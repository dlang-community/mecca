module mecca.reactor.reactor;

import std.exception;
import std.string;

import mecca.containers.lists;
import mecca.containers.arrays;
import mecca.reactor.fibril: Fibril;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.lib.memory;
import mecca.log;
import core.memory: GC;
import core.sys.posix.sys.mman: munmap, mprotect, PROT_NONE;

import std.stdio;


struct ReactorFiber {
    enum FLS_BLOCK_SIZE = 512;

    struct OnStackParams {
        Closure               closure;
        GCStackDescriptor     stackDescriptor;
        ubyte[FLS_BLOCK_SIZE] flsBlock;
    }
    enum Flags: ubyte {
        CALLBACK_SET   = 0x01,
        SCHEDULED      = 0x02,
        RUNNING        = 0x04,
        SPECIAL        = 0x08,
        IMMEDIATE      = 0x10,
        //HAS_EXCEPTION  = 0x20,
        //REQUEST_BT     = 0x40,
    }

align(1):
    Fibril         fibril;
    OnStackParams* params;
    ReactorFiber*  _next;
    uint           incarnationCounter;
    ubyte          _flags;
    ubyte[3]       _reserved;

    static assert (this.sizeof == 32);  // keep it small and cache-line friendly

    void setup(void[] stackArea) nothrow @nogc {
        fibril.set(stackArea[0 .. $ - OnStackParams.sizeof], &wrapper);
        params = cast(OnStackParams*)&stackArea[$ - OnStackParams.sizeof];
        setToInit(params);

        params.stackDescriptor.bstack = params;
        params.stackDescriptor.tstack = fibril.rsp;
        params.stackDescriptor.add();

        _next = null;
        incarnationCounter = 0;
        _flags = 0;
    }

    void teardown() nothrow @nogc {
        fibril.reset();
        if (params) {
            params.stackDescriptor.remove();
            params = null;
        }
    }

    @property uint identity() const nothrow @nogc {
        return cast(uint)(&this - theReactor.allFibers.ptr);
    }

    @property bool flag(string NAME)() const pure nothrow @nogc {
        return (_flags & __traits(getMember, Flags, NAME)) != 0;
    }
    @property void flag(string NAME)(bool value) pure nothrow @nogc {
        if (value) {
            _flags |= __traits(getMember, Flags, NAME);
        }
        else {
            _flags &= ~__traits(getMember, Flags, NAME);
        }
    }

    private void updateStackDescriptor() nothrow @nogc {
        params.stackDescriptor.tstack = fibril.rsp;
    }

    private void wrapper() nothrow {
        while (true) {
            INFO!"wrapper on %s flags=0x%0x"(identity, _flags);

            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (flag!"RUNNING");
            Throwable ex = null;

            try {
                params.closure();
            }
            catch (Throwable ex2) {
                ex = ex2;
            }

            INFO!"wrapper finished on %s, ex=%s"(identity, ex);

            params.closure.clear();
            flag!"RUNNING" = false;
            flag!"CALLBACK_SET" = false;
            incarnationCounter++;
            theReactor.fiberTerminated(ex);
        }
    }
}


struct FiberHandle {
    uint identity = uint.max;
    uint incarnation = uint.max;

    this(ReactorFiber* fib) {
        opAssign(fib);
    }
    auto ref opAssign(ReactorFiber* fib) {
        if (fib) {
            identity = fib.identity;
            incarnation = fib.incarnationCounter;
        }
        else {
            identity = uint.max;
        }
        return this;
    }
    @property ReactorFiber* get() const {
        if (identity == uint.max || theReactor.allFibers[identity].incarnationCounter != incarnation) {
            return null;
        }
        return &theReactor.allFibers[identity];
    }

    @property bool isValid() const {
        return get() !is null;
    }

    alias get this;
}


struct Reactor {
    enum NUM_SPECIAL_FIBERS = 2;

    struct Options {
        uint     numFibers = 256;
        size_t   fiberStackSize = 32*1024;
        uint     maxFDs = 1024;
        Duration gcInterval = 30.seconds;
    }

    bool _open;
    bool _running;
    int criticalSectionNesting;
    ulong idleCycles;
    Options options;

    MmapBuffer fiberStacks;
    MmapArray!ReactorFiber allFibers;
    LinkedQueueWithLength!(ReactorFiber*) freeFibers;
    LinkedQueueWithLength!(ReactorFiber*) scheduledFibers;

    ReactorFiber* thisFiber;
    ReactorFiber* prevFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    FixedArray!(void delegate(), 16) idleCallbacks;

    void setup() {
        assert (!_open);
        _open = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        thisFiber = null;
        criticalSectionNesting = 0;
        idleCallbacks.length = 0;

        foreach(i, ref fib; allFibers) {
            auto stack = fiberStacks[i * stackPerFib .. (i + 1) * stackPerFib];
            //errnoEnforce(mprotect(stack.ptr, SYS_PAGE_SIZE, PROT_NONE) == 0);
            errnoEnforce(munmap(stack.ptr, SYS_PAGE_SIZE) == 0, "munmap");
            fib.setup(stack[SYS_PAGE_SIZE .. $]);

            if (i >= NUM_SPECIAL_FIBERS) {
                freeFibers.append(&fib);
            }
        }

        mainFiber = &allFibers[0];
        mainFiber.flag!"SPECIAL" = true;
        mainFiber.flag!"CALLBACK_SET" = true;

        idleFiber = &allFibers[1];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.flag!"CALLBACK_SET" = true;
        idleFiber.params.closure.set(&idleLoop);
    }

    void teardown() {
        options.setToInit();
        allFibers.free();
        fiberStacks.free();
    }

    @property private bool shouldRunTimedCallbacks() {
        return false;
    }

    private void switchToNext() {
        DEBUG!"SWITCH out of %s"(thisFiber.identity);

        // in source fiber
        {
            if (thisFiber !is mainFiber && !mainFiber.flag!"SCHEDULED" && shouldRunTimedCallbacks()) {
                resumeSpecialFiber(mainFiber);
            }
            else if (scheduledFibers.empty) {
                resumeSpecialFiber(idleFiber);
            }

            assert (!scheduledFibers.empty, "scheduledList is empty");

            prevFiber = thisFiber;
            prevFiber.flag!"RUNNING" = false;

            thisFiber = scheduledFibers.popHead();
            assert (thisFiber.flag!"SCHEDULED");

            thisFiber.flag!"RUNNING" = true;
            thisFiber.flag!"SCHEDULED" = false;

            if (prevFiber !is thisFiber) {
                // make the switch
                prevFiber.fibril.switchTo(thisFiber.fibril);
            }
        }

        // in destination fiber
        {
            // note that GC cannot happen here since we disabled it in the mainloop() --
            // otherwise this might have been race-prone
            prevFiber.updateStackDescriptor();
            DEBUG!"SWITCH into %s"(thisFiber.identity);
        }
    }

    private void fiberTerminated(Throwable ex) nothrow {
        assert (!thisFiber.flag!"SPECIAL", "special fibers must never terminate");
        assert (ex is null);

        freeFibers.prepend(thisFiber);

        try {
            /+if (ex) {
                mainFiber.setException(ex);
                resumeSpecialFiber(mainFiber);
            }+/
            switchToNext();
        }
        catch (Throwable ex2) {
            ERROR!"switchToNext failed with exception %s"(ex2);
            assert(false);
        }
    }

    package void suspendThisFiber(Timeout timeout = Timeout.infinite) {
        //LOG("suspend");
        assert (!isInCriticalSection);
        switchToNext();
    }

    private void resumeSpecialFiber(ReactorFiber* fib) {
        assert (fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");
        assert (!fib.flag!"SCHEDULED" || scheduledFibers.head is fib);

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            scheduledFibers.prepend(fib);
        }
    }

    private void resumeFiber(ReactorFiber* fib) {
        assert (!fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            if (fib.flag!"IMMEDIATE") {
                fib.flag!"IMMEDIATE" = false;
                scheduledFibers.prepend(fib);
            }
            else {
                scheduledFibers.append(fib);
            }
        }
    }

    private ReactorFiber* _spawnFiber(bool immediate) {
        auto fib = freeFibers.popHead();
        assert (!fib.flag!"CALLBACK_SET");
        fib.flag!"IMMEDIATE" = immediate;
        fib.flag!"CALLBACK_SET" = true;
        resumeFiber(fib);
        return fib;
    }

    public FiberHandle spawnFiber(T...)(T args) {
        auto fib = _spawnFiber(false);
        fib.params.closure.set(args);
        return FiberHandle(fib);
    }

    @property bool isIdle() pure const nothrow @nogc {
        return thisFiber is idleFiber;
    }
    @property bool isMain() pure const nothrow @nogc {
        return thisFiber is mainFiber;
    }
    @property bool isSpecialFiber() const nothrow @nogc {
        return thisFiber.flag!"SPECIAL";
    }

    private void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            end = start = TscTimePoint.now;

            while (scheduledFibers.empty) {
                //enterCriticalSection();
                //scope(exit) leaveCriticalSection();
                end = TscTimePoint.now;
                runTimedCallbacks();
                foreach(cb; idleCallbacks) {
                    cb();
                }
                //if (!options.userlandPolling && nothingToDo) {
                //    // when idle, sleep on epoll for 8ms
                //    fetchEpollEventsIdle();
                //}
                DEBUG!"Reactor idle"();
                import core.thread; Thread.sleep(1.seconds);
            }
            idleCycles += end.diff!"cycles"(start);
            switchToNext();
        }
    }

    void runTimedCallbacks() {
    }

    void mainloop() {
        assert (_open);
        assert (!_running);
        assert (thisFiber is null);

        _running = true;
        GC.disable();
        scope(exit) GC.enable();

        thisFiber = mainFiber;
        scope(exit) thisFiber = null;

        while (_running) {
            runTimedCallbacks();
            switchToNext();
        }
    }

    void stop() {
        if (_running) {
            _running = false;
            if (thisFiber !is mainFiber) {
                resumeSpecialFiber(mainFiber);
            }
        }
    }

    public void enterCriticalSection() pure nothrow @nogc {
        pragma(inline, true);
        criticalSectionNesting++;
    }
    public void leaveCriticalSection() pure nothrow @nogc {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }
    @property bool isInCriticalSection() const pure nothrow @nogc {
        return criticalSectionNesting > 0;
    }

    @property public auto criticalSection() {
        pragma(inline, true);
        struct CriticalSection {
            @disable this(this);
            ~this() {theReactor.leaveCriticalSection();}
        }
        enterCriticalSection();
        return CriticalSection();
    }

    void yieldThisFiber() {
        resumeFiber(thisFiber);
        suspendThisFiber();
    }
}


__gshared Reactor theReactor;


unittest {
    import std.stdio;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    static void fibFunc(string name) {
        foreach(i; 0 .. 10) {
            writeln(name);
            theReactor.yieldThisFiber();
        }
        theReactor.stop();
    }

    theReactor.spawnFiber(&fibFunc, "hello");
    theReactor.spawnFiber(&fibFunc, "world");
    theReactor.mainloop();
}

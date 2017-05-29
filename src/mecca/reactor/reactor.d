module mecca.reactor.reactor;

import std.exception;
import std.string;

import mecca.containers.lists;
import mecca.reactor.fibril: Fibril;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.lib.memory;
import core.memory: GC;
import core.sys.posix.sys.mman: mprotect, PROT_NONE;



struct ReactorFiber {
    enum FLS_BLOCK_SIZE = 512;

    struct OnStackParams {
        Closure               closure;
        GCStackDescriptor     stackDescriptor;
        ubyte[FLS_BLOCK_SIZE] flsBlock;
    }
    enum Flags: ubyte {
        IS_SET         = 0x01,
        SPECIAL        = 0x02,
        PRIORITIZED    = 0x04,
        //HAS_EXCEPTION  = 0x10,
        //REQUEST_BT     = 0x40,
    }
    enum State: ubyte {
        FREE,
        SCHEDULED,
        PENDING,
        RUNNING,
    }

align(1):
    Fibril         fibril;
    OnStackParams* params;
    ReactorFiber*  _next;
    uint           incarnationCounter;
    ubyte          _flags;
    State          state;
    ubyte[2]       _reserved;

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
        state = State.FREE;
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
            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (state == State.RUNNING);
            Throwable ex = null;

            try {
                params.closure();
            }
            catch (Throwable ex2) {
                ex = ex2;
            }

            params.closure.clear();
            state = State.FREE;
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
    enum NUM_SPECIAL_FIBERS = 3;

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
    ReactorFiber* callbacksFiber;

    void setup() {
        assert (!_open);
        _open = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        thisFiber = null;
        criticalSectionNesting = 0;

        foreach(i, ref fib; allFibers) {
            auto stack = fiberStacks[i * stackPerFib .. (i + 1) * stackPerFib];
            errnoEnforce(mprotect(stack.ptr, SYS_PAGE_SIZE, PROT_NONE) == 0);
            fib.setup(stack[SYS_PAGE_SIZE .. $]);

            if (i >= NUM_SPECIAL_FIBERS) {
                freeFibers.append(&fib);
            }
        }

        mainFiber = &allFibers[0];
        mainFiber.flag!"SPECIAL" = true;

        idleFiber = &allFibers[1];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.params.closure.set(&idleLoop);

        callbacksFiber = &allFibers[2];
        callbacksFiber.flag!"SPECIAL" = true;
        callbacksFiber.params.closure.set(&callbacksLoop);
    }

    void teardown() {
        options.setToInit();
        allFibers.free();
        fiberStacks.free();
    }

    private void switchToNext() {
        assert (!isInCriticalSection);

        import std.stdio; writefln("SWITCH out of %s", thisFiber.identity);

        // in source fiber
        {
            //if (thisFiber !is callbacksFiber && !callbacksFiber.flag!"IN_SCHEDULED" && shouldRunTimedCallbacks()) {
            //    resumeSpecialFiber(callbacksFiber);
            //}
            //else
            if (scheduledFibers.empty) {
                resumeSpecialFiber(idleFiber);
                // now scheduledFibers is surely not empty
            }

            assert (!scheduledFibers.empty, "scheduledList is empty");

            prevFiber = thisFiber;
            thisFiber = scheduledFibers.popHead();
            assert (thisFiber.state == ReactorFiber.State.SCHEDULED);

            thisFiber.state = ReactorFiber.State.RUNNING;
            // make the switch
            prevFiber.fibril.switchTo(thisFiber.fibril);
        }

        import std.stdio; writefln("SWITCH into %s", thisFiber.identity);

        // in destination fiber
        {
            // note that GC cannot happen here since we disabled it in the mainloop() --
            // otherwise this might have been race-prone
            prevFiber.updateStackDescriptor();
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
            assert(false);
        }
    }

    /+package void suspendThisFiber(Timeout timeout = Timeout.infinite) {
        //LOG("suspend");
        switchToNext();
    }+/

    private void resumeSpecialFiber(ReactorFiber* fib) {
        assert (fib.flag!"SPECIAL");

        if (fib.state == ReactorFiber.State.PENDING) {
            fib.state = ReactorFiber.State.SCHEDULED;
            scheduledFibers.prepend(fib);
        }
        else if (fib.state == ReactorFiber.State.SCHEDULED) {
            assert (scheduledFibers.head is fib);
        }
        else {
            assert (false, "state=%s".format(fib.state));
        }
    }

    private void resumeFiber(ReactorFiber* fib) {
        assert (!fib.flag!"SPECIAL");

        if (fib.state == ReactorFiber.State.PENDING) {
            fib.state = ReactorFiber.State.SCHEDULED;
            if (fib.flag!"PRIORITIZED") {
                fib.flag!"PRIORITIZED" = false;
                scheduledFibers.prepend(fib);
            }
            else {
                scheduledFibers.append(fib);
            }
        }
        else if (fib.state == ReactorFiber.State.SCHEDULED) {
            // LOG
        }
        else {
            assert (false);
        }
    }

    private ReactorFiber* _spawnFiber(bool immediate) {
        auto fib = freeFibers.popHead();
        assert (fib.state == ReactorFiber.State.FREE);
        fib.state = ReactorFiber.State.PENDING;
        fib.flag!"PRIORITIZED" = immediate;
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
            while (scheduledFibers.empty) {
                import core.thread;
                import std.stdio;
                writeln("idle");
                Thread.sleep(1.seconds);
            }
            switchToNext();
        }
    }
    private void callbacksLoop() {
        while (true) {
            switchToNext();
        }
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

        import std.stdio; writeln("MAINLOOP");

        while (_running) {
            /+with (criticalSection) {
                foreach(cb; mainCallbacks) {
                    cb();
                }
                mainCallbacks.length = 0;
            }+/
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

    static void fibFunc(int x) {
        foreach(i; 0 .. 10) {
            writeln(x);
            theReactor.yieldThisFiber();
        }
        theReactor.stop();
    }

    theReactor.spawnFiber(&fibFunc, 10);
    //theReactor.spawnFiber(&fibFunc, 20);
    theReactor.mainloop();
}


























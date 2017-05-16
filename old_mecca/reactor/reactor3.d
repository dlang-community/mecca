module mecca.reactor.reactor3;

import std.exception;
import std.string: format;
import core.memory: GC;
import std.traits: Parameters;

import mecca.lib.reflection: Closure, setInitTo;
import mecca.lib.memory: SYS_PAGE_SIZE, prefetch_read, MmapArray;
import mecca.lib.hacks: gcGetStats, GCStats, GCStackDescriptor;
import mecca.lib.exception: ExcBuf;
import mecca.lib.time: TscTimePoint, Timeout, Duration, seconds;

import mecca.containers.array: FixedArray;
import mecca.containers.linked_set: Chain;
import mecca.containers.queue: IntrusiveQueue;

import mecca.reactor.fibril: Fibril;


private struct ReactorFiber {
    enum STACK_GUARD_PAGES = 1;
    enum FLS_BLOCK_SIZE = 512;

    struct OnStackParams {
        void[] stackMapping;
        GCStackDescriptor stackDescriptor;
        Closure closure;
        ubyte[FLS_BLOCK_SIZE] flsBlock;
        ExcBuf excBuf;
    }
    enum Flags: ubyte {
        IS_SET         = 0x01,
        IN_FREE        = 0x02,
        IN_SCHEDULED   = 0x04,
        SPECIAL        = 0x08,
        HAS_EXCEPTION  = 0x10,
        PRIORITIZED    = 0x20,
        REQUEST_BT     = 0x40,
    }

align(1):
    Fibril          fibril;
    OnStackParams*  onStackParams;
    ReactorFiber*   next;
    uint            incarnationCounter;
    ubyte           _flags;
    ubyte[3]        _reserved;

    static assert (this.sizeof == 32);  // keep it small

    @disable this(this);

    void open(size_t stackSize) {
        assert (stackSize > OnStackParams.sizeof);

        import core.sys.posix.sys.mman;
        auto mapSize = (((stackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE + STACK_GUARD_PAGES) * SYS_PAGE_SIZE);
        auto pStack = mmap(null, mapSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        errnoEnforce(pStack != MAP_FAILED, "mmap (%s)".format(mapSize));
        errnoEnforce(mprotect(pStack, STACK_GUARD_PAGES * SYS_PAGE_SIZE, PROT_NONE) == 0, "mprotect");
        auto stackMapping = pStack[0 .. mapSize];

        this.fibril.set(stackMapping[0 .. $-OnStackParams.sizeof], &wrapper);
        this.onStackParams = cast(OnStackParams*)&stackMapping[$-OnStackParams.sizeof];
        setInitTo(this.onStackParams);
        this.onStackParams.stackMapping = stackMapping;
        this.onStackParams.stackDescriptor.bstack = onStackParams;
        this.onStackParams.stackDescriptor.tstack = fibril.rsp;
        this.onStackParams.stackDescriptor.add();

        this.next = null;
        this.incarnationCounter = 0;
        this._flags = 0;
    }

    void close() {
        import core.sys.posix.sys.mman;
        if (onStackParams) {
            fibril.reset();
            onStackParams.stackDescriptor.remove();
            errnoEnforce(munmap(onStackParams.stackMapping.ptr, onStackParams.stackMapping.length));
            onStackParams = null;
        }
    }

    @property bool flag(string NAME)() const pure nothrow {
        return (_flags & __traits(getMember, Flags, NAME)) != 0;
    }
    @property void flag(string NAME)(bool val) pure nothrow {
        if (val) {
            _flags |= __traits(getMember, Flags, NAME);
        }
        else {
            _flags &= ~__traits(getMember, Flags, NAME);
        }
    }

    private void updateStackDescriptor() nothrow {
        onStackParams.stackDescriptor.tstack = fibril.rsp;
    }

    private void setException(Throwable ex) nothrow {
        flag!"HAS_EXCEPTION" = true;
        //onStackParams.excBuf.set(ex);
    }

    void wrapper() nothrow {
        while (true) {
            //LOG("wrapper this=%s", theReactor.getFiberIndex(&this));
            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (flag!"IS_SET");

            try {
                onStackParams.closure();
                theReactor.wrapperFinished(null);
            }
            catch (Throwable ex) {
                theReactor.wrapperFinished(ex);
            }
        }
    }
}

struct FiberHandle {
    ReactorFiber* _fib;
    uint _incarnation;

    this(ReactorFiber* fib) {
        opAssign(fib);
    }
    void opAssign(ReactorFiber* fib) {
        _fib = fib;
        _incarnation = fib ? fib.incarnationCounter : uint.max;
    }
    @property ReactorFiber* get() pure nothrow @nogc {
        return _fib && _fib.incarnationCounter == _incarnation ? _fib : null;
    }
    @property bool isValid() const pure nothrow @nogc {
        return (cast(FiberHandle*)&this).get() !is null;
    }
}

struct TimedCallback {
    TscTimePoint timePoint;
    long         intervalCycles;
    Closure      callback;
    Chain        _chain;
}

struct _TCBHandle {}
alias TCBHandle = _TCBHandle*;


/+private void LOG(string M=__FUNCTION__, size_t L=__LINE__, T...)(string fmt, T args) nothrow {
    pragma(inline, true);
    import std.string;
    import std.stdio;
    try {
        writefln("[F(%s) at %s:%s] " ~ fmt, theReactor.getFiberIndex(theReactor.thisFiber), M.split(".")[$-1], L, args);
    }
    catch (Throwable ex) {}
}+/


struct Reactor {
    enum NUM_SPECIAL_FIBERS = 3;

    bool _open;
    bool _running;
    ReactorFiber* prevFiber;
    ReactorFiber* thisFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    ReactorFiber* callbacksFiber;
    IntrusiveQueue!(ReactorFiber*) freeList;
    IntrusiveQueue!(ReactorFiber*) scheduledList;
    MmapArray!ReactorFiber allFibers;
    FixedArray!(void delegate(), 8) mainCallbacks;
    FixedArray!(void delegate(), 16) idleCallbacks;
    long idleCycles;
    int criticalSectionNesting;


    struct Options {
        uint numFibers = 1024;
        uint fiberStackSize = 32 * 4096;
        uint maxFDs = 1024;
        Duration gcInterval = 30.seconds;
    }
    Options options;

    void open() {
        assert (!_open);
        _open = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);
        mainCallbacks.length = 0;

        allFibers.allocate(options.numFibers);
        foreach(i, ref f; allFibers) {
            f.open(i == 0 ? SYS_PAGE_SIZE : options.fiberStackSize);
            if (i < NUM_SPECIAL_FIBERS) {
                f.flag!"SPECIAL" = true;
            }
            else {
                f.flag!"IN_FREE" = true;
                freeList.pushTail(&f);
            }
        }

        mainFiber = &allFibers[0];
        mainFiber.flag!"IS_SET" = true;

        idleFiber = &allFibers[1];
        idleFiber.flag!"IS_SET" = true;
        idleFiber.onStackParams.closure.set(&idleLoop);

        callbacksFiber = &allFibers[2];
        callbacksFiber.flag!"IS_SET" = true;
        callbacksFiber.onStackParams.closure.set(&callbacksLoop);

        thisFiber = null;
        criticalSectionNesting = 0;
    }
    void close() {
        setInitTo(options);
        if (!_open) {
            return;
        }
    }

    @property bool shouldRunTimedCallbacks() nothrow {
        return false;
    }

    private void switchToNext() {
        assert (!isInCriticalSection);

        // in source fiber
        {
            if (thisFiber !is callbacksFiber && !callbacksFiber.flag!"IN_SCHEDULED" && shouldRunTimedCallbacks()) {
                resumeSpecialFiber(callbacksFiber);
            }
            else if (scheduledList.empty) {
                resumeSpecialFiber(idleFiber);
            }

            //prefetch_read(thisFiber.next.fibril.rsp);
            assert (!scheduledList.empty, "scheduledList is empty");
            assert (scheduledList.peekHead.fibril.rsp, "rsp is null, thisFiber=%s".format(getFiberIndex(scheduledList.peekHead)));

            prevFiber = thisFiber;
            thisFiber = scheduledList.popHead();
            thisFiber.flag!"IN_SCHEDULED" = false;
            // make the switch
            prevFiber.fibril.switchTo(thisFiber.fibril);
        }

        // in destination fiber
        {
            // note that GC cannot happen here since we disabled it in the mainloop() --
            // otherwise this might have been race-prone
            prevFiber.updateStackDescriptor();

            //if (thisFiber.flag!"REQUEST_BT") {
            //    auto tmp = thisFiber;
            //    thisFiber = prevFiber;
            //    prevFiber = tmp;
            //    prevFiber.fibril.switchTo(thisFiber.fibril);
            //}

            if (thisFiber.flag!"HAS_EXCEPTION") {
                thisFiber.flag!"HAS_EXCEPTION" = false;
                throw thisFiber.onStackParams.excBuf.get();
            }
        }
    }

    private void wrapperFinished(Throwable ex) nothrow {
        assert (!thisFiber.flag!"SPECIAL", "special fibers must never terminate");

        try {
            thisFiber.onStackParams.closure.reset();
            thisFiber.flag!"IS_SET" = false;
            thisFiber.flag!"IN_FREE" = true;
            freeList.pushHead(thisFiber);
            thisFiber.incarnationCounter++;
            if (ex) {
                mainFiber.setException(ex);
                resumeSpecialFiber(mainFiber);
            }
            switchToNext();
        }
        catch (Throwable ex2) {
            // won't really happen
            assert(false);
        }
    }

    private void resumeSpecialFiber(ReactorFiber* fib) {
        assert (fib.flag!"SPECIAL");
        assert (!fib.flag!"IN_FREE");
        if (fib.flag!"IN_SCHEDULED") {
            assert (scheduledList.peekHead() is fib);
        }
        else {
            fib.flag!"IN_SCHEDULED" = true;
            scheduledList.pushHead(fib);
        }
    }

    public void*[] extractFiberBacktrace(FiberHandle fibHandle) {
        return null;
    }

    public void throwInFiber(FiberHandle fibHandle, Throwable ex) {
        if (auto f = fibHandle.get()) {
        }
    }

    public bool killFiber(FiberHandle fibHandle, Throwable ex) {
        if (auto f = fibHandle.get()) {
            return true;
        }
        else {
            return false;
        }
    }

    package void resumeFiber(FiberHandle fibHandle) {
        if (auto f = fibHandle.get()) {
            resumeFiber(f);
        }
    }

    private void resumeFiber(ReactorFiber* fib) {
        assert (fib.flag!"IS_SET", "fib=%s".format(getFiberIndex(fib)));
        assert (!fib.flag!"IN_FREE");
        assert (!fib.flag!"SPECIAL");
        if (!fib.flag!"IN_SCHEDULED") {
            fib.flag!"IN_SCHEDULED" = true;
            if (fib.flag!"PRIORITIZED") {
                fib.flag!"PRIORITIZED" = false;
                //LOG("resumeing %s (head)", getFiberIndex(fib));
                scheduledList.pushHead(fib);
            }
            else {
                //LOG("resumeing %s (tail)", getFiberIndex(fib));
                scheduledList.pushTail(fib);
            }
        }
        else {
            //LOG("%s already scheduled", getFiberIndex(fib));
        }
    }
    package void suspendThisFiber(Timeout timeout = Timeout.infinite) {
        //LOG("suspend");
        switchToNext();
    }

    @property bool isIdle() pure const nothrow {return thisFiber is idleFiber;}
    @property bool isMain() pure const nothrow {return thisFiber is mainFiber;}
    @property bool isSpecialFiber() pure const nothrow {return thisFiber.flag!"SPECIAL";}
    @property long getFiberIndex(ReactorFiber* fib) pure const nothrow {return fib ? fib - allFibers.ptr : -1;}

    private ReactorFiber* _spawnFiber(bool immediate) {
        auto fib = freeList.popHead();
        assert (!fib.flag!"IS_SET", "%s".format(getFiberIndex(fib)));
        assert (fib.flag!"IN_FREE");
        fib.flag!"IN_FREE" = false;
        fib.flag!"IS_SET" = true;
        fib.flag!"PRIORITIZED" = immediate;
        resumeFiber(fib);
        return fib;
    }

    public FiberHandle spawnFiber(T)(T fn) if (is(T == void function()) || is(T == void delegate())) {
        auto fib = _spawnFiber(false);
        fib.onStackParams.closure.set(fn);
        return FiberHandle(fib);
    }
    public FiberHandle spawnFiber(alias F)(Parameters!F args) {
        auto fib = _spawnFiber(false);
        fib.onStackParams.closure.set!F(args);
        return FiberHandle(fib);
    }

    private void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            start = TscTimePoint.now;
            while (scheduledList.empty) {
                enterCriticalSection();
                scope(exit) leaveCriticalSection();
                end = TscTimePoint.now;
                foreach(cb; idleCallbacks) {
                    cb();
                }
                runTimedCallbacks();
            }
            idleCycles += end.diff!"cycles"(start);
            switchToNext();
        }
    }
    private void callbacksLoop() {
        while (true) {
            with (criticalSection) {
                runTimedCallbacks();
            }
            switchToNext();
        }
    }
    private void runTimedCallbacks() {
        auto now = TscTimePoint.now;
    }

    void mainloop() {
        assert (_open);
        assert (!_running);

        _running = true;
        GC.disable();
        scope(exit) GC.enable();

        assert (thisFiber is null);
        thisFiber = mainFiber;
        scope(exit) thisFiber = null;

        while (_running) {
            with (criticalSection) {
                foreach(cb; mainCallbacks) {
                    cb();
                }
                mainCallbacks.length = 0;
            }
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

    void runInMain(void delegate() cb) {
        mainCallbacks ~= cb;
        resumeSpecialFiber(mainFiber);
    }

    public void enterCriticalSection() {
        pragma(inline, true);
        criticalSectionNesting++;
    }
    public void leaveCriticalSection() {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }
    @property bool isInCriticalSection() const pure {return criticalSectionNesting > 0;}

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

void main() {
    import std.stdio;

    theReactor.open();
    scope(exit) theReactor.close();

    long loops;
    enum ITERS = 1_000_000;

    void f() {
        foreach(i; 0 .. ITERS) {
            //writeln("f ", i);
            loops++;
            theReactor.yieldThisFiber();
        }
        theReactor.stop();
    }
    void g() {
        foreach(i; 0 .. ITERS) {
            //writeln("g ", i);
            loops++;
            theReactor.yieldThisFiber();
        }
    }

    theReactor.spawnFiber(&f);
    foreach(i; 0 .. 30) {
        theReactor.spawnFiber(&g);
    }
    auto t0 = TscTimePoint.now;
    theReactor.mainloop();
    auto dt = TscTimePoint.now.diff!"cycles"(t0);

    writefln("done in %s cycles (%s per switch)", dt, (cast(double)dt) / loops);
}




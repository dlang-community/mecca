/// Define the micro-threading reactor
module mecca.reactor;

static import posix_signal = core.sys.posix.signal;
static import posix_time = core.sys.posix.time;
static import posix_ucontext = core.sys.posix.ucontext;
import core.memory: GC;
import core.sys.posix.signal;
import core.sys.posix.sys.mman: munmap, mprotect, PROT_NONE;
import core.thread: thread_isMainThread;

import std.exception;
import std.string;
import std.traits;

import mecca.containers.lists;
import mecca.containers.arrays;
import mecca.containers.pools;
import mecca.lib.concurrency;
import mecca.lib.consts;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.lib.memory;
import mecca.log;
import mecca.log.impl;
import mecca.platform.linux;
import mecca.reactor.fiber_group;
import mecca.reactor.impl.time_queue;
import mecca.reactor.impl.fibril: Fibril;
import mecca.reactor.impl.fls;
import mecca.reactor.subsystems.gc_tracker;
import mecca.reactor.subsystems.threading;
public import mecca.reactor.types;

import std.stdio;

/// Handle for manipulating registered timers.
alias TimerHandle = Reactor.TimerHandle;
alias FiberIncarnation = ushort;

struct ReactorFiber {
    struct OnStackParams {
        Closure                 fiberBody;
        GCStackDescriptor       stackDescriptor;
        FiberGroup.Chain        fgChain;
        FLSArea                 flsBlock;
        ExcBuf                  currExcBuf;
        LogsFiberSavedContext   logsSavedContext;
    }
    enum Flags: ubyte {
        // XXX Do we need CALLBACK_SET?
        CALLBACK_SET   = 0x01,  /// Has callback set
        SPECIAL        = 0x02,  /// Special fiber. Not a normal user fiber
        SCHEDULED      = 0x04,  /// Fiber currently scheduled to be run
        SLEEPING       = 0x08,  /// Fiber is sleeping on a sync object
        HAS_EXCEPTION  = 0x10,  /// Fiber has pending exception to be thrown in it
        EXCEPTION_BT   = 0x20,  /// Fiber exception needs to have fiber's backtrace
        GC_ENABLED     = 0x40,  /// Fiber is allowed to perform GC without warning
        //REQUEST_BT     = 0x40,
    }

    enum State : ubyte {
        None, Running, Sleeping, Done
    }

align(1):
    Fibril                                      fibril;
    OnStackParams*                              params;
    LinkedListWithOwner!(ReactorFiber*)*        _owner;
    FiberId                                     _nextId;
    FiberId                                     _prevId;
    FiberIncarnation                            incarnationCounter;
    ubyte                                       _flags;
    State                                       state;

    // We define this struct align(1) for the sole purpose of making the following static assert verify what it's supposed to
    static assert (this.sizeof == 32);  // keep it small and cache-line friendly

    // LinkedQueue access through property
    @property ReactorFiber* _next() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_nextId);
    }

    @property void _next(FiberId newNext) nothrow @safe @nogc {
        _nextId = newNext;
    }

    @property void _next(ReactorFiber* newNext) nothrow @safe @nogc {
        _nextId = to!FiberId(newNext);
    }

    @property ReactorFiber* _prev() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_prevId);
    }

    @property void _prev(FiberId newPrev) nothrow @safe @nogc {
        _prevId = newPrev;
    }

    @property void _prev(ReactorFiber* newPrev) nothrow @safe @nogc {
        _prevId = to!FiberId(newPrev);
    }

    @notrace void setup(void[] stackArea, bool main) nothrow @nogc {
        if( !main )
            fibril.set(stackArea[0 .. $ - OnStackParams.sizeof], &wrapper);
        params = cast(OnStackParams*)&stackArea[$ - OnStackParams.sizeof];
        setToInit(params);

        if( !main ) {
            params.stackDescriptor.bstack = stackArea.ptr + stackArea.length; // Include params, as FLS is stored there
            params.stackDescriptor.tstack = fibril.rsp;
            params.stackDescriptor.add();
        }

        _next = null;
        incarnationCounter = 0;
        _flags = 0;
    }

    @notrace void teardown(bool main) nothrow @nogc {
        fibril.reset();
        if (!main) {
            params.stackDescriptor.remove();
        }
        params = null;
    }

    @notrace void switchTo(ReactorFiber* next) nothrow @safe @nogc {
        pragma(inline, true);
        fibril.switchTo(next.fibril, &params.stackDescriptor.tstack);
    }

    @property FiberId identity() const nothrow @safe @nogc {
        return to!FiberId(&this);
    }

    @property bool flag(string NAME)() const pure nothrow @safe @nogc {
        return (_flags & __traits(getMember, Flags, NAME)) != 0;
    }
    @property void flag(string NAME)(bool value) pure nothrow @safe @nogc {
        if (value) {
            _flags |= __traits(getMember, Flags, NAME);
        }
        else {
            import mecca.lib.integers: bitComplement;
            _flags &= bitComplement(__traits(getMember, Flags, NAME));
        }
    }

private:
    @notrace void wrapper() nothrow {
        while (true) {
            try {
                switchInto();
            } catch(Throwable ex) {
                ASSERT!"Fiber %s had exception at the very beginning of its run"(false, identity);
            }
            params.logsSavedContext = LogsFiberSavedContext.init;
            INFO!"wrapper on %s flags=0x%0x"(identity, _flags);

            assert (theReactor.thisFiber is &this, "this is wrong");
            ASSERT!"Fiber %s is in state %s instead of \"Running\"" (state == State.Running, theReactor.thisFiber.identity, state);
            Throwable ex = null;

            try {
                params.fiberBody();
            }
            catch (ReactorExit ex2) {
                // Do nothing. The reactor is quitting
            }
            catch (FiberGroup.FiberGroupExtinction ex2) {
                INFO!"Fiber %s killed by fiber group"(theReactor.runningFiberId);
            }
            catch (Throwable ex2) {
                ex = ex2;
            }

            if (params.fgChain.owner !is null) {
                params.fgChain.owner.remove(theReactor.thisFiber);
            }

            if( ex is null )
                INFO!"wrapper finished on %s"(identity);
            else
                ERROR!"wrapper finished on %s with exception: %s"(identity, ex.msg);

            params.fiberBody.clear();
            flag!"CALLBACK_SET" = false;
            assert (state == State.Running);
            state = State.Done;
            incarnationCounter++;
            if (ex !is null) {
                theReactor.forwardExceptionToMain(ex);
            } else {
                theReactor.fiberTerminated();
            }
        }
    }

    void switchInto() @safe @nogc {
        switchCurrExcBuf( &params.currExcBuf );
        if (!flag!"SPECIAL") {
            params.flsBlock.switchTo();
        } else {
            FLSArea.switchToNone();
        }
        logSwitchFiber(&params.logsSavedContext, cast( Parameters!logSwitchFiber[1] )identity.value);

        if (flag!"HAS_EXCEPTION") {
            Throwable ex = params.currExcBuf.get();
            if (flag!"EXCEPTION_BT") {
                params.currExcBuf.setTraceback(ex);
                flag!"EXCEPTION_BT" = false;
            }

            flag!"HAS_EXCEPTION" = false;
            throw ex;
        }
    }
}


/**
  A handle to a running fiber.

  This handle expires automatically when the fiber stops running. Unless you know, semantically, that a fiber is still running, don't assume
  there is a running fiber attached to this handle.

  The handle will correctly claim invalidity even if a new fiber is launched with the same FiberId.
 */
struct FiberHandle {
private:
    FiberId identity;
    FiberIncarnation incarnation;

public:
    this(ReactorFiber* fib) nothrow @safe @nogc {
        opAssign(fib);
    }
    auto ref opAssign(ReactorFiber* fib) nothrow @safe @nogc {
        if (fib) {
            identity = fib.identity;
            incarnation = fib.incarnationCounter;
        }
        else {
            identity = FiberId.invalid;
        }
        return this;
    }
    package @property ReactorFiber* get() const nothrow @safe @nogc {
        if (!identity.isValid || theReactor.allFibers[identity.value].incarnationCounter != incarnation) {
            return null;
        }
        return &theReactor.allFibers[identity.value];
    }

    /// returns whether the handle currently describes a running fiber.
    @property bool isValid() const nothrow @safe @nogc {
        return get() !is null;
    }

    /// returns the FiberId described by the handle. If the handle is no longer valid, will return FiberId.invalid
    @property FiberId fiberId() const nothrow @safe @nogc {
        if( isValid )
            return identity;

        return FiberId.invalid;
    }
}

/**
  The main scheduler for the micro-threading architecture.
 */
struct Reactor {
    /// The options control aspects of the reactor's operation
    struct OpenOptions {
        /// Maximum number of fibers.
        uint     numFibers = 256;
        /// Stack size of each fiber (except the main fiber). The reactor will allocate numFiber*fiberStackSize during startup
        size_t   fiberStackSize = 32*KB;
        /**
          How often does the GC's collection run.

          The reactor uses unconditional periodic collection, rather than lazy evaluation one employed by the default GC settings. This
          setting sets how often the collection cycle should run.
         */
        Duration gcInterval = 30.seconds;
        /**
          Base granularity of the reactor's timer.

          Any scheduled task is scheduled at no better accuracy than timerGranularity. $(B In addition to) the fact that a timer task may
          be delayed. As such, with a 1ms granularity, a task scheduled for 1.5ms from now is the same as a task scheduled for 2ms from now,
          which may run 3ms from now.
         */
        Duration timerGranularity = 1.msecs;
        /**
          Hogger detection threshold.

          A hogger is a fiber that does not release the CPU to run other tasks for a long period of time. Often, this is a result of a bug
          (i.e. - calling the OS's `sleep` instead of the reactor's).

          Hogger detection works by measuring how long each fiber took until it allows switching away. If the fiber took more than
          hoggerWarningThreshold, a warning is logged.
         */
        Duration hoggerWarningThreshold = 200.msecs;
        /**
          Hard hang detection.

          This is a similar safeguard to that used by the hogger detection. If activated (disabled by default), it premptively prompts the
          reactor every set time to see whether fibers are still being switched in/out. If it finds that the same fiber is running, without
          switching out, for too long, it terminates the entire program.
         */
        Duration hangDetectorTimeout = Duration.zero;
        /**
          Whether to enable fault handlers

          The fault handlers catch program faults (such as segmentation faults) and log them with their backtrace.
         */
        bool faultHandlersEnabled = true;

        /// Maximal number of timers that can be simultaneously registered.
        size_t   numTimers = 10_000;

        /// Number of threads servicing deferred tasks
        uint numThreadsInPool = 4;
        /// Worker thread stack size
        size_t threadStackSize = 512*KB;

        /// Whether we have enabled deferToThread
        bool threadDeferralEnabled;

        version(unittest) {
            /// Disable all GC collection during the reactor run time. Only available for UTs.
            bool utGcDisabled;
        } else {
            private enum utGcDisabled = false;
        }
    }

private:
    enum MAX_IDLE_CALLBACKS = 16;
    enum TIMER_NUM_BINS = 256;
    enum TIMER_NUM_LEVELS = 4;
    enum MAX_DEFERRED_TASKS = 1024;

    enum GUARD_ZONE_SIZE = SYS_PAGE_SIZE;

    enum NUM_SPECIAL_FIBERS = 2;
    enum ZERO_DURATION = Duration.zero;

    enum MainFiberId = FiberId(0);
    enum IdleFiberId = FiberId(1);

    bool _open;
    bool _running;
    bool _stopping;
    bool _gcCollectionNeeded;
    int criticalSectionNesting;
    ulong idleCycles;
    OpenOptions optionsInEffect;

    MmapBuffer fiberStacks;
    MmapArray!ReactorFiber allFibers;
    LinkedQueueWithLength!(ReactorFiber*) freeFibers;
    LinkedQueueWithLength!(ReactorFiber*) scheduledFibers;

    ReactorFiber* _thisFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    alias IdleCallbackDlg = void delegate(Duration);
    FixedArray!(IdleCallbackDlg, MAX_IDLE_CALLBACKS) idleCallbacks;
    __gshared OSSignal hangDetectorSig;
    posix_time.timer_t hangDetectorTimerId;

    SignalHandlerValue!TscTimePoint fiberRunStartTime;

    struct TimedCallback {
        TimedCallback* _next, _prev;
        timeQueue.OwnerAttrType _owner;
        TscTimePoint timePoint;
        ulong intervalCycles; // How many cycles between repeatetions. Zero means non-repeating

        Closure closure;
    }

    // TODO change to mmap pool or something
    SimplePool!(TimedCallback) timedCallbacksPool;
    CascadingTimeQueue!(TimedCallback*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue;

    ThreadPool!MAX_DEFERRED_TASKS threadPool;

public:
    /// Report whether the reactor has been properly opened (i.e. - setup has been called).
    @property bool isOpen() const pure nothrow @safe @nogc {
        return _open;
    }

    /// Report whether the reactor is currently running
    @property bool isRunning() const pure nothrow @safe @nogc {
        return _running;
    }

    /**
      Set the reactor up for doing work.

      All options must be set before calling this function.
     */
    void setup(OpenOptions options = OpenOptions.init) {
        assert (!isOpen, "reactor.setup called twice");
        _open = true;
        assert (thread_isMainThread);
        _isReactorThread = true;
        assert (options.numFibers > NUM_SPECIAL_FIBERS);
        optionsInEffect = options;

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        _thisFiber = null;
        criticalSectionNesting = 0;
        idleCallbacks.length = 0;

        foreach(i, ref fib; allFibers) {
            auto stack = fiberStacks[i * stackPerFib .. (i + 1) * stackPerFib];
            errnoEnforce(mprotect(stack.ptr, GUARD_ZONE_SIZE, PROT_NONE) == 0, "Guard zone protection failed");
            fib.setup(stack[GUARD_ZONE_SIZE .. $], i==0);

            if (i >= NUM_SPECIAL_FIBERS) {
                freeFibers.append(&fib);
            }
        }

        mainFiber = &allFibers[MainFiberId.value];
        mainFiber.flag!"SPECIAL" = true;
        mainFiber.flag!"CALLBACK_SET" = true;
        mainFiber.state = ReactorFiber.State.Running;

        idleFiber = &allFibers[IdleFiberId.value];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.flag!"CALLBACK_SET" = true;
        idleFiber.params.fiberBody.set(&idleLoop);

        timedCallbacksPool.open(options.numTimers, true);
        timeQueue.open(options.timerGranularity);

        if( options.faultHandlersEnabled )
            registerFaultHandlers();

        if( options.threadDeferralEnabled )
            threadPool.open(options.numThreadsInPool, options.threadStackSize);

        import mecca.reactor.io.fd;
        _openReactorEpoll();

        import mecca.reactor.io.signals;
        reactorSignal._open();
    }

    /**
      Shut the reactor down.
     */
    void teardown() {
        ASSERT!"reactor teardown called on non-open reactor"(isOpen);
        ASSERT!"reactor teardown called on still running reactor"(!isRunning);
        ASSERT!"reactor teardown called inside a critical section"(criticalSectionNesting==0);

        import mecca.reactor.io.signals;
        reactorSignal._close();

        import mecca.reactor.io.fd;
        _closeReactorEpoll();

        foreach(i, ref fib; allFibers) {
            fib.teardown(i==0);
        }

        if( optionsInEffect.threadDeferralEnabled )
            threadPool.close();
        switchCurrExcBuf(null);

        // disableGCTracking();

        if( optionsInEffect.faultHandlersEnabled )
            deregisterFaultHandlers();

        allFibers.free();
        fiberStacks.free();
        timeQueue.close();
        timedCallbacksPool.close();

        setToInit(freeFibers);
        setToInit(scheduledFibers);

        _thisFiber = null;
        mainFiber = null;
        idleFiber = null;
        idleCallbacks.length = 0;
        idleCycles = 0;

        _isReactorThread = false;
        _open = false;
    }

    /**
      Register an idle handler callback.

      The reactor handles scheduling and fibers switching, but has no built-in mechanism for scheduling sleeping fibers back to execution
      (except fibers sleeping on a timer, of course). Mechanisms such as file descriptor watching are external, and are registered using
      this function.

      The idler callback should receive a timeout variable. This indicates the time until the closest timer expires. If no other event comes
      in, the idler should strive to wake up after that long. Waking up sooner will, likely, cause the idler to be called again. Waking up
      later will delay timer tasks (which is allowed by the API contract).

      It is allowed to register more than one idler callback. Doing so, however, will cause $(B all) of them to be called with a timeout of
      zero (i.e. - don't sleep), resulting in a busy wait for events.
     */
    void registerIdleCallback(IdleCallbackDlg dg) nothrow @safe @nogc {
        // You will notice our deliberate lack of function to unregister
        idleCallbacks ~= dg;
        DEBUG!"%s idle callbacks registered"(idleCallbacks.length);
    }

    /**
     * Spawn a new fiber for execution.
     *
     * Parameters:
     *  The first argument must be the function/delegate to call inside the new fiber. If said callable accepts further arguments, then
     *  they must be provided as further arguments to spawnFiber.
     *
     * Returns:
     *  A FiberHandle to the newly created fiber.
     */
    @notrace FiberHandle spawnFiber(T...)(T args) nothrow @safe @nogc {
        static assert(T.length>=1, "Must pass at least the function/delegate to spawnFiber");
        auto fib = _spawnFiber(false);
        fib.params.fiberBody.set(args);
        return FiberHandle(fib);
    }

    /**
     * Spawn a new fiber for execution.
     *
     * Params:
     *  F = The function or delegate to call inside the fiber.
     *  args = The arguments for F
     *
     * Returns:
     *  A FiberHandle to the newly created fiber.
     */
    @notrace FiberHandle spawnFiber(alias F)(Parameters!F args) {
        auto fib = _spawnFiber(false);
        import std.algorithm: move;
        mixin( genMoveArgument( args.length, "fib.params.fiberBody.set!F", "args" ) );

        return FiberHandle(fib);
    }

    /// Returns whether currently running fiber is the idle fiber.
    @property bool isIdle() pure const nothrow @safe @nogc {
        return thisFiber is idleFiber;
    }

    /// Returns whether currently running fiber is the main fiber.
    @property bool isMain() pure const nothrow @safe @nogc {
        return thisFiber is mainFiber;
    }

    /// Returns whether currently running fiber is a special (i.e. - non-user) fiber
    @property bool isSpecialFiber() const nothrow @safe @nogc {
        return thisFiber.flag!"SPECIAL";
    }

    /// Returns a FiberHandle to the currently running fiber
    @property FiberHandle runningFiberHandle() nothrow @safe @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        assert(!isSpecialFiber, "Should not blindly get fiber handle of special fibers");
        return FiberHandle(thisFiber);
    }
    @property package ReactorFiber* runningFiberPtr() nothrow @safe @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        assert(!isSpecialFiber, "Should not blindly get fiber handle of special fibers");
        return thisFiber;
    }
    /**
      Returns the FiberId of the currently running fiber.

      You should almost never store the FiberId for later comparison or pass it to another fiber. Doing so risks having the current fiber
      die and another one spawned with the same FiberId. If that's what you want to do, use runningFiberHandle instead.
     */
    @property FiberId runningFiberId() const nothrow @safe @nogc {
        return thisFiber.identity;
    }

    /**
      Starts up the reactor.

      The reactor should already have at least one user fiber at that point, or it will start, but sit there and do nothing.

      This function "returns" only after the reactor is stopped and no more fibers are running.
     */
    void start() {
        META!"Reactor started"();
        assert( idleFiber !is null, "Reactor started without calling \"setup\" first" );
        mainloop();
        META!"Reactor stopped"();
    }

    /**
      Stop the reactor, killing all fibers.

      This will kill all running fibers and trigger a return from the original call to Reactor.start.

      Typically, this function call never returns (throws ReactorExit). However, if stop is called while already in the
      process of stopping, it will just return. It is, therefor, not wise to rely on that fact.
     */
    void stop() @safe @nogc {
        if( _stopping ) {
            ERROR!"Reactor.stop called, but reactor is not running"();
            return;
        }

        _stopping = true;
        if( !isMain() ) {
            resumeSpecialFiber(mainFiber);
        }

        throw mkEx!ReactorExit("Reactor is quitting");
    }

    /**
      enter a no-fiber switch piece of code.

      If the code tries to switch away from the current fiber before leaveCriticalSection is called, the reactor will throw an assert.
      This helps writing code that does interruption sensitive tasks without locks and making sure future changes don't break it.

      Critical sections are nestable.

      Also see `criticalSection` below.
     */
    void enterCriticalSection() pure nothrow @safe @nogc {
        pragma(inline, true);
        criticalSectionNesting++;
    }

    /// leave the innermost critical section.
    void leaveCriticalSection() pure nothrow @safe @nogc {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }

    /// Reports whether execution is currently within a critical section
    @property bool isInCriticalSection() const pure nothrow @safe @nogc {
        return criticalSectionNesting > 0;
    }

    /**
     * Return a RAII object handling a critical section
     *
     * The function enters a critical section. Unlike enterCriticalSection, however, there is no need to explicitly call
     * leaveCriticalSection. Instead, the function returns a variable that calls leaveCriticalSection when it goes out of scope.
     *
     * There are two advantages for using criticalSection over enter/leaveCriticalSection. The first is for nicer scoping:
     * ---
     * with(theReactor.criticalSection) {
     *   // Code in critical section goes here
     * }
     * ---
     *
     * The second case is if you need to switch, within the same code, between critical section and none:
     * ---
     * auto cs = theReactor.criticalSection;
     *
     * // Some code
     * cs.leave();
     * // Some code that sleeps
     * cs.enter();
     *
     * // The rest of the critical section code
     * ---
     *
     * The main advantage over enter/leaveCriticalSection is that this way, the critical section never leaks. Any exception thrown, either
     * from the code inside the critical section or the code temporary out of it, will result in the correct number of leaveCriticalSection
     * calls to zero out the effect.
     *
     * Also note that there is no need to call leave at the end of the code. Cs's destructor will do it for us $(B if necessary).
     */
    @property auto criticalSection() nothrow @safe @nogc {
        pragma(inline, true);
        static struct CriticalSection {
        private:
            bool owner = true;

        public:
            @disable this(this);
            ~this() nothrow @safe @nogc {
                if( owner )
                    leave();
            }

            void enter() nothrow @safe @nogc {
                DBG_ASSERT!"The same critical section was activated twice"(!owner);
                theReactor.enterCriticalSection();
                owner = true;
            }

            void leave() nothrow @safe @nogc {
                DBG_ASSERT!"Asked to leave critical section not owned by us"(owner);
                theReactor.leaveCriticalSection();
                owner = false;
            }
        }
        enterCriticalSection();
        return CriticalSection();
    }
    unittest {
        testWithReactor({
                {
                    with( theReactor.criticalSection ) {
                        assertThrows!AssertError( theReactor.yieldThisFiber() );
                    }
                }

                theReactor.yieldThisFiber();
                });
    }

    /**
     * Temporarily surrender the CPU for other fibers to run.
     *
     * Unlike suspend, the current fiber will automatically resume running after any currently scheduled fibers are finished.
     */
    void yieldThisFiber() @safe @nogc {
        resumeFiber(thisFiber);
        suspendThisFiber();
    }

    /// Handle used to manage registered timers
    struct TimerHandle {
    private:
        TimedCallback* callback;

    public:
        /// Returns whether the handle describes a currently registered task
        @property bool isValid() const @safe @nogc {
            // TODO make the handle resilient to ABA changes
            return callback !is null && callback._owner !is null;
        }
    }

    /**
     * Registers a timer task.
     *
     * Params:
     * F = the callable to be invoked when the timer expires
     * timeout = when the timer is be called
     * params = the parameters to call F with
     *
     * Returns:
     * A handle to the just registered timer.
     */
    TimerHandle registerTimer(alias F)(Timeout timeout, Parameters!F params) nothrow @safe @nogc {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.closure.set(&F, params);
        callback.timePoint = timeout.expiry;
        callback.intervalCycles = 0;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    /**
     * Register a timer callback
     *
     * Same as `registerTimer!F`, except with the callback as an argument. Callback cannot accept parameters.
     */
    TimerHandle registerTimer(T)(Timeout timeout, T dg) nothrow @safe @nogc {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.closure.set(dg);
        callback.timePoint = timeout.expiry;
        callback.intervalCycles = 0;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    private TimedCallback* _registerRecurringTimer(Duration interval) nothrow @safe @nogc {
        TimedCallback* callback = timedCallbacksPool.alloc();
        callback.intervalCycles = TscTimePoint.toCycles(interval);
        rescheduleRecurringTimer(callback);
        return callback;
    }

    /**
     * registers a timer that will repeatedly trigger at set intervals.
     *
     * Params:
     *  interval = the frequency with which the callback will be called.
     *  dg = the callback to invoke
     */
    TimerHandle registerRecurringTimer(Duration interval, void delegate() dg) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(dg);
        return TimerHandle(callback);
    }

    /**
     * registers a timer that will repeatedly trigger at set intervals.
     *
     * different form of the same function.
     */
    TimerHandle registerRecurringTimer(alias F)(Duration interval, Parameters!F params) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(&F, params);
        return TimerHandle(callback);
    }

    /// Cancel a currently registered timer
    void cancelTimer(TimerHandle handle) @safe @nogc {
        if( !handle.isValid )
            return;
        timeQueue.cancel(handle.callback);
        timedCallbacksPool.release(handle.callback);
    }

    /// Suspend the current fiber for a specified amount of time
    void sleep(Duration duration) @safe @nogc {
        sleep(Timeout(duration));
    }

    /// ditto
    void sleep(Timeout until) @safe @nogc {
        assert(until != Timeout.init, "sleep argument uninitialized");
        auto timerHandle = registerTimer!resumeFiber(until, runningFiberHandle, false);
        scope(failure) cancelTimer(timerHandle);

        suspendThisFiber();
    }

    /**
     * run a function inside a different thread.
     *
     * Runs a function inside a thread. Use this function to run CPU bound processing without freezing the other fibers.
     *
     * Returns:
     * The return argument from the delegate is returned by this function.
     *
     * Throws:
     * Will throw TimeoutExpired if the timeout expires.
     *
     * Will rethrow whatever the thread throws in the waiting fiber.
     */
    auto deferToThread(alias F)(Parameters!F args) @nogc {
        DBG_ASSERT!"deferToThread called but thread deferral isn't enabled in the reactor"(optionsInEffect.threadDeferralEnabled);
        return threadPool.deferToThread!F(Timeout.infinite, args);
    }

    /// ditto
    auto deferToThread(F)(scope F dlg, Timeout timeout = Timeout.infinite) @nogc {
        DBG_ASSERT!"deferToThread called but thread deferral isn't enabled in the reactor"(optionsInEffect.threadDeferralEnabled);
        static auto glueFunction(F dlg) {
            return dlg();
        }

        return threadPool.deferToThread!glueFunction(timeout, dlg);
    }

    /**
     * forward an exception to another fiber
     *
     * This function throws an exception in another fiber. The fiber will be scheduled to run.
     *
     * There is a difference in semantics between the two forms. The first form throws an identical copy of the exception in the
     * target fiber. The second form forms a new exception to be thrown in that fiber.
     *
     * One place where this difference matters is with the stack trace the thrown exception will have. With the first form, the
     * stack trace will be the stack trace `ex` has, wherever it is (usually not in the fiber in which the exception was thrown).
     * With the second form, the stack trace will be of the target fiber, which means it will point back to where the fiber went
     * to sleep.
     */
    bool throwInFiber(FiberHandle fHandle, Throwable ex) nothrow @safe @nogc {
        ExcBuf* fiberEx = prepThrowInFiber(fHandle, false);

        if( fiberEx is null )
            return false;

        fiberEx.set(ex);
        auto fib = fHandle.get();
        resumeFiber(fib);
        return true;
    }

    /// ditto
    bool throwInFiber(T : Throwable, string file = __FILE__, size_t line = __LINE__, A...)
            (FiberHandle fHandle, auto ref A args) nothrow @safe @nogc
    {
        pragma(inline, true);
        ExcBuf* fiberEx = prepThrowInFiber(fHandle, true);

        if( fiberEx is null )
            return false;

        fiberEx.construct!T(file, line, false, args);
        auto fib = fHandle.get();
        resumeFiber(fib, true);
        return true;
    }

    /** Request that a GC collection take place ASAP
     *  Params:
     *  waitForCollection = whether to wait for the collection to finish before returning.
     */
    void requestGCCollection(bool waitForCollection = true) @safe @nogc {
        if( theReactor._stopping )
            return;

        _gcCollectionNeeded = true;
        if( theReactor.runningFiberId != MainFiberId ) {
            theReactor.resumeSpecialFiber(theReactor.mainFiber);

            if( waitForCollection )
                yieldThisFiber();
        }
    }

private:
    @property inout(ReactorFiber)* thisFiber() inout nothrow pure @safe @nogc {
        DBG_ASSERT!"No current fiber as reactor was not started"(isRunning);
        return _thisFiber;
    }

    @property bool shouldRunTimedCallbacks() nothrow @safe @nogc {
        return timeQueue.cyclesTillNextEntry(TscTimePoint.hardNow()) == 0;
    }

    void switchToNext() @safe @nogc {
        //DEBUG!"SWITCH out of %s"(thisFiber.identity);
        ASSERT!"Context switch while inside a critical section"(!isInCriticalSection);

        // in source fiber
        {
            auto now = TscTimePoint.hardNow;
            if( !thisFiber.flag!"SPECIAL" ) {
                auto fiberRunTime =  now - fiberRunStartTime;
                if( fiberRunTime >= optionsInEffect.hoggerWarningThreshold ) {
                    WARN!"#HOGGER detected: Fiber %s ran for %sms"(thisFiber.identity, fiberRunTime.total!"msecs");
                    // TODO: Add dumping of stack trace
                }
            }

            fiberRunStartTime = now;

            if (thisFiber !is mainFiber && !mainFiber.flag!"SCHEDULED" && shouldRunTimedCallbacks()) {
                resumeSpecialFiber(mainFiber);
            }
            else if (scheduledFibers.empty) {
                resumeSpecialFiber(idleFiber);
            }

            assert (!scheduledFibers.empty, "scheduledList is empty");

            auto currentFiber = thisFiber;
            if( currentFiber.state==ReactorFiber.State.Running )
                currentFiber.state = ReactorFiber.State.Sleeping;
            else {
                assert( currentFiber.state==ReactorFiber.State.Done );
                currentFiber.state = ReactorFiber.State.None;
            }

            _thisFiber = scheduledFibers.popHead();

            assert (thisFiber.flag!"SCHEDULED");
            thisFiber.flag!"SCHEDULED" = false;
            thisFiber.state = ReactorFiber.State.Running;

            if (currentFiber !is thisFiber) {
                // make the switch
                currentFiber.switchTo(thisFiber);
            }
        }

        // in destination fiber
        {
            /+
               Important note:
               Any code you place here *must* be replicated at the beginning of ReactorFiber.wrapper. Fibers launched
               for the first time do not return from `switchTo` above.
             +/

            // DEBUG!"SWITCH into %s"(thisFiber.identity);

            // This might throw, so it needs to be the last thing we do
            thisFiber.switchInto();
        }
    }

    void fiberTerminated() nothrow {
        ASSERT!"special fibers must never terminate" (!thisFiber.flag!"SPECIAL");

        freeFibers.prepend(thisFiber);

        try {
            /+if (ex) {
                mainFiber.setException(ex);
                resumeSpecialFiber(mainFiber);
            }+/
            switchToNext();
        }
        catch (Throwable ex2) {
            ERROR!"switchToNext on dead fiber failed with exception %s"(ex2.msg);
            LOG_EXCEPTION(ex2);
            assert(false);
        }
    }

    @notrace package void suspendThisFiber(Timeout timeout) @trusted @nogc {
        if (timeout == Timeout.infinite)
            return suspendThisFiber();

        ASSERT!"suspendThisFiber called while inside a critical section"(!isInCriticalSection);

        TimerHandle timeoutHandle;
        scope(exit) cancelTimer( timeoutHandle );
        bool timeoutExpired;

        if (timeout == Timeout.elapsed) {
            throw mkEx!TimeoutExpired;
        }

        static void resumer(FiberHandle fibHandle, TimerHandle* cookie, bool* timeoutExpired) nothrow @safe @nogc{
            *cookie = TimerHandle.init;
            ReactorFiber* fib = fibHandle.get;
            assert( fib !is null, "Fiber disappeared while suspended with timer" );

            // Throw TimeoutExpired only if we're the ones who resumed the fiber. this prevents a race when
            // someone else had already woken the fiber, but it just didn't get time to run while the timer expired.
            // this probably indicates fibers hogging the CPU for too long (starving others)
            *timeoutExpired = ! fib.flag!"SCHEDULED";

            /+
                    if (! *timeoutExpired)
                        fib.WARN_AS!"#REACTOR fiber resumer invoked, but fiber already scheduled (starvation): %s scheduled, %s pending"(
                                theReactor.scheduledFibers.length, theReactor.pendingFibers.length);
            +/

            theReactor.resumeFiber(fib);
        }

        timeoutHandle = registerTimer!resumer(timeout, runningFiberHandle, &timeoutHandle, &timeoutExpired);
        switchToNext();

        if( timeoutExpired )
            throw mkEx!TimeoutExpired();
    }

    package void suspendThisFiber() @safe @nogc {
         switchToNext();
    }

    void resumeSpecialFiber(ReactorFiber* fib) nothrow @safe @nogc {
        assert (fib.flag!"SPECIAL");
        assert (fib.flag!"CALLBACK_SET");
        assert (!fib.flag!"SCHEDULED" || scheduledFibers.head is fib);

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            scheduledFibers.prepend(fib);
        }
    }

    package void resumeFiber(FiberHandle handle, bool immediate = false) nothrow @safe @nogc {
        resumeFiber(handle.get(), immediate);
    }

    void resumeFiber(ReactorFiber* fib, bool immediate = false) nothrow @safe @nogc {
        assert (!fib.flag!"SPECIAL");
        ASSERT!"resumeFiber called on %s, which does not have a callback set"(fib.flag!"CALLBACK_SET", fib.identity);

        if (!fib.flag!"SCHEDULED") {
            if (fib._owner !is null) {
                // Whatever this fiber was waiting to do, it is no longer what it needs to be doing
                fib._owner.remove(fib);
            }
            fib.flag!"SCHEDULED" = true;
            if (immediate) {
                scheduledFibers.prepend(fib);
            }
            else {
                scheduledFibers.append(fib);
            }
        }
    }

    ReactorFiber* _spawnFiber(bool immediate) nothrow @safe @nogc {
        ASSERT!"No more free fibers in pool"(!freeFibers.empty);
        auto fib = freeFibers.popHead();
        assert (!fib.flag!"CALLBACK_SET");
        fib.flag!"CALLBACK_SET" = true;
        fib.state = ReactorFiber.State.Sleeping;
        fib._prevId = FiberId.invalid;
        fib._nextId = FiberId.invalid;
        fib._owner = null;
        fib.params.flsBlock.reset();
        resumeFiber(fib, immediate);
        return fib;
    }

    void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            end = start = TscTimePoint.hardNow;

            while (scheduledFibers.empty) {
                //enterCriticalSection();
                //scope(exit) leaveCriticalSection();
                end = TscTimePoint.hardNow;
                /*
                   Since we've updated "end" before calling the timers, these timers won't count as idle time, unless....
                   after running them the scheduledFibers list is still empty, in which case they do.
                 */
                if( runTimedCallbacks(end) )
                    continue;

                // We only reach here if runTimedCallbacks did nothing, in which case "end" is recent enough
                Duration sleepDuration = timeQueue.timeTillNextEntry(end);
                if( idleCallbacks.length==1 ) {
                    //DEBUG!"idle callback called with duration %s"(sleepDuration);
                    idleCallbacks[0](sleepDuration);
                } else if ( idleCallbacks.length>1 ) {
                    foreach(cb; idleCallbacks) {
                        cb(ZERO_DURATION);
                    }
                } else {
                    DEBUG!"Idle fiber called with no callbacks, sleeping %sus"(sleepDuration.total!"usecs");
                    import core.thread; Thread.sleep(sleepDuration);
                }
            }
            idleCycles += end.diff!"cycles"(start);
            switchToNext();
        }
    }

    @notrace bool runTimedCallbacks(TscTimePoint now = TscTimePoint.hardNow) {
        // Timer callbacks are not allowed to sleep
        auto criticalSectionContainer = criticalSection();

        bool ret;

        TimedCallback* callback;
        while ((callback = timeQueue.pop(now)) !is null) {
            callback.closure();
            if( callback.intervalCycles==0 )
                timedCallbacksPool.release(callback);
            else
                rescheduleRecurringTimer(callback);

            ret = true;
        }

        return ret;
    }

    void rescheduleRecurringTimer(TimedCallback* callback) nothrow @safe @nogc {
        ulong cycles = TscTimePoint.hardNow.cycles + callback.intervalCycles;
        cycles -= cycles % callback.intervalCycles;
        callback.timePoint = TscTimePoint(cycles);

        timeQueue.insert(callback);
    }

    ExcBuf* prepThrowInFiber(FiberHandle fHandle, bool updateBT, bool specialOkay = false) nothrow @safe @nogc {
        ReactorFiber* fib = fHandle.get();
        ASSERT!"Cannot throw in the reactor's own fibers"( !fib.flag!"SPECIAL" || specialOkay );
        if( fib is null ) {
            WARN!"Failed to throw exception in fiber %s which is no longer valid"(fHandle);
            return null;
        }

        if( fib.flag!"HAS_EXCEPTION" ) {
            ERROR!"Tried to throw exception in fiber %s which already has an exception pending"(fHandle);
            return null;
        }

        fib.flag!"HAS_EXCEPTION" = true;
        fib.flag!"EXCEPTION_BT" = updateBT;
        return &fib.params.currExcBuf;
    }

    void forwardExceptionToMain(Throwable ex) nothrow @trusted @nogc {
        ExcBuf* fiberEx = prepThrowInFiber(FiberHandle(mainFiber), false, true);

        if( fiberEx is null )
            return;

        fiberEx.set(ex);
        resumeSpecialFiber(mainFiber);
        as!"nothrow"(&theReactor.switchToNext);
        assert(false, "switchToNext on dead system returned");
    }

    void registerHangDetector() @trusted @nogc {
        DBG_ASSERT!"registerHangDetector called twice"( hangDetectorSig == OSSignal.SIGNONE );
        hangDetectorSig = cast(OSSignal)SIGRTMIN;
        scope(failure) hangDetectorSig = OSSignal.init;

        posix_signal.sigaction_t sa;
        sa.sa_flags = posix_signal.SA_RESTART | posix_signal.SA_ONSTACK | posix_signal.SA_SIGINFO;
        sa.sa_sigaction = &hangDetectorHandler;
        errnoEnforceNGC(posix_signal.sigaction(hangDetectorSig, &sa, null) == 0, "sigaction() for registering hang detector signal failed");
        scope(failure) posix_signal.signal(hangDetectorSig, posix_signal.SIG_DFL);

        enum SIGEV_THREAD_ID = 4;
        // SIGEV_THREAD_ID (Linux-specific)
        // As  for  SIGEV_SIGNAL, but the signal is targeted at the thread whose ID is given in sigev_notify_thread_id,
        // which must be a thread in the same process as the caller.  The sigev_notify_thread_id field specifies a kernel
        // thread ID, that is, the value returned by clone(2) or gettid(2).  This flag is intended only for use by
        // threading libraries.

        sigevent sev;
        sev.sigev_notify = SIGEV_THREAD_ID;
        sev.sigev_signo = hangDetectorSig;
        sev.sigev_value.sival_ptr = &hangDetectorTimerId;
        sev._sigev_un._tid = gettid();

        errnoEnforceNGC(posix_time.timer_create(posix_time.CLOCK_MONOTONIC, &sev, &hangDetectorTimerId) == 0,
                "timer_create for hang detector");
        ASSERT!"hangDetectorTimerId is null"(hangDetectorTimerId !is posix_time.timer_t.init);
        scope(failure) posix_time.timer_delete(hangDetectorTimerId);

        posix_time.itimerspec its;

        enum TIMER_GRANULARITY = 4; // Number of wakeups during the monitored period
        Duration threshold = optionsInEffect.hangDetectorTimeout / TIMER_GRANULARITY;
        threshold.split!("seconds", "nsecs")(its.it_value.tv_sec, its.it_value.tv_nsec);
        its.it_interval = its.it_value;
        INFO!"Hang detector will wake up every %s seconds and %s nsecs"(its.it_interval.tv_sec, its.it_interval.tv_nsec);

        errnoEnforceNGC(posix_time.timer_settime(hangDetectorTimerId, 0, &its, null) == 0, "timer_settime");
    }

    void deregisterHangDetector() nothrow @trusted @nogc {
        if( hangDetectorSig is OSSignal.SIGNONE )
            return; // Hang detector was not initialized

        posix_time.timer_delete(hangDetectorTimerId);
        posix_signal.signal(hangDetectorSig, posix_signal.SIG_DFL);
        hangDetectorSig = OSSignal.init;
    }

    extern(C) static void hangDetectorHandler(int signum, siginfo_t* info, void *ctx) nothrow @trusted @nogc {
        auto now = TscTimePoint.hardNow();
        auto delay = now - theReactor.fiberRunStartTime;

        if( delay<theReactor.optionsInEffect.hangDetectorTimeout || theReactor.runningFiberId == IdleFiberId )
            return;

        long seconds, usecs;
        delay.split!("seconds", "usecs")(seconds, usecs);

        ERROR!"Hang detector triggered for %s after %s.%06s seconds"(theReactor.runningFiberId, seconds, usecs);
        dumpStackTrace();

        ABORT("Hang detector killed process");
    }

    void registerFaultHandlers() @trusted @nogc {
        posix_signal.sigaction_t action;
        action.sa_sigaction = &faultHandler;
        action.sa_flags = posix_signal.SA_SIGINFO | posix_signal.SA_RESETHAND | posix_signal.SA_ONSTACK;

        errnoEnforceNGC( posix_signal.sigaction(OSSignal.SIGSEGV, &action, null)==0, "Failed to register SIGSEGV handler" );
        errnoEnforceNGC( posix_signal.sigaction(OSSignal.SIGILL, &action, null)==0, "Failed to register SIGILL handler" );
        errnoEnforceNGC( posix_signal.sigaction(OSSignal.SIGBUS, &action, null)==0, "Failed to register SIGBUS handler" );
    }

    void deregisterFaultHandlers() nothrow @trusted @nogc {
        posix_signal.signal(OSSignal.SIGBUS, posix_signal.SIG_DFL);
        posix_signal.signal(OSSignal.SIGILL, posix_signal.SIG_DFL);
        posix_signal.signal(OSSignal.SIGSEGV, posix_signal.SIG_DFL);
    }

    @notrace extern(C) static void faultHandler(int signum, siginfo_t* info, void* ctx) nothrow @trusted @nogc {
        OSSignal sig = cast(OSSignal)signum;
        string faultName;

        switch(sig) {
        case OSSignal.SIGSEGV:
            faultName = "Segmentation fault";
            break;
        case OSSignal.SIGILL:
            faultName = "Illegal instruction";
            break;
        case OSSignal.SIGBUS:
            faultName = "Bus error";
            break;
        default:
            faultName = "Unknown fault";
            break;
        }

        ERROR!"#OSSIGNAL %s"(faultName);
        dumpStackTrace();
        flushLog(); // There is a certain chance the following lines themselves fault. Flush the logs now so that we have something

        posix_ucontext.ucontext_t* contextPtr = cast(posix_ucontext.ucontext_t*)ctx;
        auto pc = contextPtr ? contextPtr.uc_mcontext.gregs[posix_ucontext.REG_RIP] : 0;

        if( isReactorThread ) {
            auto onStackParams = theReactor.runningFiberPtr.params;
            ERROR!"%s on %s address 0x%x, PC 0x%x stack params at 0x%x"(faultName, theReactor.runningFiberId, info.si_addr, pc,
                    onStackParams);
            ERROR!"Stack is at [%s .. %s]"( onStackParams.stackDescriptor.bstack, onStackParams.stackDescriptor.tstack );
            auto guardAddrStart = onStackParams.stackDescriptor.bstack - GUARD_ZONE_SIZE;
            if( info.si_addr < onStackParams.stackDescriptor.bstack && info.si_addr >= guardAddrStart ) {
                ERROR!"Hit stack guard area"();
            }
        } else {
            ERROR!"%s on OS thread at address %s, PC %s"(faultName, info.si_addr, pc);
        }
        flushLog();

        // Exit the fault handler, which will re-execute the offending instruction. Since we registered as run once, the default handler
        // will then kill the node.
    }

    void mainloop() {
        assert (isOpen);
        assert (!isRunning);
        assert (_thisFiber is null);

        _running = true;
        GC.disable();
        scope(exit) GC.enable();

        if( optionsInEffect.utGcDisabled ) {
            // GC is disabled during the reactor run. Run it before we start
            GC.collect();
        }

        // Don't register the hang detector until after we've finished running the GC
        if( optionsInEffect.hangDetectorTimeout !is Duration.zero )
            registerHangDetector();

        scope(exit) {
            if( optionsInEffect.hangDetectorTimeout !is Duration.zero )
                deregisterHangDetector();
        }

        _thisFiber = mainFiber;
        scope(exit) _thisFiber = null;

        if( !optionsInEffect.utGcDisabled )
            TimerHandle gcTimer = registerRecurringTimer!requestGCCollection(optionsInEffect.gcInterval, false);

        try {
            while (!_stopping) {
                DBG_ASSERT!"Switched to mainloop with wrong thisFiber %s"(thisFiber is mainFiber, thisFiber.identity);
                runTimedCallbacks();
                if( _gcCollectionNeeded ) {
                    _gcCollectionNeeded = false;
                    TscTimePoint.hardNow(); // Update the hard now value
                    INFO!"#GC collection cycle started"();
                    GC.collect();
                    TscTimePoint.hardNow(); // Update the hard now value
                    INFO!"#GC collection cycle ended"();
                }

                if( !_stopping )
                    switchToNext();
            }
        } catch( ReactorExit ex ) {
            ASSERT!"Main loop threw ReactorExit, but reactor is not stopping"(_stopping);
        }

        performStopReactor();
    }

    void performStopReactor() @nogc {
        ASSERT!"performStopReactor must be called from the main fiber. Use Reactor.stop instead"( isMain );

        Throwable reactorExit = mkEx!ReactorExit("Reactor is quitting");
        foreach(ref fiber; allFibers[1..$]) { // All fibers but main
            if( fiber.state == ReactorFiber.State.Sleeping ) {
                fiber.flag!"SPECIAL" = false;
                throwInFiber(FiberHandle(&fiber), reactorExit);
            }
        }

        thisFiber.flag!"SPECIAL" = false;
        yieldThisFiber();

        META!"Stopping reactor"();
        _running = false;
        _stopping = false;
    }
}

// Expose the conversion to/from ReactorFiber only to the reactor package
package ReactorFiber* to(T : ReactorFiber*)(FiberId fid) nothrow @safe @nogc {
    if (!fid.isValid)
        return null;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    return &theReactor.allFibers[fid.value];
}

package FiberId to(T : FiberId)(const ReactorFiber* rfp) nothrow @safe @nogc {
    if (rfp is null)
        return FiberId.invalid;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    auto idx = rfp - &theReactor.allFibers.arr[0];
    DBG_ASSERT!"Reactor fiber pointer not pointing to fibers pool: base %s ptr %s idx %s"(idx>=0 && idx<theReactor.allFibers.arr.length,
            &theReactor.allFibers.arr[0], rfp, idx);
    return FiberId( cast(ushort)idx );
}

private __gshared Reactor _theReactor;
private bool /* thread local */ _isReactorThread;

/**
 * return a reference to the Reactor singleton
 *
 * In theory, @safe code must not access global variables. Since theReactor is only meant to be used by a single thread, however, this
 * function is @trusted. If it were not, practically no code could be @safe.
 */
@property ref Reactor theReactor() nothrow @trusted @nogc {
    //DBG_ASSERT!"not main thread"(_isReactorThread);
    return _theReactor;
}

/// Returns whether the current thread is the thread in which theReactor is running
@property bool isReactorThread() nothrow @safe @nogc {
    return _isReactorThread;
}

version (unittest) {
    void testWithReactor(void delegate() dg, Reactor.OpenOptions options = Reactor.OpenOptions.init) {
        sigset_t emptyMask;
        errnoEnforceNGC( sigprocmask( SIG_SETMASK, &emptyMask, null )==0, "sigprocmask failed" );

        theReactor.setup(options);
        scope(success) theReactor.teardown();

        bool succ = false;

        void wrapper() {
            scope(success) {
                succ = true;
                theReactor.stop();
            }
            dg();
        }

        theReactor.spawnFiber(&wrapper);
        theReactor.start();
        assert (succ);
    }

    public import mecca.runtime.ut: mecca_ut;

    mixin template TEST_FIXTURE_REACTOR(FIXTURE) {
        import mecca.runtime.ut: runFixtureTestCases;
        unittest {
            testWithReactor({
                    runFixtureTestCases!(FIXTURE)();
                    });
        }
    }
}


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
    theReactor.start();
}

unittest {
    // Test simple timeout
    import std.stdio;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    uint counter;
    TscTimePoint start;

    void fiberFunc(Duration duration) {
        INFO!"Fiber %s sleeping for %s"(theReactor.runningFiberHandle, duration.toString);
        theReactor.sleep(duration);
        auto now = TscTimePoint.hardNow;
        counter++;
        INFO!"Fiber %s woke up after %s, overshooting by %s counter is %s"(theReactor.runningFiberHandle, (now - start).toString,
                ((now-start) - duration).toString, counter);
    }

    void ender() {
        INFO!"Fiber %s ender is sleeping for 250ms"(theReactor.runningFiberHandle);
        theReactor.sleep(dur!"msecs"(250));
        INFO!"Fiber %s ender woke up"(theReactor.runningFiberHandle);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(10));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(100));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(150));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(20));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(30));
    theReactor.spawnFiber(&fiberFunc, dur!"msecs"(200));
    theReactor.spawnFiber(&ender);

    start = TscTimePoint.hardNow;
    theReactor.start();
    auto end = TscTimePoint.hardNow;
    INFO!"UT finished in %s"((end - start).toString);

    assert(counter == 6, "Not all fibers finished");
}

unittest {
    // Test suspending timeout
    import std.stdio;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    void fiberFunc() {
        bool thrown;

        try {
            theReactor.suspendThisFiber( Timeout(dur!"msecs"(4)) );
        } catch(TimeoutExpired ex) {
            thrown = true;
        }

        assert(thrown);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc);
    theReactor.start();
}

unittest {
    // Test suspending timeout
    import std.stdio;

    // GC running during the test mess with the timing
    Reactor.OpenOptions oo;
    oo.utGcDisabled = true;

    theReactor.setup(oo);
    scope(exit) theReactor.teardown();

    void fiberFunc() {
        TimerHandle[8] handles;
        Duration[8] timeouts = [
            dur!"msecs"(2),
            dur!"msecs"(200),
            dur!"msecs"(6),
            dur!"msecs"(120),
            dur!"msecs"(37),
            dur!"msecs"(40),
            dur!"msecs"(133),
            dur!"msecs"(8),
        ];

        ubyte a;

        static void timer(ubyte* a, TimerHandle* handle, ubyte bit) {
            (*a) |= 1<<bit;

            (*handle) = TimerHandle.init;
        }

        foreach(ubyte i, duration; timeouts) {
            handles[i] = theReactor.registerTimer!timer( Timeout(duration), &a, &handles[i], i );
        }

        uint recurringCounter;
        static void recurringTimer(uint* counter) {
            (*counter)++;
        }

        TimerHandle recurringTimerHandle = theReactor.registerRecurringTimer!recurringTimer( dur!"msecs"(7), &recurringCounter );

        theReactor.sleep(dur!"msecs"(3));

        // Cancel one expired timeout and one yet to happen
        theReactor.cancelTimer(handles[0]);
        theReactor.cancelTimer(handles[6]);

        // Wait for all timers to run
        theReactor.sleep(dur!"msecs"(200));

        assert(a == 0b1011_1111);
        ASSERT!"Recurring timer should run 29 times, ran %s"(recurringCounter==29 || recurringCounter==30, recurringCounter); // 203ms / 7

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberFunc);
    theReactor.start();
}

unittest {
    import mecca.reactor.sync.event;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    Event evt1, evt2;

    class TheException : Exception {
        this() {
            super("The Exception");
        }
    }

    void fib2() {
        // Release 1
        evt1.set();

        try {
            // Wait for 1 to do its stuff
            evt2.wait();

            assert( false, "Exception not thrown" );
        } catch( Exception ex ) {
            assert( ex.msg == "The Exception" );
        }

        theReactor.stop();
    }

    void fib1() {
        auto fib = theReactor.spawnFiber(&fib2);

        evt1.wait();

        theReactor.throwInFiber(fib, new TheException);
        evt2.set();
    }

    theReactor.spawnFiber(&fib1);
    theReactor.start();
}

unittest {
    Reactor.OpenOptions options;
    options.hangDetectorTimeout = 20.msecs;
    options.utGcDisabled = true;
    DEBUG!"sanity: %s"(options.hangDetectorTimeout.toString);

    testWithReactor({
            theReactor.sleep(200.msecs);
            /+
            // To trigger the hang, uncomment this:
            import core.thread;
            Thread.sleep(200.msecs);
            +/
            }, options);
}

/+
unittest {
    // Trigger a segmentation fault
    theReactor.options.hangDetectorTimeout = 20.msecs;
    DEBUG!"sanity: %s"(theReactor.options.hangDetectorTimeout);

    testWithReactor({
            int* a = cast(int*) 16;
            *a = 3;
            });
}
+/

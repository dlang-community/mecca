/// Define the micro-threading reactor
module mecca.reactor;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

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

import mecca.containers.arrays;
import mecca.containers.lists;
import mecca.containers.pools;
import mecca.lib.concurrency;
import mecca.lib.consts;
import mecca.lib.exception;
import mecca.lib.integers : bitsInValue, createBitMask;
import mecca.lib.memory;
import mecca.lib.reflection;
import mecca.lib.time;
import mecca.lib.time_queue;
import mecca.lib.typedid;
import mecca.log;
import mecca.log.impl;
import mecca.platform.os;
import mecca.reactor.fiber_group;
import mecca.reactor.fls;
import mecca.reactor.impl.fibril: Fibril;
import mecca.reactor.subsystems.threading;
import mecca.reactor.sync.event: Signal;
public import mecca.reactor.types;

import std.stdio;

/// Handle for manipulating registered timers.
alias TimerHandle = Reactor.TimerHandle;
alias FiberIncarnation = ushort;

// The slot number in the stacks for the fiber
private alias FiberIdx = AlgebraicTypedIdentifier!("FiberIdx", ushort, ushort.max, ushort.max);

/// Track the fiber's state
enum FiberState : ubyte {
    None,       /// Fiber isn't running
    Starting,   /// Fiber was spawned, but have not yet started running
    Scheduled,  /// Fiber is waiting to run
    Running,    /// Fiber is running
    Sleeping,   /// Fiber is currently suspended
    Done,       /// Fiber has finished running
}

private {
    extern(C) void* _d_eh_swapContext(void* newContext) nothrow @nogc;
    extern(C) void* _d_eh_swapContextDwarf(void* newContext) nothrow @nogc;
}

struct ReactorFiber {
    // Prevent accidental copying
    @disable this(this);

    static struct OnStackParams {
        Closure                 fiberBody;
        union {
            DRuntimeStackDescriptor  _stackDescriptor;
            DRuntimeStackDescriptor* stackDescriptorPtr;
        }
        FiberGroup.Chain        fgChain;
        FLSArea                 flsBlock;
        ExcBuf                  currExcBuf;
        LogsFiberSavedContext   logsSavedContext;
        string                  fiberName;              // String identifying what this fiber is doing
        void*                   fiberPtr;               // The same with a numerical value
        Signal                  joinWaiters;
    }
    enum Flags: ubyte {
        // XXX Do we need CALLBACK_SET?
        CALLBACK_SET   = 0x01,  /// Has callback set
        SPECIAL        = 0x02,  /// Special fiber. Not a normal user fiber
        MAIN           = 0x04,  /// This is the main fiber (i.e. - the "not a fiber")
        SCHEDULED      = 0x08,  /// Fiber currently scheduled to be run
        SLEEPING       = 0x10,  /// Fiber is sleeping on a sync object
        HAS_EXCEPTION  = 0x20,  /// Fiber has pending exception to be thrown in it
        EXCEPTION_BT   = 0x40,  /// Fiber exception needs to have fiber's backtrace
        PRIORITY       = 0x80,  /// Fiber is a high priority one
    }

align(1):
    Fibril                                      fibril;
    OnStackParams*                              params;
    LinkedListWithOwner!(ReactorFiber*)*        _owner;
    FiberIdx                                    _nextId;
    FiberIdx                                    _prevId;
    FiberIncarnation                            incarnationCounter;
    ubyte                                       _flags;
    FiberState                                  _state;
    static extern(C) void* function(void*) @nogc nothrow _swapEhContext = &swapEhContextChooser;

    // We define this struct align(1) for the sole purpose of making the following static assert verify what it's supposed to
    static assert (this.sizeof == 32);  // keep it small and cache-line friendly

    // LinkedQueue access through property
    @property ReactorFiber* _next() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_nextId);
    }

    @property void _next(FiberIdx newNext) nothrow @safe @nogc {
        _nextId = newNext;
    }

    @property void _next(ReactorFiber* newNext) nothrow @safe @nogc {
        _nextId = to!FiberIdx(newNext);
    }

    @property ReactorFiber* _prev() const nothrow @safe @nogc {
        return to!(ReactorFiber*)(_prevId);
    }

    @property void _prev(FiberIdx newPrev) nothrow @safe @nogc {
        _prevId = newPrev;
    }

    @property void _prev(ReactorFiber* newPrev) nothrow @safe @nogc {
        _prevId = to!FiberIdx(newPrev);
    }

    @notrace void setup(void[] stackArea, bool main) nothrow @nogc {
        _flags = 0;

        if( !main )
            fibril.set(stackArea[0 .. $ - OnStackParams.sizeof], &wrapper);
        else
            flag!"MAIN" = true;

        params = cast(OnStackParams*)&stackArea[$ - OnStackParams.sizeof];
        setToInit(params);

        if( !main ) {
            params._stackDescriptor.bstack = stackArea.ptr + stackArea.length; // Include params, as FLS is stored there
            params._stackDescriptor.tstack = fibril.rsp;
            params._stackDescriptor.add();
        } else {
            import core.thread: Thread;
            params.stackDescriptorPtr = cast(DRuntimeStackDescriptor*)accessMember!("m_curr")(Thread.getThis());
            DBG_ASSERT!"MAIN not set on main fiber"( flag!"MAIN" );
        }

        _next = null;
        incarnationCounter = 0;
    }

    @notrace void teardown() nothrow @nogc {
        fibril.reset();
        if (!flag!"MAIN") {
            params._stackDescriptor.remove();
        }
        params = null;
    }

    @notrace void switchTo(ReactorFiber* next) nothrow @trusted @nogc {
        pragma(inline, true);
        import core.thread: Thread;

        DRuntimeStackDescriptor* currentSD = stackDescriptor;
        DRuntimeStackDescriptor* nextSD = next.stackDescriptor;

        currentSD.ehContext = _swapEhContext(nextSD.ehContext);

        // Since druntime does not expose the interfaces needed for switching fibers, we need to hack around the
        // protection system to access Thread.m_curr, which is private.
        DRuntimeStackDescriptor** threadCurrentSD = cast(DRuntimeStackDescriptor**)&accessMember!("m_curr")(Thread.getThis());
        *threadCurrentSD = nextSD;

        fibril.switchTo(next.fibril, &currentSD.tstack);
    }

    @notrace @property private DRuntimeStackDescriptor* stackDescriptor() @trusted @nogc nothrow {
        if( !flag!"MAIN" ) {
            return &params._stackDescriptor;
        } else {
            return params.stackDescriptorPtr;
        }
    }

    @property FiberId identity() const nothrow @safe @nogc {
        FiberId.UnderlyingType res;
        res = to!FiberIdx(&this).value;
        res |= incarnationCounter << theReactor.maxNumFibersBits;

        return FiberId(res);
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

    @property FiberState state() pure const nothrow @safe @nogc {
        return _state;
    }

    @property void state(FiberState newState) nothrow @safe @nogc {
        DBG_ASSERT!"%s trying to switch state from %s to %s, but histogram claims no fibers in this state. %s"(
                theReactor.stats.fibersHistogram[_state]>0, identity, _state, newState,
                theReactor.stats.fibersHistogram );

        theReactor.stats.fibersHistogram[_state]--;
        theReactor.stats.fibersHistogram[newState]++;

        _state = newState;
    }

    @property bool isAlive() const pure nothrow @safe @nogc {
        with(FiberState) switch( state ) {
        case None:
            return false;
        case Done:
            assert(false, "Fiber is in an invalid state Done");
        default:
            return true;
        }
    }

private:
    @notrace void wrapper() nothrow {
        bool skipBody;
        Throwable ex = null;

        try {
            // Nobody else will run it the first time the fiber is started. This results in some unfortunate
            // code duplication
            switchInto();
        } catch (FiberInterrupt ex2) {
            INFO!"Fiber %s killed by FiberInterrupt exception: %s"(identity, ex2.msg);
            skipBody = true;
        } catch(Throwable ex2) {
            ex = ex2;
            skipBody = true;
        }

        while (true) {
            DBG_ASSERT!"skipBody=false with pending exception"(ex is null || skipBody);
            scope(exit) ex = null;

            if( !skipBody ) {
                params.logsSavedContext = LogsFiberSavedContext.init;
                INFO!"Fiber %s started generation %s flags=0x%0x"(identity, incarnationCounter, _flags);

                ASSERT!"Reactor's current fiber isn't the running fiber" (theReactor.thisFiber is &this);
                ASSERT!"Fiber %s is in state %s instead of Running" (state == FiberState.Running, identity, state);

                try {
                    // Perform the actual fiber callback
                    params.fiberBody();
                } catch (FiberInterrupt ex2) {
                    INFO!"Fiber %s killed by FiberInterrupt exception: %s"(identity, ex2.msg);
                } catch (Throwable ex2) {
                    ex = ex2;
                }
            }

            ASSERT!"Fiber still member of fiber group at termination" (params.fgChain.owner is null);

            params.joinWaiters.signal();
            if( ex is null ) {
                INFO!"Fiber %s finished"(identity);
            } else {
                ERROR!"Fiber %s finished with exception: %s"(identity, ex.msg);
                LOG_EXCEPTION(ex);
            }

            params.fiberBody.clear();
            params.fiberName = null;
            params.fiberPtr = null;
            flag!"CALLBACK_SET" = false;
            ASSERT!"Fiber %s state is %s instead of Running at end of execution"(
                    state == FiberState.Running, identity, state);
            state = FiberState.Done;
            incarnationCounter++;
            if (ex !is null) {
                theReactor.forwardExceptionToMain(ex);
                assert(false);
            } else {
                skipBody = theReactor.fiberTerminated();
            }
        }
    }

    void switchInto() @safe @nogc {
        // We might have a cross fiber hook. If we do, we need to repeat this part several times
        bool switched = false;
        do {
            switchCurrExcBuf( &params.currExcBuf );
            if (!flag!"SPECIAL") {
                params.flsBlock.switchTo();
            } else {
                FLSArea.switchToNone();
            }
            logSwitchInto();

            if( theReactor.crossFiberHook !is null ) {
                theReactor.performCrossFiberHook();
            } else {
                switched = true;
            }
        } while(!switched);

        if (flag!"HAS_EXCEPTION") {
            Throwable ex = params.currExcBuf.get();
            ASSERT!"Fiber has exception, but exception is null"(ex !is null);
            if (flag!"EXCEPTION_BT") {
                params.currExcBuf.setTraceback(ex);
                flag!"EXCEPTION_BT" = false;
            }

            flag!"HAS_EXCEPTION" = false;
            throw ex;
        }
    }

    void logSwitchInto() nothrow @safe @nogc{
        logSwitchFiber(&params.logsSavedContext, cast( Parameters!logSwitchFiber[1] )identity.value);
    }

private:
    static extern(C) void* swapEhContextChooser(void * newContext) @nogc nothrow @notrace {
        DBG_ASSERT!"Context is not null on first invocation"(newContext is null);
        void* std = _d_eh_swapContext(newContext);
        void* dwarf = _d_eh_swapContextDwarf(newContext);

        if( std !is null ) {
            _swapEhContext = &_d_eh_swapContext;
            return std;
        } else if( dwarf !is null ) {
            _swapEhContext = &_d_eh_swapContextDwarf;
            return dwarf;
        }

        // Cannot tell which is correct yet
        return null;
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
    /// Returns whether the handle was set
    ///
    /// Unlike `isValid`, this does not check whether the handle is still valid. It only returns whether the handle
    /// is in initialized state.
    @property bool isSet() pure const nothrow @safe @nogc {
        return identity.isValid;
    }

    /// Returns whether the handle currently describes a running fiber.
    @property bool isValid() const nothrow @safe @nogc {
        return get() !is null;
    }

    /// the `FiberId` described by the handle. If the handle is no longer valid, will return FiberId.invalid
    ///
    /// Use `getFiberId` if you want the `FiberId` of a no-longer valid handle.
    @property FiberId fiberId() const nothrow @safe @nogc {
        if( isValid )
            return identity;

        return FiberId.invalid;
    }

    /// returns the original `FiberId` set for the handle, whether still valid or not
    FiberId getFiberId() const nothrow @safe @nogc pure {
        return identity;
    }

    /// Reset the handle to uninitialized state
    @notrace void reset() nothrow @safe @nogc {
        this = FiberHandle.init;
    }

package:
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

    ReactorFiber* get() const nothrow @safe @nogc {
        if (!theReactor.isRunning)
            return null;

        if (!identity.isValid) {
            return null;
        }

        ReactorFiber* fiber = &theReactor.allFibers[to!FiberIdx(identity).value];

        DBG_ASSERT!"Fiber state is transient state Done"(fiber.state != FiberState.Done);
        if(fiber.state == FiberState.None || fiber.incarnationCounter != incarnation) {
            return null;
        }

        return fiber;
    }
}

/**
  The main scheduler for the micro-threading architecture.
 */
struct Reactor {
    // Prevent accidental copying
    @disable this(this);

    /// Delegates passed to `registerIdleCallback` must be of this signature
    alias IdleCallbackDlg = bool delegate(Duration);

    /// The options control aspects of the reactor's operation
    struct OpenOptions {
        /// Maximum number of fibers.
        ushort   numFibers = 256;
        /// Stack size of each fiber (except the main fiber). The reactor will allocate numFiber*fiberStackSize during startup
        size_t   fiberStackSize = 32*KB;
        /**
          How often does the GC's collection run.

          The reactor uses unconditional periodic collection, rather than lazy evaluation one employed by the default GC
          settings. This setting sets how often the collection cycle should run. See `gcRunThreshold` for how to not
          run the GC collection when not needed.
         */
        Duration gcInterval = 30.seconds;

        /**
         * Allocation threshold to trigger a GC run
         *
         * If the amount of memory allocated since the previous GC run is less than this amount of bytes, the GC scan
         * will be skipped.
         *
         * Setting this value to 0 forces a run every `gcInterval`, regardless of how much was allocated.
         */
        size_t gcRunThreshold = 16*MB;

        /**
          Base granularity of the reactor's timer.

          Any scheduled task is scheduled at no better accuracy than timerGranularity. $(B In addition to) the fact that
          a timer task may be delayed. As such, with a 1ms granularity, a task scheduled for 1.5ms from now is the same
          as a task scheduled for 2ms from now, which may run 3ms from now.
         */
        Duration timerGranularity = 1.msecs;
        /**
          Hogger detection threshold.

          A hogger is a fiber that does not release the CPU to run other tasks for a long period of time. Often, this is
          a result of a bug (i.e. - calling the OS's `sleep` instead of the reactor's).

          Hogger detection works by measuring how long each fiber took until it allows switching away. If the fiber took
          more than hoggerWarningThreshold, a warning is logged.
         */
        Duration hoggerWarningThreshold = 200.msecs;
        /**
         Maximum desired fiber run time

         A fiber should aim not to run more than this much time without a voluntary context switch. This value affects
         the `shouldYield` and `considerYield` calls.
         */
        Duration maxDesiredRunTime = 150.msecs;
        /**
          Hard hang detection.

          This is a similar safeguard to that used by the hogger detection. If activated (disabled by default), it
          premptively prompts the reactor every set time to see whether fibers are still being switched in/out. If it
          finds that the same fiber is running, without switching out, for too long, it terminates the entire program.
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

        /**
          Whether the reactor should register the default (fd processing) idle handler

          If this value is set to `false`, the poller is still opened. It's idle function would not be automatically
          called, however, so file operations might block indefinitely unless another mechanism (such as timer based)
          is put in place to call it periodically.

          The non-registered idle handler can be manually triggered by calling `epoller.poll`.
         */
        bool registerDefaultIdler = true;

        version(unittest) {
            /// Disable all GC collection during the reactor run time. Only available for UTs.
            bool utGcDisabled;
        } else {
            private enum utGcDisabled = false;
        }
    }

    /// Used by `reportStats` to report statistics about the reactor
    struct Stats {
        ulong[FiberState.max+1] fibersHistogram;        /// Total number of user fibers in each `FiberState`
        ulong numContextSwitches;                       /// Number of time we switched between fibers
        ulong idleCycles;                               /// Total number of idle cycles

        /// Returns number of currently used fibers
        @property ulong numUsedFibers() pure const nothrow @safe @nogc {
            ulong ret;

            with(FiberState) {
                foreach( state; [Starting, Scheduled, Running, Sleeping]) {
                    ret += fibersHistogram[state];
                }
            }

            return ret;
        }

        /// Returns number of fibers available to be run
        @property ulong numFreeFibers() pure const nothrow @safe @nogc {
            ulong ret;

            with(FiberState) {
                foreach( state; [None]) {
                    ret += fibersHistogram[state];
                }

                DBG_ASSERT!"%s fibers in Done state. Should be 0"(fibersHistogram[Done] == 0, fibersHistogram[Done]);
            }

            return ret;
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
    bool _gcCollectionForce;
    bool _hangDetectorEnabled;
    ubyte maxNumFibersBits;     // Number of bits sufficient to represent the maximal number of fibers
    bool nothingScheduled; // true if there is no scheduled fiber
    enum HIGH_PRIORITY_SCHEDULES_RATIO = 2; // How many high priority schedules before shceduling a low priority fiber
    ubyte highPrioritySchedules; // Number of high priority schedules done
    FiberIdx.UnderlyingType maxNumFibersMask;
    int reactorReturn;
    int criticalSectionNesting;
    OpenOptions optionsInEffect;
    Stats stats;
    GC.Stats lastGCStats;

    MmapBuffer fiberStacks;
    MmapArray!ReactorFiber allFibers;
    LinkedQueueWithLength!(ReactorFiber*) freeFibers;
    enum FiberPriorities { NORMAL, HIGH, IMMEDIATE };
    LinkedListWithOwner!(ReactorFiber*) scheduledFibersNormal, scheduledFibersHigh, scheduledFibersImmediate;

    ReactorFiber* _thisFiber;
    ReactorFiber* mainFiber;
    ReactorFiber* idleFiber;
    FixedArray!(IdleCallbackDlg, MAX_IDLE_CALLBACKS) idleCallbacks;
    // Point to idleCallbacks as a range, in case it gets full and we need to spill over to GC allocation
    IdleCallbackDlg[] actualIdleCallbacks;
    __gshared Timer hangDetectorTimer;

    SignalHandlerValue!TscTimePoint fiberRunStartTime;
    void delegate() nothrow @nogc @safe crossFiberHook;
    FiberHandle crossFiberHookCaller;   // FiberHandle to return to after performing the hook

    alias TimedCallbackGeneration = TypedIdentifier!("TimedCallbackGeneration", ulong, ulong.max, ulong.max);
    struct TimedCallback {
        TimedCallback* _next, _prev;
        timeQueue.OwnerAttrType _owner;
        TimedCallbackGeneration generation;
        TscTimePoint timePoint;
        ulong intervalCycles; // How many cycles between repeatetions. Zero means non-repeating

        Closure closure;
    }

    // TODO change to mmap pool or something
    SimplePool!(TimedCallback) timedCallbacksPool;
    TimedCallbackGeneration.Allocator timedCallbackGeneration;
    CascadingTimeQueue!(TimedCallback*, TIMER_NUM_BINS, TIMER_NUM_LEVELS, true) timeQueue;

    ThreadPool!MAX_DEFERRED_TASKS threadPool;

public:
    /// Report whether the reactor has been properly opened (i.e. - setup has been called).
    @property bool isOpen() const pure nothrow @safe @nogc {
        return _open;
    }

    /// Report whether the reactor is currently active
    ///
    /// Unlike `isRunning`, this will return `false` during the reactor shutdown.
    @property bool isActive() const pure nothrow @safe @nogc {
        return _running && !_stopping;
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
        INFO!"Setting up reactor"();

        assert (!isOpen, "reactor.setup called twice");
        _open = true;
        assert (thread_isMainThread);
        assert (options.numFibers > NUM_SPECIAL_FIBERS);
        reactorReturn = 0;
        optionsInEffect = options;

        maxNumFibersBits = bitsInValue(optionsInEffect.numFibers - 1);
        maxNumFibersMask = createBitMask!(FiberIdx.UnderlyingType)(maxNumFibersBits);

        stats = Stats.init;
        stats.fibersHistogram[FiberState.None] = options.numFibers;

        const stackPerFib = (((options.fiberStackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) + 1) * SYS_PAGE_SIZE;
        fiberStacks.allocate(stackPerFib * options.numFibers);
        allFibers.allocate(options.numFibers);

        _thisFiber = null;
        criticalSectionNesting = 0;
        idleCallbacks.length = 0;
        actualIdleCallbacks = null;

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
        mainFiber.state = FiberState.Running;
        setFiberName(mainFiber, "mainFiber", &mainloop);

        idleFiber = &allFibers[IdleFiberId.value];
        idleFiber.flag!"SPECIAL" = true;
        idleFiber.flag!"CALLBACK_SET" = true;
        idleFiber.params.fiberBody.set(&idleLoop);
        idleFiber.state = FiberState.Sleeping;
        setFiberName(idleFiber, "idleFiber", &idleLoop);

        timedCallbacksPool.open(options.numTimers, true);
        timeQueue.open(options.timerGranularity);

        if( options.faultHandlersEnabled )
            registerFaultHandlers();

        if( options.threadDeferralEnabled )
            threadPool.open(options.numThreadsInPool, options.threadStackSize);

        import mecca.reactor.io.fd;
        _openReactorEpoll();

        if(options.registerDefaultIdler) {
            import mecca.reactor.subsystems.poller;
            theReactor.registerIdleCallback(&poller.reactorIdle);
        }

        import mecca.reactor.io.signals;
        reactorSignal._open();

        enum TIMER_GRANULARITY = 4; // Number of wakeups during the monitored period
        Duration threshold = optionsInEffect.hangDetectorTimeout / TIMER_GRANULARITY;
        hangDetectorTimer = Timer(threshold, &hangDetectorHandler);
    }

    /**
      Shut the reactor down.
     */
    void teardown() {
        INFO!"Tearing down reactor"();

        ASSERT!"reactor teardown called on non-open reactor"(isOpen);
        ASSERT!"reactor teardown called on still running reactor"(!isRunning);
        ASSERT!"reactor teardown called inside a critical section"(criticalSectionNesting==0);

        import mecca.reactor.io.signals;
        reactorSignal._close();

        import mecca.reactor.io.fd;
        _closeReactorEpoll();

        foreach(i, ref fib; allFibers) {
            fib.teardown();
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
        setToInit(scheduledFibersNormal);
        setToInit(scheduledFibersHigh);
        setToInit(scheduledFibersImmediate);
        nothingScheduled = true;

        _thisFiber = null;
        mainFiber = null;
        idleFiber = null;
        idleCallbacks.length = 0;
        actualIdleCallbacks = null;

        _open = false;
    }

    /**
      Register an idle handler callback.

      The reactor handles scheduling and fibers switching, but has no built-in mechanism for scheduling sleeping fibers
      back to execution (except fibers sleeping on a timer, of course). Mechanisms such as file descriptor watching are
      external, and are registered using this function.

      The idler callback should receive a timeout variable. This indicates the time until the closest timer expires. If
      no other event comes in, the idler should strive to wake up after that long. Waking up sooner will, likely, cause
      the idler to be called again. Waking up later will delay timer tasks (which is allowed by the API contract).

      It is allowed to register more than one idler callback. Doing so, however, will cause $(B all) of them to be
      called with a timeout of zero (i.e. - don't sleep), resulting in a busy wait for events.

      The idler is expected to return a boolean value indicating whether the time spent inside the idler is to be
      counted as idle time, or whether that's considered "work". This affects the results returned by the `idleCycles`
      field returned by the `reactorStats`.
     */
    void registerIdleCallback(IdleCallbackDlg dg) nothrow @safe {
        // You will notice our deliberate lack of function to unregister
        if( actualIdleCallbacks.length==idleCallbacks.capacity ) {
            WARN!"Idle callbacks capacity reached - switching to GC allocated list"();
        }

        if( actualIdleCallbacks.length<idleCallbacks.capacity ) {
            idleCallbacks ~= dg;
            actualIdleCallbacks = idleCallbacks[];
        } else {
            actualIdleCallbacks ~= dg;
        }

        DEBUG!"%s idle callbacks registered"(actualIdleCallbacks.length);
    }

    /**
     * Spawn a new fiber for execution.
     *
     * Parameters:
     *  The first argument must be the function/delegate to call inside the new fiber. If said callable accepts further
     *  arguments, then they must be provided as further arguments to spawnFiber.
     *
     * Returns:
     *  A FiberHandle to the newly created fiber.
     */
    @notrace FiberHandle spawnFiber(T...)(T args) nothrow @safe @nogc {
        static assert(T.length>=1, "Must pass at least the function/delegate to spawnFiber");
        static assert(isDelegate!(T[0]) || isFunctionPointer!(T[0]),
                "spawnFiber first argument must be function or delegate");
        static assert( is( ReturnType!(T[0]) == void ), "spawnFiber callback must be of type void" );
        auto fib = _spawnFiber(false);
        fib.params.fiberBody.set(args);
        setFiberName(fib, "Fiber", args[0]);
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
    @notrace FiberHandle spawnFiber(alias F)(Parameters!F args)
    if (!isType!F) {
        static assert( is( ReturnType!F == void ), "spawnFiber callback must be of type void" );
        auto fib = _spawnFiber(false);
        import std.algorithm: move;
        // pragma(msg, genMoveArgument( args.length, "fib.params.fiberBody.set!F", "args" ) );
        mixin( genMoveArgument( args.length, "fib.params.fiberBody.set!F", "args" ) );

        setFiberName(fib, F.mangleof, &F);
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
    @property FiberHandle currentFiberHandle() nothrow @safe @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        DBG_ASSERT!"Should not blindly get fiber handle of special fiber %s"(!isSpecialFiber, currentFiberId);
        return FiberHandle(thisFiber);
    }
    @property package ReactorFiber* currentFiberPtr() nothrow @safe @nogc {
        return getCurrentFiberPtr(false);
    }
    @notrace private ReactorFiber* getCurrentFiberPtr(bool specialOkay) nothrow @safe @nogc {
        // XXX This assert may be incorrect, but it is easier to remove an assert than to add one
        ASSERT!"Should not blindly get fiber handle of special fibers %s"(specialOkay || !isSpecialFiber, currentFiberId);
        return thisFiber;
    }
    /**
      Returns the FiberId of the currently running fiber.

      You should almost never store the FiberId for later comparison or pass it to another fiber. Doing so risks having the current fiber
      die and another one spawned with the same FiberId. If that's what you want to do, use currentFiberHandle instead.
     */
    @property FiberId currentFiberId() const nothrow @safe @nogc {
        return thisFiber.identity;
    }

    /// Returns the `FiberState` of the specified fiber.
    FiberState getFiberState(FiberHandle fh) const nothrow @safe @nogc {
        auto fiber = fh.get();

        if( fiber is null )
            return FiberState.None;

        if( fiber.state==FiberState.Sleeping && fiber.flag!"SCHEDULED" )
            return FiberState.Scheduled;

        return fiber.state;
    }

    /**
      Starts up the reactor.

      The reactor should already have at least one user fiber at that point, or it will start, but sit there and do nothing.

      This function "returns" only after the reactor is stopped and no more fibers are running.

      Returns:
      The return value from `start` is the value passed to the `stop` function.
     */
    int start() {
        _isReactorThread = true;
        scope(exit) _isReactorThread = false;

        META!"Reactor started"();
        assert( idleFiber !is null, "Reactor started without calling \"setup\" first" );
        mainloop();
        META!"Reactor stopped"();

        return reactorReturn;
    }

    /**
      Stop the reactor, killing all fibers.

      This will kill all running fibers and trigger a return from the original call to Reactor.start.

      Typically, this function call never returns (throws ReactorExit). However, if stop is called while already in the
      process of stopping, it will just return. It is, therefor, not wise to rely on that fact.

      Params:
      reactorReturn = The return value to be returned from `start`
     */
    void stop(int reactorReturn = 0) @safe @nogc {
        if( !isActive ) {
            ERROR!"Reactor.stop called, but reactor is not running"();
            return;
        }

        INFO!"Stopping reactor with exit code %s"(reactorReturn);
        this.reactorReturn = reactorReturn;

        _stopping = true;
        if( !isMain() ) {
            resumeSpecialFiber(mainFiber);
        }

        throw mkEx!ReactorExit();
    }

    /**
      enter a no-fiber switch piece of code.

      If the code tries to switch away from the current fiber before leaveCriticalSection is called, the reactor will throw an assert.
      This helps writing code that does interruption sensitive tasks without locks and making sure future changes don't break it.

      Critical sections are nestable.

      Also see `criticalSection` below.
     */
    void enterCriticalSection() nothrow @safe @nogc {
        pragma(inline, true);
        criticalSectionNesting++;
    }

    /// leave the innermost critical section.
    void leaveCriticalSection() nothrow @safe @nogc {
        pragma(inline, true);
        assert (criticalSectionNesting > 0);
        criticalSectionNesting--;
    }

    /// Reports whether execution is currently within a critical section
    @property bool isInCriticalSection() const pure nothrow @safe @nogc {
        return criticalSectionNesting > 0;
    }

    /** Make sure we are allowed to context switch from this point.
     *
     * This will be called automatically if an actual context switch is attempted. You might wish to call this function
     * explicitly, however, from contexts that $(I might) context switch, so that they fail even if they don't actually
     * attempt it, in accordance with the "fail early" doctrine.
     */
    void assertMayContextSwitch(string message = "Simulated context switch") nothrow @safe @nogc {
        pragma(inline, true);
        ASSERT!"Context switch from outside the reactor thread: %s"(isReactorThread, message);
        ASSERT!"Context switch while inside a critical section: %s"(!isInCriticalSection, message);
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
                        assertThrows!AssertError( theReactor.yield() );
                    }
                }

                theReactor.yield();
                });
    }

    /**
     * Temporarily surrender the CPU for other fibers to run.
     *
     * Unlike suspend, the current fiber will automatically resume running after any currently scheduled fibers are finished.
     */
    @notrace void yield() @safe @nogc {
        // TODO both scheduled and running is not a desired state to be in other than here.
        resumeFiber(thisFiber);
        suspendCurrentFiber();
    }

    /**
     * Returns whether the fiber is already running for a long time.
     *
     * Fibers that run for too long prevent other fibers from operating properly. On the other hand, fibers that initiate
     * a context switch needlessly load the system with overhead.
     *
     * This function reports whether the fiber is already running more than the desired time.
     *
     * The base time used is taken from `OpenOptions.maxDesiredRunTime`.
     *
     * Params:
     * tolerance = A multiplier for the amount of acceptable run time. Specifying 4 here will give you 4 times as much
     * time to run before a context switch is deemed necessary.
     */
    @notrace bool shouldYield(uint tolerance = 1) const nothrow @safe @nogc {
        if( _stopping )
            return true;

        auto now = TscTimePoint.hardNow();
        return (now - fiberRunStartTime) > tolerance*optionsInEffect.maxDesiredRunTime;
    }

    /**
     Perform yield if fiber is running long enough.

     Arguments and meaning are the same as for `shouldYield`.

     Returns:
     Whether a yield actually took place.
     */
    @notrace bool considerYield(uint tolerance = 1) @safe @nogc {
        if( shouldYield(tolerance) ) {
            yield();
            return true;
        }

        return false;
    }

    /**
     * Give a fiber temporary priority in execution.
     *
     * Setting fiber priority means that the next time this fiber is scheduled, it will be scheduled ahead of other
     * fibers already scheduled to be run.
     *
     * Returns a RAII object that sets the priority back when destroyed. Typically, that happens at the end of the scope.
     *
     * Can be used as:
     * ---
     * with(boostFiberPriority()) {
     *    // High priority stuff goes here
     * }
     * ---
     */
    auto boostFiberPriority() nothrow @safe @nogc {
        static struct FiberPriorityRAII {
        private:
            FiberHandle fh;

        public:
            @disable this(this);
            this(FiberHandle fh) @safe @nogc nothrow {
                this.fh = fh;
            }

            ~this() @safe @nogc nothrow {
                if( fh.isValid ) {
                    ASSERT!"Cannot move priority watcher between fibers (opened on %s)"(
                            fh == theReactor.currentFiberHandle, fh.fiberId);

                    ASSERT!"Trying to reset priority which is not set"( theReactor.thisFiber.flag!"PRIORITY" );
                    theReactor.thisFiber.flag!"PRIORITY" = false;
                }
            }
        }

        ASSERT!"Cannot ask to prioritize a non-user fiber"(!isSpecialFiber);
        ASSERT!"Asked to prioritize a fiber %s which is already high priority"(
                !thisFiber.flag!"PRIORITY", currentFiberId );
        DEBUG!"Setting fiber priority"();
        thisFiber.flag!"PRIORITY" = true;

        return FiberPriorityRAII(currentFiberHandle);
    }

    /// Handle used to manage registered timers
    struct TimerHandle {
    private:
        TimedCallback* callback;
        TimedCallbackGeneration generation;

    public:

        this(TimedCallback* callback) nothrow @safe @nogc {
            DBG_ASSERT!"Constructing TimedHandle from null callback"(callback !is null);
            this.callback = callback;
            this.generation = callback.generation;
        }

        /// Returns whether the handle was used
        ///
        /// returns:
        /// `true` if the handle was set. `false` if it is still in its init value.
        @property bool isSet() const pure nothrow @safe @nogc {
            return callback !is null;
        }

        /// Returns whether the handle describes a currently registered task
        @property bool isValid() const nothrow @safe @nogc {
            return
                    isSet() &&
                    theReactor.isOpen &&
                    callback._owner !is null &&
                    generation == callback.generation;
        }

        /// Revert the handle to init value, forgetting the timer it points to
        ///
        /// This call will $(B not) cancel the actual timer. Use `cancelTimer` for that.
        @notrace void reset() nothrow @safe @nogc {
            callback = null;
            generation = TimedCallbackGeneration.invalid;
        }

        /// Cancel a currently registered timer
        void cancelTimer() nothrow @safe @nogc {
            if( isValid ) {
                theReactor.cancelTimerInternal(this);
            }

            reset();
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
        TimedCallback* callback = allocTimedCallback();
        callback.closure.set(&F, params);
        callback.timePoint = timeout.expiry;
        callback.intervalCycles = 0;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    /// ditto
    TimerHandle registerTimer(alias F)(Duration timeout, Parameters!F params) nothrow @safe @nogc {
        return registerTimer!F(Timeout(timeout), params);
    }

    /**
     * Register a timer callback
     *
     * Same as `registerTimer!F`, except with the callback as an argument. Callback cannot accept parameters.
     */
    TimerHandle registerTimer(T)(Timeout timeout, T dg) nothrow @safe @nogc {
        TimedCallback* callback = allocTimedCallback();
        callback.closure.set(dg);
        callback.timePoint = timeout.expiry;
        callback.intervalCycles = 0;

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    /// ditto
    TimerHandle registerTimer(T)(Duration timeout, T dg) nothrow @safe @nogc {
        return registerTimer!T(Timeout(timeout), dg);
    }

    /**
     * registers a timer that will repeatedly trigger at set intervals.
     *
     * You do not control precisely when the callback is invoked, only how often. The invocations are going to be evenly
     * spaced out (best effort), but the first invocation might be almost immediately after the call or a whole
     * `interval` after.
     *
     * You can use the `firstRun` argument to control when the first invocation is going to be (but the same rule will
     * still apply to the second one).
     *
     * Params:
     *  interval = the frequency with which the callback will be called.
     *  dg = the callback to invoke
     *  F = an alias to the function to be called
     *  params = the arguments to pass to F on each invocation
     *  firstRun = if supplied, directly sets when is the first time the timer shall run. The value does not have any
     *      special constraints.
     */
    TimerHandle registerRecurringTimer(Duration interval, void delegate() dg) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(dg);
        return TimerHandle(callback);
    }

    /// ditto
    TimerHandle registerRecurringTimer(alias F)(Duration interval, Parameters!F params) nothrow @safe @nogc {
        TimedCallback* callback = _registerRecurringTimer(interval);
        callback.closure.set(&F, params);
        return TimerHandle(callback);
    }

    /// ditto
    TimerHandle registerRecurringTimer(Duration interval, void delegate() dg, Timeout firstRun) nothrow @safe @nogc {
        TimedCallback* callback = allocRecurringTimer(interval);
        callback.timePoint = firstRun.expiry;
        callback.closure.set(dg);

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    /// ditto
    TimerHandle registerRecurringTimer(alias F)(Duration interval, Parameters!F params, Timeout firstRun) nothrow @safe @nogc {
        TimedCallback* callback = allocRecurringTimer(interval);
        callback.timePoint = firstRun.expiry;
        callback.closure.set(&F, params);

        timeQueue.insert(callback);

        return TimerHandle(callback);
    }

    private void cancelTimerInternal(TimerHandle handle) nothrow @safe @nogc {
        DBG_ASSERT!"cancelTimerInternal called with invalid handle"( handle.isValid );
        timeQueue.cancel(handle.callback);
        timedCallbacksPool.release(handle.callback);
    }

    /**
     * Schedule a callback for out of bounds immediate execution.
     *
     * For all intents and purposes, `call` is identical to `registerTimer` with an expired timeout.
     */
    TimerHandle call(alias F)(Parameters!F params) nothrow @safe @nogc {
        return registerTimer!F(Timeout.elapsed, params);
    }

    /// ditto
    TimerHandle call(T)(T dg) nothrow @safe @nogc {
        return registerTimer(Timeout.elapsed, dg);
    }

    /// Suspend the current fiber for a specified amount of time
    void sleep(Duration duration) @safe @nogc {
        sleep(Timeout(duration));
    }

    /// ditto
    void sleep(Timeout until) @safe @nogc {
        assert(until != Timeout.init, "sleep argument uninitialized");
        auto timerHandle = registerTimer!resumeFiber(until, currentFiberHandle, false);
        scope(failure) timerHandle.cancelTimer();

        suspendCurrentFiber();
    }

    /**
      Resume a suspended fiber

      You are heartily encouraged not to use this function directly. In almost all cases, it is better to use one of the
      synchronization primitives instead.

      Params:
      handle = the handle of the fiber to be resumed.
      priority = If true, schedule the fiber before all currently scheduled fibers. If the fiber is already scheduled
        (`getFiberState` returns `Scheduled`), this will move it to the top of the queue.
     */
    @notrace void resumeFiber(FiberHandle handle, bool priority = false) nothrow @safe @nogc {
        auto fiber = handle.get();

        if( fiber !is null )
            resumeFiber(handle.get(), priority);
    }

    /**
      Suspend the current fiber

      If `timeout` is given and expires, the suspend will throw a `TimeoutExpired` exception.

      You are heartily encouraged not to use this function directly. In almost all cases, it is better to use one of the
      synchronization primitives instead.
     */
    @notrace void suspendCurrentFiber(Timeout timeout) @trusted @nogc {
        if (timeout == Timeout.infinite)
            return suspendCurrentFiber();

        assertMayContextSwitch("suspendCurrentFiber");

        TimerHandle timeoutHandle;
        scope(exit) timeoutHandle.cancelTimer();
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

        timeoutHandle = registerTimer!resumer(timeout, currentFiberHandle, &timeoutHandle, &timeoutExpired);
        switchToNext();

        if( timeoutExpired )
            throw mkEx!TimeoutExpired();
    }

    /// ditto
    @notrace void suspendCurrentFiber() @safe @nogc {
         switchToNext();
    }

    /**
     * run a function inside a different thread.
     *
     * Runs a function inside a thread. Use this function to run CPU bound processing without freezing the other fibers.
     *
     * `Fini`, if provided, will be called with the same parameters in the reactor thread once the thread has finished.
     * `Fini` will be called unconditionally, even if the fiber that launched the thread terminates before the thread
     * has finished.
     *
     * The `Fini` function runs within a `criticalSection`, and must not sleep.
     *
     * Returns:
     * The return argument from the delegate is returned by this function.
     *
     * Throws:
     * Will throw TimeoutExpired if the timeout expires.
     *
     * Will rethrow whatever the thread throws in the waiting fiber.
     */
    auto deferToThread(alias F, alias Fini = null)(Parameters!F args, Timeout timeout = Timeout.infinite) @nogc {
        DBG_ASSERT!"deferToThread called but thread deferral isn't enabled in the reactor"(
                optionsInEffect.threadDeferralEnabled);
        return threadPool.deferToThread!(F, Fini)(timeout, args);
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
        if( !fHandle.isValid )
            return false;

        ExcBuf* fiberEx = prepThrowInFiber(fHandle, false);

        if( fiberEx is null )
            return false;

        fiberEx.set(ex);
        auto fib = fHandle.get();
        resumeFiber(fib, true);
        return true;
    }

    /// ditto
    bool throwInFiber(T : Throwable, string file = __FILE_FULL_PATH__, size_t line = __LINE__, A...)
            (FiberHandle fHandle, auto ref A args) nothrow @safe @nogc
    {
        pragma(inline, true);
        if( !fHandle.isValid )
            return false;

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

        DEBUG!"Requesting explicit GC collection"();
        requestGCCollectionInternal(true);

        if( waitForCollection ) {
            DBG_ASSERT!"Special fiber must request synchronous GC collection"( !isSpecialFiber );
            yield();
        }
    }

    private void requestGCCollectionInternal(bool force) nothrow @safe @nogc {
        _gcCollectionNeeded = true;
        _gcCollectionForce = force;
        if( theReactor.currentFiberId != MainFiberId ) {
            theReactor.resumeSpecialFiber(theReactor.mainFiber);
        }
    }

    /// Property for disabling/enabling the hang detector.
    ///
    /// The hang detector must be configured during `setup` by setting `OpenOptions.hangDetectorTimeout`.
    @property bool hangDetectorEnabled() pure const nothrow @safe @nogc {
        return _hangDetectorEnabled;
    }

    /// ditto
    @property void hangDetectorEnabled(bool enabled) pure nothrow @safe @nogc {
        ASSERT!"Cannot enable an unconfigured hang detector"(
                !enabled || optionsInEffect.hangDetectorTimeout !is Duration.zero);
        _hangDetectorEnabled = enabled;
    }

    /// Iterate all fibers
    auto iterateFibers() const nothrow @safe @nogc {
        static struct FibersIterator {
        private:
            uint numLivingFibers;
            FiberIdx idx = NUM_SPECIAL_FIBERS;
            ReturnType!(Reactor.criticalSection) criticalSection;

            this(uint numFibers) {
                numLivingFibers = numFibers;
                this.criticalSection = theReactor.criticalSection();

                if( numLivingFibers>0 ) {
                    findNextFiber();
                }
            }

            void findNextFiber() @safe @nogc nothrow {
                while( ! to!(ReactorFiber*)(idx).isAlive ) {
                    idx++;
                    DBG_ASSERT!"Asked for next living fiber but none was found"(
                            idx<theReactor.optionsInEffect.numFibers);
                }
            }
        public:
            @property bool empty() const pure @safe @nogc nothrow {
                return numLivingFibers==0;
            }

            void popFront() @safe @nogc nothrow {
                ASSERT!"Popping fiber from empty list"(!empty);
                numLivingFibers--;
                idx++;

                if( !empty )
                    findNextFiber;
            }

            @property FiberHandle front() @safe @nogc nothrow {
                auto fib = &theReactor.allFibers[idx.value];
                DBG_ASSERT!"Scanned fiber %s is not alive"(fib.isAlive, idx);

                return FiberHandle(fib);
            }
        }

        return FibersIterator(cast(uint) reactorStats.numUsedFibers);
    }

    auto iterateScheduledFibers(FiberPriorities priority) nothrow @safe @nogc {
        @notrace static struct Range {
            private typeof(scheduledFibersNormal.range()) fibersRange;

            @property FiberHandle front() nothrow @nogc {
                return FiberHandle(fibersRange.front);
            }

            @property bool empty() const pure nothrow @nogc {
                return fibersRange.empty;
            }

            @notrace void popFront() nothrow {
                fibersRange.popFront();
            }
        }

        with(FiberPriorities) final switch(priority) {
        case NORMAL:
            return scheduledFibersNormal.range();
        case HIGH:
            return scheduledFibersHigh.range();
        case IMMEDIATE:
            return scheduledFibersImmediate.range();
        }

        assert(false, "Priority must be member of FiberPriorities");
    }

    /**
     * Set a fiber name
     *
     * Used by certain diagnostic functions to distinguish the different fiber types and create histograms.
     * Arguments bear no specific meaning, but default to describing the function used to start the fiber.
     */
    @notrace void setFiberName(FiberHandle fh, string name, void *ptr) nothrow @safe @nogc {
        DBG_ASSERT!"Trying to set fiber name of an invalid fiber"(fh.isValid);
        setFiberName(fh.get, name, ptr);
    }

    /// ditto
    @notrace void setFiberName(T)(FiberHandle fh, string name, scope T dlg) nothrow @safe @nogc if( isDelegate!T ) {
        setFiberName(fh, name, dlg.ptr);
    }

    /**
     * Temporarily change the fiber's name
     *
     * Meaning of arguments is as for `setFiberName`.
     *
     * returns:
     * A voldemort type whose destructor returns the fiber name to the one it had before. It also has a `release`
     * function for returning the name earlier.
     */
    auto pushFiberName(string name, void *ptr) nothrow @safe @nogc {
        static struct PrevName {
        private:
            string name;
            void* ptr;

        public:
            @disable this();
            @disable this(this);

            this(string name, void* ptr) nothrow @safe @nogc {
                this.name = name;
                this.ptr = ptr;
            }

            ~this() nothrow @safe @nogc {
                if( name !is null || ptr !is null )
                    release();
            }

            void release() nothrow @safe @nogc {
                theReactor.setFiberName( theReactor.thisFiber, this.name, this.ptr );

                name = null;
                ptr = null;
            }
        }

        auto prevName = PrevName(name, ptr);
        setFiberName( theReactor.thisFiber, name, ptr );

        import std.algorithm: move;
        return move(prevName);
    }

    /// ditto
    @notrace auto pushFiberName(T)(string name, scope T dlg) nothrow @safe @nogc if( isDelegate!T ) {
        return pushFiberName(name, dlg.ptr);
    }

    /// Retrieve the fiber name set by `setFiberName`
    @notrace string getFiberName(FiberHandle fh) nothrow @safe @nogc {
        DBG_ASSERT!"Trying to get fiber name of an invalid fiber"(fh.isValid);
        return fh.get.params.fiberName;
    }

    /// ditto
    @notrace string getFiberName() nothrow @safe @nogc {
        return thisFiber.params.fiberName;
    }

    /// Retrieve the fiber pointer set by `setFiberName`
    @notrace void* getFiberPtr(FiberHandle fh) nothrow @safe @nogc {
        DBG_ASSERT!"Trying to get fiber pointer of an invalid fiber"(fh.isValid);
        return fh.get.params.fiberPtr;
    }

    /// ditto
    @notrace void* getFiberPtr() nothrow @safe @nogc {
        return thisFiber.params.fiberPtr;
    }

    /**
     * Wait until given fiber finishes
     */
    @notrace void joinFiber(FiberHandle fh, Timeout timeout = Timeout.infinite) @safe @nogc {
        ReactorFiber* fiber = fh.get();

        if( fiber is null ) {
            assertMayContextSwitch();
            return;
        }

        fiber.params.joinWaiters.wait(timeout);
        DBG_ASSERT!"Fiber handle %s is valid after signalling done"(!fh.isValid, fh);
    }

    /// Report the current reactor statistics.
    @property Stats reactorStats() const nothrow @safe @nogc {
        Stats ret = stats;

        foreach( FiberIdx.UnderlyingType i; 0..NUM_SPECIAL_FIBERS ) {
            auto fiberIdx = FiberIdx(i);
            auto fiber = to!(ReactorFiber*)(fiberIdx);
            DBG_ASSERT!"%s is in state %s with histogram of 0"(
                    ret.fibersHistogram[fiber.state]>0, fiber.identity, fiber.state );
            ret.fibersHistogram[fiber.state]--;
        }

        return ret;
    }

private:
    package @property inout(ReactorFiber)* thisFiber() inout nothrow pure @safe @nogc {
        DBG_ASSERT!"No current fiber as reactor was not started"(isRunning);
        return _thisFiber;
    }

    @notrace TimedCallback* allocTimedCallback() nothrow @safe @nogc {
        DBG_ASSERT!"Registering timer on non-open reactor"(isOpen);
        auto ret = timedCallbacksPool.alloc();
        ret.generation = timedCallbackGeneration.getNext();

        return ret;
    }

    TimedCallback* allocRecurringTimer(Duration interval) nothrow @safe @nogc {
        TimedCallback* callback = allocTimedCallback();
        if( interval<optionsInEffect.timerGranularity )
            interval = optionsInEffect.timerGranularity;

        callback.intervalCycles = TscTimePoint.toCycles(interval);
        return callback;
    }

    TimedCallback* _registerRecurringTimer(Duration interval) nothrow @safe @nogc {
        TimedCallback* callback = allocRecurringTimer(interval);
        rescheduleRecurringTimer(callback);
        return callback;
    }

    @property bool shouldRunTimedCallbacks() nothrow @safe @nogc {
        return timeQueue.cyclesTillNextEntry(TscTimePoint.hardNow()) == 0;
    }

    void switchToNext() @safe @nogc {
        //DEBUG!"SWITCH out of %s"(thisFiber.identity);
        assertMayContextSwitch("Context switch");

        stats.numContextSwitches++;

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

            ReactorFiber* nextFiber;

            if( !scheduledFibersImmediate.empty ) {
                nextFiber = scheduledFibersImmediate.popHead();
            } else if(
                    !scheduledFibersHigh.empty &&
                    ( highPrioritySchedules<HIGH_PRIORITY_SCHEDULES_RATIO || scheduledFibersNormal.empty))
            {
                nextFiber = scheduledFibersHigh.popHead();
                highPrioritySchedules++;
            } else if( !scheduledFibersNormal.empty ) {
                nextFiber = scheduledFibersNormal.popHead();
                if( !scheduledFibersHigh.empty ) {
                    ERROR!"Scheduled normal priority fiber %s over high priority %s to prevent starvation"(
                            nextFiber.identity, scheduledFibersHigh.head.identity);
                }

                highPrioritySchedules = 0;
            } else {
                DBG_ASSERT!"Idle fiber scheduled but all queues empty"( !idleFiber.flag!"SCHEDULED" );
                nextFiber = idleFiber;
                idleFiber.flag!"SCHEDULED" = true;
                nothingScheduled = true;
            }

            if( thisFiber.state==FiberState.Running )
                thisFiber.state = FiberState.Sleeping;
            else {
                assertEQ( thisFiber.state, FiberState.Done, "Fiber is in incorrect state" );
                thisFiber.state = FiberState.None;
            }

            DBG_ASSERT!"Couldn't decide on a fiber to schedule"(nextFiber !is null);

            ASSERT!"Next fiber %s is not marked scheduled" (nextFiber.flag!"SCHEDULED", nextFiber.identity);
            nextFiber.flag!"SCHEDULED" = false;
            DBG_ASSERT!"%s is in state %s, should be Sleeping or Starting"(
                    nextFiber.state==FiberState.Sleeping || nextFiber.state==FiberState.Starting,
                    nextFiber.identity, nextFiber.state);
            nextFiber.state = FiberState.Running;

            // DEBUG!"Switching %s => %s"(thisFiber.identity, nextFiber.identity);
            if (thisFiber !is nextFiber) {
                // make the switch
                switchTo(nextFiber);
            }
        }
    }

    void switchTo(ReactorFiber* nextFiber) @safe @nogc {
        auto currentFiber = thisFiber;
        _thisFiber = nextFiber;

        currentFiber.switchTo(nextFiber);

        // After returning
        /+
          Important note:
          Any code you place here *must* be replicated at the beginning of ReactorFiber.wrapper. Fibers launched
          for the first time do not return from `switchTo` above.
         +/

        // DEBUG!"SWITCH into %s"(thisFiber.identity);

        // This might throw, so it needs to be the last thing we do
        thisFiber.switchInto();
    }

    bool fiberTerminated() nothrow @notrace {
        ASSERT!"special fibers must never terminate" (!thisFiber.flag!"SPECIAL");

        freeFibers.prepend(thisFiber);

        bool skipBody = false;
        try {
            // Wait for next incarnation of fiber
            switchToNext();
        } catch (FiberInterrupt ex) {
            INFO!"Fiber %s killed by FiberInterrupt exception %s"(currentFiberId, ex.msg);
            skipBody = true;
        } catch (Throwable ex) {
            ERROR!"switchToNext on %s fiber %s failed with exception %s"(
                    thisFiber.state==FiberState.Running ? "just starting" : "dead", currentFiberId, ex.msg);
            theReactor.forwardExceptionToMain(ex);
            assert(false);
        }

        return skipBody;
    }

    void resumeSpecialFiber(ReactorFiber* fib) nothrow @safe @nogc {
        DBG_ASSERT!"Asked to resume special fiber %s which isn't marked special" (fib.flag!"SPECIAL", fib.identity);
        DBG_ASSERT!"Asked to resume special fiber %s with no body set" (fib.flag!"CALLBACK_SET", fib.identity);
        DBG_ASSERT!"Special fiber %s scheduled not in head of list" (
                !fib.flag!"SCHEDULED" || scheduledFibersImmediate.head is fib, fib.identity);

        if (!fib.flag!"SCHEDULED") {
            fib.flag!"SCHEDULED" = true;
            scheduledFibersImmediate.prepend(fib);
            nothingScheduled = false;
        }
    }

    void resumeFiber(ReactorFiber* fib, bool immediate = false) nothrow @safe @nogc {
        DBG_ASSERT!"Cannot resume a special fiber %s using the standard resumeFiber" (!fib.flag!"SPECIAL", fib.identity);
        ASSERT!"resumeFiber called on %s, which does not have a callback set"(fib.flag!"CALLBACK_SET", fib.identity);

        typeof(scheduledFibersNormal)* queue;
        if( immediate ) {
            if( fib.flag!"SCHEDULED" && fib !in scheduledFibersImmediate ) {
                fib._owner.remove(fib);
                fib.flag!"SCHEDULED" = false;
            }

            queue = &scheduledFibersImmediate;
        } else if( fib.flag!"PRIORITY" ) {
            queue = &scheduledFibersHigh;
        } else {
            queue = &scheduledFibersNormal;
        }

        if (!fib.flag!"SCHEDULED") {
            if (fib._owner !is null) {
                // Whatever this fiber was waiting to do, it is no longer what it needs to be doing
                fib._owner.remove(fib);
            }
            fib.flag!"SCHEDULED" = true;
            queue.append(fib);
            nothingScheduled = false;
        }
    }

    ReactorFiber* _spawnFiber(bool immediate) nothrow @safe @nogc {
        ASSERT!"No more free fibers in pool"(!freeFibers.empty);
        auto fib = freeFibers.popHead();
        assert (!fib.flag!"CALLBACK_SET");
        fib.flag!"CALLBACK_SET" = true;
        fib.state = FiberState.Starting;
        fib._prevId = FiberIdx.invalid;
        fib._nextId = FiberIdx.invalid;
        fib._owner = null;
        fib.params.flsBlock.reset();
        resumeFiber(fib, immediate);
        return fib;
    }

    void idleLoop() {
        while (true) {
            TscTimePoint start, end;
            end = start = TscTimePoint.hardNow;

            while (nothingScheduled) {
                auto critSect = criticalSection();

                /*
                   Since we've updated "end" before calling the timers, these timers won't count as idle time, unless....
                   after running them the scheduledFibers list is still empty, in which case they do.
                 */
                if( runTimedCallbacks(end) )
                    continue;

                // We only reach here if runTimedCallbacks did nothing, in which case "end" is recent enough
                Duration sleepDuration = timeQueue.timeTillNextEntry(end);
                bool countsAsIdle = true;
                if( actualIdleCallbacks.length==1 ) {
                    countsAsIdle = actualIdleCallbacks[0](sleepDuration) && countsAsIdle;
                } else if ( actualIdleCallbacks.length>1 ) {
                    foreach(cb; actualIdleCallbacks) {
                        with( pushFiberName("Idle callback", cb) ) {
                            countsAsIdle = cb(ZERO_DURATION) && countsAsIdle;
                        }
                    }
                } else {
                    //DEBUG!"Idle fiber called with no callbacks, sleeping %sus"(sleepDuration.total!"usecs");
                    import core.thread; Thread.sleep(sleepDuration);
                }

                if( countsAsIdle ) {
                    end = TscTimePoint.hardNow;
                } else {
                    if( nothingScheduled ) {
                        // We are going in for another round, but this round should not count as idle time
                        stats.idleCycles += end.diff!"cycles"(start);
                        end = start = TscTimePoint.hardNow;
                    }
                }
            }
            stats.idleCycles += end.diff!"cycles"(start);
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
        if( !mainFiber.flag!"SPECIAL" ) {
            ASSERT!"Main fiber not marked as special but reactor is not stopping"( _stopping );
            mainFiber.flag!"SPECIAL" = true;
        }
        resumeSpecialFiber(mainFiber);
        as!"nothrow"(&theReactor.switchToNext);
        assert(false, "switchToNext on dead system returned");
    }

    void registerHangDetector() @trusted @nogc {
        DBG_ASSERT!"registerHangDetector called twice"(!hangDetectorTimer.isSet);
        hangDetectorTimer.start();
    }

    void deregisterHangDetector() nothrow @trusted @nogc {
        hangDetectorTimer.cancel();
    }

    extern(C) static void hangDetectorHandler() nothrow @trusted @nogc {
        if( !theReactor._hangDetectorEnabled )
            return;

        auto now = TscTimePoint.hardNow();
        auto delay = now - theReactor.fiberRunStartTime;

        if( delay<theReactor.optionsInEffect.hangDetectorTimeout || theReactor.currentFiberId == IdleFiberId )
            return;

        long seconds, usecs;
        delay.split!("seconds", "usecs")(seconds, usecs);

        ERROR!"Hang detector triggered for %s after %s.%06s seconds"(theReactor.currentFiberId, seconds, usecs);
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

        META!"#OSSIGNAL %s"(faultName);
        dumpStackTrace();
        flushLog(); // There is a certain chance the following lines themselves fault. Flush the logs now so that we have something

        posix_ucontext.ucontext_t* contextPtr = cast(posix_ucontext.ucontext_t*)ctx;
        auto pc = contextPtr ? contextPtr.uc_mcontext.gregs[posix_ucontext.REG_RIP] : 0;

        if( isReactorThread ) {
            auto currentSD = theReactor.getCurrentFiberPtr(true).stackDescriptor;
            ERROR!"%s on %s address 0x%x, PC 0x%x stack params at 0x%x"(
                    faultName, theReactor.currentFiberId, info.si_addr, pc, theReactor.getCurrentFiberPtr(true).params);
            ERROR!"Stack is at [%s .. %s]"( currentSD.bstack, currentSD.tstack );
            auto guardAddrStart = currentSD.bstack - GUARD_ZONE_SIZE;
            if( info.si_addr < currentSD.bstack && info.si_addr >= guardAddrStart ) {
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
        scope(exit) _running = false;

        GC.disable();
        scope(exit) GC.enable();

        lastGCStats = GC.stats();

        if( optionsInEffect.utGcDisabled ) {
            // GC is disabled during the reactor run. Run it before we start
            GC.collect();
        }

        // Don't register the hang detector until after we've finished running the GC
        if( optionsInEffect.hangDetectorTimeout !is Duration.zero ) {
            registerHangDetector();
            _hangDetectorEnabled = true;
        } else {
            _hangDetectorEnabled = false;
        }

        scope(exit) {
            if( optionsInEffect.hangDetectorTimeout !is Duration.zero )
                deregisterHangDetector();

            _hangDetectorEnabled = false;
        }

        _thisFiber = mainFiber;
        scope(exit) _thisFiber = null;

        if( !optionsInEffect.utGcDisabled )
            TimerHandle gcTimer = registerRecurringTimer!requestGCCollectionInternal(optionsInEffect.gcInterval, false);

        try {
            while (!_stopping) {
                DBG_ASSERT!"Switched to mainloop with wrong thisFiber %s"(thisFiber is mainFiber, thisFiber.identity);
                runTimedCallbacks();
                if( _gcCollectionNeeded )
                    gcCollect();

                if( !_stopping )
                    switchToNext();
            }
        } catch( ReactorExit ex ) {
            ASSERT!"Main loop threw ReactorExit, but reactor is not stopping"(_stopping);
        }

        performStopReactor();
    }

    void gcCollect() {
        _gcCollectionNeeded = false;
        auto statsBefore = GC.stats();

        if(
            _gcCollectionForce ||
            optionsInEffect.gcRunThreshold==0 ||
            statsBefore.usedSize > lastGCStats.usedSize+optionsInEffect.gcRunThreshold )
        {
            TscTimePoint.hardNow(); // Update the hard now value
            DEBUG!"#GC collection cycle started, %s bytes allocated since last run (forced %s)"(statsBefore.usedSize - lastGCStats.usedSize, _gcCollectionForce);

            GC.collect();
            TscTimePoint.hardNow(); // Update the hard now value
            lastGCStats = GC.stats();
            DEBUG!"#GC collection cycle ended, freed %s bytes"(statsBefore.usedSize - lastGCStats.usedSize);

            _gcCollectionForce = false;
        }
    }

    void performStopReactor() @nogc {
        ASSERT!"performStopReactor must be called from the main fiber. Use Reactor.stop instead"( isMain );

        Throwable reactorExit = mkEx!ReactorExit("Reactor is quitting");
        foreach(ref fiber; allFibers[1..$]) { // All fibers but main
            if( fiber.isAlive ) {
                fiber.flag!"SPECIAL" = false;
                throwInFiber(FiberHandle(&fiber), reactorExit);
            }
        }

        thisFiber.flag!"SPECIAL" = false;
        yield();

        META!"Stopping reactor"();
        _stopping = false;
    }

    @notrace void setFiberName(ReactorFiber* fib, string name, void *ptr) nothrow @safe @nogc {
        fib.params.fiberName = name;
        fib.params.fiberPtr = ptr;
    }

    @notrace void setFiberName(T)(ReactorFiber* fib, string name, scope T dlg) nothrow @safe @nogc if( isDelegate!T ) {
        fib.params.fiberName = name;
        fib.params.fiberPtr = dlg.ptr;
    }

    void performCrossFiberHook() @safe @nogc {
        ReactorFiber* callingFiber;

        // Perform the hook under critical section
        with(criticalSection()) {
            scope(failure) ASSERT!"Cross fiber hook threw"(false);
            crossFiberHook();

            callingFiber = crossFiberHookCaller.get();
            ASSERT!"Fiber invoking hook %s invalidated by hook"(callingFiber !is null, crossFiberHookCaller.identity);

            // Clear the hooks so they don't get called when returning to the hooker fiber
            crossFiberHook = null;
            crossFiberHookCaller.reset();
        }

        switchTo(callingFiber);
    }

    @notrace void callInFiber(FiberHandle fh, scope void delegate() nothrow @safe @nogc callback) @trusted @nogc {
        ASSERT!"Cannot set hook when one is already set"( crossFiberHook is null && !crossFiberHookCaller.isSet );
        ReactorFiber* fib = fh.get();
        if( fib is null )
            // Fiber isn't valid - don't do anything
            return;

        if( fib is thisFiber ) {
            // We were asked to switch to ourselves. Just run the callback
            auto critSect = criticalSection();
            callback();

            return;
        }

        with(FiberState) {
            ASSERT!"Trying to dump stack trace of %s which is in invalid state %s"(
                fib.state==Starting || fib.state==Sleeping, fib.identity, fib.state );
        }

        // We are storing a scoped delegate inside a long living pointer, but we make sure to finish using it before exiting.
        crossFiberHook = callback;
        crossFiberHookCaller = FiberHandle(thisFiber); // Don't call currentFiber, as we might be a special fiber

        switchTo(fib);

        DBG_ASSERT!"crossFiberHookCaller not cleared after call"( !crossFiberHookCaller.isSet );
        DBG_ASSERT!"crossFiberHook not cleared after call"( crossFiberHook is null );
    }

    import std.string : format;
    enum string decl_log_as(string logLevel) = q{
        @notrace public void %1$s_AS(
            string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)
            (FiberHandle fh, T args) nothrow @safe @nogc
        {
            auto fiber = fh.get;
            if( fiber is null ) {
                ERROR!("Can't issue %1$s log as %%s. Original log: "~fmt, file, mod, line)(fh, args);
                return;
            }

            auto currentFiber = getCurrentFiberPtr(true);
            fiber.logSwitchInto();
            scope(exit) currentFiber.logSwitchInto();

            %1$s!(fmt, file, mod, line)(args);
        }
    }.format(logLevel);
    mixin(decl_log_as!"DEBUG");
    mixin(decl_log_as!"INFO");
    mixin(decl_log_as!"WARN");
    mixin(decl_log_as!"ERROR");
    mixin(decl_log_as!"META");

    /**
     * Log the stack trace of a given fiber.
     *
     * The fiber should be in a valid state. This is the equivalent to the fiber itself running `dumpStackTrace`.
     */
    @notrace public void LOG_TRACEBACK_AS(
            FiberHandle fh, string text, string file = __FILE_FULL_PATH__, size_t line = __LINE__) @safe @nogc
    {
        callInFiber(fh, {
                dumpStackTrace(text, file, line);
            });
    }
}

// Expose the conversion to/from ReactorFiber only to the reactor package
package ReactorFiber* to(T : ReactorFiber*)(FiberIdx fidx) nothrow @safe @nogc {
    if (!fidx.isValid)
        return null;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    return &theReactor.allFibers[fidx.value];
}

package FiberIdx to(T : FiberIdx)(const ReactorFiber* rfp) nothrow @safe @nogc {
    if (rfp is null)
        return FiberIdx.invalid;

    ASSERT!"Reactor is not open"( theReactor.isOpen );
    auto idx = rfp - &theReactor.allFibers.arr[0];
    DBG_ASSERT!"Reactor fiber pointer not pointing to fibers pool: base %s ptr %s idx %s"(
            idx>=0 && idx<theReactor.allFibers.arr.length, &theReactor.allFibers.arr[0], rfp, idx);
    return FiberIdx( cast(ushort)idx );
}

package FiberIdx to(T : FiberIdx)(FiberId fiberId) nothrow @safe @nogc {
    return FiberIdx( fiberId.value & theReactor.maxNumFibersMask );
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
    /**
     * Run a test inside a reactor
     *
     * This is a convenience function for running a UT as a reactor fiber. A new reactor will be initialized, `dg` called
     * and the reactor will automatically stop when `dg` is done.
     */
    int testWithReactor(int delegate() dg, Reactor.OpenOptions options = Reactor.OpenOptions.init) {
        sigset_t emptyMask;
        errnoEnforceNGC( sigprocmask( SIG_SETMASK, &emptyMask, null )==0, "sigprocmask failed" );

        theReactor.setup(options);
        scope(success) theReactor.teardown();

        bool delegateReturned = false;

        void wrapper() {
            int ret;
            try {
                ret = dg();

                delegateReturned = true;
            } catch(ReactorExit ex) {
                LOG_EXCEPTION(ex);
                assert(false, "testWithReactor's body called theReactor.stop explicitly");
            } catch(FiberInterrupt ex) {
                LOG_EXCEPTION(ex);
                theReactor.stop();
            } catch(Throwable ex) {
                // No need to stop the reactor - the exception thrown will teminate it
                LOG_EXCEPTION(ex);
                ERROR!"Test terminated abnormally"();
                throw ex;
            }

            theReactor.stop( ret );
        }

        theReactor.spawnFiber(&wrapper);
        int ret = theReactor.start();
        assert (delegateReturned, "testWithReactor called with a delegate that threw without returning");

        return ret;
    }

    /// ditto
    void testWithReactor(void delegate() dg, Reactor.OpenOptions options = Reactor.OpenOptions.init) {
        int wrapper() {
            dg();

            return 0;
        }

        testWithReactor(&wrapper, options);
    }

    public import mecca.runtime.ut: mecca_ut;

    mixin template TEST_FIXTURE_REACTOR(FIXTURE) {
        import mecca.runtime.ut: runFixtureTestCases;
        import mecca.reactor: testWithReactor, Reactor;
        unittest {
            Reactor.OpenOptions options;

            static if( __traits(hasMember, FIXTURE, "reactorOptions") ) {
                options = FIXTURE.reactorOptions;
            }

            testWithReactor({
                    try {
                        runFixtureTestCases!(FIXTURE)();
                    } catch( Throwable ex ) {
                        import mecca.log: LOG_EXCEPTION;
                        import mecca.lib.exception: DIE;

                        LOG_EXCEPTION(ex);
                        DIE("UT failed due to exception");
                    }
                }, options);
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
            theReactor.yield();
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
        INFO!"Fiber %s sleeping for %s"(theReactor.currentFiberHandle, duration.toString);
        theReactor.sleep(duration);
        auto now = TscTimePoint.hardNow;
        counter++;
        INFO!"Fiber %s woke up after %s, overshooting by %s counter is %s"(theReactor.currentFiberHandle, (now - start).toString,
                ((now-start) - duration).toString, counter);
    }

    void ender() {
        INFO!"Fiber %s ender is sleeping for 250ms"(theReactor.currentFiberHandle);
        theReactor.sleep(dur!"msecs"(250));
        INFO!"Fiber %s ender woke up"(theReactor.currentFiberHandle);

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
            theReactor.suspendCurrentFiber( Timeout(dur!"msecs"(4)) );
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
        handles[0].cancelTimer();
        handles[6].cancelTimer();

        // Wait for all timers to run
        theReactor.sleep(dur!"msecs"(200));

        assert(a == 0b1011_1111);
        ASSERT!"Recurring timer should run 29 times, ran %s"(recurringCounter>=25 && recurringCounter<=30, recurringCounter); // 203ms / 7

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
        assertEQ( theReactor.getFiberState(theReactor.currentFiberHandle), FiberState.Running );
        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Starting], 0 );
        auto fib = theReactor.spawnFiber(&fib2);
        assertEQ( theReactor.getFiberState(fib), FiberState.Starting );
        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Starting], 1 );

        evt1.wait();

        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Starting], 0 );
        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Sleeping], 2 );
        theReactor.throwInFiber(fib, new TheException);
        // The following should be "1", because the state would switch to Scheduled. Since that's not implemented yet...
        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Sleeping], 2 ); // Should be 1
        assertEQ( theReactor.reactorStats.fibersHistogram[FiberState.Scheduled], 0 ); // Should 1
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

unittest {
    // No automatic failing, but at least exercise the *_AS loggers
    import mecca.reactor.sync.event;
    Event finish;

    META!"#UT exercise log_AS functions"();

    void fiberFunc() {
        DEBUG!"Fiber started"();
        finish.wait();
        DEBUG!"Fiber finished"();
    }

    void testBody() {
        auto fh = theReactor.spawnFiber(&fiberFunc);
        theReactor.yield();

        DEBUG!"Main fiber logging as %s"(fh);
        theReactor.DEBUG_AS!"DEBUG trace with argument %s"(fh, 17);
        theReactor.INFO_AS!"INFO trace"(fh);
        theReactor.WARN_AS!"WARN trace"(fh);
        theReactor.ERROR_AS!"ERROR trace"(fh);
        theReactor.META_AS!"META trace"(fh);

        DEBUG!"Killing fiber"();
        finish.set();
        theReactor.yield();

        DEBUG!"Trying to log as dead fiber"();
        theReactor.DEBUG_AS!"DEBUG trace on dead fiber with argument %s"(fh, 18);
    }

    testWithReactor(&testBody);
}

unittest {
    // Make sure we do not immediately repeat the same FiberId on relaunch
    FiberId fib;

    void test1() {
        fib = theReactor.currentFiberId();
    }

    void test2() {
        assert(theReactor.currentFiberId() != fib);
    }

    testWithReactor({
            theReactor.spawnFiber(&test1);
            theReactor.yield();
            theReactor.spawnFiber(&test2);
            theReactor.yield();
        });
}

unittest {
    // Make sure that FiberHandle can return a ReactorFiber*
    static void fiberBody() {
        assert( theReactor.currentFiberPtr == theReactor.currentFiberHandle.get() );
    }

    testWithReactor({
            theReactor.spawnFiber!fiberBody(); // Run twice to make sure the genration isn't 0
            theReactor.yield();
            theReactor.spawnFiber!fiberBody();
            theReactor.yield();
        });
}

unittest {
    int ret = testWithReactor( { return 17; } );

    assert( ret==17 );
}

unittest {
    // test priority of scheduled fibers

    uint gen;
    string[] runOrder;

    void verify(bool Priority)(string id) {

        static if( Priority ) {
            auto priorityWatcher = theReactor.boostFiberPriority();
        }
        theReactor.suspendCurrentFiber();
        runOrder ~= id;
    }

    testWithReactor({
            FiberHandle[] fh;
            fh ~= theReactor.spawnFiber(&verify!false, "reg1");
            fh ~= theReactor.spawnFiber(&verify!false, "reg2");
            fh ~= theReactor.spawnFiber(&verify!false, "imm1"); // Scheduled immediate
            fh ~= theReactor.spawnFiber(&verify!true, "pri1");
            fh ~= theReactor.spawnFiber(&verify!false, "imm2"); // Scheduled immediate
            fh ~= theReactor.spawnFiber(&verify!true, "pri2");
            fh ~= theReactor.spawnFiber(&verify!false, "reg3");
            fh ~= theReactor.spawnFiber(&verify!true, "pri3"); // reg1 bypasses this one in order to avoid starvation
            fh ~= theReactor.spawnFiber(&verify!false, "imm3"); // Scheduled immediate
            theReactor.yield();
            foreach(i; 0..fh.length)
                theReactor.resumeFiber( fh[i], i==2 || i==4 );

            // Resuming immediate an already scheduled fiber should change its priority
            theReactor.resumeFiber( fh[8], true );

            theReactor.yield();
            assertEQ(["imm1", "imm2", "imm3", "pri1", "pri2", "reg1", "pri3", "reg2", "reg3"], runOrder);
        });
}

unittest {
    // Test join

    static void fiberBody() {
        theReactor.yield();
        theReactor.yield();
        theReactor.yield();
    }

    testWithReactor({
            FiberHandle fh = theReactor.spawnFiber!fiberBody();
            assertEQ( theReactor.getFiberState(fh), FiberState.Starting );
            theReactor.yield();
            assertEQ( theReactor.getFiberState(fh), FiberState.Scheduled );
            theReactor.joinFiber(fh);
            assertEQ( theReactor.getFiberState(fh), FiberState.None );
            theReactor.joinFiber(fh, Timeout(Duration.zero));
        });
}

unittest {
    testWithReactor({
            void doNothing() {
                while( true )
                    theReactor.sleep(1.msecs);
            }

            FiberHandle[] handles;
            handles ~= theReactor.spawnFiber(&doNothing);
            handles ~= theReactor.spawnFiber(&doNothing);
            theReactor.sleep(5.msecs);

            foreach(fh; handles) {
                theReactor.throwInFiber!FiberKilled(fh);
            }

            DEBUG!"Sleeping for 1ms"();
            theReactor.sleep(1.msecs);
            DEBUG!"Woke up from sleep"();
        });
}

unittest {
    testWithReactor({
            static void fiber() {
                theReactor.sleep(1.seconds);
            }

            auto fh = theReactor.spawnFiber!fiber();

            DEBUG!"Starting test"();
            foreach(i; 0..4) {
                theReactor.LOG_TRACEBACK_AS(fh, "test");
                DEBUG!"Back in fiber"();
                theReactor.yield();
            }
            DEBUG!"Test ended"();
        });
}

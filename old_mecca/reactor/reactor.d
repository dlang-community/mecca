module mecca.reactor.reactor;

import std.exception;
import std.string;
import std.traits;
import core.atomic;
import core.thread;
import core.memory: GC;

import mecca.lib.time;
import mecca.lib.exception;
import mecca.lib.bits;
import mecca.lib.memory;
import mecca.lib.reflection;
import mecca.lib.hacks;
import mecca.containers.linked_set;
import mecca.containers.pools;

import mecca.lib.tracing;
import mecca.reactor.fibers;
import mecca.reactor.transports;
import mecca.reactor.time_queue;
import mecca.reactor.threading;
import mecca.reactor.misc;


@notrace package struct TimedCallback {
    TscTimePoint timePoint;
    long intervalCycles;
    Closure callback;
    Chain _chain;
}

@notrace struct _TCBCookie {}
alias TCBCookie = _TCBCookie*;

class ReactorExit: Error {
    __gshared static ReactorExit singleton = new ReactorExit();
    this() {super("ReactorExit");}
}

class FiberTimeout: Exception {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

@notrace struct SuspenseToken {
    enum phantomType = true;

    @disable this();
    @disable this(this);
    @disable void opAssign(T)(auto ref T x);
    @disable static typeof(this) init();
}

struct Reactor {
    enum timeQueueResolution = 50.usecs;

package:
    bool _opened;
    bool _running;
    uint criticalSectionNesting;

    void delegate()[] idleCallbacks;
    ReactorFiber[] allFibers;
    TscTimePoint lastMainloopVisit;

    static struct Stats {
        TscTimePoint startTime;
        long idleCycles;
        ulong iterations;
        ulong idleIterations;

        @property long totalCycles() {
            return TscTimePoint.now.cycles - startTime.cycles;
        }
        @property Duration totalDuration() {
            return TscTimePoint.toDuration(totalCycles);
        }
        @property float idlePercent() {
            return (cast(double)idleCycles) / totalCycles();
        }
    }

    LinkedSetWithLength!ReactorFiber scheduledFibers;
    LinkedSetWithLength!ReactorFiber pendingFibers;
    LinkedSetWithLength!ReactorFiber defunctFibers;

    FixedPool!TimedCallback tcbPool;
    CascadingTimeQueue!(tcbPool.Ptr, 256, 4) ctq;

    long MAX_CALLBACK_TIME_CYCLES;
    long OUTRAGEOUS_CALLBACK_TIME_CYCLES;
    long FIBER_TIMESLOT_GOAL_CYCLES;
    long MAX_FIBER_TIMESLOT_CYCLES;
    long OUTRAGEOUS_FIBER_TIMESLOT_CYCLES;

public:
    static struct Options {
        uint maxFDs = 1024;
        uint maxCallbacks = 16 * 1024;
        uint fiberStackSize = 32 * 1024;
        uint numThreadsInPool = 2;
        uint numFibers = 128;
        Duration hangDetectorGrace = 60.seconds;
        Duration gcInterval = 30.seconds;
        bool userlandPolling = false;
        bool setupSegfaultHandler = true;
        bool handDetectorEnabled = true;
        Duration memoryStatsInterval = 3.minutes;
    }
    Options options;
    Stats stats;

    void open() {
        assert (!_opened);
        ensureCoherency();

        _opened = true;
        _running = false;
        setInitTo(stats);
        tcbPool.open(options.maxCallbacks);
        ctq.open(timeQueueResolution, TscTimePoint.now);
        idleCallbacks.length = 0;
        idleCallbacks.reserve(20);

        assert (options.numFibers <= ReactorFiber.MAX_FIBERS, "%s > %s".format(options.numFibers, ReactorFiber.MAX_FIBERS));
        allFibers.length = options.numFibers;
        foreach(ref fib; allFibers) {
            fib = new ReactorFiber(options.fiberStackSize);
            defunctFibers.append(fib);
        }

        initTransports();
        initThreading();
        initMisc();

        // GC
        if (theReactor.options.gcInterval > Duration.zero) {
            theReactor.callEvery(theReactor.options.gcInterval, &collectGarbage);
        }

        FIBER_TIMESLOT_GOAL_CYCLES = TscTimePoint.toCycles(usecs(50));
        if (theReactor.options.userlandPolling) {
            MAX_CALLBACK_TIME_CYCLES = TscTimePoint.toCycles(usecs(200));
            OUTRAGEOUS_CALLBACK_TIME_CYCLES = TscTimePoint.toCycles(usecs(400));
            MAX_FIBER_TIMESLOT_CYCLES = TscTimePoint.toCycles(usecs(1000));
            OUTRAGEOUS_FIBER_TIMESLOT_CYCLES = TscTimePoint.toCycles(usecs(5000));
        }
        else {
            MAX_CALLBACK_TIME_CYCLES = TscTimePoint.toCycles(usecs(50));
            OUTRAGEOUS_CALLBACK_TIME_CYCLES = TscTimePoint.toCycles(usecs(200));
            MAX_FIBER_TIMESLOT_CYCLES = TscTimePoint.toCycles(usecs(200));
            OUTRAGEOUS_FIBER_TIMESLOT_CYCLES = TscTimePoint.toCycles(usecs(800));
        }
    }

    @property bool closed() const pure nothrow @nogc {
        return !_opened;
    }
    @property bool running() const pure nothrow @nogc {
        return _running;
    }
    @notrace package void ensureCoherency(string func=__FUNCTION__) nothrow const @nogc {
        pragma(inline, true);
        ASSERT(isMainThread(), "%s must be called from main thread", func);
        ASSERT(_opened, "Reactor closed");
    }

    void close() {
        ensureCoherency();
        assert(Fiber.getThis() is null, "Reactor.close() must not be called from a fiber");

        setInitTo(options);
        if (!_opened) {
            return;
        }

        criticalSectionNesting = 0;
        finiMisc();
        finiThreading();
        finiTransports();

        foreach(fib; allFibers) {
            assert (fib.state != ReactorFiber.State.EXEC);
            if (fib.state == ReactorFiber.State.HOLD) {
                fib.throwInFiber(ReactorExit.singleton);
                auto ex = fib.execute();
                assert(fib.state == Fiber.State.TERM, "Fiber did not terminate");
                //assert(ex && cast(Throwable)ex, "Fiber must not have caught ReactorExit!");
            }
            fib.recycle();
        }
        scheduledFibers.removeAll();
        pendingFibers.removeAll();
        defunctFibers.removeAll();
        allFibers = null;
        idleCallbacks.length = 0;

        tcbPool.close();
    }

    @notrace void mainloop() {
        ensureCoherency();
        assert (!_running);
        _running = true;
        scope(exit) _running = false;

        GC.disable();
        scope(exit) GC.enable();

        stats.startTime = TscTimePoint.now;
        stats.idleCycles = 0;
        TscTimePoint idleStarted;
        TscTimePoint nextRunCallbacks;
        bool isIdle = false;

        while (_running) {
            auto t0 = TscTimePoint.now;
            auto t1 = t0;
            lastMainloopVisit = t0;

            bool ranCb = false;
            if (t0.cycles > nextRunCallbacks.cycles) {
                ranCb = runCallbacks(t1);
                if (t1.cycles - t0.cycles > MAX_CALLBACK_TIME_CYCLES && !scheduledFibers.empty) {
                    // give a penalty to the callbacks
                    nextRunCallbacks = t1 + 2 * FIBER_TIMESLOT_GOAL_CYCLES;
                }
            }
            auto ranFib = runFiber(t1);

            if (!ranFib && !ranCb) {
                if (!isIdle) {
                    isIdle = true;
                    idleStarted = t0;
                }
                stats.idleIterations++;
                runIdleCallbacks(t0);
            }
            else {
                if (isIdle) {
                    isIdle = false;
                    stats.idleCycles += t0.cycles - idleStarted.cycles;
                }
                //else if (t0.cycles - idleStart.cycles >= TscTimePoint.cyclesPerSecond) {
                //    // update every second (in case no fibers ran)
                //    IDLE_CYCLES += t0.cycles - idleStart.cycles;
                //    idleStart = t0;
                //}
            }
            stats.iterations++;
        }
    }

    void stop() {
        ensureCoherency();
        _running = false;
    }

    @notrace private bool runFiber(TscTimePoint t0) {
        ReactorFiber fib = scheduledFibers.popHead();
        if (fib is null) {
            return false;
        }
        fib.prefetch();
        fib.timeExecuted = t0;
        auto lastTrace = getTraceEntryIndex();
        auto obj = fib.execute();
        updateFiberStats(fib, lastTrace);

        if (obj !is null) {
            auto ex = cast(Throwable)obj;
            assert (ex !is null, "ex is not a Throwable");
            ERROR!"#REACTOR fiber exception hits mainloop"();
            LOG_TRACEBACK("Exception reached reactor mainloop", ex);
            throw ex;
        }
        if (fib.state == ReactorFiber.State.TERM) {
            fib.recycle();
            defunctFibers.prepend(fib);
        }
        else {
            assert (fib.state == ReactorFiber.State.HOLD);
            pendingFibers.append(fib);
        }
        return true;
    }
    @notrace void updateFiberStats(ReactorFiber fib, TraceEntryIndex lastTrace) {
        auto now = TscTimePoint.now;
    }

    @notrace private bool runCallbacks(ref TscTimePoint now) {
        TimedCallback* tcb;
        bool anyRun = false;
        auto t0 = now;
        auto t1 = now;
        while ((tcb = ctq.pop(now)) !is null) {
            tcb.callback();
            t1 = TscTimePoint.now;
            auto dt = t1.cycles - t0.cycles;
            t0 = t1;
            anyRun = true;

            if (dt > MAX_CALLBACK_TIME_CYCLES) {
                if (dt > OUTRAGEOUS_CALLBACK_TIME_CYCLES) {
                    ERROR!"#DELAY callback %s took %s us"(tcb.callback.funcptr, TscTimePoint.to!"usecs"(dt));
                }
                else {
                    WARN!"#DELAY callback %s took %s us"(tcb.callback.funcptr, TscTimePoint.to!"usecs"(dt));
                }
            }

            if (tcb.intervalCycles == 0) {
                // non-recurring
                tcbPool.release(tcb);
            }
            else if (tcb.intervalCycles > 0) {
                // aligned, recurring
                tcb.timePoint += (1 + (t0.cycles - tcb.timePoint.cycles) / tcb.intervalCycles) * tcb.intervalCycles;

                //auto desired = ((TscTimePoint.softNow.cycles - tcb.baseTimePoint.cycles) / intervalCycles) * intervalCycles;
                //tcb.timePoint = tcb.baseTimePoint + desired + intervalCycles;
            }
            else if (tcb.intervalCycles < 0) {
                // non-aligned, recurring
                tcb.timePoint = t0 + (-tcb.intervalCycles);
            }
        }

        // update `now` in caller
        now = t1;
        return anyRun;
    }

    @notrace private void runIdleCallbacks(TscTimePoint t0) {
        foreach(dg; idleCallbacks) {
            dg();
            auto t1 = TscTimePoint.now;
            auto dt = t1.cycles - t0.cycles;
            t0 = t1;

            if (dt > MAX_CALLBACK_TIME_CYCLES) {
                if (dt > OUTRAGEOUS_CALLBACK_TIME_CYCLES) {
                    ERROR!"#DELAY idle callback %s took %s us"(dg.funcptr, TscTimePoint.to!"usecs"(dt));
                }
                else {
                    WARN!"#DELAY idle callback %s took %s us"(dg.funcptr, TscTimePoint.to!"usecs"(dt));
                }
            }
        }
    }

    GCStats _gcStatsBeforeScan;
    GCStats _gcStatsAfterScan;

    @notrace public void collectGarbage() {
        // garbage must be collected every so often, and it must not be called from a fiber
        // as it may recurse deeply and reach the guard page (causing SEGFAULT)

        enum GC_SIZE_TO_SCAN = 20 * 1024*1024;
        enum GC_POOL_MINIMIZE_SIZE = 200 * 1024*1024;
        enum GC_FREE_TOO_MUCH = 30 * 1024*1024;

        ensureCoherency();
        assert(!isCalledFromFiber, "collectGarbage called from fiber");

        auto t0 = TscTimePoint.now;
        bool minimized = false;
        _gcStatsBeforeScan = getGCStats();

        if (_gcStatsAfterScan.usedsize != 0 &&
            (_gcStatsBeforeScan.usedsize - _gcStatsAfterScan.usedsize) < GC_SIZE_TO_SCAN &&
            _gcStatsBeforeScan.poolsize < GC_POOL_MINIMIZE_SIZE)
        {
            DEBUG!("Diff from last #GC check was not big enough. Only %dkb added, need %s KB")(
                (_gcStatsBeforeScan.usedsize - _gcStatsAfterScan.usedsize) / 1024, GC_SIZE_TO_SCAN / 1024);
            return;
        }
        INFO!"#GC started stats: %s"(_gcStatsBeforeScan);
        GC.enable();
        GC.collect();
        if (_gcStatsBeforeScan.poolsize > GC_POOL_MINIMIZE_SIZE) {
            GC.minimize();
            minimized = true;
        }
        GC.disable();

        auto t1 = TscTimePoint.now;
        _gcStatsAfterScan = getGCStats();
        auto _gcLastScanTime = t1.diff!"usecs"(t0);
        INFO!"#GC #DELAY finished (minimized=%s) after %d us. stats: %s"(minimized, _gcLastScanTime, _gcStatsAfterScan);
        if ((_gcStatsBeforeScan.usedsize - _gcStatsAfterScan.usedsize) > GC_FREE_TOO_MUCH) {
            WARN!"#GC last GC collect freed too much memory! %dkb"((_gcStatsBeforeScan.usedsize - _gcStatsAfterScan.usedsize) / 1024);
        }

        // don't account collection as idle time
        //anyScheduled = true;
    }

    //
    // callbacks
    //
    @notrace private TimedCallback* _allocTCB(TscTimePoint tp, long intervalCycles = 0) {
        ensureCoherency();
        auto tcb = tcbPool.alloc();
        tcb.timePoint = tp;
        tcb.intervalCycles = intervalCycles;
        ctq.insert(tcb);
        return tcb;
    }

    @notrace void call(T)(T cb) {
        _allocTCB(TscTimePoint.zero).callback.set(cb);
    }
    @notrace void call(alias F)(Parameters!F args) {
        _allocTCB(TscTimePoint.zero).callback.set!F(args);
    }
    @notrace TCBCookie callIn(T)(Duration dur, T cb) {
        auto tcb = _allocTCB(TscTimePoint.now + dur);
        tcb.callback.set(cb);
        return cast(TCBCookie)tcb;
    }
    @notrace TCBCookie callIn(alias F)(Duration dur, Parameters!F args) {
        auto tcb = _allocTCB(TscTimePoint.now + dur);
        tcb.callback.set!F(args);
        return cast(TCBCookie)tcb;
    }
    @notrace TCBCookie callAt(T)(TscTimePoint tp, T cb) {
        auto tcb = _allocTCB(tp);
        tcb.callback.set(cb);
        return cast(TCBCookie)tcb;
    }
    @notrace TCBCookie callAt(alias F)(TscTimePoint tp, Parameters!F args) {
        auto tcb = _allocTCB(tp);
        tcb.callback.set!F(args);
        return cast(TCBCookie)tcb;
    }
    @notrace TCBCookie callEvery(T)(Duration interval, T cb, bool aligned=true, bool delayed=false) {
        auto cyc = TscTimePoint.toCycles(interval);
        auto tcb = _allocTCB(delayed ? TscTimePoint.now + cyc : TscTimePoint.now, aligned ? cyc : -cyc);
        tcb.callback.set(cb);
        return cast(TCBCookie)tcb;
    }
    @notrace TCBCookie callEvery(alias F, bool aligned=false, bool delayed=false)(Duration interval, Parameters!F args) {
        auto cyc = TscTimePoint.toCycles(interval);
        auto tcb = _allocTCB(delayed ? TscTimePoint.now + cyc : TscTimePoint.now, aligned ? cyc : -cyc);
        tcb.callback.set!F(args);
        return cast(TCBCookie)tcb;
    }

    @notrace void cancelCall(ref TCBCookie cookie) {
        if (!_opened) {
            cookie = null;
            return;
        }
        ensureCoherency();
        auto tcb = tcbPool.Ptr(cast(TimedCallback*)cookie);
        if (tcb !is null) {
            ctq.discard(tcb);
            tcb.release();
            cookie = null;
        }
    }

    void registerPoller(void delegate() dg, Duration interval = 200.usecs, bool idle = false) {
        callEvery(interval, dg);
        if (idle) {
            idleCallbacks ~= dg;
        }
    }

    void registerIdlePoller(void delegate() dg) {
        ensureCoherency();
        idleCallbacks ~= dg;
    }

    //
    // fibers
    //
    @notrace private ReactorFiber _spawnFiber() {
        ensureCoherency();
        auto fib = defunctFibers.popHead();
        ASSERT(fib !is null, "Out of fibers");
        scheduledFibers.append(fib);
        return fib;
    }

    @notrace FiberHandle spawnFiber(void delegate() dg) {
        auto fib = _spawnFiber();
        fib.closure.set(dg);
        return FiberHandle(fib);
    }
    @notrace FiberHandle spawnFiber(void function() fn) {
        auto fib = _spawnFiber();
        fib.closure.set(fn);
        return FiberHandle(fib);
    }
    @notrace FiberHandle spawnFiber(alias F)(Parameters!F args) {
        auto fib = _spawnFiber();
        fib.closure.set!F(args);
        return FiberHandle(fib);
    }

    @notrace bool throwInFiber(FiberHandle fib, Throwable ex) {
        if (auto f = fib.get()) {
            INFO!"#REACTOR throwing %s into %s"(typeid(ex).name, f.fiberId);
            f.prioritized = true;
            f.throwInFiber(ex);
            resumeFiber(f);
            return true;
        }
        else {
            return false;
        }
    }
    @notrace bool throwInFiberAndJoin(FiberHandle fib, Throwable ex) {
        return false;
    }

    @notrace package void suspendThisFiber(Timeout timeout) {
        ensureCoherency();
        assert (_thisFiber !is null, "Suspend called from non-fiber");
        assert (criticalSectionNesting == 0, "Context-switch inside a critical section");

        scheduledFibers.prefetchHead();

        if (timeout == Timeout.elapsed) {
            throw new FiberTimeout("Fiber operation did not finish in time");
        }

        TCBCookie cookie;
        bool timedOut = false;

        if (timeout != Timeout.infinite) {
            static void timeouter(ReactorFiber fib, TCBCookie* cookie, bool* timedOut) {
                *cookie = null;
                if (theReactor.resumeFiber(fib)) {
                    // blow up only if we're the ones who resumed the fiber. this prevents a race when
                    // someone else had already woken the fiber, but it just didn't get time to run
                    // while the timer expired. this probably indicates fibers hogging the CPU for
                    // too long (starving others)
                    *timedOut = true;
                }
                else {
                    fib.WARN_AS!"#REACTOR fiber timeout expired but fiber already scheduled (starvation): %s scheduled, %s pending"(
                        theReactor.scheduledFibers.length, theReactor.pendingFibers.length);
                }
            }
            cookie = callAt!timeouter(timeout.expiry, _thisFiber, &cookie, &timedOut);
        }

        try {
            _thisFiber.suspend();
        }
        finally {
            if (cookie) {
                cancelCall(cookie);
            }
            version(assert) _thisFiber.suspendCounter++;
        }

        if (timedOut) {
            throw mkEx!FiberTimeout("Fiber operation did not finish in time");
        }
    }
    @notrace package bool resumeFiber(FiberHandle fib) {
        if (auto f = fib.get()) {
            return resumeFiber(f);
        }
        else {
            return false;
        }
    }
    @notrace package bool resumeFiber(ReactorFiber fib) {
        assert(fib !is null, "fib is null");
        assert(fib.state == ReactorFiber.State.HOLD /*, "Wrong fiber state: %s".format(fib.state)*/);

        if (fib in pendingFibers) {
            pendingFibers.remove(fib);
            if (fib.prioritized) {
                scheduledFibers.prepend(fib);
                fib.prioritized = false;
            }
            else {
                scheduledFibers.append(fib);
            }
            fib.timeResumed = TscTimePoint.now;
            return true;
        }
        else {
            assert(fib in scheduledFibers /*, "Scheduling a defunct fiber %s".format(fib)*/);
            return false;
        }
    }

    //
    // Fiber services
    //
    @property public auto numUsedFibers() {
        return allFibers.length - defunctFibers.length;
    }
    @notrace void joinFiber(FiberHandle fib, Timeout timeout = Timeout.infinite) {
    }

    @property bool isCalledFromFiber() const nothrow @nogc {
        ensureCoherency();
        return _thisFiber !is null;
    }
    @property FiberHandle thisFiber() nothrow @nogc {
        ensureCoherency();
        return FiberHandle(_thisFiber);
    }

    /// Prioritize the calling fiber. This should be done before going to sleep on some operation,
    /// after which this fiber has *very little* work to do (basically just folding up). This is intended
    /// to reduce IO latency and enable run-to-completion
    @notrace void prioritizeThisFiber() {
        ensureCoherency();
        assert (_thisFiber, "Must be called from a fiber");
        _thisFiber.prioritized = true;
    }
    @notrace void unprioritizeThisFiber() {
        ensureCoherency();
        assert (_thisFiber, "Must be called from a fiber");
        _thisFiber.prioritized = true;
    }

    @notrace auto criticalSection() {
        ensureCoherency();
        @notrace static struct CriticalSection {
            Reactor* reactor;
            @disable this();
            @disable this(this);

            this(Reactor* reactor) {
                this.reactor = reactor;
                reactor.criticalSectionNesting++;
            }
            ~this() {
                assert (reactor.criticalSectionNesting > 0);
                reactor.criticalSectionNesting--;
            }
        }
        return CriticalSection(&this);
    }
    @property bool isInCriticalSection() {
        return criticalSectionNesting > 0;
    }

    @notrace void delay(Duration dur) {
        static void resumer(FiberHandle fib) {
            theReactor.resumeFiber(fib);
        }
        callIn!resumer(dur, theReactor.thisFiber);
        suspendThisFiber(Timeout.infinite);
    }

    @notrace void contextSwitch() {
        static void resumer(FiberHandle fib) {
            theReactor.resumeFiber(fib);
        }
        call!resumer(theReactor.thisFiber);
        suspendThisFiber(Timeout.infinite);
    }
}

align(64) __gshared Reactor theReactor;





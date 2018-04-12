module mecca.reactor.subsystems.threading;

import core.atomic;
import core.thread;
import core.sys.posix.signal;
import std.exception;

import mecca.platform.linux: gettid, OSSignal;
import mecca.lib.reflection;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.lib.typedid: TypedIdentifier;

import mecca.containers.otm_queue: DuplexQueue;
import mecca.containers.arrays: FixedString;
import mecca.containers.pools: FixedPool;

import mecca.log;
import mecca.reactor: theReactor, FiberHandle, TimerHandle;


class WorkerThread: Thread {
    __gshared static immutable BLOCKED_SIGNALS = [
        OSSignal.SIGHUP, OSSignal.SIGINT, OSSignal.SIGQUIT,
        //OSSignal.SIGILL, OSSignal.SIGTRAP, OSSignal.SIGABRT,
        //OSSignal.SIGBUS, OSSignal.SIGFPE, OSSignal.SIGKILL,
        //OSSignal.SIGUSR1, OSSignal.SIGSEGV, OSSignal.SIGUSR2,
        OSSignal.SIGPIPE, OSSignal.SIGALRM, OSSignal.SIGTERM,
        //OSSignal.SIGSTKFLT, OSSignal.SIGCONT, OSSignal.SIGSTOP,
        OSSignal.SIGCHLD, OSSignal.SIGTSTP, OSSignal.SIGTTIN,
        OSSignal.SIGTTOU, OSSignal.SIGURG, OSSignal.SIGXCPU,
        OSSignal.SIGXFSZ, OSSignal.SIGVTALRM, OSSignal.SIGPROF,
        OSSignal.SIGWINCH, OSSignal.SIGIO, OSSignal.SIGPWR,
        //OSSignal.SIGSYS,
    ];

    __gshared static void delegate(WorkerThread) preThreadFunc;

    align(8) int kernel_tid = -1;
    void delegate() dg;

    this(void delegate() dg, size_t stackSize = 0) {
        kernel_tid = -1;
        this.dg = dg;
        this.isDaemon = true;
        super(&wrapper, stackSize);
    }

    private void wrapper() nothrow {
        scope(exit) kernel_tid = -1;
        kernel_tid = gettid();

        sigset_t sigset = void;
        ASSERT!"sigemptyset failed"(sigemptyset(&sigset) == 0);
        foreach(sig; BLOCKED_SIGNALS) {
            ASSERT!"sigaddset(%s) failed"(sigaddset(&sigset, sig) == 0, sig);
        }
        foreach(sig; SIGRTMIN .. SIGRTMAX /* +1? */) {
            ASSERT!"sigaddset(%s) failed"(sigaddset(&sigset, sig) == 0, sig);
        }
        ASSERT!"pthread_sigmask failed"(pthread_sigmask(SIG_BLOCK, &sigset, null) == 0);

        try {
            if (preThreadFunc) {
                // set sched priority, move to CPU set
                preThreadFunc(this);
            }
            dg();
        }
        catch (Throwable ex) {
            try{import std.stdio; writeln(ex);} catch(Throwable){}
            ASSERT!"WorkerThread threw %s(%s)"(false, typeid(ex).name, ex.msg);
            assert(false);
        }
    }
}

class DeferredTaskFailed: Exception {
    mixin ExceptionBody;
}

alias DeferredTaskCookie = TypedIdentifier!("DeferredTaskCookie", ulong, ulong.max, ulong.max);

struct DeferredTask {
    Closure taskClosure;
    Closure finiClosure;
    TscTimePoint timeAdded;
    TscTimePoint timeFinished;
    bool hasException;
    FiberHandle fibHandle;

    union {
        void[128] result;
        struct {
            string excType;
            string excFile;
            size_t excLine;
            FixedString!80 excMsg;
        }
    }

    @property DeferredTaskCookie cookie() const pure @nogc nothrow {
        return DeferredTaskCookie(timeAdded.cycles);
    }

    @notrace void set(alias F, alias Fini = null)(Parameters!F args) {
        static if( !is( typeof(Fini) == typeof(null) ) ) {
            static assert(
                    is( Parameters!F == Parameters!Fini ), "Fini parameters must match callback parameters");
            static assert(
                    is( ReturnType!Fini == void ),
                    "Fini callback must be of type void, not " ~ ReturnType!Fini.stringof );
        }

        alias R = ReturnType!F;
        static if (is(R == void)) {
            taskClosure.set!F(args);
        }
        else {
            static assert (R.sizeof <= result.sizeof);
            static void wrapper(void* res, Parameters!F args) {
                *cast(R*)res = F(args);
            }
            taskClosure.set!wrapper(result.ptr, args);
        }

        static if( !is( typeof(Fini) == typeof(null) ) ) {
            finiClosure.set!Fini(args);
        }
    }

    void execute() {
        // called on worker thread
        if (!fibHandle.isValid()) {
            DEBUG!"#THD no fiber is waiting for %s"(cookie);
            return;
        }

        scope(exit) timeFinished = TscTimePoint.hardNow;
        hasException = false;
        try {
            DEBUG!"#THD running %s in thread"(cookie);
            taskClosure();
        }
        catch (Throwable ex) {
            hasException = true;
            excType = typeid(ex).name;
            excMsg.safeSetPrefix(ex.msg);
            excFile = ex.file;
            excLine = ex.line;
        }
    }

    @notrace void runFinalizer() nothrow {
        try {
            finiClosure();
        } catch(Exception ex) {
            ASSERT!"Thread finalizer should never throw. Threw \"%s\""(false, ex.msg);
        }
    }
}

private extern(C) nothrow @system @nogc {
    import core.sys.posix.pthread: pthread_mutex_t;

    // these are not marked as @nogc in some versions of phobos
    int pthread_mutex_lock(pthread_mutex_t*);
    int pthread_mutex_unlock(pthread_mutex_t*);
}

private struct PthreadMutex {
    pthread_mutex_t mtx;

    void lock() nothrow @nogc {
        ASSERT!"pthread_mutex_lock"(pthread_mutex_lock(&mtx) == 0);
    }
    void unlock() nothrow @nogc {
        ASSERT!"pthread_mutex_unlock"(pthread_mutex_unlock(&mtx) == 0);
    }
}

struct ThreadPool(ushort numTasks) {
    enum MAX_FETCH_STREAK = 32;

private:
    alias PoolType = FixedPool!(DeferredTask, numTasks);
    alias IdxType = PoolType.IdxType;
    enum IdxType POISON = IdxType.max >> 1;
    static assert (numTasks < POISON);

    bool active;
    bool threadExited;
    shared long numActiveThreads;
    PthreadMutex pollerThreadMutex;
    Duration pollingInterval;
    WorkerThread[] threads;
    TimerHandle timerHandle;
    PoolType tasksPool;
    DuplexQueue!(IdxType, numTasks) queue;

public:
    void open(uint numThreads, size_t stackSize = 0, Duration threadPollingInterval = 10.msecs,
              Duration reactorPollingInterval = 500.usecs) {
        pollerThreadMutex = PthreadMutex.init;
        pollingInterval = threadPollingInterval;
        numActiveThreads = 0;
        active = true;
        threadExited = false;
        tasksPool.open();
        queue.open(numThreads);
        threads.length = numThreads;

        foreach(ref thd; threads) {
            thd = new WorkerThread(&threadFunc, stackSize);
            thd.start();
        }
        while (numActiveThreads < threads.length) {
            Thread.sleep(2.msecs);
        }
        timerHandle = theReactor.registerRecurringTimer(reactorPollingInterval, &completionCallback);
    }

    void close() {
        theReactor.cancelTimer(timerHandle);
        active = false;
        foreach(i; 0 .. threads.length) {
            queue.submitRequest(POISON);
        }
        foreach(thd; threads) {
            thd.join();
        }
        destroy(queue);
        tasksPool.close();
    }

    private DeferredTask* pullWork() nothrow @nogc {
        // only one thread will enter this function. the rest will wait on the pollerThreadMutex
        // when the function fetch some work, it will release the lock and another thread will enter
        pollerThreadMutex.lock();
        scope(exit) pollerThreadMutex.unlock();

        while (active) {
            IdxType idx;
            if (queue.pullRequest(idx)) {
                return idx == POISON ? null : tasksPool.fromIndex(idx);
            }
            else {
                Thread.sleep(pollingInterval);
            }
        }
        return null;
    }

    private void threadFunc() {
        atomicOp!"+="(numActiveThreads, 1);
        scope(exit) {
            atomicOp!"-="(numActiveThreads, 1);
            threadExited = true;
        }

        while (active) {
            auto task = pullWork();
            if (task is null || !active) {
                assert (!active);
                break;
            }

            task.execute();
            auto added = queue.submitResult(tasksPool.indexOf(task));
            ASSERT!"submitResult failed"(added);
        }
    }

    @notrace private void completionCallback() nothrow {
        assert (!threadExited);
        foreach(_; 0 .. MAX_FETCH_STREAK) {
            IdxType idx;
            if (!queue.pullResult(idx)) {
                break;
            }
            DeferredTask* task = tasksPool.fromIndex(idx);
            task.runFinalizer(); // call finalizer, if the user provided one

            DEBUG!"#THD pulled result of %s from thread"(task.cookie);
            if (task.fibHandle.isValid) {
                theReactor.resumeFiber(task.fibHandle);
                task.fibHandle = null;
            }
            else {
                // the fiber is no longer there to release it -- we must do it ourselves
                tasksPool.release(task);
            }
        }
    }

    auto deferToThread(alias F, alias Fini = null)(Timeout timeout, Parameters!F args) @nogc {
        static assert(
                is( typeof(Fini) == typeof(null) ) || hasFunctionAttributes!(Fini, "nothrow"),
                "Fini callback must be nothrow" );

        auto task = tasksPool.alloc();
        task.fibHandle = theReactor.currentFiberHandle;
        task.timeAdded = TscTimePoint.now();
        task.set!(F, Fini)(args);
        auto added = queue.submitRequest(tasksPool.indexOf(task));
        ASSERT!"submitRequest"(added);

        //
        // once submitted, the task no longer belongs (solely) to us. we go to sleep until either:
        //   * the completion callback fetched the task (suspendCurrentFiber returns)
        //   * the fiber was killed/timed out (suspendCurrentFiber throws)
        //      - note that the thread may or may not be done
        //      - if it is done, we must release it.
        //
        try {
            theReactor.suspendCurrentFiber(timeout);
        }
        catch (Throwable ex) {
            if (task.fibHandle.isValid) {
                // fiber was killed while thread still holds the task (or at least,
                // completionCallback hasn't fetched this task yet).
                // do NOT release, but mark defunct -- completionCallback will finalize and release
                task.fibHandle = null;
            }
            else {
                // thread is done with the task (completionCallback already fetched this task yet).
                // release it, since completionCallback won't do that any more.
                // the task is already finalized
                tasksPool.release(task);
            }
            throw ex;
        }

        // we reach this part if-and-only-if the thread is done with the task.
        // the task is already finalized
        if (task.hasException) {
            auto ex = mkExFmt!DeferredTaskFailed("%s: %s", task.excType, task.excMsg);
            ex.file = task.excFile;
            ex.line = task.excLine;
            tasksPool.release(task);
            throw ex;
        }
        else {
            static if (is(ReturnType!F == void)) {
                tasksPool.release(task);
            }
            else {
                auto tmp = *(cast(ReturnType!F*)task.result.ptr);
                tasksPool.release(task);
                return tmp;
            }
        }
    }
}

unittest {
    import mecca.reactor: Reactor, testWithReactor;

    __gshared static long sum;
    __gshared static long done;

    static int sleeper(Duration dur, int x) {
        Thread.sleep(dur);
        return x * 2;
    }

    static void sleeperFib(int x) {
        auto res = theReactor.deferToThread!sleeper(x.msecs, x);
        assert (res == x * 2);
        sum += x;
        done--;
    }

    Reactor.OpenOptions options;
    options.threadDeferralEnabled = true;

    testWithReactor({
        done = 0;
        foreach(int i; [10, 20, 30, 40, 50, 45, 35, 25, 15]) {
            done++;
            theReactor.spawnFiber(&sleeperFib, i);
        }

        // XXX: need semaphore
        while (done > 0) {
            theReactor.sleep(10.msecs);
        }

        assert (sum == 270);
    }, options);
}

unittest {
    import mecca.reactor;
    import mecca.reactor.sync.event;
    import mecca.reactor.types : ReactorExit;
    import std.traits;

    static struct Context {
        uint counter;
        shared bool inThread;
        Event started, done;

        void threadBody() {
            assert(!inThread, "Variable marked in thread at thread beginning");
            inThread = true;
            scope(exit) inThread = false;
            Thread.sleep(20.msecs);
        }

        static void proxyBody(Context* _this) {
            _this.threadBody();
        }

        void testFini() nothrow {
            counter++;
            done.set();
        }

        static void proxyFini(Context* _this) nothrow {
            return _this.testFini();
        }

        void testFiber() {
            started.set();
            DEBUG!"Deferring to thread"();
            theReactor.deferToThread!(proxyBody, proxyFini)(&this);
            assert(false, "Thread finished successfully when it shouldn't");
        }
    }

    void testBody() {
        Context context;

        auto handle = theReactor.spawnFiber(&context.testFiber);

        context.started.wait();
        // Wait for the thread queue to pick up the new task
        theReactor.sleep(14.msecs);
        theReactor.throwInFiber!ReactorExit(handle);
        assert(context.counter==0);
        assert(context.inThread);
        context.done.wait(Timeout(50.msecs));
        assert(!context.inThread);
        assert(context.counter==1);
    }

    Reactor.OpenOptions options;
    options.threadDeferralEnabled = true;
    testWithReactor(&testBody, options);
}

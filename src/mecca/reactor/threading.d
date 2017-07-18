module mecca.reactor.threading;

import core.atomic;
import core.thread;
import core.sync.mutex: Mutex;
import core.sys.posix.signal;
import std.exception;

import mecca.lib.lowlevel: gettid;
import mecca.lib.reflection;
import mecca.lib.exception;
import mecca.lib.time;

import mecca.containers.producer_consumer: DuplexQueue;
import mecca.containers.arrays: FixedString;
import mecca.containers.pools: FixedPool;

import mecca.reactor.reactor: theReactor, FiberHandle;


class WorkerThread: Thread {
    enum State: ubyte {
        NEW,
        RUNNING,
        DEAD,
    }

    static shared signalsToBlock = [SIGHUP, SIGINT, SIGTERM, SIGQUIT, SIGTSTP, SIGTTIN,
        SIGTTOU, SIGCHLD, SIGPIPE];

    align(8) shared State state;
    int kernel_tid = -1;
    Closure closure;

    this(void function() fn, size_t stackSize = 0) {
        atomicStore(state, State.NEW);
        closure.set(fn);
        super(&wrapper, stackSize);
    }
    this(void delegate() dg, size_t stackSize = 0) {
        atomicStore(state, State.NEW);
        closure.set(dg);
        super(&wrapper, stackSize);
    }

    private void wrapper() {
        scope(exit) {
            kernel_tid = -1;
            atomicStore(state, State.DEAD);
        }

        sigset_t sigset = void;
        errnoEnforce(sigemptyset(&sigset) == 0, "sigemptyset failed");
        foreach(sig; signalsToBlock) {
            errnoEnforce(sigaddset(&sigset, sig) == 0, "sigaddset failed");
        }
        errnoEnforce(pthread_sigmask(SIG_BLOCK, &sigset, null) == 0, "pthread_sigmask failed");

        kernel_tid = gettid();
        //_currExcBuf = &excBuf;
        atomicStore(state, State.RUNNING);

        try {
            closure();
        }
        catch (Throwable ex) {
            assert (false);
        }
    }
}

class DeferredTaskFailed: Exception {
    mixin ExceptionBody;
}

struct Task {
    Closure closure;
    TscTimePoint timeAdded;
    bool isException;
    FiberHandle fibHandle;

    union {
        void[128] result;
        struct {
            string excType;
            string file;
            size_t line;
            FixedString!80 excMsg;
        }
    }

    void set(alias F)(Parameters!F args) {
        alias R = ReturnType!F;
        static if (is(R == void)) {
            closure.set!F(args);
        }
        else {
            static assert (R.sizeof <= result.sizeof);
            static void wrapper(R* res, Parameters!F args) {
                *res = F(args);
            }
            //closure.set!wrapper(cast(R*)result.ptr, args);
        }
    }

    void execute() {
        //
        // called on worker thread
        //
        if (!fibHandle.isValid()) {
            return;
        }

        isException = false;
        try {
            closure();
        }
        catch (Throwable ex) {
            isException = true;
            excType = typeid(ex).name;
            excMsg.safeSetPrefix(ex.msg);
            file = ex.file;
            line = ex.line;
        }
    }
}

struct ThreadPool(size_t numTasks) {
    enum MAX_FETCH_STREAK = 32;

    align(8) shared {
        bool active;
        bool threadExited;
        uint numActiveThreads;
    }
    Mutex pollerLock;
    Duration pollingInterval;
    DuplexQueue!(Task*, numTasks) queue;
    FixedPool!(Task, numTasks) tasksPool;
    WorkerThread[] threads;

    void open(uint numThreads, size_t stackSize, Duration pollingInterval = 10.msecs) {
        pollerLock = new Mutex();
        this.pollingInterval = pollingInterval;
        threads.length = numThreads;
        numActiveThreads = 0;
        active = true;
        threadExited = false;
        tasksPool.open();
        foreach(ref thd; threads) {
            thd = new WorkerThread(&threadFunc, stackSize);
            thd.start();
        }
        while (numActiveThreads < threads.length) {
            Thread.sleep(2.msecs);
        }
        //timerCookie = theReactor.callEvery(200.usecs, &completionCallback);
    }

    void close() {
        //theReactor.cancelCall(timerCookie);
        active = false;
        foreach(i; 0 .. numTasks) {
            queue.submitRequest(null);
        }
        foreach(thd; threads) {
            thd.join();
        }
        pollerLock = null;
        tasksPool.close();
    }

    private Task* pullWork() {
        // only one thread will enter this function. the rest will wait on the pollerLock.
        // when the function fetch some work, it will release the lock and another thread will enter
        pollerLock.lock();
        scope(exit) pollerLock.unlock();

        while (active) {
            Task* task;
            if (queue.pullRequest(task)) {
                return task;
            }
            else {
                Thread.sleep(pollingInterval);
            }
        }
        return null;
    }

    void threadFunc() {
        atomicOp!"+="(numActiveThreads, 1);
        scope(exit) {
            atomicOp!"-="(numActiveThreads, 1);
            atomicStore(threadExited, true);
        }

        while (active) {
            auto task = pullWork();
            if (task is null) {
                assert (!active);
                break;
            }

            task.execute();
            auto added = queue.submitResult(task);
            ASSERT!"submitResult failed"(added);
        }
    }

    void completionCallback() {
        assert (!threadExited);
        foreach(_; 0 .. MAX_FETCH_STREAK) {
            Task* task;
            if (!queue.pullResult(task)) {
                break;
            }
            assert (task);

            if (task.fibHandle.isValid) {
                theReactor.resumeFiber(task.fibHandle);
                task.fibHandle = null;
            }
            else {
                tasksPool.release(task);
            }
        }
    }

    auto deferToThread(alias F)(Parameters!F args) {
        auto task = tasksPool.alloc();
        task.fibHandle = theReactor.runningFiberHandle;
        task.timeAdded = TscTimePoint.softNow();
        task.set!F(args);
        auto added = queue.submitRequest(task);
        ASSERT!"submitRequest"(added);

        //
        // once submitted, the task no longer belongs (solely) to us. we go to sleep until
        // one of the following:
        //   * the fiber is unwinding due to an exception (fiber killed)
        //      - note that the thread may or may not be done
        //      - if it is done, we must release it.
        //   * the completion callback fetched the result
        //
        try {
            theReactor.suspendThisFiber();
        }
        catch (Throwable ex) {
            if (task.fibHandle.isValid) {
                // fiber was killed while thread still holds the task
                // do NOT release, but mark defunct
                task.fibHandle = null;
            }
            else {
                // thread is done with the task, release it
                tasksPool.release(task);
            }
            throw ex;
        }

        //
        // we reach this part iff the thread is done with the task
        //
        if (task.isException) {
            auto ex = mkExFmt!DeferredTaskFailed("%s: %s", task.excType, task.excMsg);
            ex.file = task.file;
            ex.line = task.line;
            tasksPool.release(task);
            throw ex;
        }

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

unittest {
    ThreadPool!64 thdPool;

    static int sleeper(Duration dur) {
        Thread.sleep(dur);
        return 17;
    }

    //testWithReactor({
    auto res = thdPool.deferToThread!sleeper(10.msecs);
    assert (res == 17);
    //});
}

















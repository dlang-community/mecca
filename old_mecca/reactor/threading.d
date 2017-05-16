module mecca.reactor.threading;

import core.thread;
import core.atomic;
import core.sync.mutex;
import std.exception;
import std.string;

import mecca.lib.reflection;
import mecca.lib.tracing;
import mecca.lib.os;
import mecca.lib.time;
import mecca.containers.tsqueue;

import mecca.reactor.reactor;
import mecca.reactor.misc;
import mecca.reactor.fibers;

pragma(mangle, "thread_isMainThread") extern(C) bool isMainThread() pure nothrow @safe @nogc;


class ReactorThread: Thread {
    Closure closure;
    Throwable unhandledEx;
    int kernelThreadId;

    this(void delegate() dlg) {
        kernelThreadId = -1;
        super(&thdFunc);
        closure.set(dlg);
    }
    @notrace void thdFunc() {
        kernelThreadId = gettid();
        scope(exit) kernelThreadId = -1;

        // block signals
        import core.sys.posix.signal;
        sigset_t sigset = void;
        sigemptyset(&sigset);
        foreach(sig; [SIGHUP, SIGINT, SIGTERM, SIGQUIT, SIGTSTP, HANG_DETECTOR_SIGNUM]) {
            sigaddset(&sigset, SIGHUP);
        }
        //setSchedulerMax(SchedulingPolicy.SCHED_OTHER);

        try {
            errnoEnforce(pthread_sigmask(SIG_BLOCK, &sigset, null) == 0, "pthread_sigmask failed");
            closure();
        }
        catch (Throwable ex) {
            unhandledEx = ex;
        }
    }
}

private struct DeferredTask {
    __gshared static DeferredTask poison;

    @disable this(this);

    Closure closure;
    Closure finiCb;
    FiberHandle ownerFib;
}


struct ThreadPool(size_t capacity_) {
    enum capacity = capacity_;
    shared long activeThreads;
    ReactorThread[] threads;
    DuplexQueue!(DeferredTask*, capacity) tsqueue;
    Mutex workerLock;

    void open(int numThreads) {
        assert (numThreads > 0);
        assert(closed);
        tsqueue.reset();
        threads.length = numThreads;
        workerLock = new Mutex();
        foreach(i, ref thd; threads) {
            thd = new ReactorThread(&threadMain);
        }
        foreach(thd; threads) {
            thd.start();
        }
        while (atomicLoad(activeThreads) < numThreads) {
            Thread.sleep(10.msecs);
        }
    }
    void close() {
        foreach(thd; threads) {
            while (!tsqueue.pushInput(&DeferredTask.poison)) {
                Thread.sleep(10.msecs);
            }
        }
        foreach(thd; threads) {
            thd.join();
        }
        threads.length = 0;
    }
    @property bool closed() const pure nothrow @nogc {
        return threads.length == 0;
    }

    void poller() {
        assert (atomicLoad!(MemoryOrder.raw)(activeThreads) == threads.length);
        DeferredTask* task;
        foreach(_; 0 .. 32) {
            if (!tsqueue.popOutput(task)) {
                break;
            }
            if (task.ownerFib.isValid) {

            }
            task.finiCb();
        }
    }

    DeferredTask* _popTask() {
        // only a single thread will actually poll the tsqueue -- the rest will sleep on the lock
        // this function blocks the caller until it has a task to return
        synchronized (workerLock) {
            while (true) {
                DeferredTask* task;
                if (tsqueue.popInput(task)) {
                    return task;
                }
                else {
                    Thread.sleep(10.msecs);
                }
            }
        }
    }

    void threadMain() {
        auto tid = atomicOp!"+="(activeThreads, 1);
        scope(exit) atomicOp!"-="(activeThreads, 1);
        scope(failure) ERROR!"#THDPOOL thread %s has died"(tid);

        while (true) {
            auto task = _popTask();
            if (task == &DeferredTask.poison) {
                INFO!"#THDPOOL thread %s was poisoned"(tid);
                break;
            }
        }
    }
}

__gshared ThreadPool!1024 threadPool;

void initThreading() {
    threadPool.open(theReactor.options.numThreadsInPool);
    theReactor.registerPoller(&threadPool.poller, 200.usecs, true /* idle */);
}
void finiThreading() {
    threadPool.close();
}






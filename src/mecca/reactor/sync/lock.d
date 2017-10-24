/***
 * Implements a reactor aware mutex
 * Authors: Shachar Shemesh
 * Copyright: ©2017 Weka.io Ltd.
 */
module mecca.reactor.sync.lock;

import mecca.lib.exception;
import mecca.lib.time;
import mecca.reactor.sync.fiber_queue;

/**
  A reactor aware non-recursive simple mutex.

  This struct can be used for synchronizing different fibers. It cannot be used for synchronizing threads not running under the same
  reactor.
 */
struct Lock {
private:
    FiberQueue waiters;
    uint numRequesting; // Including the fiber already holding the lock

public:
    /** Acquire the lock. Suspend the fiber if currently acquired.
     * 
     * Upon return, the mutex is acquired. It is up to the caller to call release.
     *
     * The call is guaranteed not to sleep if the mutex is available.
     *
     * Throws:
     * TimeoutExpired if the timeout expires
     *
     * Anything injected through a call to Reactor.throwInFiber
     */
    void acquire(Timeout timeout = Timeout.infinite) @safe @nogc {
        if( numRequesting==0 ) {
            // Fast path
            numRequesting = 1;
            return;
        }

        numRequesting++;
        scope(failure) numRequesting--;

        waiters.suspend(timeout);
    }

    /** Release a previously acquired lock.
     */
    void release() nothrow @safe @nogc {
        ASSERT!"Lock.release called on a non-acquired lock"(numRequesting>=1);
        numRequesting--;

        if( numRequesting>0 )
            waiters.resumeOne();
    }

    /// Returns whether the lock is currently held.
    @property bool isLocked() const nothrow @safe @nogc {
        return numRequesting>0;
    }
}

unittest {
    import mecca.reactor;
    import mecca.reactor.sync.barrier;

    Lock lock;
    Barrier barrier;
    bool held;

    void waiter() {
        foreach(i; 0..3) {
            lock.acquire();
            scope(exit) {
                lock.release();
                held = false;
            }

            ASSERT!"Lock held on entry"(!held);

            theReactor.sleep(1.msecs);
        }

        barrier.markDone();
    }

    TscTimePoint begin = TscTimePoint.hardNow;
    testWithReactor({
            foreach(i; 0..7) {
                barrier.addWaiter();
                theReactor.spawnFiber(&waiter);
            }
            barrier.waitAll();
            ASSERT!"Lock held after end"(!held);

            // Test whether the lock is free and can be acquired without sleep
            theReactor.enterCriticalSection();
            lock.acquire();
            lock.release();
            theReactor.leaveCriticalSection();
            });
    TscTimePoint end = TscTimePoint.hardNow;

    assert(end - begin >= 21.msecs, "mutex did not mutually exclude");
}

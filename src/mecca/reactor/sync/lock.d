/***
 * Implements a reactor aware mutex
 * Authors: Shachar Shemesh
 * Copyright: ©2017 Weka.io Ltd.
 */
module mecca.reactor.sync.lock;

import mecca.log;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.reactor;
import mecca.reactor.sync.barrier;
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
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);
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

            assert(!lock.isLocked);
            });
    TscTimePoint end = TscTimePoint.hardNow;

    assert(end - begin >= 21.msecs, "mutex did not mutually exclude");
}

/**
  Shared access lock

  A standard Read-Write lock. Supports multiple readers or a single writer.
 */
struct SharedLock {
private:
    Lock        acquireLock;
    Barrier     sharedLockers;

public:
    /**
     * Acquire an exclusive access lock
     */
    @notrace void acquireExclusive(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        acquireLock.acquire(timeout);
        scope(failure) acquireLock.release();
        sharedLockers.waitAll(timeout);
    }

    /**
     * Acquire a shared access lock
     */
    @notrace void acquireShared(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        acquireLock.acquire(timeout);
        scope(exit) acquireLock.release();

        sharedLockers.addWaiter();
    }

    /// Release a previously acquired exclusive access lock
    @notrace void releaseExclusive() nothrow @safe @nogc {
        DBG_ASSERT!"Have shared lockers during exclusive unlock"(!sharedLockers.hasWaiters);
        acquireLock.release();
    }

    /// Release a previously acquired shared access lock
    @notrace void releaseShared() nothrow @safe @nogc {
        DBG_ASSERT!"releaseShared call but no shared lockers"(sharedLockers.hasWaiters);
        sharedLockers.markDone();
    }
}

/**
  Unfair shared access lock

  This behaves like a standard read-write lock, except an exclusive lock is only obtained after all shared users have
  relinquished the lock.
 */
struct UnfairSharedLock {
private:
    Lock        lock;
    uint        numSharedLockers;

public:
    /**
     * Acquire an exclusive access lock
     */
    @notrace void acquireExclusive(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        lock.acquire(timeout);
        DBG_ASSERT!"Exclusivly locked but have shared lockers"(numSharedLockers==0);
    }

    /**
     * Acquire a shared access lock
     */
    @notrace void acquireShared(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        if( numSharedLockers==0 ) {
            lock.acquire(timeout);
        }

        DBG_ASSERT!"Shared lockers but lock is not acquired"(lock.isLocked);
        numSharedLockers++;
    }

    /// Release a previously acquired exclusive access lock
    @notrace void releaseExclusive() nothrow @safe @nogc {
        lock.release();
    }

    /// Release a previously acquired shared access lock
    @notrace void releaseShared() nothrow @safe @nogc {
        DBG_ASSERT!"releaseShared call but no shared lockers"(numSharedLockers>0);

        if( --numSharedLockers==0 ) {
            lock.release();
        }
    }
}

version(unittest):
private:

mixin template Test(SharedLockType) {
    uint generation;
    SharedLockType lock;
    Barrier allDone;

    void exclusiveTest(uint gen) {
        scope(exit) allDone.markDone();

        DEBUG!"Obtaining exclusive lock gen %s"(gen);
        lock.acquireExclusive();
        scope(exit) {
            DEBUG!"Releasing exclusive lock gen %s"(gen);
            lock.releaseExclusive();
        }
        DEBUG!"Obtained exclusive lock gen %s"(gen);

        assert(generation == gen);
        generation++;
        foreach(i; 0..10) {
            theReactor.yield();
        }
        assert(generation == gen+1);
    }

    void sharedTest(uint gen) {
        scope(exit) allDone.markDone();

        DEBUG!"Obtaining shared lock gen %s"(gen);
        lock.acquireShared();
        scope(exit) {
            DEBUG!"Releasing shared lock gen %s"(gen);
            lock.releaseShared();
        }
        DEBUG!"Obtained shared lock gen %s"(gen);

        assert(generation == gen);
        foreach(i; 0..10) {
            theReactor.yield();
        }
        assert(generation == gen);
    }

    void startExclusive(uint gen) {
        theReactor.spawnFiber( &exclusiveTest, gen );
        allDone.addWaiter();
        theReactor.yield();
    }
    void startShared(uint gen) {
        theReactor.spawnFiber( &sharedTest, gen );
        allDone.addWaiter();
        theReactor.yield();
    }
}

unittest {
    mixin Test!SharedLock;

    void testBody() {
        startShared(0);
        startShared(0);
        startExclusive(0);
        startShared(1);
        startShared(1);
        startShared(1);
        startShared(1);
        startExclusive(1);
        startShared(2);

        allDone.waitAll();
        lock.acquireExclusive(Timeout(Duration.zero));
    }

    testWithReactor(&testBody);
}

unittest {
    mixin Test!UnfairSharedLock;

    void testBody() {
        startShared(0);
        startShared(0);
        startExclusive(0);
        startShared(0);
        startShared(0);
        startShared(0);
        startShared(0);
        startExclusive(1);
        startShared(0);

        allDone.waitAll();
        lock.acquireExclusive(Timeout(Duration.zero));
    }

    testWithReactor(&testBody);
}

/***
 * Implements a reactor aware mutex
 * Authors: Shachar Shemesh
 * Copyright: ©2017 Weka.io Ltd.
 */
module mecca.reactor.sync.lock;

import mecca.lib.reflection;

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
    FiberHandle _owner;
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
        DBG_ASSERT!"DEADLOCK: trying to acquire a lock by the same fiber already holding it"(
                owner!=theReactor.currentFiberHandle);

        scope(success) {
            DBG_ASSERT!"Owner set when granting the lock"(!owner.isSet);
            _owner = theReactor.currentFiberHandle;
        }

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
     *
     * This funciton must be called from the same fiber that called the matching `acquire`.
     */
    void release() nothrow @safe @nogc {
        ASSERT!"Lock.release called on a non-acquired lock"(numRequesting>=1);
        ASSERT!"Lock acquired by %s but released by %s"(
                owner==theReactor.currentFiberHandle, owner, theReactor.currentFiberHandle);
        numRequesting--;
        _owner.reset();

        if( numRequesting>0 )
            waiters.resumeOne();
    }

    /// Returns whether the lock is currently held.
    @property bool isLocked() pure const nothrow @safe @nogc {
        return numRequesting>0;
    }

    /// Returns the `FiberHandle` of the current owner of the lock.
    ///
    /// Function returns `FiberHandle.init` if not currently locked. This is $(I not) the same as calling `isLocked`.
    /// There are some cases where `isLocked` will return `true` but `owner` will return the invalid handle.
    @property FiberHandle owner() pure const nothrow @safe @nogc {
        return _owner;
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
    /// The state of the lock, as returned by `lockState`.
    enum LockState {
        Unlocked,                       /// Lock is unlocked
        Shared,                         /// Lock is in shared mode
        SharedWithExclusivePending,     /// Lock is in shared mode, and there are fibers waiting to lock it exclusively
        Exclusive,                      /// Lock is in exclusive mode.
    }

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

    /// Return the current state of the lock.
    ///
    /// Returns:
    /// see `LockState`
    @property LockState lockState() pure const nothrow @safe @nogc {
        if( acquireLock.isLocked ) {
            if( sharedLockers.hasWaiters )
                return LockState.SharedWithExclusivePending;

            return LockState.Exclusive;
        }

        if( sharedLockers.hasWaiters )
            return LockState.Shared;

        return LockState.Unlocked;
    }
}

/**
  Unfair shared access lock

  This behaves like a standard read-write lock, except an exclusive lock is only obtained after all shared users have
  relinquished the lock.
 */
struct UnfairSharedLock {
    import mecca.reactor.sync.semaphore : Semaphore;

private:
    Semaphore   lock = Semaphore(1);
    uint        numSharedLockers;

public:
    /// Lock state enum
    alias LockState = SharedLock.LockState;

    /**
     * Acquire an exclusive access lock
     */
    @notrace void acquireExclusive(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        lock.acquire(1, timeout);
        DBG_ASSERT!"Exclusivly locked but have shared lockers"(numSharedLockers==0);
    }

    /**
     * Acquire a shared access lock
     */
    @notrace void acquireShared(Timeout timeout = Timeout.infinite) @safe @nogc {
        DBG_ASSERT!"Cannot acquire a lock while in a critical section"(!theReactor.isInCriticalSection);

        if( numSharedLockers==0 ) {
            lock.acquire(1, timeout);
        }

        DBG_ASSERT!"Shared lockers but lock is not acquired"(lock.level==0);
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


    /// Return the current state of the lock.
    ///
    /// This function will never return the `SharedWithExclusivePending` state.
    /// Returns:
    /// see `LockState`
    @property LockState lockState() pure const nothrow @safe @nogc {
        if( numSharedLockers>0 )
            return LockState.Shared;

        if( lock.level==0 )
            return LockState.Exclusive;

        return LockState.Unlocked;
    }
}

version(unittest) {

private mixin template Test(SharedLockType) {
    uint generation;
    SharedLockType lock;
    Barrier allDone;

    void exclusiveTest(uint gen) {
        scope(exit) allDone.markDone();

        DEBUG!"Obtaining exclusive lock gen %s"(gen);
        lock.acquireExclusive();
        assertEQ(lock.lockState, lock.LockState.Exclusive);
        scope(exit) {
            DEBUG!"Releasing exclusive lock gen %s"(gen);
            lock.releaseExclusive();
        }
        DEBUG!"Obtained exclusive lock gen %s"(gen);

        assertEQ(generation ,  gen);
        generation++;
        foreach(i; 0..10) {
            theReactor.yield();
        }
        assertEQ(generation ,  gen+1);
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

        assertEQ(generation ,  gen);
        foreach(i; 0..10) {
            theReactor.yield();
        }
        assertEQ(generation ,  gen);
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
        assertEQ(lock.lockState, lock.LockState.Unlocked);
        startShared(0);
        assertEQ(lock.lockState, lock.LockState.Shared);
        startShared(0);
        assertEQ(lock.lockState, lock.LockState.Shared);
        startExclusive(0);
        assertEQ(lock.lockState, lock.LockState.SharedWithExclusivePending);
        startShared(1);
        startShared(1);
        startShared(1);
        startShared(1);
        startExclusive(1);
        startShared(2);

        allDone.waitAll();
        assertEQ(lock.lockState, lock.LockState.Unlocked);
        lock.acquireExclusive(Timeout(Duration.zero));
        assertEQ(lock.lockState, lock.LockState.Exclusive);
    }

    testWithReactor(&testBody);
}

unittest {
    mixin Test!UnfairSharedLock;

    void testBody() {
        assertEQ(lock.lockState, lock.LockState.Unlocked);
        startShared(0);
        assertEQ(lock.lockState, lock.LockState.Shared);
        startShared(0);
        startExclusive(0);
        assertEQ(lock.lockState, lock.LockState.Shared);
        startShared(0);
        startShared(0);
        startShared(0);
        startShared(0);
        startExclusive(1);
        startShared(0);

        allDone.waitAll();
        assertEQ(lock.lockState, lock.LockState.Unlocked);
        lock.acquireExclusive(Timeout(Duration.zero));
        assertEQ(lock.lockState, lock.LockState.Exclusive);
    }

    testWithReactor(&testBody);
}
}

/// A RAII wrapper for a lock
///
/// Params:
/// LockType = the type of lock to define over
/// acquireName = the name of the function to call to acquire the lock
/// releaseName = the name of the function to call to release the lock
struct Locker(LockType, string acquireName="acquire", string releaseName="release") {
private:
    import std.format : format;

    LockType* lock;

public:
    @disable this(this);
    // Constructor code is inside the acquire mixin

    /// Auto unlocking destructor
    ~this() nothrow @nogc {
        if( lock !is null )
            release();
    }

    //pragma(msg, acquireCode);

    /// Acquire the lock
    mixin(acquireCode);

    //pragma(msg, releaseCode);

    // Release the lock
    mixin(releaseCode);

    /// Report whether the container is currently locked
    @notrace bool isLocked() const pure nothrow @safe @nogc {
        return lock !is null;
    }
private:
    alias AcquireGenerator = CopySignature!( __traits(getMember, LockType, acquireName) );
    enum string acquireCode = q{
        // XXX I'm not sure why I bother documenting functions inside mixins that the doc will never build
        /// Construct a locked instance
        this(ref LockType lock, %1$s) @nogc {
            acquire(lock, %2$s);
        }

        /// Acquire the lock
        ///
        /// Params:
        /// lock = an instance of `LockType` to lock
        ///
        /// The other arguments are the same as for `LockType.acquire`
        @notrace void acquire(ref LockType lock, %1$s) @nogc {
            ASSERT!"Tried to acquire an already locked Locker"(this.lock is null);
            this.lock = &lock;
            lock.%3$s(%2$s);
        }
    }.format( AcquireGenerator.genDefinitionList, AcquireGenerator.genCallList, acquireName );

    alias ReleaseGenerator = CopySignature!( __traits(getMember, LockType, releaseName) );
    enum string releaseCode = q{
        /// Release the lock
        @notrace void release(%1$s) @nogc {
            ASSERT!"Tried to release a non locked Locker"(this.lock !is null);
            scope(exit) this.lock = null;
            lock.%3$s(%2$s);
        }
    }.format( ReleaseGenerator.genDefinitionList, ReleaseGenerator.genCallList, releaseName );
}

unittest {
    enum NUM_FIBERS = 5;
    enum NUM_RUNS = 10;

    uint numRuns;
    bool locked;
    Lock lock;
    import mecca.reactor.sync.barrier: Barrier;
    Barrier allDone;

    void lockerFiber() {
        scope(exit) allDone.markDone();

        foreach(i; 0..NUM_RUNS) {
            auto locker = Locker!Lock(lock);
            assert(!locked, "Mutual exclusion failed");
            locked = true;
            numRuns++;
            scope(exit) locked = false;

            theReactor.yield();
        }
    }

    testWithReactor({
        foreach(i; 0..NUM_FIBERS) {
            allDone.addWaiter();
            theReactor.spawnFiber(&lockerFiber);
        }

        allDone.waitAll();
        assert(!lock.isLocked, "lock acquired at end of test");
        assert(numRuns==NUM_FIBERS*NUM_RUNS);
    });
}

/// Locker wrapper for a SharedLock with a shared lock
alias SharedLocker = Locker!(SharedLock, "acquireShared", "releaseShared");
/// Locker wrapper for a SharedLock with an exclusive lock
alias ExclusiveLocker = Locker!(SharedLock, "acquireShared", "releaseShared");

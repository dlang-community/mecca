/// Reactor aware semaphore
module mecca.reactor.sync.semaphore;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.algorithm;

import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.fiber_queue;

/// Reactor aware semaphore
struct Semaphore {
private:
    /+ Semaphore fairness is assured using a two stage process.
       During acquire, if there are other waiting acquirers, we place ourselves in the "waiters" queue.

       Once we're at the top of the queue, we register our fiber handle as primaryWaiter.
     +/
    size_t _capacity, pendingCapacity;
    long available;     // May be negative due to capacity change
    size_t requestsPending;
    FiberQueue waiters;
    FiberHandle primaryWaiter;
    bool resumePending;         // Makes sure only one fiber gets woken up at any one time

public:
    @disable this(this);

    /**
     * Construct a semaphore with given capacity.
     */
    this(size_t capacity, size_t used = 0) pure nothrow @safe @nogc {
        open(capacity, used);
    }

    /**
     * Call this function before using the semaphore.
     *
     * You can skip calling `open` if the semaphore is constructed explicitly
     *
     * Params:
     *  capacity = maximal value the semaphore can grow to.
     *  used = initial number of obtained locks. Default of zero means that the semaphore is currently unused.
     */
    void open(size_t capacity, size_t used = 0) pure nothrow @safe @nogc {
        ASSERT!"Semaphore.open called on already open semaphore"(_capacity==0);
        ASSERT!"Semaphore.open called with capacity 0"(capacity>0);
        ASSERT!"Semaphore.open called with initial used count %s greater than capacity %s"(used<=capacity, used, capacity);

        _capacity = capacity;
        available = _capacity - used;
        pendingCapacity = 0;
        requestsPending = 0;
        ASSERT!"open called with waiters in queue"( waiters.empty );
    }

    /**
     * Call this function when the semaphore is no longer needed.
     *
     * This function is mostly useful for unittests, where the same semaphore instance might be used multiple times.
     */
    void close() pure nothrow @safe @nogc {
        ASSERT!"Semaphore.close called on a non-open semaphore"(_capacity > 0);
        ASSERT!"Semaphore.close called while fibers are waiting on semaphore"(waiters.empty);
        _capacity = 0;
    }

    /// Report the capacity of the semaphore
    @property size_t capacity() const pure nothrow @safe @nogc {
        return _capacity;
    }

    /** Change the capacity of the semaphore
     *
     * If `immediate` is set to `false` and the current `level` is higher than the requested capacity, `setCapacity`
     * will sleep until the capacity can be cleared.
     *
     * If `immediate` is `false` then `setCapacity` may return before the new capacity is actually set. This will
     * $(I only) happen if there is an older `setCapacity` call that has not yet finished.
     *
     * Params:
     * newCapacity = The new capacity
     * immediate = whether the new capacity takes effect immediately.
     *
     * Warnings:
     * Setting the capacity to lower than the number of resources a waiting fiber is currently requesting is undefined.
     *
     * If `immediate` is set to `true`, it is possible for `level` to report a higher acquired count than `capacity`.
     *
     * If there is a chance that multiple calls to `setCapacity` are active at once, the `immeditate` flag must be set
     * the same way on all of them. In other words, it is illegal to call `setCapacity` with `immediate` set to `false`,
     * and then call `setCapacity` with `immediate` set to true before the first call returns.
     */
    void setCapacity(size_t newCapacity, bool immediate = false) @safe @nogc {
        DBG_ASSERT!"setCapacity called with immediate set and a previous call still pending"(
                !immediate || pendingCapacity == 0 );

        if( (newCapacity>=_capacity && pendingCapacity==0) || immediate ) {
            // Fast path
            available += newCapacity - _capacity;
            _capacity = newCapacity;

            // It is possible that a fiber that previously was blocked can now move forward
            resumeOne(false);

            return;
        }

        // We cannot complete the capacity change immediately
        if( pendingCapacity!=0 ) {
            // Just piggyback the pending capacity change
            pendingCapacity = newCapacity;
            return;
        }

        // We need to wait ourselves for the change to be possible
        pendingCapacity = newCapacity;
        scope(exit) pendingCapacity = 0;

        while( pendingCapacity!=this.capacity ) {
            assertEQ( newCapacity, pendingCapacity );

            // If we ask to reduce the capacity, and then reduce it again, we might need to run this loop more than once
            assertLT( pendingCapacity, this.capacity, "pendingCapacity not <= level" );
            size_t numAcquired = this.capacity - pendingCapacity;
            acquire(numAcquired);
            // It is never released as such. We instead manipulate the state accordingly

            // Calculate the capacity closest to the one we want we can saftly reach right now
            newCapacity = max(newCapacity, pendingCapacity);

            _capacity = newCapacity;
            if( newCapacity>this.capacity ) {
                // We need to increase the capcity.
                release(numAcquired);
                // This also releases any further clients waiting
            } else {
                // available was already substracted by the acquire. Nothing more to do here
            }

            newCapacity = pendingCapacity;
        }
    }

    /**
     * Report the current amount of available resources.
     *
     * This amount includes all currently pending acquire requests.
     */
    @property size_t level() const pure nothrow @safe @nogc {
        if( available < requestsPending )
            return 0;

        return available - requestsPending;
    }

    /**
     * acquire resources from the semaphore.
     *
     * Acquire one or more "resources" from the semaphore. Sleep if not enough are available. The semaphore guarantees a
     * strict FIFO. A new request, even if satifiable, will not be granted until all older requests are granted.
     *
     * Params:
     *  amount = the amount of resources to request.
     *  timeout = how long to wait for resources to become available.
     *
     * Throws:
     *  TimeoutExpired if timeout has elapsed without satisfying the request.
     *
     *  Also, any other exception may be thrown if injected using theReactor.throwInFiber.
     */
    void acquire(size_t amount = 1, Timeout timeout = Timeout.infinite) @safe @nogc {
        ASSERT!"Semaphore tried to acquire %s, but total capacity is only %s"( amount<=capacity, amount, capacity );
        requestsPending += amount;
        scope(exit) requestsPending -= amount;

        bool slept;
        if( requestsPending>amount ) {
            // There are others waiting before us
            suspendSecondary(timeout);
            slept = true;
        }

        while( available<amount ) {
            if( slept ) {
                DEBUG!"Spurious wakeup waiting to acquire %s from semaphore. Available %s, capacity %s"(
                        amount, available, capacity);
            }

            slept = true;
            suspendPrimary(timeout);
        }

        DBG_ASSERT!"Semaphore has %s requests pending including us, but we're requesting %s"(
                requestsPending >= amount, requestsPending, amount);

        available -= amount;
        // requestsPending -= amount; Will be done by scope(exit) above. We're not sleeping until the end of the function

        if( requestsPending>amount && available>0 ) {
            // If there are other pendings, we've slept. The same release that woke us up should have woken the next in
            // line too, except it didn't know it released enough to wake more than one.
            resumeOne(true);
        }
    }

    /**
     * Try to acquire resources from the semaphore.
     *
     * Try to acquire one or more "resources" from the semaphore. To maintain strict FIFO, the acquire will fail if
     * another request is currently pending, even if there are enough resources to satisfy both requests.
     *
     * returns:
     * Returns `true` if the request was granted.
     */
    bool tryAcquire(size_t amount = 1) nothrow @safe @nogc {
        if( requestsPending>0 )
            // There are other waiters. Won't satisfy immediately
            return false;

        if( available<amount ) {
            return false;
        }

        available-=amount;
        return true;
    }

    /**
     * Release resources acquired via acquire.
     */
    void release(size_t amount = 1) nothrow @safe @nogc {
        ASSERT!"Semaphore.release called to release 0 coins"(amount>0);

        available += amount;
        ASSERT!"Semaphore.release(%s) called results in %s available coins but only %s capacity"( available<=capacity, amount, available,
               capacity );

        if( requestsPending>0 )
            resumeOne(false);
    }

private:
    void resumeOne(bool immediate) nothrow @safe @nogc {
        if( !resumePending ) {
            if( primaryWaiter.isValid ) {
                theReactor.resumeFiber(primaryWaiter, immediate);
            } else {
                waiters.resumeOne(immediate);
            }

            resumePending = true;
        }
    }

    void suspendSecondary(Timeout timeout) @safe @nogc {
        waiters.suspend(timeout);
        ASSERT!"Semaphore woke up without anyone owning up to waking us up."(resumePending);

        resumePending = false;
    }

    void suspendPrimary(Timeout timeout) @safe @nogc {
        DBG_ASSERT!"Cannot have two primary waiters"(!primaryWaiter.isValid);
        primaryWaiter = theReactor.currentFiberHandle();
        scope(exit) primaryWaiter.reset();
        theReactor.suspendCurrentFiber(timeout);
        ASSERT!"Semaphore woke up without anyone owning up to waking us up."(resumePending);

        resumePending = false;
    }
}

unittest {
    import mecca.reactor;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    uint[4] counters;
    Semaphore sem;
    uint doneCount;

    sem.open(3);

    void func(uint cnt) {
        sem.acquire(3);
        theReactor.yield();
        sem.release(3);

        foreach(i; 0..1000) {
            sem.acquire(2);
            counters[cnt]++;
            sem.release(2);
        }

        theReactor.stop();
    }

    theReactor.spawnFiber(&func, 0);
    theReactor.spawnFiber(&func, 1);
    theReactor.spawnFiber(&func, 2);
    theReactor.spawnFiber(&func, 3);

    theReactor.start();

    INFO!"Counters at end: %s"(counters);
    foreach(i, cnt; counters) {
        ASSERT!"Counter %s not correct: %s"(cnt>=999, i, counters);
    }
}

unittest {
    import mecca.reactor.sync.barrier;

    uint counter;
    auto sem = Semaphore(4);
    Barrier barrier;

    void fib(uint expected) {
        assert(counter==0);
        sem.acquire(4);
        assertEQ(counter, expected, "Out of order acquire");
        counter++;
        sem.release(4);

        barrier.markDone();
    }

    testWithReactor({
            sem.acquire(4);

            foreach(uint i; 0..10) {
                theReactor.spawnFiber(&fib, i);
                barrier.addWaiter();
                theReactor.yield;
            }

            sem.release(1);
            theReactor.yield();
            sem.release(3);

            barrier.waitAll();

            assert(counter==10);
        });
}

unittest {
    auto sem = Semaphore(2);
    bool gotIt;

    void fiberFunc() {
        sem.acquire();
        scope(exit) sem.release();

        gotIt = true;

        theReactor.yield();
    }

    void mainFunc() {
        assert(sem.tryAcquire(2), "tryAcquire failed on empty semaphore");

        auto fib = theReactor.spawnFiber(&fiberFunc);
        theReactor.yield();
        assert(!gotIt, "semaphore acquired despite no available resources");

        sem.release(2);
        assert(!gotIt, "release shouldn't yield");

        assert(!sem.tryAcquire(), "tryAcquire succeeded despite pending fibers");
        theReactor.yield();
        assert(gotIt, "Fiber didn't acquire despite release");
        assert(fib.isValid, "Fiber quite too soon");
        assertEQ(sem.level, 1, "Semaphore level is incorrect");
        assert(sem.tryAcquire(), "tryAcquire failed despite available resources");

        theReactor.joinFiber(fib);
        assertEQ(sem.level, 1, "Semaphore level is incorrect");
    }

    testWithReactor(&mainFunc);
}

version(unittest):
import mecca.reactor.sync.barrier;
import mecca.reactor.sync.event;

class SetCapacityTests {
    Semaphore sem;
    uint counter;
    Barrier barrier;

    void open(uint capacity, uint used = 0) {
        assertEQ(barrier.numWaiters, 0, "Barrier not clear on open");
        sem.open(capacity, used);
        counter = 0;
    }

    void reset() {
        sem.close();
    }

    void fib(uint howMuch, Event* clearToExit) {
        scope(exit) barrier.markDone();

        sem.acquire(howMuch);
        scope(exit) sem.release(howMuch);

        counter++;
        clearToExit.wait();
    }

    FiberHandle spawn(uint howMuch, Event* clearToExit) {
        auto fh = theReactor.spawnFiber(&fib, howMuch, clearToExit);
        barrier.addWaiter();

        return fh;
    }

    @mecca_ut void releaseOnCapacityIncrease() {
        open(1);
        scope(success) reset();

        Event clearToExit;

        spawn(1, &clearToExit);
        spawn(1, &clearToExit);

        theReactor.yield();
        theReactor.yield();
        assertEQ(counter, 1, "Acquire succeeded, should have failed");

        sem.setCapacity(2);
        theReactor.yield();
        assertEQ(counter, 2, "Acquire failed, should have succeeded");

        clearToExit.set();
        barrier.waitAll();
        assertEQ(counter, 2);
    }

    @mecca_ut void reduceCapacity() {
        open(4);
        scope(success) reset();

        Event blocker;

        spawn(2, &blocker);
        spawn(2, &blocker);
        spawn(2, &blocker);

        theReactor.yield();
        theReactor.yield();
        assertEQ(counter, 2);

        blocker.set();
        sem.setCapacity(2);
        assertEQ(counter, 3);

        blocker.reset();

        spawn(2, &blocker);
        spawn(2, &blocker);
        theReactor.yield();
        assertEQ(counter, 4);

        blocker.set();
        barrier.waitAll();
        assertEQ(counter, 5);
    }
}

mixin TEST_FIXTURE_REACTOR!SetCapacityTests;

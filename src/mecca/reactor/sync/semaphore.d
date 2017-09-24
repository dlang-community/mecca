/// Reactor aware semaphore
module mecca.reactor.sync.semaphore;

import std.algorithm;

import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.fiber_queue;

/// Reactor aware semaphore
struct Semaphore {
private:
    size_t _capacity;
    size_t available;
    size_t requestsPending;
    FiberQueue waiters;
    bool resumePending; // Makes sure only one fiber gets woken up at any one time

public:
    @disable this(this);

    this(size_t capacity, size_t used = 0) {
        open(capacity, used);
    }

    /**
     * Call this function before using the semaphore.
     *
     * Params:
     *  capacity = maximal value the semaphore can grow to.
     *  used = initial number of obtained locks. Default of zero means that the semaphore is currently unused.
     */
    void open(size_t capacity, size_t used = 0) nothrow @safe @nogc {
        ASSERT!"Semaphore.open called on already open semaphore"(_capacity==0);
        ASSERT!"Semaphore.open called with capacity 0"(capacity>0);
        ASSERT!"Semaphore.open called with initial used count %s greater than capacity %s"(used<=capacity, used, capacity);

        _capacity = capacity;
        available = _capacity - used;
        requestsPending = 0;
        ASSERT!"open called with waiters in queue"( waiters.empty );
    }

    /**
     * Call this function when the semaphore is no longer needed.
     *
     * This function is mostly useful for unittests, where the same semaphore instance might be used multiple times.
     */
    void close() nothrow @safe @nogc {
        ASSERT!"Semaphore.close called on a non-open semaphore"(_capacity > 0);
        ASSERT!"Semaphore.close called while fibers are waiting on semaphore"(waiters.empty);
        _capacity = 0;
    }

    /// Report the capacity of the semaphore
    @property size_t capacity() const pure nothrow @safe @nogc {
        return _capacity;
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
     * acquire a resource from the semaphore.
     *
     * Acquire one or more "resources" from the semaphore. Sleep if not enough are available. The semaphore guarantees a strict FIFO.
     * A new request, even if satifiable, will not be granted until all older requests are granted.
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
            suspend(timeout);
            slept = true;
        }

        while( available<amount ) {
            if( slept ) {
                DEBUG!"Spurious wakeup waiting to acquire %s from semaphore. Available %s, capacity %s"(amount, available, capacity);
            }

            slept = true;
            suspend(timeout);
        }

        DBG_ASSERT!"Semaphore has %s requests pending including us, but we're requesting %s"(requestsPending >= amount, requestsPending,
                amount);

        available -= amount;
        // requestsPending -= amount; Will be done by scope(exit) above. We're not sleeping until the end of the function

        if( requestsPending>amount && available>0 ) {
            // If there are other pendings, we've slept. The same release that woke us up should have woken the next in line too, except it
            // didn't know it released enough to wake more than one.
            resumeOne(true);
        }
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
            waiters.resumeOne(immediate);
            resumePending = true;
        }
    }

    void suspend(Timeout timeout) @safe @nogc {
        waiters.suspend(timeout);
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
        theReactor.yieldThisFiber();
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

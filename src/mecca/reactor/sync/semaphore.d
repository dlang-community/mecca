module mecca.reactor.sync.semaphore;

import std.algorithm;

import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.fiber_queue;

struct Semaphore {
private:
    size_t _capacity;
    size_t available;
    FiberQueue waiters;
    uint fibersWaiting;

public:
    @disable this(this);

    void open(size_t capacity, size_t used = 0) nothrow @safe @nogc {
        ASSERT!"Semaphore.open called on already open semaphore"(_capacity==0);
        ASSERT!"Semaphore.open called with capacity 0"(capacity>0);
        ASSERT!"Semaphore.open called with initial used count %s greater than capacity %s"(used<=capacity, used, capacity);

        _capacity = capacity;
        available = _capacity - used;
    }

    void close() nothrow @safe @nogc {
        ASSERT!"Semaphore.close called on a non-open semaphore"(_capacity > 0);
        ASSERT!"Semaphore.close called while fibers are waiting on semaphore"(waiters.empty);
        _capacity = 0;
    }

    @property size_t capacity() const pure nothrow @safe @nogc {
        return _capacity;
    }

    void acquire(size_t amount = 1, Timeout timeout = Timeout.infinite) @safe @nogc {
        if( fibersWaiting>0 ) {
            // Even if the semaphore has coins, other fibers are ahead of us in queue to get them.
            fibersWaiting++;
            scope(exit) fibersWaiting--;

            waiters.suspend(timeout);
        }

        size_t totalObtained;
        scope(failure) {
            if(totalObtained>0)
                release(totalObtained);
        }

        while( amount > 0 ) {
            size_t obtained = min(amount, available);
            amount -= obtained;
            available -= obtained;
            totalObtained += obtained;

            if( amount>0 ) {
                fibersWaiting++;
                scope(exit) fibersWaiting--;

                waiters.suspend(timeout);
            } else if( available>0 ) {
                // While we slept, it is possible that more coins became available than what we need. If that's the case, wake up the
                // next waiter in the list. We perform an immediate resume, as the fiber should have been resumed with us.
                waiters.resumeOne(true);
            } 
        }
    }

    void release(size_t amount = 1) nothrow @safe @nogc {
        ASSERT!"Semaphore.release called to release 0 coins"(amount>0);

        available += amount;
        ASSERT!"Semaphore.release(%s) called results in %s available coins but only %s capacity"( available<=capacity, amount, available,
               capacity );

        waiters.resumeOne();
    }
}

/+
unittest {
    import mecca.reactor.reactor;

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

    foreach(i, cnt; counters) {
        ASSERT!"Counter %s not correct: %s"(cnt>998, i, counters);
    }
}
+/

module mecca.reactor.sync.fiber_queue;

import mecca.containers.lists;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.reactor;

struct FiberQueue {
private:
    LinkedSet!(ReactorFiber*) list;

public:
    void suspend(Timeout timeout = Timeout.infinite) {
        auto ourHandle = theReactor.runningFiberHandle;
        bool inserted = list.append(ourHandle.get);
        DBG_ASSERT!"Fiber %s added to same queue twice"(inserted, ourHandle);

        theReactor.suspendThisFiber(timeout);
        // Since we're the fiber management, the fiber should not be able to exit without going through this point
        DBG_ASSERT!"Fiber handle for %s became invalid while it slept"(ourHandle.isValid, ourHandle);
        ASSERT!"Fiber %s woken up but not removed from FiberQueue"(ourHandle.get !in list, ourHandle);
    }

    FiberHandle resumeOne() {
        ReactorFiber* wakeupFiber = list.popHead;

        if (wakeupFiber is null)
            return FiberHandle.init;

        auto handle = FiberHandle( wakeupFiber );
        theReactor.resumeFiber( handle );

        return handle;
    }
}

unittest {
    import mecca.reactor.fd;
    import std.random;

    Mt19937 random;
    random.seed(unpredictableSeed);

    theReactor.setup();
    scope(exit) theReactor.teardown();

    FD.openReactor();

    FiberQueue fq;
    DEBUG!"Fiber queue at %s"( &fq );

    uint wokeup, timedout;

    void waiter() {
        try {
            Duration waitDuration = dur!"msecs"( uniform!"(]"(20, 200, random) );
            DEBUG!"Fiber %s waiting for %s"(theReactor.runningFiberHandle, waitDuration);
            fq.suspend( Timeout(waitDuration) );
            wokeup++;
        } catch( ReactorTimeout ex ) {
            timedout++;
            DEBUG!"%s timed out"(theReactor.runningFiberHandle);
        }
    }

    enum NumWaiters = 30;

    void framework() {
        theReactor.delay(dur!"msecs"(70));

        FiberHandle handle;
        while( (handle = fq.resumeOne).isValid ) {
            DEBUG!"Woke up %s"(handle);
        }
        theReactor.yieldThisFiber;

        INFO!"Ran test with %s fibers timing out and %s waking up"(timedout, wokeup);
        assert( timedout + wokeup == NumWaiters, "Incorrect number of fibers finished");

        theReactor.stop();
    }

    foreach(i; 0..NumWaiters)
        theReactor.spawnFiber(&waiter);

    theReactor.spawnFiber(&framework);

    theReactor.start();
}

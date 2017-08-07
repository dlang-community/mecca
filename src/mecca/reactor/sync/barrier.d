module mecca.reactor.sync.barrier;

import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.event;

struct Barrier {
    private Event evt = Event(true);
    private uint numWaiters = 0;

    void addWaiter() nothrow @safe @nogc {
        evt.reset();
        numWaiters++;
        DEBUG!"Barrier addWaiter called. Now at %s"(numWaiters);
    }
    void markDone() nothrow @safe @nogc {
        DEBUG!"Barrier markDone called. Reducing from %s"(numWaiters);
        assert (numWaiters > 0, "numWaiters=0");
        numWaiters--;
        if (numWaiters == 0) {
            evt.set();
        }
    }

    auto hasWaiters() nothrow @safe @nogc {
        return numWaiters > 0;
    }

    void waitAll(Timeout timeout = Timeout.infinite) @safe @nogc {
        evt.wait(timeout);
    }
    void markDoneAndWaitAll(Timeout timeout = Timeout.infinite) @safe @nogc {
        markDone();
        waitAll(timeout);
    }
}

/+
unittest {
    import mecca.reactor.reactor;

    testWithReactor({
        Barrier barrier;
        int count = 0;
        enum numFibs = 80;

        foreach(_; 0 .. numFibs) {
            barrier.addWaiter();
            theReactor.spawnFiber({
                count++;
                barrier.markDoneAndWaitAll();
            });
        }

        barrier.waitAll();
        assert (count == numFibs);
    });
}
+/

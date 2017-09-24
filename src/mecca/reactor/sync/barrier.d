/// Cross fibers synchronization point
module mecca.reactor.sync.barrier;

import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.event;

/**
 * A cross fibers synchronization point.
 *
 * Barrier has several deployment methods. The basic idea is to divide the fibers into those who need to "check in", and those that wait for
 * the check in counter to reach the correct amount.
 *
 * The most common use case is waiting for launched fibers to finish. To facilitate this mode, the following code structure is used:
 * ---
 * void fiberDlg() {
 *   scope(exit) barrier.markDone();
 *   ...
 * }
 * ...
 * theReactor.spawnFiber!fiberDlg();
 * barrier.addWaiter();
 * ...
 * barrier.waitAll();
 * ---
 */
struct Barrier {
private:
    Event evt = Event(true);
    uint numWaiters = 0;

public:
    /**
     * Increase number of expected completions by one.
     */
    void addWaiter() nothrow @safe @nogc {
        evt.reset();
        numWaiters++;
        DEBUG!"Barrier addWaiter called. Now at %s"(numWaiters);
    }

    /**
     * Increase number of completions by one.
     *
     * Call this when the completion event the barrier synchronizes on happens. This function does not sleep.
     */
    void markDone() nothrow @safe @nogc {
        DEBUG!"Barrier markDone called. Reducing from %s"(numWaiters);
        assert (numWaiters > 0, "numWaiters=0");
        numWaiters--;
        if (numWaiters == 0) {
            evt.set();
        }
    }

    /**
     * Report whether anyone is waiting for the barrier to complete.
     */
    auto hasWaiters() nothrow @safe @nogc {
        return numWaiters > 0;
    }

    /**
     * Wait for all completion events to happen.
     *
     * Halts the fiber until all expected completion events actually happen.
     *
     * Throws:
     * Will throw TimeoutExpired if the timeout is exceeded.
     *
     * May also throw any other exception injected into the fiber.
     */
    void waitAll(Timeout timeout = Timeout.infinite) @safe @nogc {
        evt.wait(timeout);
    }

    /**
     * Mark one completion and wait for all other completions to happen.
     *
     * This function is, literally, equivalent to calling markDone followed by waitAll.
     */
    void markDoneAndWaitAll(Timeout timeout = Timeout.infinite) @safe @nogc {
        markDone();
        waitAll(timeout);
    }
}

unittest {
    import mecca.reactor;
    import mecca.lib.exception;

    testWithReactor({
        Barrier barrier;
        int count = 0;
        enum numFibs = 80;

        foreach(_; 0 .. numFibs) {
            barrier.addWaiter();
            theReactor.spawnFiber({
                count++;
                barrier.markDoneAndWaitAll();
                theReactor.yieldThisFiber();
                count--;
            });
        }

        barrier.waitAll();
        assertEQ (count, numFibs);
        theReactor.yieldThisFiber();
        theReactor.yieldThisFiber();
        assertEQ (count, 0);
    });
}

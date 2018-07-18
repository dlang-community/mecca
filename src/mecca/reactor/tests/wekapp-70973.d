module mecca.reactor.tests.wekapp_70973;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(unittest):

import mecca.lib.exception;
import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.event;

unittest {
    // Make sure fibers don't start after the reactor is already closing.

    FiberId fiberRan;
    Event holder1, holder2, holder3;
    uint counter;

    void externalFiberBody(Event* holder) {
        scope(exit)
                counter++;

        holder.wait();
        fiberRan = theReactor.currentFiberId;
    }

    theReactor.setup();
    scope(exit) theReactor.teardown();

    void testBody() {
        auto fh = theReactor.spawnFiber(&externalFiberBody, &holder1);
        INFO!"Spawn sleeping fiber %s"(fh.fiberId);

        fh = theReactor.spawnFiber(&externalFiberBody, &holder2);
        INFO!"Spawn scheduled fiber %s"(fh.fiberId);

        theReactor.yield();

        holder3.set();
        fh = theReactor.spawnFiber(&externalFiberBody, &holder3);
        INFO!"Spawn starting fiber %s"(fh.fiberId);

        holder2.set();

        INFO!"Stopping reactor"();
        theReactor.stop();
    }

    theReactor.spawnFiber(&testBody);

    theReactor.start();

    // Only 2 fibers reach the scope(exit) and increment the counter
    assertEQ(counter, 2, "Not all fibers quit");
    ASSERT!"Fiber %s ran despite being after theReactor.stop"(!fiberRan.isValid, fiberRan);
}

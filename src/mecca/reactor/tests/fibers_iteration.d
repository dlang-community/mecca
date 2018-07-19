module mecca.reactor.tests.fibers_iteration;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(unittest):

import mecca.lib.exception;
import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.event;

unittest {
    static void body1() {
        theReactor.yield();
    }

    Event ev;

    void body2() {
        ev.wait();
    }

    testWithReactor({
            FiberHandle fh1 = theReactor.spawnFiber(&body1);
            FiberHandle fh2 = theReactor.spawnFiber(&body2);
            theReactor.yield();
            FiberHandle fh3 = theReactor.spawnFiber(&body1);

            uint numLocatedFibers;
            foreach(fh; theReactor.iterateFibers) {
                ASSERT!"Fiber %s returned by iterator despite not being valid"(fh.isValid, fh.getFiberId());
                numLocatedFibers++;
                auto state = theReactor.getFiberState(fh);
                if( fh == fh1 ) {
                    ASSERT!"First fiber %s should be in state Scheduled, is %s"(
                        state == FiberState.Scheduled, fh.fiberId, state);
                } else if( fh == fh2 ) {
                    ASSERT!"Second fiber %s should be in state Sleeping, is %s"(
                        state == FiberState.Sleeping, fh.fiberId, state);
                } else if( fh == fh3 ) {
                    ASSERT!"Third fiber %s should be in state Starting, is %s"(
                        state == FiberState.Starting, fh.fiberId, state);
                } else if( fh == theReactor.currentFiberHandle ) {
                    ASSERT!"Test fiber %s should be in state Starting, is %s"(
                        state == FiberState.Running, fh.fiberId, state);
                } else {
                    WARN!"Found unrelated fiber %s in state %s"(fh.fiberId, state);
                    numLocatedFibers--;
                }
            }

            assertEQ(4, numLocatedFibers, "Not all fibers were returned by iterator.");
        });
}

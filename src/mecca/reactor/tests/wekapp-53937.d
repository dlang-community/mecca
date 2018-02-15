module mecca.reactor.tests.wekapp_53937;

version(unittest):

import std.string;

import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.barrier;
import mecca.runtime.ut;

unittest {
    enum numRuns = 128;

    Barrier exitBarrier;

    void collector() {
        scope(success) exitBarrier.markDone();


        int[] array;
        array.length=100;
        array[] = 100;

        DEBUG!"%s array %s"(theReactor.runningFiberId, &array);

        theReactor.requestGCCollection();

        // Make sure that post GC everything is still here
        uint verified;
        foreach( i, a; array ) {
            assert(a==100, "Comparison failed %s [%s]%s!=%s".format(theReactor.runningFiberId, i, a, 100));
            verified++;
        }

        assert(verified == 100);
    }

    void testBody() {
        enum ARR_SIZE = 573;
        enum MAGIC_BYTE = 17;
        byte[] array;
        array.length = ARR_SIZE;
        array[] = MAGIC_BYTE;

        void verify() {
            // Verify that the original array is all there
            uint size;
            foreach( elem; array ) {
                assert(elem==MAGIC_BYTE);
                size++;
            }

            assert(size==ARR_SIZE);
        }

        verify();

        foreach(i; 0..numRuns) {
            theReactor.spawnFiber( &collector );
            exitBarrier.addWaiter();
        }

        verify();

        exitBarrier.waitAll();

        verify();
    }

    testWithReactor(&testBody);
}

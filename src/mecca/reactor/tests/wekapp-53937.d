module mecca.reactor.tests.wekapp_53937;

version(unittest):

import mecca.reactor;
import mecca.runtime.ut;
import mecca.reactor.sync.barrier;

unittest {
    enum numRuns = 100;

    Barrier exitBarrier;

    void collector() {
        scope(success) exitBarrier.markDone();


        int[] array;
        array.length=100;
        array[] = 100;

        theReactor.requestGCCollection();

        // Make sure that post GC everything is still here
        uint verified;
        foreach( a; array ) {
            assert(a==100);
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

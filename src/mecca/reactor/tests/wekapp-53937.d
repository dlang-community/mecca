module mecca.reactor.tests.wekapp_53937;

version(unittest):

import std.string;

import mecca.log;
import mecca.reactor;
import mecca.reactor.sync.barrier;
import mecca.runtime.ut;
import mecca.reactor.impl.fls;

unittest {
    META!"UT for testing GC's scanning of local fiber variables"();
    enum numRuns = 128;

    Barrier exitBarrier;

    void collector() {
        scope(success) exitBarrier.markDone();


        int[] array;
        array.length=100;
        array[] = 100;

        DEBUG!"%s array %s"(theReactor.currentFiberId, &array);

        theReactor.requestGCCollection();

        // Make sure that post GC everything is still here
        uint verified;
        foreach( i, a; array ) {
            assert(a==100, "Comparison failed %s [%s]%s!=%s".format(theReactor.currentFiberId, i, a, 100));
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

unittest {
    META!"UT for testing GC's scanning of fiber local variables"();
    enum numRuns = 128;
    enum ARR_LENGTH = 493;

    Barrier entryBarrier, exitBarrier;

    alias utGcArray = FiberLocal!(ubyte[], "utGcArray");

    static void allocate() {
        pragma(inline, false);
        utGcArray.length = ARR_LENGTH;
        utGcArray[] = cast(ubyte)theReactor.currentFiberId.value;
    }

    static void verify() {
        ubyte expected = cast(ubyte)theReactor.currentFiberId.value;
        uint verified;

        foreach( i, a; utGcArray ) {
            assert(a==expected, "Comparison failed %s %s[%s] %s!=%s".format(theReactor.currentFiberId, &(utGcArray()), i,
                    a, expected));
            verified++;
        }

        assert(verified==ARR_LENGTH);
    }

    void allocator() {
        scope(exit) exitBarrier.markDone();

        allocate();

        DEBUG!"Pre GC verify"();
        verify();

        entryBarrier.markDoneAndWaitAll();

        theReactor.requestGCCollection();
        DEBUG!"Post GC verify"();
        verify();
    }

    void testBody() {
        foreach(i; 0..numRuns) {
            theReactor.spawnFiber( &allocator );
            entryBarrier.addWaiter();
            exitBarrier.addWaiter();
        }

        exitBarrier.waitAll();
    }

    testWithReactor(&testBody);
}

module mecca.reactor.sync.future;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.reactor;
import mecca.log;


struct Future(T) {
    FiberHandle fibHandle;
    static if (!is(T == void)) {
        T* value;
    }

    T wait() @nogc {
        assert (!fibHandle.isValid);
        static if (!is(T == void)) {
            T onStackValue;
            value = &onStackValue;
        }
        scope(exit) fibHandle = null;
        fibHandle = theReactor.currentFiberHandle;
        theReactor.suspendCurrentFiber();
        static if (!is(T == void)) {
            return *value;
        }
    }

    static if (is(T == void)) {
        void set() @nogc {
            if (fibHandle.isValid) {
                theReactor.resumeFiber(fibHandle);
                fibHandle = null;
            }
            else {
                WARN!"Attempted to set an unwaited future"();
            }
        }
    }
    else {
        void set(T value) @nogc {
            if (fibHandle.isValid) {
                *this.value = value;
                theReactor.resumeFiber(fibHandle);
                fibHandle = null;
            }
            else {
                WARN!"Attempted to set an unwaited future"();
            }
        }
    }

    void raise(Throwable ex) @nogc {
        if (fibHandle.isValid) {
            theReactor.throwInFiber(fibHandle, ex);
            fibHandle = null;
        }
        else {
            WARN!"Attempted to throw in an unwaited future";
        }
    }
}

unittest {
    import mecca.lib.time;

    testWithReactor({
        Future!int fut;

        theReactor.spawnFiber({
            theReactor.sleep(10.msecs);
            fut.set(188);
        });

        auto val = fut.wait();
        assert (val == 188);

        class MyException: Exception {
            this(){
                super("fooo");
            }
        }

        theReactor.spawnFiber({
            theReactor.sleep(10.msecs);
            fut.raise(new MyException());
        });

        bool caught = false;
        try {
            val = fut.wait();
        }
        catch (MyException) {
            caught = true;
        }
        assert (caught);
    });
}









module mecca.reactor.reactor;

import mecca.reactor.fibril: Fibril;
import mecca.lib.time: TscTimePoint;
import mecca.lib.reflection: Closure;


struct ReactorFiber {
    struct OnStackParams {
        Closure closure;
    }
    enum Flags: ubyte {
        IN_SCHEDULED = 0x01,
        IN_FREE      = 0x02,
    }

    Fibril    fibril;
    uint      incarnationCounter;
    ushort    nextIdx = ushort.max;
    Flags     _flags;

    @property ReactorFiber* _next() {
        return nextIdx == ushort.max ? null : theReactor.fibers[nextIdx];
    }
    @property void _next(ReactorFiber* fib) {
        nextIdx = fib is null ? ushort.max : cast(ushort)(fib - theReactor.fibers.ptr);
    }

    void wrapper() nothrow {
        while (true) {
            //LOG("wrapper this=%s", theReactor.getFiberIndex(&this));
            assert (theReactor.thisFiber is &this, "this is wrong");
            assert (flag!"IS_SET");

            try {
                onStackParams.closure();
                theReactor.wrapperFinished(null);
            }
            catch (Throwable ex) {
                theReactor.wrapperFinished(ex);
            }
        }
    }
}

struct Reactor {

}


__gshared Reactor theReactor;

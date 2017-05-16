module mecca.reactor.fiber_local;

@("notrace") void traceDisableCompileTimeInstrumentation();

import std.string;
import core.thread;

package struct FiberLocalStorageBlock {
    ubyte[64*8] contents;
}

static assert(FiberLocalStorageBlock.contents.offsetof == 0);
static assert(FiberLocalStorageBlock.sizeof == FiberLocalStorageBlock.contents.sizeof);

package __gshared FiberLocalStorageBlock* indirFls = null;
package __gshared uint _flsOffset = 0;
package __gshared FiberLocalStorageBlock flsInitBlock;

template FiberLocal(T, string NAME, T init=T.init) {
    __gshared static int offset = -1;

    shared static this() {
        // Workaround for DMD issue 14901: Exit immediately if the ctor is called more than once.
        if (offset == -1) {
            offset = _flsOffset;
            _flsOffset += T.sizeof;
            assert (offset < FiberLocalStorageBlock.sizeof && _flsOffset <= FiberLocalStorageBlock.sizeof,
                    "FLS is overpopulated, %s required but only %s available: %s".format(
                        _flsOffset, FiberLocalStorageBlock.sizeof, NAME));
            *(cast(T*)&(flsInitBlock.contents[offset])) = init;
        }
    }

    @property ref T FiberLocal() {
        assert (thread_isMainThread(), "FiberLocal must be called from main thread");
        assert (indirFls !is null, "FiberLocal must be called from a fiber");
        return *(cast(T*)&(indirFls.contents[offset]));
    }
}


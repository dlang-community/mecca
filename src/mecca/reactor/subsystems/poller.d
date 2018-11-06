module mecca.reactor.subsystems.poller;

enum Direction { Read = 0, Write, Both }

public import mecca.reactor.platform.poller;

struct FdContext {
    import mecca.reactor : FiberHandle;

    enum Type { None, FiberHandle, Callback, CallbackOneShot }

    static struct State {
        Type type = Type.None;
        union {
            FiberHandle fibHandle;
            void delegate(void* opaq) callback;
        }
        void* opaq;
    }

    int fdNum;

    State[Direction.max] states; // Only for read and for write
}

private __gshared Poller __poller;
public @property ref Poller poller() nothrow @trusted @nogc {
    return __poller;
}

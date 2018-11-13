module mecca.reactor.subsystems.poller;

enum Direction { Read = 0, Write, Both }

public import mecca.reactor.platform.poller;
import mecca.reactor.io.signals : reactorSignal;

struct FdContext {
    import mecca.reactor : FiberHandle;

    enum Type {
        None,
        FiberHandle,
        Callback,
        CallbackOneShot,
        SignalHandler // kqueue only
    }

    static struct State {
        Type type = Type.None;
        union {
            FiberHandle fibHandle;
            void delegate(void* opaq) callback;
            reactorSignal.SignalHandler signalHandler; // kqueue only
        }
        void* opaq;
    }

    int fdNum; // file descriptor or signal

    State[Direction.max] states; // Only for read and for write
}

private __gshared Poller __poller;
public @property ref Poller poller() nothrow @trusted @nogc {
    return __poller;
}

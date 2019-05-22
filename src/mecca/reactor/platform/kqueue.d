module mecca.reactor.platform.kqueue;

version (Kqueue):
package:

alias Poller = Kqueue;

struct Kqueue
{
    public import mecca.reactor.subsystems.poller : FdContext;

    import core.time : Duration, msecs;

    import mecca.containers.pools : FixedPool;
    import mecca.lib.exception : ASSERT, DBG_ASSERT, enforceNGC, errnoEnforceNGC;
    import mecca.lib.io : FD;
    import mecca.lib.reflection : setToInit;
    import mecca.lib.time : Timeout;
    import mecca.log : INFO, notrace;
    import mecca.platform.os : OSSignal;
    import mecca.reactor : theReactor;
    import mecca.reactor.platform : EVFILT_READ, EVFILT_WRITE, EVFILT_SIGNAL, kevent64, kevent64_s;
    import mecca.reactor.subsystems.poller : Direction;

    package(mecca.reactor) alias SignalHandler = void delegate(OSSignal) @system;

    private
    {
        enum MIN_DURATION = 1.msecs;
        enum NUM_BATCH_EVENTS = 32;
        enum MAX_CONCURRENT_FDS = 512;

        FD kqueueFd;
        FixedPool!(FdContext, MAX_CONCURRENT_FDS) fdPool;

        int numberOfChanges;
        kevent64_s[NUM_BATCH_EVENTS] changes;
        kevent64_s[NUM_BATCH_EVENTS] events;
    }

    invariant
    {
        assert(changes.length > numberOfChanges);
    }

    void open() @safe
    {
        enum assertMessage = "Must call theReactor.setup before calling " ~
            "ReactorFD.openReactor";

        ASSERT!assertMessage(theReactor.isOpen);

        const fd = kqueue();
        errnoEnforceNGC(fd >= 0, "Failed to create kqueue file descriptor");
        kqueueFd = FD(fd);

        fdPool.open();
    }

    void close()
    {
        kqueueFd.close();
    }

    @property bool isOpen() const pure nothrow @safe @nogc
    {
        return kqueueFd.isValid;
    }

    FdContext* registerFD(ref FD fd, bool alreadyNonBlocking = false) @safe @nogc
    {
        import core.sys.posix.fcntl : F_SETFL, FD_CLOEXEC, O_NONBLOCK;

        enum reactorMessage = "registerFD called outside of an open reactor";
        enum fdMessage = "registerFD called without first calling " ~
            "ReactorFD.openReactor";

        ASSERT!reactorMessage(theReactor.isOpen);
        ASSERT!fdMessage(kqueueFd.isValid);

        FdContext* ctx = fdPool.alloc();
        setToInit(ctx);
        ctx.fdNum = fd.fileNo;
        scope(failure) fdPool.release(ctx);

        if (!alreadyNonBlocking)
        {
            const res = fcntl(fd.fileNo, F_SETFL, O_NONBLOCK | FD_CLOEXEC);
            errnoEnforceNGC(res >=0 , "Failed to set fd to non-blocking mode");
        }

        internalRegisterFD(fd.fileNo, ctx, Direction.Both);

        return ctx;
    }

    void deregisterFd(ref FD fd, FdContext* ctx, bool fdIsClosing = false) nothrow @safe @nogc
    {
        internalDeregisterFD(fd.fileNo, ctx, fdIsClosing);

        fdPool.release(ctx);
    }

    void waitForEvent(FdContext* ctx, int fd, Direction dir, Timeout timeout = Timeout.infinite) @safe @nogc
    {
        // XXX Relax this restriction if there is a need
        DBG_ASSERT!"Cannot wait for both in and out events"(dir != Direction.Both);
        auto ctxState = &ctx.states[dir];
        with(FdContext.Type) final switch(ctxState.type) {
        case None:
            break;
        case FiberHandle:
            ASSERT!"Two fibers cannot wait on the same ReactorFD %s at once: %s asked to wait with %s already waiting"(
                    false, fd, theReactor.currentFiberHandle.fiberId, ctxState.fibHandle.fiberId );
            break;
        case Callback:
        case CallbackOneShot:
            ASSERT!"Cannot wait on FD %s already waiting on a callback"(false, fd, dir);
            break;
        case SignalHandler:
            ASSERT!"Cannot wait on signal %s already waiting on a signal handler"(false, fd);
            break;
        }
        ctxState.type = FdContext.Type.FiberHandle;
        scope(exit) ctxState.type = FdContext.Type.None;
        ctxState.fibHandle = theReactor.currentFiberHandle;

        theReactor.suspendCurrentFiber(timeout);
    }

    @notrace void registerFdCallback(
            FdContext* ctx, Direction dir, void delegate(void*) callback, void* opaq, bool oneShot)
            nothrow @trusted @nogc
    {
        DBG_ASSERT!"Direction may not be Both"(dir!=Direction.Both);
        auto state = &ctx.states[dir];
        INFO!"Registered callback %s on fd %s one shot %s"(&callback, ctx.fdNum, oneShot);
        ASSERT!"Trying to register callback on busy FD %s: state %s"(
                state.type==FdContext.Type.None, ctx.fdNum, state.type );
        ASSERT!"Cannot register a null callback on FD %s"( callback !is null, ctx.fdNum );

        state.type = oneShot ? FdContext.Type.CallbackOneShot : FdContext.Type.Callback;
        state.callback = callback;
        state.opaq = opaq;
    }

    @notrace void unregisterFdCallback(FdContext* ctx, Direction dir) nothrow @trusted @nogc {
        DBG_ASSERT!"Direction may not be Both"(dir!=Direction.Both);
        auto state = &ctx.states[dir];
        INFO!"Unregistered callback on fd %s"(ctx.fdNum);
        ASSERT!"Trying to deregister callback on non-registered FD %s: state %s"(
                state.type==FdContext.Type.Callback || state.type==FdContext.Type.CallbackOneShot, ctx.fdNum, state.type);

        state.type = FdContext.Type.None;
    }

    package(mecca.reactor) @notrace FdContext* registerSignalHandler(OSSignal signal, SignalHandler handler)
        @trusted @nogc
    {
        enum reactorMessage = "registerFD called outside of an open reactor";
        enum fdMessage = "registerFD called without first calling " ~
            "ReactorFD.openReactor";

        ASSERT!reactorMessage(theReactor.isOpen);
        ASSERT!fdMessage(kqueueFd.isValid);

        auto ctx = fdPool.alloc();
        setToInit(ctx);

        auto state = &ctx.states[Direction.Read];
        state.type = FdContext.Type.SignalHandler;
        state.signalHandler = handler;
        ctx.fdNum = signal;
        scope(failure) fdPool.release(ctx);

        internalRegisterSignalHandler(ctx);
        return ctx;
    }

    package(mecca.reactor) @notrace void unregisterSignalHandler(FdContext* ctx) nothrow @safe @nogc
    {
        internalDeregisterSignalHandler(ctx);
        fdPool.release(ctx);
    }

    /// Export of the poller function
    ///
    /// A variation of this function is what's called by the reactor idle callback (unless `OpenOptions.registerDefaultIdler`
    /// is set to `false`).
    @notrace void poll()
    {
        reactorIdle(Duration.zero);
    }

    @notrace bool reactorIdle(Duration timeout)
    {
        import core.stdc.errno : EINTR, EPIPE, EBADF, errno;

        import mecca.lib.time : toTimespec;
        import mecca.log : DEBUG, WARN;
        import mecca.reactor.platform : EV_DELETE, EV_ERROR, EV_EOF;

        static OSSignal toOSSignal(typeof(kevent64_s.ident) signal)
        in
        {
            ASSERT!"Event signal %s could not be converted to OSSignal"(
                signal >= OSSignal.min && signal <= OSSignal.max, signal
            );
        }
        do
        {
            return cast(OSSignal) signal;
        }

        const spec = timeout.toTimespec();
        const specTimeout = timeout == Duration.max ? null : &spec;

        const result = kqueueFd.osCall!kevent64(
            changes.ptr,
            numberOfChanges,
            events.ptr,
            cast(int) events.length,
            0,
            specTimeout
        );
        numberOfChanges = 0;

        if (result < 0 && errno == EINTR)
        {
            DEBUG!"kevent64 call interrupted by signal";
            return true;
        }

        errnoEnforceNGC(result >= 0, "kevent64 failed");

        foreach (ref event ; events[0 .. result])
        {
            if (event.flags & EV_ERROR)
            {
                switch(event.data)
                {
                    case EPIPE, EBADF:
                        continue;
                    default:
                        errno = cast(int) event.data;
                        errnoEnforceNGC(false, "event failed");
                }
            }

            auto ctx = cast(FdContext*) event.udata;
            ASSERT!"ctx is null"(ctx !is null);

            with(Direction) foreach(dir; Read..(Write+1)) {
                final switch(dir) {
                case Read:
                    if (event.filter != EVFILT_READ && event.filter != EVFILT_SIGNAL)
                        continue;
                    break;
                case Write:
                    if (event.filter != EVFILT_WRITE)
                        continue;
                    break;
                case Both:
                    assert(false);
                }

                auto state = &ctx.states[dir];
                with(FdContext.Type) final switch(state.type)
                {
                case None:
                    if( cast(Direction)dir==Read || event.filter != EVFILT_READ ) {
                        // Since most FDs are available for write most of the time, almost any wakeup would trigger
                        // this warning. As such, we log only if one of two conditions are met:
                        // Either we got this condition on a read, or we got this condition on a write, but the FD is
                        // not read ready.
                        WARN!"kqueue64s for returned fd %s events %s which is not listening for %s"(
                                ctx.fdNum, event.filter, dir);
                    }
                    break;
                case FiberHandle:
                    theReactor.resumeFiber(state.fibHandle);
                    break;
                case Callback:
                    state.callback(state.opaq);
                    break;
                case CallbackOneShot:
                    state.type = None;
                    state.callback(state.opaq);
                    break;
                case SignalHandler:
                    ASSERT!"Event signal %s was not the same as the registered signal %s"(event.ident == ctx.fdNum, event.ident, ctx.fdNum);
                    state.signalHandler(toOSSignal(event.ident));
                    break;
                }
            }
        }

        return true;
    }

private:

    void internalRegisterFD(int fd, FdContext* ctx, Direction dir) @trusted @nogc
    {
        import mecca.reactor.platform : EV_ADD, EV_CLEAR, EV_ENABLE;

        ASSERT!"ctx is null"(ctx !is null);
        static immutable short[2] filters = [EVFILT_READ, EVFILT_WRITE];

        foreach (filter ; filters)
        {
            const kevent64_s event = {
                ident: fd,
                filter: filter,
                flags: EV_ADD | EV_ENABLE | EV_CLEAR,
                udata: cast(ulong) ctx
            };

            const result = queueEvent(event);
            errnoEnforceNGC(result >= 0, "Adding fd to queue failed");
        }
    }

    void internalDeregisterFD(int fd, FdContext* ctx, bool fdIsClosing) nothrow @trusted @nogc
    {
        import core.stdc.errno : errno;
        import mecca.reactor.platform : EV_DELETE;

        // Events are automatically removed when a file descriptor is closed.
        // This will save us one system call.
        if (fdIsClosing)
            return;

        ASSERT!"ctx is null"(ctx !is null);
        static immutable short[2] filters = [EVFILT_READ, EVFILT_WRITE];

        foreach (filter ; filters)
        {
            const kevent64_s event = {
                ident: fd,
                filter: filter,
                flags: EV_DELETE
            };

            const result = queueEvent(event);
            ASSERT!"Removing fd from queue failed with errno %s"(result >= 0, errno);
        }
    }

    void internalRegisterSignalHandler(FdContext* ctx) @trusted @nogc
    {
        import mecca.reactor.platform : EV_ADD, EV_CLEAR, EV_ENABLE;

        ASSERT!"ctx is null"(ctx !is null);

        const kevent64_s event = {
            ident: ctx.fdNum,
            filter: EVFILT_SIGNAL,
            flags: EV_ADD | EV_ENABLE | EV_CLEAR,
            udata: cast(ulong) ctx
        };

        const result = queueEvent(event, true);
        errnoEnforceNGC(result >= 0, "Adding signal to queue failed");
    }

    void internalDeregisterSignalHandler(FdContext* ctx) nothrow @trusted @nogc
    {
        import core.stdc.errno : errno;
        import mecca.reactor.platform : EV_DELETE;

        const kevent64_s event = {
            ident: ctx.fdNum,
            filter: EVFILT_SIGNAL,
            flags: EV_DELETE
        };

        const result = queueEvent(event, true);
        ASSERT!"Removing signal from queue failed with errno %s"(result >= 0, errno);
    }

    int queueEvent(const ref kevent64_s event, bool flush = false) nothrow @trusted @nogc
    {
        changes[numberOfChanges++] = event;

        if (numberOfChanges != changes.length && !flush)
            return 1;

        const result = kqueueFd.osCall!kevent64(changes.ptr, numberOfChanges,
            null, 0, 0, null);
        numberOfChanges = 0;

        return result;
    }
}

extern (C) int kqueue() nothrow @trusted @nogc;
extern (C) int fcntl(int, int, ...) nothrow @trusted @nogc;

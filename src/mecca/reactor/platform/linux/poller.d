module mecca.reactor.platform.linux.poller;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux):
package(mecca.reactor.platform):

import core.stdc.errno;
import core.sys.linux.epoll;
import core.sys.posix.fcntl;
import unistd = core.sys.posix.unistd;
import std.conv;
import std.exception;
import std.meta;
import std.traits;
import std.string;

import mecca.containers.pools;
import mecca.lib.io;
import mecca.lib.exception;
import mecca.lib.reflection;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.subsystems.poller : Direction;

//
// epoll subsystems (sleep in the kernel until events occur)
//

// Definitions missing from the phobos headers or lacking nothrow @nogc
private extern(C) {
    int epoll_create1 (int flags) nothrow @trusted @nogc;
    int fcntl(int, int, ...) nothrow @trusted @nogc;
    /+
    int epoll_pwait(int epfd, epoll_event* events,
                      int maxevents, int timeout,
                      const sigset_t *sigmask);
    +/
}

struct Poller {
    public import mecca.reactor.subsystems.poller : FdContext;

private: // Not that this does anything, as the struct itself is only visible to this file.
    // Prevent accidental copying
    @disable this(this);

    FD epollFd;
    FixedPool!(FdContext, MAX_CONCURRENT_FDS) fdPool;

    enum MIN_DURATION = dur!"msecs"(1);
    enum NUM_BATCH_EVENTS = 32;
    enum MAX_CONCURRENT_FDS = 512;

public:

    void open() @safe {
        ASSERT!"Must call theReactor.setup before calling ReactorFD.openReactor"(theReactor.isOpen);
        int epollFdOs = epoll_create1(EPOLL_CLOEXEC);
        errnoEnforceNGC( epollFdOs>=0, "Failed to create epoll fd" );
        epollFd = FD(epollFdOs);

        fdPool.open();
    }

    void close() {
        epollFd.close();
    }

    @property bool isOpen() const pure nothrow @safe @nogc {
        return epollFd.isValid;
    }

    FdContext* registerFD(ref FD fd, bool alreadyNonBlocking = false) @safe @nogc {
        ASSERT!"registerFD called outside of an open reactor"( theReactor.isOpen );
        ASSERT!"registerFD called without first calling ReactorFD.openReactor"( epollFd.isValid );
        FdContext* ctx = fdPool.alloc();
        setToInit(ctx);
        ctx.fdNum = fd.fileNo;
        scope(failure) fdPool.release(ctx);

        if( !alreadyNonBlocking ) {
            int res = .fcntl(fd.fileNo, F_SETFL, O_NONBLOCK|FD_CLOEXEC);
            errnoEnforceNGC( res>=0, "Failed to set fd to non-blocking mode" );
        }

        internalRegisterFD(fd.fileNo, ctx, Direction.Both);

        return ctx;
    }

    void deregisterFd(ref FD fd, FdContext* ctx, bool fdIsClosing = false) nothrow @safe @nogc {
        // fdIsClosing is only used for kqueue
        internalDeregisterFD(fd.fileNo, ctx);

        fdPool.release(ctx);
    }

    void waitForEvent(FdContext* ctx, int fd, Direction dir, Timeout timeout = Timeout.infinite) @safe @nogc {
        // XXX Relax this restriction if there is a need
        DBG_ASSERT!"Cannot wait for both in and out events"(dir != Direction.Both);
        auto ctxState = &ctx.states[dir];
        with(FdContext.Type) final switch(ctxState.type) {
        case None:
            break;
        case FiberHandle:
            ASSERT!(
                    "Two fibers cannot wait on the same ReactorFD %s direction %s at once: %s asked to wait with %s " ~
                    "already waiting")
                    ( false, fd, dir, theReactor.currentFiberHandle.fiberId, ctxState.fibHandle.fiberId );
            break;
        case Callback:
        case CallbackOneShot:
            ASSERT!"Cannot wait on FD %s direction %s already waiting on a callback"(false, fd, dir);
            break;
        case SignalHandler:
            ASSERT!"Should never happen for epoll, SignalHandler is kqueue only"(false);
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

    /// Export of the poller function
    ///
    /// A variation of this function is what's called by the reactor idle callback (unless `OpenOptions.registerDefaultIdler`
    /// is set to `false`).
    @notrace void poll() {
        reactorIdle(Duration.zero);
    }

    @notrace bool reactorIdle(Duration timeout) {
        int intTimeout;
        if( timeout == Duration.max )
            intTimeout = -1;
        else
            intTimeout = to!int(timeout.total!"msecs");

        epoll_event[NUM_BATCH_EVENTS] events;
        if( timeout > Duration.zero && intTimeout == 0 )
            intTimeout = 1;
        int res = epollFd.osCall!epoll_wait(events.ptr, NUM_BATCH_EVENTS, intTimeout);

        if( res<0 &&  errno==EINTR ) {
            DEBUG!"epoll call interrupted by signal"();
            return true;
        }

        errnoEnforceNGC( res>=0, "epoll_wait failed" );

        foreach( ref event; events[0..res] ) {
            auto ctx = cast(FdContext*)event.data.ptr;

            with(Direction) foreach(dir; Read..(Write+1)) {
                final switch(dir) {
                case Read:
                    if( (event.events & (EPOLLIN | EPOLLHUP))==0 )
                        continue;
                    break;
                case Write:
                    if( (event.events & EPOLLOUT)==0 )
                        continue;
                    break;
                case Both:
                    assert(false);
                }

                auto state = &ctx.states[dir];
                with(FdContext.Type) final switch(state.type) {
                case None:
                    if( cast(Direction)dir==Read || (event.events & (EPOLLIN | EPOLLHUP))==0 ) {
                        // Since most FDs are available for write most of the time, almost any wakeup would trigger
                        // this warning. As such, we log only if one of two conditions are met:
                        // Either we got this condition on a read, or we got this condition on a write, but the FD is
                        // not read ready.
                        WARN!"epoll for returned fd %s events %x which is not listening for %s"(
                                ctx.fdNum, event.events, cast(Direction)dir);
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
                    ASSERT!"Should never happen for epoll, SignalHandler is kqueue only"(false);
                    break;
                }
            }
        }

        return true;
    }

private:
    @notrace void internalRegisterFD(int fd, FdContext* ctx, Direction dir) @trusted @nogc {
        epoll_event event = void;
        event.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET; // Register with Edge Trigger behavior
        event.data.ptr = ctx;
        int res = epollFd.osCall!epoll_ctl(EPOLL_CTL_ADD, fd, &event);
        errnoEnforceNGC( res>=0, "Adding fd to epoll failed" );
    }

    @notrace void internalDeregisterFD(int fd, FdContext* ctx) nothrow @trusted @nogc {
        int res = epollFd.osCall!epoll_ctl(EPOLL_CTL_DEL, fd, null);

        if(res<0) {
        // There is no reason for a registered FD to fail removal, so we assert instead of throwing
            INFO!"Removing fd %d from epoll failed with errno %s"(fd, errno );
        }
    }
}

// Unit test in mecca.reactor.io

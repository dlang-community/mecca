module mecca.reactor.fd;

import core.stdc.errno;
import core.sys.linux.epoll;
import std.conv;
import std.exception;
import std.meta;
import std.traits;

import unistd = core.sys.posix.unistd;
import fcntl = core.sys.posix.fcntl;

import mecca.reactor.reactor;
import mecca.containers.pools;
import mecca.lib.time;
import mecca.log;

// Definitions missing from the phobos headers
extern(C) {
    int pipe2(int[2]* pipefd, int flags);
    /+
    int epoll_pwait(int epfd, epoll_event* events,
                      int maxevents, int timeout,
                      const sigset_t *sigmask);
    +/
}

struct FD {
private:
    int fd = -1;
    Epoll.FdContext* ctx;

public:
    static void openReactor() {
        epoller.open();
    }

    static void closeReactor() {
        epoller.close();
    }

    @disable this(this);

    this(int fd, bool alreadyNonBlocking = false) {
        this.fd = fd;
        ctx = epoller.registerFD(fd, alreadyNonBlocking);
    }

    ~this() {
        close();
    }

    void close() {
        if( fd>=0 ) {
            assert(ctx !is null);

            epoller.deregisterFd( fd, ctx );

            int res = unistd.close(fd);
            errnoEnforce(res>=0, "Close failed");
            fd = -1;
            ctx = null;
        }
    }

    auto opDispatch(string funcName, T...)(T args) if( isIntegral!(ReturnType!( __traits(getMember, unistd, funcName) )) ) {
        // TODO have T deduced from funcName rather than from the caller. Current way needlessly creates multiple instantiations of the same
        // function.

        // DMDBUG the following line does not compile: Error: basic type expected, not __traits
        // alias func = __traits(getMember, unistd, funcName);
        alias func = Alias!(__traits(getMember, unistd, funcName));
        alias RetType = ReturnType!func;
        /+
        pragma(msg, funcName);
        pragma(msg, RetType);
        pragma(msg, Parameters!func);
        pragma(msg, T);
        +/
        RetType res;
        bool again;

        do {
            again = false;
            res = func(this.fd, args);
            if( res<0 && errno == EAGAIN ) {
                again = true;
                epoller.waitForEvent(ctx); // Makes sure that the epoll will wake us up when we can try again. May result in false wakeups
            }
        } while( again );

        return res;
    }

    static void pipe(out FD readFd, out FD writeFd) {
        int[2] fds;
        int res = pipe2(&fds, fcntl.O_NONBLOCK);
        errnoEnforce(res>=0, "Failed to create anonymous pipe");
        readFd = FD(fds[0], true);
        writeFd = FD(fds[1], true);
    }
}

private:

struct Epoll {
    struct FdContext {
        FiberHandle fibHandle;
    }

private: // Not that this does anything, as the struct itself is only visible to this file.
    int epollFd = -1;
    FixedPool!(FdContext, MAX_CONCURRENT_FDS) fdPool;

    enum MIN_DURATION = dur!"msecs"(1);
    enum NUM_BATCH_EVENTS = 32;
    enum MAX_CONCURRENT_FDS = 512;

public:

    void open() {
        assert(theReactor.isOpen, "Must call theReactor.setup before calling FD.openReactor");
        epollFd = epoll_create1(0);
        errnoEnforce( epollFd>=0, "Failed to create epoll fd" );

        fdPool.reset();

        theReactor.registerIdleCallback(&reactorIdle);
    }

    void close() {
        assert(false, "TODO: implement");
    }

    FdContext* registerFD(int fd, bool alreadyNonBlocking = false) {
        assert( epollFd>=0, "registerFD called without first calling FD.openReactor" );
        FdContext* ctx = fdPool.alloc();
        scope(failure) fdPool.release(ctx);

        if( !alreadyNonBlocking ) {
            int res = fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.O_NONBLOCK);
            errnoEnforce( res>=0, "Failed to set fd to non-blocking mode" );
        }

        epoll_event event = void;
        event.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET; // Register with Edge Trigger behavior
        event.data.ptr = ctx;
        int res = epoll_ctl(epollFd, EPOLL_CTL_ADD, fd, &event);
        errnoEnforce( res>=0, "Adding fd to epoll failed" );

        return ctx;
    }

    void deregisterFd(int fd, FdContext* ctx) {
        fdPool.release(ctx);
        // We do not call EPOLL_CTL_DEL, as the caller of this function will soon call close, which achieves the same result. No reason to
        // waste a syscall.
    }

    void waitForEvent(FdContext* ctx) {
        /*
            TODO: In the future, we might wish to allow one fiber to read from an FD while another writes to the same FD. As the code
            currently stands, this will trigger the assert below
         */
        assert( !ctx.fibHandle.isValid, "Two fibers cannot wait on the same FD at once" );
        ctx.fibHandle = theReactor.runningFiberHandle;
        scope(exit) destroy(ctx.fibHandle);

        theReactor.suspendThisFiber();
    }

private:
    void reactorIdle(Duration timeout) {
        DEBUG!"Calling epoll_wait with a timeout of %s"(timeout);

        epoll_event[NUM_BATCH_EVENTS] events;
        if( timeout > Duration.zero && timeout < MIN_DURATION )
            timeout = MIN_DURATION;
        int res = epoll_wait(epollFd, events.ptr, NUM_BATCH_EVENTS, to!int(timeout.total!"msecs"));
        errnoEnforce( res>=0, "epoll_wait failed" );

        foreach( ref event; events[0..res] ) {
            auto ctx = cast(FdContext*)event.data.ptr;
            if( !ctx.fibHandle.isValid ) {
                WARN!"epoll returned handle %s which is no longer valid"(ctx.fibHandle);
                continue;
            }

            theReactor.resumeFiber(ctx.fibHandle);
        }
    }
}

__gshared Epoll epoller;

unittest {
    import mecca.lib.consts;
    import core.sys.posix.sys.types;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    FD.openReactor();

    FD pipeRead, pipeWrite;
    FD.pipe( pipeRead, pipeWrite );

    void reader() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;
        uint lastNum = -1;

        // Send 128MB over the pipe
        ssize_t res;
        while((res = pipeRead.opDispatch!"read"(buffer.ptr, BUFF_SIZE))>0) {
            DEBUG!"Received %s bytes"(res);
            assert(res==BUFF_SIZE, "Short read from pipe");
            assert(buffer[0] == ++lastNum, "Read incorrect value from buffer");
        }

        errnoEnforce(res==0, "Read failed from pipe");
        INFO!"Reader finished"();
        theReactor.stop();
    }

    void writer() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;

        // Send 128MB over the pipe
        while(buffer[0] < (128*MB/BUFF_SIZE)) {
            DEBUG!"Sending %s bytes"(BUFF_SIZE);
            ssize_t res = pipeWrite.write(buffer.ptr, BUFF_SIZE);
            errnoEnforce( res>=0, "Write failed on pipe");
            assert( res==BUFF_SIZE, "Short write to pipe" );
            buffer[0]++;
        }

        INFO!"Writer finished - closing pipe"();
        pipeWrite.close();
    }

    theReactor.spawnFiber(&reader);
    theReactor.spawnFiber(&writer);

    theReactor.start();
}

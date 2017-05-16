module mecca.reactor.transports;

import std.string;
import std.exception;
import std.algorithm: min, max;

import fcntl = core.sys.posix.fcntl;
import unistd = core.sys.posix.unistd;
import unistat = core.sys.posix.sys.stat;
import core.sys.linux.epoll;
import core.sys.linux.sys.inotify;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.in_;
import core.sys.posix.netinet.tcp;
import core.stdc.errno;

import mecca.lib.time;
import mecca.lib.net;
import mecca.containers.table: SmallTable;
import mecca.containers.linked_set;
import mecca.containers.pools: FixedPool;
import mecca.lib.tracing;
import mecca.reactor.reactor;
import mecca.reactor.fibers;
import mecca.reactor.sync;


class TransportException: Exception {
    this(string msg, string file=__FILE__, size_t line=__LINE__){super(msg, file, line);}
}
class EOFException: TransportException {
    this(string msg, string file=__FILE__, size_t line=__LINE__){super(msg, file, line);}
}

@FMT("EpollHandle({fd})")
package struct EpollHandle {
package:
    enum Mode: ubyte {NONE, FIB, DLG}

    int            fd = -1;
    uint           reportedEvents;
    uint           refCount;
    Mode           mode;
    union {
        Suspender  suspender;
        void delegate(EpollHandle*) callback;
    }
    Chain          _chain;

    @disable this(this);

    void close() {
        if (fd >= 0) {
            unistd.close(fd);
            fd = -1;
        }
    }
    public @property bool closed() const pure nothrow @nogc {
        return fd < 0;
    }
    public @property int fileno() const pure nothrow @nogc {
        return fd;
    }

    @notrace public void _poolElementReleased() {
        assert (fd < 0, "Releasing unclosed handle, fd=%s".format(fd));
    }

    @notrace void clearRead() {
        reportedEvents &= ~EPOLLIN;
    }
    @notrace void clearWrite() {
        reportedEvents &= ~EPOLLOUT;
    }
    @property bool isHUP() const pure nothrow @nogc {
        return (reportedEvents & (EPOLLHUP | EPOLLRDHUP)) != 0;
    }
    @property bool canRead() const pure nothrow @nogc {
        return (reportedEvents & (EPOLLIN | EPOLLHUP | EPOLLRDHUP)) != 0;
    }
    @property bool canWrite() const pure nothrow @nogc {
        return (reportedEvents & EPOLLOUT) != 0;
    }

    @notrace void setCallback(void delegate(EpollHandle*) dg) {
        assert (dg !is null);
        assert (mode == Mode.NONE);
        mode = Mode.DLG;
        callback = dg;
    }
    @notrace void clearCallback() {
        mode = Mode.NONE;
        callback = null;
    }

    @notrace void suspendFiber(Timeout timeout = Timeout.infinite) {
        assert (mode == Mode.NONE);
        mode = Mode.FIB;
        scope(exit) mode = Mode.NONE;
        suspender.wait(timeout);
    }

    @notrace void invoke(uint newEvents) {
        reportedEvents |= newEvents;
        final switch (mode) with (Mode) {
            case NONE:
                break;
            case FIB:
                suspender.wakeUp();
                mode = Mode.NONE;
                break;
            case DLG:
                assert (callback !is null);
                callback(&this);
                break;
        }
    }
}

struct Epoller {
    private int epfd = -1;

    void open() {
        assert (epfd < 0);
        epfd = epoll_create1(EPOLL_CLOEXEC);
        errnoEnforce(epfd >= 0, "epoll_create1");
    }
    void close() {
        if (epfd >= 0) {
            unistd.close(epfd);
            epfd = -1;
        }
    }
    @property bool closed() {
        return epfd < 0;
    }

    @notrace package EpollHandle* registerFD(int fd) {
        assert (!closed);
        assert (fd >= 0);
        auto h = handlePool.alloc();
        scope(failure) handlePool.release(h);

        auto flags = fcntl.fcntl(fd, fcntl.F_GETFL);
        errnoEnforce(flags >= 0, "fcntl(get %s) failed".format(fd));
        if ((flags & fcntl.O_NONBLOCK) == 0) {
            errnoEnforce(fcntl.fcntl(fd, fcntl.F_SETFL, flags | fcntl.O_NONBLOCK) != -1, "fcntl(set %s) failed".format(fd));
        }

        epoll_event evt = void;
        evt.events = EPOLLIN | EPOLLRDHUP | EPOLLOUT | EPOLLET;
        evt.data.ptr = h;
        errnoEnforce(epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &evt) == 0, "epoll_ctl(ADD %s)".format(fd));

        h.fd = fd;
        h.refCount = 1;
        h.mode = EpollHandle.Mode.NONE;
        return h;
    }

    @notrace void _poll(int timeoutMsec) {
        assert (!closed);
        static assert (epoll_event.sizeof == 12);
        epoll_event[128] _events = void;
        auto res = epoll_wait(epfd, _events.ptr, _events.length, timeoutMsec);
        errnoEnforce(res >= 0, "epoll_wait");
        foreach(e; _events[0 .. res]) {
            (cast(EpollHandle*)e.data.ptr).invoke(e.events);
        }
    }

    @notrace void poll() {
        _poll(0);
    }
}

struct FSWatchDescriptor {
    private int wd;

    private this(int wd) {
        assert (wd >= 0);
        this.wd = wd;
    }
}

struct FSEvent {
    FSWatchDescriptor desc;
    uint event;
    uint cookie;
    char[] name;

    @property bool created() pure const nothrow @nogc {return (event & IN_CREATE) != 0;}
    @property bool deleted() pure const nothrow @nogc {return (event & IN_DELETE) != 0;}
}

private struct FSWatcher {
    // man: Specifying a buffer of size ``sizeof(struct inotify_event) + NAME_MAX + 1``
    //      will be sufficient to read at least one event
    enum MAX_WATCHERS = 16;
    enum NAME_MAX = 255;
    enum MAX_EVENT_SIZE = inotify_event.sizeof + NAME_MAX + 1;

    EpollHandle* handle;
    SmallTable!(FSWatchDescriptor, void delegate(const(FSEvent)*), MAX_WATCHERS) watchers;

    @notrace void _open() {
        if (handle !is null) {
            return;
        }
        int fd = inotify_init1(IN_CLOEXEC);
        errnoEnforce(fd >= 0, "inotify_init failed");
        this.handle = epoller.registerFD(fd);
        this.handle.setCallback(&fetchEvents);
        watchers.removeAll();
    }
    void close() {
        if (handle) {
            handle.close();
            handlePool.release(handle);
            handle = null;
        }
    }
    @property bool closed() const pure nothrow @nogc {
        return handle is null;
    }

    @notrace FSWatchDescriptor watchPath(string path, void delegate(const(FSEvent)*) dg) {
        return watchPath!"IN_CREATE|IN_DELETE"(path, dg);
    }
    @notrace FSWatchDescriptor watchPath(string mask)(string path, void delegate(const(FSEvent)*) dg) {
        static import inotify_mod = core.sys.linux.sys.inotify;
        enum m = mixin((){
            string s = "0";
            foreach(flag; mask.split("|")) {
                s ~= " | (inotify_mod." ~ flag ~ ")";
            }
            return s;
        }());
        return watchPath(path, m, dg);
    }
    FSWatchDescriptor watchPath(string path, uint mask, void delegate(const(FSEvent)*) dg) {
        assert (!watchers.full);
        int wd = inotify_add_watch(handle.fd, path.toStringz, mask);
        errnoEnforce(wd >= 0, "inotify_add_watch('%s') failed".format(path));
        auto desc = FSWatchDescriptor(wd);
        assert (desc !in watchers, "wd %s already exists (path=%s)".format(wd, path));
        watchers[desc] = dg;
        return desc;
    }

    void unwatch(ref FSWatchDescriptor desc) {
        if (!closed) {
            assert (desc.wd >= 0);
            assert (desc in watchers, "invalid wd=%s".format(desc.wd));
            errnoEnforce(inotify_rm_watch(handle.fd, desc.wd) == 0, "inotify_rm_watch(%s) failed".format(desc.wd));
            watchers.remove(desc);
            desc.wd = -1;
        }
    }

    @notrace void _dispatch(void[] eventsBuf) {
        while (eventsBuf.length > 0) {
            inotify_event* evt = cast(inotify_event*)eventsBuf.ptr;
            eventsBuf = eventsBuf[evt.len .. $];

            auto desc = FSWatchDescriptor(evt.wd);
            assert (desc in watchers, "wd=%s, not found in watchers".format(evt.wd));
            auto callback = watchers[desc];
            assert (callback !is null, "wd=%s entry callback is null".format(evt.wd));

            FSEvent fsevt;
            fsevt.desc = desc;
            fsevt.cookie = evt.cookie;
            fsevt.event = evt.mask;

            // trim NULs
            auto name = (cast(char*)evt.name.ptr)[0 .. evt.len];
            auto len = evt.len;
            while (len > 0 && name[len-1] == '\0') {
                len--;
            }
            fsevt.name = name[0 .. len];

            // name is stored on the stack, so the callback must be called immediately (not via reactor.call)
            // and the name must be copied if the user wishes to keep it
            callback(&fsevt);
        }
    }

    @notrace void fetchEvents(EpollHandle* _) {
        assert (!closed);
        ssize_t res;
        ubyte[MAX_EVENT_SIZE * 10] eventsBuf = void;

        while (true) {
            res = unistd.read(handle.fd, eventsBuf.ptr, eventsBuf.length);
            if (res >= 0) {
                _dispatch(eventsBuf[0 .. res]);
            }
            else if (errno == EAGAIN) {
                handle.clearRead();
                break;
            }
            else {
                errnoEnforce(errno == EINTR, "read(inotify) failed");
            }
        }
    }
}

private struct SignalWatcher {
    import core.sys.posix.signal;
    import core.sys.linux.sys.signalfd;
    enum MAX_SIGNALS = 32;

    EpollHandle* handle;
    sigset_t sigset;
    void delegate()[MAX_SIGNALS] sigHandlers;

    private void open() {
        assert (closed);
        sigemptyset(&sigset);
        int fd = signalfd(-1, &sigset, SFD_CLOEXEC);
        errnoEnforce(fd >= 0, "signalfd failed");
        this.handle = epoller.registerFD(fd);
        this.handle.setCallback(&fetchSignals);
        sigHandlers[] = null;
    }
    void close() {
        if (handle) {
            sigprocmask(SIG_UNBLOCK, &sigset, null);
            sigemptyset(&sigset);
            handle.close();
            handlePool.release(handle);
            handle = null;
        }
    }
    @property bool closed() const pure nothrow @nogc {
        return handle is null;
    }

    void registerSignal(string name)(void delegate() handler) {
        enum signum = __traits(getMember, core.sys.posix.signal, name);
        assert (sigHandlers[signum] is null, "%s is already registered".format(signum));
        sigaddset(&sigset, signum);
        sigHandlers[signum] = handler;
        errnoEnforce(pthread_sigmask(SIG_BLOCK, &sigset, NULL) == 0, "pthread_sigmask(BLOCK) failed");
        errnoEnforce(signalfd(handle.fd, &sigset, SFD_CLOEXEC) == handle.fd, "signalfd failed");
    }
    void unregisterSignal(string name)() {
        enum signum = __traits(getMember, core.sys.posix.signal, name);
        if (sigHandlers[signum] !is null) {
            sigdelset(&sigset, signum);
            errnoEnforce(signalfd(handle.fd, &sigset, SFD_CLOEXEC) == handle.fd, "signalfd failed");
            sigHandlers[signum] = null;

            sigset_t tmp = void;
            sigempty(&tmp);
            sigaddset(&tmp, signum);
            errnoEnforce(pthread_sigmask(SIG_UNBLOCK, &tmp, NULL) == 0, "pthread_sigmask(UNBLOCK) failed");
        }
    }

    @notrace void fetchSignals(EpollHandle* _) {
        signalfd_siginfo[8] sigBuf;
        while (true) {
            auto res = unistd.read(handle.fd, sigBuf.ptr, sigBuf.sizeof);
            if (res >= 0) {
                assert (res > 0);
                assert (res % signalfd_siginfo.sizeof == 0, "res=%s".format(res));
                auto count = res / signalfd_siginfo.sizeof;
                foreach(ref siginfo; sigBuf[0 .. count]) {
                    INFO!"Received #SIGNAL %s from pid %s, code %s, addr %s"(siginfo.ssi_signo, siginfo.ssi_pid,
                        siginfo.ssi_code, siginfo.ssi_addr);
                    assert (sigHandlers[siginfo.ssi_signo] !is null);
                    sigHandlers[siginfo.ssi_signo]();
                }
                if (count < sigBuf.length) {
                    break;
                }
            }
            else if (errno == EAGAIN) {
                handle.clearRead();
                break;
            }
            else {
                errnoEnforce(errno == EINTR, "read(signalfd) failed");
            }
        }
    }
}

package FixedPool!EpollHandle handlePool;
package __gshared Epoller epoller;
public __gshared FSWatcher fsWatcher;
public __gshared SignalWatcher signalWatcher;


package void initTransports() {
    handlePool.open(theReactor.options.maxFDs);
    epoller.open();
    signalWatcher.open();
    enum IDLE_SLEEP_MSEC = 10;

    void idleEpoll() {
        //auto cyc = theReactor.ctq.timeTillNextEntry();
        epoller._poll(IDLE_SLEEP_MSEC);
    }

    if (theReactor.options.userlandPolling) {
        theReactor.registerPoller(&epoller.poll, 500.usecs, true /* idle */);
    }
    else {
        theReactor.registerPoller(&epoller.poll, 2.msecs, false /* idle */);
        // this is actually the idler that yields to the kernel
        theReactor.registerIdlePoller(&idleEpoll);
    }
}

package void finiTransports() {
    signalWatcher.close();
    fsWatcher.close();
    epoller.close();
    handlePool.close();
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Transport Implementations
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

mixin template TransportBase() {
    EpollHandle* handle;

    package this(int fd) {
        assert (fd >= 0);
        assert (handle is null);
        this.handle = epoller.registerFD(fd);
    }
    package this(EpollHandle* handle) {
        assert (handle !is null);
        this.handle = handle;
    }

    void close() {
        if (handle) {
            handle.close();
            handlePool.release(handle);
            handle = null;
        }
    }
    @property bool closed() const pure nothrow @nogc {
        return handle is null;
    }

    static assert (this.sizeof == (void*).sizeof);
}

struct ListenerSocket {
    mixin TransportBase;

    static ListenerSocket listenTCP(ushort port) {
        return listenTCP(SockAddr.any4(port));
    }
    static ListenerSocket listenTCP(SockAddr sa, int backlog = 10) {
        int fd = socket(sa.family, SOCK_STREAM, IPPROTO_TCP);
        errnoEnforce(fd >= 0, "socket() failed");
        scope(failure) unistd.close(fd);

        uint val = 1;
        errnoEnforce(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, val.sizeof) == 0, "setsockopt(SO_REUSEADDR) failed");
        errnoEnforce(bind(fd, sa.asSockaddr, sa.length) == 0, "bind failed");
        errnoEnforce(.listen(fd, backlog) == 0, "listen failed");

        return ListenerSocket(fd);
    }

    @notrace StreamSocket accept(Timeout timeout = Timeout.infinite) {
        sockaddr_in6 sa;
        socklen_t len = sa.sizeof;

        while (true) {
            auto fd = .accept(handle.fd, cast(sockaddr*)&sa, &len);
            if (fd >= 0) {
                DEBUG!"#TRANSPORT Listener %s accepted socket %s"(handle.fd, fd);
                return StreamSocket(fd);
            }
            else if (errno == EAGAIN) {
                static assert (EWOULDBLOCK == EAGAIN);
                handle.clearRead();
                handle.suspendFiber(timeout);
            }
            else {
                errnoEnforce(errno == EINTR, "accept failed");
            }
        }
    }
}

struct StreamSocket {
    enum MAX_IO_CHUNK = 32 * 1024;
    mixin TransportBase;

    static SockAddr resolve(string name) {
        return SockAddr.init;
    }

    //static StreamSocket connectTCP(string name, ushort port) {
    //    auto sa = SockAddr.resolve(hostname, service, family, sockType);
    //    return connectTCP(sa);
    //}
    static StreamSocket connectTCP(SockAddr sa, Timeout timeout = Timeout.infinite, bool nodelay = true) {
        int fd = socket(sa.family, SOCK_STREAM, IPPROTO_TCP);
        errnoEnforce(fd >= 0, "socket() failed");

        scope(failure) {
            if (fd >= 0) {
                unistd.close(fd);
            }
        }

        auto connSock = StreamSocket(fd);
        scope(failure) {
            connSock.close();
            fd = -1;
        }

        if (.connect(fd, sa.asSockaddr, sa.length) != 0) {
            errnoEnforce(errno == EINPROGRESS, "connect() failed");
            connSock.handle.suspendFiber(timeout);

            int connErrno;
            uint connErrnoSize = connErrno.sizeof;
            errnoEnforce(getsockopt(fd, SOL_SOCKET, SO_ERROR, &connErrno, &connErrnoSize) == 0, "getsockopt(SO_ERROR) failed");
            enforce(connErrnoSize == connErrno.sizeof, "failed getting SO_ERROR");
            errno = connErrno;
            errnoEnforce(connErrno == 0, "connect() failed");
        }
        if (nodelay) {
            uint val = 1;
            errnoEnforce(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, val.sizeof) == 0, "setsockopt(TCP_NODELAY) failed");
        }

        return connSock;
    }

    static StreamSocket[2] connectPair() {
        int[2] fds;
        errnoEnforce(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0, "socketpair() failed");
        StreamSocket[2] cs;
        cs[0] = StreamSocket(fds[0]);
        cs[1] = StreamSocket(fds[1]);
        return cs;
    }

    static StreamSocket connectUnixDomain(string path) {
        import core.sys.posix.sys.un;
        enforce(path.length < sockaddr_un.init.sun_path.length,
            "Path too long (%s >= %s)".format(path.length, sockaddr_un.init.sun_path.length));

        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        errnoEnforce(fd > 0, "socket(AF_UNIX) failed");
        scope(failure) unistd.close(fd);

        sockaddr_un sa;
        sa.sun_family = AF_UNIX;
        sa.sun_path[0 .. path.length] = cast(byte[])path;
        sa.sun_path[path.length] = '\0';

        errnoEnforce(.connect(fd, cast(sockaddr*)&sa, sa.sizeof) == 0, "connect(%s) failed".format(path));
        return StreamSocket(fd);
    }

//    @property SockEndpoint localEP() {
//        return SockEndpoint.getSockName(fd);
//    }
//    @property SockEndpoint remoteEP() {
//        return SockEndpoint.getPeerName(fd);
//    }

    @notrace void[] recv(void[] buf, bool eager = true, Timeout timeout = Timeout.infinite) {
        assert (!closed);
        size_t offset = 0;

        while (offset < buf.length) {
            auto bytes = .recv(handle.fd, &buf[offset], min(buf.length - offset, MAX_IO_CHUNK), MSG_NOSIGNAL);
            if (bytes == 0) {
                // EOF
                break;
            }
            else if (bytes > 0) {
                offset += bytes;
            }
            else if (errno == EAGAIN) {
                handle.clearRead();
                if (eager && offset > 0) {
                    // return whatever we already have
                    break;
                }
                handle.suspendFiber(timeout);
            }
            else {
                errnoEnforce(errno == EINTR, "recv() failed");
            }
        }
        return buf[0 .. offset];
    }

    @notrace void recvObj(T)(T* obj, Timeout timeout = Timeout.infinite) {
        auto res = this.recv((cast(ubyte*)obj)[0 .. T.sizeof], false, timeout);
        enforceEx!EOFException(res.length == T.sizeof, "got %s bytes, expected %s".format(res.length, T.sizeof));
    }

    @notrace void send(const(void)[] buf, Timeout timeout = Timeout.infinite) {
        assert (!closed);

        while (buf.length > 0) {
            auto sent = .send(handle.fd, buf.ptr, min(buf.length, MAX_IO_CHUNK), MSG_NOSIGNAL);
            if (sent >= 0) {
                assert (sent != 0, "sent==0");
                buf = buf[sent .. $];
            }
            else if (errno == EAGAIN) {
                handle.clearWrite();
                handle.suspendFiber(timeout);
            }
            else {
                errnoEnforce(errno == EINTR, "send() failed");
            }
        }
    }

    @notrace void sendObj(T)(auto ref const T obj, Timeout timeout = Timeout.infinite) {
        this.send((cast(const(ubyte)*)&obj)[0 .. T.sizeof], timeout);
    }

    @notrace size_t recvVec(void[][] vec, bool eager = true, Timeout timeout = Timeout.infinite) {
        import core.sys.posix.sys.uio;
        auto ivec = cast(iovec[])vec;

        return 0;
    }
    @notrace void sendVec(void[][] vec, Timeout timeout = Timeout.infinite) {
    }
}


struct DatagramSocket {
    mixin TransportBase;

    static DatagramSocket open(SockAddr sa, bool allowBroadcast=false) {
        int fd = socket(sa.family, SOCK_DGRAM, IPPROTO_UDP);
        errnoEnforce(fd > 0, "socket() failed");
        scope(failure) unistd.close(fd);

        uint val = 1;
        errnoEnforce(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, val.sizeof) == 0, "setsockopt(SO_REUSEADDR) failed");
        errnoEnforce(.bind(fd, sa.asSockaddr, sa.length) == 0, "bind() failed");
        if (allowBroadcast) {
            int flag = 1;
            errnoEnforce(setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &flag, flag.sizeof) == 0, "setsockopt(SO_BROADCAST) failed");
        }
        return DatagramSocket(fd);
    }

    @notrace size_t sendTo(const ref SockAddr dest, const(void)[] buf, Timeout timeout = Timeout.infinite) {
        assert(false);
    }
    @notrace void[] recvFrom(out SockAddr src, void[] buf, Timeout timeout = Timeout.infinite) {
        assert(false);
    }
}

struct FileTransport {
    import core.stdc.stdio: SEEK_SET, SEEK_CUR, SEEK_END;
    enum defaultMode = unistat.S_IWUSR | unistat.S_IRUSR | unistat.S_IRGRP  | unistat.S_IROTH;  // 0o644
    mixin TransportBase;

    static FileTransport open(string filename, int flags, int mode = defaultMode) {
        int fd = fcntl.open(filename.toStringz, flags, mode);
        errnoEnforce(fd >= 0, "open(%s) failed".format(filename));
        return FileTransport(fd);
    }
    static FileTransport open(string flags)(string filename) {
        int _flags;
        static if (flags == "r") {_flags = fcntl.O_RDONLY;}
        else static if (flags == "r+") {_flags = fcntl.O_RDWR | fcntl.O_CREAT;}
        else static if (flags == "w") {_flags = fcntl.O_WRONLY | fcntl.O_CREAT | fcntl.O_TRUNC;}
        else static if (flags == "w+") {_flags = fcntl.O_RDWR | fcntl.O_CREAT | fcntl.O_TRUNC;}
        else static if (flags == "a") {_flags = fcntl.O_WRONLY | fcntl.O_CREAT | fcntl.O_APPEND;}
        else static if (flags == "a+") {_flags = fcntl.O_RDWR | fcntl.O_CREAT | fcntl.O_APPEND;}
        else {static assert (false, "Invalid flags: " ~ flags);}
        return open(filename, _flags);
    }

    @notrace off_t seek(off_t offset, int whence=SEEK_SET) {
        assert (!closed);
        auto newoff = unistd.lseek(handle.fd, offset, whence);
        errnoEnforce(newoff != cast(off_t)-1, "lseek");
        return newoff;
    }
    @property off_t tell() {
        return seek(0, SEEK_CUR);
    }
    void truncate(off_t length) {
        assert (!closed);
        errnoEnforce(unistd.ftruncate(handle.fd, length) == 0, "ftruncate failed");
    }
    @notrace unistat.stat_t stat() {
        assert (!closed);
        unistat.stat_t res;
        errnoEnforce(unistat.fstat(handle.fd, &res) == 0, "fstat failed");
        return res;
    }
    @notrace void sync() {
        assert (!closed);
        errnoEnforce(unistd.fsync(handle.fd) == 0, "fsync failed");
    }

    @notrace void[] read(void[] buf, Timeout timeout = Timeout.infinite) {
        // Files are always "readable", cannot suspend on epoll here
        auto res = unistd.read(handle.fd, buf.ptr, buf.length);
        errnoEnforce(res >= 0, "read failed");
        return buf[0 .. res];
    }
    @notrace void write(const(void)[] buf, Timeout timeout = Timeout.infinite) {
        // Files are always "writable", cannot suspend on epoll here
        while (buf.length > 0) {
            auto res = unistd.write(handle.fd, buf.ptr, buf.length);
            errnoEnforce(res >= 0, "read failed");
            buf = buf[res .. $];
        }
    }
}

private extern(C) @system @nogc nothrow {
    alias eventfd_t = uint64_t;

    enum {
        EFD_SEMAPHORE = 0x00001,
        EFD_CLOEXEC   = 0x80000,
        EFD_NONBLOCK  = 0x00800,
    }

    int eventfd(int count, int flags);
}

struct WakeupTransport {
    mixin TransportBase;

    static WakeupTransport open() {
        int fd = .eventfd(0, EFD_CLOEXEC);
        errnoEnforce(fd >= 0, "eventfd() failed");
        return WakeupTransport(fd);
    }

    //
    // this function is thread-safe: any thread can signal this, and it will wake the fiber currently waiting on it.
    // internally, it increments a kernel-held counter which can be retrieved by wait().
    // returns true on success, false on failure and logs the reason
    //
    @notrace bool signal() @nogc nothrow {
        if (handle.fd < 0) {
            //ERROR!"WakeupTransport.signal on closed fd"();
            return false;
        }
        eventfd_t value = 1;
        auto res = unistd.write(handle.fd, &value, value.sizeof);
        if (res != value.sizeof) {
            ERROR!"WakeupTransport.signal: write failed, res=%s errno=%s"(res, errno);
            return false;
        }
        return true;
    }

    //
    // this function blocks the calling fiber until the FD has been signaled. MUST BE CALLED FROM MAIN THREAD.
    // returns the counter's value at the time of reading it, and (atomically) resets it to zero.
    //
    @notrace size_t wait(Timeout timeout = Timeout.infinite) {
        assert (!closed >= 0, "EventFD is closed");
        assert (theReactor.isCalledFromFiber, "must be called from a fiber");

        eventfd_t value;
        while (true) {
            auto res = unistd.read(handle.fd, &value, value.sizeof);
            if (res >= 0) {
                errnoEnforce(res == value.sizeof, "read(eventfd) failed (res=%s)".format(res));
                handle.clearRead();
                return value;
            }
            else if (errno == EAGAIN) {
                handle.clearRead();
                handle.suspendFiber(timeout);
            }
            else {
                errnoEnforce(errno == EINTR, "read(eventfd) failed (res=%s)".format(res));
            }
        }
    }
}

struct MultiTransport(T) {
    LinkedSet!(EpollHandle*) pending;
    LinkedSet!(EpollHandle*) ready;
    Suspender suspender;

    @notrace void addRead(T transport) {
        addRead(transport.handle);
    }
    @notrace void addRead(EpollHandle handle) {
        if (handle.canRead) {
            ready.append(handle);
            handle.clearCallback();
        }
        else {
            pending.append(handle);
            handle.setCallback(&_becomeReady);
        }
    }

    void remove(EpollHandle handle) {
        pending.remove(handle);
        ready.remove(handle);
        handle.clearCallback();
    }

    @notrace private void _becomeReady(EpollHandle handle) {
        if (handle in pending) {
            pending.remove(handle);
            ready.append(handle);
        }
        else {
            assert (handle in ready);
        }
    }

    @notrace EpollHandle pop(Timeout timeout = Timeout.infinite) {
        if (ready.empty) {
            suspender.wait(timeout);
        }
        handle = ready.popHead();
        assert (handle !is null && handle.canRead());
        handle.clearCallback();
        return handle;
    }
}








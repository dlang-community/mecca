/// Reactor friendly interface for Linux's inotify
module mecca.reactor.io.inotify;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux):

import core.sys.linux.sys.inotify;

import mecca.lib.exception;
import mecca.lib.string;
import mecca.lib.typedid;
import mecca.log;
import mecca.reactor.io.fd;
import mecca.reactor;

private extern(C) nothrow @nogc {
    int inotify_init1(int flags) @safe;
    //int inotify_add_watch(int fd, const(char)* name, uint mask);
    //int inotify_rm_watch(int fd, uint wd) @safe;

    enum NAME_MAX = 255;
}

/// Watch point handle type
alias WatchDescriptor = TypedIdentifier!("WatchDescriptor", int, -1, -1);

/**
 * iNotify type.
 *
 * Create as many instances of this as you need. Each one has its own inotify file descriptor, and manages its own events
 */
struct Inotifier {
    /**
     * The type of reported events
     *
     * Full documentation is available in the <a href="https://linux.die.net/man/7/inotify">inotify man page</a>, except for the name
     * field, which returns a D string.
     */
    struct Event {
        @disable this(this);

        inotify_event event;
        @property WatchDescriptor wd() const pure nothrow @safe @nogc {
            return WatchDescriptor( event.wd );
        }

        @property string name() const nothrow @trusted @nogc {
            if( event.len==0 )
                return null;

            import std.string : indexOf;

            const char* basePtr = event.name.ptr;
            string ret = cast(immutable(char)[])basePtr[0 .. event.len];
            auto nullIdx = indexOf( ret, '\0' );
            ASSERT!"Name returned from inotify not null terminated"( nullIdx>=0 );
            return ret[0..nullIdx];
        }

        alias event this;
    }

    enum IN_ACCESS = .IN_ACCESS; /// See definition in the <a href="https://linux.die.net/man/7/inotify">inotify man page</a>.
    enum IN_MODIFY = .IN_MODIFY; /// ditto
    enum IN_ATTRIB = .IN_ATTRIB; /// ditto
    enum IN_CLOSE_WRITE = .IN_CLOSE_WRITE; /// ditto
    enum IN_CLOSE_NOWRITE = .IN_CLOSE_NOWRITE; /// ditto
    enum IN_OPEN = .IN_OPEN; /// ditto
    enum IN_MOVED_FROM = .IN_MOVED_FROM; /// ditto
    enum IN_MOVED_TO = .IN_MOVED_TO; /// ditto
    enum IN_CREATE = .IN_CREATE; /// ditto
    enum IN_DELETE = .IN_DELETE; /// ditto
    enum IN_DELETE_SELF = .IN_DELETE_SELF; /// ditto
    enum IN_MOVE_SELF = .IN_MOVE_SELF; /// ditto
    //enum IN_UNMOUNT = .IN_UNMOUNT; /// ditto
    enum IN_Q_OVERFLOW = .IN_Q_OVERFLOW; /// ditto
    enum IN_IGNORED = .IN_IGNORED; /// ditto
    enum IN_CLOSE = .IN_CLOSE; /// ditto
    enum IN_MOVE = .IN_MOVE; /// ditto
    enum IN_ONLYDIR = .IN_ONLYDIR; /// ditto
    enum IN_DONT_FOLLOW = .IN_DONT_FOLLOW; /// ditto
    enum IN_EXCL_UNLINK = .IN_EXCL_UNLINK; /// ditto
    enum IN_MASK_ADD = .IN_MASK_ADD; /// ditto
    enum IN_ISDIR = .IN_ISDIR; /// ditto
    enum IN_ONESHOT = .IN_ONESHOT; /// ditto
    enum IN_ALL_EVENTS = .IN_ALL_EVENTS; /// ditto
private:
    ReactorFD fd;

    enum EVENTS_BUFFER_SIZE = 512;

    // Cache for already extracted events
    static assert( EVENTS_BUFFER_SIZE >= inotify_event.sizeof + NAME_MAX + 1, "events buffer not big enough for one event" );
    void[EVENTS_BUFFER_SIZE] eventsBuffer;
    uint bufferSize;
    uint bufferConsumed;

public:
    /// call before using the inotifyer
    void open() @safe @nogc {
        ASSERT!"Inotifier.open called twice"( !fd.isValid );
        int inotifyFd = inotify_init1(IN_NONBLOCK|IN_CLOEXEC);
        errnoEnforceNGC( inotifyFd>=0, "inotify_init failed" );
        fd = ReactorFD( inotifyFd, true );
    }

    ~this() nothrow @safe @nogc {
        close();
    }

    /// call when you're done with the inotifyer
    void close() nothrow @safe @nogc {
        fd.close();
    }

    /// Report whether Inotifier is open
    bool isOpen() const nothrow @safe @nogc {
        return fd.isValid;
    }

    /**
     * add or change a watch point
     *
     * Params:
     * path = path to be watched
     * mask = the mask of events to be watched
     *
     * Returns:
     * the WatchDescriptor of the added or modified watch point.
     */
    WatchDescriptor watch( const(char)[] path, uint mask ) @trusted @nogc {
        auto wd = WatchDescriptor( fd.osCallErrno!(.inotify_add_watch)(ToStringz!(NAME_MAX+1)(path), mask) );

        return wd;
    }

    /**
     * remove a previously registered watch point
     *
     * Params:
     * wd = the WatchDescriptor returned by watch
     */
    void removeWatch( WatchDescriptor wd ) @trusted @nogc {
        fd.osCallErrno!(.inotify_rm_watch)( wd.value );
    }

    /**
     * get one pending inotify event
     *
     * This function may sleep.
     *
     * Returns:
     * A pointer to a const Event. This pointer remains valid until the next call to `getEvent` or `consumeAllEvents`.
     *
     * Bugs:
     * Only one fiber at a time may use this function
     */
    const(Event)* getEvent() @trusted @nogc {
        if( bufferSize==bufferConsumed ) {
            bufferConsumed = bufferSize = 0;

            bufferSize = cast(uint) fd.read( eventsBuffer );
        }

        assertGT( bufferSize, bufferConsumed, "getEvent with no events" );
        assertGE( bufferConsumed - bufferSize, inotify_event.sizeof, "events buffer with partial event" );

        const(Event)* ret = cast(Event*)(&eventsBuffer[bufferConsumed]);
        bufferConsumed += inotify_event.sizeof + ret.len;

        return ret;
    }

    /**
     * Discard all pending events.
     *
     * This function discards all pending events, both from the memory cache and from the OS. All events in the inotify fd are discarded,
     * regardless of which watch descriptor they belong to.
     *
     * This function does not sleep.
     */
    void consumeAllEvents() @trusted @nogc {
        with( theReactor.criticalSection ) {
            // Clear the memory cache
            bufferConsumed = bufferSize = 0;

            bool moreEvents = true;
            do {
                import core.sys.posix.unistd : read;
                import core.stdc.errno;

                auto size = fd.osCall!(read)(eventsBuffer.ptr, eventsBuffer.length);
                if( size<0 ) {
                    errnoEnforceNGC( errno==EAGAIN || errno==EWOULDBLOCK, "inotify read failed" );
                    moreEvents = false;
                }
            } while( moreEvents );
        }
    }
}

unittest {
    void watcher(string path) {
        Inotifier inote;
        inote.open();

        auto wd = inote.watch(path, IN_MODIFY|IN_ATTRIB|IN_CREATE|IN_DELETE|IN_MOVED_FROM|IN_MOVED_TO|IN_ONLYDIR);
        DEBUG!"watch registration returned %s"(wd);

        while( true ) {
            auto event = inote.getEvent();
            INFO!"handle %s mask %x cookie %s len %s name %s"( event.wd, event.mask, event.cookie, event.len, event.name );
        }
    }

    void testBody() {
        import core.sys.posix.stdlib;
        import std.string;
        import std.file;
        import std.process;
        import std.exception;

        import mecca.lib.time;

        string iPath = format("%s/meccaUT-XXXXXX\0", tempDir());
        char[] path;
        path.length = iPath.length;
        path[] = iPath[];
        errnoEnforce( mkdtemp(path.ptr) !is null );
        scope(exit) execute( ["rm", "-rf", path] );

        iPath.length = 0;
        iPath ~= path[0..$-1];
        DEBUG!"Using directory %s for inotify tests"( iPath );

        theReactor.spawnFiber( &watcher, iPath );

        theReactor.yield();

        execute( ["touch", iPath ~ "/file1"] );
        rename( iPath ~ "/file1", iPath ~ "/file2" );

        theReactor.sleep(1.msecs);
    }

    testWithReactor(&testBody);
}

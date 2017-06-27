module mecca.reactor.fd;

import std.conv;
import std.exception;

import unistd = core.sys.posix.unistd;
import core.sys.linux.epoll;

import mecca.reactor.reactor;
import mecca.lib.time;
import mecca.log;

struct FD {
private:
    int fd = -1;

public:
    static void openReactor() {
        epoller.open();
    }

    static void closeReactor() {
        epoller.close();
    }

    @disable this(this);

    ~this() {
        close();
    }

    void close() {
        if( fd>=0 ) {
            int res = unistd.close(fd);
            fd = -1;

            /+
            if( res<0 )
                throw new errnoException;
            +/
        }
    }
}

private:

struct Epoll {
private: // Not that this does anything, as the struct itself is only visible to this file.
    int fd = -1;

    enum MIN_DURATION = dur!"msecs"(1);
    enum NUM_BATCH_EVENTS = 32;

public:

    void open() {
        assert(theReactor.isOpen, "Must call theReactor.setup before calling FD.openReactor");
        fd = epoll_create1(0);
        errnoEnforce( fd>=0, "Failed to create epoll fd" );

        theReactor.registerIdleCallback(&reactorIdle);
    }

    void close() {
        assert(false, "TODO: implement");
    }

private:
    void reactorIdle(Duration timeout) {
        DEBUG!"Calling epoll_wait with a timeout of %s"(timeout);

        epoll_event[NUM_BATCH_EVENTS] events;
        if( timeout > Duration.zero && timeout < MIN_DURATION )
            timeout = MIN_DURATION;
        int res = epoll_wait(fd, events.ptr, NUM_BATCH_EVENTS, to!int(timeout.total!"msecs"));
        errnoEnforce( res>=0, "epoll_wait failed" );
    }
}

Epoll epoller;

unittest {
    theReactor.setup();
    scope(exit) theReactor.teardown();

    FD.openReactor();

    theReactor.start();
}

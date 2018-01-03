/// File descriptor management
module mecca.lib.io;

import core.sys.posix.unistd;
import std.traits;

import mecca.lib.exception;

/**
 * File descriptor wrapper
 *
 * This wrapper's main purpose is to protect the fd against leakage. It does not actually $(I do) anything.
 */
struct FD {
private:
    enum InvalidFd = -1;
    int fd = InvalidFd;

public:
    @disable this(this);

    /**
     * Initialize from an OS file descriptor.
     *
     * Params:
     *  fd = OS handle of file to wrap.
     */
    this(int fd) nothrow @safe @nogc {
        ASSERT!"FD initialized with an invalid FD %s"(fd>=0, fd);
        this.fd = fd;
    }

    ~this() nothrow @safe @nogc {
        close();
    }

    /**
     * Wrapper for adopting an fd immediately after being returned from external function
     *
     * The usage should be `FD fd = FD.adopt!"open"( .open("/path/to/file", O_RDWR) );`
     *
     * Throws:
     * ErrnoException in case fd is invalid
     */
    static FD adopt(string errorMsg)(int fd) @safe @nogc {
        errnoEnforceNGC(fd>=0, errorMsg);
        return FD(fd);
    }

    /**
     * Call an OS function that accepts an FD as the first argument.
     *
     * Parameters:
     * The parameters are the arguments that OS function accepts without the first one (the file descriptor).
     *
     * Returns:
     * Whatever the original OS function returns.
     */
    auto osCall(alias F, T...)(T args) nothrow @nogc if( is( Parameters!F[0]==int ) ) {
        import mecca.lib.reflection : as;

        static assert( fullyQualifiedName!F != fullyQualifiedName!(.close),
                "Do not try to close the fd directly. Use FD.close instead." );
        ReturnType!F res;
        as!"nothrow @nogc"({ res = F(fd, args); });

        return res;
    }

    /**
     * Run an fd based function and throw if it fails
     *
     * This function behave the same as `osCall`, except if the return is -1, it will throw an ErrnoException
     */
    auto checkedCall(alias F, string errorMessage, T...)(T args) @system @nogc
            if( is( Parameters!F[0]==int ) )
    {
        auto ret = osCall!F(args);

        errnoEnforceNGC(ret!=-1, errorMessage);

        return ret;
    }

    /**
     * Close the OS handle prematurely.
     *
     * Closes the OS handle. This happens automatically on struct destruction. It is only necessary to call this method if you wish to close
     * the underlying FD before the struct goes out of scope.
     *
     * Throws:
     * Nothing. There is nothing useful to do if close fails.
     */
    void close() nothrow @safe @nogc {
        if( fd != InvalidFd ) {
            .close(fd);
        }

        fd = InvalidFd;
    }

    /**
      * Obtain the underlying OS handle
      *
      * This returns the underlying OS handle for use directly with OS calls.
      *
      * Warning:
      * Do not use this function to directly call the close system call. Doing so may lead to quite difficult to debug problems across your
      * program. If another part of the program gets the same FD number, it can be quite difficult to find out what went wrong.
      */
    @property int fileNo() pure nothrow @safe @nogc {
        return fd;
    }

    /**
     * Report whether the FD currently holds a valid fd
     *
     * Additional_Details:
     * Hold stick near centre of its length. Moisten pointed end in mouth. Insert in tooth space, blunt end next to gum. Use gentle in-out
     * motion.
     *
     * See_Also:
     * <a href="http://hitchhikers.wikia.com/wiki/Wonko_the_Sane">Wonko the sane</a>
     *
     * Returns: true if valid
     */
    @property bool isValid() pure const nothrow @safe @nogc {
        return fd != InvalidFd;
    }

    /** Duplicate an FD
     *
     * Does the same as the `dup` system call.
     *
     * Returns:
     * An FD representing a duplicate of the current FD.
     */
    FD dup() @trusted @nogc {
        import fcntl = core.sys.posix.fcntl;
        static if( __traits(compiles, fcntl.F_DUPFD_CLOEXEC) ) {
            enum F_DUPFD_CLOEXEC = fcntl.F_DUPFD_CLOEXEC;
        } else {
            version(linux) {
                enum F_DUPFD_CLOEXEC = 1030;
            }
        }

        int newFd = osCall!(fcntl.fcntl)( F_DUPFD_CLOEXEC, 0 );
        errnoEnforceNGC(newFd!=-1, "Failed to duplicate FD");
        return FD( newFd );
    }
}

unittest {
    import core.stdc.errno;
    import core.sys.posix.fcntl;
    import std.conv;

    int fd1copy, fd2copy;

    {
        auto fd = FD.adopt!"open"(open("/tmp/meccaUTfile1", O_CREAT|O_RDWR|O_TRUNC, octal!666));
        fd1copy = fd.fileNo;

        fd.osCall!write("Hello, world\n".ptr, 13);
        // The following line should not compile:
        // fd.osCall!(.close)();

        unlink("/tmp/meccaUTfile1");

        fd = FD.adopt!"open"( open("/tmp/meccaUTfile2", O_CREAT|O_RDWR|O_TRUNC, octal!666) );
        fd2copy = fd.fileNo;

        unlink("/tmp/meccaUTfile2");
    }

    assert( .close(fd1copy)<0 && errno==EBADF, "FD1 was not closed" );
    assert( .close(fd2copy)<0 && errno==EBADF, "FD2 was not closed" );
}

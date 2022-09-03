/// File descriptor management
module mecca.lib.io;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.stdc.errno;
import core.sys.posix.unistd;
public import core.sys.posix.fcntl :
    O_ACCMODE, O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_EXCL, O_TRUNC, O_APPEND, O_SYNC, O_NOCTTY;
    /* O_NOATIME, O_NOFOLLOW not included because not defined */
import core.sys.posix.fcntl;
import std.algorithm : min, move;
import std.conv;
import std.traits;

import mecca.lib.exception;
import mecca.lib.memory;
import mecca.lib.string;
import mecca.log;
import mecca.platform.x86;
import mecca.platform.os : EREMOTEIO, O_CLOEXEC;

/// Exception thrown if a read/recv receives partial data
///
/// `ErrnoException.errno` will report `EREMOTEIO`.
class ShortRead : ErrnoException {
    this(string msg, string file = __FILE_FULL_PATH__, size_t line = __LINE__) @trusted {
        super(msg, EREMOTEIO, file, line);
    }
}

unittest {
    auto except = new ShortRead("Message");
    assert(except.errno == EREMOTEIO);
}

private extern(C) nothrow @trusted @nogc {
    int pipe2(ref int[2], int flags);
}

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

    /**
     * Open a new file.
     *
     * Parameters:
     * Same as for the `open`(2) command;
     */
    this(string path, int flags, mode_t mode = octal!666) @trusted @nogc {
        fd = .open(path.toStringzNGC, flags | O_CLOEXEC, mode);
        errnoEnforceNGC(fd>=0, "File open failed");
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
    @notrace static FD adopt(string errorMsg)(int fd) @safe @nogc {
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
        // We're using T... rather than Parameters!F because the later does not handle variadic functions very well.
        // XXX Consider having two versions of this function
        import mecca.lib.reflection : as;

        static assert( fullyQualifiedName!F != fullyQualifiedName!(.close),
                "Do not try to close the fd directly. Use FD.close instead." );
        ReturnType!F res;
        as!"nothrow @nogc"({ res = F(fd, args); });

        return res;
    }

    /// @safe read
    auto read(void[] buffer) @trusted @nogc {
        return checkedCall!(core.sys.posix.unistd.read)(buffer.ptr, buffer.length, "read failed");
    }

    /// @safe write
    auto write(const void[] buffer) @trusted @nogc {
        return checkedCall!(core.sys.posix.unistd.write)(buffer.ptr, buffer.length, "write failed");
    }

    /**
     * Run an fd based function and throw if it fails
     *
     * This function behave the same as `osCall`, except if the return is -1, it will throw an ErrnoException
     */
    auto checkedCall(alias F, T...)(T args, string errorMessage) @system @nogc
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
    int close() nothrow @safe @nogc {
        int ret = -1;
        if( fd != InvalidFd ) {
            ret = .close(fd);
        }

        fd = InvalidFd;
        return ret;
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
    @notrace FD dup() @trusted @nogc {
        import core.sys.posix.fcntl : fcntl;
        import mecca.platform.os : F_DUPFD_CLOEXEC;

        int newFd = osCall!(fcntl)( F_DUPFD_CLOEXEC, 0 );
        errnoEnforceNGC(newFd!=-1, "Failed to duplicate FD");
        return FD( newFd );
    }
}

/**
 * create an unnamed pipe pair
 *
 * Params:
 *  readEnd = `FD` struct to receive the reading (output) end of the pipe
 *  writeEnd = `FD` struct to receive the writing (input) end of the pipe
 */
void createPipe(out FD readEnd, out FD writeEnd) @trusted @nogc {
    int[2] pipeRawFD;

    errnoEnforceNGC( pipe2(pipeRawFD, O_CLOEXEC )>=0, "OS pipe creation failed" );

    readEnd = FD( pipeRawFD[0] );
    writeEnd = FD( pipeRawFD[1] );
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

/// A wrapper to perform buffered IO over another IO type
struct BufferedIO(T) {
    enum MIN_BUFF_SIZE = 128;

private:
    MmapArray!ubyte rawMemory;
    void[] readBuffer, writeBuffer;
    size_t readBufferSize;
    public T fd; // Declared public so it is visible through alias this

public:
    // BufferedIO is not copyable even if T is copyable (which it typically won't be)
    @disable this(this);

    /** Construct an initialized buffered IO object
     *
     * `fd` is the FD object to wrap. Other arguments are the same as for the `open` call.
     */
    this(T fd, size_t bufferSize) {
        this.open(bufferSize);
        this.fd = move(fd);
    }

    this(T fd, size_t readBufferSize, size_t writeBufferSize) {
        this.open(readBufferSize, writeBufferSize);
        this.fd = move(fd);
    }

    /// Struct destructor
    ///
    /// Warning:
    /// $(B The destructor does not flush outstanding writes). This is because it might be called from an exception
    /// context where such flushes are not possible. Adding `scope(success) io.flush();` is recommended.
    ~this() @safe @nogc {
        closeNoFlush();
        // No point in closing the underlying FD. Its own destructor should do that.
    }

    /**
     * Prepare the buffers.
     *
     * The first form sets the same buffer size for both read and write operations. The second sets the read and write
     * buffer sizes independently.
     */
    void open(size_t bufferSize) @safe @nogc {
        open( bufferSize, bufferSize );
    }

    /// ditto
    void open(size_t readBufferSize, size_t writeBufferSize) @safe @nogc {
        ASSERT!"BufferedIO.open called twice"( rawMemory.closed );
        assertGE( readBufferSize, MIN_BUFF_SIZE, "readBufferSize not big enough" );
        assertGE( writeBufferSize, MIN_BUFF_SIZE, "writeBufferSize not big enough" );

        // Round readBufferSize to a multiple of the cacheline size, so that the write buffer be cache aligned
        readBufferSize += CACHE_LINE_SIZE-1;
        readBufferSize -= readBufferSize % CACHE_LINE_SIZE;

        size_t total = readBufferSize + writeBufferSize;

        // Round size up to next page
        total += SYS_PAGE_SIZE - 1;
        total -= total % SYS_PAGE_SIZE;

        rawMemory.allocate( total, false ); // We do NOT want the GC to scan this area
        size_t added = total - readBufferSize - writeBufferSize;
        added /= 2;
        added -= added % CACHE_LINE_SIZE;
        this.readBufferSize = readBufferSize + added;

        readBuffer = null;
        writeBuffer = null;
    }

    /** Close the buffered IO
     *
     * This flushes all outstanding writes, closes the underlying FD and releases the buffers.
     */
    void close() @notrace {
        flush();
        closeNoFlush();
        fd.close();
    }

    /** Forget all pending writes
     *
     * This causes the `BufferedIO` to discard all unflushed write data. Cached read data is unaffected.
     */
    void reset() @safe @nogc nothrow pure {
        writeBuffer = null;
    }

    /// Perform @safe buffered read
    ///
    /// Notice that if there is data already in the buffers, that data is what will be returned, even if the read
    /// requested more (partial result).
    auto read(ARGS...)(void[] buffer, ARGS args) @trusted @nogc {
        size_t cachedLength = min(buffer.length, readBuffer.length);
        if( cachedLength>0 ) {
            // Data already in buffer
            buffer[0..cachedLength][] = readBuffer[0..cachedLength][];
            readBuffer = readBuffer[cachedLength..$];

            return cachedLength;
        }

        cachedLength = fd.read(rawReadBuffer, args);
        readBuffer = rawReadBuffer[0..cachedLength];

        if( cachedLength==0 )
            return 0;

        // Call ourselves again. Since the buffer is now not empty, the call should succeed without performing the
        // actual underlying read again.
        return read(buffer, args);
    }

    /** Read a single line
     *
     * Reads a single line from the buffered IO. The line must fit the struct's allocated read buffer.
     *
     * returns:
     * The function returns a `const(char)[]` that points to the file's read buffer. This means that no copy is done
     * (the data is read directly to its final resting place), but it also means that the data might disappear if
     * further read operations are done on the file.
     *
     * Upon successful read, the returned range contains the terminating character as its last element. See Notes below
     * for discussion on partial lines.
     *
     * In case of end of file, the function returns a slice of length 0.
     *
     * params:
     * terminator = the line terminator to look for.
     * partialOk = whether it is okay for the line to be partial. Defaults to `false`.
     * args = the arguments for the underlying FD, if any. Can be used to pass `Timeout` to a `ReactorFD`.
     *
     * Notes:
     * A partial line might happen in one of two cases. Either the line width is longer than the entire read buffer
     * (as set when calling `open` or during construction), or the file sends an EOF without terminating the last line.
     *
     * What happens in that case depends on whether `partialOk` is set. If it is, the buffer is returned with no
     * terminator as the last character. If `partialOk` is clear (the default) then the call throws a `ShortRead`
     * exception.
     */
    const(char)[] readLine(char terminator = '\n') @trusted @nogc {
        return readLine(terminator, false);
    }

    const(char)[] readLine(ARGS...)(char terminator, bool partialOk, ARGS args) @trusted @nogc {
        size_t readLineFromBuffer(size_t start, char terminator) @trusted @nogc nothrow {
            const(char)[] convertedBuffer = cast(const(char)[])readBuffer;

            // Can't use std.algorithm.searching.find, as it's a GC function. Of course, the only reason it allocates is
            // because it needs to throw range.empty if not found. Since we would then have to also catch that exception,
            // using it quickly spirals out of control.
            //
            // Instead, we're going to spend the 4 lines it takes to roll our own :-(
            foreach(i; start..readBuffer.length) {
                if( convertedBuffer[i]==terminator ) {
                    return i+1;
                }
            }

            return 0;
        }

        // Fast path - the entire line is already present in the buffer
        size_t intermediateLength = readLineFromBuffer(0, terminator);
        if( intermediateLength!=0 ) {
            const(char)[] result = cast(const(char)[])readBuffer[0..intermediateLength];
            readBuffer = readBuffer[intermediateLength..$];

            return result;
        }

        // Move the buffer we already have to the beginning of the memory, to maximize the efficiency of the next read
        if( readBuffer.ptr!=rawReadBuffer.ptr ) {
            // No point in moving memory if it's already at the beginning
            foreach(i; 0..readBuffer.length) {
                // Can't use array operations because the ranges might overlap
                (cast(char[])rawReadBuffer)[i] = (cast(const(char)[])readBuffer)[i];
            }

            readBuffer = rawReadBuffer[0..readBuffer.length];
        }

        const(char)[] partialResult() {
            if( partialOk ) {
                const(char)[] result = (cast(const(char)[])readBuffer);
                readBuffer = null;

                return result;
            } else {
                throw mkExFmt!ShortRead("readline unable to find terminator in %s bytes", readBuffer.length);
            }
        }

        intermediateLength = readBuffer.length;
        size_t numRead;
        size_t terminatorLocation;
        do {
            intermediateLength += numRead;
            if( readBuffer.length==readBufferSize ) {
                return partialResult(); // No more room to expand
            }

            numRead = fd.read(rawReadBuffer[intermediateLength..$], args);
            if( numRead==0 )
                return partialResult(); // EOF

            readBuffer = rawReadBuffer[0..intermediateLength + numRead];
        } while( (terminatorLocation = readLineFromBuffer(intermediateLength, terminator))==0 );

        DBG_ASSERT!"Terminator not found in successful loop completion: loc %s str \"%s\""(
                (cast(const(char)[])readBuffer)[terminatorLocation-1]==terminator, terminatorLocation,
                (cast(const(char)[])readBuffer)[0..terminatorLocation]);
        auto result = (cast(const(char)[])readBuffer)[0..terminatorLocation];
        readBuffer = readBuffer[terminatorLocation..$];

        return result;
    }

    /// Perform @safe buffered write
    ///
    /// Function does not return until all data is either written to FD or buffered
    void write(ARGS...)(const(void)[] buffer, ARGS args) @trusted @nogc {
        if( buffer.length>rawWriteBuffer.length ) {
            // Buffer is big - write it directly to save on copies
            flush(args);
            DBG_ASSERT!"write buffer is not empty after flush"(writeBuffer.length == 0);
            while( buffer.length>0 ) {
                auto numWritten = fd.write(buffer, args);
                buffer = buffer[numWritten..$];
            }

            return;
        }

        while( buffer.length>0 ) {
            size_t start = writeBuffer.length;
            size_t writeSize = rawWriteBuffer.length - start;
            writeSize = min(writeSize, buffer.length);

            writeBuffer = rawWriteBuffer[0 .. start+writeSize];
            writeBuffer[start..$][] = buffer[0..writeSize][];

            buffer = buffer[writeSize..$];

            if( writeBuffer.length==rawWriteBuffer.length )
                flush(args);
        }
    }

    /// Flush the write buffers
    void flush(ARGS...)(ARGS args) @trusted @nogc {
        scope(failure) {
            /* In case of mid-op failure, writeBuffer might end up not at the start of rawBuffer, which violates
             * invariants assumed elsewhere in the code.
             */
            auto len = writeBuffer.length;
            // Source and destination buffers may overlap, so we cannot use slice operation for the copy
            foreach( i, d; cast(ubyte[])writeBuffer )
                (cast(ubyte[])rawWriteBuffer)[i] = d;
            writeBuffer = rawWriteBuffer[0..len];
        }

        while( writeBuffer.length>0 ) {
            auto numWritten = fd.write(writeBuffer, args);
            writeBuffer = writeBuffer[numWritten..$];
        }
    }

    /** Attach an underlying FD to the buffered IO instance
     *
     * Instance must be open and not already attached
     */
    ref BufferedIO opAssign(T fd) {
        ASSERT!"Attaching fd to an open buffered IO"(!this.fd.isValid);
        ASSERT!"Trying to attach an fd to a closed BufferedIO"( !rawMemory.closed );
        move(fd, this.fd);

        return this;
    }

    alias fd this;
private:
    size_t writeBufferSize() const pure nothrow @safe @nogc {
        return rawMemory.length - readBufferSize;
    }

    @property void[] rawReadBuffer() pure nothrow @safe @nogc {
        DBG_ASSERT!"Did not call open"(readBufferSize!=0);
        DBG_ASSERT!"readBufferSize greater than total raw memory. %s<%s"(
                readBufferSize<rawMemory.length, readBufferSize, rawMemory.length );
        return rawMemory[0..readBufferSize];
    }
    @property void[] rawWriteBuffer() pure nothrow @safe @nogc {
        DBG_ASSERT!"readBufferSize greater than total raw memory. %s<%s"(
                readBufferSize<rawMemory.length, readBufferSize, rawMemory.length );
        return rawMemory[readBufferSize..$];
    }

    @notrace void closeNoFlush() @safe @nogc {
        if( writeBuffer.length!=0 ) {
            ERROR!"Closing BufferedIO while it still has unflushed data to write"();
        }
        rawMemory.free();
        readBufferSize = 0;
        readBuffer = null;
        writeBuffer = null;
    }
}

unittest {
    enum TestSize = 32000;
    enum ReadBuffSize = 2000;
    enum WriteBuffSize = 2000;

    ubyte[] reference;
    uint numReads, numWrites;

    struct MockFD {
        uint readOffset, writeOffset;
        bool opened = true;

        ssize_t read(void[] buffer) @nogc {
            auto len = min(buffer.length, reference.length - readOffset);
            buffer[0..len] = reference[readOffset..readOffset+len][];
            readOffset += len;
            if( len>0 )
                numReads++;

            return len;
        }

        size_t write(const void[] buffer) @nogc {
            foreach(datum; cast(ubyte[])buffer) {
                assertEQ(datum, cast(ubyte)(reference[writeOffset]+1));
                writeOffset++;
            }

            numWrites++;

            return buffer.length;
        }

        @property bool isValid() const @nogc {
            return opened;
        }

        void close() @nogc {
            opened = false;
        }
    }

    BufferedIO!MockFD fd;

    import std.random;
    auto seed = unpredictableSeed;
    scope(failure) ERROR!"Test failed with seed %s"(seed);
    auto rand = Random(seed);

    reference.length = TestSize;
    foreach(ref d; reference) {
        d = uniform!ubyte(rand);
    }

    fd.open(ReadBuffSize, WriteBuffSize);

    ubyte[17] buffer;
    ssize_t numRead;
    size_t total;
    while( (numRead = fd.read(buffer))>0 ) {
        total+=numRead;
        buffer[0..numRead][] += 1;
        fd.write(buffer[0..numRead]);
    }

    fd.flush();

    assertEQ(total, TestSize, "Incorrect total number of bytes processed");
    assertEQ(fd.readOffset, TestSize, "Did not read correct number of bytes");
    assertEQ(fd.writeOffset, TestSize, "Did not write correct number of bytes");
    assertEQ(numReads, 16);
    assertEQ(numWrites, 16);
}

unittest {
    import mecca.lib.time;
    import mecca.reactor;
    import mecca.reactor.io.fd;
    import mecca.reactor.subsystems.poller;

    void testBody() {
        FD pipeReadFD, pipeWriteFD;
        createPipe(pipeReadFD, pipeWriteFD);

        BufferedIO!ReactorFD pipeRead = BufferedIO!ReactorFD( ReactorFD(move(pipeReadFD)), 128, 4096-128);
        ReactorFD pipeWrite = ReactorFD(move(pipeWriteFD));

        uint numLinesRead, numLinesFailed;

        auto timeout = Timeout(300.msecs);

        enum string[] expectedLines = [ "First line", "Second line", "", "Fourth line",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ~
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "aaaaaaaaaaaa", "" ];
        void reader() {
            const(char)[] line;
            int i;
            do {
                line = pipeRead.readLine('\n', true, timeout);
                if( line.length>0 && line[$-1]=='\n' ) {
                    DEBUG!"Read \"%s\" expected \"%s\""( line[0..$-1], expectedLines[i] );
                    assertEQ( expectedLines[i], line[0..$-1], ": Read the wrong data" );
                    ++i;
                    numLinesRead++;
                } else {
                    DEBUG!"Read \"%s\" expected \"%s\""( line[0..$], expectedLines[i] );
                    assertEQ( expectedLines[i], line[0..$], ": Read the wrong data" );
                    ++i;
                    numLinesFailed++;
                }
            } while(line.length>0);
        }

        theReactor.spawnFiber(&reader);

        void writeData(string data) {
            pipeWrite.write(data, timeout);
            poller.poll(); // Otherwise the other fiber won't get scheduled
            theReactor.yield();
        }

        // Write two complete lines and one incomplete one
        writeData("First line\nSecond line\n\nFour");
        assertEQ(numLinesRead, 3, "Read lines count incorrect");
        assertEQ(numLinesFailed, 0, "Failed lines count incorrect");

        writeData("th lin");
        assertEQ(numLinesRead, 3, "Read lines count incorrect");
        assertEQ(numLinesFailed, 0, "Failed lines count incorrect");

        writeData("e\n");
        assertEQ(numLinesRead, 4, "Read lines count incorrect");
        assertEQ(numLinesFailed, 0, "Failed lines count incorrect");

        writeData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); // 70 "a"s
        assertEQ(numLinesRead, 4, "Read lines count incorrect");
        assertEQ(numLinesFailed, 0, "Failed lines count incorrect");

        writeData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); // 70 more "a"s
        assertEQ(numLinesRead, 4, "Read lines count incorrect");
        assertEQ(numLinesFailed, 1, "Failed lines count incorrect");

        destroy(pipeWrite);
        poller.poll(); // Otherwise the other fiber won't get scheduled
        theReactor.yield();

        assertEQ(numLinesRead, 4, "Read lines count incorrect");
        assertEQ(numLinesFailed, 3, "Failed lines count incorrect");
    }

    testWithReactor(&testBody);
}

/// Reactor aware process management
module mecca.reactor.lib.process;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.stdc.errno;
import core.sys.posix.sys.wait;
import core.sys.posix.unistd;
import std.algorithm : move;
import std.conv : emplace;
import process = std.process;

import mecca.containers.pools;
import mecca.lib.exception;
import mecca.lib.io;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.io.fd;
import mecca.reactor.io.signals;
import mecca.reactor.sync.event;

/** Subprocess handler
 *
 * Do not create direct instances of this struct. Use `ProcessManager.alloc` instead.
 */
struct Process {
    /// The three IO streams that can be redirected
    enum StdIO {
        StdIn = 0,      /// Child's stdin stream.
        StdOut,         /// Child's stdout stream.
        StdErr          /// Child's stderr stream.
    }
private:
    pid_t _pid;
    Event processDone;
    // Child side end of standard streams
    FD[3] childStdIO;
    int exitStatus;
    version(assert) {
        bool managerInitialized;
    }

public:
    /// Parent side end of standard streams
    ReactorFD[3] stdIO;

    /** Redirect a standard IO for the child to an FD
     *
     * Params:
     * io = which of the IO streams to redirect
     * fd = An fd to be assigned. Ownership is moved to the child
     */
    void redirectIO(StdIO io, FD fd) nothrow @safe @nogc {
        verifyManagerInitialized();
        ASSERT!"Cannot set redirection on child once it has been run"(pid==0);
        stdIO[io].close();
        move(fd, childStdIO[io]);
    }

    /** Redirect a standard IO for the child to a pipe
     *
     * Redirects the child's IO to a pipe whose other side is accessible by the parent.
     * After running, the other end of the pipe will be available as `stdIO[io]`
     *
     * Params:
     * io = which of the IO streams to redirect
     */
    void redirectIO(StdIO io) @trusted @nogc {
        verifyManagerInitialized();
        ASSERT!"Cannot set redirection on child once it has been run"(pid==0);

        FD parentEnd;
        FD* writeEnd, readEnd;
        if( io==StdIO.StdIn ) {
            writeEnd = &parentEnd;
            readEnd = &childStdIO[io];
        } else {
            writeEnd = &childStdIO[io];
            readEnd = &parentEnd;
        }

        createPipe( *readEnd, *writeEnd );
        stdIO[io] = ReactorFD( move(parentEnd) );
    }

    /** Redirect stderr to stdout
     *
     * Make the child's stderr point to the same stream as its stdout
     */
    void redirectErrToOut() @safe @nogc {
        verifyManagerInitialized();
        ASSERT!"Cannot set redirection on child once it has been run"(pid==0);
        ASSERT!"Cannot redirect when stdout is not valid"(childStdIO[StdIO.StdOut].isValid);

        childStdIO[StdIO.StdErr] = childStdIO[StdIO.StdOut].dup();
        stdIO[StdIO.StdErr].close();
    }

    /// Test whether the child process is still running
    bool isRunning() const nothrow @safe @nogc {
        return !processDone.isSet;
    }

    /** Suspend fiber until the child process finishes
     *
     * Returns:
     * Return the child's return value
     */
    int wait(Timeout timeout = Timeout.infinite) @safe @nogc {
        processDone.wait(timeout);

        return exitStatus;
    }

    /** Run the child with the given arguments.
     *
     * This function returns immediately. Use `wait` if you want to wait for the child to finish execution.
     */
    void run(string[] args...) @trusted @nogc {
        verifyManagerInitialized();
        import mecca.lib.reflection : as;

        /*
           We are @nogc. @nogc states that the function will not trigger a GC before it returns.

           This function creates a child process. The parent doesn't trigger a GC. The child calls execve, and doesn't
           return.

           So we are @nogc.
         */
        ASSERT!"run must be called with at least one argument"(args.length>0);
        _pid = fork();

        if( _pid==0 ) {
            as!"@nogc"({ runChildHelper(args); });
        }

        // Cleanups
        foreach( ref fd; childStdIO ) {
            fd.close();
        }

        as!"@nogc"({ theProcessManager.processes[_pid] = &this; });

        INFO!"Launched child process %s"(pid);
    }

    /** Send the process a signal
     *
     * Params:
     * signal = Signal to send. SIGTERM by default
     */
    void kill(OSSignal signal = OSSignal.SIGTERM) @trusted @nogc {
        ASSERT!"Cannot kill process before it was started"(pid!=0);

        errnoEnforceNGC( .kill( pid, signal )==0, "Failed to send signal to process" );
    }

    /// Returns the pid of the child.
    ///
    /// Returns 0 if child has not started running
    @property pid_t pid() const pure nothrow @safe @nogc {
        return _pid;
    }

    // Do not call!!!
    void _poolElementInit() nothrow @safe @nogc {
        emplace(&this);
    }

private:
    void runChildHelper(string[] args) nothrow @trusted {
        try {
            sigset_t emptyMask;
            errnoEnforceNGC( sigprocmask( SIG_SETMASK, &emptyMask, null )==0, "sigprocmask failed" );

            // Perform IO redirection
            foreach( int ioNum, ref fd ; childStdIO ) {
                // Leave IO streams that were not redirected as they are
                if( !fd.isValid )
                    continue;

                fd.checkedCall!dup2(ioNum, "Failed to redirect IO");
            }

            process.execvp(args[0], args);
            assert(false, "Must never reach this point");
        } catch(Exception ex) {
            ERROR!"Execution of %s failed: %s"( args[0], ex.msg );
            _exit(255);
        }
    }

    void handleExit(int status) nothrow @safe {
        exitStatus = status;
        processDone.set();

        destroy( theProcessManager.processes[pid] );
    }

    void verifyManagerInitialized() pure const nothrow @safe @nogc {
        version(assert) {
            DBG_ASSERT!"Process was directly initialized. Use ProcessManager.alloc instead."( managerInitialized );
        }
    }
}

/// Process tracking management
struct ProcessManager {
private:
    enum OUTPUT_BUFF_SIZE = 1024;

    SimplePool!Process processPool;
    Process*[pid_t] processes; // XXX change to a nogc construct
    void delegate(pid_t pid, int exitStatus) nothrow @system customHandler;

    /// RAII wrapper for a process
    static struct ProcessPtr {
        Process* ptr;

        @disable this(this);

        ~this() nothrow @safe @nogc {
            if( ptr is null )
                return;

            theProcessManager.processPool.release(ptr);
        }

        alias ptr this;
    }

public:
    /** initialize the process manager
     *
     * You must call this before trying to spawn new processes. Must be called when the reactor is already active.
     *
     * Params:
     * maxProcesses = Maximum number of concurrent processes to be tracked.
     */
    void open(size_t maxProcesses) @trusted @nogc {
        processPool.open(maxProcesses);

        reactorSignal.registerHandler(OSSignal.SIGCHLD, &sigChildHandler);
        customHandler = null;
    }

    /** Shut down the process manager
     *
     * There is no real need to call this. This is mostly useful for unit tests. Must be called while the reactor is
     * still active.
     */
    void close() @trusted @nogc {
        reactorSignal.unregisterHandler(OSSignal.SIGCHLD);
        processPool.close();
    }

    /** Allocate a new handler for a child process.
     *
     * This is the way to allocate a new child process handler.
     *
     * Returns:
     * Returns a smart object referencing the Process struct. Struct is destructed when the referenece is destructed.
     */
    ProcessPtr alloc() nothrow @safe @nogc {
        Process* ptr = processPool.alloc();
        version(assert) {
            ptr.managerInitialized = true;
        }

        return ProcessPtr(ptr);
    }

    alias OutputHandlerDlg = void delegate(Process* child, const(char)[] output) nothrow;
    /**
     * Run a command and pass its output to a callback
     *
     * Run a command with the supplied command line. Call `outputProcessor` whenever the command outputs anything on
     * stdout or stderr.
     *
     * In addition to those, outputProcessor gets called three more times. The first time is right before the process is
     * started (with `output` set to empty). This allows outputProcessor to do any additional manipulations (such as
     * redirecting the input). This can be tested for because `child.pid` is 0.
     *
     * The second time is when the output closes. Again, this call will have a `output` set to an empty range.
     *
     * The third time is after the process has already exit. This can be tested for because `child.isAlive` will be
     * false.
     */
    void collectCommandOutput( OutputHandlerDlg outputProcessor, string[] cmdline... ) {
        ASSERT!"cmdline must have at least one argument (command to run)"(cmdline.length > 0);
        theReactor.spawnFiber!_commandOutputFiber(outputProcessor, cmdline);
    }

    /** Register custom SIGCHLD handler
     *
     * With this function you can register a custom SIGCHLD handler. This handler will be called only for child
     * processes that were not started by the ProcessManager, or for child processes that did not exit.
     *
     * The handler delegate will be called under a critical section lock and must not sleep.
     */
    void registerSigChldHandler(void delegate(pid_t pid, int status) nothrow @system handler) nothrow @safe @nogc {
        customHandler = handler;
    }

private:
    void sigChildHandler(const ref signalfd_siginfo siginfo) @system {
        Process** child = siginfo.ssi_pid in processes;

        int status;
        if( waitpid( siginfo.ssi_pid, &status, WNOHANG )<0 ) {
            ERROR!"SIGCHLD reported for %s with status 0x%x, but wait failed with errno %s"(
                    siginfo.ssi_pid, siginfo.ssi_status, errno );

            return;
        }

        if( (WIFEXITED(siginfo.ssi_status) || WIFSIGNALED(siginfo.ssi_status)) && child !is null ) {
            INFO!"Received child exit notification from %s: 0x%x"(siginfo.ssi_pid, status);
            (*child).handleExit(siginfo.ssi_status);
        } else {
            if( customHandler !is null ) {
                customHandler( siginfo.ssi_pid, siginfo.ssi_status );
            } else {
                ERROR!"Received child exit notification from unknown child %s status 0x%x"( siginfo.ssi_pid, status );
            }
        }
    }

    // Fiber function for collectCommandOutput
    // DMDBUG public because otherwise we can't template on it
    public static void _commandOutputFiber( OutputHandlerDlg outputProcessor, string[] cmdline ) {
        auto child = theProcessManager.alloc();
        child.redirectIO( Process.StdIO.StdOut );
        child.redirectErrToOut();

        // First call, before we run anything
        outputProcessor(child, null);

        child.run(cmdline);

        char[OUTPUT_BUFF_SIZE] buffer;
        ssize_t numRead;
        do {
            numRead = child.stdIO[Process.StdIO.StdOut].read(buffer, Timeout(20.msecs));
            // Call with what we got. This will be the empty range the last time we call
            outputProcessor( child, buffer[0..numRead] );
        } while( numRead>0 );

        child.wait();

        outputProcessor( child, null );
    }
}

@notrace ref ProcessManager theProcessManager() nothrow @trusted @nogc {
    return _theProcessManager;
}

private __gshared ProcessManager _theProcessManager;

unittest {
    import mecca.reactor;

    testWithReactor({
            theProcessManager.open(24);
            scope(exit) theProcessManager.close();

            auto child = theProcessManager.alloc();
            child.redirectIO(Process.StdIO.StdOut);
            child.redirectErrToOut();

            child.run("echo", "-e", "Hello\\r", "world");

            char[] buffer;
            ssize_t res;
            do {
                enum readChunk = 128;
                size_t oldLen = buffer.length;
                buffer.length = oldLen + readChunk;
                res = child.stdIO[Process.StdIO.StdOut].read(buffer[oldLen..oldLen+readChunk], Timeout(20.msecs));
                buffer.length = oldLen + res;
            } while( res>0 );

            DEBUG!"Child stdout: %s"(buffer);
            child.wait(Timeout(dur!"msecs"(100)));

            ASSERT!"Child closed stdout but is still running"(!child.isRunning);
            ASSERT!"Child output is \"%s\", not as expected"( buffer == "Hello\r world\n", buffer );
        });
}

unittest {
    import mecca.reactor;

    struct RunContext {
        Event done;
        uint howManyWaysMustAManWalkDown;
        bool killed;

        void callback( Process* child, const(char)[] buffer ) nothrow {
            try {
                if( child.pid == 0 ) {
                    // First call, before we started
                    child.redirectIO(Process.StdIO.StdIn, FD( "/dev/zero", O_RDONLY ));

                    return;
                }

                foreach(i, c; buffer) {
                    ASSERT!"buffer not filled with 0, has %s instead at offset %s"(
                            c=='\0', c, i+howManyWaysMustAManWalkDown);
                }

                howManyWaysMustAManWalkDown += buffer.length;
                if( !killed && howManyWaysMustAManWalkDown > 8196 ) {
                    child.kill();
                    killed = true;
                }

                if( !child.isRunning )
                    done.set();
            } catch(Exception ex) {
                ERROR!"Failed: %s"(ex.msg);
                assert(false);
            }
        }
    }

    testWithReactor({
            theProcessManager.open(24);
            scope(exit) theProcessManager.close();

            import mecca.reactor.io.signals;

            void termHandler(const ref signalfd_siginfo si) {
                // Nothing. We don't expect this to get called
            }

            // Register a TERM handler so that the signal is masked in the parent
            reactorSignal.registerHandler(OSSignal.SIGTERM, &termHandler);

            RunContext ctx;

            theProcessManager.collectCommandOutput( &ctx.callback, "cat" );

            ctx.done.wait();
        });
}

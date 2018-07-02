/// Manage signals as reactor callbacks
module mecca.reactor.io.signals;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.sys.posix.signal;
import core.sys.posix.unistd;
import core.sys.linux.sys.signalfd;
public import core.sys.linux.sys.signalfd : signalfd_siginfo;

import mecca.lib.exception;
import mecca.lib.reflection;
import mecca.lib.time;
import mecca.log;
public import mecca.platform.linux : OSSignal;
import mecca.platform.linux;
import mecca.reactor.io.fd;
import mecca.reactor;
import mecca.reactor.subsystems.epoll;

// Definitions missing from the phobos headers or lacking nothrow @nogc
extern(C) private nothrow @trusted @nogc {
    int signalfd(int, const(sigset_t)*, int);
    int sigemptyset(sigset_t*);
    int sigaddset(sigset_t*, int);
    int sigismember(in sigset_t*, int);
    int sigdelset(sigset_t*, int);
    int sigprocmask(int, in sigset_t*, sigset_t*);
}

// @safe wrappers
private {
    @notrace int signalfd (int __fd, const ref sigset_t __mask, int __flags) nothrow @trusted @nogc {
        return signalfd( __fd, &__mask, __flags );
    }

    @notrace int sigemptyset(ref sigset_t set) nothrow @trusted @nogc {
        return sigemptyset(&set);
    }

    @notrace int sigaddset(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigaddset( &set, signum );
    }

    @notrace int sigismember(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigismember(&set, signum);
    }
    @notrace int sigdelset(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigdelset( &set, signum );
    }
    @notrace int sigprocmask(int op, const ref sigset_t newMask) nothrow @trusted @nogc {
        return sigprocmask( op, &newMask, null );
    }
    @notrace int sigprocmask(int op, const ref sigset_t newMask, ref sigset_t oldMask) nothrow @trusted @nogc {
        return sigprocmask( op, &newMask, &oldMask );
    }
}

/**
 * A singleton managing registered signals
 */
private struct ReactorSignal {
    alias SignalHandler = void delegate(const ref signalfd_siginfo siginfo) @system;
private:
    enum BATCH_SIZE = 16; // How many signals to handle with one syscall

    enum SignalFdFlags = SFD_NONBLOCK|SFD_CLOEXEC;
    ReactorFD signalFd;
    sigset_t signals;
    FiberHandle fiberHandle;

    SignalHandler[NUM_SIGS] handlers;
public:
    /**
     * Must be called prior to registering any signals.
     *
     * Must be called after the reactor is open, and also after ReactorFS.openReactor has already been called.
     */
    void _open() @safe @nogc {
        ASSERT!"ReactorSignal.open called without first calling ReactorFD.openReactor"(epoller.isOpen);
        sigemptyset(signals);
        handlers[] = null;
        int fd = signalfd(-1, signals, SignalFdFlags);
        errnoEnforceNGC(fd >= 0, "signalfd creation failed");

        signalFd = ReactorFD(fd, true);

        fiberHandle = theReactor.spawnFiber(&fiberMainWrapper, &this);
    }

    /// Call this when shutting down the reactor. Mostly necessary for unit tests
    void _close() @safe @nogc {
        verifyOpen();
        signalFd.close();
        errnoEnforceNGC( sigprocmask( SIG_UNBLOCK, &signals, null )>=0, "sigprocmask unblocking signals failed" );
        ASSERT!"_close called while reactor still running"( !fiberHandle.isValid );
        // theReactor.throwInFiber!TerminateFiber(fiberHandle);
    }

    /**
     * register a signal handler
     *
     * Register a handler for a specific signal. The signal must not already be handled, either through ReactorSignal or
     * otherwise.
     *
     * Params:
     * signum = the signal to be handled
     * handler = a delegate to be called when the signal arrives
     */
    void registerHandler(OSSignal signum, SignalHandler handler) @trusted @nogc {
        verifyOpen();
        ASSERT!"registerHandler called with invalid signal %s"(signum<NUM_SIGS || signum<=0, signum);
        ASSERT!"signal %s registered twice"(handlers[signum] is null, signum);
        DBG_ASSERT!"signal %s has no handle but is set in sigmask"(sigismember(signals, signum)!=1, signum);

        sigaddset(signals, signum);
        scope(failure) sigdelset(signals, signum);

        errnoEnforceNGC( signalFd.osCall!(core.sys.linux.sys.signalfd.signalfd)(&signals, SignalFdFlags)>=0,
                "Registering new signal handler failed" );
        sigset_t oldSigMask;
        sigprocmask(SIG_BLOCK, signals, oldSigMask);
        ASSERT!"Registered signal %s already masked"(sigismember(oldSigMask, signum)!=1, signum);

        handlers[signum] = handler;
    }

    void registerHandler(string sig, T)(T handler) @trusted {
        registerHandler(__traits(getMember, OSSignal, sig), (ref _){handler();});
    }

    void unregisterHandler(OSSignal signum) @trusted @nogc {
        verifyOpen();
        ASSERT!"registerHandler called with invalid signal %s"(signum<NUM_SIGS || signum<=0, signum);
        ASSERT!"signal %s not registered"(handlers[signum] !is null, signum);
        DBG_ASSERT!"signal %s has a handle but is not set sigmask"(sigismember(signals, signum)==1, signum);

        sigset_t clearMask;
        sigemptyset(clearMask);
        sigaddset(clearMask, signum);
        errnoEnforceNGC( sigprocmask( SIG_UNBLOCK, clearMask )>=0, "sigprocmask unblocking signal failed" );
        sigdelset( signals, signum );
        errnoEnforceNGC( signalFd.osCall!(core.sys.linux.sys.signalfd.signalfd)(&signals, SignalFdFlags)>=0,
                "Deregistering signal handler failed" );
        handlers[signum] = null;
    }

    void unregisterHandler(string sig)() @trusted @nogc {
        unregisterHandler(__traits(getMember, OSSignal, sig));
    }


private:
    class TerminateFiber : Exception {
        this() nothrow @safe @nogc {
            super("ReactorSignal fiber terminator exception");
        }
    }

    static void fiberMainWrapper(ReactorSignal* rs) @safe {
        rs.fiberMain();
    }

    void fiberMain() @trusted {
        try {
            while(true) {
                // XXX Consider placing the array in the struct, so it's not on the stack
                signalfd_siginfo[BATCH_SIZE] info;
                ssize_t readSize = signalFd.blockingCall!(read)(&info, typeof(info).sizeof, Timeout.infinite);
                ASSERT!"read from signalfd returned misaligned size %s, expected a multiple of %s"(
                        (readSize%signalfd_siginfo.sizeof) == 0, readSize, signalfd_siginfo.sizeof);

                theReactor.enterCriticalSection();
                scope(exit) theReactor.leaveCriticalSection();

                bool[NUM_SIGS] handleMask;
                size_t numElements = readSize / signalfd_siginfo.sizeof;
                foreach( ref siginfo; info[0..numElements] ) {
                    auto signum = cast(OSSignal)siginfo.ssi_signo;
                    if( handleMask[signum] ) {
                        INFO!"Squelching repeated signal %s that happened multiple times"(signum); // That's temporal, not spatial, squelching
                        continue;
                    }

                    handleMask[signum] = true;
                    DBG_ASSERT!"Received signal %s with no handler"(handlers[signum] !is null, signum);
                    handlers[signum](siginfo);
                }
            }
        } catch(TerminateFiber ex) {
            INFO!"ReactorSignal fiber terminated"();
        }
    }

    @property void verifyOpen() const nothrow @safe @nogc {
        ASSERT!"ReactorSignal.close called without first calling open"(signalFd.isValid);
    }
}

/// ReactorSignal singleton
__gshared ReactorSignal reactorSignal;

unittest {
    Reactor.OpenOptions options;

    // Timing sensitive tests should not suffer GC collection in their middle
    options.utGcDisabled = true;

    theReactor.setup(options);
    scope(success) theReactor.teardown();

    uint sigcount;

    void sigHandler(const ref signalfd_siginfo siginfo) nothrow @safe @nogc {
        sigcount++;
    }

    void fiberCode() {
        import core.sys.posix.sys.time;
        import mecca.lib.time;

        reactorSignal.registerHandler(OSSignal.SIGALRM, &sigHandler);

        itimerval it;
        it.it_interval.tv_usec = 500; // Wake up every half millisecond. More accurate than our reactor timers ;-)
        it.it_value = it.it_interval;

        errnoCall!setitimer(ITIMER_REAL, &it, null);

        theReactor.sleep(dur!"msecs"(3));

        // Disarm the timer
        it.it_value.tv_sec = 0;
        it.it_value.tv_usec = 0;
        it.it_interval = it.it_value;
        errnoCall!setitimer(ITIMER_REAL, &it, null);

        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberCode);

    theReactor.start();

    INFO!"500µs timer triggered %s time during 3ms sleep"(sigcount);
    assertGE(sigcount, 5, "Signal count incorrect"); // Will probably be higher
}



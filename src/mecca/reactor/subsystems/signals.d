module mecca.reactor.subsystems.signal;

import core.sys.posix.signal;
import core.sys.posix.unistd;
import core.sys.linux.sys.signalfd;

import mecca.lib.exception;
import mecca.lib.reflection;
import mecca.log;
import mecca.platform.linux;
import mecca.reactor.subsystems.epoll;
import mecca.reactor.reactor;

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
    int signalfd (int __fd, const ref sigset_t __mask, int __flags) nothrow @trusted @nogc {
        return signalfd( __fd, &__mask, __flags );
    }

    int sigemptyset(ref sigset_t set) nothrow @trusted @nogc {
        return sigemptyset(&set);
    }

    int sigaddset(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigaddset( &set, signum );
    }

    int sigismember(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigismember(&set, signum);
    }
    int sigdelset(ref sigset_t set, int signum) nothrow @trusted @nogc {
        return sigdelset( &set, signum );
    }
    int sigprocmask(int op, const ref sigset_t newMask) nothrow @trusted @nogc {
        return sigprocmask( op, &newMask, null );
    }
    int sigprocmask(int op, const ref sigset_t newMask, ref sigset_t oldMask) nothrow @trusted @nogc {
        return sigprocmask( op, &newMask, &oldMask );
    }
}

private struct ReactorSignal {
    alias SignalHandler = void delegate(const ref signalfd_siginfo siginfo) nothrow @trusted @nogc;
private:
    enum BATCH_SIZE = 16; // How many signals to handle with one syscall

    enum SignalFdFlags = SFD_NONBLOCK|SFD_CLOEXEC;
    FD signalFd;
    sigset_t signals;
    FiberHandle fiberHandle;

    SignalHandler[NUM_SIGS] handlers;
public:
    void open() @trusted @nogc {
        ASSERT!"ReactorSignal.open called without first calling reactor.FD.openReactor"(epoller.isOpen);
        sigemptyset(signals);
        handlers[] = null;
        int fd = signalfd(-1, signals, SignalFdFlags);
        errnoEnforceNGC(fd >= 0, "signalfd creation failed");

        signalFd = FD(fd, true);

        fiberHandle = theReactor.spawnFiber(&fiberMainWrapper, &this);
    }

    void close() @trusted @nogc {
        verifyOpen();
        signalFd.close();
        errnoEnforceNGC( sigprocmask( SIG_UNBLOCK, &signals, null )>=0, "sigprocmask unblocking signals failed" );
        if( fiberHandle.isValid ) {
            theReactor.throwInFiber!TerminateFiber(fiberHandle);
        } else {
            WARN!"ReactorSignal.close called with no fiber, probably after reactor close"();
        }
    }

    void registerSignal(OsSignal signum, SignalHandler handler) @safe @nogc {
        verifyOpen();
        ASSERT!"registerSignal called with invalid signal %s"(signum<NUM_SIGS || signum<=0, signum);
        ASSERT!"signal %s registered twice"(handlers[signum] is null, signum);
        DBG_ASSERT!"signal %s has no handle but is set in sigmask"(sigismember(signals, signum)!=1, signum);

        sigaddset(signals, signum);
        scope(failure) sigdelset(signals, signum);

        errnoEnforceNGC( signalfd(signalFd.get, signals, SignalFdFlags)>=0, "Registering new signal handler failed" );
        sigset_t oldSigMask;
        sigprocmask(SIG_BLOCK, signals, oldSigMask);
        ASSERT!"Registered signal %s already masked"(sigismember(oldSigMask, signum)!=1, signum);

        handlers[signum] = handler;
    }

    void unregisterSignal(OsSignal signum) @safe @nogc {
        verifyOpen();
        ASSERT!"registerSignal called with invalid signal %s"(signum<NUM_SIGS || signum<=0, signum);
        ASSERT!"signal %s not registered"(handlers[signum] !is null, signum);
        DBG_ASSERT!"signal %s has a handle but is not set sigmask"(sigismember(signals, signum)==1, signum);

        sigset_t clearMask;
        sigemptyset(clearMask);
        sigaddset(clearMask, signum);
        errnoEnforceNGC( sigprocmask( SIG_UNBLOCK, clearMask )>=0, "sigprocmask unblocking signal failed" );
        sigdelset( signals, signum );
        errnoEnforceNGC( signalfd(signalFd.get, signals, SignalFdFlags)>=0, "Deregistering signal handler failed" );
        handlers[signum] = null;
    }

private:
    class TerminateFiber : Exception {
        this() nothrow @safe @nogc {
            super("ReactorSignal fiber terminator exception");
        }
    }

    static void fiberMainWrapper(ReactorSignal* rs) @safe @nogc {
        rs.fiberMain();
    }

    void fiberMain() @trusted @nogc {
        try {
            while(true) {
                // XXX Consider placing the array in the struct, so it's not on the stack
                signalfd_siginfo[BATCH_SIZE] info;
                ssize_t readSize = signalFd.read(info);
                ASSERT!"read from signalfd returned misaligned size %s, expected a multiple of %s"( (readSize%signalfd_siginfo.sizeof) == 0,
                        signalfd_siginfo.sizeof);

                theReactor.enterCriticalSection();
                scope(exit) theReactor.leaveCriticalSection();

                bool[NUM_SIGS] handleMask;
                size_t numElements = readSize / signalfd_siginfo.sizeof;
                foreach( ref siginfo; info[0..numElements] ) {
                    auto signum = cast(OsSignal)siginfo.ssi_signo;
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

__gshared ReactorSignal reactorSignal;

unittest {
    theReactor.setup();
    scope(exit) theReactor.teardown();

    FD.openReactor();
    reactorSignal.open();
    scope(exit) reactorSignal.close();

    uint sigcount;

    void sigHandler(const ref signalfd_siginfo siginfo) nothrow @safe @nogc {
        sigcount++;
    }

    void fiberCode() {
        import core.sys.posix.sys.time;
        import mecca.lib.time;

        reactorSignal.registerSignal(OsSignal.SIGALRM, &sigHandler);

        itimerval it;
        it.it_interval.tv_usec = 500; // Wake up every half millisecond. More accurate than our reactor timers ;-)
        it.it_value = it.it_interval;

        errnoCall!setitimer(ITIMER_REAL, &it, null);

        it = itimerval.init;
        scope(exit) setitimer(ITIMER_REAL, &it, null);

        theReactor.sleep(dur!"msecs"(3));
        theReactor.stop();
    }

    theReactor.spawnFiber(&fiberCode);

    theReactor.start();

    INFO!"500µs timer triggered %s time during 3ms sleep"(sigcount);
    ASSERT!"sigcount has incorrect value: %s"(sigcount>=6, sigcount); // Will probably be higher
}



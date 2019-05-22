module mecca.reactor.platform.signals;

package(mecca.reactor):

version (linux)
    import signals = mecca.reactor.platform.linux.signals;
else version (Darwin)
    import signals = mecca.reactor.platform.darwin.signals;
else
    static assert("platform not supported");

/// ReactorSignal singleton
public __gshared signals.ReactorSignal reactorSignal;

static if (is(signals.signalfd_siginfo))
    alias signals.signalfd_siginfo signalfd_siginfo;

unittest {
    import std.process : environment;

    import mecca.lib.exception : assertGE;
    import mecca.log : LogToConsole, INFO, WARN;
    import mecca.reactor : Reactor, theReactor;
    import mecca.platform.os : OSSignal;

    if( environment.get("DETERMINSTIC_HINT", "0")=="1" ) {
        WARN!"Skipping signals test due to environment request"();
        static if( !LogToConsole ) {
            import std.stdio: stderr;
            stderr.writeln( "Skipping signals test due to environment request" );
        }
        return;
    }

    Reactor.OpenOptions options;

    // Timing sensitive tests should not suffer GC collection in their middle
    options.utGcDisabled = true;

    theReactor.setup(options);
    scope(success) theReactor.teardown();

    uint sigcount;

    void sigHandler(OSSignal) {
        sigcount++;
    }

    void fiberCode() {
        import core.sys.posix.sys.time;
        import mecca.lib.exception : errnoCall;
        import mecca.lib.time;
        import mecca.platform.os : ITIMER_REAL;

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

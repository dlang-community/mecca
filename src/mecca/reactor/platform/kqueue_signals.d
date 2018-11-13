/// Manage signals as reactor callbacks
module mecca.reactor.platform.kqueue_signals;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (Kqueue):
package(mecca.reactor.platform):

alias ReactorSignal = KqueueReactorSignal;

private struct KqueueReactorSignal {
    import core.sys.posix.signal : sigaction_t, sigaction, SIG_IGN;

    import std.traits : Parameters;

    import mecca.lib.exception : ASSERT, errnoEnforceNGC;
    import mecca.platform.os : OSSignal;
    import mecca.reactor.platform.kqueue : Kqueue;
    import mecca.reactor.subsystems.poller : poller, Poller;

    alias SignalHandler = Kqueue.SignalHandler;

    private Poller.FdContext*[OSSignal.max + 1] handlers;
    private sigaction_t[OSSignal.max + 1] previousActions;

    /**
     * Must be called prior to registering any signals.
     *
     * Must be called after the reactor is open, and also after ReactorFS.openReactor has already been called.
     */
    void _open() @trusted @nogc {
        ASSERT!"ReactorSignal.open called without first calling ReactorFD.openReactor"(poller.isOpen);
    }

    /// Call this when shutting down the reactor. Mostly necessary for unit tests
    void _close() @safe @nogc {
        // noop
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
        ASSERT!"registerHandler called with invalid signal %s"(signum <= OSSignal.max || signum<=0, signum);
        ASSERT!"signal %s registered twice"(handlers[signum] is null, signum);

        sigaction_t previousAction;
        const sigaction_t action = { sa_handler: &dummySignalHandler };
        errnoEnforceNGC(sigaction(signum, &action, &previousAction) == 0, "Failed to register signal action");

        handlers[signum] = poller.registerSignalHandler(signum, handler);
        previousActions[signum] = previousAction;
    }

    void registerHandler(string sig, T)(T handler) @trusted {
        registerHandler(__traits(getMember, OSSignal, sig), (_){handler();});
    }

    void unregisterHandler(OSSignal signum) @trusted @nogc {
        ASSERT!"registerHandler called with invalid signal %s"(signum <= OSSignal.max || signum<=0, signum);
        ASSERT!"signal %s not registered"(handlers[signum] !is null, signum);

        errnoEnforceNGC(sigaction(signum, &previousActions[signum], null) == 0, "Failed to restore signal action");
        poller.unregisterSignalHandler(handlers[signum]);

        handlers[signum] = null;
        previousActions[signum] = sigaction_t.init;
    }

    void unregisterHandler(string sig)() @trusted @nogc {
        unregisterHandler(__traits(getMember, OSSignal, sig));
    }

    // Dummy signal handler is necessary, otherwise kqueue won't receive the
    // signal since it has lower precedence
    extern (C) private static void dummySignalHandler(int) {}
}

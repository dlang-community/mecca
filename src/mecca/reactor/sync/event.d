/**
 * Level and edge triggers condition with multiple waiters
 */
module mecca.reactor.sync.event;

import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.fiber_queue;
import mecca.reactor.sync.verbose;

/**
  Level trigger condition variable supporting multiple waiters.
 */
struct Event {
private:
    VolatileFiberQueue waiters;
    bool currentlySet;
    EventReporter reporter;

public:
    /**
     * Optional constructor setting the initial state.
     *
     * Params:
     * initialState = true means the Event is initially set. false (default) means it is initially unset.
     */
    this(bool initialState) nothrow @safe @nogc {
        currentlySet = initialState;
    }

    /**
     * Set the event.
     *
     * If there are any waiters, release all of them.
     */
    void set() nothrow @safe @nogc {
        DBG_ASSERT!"Event is set but has fibers waiting"(!isSet || waiters.empty);
        if (isSet)
            return;

        currentlySet = true;
        waiters.resumeAll();
        report(SyncVerbosityEventType.HazardOff);
    }

    /**
     * Reset the event.
     *
     * Any future fiber calling wait will block until another call to set. This is the Event default state.
     */
    void reset() nothrow @safe @nogc {
        DBG_ASSERT!"Event is set but has fibers waiting"(!isSet || waiters.empty);
        if( currentlySet )
            report(SyncVerbosityEventType.HazardOn);
        currentlySet = false;
    }

    /// Report the Event's current state.
    @property bool isSet() const pure nothrow @safe @nogc {
        return currentlySet;
    }

    /**
     * waits for the event to be set
     *
     * If the event is already set, returns without sleeping.
     *
     * Params:
     * timeout = sets a timeout for the wait.
     *
     * Throws:
     * TimeoutExpired if the timeout expires.
     *
     * Any other exception injected to this fiber using Reactor.throwInFiber
     */
    void wait(Timeout timeout = Timeout.infinite) @safe @nogc {
        bool reported;

        while( !isSet ) {
            if( !reported ) {
                report(SyncVerbosityEventType.Contention);
                reported = true;
            }
            waiters.suspend(timeout);
        }

        if( reported ) {
            report(SyncVerbosityEventType.Wakeup);
        }
    }

    /**
     * waits for the event to be set with potential spurious wakeups
     *
     * If the event is already set, returns without sleeping.
     *
     * The main difference between this method and wait is that this method supports the case where the struct holding the Event is freed
     * while the fiber is sleeping. As a result, two main differences are possible:
     * $(OL
     * $(LI Spurious wakeups are possible $(LPAREN)i.e. - unreliableWait returns, but the event is not set$(RPAREN) )
     * $(LI The VerboseEvent will not report when we wake up from the sleep.) )
     *
     * Params:
     * timeout = sets a timeout for the wait.
     *
     * Throws:
     * TimeoutExpired if the timeout expires.
     *
     * Any other exception injected to this fiber using Reactor.throwInFiber
     */
    void unreliableWait(Timeout timeout = Timeout.infinite) @safe @nogc {
        if( isSet )
            return;

        report(SyncVerbosityEventType.Contention);
        waiters.suspend(timeout);
        // Will not report wakeup, as we cannot know that the event still exists: report(SyncVerbosityEventType.Wakeup);
    }

package:
    void setVerbosityCallback(EventReporter reporter) nothrow @safe @nogc {
        this.reporter = reporter;
    }

    void report(SyncVerbosityEventType type) nothrow @safe @nogc {
        if( reporter !is null )
            reporter(type);
    }
}

/**
 * A wrapper around Event that adds verbosity to state changes.
 *
 * All state changes will be reported (from set to reset and vice versa). Also, a fiber that has to sleep due to the Event not being set will
 * also be reported.
 *
 * Don't forget to call open, or the event will behave as a usual Event.
 *
 * Params:
 *  Name = the display name to show for the Event.
 *  ExtraParam = An optional extra type to provide more context for the specific event instance. The data that goes with this type is
 *     provided as an argument to open.
 */
template VerboseEvent(string Name, ExtraParam = void) {
    alias VerboseEvent = SyncVerbosity!(Event, Name, ExtraParam);
}

unittest {
    //import mecca.reactor.fd;
    import mecca.reactor;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    VerboseEvent!"UT" evt;
    evt.open();

    uint counter;
    uint doneCount;
    bool done;

    enum NumWaiters = 30;

    void worker() {
        while(!done) {
            theReactor.yieldThisFiber();
            evt.wait();
            counter++;
        }

        doneCount++;
    }

    void framework() {
        uint savedCounter;

        enum Delay = dur!"msecs"(1);
        foreach(i; 0..10) {
            INFO!"Reset event"();
            evt.reset();
            savedCounter = counter;
            INFO!"Infra begin sleep"();
            theReactor.sleep(Delay);
            INFO!"Infra end sleep"();
            assert(savedCounter == counter, "Worker fibers working while event is reset");

            INFO!"Set event"();
            evt.set();
            INFO!"Infra begin sleep2"();
            theReactor.sleep(Delay);
            INFO!"Infra end sleep2"();
            assert(savedCounter != counter, "Worker fibers not released despite event set");
        }

        INFO!"Reset event end"();
        evt.reset();
        theReactor.yieldThisFiber();

        assert(doneCount==0, "Worker fibers exit while not done");
        done = true;
        INFO!"Infra begin sleep end"();
        theReactor.sleep(Delay);
        INFO!"Infra end sleep end"();

        assert(doneCount==0, "Worker fibers exit with event reset");
        INFO!"Set event end"();
        evt.set();
        INFO!"Infra yeild"();
        theReactor.yieldThisFiber();
        assert(doneCount==NumWaiters, "Not all worker fibers woke up from event");

        INFO!"Infra done"();
        theReactor.stop();
    }

    foreach(i; 0..NumWaiters)
        theReactor.spawnFiber(&worker);

    theReactor.spawnFiber(&framework);


    theReactor.start();
}

/// Edge trigger condition variable supporting multiple waiters.
struct Signal {
private:
    FiberQueue waiters;

public:
    /**
     * waits for the event to trigger
     *
     * This function is $(B guaranteed) to sleep.
     *
     * Params:
     * timeout = sets a timeout for the wait.
     *
     * Throws:
     * TimeoutExpired if the timeout expires.
     *
     * Any other exception injected to this fiber using Reactor.throwInFiber
     */
    void suspend(Timeout timeout = Timeout.infinite) @safe @nogc {
        waiters.suspend(timeout);
    }

    /**
     * Wake up all waiting fibers
     */
    void signal() nothrow @safe @nogc {
        waiters.resumeAll();
    }
}

/// Run a job in a fiber, but never two simultaneously
module mecca.reactor.lib.ondemand_worker;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;

import mecca.lib.exception;
import mecca.lib.integers;
import mecca.lib.time: Timeout;
import mecca.log;
import mecca.reactor;
import mecca.reactor.fiber_group;
import mecca.reactor.sync.event: Signal;

/// A fiber spawning delegate must be of this type
alias SpawnFiberDlg = FiberHandle delegate(void delegate() dlg) nothrow @safe @nogc;

/**
Run a job in a fiber, making sure never to run two simultaneously.

This semantics is useful for deferred jobs that need to collect or parse a state that changes. The number of jobs is
not dependent on the number of state changes.

The usage is to trigger the worker when the state changes. If no job is currently running, a fiber is immediately
launched to carry out the job. If the job is already running, it will trigger again once the current instance finishes.
*/
struct OnDemandWorkerFunc(alias F) {
private:
    static class JobCancelled : FiberInterrupt {
        mixin ExceptionBody!"OnDemandWorker task cancelled";
    }

    SpawnFiberDlg spawnFiber;
    Signal done;
    FiberHandle fiberHandle;
    Serial32 requestGeneration, completedGeneration;
    bool disabled, cancelAll;
    ParameterTypeTuple!F args;
    ParameterTypeTuple!F defaultArgs;

public:
    @disable this(this);

    /// Construct a worker
    static if( ParameterTypeTuple!F.length>0 ) {
        this(ParameterTypeTuple!F args, SpawnFiberDlg spawnFiberDlg = null) {
            this.args = args;
            this.defaultArgs = args;
            this.spawnFiber = spawnFiberDlg;
        }
    } else {
        // The above definition works for this case as well, but results in a constructor with default values to
        // all arguments.
        this(SpawnFiberDlg spawnFiberDlg) {
            this.spawnFiber = spawnFiberDlg;
        }
    }

    /// ditto
    this(ParameterTypeTuple!F args, FiberGroup* group) {
        ASSERT!"The fiber group must not be null"(group !is null);
        this(args, &group.spawnFiber);
    }

    /// Helper for more verbose DEBUG logging
    void DEBUG(string fmt, string file = __FILE__, string mod = __MODULE__, uint line = __LINE__, Args...)(Args args) {
        .DEBUG!("#ONDEMAND(%s) worker: " ~ fmt, file, mod, line)(&this, args);
    }

    /** Trigger an execution of the worker.

     If the worker is already executing, this will cause it to execute again once it completes. Otheriwse, opens a new
     fiber and starts executing.
     */
    @notrace void run() nothrow @safe @nogc {
        if(disabled) {
            WARN!"#ONDEMAND(%s) worker is #DISABLED, not running!"(&this);
            return;
        }
        if (spawned) {
            requestGeneration++;
            cancelAll = false;
        } else {
            assert(requestGeneration==completedGeneration);
            requestGeneration++;

            if( spawnFiber is null ) {
                // We can't do that in the constructor because we want to allow static initialization
                spawnFiber = &theReactor.spawnFiber!(void delegate());
            }

            fiberHandle = spawnFiber(&fib);
            DEBUG!"spawned fiber %s"(fiberHandle.fiberId);
        }
    }
    static if (ParameterTypeTuple!F.length > 0) {
        /// ditto
        void run(ParameterTypeTuple!F args) nothrow @safe @nogc {
            this.args = args;
            run();
        }
    }

    /** Wait for task queue to empty.
     *
     * This function waits until the worker fiber exits. This means that not only has the current 
     *
     * Note:
     * Unless independently throttling requests, there is no guarantee that this condition will $(B ever) happen. 
     */
    void waitIdle(Timeout timeout = Timeout.infinite) @safe @nogc {
        while( spawned )
            done.wait(timeout);
    }

    /// Wait for all $(I currently) pending tasks to complete
    void waitComplete(Timeout timeout = Timeout.infinite) @safe @nogc {
        auto targetGeneration = requestGeneration;
        while( targetGeneration<completedGeneration ) {
            done.wait(timeout);
        }
    }

    /// Reports whether a fiber is currently handling a request
    @property public bool spawned() const nothrow @safe @nogc {
        return fiberHandle.isValid;
    }

    /// Cancel currently running tasks.
    ///
    /// Params:
    /// currentOnly = Cancel only the currently running task. False (default) means to cancel the current task and also
    /// all currently scheduled tasks. Setting to true means cancel only the currently running task. If another one is
    /// scheduled, it will get carried out.
    void cancel(bool currentOnly = false) nothrow @safe @nogc {
        if( !spawned ) {
            ASSERT!"Task fiber not running but a cancel is pending"(!cancelAll);
            return;
        }

        if( !currentOnly )
            cancelAll = true;

        theReactor.throwInFiber!JobCancelled(fiberHandle);
    }

    /** Disable the worker from receiving new jobs.
     *
     * This is useful in preperation for shutdown of the system. Disabling the worker $(B does not) terminate a current
     * job, if one is running. Use `cancel` to do that.
     */
    void disable() nothrow @safe @nogc {
        disabled = true;

        // Don't interrupt a running task, but prevent future ones from starting
        cancelAll = true;

        // Mark all pending tasks as done

        // This will get overridden by the fiber if a task is currently executing, but the cancelAll handling will do
        // it again from within the fiber.
        completedGeneration = requestGeneration;
    }

    /// Enable a disabled worker.
    void enable() nothrow @safe @nogc {
        if( !disabled )
            return;

        DBG_ASSERT!"Disabled and idle worker has incomplete tasks"(completedGeneration==requestGeneration);
        ASSERT!"Cannot enable a disabled worker while a defunct task is still running"(!spawned);
        disabled = false;
        cancelAll = false;
    }
private:
    void fib() {
        scope(exit)
            cancelAll = false;

        try {
            scope (exit) {
                fiberHandle = null;
            }
            theReactor.setFiberName(fiberHandle, __traits(identifier, F), &F);
            do {
                scope(exit) done.signal();
                scope(exit) args = defaultArgs;

                auto targetGeneration = requestGeneration;
                scope(exit) completedGeneration = targetGeneration;

                F(args);
            } while (!cancelAll && requestGeneration<completedGeneration);
        } catch(Throwable t) {
            DEBUG!"becoming #DISABLED due to exception: %s"(t.msg);
            disable();
            throw t;
        }

        if( cancelAll )
            completedGeneration = requestGeneration;
    }
}

/// Same as `OnDemandWorkerFunc`, except with a delegate.
struct OnDemandWorkerDelegate {
    OnDemandWorkerFunc!wrapper onDemandWorkerFunc;

    /// Construct a worker
    this(void delegate() dg, SpawnFiberDlg spawnFiberDlg = null) {
        import mecca.lib.exception: DBG_ASSERT;
        onDemandWorkerFunc = OnDemandWorkerFunc!wrapper(dg, spawnFiberDlg);
    }

    this(void delegate() dg, FiberGroup* group) {
        ASSERT!"The fiber group must not be null"(group !is null);
        this(dg, &group.spawnFiber);
    }

    @notrace private static void wrapper(void delegate() dg) {
        dg();
    }

    @property bool isSet() {
        return onDemandWorkerFunc.args[0] !is null;
    }

    alias onDemandWorkerFunc this;
    // XXX for OndemandWorkerDelegate we don't want to allow calling run(void delegate()) and replace the delegate.
    //@disable void run(void delegate() dg) {}
}

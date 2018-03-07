module mecca.reactor.ondemand_worker;

import std.traits;

import mecca.lib.time: Timeout;
import mecca.log;
import mecca.reactor;
import mecca.reactor.fiber_group;
import mecca.reactor.sync.event: Event;

struct OnDemandWorkerFunc(alias F) {
    private FiberHandle fiberHandle;
    private bool runAgain, defunct;
    private ParameterTypeTuple!F args;
    private ParameterTypeTuple!F defaultArgs;
    Event done = Event(true);

    FiberGroup* group;

    static if (ParameterTypeTuple!F.length > 0) {
        this(ParameterTypeTuple!F args, FiberGroup* group = null) {
            this.args = args;
            this.defaultArgs = args;
            this.group = group;
        }
    } else {
        this(FiberGroup* group) { this.group = group; }
    }

    void DEBUG(string fmt, string file = __FILE__, string mod = __MODULE__, uint line = __LINE__, Args...)(Args args) {
        .DEBUG!("#ONDEMAND(%s) worker: " ~ fmt, file, mod, line)(&this, args);
    }
    void run() {
        if(defunct) {
            // This is just as valid as the killing of the fiber that had executed the previous job. It is an indefinite
            // "postponing" of the work. In practice used for step down exception to prevent spawns until we're
            // destroyed.
            WARN!"#ONDEMAND(%s) worker is #DEFUNCT, not running!"(&this);
            return;
        }
        if (spawned) {
            DEBUG!"telling existing fiber %s to run again"(fiberHandle.fiberId);
            runAgain = true;
        } else {
            assert(!runAgain);
            done.reset();
            if( this.group is null )
                fiberHandle = theReactor.spawnFiber(&fib);
            else
                fiberHandle = group.spawnFiber(&fib);
            DEBUG!"spawned fiber %s"(fiberHandle.fiberId);
        }
    }
    static if (ParameterTypeTuple!F.length > 0) {
        void run(ParameterTypeTuple!F args) {
            this.args = args;
            run();
        }
    }

    void join(Timeout timeout = Timeout.infinite) {
        done.wait(timeout);
    }

    private void fib() {
        try {
            assert(!done.isSet);
            scope (exit) {
                fiberHandle = null;
                assert(!done.isSet);
                done.set();
            }
            do {
                runAgain = false;
                scope(exit) args = defaultArgs;
                F(args);
            } while (runAgain);
        } catch(Throwable t) {
            DEBUG!"becoming #DEFUNCT due to exception: %s"(t.msg);
            defunct = true;
            throw t;
        }
    }

    @property public bool spawned() const {
        return fiberHandle.isValid;
    }
}

struct OnDemandWorkerDelegate {
    OnDemandWorkerFunc!wrapper onDemandWorkerFunc;

    this(void delegate() dg, FiberGroup* group = null) {
        import mecca.lib.exception: DBG_ASSERT;
        DBG_ASSERT!"delegate can't be null"(dg !is null);
        onDemandWorkerFunc = OnDemandWorkerFunc!wrapper(dg, group);
    }

    private static void wrapper(void delegate() dg) {
        dg();
    }

    @property bool isSet() {
        return onDemandWorkerFunc.args[0] !is null;
    }

    alias onDemandWorkerFunc this;
    // XXX for OndemandWorkerDelegate we don't want to allow calling run(void delegate()) and replace the delegate.
    //@disable void run(void delegate() dg) {}
}

struct RepetitiveWorkerFunc(alias F) {
    private OnDemandWorkerFunc!F worker;
    private Duration frequency;
}

//struct OnDemandWorker(alias F = null) {
//    private bool spawned;
//    private bool runAgain;

//    static if (isSomeFunction!F) {
//        alias Func = F;
//        ParameterTypeTuple!F args;
//        static if (ParameterTypeTuple!F.length > 0) {
//            this(ParameterTypeTuple!Func args) {
//                this.args = args;
//            }
//        }
//    } else {
//        //static assert(false);
//        private static void wrapper(void delegate() dg) {
//            dg();
//        }
//        alias Func = wrapper;
//        void delegate() args;
//        this(void delegate() dg) {
//            this.args = dg;
//        }
//    }

//    void run() {
//        if (spawned) {
//            runAgain = true;
//        } else {
//            assert(!runAgain);
//            theReactor.spawnFiber(&fib);
//            spawned = true;
//        }
//    }

//    private void fib() {
//        scope(exit) spawned = false;
//        do {
//            runAgain = false;
//            Func(args);
//        } while (runAgain);
//    }
//}

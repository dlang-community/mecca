/// group related fibers so they can all be killed together, if needed
module mecca.reactor.fiber_group;

import std.traits;

import mecca.containers.lists;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;

/// group of related fiber that may need to be killed together
struct FiberGroup {
private:
    package class FiberGroupExtinction: Error {mixin ExceptionBody!"FiberGroup killer exception";}
    alias RegisteredFibersList = _LinkedList!(ReactorFiber*, "params.fgChain.next", "params.fgChain.prev", "params.fgChain.owner", false);

    package struct Chain {
        ReactorFiber*           prev, next;
        RegisteredFibersList*   owner;
    }

    RegisteredFibersList fibersList;
    enum State {
        None,
        Active,
        Closing,
    }
    State state;

public:
    /// Initialize a new fiber group
    void open() nothrow @safe @nogc {
        ASSERT!"FiberGroup.open called on already open group"(closed);
        DBG_ASSERT!"New FiberGroup has fibers registered"(fibersList.empty);
        state = State.Active;
    }

    /// report whether a fiber group is closed
    @property closed() const pure nothrow @safe @nogc {
        return state == State.None;
    }

    /**
     * close the group (killing all fibers).
     *
     * The function returns after all fibers have died.
     *
     * It is legal for the calling thread to be part of the group. In that case, it will be
     * killed only once the function is done waiting for the other fibers to exit.
     */
    void close() @safe @nogc {
        if( state!=State.Active )
            return;

        auto cs = theReactor.criticalSection();
        state = State.Closing;
        scope(exit) if(state == State.Closing) state = State.Active;

        bool suicide;

        auto ourFiberId = theReactor.runningFiberId;
        auto killerException = mkEx!FiberGroupExtinction;
        foreach(fiber; fibersList.range) {
            if( fiber.identity == ourFiberId ) {
                suicide = true;
                continue;
            }

            // WARN_AS!"Fiber killed by group"(fiber.identity);
            WARN!"Killing fiber %s"(fiber.identity);
            theReactor.throwInFiber(FiberHandle(fiber), killerException);
        }
        cs.leave();

        if( suicide )
            removeThisFiber();

        // Wait for all fibers to die an agonizing death
        theReactor.yieldThisFiber();

        while( !fibersList.empty ) {
            WARN!"Some fibers in group not yet dead. Sleeping for 1ms"();
            theReactor.sleep(dur!"msecs"(1));
        }
        DEBUG!"All group fibers are now dead. May them rest in pieces"();

        state = State.None;

        if (suicide) {
            WARN!"Fiber commiting suicid as part of group"();
            throw killerException;
        }
    }

    /// Return true if the current fiber is a member of the group
    bool isCurrentFiberMember() const nothrow @safe @nogc {
        return theReactor.runningFiberPtr in fibersList;
    }

    /**
     * Spawn a new fiber that will be a member of the group.
     *
     * Arguments and return value are the same as for theReactor.spawnFiber.
     */
    FiberHandle spawnFiber(alias F)(ParameterTypeTuple!F args) nothrow @safe @nogc {
        ASSERT!"FiberGroup state not Active: %s"(state == State.Active, state);
        alias funcType = typeof(F);
        auto fib = theReactor.spawnFiber( &fiberWrapper!funcType, &F, &this, args );

        return fib;
    }

    /// ditto
    FiberHandle spawnFiber(void delegate() dg) nothrow @safe @nogc {
        static void wrapper(void delegate() dg) @system {
            dg();
        }
        return spawnFiber!wrapper(dg);
    }

    /**
     * Conditionally spawn a new fiber, only if the fiber group is currently open.
     *
     * This function is useful in certain racy cases, where the fiber group has been closed, but has not yet finished closing.
     *
     * Params:
     * dg = the delegate to run inside the fiber
     *
     * Returns:
     * The FiberHandle of the new fiber if successful, the invalid FiberHandle if the fiber group is closed or closing.
     */
    FiberHandle spawnFiberIfOpen(void delegate() dg) nothrow @safe @nogc {
        if( state != State.Active )
            return FiberHandle.init;

        return spawnFiber(dg);
    }

    struct ExecutionResult(T) {
        bool completed = false;
        static if (!is(T == void)) {
            T result;
        }
    }

    /**
     * Perform a task inside the current fiber as part of the group.
     *
     * This function temporarily adds the current fiber to the group for the sake of performing a specific function. Once that function
     * is done, the fiber leaves the group again.
     *
     * If the group is killed while inside this function, the function returns early and the return type has the member `completed` set to
     * false. If the function ran to completion, `completed` is set to true, and `result` is set to the function's return value (if one
     * exists).
     *
     * If the fiber is already a member of the group when this function is called, the function is simply executed normally.
     */
    auto runTracked(alias F)(ParameterTypeTuple!F args) {
        alias R = ReturnType!F;
        ExecutionResult!R res;

        if(isCurrentFiberMember()) {
            // No need to attach again
            return invoke!F(args);
        }

        addThisFiber();
        bool fiberAdded = true;
        scope(exit) {
            if(fiberAdded)
                removeThisFiber();
        }

        try {
            res = invoke!F(args);
        } catch( FiberGroupExtinction ex ) {
            WARN!"Fiber %s killed in contained context by FiberGroup"(theReactor.runningFiberId);
            removeThisFiber();
            fiberAdded = false;
            theReactor.yieldThisFiber();
        }

        return res;
    }

    /// ditto
    auto runTracked(T)(scope T delegate() dg) {
        static T wrapper(scope T delegate() dg) {
            return dg();
        }
        return runTracked!(wrapper)(dg);
    }

private:
    void addThisFiber() nothrow @safe @nogc {
        ASSERT!"FiberGroup state not Active: %s"(state == State.Active, state);
        auto fib = theReactor.runningFiberPtr;
        DBG_ASSERT!"Trying to add fiber already in group"( fib !in fibersList );
        DBG_ASSERT!"Trying to add fiber to group which is already member of another group"( fib.params.fgChain.owner is null );
        fibersList.append(fib);
    }

    void removeThisFiber() nothrow @safe @nogc {
        ASSERT!"FiberGroup asked to remove fiber which is not a member"(isCurrentFiberMember());
        fibersList.remove(theReactor.runningFiberPtr);
    }

    static auto invoke(alias F)(ParameterTypeTuple!F args) {
        alias R = ReturnType!F;
        ExecutionResult!R res;

        static if (is(R == void)) {
            F(args);
        } else {
            res.result = F(args);
        }
        res.completed = true;

        return res;
    }

    static void fiberWrapper(T)(T* fn, FiberGroup* fg, ParameterTypeTuple!T args) {
        if( fg.state!=State.Active ) {
            ASSERT!"FiberGroup fiber starts for a non-active fiber group"(fg.state==State.Closing);
            return;
        }

        fg.addThisFiber();
        fn(args);
    }
}

unittest {
    static int counter = 0;

    static void fib(int num) {
        scope(success) assert(false);

        while (true) {
            counter += num;
            theReactor.sleep(msecs(1));
        }
    }

    testWithReactor({
        FiberGroup tracker;
        tracker.open();

        tracker.addThisFiber();
        tracker.spawnFiber!fib(1);
        tracker.spawnFiber!fib(100);
        theReactor.sleep(msecs(50));
        // this fiber won't get to run
        tracker.spawnFiber!fib(10000);

        bool caught = false;
        try {
            tracker.close();
        }
        catch (tracker.FiberGroupExtinction ex) {
            caught = true;
        }

        assert(caught, "this fiber did not commit suicide");
        assert(counter > 0, "no fibers have run");
        assert(counter < 10000, "third fiber should not have run");

        int counter2 = 0;

        tracker.open();

        static class SomeException: Exception {mixin ExceptionBody!"Some exception";}

        static bool caught2 = false;
        try {
            tracker.runTracked({
                throw mkEx!SomeException;
            });
        } catch (SomeException ex) {
            caught2 = true;
        }
        assert(caught2, "exception wasn't passed up");

        tracker.runTracked({
            theReactor.registerTimer(Timeout(msecs(20)), (){
                theReactor.spawnFiber({
                    tracker.close();
                });
            });

            scope(success) assert(false);

            while (true) {
                counter2++;
                theReactor.sleep(msecs(1));
            }
        });

        assert(counter2 > 0, "no fibers have run");
        assert(counter2 < 10000, "third fiber should not have run");

        // test fiber suicide
        tracker.open();
        tracker.spawnFiber({tracker.close();});
        theReactor.sleep(msecs(1));
        assert(tracker.closed());
    });
}
/*
   Make sure nested calls work correctly
 */
unittest {
    import std.exception;
    import std.stdio;

    testWithReactor({
        FiberGroup foo;
        foo.open();

        // Make sure we dont catch the fiberbomb in the nested call
        auto res1 = foo.runTracked({
            foo.runTracked({
                throw mkEx!(foo.FiberGroupExtinction);
            });
            assert(false, "Nested call caught the fiber bomb!");
        });
        assert(res1.completed == false, "res2 marked as completed when shouldn't has");

        // Make sure we dont catch the fiberbomb in a deeply nested call
        auto res2 = foo.runTracked({
            foo.runTracked({
                foo.runTracked({
                    foo.runTracked({
                        foo.runTracked({
                            throw mkEx!(foo.FiberGroupExtinction);
                        });
                        assert(false, "Nested call caught the fiber bomb!");
                    });
                    assert(false, "Nested call caught the fiber bomb!");
                });
                assert(false, "Nested call caught the fiber bomb!");
            });
            assert(false, "Nested call caught the fiber bomb!");
        });
        assert(res2.completed == false, "res2 marked as completed when shouldn't have");
    });
}

/*
    Spawn fibers on inactive trackers
*/
unittest {
    import std.exception;
    import std.stdio;

    testWithReactor({
        FiberGroup foo;

        void dlg() {}

        assert( !foo.spawnFiberIfOpen(&dlg).isValid );

        foo.open();

        assert(foo.spawnFiberIfOpen(&dlg).isValid);

        foo.close();

        assert( !foo.spawnFiberIfOpen(&dlg).isValid);
    });
}

/// group related fibers so they can all be killed together, if needed
module mecca.reactor.fiber_group;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;

import mecca.containers.lists;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;

/// group of related fiber that may need to be killed together
struct FiberGroup {
private:
    package class FiberGroupExtinction: FiberInterrupt {mixin ExceptionBody!"FiberGroup killer exception";}
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

    @disable this(this);

    ~this() @safe @nogc nothrow {
        ASSERT!"FiberGroup destructed but is not fully closed"(closed);
    }

    /// 3state execution results type
    struct ExecutionResult(T) {
        /// Whether execution finished successfully
        bool completed = false;
        static if (!is(T == void)) {
            /// Actual execution result (if type is not void)
            T result;
        }
    }

    /// Initialize a new fiber group
    void open() nothrow @safe @nogc {
        ASSERT!"New FiberGroup has fibers registered"(fibersList.empty);
        // The following line has a side effect!! "closed" will set the state to None if it is Closing and all fibers
        // have quit. Since this is an ASSERT (i.e. - does not get compiled away), and since we're overriding the state
        // at the very next statement, this is not a problem.
        ASSERT!"Cannot open fiber group that is not closed: Current state %s"(closed, state);
        state = State.Active;
    }

    /// report whether a fiber group is closed
    ///
    /// This call will return `false` for half-closed groups.
    @property closed() pure nothrow @safe @nogc {
        // If we closed without waiting, we might still be in Closing state.
        if( state==State.Closing && fibersList.empty )
            state=State.None;

        return state == State.None;
    }

    /**
     * close the group (killing all fibers).
     *
     * It is legal for the calling thread to be part of the group. If `waitForExit` is true, it will be killed only once
     * the function is done waiting for the other fibers to exit.
     *
     * Params:
     * waitForExit = Whether the function waits for all fibers to exit before returning.
     *
     * Notes:
     * If waitForExit is false, the group cannot be reused before all fibers have actually exited.
     */
    void close(bool waitForExit = true) @safe @nogc {
        if( state!=State.Active )
            return;

        auto cs = theReactor.criticalSection();
        state = State.Closing;

        bool suicide;

        auto ourFiberId = theReactor.currentFiberId;
        auto killerException = mkEx!FiberGroupExtinction;
        foreach(fiber; fibersList.range) {
            if( fiber.identity == ourFiberId ) {
                suicide = true;
                continue;
            }

            // WARN_AS!"Fiber killed by group"(fiber.identity);
            WARN!"Killing fiber %s"(fiber.identity);
            theReactor.throwInFiber!FiberGroupExtinction(FiberHandle(fiber));
        }

        if( !waitForExit ) {
            if( suicide ) {
                WARN!"Fiber commiting suicid as part of group"();
                throw killerException;
            }
            return;
        }

        cs.leave();

        if( suicide )
            removeThisFiber();

        waitEmpty();
        DEBUG!"All group fibers are now dead. May they rest in pieces"();

        state = State.None;

        if (suicide) {
            // For consistency, add ourselves back.
            addThisFiber(true);
            WARN!"Fiber commiting suicid as part of group"();
            throw killerException;
        }
    }

    /// Wait for all fibers in a group to exit.
    ///
    /// This function does not initiate termination. Use `close` to actually terminate the fibers.
    void waitEmpty(Timeout timeout = Timeout.infinite) @safe @nogc {
        // Wait for all fibers to die an agonizing death
        while( !fibersList.empty ) {
            theReactor.joinFiber( FiberHandle(fibersList.head), timeout );
        }
    }

    /// Return true if the current fiber is a member of the group
    bool isCurrentFiberMember() const nothrow @safe @nogc {
        return theReactor.currentFiberPtr in fibersList;
    }

    // DMDBUG https://issues.dlang.org/show_bug.cgi?id=16206
    // The non-template version must come before the templated version
    /**
     * Spawn a new fiber that will be a member of the group.
     *
     * Arguments and return value are the same as for theReactor.spawnFiber.
     */
    FiberHandle spawnFiber(void delegate() dg) nothrow @safe @nogc {
        static void wrapper(void delegate() dg) @system {
            dg();
        }
        return spawnFiber!wrapper(dg);
    }

    /// ditto
    FiberHandle spawnFiber(alias F)(ParameterTypeTuple!F args) nothrow @safe @nogc {
        ASSERT!"FiberGroup state not Active: %s"(state == State.Active, state);
        alias funcType = typeof(F);
        auto fib = theReactor.spawnFiber( &fiberWrapper!funcType, &F, &this, args );

        return fib;
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

    /**
     * Perform a task inside the current fiber as part of the group.
     *
     * This function temporarily adds the current fiber to the group for the sake of performing a specific function.
     * Once that function is done, the fiber leaves the group again.
     *
     * If the group is killed while inside this function, the function returns early and the return type has the member
     * `completed` set to false. If the function ran to completion, `completed` is set to true, and `result` is set to
     * the function's return value (if one exists).
     *
     * If the fiber is already a member of the group when this function is called, the function is simply executed
     * normally.
     */
    @notrace auto runTracked(alias F)(ParameterTypeTuple!F args) {
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
            WARN!"Fiber %s killed in contained context by FiberGroup"(theReactor.currentFiberId);
            removeThisFiber();
            fiberAdded = false;
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
    @notrace void addThisFiber(bool duringSuicide = false) nothrow @safe @nogc {
        ASSERT!"FiberGroup state not Active: %s"(state == State.Active || state==State.None && duringSuicide, state);
        auto fib = theReactor.currentFiberPtr;
        DBG_ASSERT!"Trying to add fiber already in group"( fib !in fibersList );
        DBG_ASSERT!"Trying to add fiber to group which is already member of another group"( fib.params.fgChain.owner is null );
        fibersList.append(fib);
    }

    @notrace void removeThisFiber() nothrow @safe @nogc {
        ASSERT!"FiberGroup asked to remove fiber which is not a member"(isCurrentFiberMember());
        fibersList.remove(theReactor.currentFiberPtr);
    }

    @notrace static auto invoke(alias F)(ParameterTypeTuple!F args) {
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

    @notrace static void fiberWrapper(T)(T* fn, FiberGroup* fg, ParameterTypeTuple!T args) {
        if( fg.state!=State.Active ) {
            WARN!"Fiber group closed before fiber managed to start"();
            return;
        }

        fg.addThisFiber();
        scope(exit) fg.removeThisFiber();
        theReactor.setFiberName(theReactor.currentFiberHandle, "FiberGroupMember", fn);
        fn(args);
    }
}

unittest {
    static int counter;
    counter = 0;

    static void fib(int num) {
        scope(success) assert(false);

        while (true) {
            counter += num;
            theReactor.sleep(msecs(1));
        }
    }

    testWithReactor({
        FiberGroup tracker;

        {
            DEBUG!"#UT Test fibers running and being killed"();
            tracker.open();

            tracker.addThisFiber();
            scope(exit) tracker.removeThisFiber();
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

            theReactor.sleep(2.msecs);

            assert(caught, "this fiber did not commit suicide");
            assert(counter > 0, "no fibers have run");
            assert(counter < 10000, "third fiber should not have run");
        }

        {
            int counter2 = 0;

            tracker.open();

            static class SomeException: Exception {mixin ExceptionBody!"Some exception";}

            static bool caught = false;
            try {
                tracker.runTracked({
                    throw mkEx!SomeException;
                });
            } catch (SomeException ex) {
                caught = true;
            }
            assert(caught, "exception wasn't passed up");

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
        }

        {
            // test fiber suicide
            tracker.open();
            tracker.spawnFiber({tracker.close();});
            theReactor.sleep(msecs(1));
            assert(tracker.closed());
        }
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

        foo.close();
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

unittest {
    uint counter = 0;
    FiberGroup tracker;

    void fib1() {
        scope(exit) {
            counter++;
        }
        theReactor.sleep(10.msecs);
    }

    testWithReactor(
    {
        static void closer(FiberGroup* fg, bool wait) {
            fg.close(wait);
        }

        {
            tracker.open();

            tracker.spawnFiber(&fib1);
            tracker.spawnFiber(&fib1);

            theReactor.yield();

            tracker.runTracked!closer(&tracker, true);
            assertEQ(counter, 2);

            counter=0;
            tracker.open();

            tracker.spawnFiber(&fib1);
            tracker.spawnFiber(&fib1);

            theReactor.yield();

            tracker.runTracked!closer(&tracker, false);
            assertEQ(counter, 0);
            theReactor.yield();
            assertEQ(counter, 2);
        }

        tracker.close();
    });
}

unittest {
    META!"Make sure that close(false) works properly"();

    int counter;

    void fiberBody() {
        scope(exit) counter++;

        theReactor.sleep(10.days);
    }

    testWithReactor({
        FiberGroup group;

        group.open();

        group.spawnFiber(&fiberBody);
        group.spawnFiber(&fiberBody);

        assertEQ(counter, 0);
        theReactor.yield();

        assertEQ(counter, 0);
        assert(!group.closed);

        group.close(false);

        assert(!group.closed);
        assertThrows!AssertError(group.open());

        theReactor.yield();
        assert(group.closed);

        group.open();
        group.close();
    });
}

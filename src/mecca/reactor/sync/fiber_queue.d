module mecca.reactor.sync.fiber_queue;

import mecca.containers.lists;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.reactor;

struct FiberQueueImpl(bool Volatile) {
private:
    LinkedListWithOwner!(ReactorFiber*) waitingList;

public:
    @disable this(this);

    void suspend(Timeout timeout = Timeout.infinite) @safe @nogc {
        auto ourHandle = theReactor.runningFiberHandle;
        DBG_ASSERT!"Fiber already has sleep flag when FQ.suspend called"( ! ourHandle.get.flag!"SLEEPING" );
        bool inserted = waitingList.append(ourHandle.get);
        DBG_ASSERT!"Fiber %s added to same queue twice"(inserted, ourHandle);

        ourHandle.get.flag!"SLEEPING" = true;
        scope(failure) {
            if( ourHandle.get.flag!"SLEEPING" ) {
                ourHandle.get.flag!"SLEEPING" = false;
            } else {
                // We were killed after we were already scheduled to wake up
                static if( !Volatile ) {
                    // Wake up one instead of us. Only do so if there is no chance that the queue itself disappeared
                    resumeOne();
                }
            }
        }

        theReactor.suspendThisFiber(timeout);

        // Since we're the fiber management, the fiber should not be able to exit without going through this point
        DBG_ASSERT!"Fiber handle for %s became invalid while it slept"(ourHandle.isValid, ourHandle);
        DBG_ASSERT!"Fiber woke up from sleep without the sleep flag being reset"( ! ourHandle.get.flag!"SLEEPING" );

        // There are some (perverse) use cases where after wakeup the fiber queue is no longer valid. As such, make sure not to rely on any
        // member, which is why we disable:
        // ASSERT!"Fiber %s woken up but not removed from FiberQueue"(ourHandle.get !in waitingList, ourHandle);
    }

    static if( !Volatile ) {
        // We cannot provide a reliable resumeOne in a volatile FQ. In order to not trap innocent implementers, we disable the function
        // altogether.
        FiberHandle resumeOne(bool immediate=false) nothrow @safe @nogc {
            return internalResumeOne(immediate);
        }
    }

    void resumeAll() nothrow @safe @nogc {
        while( !empty ) {
            internalResumeOne(false);
        }
    }

    @property bool empty() const pure nothrow @nogc @safe {
        return waitingList.empty;
    }

private:
    FiberHandle internalResumeOne(bool immediate) nothrow @safe @nogc {
        ReactorFiber* wakeupFiber = waitingList.popHead;

        if (wakeupFiber is null)
            return FiberHandle.init;

        DBG_ASSERT!"FQ Trying to wake up %s which doesn't have SLEEPING set"(wakeupFiber.flag!"SLEEPING", wakeupFiber.identity);
        wakeupFiber.flag!"SLEEPING" = false;
        auto handle = FiberHandle( wakeupFiber );
        theReactor.resumeFiber( handle, immediate );

        return handle;
    }
}

alias VolatileFiberQueue = FiberQueueImpl!true;
alias FiberQueue = FiberQueueImpl!false;

unittest {
    INFO!"UT fiber queue basic tests"();
    import std.random;

    Mt19937 random;
    random.seed(unpredictableSeed);

    theReactor.setup();
    scope(exit) theReactor.teardown();

    FiberQueue fq;
    DEBUG!"Fiber queue at %s"( &fq );

    uint wokeup, timedout;

    void waiter() {
        try {
            Duration waitDuration = dur!"msecs"( uniform!"(]"(20, 200, random) );
            DEBUG!"Fiber %s waiting for %s"(theReactor.runningFiberHandle, waitDuration);
            fq.suspend( Timeout(waitDuration) );
            wokeup++;
        } catch( ReactorTimeout ex ) {
            timedout++;
            DEBUG!"%s timed out"(theReactor.runningFiberHandle);
        }
    }

    enum NumWaiters = 30;

    void framework() {
        theReactor.sleep(dur!"msecs"(70));

        FiberHandle handle;
        while( !fq.empty ) {
            handle = fq.resumeOne;
            assert(handle.isValid);
            DEBUG!"Woke up %s"(handle);
        }
        theReactor.yieldThisFiber;

        INFO!"Ran test with %s fibers timing out and %s waking up"(timedout, wokeup);
        assert( timedout + wokeup == NumWaiters, "Incorrect number of fibers finished");

        theReactor.stop();
    }

    foreach(i; 0..NumWaiters)
        theReactor.spawnFiber(&waiter);

    theReactor.spawnFiber(&framework);

    theReactor.start();
}

unittest {
    INFO!"UT test fiber exception during wake up"();
    theReactor.setup();
    scope(exit) theReactor.teardown();

    FiberQueue fq;
    uint finishedCount, exceptionCount;

    void workerFiber() {
        try {
            fq.suspend();
            finishedCount++;
        } catch(ReactorTimeout ex) {
            exceptionCount++;
        }
    }

    void framework() {
        /* The fibers desired itinerary:
           We wake up exactly one fiber, so exactly one fiber should wake up.
           fib1 - enters the FQ, woken up and also killed, counts as exception exit
           fib2 - enters the FQ, woken up
           fib3 - killed
           fib4 - never wakes up

           All in all, two deaths and one clean exit
         */
        FiberHandle fib1 = theReactor.spawnFiber(&workerFiber);
        theReactor.yieldThisFiber();
        FiberHandle fib2 = theReactor.spawnFiber(&workerFiber);
        theReactor.yieldThisFiber();
        FiberHandle fib3 = theReactor.spawnFiber(&workerFiber);
        theReactor.yieldThisFiber();
        FiberHandle fib4 = theReactor.spawnFiber(&workerFiber);
        theReactor.yieldThisFiber();

        // Both fibers sleeping
        fq.resumeOne();
        theReactor.throwInFiber!ReactorTimeout(fib1);
        theReactor.throwInFiber!ReactorTimeout(fib3);
        theReactor.yieldThisFiber();
        theReactor.yieldThisFiber();
        theReactor.yieldThisFiber();
        theReactor.yieldThisFiber();

        theReactor.stop();
    }

    theReactor.spawnFiber(&framework);
    theReactor.start();

    INFO!"finished count %s exception count %s"(finishedCount, exceptionCount);
    ASSERT!"Finished count not 1: %s"(finishedCount==1, finishedCount);
    ASSERT!"Exception count not 2: %s"(exceptionCount==2, exceptionCount);
}

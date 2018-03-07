/// Fiber queue helper for writing synchronization objects

// Authors: Shachar Shemesh
// Copyright: ©2017 Weka.io Ltd.
module mecca.reactor.sync.fiber_queue;

import mecca.containers.lists;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;

/**
  Implementation of the fiber queue.

  A fiber queue supports two basic operations: suspend, which causes a fiber to stop execution and wait in the queue, and resume, which wakes
  up one (or more) suspended fibers.

  As the name suggests, the queue maintains a strict FIFO order.

  This should not, typically, be used directly by client code. Instead, it is a helper for developing synchronization objects.

Params:
 Volatile = Sets whether suspend is supported in the case where the fiber queue itself goes out of context before all fibers wake up.
 */
struct FiberQueueImpl(bool Volatile) {
private:
    LinkedListWithOwner!(ReactorFiber*) waitingList;

public:
    @disable this(this);

    /** Suspends the current fiber until it is awoken.
        Params:
            timeout = How long to wait.
        Throws:
            TimeoutExpired if the timeout expires.

            Anything else if someone calls Reactor.throwInFiber
     */
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
        /** Resumes execution of one fiber.
         *
         * Unless there are no viable fibers in the queue, exactly one fiber will be resumed.
         *
         * Any fibers with pending exceptions (TimeoutExpired or anything else) do not count as viable, even if they are first in line to be
         * resumed.
         *
         * A volatile FiberQueue cannot provide a reliable resumeOne semantics. In order to not entrap innocent implementers, this method is
         * only available in the non-volatile version of the queue.
         *
         * Params:
         *    immediate = By default the fiber resumed is appended to the end of the scheduled fibers. Setting immediate to true causes
         *        it to be scheduled at the beginning of the queue.
         * Note:
         *    If the fibers at the head of the queue have pending exceptions, the fiber actually woken might be one that was not in the queue
         *    when resumeOne was originally called. Most of the time, this is the desired behavior. If not, this might result in a spurious
         *    wakeup.
         */
        FiberHandle resumeOne(bool immediate=false) nothrow @safe @nogc {
            return internalResumeOne(immediate);
        }
    }

    /** Resumes execution of all pending fibers
     */
    void resumeAll() nothrow @safe @nogc {
        while( !empty ) {
            internalResumeOne(false);
        }
    }

    /** Reports whether there are pending fibers in the queue.
        Returns: true if there are no pending fibers.
     */
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

/** A simple type for defining a volatile fiber queue.

  Please use with extreme care. Writing correct code with a volatile queue is a difficult task. Consider whether you really need it.
 */
alias VolatileFiberQueue = FiberQueueImpl!true;
/// A simple type for defining a non-volatile fiber queue.
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
            DEBUG!"Fiber %s waiting for %s"(theReactor.runningFiberHandle, waitDuration.toString);
            fq.suspend( Timeout(waitDuration) );
            wokeup++;
        } catch( TimeoutExpired ex ) {
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
        theReactor.yield;

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
        } catch(TimeoutExpired ex) {
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
        theReactor.yield();
        FiberHandle fib2 = theReactor.spawnFiber(&workerFiber);
        theReactor.yield();
        FiberHandle fib3 = theReactor.spawnFiber(&workerFiber);
        theReactor.yield();
        FiberHandle fib4 = theReactor.spawnFiber(&workerFiber);
        theReactor.yield();

        // Both fibers sleeping
        fq.resumeOne();
        theReactor.throwInFiber!TimeoutExpired(fib1);
        theReactor.throwInFiber!TimeoutExpired(fib3);
        theReactor.yield();
        theReactor.yield();
        theReactor.yield();
        theReactor.yield();

        theReactor.stop();
    }

    theReactor.spawnFiber(&framework);
    theReactor.start();

    INFO!"finished count %s exception count %s"(finishedCount, exceptionCount);
    ASSERT!"Finished count not 1: %s"(finishedCount==1, finishedCount);
    ASSERT!"Exception count not 2: %s"(exceptionCount==2, exceptionCount);
}

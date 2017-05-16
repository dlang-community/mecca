module mecca.reactor.sync;

import std.string;
import std.exception;

import mecca.lib.tracing;
import mecca.lib.time;
import mecca.containers.linked_set;
import mecca.reactor.fibers;
import mecca.reactor.reactor;


struct Suspender {
    package FiberHandle fib;
    version(assert) uint suspendCounter;

    void wait(Timeout timeout = Timeout.infinite) {
        assert (!fib.isValid, "Already set");
        fib = theReactor.thisFiber;
        auto f = fib.get();
        assert (f !is null, "Not called from fiber");
        scope(exit) fib = null;
        version (assert) suspendCounter = f.suspendCounter;
        theReactor.suspendThisFiber(timeout);
    }
    void wakeUp() {
        version (assert) {
            auto f = fib.get();
            assert (f is null || suspendCounter == f.suspendCounter,
                format("Wrong suspendCount %s, expected %s (fib=%s)", f.suspendCounter, suspendCounter, f.fiberId));
        }

        theReactor.resumeFiber(fib);
        fib = null;
    }
    @property bool isSet() const pure nothrow @nogc  {
        return fib.isValid;
    }
}

struct _FiberQueue(T) {
    static struct FiberChain {
        FiberHandle   fiber;
        static if (!is(T == void)) {
            T         payload;
        }
        Chain         _chain;

        @property bool isValid() const pure nothrow @nogc {
            return fiber.isValid();
        }
    }
    private LinkedSet!(FiberChain*) list;

    @property empty() const pure nothrow @nogc {
        return list.empty;
    }

    @notrace private void _enqueueAndSuspend(ref FiberChain chain, Timeout timeout = Timeout.infinite) {
        pragma(inline, true);
        scope(exit) list.remove(&chain);
        list.append(&chain);
        theReactor.suspendThisFiber(timeout);
    }

    static if (is(T == void)) {
        @notrace void enqueueAndSuspend(Timeout timeout = Timeout.infinite) {
            auto chain = FiberChain(theReactor.thisFiber);
            _enqueueAndSuspend(chain);
        }
    }
    else {
        @notrace void enqueueAndSuspend(T payload, Timeout timeout = Timeout.infinite) {
            auto chain = FiberChain(theReactor.thisFiber, payload);
            _enqueueAndSuspend(chain);
        }
    }

    @notrace auto popAndResume() {
        while (true) {
            FiberChain* chain = list.popHead();
            if (chain is null) {
                static if (is(T == void)) {
                    return FiberHandle.invalid;
                }
                else {
                    return null;
                }
            }
            else if (chain.fiber.isValid) {
                theReactor.resumeFiber(chain.fiber);
                static if (is(T == void)) {
                    return chain.fiber;
                }
                else {
                    return chain;
                }
            }
            // fetched a dead fiber, retry
        }
    }
}

alias FiberQueue = _FiberQueue!void;

struct Lock {
    private FiberHandle owner;
    private FiberQueue waiters;

    ~this() {
        assert(waiters.empty, "Lock destroyed but there fibers waiting on it");
    }

    @property bool isAcquired() const pure nothrow  {
        return owner.isValid;
    }
    @property FiberHandle getOwner() nothrow {
        return owner;
    }

    @notrace void acquire(Timeout timeout = Timeout.infinite) {
        if (!owner.isValid) {
            owner = theReactor.thisFiber;
        }
        else {
            auto fib = theReactor.thisFiber;
            scope(failure) {
                if (owner == fib) {
                    owner = waiters.popAndResume();
                }
            }
            waiters.enqueueAndSuspend(timeout);
            assert (owner == fib);
        }
    }

    @notrace bool tryAcquire() {
        if (!owner.isValid) {
            owner = theReactor.thisFiber;
            return true;
        }
        else {
            return false;
        }
    }

    @notrace void release() {
        assert (owner == theReactor.thisFiber);
        owner = waiters.popAndResume();
    }

    @notrace auto acquisition(Timeout timeout = Timeout.infinite) {
        static struct Acquisition {
            Lock* lock;

            @disable this(this);
            ~this() {
                assert (lock !is null);
                lock.release();
                lock = null;
            }
        }
        acquire(timeout);
        return Acquisition(&this);
    }
}

struct _Event(bool INITIAL) {
    private FiberQueue waiters;
    private bool _set = INITIAL;

    this(bool initiallySet) {
        _set = initiallySet;
    }
    ~this() {
        assert(waiters.empty, "Event destroyed but there fibers waiting on it");
    }

    @property bool hasWaiters() const pure nothrow @nogc {
        return !waiters.empty();
    }
    @property bool isSet() const pure nothrow @nogc {
        return _set;
    }

    @notrace void set() {
        _set = true;
        while (!waiters.empty) {
            waiters.popAndResume();
        }
    }
    @notrace void reset() {
        _set = false;
    }
    @notrace void signal() {
        set();
        reset();
    }
    @notrace void wait(Timeout timeout = Timeout.infinite) {
        if (!_set) {
            waiters.enqueueAndSuspend(timeout);
        }
    }
}

alias Event = _Event!false;
alias InitiallySetEvent = _Event!true;

struct Semaphore {
    private FiberQueue waiters;
    const uint max;
    private uint used;

    this(uint max, uint used = 0) {
        assert(max > 0, "max == 0");
        assert(used <= max, "used > max");
        this.max = max;
        this.used = used;
    }

    @notrace void release(uint howMuch = 1) {
        enforce(used >= howMuch, "Released too many times. used=%s release=%s".format(used, howMuch));
        used -= howMuch;
        while (!waiters.empty && used < max) {
            waiters.popAndResume();
            used++;
        }
    }

    @notrace void acquire(Timeout timeout = Timeout.infinite) {
        if (used < max) {
            used++;
        }
        else {
            waiters.enqueueAndSuspend(timeout);
        }
    }

    @property bool canAcquire() {
        return used < max;
    }
    @property uint numAvailable() {
        return used < max ? max - used : 0;
    }
    @property auto numUsed() {
        return used;
    }
}

struct Barrier {
    private InitiallySetEvent evt;
    private uint numWaiters;

    @notrace void addWaiter(uint count = 1) {
        assert (count > 0);
        evt.reset();
        numWaiters += count;
    }
    @notrace void markDone() {
        assert (numWaiters > 0, "numWaiters=0");
        numWaiters--;
        if (numWaiters == 0) {
            evt.set();
        }
    }
    void waitAll(Timeout timeout = Timeout.infinite) {
        if (numWaiters > 0) {
            evt.wait(timeout);
            assert (numWaiters == 0, "numWaiters=%s".format(numWaiters));
        }
    }
}

struct RWLock {
    _FiberQueue!bool waiters;
    waiters.FiberChain owner;

    void acquireRead(Timeout timeout = Timeout.infinite) {
        assert (false);
    }
    void acquireWrite(Timeout timeout = Timeout.infinite) {
        assert (false);
    }
    void release() {
        assert (false);
    }
}





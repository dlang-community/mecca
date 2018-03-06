/// Set deadline for specific code execution
module mecca.reactor.sync.time_bomb;

import mecca.log;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.reactor;

/// Exception thrown if the deadline expired
class TimeBombExploded : Exception {
    this(string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow @nogc {
        super("Time bomb exploded", file, line, next);
    }
}

private @notrace void timeBombCallback(FiberHandle fib, TimerHandle* timebombHandle) {
    if (fib.isValid) {
        theReactor.WARN_AS!"TimeBomb expired"(fib);
        timebombHandle.reset;
        theReactor.throwInFiber!TimeBombExploded(fib);
    }
}

/// Set a deadline for code execution
struct TimeBomb {
private:
    TimerHandle timebombHandle;

public:
    @disable this(this);

    /// Construct and arm the time bomb
    this(Duration timeout) {
        timebombHandle = theReactor.registerTimer!timeBombCallback(
                Timeout(timeout), theReactor.currentFiberHandle, &timebombHandle);
    }

    ~this() {
        if (timebombHandle.isValid) {
            theReactor.cancelTimer(timebombHandle);
            timebombHandle.reset();
        }
    }
}

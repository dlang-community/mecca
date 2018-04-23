/// Type definitions for reactor related types
module mecca.reactor.types;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.lib.exception;
import mecca.lib.typedid;

/// Fibers' ID type
alias FiberId = TypedIdentifier!("FiberId", ushort, ushort.max, ushort.max);

/// Exception thrown when a fiber is suspended for too long.
class TimeoutExpired : Exception {
    this(string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow @nogc {
        super("Reactor timed out on a timed suspend", file, line, next);
    }
}

/**
  Base class for interrupting a fiber operation.

  This is the base class for exceptions that need to interrupt the operation of a fiber. This is the only type of
  exception allowed to escape the fiber code (any other type will be rethrown out of the reactor itself).

  It is discouraged to catch `FiberInterrupt` directly. If you do, please be sure to rethrow it.

  Catching custom classes that derive from `FiberInterrupt` is permitted.
 */
class FiberInterrupt : Throwable {
    mixin ExceptionBody;
}

class ReactorExit : FiberInterrupt {
    mixin ExceptionBody!("Reactor is quitting");
}


module mecca.log.impl;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(MeccaAlternateLogger) {
    static if( __traits(compiles, import("MeccaAlternateLoggerImpl.txt")) ) {
        mixin("public import " ~ import("MeccaAlternateLoggerImpl.txt") ~ ";");
    }
} else {
import mecca.reactor.types;

/* thread local */ char[4] logSource = "MAIN";
alias LogsFiberSavedContext = void[0];

void logSwitchFiber( LogsFiberSavedContext* ctx, FiberId newFiberId ) nothrow @safe @nogc {
    pragma(inline, true);

    auto id = newFiberId.value;
    if (id == 0) {
        logSource = "MAIN";
    }
    else if (id == 1) {
        logSource = "IDLE";
    }
    else {
        logSource[0] = "0123456789abcdef"[(id >> 12) & 0xf];
        logSource[1] = "0123456789abcdef"[(id >> 8) & 0xf];
        logSource[2] = "0123456789abcdef"[(id >> 4) & 0xf];
        logSource[3] = "0123456789abcdef"[id & 0xf];
    }
}
}

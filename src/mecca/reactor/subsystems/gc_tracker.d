/**
 * This module is used to track who, when and how much fibers use the GC. This module is disabled by default.
 * Compile with --version=gc_tracker to enable.
 */
module mecca.reactor.subsystems.gc_tracker;

import mecca.lib.exception;
import mecca.log;
import mecca.reactor.reactor;


private __gshared bool gcTrackerEnabled = false;
// This is the log malloc call function we'll have to override!
private extern (C) __gshared extern void function(void *p, size_t size) nothrow g_log_malloc_call;


/**
 * Global enable/disable of tracking GC operations by fibers.
 */
void enableGCTracking() {
    //g_log_malloc_call = &logGCMallocCalls;
    gcTrackerEnabled = true;
}
void disableGCTracking() {
    //g_log_malloc_call = null;
    gcTrackerEnabled = false;
}

/**
 * Per-fiber enable/disable of GC tracking.
 */
void disableGCTrackingForFiber() nothrow @safe @nogc {
    ASSERT!"Cannot disable GC tracking for fiber when not on the main thread"(isReactorThread);
    ASSERT!"Cannot disable GC tracking for special fibers"(theReactor.isSpecialFiber);
    theReactor.runningFiberPtr.flag!"GC_ENABLED" = true;
}
void enableGCTrackingForFiber() nothrow @safe @nogc {
    ASSERT!"Cannot disable GC tracking for fiber when not on the main thread"(isReactorThread);
    ASSERT!"Cannot disable GC tracking for special fibers"(theReactor.isSpecialFiber);
    theReactor.runningFiberPtr.flag!"GC_ENABLED" = false;
}

extern (C) void logGCMallocCalls(void* p, size_t size) nothrow {
    if (!gcTrackerEnabled) {
        return;
    }
    if (!isReactorThread) {
        LOG_STACK!"#GC allocating from a thread"();
    }
    else if ( theReactor.runningFiberPtr.flag!"GC_ENABLED") {
        LOG_STACK!"#GC allocating from a fiber (size=%s addr=%s)"(size, p);
    }
}

unittest {
    enableGCTracking();
    scope(exit) disableGCTracking();
    testWithReactor({
        int[] a;

        a ~= 12;
        DEBUG!"12 = %s"(a[0]);
    });
}



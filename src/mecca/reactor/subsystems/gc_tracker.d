/**
  This module is used to track who, when and how much fibers use the GC. This module is disabled by default.
  Compile with --version=gc_tracker to enable.
 */
module mecca.reactor.subsystems.gc_tracker;

import core.atomic;

import mecca.lib.exception;
import mecca.log;
import mecca.reactor.reactor;

private __gshared bool gcTrackerEnabled = false;
private enum ALLOCATIONS_TO_SKIP = 0;

/**
  Global enable/disable of tracking GC operations by fibers.
 */
void enableGcTracking(bool enable) {
    gcTrackerEnabled = true;
}

/**
  Exclude a single fiber from GC tracking.
 */
void disableGCTrackingForFiber() nothrow @safe @nogc
{
    ASSERT!"Cannot disable GC tracking for fiber when not on the main thread"(isReactorThread);
    ASSERT!"Cannot disable GC tracking for special fibers"(theReactor.isSpecialFiber);
    theReactor.runningFiberPtr.flag!"GC_ENABLED" = true;
}

/**
  Re-enable single fiber GC tracking
 */
void enableGCTrackingForFiber() nothrow @safe @nogc
{
    ASSERT!"Cannot disable GC tracking for fiber when not on the main thread"(isReactorThread);
    ASSERT!"Cannot disable GC tracking for special fibers"(theReactor.isSpecialFiber);
    theReactor.runningFiberPtr.flag!"GC_ENABLED" = false;
}

// This is the log malloc call function we'll have to override!
extern (C) __gshared extern void function(void *p, size_t size) nothrow g_log_malloc_call;

/*
 * This will be called from the gc malloc code. Will log any allocations that happen inside a fiber.
 * In the future, we'll also be able to disallow any alloctions at all unless explicitly permitted.
 */
extern (C)  void logGCMallocCalls(void * p, size_t size) nothrow {
    if (!gcTrackerEnabled) {
        return;
    }
    __gshared static int fiberAllocations = 0; // Only one thread writes to these, so no sync needed
    shared static int nonFiberAllocations = 0;

    if (!isReactorThread()) {
        // We're not in a fiber, quit
        if (atomicOp!"+="(nonFiberAllocations, 1) > ALLOCATIONS_TO_SKIP) {
            DEBUG!"log #GC NOFIB malloc call called not from a fiber. size %s addr %s"(size,p);
            // On non-release builds, we should skip 2 frames, but with release builds it's inconsistent.
            dumpStackTrace("#GC allocating from outside a fiber!");
        }
        return;
    }

    if (theReactor.runningFiberPtr.flag!"GC_ENABLED") {
        return;
    }

    if (++fiberAllocations < ALLOCATIONS_TO_SKIP) {
        //DEBUG!"Not logging first 30k fiber allocations. size %s addr %s allocations# %s"(size, p, fiberAllocations);
        return;
    }
    WARN!"Going to #GC alloc from fiber:  %d bytes to addr %s fiberAllocations %s"( size, p, fiberAllocations);
    // TODO: Add a manhole API that enables and disables the dumping of stack traces
    dumpStackTrace("#GC allocating from within a fiber!"); // On non-release builds, we should skip 2 frames, but with release builds it's inconsistent.
    //WARN!"Finished dumping the stack of the fiber #GC alloc."();
}

unittest {
    enableGcTracking(true);
    testWithReactor({
            int[] a;
            
            a ~= 12;
            DEBUG!"12 = %s"(a[0]);
            });
}

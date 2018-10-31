module mecca.platform.os.darwin;

import core.sys.posix.sys.types : pthread_t;

package(mecca):

// This does not exist on Darwin platforms. We'll just use a value that won't
// have any affect when used together with mmap.
enum MAP_POPULATE = 0;

/**
 * Represents the ID of a thread.
 *
 * This type is platform dependent.
 */
alias ThreadId = ulong;

extern (C) private int pthread_threadid_np(pthread_t, ulong*) nothrow;

/// Returns: the current thread ID
ThreadId currentThreadId() @system nothrow
{
    import mecca.lib.exception : ASSERT;

    enum assertMessage = "pthread_threadid_np failed, should not happen";

    ulong threadId;
    ASSERT!"assertMessage"(pthread_threadid_np(null, &threadId) == 0);

    return threadId;
}

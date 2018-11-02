module mecca.platform.os.darwin;

version (Darwin):
package(mecca):

public import mecca.platform.os.darwin.time;

import core.sys.posix.sys.types : pthread_t;

// This does not exist on Darwin platforms. We'll just use a value that won't
// have any affect when used together with mmap.
enum MAP_POPULATE = 0;

///
enum OSSignal
{
    SIGNONE = 0, /// invalid
    SIGHUP = 1, /// hangup
    SIGINT = 2, /// interrupt
    SIGQUIT = 3, /// quit
    SIGILL = 4, /// illegal instruction (not reset when caught)
    SIGTRAP = 5, /// trace trap (not reset when caught)
    SIGABRT = 6, /// abort()
    SIGIOT = SIGABRT, /// compatibility
    SIGEMT = 7, /// EMT instruction
    SIGFPE = 8, /// floating point exception
    SIGKILL = 9, /// kill (cannot be caught or ignored)
    SIGBUS = 10, /// bus error
    SIGSEGV = 11, /// segmentation violation
    SIGSYS = 12, /// bad argument to system call
    SIGPIPE = 13, /// write on a pipe with no one to read it
    SIGALRM = 14, /// alarm clock
    SIGTERM = 15, /// software termination signal from kill
    SIGURG = 16, /// urgent condition on IO channel
    SIGSTOP = 17, /// sendable stop signal not from tty
    SIGTSTP = 18, /// stop signal from tty
    SIGCONT = 19, /// continue a stopped process
    SIGCHLD = 20, /// to parent on child stop or exit
    SIGTTIN = 21, /// to readers pgrp upon background tty read
    SIGTTOU = 22, /// like TTIN for output if (tp->t_local&LTOSTOP)
    SIGIO = 23, /// input/output possible signal
    SIGXCPU = 24, /// exceeded CPU time limit
    SIGXFSZ = 25, /// exceeded file size limit
    SIGVTALRM = 26, /// virtual time alarm
    SIGPROF = 27, /// profiling time alarm
    SIGWINCH = 28, /// window size changes
    SIGINFO = 29, /// information request
    SIGUSR1 = 30, /// user defined signal 1
    SIGUSR2 = 31 /// user defined signal 2
}

/**
 * Represents the ID of a thread.
 *
 * This type is platform dependent.
 */
alias ThreadId = ulong;

__gshared static immutable BLOCKED_SIGNALS = [
    OSSignal.SIGHUP, OSSignal.SIGINT, OSSignal.SIGQUIT,
    //OSSignal.SIGILL, OSSignal.SIGTRAP, OSSignal.SIGABRT,
    //OSSignal.SIGBUS, OSSignal.SIGFPE, OSSignal.SIGKILL,
    //OSSignal.SIGUSR1, OSSignal.SIGSEGV, OSSignal.SIGUSR2,
    OSSignal.SIGPIPE, OSSignal.SIGALRM, OSSignal.SIGTERM,
    //OSSignal.SIGSTKFLT, OSSignal.SIGCONT, OSSignal.SIGSTOP,
    OSSignal.SIGCHLD, OSSignal.SIGTSTP, OSSignal.SIGTTIN,
    OSSignal.SIGTTOU, OSSignal.SIGURG, OSSignal.SIGXCPU,
    OSSignal.SIGXFSZ, OSSignal.SIGVTALRM, OSSignal.SIGPROF,
    OSSignal.SIGWINCH, OSSignal.SIGIO,
    //OSSignal.SIGSYS,
];

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

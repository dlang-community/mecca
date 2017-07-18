module mecca.lib.lowlevel;

version(linux):
version(X86_64):

private enum NR_gettid = 186;

extern(C) nothrow @system @nogc {
    int syscall(int number, ...);

    int gettid() {
        return syscall(NR_gettid);
    }
}

unittest {
    import core.thread: thread_isMainThread;
    import core.sys.posix.unistd: getpid;
    assert (thread_isMainThread());
    assert (gettid() == getpid());
}

enum Signal: int {
    SIGHUP         = 1,       /* Hangup (POSIX).  */
    SIGINT         = 2,       /* Interrupt (ANSI).  */
    SIGQUIT        = 3,       /* Quit (POSIX).  */
    SIGILL         = 4,       /* Illegal instruction (ANSI).  */
    SIGTRAP        = 5,       /* Trace trap (POSIX).  */
    SIGABRT        = 6,       /* Abort (ANSI).  */
    SIGBUS         = 7,       /* BUS error (4.2 BSD).  */
    SIGFPE         = 8,       /* Floating-point exception (ANSI).  */
    SIGKILL        = 9,       /* Kill, unblockable (POSIX).  */
    SIGUSR1        = 10,      /* User-defined signal 1 (POSIX).  */
    SIGSEGV        = 11,      /* Segmentation violation (ANSI).  */
    SIGUSR2        = 12,      /* User-defined signal 2 (POSIX).  */
    SIGPIPE        = 13,      /* Broken pipe (POSIX).  */
    SIGALRM        = 14,      /* Alarm clock (POSIX).  */
    SIGTERM        = 15,      /* Termination (ANSI).  */
    SIGSTKFLT      = 16,      /* Stack fault.  */
    SIGCHLD        = 17,      /* Child status has changed (POSIX).  */
    SIGCONT        = 18,      /* Continue (POSIX).  */
    SIGSTOP        = 19,      /* Stop, unblockable (POSIX).  */
    SIGTSTP        = 20,      /* Keyboard stop (POSIX).  */
    SIGTTIN        = 21,      /* Background read from tty (POSIX).  */
    SIGTTOU        = 22,      /* Background write to tty (POSIX).  */
    SIGURG         = 23,      /* Urgent condition on socket (4.2 BSD).  */
    SIGXCPU        = 24,      /* CPU limit exceeded (4.2 BSD).  */
    SIGXFSZ        = 25,      /* File size limit exceeded (4.2 BSD).  */
    SIGVTALRM      = 26,      /* Virtual alarm clock (4.2 BSD).  */
    SIGPROF        = 27,      /* Profiling alarm clock (4.2 BSD).  */
    SIGWINCH       = 28,      /* Window size change (4.3 BSD, Sun).  */
    SIGIO          = 29,      /* I/O now possible (4.2 BSD).  */
    SIGPWR         = 30,      /* Power failure restart (System V).  */
    SIGSYS         = 31,      /* Bad system call.  */
}

enum NUM_SIGS = 65; /* _NSIG: Biggest signal number + 1 (including real-time signals).  */

public import core.sys.posix.signal: SIGRTMIN, SIGRTMAX;

/+version(LDC) {
    private pure pragma(LDC_intrinsic, "llvm.x86.sse42.crc32.64.64") ulong crc32(ulong crc, ulong v) nothrow @safe @nogc;
}

uint crc32c(ulong crc, ulong v) @nogc nothrow @system {
    if (__ctfe) {
        return 0;
    } else {
        version(LDC) {
            return cast(uint)crc32(crc, v);
        } else {
            return 0;
        }
    }
}

unittest {
    ulong crc = 0x000011115555AAAA;
    ulong v = 0x88889999EEEE3333;

    assert(crc32c(crc, v) == 0x16f57621);
    v = 0x00000000EEEE3333;
    assert(crc32c(crc, v) == 0x8e5d3bf9);
}
+/

/+
mixin template hookSyscall(alias F, int nr, alias preFunc) {
    import std.traits: Parameters;
    enum name = __traits(identifier, F);
    mixin("extern(C) pragma(mangle, \"" ~ name ~ "\") @system int " ~ name ~ "(Parameters!F args) {
            preFunc(args);
            return syscall(nr, args);
        }"
    );
}

version (unittest) {
    __gshared bool hitPreFunc = false;

    static import core.sys.posix.unistd;
    mixin hookSyscall!(core.sys.posix.unistd.close, 3, (int fd){hitPreFunc = true;});

    unittest {
        import std.stdio;
        auto f = File("/tmp/test", "w");
        f.close();
        assert (hitPreFunc);
    }
}
+/




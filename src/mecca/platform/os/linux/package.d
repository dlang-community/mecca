/// Linux platform specific functions
module mecca.platform.os.linux;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.log: notrace;

version(linux):
version(X86_64):

public import mecca.platform.os.linux.ucontext;
public import mecca.platform.os.linux.time;

enum Syscall: int {
    NR_read = 0,
    NR_write = 1,
    NR_open = 2,
    NR_close = 3,
    NR_stat = 4,
    NR_fstat = 5,
    NR_lstat = 6,
    NR_poll = 7,
    NR_lseek = 8,
    NR_mmap = 9,
    NR_mprotect = 10,
    NR_munmap = 11,
    NR_brk = 12,
    NR_rt_sigaction = 13,
    NR_rt_sigprocmask = 14,
    NR_rt_sigreturn = 15,
    NR_ioctl = 16,
    NR_pread64 = 17,
    NR_pwrite64 = 18,
    NR_readv = 19,
    NR_writev = 20,
    NR_access = 21,
    NR_pipe = 22,
    NR_select = 23,
    NR_sched_yield = 24,
    NR_mremap = 25,
    NR_msync = 26,
    NR_mincore = 27,
    NR_madvise = 28,
    NR_shmget = 29,
    NR_shmat = 30,
    NR_shmctl = 31,
    NR_dup = 32,
    NR_dup2 = 33,
    NR_pause = 34,
    NR_nanosleep = 35,
    NR_getitimer = 36,
    NR_alarm = 37,
    NR_setitimer = 38,
    NR_getpid = 39,
    NR_sendfile = 40,
    NR_socket = 41,
    NR_connect = 42,
    NR_accept = 43,
    NR_sendto = 44,
    NR_recvfrom = 45,
    NR_sendmsg = 46,
    NR_recvmsg = 47,
    NR_shutdown = 48,
    NR_bind = 49,
    NR_listen = 50,
    NR_getsockname = 51,
    NR_getpeername = 52,
    NR_socketpair = 53,
    NR_setsockopt = 54,
    NR_getsockopt = 55,
    NR_clone = 56,
    NR_fork = 57,
    NR_vfork = 58,
    NR_execve = 59,
    NR_exit = 60,
    NR_wait4 = 61,
    NR_kill = 62,
    NR_uname = 63,
    NR_semget = 64,
    NR_semop = 65,
    NR_semctl = 66,
    NR_shmdt = 67,
    NR_msgget = 68,
    NR_msgsnd = 69,
    NR_msgrcv = 70,
    NR_msgctl = 71,
    NR_fcntl = 72,
    NR_flock = 73,
    NR_fsync = 74,
    NR_fdatasync = 75,
    NR_truncate = 76,
    NR_ftruncate = 77,
    NR_getdents = 78,
    NR_getcwd = 79,
    NR_chdir = 80,
    NR_fchdir = 81,
    NR_rename = 82,
    NR_mkdir = 83,
    NR_rmdir = 84,
    NR_creat = 85,
    NR_link = 86,
    NR_unlink = 87,
    NR_symlink = 88,
    NR_readlink = 89,
    NR_chmod = 90,
    NR_fchmod = 91,
    NR_chown = 92,
    NR_fchown = 93,
    NR_lchown = 94,
    NR_umask = 95,
    NR_gettimeofday = 96,
    NR_getrlimit = 97,
    NR_getrusage = 98,
    NR_sysinfo = 99,
    NR_times = 100,
    NR_ptrace = 101,
    NR_getuid = 102,
    NR_syslog = 103,
    NR_getgid = 104,
    NR_setuid = 105,
    NR_setgid = 106,
    NR_geteuid = 107,
    NR_getegid = 108,
    NR_setpgid = 109,
    NR_getppid = 110,
    NR_getpgrp = 111,
    NR_setsid = 112,
    NR_setreuid = 113,
    NR_setregid = 114,
    NR_getgroups = 115,
    NR_setgroups = 116,
    NR_setresuid = 117,
    NR_getresuid = 118,
    NR_setresgid = 119,
    NR_getresgid = 120,
    NR_getpgid = 121,
    NR_setfsuid = 122,
    NR_setfsgid = 123,
    NR_getsid = 124,
    NR_capget = 125,
    NR_capset = 126,
    NR_rt_sigpending = 127,
    NR_rt_sigtimedwait = 128,
    NR_rt_sigqueueinfo = 129,
    NR_rt_sigsuspend = 130,
    NR_sigaltstack = 131,
    NR_utime = 132,
    NR_mknod = 133,
    NR_uselib = 134,
    NR_personality = 135,
    NR_ustat = 136,
    NR_statfs = 137,
    NR_fstatfs = 138,
    NR_sysfs = 139,
    NR_getpriority = 140,
    NR_setpriority = 141,
    NR_sched_setparam = 142,
    NR_sched_getparam = 143,
    NR_sched_setscheduler = 144,
    NR_sched_getscheduler = 145,
    NR_sched_get_priority_max = 146,
    NR_sched_get_priority_min = 147,
    NR_sched_rr_get_interval = 148,
    NR_mlock = 149,
    NR_munlock = 150,
    NR_mlockall = 151,
    NR_munlockall = 152,
    NR_vhangup = 153,
    NR_modify_ldt = 154,
    NR_pivot_root = 155,
    NR__sysctl = 156,
    NR_prctl = 157,
    NR_arch_prctl = 158,
    NR_adjtimex = 159,
    NR_setrlimit = 160,
    NR_chroot = 161,
    NR_sync = 162,
    NR_acct = 163,
    NR_settimeofday = 164,
    NR_mount = 165,
    NR_umount2 = 166,
    NR_swapon = 167,
    NR_swapoff = 168,
    NR_reboot = 169,
    NR_sethostname = 170,
    NR_setdomainname = 171,
    NR_iopl = 172,
    NR_ioperm = 173,
    NR_create_module = 174,
    NR_init_module = 175,
    NR_delete_module = 176,
    NR_get_kernel_syms = 177,
    NR_query_module = 178,
    NR_quotactl = 179,
    NR_nfsservctl = 180,
    NR_getpmsg = 181,
    NR_putpmsg = 182,
    NR_afs_syscall = 183,
    NR_tuxcall = 184,
    NR_security = 185,
    NR_gettid = 186,
    NR_readahead = 187,
    NR_setxattr = 188,
    NR_lsetxattr = 189,
    NR_fsetxattr = 190,
    NR_getxattr = 191,
    NR_lgetxattr = 192,
    NR_fgetxattr = 193,
    NR_listxattr = 194,
    NR_llistxattr = 195,
    NR_flistxattr = 196,
    NR_removexattr = 197,
    NR_lremovexattr = 198,
    NR_fremovexattr = 199,
    NR_tkill = 200,
    NR_time = 201,
    NR_futex = 202,
    NR_sched_setaffinity = 203,
    NR_sched_getaffinity = 204,
    NR_set_thread_area = 205,
    NR_io_setup = 206,
    NR_io_destroy = 207,
    NR_io_getevents = 208,
    NR_io_submit = 209,
    NR_io_cancel = 210,
    NR_get_thread_area = 211,
    NR_lookup_dcookie = 212,
    NR_epoll_create = 213,
    NR_epoll_ctl_old = 214,
    NR_epoll_wait_old = 215,
    NR_remap_file_pages = 216,
    NR_getdents64 = 217,
    NR_set_tid_address = 218,
    NR_restart_syscall = 219,
    NR_semtimedop = 220,
    NR_fadvise64 = 221,
    NR_timer_create = 222,
    NR_timer_settime = 223,
    NR_timer_gettime = 224,
    NR_timer_getoverrun = 225,
    NR_timer_delete = 226,
    NR_clock_settime = 227,
    NR_clock_gettime = 228,
    NR_clock_getres = 229,
    NR_clock_nanosleep = 230,
    NR_exit_group = 231,
    NR_epoll_wait = 232,
    NR_epoll_ctl = 233,
    NR_tgkill = 234,
    NR_utimes = 235,
    NR_vserver = 236,
    NR_mbind = 237,
    NR_set_mempolicy = 238,
    NR_get_mempolicy = 239,
    NR_mq_open = 240,
    NR_mq_unlink = 241,
    NR_mq_timedsend = 242,
    NR_mq_timedreceive = 243,
    NR_mq_notify = 244,
    NR_mq_getsetattr = 245,
    NR_kexec_load = 246,
    NR_waitid = 247,
    NR_add_key = 248,
    NR_request_key = 249,
    NR_keyctl = 250,
    NR_ioprio_set = 251,
    NR_ioprio_get = 252,
    NR_inotify_init = 253,
    NR_inotify_add_watch = 254,
    NR_inotify_rm_watch = 255,
    NR_migrate_pages = 256,
    NR_openat = 257,
    NR_mkdirat = 258,
    NR_mknodat = 259,
    NR_fchownat = 260,
    NR_futimesat = 261,
    NR_newfstatat = 262,
    NR_unlinkat = 263,
    NR_renameat = 264,
    NR_linkat = 265,
    NR_symlinkat = 266,
    NR_readlinkat = 267,
    NR_fchmodat = 268,
    NR_faccessat = 269,
    NR_pselect6 = 270,
    NR_ppoll = 271,
    NR_unshare = 272,
    NR_set_robust_list = 273,
    NR_get_robust_list = 274,
    NR_splice = 275,
    NR_tee = 276,
    NR_sync_file_range = 277,
    NR_vmsplice = 278,
    NR_move_pages = 279,
    NR_utimensat = 280,
    NR_epoll_pwait = 281,
    NR_signalfd = 282,
    NR_timerfd_create = 283,
    NR_eventfd = 284,
    NR_fallocate = 285,
    NR_timerfd_settime = 286,
    NR_timerfd_gettime = 287,
    NR_accept4 = 288,
    NR_signalfd4 = 289,
    NR_eventfd2 = 290,
    NR_epoll_create1 = 291,
    NR_dup3 = 292,
    NR_pipe2 = 293,
    NR_inotify_init1 = 294,
    NR_preadv = 295,
    NR_pwritev = 296,
    NR_rt_tgsigqueueinfo = 297,
    NR_perf_event_open = 298,
    NR_recvmmsg = 299,
    NR_fanotify_init = 300,
    NR_fanotify_mark = 301,
    NR_prlimit64 = 302,
    NR_name_to_handle_at = 303,
    NR_open_by_handle_at = 304,
    NR_clock_adjtime = 305,
    NR_syncfs = 306,
    NR_sendmmsg = 307,
    NR_setns = 308,
    NR_getcpu = 309,
    NR_process_vm_readv = 310,
    NR_process_vm_writev = 311,
    NR_kcmp = 312,
    NR_finit_module = 313,
    NR_sched_setattr = 314,
    NR_sched_getattr = 315,
    NR_renameat2 = 316,
    NR_seccomp = 317,
}

extern(C) nothrow @system @nogc {
    long syscall(int number, ...) nothrow;

    @notrace
    int syscall_int(ARGS...)(int number, auto ref ARGS args) nothrow {
        return cast(int)syscall(number, args);
    }

    @notrace
    int gettid() nothrow @trusted {
        return syscall_int(Syscall.NR_gettid);
    }

    @notrace
    int tgkill(int tgid, int tid, int sig) nothrow @trusted {
        return syscall_int(Syscall.NR_tgkill, tgid, tid, sig);
    }
}

unittest {
    import core.thread: thread_isMainThread;
    import core.sys.posix.unistd: getpid;
    assert (thread_isMainThread());
    assert (gettid() == getpid());
}

enum OSSignal: uint {
    SIGNONE        = 0,       /// Invalid signal
    SIGHUP         = 1,       /// Hangup (POSIX).
    SIGINT         = 2,       /// Interrupt (ANSI).
    SIGQUIT        = 3,       /// Quit (POSIX).
    SIGILL         = 4,       /// Illegal instruction (ANSI).
    SIGTRAP        = 5,       /// Trace trap (POSIX).
    SIGABRT        = 6,       /// Abort (ANSI).
    SIGBUS         = 7,       /// BUS error (4.2 BSD).
    SIGFPE         = 8,       /// Floating-point exception (ANSI).
    SIGKILL        = 9,       /// Kill, unblockable (POSIX).
    SIGUSR1        = 10,      /// User-defined signal 1 (POSIX).
    SIGSEGV        = 11,      /// Segmentation violation (ANSI).
    SIGUSR2        = 12,      /// User-defined signal 2 (POSIX).
    SIGPIPE        = 13,      /// Broken pipe (POSIX).
    SIGALRM        = 14,      /// Alarm clock (POSIX).
    SIGTERM        = 15,      /// Termination (ANSI).
    SIGSTKFLT      = 16,      /// Stack fault.
    SIGCHLD        = 17,      /// Child status has changed (POSIX).
    SIGCONT        = 18,      /// Continue (POSIX).
    SIGSTOP        = 19,      /// Stop, unblockable (POSIX).
    SIGTSTP        = 20,      /// Keyboard stop (POSIX).
    SIGTTIN        = 21,      /// Background read from tty (POSIX).
    SIGTTOU        = 22,      /// Background write to tty (POSIX).
    SIGURG         = 23,      /// Urgent condition on socket (4.2 BSD).
    SIGXCPU        = 24,      /// CPU limit exceeded (4.2 BSD).
    SIGXFSZ        = 25,      /// File size limit exceeded (4.2 BSD).
    SIGVTALRM      = 26,      /// Virtual alarm clock (4.2 BSD).
    SIGPROF        = 27,      /// Profiling alarm clock (4.2 BSD).
    SIGWINCH       = 28,      /// Window size change (4.3 BSD, Sun).
    SIGIO          = 29,      /// I/O now possible (4.2 BSD).
    SIGPOLL        = SIGIO,   /// ditto
    SIGPWR         = 30,      /// Power failure restart (System V).
    SIGSYS         = 31,      /// Bad system call.
}

/* _NSIG: Biggest signal number + 1 (including real-time signals).  */
enum NUM_SIGS = 65;

public import core.sys.posix.signal: SIGRTMIN, SIGRTMAX;

unittest {
    assert (SIGRTMIN > OSSignal.SIGSYS);
    assert (SIGRTMAX < NUM_SIGS);
}


extern(C) nothrow /*@nogc*/ {
    public alias CloneFunction = extern(C) int function(void*) nothrow /*@nogc*/;
    public int clone(CloneFunction fn, void* child_stack, int flags, void* args);
    public int unshare(int flags);
    public int chroot(const char* dirname);
    public enum {
        CSIGNAL                 = 0x000000ff,     // signal mask to be sent at exit
        CLONE_VM                = 0x00000100,     // set if VM shared between processes
        CLONE_FS                = 0x00000200,     // set if fs info shared between processes
        CLONE_FILES             = 0x00000400,     // set if open files shared between processes
        CLONE_SIGHAND           = 0x00000800,     // set if signal handlers and blocked signals shared
        CLONE_PTRACE            = 0x00002000,     // set if we want to let tracing continue on the child too
        CLONE_VFORK             = 0x00004000,     // set if the parent wants the child to wake it up on mm_release
        CLONE_PARENT            = 0x00008000,     // set if we want to have the same parent as the cloner
        CLONE_THREAD            = 0x00010000,     // Same thread group?
        CLONE_NEWNS             = 0x00020000,     // New namespace group?
        CLONE_SYSVSEM           = 0x00040000,     // share system V SEM_UNDO semantics
        CLONE_SETTLS            = 0x00080000,     // create a new TLS for the child
        CLONE_PARENT_SETTID     = 0x00100000,     // set the TID in the parent
        CLONE_CHILD_CLEARTID    = 0x00200000,     // clear the TID in the child
        CLONE_DETACHED          = 0x00400000,     // Unused, ignored
        CLONE_UNTRACED          = 0x00800000,     // set if the tracing process can't force CLONE_PTRACE on this clone
        CLONE_CHILD_SETTID      = 0x01000000,     // set the TID in the child
        CLONE_NEWUTS            = 0x04000000,     // New utsname group?
        CLONE_NEWIPC            = 0x08000000,     // New ipcs
        CLONE_NEWUSER           = 0x10000000,     // New user namespace
        CLONE_NEWPID            = 0x20000000,     // New pid namespace
        CLONE_NEWNET            = 0x40000000,     // New network namespace
        CLONE_IO                = 0x80000000,     // Clone io context
    }

    public int mount(in char* __special_file, in char* __dir, in char* __fstype, ulong __rwflag, in void* __data);
    public int umount(in char* target);
    public int umount2(in char* target, int flags);
    public enum MountOptions {
        MS_RDONLY = 1,                // Mount read-only.
        MS_NOSUID = 2,                // Ignore suid and sgid bits.
        MS_NODEV = 4,                 // Disallow access to device special files.
        MS_NOEXEC = 8,                // Disallow program execution.
        MS_SYNCHRONOUS = 16,          // Writes are synced at once.
        MS_REMOUNT = 32,              // Alter flags of a mounted FS.
        MS_MANDLOCK = 64,             // Allow mandatory locks on an FS.
        MS_DIRSYNC = 128,             // Directory modifications are synchronous.
        MS_NOATIME = 1024,            // Do not update access times.
        MS_NODIRATIME = 2048,         // Do not update directory access times.
        MS_BIND = 4096,               // Bind directory at different place.
        MS_MOVE = 8192,
        MS_REC = 16384,
        MS_SILENT = 32768,
        MS_POSIXACL = 1 << 16,        // VFS does not apply the umask.
        MS_UNBINDABLE = 1 << 17,      // Change to unbindable.
        MS_PRIVATE = 1 << 18,         // Change to private.
        MS_SLAVE = 1 << 19,           // Change to slave.
        MS_SHARED = 1 << 20,          // Change to shared.
        MS_RELATIME = 1 << 21,        // Update atime relative to mtime/ctime.
        MS_KERNMOUNT = 1 << 22,       // This is a kern_mount call.
        MS_I_VERSION =  1 << 23,      // Update inode I_version field.
        MS_STRICTATIME = 1 << 24,     // Always perform atime updates.
        MS_ACTIVE = 1 << 30,
        MS_NOUSER = 1 << 31
    }
    public enum {
        MNT_FORCE = 1,                /* Force unmounting.  */
        MNT_DETACH = 2,               /* Just detach from the tree.  */
        MNT_EXPIRE = 4,               /* Mark for expiry.  */
        UMOUNT_NOFOLLOW = 8           /* Don't follow symlink on umount.  */
    };
}

/** Intercept a library of a system call
 *
 * To use: define a function (typically, with `extern(C)` linkage) that performs the alternative implementation of
 * the library call. Then expand the template mixin here, giving it your function as a template argument.
 *
 * The template mixin will define a function called `next_` $(I yourfunction)
 *
 * Example:
 * ---
 * extern(C) int socket(int domain, int type, int protocol) {
 *     import std.stdio;
 *     int ret = next_socket(domain, type, protocol);
 *
 *     writefln("socket(%s, %s, %s) = %s", domain, type, protocol, ret);
 *
 *     return ret;
 * }
 *
 * mixin InterceptCall!socket;
 * ---
 */
public import core.sys.posix.dlfcn;
mixin template InterceptCall(alias F, alias lib=null) {
private:
    import std.string: format;
    import mecca.lib.reflection:  funcAttrToString;
    import core.sys.linux.dlfcn: RTLD_NEXT;

    mixin(q{
            typeof(F)* next_%1$s = &stub_%1$s;

            extern(%2$s) ReturnType!F stub_%1$s(Parameters!F args) %3$s {
                if( next_%1$s is &stub_%1$s ) {
                    void *handle = RTLD_NEXT;
                    static if(lib!=null) {
                        handle=dlopen(lib, RTLD_NOW);
                    }
                    next_%1$s = cast(typeof(F)*)dlsym(handle, "%1$s");
                }

                return next_%1$s(args);
            }
        }.format(mangledName!F, functionLinkage!F, funcAttrToString(functionAttributes!F)));
}

enum SyscallTracePoint {
    PRE_SYSCALL,
    POST_SYSCALL,
}

mixin template hookSyscall(alias F, Syscall nr, alias traceFunc, SyscallTracePoint tracePoint=SyscallTracePoint.PRE_SYSCALL, string file = __FILE_FULL_PATH__, size_t line = __LINE__, string _module_ = __MODULE__) {
    import std.traits: Parameters, ReturnType;
    import mecca.platform.linux: syscall;
    enum name = __traits(identifier, F);
    mixin("extern(C) pragma(mangle, \"" ~ name ~ "\") @system ReturnType!F " ~ name ~ "(Parameters!F args) {
            static if (tracePoint == SyscallTracePoint.PRE_SYSCALL) {
                traceFunc(args);
            }
            auto res = cast(ReturnType!F)syscall(nr, args);
            static if (tracePoint == SyscallTracePoint.POST_SYSCALL) {
                traceFunc(res, args);
            }
            return res;
        }"
    );
    import std.traits: fullyQualifiedName;
    enum hookFunctionScope = fullyQualifiedName!(__traits(parent, name));
    static assert(_module_ == hookFunctionScope,
        "syscall hook should be mixed into the global scope of a module in order for the linker to find it (instantiated on " ~ file ~ "(" ~ line.to!string ~ ")");
}

/+version (unittest) {
    __gshared bool hitPreFunc = false;

    static import core.sys.posix.unistd;
    mixin hookSyscall!(core.sys.posix.unistd.close, Syscall.NR_close, (int fd){hitPreFunc = true;});

    unittest {
        import std.stdio;
        auto f = File("/tmp/test", "w");
        f.close();
        assert (hitPreFunc);
    }
}+/

public import core.sys.linux.sys.mman : MAP_POPULATE, MREMAP_MAYMOVE;
import core.sys.posix.sys.types : pid_t;
import std.traits : ReturnType;

package(mecca):

/**
 * Represents the ID of a thread.
 *
 * This type is platform dependent.
 */
alias ThreadId = ReturnType!gettid;

/**
 * Represents the ID of a thread.
 *
 * This type is platform dependent.
 */
ThreadId currentThreadId() nothrow @system @nogc
{
    return gettid();
}

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
    OSSignal.SIGWINCH, OSSignal.SIGIO, OSSignal.SIGPWR,
    //OSSignal.SIGSYS,
];

static if( __traits(compiles, O_CLOEXEC) ) {
    enum O_CLOEXEC = core.sys.posix.fcntl.O_CLOEXEC;
} else {
    enum O_CLOEXEC = 0x80000;
}

import fcntl = core.sys.posix.fcntl;
static if( __traits(compiles, fcntl.F_DUPFD_CLOEXEC) ) {
    enum F_DUPFD_CLOEXEC = fcntl.F_DUPFD_CLOEXEC;
} else {
    version(linux) {
        enum F_DUPFD_CLOEXEC = 1030;
    }
}

public import core.stdc.errno : EREMOTEIO;
public import core.sys.posix.sys.time : ITIMER_REAL;

import mecca.platform.os : MmapArguments;

// A wrapper that is compatible with the signature used for Darwin
void* mremap(Args...)(MmapArguments, void* oldAddress,
    size_t oldSize, size_t newSize, int flags, Args args)
{
    import core.sys.linux.sys.mman: mremap;
    return mremap(oldAddress, oldSize, newSize, flags, args);
}

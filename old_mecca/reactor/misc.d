///////////////////////////////////////////////////////////////////////////////
// Misc reactor services:
//-----------------------------------------------------------------------------
// * periodic memory reporting
// * fiber histogram
// * segfault handler
// * hang-detector
///////////////////////////////////////////////////////////////////////////////
module mecca.reactor.misc;

import std.exception;
import std.string;

import core.memory: GC;
import fcntl = core.sys.posix.fcntl;
import unistd = core.sys.posix.unistd;
import core.sys.posix.signal;
import core.sys.posix.time: clockid_t, sigevent, itimerspec, CLOCK_MONOTONIC;

import mecca.lib.os: gettid;
import mecca.lib.tracing;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.reactor.reactor;
import mecca.reactor.fibers;


align(64) private __gshared ubyte[SIGSTKSZ] sigstack;

shared static this() {
    // the kernel will take care of choosing a correctly-aligned stack pointer inside sigstack
    stack_t ss = {&sigstack, 0, sigstack.sizeof};
    errnoEnforce(sigaltstack(&ss, null) == 0, "sigaltstack() failed");
}

private extern (C) nothrow @system @nogc {
    // BUG 15073: SIGRTMIN is private
    //int __libc_current_sigrtmin();

    // BUG 15088: timer_t is defined as int
    alias timer_t = void*;
    int timer_create(clockid_t, sigevent*, timer_t*);
    int timer_delete(timer_t);
    int timer_gettime(timer_t, itimerspec*);
    int timer_getoverrun(timer_t);
    int timer_settime(timer_t, int, in itimerspec*, itimerspec*);

    enum SIGEV_THREAD_ID = 4;
}

package __gshared int HANG_DETECTOR_SIGNUM = -1;

shared static this() {
    HANG_DETECTOR_SIGNUM = SIGRTMIN();
    assert (HANG_DETECTOR_SIGNUM > 0);
}

private __gshared timer_t hangDetectorTimerId;
private __gshared sigaction_t _prevSigsegv;

private void initHangDetector() {
    sigevent sev;
    itimerspec its;
    sigaction_t sa;

    sa.sa_flags = SA_RESTART | SA_ONSTACK;
    sa.sa_handler = &_hangDetectorHandler;
    errnoEnforce(sigaction(HANG_DETECTOR_SIGNUM, &sa, null) == 0, "sigaction() failed");

    sev.sigev_notify = SIGEV_THREAD_ID;
    sev.sigev_signo = HANG_DETECTOR_SIGNUM;
    sev.sigev_value.sival_ptr = &hangDetectorTimerId;
    sev._sigev_un._tid = gettid();

    errnoEnforce(timer_create(CLOCK_MONOTONIC, &sev, &hangDetectorTimerId) == 0, "timer_create");
    assert (hangDetectorTimerId !is null, "hangDetectorTimerId is null");

    its.it_value.tv_sec = 20;
    its.it_value.tv_nsec = 0;
    its.it_interval.tv_sec = its.it_value.tv_sec;
    its.it_interval.tv_nsec = its.it_value.tv_nsec;

    errnoEnforce(timer_settime(hangDetectorTimerId, 0, &its, null) == 0, "timer_settime");
}

void finiHangDetector() {
    if (hangDetectorTimerId !is null) {
        timer_delete(hangDetectorTimerId);
        hangDetectorTimerId = null;
    }
}

extern(C) @notrace private void _hangDetectorHandler(int signum) nothrow {
    if (!theReactor._opened || !theReactor._running || !theReactor.options.handDetectorEnabled) {
        return;
    }

    auto dur = TscTimePoint.now - theReactor.lastMainloopVisit;
    if (dur > theReactor.options.hangDetectorGrace) {
        auto ms = dur.total!"msecs";
        if (_thisFiber !is null) {
            // hung by a fiber
            META!"#HANG #DELAY Fiber is blocking the reactor for %s msecs. Aborting"(ms);
        }
        else {
            // hung by a callback
            META!"#HANG #DELAY Callback is blocking the reactor for %s msecs. Aborting"(ms);
        }
        ABORT("HANG DETECTOR");
    }
}

private void initSigsegvInspector() {
    if (theReactor.options.setupSegfaultHandler) {
        sigaction_t action;
        action.sa_sigaction = &_segfaultHandler;
        action.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
        auto res = sigaction(SIGSEGV, &action, &_prevSigsegv);
        errnoEnforce(res == 0, "sigaction() failed");
    }
}

private void finiSigsegvInspector() {
    if (theReactor.options.setupSegfaultHandler) {
        sigaction(SIGSEGV, &_prevSigsegv, null);
    }
}

extern(C) @notrace static private void _segfaultHandler(int signum, siginfo_t* info, void* ctx) nothrow {
    import core.sys.posix.ucontext;

    auto fib = _thisFiber;
    void* rip = ctx ? cast(void*)((cast(ucontext_t*)ctx).uc_mcontext.gregs[REG_RIP]) : null;

    if (fib) {
        META!"SEGFAULT inspector entered on fiber %s (stack=[%s..%s]%s, si_addr=%s, si_code=%s, RIP=%s)"(
            fib.fiberId, fib.stackBottom(), fib.stackTop(),
            info.si_addr >= fib.guardArea && info.si_addr <= fib.stackBottom() ? " HIT GUARD PAGE " : "",
            info.si_addr, info.si_code, rip);
    }
    else {
        META!"SEGFAULT inspector entered on thread (si_addr=%s, si_code=%s, RIP=%s)"(
            info.si_addr, info.si_code, rip);
    }
    LOG_CALLSTACK("SEGFAULT backtrace");

    // the instruction will be retried, which will throw again, this time terminating us
}

package void initMisc() {
    initHangDetector();
    initSigsegvInspector();

    if (theReactor.options.memoryStatsInterval > Duration.zero) {
        theReactor.callEvery(theReactor.options.memoryStatsInterval, &reportMemoryStats);
    }
}

package void finiMisc() {
    finiHangDetector();
    finiSigsegvInspector();
}

package void reportMemoryStats() {
    import core.stdc.stdio: sscanf;

    enum fn = "/proc/self/statm";
    enum fnzstr = fn ~ "\x00";
    auto fd = fcntl.open(fnzstr, fcntl.O_RDONLY);
    if (fd < 0) {
        ERROR!"#MEMSTAT failed to open '%s'"(fn);
        return;
    }
    scope(exit) unistd.close(fd);
    char[512] buf = void;
    auto res = unistd.read(fd, buf.ptr, buf.length);
    if (res < 0) {
        ERROR!"#MEMSTAT failed to read '%s'"(fn);
        return;
    }

    //  size       (1) total program size (same as VmSize in /proc/[pid]/status)
    //  resident   (2) resident set size (same as VmRSS in /proc/[pid]/status)
    //  share      (3) shared pages (i.e., backed by a file)
    //  text       (4) text (code)
    //  lib        (5) library (unused in Linux 2.6)
    //  data       (6) data + stack
    //  dt         (7) dirty pages (unused in Linux 2.6)
    long size, resident, share, text, lib, data, dt;
    auto num = sscanf(buf.ptr, "%lld %lld %lld %lld %lld %lld %lld", &size, &resident, &share, &text, &lib, &data, &dt);
    if (num != 7) {
        ERROR!"#MEMSTAT failed to parse '%s', num=%s"(buf[0 .. res], num);
        return;
    }
    INFO!"#MEMSTAT vmsize=%sMB resident=%sMB shared=%sMB text=%sMB data=%sMB"(size / 256, resident / 256,
        share / 256, text / 256, data / 256);
}

@notrace void collectGarbage() {
    // garbage must be collected every so often, and it must not be called from a fiber
    // as it may recurse deeply and reach the guard page (causing SEGFAULT)
    import core.thread: Fiber;
    theReactor.ensureCoherency();
    assert (Fiber.getThis() is null);

    GC.collect();
    //GC.minimize();
}




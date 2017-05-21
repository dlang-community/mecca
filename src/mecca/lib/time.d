module mecca.lib.time;

version(LDC) {
    public import ldc.intrinsics: readTSC = llvm_readcyclecounter;
}
else {
    ulong readTSC() nothrow pure @nogc @trusted {
        asm nothrow pure @nogc @trusted {
            naked;
            rdtsc;         // EDX(hi):EAX(lo)
            shl RDX, 32;
            or RAX, RDX;   // RAX |= (RDX << 32)
            ret;
        }
    }
}

struct TscTimePoint {
    __gshared static long cyclesPerSec;
    __gshared static long cyclesPerMsec;
    __gshared static long cyclesPerUsec;
    long cycles;

    static TscTimePoint now() {
        return TscTimePoint(readTSC());
    }

    shared static this() {
        import std.exception;
        import core.sys.posix.time;
        import std.file: readText;
        import std.string;

        enforce(readText("/proc/cpuinfo").indexOf("constant_tsc") >= 0, "constant_tsc not supported");

        timespec sleepTime = timespec(0, 200_000_000);
        timespec t0, t1;

        auto rc1 = clock_gettime(CLOCK_MONOTONIC, &t0);
        auto cyc0 = readTSC();
        auto rc2 = nanosleep(&sleepTime, null);
        auto rc3 = clock_gettime(CLOCK_MONOTONIC, &t1);
        auto cyc1 = readTSC();

        errnoEnforce(rc1 == 0, "clock_gettime");
        errnoEnforce(rc2 == 0, "nanosleep");
        errnoEnforce(rc3 == 0, "clock_gettime");

        auto nsecs = (t1.tv_sec - t0.tv_sec) * 1_000_000_000UL + (t1.tv_nsec  - t0.tv_nsec);
        cyclesPerSec= cast(long)((cyc1 - cyc0) / (nsecs / 1E9));
        cyclesPerMsec = cyclesPerSec / 1_000;
        cyclesPerUsec = cyclesPerSec / 1_000_000;
    }
}

unittest {
    auto t0 = TscTimePoint.now;
    assert (t0.cycles > 0);
    assert (TscTimePoint.cyclesPerSec > 1_000_000);
}

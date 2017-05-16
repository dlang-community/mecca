module mecca.lib.time;

import std.exception;
public import std.datetime;
import mecca.lib.divide: U64Denominator;

struct TscTimePoint {
    static shared immutable long cyclesPerSecond;
    static shared immutable U64Denominator cyclesPerSecondDenom;
    static shared immutable long cyclesPerMsec;
    static shared immutable U64Denominator cyclesPerMsecDenom;
    static shared immutable long cyclesPerUsec;
    static shared immutable U64Denominator cyclesPerUsecDenom;
    private enum HECTONANO = 10_000_000;
    enum min = TscTimePoint(long.min);
    enum zero = TscTimePoint(0);
    enum max = TscTimePoint(long.max);
    long cycles;
    static /* thread-local */ TscTimePoint lastTsc;

    version (LDC) {
        public import ldc.intrinsics: readTSC = llvm_readcyclecounter;
    }
    else {
        static ulong readTSC() nothrow @nogc @trusted {
            pragma(inline, true);
            asm nothrow @nogc @trusted {
                naked;
                rdtsc;         // result = EDX(hi):EAX(lo)
                shl RDX, 32;
                or RAX, RDX;   // RAX |= (RDX << 32)
                ret;
            }
        }
    }

    static auto now() @nogc nothrow {
        pragma(inline, true);
        auto c = readTSC();
        lastTsc = TscTimePoint(c);
        return TscTimePoint(c);
    }

    @("notrace") static long toCycles(Duration dur) pure @nogc @trusted nothrow {
        long hns = dur.total!"hnsecs";
        return (hns / HECTONANO) * cyclesPerSecond + ((hns % HECTONANO) * cyclesPerSecond) / HECTONANO;
    }
    @("notrace") static Duration toDuration(long cycles) pure @nogc @safe nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    TscTimePoint opBinary(string op)(long cycles) @nogc @safe const pure nothrow if (op == "+" || op == "-") {
        return TscTimePoint(mixin("this.cycles" ~ op ~ "cycles"));
    }
    TscTimePoint opBinary(string op)(Duration dur) @nogc @safe const nothrow if (op == "+" || op == "-") {
        return TscTimePoint(mixin("this.cycles" ~ op ~ "toCycles(dur)"));
    }
    TscTimePoint opBinary(string op: "+")(TscTimePoint tsc) @nogc @safe const nothrow pure {
        return TscTimePoint(this.cycles + tsc.cycles);
    }
    Duration opBinary(string op: "-")(TscTimePoint tsc) @nogc @safe const pure nothrow {
        return toDuration(this.cycles - tsc.cycles);
    }
    ref TscTimePoint opOpAssign(string op)(long cyc) @nogc @safe pure nothrow if (op == "+" || op == "-") {
        mixin("this.cycles " ~ op ~ "= cyc;");
        return this;
    }
    ref TscTimePoint opOpAssign(string op)(Duration dur) @nogc @safe pure nothrow if (op == "+" || op == "-") {
        mixin("this.cycles " ~ op ~ "= toCycles(dur);");
        return this;
    }
    long opCmp(TscTimePoint rhs) const pure nothrow @nogc {
        pragma(inline, true);
        return cycles - rhs.cycles;
    }
    long opCmp(long rhs) const pure nothrow @nogc {
        pragma(inline, true);
        return cycles - rhs;
    }

    @("notrace") long diff(string units)(TscTimePoint rhs) const nothrow @nogc {
        static if (units == "usecs") {
            return (cycles - rhs.cycles) / cyclesPerUsecDenom;
        }
        else static if (units == "msecs") {
            return (cycles - rhs.cycles) / cyclesPerMsecDenom;
        }
        else static if (units == "seconds") {
            return (cycles - rhs.cycles) / cyclesPerSecondDenom;
        }
        else static if (units == "cycles") {
            return (cycles - rhs.cycles);
        }
        else {
            static assert (false, units);
        }
    }
    @property long to(string units)() const nothrow @nogc {
        return to!units(cycles);
    }
    @property static long to(string units)(long cycles) nothrow @nogc {
        static if (units == "usecs") {
            return cycles / cyclesPerUsecDenom;
        }
        else static if (units == "msecs") {
            return cycles / cyclesPerMsecDenom;
        }
        else static if (units == "seconds") {
            return cycles / cyclesPerSecondDenom;
        }
        else static if (units == "cycles") {
            return cycles;
        }
        else {
            static assert (false, units);
        }
    }
    @("notrace") static TscTimePoint from(string units)(long num) nothrow @nogc {
        static if (units == "usecs") {
            return TscTimePoint(num * cyclesPerUsec);
        }
        else static if (units == "msecs") {
            return TscTimePoint(num * cyclesPerMsec);
        }
        else static if (units == "seconds") {
            return TscTimePoint(num * cyclesPerSecond);
        }
        else static if (units == "cycles") {
            return TscTimePoint(num);
        }
        else {
            static assert (false, units);
        }
    }

    shared static this() {
        import std.file: readText;
        import std.string;
        import core.sys.posix.time;
        import core.sys.posix.unistd;
        import core.sys.linux.time;

        // we must have constant_tsc to reliably use RDTSC
        enforce(readText("/proc/cpuinfo").indexOf("constant_tsc") > 0, "CPU does not support constant_tsc");

        timespec t0, t1;
        auto rc1 = clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
        auto tsc0 = readTSC();
        auto rc2 = usleep(300_000);
        auto rc3 = clock_gettime(CLOCK_MONOTONIC_RAW, &t1);
        auto tsc1 = readTSC();

        assert(rc1 == 0);
        assert(rc2 == 0);
        assert(rc3 == 0);
        auto dr = tsc1 - tsc0;

        auto dtUsecs = (t1.tv_sec * 1_000_000UL + t1.tv_nsec / 1_000) - (t0.tv_sec * 1_000_000UL + t0.tv_nsec / 1_000);
        cyclesPerSecond = (dr * 1_000_000) / dtUsecs;
        cyclesPerSecondDenom = U64Denominator(cyclesPerSecond);
        cyclesPerMsec = cyclesPerSecond / 1_000;
        cyclesPerMsecDenom = U64Denominator(cyclesPerMsec);
        cyclesPerUsec = cyclesPerSecond / 1_000_000;
        cyclesPerUsecDenom = U64Denominator(cyclesPerUsec);
    }
}

unittest {
    assert (TscTimePoint.cyclesPerSecond > 1_000_000);
}

struct Timeout {
    enum elapsed = Timeout(TscTimePoint.zero);
    enum infinite = Timeout(TscTimePoint.max);

    TscTimePoint expiry;

    this(TscTimePoint expiry) nothrow @nogc {
        this.expiry = expiry;
    }
    this(Duration dur, TscTimePoint now = TscTimePoint.now) nothrow @nogc {
        this.expiry = now + dur;
    }

    @property Duration remaining(TscTimePoint now=TscTimePoint.lastTsc) const nothrow @nogc {
        return (expiry == TscTimePoint.max) ? Duration.max : (expiry.cycles < now.cycles ? Duration.zero : expiry - now);
    }
    @property bool isExpired(TscTimePoint now=TscTimePoint.lastTsc) const nothrow @nogc {
        return (expiry == TscTimePoint.max) ? false : now.cycles > expiry.cycles;
    }
}

@("notrace") long getClockMonotonicNs() {
    import core.sys.posix.time;
    import core.sys.linux.time: CLOCK_MONOTONIC_RAW;

    timespec ts;
    errnoEnforce(clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0, "clock_gettime");
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}

struct WallTimePoint {

}




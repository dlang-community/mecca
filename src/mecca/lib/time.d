/// It's about time
module mecca.lib.time;

public import std.datetime;
import mecca.lib.division: S64Divisor;
public import mecca.platform.x86: readTSC;

/**
 * A time point maintained through the TSC timer
 *
 * TSC is a time counter maintained directly by the CPU. It counts how many "cycles" (loosly corresponding to actual CPU cycles)
 * since an arbitrary start point. It is read by a single assembly instruciton, and is more efficient to read than kernel
 * operatons.
 */
struct TscTimePoint {
    private enum HECTONANO = 10_000_000;
    /// Minimal, maximal and zero constants for reference.
    enum min = TscTimePoint(long.min);
    enum zero = TscTimePoint(0); /// ditto
    enum max = TscTimePoint(long.max); /// ditto

    /// Provide the cycles/time ratio for the current machine.
    static shared immutable long cyclesPerSecond;
    static shared immutable long cyclesPerMsec;         /// ditto
    static shared immutable long cyclesPerUsec;         /// ditto
    alias frequency = cyclesPerSecond;                  /// ditto

    /** Prepared dividor for the cycles/time value
     *
     * An S64Divisor for the cycles/time value, for quickly dividing by it at runtime.
     */
    static shared immutable S64Divisor cyclesPerSecondDivisor;
    static shared immutable S64Divisor cyclesPerMsecDivisor;    /// ditto
    static shared immutable S64Divisor cyclesPerUsecDivisor;    /// ditto

private:
    /* thread local */ static ubyte refetchInterval;
    /* thread local */ static ubyte fetchCounter;
    /* thread local */ static TscTimePoint lastTsc;

public:
    /// Time represented by TscTimePoint in units of cycles.
    long cycles;

    /**
     * Get a TscTimePoint representing now.
     *
     * There are two variants of this method. hardNow returns the actual time, right now, as reported by the cycles counter in the
     * CPU. softNow returns an approximate time. It is guaranteed to montoniously advance, but it not guaranteed to be accurate.
     * softNow works by calling hardNow once in a while, and doing simple increments in between.
     *
     * A good rule of thumb is this: If you use requires getting the time on a semi-regular basis, call softNow whenever precise
     * time is not required. If your use requires time only sporadically, only use hardNow.
     *
     * Warning:
     * softNow does not guarantee monotonity across different threads. If you need different threads to have comparable times, use
     * hardNow.
     */
    static TscTimePoint softNow() nothrow @nogc @safe {
        if (fetchCounter < refetchInterval) {
            fetchCounter++;
            lastTsc.cycles++;
            return lastTsc;
        }
        else {
            return hardNow();
        }
    }
    /// ditto
    static TscTimePoint hardNow() nothrow @nogc @safe {
        pragma(inline, true);
        lastTsc.cycles = readTSC();
        fetchCounter = 0;
        return lastTsc;
    }

    shared static this() {
        import std.exception;
        import core.sys.posix.time;
        import std.file: readText;
        import std.string;

        // the main thread actually performs RDTSC 1 in 10 calls
        refetchInterval = 10;

        version (linux) {
        }
        else {
            static assert (false, "a linux system is required");
        }

        enforce(readText("/proc/cpuinfo").indexOf("constant_tsc") >= 0, "constant_tsc not supported");

        timespec sleepTime = timespec(0, 200_000_000);
        timespec t0, t1;

        auto rc1 = clock_gettime(CLOCK_MONOTONIC, &t0);
        auto cyc0 = readTSC();
        auto rc2 = nanosleep(&sleepTime, null);
        auto rc3 = clock_gettime(CLOCK_MONOTONIC, &t1);
        auto cyc1 = readTSC();

        errnoEnforce(rc1 == 0, "clock_gettime");
        errnoEnforce(rc2 == 0, "nanosleep");   // we hope we won't be interrupted by a signal here
        errnoEnforce(rc3 == 0, "clock_gettime");

        auto nsecs = (t1.tv_sec - t0.tv_sec) * 1_000_000_000UL + (t1.tv_nsec  - t0.tv_nsec);
        cyclesPerSecond = cast(long)((cyc1 - cyc0) / (nsecs / 1E9));
        cyclesPerMsec = cyclesPerSecond / 1_000;
        cyclesPerUsec = cyclesPerSecond / 1_000_000;

        cyclesPerSecondDivisor = S64Divisor(cyclesPerSecond);
        cyclesPerMsecDivisor = S64Divisor(cyclesPerMsec);
        cyclesPerUsecDivisor = S64Divisor(cyclesPerUsec);

        hardNow();
    }

    /// Calculate a TscTimePoint for a set duration from now
    static auto fromNow(Duration dur) @nogc {
        return hardNow + toCycles(dur);
    }

    /// Various conversion functions
    static long toCycles(Duration dur) @nogc @safe nothrow {
        long hns = dur.total!"hnsecs";
        return (hns / HECTONANO) * cyclesPerSecond + ((hns % HECTONANO) * cyclesPerSecond) / HECTONANO;
    }
    /// ditto
    static long toCycles(string unit)(long n) @nogc @safe nothrow {
        static if (unit == "usecs") {
            return n * cyclesPerUsec;
        } else static if (unit == "msecs") {
            return n * cyclesPerMsec;
        } else static if (unit == "seconds") {
            return n * cyclesPerSecond;
        }
    }
    /// ditto
    static Duration toDuration(long cycles) @nogc @safe nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    /// ditto
    Duration toDuration() const @safe nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    /// ditto
    static long toUsecs(long cycles) @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    /// ditto
    long toUsecs() const @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    /// ditto
    static long toMsecs(long cycles) @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }
    /// ditto
    long toMsecs() const @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }

    int opCmp(TscTimePoint rhs) const @nogc @safe nothrow {
        return (cycles > rhs.cycles) ? 1 : ((cycles < rhs.cycles) ? -1 : 0);
    }
    bool opEquals()(TscTimePoint rhs) const @nogc @safe nothrow {
        return cycles == rhs.cycles;
    }

    TscTimePoint opBinary(string op: "+")(long cycles) const @nogc @safe nothrow {
        return TscTimePoint(this.cycles + cycles);
    }
    TscTimePoint opBinary(string op: "+")(Duration dur) const @nogc @safe nothrow {
        return TscTimePoint(cycles + toCycles(dur));
    }

    Duration opBinary(string op: "-")(long cycles) const @nogc @safe nothrow {
        return TscTimePoint.toDuration(this.cycles - cycles);
    }
    Duration opBinary(string op: "-")(TscTimePoint rhs) const @nogc @safe nothrow {
        return TscTimePoint.toDuration(cycles - rhs.cycles);
    }
    TscTimePoint opBinary(string op: "-")(Duration dur) const @nogc @safe nothrow {
        return TscTimePoint(cycles - toCycles(dur));
    }

    ref auto opOpAssign(string op)(Duration dur) @nogc if (op == "+" || op == "-") {
        mixin("cycles " ~ op ~ "= toCycles(dur);");
        return this;
    }
    ref auto opOpAssign(string op)(long cycles) @nogc if (op == "+" || op == "-") {
        mixin("this.cycles " ~ op ~ "= cycles;");
        return this;
    }

    /// Calculate difference between two TscTimePoint in the given units
    @("notrace") long diff(string units)(TscTimePoint rhs) @nogc
            if (units == "usecs" || units == "msecs" || units == "seconds" || units == "cycles")
    {
        static if (units == "usecs") {
            return (cycles - rhs.cycles) / cyclesPerUsecDivisor;
        }
        else static if (units == "msecs") {
            return (cycles - rhs.cycles) / cyclesPerMsecDivisor;
        }
        else static if (units == "seconds") {
            return (cycles - rhs.cycles) / cyclesPerSecondDivisor;
        }
        else static if (units == "cycles") {
            return (cycles - rhs.cycles);
        }
        else {
            static assert (false, units);
        }
    }

    /// Convert to any of the units accepted by toDuration
    long to(string unit)() @nogc @safe nothrow {
        return toDuration.total!unit();
    }
}

unittest {
    auto t0 = TscTimePoint.hardNow;
    assert (t0.cycles > 0);
    assert (TscTimePoint.cyclesPerSecond > 1_000_000);
}

/// A type for specifying absolute timeouts
struct Timeout {
    /// Constant specifying an already elapsed timeout
    enum Timeout elapsed = Timeout(TscTimePoint.min);
    /// Constant specifying a timeout that will never elapse
    enum Timeout infinite = Timeout(TscTimePoint.max);

    /// The expected expiry time
    TscTimePoint expiry;

    /// Construct a timeout from TscTimePoint
    this(TscTimePoint expiry) {
        this.expiry = expiry;
    }
    /**
     * Construct a timeout from Duration
     *
     * Params:
     * dur = Duration until timeout expires
     * now = If provided, the base time to compute the timeout relative to
     */
    this(Duration dur, TscTimePoint now = TscTimePoint.hardNow) @safe @nogc {
        if (dur == Duration.max) {
            this.expiry = TscTimePoint.max;
        }
        else {
            this.expiry = now + dur;
        }
    }

    /**
     * Checks whether a Timeout has expired.
     *
     * Params:
     * now = time point relative to which to check.
     */
    bool expired(TscTimePoint now = TscTimePoint.softNow) const nothrow @safe @nogc {
        if( this == infinite )
            return false;

        return expiry <= now;
    }
}

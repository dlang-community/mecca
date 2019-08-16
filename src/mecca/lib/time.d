/// It's about time
module mecca.lib.time;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.sys.posix.sys.time : timespec;

public import std.datetime;
import mecca.lib.division: S64Divisor;
public import mecca.platform.x86: readTSC;
import mecca.log;

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
    /* thread local */ static ubyte refetchInterval; // How many soft calls to do before doing hard fetch of timer
    /* thread local */ static ubyte fetchCounter;
    /* thread local */ static TscTimePoint lastTsc;

public:
    /// Time represented by TscTimePoint in units of cycles.
    long cycles;

    /**
     * Get a TscTimePoint representing now.
     *
     * There are two variants of this method. "now" and "hardNow". By default, they do exactly the same thing:
     * report the time right now, as reported by the cycles counter in the CPU.
     *
     * As fetching the cycles counter may be relatively expensive, threads that do a lot of time keeping may find that getting
     * the hardware counter each and every time is too costly. In that case, you can call "setHardNowThreshold" with a threshold.
     * Calling, e.g. setHardNow(3) will mean that now will call hardNow every third invocation.
     *
     * Even when now doesn't call hardNow, it is still guaranteed to montoniously advance, but it not guaranteed to be accurate.
     *
     * A good rule of thumb is this: If you use requires getting the time on a semi-regular basis, call now whenever precise
     * time is not required. If your use requires time only sporadically, only use hardNow.
     *
     * Warning:
     * now does not guarantee monotonity across different threads. If you need different threads to have comparable times, use
     * hardNow.
     */
    static TscTimePoint now() nothrow @nogc @safe {
        if (fetchCounter < refetchInterval || refetchInterval==ubyte.max) {
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

    /**
     * Set the frequency with which we take a hard TSC reading
     *
     * See complete documentation in the now method.
     *
     * Params:
     * interval = take a hardNow every so many calls to now. A value of 1 mean that now and hardNow are identical. A value of 0
     *   means that hardNow is $(B never) implicitly taken.
     */
    static void setHardNowThreshold(ubyte interval) nothrow @nogc @safe {
        refetchInterval = cast(ubyte)(interval-1);
    }

    shared static this() {
        import mecca.platform.os: calculateCycles;

        const cycles = calculateCycles();
        cyclesPerSecond = cycles.perSecond;
        cyclesPerMsec = cycles.perMsec;
        cyclesPerUsec = cycles.perUsec;

        cyclesPerSecondDivisor = S64Divisor(cyclesPerSecond);
        cyclesPerMsecDivisor = S64Divisor(cyclesPerMsec);
        cyclesPerUsecDivisor = S64Divisor(cyclesPerUsec);

        hardNow();
    }

    /// Calculate a TscTimePoint for a set duration from now
    static auto fromNow(Duration dur) @nogc {
        return hardNow + toCycles(dur);
    }

    /// Calculate a TscTimePoint for a time given in systime from now
    ///
    /// Not @nogc and nothrow, because Clock.currTime does GC and may throw
    @("notrace") static auto fromSysTime(SysTime time) @safe {
        Duration diff = time - Clock.currTime();
        return fromNow(diff);
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
    static Duration durationof(long cycles) pure @safe @nogc nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }

    alias toDuration this;
    
    /// ditto
    @property Duration toDuration() const @safe @nogc nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    /// ditto
    static long toUsecs(long cycles) pure @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    /// ditto
    long toUsecs() const pure @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    /// ditto
    static long toMsecs(long cycles) pure @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }
    /// ditto
    long toMsecs() pure const @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }

    double toSeconds() pure const @nogc @safe nothrow {
        return cast(double)cycles/cyclesPerSecond;
    }

    int opCmp(TscTimePoint rhs) pure const @nogc @safe nothrow {
        return (cycles > rhs.cycles) ? 1 : ((cycles < rhs.cycles) ? -1 : 0);
    }
    bool opEquals()(TscTimePoint rhs) pure const @nogc @safe nothrow {
        return cycles == rhs.cycles;
    }
    
    TscTimePoint opBinary(string op: "+")(long cycles) const @nogc @safe nothrow pure {
        return TscTimePoint(this.cycles + cycles);
    }
    TscTimePoint opBinary(string op: "+")(Duration dur) const @nogc @safe nothrow {
        return TscTimePoint(cycles + toCycles(dur));
    }

    TscTimePoint opBinary(string op: "-")(long cycles) const @nogc @safe nothrow pure {
        return TscTimePoint(this.cycles - cycles);
    }
    TscTimePoint opBinary(string op: "-")(TscTimePoint rhs) const @nogc @safe nothrow pure {
        return TscTimePoint(cycles - rhs.cycles);
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
    @("notrace") long diff(string units)(TscTimePoint rhs) nothrow @safe @nogc
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
    long to(string unit)() const @nogc @safe nothrow {
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
    @safe @nogc pure nothrow
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
    this(Duration dur, TscTimePoint now = TscTimePoint.now) nothrow @safe @nogc {
        if (dur == Duration.max) {
            this.expiry = TscTimePoint.max;
        }
        else {
            this.expiry = now + dur;
        }
    }

    /**
     * Report how much time until the timeout expires
     */
    @notrace @property Duration remaining(TscTimePoint now = TscTimePoint.now) const @safe @nogc nothrow {
        if (expiry == TscTimePoint.max) {
            return Duration.max;
        }
        if (expiry.cycles < now.cycles) {
            return Duration.zero;
        }
        return expiry - now;
    }

    /**
     * Checks whether a Timeout has expired.
     *
     * Params:
     * now = time point relative to which to check.
     */
    @notrace @property bool expired(TscTimePoint now = TscTimePoint.now) pure const nothrow @safe @nogc {
        if( this == infinite )
            return false;

        return expiry <= now;
    }

    @notrace int opCmp(in Timeout rhs) const nothrow @safe @nogc {
        return expiry.opCmp(rhs.expiry);
    }

    @notrace bool opEquals()(in Timeout rhs) const nothrow @safe @nogc {
        return expiry == rhs.expiry;
    }
}

package(mecca) timespec toTimespec(Duration duration) nothrow pure @safe @nogc
{
    timespec spec;
    duration.split!("seconds", "nsecs")(spec.tv_sec, spec.tv_nsec);

    return spec;
}

module mecca.reactor.impl.time_queue;

import std.string;

import mecca.log;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.containers.lists;
import mecca.lib.division: S64Divisor;


class TooFarAhead: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

struct CascadingTimeQueue(T, size_t numBins, size_t numLevels, bool hasOwner = false) {
private:
    static assert ((numBins & (numBins - 1)) == 0);
    static assert (numLevels >= 1);
    static assert (numBins * numLevels < 256*8);
    enum spanInBins = numBins*(numBins^^numLevels-1) / (numBins-1);

    TscTimePoint baseTime;
    TscTimePoint poppedTime; // Marks the END of the bin currently pointed to by offset
    long resolutionCycles;
    S64Divisor resolutionDenom;
    size_t offset;
    version(unittest) {
        ulong[numLevels] stats;
    }

    static if( hasOwner )
            alias ListType = LinkedListWithOwner!T;
    else
        alias ListType = LinkedList!T;

    ListType[numBins][numLevels] bins;

public:
    static if( hasOwner ) {
        alias OwnerAttrType = ListType*;
    }

    void open(Duration resolution, TscTimePoint startTime = TscTimePoint.now) @safe @nogc {
        open(TscTimePoint.toCycles(resolution), startTime);
    }

    void open(long resolutionCycles, TscTimePoint startTime) @safe @nogc {
        assert (resolutionCycles > 0);
        this.baseTime = startTime;
        this.poppedTime = startTime;
        this.resolutionCycles = resolutionCycles;
        this.resolutionDenom = S64Divisor(resolutionCycles);
        this.offset = 0;
        version (unittest) {
            this.stats[] = 0;
        }
    }

    void close() nothrow @safe @nogc {
        foreach(ref lvl; bins) {
            foreach(ref bin; lvl) {
                while( !bin.empty )
                    bin.popHead;
            }
        }
    }

    @property Duration span() const nothrow {
        return TscTimePoint.toDuration(resolutionCycles * spanInBins);
    }

    void insert(T entry) @safe @nogc {
        version (unittest) {
            stats[0]++;
        }
        if (!_insert(entry)) {
            throw mkExFmt!TooFarAhead("tp=%s baseTime=%s poppedTime=%s (%.3fs in future) offset=%s resolutionCycles=%s",
                    entry.timePoint, baseTime, poppedTime, (entry.timePoint - baseTime).total!"msecs" / 1000.0,
                            offset, resolutionCycles);
        }
    }

    static if( hasOwner ) {
        void cancel(T entry) {
            ListType.discard(entry);
        }
    }

    Duration timeTillNextEntry(TscTimePoint now) {
        long cycles = cyclesTillNextEntry(now);

        if( cycles==long.max )
            return Duration.max;

        return TscTimePoint.toDuration(cycles);
    }

    long cyclesTillNextEntry(TscTimePoint now) {
        ulong binsToGo = binsTillNextEntry();

        if( binsToGo == ulong.max )
            return long.max;

        long delta = now.cycles - poppedTime.cycles;
        long wait = binsToGo * resolutionCycles - delta;
        if( wait<0 )
            return 0;
        return wait;
    }

    T pop(TscTimePoint now) {
        while (now >= poppedTime) {
            auto e = bins[0][offset % numBins].popHead();
            if (e !is null) {
                assert (e.timePoint <= now, "popped tp=%s now=%s baseTime=%s poppedTime=%s offset=%s resolutionCycles=%s".format(
                    e.timePoint, now, baseTime, poppedTime, offset, resolutionCycles));
                return e;
            }
            else {
                offset++;
                poppedTime += resolutionCycles;
                if (offset % numBins == 0) {
                    baseTime = poppedTime;
                    cascadeNextLevel!1();
                }
            }
        }
        return T.init;
    }

private:
    bool _insert(T entry) nothrow @safe @nogc {
        if (entry.timePoint <= poppedTime) {
            bins[0][offset % numBins].append(entry);
            return true;
        }
        else {
            auto idx = (entry.timePoint.cycles - baseTime.cycles + resolutionCycles - 1) / resolutionDenom;
            auto origIdx = idx;
            foreach(i; IOTA!numLevels) {
                if (idx < numBins) {
                    enum magnitude = numBins ^^ i;
                    static if( i>0 ) {
                        size_t effectiveOffset = offset / magnitude;
                    } else {
                        enum effectiveOffset = 0;
                    }
                    bins[i][(effectiveOffset + idx) % numBins].append(entry);
                    return true;
                }
                idx = idx / numBins - 1;
            }
            return false;
        }
    }

    private ulong binsTillNextEntry() {
        ulong binsToGo;
        foreach(level; IOTA!numLevels) {
            enum ResPerBin = numBins ^^ level; // Number of resolution units in a single level bin
            foreach( bin; ((offset / ResPerBin) % numBins) .. numBins ) {
                if( !bins[level][bin].empty )
                    return binsToGo;

                binsToGo += ResPerBin;
            }
        }

        return ulong.max;
    }

    void cascadeNextLevel(size_t level)() {
        static if (level < numLevels) {
            version (unittest) {
                stats[level]++;
            }
            enum magnitude = numBins ^^ level;
            assert (offset >= magnitude, "level=%s offset=%s mag=%s".format(level, offset, magnitude));
            auto binToClear = &bins[level][(offset / magnitude - 1) % numBins];
            while ( !binToClear.empty ) {
                auto e = binToClear.popHead();
                auto succ = _insert(e);
                /+assert (succ && e._chain.owner !is null && e._chain.owner !is binToClear,
                    "reinstered succ=%s tp=%s level=%s baseTime=%s poppedTime=%s offset=%s resolutionCycles=%s".format(
                        succ, e.timePoint, level, baseTime, poppedTime, offset, resolutionCycles));+/
            }
            assert (binToClear.empty, "binToClear not empty, level=%s".format(level));
            if ((offset / magnitude) % numBins == 0) {
                cascadeNextLevel!(level+1);
            }
        }
    }
}

unittest {
    import std.stdio;
    import std.algorithm: count, map;
    import std.array;

    static struct Entry {
        TscTimePoint timePoint;
        string name;
        Entry* _next;
        Entry* _prev;
    }

    enum resolution = 50;
    enum numBins = 16;
    enum numLevels = 3;
    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    ctq.open(resolution, TscTimePoint(0));
    assert (ctq.spanInBins == 16 + 16^^2 + 16^^3);

    bool[Entry*] entries;
    Entry* insert(TscTimePoint tp, string name) {
        Entry* e = new Entry(tp, name);
        ctq.insert(e);
        entries[e] = true;
        return e;
    }

    insert(90.TscTimePoint, "e1");
    insert(120.TscTimePoint, "e2");
    insert(130.TscTimePoint, "e3");
    insert(160.TscTimePoint, "e4");
    insert(TscTimePoint(resolution*numBins-1), "e5");
    insert(TscTimePoint(resolution*numBins + 10), "e6");

    long then = 0;
    foreach(long now; [10, 50, 80, 95, 100, 120, 170, 190, 210, 290, resolution*numBins, resolution*(numBins+1), resolution*(numBins+1)+1]) {
        Entry* e;
        while ((e = ctq.pop(TscTimePoint(now))) !is null) {
            scope(failure) writefln("%s:%s (%s..%s, %s)", e.name, e.timePoint, then, now, ctq.baseTime);
            assert (e.timePoint.cycles/resolution <= now/resolution, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e.timePoint.cycles/resolution >= then/resolution - 1, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e in entries);
            entries.remove(e);
        }
        then = now;
    }
    assert (entries.length == 0, "Entries not empty: %s".format(entries));

    auto e7 = insert(ctq.baseTime + resolution * (ctq.spanInBins - 1), "e7");

    auto caught = false;
    try {
        insert(ctq.baseTime + resolution * ctq.spanInBins, "e8");
    }
    catch (TooFarAhead ex) {
        caught = true;
    }
    assert (caught);

    auto e = ctq.pop(e7.timePoint + resolution);
    assert (e is e7, "%s".format(e));
}

unittest {
    import std.stdio;
    import mecca.containers.pools;
    import std.algorithm: min;
    import std.random;

    static struct Entry {
        TscTimePoint timePoint;
        ulong counter;
        Entry* _next;
        Entry* _prev;
    }

    // must set these for the UT to be reproducible
    const t0 = TscTimePoint(168513482286);
    const cyclesPerSecond = 2208014020;
    const cyclesPerUsec = cyclesPerSecond / 1_000_000;
    long toCycles(Duration dur) {
        enum HECTONANO = 10_000_000;
        long hns = dur.total!"hnsecs";
        return (hns / HECTONANO) * cyclesPerSecond + ((hns % HECTONANO) * cyclesPerSecond) / HECTONANO;
    }

    void testCTQ(size_t numBins, size_t numLevels, size_t numElems)(Duration resolutionDur) {
        FixedPool!(Entry, numElems) pool;
        CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;

        TscTimePoint now = t0;
        long totalInserted = 0;
        long totalPopped = 0;
        long iterationCounter = 0;
        auto span = resolutionDur * ctq.spanInBins;
        auto end = t0 + toCycles(span * 2);
        long before = toCycles(10.msecs);
        long ahead = toCycles(span/2);

        pool.open();
        ctq.open(toCycles(resolutionDur), t0);

        //uint seed = 3594633224; //1337;
        uint seed = unpredictableSeed();
        auto rand = Random(seed);
        scope(failure) writefln("seed=%s numBins=%s numLevels=%s resDur=%s iterationCounter=%s totalInserted=%s " ~
            "totalPopped=%s t0=%s now=%s", seed, numBins, numLevels, resolutionDur, iterationCounter, totalInserted,
                totalPopped, t0, now);

        void popReady(long advanceCycles) {
            auto prevNow = now;
            now += advanceCycles;
            uint numPopped = 0;
            Entry* e;
            while ((e = ctq.pop(now)) !is null) {
                assert (e.timePoint <= now, "tp=%s prevNow=%s now=%s".format(e.timePoint, prevNow, now));
                //assert (e.timePoint/ctq.baseFrequencyCyclesDenom >= prevNow/ctq.baseFrequencyCyclesDenom, "tp=%s prevNow=%s now=%s".format(e.timePoint, prevNow, now));
                numPopped++;
                pool.release(e);
            }
            //writefln("%8d..%8d: %s", (prevNow - t0) / cyclesPerUsec, (now - t0) / cyclesPerUsec, numPopped);
            totalPopped += numPopped;
        }

        while (now < end) {
            while (pool.numAvailable > 0) {
                auto e = pool.alloc();
                e.timePoint = TscTimePoint(uniform(now.cycles - before, min(end.cycles, now.cycles + ahead), rand));
                e.counter = totalInserted++;
                //writefln("insert[%s] at %s", e.counter, (e.timePoint - t0) / cyclesPerUsec);
                ctq.insert(e);
            }
            auto us = uniform(0, 130, rand);
            if (us > 120) {
                us = uniform(100, 1500, rand);
            }
            popReady(us * cyclesPerUsec);
            iterationCounter++;
        }
        popReady(ahead + ctq.resolutionCycles);
        auto covered = ctq.baseTime.diff!"cycles"(t0) / double(cyclesPerSecond);
        auto expectedCover = span.total!"msecs" * (2.5 / 1000);
        assert (covered >= expectedCover - 2, "%s %s".format(covered, expectedCover));

        writeln(totalInserted, " ", totalPopped, " ", ctq.stats);
        foreach(i, s; ctq.stats) {
            assert (s > 0, "i=%s s=%s".format(i, s));
        }

        assert (totalInserted - totalPopped == pool.numInUse, "(1) pool.used=%s inserted=%s popped=%s".format(pool.numInUse, totalInserted, totalPopped));
        assert (totalInserted == totalPopped, "(2) pool.used=%s inserted=%s popped=%s".format(pool.numInUse, totalInserted, totalPopped));
        assert (totalInserted > numElems * 2, "totalInserted=%s".format(totalInserted));
    }

    int numRuns = 0;
    foreach(numElems; [10_000 /+, 300, 1000, 4000, 5000+/]) {
        // spans 878s
        testCTQ!(256, 3, 10_000)(50.usecs);
        numRuns++;
    }
    assert (numRuns > 0);
}

unittest {
    import mecca.log;
    import std.string;

    static struct Entry {
        TscTimePoint timePoint;
        string name;
        Entry* _next;
        Entry* _prev;
    }

    // The actual resolution is going to be slightly different than this, but it should only be more accurate, never less.
    enum resolution = dur!"msecs"(1);
    enum numBins = 16;
    enum numLevels = 3;

    TscTimePoint now = TscTimePoint.now;

    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    ctq.open(resolution, now);

    Entry[6] entries;
    enum L0Duration = resolution * numBins;
    enum L1Duration = L0Duration * numBins;

    entries[0] = Entry(now + resolution /2, "e0 l0 b1");
    entries[1] = Entry(now + resolution + 2, "e1 l0 b2");
    entries[2] = Entry(now + resolution * 10 + 3, "e2 l0 b11");
    entries[3] = Entry(now + L0Duration + resolution * 3 + 2, "e3 l1 b0 l0 b4");
    entries[4] = Entry(now + L0Duration*7 + resolution * 5 + 7, "e4 l1 b6 l0 b6");
    entries[5] = Entry(now + L1Duration + 14, "e5 l2 b0 l0 b1");

    foreach( ref e; entries ) {
        INFO!"Entry %s at %s"( e.name, e.timePoint - now );
    }

    // Insert out of order
    ctq.insert(&entries[3]);
    ctq.insert(&entries[1]);
    ctq.insert(&entries[4]);
    ctq.insert(&entries[5]);
    ctq.insert(&entries[2]);
    ctq.insert(&entries[0]);

    uint nextIdx = 0;

    assert(ctq.pop(now) is null, "First entry received too soon");

    auto base = now;
    while(nextIdx<entries.length) {
        auto step = ctq.cyclesTillNextEntry(now);
        now += step;
        DEBUG!"Setting time forward by %s to %s"(TscTimePoint.toDuration(step), now - base);
        Entry* e = ctq.pop(now);

        if( e !is null ) {
            INFO!"Got entry %s from queue"(e.name);
            assert( e.name == entries[nextIdx].name, "Pop returned incorrect entry, expected %s, got %s".format(entries[nextIdx].name,
                        e.name) );
            assert( e.timePoint>(now - resolution) && e.timePoint<=now,
                    "Pop returned entry %s at an incorrect time. Current %s expected %s".format(e.name, now-base, e.timePoint-base) );
            nextIdx++;
        } else {
            DEBUG!"Got empty entry from queue"();
        }
    }
}

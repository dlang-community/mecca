module mecca.lib.time_queue;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.algorithm : min, max;
import std.math : abs;

import mecca.containers.lists;
import mecca.lib.division: S64Divisor;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.lib.reflection;
import mecca.log;

// DMDBUG define a global for the sole purpose of forcing functions to not be misidentified as pure. See notPure()
private __gshared uint notPureDMDBUG;

struct CascadingTimeQueue(T, size_t numBins, size_t numLevels, bool hasOwner = false) {
private:
    debug(timeq_verbosity) {
        enum INTERNAL_VERBOSITY = true;
    } else {
        enum INTERNAL_VERBOSITY = false;
    }

    static assert (numBins>1, "Seriously? What were you thining?");
    static assert ((numBins & (numBins - 1)) == 0, "numBins must be a power of 2");
    static assert (numLevels > 1);
    static assert (numBins * numLevels < 256*8);
    // Minimal maximal span is the size of all bins in the last level + one bin of the first level. Not exported because
    // meaningless, as we have the overflow to catch uses outside this span.
    enum spanInBins = (numBins-1) * rawBinsInBin(numLevels-1) + 1;

    alias Phase = ulong;

    TscTimePoint[numLevels] baseTimes; // Time the first bin of each level begins on
    TscTimePoint[numLevels] endTimes; // The time point that marks bins no longer available in this level
    TscTimePoint poppedTime; // Marks the END of the bin currently pointed to by phase (last timestamp in bin)
    long resolutionCycles;
    ulong nextEntryHint = ulong.max; // Next active bin not before this number of bins (max = invalid)
    S64Divisor[numLevels] resolutionDividers;
    Phase phase;
    size_t _length; // Number of elements in the queue
    version(unittest) {
        ulong[numLevels+1] stats;
    }

    static if( hasOwner )
        alias ListType = LinkedListWithOwner!T;
    else
        alias ListType = LinkedList!T;

    ListType[numBins][numLevels] bins;
    ListType[2] overflow;
    uint activeOverflow;

public:
    static if( hasOwner ) {
        alias OwnerAttrType = ListType*;
    }

    void open(Duration resolution, TscTimePoint startTime = TscTimePoint.hardNow) @safe @nogc {
        open(TscTimePoint.toCycles(resolution), startTime);
    }

    void open(long resolutionCycles, TscTimePoint startTime) @safe @nogc {
        assert (resolutionCycles > 0);
        assertEQ (_length, 0);
        this.resolutionCycles = resolutionCycles;
        foreach( uint level; 0..numLevels ) {
            this.resolutionDividers[level] = S64Divisor(resolutionCycles*rawBinsInBin(level));
        }
        this.phase = 0;
        this.nextEntryHint = ulong.max;
        version (unittest) {
            this.stats[] = 0;
        }

        this.poppedTime = startTime;
        this.baseTimes[0] = this.poppedTime;
        this.baseTimes[0] -= resolutionCycles - 1; // First bin in first level is for already expired jobs
        foreach( uint level; 0..numLevels ) {
            this.endTimes[level] = this.baseTimes[level];
            this.endTimes[level] += binsInLevel(level) * resolutionCycles;

            if( level==numLevels-1 )
                break;

            // On init, next level begins where current level ends
            this.baseTimes[level+1] = this.endTimes[level];
        }
    }

    void close() nothrow @safe @nogc {
        foreach(ref lvl; bins) {
            foreach(ref bin; lvl) {
                while( !bin.empty ) {
                    _length--;
                    bin.popHead;
                }
            }
        }

        ASSERT!"Standby overflow bin not empty"( overflow[1-activeOverflow].empty );
        while( !overflow[activeOverflow].empty ) {
            _length--;
            overflow[activeOverflow].popHead;
        }

        ASSERT!"At end of CascadingTimeQueue.close() _length is %s (expected 0)"(_length==0, _length);
    }

    @property size_t length() pure const nothrow @safe @nogc {
        return _length;
    }

    static if( hasOwner ) {
        void cancel(T entry) nothrow @safe @nogc {
            ListType.discard(entry);
            _length--;
        }
    }

    @notrace Duration timeTillNextEntry(TscTimePoint now) nothrow @safe @nogc {
        ulong cycles = cyclesTillNextEntry(now);

        if( cycles==ulong.max )
            return Duration.max;

        return TscTimePoint.durationof(cycles);
    }

    ulong cyclesTillNextEntry(TscTimePoint now) nothrow @safe @nogc {
        DBG_ASSERT!"time moved backwards %s=>%s"(now>=poppedTime, now, poppedTime);
        ulong binsToGo = binsTillNextEntry();
        static if(INTERNAL_VERBOSITY) DEBUG!"XXX Bins to go %s phase %s"(binsToGo, phase);

        if( binsToGo == ulong.max )
            return ulong.max;

        long delta = now.cycles - poppedTime.cycles;
        long wait = binsToGo * resolutionCycles - delta;
        if( wait<0 )
            return 0;
        return wait;
    }

    @notrace T pop(TscTimePoint now) nothrow @safe @nogc {
        assertOp!"<="(poppedTime, now, "current time moved backwards");

        // If there are expired events, return those first
        auto event = bins[0][phase % numBins].popHead();
        if( event !is T.init ) {
            ASSERT!"Successfully popped element from cascaded time queue, but length is 0"(_length>0);
            _length--;
            return event;
        }

        ulong cyclesInPast = max(now.cycles - poppedTime.cycles, 0);
        ulong binsInPast = cyclesInPast / resolutionDividers[0];

        while (binsInPast>0) {
            calcNextEntryHint();

            DBG_ASSERT!"Calculated next entry hint is 0 when it shouldn't be. Phase %s bin empty state %s"(
                    nextEntryHint>0, phase, bins[0][phase % numBins].empty );

            ulong advanceCount = min( binsInPast, nextEntryHint );
            advancePhase( advanceCount );
            binsInPast -= advanceCount;

            event = bins[0][phase % numBins].popHead();
            if( event !is T.init ) {
                ASSERT!"Successfully popped element from cascaded time queue, but length is 0"(_length>0);
                _length--;
                return event;
            }
        }

        DBG_ASSERT!"Time isn't \"now\" at end of unsuccessful pop. unpopped %s now %s"(
                abs(poppedTime.cycles - now.cycles) <= resolutionCycles, poppedTime, now );

        return T.init;
    }

    void insert(T entry) nothrow @safe @nogc {
        // DMDBUG compile by package sometimes thinks this function is pure, which causes linker errors :-(
        notPure();

        void updateHint(ulong binsInFuture) {
            if( nextEntryHint <= binsInFuture )
                return;

            static if(INTERNAL_VERBOSITY)
                DEBUG!"XXX entry hint moved %s=>%s"(nextEntryHint, binsInFuture);

            nextEntryHint = binsInFuture;
        }

        static if(INTERNAL_VERBOSITY)
            DEBUG!"XXX insert entry %s popped time %s base time %s phase %s"(
                    entry.timePoint, poppedTime, baseTimes[0], phase );

        if (entry.timePoint <= poppedTime) {
            // Already expired entries all go to the same bin
            static if(INTERNAL_VERBOSITY)
                DEBUG!"XXX insert at first bin, level 0 bin %s"(phase%numBins);
            bins[0][phase % numBins].append(entry);
            updateHint(0);
        } else if(entry.timePoint>=endTimes[numLevels-1]) {
            static if(INTERNAL_VERBOSITY)
                DEBUG!"XXX No room for entry %s in cascaded queue (ending at %s). Inserted in overflow"(
                        entry.timePoint, endTimes[numLevels-1] );
            overflow[activeOverflow].append(entry);

            ulong binsInFuture = (endTimes[numLevels-1].cycles - poppedTime.cycles) / resolutionDividers[0];
            updateHint(binsInFuture);

            version (unittest) {
                stats[numLevels]++;
            }
        } else {
            ulong binsInFuture;

            // Find out which level we need to insert at
            uint level;
            while( entry.timePoint >= endTimes[level] ) {
                binsInFuture += (numBins - phaseInLevel(level)) * rawBinsInBin(level);
                level++;
                DBG_ASSERT!"Entry %s is pass end of queue %s"(level<numLevels, entry.timePoint, endTimes[numLevels-1]);
            }

            version (unittest) {
                stats[level]++;
            }

            ulong cyclesInLevel = entry.timePoint.cycles - baseTimes[level].cycles;
            ulong idxInLevel = cyclesInLevel / resolutionDividers[level];
            DBG_ASSERT!"Phase %s in level %s bigger than idxInLevel %s. Base time %s cycles per bin %s(%s)"(
                    idxInLevel >= phaseInLevel(level), phaseInLevel(level), level, idxInLevel, baseTimes[level],
                    resolutionCycles*rawBinsInBin(level), resolutionCycles );
            ulong binsInFutureDelta = (idxInLevel - phaseInLevel(level)) * rawBinsInBin(level);
            DBG_ASSERT!
                    "Insert %s bins in future %s(+%s) bigger than level %s size %s. Base time %s cycles per bin %s(%s)"
                (binsInFutureDelta<binsInLevel(level), entry.timePoint, binsInFuture, binsInFutureDelta, level,
                    binsInLevel(level), baseTimes[level], resolutionCycles*rawBinsInBin(level), resolutionCycles);
            binsInFuture += binsInFutureDelta;
            idxInLevel %= numBins;

            updateHint(binsInFuture);

            bins[level][idxInLevel].append(entry);
            static if(INTERNAL_VERBOSITY)
                DEBUG!"XXX insert at level %s bin %s binsInFuture %s"(level, idxInLevel, binsInFuture);
        }

        _length++;
    }

    int opApply(scope int delegate(T t, uint level, uint bin) @nogc dg) @nogc {
        foreach(uint level; 0..numLevels) {
            foreach(uint bin; 0..numBins) {
                foreach(ref T event; bins[level][bin].range()) {
                    if( dg(event, level, bin) )
                        return 1;
                }
            }
        }

        return 0;
    }

private:
    @notrace ulong binsTillNextEntry() nothrow @safe @nogc {
        calcNextEntryHint();

        return nextEntryHint;
    }

    static ulong rawBinsInBin(uint level) pure nothrow @safe @nogc {
        DBG_ASSERT!"Level passed is too big %s<%s"(level<=numLevels, level, numLevels);
        return numBins ^^ level;
    }

    static ulong binsInLevel(uint level) pure nothrow @safe @nogc {
        return rawBinsInBin(level+1);
    }

    uint phaseInLevel(uint level) pure const nothrow @safe @nogc {
        ulong levelPhase = phase / rawBinsInBin(level);

        return levelPhase % numBins;
    }

    void calcNextEntryHint() nothrow @safe @nogc {
        if( nextEntryHint!=0 )
            return;

        ref ListType nextLevelList(uint level) pure {
            if( level<numLevels-1 ) {
                return bins[level+1][phaseInLevel(level+1)];
            } else {
                return overflow[activeOverflow];
            }
        }

        foreach( uint level; 0..numLevels ) {
            foreach( idx; phaseInLevel(level) .. numBins ) {
                if( !bins[level][idx].empty )
                    return;

                nextEntryHint += rawBinsInBin(level);
            }

            if( !nextLevelList(level).empty ) {
                // The first bin of the next level is not empty. We have to unwrap it before we can figure out what's
                // the next event to be handled, so set the hint to point to it.
                continue;
            }

            // First bin of next level is empty, but we might have entries in this level after the fold
            ulong speculativeHintDelta;
            foreach( idx; 0 .. phaseInLevel(level) ) {
                if( !bins[level][idx].empty ) {
                    nextEntryHint += speculativeHintDelta;
                    static if(INTERNAL_VERBOSITY)
                        DEBUG!"XXX calculated new hint %s"(nextEntryHint);

                    return;
                }

                speculativeHintDelta += rawBinsInBin(level);
            }
        }

        if( overflow[activeOverflow].empty ) {
            // If we've reached here, then the entire CTQ is empty
            nextEntryHint = ulong.max;
        }

        static if(INTERNAL_VERBOSITY)
            DEBUG!"XXX calculated new hint %s"(nextEntryHint);
    }

    @notrace void advancePhase( ulong advanceCount ) nothrow @safe @nogc {
        if( advanceCount==0 )
            return;

        assertOp!"<="( advanceCount, nextEntryHint, "Tried to advance the phase past the next entry" );
        uint[numLevels] oldPhases = -1;
        oldPhases[0] = phaseInLevel(0);

        bool needCascading = oldPhases[0] + advanceCount >= numBins-1;
        if( needCascading ) {
            foreach( uint level; 1..numLevels ) {
                oldPhases[level] = phaseInLevel(level);
            }
        }

        phase += advanceCount;
        if( nextEntryHint !is ulong.max )
            nextEntryHint -= advanceCount;

        poppedTime += advanceCount * resolutionCycles;

        if( !needCascading ) {
            // Stayed in same level. Only thing to do is update the level's end
            endTimes[0] += advanceCount * resolutionCycles;
            return;
        }

        uint maxAffectedLevel;
        ulong levelBinsToAdvance = advanceCount;
        foreach( uint level; 0..numLevels ) {
            maxAffectedLevel = level;

            endTimes[level] += levelBinsToAdvance * rawBinsInBin(level) * resolutionCycles;

            levelBinsToAdvance += oldPhases[level];
            levelBinsToAdvance /= numBins;
            if( levelBinsToAdvance==0 )
                break;

            ulong cyclesAdvanced = levelBinsToAdvance * binsInLevel(level) * resolutionCycles;
            baseTimes[level] += cyclesAdvanced;
            DBG_ASSERT!"Level %s end level time %s does not match start level time %s (should be %s)"(
                (endTimes[level].cycles - baseTimes[level].cycles) / (binsInLevel(level)*resolutionCycles) == 1,
                level, endTimes[level], baseTimes[level], baseTimes[level] + binsInLevel(level)*resolutionCycles);
        }

        if( (phase % (numBins ^^ numLevels)) == 0 && !overflow[activeOverflow].empty ) {
            maxAffectedLevel = numLevels;
        }

        if( maxAffectedLevel>0 )
            cascadeLevel( maxAffectedLevel );
    }

    @notrace void cascadeLevel( uint maxLevel ) nothrow @safe @nogc {
        bool firstCascaded = true;

        uint effectiveMaxLevel = min(maxLevel, numLevels-1);
        foreach( uint level; 1..effectiveMaxLevel+1 ) {
            // The bin to clear is the one right *before* the current one
            uint binToClearIdx = previousBinIdx(level);

            auto binToClear = &bins[level][ binToClearIdx ];
            if( !binToClear.empty && firstCascaded ) {
                firstCascaded = false;
            }

            while( !binToClear.empty ) {
                auto event = binToClear.popHead();
                ASSERT!"During cascading, length is 0 when bins have entries"(_length>0);
                _length--;
                insert(event);
            }
        }

        if( maxLevel==numLevels ) {
            // Cascade the overflow
            auto outOverflow = &overflow[activeOverflow];
            activeOverflow = (activeOverflow + 1) % 2; // Switch to other buffer
            auto inOverflow = &overflow[activeOverflow];

            DBG_ASSERT!"Passive overflow not empty before switch"( inOverflow.empty );

            TscTimePoint ctqEnd = endTimes[numLevels-1];
            while( !outOverflow.empty ) {
                T entry = outOverflow.popHead();
                if( entry.timePoint >= ctqEnd ) {
                    inOverflow.append(entry);
                } else {
                    /*
                      We could do only this, but as most entries in the overflow will usually remain in the overflow,
                      this if should save a few cycles.
                    */
                    DBG_ASSERT!"Length is 0 while moving entries from overflow"(_length>0);
                    _length--;
                    insert(entry);
                }
            }
        }

        DBG_ASSERT!"nextEntryHint incorrect after cascading"( firstCascaded || nextEntryHint!=ulong.max );
    }

    uint previousBinIdx( uint level ) pure const nothrow @safe @nogc {
        return (phaseInLevel(level) + numBins - 1) % numBins;
    }

    @notrace void notPure() const nothrow @trusted @nogc {
        if( numBins==0 ) // Which it never is
            notPureDMDBUG++; // Cannot be pure.
    }
}

version(unittest):
private:
bool popOne(T, size_t numBins, size_t numLevels, bool hasOwner)
    (ref CascadingTimeQueue!(T, numBins, numLevels, hasOwner) ctq, TscTimePoint now, void delegate(T) validate = null)
{
    T entry;
    bool foundSomething;

    while( (entry = ctq.pop(now)) !is null ) {
        if( validate !is null )
            validate(entry);

        // Make sure the time is correct
        assert( entry.timePoint>TscTimePoint(now.cycles - ctq.resolutionCycles) &&
                entry.timePoint<TscTimePoint(now.cycles+ctq.resolutionCycles) );

        foundSomething = true;
    }

    return foundSomething;
}

void wait(CTQ)(ref CTQ ctq, ref TscTimePoint now) {
    auto oldNow = now;
    auto delta = ctq.cyclesTillNextEntry(now);
    now = TscTimePoint( now.cycles + delta );
    DEBUG!"Advanced from %s to %s (delta %s)"(oldNow, now, delta);
    assert(delta>0);
}

unittest {
    META!"UT test time queue's levels test 1"();
    static struct Entry {
        TscTimePoint timePoint;
        Entry* _next;
        Entry* _prev;
    }

    enum resolution = 10;
    enum numBins = 4;
    enum numLevels = 3;
    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    ctq.open(resolution, TscTimePoint(0));

    Entry[] entries;
    entries ~= Entry(TscTimePoint(30));
    entries ~= Entry(TscTimePoint(0));
    entries ~= Entry(TscTimePoint(41));
    entries ~= Entry(TscTimePoint(70));
    entries ~= Entry(TscTimePoint(71));
    entries ~= Entry(TscTimePoint(110));
    entries ~= Entry(TscTimePoint(111));
    entries ~= Entry(TscTimePoint(150));
    entries ~= Entry(TscTimePoint(151));
    entries ~= Entry(TscTimePoint(190));
    entries ~= Entry(TscTimePoint(191));
    entries ~= Entry(TscTimePoint(350));
    entries ~= Entry(TscTimePoint(351));
    entries ~= Entry(TscTimePoint(510));
    entries ~= Entry(TscTimePoint(511));
    entries ~= Entry(TscTimePoint(643));
    entries ~= Entry(TscTimePoint(670));
    entries ~= Entry(TscTimePoint(671));
    entries ~= Entry(TscTimePoint(830));

    foreach( ref entry; entries ) {
        ctq.insert( &entry );
    }

    foreach( Entry* entry, uint level, uint bin; ctq ) {
        DEBUG!"Entry %s level %s bin %s"(*entry, level, bin);
    }

    assertEQ(entries.length, ctq.length);

    auto now = TscTimePoint(0);
    while( true ) {
        long wait = ctq.cyclesTillNextEntry(now);
        DEBUG!"now %s cycles to wait %s"( now, wait );
        if( wait == ulong.max )
            break;

        Entry* entry = ctq.pop(now);
        if( wait!=0 )
            assert( entry is null );
        else {
            if( entry !is null )
                DEBUG!"Extracted entry %s from queue"( entry.timePoint );
            else
                INFO!"Non-zero wait but pop returned nothing"();
        }

        now += wait;
    }

    assertEQ(0, ctq.length);
}

unittest {
    META!"UT test time queue's levels test 2"();
    import std.stdio;
    import std.string;
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
    scope(success) ctq.close();
    static assert (ctq.spanInBins == (numBins-1) * 16^^2 + 1);

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
            scope(failure) writefln("%s:%s (%s..%s, %s)", e.name, e.timePoint, then, now, ctq.baseTimes[0]);
            assert (e.timePoint.cycles/resolution <= now/resolution, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e.timePoint.cycles/resolution >= then/resolution - 1, "tp=%s then=%s now=%s".format(e.timePoint, then, now));
            assert (e in entries);
            entries.remove(e);
        }
        then = now;
    }
    assert (entries.length == 0, "Entries not empty: %s".format(entries));

    auto e7 = insert(ctq.baseTimes[0] + resolution * (ctq.spanInBins), "e7");

    insert(ctq.baseTimes[0] + resolution * (ctq.spanInBins + ctq.binsInLevel(2)), "e8");
    assert (ctq.stats[numLevels] == 1);

    auto e = ctq.pop(e7.timePoint + resolution);
    assert (e is e7, "%s".format(e));
}

unittest {
    META!"UT test time queue with captured values"();
    import std.stdio;
    import std.string;
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
        auto covered = ctq.baseTimes[0].diff!"cycles"(t0) / double(cyclesPerSecond);
        auto expectedCover = span.total!"msecs" * (2.5 / 1000);
        assert (covered >= expectedCover - 2, "%s %s".format(covered, expectedCover));

        writeln(totalInserted, " ", totalPopped, " ", ctq.stats);
        foreach(i, s; ctq.stats[0..numLevels]) {
            assert (s > 0, "level %s never received events".format(i));
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
    META!"UT testing time queue with actual times"();
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

    TscTimePoint now = TscTimePoint.hardNow;

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
        INFO!"Entry %s at %s"( e.name, (e.timePoint - now).toString );
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
        DEBUG!"Setting time forward by %s to %s"(TscTimePoint.toDuration(step).toString, (now - base).toString);
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

/+
unittest {
    META!"UT testing run with a reactor"();
    import mecca.reactor;
    Reactor.OpenOptions options;
    options.timerGranularity = 100.usecs;

    int numRuns;

    FiberHandle handle;

    void looper() {
        DEBUG!"Num runs %s"(numRuns);
        if( ++numRuns > 100 )
            theReactor.resumeFiber(handle);
    }

    void testBody() {
        handle = theReactor.currentFiberHandle();

        theReactor.registerRecurringTimer(dur!"seconds"(1), &looper);

        theReactor.suspendCurrentFiber();
    }

    testWithReactor(&testBody, options);

    DEBUG!"Total runs %s"(numRuns);
}
+/

unittest {
    META!"UT testing random time queue operations"();
    // Test the cascading
    import std.random;

    Mt19937 random;
    auto seed = unpredictableSeed;
    random.seed(seed);
    scope(failure) INFO!"Running with seed %s"(seed);

    enum long resolution = 4;
    enum numBins = 4;
    enum numLevels = 4;

    struct Entry {
        TscTimePoint timePoint;
        uint id;
        Entry* _next;
        Entry* _prev;
    }

    TscTimePoint[uint] entries;
    uint nextId;

    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    auto now = TscTimePoint(0);
    ctq.open(resolution, now);
    size_t numEntriesInQueue;

    void insert() {
        Entry* entry;
        entry = new Entry;

        uint level = uniform(0, numLevels-1, random);
        ulong range = 0;
        foreach( l; 0..level+1 ) {
            range = resolution * ctq.binsInLevel(level);
        }

        entry.timePoint = TscTimePoint( now.cycles + uniform(0, range, random) );
        entry.id = nextId++;

        entries[entry.id] = entry.timePoint;

        DEBUG!"Pushing entry %s timepoint %s"(entry.id, entry.timePoint);
        ctq.insert(entry);
        numEntriesInQueue++;
        assertEQ( ctq.length, numEntriesInQueue );
    }

    void popAll() {
        Entry* entry;
        while( (entry = ctq.pop(now)) !is null ) {
            DEBUG!"At %s popped entry %s timepoint %s"(now, entry.id, entry.timePoint);
            numEntriesInQueue--;
            assertEQ( numEntriesInQueue, ctq.length );
            assert( entries[entry.id] == entry.timePoint );
            entries.remove(entry.id);

            // Make sure the time is correct
            ASSERT!"entry %s popped at incorrect time. %s<%s<%s"(
                    entry.timePoint>TscTimePoint(now.cycles - resolution) &&
                    entry.timePoint<TscTimePoint(now.cycles+resolution),
                    entry.id,
                    TscTimePoint(now.cycles - resolution),
                    entry.timePoint,
                    TscTimePoint(now.cycles + resolution));
        }
    }

    foreach(i; 0..10) {
        insert();
    }

    while( entries.length > 0 ) {
        popAll();

        if( nextId<1000 ) {
            insert();
            insert();
        }
        auto oldNow = now;
        now = TscTimePoint( now.cycles + ctq.cyclesTillNextEntry(now) );
        DEBUG!"Advanced from %s to %s phase %s(%s)"(oldNow, now, ctq.phaseInLevel(0), ctq.phase);
    }

    assertEQ( ctq.length, 0 );
}

unittest {
    // Expose a specific problem not visible under random testing
    META!"UT for specific problems found"();

    enum long resolution = 10;
    enum numBins = 4;
    enum numLevels = 3;

    struct Entry {
        TscTimePoint timePoint;
        uint id;
        Entry* _next;
        Entry* _prev;
    }

    TscTimePoint[uint] entries;
    uint nextId;

    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    auto now = TscTimePoint(0);
    ctq.open(resolution, now);

    void insert(TscTimePoint time) {
        Entry* entry;
        entry = new Entry;

        entry.timePoint = time;
        entry.id = nextId++;

        entries[entry.id] = entry.timePoint;

        DEBUG!"Pushing entry %s timepoint %s"(entry.id, entry.timePoint);
        ctq.insert(entry);
    }

    void validate(Entry* entry) {
        DEBUG!"At %s popped entry %s timepoint %s"(now, entry.id, entry.timePoint);
        assert( entries[entry.id] == entry.timePoint );
        entries.remove(entry.id);
    }

    bool popOne() {
        return .popOne(ctq, now, &validate);
    }

    void popAll() {
        while( !popOne() ) {
            wait(ctq, now);
        }
    }

    // insert a point that goes in the first bin of the second level
    insert( TscTimePoint(9) );
    popOne();
    //now += 9; // Give it a time point that is almost, but not quite, to the next bucket
    Entry* tmpRes = ctq.pop(now); // This should not return anything
    assert( tmpRes is null );

    /* Now insert something that is distant enough from our current time to be in the first bucket of the second level,
       but from the starting point should go into the second bucket of the second level.
     */
    insert( TscTimePoint(91) );
    insert( TscTimePoint(99) );
    popOne();
    popOne();
}

unittest {
    META!"UT for overflow support"();

    enum long resolution = 4;
    enum numBins = 4;
    enum numLevels = 2;

    struct Entry {
        TscTimePoint timePoint;
        Entry* _next;
        Entry* _prev;
    }

    Entry[] entries;

    entries.reserve(10);
    CascadingTimeQueue!(Entry*, numBins, numLevels) ctq;
    auto now = TscTimePoint(0);
    ctq.open(resolution, now);
    scope(exit) ctq.close();

    void insert(TscTimePoint point) {
        entries ~= Entry(point);
        ctq.insert(&entries[$-1]);
    }

    void popOne() {
        while( !.popOne(ctq, now) ) {
            wait(ctq, now);
        }
    }

    insert(TscTimePoint(74)); // Level 1 bin 3 => L0 b3
    insert(TscTimePoint(101)); // Level 2 => L1 b1

    popOne();
    auto timeToWait = ctq.binsTillNextEntry();
    assert( timeToWait!=ulong.max, "CTQ failed to account for entry in overflow" );

    // After the pop pointer has moved, insert two points before and after the second point
    insert(TscTimePoint(90)); // L1 b0
    insert(TscTimePoint(120)); // L1 b2

    popOne();
    popOne();
    popOne();

    timeToWait = ctq.binsTillNextEntry();
    assertEQ( timeToWait, ulong.max, "Empty CTQ does not return infinite wait" );
}

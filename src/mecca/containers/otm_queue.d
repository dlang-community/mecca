/// Lock free one-to-many queues
///
/// Both single-consumer/multi-producer and multi-consumer/single-producer variants are provided.
///
/// The implementations sacrifice fairness to efficiency. In the SCMP case, the size of the queue
/// should be much larger than the thread count to avoid starving any threads. Fairness in the MCSP
/// case is not as important for us, as we are willing to "waste" threads as long as the queue is
/// constantly depleted.
///
/// The methods corresponding to the "single" end (producer/consumer) are not thread-safe; full
/// synchronisation is required to move that role between threads.
module mecca.containers.otm_queue;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.atomic;
import core.thread: thread_isMainThread;
import std.string;
import std.stdint: intptr_t;

import mecca.log;
import mecca.lib.exception;

private enum UtExtraDebug = false;

/**
 * Single consumer multiple producers queue
 *
 * Params:
 * T = the type handled by the queue.
 * size = the number of raw elements in the queue (actual queue size will be somewhat smaller). Must be a power of 2.
 */
struct SCMPQueue(T, size_t size)
{
    // This is "just" a performance issue rather than an actual problem. It is a major performance issue, however.
    static assert( (size & -size) == size, "One to many queue size not a power of 2" );

private:
    static struct Slot {
        shared ubyte phase = 1;
        T data;
    }

    Slot[size] queue;
    shared ulong readIndex;
    shared ulong writeIndex;

    // No synchronization here because the number of producers is constant while multiple threads are
    // accessing the object.
    size_t maxQueueCapacity = size - 1;
    @property producers() pure const nothrow @safe @nogc { return size - 1 - maxQueueCapacity; }

public:
    /**
     * Register number of producers
     *
     * The queue algorithm requires a bound on the number of threads that might concurrently push new elements.
     * This function increases the number of such producer threads (which lowers the effective queue capacity).
     *
     * This function must only be called before the producer threads start to execute. (That is, either before
     * the threads are spawned, or by explicitly, externally, synchronizing between the last `addProducer(s)`
     * call and the first `push` call.)
     */
    void addProducers(size_t numProducers) nothrow @nogc @safe {
        ASSERT!"addProducer called on an already active queue"(readIndex==0 && writeIndex==0);
        const newCapacity = maxQueueCapacity - numProducers;
        DBG_ASSERT!"Cannot register %s producers on queue of size %s with %s producers already"
                (newCapacity >= size / 2, numProducers, size, producers);
        maxQueueCapacity = newCapacity;
    }

    /// ditto
    void addProducer() nothrow @safe @nogc {
        addProducers(1);
    }

    /**
     * Report the effective capacity of the queue.
     *
     * Effective capacity will be smaller than the queue size, depending on the number of producers registered.
     */
    @property size_t effectiveCapacity() pure const nothrow @safe @nogc {
        return maxQueueCapacity;
    }

    /**
     * Report whether the queue is currently full.
     *
     * Please note that the value returned may change by other threads at any point.
     */
    @property bool isFull() const nothrow @safe @nogc {
        // We use raw memory order to make the check cheap: Even if writeIndex is out of date for a producer, the
        // (size - maxQueueCapacity) extra elements make sure it is safe to go ahead with push(). If readIndex is
        // not up to date, a producer might wait unnecessarily long for space to become available, which is not
        // an issue.
        //
        // Note that we assume here that there are no indices around that are separated by more than
        // an integer range. Given that we are using ulongs, this is a solid assumption in practice,
        // as a wraparound will happen at most every few hundreds of years.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        return maxQueueCapacity <= (myWriteIndex - myReadIndex);
    }

    /**
     * Pop a value from the queue
     *
     * Pop one value from the queue, if one is available. Must only be called from the (single) consumer thread.
     *
     * Params:
     * result = out parameter where to store the result.
     *
     * Returns:
     * true if a value was, indeed, popped from the queue. False if the queue was empty.
     */
    @notrace bool pop(out T result) nothrow @nogc {
        version (unittest) {
            sanity();
            scope(exit) sanity();
        }

        // We are the only one modifying the read index; no synchronization needed to read back
        // our own store.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);

        // Relaxed memory order is fine here, we will synchronize with the store to `.data` by virtue
        // of the acquire read of phase below.
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);
        if (myWriteIndex == myReadIndex) {
            return false;
        }

        const myPhase = atomicLoad!(MemoryOrder.acq)(queue[myReadIndex % size].phase);
        if (myPhase != calcPhase(myReadIndex)) {
            return false;
        }

        result = queue[readIndex % size].data;

        atomicStore!(MemoryOrder.raw)(readIndex, myReadIndex + 1);
        return true;
    }

    /**
     * push a value into the queue.
     *
     * Push a single value into the queue.
     *
     * Params:
     * data = value to push.
     *
     * Returns:
     * true if value was successfully pushed. False if the queue was full.
     */
    @notrace bool push(T data) nothrow @nogc {
        DBG_ASSERT!"Must register number of concurrent producers"( producers>0 );
        version (unittest) {
            sanity();
            scope(exit) sanity();
        }

        if (isFull()) {
            return false;
        }

        const myPtr = atomicOp!"+="(writeIndex, 1) - 1;
        queue[myPtr % size].data = data;
        DBG_ASSERT!"Phase is already correct for new produce. myPtr %s queue[%d].phase = %d"(
                atomicLoad!(MemoryOrder.acq)(queue[myPtr % size].phase) != calcPhase(myPtr),
                myPtr, myPtr % size, calcPhase(myPtr));
        atomicStore!(MemoryOrder.rel)(queue[myPtr % size].phase, calcPhase(myPtr));

        return true;
    }

private:
    static ubyte calcPhase(ulong ptr) nothrow @safe @nogc {
        return (ptr / size) &1;
    }

    version (unittest) @notrace void sanity() nothrow @safe @nogc {
        version(assert) {
            const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
            const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);
            ASSERT!"readIndex %d > writeIndex %d"(myReadIndex <= myWriteIndex, myReadIndex, myWriteIndex);
        }
        // Since we don't want to enforce SC on the consumer pointer, we cannot be sure of an override,
        // this is JUST a speculation, the following assert should remain commented out.
        // assert(producer - consumer <= size,
        //        format("An override occurred! writeIndex %d, readIndex %d size %d",
        //               producer, consumer, size));
    }
}

/**
 * Multiple consumers single producer queue
 *
 * Params:
 * T = the type handled by the queue.
 * size = the number of raw elements in the queue (actual queue size will be somewhat smaller). Must be a power of 2.
 */
struct MCSPQueue(T, size_t size)
{
    // This is a performance issue rather than an actual problem. It is a major performance issue, however.
    static assert( (size & -size) == size, "One to many queue size not a power of 2" );

private:
    static struct Slot {
        shared ubyte phase = 0;
        T data;
    }

    Slot[size] queue;
    shared ulong readIndex;
    shared ulong writeIndex;

public:
    /**
     * Report the effective capacity of the queue.
     *
     * Effective capacity will be slightly smaller than the queue size, due to algorithm related constraints.
     */
    @property size_t effectiveCapacity() nothrow @safe @nogc {
        return size - 1;
    }

    /**
     * Report whether the queue is currently full.
     *
     * Please note that the value returned may change by other threads at any point.
     */
    @property bool isFull() nothrow @safe @nogc {
        // We use raw memory order to make the check cheap: The worst that can happen is that readIndex
        // lags far behind the consumers, in which case the producer might wait unnecessarily before pushing
        // more elements.
        //
        // Note that we assume here that there are no indices around that are separated by more than
        // an integer range. Given that we are using ulongs, this is a solid assumption in practice,
        // as a wraparound will happen at most every few hundreds of years.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        return effectiveCapacity <= (myWriteIndex - myReadIndex);
    }

    /**
     * Pop a value from the queue
     *
     * Attempt to pop one value from the queue, if one is available.
     *
     * Note: Failure to pop a value from the queue does not necessarily mean that the queue is empty.
     *
     * Params:
     * result = out parameter where to store the result.
     *
     * Returns:
     * true if a value was, indeed, popped from the queue. False if failed.
     */
    @notrace bool pop(out T result) nothrow @nogc {
        // See whether there might be data available.
        //
        // A raw load is fine for the read index in terms of correctness, as we will (try to) claim the slot
        // using a sequentially consistent cas() later anyway. The worst thing that can happen is that we
        // needlessly wait for the producer for a while.
        //
        // For the write index we need an acquire load, as this is the point of synchronisation with the
        // producer and its store to `.data`.
        //
        // To make the "no new data" case a bit cheaper on platforms where acquire loads are
        // expensive, the initial check could be done using a relaxed load and an acquire barrier
        // could be inserted after the slot has been claimed.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
        const myWriteIndex = atomicLoad!(MemoryOrder.acq)(writeIndex);
        if (myWriteIndex <= myReadIndex) {
            return false;
        }

        // Try to claim the slot for reading.
        if (!cas(&readIndex, myReadIndex, myReadIndex + 1)) {
            // Another consumer snatched it from us.
            return false;
        }

        result = queue[myReadIndex % size].data;

        // We have read the data, so toggle the phase to allow the producer to write to this slot
        // when it arrives at it the next time around.
        const nextPhase = cast(ubyte)(1 - calcPhase(myReadIndex));
        atomicStore!(MemoryOrder.rel)(queue[myReadIndex % size].phase, nextPhase);

        return true;
    }

    /**
     * push a value into the queue.
     *
     * Push a single value into the queue. This is only safe to call from the (single) producer thread.
     *
     * Params:
     * data = value to push.
     *
     * Returns:
     * true if value was successfully pushed. False if the queue was full.
     */
    @notrace bool push(T data) nothrow @nogc {
        if (isFull()) {
            return false;
        }

        // We are the only one modifying the write index; no synchronization needed to read back
        // our own store.
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        // Make sure that the phase is back to "produce" mode.
        const myPhase = atomicLoad!(MemoryOrder.acq)(queue[myWriteIndex % size].phase);
        if (myPhase != calcPhase(myWriteIndex)) {
            // We have wrapped and the consumers have not read the data yet.
            return false;
        }

        queue[myWriteIndex % size].data = data;

        // Make stored data visible to consumers.
        atomicStore!(MemoryOrder.rel)(writeIndex, myWriteIndex + 1);

        return true;
    }

private:
    static ubyte calcPhase(ulong ptr) nothrow @safe @nogc {
        return (ptr / size) &1;
    }
}

unittest {
    import std.stdio;
    import core.exception;
    import core.thread;

    // start by creating a single thread with many producers
    SCMPQueue!(void*, 4) q;
    void* a;
    assert(q.effectiveCapacity == 3, format("expected capacity of 3 found %d", q.effectiveCapacity));
    q.addProducer();
    assert(q.effectiveCapacity == 2);
    assert(!q.isFull());
    assert(!q.pop(a));
    assert(q.push(cast(void*)1));
    assert(q.push(cast(void*)2));
    assert(q.isFull(), format("capacity %d widx %d ridx %d isFull %d",
                              q.effectiveCapacity, q.writeIndex, q.readIndex, q.isFull));
    assert(q.pop(a));
    assert(cast(ulong)a == 1);
    assert(q.pop(a));
    assert(cast(ulong)a == 2);
    assert(!q.pop(a));

    SCMPQueue!(void*, 128) q2;

    int totalIter = 100;
    void produceNumbers(int initial) {
        //writeln("will produce from ", initial, " to ", initial + total);
        foreach(num; initial .. initial + totalIter) {
            while(!q2.push(cast(void*)num)) { }
        }
        //writeln("\nFinished producing from ", initial, " to ", initial + total);
    }

    debug(longrun) {
        enum numProducers = 120;
    } else {
        enum numProducers = 24;
    }

    class ProducerThread : Thread {
        int producerId;
        this (int id) {
            producerId = id;
            super(&run, 512 * 1024);
        }

    private:
        void run() {
            try {
                produceNumbers(producerId * totalIter);
            } catch (AssertError e) {
                writeln("\n\n Caught assertion ", e);
            }
        }
    }
    //writeln("Going to create producers");
    Thread[numProducers] producerThreads;
    foreach(i ; 0 .. numProducers) {
        q2.addProducer();
        assert(q2.effectiveCapacity == 127 - i - 1);
        producerThreads[i] = new ProducerThread(i);
    }
    foreach(i ; 0 .. numProducers) {
        producerThreads[i].start();
    }

    ulong[] popped;
    //writeln("Going to start consuming, max capacity is ", q2.effectiveCapacity);
    foreach(i; 0 .. numProducers*totalIter) {
        while(!q2.pop(a)) {}
        popped ~= cast(ulong)a;
    }

    foreach(i ; 0 .. numProducers) {
        producerThreads[i].join();
    }

    // TODO: join back all threads, make sure the arr is empty
    assert(q2.readIndex == q2.writeIndex,
           format("After all the work, arr is not empty. consumer %d producer %d",
                  q2.readIndex, q2.writeIndex));


    assert(popped.length == numProducers * totalIter);
    import std.algorithm;
    import std.range;
    foreach (i ; 0 .. numProducers) {
        //writefln("Will look for x between %d and %d", totalIter *i , totalIter*(i+1));
        auto some = popped
            .filter!(x => ( totalIter * i <= x) && (x < (i+1) * totalIter ))
            .array;
        //writefln("Array for %d is %s", i, some);
        assert(some.length == totalIter, format("Received invalid length %d != %d", some.length, totalIter ));
        auto calc = iota( totalIter* i, (i+1) *totalIter).array;
        assert(some == calc,
               format("Did not receive correct result %s != %s", some,calc ));
    }

    //writeln("\n\n Multi Consumers: spawning threads");
    // Now going to test multi consumer single producer case
    MCSPQueue!(void*, 16) mcq;
    assert(mcq.effectiveCapacity == 15);

    debug(longrun) {
        enum numConsumers = 1000; // 1000 consumers for 16 slots queue
        enum producedElementNum = 100_000;
    } else {
        enum numConsumers = 100; // 100 consumers for 16 slots queue
        enum producedElementNum = 1_000;
    }

    shared( shared(ulong)[])[numConsumers] consumedData;
    shared bool stillRunning = true;

    class ConsumerThread : Thread {
        int consumerId;
        this(int _consumerId) {
            consumerId = _consumerId;
            super(&run, 512 * 1024);
        }

    private:
        void run() {
            // This is the actual code. Just consume messages until requested to
            // stop
            try {
                void* a;
                while (stillRunning) {
                    foreach(i ; 0 .. 2000) {
                        if(mcq.pop(a)) {
                            consumedData[consumerId] ~= cast(ulong)a;
                        }
                    }
                }
                if(mcq.pop(a)) {
                    consumedData[consumerId] ~= cast(ulong)a;
                }
            } catch (AssertError e) { // The thread.join shoule also throw, but just in case...
                writeln("\n\n Caught assertion ", e);
            }
        }
    }

    ConsumerThread[numConsumers] threads;
    foreach(i; 0 .. numConsumers) {
        threads[i] = new ConsumerThread(i);
        threads[i].start();
    }

    //writeln("All threads are running. Going to produce values: ", producedElementNum);
    foreach (i ; 0 .. producedElementNum) {
        while(!mcq.push(cast(void*)i)) {}
    }
    stillRunning = false;
    //writeln("Finished producing values, will wait for threads to join");
    foreach(i ; 0 .. numConsumers) {
        threads[i].join();
    }

    //writeln("Now will make sure data is correct");

    ulong[] result;
    foreach(l; consumedData) {
        foreach(d; l) {
            result ~= d;
        }
    }

    assert(result.length == producedElementNum, format("Total result length is not correct. Expected %d found %d", producedElementNum, result.length));
    result.sort();
    foreach(i; 0 .. producedElementNum) {
        assert(result[i] == i,
               format("result at location %d is %d", i, result[i]));
    }

    //writeln("Done");
}

/**
 * Request/response construct for sending requests from one requester to multiple worker threads
 *
 * Params:
 * T = type of request. Must be small enough to support atomic loading and storing.
 * capacity = the queue buffer size.
 */
struct DuplexQueue(T, size_t capacity) {
    MCSPQueue!(T, capacity) inputs;
    SCMPQueue!(T, capacity) outputs;

    /**
     * Register number of worker threads
     *
     * Must be called before using the queue.
     */
    void open(size_t numWorkers) {
        outputs.addProducers(numWorkers);
    }

    /**
     * Submit a single request
     */
    @notrace bool submitRequest(T val) nothrow @nogc {
        pragma(inline, true);
        return inputs.push(val);
    }
    /// Receive a single response
    @notrace bool pullResult(out T val) nothrow @nogc {
        pragma(inline, true);
        return outputs.pop(val);
    }

    /**
     * worker-thread APIs
     */
    @notrace bool pullRequest(out T val) nothrow @nogc {
        pragma(inline, true);
        return inputs.pop(val);
    }
    /// ditto
    @notrace bool submitResult(T val) nothrow @nogc {
        pragma(inline, true);
        return outputs.push(val);
    }
}

unittest {
    import std.stdio;
    import core.thread;

    DuplexQueue!(void*, 512) dq;
    enum void* POISON = cast(void*)0x7fff_ffff_ffff_ffffUL;

    enum ulong numElems = 200_000;
    enum NumThreads = 17;
    ulong inputsSum;
    ulong outputsSum;
    ulong numReplies;

    align(64) struct WorkerTracker {
        ulong numRequests;
        ulong numReplies;
        ulong[numElems] requests;
    }

    static if(UtExtraDebug) {
        static __gshared WorkerTracker[] workerTrackers = new WorkerTracker[NumThreads];
    }

    class Worker: Thread {
        ulong id;

        this(ulong id) {
            this.id = id;
            super(&run, 512*1024);
        }

        void run() {
            static if(UtExtraDebug) {
                WorkerTracker* tracker = &workerTrackers[id];
                DEBUG!"Started test thread %s tracker %s"(id, tracker);
            } else {
                DEBUG!"Started test thread %s"(id);
            }

            while (true) {
                void* p;
                if (dq.pullRequest(p)) {
                    // DEBUG!"RI %s"(cast(ulong)p);

                    static if(UtExtraDebug) {
                        tracker.requests[tracker.numRequests++] = cast(ulong)p;
                    }
                    if (p is POISON) {
                        DEBUG!"Breaking from thread %s due to test finished"(id);
                        break;
                    }

                    while (!dq.submitResult(p)) {}
                    // DEBUG!"WO %s"(cast(ulong)p);
                    static if(UtExtraDebug) {
                        tracker.numReplies++;
                    }
                }
            }
        }
    }

    Worker[NumThreads] workers;
    dq.open(workers.length);

    DEBUG!"Launching threads"();
    foreach(i, ref worker; workers) {
        // DEBUG!"Started worker"();
        worker = new Worker(i);
        worker.start();
    }

    void fetchReplies() {
        void* p;
        while (dq.pullResult(p)) {
            //writeln("RO ", cast(ulong)p);
            assert (p !is POISON);
            outputsSum += cast(ulong)p;
            numReplies++;
        }
    }

    DEBUG!"Starting test"();
    for (ulong i = 1; i <= numElems;) {
        if( (i%1024)==0 )
            DEBUG!"#UT otm_queue sent %s requests"(i);

        if (dq.submitRequest(cast(void*)i)) {
            //writeln("WI ", i);
            inputsSum += i;
            i++;
        }
        fetchReplies();
    }

    DEBUG!"Sending poison"();
    for (int numPosions = 0; numPosions < workers.length;) {
        if (dq.submitRequest(POISON)) {
            //DEBUG!"Poisoning %s"(numPosions);
            numPosions++;
        }
        fetchReplies();
    }

    ulong repliesReported;
    while( numReplies<numElems ) {
        if( repliesReported!=numReplies ) {
            DEBUG!"Fetching remaining replies (%s/%s fetched)"( numReplies, numElems );
            repliesReported = numReplies;
        }
        fetchReplies();
    }

    DEBUG!"Joining all threads"();
    foreach(worker; workers) {
        worker.join(true);
        // DEBUG!"Worker joined"();
    }

    auto computedSum = ((1+numElems) * numElems)/2;
    assert (computedSum == inputsSum, "comp %s != inp %s".format(computedSum, inputsSum));
    assert (outputsSum == inputsSum, "out %s != inp %s".format(outputsSum, inputsSum));

    DEBUG!"Test successfully done"();
}

unittest {
    import std.stdio;
    import core.thread;
    import std.datetime;

    DuplexQueue!(ushort, 256) dq;
    enum ushort POISON = 32767;

    class Worker: Thread {
        static shared int idCounter;
        int id;
        this() {
            this.id = atomicOp!"+="(idCounter, 1);
            super(&thdfunc);
        }
        void thdfunc() {
            ushort req;
            DEBUG!"Started test thread %s"(id);
            while (true) {
                if (dq.pullRequest(req)) {
                    if (req == POISON) {
                        DEBUG!"Breaking from thread %s due to test finished"(id);
                        break;
                    }
                    //writefln("[%s] fetched %s", id, req);
                    Thread.sleep(10.usecs);
                    while (!dq.submitResult(req)) {
                        Thread.sleep(10.usecs);
                    }
                }
            }
        }
    }

    Worker[17] workers;
    dq.open(workers.length);
    foreach(ref thd; workers) {
        thd = new Worker();
        thd.start();
    }

    ulong totalRequests;
    ulong totalResults;
    ulong numRequests;
    ulong numResults;

    enum streak = 50;
    enum iters = 50_000;
    ushort counter = 9783;

    while (numRequests < iters) {
        foreach(j; 0 .. streak) {
            ushort req = counter % 16384;
            counter++;
            if (!dq.submitRequest(req)) {
                break;
            }
            //writefln("pushed %s", req);
            totalRequests += req;
            numRequests++;
        }
        foreach(_; 0 .. streak) {
            ushort res;
            if (!dq.pullResult(res)) {
                break;
            }
            //writefln("pulled %s", res);
            totalResults += res;
            numResults++;
        }
    }

    void fetchAll(int attempts, Duration delay=100.usecs) {
        foreach(_; 0 .. attempts) {
            Thread.sleep(delay);
            ushort res;
            while (dq.pullResult(res)) {
                totalResults += res;
                numResults++;
            }
        }
    }
    fetchAll(10);

    foreach(_; workers) {
        //writeln("POISON");
        while (!dq.submitRequest(POISON)) {
            Thread.sleep(10.usecs);
        }
    }
    fetchAll(10);

    foreach(thd; workers) {
        thd.join();
    }
    fetchAll(1);

    assert (totalRequests == totalResults && numRequests == numResults,
        "%s=%s %s=%s".format(totalRequests, totalResults, numRequests, numResults));
}

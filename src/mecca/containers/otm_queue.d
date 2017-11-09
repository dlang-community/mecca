/// Lock free one-to-many queues
module mecca.containers.otm_queue;

import core.atomic;
import core.thread: thread_isMainThread;
import std.string;
import std.stdint: intptr_t;

import mecca.log;
import mecca.lib.exception;

private enum UtExtraDebug = false;

/******************************************************************************************************
 * Lock-free 1-to-many queue, either single consumer multi producers, or single producer multi
 * consumers.
 * The queue sacrifices fairness to efficiency. The size of the queue should be much larger than the
 * thread count to make sure all threads get the produce.
 * The consuming part is naturally not as important, as we're willing to "waste" threads as long as the
 * queue is constantly depleted.
 *
 * There is a STRONG assumption that the single part NEVER CHANGES ITS EXECUTING CPU CORE.
 * The single (producer/consumer) is not marked as shared, and may not be correct if that role is
 * moved to another core.
 ******************************************************************************************************/

/**
 * Single consumer multiple producers queue
 *
 * Params:
 * T = the type handled by the queue. Must be one that supports atomic operations.
 * size = the number of raw elements in the queue (actual queue size will be somewhat smaller). Must be a power of 2.
 */
struct SCMPQueue(T, size_t size)
{
    // This is "just" a performance issue rather than an actual problem. It is a major performance issue, however.
    static assert( (size & -size) == size, "One to many queue size not a power of 2" );
    static assert(
            __traits( compiles, { shared T t; atomicLoad!(MemoryOrder.raw)(t); } ), "T is incompatible with atomic operations" );

private:
    static struct QueueNode {
        shared ubyte phase = 1;
        T data;
    }

    QueueNode[size] queue;
    shared ulong readIndex;
    shared ulong writeIndex;

    // No synchronization here because it is only accessed from the main thread.
    ulong producers;
    size_t maxQueueCapacity = size - 1;

public:
    /**
     * Register number of producers
     *
     * For the algorithm to know, the queue must know how many concurrent threads might be pushing data at any point.
     * This function add producers to the number of currently registered producers.
     *
     * This function must only be called from the main thread, and before any queue activity has actually started.
     */
    void addProducers(size_t numProducers) nothrow @nogc @safe {
        ASSERT!"addProducer called on an already active queue"(readIndex==0 && writeIndex==0);
        DBG_ASSERT!"Cannot register %s producers on queue of size %s with %s producers already"
                ( numProducers+producers < size/2, numProducers, size, producers );
        producers += numProducers;
        maxQueueCapacity -= numProducers;
        DBG_ASSERT!"queue capacity calculation is off. Capacity %s size %s producers %s registered now %s"
                ( maxQueueCapacity == size - producers - 1,
                  maxQueueCapacity,
                  size,
                  producers,
                  numProducers );
    }

    /// ditto
    void addProducer() nothrow @safe @nogc {
        addProducers(1);
    }

    /**
     * Report the effective capacity of the queue.
     *
     * Effective capacity might be smaller than the queue size, due to algorithm related constraints. It also depends on the
     * number of producers registered.
     */
    @property size_t effectiveCapacity() pure const nothrow @safe @nogc {
        return maxQueueCapacity;
    }

    /**
     * Report whether the queue is currently full.
     *
     * Please note that the value returned may change by other threads at any point.
     */
    @property bool isFull() const nothrow @trusted @nogc {
        // This has the same version for multi consumer and multi producers.
        // * For multi producers the readIndex may not have updated, so the worst to happen
        //   is that a producer will not produce, and will just try again later
        // * For multi consumers, since there is a single producer thread with the correct value
        //
        // Note that this assumes that there are no pointers around from cycles that are separated by more
        // than one pointer wraparound. Given that we are using ulongs, this is a solid assumption in
        // practice, even if theoritically a bit unsound in terms of the memory model.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        return maxQueueCapacity <= (myWriteIndex - myReadIndex);
    }

    /**
     * Pop a value from the queue
     *
     * Pop one value from the queue, if one is available. Only one thread can simulteneously safely call this function.
     *
     * Params:
     * T = out parameter where to store the result.
     *
     * Returns:
     * true if a value was, indeed, popped from the queue. False if the queue was empty.
     */
    @notrace bool pop(out T result) nothrow @trusted @nogc {
        version (unittest) {
            sanity();
            scope(exit) sanity();
        }

        // A raw load is fine in either case. For a single consumer, this is obviously up to date.
        // For multiple consumers, we will do a sequentially consistent cas() to claim a slot later
        // anyway, so the worst thing that can happen is that we needlessly wait for produce for
        // some time.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);

        // Relaxed memory order is fine here, we will synchronize with the data store by virtue
        // of the acquire read of phase below.
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        if (myWriteIndex == myReadIndex) {
            return false;
        }

        if (atomicLoad!(MemoryOrder.acq)(queue[myReadIndex % size].phase) != calcPhase(myReadIndex)) {
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
    @notrace bool push(T data) nothrow @trusted @nogc {
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

    version (unittest) @notrace void sanity() nothrow @system @nogc {
        version(assert) {
            const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
            const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);
            ASSERT!"writeIndex %d < ConsumerPtr %d"(myReadIndex <= myWriteIndex, myReadIndex, myWriteIndex);
        }
        // Since we don't want to enforce SC on the consumer pointer, we cannot be sure of an override,
        // this is JUST a speculation, the following ASSERT should remain commented out.
        // assert(producer - consumer <= size,
        //        format("An override occurred! writeIndex %d, readIndex %d size %d",
        //               producer, consumer, size));
    }
}

/**
 * Multiple consumers single producer queue
 *
 * Params:
 * T = the type handled by the queue. Must be one that supports atomic operations.
 * size = the number of raw elements in the queue (actual queue size will be somewhat smaller). Must be a power of 2.
 */
struct MCSPQueue(T, size_t size)
{
    // This is a performance issue rather than an actual problem. It is a major performance issue, however.
    static assert( (size & -size) == size, "One to many queue size not a power of 2" );
    static assert(
            __traits( compiles, { shared T t; atomicLoad!(MemoryOrder.raw)(t); } ), "T is incompatible with atomic operations" );
private:
    static struct QueueNode {
        shared ubyte phase = 0;
        T data;
    }

    QueueNode[size] queue;
    shared ulong readIndex;
    shared ulong writeIndex;

    // No synchronization here because it is only accessed from the main thread.
    ulong producers;

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
    @property bool isFull() nothrow @trusted @nogc {
        // This has the same version for multi consumer and multi producers.
        // * For multi producers the readIndex may not have updated, so the worst to happen
        //   is that a producer will not produce, and will just try again later
        // * For multi consumers, since there is a single producer thread with the correct value
        //
        // Note that this assumes that there are no pointers around from cycles that are separated by more
        // than one pointer wraparound. Given that we are using ulongs, this is a solid assumption in
        // practice, even if theoritically a bit unsound in terms of the memory model.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        return effectiveCapacity <= (myWriteIndex - myReadIndex);
    }

    /**
     * Pop a value from the queue
     *
     * Attempt to pop one value from the queue, if one is available.
     *
     * Please note that failure to pop a value from the queue does not necessarily mean that the queue is empty.
     *
     * Params:
     * T = out parameter where to store the result.
     *
     * Returns:
     * true if a value was, indeed, popped from the queue. False if failed.
     */
    @notrace bool pop(out T result) nothrow @trusted @nogc {
        // A raw load is fine in either case. For a single consumer, this is obviously up to date.
        // For multiple consumers, we will do a sequentially consistent cas() to claim a slot later
        // anyway, so the worst thing that can happen is that we needlessly wait for produce for
        // some time.
        const myReadIndex = atomicLoad!(MemoryOrder.raw)(readIndex);

        // Because incrementing writeIndex is the only thing the producer gives us to synchronize
        // with it storing the new data. To make the "no new data" case a bit cheaper on platforms
        // where acquire loads are expensive, the initial check could be done using a relaxed load
        // and an acquire barrier could be inserted after the slot has ben claimed.
        const myWriteIndex = atomicLoad!(MemoryOrder.acq)(writeIndex);

        if (myWriteIndex <= myReadIndex) {
            return false;
        }

        // Try to claim the slot for reading.
        if (!cas(&readIndex, myReadIndex, myReadIndex + 1)) {
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
     * Push a single value into the queue. Only one thread can simulteneously safely call this function.
     *
     * Params:
     * data = value to push.
     *
     * Returns:
     * true if value was successfully pushed. False if the queue was full.
     */
    @notrace bool push(T data) nothrow @trusted @nogc {
        if (isFull()) {
            return false;
        }

        // We are the only one modifying the producer pointer, no synchronization needed.
        const myWriteIndex = atomicLoad!(MemoryOrder.raw)(writeIndex);

        // Make sure that the phase is back to "produce" mode.
        if (atomicLoad!(MemoryOrder.acq)(queue[myWriteIndex % size].phase) != calcPhase(myWriteIndex)) {
            // We have wrapped and the consumers have not read the data yet.
            return false;
        }

        queue[myWriteIndex % size].data = data;
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

    for (ulong i = 1; i <= numElems;) {
        if (dq.submitRequest(cast(void*)i)) {
            //writeln("WI ", i);
            inputsSum += i;
            i++;
        }
        fetchReplies();
    }

    for (int numPosions = 0; numPosions < workers.length;) {
        if (dq.submitRequest(POISON)) {
            //DEBUG!"Poisoning %s"(numPosions);
            numPosions++;
        }
        fetchReplies();
    }

    while( numReplies<numElems ) {
        fetchReplies();
    }

    foreach(worker; workers) {
        worker.join(true);
        // DEBUG!"Worker joined"();
    }

    auto computedSum = ((1+numElems) * numElems)/2;
    assert (computedSum == inputsSum, "comp %s != inp %s".format(computedSum, inputsSum));
    assert (outputsSum == inputsSum, "out %s != inp %s".format(outputsSum, inputsSum));
    //writeln("done2");

    // DEBUG!"Test done"();
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

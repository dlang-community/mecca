/// Reactor aware queue that waits for operations to be possible
module mecca.reactor.sync.queue;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.containers.queue;
import mecca.lib.time;
import mecca.log;
import mecca.reactor.sync.semaphore : Semaphore;

/**
 * Reactor aware fixed size queue.
 *
 * Unlike mecca.container.queue, this queue does not assert when an operation cannot be fulfilled. Instead, it blocks the calling fiber
 * until the operation can be completed.
 *
 * Params:
 *  Type = the item type to be used.
 *  MaxItems = the queue's capacity.
 */
struct BlockingQueue(Type, ushort MaxItems) {
private:
    alias QueueType = Queue!(Type, MaxItems);

    QueueType queue;
    Semaphore syncPush = Semaphore(MaxItems);
    Semaphore syncPop = Semaphore(MaxItems, MaxItems);

public:
    /**
     * Returns true if no items are currenlty queued.
     *
     * Calling pop will block IFF empty is true.
     */
    @property bool empty() const pure nothrow @safe @nogc {
        return syncPop.level == 0;
    }
    /**
     * Returns true if trying to add a new item would block.
     *
     * Calling push will block IFF full is true.
     */
    @property bool full() const pure nothrow @safe @nogc {
        return syncPush.level == 0;
    }

    /**
     * Add an item to the queue.
     *
     * Params:
     *  item = item to add.
     *  timeout = how long to wait if no room to add immediately.
     */
    @notrace void push(Type item, Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPush.acquire(1, timeout);
        queue.push(item);
        syncPop.release();
    }
    /**
     * Pushes an uninitialized item to the queue.
     *
     * For items that are faster to initialize in place than to copy, this form will be faster.
     *
     * Params:
     *  timeout = how long to wait if no room to add immediately.
     *
     * Returns:
     *  A pointer to the newly created item, so it can be filled with values.
     */
    @notrace Type* push(Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPush.acquire(1, timeout);
        auto ret = queue.push();
        syncPop.release();
        return ret;
    }

    /**
     * Pop a single element from the queue
     *
     * Params:
     *  timeout = how long to wait if no items are immediately available.
     */
    @notrace Type pop(Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPop.acquire(1, timeout);
        auto ret = queue.pop();
        syncPush.release();
        return ret;
    }
    // @notrace ref const(Type) peek(Timeout timeout = Timeout.infinite) @safe @nogc {
    /*
     * Peek is not implemented, because there is almost no safe way of using it. The only safe way to use it is to hold a critical section
     * while the reference is alive, as any sleep might invalidate the reference. Since many implementations still do pop at the end of
     * processing, I (Shachar) have decided to leave out any implementation at all.
     */

    /**
     * Wait until all current fibers waiting to push have done so.
     *
     * This method follows the principle that ugly functionality should have an ugly name. This function is only reliably useful if you know
     * there is only one fiber that can push to the queue.
     *
     * This method waits until all fibers currently waiting to push have done so, and then waits for an empty slot to clear up. If only one
     * fiber is pushing, this guarantees that the next call to push will not have to sleep.
     *
     * Please note that if more than one fiber might be pushing items to the queue, no such guarantee exists even if a push is attempted
     * immediately after this method returns. The reason is that fibers that asked to push after this fiber called the method are ahead of
     * the future push event in line.
     */
    void pushWaitersQueueWaitForHead(Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPush.acquire(1, timeout);
        syncPush.release();
    }
}

version(unittest) {
    import mecca.reactor;
    import mecca.lib.exception;

    class BlockingQueueTests {
        enum SIZE = 10;
        private BlockingQueue!(int, SIZE) queue;

        private void fillQueue() {
            assert(queue.empty);
            foreach (i; 0 .. SIZE) {
                assert(!queue.full);
                queue.push(i, Timeout.elapsed);
            }
            assert(queue.full);
        }

        private void popTotal(size_t total) {
            auto timeout = Timeout(10.seconds);
            foreach (i; 0 .. total) {
                queue.pop(timeout);
            }

            assertThrows!TimeoutExpired(queue.pop(Timeout(1.seconds)));
        }

        @mecca_ut void multipleWaitingToPush() {
            fillQueue();

            ulong numRunning = 0;
            void pushFib() {
                numRunning++;
                scope(success) numRunning--;
                assert(queue.full);
                queue.push(1000, Timeout(10.seconds));
            }

            foreach (_; 0 .. SIZE) {
                theReactor.spawnFiber(&pushFib);
            }
            while(numRunning < SIZE) {
                theReactor.yield();
            }

            popTotal(SIZE * 2);
            assertEQ(numRunning, 0);
        }

        @mecca_ut void multipleWaitingNotFull() {
            fillQueue();

            ulong numRunning = 0;
            void waitThenPushFib() {
                numRunning++;
                scope(success) numRunning--;
                assert(queue.full);
                queue.push(2000, Timeout(10.seconds));
            }

            foreach (_; 0 .. SIZE) {
                theReactor.spawnFiber(&waitThenPushFib);
            }
            while(numRunning < SIZE) {
                theReactor.yield();
            }

            popTotal(SIZE * 2);
            assertEQ(numRunning, 0);
        }

        @mecca_ut void waitPop() {
            import mecca.reactor.sync.event : Event;
            Event done;
            theReactor.spawnFiber({
                foreach (i; 0 .. 2*SIZE) {
                    assertEQ(i, queue.pop(Timeout(500.msecs)));
                }
                done.set();
            });

            foreach (i; 0 .. 2*SIZE) {
                theReactor.sleep(100.msecs);
                assert(!queue.full);
                queue.push(i);
            }
            done.wait(Timeout(1.seconds));
        }
    }

    mixin TEST_FIXTURE_REACTOR!BlockingQueueTests;
}

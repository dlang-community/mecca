/// Reactor aware queue that waits for operations to be possible
module mecca.reactor.sync.queue;

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
    /**
     * Get reference to item at head of the queue.
     *
     * Params:
     *  timeout = how long to wait if no items are immediately available.
     */
    @notrace ref const(Type) peek(Timeout timeout = Timeout.infinite) @safe @nogc {
        waitHasItems(timeout);
        return queue.peek();
    }

    /**
     * Suspend the fiber until the queue has at least one empty slot.
     *
     * Params:
     *  timeout = how long to wait if no items are immediately available.
     */
    @notrace void waitHasRoom(Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPush.acquire(1, timeout);
        syncPush.release();
        assert(!this.full);
    }
    /**
     * Suspend the fiber until the queue has at least one item queued.
     *
     * Params:
     *  timeout = how long to wait if no items are immediately available.
     */
    @notrace void waitHasItems(Timeout timeout = Timeout.infinite) @safe @nogc {
        syncPop.acquire(1, timeout);
        syncPop.release();
        assert(!this.empty);
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
                queue.waitHasRoom(Timeout.elapsed);
                queue.push(i, Timeout.elapsed);
            }
            assert(queue.full);
        }

        private void popTotal(size_t total) {
            auto timeout = Timeout(10.seconds);
            foreach (i; 0 .. total) {
                if (i % 2 == 0) {
                    queue.waitHasItems(timeout);
                    queue.peek(Timeout.elapsed);
                    queue.pop(Timeout.elapsed);
                } else {
                    queue.pop(timeout);
                }
            }

            assertThrows!ReactorTimeout(queue.pop(Timeout(1.seconds)));
            assertThrows!ReactorTimeout(queue.waitHasItems(Timeout(1.seconds)));
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
                theReactor.yieldThisFiber();
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
                queue.waitHasRoom(Timeout(10.seconds));
                queue.push(2000, Timeout.elapsed);
            }

            foreach (_; 0 .. SIZE) {
                theReactor.spawnFiber(&waitThenPushFib);
            }
            while(numRunning < SIZE) {
                theReactor.yieldThisFiber();
            }

            popTotal(SIZE * 2);
            assertEQ(numRunning, 0);
        }

        @mecca_ut void waitPeekPop() {
            import mecca.reactor.sync.event : Event;
            Event done;
            theReactor.spawnFiber({
                foreach (i; 0 .. 2*SIZE) {
                    queue.waitHasItems(Timeout(500.msecs));
                    assertEQ(i, queue.peek(Timeout.elapsed));
                    assertEQ(i, queue.pop(Timeout.elapsed));
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

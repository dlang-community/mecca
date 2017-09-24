/// FIFO queues
module mecca.containers.queue;

import std.traits;

import mecca.lib.exception;
import mecca.log;

/**
 * No GC FIFO queue of fixed maximal size
 *
 * Performance of queue is better if MaxSize is a power of 2.
 * Params:
 *  Type = the types to be stored in the queue. Must have .init
 *  MaxSize = the maximal number of entries the queue can hold.
 */
struct Queue(Type, ushort MaxSize) {
private:
    ushort rIndex;
    ushort wIndex;
    ushort count;
    @notrace Type[MaxSize] items;

    // enum Copyable = isCopyable!Type;
    // XXX isCopyable not supported on all compilers:
    enum Copyable = true;
public:
    /// Alias for the item type used by the queue
    alias ItemType = Type;
    /// Reports the capacity of the queue
    enum capacity = MaxSize;

    /**
     * Construct a Queue already filled with supplied items.
     */
    this(Type[] initItems...) nothrow @safe @nogc {
        ASSERT!"Queue constructor called with %s initialization items, but capacity is only %s"(
                initItems.length <= capacity, initItems.length, capacity);
        count = cast(ushort)initItems.length;
        rIndex = 0;
        wIndex = count;
        items[0 .. initItems.length] = initItems;
    }

    string toString() const pure @safe {
        import std.string : format;

        return format("CyclicQueue!(%s, %s/%s)", Type.stringof, count, capacity);
    }

    /// Report current queue's length
    @property auto length() const pure nothrow @safe @nogc {
        return count;
    }
    /// Returns true if queue is empty
    @property bool empty() const pure nothrow @safe @nogc {
        return count == 0;
    }
    /// Returns true if queue is full
    @property bool full() const pure nothrow @safe @nogc {
        return count == capacity;
    }

    /**
     * Pushes one item to the queue. Queue must have room for new item.
     */
    static if(Copyable) {
    @notrace void push(Type item) nothrow @safe @nogc {
        ASSERT!"Trying to push to full queue"(count < capacity);
        count++;
        items[wIndex] = item;
        wIndex = (wIndex + 1) % capacity;
    }
    }

    /**
     * Pushes an uninitialized item to the queue.
     *
     * For items that are faster to initialize in place than to copy, this form will be faster.
     *
     * Returns:
     *  A pointer to the newly created item, so it can be filled with values.
     */
    @notrace Type* push() nothrow @safe @nogc {
        ASSERT!"Trying to push to full queue"(count < capacity);
        count++;
        items[wIndex] = Type.init;
        auto ret = &items[wIndex];
        wIndex = (wIndex + 1) % capacity;
        return ret;
    }

    version(notQueue) {
    @notrace void pushHead(Type item) {
        enforceEx!QueueFullException(count < capacity, "Queue is full");
        count++;
        if( rIndex==0 )
            rIndex = capacity;
        rIndex--;
        items[rIndex] = item;
    }
    }

    static if(Copyable) {
    /**
     * Pop a single element from the queue
     */
    @notrace Type pop() nothrow @safe @nogc {
        ASSERT!"Trying to pop from empty queue"(count > 0);
        count--;
        auto tmp = items[rIndex];
        items[rIndex] = Type.init;
        rIndex = (rIndex + 1) % capacity;
        return tmp;
    }
    }
    /**
     * Get reference to item at head of the queue.
     *
     * If Type is not copyable, the only way to remove an element from the queue is to look at it using peek, followed by removeHead
     */
    @notrace ref const(Type) peek() const nothrow @safe @nogc {
        ASSERT!"Trying to peek at empty queue"(count > 0);
        return items[rIndex];
    }

    /// Delete the head element
    void removeHead() nothrow @safe @nogc {
        ASSERT!"Trying to pop from empty queue"(count > 0);
        count--;
        items[rIndex] = Type.init;
        rIndex = (rIndex + 1) % capacity;
    }

    /**
     * Remove all items from the queue
     */
    void removeAll() nothrow @safe @nogc {
        rIndex = wIndex = count = 0;
        items[] = Type.init;
    }

    version(XXX) {
    /**
     * Remove all items that compare equal to provided item.
     *
     * Returns:
     * Number of items removed
     */
    @notrace uint removeAll(Type item) nothrow @safe @nogc {
        uint numRemoved = 0;

        for (auto i = 0; i < count; i++) {
            auto j = (rIndex + i) % capacity;
            if (items[j] == item) {
                if (wIndex >= j) {
                    // avoid 'Overlapping arrays in copy'
                    foreach(k; j .. wIndex - 1) {
                        items[k] = items[k+1];
                    }
                    items[wIndex - 1] = Type.init;
                }
                else {
                    items[j .. $ - 1] = items[j + 1 .. $];
                    if (wIndex != 0) {
                        items[$ - 1] = items[0];
                        // avoid 'Overlapping arrays in copy'
                        foreach(k; 0 .. wIndex - 1) {
                            items[k] = items[k+1];
                        }
                        items[wIndex - 1] = Type.init;
                    }
                }
                count--;
                wIndex = cast(ushort)((wIndex - 1) % capacity);
                numRemoved++;
                i--;
            }
        }
        return numRemoved;
    }
    }
}

unittest {
    import std.stdio;
    import std.string;
    import std.conv;

    @notrace static class MyClass {
        int x, y;

        this(int x, int y) {
            this.x = x;
            this.y = y;
        }

        override string toString() const {
            return format("MyClass(%s, %s)", x, y);
        }
        override bool opEquals(Object o) nothrow @safe @nogc {
            auto c = cast(MyClass)o;
            return c && c.x == x && c.y == y;
        }
    }

    auto q = Queue!(MyClass, 10)(new MyClass(1, 2), new MyClass(3, 4));
    q.push(new MyClass(5,6));
    assert(q.length == 3);

    //q.pushHead( new MyClass(7,8) );

    auto m = q.pop();
    //assert(m.x == 7 && m.y == 8, to!string(m));
    //m = q.pop();
    assert(m.x == 1 && m.y == 2, to!string(m));
    m = q.pop();
    assert(m.x == 3 && m.y == 4, to!string(m));
    m = q.pop();
    assert(m.x == 5 && m.y == 6, to!string(m));

    assert(q.empty);
    assertThrows!AssertError( q.pop() );

    foreach (int i; 0 .. q.capacity) {
        q.push(new MyClass(i, i*2));
    }
    assert(q.full);
    assertThrows!AssertError( q.push(new MyClass(100,200)) );

    q.removeAll();
    assert(q.empty);
    foreach (int i; 0 .. q.capacity) {
        q.push(new MyClass(i, i*2));
    }
    assert(q.full);
    foreach (int i; 0 .. 4) {
        m = q.pop();
        assert(m.x == i && m.y == i * 2, to!string(m));
    }
    foreach (int i; q.capacity .. q.capacity + 4) {
        q.push(new MyClass(i, i*2));
    }
    assert(q.full);
    /+
    assert(q.removeAll(new MyClass(8, 16)) == 1, to!string(q.items));
    assert(!q.full);
    assert(q.removeAll(new MyClass(8, 16)) == 0);
    assert(q.removeAll(new MyClass(12, 24)) == 1, to!string(q.items));
    assert(q.length == q.capacity - 2);
    q.push(new MyClass(20, 40));
    q.push(new MyClass(20, 40));
    assert(q.full);
    assert(q.removeAll(new MyClass(20, 40)) == 2, to!string(q.items));
    assert(q.length == q.capacity - 2, to!string(q.items));
    q.push(new MyClass(14, 28));
    q.push(new MyClass(15, 30));
    assert(q.full);

    foreach (int i; 4 .. q.capacity + 6) {
        if (i == 8 || i == 12) {
            continue;
        }
        m = q.pop();
        assert(m && m.x == i && m.y == i * 2, to!string(m));
    }
    assert(q.empty);
    +/
}

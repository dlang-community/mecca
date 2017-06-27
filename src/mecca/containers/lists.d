module mecca.containers.lists;

import mecca.lib.memory: prefetch;


///////////////////////////////////////////////////////////////////////////////////////////////////
//
// LinkedList: doubly-linked list of elements; next/prev stored in-element (intrusive)
//
///////////////////////////////////////////////////////////////////////////////////////////////////

struct _LinkedList(T, string nextAttr, string prevAttr, bool withLength) {
    T head;
    static if (withLength) {
        size_t length;
    }

    static T getNextOf(T node) nothrow {
        pragma(inline, true);
        T tmp = mixin("node." ~ nextAttr);
        prefetch(tmp);
        return tmp;
    }
    static void setNextOf(T node, T val) nothrow {
        pragma(inline, true);
        mixin("node." ~ nextAttr ~ " = val;");
    }

    static T getPrevOf(T node) nothrow {
        pragma(inline, true);
        T tmp = mixin("node." ~ prevAttr);
        prefetch(tmp);
        return tmp;
    }
    static void setPrevOf(T node, T val) nothrow {
        pragma(inline, true);
        mixin("node." ~ prevAttr ~ " = val;");
    }

    @property bool empty() const pure nothrow {
        static if (withLength) assert (head !is null || length == 0, "head is null but length != 0");
        return head is null;
    }
    @property T tail() nothrow {
        static if (withLength) assert (head !is null || length == 0, "head is null but length != 0");
        return head is null ? null : getPrevOf(head);
    }

    void _insert(bool after)(T anchor, T node) nothrow {
        assert (node !is null, "appending null");
        assert (getNextOf(node) is null, "next is linked");
        assert (getPrevOf(node) is null, "prev is linked");

        if (head is null) {
            assert (anchor is null);
            static if (withLength) assert (length == 0);
            head = node;
            setNextOf(node, node);
            setPrevOf(node, node);
        }
        else {
            static if (withLength) assert (length > 1);
            static if (after) {
                auto next = getNextOf(anchor);
                setNextOf(anchor, node);
                setPrevOf(node, anchor);
                setNextOf(node, next);
                setPrevOf(next, node);
            }
            else {
                auto prev = getPrevOf(anchor);
                setNextOf(node, anchor);
                setPrevOf(node, prev);
                setPrevOf(anchor, node);
                setNextOf(prev, node);

                if (anchor is head) {
                    head = node;
                }
            }
        }

        static if (withLength) length++;
    }

    void insertAfter(T anchor, T node) nothrow {pragma(inline, true);
        _insert!true(anchor, node);
    }
    void insertBefore(T anchor, T node) nothrow {pragma(inline, true);
        _insert!false(anchor, node);
    }

    void append(T node) nothrow {pragma(inline, true);
        insertAfter(tail, node);
    }
    void prepend(T node) nothrow {pragma(inline, true);
        insertBefore(head, node);
    }

    void remove(T node) nothrow {
        assert (node);
        assert (!empty);

        if (getNextOf(head) is head) {
            // single element
            assert (node is head);
            setNextOf(node, null);
            setPrevOf(node, null);
            head = null;
        }
        else {
            auto p = getPrevOf(node);
            auto n = getNextOf(node);
            setNextOf(p, n);
            setPrevOf(n, p);
            if (node is head) {
                head = n;
            }
        }
        setNextOf(node, null);
        setPrevOf(node, null);

        static if (withLength) {
            assert (length > 0);
            length--;
        }
    }

    T popHead() nothrow {
        auto node = head;
        if (node) {
            remove(node);
        }
        return node;
    }
    T popTail() nothrow {
        auto node = tail;
        if (node) {
            remove(node);
        }
        return node;
    }

    void splice(_LinkedList* second) nothrow {
        assert (second !is &this);
        if (second.empty) {
            return;
        }
        if (empty) {
            head = second.head;
        }
        else {
            setNextOf(tail, second.head);
            setPrevOf(second.head, tail);
            setNextOf(second.tail, head);
            setPrevOf(head, second.tail);
        }

        static if (withLength) length += second.length;

        // For safety reasons, `second` is emptied (otherwise pop() from it would break this)
        second.head = null;
        static if (withLength) second.length = 0;
    }

    void removeAll() nothrow {
        while (head) {
            auto next = getNextOf(head);
            setPrevOf(head, null);
            setNextOf(head, null);
            head = (next is head) ? null : next;
        }
        static if (withLength) length = 0;
    }

    static struct Range {
        _LinkedList* list;
        T front;

        @property bool empty() const pure nothrow @nogc {
            return front is null;
        }
        void popFront() nothrow {
            assert (list);
            assert (front);
            front = getNextOf(front);
            if (front is list.head) {
                front = null;
            }
        }
    }
    @property auto range() nothrow {
        return Range(&this, head);
    }

    static struct ReverseRange {
        _LinkedList* list;
        T front;

        @property bool empty() const pure nothrow @nogc {
            return front is null;
        }
        void popFront() nothrow {
            assert (list);
            assert (front);
            front = getPrevOf(front);
            if (front is list.tail) {
                front = null;
            }
        }
    }
    @property auto reverseRange() nothrow {
        return ReverseRange(&this, tail);
    }

    static struct ConsumingRange {
        _LinkedList* list;

        @property bool empty() const pure nothrow @nogc {
            return list.empty;
        }
        @property T front() pure nothrow @nogc {
            return list.head;
        }
        void popFront() nothrow {
            list.popHead();
        }
    }
    @property auto consumingRange() nothrow {
        return ConsumingRange(&this);
    }
}

alias LinkedList(T, string nextAttr="_next", string prevAttr="_prev") = _LinkedList!(T, nextAttr, prevAttr, false);
alias LinkedListWithLength(T, string nextAttr="_next", string prevAttr="_prev") = _LinkedList!(T, nextAttr, prevAttr, true);


unittest {
    import std.stdio;
    import std.string;

    struct Node {
        int value;
        Node* _next;
        Node* _prev;

        @disable this(this);
    }

    Node[10] nodes;
    foreach(int i, ref n; nodes) {
        n.value = i;
    }

    LinkedList!(Node*) list;
    assert (list.head is null);

    list.append(&nodes[0]);
    assert (list.head.value == 0);

    list.append(&nodes[1]);
    list.append(&nodes[2]);
    list.append(&nodes[3]);
    list.append(&nodes[4]);
    list.append(&nodes[5]);
    list.append(&nodes[6]);
    list.append(&nodes[7]);
    list.append(&nodes[8]);
    list.append(&nodes[9]);
    assert (list.head.value == 0);

    void matchElements(R)(R range, int[] expected) {
        int[] arr;
        foreach(n; range) {
            arr ~= n.value;
        }
        //writeln(arr);
        assert (arr == expected, "%s != %s".format(arr, expected));
    }

    matchElements(list.range, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    matchElements(list.range, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

    list.remove(&nodes[3]);
    matchElements(list.range, [0, 1, 2, 4, 5, 6, 7, 8, 9]);

    list.remove(&nodes[0]);
    matchElements(list.range, [1, 2, 4, 5, 6, 7, 8, 9]);

    list.remove(&nodes[9]);
    matchElements(list.range, [1, 2, 4, 5, 6, 7, 8]);

    list.insertAfter(&nodes[2], &nodes[3]);
    matchElements(list.range, [1, 2, 3, 4, 5, 6, 7, 8]);

    list.insertBefore(&nodes[7], &nodes[9]);
    matchElements(list.range, [1, 2, 3, 4, 5, 6, 9, 7, 8]);

    matchElements(list.reverseRange, [8, 7, 9, 6, 5, 4, 3, 2, 1]);

    list.removeAll();
    assert (list.empty);

    list.append(&nodes[1]);
    list.append(&nodes[2]);
    list.append(&nodes[3]);

    matchElements(list.consumingRange, [1, 2, 3]);
    assert (list.empty);

}

unittest {
    import std.stdio;
    import std.string;

    struct Node {
        static Node[10] theNodes;

        int value;
        ubyte nextIdx = ubyte.max;
        ubyte prevIdx = ubyte.max;

        @property Node* _next() nothrow {
            return nextIdx == ubyte.max ? null : &theNodes[nextIdx];
        }
        @property void _next(Node* n) nothrow {
            nextIdx = n is null ? ubyte.max : cast(ubyte)(n - theNodes.ptr);
        }

        @property Node* _prev() nothrow {
            return prevIdx == ubyte.max ? null : &theNodes[prevIdx];
        }
        @property void _prev(Node* n) nothrow {
            prevIdx = n is null ? ubyte.max : cast(ubyte)(n - theNodes.ptr);
        }
    }

    foreach(int i, ref n; Node.theNodes) {
        n.value = 100 + i;
    }

    LinkedList!(Node*) list;
    assert (list.head is null);

    list.append(&Node.theNodes[0]);
    assert (list.head.value == 100);

    list.append(&Node.theNodes[1]);
    list.append(&Node.theNodes[2]);
    list.append(&Node.theNodes[3]);
    list.append(&Node.theNodes[4]);
    list.append(&Node.theNodes[5]);
    list.append(&Node.theNodes[6]);
    list.append(&Node.theNodes[7]);
    list.append(&Node.theNodes[8]);
    list.append(&Node.theNodes[9]);
    assert (list.head.value == 100);

    list.remove(&Node.theNodes[5]);
    list.remove(&Node.theNodes[6]);

    int[] arr;
    foreach(n; list.range) {
        arr ~= n.value;
    }
    assert(arr == [100, 101, 102, 103, 104, 107, 108, 109]);
}


///////////////////////////////////////////////////////////////////////////////////////////////////
//
// LinkedQueue: singly-linked list of elements; next pointer is stored in-element (intrusive).
//              insert in the head or tail, from only from head
//
///////////////////////////////////////////////////////////////////////////////////////////////////

struct _LinkedQueue(T, string nextAttr, bool withLength) {
    T head;
    T tail;
    static if (withLength) {
        size_t length;
    }

    static T getNextOf(T node) nothrow {
        pragma(inline, true);
        T tmp = mixin("node." ~ nextAttr);
        prefetch(tmp);
        return tmp;
    }
    static void setNextOf(T node, T val) nothrow {
        pragma(inline, true);
        mixin("node." ~ nextAttr ~ " = val;");
    }

    @property empty() const pure nothrow @safe @nogc {
        static if (withLength) {
            assert ((head is null && tail is null && length == 0) || (head !is null && tail !is null && length > 0));
        }
        else {
            assert ((head is null && tail is null) || (head !is null && tail !is null));
        }
        return head is null;
    }

    void append(T node) nothrow {
        assert (getNextOf(node) is null, "Appending non-free node to list");
        assert (node !is head && node !is tail, "Appending an invalid node to list");

        if (empty) {
            head = tail = node;
        }
        else {
            setNextOf(tail, node);
            tail = node;
        }
        static if (withLength) length++;
    }
    void prepend(T node) nothrow {
        assert (getNextOf(node) is null && node !is head && node !is tail);

        if (empty) {
            head = tail = node;
        }
        else {
            setNextOf(node, head);
            head = node;
        }
        static if (withLength) length++;
    }

    T popHead() nothrow {
        assert (!empty);

        auto node = head;
        head = getNextOf(head);
        setNextOf(node, null);
        static if (withLength) length--;

        if (head is null) {
            tail = null;
            static if (withLength) assert (length == 0);
        }

        return node;
    }

    void removeAll() nothrow {
        while (!empty) {
            popHead();
        }
    }

    void splice(_LinkedQueue* second) nothrow {
        assert (second !is &this);
        if (second.empty) {
            return;
        }
        if (empty) {
            head = second.head;
        }
        else {
            setNextOf(tail, second.head);
        }

        tail = second.tail;
        static if (withLength) length += second.length;

        // For safety reasons, `second` is emptied (otherwise pop() from it would break this)
        second.head = null;
        second.tail = null;
        static if (withLength) second.length = 0;
    }

    static struct Range {
        T front;

        @property empty() const pure @safe @nogc nothrow {
            return front is null;
        }
        void popFront() nothrow {
            assert (front);
            front = getNextOf(front);
        }
    }
    @property auto range() nothrow {
        return Range(head);
    }

    static struct ConsumingRange {
        _LinkedQueue* queue;

        @property empty() const pure @safe @nogc nothrow {
            return queue.empty;
        }
        @property T front() pure @safe @nogc nothrow {
            return queue.head;
        }
        void popFront() nothrow {
            queue.popHead();
        }
    }
    @property auto consumingRange() nothrow {
        return ConsumingRange(&this);
    }
}

alias LinkedQueue(T, string nextAttr="_next") = _LinkedQueue!(T, nextAttr, false);
alias LinkedQueueWithLength(T, string nextAttr="_next") = _LinkedQueue!(T, nextAttr, true);

unittest {
    import std.stdio;
    import std.string;

    static struct Node {
        int value;
        Node* _next;
    }
    Node[10] nodes;
    foreach(int i, ref n; nodes) {
        n.value = i;
    }

    LinkedQueue!(Node*) queue;
    assert (queue.empty);

    queue.append(&nodes[0]);
    assert (!queue.empty);

    queue.append(&nodes[1]);
    queue.append(&nodes[2]);
    queue.append(&nodes[3]);
    queue.append(&nodes[4]);
    queue.append(&nodes[5]);
    queue.append(&nodes[6]);

    queue.prepend(&nodes[7]);
    queue.prepend(&nodes[8]);
    queue.prepend(&nodes[9]);

    void matchElements(R)(R range, int[] expected) {
        int[] arr;
        foreach(n; range) {
            arr ~= n.value;
        }
        //writeln(arr);
        assert (arr == expected, "%s != %s".format(arr, expected));
    }

    matchElements(queue.range, [9, 8, 7, 0, 1, 2, 3, 4, 5, 6]);
    assert (!queue.empty);

    matchElements(queue.consumingRange, [9, 8, 7, 0, 1, 2, 3, 4, 5, 6]);
    assert (queue.empty);

    LinkedQueue!(Node*) queue2;

    queue.append(&nodes[0]);
    queue.append(&nodes[1]);
    queue.append(&nodes[2]);

    queue2.append(&nodes[3]);
    queue2.append(&nodes[4]);
    queue2.append(&nodes[5]);

    matchElements(queue.range, [0, 1, 2]);
    matchElements(queue2.range, [3, 4, 5]);
    queue.splice(&queue2);
    assert(queue2.empty);
    matchElements(queue.range, [0, 1, 2, 3, 4, 5]);
}

unittest {
    struct Node {
        static Node[10] theNodes;

        int value;
        ubyte nextIdx = ubyte.max;

        @property Node* _next() nothrow {
            return nextIdx == ubyte.max ? null : &theNodes[nextIdx];
        }
        @property void _next(Node* n) nothrow {
            nextIdx = n is null ? ubyte.max : cast(ubyte)(n - theNodes.ptr);
        }
    }

    foreach(int i, ref n; Node.theNodes) {
        n.value = 100 + i;
    }

    LinkedQueue!(Node*) queue;
    assert (queue.empty);

    queue.append(&Node.theNodes[0]);
    assert (!queue.empty);
    queue.append(&Node.theNodes[1]);
    queue.append(&Node.theNodes[2]);
    queue.append(&Node.theNodes[3]);
    queue.append(&Node.theNodes[4]);

    int[] arr;
    foreach(n; queue.range) {
        arr ~= n.value;
    }
    assert(arr == [100, 101, 102, 103, 104]);

    queue.removeAll();
    assert (queue.empty);
}





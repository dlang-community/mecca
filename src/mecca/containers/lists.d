module mecca.containers.lists;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;

import mecca.lib.memory: prefetch;
import mecca.lib.exception;
import mecca.log;


///////////////////////////////////////////////////////////////////////////////////////////////////
//
// LinkedList: doubly-linked list of elements; next/prev stored in-element (intrusive)
//
///////////////////////////////////////////////////////////////////////////////////////////////////

struct _LinkedList(T, string nextAttr, string prevAttr, string ownerAttr, bool withLength) {
    T head;
    static if (withLength) {
        size_t length;
    }
    enum withOwner = ownerAttr.length > 0;

    private enum MAY_PREFETCH = __traits(compiles, {T t; prefetch(t);});

    static if(isPointer!T) pure nothrow @nogc {
        private static bool isValid(const T t) pure nothrow @safe @nogc {
            return t !is null;
        }

        enum invalid = null;
    } else {
        private static bool isValid(const T t) pure nothrow @safe @nogc {
            return t.isValid;
        }

        enum invalid = T.invalid;
    }

    static assert (!isValid(invalid), "invalid is valid for type " ~ T.stringof);

    static T getNextOf(T node) nothrow @safe @nogc {
        pragma(inline, true);
        T tmp = mixin("node." ~ nextAttr);
        static if(MAY_PREFETCH) prefetch(tmp);
        return tmp;
    }
    static void setNextOf(T node, T val) nothrow @safe @nogc {
        pragma(inline, true);
        mixin("node." ~ nextAttr ~ " = val;");
    }

    static T getPrevOf(T node) nothrow @safe @nogc {
        pragma(inline, true);
        T tmp = mixin("node." ~ prevAttr);
        static if (MAY_PREFETCH) prefetch(tmp);
        return tmp;
    }
    static void setPrevOf(T node, T val) nothrow @safe @nogc {
        pragma(inline, true);
        mixin("node." ~ prevAttr ~ " = val;");
    }

    static if (withOwner) {
        @notrace private static _LinkedList* getOwnerOf(T node) nothrow @trusted @nogc {
            pragma(inline, true);
            mixin("return cast(_LinkedList*)(node." ~ ownerAttr ~ ");");
        }
        @notrace private static void clearOwnerOf(T node) nothrow @safe @nogc {
            pragma(inline, true);
            mixin("node." ~ ownerAttr ~ " = null;");
        }
    }

    @property bool empty() const pure nothrow {
        static if (withLength) assert (isValid(head) || length == 0, "head is null but length != 0");
        return !isValid(head);
    }
    @property T tail() nothrow {
        static if (withLength) assert (isValid(head) || length == 0, "head is null but length != 0");
        return isValid(head) ? getPrevOf(head) : invalid;
    }

    bool _insert(bool after)(T anchor, T node) nothrow @safe @nogc {
        assert (isValid(node), "appending null");

        static if (withOwner) {
            assert (!isValid(anchor) || getOwnerOf(anchor) is &this, "anchor does not belong to this list");
            auto owner = getOwnerOf(node);
            if (owner is &this) {
                return false;
            }
            assert (owner is null, "owner already set");
            mixin("node." ~ ownerAttr ~ " = &this;");
        }
        ASSERT!"next is linked"(!isValid(getNextOf(node)));
        ASSERT!"prev is linked"(!isValid(getPrevOf(node)));

        if (!isValid(head)) {
            assert (!isValid(anchor));
            static if (withLength) assert (length == 0);
            head = node;
            setNextOf(node, node);
            setPrevOf(node, node);
        }
        else {
            static if (withLength) assert (length > 0, "List with head has length 0");
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
        return true;
    }

    bool insertAfter(T anchor, T node) nothrow @safe @nogc {pragma(inline, true);
        return _insert!true(anchor, node);
    }
    bool insertBefore(T anchor, T node) nothrow @safe @nogc {pragma(inline, true);
        return _insert!false(anchor, node);
    }

    bool append(T node) nothrow @safe @nogc {pragma(inline, true);
        return insertAfter(tail, node);
    }
    bool prepend(T node) nothrow @safe @nogc {pragma(inline, true);
        return insertBefore(head, node);
    }

    bool remove(T node) nothrow @safe @nogc {
        assert (isValid(node));
        assert (!empty);

        static if (withOwner) {
            auto owner = getOwnerOf(node);
            if (owner is null) {
                assert (!isValid(getNextOf(node)), "no owner but next is linked");
                assert (!isValid(getPrevOf(node)), "no owner but prev is linked");
                return false;
            }
            DBG_ASSERT!"Trying to remove node that doesn't belong to list. Owner %s, this %s" (owner is &this, owner, &this);
            clearOwnerOf(node);
        }

        if (getNextOf(head) is head) {
            // single element
            assert (node is head);
            setNextOf(node, invalid);
            setPrevOf(node, invalid);
            head = invalid;
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
        setNextOf(node, invalid);
        setPrevOf(node, invalid);

        static if (withLength) {
            assert (length > 0);
            length--;
        }
        return true;
    }

    static if (withOwner) {
        bool opBinaryRight(string op: "in")(T node) const nothrow @safe @nogc {
            return getOwnerOf(node) is &this;
        }

        static bool discard(T node) nothrow @safe @nogc {
            if (auto owner = getOwnerOf(node)) {
                return owner.remove(node);
            }
            else {
                assert (!isValid(getNextOf(node)), "no owner but next is linked");
                assert (!isValid(getPrevOf(node)), "no owner but prev is linked");
                return false;
            }
        }
    }

    T popHead() nothrow @safe @nogc {
        auto node = head;
        if (isValid(node)) {
            remove(node);
        }
        return node;
    }
    T popTail() nothrow @safe @nogc {
        auto node = tail;
        if (isValid(node)) {
            remove(node);
        }
        return node;
    }

    static if (!withOwner) {
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

            // For safety reasons, `second` is emptied (otherwise pop() from it would break this)
            second.head = invalid;
            static if (withLength) {
                length += second.length;
                second.length = 0;
            }
        }
    }

    void removeAll() nothrow {
        while (isValid(head)) {
            auto next = getNextOf(head);
            setPrevOf(head, invalid);
            setNextOf(head, invalid);
            static if (withOwner) clearOwnerOf(head);
            head = (next is head) ? invalid : next;
        }
        static if (withLength) length = 0;
    }

    static struct Range {
        _LinkedList* list;
        T front;

        @property bool empty() const pure nothrow @nogc {
            return !isValid(front);
        }
        void popFront() nothrow {
            assert (list !is null);
            assert (isValid(front));
            front = getNextOf(front);
            if (front is list.head) {
                front = invalid;
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
            return !isValid(front);
        }
        void popFront() nothrow {
            assert (list);
            assert (isValid(front));
            front = getPrevOf(front);
            if (front is list.tail) {
                front = invalid;
            }
        }
    }
    @property auto reverseRange() nothrow {
        return ReverseRange(&this, tail);
    }
}

alias LinkedList(T, string nextAttr="_next", string prevAttr="_prev") = _LinkedList!(T, nextAttr, prevAttr, "", false);
alias LinkedListWithLength(T, string nextAttr="_next", string prevAttr="_prev") = _LinkedList!(T, nextAttr, prevAttr, "", true);

alias LinkedListWithOwner(T, string nextAttr="_next", string prevAttr="_prev", string ownerAttr="_owner") = _LinkedList!(T, nextAttr, prevAttr, ownerAttr, false);
alias LinkedListWithLengthAndOwner(T, string nextAttr="_next", string prevAttr="_prev", string ownerAttr="_owner") = _LinkedList!(T, nextAttr, prevAttr, ownerAttr, true);


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
}

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

    LinkedListWithLength!(Node*) list;
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
}

unittest {
    import std.stdio;
    import std.string;

    // Linked list using abstracted _next and _prev
    struct Node {
        @disable this(this);

        static Node[10] theNodes;

        int value;
        ubyte nextIdx = ubyte.max;
        ubyte prevIdx = ubyte.max;

        @property Node* _next() nothrow @safe @nogc {
            return nextIdx == ubyte.max ? null : &theNodes[nextIdx];
        }
        @property void _next(Node* n) nothrow @safe @nogc {
            nextIdx = n is null ? ubyte.max : cast(ubyte)(n - &theNodes[0]);
        }

        @property Node* _prev() nothrow @safe @nogc {
            return prevIdx == ubyte.max ? null : &theNodes[prevIdx];
        }
        @property void _prev(Node* n) nothrow @safe @nogc {
            prevIdx = n is null ? ubyte.max : cast(ubyte)(n - &theNodes[0]);
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

unittest {
    import std.stdio;
    import std.string;

    // Linked list using abstracted pointer
    struct Node {
        static Node[10] theNodes;

        static struct Ptr {
            ubyte index = ubyte.max;

            @property Node* node() nothrow @safe @nogc {
                if (index==ubyte.max)
                    return null;

                return &theNodes[index];
            }

            @property ref Ptr _prev() nothrow @safe @nogc {
                return node._prev;
            }

            @property ref Ptr _next() nothrow @safe @nogc {
                return node._next;
            }

            bool isValid() const pure nothrow @safe @nogc {
                return index != ubyte.max;
            }

            enum invalid = Ptr.init;
        }

        int value;
        Ptr _next;
        Ptr _prev;
    }

    foreach(int i, ref n; Node.theNodes) {
        n.value = 100 + i;
    }

    LinkedList!(Node.Ptr) list;
    assert (!list.head.isValid);

    list.append(Node.Ptr(0));
    assert (list.head.node.value == 100);

    list.append(Node.Ptr(1));
    list.append(Node.Ptr(2));
    list.append(Node.Ptr(3));
    list.append(Node.Ptr(4));
    list.append(Node.Ptr(5));
    list.append(Node.Ptr(6));
    list.append(Node.Ptr(7));
    list.append(Node.Ptr(8));
    list.append(Node.Ptr(9));
    assert (list.head.node.value == 100);

    list.remove(Node.Ptr(5));
    list.remove(Node.Ptr(6));

    int[] arr;
    foreach(n; list.range) {
        arr ~= n.node.value;
    }
    assert(arr == [100, 101, 102, 103, 104, 107, 108, 109], "Incorrect result: %s".format(arr));
}

unittest {
    import std.stdio;
    import std.string;

    struct Node {
        int value;
        Node* _next;
        Node* _prev;
        void* _owner;

        @disable this(this);
    }

    Node[10] nodes;
    foreach(int i, ref n; nodes) {
        n.value = i;
    }

    LinkedListWithOwner!(Node*) set;
    assert (set.empty);

    assert(set.append(&nodes[1]));
    assert(set.append(&nodes[2]));
    assert(set.append(&nodes[3]));
    assert(!set.append(&nodes[2]));

    assert (&nodes[1] in set);
    assert (&nodes[2] in set);
    assert (&nodes[3] in set);
    assert (&nodes[4] !in set);

    assert (set.remove(&nodes[2]));
    assert (&nodes[2] !in set);

    assert (!set.remove(&nodes[2]));
    assert (!set.discard(&nodes[2]));
    assert (set.discard(&nodes[1]));
    assert (&nodes[1] !in set);
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

    static T getNextOf(T node) nothrow @safe @nogc {
        pragma(inline, true);
        T tmp = mixin("node." ~ nextAttr);
        prefetch(tmp);
        return tmp;
    }
    static void setNextOf(T node, T val) nothrow @safe @nogc {
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

    void append(T node) nothrow @safe @nogc {
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
    void prepend(T node) nothrow @safe @nogc {
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

    T popHead() nothrow @safe @nogc {
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

    queue.removeAll();
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

        @property Node* _next() const nothrow @safe @nogc {
            return nextIdx == ubyte.max ? null : &theNodes[nextIdx];
        }
        @property void _next(Node* n) nothrow @safe @nogc {
            nextIdx = n is null ? ubyte.max : cast(ubyte)(n - &theNodes[0]);
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

unittest {
    // Dummy node type for list. This is means primarily to make sure no one in the list implementation is comparing to null instead of using
    // isValid. Nothing runs in this UT. If it compiles, it's fine
    struct S {
        alias OurList = _LinkedList!(S, "_next", "_prev", "owner", false);
        @property S _next() pure nothrow @nogc @safe {
            return invalid;
        }
        @property void _next(S rhs) pure nothrow @nogc @safe {
        }
        @property S _prev() pure nothrow @nogc @safe {
            return invalid;
        }
        @property void _prev(S rhs) pure nothrow @nogc @safe {
        }
        OurList* owner;
        bool isValid() const pure nothrow @safe @nogc {
            return false;
        }
        enum invalid = S.init;
    }

    S.OurList list;
}

module mecca.containers.linked_set;

import std.meta;
import mecca.lib.tracing;
import mecca.lib.memory: test_and_prefetch_read, prefetch_read;

struct Chain {
    Chain* prev;
    Chain* next;
    void*  owner;

    @disable this(this);

    @notrace private void assertNull() const pure nothrow {
        assert(owner is null && next is null && prev is null, "non empty chain");
    }
    @notrace private void disown() {
        owner = null;
        prev = null;
        next = null;
    }
}

struct LinkedSet(T, string chainName="_chain", bool withLength=false) {
    static assert (is(T == U*, U) || is(T == class), "T must be a reference type (pointer or class)");

    Chain* anchor;
    static if (withLength) {
        size_t length;
    }

    @disable this(this);

    @notrace private static Chain* getChain(bool prefetch=true)(T node) pure nothrow {
        auto c = &__traits(getMember, node, chainName);
        static if (prefetch) {
            prefetch_read(c.next);
            prefetch_read(c.prev);
        }
        return c;
    }
    @notrace private static T getContainer(Chain* chain) pure nothrow {
        enum chainOffset = __traits(getMember, T, chainName).offsetof;
        static if (is(T.PointedType)) {
            auto p = T(cast(T.PointedType*)((cast(ubyte*)chain) - chainOffset));
        }
        else {
            auto p = cast(T)((cast(ubyte*)chain) - chainOffset);
        }
        prefetch_read(p);
        //prefetch_read_maybe(p.next);
        return p;
    }
    @property bool empty() const pure nothrow {
        return anchor is null;
    }
    bool opBinaryRight(string op: "in")(T node) {
        return getChain(node).owner is &this;
    }
    @property T getHead() pure nothrow {
        return anchor is null ? T.init : getContainer(anchor.next);
    }
    @property T getTail() pure nothrow {
        return anchor is null ? T.init : getContainer(anchor.prev);
    }

    @notrace bool _push(bool append)(T node) {
        assert (node !is null);
        auto c = getChain(node);
        if (c.owner is &this) {
            return false;
        }
        c.assertNull();
        c.owner = &this;
        if (anchor is null) {
            anchor = c;
            c.next = c;
            c.prev = c;
        }
        else {
            static if (append) {
                auto tail = anchor.prev;
                tail.next = c;
                anchor.prev = c;
                c.next = anchor;
                c.prev = tail;
            }
            else {
                auto head = anchor.next;
                auto tail = anchor.prev;
                anchor = c;
                c.next = head;
                c.prev = tail;
                head.prev = c;
            }
        }
        static if (withLength) {
            length++;
        }
        return true;
    }

    alias append = _push!true;
    alias prepend = _push!false;

    @notrace void prefetchHead() {
        if (anchor !is null) {
            prefetch_read(anchor.next);
            prefetch_read(anchor.prev);
        }
    }

    @notrace T popHead() {
        if (anchor is null) {
            return T.init;
        }
        auto node = getContainer(anchor.next);
        remove(anchor.next);
        if (anchor) {
            // prefetch for next pop
            prefetch_read(anchor);
            test_and_prefetch_read(anchor.next);
            test_and_prefetch_read(anchor.prev);
        }
        return node;
    }
    @notrace T popTail() {
        if (anchor is null) {
            return T.init;
        }
        auto node = getContainer(anchor.prev);
        remove(anchor.prev);
        if (anchor) {
            // prefetch for next pop
            prefetch_read(anchor);
            test_and_prefetch_read(anchor.next);
            test_and_prefetch_read(anchor.prev);
        }
        return node;
    }

    @notrace private bool remove(Chain* c) {
        assert (c !is null);
        if (c.owner is null) {
            return false;
        }
        assert (c.owner is &this);
        assert (anchor !is null, "list is empty but node belongs to this list");
        // these are surely non-null
        prefetch_read(c.next);
        prefetch_read(c.prev);

        if (anchor.next is anchor) {
            // single element
            assert (anchor is c);
            anchor = null;
        }
        else {
            auto p = c.prev;
            auto n = c.next;
            p.next = n;
            n.prev = p;
            if (c is anchor) {
                anchor = n;
            }
        }
        static if (withLength) {
            assert (length > 0);
            length--;
        }
        c.disown();
        return true;
    }
    @notrace bool remove(T node) {
        assert (node !is null);
        return remove(getChain(node));
    }

    void removeAll() {
        while (anchor !is null) {
            auto next = anchor.next;
            anchor.disown();
            anchor = (next is anchor) ? null : next;
        }
        static if (withLength) {
            length = 0;
        }
        assert (anchor is null);
    }

    static struct Range {
        LinkedSet* list;
        Chain* curr;

        this(LinkedSet* list) {
            this.list = list;
            curr = list.anchor;
            if (curr) {
                prefetch_read(curr.next);
            }
        }
        @property bool empty() const pure nothrow {
            return curr is null;
        }
        @property T front() pure nothrow {
            return curr is null ? T.init : getContainer(curr);
        }
        void popFront() {
            assert (curr !is null);
            curr = curr.next;
            if (curr is list.anchor) {
                curr = null;
            }
            else {
                prefetch_read(curr);
            }
        }
    }

    static struct ConsumingRange {
        LinkedSet* list;
        T front;

        this(LinkedSet* list) {
            this.list = list;
            front = list.popHead();
        }
        @property bool empty() const pure nothrow {
            return front is null;
        }
        void popFront() {
            front = list.popHead();
        }
    }

    @notrace auto range() {
        return Range(&this);
    }
    @notrace auto consumingRange() {
        return ConsumingRange(&this);
    }

    @notrace static bool discard(T node) {
        auto c = getChain(node);
        if (c.owner is null) {
            return false;
        }
        else {
            (cast(LinkedSet*)(c.owner)).remove(node);
            return true;
        }
    }
}

alias LinkedSetWithLength(T, string chainName="_chain") = LinkedSet!(T, chainName, true);

unittest {
    import std.array;
    import std.algorithm;
    import std.stdio;

    static struct Node {
        uint value;
        Chain _chain;
    }
    LinkedSetWithLength!(Node*) list;

    auto n1 = Node(1);
    auto n2 = Node(2);
    auto n3 = Node(3);
    auto n4 = Node(4);
    auto n5 = Node(5);
    auto n6 = Node(6);

    assert (list.empty);
    list.append(&n1);
    assert (!list.empty);
    list.append(&n2);
    list.append(&n3);
    assert(!list.append(&n2));
    assert (list.length == 3);
    list.remove(&n2);
    assert (list.length == 2);
    assert (list.range.map!(n => n.value).array == [1, 3]);
    list.remove(&n1);
    assert (list.range.map!(n => n.value).array == [3]);
    list.remove(&n3);
    assert (list.range.map!(n => n.value).array == []);

    list.append(&n1);
    list.append(&n2);
    list.append(&n3);
    assert (list.length == 3);

    list.removeAll();
    assert (list.length == 0);
    assert (list.range.map!(e => e.value).array == []);
}





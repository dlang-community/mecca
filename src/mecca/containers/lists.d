module mecca.containers.lists;


struct LinkedList(T, string nextAttr = "_next", string prevAttr = "_prev") {
    T anchor;

    @disable this(this);

    @property static ref T nextOf(T node) {
        pragma(inline, true);
        return mixin("node." ~ nextAttr);
    }
    @property static ref T prevOf(T node) {
        pragma(inline, true);
        return mixin("node." ~ prevAttr);
    }
    private static assertUnlinked(T node) {
        assert (node !is null);
        assert (nextOf(node) is null);
        assert (prevOf(node) is null);
    }

    @property bool empty() const pure nothrow {
        return anchor is null;
    }
    @property T head() pure nothrow {
        return anchor is null ? T.init : nextOf(anchor);
    }
    @property T tail() pure nothrow {
        return anchor is null ? T.init : prevOf(anchor);
    }

    private void _push(bool append)(T node) {
        assertUnlinked(node);
        if (anchor is null) {
            anchor = node;
            nextOf(node) = node;
            prevOf(node) = node;
        }
        else {
            static if (append) {
                T tail = prevOf(anchor);
                nextOf(tail) = node;
                prevOf(anchor) = node;
                nextOf(node) = anchor;
                prevOf(node) = tail;
            }
            else {
                T head = nextOf(anchor);
                T tail = prevOf(anchor);
                anchor = node;
                nextOf(node) = head;
                prevOf(node) = tail;
                prevOf(head) = node;
            }
        }
    }

    alias append = _push!true;
    alias prepend = _push!false;

    void remove(T node) {
        assert (node);
        assert (!empty);

        if (head is anchor) {
            // single element
            assert (node is anchor);
            anchor = null;
        }
        else {
            auto p = prevOf(node);
            auto n = nextOf(node);
            nextOf(p) = n;
            prevOf(n) = p;
            if (node is anchor) {
                anchor = n;
            }
        }
        nextOf(node) = null;
        prevOf(node) = null;
    }

    T popHead() {
        auto node = head;
        if (node) {
            remove(node);
        }
        return node;
    }
    T popTail() {
        auto node = tail;
        if (node) {
            remove(node);
        }
        return node;
    }

    void removeAll() {
        while (anchor) {
            auto next = nextOf(anchor);
            prevOf(anchor) = null;
            nextOf(anchor) = null;
            anchor = (next is anchor) ? null : next;
        }
    }

    static struct Range {
        LinkedList* list;
        T front;

        @property bool empty() const pure nothrow @nogc {
            return front is null;
        }
        void popFront() {
            assert (front);
            auto front = nextOf(front);
            if (front is list.anchor) {
                front = null;
            }
        }
    }
    @property auto range() {
        return Range(&this, head);
    }


}


unittest {
    struct Node {
        ulong value;
        Node* _next;
        Node* _prev;
        @disable this(this);
    }
    Node[10] nodes;

    foreach(i, ref n; nodes) {
        n.value = i;
    }


    LinkedList!(Node*) list;
    list.append(&nodes[0]);
    list.append(&nodes[1]);
    list.append(&nodes[2]);
    list.append(&nodes[3]);
    list.append(&nodes[4]);
    list.append(&nodes[5]);
    list.append(&nodes[6]);
    list.append(&nodes[7]);
    list.append(&nodes[8]);
    list.append(&nodes[9]);

    list.remove(&nodes[3]);

    import std.stdio;
    foreach(n; list.range) {
        writeln(n.value);
    }
}












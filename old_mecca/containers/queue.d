module mecca.containers.queue;


struct IntrusiveQueue(T, string NEXT="next") {
    private size_t _length;
    private T head;
    private T tail;

    @disable this(this);
    @property auto length() const pure {return _length;}
    @property bool empty() const pure {return head is null;}
    @property T peekHead() pure {return head;}
    @property private ref T _nextOf(T elem) pure {return __traits(getMember, elem, NEXT);}

    T popHead() {
        assert(head !is null);
        assert(tail !is null);
        assert(_length > 0);
        _length--;
        auto tmp = head;
        head = _nextOf(head);
        _nextOf(tmp) = null;
        if (head is null) {
            tail = null;
            assert(_length == 0);
        }
        return tmp;
    }

    T tryPopHead() {
        return empty ? T.init : popHead();
    }

    void pushTail(T elem) {
        assert(_nextOf(elem) is null);
        if (tail is null) {
            assert(head is null);
            assert(_length == 0);
            head = elem;
        }
        else {
            assert(head !is null);
            _nextOf(tail) = elem;
        }
        tail = elem;
        _length++;
    }

    void pushHead(T elem) {
        import std.string;
        assert(_nextOf(elem) is null, "elem=%s next=%s".format(elem, elem.next));
        if (head is null) {
            assert(tail is null);
            assert(_length == 0);
            head = tail = elem;
        }
        else {
            assert(tail !is null);
            _nextOf(elem) = head;
            head = elem;
        }
        _length++;
    }

    void removeAll() {
        while (head) {
            popHead();
        }
        assert(_length == 0);
    }
}



module mecca.containers.pools;

import std.algorithm: max;
import std.exception;

import mecca.lib.tracing;
import mecca.lib.reflection;
import mecca.lib.memory;


class PoolDepleted: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

struct FixedPool(T) {
    private static struct Element {
        //enum MAGIC = 0xd365_c554;
        //uint magic, generation;
        union {
            FixedPool* pool;
            Element* next;
        }
        ulong rc;
        align(8) ubyte[T.sizeof] data;

        static Element* fromValue(T* p) pure nothrow @nogc {
            return cast(Element*)((cast(void*)p) - data.offsetof);
        }

        @property T* value() {
            return cast(T*)data.ptr;
        }
    }

    static struct Ptr {
        alias PointedType = T;
        T* _ptr;
        alias _ptr this;

        @notrace void release() {
            if (_ptr) {
                auto e = Element.fromValue(_ptr);
                e.pool.release(e);
                _ptr = null;
            }
        }
    }

    private MmapArray!Element elements;
    private size_t            _used;
    private Element*          freeHead;

    void open(size_t capacity, bool registerWithGC = true) {
        elements.allocate(capacity, registerWithGC);
        foreach(i, ref e; elements[0 .. $-1]) {
            e.next = &elements[i+1];
            e.rc = 0;
        }
        elements[$-1].next = null;
        elements[$-1].rc = 0;
        freeHead = elements.ptr;
        _used = 0;
    }
    void close() {
        elements.free();
    }
    @property bool closed() pure const nothrow @nogc {
        return elements.ptr is null;
    }
    @property size_t used() pure const nothrow @nogc {
        return _used;
    }
    @property size_t capacity() pure const nothrow @nogc {
        return elements.length;
    }
    @property bool full() pure const nothrow @nogc {
        return _used == elements.length;
    }

    @notrace Ptr alloc() {
        assert (!closed);
        if (_used >= elements.length) {
            throw new PoolDepleted(T.stringof);
        }
        _used++;
        auto e = freeHead;
        freeHead = freeHead.next;
        e.pool = &this;
        e.rc = 1;
        auto p = e.value;
        static if (__traits(hasMember, T, "_poolElementInit")) {
            p._poolElementInit();
        }
        else {
            setInitTo(p);
        }
        return Ptr(p);
    }

    @notrace private void release(Element* e) {
        if (closed) {
            return;
        }
        assert (e.pool is &this);
        assert (_used > 0);
        assert (e.rc > 0);
        static if (__traits(hasMember, T, "_poolElementReleased")) {
            e.value._poolElementReleased();
        }
        e.rc = 0;
        e.next = freeHead;
        freeHead = e;
        _used--;
    }

    @notrace void release(ref Ptr p) {
        p.release();
    }

    @notrace void release(T* p) {
        release(Element.fromValue(p));
    }
}

unittest {
    FixedPool!uint pool;
    pool.open(10);
    scope(exit) pool.close();

    auto e1 = pool.alloc();
    auto e2 = pool.alloc();
    auto e3 = pool.alloc();
    auto e4 = pool.alloc();
    assert (pool.used == 4);
    auto p_e1 = e1._ptr;
    e1.release();
    assert (pool.used == 3);
    auto e5 = pool.alloc();
    assert (pool.used == 4);
    assert (e5._ptr is p_e1);
    pool.release(e2);
    pool.release(e3);
    pool.release(e4);
    pool.release(e5);
    assert (pool.used == 0);
}

/+
struct SmartPool(T) {
    static assert (is(T == struct));

    private static struct Element {
        union {
            FixedPool* pool;
            Element* next;
        }
        ulong rc;
        align(8) ubyte[T.sizeof] data;

        @property T* value() pure nothrow @nogc @trusted {
            return cast(T*)data.ptr;
        }

        static Element* fromValue(T* p) pure nothrow @nogc @trusted {
            return cast(Element*)((cast(void*)p) - data.offsetof);
        }
    }

    private static struct Ptr {
        private T* _ptr;

        private this(T* p) pure nothrow @nogc {
            assert (Element.fromValue(p).rc > 0);
            this._ptr = p;
        }
        this(this) pure nothrow @nogc {
            if (_ptr) {
                auto e = Element.fromValue(_ptr);
                assert (e.rc > 0);
                e.rc++;
            }
        }
        ~this() nothrow @nogc {
            _decref();
        }
        bool opCast(U: bool)() {
            return _ptr !is null;
        }

        ref Ptr opAssign(typeof(null) p) {
            _decref();
            return this;
        }
        ref Ptr opAssign(Ptr p) pure nothrow @nogc {
            _decref();
            _ptr = p._ptr;
            return this;
        }
        ref Ptr opAssign(T* p) pure nothrow @nogc {
            _decref();
            _ptr = p;
            return this;
        }

        private void _decref() pure nothrow @nogc {
            if (_ptr) {
                auto e = Element.fromValue(_ptr);
                assert (e.rc > 0);
                e.rc--;
                if (e.rc == 0) {
                    auto pool = e.pool;
                    if (pool.closed) {
                        return;
                    }
                    assert (pool._used > 0);
                    static if (__traits(hasMember, T, "_poolElementReleased")) {
                        _ptr._poolElementReleased();
                    }
                    e.rc = 0;
                    e.next = freeHead;
                    pool.freeHead = e;
                    pool._used--;
                }
                _ptr = null;
            }
        }

        /+template opDispatch(string name) {
            static if (FieldNameTuple!T.canFind(name)) {
                @property ref auto opDispatch() pure nothrow @nogc {
                    return _ptr.
                }
            }
            else {

            }
        }+/

        //alias _ptr this;
        static assert (this.sizeof == (void*).sizeof);
    }

    private MmapArray!Element elements;
    private size_t            _used;
    private Element*          freeHead;

    void open(size_t capacity, bool registerWithGC = true) {
        elements.allocate(capacity, registerWithGC);
        foreach(i, ref e; elements[0 .. $-1]) {
            e.next = &elements[i+1];
            e.rc = 0;
        }
        elements[$-1].next = null;
        elements[$-1].rc = 0;
        freeHead = elements.ptr;
        _used = 0;
    }
    void close() {
        elements.free();
    }
    @property bool closed() pure const nothrow @nogc {
        return elements.ptr is null;
    }
    @property size_t used() pure const nothrow @nogc {
        return _used;
    }
    @property size_t capacity() pure const nothrow @nogc {
        return elements.length;
    }
    @property bool full() pure const nothrow @nogc {
        return _used == elements.length;
    }

    @notrace Ptr alloc() {
        assert (!closed);
        if (_used >= elements.length) {
            throw new PoolDepleted(T.stringof);
        }
        _used++;
        auto e = freeHead;
        freeHead = freeHead.next;
        e.pool = &this;
        e.rc = 1;
        auto p = e.value;
        static if (__traits(hasMember, T, "_poolElementInit")) {
            p._poolElementInit();
        }
        else {
            setInitTo(p);
        }
        return Ptr(p);
    }
}

unittest {
    static struct Elem {
        int x;

        void foo() {
            x++;
        }
    }

    SmartPool!uint pool;
    pool.open(100);
    scope(exit) pool.close();
    assert (pool.used == 0);

    {
        auto e1 = pool.alloc();
        e1.x = 5;
        assert (pool.used == 1);
    }

    assert (pool.used == 0);
}
+/




























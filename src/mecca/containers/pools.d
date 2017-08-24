module mecca.containers.pools;

///////////////////////////////////////////////////////////////////////////////////////////////////
// Pool-element Protocol
///////////////////////////////////////////////////////////////////////////////////////////////////
//
// The type (T) on which the pool is instantiated may define the following members
//
// * void _poolElementInit() -
//     - if present, will be invoked when the element is allocated. the memory is NOT initialized in any way
//     - if not present, the element will be initialized to `T.init`
//
// * void _poolElementFini() -
//     - if present, will be invoked when the element is released
//     - if not present, and T defines a dtor, it will be invoked. otherwise nothing is done.
//
// * enum size_t _poolElementAlignment - if present, controls the element alignment (in bytes)
//
///////////////////////////////////////////////////////////////////////////////////////////////////

import std.string;
import mecca.lib.memory: MmapArray;
import mecca.lib.reflection;


class PoolDepleted: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) nothrow @nogc {
        super(msg, file, line);
    }
}


///////////////////////////////////////////////////////////////////////////////////////////////////
//
// FixedPool: a FixedArray-based pool. May be placed on the stack/inside structs.
//            you must call open() before using this pool
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct FixedPool(T, size_t N) {
    alias IdxType = CapacityType!(N+1);
    static assert (N < IdxType.max);
    enum INVALID = IdxType.max;
    enum capacity = N;

    struct Elem {
        @disable this(this);
        union{
            void[T.sizeof] data;
            IdxType nextIdx;
        }
        static if (__traits(hasMember, T, "_poolElementAlignment")) {
            enum sz = T.sizeof < (Elem*).sizeof ? (Elem*).sizeof : T.sizeof;
            ubyte[T._poolElementAlignment - (sz % T._poolElementAlignment)] padding;
        }

        @property T* value() pure @trusted nothrow @nogc {
            return cast(T*)data.ptr;
        }
    }

    static if (__traits(hasMember, T, "_poolElementAlignment")) {
        static assert (Elem.sizeof % T._poolElementAlignment == 0);
    }

    private bool isInited;
    private IdxType freeIdx;
    private IdxType used;
    private Elem[N] elems;

    @property auto numInUse() const pure nothrow @nogc {
        assert (isInited);
        return used;
    }
    @property auto numAvailable() const pure nothrow @nogc {
        assert (isInited);
        return N - used;
    }

    void open() {
        foreach(i, ref e; elems[0..$-1]) {
            e.nextIdx = cast(IdxType)(i+1);
        }
        elems[$-1].nextIdx = INVALID;
        freeIdx = 0;
        used = 0;
        isInited = true;
    }
    void close() {
        // XXX: release all allocated elements?
    }

    T* alloc() nothrow @safe @nogc {
        assert (isInited);
        if (used >= N) {
            static const PoolDepleted poolDepeleted = new PoolDepleted(typeof(this).stringof);
            throw poolDepeleted;
        }
        assert (freeIdx != INVALID);
        auto e = &elems[freeIdx];
        used++;
        freeIdx = e.nextIdx;
        static if (__traits(hasMember, T, "_poolElementInit")) {
            e.value._poolElementInit();
        }
        else {
            setToInit(e.value);
        }
        return e.value;
    }

    IdxType indexOf(T* obj) const pure @trusted nothrow @nogc {
        assert (isInited);
        assert (used > 0);
        auto e = cast(Elem*)((cast(void*)obj) - Elem.data.offsetof);
        assert (e >= elems.ptr && e < elems.ptr + N);
        return cast(IdxType)(e - elems.ptr);
    }
    T* fromIndex(IdxType idx) pure @safe nothrow @nogc {pragma(inline, true);
        assert (isInited);
        assert (used > 0);
        return elems[idx].value;
    }

    void release(ref T* obj) nothrow @nogc {
        auto idx = indexOf(obj);
        static if (__traits(hasMember, T, "_poolElementFini")) {
            obj._poolElementFini();
        }
        elems[idx].nextIdx = freeIdx;
        freeIdx = idx;
        used--;
        obj = null;
    }
}

unittest {
    import core.exception;
    import std.exception;

    FixedPool!(ulong, 17) p;
    assertThrown!AssertError(p.alloc());
    p.open();
    assert (p.numInUse == 0);

    auto e1 = p.alloc();
    auto e2 = p.alloc();
    auto e3 = p.alloc();
    auto e4 = p.alloc();
    auto e5 = p.alloc();
    assert (p.numInUse == 5);
    assert (p.numAvailable == 12);

    auto pe2 = e2;
    p.release(e2);
    assert (e2 is null);

    auto pe3 = e3;
    p.release(e3);

    auto pe4 = e4;
    p.release(e4);

    assert (p.numInUse == 2);

    auto e6 = p.alloc();
    assert (e6 == pe4);

    auto e7 = p.alloc();
    assert (e7 == pe3);

    assert (p.numInUse == 4);

    while (p.numAvailable > 0) {
        p.alloc();
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
//
// SimplePool: a dynamically-allocated pool of elements (free list, allocated using mmap)
//             you must call open(numElements) before using this pool
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct SimplePool(T) {
    struct Elem {
        @disable this(this);
        union {
            void[T.sizeof] data;
            Elem* next;
        }
        static if (__traits(hasMember, T, "_poolElementAlignment")) {
            enum sz = T.sizeof < (Elem*).sizeof ? (Elem*).sizeof : T.sizeof;
            ubyte[T._poolElementAlignment - (sz % T._poolElementAlignment)] padding;
        }

        @property T* value() @nogc nothrow {
            return cast(T*)data.ptr;
        }
    }

    private MmapArray!Elem elements;
    private Elem* head;
    private size_t used;

    @property auto capacity() const pure nothrow @nogc {
        assert (!closed);
        return elements.length;
    }
    @property auto numInUse() const pure nothrow @nogc {
        assert (!closed);
        return used;
    }
    @property auto numAvailable() const pure nothrow @safe @nogc {
        assert (!closed);
        return elements.length - used;
    }

    void open(size_t numElements, bool registerWithGC = false) {
        assert (closed, "Already open");
        elements.allocate(numElements, registerWithGC);
        foreach(i, ref e; elements[0 .. $-1]) {
            e.next = &elements[i+1];
        }
        head = &elements[0];
        elements[$-1].next = null;
    }
    @property bool closed() const pure nothrow @nogc {
        return elements.closed();
    }
    void close() {
        // XXX: release all allocated elements?
        elements.free();
    }

    T* alloc() nothrow @trusted @nogc {
        assert (!closed);
        if (used >= elements.length) {
            static const PoolDepleted poolDepeleted = new PoolDepleted(typeof(this).stringof);
            throw poolDepeleted;
        }
        assert (head !is null);
        auto e = head;
        used++;
        head = head.next;
        static if (__traits(hasMember, T, "_poolElementInit")) {
            e.value._poolElementInit();
        }
        else {
            setToInit(e.value);
        }
        return e.value;
    }

    void release(ref T* obj) nothrow @trusted @nogc {
        assert (!closed);
        assert (used > 0);
        static if (__traits(hasMember, T, "_poolElementFini")) {
            obj._poolElementFini();
        }
        // XXX: check for dtor
        auto e = cast(Elem*)((cast(void*)obj) - Elem.data.offsetof);
        e.next = head;
        head = e;
        used--;
        obj = null;
    }
}

unittest {
    import core.exception;
    import std.exception;

    SimplePool!(ulong) p;
    assertThrown!AssertError(p.alloc());
    p.open(17);
    scope(exit) p.close();
    assert (p.numInUse == 0);

    auto e1 = p.alloc();
    auto e2 = p.alloc();
    auto e3 = p.alloc();
    auto e4 = p.alloc();
    auto e5 = p.alloc();
    assert (p.numInUse == 5);
    assert (p.numAvailable == 12);

    auto pe2 = e2;
    p.release(e2);
    assert (e2 is null);

    auto pe3 = e3;
    p.release(e3);

    auto pe4 = e4;
    p.release(e4);

    assert (p.numInUse == 2);

    auto e6 = p.alloc();
    assert (e6 == pe4);

    auto e7 = p.alloc();
    assert (e7 == pe3);

    assert (p.numInUse == 4);

    while (p.numAvailable > 0) {
        p.alloc();
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////
//
// RCPool: a reference-counted pool of elements based on SimplePool
//         you must call open(numElements) before using this pool
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct RCPool(T) {
    struct Elem {
        static if (__traits(hasMember, T, "_poolElementAlignment")) {
            enum _poolElementAlignment = T._poolElementAlignment;
        }
        void[T.sizeof] data;
        ulong rc;

        @disable this(this);
        @property T* value() {
            return cast(T*)data.ptr;
        }
        void _poolElementInit() nothrow @nogc {
            static if (__traits(hasMember, T, "_poolElementInit")) {
                value._poolElementInit();
            }
            else {
                setToInit(value);
            }
        }
        void _poolElementFini() nothrow @nogc {
            static if (__traits(hasMember, T, "_poolElementFini")) {
                value._poolElementFini();
            }
        }

        static Elem* fromValue(const T* obj) nothrow @nogc {
            return cast(Elem*)(cast(void*)obj - data.offsetof);
        }
    }

    private SimplePool!Elem pool;

    @property auto capacity() const pure nothrow @nogc {return pool.capacity;}
    @property auto numInUse() const pure nothrow @nogc {return pool.numInUse;}
    @property auto numAvailable() const pure nothrow @nogc {return pool.numAvailable;}
    void open(size_t numElements, bool registerWithGC = false) {pool.open(numElements, registerWithGC);}
    @property bool closed() const pure nothrow {return pool.closed;}
    void close() {pool.close();}

    T* alloc(size_t init=1)() nothrow @nogc {
        auto e = pool.alloc();
        e.rc = init;
        return e.value;
    }
    void incref(size_t delta=1)(T* obj) nothrow @nogc {
        auto e = Elem.fromValue(obj);
        assert (e.rc > 0);
        e.rc += delta;
    }
    void decref(size_t delta=1)(ref T* obj) nothrow @nogc {
        auto e = Elem.fromValue(obj);
        assert (e.rc >= delta);
        e.rc -= delta;
        if (e.rc == 0) {
            pool.release(e);
            obj = null;
        }
    }
    auto getref(const T* obj) const nothrow @nogc {
        auto e = Elem.fromValue(obj);
        assert (e.rc > 0);
        return e.rc;
    }
}

unittest {
    RCPool!ulong pool;
    assert (pool.closed());
    pool.open(17);
    assert (!pool.closed());
    scope(exit) pool.close();

    auto e1 = pool.alloc();
    auto e2 = pool.alloc();
    auto e3 = pool.alloc();

    assert (pool.getref(e1) == 1);
    pool.incref(e1);
    assert (pool.getref(e1) == 2);
    pool.decref(e2);
    assert (e2 is null);

    pool.decref(e1);
    assert (e1 !is null);
    pool.decref(e1);
    assert (e1 is null);
}

struct SmartPool(T) {
    RCPool!T rcPool;

    struct Handle {
        private SmartPool* _pool;
        private T* _elem;

        private this(SmartPool* pool, T* elem) nothrow @nogc {
            _pool = pool;
            _elem = elem;
        }
        this(this) nothrow @nogc {
            if (_pool && _elem) {
                _pool.rcPool.incref(_elem);
            }
        }
        private void _kill() nothrow @nogc {
            if (_pool && _elem) {
                _pool.rcPool.decref(_elem);
            }
            _pool = null;
            _elem = null;
        }
        ~this() nothrow @nogc {
            _kill();
        }
        bool opCast(U)() pure const nothrow @nogc if (is(U == bool)) {
            return _pool & _elem;
        }
        ref auto opAssign(typeof(null)) nothrow @nogc {
            _kill();
            return this;
        }
        ref auto opAssign(const ref Handle handle) nothrow @nogc {
            _kill();
            _pool = cast(SmartPool*)handle._pool;
            _elem = cast(T*)handle._elem;
            if (_pool && _elem) {
                _pool.rcPool.incref(_elem);
            }
            return this;
        }
        @property ref T get() pure nothrow @nogc {
            assert (_pool && _elem);
            return *_elem;
        }
        ref T opUnary(string s: "*")() pure nothrow @nogc {
            return get();
        }
        alias get this;

        auto getref() const nothrow @nogc {
            if (_pool && _elem) {
                return _pool.rcPool.getref(_elem);
            }
            else {
                return 0;
            }
        }
    }

    @property auto capacity() const pure nothrow @nogc {return rcPool.capacity;}
    @property auto numInUse() const pure nothrow @nogc {return rcPool.numInUse;}
    @property auto numAvailable() const pure nothrow @nogc {return rcPool.numAvailable;}
    void open(size_t numElements, bool registerWithGC = false) {rcPool.open(numElements, registerWithGC);}
    @property bool closed() const pure nothrow {return rcPool.closed;}
    void close() {rcPool.close();}

    Handle alloc() {
        return Handle(&this, rcPool.alloc());
    }
}

unittest {
    import std.stdio;

    SmartPool!uint pool;
    pool.open(17);
    scope(exit) pool.close();

    {
        auto h1 = pool.alloc();
        auto h2 = pool.alloc();
        auto h3 = pool.alloc();
        assert (pool.numInUse == 3);

        *h1 = 1;
        *h2 = 2;
        *h3 = 3;

        auto copy1 = h2;
        auto copy2 = copy1;

        assert (h1.getref == 1);
        assert (h2.getref == 3);
        assert (h3.getref == 1);

        assert (*h1 == 1);
        assert (*h2 == 2);
        assert (*h3 == 3);

        copy2 = null;
        h3 = null;
        assert (h2.getref == 2);
        assert (h3.getref == 0);

        copy1 = h1;
        assert (h1.getref == 2);
        assert (h2.getref == 1);
    }

    assert (pool.numInUse == 0);

    {
        void g(pool.Handle h, char* tmp) {
            char[100] x;
            assert (h.getref == 3);
            char[100] y;
        }

        void f(pool.Handle h) {
            assert (h.getref == 2);
            char[100] x;
            g(h, x.ptr);
            char[100] y;
            assert (h.getref == 2);
        }

        auto h = pool.alloc();
        assert (pool.numInUse == 1);
        assert (h.getref == 1);
    }

    assert (pool.numInUse == 0);

    {
        struct S {
            int x;
            pool.Handle h;
            int y;
        }

        auto h = pool.alloc();
        auto s = S(10, h, 20);
        assert (h.getref == 2);

        void gg(S s2, char* tmp) {
            char[100] a;
            assert (h.getref == 4);
            char[100] b;
        }
        void ff(S s2) {
            char[100] a;
            assert (h.getref == 3);
            gg(s2, a.ptr);
            char[100] b;
        }

        ff(s);
        assert (h.getref == 2);
        s = S.init;
        assert (h.getref == 1);
    }

    assert (pool.numInUse == 0);
}





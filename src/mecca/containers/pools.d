module mecca.containers.pools;

import std.string;
import mecca.lib.memory: MmapArray;
import mecca.lib.reflection;


class PoolDepleted: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

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
        @property T* value() {
            return cast(T*)data.ptr;
        }
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

    void reset() {
        foreach(i, ref e; elems[0..$-1]) {
            e.nextIdx = cast(IdxType)(i+1);
        }
        elems[$-1].nextIdx = INVALID;
        freeIdx = 0;
        used = 0;
        isInited = true;
    }

    T* alloc() {
        assert (isInited);
        if (used >= N) {
            throw new PoolDepleted(typeof(this).stringof ~ " %s depleted".format(&this));
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

    void release(ref T* obj) {
        assert (isInited);
        assert (used > 0);
        static if (__traits(hasMember, T, "_poolElementFini")) {
            obj._poolElementFini();
        }
        auto e = cast(Elem*)((cast(void*)obj) - Elem.data.offsetof);
        e.nextIdx = freeIdx;
        freeIdx = cast(IdxType)(e - elems.ptr);
        used--;
        obj = null;
    }
}

unittest {
    import core.exception;
    import std.exception;

    FixedPool!(ulong, 17) p;
    assertThrown!AssertError(p.alloc());
    p.reset();
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
    @property auto numAvailable() const pure nothrow @nogc {
        assert (!closed);
        return elements.length - used;
    }

    void open(size_t numElements, bool registerWithGC = false) {
        elements.allocate(numElements, registerWithGC);
        foreach(i, ref e; elements[0 .. $-1]) {
            e.next = &elements[i+1];
        }
        head = &elements[0];
        elements[$-1].next = null;
    }
    @property bool closed() const pure nothrow {
        return elements.closed();
    }
    void close() {
        elements.free();
    }

    T* alloc() {
        assert (!closed);
        if (used >= elements.length) {
            throw new PoolDepleted(typeof(this).stringof ~ " %s depleted".format(&this));
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

    void release(ref T* obj) {
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
        void _poolElementInit() {
            static if (__traits(hasMember, T, "_poolElementInit")) {
                value._poolElementInit();
            }
            else {
                setToInit(value);
            }
        }
        void _poolElementFini() {
            static if (__traits(hasMember, T, "_poolElementFini")) {
                value._poolElementFini();
            }
        }

        static Elem* fromValue(T* obj) {
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

    T* alloc(size_t init=1)() {
        auto e = pool.alloc();
        e.rc = init;
        return e.value;
    }
    void incref(size_t delta=1)(T* obj) {
        auto e = Elem.fromValue(obj);
        assert (e.rc > 0);
        e.rc += delta;
    }
    void decref(size_t delta=1)(ref T* obj) {
        auto e = Elem.fromValue(obj);
        assert (e.rc >= delta);
        e.rc -= delta;
        if (e.rc == 0) {
            pool.release(e);
            obj = null;
        }
    }
    auto getRefcount(T* obj) {
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

    assert (pool.getRefcount(e1) == 1);
    pool.incref(e1);
    assert (pool.getRefcount(e1) == 2);
    pool.decref(e2);
    assert (e2 is null);

    pool.decref(e1);
    assert (e1 !is null);
    pool.decref(e1);
    assert (e1 is null);
}




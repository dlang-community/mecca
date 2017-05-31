module mecca.containers.pools;

import std.string;
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







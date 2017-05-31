module mecca.containers.pools;

import std.string;
import mecca.lib.reflection;


class PoolDepleted: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

struct StaticPool(T, size_t N) {
    alias IdxType = CapacityType!(N+1);
    static assert (N < IdxType.max);
    enum INVALID = IdxType.max;

    struct Elem {
        @disable this(this);
        union{
            void[T.sizeof] value;
            IdxType nextIdx;
        }
    }
    private IdxType freeIdx;
    private IdxType used;
    private Elem[N] elems;

    enum capacity = N;
    @property auto numInUsed() const pure nothrow @nogc {return used;}

    void reset() {
        foreach(i, ref e; elems[0..$-1]) {
            e.nextIdx = cast(IdxType)(i+1);
        }
        elems[$-1].nextIdx = INVALID;
        freeIdx = 0;
        used = 0;
    }

    T* alloc() {
        if (used >= N) {
            throw new PoolDepleted(typeof(this).stringof ~ " %s depleted".format(&this));
        }
        assert (freeIdx != INVALID);
        auto e = &elems[freeIdx];
        T* v = cast(T*)(e.value.ptr);
        used++;
        freeIdx = e.nextIdx;
        static if (__traits(hasMember, T, "_poolElementInit")) {
            v.value._poolElementInit();
        }
        else {
            setToInit(v);
        }
        return v;
    }

    void release(T* value) {
        assert (used > 0);
        static if (__traits(hasMember, T, "_poolElementFini")) {
            value._poolElementFini();
        }
        auto e = cast(Elem*)((cast(void*)value) - Elem.value.offsetof);
        e.nextIdx = freeIdx;
        freeIdx = cast(IdxType)(e - elems.ptr);
        used--;
    }

    int opApply(scope int delegate(T*) dg) {
        int res;
        foreach(ref e; elems) {
            res = dg(cast(T*)e.value.ptr);
            if (res) {
                break;
            }
        }
        return res;
    }


}

unittest {
    StaticPool!(ulong, 17) sp;
    sp.reset();
    foreach(i; 0 .. sp.capacity) {
        sp.alloc();
    }
    assert (sp.numInUsed == sp.capacity);

}











module mecca.reactor.impl.fls;

import mecca.log;

enum FLS_AREA_SIZE = 512;

struct FLSArea {
    align( (void*).alignof ):
    __gshared static const FLSArea flsAreaInit;
    __gshared static int _flsOffset = 0;
    /* thread local */ static FLSArea* thisFls;

    ubyte[FLS_AREA_SIZE] data;

    void reset() nothrow @safe @nogc {
        pragma(inline, true);
        data[] = flsAreaInit.data[];
    }

    @notrace void switchTo() nothrow @trusted @nogc {
        pragma(inline, true);
        thisFls = &this;
    }

    static void switchToNone() nothrow @safe @nogc {
        pragma(inline, true);
        thisFls = null;
    }

    private static int alloc(T)(T initVal) {
        // Make sure allocation is properly aligned
        import std.string : format;
        static assert(T.alignof <= (void*).alignof, "Cannot allocate on FLS type %s with alignement %s > ptr alignement"
                .format(T.stringof, T.alignof));
        _flsOffset += T.alignof - 1;
        _flsOffset -= _flsOffset % T.alignof;

        int offset = _flsOffset;
        _flsOffset += T.sizeof;
        assert (_flsOffset <= data.sizeof);
        *cast(T*)(flsAreaInit.data.ptr + offset) = initVal;
        return offset;
    }
}
static assert(FLSArea.alignof == (void*).alignof, "FLSArea must have same alignement as a pointer");
static assert((FLSArea.data.offsetof % (void*).alignof) == 0, "FLSArea data must have same alignement as a pointer");

template FiberLocal(T, string NAME, T initVal=T.init) {
    __gshared int offset = -1;

    shared static this() {
        assert (offset == -1);
        offset = FLSArea.alloc!T(initVal);
    }

    @property ref T FiberLocal() {
        assert (FLSArea.thisFls !is null && offset >= 0);
        return *cast(T*)(FLSArea.thisFls.data.ptr + offset);
    }
}

version (unittest) {
    alias myFls = FiberLocal!(int, "myFls", 200);
    alias yourFls = FiberLocal!(double, "yourFls", 0.9);
}

unittest {
    FLSArea area1;
    FLSArea area2;

    area1.reset();
    area2.reset();

    scope(exit) FLSArea.thisFls = null;

    area1.switchTo();
    assert (myFls == 200);
    assert (yourFls == 0.9);

    myFls = 19;
    yourFls = 3.14;

    area2.switchTo();
    assert (myFls == 200);
    assert (yourFls == 0.9);

    myFls = 38;
    yourFls = 6.28;

    assert (myFls == 38);

    area1.switchTo();
    assert (myFls == 19);
    assert (yourFls == 3.14);

    area2.switchTo();
    assert (yourFls == 6.28);
}


unittest {
    align(64) struct A {
        align(64):
        uint a;
    }
    static assert( !__traits(compiles, FiberLocal!(A, "wontWork", A( 12 ))) );
}

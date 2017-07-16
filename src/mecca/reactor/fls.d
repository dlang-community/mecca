module mecca.reactor.fls;


enum FLS_AREA_SIZE = 512;

package struct FLSArea {
    private __gshared static const FLSArea flsAreaInit;
    private __gshared static int _flsOffset = 0;
    package __gshared static FLSArea* thisFls;

    ubyte[FLS_AREA_SIZE] data;

    private static int addVariable(T)(T initVal) {
        int offset = _flsOffset;
        _flsOffset += T.sizeof;
        assert (_flsOffset <= data.sizeof);
        *cast(T*)(flsAreaInit.data.ptr + offset) = initVal;
        return offset;
    }
    package void reset() {pragma(inline, true);
        data[] = flsAreaInit.data[];
    }
    package void switchTo() {pragma(inline, true);
        thisFls = &this;
    }
}

template FiberLocal(T, string NAME, T initVal=T.init) {
    __gshared int offset = -1;

    shared static this() {
        assert (offset == -1);
        offset = FLSArea.addVariable(initVal);
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




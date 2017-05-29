module mecca.lib.reflection;

public import std.traits;
public import std.meta;
import std.stdint: intptr_t;


template CapacityType(size_t n) {
    static if (n <= ubyte.max) {
        alias CapacityType = ubyte;
    }
    else static if (n <= ushort.max) {
        alias CapacityType = ushort;
    }
    else static if (n <= uint.max) {
        alias CapacityType = uint;
    }
    else {
        alias CapacityType = ulong;
    }
}

unittest {
    static assert (is(CapacityType!17 == ubyte));
    static assert (is(CapacityType!17_000 == ushort));
    static assert (is(CapacityType!17_000_000 == uint));
    static assert (is(CapacityType!17_000_000_000 == ulong));
}


struct _Closure(size_t ARGS_SIZE) {
private:
    void*                 _funcptr;
    intptr_t              _wrapper;
    union {
        void delegate()   _dg;
        ubyte[ARGS_SIZE]  argsBuf;
    }

public:
    @property const(void*) funcptr() const pure @nogc nothrow @safe {return _funcptr;}
    bool opCast(T: bool)() const pure @nogc nothrow {return _funcptr !is null;}
    @property bool isSet(T: bool)() const pure @nogc nothrow {return _funcptr !is null;}

    ref auto opAssign(typeof(null)) pure @nogc nothrow {clear(); return this;}
    ref auto opAssign(void function() fn) pure @nogc nothrow {set(fn); return this;}
    ref auto opAssign(void delegate() dg) pure @nogc nothrow {set(dg); return this;}

    void clear() pure @safe nothrow @nogc {
        _funcptr = null;
        _wrapper = 0;
        argsBuf[] = 0;
    }
    void set(void function() fn) pure @nogc nothrow {
        _funcptr = fn;
        _wrapper = 0;
        argsBuf[] = 0;
    }
    void set(void delegate() dg) pure @nogc nothrow {
        _funcptr = dg.funcptr;
        _wrapper = 1;
        _dg = dg;
        argsBuf[dg.sizeof .. $] = 0;
    }

    void set(T...)(void function(T) fn, T args) pure @nogc nothrow {
        struct Typed {T args;}
        static assert (Typed.sizeof <= argsBuf.sizeof);
        static void wrapper(_Closure* c) {
            (cast(void function(T))c._funcptr)((cast(Typed*)c.argsBuf.ptr).args);
        }

        _funcptr = fn;
        _wrapper = cast(intptr_t)&wrapper;
        (cast(Typed*)argsBuf.ptr).args = args;
        argsBuf[Typed.sizeof .. $] = 0;
    }

    void set(T...)(void delegate(T) dg, T args) pure @nogc nothrow {
        struct Typed {void delegate(T) dg; T args;}
        static assert (Typed.sizeof <= argsBuf.sizeof);
        static void wrapper(_Closure* c) {
            auto typed = (cast(Typed*)c.argsBuf.ptr);
            typed.dg(typed.args);
        }

        _funcptr = dg.funcptr;
        _wrapper = cast(intptr_t)&wrapper;
        (cast(Typed*)argsBuf.ptr).dg = dg;
        (cast(Typed*)argsBuf.ptr).args = args;
        argsBuf[Typed.sizeof .. $] = 0;
    }

    void setF(alias F)(Parameters!F args) pure @nogc nothrow {
        struct Typed {staticMap!(Unqual, Parameters!F) args;}
        static void wrapper(_Closure* c) {
            F((cast(Typed*)c.argsBuf.ptr).args);
        }

        _funcptr = &F;
        _wrapper = cast(intptr_t)&wrapper;
        (cast(Typed*)argsBuf.ptr).args = args;
        argsBuf[Typed.sizeof .. $] = 0;
    }

    void opCall() {
        pragma(inline, true);
        if (_wrapper == 0) {
            (cast(void function())funcptr)();
        }
        else if (_wrapper == 1) {
            _dg();
        }
        else {
            (cast(void function(_Closure*))_wrapper)(&this);
        }
    }
}

alias Closure = _Closure!64;

unittest {
    static long sum;

    static void f(int x) {
        sum += 1000 * x;
    }

    struct S {
        int z;
        void g(int x, int y) {
            sum += 1_000_000 * x + y * 100 + z;
        }
    }

    Closure c;
    assert (!c);

    c.set(&f, 5);
    assert (c);

    c();
    assert (c.funcptr == &f);
    assert (sum == 5_000);

    S s;
    s.z = 99;
    c.set(&s.g, 8, 18);
    c();
    assert (c.funcptr == (&s.g).funcptr);
    assert (sum == 5_000 + 8_000_000 + 1_800 + 99);

    c = null;
    //c();
    assert (!c);

    import std.functional: toDelegate;

    sum = 0;
    c.set(toDelegate(&f), 50);
    c();
    assert (sum == 50_000);

    static void h(int x, double y, string z) {
        sum = cast(long)(x * y) + z.length;
    }

    sum = 0;
    c.setF!h(16, 8.5, "hello");
    c();
    assert (sum == cast(long)(16 * 8.5 + 5));
}


void setToInit(T)(ref T val) nothrow @nogc if (!isPointer!T) {
    auto initBuf = cast(ubyte[])typeid(T).initializer();
    if (initBuf.ptr is null) {
        val.asBytes[] = 0;
    }
    else {
        // duplicate static arrays to work around https://issues.dlang.org/show_bug.cgi?id=16394
        static if (isStaticArray!T) {
            foreach(ref e; val) {
                e.asBytes[] = initBuf;
            }
        }
        else {
            val.asBytes[] = initBuf;
        }
    }
}

void setToInit(T)(T* val) nothrow @nogc if (!isPointer!T) {
    pragma(inline, true);
    setToInit(*val);
}

void copyTo(T)(const ref T src, ref T dst) nothrow @nogc {
    pragma(inline, true);
    (cast(ubyte*)&dst)[0 .. T.sizeof] = (cast(ubyte*)&src)[0 .. T.sizeof];
}

ubyte[] asBytes(T)(const ref T val) nothrow @nogc if (!isPointer!T) {
    pragma(inline, true);
    return (cast(ubyte*)&val)[0 .. T.sizeof];
}

unittest {
    static struct S {
        int a = 999;
    }

    S s;
    s.a = 111;
    setToInit(s);
    assert (s.a == 999);

    S[17] arr;
    foreach(ref s2; arr) {
        s2.a = 111;
    }
    assert (arr[0].a == 111 && arr[$-1].a == 111);
    setToInit(arr);
    assert (arr[0].a == 999 && arr[$-1].a == 999);
}

template IOTA(size_t N) {
    template helper(size_t i) {
        static if (i >= N) {
            alias helper = AliasSeq!();
        }
        else {
            alias helper = AliasSeq!(i, helper!(i+1));
        }
    }
    alias IOTA = helper!0;
}

unittest {
    foreach(i; IOTA!10) {
        enum x = i;
    }
}





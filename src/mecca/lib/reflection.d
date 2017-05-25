module mecca.lib.reflection;

public import std.traits;
public import std.meta;


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
    private void function(void*) wrapper;
    union {
        struct {
            private void* _funcptr;
            private void* _ctx;
        }
        private void[ARGS_SIZE + _funcptr.sizeof] argsBuf;
    }

    @property const(void*) funcptr() const pure nothrow @trusted @nogc {
        return _funcptr;
    }
    @property bool isSet() const pure nothrow @trusted @nogc {
        return _funcptr !is null;
    }
    bool opCast(T: bool)() const pure nothrow @safe @nogc {
        return isSet();
    }
    void clear() nothrow @nogc {
        wrapper = null;
        argsBuf.asBytes[] = 0;
    }

    void set(void function() fn) {
        static void fnWrapper(void* fn) {
            (cast(void function())fn)();
        }
        _funcptr = fn;
        argsBuf.asBytes[(void*).sizeof .. $] = 0;
        wrapper = &fnWrapper;
    }

    void set(void delegate() dg) {
        static void dgWrapper(void* fn) {
            (cast(void delegate())fn)();
        }

        _funcptr = dg.funcptr;
        _ctx = dg.ptr;
        argsBuf.asBytes[(void*).sizeof * 2 .. $] = 0;
        wrapper = &dgWrapper;
    }


    /+private void _set(T...)(void* fn, T args) @trusted @nogc {
        import std.string: format;
        static struct Typed {
            void function(T) fn;
            T args;
            static void call(void* self) {
                (cast(Typed*)self).fn((cast(Typed*)self).args);
            }
        }
        static assert (Typed.sizeof <= argsBuf.length, "args require %s bytes, %s available".format(
                Typed.sizeof - (void*).sizeof, argsBuf.length - (void*).sizeof));

        Typed* typed = cast(Typed*)argsBuf.ptr;
        typed.fn = cast(void function(T))fn;
        typed.args = args;
        (cast(ubyte[])argsBuf[Typed.sizeof .. $])[] = 0;   // don't leave dangling pointers
        wrapper = &Typed.call;
    }+/

    /+
    void set(T...)(void function(T) fn, T args) nothrow @nogc {
        _set(fn, args);
    }
    void set(T...)(void delegate(T) dg, T args) nothrow @nogc {
        // XXX: ABI
        _set(dg.funcptr, args, dg.ptr);
    }

    void setF(alias F)(Parameters!F args) @trusted @nogc {
        static assert (is(ReturnType!F == void));

        import std.string: format;
        static struct Typed {
            Parameters!F args;
            static void call(void* self) {
                F((cast(Typed*)self).args);
            }
        }
        static assert (Typed.sizeof <= argsBuf.length, "args require %s bytes, %s available".format(
                Typed.sizeof, argsBuf.length));

        Typed* typed = cast(Typed*)argsBuf.ptr;
        typed.args = args;
        (cast(ubyte[])argsBuf[Typed.sizeof .. $])[] = 0;   // don't leave dangling pointers
        wrapper = &Typed.call;
    }+/

    ref typeof(this) opAssign(typeof(null) fn) {clear(); return this;}
    ref typeof(this) opAssign(void function() fn) {set(fn); return this;}
    ref typeof(this) opAssign(void delegate() dg) {set(dg); return this;}

    void opCall() {
        pragma(inline, true);
        wrapper(argsBuf.ptr);
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





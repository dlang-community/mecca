module mecca.lib.reflection;

import std.string;
public import std.traits;
public import std.meta;

import mecca.lib.tracing_uda;


@("notrace") void traceDisableCompileTimeInstrumentation();

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


struct Closure {
    enum MAX_CALLBACK_ARGS_SIZE = 64;

    union {
        private void delegate() dlg;
        struct {
            private void* _ctx;
            private void* _func;
        }
    }
    private ubyte[MAX_CALLBACK_ARGS_SIZE] closureArgs;

    bool opCast(T = bool)() pure const nothrow @nogc {
        return dlg !is null;
    }
    alias isSet = opCast!bool;

    void set(typeof(null) dlg) nothrow pure @nogc {
        reset();
    }
    void reset() nothrow pure @nogc {
        dlg = null;
        closureArgs[] = 0;
    }
    void set(void delegate() dlg) nothrow pure @nogc {
        this.dlg = dlg;
    }
    void set(void function() func) {
        _ctx = null;
        _func = func;
    }
    alias opAssign = set;

    @property const(void*) funcptr() const pure nothrow @nogc {
        return _func; //(_func is null) ? _ctx : _func;
    }

    void set(alias F)(Parameters!F args) pure nothrow @nogc {
        static assert (is(ReturnType!F == void));
        enum checkStorageClass(uint sc) = (sc != ParameterStorageClass.none);
        static assert (Filter!(checkStorageClass, ParameterStorageClassTuple!F).length == 0);

        static struct Typed {
            Parameters!F args;
            void call() {
                F(args);
            }
        }
        static assert (Typed.sizeof <= MAX_CALLBACK_ARGS_SIZE);
        auto typed = cast(Typed*)closureArgs.ptr;
        typed.args = args;
        this.dlg = &typed.call;
    }

    void opCall() {
        pragma(inline, true);
        dlg();
        //assert (dlg);
        //if (_func) {
        //}
        //else {
        //    (cast(void function())_ctx)();
        //}
    }
}

unittest {
    Closure c;
    static int res;

    int dlgRes = 1;
    void dlg() {
        res += dlgRes;
    }

    static void func() {
        res += 100;
    }
    static void myFunc(int a, long b, double c) {
        res += a;
    }

    c = null;

    assert (!c);
    assert (!c.isSet);
    c = &dlg;
    assert (c);
    c();
    c = &func;
    c();
    c.set!myFunc(10_000, 2, 3.1415926);
    c();
    c();
    c = null;
    c();
    assert (res == 20101);
}


void setInitTo(T)(ref T val) if (!isPointer!T) {
    auto arr = cast(ubyte[])typeid(T).initializer();
    import std.algorithm : fill;
    if (arr.ptr is null) {
        (cast(ubyte*)&val)[0 .. T.sizeof] = 0;
    } else {
        // Use fill to duplicate 'arr' to work around https://issues.dlang.org/show_bug.cgi?id=16394
        (cast(ubyte*)&val)[0 .. T.sizeof].fill(arr);
    }
}

void setInitTo(T)(T* val) if (!isPointer!T) {
    setInitTo(*val);
}

void copyTo(T)(const ref T src, ref T dst) {
    (cast(ubyte*)&dst)[0 .. T.sizeof] = (cast(ubyte*)&src)[0 .. T.sizeof];
}

unittest {
    ulong x;
    setInitTo(x);
    ulong[17] y;
    setInitTo(y);
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
    int sum = 0;
    foreach(i; IOTA!5) {
        enum x = i; // make sure it's a static-foreach
        sum += i;
    }
    assert (sum == 0+1+2+3+4);
}

template TypedIdentifier(string name_, T, T invalid_ = T.max, T init_ = invalid_, string fmt="%d") {
    @FMT(name_ ~ "<{value!" ~ fmt ~ "}>")
    struct TypedIdentifier {
        alias UnderlyingType = T;
        enum name = name_;
        enum min = T.min;
        enum max = T.max;
        enum invalid = TypedIdentifier(invalid_);

        T value = init_;

        this(T value) {
            this.value = value;
        }
        U opCast(U)() const pure @safe nothrow if (isImplicitlyConvertible!(T, U)) {
            return value;
        }
        @property bool isValid() const pure nothrow @nogc {
            return this.value != invalid_;
        }
        string toString() {
            return "%s(%s)".format(name, value);
        }

        static assert (this.sizeof == T.sizeof);
    }
}

enum isTypedIdentifier(T) = is(T == TypedIdentifier!X, X...);

unittest {
    alias FooId = TypedIdentifier!("FooId", int);
    alias BarId = TypedIdentifier!("BarId", int);
    static assert (!__traits(compiles, FooId(5) == 5));
    assert (FooId(5).toString() == "FooId(5)");
    FooId x;
    assert (!x.isValid);
    x = FooId(8);
    assert (x.isValid);
    auto y = BarId(8);
    assert (x.value == y.value);
    static assert (!__traits(compiles, x == y));
    static assert (isTypedIdentifier!FooId);
    static assert (!isTypedIdentifier!int);
}

/+auto iota(T)(const T start, const T end) if (isTypedIdentifier!T) {
    import std.range : iota;
    import std.algorithm : map;
    return iota(start.value, end.value).map!(x => T(x));
}+/

enum superAccessor(string propName, string superName) = q{
        @property ref auto %s() inout {
            return super.tupleof[staticIndexOf!("%s", FieldNameTuple!(typeof(super)))];
        }
    }.format(propName, superName);


pragma(inline, true) void pureNogcNothrow(scope void function() fn) nothrow pure @nogc @trusted {
    return (cast(void function() nothrow pure @nogc)fn)();
}

pragma(inline, true) void pureNogcNothrow(scope void delegate() dg) nothrow pure @nogc @trusted {
    return (cast(void delegate() nothrow pure @nogc)dg)();
}




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
    void set(void function() fn) pure nothrow @safe @nogc {
        _funcptr = fn;
        _wrapper = 0;
        argsBuf[] = 0;
    }
    void set(void delegate() dg) pure nothrow @trusted @nogc {
        _funcptr = dg.funcptr;
        _wrapper = 1;
        _dg = dg;
        argsBuf[dg.sizeof .. $] = 0;
    }

    void set(T...)(void function(T) fn, T args) pure nothrow @trusted @nogc {
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

    void set(T...)(void delegate(T) dg, T args) pure nothrow @trusted @nogc {
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

unittest {
    struct S {
        int x = 5;
        int y = 7;
        int* p;
    }

    {
        S s = S(1,2,null);
        setToInit(s);
        assert(S.init == s);
    }

    {
        int y;
        S s = S(1,2,&y);
        setToInit(&s);
        assert(S.init == s);
    }

    {
        S s = S(1,2,null);
        auto p = &s;
        setToInit(p);
        assert(S.init == s);
    }

    {
        // no initializer
        int x = 5;
        setToInit(x);
        assert(x == 0);
        setToInit(&x);
        assert(x == 0);
    }

    {
        // static array & no initializer
        int[2] x = [1, 2];
        setToInit(x);
        import std.algorithm : equal;
        assert(x[].equal([0,0]));
        x = [3, 4];
        setToInit(&x);
        assert(x[].equal([0,0]));
    }

    {
        // static array & initializer
        S[2] x = [S(1,2), S(3,4)];
        assert(x[0].x == 1 && x[0].y == 2);
        assert(x[1].x == 3 && x[1].y == 4);
        setToInit(x);
        import std.algorithm : equal;
        assert(x[].equal([S.init, S.init]));
        x = [S(0,0),S(0,0)];
        setToInit(&x);
        assert(x[].equal([S.init, S.init]));
    }
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

public import std.typecons: staticIota;

alias IOTA(size_t end) = staticIota!(0, end);

unittest {
    foreach(i; IOTA!10) {
        enum x = i;
    }
}

FunctionAttribute toFuncAttrs(string attrs) {
    import std.algorithm.iteration : splitter, fold, map;
    return attrs.splitter(" ").map!(
        (word){
            if(word == "@nogc" || word == "nogc") return FunctionAttribute.nogc;
            if(word == "nothrow") return FunctionAttribute.nothrow_;
            if(word == "pure") return FunctionAttribute.pure_;
            if(word == "@safe" || word == "safe") return FunctionAttribute.safe;
            assert(false, word ~ " is not a valid attribute: must be @nogc, @safe, nothrow or pure");
        }).fold!((a, b) => a|b)(FunctionAttribute.none);
}

/// Execute a given piece of code while casting it:
auto ref as(string attrs, Func)(scope Func func) if (isFunctionPointer!Func || isDelegate!Func) {
    pragma(inline, true);
    return (cast(SetFunctionAttributes!(Func, functionLinkage!Func, functionAttributes!Func | toFuncAttrs(attrs)))func)();
}

unittest {
    static ubyte[] f() @nogc {
        //new ubyte[100];
        return as!"@nogc"({return new ubyte[100];});
    }
    static void g() nothrow {
        //throw new Exception("FUUU");
        as!"nothrow"({throw new Exception("FUUU");});
    }
    /+static void h() pure {
        static int x;
        as!"pure"({x++;});
    }+/
    /+static void k() @safe {
        int y;
        void* x = &y;
        //*(cast(int*)x) = 5;
        as!"@safe"({*(cast(int*)x) = 5;});
    }+/
}

template isVersion(string NAME) {
    mixin("version ("~ NAME ~") {enum isVersion = true;} else {enum isVersion=false;}");
}

unittest {
    static assert(isVersion!"unittest");
    static assert(isVersion!"assert");
    static assert(!isVersion!"slklfjsdkjfslk234r32c");
}

template callableMembersOf(T) {
    import std.typetuple: Filter;
    template isCallableMember(string memberName) {
        enum isCallableMember = isCallable!(__traits(getMember, T, memberName));
    }
    enum callableMembersOf = Filter!(isCallableMember, __traits(allMembers, T));
}

struct StructImplementation(I) {
    mixin((){
        string s;
        foreach (name; callableMembersOf!I) {
            s ~= "ReturnType!(__traits(getMember, I, \"" ~ name ~ "\")) delegate(ParameterTypeTuple!(__traits(getMember, I, \"" ~ name ~ "\")) args) " ~ name ~ ";\n";
        }
        return s;
    }());

    this(T)(ref T obj) {
        opAssign(obj);
    }
    this(T)(T* obj) {
        opAssign(obj);
    }

    ref auto opAssign(typeof(null) _) {
        foreach(ref field; this.tupleof) {
            field = null;
        }
        return this;
    }
    ref auto opAssign(const ref StructImplementation impl) {
        this.tupleof = impl.tupleof;
        return this;
    }
    ref auto opAssign(T)(T* obj) {
        return obj ? opAssign(*obj) : opAssign(null);
    }
    ref auto opAssign(T)(ref T obj) {
        foreach(name; callableMembersOf!I) {
            __traits(getMember, this, name) = &__traits(getMember, obj, name);
        }
        return this;
    }

    @property bool isValid() {
        // enough to check one member - all are assigned at the same time
        return this.tupleof[0] !is null;
    }
}

unittest {
    interface Foo {
        int func1(string a, double b);
        void func2(int c);
    }

    struct MyStruct {
        int func1(string a, double b) {
            return cast(int)(a.length * b);
        }
        void func2(int c) {
        }
        void func2() {
        }
    }

    StructImplementation!Foo simpl;
    assert (!simpl.isValid);
    MyStruct ms;
    simpl = ms;
    assert (simpl.isValid);

    assert (simpl.func1("hello", 3.001) == 15);

    simpl = null;
    assert (!simpl.isValid);
}

alias ParentType(alias METHOD) = Alias!(__traits(parent, METHOD));

auto methodCall(alias METHOD)(ParentType!METHOD* instance, ParameterTypeTuple!METHOD args) if(is(ParentType!METHOD == struct)) {
    return __traits(getMember, instance, __traits(identifier, METHOD))(args);
}
auto methodCall(alias METHOD)(ParentType!METHOD instance, ParameterTypeTuple!METHOD args) if(!is(ParentType!METHOD == struct)) {
    return __traits(getMember, instance, __traits(identifier, METHOD))(args);
}

unittest {
    struct MyStruct {
        int x;
        int f() {
            return x * 2;
        }
    }

    auto ms = MyStruct(17);
    assert (ms.f() == 34);
    assert (methodCall!(MyStruct.f)(&ms) == 34);
}

template StaticRegex(string exp, string flags = "") {
    import std.regex;
    __gshared static Regex!char StaticRegex;
    shared static this() {
        StaticRegex = regex(exp, flags);
    }
}













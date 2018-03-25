/// Various utilities for hacking the D type system
module mecca.lib.reflection;

import std.algorithm: move, moveEmplace;
public import std.traits;
public import std.meta;
import std.conv;
import std.stdint: intptr_t;

// Disable tracing instrumentation for the whole file
@("notrace") void traceDisableCompileTimeInstrumentation();

/// Return the smallest type large enough to hold the numbers 0..n
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

/// Type, unless it is smaller than int, in which case it is promoted
///
/// This is useful for predicting the return type due to algebraic type promotion
template PromotedType(Type) {
    alias PromotedType = typeof(Type(0)+Type(0));
}

unittest {
    static assert( is( PromotedType!ubyte == int ) );
    static assert( is( PromotedType!byte == int ) );
    static assert( is( PromotedType!ushort == int ) );
    static assert( is( PromotedType!short == int ) );
    static assert( is( PromotedType!int == int ) );
    static assert( is( PromotedType!uint == uint ) );
    static assert( is( PromotedType!long == long ) );
    static assert( is( PromotedType!ulong == ulong ) );
}

private enum badStorageClass(uint cls) = (cls != ParameterStorageClass.none);

/**
 * Non-GC postponed function call with arguments (closure)
 */
struct Closure {
    enum ARGS_SIZE = 64;

private:
    enum DIRECT_FN = cast(void function(Closure*))0x1;
    enum DIRECT_DG = cast(void function(Closure*))0x2;

    void function(Closure*) _wrapper;
    void* _funcptr;
    union {
        void delegate() _dg;
        ubyte[ARGS_SIZE] argsBuf;
    }

public:
    @property const(void)* funcptr() pure const nothrow @nogc {
        return _funcptr;
    }
    @property bool isSet() pure const nothrow @nogc {
        return _funcptr !is null;
    }
    bool opCast(T: bool)() const pure @nogc nothrow @safe {
        return _funcptr !is null;
    }
    ref auto opAssign(typeof(null)) pure @nogc nothrow @safe {
        clear();
        return this;
    }
    ref auto opAssign(void function() fn) pure @nogc nothrow @safe {
        set(fn);
        return this;
    }
    ref auto opAssign(void delegate() dg) pure @nogc nothrow @safe {
        set(dg);
        return this;
    }

    void clear() pure nothrow @nogc @safe {
        _wrapper = null;
        _funcptr = null;
        argsBuf[] = 0;
    }

    void set(F, T...)(F f, T args) pure nothrow @nogc @trusted if (isFunctionPointer!F) {
        static assert (is(ReturnType!F == void), "Delegate must return void");
        static assert (is(typeof(f(args))), "Args don't match passed delegate");

        alias PSCT = ParameterStorageClassTuple!F;
        foreach( i; IOTA!(T.length) ) {
            import std.string: format;

            static assert(
                    PSCT[i] != ParameterStorageClass.ref_,
                    "Closure cannot be used over functions with a ref variables (argument %s)".format(i+1) );
            static assert(
                    PSCT[i] != ParameterStorageClass.out_,
                    "Closure cannot be used over functions with an out variables (argument %s)".format(i+1) );
            static assert(
                    PSCT[i] != ParameterStorageClass.lazy_,
                    "Closure cannot be used over functions with a lazy variables (argument %s)".format(i+1) );
        }

        static if (T.length == 0) {
            _wrapper = DIRECT_FN;
            _funcptr = f;
            argsBuf[] = 0;
        }
        else {
            struct Typed {
                T args;
            }
            static assert (Typed.sizeof <= argsBuf.sizeof, "Args too big");

            static void wrapper(Closure* closure) {
                mixin( genMoveArgument(
                            T.length,
                            "(cast(F)closure._funcptr)",
                            "(cast(Typed*)closure.argsBuf.ptr).args") );
            }
            _funcptr = f;
            _wrapper = &wrapper;
            foreach( i, ref arg; args )
                moveEmplace( arg, (cast(Typed*)argsBuf.ptr).args[i] );
            argsBuf[Typed.sizeof .. $] = 0;
        }
    }

    void set(D, T...)(D dg, T args) pure nothrow @nogc @trusted if (isDelegate!D) {
        static assert (is(ReturnType!D == void), "Delegate must return void");
        static assert (is(typeof(dg(args))), "Args don't match passed delegate");

        alias PSCT = ParameterStorageClassTuple!D;
        foreach( i; IOTA!(T.length) ) {
            import std.string: format;

            static assert(
                    PSCT[i] != ParameterStorageClass.ref_,
                    "Closure cannot be used over functions with a ref variables (argument %s)".format(i+1) );
            static assert(
                    PSCT[i] != ParameterStorageClass.out_,
                    "Closure cannot be used over functions with an out variables (argument %s)".format(i+1) );
            static assert(
                    PSCT[i] != ParameterStorageClass.lazy_,
                    "Closure cannot be used over functions with a lazy variables (argument %s)".format(i+1) );
        }

        static if (T.length == 0) {
            _wrapper = DIRECT_DG;
            _funcptr = dg.funcptr;
            _dg = dg;
            argsBuf[_dg.sizeof .. $] = 0;
        }
        else {
            struct Typed {
                D dg;
                T args;
            }
            static assert (Typed.sizeof <= argsBuf.sizeof, "Args too big");

            static void wrapper(Closure* closure) {
                auto typed = cast(Typed*)closure.argsBuf.ptr;
                mixin( genMoveArgument(args.length, "typed.dg", "typed.args") );
            }
            _wrapper = &wrapper;
            _funcptr = dg.funcptr;
            auto typed = cast(Typed*)argsBuf.ptr;
            typed.dg = dg;
            foreach(i, ref arg; args) {
                moveEmplace( arg, typed.args[i] );
            }
            argsBuf[Typed.sizeof .. $] = 0;
        }
    }

    void set(alias F)(Parameters!F args) nothrow @nogc @trusted {
        static assert (is(ReturnType!F == void), "Delegate must return void");
        foreach(i, storage; ParameterStorageClassTuple!F) {
            static assert(
                    !badStorageClass!storage,
                    "Argument " ~ text(i) ~ " has non-plain storage class " ~
                        bitEnumToString!ParameterStorageClass(storage) );
        }

        alias PSCT = ParameterStorageClassTuple!F;
        foreach( i, sc; PSCT ) {
            import std.string: format;

            static assert(
                    sc != ParameterStorageClass.ref_,
                    "Closure cannot be used over functions with a ref variables (argument %s)".format(i+1) );
            static assert(
                    sc != ParameterStorageClass.out_,
                    "Closure cannot be used over functions with an out variables (argument %s)".format(i+1) );
            static assert(
                    sc != ParameterStorageClass.lazy_,
                    "Closure cannot be used over functions with a lazy variables (argument %s)".format(i+1) );
        }

        static if (Parameters!F.length == 0) {
            _wrapper = DIRECT_FN;
            _funcptr = &F;
            argsBuf[] = 0;
        }
        else {
            struct Typed {
                staticMap!(Unqual, Parameters!F) args;
            }
            static void wrapper(Closure* closure) {
                Typed* typed = cast(Typed*)closure.argsBuf.ptr;
                mixin( genMoveArgument(args.length, "F", "typed.args") );
            }

            _wrapper = &wrapper;
            _funcptr = &F;
            foreach(i, ref arg; args ) {
                moveEmplace( arg, (cast(Typed*)argsBuf.ptr).args[i] );
            }
            argsBuf[Typed.sizeof .. $] = 0;
        }
    }

    void opCall() {
        if (_funcptr is null) {
            return;
        }
        else if (_wrapper == DIRECT_FN) {
            (cast(void function())_funcptr)();
        }
        else if (_wrapper == DIRECT_DG) {
            _dg();
        }
        else {
            (cast(void function(Closure*))_wrapper)(&this);
        }
    }

}

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
    c.set!h(16, 8.5, "hello");
    c();
    assert (sum == cast(long)(16 * 8.5 + 5));
}

unittest {
    Closure c;

    void func(lazy int a) {
    }

    int var;

    // This check depends on an advanced enough version of the compiler
    static assert( !__traits(compiles, c.set(&func, var)) );
}

void setToInit(T)(ref T val) nothrow @trusted @nogc if (!isPointer!T) {
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
    static assert( !hasElaborateDestructor!T, "Cannot convert to bytes a type with destructor" );
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

debug {
    enum isDebug = true;
}
else {
    enum isDebug = false;
}

private string signatureOf(Ts...)() if (Ts.length == 1) {
    import std.conv;

    alias T = Ts[0];
    static if (isSomeFunction!T) {
        string s = "(";
        foreach(i, U; ParameterTypeTuple!T) {
            s ~= signatureOf!U ~ " " ~ int(ParameterStorageClassTuple!T[i]).to!string() ~ ParameterIdentifierTuple!T[i] ~ ",";
        }
        return s ~ ")->" ~ signatureOf!(ReturnType!T);
    }
    else static if (is(T == struct) || is(T == union)) {
        string s = T.stringof ~ "{";
        foreach(i, U; typeof(T.tupleof)) {
            s ~= signatureOf!U ~ " " ~ __traits(identifier, T.tupleof[i]);
            static if (is(T == struct)) {
                s ~= ",";
            }
            else {
                s ~= "|";
            }
        }
        return s ~ "}";
    }
    else static if (isBuiltinType!T) {
        return T.stringof;
    }
    else static if (is(T == U*, U)) {
        return U.stringof ~ "*";
    }
    else {
        static assert (false, T.stringof);
    }
}

ulong abiSignatureOf(Ts...)() if (Ts.length == 1) {
    import mecca.lib.hashing: murmurHash3_64;
    return murmurHash3_64(signatureOf!(Ts));
}

version (unittest) {
    static struct WWW {
        int x, y;
    }

    static struct SSS {
        int a;
        long b;
        double c;
        SSS* d;
        WWW[2] e;
        string f;
    }

    static int fxxx(int x, SSS s, const ref SSS t) {
        return 7;
    }
}

unittest {
    import std.conv;

    enum sig = signatureOf!fxxx;

    enum expected = "(int 0x,SSS{int a,long b,double c,SSS* d,WWW[2] e,string f,} 0s,const(SSS){const(int) a," ~
        "const(long) b,const(double) c,const(SSS)* d,const(WWW[2]) e,const(string) f,} 4t,)->int";
    static assert (sig == expected, "\n" ~ sig ~ "\n" ~ expected);
    enum hsig = abiSignatureOf!fxxx;

    static assert (hsig == 2694514427802277758LU, text(hsig));
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

/// Replace std.traits.ForeachType with one that works when the item is copyable or not
template ForeachTypeof (T) {
    alias TU = Unqual!T;
    static if(__traits(compiles, {foreach(x; TU.init) {}})) {
        alias ForeachTypeof = ReturnType!({ foreach(x;TU.init) { return x; } assert(0); });
    } else {
        alias ForeachTypeof = PointerTarget!(ReturnType!({ foreach(ref x;TU.init) { return &x; } assert(0); }));
    }
}

unittest {
    struct A{ @disable this(this); }
    struct B{ int opApply(int delegate(int x) dlg) { return 0; } }
    alias AF = ForeachTypeof!(A[]);
    alias BF = ForeachTypeof!B;
    alias IF = ForeachTypeof!(int[5]);
}

/**
 * A CTFE function for generating a mixin string of a function call moving arguments
 *
 * Params:
 * numArgs = number of arguments in generated function call
 * callString = the string used to call the function
 * argumentString = the string used to specify a specific argument
 * ret = optional variable to receive the function's return
 */
string genMoveArgument(size_t numArgs, string callString, string argumentString, string ret = null) @safe pure {
    import std.string: format;

    string retVal;
    if( ret !is null )
        retVal ~= "%s = ".format(ret);
    retVal ~= "%s( ".format(callString);
    foreach(i; 0..numArgs) {
        if( i>0 )
            retVal ~= ", ";
        retVal ~= "move(%s[%s])".format(argumentString, i);
    }

    retVal ~= " );";

    return retVal;
}

/+
XXX Disabled due to compiler bug in __traits(parent)

/**
 * CTFE function for selecting a specific overload of a function
 */
template getOverload(alias F, Args...) {
    bool predicate(Func)() {
        static if( Parameters!Func == Args ) {
            return true;
        } else {
            return false;
        }
    }

    pragma(msg, "id ", __traits(identifier, F));
    pragma(msg, "type   ", fullyQualifiedName!F, " = ", typeof(F));
    pragma(msg, "parent ", fullyQualifiedName!(__traits(parent, F)), " = ", typeof(__traits(parent, F)));
    pragma(msg, "parent 2 ", fullyQualifiedName!(__traits(parent, __traits(parent, F))), " = ", typeof(__traits(parent, __traits(parent, F))));
    pragma(msg, __traits(getOverloads, __traits(parent, F), __traits(identifier, F)) );
    /+
    alias getOverload = Filter!("predicate",
            __traits(getOverloads, __traits(parent, F), __traits(identifier, F)));
    +/
    alias getOverload = void;
    pragma(msg, typeof(getOverload));
}
+/

/// CTFE template for genering a string for mixin copying a function's signature along with its default values
///
/// Bugs:
/// Due to $(LINK2 https://issues.dlang.org/show_bug.cgi?id=18572, issue 18572) this will not copy extended
/// attributes of the arguments (ref, out etc). All arguments are passed by value.
///
/// The generated code refers to `srcFunc` by its fully qualified name. Unfortunately, this means we cannot apply to
/// functions nested inside other functions.
template CopySignature(alias srcFunc, int argumentsBegin = 0, int argumentsEnd = Parameters!srcFunc.length) {
    private alias Args = Parameters!srcFunc;
    private alias Defaults = ParameterDefaults!srcFunc;
    // TODO fullyQualifiedName returns an unusable identifier in case of a nested function
    private enum funcName = fullyQualifiedName!srcFunc;

    import std.format : format;

    /// Generates a definition list.
    ///
    /// Note:
    /// The arguments are going to be named "arg0" through "argN". The first argument will be `arg0` even if
    /// `argumentsBegin` is not 0.
    string genDefinitionList() pure @safe {
        string ret;

        foreach(i, type; Defaults[argumentsBegin..argumentsEnd]) {
            if( i>0 )
                ret ~= ", ";

            // DMDBUG: we need to give range if we want to maintain ref/out attributes (Params[0..1] arg0).
            // Due to issue 18572, however, we would then not be able to provide default arguments.
            ret ~= "Parameters!(%s)[%s] arg%s".format(funcName, i+argumentsBegin, i);

            static if( !is(type == void) ) {
                ret ~= " = ParameterDefaults!(%s)[%s]".format(funcName, i+argumentsBegin);
            }
        }

        return ret;
    }

    /// Generate a calling list. Simply the list of arg0 through argN separated by commas
    string genCallList() pure @safe {
        string ret;

        foreach(i; 0..argumentsEnd-argumentsBegin) {
            if( i>0 )
                ret ~= ", ";

            ret ~= "arg%s".format(i);
        }

        return ret;
    }
}

version(unittest) {
    private int UTfunc1( int a, int b = 3 ) {
        return a += b;
    }
}

unittest {
    import std.format : format;

    alias CopySig = CopySignature!UTfunc1;

    enum MixIn = q{
        int func2( %s ) {
            return UTfunc1( %s );
        }
    }.format( CopySig.genDefinitionList, CopySig.genCallList );
    // pragma(msg, MixIn);
    mixin(MixIn);

    int a=2;
    assert( func2(a)==5 );
    assert( func2(a, 17)==19 );
    static assert( !__traits(compiles, func2()) );
}

/// Convert a value to bitwise or of enum members
string bitEnumToString(T)(ulong val) pure @safe {
    import std.format : format;

    static assert( is(T==enum), "enumToString must accept an enum type (duh!). Got " ~ T.stringof ~ " instead." );

    string ret;

    foreach(enumMember; EnumMembers!T) {
        if( (val & enumMember)!=0 ) {
            if( ret.length!=0 )
                ret ~= "|";

            ret ~= text(enumMember);
            val &= ~(enumMember);
        }
    }

    if( val!=0 ) {
        if( ret.length!=0 )
            ret ~= "|";

        ret ~= format("0x%x", val);
    }

    return ret;
}

unittest {
    import mecca.lib.exception : assertEQ;

    enum Test : uint {
        A = 1,
        B = 4,
        C = 8,
        D = 4,
    }

    assertEQ( bitEnumToString!Test(2), "0x2" );
    assertEQ( bitEnumToString!Test(8), "C" );
    assertEQ( bitEnumToString!Test(11), "A|C|0x2" );
    assertEQ( bitEnumToString!Test(12), "B|C" );
}

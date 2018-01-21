module mecca.lib.typedid;

import std.traits;
import std.conv;

import mecca.lib.exception;
import mecca.log : FMT, notrace;

template RawTypedIdentifier(string _name, T, T _invalid, T _init, FMT fmt, bool algebraic)
    if (isIntegral!T)
{
    @fmt
    struct RawTypedIdentifier {
    private:
        T _value = _init;

        enum Algebraic = algebraic;

    public:
        alias UnderlyingType = T;
        enum RawTypedIdentifier invalid = RawTypedIdentifier(_invalid);
        enum name = _name;

        this(T value) @safe pure nothrow @nogc {
            this._value = value;
        }
        // Default this(this) does the right thing

        // For some reason, this form is not covered by this(this)
        this(RawTypedIdentifier that) @safe pure nothrow @nogc {
            this._value = that.value;
        }

        this(string str) @safe {
            setFromString(str);
        }

        @property T value() const pure nothrow @safe @nogc {
            return _value;
        }
        @property bool isValid() const pure nothrow @safe @nogc {
            return _value != _invalid;
        }
        // XXX do we want this?
        ref RawTypedIdentifier opAssign(T val) nothrow @safe @nogc {
            _value = val;
            return this;
        }

        // Default opEquals does the right thing

        int opCmp(in RawTypedIdentifier rhs) const pure nothrow @safe @nogc {
            return value > rhs.value ? 1 : (value < rhs.value ? -1 : 0);
        }

        static if (algebraic) {
            enum RawTypedIdentifier min = T.min;
            enum RawTypedIdentifier max = T.max;

            int opCmp(in T rhs) const pure nothrow @safe @nogc {
                return opCmp( RawTypedIdentifier(rhs) );
                // return value > rhs ? 1 : (value < rhs ? -1 : 0);
            }

            // Pointer like semantics:
            // Can add integer to RawTypedIdentifier to get RawTypedIdentifier
            ref RawTypedIdentifier opOpAssign(string op)(in T rhs) nothrow @safe @nogc if (op == "+" || op == "-") {
                mixin("_value "~op~"= rhs;");
                return this;
            }

            // Can do any op at all on another TypedId
            ref RawTypedIdentifier opOpAssign(string op)(in RawTypedIdentifier rhs) nothrow @safe @nogc {
                mixin("_value "~op~"= rhs.value;");
                return this;
            }

            RawTypedIdentifier opBinary(string op)(in T rhs) const pure nothrow @safe @nogc if (op == "+" || op == "-") {
                RawTypedIdentifier res = this;
                //return mixin("res "~op~"= rhs;");
                res += rhs;
                return res;
            }

            ref RawTypedIdentifier opUnary(string op)() nothrow @safe @nogc if (op == "++" || op == "--") {
                if (isValid)
                    mixin("_value" ~ op ~ ";");

                return this;
            }

            // Can subtract two RawTypedIdentifier to get an integer
            T opBinary(string op : "-")(in RawTypedIdentifier rhs) const pure nothrow @safe @nogc {
                return value - rhs.value;
            }
        }

        // toString is not @nogc
        string toString() const pure nothrow @safe {
            return name ~ "<" ~ (isValid ? to!string(_value) : "INVALID") ~ ">";
        }

        @notrace void setFromString(string str) @safe {
            import std.conv : ConvException, parse;
            import std.string : indexOf;
            auto idx = str.indexOf('<');
            if (idx > 0 && str[$ - 1] == '>') {
                import std.uni: sicmp;
                enforceFmt!ConvException(sicmp(str[0 .. idx], name) == 0, "Expected %s not %s", name, str[0 .. idx]);
                auto tmp2 = str[idx + 1 .. $-1];
                if (tmp2 == "INVALID") {
                    _value = _invalid;
                } else {
                    _value = parse!T(tmp2);
                }
            }
            else {
                _value = parse!T(str);
            }
        }

        static assert (this.sizeof == T.sizeof);
    }
}

alias TypedIdentifier(string name, T, T invalid = T.max, T _init = T.init, FMT fmt = FMT("")) =
    RawTypedIdentifier!(name, T, invalid, _init, fmt, false);
alias AlgebraicTypedIdentifier(string name, T, T invalid = T.max, T _init = T.init, FMT fmt = FMT("")) =
    RawTypedIdentifier!(name, T, invalid, _init, fmt, true);

unittest {
    import std.string;

    alias UtId = AlgebraicTypedIdentifier!("UtId", ushort);

    auto val = UtId(12);
    auto inv = UtId(65535);

    assert( format("%s", val) == "UtId<12>" );
    assert( format("%s", inv) == "UtId<INVALID>" );

    val++;
    inv++;
    assert( val == UtId(13) );
    assert( !inv.isValid );

    val += 2;
    assert( val == UtId(15) );

    auto newval = val + 3;

    static assert( is( typeof(newval) == typeof(val) ) );
    assert( newval.value == 18 );
}

enum isTypedIdentifier(T) = isInstanceOf!(RawTypedIdentifier, T);
enum isAlgebraicTypedIdentifier(T) = {
    static if( isTypedIdentifier!T ) {
        return T.Algebraic;
    } else {
        return false;
    }
} ();

auto iota(T)(const T start, const T end) nothrow @safe @nogc if (isAlgebraicTypedIdentifier!T) {
    import std.range : iota;
    import std.algorithm : map;
    return iota(start.value, end.value).map!(x => T(x));
}

auto iota(T)(const T end) nothrow @safe @nogc if (isAlgebraicTypedIdentifier!T) {
    return iota(T(0), end);
}

unittest {
    import std.range : iota;

    alias UTiD = AlgebraicTypedIdentifier!("UTiD", uint);

    uint counter;
    foreach( i; iota(12) ) {
        counter++;
    }
    assert(counter==12);

    counter = 0;
    foreach( i; iota(UTiD(12)) ) {
        counter++;
    }
    assert(counter==12);

    counter = 0;
    foreach( i; iota(UTiD(3), UTiD(12)) ) {
        counter++;
    }
    assert(counter == 9);
}

import std.range : isInputRange, ElementType;
import std.array : empty, front, popFront;

struct TypedIndexArray(KEY, VALUE, size_t LENGTH) if (isAlgebraicTypedIdentifier!KEY) {
private:
    VALUE[LENGTH] _array;

public:
    alias Key = KEY;

    this(R)(R values) if(isInputRange!R) {
        // DMDBUG Work around: https://issues.dlang.org/show_bug.cgi?id=16301
        // Allowing TypedIndexArray to be used in more CTFE contexts:
        auto arr = &this._array;
        uint count = 0;
        foreach(ref item; values) {
            (*arr)[count] = item;
            count++;
        }
        ASSERT!("TypedIndexArray initialize from range of wrong length (%s != " ~ LENGTH.stringof ~ ")") (LENGTH == count, count);
    }
    this()(VALUE value) {
        _array[] = value;
    }

    this()(ref VALUE[LENGTH] value) {
        _array[] = value[];
    }

    alias Slice = TypedIndexSlice!(KEY, VALUE);
    ref inout(VALUE) opIndex(KEY index) inout {
        DBG_ASSERT!"opIndex called with invalid index"(index.isValid);
        return _array[index.value];
    }

    inout(Slice) opIndex() inout {
        return inout(Slice)(_array[]);
    }

    inout(Slice) opSlice(KEY begin, KEY end) inout {
        return inout(Slice)(_array[begin.value .. end.value], begin.value);
    }

    @property KEY opDollar() const { return KEY(LENGTH); }
    @property static KEY length() { return KEY(LENGTH); }
    static size_t intLength() { return LENGTH; }

    int opApply(scope int delegate(ref VALUE value) dg) {
        return this[].opApply(dg);
    }

    int opApply(scope int delegate(ref const(VALUE) value) dg) const {
        return this[].opApply(dg);
    }

    int opApply(scope int delegate(KEY key, ref VALUE value) dg) {
        return this[].opApply(dg);
    }

    int opApply(scope int delegate(KEY key, ref const(VALUE) value) dg) const {
        return this[].opApply(dg);
    }

    ref TypedIndexArray opAssign()(VALUE value) @nogc {
        _array[] = value;

        return this;
    }

    ref TypedIndexArray opAssign()(ref VALUE[LENGTH] value) {
        _array[] = value[];

        return this;
    }

    ref TypedIndexArray opOpAssign(string OP)(VALUE value) {
        this[].opOpAssign!OP(value);

        return this;
    }

    ref TypedIndexArray opIndexAssign()(VALUE value, KEY key) {
        _array[key.value] = value;

        return this;
    }

    ref TypedIndexArray opIndexAssign()(VALUE value) {
        this[].opIndexAssign(value);

        return this;
    }

    ref TypedIndexArray opIndexAssign()(VALUE value, Slice slice) {
        slice.opIndexAssign(value);

        return this;
    }

    ref TypedIndexArray opIndexOpAssign(string OP, T)(T value, KEY key) {
        this[].opIndexOpAssign!OP(value, key);

        return this;
    }

    ref TypedIndexArray opIndexOpAssign(string OP, T)(T value) {
        this[].opIndexOpAssign!OP(value);

        return this;
    }

    ref TypedIndexArray opIndexOpAssign(string OP, T)(T value, Slice slice) {
        slice.opIndexOpAssign!OP(value);

        return this;
    }

    @property ref inout(VALUE[LENGTH]) range() inout {
        return _array;
    }
}

auto mapTypedArray(alias _func, KEY, VALUE, size_t LENGTH)(ref TypedIndexArray!(KEY, VALUE, LENGTH) arr) {
    import std.functional : unaryFun;
    import std.traits;
    alias func = unaryFun!_func;
    alias RetType = typeof(func(arr._array[0]));
    TypedIndexArray!(KEY, Unqual!RetType, LENGTH) result;
    foreach(KEY idx, ref VALUE oldVal; arr) {
        result[idx] = func(oldVal);
    }
    return result;
}

// Similar to std.array : array
auto typedIndexArray(KEY, size_t LENGTH, R)(R items) if(isInputRange!R)
{
    alias Array = TypedIndexArray!(KEY, ElementType!R, LENGTH);
    return Array(items);
}

unittest {
    import std.range : iota, take;
    import std.array : array;
    int[10] x = iota(10).array;
    alias Meters = AlgebraicTypedIdentifier!("Meters", uint);
    auto meters = typedIndexArray!(Meters, 10)(x[]);
    assert(meters[Meters(0)] == 0);
    assert(meters[Meters(9)] == 9);
    assert(meters.length == Meters(10));

    import std.algorithm : map, equal;
    assert(meters[].map!(x => x*2).take(5).equal([0, 2, 4, 6, 8]));
}

struct TypedIndexSlice(KEY, VALUE) if (isAlgebraicTypedIdentifier!KEY) {
private:
    VALUE[] _slice;
    KEY.UnderlyingType _offset = 0;

public:
    alias Key = KEY;

    ref inout(VALUE) opIndex(KEY index) inout {
        DBG_ASSERT!"opIndex called with invalid index"(index.isValid);
        return _slice[index.value - _offset];
    }

    ref inout(TypedIndexSlice) opIndex() inout {
        return this;
    }

    inout(TypedIndexSlice) opSlice(KEY begin, KEY end) inout {
        return inout(TypedIndexSlice)(_slice[begin.value - _offset .. end.value - _offset], begin.value);
    }

    @property KEY opDollar() const { return KEY(cast(KEY.UnderlyingType)(length + _offset)); }
    @property size_t length() const { return _slice.length; }

    // DMDBUG: Yes, it is a direct dupliate of the opApply below. Yes, this is precisely what inout was invented
    // for. No, inout doesn't work here. This is because opApply inference is special-cased and doesn't have the full
    // delegate type, but rather must select the overloaded method via "ref" or "const" syntax in the foreach and decl.
    int opApply(scope int delegate(KEY key, ref const(VALUE) value) dg) const {
        foreach( KEY i; iota(KEY(_offset), opDollar) ) {
            int result = dg(i, _slice[i.value - _offset]);
            if (result) return result;
        }
        return 0;
    }

    int opApply(scope int delegate(KEY key, ref VALUE value) dg) {
        foreach( KEY i; iota(KEY(_offset), opDollar) ) {
            int result = dg(i, _slice[i.value - _offset]);
            if (result) return result;
        }
        return 0;
    }

    int opApply(scope int delegate(ref const(VALUE) value) dg) const {
        return opApply((KEY key, ref const(VALUE) val) => dg(val));
    }

    int opApply(scope int delegate(ref VALUE value) dg) {
        return opApply((KEY key, ref VALUE val) => dg(val));
    }

    @property bool empty() { return _slice.empty; }
    @property ref inout(VALUE) front() inout { return _slice.front; }
    void popFront() { _slice.popFront(); _offset++; }

    // TODO: Rename to slice
    @property inout(VALUE)[] range() inout {
        return _slice;
    }

    ref TypedIndexSlice opAssign()(VALUE value) @nogc {
        _slice[] = value;

        return this;
    }

    ref TypedIndexSlice opOpAssign(string OP)(VALUE value) @nogc {
        import std.format : format;
        mixin( q{_slice[] %s= value;}.format(OP) );

        return this;
    }

    ref TypedIndexSlice opIndexAssign()(VALUE value, KEY key) @nogc {
        _slice[key.value - _offset] = value;

        return this;
    }

    ref TypedIndexSlice opIndexAssign()(VALUE value) @nogc {
        _slice[] = value;

        return this;
    }

    ref TypedIndexSlice opIndexOpAssign(string OP, T)(T value, KEY key) @nogc {
        import std.format : format;
        mixin(q{_slice[key.value - _offset] %s= value;}.format(OP));

        return this;
    }

    ref TypedIndexSlice opIndexOpAssign(string OP, T)(T value) @nogc {
        import std.format : format;
        mixin(q{_slice[] %s= value}.format(OP));

        return this;
    }
}


unittest {
    import std.stdio;
    import std.conv;

    alias XXNodeId = AlgebraicTypedIdentifier!("XXNodeId", int);
    alias XXBucketId = TypedIdentifier!("XXBucketId", ushort, 0);
    alias MoisheId = TypedIdentifier!("MoisheId", ulong);

    auto x = XXNodeId(5);
    auto y = XXBucketId(17);
    MoisheId z = 19;

    assert(to!string(x) == "XXNodeId<5>");
    assert(y.value == 17);
    // assert(z == 19);
    static assert (XXNodeId.invalid == XXNodeId(int.max));
    static assert (XXBucketId.invalid == XXBucketId(0));

    static assert(!__traits(compiles, x=y));

    static assert(isTypedIdentifier!XXNodeId);
    static assert(isTypedIdentifier!XXBucketId);
    static assert(isTypedIdentifier!MoisheId);
    static assert(!isTypedIdentifier!int);
}

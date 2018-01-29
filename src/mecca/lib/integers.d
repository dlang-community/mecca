module mecca.lib.integers;

import std.traits;
import std.meta: AliasSeq;
import std.conv;
import std.string;
import std.algorithm: among;

import mecca.log;

version(LDC) {
    ubyte bswap(ubyte x) pure @nogc {
        pragma(inline, true);
        return x;
    }
    ushort bswap(ushort x) pure @nogc {
        pragma(inline, true);
        if (__ctfe) {
            return cast(ushort)((x << 8) | (x >> 8));
        }
        else {
            import ldc.intrinsics: llvm_bswap;
            return llvm_bswap(x);
        }
    }
    uint bswap(uint x) pure @nogc {
        pragma(inline, true);
        if (__ctfe) {
            import core.bitop: bswap;
            return bswap(x);
        }
        else {
            import ldc.intrinsics: llvm_bswap;
            return llvm_bswap(x);
        }
    }
    ulong bswap(ulong x) pure @nogc {
        pragma(inline, true);
        if (__ctfe) {
            import core.bitop: bswap;
            return bswap(x);
        }
        else {
            import ldc.intrinsics: llvm_bswap;
            return llvm_bswap(x);
        }
    }
}
else {
    public import core.bitop: bswap;
    ubyte bswap(ubyte x) pure @nogc {return x;}
    ushort bswap(ushort x) pure @nogc {return cast(ushort)((x << 8) | (x >> 8));}
}

unittest {
    assert(bswap(ubyte(0x12)) == 0x12);
    assert(bswap(ushort(0x1122)) == 0x2211);
    assert(bswap(uint(0x11223344)) == 0x44332211);
    assert(bswap(ulong(0x1122334455667788UL)) == 0x8877665544332211UL);
}

version (LittleEndian) {
    enum hostOrder = 'L';
}
else version (BigEndian) {
    enum hostOrder = 'B';
}
else {
    static assert (false);
}
enum networkOrder = 'B';

private U toEndianity(char E1, char E2, U)(U val) pure @nogc
        if (isIntegral!U && (E1 == 'L' || E1 == 'B') && (E2 == 'L' || E2 == 'B')) {
    pragma(inline, true);
    static if (E1 == E2) {
        return val;
    }
    else {
        return bswap(val);
    }
}
private U endianOp(char E1, string op, char E2, U)(U lhs, U rhs) {
    pragma(inline, true);
    return cast(U)(mixin("toEndianity!(E1, hostOrder)(lhs)" ~ op ~ "toEndianity!(E2, hostOrder)(rhs)"));
}


struct Integer(T, char E) {
    static assert (E == 'L' || E == 'B');
    static assert (is(T == byte) || is(T == ubyte) || is(T == short) || is(T == ushort) ||
        is(T == int) || is(T == uint) || is(T == long) || is(T == ulong), T);
    enum signed = isSigned!T;
    enum bits = T.sizeof * 8;
    enum name = (signed ? "S" : "U") ~ E ~ bits.to!string;
    enum Integer min = Integer(T.min);
    enum Integer max = Integer(T.max);

    T value;

    static assert (this.sizeof == T.sizeof);

    this(T val) {
        value = toEndianity!(E, hostOrder)(val);
    }
    this(U, char E2)(Integer!(U, E2) val) {
        pragma(inline, true);
        opAssign!(U, E2)(val);
    }
    @property T inHostOrder() const pure @nogc {
        pragma(inline, true);
        return toEndianity!(E, hostOrder, T)(value);
    }

    U opCast(U)() {
        static if (is(U == bool)) {
            return value != 0;
        }
        static if (isIntegral!U) {
            return cast(U)value;
        }
        else if (isInstanceOf!(Integer, U)) {
            return U(cast(S)toHostOrder);
        }
        else {
            static assert (false, U);
        }
    }

    auto ref opAssign(T rhs) {
        value = toEndianity!(E, hostOrder)(rhs);
        return this;
    }
    auto ref opAssign(U, char E2)(Integer!(U, E2) rhs) if (signed == rhs.signed) {
        static assert (U.sizeof <= T.sizeof);
        value = toEndianity!(E, E2)(rhs.value);
        return this;
    }

    bool opEquals(T rhs) {
        pragma(inline, true);
        return inHostOrder == rhs;
    }
    bool opEquals(U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed) {
        pragma(inline, true);
        return inHostOrder == rhs.inHostOrder;
    }

    long opCmp(T rhs) {
        pragma(inline, true);
        return inHostOrder < rhs ? -1 : 1;
    }
    long opCmp(U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed) {
        pragma(inline, true);
        return inHostOrder < rhs.inHostOrder ? -1 : 1;
    }

    auto ref opUnary(string op: "++")() {
        pragma(inline, true);
        static if (E == hostOrder) {
            ++value;
        }
        else {
            opAssign(endianOp!(E, "+", hostOrder)(value, cast(T)1));
        }
        return this;
    }
    auto ref opUnary(string op: "--")() {
        static if (E == hostOrder) {
            --value;
        }
        else {
            opAssign(endianOp!(E, "+", hostOrder)(value, cast(T)1));
        }
        return this;
    }

    static if (signed) {
        auto opUnary(string op)() const if (op == "+" || op == "-") {
            pragma(inline, true);
            return Integer(mixin(op ~ "inHostOrder"));
        }

        private alias binOps = AliasSeq!("+", "-", "*", "/", "%", "^");
    }
    else {
        auto opUnary(string op)() const if (op == "~") {
            pragma(inline, true);
            return Integer(mixin(op ~ "inHostOrder"));
        }

        private alias binOps = AliasSeq!("+", "-", "*", "/", "%", "^", "&", "|", "^", "<<", ">>", ">>>");
    }

    auto opBinary(string op)(T rhs) const if (op.among(binOps)) {
        pragma(inline, true);
        return Integer(endianOp!(E, op, hostOrder)(value, rhs));
    }
    auto opBinary(string op, U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed && op.among(binOps)) {
        pragma(inline, true);
        static if (U.sizeof <= T.sizeof) {
            return Integer(endianOp!(E, op, E2)(value, rhs.value));
        }
        else {
            return Integer!(U, E)(endianOp!(E, op, E2)(cast(U)value, rhs.value));
        }
    }

    string toString() const {
        return "%s#%s".format(value, name);
    }
}

alias U8  = Integer!(ubyte,  hostOrder);
alias U16 = Integer!(ushort, hostOrder);
alias U32 = Integer!(uint,   hostOrder);
alias U64 = Integer!(ulong,  hostOrder);

alias S8  = Integer!(byte,   hostOrder);
alias S16 = Integer!(short,  hostOrder);
alias S32 = Integer!(int,    hostOrder);
alias S64 = Integer!(long,   hostOrder);

unittest {
    auto x = 17.U8;
    auto y = 17.S8;
    auto z = 17.U16;

    static assert (!is(typeof(x + y)));
    static assert (!is(typeof(x > y)));
    static assert (is(typeof(x > z) == bool));
    static assert (is(typeof(~x)));
    static assert (is(typeof(x ^ z)));
    static assert (!is(typeof(x ^ y)));
    static assert (!is(typeof(~y)));

    assert (x + z == 34);
    assert (x * 2 == 34);
    assert (y * 2 == 34);
    assert (z * 2 == 34);

    x++;
    y++;
    assert (x == 18);
}

alias NetU8  = Integer!(ubyte,  networkOrder);
alias NetU16 = Integer!(ushort, networkOrder);
alias NetU32 = Integer!(uint,   networkOrder);
alias NetU64 = Integer!(ulong,  networkOrder);

alias NetS8  = Integer!(byte,   networkOrder);
alias NetS16 = Integer!(short,  networkOrder);
alias NetS32 = Integer!(int,    networkOrder);
alias NetS64 = Integer!(long,   networkOrder);

unittest {
    import std.stdio;

    NetU16 x = 17;
    U16 y = x;
    assert (x == y);
    assert (x.value == 0x1100);
    assert (y.value == 0x0011);

    assert (x.toString == "4352#UB16");
    assert (y.toString == "17#UL16");

    auto z = x + y;
    static assert (is(typeof(z) == NetU16));
    assert (z.value == 0x2200);
    auto w = x * 2;
    static assert (is(typeof(w) == NetU16));

    assert (y * 2 == 34);
    assert (x * 2 == w);

    w++;
    assert (w.value == 0x2300);
}


struct SerialInteger(T) {
    static assert (isUnsigned!T, "T must be an unsigned type");

    alias Type = T;
    enum min = T.min;
    enum max = T.max;
    enum T midpoint = (2 ^^ (8 * T.sizeof - 1));
    T value;

    this(T value) nothrow @nogc {
        this.value = value;
    }

    U opCast(U)() nothrow @nogc if (isUnsigned!U) {
        return this.value;
    }

    ref SerialInteger opAssign(SerialInteger rhs) nothrow @nogc {pragma(inline, true);
        this.value = rhs.value;
        return this;
    }
    ref SerialInteger opAssign(T rhs) nothrow @nogc {pragma(inline, true);
        this.value = rhs;
        return this;
    }

    ref SerialInteger opUnary(string op)() nothrow @nogc if (op == "++" || op == "--") {pragma(inline, true);
        mixin(op ~ "value;");
        return this;
    }
    SerialInteger opBinary(string op)(T rhs) const pure nothrow @nogc if (op == "+" || op == "-") {pragma(inline, true);
        return SerialInteger(cast(T)mixin("value " ~ op ~ " rhs"));
    }
    SerialInteger opBinary(string op)(SerialInteger rhs) const pure nothrow @nogc if (op == "+" || op == "-") {pragma(inline, true);
        return SerialInteger(cast(T)mixin("value " ~ op ~ " rhs.value"));
    }

    ref SerialInteger opOpAssign(string op)(T rhs) nothrow @nogc if (op == "+" || op == "-") {pragma(inline, true);
        mixin("value " ~ op ~ "= rhs;");
        return this;
    }
    ref SerialInteger opOpAssign(string op)(SerialInteger rhs) nothrow @nogc if (op == "+" || op == "-") {pragma(inline, true);
        mixin("value " ~ op ~ "= rhs.value;");
        return this;
    }

    bool opEquals(const T rhs) const pure nothrow @nogc {pragma(inline, true);
        return value == rhs;
    }
    bool opEquals(const SerialInteger rhs) const pure nothrow @nogc {pragma(inline, true);
        return value == rhs.value;
    }

    int opCmp(const SerialInteger rhs) const pure nothrow @nogc {pragma(inline, true);
        return opCmp(rhs.value);
    }
    int opCmp(const T rhs) const {pragma(inline, true);
        pragma(inline, true);
        // see https://en.wikipedia.org/wiki/Serial_number_arithmetic
        // note that if the two numbers are on the circumference, then both (a < b) and (b < a) are true
        // but it's too expensive to assert on it
        static if (is(T == ubyte)) {
            return cast(byte)(value - rhs);
        }
        else static if (is(T == ushort)) {
            return cast(short)(value - rhs);
        }
        else static if (is(T == uint)) {
            return cast(int)(value - rhs);
        }
        else {
            static assert (false, "not implemented");
        }
    }

    static assert (this.sizeof == T.sizeof);
}

alias Serial8  = SerialInteger!ubyte;
alias Serial16 = SerialInteger!ushort;
alias Serial32 = SerialInteger!uint;

unittest {
    auto a = Serial16(2);
    a = 7;
    assert(a < 100);
    assert(Serial16(65530) < 100);
    assert(100 > Serial16(65530));
    assert(a == 7);
    a++;
    a += 7;
    assert(a == 15);
    assert(a < 100);
    assert(a > 10);
    assert(Serial16(0) > Serial16(65534));

    // subtraction
    a = Serial16(2);
    assert( (a - cast(ushort)(-1)).value == 3 );
    assert( (a - cast(ushort)(-1)).value == cast(ushort)(a.value + 1) );

    assert( (a - 5).value == 65533 );
    assert( cast(short)((a - 5).value) == cast(short)-3 );
}

/// Flip each bit of the input. Returns the same type as the input.
/// See https://dlang.org/changelog/2.078.0.html#fix16997
T bitComplement(T)(T val) pure nothrow @nogc {
    static if (T.sizeof < int.sizeof) {
        return cast(T)( ~ cast(int)val );
    } else {
        return ~val;
    }
}

unittest {
    {
        ulong sum = 1;
        ubyte val = 0xFE;
        sum += bitComplement(val);
        assert(sum == 2);
    }
    {
        ushort s1 = 0x0101;
        ushort s2 = 0xF00F;
        s1 &= bitComplement(s2);
        assert(s1 == 0x0100);
    }

    static assert( bitComplement(0x0F) == 0xFFFF_FFF0 );
    static assert( bitComplement(ushort(0x0F)) == 0xFFF0 );
}

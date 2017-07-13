module mecca.lib.integers;

import std.traits;
import std.meta: AliasSeq;
import std.conv;
import std.string;
import std.algorithm: among;

version(LDC) {
    public import llvm.intrinsic: bswap = llvm_bswap;
    ubyte bswap(ubyte x) @nogc {return x;}
}
else {
    public import core.bitop: bswap;
    ubyte bswap(ubyte x) @nogc {return x;}
    ushort bswap(ushort x) @nogc {return cast(ushort)((x << 8) | (x >> 8));}
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

private U toEndianity(char E1, char E2, U)(U val) if (isIntegral!U && (E1 == 'L' || E1 == 'B') && (E2 == 'L' || E2 == 'B')) {
    pragma(inline, true);
    static if (E1 == E2) {
        return val;
    }
    else {
        return bswap(val);
    }
}
private U toHostOrder(char E, U)(U val) {
    pragma(inline, true);
    return toEndianity!(E, hostOrder, U)(val);
}
private U endianOp(char E1, string op, char E2, U)(U lhs, U rhs) {
    pragma(inline, true);
    return cast(U)(mixin("toHostOrder!E1(lhs)" ~ op ~ "toHostOrder!E2(rhs)"));
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

    U opCast(U)() {
        static if (is(U == bool)) {
            return value != 0;
        }
        static if (isIntegral!U) {
            return cast(U)value;
        }
        else if (is(U == Integer!(S, E2), S, char E2)) {
            return U(toEndianity!(E, E2)(cast(S)value), true);
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
        return toHostOrder!E(value) == rhs;
    }
    bool opEquals(U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed) {
        return toHostOrder!E(value) == toHostOrder!E2(rhs.value);
    }

    long opCmp(T rhs) {
        return toHostOrder!E(cast(long)value) - (cast(long)rhs);
    }
    long opCmp(U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed) {
        return toHostOrder!E(cast(long)value) - toHostOrder!E2(cast(long)rhs.value);
    }

    auto ref opUnary(string op: "++")() {
        static if (E == hostOrder) {
            ++value;
        }
        else {
            value = toEndianity!(hostOrder, E)(endianOp!(E, "+", hostOrder)(value, cast(T)1));
        }
        return this;
    }
    auto ref opUnary(string op: "--")() {
        static if (E == hostOrder) {
            --value;
        }
        else {
            value = toEndianity!(hostOrder, E)(endianOp!(E, "-", hostOrder)(value, cast(T)1));
        }
        return this;
    }

    static if (signed) {
        auto opUnary(string op)() const if (op == "+" || op == "-") {
            return Integer(mixin(op ~ "toHostOrder!E(value)"));
        }
        private alias binOps = AliasSeq!("+", "-", "*", "/", "%", "^");
    }
    else {
        auto opUnary(string op)() const if (op == "~") {
            return Integer(mixin(op ~ "toHostOrder!E(value)"));
        }
        private alias binOps = AliasSeq!("+", "-", "*", "/", "%", "^", "&", "|", "^", "<<", ">>", ">>>");
    }

    auto opBinary(string op)(T rhs) const if (op.among(binOps)) {
        return Integer(endianOp!(E, op, hostOrder)(value, rhs));
    }
    auto opBinary(string op, U, char E2)(Integer!(U, E2) rhs) const if (signed == rhs.signed && op.among(binOps)) {
        static if (U.sizeof <= T.sizeof) {
            return Integer(endianOp!(E, op, E2)(value, rhs.value));
        }
        else {
            return Integer!(U, E)(endianOp!(E, op, E2)(cast(U)value, rhs.value));
        }
    }

    string toString() const {
        return ("%s#" ~ name).format(value);
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




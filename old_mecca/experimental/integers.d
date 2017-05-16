module mecca.experimental.integers;

import std.string;
import std.conv;
import std.traits;

@("notrace") void traceDisableCompileTimeInstrumentation();


struct Integer(T) {
    static assert (is(T == byte) || is(T == ubyte) || is(T == short) || is(T == ushort) ||
        is(T == int) || is(T == uint) || is(T == long) || is(T == ulong), T);
    enum signed = isSigned!T;
    enum bits = T.sizeof * 8;
    enum name = (signed ? "s" : "u") ~ bits.to!string;
    enum Integer min = Integer(T.min);
    enum Integer max = Integer(T.max);
    static if (bits == 8) {
        static if (signed) {alias promotion = short;} else {alias promotion = ushort;}
    }
    else static if (bits == 16) {
        static if (signed) {alias promotion = int;} else {alias promotion = uint;}
    }
    else static if (bits == 32) {
        static if (signed) {alias promotion = long;} else {alias promotion = ulong;}
    }
    else {
        alias promotion = void;
    }

    T value;
    static assert (this.sizeof == T.sizeof);

    this(T rhs) {
        this.value = rhs;
    }
    this(U)(Integer!U rhs) {
        static assert (U.sizeof <= T.sizeof);
        this.value = rhs.value;
    }

    static if (!is(promotion == void)) {
        @property auto _promote() {return Integer!promotion(value);}
        alias _promote this;
    }

    auto opCast(U: bool)() {
        return value != 0;
    }
    auto opCast(U)() {
        static if (isIntegral!U) {
            return cast(U)value;
        }
        else if (is(U == Integer!S, S)) {
            return U(cast(S)value);
        }
    }

    auto ref opAssign(T rhs) {
        this.value = rhs;
        return this;
    }
    auto ref opAssign(U)(Integer!U rhs) {
        static assert (U.sizeof <= T.sizeof);
        this.value = rhs.value;
        return this;
    }

    auto opBinary(string op)(T rhs) {
        return Integer(cast(T)mixin("value " ~ op ~ " rhs"));
    }
    auto opBinary(string op, U)(Integer!U rhs) {
        static if (U.sizeof <= T.sizeof) {
            return Integer(cast(T)mixin("value " ~ op ~ " rhs.value"));
        }
        else {
            return Integer!U(cast(U)mixin("value " ~ op ~ " rhs.value"));
        }
    }

    auto ref opUnary(string op)() if (op == "++" || op == "--") {
        mixin(op ~ "value");
        return this;
    }

    string toString() {
        return ("%s." ~ name).format(value);
    }
}

alias u8 = Integer!ubyte;
alias u16 = Integer!ushort;
alias u32 = Integer!uint;
alias u64 = Integer!ulong;

alias s8 = Integer!byte;
alias s16 = Integer!short;
alias s32 = Integer!int;
alias s64 = Integer!long;

version (LittleEndian) {
    auto bswap(ubyte x) {return x;}
    auto bswap(ushort x) {return cast(ushort)((x << 8) | (x >> 8));}
    auto bswap(uint x) {return x;}
    auto bswap(ulong x) {return x;}

    struct HostOrder(T) {
        T value;

        this(T ho) {opAssign(ho);}
        this(U)(HostOrder!U ho) {opAssign(ho);}
        this(U)(NetworkOrder!U no) {opAssign(no);}

        auto ref opAssign(T value) {
            this.value = value;
            return this;
        }
        auto ref opAssign(U)(HostOrder!U ho) {
            return opAssign(cast(T)ho.value);
        }
        auto ref opAssign(U)(NetworkOrder!U no) {
            value = bswap(no.value);
            return this;
        }

        @property auto networkOrder() {return NetworkOrder!T(value);}
    }

    struct NetworkOrder(T) {
        T value;

        this(T ho) {opAssign(ho);}
        this(U)(HostOrder!U ho) {opAssign(ho);}
        this(U)(NetworkOrder!U no) {opAssign(no);}

        auto ref opAssign(T ho) {
            this.value = bswap(value);
            return this;
        }
        auto ref opAssign(U)(HostOrder!U ho) {
            return opAssign(cast(T)ho.value);
        }
        auto ref opAssign(U)(NetworkOrder!U no) {
            value = no.value;
            return this;
        }

        @property auto hostOrder() {return HostOrder!T(value);}
    }
}
else version (BigEndian) {
    struct NetworkOrder(T) {
        T value;

        @property auto hostOrder() {return this;}
        @property auto networkOrder() {return this;}
    }

    alias HostOrder = NetworkOrder;
}
else {
    static assert (false);
}

alias hu8 = HostOrder!ubyte;
alias hu16 = HostOrder!ushort;
alias hu32 = HostOrder!uint;
alias hu64 = HostOrder!ulong;
alias hs8 = HostOrder!byte;
alias hs16 = HostOrder!short;
alias hs32 = HostOrder!int;
alias hs64 = HostOrder!long;
alias nu8 = NetworkOrder!ubyte;
alias nu16 = NetworkOrder!ushort;
alias nu32 = NetworkOrder!uint;
alias nu64 = NetworkOrder!ulong;
alias ns8 = NetworkOrder!byte;
alias ns16 = NetworkOrder!short;
alias ns32 = NetworkOrder!int;
alias ns64 = NetworkOrder!long;


unittest {
    import std.stdio;
    auto x = 5.u8;
    auto y = 6.u16;
    y = 9;
    y = x;

    static void f(u64 x) {writeln(x);}

    f(x);

    writeln(x + y);
}

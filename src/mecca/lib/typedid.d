module mecca.lib.typedid;

import std.traits;
import std.conv;


struct TypedIdentifier(string _name, T, T _invalid = T.max, T _init=_invalid, bool algebraic=false) if (isIntegral!T) {
private:
    T _value = _init;

public:
    alias UnderlyingType = T;
    enum TypedIdentifier invalid = TypedIdentifier(_invalid);
    enum name = _name;

    this(T value) @safe pure nothrow @nogc {
        this._value = value;
    }
    // Default this(this) does the right thing

    @property T value() const pure nothrow @safe @nogc {
        return _value;
    }
    @property bool isValid() const pure nothrow @safe @nogc {
        return _value != _invalid;
    }
    ref TypedIdentifier opAssign(T val) nothrow @safe @nogc {
        _value = val;
        return this;
    }

    // Default opEquals does the right thing

    static if (algebraic) {
        enum TypedIdentifier min = T.min;
        enum TypedIdentifier max = T.max;

        int opCmp(in TypedIdentifier rhs) const pure nothrow @safe @nogc {
            return value > rhs.value ? 1 : (value < rhs.value ? -1 : 0);
        }

        // Pointer like semantics:
        // Can add integer to TypedIdentifier to get TypedIdentifier
        ref TypedIdentifier opOpAssign(string op)(in T rhs) nothrow @safe @nogc if (op == "+" || op == "-") {
            mixin("_value "~op~"= rhs;");
            return this;
        }

        TypedIdentifier opBinary(string op)(in T rhs) const pure nothrow @safe @nogc if (op == "+" || op == "-") {
            TypedIdentifier res = this;
            //return mixin("res "~op~"= rhs;");
            res += rhs;
            return res;
        }

        ref TypedIdentifier opUnary(string op)() nothrow @safe @nogc if (op == "++" || op == "--") {
            if (isValid)
                mixin("_value" ~ op ~ ";");

            return this;
        }

        // Can subtract two TypedIdentifier to get an integer
        T opBinary(string op : "-")(in TypedIdentifier rhs) const pure nothrow @safe @nogc {
            return value - rhs.value;
        }
    }

    // toString is not @nogc
    string toString() const pure nothrow @safe {
        return name ~ "<" ~ (isValid ? to!string(_value) : "INVALID") ~ ">";
    }

    static assert (this.sizeof == T.sizeof);
}

alias AlgebraicTypedIdentifier(string name, T, T invalid = T.max, T init = invalid) = TypedIdentifier!(name, T, invalid, init, true);


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

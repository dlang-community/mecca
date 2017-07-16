module mecca.lib.sumtypes;

import mecca.lib.reflection;

struct SumType(CASES_...) {
    static if (is(typeof(CASES_[$-1]): int)) {
        enum ubyte default_ = CASES_[$-1];
        alias CASES = CASES_[0 .. $-1];
    }
    else {
        enum ubyte default_ = ubyte.max;
        alias CASES = CASES_;
    }
    static assert (NoDuplicates!CASES.length == CASES.length, "Duplicate types found");
    static assert (CASES.length < ubyte.max);

    enum isOneOfTheCases(T) = (staticIndexOf!(T, CASES) >= 0);

    private ubyte which = default_;
    union {
        private CASES cases;
    }

    this(T)(auto ref T rhs) if (isOneOfTheCases!T) {
        opAssign(rhs);
    }
    ref auto opAssign(T)(auto ref T rhs) if (isOneOfTheCases!T) {
        enum idx = staticIndexOf!(T, CASES);
        which = idx;
        cases[idx] = rhs;
    }
    ref auto opAssign(ref SumType rhs) {
        which = rhs.which;
        this.asBytes[cases[0].offsetof .. $] = rhs.asBytes[cases[0].offsetof .. $];
        return this;
    }
    void unset() pure @nogc {
        which = ubyte.max;
    }
    @property bool isSet() const pure @nogc {
        return which != ubyte.max;
    }

    @property bool isA(T)() const if (isOneOfTheCases!T) {
        foreach (i, U; CASES) {
            static if (is(T == U)) {
                return which == i;
            }
        }
        assert(false);
    }
    @property ref T get(T)() if (isOneOfTheCases!T) {
        foreach (i, U; CASES) {
            static if (is(T == U)) {
                assert (which == i);
                return cases[i];
            }
        }
        assert(false);
    }

    string toString() {
        import std.conv: text;
        switch (which) {
            foreach (i, U; CASES) {
                case i:
                    return text(cases[i]);
            }
            default:
                return "(unset)";
        }
    }
}

template caseOf(Fs...) {
    auto caseOf(T)(ref T st) if (isInstanceOf!(SumType, T)) {
        static assert (Fs.length == T.CASES.length);
        switch (st.which) {
            foreach (i, F; Fs) {
                enum idx = staticIndexOf!(Parameters!F[0], T.CASES);
                static assert (idx >= 0);

                case idx:
                    return F(st.cases[idx]);
            }

            default:
                assert(false);
        }
        assert (false);
    }
}
template caseOfTemplated(alias func, T) if (isInstanceOf!(SumType, T)) {
    auto caseOfTemplated(ref T st) {
        final switch (st.which) {
            foreach(i, _; T.CASES) {
                case i:
                    return func(st.cases[i]);
            }
        }
        assert (false);
    }
}

unittest {
    import std.string;
    import std.stdio;

    SumType!(double, int, string) sm;
    sm = 7;
    auto res = sm.caseOf!(
        (int x) {return "int %s".format(x);},
        (double x) {return "double %s".format(x);},
        (string x) {return "string %s".format(x);},
    );

    assert(res == "int 7");

    sm = 3.14;
    res = sm.caseOfTemplated!(a => "%s %s".format(typeid(a), a));
    assert (res == "double 3.14");
}

struct Maybe(T) {
    private SumType!(typeof(null), T, 0) value;

    this(T value_) {
        value = value_;
    }
    ref auto opAssign(T rhs) {
        value = rhs;
        return this;
    }
    ref auto opAssign(ref T rhs) {
        value = rhs;
        return this;
    }
    ref auto opAssign(typeof(null) rhs) {
        value = null;
        return this;
    }
    @property bool hasValue() const {
        return value.isA!T;
    }
    auto get() {
        return value.get!T;
    }

    string toString() {
        import std.conv: text;
        return hasValue ? text(get) : "(null)";
    }

    auto caseOf(alias just, alias nothing)() {
        return value.caseOf!(
            just,
            (typeof(null) x) => nothing)();
    }
}

unittest {
    import std.stdio;
    import std.string;

    Maybe!int x;
    assert (!x.hasValue);
    x = 7;
    assert (x.hasValue);
    assert(x.toString == "7");
    x = null;
    assert (!x.hasValue);
    assert(x.toString == "(null)");

    foreach(i, expected; ["no string today", "foo 18"]) {
        auto res = x.caseOf!(
            (int y) => "foo %s".format(y),
            "no string today");
        assert (res == expected);
        x = 18;
    }
}



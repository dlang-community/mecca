/// Utility functions for handling strings
module mecca.lib.string;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.ascii;
import std.conv;
import std.string;
import std.traits;
import std.typetuple;

import mecca.lib.exception;
import mecca.lib.typedid;
import mecca.log;

/**
 * Convert a D string to a C style null terminated pointer
 *
 * The function uses a static buffer in order to keep the string whie needed. The function's return type is a custom type that tracks the
 * life time of the pointer. This type is implicitly convertible to `char*` for ease of use.
 *
 * Most cases can use the return type as if it is a pointer to char:
 *
 * `fcntl.open(toStringzNGC(pathname), flags);`
 *
 * If keeping the pointer around longer is needed, it should be stored in a variable of type `auto`:
 *
 * `auto fileNameC = toStringzNGC(fileName);`
 *
 * This can be kept around until end of scope. It can be released earlier with the `release` function:
 *
 * `fileNameC.release();`
 *
 * Params:
 *   dString = the D string to be converted to zero terminated format.
 *
 * Returns:
 *   A custom type with a destructor, a function called `release()`, and an implicit conversion to `char*`.
 *
 */
auto toStringzNGC(string dString) nothrow @trusted @nogc {
    enum MaxStringSize = 4096;
    __gshared static char[MaxStringSize] buffer;
    __gshared static bool inUse;

    ASSERT!"toStringzNGC called while another instance is still in use. Buffer currently contains: %s"(!inUse, buffer[]);
    // DMDBUG? The following line triggers a closure GC
    //ASSERT!"toStringzNGC got %s chars long string, maximal string size is %s"(dString.length<MaxStringSize, dString.length, MaxStringSize-1);

    char[] cString = buffer[0..dString.length + 1];
    cString[0..dString.length] = dString[];
    cString[dString.length] = '\0';

    static struct toStringzNGCContext {
    private:
        alias LengthType = ushort;
        static assert((1 << (LengthType.sizeof * 8)) > MaxStringSize, "Length type not big enough for buffer");
        LengthType length;

    public:
        @disable this(this);

        this(LengthType length) nothrow @trusted @nogc {
            this.length = length;
            inUse = true;
        }

        ~this() nothrow @safe @nogc {
            release();
        }

        void release() nothrow @trusted @nogc {
            enum UnusedString = "toStringzNGC result used after already stale\0";
            inUse = false;
            buffer[0..UnusedString.length] = UnusedString[];
        }

        @property char* ptr() nothrow @trusted @nogc {
            return &buffer[0];
        }

        alias ptr this;
    }

    return toStringzNGCContext(cast(toStringzNGCContext.LengthType)cString.length);
}


struct ToStringz(size_t N) {
    char[N] buffer;

    @disable this();
    @disable this(this);

    this(const(char)[] str) nothrow @safe @nogc {
        opAssign(str);
    }
    ref ToStringz opAssign(const(char)[] str) nothrow @safe @nogc {
        assert (str.length < buffer.length, "Input string too long");
        buffer[0 .. str.length] = str;
        buffer[str.length] = '\0';
        return this;
    }
    @property const(char)* ptr() const nothrow @system @nogc {
        return buffer.ptr;
    }
    alias ptr this;
}

unittest {
    import core.stdc.string: strlen;

    assert (strlen(ToStringz!64("hello")) == 5);
    assert (strlen(ToStringz!64("kaki")) == 4);
    {
        auto s = ToStringz!64("0123456789");
        assert (strlen(s) == 10);
        s = "moshe";
        assert (strlen(s) == 5);
    }
    assert (strlen(ToStringz!64("mishmish")) == 8);
}


private enum FMT: ubyte {
    STR,
    CHR,
    DEC,
    HEX,
    PTR,
    FLT,
}

@notrace
ulong getNextNonDigitFrom(string fmt){
    ulong idx;
    foreach(c; fmt){
        if ("0123456789+-.".indexOf(c) < 0) {
            return idx;
        }
        ++idx;
    }
    return idx;
}

template splitFmt(string fmt) {
    template pair(int j, FMT f) {
        enum size_t pair = (j << 8) | (cast(ubyte)f);
    }

    template helper(int from, int j) {
        enum idx = fmt[from .. $].indexOf('%');
        static if (idx < 0) {
            enum helper = TypeTuple!(fmt[from .. $]);
        }
        else {
            enum idx1 = idx + from;
            static if (idx1 >= fmt.length - 1) {
                static assert (false, "Expected formatter after %");
            }else{
                enum idx2 = idx1 + getNextNonDigitFrom(fmt [idx1+1 .. $]);
                //pragma(msg, fmt);
                //pragma(msg, idx2);
                static if (fmt[idx2+1] == 's') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.STR), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'c') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.CHR), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'n') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.STR), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'd') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.DEC), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'x') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.HEX), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'b') {  // should be binary, but use hex for now
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.HEX), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'p') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.PTR), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == 'f' || fmt[idx2+1] == 'g') {
                    enum helper = TypeTuple!(fmt[from .. idx2], pair!(j, FMT.FLT), helper!(idx2+2, j+1));
                }
                else static if (fmt[idx2+1] == '%') {
                    enum helper = TypeTuple!(fmt[from .. idx2+1], helper!(idx2+2, j));
                }
                else {
                    static assert (false, "Invalid formatter '"~fmt[idx2+1]~"'");
                }
            }
        }
    }

    template countFormatters(tup...) {
        static if (tup.length == 0) {
            enum countFormatters = 0;
        }
        else static if (is(typeof(tup[0]) == size_t)) {
            enum countFormatters = 1 + countFormatters!(tup[1 .. $]);
        }
        else {
            enum countFormatters = countFormatters!(tup[1 .. $]);
        }
    }

    alias tokens = helper!(0, 0);
    alias numFormatters = countFormatters!tokens;
}

@notrace @nogc char[] formatDecimal(size_t W = 0, char fillChar = ' ', T)(char[] buf, T val) pure nothrow if (is(typeof({ulong v = val;}))) {
    const neg = (isSigned!T) && (val < 0);
    size_t len = neg ? 1 : 0;
    ulong v = neg ? -long(val) : val;

    auto tmp = v;
    while (tmp) {
        tmp /= 10;
        len++;
    }
    static if (W > 0) {
        if (W > len) {
            buf[0 .. W - len] = fillChar;
            len = W;
        }
    }

    if (v == 0) {
        static if (W > 0) {
            buf[len-1] = '0';
        }
        else {
            buf[len++] = '0';
        }
    }
    else {
        auto idx = len;
        while (v) {
            buf[--idx] = "0123456789"[v % 10];
            v /= 10;
        }
        if (neg) {
            buf[--idx] = '-';
        }
    }
    return buf[0 .. len];
}

@notrace @nogc char[] formatDecimal(char[] buf, bool val) pure nothrow {
    if (val) {
        return cast(char[])"1";
    }
    return cast(char[])"0";
}

unittest {
    char[100] buf;
    assert (formatDecimal!10(buf, -1234) == "     -1234");
    assert (formatDecimal!10(buf, 0)     == "         0");
    assert (formatDecimal(buf, -1234)    == "-1234");
    assert (formatDecimal(buf, 0)        == "0");
    assert (formatDecimal!3(buf, 1234)   == "1234");
    assert (formatDecimal!3(buf, -1234)  == "-1234");
    assert (formatDecimal!3(buf, 0)      == "  0");
    assert (formatDecimal!(3,'0')(buf, 0)      == "000");
    assert (formatDecimal!(3,'a')(buf, 0)      == "aa0");
    assert (formatDecimal!(10, '0')(buf, -1234) == "00000-1234");
}

@notrace @nogc char[] formatHex(size_t W=0)(char[] buf, ulong val) pure nothrow {
    size_t len = 0;
    auto v = val;

    while (v) {
        v >>= 4;
        len++;
    }
    static if (W > 0) {
        if (W > len) {
            buf[0 .. W - len] = '0';
            len = W;
        }
    }

    v = val;
    if (v == 0) {
        static if (W == 0) {
            buf[0] = '0';
            len = 1;
        }
    }
    else {
        auto idx = len;
        while (v) {
            buf[--idx] = "0123456789ABCDEF"[v & 0x0f];
            v >>= 4;
        }
    }
    return buf[0 .. len];
}

unittest {
    import mecca.lib.exception;
    char[100] buf;
    assertEQ(formatHex(buf, 0x123), "123");
    assertEQ(formatHex!10(buf, 0x123), "0000000123");
    assertEQ(formatHex(buf, 0), "0");
    assertEQ(formatHex!10(buf, 0), "0000000000");
    assertEQ(formatHex!10(buf, 0x123456789), "0123456789");
    assertEQ(formatHex!10(buf, 0x1234567890), "1234567890");
    assertEQ(formatHex!10(buf, 0x1234567890a), "1234567890A");
}

@notrace @nogc char[] formatPtr(char[] buf, ulong p) pure nothrow {
    return formatPtr(buf, cast(void*)p);
}

@notrace @nogc char[] formatPtr(char[] buf, const void* p) pure nothrow {
    if (p is null) {
        buf[0 .. 4] = "null";
        return buf[0 .. 4];
    }
    else {
        import std.stdint : intptr_t;
        return formatHex!((void*).sizeof*2)(buf, cast(intptr_t)p);
    }
}

@notrace @nogc char[] formatFloat(char[] buf, double val) pure nothrow {
    assert (false, "Not implemented");
}

@notrace @nogc string enumToStr(E)(E value) pure nothrow {
    switch (value) {
        foreach(name; __traits(allMembers, E)) {
            case __traits(getMember, E, name):
                return name;
        }
        default:
            return null;
    }
}

unittest {
    import mecca.lib.exception;
    import std.string: format, toUpper;
    char[100] buf;
    int p;

    assertEQ(formatPtr(buf, 0x123), "0000000000000123");
    assertEQ(formatPtr(buf, 0), "null");
    assertEQ(formatPtr(buf, null), "null");
    assertEQ(formatPtr(buf, &p), format("%016x", &p).toUpper);
}

@notrace @nogc string nogcFormat(string fmt, T...)(char[] buf, T args) pure nothrow {
    alias sfmt = splitFmt!fmt;
    static assert (sfmt.numFormatters == T.length, "Expected " ~ text(sfmt.numFormatters) ~
        " arguments, got " ~ text(T.length));

    char[] p = buf;
    @nogc pure nothrow
    void advance(const(char[]) str) {
        p = p[str.length..$];
    }
    @nogc pure nothrow
    void write(const(char[]) str) {
        p[0..str.length] = str;
        advance(str);
    }

    @nogc pure nothrow
    void writeHex(const(char[]) str) {
        for(auto i=0; i< str.length; i++) {
            p[0] = "0123456789abcdef"[(str[i]>>4)];
            p[1] = "0123456789abcdef"[(str[i]&0x0F)];
            p=p[2..$];
        }
    }

    foreach(tok; sfmt.tokens) {
        static if (is(typeof(tok) == string)) {
            static if (tok.length > 0) {
                write(tok);
            }
        }
        else static if (is(typeof(tok) == size_t)) {
            enum j = tok >> 8;
            enum f = cast(FMT)(tok & 0xff);

            alias Typ = T[j];
            auto val = args[j];

            static if (f == FMT.STR) {
                static if (is(typeof(advance(val.nogcToString(p))))) {
                    advance(val.nogcToString(p));
                } else static if (is(Typ == string) || is(Typ == char[]) || is(Typ == const(char)[]) || is(Typ == char[Len], uint Len)) {
                    write(val[]);
                } else static if (is(Typ == enum)) {
                    auto tmp = enumToStr(val);
                    if (tmp is null) {
                        advance(p.nogcFormat!"%s(%d)"(Typ.stringof, val));
                    } else {
                        write(tmp);
                    }
                } else static if (is(Typ == U[N], U, size_t N) || is(Typ == U[], U)) {
                    write("[");
                    foreach(i, x; val) {
                        if(i > 0) {
                            advance(p.nogcFormat!", %s"(x));
                        } else {
                            advance(p.nogcFormat!"%s"(x));
                        }
                    }
                    write("]");
                } else static if (isTypedIdentifier!Typ) {
                    advance(p.nogcFormat!(Typ.name ~ "<%s>")(val.value));
                } else static if (isPointer!Typ) {
                    advance(formatPtr(p, val));
                } else static if (is(Typ : ulong)) {
                    advance(formatDecimal(p, val));
                } else static if (is(Typ == struct)) {
                    {
                        enum Prefix = Typ.stringof ~ "(";
                        write(Prefix);
                    }
                    alias Names = FieldNameTuple!Typ;
                    foreach(i, field; val.tupleof) {
                        enum string Name = Names[i];
                        enum Prefix = (i == 0 ? "" : ", ") ~ Name ~ " = ";
                        write(Prefix);
                        // TODO: Extract entire FMT.STR hangling to nogcToString and use that:
                        advance(p.nogcFormat!"%s"(field));
                    }
                    write(")");
                } else {
                    static assert (false, "Expected string, enum or integer, not " ~ Typ.stringof);
                }
            }
            else static if (f == FMT.CHR) {
                static assert (is(T[j] : char));
                write((&val)[0..1]);
            }
            else static if (f == FMT.DEC) {
                static assert (is(T[j] : ulong));
                advance(formatDecimal(p, val));
            }
            else static if (f == FMT.HEX) {
                static if (is(Typ == string) || is(Typ == char[])|| is(Typ == const(char)[]) || is(Typ == char[Len], uint Len)) {
                    writeHex(val);
                } else {
                static assert (is(T[j] : ulong));
                    write("0x");
                    advance(formatHex(p, val));
                }
            }
            else static if (f == FMT.PTR) {
                static assert (is(T[j] : ulong) || isPointer!(T[j]));
                advance(formatPtr(p, val));
            }
            else static if (f == FMT.FLT) {
                static assert (is(T[j] : double));
                advance(formatFloat(p, val));
            }
        }
        else {
            static assert (false);
        }
    }

    auto len = p.ptr - buf.ptr;
    import std.exception : assumeUnique;
    return buf[0 .. len].assumeUnique;
}

@notrace @nogc string nogcFormatTmp(string fmt, T...)(T args) nothrow {
    // the lengths i have to go to fool `pure`
    static __gshared char[1024] tmpBuf;

    return nogcFormat!fmt(cast(char[])tmpBuf, args);
}

unittest {
    char[100] buf;
    assert (nogcFormat!"hello %s %s %% world %d %x %p"(buf, [1, 2, 3], "moshe", -567, 7, 7) == "hello [1, 2, 3] moshe % world -567 0x7 0000000000000007");
}

unittest {
    import std.exception;
    import core.exception : RangeError;

    auto fmt(string fmtStr, size_t size = 16, Args...)(Args args) {
        auto buf = new char[size];
        return nogcFormat!fmtStr(buf, args);
    }

    static assert(fmt!"abcd abcd" == "abcd abcd");
    static assert(fmt!"123456789a" == "123456789a");
    version (D_NoBoundsChecks) {} else {
        assertThrown!RangeError(fmt!("123412341234", 10));
    }

    // literal escape
    static assert(fmt!"123 %%" == "123 %");
    static assert(fmt!"%%%%" == "%%");

    // %d
    static assert(fmt!"%d"(1234) == "1234");
    static assert(fmt!"ab%dcd"(1234) == "ab1234cd");
    static assert(fmt!"ab%d%d"(1234, 56) == "ab123456");

    // %x
    static assert(fmt!"%x"(0x1234) == "0x1234");

    // %p
    static assert(fmt!("%p", 20)(0x1234) == "0000000000001234");

    // %s
    static assert(fmt!"12345%s"("12345") == "1234512345");
    static assert(fmt!"12345%s"(12345) == "1234512345");
    enum Floop {XXX, YYY, ZZZ}
    static assert(fmt!"12345%s"(Floop.YYY) == "12345YYY");

    // Arg num
    static assert(!__traits(compiles, fmt!"abc"(5)));
    static assert(!__traits(compiles, fmt!"%d"()));
    static assert(!__traits(compiles, fmt!"%d a %d"(5)));

    // Format error
    static assert(!__traits(compiles, fmt!"%"()));
    static assert(!__traits(compiles, fmt!"abcd%d %"(15)));
    static assert(!__traits(compiles, fmt!"%$"(1)));
    //static assert(!__traits(compiles, fmt!"%s"(1)));
    static assert(!__traits(compiles, fmt!"%d"("hello")));
    //static assert(!__traits(compiles, fmt!"%x"("hello")));

    static assert(fmt!"Hello %s"(5) == "Hello 5");
    alias Moishe = TypedIdentifier!("Moishe", ushort);
    static assert(fmt!"Hello %s"(Moishe(5)) == "Hello Moishe<5>");

    struct Foo { int x, y; }
    static assert(fmt!("Hello %s", 40)(Foo(1, 2)) == "Hello Foo(x = 1, y = 2)");
}

@notrace @nogc nothrow pure
string nogcRtFormat(T...)(char[] buf, string fmt, T args) {
    size_t fmtIdx = 0;
    size_t bufIdx = 0;

    @notrace @nogc nothrow pure
    char nextFormatter() {
        while (true) {
            long pctIdx = -1;
            foreach(j, ch; fmt[fmtIdx .. $]) {
                if (ch == '%') {
                    pctIdx = fmtIdx + j;
                    break;
                }
            }
            if (pctIdx < 0) {
                return 's';
            }

            auto fmtChar = (pctIdx < fmt.length - 1) ? fmt[pctIdx + 1] : 's';

            auto tmp = fmt[fmtIdx .. pctIdx];
            buf[bufIdx .. bufIdx + tmp.length] = tmp;
            bufIdx += tmp.length;
            fmtIdx = pctIdx + 2;

            if (fmtChar == '%') {
                buf[bufIdx++] = '%';
                continue;
            }
            return fmtChar;
        }
    }

    foreach(i, U; T) {
        auto fmtChar = nextFormatter();

        static if (is(U == string) || is(U: char[])) {
            assert (fmtChar == 's'/*, text(fmtChar)*/);
            buf[bufIdx .. bufIdx + args[i].length] = args[i];
            bufIdx += args[i].length;
        }
        else static if (is(U == char*) || is(U == const(char)*) || is (U == const(char*))) {
            if (fmtChar == 's') {
                auto tmp = fromStringz(args[i]);
                buf[bufIdx .. bufIdx + tmp.length] = tmp;
                bufIdx += tmp.length;
            }
            else if (fmtChar == 'p') {
                bufIdx += formatPtr(buf[bufIdx .. $], args[i]).length;
            }
            else {
                assert (false /*, text(fmtChar)*/);
            }
        }
        else static if (is(U == enum)) {
            if (fmtChar == 's') {
                auto tmp = enumToStr(args[i]);
                if (tmp is null) {
                    bufIdx += nogcFormat!"%s(%d)"(buf[bufIdx .. $], U.stringof, args[i]).length;
                }
                else {
                    buf[bufIdx .. bufIdx + tmp.length] = tmp;
                    bufIdx += tmp.length;
                }
            }
            else if (fmtChar == 'x') {
                buf[bufIdx .. bufIdx + 2] = "0x";
                bufIdx += 2;
                bufIdx += formatHex(buf[bufIdx .. $], args[i]).length;
            }
            else if (fmtChar == 'p') {
                bufIdx += formatPtr(buf[bufIdx .. $], args[i]).length;
            }
            else if (fmtChar == 's' || fmtChar == 'd') {
                bufIdx += formatDecimal(buf[bufIdx .. $], args[i]).length;
            }
            else {
                assert (false /*, text(fmtChar)*/);
            }
        }
        else static if (is(U : ulong)) {
            if (fmtChar == 'x') {
                buf[bufIdx .. bufIdx + 2] = "0x";
                bufIdx += 2;
                bufIdx += formatHex(buf[bufIdx .. $], args[i]).length;
            }
            else if (fmtChar == 'p') {
                bufIdx += formatPtr(buf[bufIdx .. $], args[i]).length;
            }
            else if (fmtChar == 's' || fmtChar == 'd') {
                bufIdx += formatDecimal(buf[bufIdx .. $], args[i]).length;
            }
            else {
                assert (false /*, text(fmtChar)*/);
            }
        }
        else static if (is(U == TypedIdentifier!X, X...)) {
            bufIdx += nogcFormat!"%s(%d)"(buf[bufIdx .. $], U.name, args[i].value).length;
        }
        else static if (isPointer!U) {
            bufIdx += formatPtr(buf[bufIdx .. $], args[i]).length;
        }
        else {
            static assert (false, "Cannot format " ~ U.stringof);
        }
    }

    // tail
    if (fmtIdx < fmt.length) {
        auto tmp = fmt[fmtIdx .. $];
        buf[bufIdx .. bufIdx + tmp.length] = tmp;
        bufIdx += tmp.length;
    }

    return cast(string)buf[0 .. bufIdx];
}

unittest {
    import mecca.lib.exception;
    char[100] buf;
    assertEQ(nogcRtFormat(buf, "hello %% %s world %d", "moshe", 15), "hello % moshe world 15");
}


template HexFormat(T) if( isIntegral!T )
{
    static if( T.sizeof == 1 )
        enum HexFormat = "%02x";
    else static if( T.sizeof == 2 )
        enum HexFormat = "%04x";
    else static if( T.sizeof == 4 )
        enum HexFormat = "%08x";
    else static if( T.sizeof == 8 )
        enum HexFormat = "%016x";
    else
        static assert(false);
}

@notrace static string hexArray(T)( const T[] array ) if( isIntegral!T ) {
    import std.string;
    auto res = "[";
    foreach( i, element; array ) {
        if( i==0 )
            res ~= " ";
        else
            res ~= ", ";

        res ~= format(HexFormat!T, element);
    }
    res ~= " ]";
    return res;
}


@notrace string buildStructFormatCode(string fmt, string structName, string conversionFunction = "text") {
    string iter = fmt[];
    string result = "`";
    while (0 < iter.length) {
        auto phStart = iter.indexOf('{');
        auto phEnd = iter.indexOf('}');

        // End of format string
        if (phStart < 0 && phEnd < 0) {
            result ~= iter;
            break;
        }

        assert (0 <= phStart, "single '}' in `" ~ fmt ~ "`");
        assert (0 <= phEnd, "single '{' in `" ~ fmt ~ "`");
        assert (phStart < phEnd, "single '}' in `" ~ fmt ~ "`");

        result ~= iter[0 .. phStart];
        result ~= "` ~ " ~ conversionFunction ~ "(" ~ structName ~ "." ~ iter[phStart + 1 .. phEnd] ~ ") ~ `";
        iter = iter[phEnd + 1 .. $];
    }
    return result ~ "`";
}

unittest {
    struct Foo {
        int x;
        string y;
    }
    string formatFoo(Foo foo) {
        return mixin(buildStructFormatCode("x is {x} and y is {y}", "foo"));
    }
    assert (formatFoo(Foo(1, "a")) == "x is 1 and y is a");
    assert (formatFoo(Foo(2, "b")) == "x is 2 and y is b");
}

struct StaticFormatter {
    char[] buf;
    size_t offset;

    this(char[] buf) @nogc nothrow @safe {
        this.buf = buf;
        offset = 0;
    }
    @notrace void rewind() nothrow @nogc {
        offset = 0;
    }
    @notrace void append(char ch) @nogc {
        buf[offset .. offset + 1] = ch;
        offset++;
    }
    @notrace void append(string s) @nogc {
        buf[offset .. offset + s.length] = s;
        offset += s.length;
    }
    @notrace void append(string FMT, T...)(T args) @nogc {
        auto s = nogcFormat!FMT(buf[offset .. $], args);
        offset += s.length;
    }
    @notrace void accumulate(const(char)[] function(char[]) @nogc dg) @nogc {
        auto s = dg(remaining);
        assert(cast(void*)s.ptr == remaining.ptr, "dg() returned wrong buffer");
        skip(s.length);
    }
    @notrace void accumulate(const(char)[] delegate(char[]) @nogc dg) @nogc {
        auto s = dg(remaining);
        assert(cast(void*)s.ptr == remaining.ptr, "dg() returned wrong buffer");
        skip(s.length);
    }
    @notrace void accumulate(alias F, T...)(T args) @nogc {
        auto s = F(remaining, args);
        assert(cast(void*)s.ptr == remaining.ptr, "dg() returned wrong buffer");
        skip(s.length);
    }

    @property string text() @nogc {
        return cast(string)buf[0 .. offset];
    }
    @property char[] remaining() @nogc {
        return buf[offset .. $];
    }
    @notrace void skip(size_t count) @nogc {
        assert (offset + count <= buf.length, "overflow");
        offset += count;
    }
}

unittest {
    char[100] buf;
    auto sf = StaticFormatter(buf);
    sf.append!"a=%s b=%s "(1, 2);
    sf.append!"c=%s d=%s"(3, 4);
    assert(sf.text == "a=1 b=2 c=3 d=4", sf.text);
}



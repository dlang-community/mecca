/// Utility functions for handling strings
module mecca.lib.string;

import std.traits;

import mecca.lib.exception;

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

    this(string str) nothrow @trusted @nogc {
        opAssign(str);
    }
    ref ToStringz opAssign(string str) nothrow @trusted @nogc {
        assert (str.length < buffer.length, "Input string too long");
        buffer[0 .. str.length] = str;
        buffer[str.length] = '\0';
        return this;
    }
    @property const(char)* ptr() const nothrow @trusted @nogc {
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




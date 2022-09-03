/// @safe @nogc arrays
module mecca.containers.arrays;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;
import mecca.lib.reflection: CapacityType;
import mecca.lib.exception;
import std.range;

/**
 * A variable size array with a fixed maximal capacity
 */
struct FixedArray(T, size_t N, bool InitializeMembers = true) {
    /// Alias for querying the array's element type
    alias ElementType = T;

private:
    alias L = CapacityType!N;
    static if (InitializeMembers) {
        T[N] data;
    } else {
        T[N] data = void;
    }
    L _length;

public:
    /// Return the maximal capacity of the array
    ///
    /// Returns:
    /// The capacity of the array, using the smallest unsigned type that can hold it.
    @property L capacity() const nothrow pure @nogc {
        return N;
    }

    /// Return the length of the array.
    ///
    /// This returns the same value as `length`, except it uses the narrowest type in which the length is guaranteed to
    /// fit.
    @property L len() const nothrow pure @safe @nogc {
        return _length;
    }

    /// Property for getting and setting the length of the array.
    @property size_t length() const nothrow pure @safe @nogc {
        return len;
    }

    /// ditto
    @property void length(size_t newLen) {
        assert (newLen <= N);
        static if (InitializeMembers) {
            while (_length > newLen) {
                destroy(data[_length-1]);
                _length--;
            }
        }

        _length = cast(L)newLen;
    }

    /// Returns a standard slice pointing at the array's data
    @property inout(T)[] array() inout nothrow pure @safe @nogc {
        return data[0 .. _length];
    }

    auto ref opOpAssign(string op: "~", U)(U val) nothrow @safe @nogc if (is(Unqual!U == T) || isAssignable!(T, U)) {
        ASSERT!"FixedArray is full. Capacity is %s"( _length < capacity, capacity );
        data[_length] = val;
        ++_length;
        return this;
    }

    // implicitly convert from range
    this(R)(R range) @safe if ((isInputRange!R)) {
        foreach(val; range) {
            ASSERT!"FixedArray is full. Capacity is %s"( _length < capacity, capacity );
            data[_length] = val;
            ++_length;
        }
    }

    ref FixedArray!(T, N, InitializeMembers) opOpAssign(string op: "~", R)(R range) nothrow @safe @nogc  if ((isInputRange!R)) {
        foreach(val; range) {
            ASSERT!"FixedArray is full. Capacity is %s"( _length < capacity, capacity );
            data[_length] = val;
            ++_length;
        }
        return this;
    }

    static if(is(T==char)) {
        /// Returns a standard slice pointing at the array's data
        @property string str() nothrow pure @nogc {
            return cast(immutable(T)[])(data[0 .. _length]);
        }

        auto ref nogcFormat(string fmt, T...)(T args) pure nothrow @nogc {
            import mecca.lib.string : nogcFormat;
            auto len =nogcFormat!(fmt)(data[length..N], args).length;
            _length+=len;
            return this;
        }
    }
    
    /// FixedArray is implicitly convertible to its underlying array
    alias array this;

    static if( isAssignable!(T, const(T)) ) {
        // If the type supports assignment from const(T) to T

        /// Set the FixedArray to whatever fits from the beginning of arr2
        void safeSetPrefix(const(T)[] arr2) {
            length = arr2.length <= N ? arr2.length : N;
            data[0 .. _length][] = arr2[0.._length][];
        }
        /// Set the FixedArray to whatever fits from the end of arr2
        void safeSetSuffix(const(T)[] arr2) {
            length = arr2.length <= N ? arr2.length : N;
            data[0 .. _length] = arr2[$ - _length .. $];
        }
    } else {
        // Only allow assignement from mutable types

        /// Set the FixedArray to whatever fits from the beginning of arr2
        void safeSetPrefix(T[] arr2) {
            length = arr2.length <= N ? arr2.length : N;
            data[0 .. _length][] = arr2[0.._length][];
        }
        /// Set the FixedArray to whatever fits from the end of arr2
        void safeSetSuffix(T[] arr2) {
            length = arr2.length <= N ? arr2.length : N;
            data[0 .. _length] = arr2[$ - _length .. $];
        }
    }
}

/// A nogc mutable char array (string)
alias FixedString(size_t N) = FixedArray!(char, N, false);

/// Shorten a null terminated `FixedString` to be the size of the actual string (without the null)
///
/// Will throw a RangeError if the string is not null terminated
void setStringzLength(size_t N)(ref FixedArray!(char, N, false) str) pure nothrow @safe @nogc {
    import std.string : indexOf;
    str.length = str.array.indexOf('\0');
}

auto ref fixedArray(size_t N, R)(R range) {
    FixedArray!(ElementType!R, N, false) result = range;
    return result;
}

unittest {
    auto a = [1,2,3].fixedArray!5;
    assert(a.length==3);
    assert(a.capacity==5);
    assert(a[0..3] == [1,2,3]);
}

unittest {
    FixedArray!(uint, 8) fa;
    assert (fa.length == 0);

    fa.length = 3;
    fa[0] = 8;
    fa[1] = 9;
    fa[2] = 10;
    assert (fa.length == 3);
}

unittest {
    // Make sure values are initialized
    FixedArray!(uint, 8) fa;

    fa.length = 4;
    assert (fa[2] == 0);
    fa[3] = 4;
    assert (fa[3] == 4);
    fa.length = 1;
    fa.length = 5;
    assert (fa[3] == 0);
}

unittest {
    // Make sure destructors are called
    static struct S {
        static uint count;
        uint value = 3;

        ~this() {
            count++;
        }
    }

    {
        FixedArray!(S, 5) fa;

        fa.length = 3;

        assert (S.count==0);

        assert(fa[2].value == 3);
        fa[2].value = 2;
        fa.length = 5;
        assert (S.count==0);
        assert(fa[2].value == 2);

        fa.length = 1;
        assert (S.count==4);
        fa.length = 3;
        assert (S.count==4);
        assert(fa[2].value == 3);
    }
}

unittest {
    FixedString!5 str;

    str.safeSetSuffix("123456789");
    assert(str[]=="56789");
    str.safeSetPrefix("123456789");
    assert(str[]=="12345");
}

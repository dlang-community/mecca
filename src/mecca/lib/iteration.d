/// Library for iterating over stuff
module mecca.lib.iteration;

import std.traits;
import std.range;

import mecca.lib.reflection;

/**
  Turn a Ref returning input range into a PTR one.

  This is useful for using ranges iterating `@disable this(this)` types with Phobos, that requires `front` to be
  copyable in order to recognize a range as an input range.
 */
auto ptrInputRange(Range)(Range range) if( isRefInputRange!Range ) {
    struct PtrRange {
        Range range;

        @property auto front() {
            return &range.front;
        }

        alias range this;
    }

    return PtrRange(range);
}

/// ditto
auto ptrInputRange(T)(T[] slice) {
    struct PtrRange {
        T[] slice;

        @property bool empty() pure const @safe @nogc {
            return slice.length == 0;
        }

        void popFront() @safe @nogc {
            slice = slice[1..$];
        }

        @property T* front() pure @safe @nogc {
            return &slice[0];
        }
    }

    return PtrRange(slice);
}

unittest {
    import std.algorithm : map, equal;

    struct Uncopyable {
        uint a;

        @disable this(this);
    }

    Uncopyable[5] arr;
    foreach(i; 0..5) {
        arr[i] = Uncopyable(i);
    }

    assert( equal( arr.ptrInputRange.map!"(*a).a*2", [0, 2, 4, 6, 8] ) );
}

auto derefRange(Range)(Range range) if( isInputRange!Range && is( isPointer!(elementType!Range) ) ) {
    struct DerefRange {
        Range range;

        @property ref auto front() {
            return *range.front;
        }

        alias range this;
    }

    return DerefRange(range);
}

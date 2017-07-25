module mecca.containers.arrays;

import std.traits;
import mecca.lib.reflection: CapacityType;
import mecca.lib.exception;

struct FixedArray(T, size_t N, bool InitializeMembers = true) {
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
    @property L capacity() const nothrow pure @nogc {
        return N;
    }

    @property L length() const nothrow pure @nogc {
        return _length;
    }

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

    @property T[] array() nothrow pure @nogc {
        return data[0 .. _length];
    }

    auto ref opOpAssign(string op: "~", U)(U val) nothrow @trusted @nogc if (is(Unqual!U == T) || isAssignable!(T, U)) {
        ASSERT!"FixedArray is full. Capacity is %s"( _length < capacity, capacity );
        data[_length] = val;
        ++_length;
        return this;
    }

    alias array this;

    void safeSetPrefix(const(T)[] arr2) {
        _length = cast(L)(arr2.length <= N ? arr2.length : N);
        data[0 .. _length] = cast(T[])arr2;
    }
    void safeSetSuffix(const(T)[] arr2) {
        _length = cast(L)(arr2.length <= N ? arr2.length : N);
        data[0 .. _length] = cast(T[])arr2[$ - _length .. $];
    }
}

alias FixedString(size_t N) = FixedArray!(char, N, false);

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
    struct S {
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

module mecca.containers.arrays;

import mecca.lib.reflection: CapacityType;

struct FixedArray(T, size_t N) {
    T[N] data;
    CapacityType!N _length;

    @property auto length() const nothrow pure @nogc {
        return _length;
    }
    @property void length(size_t newLen) nothrow pure @nogc {
        assert (newLen <= N);
        _length = cast(typeof(_length))newLen;
    }

    @property T[] array() nothrow pure @nogc {
        return data[0 .. _length];
    }

    alias array this;
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

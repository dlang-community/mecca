module mecca.containers.arrays;

struct FixedArray(T, size_t N) {
    T[N] data;
    size_t _length;

    @property T[] array() nothrow pure @nogc {
        return data[0 .. _length];
    }

    alias array this;
}

unittest {
    FixedArray!(uint, 8) fa;

    import std.stdio;
    writeln(fa.length);
}

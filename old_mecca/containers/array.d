module mecca.containers.array;

import mecca.lib.reflection;


struct FixedArray(T, size_t _capacity) {
    enum capacity = _capacity;
    CapacityType!capacity _length;
    T[capacity] _arr;

    @property auto length() const pure nothrow @nogc {
        return _length;
    }
    @property void length(CapacityType!capacity newLen) pure nothrow @nogc {
        assert (newLen <= capacity);
        _length = newLen;
    }

    @property T[] slice() pure nothrow @safe @nogc {
        return _arr[0 .. _length];
    }
    @property opOpAssign(string op: "~")(T elem) pure nothrow @safe @nogc {
        assert (length < capacity);
        _arr[_length++] = elem;
    }

    alias slice this;
}

alias FixedString(size_t capacity) = FixedArray!(char, capacity);

unittest {
    FixedArray!(ulong, 20) fa;
}

module mecca.lib.serialization;

import std.traits;
import std.meta;


void blitWrite(T)(ref ubyte[] stream, const ref T data) {
    static if (isDynamicArray!T) {
        stream[0 .. data.length] = cast(ubyte[])data;
        stream = stream[data.length .. $];
    }
    else {
        stream[0 .. T.sizeof] = *(cast(ubyte[T.sizeof]*)&data);
        stream = stream[T.sizeof .. $];
    }
}

bool isBlittable(U)() {
    alias T = Unqual!U;
    static if (is(typeof({T obj; obj.customDump(stream);}))) {
        return false;
    }
    else static if (is(T == class) || is(T == union) || is(T == interface) || isPointer!T || hasIndirections!T) {
        return false;
    }
    else static if (isScalarType!T) {
        return true;
    }
    else static if (is(T == S[N], S, size_t N)) {
        return isBlittable!S;
    }
    else static if (is(T == S[], S)) {
        return isBlittable!S;
    }
    else static if (is(T == struct)) {
        return Filter!(isBlittable, typeof(T.tupleof)).length == T.tupleof.length;
    }
    else {
        return false;
    }
}

void dump(S, T)(ref S stream, auto ref const T obj) {
    static if (is(typeof(obj.customDump(stream)))) {
        obj.customDump(stream);
    }
    else static if (isBlittable!T) {
        blitWrite(stream, obj);
    }
    else static if (isArray!T) {
        dump(stream, cast(uint)obj.length);
        foreach(ref item; obj) {
            dump(stream, item);
        }
    }
    else static if (is(T == struct)) {
        foreach(i, _; typeof(obj.tupleof)) {
            dump(stream, obj.tupleof[i]);
        }
    }
    else {
        static assert (false, "Cannot dump " ~ T.stringof);
    }
}


unittest {
    import std.stdio;

    ubyte[100] buf;
    ubyte[] stream = buf;

    struct S {
        int x;
        long y;
        string z;
    }
    static assert (!isBlittable!S);

    S[2] ss = [S(10, 20), S(11, 22, "world")];
    dump(stream, ss);
    writeln(buf[0 .. (stream.ptr - buf.ptr)]);

}

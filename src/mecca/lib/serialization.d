module mecca.lib.serialization;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits;
import std.meta;

alias LengthType = uint;

template ArrayElement(T) {
    static if (isStaticArray!T && is(T == E[N], E, size_t N)) {
        alias ArrayElement = E;
    }
    else static if (isDynamicArray!T && is(T == E[], E)) {
        alias ArrayElement = E;
    }
    else {
        static assert (false, T.stringof ~ " is not an array");
    }
}

template isBlittable(U) {
    alias T = U; //Unqual!U;
    static if (__traits(hasMember, T, "customDump")) {
        enum isBlittable = false;
    }
    else static if (is(T == struct) || is(T == union)) {
        static if (isNested!T) {
            enum isBlittable = false;
        }
        else {
            enum isBlittable = allSatisfy!(.isBlittable, typeof(T.tupleof));
        }
    }
    else static if (isStaticArray!T) {
        alias E = ArrayElement!T;
        enum isBlittable = is(E == void) || isBlittable!E;
    }
    else static if (staticIndexOf!(T, bool, char, wchar, dchar, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, real) >= 0) {
        enum isBlittable = true;
    }
    else {
        enum isBlittable = false;
    }
}

template isTopLevelBlittable(T) {
    static if (isBlittable!T) {
        enum isTopLevelBlittable = true;
    }
    else static if (isDynamicArray!T) {
        enum isTopLevelBlittable = isBlittable!(ArrayElement!T);
    }
    else {
        enum isTopLevelBlittable = false;
    }
}

size_t calcSizeOf(T)(auto ref const T obj) {
    static if (__traits(hasMember, T, "customDump")) {
        obj.customCalcSize();
    }
    else static if (isArray!T) {
        size_t s;
        static if (isDynamicArray!T) {
            assert (obj.length < LengthType.max);
            s = LengthType.sizeof;
        }
        static if (isBlittable!(ArrayElement!T)) {
            s += ArrayElement!T.sizeof * obj.length;
        }
        else {
            foreach(const ref item; obj) {
                s += calcSizeOf(item);
            }
        }
        return s;
    }
    else static if (isAssociativeArray!T) {
        size_t s = LengthType.sizeof;
        foreach(k, ref v; obj) {
            s += calcSizeOf(k) + calcSizeOf(v);
        }
        return s;
    }
    else static if (isBlittable!T) {
        return T.sizeof;
    }
    else static if (is(T == struct)) {
        // we know the struct is not blittable
        size_t s;
        foreach(i, _; typeof(T.tupleof)) {
            s += calcSizeOf(obj.tupleof[i]);
        }
        return s;
    }
    else {
        static assert (false, "Cannot dump " ~ T.stringof);
    }
}

void blitWrite(S, T)(ref S stream, ref const T data) {
    static assert (isTopLevelBlittable!T);
    static if (isDynamicArray!T) {
        static if (is(S == ubyte[])) {
            stream[0 .. data.length] = data;
            stream = stream[data.length .. $];
        }
        else {
            stream.write(data);
        }
    }
    else {
        static if (is(S == ubyte[])) {
            *(cast(T*)stream.ptr) = data;
            stream = stream[T.sizeof .. $];
        }
        else {
            stream.write((cast(const(ubyte)*)&data)[0 .. T.sizeof]);
        }
    }
}

void blitRead(S, T)(ref S stream, auto ref T data) {
    static assert (isTopLevelBlittable!T);
    static if (isDynamicArray!T) {
        static if (is(S == ubyte[])) {
            data[] = stream[0 .. data.length];
            stream = stream[data.length .. $];
        }
        else {
            stream.read(data);
        }
    }
    else {
        static if (is(S == ubyte[])) {
            data = *(cast(T*)stream.ptr);
            stream = stream[T.sizeof .. $];
        }
        else {
            stream.write((cast(const(ubyte)*)&data)[0 .. T.sizeof]);
        }
    }
}

void dump(S, T)(ref S stream, auto ref const T obj) {
    static if (__traits(hasMember, T, "customDump")) {
        obj.customDump(stream);
    }
    else static if (isArray!T) {
        static if (isDynamicArray!T) {
            assert (obj.length < LengthType.max);
            dump(stream, cast(LengthType)obj.length);
        }
        static if (isBlittable!(ArrayElement!T)) {
            blitWrite(stream, cast(ubyte[])obj);
        }
        else {
            foreach(const ref item; obj) {
                dump(stream, item);
            }
        }
    }
    else static if (isAssociativeArray!T) {
        assert (obj.length < LengthType.max);
        dump(stream, cast(LengthType)obj.length);
        foreach(k, ref v; obj) {
            dump(stream, k);
            dump(stream, v);
        }
    }
    else static if (isBlittable!T) {
        blitWrite(stream, obj);
    }
    else static if (is(T == struct)) {
        // we know the struct is not blittable
        foreach(i, _; typeof(T.tupleof)) {
            dump(stream, obj.tupleof[i]);
        }
    }
    else {
        static assert (false, "Cannot dump " ~ T.stringof);
    }
}

ubyte[] dump(T)(auto ref const T obj) {
    ubyte[] buf = new ubyte[calcSizeOf(obj)];
    ubyte[] stream = buf;
    dump(stream, obj);
    assert (stream.length == 0);
    return buf;
}

void load(S, T)(ref S stream, ref T obj) {
    static if (__traits(hasMember, T, "customDump")) {
        obj.customLoad(stream);
    }
    else static if (isArray!T) {
        alias E = ArrayElement!T;
        static if (isDynamicArray!T) {
            LengthType len;
            load(stream, len);
            obj.length = len;
        }
        static if (isBlittable!E) {
            blitRead(stream, cast(ubyte[])obj);
        }
        else static if (is(E == immutable(char)) || is(E == immutable(wchar)) || is(E == immutable(dchar))) {
            blitRead(stream, cast(ubyte[])obj);
        }
        else {
            foreach(ref item; obj) {
                load(stream, item);
            }
        }
    }
    else static if (isAssociativeArray!T) {
        LengthType len;
        load(stream, len);
        obj.clear();
        foreach(_; 0 .. len) {
            KeyType!k;
            ValueType!v;
            load(stream, k);
            load(stream, v);
            obj[k] = v;
        }
    }
    else static if (isBlittable!T) {
        blitRead(stream, obj);
    }
    else static if (is(T == struct)) {
        // we know the struct is not blittable
        foreach(i, _; typeof(T.tupleof)) {
            load(stream, obj.tupleof[i]);
        }
    }
    else {
        static assert (false, "Cannot dump " ~ T.stringof);
    }
}

T load(T, S)(ref S stream) {
    Unqual!T tmp;
    load(stream, tmp);
    return tmp;
}


unittest {
    import std.stdio;
    import std.string;

    static void loadDumped(T)(T val) {
        ubyte[] binary = dump(val);
        ubyte[] stream = binary;
        T val2;
        load(stream, val2);
        //writefln("Dumped %s as %s, loaded %s", val, binary, val2);
        assert (stream.length == 0);
        assert (val == val2, "Dumped %s as %s, loaded as %s".format(val, binary, val2));
    }

    loadDumped("hello");
    loadDumped(16.25);
    struct S {float x; uint y;}
    loadDumped(S(16.25, 88));
    struct S2 {float x; uint y; string foo;}
    loadDumped(S2(16.25, 88, "hello"));
}




module mecca.containers.stringpool;
import mecca.lib.memory;
import std.algorithm.searching;

class StringPool
{
    MmapArray!char buf;
    char[] range;

    this(size_t capacity) {
        buf.allocate(capacity);
        range = buf[0..0];
    }

    string intern(string value){
        auto found = find(range, value);
        if(found.length>0)
            return cast(string)found[0..value.length];
        range = buf[0..range.length+value.length+1];
        auto interned = range[range.length-value.length-1..$-1];
        interned[] = value[];
        range[range.length-1] = 0; // returned string.ptr is asciiz
        return cast(string)interned;
    }
}
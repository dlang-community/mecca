module mecca.containers.stringtable;
import mecca.lib.memory;
import mecca.containers.tables;

struct StringTable(ushort capacity=128) {
    MmapArray!char buffer_;
    SmallTable!(char[], char[], capacity) table_;
    char[] range_;
    alias table_ this;

    this(size_t maxSize) {
        buffer_.allocate(maxSize);
        range_ = buffer_[0..$];
    }

    char[] opIndexAssign(char[] value, char[] key) {
        range_[0..key.length] = key;
        range_[key.length..key.length+value.length] = value;
        key = range_[0..key.length];
        value = range_[key.length..key.length+value.length];
        range_ = range_[key.length+value.length..$];
        table_[key] = value;
        return value;
    }
}
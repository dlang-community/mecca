module mecca.containers.tables;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.traits: isArray;
import mecca.lib.exception;


class TableFull: Error {mixin ExceptionBody;}


///////////////////////////////////////////////////////////////////////////////////////////////////
//
// HashTable: a Robin hash-table.
//            Must support the value being `void` where it essentially becomes a set
//            choose best implementation (robin/etc) based on key/value size?
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct HashTable(K, V) {
}

///////////////////////////////////////////////////////////////////////////////////////////////////
//
// FixedTable: a HashTable (as above) initialized over a static array
//             can be dumped to file; must hold indexes instead of pointers
//             (replaces StaticHashTable)
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct FixedTable(K, V, size_t N) {
}

///////////////////////////////////////////////////////////////////////////////////////////////////
//
// SmallTable: an array with table-like accessors. Useful for small tables that fit in a (few)
//             cache lines, where a simple O(N) scan is good enough
//
///////////////////////////////////////////////////////////////////////////////////////////////////
struct SmallTable(K, V, ushort capacity_) {
    enum capacity = capacity_;

private:
    ushort _length;
    K[capacity] keys;
    static if (!is(V == void)) {
        V[capacity] values;
    }

    int lookup(K k) const {
        foreach(ushort i; 0 .. _length) {
            if (keys[i] == k) {
                return i;
            }
        }
        return -1;
    }

    int create(K k) {
        auto v = lookup(k);
        if (v >= 0) {
            return v;
        }
        return doCreate(k);
    }

    int doCreate(K k) {
        enforceFmt!TableFull(_length < capacity, typeof(this).stringof ~ " is full");
        auto tmp = _length;
        _length++;
        keys[tmp] = k;
        static if (!is(V == void)) {
            values[tmp] = V.init;
        }
        return tmp;
    }

public:
    @property auto length() pure const @safe nothrow {
        return _length;
    }
    @property bool empty() pure const @safe nothrow {
        return _length == 0;
    }
    @property bool full() pure const @safe nothrow {
        return _length == capacity;
    }

    static if (!is(V == void)) {
        ref inout(V) opIndex(K k) inout {
            auto idx = lookup(k);
            if (idx < 0) {
                throw rangeError(k);
            }
            else {
                return values[idx];
            }
        }
        ref V opIndexAssign(V v, K k) {
            auto idx = create(k);
            values[idx] = v;
            return values[idx];
        }
        void opIndexUnary(string op)(K k) {
            mixin(`values[create(k)]` ~ op ~ `;`);
        }
        inout(V)* opBinaryRight(string op: "in")(K k) inout {
            int idx = lookup(k);
            return (idx < 0) ? null : &values[idx];
        }
        //ref inout(V) get(K k, ref inout(V) defaultValue) inout {
        //    int idx = lookup(k);
        //    return (idx < 0) ? defaultValue : values[idx];
        //}
        V* getOrCreate(K k) {
            return &values[doCreate(k)];
        }

        ref V getOrAdd(K k, out bool found) {
            int index = lookup(k);
            if(index<0) {
                found = false;
                index = doCreate(k);
                return values[index];
            }else {
                found = true;
                return values[index];
            }
        }

        ref V getOrAdd(K k) {
            int index = create(k);
            return values[index];
        }

        @property inout(K)[] byKey() inout {
            return keys[0 .. _length];
        }
        @property inout(V)[] byValue() inout {
            return values[0 .. _length];
        }
        int opApply(scope int delegate(K, ref V) dg) {
            foreach(i; 0 .. _length) {
                auto res = dg(keys[i], values[i]);
                if (res) {
                    return res;
                }
            }
            return 0;
        }
        int opApply(scope int delegate(K, ref const V) dg) const {
            return (cast()this).opApply(dg);
        }
    }
    else {
        void add(K k) {
            create(k);
        }
        ref SmallTable extend(K[] ks) {
            foreach(k; ks) {
                create(k);
            }
            return this;
        }
        ref SmallTable extend(R)(R ks) {
            foreach(k; ks) {
                create(k);
            }
            return this;
        }

        bool opBinaryRight(string op: "in")(K k) const {
            return (lookup(k) >= 0);
        }

        @property inout(K)[] array() inout {
            return keys[0 .. _length];
        }

        int opApply(scope int delegate(K k) dg) const {
            foreach(k; keys[0 .. _length]) {
                auto res = dg(k);
                if (res) {
                    return res;
                }
            }
            return 0;
        }

        K pop() {
            assert (!empty, "popping from empty set");
            auto k = keys[0];
            remove(k);
            return k;
        }

        /// new set with elements in this but not in rhs
        SmallSet opBinary(string op: "-")(SmallSet rhs) const {
            SmallSet ret;
            foreach(item; items) {
                if (item !in rhs) {
                    ret.add(item);
                }
            }
            return ret;
        }

        /// new set with elements common to this and rhs
        SmallSet opBinary(string op: "&")(SmallSet rhs) const {
            SmallSet ret;
            foreach(item; items) {
                if (item in rhs) {
                    ret.add(item);
                }
            }
            return ret;
        }

        /// new set with elements from both this and rhs
        SmallSet opBinary(string op: "|")(SmallSet rhs) const {
            SmallSet ret;
            foreach(item; items.chain(rhs.items)) {
                ret.add(item);
            }
            return ret;
        }
    }

    bool remove(K k) {
        auto idx = lookup(k);
        if (idx < 0) {
            return false;
        }
        _length--;
        keys[idx] = keys[length];
        static if (!is(V == void)) {
            values[idx] = values[length];
        }
        return true;
    }
    void removeAll() {
        _length = 0;
    }

    bool opEquals()(const ref SmallTable rhs) const {
        if (_length != rhs._length) {
            return false;
        }
        static if (is(V == void)) {
            foreach(k; array) {
                if (k !in rhs) {
                    return false;
                }
            }
        }
        else {
            foreach(k, const ref v; this) {
                auto rhsV = k in rhs;
                if ((rhsV is null) || (v != *rhsV)) {
                    return false;
                }
            }
        }
        return true;
    }
}

unittest {
    SmallTable!(uint, uint, 10) tbl;

    foreach(i; 0 .. 4) {
        assert (tbl.empty);

        tbl[6] = 19;
        tbl[7] = 20;
        tbl[8] = 21;
        tbl[9] = 22;
        tbl[10] = 23;
        tbl[11] = 24;

        assert (!tbl.empty);
        assert (!tbl.full);
        assert (tbl.length == 6);
        assert (tbl[6] == 19);
        assert (tbl[9] == 22);
        assert (tbl[11] == 24);
        assert (6 in tbl);
        assert (12 !in tbl);
        assert (5 !in tbl);

        assert (tbl.remove(7));
        assert (7 !in tbl);

        auto sum = 0;
        foreach(k, ref v; tbl) {
            sum += v;
        }
        assert (sum == 19+/*20+*/21+22+23+24);

        assert (tbl.length == 5);
        tbl[12] = 25;
        tbl[13] = 26;
        tbl[14] = 27;
        tbl[15] = 28;
        assert (tbl.length == 9);
        assert (!tbl.full);

        tbl[16] = 29;
        assert (tbl.length == 10);
        assert (tbl.full);

        assert (tbl.remove(16));
        assert (tbl.remove(15));
        assert (tbl.remove(6));
        assert (!tbl.remove(7));
        assert (tbl.remove(12));

        assert (6 !in tbl);
        assert (7 !in tbl);
        assert (12 !in tbl);
        assert (19 !in tbl);
        assert (20 !in tbl);

        assert (tbl.length == 6);
        assert (!tbl.full);

        sum = 0;
        foreach(k, ref v; tbl) {
            sum += v;
        }
        assert (sum == /*19+20+*/21+22+23+24+/*25+*/26+27/*+28+29*/);

        if (i % 2 == 0) {
            assert(tbl.remove(8));
            assert(tbl.remove(9));
            assert(tbl.remove(10));
            assert(tbl.remove(11));
            assert(tbl.remove(13));
            assert(tbl.remove(14));
        }
        else {
            tbl.removeAll();
        }
    }
}

alias SmallSet(K, ushort capacity) = SmallTable!(K, void, capacity);

auto smallSet(uint capacity, T)(T[] items...) {
    return SmallSet!(T, capacity)().extend(items);
}

auto smallSet(uint capacity, R)(R items) if (!isArray!R) {
    import std.range;
    return SmallSet!(Unqual!(ElementType!R), capacity)().extend(items);
}

unittest {
    SmallSet!(uint, 10) set;

    set.add(7);
    set.add(8);
    set.add(9);
    set.add(10);
    set.add(11);
    set.add(12);
    set.add(13);
    set.add(14);
    set.add(15);
    set.add(15);
    set.add(15);
    set.add(15);
    assert(!set.full);
    set.add(16);
    assert(set.length == 10);
    assert(set.full);
    assert(12 in set);
    assert(17 !in set);
    set.remove(12);
    assert(12 !in set);
    assert(set.length == 9);
}

// test opEquals()
unittest {
    auto s1 = smallSet!5([1,2,3]);
    auto s2 = smallSet!5([3,1]);
    assert(s1 != s2);
    s2.add(2);
    assert(s1 == s2);
    s2.add(4);
    assert(s1 != s2);
    s2.removeAll();
    assert(s1 != s2);
}

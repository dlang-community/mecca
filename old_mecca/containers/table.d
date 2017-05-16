module mecca.containers.table;

import std.traits;
import std.string;
import std.exception;

import mecca.lib.reflection;
import mecca.lib.exception;
import mecca.lib.memory;


@("notrace") void traceDisableCompileTimeInstrumentation();

class TableFull: Error {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

ulong quickHash(ulong x) {
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9UL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebUL;
    x = x ^ (x >> 31);
    return x;
}

struct FixedTable(K, V, uint N, uint B = 0, alias H) {
    enum capacity = N;
    static if (B == 0) {
        import std.math: ilogb;
        enum numBuckets = (N & (N - 1)) == 0 ? 2 * N : 1 << (ilogb(cast(uint)(2*N)) + 1);
    }
    else {
        enum numBuckets = B;
    }
    alias Index = CapacityType!(N+1);
    enum invalid = cast(Index)-1;
    static assert (capacity < invalid);

    static if (hasIndirections!K || hasIndirections!V) {
        struct KVI {
            K k = void;
            Index next = void;
            V v = void;
        }
    }
    else {
        align(1) struct KVI {
        align(1):
            K k = void;
            Index next = void;
            V v = void;
        }
    }

    bool _inited;
    uint _iterating;
    Index _length;
    Index freeHead;
    version(unittest) {
        size_t numCollisions;
        size_t numLookups;
    }
    Index[numBuckets] buckets;
    KVI[N] kvis;

    void removeAll() {
        buckets[] = invalid;
        foreach(i, ref kvi; kvis[0 .. $-1]) {
            kvi.next = cast(Index)(i+1);
        }
        kvis[$-1].next = invalid;
        freeHead = 0;
        _length = 0;
        _iterating = 0;
        _inited = true;
    }

    alias open = removeAll;

    private Index lookup(K k, out Index bktIndex, out Index parent) const {
        assert (_inited);

        auto h = H(k);
        Index idx = buckets[h % numBuckets];
        bktIndex = h % numBuckets;
        parent = invalid;

        while (idx != invalid) {
            if (kvis[idx].k == k) {
                version(unittest) (cast()this).numLookups++;
                return idx;
            }
            parent = idx;
            idx = kvis[idx].next;
            version(unittest) (cast()this).numCollisions++;
        }

        return invalid;
    }

    private V* _create(bool forceCreation=false)(K k) {
        Index bktIndex, parent;
        auto idx = lookup(k, bktIndex, parent);
        if (idx != invalid) {
            static if (forceCreation) {
                throw rangeError(k, "already exists");
            }
            else {
                return &kvis[idx].v;
            }
        }

        enforceEx!TableFull(_length < capacity);
        assert (freeHead != invalid);
        idx = freeHead;
        freeHead = kvis[freeHead].next;
        _length++;
        if (parent == invalid) {
            buckets[bktIndex] = idx;
        }
        else {
            kvis[parent].next = idx;
        }
        kvis[idx].next = invalid;
        kvis[idx].k = k;
        setInitTo(kvis[idx].v);
        version(unittest) numLookups++;
        return &kvis[idx].v;
    }

    inout(V)* opBinaryRight(string op: "in")(K k) inout {
        if (empty) {
            return null;
        }
        Index bktIndex, parent;
        auto idx = lookup(k, bktIndex, parent);
        return (idx == invalid) ? null : &kvis[idx].v;
    }

    ref inout(V) opIndex(K k) inout {
        if (auto pv = k in this) {
            return *pv;
        }
        else {
            throw rangeError(k);
        }
    }

    @property auto inited() const pure @safe nothrow @nogc {
        return _inited;
    }
    @property auto length() const pure @safe nothrow @nogc {
        assert (_inited);
        return _length;
    }
    @property bool empty() const pure @safe nothrow @nogc {
        assert (_inited);
        return _length == 0;
    }
    @property bool full() const pure @safe nothrow @nogc {
        assert (_inited);
        return _length == capacity;
    }

    V* create(K k) {
        return _create!true(k);
    }
    V* getOrCreate(K k) {
        return _create!false(k);
    }
    ref V opIndexAssign(V v, K k) {
        V* p = _create!false(k);
        *p = v;
        return *p;
    }
    ref V opIndexUnary(string op)(K k) {
        V* p = _create!false(k);
        mixin(`(*p)` ~ op ~ `;`);
        return *p;
    }

    static struct Range(bool isConst, string mode) {
        static if (isConst) {
            const(FixedTable)* table;
        }
        else {
            FixedTable* table;
        }
        uint bktIndex;
        uint index;

        static if (isConst) {
            this(const(FixedTable)* table) {
                this(cast(FixedTable*)table);
            }
        }
        this(FixedTable* table) {
            assert (table._inited);
            this.table = table;
            bktIndex = 0;
            index = invalid;
            (cast(FixedTable*)table)._iterating++;
            if (!table.empty) {
                for (; index == invalid && bktIndex < numBuckets; bktIndex++) {
                    index = table.buckets[bktIndex];
                }
            }
        }
        this(this) {
            assert (table._iterating > 0);
            (cast(FixedTable*)table)._iterating++;
        }
        ~this() {
            assert (table._iterating > 0);
            (cast(FixedTable*)table)._iterating--;
        }

        @property bool empty() const {
            return index == invalid;
        }
        @property auto front() {
            assert (index != invalid);
            static if (mode == "k") {
                return table.kvis[index].k;
            }
            else static if (mode == "v") {
                return &table.kvis[index].v;
            }
            else static if (mode == "kv") {
                static struct KV {
                    K k;
                    static if (isConst) {
                        const(V)* v;
                    }
                    else {
                        V* v;
                    }
                }
                return KV(table.kvis[index].k, &table.kvis[index].v);
            }
            else {
                static assert (false, mode);
            }
        }
        void popFront() {
            assert (index != invalid);
            index = table.kvis[index].next;
            for (; index == invalid && bktIndex < numBuckets; bktIndex++) {
                index = table.buckets[bktIndex];
            }
            if (index != invalid) {
                prefetch_read(&table.kvis[index]);
            }
        }
    }

    @property auto byItem() {
        return Range!(false, "kv")(&this);
    }
    @property auto byItem() const {
        return Range!(true, "kv")(&this);
    }

    @property auto byKey() {
        return Range!(false, "k")(&this);
    }
    @property auto byKey() const {
        return Range!(true, "k")(&this);
    }

    @property auto byValue() {
        return Range!(false, "v")(&this);
    }
    @property auto byValue() const {
        return Range!(true, "v")(&this);
    }

    int opApply(scope int delegate(K, ref V) dg) {
        int res;
        foreach(kv; byItem) {
            res = dg(kv.k, *kv.v);
            if (res) {
                break;
            }
        }
        return res;
    }

    int opApply(scope int delegate(K, ref const V) dg) const {
        return (cast()this).opApply(dg);
    }

    bool popItem(out K k, out V v) {
        if (empty) {
            return false;
        }
        /* scope */{
            auto r = byItem();
            assert (!r.empty);
            auto kv = r.front;
            k = kv.k;
            v = *kv.v;
        }
        remove(k);
        return true;
    }

    bool remove(K k) {
        assert (_iterating == 0, "Cannot remove while iterating");
        Index bkt, parent;
        auto idx = lookup(k, bkt, parent);
        if (idx == invalid) {
            return false;
        }
        if (parent == invalid) {
            buckets[bkt] = kvis[idx].next;
        }
        else {
            kvis[parent].next = kvis[idx].next;
        }
        kvis[idx].next = freeHead;
        freeHead = idx;
        _length--;
        return true;
    }

    version(unittest) {
        void showStats() {
            import std.stdio;
            uint usedBuckets = 0;
            uint[10] histogram;
            foreach(b; 0 .. numBuckets) {
                auto p = buckets[b];
                if (p == invalid) {
                    histogram[0]++;
                    continue;
                }
                usedBuckets++;
                uint chain;
                while(p != invalid) {
                    chain++;
                    p = kvis[p].next;
                }
                if (chain >= histogram.length) {
                    chain = histogram.length-1;
                }
                histogram[chain]++;
            }

            writefln("entries=%s/%s usedBuckets=%s/%s avgChain=%.2f collisions=%s lookups=%s\n%s",
                length, capacity, usedBuckets, numBuckets, float(length) / usedBuckets, numCollisions, numLookups,
                histogram);
        }
    }
}


unittest {
    import std.stdio;
    import std.random;
    Random rnd;
    rnd.seed(1337);

    static ulong id(ulong x) {return x;}

    FixedTable!(uint, uint, 20_000, 65536, id) table;
    table.open();

    foreach(i; 0 .. table.capacity * 10) {
        auto which = uniform(0, 10, rnd);
        if (which < 5) {
            auto k = uniform(0, uint.max, rnd);
            auto res = k in table;
        }
        else if (which < 8 && !table.full) {
            auto k = uniform(0, uint.max, rnd);
            table[k] = 7;
        }
        else {
            uint k, v;
            table.popItem(k, v);
        }
    }

    table.showStats();

    int count;
    foreach(k, ref v; table) {
        v++;
        count++;
    }
}


// just an array, useful for small "hash" tables (cache-line friendly)
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
        enforceEx!TableFull(_length < capacity, format("Table is full. length %s capacity %s", _length, capacity));
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
            return &values[create(k)];
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

    /+string toString() const {
        static if (is(V == void)) {
            return "%s".format(array);
        }
        else {
            string s = "[";
            foreach(k, v; this) {
                s ~= "%s: %s, ".format(k, v);
            }
            return s ~ "]";
        }
    }+/

    //JSONValue toJSON()() const {
    //    auto jv = JSONValue(string[string].init);
    //    foreach(k, ref v; this) {
    //        jv[objToJSONKey(k)] = objToJSON(v);
    //    }
    //    return jv;
    //}
    //void fromJSON()(JSONValue jv) {
    //    removeAll();
    //    foreach(kj, vj; jv.object) {
    //        this[jsonToObj!K(JSONValue(kj))] = jsonToObj!V(vj);
    //    }
    //}
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


module mecca.lib.iterartion;

import std.traits;


enum isIterator(T) = is(ReturnType!(T.next) == bool) && Parameters!(T.next).length == 1 && ParameterStorageClassTuple!(T.next)[0] == ParameterStorageClass.out_;
template IteratorElement(T) if (isIterator!T) {
    alias IteratorElement = Parameters!(T.next)[0];
}

version (unittest) {
    struct Counter {
        size_t start, stop;

        bool next(out size_t res) {
            if (start >= stop) {
                return false;
            }
            res = start++;
            return true;
        }
    }

    static assert (isIterator!Counter);
    static assert (is(IteratorElement!Counter == size_t));
}

@("notrace") auto iterartorToRange(T)(bool delegate(out T) iterDlg) {
    static struct Range {
        bool delegate(out T) iterDlg;
        T front;
        bool empty;

        this(bool delegate(out T) iterDlg) {
            this.iterDlg = iterDlg;
            popFront();
        }
        void popFront() {
            empty = !iterDlg(front);
        }
    }
    return Range(iterDlg);
}

@("notrace") auto iterartorToRange(T)(ref T iterObj) if (is(typeof(iterObj.next))) {
    return iterartorToRange(&iterObj.next);
}

unittest {
    import std.algorithm: sum;

    auto counter = Counter(10, 20);
    assert (counter.iterartorToRange.sum() == (10 + 19) * 10 / 2);
}

@("notrace") auto iMap(alias F, I)(I iter) if (isIterator!I) {
    static struct Map {
        I iter;
        bool next(out ReturnType!F res) {
            IteratorElement!I tmp;
            if (!iter.next(tmp)) {
                return false;
            }
            res = F(tmp);
            return true;
        }
    }
    return Map(iter);
}

unittest {
    import std.algorithm: sum;

    auto itr = Counter(10, 20).iMap!((size_t x) => x * 2);
    assert(sum(itr.iterartorToRange) == (20 + 38) * 10 / 2);
}

@("notrace") auto iFilter(alias F, I)(I iter) if (isIterator!I) {
    static struct Filter {
        I iter;
        bool next(out IteratorElement!I res) {
            while (iter.next(res)) {
                if (F(res)) {
                    return true;
                }
            }
            return false;
        }
    }
    return Filter(iter);
}

unittest {
    import std.array;
    auto itr = Counter(10, 20).iFilter!(x => x % 3 == 0);
    assert (itr.iterartorToRange.array == [12, 15, 18]);
}

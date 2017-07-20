module mecca.node.services;


__gshared void function()[][string] perServiceInitFuncs;

template ServiceGlobal(string svc, T, string mod=__MODULE__, size_t line=__LINE__) {
    __gshared T* obj = null;
    shared static this() {
        perServiceInitFuncs[svc] ~= () {
            assert (obj is null);
            import std.traits: isStaticArray;
            static if (isStaticArray!T) {
                struct S {
                    T data;
                }
                obj = &(new S).data;
            }
            else {
                obj = new T;
            }
        };
    }
    @property ref T ServiceGlobal() @trusted nothrow @nogc {
        assert (obj !is null);
        return *obj;
    }
}

version (unittest) {
    private:
    alias utLong = ServiceGlobal!("UT", long);
    alias utBiggy = ServiceGlobal!("UT", long[10000]);

    unittest {
        foreach(fn; perServiceInitFuncs["UT"]) {
            fn();
        }

        assert (utLong == 0);
        utLong = 17;
        assert (utLong == 17);
        assert (utBiggy[1888] == 0);
        utBiggy[1888] = 9999;
        assert (utBiggy[1888] == 9999);
    }
}




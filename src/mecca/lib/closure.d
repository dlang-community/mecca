module mecca.lib.closure;

struct _Closure(size_t ARGS_SIZE) {
    private void function(void*) wrapper;
    union {
        private void* _funcptr;
        private void[ARGS_SIZE + _funcptr.sizeof] argsBuf;
    }

    @property const(void*) funcptr() const pure nothrow @trusted @nogc {
        return _funcptr;
    }
    @property bool isSet() const pure nothrow @trusted @nogc {
        return _funcptr !is null;
    }
    bool opCast(T: bool)() const pure nothrow @safe @nogc {
        return isSet();
    }

    private void _set(T...)(void* fn, T args) @nogc {
        import std.string: format;
        static struct Typed {
            void function(T) fn;
            T args;
            static void call(void* self) {
                (cast(Typed*)self).fn((cast(Typed*)self).args);
            }
        }
        static assert (Typed.sizeof <= argsBuf.length, "args require %s bytes, %s available".format(
                Typed.sizeof - (void*).sizeof, argsBuf.length - (void*).sizeof));

        Typed* typed = cast(Typed*)argsBuf.ptr;
        typed.fn = cast(void function(T))fn;
        typed.args = args;
        (cast(ubyte[])argsBuf[Typed.sizeof .. $])[] = 0;   // don't leave dangling pointers
        wrapper = &Typed.call;
    }

    void clear() {
        _set(null);
    }
    void set(T...)(void function(T) fn, T args) {
        _set(fn, args);
    }
    void set(T...)(void delegate(T) dg, T args) {
        _set(dg.funcptr, args, dg.ptr);
    }

    ref typeof(this) opAssign(typeof(null) fn) {clear(); return this;}
    ref typeof(this) opAssign(void function() fn) {set(fn); return this;}
    ref typeof(this) opAssign(void delegate() dg) {set(dg); return this;}

    void opCall() {
        pragma(inline, true);
        wrapper(argsBuf.ptr);
    }
}

alias Closure = _Closure!64;


unittest {
    static long sum;

    static void f(int x) {
        sum += 1000 * x;
    }

    struct S {
        int z;
        void g(int x, int y) {
            sum += 1_000_000 * x + y * 100 + z;
        }
    }

    Closure c;
    assert (!c);

    c.set(&f, 5);
    assert (c);

    c();
    assert (c.funcptr == &f);
    assert (sum == 5_000);

    S s;
    s.z = 99;
    c.set(&s.g, 8, 18);
    c();
    assert (c.funcptr == (&s.g).funcptr);
    assert (sum == 5_000 + 8_000_000 + 1_800 + 99);

    c = null;
    //c();
    assert (!c);

    import std.functional: toDelegate;

    sum = 0;
    c.set(toDelegate(&f), 50);
    c();
    assert (sum == 50_000);
}



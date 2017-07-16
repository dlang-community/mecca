module mecca.lib.lowlevel;

version(linux):
version(X86_64):

private enum NR_gettid = 186;

extern(C) nothrow @system @nogc {
    int syscall(int number, ...);

    int gettid() {
        return syscall(NR_gettid);
    }
}

unittest {
    import core.thread: thread_isMainThread;
    import core.sys.posix.unistd: getpid;
    assert (thread_isMainThread());
    assert (gettid() == getpid());
}

/+version(LDC) {
    private pure pragma(LDC_intrinsic, "llvm.x86.sse42.crc32.64.64") ulong crc32(ulong crc, ulong v) nothrow @safe @nogc;
}

uint crc32c(ulong crc, ulong v) @nogc nothrow @system {
    if (__ctfe) {
        return 0;
    } else {
        version(LDC) {
            return cast(uint)crc32(crc, v);
        } else {
            return 0;
        }
    }
}

unittest {
    ulong crc = 0x000011115555AAAA;
    ulong v = 0x88889999EEEE3333;

    assert(crc32c(crc, v) == 0x16f57621);
    v = 0x00000000EEEE3333;
    assert(crc32c(crc, v) == 0x8e5d3bf9);
}
+/


mixin template hookSyscall(alias F, int nr, alias preFunc) {
    import std.traits: Parameters;
    enum name = __traits(identifier, F);
    mixin("extern(C) pragma(mangle, \"" ~ name ~ "\") @system int " ~ name ~ "(Parameters!F args) {
            preFunc(args);
            return syscall(nr, args);
        }"
    );
}

version (unittest) {
    __gshared bool hitPreFunc = false;

    static import core.sys.posix.unistd;
    mixin hookSyscall!(core.sys.posix.unistd.close, 3, (int fd){hitPreFunc = true;});

    unittest {
        import std.stdio;
        auto f = File("/tmp/test", "w");
        f.close();
        assert (hitPreFunc);
    }
}





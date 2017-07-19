module mecca.platform.x86;


version(LDC) {
    public import ldc.intrinsics: readTSC = llvm_readcyclecounter;
}
else version (D_InlineAsm_X86_64) {
    ulong readTSC() nothrow @nogc @trusted {
        asm nothrow @nogc @trusted {
            naked;
            rdtsc;         // EDX(hi):EAX(lo)
            shl RDX, 32;
            or RAX, RDX;   // RAX |= (RDX << 32)
            ret;
        }
    }
}
else {
    static assert (false, "RDTSC not supported on platform");
}

unittest {
    assert (readTSC() != 0);
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



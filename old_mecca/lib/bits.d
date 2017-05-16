module mecca.lib.bits;

import core.atomic;

@("notrace") void atomicBitSet(ulong* p /* RSI */, ushort bitnum /* DI */) {
    version(LDC) {
        pragma(LDC_allow_inline);
    }
    asm pure nothrow @nogc {
        naked;
        lock;
        bts [RSI], DI;
        ret;
    }
}

@("notrace") void atomicBitReset(ulong* p /* RSI */, ushort bitnum /* DI */) {
    version(LDC) {
        pragma(LDC_allow_inline);
    }
    asm pure nothrow @nogc {
        naked;
        lock;
        btr [RSI], DI;
        ret;
    }
}



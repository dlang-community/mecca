module mecca.reactor.fibril;

version (D_InlineAsm_X86_64) version (Posix) {
    private pure nothrow @trusted @nogc:

    void* _fibril_init_stack(void[] stackArea, void delegate() nothrow dg) {
        // set rsp to top of stack, and make sure it's 16-byte aligned
        auto rsp = cast(void*)((((cast(size_t)stackArea.ptr) + stackArea.length) >> 4) << 4);
        auto rbp = rsp;

        void push(void* v) nothrow pure @nogc {
            rsp -= v.sizeof;
            *(cast(void**)rsp) = v;
        }

        push(null);                     // Fake RET of entrypoint
        push(&_fibril_trampoline);      // RIP
        push(rbp);                      // RBP
        push(null);                     // RBX
        push(null);                     // R12
        push(null);                     // R13
        push(dg.ptr);                   // R14 - ctxptr
        push(dg.funcptr);               // R15 - funcptr

        return rsp;
    }

    extern(C) void _fibril_trampoline() nothrow {
        pragma(inline, false);
        asm pure nothrow @nogc {
            naked;
            mov RDI, R14;  // ctxptr  -- set by _fibril_init_stack
            mov RSI, R15;  // funcptr -- set by _fibril_init_stack

            // this has to be a jmp (not a call), otherwise exception-handling will see
            // this function in the stack and be... unhappy
            jmp _fibril_wrapper;
        }
    }

    extern(C) void _fibril_switch(void** fromRSP /* RDI */, void* toRSP /* RSI */) {
        pragma(inline, false);
        asm pure nothrow @nogc {
            naked;

            // save current state, then store RSP into `fromRSP`
            // RET is already pushed at TOS
            push RBP;
            push RBX;
            push R12;
            push R13;
            push R14;
            push R15;
            mov [RDI], RSP;

            // set RSP to `toRSP` and load state
            // and return to caller (RET is at TOS)
            mov RSP, RSI;
            pop R15;
            pop R14;
            pop R13;
            pop R12;
            pop RBX;
            pop RBP;
            ret;
        }
    }
}

extern(C) private void _fibril_wrapper(void delegate() dg) {
    import core.stdc.stdlib: abort;
    void writeErr(const(char[]) text) {
        import core.sys.posix.unistd: write;
        write(2, text.ptr, text.length);
    }

    try {
        dg();
        writeErr("Fibril function must never return\n");
        abort();
    }
    catch (Throwable ex) {
        writeErr("Fibril function must never throw\n");
        try {ex.toString(&writeErr);} catch (Throwable) {}
        writeErr("\n");
        abort();
    }
    // we add an extra call to abort here, so the compiler would be forced to emit `call` instead of `jmp`
    // above, thus leaving this function on the call stack. produces a more explciit backtrace.
    abort();
}

struct Fibril {
    void* rsp;

    void reset() {
        rsp = null;
    }
    void set(void[] stackArea, void delegate() nothrow dg) {
        assert (rsp is null, "already set");
        rsp = _fibril_init_stack(stackArea, dg);
    }
    void switchTo(ref Fibril next) nothrow {
        pragma(inline, true);
        _fibril_switch(&this.rsp, next.rsp);
    }
}


/+
void main() {
    import std.stdio;
    enum ITERS = 50_000_000;

    static struct TscTimePoint {
        long cycles;
        @property static TscTimePoint now() {
            return TscTimePoint(readTSC());
        }

        static ulong readTSC() @nogc @trusted {
            asm nothrow @nogc @trusted {
                naked;
                rdtsc;         // result = EDX(hi):EAX(lo)
                shl RDX, 32;
                or RAX, RDX;   // RAX |= (RDX << 32)
                ret;
            }
        }
    }

    __gshared static Fibril mainWire, fw, gw;
    __gshared static long fcount, gcount, maincount;

    void f() nothrow {
        foreach(i; 0 .. ITERS) {
            //try{writeln("f ", i);}catch(Throwable ex){}
            fcount++;
            fw.switchTo(gw);
        }
    }

    void g() nothrow {
        foreach(i; 0 .. ITERS) {
            //try{writeln("g ", i);}catch(Throwable ex){}
            gcount++;
            /+if (i == 3) {
                //import core.exception; throw new AssertError("oh no");
                return;
            }+/
            gw.switchTo(mainWire);
        }
    }

    fw.set(new ubyte[4096], &f);
    gw.set(new ubyte[4096], &g);

    auto t0 = TscTimePoint.now.cycles;
    foreach(i; 0 .. ITERS) {
        //try{writeln("m ", i);}catch(Throwable ex){}
        maincount++;
        mainWire.switchTo(fw);
    }
    auto dt = TscTimePoint.now.cycles - t0;
    auto total = maincount+gcount+fcount;
    writeln(total, " swicthes done in ", dt, " cycles; ", dt / (cast(double)total), " per switch");
}
+/



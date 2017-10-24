module mecca.reactor.impl.fibril;

// Disable tracing instrumentation for the whole file
@("notrace") void traceDisableCompileTimeInstrumentation();

version (D_InlineAsm_X86_64) version (Posix) {
    private pure nothrow @trusted @nogc:

    void* _fibril_init_stack(void[] stackArea, void function(void*) nothrow fn, void* opaque) {
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
        push(fn);                       // R14
        push(opaque);                   // R15

        return rsp;
    }

    extern(C) void _fibril_trampoline() nothrow {
        pragma(inline, false);
        asm pure nothrow @nogc {
            naked;
            mov RDI, R14;  // fn
            mov RSI, R15;  // opaque

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


extern(C) private void _fibril_wrapper(void function(void*) fn /* RDI */, void* opaque /* RSI */) {
    import core.stdc.stdlib: abort;
    void writeErr(const(char[]) text) {
        import core.sys.posix.unistd: write;
        // Write error directly to stderr
        write(2, text.ptr, text.length);
    }

    try {
        fn(opaque);
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
    // above, thus leaving this function on the call stack. it produces a more readable backtrace.
    abort();
}


struct Fibril {
    void* rsp;

    void reset() nothrow @nogc {
        rsp = null;
    }
    void set(void[] stackArea, void function(void*) nothrow fn, void* opaque) nothrow @nogc {
        assert (rsp is null, "already set");
        rsp = _fibril_init_stack(stackArea, fn, opaque);
    }
    void set(void[] stackArea, void delegate() nothrow dg) nothrow @nogc {
        set(stackArea, cast(void function(void*) nothrow)dg.funcptr, dg.ptr);
    }
    void switchTo(ref Fibril next) nothrow @trusted @nogc {
        pragma(inline, true);
        _fibril_switch(&this.rsp, next.rsp);
    }
}


unittest {
    import std.stdio;
    import std.range;

    ubyte[4096] stack1;
    ubyte[4096] stack2;

    Fibril mainFib, fib1, fib2;
    char[] order;

    void func1() nothrow {
        while (true) {
            order ~= '1';
            //try{writefln("in fib1");} catch(Throwable){}
            fib1.switchTo(fib2);
        }
    }
    void func2() nothrow {
        while (true) {
            order ~= '2';
            //try{writefln("in fib2");} catch(Throwable){}
            fib2.switchTo(mainFib);
        }
    }

    fib1.set(stack1, &func1);
    fib2.set(stack2, &func2);

    enum ITERS = 10;
    order.reserve(ITERS * 3);

    foreach(_; 0 .. ITERS) {
        order ~= 'M';
        //try{writefln("in main");} catch(Throwable){}
        mainFib.switchTo(fib1);
    }

    assert (order == "M12".repeat(ITERS).join(""), order);
}

unittest {
    import std.stdio;

    ubyte[4096] stack1;
    ubyte[4096] stack2;

    Fibril mainFib, fib1, fib2;
    size_t counter;

    void func1() nothrow {
        while (true) {
            counter++;
            fib1.switchTo(fib2);
        }
    }
    void func2() nothrow {
        while (true) {
            fib2.switchTo(mainFib);
        }
    }

    fib1.set(stack1, &func1);
    fib2.set(stack2, &func2);

    enum ITERS = 10_000_000;

    import mecca.lib.time: TscTimePoint;
    auto t0 = TscTimePoint.hardNow;
    foreach(_; 0 .. ITERS) {
        mainFib.switchTo(fib1);
    }
    auto dt = TscTimePoint.hardNow.diff!"cycles"(t0);
    assert (counter == ITERS);
    writefln("total %s cycles, per iteration %s", dt, dt / (ITERS * 3.0));
}


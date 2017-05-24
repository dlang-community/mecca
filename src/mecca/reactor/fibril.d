module mecca.reactor.fibril;

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
    // above, thus leaving this function on the call stack. produces a more explciit backtrace.
    abort();
}

struct Fibril {
    void* rsp;

    void reset() {
        rsp = null;
    }
    void set(void[] stackArea, void function(void*) nothrow fn, void* opaque) {
        assert (rsp is null, "already set");
        rsp = _fibril_init_stack(stackArea, fn, opaque);
    }
    void switchTo(ref Fibril next) nothrow {
        pragma(inline, true);
        _fibril_switch(&this.rsp, next.rsp);
    }
}

unittest {
    import std.stdio;
    import std.range;

    ubyte[4096] stack1;
    ubyte[4096] stack2;

    struct Context {
        Fibril mainFib, fib1, fib2;
        char[] order;
    }
    Context context;

    static void func1(void* c) nothrow {
        auto context = cast(Context*)c;
        while (true) {
            context.order ~= '1';
            //try{writefln("in fib1");} catch(Throwable){}
            context.fib1.switchTo(context.fib2);
        }
    }
    static void func2(void* c) nothrow {
        auto context = cast(Context*)c;
        while (true) {
            context.order ~= '2';
            //try{writefln("in fib2");} catch(Throwable){}
            context.fib2.switchTo(context.mainFib);
        }
    }

    context.fib1.set(stack1, &func1, &context);
    context.fib2.set(stack2, &func2, &context);

    enum ITERS = 10;
    context.order.reserve(ITERS * 3);

    foreach(_; 0 .. ITERS) {
        context.order ~= 'M';
        //try{writefln("in main");} catch(Throwable){}
        context.mainFib.switchTo(context.fib1);
    }

    assert (context.order == "M12".repeat(ITERS).join(""));
}

unittest {
    import std.stdio;

    ubyte[4096] stack1;
    ubyte[4096] stack2;

    struct Context {
        Fibril mainFib, fib1, fib2;
        size_t counter;
    }
    Context context;

    static void func1(void* c) nothrow {
        auto context = cast(Context*)c;
        while (true) {
            context.counter++;
            context.fib1.switchTo(context.fib2);
        }
    }
    static void func2(void* c) nothrow {
        auto context = cast(Context*)c;
        while (true) {
            context.fib2.switchTo(context.mainFib);
        }
    }

    context.fib1.set(stack1, &func1, &context);
    context.fib2.set(stack2, &func2, &context);

    enum ITERS = 10_000_000;

    import mecca.lib.time: TscTimePoint;
    auto t0 = TscTimePoint.now;
    foreach(_; 0 .. ITERS) {
        context.mainFib.switchTo(context.fib1);
    }
    auto dt = TscTimePoint.now.diff!"cycles"(t0);
    assert (context.counter == ITERS);
    writefln("total %s cycles, per iteration %s", dt, dt / (ITERS * 3.0));
}


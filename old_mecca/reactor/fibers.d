module mecca.reactor.fibers;

import core.thread;
import std.string;
import std.exception;
import std.traits;

import mecca.lib.reflection;
import mecca.lib.time;
import mecca.lib.exception;
import mecca.containers.linked_set;
import mecca.lib.memory;
import mecca.lib.tracing;
import mecca.reactor.fiber_local;
public import mecca.lib.tracing: FiberId;


package /* thread-local */ ReactorFiber _thisFiber;

class ReactorFiber: Fiber {
    enum MAX_FIBERS = 4096;
    enum GUARD_SIZE = SYS_PAGE_SIZE;
    static assert ((MAX_FIBERS & (MAX_FIBERS-1)) == 0);
    enum PERMANENT_ID_MASK = MAX_FIBERS - 1;

package:
    __gshared static ushort permanentIdCounter;

    // 0
    FiberId fiberId;
    Throwable thrownEx;
    // 16
    uint suspendCounter;
    const ushort permanentId;
    bool prioritized;
    private bool requestBacktrace;
    // 24
    private void*[] backtraceBuffer;
    // 40
    TscTimePoint timeResumed;
    TscTimePoint timeExecuted;
    // 56
    TracingContext myTracingContext;
    // 72
    FiberLocalStorageBlock flsBlock;
    // 80
    public Chain _chain;
    // 112
    Closure closure;
    // 192

    mixin (superAccessor!("_ctxt", "m_ctxt"));
    mixin (superAccessor!("_size", "m_size"));
    mixin (superAccessor!("_pmem", "m_pmem"));

    this(size_t stackSize) {
        import core.sys.posix.sys.mman;
        super(&fibFunc, ((stackSize + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) * SYS_PAGE_SIZE + GUARD_SIZE);
        errnoEnforce(mprotect(_pmem, GUARD_SIZE, PROT_NONE) == 0, "mprotect() failed");
        permanentId = permanentIdCounter++;
        assert (permanentId < MAX_FIBERS);
        fiberId.value = permanentId;
        recycle();
    }
    @property const(void*) guardArea() const pure nothrow @nogc {
        return _pmem;
    }
    @property const(void)* stackBottom() const pure nothrow @nogc {
        return _pmem + GUARD_SIZE;
    }
    @property size_t stackSize() const pure nothrow @nogc {
        return _size - GUARD_SIZE;
    }
    @property const(void)* stackTop() const pure nothrow @nogc {
        return _pmem + (_size - GUARD_SIZE);
    }
    @notrace private void fibFunc() {
        assert (state == State.EXEC);
        if (thrownEx !is null) {
            thrownEx = null;
            return;
        }
        closure();
    }

    @notrace void recycle() {
        assert (state != State.EXEC);
        fiberId.value += MAX_FIBERS;
        assert ((fiberId.value & PERMANENT_ID_MASK) == (permanentId & PERMANENT_ID_MASK),
            "fiberId=%s permanent=%s".format(fiberId, permanentId));
        thrownEx = null;
        closure = null;
        prioritized = false;
        requestBacktrace = false;
        myTracingContext.id = fiberId;
        myTracingContext.nesting = 0;
        myTracingContext.traceDisableNesting = 0;
        flsInitBlock.copyTo(flsBlock);
    }

    @notrace void prefetch() {
        prefetch_read(&myTracingContext);
        prefetch_read(_ctxt.tstack);
    }

    @notrace Object execute() {
        assert (_thisFiber is null);

        const restore = tracingContext;
        tracingContext = myTracingContext;
        indirFls = &flsBlock;
        _thisFiber = this;

        scope(exit) {
            _thisFiber = null;
            indirFls = null;
            myTracingContext = tracingContext;
            tracingContext = restore;
        }

        return super.call(Rethrow.no);
    }

    @notrace void suspend() {
        while (true) {
            yield();
            if (requestBacktrace) {
                backtraceBuffer = extractStack(backtraceBuffer);
                requestBacktrace = false;
            }
            else {
                break;
            }
        }
        if (thrownEx !is null) {
            auto ex = thrownEx;
            thrownEx = null;
            throw ex;
        }
    }

    void throwInFiber(Throwable ex) {
        final switch (state) with (State) {
            case  EXEC:
                throw ex;
            case HOLD:
                thrownEx = ex;
                break;
            case TERM:
                assert (false, "throw in terminated fiber");
        }
    }
    @notrace void*[] getBacktrace(void*[] backtraceBuffer) {
        if (state == State.TERM) {
            return null;
        }
        assert (state == State.HOLD);
        this.requestBacktrace = true;
        this.backtraceBuffer = backtraceBuffer;
        execute();
        assert (!requestBacktrace);
        return this.backtraceBuffer;
    }

    @property public ref auto fiberLocal(alias SYM)() {
        auto prev = indirFls;
        indirFls = &flsBlock;
        scope(exit) indirFls = prev;
        return SYM;
    }

    @notrace public auto DEBUG_AS(string msg, T...)(T args) {
    }
    @notrace public auto INFO_AS(string msg, T...)(T args) {
    }
    @notrace public auto WARN_AS(string msg, T...)(T args) {
    }
    @notrace public auto ERROR_AS(string msg, T...)(T args) {
    }
    @notrace public auto LOG_TRACEBACK_AS(string msg) {
    }
}

struct FiberHandle {
    enum FiberHandle invalid = FiberHandle.init;

    ReactorFiber _fib;
    FiberId _fiberId;

    this(ReactorFiber fib) nothrow @nogc {
        opAssign(fib);
    }
    ref opAssign(ReactorFiber fib) nothrow @nogc {
        _fib = fib;
        _fiberId = fib is null ? FiberId.invalid : fib.fiberId;
        return this;
    }
    bool opEquals(const FiberHandle rhs) const @safe pure nothrow {
        return _fiberId == rhs._fiberId;
    }

    @property bool isValid() const pure nothrow @nogc {
        return _fib.fiberId == _fiberId;
    }
    @property ReactorFiber get() pure nothrow @nogc {
        return (_fib.fiberId == _fiberId) ? _fib : null;
    }
    alias get this;
}






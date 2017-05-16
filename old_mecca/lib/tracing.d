module mecca.lib.tracing;

@("notrace") void traceDisableCompileTimeInstrumentation();

import mecca.lib.reflection;
public import mecca.lib.tracing_uda;

alias FiberId = TypedIdentifier!("FiberId", ulong);

struct TracingContext {
    FiberId id = FiberId.invalid;
    ubyte nesting = 0;
    ubyte traceDisableNesting = 0;
}

/* thread-local */ TracingContext tracingContext;

alias TraceEntryIndex = ulong;

enum LogLevel: ubyte {
    DEBUG, INFO, WARN, ERROR, META
}

TraceEntryIndex emitLog(LogLevel level, string msg, string modname, string filename, size_t line, T...)(T args) nothrow @trusted @nogc {
    version(notrace) {
        return 0;
    }
    else {
        return 0;
    }
}

TraceEntryIndex getTraceEntryIndex() nothrow @nogc @safe {
    return 0;
}

TraceEntryIndex DEBUG(string msg, string modname=__MODULE__, string filename=__FILE__, size_t line=__LINE__, T...)(T args) nothrow @safe @nogc {
    pragma(inline, true);
    return emitLog!(LogLevel.DEBUG, msg, modname, filename, line, T)(args);
}
TraceEntryIndex INFO(string msg, string modname=__MODULE__, string filename=__FILE__, size_t line=__LINE__, T...)(T args) nothrow @safe @nogc {
    pragma(inline, true);
    return emitLog!(LogLevel.INFO, msg, modname, filename, line, T)(args);
}
TraceEntryIndex WARN(string msg, string modname=__MODULE__, string filename=__FILE__, size_t line=__LINE__, T...)(T args) nothrow @safe @nogc {
    pragma(inline, true);
    return emitLog!(LogLevel.WARN, msg, modname, filename, line, T)(args);
}
TraceEntryIndex ERROR(string msg, string modname=__MODULE__, string filename=__FILE__, size_t line=__LINE__, T...)(T args) nothrow @safe @nogc {
    pragma(inline, true);
    return emitLog!(LogLevel.ERROR, msg, modname, filename, line, T)(args);
}
TraceEntryIndex META(string msg, string modname=__MODULE__, string filename=__FILE__, size_t line=__LINE__, T...)(T args) nothrow @safe @nogc {
    pragma(inline, true);
    return emitLog!(LogLevel.META, msg, modname, filename, line, T)(args);
}

TraceEntryIndex LOG_TRACEBACK(string msg, Throwable ex) nothrow @safe @nogc {
    return 0;
}
TraceEntryIndex LOG_TRACEBACK(string msg, Throwable.TraceInfo tinfo) nothrow @safe @nogc {
    return 0;
}
TraceEntryIndex LOG_TRACEBACK(string msg, const(void*)[] backtrace) nothrow @safe @nogc {
    return 0;
}
TraceEntryIndex LOG_CALLSTACK(string msg) nothrow @safe @nogc {
    return 0;
}


void TEXT_DEBUG(string msg) nothrow @safe @nogc {
}
void TEXT_INFO(string msg) nothrow @safe @nogc {
}
void TEXT_WARN(string msg) nothrow @safe @nogc {
}
void TEXT_ERROR(string msg) nothrow @safe @nogc {
}

alias TEXT = TEXT_DEBUG;






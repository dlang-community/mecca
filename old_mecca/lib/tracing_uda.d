module mecca.lib.tracing_uda;

@("notrace") void traceDisableCompileTimeInstrumentation();

struct notrace {
}

struct FMT {
    immutable string fmt;
}

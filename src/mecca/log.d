module mecca.log;

import std.stdio;
import std.string;
import mecca.lib.reflection: as;

/*
   These functions are mostly placeholders. Since we'd sometimes want to replace them with functions that do binary logging, the format
   is part of the function's template.
 */

import mecca.lib.console;

/* thread local */ char[4] logSource = "MAIN";

enum string[string] levelColor = [
    "DEBUG" : "1;30",
    "INFO" : "0;32",
    "WARN" : "1;33",
    "ERROR" : "1;31",
];

private void internalLogOutput(string LEVEL, T...)(string format, string file, size_t line, scope lazy T args) nothrow @nogc {
    as!"nothrow @nogc"({
            writefln("\x1b[36m%s \x1b[1;30m%s:%s\t \x1b[" ~ levelColor[LEVEL] ~ "m " ~ format ~ "\x1b[0m",
                logSource, file.split("/")[$-1], line, args);
    });
}

void DEBUG(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!"DEBUG"(format, file, line, args);
}

void INFO(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!"INFO"(format, file, line, args);
}

void WARN(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!"WARN"(format, file, line, args);
}

void ERROR(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!"ERROR"(format, file, line, args);
}

unittest {
    DEBUG!"Just some debug info %s"(42);
    INFO!"Event worthy of run time mention %s"(100);
    WARN!"Take heed, %s traveller, for something strange is a%s"("weary", "foot");
    ERROR!"2b || !2b == %s"('?');
}

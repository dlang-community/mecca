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
    "DEBUG" : ConsoleGreyFg,
    "INFO" : ConsoleCode!(Console.BoldOff,Console.GreenFg),
    "WARN" : ConsoleCode!(Console.BoldOn,Console.YellowFg),
    "ERROR" : ConsoleCode!(Console.BoldOn,Console.RedFg),
];

private void internalLogOutput(string LEVEL, string format, string file, size_t line, T...)(T args) nothrow @nogc {
    enum string unifiedFormat = ConsoleCyanFg ~ "%s " ~ ConsoleGreyFg ~ "%s:%s\t " ~ levelColor[LEVEL] ~ " " ~ format ~ ConsoleReset;
    enum string fileName = file.split("/")[$-1];
    as!"nothrow @nogc"({
            writefln(unifiedFormat, logSource, fileName, line, args);
    });
}

void DEBUG(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!("DEBUG", format, file, line)(args);
}

void INFO(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!("INFO", format, file, line)(args);
}

void WARN(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!("WARN", format, file, line)(args);
}

void ERROR(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @trusted @nogc {
    internalLogOutput!("ERROR", format, file, line)(args);
}

unittest {
    DEBUG!"Just some debug info %s"(42);
    INFO!"Event worthy of run time mention %s"(100);
    WARN!"Take heed, %s traveller, for something strange is a%s"("weary", "foot");
    ERROR!"2b || !2b == %s"('?');
}

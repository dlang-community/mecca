module mecca.log;

import std.stdio;
import std.string;
import std.datetime;
import mecca.lib.reflection: as;
import mecca.lib.console;

/*
   These functions are mostly placeholders. Since we'd sometimes want to replace them with functions that do binary logging, the format
   is part of the function's template.
 */

/* thread local */ char[4] logSource = "MAIN";

enum LEVEL_DEBUG = FG.grey;
enum LEVEL_INFO  = FG.green;
enum LEVEL_WARN  = FG.iyellow;
enum LEVEL_ERROR = FG.ired;

private void internalLogOutput(ANSI level, T...)(string fmt, string file, size_t line, T args) nothrow @trusted @nogc {
    as!"nothrow @nogc"({
        auto t = Clock.currTime();
        auto loc = "%s:%s".format(file.split("/")[$-1], line);
        writefln(FG.grey("%02d:%02d:%02d.%03d") ~ "\u2502" ~ FG.cyan("%s") ~ "\u2502" ~ FG.grey("%-20s") ~ "\u2502" ~ level(fmt),
            t.hour, t.minute, t.second, t.fracSecs.total!"msecs", logSource, loc[$ > 20 ? $ - 20 : 0 .. $], args);
    });
}

void DEBUG(string fmt, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!LEVEL_DEBUG(fmt, file, line, args);
}

void INFO(string fmt, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!LEVEL_INFO(fmt, file, line, args);
}

void WARN(string fmt, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!LEVEL_WARN(fmt, file, line, args);
}

void ERROR(string fmt, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!LEVEL_ERROR(fmt, file, line, args);
}

unittest {
    DEBUG!"Just some debug info %s"(42);
    INFO!"Event worthy of run time mention %s"(100);
    WARN!"Take heed, %s traveller, for something strange is a%s"("weary", "foot");
    ERROR!"2b || !2b == %s"('?');
}

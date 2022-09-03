module mecca.log;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(MeccaAlternateLogger) {
mixin("public import " ~ import("MeccaAlternateLogger.txt") ~ ";");
} else {
import std.stdio;
import std.string;
import std.datetime;
import mecca.lib.reflection: as;
import mecca.lib.console;
import mecca.lib.exception: extractStack, DefaultTraceInfoABI;
import mecca.log.impl;
import mecca.containers.arrays:FixedString;

/// Report whether the loggin infra has been initialized
enum loggingInitialized = true;

/**
 * UDA for disabling auto tracing of a specific function
 *
 * Decorate functions that should not be traced with @notrace.
 */
enum notrace = "notrace";

// All implementations must define this enum to say whether logs sent find their way to the console
enum LogToConsole = true;

// UDA for modifying a variable formatting (currently ignored)
struct FMT {
    immutable string __log_customFormatString;
}

/*
   These functions are mostly placeholders. Since we'd sometimes want to replace them with functions that
   do binary logging, the format is part of the function's template.
 */

enum LEVEL_DEBUG     = FG.grey;
enum LEVEL_INFO      = FG.green;
enum LEVEL_WARN      = FG.iyellow;
enum LEVEL_ERROR     = FG.ired;
enum LEVEL_EXCEPTION = FG.iwhite | BG.red;
enum LEVEL_META = FG.iwhite | BG.magenta;
enum LEVEL_BT        = FG.red;

enum FMT_MAX     = 2048;

enum FMT_PREFIX = FG.grey("%02d:%02d:%02d.%03d") ~ "\u2502" ~ FG.cyan("%s") ~ "\u2502" ~ FG.grey("%-20s") ~ "\u2502";


private void internalLogOutput(ANSI level, string fmt, T...)(string file, size_t line, T args) nothrow @trusted @nogc {
    as!"nothrow @nogc"({
        import std.algorithm.searching: until;
        import std.range: retro;
        import std.path: baseName;
        auto t = Clock.currTime();
        auto path = baseName(file);
        FixedString!30 loc = path[$ > 20 ? $ - 20 : 0 .. $];
        loc.nogcFormat!":%d"(line);
        FixedString!FMT_MAX buf = FMT_PREFIX;
        level.writeTo(buf, fmt);
        writefln(buf, t.hour, t.minute, t.second, t.fracSecs.total!"msecs", logSource, loc, args);
    });
}

void DEBUG(string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!(LEVEL_DEBUG, fmt)(file, line, args);
}

void INFO(string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!(LEVEL_INFO, fmt)(file, line, args);
}

void WARN(string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!(LEVEL_WARN, fmt)(file, line, args);
}

void ERROR(string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!(LEVEL_ERROR, fmt)(file, line, args);
}

void LOG_EXCEPTION(Throwable ex) nothrow @trusted @nogc {
    internalLogOutput!(LEVEL_EXCEPTION, "%s@%s(%s): %s")(ex.file, ex.line, typeid(ex).name, ex.file, ex.line, ex.msg);
    if (ex.info) {
        foreach( ptr; DefaultTraceInfoABI.extract(ex.info).frames ) {
            as!"nothrow @nogc"({ writefln("\t0x%x", ptr); });
        }
    }
}

void META(string fmt, string file = __FILE_FULL_PATH__, string mod = __MODULE__, int line = __LINE__, T...)(T args) nothrow @safe @nogc {
    internalLogOutput!(LEVEL_META, fmt)( file, line, args);
}

void LOG_TRACEBACK(void*[] bt, string msg, string file = __FILE_FULL_PATH__, size_t line = __LINE__) nothrow @trusted @nogc
{
    internalLogOutput!(LEVEL_BT, "%s")(file, line, msg);
    foreach( ptr; bt ) {
        as!"nothrow @nogc"({ writefln("\t0x%x", ptr); });
    }
}

/* thread local */ static void*[128] btBuffer = void;

void dumpStackTrace(string msg = "Backtrace:", string file = __FILE_FULL_PATH__, size_t line = __LINE__) nothrow @trusted @nogc {
    auto bt = extractStack(btBuffer);
    LOG_TRACEBACK(bt, msg, file, line);
}

void flushLog() nothrow @trusted @nogc {
    as!"nothrow @nogc"({ stdout.flush(); });
}

unittest {
    DEBUG!"Just some debug info %s"(42);
    INFO!"Event worthy of run time mention %s"(100);
    WARN!"Take heed, %s traveller, for something strange is a%s"("weary", "foot");
    ERROR!"2b || !2b == %s"('?');
    dumpStackTrace("Where am I?");
    try {
        throw new Exception("inception");
    }
    catch (Exception ex) {
        LOG_EXCEPTION(ex);
    }
}
}

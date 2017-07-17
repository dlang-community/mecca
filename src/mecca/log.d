module mecca.log;

import std.stdio;
import mecca.lib.reflection: as;

/*
   These functions are mostly placeholders. Since we'd sometimes want to replace them with functions that do binary logging, the format
   is part of the function's template.
 */

private void internalLogOutput(string TYPE, T...)(string format, scope lazy T args) nothrow {
    as!"nothrow @nogc"({writefln(TYPE ~ " " ~ format, args);});
}

void DEBUG(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @nogc {
    internalLogOutput!"DEBUG"("%s:%s " ~ format, file, line, args);
}

void INFO(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @nogc {
    internalLogOutput!"INFO"("%s:%s " ~ format, file, line, args);
}

void WARN(string format, string file = __FILE__, int line = __LINE__, T...)(T args) nothrow @nogc {
    internalLogOutput!"WARN"("%s:%s " ~ format, file, line, args);
}

void ERROR(string format, string file = __FILE__, int line = __LINE__, T...)(scope lazy T args) nothrow {
    internalLogOutput!"ERROR"("%s:%s " ~ format, file, line, args);
}

unittest {
    DEBUG!"Just some debug info %s"(42);
    INFO!"Event worthy of run time mention %s"(100);
    WARN!"Take heed, %s traveller, for something strange is a%s"("weary", "foot");
    ERROR!"2b || !2b == %s"('?');
}

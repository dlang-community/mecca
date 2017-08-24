module mecca.services.ut_main;

version(unittest):

import std.stdio;
import std.string;
import std.datetime;
import std.path: absolutePath, buildNormalizedPath;
import core.sys.posix.unistd: isatty;
import core.runtime: Runtime;

import mecca.lib.console;

shared static this() {
    Runtime.moduleUnitTester = (){return true;};
}

int main(string[] argv) {
    bool tty = isatty(1) != 0;

    void logLine(string text) {
        auto t = Clock.currTime();
        writefln(FG.grey("%02d:%02d:%02d.%03d") ~ " %s", t.hour, t.minute, t.second,
                t.fracSecs.total!"msecs", text);
    }

    string[] do_run;
    string[] dont_run;
    foreach(a; argv[1 .. $]) {
        if (a.length == 0) {
            continue;
        }
        if (a[0] == '-') {
            dont_run ~= a[1 .. $];
        }
        else if (a[0] == '+') {
            do_run ~= a[1 .. $];
        }
        else {
            do_run ~= a;
        }
    }

    bool shouldRun(string name) {
        size_t numMatched = 0;
        foreach(prefix; do_run) {
            if (name.startsWith(prefix)) {
                numMatched++;
            }
        }
        if (do_run.length > 0 && numMatched == 0) {
            return false;
        }
        foreach(prefix; dont_run) {
            if (name.startsWith(prefix)) {
                return false;
            }
        }
        return true;
    }

    size_t totalUTs;
    foreach(m; ModuleInfo) {
        if (m && m.unitTest) {
            totalUTs++;
        }
    }

    size_t counter;
    bool failed = false;
    auto startTime = MonoTime.currTime();

    logLine(FG.icyan("Started UT of %s (a total of %s found)".format(buildNormalizedPath(argv[0].absolutePath()), totalUTs)));

    foreach(m; ModuleInfo) {
        if (m is null) {
            continue;
        }
        auto fp = m.unitTest;
        if (fp is null) {
            continue;
        }
        if (!shouldRun(m.name)) {
            continue;
        }

        counter++;
        logLine(FG.yellow("Running UT of ") ~ FG.iwhite(m.name));
        try {
            fp();
        }
        catch (Throwable ex) {
            logLine(FG.red("UT failed!"));
            auto seenSep = false;
            foreach(line; ex.toString().lineSplitter()) {
                auto idx = line.indexOf(" ");
                if (seenSep && idx >= 0) {
                    auto loc = line[0 .. idx];
                    auto func = line[idx .. $];
                    writefln("    %-30s  %s", (loc == "??:?") ? "" : loc, func);
                    if (func.startsWith(" int mecca.ut_harness.main")) {
                        break;
                    }
                }
                else {
                    if (!seenSep && line.indexOf("------------") >= 0) {
                        seenSep = true;
                        writeln("    ----------------------------------------------");
                    }
                    else {
                        writeln("    ", line);
                    }
                }
            }
            failed = true;
            break;
        }
    }
    auto endTime = MonoTime.currTime();
    auto secs = (endTime - startTime).total!"msecs" / 1000.0;

    if (failed) {
        logLine(FG.ired("Failed. Ran %s unittests in %.2f seconds".format(counter, secs)));
        return 1;
    }
    else if (counter == 0) {
        logLine(FG.ired("Did not find any unittests to run"));
        return 2;
    }
    else {
        logLine(FG.igreen("Success. Ran %s unittests in %.2f seconds".format(counter, secs)));
        return 0;
    }
}



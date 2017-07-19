module mecca.ut_harness;

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

    void notify(string[] text...) {
        auto t = Clock.currTime();
        if (tty) {
            writef(ConsoleCode!(Console.BlackFg,Console.BoldOn) ~ "%02d:%02d:%02d.%03d" ~ ConsoleReset ~ " ", t.hour, t.minute, t.second,
                    t.fracSecs.total!"msecs");
        }
        else {
            writef("[%02d:%02d:%02d.%03d] ", t.hour, t.minute, t.second, t.fracSecs.total!"msecs");
        }
        foreach(i, part; text) {
            if (tty) {
                if (i % 2 == 0) {
                    writef("\x1b[%sm", part);
                }
                else {
                    writef("%s" ~ ConsoleReset, part);
                }
            }
            else {
                if (i % 2 == 1) {
                    write(part);
                }
            }
        }
        writeln();
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

    notify("1;36", "Started UT of %s (a total of %s found)".format(buildNormalizedPath(argv[0].absolutePath()), totalUTs));

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
        notify("33", "Running UT of ", "1;37", m.name);
        try {
            fp();
        }
        catch (Throwable ex) {
            notify("31", "UT failed!");
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
        notify("1;31", "Failed. Ran %s unittests in %.2f seconds".format(counter, secs));
        return 1;
    }
    else if (counter == 0) {
        notify("1;31", "Did not find any unittests to run");
        return 2;
    }
    else {
        notify("1;32", "Success. Ran %s unittests in %.2f seconds".format(counter, secs));
        return 0;
    }
}



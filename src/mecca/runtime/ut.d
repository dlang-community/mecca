/// Mecca UT support
module mecca.runtime.ut;

version(unittest):

import std.stdio;
import std.string;
import std.datetime;
import std.path: absolutePath, buildNormalizedPath;
import core.sys.posix.unistd: isatty;
import core.runtime: Runtime;

import mecca.lib.console;
import mecca.log;

shared static this() {
    Runtime.moduleUnitTester = (){return true;};
}

/**
 * Automatic main for UT compilations.
 *
 * Special main for UT compilations. This main accepts arguments that limit (by module) the UTs to run.
 */
@notrace int utMain(string[] argv) {
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

    META!"Started UT of %s (a total of %s found)"(buildNormalizedPath(argv[0].absolutePath()), totalUTs);
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
        META!"Running UT of %s"(m.name);
        logLine(FG.yellow("Running UT of ") ~ FG.iwhite(m.name));
        try {
            fp();
        }
        catch (Throwable ex) {
            ERROR!"UT failed!"();
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
        META!"Failed. Ran %s unittests in %.2f seconds"(counter, secs);
        logLine(FG.ired("Failed. Ran %s unittests in %.2f seconds".format(counter, secs)));
        return 1;
    }
    else if (counter == 0) {
        META!"Did not find any unittest to run"();
        logLine(FG.ired("Did not find any unittests to run"));
        return 2;
    }
    else {
        META!"Success. Ran %s unittests in %.2f seconds"(counter, secs);
        logLine(FG.igreen("Success. Ran %s unittests in %.2f seconds".format(counter, secs)));
        return 0;
    }
}


struct mecca_ut {}

void runFixtureTestCases(FIXTURE, string mod = __MODULE__)() {
    import std.stdio;
    import std.traits;
    writeln();
    foreach(testCaseName; __traits(derivedMembers, FIXTURE)) {
        static if ( __traits(compiles, __traits(getMember, FIXTURE, testCaseName) ) ) {
            static if (hasUDA!(__traits(getMember, FIXTURE, testCaseName), mecca_ut)) {
                import std.string:format;
                string fullCaseName = format("%s.%s", __traits(identifier, FIXTURE), testCaseName);
                META!"Test Case: %s"(fullCaseName);
                stderr.writefln("\t%s...", fullCaseName);
                import std.typecons:scoped;
                auto fixture = new FIXTURE();
                try {
                    __traits(getMember, fixture, testCaseName)();
                } catch (Throwable t) {
                    stderr.writeln("\tERROR");
                    throw t;
                }
                destroy(fixture);
                stderr.flush();
            }
        }
    }
}

/**
 * Automatic UT expansion
 *
 * Applying the mixin on a class causes all class members labeled with the @mecca_ut attribute to run.
 */
mixin template TEST_FIXTURE(FIXTURE) {
    unittest {
        runFixtureTestCases!(FIXTURE)();
    }
}


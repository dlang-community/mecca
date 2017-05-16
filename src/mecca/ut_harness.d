module mecca.ut_harness;

version(unittest):

import std.stdio;
import std.string;
import std.datetime;
import core.sys.posix.unistd: isatty;
import core.runtime: Runtime;

shared static this() {
    Runtime.moduleUnitTester = (){return true;};
}

int utMain(string[] argv) {
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

    auto startTime = MonoTime.currTime();
    size_t counter;
    bool failed = false;

    foreach(m; ModuleInfo) {
        if (m is null) {
            continue;
        }
        auto fp = m.unitTest;
        if (fp is null) {
            continue;
        }
        auto name = m.name;
        auto shouldRun = (do_run.length == 0);
        foreach(prefix; do_run) {
            if (name.startsWith(prefix)) {
                shouldRun = true;
                break;
            }
        }
        foreach (prefix; dont_run) {
            if (name.startsWith(prefix)) {
                shouldRun = false;
                break;
            }
        }
        if (!shouldRun) {
            continue;
        }

        writefln("\x1b[33mRunning UT of \x1b[1;7m%s\x1b[0m", m.name);
        try {
            fp();
        }
        catch (Throwable ex) {
            writeln("\x1b[31mUT failed!\x1b[0m");
            writeln(ex);
            failed = true;
            break;
        }
        counter++;
    }
    auto endTime = MonoTime.currTime();
    auto secs = (endTime - startTime).total!"msecs" / 1000.;

    writeln("===========================================================");
    if (failed) {
        writefln("\x1b[1;31mRan %s unittests in %.2f seconds\x1b[0m", counter, secs);
        return 1;
    }
    else if (counter == 0) {
        writefln("\x1b[1;31mDid not run any unittests (no matches for filter)\x1b[0m");
        return 1;
    }
    else {
        writefln("\x1b[1;32mRan %s unittests in %.2f seconds\x1b[0m", counter, secs);
        return 0;
    }
}

int main(string[] argv) {
    return utMain(argv);
}

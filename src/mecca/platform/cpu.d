module mecca.platform.cpu;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.string;
import std.conv;

version(linux):

struct CPUInfo {
    string[string] members;

    bool opBinaryRight(string op: "in")(string name) const {
        return (name in members) !is null;
    }
    string opIndex(string name) const {
        return members[name];
    }
    T getAs(T)(string name) const {
        return to!T(members[name]);
    }
    string toString() const {
        return to!string(members);
    }

    @property int coreId() const {
        return getAs!int("core id");
    }
    @property int physicalId() const {
        return getAs!int("physical id");
    }
    @property string[] flags() const {
        return members["flags"].split();
    }
}

private __gshared CPUInfo[int] _cpus;

private void loadCPUInfos() {
    import std.file: readText;
    auto lines = readText("/proc/cpuinfo").splitLines();

    CPUInfo processor;

    while(lines.length > 0) {
        auto line = lines[0].strip();
        lines = lines[1 .. $];
        if (line.length == 0) {
            _cpus[processor.getAs!int("processor")] = processor;
            processor = CPUInfo.init;
            continue;
        }

        auto colon = line.indexOf(":");
        auto k = line[0 .. colon].strip();
        auto v = line[colon+1 .. $].strip();
        processor.members[k] = v;
    }
}

@property const(CPUInfo[int]) cpuInfos() {
    if (_cpus.length == 0) {
        loadCPUInfos();
    }
    return _cpus;
}

unittest {
    import std.stdio;
    import std.algorithm;

    assert (cpuInfos.length > 0);
    assert (cpuInfos[0].flags.canFind("sse"));
}


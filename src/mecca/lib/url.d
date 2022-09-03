module mecca.lib.url;

import std.regex: splitter, regex;
import std.typecons; // : Flag, Yes, No;
import mecca.containers.arrays;

struct Url {
    string scheme;
    string host;
    string path;
    string port;
    
    enum re  ="[/:]".regex;
    static Url parse(string url) {
        auto parts = url.splitter!(Yes.keepSeparators)(re).fixedArray!100;
        Url result;
        result.scheme = parts[0]; // 0=scheme, 1=:,2=,3=/,4=,5=/,6=host,7=:,8=port,9=/,10...=path,
        result.host = parts[6];
        bool hasPort = parts.length>8 && parts[7]==":";
        int pathIndex = hasPort ? 9:7;
        result.path = parts.length>pathIndex+1? parts[pathIndex].ptr[0..url.length-(parts[pathIndex].ptr-url.ptr)] : "/";
        result.port = hasPort ? parts[8] : parts[0][$-1]=='s'?"443":"80";
        return result;
    }
}

unittest {
    Url url=Url.parse("https://google.com");
    assert(url.path=="/");
    assert(url.host=="google.com");
    assert(url.port=="443");
}

unittest {
    Url url=Url.parse("https://google.com:999");
    assert(url.path=="/");
    assert(url.host=="google.com");
    assert(url.port=="999");
}

unittest {
    Url url=Url.parse("https://google.com:999/a/b/c");
    assert(url.path=="/a/b/c");
    assert(url.host=="google.com");
    assert(url.port=="999");
}

unittest {
    Url url=Url.parse("http://google.com/a/b/c");
    assert(url.path=="/a/b/c");
    assert(url.host=="google.com");
    assert(url.port=="80");
}
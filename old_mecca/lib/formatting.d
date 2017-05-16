module mecca.lib.formatting;


@("notrace") char[] nogcFormat(string fmt, T...)(char[] buf, auto ref T args) @nogc {
    import std.string: sformat;
    return (cast(char[] function(char[], string fmt, T) @nogc)&sformat!(immutable(char), T))(buf, fmt, args);
}

unittest {
    char[100] buf;
    auto res = nogcFormat!"x=%s y=%d"(buf, "hello", 7);
    assert (res == "x=hello y=7");
}



module mecca.experimental.phantom;

import std.stdio;

struct Token {
    @disable this(this);
    @disable this();
    @disable void opAssign(T)(auto ref T x);
    @disable static Token init();
}

void baruch(ref Token tok) {
    writeln(__FUNCTION__);
}

auto moishe(ref Token tok, int x) {
    baruch(tok);

    //void nested() {
    //    baruch(tok);
    //}

    //baruch(Token.init);

    //auto tmp = tok;
    writeln(x);
}

unittest {
    auto ptok = cast(Token*)null;
    moishe(*ptok, 5);
}

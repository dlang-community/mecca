module mecca.lib.console;

struct ANSI {
    string code;
    this(string code) pure nothrow @nogc {
        this.code = code;
    }
    ANSI opBinary(string op)(ANSI rhs) const if (op == "|" || op == "+" || op == "~"){
        return ANSI(code ~ ";" ~ rhs.code);
    }
    string opCall(string text) const {
        return "\x1b[" ~ code ~ "m" ~ text ~ "\x1b[0m";
    }

    enum reset = ANSI("0");
    enum inverse = ANSI("7");
    alias negative = inverse;
    enum crossed = ANSI("9");
    enum bold = ANSI("1");
    alias intense = bold;
}

struct FG {
    enum black    = ANSI("30");
    enum red      = ANSI("31");
    enum green    = ANSI("32");
    enum yellow   = ANSI("33");
    enum blue     = ANSI("34");
    enum magenta  = ANSI("35");
    enum cyan     = ANSI("36");
    enum white    = ANSI("37");
    enum default_ = ANSI("39");

    enum iblack   = ANSI.intense | black;
    enum ired     = ANSI.intense | red;
    enum igreen   = ANSI.intense | green;
    enum iyellow  = ANSI.intense | yellow;
    enum iblue    = ANSI.intense | blue;
    enum imagenta = ANSI.intense | magenta;
    enum icyan    = ANSI.intense | cyan;
    enum iwhite   = ANSI.intense | white;

    alias grey    = iblack;
    alias purple  = imagenta;
}

struct BG {
    enum black    = ANSI("40");
    enum red      = ANSI("41");
    enum green    = ANSI("42");
    enum yellow   = ANSI("43");
    enum blue     = ANSI("44");
    enum magenta  = ANSI("45");
    enum cyan     = ANSI("46");
    enum white    = ANSI("47");
    enum default_ = ANSI("49");
}


unittest {
    assert ("hello " ~ (FG.grey | BG.white)("moshe") ~ " of suburbia" == "hello \x1b[1;30;47mmoshe\x1b[0m of suburbia");
}

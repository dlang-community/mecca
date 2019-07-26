/// Tools for manipulating the console
module mecca.lib.console;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

/**
 * Encode an ANSI console sequence.
 */
struct ANSI {
private:
    string code;

public:
    /// Constructor for specific code
    this(string code) pure nothrow @nogc {
        assert(code.length > 0);
        this.code = code;
    }

    /// Concatanate another code to the existing one
    ANSI opBinary(string op)(ANSI rhs) const if (op == "|" || op == "+" || op == "~"){
        return ANSI(code ~ ";" ~ rhs.code);
    }

    /// Get the encoded ANSI sequence, including escapes
    string opCall(string text) const {
        return "\x1b[" ~ code ~ "m" ~ text ~ "\x1b[0m";
    }

    void writeTo(R)(ref R output, string text) const {
        output ~= "\x1b[";
        output ~= code;
        output ~= "m";
        output ~= text;
        output ~= "\x1b[0m";
    }

    /// Predefined ANSI sequences
    enum reset = ANSI("0");
    enum inverse = ANSI("7");           /// ditto
    alias negative = inverse;           /// ditto
    enum crossed = ANSI("9");           /// ditto
    enum bold = ANSI("1");              /// ditto
    alias intense = bold;               /// ditto
}

/// Predefined foreground colors
struct FG {
    enum black    = ANSI("30");                 /// Foreground color
    enum red      = ANSI("31");                 /// ditto
    enum green    = ANSI("32");                 /// ditto
    enum yellow   = ANSI("33");                 /// ditto
    enum blue     = ANSI("34");                 /// ditto
    enum magenta  = ANSI("35");                 /// ditto
    enum cyan     = ANSI("36");                 /// ditto
    enum white    = ANSI("37");                 /// ditto
    enum default_ = ANSI("39");                 /// ditto

    enum iblack   = ANSI.intense | black;       /// ditto
    enum ired     = ANSI.intense | red;         /// ditto
    enum igreen   = ANSI.intense | green;       /// ditto
    enum iyellow  = ANSI.intense | yellow;      /// ditto
    enum iblue    = ANSI.intense | blue;        /// ditto
    enum imagenta = ANSI.intense | magenta;     /// ditto
    enum icyan    = ANSI.intense | cyan;        /// ditto
    enum iwhite   = ANSI.intense | white;       /// ditto

    alias grey    = iblack;                     /// ditto
    alias purple  = imagenta;                   /// ditto
}

/// Predefined foreground colors
struct BG {
    enum black    = ANSI("40");                 /// Background color
    enum red      = ANSI("41");                 /// ditto
    enum green    = ANSI("42");                 /// ditto
    enum yellow   = ANSI("43");                 /// ditto
    enum blue     = ANSI("44");                 /// ditto
    enum magenta  = ANSI("45");                 /// ditto
    enum cyan     = ANSI("46");                 /// ditto
    enum white    = ANSI("47");                 /// ditto
    enum default_ = ANSI("49");                 /// ditto
}


unittest {
    assert ("hello " ~ (FG.grey | BG.white)("moshe") ~ " of suburbia" == "hello \x1b[1;30;47mmoshe\x1b[0m of suburbia");
}

module mecca.lib.console;

enum Console : string {
    Reset = "0",
    BoldOn = "1",
    BolOff = "22",
    ItalicsOn = "3",
    ItalicsOff = "23",
    UnderlineOn = "4",
    UnderlineOff = "24",
    InverseOn = "7",
    InverseOff = "27",
    StrikethroughOn = "9",
    StrikethroughOff = "29",
    BlackFg = "30",
    RedFg = "31",
    GreenFg = "32",
    YellowFg = "33",
    BlueFg = "34",
    MagentaFg = "35",
    CyanFg = "36",
    WhiteFg = "37",
    DefaultFg = "39",
    BlackBg = "40",
    RedBg = "41",
    GreenBg = "42",
    YellowBg = "43",
    BlueBg = "44",
    MagentaBg = "45",
    CyanBg = "46",
    WhiteBg = "47",
    DefaultBg = "49",
};

enum ConsoleReset = ConsoleCode!(Console.Reset);
enum ConsoleBoldOn = ConsoleCode!(Console.BoldOn);
enum ConsoleBolOff = ConsoleCode!(Console.BolOff);
enum ConsoleItalicsOn = ConsoleCode!(Console.ItalicsOn);
enum ConsoleItalicsOff = ConsoleCode!(Console.ItalicsOff);
enum ConsoleUnderlineOn = ConsoleCode!(Console.UnderlineOn);
enum ConsoleUnderlineOff = ConsoleCode!(Console.UnderlineOff);
enum ConsoleInverseOn = ConsoleCode!(Console.InverseOn);
enum ConsoleInverseOff = ConsoleCode!(Console.InverseOff);
enum ConsoleStrikethroughOn = ConsoleCode!(Console.StrikethroughOn);
enum ConsoleStrikethroughOff = ConsoleCode!(Console.StrikethroughOff);
enum ConsoleBlackFg = ConsoleCode!(Console.BlackFg);
enum ConsoleRedFg = ConsoleCode!(Console.RedFg);
enum ConsoleGreenFg = ConsoleCode!(Console.GreenFg);
enum ConsoleYellowFg = ConsoleCode!(Console.YellowFg);
enum ConsoleBlueFg = ConsoleCode!(Console.BlueFg);
enum ConsoleMagentaFg = ConsoleCode!(Console.MagentaFg);
enum ConsoleCyanFg = ConsoleCode!(Console.CyanFg);
enum ConsoleWhiteFg = ConsoleCode!(Console.WhiteFg);
enum ConsoleDefaultFg = ConsoleCode!(Console.DefaultFg);
enum ConsoleBlackBg = ConsoleCode!(Console.BlackBg);
enum ConsoleRedBg = ConsoleCode!(Console.RedBg);
enum ConsoleGreenBg = ConsoleCode!(Console.GreenBg);
enum ConsoleYellowBg = ConsoleCode!(Console.YellowBg);
enum ConsoleBlueBg = ConsoleCode!(Console.BlueBg);
enum ConsoleMagentaBg = ConsoleCode!(Console.MagentaBg);
enum ConsoleCyanBg = ConsoleCode!(Console.CyanBg);
enum ConsoleWhiteBg = ConsoleCode!(Console.WhiteBg);
enum ConsoleDefaultBg = ConsoleCode!(Console.DefaultBg);

private enum string Esc = "\x1b[", Sep = ";", End = "m";

template ConsoleCode(T...) {
    string genCode() {
        static assert(T.length >= 1);
        string ret = Esc;
        bool first=true;
        foreach(code; T) {
            if( !first ) {
                ret ~= Sep;
            }
            first = false;
            ret ~= code;
        }
        ret ~= End;

        return ret;
    }

    enum string ConsoleCode = genCode();
}

unittest {
    assert( ConsoleCode!(Console.RedFg) == Esc ~ Console.RedFg ~ End );
    assert( ConsoleCode!(Console.RedFg, Console.BlueBg) == Esc ~ Console.RedFg ~ Sep ~ Console.BlueBg ~ End );
}

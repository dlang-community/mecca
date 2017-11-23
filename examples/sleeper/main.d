module lordcmdr.main;

import std.stdio;
import std.datetime;

import mecca.reactor: theReactor;

void main(string[] argv) {
    theReactor.setup();
    scope(exit) theReactor.teardown();

    writeln("hello");
    theReactor.sleep(1.seconds);
    writeln("goodbye");
}

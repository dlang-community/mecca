module mecca.node;

import std.stdio;

struct Node {
    struct Service {
        string name;
        string[] deps;
        void delegate() setup;
        void delegate() teardown;
    }

    Service[string] services;

    void main() {
    }
}


unittest {
    writeln("Hello World.");
}

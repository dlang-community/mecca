module lordcmdr.main;

import std.stdio;

import mecca.runtime.services;
import mecca.runtime.main;
import mecca.reactor: theReactor;
import mecca.reactor.io.signals: reactorSignal;


struct LordCommander {
    mixin registerService;

    void handleSIGINT() {
        serviceManager.stop();
    }

    void mainFib() {
        reactorSignal.registerHandler!"SIGINT"(&handleSIGINT);

        writeln("mainFib");
    }
}


void main(string[] argv) {
    meccaMain(argv);
}

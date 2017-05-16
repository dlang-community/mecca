module mecca.reactor.test_reactor;

version(unittest):

import std.stdio;

import mecca.reactor.reactor;
import mecca.reactor.sync;


void testWithReactor(void delegate() main, Reactor.Options opts = Reactor.Options.init) {
    theReactor.options = opts;
    theReactor.open();
    scope(exit) theReactor.close();

    bool succ = false;

    theReactor.spawnFiber({
        scope(exit) theReactor.stop();
        scope(success) succ = true;
        main();
    });

    theReactor.mainloop();
    assert (succ);
}


unittest {
    testWithReactor({
        __gshared static Barrier barrier;

        static void fibFunc(string name) {
            foreach(i; 0 .. 10) {
                theReactor.contextSwitch();
                writeln(name);
            }
            barrier.markDone();
        }

        theReactor.spawnFiber!fibFunc("A");
        theReactor.spawnFiber!fibFunc("B");
        barrier.addWaiter(2);
        barrier.waitAll();
    });
}



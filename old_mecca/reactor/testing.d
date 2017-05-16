module mecca.reactor.testing;

version(unittest):

import mecca.reactor.reactor;

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



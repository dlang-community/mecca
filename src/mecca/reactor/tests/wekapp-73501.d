module mecca.reactor.tests.wekapp_73501;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version(unittest):

import std.algorithm: move;
import mecca.lib.exception;
import mecca.lib.io;
import mecca.lib.time;
import mecca.log;
import mecca.reactor;
import mecca.reactor.io.fd;

unittest {
    META!"UT for testing socket/pipe hangup is properly detected"();

    void testBody() {
        FD pipeReadFD, pipeWriteFD;
        createPipe(pipeReadFD, pipeWriteFD);
        ReactorFD pipeRead = ReactorFD(move(pipeReadFD));
        ReactorFD pipeWrite = ReactorFD(move(pipeWriteFD));

        ubyte[1024] buffer;

        pipeWrite.write(buffer);
        auto res = pipeRead.read(buffer, Timeout(20.msecs));
        assertEQ(res, 1024, "read returned wrong size");

        theReactor.spawnFiber({ pipeWrite.close(); });

        res = pipeRead.read(buffer, Timeout(20.msecs));
        assertEQ(res, 0, "read did not report EOF");
    }
    testWithReactor(&testBody);
}

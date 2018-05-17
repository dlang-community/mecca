import std.algorithm : move;

import mecca.lib.time;
import mecca.reactor;
import mecca.reactor.io.fd;

enum ECHO_PORT = 7007;
enum CLIENT_TIMEOUT = 20.seconds;

int main() {
    theReactor.setup();
    scope(exit) theReactor.teardown(); // Not really needed outside of UTs

    theReactor.spawnFiber!listeningFiber();
    return theReactor.start();
}

void listeningFiber() {
    auto listeningSock = ConnectedSocket.listen( SockAddrIPv4.any(ECHO_PORT), true /* reuse address */ );

    while(true) {
        SockAddr clientAddress;
        auto clientSock = listeningSock.accept(clientAddress);
        theReactor.spawnFiber!clientFiber( move(clientSock) );
    }
}

void clientFiber( ConnectedSocket sock ) {
    try {
        while( true ) {
            char[4096] buffer = void;
            auto len = sock.read(buffer, Timeout(CLIENT_TIMEOUT));
            sock.write(buffer[0..len]);

            // Backdoor kill switch to the entire server
            if( len>5 && buffer[4]=='%' ) {
                theReactor.stop(17); // Stop the server with failure
            }
        }
    } catch(TimeoutExpired ex) {
        sock.write("K'bye now\n");
    }
}

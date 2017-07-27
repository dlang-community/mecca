module mecca.reactor.io;


struct ListenerSocket {
}

struct ConnectedSocket {
}

struct DatagramSocket {
}

struct ConnectedDatagramSocket {
}

struct Pipe {
}

struct File {
}

struct WakeableFD {
    // wrap a generic FD and expose waitRead and waitWrite interfaces
    // i.e. eventfd, netlink, etc.
}



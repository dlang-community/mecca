/// Various networking support tools
module mecca.lib.net;

import core.stdc.errno : errno, EINVAL;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.un;
import std.conv;

import mecca.lib.exception;
import mecca.lib.string;

struct SockAddrIPv4 {
    enum PORT_ANY = 0;

    sockaddr_in sa;

    this(in_addr addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        sa.sin_family = AF_INET;
        sa.sin_addr = addr;
        this.port = port;
    }

    this(string addr, ushort port = PORT_ANY) @trusted @nogc {
        int res = inet_pton(AF_INET, toStringzNGC(addr), &sa.sin_addr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv4 address to SockAddrIPv4 constructor");
        }

        sa.sin_family = AF_INET;
        this.port = port;
    }

    @property void port(ushort newPort) nothrow @safe @nogc {
        sa.sin_port = htons(newPort);
    }

    @property ushort port() const pure nothrow @safe @nogc {
        return ntohs(sa.sin_port);
    }

    string toString() nothrow @trusted {
        if( sa.sin_family != AF_INET )
            return "<Invalid IPv4 address>";

        char[INET_ADDRSTRLEN] buffer;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET, &sa.sin_addr, buffer.ptr, INET_ADDRSTRLEN) !is null);

        return to!string(buffer.ptr) ~ ":" ~ to!string(port);
    }

    static SockAddrIPv4 loopback(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(in_addr(htonl(INADDR_LOOPBACK)), port);
    }

    static SockAddrIPv4 any(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(in_addr(htonl(INADDR_ANY)), port);
    }

    static SockAddrIPv4 bcast(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(in_addr(htonl(INADDR_BROADCAST)), port);
    }
}

unittest {
    SockAddrIPv4 s1 = SockAddrIPv4.loopback(1234);
    SockAddrIPv4 s2 = SockAddrIPv4(in_addr(htonl(0x0a0b0c0d)), 1234);

    assertEQ(s1.toString(), "127.0.0.1:1234");
    //assertEQ(s1.addrFixedString(), "127.0.0.1");
    assertEQ(s2.toString(), "10.11.12.13:1234");
    //assertEQ(s2.addrFixedString(), "10.11.12.13");
}

struct SockAddrIPv6 {
    enum PORT_ANY = 0;

    sockaddr_in6 sa;

    this(in6_addr addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        sa.sin6_family = AF_INET6;
        sa.sin6_addr = addr;
        sa.sin6_flowinfo = 0;
        this.port = port;
    }

    this(string addr, ushort port = PORT_ANY) @trusted @nogc {
        int res = inet_pton(AF_INET6, toStringzNGC(addr), &sa.sin6_addr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv6 address to SockAddrIPv6 constructor");
        }

        sa.sin6_family = AF_INET6;
        this.port = port;
    }

    @property void port(ushort newPort) nothrow @safe @nogc {
        sa.sin6_port = htons(newPort);
    }

    @property ushort port() const pure nothrow @safe @nogc {
        return ntohs(sa.sin6_port);
    }

    string toString() nothrow @trusted {
        if( sa.sin6_family != AF_INET6 )
            return "<Invalid IPv6 address>";

        char[INET6_ADDRSTRLEN] buffer;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET6, &sa.sin6_addr, buffer.ptr, INET6_ADDRSTRLEN) !is null);

        return to!string(buffer.ptr) ~ ":" ~ to!string(port);
    }

    static SockAddrIPv6 loopback(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv6(in6addr_loopback, port);
    }

    static SockAddrIPv6 any(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv6(in6addr_any, port);
    }
}

unittest {
    // String translation tests
    in6_addr test_ip6 = in6_addr(['\x11','\x11','\x11','\x11',
                             '\x11','\x11','\x11','\x11',
                             '\x11','\x11','\x11','\x11',
                             '\x11','\x11','\x11','\x11']);

    SockAddrIPv6 s1 = SockAddrIPv6.loopback(1234);
    SockAddrIPv6 s2 = SockAddrIPv6(test_ip6, 1234);

    assertEQ(s1.toString(), "::1:1234");
    // assertEQ(s1.addrFixedString(), "::1");
    assertEQ(s2.toString(), "1111:1111:1111:1111:1111:1111:1111:1111:1234");
    // assertEQ(s2.addrFixedString(), "1111:1111:1111:1111:1111:1111:1111:1111");
}

struct SockAddrUnix {
    sockaddr_un unix;
}

struct SockAddr {
    union {
        sockaddr base = sockaddr(AF_UNSPEC);
        SockAddrIPv4 ipv4;
        SockAddrIPv6 ipv6;
        SockAddrUnix unix;
    }
}

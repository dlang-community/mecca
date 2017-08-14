/// Various networking support tools
module mecca.lib.net;

import core.stdc.errno : errno, EINVAL;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.un;
import core.sys.posix.netdb;
import std.conv;

import mecca.lib.exception;
import mecca.lib.string;

struct IPv4 {
    enum IPv4 loopback  = IPv4(cast(ubyte[])[127, 0, 0, 1]);
    enum IPv4 none      = IPv4(cast(ubyte[])[255, 255, 255, 255]);
    enum IPv4 broadcast = IPv4(cast(ubyte[])[255, 255, 255, 255]);
    enum IPv4 any       = IPv4(cast(ubyte[])[0, 0, 0, 0]);

    union {
        in_addr inaddr = in_addr(0xffffffff);
        struct {
            ubyte[4] bytes;
        }
    }

    this(uint netOrder) nothrow @safe @nogc {
        inaddr.s_addr = netOrder;
    }
    this(ubyte[4] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
    }
    this(in_addr ia) nothrow @safe @nogc {
        inaddr = ia;
    }
    this(string dottedString) @safe @nogc {
        opAssign(dottedString);
    }

    ref typeof(this) opAssign(uint netOrder) nothrow @safe @nogc {
        inaddr.s_addr = netOrder;
        return this;
    }
    ref typeof(this) opAssign(ubyte[4] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
        return this;
    }
    ref typeof(this) opAssign(in_addr ia) nothrow @safe @nogc {
        inaddr = ia;
        return this;
    }
    ref typeof(this) opAssign(string dottedString) @trusted @nogc {
        int res = inet_pton(AF_INET, ToStringz!INET_ADDRSTRLEN(dottedString), &inaddr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv4 address to SockAddrIPv4 constructor");
        }

        return this;
    }

    @property uint netOrder() const pure nothrow @safe @nogc {
        return inaddr.s_addr;
    }
    @property uint hostOrder() const pure nothrow @safe @nogc {
        return ntohl(inaddr.s_addr);
    }
    @property bool isValid() const pure nothrow @safe @nogc {
        return inaddr.s_addr != 0 && inaddr.s_addr != 0xffffffff;
    }

    string toString() const @safe {
        import std.string : format;
        return format("%d.%d.%d.%d", bytes[0], bytes[1], bytes[2], bytes[3]);
    }

    //
    // netmasks
    //
    static IPv4 mask(ubyte bits) nothrow @safe @nogc {
        return IPv4((1 << bits) - 1);
    }

    ubyte maskBits() pure nothrow @safe @nogc {
        if (netOrder == 0) {
            return 0;
        }
        import core.bitop: bsf;
        ASSERT!"not a mask"(isMask);
        int leastSignificantSetBit = bsf(cast(uint)hostOrder);
        auto maskBits = (leastSignificantSetBit.sizeof * 8) - leastSignificantSetBit;
        return cast(byte)maskBits;
    }

    public bool isMask() pure const nothrow @safe @nogc {
        return (~hostOrder & (~hostOrder + 1)) == 0;
    }

    IPv4 opBinary(string op: "&")(IPv4 rhs) const nothrow @safe @nogc {
        return IPv4(inaddr.s_addr & rhs.inaddr.s_addr);
    }

    IPv4 opBinary(string op: "/")(int bits) const nothrow @safe @nogc {
        return IPv4(inaddr.s_addr & ((1 << bits) - 1));
    }
    bool isInSubnet(IPv4 gateway, IPv4 mask) const nothrow @safe @nogc {
        return (gateway & mask) == (this & mask);
    }

    static assert (this.sizeof == in_addr.sizeof);
}


unittest {
    import std.stdio;
    assert(IPv4.loopback.toString() == "127.0.0.1");
    auto ip = IPv4("1.2.3.4");
    assert(ip.toString() == "1.2.3.4");
    assert(ip.netOrder == 0x04030201);
    assert(ip.hostOrder == 0x01020304);

    auto m = ip.mask(24);
    assert(m.toString == "255.255.255.0");
    assert((ip & m) == IPv4("1.2.3.0"));
    assert((ip / 24) == IPv4("1.2.3.0"));
    ip = "172.16.0.195";
    assert(ip.toString == "172.16.0.195");
    ip = IPv4.loopback;
    assert(ip.toString == "127.0.0.1");
    assert(ip.bytes[0] == 127);
}

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

    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for IPv4. %s instead of %s"(sa.sa_family == AF_INET, sa.sa_family, AF_INET);
        ASSERT!"IPv4 sockaddr too short. %s<%s"(length < sockaddr_in.sizeof, length, sockaddr_in.sizeof);
        this.sa = *cast(sockaddr_in*)sa;
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

struct IPv6 {
    enum any = IPv6(cast(ubyte[16])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
    enum loopback = IPv6(cast(ubyte[16])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]);

    enum ADDR_LEN = 16;

    union {
        in6_addr inaddr;
        ubyte[ADDR_LEN] bytes;
    }

    this(ref const in6_addr ia) nothrow @safe @nogc {
        this.inaddr = ia;
    }

    this(ubyte[ADDR_LEN] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
    }

    this(string dottedString) @safe @nogc {
        opAssign(dottedString);
    }
    ref auto opAssign(ref const in6_addr ia) nothrow @safe @nogc {
        this.inaddr = ia;
        return this;
    }
    ref auto opAssign(ubyte[16] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
        return this;
    }
    ref auto opAssign(string dottedString) @trusted @nogc {
        int res = inet_pton(AF_INET6, ToStringz!INET6_ADDRSTRLEN(dottedString), &inaddr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv6 address to SockAddrIPv6 constructor");
        }

        return this;
    }

    /+
        Disabled as it contains an invalid cast from char to immutable(char)

    string toString(char[] buf) @trusted const {
        errnoEnforceNGC(inet_ntop(AF_INET6, bytes.ptr, buf.ptr, cast(uint)buf.length) !is null, "inet_ntop failed");
        return cast(string)fromStringz(buf.ptr);
    }
    +/

    string toString() const @trusted {
        char[INET6_ADDRSTRLEN] buf;
        errnoEnforceNGC(inet_ntop(AF_INET6, bytes.ptr, buf.ptr, buf.length) !is null, "inet_ntop failed");
        return to!string(buf.ptr);
    }

    @property bool isUnspecified() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_UNSPECIFIED(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isLoopback() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_LOOPBACK(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isMulticast() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_MULTICAST(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isLinkLocal() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_LINKLOCAL(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isSiteLocal() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_SITELOCAL(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isV4Mapped() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_V4MAPPED(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isV4Compat() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_V4COMPAT(cast(in6_addr*)&inaddr) != 0;
    }

    static assert (this.sizeof == in6_addr.sizeof, "Incorrect size of struct");
}

unittest {
    assert(IPv6.loopback.toString() == "::1");
    assert(IPv6.loopback.isLoopback);
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

    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for IPv6. %s instead of %s"(sa.sa_family == AF_INET6, sa.sa_family, AF_INET6);
        ASSERT!"IPv4 sockaddr too short. %s<%s"(length < sockaddr_in6.sizeof, length, sockaddr_in6.sizeof);
        this.sa = *cast(sockaddr_in6*)sa;
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

    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for Unix domain sockets. %s instead of %s"(sa.sa_family == AF_UNIX, sa.sa_family, AF_UNIX);
        ASSERT!"Unix domain sockaddr too short. %s<%s"(length < sockaddr_un.sizeof, length, sockaddr_un.sizeof);
        this.unix = *cast(sockaddr_un*)sa;
    }

    string toString() @trusted {
        import std.string;

        if( unix.sun_family != AF_UNIX )
            return "<Invalid Unix domain address>";

        if( unix.sun_path[0] == '\0' )
            return "<Anonymous Unix domain address>";

        auto idx = indexOf(cast(char[])(unix.sun_path[]), cast(byte)'\0');
        if( idx<0 )
            idx = unix.sun_path.length;

        return to!string(unix.sun_path[0..idx]);
    }
}

struct SockAddr {
    union {
        sockaddr base = sockaddr(AF_UNSPEC);
        SockAddrIPv4 ipv4;
        SockAddrIPv6 ipv6;
        SockAddrUnix unix;
    }

    this(const sockaddr* sa, socklen_t length) nothrow @safe @nogc {
        switch(sa.sa_family) {
        case AF_INET:
            this.ipv4 = SockAddrIPv4(sa, length);
            break;
        case AF_INET6:
            this.ipv6 = SockAddrIPv6(sa, length);
            break;
        case AF_UNIX:
            this.unix = SockAddrUnix(sa, length);
            break;
        default:
            ASSERT!"SockAddr constructor called with invalid family %s"(false, sa.sa_family);
        }
    }

    this(SockAddrIPv4 sa) {
        ipv4 = sa;
        ASSERT!"Called with mismatching address family. Expected IPv4(%s), got %s"( AF_INET == family, AF_INET, family );
    }

    this(SockAddrIPv6 sa) {
        ipv6 = sa;
        ASSERT!"Called with mismatching address family. Expected IPv6(%s), got %s"( AF_INET6 == family, AF_INET6, family );
    }

    this(SockAddrUnix sa) {
        unix = sa;
        ASSERT!"Called with mismatching address family. Expected Unix domain(%s), got %s"( AF_UNIX == family, AF_UNIX, family );
    }

    @property sa_family_t family() const pure @safe @nogc {
        return base.sa_family;
    }

    string toString() @safe {
        switch( family ) {
        case AF_UNSPEC:
            return "<Uninitialized socket address>";
        case AF_INET:
            return ipv4.toString();
        case AF_INET6:
            return ipv6.toString();
        case AF_UNIX:
            return unix.toString();

        default:
            return "<Unsupported socket address family>";
        }
    }

    static SockAddr resolve(string hostname, string service, ushort family = AF_INET, int sockType = 0) @trusted {
        ASSERT!"Invalid family %s"(family == AF_INET || family == AF_INET6, family);

        addrinfo* res = null;
        addrinfo hint;
        hint.ai_family = family;
        hint.ai_socktype = sockType;

        auto rc = getaddrinfo(hostname.toStringzNGC, service.toStringzNGC, &hint, &res);
        if( rc!=0 ) {
            throw mkExFmt!Exception("Lookup failed for %s:%s: %s", hostname, service, to!string(gai_strerror(rc)));
        }
        if( res is null ) {
            throw mkExFmt!Exception("Lookup for %s:%s returned no results", hostname, service);
        }
        scope(exit) freeaddrinfo(res);

        return SockAddr(res.ai_addr, res.ai_addrlen);
    }
}

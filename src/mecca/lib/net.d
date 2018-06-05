/// Various networking support tools
module mecca.lib.net;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import core.stdc.errno : errno, EINVAL;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.un;
import core.sys.posix.netdb;
import std.conv;

import mecca.containers.arrays: FixedString, setStringzLength;
import mecca.lib.exception;
import mecca.lib.string;
import mecca.log;

/// An IPv4 address
@FMT("{bytes[0]}.{bytes[1]}.{bytes[2]}.{bytes[3]}")
struct IPv4 {
    enum IPv4 loopback  = IPv4(cast(ubyte[])[127, 0, 0, 1]);            /// Lookpack address
    enum IPv4 none      = IPv4(cast(ubyte[])[255, 255, 255, 255]);      /// No address
    enum IPv4 broadcast = IPv4(cast(ubyte[])[255, 255, 255, 255]);      /// Broadcast address
    enum IPv4 any       = IPv4(cast(ubyte[])[0, 0, 0, 0]);              /// "Any" address (for local binding)

    union {
        in_addr inaddr = in_addr(0xffffffff);   /// Address as an `in_addr`
        ubyte[4] bytes;                         /// Address as array of bytes
    }

    /// Construct an IPv4 address
    this(uint netOrder) pure nothrow @safe @nogc {
        inaddr.s_addr = netOrder;
    }
    /// ditto
    this(ubyte[4] bytes) pure nothrow @safe @nogc {
        this.bytes = bytes;
    }
    /// ditto
    this(in_addr ia) pure nothrow @safe @nogc {
        inaddr = ia;
    }
    /// ditto
    this(string dottedString) @safe @nogc {
        opAssign(dottedString);
    }

    /// Assignment
    ref typeof(this) opAssign(uint netOrder) pure nothrow @safe @nogc {
        inaddr.s_addr = netOrder;
        return this;
    }
    /// ditto
    ref typeof(this) opAssign(ubyte[4] bytes) pure nothrow @safe @nogc {
        this.bytes = bytes;
        return this;
    }
    /// ditto
    ref typeof(this) opAssign(in_addr ia) pure nothrow @safe @nogc {
        inaddr = ia;
        return this;
    }
    /// ditto
    ref typeof(this) opAssign(string dottedString) @trusted @nogc {
        int res = inet_pton(AF_INET, ToStringz!INET_ADDRSTRLEN(dottedString), &inaddr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv4 address to SockAddrIPv4 constructor");
        }

        return this;
    }

    /// Return the address in network order
    @property uint netOrder() const pure nothrow @safe @nogc {
        return inaddr.s_addr;
    }
    /// Return the address in host order
    @property uint hostOrder() const pure nothrow @safe @nogc {
        return ntohl(inaddr.s_addr);
    }
    /// Is the address a valid one
    ///
    /// The broadcast address is not considered valid.
    @property bool isValid() const pure nothrow @safe @nogc {
        return inaddr.s_addr != 0 && inaddr.s_addr != 0xffffffff;
    }

    /// Return a GC allocated string for the address (dot notation)
    string toString() const nothrow @trusted {
        char[INET_ADDRSTRLEN] buffer;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET, &inaddr, buffer.ptr, INET_ADDRSTRLEN) !is null);

        return to!string(buffer.ptr);
    }

    //
    // netmasks
    //
    /// Return a mask corresponding to a network of 2^^bits addresses
    static IPv4 mask(ubyte bits) nothrow @safe @nogc {
        return IPv4((1 << bits) - 1);
    }

    /// Return how many bits in the current mask
    ///
    /// Object must be initialized to a valid mask address
    ubyte maskBits() pure nothrow @safe @nogc {
        if (netOrder == 0) {
            return 0;
        }
        import core.bitop: bsf;
        assert(isMask, "not a mask");
        int leastSignificantSetBit = bsf(cast(uint)hostOrder);
        auto maskBits = (leastSignificantSetBit.sizeof * 8) - leastSignificantSetBit;
        return cast(byte)maskBits;
    }

    /// Return whether current address is a valid mask address
    public bool isMask() pure const nothrow @safe @nogc {
        return (~hostOrder & (~hostOrder + 1)) == 0;
    }

    /// Return the intersection of the two addresses
    ///
    /// This is useful to extract network name and client name from an address
    IPv4 opBinary(string op: "&")(IPv4 rhs) const nothrow @safe @nogc {
        return IPv4(inaddr.s_addr & rhs.inaddr.s_addr);
    }

    /// Returns whether our IP and host are in the same network
    bool isInSubnet(IPv4 host, IPv4 mask) const nothrow @safe @nogc {
        assert(mask.isMask, "mask argument is not valid");
        return (host & mask) == (this & mask);
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
    ip = "172.16.0.195";
    assert(ip.toString == "172.16.0.195");
    ip = IPv4.loopback;
    assert(ip.toString == "127.0.0.1");
    assert(ip.bytes[0] == 127);
}

/// A D representation of the `sockaddr_in` struct
struct SockAddrIPv4 {
    /// Unspecified port constant
    enum PORT_ANY = 0;

    /// the underlying `sockaddr_in` struct
    sockaddr_in sa;

    /// Construct a SockAddrIPv4
    this(in_addr addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        sa.sin_family = AF_INET;
        sa.sin_addr = addr;
        this.port = port;
    }

    /// ditto
    this(string addr, ushort port = PORT_ANY) @trusted @nogc {
        int res = inet_pton(AF_INET, toStringzNGC(addr), &sa.sin_addr);

        DBG_ASSERT!"Invalid call to inet_pton(%s)"(res>=0, addr);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv4 address to SockAddrIPv4 constructor");
        }

        sa.sin_family = AF_INET;
        this.port = port;
    }

    /// ditto
    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for IPv4. %s instead of %s"(sa.sa_family == AF_INET, sa.sa_family, AF_INET);
        ASSERT!"IPv4 sockaddr too short. %s<%s"(length >= sockaddr_in.sizeof, length, sockaddr_in.sizeof);
        this.sa = *cast(sockaddr_in*)sa;
    }

    /// ditto
    this(IPv4 addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        this(addr.inaddr, port);
    }

    /// Get/set the sa's port in $(B host) byte order
    @property void port(ushort newPort) nothrow @safe @nogc {
        sa.sin_port = htons(newPort);
    }

    /// ditto
    @property ushort port() const pure nothrow @safe @nogc {
        return ntohs(sa.sin_port);
    }

    /// Get/set the sa's addr
    @property void addr(IPv4 address) nothrow @safe @nogc {
        sa.sin_addr = address.inaddr;
    }

    /// ditto
    @property IPv4 addr() const pure nothrow @safe @nogc {
        return IPv4(sa.sin_addr);
    }

    /// Convert the address to GC allocated string in the format addr:port
    string toString() const nothrow @safe {
        return toStringAddr() ~ ":" ~ toStringPort();
    }

    /// Convert just the address part to a GC allocated string
    string toStringAddr() const nothrow @safe {
        if( sa.sin_family != AF_INET )
            return "<Invalid IPv4 address>";

        return IPv4(sa.sin_addr).toString();
    }

    auto toFixedStringAddr() const nothrow @trusted @nogc {
        ASSERT!"Address family is %s, not IPv4"( sa.sin_family == AF_INET, sa.sin_family );

        FixedString!INET_ADDRSTRLEN buf;
        buf.length = buf.capacity;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET, &sa.sin_addr, buf.ptr, buf.len) !is null);
        setStringzLength(buf);

        return buf;
    }

    /// Convert just the port part to a GC allocated string
    string toStringPort() const nothrow @safe {
        if( port!=PORT_ANY )
            return to!string(port);
        else
            return "*";
    }

    /// Construct a loopback sockaddr for the given port
    static SockAddrIPv4 loopback(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(IPv4.loopback, port);
    }

    /// Construct an any sockaddr for the given port
    static SockAddrIPv4 any(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(IPv4.any, port);
    }

    /// Construct a broadcast sockaddr for the given port
    static SockAddrIPv4 broadcast(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv4(IPv4.broadcast, port);
    }
}

unittest {
    SockAddrIPv4 s1 = SockAddrIPv4.loopback(1234);
    SockAddrIPv4 s2 = SockAddrIPv4(in_addr(htonl(0x0a0b0c0d)));

    assertEQ(s1.toString(), "127.0.0.1:1234");
    assertEQ(s1.toStringAddr(), "127.0.0.1");
    assertEQ(s1.toFixedStringAddr(), "127.0.0.1");
    assertEQ(s1.toStringPort(), "1234");
    //assertEQ(s1.addrFixedString(), "127.0.0.1");
    assertEQ(s2.toString(), "10.11.12.13:*");
    //assertEQ(s2.addrFixedString(), "10.11.12.13");
}

/// An IPv6 address
struct IPv6 {
    enum any = IPv6(cast(ubyte[ADDR_LEN])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);            /// "Any" address (for local binding)
    enum loopback = IPv6(cast(ubyte[ADDR_LEN])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]);       /// Loopback address

    enum ADDR_LEN = 16; /// Length of an IPv6 address

    union {
        in6_addr inaddr;        /// Address as `in6_addr`
        ubyte[ADDR_LEN] bytes;  /// Address as array of bytes
    }

    /// Construct an IPv6 address
    this(ref const in6_addr ia) nothrow @safe @nogc {
        this.inaddr = ia;
    }

    /// ditto
    this(ubyte[ADDR_LEN] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
    }

    /// ditto
    this(string dottedString) @safe @nogc {
        opAssign(dottedString);
    }
    /// Assignment
    ref auto opAssign(ref const in6_addr ia) nothrow @safe @nogc {
        this.inaddr = ia;
        return this;
    }
    /// ditto
    ref auto opAssign(ubyte[16] bytes) nothrow @safe @nogc {
        this.bytes = bytes;
        return this;
    }
    /// ditto
    ref auto opAssign(string dottedString) @trusted @nogc {
        int res = inet_pton(AF_INET6, ToStringz!INET6_ADDRSTRLEN(dottedString), &inaddr);

        DBG_ASSERT!"Invalid call to inet_pton"(res>=0);
        if( res!=1 ) {
            errno = EINVAL;
            throw mkEx!ErrnoException("Invalid IPv6 address to SockAddrIPv6 constructor");
        }

        return this;
    }

    /// Return a GC allocated string for the address (colon notation)
    string toString() const @trusted {
        char[INET6_ADDRSTRLEN] buf;
        errnoEnforceNGC(inet_ntop(AF_INET6, bytes.ptr, buf.ptr, buf.length) !is null, "inet_ntop failed");
        return to!string(buf.ptr);
    }

    /// Returns true if this is the unspecified address
    @property bool isUnspecified() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_UNSPECIFIED(cast(in6_addr*)&inaddr) != 0;
    }
    /// Returns true if this is the loopback address
    @property bool isLoopback() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_LOOPBACK(cast(in6_addr*)&inaddr) != 0;
    }
    /// Returns true if this is a multicast address
    @property bool isMulticast() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_MULTICAST(cast(in6_addr*)&inaddr) != 0;
    }
    /// Returns true if this is a link local address
    @property bool isLinkLocal() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_LINKLOCAL(cast(in6_addr*)&inaddr) != 0;
    }
    /// Returns true if this is a site local address
    @property bool isSiteLocal() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_SITELOCAL(cast(in6_addr*)&inaddr) != 0;
    }
    @property bool isV4Mapped() pure const @trusted @nogc {
        // DMDBUG the "macro" is incorrectly defined, which means we have to cast away constness here
        return IN6_IS_ADDR_V4MAPPED(cast(in6_addr*)&inaddr) != 0;
    }
    /// Returns true if this address is in the IPv4 range
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

/// A D representation of the `sockaddr_in6` struct
struct SockAddrIPv6 {
    /// Unspecified port constant
    enum PORT_ANY = 0;

    /// the underlying `sockaddr_in6` struct
    sockaddr_in6 sa;

    /// Construct a SockAddrIPv6
    this(in6_addr addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        sa.sin6_family = AF_INET6;
        sa.sin6_addr = addr;
        sa.sin6_flowinfo = 0;
        this.port = port;
    }

    /// ditto
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

    /// ditto
    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for IPv6. %s instead of %s"(sa.sa_family == AF_INET6, sa.sa_family, AF_INET6);
        ASSERT!"IPv4 sockaddr too short. %s<%s"(length < sockaddr_in6.sizeof, length, sockaddr_in6.sizeof);
        this.sa = *cast(sockaddr_in6*)sa;
    }

    /// ditto
    this(IPv6 addr, ushort port = PORT_ANY) nothrow @safe @nogc {
        this(addr.inaddr, port);
    }

    /// Get/set the sa's port in $(B host) byte order
    @property void port(ushort newPort) nothrow @safe @nogc {
        sa.sin6_port = htons(newPort);
    }

    /// ditto
    @property ushort port() const pure nothrow @safe @nogc {
        return ntohs(sa.sin6_port);
    }

    /// Convert the address to GC allocated string in the format addr:port
    string toString() const nothrow @safe {
        return toStringAddr() ~ ":" ~ toStringPort();
    }

    /// Convert just the address part to a GC allocated string
    string toStringAddr() const nothrow @trusted {
        if( sa.sin6_family != AF_INET6 )
            return "<Invalid IPv6 address>";

        char[INET6_ADDRSTRLEN] buffer;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET6, &sa.sin6_addr, buffer.ptr, INET6_ADDRSTRLEN) !is null);

        return to!string(buffer.ptr);
    }

    auto toFixedStringAddr() const nothrow @trusted @nogc {
        ASSERT!"Address family is %s, not IPv6"( sa.sin6_family == AF_INET6, sa.sin6_family );

        FixedString!INET6_ADDRSTRLEN buf;
        buf.length = buf.capacity;
        ASSERT!"Address translation failed"(inet_ntop(AF_INET6, &sa.sin6_addr, buf.ptr, buf.len) !is null);
        setStringzLength(buf);

        return buf;
    }

    /// Convert just the port part to a GC allocated string
    string toStringPort() const nothrow @safe {
        if( port!=PORT_ANY )
            return to!string(port);
        else
            return "*";
    }

    /// Construct a loopback sockaddr for the given port
    static SockAddrIPv6 loopback(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv6(IPv6.loopback, port);
    }

    /// Construct an any sockaddr for the given port
    static SockAddrIPv6 any(ushort port = PORT_ANY) nothrow @safe @nogc {
        return SockAddrIPv6(IPv6.any, port);
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
    assertEQ(s1.toFixedStringAddr(), "::1");
    assertEQ(s2.toString(), "1111:1111:1111:1111:1111:1111:1111:1111:1234");
    assertEQ(s2.toFixedStringAddr(), "1111:1111:1111:1111:1111:1111:1111:1111");
}

/// A D representation of the `sockaddr_un` struct
struct SockAddrUnix {
    /// the underlying `sockaddr_in` struct
    sockaddr_un unix = void;

    /// Construct a SockAddrUnix
    this(const sockaddr* sa, socklen_t length) nothrow @trusted @nogc {
        ASSERT!"Wrong address family for Unix domain sockets. %s instead of %s"(sa.sa_family == AF_UNIX, sa.sa_family, AF_UNIX);
        ASSERT!"Unix domain sockaddr too short. %s<%s"(length < sockaddr_un.sizeof, length, sockaddr_un.sizeof);
        this.unix = *cast(sockaddr_un*)sa;
    }

    /// ditto
    this(string path) nothrow @trusted @nogc {
        unix.sun_family = AF_UNIX;
        unix.sun_path[0..path.length][] = cast(immutable(byte)[])path[];
        if( path.length < unix.sun_path.length )
            unix.sun_path[path.length] = '\0';
    }

    /// Convert the address to GC allocated string
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

/// A D representation of a `sockaddr` struct
///
/// This is how `sockaddr` might have looked like had C supported inheritence
struct SockAddr {
    align(1):
    union {
        sockaddr base = sockaddr(AF_UNSPEC);    /// SockAddr as a `sockaddr`
        SockAddrIPv4 ipv4;                      /// SockAddr as a SockAddrIPv4
        SockAddrIPv6 ipv6;                      /// SockAddr as a SockAddrIPv6
        SockAddrUnix unix;                      /// SockAddr as a SockAddrUnix
    }

    /// Construct a SockAddr
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

    /// ditto
    this(SockAddrIPv4 sa) nothrow @safe @nogc {
        ipv4 = sa;
        ASSERT!"Called with mismatching address family. Expected IPv4(%s), got %s"( AF_INET == family, AF_INET, family );
    }

    /// ditto
    this(SockAddrIPv6 sa) nothrow @safe @nogc {
        ipv6 = sa;
        ASSERT!"Called with mismatching address family. Expected IPv6(%s), got %s"( AF_INET6 == family, AF_INET6, family );
    }

    /// ditto
    this(SockAddrUnix sa) nothrow @safe @nogc {
        unix = sa;
        ASSERT!"Called with mismatching address family. Expected Unix domain(%s), got %s"( AF_UNIX == family, AF_UNIX, family );
    }

    /// Return the address family
    @property sa_family_t family() const pure nothrow @safe @nogc {
        return base.sa_family;
    }

    /// Return a GC allocated string representing the address
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

    /// Convert just the address part to a GC allocated string
    string toStringAddr() @safe {
        switch( family ) {
        case AF_UNSPEC:
            return "<Uninitialized socket address>";
        case AF_INET:
            return ipv4.toStringAddr();
        case AF_INET6:
            return ipv6.toStringAddr();
        case AF_UNIX:
            return unix.toString();

        default:
            return "<Unsupported socket address family>";
        }
    }

    /// Convert just the port part to a GC allocated string
    string toStringPort() @safe {
        switch( family ) {
        case AF_UNSPEC:
            return "<Uninitialized socket address>";
        case AF_INET:
            return ipv4.toStringPort();
        case AF_INET6:
            return ipv6.toStringPort();
        case AF_UNIX:
            return "<Portless address family AF_UNIX>";

        default:
            return "<Unsupported socket address family>";
        }
    }

    /// Perform a name resolution on the given string
    static SockAddr resolve(string hostname, string service = null, ushort family = AF_INET, int sockType = 0) @trusted
    {
        ASSERT!"Invalid family %s"(family == AF_INET || family == AF_INET6, family);

        addrinfo* res = null;
        addrinfo hint;
        hint.ai_family = family;
        hint.ai_socktype = sockType;

        auto rc = getaddrinfo(hostname.toStringzNGC, ToStringz!512(service), &hint, &res);
        if( rc!=0 ) {
            throw mkExFmt!Exception("Lookup failed for %s:%s: %s", hostname, service, to!string(gai_strerror(rc)));
        }
        if( res is null ) {
            throw mkExFmt!Exception("Lookup for %s:%s returned no results", hostname, service);
        }
        scope(exit) freeaddrinfo(res);

        return SockAddr(res.ai_addr, res.ai_addrlen);
    }

    unittest {
        auto addr = SockAddr.resolve("localhost", "ssh");
        assertEQ( addr.toString(), "127.0.0.1:22" );
        addr = SockAddr.resolve("localhost");
        assertEQ( addr.toString(), "127.0.0.1:*" );
    }

    /// Returns the length of the data in the struct
    ///
    /// This is needed for underlying system calls that accept `sockaddr`
    @property uint len() const pure nothrow @safe @nogc {
        switch(family) {
        case AF_UNSPEC:
            return SockAddr.sizeof;
        case AF_INET:
            return SockAddrIPv4.sizeof;
        case AF_INET6:
            return SockAddrIPv6.sizeof;
        case AF_UNIX:
            return SockAddrUnix.sizeof;
        default:
            assert(false, "Unknown family");
        }
    }
}

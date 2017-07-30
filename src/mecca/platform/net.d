module mecca.platform.net;

import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import core.sys.posix.netinet.tcp;
import core.sys.posix.netdb;

import std.conv: to;
import std.string;
import std.exception;


struct IP4 {
    enum IP4 loopback  = IP4(cast(ubyte[])[127, 0, 0, 1]);
    enum IP4 none      = IP4(cast(ubyte[])[255, 255, 255, 255]);
    enum IP4 broadcast = IP4(cast(ubyte[])[255, 255, 255, 255]);
    enum IP4 any       = IP4(cast(ubyte[])[0, 0, 0, 0]);

    union {
        in_addr inaddr = in_addr(0xffffffff);
        struct {
            ubyte[4] bytes;
        }
    }

    this(uint netOrder) {
        inaddr.s_addr = netOrder;
    }
    this(ubyte[4] bytes) {
        this.bytes = bytes;
    }
    this(in_addr ia) {
        inaddr = ia;
    }
    this(string dottedString) {
        opAssign(dottedString);
    }

    ref typeof(this) opAssign(uint netOrder) {
        inaddr.s_addr = netOrder;
        return this;
    }
    ref typeof(this) opAssign(ubyte[4] bytes) {
        this.bytes = bytes;
        return this;
    }
    ref typeof(this) opAssign(in_addr ia) {
        inaddr = ia;
        return this;
    }
    ref typeof(this) opAssign(string dottedString) {
        auto parts = dottedString.split(".");
        enforce(parts.length == 4);
        foreach(i, ref b; bytes) {
            b = parts[i].to!ubyte;
        }
        return this;
    }

    @property uint netOrder() const pure nothrow @nogc {
        return inaddr.s_addr;
    }
    @property uint hostOrder() const pure nothrow @nogc {
        return ntohl(inaddr.s_addr);
    }
    @property bool isValid() const {
        return inaddr.s_addr != 0 && inaddr.s_addr != 0xffffffff;
    }

    string toString() @safe const {
        return format("%d.%d.%d.%d", bytes[0], bytes[1], bytes[2], bytes[3]);
    }

    //
    // netmasks
    //
    static IP4 mask(ubyte bits) {
        return IP4((1 << bits) - 1);
    }
    ubyte bits() {
        if (netOrder == 0) {
            return 0;
        }
        import core.bitop: bsf;
        assert(isMask, "not a mask");
        int leastSignificantSetBit = bsf(cast(uint)hostOrder);
        auto maskBits = (leastSignificantSetBit.sizeof * 8) - leastSignificantSetBit;
        return maskBits.to!byte;
    }
    public bool isMask() {
        return (~hostOrder & (~hostOrder + 1)) == 0;
    }
    IP4 opBinary(string op: "&")(IP4 rhs) const {
        return IP4(inaddr.s_addr & rhs.inaddr.s_addr);
    }
    IP4 opBinary(string op: "/")(int bits) const {
        return IP4(inaddr.s_addr & ((1 << bits) - 1));
    }
    bool isInSubnet(IP4 gateway, IP4 mask) const {
        return (gateway & mask) == (this & mask);
    }

    static assert (this.sizeof == in_addr.sizeof);
}


unittest {
    import std.stdio;
    assert(IP4.loopback.toString() == "127.0.0.1");
    auto ip = IP4("1.2.3.4");
    assert(ip.toString() == "1.2.3.4");
    assert(ip.netOrder == 0x04030201);
    assert(ip.hostOrder == 0x01020304);

    auto m = ip.mask(24);
    assert(m.toString == "255.255.255.0");
    assert((ip & m) == IP4("1.2.3.0"));
    assert((ip / 24) == IP4("1.2.3.0"));
    ip = "172.16.0.195";
    assert(ip.toString == "172.16.0.195");
    ip = IP4.loopback;
    assert(ip.toString == "127.0.0.1");
    assert(ip.bytes[0] == 127);
}


struct IP6 {
    enum any = IP6(cast(ubyte[16])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]);
    enum loopback = IP6(cast(ubyte[16])[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]);

    ubyte[16] bytes;

    this(ref const in6_addr ia) {
        this.bytes = cast(ubyte[16])((cast(ubyte*)&ia)[0 .. 16]);
    }
    this(ubyte[16] bytes) {
        this.bytes = bytes;
    }
    this(string dottedString) {
        enforce(inet_pton(AF_INET6, toStringz(dottedString), bytes.ptr) == 1, "inet_pton failed: '" ~ dottedString ~ "'");
    }
    ref auto opAssign(ref const in6_addr ia) {
        this.bytes = cast(ubyte[16])((cast(ubyte*)&ia)[0 .. 16]);
        return this;
    }
    ref auto opAssign(ubyte[16] bytes) {
        this.bytes = bytes;
        return this;
    }
    ref auto opAssign(string dottedString) {
        enforce(inet_pton(AF_INET6, toStringz(dottedString), bytes.ptr) == 1, "inet_pton failed: '" ~ dottedString ~ "'");
        return this;
    }
    @property ref in6_addr as_in6addr() {
        return *(cast(in6_addr*)bytes.ptr);
    }

    string toString(char[] buf) @trusted const {
        errnoEnforce(inet_ntop(AF_INET6, bytes.ptr, buf.ptr, cast(uint)buf.length) !is null, "inet_ntop failed");
        return cast(string)fromStringz(buf.ptr);
    }
    string toString() @trusted const {
        char[INET6_ADDRSTRLEN] buf;
        errnoEnforce(inet_ntop(AF_INET6, bytes.ptr, buf.ptr, buf.length) !is null, "inet_ntop failed");
        return to!string(buf.ptr);
    }

    @property bool isUnspecified() pure const {
        return IN6_IS_ADDR_UNSPECIFIED(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isLoopback() pure const {
        return IN6_IS_ADDR_LOOPBACK(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isMulticast() pure const {
        return IN6_IS_ADDR_MULTICAST(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isLinkLocal() pure const {
        return IN6_IS_ADDR_LINKLOCAL(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isSiteLocal() pure const {
        return IN6_IS_ADDR_SITELOCAL(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isV4Mapped() pure const {
        return IN6_IS_ADDR_V4MAPPED(cast(in6_addr*)bytes.ptr) != 0;
    }
    @property bool isV4Compat() pure const {
        return IN6_IS_ADDR_V4COMPAT(cast(in6_addr*)bytes.ptr) != 0;
    }

    static assert (this.sizeof == in6_addr.sizeof);
}

unittest {
    assert(IP6.loopback.toString() == "::1");
    assert(IP6.loopback.isLoopback);
}


struct SockAddr {
    enum maxLength = sin6.sizeof;

    union {
        struct {
            sa_family_t family;
            in_port_t   portNBO;
        }
        sockaddr_in   sin4;
        sockaddr_in6  sin6;
    }
    socklen_t length;

    @property ushort port() const @nogc {
        return ntohs(portNBO);
    }
    @property void port(ushort newPort) @nogc {
        portNBO = htons(newPort);
    }

    @property sockaddr* asSockaddr(this T)() {
        return cast(sockaddr*)&sin4;
    }

    @property ref IP4 ip4() {
        enforce(family == AF_INET, "Not IPv4");
        return *(cast(IP4*)&sin4.sin_addr);
    }
    @property ref IP6 ip6() {
        enforce(family == AF_INET6, "Not IPv6");
        return *(cast(IP6*)&sin6.sin6_addr);
    }

    @property string ipString() {
        if (family == AF_INET) {
            return ip4.toString();
        }
        else if (family == AF_INET6) {
            return ip6.toString();
        }
        else {
            return "<Invalid address family>";
        }
    }

    string toString() {
        if (family == AF_INET) {
            return "%s:%s".format(ip4.toString(), port);
        }
        else if (family == AF_INET6) {
            return "[%s]:%s".format(ip6.toString(), port);
        }
        else {
            return "<Invalid address family>";
        }
    }

    static SockAddr loopback4(ushort port=0) {
        SockAddr ep;
        ep.sin4.sin_addr = IP4.loopback.inaddr;
        ep.length = sin4.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr loopback6(ushort port=0) {
        SockAddr ep;
        ep.sin6.sin6_addr = in6addr_loopback;
        ep.length = sin6.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr any4(ushort port=0) {
        SockAddr ep;
        ep.sin4.sin_addr = IP4.any.inaddr;
        ep.length = sin4.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr any6(ushort port=0) {
        SockAddr ep;
        ep.sin6.sin6_addr = in6addr_any;
        ep.length = sin6.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr getSockName(int fd) {
        SockAddr ep;
        ep.length = maxLength;
        errnoEnforce(getsockname(fd, ep.asSockaddr, &ep.length) == 0, "getsockname() failed");
        return ep;
    }

    static SockAddr getPeerName(int fd) {
        SockAddr ep;
        ep.length = maxLength;
        errnoEnforce(getpeername(fd, ep.asSockaddr, &ep.length) == 0, "getpeername() failed");
        return ep;
    }

    static SockAddr resolve4(string hostname, string service = "") {
        return resolve(hostname, service);
    }
    static SockAddr resolve4(string hostname, ushort port) {
        return resolve(hostname, to!string(port));
    }
    static SockAddr resolve6(string hostname, string service = "") {
        return resolve(hostname, service, AF_INET6);
    }
    static SockAddr resolve6(string hostname, ushort port) {
        return resolve(hostname, to!string(port), AF_INET6);
    }

    static SockAddr resolve(string hostname, string service, ushort family = AF_INET, int sockType = SOCK_STREAM) {
        enforce(family == AF_INET || family == AF_INET6, "invalid family " ~ to!string(family));

        addrinfo* res = null;
        addrinfo hint;
        hint.ai_family = family;
        hint.ai_socktype = sockType;

        auto rc = getaddrinfo(hostname.toStringz, service.toStringz, &hint, &res);
        enforce(rc == 0, hostname ~ ":" ~ service ~ " - " ~ to!string(gai_strerror(rc)));
        enforce(res !is null, hostname ~ ":" ~ service ~ " - no results");
        scope(exit) freeaddrinfo(res);

        SockAddr ep;

        for (auto curr = res; curr !is null; curr = curr.ai_next) {
            if (family == AF_INET && curr.ai_addrlen == sockaddr_in.sizeof) {
                ep.sin4 = *(cast(sockaddr_in*)curr.ai_addr);
                ep.length = sockaddr_in.sizeof;
                return ep;
            }
            else if (family == AF_INET6 && curr.ai_addrlen == sockaddr_in6.sizeof) {
                ep.sin6 = *(cast(sockaddr_in6*)curr.ai_addr);
                ep.length = sockaddr_in6.sizeof;
                return ep;
            }
        }

        throw new Exception(hostname ~ ":" ~ service ~ " - no results");
    }
}


unittest {
    auto sa = SockAddr.resolve4("localhost", 12345);
    assert(sa.toString == "127.0.0.1:12345", sa.toString);
    assert(sa.ip4.toString == "127.0.0.1", sa.ip4.toString);
    assert(sa.family == AF_INET);

    sa = SockAddr.resolve6("::1" /+"ip6-localhost" -- not always the name +/, 12345);
    assert(sa.toString == "[::1]:12345");
    assert(sa.family == AF_INET6);
    assert(sa.ip6.toString == "::1");
}




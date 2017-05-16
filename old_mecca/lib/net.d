module mecca.lib.net;

import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.sys.types;
import core.sys.posix.netinet.tcp;
import core.sys.posix.netdb;

import std.exception;
import std.string;
import std.json;
import std.conv;

import mecca.lib.tracing;
import mecca.containers.array;

extern(C) size_t strnlen(const char *s, size_t maxlen);

alias IP4FixedString = FixedString!INET_ADDRSTRLEN;


@FMT("{a}.{b}.{c}.{d}")
struct IP4 {
    enum IP4 loopback = IP4(127, 0, 0, 1);
    enum IP4 none = IP4(255, 255, 255, 255);
    enum IP4 broadcast = IP4(255, 255, 255, 255);
    enum IP4 any = IP4(0, 0, 0, 0);
    enum max = none;

    ubyte a = 255;
    ubyte b = 255;
    ubyte c = 255;
    ubyte d = 255;

    this(in_addr ia) {
        this(ia.s_addr);
    }
    this(uint netOrder) {
        *(cast(uint*)&this) = netOrder;
    }
    this(ubyte a, ubyte b, ubyte c, ubyte d) {
        this.a = a;
        this.b = b;
        this.c = c;
        this.d = d;
    }
    this(string dottedString) {
        if (dottedString.strip.length == 0) {
            a = b = c = d = 0;
        }
        else {
            if (__ctfe) {
                auto parts = dottedString.split(".");
                enforce(parts.length == 4, dottedString);
                a = to!ubyte(parts[0]);
                b = to!ubyte(parts[1]);
                c = to!ubyte(parts[2]);
                d = to!ubyte(parts[3]);
            }
            else {
                enforce(inet_pton(AF_INET, toStringz(dottedString), &this) == 1, "inet_pton failed: '" ~ dottedString ~ "'");
            }
        }
    }
    @property ref ubyte[4] bytes() {
        return *(cast(ubyte[4]*)&this);
    }
    ref typeof(this) opAssign(uint netOrder) {
        *(cast(uint*)&this) = netOrder;
        return this;
    }
    ref typeof(this) opAssign(in_addr ia) {
        return opAssign(ia.s_addr);
    }
    ref typeof(this) opAssign(string dottedString) {
        if (dottedString.strip.length == 0) {
            *(cast(uint*)&this) = 0;
        }
        else {
            enforce(inet_pton(AF_INET, toStringz(dottedString), &this) == 1, "inet_pton failed: '" ~ dottedString ~ "'");
        }
        return this;
    }

    @property uint netOrder() const {
        return *(cast(uint*)&this);
    }
    @property uint hostOrder() const {
        return ntohl(*(cast(uint*)&this));
    }
    static IP4 fromHostOrder(uint hostOrder) {
        return IP4(htonl(hostOrder));
    }
    @property ref in_addr as_inaddr() {
        return *(cast(in_addr*)&this);
    }
    @property bool isValid() const {
        return *(cast(uint*)&this) != 0 && *(cast(uint*)&this) != 0xffffffff;
    }

    string toString() @trusted const {
        return format("%d.%d.%d.%d", a, b, c, d);
    }

    static @("notrace") IP4 mask(ubyte bits) {
        return IP4(((1 << bits) - 1));
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
        return IP4(*(cast(uint*)&this) & *(cast(uint*)&rhs));
    }
    IP4 opBinary(string op: "/")(int bits) const {
        return IP4(*(cast(uint*)&this) & ((1 << bits) - 1));
    }
    bool isInSubnet(IP4 gateway, IP4 mask) const {
        return (gateway & mask) == (this & mask);
    }

    @notrace JSONValue toJSON() const {
        return JSONValue(toString());
    }
    @notrace void fromJSON(JSONValue jv) {
        auto parts = jv.str.split(".");
        a = parts[0].to!ubyte;
        b = parts[1].to!ubyte;
        c = parts[2].to!ubyte;
        d = parts[3].to!ubyte;
    }

    static assert (this.sizeof == in_addr.sizeof);

    alias netOrder this;
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

@("notrace") struct SockAddr {
    union {
        struct {
            sa_family_t family;
            in_port_t   portNBO;
        }
        sockaddr_in   sin4;
        sockaddr_in6  sin6;
    }
    private socklen_t _len;

    @property auto port() {
        return ntohs(portNBO);
    }
    @property auto port(ushort portHBO) {
        cast()portNBO = htons(portHBO);
    }
    @property sockaddr* asSockaddr() {
        return cast(sockaddr*)&sin4;
    }
    @property auto length() {
        return _len;
    }
    enum maxLength = sin6.sizeof;

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
        ep.sin4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        ep._len = sin4.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr loopback6(ushort port=0) {
        SockAddr ep;
        ep.sin6.sin6_addr = in6addr_loopback;
        ep._len = sin6.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr any4(ushort port=0) {
        SockAddr ep;
        ep.sin4.sin_addr.s_addr = htonl(INADDR_ANY);
        ep._len = sin4.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr any6(ushort port=0) {
        SockAddr ep;
        ep.sin6.sin6_addr = in6addr_any;
        ep._len = sin6.sizeof;
        ep.port = port;
        return ep;
    }

    static SockAddr getSockName(int fd) {
        SockAddr ep;
        ep._len = maxLength;
        errnoEnforce(getsockname(fd, ep.asSockaddr, &ep._len) == 0, "getsockname() failed");
        return ep;
    }

    static SockAddr getPeerName(int fd) {
        SockAddr ep;
        ep._len = maxLength;
        errnoEnforce(getpeername(fd, ep.asSockaddr, &ep._len) == 0, "getpeername() failed");
        return ep;
    }

    @("notrace") static SockAddr resolve4(string hostname, string service = "") {
        return resolve(hostname, service);
    }
    @("notrace") static SockAddr resolve4(string hostname, ushort port) {
        return resolve(hostname, to!string(port));
    }
    @("notrace") static SockAddr resolve6(string hostname, string service = "") {
        return resolve(hostname, service, AF_INET6);
    }
    @("notrace") static SockAddr resolve6(string hostname, ushort port) {
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
                ep._len = sockaddr_in.sizeof;
                return ep;
            }
            else if (family == AF_INET6 && curr.ai_addrlen == sockaddr_in6.sizeof) {
                ep.sin6 = *(cast(sockaddr_in6*)curr.ai_addr);
                ep._len = sockaddr_in6.sizeof;
                return ep;
            }
        }

        throw new Exception(hostname ~ ":" ~ service ~ " - no results");
    }
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

    assert(IP6.loopback.toString() == "::1");
    assert(IP6.loopback.isLoopback);

    auto sa = SockAddr.resolve4("localhost", 12345);
    assert(sa.toString == "127.0.0.1:12345");
    assert(sa.ip4.toString == "127.0.0.1");
    assert(sa.family == AF_INET);

    sa = SockAddr.resolve6("localhost", 12345);
    assert(sa.toString == "[::1]:12345");
    assert(sa.family == AF_INET6);
    assert(sa.ip6.toString == "::1");
}



module mecca.lib.websockets;

import mecca.reactor.subsystems.poller: Direction;
import mecca.containers.arrays;
import mecca.lib.net;
import mecca.reactor;
import mecca.lib.time;
import mecca.lib.memory;
import mecca.lib.string;
import mecca.containers.tables;
import mecca.lib.exception;
import mecca.log;
import std.algorithm;
import std.typecons;
import mecca.lib.ssl;
import mecca.containers.stringtable;
import mecca.lib.url;
import mecca.lib.reflection;

struct WebSocketFrame {
    enum : ubyte {
        Continuation = 0x0,
        Text = 0x1,
        Binary = 0x2,
        Close = 0x8,
        Ping = 0x9,
        Pong = 0xA
    }

    bool fin;
    bool masked;
    
    ulong length;
    uint mask;
    ubyte opcode;
    const(char)[] payload;

    @property bool isBinary() {
        return opcode == Binary;
    }
    
    this(ubyte opcode, const(void)[] payload=null, bool fin=true, bool masked=true) {
        this.payload = cast(const(char)[])payload;
        this.length = payload.length;
        this.opcode = opcode;
        this.fin = fin;
        this.masked = masked;
    }

    static WebSocketFrame ping(bool fin=true, bool masked=true) {
        return WebSocketFrame(Ping, null, fin, masked);
    }

    static WebSocketFrame pong(bool fin=true, bool masked=true) {
        return WebSocketFrame(Pong, null, fin, masked);
    }

    static WebSocketFrame text(const(void)[] payload, bool fin=true, bool masked=true) {
        return WebSocketFrame(Text, payload, fin, masked);
    }

    static WebSocketFrame binary(const(void)[] payload, bool fin=true, bool masked=true) {
        return WebSocketFrame(Binary, payload, fin, masked);
    }

    auto nogcToString(char[] buf) @nogc {
        return nogcFormat!"Frame(%s, %d, %s, %s)"(buf, fin?"FIN":"", length, opcode, cast(string)payload);
    }

    auto toString() {
        static char[8192] buf;
        return nogcToString(buf);
    }
}


struct WebSocket(SocketT, size_t headersSize=128) {
        /**
    * The Opcode is 4 bits, as defined in Section 5.2
    *
    * Values are defined in section 11.8
    * Currently only 6 values are defined, however the opcode is defined as
    * taking 4 bits.
    */

    SocketT underlying_;
    StringTable!headersSize headers_;
    MmapArray!char rdbuf_;
    char[] unread_;
    ulong msg_length_;
    int length_;
    FixedString!4096 req_;

    enum:ubyte {
        Fin=0x80
    }

    enum wsUpgrade = "GET %s HTTP/1.1\r\n"~
                "Host: %s\r\n"~
                "Upgrade: websocket\r\n"~
                "Connection: upgrade\r\n"~
                "Sec-WebSocket-Key: %s\r\n"~
                "Sec-WebSocket-Version: 13\r\n"~ 
                "\r\n";

    this(SocketT underlying, string uri, string host) {
        underlying_ = move(underlying);
        headers_ = StringTable!128(8192uL);
        rdbuf_.allocate(8192);
        unread_ = rdbuf_[];
        req_.nogcFormat!wsUpgrade(uri, host, "d1hlIHNhbXBsZSBub25jZQ==");
    }

    @property auto ref headers() {
        return headers_;
    }

    static WebSocket connect(Url parsedUrl, Timeout timeout=Timeout.infinite, bool nodelay=true) {
        INFO!"IP_resolve %s:%s"(parsedUrl.host, parsedUrl.port);
        auto addr = SockAddr.resolve(parsedUrl.host, parsedUrl.port); //"172.217.17.142","443");
        INFO!"SSL_connect %s %s"(parsedUrl.host, addr.toString());
        auto sock = connect(addr, parsedUrl.path, parsedUrl.host, timeout, nodelay);
        return sock;
    }

    static WebSocket connect(SockAddr saddr, string uri="/", string host="localhost", Timeout timeout = Timeout.infinite, bool nodelay = true) {
        auto socket = WebSocket!(SocketT)(
            SocketT.connect(saddr, timeout, nodelay), 
            uri, host);
        socket.do_handshake();    
        return socket;
    }
    
    static void TRACE(Direction dir, bool binary=false)(const(char)[] payload) {
        debug {
            static if(binary) {
                char [256] tmp;
                string s = nogcFormat!"%x"(tmp, payload[0..min($,64)]);
            }else {
                string s = cast(string)payload;
            }
            static if(dir==Direction.Read) {
                enum op = "WS_read";
            }else {
                enum op = "WS_write";
            }
            INFO!("(%d, %s)")(payload.length, s);
        }
    }

    static char[] consumeToken(ref char[] range, string token) {
        auto output =  range[0..token.length];
        bool match = equal(output, token);
        if(match) {
            range = range[token.length..$];
            return output;
        }
        return null;
    }

    static char[] consumeByLen(ref char[] range, size_t len) {
        auto output = range[0..len];
        range = range[len..$];
        return output;
    }

    static char[] consumeUntil(ref char[] range, char term) {
        auto output = range;
        while(range.length>0 && range[0]!=term) {
            range = range[1..$];
        }
        output = output[0..(range.ptr-output.ptr)];
        return output;
    }

    static void consumeWhile(ref char[] range, char term) {
        while(range.length>0 && range[0]==term) {
            range = range[1..$];
        }
    }

    static bool consumeHeader(ref char[] range, ref char[] key, ref char[] value) {
        if(range[0]=='\r') {
            consumeToken(range, "\r\n");
            return false;
        }
        key = consumeUntil(range, ':');
        consumeToken(range, ":");
        consumeWhile(range, ' ');
        value = consumeUntil(range, '\r');
        if(!consumeToken(range, "\r\n"))
            return false;
        return true;
    }

    int do_handshake(Timeout timeout=Timeout.infinite) {
        TRACE!(Direction.Write)(req_.str);
        underlying_.write(req_, timeout);
        length_ = underlying_.read(rdbuf_, timeout);
        if(length_>0) {
            unread_ = rdbuf_[0..length_];
            TRACE!(Direction.Read)(unread_);
            if(!consumeToken(unread_, "HTTP/1.1 101 Switching Protocols\r\n"))
                return -1;
            char[] key, value;
            while(consumeHeader(unread_, key, value)) {
                headers_[key] = value;
            }
        }        
        return cast(int)unread_.length;
    }
    
    pragma(inline,true)
    int do_read(void[] buffer, Timeout timeout) {
        // eat what we had
        int total = 0;
        auto len = min(buffer.length, unread_.length);
        buffer[0..len] = unread_[0..len];
        total += len;
        buffer = buffer[len..$];
        unread_ = unread_[len..$];
        if(unread_.length==0)
            unread_ = rdbuf_[0..0];
        if(buffer.length>0) {
            auto offset = unread_.ptr-rdbuf_.ptr;
            auto readTo = offset+unread_.length;
            auto rx = underlying_.read(rdbuf_[readTo .. $]);
            unread_ = rdbuf_[offset .. offset+unread_.length+rx];
            len = min(buffer.length, unread_.length);
            buffer[0..len] = unread_[0..len];
            unread_ = unread_[len .. $];
            total+=len;
        }
        return total;
    }

    @notrace WebSocketFrame read(void[] buffer, Timeout timeout = Timeout.infinite) @trusted @nogc {
         return as!"@nogc pure nothrow"({
            import std.bitmanip;
            ubyte[8] hdr = void;
            WebSocketFrame frame = void;
            int rx = do_read(hdr[0..2], timeout);
            frame.fin = (hdr[0] & Fin) != 0;
		    frame.opcode = cast(ubyte)(hdr[0] & 0x0F);
		    frame.masked = !!(hdr[1] & 0b1000_0000);
            frame.length = hdr[1] & 0b0111_1111;
            if (frame.length == 126) {
			    do_read(hdr[0 .. 2], timeout);
			    frame.length = std.bitmanip.bigEndianToNative!ushort(hdr[0 .. 2]);
		    } else if (frame.length == 127) {
			    do_read(hdr, timeout);
			    frame.length = std.bitmanip.bigEndianToNative!ulong(hdr);
            }
            	// Masking key is 32 bits / uint
            if (frame.masked)
			    do_read((cast(char*)&frame.mask)[0..4], timeout);
            ASSERT!"ws read buffer should be at least %d bytes"(frame.length<=buffer.length, frame.length);
            rx = do_read(buffer[0..frame.length], timeout);
            if(frame.masked) {
                // TODO
            }
            frame.payload = cast(const(char)[])buffer[0..rx];
            debug {
                if(frame.isBinary)
                    TRACE!(Direction.Read, true)(frame.payload);
                else 
                    TRACE!(Direction.Read, false)(frame.payload);
            }
            return frame;
        });
    }

    @notrace int write()(auto ref WebSocketFrame frame, Timeout timeout = Timeout.infinite) @trusted @nogc {
        return as!"@nogc pure nothrow"({
            import std.bitmanip;
            char[4096] tmp;
            INFO!"WS_write(%s)"(nogcFormat!"%s"(tmp, frame));
            ubyte firstByte = cast(ubyte)frame.opcode;
		    if (frame.fin)
                firstByte |= 0x80;
		    ubyte[10] hdr;
            hdr[0] = firstByte;
            auto b1 = frame.masked ? 0x80 : 0x00;
            int tx;
            auto len = frame.payload.length;
            if (len< 126) {
                hdr[1] = cast(ubyte)(b1 | len);
                tx = underlying_.write(hdr[0..2], timeout);
            } else if (len < 65536) {
                hdr[1] = cast(ubyte) (b1 | 126);
                hdr[2 .. 4] = std.bitmanip.nativeToBigEndian(cast(ushort)len);
                tx = underlying_.write(hdr[0..4], timeout);
            } else {
                hdr[1] = cast(ubyte) (b1 | 127);
                hdr[2 .. 10] = std.bitmanip.nativeToBigEndian(cast(ulong)len);
                tx = underlying_.write(hdr[0..10], timeout);
            }
            if(frame.masked) {
                underlying_.write((cast(char*)&frame.mask)[0..4], timeout);
                // mask the payload, we use mask=0
            }
            tx+=underlying_.write(frame.payload, timeout);
            return tx;
        });
    }
}


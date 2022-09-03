import std.algorithm : move;
import mecca.log;
import mecca.lib.time;
import mecca.lib.memory;
import mecca.reactor;
import mecca.reactor.io.fd;
import mecca.lib.string;
import mecca.containers.arrays;
import std.range: take;
import std.algorithm.mutation:copy;
import mecca.lib.websockets;
import mecca.lib.url;
import mecca.lib.reflection;
import mecca.lib.ssl;
import core.stdc.stdlib;
import core.stdc.signal;
import core.runtime:Runtime;
import std.stdio;
import std.array:Appender;
import std.zlib;
import mecca.lib.zlib;

extern(C) void onterm(int) nothrow @nogc {
    as!"nothrow @nogc"({
        try {
            Runtime.terminate();
            exit(-1);
        }catch(Exception e) {
            
        }
    });
} 

int main() {
    Reactor.OpenOptions opts = {fiberStackSize:256*1024};
    theReactor.setup(opts);
    signal(SIGINT, &onterm);
    scope(exit) theReactor.teardown(); // Not really needed outside of UTs

    auto url = "wss://real.okex.com:10442/ws/v3";
    //auto url = "wss://www.bitmex.com:443/realtime";
    //auto url = "wss://echo.websocket.org:443/echo";
    //auto url = "wss://api-pub.bitfinex.com:443/ws/2";
    theReactor.spawnFiber!wsClientFiber(url);
    return theReactor.start();
}

void wsClientFiber(string url) {
    auto parsedUrl = Url.parse(url);
    auto sock = WebSocket!(SSLSocket!Socket).connect(parsedUrl);
    debug {
        foreach(key, value; sock.headers) {
            INFO!"WS_http_header %s: %s"(key, value);
        }
    }
    MmapArray!char buf, ubuf;
    buf.allocate(65536);
    ubuf.allocate(65536);
    //sock.write(WebSocketFrame.ping);
    sock.write(WebSocketFrame.text(`{"op":"subscribe","args": ["spot/depth:BTC-USDT"]}`));
    while(true) {
        auto frame = sock.read(buf);
        auto now = TscTimePoint.hardNow;
        Duration dur = now - sock.underlying_.underlying_.fd.lastIOTime;
        sock.underlying_.underlying_.fd.lastIOTime = now;
        string message = cast(string) frame.payload.uncompressNGC(cast(ubyte[])ubuf[]);
        INFO!"%5.3gus|READ (%d) %s %s"(dur.total!"nsecs"/1e3, frame.payload.length, frame.opcode, message);
    }
}
module mecca.web.http;

import mecca.containers.array;
import mecca.reactor.reactor;
import mecca.reactor.transports;
import mecca.lib.tracing;


enum MAX_TOTAL_HEADERS_LENGTH = 2048;

private mixin template HttpFields() {
    StreamSocket sock;
    FixedString!MAX_TOTAL_HEADERS_LENGTH headersBuf;
    bool isChunked;
    bool processedHeaders;

    this(StreamSocket sock) {
        this.sock = sock;
    }
}

struct HttpRequestBuilder {
    mixin HttpFields;

    void setPath(string method, string path) {
    }
    void addHeader(string name, string value) {
    }
    void sendHeaders() {
    }
    void sendBody(const(void)[] buf) {
    }
    void sendChunk(const(void)[] buf) {
    }
}

struct HttpRequestParser {
    mixin HttpFields;

    @property string methodAndPath() {
        return "";
    }

    bool readHeaders() {
        return false;
    }
    string getHeader(string key, string defaultValue=null) {
        return defaultValue;
    }
    void[] readBody(void[] buf) {
        return buf;
    }
    void[] readChunk(void[] buf) {
        return buf;
    }
}

struct HttpResponseBuilder {
    mixin HttpFields;

    void setStatus(int code, string msg) {
    }
    void addHeader(string name, string value) {
    }
    void sendHeaders() {
    }
    void sendBody(const(void)[] buf) {
    }
    void sendChunk(const(void)[] buf) {
    }
}

struct HttpResponseParser {
    mixin HttpFields;

    string getStatusMessage() {
        return "OK";
    }
    int getStatus() {
        return 200;
    }
    bool readHeaders() {
        return false;
    }
    string getHeader(string key, string defaultValue=null) {
        return defaultValue;
    }
    void[] readBody(void[] buf) {
        return buf;
    }
    void[] readChunk(void[] buf) {
        return buf;
    }
}


struct HttpServer {
    ListenerSocket listener;
    alias HandlerDlg = void delegate(HttpRequestParser* req, HttpResponseBuilder* resp);
    HandlerDlg[string] handlers;
    HandlerDlg defaultHandler;

    void close() {
        listener.close();
    }

    void registerPath(HandlerDlg dlg, string path, string method="GET") {
        handlers[method ~ " " ~ path] = dlg;
    }

    void serve() {
        try {
            while (!listener.closed) {
                auto sock = listener.accept();
                theReactor.spawnFiber!serveClient(&this, sock);
            }
        }
        catch (Exception ex) {
            if (listener.closed) {
                // ignore
            }
            else {
                listener.close();
                throw ex;
            }
        }
    }

    static void serveClient(HttpServer* self, StreamSocket sock) {
        scope(exit) sock.close();

        while (true) {
            auto req = HttpRequestParser(sock);
            if (!req.readHeaders()) {
                // eof
                break;
            }

            auto resp = HttpResponseBuilder(sock);
            resp.setStatus(200, "OK");

            try {
                if (auto h = req.methodAndPath in self.handlers) {
                    (*h)(&req, &resp);
                }
                else {
                    if (self.defaultHandler) {
                        INFO!"#HTTP path/method '%s' not found, invoking default handler"(req.methodAndPath);
                        self.defaultHandler(&req, &resp);
                    }
                    else {
                        WARN!"#HTTP path/method '%s' not found"(req.methodAndPath);
                        resp.setStatus(404, "Not found");
                        resp.addHeader("encoding", "text/plain");
                        resp.sendHeaders();
                    }
                }
            }
            catch (Exception ex) {
                LOG_TRACEBACK("#HTTP server-side threw", ex);
                if (!resp.processedHeaders) {
                    resp.setStatus(500, "Internal server error");
                    resp.addHeader("encoding", "text/plain");
                    resp.sendHeaders();
                    // XXX: defer toString to thread pool?
                    resp.sendBody(ex.toString());
                }
                else {
                    INFO!"#HTTP response already partially-sent, not sending traceback"();
                }
                break;
            }
        }
    }
}


















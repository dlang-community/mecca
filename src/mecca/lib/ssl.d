module mecca.lib.ssl;

import deimos.openssl.ssl;
import std.algorithm : move, swap, min;
import mecca.log;
import mecca.lib.reflection: as;
import mecca.lib.time;
import mecca.lib.exception;
import mecca.reactor;
import mecca.lib.io;
import mecca.reactor.io.fd;
import mecca.lib.string;
import mecca.lib.memory;
import std.conv;
import std.string: fromStringz;
import std.typecons : Yes;
import std.format: format;

shared static this() {
    import deimos.openssl.err : ERR_load_crypto_strings;

    SSL_library_init();
    ERR_load_crypto_strings();
    SSL_load_error_strings();
}

class SslError : Exception {
    this(int ret, int err, string file = __FILE__, size_t line = __LINE__) {
        string buf = "SslError(%d) ".format(err);
        super(buf, file, line);
    }
}

struct TlsContext {
private:
    SSL_CTX* ctx;

public:

    @disable this(this);

        /// Move semantics opAssign
    ref TlsContext opAssign(TlsContext rhs) return nothrow @safe @nogc {
        swap( rhs.ctx, ctx );

        return this;
    }

    this(const(SSL_METHOD)* method) {
        ctx = SSL_CTX_new(method);
    }

    static TlsContext client(const(SSL_METHOD)* method = SSLv23_client_method) {
        return TlsContext(method);
    }

    static TlsContext server(string serverChainPath, string serverKeyPath, const(SSL_METHOD)* method = SSLv23_server_method) {
        import std.string : toStringz;
        TlsContext res = TlsContext(method);
        int rc = SSL_CTX_use_certificate_chain_file(res.ctx, serverChainPath.toStringz);
        if (rc <= 0) throw mkEx!SslError(rc, 0);
        rc = SSL_CTX_use_PrivateKey_file(res.ctx, serverKeyPath.toStringz, SSL_FILETYPE_PEM);
        if (rc <= 0) throw mkEx!SslError(rc, 0);
        return res;
    }

    ~this() nothrow @nogc @trusted {
        as!"@nogc"({SSL_CTX_free(ctx);});
    }

    void load_verify_locations(string cafile) {
        import std.string : toStringz;

        int rc = SSL_CTX_load_verify_locations(ctx, cafile.toStringz, null);
        if (rc <= 0) {
            throw mkEx!SslError(rc, 0);
        }
    }
}

struct SSLSocket(SocketT) {
    SocketT underlying_;
    TlsContext ctx_;
    SSL *ssl_;
    BIO* read_;
    BIO* write_;
    int err_;
    int state_;
    MmapArray!char rdbuf_;
    MmapArray!char wrbuf_;

    @disable this(this);

    this(SocketT underlying, TlsContext ctx) {
        underlying_ = move(underlying);
        ctx_ = move(ctx);
        rdbuf_.allocate(8192);
        wrbuf_.allocate(8192);
    }

    int get_error(int ret) {
        return SSL_get_error(ssl_, ret);
    }

    enum SslStatus {
        OK = 0,
        WANT_IO = 1,
        FAIL = -1
    }

    static SslStatus status(int err)
    {
        switch (err)
        {
            case SSL_ERROR_NONE:
            return SslStatus.OK;
            case SSL_ERROR_WANT_WRITE:
            return SslStatus.WANT_IO;
            case SSL_ERROR_WANT_READ:
            return SslStatus.WANT_IO;
            case SSL_ERROR_ZERO_RETURN:
            case SSL_ERROR_SYSCALL:
            default:
            return SslStatus.FAIL;
        }
    }

    int check_state() {
        
        int state = SSL_state(ssl_);
        if(state!=state_) {
            auto stateStr = fromStringz(SSL_state_string_long(ssl_));
            DEBUG!"SSL_state(0x%x) %s"(state, stateStr);
            state_ = state;
        }
        return state;
    }

    int do_handshake() {
        do {
            check_state();
            int ret = SSL_do_handshake(ssl_);
            doIO(ret);
        }while(!SSL_is_init_finished(ssl_));
        check_state();
        return 0;
    }
    
    int do_write() {
        int ret;
        int total = 0;

        while((ret = BIO_read(write_, wrbuf_.ptr, cast(int)wrbuf_.length))>0) {
            check_state();
            debug {
                char[32] tmp;
                INFO!"SSL_do_write(%d, 0x%s)"(ret, nogcFormat!"%x"(tmp, wrbuf_[0..min(ret, 16)]));
            }
            long written = underlying_.write(wrbuf_[0..ret]);
            total += written;
        }
        return ret<0 ? ret : total;
    }

    int do_read() {
        size_t read;
        int total = 0;
        int ret = 0;
        if((read = underlying_.read(rdbuf_))>0) { // no cycle here because will block
            
            debug {
                char[32] tmp;
                INFO!"SSL_do_read(%d, 0x%s)"(read, nogcFormat!"%x"(tmp, rdbuf_[0..min(read,16)]));
            }
            
            ret = BIO_write(read_, rdbuf_.ptr, cast(int)read);
            ASSERT!"BIO_write failed"(ret==read);
            if(ret>=0) {
                total += ret;
            }
        }
        return ret<0 ? ret : total;
    }
    
    enum SslMode {
        CLIENT,
        SERVER
    }

    void initialize(SslMode mode) {
        ssl_ = SSL_new(ctx_.ctx);
        read_ = BIO_new(BIO_s_mem());
        BIO_set_nbio(read_, 1);
        write_ = BIO_new(BIO_s_mem());
        BIO_set_nbio(write_, 1);
        SSL_set_bio(ssl_, read_, write_);
        SSL_set_verify(ssl_, SSL_VERIFY_NONE, null);
        switch(mode) {
            case SslMode.CLIENT: SSL_set_connect_state(ssl_); break;
            case SslMode.SERVER: SSL_set_accept_state(ssl_); break;
            default:assert(false);
        }
    }

    /// Move semantics opAssign
    ref SSLSocket opAssign(SSLSocket rhs) return nothrow @safe @nogc {
        swap( rhs.underlying_, underlying_ );
        swap( rhs.ctx_, ctx_ );
        swap( rhs.ssl_, ssl_ );
        swap( rhs.read_, read_ );
        swap( rhs.write_, write_ );
        return this;
    }

    ~this() nothrow @trusted @nogc{
        close();
        as!"@nogc"({SSL_free(ssl_);});
    }
    
    static SSLSocket connect(SockAddr saddr, Timeout timeout = Timeout.infinite, bool nodelay = true) {
        auto underlying = ConnectedSocket.connect(saddr, timeout, nodelay);
        auto socket = SSLSocket(move(underlying.sock), TlsContext.client());
        socket.initialize(SSLSocket.SslMode.CLIENT);
        socket.do_handshake();
        return socket;
    }

    void close() nothrow @safe @nogc{
        underlying_.close();
    }
    
    @notrace int read(void[] buffer, Timeout timeout = Timeout.infinite) @trusted @nogc {
         return as!"@nogc pure nothrow"({
            assert(SSL_is_init_finished(ssl_));
            if(buffer.length==0)
                return 0;
            int ret;
            while((ret = SSL_read(ssl_, buffer.ptr, cast(int)buffer.length))<=0) {
                doIO(ret);
            }
            return ret;
        });
    }

    void doIO(int ret) {
        while(ret<=0) {
            check_state();
            switch(err_=SSL_get_error(ssl_, ret)) {
                case SSL_ERROR_WANT_READ: 
                case SSL_ERROR_WANT_WRITE: 
                        ret = do_write();
                        ret = do_read();
                break;
                case SSL_ERROR_NONE: 
                    break;
                default:
                    throw mkEx!SslError(ret, err_);
            }
            if(!SSL_is_init_finished(ssl_)) {
                check_state();
                ret = SSL_do_handshake(ssl_);
            }else {
                return;
            }
        }
    }
    @notrace int write(const void[] buffer, Timeout timeout = Timeout.infinite) @trusted @nogc {
        return as!"@nogc pure nothrow"({
            assert(SSL_is_init_finished(ssl_));
            if(buffer.length==0)
                return 0;
            int ret;
            while((ret = SSL_write(ssl_, buffer.ptr, cast(int)buffer.length))<=0) {
                doIO(ret);
            }
            return ret;
        });
    }
}


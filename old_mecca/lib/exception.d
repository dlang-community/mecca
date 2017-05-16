module mecca.lib.exception;

import std.conv;
import std.string;

import core.exception;
import core.runtime;
import core.stdc.stdlib: _abort = abort;
import core.sys.posix.unistd: _exit;

import mecca.lib.reflection;
import mecca.lib.tracing;


@("notrace") void traceDisableCompileTimeInstrumentation();

mixin template ExceptionBody() {
    this(string msg, string file=__FILE__, size_t line=__LINE__) {
        super(msg, file, line);
    }
}

private extern(C) int backtrace(void** buffer, int size) nothrow @nogc;


void*[] extractStack(void*[] callstack, size_t skip=0) nothrow @trusted @nogc {
    immutable numFrames = backtrace(callstack.ptr, cast(int)callstack.length);
    if (skip > numFrames) {
        return null;
    }

    // Adjust the locations by one byte so they point inside the function (as
    // required by backtrace_symbols) even if the call to _d_throw_exception
    // was the very last instruction in the function.
    auto res = callstack[skip .. numFrames];
    foreach (ref c; res) {
        c -= 1;
    }
    return res;
}

private __gshared static TypeInfo_Class defaultTraceTypeInfo;

shared static this() {
    defaultTraceTypeInfo = typeid(cast(Object)defaultTraceHandler(null));
    assert(defaultTraceTypeInfo.name == "core.runtime.defaultTraceHandler.DefaultTraceInfo", defaultTraceTypeInfo.name);
    assert(defaultTraceTypeInfo.initializer.length <= ExcBuf.MAX_TRACEBACK_SIZE, "defaultTraceTypeInfo size=%s".format(
            defaultTraceTypeInfo.initializer.length));
}

struct DefaultTraceInfoABI {
    enum MAXFRAMES = 128;

    void* vtbl;
    void* mutex;
    void* iface_vtbl;
    int   numframes;
    void*[MAXFRAMES] callstack;

    static DefaultTraceInfoABI* extract(Throwable.TraceInfo ti) {
        auto obj = cast(Object)ti;
        assert (typeid(obj).name == "core.runtime.defaultTraceHandler.DefaultTraceInfo", typeid(obj).name);
        return cast(DefaultTraceInfoABI*)(cast(void*)obj);
    }
    static DefaultTraceInfoABI* extract(Throwable t) {
        return extract(t.info);
    }

    @property const(void*)[] frames() const pure nothrow @nogc {
        return callstack[0 .. numframes];
    }
}

struct ExcBuf {
    enum MAX_EXCEPTION_INSTANCE_SIZE = 256;
    enum MAX_TRACEBACK_SIZE = 1064;
    enum MAX_EXCEPTION_MESSAGE_SIZE = 256;

    ubyte[MAX_EXCEPTION_INSTANCE_SIZE] ex;
    ubyte[MAX_TRACEBACK_SIZE] ti;
    char[MAX_EXCEPTION_MESSAGE_SIZE] msgbuf;

    Throwable get() @nogc nothrow {
        if (*(cast(void**)ex.ptr) is null) {
            return null;
        }
        auto t = cast(Throwable)ex.ptr;
        assert (t !is null);
        return t;
    }
    /+Throwable set(Throwable t) {
        static assert (this.ex.offsetof == 0);
        if (t is null) {
            *(cast(void**)ex.ptr) = null;
            return null;
        }
    }+/

    T build(T: Throwable, A...)(string file, size_t line, auto ref A args) nothrow @trusted @nogc {
        static assert (__traits(classInstanceSize, T) <= MAX_EXCEPTION_INSTANCE_SIZE);

        // create the exception
        ex[0 .. __traits(classInstanceSize, T)] = cast(ubyte[])(typeid(T).initializer);
        auto t = cast(T)ex.ptr;
        scope dg = (){t.__ctor(args);};
        (cast(void delegate() nothrow @nogc)dg)();
        t.file = file;
        t.line = line;
        ti[0 .. defaultTraceTypeInfo.initializer.length] = cast(ubyte[])defaultTraceTypeInfo.initializer;
        t.info = cast(Throwable.TraceInfo)(cast(Object)ti.ptr);
        auto abi = cast(DefaultTraceInfoABI*)ti;
        abi.numframes = cast(int)extractStack(abi.callstack).length;
        return t;
    }

    static bool isGCException(Throwable ex) {
        import core.memory: GC;
        return GC.addrOf(cast(void*)ex) !is null;
    }
}

/*TLS*/ private static ExcBuf _tlsExcBuf;
/*TLS*/ static ExcBuf* _currExcBuf;
/*TLS*/ static this() {
    _currExcBuf = &_tlsExcBuf;
}

T mkEx(T: Throwable = Exception, string file=__FILE__, size_t line=__LINE__, A...)(auto ref A args) nothrow @nogc {
    pragma(inline, true);  // must inline due to file/line template params
    return _currExcBuf.build!(T, A)(file, line, args);
}

T mkExFmt(T: Throwable = Exception, string file=__FILE__, size_t line=__LINE__, A...)(string fmt, auto ref A args) @nogc {
    pragma(inline, true);  // must inline due to file/line template params
    scope dg = (){return cast(string)sformat(_currExcBuf.msgbuf, fmt, args);};
    string msg = (cast(string delegate() @nogc)dg)();
    return _currExcBuf.build!T(file, line, msg);
}

RangeError rangeError(K)(K key, string msg="not found", string file=__FILE__, size_t line=__LINE__) {
    auto ex = new RangeError(file, line);
    static if (__traits(compiles, format("%s", key))) {
        ex.msg = "Key/index %s %s".format(key, msg);
    }
    else {
        ex.msg = "Key/index of type %s %s".format(K.stringof, msg);
    }
    return ex;
}

private void writeErr(T...)(T texts) nothrow @nogc {
    import core.sys.posix.unistd: write, STDERR_FILENO;
    foreach(t; texts) {
        write(STDERR_FILENO, t.ptr, t.length);
    }
}

__gshared private static ExcBuf _assertExcBuf;
__gshared private static char[8192] _assertMsgBuf;

private void lastWords(A...)(string prefix, string fmt, string file, size_t line, A args) {
    synchronized {
        char[] msg;

        try {
            static if (args.length == 0) {
                _assertMsgBuf[0 .. prefix.length] = prefix;
                _assertMsgBuf[prefix.length .. prefix.length + fmt.length] = fmt;
                msg = _assertMsgBuf[0 .. prefix.length + fmt.length];
            }
            else {
                msg = sformat(_assertMsgBuf[prefix.length .. $], fmt, args);
                _assertMsgBuf[0 .. prefix.length] = prefix;
                msg = _assertMsgBuf[0 .. prefix.length + msg.length];
            }
        }
        catch(Throwable t) {
            msg = sformat(_assertMsgBuf, "Formatting the message threw %s: %s",
                typeid(t).name, t.msg);
        }
        LOG_CALLSTACK(cast(string)msg);

        char[20] lineStr;
        writeErr("===== ", Runtime.args()[0], " dies at ", file, ":", sformat(lineStr, "%s", line), " =====\n");
        auto ex = _assertExcBuf.build!AssertError(file, line, cast(string)msg);
        ex.toString((const char[] s){writeErr(s);});
        writeErr("\n=====================================================\n");
    }
}

void ASSERT(string mod=__MODULE__, string file=__FILE__, size_t line=__LINE__, T...)(bool cond, string fmt, scope lazy T args) pure nothrow @nogc @trusted {
    pragma(inline, true);  // must inline due to file/line template params

    if (!cond) {
        META!("ASSERT failed at %s:%s", mod, file, line)(file, line);
        pureNogcNothrow({
            version (unittest) {
                throw new AssertError(format(fmt, args), file, line);
            }
            else {
                scope(exit) _exit(1);
                lastWords("ASSERT failed: ", fmt, file, line, args);
            }
        });
    }
}

version (assert) {
    alias DBG_ASSERT = ASSERT;
}
else {
    void DBG_ASSERT(T...)(scope lazy T args){}
}

private void assertHandler2(string file, size_t line, string msg) nothrow {
    META!("ASSERT failed: %s at %s:%s")(msg, file, line);

    version (unittest) {
        throw new AssertError(msg, file, line);
    }
    else {
        pureNogcNothrow({
            scope(exit) _exit(1);
            lastWords("ASSERT failed: ", msg, file, line);
        });
    }
}

shared static this() {
    assertHandler = &assertHandler2;
}

void ABORT(string mod=__MODULE__, string file=__FILE__, size_t line=__LINE__, A...)(string fmt, A args) pure nothrow @nogc @trusted {
    pragma(inline, true);  // must inline due to file/line template params

    META!("ABORTING at %s:%s", mod, file, line)(file, line);
    pureNogcNothrow({
        scope(exit) _abort();
        lastWords("ABORTING: ", fmt, file, line, args);
    });
}

unittest {
    // just make sure it compiles
    void f() {
        assert (false, "oh crap");
        ASSERT(false, "moshe %s", 71);
        throw mkExFmt("moshe %s", 72);
        ABORT("moshe %s", 73);
    }
}


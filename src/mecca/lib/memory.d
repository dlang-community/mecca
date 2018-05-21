module mecca.lib.memory;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.exception;
import std.string;
import std.conv;
import std.uuid;

import core.atomic;
import core.sys.posix.sys.mman;
import core.stdc.errno;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.sys.linux.sys.mman: MAP_ANONYMOUS, MAP_POPULATE;

import mecca.lib.exception;
import mecca.lib.reflection: setToInit, abiSignatureOf;

import mecca.log;

enum SYS_PAGE_SIZE = 4096;

shared static this() {
    auto actual = sysconf(_SC_PAGESIZE);
    enforce(SYS_PAGE_SIZE == actual, "PAGE_SIZE = %s".format(actual));
}

public import mecca.platform.x86: prefetch;

struct MmapArray(T) {
    T[] arr;

    ~this() nothrow @safe @nogc {
        free();
    }

    @notrace void allocate(size_t numElements, bool registerWithGC = false) @trusted @nogc {
        assert (arr is null, "Already open");
        assert (numElements > 0);
        auto size = T.sizeof * numElements;
        auto ptr = mmap(null, size, PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
        enforceFmt!ErrnoException(ptr != MAP_FAILED, "mmap(%s bytes) failed", size);
        arr = (cast(T*)ptr)[0 .. numElements];
        if (registerWithGC) {
            import core.memory;
            GC.addRange(ptr, size);
        }
        if (typeid(T).initializer.ptr !is null) {
            // if the initializer is null, it means it's inited to zeros, which is already the case
            // otherwise, we'll have to init it ourselves
            foreach(ref a; arr) {
                setToInit(a);
            }
        }
    }
    @notrace void free() nothrow @trusted @nogc {
        if (arr) {
            import core.memory;
            GC.removeRange(arr.ptr);
            munmap(arr.ptr, T.sizeof * arr.length);
        }
        arr = null;
    }
    @property bool closed() const pure nothrow {
        return arr is null;
    }

    alias arr this;
}

alias MmapBuffer = MmapArray!ubyte;

unittest {
    MmapArray!ulong arr;
    assert (arr is null);
    assert (arr.length == 0);
    arr.allocate(1024);
    assert(arr.length == 1024);
    arr[4] = 199;
    arr[$-1] = 200;
    arr.free();
    assert (arr is null);
}

struct SharedFile {
    string filename;
    int fd = -1;
    ubyte[] data;

    void open(string filename, size_t size, bool readWrite = true) {
        assert (data is null, "Already open");
        assert (fd < 0, "Already open (fd)");

        //fd = .open(filename.toStringz, O_EXCL | O_CREAT | (readWrite ? O_RDWR : O_RDONLY), octal!644);
        //bool created = (fd >= 0);
        //if (fd < 0 && errno == EEXIST) {
        //    // this time without O_EXCL
        //    fd = .open(filename.toStringz, O_CREAT | (readWrite ? O_RDWR : O_RDONLY), octal!644);
        //}
        //errnoEnforce(fd >= 0, "open(%s) failed".format(filename));

        //fd = errnoCall!(.open)(filename.toStringz, O_CREAT | (readWrite ? O_RDWR : O_RDONLY), octal!644);
        fd = .open(filename.toStringz, O_CREAT | (readWrite ? O_RDWR : O_RDONLY), octal!644);
        scope(failure) {
            .close(fd);
            fd = -1;
        }

        auto roundedSize = ((size + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) * SYS_PAGE_SIZE;
        errnoCall!ftruncate(fd, roundedSize);

        auto ptr = mmap(null, size, PROT_READ | (readWrite ? PROT_WRITE : 0), MAP_SHARED, fd, 0);
        errnoEnforce(ptr != MAP_FAILED, "mmap(%s) failed".format(size));

        data = (cast(ubyte*)ptr)[0 .. size];
        this.filename = filename;
    }
    void close() @nogc {
        if (fd >= 0) {
            .close(fd);
        }
        if (data) {
            munmap(data.ptr, data.length);
            data = null;
        }
    }
    @property bool closed() @nogc @safe pure nothrow{
        return data is null;
    }

    void unlink() {
        if (filename) {
            errnoCall!(.unlink)(filename.toStringz);
            filename = null;
        }
    }
    void lock() {
        errnoCall!lockf(fd, F_LOCK, 0);
    }
    void unlock() {
        errnoCall!lockf(fd, F_ULOCK, 0);
    }

    alias data this;
}

unittest {
    enum fn = "/tmp/mapped_file_ut";
    SharedFile sf;
    scope(exit) {
        sf.unlink();
        sf.close();
    }
    sf.open(fn, 7891);
    sf[7890] = 8;
    assert(sf[$-1] == 8);
}

struct SharedFileStruct(T) {
    import std.traits;
    static assert (is(T == struct));
    static assert (!hasIndirections!T, "Shared struct cannot hold pointers");

    struct Wrapper {
        shared size_t inited;
        ulong abiSignature;  // make sure it's the same `T` in all users
        UUID uuid;           // make sure it belongs to the same object in all users
        align(64) T data;
    }

    SharedFile sharedFile;

    void open(string filename, UUID uuid = UUID.init) {
        sharedFile.open(filename, Wrapper.sizeof);
        sharedFile.lock();
        scope(exit) sharedFile.unlock();

        if (atomicLoad(wrapper.inited) == 0) {
            // we have the guarantee that the first time the file is opened, it's all zeros
            // so let's init it here
            setToInit(wrapper.data);
            static if (__traits(hasMember, T, "sharedInit")) {
                wrapper.data.sharedInit();
            }
            wrapper.abiSignature = abiSignatureOf!T;
            wrapper.uuid = uuid;
            atomicStore(wrapper.inited, 1UL);
        }
        else {
            // already inited
            assert (wrapper.uuid == uuid);
            assert (wrapper.abiSignature == abiSignatureOf!T);
        }
    }
    void close() @nogc {
        sharedFile.close();
    }
    @property bool closed() @nogc {
        return sharedFile.closed();
    }
    void unlink() {
        sharedFile.unlink();
    }

    private @property ref Wrapper wrapper() @nogc {pragma(inline, true);
        return *cast(Wrapper*)sharedFile.data.ptr;
    }
    @property ref T data() @nogc {pragma(inline, true);
        return (cast(Wrapper*)sharedFile.data.ptr).data;
    }

    void lock() {
        //import core.sys.posix.sched: sched_yield;
        //while (!cas(&wrapper.locked, 0UL, 1UL)) {
        //    sched_yield();
        //}
        sharedFile.lock();
    }
    void unlock() {
        //assert (wrapper.locked);
        //atomicStore(wrapper.locked, 0UL);
        sharedFile.unlock();
    }
}

unittest {
    struct S {
        ulong x = 17;
        ulong y = 18;
    }

    SharedFileStruct!S sfs;
    sfs.open("/tmp/mapped_file_ut");
    scope(exit) {
        sfs.unlink();
        sfs.close();
    }

    sfs.data.x++;
    sfs.data.y++;
    assert (sfs.data.x == 18);
    assert (sfs.data.y == 19);
}


// Adapted from https://github.com/D-Programming-Language/druntime/blob/master/src/gc/stats.d
struct GCStats {
    size_t poolSizeBytes;   // total size of pool (in bytes)
    size_t usedSizeBytes;   // bytes allocated
    size_t freeBlocks;      // number of blocks marked FREE
    size_t freeListSize;    // total of memory on free lists
    size_t pageBlocks;      // number of blocks marked PAGE
}

struct GCStackDescriptor {
    private import core.sync.mutex: Mutex;

    void*              bstack; /// Stack bottom
    void*              tstack; /// Stack top
    void*              ehContext;
    GCStackDescriptor* within;
    GCStackDescriptor* next;
    GCStackDescriptor* prev;

    static assert (__traits(classInstanceSize, Mutex) == 72); // This size is part of the mangle
    pragma(mangle, "_D4core6thread6Thread6_locksG2G72v") extern __gshared static
            void[__traits(classInstanceSize, Mutex)][2] _locks;
    static if (__VERSION__ < 2077) {
        pragma(mangle, "_D4core6thread6Thread7sm_cbegPS4core6thread6Thread7Context") extern __gshared static
                GCStackDescriptor* sm_cbeg;
    } else {
        pragma(mangle, "_D4core6thread6Thread7sm_cbegPSQBdQBbQx7Context") extern __gshared static
                GCStackDescriptor* sm_cbeg;
    }

    @notrace void add() nothrow @nogc {
        auto slock = cast(Mutex)_locks[0].ptr;
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();

        if (sm_cbeg) {
            this.next = sm_cbeg;
            sm_cbeg.prev = &this;
        }
        sm_cbeg = &this;
    }

    @notrace void remove() nothrow @nogc {
        auto slock = cast(Mutex)_locks[0].ptr;
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();

        if (this.prev) {
            this.prev.next = this.next;
        }
        if (this.next) {
            this.next.prev = this.prev;
        }
        if (sm_cbeg == &this) {
            sm_cbeg = this.next;
        }
    }
}

module mecca.lib.memory;

import std.exception;
import std.string;
import std.conv;
import core.sys.posix.sys.mman;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.sys.linux.sys.mman: MAP_ANONYMOUS, MAP_POPULATE;


enum SYS_PAGE_SIZE = 4096;

shared static this() {
    auto actual = sysconf(_SC_PAGESIZE);
    enforce(SYS_PAGE_SIZE == actual, "PAGE_SIZE = %s".format(actual));
}

public import mecca.platform.x86: prefetch;

struct MmapArray(T) {
    T[] arr;

    void allocate(size_t numElements, bool registerWithGC = false) {
        assert (arr is null, "Already open");
        assert (numElements > 0);
        auto size = T.sizeof * numElements;
        auto ptr = mmap(null, size, PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
        errnoEnforce(ptr != MAP_FAILED, "mmap(%s) failed".format(size));
        arr = (cast(T*)ptr)[0 .. numElements];
        if (registerWithGC) {
            import core.memory;
            GC.addRange(ptr, size);
        }
    }
    void free() {
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

struct MmapFile {
    ubyte[] data;

    void open(string filename, size_t size, bool readWrite = true) {
        assert (data is null, "Already open");
        enum PAGE_SIZE = 4096;
        int fd = .open(filename.toStringz, O_CREAT | (readWrite ? O_RDWR : O_RDONLY), octal!644);
        errnoEnforce(fd >= 0, "open(%s) failed".format(filename));
        auto roundedSize = ((size + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;
        errnoEnforce(ftruncate(fd, roundedSize) == 0, "truncate(%s, %s) failed".format(filename, roundedSize));
        auto ptr = mmap(null, size, PROT_READ | (readWrite ? PROT_WRITE : 0), MAP_SHARED, fd, 0);
        errnoEnforce(ptr != MAP_FAILED, "mmap(%s) failed".format(size));
        .close(fd);
        data = (cast(ubyte*)ptr)[0 .. size];
    }
    void close() {
        if (data) {
            munmap(data.ptr, data.length);
            data = null;
        }
    }
    @property bool closed() {
        return data is null;
    }

    alias data this;
}

unittest {
    enum fn = "/tmp/mapped_file_ut";
    MmapFile mf;
    scope(exit) {
        mf.close();
        unlink(fn);
    }
    mf.open(fn, 7891);
    mf[7890] = 8;
    assert(mf[$-1] == 8);
}


// Adapted from https://github.com/D-Programming-Language/druntime/blob/master/src/gc/stats.d
struct GCStats {
    size_t poolSizeBytes;   // total size of pool (in bytes)
    size_t usedSizeBytes;   // bytes allocated
    size_t freeBlocks;      // number of blocks marked FREE
    size_t freeListSize;    // total of memory on free lists
    size_t pageBlocks;      // number of blocks marked PAGE
}

pragma(mangle, "gc_stats") extern(C) GCStats gcGetStats() @nogc nothrow @safe;

struct GCStackDescriptor {
    private import core.sync.mutex: Mutex;

    void*              bstack; /// Stack bottom
    void*              tstack; /// Stack top
    void*              ehContext;
    GCStackDescriptor* within;
    GCStackDescriptor* next;
    GCStackDescriptor* prev;

    pragma(mangle, "_D4core6thread6Thread6_locksG2G72v") extern __gshared static void[__traits(classInstanceSize, Mutex)][2] _locks;
    pragma(mangle, "_D4core6thread6Thread7sm_cbegPS4core6thread6Thread7Context") extern __gshared static  GCStackDescriptor* sm_cbeg;

    void add() nothrow @nogc {
        auto slock = cast(Mutex)_locks[0].ptr;
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();

        if (sm_cbeg) {
            this.next = sm_cbeg;
            sm_cbeg.prev = &this;
        }
        sm_cbeg = &this;
    }

    void remove() nothrow @nogc {
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






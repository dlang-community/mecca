/// Constructs for allocating and managing memory without the GC
module mecca.lib.memory;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.exception;
import std.string;
import std.conv;
import std.uuid;

import core.atomic;
import core.stdc.errno;
import core.sys.posix.fcntl;
import core.sys.posix.sys.mman;
import core.sys.posix.unistd;
import core.sys.linux.sys.mman: MAP_ANON, mremap, MREMAP_MAYMOVE;

import mecca.lib.exception;
import mecca.lib.reflection: setToInit, abiSignatureOf, as;
import mecca.platform.os : MAP_POPULATE;

import mecca.log;

enum SYS_PAGE_SIZE = 4096;

shared static this() {
    auto actual = sysconf(_SC_PAGESIZE);
    enforce(SYS_PAGE_SIZE == actual, "PAGE_SIZE = %s".format(actual));
}

public import mecca.platform.x86: prefetch;

/**
 * A variable size array backed by mmap-allocated memory.
 *
 * Behaves just like a native dynamic array, but all methods are `@nogc`.
 *
 * Params:
 *      shrink = Determines whether the capacity of the array can be reduced by setting .length.
 *      Allocated memory can always be freed by calling free().
 */
public struct MmapArray(T, bool shrink = false) {
private:
    void *_ptr = MAP_FAILED;
    size_t _capacity = 0;
    T[] _arr;
    bool registerWithGC = false;

public:

    /// Returns `true` if the array currently has no allocated memory.
    @property bool closed() const pure nothrow @nogc { return (_ptr == MAP_FAILED); }

    /// Returns the array as a standard D slice.
    @property inout(T[]) arr() inout pure nothrow @nogc { return _arr; }

    /// Returns the number of elements the array can grow to with no further allocations
    @property size_t capacity() const pure nothrow @nogc { return _capacity / T.sizeof; }

    /// Get/set the number of elements in the array.
    @property size_t length() const pure nothrow @nogc { return _arr.length; }
    /// ditto
    @property size_t length(size_t numElements) @trusted @nogc {
        return this.lengthImpl!true = numElements;
    }

    @disable this(this);
    ~this() nothrow @safe @nogc {
        free();
    }

    alias arr this;

    /// Pre-allocate enough memory for at least numElements to be appended to the array.
    @notrace void reserve(size_t numElements) @trusted @nogc {
        if (this.capacity >= numElements) {
            return;
        }
        reserveImpl(numElements);
    }

    /// Initial allocation of the array memory.
    ///
    /// Params:
    ///     numElements = The initial number of elements of the array.
    ///     registerWithGC = Whether the array's memory should be scanned by the GC. This is required for arrays holding
    ///         pointers to GC-allocated memory.
    ///
    /// Notes:
    ///     Should be called on a closed array.
    ///
    ///     This method is added for symmetry with `free()`. Its use is optional. If `registerWithGC` is `false`, this
    ///     call has the same effect as setting `length` on a closed array.
    @notrace void allocate(size_t numElements, bool registerWithGC = false) @trusted @nogc {
        assert (closed, "Already opened");
        assert (numElements > 0);
        this.registerWithGC = registerWithGC;
        this.lengthImpl!false = numElements;
    }

    /// Free all allocated memory and set length to 0.
    @notrace void free() nothrow @trusted @nogc {
        if (closed) {
            return;
        }

        this.gcUnregister();
        munmap(_ptr, _capacity);
        this._ptr = MAP_FAILED;
        this._capacity = 0;
        this._arr = null;
    }

private:

    @notrace void reserveImpl(size_t numElements) @trusted @nogc {
        immutable size_t newCapacity = ((((numElements * T.sizeof) + SYS_PAGE_SIZE - 1) / SYS_PAGE_SIZE) * SYS_PAGE_SIZE);
        static if (shrink) {
            if (newCapacity == _capacity) {
                return;
            }
        } else {
            if (newCapacity <= _capacity) {
                return;
            }
        }

        if (numElements == 0) {
            free();
            return;
        }

        this.gcUnregister();
        void* ptr = MAP_FAILED;

        // initial allocation - mmap
        if (closed) {
            ptr = mmap(null, newCapacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_POPULATE, -1, 0);
            enforceFmt!ErrnoException(ptr != MAP_FAILED, "mmap(%s bytes) failed", newCapacity);
        }

        // resize existing allocation - mremap
        else {
            ptr = as!"@nogc"(() => mremap(_ptr, _capacity, newCapacity, MREMAP_MAYMOVE));
            enforceFmt!ErrnoException(ptr != MAP_FAILED, "mremap(%s bytes -> %s bytes) failed", _capacity, newCapacity);
        }

        immutable size_t currLength = this.length;
        this._ptr = ptr;
        this._capacity = newCapacity;
        this._arr = (cast(T*)_ptr)[0 .. currLength];
        this.gcRegister();
    }

    @property size_t lengthImpl(bool forceSetToInit)(size_t numElements) @trusted @nogc {
        import std.algorithm : min;
        import std.traits : hasElaborateDestructor;
        immutable size_t currLength = this.length;

        static if (hasElaborateDestructor!T) {
            foreach (ref a; this._arr[min($, numElements) .. $]) {
                a.__xdtor();
            }
        }

        this.reserveImpl(numElements);
        this._arr = this._arr.ptr[0 .. numElements];

        // XXX DBUG change this runtime if() to static if with __traits(isZeroInit, T) once it's implemented
        if (forceSetToInit || typeid(T).initializer.ptr !is null) {
            foreach (ref a; this._arr[min($, currLength) .. $]) {
                setToInit!true(a);
            }
        }

        return numElements;
    }

    @notrace gcRegister() const nothrow @trusted @nogc {
        import core.memory;
        if (registerWithGC) {
            GC.addRange(_ptr, _capacity);
        }
    }
    @notrace gcUnregister() const nothrow @trusted @nogc {
        import core.memory;
        if (registerWithGC && !closed) {
            GC.removeRange(_ptr);
        }
    }
}

alias MmapBuffer = MmapArray!ubyte;

@nogc unittest {
    MmapArray!ubyte arr;
    assert (arr is null);
    assert (arr.length == 0);
    arr.allocate(1024);
    assert(arr.length == 1024);
    arr[4] = 199;
    arr[$-1] = 200;
    arr.free();
    assert (arr is null);

    arr.length = SYS_PAGE_SIZE / 4;
    assert (arr.capacity == SYS_PAGE_SIZE);
    arr[$-1] = 0x13;
    arr.length = SYS_PAGE_SIZE / 2;
    arr[$-1] = 0x37;
    arr.length = SYS_PAGE_SIZE / 4;
    assert (arr[$-1] == 0x13);
    arr.length = SYS_PAGE_SIZE / 2;
    assert (arr[$-1] == 0);
    assert (arr.capacity == SYS_PAGE_SIZE);

    arr.length = 4*SYS_PAGE_SIZE - 100;
    assert (arr.capacity == 4*SYS_PAGE_SIZE);
    assert (arr[SYS_PAGE_SIZE/4 - 1] == 0x13);
    arr.length = SYS_PAGE_SIZE / 4;
    assert (arr.capacity == 4*SYS_PAGE_SIZE);
    assert (arr[$ - 1] == 0x13);
    arr.length = 0;
    assert (arr.empty);
    assert (arr.capacity == 4*SYS_PAGE_SIZE);

    arr.free();
    assert (arr is null);
    assert (arr.empty);
    assert (arr.capacity == 0);
}

@nogc unittest {
    static ulong count;
    count = 0;

    struct S {
        int x;
        ~this() @nogc {
            // count is global (static) to avoid allocating a closure.
            count++;
        }
    }
    MmapArray!S arr;

    arr.reserve(100);
    assert (arr.empty);
    assert (arr.capacity >= 100);

    arr.length = 10;
    assert (!arr.empty);
    assert (count == 0);

    arr[9].x = 9;
    arr.length = 5;
    assert (count == 5);
    arr.length = 20;
    assert (count == 5);
    assert (arr[9].x == 0);
    arr.length = 5;
    assert (count == 20);
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

struct DRuntimeStackDescriptor {
    private import core.sync.mutex: Mutex;
    private import core.thread: Thread;

    import std.conv: to;

    void*                       bstack; /// Stack bottom
    void*                       tstack; /// Stack top
    void*                       ehContext;
    DRuntimeStackDescriptor*    within;
    DRuntimeStackDescriptor*    next;
    DRuntimeStackDescriptor*    prev;

    private enum mutextInstanceSize = __traits(classInstanceSize, Mutex);
    private enum mangleSuffix = mutextInstanceSize.to!string ~ "v";

    static if (__traits(hasMember, Thread, "_locks")) {
        pragma(mangle, "_D4core6thread6Thread6_locksG2G" ~ mangleSuffix) extern __gshared static
            void[__traits(classInstanceSize, Mutex)][2] _locks;
        @notrace private Mutex _slock() nothrow @nogc {
            return cast(Mutex)_locks[0].ptr;
        }
    } else {
        pragma(mangle,"_D4core6thread6Thread6_slockG72" ~ mangleSuffix) extern __gshared static
            void[__traits(classInstanceSize, Mutex)] _slock;
        @notrace private Mutex _slock() nothrow @nogc {
            return cast(Mutex)_slock.ptr;
        }
    }

    static if (__VERSION__ < 2077) {
        pragma(mangle, "_D4core6thread6Thread7sm_cbegPS4core6thread6Thread7Context") extern __gshared static
                DRuntimeStackDescriptor* sm_cbeg;
    } else {
        pragma(mangle, "_D4core6thread6Thread7sm_cbegPSQBdQBbQx7Context") extern __gshared static
                DRuntimeStackDescriptor* sm_cbeg;
    }

    @notrace void add() nothrow @nogc {
        auto slock = _slock();
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();

        if (sm_cbeg) {
            this.next = sm_cbeg;
            sm_cbeg.prev = &this;
        }
        sm_cbeg = &this;
    }

    @notrace void remove() nothrow @nogc {
        auto slock = _slock();
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

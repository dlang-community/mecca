module mecca.lib.hacks;

// Adapted from https://github.com/D-Programming-Language/druntime/blob/master/src/gc/stats.d
struct GCStats
{
    size_t poolSizeBytes;   // total size of pool (in bytes)
    size_t usedSizeBytes;   // bytes allocated
    size_t freeBlocks;      // number of blocks marked FREE
    size_t freeListSize;    // total of memory on free lists
    size_t pageBlocks;      // number of blocks marked PAGE
}

pragma(mangle, "gc_stats") extern(C) GCStats gcGetStats() @nogc nothrow @safe;

struct GCStackDescriptor {
    private import core.sync.mutex: Mutex;

    void*              bstack;
    void*              tstack;
    void*              ehContext;
    GCStackDescriptor* within;
    GCStackDescriptor* next;
    GCStackDescriptor* prev;

    pragma(mangle, "_D4core6thread6Thread6_locksG2G72v") extern __gshared static void[__traits(classInstanceSize, Mutex)][2] _locks;
    pragma(mangle, "_D4core6thread6Thread7sm_cbegPS4core6thread6Thread7Context") extern __gshared static  GCStackDescriptor* sm_cbeg;

    void add() nothrow {
        auto slock = cast(Mutex)_locks[0].ptr;
        slock.lock_nothrow();
        scope(exit) slock.unlock_nothrow();

        if (sm_cbeg) {
            this.next = sm_cbeg;
            sm_cbeg.prev = &this;
        }
        sm_cbeg = &this;
    }

    void remove() nothrow {
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



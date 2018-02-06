module mecca.platform.aio;

//
// adapted from libaio (https://git.fedorahosted.org/cgit/libaio.git/tree/src/io_getevents.c)
//

import core.sys.posix.time: timespec;
import mecca.lib.exception: errnoCall;
import mecca.platform.linux;

version(linux):

alias aio_context_t = ulong;

enum IOCB_CMD: ushort {
    PREAD = 0,
    PWRITE = 1,
    FSYNC = 2,
    FDSYNC = 3,
    /* These two are experimental.
     * IOCB_CMD_PREADX = 4,
     * IOCB_CMD_POLL = 5,
     */
    NOOP = 6,
    PREADV = 7,
    PWRITEV = 8,
    /* Weka IO private */
    FENCE = 1638, // By my internal organic random number generator
}

enum {
    IOCB_FLAG_RESFD = 1,    // Set if the "aio_resfd" member of the "struct iocb" is valid
}

extern(C) struct io_event {
    ulong   data;           /* the data field from the iocb */
    ulong   obj;            /* what iocb this event came from */
    long    res;            /* result code for this event */
    long    res2;           /* secondary result */
};

/*
 * we always use a 64bit off_t when communicating
 * with userland.  its up to libraries to do the
 * proper padding and aio_error abstraction
 */
extern(C) struct iocb {
    /* these are internal to the kernel/libc. */
    ulong   aio_data;       /* data to be returned in event's data */

    version (LittleEndian) {
        uint aio_key;       /* the kernel sets aio_key to the req # */
        uint aio_reserved1;
    }
    else version (BigEndian) {
        uint aio_reserved1;
        uint aio_key;       /* the kernel sets aio_key to the req # */
    }
    else {
        static assert(false, "Unknown endianity");
    }

    /* common fields */
    ushort   aio_lio_opcode; /* see IOCB_CMD_ above */
    short    aio_reqprio;
    uint     aio_fildes;

    ulong    aio_buf;
    ulong    aio_nbytes;
    long     aio_offset;

    /* extra parameters */
    ulong    aio_reserved2;  /* TODO: use this for a (struct sigevent *) */

    /* flags for the "struct iocb" */
    uint     aio_flags;

    /*
     * if the IOCB_FLAG_RESFD flag of "aio_flags" is set, this is an
     * eventfd to signal AIO readiness to
     */
    uint     aio_resfd;
}

static assert (iocb.sizeof == 64);

extern(C) private struct aio_ring {
    enum RING_MAGIC = 0xa10a10a1;

    uint   id;     /* kernel internal index number */
    uint   nr;     /* number of io_events */
    uint   head;
    uint   tail;

    uint   magic;
    uint   compat_features;
    uint   incompat_features;
    uint   header_length;  /* size of aio_ring */
};


// maxevents - up to `/proc/sys/fs/aio-max-nr`
//             update system-wide `sysctl -w fs.aio-max-nr = 1048576`
int io_setup(uint maxevents, aio_context_t* ctxp) nothrow @nogc @system {
    return syscall_int(Syscall.NR_io_setup, maxevents, ctxp);
}
int io_destroy(aio_context_t ctx_id) nothrow @nogc @system {
    return syscall_int(Syscall.NR_io_destroy, ctx_id);
}
int io_submit(aio_context_t ctx_id, long nr, iocb** ios) nothrow @nogc @system {
    return syscall_int(Syscall.NR_io_submit, ctx_id, nr, ios);
}
int io_cancel(aio_context_t ctx_id, iocb* iocb, io_event* result) nothrow @nogc @system {
    return syscall_int(Syscall.NR_io_cancel, ctx_id, iocb, result);
}
int io_getevents(aio_context_t ctx_id, long min_nr, long nr, io_event* events, timespec* timeout) nothrow @nogc @system {
    auto ring = cast(aio_ring*)ctx_id;
    if (ring !is null && min_nr == 0 && ring.magic == aio_ring.RING_MAGIC && ring.head == ring.tail) {
        return 0;
    }
    return syscall_int(Syscall.NR_io_getevents, ctx_id, min_nr, nr, events, timeout);
}


struct AIOContext {
    aio_context_t ctxId;

    void open(uint maxEvents) {
        errnoCall!io_setup(maxEvents, &ctxId);
    }
    void close() {
        errnoCall!io_destroy(ctxId);
        ctxId = aio_context_t.init;
    }
    int submit(iocb*[] ios) {
        if (ios.length == 0) {
            return 0;
        }
        else {
            return errnoCall!io_submit(ctxId, ios.length, ios.ptr);
        }
    }
    io_event[] getEvents(io_event[] eventsBuf) {
        int count = errnoCall!io_getevents(ctxId, 0, eventsBuf.length, eventsBuf.ptr, null);
        return eventsBuf[0 .. count];
    }
}

unittest {
    AIOContext ctx;
    ctx.open(10);
    io_event[1] eventsBuf;
    assert (ctx.getEvents(eventsBuf).length == 0);
    ctx.close();
}






module mecca.lib.zlib;
import mecca.lib.exception;

void[] uncompressNGC(const(void)[] srcbuf, ubyte[] destbuf, int winbits = -15)
{
    import std.conv : to;
    import etc.c.zlib;
    import std.zlib:ZlibException;

    int err;

    int destlen = cast(int)destbuf.length;

    etc.c.zlib.z_stream zs;
    zs.next_in = cast(typeof(zs.next_in)) srcbuf.ptr;
    zs.avail_in = to!uint(srcbuf.length);
    err = etc.c.zlib.inflateInit2(&zs, winbits);
    if (err)
    {
        throw new ZlibException(err);
    }

    size_t olddestlen = 0u;

    while (true)
    {
        //destbuf.length = destlen;
        zs.next_out = cast(typeof(zs.next_out)) &destbuf[olddestlen];
        zs.avail_out = to!uint(destlen - olddestlen);
        olddestlen = destlen;

        err = etc.c.zlib.inflate(&zs, Z_NO_FLUSH);
        switch (err)
        {
            case Z_OK:
                throw new RangeErrorWithReason("uncompressNGC");

            case Z_STREAM_END:
                //destbuf.length = zs.total_out;
                err = etc.c.zlib.inflateEnd(&zs);
                if (err != Z_OK)
                    throw new ZlibException(err);
                return destbuf[0..zs.total_out];

            default:
                etc.c.zlib.inflateEnd(&zs);
                throw new ZlibException(err);
        }
    }
    assert(0, "Unreachable code");
}
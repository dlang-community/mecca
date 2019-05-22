module mecca.platform.os;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux)
    public import mecca.platform.os.linux;
else version (Darwin)
    public import mecca.platform.os.darwin;
else
    static assert("platform not supported");

package(mecca) struct MmapArguments
{
    import core.sys.posix.sys.types : off_t;

    int prot;
    int flags;
    int fd;
    off_t offset;
}

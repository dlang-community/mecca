module mecca.platform.os;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux)
    public import mecca.platform.os.linux;
else version (Darwin)
    public import mecca.platform.os.darwin;
else
    static assert("platform not supported");

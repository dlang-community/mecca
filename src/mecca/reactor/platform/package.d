module mecca.reactor.platform;

version (linux)
    public import mecca.reactor.platform.linux;
else version (Darwin)
    public import mecca.reactor.platform.darwin;
else
    static assert("platform not supported");

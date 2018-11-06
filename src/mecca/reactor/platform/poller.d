module mecca.reactor.platform.poller;

package(mecca.reactor):

version (linux)
    import poller = mecca.reactor.platform.linux.poller;
else version (Darwin)
    import poller = mecca.reactor.platform.darwin.poller;
else
    static assert("platform not supported");

alias Poller = poller.Poller;

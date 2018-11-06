module mecca.reactor.platform.darwin.poller;

version (Darwin):
package(mecca.reactor.platform):

public import core.sys.darwin.sys.event;
public import mecca.reactor.platform.kqueue;

module mecca.reactor.subsystems.poller;

enum Direction { Read = 0, Write, Both }

version(linux) {
import mecca.reactor.platform.linux.epoll;

alias poller = epoller;
alias Poller = Epoll;

} else {
static assert(false, "Unsupported platform");
}

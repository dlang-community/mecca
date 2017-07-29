module mecca.reactor.subsystems.inotify;


struct WatchHandle {
    void unwatch() {
    }
}

struct FSWatcher {
    WatchHandle watch(string path) {
        return WatchHandle.init;
    }
}


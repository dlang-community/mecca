/// Platform independent file watcher
/**
 * Interface is expected to change in order to make it less platform specific.
 */
module mecca.reactor.io.fs_watcher;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import mecca.log;
import mecca.reactor;

version(linux):

import mecca.reactor.io.inotify;
public import mecca.reactor.io.inotify : WatchDescriptor;
public import core.sys.linux.sys.inotify;


/// file watcher struct
struct FSWatcher {
    /// Signature for the watch event callback delegate
    alias void delegate(ref const(Inotifier.Event) wd) nothrow WatchEventCallback;
private:
    FiberHandle watcherFiberHandle;
    WatchEventCallback[WatchDescriptor] registeredWatchers; // XXX TODO: switch to non-GC hashing
    Inotifier notifier;

public:
    /**
     * Add a watch point.
     *
     * Params:
     * path = The path to watch
     * mask = The events we should watch for. See details in `Inotifier`.
     * callback = The delegate to be called when the events happen. Will be passed a `Inotifier.Event` struct. The code
     *  will run under a critical section, so it must not yield.
     */
    @notrace WatchDescriptor addWatch(const(char)[] path, uint mask, WatchEventCallback callback) @safe {
        if( registeredWatchers.length==0 )
            open();

        auto wd = notifier.watch(path, mask);

        registeredWatchers[wd] = callback;

        return wd;
    }

    /// Remove a watch point
    @notrace void removeWatch(WatchDescriptor wd) @safe @nogc {
        notifier.removeWatch(wd);
        registeredWatchers.remove(wd);
    }

private:
    @notrace void open() @safe @nogc {
        notifier.open();
        watcherFiberHandle = theReactor.spawnFiber( &watcherFiber );
    }

    @notrace void closing() nothrow @safe @nogc {
        notifier.close();
        watcherFiberHandle.reset();
    }

    void watcherFiber() {
        scope(exit) {
            closing();
        }

        while(true) {
            auto event = notifier.getEvent();
            WatchEventCallback* cb = event.wd in registeredWatchers;
            if( cb is null ) {
                WARN!"Received event %s on %s with mask %x but no handler"(event.wd, event.name, event.mask);
                continue;
            }

            with(theReactor.criticalSection) {
                (*cb)(*event);
            }
        }
    }
}

__gshared FSWatcher fsWatcher;

unittest {
    import mecca.lib.exception;

    WatchDescriptor wd;
    uint numEvents;

    void eventCB(ref const(Inotifier.Event) event) nothrow {
        INFO!"handle %s mask %x cookie %s len %s name %s"( event.wd, event.mask, event.cookie, event.len, event.name );
        numEvents++;
    }

    void testBody() {
        import core.sys.posix.stdlib;
        import std.string;
        import std.file;
        import std.process;
        import std.exception;

        import mecca.lib.time;

        string iPath = format("%s/meccaUT-XXXXXX\0", tempDir());
        char[] path;
        path.length = iPath.length;
        path[] = iPath[];
        errnoEnforce( mkdtemp(path.ptr) !is null );
        scope(exit) execute( ["rm", "-rf", path] );

        iPath.length = 0;
        iPath ~= path[0..$-1];
        DEBUG!"Using directory %s for inotify tests"( iPath );

        wd = fsWatcher.addWatch(
                path,
                Inotifier.IN_MODIFY|Inotifier.IN_ATTRIB|Inotifier.IN_CREATE|Inotifier.IN_DELETE|Inotifier.IN_MOVED_FROM|Inotifier.IN_MOVED_TO|Inotifier.IN_ONLYDIR,
                &eventCB);
        DEBUG!"watch registration returned %s"(wd);

        uint historicalNumEvents;
        assertEQ(numEvents, historicalNumEvents);
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);

        execute( ["touch", iPath ~ "/file1"] );
        theReactor.sleep(1.msecs);
        assertGT(numEvents, historicalNumEvents);
        historicalNumEvents = numEvents;
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);
        rename( iPath ~ "/file1", iPath ~ "/file2" );
        theReactor.sleep(1.msecs);
        assertGT(numEvents, historicalNumEvents);
        historicalNumEvents = numEvents;
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);
        theReactor.yield();
        assertEQ(numEvents, historicalNumEvents);
    }

    testWithReactor(&testBody);
}

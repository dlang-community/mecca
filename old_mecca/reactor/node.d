module mecca.node.node;

import std.functional;

import mecca.lib.tracing;
import mecca.reactor.reactor;


mixin template RegisterNodeService() {
    shared static this() {
        thisNode.registerService(serviceName, serviceDeps, &isSupported, &initService, &finiService);
    }
}

struct Node {
    static struct NodeService {
        enum State: ubyte {UNINIT, INITING, INITED, UNINITING}
        string name;
        string[] deps;
        State state;
        bool function() isSupported;
        void function() initService;
        void function() finiService;
    }

    private void delegate()[] atExitCallbacks;
    private NodeService[string] services;

    void registerAtExit(void delegate() cb) {
        atExitCallbacks ~= cb;
    }
    void registerAtExit(void function() cb) {
        atExitCallbacks ~= toDelegate(cb);
    }
    void registerService(string name, string[] deps, bool function() isSupported,
                         void function() initService, void function() finiService) {
        assert (name !in services);
        services[name] = NodeService(name, deps, NodeService.State.UNINIT, isSupported, initService, finiService);
    }

    void main(string[] argv) {
        theReactor.open();
        scope(exit) theReactor.close();

        atExitCallbacks.reserve(20);

        theReactor.spawnFiber(&initServices);
        scope(exit) {
            finiServices();
        }
        scope(exit) runAtExit();

        theReactor.mainloop();
    }

    private void initServices() {
        void initWithDeps(string name) {
            final switch (services[name].state) with (NodeService.State) {
                case INITED:
                    return;
                case INITING:
                    assert (false, "cycle");
                case UNINIT:
                    break;
                case UNINITING:
                    assert (false, "UNINITING");
            }
            if (!services[name].isSupported()) {
                INFO!"#NODE skipping service %s (not supported)"(name);
                return;
            }
            services[name].state = NodeService.State.INITING;
            foreach(depName; services[name].deps) {
                initWithDeps(depName);
            }
            INFO!"#NODE initializing service %s"(name);
            scope(failure) ERROR!"#NODE failed initializing service %s"(name);
            services[name].initService();
            services[name].state = NodeService.State.INITED;
            INFO!"#NODE finished initializing service %s"(name);
        }
        foreach(name; services.byKey) {
            initWithDeps(name);
        }
    }

    private void finiServices() {
        void finiWithDeps(string name) {
            final switch (services[name].state) with (NodeService.State) {
                case INITED:
                    break;
                case INITING:
                    assert (false, "INITING");
                case UNINIT:
                    return;
                case UNINITING:
                    assert (false, "cycle");
            }
            services[name].state = NodeService.State.UNINITING;
            foreach(depName; services[name].deps) {
                finiWithDeps(depName);
            }
            INFO!"#NODE finalizing service %s"(name);
            scope(failure) ERROR!"#NODE failed finalizing service %s"(name);
            services[name].finiService();
            services[name].state = NodeService.State.UNINIT;
            INFO!"#NODE finished finalizing service %s"(name);
        }
        foreach(name; services.byKey) {
            finiWithDeps(name);
        }
    }

    public void restart() {
        assert (false);
    }

    public void terminate() {
        assert (false);
    }

    private void runAtExit() {
        foreach(cb; atExitCallbacks) {
            cb();
        }
    }
}

__gshared Node thisNode;


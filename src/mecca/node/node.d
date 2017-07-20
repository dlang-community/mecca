module mecca.node.node;

import std.stdio;
import std.string;


mixin template registerService() {
    __gshared static typeof(this) instance;

    shared static this() {
        import mecca.node;
        import std.string;
        import std.traits;

        Node.Service svc;
        static if (is(typeof(instance.SERVICE_NAME))) {
            svc.name = instance.SERVICE_NAME;
        }
        else {
            svc.name = typeof(this).stringof;
            if (svc.name.toLower.endsWith("service")) {
                svc.name = svc.name[0 .. $-6];
            }
        }
        static if (is(typeof(instance.getDependencies))) {
            svc.deps = instance.getDependencies();
        }
        else static if (is(typeof(instance.DEPS))) {
            static if (isArray!instance.DEPS) {
                svc.deps = instance.DEPS;
            }
            else {
                svc.deps = [instance.DEPS];
            }
        }

        svc.setup = &instance.setup;
        svc.teardown = &instance.teardown;
    }
}

struct Node {
    struct Service {
        enum Phase {DOWN, SETTING_UP, UP, TEARING_DOWN}

        Phase phase = Phase.DOWN;
        string name;
        string[] deps;
        void delegate() setup;
        void delegate() teardown;
    }

    private void delegate()[] atExitCallbacks;
    Service[string] services;
    string[] args;

    void main(string[] args) {
        this.args = args;

        // init reactor
        setupServices();
    }

    void _setupService(string name) {
        final switch (services[name].phase) with (Service.Phase) {
            case UP:
                break;
            case DOWN:
                services[name].phase = SETTING_UP;
                foreach(dep; services[name].deps) {
                    _setupService(dep);
                }
                services[name].setup();
                services[name].phase = UP;
                break;
            case SETTING_UP:
                assert (false, "%s: cycle".format(name));
            case TEARING_DOWN:
                assert (false, "%s: TEARING_DOWN".format(name));
        }
    }

    void setupServices() {
        foreach(name; services.keys) {
            _setupService(name);
        }
    }

    void _teardownService(string name) {
        /+final switch (services[name].phase) with (Service.Phase) {
            case DOWN:
                break;
            case UP:
                services[name].phase = TEARING_DOWN;
                foreach(dep; services[name].deps) {
                    _setupService(dep);
                }
                services[name].teardown();
                services[name].phase = DOWN;
                break;
            case SETTING_UP:
                assert (false, "%s: cycle".format(name));
            case TEARING_DOWN:
                assert (false, "%s: TEARING_DOWN".format(name));
        }+/
    }

    void teardownServices() {
        /+string[string] reversedTopology;
        foreach(name, ref svc; services.keys) {
            foreach(depName; svc.deps) {
                depName
            }
        }+/
    }

}

__gshared Node thisNode;

version (unittest) {
}
else {
    void main(string[] args) {
        thisNode.main(args);
    }
}




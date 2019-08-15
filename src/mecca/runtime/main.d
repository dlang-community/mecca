/// Mecca main entrypoint
module mecca.runtime.main;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.stdio;
import std.string;
import mecca.reactor: theReactor;
import mecca.runtime.services;


struct ServiceManager {
    bool isRunning;
    string[] args;
    private string[] _serviceStack;
    private string[] _orderOfInitialization;
    string[] servicesToInit;

    void main(string[] args) {
        assert (!isRunning);
        isRunning = true;
        scope(exit) isRunning = false;
        this.args = args;

        scope(exit) runAtExitCallbacks();

        theReactor.setup();
        scope(success) theReactor.teardown();

        setupServices();
        scope(success) teardownServices();

        // this is the mainloop
        theReactor.start();
    }

    void utMain(string[] args, string[] servicesToInit = null) {
        this.servicesToInit = servicesToInit;
        main(args);
    }

    private void _recursiveSetup(string name) {
        auto svc = &_registeredServices[name];

        final switch (svc.state) with (ServiceInterface.State) {
            case DOWN:
                _serviceStack ~= name;
                scope(exit) _serviceStack.length--;

                svc.state = SETUP;
                foreach(depName; svc.deps) {
                    _recursiveSetup(depName);
                }
                if (svc.setup()) {
                    _orderOfInitialization ~= name;
                    svc.state = UP;
                }
                else {
                    svc.state = DISABLED;
                }
                break;

            case SETUP:
                assert (false, "Cycle detected: %s".format(_serviceStack));

            case UP:
                break;

            case DISABLED:
                if (_serviceStack.length == 0) {
                    // invoked from root, just skip
                }
                else {
                    assert (false, "Service %s requires disabled service %s (%s)".format(_serviceStack[$-1], name));
                }
                break;

            case TEARDOWN:
                assert (false, "Teardown during setup: %s".format(_serviceStack));
        }
    }

    private void setupServices() {
        _orderOfInitialization.length = 0;
        _serviceStack.length = 0;
        foreach(_, ref svc; _registeredServices) {
            svc.state = ServiceInterface.State.DOWN;
        }
        scope(exit) servicesToInit = null;
        if (servicesToInit is null) {
            servicesToInit = _registeredServices.keys;
        }
        foreach(name; servicesToInit) {
            assert (_serviceStack.length == 0);
            _recursiveSetup(name);
            assert (_serviceStack.length == 0);
        }
    }

    private void teardownServices() {
        foreach_reverse(name; _orderOfInitialization) {
            auto svc = &_registeredServices[name];
            assert (svc.state == ServiceInterface.State.UP);
            svc.teardown();
            svc.state = ServiceInterface.State.DOWN;
        }
        _orderOfInitialization.length = 0;
    }

    public void stop() {
        // graceful termination
        //theReactor.stop();  -- this asserts on a context switch while in a critical section
        import mecca.lib.time: Timeout;

        static void stopWrapper() {
            theReactor.stop();
        }

        theReactor.registerTimer(Timeout.elapsed, &stopWrapper);
    }
}

__gshared ServiceManager serviceManager;

/**
 * main entrance function for the mecca reactor
 */
int meccaMain(string[] argv) {
    serviceManager.main(argv);
    return 0;
}

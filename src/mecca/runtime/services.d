module mecca.runtime.services;


private __gshared void delegate()[] _atExitCallbacks;

public void registerAtExit(void function() fn) {
    import std.functional: toDelegate;
    _atExitCallbacks ~= toDelegate(fn);
}
public void registerAtExit(void delegate() dg) {
    _atExitCallbacks ~= dg;
}

package void runAtExitCallbacks() {
    foreach(dg; _atExitCallbacks) {
        dg();
    }
    _atExitCallbacks.length = 0;
}

struct ServiceInterface {
    enum State {
        DOWN,
        SETUP,
        UP,
        DISABLED,
        TEARDOWN,
    }

    string[] deps;
    bool delegate() setup;
    void delegate() teardown;
    State state = State.DOWN;
}

mixin template registerService() {
    __gshared static typeof(this) instance;

    shared static this() {
        import std.string;
        import std.traits;
        import mecca.runtime.services: ServiceInterface, _registeredServices;

        string svcName;
        ServiceInterface svcCbs;

        static if (__traits(hasMember, typeof(this), "SVC_NAME")) {
            svcName = typeof(this).SVC_NAME;
        }
        else if (typeof(this).stringof.toLower.endsWith("service")) {
            svcName = typeof(this).stringof[0 .. $-6];
        }
        else {
            svcName = typeof(this).stringof;
        }

        static if (__traits(hasMember, typeof(this), "getDeps")) {
            svcCbs.deps = instance.getDeps();
        }
        static if (__traits(hasMember, typeof(this), "SVC_DEPS")) {
            static if (is(typeof(instance.SVC_DEPS == string))) {
                svcCbs.deps = [instance.SVC_DEPS];
            }
            else {
                svcCbs.deps = instance.SVC_DEPS;
            }
        }
        else {
            svcCbs.deps = null;
        }

        static if (__traits(hasMember, typeof(this), "setup")) {
            svcCbs.setup = &instance.setup;
        }
        else static if (__traits(hasMember, typeof(this), "mainFib")) {
            svcCbs.setup = (){
                import mecca.reactor: theReactor;
                theReactor.spawnFiber(&instance.mainFib);
                return true;
            };
        }

        static if (__traits(hasMember, typeof(this), "teardown")) {
            svcCbs.teardown = &instance.teardown;
        }
        else {
            svcCbs.teardown = (){};
        }

        _registeredServices[svcName] = svcCbs;
    }
}

__gshared ServiceInterface[string] _registeredServices;
package __gshared void function()[][string] _serviceGlobalsInitFuncs;

template ServiceGlobal(string svc, T, string mod=__MODULE__, size_t line=__LINE__) {
    __gshared T* obj = null;
    shared static this() {
        perServiceInitFuncs[svc] ~= () {
            assert (obj is null);
            import std.traits: isStaticArray;
            static if (isStaticArray!T) {
                struct S {
                    T data;
                }
                obj = &(new S).data;
            }
            else {
                obj = new T;
            }
        };
    }
    @property ref T ServiceGlobal() @trusted nothrow @nogc {
        assert (obj !is null);
        return *obj;
    }
}

/+version (unittest) {
    private:
    alias utLong = ServiceGlobal!("UT", long);
    alias utBiggy = ServiceGlobal!("UT", long[10000]);

    unittest {
        foreach(fn; perServiceInitFuncs["UT"]) {
            fn();
        }

        assert (utLong == 0);
        utLong = 17;
        assert (utLong == 17);
        assert (utBiggy[1888] == 0);
        utBiggy[1888] = 9999;
        assert (utBiggy[1888] == 9999);
    }
}
+/




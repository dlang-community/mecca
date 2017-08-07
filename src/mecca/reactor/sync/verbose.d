/// Allows adding verbosity to sync objects
///
/// Intended for use only by sync object developers
module mecca.reactor.sync.verbose;

import mecca.log;

enum SyncVerbosityEventType {
    HazardOn, HazardOff, Contention, Wakeup
}

alias EventReporter = void delegate(SyncVerbosityEventType evt) nothrow @safe @nogc;

struct SyncVerbosity(SyncType, string Name, ExtraParam = void) {
    SyncType syncer;

private:
    enum WithExtraParam = !is(ExtraParam == void);

    static if( WithExtraParam ) {
        ExtraParam param;
    }

public:
    static if( WithExtraParam ) {
        this(ExtraParam param) nothrow @safe @nogc {
            this.param = param;
            this.syncer.setVerbosityCallback(&reportEvent);
        }

        void open( ExtraParam param ) nothrow @safe @nogc {
            this.param = param;
            this.syncer.setVerbosityCallback(&reportEvent);
        }
    } else {
        void open() nothrow @safe @nogc {
            this.syncer.setVerbosityCallback(&reportEvent);
        }
    }

    alias syncer this;

private:
    void reportEvent(SyncVerbosityEventType event) nothrow @safe @nogc {
        static if( WithExtraParam ) {
            enum NameFormat = Name ~ "(%s)";
        } else {
            enum NameFormat = Name;
        }

        with(SyncVerbosityEventType) {
            final switch(event) {
            case HazardOn:
                static if( WithExtraParam ) {
                    WARN!(NameFormat ~ " became unavailable")(param);
                } else {
                    WARN!(NameFormat ~ " became unavailable")();
                }
                break;
            case HazardOff:
                static if( WithExtraParam ) {
                    INFO!(NameFormat ~ " became available again")(param);
                } else {
                    INFO!(NameFormat ~ " became available again")();
                }
                break;
            case Contention:
                static if( WithExtraParam ) {
                    WARN!("Blocking in wait for " ~ NameFormat)(param);
                } else {
                    WARN!("Blocking in wait for " ~ NameFormat)();
                }
                break;
            case Wakeup:
                static if( WithExtraParam ) {
                    DEBUG!("Woke up after waiting for " ~ NameFormat)(param);
                } else {
                    DEBUG!("Woke up after waiting for " ~ NameFormat)();
                }
                break;
            }
        }
    }
}

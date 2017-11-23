module mecca.reactor.subsystems.processes;

import unistd = core.sys.posix.unistd;
import signal = core.sys.posix.signal;

import mecca.reactor.sync.event: Event;


//
// process execution (direct or via shell-daemon)
//

struct Process {
    string executable;
    string[] args;
    string[] env;
    int pid = -1;
    int retcode = -1;
    Event deathEvent;

    this(string[] args, string[] env = null) {
        this(args[0], args, env);
    }
    this(string executable, string[] args, string[] env = null) {
        this.executable = executable;
        this.args = args;
        this.env = env;
        pid = -1;
        retcode = -1;
    }

    @property bool isAlive() {
        return !deathEvent.isSet;
    }

    void sendSignal(int sig) {
        signal.kill(pid, sig);
    }
    void terminate() {
        // send SIGTERM, wait a little, then send SIGKILL
    }


    void wait() {
        deathEvent.wait();
    }

}


struct ProcessManager {
    void open() {
        // register SIGCHLD
    }
    void close() {
    }

}

__gshared ProcessManager processManager;



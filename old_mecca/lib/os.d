module mecca.lib.os;

version(linux) {
    extern (C) nothrow @system @nogc:
    version(X86_64) {
        private enum NR_gettid = 186;
    }
    else version (X86) {
        private enum NR_gettid = 224;
    }
    else {
        static assert (false, "Invalid platform");
    }

    @("notrace") private int syscall(int number, ...);
    @("notrace") int gettid() {return syscall(NR_gettid);}
}



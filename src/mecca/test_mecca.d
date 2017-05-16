module mecca.test_mecca;

import mecca.node;

struct MyService {
    mixin registerService;

    void setup() {
        writeln("hello from MyService");
    }
    void teardown() {
    }
}




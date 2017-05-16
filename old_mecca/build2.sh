#!/bin/bash
/opt/ldc2/bin/ldc2 \
    mecca/containers/queue.d\
    mecca/containers/linked_set.d\
    mecca/containers/array.d\
    mecca/lib/memory.d\
    mecca/lib/exception.d\
    mecca/lib/time.d\
    mecca/lib/divide.d\
    mecca/lib/reflection.d\
    mecca/lib/tracing.d\
    mecca/lib/tracing_uda.d\
    mecca/lib/hacks.d\
    mecca/reactor/fibril.d\
    mecca/reactor/reactor3.d\
    -g -O3 -release -of/build/reactor3 && /build/reactor3


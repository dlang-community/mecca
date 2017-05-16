#!/bin/bash
if (grep '\bweka\b' -R . | grep -e module -e import); then 
    echo "No weka in mecca"
    exit 1;
else
    (find . -name '*.d' | xargs dmd -defaultlib=libphobos2.so -fPIC -unittest -ofmecca_ut) && ./mecca_ut "$@"
fi



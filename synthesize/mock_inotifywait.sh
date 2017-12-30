#!/bin/sh

WAIT=true

while $WAIT ; do
    sleep 5
    MODIFIED=`git status | grep -i '.*\.wks.*' | wc -l`
    if [ "$MODIFIED" -ne 0 ] ; then
        WAIT=false
    fi
done

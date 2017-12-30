#!/usr/bin/python
#coding:utf8

#
# This script selects up to ten samples from each directory,
# in case you have more than ample samples of an instrument.
# You can then listen to the selection via keep.m3u.
#

import os
from math import ceil

#first, walk directories

print "... walking."

os.system("find . -type d > tmp")
print "reading"
with open("tmp","rt") as f:
    dirs = f.readlines()
os.unlink("./tmp")

os.system("mkdir calibrate")

for d in dirs:
    d = d[:-1] #remove trailing newline
    if d != ".":
        os.system("find '"+d+"' -type f -name '*.sl' | sort > tmp")
        with open("tmp","rt") as f:
            samples = f.readlines()
        os.unlink("tmp")
        print len(samples), "samples found in",d
        cnt = 0
        os.system("mkdir 'calibrate/"+os.path.basename(d)+"'")
        for x in samples:
            with open("calibrate/"+os.path.basename(d)+"/smp"+str(cnt)+".cfg","wt") as f:
                f.write("NAME "+os.path.basename(d)+"_calib\nDRUM 36\nTIME 32\nVELOCITY 33\n"+
                        """GAIN 0
    BALANCE 0
    TIME VARIANCE 0
    VELOCITY VARIANCE 0
    AUTO DAMP DELAY 0
    USER DAMP DELAY 0
    """)
                f.write("RAW rota-kit/"+x)
            cnt += 1

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


for d in dirs:
    d = d[:-1] #remove trailing newline
    if d != ".":
        os.system("find '"+d+"' -type f -name '*.wav' | sort > tmp")
        with open("tmp","rt") as f:
            samples = f.readlines()
        os.unlink("tmp")
        print len(samples), "samples found in",d
        if len(samples) <= 10:
            k = ""
        else:
            k = "02"
        for i in range(len(samples)):
            newname = d + os.path.sep + os.path.basename(d)+("%"+k+"d")%i + ".wav"
            print samples[i].strip(), "->", newname
            os.rename(samples[i].strip(), newname)

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

maxsmps = 10

keep = open("keep.m3u","wt")
remove = open("remove.m3u","wt")

for d in dirs:
    d = d[:-1] #remove trailing newline
    if d != ".":
        os.system("find '"+d+"' -type f -name '*.wav' | sort > tmp")
        with open("tmp","rt") as f:
            samples = f.readlines()
        os.unlink("tmp")
        print len(samples), "samples found in",d
        if len(samples) > maxsmps:
            print "Too many samples.... (",len(samples),")"
            retain_idxs = [0] + [int(ceil(1 + float(i-1)*(len(samples)-1)/(maxsmps-1))) for i in range(1,maxsmps-1)] + [len(samples)-1]
        else:
            retain_idxs = list(range(len(samples)))
        for i in range(len(samples)):
            if i in retain_idxs:
                keep.write(samples[i])
            else:
                remove.write(samples[i])

keep.close()
remove.close()

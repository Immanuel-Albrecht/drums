#!/usr/bin/python
#coding:utf8

#
# This script selects up to ten samples from each directory,
# in case you have more than ample samples of an instrument.
# You can then listen to the selection via keep.m3u.
#

import os
from math import ceil

#config data:

cfg = """
#cymb
ride1           51
ride2           59
ride_bel        53

#cymb
crash2          57

#drum
floor_hi        43

#cymb
hihat_ped       44
hihat_opn       46
hihat_cls       42

#drum
snare_rms       40
snare_prs       39
snare_sidestick 37
snare_ord       38

#drum
tom_mid         47

#drum
tom_hi          48

#cymb
splash          55

#cymb
crash1          49

#cymb
china           52


#drum
kick_a          35
kick_b          36

#drum
tom_lo          45

#drum
floor_lo        41
"""

groups = []
current_group = []
for x in cfg.split("\n"):
    x = x.strip()
    if x.startswith("#"):
        current_group = [x]
        groups.append(current_group)
    elif len(x):
        current_group.append(x.split())

os.system("mkdir cfg")

for x in groups:
    if x[0].lower().startswith("#c"):
        time = 26
        timevar = "128"
        velocity = 27
        velvar = "2.6"
        damp = "UNSET USERDAMP\nUNSET AUTODAMP\nUSER DAMP DELAY 0\nAUTO DAMP DELAY 0\n"
    else:
        time = 24
        timevar = "128"
        velocity = 25
        velvar = "2.6"
        damp = "UNSET USERDAMP\nSET AUTODAMP\nUSER DAMP DELAY 0\nAUTO DAMP DELAY 0\n"
    notes = [int(y[1]) for y in x[1:]]
    for y in x[1:]:
        print "drum_kit_config(",y[1],",",repr(y[0]),",[])"
        with open("cfg/"+y[0]+".cfg","wt") as f:
            f.write("NAME "+y[0]+"\n")
            f.write("DRUM "+y[1]+"\n")
            f.write("TIME "+str(time)+"\n")
            f.write("TIME VARIANCE "+timevar+"\n")
            f.write("VELOCITY "+str(velocity)+"\n")
            f.write("VELOCITY VARIANCE "+velvar+"\n")
            f.write(damp)
            for n in notes:
                if n != int(y[1]):
                    f.write("DAMP "+str(n)+"\n")
                    f.write("DRUM "+str(n)+" DAMP DELAY 0\n")
            f.write("DELAY 0\n")
            os.system("find '"+y[0]+"' -type f -name '*.sl' | sort > tmp")
            with open("tmp","rt") as f2:
                samples = f2.readlines()
            os.unlink("tmp")
            for s in samples:
                f.write("RAW rota-kit/"+s)

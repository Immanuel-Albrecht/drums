# drums
A jack-audio X-platform drum sampler hacked together in D


Quality Disclaimer
==================

This repository contains code that I hacked together in order to generate
play-along metal drum tracks. I started the project in 2015 and got it working
for me by early 2016; but I wasn't satisfied with the overall code quality, so
I wanted to fix this before I release the software. Well, I didn't fix anything
and I will probably never have enough time to do so, therefore I am releasing
this steaming mess of code.

About
=====

The program *drums* is a proof of concept that you can write non-trivial audio
applications in D, and that you can end up with software that runs on
  - Windows
  - MacOSX
  - Debian Linux

What does *drums* do?
=====================

Drums is a program that listens for MIDI input and plays back a bunch of
samples accordingly. It has a primitive GUI that can be used to test
the setup of the sampler without having to connect it to

What does *synthesize* do?
==========================
Synthesize is similar to a modular tracker or sequencer,
you can compose and cobble together different drum patterns
which on playback will generate MIDI events that drive the sampler.
You can customize the MIDI note mapping in the file *drumkit.d*.
There are two modes, one for hackers, and one called *./sketch.sh*
with a more decent GUI -- use this one uses the MIDI note mapping from
*drumkit.d* and the defaults from *sketchui.d*.
 A nice feature here is the rehearsal mode that allows
you to display
your guitar tabs (or any other image)
in a riff-wise fashion; so you don't have to manually
switch pages anymore.


Mileage May Vary
================

In general, I made several not so good choices. First, I used dlangui,
which is pre-1.0.0 software and therefore breaks rather often.
The current version from github (dlangui 0.9.173+commit.8.g24d70c0e)
seems to work fine, though I get deprecation warnings for now.

There is also a port of libjack available via dub, unfortunately there were
some issues with it, so I
had to hack it, and *this software won't work with the official version of libjack*.


Lessons Learned
===============

One thing that I learned is that inside a jack thread, you cannot have most
of the sugary features that D offers. Especially anything that might
somehow trigger the garbage collection will kill your jack thread. A
clean way would be to have the `@nogc`-flag for the callback function,
but that would require some adjustments to the libjack port, but I
recently gave up to do this. Unfortunately, parts of the MIDI code in
libjack actually created new objects, and I had to patch this behaviour. Using
objects that have been allocated somewhere else and that will be deallocated
somewhere else seems to be no big problem in a jack callback, though.

Windows
=======

Both programs run on Windows. I am aware that the typical Windows user
never compiles her_his software him_herself. Therefore I provided some
binaries without any warranty (the question is: do you trust a random Linux
  user
  to be able to keep his Windows free of malware?)
Furthermore, the Windows user would have to edit the `sampler.bat` file
in order to reflect his_her configuration files.


How To Configure It?
====================

If you just want to use the song-sketch
util, you could use Ardour in order to link it against the General MIDI
percussion kit. But since this is only half of the deal,
I'm going to create a tutorial here, which guides you how to use your favorite
drum samples in connection with drums. Unfortunately, I cannot provide you
with free samples, and I also do not know of any free drum sample library
that is worth the hassle of going through the configuration process.
There used to be a pretty decent free to use sample library called
`ns_kit7free`, but the
original author sold it and it is no longer available for free download.
Even more unfortunate for you is the fact that the DVD version that could be
bought for about 80 GBP is also no longer available, and the follow-up website
marketing it as a paid download seems to be defunct, too. On the other hand,
you can use any sample library there is, as long as you can export the samples
to 32bit big-endian raw 2-channel sample files (or k-channels if you
  bother to edit the corresponding source file *immutables*).

Setup Walk-Through
==================

Step 0
------

You should get hold of `python`, `bash`, and `sox`, somehow.
On debian, you would use `apt-get` for it, on mac `brew`, and on Windows
you probably should use the cygwin installer tool.

Step 1
------

You should create a directory for every drum that you wish to sample,
and copy the corresponding sample files (`.wav`s, for instance)
in that folder, such that the samples that correspond to weak hits
have filenames that are ''smaller'' than the stronger hits. I have
never seen a sample library, where you would have to rename the files
in order to achieve this. It goes without saying that you need at least one
sample per drum for this to work.

Step 1b (optional)
------------------

I consider 10 samples per drum to be enough for my purposes, and since
I have been lazy and copied whole directories, I have to
weed out some samples. In order to do that, I run `./up_to_ten_samples.py`
to generate a `keep.m3u`. Then I check whether those samples make sense
by listening to all of them. If I am happy, I delete all files from
`remove.m3u` by hacking
```bash
 for i in `cat remove.m3u`; do rm "$i"; done
 ```
Probably I do not like how the files are named, so I rename them
with `./rename_files.py`.

Step 2
------

Now we have to convert the audio files to the simplest possible
way to store them: 32bit singed big-endian integer frames consisting
of the two stereo channel samples. If your sample library is like mine,
you would also want to chop off the silence at the beginning of the samples.
I create the bash script for that as follows
```bash
echo '!#/bin/bash' > convert_and_trim.sh
chmod +x convert_and_trim.sh
for i in **/*wav; do
  echo sox "$i" -t sl --encoding signed-integer --bits 32 --endian big "${i%wav}sl" silence 20s 0s -76d trim 0s
done  
```

Clearly, this script does not work if you don't have *glob* on, or
if you used spaces anywhere (don't!). The second *0s* after trim can be
used to further tweak the trimming if needed.
Now, we just run `./convert_and_trim.sh`.

Step 3
------

Now, you should edit the `cfg` variable in `create_config.py`
to reflect the directory names and drums that you have. You can group
drums with `#drum` and cymbals with `#cymb`. Each tag creates a new
mute group, and should be followed by the directory names of the
drums that belong to that group, followed by the assigned midi note
number of that drum. If you run `./create_config.py` the configuration
files for the drums are created for you; and they will work as long as
your files are in a sub-directory called `rota-kit` (you might want to
  change that in the scripts, though) and as long as you start
  the sampler like this:
```bash
dub -- rota-kit/cfg/*
```
or
```bash
./drums rota-kit/cfg/*
```
or by editing the `sampler.bat`.

Step 4
------
You probably want to edit `drumkit.d` and `sketchui.d` to reflect
your drum kit configuration.

Drum Configuration Files
========================

*drums* uses a single configuration file per drum which is added to
the command line in order to load it.
Basically, that file consists of directives from this list:

NAME $name
     __ sets the name of this drum
DRUM $pitch
     __ sets the MIDI pitch where the drum listens to hits
TIME $pitch
     __ sets the MIDI pitch where the drum listens to timing-accuracy hints
VELOCITY $pitch
     __ sets the MIDI pitch where the drum listens to velocity-accuracy hints
DAMP $pitch
     __ adds a MIDI pitch where the drum listens to hits in order to damp itself
SET AUTODAMP
    __ damp previous hits on next hit
UNSET AUTODAMP
    __ do not damp previous hits on next hit
SET USERDAMP
     __ respond to damp-hits on drum pitch (damp on note-off event)
UNSET USERDAMP
     __ do not respond to damp-hits on drum pitch
BALANCE $dB
     __ left-right balance, left channel is enhanced by -$dB,
                           right channel is enhanced by +$dB.
GAIN $dB
     __ trim gain
DELAY $frames
     __ set the delay for the drum (default: 96 frames)
AUTO DAMP DELAY $frames
     __ set the additional delay for damping on another drum hit
USER DAMP DELAY $frames
     __ set the additional delay for damping requests by the user (other mute group drum hits)
DRUM $pitch DAMP DELAY $frames
     __ set the additional delay for damping when the drum $pitch is hit.
TIME VARIANCE $frames
     __ set the variance for the default timing-accuracy (default: 100 frames)
VELOCITY VARIANCE $dB
     __ set the variance for the default velocity-accuracy (default: 2 dB)
ADJUST $frames
     __ add $frame zero frames to the front of the last loaded sample, or
        if $frame < 0, remove $frames from the front of the last loaded sample
RAW $sl_file_name
     __ load the given raw sample file

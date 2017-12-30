module pattern;

import drumkit;
import config;
import std.array;
import std.string;
import std.algorithm;
import std.stdio;
import std.conv;
import std.regex;

/** this module contains data structures and helpers for playback patterns */

struct PatternHit {
    int pitch;
    int velocity;
}

struct PatternConfig {
    string name;
    ubyte pitch;
    PatternHit[][] per_beat;
    string description;

    this(string n, ubyte p, string sequence) {
        description = sequence;
        name = n;
        pitch = p;
        per_beat = pattern_from_string(sequence);
    }
}

struct PatternChannelConfig {
    string name;
    PatternConfig[] patterns;
}

struct PatternState {
    bool playing;
    bool hold;
    ulong current_beat;
    int repeat_count;
}

PatternChannelConfig[] build_pattern_channel_config(string s) {
    PatternChannelConfig[] channels;
    bool is_hot = false;
    PatternChannelConfig current_channel;
    int pitch = 60;
    current_channel.name = "unnamed channel 1";

    foreach (idx, line; lineSplitter(s).array) {
        auto words = splitter(strip(line)).array;
        if (words.length < 1)
            continue; /* empty line */
        auto leftmost = toUpper(words[0]);

        if (leftmost.length < 1)
            continue;

        /* comment */
        if (leftmost[0] == '#')
            continue;

        /* new channel */
        if (leftmost == "CHANNEL") {
            if (is_hot)
                channels ~= current_channel;

            is_hot = true;
            if (words.length > 1)
                current_channel = PatternChannelConfig(words[1], []);
            else
                current_channel = PatternChannelConfig(
                    "unnamed channel " ~ to!string(channels.length + 1));

            continue;
        }

        /* check for format */
        auto components = match(line, regex(`^\s*([0-9]*)\s*([^:]*:)(.*)`));

        auto description = line;
        auto name = "";

        if (!components.empty) {
            try {
                int val = to!int(components.captures[2]);
                pitch = val;
            }
            catch (Throwable all) {
            }

            description = components.captures[3];
            name = components.captures[1];
        }

        auto pat = PatternConfig(name, cast(ubyte)pitch, description);

        current_channel.patterns ~= pat;
        is_hot = true;

        ++pitch;

    }

    if (is_hot) {
        channels ~= current_channel;
    }

    return channels;
}

unittest {
    writeln("Testing Pattern-Format:");
    writeln(
        build_pattern_channel_config(
        " 53 XS: ax/b:c://i\n QS: ax/q/b/h\n 57: a x- b h\n a b/c h"));
}

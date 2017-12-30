module common;

import std.stdio;

import jack.client;
import jack.midiport;
import std.regex;

import std.stdio;
import std.math;
import core.thread;
import core.stdc.string;
import core.memory;

import dlangui;
import std.utf;

import core.sync.mutex;

import config;
import sync;
import pattern;

auto wait_for_jack() {

    JackClient client = new JackClient;
    bool success = false;

    while (!success) {
        // Try to connect to jack util jack is available, do not start on our own

        try {
            client.open(name, JackOptions.JackNoStartServer, null);
            success = true;
        }
        catch (JackError e) {
            writeln("Error opening jack client: ", e.msg);
            Thread.sleep(dur!"seconds"(1));
            writeln("Trying again.");
        }
    }

    /* Tell Jack to be fine with any kind of XRun */
    client.xrun_callback = delegate int() { return 0; };

    return client;
}

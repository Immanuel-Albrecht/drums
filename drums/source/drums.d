module drums;

import sampler;
import bisection;

import jack.client;
import jack.midiport;
import std.regex;

import std.stdio;
import std.math;
import core.thread;
import core.stdc.string;
import core.memory;
import std.algorithm : startsWith;
import std.string : strip;

import dlangui;
import std.utf;

import core.sync.mutex;

string name = "drums.d";

//debug = printMidiCommands;
//debug = ui;

//debug = active_drums;

mixin APP_ENTRY_POINT;

/// entry point for dlangui based application
extern (C) int UIAppMain(string[] args) {
     writeln("UIAppMain (",args,")");
    return drums_main(args); /* call own main function */
}

immutable auto calibration_interval = 40000;


/** implements a hard limiter */

pure float hard_limit(float f) @safe @nogc  {
    if ((f < .95) && (f > -.95))
        return f;
    if (f > 0.) {
        if (f > 2.)
            return 1.0;
        return 0.181405895691609*f -0.0453514739229023*(f*f)+ 0.818594104308390;
    } else {
        if (f < -2.)
            return -1.0;
        return 0.181405895691609*f +0.0453514739229023*(f*f)- 0.818594104308390;
    }
}


/*
 Usage: drums [--name=JACK_CLIENT_NAME] drum1.cfg [drum2.cfg [..]]
 
 where drum*.cfg are configuration files for each drum

 */


int drums_main(string[] args) {

    /* if this gives an error, use `dub add-local ../jack-1.0.1` */
    writeln("jack-1.0.1: ", using_modified_version_of_jack);

    writeln(name, "\n  -+ loading drums.");
    // Sampler
    auto m_drums = new Mutex;

    DrumSampler[] drums;
    string[] config_paths;

    bool do_gc = false;
    bool connect_system = true;

    /* workaround for windows native cmd command line */

    if (args[0].startsWith("@")) {
	 string[] cmdline;
	 foreach (l; args[0][1 .. $].File.byLine) {
	 	cmdline ~= to!string(l.strip.dup);
	 }
	 args = cmdline;
    }

    for (int i = 1; i < args.length; ++i) {

        auto o_name = match(args[i], regex(`^--name=(.*)`));
        if (!o_name.empty) {
            name = o_name.captures[1].dup;
            writeln("   +-- client name =\"", name, "\"");
        } else {
            if (match(args[i],regex(`^--no-gc`)))
                    {
                        do_gc = false;
                    } else {
            if (match(args[i],regex(`^--output`)))
                    {
                        connect_system = true;
                    } else {
            writeln("   +-+ drum config = \"", args[i], "\"");
            config_paths ~= args[i];
            drums ~= new DrumSampler(args[i]);
        }}}
    }

    // communication pipeline

    auto m_com = new Mutex;
    bool[] calibrate_drum;
    int calibration_velocity = 120;
    foreach (d; drums)
        calibrate_drum ~= false;

    // Jack state
    jack_nframes_t calibration_accumulator = 0;

    // Jack Interface
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
    scope (exit)
        client.close();

    writeln("New jack_client with name: " ~ client.get_name());

    JackPort midi = client.register_port("In",
        JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsInput, 0);
    JackPort out1 = client.register_port("Out1",
        JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);
    JackPort out2 = client.register_port("Out2",
        JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);

    /* Tell Jack to be fine with any kind of XRun */
    client.xrun_callback = delegate int() { return 0; };

    /* local variables for jack callback */
    JackMidiPortBuffer midibuf;
    JackMidiEvent event;
    JackMidiPortBufferRange iter_events;

    /* Jack callback routine */
    client.process_callback = delegate int(jack_nframes_t nframes) {
        try {
            synchronized (m_drums) {

                calibration_accumulator += nframes;
                if (calibration_accumulator >= calibration_interval) {

                    if (m_com.tryLock) {
                        scope (exit)
                            m_com.unlock;

                        calibration_accumulator %= calibration_interval;

                        /* read comm input and generate calibration requests */
                        for (auto idx=0;idx<drums.length;++idx)
                        {
                            if (calibrate_drum[idx])
                                drums[idx].calibration_tick(calibration_velocity);
                        }
                    }
                }

                midibuf = midi.get_midi_buffer(nframes);
                
                iter_events = midibuf.iter_events();
                while (!iter_events.empty()) 
                {
                    event = iter_events.front();
                    iter_events.popFront();
                    
                    if (event.size == 3) {
                        if (event.buffer[0] == 0x80
                                || event.buffer[0] == 0x90 && event.buffer[2] == 0) {
                            debug (printMidiCommands)
                                writeln("DAMP ", event.buffer,
                                    " ", event.buffer[1], "@", event.buffer[2]);
                            for (auto idx=0;idx<drums.length;++idx)
                                drums[idx].damp(event.buffer[1], event.buffer[2]);
                        } else if (event.buffer[0] == 0x90) {
                            debug (printMidiCommands)
                                writeln("HIT  ", event.buffer,
                                    " ", event.buffer[1], "@", event.buffer[2]);
                            for (auto idx=0;idx<drums.length;++idx)
                                drums[idx].hit(event.buffer[1], event.buffer[2]);
                        }
                    }
                }

                float* buf1 = out1.get_audio_buffer(nframes);
                float* buf2 = out2.get_audio_buffer(nframes);

                for (auto x = 0;
                x < nframes;
                ++x) {
                    buf1[x] = 0;
                    buf2[x] = 0;
                }

                debug (active_drums) int count = 0;

                for (auto idx=0;idx<drums.length;++idx)
                    if (!drums[idx].may_skip) {
                        drums[idx].write(buf1, buf2, nframes);
                        debug (active_drums) ++count;
                    }
                debug (active_drums) writeln("Active Drums: ",count);

                /* hard limiter */
                for (auto x = 0;
                x < nframes;
                ++x) {
                    buf1[x] = hard_limit(buf1[x]);
                    buf2[x] = hard_limit(buf1[x]);
                }
            }

            return 0;
        }
        catch (Throwable all) {
            writeln("process_callback: ", all);
            return 0;
        }
    };

    /* dlangui window stuff */

    Window window = Platform.instance.createWindow(
        to!dstring(name ~ " - Control"), null);

    /* interface layout */
    class myVerticalLayout : VerticalLayout {
        override bool onTimer(ulong id) {

            GC.enable();
            GC.collect();
            GC.minimize();
            GC.disable();

            return true;
        }
    }

    auto layout = new VerticalLayout;

    foreach (idx, drum; drums) {
        auto line = new HorizontalLayout;
        auto calibrate_box = new CheckBox;

        calibrate_box.text = "";
        calibrate_box.checkChange = (idx => delegate(Widget w, bool s) {
            synchronized (m_com) {
                calibrate_drum[idx] = s;
                debug (ui)
                    writeln("calibrate ", idx, " <-", calibrate_drum[idx]);

            }
            return true;
        })(idx);

        line.addChild(calibrate_box);

        line.addChild(new TextWidget(null,
            to!dstring(drum.name) ~ " " ~ to!dstring(drum.drum_pitch) ~ "  (t" ~ to!dstring(
            drum.timing_pitch) ~ "/v" ~ to!dstring(drum.stability_pitch) ~ ")  Delay:"));

        immutable amounts = [-100, -10, -5, -1, 1, 5, 10, 100];
        auto delay = new TextWidget(null, to!dstring(drum.current_delay));

        foreach (x; amounts) {
            auto btn = new Button(null, to!dstring(x));
            btn.click = (delay => (x => (drum => delegate(Widget w) {
                synchronized (m_drums) {
                    drum.current_delay += x;
                    delay.text = to!dstring(drum.current_delay);
                }
                return true;
            })(drum))(x))(delay);
            line.addChild(btn);
        }

        line.addChild(delay);
        line.addChild(new TextWidget(null, to!dstring(config_paths[idx])));

        layout.addChild(line);
    }

    auto scroll = new ScrollWidget;
    scroll.contentWidget = layout;

    auto vm = new myVerticalLayout;
    vm.addChild(scroll);

    auto status = new HorizontalLayout;

    status.addChild(new TextWidget(null,
        "Total Drums: "d ~ to!dstring(drums.length)));
    status.addChild(new TextWidget(null, "  Calibration-Velocity: "d));
    auto min10 = new Button(null, "- 10"d);
    auto min1 = new Button(null, "- 1"d);
    auto vel = new TextWidget(null, to!dstring(calibration_velocity));
    auto plus1 = new Button(null, "+ 1"d);
    auto plus10 = new Button(null, "+ 10"d);

    min10.click = delegate(Widget w) {
        synchronized (m_com) {
            calibration_velocity -= 10;
            if (calibration_velocity < 1)
                calibration_velocity = 1;
            vel.text = to!dstring(calibration_velocity);
        }
        return true;
    };
    min1.click = delegate(Widget w) {
        synchronized (m_com) {
            calibration_velocity -= 1;
            if (calibration_velocity < 1)
                calibration_velocity = 1;
            vel.text = to!dstring(calibration_velocity);
        }
        return true;
    };
    plus10.click = delegate(Widget w) {
        synchronized (m_com) {
            calibration_velocity += 10;
            if (calibration_velocity > 127)
                calibration_velocity = 127;
            vel.text = to!dstring(calibration_velocity);
        }
        return true;
    };
    plus1.click = delegate(Widget w) {
        synchronized (m_com) {
            calibration_velocity += 1;
            if (calibration_velocity > 127)
                calibration_velocity = 127;
            vel.text = to!dstring(calibration_velocity);
        }
        return true;
    };

    status.addChild(min10);
    status.addChild(min1);
    status.addChild(vel);
    status.addChild(plus1);
    status.addChild(plus10);

    vm.addChild(status);

    window.mainWidget = vm;

    window.show();

    if (do_gc) {
        writeln("Runnig GC in background.");
        vm.setTimer(1000);
    }
    /* main loop */

    int retval;

    try {
        /* clean up */
        core.memory.GC.collect();
        core.memory.GC.minimize();
        /* disable garbage collector */
        core.memory.GC.disable();

        client.activate();

        if( connect_system) {
        try {
            writeln(" Connecting Out 1: ",
                client.connect(out1.get_name, "system:playback_1"));
        }
        catch (Throwable all) {
        }
        try {
            writeln(" Connecting Out 2: ",
                client.connect(out2.get_name, "system:playback_2"));
        }
        catch (Throwable all) {
        }
        }

        /* run main message loop */
        retval = Platform.instance.enterMessageLoop();

    }
    catch (Throwable all) {
        writeln("Main: ", all);
        return 99;
    }

    core.memory.GC.enable();
    return retval;
}

module synthesize;

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
import common;

//debug = printMidiCommands;
//debug = beats;
//debug = hits;
//debug = uiSync;
//debug = ui;
//debug = patternState;

//debug = printAllEvents;
//debug = output;

int syn_main(string[] args) {

    /* if this gives an error, use `dub add-local ../jack-1.0.1` */
    writeln("jack-1.0.1: ", using_modified_version_of_jack);

    writeln(name, "\n -+ startup.");

    string config_data = "";
    bool no_default = false;

    for (int i = 1; i < args.length; ++i) {

        auto o_name = match(args[i], regex(`^--name=(.*)`));
        if (!o_name.empty) {
            name = o_name.captures[1].dup;
            writeln("   +-- client name =\"", name, "\"");
        } else {
            writeln("   +-- channel config =\"", args[i], "\"");

            auto f = args[i].File;
            foreach (l; f.byLine) {
                config_data ~= l ~ "\n";
            }

            no_default = true;
        }
    }

    writeln("\n -- channel configuration.");
    writeln("    ~~~ building pattern channel config");
    auto channels = build_pattern_channel_config(
        no_default ? config_data : default_pattern_config);
    writeln("    ~~~ " ~ to!string(channels.length) ~ " channels");

    foreach (c; channels) {
        writeln("\n    -- channel ", c.name);
        foreach (p; c.patterns) {
            writeln("         -- ", p.pitch, " ", p.name, " ",
                p.description, " ", p.per_beat);
        }
    }

    writeln("\n -+ done.");

    // Jack Interface
    JackClient client = wait_for_jack();
    scope (exit)
        client.close();

    JackPort[] patterns;
    foreach (c; channels) {
        writeln(name, "\n -+ register: ", c.name);
        JackPort control = client.register_port(c.name,
            JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsInput,
            0);
        patterns ~= control;
    }
    JackPort tempo = client.register_port("Tempo",
        JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsInput, 0);

    JackPort hits = client.register_port("Hits",
        JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsOutput, 0);
    JackPort params = client.register_port("Parameters",
        JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsOutput, 0);
    JackPort ticks = client.register_port("Ticks",
        JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsOutput, 0);

    /* jack callback global variables */
    jack_nframes_t beat_accumulator;
    jack_nframes_t beat_length = initial_beat_length;
    jack_nframes_t next_beat_length = initial_beat_length;
    jack_nframes_t tempo_accumulator;
    int retrigger_release_events = -1;
    bool clock_ticking = initially_ticking;
    bool on_hold = false;
    bool tick_through = false;

    ulong[ubyte][] pitch_lookup_table;

    PatternState[][] states;
    foreach (c; channels) {
        PatternState[] c_state;
        ulong[ubyte] lookup;

        writeln(name, "\n -+ states: ", c.name);
        foreach (idx, p; c.patterns) {
            lookup[p.pitch] = idx;
            c_state ~= PatternState();
        }
        states ~= c_state;
        pitch_lookup_table ~= lookup;
    }
    writeln("Pat States:");
    writeln(states);

    /* synchronization things */

    auto m_sync = new Mutex;

    bool chpat = false;
    int chpat_ch;
    int chpat_p;
    string chpat_s;

    auto sync_bool = [
        new synchronizer!bool(&on_hold, "Hold clock"),
        new synchronizer!bool(&clock_ticking, "Clock running"),
        new synchronizer!bool(&tick_through, "Tick once")
    ];
    auto sync_nf = [
        new synchronizer!jack_nframes_t(&beat_accumulator,
        "Beat offset"),
        new synchronizer!jack_nframes_t(&beat_length,
        "Current beat length (only once)"),
        new synchronizer!jack_nframes_t(&next_beat_length,
        "Beat length (next beat and on..)"),
        new synchronizer!jack_nframes_t(&tempo_accumulator,
        "Current set-tempo duration")
    ];

    PatternState s_;
    sync.synchronizer!(PatternState)[] sync_pats = [];

    foreach (idc, X; states)
        foreach (idp, ref s; X) {
            sync_pats ~= new synchronizer!PatternState(&s,
                channels[idc].name ~ " " ~ channels[idc].patterns[idp].name ~ " (" ~ to!string(
                channels[idc].patterns[idp].pitch) ~ ")");
        }

    /* state variables */

    int[128] emit_hit;
    emit_hit[0 .. $] = -1;

    /* event templates */
    ubyte[3] tick_evt = [0x90, tick_clock, 127];
    ubyte[3] tick_evt2 = [0x90, tick_clock, 0];
    ubyte[3] tick_evt3 = [0x80, tick_clock, 127];
    ubyte[3] hit_evt = [0x90, tick_clock, 127];
    ubyte[3] hit_evt2 = [0x90, tick_clock, 0];
    ubyte[3] hit_evt3 = [0x80, tick_clock, 127];

    /* "local variables" */

    bool tick;
    JackMidiPortBuffer midibuf;
    PatternState[] state_array;
    ulong[ubyte] lookup;
    ulong* which;
    JackMidiPortBuffer hit_out;
    JackMidiPortBufferRange iter_events;
    JackMidiEvent event;
    JackMidiPortBuffer tx_out;

    /* Jack callback routine */
    client.process_callback = delegate int(jack_nframes_t nframes) {
        tick = tick_through;
        tick_through = false;

        try {
            if (clock_ticking && (!on_hold))
                beat_accumulator += nframes;

            if (clock_ticking)
                tempo_accumulator += nframes;

            {
                /*
                 * Control Patterns MIDI Input
                 *
                 */

                for (auto idx = 0;
                idx < patterns.length;
                ++idx) {

                    state_array = states[idx];
                    lookup = pitch_lookup_table[idx];

                    midibuf = patterns[idx].get_midi_buffer(nframes);
                    iter_events = midibuf.iter_events();
                    while (!iter_events.empty()) {
                        event = iter_events.front();
                        iter_events.popFront();
                        debug (printAllEvents) {
                            write("IN: ", channels[idx].name,
                                ": ", event, " DATA =");
                            for (auto idx_ = 0;
                            idx_ < event.size;
                            ++idx_)
                            write(" ", event.buffer[idx_]);
                            writeln;
                        }

                        if (event.size == 3) {
                            if (event.buffer[0] == 0x80
                                    || (event.buffer[0] == 0x90
                                    && event.buffer[2] == 0)) {
                                debug (printMidiCommands)
                                    writeln("@In: DAMP ",
                                        event.buffer, " ",
                                        event.buffer[1], "@", event.buffer[2]);

                                which = (event.buffer[1] in lookup);
                                if (which) {
                                    state_array[cast(int)*which].hold = false;

                                    debug (patternState)
                                        writeln("Pat ", *which, " hold off.");
                                }

                            } else if (event.buffer[0] == 0x90) {
                                debug (printMidiCommands)
                                    writeln("@In: HIT  ",
                                        event.buffer, " ",
                                        event.buffer[1], "@", event.buffer[2]);

                                which = (event.buffer[1] in lookup);
                                if (which) {

                                    debug (patternState)
                                        writeln("Pat ", *which, " hold on.");

                                    state_array[cast(int)*which].hold = true;
                                    auto velocity = event.buffer[2];

                                    if (velocity >= stop_pattern_no_reset_threshold) {
                                        debug (patternState)
                                            writeln("Pat ",
                                                *which, " current_beat <- 0.");
                                        state_array[cast(int)*which].current_beat = 0;
                                    }

                                    if (velocity < cancel_pattern_threshold) {
                                        debug (patternState)
                                            writeln("Pat ",
                                                *which, " playing <- false.");
                                        state_array[cast(int)*which].playing = false;
                                    }

                                    if (velocity < stop_pattern_threshold) {
                                        debug (patternState)
                                            writeln("Pat ",
                                                *which, " repeat_count <- 0.");
                                        state_array[cast(int)*which].repeat_count = 0;
                                    } else {
                                        state_array[cast(int)*which].playing = true;
                                        debug (patternState)
                                            writeln("Pat ",
                                                *which, " playing <- true.");

                                        if (
                                                velocity < infinite_repeat_pattern_threshold) {
                                            state_array[cast(int)*which].repeat_count = velocity - stop_pattern_threshold;
                                        } else {
                                            state_array[cast(int)*which].repeat_count = -1;
                                        }
                                        debug (patternState)
                                            writeln("Pat ",
                                                *which,
                                                " repeat_count <- ",
                                                state_array[cast(int)*which].repeat_count,
                                                ".");
                                    }

                                } else {
                                    debug (printMidiCommands)
                                        writeln("@In: Unrecgnized ",
                                            event.buffer[0]);
                                }
                            } else if (event.buffer[0] == 176
                                    && event.buffer[1] == 64 && event.buffer[2] == 0) {
                                debug (patternState)
                                    writeln("Pat Stop.");
                                for (auto sidx = 0;
                                sidx < state_array.length;
                                ++sidx) {
                                    state_array[sidx].playing = false;
                                    state_array[sidx].hold = false;
                                }
                            } else if (event.buffer[0] == 176
                                    && event.buffer[1] == 123
                                    && event.buffer[2] == 0) {
                                debug (patternState)
                                    writeln("Pat Reset.");
                                for (auto sidx = 0;
                                sidx < state_array.length;
                                ++sidx) {
                                    state_array[sidx].playing = false;
                                    state_array[sidx].hold = false;
                                    state_array[sidx].current_beat = 0;
                                    state_array[sidx].repeat_count = 0;
                                }
                            }
                        } else {
                            debug (printMidiCommands) {
                                write("@In: Unrecgnized ", event.size,
                                    "bytes: ");
                                for (auto i = 0;
                                i < event.size;
                                ++i)
                                write(" ", event.buffer[i]);
                                writeln(".");
                            }
                        }
                    }
                }

                /*
                 * Tempo MIDI Input
                 *
                 */

                midibuf = tempo.get_midi_buffer(nframes);
                iter_events = midibuf.iter_events();
                while (!iter_events.empty()) {
                    event = iter_events.front();
                    iter_events.popFront();
                    debug (printAllEvents) {
                        write("TEMPO: ", event, " DATA =");
                        for (auto idx_ = 0;
                        idx_ < event.size;
                        ++idx_)
                        write(" ", event.buffer[idx_]);
                        writeln;
                    }

                    if (event.size == 3) {
                        if (event.buffer[0] == 0x80
                                || event.buffer[0] == 0x90
                                && event.buffer[2] <= low_threshold) {
                            debug (printMidiCommands)
                                writeln("@Tempo: DAMP ",
                                    event.buffer, " ",
                                    event.buffer[1], "@", event.buffer[2]);
                            switch (event.buffer[1]) {
                            case hold_delay:
                                on_hold = false;
                                break;
                            default:
                                break;
                            }
                        } else if (event.buffer[0] == 0x90) {
                            debug (printMidiCommands)
                                writeln("@Tempo: HIT  ",
                                    event.buffer, " ",
                                    event.buffer[1], "@", event.buffer[2]);
                            switch (event.buffer[1]) {
                            case tempo_start:
                                tempo_accumulator = 0;
                                break;
                            case hold_delay:
                                on_hold = true;
                                break;
                            case stop_clock:
                                clock_ticking = false;
                                break;
                            case start_clock:
                                clock_ticking = true;
                                break;
                            case tick_clock:
                                tick = true;
                                break;
                            case clear_clock:
                                beat_accumulator = 0;
                                break;
                            default:
                                if (event.buffer[1] >= tempo_stop) {
                                    next_beat_length = tempo_accumulator / (
                                        event.buffer[1] - tempo_stop + 1);
                                }
                                break;
                            }
                        }
                    }
                }
            }

            if (beat_accumulator >= beat_length) {
                beat_accumulator -= beat_length;
                beat_length = next_beat_length;
                tick = true;
            }

            hit_out = hits.get_midi_buffer(nframes);
            hit_out.clear();

            if (retrigger_release_events >= 0) {
                auto when = retrigger_release_events;

                if (when >= nframes) {
                    retrigger_release_events = when - nframes;
                } else {
                    for (auto idx = 0;
                    idx < emit_hit.length;
                    ++idx) {
                        if (emit_hit[idx] >= 0) {
                            ubyte i = cast(ubyte)idx;
                            hit_evt2[1] = i;
                            hit_evt3[1] = i;

                            bool retval;

                            if (note_off_zero_hit)
                                retval = hit_out.write_event(when,
                                    &hit_evt2[0], hit_evt2.length);
                            else
                                retval = hit_out.write_event(when,
                                    &hit_evt3[0], hit_evt3.length);

                            debug (output)
                                if (!retval)
                                    writeln("write_event failed (RELEASE)!");

                            emit_hit[idx] = -1;
                        }
                    }
                }
            }

            if (tick) {
                /* trigger beat event */
                debug (beats) {
                    writeln("BEAT.", beat_accumulator, " ",
                        beat_length, " ", nframes);
                }

                tx_out = ticks.get_midi_buffer(nframes);
                tx_out.clear();

                tx_out.write_event(0, &tick_evt[0], tick_evt.length);
                if (note_off_zero_hit)
                    tx_out.write_event(note_off_delay,
                        &tick_evt2[0], tick_evt2.length);
                else
                    tx_out.write_event(note_off_delay,
                        &tick_evt3[0], tick_evt3.length);

                /* do what there is to do with the patterns */

                for (auto Sidx = 0;
                Sidx < states.length;
                ++Sidx) {
                    for (auto idx2 = 0;
                    idx2 < states[Sidx].length;
                    ++idx2) {
                        if (!(states[Sidx][idx2].playing
                                || (states[Sidx][idx2].hold && pattern_play_on_hold)))
                            continue;

                        //auto pattern = channels[idx].patterns[idx2];

                        if (
                                states[Sidx][idx2].current_beat >= channels[Sidx].patterns[
                                idx2].per_beat.length) {
                            /** reached the end of the channels[Sidx].patterns[idx2] */
                            states[Sidx][idx2].current_beat = 0;

                            if (!(states[Sidx][idx2].hold && pattern_play_on_hold)) {
                                /** check whether we are out of repetitions */
                                if (states[Sidx][idx2].repeat_count != 0) {
                                    if (states[Sidx][idx2].repeat_count > 0)
                                        states[Sidx][idx2].repeat_count--;
                                } else {
                                    states[Sidx][idx2].playing = false;
                                    continue;
                                }
                            }
                        }

                        /** safeguard against empty patterns */
                        if (channels[Sidx].patterns[idx2].per_beat.length == 0)
                            continue;

                        /** process pianola slot */
                        for (auto hidx = 0;
                        hidx < channels[cast(int)Sidx].patterns[cast(int)idx2].per_beat[cast(
                            int)states[cast(int)Sidx][cast(int)idx2].current_beat].length;
                        hidx++) {
                            auto current = emit_hit[channels[cast(
                                int)Sidx].patterns[cast(int)idx2].per_beat[cast(
                                int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                int)hidx].pitch];

                            if (
                                    emit_hit[cast(
                                    int)channels[cast(int)Sidx].patterns[cast(
                                    int)idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].pitch] == 0)
                                continue; /* do not override hit events */

                            if (
                                    channels[Sidx].patterns[idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].velocity == 0) {
                                emit_hit[cast(
                                    int)channels[cast(int)Sidx].patterns[cast(
                                    int)idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].pitch] = 0;
                                continue;
                            }

                            if (
                                    channels[cast(int)Sidx].patterns[cast(int)idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].velocity > emit_hit[channels[Sidx].patterns[idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].pitch]) {
                                /** hit with the strongest request of all currently playing patterns */
                                emit_hit[cast(
                                    int)channels[cast(int)Sidx].patterns[cast(
                                    int)idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].pitch] = channels[cast(int)Sidx].patterns[cast(
                                    int)idx2].per_beat[cast(
                                    int)states[cast(int)Sidx][cast(int)idx2].current_beat][cast(
                                    int)hidx].velocity;
                            }
                        }
                        /* count up the beat */
                        states[Sidx][idx2].current_beat++;

                    }
                }

            }

            /** emit all requested hits */

            /** we have to break this into two loops because the first note-off event
              would put the second note-on event "out-of-order" */
            for (auto idx = 0;
            idx < emit_hit.length;
            ++idx) {
                if (emit_hit[idx] >= 0) {
                    debug (hits)
                        writeln("HIT: ", idx, " @ ", emit_hit[idx]);
                    ubyte i = cast(ubyte)idx;

                    hit_evt[1] = i;
                    if (emit_hit[idx] >= 128)
                        hit_evt[2] = 127;
                    else
                        hit_evt[2] = cast(ubyte)emit_hit[idx];

                    auto retval = hit_out.write_event(beat_accumulator,
                        &hit_evt[0], hit_evt.length);

                    debug (output)
                        if (!retval)
                            writeln("write_event failed (HIT)!");

                }
            }

            auto when = beat_accumulator + note_off_delay;

            if (when >= nframes) {
                retrigger_release_events = when - nframes;
            } else {
                for (auto idx = 0;
                idx < emit_hit.length;
                ++idx) {
                    if (emit_hit[idx] >= 0) {
                        ubyte i = cast(ubyte)idx;
                        hit_evt2[1] = i;
                        hit_evt3[1] = i;

                        bool retval;

                        if (note_off_zero_hit)
                            retval = hit_out.write_event(when,
                                &hit_evt2[0], hit_evt2.length);
                        else
                            retval = hit_out.write_event(when,
                                &hit_evt3[0], hit_evt3.length);

                        debug (output)
                            if (!retval)
                                writeln("write_event failed (RELEASE)!");

                        emit_hit[idx] = -1;
                    }
                }
            }

            if (m_sync.tryLock) {
                scope (exit)
                    m_sync.unlock();

                for (auto idx = 0;
                idx < sync_bool.length;
                ++idx) {
                    sync_bool[idx].update_target;
                }
                for (auto idx = 0;
                idx < sync_nf.length;
                ++idx) {
                    sync_nf[idx].update_target;
                }
                for (auto idx = 0;
                idx < sync_pats.length;
                ++idx) {
                    sync_pats[idx].update_target;
                }

                if (chpat) {
                    chpat = false;
                    channels[chpat_ch].patterns[chpat_p].per_beat = pattern_from_string(
                        chpat_s);
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
        to!dstring(name ~ " - MIDI Event Synthesizer Control"), null);

    /* display interface */

    CheckBox[] bool_uis;
    foreach (s; sync_bool) {
        auto cb = new CheckBox;
        cb.text = UIString.fromRaw(to!dstring(s.name));
        cb.checkChange = (sync => delegate(Widget w, bool s) {
            if (m_sync.tryLock) {
                scope (exit)
                    m_sync.unlock;
                debug (uiSync)
                    writeln("UI: ", sync.name, " --> ", s);
                sync.set(s);
            }

            return true;
        })(s);
        bool_uis ~= cb;
    }

    EditLine[] nf_uis_e;
    TextWidget[] nf_uis_v;
    foreach (s; sync_nf) {
        auto txt = new TextWidget(null, ""d);
        txt.minWidth = 100;
        nf_uis_v ~= txt;
        txt.text = to!dstring("(waiting)");

        auto ed = new EditLine;
        ed.minWidth = 100;
        nf_uis_e ~= ed;
    }

    CheckBox[] ps_play;
    CheckBox[] ps_hold;
    TextWidget[] ps_current;
    TextWidget[] ps_repeat;

    foreach (s; sync_pats) {
        auto cb = new CheckBox;
        cb.text = "playing"d;
        cb.checkChange = (sync => delegate(Widget w, bool s) {
            if (m_sync.tryLock) {
                scope (exit)
                    m_sync.unlock;
                debug (uiSync)
                    writeln("UI: ", sync.name, " .playing --> ", s);
                auto x = sync.get;
                x.playing = s;
                sync.set(x);
            }

            return true;
        })(s);
        ps_play ~= cb;

        cb = new CheckBox;
        cb.text = "hold"d;
        cb.checkChange = (sync => delegate(Widget w, bool s) {
            if (m_sync.tryLock) {
                scope (exit)
                    m_sync.unlock;
                debug (uiSync)
                    writeln("UI: ", sync.name, " .hold --> ", s);
                auto x = sync.get;
                x.hold = s;
                sync.set(x);
            }

            return true;
        })(s);

        ps_hold ~= cb;

        auto txt = new TextWidget(null, "(waiting)"d);
        txt.minWidth = 60;
        ps_current ~= txt;
        auto txt2 = new TextWidget(null, "(waiting)"d);
        txt2.minWidth = 60;
        ps_repeat ~= txt2;

    }

    class myVerticalLayout : VerticalLayout {
        override bool onTimer(ulong id) {

            if (m_sync.tryLock) {
                scope (exit)
                    m_sync.unlock;
                debug (uiSync)
                    writeln("UI: sync..ing");

                foreach (idx, s; sync_bool) {
                    auto cb = bool_uis[idx];

                    cb.checked = s.get;
                }

                foreach (idx, s; sync_nf) {
                    auto lbl = nf_uis_v[idx];

                    lbl.text = to!dstring(s.get);
                }

                foreach (idx, s; sync_pats) {
                    auto v = s.get;
                    auto cb = ps_play[idx];
                    cb.checked = v.playing;
                    auto cb2 = ps_hold[idx];
                    cb2.checked = v.hold;

                    auto txt = ps_current[idx];
                    txt.text = to!dstring(v.current_beat);
                    auto txt2 = ps_repeat[idx];
                    txt2.text = to!dstring(v.repeat_count);
                }
            }

            GC.enable();
            GC.collect();
            GC.minimize();
            GC.disable();

            return true;
        }
    }

    auto layout = new VerticalLayout;

    /* add controls to layout */

    foreach (x; bool_uis) {
        auto hlayout = new HorizontalLayout;
        hlayout.addChild(x);
        layout.addChild(hlayout);
    }

    foreach (idx, s; sync_nf) {
        auto hlayout = new HorizontalLayout;
        auto label = new TextWidget(null, to!dstring(s.name));
        label.minWidth = 420;
        hlayout.addChild(label);
        hlayout.addChild(nf_uis_v[idx]);
        auto btn = new Button;
        btn.text = to!dstring(" <-- ");

        btn.click = ((sync, edit) => delegate(Widget w) {
            jack_nframes_t val;
            try {
                val = to!jack_nframes_t(edit.text);
            }
            catch (Throwable all) {
                debug (ui)
                    writeln("UI: CANNOT CONVERT ", edit.text,
                        " to jack_nframes_t!");
            }
            finally {
                if (m_sync.tryLock) {
                    scope (exit)
                        m_sync.unlock;
                    debug (uiSync)
                        writeln("UI: ", sync.name, " --> ", val);
                    sync.set(val);
                }
            }

            return true;
        })(s, nf_uis_e[idx]);

        hlayout.addChild(btn);
        hlayout.addChild(nf_uis_e[idx]);
        layout.addChild(hlayout);
    }
    layout.addChild(new TextWidget(null, " --- PATTERN --- "d));

    ulong pidx = 0;

    foreach (idx_ch, c; channels) {
        layout.addChild(new TextWidget(null, to!dstring("Channel " ~ c.name)));

        foreach (idx_p, p; c.patterns) {
            auto hlayout = new HorizontalLayout;

            hlayout.addChild(new TextWidget(null,
                to!dstring(p.pitch) ~ " "d ~ to!dstring(p.name) ~ " ["d ~ to!dstring(
                p.per_beat.length) ~ "]"d));

            hlayout.addChild(ps_play[cast(int)pidx]);
            hlayout.addChild(ps_hold[cast(int)pidx]);

            hlayout.addChild(new TextWidget(null, "@"d));
            hlayout.addChild(ps_current[cast(int)pidx]);
            auto edit = new EditLine;
            auto btn = new Button;
            btn.text = to!dstring("<-");

            btn.click = ((sync, edit) => delegate(Widget w) {
                ulong val;
                try {
                    val = to!ulong(edit.text);
                }
                catch (Throwable all) {
                    debug (ui)
                        writeln("UI: CANNOT CONVERT ", edit.text,
                            " to ulong!");
                }
                finally {
                    if (m_sync.tryLock) {
                        scope (exit)
                            m_sync.unlock;
                        debug (uiSync)
                            writeln("UI: ", sync.name, " current_beat --> ",
                                val);
                        auto x = sync.get;
                        x.current_beat = val;
                        sync.set(x);
                    }
                }

                return true;
            })(sync_pats[cast(int)pidx], edit);

            hlayout.addChild(btn);
            edit.minWidth = 60;
            hlayout.addChild(edit);
            hlayout.addChild(new TextWidget(null, "  repeat?"d));
            hlayout.addChild(ps_repeat[cast(int)pidx]);
            auto btn2 = new Button;
            auto edit2 = new EditLine;
            btn2.text = to!dstring("<-");

            btn2.click = ((sync, edit) => delegate(Widget w) {
                int val;
                try {
                    val = to!int(edit.text);
                }
                catch (Throwable all) {
                    debug (ui)
                        writeln("UI: CANNOT CONVERT ", edit.text,
                            " to ulong!");
                }
                finally {
                    if (m_sync.tryLock) {
                        scope (exit)
                            m_sync.unlock;
                        debug (uiSync)
                            writeln("UI: ", sync.name, " repeat --> ",
                                val);
                        auto x = sync.get;
                        x.repeat_count = val;
                        sync.set(x);
                    }
                }

                return true;
            })(sync_pats[cast(int)pidx], edit2);
            hlayout.addChild(btn2);
            edit2.minWidth = 60;
            hlayout.addChild(edit2);

            hlayout.addChild(new TextWidget(null, " Seq. "d));
            auto setseq = new Button;
            auto resseq = new Button;

            setseq.text = "<-"d;
            resseq.text = "(reset)"d;

            auto ed_seq = new EditLine;
            ed_seq.minWidth = 800;
            ed_seq.text = to!dstring(p.description);

            setseq.click = ((idx_ch, idx_p, ed_seq) => delegate(Widget w) {
                if (m_sync.tryLock) {
                    scope (exit)
                        m_sync.unlock;
                    chpat = true;
                    chpat_ch = idx_ch;
                    chpat_p = idx_p;
                    chpat_s = to!string(ed_seq.text);
                }
                return true;
            })(cast(int)idx_ch, cast(int)idx_p, ed_seq);
            resseq.click = ((idx_ch, idx_p, ed_seq, s) => delegate(Widget w) {
                if (m_sync.tryLock) {
                    scope (exit)
                        m_sync.unlock;
                    chpat = true;
                    chpat_ch = idx_ch;
                    chpat_p = idx_p;
                    chpat_s = to!string(s);
                }
                ed_seq.text = to!dstring(s);
                return true;
            })(cast(int)idx_ch, cast(int)idx_p, ed_seq, p.description);

            hlayout.addChild(setseq);
            hlayout.addChild(ed_seq);
            hlayout.addChild(resseq);

            layout.addChild(hlayout);

            ++pidx;
        }

    }
    auto scroll = new ScrollWidget;
    scroll.contentWidget = layout;

    auto vm = new myVerticalLayout;
    vm.addChild(scroll);

    window.mainWidget = vm;

    writeln("\n -+ show window.");
    window.show();

    vm.setTimer(250);
    /* main loop */

    int retval;
    //    writeln("\n -+ disable GC.");

    try {
        /* clean up */
        core.memory.GC.collect();
        core.memory.GC.minimize();
        /* disable garbage collector */
        core.memory.GC.disable();

        writeln("\n -+ start jack.");
        client.activate();

        writeln("\n -+ message loop.");
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

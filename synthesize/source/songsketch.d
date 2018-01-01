module songsketch;

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

import sketchui;
import sketch;
import core.atomic;
import std.concurrency;
import jack.c.jack;
import jack.c.midiport;

import std.algorithm;

//debug = jack_callback;

struct PipeMessage {
    MessageType type = MessageType.NUL;

    /** the contract for this pointer is: either it is null,
      or it has to be freed by the message piper
      */
    void* data = null;

    void free() {
        if (data) {
            GC.free(data);
            data = null;
        }
        type = MessageType.NUL;
    }
}

immutable msg_ringbuffer_length = 256;

/** we cannot use synchronized and all the nice stuff, since jack wants a @nogc callback */
class MessagePipe {
    Mutex m;

    int readhead;
    int writehead;

    PipeMessage[msg_ringbuffer_length] buffer;

    int freehead;
    int freed;
    PipeMessage[msg_ringbuffer_length] to_free;

    this() {
        m = new Mutex;
        readhead = 0;
        writehead = 0;
        freehead = 0;
        freed = 0;
    }

    /** realtime-friendly check for empty ringbuffer */
    bool empty() @nogc {
        // Unfortunately, this is not possible with @nogc.
        //
        //if (m.tryLock) {
        //    scope(exit) m.unlock;
        //
        //    return readhead == writehead;
        //}
        synchronized (m) {
            return readhead == writehead;
        }
    };

    /** read the first message in the ringbuffer,
      the result must be requested to be freed by the reader
     */
    PipeMessage read() @nogc {
        PipeMessage msg;
        if (empty)
            return msg;
        synchronized (m) {
            ++readhead;
            if (readhead == msg_ringbuffer_length) {
                readhead = 0;
            }

            msg = buffer[readhead];
            buffer[readhead].data = null;
            buffer[readhead].type = MessageType.NUL;
        }
        return msg;
    }

    /** bounce back the read message to be freed by the GC-enabled threads*/
    void free(ref PipeMessage msg) @nogc {
        synchronized (m) {
            freehead++;
            if (freehead == msg_ringbuffer_length) {
                freehead = 0;
            }

            to_free[freehead] = msg;

            msg.data = null;
            msg.type = MessageType.NUL;
        }
    }

    /** free messages */
    void kill() {
        int count = 0;
        synchronized (m) {
            count = freehead - freed;
        }

        PipeMessage msg;

        if (count < 0)
            count += msg_ringbuffer_length;

        while (count) {
            --count;
            synchronized (m) {
                if (freed != freehead) {
                    freed++;
                    if (freed == msg_ringbuffer_length) {
                        freed = 0;
                    }

                    msg = to_free[freed];

                    to_free[freed].data = null;
                    to_free[freed].type = MessageType.NUL;
                }
            }

            msg.free;
        }
    }

    /** write the message to the ringbuffer, which takes
      responsibility to free the message */
    void write(ref PipeMessage msg) {
        synchronized (m) {
            writehead++;
            if (writehead == msg_ringbuffer_length) {
                writehead = 0;
            }

            buffer[writehead].free;
            buffer[writehead] = msg;

            msg.data = null;
            msg.type = MessageType.NUL;
        }
    }
};

/** this pipe class handles feedback from the jack client back to the interface. remember, jack threat
  should not access anything GC */
class FeedbackPipe(FEEDBACK_STRUCT) {
    Mutex m;

    int readhead;
    int writehead;

    FEEDBACK_STRUCT[msg_ringbuffer_length] buffer;

    this() {
        m = new Mutex;
        readhead = 0;
        writehead = 0;
    }

    bool empty() {
        synchronized (m)
            return readhead == writehead;
    }

    void write(FEEDBACK_STRUCT msg) @nogc {
        synchronized (m) {
            writehead++;

            if (writehead == msg_ringbuffer_length) {
                writehead = 0;
            }

            buffer[writehead] = msg;
        }
    }

    FEEDBACK_STRUCT read() {
        if (empty) {
            FEEDBACK_STRUCT x;
            return x;
        }
        synchronized (m) {
            readhead++;
            if (readhead == msg_ringbuffer_length) {
                readhead = 0;
            }

            return buffer[readhead];
        }
    }

};

immutable jack_max_msg_per_frame = 1;
immutable speed_factor_denominator = 20000;
immutable max_factor = 200000;
immutable min_factor = 5000;

class JackCallbackRoutines {
    JackClient client;

    MessagePipe to_jack;
    FeedbackPipe!FeedbackStatus jack_status;
    FeedbackPipe!(SketchProgram*) jack_free_program;

    JackPort hits;

    void StopPlayback() {
        if (client is null)
            return;

        debug writeln("StopPlayback");
        PipeMessage msg;
        msg.type = MessageType.StopPlayback;

        to_jack.write(msg);
    }

    /** sends a program for next playback, will take care of GC.free() */
    void SendProgram(SketchProgram* prg) {
        if (client is null) {
            prg.free;
            GC.free(prg);
            return;
        }

        debug writeln("SendProgram ", prg);

        PipeMessage msg;
        msg.type = MessageType.SetProgram;
        SketchProgram** pprg = cast(SketchProgram**)GC.calloc(
            (SketchProgram*).sizeof);
        *pprg = prg;
        msg.data = pprg;

        to_jack.write(msg);
    }

    void ResetSpeed() {
        if (client is null)
            return;

        debug writeln("SpeedFactorReset");
        PipeMessage msg;
        msg.type = MessageType.SpeedFactorReset;

        to_jack.write(msg);
    }

    void FasterSpeed() {
        if (client is null)
            return;

        debug writeln("SpeedFactorFaster");
        PipeMessage msg;
        msg.type = MessageType.SpeedFactorFaster;

        to_jack.write(msg);
    }

    void SlowerSpeed() {
        if (client is null)
            return;

        debug writeln("SpeedFactorSlower");
        PipeMessage msg;
        msg.type = MessageType.SpeedFactorSlower;

        to_jack.write(msg);
    }
    void PausePlayback() {
        if (client is null)
            return;

        debug writeln("PausePlayback");
        PipeMessage msg;
        msg.type = MessageType.PausePlayback;

        to_jack.write(msg);
    }
    void ResumePlayback() {
        if (client is null)
            return;

        debug writeln("ResumePlayback");
        PipeMessage msg;
        msg.type = MessageType.ResumePlayback;

        to_jack.write(msg);
    }

    this() {
        /** jack dummy driver */
    }

    /* connect output */
    void connect(string where) {
        try {
            client.connect(hits.get_name, where);
        }
        catch (Throwable all) {
        }
    }

    this(JackClient client_) {
        to_jack = new MessagePipe;
        jack_status = new FeedbackPipe!FeedbackStatus;
        jack_free_program = new FeedbackPipe!(SketchProgram*);

        client = client_;

        /** jack client variables */

        JackMidiPortBuffer hit_out;
        hits = client.register_port("Hits",
            JACK_DEFAULT_MIDI_TYPE, JackPortFlags.JackPortIsOutput,
            0);

        SketchProgram* prg = null;
        /* current array head indexes */
        int action;
        int midis;
        int seqId;
        int patId;
        int patRow;
        int seqRow;
        int subRow;
        int patBpm;
        int seqPer;
        int subPer;
        int subId;
        int waitTime;
        /* state vars */
        bool request_stop = false;
        FeedbackStatus status;
        int speed_factor = speed_factor_denominator; /** instant speed change factor */
        bool pause_playback = false;

        status.speed_factor = 100;

        int left_to_wait = 0;

        /* certainly, someone should add the @nogc to the jack wrapper routines */
        auto hits_handle = hits.handle;

        client.process_callback = delegate int(jack_nframes_t nframes) /* @nogc */{
            try {
                int count = 0;

                hit_out = hits.get_midi_buffer(nframes);
                //hit_out.ptr_ = jack_port_get_buffer(hits_handle, nframes);

                hit_out.clear;

                //jack_midi_clear_buffer(hit_out.ptr_);

                while ((!to_jack.empty) && (count < jack_max_msg_per_frame)) {
                    PipeMessage msg = to_jack.read;

                    /** process message here */

                    if (msg.type == MessageType.StopPlayback) {
                        request_stop = true;
                    } else if (msg.type == MessageType.SetProgram) {
                        if (prg != null) {
                            jack_free_program.write(prg);
                        }
                        prg = *cast(SketchProgram**)msg.data;
                        if (prg)
                            status.stopped_playing = false;
                        else
                            status.stopped_playing = true;
                        /* reset array heads */
                        action = 0;
                        midis = 0;
                        seqId = 0;
                        patId = 0;
                        patRow = 0;
                        seqRow = 0;
                        subRow = 0;
                        patBpm = 0;
                        seqPer = 0;
                        subPer = 0;
                        subId = 0;
                        waitTime = 0;
                        /* reset wait counter */
                        left_to_wait = 0;
                        request_stop = false;
                    } else if (msg.type == MessageType.SpeedFactorReset) {
                        speed_factor = speed_factor_denominator;
                        status.speed_factor =( speed_factor_denominator*100) / speed_factor;
                    }
                     else if (msg.type == MessageType.PausePlayback) {
                        pause_playback = true;
                    }
                     else if (msg.type == MessageType.ResumePlayback) {
                        pause_playback = false;
                    }
                     else if (msg.type == MessageType.SpeedFactorSlower) {
                        speed_factor = min((105*speed_factor)/100,max_factor);
                        status.speed_factor =( speed_factor_denominator*100) / speed_factor;
                    }
                     else if (msg.type == MessageType.SpeedFactorFaster) {
                        speed_factor = max(min_factor,(100*speed_factor)/105);
                        status.speed_factor =( speed_factor_denominator*100) / speed_factor;
                    }

                    to_jack.free(msg);

                    ++count;
                }

                int offset = 0;

                while ((!pause_playback) && prg && left_to_wait + offset < nframes) {
                    offset += left_to_wait;
                    left_to_wait = 0;

                    if (prg.actions[action] == ProgramAction.RepeatLoop) {
                        debug (jack_callback) {
                            writeln("Repeat Loop!");
                        }
                        /* reset array heads */
                        action = 0;
                        midis = 0;
                        seqId = 0;
                        patId = 0;
                        patRow = 0;
                        seqRow = 0;
                        subRow = 0;
                        waitTime = 0;
                        patBpm = 0;
                        seqPer = 0;
                        subPer = 0;
                        subId = 0;
                    }

                    debug (jack_callback) {
                        writeln("Action:", prg.actions[action], "@",
                            action);
                        writeln("Offset:", offset);
                        writeln("Left To Wait:", left_to_wait);
                    }


                    switch (prg.actions[action]) {
                    case ProgramAction.End:
                        jack_free_program.write(prg);
                        prg = null;
                        status.stopped_playing = true;
                        jack_status.write(status);
                        break;

                    case ProgramAction.GracefulStop:
                        if (request_stop) {
                            jack_free_program.write(prg);
                            prg = null;
                            status.stopped_playing = true;
                            jack_status.write(status);
                        }

                        break;

                    case ProgramAction.WaitTime:
                        left_to_wait = (prg.waitTimes[waitTime] * speed_factor) / speed_factor_denominator;
                        waitTime++;
                        break;

                    case ProgramAction.SendMidi:
                        hit_out.write_event(offset,
                            &prg.midis[midis].data[0], prg.midis[midis].length);
                        debug (jack_callback)
                            writeln("SEND MIDI", prg.midis[midis]);
                        midis++;
                        break;

                    case ProgramAction.SetPatternId:
                        status.pattern_id = prg.patIds[patId];
                        ++patId;
                        break;

                    case ProgramAction.SetSequenceId:
                        status.sequence_id = prg.seqIds[seqId];
                        ++seqId;
                        break;

                    case ProgramAction.SetPatRow:
                        status.beat_in_pattern = prg.patRows[patRow];
                        ++patRow;
                        break;

                    case ProgramAction.SetSeqRow:
                        status.pattern_in_sequence = prg.seqRows[seqRow];
                        ++seqRow;
                        break;
                    case ProgramAction.SetSubSeqRow:
                        status.pattern_in_subsequence = prg.subSeqRows[subRow];
                        ++subRow;
                        break;


                    case ProgramAction.SetPatternBpm:
                            status.bpm = prg.patBpms[patBpm];
                            ++patBpm;
                        break;
                    case ProgramAction.SetSequencePercent:
                        status.percentage = prg.seqPercents[seqPer];
                        ++seqPer;
                        break;
                    case ProgramAction.SetSubSeqId:
                        status.subsequence_id = prg.subSeqIds[subId];
                        ++subId;
                        break;
                    case ProgramAction.SetSubSeqPercent:
                        status.subsequence_percentage = prg.subSeqPercents[subPer];
                        ++subPer;
                        break;

                    case ProgramAction.PostFeedback:
                        jack_status.write(status);
                        break;

                    default:
                        assert(0);
                    }
                    action++;

                }

                left_to_wait -= nframes - offset;
                if (left_to_wait < 0)
                    left_to_wait = 0;
                else
                    debug (jack_callback)
                        writeln("Waiting:", left_to_wait);

                return 0;
            }
            catch (Throwable all) {
                debug (jack_callback)
                    writeln("process_callback: ", all);

                return 0;
            }
        };

        writeln("\n -+ start jack.");

        client.activate();

        current_sample_rate = client.get_sample_rate;

        writeln("  + sample rate = ", current_sample_rate);
    }
};

int sketch_main(string[] args) {

    auto connect_output_default = "drumkit:In";
    string[] connect_output;

    bool no_jack = false;

    /* if this gives an error, use `dub add-local ../jack-1.0.1` */
    writeln("jack-1.0.1: ", using_modified_version_of_jack);

    string config_data = "";
    bool no_default = false;
    /** read all parameters */
    for (int i = 1; i < args.length; ++i) {

        if (args[i] == "--sketch")
            continue;

        auto m = match(args[i], regex(`^--name=(.*)`));
        if (!m.empty) {
            name = m.captures[1].dup;
            writeln("   +-- client name =\"", name, "\"");
        } else {
            m = match(args[i], regex(`^--no-jack`));

            if (!m.empty) {
                /* ignore jack stuff, interface only; nice for dev. */
                no_jack = true;
            } else {
                m = match(args[i], regex(`^--out=(.*)`));

                if (!m.empty) {
                    connect_output ~= m.captures[1].dup;
                    writeln("   +-- connect output to \"",
                        connect_output[$ - 1], "\"");
                } else {

                    m = match(args[i], regex(`^--retina=(.*)`));
                    if (!m.empty) {
                        retina_factor = to!float(m.captures[1]);
                        writeln("  +-- retina pixel factor = ", retina_factor);
                    } else {
                    m = match(args[i], regex(`^--git=(.*)`));
                    if (!m.empty) {
                        git_cmd = to!string(m.captures[1].dup);
                        writeln("  +-- git command = ", git_cmd);
                    } else {

                        writeln("   +-- channel config =\"", args[i],
                            "\"");

                        auto f = args[i].File;
                        foreach (l; f.byLine) {
                            config_data ~= l ~ "\n";
                        }

                        no_default = true;
                    }}
                }
            }
        }
    }

    writeln(name, "\n -+ startup.");

    if (no_jack == false) {
        // Jack Interface
        JackClient client = wait_for_jack();
        scope (exit)
            client.close();

        JackCallbackRoutines jack = new JackCallbackRoutines(client);

        if (connect_output.length == 0)
            jack.connect(connect_output_default);
        else {
            foreach (x; connect_output) {
                jack.connect(x); /* this behavior is nice if you have several instances of drum machines running */
            }
        }

        writeln("\n -+ user interface.");

        UserInterface ui = new UserInterface(jack);

        ui.run(delegate() {
            int count = 0;

            /** free the program pointers sent back from the jack client */
            while (!jack.jack_free_program.empty && (count < 4)) {
                SketchProgram* ptr = jack.jack_free_program.read;

                ptr.free;

                GC.free(ptr);

                ++count;
            }

            /** free the message struct after they have been processed */
            jack.to_jack.kill;

            count = 0;
            bool update_status = false;
            FeedbackStatus updated;

            while (!jack.jack_status.empty && (count < 10)) {
                updated = jack.jack_status.read;
                update_status = true;
            }

            if (update_status) {
                ui.update_status(updated);
            }

            return;
        });

    } else {
        writeln("\n -+ user interface.");

        UserInterface ui = new UserInterface(new JackCallbackRoutines);

        ui.run(delegate() { return; });
    }

    return 0;
}

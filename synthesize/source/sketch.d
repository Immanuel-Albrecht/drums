module sketch;

import core.memory;
import std.math;
import std.algorithm;

enum ProgramAction {
    NUL = 0,
    WaitTime,
    End,
    SetPatternId,
    SetSequenceId,
    SetPatRow,
    SetSeqRow,
    SetSubSeqRow,
    SetPatternBpm,
    SetSequencePercent,
    SetSubSeqId,
    SetSubSeqPercent,
    PostFeedback,
    SendMidi,
    GracefulStop,
    RepeatLoop
};

immutable max_midi_length = 3; /* unified midi data package length */
immutable note_off_before_next_hit = 1; /* note off one sample before next midi hit */

struct MidiOutput {
    ubyte[max_midi_length] data;
    int length;
};

struct SketchProgram {

    ProgramAction* actions;
    MidiOutput* midis;

    int* seqIds;
    int* patIds;
    int* patRows;
    int* seqRows;
    int* subSeqRows;
    int* subSeqIds;
    int* patBpms;
    int* seqPercents;
    int* subSeqPercents;

    int* waitTimes;

    void free() {
        if (actions) {
            GC.free(actions);
            actions = null;
        }
        if (midis) {
            GC.free(midis);
            midis = null;
        }
        if (seqIds) {
            GC.free(seqIds);
            seqIds = null;
        }
        if (patIds) {
            GC.free(patIds);
            patIds = null;
        }
        if (patRows) {
            GC.free(patRows);
            patRows = null;
        }
        if (seqRows) {
            GC.free(seqRows);
            seqRows = null;
        }
        if (patBpms) {
            GC.free(patBpms);
            patBpms = null;
        }
        if (seqPercents) {
            GC.free(seqPercents);
            seqPercents = null;
        }
        if (subSeqPercents) {
            GC.free(subSeqPercents);
            subSeqPercents = null;
        }
        if (subSeqIds) {
            GC.free(subSeqIds);
            subSeqIds = null;
        }
        if (subSeqRows) {
            GC.free(subSeqRows);
            subSeqRows = null;
        }
        if (waitTimes) {
            GC.free(waitTimes);
            waitTimes = null;
        }
    }

};

enum MessageType {
    NUL = 0,
    StopPlayback,
    SetProgram,
    SpeedFactorReset,
    SpeedFactorFaster,
    SpeedFactorSlower,
    PausePlayback,
    ResumePlayback
};

shared int current_sample_rate = 44100;

int getDurationFrames(int bpm, int num, int den) {
    return (current_sample_rate * 60 * num) / (bpm * den);
}

struct FeedbackStatus {
    bool stopped_playing; //<! true, if there is nothing more to play back for the jack threat
    int beat_in_pattern; //<! which beat position we are at in the current pattern
    int pattern_id; //<! which is the current pattern played back?

    int bpm; //<! which is the current patterns resulting bpm

    int pattern_in_sequence; //<! which pattern of the sequence we are at in the current sequence
    int sequence_id; //<! which is the current sequence id
    int percentage; //<! which is the current sequence id's percentage setting

    int subsequence_id; //<! which is the current innermost subsequence?
    int subsequence_percentage; //<! which is the current innermost sub-sequences resulting percentage setting
    int pattern_in_subsequence; //<! which pattern of the subsequence we are at...

    int speed_factor; //<! current playback speed factor in percent
    bool paused; //<! true, if current playback is paused
};

/** this class provides an interface to the backend */
struct ConstructProgramAction {
    struct Hit {
        int channel;
        int velocity;
    };

    struct TimeSlice {
        Hit[] hits;
        int pattern; /* current pattern played back */
        int bpm; /* current pattern bpm */
        int row; /* current row in pattern which is played back */
        int sequence; /* -1 if not applicable */
        int percentage; /* current sequence percentage setting */
        int subsequence; /* -1 if not applicable */
        int subsequence_percentage; /* current subsequence percentage setting */
        int column; /* current column in sequence which is played back */
        int subseq_row; /* dito for subsequence */
        int duration; /* duration of this slice in frames */
    };

    TimeSlice[] sequence; /* playback sequence */

    SketchProgram* allocProgram() {
        return allocProgram(false);
    }
    /** calculates and allocates the SketchProgram sequence and fills it appropriately */
    SketchProgram* allocProgram(bool loop) {
        SketchProgram* prg = cast(SketchProgram*)GC.calloc(SketchProgram.sizeof);

        int actions = 1; /* end */
        int midis = 0;

        foreach (slice; sequence) {
            midis += slice.hits.length * 2; /* hit and hit-off */
            actions += 2 * slice.hits.length /* midi commands */
             + 4 /* set pattern, seq, row, col */
             + 5 /* set subsequence, subseq row, bpm, percentage, subsequence_percentage */
             + 2 /* duration between on and off, and between off and next */
             + 1 /* post feedback */
             + 2 /* graceful stops */
            ;
        }
        prg.actions = cast(ProgramAction*)GC.calloc(ProgramAction.sizeof * actions);
        prg.midis = cast(MidiOutput*)GC.calloc(MidiOutput.sizeof * midis);
        prg.seqIds = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.patIds = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.patRows = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.seqRows = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.subSeqRows = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.waitTimes = cast(int*)GC.calloc(int.sizeof * sequence.length * 2);
        prg.patBpms = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.subSeqIds = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.seqPercents = cast(int*)GC.calloc(int.sizeof * sequence.length);
        prg.subSeqPercents = cast(int*)GC.calloc(int.sizeof * sequence.length);

        int idx_a = 0;
        int idx_m = 0;
        int idx_s = 0;

        foreach (slice; sequence) {
            prg.actions[idx_a] = ProgramAction.GracefulStop;
            ++idx_a;

            /* set the feedback */
            prg.actions[idx_a] = ProgramAction.SetPatternId;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetPatRow;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetPatternBpm;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSequenceId;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSeqRow;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSequencePercent;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSubSeqId;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSubSeqRow;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.SetSubSeqPercent;
            ++idx_a;

            prg.seqIds[idx_s] = slice.sequence;
            prg.patIds[idx_s] = slice.pattern;
            prg.seqRows[idx_s] = slice.column;
            prg.subSeqRows[idx_s] = slice.subseq_row;
            prg.patRows[idx_s] = slice.row;
            prg.subSeqIds[idx_s] = slice.subsequence;
            prg.patBpms[idx_s] = slice.bpm;
            prg.subSeqPercents[idx_s] = slice.subsequence_percentage;
            prg.seqPercents[idx_s] = slice.percentage;

            /* post feedback to user interface */
            prg.actions[idx_a] = ProgramAction.PostFeedback;
            ++idx_a;

            /* add midi hits */

            foreach (hit; slice.hits) {
                prg.midis[idx_m].length = 3;
                prg.midis[idx_m].data[0] = 0x90; /* MIDI Note-on */
                prg.midis[idx_m].data[1] = cast(ubyte)min(max(0, hit.channel),
                    127);
                prg.midis[idx_m].data[2] = cast(ubyte)min(max(0,
                    hit.velocity), 127);
                ++idx_m;

                prg.actions[idx_a] = ProgramAction.SendMidi;
                ++idx_a;
            }

            int between_length = max(0, slice.duration - note_off_before_next_hit);
            int after_length = min(note_off_before_next_hit, slice.duration);

            /* wait for note-off */

            prg.actions[idx_a] = ProgramAction.WaitTime;
            ++idx_a;

            prg.waitTimes[idx_s * 2] = between_length;

            foreach (hit; slice.hits) {
                prg.midis[idx_m].length = 3;
                prg.midis[idx_m].data[0] = 0x80; /* MIDI Note-off */
                prg.midis[idx_m].data[1] = cast(ubyte)min(max(0, hit.channel),
                    127);
                prg.midis[idx_m].data[2] = cast(ubyte)min(max(0,
                    hit.velocity), 127);
                ++idx_m;

                prg.actions[idx_a] = ProgramAction.SendMidi;
                ++idx_a;
            }

            prg.actions[idx_a] = ProgramAction.GracefulStop;
            ++idx_a;

            prg.actions[idx_a] = ProgramAction.WaitTime;
            ++idx_a;

            prg.waitTimes[idx_s * 2 + 1] = after_length;

            ++idx_s;
        }

        prg.actions[idx_a] = loop ? ProgramAction.RepeatLoop : ProgramAction.End;
        ++idx_a;

        assert(idx_a == actions);
        assert(idx_s == sequence.length);
        assert(idx_m == midis);

        import std.stdio;

        writeln("Actions ", actions, " Midis ", idx_m, " Cols ", idx_s);

        return prg;
    };
};

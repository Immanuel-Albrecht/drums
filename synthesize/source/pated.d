module pated;

import std.stdio;

import jack.client;
import jack.midiport;
import std.regex;

import std.conv;
import std.stdio;
import std.math;
import core.thread;
import core.stdc.string;
import core.memory;
import std.file;
import std.array;
import std.algorithm;
import std.string;

import dlangui;
import dlangui.dialogs.dialog;
import dlangui.dialogs.inputbox;
import filedlg; /** fixed version of FileDialog */

import std.utf;

import core.sync.mutex;

//import config;
import drumkit;
import sync;
import pattern;
import common;

import sketch;
import songsketch;
import sketchui;

class RestoreSketchPattern : UndoRoot {
    int cols;
    string[] rows;
    int[][] hit_strengths;
    bool[][] hits;
    int denominator;
};

/** stores the data that belong to a certain pattern */
class SketchPattern {

private:
    void function(SketchPattern, UndoRoot)[] undoActions;
    UndoRoot[] undoData;
    void function(SketchPattern, UndoRoot)[] redoActions;
    UndoRoot[] redoData;

public:

    void undo() {
        if (undoActions.length == 0)
            return;
        undoActions[$ - 1](this, undoData[$ - 1]);
        undoActions.length--;
        undoData.length--;
    }

    UndoRoot peekUndoTop() {
        if (undoData.length == 0)
            return null;
        return undoData[$ - 1];
    }

    void addUndo(void function(SketchPattern, UndoRoot) action, UndoRoot data) {
        undoData ~= data;
        undoActions ~= action;
    }

    bool hasUndo() {
        return undoActions.length > 0;
    }

    bool hasRedo() {
        return redoActions.length > 0;

    }

    void killRedo() {
        redoActions.length = 0;
        redoData.length = 0;
    }

    void redo() {
        if (redoActions.length == 0)
            return;
        redoActions[$ - 1](this, redoData[$ - 1]);
        redoActions.length--;
        redoData.length--;
    }

    void addRedo(void function(SketchPattern, UndoRoot) action, UndoRoot data) {
        redoData ~= data;
        redoActions ~= action;
    }

    /**** DATA *****/

    int cols = pat_default_cols;
    string[] rows = pat_default_rows;

    int denominator = pat_default_denominator;

    int[][] hit_strengths;
    bool[][] hits;

    string name = pat_default_name;

    /**** END DATA *****/

    /* get canonical undo object */
    RestoreSketchPattern getNewRestore() {
        auto rsp = new RestoreSketchPattern;

        rsp.cols = cols;
        rsp.denominator = denominator;
        rsp.rows = rows.dup;
        foreach (hs; hit_strengths) {
            rsp.hit_strengths ~= hs.dup;
        }
        foreach (h; hits) {
            rsp.hits ~= h.dup;
        }

        return rsp;
    }

    /* do canonical undo/redo action */
    void swapRestore(ref RestoreSketchPattern rsp) {
        auto xcols = cols;
        cols = rsp.cols;
        rsp.cols = xcols;
        auto xdenominator = denominator;
        denominator = rsp.denominator;
        rsp.denominator = xdenominator;
        auto xrows = rows;
        rows = rsp.rows;
        rsp.rows = xrows;
        auto xhits = hits;
        hits = rsp.hits;
        rsp.hits = xhits;
        auto xhit_strengths = hit_strengths;
        hit_strengths = rsp.hit_strengths;
        rsp.hit_strengths = xhit_strengths;
    }

    void constructProgram(ref ConstructProgramAction prg,
        int bpm, int seq, int seqrow, int pat, 
        int percentage, int subseq, int subseqrow, int subpercentage) const {

        debug (cons_prog)
            writeln("constructProgram(", prg, ",", bpm, ",",
                seq, ",", seqrow, ",", pat, ") @", &this);

        int slice_length = getDurationFrames(bpm, 1, denominator);
        int[] channel_assignments;

        foreach (r; rows) {
            channel_assignments ~= get_drum_name_or_shorthand_index(r);
        }

        for (auto idx = 0; idx < cols; ++idx) {
            ConstructProgramAction.TimeSlice slice;

            slice.duration = slice_length;
            slice.pattern = pat;
            slice.column = seqrow;
            slice.subseq_row = subseqrow;
            slice.row = idx;
            slice.bpm = bpm;
            slice.subsequence = subseq;
            slice.percentage = percentage;
            slice.subsequence_percentage = subpercentage;
            slice.sequence = seq;

            for (auto r = 0; r < hits.length; ++r) {
                if (hits[r][idx]) {
                    if (channel_assignments[r] >= 0) {
                        ConstructProgramAction.Hit h;
                        h.channel = drumkit.drumkit[channel_assignments[r]].channel;
                        h.velocity = hit_strengths[r][idx];
                        slice.hits ~= h;
                    }
                }
            }

            prg.sequence ~= slice;
        }
        debug (cons_prog)
            writeln("constructProgram = ", prg);
    }

    SketchPattern dup() const {
        SketchPattern c = new SketchPattern;
        c.cols = cols;
        c.rows = rows.dup;
        c.denominator = denominator;
        c.name = name;
        c.hit_strengths = [];
        c.hits = [];
        foreach (h; hit_strengths) {
            c.hit_strengths ~= h.dup;
        }
        foreach (h; hits) {
            c.hits ~= h.dup;
        }
        return c;
    }

    this(string _name, string[] _data) {
        this();

        hit_strengths.length = 0;
        hits.length = 0;
        rows.length = 0;

        name = _name;
        cols = 0;

        foreach (l; _data) {
            auto m_denominator = match(l,
                regex(`^\s*rows\s*per\s*beat\s*=\s*([0-9]*).*`));
            if (!m_denominator.empty) {
                denominator = to!int(m_denominator.captures[1]);
            } else {
                l = l.strip;
                if (!l.empty) {
                    auto parts = l.split;

                    if (parts.length - 1 > cols) {
                        foreach (h; hits) {
                            for (auto i = cols; i < parts.length - 1;
                                    ++i) {
                                h ~= false;
                            }
                        }
                        foreach (hs; hit_strengths) {
                            for (auto i = cols; i < parts.length - 1;
                                    ++i) {
                                hs ~= default_hit_strength;
                            }
                        }

                        cols = cast(int)parts.length - 1;
                    }

                    rows ~= parts[0];

                    bool[] h;
                    h.length = cols;
                    foreach (ref x; h) {
                        x = false;
                    }

                    int[] hs;
                    hs.length = cols;
                    foreach (ref x; hs) {
                        x = default_hit_strength;
                    }

                    for (auto idx = 1; idx < parts.length; ++idx) {
                        auto s = parts[idx].replace(".", "");
                        if (!s.empty) {
                            h[idx - 1] = true;

                            if (s[0] == 'x' || s[0] == 'X') {
                                hs[idx - 1] = default_hit_strength;
                            } else {
                                int strength = 0;
                                foreach (q; s) {
                                    strength = 10 * strength;
                                    switch (q) {
                                    case '1':
                                        strength += 1;
                                        break;
                                    case '2':
                                        strength += 2;
                                        break;
                                    case '3':
                                        strength += 3;
                                        break;
                                    case '4':
                                        strength += 4;
                                        break;
                                    case '5':
                                        strength += 5;
                                        break;
                                    case '6':
                                        strength += 6;
                                        break;
                                    case '7':
                                        strength += 7;
                                        break;
                                    case '8':
                                        strength += 8;
                                        break;
                                    case '9':
                                        strength += 9;
                                        break;
                                    case 'A':
                                    case 'a':
                                        strength += 10;
                                        break;
                                    case 'B':
                                    case 'b':
                                        strength += 11;
                                        break;
                                    case 'C':
                                    case 'c':
                                        strength += 12;
                                        break;
                                    default:
                                        break;
                                    }
                                }
                                hs[idx - 1] = min(127, strength);
                            }
                        }
                    }

                    hits ~= h;
                    hit_strengths ~= hs;

                }
            }
        }
    }

    void write(ref File f) {
        f.writeln("[" ~ name ~ "]");
        f.writeln("rows per beat = " ~ to!string(denominator));
        foreach (idx, rn; rows) {
            auto represent_row = rn;
            while (represent_row.length < 16)
                represent_row ~= " ";

            represent_row ~= to!string(textifyRow(cast(int)idx));

            f.writeln(represent_row);
        }
    }

    this() {
        foreach (idx, r; rows) {

            int[] strengths;
            bool[] hits;

            for (auto i = 0; i < cols; ++i) {
                strengths ~= default_hit_strength;
                hits ~= false;
            }

            hit_strengths ~= strengths;
            this.hits ~= hits;
        }
    }

    this(int _cols, int _denom) {
        denominator = _denom;
        cols = _cols;

        foreach (idx, r; rows) {

            int[] strengths;
            bool[] hits;

            for (auto i = 0; i < cols; ++i) {
                strengths ~= default_hit_strength;
                hits ~= false;
            }

            hit_strengths ~= strengths;
            this.hits ~= hits;
        }
    }

    dstring textifyRow(int row) {
        string txt = "";

        for (auto i = 0; i < cols; ++i) {
            if (!hits[row][i]) {
                txt ~= " ..";
            } else {
                int s = hit_strengths[row][i];
                txt ~= " " ~ hit_strength_to_text(s);
            }
        }

        return to!dstring(txt);
    }

    /*** Loop Playback feature **/

    void doLoop(UserInterface ui, int pat_idx, int preview_bpm) {
        debug (loop_playback)
            writeln("doLoop(", ui, ",", pat_idx, ",", preview_bpm,
                ")");
        ConstructProgramAction cons;

        constructProgram(cons, preview_bpm, -1, -1, pat_idx, 100, -1, 0, 100);

        ui.jack.SendProgram(cons.allocProgram);
    }
}

void undoRSP(SketchPattern pat, UndoRoot data) {
    auto rsp = cast(RestoreSketchPattern)data;
    pat.swapRestore(rsp);

    pat.addRedo(&redoRSP, rsp);
}

void redoRSP(SketchPattern pat, UndoRoot data) {
    auto rsp = cast(RestoreSketchPattern)data;
    pat.swapRestore(rsp);

    pat.addUndo(&undoRSP, rsp);
}

void redoAddRow(SketchPattern pat, UndoRoot data) {
    pat.rows ~= default_row_drum;

    int[] strengths;
    bool[] hits;

    for (auto i = 0; i < pat.cols; ++i) {
        strengths ~= default_hit_strength;
        hits ~= false;
    }

    pat.hit_strengths ~= strengths;
    pat.hits ~= hits;
    pat.addUndo(&undoAddRow, null);
}

void undoAddRow(SketchPattern pat, UndoRoot data) {
    pat.rows.length--;
    pat.hits.length--;
    pat.hit_strengths.length--;

    pat.addRedo(&redoAddRow, null);
}

class UndoSetDrum : UndoRoot {
    int row;
    string name;

    this(int r, string n) {
        row = r;
        name = n;
    }
};

class UndoSwitchDip : UndoRoot {
    int row;
    int col;

    this(int r, int c) {
        row = r;
        col = c;
    }
}

void redoSwitchDip(SketchPattern pat, UndoRoot r) {
    UndoSwitchDip data = cast(UndoSwitchDip)r;
    pat.hits[data.row][data.col] = !pat.hits[data.row][data.col];

    pat.addUndo(&undoSwitchDip, data);
}

void undoSwitchDip(SketchPattern pat, UndoRoot r) {
    UndoSwitchDip data = cast(UndoSwitchDip)r;
    pat.hits[data.row][data.col] = !pat.hits[data.row][data.col];

    pat.addRedo(&redoSwitchDip, data);
}

class UndoSetStrength : UndoRoot {
    int row;
    int col;
    int str;

    this(int r, int c, int s) {
        row = r;
        col = c;
        str = s;
    }
}

void redoSetStrength(SketchPattern pat, UndoRoot r) {
    UndoSetStrength data = cast(UndoSetStrength)r;
    int old = pat.hit_strengths[data.row][data.col];
    pat.hit_strengths[data.row][data.col] = data.str;

    data.str = old;

    UndoRoot top = pat.peekUndoTop();
    if ((cast(UndoSetStrength)top) !is null) {
        UndoSetStrength dtop = cast(UndoSetStrength)top;
        if (dtop.row != data.row || dtop.col != data.col)
            pat.addUndo(&undoSetStrength, data);
    } else
        pat.addUndo(&undoSetStrength, data);
}

void undoSetStrength(SketchPattern pat, UndoRoot r) {
    UndoSetStrength data = cast(UndoSetStrength)r;
    int old = pat.hit_strengths[data.row][data.col];
    pat.hit_strengths[data.row][data.col] = data.str;

    data.str = old;

    pat.addRedo(&redoSetStrength, data);
}

void undoSetDrum(SketchPattern pat, UndoRoot r) {
    UndoSetDrum data = cast(UndoSetDrum)r;
    string old_name = pat.rows[data.row];
    pat.rows[data.row] = data.name;
    data.name = old_name;

    pat.addRedo(&redoSetDrum, data);
}

void redoSetDrum(SketchPattern pat, UndoRoot r) {
    UndoSetDrum data = cast(UndoSetDrum)r;
    string old_name = pat.rows[data.row];
    pat.rows[data.row] = data.name;
    data.name = old_name;

    pat.addUndo(&undoSetDrum, data);
}

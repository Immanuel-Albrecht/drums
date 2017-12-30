module seqed;

import std.stdio;

import jack.client;
import jack.midiport;
import std.regex;
import std.uri;

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

import dlangui.graphics.images: loadImage;

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

/** stores the data that belong to a sequence of patterns */
class SketchSequence {
private:
    void function(SketchSequence, UndoRoot)[] undoActions;
    UndoRoot[] undoData;
    void function(SketchSequence, UndoRoot)[] redoActions;
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

    void addUndo(void function(SketchSequence, UndoRoot) action, UndoRoot data) {
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

    void addRedo(void function(SketchSequence, UndoRoot) action, UndoRoot data) {
        redoData ~= data;
        redoActions ~= action;
    }

    /*** DATA ***/

    string name = seq_default_name;

    struct Slot {
        bool references_pattern = true; /** true -> repeat pattern; false -> repeat sequence */
        bool filled = false; /** true -> do not skip this slot, false -> set to skip*/
        int id = 0; /** negative id indicates deleted pattern / ignore slot */
        int repeat_count = 1; /** repeat how often? negative = skip slot */
        int bpm = 120; /** pattern speed / % speedup for sequences */
        string rehearsal_image = ""; /** path to some image which is displayed in the rehearsal window */
        string info_link = ""; /** some link that can be opened by the OS when clicked on... */
    };

    Slot[seq_max_rows] list;


    /*** END DATA ***/

    /** UI-CACHE */
    ColorDrawBuf[seq_max_rows] rehearsal_images; /** rehearsal images are preloaded and stored here until needed.
                                                   null objects indicate that there is no image to display */
    /** END UI-CACHE */

    void constructProgram(ref ConstructProgramAction prg,
        int percentage, int seq, int row, const Workspace wks, int recursion_depth,
        int subseq, int superpercentage) const {
        foreach (idx, slot; list) {
            if (slot.filled) {
                if (slot.id < 0)
                    continue;

                if (slot.references_pattern) {
                    if (slot.id >= wks.patterns.length)
                        continue;
                    int bpm = (slot.bpm * percentage + 51) / 100;
                    for (auto c = 0; c < slot.repeat_count; ++c)
                        wks.patterns[slot.id].constructProgram(prg,
                            bpm, seq, (row < 0) ? (cast(int)idx) : row,
                            slot.id, superpercentage, subseq, cast(int)idx, percentage);
                } else {
                    if (slot.id >= wks.sequences.length)
                        continue;
                    if (recursion_depth < 1)
                        continue;
                    int perc = (slot.bpm * percentage + 50) / 100;
                    for (auto c = 0; c < slot.repeat_count; ++c)
                        wks.sequences[slot.id].constructProgram(prg,
                            perc, seq, cast(int)idx, wks, recursion_depth - 1,
                            slot.id, percentage);

                }
            }
        }
    }

    SketchSequence dup() const {
        SketchSequence s = new SketchSequence;
        s.name = name;
        s.list = list.dup;

        return s;
    }

    this() {
    }

    this(string _name, string[] _data, int[string] id, bool[string] is_pat) {
        name = _name;
        int row = 0;
        foreach (l; _data) {
            auto m_line = match(l, regex(`^\s*"(.*)"\s*([0-9]+)\s+([0-9]+)\s*([a-zA-Z0-9;/?:@&=+$,-.!~*'()]*)\s*(\s@([a-zA-Z0-9;/?:@&=+$,-.!~*'()]*)|)\s*$`));
            if (!m_line.empty) {
                if (m_line.captures.length >= 4) {
                    string n = to!string(m_line.captures[1].dup).replace("\"\"",
                        "\"");
                    if (n in id) {
                        list[row].id = id[n];
                        list[row].references_pattern = is_pat[n];
                        list[row].filled = true;
                        list[row].bpm = to!int(m_line.captures[2]);
                        list[row].repeat_count = to!int(m_line.captures[3]);
                        list[row].rehearsal_image = std.uri.decode(m_line.captures[4]);
                        list[row].info_link = std.uri.decode(m_line.captures[6]);
                        ++row;
                    }
                }
            }
        }

        loadImageCache();
    }

    void loadImageCache() {
        foreach (idx, slot; list) {
            if (slot.filled == false)
            {
                rehearsal_images[idx] = null;
                continue;
            }
            try {
                rehearsal_images[idx] = loadImage(slot.rehearsal_image);
            } 
            catch (Throwable o) {
                /** there was some error loading the image... */
                rehearsal_images[idx] = null;
            }
        }
    }

    void write(ref File f, const Workspace w) {
        f.writeln("{" ~ name ~ "}");

        foreach (s; list) {
            if (s.filled == false)
                continue;

            string n;
            if (s.references_pattern) {
                if (w.patterns.length > s.id)
                    n = w.patterns[s.id].name;
                else
                    continue;
            } else if (w.sequences.length > s.id)
                n = w.sequences[s.id].name;
            else
                continue;

            n = "\"" ~ n.replace("\"", "\"\"") ~ "\"";

            while (n.length < 30)
                n ~= " ";

            n ~= " " ~ to!string(s.bpm) ~ " ";
            while (n.length < 36)
                n ~= " ";

            n ~= " " ~ to!string(s.repeat_count);

            if (s.rehearsal_image != "") {
                while (n.length < 40)
                  n ~= " ";
                n ~= " "~ std.uri.encode(s.rehearsal_image);
            }

            if (s.info_link != "") {
                while (n.length < 40)
                  n ~= " ";
                n ~= " @"~ std.uri.encode(s.info_link) ;
            }

            f.writeln(n);
        }
    }

    UndoSlotChanges getNewRestore() {
        auto d = new UndoSlotChanges;
        d.type = "canonical";
        foreach (idx, l; list) {
            d.restore ~= l;
            d.indices ~= cast(int)idx;
        }

        return d;
    }

    /** Loop playback handler **/
    void doLoop(UserInterface ui, int seq_idx, int preview_percentage) {
        ConstructProgramAction cons;

        constructProgram(cons, preview_percentage, seq_idx, -1, ui.workspace,
            4, -1, preview_percentage);

        ui.jack.SendProgram(cons.allocProgram);
    }

}

class UndoSlotChanges : UndoRoot {
    SketchSequence.Slot[] restore;
    int[] indices;
    string type;
};

void undoSlotChanges(SketchSequence seq, UndoRoot data) {
    UndoSlotChanges d = cast(UndoSlotChanges)data;
    foreach (idx, ref s; d.restore) {
        SketchSequence.Slot x = seq.list[d.indices[idx]];
        seq.list[d.indices[idx]] = s;
        try {
            seq.rehearsal_images[idx] = loadImage(s.rehearsal_image);
        } catch(Throwable o) {
            seq.rehearsal_images[idx] = null;
        }
        s = x;
    }
    seq.addRedo(&redoSlotChanges, d);
}

void redoSlotChanges(SketchSequence seq, UndoRoot data) {
    UndoSlotChanges d = cast(UndoSlotChanges)data;
    foreach (idx, ref s; d.restore) {
        SketchSequence.Slot x = seq.list[d.indices[idx]];
        seq.list[d.indices[idx]] = s;
        try {
            seq.rehearsal_images[idx] = loadImage(s.rehearsal_image);
        } catch(Throwable o) {
            seq.rehearsal_images[idx] = null;
        }
        s = x;
    }
    seq.addUndo(&undoSlotChanges, d);
}

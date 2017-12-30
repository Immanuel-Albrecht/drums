module sequi;

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

import imgdlg;
import lnkdlg;

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

int seq_recursion_depth = 4;

struct SequenceEditorVars {
    UserInterface ui;
    Workspace workspace;

    Window window;

    VerticalLayout master;

    VerticalLayout rowlayout;

    HorizontalLayout tools;

    HorizontalLayout headrow;

    SketchSequence seq;

    ComboBox sequence_selector;

    HorizontalLayout[] rows;

    TextWidget[] pat_or_seq;
    ComboBox[] sel;

    TextWidget[] bpms;
    TextWidget[] repeats;
    TextWidget[] images;
    TextWidget[] links;

    TextWidget[] playhead;

    int preview_percentage = 100;

    bool ignore_input = false;
    bool nofix_scroll = false;

    Button undo_btn;
    Button redo_btn;

    void clearPlayhead() {
        foreach (p; playhead) {
            p.text = " "d;
        }
    }

    void setPlayhead(int col) {
        foreach (idx, p; playhead) {
            if (idx < col) {
                p.text = ".."d;
            } else if (idx == col) {
                p.text = ">>"d;
            } else
                p.text = " "d;
        }
    }

    void init(VerticalLayout l, Window w, Workspace wsp, UserInterface _ui) {
        ui = _ui;
        window = w;
        master = l;
        workspace = wsp;

        tools = new HorizontalLayout;
        headrow = new HorizontalLayout;
        rowlayout = new VerticalLayout;

        undo_btn = new Button(null, "Undo"d);

        undo_btn.click = delegate(Widget src) {
            undo();
            return true;
        };

        tools.addChild(undo_btn);

        redo_btn = new Button(null, "Redo"d);

        redo_btn.click = delegate(Widget src) {
            redo();
            return true;
        };

        tools.addChild(redo_btn);
        auto stop_btn = new Button(null, "Stop"d);
        stop_btn.click = delegate(Widget w) {

            ui.Unloop;

            ui.jack.StopPlayback;
            return true;
        };
        tools.addChild(stop_btn);

        auto play_btn = new Button(null, "Play"d);
        play_btn.click = delegate(Widget w) {
            ui.jack.StopPlayback;

            ConstructProgramAction cons;

            int seq_idx = -1;
            foreach (idx, s;
            workspace.sequences) {
                if (s is seq) {
                    seq_idx = cast(int)idx;
                    break;
                }
            }

            seq.constructProgram(cons, preview_percentage,
                seq_idx, -1, workspace, seq_recursion_depth, -1, preview_percentage);

            ui.Unloop;

            ui.jack.SendProgram(cons.allocProgram);

            return true;
        };

        tools.addChild(play_btn);
        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Play Sequence..."d, null, KeyCode.F6, 0));
        actionHandlers ~= delegate() {
            play_btn.click(play_btn);
            return;
        };

        auto loop_btn = new Button(null, "Loop (editable)"d);
        loop_btn.click = delegate(Widget w) {
            ui.jack.StopPlayback;

            ConstructProgramAction cons;

            int seq_idx = -1;
            foreach (idx, s;
            workspace.sequences) {
                if (s is seq) {
                    seq_idx = cast(int)idx;
                    break;
                }
            }

            seq.constructProgram(cons, preview_percentage,
                seq_idx, -1, workspace, seq_recursion_depth,
                -1, preview_percentage);

            ui.LoopSequence(seq_idx, preview_percentage);

            ui.jack.SendProgram(cons.allocProgram);

            return true;
        };

        tools.addChild(loop_btn);


        auto loopB_btn = new Button(null, "Loop (rehearsable)"d);
        loopB_btn.click = delegate(Widget w) {
            ui.jack.StopPlayback;

            ConstructProgramAction cons;

            int seq_idx = -1;
            foreach (idx, s;
            workspace.sequences) {
                if (s is seq) {
                    seq_idx = cast(int)idx;
                    break;
                }
            }

            ui.playRehearseSequence(seq_idx,preview_percentage);

            /*seq.constructProgram(cons, preview_percentage,
                seq_idx, -1, workspace, seq_recursion_depth, -1, preview_percentage);

            ui.jack.SendProgram(cons.allocProgram(true));*/

            return true;
        };

        tools.addChild(loopB_btn);

        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Loop Sequence (editable)..."d, null, KeyCode.F6, KeyFlag.Control));
        actionHandlers ~= delegate() {
            loop_btn.click(loop_btn);
            return;
        };
        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Loop Sequence (rehearsable)..."d, null, KeyCode.F6, KeyFlag.Shift));
        actionHandlers ~= delegate() {
            loopB_btn.click(loopB_btn);
            return;
        };

        auto x_preview_percentage = new TextWidget(null,
            to!dstring(preview_percentage) ~ "%"d);
        x_preview_percentage.minWidth = cast(int)(50 * retina_factor);
        x_preview_percentage.maxWidth = cast(int)(50 * retina_factor);
        x_preview_percentage.fontFace = pat_dip_font;
        x_preview_percentage.fontSize = cast(int)(pat_dip_size * retina_factor);
        x_preview_percentage.fontWeight = pat_dip_weight;
        x_preview_percentage.alignment = Align.Right | Align.VCenter;

        x_preview_percentage.mouseEvent = delegate(Widget src, MouseEvent evt) {

            if (evt.wheelDelta <= -7) {
                preview_percentage = min(preview_percentage + 10,
                    999);
            } else if (evt.wheelDelta < 0) {
                preview_percentage = min(preview_percentage + 1, 999);
            } else if (evt.wheelDelta >= 7) {
                preview_percentage = max(preview_percentage - 10,
                    1);
            } else if (evt.wheelDelta > 0) {
                preview_percentage = max(preview_percentage - 1, 1);
            } else
                return true;

            x_preview_percentage.text = to!dstring(preview_percentage) ~ "%"d;

            return true;
        };

        tools.addChild(x_preview_percentage);

        headrow = new HorizontalLayout;

        headrow.addChild(new TextWidget(null, "Current sequence: "d));

        sequence_selector = new ComboBox;
        sequence_selector.minWidth = cast(int)(220 * retina_factor);
        sequence_selector.maxWidth = cast(int)(220 * retina_factor);

        sequence_selector.itemClick = delegate(Widget w, int idx) {
            if (ignore_input)
                return true;

            attachSequence(workspace.sequences[idx]);

            return true;
        };

        headrow.addChild(sequence_selector);

        auto chg_name = new Button;
        chg_name.text = "Rename..."d;
        chg_name.click = delegate(Widget src) {
            auto dlg = new InputBox(UIString("Rename Sequence..."d),
                UIString("Change sequence name to:"d), window,
                to!dstring(seq.name), delegate(dstring result) {
                seq.name = to!string(result);
                updateWorkspace();
                attachSequence(seq);
            });
            dlg.show();
            return true;
        };

        headrow.addChild(chg_name);
        headrow.addChild(new TextWidget(null, "  "d));

        auto clone_btn = new Button;
        clone_btn.text = "Clone"d;

        clone_btn.click = delegate(Widget src) {

            auto nseq = seq.dup();
            nseq.name ~= "'";
            workspace.sequences ~= nseq;

            updateWorkspace;
            nofix_scroll = true; /* I honestly have no idea, why window.layout crashes here */
            attachSequence(nseq);
            nofix_scroll = false;
            updateWorkspace;

            return true;
        };

        headrow.addChild(clone_btn);

        auto new_btn = new Button;
        new_btn.text = "New"d;

        new_btn.click = delegate(Widget src) {

            auto nseq = seq.dup();
            nseq.name = "Seq. " ~ to!string(workspace.sequences.length);
            workspace.sequences ~= nseq;

            updateWorkspace;
            nofix_scroll = true; /* I honestly have no idea, why window.layout crashes here */
            attachSequence(nseq);
            nofix_scroll = false;
            updateWorkspace;

            return true;
        };

        headrow.addChild(new_btn);

        master.addChild(tools);
        master.addChild(headrow);

        auto heading = new HorizontalLayout;

        auto plhnd = new TextWidget(null, " "d);
        plhnd.minWidth = cast(int)(20 * retina_factor);
        plhnd.maxWidth = cast(int)(20 * retina_factor);

        heading.addChild(plhnd);

        auto nbr = new TextWidget(null, "Nbr."d);
        nbr.minWidth = cast(int)(30 * retina_factor);
        nbr.maxWidth = cast(int)(30 * retina_factor);

        heading.addChild(nbr);
        auto patorseq = new TextWidget(null, "P/S"d);
        patorseq.minWidth = cast(int)(30 * retina_factor);
        patorseq.maxWidth = cast(int)(30 * retina_factor);

        heading.addChild(patorseq);
        auto psname = new TextWidget(null, "Name"d);
        psname.minWidth = cast(int)(220 * retina_factor);
        psname.maxWidth = cast(int)(220 * retina_factor);

        heading.addChild(psname);

        auto psbpm = new TextWidget(null, "BPM/%"d);
        psbpm.minWidth = cast(int)(70 * retina_factor);
        psbpm.maxWidth = cast(int)(70 * retina_factor);
        psbpm.alignment = Align.Right;

        heading.addChild(psbpm);
        auto psrepeat = new TextWidget(null, "Repeats"d);
        psrepeat.minWidth = cast(int)(70 * retina_factor);
        psrepeat.maxWidth = cast(int)(70 * retina_factor);
        psrepeat.alignment = Align.Right;

        heading.addChild(psrepeat);

        auto psimage = new TextWidget(null, "Image"d);
        psimage.minWidth = cast(int)(90 * retina_factor);
        psimage.maxWidth = cast(int)(90 * retina_factor);
        psimage.alignment = Align.Right;

        heading.addChild(psimage);
        auto pslink = new TextWidget(null, "Info Link"d);
        pslink.minWidth = cast(int)(60*retina_factor);
        pslink.maxWidth = cast(int)(60*retina_factor);
        pslink.alignment = Align.Right;

        heading.addChild(pslink);

        master.addChild(heading);

        for (int idx = 0; idx < seq_max_rows; ++idx) {
            auto row = new HorizontalLayout;
            auto plhd = new TextWidget(null, " "d);
            plhd.minWidth = cast(int)(20 * retina_factor);
            plhd.maxWidth = cast(int)(20 * retina_factor);
            plhd.fontFace = pat_dip_font;
            plhd.fontSize = cast(int)(pat_dip_size * retina_factor);
            plhd.fontWeight = pat_dip_weight;

            row.addChild(plhd);

            playhead ~= plhd;

            auto rnbr = new TextWidget(null, to!dstring(idx + 1));

            rnbr.minWidth = cast(int)(30 * retina_factor);
            rnbr.maxWidth = cast(int)(30 * retina_factor);
            rnbr.alignment = Align.Right;

            row.addChild(rnbr);

            auto pors = new TextWidget(null, "Pat. "d);

            pors.minWidth = cast(int)(30 * retina_factor);
            pors.maxWidth = cast(int)(30 * retina_factor);
            pors.alignment = Align.Right;

            row.addChild(pors);

            pat_or_seq ~= pors;

            auto cb = new ComboBox;

            cb.minWidth = cast(int)(220 * retina_factor);
            cb.maxWidth = cast(int)(220 * retina_factor);

            cb.itemClick = (nbr => delegate(Widget wdg, int index) {
                if (seq.list.length <= nbr)
                    return true;
                if (ignore_input)
                    return true;

                UndoSlotChanges d = new UndoSlotChanges();
                d.indices ~= nbr;
                d.restore ~= seq.list[nbr];
                d.type = "Seq";

                if (index < workspace.patterns.length) {

                    seq.list[nbr].filled = true;
                    seq.list[nbr].references_pattern = true;
                    seq.list[nbr].id = index;
                    if (nbr < seq_max_rows - 1) {
                        if (!seq.list[nbr + 1].filled)
                            seq.list[nbr + 1].bpm = seq.list[nbr].bpm;
                        updateRow(nbr + 1);
                        rows[nbr + 1].visibility = Visibility.Visible;
                    }

                } else if (index == workspace.patterns.length) {
                    seq.list[nbr].filled = false;
                    seq.list[nbr].references_pattern = false;
                    seq.list[nbr].id = 0;

                    attachSequence(seq);
                } else {

                    seq.list[nbr].filled = true;
                    seq.list[nbr].references_pattern = false;
                    seq.list[nbr].id = index - 1 - cast(int)workspace.patterns.length;
                    if (nbr < seq_max_rows - 1) {
                        if (!seq.list[nbr + 1].filled)
                            seq.list[nbr + 1].bpm = seq.list[nbr].bpm;
                        updateRow(nbr + 1);
                        rows[nbr + 1].visibility = Visibility.Visible;
                    }
                }
                if (seq.list[nbr] != d.restore[0]) {
                    seq.killRedo;
                    if (seq.hasUndo) {
                        UndoSlotChanges top = cast(UndoSlotChanges)seq.peekUndoTop;
                        if (top !is null) {
                            if ((top.indices != d.indices) || (top.type != d.type))
                                seq.addUndo(&undoSlotChanges, d);
                        } else {
                            seq.addUndo(&undoSlotChanges, d);
                        }
                    } else
                        seq.addUndo(&undoSlotChanges, d);
                }
                updateRow(nbr);
                updateToolbar;
                fixScroll;

                return true;
            })(idx);

            sel ~= cb;

            row.addChild(cb);

            auto bpm = new TextWidget(null, "120bpm"d);

            bpm.minWidth = cast(int)(70 * retina_factor);
            bpm.maxWidth = cast(int)(70 * retina_factor);
            bpm.alignment = Align.Right;
            bpm.fontFace = pat_dip_font;
            bpm.fontSize = cast(int)(pat_dip_size * retina_factor);
            bpm.fontWeight = pat_dip_weight;

            bpm.mouseEvent = (nbr => delegate(Widget src, MouseEvent evt) {
                UndoSlotChanges d = new UndoSlotChanges();
                d.indices ~= nbr;
                d.restore ~= seq.list[nbr];
                d.type = "BPM";

                if (evt.wheelDelta <= -7) {
                    seq.list[nbr].bpm = min(seq.list[nbr].bpm + 10,
                        999);
                } else if (evt.wheelDelta < 0) {
                    seq.list[nbr].bpm = min(seq.list[nbr].bpm + 1,
                        999);
                } else if (evt.wheelDelta >= 7) {
                    seq.list[nbr].bpm = max(seq.list[nbr].bpm - 10,
                        1);
                } else if (evt.wheelDelta > 0) {
                    seq.list[nbr].bpm = max(seq.list[nbr].bpm - 1,
                        1);
                } else
                    return true;

                if (seq.list[nbr] != d.restore[0]) {
                    seq.killRedo;
                    if (seq.hasUndo) {
                        UndoSlotChanges top = cast(UndoSlotChanges)seq.peekUndoTop;
                        if (top !is null) {
                            if ((top.indices != d.indices) || (top.type != d.type))
                                seq.addUndo(&undoSlotChanges, d);
                        } else {
                            seq.addUndo(&undoSlotChanges, d);
                        }
                    } else
                        seq.addUndo(&undoSlotChanges, d);
                }
                updateRow(nbr);
                updateToolbar();
                return true;
            })(idx);

            bpms ~= bpm;

            row.addChild(bpm);

            auto repeat = new TextWidget(null, "(skip)"d);

            repeat.minWidth = cast(int)(70 * retina_factor);
            repeat.maxWidth = cast(int)(70 * retina_factor);
            repeat.alignment = Align.Right;
            repeat.fontFace = pat_dip_font;
            repeat.fontSize = cast(int)(pat_dip_size * retina_factor);
            repeat.fontWeight = pat_dip_weight;
            repeat.mouseEvent = (nbr => delegate(Widget src, MouseEvent evt) {
                UndoSlotChanges d = new UndoSlotChanges();
                d.indices ~= nbr;
                d.restore ~= seq.list[nbr];
                d.type = "rep";

                if (evt.wheelDelta <= -7) {
                    seq.list[nbr].repeat_count = min(
                        seq.list[nbr].repeat_count + 10, 999);
                } else if (evt.wheelDelta < 0) {
                    seq.list[nbr].repeat_count = min(
                        seq.list[nbr].repeat_count + 1, 999);
                } else if (evt.wheelDelta >= 7) {
                    seq.list[nbr].repeat_count = max(
                        seq.list[nbr].repeat_count - 10, 0);
                } else if (evt.wheelDelta > 0) {
                    seq.list[nbr].repeat_count = max(
                        seq.list[nbr].repeat_count - 1, 0);
                } else
                    return true;

                if (seq.list[nbr] != d.restore[0]) {
                    seq.killRedo;
                    if (seq.hasUndo) {
                        UndoSlotChanges top = cast(UndoSlotChanges)seq.peekUndoTop;
                        if (top !is null) {
                            if ((top.indices != d.indices) || (top.type != d.type))
                                seq.addUndo(&undoSlotChanges, d);
                        } else {
                            seq.addUndo(&undoSlotChanges, d);
                        }
                    } else
                        seq.addUndo(&undoSlotChanges, d);
                }
                updateRow(nbr);
                updateToolbar();
                return true;
            })(idx);

            repeats ~= repeat;

            row.addChild(repeat);
            auto image = new TextWidget(null, "(no image set)"d);

            image.minWidth = cast(int)(90 * retina_factor);
            image.maxWidth = cast(int)(90 * retina_factor);
            image.alignment = Align.Right;
            image.mouseEvent = (nbr => delegate(Widget src, MouseEvent evt) {

                if (evt.button == MouseButton.Left) {

                    auto dlg = new ImageDialog(window);

                    dlg.img_path = seq.list[nbr].rehearsal_image;


                    dlg.okay = delegate() {
                    
                        if (seq.list[nbr].rehearsal_image == dlg.img_path)
                            return;

                        UndoSlotChanges d = new UndoSlotChanges();
                        d.indices ~= nbr;
                        d.restore ~= seq.list[nbr];
                        d.type = "IMG";

                        seq.list[nbr].rehearsal_image = dlg.img_path;

                        try {
                            seq.rehearsal_images[nbr] = loadImage(dlg.img_path);
                        } catch(Throwable o) {
                            seq.rehearsal_images[nbr] = null;
                        }


                            seq.killRedo;
                            seq.addUndo(&undoSlotChanges, d);
                        updateRow(nbr);
                        updateToolbar();
                    };

                    dlg.show();
                }

                return true;
            })(idx);

            images ~= image;

            row.addChild(image);
            auto link = new TextWidget(null, "(no link)"d);

            link.minWidth = cast(int)(60 * retina_factor);
            link.maxWidth = cast(int)(60 * retina_factor);
            link.alignment = Align.Right;
            link.mouseEvent = (nbr => delegate(Widget src, MouseEvent evt) {

                bool show_dlg = false;

                if (evt.button == MouseButton.Left) {
                    if (seq.list[nbr].info_link != "") {
                        platform.openURL(seq.list[nbr].info_link);
                    } else
                        show_dlg = true;
                }

                if (evt.button == MouseButton.Right || show_dlg) {

                    auto dlg = new LinkDialog(window);

                    dlg.link = seq.list[nbr].info_link;
                    dlg.okay = delegate() {
                    
                        if (seq.list[nbr].info_link == dlg.link)
                            return;

                        UndoSlotChanges d = new UndoSlotChanges();
                        d.indices ~= nbr;
                        d.restore ~= seq.list[nbr];
                        d.type = "URL";

                        seq.list[nbr].info_link = dlg.link;


                        seq.killRedo;
                        seq.addUndo(&undoSlotChanges, d);
                        updateRow(nbr);
                        updateToolbar();
                    };


                    dlg.show();

                }

                return true;
            })(idx);

            links ~= link;

            row.addChild(link);



            SketchSequence.Slot clipboard;



            auto btn_see = new Button(null, "See"d);
            btn_see.click = (nbr => delegate(Widget src) {
    
                    auto slot = seq.list[nbr];

                    if (slot.filled) {
                        if (slot.references_pattern) {
                            ui.showPat(slot.id);
                        } else ui.showSeq(slot.id);
                    }
                    return true;
                })(idx);


            auto btn_rehearse = new Button(null, "Rehearse"d);
            btn_rehearse.click = (nbr => delegate(Widget src) {

                    ui.setRehearserImage(seq.rehearsal_images[nbr]);

                    auto slot = seq.list[nbr];

                    if (slot.filled) {
                        if (slot.references_pattern) {
                            /** loop pattern */
                            if ((slot.id >= 0)&&(slot.id < workspace.patterns.length)) {
                                    
                                    int seq_idx = -1;
                                    foreach (idx, s;
                                    workspace.sequences) {
                                        if (s is seq) {
                                            seq_idx = cast(int)idx;
                                            break;
                                        }
                                    }

                                    ui.playRehearsePattern(slot.id, seq_idx, nbr, slot.bpm, preview_percentage);

                            }

                        } else {
                            /** loop sequence */
                            if ((slot.id >= 0)&&(slot.id < workspace.sequences.length)) {
                                    int seq_idx = -1;
                                    foreach (idx, s;
                                    workspace.sequences) {
                                        if (s is seq) {
                                            seq_idx = cast(int)idx;
                                            break;
                                        }
                                    }

                                    if (seq_idx >= 0)

                                ui.playRehearseSubSequence(seq_idx, nbr, preview_percentage);
                            }

                        }
                    }
                    
                    return true;
                })(idx);

                auto btn_copy = new Button(null, "Copy"d);
                btn_copy.click = (nbr => delegate(Widget src) {
                    clipboard = seq.list[nbr];

                return true;
            })(idx);

            auto btn_paste = new Button(null, "Paste"d);
            btn_paste.click = (nbr => delegate(Widget src) {
                if (clipboard != seq.list[nbr]) {
                    UndoSlotChanges d = new UndoSlotChanges();
                    d.indices ~= nbr;
                    d.restore ~= seq.list[nbr];
                    d.type = "Paste";

                    seq.list[nbr] = clipboard;

                    seq.killRedo;
                    seq.addUndo(&undoSlotChanges, d);

                    if (nbr < seq_max_rows - 1) {
                        if (!seq.list[nbr + 1].filled)
                            seq.list[nbr + 1].bpm = seq.list[nbr].bpm;
                        updateRow(nbr + 1);
                        rows[nbr + 1].visibility = Visibility.Visible;
                    }

                    updateRow(nbr);
                    updateToolbar;
                    fixScroll;
                }

                return true;
            })(idx);

            auto btn_insert = new Button(null, "Insert"d);
            btn_insert.click = (nbr => delegate(Widget src) {

                auto d = seq.getNewRestore;
                d.type = "Insert";

                for (int idx = seq_max_rows - 1;
                idx > nbr;
                --idx) {
                    seq.list[idx] = seq.list[idx - 1];
                }

                seq.list[nbr].filled = false;
                if (nbr > 0)
                    seq.list[nbr].bpm = seq.list[nbr - 1].bpm;

                seq.killRedo;
                seq.addUndo(&undoSlotChanges, d);

                attachSequence(seq);

                return true;
            })(idx);

            auto btn_erase = new Button(null, "Erase"d);
            btn_erase.click = (nbr => delegate(Widget src) {

                auto d = seq.getNewRestore;
                d.type = "Erase";

                for (int idx = nbr;
                idx < seq_max_rows - 1;
                ++idx) {
                    seq.list[idx] = seq.list[idx + 1];
                }
                seq.list[seq_max_rows - 1].filled = false;

                seq.killRedo;
                seq.addUndo(&undoSlotChanges, d);

                attachSequence(seq);

                return true;
            })(idx);

            row.addChild(btn_see);
            row.addChild(btn_rehearse);
            row.addChild(btn_copy);
            row.addChild(btn_paste);
            row.addChild(btn_insert);
            row.addChild(btn_erase);

            rowlayout.addChild(row);

            rows ~= row;
        }

        auto seqscr = new ScrollWidget("scrlseq");
        seqscr.contentWidget = rowlayout;

        seqscr.vscrollbar.minWidth = cast(int)(20 * retina_factor);
        seqscr.vscrollbar.maxWidth = cast(int)(20 * retina_factor);
        seqscr.hscrollbar.minHeight = cast(int)(20 * retina_factor);
        seqscr.hscrollbar.maxHeight = cast(int)(20 * retina_factor);

        master.addChild(seqscr);

        updateWorkspace();

        if (workspace.sequences.length == 0)
            attachSequence(new SketchSequence());
        else
            attachSequence(workspace.sequences[0]);

    }

    void fixScroll() {
        if (nofix_scroll)
            return;
        try {
            window.layout;
        }
        catch (Throwable o) {
            writeln("window.layout error: ", o);
        }
    }

    void updateToolbar() {
        undo_btn.enabled = seq.hasUndo;
        redo_btn.enabled = seq.hasRedo;
    }

    void updateRow(int idx) {
        if (idx >= seq.list.length) {
            ignore_input = true;
            sel[idx].selectedItemIndex = cast(int)workspace.patterns.length;
            ignore_input = false;
            return;
        }
        auto r = seq.list[idx];

        int sidx;

        if (r.filled) {
            if (r.references_pattern) {
                sidx = r.id;
            } else
                sidx = cast(int)workspace.patterns.length + 1 + r.id;
        } else {
            sidx = cast(int)workspace.patterns.length;
        }

        if (r.repeat_count > 0)
            repeats[idx].text = to!dstring(r.repeat_count);
        else
            repeats[idx].text = "(skip)"d;

        if (r.references_pattern) {
            bpms[idx].text = to!dstring(r.bpm) ~ "bpm"d;
        } else
            bpms[idx].text = to!dstring(r.bpm) ~ " %"d;

        if (seq.rehearsal_images[idx] is null)
            images[idx].text = "(!)"d ~ to!dstring(r.rehearsal_image);
        else
            images[idx].text = to!dstring(r.rehearsal_image);
        if (r.info_link == "")
            links[idx].text = "(no link)"d;
        else
            links[idx].text = to!dstring(r.info_link);

        ignore_input = true;
        sel[idx].selectedItemIndex = sidx;
        ignore_input = false;
    }

    void attachSequence(SketchSequence s) {
        seq = s;
        writeln("..attaching Sequence ", seq);

        int last_row = 0;
        foreach (idx, r; seq.list) {
            if (r.filled) {
                last_row = cast(int)idx + 1;
            }
        }

        last_row++;

        if (last_row >= seq_max_rows)
            last_row = seq_max_rows;

        writeln("Last Row:", last_row);

        foreach (idx, r; rows) {
            writeln("updateRow ", idx, " . ", r);
            updateRow(cast(int)idx);

            if (idx < last_row) {

                r.visibility = Visibility.Visible;
            } else {
                r.visibility = Visibility.Gone;
            }
        }

        writeln("..rows", seq);
        updateToolbar();
        writeln("..toolbar", seq);
        clearPlayhead();
        writeln("..playhead", seq);
        fixScroll;
        writeln("...fixed scroll.<--. done.");
    }

    void updateWorkspace() {
        dstring[] seqlist;
        int seqsel = 0;
        foreach (idx, p; workspace.sequences) {
            seqlist ~= to!dstring(p.name);
            if (p is seq)
                seqsel = cast(int)idx;
        }

        ignore_input = true;

        sequence_selector.items = seqlist;
        sequence_selector.selectedItemIndex = seqsel;

        dstring[] patseqlist;
        foreach (p; workspace.patterns) {
            patseqlist ~= to!dstring(p.name) ~ " [P]";
        }
        patseqlist ~= "----------------- (skip)"d;
        foreach (s; workspace.sequences) {
            patseqlist ~= to!dstring(s.name) ~ " [S]";
        }
        foreach (x; sel) {
            x.items = patseqlist;
        }
        ignore_input = false;

        if (seq !is null) {

            foreach (idx, r; rows)
                updateRow(cast(int)idx);
        }

    }

    void undo() {
        seq.undo();

        attachSequence(seq);
    }

    void redo() {
        seq.redo();

        attachSequence(seq);
    }

    void attachTab() {
        updateWorkspace();
    }

    void deattachTab() {
    }
}

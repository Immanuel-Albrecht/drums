module patui;

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
import sync;
import pattern;
import common;

import sketch;
import songsketch;
import sketchui;
import drumkit;

struct PatternEditorVars {
    Workspace workspace;
    UserInterface ui;

    Window window;

    VerticalLayout master;
    VerticalLayout rowlayout;

    HorizontalLayout tools;

    HorizontalLayout headrow;
    ComboBox pattern_selector;

    int preview_bpm = 120;

    HorizontalLayout[] rows;
    TextWidget[] dips; //<! store the text widgets that show off the current pattern hits
    ComboBox[] target_drums; //<! store the target drum names

    TextWidget tablehead; //<! table head
    TextWidget playhead; //<! indicator for current playback position

    TextWidget denominator; //<! pattern denominator
    TextWidget columns; //<! columns in pattern
    TextWidget x_preview_bpm; //<! show the current preview bpm setting

    SketchPattern pat; //<! store the current sketch pattern object...

    Button undo_btn;
    Button redo_btn;
    CheckBox l_toggle_hit; //<! toggle hit on left mouse?
    CheckBox l_set_strength; //<! set strength on left mouse?
    int l_strength = default_hit_strength; //<! strength to set on left mouse

    bool ignore_input = false;

    bool dip_click;

    void cleanup() {
    }

    void updateWorkspace() {

        dstring[] patlist;
        int sel = 0;
        foreach (idx, p; workspace.patterns) {
            patlist ~= to!dstring(p.name);
            if (p == pat)
                sel = cast(int)idx;
        }

        ignore_input = true;
        pattern_selector.items = patlist;
        pattern_selector.selectedItemIndex = sel;

        ignore_input = false;

    }

    void clearPlayhead() {
        playhead.text = " "d;
    }

    void setPlayhead(int col) {
        string txt = " ";
        for (auto i = 0; i < col; ++i)
            txt ~= ".. ";
        txt ~= ">>";
        playhead.text = to!dstring(txt);
    }

    void init(VerticalLayout l, Window w, Workspace wsp, UserInterface _ui) {
        ui = _ui;
        window = w;
        master = l;
        workspace = wsp;

        auto hl0 = new HorizontalLayout;
        auto hl0t = new TextWidget(null, " "d);
        hl0t.minWidth = cast(int)( 100 * retina_factor);
        hl0t.maxWidth = cast(int)( 100 * retina_factor);

        playhead = new TextWidget(null, " "d);
        playhead.fontFace = pat_dip_font;
        playhead.fontSize = cast(int) ( pat_dip_size * retina_factor );
        playhead.fontWeight = pat_dip_weight;

        hl0.addChild(hl0t);

        hl0.addChild(playhead);

        auto hlx = new HorizontalLayout;

        auto hlx0 = new TextWidget(null, "Denominator: "d);

        hlx.addChild(hlx0);

        denominator = new TextWidget(null, "4"d);
        denominator.minWidth = cast(int) ( 30 * retina_factor);
        denominator.maxWidth = cast(int) ( 30 * retina_factor);
        denominator.fontFace = pat_dip_font;
        denominator.fontSize = cast(int) ( pat_dip_size * retina_factor);
        denominator.fontWeight = pat_dip_weight;
        denominator.alignment = Align.Right;

        bool denominator_btn_down = false;

        denominator.mouseEvent = delegate(Widget src, MouseEvent evt) {
            if (evt.lbutton.isDown) {
                denominator_btn_down = true;
            } else if (denominator_btn_down) {
                denominator_btn_down = false;

                auto dlg = new InputBox(
                    UIString.fromRaw("Set Pattern Denominator..."d),
                    UIString.fromRaw("Set columns per beat to:"d),
                    window, to!dstring(pat.denominator),
                    delegate(dstring result) {
                    try {
                        auto result_denominator = min(max(1, to!int(result)),
                            32);
                        if (result_denominator != pat.denominator) {
                            window.showMessageBox(
                                UIString.fromRaw("Change Pattern Denominator..."d),
                                UIString.fromRaw("Interpolate current columns?"d),
                                [ACTION_YES, ACTION_NO], 1,
                                delegate(const Action a) {

                                auto rsp = pat.getNewRestore;

                                if (a.id == StandardAction.Yes) {
                                    /* interpolate current beats */

                                    auto rcols = cast(int)(
                                        ((cast(float)pat.cols) / pat.denominator) * result_denominator + .99);

                                    int[] h1_t;
                                    for (auto c = 0;
                                    c < rcols;
                                    ++c) {
                                        h1_t ~= cast(int)(
                                            (cast(float)c * pat.denominator) / result_denominator);
                                    }

                                    if (rcols > pat.cols) {

                                        /* stretch contents */

                                        foreach (idx, ref h;
                                        pat.hits) {
                                            auto h0 = rsp.hits[idx];

                                            h.length = rcols;

                                            for (auto c = 0;
                                            c < rcols;
                                            ++c) {
                                                if ((c == 0)
                                                        || (h1_t[c - 1] < h1_t[c]))
                                                    h[c] = h0[h1_t[c]];
                                                else
                                                    h[c] = false;
                                            }

                                        }
                                        foreach (idx, ref h;
                                        pat.hit_strengths) {
                                            auto h0 = rsp.hit_strengths[idx];

                                            h.length = rcols;

                                            for (auto c = 0;
                                            c < rcols;
                                            ++c) {
                                                h[c] = h0[h1_t[c]];
                                            }
                                        }
                                    } else {

                                        /* compress contents */

                                        foreach (idx, ref h;
                                        pat.hits) {
                                            auto h0 = rsp.hits[idx];

                                            h.length = rcols;

                                            for (auto c = 0;
                                            c < rcols;
                                            ++c) {
                                                int upper_bound;
                                                if (c + 1 < rcols)
                                                    upper_bound = h1_t[c + 1];
                                                else
                                                    upper_bound = pat.cols;

                                                h[c] = false;

                                                for (auto i = h1_t[c];
                                                i < upper_bound;
                                                ++i) {
                                                    if (h0[i]) /* collect hits from the range */
                                                        h[c] = true;
                                                }
                                            }

                                        }
                                        foreach (idx, ref h;
                                        pat.hit_strengths) {
                                            auto h0 = rsp.hit_strengths[idx];
                                            auto hx0 = rsp.hits[idx];
                                            auto hx = pat.hits[idx];

                                            h.length = rcols;
                                            for (auto c = 0;
                                            c < rcols;
                                            ++c) {
                                                int upper_bound;
                                                if (c + 1 < rcols)
                                                    upper_bound = h1_t[c + 1];
                                                else
                                                    upper_bound = pat.cols;

                                                int maximum = 0;
                                                for (auto i = h1_t[c];
                                                i < upper_bound;
                                                ++i) {
                                                    if (hx0[i] || (!hx[c])) /* collect hits from the range */
                                                        maximum = max(maximum,
                                                            h0[i]);
                                                }

                                                h[c] = maximum;

                                            }

                                        }
                                    }

                                    pat.cols = rcols;

                                }

                                pat.denominator = result_denominator;
                                pat.killRedo;
                                pat.addUndo(&undoRSP, rsp);

                                attachPattern(pat);
                                updateToolbar;
                                fixScroll;

                                return true;
                            });
                        }
                    }
                    catch (Throwable all) {
                        return;
                    }
                });
                dlg.show();
            }

            return true;
        };

        hlx.addChild(denominator);

        columns = new TextWidget(null, "x"d);
        columns.minWidth = cast(int) ( 45 * retina_factor);
        columns.maxWidth = cast(int) ( 45 * retina_factor);
        columns.fontFace = pat_dip_font;
        columns.fontSize = cast(int) ( pat_dip_size * retina_factor);
        columns.fontWeight = pat_dip_weight;
        columns.alignment = Align.Right;

        bool columns_btn_down = false;

        columns.mouseEvent = delegate(Widget src, MouseEvent evt) {
            if (evt.lbutton.isDown) {
                columns_btn_down = true;
            } else if (columns_btn_down) {
                columns_btn_down = false;

                auto dlg = new InputBox(
                    UIString.fromRaw("Set Pattern Length..."d),
                    UIString.fromRaw("Change number of pattern columns to:"d),
                    window, to!dstring(pat.cols), delegate(dstring result) {
                    try {
                        auto result_cols = min(max(0, to!int(result)),
                            512);
                        if (result_cols != pat.cols) {
                            auto data = pat.getNewRestore;

                            if (result_cols < pat.cols) {
                                foreach (ref h;
                                pat.hits) {
                                    h.length = result_cols;
                                }
                                foreach (ref hs;
                                pat.hit_strengths) {
                                    hs.length = result_cols;
                                }
                            } else {
                                foreach (ref h;
                                pat.hits) {
                                    for (auto idx = pat.cols;
                                    idx < result_cols;
                                    ++idx) {
                                        h ~= false;
                                    }
                                }
                                foreach (ref hs;
                                pat.hit_strengths) {
                                    for (auto idx = pat.cols;
                                    idx < result_cols;
                                    ++idx) {
                                        hs ~= default_hit_strength;
                                    }
                                }
                            }
                            pat.cols = result_cols;
                            pat.killRedo;
                            pat.addUndo(&undoRSP, data);

                            attachPattern(pat);
                            updateToolbar;

                            fixScroll();

                        }
                    }
                    catch (Throwable all) {
                        return;
                    }
                });
                dlg.show();
            }

            return true;
        };

        auto hlx1 = new TextWidget(null, " Columns: "d);

        hlx.addChild(hlx1);
        hlx.addChild(columns);

        auto hl = new HorizontalLayout;

        auto hdx = new TextWidget(null, "Offset"d);

        hdx.minWidth = cast(int) ( 100 * retina_factor );
        hdx.maxWidth = cast(int) ( 100 * retina_factor );

        hl.addChild(hdx);

        tablehead = new TextWidget();
        tablehead.fontFace = pat_dip_font;
        tablehead.fontSize = cast(int) ( pat_dip_size * retina_factor );
        tablehead.fontWeight = pat_dip_weight;

        bool tablehead_down = false;

        PopupWidget dlg = null;

        bool[] copy_hit;
        int[] copy_strength;

        tablehead.mouseEvent = delegate(Widget src, MouseEvent evt) {
            int col = ((evt.x - src.pos.left) * pat.cols) / src.pos.width;
            if (col >= pat.cols)
                col = pat.cols - 1;

            if (evt.lbutton.isDown) {
                tablehead_down = true;
            } else if (tablehead_down) {
                tablehead_down = false;

                auto layout = new VerticalLayout;
                layout.backgroundColor = "white";

                auto text = new TextWidget(null,
                    "Beat "d ~ to!dstring(col / pat.denominator + 1) ~ " + " ~ to!dstring(
                    col % pat.denominator) ~ "/"d ~ to!dstring(pat.denominator));

                text.backgroundColor = "white";

                layout.addChild(text);
                auto btn_dismiss = new Button(null, "Cancel"d);

                layout.addChild(btn_dismiss);

                auto btn_copy = new Button(null, "Copy Contents"d);
                btn_copy.minHeight = cast(int) (20 * retina_factor);
                btn_copy.minWidth = cast(int) ( 120 * retina_factor);
                auto btn_cut = new Button(null, "Cut Contents"d);
                btn_cut.minHeight = cast(int) ( 20 * retina_factor);
                btn_cut.minWidth = cast(int) ( 120 * retina_factor);

                auto btn_erase = new Button(null, "Erase Column"d);
                btn_erase.minHeight = cast(int) ( 20 * retina_factor);
                btn_erase.minWidth = cast(int) ( 120 * retina_factor);
                auto btn_insert = new Button(null, "Insert Column"d);
                btn_insert.minHeight = cast(int) ( 20 * retina_factor);
                btn_insert.minWidth = cast(int) ( 120 * retina_factor);

                auto btn_paste = new Button(null, "Paste (Replace)"d);
                btn_paste.minHeight = cast(int) ( 20 * retina_factor);
                btn_paste.minWidth = cast(int) ( 120 * retina_factor);
                auto btn_join = new Button(null, "Paste (Join)"d);
                btn_join.minHeight = cast(int) ( 20 * retina_factor);
                btn_join.minWidth = cast(int) ( 120 * retina_factor);

                layout.addChild(btn_copy);
                layout.addChild(btn_cut);
                layout.addChild(btn_paste);
                layout.addChild(btn_join);

                layout.addChild(btn_insert);
                layout.addChild(btn_erase);

                /** kill the old popup */
                if (dlg)
                    dlg.close;

                dlg = window.showPopup(layout, null,
                    PopupAlign.Point, evt.x, evt.y + cast(int) ( 10 * retina_factor));

                btn_dismiss.minHeight = cast(int) (20 * retina_factor);
                btn_dismiss.minWidth = cast(int) ( 120 * retina_factor);
                btn_dismiss.click = delegate(Widget src) {
                    dlg.close;
                    dlg = null;
                    return true;
                };

                btn_copy.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        copy_hit.length = 0;
                        copy_strength.length = 0;

                        foreach (idx, h;
                        pat.hits) {
                            auto hs = pat.hit_strengths[idx];
                            copy_hit ~= h[nbr];
                            copy_strength ~= hs[nbr];
                        }

                    }

                    dlg.close;
                    dlg = null;
                    return true;
                })(col);

                btn_cut.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        copy_hit.length = 0;
                        copy_strength.length = 0;

                        bool add_undo = false;
                        auto rsp = pat.getNewRestore;

                        foreach (idx, ref h;
                        pat.hits) {
                            auto hs = pat.hit_strengths[idx];
                            copy_hit ~= h[nbr];
                            if (h[nbr]) {
                                add_undo = true;
                                h[nbr] = false;
                            }
                            copy_strength ~= hs[nbr];
                        }

                        if (add_undo) {
                            pat.killRedo;
                            pat.addUndo(&undoRSP, rsp);

                            attachPattern(pat);
                        }

                    }

                    dlg.close;
                    dlg = null;
                    return true;
                })(col);
                btn_paste.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        bool add_undo = false;
                        auto rsp = pat.getNewRestore;

                        foreach (idx, ref h;
                        pat.hits) {
                            if (idx < copy_hit.length) {
                                if (copy_hit[idx]) {
                                    if (!h[nbr])
                                        add_undo = true;

                                    h[nbr] = true;

                                    if (
                                            pat.hit_strengths[idx][nbr] != copy_strength[
                                            idx]) {
                                        pat.hit_strengths[idx][nbr] = copy_strength[
                                            idx];
                                        add_undo = true;
                                    }
                                } else {

                                    if (h[nbr]) {
                                        h[nbr] = false;
                                        add_undo = true;
                                    }
                                }
                            } else if (h[nbr]) {
                                h[nbr] = false;
                                add_undo = true;
                            }
                        }

                        if (add_undo) {
                            pat.killRedo;
                            pat.addUndo(&undoRSP, rsp);

                            attachPattern(pat);
                        }

                    }

                    dlg.close;
                    dlg = null;
                    return true;
                })(col);
                btn_join.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        bool add_undo = false;
                        auto rsp = pat.getNewRestore;

                        foreach (idx, ref h;
                        pat.hits) {
                            if (idx < copy_hit.length) {
                                if (copy_hit[idx]) {
                                    if (!h[nbr])
                                        add_undo = true;

                                    h[nbr] = true;

                                    if (
                                            pat.hit_strengths[idx][nbr] != copy_strength[
                                            idx]) {
                                        pat.hit_strengths[idx][nbr] = copy_strength[
                                            idx];
                                        add_undo = true;
                                    }
                                }
                            } else
                                break;
                        }

                        if (add_undo) {
                            pat.killRedo;
                            pat.addUndo(&undoRSP, rsp);

                            attachPattern(pat);
                        }

                    }

                    dlg.close;
                    dlg = null;
                    return true;
                })(col);

                btn_erase.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        auto rsp = pat.getNewRestore;

                        pat.cols--;
                        foreach (ref h;
                        pat.hits) {
                            remove(h, nbr); /* std.algorithm.mutation */
                            h.length -= 1; /* "all functions in std.algorithm only change content, not topology." */
                        }
                        foreach (ref h;
                        pat.hit_strengths) {
                            remove(h, nbr); /* std.algorithm.mutation */
                            h.length -= 1; /* "all functions in std.algorithm only change content, not topology." */
                        }

                        pat.killRedo;
                        pat.addUndo(&undoRSP, rsp);

                        attachPattern(pat);
                        fixScroll;
                    }
                    dlg.close;
                    dlg = null;
                    return true;
                })(col);
                btn_insert.click = (nbr => delegate(Widget src) {
                    if (pat.cols > nbr) {
                        auto rsp = pat.getNewRestore;

                        pat.cols++;

                        foreach (ref h;
                        pat.hits) {
                            h = h[0 .. nbr] ~ [false] ~ h[nbr .. $];
                        }
                        foreach (ref h;
                        pat.hit_strengths) {
                            h = h[0 .. nbr] ~ [default_hit_strength] ~ h[nbr .. $];
                        }

                        pat.killRedo;
                        pat.addUndo(&undoRSP, rsp);

                        attachPattern(pat);
                        fixScroll;
                    }
                    dlg.close;
                    dlg = null;
                    return true;
                })(col);

            }

            return true;
        };

        hl.addChild(tablehead);

        rowlayout = new VerticalLayout;
        tools = new HorizontalLayout;

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

            int pat_idx = -1;
            foreach (idx, p;
            workspace.patterns) {
                if (p is pat) {
                    pat_idx = cast(int)idx;
                    break;
                }
            }

            pat.constructProgram(cons, preview_bpm, -1, -1, pat_idx, 100, -1,0, 100);

            ui.Unloop;

            ui.jack.SendProgram(cons.allocProgram);

            return true;
        };
        tools.addChild(play_btn);
        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Play Pattern..."d, null, KeyCode.F7, 0));
        actionHandlers ~= delegate() {
            play_btn.click(play_btn);
            return;
        };

        auto loop_btn = new Button(null, "Loop (editable)"d);
        loop_btn.click = delegate(Widget w) {
            ui.jack.StopPlayback;

            ConstructProgramAction cons;

            int pat_idx = -1;
            foreach (idx, p;
            workspace.patterns) {
                if (p is pat) {
                    pat_idx = cast(int)idx;
                    break;
                }
            }

            pat.constructProgram(cons, preview_bpm, -1, -1, pat_idx, 100, -1,0, 100);

            ui.LoopPattern(pat_idx, preview_bpm);

            ui.jack.SendProgram(cons.allocProgram);

            return true;
        };
        tools.addChild(loop_btn);


        auto loopB_btn = new Button(null, "Loop (rehearsable)"d);
        loopB_btn.click = delegate(Widget w) {
            ui.jack.StopPlayback;

            ConstructProgramAction cons;

            int pat_idx = -1;
            foreach (idx, p;
            workspace.patterns) {
                if (p is pat) {
                    pat_idx = cast(int)idx;
                    break;
                }
            }

            pat.constructProgram(cons, preview_bpm, -1, -1, pat_idx, 100, -1,0, 100);

            ui.jack.SendProgram(cons.allocProgram(true));

            return true;
        };
        tools.addChild(loopB_btn);

        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Loop Pattern (editable)..."d, null, KeyCode.F7, KeyFlag.Control));
        actionHandlers ~= delegate() {
            loop_btn.click(loop_btn);
            return;
        };
        ui.main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Loop Pattern (rehearsable)..."d, null, KeyCode.F7, KeyFlag.Shift));
        actionHandlers ~= delegate() {
            loopB_btn.click(loopB_btn);
            return;
        };

        x_preview_bpm = new TextWidget(null, to!dstring(preview_bpm) ~ "bpm"d);
        x_preview_bpm.minWidth = cast(int) (70 * retina_factor);
        x_preview_bpm.maxWidth = cast(int) ( 70 * retina_factor);
        x_preview_bpm.fontFace = pat_dip_font;
        x_preview_bpm.fontSize = cast(int) ( pat_dip_size * retina_factor);
        x_preview_bpm.fontWeight = pat_dip_weight;
        x_preview_bpm.alignment = Align.Right | Align.VCenter;

        x_preview_bpm.mouseEvent = delegate(Widget src, MouseEvent evt) {

            if (evt.wheelDelta <= -7) {
                preview_bpm = min(preview_bpm + 10, 999);
            } else if (evt.wheelDelta < 0) {
                preview_bpm = min(preview_bpm + 1, 999);
            } else if (evt.wheelDelta >= 7) {
                preview_bpm = max(preview_bpm - 10, 1);
            } else if (evt.wheelDelta > 0) {
                preview_bpm = max(preview_bpm - 1, 1);
            } else
                return true;

            x_preview_bpm.text = to!dstring(preview_bpm) ~ "bpm"d;

            return true;
        };

        tools.addChild(x_preview_bpm);

        tools.addChild(new TextWidget(null, "   Left Click:"d));

        l_toggle_hit = new CheckBox;
        l_toggle_hit.text = "toggles hit"d;
        l_toggle_hit.checked = true;
        tools.addChild(l_toggle_hit);
        l_set_strength = new CheckBox;
        l_set_strength.text = "sets strength to "d;
        l_set_strength.checked = false;
        tools.addChild(l_set_strength);

        auto l_str_ctrl = new TextWidget(null,
            to!dstring(hit_strength_to_text(l_strength)));
        l_str_ctrl.fontFace = pat_dip_font;
        l_str_ctrl.fontSize = cast(int) (pat_dip_size * retina_factor);
        l_str_ctrl.fontWeight = pat_dip_weight;

        l_str_ctrl.mouseEvent = delegate(Widget src, MouseEvent evt) {
            if (evt.wheelDelta <= -7) {
                l_strength = min(127, l_strength + 10);
            } else if (evt.wheelDelta < 0) {
                l_strength = min(127, l_strength + 1);
            } else if (evt.wheelDelta >= 7) {
                l_strength = max(0, l_strength - 10);
            } else if (evt.wheelDelta > 0) {
                l_strength = max(0, l_strength - 1);
            } else
                return true;

            l_str_ctrl.text = to!dstring(hit_strength_to_text(l_strength));
            return true;
        };

        tools.addChild(l_str_ctrl);

        auto l_str_click_fader = new TextWidget(null, "00--+--+--[-C7"d);

        l_str_click_fader.mouseEvent = delegate(Widget src, MouseEvent evt) {

            if (evt.lbutton.isDown) {
                auto x = evt.x - src.pos.left;
                if (x < pat_dip_size * retina_factor)
                    l_strength = 0;
                else if (x > src.width - pat_dip_size * retina_factor) {
                    l_strength = 127;
                } else {
                    l_strength = (cast(int) (x - pat_dip_size * retina_factor) * 127) / (
                        src.width - cast(int) (2 * pat_dip_size * retina_factor));
                }
            }

            l_str_ctrl.text = to!dstring(hit_strength_to_text(l_strength));
            return true;
        };

        tools.addChild(new TextWidget(null, " "d));
        tools.addChild(l_str_click_fader);

        l_str_click_fader.fontFace = pat_dip_font;
        l_str_click_fader.fontSize = cast(int) (pat_dip_size * retina_factor);
        //l_str_click_fader.fontWeight = pat_dip_weight;

        master.addChild(tools);

        headrow = new HorizontalLayout;

        headrow.addChild(new TextWidget(null, "Current pattern: "d));

        pattern_selector = new ComboBox;
        pattern_selector.minWidth = cast(int)(220 * retina_factor);
        pattern_selector.maxWidth = cast(int)(220 * retina_factor);

        pattern_selector.itemClick = delegate(Widget w, int idx) {

            if (ignore_input == false) {
                attachPattern(workspace.patterns[idx]);
                fixScroll;
            }

            return true;
        };

        headrow.addChild(pattern_selector);

        auto chg_name = new Button;
        chg_name.text = "Rename..."d;
        chg_name.click = delegate(Widget src) {
            auto dlg = new InputBox(UIString.fromRaw("Rename Pattern..."d),
                UIString.fromRaw("Change pattern name to:"d), window,
                to!dstring(pat.name), delegate(dstring result) {
                pat.name = to!string(result);
                updateWorkspace();
            });
            dlg.show();
            return true;
        };

        headrow.addChild(chg_name);
        headrow.addChild(new TextWidget(null, "  "d));

        auto clone_btn = new Button;
        clone_btn.text = "Clone"d;

        clone_btn.click = delegate(Widget src) {

            auto npat = pat.dup();
            npat.name ~= "'";
            workspace.patterns ~= npat;
            attachPattern(npat);
            updateWorkspace();
            attachPattern(npat);

            fixScroll;

            return true;
        };

        headrow.addChild(clone_btn);

        auto newrow = new HorizontalLayout;

        newrow.addChild(new TextWidget(null, "New Pattern:"d));

        auto beats = [16, 12, 8, 4, 3, 2];
        auto denoms = [4, 6, 3];

        foreach (denom; denoms) {
            foreach (b; beats) {

                auto cols = cast(int)(b * denom + .1);

                auto new_btn = new Button;
                new_btn.text = to!dstring(cols / denom) ~ " "d ~ to!dstring(
                    cols % denom) ~ "/"d ~ to!dstring(denom);

                new_btn.click = ((_cols, _denom) => delegate(Widget src) {

                    auto npat = new SketchPattern(_cols, _denom);
                    npat.name = "Pat. " ~ to!string(workspace.patterns.length) ~ " [" ~ to!string(
                        _cols / _denom) ~ "+" ~ to!string(_cols % _denom) ~ "/" ~ to!string(
                        _denom) ~ "]";
                    workspace.patterns ~= npat;

                    attachPattern(npat);
                    updateWorkspace();
                    attachPattern(npat);
                    fixScroll;

                    return true;
                })(cols, denom);
                newrow.addChild(new_btn);
            }
        }

        master.addChild(headrow);
        master.addChild(newrow);

        master.addChild(hlx);
        master.addChild(hl0);
        master.addChild(hl);

        dstring[] dnames;
        foreach (d; drumkit.drumkit) {
            dnames ~= to!dstring(d.name);
        }
        dnames ~= "*unassigned*";

        /** add each voices row */
        for (auto i = 0; i < pat_max_rows; ++i) {
            auto row = new HorizontalLayout();

            auto tdrum = new ComboBox();
            tdrum.minWidth = cast(int)(100 * retina_factor);
            tdrum.maxWidth = cast(int)(100 * retina_factor);

            tdrum.items = dnames;

            tdrum.itemClick = (nbr => delegate(Widget src, int idx) {
                if (ignore_input)
                    return true;

                string selection = to!string(dnames[idx]);
                if (pat.rows[nbr] != selection) {

                    pat.killRedo();

                    UndoRoot x = new UndoSetDrum(nbr, selection);
                    redoSetDrum(pat, x);

                    updateRowText(nbr);
                    updateToolbar();
                }

                return false;
            })(i);

            target_drums ~= tdrum;

            row.addChild(tdrum);

            auto dip = new TextWidget();

            dip.text = ".. .. .. .. ..";
            dip.fontFace = pat_dip_font;
            dip.fontSize = cast(int) ( pat_dip_size * retina_factor );
            dip.fontWeight = pat_dip_weight;

            dip.mouseEvent = (nbr => delegate(Widget src, MouseEvent evt) {
                int col = ((evt.x - dips[nbr].pos.left) * pat.cols) / dips[nbr].pos.width;
                if (col >= pat.cols)
                    col = pat.cols - 1;

                if (evt.lbutton.isDown) {
                    dip_click = true;
                } else if (dip_click) {
                    dip_click = false;

                    if (l_toggle_hit.checked) {
                        pat.killRedo();

                        redoSwitchDip(pat, new UndoSwitchDip(nbr,
                            col));
                    }
                    if (l_set_strength.checked) {
                        pat.killRedo();
                        redoSetStrength(pat,
                            new UndoSetStrength(nbr, col, l_strength));

                    }

                    updateRowText(nbr);
                    updateToolbar();
                }

                if (evt.wheelDelta <= -7) {
                    if (!pat.hits[nbr][col]) {
                        pat.killRedo();

                        redoSwitchDip(pat, new UndoSwitchDip(nbr,
                            col));
                    }

                    pat.killRedo();
                    redoSetStrength(pat,
                        new UndoSetStrength(nbr, col, min(127,
                        pat.hit_strengths[nbr][col] + 10)));

                    updateRowText(nbr);
                    updateToolbar();

                } else if (evt.wheelDelta < 0) {
                    if (!pat.hits[nbr][col]) {
                        pat.killRedo();

                        redoSwitchDip(pat, new UndoSwitchDip(nbr,
                            col));
                    }
                    pat.killRedo();
                    redoSetStrength(pat,
                        new UndoSetStrength(nbr, col, min(127,
                        pat.hit_strengths[nbr][col] + 1)));

                    updateRowText(nbr);
                    updateToolbar();
                } else if (evt.wheelDelta >= 7) {
                    if (!pat.hits[nbr][col]) {
                        pat.killRedo();

                        redoSwitchDip(pat, new UndoSwitchDip(nbr,
                            col));
                    }
                    pat.killRedo();
                    redoSetStrength(pat,
                        new UndoSetStrength(nbr, col, max(0,
                        pat.hit_strengths[nbr][col] - 10)));

                    updateRowText(nbr);
                    updateToolbar();
                } else if (evt.wheelDelta > 0) {
                    if (!pat.hits[nbr][col]) {
                        pat.killRedo();

                        redoSwitchDip(pat, new UndoSwitchDip(nbr,
                            col));
                    }
                    pat.killRedo();
                    redoSetStrength(pat,
                        new UndoSetStrength(nbr, col, max(0,
                        pat.hit_strengths[nbr][col] - 1)));

                    updateRowText(nbr);
                    updateToolbar();
                }

                return true;
            })(i);

            row.addChild(dip);

            rowlayout.addChild(row);
            rows ~= row;
            dips ~= dip;
        }

        master.addChild(rowlayout);

        auto add_row_btn = new Button(null, "Add row..."d);

        add_row_btn.click = delegate(Widget src) {

            addRow();

            return true;
        };

        master.addChild(add_row_btn);

        if (workspace.patterns.length == 0)
            attachPattern(new SketchPattern());
        else
            attachPattern(workspace.patterns[0]);
        updateWorkspace();

    }

    void addRow() {
        if (pat.rows.length >= pat_max_rows) {
            master.window.showMessageBox("Add Pattern Row"d,
                "Maximal number of rows reached!"d);
            return;
        }

        pat.killRedo();
        redoAddRow(pat, null);

        updateRowText(cast(int)pat.rows.length - 1);
        rows[pat.rows.length - 1].visibility = Visibility.Visible;
        updateToolbar();
        fixScroll;

    }

    void updateToolbar() {
        undo_btn.enabled = pat.hasUndo;
        redo_btn.enabled = pat.hasRedo;
    }

    void updateRowText(int row) {
        ignore_input = true;
        dips[row].text = pat.textifyRow(row);

        auto idx = get_drum_name_or_shorthand_index(pat.rows[row]);
        if (idx >= 0)
            target_drums[row].selectedItemIndex = idx;
        else {
            target_drums[row].selectedItemIndex = cast(int)drumkit.drumkit.length;
        }
        ignore_input = false;
    }

    void undo() {
        pat.undo();

        attachPattern(pat);
        fixScroll;
    }

    void redo() {
        pat.redo();

        attachPattern(pat);
        fixScroll;
    }

    void fixScroll() {
        try {
            window.layout;
        }
        catch (Throwable o) {
            writeln("window.layout threw: ", o);
        }
    }

    void attachPattern(SketchPattern p) {
        pat = p;

        foreach (idx, s; pat.rows) {
            rows[idx].visibility = Visibility.Visible;
            updateRowText(cast(int)idx);
        }
        for (auto idx = pat.rows.length; idx < pat_max_rows; ++idx) {
            rows[idx].visibility = Visibility.Gone;
        }

        string headtxt = "";
        for (auto i = 0; i < pat.cols; ++i) {
            string mark = "   ";
            if ((i) % pat.denominator == 0) {
                mark ~= to!string((i / pat.denominator) + 1);
            } else {
                auto remainder = i % pat.denominator;
                if (remainder % 4 == 0) {
                    mark ~= "+";
                } else if (remainder % 2 == 0) {
                    mark ~= ".";
                }
            }

            headtxt ~= mark[($ - 3) .. $];
        }

        tablehead.text = to!dstring(headtxt);

        denominator.text = to!dstring(p.denominator);

        if (p.rows.length == 0)
            columns.text = "N/A"d;
        else
            columns.text = to!dstring(p.hits[0].length);

        updateToolbar();
        clearPlayhead();
    }

    void attachTab() {
        attachPattern(pat);
        updateWorkspace();
        fixScroll;
    }

    void deattachTab() {
    }

};

module sketchui;

public import patui;
public import pated;
public import seqed;
public import sequi;
public import rehearseui;

import std.stdio;

import jack.client;
import jack.midiport;
import std.regex;

import core.sys.posix.stdlib: exit;

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

import std.process;
import std.path;
import std.file;

import dlangui;
import dlangui.dialogs.dialog;
import dlangui.dialogs.inputbox;
import filedlg; /** fixed version of FileDialog */

import std.utf;

import core.sync.mutex;

import config;
import sync;
import pattern;
import common;

import sketch;
import songsketch;

debug = fancy;

immutable pat_max_rows = 32; //<! max. number of different drums in a pattern
immutable pat_default_denominator = 4; //<! default = 16ths
immutable pat_default_cols = 4 * pat_default_denominator; //<! default number of columns
immutable pat_default_rows = [
    "kick_a", "kick_b", "snare_ord", "hihat_cls",
    "hihat_opn",
    "ride1", "splash", "crash1", "crash2","china","floor_lo","floor_hi","tom_mid","tom_hi"
]; //<! default row assingments
immutable pat_default_name = "New Pattern";

immutable seq_default_name = "New Sequence";

immutable default_hit_strength = 100;
immutable default_row_drum = "*unassigned*";

float retina_factor = 2; //<! everything pixel is retina_factor*(normal size) on a retina macbook.

immutable pat_dip_font = "Courier New"; //<! should be available almost everywhere
immutable pat_dip_weight = 800; //<! bold!
immutable pat_dip_size = 16;

immutable seq_max_rows = 192; //<! max. number of patterns or subsequences per sequence

/** stash for accelerator triggered actions */
void delegate()[] actionHandlers;
immutable zeroAction = 10000;

/** git command line */
string git_cmd = "git";

class UndoRoot {
}

class Workspace {
    string path;

    SketchPattern[] patterns;
    SketchSequence[] sequences;

    this() {
        patterns ~= new SketchPattern;
        sequences ~= new SketchSequence;
    }

    void uniquifyNames() {
        bool[string] names_list;

        foreach (ref x; patterns) {
            while (x.name in names_list)
                x.name ~= "'";
            names_list[x.name] = true;
        }

        foreach (ref x; sequences) {
            while (x.name in names_list)
                x.name ~= "'";
            names_list[x.name] = true;
        }
    }

    void write(string path) {
        uniquifyNames;

        auto f = File(path, "wt");
        scope (exit)
            f.close();

        this.path = path;

        foreach (p; patterns) {
            p.write(f);
        }
        foreach (s; sequences) {
            s.write(f, this);
        }
    }

    static Workspace read(string path) {
        Workspace w = new Workspace;

        w.patterns.length = 0;
        w.sequences.length = 0;

        string[][] parts;
        int[] type;
        string[] name;
        int pat_count = 0;
        int seq_count = 0;
        int[string] id;
        bool[string] pat_or_seq;

        type ~= 0;
        name ~= "";
        parts ~= cast(string[])[];
        writeln("FILE:", path);

        foreach (line; path.File("rt").byLine) {
            auto m_pattern = match(line, regex(`^\s*\[(.*)]\s*`));
            if (!m_pattern.empty) {
                type ~= 1;
                name ~= to!string(m_pattern.captures[1].dup);
                parts ~= cast(string[])[];

                id[name[$ - 1]] = pat_count;
                pat_or_seq[name[$ - 1]] = true;

                ++pat_count;
            } else {
                auto m_sequence = match(line, regex(`^\s*[{](.*)[}]\s*`));
                if (!m_sequence.empty) {
                    type ~= 2;
                    name ~= to!string(m_sequence.captures[1].dup);
                    parts ~= cast(string[])[];

                    id[name[$ - 1]] = seq_count;
                    pat_or_seq[name[$ - 1]] = false;

                    writeln("S", seq_count);
                    ++seq_count;
                } else {
                    parts[$ - 1] ~= to!string(line.dup);
                }
            }
        }
        writeln(parts);
        writeln(type);
        for (auto idx = 1; idx < parts.length; ++idx) {
            if (type[idx] == 1) {
                w.patterns ~= new SketchPattern(name[idx], parts[idx]);
            } else if (type[idx] == 2) {
                w.sequences ~= new SketchSequence(name[idx],
                    parts[idx], id, pat_or_seq);
            }
        }

        if (w.sequences.length == 0)
            w.sequences ~= new SketchSequence;
        if (w.patterns.length == 0)
            w.patterns ~= new SketchPattern;
        w.path = path.dup;
        writeln("..done reading");
        return w;
    }
};

string hit_strength_to_text(int s) {
    if (s <= 0)
        return "--";

    string txt = "";
    if (s < 100) {
        txt ~= to!string(s / 10);
    } else {
        txt ~= 'A' + (s / 10 - 10);
    }
    txt ~= to!string(s % 10);
    return txt;
}

/** stores the data that belong to a song */
class SketchSong {
}

/** A complete user interface. Yay! */

class UserInterface {

public:

    enum LoopModus {
        nothing = 0,
        pattern,
        sequence
    };

    LoopModus loop = LoopModus.nothing; // should we loop somenthing?
    int loop_id; // id of pattern, sequence, ... to loop
    int loop_bpm;

    void Unloop() {
        loop = LoopModus.nothing;
    }

    void LoopPattern(int id, int bpm) {
        loop_id = id;
        loop_bpm = bpm;
        loop = LoopModus.pattern;
    }

    void LoopSequence(int id, int bpm) {
        loop_id = id;
        loop_bpm = bpm;
        loop = LoopModus.sequence;
    }

    string defID = "UI";

    Window window; //<! main window handle

    Window rehearse_window; //<! external window for rehearser view

    class myTabWidget : TabWidget {

        void delegate() idle;

        this(string s) {
            super(s);
        }

        override bool onTimer(ulong id) {

            idle();

            return true;
        }

        override bool handleAction(const Action a) {
            if (a.id < zeroAction) {
                if (parent) // by default, pass to parent widget
                    return parent.handleAction(a);
                return false;
            }
            if (a.id >= zeroAction + actionHandlers.length) {
                if (parent) // by default, pass to parent widget
                    return parent.handleAction(a);
                return false;
            }

            actionHandlers[a.id - zeroAction]();

            return true;
        }
    }

    myTabWidget main; //<! mainframe tab layout.

    VerticalLayout show_editor; //<! manage songs layout.

    VerticalLayout song_editor; //<! manage songs layout.

    VerticalLayout pattern_editor; //<! manage songs layout.

    VerticalLayout rehearse_tab; //<! rehearse image display
    bool rehearse_in_tab; //<! true whenever rehearse_tab is shown as tab.

    Workspace workspace;

    PatternEditorVars pat;

    struct WorkspaceEditorVars {
        Workspace workspace;
        UserInterface ui;

        Window window;

        VerticalLayout frame;
        HorizontalLayout master;
        HorizontalLayout toolbar;

        VerticalLayout songs;
        VerticalLayout seqs;
        VerticalLayout pats;

        StringListWidget s_list;
        StringListWidget sq_list;
        StringListWidget p_list;

        void init(VerticalLayout layout, Window wnd,
            Workspace wks, UserInterface _ui) {
            ui = _ui;
            workspace = wks;
            frame = layout;


            master = new HorizontalLayout;
            toolbar = new HorizontalLayout;

            auto btn_load = new Button;
            btn_load.text = "Load Workspace..."d;
            btn_load.click = delegate(Widget w) {

                auto dlg = new FileDialog(
                    UIString("Load Workspace..."d), window,
                    null, FileDialogFlag.Open | FileDialogFlag.FileMustExist);
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_WKS_FILES",
                    "Sketch Workspace (*.wks)"d), "*.wks"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_ALL_FILES",
                    "All files (*)"d), "*"));

                if (workspace.path)
                    dlg.filename = workspace.path;

                dlg.dialogResult = delegate(Dialog _dlg, const Action result) {
                    if (result.id == ACTION_OPEN.id) {
                        string filepath = absolutePath(result.stringParam);

                        /** set file directory as current working directory */
                        chdir(dirName(filepath));

                        workspace = Workspace.read(filepath);
                        writeln("..-> exchanging current workspace ");
                        ui.seq.workspace = workspace;
                        writeln("..-> seq ");
                        ui.pat.workspace = workspace;
                        writeln("..-> pat ");
                        ui.workspace = workspace;
                        writeln("..-> rehearse, rehearse2");
                        ui.rehearse.workspace = workspace;
                        ui.rehearse2.workspace = workspace;
                        writeln("..-> ws ");
                        ui.pat.attachPattern(workspace.patterns[0]);
                        writeln("..-> attachPat ");
                        ui.pat.updateWorkspace;
                        writeln("..-> pat.upd ");
                        ui.seq.updateWorkspace;
                        writeln("..-> seq.upd ");

                        bool trap_old = ui.seq.nofix_scroll;
                        ui.seq.nofix_scroll = true;
                        ui.seq.attachSequence(workspace.sequences[0]);
                        writeln("..-> attachSeq ");
                        ui.seq.nofix_scroll = trap_old;

                        updateWorkspace;
                        writeln("..<- done exchanging ");
                    }
                };
                dlg.show();
                return true;
            };

            ui.main.acceleratorMap.add(
                new Action(cast(int)(zeroAction + actionHandlers.length),
                "Load Workspace..."d, null, KeyCode.KEY_O, KeyFlag.Control));
            actionHandlers ~= delegate() {
                btn_load.click(btn_load);
                return;
            };

            toolbar.addChild(btn_load);

            auto btn_saveas = new Button;
            btn_saveas.text = "Save Workspace As..."d;
            btn_saveas.click = delegate(Widget w) {
                auto dlg = new FileDialog(
                    UIString("Save Workspace As..."d), window,
                    null, FileDialogFlag.Save | FileDialogFlag.ConfirmOverwrite);
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_WKS_FILES",
                    "Sketch Workspace (*.wks)"d), "*.wks"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_ALL_FILES",
                    "All files (*)"d), "*"));

                if (workspace.path)
                    dlg.filename = workspace.path;

                dlg.dialogResult = delegate(Dialog _dlg, const Action result) {
                    if (result.id == ACTION_SAVE.id) {
                        string filepath = absolutePath(result.stringParam);

                        /** set file directory as current working directory */
                        chdir(dirName(filepath));

                        if (!endsWith(result.stringParam.toLower,
                                ".wks"))
                            workspace.write(result.stringParam ~ ".wks");
                        else
                            workspace.write(result.stringParam);

                        updateWorkspace;
                    }
                };
                dlg.show();
                return true;
            };

            ui.main.acceleratorMap.add(
                new Action(cast(int)(zeroAction + actionHandlers.length),
                "Save Workspace As..."d, null, KeyCode.KEY_S,
                KeyFlag.Control | KeyFlag.Shift));
            actionHandlers ~= delegate() {
                btn_saveas.click(btn_saveas);
                return;
            };

            auto btn_save = new Button;
            btn_save.text = "Save Workspace"d;
            btn_save.click = delegate(Widget w) {
                if (workspace.path == "")
                    btn_saveas.click(w);
                else {
                    workspace.write(workspace.path);
                }

                updateWorkspace();
                return true;
            };

            auto btn_saveandcommit = new Button;
            btn_saveandcommit.text = "+ git commit"d;
            btn_saveandcommit.click = delegate(Widget w) {
                if (git_cmd.length == 0) {
                    btn_save.click(btn_save);
                    return true;
                }

                void rungit() {
                    /* for some reason, execute seems to be broken on windows platforms */
		    bool dont = false;
                    version (Windows) dont = true;

		    if (dont)
			    return;

                    auto add = execute([git_cmd,"add",  workspace.path]);
                    if (add.status == 0)
                        writeln("Git add:", add.output);
                    else
                        writeln("Error Git Add:", add);
                    auto com = execute([
                        git_cmd, "commit", "-m", workspace.path ~ " commit."]);
                    if (com.status == 0)
                        writeln("Git commit:", com.output);
                    else
                        writeln("Error Git Commit:", com);
                }

                if (workspace.path == "") {
                    auto dlg = new FileDialog(
                        UIString("Save Workspace As..."d), window,
                        null, FileDialogFlag.Save | FileDialogFlag.ConfirmOverwrite);
                    dlg.addFilter(
                        FileFilterEntry(UIString("FILTER_WKS_FILES",
                        "Sketch Workspace (*.wks)"d), "*.wks"));
                    dlg.addFilter(
                        FileFilterEntry(UIString("FILTER_ALL_FILES",
                        "All files (*)"d), "*"));

                    if (workspace.path)
                        dlg.filename = workspace.path;

                    dlg.dialogResult = delegate(Dialog _dlg, const Action result) {
                        if (result.id == ACTION_SAVE.id) {
                            string filepath = result.stringParam;

                            if (!endsWith(result.stringParam.toLower,
                                    ".wks"))
                                workspace.write(result.stringParam ~ ".wks");
                            else
                                workspace.write(result.stringParam);

                            rungit();

                            updateWorkspace;
                        }
                    };
                    dlg.show();
                }
                else {
                    workspace.write(workspace.path);
                    rungit();
                    updateWorkspace();
                }

            



                return true;
            };

            toolbar.addChild(btn_save);
            toolbar.addChild(btn_saveandcommit);
            toolbar.addChild(btn_saveas);

            ui.main.acceleratorMap.add(
                new Action(cast(int)(zeroAction + actionHandlers.length),
                "Save Workspace..."d, null, KeyCode.KEY_S, KeyFlag.Control));
            actionHandlers ~= delegate() {
                btn_save.click(btn_save);
                return;
            };

            ui.main.acceleratorMap.add(
                new Action(cast(int)(zeroAction + actionHandlers.length),
                "Save Workspace + git commit..."d, null,
                KeyCode.KEY_A, KeyFlag.Control));
            actionHandlers ~= delegate() {
                btn_saveandcommit.click(btn_saveandcommit);
                return;
            };

            auto btn_stop = new Button;
            btn_stop.text = "Stop Playback"d;
            btn_stop.click = delegate(Widget w) {
                ui.Unloop;
                ui.jack.StopPlayback;
                return true;
            };

            ui.main.acceleratorMap.add(
                new Action(cast(int)(zeroAction + actionHandlers.length),
                "Stop Playback"d, null, KeyCode.F5, 0));
            actionHandlers ~= delegate() {
                btn_stop.click(btn_stop);
                return;
            };

            toolbar.addChild(btn_stop);

            frame.addChild(toolbar);
            frame.addChild(master);

            window = wnd;

            songs = new VerticalLayout;

            songs.addChild(new TextWidget(null, "Songs"d));

            s_list = new StringListWidget;

            songs.addChild(s_list);

            seqs = new VerticalLayout;

            seqs.addChild(new TextWidget(null, "Sequences"d));

            sq_list = new StringListWidget;
            sq_list.itemClick = delegate(Widget src, int itemIdx) {
            
                if ((itemIdx >= 0) && (itemIdx < workspace.sequences.length)) {
                    ui.seq.attachSequence(workspace.sequences[itemIdx]);
                    ui.main.selectTab(ui.defID~"SONGEDITOR");
                }

                return true;
            };

            seqs.addChild(sq_list);

            pats = new VerticalLayout;

            pats.addChild(new TextWidget(null, "Patterns"d));

            p_list = new StringListWidget;

            p_list.itemClick = delegate(Widget src, int itemIdx) {
            
                if ((itemIdx >= 0) && (itemIdx < workspace.patterns.length)) {
                    ui.pat.attachPattern(workspace.patterns[itemIdx]);
                    ui.main.selectTab(ui.defID~"PATTERNEDITOR");
                }

                return true;
            };

            pats.addChild(p_list);

            master.layoutWidth = FILL_PARENT;

            songs.layoutWidth = FILL_PARENT;
            seqs.layoutWidth = FILL_PARENT;
            pats.layoutWidth = FILL_PARENT;

            master.addChild(songs);
            master.addChild(seqs);
            master.addChild(pats);

            updateWorkspace();

        }

        void updateWorkspace() {
            dstring[] pitems;
            foreach (idx, p; workspace.patterns) {
                pitems ~= to!dstring(p.name ~ "(" ~ to!string(idx + 1) ~ ")");
            }
            p_list.items = pitems;
            dstring[] sqitems;
            foreach (idx, s; workspace.sequences) {
                sqitems ~= to!dstring(s.name ~ "(" ~ to!string(idx + 1) ~ ")");
            }
            sq_list.items = sqitems;
        }

        void attachTab() {
            updateWorkspace();
        }

        void deattachTab() {
        }
    };

    WorkspaceEditorVars wks;

    SequenceEditorVars seq;

    RehearseUI rehearse, rehearse2;

    ScrollWidget patscr;

    void initShowEditor() {
        show_editor = new VerticalLayout(defID ~ "SHOWEDITOR");
        wks.init(show_editor, window, workspace, this);
    }

    void initSongEditor() {
        song_editor = new VerticalLayout(defID ~ "SONGEDITOR");
        seq.init(song_editor, window, workspace, this);
    }

    void initPatternEditor() {
        pattern_editor = new VerticalLayout(defID ~ "PATTERNEDITOR-INTERIOR");
        pat.init(pattern_editor, window, workspace, this);
    }

    void initRehearseInterface() {
        rehearse_tab = new VerticalLayout(defID ~ "REHEARSE");
        rehearse.init(rehearse_tab, window, workspace, this);
    }

    void setRehearserImage(ColorDrawBuf img) {
        rehearse.showImage(img);
        rehearse2.showImage(img);
    }

    void playRehearsePattern(int pat_id, int seq_id, int row, int bpm, int preview_percentage) {
        playRehearsePattern(pat_id,seq_id,row,bpm,preview_percentage, -1, 0, 100);
    }
    /** rehearse the pattern referenced by the given sequence  the given row. */
    void playRehearsePattern(int pat_id, int seq_id, int row, int bpm, int preview_percentage, int subseq_id,
            int subseq_row, int subpercentage) {
                jack.StopPlayback;

                ConstructProgramAction cons;


                auto preview_bpm = max(1, (preview_percentage * bpm) / 100);

                workspace.patterns[pat_id].constructProgram(cons, preview_bpm, seq_id,
                        row, pat_id, preview_percentage, subseq_id ,subseq_row, subpercentage);

                
                foreach ( r; [rehearse,rehearse2]) {
                    r.percentage = preview_percentage;
                    r.subpercentage = subpercentage;
                }

                jack.SendProgram(cons.allocProgram(true));

    }

    void showSeq(int id) {
        if ((id >= 0)&&(id < workspace.sequences.length))
        {
            seq.attachSequence(workspace.sequences[id]);
            seq.updateWorkspace;
        }
        main.selectTab(defID ~ "SONGEDITOR");
    }
    void showPat(int id) {
        if ((id >= 0)&&(id < workspace.patterns.length)){
            pat.attachPattern(workspace.patterns[id]);
            pat.updateWorkspace;
        }
        main.selectTab(defID ~ "PATTERNEDITOR");
    }

    void playRehearseSubSequence(int seq_id, int row, int preview_percentage) {

                auto slot = workspace.sequences[seq_id].list[row];

                                jack.StopPlayback;

                                int percentage = max(1, (preview_percentage * slot.bpm) / 100);

                                ConstructProgramAction cons;

                                /*workspace.sequences[slot.id].constructProgram(cons, percentage,
                                    slot.id, -1, workspace, seq_recursion_depth-1,
                                    -1, preview_percentage);
*/
                                /*  void constructProgram(ref ConstructProgramAction prg,
source/seqed.d-        int percentage, int seq, int row, const Workspace wks, int recursion_depth,
source/seqed.d-        int subseq, int superpercentage) const {*/

                                //ui.LoopSequence(slot.id, percentage);

                                workspace.sequences[slot.id].constructProgram(cons, percentage,
                                    seq_id, row, workspace, seq_recursion_depth-1,
                                    slot.id, preview_percentage);
                
                foreach ( r; [rehearse,rehearse2]) {
                    r.percentage = preview_percentage;
                    r.subpercentage = percentage;
                }

                                jack.SendProgram(cons.allocProgram(true));

    }
    void playRehearseSequence(int seq_id, int preview_percentage) {


                                jack.StopPlayback;


                                ConstructProgramAction cons;

                                /*workspace.sequences[slot.id].constructProgram(cons, percentage,
                                    slot.id, -1, workspace, seq_recursion_depth-1,
                                    -1, preview_percentage);
*/
                                /*  void constructProgram(ref ConstructProgramAction prg,
source/seqed.d-        int percentage, int seq, int row, const Workspace wks, int recursion_depth,
source/seqed.d-        int subseq, int superpercentage) const {*/

                                //ui.LoopSequence(slot.id, percentage);

                                workspace.sequences[seq_id].constructProgram(cons, preview_percentage,
                                    seq_id, -1, workspace, seq_recursion_depth,
                                    -1, preview_percentage);
                
                foreach ( r; [rehearse,rehearse2]) {
                    r.percentage = preview_percentage;
                    r.subpercentage = 100;
                }

                                jack.SendProgram(cons.allocProgram(true));

    }

    void toggleRehearserTabWindow() {
        if (rehearse_in_tab) {
            rehearse_in_tab = false;
            
            rehearse_window.show();
            
        } else {

            /** window.hide() would be a nice feature... */
            rehearse_window.close();
            createRehearseWindow();

            rehearse_in_tab = true;
        }
    }

    void createRehearseWindow() {

        rehearse_window = platform.instance.createWindow(
            "Rehearse -- Song-Sketch[[sythesize]]", null, WindowFlag.Resizable,
            cast(int)(rehearser_width*retina_factor),
            cast(int)(rehearser_height*retina_factor));
        rehearse_window.onCanClose = delegate() {
            toggleRehearserTabWindow();

            return false;
        };

        auto layout = new VerticalLayout();

        rehearse2.init(layout, window, workspace, this);

        layout.layoutWidth = FILL_PARENT;
        layout.layoutHeight = FILL_PARENT;
        rehearse_window.mainWidget = layout;
    }

    void initMainframe() {
        debug (fancy)
            writeln(" initMainframe: in.");
        window = platform.instance.createWindow(
            "Song-Sketch[[sythesize]]", null, WindowFlag.Resizable,
            1080, 700);

        window.onClose = delegate() {
            exit(0);
        };

        window.onCanClose = delegate() {

            window.showMessageBox("Exit Song-Sketch[[synthesize]]?"d,
                    "Closing the main window will destroy all unsaved changes made."d,
                    [ACTION_OK,ACTION_CANCEL],1,
                    delegate(const(Action) a) {
                        if (a.id == StandardAction.Ok)
                            window.close();
                        
                        return true;
                    });

            return false;
        };


        patscr = new ScrollWidget(defID ~ "PATTERNEDITOR");

        patscr.vscrollbar.minWidth = cast(int) ( 20 * retina_factor );
        patscr.vscrollbar.maxWidth = cast(int) ( 20 * retina_factor );
        patscr.hscrollbar.minHeight = cast(int) ( 20 * retina_factor );
        patscr.hscrollbar.maxHeight = cast(int) ( 20 * retina_factor );

        workspace = new Workspace;

        main = new myTabWidget(defID ~ "TABS");

        debug (fancy)
            writeln(" initMainframe: initSongEditor.");

        initSongEditor();

        debug (fancy)
            writeln(" initMainframe: initShowEditor.");
        initShowEditor();

        debug (fancy)
            writeln(" initMainframe: initPatternEditor.");
        initPatternEditor();

        debug (fancy)
            writeln(" initMainframe: initRehearseInterface.");
        initRehearseInterface();


        createRehearseWindow();



        rehearse_in_tab = true;



        debug (fancy)
            writeln(" initMainframe: init tabs.");

        main.tabChanged = delegate(string active, string previous) {
            if (previous == defID ~ "SHOWEDITOR") {
                wks.deattachTab();
            } else if (previous == defID ~ "SONGEDITOR") {
                seq.deattachTab();
            } else if (previous == defID ~ "PATTERNEDITOR") {
                pat.deattachTab();
            } else if (previous == defID ~ "REHEARSE") {
                rehearse.deattachTab();
            }
            if (active == defID ~ "SHOWEDITOR") {
                wks.attachTab();
            } else if (active == defID ~ "SONGEDITOR") {
                seq.attachTab();
            } else if (active == defID ~ "PATTERNEDITOR") {
                pat.attachTab();
            } else if (active == defID ~ "REHEARSE") {
                rehearse.attachTab();
            }

        };

        main.addTab(show_editor, "Workbook"d);
        main.addTab(song_editor, "Sequence"d);

        patscr.contentWidget = pattern_editor;
        main.addTab(patscr, "Pattern"d);

        main.addTab(rehearse_tab, "Rehearse"d);

        main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Show Workbook..."d, null, KeyCode.F1, 0));
        actionHandlers ~= delegate() {
            main.selectTab(defID ~ "SHOWEDITOR");
            return;
        };
        main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Show Sequence..."d, null, KeyCode.F2, 0));
        actionHandlers ~= delegate() {
            main.selectTab(defID ~ "SONGEDITOR");
            return;
        };
        main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Show Pattern..."d, null, KeyCode.F3, 0));
        actionHandlers ~= delegate() {
            main.selectTab(defID ~ "PATTERNEDITOR");
            return;
        };
        main.acceleratorMap.add(
            new Action(cast(int)(zeroAction + actionHandlers.length),
            "Show Rehearse..."d, null, KeyCode.F4, 0));
        actionHandlers ~= delegate() {
            main.selectTab(defID ~ "REHEARSE");
            return;
        };


        wks.attachTab();

        main.layoutWidth = FILL_PARENT;
        main.layoutHeight = FILL_PARENT;

        window.mainWidget = main;

        window.show();
        debug (fancy)
            writeln(" initMainframe: out.");

        /*platform.instance.createWindow(
            "Song-Sketch[[sythesize]]:KeepAlive", null, WindowFlag.Resizable,
            1080, 700);*/

    }

    void cleanup() {
        pat.cleanup();
    }

    JackCallbackRoutines jack;

public:

    this(JackCallbackRoutines _jack) {

        jack = _jack;
    }

    void run(void delegate() idle) {
        initMainframe();

        main.idle = idle;

        main.setTimer(50);

        platform.instance.enterMessageLoop();

        cleanup();

    }

    void update_status(FeedbackStatus status) {
        debug (loop_playback)
            writeln("update_status", status, " loop", loop);


        rehearse.update_status(status);
        if (rehearse_in_tab == false)
        {
            rehearse2.update_status(status);
            rehearse_window.invalidate();
        }

        if (status.stopped_playing) {
            pat.clearPlayhead;
            seq.clearPlayhead;

            if (loop == LoopModus.sequence) {
                if ((loop_id >= 0) && (loop_id < workspace.sequences.length)) {
                    workspace.sequences[loop_id].doLoop(this, loop_id,
                        loop_bpm);
                }

            } else if (loop == LoopModus.pattern) {
                if ((loop_id >= 0) && (loop_id < workspace.patterns.length)) {
                    workspace.patterns[loop_id].doLoop(this, loop_id,
                        loop_bpm);
                }
            }
        } else {


            if ((status.pattern_id >= 0)
                    && (status.pattern_id < workspace.patterns.length)) {
                if (workspace.patterns[status.pattern_id] is pat.pat) {
                    pat.setPlayhead(status.beat_in_pattern);
                } else {
                    pat.clearPlayhead;
                }
            }

            bool dont_clear = false;

            if ((status.subsequence_id >= 0)
                    && (status.subsequence_id < workspace.sequences.length)) {
                if (workspace.sequences[status.subsequence_id] is seq.seq) {
                    seq.setPlayhead(status.pattern_in_subsequence);
                    dont_clear = true;
                } 
            }

            if ((status.sequence_id >= 0)
                    && (status.sequence_id < workspace.sequences.length)) {
                if (workspace.sequences[status.sequence_id] is seq.seq) {
                    seq.setPlayhead(status.pattern_in_sequence);
                } else
                    if (! dont_clear)
                        seq.clearPlayhead;
            }
        }
    }
};

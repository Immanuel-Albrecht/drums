module rehearseui;

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

/****** REHEARSER UI */

int rehearser_width = 800;
int rehearser_height = 480;
float rehearser_max_stretch = 2;

struct RehearseUI {
    UserInterface ui;
    Workspace workspace;
    Window window;
    VerticalLayout master;


    ColorDrawBuf display_image = null;
    CanvasWidget canvas;
    TextWidget seq_info;
    TextWidget subseq_info;
    TextWidget pat_info;

    TextWidget current_speed;

    int seq;
    int subseq;
    int pat;
    int bpm;
    int percentage;
    int subpercentage;

    int row;
    int subrow;


    void update_status(FeedbackStatus status) {


        seq = status.sequence_id;
        pat = status.pattern_id;
        subseq = status.subsequence_id;
        bpm = status.bpm;
        percentage = status.percentage;
        subpercentage = status.subsequence_percentage;
        row = status.pattern_in_sequence;
        subrow = status.pattern_in_subsequence;

        current_speed.text =  to!dstring("%3d%%".format(status.speed_factor));

        if ((seq >= 0) && (seq < workspace.sequences.length)) {
            auto x = workspace.sequences[seq];
            string info = x.name;

            for (auto i=info.length; i <= 22; ++i)
                info ~= " ";
            info ~= "%4d%%".format(percentage);

            seq_info.text = to!dstring(info);

            if (x.rehearsal_images[status.pattern_in_sequence] !is null) 
            {
                showImage(x.rehearsal_images[status.pattern_in_sequence]);
            } else if (x.list[status.pattern_in_sequence].rehearsal_image) {
                showImage(null);
            }
        } else 
        {
            seq_info.text = " (no sequence) "d;
        }

        if ((subseq >= 0) && (subseq < workspace.sequences.length)) {
            auto x = workspace.sequences[subseq];
            string info = x.name;
    
            for (auto i=info.length; i <= 22; ++i)
                info ~= " ";

            info ~= "%4d%%".format(subpercentage);

            subseq_info.text = to!dstring(info);

            if (x.rehearsal_images[status.pattern_in_subsequence] !is null) 
            {
                showImage(x.rehearsal_images[status.pattern_in_subsequence]);
            }else if (x.list[status.pattern_in_subsequence].rehearsal_image) {
                showImage(null);
            }

        } else 
        {
            subseq_info.text = " (no sequence) "d;
        }

        if ((pat >= 0) && (pat < workspace.patterns.length)) {
            auto x = workspace.patterns[pat];
            string info = x.name;

            for (auto i=info.length; i <= 20; ++i)
                info ~= " ";

            info ~= "%4dbpm".format(bpm);

            pat_info.text = to!dstring(info);
        } else
        {
            pat_info.text = " (no pattern) "d;
        }
        

    }

    void init(VerticalLayout l, Window w, Workspace wsp, UserInterface _ui) {
        ui = _ui;
        window = w;
        master = l;
        workspace = wsp;

        HorizontalLayout head = new HorizontalLayout();

        auto btn_toggle = new Button(null, "Toggle Window"d);
        btn_toggle.click = delegate(Widget w) {
            ui.toggleRehearserTabWindow();
            return true;
        };

        head.addChild(btn_toggle);

        head.addChild(new TextWidget(null, "Overall Speed:"d));

        current_speed = new TextWidget(null, "100%"d);
        current_speed.fontFace = pat_dip_font;
        current_speed.fontSize = cast(int) ( pat_dip_size * retina_factor );
        current_speed.fontWeight = pat_dip_weight;
        current_speed.textColor = "red";
        head.addChild(current_speed);

        auto btn_slower = new Button(null, "Slower"d);
        btn_slower.click = delegate(Widget w) {
            ui.jack.SlowerSpeed();
            return true;
        };
        head.addChild(btn_slower);
        auto btn_exact = new Button(null, "100%"d);
        btn_exact.click = delegate(Widget w) {
            ui.jack.ResetSpeed();
            return true;
        };
        head.addChild(btn_exact);

        auto btn_faster = new Button(null, "Faster"d);
        btn_faster.click = delegate(Widget w) {
            ui.jack.FasterSpeed();
            return true;
        };

        head.addChild(btn_faster);

        l.addChild(head);

        HorizontalLayout heada = new HorizontalLayout();
        HorizontalLayout headb = new HorizontalLayout();
        HorizontalLayout headc = new HorizontalLayout();

        heada.addChild(new TextWidget(null,"Song-Seq."d).minWidth(cast(int)retina_factor*85).alignment(Align.Right));
        headb.addChild(new TextWidget(null,"Riff-Seq."d).minWidth(cast(int)retina_factor*85).alignment(Align.Right));
        headc.addChild(new TextWidget(null,"Riff-Pat."d).minWidth(cast(int)retina_factor*85).alignment(Align.Right));
        auto btn_seea = new Button(null, "See"d);

        btn_seea.click = delegate(Widget w) {
            ui.showSeq(seq);
            return true;
        };

        auto btn_seeb = new Button(null, "See"d);
        
        btn_seeb.click = delegate(Widget w) {
            ui.showSeq(subseq);
            return true;
        };
        
        auto btn_seec = new Button(null, "See"d);
        
        btn_seec.click = delegate(Widget w) {
            ui.showPat(pat);
            return true;
        };

        auto btn_reha = new Button(null, "Rehearse"d);

        btn_reha.click = delegate(Widget w) {
            ui.playRehearseSequence(seq,percentage);
            return true;
        };

        auto btn_rehb = new Button(null, "Rehearse"d);
        
        btn_rehb.click = delegate(Widget w) {
            ui.playRehearseSubSequence(seq,row,percentage);
            return true;
        };
        
        auto btn_rehc = new Button(null, "Rehearse"d);
        
        btn_rehc.click = delegate(Widget w) {
            ui.playRehearsePattern(pat,seq,row,bpm,percentage,subseq,subrow,subpercentage);
            return true;
        };

        heada.addChild(btn_seea);
        headb.addChild(btn_seeb);
        headc.addChild(btn_seec);

        heada.addChild(btn_reha);
        headb.addChild(btn_rehb);
        headc.addChild(btn_rehc);


        seq_info = new TextWidget();
        seq_info.text = " (~~~)"d;
        seq_info.fontFace = pat_dip_font;
        seq_info.fontSize = cast(int) ( pat_dip_size * retina_factor );
        seq_info.fontWeight = pat_dip_weight;

        heada.addChild(seq_info);

        subseq_info = new TextWidget();
        subseq_info.text = " (~~~)"d;
        subseq_info.fontFace = pat_dip_font;
        subseq_info.fontSize = cast(int) ( pat_dip_size * retina_factor );
        subseq_info.fontWeight = pat_dip_weight;

        headb.addChild(subseq_info);

        pat_info = new TextWidget();
        pat_info.text = " (~~~)"d;
        pat_info.fontFace = pat_dip_font;
        pat_info.fontSize = cast(int) ( pat_dip_size * retina_factor );
        pat_info.fontWeight = pat_dip_weight;

        headc.addChild(pat_info);


        l.addChild(heada);
        l.addChild(headb);
        l.addChild(headc);


        l.layoutHeight(FILL_PARENT);
        l.maxHeight = SIZE_UNSPECIFIED;

        canvas = new CanvasWidget();
        canvas.layoutWidth(FILL_PARENT)
              .layoutHeight(FILL_PARENT);

        canvas.minWidth = cast(int)(rehearser_width*retina_factor);
        canvas.minHeight = cast(int)(rehearser_height*retina_factor);
        canvas.maxWidth = SIZE_UNSPECIFIED;
        canvas.maxHeight = SIZE_UNSPECIFIED;


        canvas.onDrawListener = delegate(CanvasWidget canvas, DrawBuf buf, Rect rc) {
            if (this.display_image is null)
                buf.fill(0xFFCCCC);
            else {
                buf.fill(0xFFFFFF);

                auto src_rect = Rect(0,0,display_image.width,display_image.height);
                auto stretch = min(rehearser_max_stretch,
                            (cast(float)canvas.width)/display_image.width,
                            (cast(float)canvas.height)/display_image.height);
                auto dst_rect = Rect(canvas.left,canvas.top,canvas.left+cast(int)(display_image.width*stretch),
                        cast(int)(display_image.height*stretch)+canvas.top);

	            buf.drawRescaled(dst_rect,display_image,src_rect);
            }
	    };


        l.addChild(canvas);
    }
    
    void attachTab() {
    }

    void deattachTab() {
    }

    void showImage(ColorDrawBuf img) {
        if (display_image !is img)
        {
            display_image = img;

            canvas.invalidate();
        }
    }
}

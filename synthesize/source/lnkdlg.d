module lnkdlg;

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
import std.path;

import dlangui;
import dlangui.dialogs.dialog;
import dlangui.dialogs.inputbox;
import filedlg; /** fixed version of FileDialog */

class LinkDialog : Dialog {

    EditLine data;


    string link;

    void delegate() okay;

    this(Window parent) {
        super(UIString.fromRaw("Choose External Link..."d), parent, DialogFlag.Modal| DialogFlag.Resizable,
                600,80);
        okay = delegate void() {
            return;
        };
    }


    override void initialize() {

        VerticalLayout lines = new VerticalLayout();

        lines.layoutWidth = FILL_PARENT;

        HorizontalLayout l = new HorizontalLayout();


        l.addChild(new TextWidget(null, "Link target:"d));
        data = new EditLine();
        data.text = to!dstring(link);
        data.layoutWidth = FILL_PARENT;


        l.addChild(data);

        auto chooser = new Button(null,"..."d);
        chooser.click = delegate(Widget w) {

                auto dlg = new FileDialog(
                    UIString.fromRaw("Select target file..."d), window,
                    null, FileDialogFlag.Open | FileDialogFlag.FileMustExist);
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_ALL_FILES",
                    "All files (*)"d), "*"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_MP3_FILES",
                    "*.mp3"d), "*.mp3"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_WAV_FILES",
                    "*.wav"d), "*.wav"));


                dlg.dialogResult = delegate(Dialog _dlg, const Action result) {
                    if (result.id == ACTION_OPEN.id) {
                        string filepath = relativePath(result.stringParam);

                        data.text = to!dstring(filepath);
                        link = filepath;

                    }
                };
                dlg.show();

            return true;
        };

        l.addChild(chooser);

        l.layoutWidth = FILL_PARENT;

        lines.addChild(l);


        auto btns = new HorizontalLayout();

        auto preview = new Button(null,"Open link target..."d);
        preview.click = delegate(Widget w) {
            link = to!string(data.text);

            platform.openURL(link);

            return true;
        };

        btns.addChild(preview);


        btns.addChild(new TextWidget(null, " "d).layoutWidth(FILL_PARENT));

        auto cancel = new Button(null, "Cancel"d);
        cancel.click = delegate(Widget w) {

            this.close(null);

            return true;
        };

        btns.addChild(cancel);

        auto ok = new Button(null, "Okay"d);
        ok.click = delegate(Widget w) {

            link = to!string(data.text);

            this.close(null);

            okay();

            return true;
        };

        btns.addChild(ok);



        btns.layoutWidth = FILL_PARENT;
        lines.addChild(btns);

        addChild(lines);

    }
};

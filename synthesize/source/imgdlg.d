module imgdlg;

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

class ImageDialog : Dialog {

    CanvasWidget canvas;
    ColorDrawBuf display_image;
    EditLine data;


    string img_path;

    void delegate() okay;

    this(Window parent) {
        super(UIString("Choose Image Reference..."d), parent, DialogFlag.Modal| DialogFlag.Resizable);
        okay = delegate void() {
            return;
        };
    }

    void update_preview() {
            try {
                display_image = loadImage(img_path);
            } catch(Throwable o) {
                display_image = null;
            }
        }

    override void initialize() {
        minWidth(600).minHeight(400);
        
        VerticalLayout lines = new VerticalLayout();

        lines.layoutHeight = FILL_PARENT;
        lines.layoutWidth = FILL_PARENT;

        HorizontalLayout l = new HorizontalLayout();


        l.addChild(new TextWidget(null, "Image location:"d));
        data = new EditLine();
        data.text = to!dstring(img_path);
        data.layoutWidth = FILL_PARENT;


        data.keyEvent = delegate(Widget src, KeyEvent evt) {

            img_path = to!string(data.text);

            update_preview();

            canvas.invalidate();
    

            return false;
        };


        l.addChild(data);

        auto chooser = new Button(null,"..."d);
        chooser.click = delegate(Widget w) {
        
                auto dlg = new FileDialog(
                    UIString("Select image file..."d), window,
                    null, FileDialogFlag.Open | FileDialogFlag.FileMustExist);
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_JPG_FILES",
                    "*.jpg"d), "*.jpg"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_PNG_FILES",
                    "*.png"d), "*.png"));
                dlg.addFilter(
                    FileFilterEntry(UIString("FILTER_ALL_FILES",
                    "All files (*)"d), "*"));

                
                dlg.dialogResult = delegate(Dialog _dlg, const Action result) {
                    if (result.id == ACTION_OPEN.id) {
                        string filepath = relativePath(result.stringParam);

                        data.text = to!dstring(filepath);
                        img_path = filepath;

                        update_preview();
                        canvas.invalidate();

                    }
                };
                dlg.show();

            return true;
        };

        l.addChild(chooser);

        l.layoutWidth = FILL_PARENT;

        lines.addChild(l);

        canvas = new CanvasWidget();
        canvas.layoutWidth = FILL_PARENT;
        canvas.layoutHeight = FILL_PARENT;
        canvas.maxWidth = SIZE_UNSPECIFIED;
        canvas.maxHeight = SIZE_UNSPECIFIED;
        canvas.minWidth = 150;
        canvas.minHeight = 150;


        canvas.onDrawListener = delegate(CanvasWidget canvas, DrawBuf buf, Rect rc) {
            if (this.display_image is null)
                buf.fill(0xFFCCCC);
            else {
                buf.fill(0xFFFFFF);

                auto src_rect = Rect(0,0,display_image.width,display_image.height);
                auto stretch = min(
                            (cast(float)canvas.width)/display_image.width,
                            (cast(float)canvas.height)/display_image.height);
                auto dst_rect = Rect(canvas.left,canvas.top,canvas.left+cast(int)(display_image.width*stretch),
                        cast(int)(display_image.height*stretch)+canvas.top);

	            buf.drawRescaled(dst_rect,display_image,src_rect);
            }
	    };
        
        lines.addChild(canvas);

        update_preview();


        auto btns = new HorizontalLayout();


        btns.addChild(new TextWidget(null, " "d).layoutWidth(FILL_PARENT));
        
        auto cancel = new Button(null, "Cancel"d);
        cancel.click = delegate(Widget w) {

            this.close(null);

            return true;
        };

        btns.addChild(cancel);
        
        auto ok = new Button(null, "Okay"d);
        ok.click = delegate(Widget w) {
            
            img_path = to!string(data.text);

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

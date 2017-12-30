module sync;

import std.traits;
import jack.client;
import std.stdio;

//debug = sync;
//debug = syncAll;

/** this module contains helpers for synchronizing the jack-callback with the user interface */

class synchronizer(T) {
    T* target; //<! jack variable that shall be changed via UI
    T copy; //<! keep a copy of target
    bool changed; //<! whether copy has been changed

    string name;

    this(T)(T* object, string desc) {
        target = object;
        static if (hasMember!(T, "dup"))
            copy = (*target).dup;
        else
            copy = (*target);
        changed = false;
        name = desc;
    }

    /** update target value; assume that we have write mutex on target. */
    void update_target() {
        if (changed) {
            debug (sync)
                writeln("SYNC: ", name, " <- ", copy);
            *target = copy;
            changed = false;
        } else if (*target != copy) {
            static if (hasMember!(T, "dup"))
                copy = (*target).dup;
            else
                copy = (*target);
            debug (syncAll)
                writeln("SYNC: ", name, " dup'in ", *target);
        }
    }

    /** read value */
    T get() {
        return copy;
    }

    /** write value */
    void set(T x) {
        if (x != copy) {
            copy = x;
            changed = true;
            debug (sync)
                writeln("SYNC: ", name, " set ", x);
        }
    }
}

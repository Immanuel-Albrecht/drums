module drumkit;
/* this file contains the drum kit configuration */
import pattern;
import config;
import std.stdio;
import std.string;

struct drum_kit_config {
    ubyte channel;
    string name;
    string[] shorthands;
};

immutable drum_kit_config[] drumkit = cast(immutable)[
drum_kit_config( 35 , "kick_a" ,["a"]),
drum_kit_config( 36 , "kick_b" ,["b"]),
drum_kit_config( 37 , "snare_sidestick" ,["x"]),
drum_kit_config( 38 , "snare_ord" ,["s"]),
drum_kit_config( 39 , "snare_prs" ,["sp"]),
drum_kit_config( 40 , "snare_rms" ,["sr"]),
drum_kit_config( 42 , "hihat_cls" ,["c"]),
drum_kit_config( 41 , "floor_lo" ,["fl"]),
drum_kit_config( 43 , "floor_hi" ,["f"]),
drum_kit_config( 44 , "hihat_ped" ,["p"]),
drum_kit_config( 45 , "tom_lo" ,["tl"]),
drum_kit_config( 46 , "hihat_opn" ,["o"]),
drum_kit_config( 47 , "tom_mid" ,["t"]),
drum_kit_config( 48 , "tom_hi" ,["th"]),
drum_kit_config( 49 , "crash1" ,["cr"]),
drum_kit_config( 51 , "ride1" ,["r"]),
drum_kit_config( 52 , "china" ,["ch"]),
drum_kit_config( 53 , "ride_bel" ,["b","rb"]),
drum_kit_config( 55 , "splash" ,["sp"]),
drum_kit_config( 57 , "crash2" ,["cr"]),
drum_kit_config( 59 , "ride2" ,["R"]),
    ];

int get_drum_name_or_shorthand_index(string x) {
    string xL = x.toLower();
    foreach (idx, d; drumkit) {
        if (d.name.toLower() == xL) {
            return cast(int)idx;
        }
        foreach (sh; d.shorthands) {
            if (sh == x)
                return cast(int)idx;
        }
    }
    return -1;
}

struct special_action_config {
    int action;
    alias channel = action;

    string name;
    string[] shorthands;
}

enum special_actions {
    next = -100000,
    pause,
    pause2,
    pause4,
    pause8,
    pause16,
    pause6,
    pause12,
    pause24,
    default_strength,
    increase_strength,
    decrease_strength,
    set_strength1,
    set_strength2,
    set_strength3,
    set_strength4,
    set_strength5,
    set_strength6,
    set_strength7,
    set_strength8,
    set_strength9,
    set_strengthA,
    set_strengthB,
    set_strengthC,
    set_strength0
};

immutable special_action_config[] special_markers = cast(immutable)[
    special_action_config(special_actions.next, "next", ["/"]),
    special_action_config(special_actions.pause, "pause", ["-"]),
    special_action_config(special_actions.pause2, "pause2x", ["="]),
    special_action_config(special_actions.pause4, "pause4x", ["//"]),
    special_action_config(special_actions.pause6, "pause6x", ["."]),
    special_action_config(special_actions.pause12, "pause12x", [":"]),
    special_action_config(special_actions.pause4, "pause8x", ["=="]),
    special_action_config(special_actions.pause4, "pause16x", ["|"]),
    special_action_config(special_actions.default_strength,
    "default strength", ["@"]),
    special_action_config(special_actions.increase_strength,
    "increase strength", ["+", "@+"]),
    special_action_config(special_actions.decrease_strength,
    "decrease strength", ["@-"]),
    special_action_config(special_actions.set_strength0, "set strength 0",
    ["@0"]),
    special_action_config(special_actions.set_strength1, "set strength 1",
    ["@1"]),
    special_action_config(special_actions.set_strength2, "set strength 2",
    ["@2"]),
    special_action_config(special_actions.set_strength3, "set strength 3",
    ["@3"]),
    special_action_config(special_actions.set_strength4, "set strength 4",
    ["@4"]),
    special_action_config(special_actions.set_strength5, "set strength 5",
    ["@5"]),
    special_action_config(special_actions.set_strength6, "set strength 6",
    ["@6"]),
    special_action_config(special_actions.set_strength7, "set strength 7",
    ["@7"]),
    special_action_config(special_actions.set_strength8, "set strength 8",
    ["@8"]),
    special_action_config(special_actions.set_strength9, "set strength 9",
    ["@9"]),
    special_action_config(special_actions.set_strengthA, "set strength 10",
    ["@A"]),
    special_action_config(special_actions.set_strengthB, "set strength 11",
    ["@B"]),
    special_action_config(special_actions.set_strengthC, "set strength 12",
    ["@C"]),];

PatternHit[][] pattern_from_string(string s) {
    PatternHit[][] per_beat;

    int hit_strength = default_hit_strength;
    /* check for pattern longest match. */

    /* intermediate structures */
    static bool initialized = false;

    static int[string] pattern_action;
    static string[] pattern_list;

    if (!initialized) {
        initialized = true;
        foreach (drum; drumkit) {
            pattern_list ~= drum.name;
            pattern_action[drum.name] = drum.channel;
            foreach (symbol; drum.shorthands) {
                pattern_list ~= symbol;
                pattern_action[symbol] = drum.channel;
            }
        }
        foreach (marker; special_markers) {
            pattern_list ~= marker.name;
            pattern_action[marker.name] = marker.channel;
            foreach (symbol; marker.shorthands) {
                pattern_list ~= symbol;
                pattern_action[symbol] = marker.channel;
            }
        }
    }

    PatternHit[] current;

    int[] check_all_patterns;
    check_all_patterns.length = pattern_list.length;

    void reset_matching() {
        check_all_patterns[0 .. $] = 0;
    }

    bool has_previous_matching() {
        foreach (p; check_all_patterns) {
            if (p > 0)
                return true;
        }
        return false;
    }

    ulong best_match() {
        foreach (idx, p; check_all_patterns) {
            if (p == pattern_list[idx].length)
                return idx;
        }
        foreach (idx, p; check_all_patterns) {
            if (p > 0)
                return idx;
        }
        return 0;
    }

    bool continue_matching(char c) {
        bool has_a_match = false;

        foreach (idx, s; pattern_list) {
            if (check_all_patterns[idx] < 0)
                continue;
            if ((s.length <= check_all_patterns[idx])
                    || (s[check_all_patterns[idx]] != c)) {
                check_all_patterns[idx] = -1;
                continue;
            }
            check_all_patterns[idx] += 1;
            has_a_match = true;
        }

        return has_a_match;
    }

    void carry_matching_action(ulong best) {
        auto action = pattern_action[pattern_list[cast(int)best]];
        writeln("act:", action);
        if (action > 0) {
            current ~= PatternHit(cast(ubyte)action, hit_strength);
        } else {
            alias A = special_actions;
            switch (action) {
            case A.next:
                per_beat ~= current.dup;
                current.length = 0;
                break;
            case A.pause:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                }
                per_beat ~= cast(PatternHit[])[];
                break;
            case A.pause2:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                }
                per_beat ~= [[], []];
                break;
            case A.pause4:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                } else
                    per_beat ~= cast(PatternHit[])[];
                per_beat ~= [[], [], []];
                break;
            case A.pause6:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                } else
                    per_beat ~= cast(PatternHit[])[];
                per_beat ~= [[], [], [], [], []];
                break;
            case A.pause8:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                } else
                    per_beat ~= cast(PatternHit[])[];
                per_beat ~= [[], [], [], [], [], [], []];
                break;
            case A.pause12:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                } else
                    per_beat ~= cast(PatternHit[])[];
                per_beat ~= [[], [], [], [], [], [], [], [], [], [],
                    []];
                break;
            case A.pause16:
                if (current.length > 0) {
                    per_beat ~= current.dup;
                    current.length = 0;
                } else
                    per_beat ~= cast(PatternHit[])[];
                per_beat ~= [[], [], [], [], [], [], [], [],
                    [], [], [], [], [], [], []];
                break;
            case A.default_strength:
                hit_strength = default_hit_strength;
                break;
            case A.increase_strength:
                hit_strength += increase_strength;
                break;
            case A.decrease_strength:
                hit_strength -= increase_strength;
                break;
            case A.set_strength1: .. case A.set_strengthC:
                hit_strength = (
                    default_hit_strength * (action - A.set_strength1 + 1)) / 10;
                break;
            case A.set_strength0:
                hit_strength = 0;
                break;
            default:
                writeln("ERROR: PATTERN ACTION ", action, " UNIMPLEMENTED!");
                break;
            }
        }
    }

    foreach (c; s) {
        bool has_matching = has_previous_matching();
        ulong which;
        if (has_matching)
            which = best_match();

        if (continue_matching(c))
            continue;

        if (has_matching)
            carry_matching_action(which);
        reset_matching();
        continue_matching(c);
    }

    if (has_previous_matching)
        carry_matching_action(best_match);

    if (current.length > 0)
        per_beat ~= current;

    return per_beat;
}

unittest {
    import std.stdio;

    writeln("Demangle pattern test:");
    writeln(pattern_from_string("hsa/b//hsa/b/crash(top)-b--|b|bb|b"));
}

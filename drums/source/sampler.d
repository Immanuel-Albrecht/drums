module sampler;

import std.stdio;
import std.math;
import std.regex;
import std.getopt;
import std.bitmanip;
import std.typecons;
import std.conv;
import std.string;
import std.range;
import std.algorithm;

import fakerandom;
import bisection;

immutable auto queue_length = 16; ///< allows for max. of 8 hits to be queued up (TODO)

immutable auto channels = 2; ///< stereo :)

alias sample = real; ///< we want to use floating point ops here
alias wave_sample = float; ///< more sane format for storing waves
alias frame = wave_sample[channels]; ///< one frame
alias wave = frame[]; ///< a wave of stereo frames

//debug = interpolation;
//debug = printEvents;
//debug = writeData;
//debug = pipelines;

immutable auto max_velocity = 127; ///< maximal velocity for midi

enum playback_state {
    Playing, ///< keep playing the wave
    CancelRequest, ///< signal that we would like to stop playing the wave at next sign change
    CancelledLeft, ///< signal that we would like to stop playing, and that the left channel has been stopped
    CancelledRight, ///< signal that we would like to stop playing, and that the right channel has been stopped
    Cancelled ///< all playback of this wave has been stopped
}

struct PlaybackInfo {
    int i; ///< which wave is played back?
    int current_offset; ///< how much into the wave are we? (may be negative in case of before a hit)
    sample gain; ///< adjust-gain for the hit
    playback_state state; ///< stop this playback?
    int cancel_left; ///< how many frames to play until we can cancel left?
    int cancel_right; ///< how many frames to play until we can cancel right?
}

alias indexed_gain = Tuple!(int, "i", sample, "gain");
alias velocity_realization = indexed_gain[];

enum interpolation_mode {
    centered,
    left,
    right
}

class DrumSampler {
    char[] name; ///< name of this drum, helps debugging output

    wave[] samples;
    velocity_realization[max_velocity + 1] vel;

    int[][][] sgn_test_cache; // sgn_test_cache[sample_id][channel_id] _=_ list of offsets where the sign swaps

    int drum_pitch = 64; ///< instrument pitch
    int[] damp_pitches = []; ///< pitches, where on hit, this drum is dampened; assume_sorted.
    std.range.SortedRange!(int[], "a < b") damp_pitches_set; ///< as assumeSorted
    int timing_pitch = 63; ///< control pitch to set the timing randomness parameter
    int stability_pitch = 62; ///< control pitch to set the velocity randomness parameter

    bool skip = true; ///< skip the write routine, because there is nothing to do in the near future
    bool damp_requested = false; ///< count the damping down in skip mode

    frame gain = [1., 1.]; ///< trim-gain for the instrument
    PlaybackInfo[] playing; ///< keep track of the playing samples right now
    PlaybackInfo[] still_playing; ///< avoid memory clumsification by reusing these arrays
    int[queue_length] damp_in_frames = -1; ///< damp all after some time

    int[queue_length] hit_in_frames = -1; ///< hit after some time
    int[queue_length] requested_velocity = 64; ///< velocity of requested hit

    sample interpolation_exponent = 1.61803398875; ///< 1=linear, 2=quadratic, etc.
    interpolation_mode interpolation_type = interpolation_mode.centered;
    bool autodamp = true; ///< damp all current hits on new hit
    bool userdamp = false; ///< false-> ignore damp midi commands from user on drum pitch (good for drums, bad for cymbals)

    int current_stability = 64; ///< default value for velocity-accuracy
    sample default_stability_sigma = 1.4; ///< ~ sqrt(2);  2dB default variance for stability at level 64

    int current_timing = 64; ///< default value for timing-accuracy
    sample default_timing_sigma = 10.; ///<=sqrt(100); in frames, default variance for hits at level 64
    int current_delay = 96; ///< length of delay for any hit drum
    int current_autodamp_additional_delay = 0; ///< length of additional delay for auto damping
    int current_userdamp_additional_delay = 0; ///< length of additional delay for user requested damping
    int[int] current_damp_pitch_additional_delay; ///< length of additional delay when given pitch hit requests damping

    sample sublevel_gain = .98; ///< for single-sample drums


    /// request a damp all event in the future
    void requestDampAll(int frames_from_now) {
        if (frames_from_now < 0)
            frames_from_now = 0; /// do not damp in the past.

        for (auto i = 0; i < queue_length; ++i) {
            if (damp_in_frames[i] < 0) {
                damp_in_frames[i] = frames_from_now;

                debug (pipelines)
                    writeln(name, ": damp all in ", frames_from_now);

                damp_requested = true;
                return;
            }
        }

        writeln(name, ": WARNING: damping queue overflow [",damp_requested,"]");
    }

    /** tell us where we may cancel the playback of some sample channel */
    int get_next_cancel_point(int sample, int channel, int now) {
        auto idx = bisect(sgn_test_cache[sample][channel], now);

        if (idx >= sgn_test_cache[sample][channel].length)
            return cast(int)samples[sample].length;

        if (sgn_test_cache[sample][channel][cast(uint)idx] > now)
            return sgn_test_cache[sample][channel][cast(uint)idx];
        ++idx;
        if (idx >= sgn_test_cache[sample][channel].length)
            return cast(int)samples[sample].length;
        return sgn_test_cache[sample][channel][cast(uint)idx];
    }

    /// damp all currently playing voices
    void dampAll() {
        for (int idx = 0; idx < playing.length; ++idx) {
            if (playing[idx].state == playback_state.Playing) {
                playing[idx].state = playback_state.CancelRequest;

                playing[idx].cancel_left = get_next_cancel_point(playing[idx].i, 0, playing[idx].current_offset)
                    - playing[idx].current_offset;
                playing[idx].cancel_right = get_next_cancel_point(playing[idx].i, 1, playing[idx].current_offset)
                    - playing[idx].current_offset;
            }
                
        }
        debug (pipelines)
            writeln(name, ": damped all.");
    }

    void requestHit(int offset, int velocity) {
        if (offset < 0) {
            offset = 0;
        }

        for (auto i = 0; i < queue_length; ++i) {
            if (hit_in_frames[i] >= 0)
                continue;

            requested_velocity[i] = velocity;
            hit_in_frames[i] = offset;

            debug (pipelines)
                writeln(name, ": hit at ", velocity, " in ", offset);

            skip = false;

            return;
        }

        writeln(name, ": WARNING: hit queue overflow");
    }

    void performHit(int req_vel) {

        sample regain = exp2(
            standardNormal() * (
            default_stability_sigma * (current_stability - 1) / 63.) / 10.);
        for (auto i = 0; i< vel[req_vel].length; ++i) {
            PlaybackInfo info;
            info.i = vel[req_vel][i].i;
            info.gain = vel[req_vel][i].gain * regain;
            info.current_offset = 0;
            info.state = playback_state.Playing;

            playing ~= info;
        }
        debug (pipelines)
            writeln(name, ": hit at ", req_vel,
                " instability gain ", regain, ".");
    }

    /// generate a standardized hit exactly on time, may be used to adjust delays between drums
    void calibration_tick(int calibration_velocity) {
        debug (printEvents)
            writeln(name, " calibration event.");

        if (autodamp) {
            requestDampAll(current_delay + current_autodamp_additional_delay);
        }

        requestHit(current_delay, calibration_velocity);
    }

    /// process a hit MIDI event
    void hit(int pitch, int velocity) {
        if (pitch == drum_pitch) {
            if ((velocity <= 0) || (velocity > max_velocity))
                return;
            debug (printEvents)
                writeln(name, " hit at ", velocity);

            int offset = current_delay + cast(int)round(
                standardNormal() * default_timing_sigma * (current_timing - 1.) / 63.);

            if (offset < 0)
                offset = 0;

            if (autodamp) {
                requestDampAll(offset + current_autodamp_additional_delay);
            }

            requestHit(offset, velocity);

        } else if (damp_pitches_set.contains(pitch)) {
            debug (printEvents)
                writeln(name, " dampened via ", pitch);

            requestDampAll(
                current_delay + current_userdamp_additional_delay + current_damp_pitch_additional_delay.get(pitch,
                0));
        }

        if (pitch == timing_pitch) {
            debug (printEvents)
                writeln(name, " new timing-accuracy level ", velocity);

            current_timing = velocity;
        }

        if (pitch == stability_pitch) {
            debug (printEvents)
                writeln(name, " new velocity-accuracy level ", velocity);

            current_stability = velocity;
        }
    }

    /// process a damp MIDI event
    void damp(int pitch, int velocity) {
        if ((pitch == drum_pitch) && userdamp) {
            debug (printEvents)
                writeln(name, " dampened.");

            requestDampAll(current_delay + current_userdamp_additional_delay);
        }
    }

    /* quick feedback whether we can skip the write call */
    bool may_skip() {
        return skip && (!damp_requested);
    }

    void write(float* left, float* right, int nframes) {
        if (nframes < 0)
            return;
        if (skip) {

            if (damp_requested) {
                bool damp_next = false;
                for (auto i = 0; i < queue_length; ++i)
                    if (damp_in_frames[i] >= 0) {
                        damp_in_frames[i] -= nframes;
                        if (damp_in_frames[i] >= 0)
                            damp_next = true;
                    }
                damp_requested = damp_next;
            }
            return;
        }

        debug (writeData)
            writeln(name, ": Writing ", nframes, " frames. ");

        bool skip_next;
        bool damp_next;

        while (nframes > 0) {
            --nframes;

            skip_next = true;
            damp_next = false;
            

            /// process damp events in the future
            for (auto i = 0; i < queue_length; ++i)
                if (damp_in_frames[i] >= 0) {
                    if (damp_in_frames[i] == 0) {
                        dampAll();
                    } else {
                        damp_next = true;
                    }
                    --damp_in_frames[i];
                }

            ///process hit events in the future
            for (auto i = 0; i < queue_length; ++i)
                if (hit_in_frames[i] >= 0) {
                    if (hit_in_frames[i] == 0) {
                        performHit(requested_velocity[i]);
                    } else {
                        skip_next = false;
                    }
                    --hit_in_frames[i];
                }

            /// add up all voices contributions
            for (int idx = 0; idx < playing.length; ++idx) {
                //auto info = playing[idx];
                if (playing[idx].state == playback_state.Cancelled)
                    continue;

                if (playing[idx].state == playback_state.Playing) {
                    if ((playing[idx].current_offset > 0)
                            && (playing[idx].current_offset < samples[playing[idx].i].length)) {
                        *left += playing[idx].gain * gain[0] * samples[playing[idx].i][
                            playing[idx].current_offset][0];
                        *right += playing[idx].gain * gain[1] * samples[playing[idx].i][
                            playing[idx].current_offset][1];
                    } /** TODO: MAKE THE CANCEL REQUEST THING ROLL OFF MORE GRACEFULLY **/
                } else if (playing[idx].state == playback_state.CancelRequest) {
                    playing[idx].cancel_left -= 1;
                    playing[idx].cancel_right -= 1;
                    if (playing[idx].cancel_left <= 0) {
                        playing[idx].state = playback_state.CancelledLeft;
                        if (playing[idx].cancel_right <= 0) {
                            playing[idx].state = playback_state.Cancelled;
                        } else {
                        *right += playing[idx].gain * gain[1] * samples[playing[idx].i][
                            playing[idx].current_offset][1];
                        }
                    } else
                    if (playing[idx].cancel_right <= 0) {
                        playing[idx].state = playback_state.CancelledRight;
                        *left += playing[idx].gain * gain[0] * samples[playing[idx].i][
                            playing[idx].current_offset][0];
                    } else {
                        *left += playing[idx].gain * gain[0] * samples[playing[idx].i][
                            playing[idx].current_offset][0];
                        *right += playing[idx].gain * gain[1] * samples[playing[idx].i][
                            playing[idx].current_offset][1];
                    }
                } else if (playing[idx].state == playback_state.CancelledLeft) {
                    playing[idx].cancel_right -= 1;
                    if (playing[idx].cancel_right <= 0) {
                        playing[idx].state = playback_state.Cancelled;
                    } else {
                    *right += playing[idx].gain * gain[1] * samples[playing[idx].i][
                        playing[idx].current_offset][1];
                    }
                
                } else if (playing[idx].state == playback_state.CancelledRight) {
                    playing[idx].cancel_left -= 1;
                    if (playing[idx].cancel_left <= 0) {
                        playing[idx].state = playback_state.Cancelled;
                    } else {
                        *left += playing[idx].gain * gain[0] * samples[playing[idx].i][
                            playing[idx].current_offset][0];
                    }
                }

                playing[idx].current_offset++;

                //playing[idx] = info;
            }

            left++;
            right++;
        }

        /// filter out the finished voices

        /** TODO: DO A MORE SANE THING HERE, LIKE MOVING THINGS IN playing[].. */
        still_playing.length = 0;
        for (auto i=0;i< playing.length; ++i)
        {
        //foreach (info; playing) {
            if (playing[i].state == playback_state.Playing) {
                if (playing[i].current_offset < samples[playing[i].i].length) {
                    still_playing ~= playing[i];
                    skip_next = false;
                }
            }
        }

        debug (writeData) {
            writeln(playing);
            writeln(name, ": Still Playing: ",
                still_playing.length, "/", playing.length);
        }

        auto swap = playing;

        playing = still_playing;
        still_playing = swap;

        skip = skip_next;
        damp_requested = damp_next;
    }

    void calculate_interpolation() {
        if (samples.length == 0)
            return; /// do not have to configure anything....

        if (samples.length == 1) {
            /// only one sample: interpolate using a constant factor
            sample g = 1.;
            for (int i = max_velocity; i > 0; --i) {
                vel[i] ~= [indexed_gain(0, g)];
                g *= sublevel_gain;
            }
            return;
        }

        /// calculate interpolation data
        for (int i = 1; i <= max_velocity; ++i) {
            sample position = (cast(sample)(i - 1) * (samples.length - 1)) / (
                cast(sample)max_velocity - 1);
            int lo = cast(int)floor(position);
            int hi = cast(int)ceil(position);
            if (lo == hi) {
                vel[i] = [indexed_gain(lo, 1.)];
            } else {
                if (interpolation_type == interpolation_mode.centered) {
                    /// centered interpolation
                    sample fraction = position - lo - .5;

                    sample upper = (.5 + fraction);
                    sample lower = (.5 - fraction);

                    upper = exp(log(upper) * interpolation_exponent);
                    lower = exp(log(lower) * interpolation_exponent);

                    sample u = upper / (upper + lower);
                    sample l = lower / (upper + lower);

                    vel[i] = [indexed_gain(lo, l), indexed_gain(hi,
                        u)];
                } else if (interpolation_type == interpolation_mode.left) {
                    /// left-side interpolation
                    sample fraction = exp(
                        log(position - lo) * interpolation_exponent);

                    sample u = 1. - fraction;
                    sample l = fraction;

                    vel[i] = [indexed_gain(lo, l), indexed_gain(hi,
                        u)];

                } else if (interpolation_type == interpolation_mode.right) {
                    /// left-side interpolation
                    sample fraction = exp(
                        log(hi - position) * interpolation_exponent);

                    sample u = fraction;
                    sample l = 1. - fraction;

                    vel[i] = [indexed_gain(lo, l), indexed_gain(hi,
                        u)];

                }

            }
        }

        debug (interpolation) {

            writeln(name, ": Velocity-Gain-Indexes:");
            for (int i = 0; i < vel.length; ++i) {
                writeln(i, " ", vel[i]);
            }
        }

    }

    /// create a new drum sampler object from a given config..
    this(string config_filename) {
        /*
        CONFIGURATION FILE FORMAT:

        All lines not matching a pattern are ignored/regarded as comment.

        Config details:
           NAME $name
                __ sets the name of this drum
           DRUM $pitch
                __ sets the MIDI pitch where the drum listens to hits
           TIME $pitch
                __ sets the MIDI pitch where the drum listens to timing-accuracy hints
           VELOCITY $pitch
                __ sets the MIDI pitch where the drum listens to velocity-accuracy hints
           DAMP $pitch
                __ adds a MIDI pitch where the drum listens to hits in order to damp itself
           SET USERDAMP
                __ respond to damp-hits on drum pitch
           UNSET USERDAMP
                __ do not respond to damp-hits on drum pitch
           BALANCE $dB
                __ left-right balance, left channel is enhanced by -$dB, 
                                      right channel is enhanced by +$dB.
           GAIN $dB
                __ trim gain
           DELAY $frames
                __ set the delay for the drum (default: 96 frames)
           AUTO DAMP DELAY $frames
                __ set the additional delay for damping on another drum hit
           USER DAMP DELAY $frames
                __ set the additional delay for damping requests by the user (other mute group drum hits)
           DRUM $pitch DAMP DELAY $frames
                __ set the additional delay for damping when the drum $pitch is hit.
           TIME VARIANCE $frames
                __ set the variance for the default timing-accuracy (default: 100 frames)
           VELOCITY VARIANCE $dB
                __ set the variance for the default velocity-accuracy (default: 2 dB)
           ADJUST $frames
                __ add $frame zero frames to the front of the last loaded sample, or
                   if $frame < 0, remove $frames from the front of the last loaded sample 
           RAW $sl_file_name
                __ load the given raw sample file
        
        */

        sample balance = 0.; ///< -1. == DAMP RIGHT CHANNEL, +1. == DAMP LEFT CHANNEL
        sample gainDB = 0.; ///< gain level.

        auto f = config_filename.File;
        foreach (line; f.byLine) {
            auto m_name = match(line, regex(`^\s*NAME(\s+(.*))?`));

            if (!m_name.empty) {
                if (m_name.captures.length > 2) {
                    name = m_name.captures[2].dup;
                    writeln("     +-- name = \"", name, "\"");
                }
            }

            auto m_raw = match(line, regex(`^\s*RAW(\s+(.*))?`));

            if (!m_raw.empty) {
                if (m_raw.captures.length > 2) {
                    wave W = truncate_silence(readSL(m_raw.captures[2]));
                    writeln("     +-- sample = \"",
                        m_raw.captures[2], "\" : ", W.length, " frames.");
                    samples ~= W;
                    sgn_test_cache ~= sgn_test_wave(W);
                }
            }

            auto m_adjust = match(line, regex(`^\s*ADJUST(\s+(.*))?`));

            if (!m_adjust.empty) {
                if (m_adjust.captures.length > 2) {
                    if (isInt(m_adjust.captures[2])) {
                        int adjustment = to!int(m_adjust.captures[2]);
                        writeln("     +-- adjust by ", adjustment,
                            " frames");
                        if (samples.length > 0) {
                            auto W = samples[samples.length - 1];
                            if (adjustment < 0) {
                                samples[samples.length - 1] = W[(-adjustment) .. $];
                            } else if (adjustment > 0) {
                                samples[samples.length - 1] = new frame[adjustment] ~ W;
                            }
                        }
                    }
                }
            }

            auto m_drum = match(line, regex(`^\s*DRUM(\s+(.*))?`));

            if (!m_drum.empty) {
                if (m_drum.captures.length > 2) {
                    if (isInt(m_drum.captures[2])) {
                        drum_pitch = to!int(m_drum.captures[2]);
                        writeln("     +-- drum pitch = ", drum_pitch);
                    }
                }
            }

            auto m_time = match(line, regex(`^\s*TIME(\s+(.*))?`));

            if (!m_time.empty) {
                if (m_time.captures.length > 2) {
                    if (isInt(m_time.captures[2])) {
                        timing_pitch = to!int(m_time.captures[2]);
                        writeln("     +-- timing-accuracy pitch = ",
                            timing_pitch);
                    }
                }
            }

            auto m_velocity = match(line, regex(`^\s*VELOCITY(\s+(.*))?`));

            if (!m_velocity.empty) {
                if (m_velocity.captures.length > 2) {
                    if (isInt(m_velocity.captures[2])) {
                        stability_pitch = to!int(m_velocity.captures[2]);
                        writeln("     +-- velocity-accuracy pitch = ",
                            stability_pitch);
                    }
                }
            }

            auto m_damp = match(line, regex(`^\s*DAMP(\s+(.*))?`));

            if (!m_damp.empty) {
                if (m_damp.captures.length > 2) {
                    if (isInt(m_damp.captures[2])) {
                        int pitch = to!int(m_damp.captures[2]);
                        writeln("     +-- damping pitch = ", pitch);
                        damp_pitches ~= pitch;
                    }
                }
            }
            auto m_set_userdamp = match(line,
                regex(`^\s*SET\s+USERDAMP(\s+(.*))?`));
            if (!m_set_userdamp.empty) {
                userdamp = true;
                writeln("     +-- respond to drum pitch damp events");
            }

            auto m_unset_userdamp = match(line,
                regex(`^\s*UNSET\s+USERDAMP(\s+(.*))?`));
            if (!m_unset_userdamp.empty) {
                userdamp = false;
                writeln("     +-- ignore drum pitch damp events");
            }
            auto m_set_autodamp = match(line,
                regex(`^\s*SET\s+AUTODAMP(\s+(.*))?`));
            if (!m_set_autodamp.empty) {
                autodamp = true;
                writeln("     +-- damp on drum hit");
            }

            auto m_unset_autodamp = match(line,
                regex(`^\s*UNSET\s+AUTODAMP(\s+(.*))?`));
            if (!m_unset_autodamp.empty) {
                autodamp = false;
                writeln("     +-- don't damp on drum hit");
            }

            auto m_balance = match(line, regex(`^\s*BALANCE(\s+(.*))?`));

            if (!m_balance.empty) {
                if (m_balance.captures.length > 2) {
                    if (isSample(m_balance.captures[2])) {
                        balance = to!sample(m_balance.captures[2]);
                        writeln("     +-- balance = ",
                            abs(balance), (balance < 0.) ? "dB LEFT" : "dB RIGHT");
                    }
                }
            }

            auto m_gain = match(line, regex(`^\s*BALANCE(\s+(.*))?`));

            if (!m_gain.empty) {
                if (m_gain.captures.length > 2) {
                    if (isSample(m_gain.captures[2])) {
                        gainDB = to!sample(m_gain.captures[2]);
                        writeln("     +-- gain = ", gainDB, "dB");
                    }
                }
            }

            auto m_velocity_variance = match(line,
                regex(`^\s*VELOCITY\s+VARIANCE(\s+(.*))?`));

            if (!m_velocity_variance.empty) {
                if (m_velocity_variance.captures.length > 2) {
                    if (isSample(m_velocity_variance.captures[2])) {
                        auto var = to!sample(m_velocity_variance.captures[2]);
                        if (var < 0.)
                            var = 0;
                        default_stability_sigma = sqrt(var);
                        writeln("     +-- velocity sigma = sqrt(",
                            var, ") = ", default_stability_sigma,
                            "dB");
                    }
                }
            }

            auto m_time_variance = match(line,
                regex(`^\s*TIME\s+VARIANCE(\s+(.*))?`));

            if (!m_time_variance.empty) {
                if (m_time_variance.captures.length > 2) {
                    if (isSample(m_time_variance.captures[2])) {
                        auto var = to!sample(m_time_variance.captures[2]);
                        if (var < 0.)
                            var = 0;
                        default_timing_sigma = sqrt(var);
                        writeln("     +-- time sigma = sqrt(",
                            var, ") = ", default_timing_sigma, " frames");
                    }
                }
            }

            auto m_delay = match(line, regex(`^\s*DELAY(\s+(.*))?`));

            if (!m_delay.empty) {
                if (m_delay.captures.length > 2) {
                    if (isInt(m_delay.captures[2])) {
                        current_delay = to!int(m_delay.captures[2]);
                        writeln("     +-- delay = ", current_delay,
                            " frames");
                    }
                }
            }

            auto m_user_delay = match(line,
                regex(`^\s*USER\s+DAMP\s+DELAY(\s+(.*))?`));

            if (!m_user_delay.empty) {
                if (m_user_delay.captures.length > 2) {
                    if (isInt(m_user_delay.captures[2])) {
                        current_userdamp_additional_delay = to!int(
                            m_user_delay.captures[2]);
                        writeln("     +-- additional userdamp delay = ",
                            current_userdamp_additional_delay, " frames");
                    }
                }
            }

            auto m_auto_delay = match(line,
                regex(`^\s*AUTO\s+DAMP\s+DELAY(\s+(.*))?`));

            if (!m_auto_delay.empty) {
                if (m_auto_delay.captures.length > 2) {
                    if (isInt(m_auto_delay.captures[2])) {
                        current_autodamp_additional_delay = to!int(
                            m_auto_delay.captures[2]);
                        writeln("     +-- additional autodamp delay = ",
                            current_autodamp_additional_delay, " frames");
                    }
                }
            }

            auto m_drum_delay = match(line,
                regex(`^\s*DRUM\s+([0-9]+)\s+DAMP\s+DELAY(\s+(.*))?`));

            if (!m_drum_delay.empty) {
                if (m_drum_delay.captures.length > 3) {

                    if (isInt(m_drum_delay.captures[3])
                            && isInt(m_drum_delay.captures[1])) {
                        int pitch = to!int(m_drum_delay.captures[1]);
                        int delay = to!int(m_drum_delay.captures[3]);
                        current_damp_pitch_additional_delay[pitch] = delay;

                        writeln("     +-- additional damp pitch ",
                            pitch, " delay = ", delay, " frames");
                    }
                }
            }

        }

        gain[0] = exp(log(2.) * (gainDB - balance) / 10.); // 2^(dB/10) = factor.
        gain[1] = exp(log(2.) * (gainDB + balance) / 10.); // 2^(dB/10) = factor.

        sort(damp_pitches);
        damp_pitches_set = damp_pitches.assumeSorted;

        calculate_interpolation();
    }
}

/// read a 32-bit signed integer (long) big-endian raw wave


wave readSL(char[] filename) {
    wave W;

    auto f = File(filename, "rb");

    int idx = 0;
    foreach (raw_frame; f.byChunk(new ubyte[channels * 4])) {
        ++idx;
        if (raw_frame.length == channels * 4) {
            int[channels] sl_frame;
            for (auto i = 0; i < channels; ++i) {
                ubyte[4] part = raw_frame[(i * 4) .. (i * 4 + 4)];
                sl_frame[i] = bigEndianToNative!int(part);
            }

            frame r_frame;
            for (auto i = 0; i < channels; ++i) {
                r_frame[i] = sl_frame[i];
                r_frame[i] /= 1L << 31;
            }

            W ~= r_frame;
        }
    }

    f.close();

    return W;
}

/// test whether a given string is an integer number
bool isInt(char[] x) {
    try {
        x.to!int;
    }
    catch (ConvException e) {
        if (isSample(x)) {
            writeln("WARNING: Got ", x, " where INTEGER is expected!");
        }
        return false;
    }
    return true;
}

/// test whether a given string is a "sample" number
bool isSample(char[] x) {
    try {
        x.to!sample;
    }
    catch (ConvException e) {
        return false;
    }
    return true;
}


immutable int maximal_gap = 64;

/// find some good indexes where the sign of the wave is about to change
int[][] sgn_test_wave(wave w) {
    int[] l, r;

    for (int idx=0;idx<w.length-1;++idx) {
        if (sgn_test(w[idx][0],w[idx+1][0])) {
            if (l.length > 1) {
                if (idx - l[$-2] <= maximal_gap)
                    l[$ - 1] = idx;
                else
                    l ~= idx;
            } else
                l ~= idx;
        }
        if (sgn_test(w[idx][1],w[idx+1][1])) {
            if (r.length > 1) {
                if (idx - r[$-2] <= maximal_gap)
                    r[$ - 1] = idx;
                else
                    r ~= idx;
            } else
                r ~= idx;
        }
    }

    return [l,r];
}

/// test whether the wave meets zero between sample A and sample B
bool sgn_test2(sample a, sample b) {
    if ((a > 0.) && (b > 0.))
        return false;
    if ((a < 0.) && (b < 0.))
        return false;
    return true;
}

// slightly zero tolerant version
immutable float zero_tolerance = 1.0e-5;
bool sgn_test(sample a, sample b) {
    if ((a > zero_tolerance) && (b > zero_tolerance))
        return false;
    if ((a < zero_tolerance) && (b < zero_tolerance))
        return false;
    return true;
}


bool is_silent(sample x) {
    if (x > zero_tolerance)
        return false;
    if (x < -zero_tolerance)
        return false;
    return true;
}

// truncate silent ends of waves
wave truncate_silence(wave X) {
    ulong end = X.length;
    while (end > 1) {
        if (is_silent(X[cast(uint) end-1][0]) && is_silent(X[cast(uint) end-1][1]))
        {
            --end;
        } else break;  
    }
    return X[0 .. cast(uint)end];
}

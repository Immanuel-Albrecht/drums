module config;
import pattern;

/** load drumkit config */
public import drumkit;

/** This module contains all configuration settings, like special pitches for the input channels etc. */

/*** default jack name */

string name = "synthesize";

/**** configuration variables ***/

auto immutable output_delay = 0; //<! delay of output in samples

auto immutable initial_beat_length = 48000 * 60 / (160 * 4); //<! initial samples per beat

auto immutable note_off_delay = 5; //<! number of frames between note-on and note-off events

immutable bool initially_ticking = true; //<! whether the clock is running at the start

auto immutable note_off_zero_hit = false; //<! true-> hit with zero velocity to end note, false-> use 0x80 cmd

/***
 *
 *
 *  There are two input midi channels, one for triggering
 *  patterns that are going to be played on the hits and 
 *  parameters output channels.
 *
 *  TEMPO INPUT CHANNEL CODES:
 *
 *
***/

immutable ubyte tempo_start = 60; /*<! middle C; starts time setup for next tempo */
immutable ubyte tempo_stop = 61; /*<! tempo = time interval from last start */
/*                            62:      tempo = 1/2 time ubyteerval from last start */
/*                            61+k:    tempo = 1/k time ubyteerval from last start */

immutable ubyte stop_clock = 58; /*<! stop the clock entirely */
immutable ubyte start_clock = 59; /*<! restart the automatic clock again */
immutable ubyte tick_clock = 57; /*<! manually tick the clock to the next step */
immutable ubyte clear_clock = 56; /*<! manually reset beat accumulator to zero */
immutable ubyte hold_delay = 48; /*<! while this note is on, the clock does not advance */

immutable ubyte low_threshold = 0; /*<! below this value, a hit is interpreted as a dampening */

/***
 *  
 *  PATTERN CONTROL
 *
 *
****/

immutable ubyte cancel_pattern_threshold = 32; /*<! pattern hits with velocity strictly below 
                                                 this effectively cancel the pattern on the next beat*/
immutable ubyte stop_pattern_threshold = 64; /*<! pattern hits with vel. strictly below this will
                                                 stop the pattern after finishing. */
immutable ubyte stop_pattern_no_reset_threshold = 48; /*<! pattern hits with vel. strictly below this
                                                        will not reset the current position to zero. */

immutable bool pattern_play_on_hold = true; /*<! if true, the repeat count of a pattern will not reduce, as
                                              long as the pattern-triggering midi note is on. */

/**
  *  hits with velocity from 64 through 95: repeat the pattern 1 .. 32 times.
  *
  */

immutable ubyte infinite_repeat_pattern_threshold = 96; /*<! pattern hits with vel. equal or above this
                                                will loop the pattern until it is canceled */

/***
 *
 *
 *   PATTERN SECTION
 *
 *
 *
****/

immutable string default_pattern_config = "CHANNEL Blasts\n" ~ "XS16: as / bh /\n" ~ "XS8: as / / bh / /\n" ~ "XS6: as / / / bh / / /\n";

/*** PATTERN DEFAULT PARAMETERS */

immutable int default_hit_strength = 112; /*<! default hit intensity */
immutable int increase_strength = 5; /*<! one notch harder/softer hit */



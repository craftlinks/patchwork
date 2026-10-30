//! Session example: a live-coding music screen, rebuilt from two photos of someone else's
//! tool as step 47's stress test. A patch typeset in serif with widgets in its margins, a
//! compander row, a five-strip mixer bound to the patch's numbers, and a piano keyboard over a
//! song overview and a transport.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! Whether an app can build an atypical screen from the public API alone. Everything here is
//! library widgets under app skins (`look.zig`: ring knobs, upright toggles), library draw
//! types (Box, Waveform, Fill, Arc, Path, Glyph), an `EditorOf(patch)` set in serif (`patch.zig`),
//! and pieces the library does not have: two-way bindings (`bindings.zig`), a fader with a
//! stereo meter (`fader.zig`), a piano keyboard (`keys.zig`), and the plots (`plots.zig`). The
//! sound is made up (`signal.zig`).
//!
//! ## 2. Layout (logical pixels, shown at 1280 by 720)
//! The view and the card follow the window: the view is the window's height less
//! `card_space`, and the card spans its width at its bottom. Columns stay where they are.
//! ```text
//! view      0..1280 x 0..628, scrolling: the document's rows, top to bottom
//!   x 18          fold brackets, one per section's lines
//!   x 32..168     margin widgets on their line: sliders, level bars, envelope, response
//!   x 184..1088   the editor, its viewport from x 180: the whole text, with the compander
//!                 row and the mixer (five strips 120 wide, 10 apart) as inline rows
//!   x 1100..1140  toggles; x 1148..1228 knobs: each at its line, pushed down past the last
//! card      8..1272 x 634..716: octave box, keys (36 white, 33 wide, from x 60), the song
//!           overview (540 columns over 1080 px), and the transport
//! ```
//! Rows: the compander row is 92 high, the mixer 324. The editor is as tall as its content, so
//! it never scrolls itself and the wheel reaches the view; its lines are 22 high (Noto Serif at
//! 16 px) and a heading 36.
//!
//! ## 2a. Sections
//! A section is a line starting "# ", found in the text on a new revision (`build_sections`), so
//! typing "# Chorus" adds one. Its gap, rule, and mark hang off that line: inline rows reserve
//! the gap and the rule's room, and `draw_chrome` draws at `rect_of`. Its mark's state and its
//! colour are kept by name, so a section inserted above or moved changes nothing. A name not seen
//! before inherits from the same place when the count held, so renaming keeps both, and a new
//! section takes the next colour.
//!
//! The compander's row follows the line starting `round :=`, the mixer's the line starting
//! `send =`. Their widgets draw after `draw_end`, in the view's clip, because the rows' margin
//! widgets lie left of the editor's viewport. Delete such a line and its row goes until undo or
//! typing it again; the widgets keep their values.
//!
//! ## 2b. Moving a Section
//! A section's "#" is a drag handle: its area sits above the editor's, so a press there never
//! reaches the text and a click on the name still places the caret. Past `drag_start_px` the
//! press becomes a drag between widgets (`ui/cx.zig`, section 7b), with a ghost of the heading at
//! the pointer and a line at the slot it would land in. Slots lie between sections; `slot_ys`
//! keeps where they were drawn. A drop is one edit (`sections.zig`), so one undo restores the
//! order, and it gives the editor focus, so that undo reaches it. Marks, colours, brackets,
//! margins, and the rows move by themselves: they are found from the text.
//!
//! ## 3. Bindings
//! The text is the truth (`bindings.zig`). An edit the app did not cause is parsed into the
//! widgets (`sync`). `event` compares the bound widgets around their handlers, and one that
//! moved rewrites its literal (`write`): that one place catches drags, wheels, and resets alike.
//! A pointer drag or a run of wheel notches is one gesture, so one undo entry; while a drag
//! holds a gesture, keys and pastes are dropped, because undo asserts inside one.
//!
//! A widget whose call is gone keeps its value, dims, and writes nothing; it binds again when
//! the call returns. Moving a widget takes focus from the editor, and giving it back would make
//! the next Space type, so `event` routes Ctrl+Z and Ctrl+Y to the editor when nothing holds
//! focus. A section's mark or a toggle turns its code down with a veil over the line, because a
//! palette is per class, not per line. While the editor has focus, Space and the tracker keys
//! type.
//!
//! ## 4. Transport
//! `timer_period_ms` is 33 and the timer starts disarmed: the screen sleeps until Space or
//! the pause/play mark starts it; each tick adds 33 ms to `t`, and meters, scopes, spectra,
//! the modulator, the spinner, the position, and the overview's playhead follow `t`.
//!
//! ## 5. TigerStyle Invariants
//! - Static: the app and its overview; nothing allocates.
//! - Per-frame work is bounded by the text's caps and the signal's constants.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const bench = patchwork.bench;
const kit = widgets.kit;
const look = @import("look.zig");
const patch = @import("patch.zig");
const bindings = @import("bindings.zig");
const sections_file = @import("sections.zig");
const signal = @import("signal.zig");
const plots = @import("plots.zig");
const fader_file = @import("fader.zig");
const keys = @import("keys.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.Point;
const Context = patchwork.app.Context(App);
const Fader = fader_file.Fader;
const Slot = bindings.Slot;

const Editor = patchwork.editor.EditorOf(patch);
const RingKnob = widgets.KnobOf(look.Ring);
const PanKnob = widgets.KnobOf(look.Bipolar);
const compander_color = [4]f32{ 0.45, 0.88, 0.55, 1 };
const eq_color = [4]f32{ 0.98, 0.62, 0.55, 1 };
const shimmer_color = [4]f32{ 0.98, 0.62, 0.86, 1 };
const SideToggle = widgets.ToggleOf(look.Pill);

// ---------------------------------------------------------------------------- layout

/// The view's height at 1280 by 720: the window's height less `card_space`.
const view_h: f32 = 628;
const card_space: f32 = 92;
const fold_x: f32 = 18;
const margin_x: f32 = 32;
const margin_w: f32 = 136;
const code_x: f32 = 184;
const code_end: f32 = 1088;
const toggle_x: f32 = 1100;
const toggle_w: f32 = 40;
const side_knob_x: f32 = 1148;
const side_knob_w: f32 = 80;
const side_ring: f32 = 56;
const mark_x: f32 = 1196;
const rule_end: f32 = 1240;

const header_h: f32 = 44;
/// A line of code.
const line_h: f32 = patchwork.editor.line_height_of(patch, look.code_size);
const compander_h: f32 = 92;
const mixer_h: f32 = 324;
/// The editor's viewport: its text starts `padding_px` in, at `code_x`.
const editor_x: f32 = code_x - patchwork.editor.padding_px;
const editor_w: f32 = 1080;
/// The gap above a heading, and the room under it for the rule: with the heading, 72 px.
const section_gap: f32 = 32;
const rule_room: f32 = 4;
/// A heading's line.
const heading_h: f32 = patchwork.editor.line_height_of(patch, look.code_size * patch.scales[1]);
const end_gap: f32 = 40;
/// How far a press on a "#" travels before it is a drag.
const drag_start_px: f32 = 4;
/// How far a "#" handle reaches past its glyph on each side.
const handle_slop: f32 = 4;

const comp_box: f32 = 64;
const comp_ring: f32 = 52;
const plot_w: f32 = 144;
const plot_h: f32 = 76;

const strip_w: f32 = 120;
const strip_gap: f32 = 10;
const strip_count: u32 = 5;
const strip_ring: f32 = 40;
const body_y: f32 = 102;
const body_h: f32 = 200;

const card_h: f32 = 82;
const overview_w: f32 = 1080;
const overview_columns: u32 = 540;
const card_fill = [4]f32{ 0.94, 0.94, 0.93, 1 };
const card_ink = [4]f32{ 0.25, 0.25, 0.27, 1 };
const card_accent = [4]f32{ 0.30, 0.62, 0.90, 1 };

const period_ms: u32 = 33;
const song_s: f32 = 64;
const start_s: f32 = 2.35;
const bpm: f32 = 120;

// ---------------------------------------------------------------------------- the patch

/// The mix's section in `patch_text`, the first.
const mix: u8 = 0;
/// Sections the text may have: two inline rows each, and one for the mix body.
const section_cap: u32 = 15;
const strip_names = [_][]const u8{ "bass", "pads", "line", "wet", "master" };

const Margin = enum { none, modulator, envelope, response, saws, sub, noise, pad_mix, wet, master };

/// The editor's starting text. Six spaces of serif are about the 24 px a block is indented,
/// eleven the 44 px a continued line is.
pub const patch_text =
    \\# mix
    \\round := compander(pads + line);
    \\if (tog(1, "eq")) round = round.tilt(gain = m(range=-1~4, period=25s));
    \\if (tog(1, "shimmer")) round = round.pitch_shift(2, 80ms).α(k(0~0.16~1, name="shimmer"));
    \\wet := room.wet * k(0~0.73~1, "wet");
    \\mixed := mixer(bass, pads, line, wet, level = -2.68db, -8.45db, -5.14db, -4.11db,
    \\                             send = -60db, 0db, 0db, -60db, pre = 0, 0, 0, safe[3] = 1, mute[0] = 0, mute[1] = 0);
    \\# osc
    \\module unison(Note n, detune = 0~0.12~1, width = 0~0.8~1) -> ꝏ {
    \\      return sum (j, 8) => saw(n + j.across(0, 7) * detune, φ = 0~1).pan(j.across(0, 7) * width) * 0.35f;
    \\}
    \\# pad
    \\module pad(Note n, saws = 0~0.1~1, sub = 0~0.075~1, noise = 0~0.03~1,
    \\           f = 200hz~3464hz~20000hz) -> ꝏ {
    \\      env := n.adsr(a = 1.34s, d = 1s, s = 1, r = 1.02s);
    \\      a := n.unison() * saws;
    \\      b := sine(n - 12) * sub;
    \\      hiss := ꝏ(white_noise(), white_noise()) * noise;
    \\      mixed := a + b + hiss;
    \\      return mixed.lowpass(f) * env.gate;
    \\}
    \\# reverb tank
    \\module tank(ꝏ audio, ꝏ back, decay = 0~0.93~0.99, damping = 0.05~0.39~1,
    \\           size = 0.5~1.2~2) -> ꝏ {
    \\      diffused := audio.allpass(142, 107, 379, 277) + back * decay;
    \\      return diffused.delay(size * 4453).lowpass(damping.hz()) * decay;
    \\}
;

/// The editor's height for `patch_text`: 23 lines of code, 4 headings, and their rows.
const patch_h: f32 = 2 * patchwork.editor.padding_px + 23 * line_h + 4 * heading_h + 4 * rule_room + 3 * section_gap + compander_h + mixer_h;

/// The document's height for `patch_text`: the view's content.
pub const content_h: f32 = patch_h + end_gap;

// ---------------------------------------------------------------------------- parameters

const Unit = enum { db, ratio, ms, percent, pan, send };

/// A knob's range in its own units; `log` maps the knob logarithmically.
const Param = struct {
    name: []const u8,
    lo: f32,
    hi: f32,
    initial: f32 = 0,
    unit: Unit,
    log: bool = false,

    fn display(self: Param, value: f32) f32 {
        assert(value >= 0 and value <= 1);
        if (self.log) return self.lo * std.math.pow(f32, self.hi / self.lo, value);
        return self.lo + value * (self.hi - self.lo);
    }

    fn position(self: Param, shown: f32) f32 {
        const t = if (self.log) @log(shown / self.lo) / @log(self.hi / self.lo) else (shown - self.lo) / (self.hi - self.lo);
        return std.math.clamp(t, 0, 1);
    }

    fn format(self: Param, out: *[12]u8, value: f32) []const u8 {
        const shown = self.display(value);
        const tidy = if (@abs(shown) < 0.05) 0 else shown;
        return switch (self.unit) {
            .db => if (tidy == 0) "0db" else std.fmt.bufPrint(out, "{d:.1}db", .{tidy}) catch unreachable,
            .ratio => std.fmt.bufPrint(out, "{d:.2}", .{shown}) catch unreachable,
            .ms => std.fmt.bufPrint(out, "{d:.0}ms", .{shown}) catch unreachable,
            .percent => std.fmt.bufPrint(out, "{d:.1}%", .{shown * 100}) catch unreachable,
            .pan => std.fmt.bufPrint(out, "{d:.1}", .{tidy}) catch unreachable,
            .send => if (value == 0) "-inf" else std.fmt.bufPrint(out, "{d:.0}db", .{tidy}) catch unreachable,
        };
    }
};

const comp_params = [_]Param{
    .{ .name = "below", .lo = -60, .hi = 0, .initial = -27.7, .unit = .db },
    .{ .name = "up", .lo = 1, .hi = 8, .initial = 3.82, .unit = .ratio },
    .{ .name = "above", .lo = -60, .hi = 0, .initial = -15.5, .unit = .db },
    .{ .name = "down", .lo = 1, .hi = 8, .initial = 3.42, .unit = .ratio },
    .{ .name = "most", .lo = 0, .hi = 24, .initial = 11.1, .unit = .db },
    .{ .name = "a", .lo = 0.1, .hi = 100, .initial = 5, .unit = .ms, .log = true },
    .{ .name = "r", .lo = 1, .hi = 1000, .initial = 100, .unit = .ms, .log = true },
    .{ .name = "makeup", .lo = -12, .hi = 12, .initial = 0, .unit = .db },
};
const shimmer_param: Param = .{ .name = "shimmer", .lo = 0, .hi = 1, .unit = .percent };
const wet_param: Param = .{ .name = "wet", .lo = 0, .hi = 1, .unit = .percent };
const pan_param: Param = .{ .name = "pan", .lo = -1, .hi = 1, .initial = 0, .unit = .pan };
const send_param: Param = .{ .name = "send", .lo = -60, .hi = 6, .unit = .send };
/// The master fader's level: it has no line in the text.
const master_level: f32 = 0;

// ---------------------------------------------------------------------------- ids

pub const view_id = ui.id("view", 0);
fn comp_id(index: u32) ui.Id {
    return ui.id("comp", index);
}
const shimmer_id = ui.id("shimmer", 0);
const wet_id = ui.id("wet", 0);
const comp_on_id = ui.id("compander", 0);
const eq_on_id = ui.id("eq", 0);
const shimmer_on_id = ui.id("shimmer on", 0);
fn pan_id(strip: u32) ui.Id {
    return ui.id("pan", strip);
}
fn send_id(strip: u32) ui.Id {
    return ui.id("send", strip);
}
fn fader_id(strip: u32) ui.Id {
    return ui.id("fader", strip);
}
fn mute_id(strip: u32) ui.Id {
    return ui.id("mute", strip);
}
fn solo_id(strip: u32) ui.Id {
    return ui.id("solo", strip);
}
fn mark_id(section: u32) ui.Id {
    return ui.id("mark", section);
}
fn hash_id(section: u32) ui.Id {
    return ui.id("hash", section);
}
const drop_id = ui.id("drop", 0);
pub const editor_id = ui.id("editor", 0);
const keyboard_id = ui.id("keyboard", 0);
const play_id = ui.id("play", 0);
const loop_id = ui.id("loop", 0);

// ---------------------------------------------------------------------------- pools

/// What the screen draws around the editor, plus the editor in a view as tall as this one.
const glyph_cap: u32 = 6144 + patchwork.editor.glyph_bound_of(patch, editor_w, view_h, look.code_size);
const box_cap: u32 = 1024;
const arc_cap: u32 = 64;
const path_cap: u32 = 1024;
const wave_cap: u32 = 4;
/// Bands of the one spectrum fill.
const fill_cap: u32 = 8;
const area_cap: u32 = 192;

const Strip = struct {
    pan: PanKnob,
    send: RingKnob,
    fader: Fader,
    mute: widgets.Button,
    solo: widgets.Button,
    muted: bool = false,
    soloed: bool = false,
};

/// What one frame's sound is: per strip its linear gain, its level in decibels, and its meter
/// (unit positions, left and right).
const Mixdown = struct {
    gain: [signal.channel_count]f32,
    master: f32,
    db: [strip_count]f32,
    meter: [strip_count][2]f32,
};

/// Where the rows put things this frame, for what draws after them.
const Placed = struct {
    first_y: [section_cap]f32 = @splat(std.math.inf(f32)),
    last_y: [section_cap]f32 = @splat(-std.math.inf(f32)),
    toggle_y: [3]f32 = @splat(0),
    knob_y: [2]f32 = @splat(0),
    /// The compander row's line sits in a section that is on.
    compander_on: bool = true,
    /// The "mixer" word's span and the bottom of its line, and the mixer row's top.
    mixer_word: [2]f32 = .{ 0, 0 },
    mixer_line: f32 = 0,
    mixer_top: ?f32 = null,
};

/// A heading in the text (section 2a).
const Section = struct {
    /// The hash of its name, which keeps `enabled` across edits.
    name: u64,
    enabled: bool,
    /// Its index into the cycle of `look.section_colors`.
    colour: u8,
    line: u32,
};

const RowKind = enum { room, compander, mixer };

/// An inline row before they are sorted by line.
const PlannedRow = struct {
    after_line: u32,
    height: f32,
    kind: RowKind,

    fn before(_: void, a: PlannedRow, b: PlannedRow) bool {
        return a.after_line < b.after_line;
    }
};

/// What a gesture on a bound widget is, which says what ends it (section 3).
const Gesture = enum { none, drag, wheel };

/// A section whose colour is not settled yet, while `build_sections` runs.
const no_colour: u8 = 255;

/// What keeps a section across edits: its name, whatever its case or outer spaces.
fn name_key(name: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (std.mem.trim(u8, name, " ")) |byte| {
        hasher.update(&.{std.ascii.toLower(byte)});
    }
    return hasher.final();
}

pub const App = struct {
    view: ui.ViewState,
    comp: [comp_params.len]RingKnob,
    shimmer: RingKnob,
    wet: RingKnob,
    comp_on: SideToggle,
    eq_on: SideToggle,
    shimmer_on: SideToggle,
    strips: [strip_count]Strip,
    keyboard: keys.Keyboard,
    editor: Editor,
    /// The text's sections and what the editor's rows hold (section 2a), for one revision.
    sections: [section_cap]Section,
    section_count: u32,
    /// The lines the compander's and the mixer's rows follow.
    compander_line: ?u32,
    mixer_line: ?u32,
    row_kinds: [patchwork.editor.row_cap]RowKind,
    sections_revision: u64,
    /// The colour the next new section takes.
    colour_next: u8,
    /// Where each slot was drawn (section 2b): the sections' tops, then the end of the text.
    slot_ys: [section_cap + 1]f32,
    /// Where a press on a "#" began.
    grab: [2]f32,
    /// The rebuilt bytes of a move.
    move_scratch: [patchwork.editor.buffer.buffer_cap]u8,
    /// The values read out of the text (section 3), for `parsed_revision`.
    parse: bindings.Parse,
    parsed_revision: u64,
    gesture: Gesture,
    /// The side widgets' last content y: compander, eq, shimmer toggles; shimmer, wet knobs.
    side_y: [5]f32,
    playing: bool,
    looping: bool,
    t: f32,
    overview: [overview_columns]quads.wave.Column,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork session",
        .timer_period_ms = period_ms,
        .timer_armed = false,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Waveform, .cap = wave_cap },
            .{ .type = quads.Fill, .cap = fill_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
        },
        .batch_order = .registered,
        .area_cap = area_cap,
        .theme = look.scheme,
    };

    pub const scenarios: []const bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{ .name = "scroll", .setup = &scroll_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "play", .setup = &play_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "mix", .setup = &mix_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "knobs", .setup = &knob_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "keys", .setup = &key_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "edit", .setup = &edit_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "select", .setup = &select_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "undo", .setup = &undo_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "section", .setup = &section_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "rename", .setup = &rename_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "reorder", .setup = &reorder_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "reorder-hold", .setup = &hold_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "reorder-undo", .setup = &reorder_undo_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "bind-type", .setup = &bind_type_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "bind-drag", .setup = &bind_drag_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "bind-undo", .setup = &bind_undo_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "bind-toggle", .setup = &bind_toggle_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "bind-break", .setup = &bind_break_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        app.view = .init();
        for (&app.comp, comp_params, 0..) |*knob, param, index| {
            const accent = look.pastels[index % look.pastels.len];
            knob.* = RingKnob.init(comp_id(@intCast(index)), param.name, param.position(param.initial), paint(accent)).sized(comp_ring);
        }
        app.shimmer = RingKnob.init(shimmer_id, "shimmer", 0, paint(shimmer_color)).sized(side_ring);
        app.wet = RingKnob.init(wet_id, "wet", 0, paint(look.pastels[2])).sized(side_ring);
        app.comp_on = SideToggle.init(comp_on_id, "compander", true);
        app.comp_on.accent = compander_color;
        app.eq_on = SideToggle.init(eq_on_id, "eq", true);
        app.eq_on.accent = eq_color;
        app.shimmer_on = SideToggle.init(shimmer_on_id, "shimmer", true);
        app.shimmer_on.accent = shimmer_color;
        for (&app.strips, 0..) |*strip, index| {
            const at: u32 = @intCast(index);
            const color = strip_color(at);
            strip.* = .{
                .pan = PanKnob.init(pan_id(at), "pan", 0.5, paint(look.white)).sized(strip_ring),
                .send = RingKnob.init(send_id(at), "send", 0, paint(color)).sized(strip_ring),
                .fader = Fader.init(fader_id(at), master_level),
                .mute = small_button(mute_id(at), "M"),
                .solo = small_button(solo_id(at), "S"),
            };
        }
        app.keyboard = .{ .id = keyboard_id };
        app.editor.init(editor_id, editor_style());
        assert(app.editor.load(patch_text));
        app.section_count = 0;
        app.colour_next = 0;
        app.build_sections();
        app.slot_ys = @splat(0);
        app.grab = .{ 0, 0 };
        app.side_y = @splat(0);
        app.gesture = .none;
        app.parsed_revision = 0;
        app.sync();
        app.settle_defaults();
        app.playing = false;
        app.looping = true;
        app.t = start_s;
        build_overview(&app.overview);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        if (app.gesture_drops(event_value)) return;
        _ = app.editor.handle(cx, event_value);
        app.sync();
        const typing = cx.focused(editor_id);
        const before = app.numbers();
        _ = app.view.handle(cx, view_id, event_value);
        for (&app.comp) |*knob| _ = knob.handle(cx, event_value);
        _ = app.shimmer.handle(cx, event_value);
        _ = app.wet.handle(cx, event_value);
        _ = app.comp_on.handle(cx, event_value);
        _ = app.eq_on.handle(cx, event_value);
        _ = app.shimmer_on.handle(cx, event_value);
        for (&app.strips, 0..) |*strip, index| {
            _ = strip.pan.handle(cx, event_value);
            _ = strip.fader.handle(cx, event_value);
            if (index + 1 < strip_count) _ = strip.send.handle(cx, event_value);
            if (strip.mute.handle(cx, event_value) == .clicked) {
                strip.muted = !strip.muted;
                cx.redraw();
            }
            if (index + 1 < strip_count and strip.solo.handle(cx, event_value) == .clicked) {
                strip.soloed = !strip.soloed;
                cx.redraw();
            }
        }
        for (app.sections[0..app.section_count], 0..) |*section, index| {
            if (kit.clicked(cx, mark_id(@intCast(index)), event_value)) {
                section.enabled = !section.enabled;
                cx.redraw();
            }
        }
        app.write_moved(cx, event_value, before);
        app.handle_move(cx, event_value);
        // A release still counts: its note may have started before the editor took focus.
        if (!(typing and event_value == .key_down)) _ = app.keyboard.handle(cx, event_value);
        if (kit.clicked(cx, play_id, event_value)) app.set_playing(cx, !app.playing);
        if (kit.clicked(cx, loop_id, event_value)) {
            app.looping = !app.looping;
            cx.redraw();
        }
        switch (event_value) {
            .key_down => |press| {
                if (typing) {
                    app.follow_caret(cx);
                } else if (kit.is_space(press) and !press.repeat) {
                    app.set_playing(cx, !app.playing);
                } else if (press.mods.shortcut() and cx.focus == .none) {
                    app.route_history(cx, press);
                }
            },
            else => {},
        }
    }

    /// Ctrl+Z and Ctrl+Y with nothing focused: moving a widget took focus from the editor, and
    /// a widget's move is an edit like any other (section 3).
    fn route_history(app: *App, cx: *Context, press: input.KeyPress) void {
        const action = switch (press.key) {
            .z => if (press.mods.shift) app.editor.redo(cx) else app.editor.undo(cx),
            .y => app.editor.redo(cx),
            else => return,
        };
        if (action != .changed) return;
        app.sync();
        app.follow_caret(cx);
    }

    /// True when a gesture swallows the event; closes one the event ends (section 3).
    fn gesture_drops(app: *App, event_value: input.Event) bool {
        if (app.gesture == .none) return false;
        switch (event_value) {
            .frame, .pointer_move, .wheel, .key_up => return false,
            .key_down, .paste => {
                if (app.gesture == .drag) return true;
            },
            else => {},
        }
        app.close_gesture();
        return false;
    }

    fn close_gesture(app: *App) void {
        assert(app.gesture != .none);
        app.editor.gesture_end();
        app.gesture = .none;
        app.parsed_revision = 0;
        app.sync();
    }

    /// Reads the text into the widgets when it moved without them (section 3).
    fn sync(app: *App) void {
        const revision = app.editor.revision();
        if (revision == app.parsed_revision) return;
        app.parsed_revision = revision;
        app.parse = .run(app.editor.text());
        for (0..bindings.slot_count) |index| {
            const slot: Slot = @fromBackingInt(@as(u8, @intCast(index)));
            if (app.parse.get(slot)) |value| app.set_slot(slot, value);
        }
        app.decorate();
    }

    /// The starting text's values are what a right press restores.
    fn settle_defaults(app: *App) void {
        app.shimmer.default = app.shimmer.value;
        app.wet.default = app.wet.value;
        for (&app.strips) |*strip| {
            strip.fader.default = strip.fader.value;
            strip.send.default = strip.send.value;
        }
    }

    fn set_slot(app: *App, slot: Slot, value: bindings.Value) void {
        const number = value.number;
        switch (slot) {
            .eq_on => set_toggle(&app.eq_on, number != 0),
            .shimmer_on => set_toggle(&app.shimmer_on, number != 0),
            .shimmer => app.shimmer.set_value(unit_of(value)),
            .wet => app.wet.set_value(unit_of(value)),
            .level_0, .level_1, .level_2, .level_3 => {
                app.strips[strip_of(slot, .level_0)].fader.value = fader_file.position(number);
            },
            .send_0, .send_1, .send_2, .send_3 => {
                app.strips[strip_of(slot, .send_0)].send.set_value(send_param.position(number));
            },
            .mute_0, .mute_1 => app.strips[strip_of(slot, .mute_0)].muted = number != 0,
        }
    }

    /// The bound widget's value in the text's units.
    fn number_of(app: *const App, slot: Slot) f32 {
        const ends = app.parse.get(slot);
        const lo = if (ends) |value| value.lo else 0;
        const hi = if (ends) |value| value.hi else 1;
        return switch (slot) {
            .eq_on => @floatFromInt(@intFromBool(app.eq_on.on)),
            .shimmer_on => @floatFromInt(@intFromBool(app.shimmer_on.on)),
            .shimmer => lo + app.shimmer.value * (hi - lo),
            .wet => lo + app.wet.value * (hi - lo),
            .level_0, .level_1, .level_2, .level_3 => app.strips[strip_of(slot, .level_0)].fader.db(),
            .send_0, .send_1, .send_2, .send_3 => send_param.display(app.strips[strip_of(slot, .send_0)].send.value),
            .mute_0, .mute_1 => @floatFromInt(@intFromBool(app.strips[strip_of(slot, .mute_0)].muted)),
        };
    }

    fn numbers(app: *const App) [bindings.slot_count]f32 {
        var out: [bindings.slot_count]f32 = undefined;
        for (&out, 0..) |*number, index| number.* = app.number_of(@fromBackingInt(@as(u8, @intCast(index))));
        return out;
    }

    /// Rewrites the literal of every bound widget this event moved (section 3).
    fn write_moved(app: *App, cx: *Context, event_value: input.Event, before: [bindings.slot_count]f32) void {
        const now = app.numbers();
        for (now, before, 0..) |number, was, index| {
            if (number == was) continue;
            const slot: Slot = @fromBackingInt(@as(u8, @intCast(index)));
            if (app.parse.get(slot) == null) continue;
            if (app.gesture == .none and (event_value == .pointer_move or event_value == .wheel)) {
                app.editor.gesture_begin();
                app.gesture = if (event_value == .wheel) .wheel else .drag;
            }
            app.write(slot, number);
            cx.redraw();
        }
    }

    /// A parse never writes and a write never parses: the other ranges shift instead.
    fn write(app: *App, slot: Slot, number: f32) void {
        const entry = &app.parse.values[@backingInt(slot)];
        const value = entry.*.?;
        var out: [bindings.literal_cap]u8 = undefined;
        const bytes = bindings.format(slot, number, &out);
        const range = value.range;
        if (!app.editor.replace(.{ .start = range.start, .end = range.end }, bytes)) return;
        const delta = @as(i32, @intCast(bytes.len)) - @as(i32, @intCast(range.end - range.start));
        app.parse.shift(range.end, delta);
        entry.*.?.range.end = range.start + @as(u32, @intCast(bytes.len));
        entry.*.?.number = number;
        app.parsed_revision = app.editor.revision();
        app.decorate();
    }

    /// The parse's errors as the editor's decorations.
    fn decorate(app: *App) void {
        const editor = &app.editor;
        editor.decoration_count = 0;
        for (app.parse.errors[0..app.parse.error_count]) |span| {
            editor.decorations[editor.decoration_count] = .{ .start = span.start, .end = span.end, .kind = .@"error" };
            editor.decoration_count += 1;
        }
    }

    /// The press, drag, and drop of a section's "#" (section 2b).
    fn handle_move(app: *App, cx: *Context, event_value: input.Event) void {
        for (0..app.section_count) |index| {
            const id = hash_id(@intCast(index));
            switch (cx.hit(id, event_value)) {
                .down => |press| app.grab = .{ press.x, press.y },
                .drag => |press| {
                    const moved = @abs(press.x - app.grab[0]) + @abs(press.y - app.grab[1]);
                    if (cx.dragging() == null and moved >= drag_start_px) cx.drag_begin(id, index);
                },
                else => {},
            }
        }
        switch (cx.drag_hit(drop_id, event_value)) {
            .dropped => |over| {
                if (!app.move_section(@intCast(over.payload), app.slot_of(over.y))) return;
                cx.set_focus(editor_id);
                cx.redraw();
            },
            else => {},
        }
    }

    /// Moves section `index` to `slot` as one edit; false when that changes nothing or is
    /// refused. The caret and selection travel with the text.
    fn move_section(app: *App, index: u32, slot: u32) bool {
        assert(index < app.section_count);
        const editor = &app.editor;
        var starts: [section_cap]u32 = undefined;
        for (app.sections[0..app.section_count], 0..) |section, at| {
            starts[at] = editor.buffer.line_range(section.line).start;
        }
        const text_now = editor.text();
        const move = sections_file.plan(text_now, starts[0..app.section_count], index, slot, &app.move_scratch) orelse return false;
        const after: patchwork.editor.buffer.Selection = .{ .caret = move.map(editor.caret), .anchor = move.map(editor.anchor) };
        return editor.replace_keeping(.{ .start = move.range.start, .end = move.range.end }, move.bytes, after);
    }

    /// The slot nearest the window y `y`.
    fn slot_of(app: *const App, y: f32) u32 {
        var best: u32 = 0;
        for (app.slot_ys[0 .. app.section_count + 1], 0..) |slot_y, slot| {
            if (@abs(slot_y - y) < @abs(app.slot_ys[best] - y)) best = @intCast(slot);
        }
        return best;
    }

    /// The section a drag of ours is moving.
    fn dragged_section(app: *const App, cx: *const Context) ?u32 {
        const drag = cx.dragging() orelse return null;
        if (drag.payload >= app.section_count) return null;
        const index: u32 = @intCast(drag.payload);
        return if (drag.source == hash_id(index)) index else null;
    }

    /// Keeps the caret in the view: the editor never scrolls itself (section 2).
    fn follow_caret(app: *App, cx: *Context) void {
        const caret = app.editor.rect_of(app.editor.caret);
        const port = app.view.viewport;
        const margin = patchwork.editor.padding_px;
        if (caret.y - margin < port.y) {
            _ = app.view.scroll_to(cx, app.view.scroll_y + caret.y - margin - port.y);
        } else if (caret.y + caret.height + margin > port.y + port.height) {
            _ = app.view.scroll_to(cx, app.view.scroll_y + caret.y + caret.height + margin - port.y - port.height);
        }
    }

    fn set_playing(app: *App, cx: *Context, on: bool) void {
        app.playing = on;
        cx.set_timer(on);
        cx.redraw();
    }

    /// One transport tick (section 4).
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        assert(app.playing);
        assert(now_ms == now_ms);
        app.t += @as(f32, @floatFromInt(period_ms)) / 1000;
        if (app.t >= song_s) {
            app.t = if (app.looping) app.t - song_s else song_s;
            if (!app.looping) app.set_playing(cx, false);
        }
        cx.redraw();
    }

    pub fn draw(app: *App, cx: *Context) void {
        app.sync();
        const sound = app.mixdown();
        const screen = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down });
        const viewport_h = @max(line_h, screen.height - card_space);
        _ = cx.begin_view(view_id, ui.sized(.fill, .{ .fixed = viewport_h }), .{ .flow = .down }, &app.view);
        var placed: Placed = .{};
        app.draw_editor(cx, &placed, sound);
        _ = cx.walk(ui.sized(.fill, .{ .fixed = end_gap }));
        app.draw_drop(cx);
        app.draw_folds(cx, &placed);
        app.draw_connector(cx, &placed);
        app.draw_side(cx, &placed);
        cx.end_view();
        app.draw_card(cx, bottom_of(screen));
        app.draw_ghost(cx);
        _ = cx.end();
        assert(cx.area_overflow == 0);
    }

    /// The frame's sound (section 4).
    fn mixdown(app: *const App) Mixdown {
        var any_solo = false;
        for (app.strips[0..4]) |strip| any_solo = any_solo or strip.soloed;
        var out: Mixdown = undefined;
        var power: f32 = 0;
        out.master = if (app.strips[4].muted) 0 else db_gain(app.strips[4].fader.db());
        for (0..signal.channel_count) |channel| {
            const strip = app.strips[channel];
            const silent = strip.muted or (any_solo and !strip.soloed);
            out.gain[channel] = if (silent) 0 else db_gain(strip.fader.db());
            const level = signal.level(@intCast(channel), app.t) * out.gain[channel];
            power += level * level;
            app.strip_meter(&out, channel, level);
        }
        app.strip_meter(&out, 4, @sqrt(power) * out.master);
        return out;
    }

    fn strip_meter(app: *const App, out: *Mixdown, index: usize, level: f32) void {
        const db = signal.decibels(@min(level, 1.99), -60);
        out.db[index] = db;
        const pan = pan_param.display(app.strips[index].pan.value);
        const left = level * (1 - @max(0, pan));
        const right = level * (1 + @min(0, pan));
        out.meter[index] = .{
            fader_file.position(signal.decibels(@min(left, 1.99), -60)),
            fader_file.position(signal.decibels(@min(right, 1.99), -60)),
        };
    }

    // ------------------------------------------------------------------------ rows

    /// A section's rule, mark, and handle, in the 44 px its heading sits in; `hash` is the
    /// rect of the heading's "#".
    fn draw_chrome(app: *const App, cx: *Context, index: u32, hash: Rect) void {
        const rect: Rect = .{ .x = 0, .y = hash.y - rule_room, .width = rule_end + 16, .height = header_h };
        const clip = cx.visible(rect) orelse return;
        var grab = ui.cx.plain;
        grab.cursor = .grab;
        const handle: Rect = .{ .x = hash.x - handle_slop, .y = hash.y, .width = hash.width + 2 * handle_slop, .height = hash.height };
        cx.area(hash_id(index), handle, 0, grab);
        look.hline(cx, code_x, rule_end, rect.y + rect.height - 3, clip, look.rule);
        const on = app.sections[index].enabled;
        const color = if (on) look.section_colors[app.sections[index].colour] else look.faint;
        const box: Rect = .{ .x = mark_x, .y = rect.y + 13, .width = 16, .height = 18 };
        kit.face(cx, box, clip, .{ .fill = look.background, .border_color = color, .border_width = 1.5, .radius = 1 });
        if (on) look.fill(cx, .{ .x = box.x + 7, .y = box.y + 5, .width = 2, .height = 8 }, clip, color);
        cx.area(mark_id(index), box, 0, ui.cx.plain);
        kit.label(cx, look.style(.serif, 18, look.dim), "+", .{ .x = mark_x + 22, .y = box.y, .width = 16, .height = box.height }, clip, look.centered);
    }

    fn draw_margin(app: *const App, cx: *Context, margin: Margin, alpha: f32, rect: Rect, clip: Clip, sound: Mixdown) void {
        const box: Rect = .{ .x = margin_x, .y = rect.y + 2, .width = margin_w, .height = rect.height - 4 };
        const pads_db = signal.decibels(signal.level(signal.pads, app.t) * 2.5, -60);
        switch (margin) {
            .none => {},
            .modulator => plots.slider(cx, .{ .x = margin_x + 34, .y = box.y, .width = margin_w - 36, .height = box.height }, clip, modulator(app.t), -1, 4, alpha),
            .envelope => plots.envelope(cx, .{ .x = margin_x + 40, .y = rect.y - 6, .width = margin_w - 40, .height = rect.height + 2 }, clip, 1.34, 1, 1, 1.02, 1),
            .response => plots.response(cx, .{ .x = margin_x + 40, .y = rect.y, .width = margin_w - 40, .height = rect.height - 2 }, clip, 3464, 1),
            .saws => level_bars(cx, box, clip, signal.decibels(0.1, -60), pads_db, look.white),
            .sub => level_bars(cx, box, clip, signal.decibels(0.075, -60), pads_db, look.white),
            .noise => level_bars(cx, box, clip, signal.decibels(0.03, -60), pads_db, look.white),
            .pad_mix => level_bars(cx, box, clip, signal.decibels(0.205, -60), pads_db, look.white),
            .wet => {
                var label: [8]u8 = undefined;
                plots.bars(cx, box, clip, decibel_label(&label, sound.db[3]), sound.db[3] + 6, sound.db[3] + 5, look.channel_colors[3]);
            },
            .master => {
                var label: [8]u8 = undefined;
                const meter = sound.meter[4];
                plots.bars(cx, box, clip, decibel_label(&label, sound.db[4]), fader_file.decibels(meter[0]) + 6, fader_file.decibels(meter[1]) + 6, look.white);
            },
        }
    }

    /// Finds the sections in the text and the rows they need (section 2a).
    fn build_sections(app: *App) void {
        const editor = &app.editor;
        const before = app.sections;
        const before_count = app.section_count;
        app.section_count = 0;
        app.compander_line = null;
        app.mixer_line = null;
        for (0..editor.buffer.line_count) |index| {
            const line: u32 = @intCast(index);
            const bytes = editor.buffer.line_bytes(line);
            const code = std.mem.trimStart(u8, bytes, " ");
            if (app.compander_line == null and std.mem.startsWith(u8, code, "round :=")) app.compander_line = line;
            if (app.mixer_line == null and std.mem.startsWith(u8, code, "send =")) app.mixer_line = line;
            if (patch.level_of(bytes) == 0 or app.section_count == section_cap) continue;
            const key = name_key(bytes[2..]);
            var section: Section = .{ .name = key, .enabled = true, .colour = no_colour, .line = line };
            for (before[0..before_count]) |old| {
                if (old.name != key) continue;
                section.enabled = old.enabled;
                section.colour = old.colour;
            }
            app.sections[app.section_count] = section;
            app.section_count += 1;
        }
        // A name not seen: the same place if the count held, a rename; else a new section.
        for (app.sections[0..app.section_count], 0..) |*section, index| {
            if (section.colour != no_colour) continue;
            if (before_count == app.section_count) {
                section.enabled = before[index].enabled;
                section.colour = before[index].colour;
            } else {
                section.colour = app.colour_next;
                app.colour_next = @intCast((app.colour_next + 1) % look.section_colors.len);
            }
        }
        var planned: [patchwork.editor.row_cap]PlannedRow = undefined;
        var count: u32 = 0;
        // Widgets' rows first: sorting is stable, and a gap after the same line goes below them.
        if (app.compander_line) |line| {
            planned[count] = .{ .after_line = line, .height = compander_h, .kind = .compander };
            count += 1;
        }
        if (app.mixer_line) |line| {
            planned[count] = .{ .after_line = line, .height = mixer_h, .kind = .mixer };
            count += 1;
        }
        for (app.sections[0..app.section_count]) |section| {
            if (section.line > 0) {
                planned[count] = .{ .after_line = section.line - 1, .height = section_gap, .kind = .room };
                count += 1;
            }
            planned[count] = .{ .after_line = section.line, .height = rule_room, .kind = .room };
            count += 1;
        }
        std.sort.insertion(PlannedRow, planned[0..count], {}, PlannedRow.before);
        for (planned[0..count], 0..) |row, index| {
            editor.rows[index] = .{ .after_line = row.after_line, .height = row.height };
            app.row_kinds[index] = row.kind;
        }
        editor.row_count = count;
        app.sections_revision = editor.revision();
    }

    /// The window y of the middle of `slot`'s line, while it is bound.
    fn slot_middle(app: *const App, slot: Slot) ?f32 {
        const value = app.parse.get(slot) orelse return null;
        const rect = app.editor.rect_of(value.range.start);
        return rect.y + rect.height * 0.5;
    }

    /// The window y of side widget `index`: at its line, or where it last was (section 3).
    fn side_at(app: *App, index: usize, middle: ?f32) f32 {
        if (middle) |y| app.side_y[index] = y + app.view.scroll_y;
        return app.side_y[index] - app.view.scroll_y;
    }

    /// The editor, what hangs off its lines, and the widgets of its rows (section 2a).
    fn draw_editor(app: *App, cx: *Context, placed: *Placed, sound: Mixdown) void {
        const editor = &app.editor;
        if (editor.revision() != app.sections_revision) app.build_sections();
        var walk = ui.sized(.{ .fixed = editor_w }, .{ .fixed = editor.content_height() });
        walk.margin.left = editor_x;
        editor.draw_begin(cx, walk);
        var compander_top: ?f32 = null;
        while (editor.next_row(cx)) |slot| {
            const rect = cx.walk(slot.walk);
            switch (app.row_kinds[slot.index]) {
                .room => {},
                .compander => compander_top = rect.y,
                .mixer => placed.mixer_top = rect.y,
            }
        }
        editor.draw_end(cx);
        app.draw_lines(cx, placed, sound);
        placed.toggle_y[1] = app.side_at(1, app.slot_middle(.eq_on));
        placed.toggle_y[2] = app.side_at(2, app.slot_middle(.shimmer_on));
        placed.knob_y[0] = app.side_at(3, app.slot_middle(.shimmer));
        placed.knob_y[1] = app.side_at(4, app.slot_middle(.wet));
        if (std.mem.indexOf(u8, editor.text(), "mixer(")) |at| {
            const start: u32 = @intCast(at);
            const word = editor.rect_of(start);
            placed.mixer_word = .{ word.x, editor.rect_of(start + 5).x };
            placed.mixer_line = word.y + word.height - 2;
        }
        const width = app.view.viewport.width - ui.view.gutter_px;
        const compander_middle = if (compander_top) |top| top + compander_h * 0.5 else null;
        placed.toggle_y[0] = app.side_at(0, compander_middle);
        if (compander_top) |top| {
            app.draw_compander(cx, .{ .x = 0, .y = top, .width = width, .height = compander_h }, placed);
        }
        if (placed.mixer_top) |top| {
            app.draw_mixer(cx, .{ .x = 0, .y = top, .width = width, .height = mixer_h }, sound);
        }
    }

    /// Each line's chrome or margin, and its veil (section 3).
    fn draw_lines(app: *App, cx: *Context, placed: *Placed, sound: Mixdown) void {
        const editor = &app.editor;
        const eq_line = app.line_of(.eq_on);
        const shimmer_line = app.line_of(.shimmer_on);
        var section: ?u32 = null;
        var next: u32 = 0;
        for (0..editor.buffer.line_count) |index| {
            const line: u32 = @intCast(index);
            const top = editor.rect_of(editor.buffer.line_range(line).start);
            if (next < app.section_count and app.sections[next].line == line) {
                section = next;
                next += 1;
                app.slot_ys[section.?] = top.y;
                app.draw_chrome(cx, section.?, top);
                continue;
            }
            const rect: Rect = .{ .x = 0, .y = top.y, .width = rule_end, .height = top.height };
            var alpha: f32 = 1;
            if (section) |at| {
                placed.first_y[at] = @min(placed.first_y[at], rect.y);
                placed.last_y[at] = @max(placed.last_y[at], rect.y + rect.height);
                if (!app.sections[at].enabled) alpha = 0.35;
            }
            if (app.compander_line == line) placed.compander_on = alpha == 1;
            if (eq_line == line and !app.eq_on.on) alpha *= 0.45;
            if (shimmer_line == line and !app.shimmer_on.on) alpha *= 0.45;
            const clip = cx.visible(rect) orelse continue;
            if (eq_line == line) look.hline(cx, code_x, rule_end, rect.y, clip, look.rule);
            if (alpha < 1) veil(cx, .{ .x = editor_x, .y = rect.y, .width = editor_w, .height = rect.height }, clip, 1 - alpha);
            app.draw_margin(cx, margin_of(editor.buffer.line_bytes(line)), alpha, rect, clip, sound);
        }
        const last = editor.buffer.line_count - 1;
        const bottom = editor.rect_of(editor.buffer.line_range(last).start);
        app.slot_ys[app.section_count] = bottom.y + bottom.height;
    }

    /// The line `slot` is bound on.
    fn line_of(app: *const App, slot: Slot) ?u32 {
        const value = app.parse.get(slot) orelse return null;
        return app.editor.buffer.line_of(value.range.start);
    }

    /// Dims `rect` when `slot` has no call to bind to (section 3).
    fn dim_unbound(app: *const App, cx: *Context, slot: Slot, rect: Rect) void {
        if (app.parse.get(slot) != null) return;
        const clip = cx.clip() orelse return;
        veil(cx, rect, clip, unbound_veil);
    }

    /// While a section is dragged: the drop's area, and a line where it would land.
    fn draw_drop(app: *const App, cx: *Context) void {
        const index = app.dragged_section(cx) orelse return;
        const port = app.view.viewport;
        cx.area(drop_id, port, 0, ui.cx.drag_target_flag);
        const slot = app.slot_of(cx.dragging().?.y);
        if (sections_file.unchanged(index, slot)) return;
        const clip = cx.clip() orelse return;
        const gap = if (slot > 0 and slot < app.section_count) section_gap * 0.5 else 0;
        const color = look.section_colors[app.sections[index].colour];
        const previous = cx.drawing().layer(look.over_layer);
        look.fill(cx, .{ .x = code_x, .y = app.slot_ys[slot] - gap - 1, .width = rule_end - code_x, .height = 2 }, clip, color);
        _ = cx.drawing().layer(previous);
    }

    /// The dragged section's heading at the pointer, above everything.
    fn draw_ghost(app: *const App, cx: *Context) void {
        const index = app.dragged_section(cx) orelse return;
        const clip = cx.clip() orelse return;
        const drag = cx.dragging().?;
        const bytes = app.editor.buffer.line_bytes(app.sections[index].line);
        const previous = cx.drawing().layer(.popup);
        const style = look.style(.serif_bold, look.code_size * patch.scales[1], look.ink);
        const box: Rect = .{ .x = drag.x + 12, .y = drag.y - heading_h * 0.5, .width = text.measure(style, bytes), .height = heading_h };
        // On a plate, or the ghost is a smear over the heading it passes.
        const plate: Rect = .{ .x = box.x - 8, .y = box.y - 2, .width = box.width + 16, .height = box.height + 4 };
        look.fill(cx, plate, clip, look.with_alpha(look.cell, 0.9));
        kit.label(cx, style, bytes, box, clip, look.start);
        _ = cx.drawing().layer(previous);
    }

    fn draw_compander(app: *App, cx: *Context, rect: Rect, placed: *const Placed) void {
        const clip = cx.visible(rect) orelse return;
        const alpha: f32 = if (app.comp_on.on and placed.compander_on) 1 else 0.4;
        for (&app.comp, comp_params, 0..) |*knob, param, index| {
            const box: Rect = .{ .x = code_x + @as(f32, @floatFromInt(index)) * (comp_box + 2), .y = rect.y + (rect.height - comp_box) * 0.5, .width = comp_box, .height = comp_box };
            knob_at(cx, knob, box, param);
        }
        const plot_x = code_x + comp_params.len * (comp_box + 2) + 12;
        const plot: Rect = .{ .x = plot_x, .y = rect.y + 8, .width = plot_w, .height = plot_h };
        var bins: [signal.bins]f32 = undefined;
        var line_bins: [signal.bins]f32 = undefined;
        signal.spectrum(&bins, signal.pads, app.t);
        signal.spectrum(&line_bins, signal.line, app.t);
        for (&bins, line_bins) |*bin, other| bin.* = @max(bin.*, other) * 0.9;
        const spectrum_rect: Rect = .{ .x = plot_x + plot_w + 16, .y = plot.y, .width = plot_w, .height = plot_h };
        plots.fill(cx, spectrum_rect, clip, &bins, look.with_alpha(.{ 0.38, 0.38, 0.40, 1 }, alpha), look.with_alpha(look.channel_colors[1], alpha));
        plots.transfer(cx, plot, clip, app.curve(), alpha);
    }

    fn curve(app: *const App) plots.Compander {
        return .{
            .below = comp_params[0].display(app.comp[0].value),
            .up = comp_params[1].display(app.comp[1].value),
            .above = comp_params[2].display(app.comp[2].value),
            .down = comp_params[3].display(app.comp[3].value),
            .most = comp_params[4].display(app.comp[4].value),
            .makeup = comp_params[7].display(app.comp[7].value),
        };
    }

    fn draw_mixer(app: *App, cx: *Context, rect: Rect, sound: Mixdown) void {
        const clip = cx.visible(rect) orelse return;
        look.hline(cx, code_x, rule_end, rect.y + 4, clip, look.rule);
        for (&app.strips, 0..) |*strip, index| {
            const x = code_x + @as(f32, @floatFromInt(index)) * (strip_w + strip_gap);
            app.draw_strip(cx, strip, @intCast(index), x, rect.y + 14, clip, sound);
        }
    }

    fn draw_strip(app: *const App, cx: *Context, strip: *Strip, index: u32, x: f32, y: f32, clip: Clip, sound: Mixdown) void {
        const master = index + 1 == strip_count;
        const color = strip_color(index);
        const tab: Rect = .{ .x = x, .y = y, .width = strip_w, .height = 20 };
        if (!master) look.fill(cx, tab, clip, color);
        const ink = if (master) look.dim else look.with_alpha(.{ 0.08, 0.08, 0.08, 1 }, 0.85);
        kit.label(cx, look.style(.serif_italic, 13, ink), strip_names[index], tab, clip, look.centered);
        look.vline(cx, x, y + 20, y + body_y + body_h, clip, look.with_alpha(color, if (master) 0.3 else 0.6));
        knob_at(cx, &strip.pan, .{ .x = x + 10, .y = y + 26, .width = strip_ring, .height = strip_ring }, pan_param);
        const send_box: Rect = .{ .x = x + 70, .y = y + 26, .width = strip_ring, .height = strip_ring };
        if (!master) knob_at(cx, &strip.send, send_box, send_param);
        strip.mute.paint = toggle_paint(strip.muted, .{ 0.95, 0.55, 0.30, 1 });
        strip.solo.paint = toggle_paint(strip.soloed, .{ 0.92, 0.82, 0.30, 1 });
        const mute_box: Rect = .{ .x = x + 2, .y = y + 76, .width = 56, .height = 20 };
        place_button(cx, &strip.mute, mute_box);
        if (!master) place_button(cx, &strip.solo, .{ .x = x + 62, .y = y + 76, .width = 56, .height = 20 });
        const body: Rect = .{ .x = x, .y = y + body_y, .width = strip_w, .height = body_h };
        var scope: [signal.scope_points]f32 = undefined;
        var spectrum: [signal.bins]f32 = undefined;
        app.strip_signal(index, sound, &scope, &spectrum);
        plots.upright(cx, .{ .x = body.x + 2, .y = body.y, .width = 38, .height = body.height }, clip, &scope, 0.5, 0.48, true, .{ 0.84, 0.84, 0.86, 0.9 });
        const fader_box: Rect = .{ .x = body.x + 54, .y = body.y, .width = 28, .height = body.height };
        strip.fader.draw(cx, fader_box, if (master) look.dim else color, sound.meter[index]);
        if (index < 4) {
            app.dim_unbound(cx, offset_slot(.level_0, index), fader_box);
            app.dim_unbound(cx, offset_slot(.send_0, index), send_box);
        }
        if (index < 2) app.dim_unbound(cx, offset_slot(.mute_0, index), mute_box);
        const spectrum_color = if (master) look.with_alpha(look.white, 0.6) else look.with_alpha(color, 0.85);
        plots.upright(cx, .{ .x = body.x + 86, .y = body.y + 4, .width = 34, .height = body.height - 8 }, clip, &spectrum, 0, 0.95, false, spectrum_color);
        var level: [12]u8 = undefined;
        var peak: [8]u8 = undefined;
        const db = strip.fader.db();
        const level_text = if (@abs(db) < 0.005) "0db" else std.fmt.bufPrint(&level, "{d:.2}db", .{db}) catch unreachable;
        readout(cx, .{ .x = x, .y = y + body_y + body_h + 4, .width = 58, .height = 18 }, clip, level_text);
        readout(cx, .{ .x = x + 62, .y = y + body_y + body_h + 4, .width = 58, .height = 18 }, clip, decibel_label(&peak, sound.db[index]));
    }

    /// The scope and spectrum of strip `index`: a channel scaled by its gain, or the master's
    /// sum and loudest bins.
    fn strip_signal(app: *const App, index: u32, sound: Mixdown, scope: *[signal.scope_points]f32, spectrum: *[signal.bins]f32) void {
        if (index < signal.channel_count) {
            signal.scope(scope, index, app.t);
            signal.spectrum(spectrum, index, app.t);
            for (scope) |*value| value.* *= @min(1, sound.gain[index] * 1.4);
            for (spectrum) |*value| value.* *= @min(1, sound.gain[index] * 1.2);
            return;
        }
        scope.* = @splat(0);
        spectrum.* = @splat(0);
        var channel: u32 = 0;
        while (channel < signal.channel_count) : (channel += 1) {
            var one: [signal.scope_points]f32 = undefined;
            var bins: [signal.bins]f32 = undefined;
            signal.scope(&one, channel, app.t);
            signal.spectrum(&bins, channel, app.t);
            for (scope, one) |*sum, value| sum.* += value * sound.gain[channel] * sound.master * 0.5;
            for (spectrum, bins) |*loudest, value| loudest.* = @max(loudest.*, value * sound.gain[channel] * sound.master);
        }
        for (scope) |*value| value.* = std.math.clamp(value.*, -1, 1);
        for (spectrum) |*value| value.* = std.math.clamp(value.*, 0, 1);
    }

    // ------------------------------------------------------------------------ after the rows

    fn draw_folds(app: *const App, cx: *Context, placed: *const Placed) void {
        _ = app;
        const clip = cx.clip() orelse return;
        for (placed.first_y, placed.last_y) |top, bottom| {
            if (!(bottom > top)) continue;
            look.vline(cx, fold_x, top + 4, bottom - 4, clip, look.faint);
            look.hline(cx, fold_x, fold_x + 7, top + 4, clip, look.faint);
            look.hline(cx, fold_x, fold_x + 7, bottom - 5, clip, look.faint);
        }
    }

    /// The tee from the "mixer" call down to its strips.
    fn draw_connector(app: *const App, cx: *Context, placed: *const Placed) void {
        _ = app;
        const clip = cx.clip() orelse return;
        const word = placed.mixer_word;
        if (!(word[1] > word[0])) return;
        const top = (placed.mixer_top orelse return) + 4;
        const mid = (word[0] + word[1]) * 0.5;
        const tee = [_]Point{ .{ word[0], placed.mixer_line }, .{ word[1], placed.mixer_line } };
        const stem = [_]Point{ .{ mid, placed.mixer_line }, .{ mid, top } };
        _ = kit.stroke(cx, &tee, clip, look.dim, 1.2);
        _ = kit.stroke(cx, &stem, clip, look.dim, 1.2);
    }

    /// The toggles and knobs of section 2, each at its line or pushed below the one above.
    fn draw_side(app: *App, cx: *Context, placed: *const Placed) void {
        const toggles = [_]*const SideToggle{ &app.comp_on, &app.eq_on, &app.shimmer_on };
        var bottom: f32 = -std.math.inf(f32);
        for (placed.toggle_y, toggles) |centre, toggle| {
            const top = @max(centre - look.pill_row_h * 0.5 + 6, bottom + 4);
            bottom = top + look.pill_row_h;
            const box: Rect = .{ .x = toggle_x, .y = top, .width = toggle_w, .height = look.pill_row_h };
            _ = cx.begin_at(box, .{ .flow = .overlay });
            toggle.draw(cx, ui.sized(.fill, .fill));
            _ = cx.end();
            if (toggle == toggles[1]) app.dim_unbound(cx, .eq_on, box);
            if (toggle == toggles[2]) app.dim_unbound(cx, .shimmer_on, box);
        }
        bottom = -std.math.inf(f32);
        for (placed.knob_y, 0..) |centre, index| {
            const top = @max(centre - side_ring * 0.5, bottom + 6);
            bottom = top + side_ring;
            const box: Rect = .{ .x = side_knob_x + (side_knob_w - side_ring) * 0.5, .y = top, .width = side_ring, .height = side_ring };
            if (index == 0) knob_at(cx, &app.shimmer, box, shimmer_param) else knob_at(cx, &app.wet, box, wet_param);
            app.dim_unbound(cx, if (index == 0) .shimmer else .wet, box);
        }
    }

    fn draw_card(app: *App, cx: *Context, bottom: Bottom) void {
        const card = bottom.card;
        const octave_rect = bottom.octave;
        const overview_rect = bottom.overview;
        const clip = cx.visible(card) orelse return;
        kit.face(cx, card, clip, .{ .fill = card_fill, .radius = 6 });
        kit.face(cx, .{ .x = octave_rect.x, .y = octave_rect.y, .width = octave_rect.width, .height = octave_rect.height * 0.5 }, clip, .{ .fill = .{ 0.80, 0.80, 0.80, 1 }, .radius = 2 });
        kit.face(cx, .{ .x = octave_rect.x, .y = octave_rect.y + octave_rect.height * 0.5, .width = octave_rect.width, .height = octave_rect.height * 0.5 }, clip, .{ .fill = card_accent, .radius = 2 });
        app.keyboard.draw(cx, bottom.keys);
        _ = quads.wave.append(cx.drawing(), overview_rect.array(), clip.array(), &app.overview, .{ .color = .{ 0.42, 0.42, 0.45, 1 }, .rms_color = null });
        const head = overview_rect.x + overview_rect.width * app.t / song_s;
        const previous = cx.drawing().layer(look.over_layer);
        look.fill(cx, .{ .x = head, .y = overview_rect.y - 2, .width = 1.5, .height = overview_rect.height + 4 }, clip, card_accent);
        _ = cx.drawing().layer(previous);
        app.draw_transport(cx, clip, overview_rect);
    }

    fn draw_transport(app: *const App, cx: *Context, clip: Clip, overview_rect: Rect) void {
        const y = overview_rect.y + overview_rect.height * 0.5;
        // The spinner: a three-quarter ring turning with time while playing. An Arc's start is
        // the theme's, so a turning ring is a stroke.
        var ring: [19]Point = undefined;
        const turn = if (app.playing) app.t * 4 else 0;
        for (&ring, 0..) |*point, index| {
            const angle = turn + @as(f32, @floatFromInt(index)) / 18 * std.math.pi * 1.5;
            point.* = .{ 1112 + 6 * @cos(angle), y + 6 * @sin(angle) };
        }
        _ = kit.stroke(cx, &ring, clip, card_ink, 1.5);
        const board: Rect = .{ .x = 1126, .y = y - 6, .width = 20, .height = 12 };
        kit.face(cx, board, clip, .{ .fill = card_fill, .border_color = card_ink, .border_width = 1.2, .radius = 2 });
        var key: u32 = 0;
        while (key < 4) : (key += 1) {
            look.fill(cx, .{ .x = board.x + 3 + @as(f32, @floatFromInt(key)) * 4, .y = board.y + 3, .width = 2, .height = 2 }, clip, card_ink);
        }
        look.fill(cx, .{ .x = board.x + 5, .y = board.y + 7, .width = 10, .height = 1.5 }, clip, card_ink);
        const loop_box: Rect = .{ .x = 1152, .y = overview_rect.y - 2, .width = 30, .height = 20 };
        kit.label(cx, look.style(.serif, 14, if (app.looping) card_ink else look.dim), "loop", loop_box, clip, look.centered);
        cx.area(loop_id, loop_box, 0, ui.cx.plain);
        const play_box: Rect = .{ .x = 1186, .y = y - 7, .width = 14, .height = 14 };
        if (app.playing) {
            look.fill(cx, .{ .x = play_box.x + 2, .y = play_box.y + 1, .width = 3.5, .height = 12 }, clip, card_ink);
            look.fill(cx, .{ .x = play_box.x + 8.5, .y = play_box.y + 1, .width = 3.5, .height = 12 }, clip, card_ink);
        } else {
            const triangle = [_]Point{ .{ play_box.x + 3, play_box.y + 1 }, .{ play_box.x + 12, y }, .{ play_box.x + 3, play_box.y + 13 }, .{ play_box.x + 3, play_box.y + 1 } };
            _ = kit.stroke(cx, &triangle, clip, card_ink, 2);
        }
        cx.area(play_id, play_box, 0, ui.cx.plain);
        var position: [16]u8 = undefined;
        kit.label(cx, look.style(.serif, 14, card_ink), position_text(&position, app.t), .{ .x = 1206, .y = overview_rect.y - 2, .width = 62, .height = 20 }, clip, look.start);
    }
};

// ---------------------------------------------------------------------------- helpers

/// The card at the bottom of `screen` and what it holds (section 2).
const Bottom = struct { card: Rect, octave: Rect, keys: Rect, overview: Rect };

fn bottom_of(screen: Rect) Bottom {
    const y = screen.y + screen.height - card_h - 4;
    return .{
        .card = .{ .x = screen.x + 8, .y = y, .width = @max(1, screen.width - 16), .height = card_h },
        .octave = .{ .x = screen.x + 16, .y = y + 6, .width = 36, .height = 48 },
        .keys = .{ .x = screen.x + 60, .y = y + 6, .width = keys.key_w * keys.white_count, .height = 48 },
        .overview = .{ .x = screen.x + 16, .y = y + 60, .width = overview_w, .height = 16 },
    };
}

/// The margin widget of a line, by what the line starts with: lines move as the text is edited.
fn margin_of(bytes: []const u8) Margin {
    const code_bytes = std.mem.trimStart(u8, bytes, " ");
    const margins = [_]struct { prefix: []const u8, margin: Margin }{
        .{ .prefix = "if (tog(1, \"eq\")", .margin = .modulator },
        .{ .prefix = "if (tog(0, \"eq\")", .margin = .modulator },
        .{ .prefix = "wet :=", .margin = .wet },
        .{ .prefix = "mixed := mixer", .margin = .master },
        .{ .prefix = "env :=", .margin = .envelope },
        .{ .prefix = "a :=", .margin = .saws },
        .{ .prefix = "b :=", .margin = .sub },
        .{ .prefix = "hiss :=", .margin = .noise },
        .{ .prefix = "mixed :=", .margin = .pad_mix },
        .{ .prefix = "return mixed", .margin = .response },
    };
    for (margins) |entry| {
        if (std.mem.startsWith(u8, code_bytes, entry.prefix)) return entry.margin;
    }
    return .none;
}

/// How much a widget with no call fades (section 3).
const unbound_veil: f32 = 0.6;

/// Fades what is drawn under `rect` toward the background, above the base layer's glyphs.
fn veil(cx: *Context, rect: Rect, clip: Clip, amount: f32) void {
    const previous = cx.drawing().layer(look.over_layer);
    look.fill(cx, rect, clip, look.with_alpha(look.background, amount));
    _ = cx.drawing().layer(previous);
}

/// Sets a toggle from the text: no animation, because nothing was pressed.
fn set_toggle(toggle: *SideToggle, on: bool) void {
    toggle.on = on;
    toggle.thumb = kit.settled(kit.hover_rate_per_ms, on);
}

fn strip_of(slot: Slot, first: Slot) usize {
    return @backingInt(slot) - @backingInt(first);
}

fn offset_slot(first: Slot, index: u32) Slot {
    return @fromBackingInt(@backingInt(first) + @as(u8, @intCast(index)));
}

/// The value of `value` as a unit position between its ends.
fn unit_of(value: bindings.Value) f32 {
    return std.math.clamp((value.number - value.lo) / (value.hi - value.lo), 0, 1);
}

/// The editor's look: the patch's classes over the screen's own colours, with no gutter.
fn editor_style() Editor.Style {
    var palette = Editor.default_palette;
    palette.background = look.background;
    palette.current_line = look.with_alpha(look.white, 0.05);
    palette.caret = look.white;
    return .{ .size = look.code_size, .palette = palette, .gutter = false };
}

fn paint(color: [4]f32) widgets.Paint {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3], .radius = 0 };
}

fn strip_color(index: u32) [4]f32 {
    return if (index < look.channel_colors.len) look.channel_colors[index] else look.dim;
}

fn small_button(id: ui.Id, label: []const u8) widgets.Button {
    return .{
        .id = id,
        .label = label,
        .style = look.style(.serif, 12, look.ink),
        .padding = .xy(2, 0),
        .paint = toggle_paint(false, look.white),
        .hover = .init(widgets.hover_rate_per_ms),
        .down = .init(widgets.down_rate_per_ms),
    };
}

fn toggle_paint(on: bool, color: [4]f32) widgets.Paint {
    const fill = if (on) look.with_alpha(color, 0.75) else [4]f32{ 0.17, 0.17, 0.18, 1 };
    return .{ .r = fill[0], .g = fill[1], .b = fill[2], .a = fill[3], .radius = 2 };
}

/// A widget whose `draw` takes a walk, drawn into `rect`: a free container around it.
fn place_button(cx: *Context, button: *const widgets.Button, rect: Rect) void {
    _ = cx.begin_at(rect, .{ .flow = .overlay });
    button.draw(cx, ui.sized(.fill, .fill));
    _ = cx.end();
}

/// A ring knob in `box` with its value text in `param`'s units.
fn knob_at(cx: *Context, knob: anytype, box: Rect, param: Param) void {
    var out: [12]u8 = undefined;
    _ = cx.begin_at(box, .{ .flow = .overlay });
    knob.draw_text(cx, ui.sized(.fill, .fill), param.format(&out, knob.value));
    _ = cx.end();
}

fn readout(cx: *Context, rect: Rect, clip: Clip, bytes: []const u8) void {
    look.fill(cx, rect, clip, look.cell);
    kit.label(cx, look.style(.serif, 12, look.ink), bytes, rect, clip, look.centered);
}

fn level_bars(cx: *Context, box: Rect, clip: Clip, param_db: f32, pads_db: f32, color: [4]f32) void {
    var label: [8]u8 = undefined;
    const shown = std.fmt.bufPrint(&label, "{d:.0}", .{param_db}) catch unreachable;
    // The bar follows the line's own level, breathing a few decibels with the pads.
    const live = param_db + 8 + (pads_db + 12) * 0.25;
    plots.bars(cx, box, clip, shown, live, live - 1.5, color);
}

fn decibel_label(out: *[8]u8, db: f32) []const u8 {
    if (db <= -59.95) return "-inf";
    return std.fmt.bufPrint(out, "{d:.1}", .{db}) catch unreachable;
}

fn db_gain(db: f32) f32 {
    if (db <= fader_file.db_lo) return 0;
    return std.math.pow(f32, 10, db / 20);
}

/// The eq's modulator: `m(range=-1~4, period=25s)` at `t`.
fn modulator(t: f32) f32 {
    return 1.5 + 2.5 * @sin(2 * std.math.pi * t / 25);
}

/// Bars and ticks as the photo prints them: bars in hex from 0x1e0, then the bar's fraction
/// in 256ths.
fn position_text(out: *[16]u8, t: f32) []const u8 {
    const beats = t * bpm / 60;
    const bar: u32 = 0x1e0 + @as(u32, @intFromFloat(@floor(beats / 4)));
    const tick: u32 = @intFromFloat(@floor((beats / 4 - @floor(beats / 4)) * 256));
    return std.fmt.bufPrint(out, "{x}.{x:0>2}", .{ bar, tick }) catch unreachable;
}

/// The song's overview: an arrangement of loud and quiet parts, deterministic.
fn build_overview(out: *[overview_columns]quads.wave.Column) void {
    for (out, 0..) |*column, index| {
        const t = @as(f32, @floatFromInt(index)) / overview_columns;
        const part = @floor(t * 8);
        const loud: f32 = switch (@as(u32, @intFromFloat(part))) {
            0 => 0.25,
            1, 2 => 0.55,
            3 => 0.35,
            4, 5, 6 => 0.85,
            else => 0.4,
        };
        const wobble = 0.75 + 0.25 * signal.noise(@as(f32, @floatFromInt(index)) * 1.7);
        const amp = std.math.clamp(loud * wobble, 0.05, 1);
        column.* = .{ .min = -amp * (0.8 + 0.2 * signal.noise(@as(f32, @floatFromInt(index)) * 3.1)), .max = amp, .rms = amp * 0.6 };
    }
}

// ---------------------------------------------------------------------------- scenarios

/// The view's content height minus its 628 px viewport is the scroll range (622 px); a
/// 700 px wheel scrolls to the end: the osc, pad, and reverb tank sections.
const scroll_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 4 },
};
/// Play for about a second: meters, scopes, spectra, the modulator, and the playhead move.
const play_steps = [_]bench.Step{
    .{ .click = .{ .id = play_id, .name = "play", .index = 0 } },
    .{ .wait = 30 },
};
/// The bass fader up 20 px, pads muted, line soloed, the eq off, and the pads panned right
/// 18 px (0.15 of the knob: pan 0.3, an arc from the top).
const mix_steps = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("pan", 1), .from_x = 20, .from_y = 20, .dx = 0, .dy = -18 } },
    .{ .drag = .{ .target = bench.area("fader", 0), .from_x = 20, .from_y = 30, .dx = 0, .dy = -20 } },
    .{ .click = bench.area("mute", 1) },
    .{ .click = bench.area("solo", 2) },
    .{ .click = .{ .id = eq_on_id, .name = "eq", .index = 0 } },
    .{ .wait = 4 },
};
/// The compander's "below" knob up 30 px, "down" down 40, and the wet knob up 20.
const knob_steps = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("comp", 0), .from_x = 26, .from_y = 26, .dx = 0, .dy = -30 } },
    .{ .drag = .{ .target = bench.area("comp", 3), .from_x = 26, .from_y = 26, .dx = 0, .dy = 40 } },
    .{ .drag = .{ .target = .{ .id = wet_id, .name = "wet", .index = 0 }, .from_x = 28, .from_y = 28, .dx = 0, .dy = -20 } },
    .{ .wait = 4 },
};
/// A key held with the pointer (E4, the 17th white key: x 60 + 16 * 33 + 10) and the mix section turned off.
const key_steps = [_]bench.Step{
    .{ .click = bench.area("mark", mix) },
    .{ .hold = .{ .target = .{ .id = keyboard_id, .name = "keyboard", .index = 0 }, .from_x = 16 * keys.key_w + 10, .from_y = 40, .dx = 1, .dy = 0 } },
    .{ .wait = 4 },
};
const editor_target: bench.Target = .{ .id = editor_id, .name = "editor", .index = 0 };
/// A point on the pad's `a := n.unison() * saws;` line, from the editor's top-left: past the
/// mix's heading and body, the osc, and the pad's first three lines, each of two gaps.
const a_line_y: f32 = 4 + heading_h + rule_room + 6 * line_h + compander_h + mixer_h + 2 * (section_gap + heading_h + rule_room) + 6 * 22 + 11;
/// The middle of `# reverb tank`: past the rest of the pad and one more gap.
const tank_heading_y: f32 = a_line_y - 11 + 6 * 22 + section_gap + heading_h * 0.5;
/// A click just after `saws`, and the word `unison` in italics.
const after_saws: bench.At = .{ .target = editor_target, .x = 188, .y = a_line_y };
const on_unison: bench.At = .{ .target = editor_target, .x = 96, .y = a_line_y };
const with_ctrl: input.Mods = .{ .shift = false, .ctrl = true, .alt = false, .meta = false };
const with_shift: input.Mods = .{ .shift = true, .ctrl = false, .alt = false, .meta = false };
/// To the end of the document, a click after `saws`, and two characters typed there.
const edit_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .click_at = after_saws },
    .{ .key = .{ .key = .other, .text = "2" } },
    .{ .key = .{ .key = .other, .text = " " } },
    .{ .wait = 4 },
};
/// A double click on `unison`, then Shift+Down across the shorter line under it.
const select_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .click_at = on_unison },
    .{ .click_at = on_unison },
    .{ .key = .{ .key = .down, .text = "", .mods = with_shift } },
    .{ .wait = 4 },
};
/// A click on the pad, the end of the text, and a new section typed there.
const section_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .click_at = after_saws },
    .{ .key = .{ .key = .end, .text = "", .mods = with_ctrl } },
    .{ .key = .{ .key = .enter, .text = "" } },
    .{ .key = .{ .key = .other, .text = "#" } },
    .{ .key = .{ .key = .other, .text = " " } },
    .{ .key = .{ .key = .other, .text = "c" } },
    .{ .key = .{ .key = .other, .text = "h" } },
    .{ .key = .{ .key = .other, .text = "o" } },
    .{ .key = .{ .key = .other, .text = "r" } },
    .{ .key = .{ .key = .other, .text = "u" } },
    .{ .key = .{ .key = .other, .text = "s" } },
    .{ .wait = 4 },
};
/// A click past the end of `# reverb tank` and a character added to its name.
const rename_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .click_at = .{ .target = editor_target, .x = 400, .y = tank_heading_y } },
    .{ .key = .{ .key = .other, .text = "2" } },
    .{ .wait = 4 },
};
const tank_hash: bench.Target = bench.area("hash", 3);
/// `# reverb tank`'s "#" taken up the screen to above `# pad`, held there.
const hold_tank: bench.Drag = .{ .target = tank_hash, .from_x = 6, .from_y = 18, .dx = 0, .dy = -270 };
const hold_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .hold = hold_tank },
    .{ .wait = 2 },
};
const reorder_steps = hold_steps ++ [_]bench.Step{
    .{ .release = .{ .target = tank_hash, .x = 6, .y = 18 - 270 } },
    .{ .wait = 4 },
};
const reorder_undo_steps = reorder_steps ++ [_]bench.Step{
    .{ .key = .{ .key = .z, .text = "", .mods = with_ctrl } },
    .{ .wait = 4 },
};
/// The middle of the line that holds the levels, and of the wet line, from the editor's top.
const mixed_line_y: f32 = 4 + heading_h + rule_room + line_h + compander_h + 3 * line_h + line_h * 0.5;
const wet_line_y: f32 = mixed_line_y - line_h;
/// A click after the "-" of `level = -2.68db`, and a digit typed there.
const bind_type_steps = [_]bench.Step{
    .{ .click_at = .{ .target = editor_target, .x = 343, .y = mixed_line_y } },
    .{ .key = .{ .key = .other, .text = "1" } },
    .{ .wait = 4 },
};
/// The bass fader up 40 px: its digits follow.
const bind_drag_steps = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("fader", 0), .from_x = 20, .from_y = 30, .dx = 0, .dy = -40 } },
    .{ .wait = 4 },
};
const bind_undo_steps = bind_drag_steps ++ [_]bench.Step{
    .{ .key = .{ .key = .z, .text = "", .mods = with_ctrl } },
    .{ .wait = 4 },
};
/// The eq's toggle off: its literal and its line follow.
const bind_toggle_steps = [_]bench.Step{
    .{ .click = .{ .id = eq_on_id, .name = "eq", .index = 0 } },
    .{ .wait = 4 },
};
/// The wet line selected and deleted: the knob and the wet channel's bars lose their anchors.
const bind_break_steps = [_]bench.Step{
    .{ .click_at = .{ .target = editor_target, .x = 40, .y = wet_line_y } },
    .{ .key = .{ .key = .home, .text = "" } },
    .{ .key = .{ .key = .end, .text = "", .mods = with_shift } },
    .{ .key = .{ .key = .backspace, .text = "" } },
    .{ .wait = 4 },
};
/// A word typed after `saws` and taken back: the text is the starting text, the caret stays.
const undo_steps = [_]bench.Step{
    .{ .wheel = .{ .target = .{ .id = view_id, .name = "view", .index = 0 }, .dx = 0, .dy = 700 } },
    .{ .wait = 2 },
    .{ .click_at = after_saws },
    .{ .key = .{ .key = .x, .text = "x" } },
    .{ .key = .{ .key = .y, .text = "y" } },
    .{ .wait = 1 },
    .{ .key = .{ .key = .z, .text = "", .mods = with_ctrl } },
    .{ .wait = 4 },
};

comptime {
    patchwork.app.check(App);
    assert(content_h > view_h);
    // At 1280 by 720 the card is 8..1272 x 634..716 and the keys end inside it.
    const bottom = bottom_of(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    assert(bottom.card.y == 634 and bottom.card.width == 1264);
    assert(bottom.keys.x + bottom.keys.width <= bottom.card.x + bottom.card.width);
    assert(720 - card_space == view_h);
    // The starting text has the 27 lines `patch_h` counts, 4 of them headings.
    assert(std.mem.count(u8, patch_text, "\n") == 26);
    assert(std.mem.count(u8, patch_text, "# ") == 4);
    // A heading in its rows is the 72 px of a gap and a header, and the mixer fits a row.
    assert(section_gap + heading_h + rule_room == 72);
    assert(mixer_h <= patchwork.editor.row_height_max);
    assert(2 * section_cap + 2 <= patchwork.editor.row_cap);
    // The overview's 540 columns are 2 px each.
    assert(overview_w / overview_columns == 2);
    assert(code_x + strip_count * strip_w + (strip_count - 1) * strip_gap < code_end);
}

// ---------------------------------------------------------------------------- tests

test {
    _ = look;
    _ = bindings;
    _ = patch;
    _ = sections_file;
    _ = signal;
    _ = plots;
    _ = fader_file;
    _ = keys;
}

var test_context: Context = undefined;

fn new_app() *App {
    const static = struct {
        var app: App = undefined;
    };
    test_context.init();
    patchwork.app.start(App, &test_context);
    App.init(&static.app, &test_context.draw.textures);
    return &static.app;
}

fn frame(app: *App) void {
    test_context.redraw();
    assert(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
}

fn scenario_app(name: []const u8) !*App {
    const app = new_app();
    frame(app);
    const scenario = bench.find(App.scenarios, name).?;
    // A wait takes its frames from the limit, so count them or the last steps never run.
    var steps_limit: u32 = 1;
    for (scenario.setup) |step| steps_limit += if (step == .wait) step.wait else 1;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, steps_limit);
    frame(app);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
    return app;
}

fn literal(app: *const App, slot: Slot) []const u8 {
    const range = app.parse.get(slot).?.range;
    return app.editor.text()[range.start..range.end];
}

// Locks the first frame: nothing overflows, every slot binds, the widgets start from the text
// (tog 1, shimmer 0.16, wet 0.73, the four levels, the sends), and the view scrolls over the
// document.
test "the first frame binds the patch to its widgets" {
    const app = new_app();
    frame(app);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), app.parse.error_count);
    for (app.parse.values) |value| try std.testing.expect(value != null);
    try std.testing.expect(app.eq_on.on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), app.shimmer.value, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.73), app.wet.value, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2.68), app.strips[0].fader.db(), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -4.11), app.strips[3].fader.db(), 1e-3);
    try std.testing.expectEqual(send_param.position(-60), app.strips[0].send.value);
    try std.testing.expectEqual(send_param.position(0), app.strips[1].send.value);
    try std.testing.expectEqual(content_h, app.view.content_h);
    try std.testing.expectEqual(@as(f32, 1226), content_h);
    try std.testing.expectEqual(@as(u32, 4), app.section_count);
    try std.testing.expect(!app.playing);
    test_context.draw.finalize();
    try std.testing.expectEqual(@as(u32, 0), quads.covered_glyphs(&test_context.draw));
}

// Locks the scenarios' effects: the wheel scrolls 622 px (the whole range), play runs 30
// ticks of 33 ms add 0.99 s, the mix scenario moves the bass fader 20 px (0.1 of the unit) and mutes,
// solos, gates, and pans the pads to 0.65, the knobs move by their drags over 120 px, and the key scenario holds E4
// with the mix section off.
test "scenarios scroll, play, mix, turn, and hold" {
    var app = try scenario_app("scroll");
    try std.testing.expectEqual(content_h - view_h, app.view.scroll_y);
    app = try scenario_app("play");
    try std.testing.expect(app.playing and test_context.timer_on);
    for (0..30) |tick| App.timer(app, &test_context, tick * period_ms);
    try std.testing.expectApproxEqAbs(start_s + 0.99, app.t, 1e-3);
    app = try scenario_app("mix");
    try std.testing.expectApproxEqAbs(fader_file.position(-2.68) + 0.1, app.strips[0].fader.value, 1e-4);
    try std.testing.expect(app.strips[1].muted and app.strips[2].soloed and !app.eq_on.on);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), app.strips[1].pan.value, 1e-4);
    try std.testing.expectEqualStrings("0", literal(app, .eq_on));
    try std.testing.expectEqualStrings("1", literal(app, .mute_1));
    app = try scenario_app("knobs");
    try std.testing.expectApproxEqAbs(comp_params[0].position(-27.7) + 0.25, app.comp[0].value, 1e-4);
    // The release reads the text back, so the knob settles on the two decimals it wrote.
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), app.wet.value, 1e-5);
    app = try scenario_app("keys");
    try std.testing.expect(app.keyboard.held.isSet(64));
    try std.testing.expect(!app.sections[mix].enabled);
}

// Locks the units: dB to one decimal and "0db" at zero, ratios to two, milliseconds on a log
// knob (5 ms at log(50) / log(1000) of the way), percent, and a send of 0 as "-inf".
test "knob values in their units" {
    var out: [12]u8 = undefined;
    try std.testing.expectEqualStrings("-27.7db", comp_params[0].format(&out, comp_params[0].position(-27.7)));
    try std.testing.expectEqualStrings("3.82", comp_params[1].format(&out, comp_params[1].position(3.82)));
    try std.testing.expectEqualStrings("5ms", comp_params[5].format(&out, comp_params[5].position(5)));
    try std.testing.expectEqualStrings("0db", comp_params[7].format(&out, 0.5));
    try std.testing.expectEqualStrings("73.0%", wet_param.format(&out, 0.73));
    try std.testing.expectEqualStrings("-inf", send_param.format(&out, 0));
    var position: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1e1.2c", position_text(&position, 2.35));
}

fn key_press(key: input.Key, typed: []const u8, mods: input.Mods) input.KeyPress {
    var press: input.KeyPress = .{ .key = key, .mods = mods, .repeat = false, .len = @intCast(typed.len), .text = undefined };
    press.text = @splat(0);
    @memcpy(press.text[0..typed.len], typed);
    return press;
}

fn deliver(app: *App, event_value: input.Event) void {
    ui.dispatch(App, app, &test_context, event_value);
}

// Locks that a lost window resets the pointer's note: pressing E4 (x 60 + 16 * 33 + 10), losing
// focus so its release never arrives, and pressing E4 again lights it, where a stale
// `pointer_note` left it dark.
test "the same key plays again after the window loses focus" {
    const app = new_app();
    frame(app);
    const e4: input.Point = .{ .x = 598, .y = 680 };
    deliver(app, .{ .pointer_move = e4 });
    deliver(app, .{ .pointer_down = input.left_at(e4) });
    try std.testing.expect(app.keyboard.held.isSet(64));
    deliver(app, .{ .window_focus = false });
    try std.testing.expectEqual(@as(usize, 0), app.keyboard.held.count());
    deliver(app, .{ .window_focus = true });
    deliver(app, .{ .pointer_down = input.left_at(e4) });
    try std.testing.expect(app.keyboard.held.isSet(64));
}

// Locks the keys a release cannot name: "," and "." arrive as `other` and their releases carry
// no text, so one release lets go of both (C4 and D4) instead of leaving the first stuck.
test "an other key's release lets go of every other note" {
    const app = new_app();
    frame(app);
    deliver(app, .{ .key_down = key_press(.other, ",", .none) });
    deliver(app, .{ .key_down = key_press(.other, ".", .none) });
    try std.testing.expect(app.keyboard.held.isSet(60) and app.keyboard.held.isSet(62));
    deliver(app, .{ .key_up = key_press(.other, "", .none) });
    try std.testing.expectEqual(@as(usize, 0), app.keyboard.held.count());
}

// Locks that a release always counts: z pressed plain and released with Ctrl down lets C3 go,
// while a press with Ctrl down, a shortcut, plays nothing.
test "a note ends on its release whatever the modifiers" {
    const app = new_app();
    frame(app);
    deliver(app, .{ .key_down = key_press(.z, "z", .none) });
    try std.testing.expect(app.keyboard.held.isSet(48));
    var ctrl: input.Mods = .none;
    ctrl.ctrl = true;
    deliver(app, .{ .key_up = key_press(.z, "", ctrl) });
    try std.testing.expectEqual(@as(usize, 0), app.keyboard.held.count());
    deliver(app, .{ .key_down = key_press(.z, "z", ctrl) });
    try std.testing.expectEqual(@as(usize, 0), app.keyboard.held.count());
}

// Locks the edit scenario: a click after `saws` lands there in proportional faces, and with the
// editor focused "2" and Space type, so no note sounds and the transport stays stopped.
test "typing in the patch plays nothing" {
    const app = try scenario_app("edit");
    try std.testing.expect(std.mem.indexOf(u8, app.editor.text(), "* saws2 ;") != null);
    try std.testing.expect(test_context.focused(editor_id));
    try std.testing.expect(!app.playing);
    try std.testing.expectEqual(@as(usize, 0), app.keyboard.held.count());
    // A focused editor is idle: the caret is steady, so nothing is owed and no timer runs.
    try std.testing.expect(!test_context.dirty);
    try std.testing.expect(!test_context.timer_on);
    test_context.draw.finalize();
    try std.testing.expectEqual(@as(u32, 0), quads.covered_glyphs(&test_context.draw));
}

// Locks the select scenario: a double click on `unison` selects it, and Shift+Down keeps the
// caret's x on the next line, so the selection ends inside the 12 of `sine(n - 12)`.
test "selection crosses lines of unequal width" {
    const app = new_app();
    frame(app);
    const scenario = bench.find(App.scenarios, "select").?;
    // Presses 16 ms apart, the regress clock, so the two clicks are one double click.
    _ = try bench.replay_headless_paced(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1), 16);
    frame(app);
    const range = app.editor.selection();
    const picked = app.editor.text()[range.start..range.end];
    try std.testing.expectEqualStrings("unison() * saws;\n      b := sine(n - 1", picked);
    const word_end: u32 = @intCast(std.mem.indexOf(u8, app.editor.text(), "n.unison").? + "n.unison".len);
    const line = app.editor.buffer.line_of(word_end);
    try std.testing.expectEqual(@as(?f32, app.editor.x_of(line, word_end)), app.editor.goal);
}

// Locks the undo scenario: Ctrl+Z takes back the word, so the text is the one loaded.
test "undo restores the patch" {
    const app = try scenario_app("undo");
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

// Locks the wheel through the editor: it fits its height and has no horizontal range, so a wheel
// over it scrolls the document around it.
test "the wheel over the editor scrolls the document" {
    const app = new_app();
    frame(app);
    frame(app);
    const port = app.editor.viewport();
    const y = @min(port.y + 40, 600);
    deliver(app, .{ .wheel = .{ .x = 400, .y = y, .dx = 0, .dy = 30 } });
    try std.testing.expectEqual(@as(f32, 30), app.view.scroll_y);
}

// Locks a Space outside the editor: it still plays.
test "Space plays outside the editor" {
    const app = new_app();
    frame(app);
    deliver(app, .{ .key_down = key_press(.other, " ", .none) });
    try std.testing.expect(app.playing);
}

// Locks the section scenario: "# chorus" typed at the end of the text is a section at once, its
// colour the next in the cycle, in a taller line, with a mark of its own.
test "typing a heading adds a section" {
    const app = try scenario_app("section");
    try std.testing.expect(std.mem.endsWith(u8, app.editor.text(), "\n# chorus"));
    try std.testing.expectEqual(@as(u32, 5), app.section_count);
    try std.testing.expect(test_context.find(mark_id(4)) != null);
    const last = app.editor.buffer.line_count - 1;
    try std.testing.expectEqual(heading_h, app.editor.rect_of(app.editor.buffer.line_range(last).start).height);
}

// Locks the rename scenario: the name is real text, the section stays one, and undo restores it.
test "a heading is edited like any line" {
    const app = try scenario_app("rename");
    try std.testing.expect(std.mem.indexOf(u8, app.editor.text(), "# reverb tank2\n") != null);
    try std.testing.expectEqual(@as(u32, 4), app.section_count);
    deliver(app, .{ .key_down = key_press(.z, "", with_ctrl) });
    frame(app);
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

fn section_line(app: *const App, name: []const u8) u32 {
    const at = std.mem.indexOf(u8, app.editor.text(), name).?;
    return app.editor.buffer.line_of(@intCast(at));
}

fn insert_section(app: *App, name: []const u8, before: []const u8) void {
    const at: u32 = @intCast(std.mem.indexOf(u8, app.editor.text(), before).?);
    assert(app.editor.replace(.{ .start = at, .end = at }, name));
    frame(app);
}

// Locks a section's state by name: pad turned off stays off when a section is inserted above it,
// though its index moved.
test "a section stays off across edits around it" {
    const app = new_app();
    frame(app);
    app.sections[2].enabled = false;
    insert_section(app, "# chorus\n", "# pad");
    try std.testing.expectEqual(@as(u32, 5), app.section_count);
    try std.testing.expect(app.sections[2].enabled);
    try std.testing.expect(!app.sections[3].enabled);
    insert_section(app, "x", " tank");
    try std.testing.expectEqual(@as(u32, 5), app.section_count);
}

fn set_heading(app: *App, line: u32, heading: []const u8) void {
    const range = app.editor.buffer.line_range(line);
    assert(app.editor.replace(.{ .start = range.start, .end = range.end }, heading));
    frame(app);
}

// Locks `# mix` as an ordinary heading: renaming it or deleting it touches no widget, and every
// binding and both rows stay, because they are found from the text and not from the section.
test "the mix heading is a heading like any other" {
    const app = new_app();
    frame(app);
    const height = app.editor.content_height();
    set_heading(app, 0, "# Bus");
    try std.testing.expectEqual(height, app.editor.content_height());
    try std.testing.expect(test_context.find(fader_id(0)) != null);
    const range = app.editor.buffer.line_range(0);
    try std.testing.expect(app.editor.replace(.{ .start = range.start, .end = range.end + 1 }, ""));
    frame(app);
    try std.testing.expect(test_context.find(fader_id(0)) != null);
    for (app.parse.values) |value| try std.testing.expect(value != null);
}

// Locks deleting a heading: its lines join the section before, whose fold bracket grows.
test "deleting a heading merges its lines into the section before" {
    const app = new_app();
    frame(app);
    const line = section_line(app, "# pad");
    const range = app.editor.buffer.line_range(line);
    try std.testing.expect(app.editor.replace(.{ .start = range.start, .end = range.end + 1 }, ""));
    frame(app);
    try std.testing.expectEqual(@as(u32, 3), app.section_count);
}

// Locks the reorder scenario: `# reverb tank` dropped above `# pad` moves its whole section, gives
// the editor focus, and leaves four sections in the new order.
test "dragging a heading's hash moves its section" {
    const app = try scenario_app("reorder");
    const text_now = app.editor.text();
    const tank = std.mem.indexOf(u8, text_now, "# reverb tank").?;
    const pad = std.mem.indexOf(u8, text_now, "# pad").?;
    try std.testing.expect(tank < pad);
    try std.testing.expect(std.mem.endsWith(u8, text_now, "env.gate;\n}"));
    try std.testing.expectEqual(patch_text.len, text_now.len);
    try std.testing.expectEqual(@as(u32, 4), app.section_count);
    try std.testing.expect(test_context.focused(editor_id));
}

// Locks the undo of a move: one Ctrl+Z restores the text byte for byte.
test "one undo restores the order" {
    const app = try scenario_app("reorder-undo");
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

// Locks the wheel and Escape in flight: the wheel still scrolls the document during a drag, and
// Escape ends the drag with nothing moved, the release that follows included.
test "a held drag scrolls and Escape cancels it" {
    const app = try scenario_app("reorder-hold");
    try std.testing.expect(app.dragged_section(&test_context) != null);
    const before = app.view.scroll_y;
    deliver(app, .{ .wheel = .{ .x = 400, .y = 300, .dx = 0, .dy = -30 } });
    try std.testing.expectEqual(before - 30, app.view.scroll_y);
    frame(app);
    deliver(app, .{ .key_down = key_press(.escape, "", .none) });
    try std.testing.expectEqual(@as(?u32, null), app.dragged_section(&test_context));
    deliver(app, .{ .pointer_up = input.left_at(.{ .x = 200, .y = 200 }) });
    frame(app);
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

// Locks the handle against the text: a click on the "#" moves nothing and places no caret, and a
// click on the name beside it still does.
test "the hash is a handle and the name is text" {
    const app = new_app();
    frame(app);
    frame(app);
    const handle = test_context.find(hash_id(0)).?;
    const on_hash: input.Point = .{ .x = handle.rect[0] + 4, .y = handle.rect[1] + 10 };
    deliver(app, .{ .pointer_move = on_hash });
    deliver(app, .{ .pointer_down = input.left_at(on_hash) });
    deliver(app, .{ .pointer_up = input.left_at(on_hash) });
    try std.testing.expect(!test_context.focused(editor_id));
    const on_name: input.Point = .{ .x = handle.rect[0] + 45, .y = on_hash.y };
    deliver(app, .{ .pointer_move = on_name });
    deliver(app, .{ .pointer_down = input.left_at(on_name) });
    deliver(app, .{ .pointer_up = input.left_at(on_name) });
    try std.testing.expect(test_context.focused(editor_id));
    try std.testing.expect(app.editor.caret > 0);
}

// Locks what travels with a section: a caret stays on its word, a section off stays off under its
// name, and a slot beside the section makes no edit.
test "a move carries the caret and the section's state" {
    const app = new_app();
    frame(app);
    const revision = app.editor.revision();
    try std.testing.expect(!app.move_section(2, 2));
    try std.testing.expect(!app.move_section(2, 3));
    try std.testing.expectEqual(revision, app.editor.revision());
    const word: u32 = @intCast(std.mem.indexOf(u8, app.editor.text(), "diffused :=").?);
    app.editor.caret = word;
    app.editor.anchor = word;
    app.sections[3].enabled = false;
    try std.testing.expect(app.move_section(3, 1));
    frame(app);
    try std.testing.expect(std.mem.startsWith(u8, app.editor.text()[app.editor.caret..], "diffused :="));
    try std.testing.expect(!app.sections[1].enabled);
    try std.testing.expect(app.sections[2].enabled);
}

// Locks the mix in a move: moved below `# osc`, its rows follow their lines, and a fader still
// rewrites its own literal, because the ranges were parsed from the moved text.
test "the mix moves like any section and stays bound" {
    const app = new_app();
    frame(app);
    frame(app);
    const top = test_context.find(fader_id(0)).?.rect[1];
    try std.testing.expect(app.move_section(0, 2));
    frame(app);
    frame(app);
    const moved = test_context.find(fader_id(0)).?;
    try std.testing.expect(moved.rect[1] > top);
    try std.testing.expect(std.mem.startsWith(u8, app.editor.text(), "# osc\n"));
    drag_fader(app, 0, -20);
    try std.testing.expect(!std.mem.eql(u8, "-2.68db", literal(app, .level_0)));
    try std.testing.expectEqual(app.parse.get(.level_1).?.number, @as(f32, -8.45));
    try std.testing.expectEqualStrings("-8.45db", literal(app, .level_1));
}

/// A fader dragged by `dy`, released.
fn drag_fader(app: *App, strip: u32, dy: f32) void {
    const area = test_context.find(fader_id(strip)).?;
    const from: input.Point = .{ .x = area.rect[0] + 20, .y = area.rect[1] + 60 };
    const to: input.Point = .{ .x = from.x, .y = from.y + dy };
    deliver(app, .{ .pointer_move = from });
    deliver(app, .{ .pointer_down = input.left_at(from) });
    deliver(app, .{ .pointer_move = to });
    deliver(app, .{ .pointer_up = input.left_at(to) });
    frame(app);
}

// Locks text to widgets: a typed level moves its fader, a typed tog turns its toggle off, and a
// parse writes nothing, so the revision is the edit's alone and typed digits stay as typed.
test "typing a number moves its widget" {
    const app = new_app();
    frame(app);
    const range = app.parse.get(.level_0).?.range;
    try std.testing.expect(app.editor.replace(.{ .start = range.start, .end = range.end }, "-20db"));
    const revision = app.editor.revision();
    frame(app);
    try std.testing.expectApproxEqAbs(@as(f32, -20), app.strips[0].fader.db(), 1e-3);
    try std.testing.expectEqualStrings("-20db", literal(app, .level_0));
    try std.testing.expectEqual(revision, app.editor.revision());
    const flag = app.parse.get(.eq_on).?.range;
    try std.testing.expect(app.editor.replace(.{ .start = flag.start, .end = flag.end }, "0"));
    frame(app);
    try std.testing.expect(!app.eq_on.on);
}

// Locks the bind-type scenario: a digit typed into a literal moves the fader, and the mix's lines
// take keys like any other: Space typed there plays nothing.
test "the mix's code is text" {
    const app = try scenario_app("bind-type");
    try std.testing.expectEqualStrings("-12.68db", literal(app, .level_0));
    try std.testing.expectApproxEqAbs(@as(f32, -12.68), app.strips[0].fader.db(), 1e-3);
    deliver(app, .{ .key_down = key_press(.other, " ", .none) });
    try std.testing.expect(!app.playing);
}

// Locks widgets to text: a fader's drag rewrites only its literal, as one undo entry, and leaves
// the widgets and text agreeing with a full parse.
test "moving a widget rewrites its literal" {
    const app = try scenario_app("bind-drag");
    try std.testing.expectEqual(@as(u32, 1), app.editor.buffer.undo_count);
    try std.testing.expect(!std.mem.eql(u8, literal(app, .level_0), "-2.68db"));
    try std.testing.expectEqualStrings("-8.45db", literal(app, .level_1));
    const full = bindings.Parse.run(app.editor.text());
    for (app.parse.values, full.values) |shifted, whole| {
        try std.testing.expectEqual(whole.?.range, shifted.?.range);
    }
    try std.testing.expectApproxEqAbs(full.get(.level_0).?.number, app.strips[0].fader.db(), 1e-3);
    try std.testing.expectEqual(Gesture.none, app.gesture);
}

// Locks the bind-undo scenario: Ctrl+Z with nothing focused takes back a whole drag, and the fader
// follows the text back.
test "undo reaches the text with no focus" {
    const app = try scenario_app("bind-undo");
    try std.testing.expect(!test_context.focused(editor_id));
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
    try std.testing.expectApproxEqAbs(@as(f32, -2.68), app.strips[0].fader.db(), 1e-3);
}

// Locks the bind-toggle scenario: a toggle writes its literal, and its line's undo restores it.
test "a toggle writes its literal" {
    const app = try scenario_app("bind-toggle");
    try std.testing.expectEqualStrings("0", literal(app, .eq_on));
    try std.testing.expect(!app.eq_on.on);
    deliver(app, .{ .key_down = key_press(.z, "", with_ctrl) });
    frame(app);
    try std.testing.expect(app.eq_on.on);
}

// Locks an open gesture: during a held drag a key is dropped, Ctrl+Z included, so undo never runs
// inside one; the window going away closes it.
test "a held drag drops keys and a lost window ends it" {
    const app = new_app();
    frame(app);
    frame(app);
    const area = test_context.find(fader_id(0)).?;
    const from: input.Point = .{ .x = area.rect[0] + 20, .y = area.rect[1] + 60 };
    deliver(app, .{ .pointer_move = from });
    deliver(app, .{ .pointer_down = input.left_at(from) });
    deliver(app, .{ .pointer_move = .{ .x = from.x, .y = from.y - 30 } });
    try std.testing.expectEqual(Gesture.drag, app.gesture);
    deliver(app, .{ .key_down = key_press(.z, "", with_ctrl) });
    try std.testing.expectEqual(Gesture.drag, app.gesture);
    deliver(app, .{ .window_focus = false });
    try std.testing.expectEqual(Gesture.none, app.gesture);
}

// Locks a run of wheel notches as one undo entry, ended by the next key, which still gets through.
test "a wheel run is one gesture" {
    const app = new_app();
    frame(app);
    frame(app);
    const area = test_context.find(fader_id(0)).?;
    const wheel: input.Wheel = .{ .x = area.rect[0] + 20, .y = area.rect[1] + 60, .dx = 0, .dy = -8 };
    deliver(app, .{ .wheel = wheel });
    deliver(app, .{ .wheel = wheel });
    try std.testing.expectEqual(Gesture.wheel, app.gesture);
    deliver(app, .{ .key_down = key_press(.z, "", with_ctrl) });
    try std.testing.expectEqual(Gesture.none, app.gesture);
    frame(app);
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

// Locks an unbound widget: with its call deleted the wet knob keeps its value and writes nothing
// when turned; undo brings the call, which binds and gives the knob the text's value again.
test "a widget with no call keeps its value and rebinds" {
    const app = try scenario_app("bind-break");
    try std.testing.expectEqual(@as(?bindings.Value, null), app.parse.get(.wet));
    try std.testing.expectApproxEqAbs(@as(f32, 0.73), app.wet.value, 1e-5);
    const revision = app.editor.revision();
    app.wet.set_value(0.2);
    const area = test_context.find(wet_id).?;
    const from: input.Point = .{ .x = area.rect[0] + 20, .y = area.rect[1] + 20 };
    deliver(app, .{ .pointer_move = from });
    deliver(app, .{ .pointer_down = input.left_at(from) });
    deliver(app, .{ .pointer_move = .{ .x = from.x, .y = from.y - 20 } });
    deliver(app, .{ .pointer_up = input.left_at(from) });
    try std.testing.expectEqual(revision, app.editor.revision());
    try std.testing.expect(app.wet.value > 0.2);
    deliver(app, .{ .pointer_move = .{ .x = 600, .y = 300 } });
    deliver(app, .{ .pointer_down = input.left_at(.{ .x = 600, .y = 300 }) });
    deliver(app, .{ .pointer_up = input.left_at(.{ .x = 600, .y = 300 }) });
    deliver(app, .{ .key_down = key_press(.z, "", with_ctrl) });
    frame(app);
    try std.testing.expect(app.parse.get(.wet) != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.73), app.wet.value, 1e-5);
}

// Locks an error mark: a value out of range binds, clamps, and marks its literal as a decoration.
test "a number out of range is marked and clamps" {
    const app = new_app();
    frame(app);
    const range = app.parse.get(.level_0).?.range;
    try std.testing.expect(app.editor.replace(.{ .start = range.start, .end = range.end }, "99db"));
    frame(app);
    try std.testing.expectEqual(@as(f32, 1), app.strips[0].fader.value);
    try std.testing.expectEqual(@as(u32, 1), app.editor.decoration_count);
    try std.testing.expectEqual(patchwork.editor.Decoration.Kind.@"error", app.editor.decorations[0].kind);
}

// Locks a section's colour as its own: a move keeps each mark's colour, a rename keeps its colour
// and its state letter by letter, and a new section takes the next colour.
test "a section keeps its colour through moves and renames" {
    const app = new_app();
    frame(app);
    const tank_colour = app.sections[3].colour;
    const pad_colour = app.sections[2].colour;
    try std.testing.expect(tank_colour != pad_colour);
    try std.testing.expect(app.move_section(3, 2));
    frame(app);
    try std.testing.expectEqual(tank_colour, app.sections[2].colour);
    try std.testing.expectEqual(pad_colour, app.sections[3].colour);
    app.sections[2].enabled = false;
    insert_section(app, "x", " tank");
    insert_section(app, "y", " tank");
    try std.testing.expectEqual(tank_colour, app.sections[2].colour);
    try std.testing.expect(!app.sections[2].enabled);
    insert_section(app, "# chorus\n", "# pad");
    try std.testing.expectEqual(@as(u8, 0), app.sections[3].colour);
    try std.testing.expectEqual(pad_colour, app.sections[4].colour);
}

// Locks the screen against what editing leaves behind: with each byte of the mix's lines deleted
// in turn, and each of those lines cut at every byte, a frame draws, and undo restores the text
// and every binding.
test "the mix survives any single cut" {
    const app = new_app();
    frame(app);
    const end: u32 = @intCast(std.mem.indexOf(u8, app.editor.text(), "# osc").?);
    var at: u32 = 0;
    while (at < end) : (at += 1) {
        if (!std.unicode.utf8ValidateSlice(app.editor.text()[at .. at + 1])) continue;
        app.editor.caret = 0;
        app.editor.anchor = 0;
        try std.testing.expect(app.editor.replace(.{ .start = at, .end = at + 1 }, ""));
        frame(app);
        try std.testing.expect(app.editor.buffer.undo() != null);
        frame(app);
        const line = app.editor.buffer.line_range(app.editor.buffer.line_of(at));
        if (at < line.end) {
            try std.testing.expect(app.editor.replace(.{ .start = at, .end = line.end }, ""));
            frame(app);
            try std.testing.expect(app.editor.buffer.undo() != null);
            frame(app);
        }
    }
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
    for (app.parse.values) |value| try std.testing.expect(value != null);
}

// Locks what typing can put in the text: each awkward character inserted at every byte of the mix's
// lines draws a frame, and undo restores the text.
test "the mix survives anything typed into it" {
    const app = new_app();
    frame(app);
    const end: u32 = @intCast(std.mem.indexOf(u8, app.editor.text(), "# osc").?);
    for ([_][]const u8{ "-", "\"", "(", "~", "=", ",", "0", "# ", "\n", "\u{3b1}" }) |typed| {
        var at: u32 = 0;
        while (at < end) : (at += 1) {
            if (app.editor.text()[at] & 0xC0 == 0x80) continue;
            app.editor.caret = 0;
            app.editor.anchor = 0;
            try std.testing.expect(app.editor.replace(.{ .start = at, .end = at }, typed));
            frame(app);
            try std.testing.expect(app.editor.buffer.undo() != null);
        }
        frame(app);
    }
    try std.testing.expectEqualStrings(patch_text, app.editor.text());
}

// Locks a knob whose ends the text made wide: its value is a long literal, and moving it writes
// that literal instead of overrunning `literal_cap`.
test "a knob with wide ends writes its literal" {
    const app = new_app();
    frame(app);
    frame(app);
    const range = app.parse.get(.wet).?.range;
    const start = range.start - 2;
    try std.testing.expect(app.editor.replace(.{ .start = start, .end = range.end + 2 }, "0~777777~999999999999"));
    frame(app);
    frame(app);
    try std.testing.expectEqual(@as(u32, 0), app.parse.error_count);
    const area = test_context.find(wet_id).?;
    const from: input.Point = .{ .x = area.rect[0] + 20, .y = area.rect[1] + 20 };
    deliver(app, .{ .pointer_move = from });
    deliver(app, .{ .pointer_down = input.left_at(from) });
    deliver(app, .{ .pointer_move = .{ .x = from.x, .y = from.y - 30 } });
    deliver(app, .{ .pointer_up = input.left_at(from) });
    frame(app);
    try std.testing.expect(app.parse.get(.wet).?.number > 777777);
}

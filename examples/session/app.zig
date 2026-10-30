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
//! types (Box, Waveform, Arc, Path, Glyph), and four pieces the library does not have: code
//! set in a proportional face (`code.zig`), a fader with a stereo meter (`fader.zig`), a piano
//! keyboard (`keys.zig`), and the plots (`plots.zig`). The sound is made up (`signal.zig`).
//!
//! ## 2. Layout (logical pixels, shown at 1280 by 720)
//! The view and the card follow the window: the view is the window's height less
//! `card_space`, and the card spans its width at its bottom. Columns stay where they are.
//! ```text
//! view      0..1280 x 0..628, scrolling: the document's rows, top to bottom
//!   x 18          fold brackets, one per section's lines
//!   x 32..168     margin widgets on their line: sliders, level bars, envelope, response
//!   x 184..1088   code, the compander row, the mixer (five strips 120 wide, 10 apart)
//!   x 1100..1140  toggles; x 1148..1228 knobs: each at its line, pushed down past the last
//! card      8..1272 x 634..716: octave box, keys (36 white, 33 wide, from x 60), the song
//!           overview (540 columns over 1080 px), and the transport
//! ```
//! Rows: a section header is 44 high, a code line 26, the compander row 92, the mixer 324.
//!
//! ## 3. Bindings
//! Widgets own their values; the patch's text is formatted from them every frame (`code.Slots`,
//! `update_slots`): toggles write `tog(1, ...)`, the shimmer and wet knobs their `k(...)`
//! values, faders `level = ...`, send knobs `send = ...`, mutes `mute[i] = ...`. A section's
//! mark turns it off (its code dims); a toggle off dims its line.
//!
//! ## 4. Transport
//! `timer_period_ms` is 33 and the timer starts disarmed: the screen sleeps until Space or
//! the pause/play mark starts it; each tick adds 33 ms to `t`, and meters, scopes, spectra,
//! the modulator, the spinner, the position, and the overview's playhead follow `t`.
//!
//! ## 5. TigerStyle Invariants
//! - Static: the app, its slots, and its overview; nothing allocates.
//! - Per-frame work is bounded by the rows table and the signal's constants.

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
const code = @import("code.zig");
const signal = @import("signal.zig");
const plots = @import("plots.zig");
const fader_file = @import("fader.zig");
const keys = @import("keys.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.Point;
const Context = patchwork.app.Context(App);
const Fader = fader_file.Fader;

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
const line_h: f32 = 26;
const compander_h: f32 = 92;
const mixer_h: f32 = 324;
const module_indent: f32 = 24;
const continue_indent: f32 = 44;

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

const mix: u8 = 0;
const osc: u8 = 1;
const pad: u8 = 2;
const tank: u8 = 3;
const section_names = [_][]const u8{ "mix", "osc", "pad", "reverb tank" };
const section_declared = [_][]const []const u8{
    &.{ "round", "wet", "mixed", "room" },
    &.{},
    &.{ "env", "a", "b", "hiss", "mixed" },
    &.{"diffused"},
};
const channel_names = [_][]const u8{ "bass", "pads", "line", "wet" };
const strip_names = [_][]const u8{ "bass", "pads", "line", "wet", "master" };

const Margin = enum { none, modulator, envelope, response, saws, sub, noise, pad_mix, wet, master };
const Side = enum { none, eq, shimmer, wet };
const Gate = enum { none, eq, shimmer };

const Line = struct {
    section: u8,
    template: []const u8,
    indent: f32 = 0,
    /// Indent to the pen after the previous hanging line's first "(".
    hang: bool = false,
    margin: Margin = .none,
    side: Side = .none,
    gate: Gate = .none,
    rule_above: bool = false,
};

const Row = union(enum) {
    header: u8,
    line: Line,
    compander,
    mixer,
    gap: f32,
};

/// The document (section 2). Slots: a eq, b shimmer on, c shimmer, d wet, e..h levels,
/// i..l sends, m and n the first two mutes.
const rows = [_]Row{
    .{ .header = mix },
    .{ .line = .{ .section = mix, .template = "round := compander(pads + line);" } },
    .compander,
    .{ .line = .{ .section = mix, .template = "if (tog($a, \"eq\")) round = round.tilt(gain = m(range=-1~4, period=25s));", .margin = .modulator, .side = .eq, .gate = .eq, .rule_above = true } },
    .{ .line = .{ .section = mix, .template = "if (tog($b, \"shimmer\")) round = round.pitch_shift(2, 80ms).α(k(0~$c~1, name=\"shimmer\"));", .side = .shimmer, .gate = .shimmer } },
    .{ .line = .{ .section = mix, .template = "wet := room.wet * k(0~$d~1, \"wet\");", .margin = .wet, .side = .wet } },
    .{ .line = .{ .section = mix, .template = "mixed := mixer(bass, pads, line, wet, level = $e, $f, $g, $h,", .margin = .master } },
    .{ .line = .{ .section = mix, .template = "send = $i, $j, $k, $l, pre = 0, 0, 0, safe[3] = 1, mute[0] = $m, mute[1] = $n);", .hang = true } },
    .mixer,
    .{ .gap = 28 },
    .{ .header = osc },
    .{ .line = .{ .section = osc, .template = "module unison(Note n, detune = 0~0.12~1, width = 0~0.8~1) -> ꝏ {" } },
    .{ .line = .{ .section = osc, .template = "return sum (j, 8) => saw(n + j.across(0, 7) * detune, φ = 0~1).pan(j.across(0, 7) * width) * 0.35f;", .indent = module_indent } },
    .{ .line = .{ .section = osc, .template = "}" } },
    .{ .gap = 28 },
    .{ .header = pad },
    .{ .line = .{ .section = pad, .template = "module pad(Note n, saws = 0~0.1~1, sub = 0~0.075~1, noise = 0~0.03~1," } },
    .{ .line = .{ .section = pad, .template = "f = 200hz~3464hz~20000hz) -> ꝏ {", .indent = continue_indent } },
    .{ .line = .{ .section = pad, .template = "env := n.adsr(a = 1.34s, d = 1s, s = 1, r = 1.02s);", .indent = module_indent, .margin = .envelope } },
    .{ .line = .{ .section = pad, .template = "a := n.unison() * saws;", .indent = module_indent, .margin = .saws } },
    .{ .line = .{ .section = pad, .template = "b := sine(n - 12) * sub;", .indent = module_indent, .margin = .sub } },
    .{ .line = .{ .section = pad, .template = "hiss := ꝏ(white_noise(), white_noise()) * noise;", .indent = module_indent, .margin = .noise } },
    .{ .line = .{ .section = pad, .template = "mixed := a + b + hiss;", .indent = module_indent, .margin = .pad_mix } },
    .{ .line = .{ .section = pad, .template = "return mixed.lowpass(f) * env.gate;", .indent = module_indent, .margin = .response } },
    .{ .line = .{ .section = pad, .template = "}" } },
    .{ .gap = 28 },
    .{ .header = tank },
    .{ .line = .{ .section = tank, .template = "module tank(ꝏ audio, ꝏ back, decay = 0~0.93~0.99, damping = 0.05~0.39~1," } },
    .{ .line = .{ .section = tank, .template = "size = 0.5~1.2~2) -> ꝏ {", .indent = continue_indent } },
    .{ .line = .{ .section = tank, .template = "diffused := audio.allpass(142, 107, 379, 277) + back * decay;", .indent = module_indent } },
    .{ .line = .{ .section = tank, .template = "return diffused.delay(size * 4453).lowpass(damping.hz()) * decay;", .indent = module_indent } },
    .{ .line = .{ .section = tank, .template = "}" } },
    .{ .gap = 40 },
};

fn row_height(row: Row) f32 {
    return switch (row) {
        .header => header_h,
        .line => line_h,
        .compander => compander_h,
        .mixer => mixer_h,
        .gap => |px| px,
    };
}

/// The document's height: the view's content.
pub const content_h: f32 = blk: {
    var sum: f32 = 0;
    for (rows) |row| sum += row_height(row);
    break :blk sum;
};

// ---------------------------------------------------------------------------- parameters

const Unit = enum { db, ratio, ms, percent, pan, send };

/// A knob's range in its own units; `log` maps the knob logarithmically.
const Param = struct {
    name: []const u8,
    lo: f32,
    hi: f32,
    initial: f32,
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
const shimmer_param: Param = .{ .name = "shimmer", .lo = 0, .hi = 1, .initial = 0.16, .unit = .percent };
const wet_param: Param = .{ .name = "wet", .lo = 0, .hi = 1, .initial = 0.73, .unit = .percent };
const pan_param: Param = .{ .name = "pan", .lo = -1, .hi = 1, .initial = 0, .unit = .pan };
const send_param: Param = .{ .name = "send", .lo = -60, .hi = 6, .initial = -60, .unit = .send };
const initial_levels = [_]f32{ -2.68, -8.45, -5.14, -4.11, 0 };
const initial_sends = [_]f32{ -60, 0, 0, -60 };

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
const keyboard_id = ui.id("keyboard", 0);
const play_id = ui.id("play", 0);
const loop_id = ui.id("loop", 0);

// ---------------------------------------------------------------------------- pools

const glyph_cap: u32 = 6144;
const box_cap: u32 = 1024;
const arc_cap: u32 = 64;
const path_cap: u32 = 1024;
const wave_cap: u32 = 4;
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
    first_y: [4]f32 = @splat(std.math.inf(f32)),
    last_y: [4]f32 = @splat(-std.math.inf(f32)),
    toggle_y: [3]f32 = @splat(0),
    knob_y: [2]f32 = @splat(0),
    hang_x: f32 = code_x,
    /// The "mixer" word's span and the bottom of its line, and the mixer row's top.
    mixer_word: [2]f32 = .{ 0, 0 },
    mixer_line: f32 = 0,
    mixer_top: f32 = 0,
};

pub const App = struct {
    view: ui.ViewState,
    comp: [comp_params.len]RingKnob,
    shimmer: RingKnob,
    wet: RingKnob,
    comp_on: SideToggle,
    eq_on: SideToggle,
    shimmer_on: SideToggle,
    strips: [strip_count]Strip,
    enabled: [4]bool,
    keyboard: keys.Keyboard,
    playing: bool,
    looping: bool,
    t: f32,
    slots: code.Slots,
    overview: [overview_columns]quads.wave.Column,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork session",
        .timer_period_ms = period_ms,
        .timer_armed = false,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Waveform, .cap = wave_cap },
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
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        app.view = .init();
        for (&app.comp, comp_params, 0..) |*knob, param, index| {
            const accent = look.pastels[index % look.pastels.len];
            knob.* = RingKnob.init(comp_id(@intCast(index)), param.name, param.position(param.initial), paint(accent)).sized(comp_ring);
        }
        app.shimmer = RingKnob.init(shimmer_id, "shimmer", shimmer_param.position(shimmer_param.initial), paint(shimmer_color)).sized(side_ring);
        app.wet = RingKnob.init(wet_id, "wet", wet_param.position(wet_param.initial), paint(look.pastels[2])).sized(side_ring);
        app.comp_on = SideToggle.init(comp_on_id, "compander", true);
        app.comp_on.accent = compander_color;
        app.eq_on = SideToggle.init(eq_on_id, "eq", true);
        app.eq_on.accent = eq_color;
        app.shimmer_on = SideToggle.init(shimmer_on_id, "shimmer", true);
        app.shimmer_on.accent = shimmer_color;
        for (&app.strips, 0..) |*strip, index| {
            const at: u32 = @intCast(index);
            const color = strip_color(at);
            const send = if (index < initial_sends.len) send_param.position(initial_sends[index]) else 0;
            strip.* = .{
                .pan = PanKnob.init(pan_id(at), "pan", 0.5, paint(look.white)).sized(strip_ring),
                .send = RingKnob.init(send_id(at), "send", send, paint(color)).sized(strip_ring),
                .fader = Fader.init(fader_id(at), initial_levels[index]),
                .mute = small_button(mute_id(at), "M"),
                .solo = small_button(solo_id(at), "S"),
            };
        }
        app.enabled = @splat(true);
        app.keyboard = .{ .id = keyboard_id };
        app.playing = false;
        app.looping = true;
        app.t = start_s;
        app.slots = .{};
        build_overview(&app.overview);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
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
        for (&app.enabled, 0..) |*on, section| {
            if (kit.clicked(cx, mark_id(@intCast(section)), event_value)) {
                on.* = !on.*;
                cx.redraw();
            }
        }
        _ = app.keyboard.handle(cx, event_value);
        if (kit.clicked(cx, play_id, event_value)) app.set_playing(cx, !app.playing);
        if (kit.clicked(cx, loop_id, event_value)) {
            app.looping = !app.looping;
            cx.redraw();
        }
        switch (event_value) {
            .key_down => |press| if (kit.is_space(press) and !press.repeat) app.set_playing(cx, !app.playing),
            else => {},
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
        app.update_slots();
        const sound = app.mixdown();
        const screen = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down });
        const viewport_h = @max(line_h, screen.height - card_space);
        _ = cx.begin_view(view_id, ui.sized(.fill, .{ .fixed = viewport_h }), .{ .flow = .down }, &app.view);
        var placed: Placed = .{};
        for (rows) |row| {
            const rect = cx.walk(ui.sized(.fill, .{ .fixed = row_height(row) }));
            switch (row) {
                .gap => {},
                .header => |section| app.draw_header(cx, section, rect),
                .line => |line| app.draw_line(cx, line, rect, &placed, sound),
                .compander => app.draw_compander(cx, rect, &placed),
                .mixer => app.draw_mixer(cx, rect, &placed, sound),
            }
        }
        app.draw_folds(cx, &placed);
        app.draw_connector(cx, &placed);
        app.draw_side(cx, &placed);
        cx.end_view();
        app.draw_card(cx, bottom_of(screen));
        _ = cx.end();
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    // ------------------------------------------------------------------------ bindings

    fn update_slots(app: *App) void {
        const slots = &app.slots;
        slots.set(0, "{d}", .{@intFromBool(app.eq_on.on)});
        slots.set(1, "{d}", .{@intFromBool(app.shimmer_on.on)});
        slots.set(2, "{d:.2}", .{app.shimmer.value});
        slots.set(3, "{d:.2}", .{app.wet.value});
        for (0..4) |index| {
            slots.set(@intCast(4 + index), "{d:.2}db", .{app.strips[index].fader.db()});
            const send = send_param.display(app.strips[index].send.value);
            slots.set(@intCast(8 + index), "{d:.0}db", .{if (@abs(send) < 0.5) 0 else send});
        }
        slots.set(12, "{d}", .{@intFromBool(app.strips[0].muted)});
        slots.set(13, "{d}", .{@intFromBool(app.strips[1].muted)});
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

    fn draw_header(app: *const App, cx: *Context, section: u8, rect: Rect) void {
        const clip = cx.visible(rect) orelse return;
        const title: Rect = .{ .x = code_x - 2, .y = rect.y + 6, .width = 600, .height = rect.height - 12 };
        const hash = look.style(.serif, 24, look.faint);
        kit.label(cx, hash, "#", title, clip, look.start);
        const name: Rect = .{ .x = title.x + text.measure(hash, "# "), .y = title.y, .width = 560, .height = title.height };
        kit.label(cx, look.style(.serif_bold, 26, look.ink), section_names[section], name, clip, look.start);
        look.hline(cx, code_x, rule_end, rect.y + rect.height - 3, clip, look.rule);
        const color = if (app.enabled[section]) look.section_colors[section] else look.faint;
        const box: Rect = .{ .x = mark_x, .y = rect.y + 13, .width = 16, .height = 18 };
        kit.face(cx, box, clip, .{ .fill = look.background, .border_color = color, .border_width = 1.5, .radius = 1 });
        if (app.enabled[section]) look.fill(cx, .{ .x = box.x + 7, .y = box.y + 5, .width = 2, .height = 8 }, clip, color);
        cx.area(mark_id(section), box, 0, ui.cx.plain);
        kit.label(cx, look.style(.serif, 18, look.dim), "+", .{ .x = mark_x + 22, .y = box.y, .width = 16, .height = box.height }, clip, look.centered);
    }

    fn line_context(app: *const App, line: Line) code.Context {
        var alpha: f32 = if (app.enabled[line.section]) 1 else 0.35;
        const gate_on = switch (line.gate) {
            .none => true,
            .eq => app.eq_on.on,
            .shimmer => app.shimmer_on.on,
        };
        if (!gate_on) alpha *= 0.45;
        return .{
            .declared = section_declared[line.section],
            .channels = if (line.section == mix) &channel_names else &.{},
            .alpha = alpha,
        };
    }

    fn draw_line(app: *App, cx: *Context, line: Line, rect: Rect, placed: *Placed, sound: Mixdown) void {
        var buffer: [code.line_cap]u8 = undefined;
        var spans: [code.slot_count]code.Span = undefined;
        const bytes = code.expand(&buffer, line.template, &app.slots, &spans);
        const context = app.line_context(line);
        const x = if (line.hang) placed.hang_x else code_x + line.indent;
        placed.first_y[line.section] = @min(placed.first_y[line.section], rect.y);
        placed.last_y[line.section] = @max(placed.last_y[line.section], rect.y + rect.height);
        if (std.mem.indexOf(u8, bytes, "mixer(")) |at| {
            const word_x = code.x_of(bytes, @intCast(at), x, context);
            placed.mixer_word = .{ word_x, code.x_of(bytes, @intCast(at + 5), x, context) };
            placed.mixer_line = rect.y + rect.height - 2;
            placed.hang_x = code.x_of(bytes, @intCast(at + 6), x, context);
        }
        switch (line.side) {
            .none => {},
            .eq => placed.toggle_y[1] = rect.y + rect.height * 0.5,
            .shimmer => {
                placed.toggle_y[2] = rect.y + rect.height * 0.5;
                placed.knob_y[0] = rect.y + rect.height * 0.5;
            },
            .wet => placed.knob_y[1] = rect.y + rect.height * 0.5,
        }
        const clip = cx.visible(rect) orelse return;
        if (line.rule_above) look.hline(cx, code_x, rule_end, rect.y, clip, look.rule);
        _ = code.draw_line(cx, bytes, x, rect, clip, context);
        app.draw_margin(cx, line, rect, clip, sound);
    }

    fn draw_margin(app: *const App, cx: *Context, line: Line, rect: Rect, clip: Clip, sound: Mixdown) void {
        const box: Rect = .{ .x = margin_x, .y = rect.y + 2, .width = margin_w, .height = rect.height - 4 };
        const pads_db = signal.decibels(signal.level(signal.pads, app.t) * 2.5, -60);
        switch (line.margin) {
            .none => {},
            .modulator => plots.slider(cx, .{ .x = margin_x + 34, .y = box.y, .width = margin_w - 36, .height = box.height }, clip, modulator(app.t), -1, 4, app.line_context(line).alpha),
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

    fn draw_compander(app: *App, cx: *Context, rect: Rect, placed: *Placed) void {
        placed.toggle_y[0] = rect.y + rect.height * 0.5;
        const clip = cx.visible(rect) orelse return;
        const alpha: f32 = if (app.comp_on.on and app.enabled[mix]) 1 else 0.4;
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

    fn draw_mixer(app: *App, cx: *Context, rect: Rect, placed: *Placed, sound: Mixdown) void {
        placed.mixer_top = rect.y + 4;
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
        if (!master) knob_at(cx, &strip.send, .{ .x = x + 70, .y = y + 26, .width = strip_ring, .height = strip_ring }, send_param);
        strip.mute.paint = toggle_paint(strip.muted, .{ 0.95, 0.55, 0.30, 1 });
        strip.solo.paint = toggle_paint(strip.soloed, .{ 0.92, 0.82, 0.30, 1 });
        place_button(cx, &strip.mute, .{ .x = x + 2, .y = y + 76, .width = 56, .height = 20 });
        if (!master) place_button(cx, &strip.solo, .{ .x = x + 62, .y = y + 76, .width = 56, .height = 20 });
        const body: Rect = .{ .x = x, .y = y + body_y, .width = strip_w, .height = body_h };
        var scope: [signal.scope_points]f32 = undefined;
        var spectrum: [signal.bins]f32 = undefined;
        app.strip_signal(index, sound, &scope, &spectrum);
        plots.upright(cx, .{ .x = body.x + 2, .y = body.y, .width = 38, .height = body.height }, clip, &scope, 0.5, 0.48, true, .{ 0.84, 0.84, 0.86, 0.9 });
        strip.fader.draw(cx, .{ .x = body.x + 54, .y = body.y, .width = 28, .height = body.height }, if (master) look.dim else color, sound.meter[index]);
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
        const mid = (word[0] + word[1]) * 0.5;
        const tee = [_]Point{ .{ word[0], placed.mixer_line }, .{ word[1], placed.mixer_line } };
        const stem = [_]Point{ .{ mid, placed.mixer_line }, .{ mid, placed.mixer_top } };
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
            _ = cx.begin_at(.{ .x = toggle_x, .y = top, .width = toggle_w, .height = look.pill_row_h }, .{ .flow = .overlay });
            toggle.draw(cx, ui.sized(.fill, .fill));
            _ = cx.end();
        }
        bottom = -std.math.inf(f32);
        for (placed.knob_y, 0..) |centre, index| {
            const top = @max(centre - side_ring * 0.5, bottom + 6);
            bottom = top + side_ring;
            const box: Rect = .{ .x = side_knob_x + (side_knob_w - side_ring) * 0.5, .y = top, .width = side_ring, .height = side_ring };
            if (index == 0) knob_at(cx, &app.shimmer, box, shimmer_param) else knob_at(cx, &app.wet, box, wet_param);
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

/// The view's content height minus its 628 px viewport is the scroll range (686 px); a
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

comptime {
    patchwork.app.check(App);
    assert(content_h > view_h);
    // At 1280 by 720 the card is 8..1272 x 634..716 and the keys end inside it.
    const bottom = bottom_of(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    assert(bottom.card.y == 634 and bottom.card.width == 1264);
    assert(bottom.keys.x + bottom.keys.width <= bottom.card.x + bottom.card.width);
    assert(720 - card_space == view_h);
    // The spectrum fill's 48 columns are 3 px each.
    assert(plot_w / signal.bins == 3);
    // The overview's 540 columns are 2 px each.
    assert(overview_w / overview_columns == 2);
    assert(code_x + strip_count * strip_w + (strip_count - 1) * strip_gap < code_end);
}

// ---------------------------------------------------------------------------- tests

test {
    _ = look;
    _ = code;
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
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1));
    frame(app);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
    return app;
}

// Locks the first frame: nothing overflows, the patch's text carries the widgets' values
// (tog 1, shimmer 0.16, wet 0.73, the four levels, the sends), and the view scrolls over the
// document's 1314 px.
test "the first frame binds the patch to its widgets" {
    const app = new_app();
    frame(app);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqualStrings("1", app.slots.get(0));
    try std.testing.expectEqualStrings("0.16", app.slots.get(2));
    try std.testing.expectEqualStrings("0.73", app.slots.get(3));
    try std.testing.expectEqualStrings("-2.68db", app.slots.get(4));
    try std.testing.expectEqualStrings("-4.11db", app.slots.get(7));
    try std.testing.expectEqualStrings("-60db", app.slots.get(8));
    try std.testing.expectEqualStrings("0db", app.slots.get(9));
    try std.testing.expectEqual(content_h, app.view.content_h);
    try std.testing.expectEqual(@as(f32, 1314), content_h);
    try std.testing.expect(!app.playing);
    test_context.draw.finalize();
    try std.testing.expectEqual(@as(u32, 0), quads.covered_glyphs(&test_context.draw));
}

// Locks the scenarios' effects: the wheel scrolls 686 px (the whole range), play runs 30
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
    try std.testing.expectEqualStrings("0", app.slots.get(0));
    try std.testing.expectEqualStrings("1", app.slots.get(13));
    app = try scenario_app("knobs");
    try std.testing.expectApproxEqAbs(comp_params[0].position(-27.7) + 0.25, app.comp[0].value, 1e-4);
    try std.testing.expectApproxEqAbs(wet_param.position(0.73) + 20.0 / 120.0, app.wet.value, 1e-4);
    app = try scenario_app("keys");
    try std.testing.expect(app.keyboard.held.isSet(64));
    try std.testing.expect(!app.enabled[mix]);
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

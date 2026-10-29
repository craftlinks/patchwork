//! The session's small plots: the compander's transfer curve, an envelope, a filter's
//! response, level bars, a modulator's slider, and spectra, each drawn into a rect it is given.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Each Uses
//! ```text
//! transfer   draw.Path through 33 points, rings at its two knees (look.node)
//! envelope   draw.Path through attack, decay, sustain, release; dots at the corners
//! response   draw.Path of a two-pole low-pass on a log axis; faint decade ticks
//! bars       two boxes (left and right) whose length follows decibels; a tick at 0 dB
//! slider     a line with ticks and a box at the modulator's value
//! fill       draw.Waveform columns from 0 to each bin (a filled area) and its outline
//! upright    a vertical draw.Path: a scope or a spectrum turned on its side
//! ```
//! The library has strokes and min/max columns but no filled shape (step 49), so an area
//! under a curve is a `Waveform` whose columns run from 0 to the value.
//!
//! ## 2. TigerStyle Invariants
//! - Stack buffers of named sizes; every loop is bounded by them.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const look = @import("look.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.Point;

// ---------------------------------------------------------------------------- compander

/// The compander's knobs in their own units.
pub const Compander = struct {
    below: f32,
    up: f32,
    above: f32,
    down: f32,
    most: f32,
    makeup: f32,

    /// Output decibels for input `x` decibels: expanded by `up` below `below`, compressed by
    /// `down` above `above`, the change limited to `most`, then `makeup`.
    pub fn output(self: Compander, x: f32) f32 {
        assert(self.up >= 1 and self.down >= 1);
        var y = x;
        if (x < self.below) y = self.below + (x - self.below) * self.up;
        if (x > self.above) y = self.above + (x - self.above) / self.down;
        y = std.math.clamp(y, x - self.most, x + self.most);
        return y + self.makeup;
    }
};

pub const db_floor: f32 = -60;
const transfer_points: u32 = 33;

/// The transfer curve over [-60, 0] dB both ways in `rect`.
pub fn transfer(cx: anytype, rect: Rect, clip: Clip, curve: Compander, alpha: f32) void {
    const line = look.with_alpha(look.pastels[1], alpha);
    const grid = look.with_alpha(look.faint, alpha);
    look.hline(cx, rect.x, rect.x + rect.width, map_y(rect, curve.below), clip, grid);
    look.hline(cx, rect.x, rect.x + rect.width, map_y(rect, curve.above), clip, grid);
    look.vline(cx, rect.x, rect.y, rect.y + rect.height, clip, grid);
    var points: [transfer_points]Point = undefined;
    for (&points, 0..) |*point, index| {
        const x = db_floor * (1 - @as(f32, @floatFromInt(index)) / (transfer_points - 1));
        point.* = .{ map_x(rect, x), map_y(rect, curve.output(x)) };
    }
    _ = kit.stroke(cx, &points, clip, line, 1.5);
    look.node(cx, .{ map_x(rect, curve.below), map_y(rect, curve.output(curve.below)) }, 4, clip, look.with_alpha(look.channel_colors[3], alpha));
    look.node(cx, .{ map_x(rect, curve.above), map_y(rect, curve.output(curve.above)) }, 4, clip, look.with_alpha(look.channel_colors[3], alpha));
}

fn map_x(rect: Rect, db: f32) f32 {
    return rect.x + rect.width * (db - db_floor) / -db_floor;
}

fn map_y(rect: Rect, db: f32) f32 {
    const t = std.math.clamp((db - db_floor) / -db_floor, 0, 1);
    return rect.y + rect.height * (1 - t);
}

// ---------------------------------------------------------------------------- envelope

/// An ADSR envelope (seconds, and the sustain level) over `rect`, the sustain held one second.
pub fn envelope(cx: anytype, rect: Rect, clip: Clip, a: f32, d: f32, s: f32, r: f32, alpha: f32) void {
    assert(a >= 0 and d >= 0 and r >= 0);
    const hold: f32 = 1;
    const total = a + d + hold + r;
    const scale = rect.width / total;
    const top = rect.y + 2;
    const floor = rect.y + rect.height - 1;
    const sustain = floor - (floor - top) * s;
    const points = [_]Point{
        .{ rect.x, floor },
        .{ rect.x + a * scale, top },
        .{ rect.x + (a + d) * scale, sustain },
        .{ rect.x + (a + d + hold) * scale, sustain },
        .{ rect.x + rect.width, floor },
    };
    const color = look.with_alpha(look.white, 0.8 * alpha);
    _ = kit.stroke(cx, &points, clip, color, 1.2);
    for (points[1..4]) |point| look.dot(cx, point, 2, clip, color);
}

// ---------------------------------------------------------------------------- response

const response_points: u32 = 40;

/// A two-pole low-pass at `cutoff_hz` over 20 Hz to 20 kHz in `rect`.
pub fn response(cx: anytype, rect: Rect, clip: Clip, cutoff_hz: f32, alpha: f32) void {
    assert(cutoff_hz > 0);
    var decade: u32 = 0;
    while (decade < 4) : (decade += 1) {
        const x = rect.x + rect.width * @as(f32, @floatFromInt(decade)) / 3;
        look.vline(cx, @min(x, rect.x + rect.width - 1), rect.y + rect.height * 0.45, rect.y + rect.height, clip, look.with_alpha(look.faint, alpha));
    }
    var points: [response_points]Point = undefined;
    for (&points, 0..) |*point, index| {
        const t = @as(f32, @floatFromInt(index)) / (response_points - 1);
        const hz = 20 * std.math.pow(f32, 1000, t);
        const ratio = hz / cutoff_hz;
        const gain = 1 / @sqrt(1 + ratio * ratio * ratio * ratio);
        point.* = .{ rect.x + rect.width * t, rect.y + 3 + (rect.height - 4) * (1 - gain) };
    }
    _ = kit.stroke(cx, &points, clip, look.with_alpha(look.white, 0.8 * alpha), 1.2);
}

// ---------------------------------------------------------------------------- bars

pub const bars_floor_db: f32 = -48;

/// Level bars: the label `text` right-aligned at the left, a tick at 0 dB, and two bars whose
/// lengths follow `left_db` and `right_db` from `bars_floor_db` to 0 dB, in `color`.
pub fn bars(cx: anytype, rect: Rect, clip: Clip, label: []const u8, left_db: f32, right_db: f32, color: [4]f32) void {
    const label_box: Rect = .{ .x = rect.x, .y = rect.y, .width = 26, .height = rect.height };
    kit.label(cx, look.style(.serif, 10, look.dim), label, label_box, clip, look.end);
    const x0 = rect.x + 34;
    const span = rect.width - 36;
    const mid = rect.y + rect.height * 0.5;
    look.vline(cx, x0 - 2, mid - 7, mid + 7, clip, look.dim);
    for ([2]f32{ left_db, right_db }, 0..) |db, side| {
        const t = std.math.clamp((db - bars_floor_db) / -bars_floor_db, 0, 1);
        const y = mid - 5 + @as(f32, @floatFromInt(side)) * 6;
        look.fill(cx, .{ .x = x0 + span * (1 - t), .y = y, .width = span * t, .height = 4 }, clip, color);
    }
}

/// A modulator's slider: a line with five ticks and a box at `value` in `[lo, hi]`.
pub fn slider(cx: anytype, rect: Rect, clip: Clip, value: f32, lo: f32, hi: f32, alpha: f32) void {
    assert(hi > lo);
    const mid = rect.y + rect.height * 0.5;
    look.hline(cx, rect.x, rect.x + rect.width, mid, clip, look.with_alpha(look.dim, alpha));
    var tick: u32 = 0;
    while (tick < 5) : (tick += 1) {
        const x = rect.x + rect.width * @as(f32, @floatFromInt(tick)) / 4;
        look.vline(cx, @min(x, rect.x + rect.width - 1), mid - 3, mid + 4, clip, look.with_alpha(look.faint, alpha));
    }
    const t = std.math.clamp((value - lo) / (hi - lo), 0, 1);
    look.fill(cx, .{ .x = rect.x + t * (rect.width - 4), .y = mid - 7, .width = 4, .height = 14 }, clip, look.with_alpha(look.white, alpha));
}

// ---------------------------------------------------------------------------- spectra

pub const fill_bins_max: u32 = 64;

/// A filled spectrum over `rect`: one column per value from 0 up, then its outline on the
/// over layer. `values.len` must divide the rect's width in device pixels.
pub fn fill(cx: anytype, rect: Rect, clip: Clip, values: []const f32, area: [4]f32, outline: [4]f32) void {
    assert(values.len >= 2 and values.len <= fill_bins_max);
    var columns: [fill_bins_max]quads.wave.Column = undefined;
    var points: [fill_bins_max]Point = undefined;
    for (values, columns[0..values.len], points[0..values.len], 0..) |value, *column, *point, index| {
        column.* = .{ .min = 0, .max = value, .rms = 0 };
        const x = rect.x + rect.width * (@as(f32, @floatFromInt(index)) + 0.5) / @as(f32, @floatFromInt(values.len));
        point.* = .{ x, rect.y + rect.height * (1 - value) };
    }
    _ = quads.wave.append(cx.drawing(), rect.array(), clip.array(), columns[0..values.len], .{ .color = area, .rms_color = null, .lo = 0, .hi = 1 });
    const previous = cx.drawing().layer(look.over_layer);
    _ = kit.stroke(cx, points[0..values.len], clip, outline, 1.2);
    _ = cx.drawing().layer(previous);
}

pub const upright_max: u32 = 96;

/// `values` down `rect` as one stroke: index 0 at the top (`top_first`) or the bottom, each
/// value placed across the rect from `centre` (0 at the left, 0.5 the middle) by `gain`.
pub fn upright(cx: anytype, rect: Rect, clip: Clip, values: []const f32, centre: f32, gain: f32, top_first: bool, color: [4]f32) void {
    assert(values.len >= 2 and values.len <= upright_max);
    var points: [upright_max]Point = undefined;
    const last: f32 = @floatFromInt(values.len - 1);
    for (values, points[0..values.len], 0..) |value, *point, index| {
        const t = @as(f32, @floatFromInt(index)) / last;
        const y = if (top_first) rect.y + rect.height * t else rect.y + rect.height * (1 - t);
        const x = rect.x + rect.width * std.math.clamp(centre + value * gain, 0, 1);
        point.* = .{ x, y };
    }
    _ = kit.stroke(cx, points[0..values.len], clip, color, 1);
}

// Locks the compander's curve: unity between the knees, expansion by `up` below, compression
// by `down` above, the change limited by `most`, then makeup added.
test "compander transfer" {
    const curve: Compander = .{ .below = -30, .up = 2, .above = -10, .down = 4, .most = 12, .makeup = 1 };
    try std.testing.expectEqual(@as(f32, -19), curve.output(-20));
    try std.testing.expectEqual(@as(f32, -39), curve.output(-35));
    try std.testing.expectEqual(@as(f32, -52 - 12 + 1), curve.output(-52));
    try std.testing.expectEqual(@as(f32, -10 + 2.5 + 1), curve.output(0));
}

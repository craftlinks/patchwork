//! The session's look: its palette, its serif text styles, two skins, and the small drawing
//! helpers every part of the screen shares.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Skins
//! - `Ring` (`KnobOf(Ring)`): a thin track arc, the value arc in the knob's accent, and a dot
//!   at the value's end on `over_layer` (a box appended on the base layer would draw under
//!   the arcs, whose batch comes later). The name sits in the ring's top in small italics and
//!   the value text in its middle: the app's units through `Knob.draw_text`.
//! - `Bipolar`: `Ring` whose value arc runs from the top (`ArcLook.start` 0.5), for pans.
//! - `Pill` (`ToggleOf(Pill)`): an upright capsule whose thumb rises when on and takes the
//!   toggle's `accent`, with the name under it.
//!
//! ## 2. Text
//! Three Noto Serif faces (`build.zig`, `faces.zig`): `serif` for code and values,
//! `serif_italic` for calls and labels, `serif_bold` for names a module declares.
//!
//! ## 3. TigerStyle Invariants
//! - Skins are stateless; helpers append through `kit` and skip empty geometry.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.Point;

/// The layer of dots and markers that must cover arcs and paths on the base layer.
pub const over_layer: quads.Layer = @fromBackingInt(1);

// ---------------------------------------------------------------------------- palette

pub const background = [4]f32{ 0.075, 0.075, 0.08, 1 };
pub const ink = [4]f32{ 0.87, 0.86, 0.83, 1 };
pub const dim = [4]f32{ 0.52, 0.52, 0.52, 1 };
pub const faint = [4]f32{ 0.30, 0.30, 0.31, 1 };
pub const rule = [4]f32{ 0.26, 0.26, 0.27, 1 };
pub const track = [4]f32{ 0.20, 0.20, 0.21, 1 };
pub const cell = [4]f32{ 0.14, 0.14, 0.15, 1 };
pub const meter = [4]f32{ 0.36, 0.84, 0.42, 1 };
pub const white = [4]f32{ 0.92, 0.92, 0.92, 1 };

/// Code token colours.
pub const number = [4]f32{ 0.50, 0.82, 0.72, 1 };
pub const range_end = [4]f32{ 0.30, 0.56, 0.49, 1 };
pub const string = [4]f32{ 0.93, 0.85, 0.64, 1 };
pub const level_number = [4]f32{ 0.93, 0.88, 0.62, 1 };
pub const punctuation = [4]f32{ 0.62, 0.62, 0.62, 1 };
pub const keyword = [4]f32{ 0.70, 0.70, 0.68, 1 };

/// The mixer's channels: bass, pads, line, wet.
pub const channel_colors = [4][4]f32{
    .{ 1.00, 0.30, 0.92, 1 },
    .{ 0.62, 0.50, 1.00, 1 },
    .{ 0.90, 0.78, 0.15, 1 },
    .{ 1.00, 0.36, 0.62, 1 },
};

/// Knob accents, pastel, cycled along a row.
pub const pastels = [4][4]f32{
    .{ 0.96, 0.72, 0.58, 1 },
    .{ 0.90, 0.66, 0.96, 1 },
    .{ 0.56, 0.94, 0.80, 1 },
    .{ 0.60, 0.80, 0.96, 1 },
};

/// The sections' marks: mix, osc, pad, reverb tank.
pub const section_colors = [4][4]f32{
    .{ 0.40, 0.86, 0.56, 1 },
    .{ 0.88, 0.62, 0.26, 1 },
    .{ 0.32, 0.80, 0.72, 1 },
    .{ 0.66, 0.52, 0.92, 1 },
};

/// The scheme: the palette's background, track, and text over the dark defaults.
pub const scheme: theme.Scheme = blk: {
    var s = theme.dark;
    s.colors.background = background;
    s.colors.panel = cell;
    s.colors.track = track;
    s.colors.text = ink;
    s.colors.control = faint;
    s.colors.meter = meter;
    break :blk s;
};

pub fn with_alpha(color: [4]f32, alpha: f32) [4]f32 {
    assert(alpha >= 0 and alpha <= 1);
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

pub fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    assert(t >= 0 and t <= 1);
    var out: [4]f32 = undefined;
    for (&out, a, b) |*c, x, y| c.* = x + (y - x) * t;
    return out;
}

// ---------------------------------------------------------------------------- text

pub const code_size: f32 = 16;

pub fn style(face: text.Face, size: f32, color: [4]f32) text.Style {
    return .{ .face = face, .size = size, .color = color };
}

pub const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
pub const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = false };
pub const centered: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = false };

// ---------------------------------------------------------------------------- shapes

/// A filled rect, skipped when empty.
pub fn fill(cx: anytype, rect: Rect, clip: Clip, color: [4]f32) void {
    kit.face(cx, rect, clip, .{ .fill = color });
}

/// A disc of `radius` at `centre` on `over_layer`.
pub fn dot(cx: anytype, centre: Point, radius: f32, clip: Clip, color: [4]f32) void {
    assert(radius > 0);
    const rect: Rect = .{ .x = centre[0] - radius, .y = centre[1] - radius, .width = 2 * radius, .height = 2 * radius };
    const previous = cx.drawing().layer(over_layer);
    kit.face(cx, rect, clip, .{ .fill = color, .radius = radius });
    _ = cx.drawing().layer(previous);
}

/// A ring of `radius` at `centre` on `over_layer`: a node on a curve.
pub fn node(cx: anytype, centre: Point, radius: f32, clip: Clip, color: [4]f32) void {
    assert(radius > 1);
    const rect: Rect = .{ .x = centre[0] - radius, .y = centre[1] - radius, .width = 2 * radius, .height = 2 * radius };
    const previous = cx.drawing().layer(over_layer);
    kit.face(cx, rect, clip, .{ .fill = background, .border_color = color, .border_width = 1.5, .radius = radius });
    _ = cx.drawing().layer(previous);
}

/// A one-pixel line between two points along an axis.
pub fn hline(cx: anytype, x0: f32, x1: f32, y: f32, clip: Clip, color: [4]f32) void {
    fill(cx, .{ .x = @min(x0, x1), .y = y, .width = @abs(x1 - x0), .height = 1 }, clip, color);
}
pub fn vline(cx: anytype, x: f32, y0: f32, y1: f32, clip: Clip, color: [4]f32) void {
    fill(cx, .{ .x = x, .y = @min(y0, y1), .width = 1, .height = @abs(y1 - y0) }, clip, color);
}

/// The point at `value` along the open ring of `ring`, `inset` inside its edge.
pub fn arc_point(circle: Rect, value: f32, inset: f32) Point {
    assert(value >= 0 and value <= 1);
    const angle = theme.arc_start + value * theme.arc_sweep;
    const radius = circle.width * 0.5 - inset;
    return .{ circle.x + circle.width * 0.5 + radius * @cos(angle), circle.y + circle.height * 0.5 + radius * @sin(angle) };
}

// ---------------------------------------------------------------------------- skins

pub const ring_thickness: f32 = 2;

/// The ring knob (section 1).
pub const Ring = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        return ring(cx, look, true);
    }
};

/// The ring knob whose value arc runs from the top (section 1).
pub const Bipolar = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        return ring(cx, look, false);
    }
};

fn ring(cx: anytype, look: widgets.KnobLook, from_start: bool) ?widgets.Shape {
    assert(look.value >= 0 and look.value <= 1);
    if (look.row.height < look.ring or look.row.width < look.ring) return null;
    const side = look.ring;
    const ring_rect: Rect = .{
        .x = look.row.x + (look.row.width - side) * 0.5,
        .y = look.row.y + (look.row.height - side) * 0.5,
        .width = side,
        .height = side,
    };
    const accent = [4]f32{ look.accent.r, look.accent.g, look.accent.b, look.accent.a };
    const hover = kit.weight(look.hover, cx.theme().hover_lighten);
    kit.arc(cx, ring_rect, look.clip, .{ .color = track, .thickness = ring_thickness, .hover = hover });
    const origin: f32 = if (from_start) 0 else 0.5;
    const sweep = @abs(look.value - origin);
    if (sweep > 0) {
        const value_arc: quads.ArcLook = .{ .color = with_alpha(accent, 0.85), .thickness = ring_thickness, .start = @min(origin, look.value), .sweep = sweep, .hover = hover };
        kit.arc(cx, ring_rect, look.clip, value_arc);
    }
    dot(cx, arc_point(ring_rect, look.value, ring_thickness * 0.5), 3, look.clip, accent);
    const name: Rect = .{ .x = ring_rect.x, .y = ring_rect.y + side * 0.16, .width = side, .height = side * 0.22 };
    kit.label(cx, style(.serif_italic, @max(9, side * 0.17), dim), look.name, name, look.clip, centered);
    const value: Rect = .{ .x = ring_rect.x, .y = ring_rect.y + side * 0.36, .width = side, .height = side * 0.34 };
    kit.label(cx, style(.serif, @max(10, side * 0.2), ink), look.value_text, value, look.clip, centered);
    return .{ .rect = ring_rect, .radius = side * 0.5 };
}

pub const pill_w: f32 = 20;
pub const pill_h: f32 = 34;

/// A pill and its caption: the row a `Pill` toggle needs.
pub const pill_row_h: f32 = pill_h + 16;

/// The upright toggle (section 1): the pill at the top of its row, the name under it.
pub const Pill = struct {
    pub fn toggle(cx: anytype, look: widgets.ToggleLook) ?widgets.Shape {
        assert(look.thumb >= 0 and look.thumb <= 1);
        if (look.row.height < pill_h) return null;
        const color = look.accent orelse white;
        const pill: Rect = .{ .x = look.row.x + (look.row.width - pill_w) * 0.5, .y = look.row.y + 2, .width = pill_w, .height = pill_h };
        const hover = kit.weight(look.hover, cx.theme().hover_lighten);
        kit.face(cx, pill, look.clip, .{ .fill = mix(track, with_alpha(color, 0.35), look.thumb), .radius = pill_w * 0.5, .hover = hover });
        const thumb_side = pill_w - 4;
        const travel = pill_h - thumb_side - 4;
        const thumb: Rect = .{ .x = pill.x + 2, .y = pill.y + 2 + (1 - look.thumb) * travel, .width = thumb_side, .height = thumb_side };
        kit.face(cx, thumb, look.clip, .{ .fill = mix(dim, color, look.thumb), .radius = thumb_side * 0.5, .hover = hover });
        const name: Rect = .{ .x = look.row.x - 12, .y = pill.y + pill_h + 2, .width = look.row.width + 24, .height = 12 };
        kit.label(cx, style(.serif_italic, 10, dim), look.name, name, look.clip, centered);
        return .{ .rect = pill, .radius = pill_w * 0.5 };
    }
};

// Locks the arc geometry the dots follow: value 0 sits at arc_start (lower left, 120 degrees
// clockwise from +x) and value 1 a three-quarter turn later (lower right, 30 degrees).
test "arc points follow the open ring" {
    const ring_rect: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const lo = arc_point(ring_rect, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 50 - 25), lo[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 50 + 43.30127), lo[1], 1e-3);
    const hi = arc_point(ring_rect, 1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 50 + 43.30127), hi[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 50 + 25), hi[1], 1e-3);
}

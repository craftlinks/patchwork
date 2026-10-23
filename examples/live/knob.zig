//! The live app's knob: a ring of any size with the value text inside it, bound to a literal.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Not `widgets.Knob`
//! The library knob holds a normalized value, formats its own text, has a fixed 56 px ring,
//! and puts its name and value beside the ring. A bound knob shows the literal's own bytes, at
//! two sizes (44 px in the column, 64 px in an inline row), with the value inside the ring.
//! The value lives in the text, so this knob keeps no value at all: `interpret` turns events
//! into actions and `draw` paints what the app passes.
//!
//! ## 2. Events
//! ```text
//! hover_in, hover_out   hover (the app redraws: curves brighten for a hovered knob)
//! down                  grabbed; `drag_y` remembers the press
//! drag                  turned by -(y - drag_y) / drag_span_px of the range
//! up                    released (also a capture lost to pointer_leave)
//! wheel                 wheel by -dy / drag_span_px of the range
//! right press           reset
//! ```
//!
//! ## 3. Drawing
//! A track arc over the whole sweep, a value arc over `fraction` of it in the accent, the
//! value text centered in the ring, and, for inline knobs, the label above it. A disabled
//! knob (a `shape` argument that names no binding) draws dim and records no area.
//!
//! ## 4. TigerStyle Invariants
//! - No state, no allocation; `fraction` is in `[0, 1]`.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

const Rect = quads.Rect;

/// Pointer travel, in logical pixels, that covers a knob's whole range.
pub const drag_span_px: f32 = widgets.drag_span_px;
/// Ring stroke.
pub const thickness: f32 = 3;
/// Alpha of a disabled knob's faces and text.
pub const disabled_alpha: f32 = 0.35;

pub const Action = union(enum) {
    none,
    hover,
    grabbed,
    /// Fractions of the range: positive turns up.
    turned: f32,
    released,
    wheel: f32,
    reset,
};

/// What one event means for the knob `id` (section 2). `drag_y` is the gesture's last y.
pub fn interpret(cx: anytype, id: ui.Id, event: patchwork.input.Event, drag_y: *f32) Action {
    assert(id != .none);
    assert(drag_y.* == drag_y.*);
    switch (cx.hit(id, event)) {
        .none => return .none,
        .hover_in, .hover_out => {
            cx.redraw();
            return .hover;
        },
        .down => |press| {
            drag_y.* = press.y;
            cx.redraw();
            return .grabbed;
        },
        .drag => |press| {
            const dy = press.y - drag_y.*;
            drag_y.* = press.y;
            if (dy == 0) return .none;
            return .{ .turned = -dy / drag_span_px };
        },
        .up => {
            cx.redraw();
            return .released;
        },
        .wheel => |wheel| {
            if (wheel.dy == 0) return .none;
            return .{ .wheel = -wheel.dy / drag_span_px };
        },
        .secondary => return .reset,
    }
}

/// What to paint (section 3).
pub const Look = struct {
    ring: Rect,
    /// The value's position in its range, `[0, 1]`.
    fraction: f32,
    accent: [4]f32,
    /// The literal's bytes.
    value: []const u8,
    /// Drawn inside the ring above the value; empty for none.
    label: []const u8,
    enabled: bool,
    /// Lighten toward white, `[0, 1]` (hovered or held).
    lit: f32,
};

/// Draws the knob and records its ring as a wheel area when enabled (section 3).
pub fn draw(cx: anytype, id: ui.Id, look: Look) void {
    assert(look.fraction >= 0);
    assert(look.fraction <= 1);
    assert(look.ring.width == look.ring.height);
    const clip = cx.visible(look.ring) orelse return;
    const alpha: f32 = if (look.enabled) 1 else disabled_alpha;
    if (look.enabled) cx.area(id, look.ring, look.ring.width * 0.5, widgets.knob_flags);
    var track = theme.chrome.track;
    track[3] *= alpha;
    append_arc(cx, look.ring, track, 0, 1, clip);
    if (look.fraction > 0) {
        var accent = look.accent;
        accent[3] *= alpha;
        append_arc(cx, look.ring, accent, look.lit * widgets.hover_lighten, look.fraction, clip);
    }
    const size = look.ring.width;
    var color = theme.chrome.text;
    color[3] *= alpha;
    const value_style: text.Style = .{ .face = .mono, .size = value_size(size), .color = color };
    var value_box = look.ring;
    if (look.label.len > 0) {
        var label_color = color;
        label_color[3] *= 0.7;
        const label_style: text.Style = .{ .face = .sans, .size = 10, .color = label_color };
        var label_box = look.ring;
        label_box.y += size * 0.22;
        label_box.height = size * 0.25;
        label_box.x += thickness * 2;
        label_box.width -= thickness * 4;
        text.place(cx.drawing(), label_style, look.label, label_box, clip, fitted);
        value_box.y += size * 0.47;
        value_box.height = size * 0.3;
    }
    text.place(cx.drawing(), value_style, look.value, value_box, clip, widgets.centered);
}

/// The value text's size for a ring of `size`: 11 px in the 44 px column ring.
pub fn value_size(size: f32) f32 {
    assert(size > 0);
    const result = @round(size * 0.25);
    assert(result >= 1);
    return result;
}

const fitted: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = true };

fn append_arc(
    cx: anytype,
    ring: Rect,
    color: [4]f32,
    hover: f32,
    sweep: f32,
    clip: quads.Clip,
) void {
    assert(sweep >= 0);
    assert(sweep <= 1);
    cx.append(quads.Arc, null, .{
        .rect = .{ ring.x, ring.y, ring.width, ring.height },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = color,
        .thickness = thickness,
        .sweep = sweep,
        .hover = hover,
        .pad = 0,
    }) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

comptime {
    assert(value_size(44) == 11);
    assert(value_size(64) == 16);
}

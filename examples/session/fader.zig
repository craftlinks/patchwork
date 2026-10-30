//! `Fader`: an upright level control with a stereo meter in its track. App code, and a recipe:
//! a screen that wants one copies this file (the library has a horizontal `Slider` and a
//! passive `Meter`, no fader, and step 35 and 47.3 left it that way).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! The box the app gives is the track. The level is a two-pixel line across it at
//! `y = bottom - value * height`, with a triangle in the channel's colour `marker_px` to its
//! left; the meter is two bars rising from the bottom of the track. The value maps to
//! decibels linearly: `db = db_lo + value * (db_hi - db_lo)`, so the meter bars and the line
//! share one scale.
//!
//! ## 2. Events
//! Like `Knob`: a drag is relative (`travel` logical pixels per unit, up raises), the wheel
//! nudges, and a right press restores the default. The area takes the wheel and shows the
//! vertical resize cursor.
//!
//! ## 3. TigerStyle Invariants
//! - `value` stays in `[0, 1]` after every event.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const look = @import("look.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;

pub const db_lo: f32 = -60;
pub const db_hi: f32 = 6;
pub const travel: f32 = 200;
pub const marker_px: f32 = 9;

const flags: ui.Flags = .{ .wheel = true, .focusable = false, .tab = false, .cursor = .ns_resize };

/// The unit position of `db`, clamped.
pub fn position(db: f32) f32 {
    return std.math.clamp((db - db_lo) / (db_hi - db_lo), 0, 1);
}

/// The decibels at unit position `value`.
pub fn decibels(value: f32) f32 {
    assert(value >= 0 and value <= 1);
    return db_lo + value * (db_hi - db_lo);
}

pub const Fader = struct {
    id: ui.Id,
    value: f32,
    default: f32,
    drag_y: f32 = 0,
    hover: kit.Animator = .init(kit.hover_rate_per_ms),

    pub const Action = union(enum) { none, changed: f32 };

    pub fn init(id: ui.Id, level_db: f32) Fader {
        assert(id != .none);
        const value = position(level_db);
        return .{ .id = id, .value = value, .default = value };
    }

    pub fn db(self: *const Fader) f32 {
        return decibels(self.value);
    }

    pub fn handle(self: *Fader, cx: anytype, event: input.Event) Action {
        assert(self.value >= 0 and self.value <= 1);
        if (event == .frame) {
            kit.step(cx, &self.hover, event.frame);
            return .none;
        }
        const hit = cx.hit(self.id, event);
        kit.respond(cx, hit, &self.hover, null);
        switch (hit) {
            .none, .hover_in, .hover_out, .up => return .none,
            .down => |press| {
                self.drag_y = press.y;
                return .none;
            },
            .drag => |press| {
                const dy = press.y - self.drag_y;
                self.drag_y = press.y;
                return self.nudge(cx, -dy / travel);
            },
            .wheel => |wheel| return self.nudge(cx, -wheel.dy / travel),
            .secondary => return self.nudge(cx, self.default - self.value),
        }
    }

    fn nudge(self: *Fader, cx: anytype, delta: f32) Action {
        const next = std.math.clamp(self.value + delta, 0, 1);
        if (next == self.value) return .none;
        self.value = next;
        cx.redraw();
        return .{ .changed = next };
    }

    /// The track at `rect` with the meter at `levels` (unit positions, left and right), the
    /// line, and the marker in `color`; records the area.
    pub fn draw(self: *const Fader, cx: anytype, rect: Rect, color: [4]f32, levels: [2]f32) void {
        const clip = cx.visible(rect) orelse return;
        const hover = kit.weight(self.hover.value, cx.theme().hover_lighten);
        kit.face(cx, rect, clip, .{ .fill = look.cell, .radius = 2, .hover = hover });
        const bar_w = (rect.width - 10) * 0.5;
        for (levels, 0..) |level, side| {
            assert(level >= 0 and level <= 1);
            const height = level * (rect.height - 4);
            const x = rect.x + 4 + @as(f32, @floatFromInt(side)) * (bar_w + 2);
            look.fill(cx, .{ .x = x, .y = rect.y + rect.height - 2 - height, .width = bar_w, .height = height }, clip, look.meter);
        }
        const y = rect.y + rect.height - self.value * rect.height;
        const previous = cx.drawing().layer(look.over_layer);
        look.fill(cx, .{ .x = rect.x - 1, .y = y - 1, .width = rect.width + 2, .height = 2 }, clip, look.white);
        _ = cx.drawing().layer(previous);
        const tip: quads.Point = .{ rect.x - 3, y };
        const marker = [_]quads.Point{
            .{ tip[0] - marker_px, y - marker_px * 0.6 },
            tip,
            .{ tip[0] - marker_px, y + marker_px * 0.6 },
            .{ tip[0] - marker_px, y - marker_px * 0.6 },
        };
        _ = kit.stroke(cx, &marker, clip, color, 1.5);
        const area: Rect = .{ .x = rect.x - marker_px - 4, .y = rect.y, .width = rect.width + marker_px + 4, .height = rect.height };
        cx.area(self.id, area, 0, flags);
    }
};

// Locks the decibel scale of section 1: -60 dB is the bottom, +6 dB the top, and -2.68 dB
// sits at (60 - 2.68) / 66 of the way up.
test "fader positions and decibels" {
    try std.testing.expectEqual(@as(f32, 0), position(-60));
    try std.testing.expectEqual(@as(f32, 1), position(6));
    try std.testing.expectApproxEqAbs(@as(f32, 57.32 / 66.0), position(-2.68), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.68), decibels(position(-2.68)), 1e-4);
}

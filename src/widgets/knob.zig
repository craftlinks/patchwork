//! `Knob`: an open ring with its name and value beside it, and the row geometry the meter and
//! the toggle share with it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! All geometry is UI logical pixels, origin top-left, `+Y` down; `row` is the box the turtle
//! gave the knob.
//! - `ring_sized(row, knob.ring)` is a `knob.ring` square (default `ring_size`, set per
//!   instance with `sized`) at `row.x + ring_inset`, centered vertically. A row shorter than
//!   the ring draws nothing.
//! - The labels start `label_gap` past the ring (`ring.x + 64` by default): the name on the
//!   first `label_line_px` line, the value text on the second.
//! - The hit area is the disc inscribed in the ring; it takes the wheel and shows the grab
//!   cursor (`knob_flags`).
//! - `side_box` is the label column beside a meter or pill, at the default knob's label x, so
//!   mixed rows line up.
//!
//! ## 2. Events
//! Hover follows the kit's table without a press channel; the wheel and a right press also
//! light it. Drag and wheel are relative:
//! ```text
//! value' = clamp(value - delta / drag_span_px, 0, 1)
//! delta  = y - drag_y      for drags (up increases the value)
//! delta  = wheel.dy        for the wheel
//! ```
//! A right press resets the value to `default`, its value at `init`. Test "knob drag is
//! relative and clamped".
//!
//! ## 3. Drawing
//! A track arc over the whole sweep, the value arc over `value` of it in `accent` (omitted at
//! 0, lightened by hover), the name, and the value text as hundredths `d.dd` in the fixed
//! `[8]u8` `value_text`, tail zeroed.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// Knob drag and wheel distance, in logical pixels, that covers the unit range.
pub const drag_span_px: f32 = 120;

/// Knob ring edge. The hit disc is inscribed in it, so the hole still drags.
pub const ring_size: f32 = 56;

/// Ring stroke. Stored in the arc instance's `thickness`.
pub const ring_thickness: f32 = 4;

/// Inset of the ring and the pill from the row's left edge.
pub const ring_inset: f32 = 8;
/// Smallest ring `Knob.sized` takes.
pub const ring_min: f32 = 24;
/// Space between a ring and its labels.
pub const label_gap: f32 = 8;

/// A knob row's height in logical pixels; `ring_of` centers the ring in it.
pub const knob_height: f32 = 72;
/// The height of one text line beside the ring.
pub const label_line_px: f32 = 36;
pub const accent_count: u32 = 4;

/// A knob's ring area: it takes the wheel and shows the grab cursor.
pub const knob_flags: ui.Flags = .{
    .wheel = true,
    .focusable = false,
    .tab = false,
    .cursor = .grab,
};

/// The dark scheme's per-knob accent fills, cycled by knob index modulo `accent_count`. Each
/// knob's value arc carries its own fill (`Knob.accent`); `kit.accent(cx, index)` is the app
/// scheme's.
pub const accents: [accent_count]kit.Paint = .{
    .{ .r = 0.62, .g = 0.45, .b = 0.86, .a = 1, .radius = ring_thickness },
    .{ .r = 0.40, .g = 0.78, .b = 0.48, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.55, .b = 0.24, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.80, .b = 0.32, .a = 1, .radius = ring_thickness },
};

comptime {
    assert(ring_thickness == kit.accent_radius);
    assert(accent_count == theme.accent_count);
    for (accents, theme.dark.accents) |paint, color| {
        assert(paint.r == color[0] and paint.g == color[1] and paint.b == color[2]);
        assert(paint.a == color[3]);
    }
}

/// Open ring. Drag is relative: up increases `value`. Value 0 omits the value arc. A right
/// press resets it to `default`, its value at `init`.
pub const Knob = struct {
    id: Id,
    name: []const u8,
    value_text: [8]u8,
    value: f32,
    default: f32,
    accent: kit.Paint,
    hover: animator.Animator,
    drag_y: f32,
    /// The ring's side in logical pixels (section 1); `sized` sets another.
    ring: f32 = ring_size,

    pub const Action = union(enum) {
        none,
        changed: f32,
        released,
        /// A right press set the value back to `default`.
        reset: f32,
    };

    /// A knob at `value` (also its default) with its text written.
    pub fn init(id: Id, name: []const u8, value: f32, accent: kit.Paint) Knob {
        assert(id != .none);
        assert(name.len <= 8);
        var knob: Knob = .{
            .id = id,
            .name = name,
            .value_text = @splat(0),
            .value = value,
            .default = value,
            .accent = accent,
            .hover = animator.Animator.init(kit.hover_rate_per_ms),
            .drag_y = 0,
        };
        knob.set_value(value);
        assert(knob.value == value);
        return knob;
    }

    /// This knob with a ring of `side` logical pixels, at least `ring_min`.
    pub fn sized(self: Knob, side: f32) Knob {
        assert(side >= ring_min);
        var knob = self;
        knob.ring = side;
        assert(knob.ring == side);
        return knob;
    }

    pub fn handle(self: *Knob, cx: anytype, event: input.Event) Action {
        assert(self.value >= 0);
        assert(self.value <= 1);
        if (event == .frame) {
            kit.step(cx, &self.hover, event.frame);
            return .none;
        }
        const hit = cx.hit(self.id, event);
        kit.respond(cx, hit, &self.hover, null);
        switch (hit) {
            .none, .hover_in, .hover_out => return .none,
            .down => |press| {
                self.drag_y = press.y;
                return .none;
            },
            .drag => |press| {
                const dy = press.y - self.drag_y;
                self.drag_y = press.y;
                return self.nudge(cx, -dy / drag_span_px);
            },
            .up => return .released,
            .wheel => |wheel| {
                kit.aim(cx, &self.hover, 1);
                return self.nudge(cx, -wheel.dy / drag_span_px);
            },
            .secondary => {
                kit.aim(cx, &self.hover, 1);
                if (self.value == self.default) return .none;
                self.set_value(self.default);
                cx.redraw();
                assert(self.value == self.default);
                return .{ .reset = self.default };
            },
        }
    }

    /// Draws the ring, the value arc, the name, and the value text in the box `walk` gets,
    /// and records the ring's disc as a wheel area. A box shorter than the ring draws
    /// nothing.
    pub fn draw(self: *const Knob, cx: anytype, walk: Walk) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const row = cx.walk(walk);
        if (row.height < self.ring) return;
        const clip = cx.visible(row) orelse return;
        const ring = ring_sized(row, self.ring);
        cx.area(self.id, ring, self.ring * 0.5, knob_flags);
        const scheme = cx.theme();
        kit.arc(cx, ring, clip, .{ .color = scheme.colors.track, .thickness = ring_thickness });
        if (self.value > 0) {
            const accent = self.accent;
            kit.arc(cx, ring, clip, .{
                .color = .{ accent.r, accent.g, accent.b, accent.a },
                .thickness = ring_thickness,
                .sweep = self.value,
                .hover = kit.weight(self.hover.value, scheme.hover_lighten),
            });
        }
        const centered = kit.centered;
        kit.label(cx, scheme.name, self.name, name_box(row, self.ring), clip, centered);
        const value_text = self.value_text[0..4];
        kit.label(cx, scheme.value, value_text, value_box(row, self.ring), clip, centered);
    }

    pub fn set_value(self: *Knob, value: f32) void {
        assert(value >= 0);
        assert(value <= 1);
        self.value = value;
        write_hundredths(&self.value_text, value);
        assert(self.value_text[1] == '.');
        assert(self.value == value);
    }

    fn nudge(self: *Knob, cx: anytype, delta: f32) Action {
        assert(delta == delta);
        const next = std.math.clamp(self.value + delta, 0, 1);
        if (self.value == next) return .none;
        self.set_value(next);
        cx.redraw();
        return .{ .changed = next };
    }
};

pub fn ring_of(row: Rect) Rect {
    return ring_sized(row, ring_size);
}

/// The ring of a knob of side `side` in `row` (section 1).
pub fn ring_sized(row: Rect, side: f32) Rect {
    assert(side >= ring_min);
    assert(row.height >= side);
    const ring: Rect = .{
        .x = row.x + ring_inset,
        .y = row.y + (row.height - side) * 0.5,
        .width = side,
        .height = side,
    };
    assert(ring.width == side);
    assert(ring.height == side);
    return ring;
}

pub fn write_hundredths(out: *[8]u8, value: f32) void {
    assert(value >= 0);
    assert(value <= 1);
    const scaled: i32 = @intFromFloat(@round(value * 100.0));
    const whole: u32 = @intCast(std.math.clamp(scaled, 0, 100));
    out[0] = '0' + @as(u8, @intCast(whole / 100));
    const rest = whole % 100;
    out[1] = '.';
    out[2] = '0' + @as(u8, @intCast(rest / 10));
    out[3] = '0' + @as(u8, @intCast(rest % 10));
    @memset(out[4..], 0);
    assert(out[1] == '.');
    if (out[0] != '0') assert(out[0] == '1');
}

/// The name's line beside a ring of `side`: `side + label_gap` past the ring's left edge, so
/// `ring.x + 64` for the default ring.
pub fn name_box(row: Rect, side: f32) Rect {
    const ring = ring_sized(row, side);
    const x = ring.x + side + label_gap;
    const box: Rect = .{
        .x = x,
        .y = row.y,
        .width = row.x + row.width - x,
        .height = label_line_px,
    };
    assert(box.x == ring.x + side + label_gap);
    assert(box.height == label_line_px);
    return box;
}

fn value_box(row: Rect, side: f32) Rect {
    var box = name_box(row, side);
    box.y = row.y + label_line_px;
    assert(box.y == row.y + label_line_px);
    assert(box.height == label_line_px);
    return box;
}

/// The label column beside a meter or pill. It lands at the same x as `name_box` of the
/// default ring; the comptime block asserts that.
pub fn side_box(row: Rect) Rect {
    const x = row.x + ring_inset + 64;
    const box: Rect = .{
        .x = x,
        .y = row.y,
        .width = row.x + row.width - x,
        .height = row.height,
    };
    assert(box.x == row.x + ring_inset + 64);
    assert(box.height == row.height);
    return box;
}

comptime {
    assert(drag_span_px == 120);
    assert(ring_size == 56);
    assert(ring_thickness == 4);
    assert(knob_height == 72);
    assert(accent_count == 4);
    // The literal 64 in `side_box` is the label column offset: the ring plus its inset.
    assert(ring_inset + ring_size == 64);
    // The default knob's labels start where they always did: ring.x + 64.
    assert(ring_size + label_gap == 64);
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const quads = @import("../draw.zig");
const test_context = fixture.context;
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;

/// A point on the knob ring's vertical center line at `y`.
fn at_y(y: f32) input.Point {
    return .{ .x = 36, .y = y };
}

// Locks the relative drag rule: upward motion adds `delta / drag_span_px`, the wheel uses the
// same scale with the opposite sign of `dy`, results clamp to `[0, 1]`, and the text follows.
test "knob drag is relative and clamped" {
    const cx = test_context();
    var knob = Knob.init(ui.id("knob", 0), "k", 0.25, accents[0]);
    try testing.expectEqualStrings("0.25", knob.value_text[0..4]);
    // The ring sits at (8, 8 + 72 - 56) / 2 inside a 200 by 72 row at the origin: center 36.
    draw_one(cx, &knob, at(0, 0, 200, knob_height));
    try testing.expectEqual(
        Knob.Action.none,
        send(cx, &knob, .{ .pointer_down = input.left_at(at_y(36)) }),
    );
    // Move up 30 px: 30 / drag_span_px = 0.25 added.
    try testing.expectEqual(@as(f32, 0.5), send(cx, &knob, .{ .pointer_move = at_y(6) }).changed);
    try testing.expectEqualStrings("0.50", knob.value_text[0..4]);
    // A move of exactly drag_span_px down removes the whole range; further down is clamped.
    try testing.expectEqual(@as(f32, 0), send(cx, &knob, .{ .pointer_move = at_y(126) }).changed);
    try testing.expectEqual(Knob.Action.none, send(cx, &knob, .{ .pointer_move = at_y(4000) }));
    try testing.expectEqual(
        Knob.Action.released,
        send(cx, &knob, .{ .pointer_up = input.left_at(at_y(36)) }),
    );
    // Wheel dy = -60 adds 60 / drag_span_px; a further push up clamps at 1.
    const up_60: input.Wheel = .{ .x = 36, .y = 36, .dx = 0, .dy = -60 };
    try testing.expectEqual(@as(f32, 0.5), send(cx, &knob, .{ .wheel = up_60 }).changed);
    const up_far: input.Wheel = .{ .x = 36, .y = 36, .dx = 0, .dy = -4000 };
    try testing.expectEqual(@as(f32, 1), send(cx, &knob, .{ .wheel = up_far }).changed);
    try testing.expectEqualStrings("1.00", knob.value_text[0..4]);
    // A wheel off the ring does nothing.
    const off_ring: input.Wheel = .{ .x = 150, .y = 36, .dx = 0, .dy = 60 };
    try testing.expectEqual(Knob.Action.none, send(cx, &knob, .{ .wheel = off_ring }));
}

// Locks the theme reader: a knob drawn under `theme.light` appends its track arc in light's
// `colors.track` (0.80, 0.81, 0.84, 1), its hovered value arc at light's weight (0.10), and its
// name and value in light's text styles; its accent stays the one it was given.
test "a knob under the light theme draws in its colors" {
    const cx = test_context();
    var knob = Knob.init(ui.id("knob", 0), "k", 0.5, accents[1]);
    knob.hover.value = 1;
    cx.theme_setup(theme.light);
    draw_one(cx, &knob, at(0, 0, 200, knob_height));
    const arcs = cx.draw.items(quads.Arc);
    try testing.expectEqual(@as(usize, 2), arcs.len);
    try testing.expectEqual(theme.light.colors.track, arcs[0].color);
    try testing.expectEqual(@as(f32, 0.10), arcs[1].hover);
    try testing.expectEqual(accents[1].g, arcs[1].color[1]);
    for (cx.draw.items(quads.Glyph)) |glyph| {
        try testing.expectEqual(theme.light.colors.text, glyph.color);
    }
}

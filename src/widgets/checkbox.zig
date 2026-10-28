//! `Checkbox`: a box with a check mark and its label to the right.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. State
//! `on` is the value and `mixed` a third look for a parent whose children differ (a tree): the
//! app sets `mixed`, and a flip by the user clears it and sets `on`, as HTML's `indeterminate`
//! does, so a mixed parent becomes all on. The `check` animator eases toward `on` and carries
//! the fill and the mark's alpha.
//!
//! ## 2. Geometry
//! `box_of(row)` is a `box_side` square at `row.x`, centred vertically; the label starts
//! `box_gap` right of it in the scheme's name style. The default skin's hit shape spans the
//! box and the label's measured width (`hit_of`), so a press on the label flips it too.
//!
//! ## 3. Events
//! ```text
//! hover_in / hover_out          hover follows (no press channel)
//! up inside                     flip
//! Space while focused (no mods) flip                          (`kit.is_space`)
//! ```
//! The area is focusable, so a press focuses it (`ui/cx.zig`, section 7) and Tab visits it in
//! draw order. Every flip returns `toggled` with the new `on`.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const text = @import("../text.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// A checkbox row's height in logical pixels.
pub const checkbox_height: f32 = 28;
/// The box's side, its corner radius, and the space between the box and the label.
pub const box_side: f32 = 16;
pub const box_radius: f32 = 4;
pub const box_gap: f32 = 8;
/// The longest label, in bytes.
pub const checkbox_label_max: u32 = 32;

/// A checkbox's area: focusable, with the default cursor.
pub const checkbox_flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = false,
    .cursor = .default,
};

/// The default checkbox: `CheckboxOf(skins.Default)`.
pub const Checkbox = CheckboxOf(skin.Default);

/// A checkbox drawn by `Skin` (`widgets/skin.zig`). An inside release on the hit shape, or
/// Space while focused, flips it (section 3).
pub fn CheckboxOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .checkbox)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        label: []const u8,
        on: bool,
        /// Neither on nor off: the app's to set; a flip clears it (section 1).
        mixed: bool,
        hover: animator.Animator,
        check: animator.Animator,

        pub const Action = union(enum) {
            none,
            toggled: bool,
        };

        /// A checkbox at rest, its check settled on the side `on` selects.
        pub fn init(id: Id, label: []const u8, on: bool) Self {
            assert(id != .none);
            assert(label.len <= checkbox_label_max);
            const checkbox: Self = .{
                .id = id,
                .label = label,
                .on = on,
                .mixed = false,
                .hover = animator.Animator.init(kit.hover_rate_per_ms),
                .check = kit.settled(kit.hover_rate_per_ms, on),
            };
            assert(!checkbox.check.live());
            return checkbox;
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.check.rate_per_ms > 0);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                kit.step(cx, &self.check, event.frame);
                return .none;
            }
            if (event == .key_down) {
                if (!cx.focused(self.id)) return .none;
                if (!kit.is_space(event.key_down)) return .none;
                return self.flip(cx);
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            if (hit != .up) return .none;
            if (!hit.up.inside) return .none;
            return self.flip(cx);
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.check.value >= 0);
            assert(self.check.value <= 1);
            const row = cx.walk(walk);
            const clip = cx.visible(row) orelse return;
            const shape = Skin.checkbox(cx, .{
                .row = row,
                .clip = clip,
                .label = self.label,
                .check = self.check.value,
                .mixed = self.mixed,
                .hover = self.hover.value,
                .focused = cx.focused(self.id),
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, checkbox_flags);
        }

        fn flip(self: *Self, cx: anytype) Action {
            if (self.mixed) {
                self.mixed = false;
                self.on = true;
            } else {
                self.on = !self.on;
            }
            kit.aim(cx, &self.check, if (self.on) 1 else 0);
            cx.redraw();
            assert(!self.mixed);
            return .{ .toggled = self.on };
        }
    };
}

/// The box of a checkbox row: `box_side` square at the row's left, centred vertically.
pub fn box_of(row: Rect) Rect {
    const box: Rect = .{
        .x = row.x,
        .y = row.y + (row.height - box_side) * 0.5,
        .width = box_side,
        .height = box_side,
    };
    assert(box.width == box_side);
    assert(box.x == row.x);
    return box;
}

/// The label's box: from `box_gap` right of the box to the row's right edge.
pub fn label_of(row: Rect) Rect {
    const start = box_side + box_gap;
    const label: Rect = .{
        .x = row.x + start,
        .y = row.y,
        .width = @max(0, row.width - start),
        .height = row.height,
    };
    assert(label.width >= 0);
    assert(label.height == row.height);
    return label;
}

/// The hit shape of a row whose label is `label` in `style`: the box and the label's measured
/// width, at most the row's, the row's height.
pub fn hit_of(row: Rect, style: text.Style, label: []const u8) Rect {
    assert(label.len <= checkbox_label_max);
    const wide = box_side + box_gap + @ceil(text.measure(style, label));
    const hit: Rect = .{
        .x = row.x,
        .y = row.y,
        .width = @min(row.width, if (label.len == 0) box_side else wide),
        .height = row.height,
    };
    assert(hit.width <= row.width);
    return hit;
}

/// The check mark's three points inside `box`, for a `mark_width` stroke.
pub fn mark_points(box: Rect) [3][2]f32 {
    assert(box.width == box_side);
    assert(box.height == box_side);
    return .{
        .{ box.x + 4, box.y + 8.5 },
        .{ box.x + 7, box.y + 11.5 },
        .{ box.x + 12, box.y + 5 },
    };
}

/// The check mark's stroke width, and the side of the square drawn instead without
/// `draw.Path`; the mixed bar's size.
pub const mark_width: f32 = 2;
pub const mark_square: f32 = 6;
pub const mixed_w: f32 = 8;
pub const mixed_h: f32 = 2;

comptime {
    assert(checkbox_height >= box_side);
    assert(mark_square < box_side and mixed_w < box_side);
    assert(box_radius * 2 < box_side);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const theme = @import("../theme.zig");
const fixture = @import("fixture.zig");
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;

fn space() input.Event {
    return .{ .key_down = input.key_press(.other, .none, false, " ") };
}

// Locks the box and hit geometry (section 2): a 28 px row at (0, 0) puts the 16 px box at
// y 6, the label from x 24, and the hit over box, gap, and the label's ceil'd width.
test "a checkbox lays out its box, label, and hit shape" {
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = checkbox_height };
    try testing.expectEqual(Rect{ .x = 0, .y = 6, .width = 16, .height = 16 }, box_of(row));
    try testing.expectEqual(@as(f32, 24), label_of(row).x);
    const style = theme.dark.name;
    const wide = 24 + @ceil(text.measure(style, "loop"));
    try testing.expectEqual(wide, hit_of(row, style, "loop").width);
    try testing.expectEqual(@as(f32, 16), hit_of(row, style, "").width);
    const cx = fixture.context();
    const checkbox = Checkbox.init(ui.id("check", 0), "loop", false);
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    const area = cx.find(checkbox.id).?;
    try testing.expectEqualSlices(f32, &.{ 0, 0, wide, checkbox_height }, &area.rect);
    try testing.expect(area.flags.focusable);
}

// Locks the flips of section 3: an outside release does nothing, an inside release flips and
// focuses, Space flips only while focused and only without modifiers, and the check eases
// halfway in 50 ms while asking for frames.
test "a checkbox flips on an inside release and on Space while focused" {
    const cx = fixture.context();
    var checkbox = Checkbox.init(ui.id("check", 0), "loop", false);
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    try testing.expectEqual(Checkbox.Action.none, send(cx, &checkbox, space()));
    _ = send(cx, &checkbox, .{ .pointer_down = input.left_at(.{ .x = 8, .y = 14 }) });
    try testing.expect(cx.focused(checkbox.id));
    const outside = send(cx, &checkbox, .{ .pointer_up = input.left_at(.{ .x = 300, .y = 14 }) });
    try testing.expectEqual(Checkbox.Action.none, outside);
    try testing.expect(!checkbox.on);
    _ = send(cx, &checkbox, .{ .pointer_down = input.left_at(.{ .x = 30, .y = 14 }) });
    const up = send(cx, &checkbox, .{ .pointer_up = input.left_at(.{ .x = 30, .y = 14 }) });
    try testing.expectEqual(Checkbox.Action{ .toggled = true }, up);
    try testing.expectEqual(@as(f32, 1), checkbox.check.target);
    cx.animating = false;
    _ = send(cx, &checkbox, .{ .frame = 50 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), checkbox.check.value, 0.0001);
    try testing.expect(cx.animating);
    try testing.expectEqual(Checkbox.Action{ .toggled = false }, send(cx, &checkbox, space()));
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    const chord: input.Event = .{ .key_down = input.key_press(.other, ctrl, false, "") };
    try testing.expectEqual(Checkbox.Action.none, send(cx, &checkbox, chord));
    const enter: input.Event = .{ .key_down = input.key_press(.enter, .none, false, "") };
    try testing.expectEqual(Checkbox.Action.none, send(cx, &checkbox, enter));
}

// Locks the mixed state (section 1): a flip of a mixed box clears `mixed` and turns it on,
// whatever `on` was.
test "a mixed checkbox turns on when flipped" {
    const cx = fixture.context();
    var checkbox = Checkbox.init(ui.id("check", 0), "all", false);
    checkbox.mixed = true;
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    cx.event_begin(.{ .frame = 0 });
    cx.set_focus(checkbox.id);
    cx.event_end();
    try testing.expectEqual(Checkbox.Action{ .toggled = true }, send(cx, &checkbox, space()));
    try testing.expect(!checkbox.mixed);
    try testing.expect(checkbox.on);
}

// Locks the default skin: unchecked, a box and the label; checked, the box, the mark as one
// `draw.Path`, and the label; mixed, two boxes (the box and the bar) and no path.
test "the default checkbox draws its box, mark or bar, and label" {
    const cx = fixture.context();
    var checkbox = Checkbox.init(ui.id("check", 0), "loop", false);
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(draw.Path).len);
    try testing.expectEqual(@as(usize, 4), cx.draw.items(draw.Glyph).len);
    checkbox = Checkbox.init(ui.id("check", 0), "loop", true);
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Path).len);
    checkbox.mixed = true;
    draw_one(cx, &checkbox, at(0, 0, 200, checkbox_height));
    try testing.expectEqual(@as(usize, 2), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(draw.Path).len);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

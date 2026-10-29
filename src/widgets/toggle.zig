//! `Toggle`: a pill with a sliding thumb.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! `pill_of(row)` is a `pill_w` by `pill_h` capsule at `row.x + ring_inset` (`widgets/knob.zig`),
//! centered vertically; the thumb is a `thumb_side` disc,
//! `thumb.x = pill.x + thumb_inset + thumb.value * travel` with `travel = pill_w - thumb_side -
//! 2 * thumb_inset`. The name sits in the knob's label column (`side_box`).
//!
//! ## 2. Events
//! The skin's shape is the hit area (`widgets/skin.zig`; the default skin's is the pill, and
//! `Toggle` is `ToggleOf(skins.Default)`). Hover follows the kit's table without a press
//! channel; a release inside flips `on` and aims the `thumb` animator, which eases on `.frame`
//! beside the hover. Only the thumb disc lightens. `accent`, when set, is the thumb's colour
//! when on: the default skin mixes `colors.control` toward it by the thumb's position.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const knob_file = @import("knob.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// A toggle row's height in logical pixels.
pub const toggle_height: f32 = 40;
pub const pill_w: f32 = 44;
pub const pill_h: f32 = 24;
pub const pill_radius: f32 = 12;
pub const thumb_side: f32 = 20;
pub const thumb_inset: f32 = 2;

/// The default toggle: `ToggleOf(skins.Default)`, a pill with a sliding thumb.
pub const Toggle = ToggleOf(skin.Default);

/// A toggle drawn by `Skin` (`widgets/skin.zig`). A release on the hit shape flips `on` and
/// re-aims the thumb.
pub fn ToggleOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .toggle)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        name: []const u8,
        on: bool,
        hover: animator.Animator,
        thumb: animator.Animator,
        /// The thumb's colour when on, straight RGBA; null is the skin's own.
        accent: ?[4]f32 = null,

        pub const Action = union(enum) {
            none,
            toggled: bool,
        };

        /// A toggle at rest, thumb on the side `on` selects.
        pub fn init(id: Id, name: []const u8, on: bool) Self {
            assert(id != .none);
            assert(name.len <= knob_file.name_max);
            const toggle: Self = .{
                .id = id,
                .name = name,
                .on = on,
                .hover = animator.Animator.init(kit.hover_rate_per_ms),
                .thumb = kit.settled(kit.hover_rate_per_ms, on),
            };
            assert(!toggle.thumb.live());
            return toggle;
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.thumb.rate_per_ms > 0);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                kit.step(cx, &self.thumb, event.frame);
                return .none;
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            if (hit != .up) return .none;
            if (!hit.up.inside) return .none;
            self.on = !self.on;
            kit.aim(cx, &self.thumb, if (self.on) 1 else 0);
            return .{ .toggled = self.on };
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.thumb.value >= 0);
            assert(self.thumb.value <= 1);
            const row = cx.walk(walk);
            const clip = cx.visible(row) orelse return;
            const shape = Skin.toggle(cx, .{
                .row = row,
                .clip = clip,
                .thumb = self.thumb.value,
                .hover = self.hover.value,
                .name = self.name,
                .accent = self.accent,
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, ui.cx.plain);
        }
    };
}

pub fn pill_of(row: Rect) Rect {
    const pill: Rect = .{
        .x = row.x + knob_file.ring_inset,
        .y = row.y + (row.height - pill_h) * 0.5,
        .width = pill_w,
        .height = pill_h,
    };
    assert(pill.width == pill_w);
    assert(pill.height == pill_h);
    return pill;
}

pub fn toggle_thumb(pill: Rect, value: f32) Rect {
    assert(value >= 0);
    assert(value <= 1);
    const thumb: Rect = .{
        .x = pill.x + thumb_inset + value * 20,
        .y = pill.y + thumb_inset,
        .width = thumb_side,
        .height = thumb_side,
    };
    assert(thumb.width == thumb_side);
    assert(thumb.y == pill.y + thumb_inset);
    return thumb;
}

comptime {
    assert(toggle_height == 40);
    // `toggle_thumb` hardcodes the thumb travel as 20.
    assert(pill_w - thumb_side - 2 * thumb_inset == 20);
    // A capsule: the corner radius is half the height.
    assert(pill_radius * 2 == pill_h);
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const quads = @import("../draw.zig");
const test_context = fixture.context;
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;

// Locks the toggle thumb travel to the pill interior and the release-inside flip rule, and
// that the thumb eases on `.frame` while asking for more frames.
test "toggle thumb spans the pill and flips only on an inside release" {
    const cx = test_context();
    var toggle = Toggle.init(ui.id("toggle", 0), "t", false);
    // Row y = 0 and height = 40, so the pill is centered: y = (40 - 24) / 2 = 8.
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = toggle_height };
    const pill = pill_of(row);
    const off = toggle_thumb(pill, 0);
    const on = toggle_thumb(pill, 1);
    try testing.expectEqual(pill.x + thumb_inset, off.x);
    try testing.expectEqual(pill.x + pill.width - thumb_inset, on.x + on.width);
    try testing.expectEqual(pill.y + thumb_inset, off.y);
    draw_one(cx, &toggle, at(0, 0, 200, toggle_height));
    _ = send(cx, &toggle, .{ .pointer_down = input.left_at(.{ .x = 30, .y = 20 }) });
    const outside: input.Point = .{ .x = 300, .y = 20 };
    try testing.expectEqual(
        Toggle.Action.none,
        send(cx, &toggle, .{ .pointer_up = input.left_at(outside) }),
    );
    try testing.expect(!toggle.on);
    _ = send(cx, &toggle, .{ .pointer_down = input.left_at(.{ .x = 30, .y = 20 }) });
    try testing.expect(send(
        cx,
        &toggle,
        .{ .pointer_up = input.left_at(.{ .x = 30, .y = 20 }) },
    ).toggled);
    try testing.expectEqual(@as(f32, 1), toggle.thumb.target);
    cx.animating = false;
    _ = send(cx, &toggle, .{ .frame = 50 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), toggle.thumb.value, 0.0001);
    try testing.expect(cx.animating);
}

// Locks the accent: with none the thumb is `colors.control` either way; with one the default
// skin mixes control toward it by the thumb, all the way when on. The pill is unchanged.
test "a toggle's accent colours its thumb when on" {
    const cx = test_context();
    var toggle = Toggle.init(ui.id("toggle", 0), "compander", true);
    draw_one(cx, &toggle, at(0, 0, 200, toggle_height));
    const control = cx.theme().colors.control;
    try testing.expectEqual(control, cx.draw.items(quads.Box)[1].fill);
    const accent = [4]f32{ 0.2, 0.9, 0.4, 1 };
    toggle.accent = accent;
    draw_one(cx, &toggle, at(0, 0, 200, toggle_height));
    const boxes = cx.draw.items(quads.Box);
    try testing.expectEqual(cx.theme().colors.track, boxes[0].fill);
    for (accent, boxes[1].fill) |want, got| try testing.expectApproxEqAbs(want, got, 1e-6);
}

//! `Disclosure`: a header with a chevron over a section the app draws only while it is open.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! A disclosure keeps the turtle's begin/end shape, as `Panel.begin` does:
//! ```text
//! if (d.begin(cx, walk, layout)) {    a container for walk, the header walked first
//!     ... the app draws the section ...
//! }
//! d.end(cx)                           closes the container
//! ```
//! With a `fit` height the container is the header alone while closed and the header and the
//! section while open, so a column of disclosures is a property grid whose groups fold. The
//! header is `fill` wide and `disclosure_h` high.
//!
//! ## 2. Events
//! ```text
//! hover_in / hover_out            hover follows (no press channel)
//! up inside                       flip
//! Space or Enter while focused    flip
//! ```
//! The header is focusable, so a press focuses it and Tab visits it. A flip returns `toggled`
//! with the new `open` and aims `turn`, which eases the chevron from pointing right (0, closed)
//! to down (1, open) on `.frame`; the section itself appears or goes at once.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// The header's height, in logical pixels.
pub const disclosure_h: f32 = 28;
/// The chevron's cell at the header's left, and the label's start after it.
pub const disclosure_chevron_w: f32 = 24;
/// The header's corner radius.
pub const disclosure_radius: f32 = 4;
/// The longest label, in bytes.
pub const disclosure_label_max: u32 = 64;

/// The header's area: focusable, with the default cursor.
pub const disclosure_flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = false,
    .cursor = .default,
};

/// The default disclosure: `DisclosureOf(skins.Default)`.
pub const Disclosure = DisclosureOf(skin.Default);

/// A header drawn by `Skin` (`Skin.disclosure`; `widgets/skin.zig`) over a section the app
/// draws while `open` (section 1).
pub fn DisclosureOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .disclosure)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        label: []const u8,
        open: bool,
        /// The chevron: 0 closed, 1 open, eased.
        turn: animator.Animator,
        hover: animator.Animator,

        pub const Action = union(enum) {
            none,
            toggled: bool,
        };

        /// A disclosure at rest, open or closed.
        pub fn init(id: Id, label: []const u8, open: bool) Self {
            assert(id != .none);
            assert(label.len <= disclosure_label_max);
            const disclosure: Self = .{
                .id = id,
                .label = label,
                .open = open,
                .turn = kit.settled(kit.hover_rate_per_ms, open),
                .hover = animator.Animator.init(kit.hover_rate_per_ms),
            };
            assert(!disclosure.turn.live());
            return disclosure;
        }

        /// Opens a container for `walk` laid out by `layout`, walks and draws the header, and
        /// returns whether the app draws the section (section 1). Draw phase.
        pub fn begin(self: *const Self, cx: anytype, walk: Walk, layout: ui.Layout) bool {
            assert(self.turn.value >= 0 and self.turn.value <= 1);
            assert(layout.flow == .down);
            _ = cx.begin(walk, layout);
            const header = cx.walk(ui.sized(.fill, .{ .fixed = disclosure_h }));
            const clip = cx.visible(header) orelse return self.open;
            const shape = Skin.disclosure(cx, .{
                .rect = header,
                .clip = clip,
                .label = self.label,
                .turn = self.turn.value,
                .hover = self.hover.value,
                .focused = cx.focused(self.id),
            }) orelse return self.open;
            cx.area(self.id, shape.rect, shape.radius, disclosure_flags);
            return self.open;
        }

        /// Closes the container `begin` opened.
        pub fn end(self: *const Self, cx: anytype) void {
            assert(self.id != .none);
            _ = cx.end();
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.turn.rate_per_ms > 0);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                kit.step(cx, &self.turn, event.frame);
                return .none;
            }
            if (event == .key_down) {
                if (!cx.focused(self.id)) return .none;
                const press = event.key_down;
                if (press.key != .enter and !kit.is_space(press)) return .none;
                return self.flip(cx);
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            if (hit != .up) return .none;
            if (!hit.up.inside) return .none;
            return self.flip(cx);
        }

        fn flip(self: *Self, cx: anytype) Action {
            self.open = !self.open;
            kit.aim(cx, &self.turn, if (self.open) 1 else 0);
            cx.redraw();
            return .{ .toggled = self.open };
        }
    };
}

comptime {
    assert(disclosure_h > 0);
    assert(disclosure_chevron_w < disclosure_h * 2);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

/// Draws `disclosure` 200 px wide with a fit height at (0, 0), a 40 px section while open, then
/// a probe; returns the probe's y.
fn draw_disclosure(cx: *fixture.Context, disclosure: *const Disclosure) f32 {
    cx.begin_frame(1280, 720, 120);
    _ = cx.begin(fixture.at(0, 0, 300, 400), .{ .flow = .down });
    if (disclosure.begin(cx, ui.sized(.{ .fixed = 200 }, .fit), .{ .flow = .down })) {
        _ = cx.walk(ui.sized(.fill, .{ .fixed = 40 }));
    }
    disclosure.end(cx);
    const probe = cx.walk(ui.sized(.{ .fixed = 10 }, .{ .fixed = 10 }));
    _ = cx.end();
    _ = cx.end_frame();
    return probe.y;
}

fn key(name: input.Key, utf8: []const u8) input.Event {
    return .{ .key_down = input.key_press(name, .none, false, utf8) };
}

// Locks section 1: closed, the fit container is the 28 px header alone and the next sibling
// walks at y 28; open, it holds the 40 px section too (y 68); the header is a focusable area
// 200 x 28.
test "a disclosure fits its header closed and its section open" {
    const cx = fixture.context();
    var disclosure = Disclosure.init(ui.id("group", 0), "transform", false);
    try testing.expectEqual(@as(f32, 28), draw_disclosure(cx, &disclosure));
    const area = cx.find(disclosure.id).?;
    try testing.expectEqualSlices(f32, &.{ 0, 0, 200, 28 }, &area.rect);
    try testing.expect(area.flags.focusable);
    disclosure.open = true;
    try testing.expectEqual(@as(f32, 68), draw_disclosure(cx, &disclosure));
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks section 2: an inside release opens it and focuses it, the chevron eases halfway in
// 50 ms, Space closes and Enter opens while focused, and another key does nothing.
test "a disclosure flips on a click, Space, and Enter" {
    const cx = fixture.context();
    var disclosure = Disclosure.init(ui.id("group", 0), "layout", false);
    _ = draw_disclosure(cx, &disclosure);
    const point: input.Point = .{ .x = 100, .y = 14 };
    _ = fixture.send(cx, &disclosure, .{ .pointer_down = input.left_at(point) });
    try testing.expect(cx.focused(disclosure.id));
    const opened = fixture.send(cx, &disclosure, .{ .pointer_up = input.left_at(point) });
    try testing.expectEqual(Disclosure.Action{ .toggled = true }, opened);
    cx.animating = false;
    _ = fixture.send(cx, &disclosure, .{ .frame = 50 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), disclosure.turn.value, 0.0001);
    try testing.expect(cx.animating);
    const closed = fixture.send(cx, &disclosure, key(.other, " "));
    try testing.expectEqual(Disclosure.Action{ .toggled = false }, closed);
    const again = fixture.send(cx, &disclosure, key(.enter, ""));
    try testing.expectEqual(Disclosure.Action{ .toggled = true }, again);
    try testing.expectEqual(Disclosure.Action.none, fixture.send(cx, &disclosure, key(.a, "a")));
}

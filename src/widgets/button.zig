//! `Button`: a clickable face with a centered label.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Events
//! The hover and press animators follow the kit's table (`kit.respond`, `widgets/kit.zig`,
//! section 3) exactly: a press lightens and darkens, a release inside clicks and lets the
//! darken go, a release outside lets both go. `.frame` eases them.
//!
//! ## 2. Drawing
//! `ButtonOf(Skin)` hands the skin a `ButtonLook` and records the hit shape it returns
//! (`widgets/skin.zig`); `Button` is `ButtonOf(skins.Default)`. The default look is the face
//! (`Paint.look` of the two animator values), then the label inside `padding`; the face is the
//! hit area, rounded by the paint's radius.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Walk = kit.Walk;
const Id = kit.Id;
const Inset = kit.Inset;

/// The default button: `ButtonOf(skins.Default)`, a face with a centered label.
pub const Button = ButtonOf(skin.Default);

/// A clickable button drawn by `Skin` (`widgets/skin.zig`): the behaviour below, `Skin.button`
/// for the look and the hit shape.
pub fn ButtonOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .button)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        label: []const u8,
        style: text.Style,
        padding: Inset,
        paint: kit.Paint,
        hover: animator.Animator,
        down: animator.Animator,

        pub const Action = enum {
            none,
            clicked,
        };

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                kit.step(cx, &self.down, event.frame);
                return .none;
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, &self.down);
            if (hit == .up and hit.up.inside) return .clicked;
            return .none;
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.id != .none);
            assert(self.label.len <= text.byte_cap);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            const shape = Skin.button(cx, .{
                .rect = rect,
                .clip = clip,
                .label = self.label,
                .style = self.style,
                .padding = self.padding,
                .paint = self.paint,
                .hover = self.hover.value,
                .down = self.down.value,
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, ui.cx.plain);
        }
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const test_context = fixture.context;
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;
const hover_rate_per_ms = kit.hover_rate_per_ms;
const down_rate_per_ms = kit.down_rate_per_ms;

fn sample_button() Button {
    return .{
        .id = ui.id("button", 0),
        .label = "Cycle",
        .style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } },
        .padding = .{ .left = 16, .top = 0, .right = 16, .bottom = 0 },
        .paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 24 },
        .hover = animator.Animator.init(hover_rate_per_ms),
        .down = animator.Animator.init(down_rate_per_ms),
    };
}

// Locks the click rule: a release over the button clicks once, a release elsewhere does not,
// and both release the press darken.
test "button up inside clicks and up outside does not" {
    const cx = test_context();
    var button = sample_button();
    draw_one(cx, &button, at(0, 0, 80, 48));
    const inside: input.Point = .{ .x = 40, .y = 24 };
    const outside: input.Point = .{ .x = 400, .y = 400 };
    try testing.expectEqual(
        Button.Action.none,
        send(cx, &button, .{ .pointer_down = input.left_at(inside) }),
    );
    try testing.expectEqual(@as(f32, 1), button.down.target);
    try testing.expectEqual(
        Button.Action.clicked,
        send(cx, &button, .{ .pointer_up = input.left_at(inside) }),
    );
    try testing.expectEqual(@as(f32, 0), button.down.target);
    _ = send(cx, &button, .{ .pointer_down = input.left_at(inside) });
    try testing.expectEqual(
        Button.Action.none,
        send(cx, &button, .{ .pointer_up = input.left_at(outside) }),
    );
    try testing.expectEqual(@as(f32, 0), button.hover.target);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

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
//! The face (`Paint.look` of the two animator values), then the label inside `padding`. The
//! face is the hit area, rounded by the paint's radius.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");

const Walk = kit.Walk;
const Id = kit.Id;
const Inset = kit.Inset;

/// A clickable face with a centered label.
pub const Button = struct {
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

    pub fn handle(self: *Button, cx: anytype, event: input.Event) Action {
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

    pub fn draw(self: *const Button, cx: anytype, walk: Walk) void {
        assert(self.id != .none);
        assert(self.label.len <= text.byte_cap);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        cx.area(self.id, rect, self.paint.radius, ui.cx.plain);
        kit.face(cx, rect, clip, self.paint.look(cx.theme(), self.hover.value, self.down.value));
        const inner = ui.cx.inset(rect, self.padding);
        kit.label(cx, self.style, self.label, inner, clip, kit.centered);
    }
};

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

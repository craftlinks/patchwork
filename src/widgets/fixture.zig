//! Test support shared by the widget files: one static UI context and the helpers that drive a
//! widget the way an app does. Only tests import it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Static
//! A UI context holds its pools inline, so it lives in a static, never on the test's stack.
//! `context` re-initializes it, so every test starts from a fresh one.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");

/// Box instances the context holds; `kit`'s append test fills it.
pub const box_cap: u32 = 16;

const draw_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = box_cap },
    .{ .type = draw.Arc, .cap = 16 },
    .{ .type = draw.Glyph, .cap = 128 },
    .{ .type = draw.Path, .cap = 8 },
    .{ .type = draw.Glass, .cap = 4 },
};

pub const Context = ui.Context(draw.Context(&draw_types, 16, 64), 16);

/// A freshly initialized static context, so tests keep the pools off the stack.
pub fn context() *Context {
    const static = struct {
        var value: Context = undefined;
    };
    static.value.init();
    assert(static.value.draw.overflow_count == 0);
    return &static.value;
}

/// The walk that puts a `width` by `height` box at `(x, y)` under the root turtle.
pub fn at(x: f32, y: f32, width: f32, height: f32) ui.Walk {
    assert(width >= 0);
    assert(height >= 0);
    return .{
        .width = .{ .fixed = width },
        .height = .{ .fixed = height },
        .margin = .{ .left = x, .top = y, .right = 0, .bottom = 0 },
    };
}

/// Dispatches `event` to one widget the way an app's `event` does.
pub fn send(cx: *Context, widget: anytype, event: input.Event) @TypeOf(widget.*).Action {
    cx.event_begin(event);
    const action = widget.handle(cx, event);
    cx.event_end();
    return action;
}

/// Draws one widget at `walk` in a fresh 1280 by 720 frame.
pub fn draw_one(cx: *Context, widget: anytype, walk: ui.Walk) void {
    cx.begin_frame(1280, 720, 120);
    widget.draw(cx, walk);
    _ = cx.end_frame();
}

/// Dispatches a touch event to one widget the way `ui.dispatch` does: each pointer event the
/// touch means, in order, with the contact's state loaded. Returns the widget's action for each
/// (`.none` for a lift's second event when it did nothing), and null when the event was for no
/// contact. A repeated down of a live id is not cancelled here.
pub fn send_touch(
    cx: *Context,
    widget: anytype,
    event: input.Event,
) ?[2]@TypeOf(widget.*).Action {
    const plan = cx.touch_begin(event) orelse return null;
    var actions: [2]@TypeOf(widget.*).Action = .{ .none, .none };
    for (plan.events[0..plan.count], 0..) |pointer_event, slot| {
        cx.event_begin(pointer_event);
        actions[slot] = widget.handle(cx, pointer_event);
        cx.event_end();
    }
    cx.touch_end();
    return actions;
}

/// A finger landing at `(x, y)`.
pub fn finger_down(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = 0, .serial = 100 + id } };
}

/// A finger moving to `(x, y)`.
pub fn finger_move(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_move = .{ .id = id, .x = x, .y = y, .time_ms = 0 } };
}

/// A finger lifting.
pub fn finger_up(id: u32) input.Event {
    return .{ .touch_up = .{ .id = id, .time_ms = 0 } };
}

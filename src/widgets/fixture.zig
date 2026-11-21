//! Test support shared by the widget files: one static UI context and the helpers that drive a
//! widget the way an app does. Only tests import it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Static
//! A UI context holds its pools inline, so it lives in a static, never on the test's stack.
//! `context` re-initializes it, so every test starts from a fresh one. `bare_context` is a
//! second one without `draw.Path` and `draw.Glass`, for the skins' fallback branches.
//!
//! ## 2. Tally
//! `Tally(need)` checks that frames hold exactly what an `Appends` says (`widgets/appends.zig`):
//! `observe`, after `end_frame`, reads every type the context registers, its points, and its
//! areas, and fails when one is above `need` (a type `need` does not name must be 0) or when
//! anything overflowed; `expect_reached` fails unless every count of `need` was reached by some
//! observed frame. A type no observed context registers is skipped (`draw.Glass` in a tally of
//! bare frames only). Reading every registered type, not only those `need` names, is what makes
//! an undeclared append fail.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const appends = @import("appends.zig");

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

/// `context`'s types and caps without `draw.Path` and `draw.Glass`.
const bare_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = box_cap },
    .{ .type = draw.Arc, .cap = 16 },
    .{ .type = draw.Glyph, .cap = 128 },
};

pub const BareContext = ui.Context(draw.Context(&bare_types, 16, 64), 16);

/// A freshly initialized static context that registers Box, Arc, and Glyph only, so a skin
/// takes its fallback branches.
pub fn bare_context() *BareContext {
    const static = struct {
        var value: BareContext = undefined;
    };
    static.value.init();
    assert(static.value.draw.overflow_count == 0);
    comptime assert(!BareContext.DrawContext.Registry.has(draw.Path));
    return &static.value;
}

/// Checks observed frames against `need` (module guide, section 2).
pub fn Tally(comptime need: appends.Appends) type {
    comptime {
        assert(appends.repeated(need.draws) == null);
    }
    return struct {
        const Self = @This();

        /// The most each entry of `need.draws` reached, and whether a context registered it.
        most: [need.draws.len]u32 = @splat(0),
        seen: [need.draws.len]bool = @splat(false),
        points_most: u32 = 0,
        points_seen: bool = false,
        areas_most: u32 = 0,
        frames: u32 = 0,

        /// Reads one frame of `cx` (after `end_frame`): fails when a count is above `need` or
        /// anything overflowed, and keeps each count's maximum.
        pub fn observe(self: *Self, cx: anytype) !void {
            const R = @TypeOf(cx.*).DrawContext.Registry;
            if (!std.meta.eql(cx.overflow(), ui.cx.Overflow.zero)) {
                std.debug.print("overflow: {any}\n", .{cx.overflow()});
                return error.TallyOverflow;
            }
            inline for (0..R.count) |index| {
                const T = R.Type(index);
                const count: u32 = @intCast(cx.draw.items(T).len);
                const bound = comptime need.of(T);
                if (count > bound) {
                    std.debug.print("{s}: {d} over {d}\n", .{ @typeName(T), count, bound });
                    return error.TallyExceeded;
                }
                if (comptime slot(T)) |entry_index| {
                    self.seen[entry_index] = true;
                    self.most[entry_index] = @max(self.most[entry_index], count);
                }
            }
            if (R.uses_points) self.points_seen = true;
            if (cx.draw.point_count > need.points) {
                std.debug.print("points: {d} over {d}\n", .{ cx.draw.point_count, need.points });
                return error.TallyExceeded;
            }
            if (cx.area_count > need.areas) {
                std.debug.print("areas: {d} over {d}\n", .{ cx.area_count, need.areas });
                return error.TallyExceeded;
            }
            self.points_most = @max(self.points_most, cx.draw.point_count);
            self.areas_most = @max(self.areas_most, cx.area_count);
            self.frames += 1;
            assert(self.points_most <= need.points);
            assert(self.areas_most <= need.areas);
        }

        /// Fails unless every count of `need` equals its maximum over the observed frames.
        pub fn expect_reached(self: *const Self) !void {
            assert(self.frames >= 1);
            assert(self.areas_most <= need.areas);
            inline for (need.draws, 0..) |entry, entry_index| {
                if (self.seen[entry_index] and self.most[entry_index] != entry.count) {
                    const name = @typeName(entry.type);
                    const most = self.most[entry_index];
                    std.debug.print("{s}: reached {d} of {d}\n", .{ name, most, entry.count });
                    return error.TallyNotReached;
                }
            }
            if (self.points_seen and self.points_most != need.points) {
                std.debug.print("points: reached {d} of {d}\n", .{ self.points_most, need.points });
                return error.TallyNotReached;
            }
            if (self.areas_most != need.areas) {
                std.debug.print("areas: reached {d} of {d}\n", .{ self.areas_most, need.areas });
                return error.TallyNotReached;
            }
        }

        /// The index of `T` in `need.draws`, or null.
        fn slot(comptime T: type) ?usize {
            for (need.draws, 0..) |entry, entry_index| {
                if (entry.type == T) return entry_index;
            }
            return null;
        }
    };
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

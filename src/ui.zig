//! Retained pointer dispatch over an app-defined widget union.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Generic Dispatcher
//! Every app owns a flat array of widgets and needs the same pointer arbitration: find the
//! topmost widget under the pointer, track hover, capture a press until release, forward
//! wheel input, step animators, and re-hit the stored pointer after a relayout.
//! `Scene(Widget, widget_cap)` implements that once. The app supplies a tagged union of
//! the widget kinds it uses, so adding a widget kind never edits the library.
//!
//! Payloads are called through `switch (widget.*) { inline else => ... }`, which keeps
//! dispatch static (no vtable, no function pointer) with one line per operation instead of
//! one arm per widget kind. The dispatcher does no layout and no drawing.
//!
//! ## 2. The Widget Contract
//! `Widget` must be a tagged union. Every payload type `P` declares:
//!
//! ```text
//! id: u32                                    non-zero, stable for the widget's life
//! handle(self: *P, hit: widgets.Hit) bool    true when a visible value changed
//! animate(self: *P, dt_ms: f32) bool         true when a visible value changed
//! live(self: P) bool                         true while an animator has not settled
//! contains(self: P, x: f32, y: f32) bool     hit test in logical pixels
//! ```
//!
//! A missing member is a compile error from the first call that needs it. The wrappers
//! `widget_handle`, `widget_animate`, `widget_live`, and `widget_contains` assert `id != 0`,
//! and `widget_handle` also asserts the id is unchanged by the call.
//!
//! ## 3. Coordinate Space and Hit Order
//! All points are UI logical pixels: origin top-left, `+X` right, `+Y` down. The widget
//! array is scanned from the last slot to the first, so a later slot paints over, and wins
//! the hit against, an earlier one. Apps place a container before its children.
//!
//! ## 4. State Machine
//! ```text
//!                 pointer_down inside widget i
//!   idle  ---------------------------------------->  captured(i)
//!    ^                                                   |
//!    |   pointer_up / pointer_leave: send .up, clear     |  pointer_move: send .drag
//!    +---------------------------------------------------+
//! ```
//! While captured, hover does not change and every move is a `.drag` for the captured slot.
//! `hover_in` and `hover_out` are sent only when the topmost slot changes.
//!
//! ## 5. Dirty Contract
//! `dirty` is set whenever an event or a relayout changes something visible. The app's
//! `draw` calls `finish_draw` to clear it. The host reads it through `App.dirty()`.
//!
//! ## 6. TigerStyle Invariants
//! - Storage is a fixed array of `widget_cap` slots. There is no allocation.
//! - Every loop is bounded by `count <= widget_cap`.
//! - No recursion. Scroll children are dispatched by the payload, not by this type.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("input.zig");
const widgets = @import("widgets.zig");

/// Dispatcher over `widget_cap` slots of the tagged union `Widget`.
/// `capture` and `hovered` are slot indices below `count`, or null. `pointer` and `was_down`
/// mirror the last pointer event so `finish_layout` can re-hit it.
pub fn Scene(comptime Widget: type, comptime widget_cap: u32) type {
    comptime {
        assert(widget_cap != 0);
        assert(@typeInfo(Widget) == .@"union");
        assert(@typeInfo(Widget).@"union".tag_type != null);
    }
    return struct {
        const Self = @This();

        widgets: [widget_cap]Widget,
        count: u32,
        pointer: input.Pointer,
        was_down: bool,
        capture: ?u32,
        hovered: ?u32,
        dirty: bool,
        width_logical: u32,
        height_logical: u32,

        /// Slot capacity, for apps that size their own tables against it.
        pub const capacity: u32 = widget_cap;

        /// A scene of `count` slots, `0 < count <= widget_cap`. The app must fill every slot
        /// before the first layout, because slots start undefined.
        pub fn init(count: u32) Self {
            assert(count != 0);
            assert(count <= widget_cap);
            const scene: Self = .{
                .widgets = undefined,
                .count = count,
                .pointer = input.Pointer.init(),
                .was_down = false,
                .capture = null,
                .hovered = null,
                .dirty = false,
                .width_logical = 0,
                .height_logical = 0,
            };
            assert(!scene.pointer.inside);
            assert(scene.capture == null);
            return scene;
        }

        /// Records a finished layout, marks the scene dirty, and re-hits the stored
        /// pointer so hover follows the widget that now sits under it.
        pub fn finish_layout(self: *Self, width_logical: u32, height_logical: u32) void {
            assert(width_logical != 0);
            assert(height_logical != 0);
            self.width_logical = width_logical;
            self.height_logical = height_logical;
            self.dirty = true;
            self.redispatch();
            assert(self.dirty);
            assert(self.width_logical == width_logical);
        }

        /// Clears `dirty` after the app rebuilt its draw lists from this scene.
        pub fn finish_draw(self: *Self) void {
            assert(self.width_logical != 0);
            assert(self.height_logical != 0);
            self.dirty = false;
            assert(!self.dirty);
        }

        /// Applies one event. Returns true when a visible value changed.
        pub fn handle_event(self: *Self, event: input.Event) bool {
            assert(self.count <= widget_cap);
            assert(self.width_logical == self.width_logical);
            switch (event) {
                .pointer_move => |point| return self.on_move(point),
                .pointer_down => |point| return self.on_down(point),
                .pointer_up => |point| return self.on_up(point),
                .pointer_leave => return self.on_leave(),
                .frame => |dt_ms| return self.on_frame(dt_ms),
                .wheel => |wheel| return self.on_wheel(wheel),
            }
        }

        /// True while any widget animator has not reached its target.
        pub fn live(self: *const Self) bool {
            assert(self.count <= widget_cap);
            var index: u32 = 0;
            while (index < self.count) : (index += 1) {
                if (widget_live(&self.widgets[index])) {
                    assert(index < self.count);
                    return true;
                }
            }
            assert(index == self.count);
            return false;
        }

        fn on_move(self: *Self, point: input.Point) bool {
            assert(point.x == point.x);
            assert(point.y == point.y);
            self.pointer.move(point.x, point.y);
            self.was_down = self.pointer.down;
            if (self.capture) |index| {
                assert(self.pointer.down);
                return self.mark(self.send(index, .{ .drag = point }));
            }
            var changed = self.dispatch_hover(point);
            if (self.hovered) |index| {
                if (self.send(index, .{ .move = point })) {
                    changed = true;
                }
            }
            return self.mark(changed);
        }

        fn on_down(self: *Self, point: input.Point) bool {
            self.pointer.move(point.x, point.y);
            self.pointer.button(true);
            self.was_down = true;
            var changed = self.dispatch_hover(point);
            if (self.hovered) |index| {
                if (self.send(index, .{ .move = point })) {
                    changed = true;
                }
                self.capture = index;
                if (self.send(index, .{ .down = point })) {
                    changed = true;
                }
            }
            assert(self.pointer.down);
            assert(self.was_down);
            return self.mark(changed);
        }

        fn on_up(self: *Self, point: input.Point) bool {
            self.pointer.move(point.x, point.y);
            self.pointer.button(false);
            self.was_down = false;
            var changed = false;
            if (self.capture) |index| {
                const inside = widget_contains(&self.widgets[index], point.x, point.y);
                const up: widgets.Up = .{ .x = point.x, .y = point.y, .inside = inside };
                if (self.send(index, .{ .up = up })) {
                    changed = true;
                }
                self.capture = null;
            }
            if (self.dispatch_hover(point)) {
                changed = true;
            }
            if (self.hovered) |index| {
                if (self.send(index, .{ .move = point })) {
                    changed = true;
                }
            }
            assert(!self.pointer.down);
            assert(self.capture == null);
            return self.mark(changed);
        }

        fn on_leave(self: *Self) bool {
            var changed = false;
            if (self.capture) |index| {
                const up: widgets.Up = .{
                    .x = self.pointer.x,
                    .y = self.pointer.y,
                    .inside = false,
                };
                if (self.send(index, .{ .up = up })) {
                    changed = true;
                }
                self.capture = null;
            }
            if (self.hovered) |index| {
                if (self.send(index, .hover_out)) {
                    changed = true;
                }
                self.hovered = null;
            }
            self.pointer.leave();
            self.was_down = false;
            assert(self.capture == null);
            assert(!self.pointer.down);
            return self.mark(changed);
        }

        fn on_frame(self: *Self, dt_ms: f32) bool {
            assert(dt_ms >= 0);
            assert(self.count <= widget_cap);
            var changed = false;
            var index: u32 = 0;
            while (index < self.count) : (index += 1) {
                if (widget_animate(&self.widgets[index], dt_ms)) {
                    changed = true;
                }
            }
            assert(index == self.count);
            return self.mark(changed);
        }

        fn on_wheel(self: *Self, wheel: input.Wheel) bool {
            assert(wheel.dy == wheel.dy);
            self.pointer.move(wheel.x, wheel.y);
            var changed = false;
            if (self.capture == null) {
                if (self.dispatch_hover(.{ .x = wheel.x, .y = wheel.y })) {
                    changed = true;
                }
                if (self.hovered) |index| {
                    if (self.send(index, .{ .move = .{ .x = wheel.x, .y = wheel.y } })) {
                        changed = true;
                    }
                }
            }
            if (self.topmost(wheel.x, wheel.y)) |index| {
                if (self.send(index, .{ .wheel = wheel })) {
                    changed = true;
                }
            }
            assert(self.count <= widget_cap);
            return self.mark(changed);
        }

        fn redispatch(self: *Self) void {
            assert(self.count <= widget_cap);
            if (!self.pointer.inside) {
                self.clear_hover();
                assert(!self.pointer.inside);
                return;
            }
            const point: input.Point = .{ .x = self.pointer.x, .y = self.pointer.y };
            if (self.capture) |index| {
                assert(self.was_down);
                _ = self.send(index, .{ .drag = point });
                return;
            }
            _ = self.dispatch_hover(point);
            if (self.hovered) |index| {
                _ = self.send(index, .{ .move = point });
            }
            assert(self.pointer.inside);
        }

        fn dispatch_hover(self: *Self, point: input.Point) bool {
            assert(self.count <= widget_cap);
            const next = self.topmost(point.x, point.y);
            if (same_hover(self.hovered, next)) {
                assert(self.count <= widget_cap);
                return false;
            }
            var changed = false;
            if (self.hovered) |previous| {
                if (self.send(previous, .hover_out)) {
                    changed = true;
                }
            }
            if (next) |chosen| {
                if (self.send(chosen, .hover_in)) {
                    changed = true;
                }
            }
            self.hovered = next;
            assert(same_hover(self.hovered, next));
            return changed;
        }

        fn clear_hover(self: *Self) void {
            if (self.hovered) |previous| {
                _ = self.send(previous, .hover_out);
                self.hovered = null;
            }
            assert(self.hovered == null);
            assert(self.count <= widget_cap);
        }

        fn topmost(self: *const Self, x: f32, y: f32) ?u32 {
            assert(self.count <= widget_cap);
            var index: u32 = self.count;
            while (index > 0) {
                index -= 1;
                if (widget_contains(&self.widgets[index], x, y)) {
                    assert(index < self.count);
                    return index;
                }
            }
            assert(index == 0);
            return null;
        }

        fn send(self: *Self, index: u32, hit: widgets.Hit) bool {
            assert(index < self.count);
            assert(self.count <= widget_cap);
            return widget_handle(&self.widgets[index], hit);
        }

        fn mark(self: *Self, changed: bool) bool {
            if (changed) {
                self.dirty = true;
            }
            assert(self.count <= widget_cap);
            assert(self.capture == null or self.capture.? < self.count);
            return changed;
        }

        fn widget_handle(widget: *Widget, hit: widgets.Hit) bool {
            switch (widget.*) {
                inline else => |*payload| {
                    const before = payload.id;
                    assert(before != 0);
                    const changed = payload.handle(hit);
                    assert(payload.id == before);
                    return changed;
                },
            }
        }

        fn widget_animate(widget: *Widget, dt_ms: f32) bool {
            assert(dt_ms >= 0);
            switch (widget.*) {
                inline else => |*payload| {
                    assert(payload.id != 0);
                    return payload.animate(dt_ms);
                },
            }
        }

        fn widget_live(widget: *const Widget) bool {
            switch (widget.*) {
                inline else => |*payload| {
                    assert(payload.id != 0);
                    return payload.live();
                },
            }
        }

        fn widget_contains(widget: *const Widget, x: f32, y: f32) bool {
            assert(x == x);
            assert(y == y);
            switch (widget.*) {
                inline else => |*payload| {
                    assert(payload.id != 0);
                    return payload.contains(x, y);
                },
            }
        }
    };
}

fn same_hover(hovered: ?u32, next: ?u32) bool {
    if (hovered) |previous| {
        if (next) |chosen| {
            return previous == chosen;
        }
        assert(next == null);
        return false;
    }
    if (next == null) {
        assert(hovered == null);
        return true;
    }
    assert(next != null);
    return false;
}

/// Smallest widget union that satisfies the widget contract, for the tests below.
const TestWidget = union(enum) {
    panel: widgets.Panel,
    slider: widgets.Slider,
};

const TestScene = Scene(TestWidget, 4);

// Locks the `init` postconditions: no capture, no hover, clean, and `capacity` is the cap.
test "an empty scene starts idle and clean" {
    const scene = TestScene.init(2);
    try std.testing.expectEqual(@as(u32, 2), scene.count);
    try std.testing.expect(scene.capture == null);
    try std.testing.expect(scene.hovered == null);
    try std.testing.expect(!scene.dirty);
    try std.testing.expectEqual(@as(u32, 4), TestScene.capacity);
}

// Locks `same_hover` over both positive and negative spaces of (null, some) pairs.
test "same_hover covers all four combinations" {
    try std.testing.expect(same_hover(null, null));
    try std.testing.expect(!same_hover(null, 3));
    try std.testing.expect(!same_hover(3, null));
    try std.testing.expect(same_hover(3, 3));
    try std.testing.expect(!same_hover(3, 4));
}

// Locks the dirty contract: `finish_layout` sets it, `finish_draw` clears it.
test "finish_layout marks dirty and finish_draw clears it" {
    var scene = TestScene.init(1);
    try std.testing.expect(!scene.dirty);
    scene.finish_layout(640, 480);
    try std.testing.expect(scene.dirty);
    try std.testing.expectEqual(@as(u32, 640), scene.width_logical);
    scene.finish_draw();
    try std.testing.expect(!scene.dirty);
}

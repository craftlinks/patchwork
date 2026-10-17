//! Pointer snapshot and the bounded event queue the native loop drains once per wake.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Queue Instead of a Latest-State Snapshot?
//! Wayland delivers socket messages in batches. If the loop only kept the latest pointer state,
//! a press followed by a release inside one batch would overwrite itself to `down == false`
//! before the app ran, and the click edge would be lost. `EventQueue` keeps events in the order
//! the platform observed them, and the loop drains it once per wake.
//!
//! ### Ordering and Coalescing Rules
//! - Presses, releases, leaves, and frames are never merged or reordered, so click transitions
//!   survive.
//! - A `pointer_move` pushed directly after a `pointer_move` replaces it. Only the newest
//!   position matters, and this keeps high-rate mice from filling the queue.
//! - A `wheel` pushed directly after a `wheel` is merged: `dy` is summed and the anchor point
//!   `(x, y)` becomes the newest one.
//! - Merging is only ever with the last queued event, so an intervening event of another kind
//!   splits the run (tests "a wheel between moves does not merge" and "move down move up keeps
//!   four events").
//! - A push into a full queue is counted in `dropped` and discarded; queued history is never
//!   modified and nothing is allocated (test "overflow drops the newest event").
//!
//! ### Native vs. Web
//! Native Wayland callbacks only push to the queue; the window loop pops events in order
//! (`sync_input` in `linux_window.zig`). Browser pointer events arrive one at a time, so the
//! web exports call into the app directly and bypass the queue. Both paths hand the app the
//! same `Event` values.
//!
//! ## 2. Coordinate Spaces
//! Points are in the surface's layout space: top-left origin, `+X` right, `+Y` down. This
//! module applies no scaling; each host converts into that space before pushing.
//! - **Wayland:** `wl_pointer.enter` and `motion` carry `wl_fixed_t`, a signed 24.8 fixed-point
//!   number. `logical = fixed / 256` (`fixed_to_logical`, test "fixed_to_logical converts
//!   24.8"). Surface-local coordinates are independent of the buffer scale, so they are already
//!   layout pixels.
//! - **Browser:** `web/shell.js` converts DOM CSS pixels into canvas pixels before calling the
//!   exports (see its pointer and DPI section).
//!
//! ## 3. Ownership
//! `input.zig` only records and buffers input. Hit testing, widget dispatch, and pointer capture
//! belong to `ui.Scene` and the apps.
//!
//! ## 4. TigerStyle Invariants
//! - Capacity is fixed by `queue_cap`; there is no allocation.
//! - `push`, `pop`, and `index_at` are O(1).
//! - Dropped events are counted, never silent.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum events retained between loop wakes. Moves and wheels coalesce, so the cap fills with
/// presses, releases, and leave events rather than with motion samples.
pub const queue_cap: u32 = 32;

/// A point in UI logical pixels. Origin is the top-left. Y grows downward.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// One wheel sample: the pointer anchor `(x, y)` in UI logical pixels and the scroll delta `dy`.
/// Positive `dy` scrolls content downward.
pub const Wheel = struct {
    x: f32,
    y: f32,
    dy: f32,
};

/// One input fact, in the order the platform observed it. `frame` carries the clock delta in
/// milliseconds; the native loop injects it from `sync_clock`, and pointer events come from
/// Wayland callbacks.
pub const Event = union(enum) {
    pointer_move: Point,
    pointer_down: Point,
    pointer_up: Point,
    pointer_leave,
    frame: f32,
    wheel: Wheel,
};

/// Latest pointer sample. `ui.Scene` stores this so a relayout can re-hit the same point.
/// Wayland button callbacks carry no coordinates, so the window keeps the last position
/// separately and copies it into the down and up events.
pub const Pointer = struct {
    x: f32,
    y: f32,
    inside: bool,
    down: bool,

    /// Resting pointer, outside the surface.
    pub fn init() Pointer {
        const pointer: Pointer = .{
            .x = 0,
            .y = 0,
            .inside = false,
            .down = false,
        };
        assert(!pointer.inside);
        assert(!pointer.down);
        return pointer;
    }

    /// Records a position inside the surface, in UI logical pixels.
    pub fn move(self: *Pointer, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
        self.inside = true;
        assert(self.inside);
        assert(self.x == x);
    }

    /// The pointer left the surface. Clears `down` so a press cannot stick when
    /// the display server never delivers the release.
    pub fn leave(self: *Pointer) void {
        self.inside = false;
        self.down = false;
        assert(!self.inside);
        assert(!self.down);
    }

    /// Records the primary button. `pressed` true means held.
    pub fn button(self: *Pointer, pressed: bool) void {
        self.down = pressed;
        assert(self.down == pressed);
        assert(self.x == self.x);
    }
};

/// Ring of events. `head` is the next pop, `count` the live population, and `dropped` the
/// pushes rejected because the ring was full.
pub const EventQueue = struct {
    items: [queue_cap]Event,
    head: u32,
    count: u32,
    dropped: u32,

    pub fn init() EventQueue {
        const queue: EventQueue = .{
            .items = undefined,
            .head = 0,
            .count = 0,
            .dropped = 0,
        };
        assert(queue.count == 0);
        assert(queue.dropped == 0);
        return queue;
    }

    /// Appends `event`, applying the coalescing rules in the module guide. A push that cannot
    /// coalesce while `count == queue_cap` increments `dropped` and leaves the queue unchanged.
    pub fn push(self: *EventQueue, event: Event) void {
        assert(self.count <= queue_cap);
        assert(self.head < queue_cap);
        if (coalesce(self, event)) {
            assert(self.count >= 1);
            return;
        }
        if (self.count == queue_cap) {
            self.dropped += 1;
            assert(self.dropped >= 1);
            assert(self.count == queue_cap);
            return;
        }
        const index = self.index_at(self.count);
        self.items[index] = event;
        self.count += 1;
        assert(self.count <= queue_cap);
        assert(self.count >= 1);
    }

    /// Removes the oldest event. Empty returns null.
    pub fn pop(self: *EventQueue) ?Event {
        assert(self.count <= queue_cap);
        assert(self.head < queue_cap);
        if (self.count == 0) {
            assert(self.count == 0);
            return null;
        }
        const event = self.items[self.head];
        self.head += 1;
        if (self.head == queue_cap) {
            self.head = 0;
        }
        self.count -= 1;
        assert(self.head < queue_cap);
        assert(self.count < queue_cap);
        return event;
    }

    fn index_at(self: *const EventQueue, offset: u32) u32 {
        assert(offset < queue_cap);
        assert(self.head < queue_cap);
        const sum = self.head + offset;
        if (sum >= queue_cap) {
            assert(sum < queue_cap * 2);
            return sum - queue_cap;
        }
        assert(sum < queue_cap);
        return sum;
    }
};

/// Converts a Wayland `wl_fixed_t` (signed 24.8, so 1/256 units) sample to UI logical pixels.
pub fn fixed_to_logical(fixed: i32) f32 {
    const logical: f32 = @as(f32, @floatFromInt(fixed)) / 256.0;
    if (fixed == 0) {
        assert(logical == 0);
    }
    if (fixed == 256) {
        assert(logical == 1);
    }
    return logical;
}

fn is_wheel(event: Event) bool {
    switch (event) {
        .wheel => {
            assert(event == .wheel);
            return true;
        },
        else => {
            assert(event != .wheel);
            return false;
        },
    }
}

/// Replaces a trailing move or sums a trailing wheel. Returns true when `event` did not need
/// its own slot.
fn coalesce(self: *EventQueue, event: Event) bool {
    assert(self.count <= queue_cap);
    if (self.count == 0) {
        assert(self.count == 0);
        return false;
    }
    const last = self.index_at(self.count - 1);
    if (is_move(event)) {
        if (is_move(self.items[last])) {
            self.items[last] = event;
            assert(self.count >= 1);
            return true;
        }
    }
    if (is_wheel(event)) {
        if (is_wheel(self.items[last])) {
            const summed = self.items[last].wheel.dy + event.wheel.dy;
            self.items[last] = .{ .wheel = .{
                .x = event.wheel.x,
                .y = event.wheel.y,
                .dy = summed,
            } };
            assert(self.items[last].wheel.dy == summed);
            return true;
        }
    }
    return false;
}

fn is_move(event: Event) bool {
    switch (event) {
        .pointer_move => {
            assert(event == .pointer_move);
            return true;
        },
        else => {
            assert(event != .pointer_move);
            return false;
        },
    }
}

comptime {
    assert(queue_cap == 32);
    assert(@sizeOf(Pointer) <= 16);
    assert(@sizeOf(Point) == 8);
}

// Locks the 24.8 conversion used by `wl_pointer.enter` and `motion`.
test "fixed_to_logical converts 24.8" {
    try std.testing.expectEqual(@as(f32, 1), fixed_to_logical(256));
    try std.testing.expectEqual(@as(f32, -0.5), fixed_to_logical(-128));
    try std.testing.expectEqual(@as(f32, 0), fixed_to_logical(0));
    try std.testing.expectEqual(@as(f32, 10), fixed_to_logical(2560));
}

// Three wheels occupy one slot. dy is the sum. The latest point wins.
test "consecutive wheels sum dy" {
    var queue = EventQueue.init();
    queue.push(.{ .wheel = .{ .x = 1, .y = 2, .dy = 3 } });
    queue.push(.{ .wheel = .{ .x = 4, .y = 5, .dy = 6 } });
    queue.push(.{ .wheel = .{ .x = 7, .y = 8, .dy = 9 } });
    try std.testing.expectEqual(@as(u32, 1), queue.count);
    const event = queue.pop().?;
    switch (event) {
        .wheel => |wheel| {
            try std.testing.expectEqual(@as(f32, 7), wheel.x);
            try std.testing.expectEqual(@as(f32, 8), wheel.y);
            try std.testing.expectEqual(@as(f32, 18), wheel.dy);
        },
        else => try std.testing.expect(false),
    }
}

// A wheel splits the motion stream, so it cannot collapse into either move.
test "a wheel between moves does not merge" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 1 } });
    queue.push(.{ .wheel = .{ .x = 1, .y = 1, .dy = 4 } });
    queue.push(.{ .pointer_move = .{ .x = 2, .y = 2 } });
    try std.testing.expectEqual(@as(u32, 3), queue.count);
    try std.testing.expect(queue.pop().? == .pointer_move);
    try std.testing.expect(queue.pop().? == .wheel);
    try std.testing.expect(queue.pop().? == .pointer_move);
}

// Three motions occupy one slot. The latest point wins.
test "consecutive moves coalesce" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 2 } });
    queue.push(.{ .pointer_move = .{ .x = 3, .y = 4 } });
    queue.push(.{ .pointer_move = .{ .x = 5, .y = 6 } });
    try std.testing.expectEqual(@as(u32, 1), queue.count);
    const event = queue.pop().?;
    switch (event) {
        .pointer_move => |point| {
            try std.testing.expectEqual(@as(f32, 5), point.x);
            try std.testing.expectEqual(@as(f32, 6), point.y);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expect(queue.pop() == null);
}

// A press splits the motion stream, so the click cannot collapse into the last move.
test "move down move up keeps four events" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 1 } });
    queue.push(.{ .pointer_down = .{ .x = 1, .y = 1 } });
    queue.push(.{ .pointer_move = .{ .x = 2, .y = 2 } });
    queue.push(.{ .pointer_up = .{ .x = 2, .y = 2 } });
    try std.testing.expectEqual(@as(u32, 4), queue.count);
    try std.testing.expect(queue.pop().? == .pointer_move);
    try std.testing.expect(queue.pop().? == .pointer_down);
    try std.testing.expect(queue.pop().? == .pointer_move);
    try std.testing.expect(queue.pop().? == .pointer_up);
    try std.testing.expect(queue.pop() == null);
}

// The press after `queue_cap` queued presses is counted and discarded; earlier ones stay.
test "overflow drops the newest event" {
    var queue = EventQueue.init();
    var index: u32 = 0;
    while (index < queue_cap) : (index += 1) {
        queue.push(.{ .pointer_down = .{ .x = 0, .y = 0 } });
    }
    try std.testing.expectEqual(queue_cap, queue.count);
    queue.push(.{ .pointer_down = .{ .x = 9, .y = 9 } });
    try std.testing.expectEqual(@as(u32, 1), queue.dropped);
    try std.testing.expectEqual(queue_cap, queue.count);
    const first = queue.pop().?;
    switch (first) {
        .pointer_down => |point| {
            try std.testing.expectEqual(@as(f32, 0), point.x);
        },
        else => try std.testing.expect(false),
    }
}

//! Pointer snapshot and the bounded event queue the native loop drains once per wake.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In an event-driven graphical architecture, input delivery mechanisms from the operating
//! system or display server must not be coupled directly to rendering and layout operations.
//!
//! ### The Dispatch Batching Hazard:
//! Wayland delivers incoming socket messages in large batches during `wl_display_dispatch_pending()`.
//! If the application only recorded the latest pointer state into a single global variable, a rapid
//! mouse click (a `pointer_button(pressed)` immediately followed by `pointer_button(released)` in
//! the same read batch) would overwrite itself into `down == false` before the main application loop
//! could execute a single tick. The button click edge would be completely lost.
//!
//! ### Ordered Event Queue with Motion Coalescing:
//! `EventQueue` preserves the chronological sequence of events across socket batches:
//! - Presses (`.pointer_down`), releases (`.pointer_up`), and surface leaves (`.pointer_leave`)
//!   are strictly preserved in FIFO order so click transitions are never missed.
//! - Consecutive motion events (`.pointer_move`) are automatically coalesced into the newest
//!   sample. High-frequency gaming mice (1000 Hz+) can flood the socket with dozens of motion
//!   reports in a single compositor frame; coalescing preserves the current pointer location
//!   while preventing queue exhaustion.
//! - The queue's coalesced point is the sample the commit draws. A 125 Hz mouse against a 60 Hz
//!   refresh does not divide evenly, so that point jumps by one report, then two.
//! - The queue capacity is fixed at `queue_cap = 32`. Pushing past the capacity increments the
//!   `dropped` counter and safely drops the excess event without corrupting queued history or
//!   allocating dynamic heap memory.
//!
//! ### Native vs. Web Execution:
//! - On native Linux, `linux_window.zig` drains the `EventQueue` once per loop wake in `sync_input()`,
//!   passing events sequentially to `scene.handle_event()`.
//! - In the browser, DOM pointer events are delivered individually and asynchronously to JavaScript;
//!   `web/shell.js` calls the Wasm exports (`pointer_move`, `pointer_down`, etc.) directly, which
//!   invoke `scene.handle_event()` immediately without queuing.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All point coordinates are in UI logical pixels, top-left origin `(0, 0)`, `+X` right, and
//! `+Y` down.
//!
//! ### Wayland Signed 24.8 Fixed-Point Conversion:
//! Wayland's `wl_pointer.enter` and `wl_pointer.motion` deliver coordinates as `wl_fixed_t`:
//! - High 24 bits: Signed integer pixel coordinate.
//! - Low 8 bits: Subpixel fractional part in 1/256 increments.
//! - Analytical conversion:
//!   ```text
//!   logical = @as(f32, @floatFromInt(fixed)) / 256.0
//!   ```
//! - By Wayland protocol specification, surface coordinates delivered in pointer events are
//!   invariant to the window buffer scale factor (`wl_surface.set_buffer_scale`), aligning
//!   directly with UI logical layout pixels.
//!
//! ### Browser Coordinate Mapping:
//! In `web/shell.js`, DOM PointerEvent `offsetX` and `offsetY` (in CSS pixels) are multiplied by
//! `window.devicePixelRatio` before invoking Zig exports:
//! ```text
//! x_device = event.offsetX * devicePixelRatio
//! y_device = event.offsetY * devicePixelRatio
//! ```
//! This matches the physical pixel backing store of the HTML5 canvas.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Memory Layouts:
//! - `Point`: 8 bytes total (`x: f32, y: f32`), 4-byte aligned.
//! - `Pointer`: 16 bytes total:
//!   - Offset 0: `x: f32` (4 bytes)
//!   - Offset 4: `y: f32` (4 bytes)
//!   - Offset 8: `inside: bool` (1 byte)
//!   - Offset 9: `down: bool` (1 byte)
//!   - Offset 10..15: Padding (6 bytes)
//!   - Alignment: 4 bytes.
//! - `Event`: Tagged union representation of input facts (`pointer_move`, `pointer_down`,
//!   `pointer_up`, `pointer_leave`, `frame`).
//! - `EventQueue`: Ring buffer containing:
//!   - `items: [queue_cap]Event` (fixed storage)
//!   - `head: u32` (read index)
//!   - `count: u32` (active items in queue)
//!   - `dropped: u32` (count of discarded events due to overflow)
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Queue Ingestion and Coalescing Logic:
//! ```text
//!                     push(event)
//!                          |
//!               +----------+----------+
//!               | Is event a move AND |
//!               | last item is move?  |
//!               +---------------------+
//!                     /          \
//!               YES  /            \  NO
//!                   v              v
//!            +-------------+  +-------------------+
//!            | Overwrite   |  | Is queue full?    |
//!            | last item   |  | (count == cap 32) |
//!            +-------------+  +-------------------+
//!                                 /           \
//!                           YES  /             \  NO
//!                               v               v
//!                       +-------------+   +-------------------+
//!                       | dropped += 1|   | Append at count,  |
//!                       | (drop event)|   | count += 1        |
//!                       +-------------+   +-------------------+
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Step 5 vs. Step 6 Division of Responsibility:**
//!   In Step 5, hit testing and state resolution were coupled inside this file (`hit.zig`).
//!   In Step 6, `input.zig` is strictly responsible for capturing raw device coordinates and
//!   buffering input events. `scene.zig` owns hit testing, widget dispatch, and pointer capture.
//!   `draw.contains_box` remains the low-level analytic signed distance test for rounded quads.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Memory Bounds:** `queue_cap = 32`. No dynamic memory allocations.
//! - **Strict Bounded Execution:** All queue operations (`push`, `pop`, `index_at`) are O(1).
//! - **Defensive Assertions:** Preconditions and postconditions asserted on every function.
//! - **Explicit Error Tracking:** Drops are counted and reported via `dropped`, never silently lost.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum events retained between loop wakes. Moves coalesce, so the cap fills
/// with presses, releases, and leave events rather than with motion samples.
pub const queue_cap: u32 = 32;

/// A point in UI logical pixels. Origin is the top-left. Y grows downward.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// One input fact, in the order the platform observed it.
/// `frame` carries the clock delta in milliseconds. The native loop pushes pointer
/// events from Wayland callbacks and injects `frame` from `sync_clock`.
pub const Event = union(enum) {
    pointer_move: Point,
    pointer_down: Point,
    pointer_up: Point,
    pointer_leave,
    frame: f32,
};

/// Latest pointer sample. Scene stores this so a relayout can re-hit the same point.
/// Button callbacks on Wayland carry no coordinates, so the window also keeps
/// `last_x` / `last_y` and copies them into the down and up events.
/// Memory: 16 bytes (two f32, two bools, 6 bytes of padding).
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

/// Ring of events. `head` is the next pop. `count` is the live population.
/// `dropped` counts pushes rejected because the ring was full.
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

    /// Appends `event`. A move that follows a move replaces that move.
    /// A push while `count == queue_cap` increments `dropped` and returns.
    pub fn push(self: *EventQueue, event: Event) void {
        assert(self.count <= queue_cap);
        assert(self.head < queue_cap);
        if (self.count > 0) {
            if (is_move(event)) {
                const last = self.index_at(self.count - 1);
                if (is_move(self.items[last])) {
                    self.items[last] = event;
                    assert(self.count >= 1);
                    return;
                }
            }
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

/// Converts a Wayland `wl_fixed_t` (signed 24.8) sample to UI logical pixels.
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

// The 33rd press is counted and discarded. The first 32 stay queued.
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

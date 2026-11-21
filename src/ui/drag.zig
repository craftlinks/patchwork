//! Drag: one area's press, drag, and release turned into the place of the point it moves, so
//! the spot under the pointer stays under it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Is
//! A `Drag` is a value its holder keeps, one per gesture the holder can run at a time. It holds
//! one optional offset and draws nothing; it has no id and no context. The holder computes the
//! `Hit` (`cx.hit(id, event)`) and passes it with `origin`, the point being dragged: a
//! top-left to move something, a corner to resize it. `track` says what the hit means:
//! ```text
//! hit            state        result                       state after
//! down           any          Action.grabbed               grab = pointer - origin
//! drag           held         Action.dragged = pointer - grab (the origin's new place)
//! drag           not held     Action.none                  unchanged
//! up             held         Action.released              grab = null
//! up             not held     Action.none                  unchanged
//! anything else  any          Action.none                  unchanged
//! ```
//! The event system has no cancel hit: a pointer leave and a touch cancel give the capture an
//! `up` (`ui/cx.zig`, section 5), so a cancel is `released`, and the last `dragged` place stays
//! the holder's. An `up`'s point is not read, so a release moves nothing. A second `down`
//! without an `up` between re-grabs: cx never sends one to an id, but a holder that shares one
//! `Drag` across ids can miss an `up`, and re-grabbing recovers from it. A holder that must
//! forget a drag (the thing it moved is gone) writes `.{}`.
//!
//! `Drag` neither redraws nor reacts to hover: the holder holds the same `Hit`, so it asks for
//! a redraw or lights a hover look from it. What moves, and where it stops, stay the holder's.
//!
//! ## 2. Spaces
//! `track` works in logical window pixels, the space `Hit` reports. `track_in` takes a
//! `draw.View` (a canvas's `CanvasState.drawn`), maps the pointer through `view.invert`, and
//! keeps the offset and returns the place in that view's world. `track` is `track_in` at
//! `View.identity`, whose invert is exact, so the two agree bit for bit.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation, no loop; every call is a straight-line switch over all of `Hit`'s tags, so
//!   a new tag is a compile error here.
//! - `origin` is finite on every call and `view.zoom` positive; the mapped pointer, the offset,
//!   and the place are finite (asserted, so they compile out in ReleaseFast).

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const Hit = @import("cx.zig").Hit;

/// The press, drag, and release of one area, turned into the place a point it moves goes, so the
/// spot under the pointer stays under it (module guide, section 1). The holder keeps one per
/// gesture it can run at a time; it draws nothing and holds no id.
pub const Drag = struct {
    /// The pointer's offset from the origin at the press, in the origin's space. Set exactly
    /// while held: from a `down` to the next `up`.
    grab: ?[2]f32 = null,

    pub const Action = union(enum) {
        none,
        /// A press: the offset is kept.
        grabbed,
        /// Where the origin goes, while held, in the origin's space.
        dragged: [2]f32,
        /// The release (or the cancel a pointer leave or a touch cancel makes) of a held drag.
        released,
    };

    /// True from a press to its release.
    pub fn held(self: *const Drag) bool {
        if (self.grab) |grab| assert(finite(grab));
        return self.grab != null;
    }

    /// `track_in` with the identity view: `origin` and the result are in logical window pixels,
    /// the space `hit` reports.
    pub fn track(self: *Drag, hit: Hit, origin: [2]f32) Action {
        return self.track_in(hit, origin, draw.View.identity);
    }

    /// What `hit` means for a drag of the point `origin` (module guide, section 1). `origin` and
    /// the result are in the world of `view` (a canvas's `CanvasState.drawn`); the pointer is
    /// mapped through `view.invert`. `origin` is read only on `down`.
    pub fn track_in(self: *Drag, hit: Hit, origin: [2]f32, view: draw.View) Action {
        assert(view.zoom > 0);
        assert(finite(origin));
        defer if (self.grab) |grab| assert(finite(grab));
        switch (hit) {
            .down => |press| {
                const at = view.invert(press.x, press.y);
                assert(finite(at));
                self.grab = .{ at[0] - origin[0], at[1] - origin[1] };
                return .grabbed;
            },
            .drag => |press| {
                const grab = self.grab orelse return .none;
                const at = view.invert(press.x, press.y);
                assert(finite(at));
                const place: [2]f32 = .{ at[0] - grab[0], at[1] - grab[1] };
                assert(finite(place));
                return .{ .dragged = place };
            },
            .up => {
                if (self.grab == null) return .none;
                self.grab = null;
                return .released;
            },
            .none, .hover_in, .hover_out, .wheel, .secondary => return .none,
        }
    }
};

/// True when both coordinates are finite (neither NaN nor infinite).
fn finite(point: [2]f32) bool {
    return std.math.isFinite(point[0]) and std.math.isFinite(point[1]);
}

comptime {
    assert(@sizeOf(Drag) <= 16);
    assert(@typeInfo(Drag.Action).@"union".field_names.len == 4);
}

const testing = std.testing;
const input = @import("../input.zig");
const Press = @import("cx.zig").Press;

const area: draw.Rect = .{ .x = 100, .y = 50, .width = 200, .height = 100 };

fn press_at(x: f32, y: f32) Press {
    assert(finite(.{ x, y }));
    return .{ .x = x, .y = y, .rect = area, .clicks = 1, .mods = .none };
}

fn down_at(x: f32, y: f32) Hit {
    return .{ .down = press_at(x, y) };
}

fn drag_at(x: f32, y: f32) Hit {
    return .{ .drag = press_at(x, y) };
}

fn up_at(x: f32, y: f32, inside: bool) Hit {
    return .{ .up = .{ .x = x, .y = y, .inside = inside } };
}

/// The five tags that are never part of a drag, for the test of the other tags.
fn other_hits() [5]Hit {
    const wheel: input.Wheel = .{ .x = 150, .y = 80, .dx = 0, .dy = 1 };
    const secondary = press_at(150, 80);
    return .{ .none, .hover_in, .hover_out, .{ .wheel = wheel }, .{ .secondary = secondary } };
}

// Locks the worked drag: origin (100, 50), a press at (105, 100), 5 px in and 50 down, is
// `grabbed` with grab (5, 50); a drag to (300, 200) puts the origin at (295, 150), and again
// with the moved origin (295, 150) passed (a drag does not read it); the release is `released`.
test "a drag keeps the point under the pointer" {
    var drag: Drag = .{};
    try testing.expect(!drag.held());
    try testing.expectEqual(Drag.Action.grabbed, drag.track(down_at(105, 100), .{ 100, 50 }));
    try testing.expectEqual([2]f32{ 5, 50 }, drag.grab.?);
    try testing.expect(drag.held());
    const first = drag.track(drag_at(300, 200), .{ 100, 50 });
    try testing.expectEqual(Drag.Action{ .dragged = .{ 295, 150 } }, first);
    const again = drag.track(drag_at(300, 200), .{ 295, 150 });
    try testing.expectEqual(Drag.Action{ .dragged = .{ 295, 150 } }, again);
    try testing.expectEqual([2]f32{ 5, 50 }, drag.grab.?);
    try testing.expectEqual(Drag.Action.released, drag.track(up_at(300, 200, true), .{ 295, 150 }));
    try testing.expect(!drag.held());
}

// Locks that nothing held is nothing: on a fresh `Drag` a drag at (300, 200) and an up are
// `none` and leave the grab null, and after a full press, drag, and release they are again.
test "a drag or release with nothing held is none" {
    var drag: Drag = .{};
    try testing.expectEqual(Drag.Action.none, drag.track(drag_at(300, 200), .{ 100, 50 }));
    try testing.expectEqual(@as(?[2]f32, null), drag.grab);
    try testing.expectEqual(Drag.Action.none, drag.track(up_at(300, 200, true), .{ 100, 50 }));
    try testing.expectEqual(@as(?[2]f32, null), drag.grab);
    _ = drag.track(down_at(105, 100), .{ 100, 50 });
    _ = drag.track(drag_at(300, 200), .{ 100, 50 });
    try testing.expectEqual(Drag.Action.released, drag.track(up_at(300, 200, true), .{ 295, 150 }));
    try testing.expectEqual(Drag.Action.none, drag.track(drag_at(310, 210), .{ 295, 150 }));
    try testing.expectEqual(Drag.Action.none, drag.track(up_at(310, 210, true), .{ 295, 150 }));
    try testing.expectEqual(@as(?[2]f32, null), drag.grab);
}

// Locks the other tags: held at grab (5, 50), `none`, `hover_in`, `hover_out`, `wheel`, and
// `secondary` each return `none` and keep the grab (5, 50); not held, each keeps it null.
test "hover, wheel, and secondary hits leave a drag alone" {
    var held_drag: Drag = .{};
    _ = held_drag.track(down_at(105, 100), .{ 100, 50 });
    var free_drag: Drag = .{};
    for (other_hits()) |hit| {
        try testing.expectEqual(Drag.Action.none, held_drag.track(hit, .{ 100, 50 }));
        try testing.expectEqual([2]f32{ 5, 50 }, held_drag.grab.?);
        try testing.expectEqual(Drag.Action.none, free_drag.track(hit, .{ 100, 50 }));
        try testing.expectEqual(@as(?[2]f32, null), free_drag.grab);
    }
}

// Locks a re-grab: origin (100, 50) pressed at (105, 55) is grab (5, 5); with no up, origin
// (200, 100) pressed at (210, 120) is `grabbed` with grab (10, 20), and a drag to (300, 200)
// puts it at (290, 180).
test "a second press re-grabs" {
    var drag: Drag = .{};
    try testing.expectEqual(Drag.Action.grabbed, drag.track(down_at(105, 55), .{ 100, 50 }));
    try testing.expectEqual([2]f32{ 5, 5 }, drag.grab.?);
    try testing.expectEqual(Drag.Action.grabbed, drag.track(down_at(210, 120), .{ 200, 100 }));
    try testing.expectEqual([2]f32{ 10, 20 }, drag.grab.?);
    const moved = drag.track(drag_at(300, 200), .{ 200, 100 });
    try testing.expectEqual(Drag.Action{ .dragged = .{ 290, 180 } }, moved);
}

// Locks a cancel: held and dragged to (295, 150), the `up { 0, 0, inside = false }` a pointer
// leave or touch cancel gives the capture is `released` with no place, so (295, 150) stays the
// holder's; an `up` at (999, 999) gives the same, its point unread.
test "a cancel is a release that moves nothing" {
    for ([_][2]f32{ .{ 0, 0 }, .{ 999, 999 } }) |point| {
        var drag: Drag = .{};
        _ = drag.track(down_at(105, 100), .{ 100, 50 });
        const moved = drag.track(drag_at(300, 200), .{ 100, 50 });
        try testing.expectEqual(Drag.Action{ .dragged = .{ 295, 150 } }, moved);
        const released = drag.track(up_at(point[0], point[1], false), .{ 295, 150 });
        try testing.expectEqual(Drag.Action.released, released);
        try testing.expect(!drag.held());
    }
}

// Locks a drag through a view `{ 16, 56, zoom 2 }`: origin world (16, 16), a press at screen
// (52, 96) is world (18, 20), grab (2, 4); a drag to (82, 96) is world (33, 20), so the origin
// goes to (31, 16): 30 screen px are 15 world px, the canvas example's numbers.
test "track_in keeps the offset in the view's world" {
    const view: draw.View = .{ .x = 16, .y = 56, .zoom = 2 };
    var drag: Drag = .{};
    try testing.expectEqual(Drag.Action.grabbed, drag.track_in(down_at(52, 96), .{ 16, 16 }, view));
    try testing.expectEqual([2]f32{ 2, 4 }, drag.grab.?);
    const moved = drag.track_in(drag_at(82, 96), .{ 16, 16 }, view);
    try testing.expectEqual(Drag.Action{ .dragged = .{ 31, 16 } }, moved);
}

// Locks `track` as `track_in` at the identity: the worked drag gives equal actions and grabs at
// every hit; fractional input (origin (100.25, 50.5), press (105.125, 100.75), drag (299.875,
// 200.0625)) lands exactly on `drag - (press - origin)` in f32; and a large finite case (origin
// (-8388608, 8388608), press 5 px right, drag to (-8388600, 8388610)) is exact, not clamped.
test "track equals track_in at the identity, exactly" {
    const hits = [_]Hit{
        down_at(105, 100), drag_at(300, 200), drag_at(300, 200), up_at(1, 2, true),
    };
    var window: Drag = .{};
    var world: Drag = .{};
    for (hits) |hit| {
        const a = window.track(hit, .{ 100, 50 });
        const b = world.track_in(hit, .{ 100, 50 }, draw.View.identity);
        try testing.expectEqual(a, b);
        try testing.expectEqual(window.grab, world.grab);
    }
    var fraction: Drag = .{};
    _ = fraction.track(down_at(105.125, 100.75), .{ 100.25, 50.5 });
    try testing.expectEqual([2]f32{ 4.875, 50.25 }, fraction.grab.?);
    const near = fraction.track(drag_at(299.875, 200.0625), .{ 100.25, 50.5 });
    try testing.expectEqual(Drag.Action{ .dragged = .{ 295, 149.8125 } }, near);
    var large: Drag = .{};
    _ = large.track(down_at(-8388603, 8388608), .{ -8388608, 8388608 });
    try testing.expectEqual([2]f32{ 5, 0 }, large.grab.?);
    const far = large.track(drag_at(-8388600, 8388610), .{ -8388608, 8388608 });
    try testing.expectEqual(Drag.Action{ .dragged = .{ -8388605, 8388610 } }, far);
}

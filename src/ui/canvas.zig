//! Canvases: a pan/zoom view over world coordinates, its zoom ladder, and its event side.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Division of Labour
//! `cx.begin_canvas(id, walk, layout, *CanvasState, layers)` and `cx.end_canvas()`
//! (`ui/cx.zig`, section 3a) do the drawing side: they give the canvas's layers this frame's
//! view (`draw/pools.zig`, section 5c), put the turtle, the clips, and the cull test in world
//! coordinates, and map every area recorded inside to the screen. This file owns what survives
//! the frame (`CanvasState`), the zoom ladder, and the event side (`CanvasState.handle`).
//!
//! ## 2. The View
//! A world point `(wx, wy)` lands on the logical screen point `(x + zoom * wx, y + zoom * wy)`.
//! `CanvasState` keeps the offset exactly; `view_of` snaps it to device pixels for drawing,
//! `x = round(x * s) / s`, so glyphs snapped to the world grid `1 / (s * zoom)` land on device
//! pixels (`text/cache.zig`, section 2a) and a slow drag never stalls on rounding. Events map
//! through `drawn`, the view the last frame drew with, which is what the user sees.
//!
//! ## 3. The Zoom Ladder
//! `rungs[k] = 2^((k - 8) / 4)` for `k = 0 .. 16`, from 0.25 to 4, computed at compile time so
//! both targets read the same 17 values. `rung_of(zoom)` is the nearest rung in log2, ties up:
//! the count of the geometric midpoints `2^((2k - 15) / 8)` at or below `zoom`. Glyphs
//! rasterize at `glyph_zoom(zoom) = rungs[rung_of(zoom)]`, so the cache holds at most one size
//! per rung and text is pixel-exact on every rung. The wheel moves one rung, so it never
//! leaves the zoom between rungs; an app that animates `zoom` gets glyphs stretched by at most
//! `2^(1/8)` (9%) either way.
//!
//! ## 4. Zooming About a Point
//! `zoom_at(px, py, next)` keeps the world point under `(px, py)` in place: with
//! `r = next / zoom`, `x' = px - (px - x) * r` and likewise `y`. Test "zooming keeps the point
//! under the pointer" locks the worked values.
//!
//! ## 5. Events
//! ```text
//! wheel on the canvas id   dy < 0: one rung in at the wheel's point, dy > 0: one out;
//!                          dx pans by -dx
//! left down on the id      starts a pan at the pointer (the background: areas drawn inside
//!                          the canvas are on its layers, above the canvas's own area)
//! drag                     pans by the pointer's delta since the last sample
//! up                       ends the pan
//! ```
//!
//! ## 6. TigerStyle Invariants
//! - Every function is O(1); `zoom` stays in `[zoom_min, zoom_max]` after every write.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const areas = @import("areas.zig");

pub const Rect = draw.Rect;
pub const View = draw.View;
pub const Id = areas.Id;

/// Rungs of the zoom ladder, 2^(1/4) apart.
pub const rung_count: u32 = 17;
/// The index of zoom 1.
pub const rung_one: u32 = 8;

/// The zoom of each rung (section 3).
pub const rungs: [rung_count]f32 = blk: {
    var out: [rung_count]f32 = undefined;
    for (0..rung_count) |index| {
        const exponent = (@as(f64, @floatFromInt(index)) - rung_one) / 4;
        out[index] = @floatCast(@exp2(exponent));
    }
    break :blk out;
};

/// The geometric midpoints between neighbouring rungs (section 3).
const midpoints: [rung_count - 1]f32 = blk: {
    var out: [rung_count - 1]f32 = undefined;
    for (0..rung_count - 1) |index| {
        const exponent = (2 * @as(f64, @floatFromInt(index)) + 1 - 2 * rung_one) / 8;
        out[index] = @floatCast(@exp2(exponent));
    }
    break :blk out;
};

pub const zoom_min: f32 = rungs[0];
pub const zoom_max: f32 = rungs[rung_count - 1];

/// The rung nearest `zoom` in log2, ties up (section 3).
pub fn rung_of(zoom: f32) u32 {
    assert(zoom > 0);
    var index: u32 = 0;
    for (midpoints) |midpoint| {
        if (zoom >= midpoint) index += 1;
    }
    assert(index < rung_count);
    return index;
}

/// The zoom glyphs rasterize at for a view at `zoom` (section 3).
pub fn glyph_zoom(zoom: f32) f32 {
    return rungs[rung_of(zoom)];
}

/// What one canvas keeps between frames. The app owns it; `begin_canvas` writes `viewport`
/// and `drawn`.
pub const CanvasState = struct {
    /// The exact offset in logical pixels and the zoom (section 2).
    x: f32,
    y: f32,
    zoom: f32,
    viewport: Rect,
    /// The view the last frame drew with; events map through it.
    drawn: View,
    /// The pointer during a pan drag.
    grab: ?[2]f32,

    pub const Action = enum {
        none,
        zoomed,
        panned,
    };

    /// World `(0, 0)` at the screen point `(x, y)` at `zoom`.
    pub fn init(x: f32, y: f32, zoom: f32) CanvasState {
        assert(zoom >= zoom_min and zoom <= zoom_max);
        const state: CanvasState = .{
            .x = x,
            .y = y,
            .zoom = zoom,
            .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .drawn = .{ .x = x, .y = y, .zoom = zoom },
            .grab = null,
        };
        assert(state.grab == null);
        return state;
    }

    /// The view to draw with at `scale_120`: the offset snapped to device pixels (section 2).
    pub fn view_of(self: *const CanvasState, scale_120: u32) View {
        assert(scale_120 >= 1);
        assert(self.zoom >= zoom_min and self.zoom <= zoom_max);
        const s = @as(f32, @floatFromInt(scale_120)) / 120;
        const x = @round(self.x * s) / s;
        const y = @round(self.y * s) / s;
        const view: View = .{ .x = x, .y = y, .zoom = self.zoom };
        assert(view.zoom > 0);
        return view;
    }

    /// The world point under the screen point `(x, y)` at the last draw.
    pub fn to_world(self: *const CanvasState, x: f32, y: f32) [2]f32 {
        return self.drawn.invert(x, y);
    }

    /// Zooms to `next` (clamped to the ladder's range) about the screen point `(px, py)`
    /// (section 4). Marks the context for redraw and returns `zoomed` when the zoom moved.
    pub fn zoom_at(self: *CanvasState, cx: anytype, px: f32, py: f32, next: f32) Action {
        assert(next > 0);
        const clamped = std.math.clamp(next, zoom_min, zoom_max);
        if (clamped == self.zoom) return .none;
        const ratio = clamped / self.zoom;
        self.x = px - (px - self.x) * ratio;
        self.y = py - (py - self.y) * ratio;
        self.zoom = clamped;
        cx.redraw();
        assert(self.zoom >= zoom_min and self.zoom <= zoom_max);
        return .zoomed;
    }

    /// Moves `steps` rungs from the rung nearest the zoom, about `(px, py)`.
    pub fn step_at(self: *CanvasState, cx: anytype, px: f32, py: f32, steps: i32) Action {
        const here: i32 = @intCast(rung_of(self.zoom));
        const last: i32 = rung_count - 1;
        const index: u32 = @intCast(std.math.clamp(here + steps, 0, last));
        return self.zoom_at(cx, px, py, rungs[index]);
    }

    /// Moves the offset by `(dx, dy)` logical pixels. Returns `panned` when it moved.
    pub fn pan_by(self: *CanvasState, cx: anytype, dx: f32, dy: f32) Action {
        assert(dx == dx and dy == dy);
        if (dx == 0 and dy == 0) return .none;
        self.x += dx;
        self.y += dy;
        cx.redraw();
        return .panned;
    }

    /// Applies the wheel and the background drag of `event` for the canvas `id` (section 5).
    pub fn handle(self: *CanvasState, cx: anytype, id: Id, event: anytype) Action {
        assert(id != .none);
        switch (cx.hit(id, event)) {
            .wheel => |wheel| {
                var action: Action = .none;
                if (wheel.dy < 0) action = self.step_at(cx, wheel.x, wheel.y, 1);
                if (wheel.dy > 0) action = self.step_at(cx, wheel.x, wheel.y, -1);
                if (wheel.dx != 0 and self.pan_by(cx, -wheel.dx, 0) == .panned) {
                    if (action == .none) action = .panned;
                }
                return action;
            },
            .down => |press| {
                self.grab = .{ press.x, press.y };
                return .none;
            },
            .drag => |press| {
                const from = self.grab orelse return .none;
                self.grab = .{ press.x, press.y };
                return self.pan_by(cx, press.x - from[0], press.y - from[1]);
            },
            .up => {
                self.grab = null;
                return .none;
            },
            else => return .none,
        }
    }
};

const testing = std.testing;

const Redraws = struct {
    count: u32 = 0,
    fn redraw(self: *Redraws) void {
        self.count += 1;
    }
};

// Locks the ladder (section 3): 17 rungs from 0.25 to 4 with 1 at index 8, the nearest rung
// in log2 at and between rungs, and the clamps beyond the range.
test "the ladder has 17 rungs and zooms snap to the nearest" {
    try testing.expectEqual(@as(f32, 0.25), rungs[0]);
    try testing.expectEqual(@as(f32, 1), rungs[rung_one]);
    try testing.expectEqual(@as(f32, 4), rungs[16]);
    try testing.expectApproxEqAbs(@as(f32, 1.189207), rungs[9], 1e-6);
    for (rungs, 0..) |rung, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), rung_of(rung));
    }
    // The midpoint above 1 is 2^(1/8) = 1.0905: 1.09 stays at 1 and 1.091 goes up.
    try testing.expectEqual(rung_one, rung_of(1.09));
    try testing.expectEqual(rung_one + 1, rung_of(1.091));
    try testing.expectEqual(@as(u32, 0), rung_of(0.01));
    try testing.expectEqual(@as(u32, 16), rung_of(100));
    try testing.expectEqual(rungs[9], glyph_zoom(1.15));
}

// Locks zooming about a point (section 4): one rung in about (400, 300) from offset (16, 56) at
// zoom 1 keeps world (384, 244) under the point, and the clamp at the top of the ladder.
test "zooming keeps the point under the pointer" {
    var redraws: Redraws = .{};
    var state = CanvasState.init(16, 56, 1);
    const before = state.drawn.invert(400, 300);
    try testing.expectEqual([2]f32{ 384, 244 }, before);
    try testing.expectEqual(CanvasState.Action.zoomed, state.step_at(&redraws, 400, 300, 1));
    try testing.expectEqual(rungs[9], state.zoom);
    const view: View = .{ .x = state.x, .y = state.y, .zoom = state.zoom };
    const after = view.invert(400, 300);
    try testing.expectApproxEqAbs(before[0], after[0], 1e-3);
    try testing.expectApproxEqAbs(before[1], after[1], 1e-3);
    state.zoom = zoom_max;
    try testing.expectEqual(CanvasState.Action.none, state.step_at(&redraws, 400, 300, 1));
    try testing.expectEqual(@as(u32, 1), redraws.count);
}

// Locks the device snap (section 2): at scale 1.5 an offset of 10.4 (device 15.6) draws at
// device pixel 16, 16 / 1.5 = 10.667 logical, while the state keeps 10.4.
test "the drawn view snaps the offset to device pixels" {
    const state = CanvasState.init(10.4, 8, 2);
    const view = state.view_of(180);
    try testing.expectEqual(@as(f32, 16) / 1.5, view.x);
    try testing.expectEqual(@as(f32, 8), view.y);
    try testing.expectEqual(@as(f32, 10.4), state.x);
}

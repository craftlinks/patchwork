//! Canvases: a pan/zoom view over world coordinates, its zoom ladder, and its event side.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Division of Labour
//! `cx.begin_canvas(id, walk, layout, *CanvasState, layers)` and `cx.end_canvas()`
//! (`ui/cx.zig`, section 3a) do the drawing side: they give the canvas's layers this frame's
//! view (`draw/pools.zig`, section 5c), put the turtle, the clips, and the cull test in world
//! coordinates, and map every area recorded inside to the screen. This file owns what survives
//! the frame (`CanvasState`), the zoom ladder, and the event side (`CanvasState.handle` and the
//! actions of section 5a).
//!
//! ## 2. The View
//! A world point `(wx, wy)` lands on the logical screen point `(x + zoom * wx, y + zoom * wy)`.
//! `CanvasState` keeps the offset exactly; `view_of` snaps it to device pixels for drawing,
//! `x = round(x * s) / s`, so glyphs snapped to the world grid `1 / (s * zoom)` land on device
//! pixels (`text/cache.zig`, section 2a) and a slow drag never stalls on rounding. Events map
//! through `drawn`, the view the last frame drew with, which is what the user sees.
//!
//! ## 3. The Zoom Ladder
//! `rungs[k] = 2^((k - 12) / 6)` for `k = 0 .. 24`, from 0.25 to 4, computed at compile time so
//! both targets read the same 25 values. `rung_of(zoom)` is the nearest rung in log2, ties up:
//! the count of the geometric midpoints `2^((2k - 23) / 12)` at or below `zoom`. Glyphs
//! rasterize at `glyph_zoom(zoom) = rungs[rung_of(zoom)]`, so the cache holds at most one size
//! per rung and text is pixel-exact on every rung. The wheel moves one rung, so it never
//! leaves the zoom between rungs; an app that animates `zoom` gets glyphs stretched by at most
//! `2^(1/12)` (6%) either way.
//!
//! ## 3a. Legibility
//! A zoomed-out canvas has text too small to read, and placing it costs glyphs and atlas room
//! for nothing. `legible(size, zoom)` is whether text of `size` logical px at `zoom` is at least
//! `legible_px_min` (6) on screen, `size * zoom >= legible_px_min`; an app tests it before
//! placing a label (level of detail). It is a test, not a policy of `kit.label`: each canvas
//! chooses what it drops, and a label outside a canvas never skips.
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
//! The wheel arm is `wheel(cx, turn)`, public, for an app that takes the wheel itself (a
//! window-wide one, or a canvas whose areas claim it): `zoomed` wins over `panned`.
//!
//! ## 5a. Actions
//! Apps drive the view from their own keys and commands with the same moves `handle` makes, so
//! a key zooms exactly as the wheel does:
//! ```text
//! wheel(cx, turn)              the wheel arm above
//! step_center(cx, steps)       step_at about the viewport's centre (x + width / 2, likewise y)
//! reset(cx, x, y, zoom)        offset and zoom set; viewport, drawn, and grab kept; redraws
//! reveal(cx, world, margin)    pans by the least that shows `world` whole, `margin` to spare
//! ```
//! `reveal` works per axis from the offset and zoom (not the drawn view), on the world rect's
//! screen span `near = x + zoom * wx` of `length = zoom * width`: a span too long for the
//! viewport less two margins puts its near edge at the margin; else a near edge inside the
//! margin is brought to it; else a far edge past it. It never zooms. `step_center` and
//! `reveal` do nothing before the first draw, while the viewport is empty: a key can arrive
//! before the first frame.
//!
//! ## 6. TigerStyle Invariants
//! - Every function is O(1); `zoom` stays in `[zoom_min, zoom_max]` after every write.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const areas = @import("areas.zig");

pub const Rect = draw.Rect;
pub const View = draw.View;
pub const Id = areas.Id;

/// Rungs per doubling of the zoom.
pub const rungs_per_octave: u32 = 6;
/// Doublings each way from zoom 1: the ladder runs from 2^-2 to 2^2.
const octaves: u32 = 2;
/// Rungs of the zoom ladder, 2^(1/6) apart.
pub const rung_count: u32 = 2 * octaves * rungs_per_octave + 1;
/// The index of zoom 1.
pub const rung_one: u32 = octaves * rungs_per_octave;

comptime {
    assert(rung_count == 25);
    assert(rung_one == 12);
    assert(rungs_per_octave * octaves == rung_one);
}

/// The zoom of each rung (section 3).
pub const rungs: [rung_count]f32 = blk: {
    var out: [rung_count]f32 = undefined;
    for (0..rung_count) |index| {
        const exponent = (@as(f64, @floatFromInt(index)) - rung_one) / rungs_per_octave;
        out[index] = @floatCast(@exp2(exponent));
    }
    break :blk out;
};

/// The geometric midpoints between neighbouring rungs (section 3).
const midpoints: [rung_count - 1]f32 = blk: {
    var out: [rung_count - 1]f32 = undefined;
    for (0..rung_count - 1) |index| {
        const doubled = 2 * @as(f64, @floatFromInt(index)) + 1 - 2 * rung_one;
        const exponent = doubled / (2 * rungs_per_octave);
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

/// The smallest on-screen em, in logical px, that `legible` passes (section 3a).
pub const legible_px_min: f32 = 6;

/// Whether text of `size` logical px drawn at `zoom` is at least `legible_px_min` on screen:
/// `size * zoom >= legible_px_min` (section 3a).
pub fn legible(size: f32, zoom: f32) bool {
    assert(size > 0);
    assert(zoom > 0);
    return size * zoom >= legible_px_min;
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

    /// One wheel turn at its point (section 5): `dy < 0` one rung in, `dy > 0` one out, and `dx`
    /// pans by `-dx`. `zoomed` wins over `panned`; `none` when nothing moved. `handle`'s wheel
    /// arm, for an app that takes the wheel itself (a window-wide one).
    pub fn wheel(self: *CanvasState, cx: anytype, turn: input.Wheel) Action {
        assert(turn.dx == turn.dx and turn.dy == turn.dy);
        var action: Action = .none;
        if (turn.dy < 0) action = self.step_at(cx, turn.x, turn.y, 1);
        if (turn.dy > 0) action = self.step_at(cx, turn.x, turn.y, -1);
        if (turn.dx != 0 and self.pan_by(cx, -turn.dx, 0) == .panned) {
            if (action == .none) action = .panned;
        }
        return action;
    }

    /// `step_at` about the viewport's centre: `steps` rungs for a zoom key. `none`, with nothing
    /// changed, before the first draw, while the viewport is empty.
    pub fn step_center(self: *CanvasState, cx: anytype, steps: i32) Action {
        const port = self.viewport;
        if (port.width <= 0 or port.height <= 0) return .none;
        const px = port.x + port.width / 2;
        const py = port.y + port.height / 2;
        return self.step_at(cx, px, py, steps);
    }

    /// Sets the offset and the zoom, keeping `viewport`, `drawn`, and `grab`, and redraws: a
    /// "back to the start" key.
    pub fn reset(self: *CanvasState, cx: anytype, x: f32, y: f32, zoom: f32) void {
        assert(zoom >= zoom_min and zoom <= zoom_max);
        assert(x == x and y == y);
        self.x = x;
        self.y = y;
        self.zoom = zoom;
        cx.redraw();
    }

    /// Pans by the least that shows the world rect `world` whole with `margin` screen pixels to
    /// spare, per axis (section 5a); the zoom never changes. `none` before the first draw.
    pub fn reveal(self: *CanvasState, cx: anytype, world: Rect, margin: f32) Action {
        assert(world.width > 0 and world.height > 0);
        assert(margin >= 0);
        const port = self.viewport;
        if (port.width <= 0 or port.height <= 0) return .none;
        const near_x = self.x + world.x * self.zoom;
        const near_y = self.y + world.y * self.zoom;
        const dx = reveal_axis(near_x, world.width * self.zoom, port.x, port.width, margin);
        const dy = reveal_axis(near_y, world.height * self.zoom, port.y, port.height, margin);
        return self.pan_by(cx, dx, dy);
    }

    /// Applies the wheel and the background drag of `event` for the canvas `id` (section 5).
    pub fn handle(self: *CanvasState, cx: anytype, id: Id, event: anytype) Action {
        assert(id != .none);
        switch (cx.hit(id, event)) {
            .wheel => |turn| return self.wheel(cx, turn),
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

/// One axis of `reveal` (section 5a): the shift for a span at screen `near` of `length` in a
/// viewport from `start` of `extent`, keeping `margin` to spare.
fn reveal_axis(near: f32, length: f32, start: f32, extent: f32, margin: f32) f32 {
    assert(length > 0);
    assert(extent > 0);
    const far = near + length;
    if (length + 2 * margin > extent) return start + margin - near;
    if (near < start + margin) return start + margin - near;
    if (far > start + extent - margin) return start + extent - margin - far;
    return 0;
}

const testing = std.testing;

const Redraws = struct {
    count: u32 = 0,
    fn redraw(self: *Redraws) void {
        self.count += 1;
    }
};

// Locks the ladder (section 3): 25 rungs from 0.25 to 4 with 1 at index 12, the nearest rung
// in log2 at and between rungs, and the clamps beyond the range.
test "the ladder has 25 rungs and zooms snap to the nearest" {
    try testing.expectEqual(@as(f32, 0.25), rungs[0]);
    try testing.expectEqual(@as(f32, 1), rungs[rung_one]);
    try testing.expectEqual(@as(f32, 4), rungs[24]);
    try testing.expectApproxEqAbs(@as(f32, 1.122462), rungs[13], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), rungs[18], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rungs[6], 1e-6);
    for (rungs, 0..) |rung, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), rung_of(rung));
    }
    // The midpoint above 1 is 2^(1/12) = 1.059463: 1.0594 stays at 1 and 1.0595 goes up.
    try testing.expectEqual(rung_one, rung_of(1.0594));
    try testing.expectEqual(rung_one + 1, rung_of(1.0595));
    try testing.expectEqual(@as(u32, 0), rung_of(0.01));
    try testing.expectEqual(@as(u32, 24), rung_of(100));
    // 1.15 lies between rungs[13] = 1.1225 and its upper midpoint 2^(3/12) = 1.1892.
    try testing.expectEqual(rungs[13], glyph_zoom(1.15));
    try testing.expectEqual(rungs[14], glyph_zoom(1.19));
}

// Locks `legible` (section 3a): 14 px at zoom 1 passes; 12 px at 0.5 is exactly 6 and passes,
// at 0.4 (4.8) fails; 13 px passes at rung 6 (zoom 0.5, 6.5) and fails at rung 5 (0.445, 5.79).
test "legible passes text of at least six on-screen pixels" {
    try testing.expect(legible(14, 1));
    try testing.expect(legible(12, 0.5));
    try testing.expect(!legible(12, 0.4));
    try testing.expect(legible(13, rungs[6]));
    try testing.expect(!legible(13, rungs[5]));
}

/// A stand-in context for the actions: counts redraws, and hits every event as the wheel.
const Wheels = struct {
    count: u32 = 0,
    fn redraw(self: *Wheels) void {
        self.count += 1;
    }
    fn hit(self: *Wheels, id: Id, turn: input.Wheel) @import("cx.zig").Hit {
        assert(id != .none);
        assert(self.count < 1000);
        return .{ .wheel = turn };
    }
};

// Locks `wheel` (section 5): from offset (16, 56) at zoom 1, dy -10 at (400, 300) zooms one rung
// keeping world (384, 244) under the point; dx 12 pans by -12 (`panned`); dy +10 at `zoom_min`
// is `none`; and `handle` gives the same bits through the wheel arm.
test "wheel zooms a rung at its point and pans by dx" {
    var redraws: Redraws = .{};
    var state = CanvasState.init(16, 56, 1);
    const in: input.Wheel = .{ .x = 400, .y = 300, .dx = 0, .dy = -10 };
    try testing.expectEqual(CanvasState.Action.zoomed, state.wheel(&redraws, in));
    try testing.expectEqual(rungs[rung_one + 1], state.zoom);
    const view: View = .{ .x = state.x, .y = state.y, .zoom = state.zoom };
    const kept = view.invert(400, 300);
    try testing.expectApproxEqAbs(@as(f32, 384), kept[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 244), kept[1], 1e-3);
    const x = state.x;
    const side: input.Wheel = .{ .x = 400, .y = 300, .dx = 12, .dy = 0 };
    try testing.expectEqual(CanvasState.Action.panned, state.wheel(&redraws, side));
    try testing.expectEqual(x - 12, state.x);
    var bottom = CanvasState.init(16, 56, zoom_min);
    const out: input.Wheel = .{ .x = 400, .y = 300, .dx = 0, .dy = 10 };
    try testing.expectEqual(CanvasState.Action.none, bottom.wheel(&redraws, out));
    var direct = CanvasState.init(16, 56, 1);
    var routed = CanvasState.init(16, 56, 1);
    var wheels: Wheels = .{};
    const turns = [_]input.Wheel{ in, in, side, out, .{ .x = 77.5, .y = 513.25, .dx = -3, .dy = -1 } };
    for (turns) |turn| {
        const a = direct.wheel(&redraws, turn);
        const b = routed.handle(&wheels, areas.id("canvas", 0), turn);
        try testing.expectEqual(a, b);
        try testing.expectEqual(@as(u32, @bitCast(direct.x)), @as(u32, @bitCast(routed.x)));
        try testing.expectEqual(@as(u32, @bitCast(direct.y)), @as(u32, @bitCast(routed.y)));
        try testing.expectEqual(direct.zoom, routed.zoom);
    }
}

// Locks `step_center` and `reset` (section 5a): with the canvas example's viewport (16, 56,
// 1248, 592) a step is `step_at` about (640, 352), bit for bit, in and out; with the viewport
// empty (before the first draw) it is `none` and changes nothing; `reset` sets the offset and
// zoom and keeps `viewport`, `drawn`, and `grab`.
test "step_center steps about the viewport's centre and reset keeps the rest" {
    var redraws: Redraws = .{};
    var centred = CanvasState.init(16, 56, 1);
    centred.viewport = .{ .x = 16, .y = 56, .width = 1248, .height = 592 };
    var pointed = centred;
    for ([_]i32{ 1, 1, -3, 2 }) |steps| {
        try testing.expectEqual(pointed.step_at(&redraws, 640, 352, steps), centred.step_center(&redraws, steps));
        try testing.expectEqual(@as(u32, @bitCast(pointed.x)), @as(u32, @bitCast(centred.x)));
        try testing.expectEqual(@as(u32, @bitCast(pointed.y)), @as(u32, @bitCast(centred.y)));
        try testing.expectEqual(pointed.zoom, centred.zoom);
    }
    var early = CanvasState.init(16, 56, 1);
    const before = redraws.count;
    try testing.expectEqual(CanvasState.Action.none, early.step_center(&redraws, 1));
    try testing.expectEqual(@as(f32, 1), early.zoom);
    try testing.expectEqual(before, redraws.count);
    centred.grab = .{ 5, 6 };
    centred.drawn = .{ .x = 3, .y = 4, .zoom = 2 };
    centred.reset(&redraws, 16, 56, 1);
    try testing.expectEqual(@as(f32, 16), centred.x);
    try testing.expectEqual(@as(f32, 56), centred.y);
    try testing.expectEqual(@as(f32, 1), centred.zoom);
    try testing.expectEqual(Rect{ .x = 16, .y = 56, .width = 1248, .height = 592 }, centred.viewport);
    try testing.expectEqual(View{ .x = 3, .y = 4, .zoom = 2 }, centred.drawn);
    try testing.expectEqual(@as(?[2]f32, .{ 5, 6 }), centred.grab);
    try testing.expectEqual(before + 1, redraws.count);
}

// Locks `reveal` (section 5a) on Treadle's numbers: viewport (0, 0, 1280, 720), margin 32, offset
// 0 at zoom 1: (1198, 436, 220, 222) pans (-170, 0), (1398, 56, 140, 288) (-290, 0),
// (1570, 56, 450, 364) (-772, 0), (100, 100, 100, 100) not at all (`none`), (10, 10, 100, 100)
// (22, 22), (0, 0, 2000, 100) (32, 32); offset (100, 50) at zoom 2, (600, 300, 220, 222) pans
// (-492, -406) and keeps the zoom; before the first draw nothing moves.
test "reveal pans by the least that shows a rect with a margin" {
    var redraws: Redraws = .{};
    const port: Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const cases = [_]struct { world: Rect, shift: [2]f32 }{
        .{ .world = .{ .x = 1198, .y = 436, .width = 220, .height = 222 }, .shift = .{ -170, 0 } },
        .{ .world = .{ .x = 1398, .y = 56, .width = 140, .height = 288 }, .shift = .{ -290, 0 } },
        .{ .world = .{ .x = 1570, .y = 56, .width = 450, .height = 364 }, .shift = .{ -772, 0 } },
        .{ .world = .{ .x = 100, .y = 100, .width = 100, .height = 100 }, .shift = .{ 0, 0 } },
        .{ .world = .{ .x = 10, .y = 10, .width = 100, .height = 100 }, .shift = .{ 22, 22 } },
        .{ .world = .{ .x = 0, .y = 0, .width = 2000, .height = 100 }, .shift = .{ 32, 32 } },
    };
    for (cases) |case| {
        var state = CanvasState.init(0, 0, 1);
        state.viewport = port;
        const action = state.reveal(&redraws, case.world, 32);
        const still = case.shift[0] == 0 and case.shift[1] == 0;
        try testing.expectEqual(if (still) CanvasState.Action.none else .panned, action);
        try testing.expectEqual(case.shift, [2]f32{ state.x, state.y });
    }
    var zoomed = CanvasState.init(100, 50, 2);
    zoomed.viewport = port;
    const world: Rect = .{ .x = 600, .y = 300, .width = 220, .height = 222 };
    try testing.expectEqual(CanvasState.Action.panned, zoomed.reveal(&redraws, world, 32));
    try testing.expectEqual([2]f32{ 100 - 492, 50 - 406 }, [2]f32{ zoomed.x, zoomed.y });
    try testing.expectEqual(@as(f32, 2), zoomed.zoom);
    var early = CanvasState.init(0, 0, 1);
    try testing.expectEqual(CanvasState.Action.none, early.reveal(&redraws, world, 32));
    try testing.expectEqual([2]f32{ 0, 0 }, [2]f32{ early.x, early.y });
}

// Locks zooming about a point (section 4): one rung in about (400, 300) from offset (16, 56) at
// zoom 1 keeps world (384, 244) under the point, and the clamp at the top of the ladder.
test "zooming keeps the point under the pointer" {
    var redraws: Redraws = .{};
    var state = CanvasState.init(16, 56, 1);
    const before = state.drawn.invert(400, 300);
    try testing.expectEqual([2]f32{ 384, 244 }, before);
    try testing.expectEqual(CanvasState.Action.zoomed, state.step_at(&redraws, 400, 300, 1));
    try testing.expectEqual(rungs[13], state.zoom);
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

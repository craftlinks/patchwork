//! Stroked paths: flattening, chunking, the CPU twins of the `Path` shader, and the appenders.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Chunks of Segments
//! One capsule quad per segment is the simplest stroke, but where two capsules overlap at a
//! joint a translucent line blends twice and shows a dot. A `Path` instance instead covers a
//! chunk of up to `chunk_points_max` points, and its fragment takes the minimum distance over
//! the chunk's segments, so every joint inside a chunk blends once. Cables, envelopes,
//! automation lanes, and transfer curves are all paths.
//!
//! ## 2. Data Flow
//! ```text
//! cubic(p0, p1, p2, p3) / polyline(points) / plot(samples, rect, range)
//!   -> flatten (cubic) or map (plot) into a stack buffer of absolute points
//!   -> chunk_count: the chunks, so the pool's room is checked before anything is written
//!   -> reserve_points: the path's points, relative to its origin (the bounds' top-left)
//!   -> one Path instance per chunk, indexing the shared point buffer
//! GPU: own   = min over the chunk's segments of sdf_segment(q, p[i], p[i + 1])
//!      alpha = color.a * coverage(own - width / 2) * owned * clip_mask
//! ```
//! The point buffer is the context's point pool (`draw/pools.zig`, section 5b), uploaded by
//! dirty range like the instance pools and bound once per pass (`draw/renderer.zig`).
//!
//! ## 3. Flattening
//! A cubic gets `clamp(ceil(estimate / flatten_px), segments_min, segments_max)` uniform-`t`
//! segments, where `estimate = (chord + control polygon) / 2` bounds the arc length from both
//! sides. `plot` maps `n` samples to `x = rect.x + rect.width * i / (n - 1)` and
//! `y = rect.y + rect.height * (1 - clamp((v - lo) / (hi - lo), 0, 1))`.
//!
//! ## 4. Chunks and Seams
//! Chunks overlap by one index: a chunk ends at point `e` and the next starts at `e`, so no
//! point is stored twice. `chunk_end` is greedy: at least `chunk_segments_min` segments, at
//! most `chunk_segments_max` (so at most 16 points and 15 loop iterations), and it stops early
//! once the padded bounds would exceed `chunk_area_max` square logical pixels, because a
//! fragment's cost is its chunk's segment count and a diagonal chunk's bounds grow with the
//! square of its length. Every chunk but a path's last has at least four segments, so a path
//! of `s` segments has at most `ceil(s / 4)` chunks (`chunks_max`).
//!
//! Two chunks share a point, so their round caps would overlap there. The seam rule removes
//! that: a chunk with `prev` also measures the previous chunk's last segment and one with
//! `next` the next chunk's first, and a fragment belongs to the chunk whose segment is
//! nearest, ties to the earlier chunk. A smooth or folded path therefore blends once
//! everywhere. What remains is two parts of a path that come within the stroke width of each
//! other more than one segment apart across a seam, or that cross: there both chunks draw.
//! Test "seams blend once and crossings twice" measures both.
//!
//! ## 5. Coordinates
//! Points are stored relative to the path's origin, the top-left of its unpadded bounds, and
//! each chunk carries `anchor = origin - rect.xy`. A container's alignment shift
//! (`Context.shift`) moves `rect.xy` only and `anchor` is a difference, so the stroke moves
//! with the rect and the registry rule "geometry is relative to `rect`" holds. A chunk's rect
//! is its bounds padded by `width / 2 + aa_pad`, which holds every fragment with coverage at
//! display scales of 1 and above.
//!
//! ## 6. Hit Testing
//! `distance_to_polyline` is the CPU twin of the stroke distance. `ui.Context.path_area`
//! records a path area whose `radius` is `width / 2 + hit_slop` and whose rect is the bounds
//! padded by that radius, so the origin is `rect.xy + radius` (`ui/areas.zig`).
//!
//! ## 7. TigerStyle Invariants
//! - No allocation: flattening and plotting use stack buffers of `cubic_points_max` and
//!   `plot_samples_max` points; the points go into the fixed pool.
//! - Appends are atomic: the pool's room and the point room are checked first, and a refused
//!   first instance (`BatchFull`) takes the points back. Every refusal is counted.
//! - Every loop is bounded by the path's point count.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const pools = @import("pools.zig");
const types = @import("types.zig");

pub const Point = pools.Point;
pub const Rect = draw.Rect;
pub const Clip = draw.Clip;

/// Segments of a flattened cubic: at least `segments_min`, at most `segments_max`.
pub const segments_min: u32 = 4;
pub const segments_max: u32 = 64;

/// Target segment length of a flattened cubic, in logical pixels.
pub const flatten_px: f32 = 6;

/// Points of the longest flattened cubic.
pub const cubic_points_max: u32 = segments_max + 1;

/// Points and segments of one chunk (section 4).
pub const chunk_points_max: u32 = 16;
pub const chunk_segments_max: u32 = chunk_points_max - 1;
pub const chunk_segments_min: u32 = 4;

/// Padded chunk bounds, in square logical pixels, past which a chunk of at least
/// `chunk_segments_min` segments stops growing. Chosen by the fragment estimate in test
/// "chunk area bounds the fragments of a diagonal cable".
pub const chunk_area_max: f32 = 1024;

/// Padding past the half width that holds the antialiased edge (section 5).
pub const aa_pad: f32 = 1;

/// Hit distance past the half width (section 6).
pub const hit_slop: f32 = 3;

/// Samples `plot` takes at most.
pub const plot_samples_max: u32 = 256;

/// Color, width in logical pixels, and the hover mix toward `theme.lighten`.
pub const Stroke = struct {
    color: [4]f32,
    width: f32,
    hover: f32,
};

/// Where a path's points went: `count` points from `first` in the point pool, relative to
/// the top-left of `bounds` (absolute, unpadded). `ui.Context.path_area` takes it.
pub const Placed = struct {
    first: u32,
    count: u32,
    bounds: Rect,
};

/// Most chunks a path of `point_count` points makes (section 4).
pub fn chunks_max(point_count: u32) u32 {
    assert(point_count >= 2);
    const segments = point_count - 1;
    return (segments + chunk_segments_min - 1) / chunk_segments_min;
}

/// Segments a cubic flattens to (section 3).
pub fn cubic_segments(p0: Point, p1: Point, p2: Point, p3: Point) u32 {
    const chord = length(p0, p3);
    const polygon = length(p0, p1) + length(p1, p2) + length(p2, p3);
    assert(chord <= polygon + 0.001 * polygon + 0.001);
    const estimate = (chord + polygon) * 0.5;
    const wanted = @ceil(estimate / flatten_px);
    const lo: f32 = @floatFromInt(segments_min);
    const hi: f32 = @floatFromInt(segments_max);
    const segments: u32 = @intFromFloat(std.math.clamp(wanted, lo, hi));
    assert(segments >= segments_min);
    assert(segments <= segments_max);
    return segments;
}

/// Writes the flattened cubic into `out` and returns its point count, `cubic_segments + 1`.
/// The ends are exactly `p0` and `p3`.
pub fn flatten_cubic(
    out: *[cubic_points_max]Point,
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
) u32 {
    const segments = cubic_segments(p0, p1, p2, p3);
    const step = 1.0 / @as(f32, @floatFromInt(segments));
    out[0] = p0;
    var index: u32 = 1;
    while (index < segments) : (index += 1) {
        const t = @as(f32, @floatFromInt(index)) * step;
        const u = 1 - t;
        const w0 = u * u * u;
        const w1 = 3 * u * u * t;
        const w2 = 3 * u * t * t;
        const w3 = t * t * t;
        out[index] = .{
            w0 * p0[0] + w1 * p1[0] + w2 * p2[0] + w3 * p3[0],
            w0 * p0[1] + w1 * p1[1] + w2 * p2[1] + w3 * p3[1],
        };
    }
    out[segments] = p3;
    assert(out[0][0] == p0[0]);
    assert(out[segments][1] == p3[1]);
    return segments + 1;
}

/// Maps `samples` into `rect` with `range = .{ lo, hi }` (section 3); one point per sample.
pub fn plot_points(out: []Point, samples: []const f32, rect: Rect, range: [2]f32) void {
    assert(samples.len >= 2);
    assert(out.len == samples.len);
    assert(range[1] > range[0]);
    assert(rect.width > 0);
    const last: f32 = @floatFromInt(samples.len - 1);
    for (out, samples, 0..) |*point, sample, index| {
        const level = std.math.clamp((sample - range[0]) / (range[1] - range[0]), 0, 1);
        point.* = .{
            rect.x + rect.width * @as(f32, @floatFromInt(index)) / last,
            rect.y + rect.height * (1 - level),
        };
    }
    assert(out[0][0] == rect.x);
    assert(out[out.len - 1][0] == rect.x + rect.width);
}

/// The last point index of the chunk that starts at `start` (section 4).
pub fn chunk_end(points: []const Point, start: u32, width: f32) u32 {
    assert(points.len >= 2);
    assert(start + 1 < points.len);
    assert(width > 0);
    const last: u32 = @intCast(points.len - 1);
    const pad = width * 0.5 + aa_pad;
    var low = points[start];
    var high = points[start];
    var end = start;
    while (end < last and end - start < chunk_segments_max) {
        const point = points[end + 1];
        low = .{ @min(low[0], point[0]), @min(low[1], point[1]) };
        high = .{ @max(high[0], point[0]), @max(high[1], point[1]) };
        if (end - start >= chunk_segments_min) {
            const area = (high[0] - low[0] + 2 * pad) * (high[1] - low[1] + 2 * pad);
            if (area > chunk_area_max) break;
        }
        end += 1;
    }
    assert(end > start);
    assert(end - start <= chunk_segments_max);
    if (end < last) assert(end - start >= chunk_segments_min);
    return end;
}

/// The chunks `points` split into for a stroke of `width`.
pub fn chunk_count(points: []const Point, width: f32) u32 {
    assert(points.len >= 2);
    const last: u32 = @intCast(points.len - 1);
    var count: u32 = 0;
    var start: u32 = 0;
    while (start < last) {
        start = chunk_end(points, start, width);
        count += 1;
    }
    assert(count >= 1);
    assert(count <= chunks_max(@intCast(points.len)));
    return count;
}

/// Distance from `(x, y)` to the polyline through `points` (one point is a dot). The stroke
/// of width `w` covers the points where it is at most `w / 2` (section 6).
pub fn distance_to_polyline(points: []const Point, x: f32, y: f32) f32 {
    assert(points.len >= 1);
    var best = length(points[0], .{ x, y });
    var index: usize = 1;
    while (index < points.len) : (index += 1) {
        const a = points[index - 1];
        const b = points[index];
        best = @min(best, types.sdf_segment(x, y, a[0], a[1], b[0], b[1]));
    }
    assert(best >= 0);
    return best;
}

/// The alpha the `Path` shader writes at `(x, y)` (absolute, logical pixels) for `chunk`,
/// with `points` the frame's whole point buffer and `pixel_size` the logical size of one
/// device pixel. Zero outside the chunk's rect, where no fragment runs. CPU twin of
/// `types.Path.pixel` and the prelude's clip mask.
pub fn chunk_alpha(
    points: []const Point,
    chunk: *const types.Path,
    x: f32,
    y: f32,
    pixel_size: f32,
) f32 {
    assert(pixel_size > 0);
    const rect = chunk.rect;
    if (x < rect[0] or x >= rect[0] + rect[2]) return 0;
    if (y < rect[1] or y >= rect[1] + rect[3]) return 0;
    const qx = x - rect[0] - chunk.anchor_x;
    const qy = y - rect[1] - chunk.anchor_y;
    const head: u32 = @intFromFloat(chunk.first_point);
    const tail: u32 = head + @as(u32, @intFromFloat(chunk.point_count)) - 1;
    assert(tail < points.len);
    const own = distance_to_polyline(points[head .. tail + 1], qx, qy);
    var before: f32 = std.math.floatMax(f32);
    if (chunk.prev > 0.5) before = segment_at(points, head - 1, qx, qy);
    var after: f32 = std.math.floatMax(f32);
    if (chunk.next > 0.5) after = segment_at(points, tail, qx, qy);
    if (!(own < before)) return 0;
    if (!(own <= after)) return 0;
    const clip = chunk.clip;
    if (x < clip[0] or y < clip[1] or x > clip[2] or y > clip[3]) return 0;
    const alpha = std.math.clamp(0.5 - (own - 0.5 * chunk.width) / pixel_size, 0, 1);
    assert(alpha >= 0);
    return chunk.color[3] * alpha;
}

fn segment_at(points: []const Point, index: u32, x: f32, y: f32) f32 {
    assert(index + 1 < points.len);
    const a = points[index];
    const b = points[index + 1];
    return types.sdf_segment(x, y, a[0], a[1], b[0], b[1]);
}

/// Appends the stroke through `points` (absolute, at least two) to the draw context `cx` on
/// its current layer. Returns where its points went, or null when the point pool, the `Path`
/// pool, or the batch list could not take all of it; nothing is kept then and the refusal is
/// counted in `cx.overflow_count`.
pub fn polyline(cx: anytype, points: []const Point, stroke: Stroke, clip: Clip) ?Placed {
    assert(points.len >= 2);
    assert(stroke.width > 0);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    const count: u32 = @intCast(points.len);
    const chunks = chunk_count(points, stroke.width);
    if (cx.room(types.Path) < chunks) {
        cx.refuse();
        return null;
    }
    const first = cx.reserve_points(count) orelse return null;
    const bounds = bounds_of(points);
    for (cx.points[first..][0..count], points) |*stored, point| {
        stored.* = .{ point[0] - bounds.x, point[1] - bounds.y };
    }
    const last = count - 1;
    var start: u32 = 0;
    while (start < last) {
        const end = chunk_end(points, start, stroke.width);
        const instance = chunk_of(points, start, end, first, bounds, stroke, clip);
        cx.append(types.Path, null, instance) catch |err| switch (err) {
            // Only the first chunk can open a batch: the rest share its layer and type.
            error.BatchFull => {
                assert(start == 0);
                cx.release_points(first);
                return null;
            },
            error.PoolFull, error.EdgeNotPositive, error.ClipUnordered => unreachable,
        };
        start = end;
    }
    return .{ .first = first, .count = count, .bounds = bounds };
}

/// Flattens the cubic and appends it as `polyline` does.
pub fn cubic(cx: anytype, control: [4]Point, stroke: Stroke, clip: Clip) ?Placed {
    var points: [cubic_points_max]Point = undefined;
    const count = flatten_cubic(&points, control[0], control[1], control[2], control[3]);
    assert(count >= segments_min + 1);
    return polyline(cx, points[0..count], stroke, clip);
}

/// Plots `samples` into `rect` over `range` (section 3) and appends it as `polyline` does.
pub fn plot(
    cx: anytype,
    samples: []const f32,
    rect: Rect,
    range: [2]f32,
    stroke: Stroke,
    clip: Clip,
) ?Placed {
    assert(samples.len >= 2);
    assert(samples.len <= plot_samples_max);
    var points: [plot_samples_max]Point = undefined;
    plot_points(points[0..samples.len], samples, rect, range);
    return polyline(cx, points[0..samples.len], stroke, clip);
}

/// The instance of the chunk `points[start..end + 1]`; `first` is the path's first pool index.
fn chunk_of(
    points: []const Point,
    start: u32,
    end: u32,
    first: u32,
    origin: Rect,
    stroke: Stroke,
    clip: Clip,
) types.Path {
    assert(start < end);
    assert(end < points.len);
    const box = bounds_of(points[start .. end + 1]);
    const pad = stroke.width * 0.5 + aa_pad;
    const x = box.x - pad;
    const y = box.y - pad;
    const instance: types.Path = .{
        .rect = .{ x, y, box.width + 2 * pad, box.height + 2 * pad },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = stroke.color,
        .anchor_x = origin.x - x,
        .anchor_y = origin.y - y,
        .width = stroke.width,
        .hover = stroke.hover,
        .first_point = @floatFromInt(first + start),
        .point_count = @floatFromInt(end - start + 1),
        .prev = if (start > 0) 1 else 0,
        .next = if (end + 1 < points.len) 1 else 0,
    };
    assert(instance.rect[2] > 0);
    assert(instance.rect[3] > 0);
    return instance;
}

/// The unpadded axis-aligned bounds of `points` (zero width or height for a straight line).
fn bounds_of(points: []const Point) Rect {
    assert(points.len >= 1);
    var low = points[0];
    var high = points[0];
    for (points[1..]) |point| {
        assert(point[0] == point[0]);
        assert(point[1] == point[1]);
        low = .{ @min(low[0], point[0]), @min(low[1], point[1]) };
        high = .{ @max(high[0], point[0]), @max(high[1], point[1]) };
    }
    const box: Rect = .{
        .x = low[0],
        .y = low[1],
        .width = high[0] - low[0],
        .height = high[1] - low[1],
    };
    assert(box.width >= 0);
    assert(box.height >= 0);
    return box;
}

fn length(a: Point, b: Point) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return @sqrt(dx * dx + dy * dy);
}

comptime {
    assert(chunk_points_max == 16);
    assert(chunk_segments_min <= chunk_segments_max);
    assert(segments_min >= 1);
    // A flattened cubic of the most segments makes at most 16 chunks.
    assert((segments_max + chunk_segments_min - 1) / chunk_segments_min == 16);
    // Point indices are carried as f32 instance fields and must stay exact.
    assert(pools.point_cap_max <= 1 << 24);
    assert(@sizeOf(Point) == 8);
}

const testing = std.testing;
const registry = @import("registry.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 4 },
    .{ .type = types.Path, .cap = 48 },
};

const TestContext = pools.Context(&test_draw, 4, 512);

fn new_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

const window: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 2000, .y1 = 2000 };
const cable_stroke: Stroke = .{ .color = .{ 0.9, 0.5, 0.2, 0.85 }, .width = 4, .hover = 0 };

/// A cable from `a` to `b` sagging by `sag` at both inner control points.
fn sagging(a: Point, b: Point, sag: f32) [4]Point {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return .{
        a,
        .{ a[0] + dx / 3, a[1] + dy / 3 + sag },
        .{ a[0] + 2 * dx / 3, a[1] + 2 * dy / 3 + sag },
        b,
    };
}

/// One minus the product of one minus each chunk's alpha: source-over of every chunk at
/// `(x, y)`, which is what the GPU blends.
fn composite(cx: *const TestContext, x: f32, y: f32, pixel_size: f32) f32 {
    var clear: f32 = 1;
    for (cx.items(types.Path)) |*chunk| {
        clear *= 1 - chunk_alpha(cx.point_items(), chunk, x, y, pixel_size);
    }
    return 1 - clear;
}

/// The largest composite alpha over a half-pixel grid covering every chunk's rect.
fn composite_max(cx: *const TestContext) f32 {
    var low: Point = .{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var high: Point = .{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (cx.items(types.Path)) |chunk| {
        low = .{ @min(low[0], chunk.rect[0]), @min(low[1], chunk.rect[1]) };
        high = .{
            @max(high[0], chunk.rect[0] + chunk.rect[2]),
            @max(high[1], chunk.rect[1] + chunk.rect[3]),
        };
    }
    var most: f32 = 0;
    var y = low[1] + 0.25;
    while (y < high[1]) : (y += 0.5) {
        var x = low[0] + 0.25;
        while (x < high[0]) : (x += 0.5) most = @max(most, composite(cx, x, y, 1));
    }
    return most;
}

// Locks the flattening count `clamp(ceil(((chord + polygon) / 2) / 6), 4, 64)` at both clamps
// and between them, and that the ends are exactly the cubic's ends.
test "a cubic flattens to the clamped segment count with exact ends" {
    const short = [4]Point{ .{ 0, 0 }, .{ 4, 0 }, .{ 8, 0 }, .{ 12, 0 } };
    try testing.expectEqual(@as(u32, 4), cubic_segments(short[0], short[1], short[2], short[3]));
    const mid = [4]Point{ .{ 0, 0 }, .{ 40, 0 }, .{ 80, 0 }, .{ 120, 0 } };
    try testing.expectEqual(@as(u32, 20), cubic_segments(mid[0], mid[1], mid[2], mid[3]));
    // A sag adds polygon length: chord 300, polygon 2 * sqrt(100^2 + 60^2) + 100 = 333.24,
    // estimate 316.62, so 53 segments.
    const sag = sagging(.{ 0, 0 }, .{ 300, 0 }, 60);
    try testing.expectEqual(@as(u32, 53), cubic_segments(sag[0], sag[1], sag[2], sag[3]));
    const long = sagging(.{ 100, 100 }, .{ 800, 700 }, 160);
    var out: [cubic_points_max]Point = undefined;
    const count = flatten_cubic(&out, long[0], long[1], long[2], long[3]);
    try testing.expectEqual(@as(u32, 65), count);
    try testing.expectEqual(long[0], out[0]);
    try testing.expectEqual(long[3], out[64]);
    // The midpoint of a cubic is (p0 + 3 p1 + 3 p2 + p3) / 8: 450 + 0.75 * 160 down.
    try testing.expectApproxEqAbs(@as(f32, 450), out[32][0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 520), out[32][1], 0.001);
}

// Locks the chunk rule: chunks share their end points, hold 5 to 16 points (the last may hold
// fewer), and number at most `chunks_max`. Even a straight horizontal cable stops at 11
// points, where its 6 px tall bounds pass `chunk_area_max`; a diagonal one splits at the
// four-segment floor.
test "chunk boundaries share points and hold at most 16" {
    const cases = [_][4]Point{
        sagging(.{ 100, 150 }, .{ 1100, 150 }, 0),
        sagging(.{ 100, 100 }, .{ 800, 700 }, 160),
        sagging(.{ 0, 0 }, .{ 40, 0 }, 160),
    };
    const expected_chunks = [_]u32{ 7, 16, 5 };
    for (cases, expected_chunks) |control, expected| {
        var out: [cubic_points_max]Point = undefined;
        const count = flatten_cubic(&out, control[0], control[1], control[2], control[3]);
        const points = out[0..count];
        var start: u32 = 0;
        var chunks: u32 = 0;
        while (start < count - 1) {
            const end = chunk_end(points, start, 4);
            try testing.expect(end - start + 1 <= chunk_points_max);
            if (end < count - 1) try testing.expect(end - start >= chunk_segments_min);
            chunks += 1;
            start = end;
        }
        try testing.expectEqual(count - 1, start);
        try testing.expectEqual(expected, chunks);
        try testing.expectEqual(chunks, chunk_count(points, 4));
        try testing.expect(chunks <= chunks_max(count));
    }
}

// Locks the distance twin at worked points of an L-shaped polyline, and a single point.
test "the distance twin measures to the nearest segment" {
    const points = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } };
    try testing.expectApproxEqAbs(@as(f32, 3), distance_to_polyline(&points, 5, 3), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3), distance_to_polyline(&points, 13, 5), 0.0001);
    const corner = distance_to_polyline(&points, 12, 12);
    try testing.expectApproxEqAbs(@sqrt(@as(f32, 8)), corner, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5), distance_to_polyline(&points, -3, -4), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5), distance_to_polyline(points[0..1], 3, 4), 0.0001);
}

// Locks the plot mapping: the first and last samples land on the rect's left and right
// edges, `lo` on its bottom, `hi` on its top, and a sample past `hi` is clamped.
test "plot maps samples into the rect" {
    const samples = [_]f32{ 0, 0.5, 1, 2, -1 };
    var out: [5]Point = undefined;
    plot_points(&out, &samples, .{ .x = 10, .y = 20, .width = 100, .height = 40 }, .{ 0, 1 });
    try testing.expectEqual(Point{ 10, 60 }, out[0]);
    try testing.expectEqual(Point{ 35, 40 }, out[1]);
    try testing.expectEqual(Point{ 60, 20 }, out[2]);
    try testing.expectEqual(Point{ 85, 20 }, out[3]);
    try testing.expectEqual(Point{ 110, 60 }, out[4]);
    const cx = new_context();
    const placed = plot(cx, &samples, .{ .x = 10, .y = 20, .width = 100, .height = 40 }, .{
        0, 1,
    }, cable_stroke, window).?;
    try testing.expectEqual(@as(u32, 5), placed.count);
    try testing.expectEqual(@as(usize, 1), cx.items(types.Path).len);
}

// Locks the record: points are stored once, relative to the path's origin, each chunk indexes
// its own range with `prev` and `next` set at seams, and every pixel the stroke covers (at 1x
// and 2x) lies inside its chunk's rect.
test "every chunk's rect contains its stroke" {
    const cx = new_context();
    const control = sagging(.{ 100, 100 }, .{ 800, 700 }, 160);
    const placed = cubic(cx, control, cable_stroke, window).?;
    try testing.expectEqual(@as(u32, 0), placed.first);
    try testing.expectEqual(@as(u32, 65), placed.count);
    try testing.expectEqual(@as(u32, 65), cx.point_count);
    const stored = cx.point_items();
    try testing.expectEqual(Point{ 0, 0 }, stored[0]);
    try testing.expectEqual(Point{ 700, 600 }, stored[64]);
    const chunks = cx.items(types.Path);
    try testing.expectEqual(@as(usize, 16), chunks.len);
    try testing.expectEqual(@as(f32, 0), chunks[0].prev);
    try testing.expectEqual(@as(f32, 1), chunks[0].next);
    try testing.expectEqual(@as(f32, 0), chunks[15].next);
    var expected_first: f32 = 0;
    for (chunks) |chunk| {
        try testing.expectEqual(expected_first, chunk.first_point);
        expected_first += chunk.point_count - 1;
        const head: u32 = @intFromFloat(chunk.first_point);
        const tail = head + @as(u32, @intFromFloat(chunk.point_count));
        const origin_x = chunk.rect[0] + chunk.anchor_x;
        const origin_y = chunk.rect[1] + chunk.anchor_y;
        try testing.expectEqual(placed.bounds.x, origin_x);
        for ([_]f32{ 1, 0.5 }) |pixel_size| {
            const reach = chunk.width * 0.5 + 0.5 * pixel_size;
            var y = chunk.rect[1] - 4;
            while (y < chunk.rect[1] + chunk.rect[3] + 4) : (y += 0.5) {
                var x = chunk.rect[0] - 4;
                while (x < chunk.rect[0] + chunk.rect[2] + 4) : (x += 0.5) {
                    const d = distance_to_polyline(stored[head..tail], x - origin_x, y - origin_y);
                    if (d >= reach) continue;
                    try testing.expect(x >= chunk.rect[0]);
                    try testing.expect(x < chunk.rect[0] + chunk.rect[2]);
                    try testing.expect(y >= chunk.rect[1]);
                    try testing.expect(y < chunk.rect[1] + chunk.rect[3]);
                }
            }
        }
    }
    try testing.expectEqual(@as(f32, 64), expected_first);
}

// Locks the seam rule (section 4): source-over of every chunk of a translucent straight cable
// and of a deep U-shaped one never exceeds the stroke's alpha, so no seam shows a dot. A
// hairpin whose 4 px wide arms are 3 px apart across a seam draws its overlap twice: at alpha
// 0.85 the worst pixel reaches 0.9456, 0.0956 over the stroke, below the full two-layer blend
// `1 - (1 - a)^2 = 0.9775` because the arms overlap only partly.
test "seams blend once and close folds twice" {
    const alpha = cable_stroke.color[3];
    const cx = new_context();
    _ = cubic(cx, sagging(.{ 100, 150 }, .{ 1100, 150 }, 160), cable_stroke, window).?;
    try testing.expect(cx.items(types.Path).len >= 4);
    const straight = composite_max(cx);
    try testing.expect(straight <= alpha + 1.0e-4);
    try testing.expect(straight >= alpha - 1.0e-4);
    cx.reset();
    _ = cubic(cx, sagging(.{ 100, 100 }, .{ 140, 100 }, 240), cable_stroke, window).?;
    try testing.expect(cx.items(types.Path).len >= 4);
    try testing.expect(composite_max(cx) <= alpha + 1.0e-4);
    cx.reset();
    // Two 30 px arms 3 px apart, joined at the bottom: chunks 0 and 2 hold the arms' far ends.
    var hairpin: [21]Point = undefined;
    for (hairpin[0..10], 0..) |*point, index| {
        point.* = .{ 0, @as(f32, @floatFromInt(index)) * 3 };
    }
    hairpin[10] = .{ 1.5, 30 };
    for (hairpin[11..], 0..) |*point, index| {
        point.* = .{ 3, 27 - @as(f32, @floatFromInt(index)) * 3 };
    }
    _ = polyline(cx, &hairpin, cable_stroke, window).?;
    try testing.expect(cx.items(types.Path).len >= 2);
    const twice = 1 - (1 - alpha) * (1 - alpha);
    const folded = composite_max(cx);
    try testing.expect(folded <= twice);
    try testing.expectApproxEqAbs(@as(f32, 0.0956), folded - alpha, 1.0e-4);
}

// Locks the chunk area choice by the fragments it rasterizes and the segments they measure:
// a 1,000 px diagonal cable (64 segments, 16 chunks) rasterizes 34.6k fragments and 203k
// segment evaluations, where 16-point chunks (5 chunks) would take 105k and 1.74M. Fragments
// are logical pixels: 4x at 2x scale.
test "chunk area bounds the fragments of a diagonal cable" {
    const cx = new_context();
    _ = cubic(cx, sagging(.{ 100, 100 }, .{ 800, 700 }, 160), cable_stroke, window).?;
    var fragments: f32 = 0;
    var evaluations: f32 = 0;
    for (cx.items(types.Path)) |chunk| {
        const area = chunk.rect[2] * chunk.rect[3];
        fragments += area;
        evaluations += area * (chunk.point_count - 1 + chunk.prev + chunk.next);
    }
    try testing.expectEqual(@as(usize, 16), cx.items(types.Path).len);
    try testing.expectApproxEqAbs(@as(f32, 34_626), fragments, 1);
    try testing.expectApproxEqAbs(@as(f32, 203_428), evaluations, 4);
}

// Locks atomic appends: a path whose chunks do not fit the pool, or whose points do not fit
// the point pool, keeps nothing and is counted once; a full batch list takes the points back.
test "a refused path keeps nothing and is counted" {
    const cx = new_context();
    var many: [400]Point = undefined;
    for (&many, 0..) |*point, index| point.* = .{ @floatFromInt(index * 50), 0 };
    try testing.expect(chunk_count(&many, 4) > 48);
    try testing.expectEqual(@as(?Placed, null), polyline(cx, &many, cable_stroke, window));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expectEqual(@as(u32, 0), cx.point_count);
    var straight: [300]Point = undefined;
    for (&straight, 0..) |*point, index| point.* = .{ @floatFromInt(index), 0 };
    _ = polyline(cx, &straight, cable_stroke, window).?;
    try testing.expectEqual(@as(?Placed, null), polyline(cx, &straight, cable_stroke, window));
    try testing.expectEqual(@as(u32, 2), cx.overflow_count);
    try testing.expectEqual(@as(u32, 300), cx.point_count);
    cx.reset();
    var level: u8 = 0;
    while (level < 4) : (level += 1) {
        _ = cx.layer(@fromBackingInt(level));
        try cx.append(types.Box, null, .{
            .rect = .{ 0, 0, 1, 1 },
            .clip = .{ 0, 0, 1, 1 },
            .fill = .{ 1, 1, 1, 1 },
            .border_color = .{ 0, 0, 0, 0 },
            .radius = 0,
            .border_width = 0,
            .hover = 0,
            .down = 0,
        });
    }
    const revision = cx.point_revision;
    try testing.expectEqual(@as(?Placed, null), polyline(cx, straight[0..2], cable_stroke, window));
    try testing.expectEqual(@as(u32, 0), cx.point_count);
    try testing.expect(cx.point_revision > revision);
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
}

// Locks that a container shift moves the stroke with its rects: the alpha at a point before
// the shift is the alpha at that point plus the delta after it, for every chunk.
test "a shift moves the stroke with its rects" {
    const cx = new_context();
    const starts = cx.counts();
    _ = cubic(cx, sagging(.{ 10, 10 }, .{ 200, 90 }, 40), cable_stroke, window).?;
    var before: [64]f32 = undefined;
    const probes = [_]Point{ .{ 10, 10 }, .{ 105, 70 }, .{ 200, 91 }, .{ 60, 40 } };
    for (probes, 0..) |probe, index| before[index] = composite(cx, probe[0], probe[1], 1);
    cx.shift(starts, 3, 5);
    for (probes, 0..) |probe, index| {
        const after = composite(cx, probe[0] + 3, probe[1] + 5, 1);
        try testing.expectApproxEqAbs(before[index], after, 1.0e-5);
    }
    try testing.expect(before[0] > 0.4);
}

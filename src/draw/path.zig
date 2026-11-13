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
//!      owned = the seam rule against `before` and `after` (sections 4 and 4a)
//!      near  = min(own, before, after)                                     solid
//!              min of the dashed distances of the same segments (4b)      dashed
//!      alpha = color.a * coverage(near - width / 2) * owned * clip_mask
//! ```
//! The point buffer is the context's point pool (`draw/pools.zig`, section 5b), uploaded by
//! dirty range like the instance pools and bound once per pass (`draw/renderer.zig`).
//!
//! ## 3. Flattening
//! A cubic gets `clamp(ceil(estimate * zoom / flatten_px), segments_min, segments_max)`
//! uniform-`t` segments, where `estimate = (chord + control polygon) / 2` bounds the arc length
//! from both sides and `zoom` is the open canvas's (`draw/pools.zig`, section 5c), 1 elsewhere:
//! segments follow the on-screen length. `plot` maps `n` samples to
//! `x = rect.x + rect.width * i / (n - 1)` and
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
//! that: a chunk with `prev` also measures the previous chunk's last segment (`before`) and one
//! with `next` the next chunk's first (`after`), and a fragment belongs to the chunk whose
//! segment is nearest, ties decided as section 4a says. A smooth or folded path therefore
//! blends once everywhere. What remains is two parts of a path that come within the stroke
//! width of each other more than one segment apart across a seam, or that cross: there both
//! chunks draw. Test "seams blend once and close folds twice" measures both.
//!
//! `polygon` closes the path: its last chunk's `next` joins its first, so the rule holds at the
//! closure too. The stored points are the ring of `n` points with its last point before it and
//! its first two after it, so `points[head - 1]` and `points[tail + 1]` exist; a chunk measures
//! the same indices as anywhere else, and the closure's tie goes to the last chunk. A ring of one
//! chunk has no seam and sets neither flag. A ring never splits into two chunks of which the
//! second is one segment (`ring_first_end`): that segment would be both of the first chunk's
//! neighbours (section 4a).
//!
//! ## 4a. Ties at a Seam
//! Where the two seam segments are equally near, the plain rule asks each chunk to break the tie
//! on its own, and the two do not agree: the rasterizer snaps each chunk's quad to its own
//! sub-pixel grid, so the chunks place one fragment a few thousandths of a pixel apart, and
//! `sdf_segment` rounds a reversed segment differently. A tie is a line at a gentle bend, but an
//! area beyond the seam point at a sharp one, and the whole stroke where a path turns straight
//! back on itself: there each pixel was dropped by both chunks or drawn by both (Patchwork step
//! 62, Tapestry's comb). The rule is therefore, at each seam, with `adjacent` the chunk's own
//! segment at that seam:
//! ```text
//! own < neighbour - seam_tie                 this chunk's
//! |adjacent - neighbour| <= seam_tie         a tie: this chunk's if seam_side is on its side
//! otherwise                                  the plain rule, ties to the earlier chunk
//! seam_side = signed distance from the line through the seam point b: the bisector of the
//!             turn up to a right angle, past one the line across the earlier segment at b;
//!             the earlier chunk keeps seam_side <= seam_bias
//! ```
//! The tie is the two segments that meet at the seam, not `own`: a ring of two chunks meets at
//! two seams, and near one of them the neighbour segment is within the tie of `own` while the
//! other seam's side test means nothing there.
//! Both chunks compute the line from the same three stored points, so it is the same bits in
//! each, and inside a tie neither distance decides. `seam_bias` keeps the line off the bisector,
//! where a symmetric shape puts whole rows of pixel centres, and `seam_tie` exceeds twice the
//! bias by more than the chunks' placement differs, so the side test and the distance agree at
//! the tie's edge. A fold, or a near fold whose arms stay within the tie, goes to the earlier
//! chunk whole. The owner draws `min(own, before, after)`, so a fragment a tie hands across
//! draws the alpha of the nearest segment, and a fragment the plain rule gave the same chunk
//! draws exactly as before.
//!
//! What a tie cannot remove is the line where ownership changes: a fragment within the
//! placement difference of it can still be dropped or drawn twice. That line crosses the stroke
//! once at each seam, as the bisector did before, and runs along a near fold whose arms part by
//! more than the tie. Computing `q` from the fragment's device position instead of the
//! interpolated `local` would make every chunk's `q` the same bits and remove it; that needs the
//! device mapping in the frame uniform. Test "a stroke that turns back at a seam draws once"
//! locks the rule with the chunks moved apart.
//!
//! ## 4b. Dashes
//! A `Stroke` with a `Dash` draws only the on-parts of its pattern: at arc length `s` along the
//! flattened polyline the phase is `u = mod(s + offset, on + off)`, and the pattern is on where
//! `u <= on`. A fragment's dashed distance is its distance to the union of the on-parts, so the
//! stroke of that distance is the dashed stroke with round caps and round joins, `on = 0` gives
//! dots, and a dash across a corner is one distance field, blended once.
//!
//! Per segment the nearest on-point is the projection `t` when its phase is on; otherwise the
//! nearer of the end of the dash before it and the start of the dash after it, when they lie on
//! the segment; and none when the whole segment is in a gap. Distance along a straight segment
//! grows with the distance from `t`, so that is the nearest on-point, and in a dash it is
//! `sdf_segment`'s distance exactly. `distance_to_dashes` is the CPU twin of a chunk's loop.
//!
//! Arc length is the CPU's: the appenders sum each stored segment's `f32` length in `f64` and
//! write each chunk's phase at its first point, wrapped into `[0, on + off)` in `f64`, so the
//! record never holds a large value however long the path or however far `offset` has run. The
//! fragment adds its own segments' lengths from there, and the record carries `1 / period` so
//! the phase costs a multiply. A solid stroke writes zeros, and `dash_period = 0` is the
//! shader's switch: the solid branch is the code before dashes, unchanged.
//!
//! Ownership is the solid rule (sections 4 and 4a) on plain distances, so the plane splits
//! between chunks exactly as for a solid path; only the distance the owner draws differs. That
//! owner also measures the dashes on the two neighbour segments at the phases their own chunks
//! use (`dash_phase - length` before, the accumulated phase after; equal up to `f32` rounding),
//! so a dash whose cap crosses a seam is drawn whole by whichever chunk owns each fragment. What
//! remains is section 4's class: a dash on a segment two or more away across a seam, within half
//! the width of a fragment the other chunk owns; flattened cubics' segments are near
//! `flatten_px`, so it needs a polyline with segments shorter than half the width.
//!
//! `polygon` fits the pattern to the ring: with ring length `T` and
//! `k = max(1, round(T / (on + off)))` it scales `on`, `off`, and `offset` by
//! `T / (k * (on + off))`, so a ring has no short dash at its start, flow round it loops
//! seamlessly, and the closure's neighbour phases agree.
//!
//! Flow is the app's: it lowers `offset` on the `frame` event and asks for the next frame. A
//! moved offset rewrites the chunks' records and no points. `Path` is not an animated type,
//! because an animated type keeps every path tile dirty and the app awake, solid or not.
//!
//! ## 5. Coordinates
//! Points are stored relative to the path's origin, the top-left of its unpadded bounds, and
//! each chunk carries `anchor = origin - rect.xy`. `polyline_at` takes the origin from the
//! caller instead: a lane anchored at its rect keeps the stored value of every point that did
//! not move when its bounds change, so a changed sample uploads one point. A container's
//! alignment shift (`Context.shift`) moves `rect.xy` only and `anchor` is a difference, so the
//! stroke moves with the rect and the registry rule "geometry is relative to `rect`" holds. A
//! chunk's rect is its bounds padded by `width / 2 + aa_pad`, which holds every fragment with
//! coverage at display scales of 1 and above.
//!
//! ## 5a. Oriented Quads
//! A chunk's `rect` is its axis-aligned bounds, but a diagonal chunk's box is mostly empty:
//! on the live screen's stress text the curves' boxes covered 0.98 windows for 0.09 windows of
//! stroke. `Path` therefore declares a `vertex` (`draw/registry.zig`, section 2a) that
//! rasterizes a rectangle along the chunk's chord instead:
//! ```text
//! a = first point, dir = (last - a) / |last - a| (the x axis below 1e-3), nrm = dir turned 90
//! t, n = min and max of dot(p - a, dir) and dot(p - a, nrm) over the chunk's points
//! quad = a + dir * [t_lo - r, t_hi + r] + nrm * [n_lo - r, n_hi + r],  r = width / 2 + aa_pad
//! ```
//! Every point within `r` of a segment lies inside, because the segments lie in the hull of
//! the points and the box of the points contains the hull. `rect`, chunking, capacities, and
//! hit areas do not change. `oriented_quad` is the CPU twin, `chunk_alpha` applies it, and test
//! "every chunk's oriented quad contains its stroke" locks the containment.
//!
//! ## 6. Hit Testing
//! `distance_to_polyline` is the CPU twin of the stroke distance. `ui.Context.path_area`
//! records a path area whose `radius` is `width / 2 + hit_slop` and whose rect is the bounds
//! padded by that radius, so the origin is `rect.xy + radius` (`ui/areas.zig`). It measures the
//! whole polyline, so a dashed stroke is hit in its gaps too: a cable is picked by its length.
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

/// Seam distances closer than this, in logical pixels, are a tie, which the side of the seam
/// decides (section 4a). Twice it must clear `seam_bias` by more than the few thousandths of a
/// pixel by which two chunks place one fragment.
pub const seam_tie: f32 = 8.0e-2;

/// Within a tie the earlier chunk keeps a fragment whose `seam_side` is at most this many
/// logical pixels: a line off the bisector, because a symmetric shape puts whole rows of pixel
/// centres on the bisector itself (section 4a).
pub const seam_bias: f32 = 2.5e-2;

/// Hit distance past the half width (section 6).
pub const hit_slop: f32 = 3;

/// Samples `plot` takes at most.
pub const plot_samples_max: u32 = 256;

/// Points `polygon` takes at most.
pub const polygon_points_max: u32 = 256;

/// A dash pattern in logical pixels (world pixels on a canvas, like `width`), measured along
/// the flattened polyline (section 4b). Dashes have round caps, as the stroke has: a dash of
/// `on` covers `on + width` on screen, and `on = 0` draws dots `off` apart.
pub const Dash = struct {
    on: f32,
    off: f32,
    /// Shifts the pattern toward the path's start, as SVG `stroke-dashoffset` does: a dash at
    /// arc length `s` with offset 0 is at `s - offset` with `offset`. Lowering it each frame
    /// moves the dashes toward the path's end (flow).
    offset: f32 = 0,
};

/// Color, width in logical pixels, the hover mix toward `theme.lighten`, and the dash pattern.
pub const Stroke = struct {
    color: [4]f32,
    width: f32,
    hover: f32,
    /// Null is a solid stroke, drawn exactly as before dashes existed.
    dash: ?Dash = null,
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
    return cubic_segments_at(p0, p1, p2, p3, 1);
}

/// Segments a cubic drawn at `zoom` screen pixels per pixel flattens to: by its on-screen
/// length (section 3).
pub fn cubic_segments_at(p0: Point, p1: Point, p2: Point, p3: Point, zoom: f32) u32 {
    assert(zoom > 0);
    const chord = length(p0, p3);
    const hull = length(p0, p1) + length(p1, p2) + length(p2, p3);
    assert(chord <= hull + 0.001 * hull + 0.001);
    const estimate = (chord + hull) * 0.5;
    const wanted = @ceil(estimate * zoom / flatten_px);
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
    return flatten_cubic_at(out, p0, p1, p2, p3, 1);
}

/// `flatten_cubic` for a cubic drawn at `zoom` (`cubic_segments_at`).
pub fn flatten_cubic_at(
    out: *[cubic_points_max]Point,
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    zoom: f32,
) u32 {
    const segments = cubic_segments_at(p0, p1, p2, p3, zoom);
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

/// The corners of the quad `types.Path.vertex` rasterizes for a chunk through `points`, in
/// the points' coordinates, in the order (t_lo, n_lo), (t_hi, n_lo), (t_hi, n_hi),
/// (t_lo, n_hi) (section 5a).
pub fn oriented_quad(points: []const Point, width: f32) [4]Point {
    assert(points.len >= 2);
    assert(points.len <= chunk_points_max);
    assert(width > 0);
    const a = points[0];
    const chord: Point = .{ points[points.len - 1][0] - a[0], points[points.len - 1][1] - a[1] };
    const chord_length = @sqrt(chord[0] * chord[0] + chord[1] * chord[1]);
    const dir: Point = if (chord_length > 1.0e-3)
        .{ chord[0] / chord_length, chord[1] / chord_length }
    else
        .{ 1, 0 };
    const nrm: Point = .{ -dir[1], dir[0] };
    var low: Point = .{ 0, 0 };
    var high: Point = .{ 0, 0 };
    for (points[1..]) |point| {
        const d: Point = .{ point[0] - a[0], point[1] - a[1] };
        const t = d[0] * dir[0] + d[1] * dir[1];
        const n = d[0] * nrm[0] + d[1] * nrm[1];
        low = .{ @min(low[0], t), @min(low[1], n) };
        high = .{ @max(high[0], t), @max(high[1], n) };
    }
    const r = width * 0.5 + aa_pad;
    var corners: [4]Point = undefined;
    const ts = [4]f32{ low[0] - r, high[0] + r, high[0] + r, low[0] - r };
    const ns = [4]f32{ low[1] - r, low[1] - r, high[1] + r, high[1] + r };
    for (&corners, ts, ns) |*corner, t, n| {
        corner.* = .{ a[0] + dir[0] * t + nrm[0] * n, a[1] + dir[1] * t + nrm[1] * n };
    }
    assert(high[0] >= low[0]);
    assert(high[1] >= low[1]);
    return corners;
}

/// True when `p` is inside the convex quad `corners` (either winding), edges included.
pub fn quad_contains(corners: [4]Point, p: Point) bool {
    var negative = false;
    var positive = false;
    for (0..4) |index| {
        const a = corners[index];
        const b = corners[(index + 1) % 4];
        const cross = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
        if (cross < 0) negative = true;
        if (cross > 0) positive = true;
    }
    return !(negative and positive);
}

/// The alpha the `Path` shader writes at `(x, y)` (absolute, logical pixels) for `chunk`,
/// with `points` the frame's whole point buffer and `pixel_size` the logical size of one
/// device pixel. Zero outside the chunk's rect and outside its oriented quad, where no
/// fragment runs. CPU twin of `types.Path.vertex`, `types.Path.pixel`, and the prelude's clip
/// mask.
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
    const own_points = points[head .. tail + 1];
    if (!quad_contains(oriented_quad(own_points, chunk.width), .{ qx, qy })) return 0;
    const own = distance_to_polyline(own_points, qx, qy);
    const q: Point = .{ qx, qy };
    var before: f32 = std.math.floatMax(f32);
    var before_side: f32 = 1;
    if (chunk.prev > 0.5) {
        before = segment_at(points, head - 1, qx, qy);
        before_side = seam_side(q, points[head - 1], points[head], points[head + 1]);
    }
    var after: f32 = std.math.floatMax(f32);
    var after_side: f32 = -1;
    if (chunk.next > 0.5) {
        after = segment_at(points, tail, qx, qy);
        after_side = seam_side(q, points[tail - 1], points[tail], points[tail + 1]);
    }
    if (chunk.prev > 0.5) {
        const first = segment_at(points, head, qx, qy);
        if (!seam_wins(own, first, before, before_side > seam_bias, false)) return 0;
    }
    if (chunk.next > 0.5) {
        const last = segment_at(points, tail - 1, qx, qy);
        if (!seam_wins(own, last, after, after_side <= seam_bias, true)) return 0;
    }
    const clip = chunk.clip;
    if (x < clip[0] or y < clip[1] or x > clip[2] or y > clip[3]) return 0;
    const near = if (chunk.dash_period > 0)
        dashed_near(points, chunk, q)
    else
        @min(own, @min(before, after));
    const alpha = std.math.clamp(0.5 - (near - 0.5 * chunk.width) / pixel_size, 0, 1);
    assert(alpha >= 0);
    return chunk.color[3] * alpha;
}

/// True when a chunk keeps a fragment against the neighbour segment at distance `neighbour`
/// across one seam (section 4a). `own` is the chunk's distance, `adjacent` its segment at the
/// seam's: within `seam_tie` of the neighbour that is a tie, which `own_side` decides; else the
/// plain rule, ties to the earlier chunk (`earlier`).
fn seam_wins(own: f32, adjacent: f32, neighbour: f32, own_side: bool, earlier: bool) bool {
    assert(own >= 0);
    assert(adjacent >= own);
    if (own < neighbour - seam_tie) return true;
    if (@abs(adjacent - neighbour) <= seam_tie) return own_side;
    if (earlier) return own <= neighbour;
    return own < neighbour;
}

/// The signed distance from `q` to the line through `b` that splits a tie at the seam between
/// the segments a-b and b-c: negative on a-b's side, positive on b-c's. Up to a right angle it
/// is the bisector of the turn; past one, the line across a-b at `b`, so a fold goes to a-b
/// whole (section 4a). CPU twin of `path_seam_side` in `types.Path.pixel`.
pub fn seam_side(q: Point, a: Point, b: Point, c: Point) f32 {
    assert(q[0] == q[0]);
    assert(b[0] == b[0]);
    const into = unit_or_zero(.{ b[0] - a[0], b[1] - a[1] });
    const out = unit_or_zero(.{ c[0] - b[0], c[1] - b[1] });
    const bisector = unit_or_zero(.{ into[0] + out[0], into[1] + out[1] });
    const turned_back = into[0] * out[0] + into[1] * out[1] < 0;
    const normal = if (turned_back) into else bisector;
    return (q[0] - b[0]) * normal[0] + (q[1] - b[1]) * normal[1];
}

/// `v` scaled to unit length as the shader's `v * inverseSqrt(max(dot(v, v), 1e-24))` does: a
/// zero vector stays zero.
fn unit_or_zero(v: Point) Point {
    const scale = 1 / @sqrt(@max(v[0] * v[0] + v[1] * v[1], 1.0e-24));
    assert(scale > 0);
    const unit: Point = .{ v[0] * scale, v[1] * scale };
    assert(unit[0] * unit[0] + unit[1] * unit[1] <= 1.0001);
    return unit;
}

/// The dashed distance a dashed chunk's owner draws (section 4b): the nearest on-part of its own
/// segments and of the neighbour segment at each seam, at the phases the neighbours draw them.
fn dashed_near(points: []const Point, chunk: *const types.Path, q: Point) f32 {
    assert(chunk.dash_period > 0);
    assert(chunk.dash_inverse > 0);
    const head: u32 = @intFromFloat(chunk.first_point);
    const tail: u32 = head + @as(u32, @intFromFloat(chunk.point_count)) - 1;
    const pattern: Pattern = .{
        .on = chunk.dash_on,
        .period = chunk.dash_period,
        .inverse = chunk.dash_inverse,
    };
    const along = dashes_along(points[head .. tail + 1], chunk.dash_phase, pattern, q);
    var near = along.distance;
    if (chunk.prev > 0.5) {
        const span = length(points[head - 1], points[head]);
        const phase = chunk.dash_phase - span;
        near = @min(near, dash_segment(q, points[head - 1], points[head], phase, pattern).distance);
    }
    if (chunk.next > 0.5) {
        const phase = along.phase;
        near = @min(near, dash_segment(q, points[tail], points[tail + 1], phase, pattern).distance);
    }
    assert(near >= 0);
    return near;
}

/// A dash pattern as a record carries it: the on length, the period, and its inverse.
const Pattern = struct {
    on: f32,
    period: f32,
    inverse: f32,
};

/// One segment's dashed distance and its length (`dash_segment`).
const Measure = struct {
    distance: f32,
    span: f32,
};

/// The nearest dashed distance over the segments of `points` and the phase at their last point.
const Along = struct {
    distance: f32,
    phase: f32,
};

/// Distance from `(x, y)` to the on-parts of the polyline through `points` (at least two),
/// whose pattern of `dash_on` and `dash_period` has phase `phase` at the first point. A stroke
/// of width `w` covers the dashed stroke where it is at most `w / 2` (section 4b). CPU twin of
/// the dashed loop of `types.Path.pixel` over one chunk.
pub fn distance_to_dashes(
    points: []const Point,
    phase: f32,
    dash_on: f32,
    dash_period: f32,
    x: f32,
    y: f32,
) f32 {
    assert(points.len >= 2);
    assert(dash_on >= 0);
    assert(dash_period > dash_on);
    const pattern: Pattern = .{ .on = dash_on, .period = dash_period, .inverse = 1 / dash_period };
    const distance = dashes_along(points, phase, pattern, .{ x, y }).distance;
    assert(distance >= 0);
    return distance;
}

fn dashes_along(points: []const Point, phase: f32, pattern: Pattern, q: Point) Along {
    assert(points.len >= 2);
    assert(pattern.period > 0);
    var along: Along = .{ .distance = std.math.floatMax(f32), .phase = phase };
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        const measure = dash_segment(q, a, b, along.phase, pattern);
        along.distance = @min(along.distance, measure.distance);
        along.phase += measure.span;
    }
    assert(along.phase >= phase);
    return along;
}

/// The distance from `q` to the on-parts of the segment a-b, whose pattern phase at `a` is
/// `phase`, and the segment's length: the nearest on-point is the projection when it lies in a
/// dash, else the nearer end of the dash before or after it on the segment, and none when the
/// segment lies inside a gap (section 4b). CPU twin of `path_dash_segment` in
/// `types.Path.pixel`; in a dash the distance is `sdf_segment`'s.
fn dash_segment(q: Point, a: Point, b: Point, phase: f32, pattern: Pattern) Measure {
    assert(pattern.period > 0);
    assert(pattern.on >= 0);
    const pa: Point = .{ q[0] - a[0], q[1] - a[1] };
    const ba: Point = .{ b[0] - a[0], b[1] - a[1] };
    const span = @sqrt(ba[0] * ba[0] + ba[1] * ba[1]);
    const ratio = (pa[0] * ba[0] + pa[1] * ba[1]) / @max(ba[0] * ba[0] + ba[1] * ba[1], 1.0e-12);
    const h = std.math.clamp(ratio, 0, 1);
    const t = h * span;
    const s = phase + t;
    const u = s - pattern.period * @floor(s * pattern.inverse);
    const back = t - (u - pattern.on);
    const ahead = t + (pattern.period - u);
    const back_ok = back >= 0;
    const ahead_ok = ahead <= span;
    const take_back = back_ok and (!ahead_ok or u - pattern.on <= pattern.period - u);
    const target = if (take_back) back else ahead;
    const inside = u <= pattern.on;
    const at = if (inside) h else target / @max(span, 1.0e-6);
    const dx = pa[0] - ba[0] * at;
    const dy = pa[1] - ba[1] * at;
    const reached = inside or back_ok or ahead_ok;
    const distance = if (reached) @sqrt(dx * dx + dy * dy) else 3.0e38;
    assert(distance >= 0);
    return .{ .distance = distance, .span = span };
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
    const bounds = bounds_of(points);
    const first = append_from(cx, points, .{ bounds.x, bounds.y }, stroke, clip) orelse {
        return null;
    };
    return .{ .first = first, .count = @intCast(points.len), .bounds = bounds };
}

/// Appends the stroke through `points` like `polyline`, but stores the points relative to
/// `origin` instead of their bounds' top-left (section 5). With a fixed origin, a path whose
/// bounds change keeps every unmoved point's stored value, so moving one point uploads one
/// point (an automation lane). Returns false when refused. A path placed this way has no
/// `Placed` and cannot take a path area, whose points must be relative to their bounds.
pub fn polyline_at(
    cx: anytype,
    points: []const Point,
    origin: Point,
    stroke: Stroke,
    clip: Clip,
) bool {
    assert(origin[0] == origin[0]);
    assert(origin[1] == origin[1]);
    return append_from(cx, points, origin, stroke, clip) != null;
}

/// The appender behind `polyline` and `polyline_at`: the points relative to `origin`, then
/// one instance per chunk. Returns the first point's pool index, or null when refused.
fn append_from(
    cx: anytype,
    points: []const Point,
    origin: Point,
    stroke: Stroke,
    clip: Clip,
) ?u32 {
    assert(points.len >= 2);
    assert(stroke.width > 0);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    if (stroke.dash) |dash| assert_dash(dash);
    const count: u32 = @intCast(points.len);
    const chunks = chunk_count(points, stroke.width);
    if (cx.room(types.Path) < chunks) {
        cx.refuse();
        return null;
    }
    const first = cx.reserve_points(count) orelse return null;
    for (cx.points[first..][0..count], points) |*stored, point| {
        stored.* = .{ point[0] - origin[0], point[1] - origin[1] };
    }
    const last = count - 1;
    // Arc length to the chunk's first point, over the stored points the GPU reads (section 4b).
    var arc: f64 = 0;
    var start: u32 = 0;
    while (start < last) {
        const end = chunk_end(points, start, stroke.width);
        const instance = chunk_of(points, start, end, first, origin, stroke, clip, arc);
        cx.append(types.Path, null, instance) catch |err| switch (err) {
            // Only the first chunk can open a batch: the rest share its layer and type.
            error.BatchFull => {
                assert(start == 0);
                cx.release_points(first);
                return null;
            },
            error.PoolFull, error.EdgeNotPositive, error.ClipUnordered => unreachable,
        };
        if (stroke.dash != null) arc += arc_length(cx.points[first + start .. first + end + 1]);
        start = end;
    }
    return first;
}

/// Flattens the cubic by its on-screen length (at the open canvas's zoom, `cx.view_zoom`) and
/// appends it as `polyline` does.
pub fn cubic(cx: anytype, control: [4]Point, stroke: Stroke, clip: Clip) ?Placed {
    var points: [cubic_points_max]Point = undefined;
    const c = control;
    const count = flatten_cubic_at(&points, c[0], c[1], c[2], c[3], cx.view_zoom);
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

/// Appends the closed stroke through `points` (absolute, at least three) as `polyline` does,
/// joining the last point to the first with the seam rule (section 4). `Placed` covers the ring
/// with its first point again at the end, so a path area measures the closing segment too.
pub fn polygon(cx: anytype, points: []const Point, stroke: Stroke, clip: Clip) ?Placed {
    assert(points.len >= 3);
    assert(points.len <= polygon_points_max);
    assert(stroke.width > 0);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    if (stroke.dash) |dash| assert_dash(dash);
    const count: u32 = @intCast(points.len);
    var closed: [polygon_points_max + 1]Point = undefined;
    @memcpy(closed[0..count], points);
    closed[count] = points[0];
    const ring = closed[0 .. count + 1];
    const first_end = ring_first_end(ring, stroke.width);
    var chunks: u32 = 1;
    var counted = first_end;
    while (counted < count) : (chunks += 1) counted = chunk_end(ring, counted, stroke.width);
    assert(chunks <= chunk_count(ring, stroke.width));
    if (cx.room(types.Path) < chunks) {
        cx.refuse();
        return null;
    }
    const bounds = bounds_of(points);
    const origin: Point = .{ bounds.x, bounds.y };
    // The ring, its last point before it, and its second point after it (section 4).
    const stored = count + 3;
    const reserved = cx.reserve_points(stored) orelse return null;
    const relative = cx.points[reserved..][0..stored];
    relative[0] = .{ points[count - 1][0] - origin[0], points[count - 1][1] - origin[1] };
    for (relative[1 .. count + 2], ring) |*slot, point| {
        slot.* = .{ point[0] - origin[0], point[1] - origin[1] };
    }
    relative[count + 2] = .{ points[1][0] - origin[0], points[1][1] - origin[1] };
    const first = reserved + 1;
    // The pattern fitted to the ring's stored length, so the closure is seamless (section 4b).
    var fitted = stroke;
    if (stroke.dash) |dash| fitted.dash = fit_to_ring(dash, arc_length(relative[1 .. count + 2]));
    var arc: f64 = 0;
    var start: u32 = 0;
    while (start < count) {
        const end = if (start == 0) first_end else chunk_end(ring, start, stroke.width);
        var instance = chunk_of(ring, start, end, first, origin, fitted, clip, arc);
        if (chunks > 1) {
            if (start == 0) instance.prev = 1;
            if (end == count) instance.next = 1;
        }
        cx.append(types.Path, null, instance) catch |err| switch (err) {
            // Only the first chunk can open a batch: the rest share its layer and type.
            error.BatchFull => {
                assert(start == 0);
                cx.release_points(reserved);
                return null;
            },
            error.PoolFull, error.EdgeNotPositive, error.ClipUnordered => unreachable,
        };
        if (stroke.dash != null) arc += arc_length(relative[1 + start .. 1 + end + 1]);
        start = end;
    }
    return .{ .first = first, .count = count + 1, .bounds = bounds };
}

/// The last point of a closed ring's first chunk: `chunk_end`'s, unless the ring would then be
/// two chunks of which the second is one segment. That segment would be both the first chunk's
/// neighbours, and each seam's rule would judge the other seam's pixels (section 4a), so such a
/// ring is one chunk when it fits and otherwise ends its first chunk a point earlier.
fn ring_first_end(ring: []const Point, width: f32) u32 {
    assert(ring.len >= 4);
    const last: u32 = @intCast(ring.len - 1);
    const end = chunk_end(ring, 0, width);
    if (end + 1 != last) return end;
    if (last <= chunk_segments_max) return last;
    assert(end - 1 >= chunk_segments_min);
    return end - 1;
}

/// The instance of the chunk `points[start..end + 1]`; `first` is the path's first pool index,
/// `origin` the point its stored points are relative to, and `arc` the path's arc length at
/// `start` (section 4b), which a solid stroke ignores.
fn chunk_of(
    points: []const Point,
    start: u32,
    end: u32,
    first: u32,
    origin: Point,
    stroke: Stroke,
    clip: Clip,
    arc: f64,
) types.Path {
    assert(start < end);
    assert(end < points.len);
    const dash = dash_fields(stroke.dash, arc);
    const box = bounds_of(points[start .. end + 1]);
    const pad = stroke.width * 0.5 + aa_pad;
    const x = box.x - pad;
    const y = box.y - pad;
    const instance: types.Path = .{
        .rect = .{ x, y, box.width + 2 * pad, box.height + 2 * pad },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = stroke.color,
        .anchor_x = origin[0] - x,
        .anchor_y = origin[1] - y,
        .width = stroke.width,
        .hover = stroke.hover,
        .first_point = @floatFromInt(first + start),
        .point_count = @floatFromInt(end - start + 1),
        .prev = if (start > 0) 1 else 0,
        .next = if (end + 1 < points.len) 1 else 0,
        .dash_on = dash[0],
        .dash_period = dash[1],
        .dash_phase = dash[2],
        .dash_inverse = dash[3],
    };
    assert(instance.rect[2] > 0);
    assert(instance.rect[3] > 0);
    return instance;
}

/// A chunk's `dash_on`, `dash_period`, `dash_phase`, and `dash_inverse` for the pattern `dash`
/// at arc length `arc` (section 4b): zeros for a solid stroke. The phase is wrapped in `f64`,
/// so the record never holds a large value however long the path or the offset has run.
fn dash_fields(dash: ?Dash, arc: f64) [4]f32 {
    assert(arc >= 0);
    const pattern = dash orelse return .{ 0, 0, 0, 0 };
    const period = pattern.on + pattern.off;
    assert(period > pattern.on);
    const wrapped = @mod(arc + @as(f64, pattern.offset), @as(f64, period));
    var phase: f32 = @floatCast(wrapped);
    // Rounding to f32 can reach the period itself, which is the pattern's start again.
    if (phase >= period) phase = 0;
    assert(phase >= 0);
    assert(phase < period);
    return .{ pattern.on, period, phase, 1 / period };
}

/// The pattern scaled so a whole number of periods, at least one, fits the ring of length
/// `ring_length` (section 4b). A ring of no length keeps the pattern.
fn fit_to_ring(dash: Dash, ring_length: f64) Dash {
    assert(ring_length >= 0);
    assert_dash(dash);
    if (ring_length <= 0) return dash;
    const period: f64 = @as(f64, dash.on) + @as(f64, dash.off);
    const periods = @max(1, @round(ring_length / period));
    const scale = ring_length / (periods * period);
    assert(scale > 0);
    const fitted: Dash = .{
        .on = @floatCast(dash.on * scale),
        .off = @floatCast(dash.off * scale),
        .offset = @floatCast(dash.offset * scale),
    };
    assert(fitted.off > 0);
    return fitted;
}

fn assert_dash(dash: Dash) void {
    assert(dash.on >= 0);
    assert(dash.off > 0);
    assert(std.math.isFinite(dash.offset));
}

/// The length of the polyline through `points`, each segment's length in `f32` as the shader
/// computes it, summed in `f64` (section 4b).
fn arc_length(points: []const Point) f64 {
    assert(points.len >= 2);
    var total: f64 = 0;
    for (points[0 .. points.len - 1], points[1..]) |a, b| total += length(a, b);
    assert(total >= 0);
    return total;
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
    // `types.Path.vertex` writes this pad as the literal `1.0`.
    assert(aa_pad == 1);
    // `types.Path.pixel` writes the seam tie and bias as the literals `8.0e-2` and `2.5e-2`.
    assert(seam_tie == 8.0e-2);
    assert(seam_bias == 2.5e-2);
    // The tie zone holds the side line with room for two chunks' placement to differ.
    assert(seam_tie > 2 * seam_bias + 0.02);
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
    // In a canvas the on-screen length counts: 20 segments at 1 are 40 at 2 and 10 at 0.5.
    try testing.expectEqual(@as(u32, 40), cubic_segments_at(mid[0], mid[1], mid[2], mid[3], 2));
    try testing.expectEqual(@as(u32, 10), cubic_segments_at(mid[0], mid[1], mid[2], mid[3], 0.5));
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

// Locks section 5a: every point a stroke covers (within half the width plus half a device
// pixel, at 1x and 2x) lies inside its chunk's oriented quad, for a sagging cable, a straight
// diagonal, a hairpin folded back on itself, and a chunk whose points all coincide.
test "every chunk's oriented quad contains its stroke" {
    var cable: [cubic_points_max]Point = undefined;
    const control = sagging(.{ 100, 100 }, .{ 800, 700 }, 160);
    const count = flatten_cubic(&cable, control[0], control[1], control[2], control[3]);
    const diagonal = [_]Point{ .{ 0, 0 }, .{ 30, 30 }, .{ 60, 60 }, .{ 90, 90 }, .{ 120, 120 } };
    const hairpin = [_]Point{ .{ 0, 0 }, .{ 40, 0 }, .{ 60, 6 }, .{ 40, 12 }, .{ 0, 12 } };
    const dot = [_]Point{ .{ 5, 5 }, .{ 5, 5 }, .{ 5, 5 } };
    const shapes = [_][]const Point{ cable[0..count], &diagonal, &hairpin, &dot };
    for (shapes) |shape| {
        var start: u32 = 0;
        while (start + 1 < shape.len) {
            const end = chunk_end(shape, start, cable_stroke.width);
            try expect_quad_holds_stroke(shape[start .. end + 1], cable_stroke.width);
            start = end;
        }
    }
}

fn expect_quad_holds_stroke(points: []const Point, width: f32) !void {
    const quad = oriented_quad(points, width);
    const box = bounds_of(points);
    for ([_]f32{ 1, 0.5 }) |pixel_size| {
        const reach = width * 0.5 + 0.5 * pixel_size;
        var y = box.y - reach - 2;
        while (y < box.y + box.height + reach + 2) : (y += 0.25) {
            var x = box.x - reach - 2;
            while (x < box.x + box.width + reach + 2) : (x += 0.25) {
                if (distance_to_polyline(points, x, y) >= reach) continue;
                try testing.expect(quad_contains(quad, .{ x, y }));
            }
        }
    }
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

/// Source-over of every chunk at `(x, y)` with each chunk's fragment moved by `shift` (odd
/// chunks) or `-shift` (even ones): the rasterizer snaps every quad's corners to its own sub-pixel
/// grid, so two chunks interpolate one pixel's position a few thousandths of a pixel apart.
fn composite_shifted(cx: *const TestContext, x: f32, y: f32, pixel_size: f32, shift: Point) f32 {
    var clear: f32 = 1;
    for (cx.items(types.Path), 0..) |*chunk, index| {
        const sign: f32 = if (index % 2 == 0) -1 else 1;
        const at: Point = .{ x + sign * shift[0], y + sign * shift[1] };
        clear *= 1 - chunk_alpha(cx.point_items(), chunk, at[0], at[1], pixel_size);
    }
    return 1 - clear;
}

/// Pixels of `box` (centres at 1x and 2x) where the chunks, moved apart by each of `shifts`,
/// draw other than one stroke of `width` through `points` would: a hole or a double blend.
fn seam_misses(cx: *const TestContext, points: []const Point, width: f32, box: Rect) u32 {
    const shifts = [_]Point{ .{ 2.0e-3, 1.4e-3 }, .{ -2.0e-3, 1.0e-3 }, .{ 5.0e-4, -2.0e-3 } };
    var misses: u32 = 0;
    for ([_]f32{ 1, 0.5 }) |pixel_size| {
        var y = @floor(box.y) + 0.5 * pixel_size;
        while (y < box.y + box.height) : (y += pixel_size) {
            var x = @floor(box.x) + 0.5 * pixel_size;
            while (x < box.x + box.width) : (x += pixel_size) {
                const d = distance_to_polyline(points, x, y);
                const want = std.math.clamp(0.5 - (d - 0.5 * width) / pixel_size, 0, 1);
                for (shifts) |shift| {
                    const got = composite_shifted(cx, x, y, pixel_size, shift);
                    if (@abs(got - want) > 0.01) {
                        misses += 1;
                        break;
                    }
                }
            }
        }
    }
    return misses;
}

// Locks section 4a, Patchwork step 62: a stroke that turns straight back at a chunk seam (the
// middle spike of Tapestry's comb, exactly and with its way down landing 0.05 or 0.4 px off)
// and a quarter circle whose seam lies on its own axis of symmetry draw as one stroke, with
// the chunks' fragments placed up to 4.9e-3 px apart. Under the rule before step 62 (ties to
// the earlier chunk by plain distance) the same check missed 46 pixels: the fold's
// body and cap, and the arc's axis, are ties that each chunk broke on its own placement.
test "a stroke that turns back at a seam draws once" {
    const cx = new_context();
    // Width and how far the way down lands from the way up, as on `examples/vector`'s page 5.
    const rows = [_][2]f32{
        .{ 2, 0 }, .{ 3, 0 }, .{ 5, 0 }, .{ 2.5, 0.05 }, .{ 3, 0.4 }, .{ 5, 0.05 },
    };
    var misses: u32 = 0;
    for (rows) |row| {
        for ([_]f32{ 0, 0.25, 0.5, 0.125 }) |phase| {
            // Arms 0.4 px apart at the foot are more than a tie apart, so their owners meet on
            // a line along the spike; at 0.125 it crosses a column of pixel centres (section 4a).
            if (row[1] > seam_tie and phase == 0.125) continue;
            cx.reset();
            const width = row[0];
            const base = 100 + phase;
            var comb: [9]Point = undefined;
            for (0..3) |spike| {
                const x = 40 + phase + @as(f32, @floatFromInt(spike)) * 40;
                comb[3 * spike] = .{ x, base };
                comb[3 * spike + 1] = .{ x, base - 40 };
                comb[3 * spike + 2] = .{ x + row[1], base };
            }
            const stroke: Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = width, .hover = 0 };
            _ = polyline(cx, &comb, stroke, window).?;
            // The seam is the middle spike's tip, where the stroke turns back.
            try testing.expectEqual(@as(f32, 5), cx.items(types.Path)[0].point_count);
            // The spike from above its cap to above the corner at its foot, where the comb's
            // next arm runs off and the class of section 4 begins.
            const box: Rect = .{
                .x = comb[4][0] - width - 2,
                .y = base - 40 - width - 2,
                .width = 2 * width + 4 + row[1],
                .height = 40 - 1,
            };
            misses += seam_misses(cx, &comb, width, box);
        }
    }
    var arc: [31]Point = undefined;
    for (&arc, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.pi / 60;
        point.* = .{ 106 - 6 * @cos(turn), 106 - 6 * @sin(turn) };
    }
    for ([_]f32{ 1.5, 3 }) |width| {
        cx.reset();
        const stroke: Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = width, .hover = 0 };
        _ = polyline(cx, &arc, stroke, window).?;
        try testing.expectEqual(@as(usize, 2), cx.items(types.Path).len);
        const box: Rect = .{ .x = 98, .y = 98, .width = 10, .height = 10 };
        misses += seam_misses(cx, &arc, width, box);
    }
    try testing.expectEqual(@as(u32, 0), misses);
}

// Locks section 4a's ties in closed rings. A pentagon (Weft play's `shapes` page) used to split
// into a chunk of four segments and one of the closing segment alone, which was then both of the
// first chunk's neighbours: each seam's rule judged the other seam's pixels, and pixels at both
// corners were dropped or doubled (7 under this check before step 62, 3 with only the seam
// pair's tie). Such a ring is now one chunk. A ring of 16 segments, whose greedy split would also
// leave one segment, ends its first chunk a point earlier and draws once with the chunks moved
// apart.
test "a ring never leaves one segment as its second chunk" {
    const cx = new_context();
    const corners = [_]Point{
        .{ 500, 615.85 },    .{ 527.25, 507.55 }, .{ 638.68, 500 }, .{ 680.29, 603.64 },
        .{ 594.58, 675.24 },
    };
    var ring: [corners.len + 1]Point = undefined;
    @memcpy(ring[0..corners.len], &corners);
    ring[corners.len] = corners[0];
    const stroke: Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = 2, .hover = 0 };
    _ = polygon(cx, &corners, stroke, window).?;
    try testing.expectEqual(@as(usize, 1), cx.items(types.Path).len);
    const box: Rect = .{ .x = 496, .y = 496, .width = 188, .height = 184 };
    try testing.expectEqual(@as(u32, 0), seam_misses(cx, &ring, stroke.width, box));
    cx.reset();
    // Sixteen points on a thin horizontal ellipse: bounds small enough that the greedy split
    // takes fifteen segments and leaves the closing one alone.
    var oval: [16]Point = undefined;
    for (&oval, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.tau / 16;
        point.* = .{ 300 + 20 * @cos(turn), 300 + 3 * @sin(turn) };
    }
    var oval_ring: [17]Point = undefined;
    @memcpy(oval_ring[0..16], &oval);
    oval_ring[16] = oval[0];
    try testing.expectEqual(@as(u32, 15), chunk_end(&oval_ring, 0, stroke.width));
    _ = polygon(cx, &oval, stroke, window).?;
    const chunks = cx.items(types.Path);
    try testing.expectEqual(@as(usize, 2), chunks.len);
    try testing.expectEqual(@as(f32, 15), chunks[0].point_count);
    try testing.expectEqual(@as(f32, 3), chunks[1].point_count);
    const oval_box: Rect = .{ .x = 276, .y = 293, .width = 48, .height = 14 };
    try testing.expectEqual(@as(u32, 0), seam_misses(cx, &oval_ring, stroke.width, oval_box));
}

// Locks the closure (section 4): a translucent circle of 64 points splits into several chunks and
// blends once all round, the closure included, where it has no gap either: a point on the stroke
// by the first vertex draws the full alpha. `Placed` measures the closing segment. A triangle is
// one chunk, sets neither flag, and draws its closure too.
test "a polygon closes with the seam rule" {
    const alpha = cable_stroke.color[3];
    const cx = new_context();
    var points: [64]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.tau / 64;
        point.* = .{ 300 + 200 * @cos(turn), 300 + 200 * @sin(turn) };
    }
    const placed = polygon(cx, &points, cable_stroke, window).?;
    try testing.expectEqual(@as(u32, 65), placed.count);
    const chunks = cx.items(types.Path);
    try testing.expect(chunks.len >= 2);
    try testing.expectEqual(@as(f32, 1), chunks[0].prev);
    try testing.expectEqual(@as(f32, 1), chunks[chunks.len - 1].next);
    try testing.expect(composite_max(cx) <= alpha + 1.0e-4);
    for ([_]f32{ -1.25, -0.25, 0.25, 1.25 }) |dy| {
        try testing.expectApproxEqAbs(alpha, composite(cx, 500, 300 + dy, 1), 1.0e-4);
    }
    const stored = cx.point_items()[placed.first..][0..placed.count];
    const ring_end = stored[placed.count - 1];
    try testing.expectEqual(stored[0], ring_end);
    const at = distance_to_polyline(stored, 500 - placed.bounds.x, 300 - placed.bounds.y);
    try testing.expectApproxEqAbs(@as(f32, 0), at, 1.0e-3);
    cx.reset();
    const triangle = [_]Point{ .{ 10, 10 }, .{ 40, 10 }, .{ 10, 40 } };
    _ = polygon(cx, &triangle, cable_stroke, window).?;
    try testing.expectEqual(@as(usize, 1), cx.items(types.Path).len);
    try testing.expectEqual(@as(f32, 0), cx.items(types.Path)[0].prev);
    try testing.expectEqual(@as(f32, 0), cx.items(types.Path)[0].next);
    try testing.expectApproxEqAbs(alpha, composite(cx, 10, 25, 1), 1.0e-4);
    try testing.expect(composite_max(cx) <= alpha + 1.0e-4);
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
        const unit: draw.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
        try cx.append(types.Box, null, .of(unit, clip, .{ .fill = .{ 1, 1, 1, 1 } }));
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

// Locks `polyline_at`: points are stored relative to the given origin (here the lane rect's
// top-left, 20 and 30), raising one sample above the others changes that one stored point
// while the bounds' top-left moves, and the stroke draws where `polyline` draws it.
test "a path anchored at a fixed origin stores points relative to it" {
    const cx = new_context();
    var samples: [8]f32 = @splat(0.5);
    var points: [8]Point = undefined;
    const lane: Rect = .{ .x = 20, .y = 30, .width = 70, .height = 40 };
    plot_points(&points, &samples, lane, .{ 0, 1 });
    try testing.expect(polyline_at(cx, &points, .{ lane.x, lane.y }, cable_stroke, window));
    var before: [8]Point = undefined;
    @memcpy(&before, cx.point_items()[0..8]);
    try testing.expectEqual(Point{ 0, 20 }, before[0]);
    try testing.expectEqual(Point{ 70, 20 }, before[7]);
    const flat = composite(cx, 85, 50, 1);
    cx.reset();
    samples[3] = 1;
    plot_points(&points, &samples, lane, .{ 0, 1 });
    try testing.expect(polyline_at(cx, &points, .{ lane.x, lane.y }, cable_stroke, window));
    var changed: u32 = 0;
    for (before, cx.point_items()[0..8]) |old, new| {
        if (old[0] != new[0] or old[1] != new[1]) changed += 1;
    }
    try testing.expectEqual(@as(u32, 1), changed);
    try testing.expectEqual(Point{ 30, 0 }, cx.point_items()[3]);
    try testing.expectApproxEqAbs(flat, composite(cx, 85, 50, 1), 1.0e-5);
    try testing.expect(flat > 0.4);
}

/// The test stroke of section 4b's tests: width 2, alpha 0.85, dashed as `dash`.
fn dashed_stroke(width: f32, dash: Dash) Stroke {
    return .{ .color = .{ 1, 1, 1, 0.85 }, .width = width, .hover = 0, .dash = dash };
}

// Locks the dashed distance on a straight line of one chunk (section 4b): on 10, off 5, offset 0
// puts on-parts at [0, 10], [15, 25], ..., [90, 100], so a dash's round cap reaches 0.5 px past
// its end at full alpha, half alpha at 1 px, and nothing at 2.5 px in a 5 px gap; the path's own
// start cap is a dash's too. Offset 5 moves the on-parts to [0, 5], [10, 20], [25, 35], ...
test "a straight dashed line leaves gaps with round caps" {
    const cx = new_context();
    // The line runs from (50, 50), off the window clip's edge; probes are along it.
    const line = [_]Point{ .{ 50, 50 }, .{ 150, 50 } };
    _ = polyline(cx, &line, dashed_stroke(2, .{ .on = 10, .off = 5 }), window).?;
    try testing.expectEqual(@as(usize, 1), cx.items(types.Path).len);
    const record = cx.items(types.Path)[0];
    try testing.expectEqual(@as(f32, 10), record.dash_on);
    try testing.expectEqual(@as(f32, 15), record.dash_period);
    try testing.expectEqual(@as(f32, 0), record.dash_phase);
    try testing.expectEqual(@as(f32, 1.0 / 15.0), record.dash_inverse);
    const xs = [_]f32{ 5, 10.5, 11, 11.25, 12.5, -0.5, 20, 99.5 };
    const want = [_]f32{ 0.85, 0.85, 0.425, 0.2125, 0, 0.85, 0.85, 0.85 };
    for (xs, want) |x, alpha| {
        try testing.expectApproxEqAbs(alpha, composite(cx, 50 + x, 50, 1), 1.0e-4);
    }
    cx.reset();
    _ = polyline(cx, &line, dashed_stroke(2, .{ .on = 10, .off = 5, .offset = 5 }), window).?;
    try testing.expectEqual(@as(f32, 5), cx.items(types.Path)[0].dash_phase);
    try testing.expectApproxEqAbs(@as(f32, 0.85), composite(cx, 52.5, 50, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), composite(cx, 57.5, 50, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.85), composite(cx, 65, 50, 1), 1.0e-4);
}

// Locks dots (section 4b): on 0, off 6 at width 4 is a round dot every 6 px, each of radius 2:
// full alpha 1.5 px from a dot's centre, half at 2 px, none at 2.5 and 3 px (between two dots).
test "on zero draws dots off apart" {
    const cx = new_context();
    const line = [_]Point{ .{ 50, 50 }, .{ 80, 50 } };
    _ = polyline(cx, &line, dashed_stroke(4, .{ .on = 0, .off = 6 }), window).?;
    const xs = [_]f32{ 0, 1.5, 2, 2.5, 3, 6, 30 };
    const want = [_]f32{ 0.85, 0.85, 0.425, 0, 0, 0.85, 0.85 };
    for (xs, want) |x, alpha| {
        try testing.expectApproxEqAbs(alpha, composite(cx, 50 + x, 50, 1), 1.0e-4);
    }
}

/// 101 points 1 px apart on y = 50 from x = 50: chunks of 15 segments, seams 15, 30, ..., 90
/// px along.
fn ruler() [101]Point {
    var points: [101]Point = undefined;
    for (&points, 0..) |*point, index| point.* = .{ 50 + @as(f32, @floatFromInt(index)), 50 };
    return points;
}

// Locks the seams of a dashed path (section 4b): a ruler of 1 px segments, on 10, off 5,
// offset 3, has a dash across every seam; the composite of its seven chunks equals one segment
// with the same dash at every half pixel along it, on the axis and 0.75 px off it, and never
// blends twice.
test "a dash across a seam draws once" {
    const cx = new_context();
    const points = ruler();
    const stroke = dashed_stroke(2, .{ .on = 10, .off = 5, .offset = 3 });
    _ = polyline(cx, &points, stroke, window).?;
    try testing.expectEqual(@as(usize, 7), cx.items(types.Path).len);
    const whole = [_]Point{ .{ 50, 50 }, .{ 150, 50 } };
    var x: f32 = 48;
    while (x <= 152) : (x += 0.5) {
        for ([_]f32{ 50, 50.75 }) |y| {
            const got = composite(cx, x, y, 1);
            const d = distance_to_dashes(&whole, 3, 10, 15, x, y);
            const want = 0.85 * std.math.clamp(0.5 - (d - 1), 0, 1);
            try testing.expectApproxEqAbs(want, got, 1.0e-4);
            try testing.expect(got <= 0.85 + 1.0e-4);
        }
    }
}

// Locks the neighbour measure at a seam (section 4b): with offset 10.5 every dash ends 0.5 px
// before a seam. At (15.25, 0) chunk 1 owns the fragment (its own distance 0 against the
// previous segment's 0.25) and reaches the dash ending at 14.5 through that segment: distance
// 0.75, alpha 0.75 of 0.85. Its own nearest on-part starts at 19.5.
test "a cap across a seam is drawn by the owner" {
    const cx = new_context();
    const points = ruler();
    _ = polyline(cx, &points, dashed_stroke(2, .{ .on = 10, .off = 5, .offset = 10.5 }), window).?;
    const chunks = cx.items(types.Path);
    try testing.expectEqual(@as(f32, 10.5), chunks[1].dash_phase);
    try testing.expectEqual(@as(f32, 0), chunk_alpha(cx.point_items(), &chunks[0], 65.25, 50, 1));
    try testing.expectApproxEqAbs(@as(f32, 0.6375), composite(cx, 65.25, 50, 1), 1.0e-4);
    // The stored points are relative to the ruler's start.
    const own = distance_to_dashes(cx.point_items()[15..31], 10.5, 10, 15, 15.25, 0);
    try testing.expectApproxEqAbs(@as(f32, 4.25), own, 1.0e-4);
}

// Locks the arc length (section 4b): a quarter circle of radius 100 in 32 segments of
// 200 sin(pi / 128) = 4.90825 px, on 10, off 10: vertices 1 and 2 (s 4.91 and 9.82) lie in the
// first dash, vertex 3 (14.72) in the gap 4.7 px from either end, vertex 5 (24.54) in the next.
test "dashes follow the arc length" {
    const cx = new_context();
    var arc: [33]Point = undefined;
    for (&arc, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.pi / 64;
        point.* = .{ 300 + 100 * @cos(turn), 300 + 100 * @sin(turn) };
    }
    _ = polyline(cx, &arc, dashed_stroke(2, .{ .on = 10, .off = 10 }), window).?;
    try testing.expect(cx.items(types.Path).len >= 2);
    const want = [_]f32{ 0.85, 0.85, 0.85, 0, 0.85, 0.85 };
    for (want, 0..) |alpha, index| {
        const vertex = arc[index];
        try testing.expectApproxEqAbs(alpha, composite(cx, vertex[0], vertex[1], 1), 1.0e-4);
    }
    // Each chunk's phase is the arc length at its first point, wrapped: 4.90825 px per point.
    for (cx.items(types.Path)) |chunk| {
        const s = chunk.first_point * 200 * @sin(std.math.pi / 128.0);
        try testing.expectApproxEqAbs(@mod(s, 20), chunk.dash_phase, 2.0e-3);
    }
}

// Locks joins (section 4b): an L of width 4 dashed so its corner lies inside a dash draws the
// solid L there, with one round outer corner (alpha 0.3787 at (21.5, -1.5)), and blends once
// over the whole L. A dash that ends at the corner keeps that round cap, and the gap after it
// leaves the second leg's start empty where the solid L is opaque.
test "a dash across a corner is one round join" {
    const cx = new_context();
    const corner = [_]Point{ .{ 50, 50 }, .{ 70, 50 }, .{ 70, 70 } };
    const white: Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = 4, .hover = 0 };
    _ = polyline(cx, &corner, white, window).?;
    // Relative to the L's start at (50, 50).
    const probes = [_]Point{
        .{ 71.5, 48.5 }, .{ 60, 51 }, .{ 71, 55 }, .{ 70, 52.5 }, .{ 72, 55 },
    };
    var solid: [probes.len]f32 = undefined;
    for (probes, 0..) |probe, index| solid[index] = composite(cx, probe[0], probe[1], 1);
    try testing.expectApproxEqAbs(@as(f32, 0.3787), solid[0], 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), solid[3], 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), solid[4], 1.0e-4);
    cx.reset();
    var inside = white;
    inside.dash = .{ .on = 30, .off = 10 };
    _ = polyline(cx, &corner, inside, window).?;
    for (probes[0..3], solid[0..3]) |probe, alpha| {
        try testing.expectApproxEqAbs(alpha, composite(cx, probe[0], probe[1], 1), 1.0e-5);
    }
    try testing.expect(composite_max(cx) <= 1);
    cx.reset();
    var ending = white;
    ending.dash = .{ .on = 20, .off = 10 };
    _ = polyline(cx, &corner, ending, window).?;
    try testing.expectApproxEqAbs(@as(f32, 0.3787), composite(cx, 71.5, 48.5, 1), 1.0e-4);
    try testing.expectEqual(@as(f32, 0), composite(cx, 70, 52.5, 1));
    try testing.expectEqual(@as(f32, 0), composite(cx, 72, 55, 1));
}

// Locks a dashed fold inside a chunk and at a seam (sections 4a and 4b): the hairpin of "every
// chunk's oriented quad contains its stroke" blends once on 6, off 4, and the combs of "a stroke
// that turns back at a seam draws once", dashed, draw as one dashed stroke with the chunks'
// fragments moved apart: ownership is the solid rule's, so the dashes split the same way.
test "a dashed fold draws once" {
    const cx = new_context();
    const hairpin = [_]Point{ .{ 10, 10 }, .{ 50, 10 }, .{ 70, 16 }, .{ 50, 22 }, .{ 10, 22 } };
    _ = polyline(cx, &hairpin, dashed_stroke(2, .{ .on = 6, .off = 4 }), window).?;
    try testing.expect(composite_max(cx) <= 0.85 + 1.0e-4);
    const shifts = [_]Point{ .{ 2.0e-3, 1.4e-3 }, .{ -2.0e-3, 1.0e-3 }, .{ 5.0e-4, -2.0e-3 } };
    var misses: u32 = 0;
    for ([_]f32{ 0, 2.5, 7 }) |offset| {
        for ([_][2]f32{ .{ 2, 0 }, .{ 3, 0.05 }, .{ 5, 0 } }) |row| {
            cx.reset();
            const width = row[0];
            var comb: [9]Point = undefined;
            for (0..3) |spike| {
                const x = 40.25 + @as(f32, @floatFromInt(spike)) * 40;
                comb[3 * spike] = .{ x, 100.25 };
                comb[3 * spike + 1] = .{ x, 60.25 };
                comb[3 * spike + 2] = .{ x + row[1], 100.25 };
            }
            const dash: Dash = .{ .on = 6, .off = 4, .offset = offset };
            _ = polyline(cx, &comb, dashed_stroke(width, dash), window).?;
            try testing.expectEqual(@as(f32, 5), cx.items(types.Path)[0].point_count);
            const phase = @mod(offset, 10);
            // The spike from above its cap to above the corner at its foot, as in step 62's
            // test: at the foot the next arm is two segments from the seam (section 4).
            var y: f32 = 60.25 - width - 2 + 0.25;
            while (y < 100.25 - width - 3) : (y += 0.5) {
                var x: f32 = comb[4][0] - width - 2 + 0.25;
                while (x < comb[4][0] + width + 2 + row[1]) : (x += 0.5) {
                    const d = distance_to_dashes(&comb, phase, 6, 10, x, y);
                    const want = 0.85 * std.math.clamp(0.5 - (d - 0.5 * width), 0, 1);
                    for (shifts) |shift| {
                        if (@abs(composite_shifted(cx, x, y, 1, shift) - want) > 0.01) {
                            misses += 1;
                            break;
                        }
                    }
                }
            }
        }
    }
    try testing.expectEqual(@as(u32, 0), misses);
}

// Locks polygon fitting (section 4b): the 64-gon of radius 200 is 25600 sin(pi / 64) = 1256.13
// px round, so on 10, off 5 fits 84 periods of 14.9540 with dashes of 9.9693 in every record;
// it blends once, and at the closure the first chunk's phase for the segment before it equals
// the last chunk's phase there.
test "a dashed polygon fits its pattern to the ring" {
    const cx = new_context();
    var points: [64]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.tau / 64;
        point.* = .{ 300 + 200 * @cos(turn), 300 + 200 * @sin(turn) };
    }
    _ = polygon(cx, &points, dashed_stroke(2, .{ .on = 10, .off = 5 }), window).?;
    const chunks = cx.items(types.Path);
    try testing.expect(chunks.len >= 2);
    for (chunks) |chunk| {
        try testing.expectApproxEqAbs(@as(f32, 14.9540), chunk.dash_period, 1.0e-3);
        try testing.expectApproxEqAbs(@as(f32, 9.9693), chunk.dash_on, 1.0e-3);
    }
    try testing.expect(composite_max(cx) <= 0.85 + 1.0e-4);
    const stored = cx.point_items();
    const first = chunks[0];
    const head: u32 = @intFromFloat(first.first_point);
    const before = first.dash_phase - length(stored[head - 1], stored[head]);
    const last = chunks[chunks.len - 1];
    const last_head: u32 = @intFromFloat(last.first_point);
    const last_tail = last_head + @as(u32, @intFromFloat(last.point_count)) - 1;
    const own_length: f32 = @floatCast(arc_length(stored[last_head..last_tail]));
    const at_last = last.dash_phase + own_length;
    const period = first.dash_period;
    try testing.expectApproxEqAbs(@mod(at_last, period), @mod(before, period), 1.0e-3);
}

// Locks the wrap (section 4b): an offset of -1,000,000.5, about 4.6 hours of flow at 60 px/s,
// writes the phase 4.5 exactly, since the wrap is computed in f64.
test "a dash phase wraps however far the offset has run" {
    const cx = new_context();
    const line = [_]Point{ .{ 0, 0 }, .{ 100, 0 } };
    const dash: Dash = .{ .on = 10, .off = 5, .offset = -1_000_000.5 };
    _ = polyline(cx, &line, dashed_stroke(2, dash), window).?;
    try testing.expectEqual(@as(f32, 4.5), cx.items(types.Path)[0].dash_phase);
}

// Locks the solid stroke (section 4b): a solid cable writes zeros in all four dash fields, and
// `chunk_alpha` is the solid formula of `min(own, before, after)` bit for bit at every half
// pixel of every chunk's rect.
test "a solid stroke is unchanged by dashes" {
    const cx = new_context();
    _ = cubic(cx, sagging(.{ 100, 100 }, .{ 800, 700 }, 160), cable_stroke, window).?;
    const points = cx.point_items();
    for (cx.items(types.Path)) |*chunk| {
        try testing.expectEqual(@as(f32, 0), chunk.dash_on);
        try testing.expectEqual(@as(f32, 0), chunk.dash_period);
        try testing.expectEqual(@as(f32, 0), chunk.dash_phase);
        try testing.expectEqual(@as(f32, 0), chunk.dash_inverse);
        const head: u32 = @intFromFloat(chunk.first_point);
        const tail: u32 = head + @as(u32, @intFromFloat(chunk.point_count)) - 1;
        var y = chunk.rect[1] + 0.25;
        while (y < chunk.rect[1] + chunk.rect[3]) : (y += 0.5) {
            var x = chunk.rect[0] + 0.25;
            while (x < chunk.rect[0] + chunk.rect[2]) : (x += 0.5) {
                const got = chunk_alpha(points, chunk, x, y, 1);
                if (got == 0) continue;
                const qx = x - chunk.rect[0] - chunk.anchor_x;
                const qy = y - chunk.rect[1] - chunk.anchor_y;
                var near = distance_to_polyline(points[head .. tail + 1], qx, qy);
                if (chunk.prev > 0.5) near = @min(near, segment_at(points, head - 1, qx, qy));
                if (chunk.next > 0.5) near = @min(near, segment_at(points, tail, qx, qy));
                const alpha = std.math.clamp(0.5 - (near - 0.5 * chunk.width) / 1, 0, 1);
                try testing.expectEqual(alpha * chunk.color[3], got);
            }
        }
    }
}

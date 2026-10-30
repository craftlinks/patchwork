//! Scan converter: quadratic flattening and exact signed-area coverage with non-zero winding.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Exact Area Instead of Supersampling
//! The retired offline baker cast a 4 x 4 grid of point samples per pixel, so coverage was
//! quantized to sixteenths and cost 16 winding tests per pixel. This rasterizer computes the
//! exact area of the outline inside each pixel in one pass over the edges (the signed-area
//! accumulation used by font-rs and stb_truetype's v2 rasterizer), so its cost is linear in
//! the edge-row crossings plus one prefix sum per row, and it is accurate to rounding. Test
//! "coverage matches the polygon clipping reference" locks it against an independent
//! per-pixel clipping of the same polygons.
//!
//! ## 2. Coordinate Spaces
//! - Font units: +Y up, origin on the baseline (`ttf.Outline`).
//! - Bitmap pixels: +Y down, origin at the top-left of `Box`. With `scale` in pixels per
//!   font unit, `left = floor(x_min * scale)` and `top = ceil(y_max * scale)`:
//!   ```text
//!   px = x * scale - left
//!   py = top - y * scale
//!   width = ceil(x_max * scale) - left,  height = top - floor(y_min * scale)
//!   ```
//!   `left` is the bitmap's offset right of the pen and `top` its height above the baseline,
//!   both in whole pixels, which is the same box convention the baker used.
//!
//! ## 3. Flattening
//! A quadratic `P0, P1, P2` is replaced by `n` chords at evenly spaced `t`. The largest
//! distance between the curve and a chord is `|P0 - 2 P1 + P2| / (8 n^2)`, so
//! `n = ceil(sqrt(|P0 - 2 P1 + P2| / (8 * tolerance_px)))`, clamped to `[1, segment_cap]`
//! (`quad_chords`, which `draw/fill.zig` shares).
//! Two consecutive off-curve points imply an on-curve point at their midpoint; a contour
//! that starts off-curve starts at an implied point. Horizontal chords are kept so each
//! contour stays a closed polygon (`contour_ends`), and the accumulator skips them.
//!
//! ## 4. Accumulation
//! For each non-horizontal edge, walking its rows from top to bottom, the signed height `d`
//! it covers in a row is split between the cells it crosses: the part of each cell to the
//! right of the edge receives the area, and the cell after the last one receives the rest of
//! `d`, so a running sum along the row yields the signed covered area of every pixel. Rows
//! are independent: each has `width + 2` cells, so carries never cross rows. Coverage is
//! `min(|sum|, 1)`, which implements non-zero winding for overlapping contours, written as
//! `round(coverage * 255)` into the caller's target with its own row stride.
//!
//! ## 5. TigerStyle Invariants
//! - `Raster` is fixed scratch: `edge_cap` edges and `side_cap * (side_cap + 2)` cells.
//! - Flattening returns false on edge overflow, and the caller draws the replacement glyph.

const std = @import("std");
const assert = std.debug.assert;
const ttf = @import("ttf.zig");

/// Largest bitmap edge in pixels. The cache clamps a larger glyph's size to fit.
pub const side_cap: u32 = 160;
/// Edges one flattened outline may hold.
pub const edge_cap: u32 = 4096;
/// Largest distance, in pixels, between a curve and its chords.
pub const tolerance_px: f32 = 0.2;
/// Chords one quadratic curve may become.
pub const segment_cap: u32 = 16;

/// A straight edge in bitmap pixels.
pub const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// The pixel box of a glyph bitmap; see the module guide, section 2.
pub const Box = struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
};

pub const Raster = struct {
    edges: [edge_cap]Edge,
    edge_count: u32,
    /// One past the last edge of each contour, in order.
    contour_ends: [ttf.contour_cap]u32,
    contour_count: u32,
    cells: [side_cap * (side_cap + 2)]f32,
};

/// The bitmap box of `outline` at `scale` pixels per font unit.
pub fn box_of(outline: *const ttf.Outline, scale: f32) Box {
    assert(outline.point_count >= 1);
    assert(scale > 0);
    const left = @floor(outline.x_min * scale);
    const right = @ceil(outline.x_max * scale);
    const bottom = @floor(outline.y_min * scale);
    const top = @ceil(outline.y_max * scale);
    const box: Box = .{
        .left = @intFromFloat(left),
        .top = @intFromFloat(top),
        .width = @intFromFloat(right - left),
        .height = @intFromFloat(top - bottom),
    };
    assert(box.width <= 1 << 16);
    assert(box.height <= 1 << 16);
    return box;
}

/// Flattens `outline` into `raster.edges` in the pixel space of `box`. False when the edges
/// would exceed `edge_cap`.
pub fn flatten(raster: *Raster, outline: *const ttf.Outline, scale: f32, box: Box) bool {
    assert(outline.contour_count >= 1);
    assert(scale > 0);
    raster.edge_count = 0;
    raster.contour_count = 0;
    const transform: Transform = .{
        .scale = scale,
        .left = @floatFromInt(box.left),
        .top = @floatFromInt(box.top),
    };
    var start: u32 = 0;
    for (outline.ends[0..outline.contour_count]) |end_index| {
        const end: u32 = end_index;
        assert(end >= start);
        if (!flatten_contour(raster, outline, start, end + 1, transform)) {
            return false;
        }
        raster.contour_ends[raster.contour_count] = raster.edge_count;
        raster.contour_count += 1;
        start = end + 1;
    }
    assert(start == outline.point_count);
    assert(raster.contour_count == outline.contour_count);
    return true;
}

const Transform = struct {
    scale: f32,
    left: f32,
    top: f32,
};

const Point = struct {
    x: f32,
    y: f32,
};

fn pixel_of(outline: *const ttf.Outline, index: u32, transform: Transform) Point {
    assert(index < outline.point_count);
    return .{
        .x = outline.x[index] * transform.scale - transform.left,
        .y = transform.top - outline.y[index] * transform.scale,
    };
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

/// Flattens the points `[start, end)` as one closed contour.
fn flatten_contour(
    raster: *Raster,
    outline: *const ttf.Outline,
    start: u32,
    end: u32,
    transform: Transform,
) bool {
    assert(start < end);
    const count = end - start;
    // Begin on an on-curve point, or on the midpoint of the first two off-curve points.
    var first: u32 = 0;
    while (first < count) : (first += 1) {
        if (outline.on[start + first]) break;
    }
    const origin: Point = if (first < count)
        pixel_of(outline, start + first, transform)
    else
        midpoint(pixel_of(outline, start, transform), pixel_of(outline, start + 1, transform));
    if (first == count) first = 0;
    var pen = origin;
    var control: ?Point = null;
    var step: u32 = 1;
    while (step <= count) : (step += 1) {
        const index = start + (first + step) % count;
        const closing = step == count;
        const point = if (closing) origin else pixel_of(outline, index, transform);
        const on = closing or outline.on[index];
        if (on) {
            const ok = if (control) |c| add_quad(raster, pen, c, point) else add_edge(
                raster,
                pen,
                point,
            );
            if (!ok) return false;
            pen = point;
            control = null;
        } else {
            if (control) |c| {
                const implied = midpoint(c, point);
                if (!add_quad(raster, pen, c, implied)) return false;
                pen = implied;
            }
            control = point;
        }
    }
    assert(control == null);
    return true;
}

/// Chords a quadratic of `deviation = |P0 - 2 P1 + P2|` pixels flattens to (section 3).
pub fn quad_chords(deviation: f32) u32 {
    assert(deviation >= 0);
    const wanted = @ceil(@sqrt(deviation / (8 * tolerance_px)));
    const count: u32 = @intFromFloat(std.math.clamp(wanted, 1, @as(f32, segment_cap)));
    assert(count >= 1);
    assert(count <= segment_cap);
    return count;
}

fn add_quad(raster: *Raster, p0: Point, p1: Point, p2: Point) bool {
    const ddx = p0.x - 2 * p1.x + p2.x;
    const ddy = p0.y - 2 * p1.y + p2.y;
    const count = quad_chords(@sqrt(ddx * ddx + ddy * ddy));
    const count_f: f32 = @floatFromInt(count);
    var previous = p0;
    var step: u32 = 1;
    while (step <= count) : (step += 1) {
        const t = @as(f32, @floatFromInt(step)) / count_f;
        const u = 1 - t;
        const point: Point = if (step == count) p2 else .{
            .x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            .y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
        };
        if (!add_edge(raster, previous, point)) return false;
        previous = point;
    }
    return true;
}

fn add_edge(raster: *Raster, a: Point, b: Point) bool {
    if (raster.edge_count == edge_cap) {
        return false;
    }
    raster.edges[raster.edge_count] = .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y };
    raster.edge_count += 1;
    assert(raster.edge_count <= edge_cap);
    return true;
}

/// Accumulates `raster.edges` over `box` and writes coverage into `target`, whose rows are
/// `stride` bytes apart. See the module guide, section 4.
pub fn fill(raster: *Raster, box: Box, target: []u8, stride: u32) void {
    assert(box.width >= 1);
    assert(box.height >= 1);
    assert(box.width <= side_cap);
    assert(box.height <= side_cap);
    assert(stride >= box.width);
    assert(target.len >= stride * (box.height - 1) + box.width);
    const row_cells = box.width + 2;
    @memset(raster.cells[0 .. row_cells * box.height], 0);
    for (raster.edges[0..raster.edge_count]) |edge| {
        accumulate(&raster.cells, row_cells, box.width, box.height, edge);
    }
    var row: u32 = 0;
    while (row < box.height) : (row += 1) {
        const cells = raster.cells[row * row_cells ..][0..box.width];
        const out = target[row * stride ..][0..box.width];
        var sum: f32 = 0;
        for (cells, out) |cell, *texel| {
            sum += cell;
            const coverage = @min(@abs(sum), 1.0);
            texel.* = @intFromFloat(coverage * 255.0 + 0.5);
        }
    }
    assert(row == box.height);
}

/// Adds one edge's signed area to the cells of the rows it crosses. A hot loop over
/// primitive arguments, so `cells` and the edge stay in registers.
fn accumulate(cells: []f32, row_cells: u32, width: u32, height: u32, edge: Edge) void {
    if (edge.y0 == edge.y1) {
        return;
    }
    const down = edge.y1 > edge.y0;
    const direction: f32 = if (down) 1 else -1;
    const x_top = if (down) edge.x0 else edge.x1;
    const y_top = if (down) edge.y0 else edge.y1;
    const x_bottom = if (down) edge.x1 else edge.x0;
    const y_bottom = if (down) edge.y1 else edge.y0;
    const height_f: f32 = @floatFromInt(height);
    const width_f: f32 = @floatFromInt(width);
    const slope = (x_bottom - x_top) / (y_bottom - y_top);
    const row_first: u32 = @intFromFloat(@max(0, @floor(y_top)));
    const row_end: u32 = @intFromFloat(@min(height_f, @max(0, @ceil(y_bottom))));
    var row = row_first;
    while (row < row_end) : (row += 1) {
        const row_top: f32 = @floatFromInt(row);
        const y_a = @max(row_top, y_top);
        const y_b = @min(row_top + 1, y_bottom);
        if (y_b <= y_a) continue;
        const x_a = std.math.clamp(x_top + (y_a - y_top) * slope, 0, width_f);
        const x_b = std.math.clamp(x_top + (y_b - y_top) * slope, 0, width_f);
        const line = cells[row * row_cells ..][0..row_cells];
        accumulate_row(line, x_a, x_b, (y_b - y_a) * direction);
    }
}

/// Splits the signed height `d` of one edge piece between `x_a` and `x_b` across the cells
/// of one row; see the module guide, section 4.
fn accumulate_row(line: []f32, x_a: f32, x_b: f32, d: f32) void {
    const x_left = @min(x_a, x_b);
    const x_right = @max(x_a, x_b);
    const left_floor = @floor(x_left);
    const left_index: u32 = @intFromFloat(left_floor);
    const right_ceil = @ceil(x_right);
    const right_index: u32 = @intFromFloat(right_ceil);
    assert(right_index + 1 <= line.len);
    if (right_index <= left_index + 1) {
        // The piece stays within one cell: its area right of the edge is d * (1 - mid).
        const middle = (x_a + x_b) * 0.5 - left_floor;
        line[left_index] += d * (1 - middle);
        line[left_index + 1] += d * middle;
        return;
    }
    const inverse = 1 / (x_right - x_left);
    const left_fraction = x_left - left_floor;
    const area_first = 0.5 * inverse * (1 - left_fraction) * (1 - left_fraction);
    const right_fraction = x_right - right_ceil + 1;
    const area_last = 0.5 * inverse * right_fraction * right_fraction;
    line[left_index] += d * area_first;
    if (right_index == left_index + 2) {
        line[left_index + 1] += d * (1 - area_first - area_last);
    } else {
        const area_second = inverse * (1.5 - left_fraction);
        line[left_index + 1] += d * (area_second - area_first);
        var index = left_index + 2;
        while (index < right_index - 1) : (index += 1) {
            line[index] += d * inverse;
        }
        const spans: f32 = @floatFromInt(right_index - left_index - 3);
        const area_before_last = area_second + spans * inverse;
        line[right_index - 1] += d * (1 - area_before_last - area_last);
    }
    line[right_index] += d * area_last;
}

comptime {
    assert(side_cap * (side_cap + 2) * @sizeOf(f32) <= 128 * 1024);
    assert(segment_cap >= 1);
    assert(edge_cap >= ttf.point_cap);
}

const testing = std.testing;
const text = @import("../text.zig");

/// Static scratch for the tests, so the outline, edges, cells, and bitmaps stay off the stack.
const fixture = struct {
    var outline: ttf.Outline = undefined;
    var raster: Raster = undefined;
    var bitmap: [side_cap * side_cap]u8 = undefined;
    var reference: [side_cap * side_cap]u8 = undefined;
    var clip_in: [edge_cap + 16]Point = undefined;
    var clip_out: [edge_cap + 16]Point = undefined;
};

/// Rasterizes `codepoint` of `face` at `ppem` pixels per em into `fixture.bitmap`, rows
/// `box.width` apart, and returns the box.
fn rasterize_test_glyph(face: text.Face, codepoint: u21, ppem: f32) Box {
    const font = text.font_of(face);
    const id = ttf.glyph_id(font, codepoint);
    assert(ttf.load(font, id, &fixture.outline) == .ready);
    const scale = ppem / @as(f32, @floatFromInt(font.units_per_em));
    const box = box_of(&fixture.outline, scale);
    assert(flatten(&fixture.raster, &fixture.outline, scale, box));
    fill(&fixture.raster, box, &fixture.bitmap, box.width);
    return box;
}

/// The reference coverage of pixel `(x, y)`: each flattened contour is clipped to the pixel
/// square (Sutherland-Hodgman), and the signed areas are summed, so overlapping contours
/// follow non-zero winding exactly as the accumulator's `min(|sum|, 1)` does.
fn reference_coverage(x: f32, y: f32) u8 {
    var sum: f32 = 0;
    var first: u32 = 0;
    for (fixture.raster.contour_ends[0..fixture.raster.contour_count]) |end| {
        var count: u32 = 0;
        for (fixture.raster.edges[first..end]) |edge| {
            fixture.clip_in[count] = .{ .x = edge.x0, .y = edge.y0 };
            count += 1;
        }
        count = clip_polygon(count, .{ .axis_x = true, .bound = x, .keep_above = true });
        count = clip_polygon(count, .{ .axis_x = true, .bound = x + 1, .keep_above = false });
        count = clip_polygon(count, .{ .axis_x = false, .bound = y, .keep_above = true });
        count = clip_polygon(count, .{ .axis_x = false, .bound = y + 1, .keep_above = false });
        sum += polygon_area(fixture.clip_in[0..count]);
        first = end;
    }
    const coverage = @min(@abs(sum), 1.0);
    return @intFromFloat(coverage * 255.0 + 0.5);
}

const Plane = struct {
    axis_x: bool,
    bound: f32,
    keep_above: bool,
};

/// Clips the polygon in `fixture.clip_in` by one half-plane, writing the result back there.
fn clip_polygon(count: u32, plane: Plane) u32 {
    var out: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const a = fixture.clip_in[if (index == 0) count - 1 else index - 1];
        const b = fixture.clip_in[index];
        const a_in = inside(a, plane);
        const b_in = inside(b, plane);
        if (a_in != b_in) {
            fixture.clip_out[out] = crossing(a, b, plane);
            out += 1;
        }
        if (b_in) {
            fixture.clip_out[out] = b;
            out += 1;
        }
    }
    @memcpy(fixture.clip_in[0..out], fixture.clip_out[0..out]);
    return out;
}

fn inside(point: Point, plane: Plane) bool {
    const value = if (plane.axis_x) point.x else point.y;
    return if (plane.keep_above) value >= plane.bound else value <= plane.bound;
}

fn crossing(a: Point, b: Point, plane: Plane) Point {
    if (plane.axis_x) {
        const t = (plane.bound - a.x) / (b.x - a.x);
        return .{ .x = plane.bound, .y = a.y + t * (b.y - a.y) };
    }
    const t = (plane.bound - a.y) / (b.y - a.y);
    return .{ .x = a.x + t * (b.x - a.x), .y = plane.bound };
}

fn polygon_area(points: []const Point) f32 {
    if (points.len < 3) return 0;
    var twice: f32 = 0;
    var previous = points[points.len - 1];
    for (points) |point| {
        twice += previous.x * point.y - point.x * previous.y;
        previous = point;
    }
    return twice * 0.5;
}

/// Asserts every texel of the last rasterized glyph is within one level of the reference.
fn expect_matches_reference(box: Box) !void {
    var row: u32 = 0;
    while (row < box.height) : (row += 1) {
        var column: u32 = 0;
        while (column < box.width) : (column += 1) {
            const expected = reference_coverage(@floatFromInt(column), @floatFromInt(row));
            const actual = fixture.bitmap[row * box.width + column];
            const difference = @max(expected, actual) - @min(expected, actual);
            try testing.expect(difference <= 1);
        }
    }
}

// Locks the rasterizer against an independent per-pixel polygon clipping of the same
// flattened contours: within 1/255 per texel on "H" (straight edges) and "o" (two curved
// contours with opposite winding) at 32 px per em, and on "@" at 48 px per em.
test "coverage matches the polygon clipping reference" {
    const h = rasterize_test_glyph(.sans, 'H', 32);
    try testing.expectEqual(@as(u32, 18), h.width);
    try testing.expectEqual(@as(u32, 23), h.height);
    try expect_matches_reference(h);
    try expect_matches_reference(rasterize_test_glyph(.sans, 'o', 32));
    try expect_matches_reference(rasterize_test_glyph(.sans_bold, '@', 48));
}

// Locks the flattening bound: a curve becomes at most `segment_cap` chords, and a flat
// quadratic (collinear control point) one chord.
test "flattening uses one chord for a straight quadratic and caps a tight one" {
    fixture.raster.edge_count = 0;
    const a: Point = .{ .x = 0, .y = 0 };
    try testing.expect(add_quad(&fixture.raster, a, .{ .x = 5, .y = 5 }, .{ .x = 10, .y = 10 }));
    try testing.expectEqual(@as(u32, 1), fixture.raster.edge_count);
    fixture.raster.edge_count = 0;
    const far: Point = .{ .x = 4000, .y = 0 };
    try testing.expect(add_quad(&fixture.raster, a, far, .{ .x = 0, .y = 10 }));
    try testing.expectEqual(segment_cap, fixture.raster.edge_count);
}

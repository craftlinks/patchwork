//! Filled shapes: closed contours flattened, cut into bands, and covered by exact area on the
//! GPU, with the `Fill` draw type, its CPU twins, and the appender.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why on the GPU
//! Every shape with an inside needs a fill: a sector, an arrowhead, the region under a curve, a
//! glyph outline. A CPU raster into a texture would rasterize and upload a shape that morphs on
//! every frame, so `Fill` follows `Path`: an instance per chunk of the shape, whose fragment
//! loops over the chunk's segments in the point pool.
//! ```text
//! Builder: move_to, line_to, quad_to, cubic_to, close -> flattened closed contours
//! append:  bounds -> bands (section 3) -> room checked -> points -> one Fill per band
//! GPU:     sum over the band's segments of the signed area left of each, inside the pixel
//!          (section 4), then alpha by the rule
//! ```
//!
//! ## 2. Flattening
//! A quadratic gets `raster.quad_chords(deviation * zoom * k)` chords, where `k` is
//! `raster.tolerance_px / tolerance_px` (4: the rasterizer's rule at a quarter of its tolerance),
//! and a cubic gets `path.cubic_segments_at(.., zoom)`, the stroke's rule, both at even `t`, so
//! chords follow the on-screen size inside a canvas (`cx.view_zoom`). `Builder.outline` walks a
//! font outline as `raster.flatten` does, with finer chords than the atlas glyph, whose 0.2 px
//! tolerance shows facets from a few hundred pixels up. A contour is closed by `close`, by the
//! next `move_to`, or by `append`. Over `segment_cap` segments the Builder sets `overflowed`, and
//! `append` refuses the whole shape and counts it.
//!
//! ## 2a. Transforms
//! `Builder.transform` maps every point a call takes, control points included, before any
//! flattening. An affine map keeps a Bézier a Bézier, so the chord count follows the shape's
//! on-screen size: a quadratic scaled by 4 takes twice the chords (the count goes with the
//! square root of the deviation), a rotation takes the same number. The pen and the contour's
//! start are kept transformed, and the transform changes between contours, never inside one.
//!
//! ## 3. Bands
//! A fragment's cost is its segment count, so a shape is cut into horizontal bands, each listing
//! only the segments that meet its y-range padded by `aa_pad`:
//! ```text
//! start with one band over the bounds
//! halve a band at its middle while it lists more than segments_max segments
//! a band under band_height_min still over the cap refuses the whole shape
//! ```
//! Horizontal segments have no area and are in no list. Every segment that can reach a pixel in
//! a band meets the band's padded range, so a band's own list gives the exact coverage: nothing
//! passes between bands, and a band with no segments is empty and draws no instance. Points are 2
//! per segment per band it meets: segment `i` of a band is `points[first + 2i]` to
//! `points[first + 2i + 1]`. Only the outer top and bottom are padded: neighbouring bands share
//! one edge, and the rasterizer's fill rule draws each pixel once, so a translucent shape has no
//! stripe. For the two quads to meet exactly, every band edge sits on a `1 / band_grid` grid, where
//! `rect.y + rect.height` is exact in `f32`. A `Context.shift` off that grid can leave them an ulp
//! apart, far less than the rasterizer's sub-pixel snap and never on a pixel centre.
//!
//! ## 4. Coverage
//! A fragment measures the pixel it stands for, not a sample. With `q` the pixel's centre and
//! coordinates in pixels from `q`, each segment is cut to the pixel's rows, and the part of the
//! pixel left of it, in those rows, counts with the segment's direction:
//! ```text
//! lo, hi = the segment's ends by y;  y0, y1 = max(lo.y, -1/2), min(hi.y, 1/2);  skip if y1 <= y0
//! u(y)   = the segment's x at y, + 1/2: 0 at the pixel's left edge, 1 at its right
//! left   = mean over y0..y1 of clamp(u, 0, 1)  = (R(u1) - R(u0)) / (u1 - u0)
//!          R(u) = clamp(u, 0, 1)^2 / 2 + max(u - 1, 0)
//! sum   += +-(y1 - y0) * left                   + when the segment runs down
//! ```
//! `sum` is the winding of the whole pixel to the right: an integer in the interior, between two
//! integers on an edge. Then coverage is `min(|sum|, 1)` for non-zero, as `raster.zig` writes it,
//! and `1 - |1 - (|sum| mod 2)|` for even-odd. This is the exact area of each pixel for a simple
//! shape, corners and hairlines included. An edge between two inside regions (winding 1 and 2, the
//! arms of a star) changes nothing, where a distance to the nearest segment would draw a line
//! along it. Regions of opposite winding that meet inside one pixel stay approximate: the rule
//! sees the pixel's mean winding, not its parts, as `raster.zig` does.
//!
//! ## 5. Coordinates
//! As `Path` (`draw/path.zig`, section 5): points are relative to the shape's origin, the top-left
//! of its bounds, and each band carries `anchor = origin - rect.xy`, so a container's shift moves
//! the shape with its rects.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: a `Builder` is a value of `segment_cap` segments, bands are a stack array of
//!   `bands_max`, and the splitting stack holds `split_depth_max` ranges, so nothing recurses.
//! - Appends are atomic: the plan is made and the pool's room and the points' room are checked
//!   before anything is written; a refused first instance takes the points back. Every refusal
//!   is counted in `overflow_count`.
//! - A fragment loops over at most `segments_max` segments.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const path = @import("path.zig");
const pools = @import("pools.zig");
const raster = @import("../text/raster.zig");
const textures = @import("textures.zig");
const ttf = @import("../text/ttf.zig");

pub const Point = pools.Point;
pub const Rect = draw.Rect;
pub const Clip = draw.Clip;

/// Segments one band lists: no glyph from U+0021 to U+017F is refused at this cap in six faces
/// from 16 to 2,000 px (measured on the step page).
pub const segments_max: u32 = 48;

/// Segments one `Builder` holds: the longest of those glyphs flattens to 380.
pub const segment_cap: u32 = 1024;

/// Most bands one shape makes. The most of those glyphs make is 14.
pub const bands_max: u32 = 128;

/// A band this tall or less is not split: logical pixels.
pub const band_height_min: f32 = 1;

/// Band edges are multiples of `1 / band_grid` logical pixels (section 3).
pub const band_grid: f32 = 256;

/// Padding that holds the antialiased edge, as `path.aa_pad`.
pub const aa_pad: f32 = path.aa_pad;

/// Ranges waiting on the splitting stack: one per halving on the way down, and the band.
const split_depth_max: u32 = 24;

/// Flattening tolerance of a `Builder`, in device pixels: a quarter of `raster.tolerance_px`,
/// which keeps chords of a glyph facet-free at 2,000 px with no shape refused.
pub const tolerance_px: f32 = 0.05;

/// A 2 x 3 affine map of the plane, `+y` down (module guide, section 2a).
pub const Transform = struct {
    /// `x' = a x + c y + tx`, `y' = b x + d y + ty`.
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,

    pub const identity: Transform = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };

    /// Moves every point by `x`, `y`.
    pub fn translation(x: f32, y: f32) Transform {
        return .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = x, .ty = y };
    }

    /// Scales about the origin by `sx` across and `sy` down.
    pub fn scaling(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .b = 0, .c = 0, .d = sy, .tx = 0, .ty = 0 };
    }

    /// Positive turns clockwise on screen, with `+y` down.
    pub fn rotation(radians: f32) Transform {
        const cosine = @cos(radians);
        const sine = @sin(radians);
        return .{ .a = cosine, .b = sine, .c = -sine, .d = cosine, .tx = 0, .ty = 0 };
    }

    /// `first`, then `second` on its result.
    pub fn then(first: Transform, second: Transform) Transform {
        return .{
            .a = second.a * first.a + second.c * first.b,
            .b = second.b * first.a + second.d * first.b,
            .c = second.a * first.c + second.c * first.d,
            .d = second.b * first.c + second.d * first.d,
            .tx = second.a * first.tx + second.c * first.ty + second.tx,
            .ty = second.b * first.tx + second.d * first.ty + second.ty,
        };
    }

    /// `inner` with `pivot` held still.
    pub fn around(pivot: Point, inner: Transform) Transform {
        const result = translation(-pivot[0], -pivot[1]).then(inner)
            .then(translation(pivot[0], pivot[1]));
        assert(result.a == result.a);
        return result;
    }

    /// `point` mapped by the transform.
    pub fn apply(self: Transform, point: Point) Point {
        return .{
            self.a * point[0] + self.c * point[1] + self.tx,
            self.b * point[0] + self.d * point[1] + self.ty,
        };
    }
};

/// Which regions of the winding are inside.
pub const Rule = enum(u8) {
    non_zero,
    even_odd,
};

/// A filled band of a shape from the point pool. See the module guide, sections 3 and 4.
pub const Fill = extern struct {
    /// The band's bounds, padded by `aa_pad` on x and at the shape's outer top and bottom only.
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    /// `origin - rect.xy` (section 5).
    anchor_x: f32,
    anchor_y: f32,
    first_point: f32,
    /// Twice the band's segments.
    point_count: f32,
    /// 0 non-zero, 1 even-odd.
    rule: f32,
    /// The mix toward `theme.lighten`.
    hover: f32,
    pad0: f32,
    pad1: f32,

    pub const texture: ?textures.Format = null;
    pub const reads_points: bool = true;
    // `fwidth` runs before the loop, whose bound is instance data, so the derivative stays in
    // uniform control flow (prelude, section 3). CPU twin: `signed_area`, `band_alpha`.
    pub const pixel: []const u8 =
        \\fn fill_ramp(u: f32) -> f32 {
        \\    let c = clamp(u, 0.0, 1.0);
        \\    return 0.5 * c * c + max(u - 1.0, 0.0);
        \\}
        \\
        \\fn fill_area(a: vec2<f32>, b: vec2<f32>) -> f32 {
        \\    let down = b.y > a.y;
        \\    let lo = select(b, a, down);
        \\    let hi = select(a, b, down);
        \\    let y0 = max(lo.y, -0.5);
        \\    let y1 = min(hi.y, 0.5);
        \\    if (y1 <= y0) {
        \\        return 0.0;
        \\    }
        \\    let slope = (hi.x - lo.x) / (hi.y - lo.y);
        \\    let u0 = lo.x + (y0 - lo.y) * slope + 0.5;
        \\    let u1 = lo.x + (y1 - lo.y) * slope + 0.5;
        \\    var left = 0.0;
        \\    if (u0 >= 1.0 && u1 >= 1.0) {
        \\        left = 1.0;
        \\    } else if (u0 > 0.0 || u1 > 0.0) {
        \\        if (abs(u1 - u0) < 1.0e-3) {
        \\            left = clamp(0.5 * (u0 + u1), 0.0, 1.0);
        \\        } else {
        \\            left = (fill_ramp(u1) - fill_ramp(u0)) / (u1 - u0);
        \\        }
        \\    }
        \\    let area = (y1 - y0) * left;
        \\    return select(-area, area, down);
        \\}
        \\
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let pixel_size = max(fwidth(px.local.x), 1.0e-5);
        \\    let q = px.local - vec2<f32>(px.anchor_x, px.anchor_y);
        \\    let first = u32(px.first_point + 0.5);
        \\    let count = u32(px.point_count + 0.5) / 2u;
        \\    var sum = 0.0;
        \\    for (var i = 0u; i < count; i = i + 1u) {
        \\        let a = (points[first + 2u * i] - q) / pixel_size;
        \\        let b = (points[first + 2u * i + 1u] - q) / pixel_size;
        \\        sum = sum + fill_area(a, b);
        \\    }
        \\    let w = abs(sum);
        \\    let odd = 1.0 - abs(1.0 - (w - 2.0 * floor(0.5 * w)));
        \\    let cover = select(min(w, 1.0), odd, px.rule > 0.5);
        \\    let rgb = mix(px.color.rgb, frame.theme.lighten.rgb, px.hover);
        \\    return vec4<f32>(rgb, px.color.a * cover);
        \\}
        \\
    ;
};

/// One straight piece of a contour, in the Builder's absolute coordinates.
pub const Edge = struct {
    a: Point,
    b: Point,
};

/// Flattened closed contours (module guide, section 2). It is `segment_cap` segments on the
/// stack: 16 KiB.
pub const Builder = struct {
    edges: [segment_cap]Edge,
    count: u32,
    /// A segment did not fit, so `append` refuses this shape.
    overflowed: bool,
    /// Screen pixels per logical pixel: `cx.view_zoom` inside a canvas, 1 elsewhere.
    zoom: f32,
    /// Applied to every point a call takes (module guide, section 2a). `pen` and `start` are
    /// already transformed.
    transform: Transform,
    pen: Point,
    start: Point,
    open: bool,

    /// An empty Builder whose chords suit `zoom` screen pixels per logical pixel: pass
    /// `cx.drawing().text.device_scale()` (the display scale times the canvas zoom).
    pub fn init(zoom: f32) Builder {
        assert(zoom > 0);
        const builder: Builder = .{
            .edges = undefined,
            .count = 0,
            .overflowed = false,
            .zoom = zoom,
            .transform = .identity,
            .pen = .{ 0, 0 },
            .start = .{ 0, 0 },
            .open = false,
        };
        assert(!builder.open);
        return builder;
    }

    /// Empties the Builder to build again at the same zoom, with the identity transform.
    pub fn reset(self: *Builder) void {
        self.count = 0;
        self.overflowed = false;
        self.open = false;
        self.transform = .identity;
        assert(self.count == 0);
    }

    /// Sets the transform for the contours that follow. Only between contours.
    pub fn set_transform(self: *Builder, transform: Transform) void {
        assert(!self.open);
        assert(transform.a == transform.a and transform.d == transform.d);
        self.transform = transform;
    }

    /// Begins a contour at `point`, closing the one before.
    pub fn move_to(self: *Builder, point: Point) void {
        self.close();
        const placed_point = self.transform.apply(point);
        self.pen = placed_point;
        self.start = placed_point;
        self.open = true;
    }

    /// A straight segment from the pen to `point`.
    pub fn line_to(self: *Builder, point: Point) void {
        assert(self.open);
        self.add(self.transform.apply(point));
    }

    /// A quadratic from the pen through `control` to `end`.
    pub fn quad_to(self: *Builder, source_control: Point, source_end: Point) void {
        assert(self.open);
        const control = self.transform.apply(source_control);
        const end = self.transform.apply(source_end);
        const p0 = self.pen;
        const ddx = p0[0] - 2 * control[0] + end[0];
        const ddy = p0[1] - 2 * control[1] + end[1];
        const deviation = @sqrt(ddx * ddx + ddy * ddy);
        const finer = raster.tolerance_px / tolerance_px;
        const chords = raster.quad_chords(deviation * self.zoom * finer);
        const chords_f: f32 = @floatFromInt(chords);
        var step: u32 = 1;
        while (step < chords) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / chords_f;
            const u = 1 - t;
            self.add(.{
                u * u * p0[0] + 2 * u * t * control[0] + t * t * end[0],
                u * u * p0[1] + 2 * u * t * control[1] + t * t * end[1],
            });
        }
        self.add(end);
    }

    /// A cubic from the pen through `control` to `end`.
    pub fn cubic_to(self: *Builder, control: [2]Point, end: Point) void {
        assert(self.open);
        var points: [path.cubic_points_max]Point = undefined;
        const count = path.flatten_cubic_at(
            &points,
            self.pen,
            self.transform.apply(control[0]),
            self.transform.apply(control[1]),
            self.transform.apply(end),
            self.zoom,
        );
        assert(count >= 2);
        for (points[1..count]) |point| self.add(point);
    }

    /// Closes the open contour with a line to its start, if one is open.
    pub fn close(self: *Builder) void {
        if (!self.open) return;
        self.add(self.start);
        self.open = false;
        assert(!self.open);
    }

    /// A closed polygon through `points`, as its own contour.
    pub fn polygon(self: *Builder, points: []const Point) void {
        assert(points.len >= 3);
        self.move_to(points[0]);
        for (points[1..]) |point| self.line_to(point);
        self.close();
    }

    /// Adds every contour of `outline` at `scale` pixels per font unit with the pen at `pen`,
    /// `+y` down (module guide, section 2). The walk is `raster.flatten`'s.
    pub fn outline(self: *Builder, source: *const ttf.Outline, scale: f32, pen: Point) void {
        assert(source.contour_count >= 1);
        assert(scale > 0);
        var start: u32 = 0;
        for (source.ends[0..source.contour_count]) |end_index| {
            const end: u32 = end_index;
            assert(end >= start);
            self.outline_contour(source, start, end + 1, scale, pen);
            start = end + 1;
        }
        assert(start == source.point_count);
        self.close();
    }

    /// The points `[start, end)` as one closed contour, beginning on an on-curve point or on the
    /// midpoint of the first two off-curve points.
    fn outline_contour(
        self: *Builder,
        source: *const ttf.Outline,
        start: u32,
        end: u32,
        scale: f32,
        pen: Point,
    ) void {
        assert(start < end);
        const count = end - start;
        var first: u32 = 0;
        while (first < count) : (first += 1) {
            if (source.on[start + first]) break;
        }
        const origin: Point = if (first < count)
            placed(source, start + first, scale, pen)
        else
            middle(placed(source, start, scale, pen), placed(source, start + 1, scale, pen));
        if (first == count) first = 0;
        self.move_to(origin);
        var control: ?Point = null;
        var step: u32 = 1;
        while (step <= count) : (step += 1) {
            const index = start + (first + step) % count;
            const closing = step == count;
            const point = if (closing) origin else placed(source, index, scale, pen);
            const on = closing or source.on[index];
            if (on) {
                if (control) |c| self.quad_to(c, point) else self.line_to(point);
                control = null;
            } else {
                if (control) |c| self.quad_to(c, middle(c, point));
                control = point;
            }
        }
        assert(control == null);
    }

    fn add(self: *Builder, point: Point) void {
        const a = self.pen;
        self.pen = point;
        if (a[0] == point[0] and a[1] == point[1]) return;
        if (self.count == segment_cap) {
            self.overflowed = true;
            return;
        }
        self.edges[self.count] = .{ .a = a, .b = point };
        self.count += 1;
        assert(self.count <= segment_cap);
    }

    /// The contours so far, closed or not.
    pub fn items(self: *const Builder) []const Edge {
        assert(self.count <= segment_cap);
        return self.edges[0..self.count];
    }
};

fn placed(source: *const ttf.Outline, index: u32, scale: f32, pen: Point) Point {
    assert(index < source.point_count);
    return .{ pen[0] + source.x[index] * scale, pen[1] - source.y[index] * scale };
}

fn middle(a: Point, b: Point) Point {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

/// One band of a plan: `[top, bottom)` in the shape's absolute y, listing `count` segments.
pub const Band = struct {
    top: f32,
    bottom: f32,
    count: u32,
};

/// A shape's bands, top to bottom (module guide, section 3).
pub const Plan = struct {
    bands: [bands_max]Band,
    count: u32,
    /// Points the bands take: 2 per segment per band it meets.
    points: u32,
    /// The unpadded bounds of the edges.
    bounds: Rect,

    pub fn items(self: *const Plan) []const Band {
        assert(self.count <= bands_max);
        return self.bands[0..self.count];
    }
};

/// `y` down to the band grid.
fn grid_down(y: f32) f32 {
    return @floor(y * band_grid) / band_grid;
}

/// `y` up to the band grid.
fn grid_up(y: f32) f32 {
    return @ceil(y * band_grid) / band_grid;
}

/// True when `edge` has area and meets `[top, bottom]` padded by `aa_pad`.
fn meets(edge: Edge, top: f32, bottom: f32) bool {
    if (edge.a[1] == edge.b[1]) return false;
    const low = @min(edge.a[1], edge.b[1]);
    const high = @max(edge.a[1], edge.b[1]);
    return low <= bottom + aa_pad and high >= top - aa_pad;
}

/// How many of `edges` a band lists.
fn band_count(edges: []const Edge, top: f32, bottom: f32) u32 {
    var count: u32 = 0;
    for (edges) |edge| {
        if (meets(edge, top, bottom)) count += 1;
    }
    assert(count <= edges.len);
    return count;
}

/// The unpadded axis-aligned bounds of `edges`.
fn bounds_of(edges: []const Edge) Rect {
    assert(edges.len >= 1);
    var low = edges[0].a;
    var high = edges[0].a;
    for (edges) |edge| {
        for ([2]Point{ edge.a, edge.b }) |point| {
            assert(point[0] == point[0]);
            assert(point[1] == point[1]);
            low = .{ @min(low[0], point[0]), @min(low[1], point[1]) };
            high = .{ @max(high[0], point[0]), @max(high[1], point[1]) };
        }
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

/// Cuts `edges` into bands (module guide, section 3). Null when a band under `band_height_min`
/// lists more than `segments_max`, or the bands pass `bands_max`.
pub fn plan_bands(edges: []const Edge) ?Plan {
    assert(edges.len >= 1);
    assert(edges.len <= segment_cap);
    const bounds = bounds_of(edges);
    assert(bounds.height > 0);
    var plan: Plan = .{ .bands = undefined, .count = 0, .points = 0, .bounds = bounds };
    var stack: [split_depth_max][2]f32 = undefined;
    stack[0] = .{ grid_down(bounds.y - aa_pad), grid_up(bounds.y + bounds.height + aa_pad) };
    var depth: u32 = 1;
    var visits: u32 = 0;
    while (depth > 0) : (visits += 1) {
        // Every visit makes a band or a split, so this holds for a plan that fits.
        assert(visits <= 2 * bands_max + 2);
        depth -= 1;
        const range = stack[depth];
        const count = band_count(edges, range[0], range[1]);
        if (count > segments_max) {
            const height = range[1] - range[0];
            if (height <= band_height_min) return null;
            if (depth + 2 > split_depth_max) return null;
            const cut = grid_down((range[0] + range[1]) * 0.5);
            assert(cut > range[0] and cut < range[1]);
            stack[depth] = .{ cut, range[1] };
            stack[depth + 1] = .{ range[0], cut };
            depth += 2;
            continue;
        }
        if (count == 0) continue;
        if (plan.count == bands_max) return null;
        plan.bands[plan.count] = .{ .top = range[0], .bottom = range[1], .count = count };
        plan.count += 1;
        plan.points += 2 * count;
    }
    assert(plan.count >= 1);
    return plan;
}

/// How a shape is filled.
pub const Style = struct {
    color: [4]f32,
    rule: Rule = .non_zero,
    hover: f32 = 0,
};

/// Where a shape went: `count` points from `first`, relative to the top-left of `bounds`
/// (absolute, unpadded), in `bands` instances.
pub const Placed = struct {
    first: u32,
    count: u32,
    bounds: Rect,
    bands: u32,
};

/// Appends the shape in `shape`, closing an open contour, to the draw context `cx` on its current
/// layer. Returns where its points went, or null when it could not take all of it: a Builder
/// that overflowed, a band over the cap, or a full pool, point pool, or batch list. Nothing is
/// kept then, and the refusal is counted in `cx.overflow_count`. A shape with no area appends
/// nothing and counts nothing, and returns null too.
pub fn append(cx: anytype, shape: *Builder, style: Style, clip: Clip) ?Placed {
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    shape.close();
    if (shape.overflowed) {
        cx.refuse();
        return null;
    }
    const edges = shape.items();
    var any_area = false;
    for (edges) |edge| any_area = any_area or edge.a[1] != edge.b[1];
    if (!any_area) return null;
    const plan = plan_bands(edges) orelse {
        cx.refuse();
        return null;
    };
    if (cx.room(Fill) < plan.count) {
        cx.refuse();
        return null;
    }
    const first = cx.reserve_points(plan.points) orelse return null;
    const origin: Point = .{ plan.bounds.x, plan.bounds.y };
    var written: u32 = first;
    for (plan.items(), 0..) |band, index| {
        const start = written;
        for (edges) |edge| {
            if (!meets(edge, band.top, band.bottom)) continue;
            cx.points[written] = .{ edge.a[0] - origin[0], edge.a[1] - origin[1] };
            cx.points[written + 1] = .{ edge.b[0] - origin[0], edge.b[1] - origin[1] };
            written += 2;
        }
        assert(written - start == 2 * band.count);
        const instance = band_of(&plan, band, start, origin, style, clip);
        cx.append(Fill, null, instance) catch |err| switch (err) {
            // Only the first band can open a batch: the rest share its layer and type.
            error.BatchFull => {
                assert(index == 0);
                cx.release_points(first);
                return null;
            },
            error.PoolFull, error.EdgeNotPositive, error.ClipUnordered => unreachable,
        };
    }
    assert(written == first + plan.points);
    return .{ .first = first, .count = plan.points, .bounds = plan.bounds, .bands = plan.count };
}

/// The instance of `band`, whose points start at `first`.
fn band_of(
    plan: *const Plan,
    band: Band,
    first: u32,
    origin: Point,
    style: Style,
    clip: Clip,
) Fill {
    assert(band.bottom > band.top);
    assert(band.count <= segments_max);
    const x = plan.bounds.x - aa_pad;
    const instance: Fill = .{
        .rect = .{ x, band.top, plan.bounds.width + 2 * aa_pad, band.bottom - band.top },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = style.color,
        .anchor_x = origin[0] - x,
        .anchor_y = origin[1] - band.top,
        .first_point = @floatFromInt(first),
        .point_count = @floatFromInt(2 * band.count),
        .rule = @floatFromInt(@backingInt(style.rule)),
        .hover = style.hover,
        .pad0 = 0,
        .pad1 = 0,
    };
    assert(instance.rect[2] > 0);
    assert(instance.rect[3] > 0);
    return instance;
}

fn ramp(u: f32) f32 {
    const c = std.math.clamp(u, 0, 1);
    return 0.5 * c * c + @max(u - 1, 0);
}

/// The signed part of a pixel left of the segment from `a` to `b`, in that pixel's rows, with
/// coordinates in pixels from its centre (module guide, section 4). CPU twin of `fill_area`.
pub fn signed_area(a: Point, b: Point) f32 {
    const down = b[1] > a[1];
    const lo = if (down) a else b;
    const hi = if (down) b else a;
    const y0 = @max(lo[1], -0.5);
    const y1 = @min(hi[1], 0.5);
    if (y1 <= y0) return 0;
    const slope = (hi[0] - lo[0]) / (hi[1] - lo[1]);
    const at0 = lo[0] + (y0 - lo[1]) * slope + 0.5;
    const at1 = lo[0] + (y1 - lo[1]) * slope + 0.5;
    var left: f32 = 0;
    if (at0 >= 1 and at1 >= 1) {
        left = 1;
    } else if (at0 > 0 or at1 > 0) {
        if (@abs(at1 - at0) < 1.0e-3) {
            left = std.math.clamp(0.5 * (at0 + at1), 0, 1);
        } else {
            left = (ramp(at1) - ramp(at0)) / (at1 - at0);
        }
    }
    const area = (y1 - y0) * left;
    return if (down) area else -area;
}

/// Coverage from a pixel's summed signed area, by `rule` (module guide, section 4).
pub fn cover_of(sum: f32, rule: Rule) f32 {
    const w = @abs(sum);
    return switch (rule) {
        .non_zero => @min(w, 1),
        .even_odd => 1 - @abs(1 - (w - 2 * @floor(0.5 * w))),
    };
}

/// The coverage of the pixel centred at `(x, y)`, `pixel_size` logical pixels wide, by the
/// whole shape, with no bands: what every band's list must agree with.
pub fn coverage(edges: []const Edge, rule: Rule, x: f32, y: f32, pixel_size: f32) f32 {
    assert(pixel_size > 0);
    var sum: f32 = 0;
    for (edges) |edge| {
        const a: Point = .{ (edge.a[0] - x) / pixel_size, (edge.a[1] - y) / pixel_size };
        const b: Point = .{ (edge.b[0] - x) / pixel_size, (edge.b[1] - y) / pixel_size };
        sum += signed_area(a, b);
    }
    return cover_of(sum, rule);
}

/// The alpha the `Fill` shader writes at `(x, y)` (absolute, logical pixels) for `band`, with
/// `points` the frame's whole point buffer. Zero outside the band's rect, where no fragment
/// runs, and outside its clip. CPU twin of `Fill.pixel` and the prelude's clip mask.
pub fn band_alpha(points: []const Point, band: *const Fill, x: f32, y: f32, pixel_size: f32) f32 {
    assert(pixel_size > 0);
    const rect = band.rect;
    if (x < rect[0] or x >= rect[0] + rect[2]) return 0;
    if (y < rect[1] or y >= rect[1] + rect[3]) return 0;
    const clip = band.clip;
    if (x < clip[0] or y < clip[1] or x > clip[2] or y > clip[3]) return 0;
    const qx = x - rect[0] - band.anchor_x;
    const qy = y - rect[1] - band.anchor_y;
    const first: u32 = @intFromFloat(band.first_point);
    const count: u32 = @as(u32, @intFromFloat(band.point_count)) / 2;
    assert(count <= segments_max);
    assert(first + 2 * count <= points.len);
    var sum: f32 = 0;
    for (0..count) |index| {
        const a = points[first + 2 * index];
        const b = points[first + 2 * index + 1];
        sum += signed_area(
            .{ (a[0] - qx) / pixel_size, (a[1] - qy) / pixel_size },
            .{ (b[0] - qx) / pixel_size, (b[1] - qy) / pixel_size },
        );
    }
    const rule: Rule = if (band.rule > 0.5) .even_odd else .non_zero;
    const alpha = cover_of(sum, rule);
    assert(alpha >= 0);
    return band.color[3] * alpha;
}

comptime {
    assert(@sizeOf(Fill) == 80);
    assert(@sizeOf(Edge) == 16);
    assert(@offsetOf(Fill, "first_point") == 56);
    // A band is 2 points per segment, and a point index is an exact `f32` (`path.zig`).
    assert(segments_max <= path.chunk_segments_max * 4);
    assert(segment_cap >= path.segments_max);
    // Band edges stay exact for coordinates below 2^15 (section 3).
    assert(band_grid == 256);
    // The splitting stack holds a shape 2^23 logical pixels tall, far past any target.
    assert(split_depth_max >= 24);
    assert(bands_max >= 14);
}

const testing = std.testing;
const registry = @import("registry.zig");
const types = @import("types.zig");
const text = @import("../text.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 4 },
    .{ .type = Fill, .cap = 64 },
};

const TestContext = pools.Context(&test_draw, 4, 4096);

fn new_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

const window: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 4000, .y1 = 4000 };

const test_builder = struct {
    var shape: Builder = undefined;

    fn new(zoom: f32) *Builder {
        shape = .init(zoom);
        return &shape;
    }
};

/// A comb: `teeth` narrow teeth down the right of a wall, each a `pitch` tall, so that a band
/// meets four segments per tooth.
fn comb(shape: *Builder, x: f32, y: f32, teeth: u32, pitch: f32) void {
    shape.move_to(.{ x, y });
    var tooth: u32 = 0;
    while (tooth < teeth) : (tooth += 1) {
        const top = y + @as(f32, @floatFromInt(tooth)) * pitch;
        shape.line_to(.{ x + 60, top + 0.25 * pitch });
        shape.line_to(.{ x + 60, top + 0.5 * pitch });
        shape.line_to(.{ x + 20, top + 0.75 * pitch });
        shape.line_to(.{ x + 20, top + pitch });
    }
    shape.line_to(.{ x, y + @as(f32, @floatFromInt(teeth)) * pitch });
    shape.close();
}

// Locks flattening: a straight quadratic is one chord and a tight one 16, raster's rule at a
// quarter of its tolerance (`tolerance_px`); a cubic
// takes `path`'s count, doubled at zoom 2; `close`, the next `move_to`, and a duplicate point
// add no empty edge, so a square is 4 edges however it is closed.
test "contours flatten by the rasterizer's and the stroke's rules" {
    const shape = test_builder.new(1);
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 5, 0 }, .{ 10, 0 });
    try testing.expectEqual(@as(u32, 1), shape.count);
    shape.reset();
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 500, 900 }, .{ 1000, 0 });
    try testing.expectEqual(raster.segment_cap, shape.count);
    try testing.expectEqual(Point{ 1000, 0 }, shape.items()[15].b);
    // A deviation of 40 px over 8 * 0.05: sqrt(100) = 10 chords, ceil(sqrt(200)) = 15 at zoom 2,
    // the cap of 16 at zoom 4. The rasterizer's 0.2 would take 5 and 8.
    shape.reset();
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 0, 10 }, .{ 0, 60 });
    try testing.expectEqual(@as(u32, 10), shape.count);
    try testing.expectEqual(@as(u32, 5), raster.quad_chords(40));
    const zoomed = test_builder.new(2);
    zoomed.move_to(.{ 0, 0 });
    zoomed.quad_to(.{ 0, 10 }, .{ 0, 60 });
    try testing.expectEqual(@as(u32, 15), zoomed.count);
    const capped = test_builder.new(4);
    capped.move_to(.{ 0, 0 });
    capped.quad_to(.{ 0, 10 }, .{ 0, 60 });
    try testing.expectEqual(raster.segment_cap, capped.count);
    const cubic = test_builder.new(1);
    cubic.move_to(.{ 0, 0 });
    cubic.cubic_to(.{ .{ 40, 0 }, .{ 80, 0 } }, .{ 120, 0 });
    try testing.expectEqual(@as(u32, 20), cubic.count);
    const doubled = test_builder.new(2);
    doubled.move_to(.{ 0, 0 });
    doubled.cubic_to(.{ .{ 40, 0 }, .{ 80, 0 } }, .{ 120, 0 });
    try testing.expectEqual(@as(u32, 40), doubled.count);
    const square = test_builder.new(1);
    square.move_to(.{ 0, 0 });
    square.line_to(.{ 10, 0 });
    square.line_to(.{ 10, 0 });
    square.line_to(.{ 10, 10 });
    square.line_to(.{ 0, 10 });
    square.move_to(.{ 20, 0 });
    try testing.expectEqual(@as(u32, 4), square.count);
    try testing.expectEqual(Point{ 0, 0 }, square.items()[3].b);
    square.line_to(.{ 30, 0 });
    square.line_to(.{ 30, 10 });
    square.line_to(.{ 20, 0 });
    square.close();
    try testing.expectEqual(@as(u32, 7), square.count);
}

fn expect_point(want: Point, got: Point) !void {
    try testing.expectApproxEqAbs(want[0], got[0], 1.0e-5);
    try testing.expectApproxEqAbs(want[1], got[1], 1.0e-5);
}

// Locks `Transform`: a quarter turn takes (1, 0) to (0, 1), +y down; a half turn about (10, 10)
// takes (11, 10) to (9, 10) and holds the pivot; `then` is the second after the first, equal to
// applying twice; a scale of 0 collapses to a line.
test "transforms compose and hold their pivot" {
    try expect_point(.{ 0, 1 }, Transform.rotation(0.5 * std.math.pi).apply(.{ 1, 0 }));
    const half = Transform.around(.{ 10, 10 }, .rotation(std.math.pi));
    try expect_point(.{ 9, 10 }, half.apply(.{ 11, 10 }));
    try expect_point(.{ 10, 10 }, half.apply(.{ 10, 10 }));
    const first = Transform.scaling(2, 3).then(.rotation(0.5));
    const second = Transform.translation(4, -5);
    const both = first.then(second);
    for ([_]Point{ .{ 0, 0 }, .{ 1, 2 }, .{ -3, 7 } }) |point| {
        try expect_point(second.apply(first.apply(point)), both.apply(point));
    }
    // Scale then translate differs from translate then scale.
    const moved = Transform.scaling(2, 2).then(.translation(1, 1));
    try expect_point(.{ 3, 3 }, moved.apply(.{ 1, 1 }));
    try expect_point(.{ 4, 4 }, Transform.translation(1, 1).then(.scaling(2, 2)).apply(.{ 1, 1 }));
    try expect_point(.{ 0, 5 }, Transform.scaling(0, 1).apply(.{ 3, 5 }));
}

// Locks `Builder.transform`: a quadratic of deviation 4 takes 4 chords at identity, 7 under a
// scale of 4 (the count goes with the square root of the deviation) and 4 under a rotation (the
// deviation's length is kept); a cubic's count follows the scale; a shape's coverage under a
// transform equals the coverage of the same points transformed by hand; the transform applies
// once through `polygon`; `reset` restores the identity and a scale of 0 appends nothing.
test "a transform maps points before they are flattened" {
    const shape = test_builder.new(1);
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 0, 3 }, .{ 0, 10 });
    try testing.expectEqual(@as(u32, 4), shape.count);
    shape.reset();
    shape.set_transform(.scaling(4, 4));
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 0, 3 }, .{ 0, 10 });
    try testing.expectEqual(@as(u32, 7), shape.count);
    shape.reset();
    try testing.expectEqual(Transform.identity, shape.transform);
    shape.set_transform(.rotation(1));
    shape.move_to(.{ 0, 0 });
    shape.quad_to(.{ 0, 3 }, .{ 0, 10 });
    try testing.expectEqual(@as(u32, 4), shape.count);
    shape.reset();
    shape.move_to(.{ 0, 0 });
    shape.cubic_to(.{ .{ 40, 0 }, .{ 80, 0 } }, .{ 120, 0 });
    const plain = shape.count;
    shape.reset();
    shape.set_transform(.scaling(2, 2));
    shape.move_to(.{ 0, 0 });
    shape.cubic_to(.{ .{ 40, 0 }, .{ 80, 0 } }, .{ 120, 0 });
    try testing.expectEqual(2 * plain, shape.count);

    const triangle = [3]Point{ .{ 3, 3 }, .{ 40, 9 }, .{ 12, 50 } };
    const turn = Transform.around(.{ 20, 20 }, .rotation(0.7)).then(.translation(5, 6));
    shape.reset();
    shape.set_transform(turn);
    shape.polygon(&triangle);
    var by_hand: [3]Point = undefined;
    for (&by_hand, triangle) |*out, point| out.* = turn.apply(point);
    const other = test_builder_other.new(1);
    other.polygon(&by_hand);
    try testing.expectEqual(other.count, shape.count);
    var y: f32 = 0.5;
    while (y < 70) : (y += 3) {
        var x: f32 = 0.5;
        while (x < 70) : (x += 3) {
            try testing.expectEqual(
                coverage(other.items(), .non_zero, x, y, 1),
                coverage(shape.items(), .non_zero, x, y, 1),
            );
        }
    }

    shape.reset();
    shape.set_transform(.scaling(0, 0));
    shape.polygon(&triangle);
    try testing.expectEqual(@as(?Placed, null), append(new_context(), shape, .{ .color = @splat(1) }, window));
}

const test_builder_other = struct {
    var shape: Builder = undefined;

    fn new(zoom: f32) *Builder {
        shape = .init(zoom);
        return &shape;
    }
};

// Locks the Builder's cap: segment 1,025 sets `overflowed`, and `append` then refuses the whole
// shape, keeping nothing and counting once.
test "a shape over the Builder's cap is refused whole" {
    const shape = test_builder.new(1);
    shape.move_to(.{ 0, 0 });
    var index: u32 = 0;
    while (index <= segment_cap) : (index += 1) {
        shape.line_to(.{ @floatFromInt(index % 7 + 1), @floatFromInt(index) });
    }
    try testing.expect(shape.overflowed);
    try testing.expectEqual(segment_cap, shape.count);
    const cx = new_context();
    try testing.expectEqual(@as(?Placed, null), append(cx, shape, .{ .color = @splat(1) }, window));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expectEqual(@as(usize, 0), cx.items(Fill).len);
    try testing.expectEqual(@as(u32, 0), cx.point_count);
}

// Locks the band split on a comb of 98 segments, 240 tall: two halves still list over 48, since
// lists overlap at a cut, so it ends in four bands; every segment lands in a band, every list
// holds at most 48, edges meet on the grid with no gap, and only the outer ends are padded.
test "bands halve until their lists fit" {
    const shape = test_builder.new(1);
    comb(shape, 100, 200, 24, 10);
    shape.close();
    const edges = shape.items();
    const plan = plan_bands(edges).?;
    try testing.expectEqual(@as(u32, 4), plan.count);
    try testing.expectEqual(@as(f32, 199), plan.bands[0].top);
    try testing.expectEqual(@as(f32, 441), plan.bands[3].bottom);
    for (plan.bands[0..3], plan.bands[1..4]) |upper, lower| {
        try testing.expectEqual(upper.bottom, lower.top);
    }
    var points: u32 = 0;
    for (plan.items()) |band| {
        try testing.expect(band.count <= segments_max);
        try testing.expectEqual(band_count(edges, band.top, band.bottom), band.count);
        points += 2 * band.count;
    }
    try testing.expectEqual(points, plan.points);
    for (edges) |edge| {
        if (edge.a[1] == edge.b[1]) continue;
        var found = false;
        for (plan.items()) |band| found = found or meets(edge, band.top, band.bottom);
        try testing.expect(found);
    }
    // Horizontal edges are in no list.
    const flat: Edge = .{ .a = .{ 0, 5 }, .b = .{ 9, 5 } };
    try testing.expect(!meets(flat, 0, 10));
    // A band with no segments draws nothing: two squares 300 apart, over the cap between them.
    const two = test_builder.new(1);
    comb(two, 0, 0, 13, 4);
    comb(two, 0, 340, 13, 4);
    const apart = plan_bands(two.items()).?;
    try testing.expect(apart.count >= 2);
    try testing.expect(apart.points < 2 * 2 * two.count);
}

// Locks the refusal: 80 teeth in one logical pixel list over 48 segments in a band under 1 px,
// so the whole shape is refused and counted, and nothing is kept.
test "a band under one pixel over the cap refuses the shape" {
    const shape = test_builder.new(1);
    comb(shape, 0, 0, 80, 0.0125);
    const cx = new_context();
    try testing.expectEqual(@as(?Plan, null), plan_bands(shape.items()));
    try testing.expectEqual(@as(?Placed, null), append(cx, shape, .{ .color = @splat(1) }, window));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expectEqual(@as(u32, 0), cx.point_count);
    try testing.expectEqual(@as(usize, 0), cx.items(Fill).len);
}

// Locks atomic appends: a shape over the point room keeps nothing, a full batch list takes the
// points back, and a shape with no area appends nothing and counts nothing.
test "a refused shape keeps nothing" {
    const cx = new_context();
    const shape = test_builder.new(1);
    comb(shape, 0, 0, 200, 8);
    try testing.expect(plan_bands(shape.items()).?.points <= 4096);
    _ = append(cx, shape, .{ .color = @splat(1) }, window).?;
    const used = cx.point_count;
    const bands = cx.items(Fill).len;
    try testing.expect(used > 2 * shape.count);
    while (cx.point_count + plan_bands(shape.items()).?.points <= 4096) {
        _ = append(cx, shape, .{ .color = @splat(1) }, window).?;
    }
    const kept = cx.point_count;
    const before = cx.items(Fill).len;
    try testing.expectEqual(@as(?Placed, null), append(cx, shape, .{ .color = @splat(1) }, window));
    try testing.expectEqual(kept, cx.point_count);
    try testing.expectEqual(before, cx.items(Fill).len);
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expect(bands >= 4);
    cx.reset();
    var level: u8 = 0;
    while (level < 4) : (level += 1) {
        _ = cx.layer(@fromBackingInt(level));
        const unit: draw.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
        try cx.append(types.Box, null, .of(unit, clip, .{ .fill = .{ 1, 1, 1, 1 } }));
    }
    const triangle = test_builder.new(1);
    triangle.polygon(&.{ .{ 0, 0 }, .{ 9, 0 }, .{ 0, 9 } });
    try testing.expectEqual(@as(?Placed, null), append(cx, triangle, .{ .color = @splat(1) }, window));
    try testing.expectEqual(@as(u32, 0), cx.point_count);
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    const line = test_builder.new(1);
    line.move_to(.{ 0, 5 });
    line.line_to(.{ 9, 5 });
    try testing.expectEqual(@as(?Placed, null), append(cx, line, .{ .color = @splat(1) }, window));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
}

// Locks the area of one pixel against a unit square, worked by hand: full inside, nothing
// outside, a half on each straight edge, a quarter at a corner; a pixel cut by a diagonal through
// its centre is a half and one cut through its corner an eighth; direction only changes the sign.
test "coverage is the exact area of the pixel" {
    const square = [_]Edge{
        .{ .a = .{ 10, 10 }, .b = .{ 20, 10 } },
        .{ .a = .{ 20, 10 }, .b = .{ 20, 20 } },
        .{ .a = .{ 20, 20 }, .b = .{ 10, 20 } },
        .{ .a = .{ 10, 20 }, .b = .{ 10, 10 } },
    };
    const eps = 1.0e-5;
    try testing.expectApproxEqAbs(@as(f32, 1), coverage(&square, .non_zero, 15, 15, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0), coverage(&square, .non_zero, 25, 15, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage(&square, .non_zero, 10, 15, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage(&square, .non_zero, 15, 20, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.25), coverage(&square, .non_zero, 20, 20, 1), eps);
    // A pixel half as wide sees the edge the same way, and a quarter past it sees a quarter.
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage(&square, .non_zero, 10, 15, 0.5), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.25), coverage(&square, .non_zero, 9.875, 15, 0.5), eps);
    const big = [_]Edge{
        .{ .a = .{ 0, 0 }, .b = .{ 100, 100 } },
        .{ .a = .{ 100, 100 }, .b = .{ 0, 100 } },
        .{ .a = .{ 0, 100 }, .b = .{ 0, 0 } },
    };
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage(&big, .non_zero, 50, 50, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.875), coverage(&big, .non_zero, 50, 50.5, 1), eps);
    try testing.expectApproxEqAbs(@as(f32, 0.125), coverage(&big, .non_zero, 50, 49.5, 1), eps);
    const a: Point = .{ 0.25, -3 };
    const b: Point = .{ -0.25, 3 };
    try testing.expectApproxEqAbs(signed_area(a, b), -signed_area(b, a), eps);
}

// Locks a vertex on a pixel's row: a diamond's corner lies exactly on the pixel centre's row, and
// the two edges that meet there split the pixel between them, so the vertex counts once: inside
// the diamond's width the pixel is full, and left and right of it empty, with no double count.
test "a vertex on the row counts once" {
    const diamond = [_]Edge{
        .{ .a = .{ 50, 0 }, .b = .{ 100, 50 } },
        .{ .a = .{ 100, 50 }, .b = .{ 50, 100 } },
        .{ .a = .{ 50, 100 }, .b = .{ 0, 50 } },
        .{ .a = .{ 0, 50 }, .b = .{ 50, 0 } },
    };
    for ([_]Rule{ .non_zero, .even_odd }) |rule| {
        try testing.expectApproxEqAbs(@as(f32, 1), coverage(&diamond, rule, 50, 50, 1), 1.0e-5);
        try testing.expectApproxEqAbs(@as(f32, 0), coverage(&diamond, rule, 150, 50, 1), 1.0e-5);
        try testing.expectApproxEqAbs(@as(f32, 0), coverage(&diamond, rule, -50, 50, 1), 1.0e-5);
    }
    // The pixel centred on the right corner holds the corner's triangle, half a pixel long.
    const corner = coverage(&diamond, .non_zero, 100, 50, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), corner, 1.0e-5);
}

/// A five-point star through every second point of a circle of radius 100 around (120, 120).
fn star(shape: *Builder) void {
    var points: [5]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * 2.0 * 2.0 * std.math.pi / 5.0;
        point.* = .{ 120 + 100 * @sin(turn), 120 - 100 * @cos(turn) };
    }
    shape.polygon(&points);
}

// Locks what the coverage is for: on a five-point star under non-zero, the centre (winding 2)
// and its arms (winding 1) are both full, and every pixel along the edges between them stays
// full, where a distance to the nearest segment would draw 0.5; even-odd empties the centre and
// keeps the arms, and an edge pixel there is the arm's own share.
test "edges between inside regions draw nothing" {
    const shape = test_builder.new(1);
    star(shape);
    const edges = shape.items();
    try testing.expectApproxEqAbs(@as(f32, 1), coverage(edges, .non_zero, 120, 120, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), coverage(edges, .even_odd, 120, 120, 1), 1.0e-4);
    // The inner edge across the top arm, at y = 120 - 100 cos(72) = 89.1, from the arm into the
    // centre, walked over the row at several sub-pixel offsets.
    const edge_y = 120 - 100 * @cos(@as(f32, 2.0 * std.math.pi / 5.0));
    var row: f32 = -2;
    while (row <= 2) : (row += 0.125) {
        const cover = coverage(edges, .non_zero, 120, edge_y + row, 1);
        try testing.expectApproxEqAbs(@as(f32, 1), cover, 1.0e-3);
    }
    const arm = coverage(edges, .even_odd, 120, edge_y - 3, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), arm, 1.0e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), coverage(edges, .even_odd, 120, edge_y, 1), 1.0e-3);
}

// Locks a ring: the hole of opposite direction is empty under both rules, and its wall is full;
// two contours of the same direction leave a hole only under even-odd.
test "holes come from winding" {
    const shape = test_builder.new(1);
    shape.polygon(&.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 0, 100 } });
    shape.polygon(&.{ .{ 30, 30 }, .{ 30, 70 }, .{ 70, 70 }, .{ 70, 30 } });
    const edges = shape.items();
    try testing.expectApproxEqAbs(@as(f32, 0), coverage(edges, .non_zero, 50, 50, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), coverage(edges, .non_zero, 15, 50, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), coverage(edges, .even_odd, 50, 50, 1), 1.0e-4);
    const same = test_builder.new(1);
    same.polygon(&.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 }, .{ 0, 100 } });
    same.polygon(&.{ .{ 30, 30 }, .{ 70, 30 }, .{ 70, 70 }, .{ 30, 70 } });
    try testing.expectApproxEqAbs(@as(f32, 1), coverage(same.items(), .non_zero, 50, 50, 1), 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), coverage(same.items(), .even_odd, 50, 50, 1), 1.0e-4);
}

/// Source-over of every band at a pixel: what the GPU blends.
fn composite(cx: *const TestContext, x: f32, y: f32, pixel_size: f32) f32 {
    var clear: f32 = 1;
    for (cx.items(Fill)) |*band| {
        clear *= 1 - band_alpha(cx.point_items(), band, x, y, pixel_size);
    }
    return 1 - clear;
}

// Locks the seam rule (section 3): a translucent comb split into at least 3 bands. Before a
// shift each band's rect ends exactly where the next begins. After shifts by a whole, a half, and
// a third of a pixel they meet to within an ulp, so each pixel centre at 1x and 2x lies in exactly
// one band, and at every pixel the composite equals the unbanded coverage times the alpha: no
// row is blended twice.
test "a tall translucent shape blends once across its seams" {
    const alpha: f32 = 0.5;
    const shape = test_builder.new(1);
    comb(shape, 40, 40, 60, 8);
    const edges = shape.items();
    const cx = new_context();
    const starts = cx.counts();
    const placed_shape = append(cx, shape, .{ .color = .{ 1, 1, 1, alpha } }, window).?;
    try testing.expect(placed_shape.bands >= 3);
    const shifts = [_][2]f32{ .{ 0, 0 }, .{ 2, 3 }, .{ 0.5, 0.5 }, .{ 0, 1.0 / 3.0 } };
    for (cx.items(Fill)[0 .. cx.items(Fill).len - 1], cx.items(Fill)[1..]) |upper, lower| {
        try testing.expectEqual(lower.rect[1], upper.rect[1] + upper.rect[3]);
    }
    var moved: Point = .{ 0, 0 };
    for (shifts) |delta| {
        cx.shift(starts, delta[0], delta[1]);
        moved = .{ moved[0] + delta[0], moved[1] + delta[1] };
        const bands = cx.items(Fill);
        for (bands[0 .. bands.len - 1], bands[1..]) |upper, lower| {
            try testing.expectApproxEqAbs(lower.rect[1], upper.rect[1] + upper.rect[3], 1.0e-4);
        }
    }
    const bands = cx.items(Fill);
    for ([_]f32{ 1, 0.5 }) |pixel_size| {
        // Pixel centres, not offsets from a rect: the grid the rasterizer samples.
        var y = 0.5 * pixel_size;
        while (y < bands[0].rect[1]) : (y += pixel_size) {}
        while (y < bands[bands.len - 1].rect[1] + bands[bands.len - 1].rect[3]) : (y += pixel_size) {
            var owners: u32 = 0;
            for (bands) |band| {
                if (y >= band.rect[1] and y < band.rect[1] + band.rect[3]) owners += 1;
            }
            try testing.expectEqual(@as(u32, 1), owners);
            var x: f32 = 38;
            while (x < 110) : (x += 3 * pixel_size) {
                const want = coverage(edges, .non_zero, x - moved[0], y - moved[1], pixel_size);
                const got = composite(cx, x, y, pixel_size);
                try testing.expectApproxEqAbs(want * alpha, got, 2.0e-3);
            }
        }
    }
}

// Locks `Context.shift`: the alpha at a point before a shift is the alpha at that point plus the
// delta after it, and the points do not move.
test "a shift moves the shape with its rects" {
    const shape = test_builder.new(1);
    star(shape);
    const cx = new_context();
    const starts = cx.counts();
    _ = append(cx, shape, .{ .color = .{ 1, 1, 1, 0.75 } }, window).?;
    const probes = [_]Point{ .{ 120, 120 }, .{ 120, 25 }, .{ 77, 180 }, .{ 200, 90 } };
    var before: [probes.len]f32 = undefined;
    for (probes, &before) |probe, *value| value.* = composite(cx, probe[0], probe[1], 1);
    cx.shift(starts, 7, 11);
    for (probes, before) |probe, value| {
        try testing.expectApproxEqAbs(value, composite(cx, probe[0] + 7, probe[1] + 11, 1), 1.0e-5);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.75), before[0], 1.0e-4);
}

const test_raster = struct {
    var scratch: raster.Raster = undefined;
    var bitmap: [raster.side_cap * raster.side_cap]u8 = undefined;
    var outline: ttf.Outline = undefined;
    var shape: Builder = undefined;
};

/// The largest difference between `raster.fill`'s coverage and the bands' over `outline` at
/// `scale`, one level being 1/255, walking every pixel of the box.
fn raster_difference(outline: *const ttf.Outline, scale: f32) !f32 {
    const box = raster.box_of(outline, scale);
    try testing.expect(box.width <= raster.side_cap and box.height <= raster.side_cap);
    const scratch = &test_raster.scratch;
    try testing.expect(raster.flatten(scratch, outline, scale, box));
    raster.fill(scratch, box, &test_raster.bitmap, box.width);
    const shape = &test_raster.shape;
    // A zoom of 1/4 cancels `tolerance_px`'s factor of 4: the rasterizer's chords.
    shape.* = .init(0.25);
    const pen: Point = .{ -@as(f32, @floatFromInt(box.left)), @floatFromInt(box.top) };
    shape.outline(outline, scale, pen);
    // The same chords as the rasterizer, horizontal ones included.
    try testing.expectEqual(scratch.edge_count, shape.count);
    const cx = new_context();
    const placed_shape = append(cx, shape, .{ .color = @splat(1) }, window) orelse
        return error.Refused;
    try testing.expectEqual(@as(u32, 0), cx.overflow_count);
    assert(placed_shape.bands >= 1);
    var worst: f32 = 0;
    for (0..box.height) |row| {
        for (0..box.width) |column| {
            const want = @as(f32, @floatFromInt(test_raster.bitmap[row * box.width + column])) / 255;
            const x = @as(f32, @floatFromInt(column)) + 0.5;
            const y = @as(f32, @floatFromInt(row)) + 0.5;
            worst = @max(worst, @abs(want - composite(cx, x, y, 1)));
        }
    }
    return worst;
}

// Locks the twin against the exact-area rasterizer on real outlines: for every ASCII glyph of the
// sans and mono faces at 16, 64, and 150 px (the largest box `raster.fill` holds), every pixel of
// the bands agrees with `raster.zig` to within 1.5 levels of 255; both are the same area.
test "fill coverage matches the rasterizer on glyph outlines" {
    for (&text.fonts) |*font| {
        var worst: f32 = 0;
        var code: u21 = 0x21;
        while (code < 0x7F) : (code += 1) {
            const id = ttf.glyph_id(font, code);
            if (id == 0) continue;
            if (ttf.load(font, id, &test_raster.outline) != .ready) continue;
            const units: f32 = @floatFromInt(font.units_per_em);
            for ([_]f32{ 16, 64, 150 }) |size| {
                worst = @max(worst, try raster_difference(&test_raster.outline, size / units));
            }
        }
        try testing.expect(worst <= 1.5 / 255.0);
    }
}

// Locks the twin against the rasterizer on polygons: a star (overlapping itself) and a triangle
// over a box of 120 px, with coverage summed the same way, so even the crossings agree.
test "fill coverage matches the rasterizer on polygons" {
    const shapes = [_][]const Point{
        &.{ .{ 3, 3 }, .{ 117, 40 }, .{ 20, 110 } },
        &.{ .{ 60, 2 }, .{ 94, 106 }, .{ 6, 42 }, .{ 114, 42 }, .{ 26, 106 } },
    };
    const scratch = &test_raster.scratch;
    const box: raster.Box = .{ .left = 0, .top = 0, .width = 120, .height = 120 };
    for (shapes) |points| {
        scratch.edge_count = 0;
        const shape = test_builder.new(1);
        shape.polygon(points);
        for (shape.items(), 0..) |edge, index| {
            scratch.edges[index] = .{
                .x0 = edge.a[0],
                .y0 = edge.a[1],
                .x1 = edge.b[0],
                .y1 = edge.b[1],
            };
            scratch.edge_count += 1;
        }
        raster.fill(scratch, box, &test_raster.bitmap, 120);
        for (0..120) |row| {
            for (0..120) |column| {
                const want = @as(f32, @floatFromInt(test_raster.bitmap[row * 120 + column])) / 255;
                const x = @as(f32, @floatFromInt(column)) + 0.5;
                const y = @as(f32, @floatFromInt(row)) + 0.5;
                const got = coverage(shape.items(), .non_zero, x, y, 1);
                try testing.expectApproxEqAbs(want, got, 1.5 / 255.0);
            }
        }
    }
}

// Locks a large glyph, past what `raster.fill` holds, against a 16 x 16 grid of winding samples:
// at 512 px, on every 9th row and column, the bands agree with the samples to within the grid's
// 1/16 on an edge, and the shape stays within the band cap.
test "fill coverage matches point samples on a large glyph" {
    const font = &text.fonts[0];
    const id = ttf.glyph_id(font, '&');
    try testing.expectEqual(ttf.Load.ready, ttf.load(font, id, &test_raster.outline));
    const scale = 512 / @as(f32, @floatFromInt(font.units_per_em));
    const shape = test_builder.new(1);
    shape.outline(&test_raster.outline, scale, .{ 10, 520 });
    const cx = new_context();
    const placed_shape = append(cx, shape, .{ .color = @splat(1) }, window).?;
    try testing.expect(placed_shape.bands >= 2);
    const edges = shape.items();
    var row: f32 = 0.5;
    while (row < 560) : (row += 9) {
        var column: f32 = 0.5;
        while (column < 460) : (column += 9) {
            var hits: u32 = 0;
            for (0..16) |j| {
                for (0..16) |i| {
                    const dx = (@as(f32, @floatFromInt(i)) + 0.5) / 16 - 0.5;
                    const dy = (@as(f32, @floatFromInt(j)) + 0.5) / 16 - 0.5;
                    if (winding_at(edges, column + dx, row + dy) != 0) hits += 1;
                }
            }
            const want = @as(f32, @floatFromInt(hits)) / 256;
            try testing.expectApproxEqAbs(want, composite(cx, column, row, 1), 1.0 / 16.0);
        }
    }
}

/// The winding of a point: signed half-open crossings of a ray to the right.
fn winding_at(edges: []const Edge, x: f32, y: f32) i32 {
    var winding: i32 = 0;
    for (edges) |edge| {
        const down = edge.b[1] > edge.a[1];
        const lo = if (down) edge.a else edge.b;
        const hi = if (down) edge.b else edge.a;
        if (y < lo[1] or y >= hi[1]) continue;
        const t = (y - lo[1]) / (hi[1] - lo[1]);
        if (lo[0] + (hi[0] - lo[0]) * t > x) winding += if (down) 1 else -1;
    }
    return winding;
}

// Locks the record for the registry and the pixel cache: `Fill` passes the convention, reads
// points by the two named fields, and its shader names the twin's parts.
test "the Fill record follows the draw type convention" {
    try testing.expectEqual(@as(?[]const u8, null), comptime registry.check(Fill));
    try testing.expect(comptime registry.reads_points(Fill));
    try testing.expect(comptime @hasField(Fill, "point_count"));
}

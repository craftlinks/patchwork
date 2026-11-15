//! `seams`: counts the pixels of a translucent stroke that are covered twice or not at all where
//! two chunks of it meet, on the GPU.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Tool
//! A seam fault is one pixel in tens of thousands, and a regress scenario yields only a hash,
//! so a new scenario would add golden lines and say nothing of how often the fault happens. The
//! tool draws shapes through `host.offscreen.Offscreen`, reads the frame back, and counts
//! (`draw/path.zig`, sections 4 and 4a). It needs a GPU, so it is in no part of `test`, `check`,
//! or `regress`; its pure parts (`classify`, `nearest_seam`, `seam_points`) have unit tests.
//! ```text
//! zig build seams -- [--adapter high|low|both] [--scale 1|2|3] [--strict]
//! seams high scale=2 ring n=64 width=3 seams=512 interior=48211 twice=4 dropped=1 per_seam=0.0098 elsewhere=0 fold=0 cache=same
//! ```
//!
//! ## 2. The Frame
//! One `Path` pool and no container, so no alignment shift. A frame is 64 copies of one shape at
//! one width, in an 8 by 8 grid of cells; the copy in row `j`, column `i` sits at a sub-pixel
//! offset of `(i / 8, j / 8)` device pixels, so the 64 copies put the shape's seams at 64
//! different phases of the pixel grid. White at alpha 0.5 on the theme's background. The shapes
//! are regular polygons of 16, 64, and 256 points (`path.polygon`) and open polylines of two
//! straight runs of 15 segments of 2 px that meet at one vertex with a turn of 0 to 170 degrees
//! (`path.polyline`), so the first chunk ends at the turn (asserted with `path.chunk_end`).
//!
//! ## 3. The Count
//! For each device pixel of a copy's cell the distance to the shape (`path.distance_to_polyline`,
//! a ring closed by repeating its first point) says whether the pixel is interior, at most
//! `width / 2 - 0.75 / scale` from it, where the stroke has full coverage. Its colour then sits at
//! one of three levels between the background `B` and white `C`: `B + 0.5 (C - B)`, drawn once;
//! `B + 0.75 (C - B)`, drawn by two chunks; `B`, drawn by none. `classify` takes the nearest.
//! A fault belongs to the nearest seam within `width + 2` px, a seam being the first point of a
//! `Path` record with `prev` set; a fault near no seam is `elsewhere`. A pixel of a polyline that
//! two segments cover which are more than one segment apart across the seam is `fold`
//! (`fold_at`): the class the seam rule leaves, where both chunks draw by design (section 4 of
//! the module guide). It is counted apart and `--strict` ignores it; at 135 and 170 degrees a
//! stroke of 5 or 8 px folds onto itself over the whole of its two short runs.
//!
//! ## 4. Cache
//! Each configuration is drawn twice, with the renderer's cache on and off, and the frames'
//! hashes compared (`cache=same` or `cache=differs`).
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: the frame buffer, the shape's points, and the seam list are static.
//! - Every loop is bounded by the frame's size or a table's length.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const bench = patchwork.bench;
const quads = patchwork.draw;
const path = quads.path;
const app_contract = patchwork.app;
const input = patchwork.input;

const Point = path.Point;
const Off = patchwork.host.offscreen.Offscreen(App);

/// The frame in logical pixels: an 8 by 8 grid of cells (section 2).
const grid: u32 = 8;
const cell_width: u32 = 80;
const cell_height: u32 = 64;
const window_width: u32 = cell_width * grid;
const window_height: u32 = cell_height * grid;
const scale_max: u32 = 3;

const widths = [_]f32{ 1, 2, 3, 5, 8 };
const scales = [_]u32{ 1, 2, 3 };

/// Points of the longest shape's ring, and of a polyline.
const points_max: u32 = path.polygon_points_max + 1;
const run_segments: u32 = 15;
const run_step: f32 = 2;
const ring_radius: f32 = 24;

/// A fault belongs to a seam at most this many logical pixels past the stroke width from it.
const attribution_margin: f32 = 2;

/// Coverage fraction between the levels (section 3): the midpoints of 0, 0.5, and 0.75.
const level_dropped_max: f32 = 0.25;
const level_twice_min: f32 = 0.625;

const Kind = enum { ring, polyline };

const Shape = struct {
    kind: Kind,
    /// A ring's points.
    points: u32,
    /// A polyline's turn at its vertex, in degrees.
    turn: u32,
};

const shapes = [_]Shape{
    .{ .kind = .ring, .points = 16, .turn = 0 },
    .{ .kind = .ring, .points = 64, .turn = 0 },
    .{ .kind = .ring, .points = 256, .turn = 0 },
    .{ .kind = .polyline, .points = 0, .turn = 0 },
    .{ .kind = .polyline, .points = 0, .turn = 15 },
    .{ .kind = .polyline, .points = 0, .turn = 45 },
    .{ .kind = .polyline, .points = 0, .turn = 90 },
    .{ .kind = .polyline, .points = 0, .turn = 135 },
    .{ .kind = .polyline, .points = 0, .turn = 170 },
};

/// The tool's app: draws the shape its state names, 64 copies, with no container.
const App = struct {
    shape: Shape,
    width: f32,

    const Cx = app_contract.Context(App);

    pub const config: app_contract.Config = .{
        .title = "seams",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = quads.Path, .cap = 4096 }},
    };

    pub fn init(app: *App, pool: *quads.Textures) void {
        _ = pool;
        app.shape = shapes[0];
        app.width = widths[0];
    }

    pub fn event(app: *App, cx: *Cx, event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *App, cx: *Cx, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Cx) void {
        const clip: quads.Clip = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = window_width,
            .y1 = window_height,
        };
        const stroke: path.Stroke = .{ .color = .{ 1, 1, 1, 0.5 }, .width = app.width, .hover = 0 };
        var points: [points_max]Point = undefined;
        for (0..grid * grid) |copy| {
            const origin = copy_origin(@intCast(copy), app_scale());
            const count = shape_points(app.shape, origin, &points);
            const placed = switch (app.shape.kind) {
                .ring => path.polygon(cx.drawing(), points[0..count], stroke, clip),
                .polyline => path.polyline(cx.drawing(), points[0..count], stroke, clip),
            };
            assert(placed != null);
        }
        assert(cx.drawing().overflow_count == 0);
    }
};

/// The scale the open frame is drawn at (the sub-pixel offsets are device pixels).
var scale_open: u32 = 1;

fn app_scale() u32 {
    assert(scale_open >= 1 and scale_open <= scale_max);
    return scale_open;
}

/// The top-left of copy `copy`'s cell plus its sub-pixel offset of `(i / 8, j / 8)` device
/// pixels, in logical pixels (section 2).
fn copy_origin(copy: u32, scale: u32) Point {
    assert(copy < grid * grid);
    assert(scale >= 1);
    const column = copy % grid;
    const row = copy / grid;
    const unit = 1.0 / @as(f32, @floatFromInt(grid * scale));
    return .{
        @as(f32, @floatFromInt(column * cell_width)) + @as(f32, @floatFromInt(column)) * unit,
        @as(f32, @floatFromInt(row * cell_height)) + @as(f32, @floatFromInt(row)) * unit,
    };
}

/// The points of `shape` in the cell whose top-left is `origin`: a ring's `points` points, or a
/// polyline's 31. Returns the count. The same call draws and measures, so both agree.
fn shape_points(shape: Shape, origin: Point, out: *[points_max]Point) u32 {
    switch (shape.kind) {
        .ring => {
            assert(shape.points >= 3 and shape.points < points_max);
            const middle: Point = .{ origin[0] + cell_width / 2, origin[1] + cell_height / 2 };
            for (out[0..shape.points], 0..) |*point, index| {
                const turn = 2 * std.math.pi * @as(f32, @floatFromInt(index)) /
                    @as(f32, @floatFromInt(shape.points));
                point.* = .{
                    middle[0] + ring_radius * @cos(turn),
                    middle[1] + ring_radius * @sin(turn),
                };
            }
            return shape.points;
        },
        .polyline => {
            const first: Point = .{ origin[0] + 8, origin[1] + cell_height / 2 };
            const turn = @as(f32, @floatFromInt(shape.turn)) * std.math.pi / 180.0;
            const second: Point = .{ @cos(turn), @sin(turn) };
            out[0] = first;
            for (1..2 * run_segments + 1) |index| {
                const step: Point = if (index <= run_segments) .{ 1, 0 } else second;
                const before = out[index - 1];
                out[index] = .{ before[0] + step[0] * run_step, before[1] + step[1] * run_step };
            }
            return 2 * run_segments + 1;
        },
    }
}

/// The level a pixel sits at, between the background and white (section 3).
pub const Level = enum { dropped, once, twice };

/// The level nearest to `pixel`, by the share of the background-to-white distance it covers,
/// over the three channels together: about 0 is dropped, 0.5 is once, 0.75 is twice.
pub fn classify(pixel: [3]u8, background: [3]u8) Level {
    var covered: f32 = 0;
    var span: f32 = 0;
    for (pixel, background) |value, base| {
        covered += @as(f32, @floatFromInt(value)) - @as(f32, @floatFromInt(base));
        span += 255 - @as(f32, @floatFromInt(base));
    }
    assert(span > 0);
    const share = covered / span;
    if (share < level_dropped_max) return .dropped;
    if (share < level_twice_min) return .once;
    return .twice;
}

/// The seams of a frame's `Path` records into `out`: the first point of each record with `prev`
/// set, absolute (`rect.xy + anchor + points[first_point]`). Returns the count.
pub fn seam_points(records: []const quads.Path, points: []const Point, out: []Point) u32 {
    var count: u32 = 0;
    for (records) |record| {
        if (record.prev < 0.5) continue;
        assert(count < out.len);
        const head: usize = @intFromFloat(record.first_point);
        assert(head < points.len);
        out[count] = .{
            record.rect[0] + record.anchor_x + points[head][0],
            record.rect[1] + record.anchor_y + points[head][1],
        };
        count += 1;
    }
    return count;
}

/// The index of the seam nearest `p` within `limit` logical pixels, or null (section 3).
pub fn nearest_seam(seams: []const Point, p: Point, limit: f32) ?u32 {
    assert(limit > 0);
    var best: ?u32 = null;
    var best_distance = limit;
    for (seams, 0..) |seam, index| {
        const dx = seam[0] - p[0];
        const dy = seam[1] - p[1];
        const distance = @sqrt(dx * dx + dy * dy);
        if (distance <= best_distance) {
            best_distance = distance;
            best = @intCast(index);
        }
    }
    return best;
}

/// What one configuration counted.
const Counts = struct {
    seams: u32 = 0,
    interior: u32 = 0,
    twice: u32 = 0,
    dropped: u32 = 0,
    elsewhere: u32 = 0,
    /// Faults of section 4's class, which no seam rule removes (section 3).
    fold: u32 = 0,
    same: bool = true,

    fn faults(self: Counts) u32 {
        return self.twice + self.dropped;
    }

    fn add(self: *Counts, other: Counts) void {
        self.seams += other.seams;
        self.interior += other.interior;
        self.twice += other.twice;
        self.dropped += other.dropped;
        self.elsewhere += other.elsewhere;
        self.fold += other.fold;
        self.same = self.same and other.same;
    }

    fn bad(self: Counts) bool {
        return self.faults() > 0 or self.elsewhere > 0 or !self.same;
    }
};

var seam_list: [4096]Point = undefined;
var pixels: [window_width * window_height * scale_max * scale_max * 3]u8 = undefined;

/// Draws one shape at one width on the open device, cache on and cache off, and counts.
fn measure(shape: Shape, width: f32) !Counts {
    var counts: Counts = .{};
    const size = Off.size_px();
    const bytes = pixels[0 .. size[0] * size[1] * 3];
    var hashes: [2]u64 = undefined;
    for ([2]bool{ true, false }, 0..) |cache, which| {
        try Off.start(.{ .cache = cache });
        Off.app().* = .{ .shape = shape, .width = width };
        try Off.frame(.{ .time_ms = 0, .dt_ms = 0 });
        const frame = try Off.read(.rgb, bytes);
        hashes[which] = bench.rgb_hash(frame.bytes);
        if (cache) counts = count_frame(shape, width, frame);
    }
    counts.same = hashes[0] == hashes[1];
    return counts;
}

/// The device pixel range `[low, high)` along one axis that holds `[lo, hi]` logical pixels.
fn pixel_range(lo: f32, hi: f32, scale: u32, limit: u32) [2]u32 {
    assert(hi >= lo);
    const factor: f32 = @floatFromInt(scale);
    const first = @max(@floor(lo * factor), 0);
    const last = @min(@ceil(hi * factor), @as(f32, @floatFromInt(limit)));
    assert(last >= first);
    return .{ @intFromFloat(first), @intFromFloat(last) };
}

/// Counts one frame's faults (section 3). The frame holds the open frame's pool, so its `Path`
/// records are the seams.
fn count_frame(shape: Shape, width: f32, frame: Pixels) Counts {
    const drawn = &Off.context().draw;
    var counts: Counts = .{};
    counts.seams = seam_points(drawn.items(quads.Path), drawn.point_items(), &seam_list);
    const seams = seam_list[0..counts.seams];
    const background = background_of(frame);
    const scale = app_scale();
    const scale_f: f32 = @floatFromInt(scale);
    const half = width * 0.5;
    const interior_max = half - 0.75 / scale_f;
    var points: [points_max]Point = undefined;
    for (0..grid * grid) |copy| {
        var count = shape_points(shape, copy_origin(@intCast(copy), scale), &points);
        if (shape.kind == .ring) {
            points[count] = points[0];
            count += 1;
        }
        if (shape.kind == .polyline) assert(path.chunk_end(points[0..count], 0, width) == run_segments);
        const box = bounds(points[0..count], half + 1);
        const columns = pixel_range(box[0], box[2], scale, frame.width);
        const rows = pixel_range(box[1], box[3], scale, frame.height);
        var y = rows[0];
        while (y < rows[1]) : (y += 1) {
            var x = columns[0];
            while (x < columns[1]) : (x += 1) {
                const p: Point = .{
                    (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(scale)),
                    (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(scale)),
                };
                if (path.distance_to_polyline(points[0..count], p[0], p[1]) > interior_max) {
                    continue;
                }
                counts.interior += 1;
                const at = (y * frame.width + x) * 3;
                const level = classify(frame.bytes[at..][0..3].*, background);
                if (level == .once) continue;
                if (shape.kind == .polyline and fold_at(points[0..count], p, half + 1 / scale_f)) {
                    counts.fold += 1;
                } else if (nearest_seam(seams, p, width + attribution_margin) == null) {
                    counts.elsewhere += 1;
                } else switch (level) {
                    .twice => counts.twice += 1,
                    .dropped => counts.dropped += 1,
                    .once => unreachable,
                }
            }
        }
    }
    assert(counts.interior > 0 or interior_max <= 0);
    return counts;
}

/// True when `p` is within `reach` of both runs of a polyline of two runs, and the nearest
/// segment of each run is not the one at the seam (`run_segments - 1` and `run_segments`): two
/// parts of the path more than one segment apart across the seam both claim the pixel, which the
/// seam rule leaves (`draw/path.zig`, section 4). Reported as `fold`.
pub fn fold_at(points: []const Point, p: Point, reach: f32) bool {
    assert(points.len == 2 * run_segments + 1);
    var near_first: f32 = std.math.floatMax(f32);
    var near_second: f32 = std.math.floatMax(f32);
    var at_first: u32 = 0;
    var at_second: u32 = 0;
    for (0..2 * run_segments) |index| {
        const a = points[index];
        const b = points[index + 1];
        const distance = quads.sdf_segment(p[0], p[1], a[0], a[1], b[0], b[1]);
        if (index < run_segments) {
            // Ties go to the segment nearest the seam.
            if (distance <= near_first) {
                near_first = distance;
                at_first = @intCast(index);
            }
        } else if (distance < near_second) {
            near_second = distance;
            at_second = @intCast(index);
        }
    }
    assert(at_first < run_segments);
    assert(at_second >= run_segments);
    if (near_first > reach or near_second > reach) return false;
    return at_first + 2 <= run_segments and at_second > run_segments;
}

/// The frame's background: its first pixel, which no shape reaches (the four corners agree).
fn background_of(frame: Pixels) [3]u8 {
    const row = frame.width * 3;
    const last = frame.height - 1;
    const corner = frame.bytes[0..3].*;
    assert(std.mem.eql(u8, &corner, frame.bytes[row - 3 ..][0..3]));
    assert(std.mem.eql(u8, &corner, frame.bytes[last * row ..][0..3]));
    assert(std.mem.eql(u8, &corner, frame.bytes[(last + 1) * row - 3 ..][0..3]));
    return corner;
}

/// The box of `points` grown by `margin`, as `{ x0, y0, x1, y1 }`.
fn bounds(points: []const Point, margin: f32) [4]f32 {
    assert(points.len >= 2);
    var box: [4]f32 = .{ points[0][0], points[0][1], points[0][0], points[0][1] };
    for (points[1..]) |point| {
        box = .{
            @min(box[0], point[0]),
            @min(box[1], point[1]),
            @max(box[2], point[0]),
            @max(box[3], point[1]),
        };
    }
    return .{ box[0] - margin, box[1] - margin, box[2] + margin, box[3] + margin };
}

const Pixels = patchwork.host.offscreen.Pixels;

const Options = struct {
    adapters: []const bench.Adapter,
    scales: []const u32,
    strict: bool,
};

const both = [_]bench.Adapter{ .high, .low };

fn parse(args: *std.process.Args.Iterator) ?Options {
    var options: Options = .{ .adapters = &both, .scales = &scales, .strict = false };
    var guard: u32 = 0;
    while (args.next()) |arg| : (guard += 1) {
        assert(guard < 64);
        if (std.mem.eql(u8, arg, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, arg, "--adapter")) {
            const name = args.next() orelse return null;
            if (std.mem.eql(u8, name, "both")) continue;
            const adapter = std.meta.stringToEnum(bench.Adapter, name) orelse return null;
            if (adapter == .default) return null;
            options.adapters = adapter_list[@backingInt(adapter)..][0..1];
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const text = args.next() orelse return null;
            const value = std.fmt.parseInt(u32, text, 10) catch return null;
            if (value < 1 or value > scale_max) return null;
            options.scales = scales[value - 1 ..][0..1];
        } else {
            return null;
        }
    }
    return options;
}

/// `both` indexed by `bench.Adapter`'s values (`default` is a placeholder no one asks for).
const adapter_list = [_]bench.Adapter{ .default, .low, .high };

fn usage() u8 {
    std.debug.print("usage: seams [--adapter high|low|both] [--scale 1|2|3] [--strict]\n", .{});
    return 2;
}

fn print_line(adapter: bench.Adapter, scale: u32, shape: Shape, width: f32, counts: Counts) void {
    var name_buffer: [32]u8 = undefined;
    const name = switch (shape.kind) {
        .ring => std.fmt.bufPrint(&name_buffer, "ring n={d}", .{shape.points}),
        .polyline => std.fmt.bufPrint(&name_buffer, "polyline turn={d}", .{shape.turn}),
    } catch unreachable;
    const per_seam = rate(counts.faults(), counts.seams);
    std.debug.print(
        "seams {s} scale={d} {s} width={d} seams={d} interior={d} twice={d} dropped={d} " ++
            "per_seam={d:.4} elsewhere={d} fold={d} cache={s}\n",
        .{
            @tagName(adapter),              scale,          name,
            @as(u32, @intFromFloat(width)), counts.seams,   counts.interior,
            counts.twice,                   counts.dropped, per_seam,
            counts.elsewhere,               counts.fold,    if (counts.same) "same" else "differs",
        },
    );
}

fn rate(faults: u32, seams: u32) f32 {
    if (seams == 0) return 0;
    return @as(f32, @floatFromInt(faults)) / @as(f32, @floatFromInt(seams));
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    const options = parse(&args) orelse return usage();
    var any_bad = false;
    for (options.adapters) |adapter| {
        for (options.scales) |scale| {
            var total: Counts = .{};
            try Off.open(.{
                .adapter = adapter,
                .width = window_width,
                .height = window_height,
                .scale_120 = scale * 120,
            });
            defer Off.close();
            scale_open = scale;
            for (shapes) |shape| {
                for (widths) |width| {
                    const counts = try measure(shape, width);
                    print_line(adapter, scale, shape, width, counts);
                    total.add(counts);
                }
            }
            std.debug.print(
                "seams {s} scale={d} summary seams={d} interior={d} twice={d} dropped={d} " ++
                    "per_seam={d:.4} elsewhere={d} fold={d} cache={s}\n",
                .{
                    @tagName(adapter),                     scale,           total.seams,
                    total.interior,                        total.twice,     total.dropped,
                    rate(total.faults(), total.seams),     total.elsewhere, total.fold,
                    if (total.same) "same" else "differs",
                },
            );
            any_bad = any_bad or total.bad();
        }
    }
    return if (options.strict and any_bad) 1 else 0;
}

const testing = std.testing;

// Locks the three levels over a background of (28, 31, 41): the background is dropped, the
// middle of the way to white (142, 143, 148) is once, and three quarters of the way (199, 199,
// 201) is twice; the midpoints go to the nearer level, a share of 0.25 to once and 0.625 to twice.
test "a pixel classifies as the nearest of three levels" {
    const background: [3]u8 = .{ 28, 31, 41 };
    try testing.expectEqual(Level.dropped, classify(.{ 28, 31, 41 }, background));
    try testing.expectEqual(Level.once, classify(.{ 142, 143, 148 }, background));
    try testing.expectEqual(Level.twice, classify(.{ 199, 199, 201 }, background));
    // 255 - 28 = 227 and so on: the share is 0.25 at 85, 88, 95 and 0.625 at 170, 172, 176.
    try testing.expectEqual(Level.once, classify(.{ 85, 88, 95 }, background));
    try testing.expectEqual(Level.dropped, classify(.{ 84, 87, 94 }, background));
    try testing.expectEqual(Level.twice, classify(.{ 170, 172, 176 }, background));
    try testing.expectEqual(Level.once, classify(.{ 169, 171, 175 }, background));
}

// Locks the attribution on a hand-made pair of records: the second of two chunks has `prev` set,
// so its first point, (10, 5) + anchor (-1, 2) + stored (1, 3) = (10, 10) of an origin 0, is the
// one seam; a pixel 3 px away is its, one 12 px away is no seam's, and the first record's
// own first point is not a seam.
test "a seam is the first point of a record with prev set" {
    var first = std.mem.zeroes(quads.Path);
    first.rect = .{ 0, 0, 20, 20 };
    first.point_count = 3;
    var second = first;
    second.rect = .{ 10, 5, 20, 20 };
    second.anchor_x = -1;
    second.anchor_y = 2;
    second.first_point = 2;
    second.prev = 1;
    const points = [_]Point{ .{ 0, 0 }, .{ 4, 4 }, .{ 1, 3 } };
    var out: [4]Point = undefined;
    const count = seam_points(&.{ first, second }, &points, &out);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(Point{ 10, 10 }, out[0]);
    try testing.expectEqual(@as(?u32, 0), nearest_seam(out[0..count], .{ 13, 10 }, 5));
    try testing.expectEqual(@as(?u32, null), nearest_seam(out[0..count], .{ 22, 10 }, 5));
    const two = [2]Point{ .{ 0, 0 }, .{ 10, 0 } };
    try testing.expectEqual(@as(?u32, 1), nearest_seam(&two, .{ 8, 0 }, 5));
}

// Locks the fold: on two runs of 15 segments of 2 px, the first along +x ending at (30, 0) and the
// second turning back at 170 degrees, a point 1 px past the vertex has the seam's segments 14 and
// 15 nearest (not a fold), and a point 8 px behind it is within 3 px of segment 11 and of segment
// 19 of the second run (a fold); on a straight line the nearest segments at the vertex are 14
// and 15, so nothing folds.
test "a fold needs two segments more than one apart across the seam" {
    var buffer: [points_max]Point = undefined;
    _ = shape_points(.{ .kind = .polyline, .points = 0, .turn = 170 }, .{ 0, 0 }, &buffer);
    var points = buffer[0 .. 2 * run_segments + 1].*;
    const vertex = points[run_segments];
    try testing.expect(!fold_at(&points, .{ vertex[0] + 1, vertex[1] }, 1));
    try testing.expect(fold_at(&points, .{ vertex[0] - 8, vertex[1] + 0.5 }, 3));
    _ = shape_points(.{ .kind = .polyline, .points = 0, .turn = 0 }, .{ 0, 0 }, &buffer);
    points = buffer[0 .. 2 * run_segments + 1].*;
    try testing.expect(!fold_at(&points, .{ points[run_segments][0], points[run_segments][1] }, 3));
}

// Locks the layout: the 64 copies fill 640 by 512 logical pixels, and the copy in column 7, row 7
// is 7 / 8 of a device pixel past its cell at scale 1 and 7 / 24 at scale 3.
test "copies sit at eighths of a device pixel" {
    try testing.expectEqual(@as(u32, 640), window_width);
    try testing.expectEqual(@as(u32, 512), window_height);
    try testing.expectEqual(Point{ 0, 0 }, copy_origin(0, 1));
    try testing.expectEqual(Point{ 560.875, 448.875 }, copy_origin(63, 1));
    const last = copy_origin(63, 3);
    try testing.expectApproxEqAbs(@as(f32, 560 + 7.0 / 24.0), last[0], 1.0e-4);
    try testing.expectApproxEqAbs(@as(f32, 448 + 7.0 / 24.0), last[1], 1.0e-4);
}

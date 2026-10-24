//! Waveforms and rings: the `Waveform` and `Ring` draw types, their appender, and the zoom
//! pyramid.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Columns, Not Strokes
//! A sample view shows far more samples than pixels, so it draws one value range per pixel
//! column: the column's minimum and maximum (and its RMS), computed on the CPU and stored in
//! the context's point pool as `(min, max)` pairs. One `Waveform` quad covers the view, and its
//! fragment looks up its own column, so there is no loop and no texture, and a view of
//! `columns` columns uploads at most `8 * stride * columns` bytes, only the changed range.
//! `Pyramid` keeps that O(columns) at every zoom: it holds min, max, and sum-of-squares blocks
//! of `block_min` samples and their pairwise merges.
//!
//! ## 2. The Waveform Pixel
//! With `t = local / size`, `columns = point_count / stride`:
//! ```text
//! column = clamp(floor(t.x * columns), 0, columns - 1)
//! band   = points[first_point + column * stride]      (min, max)
//! value  = hi - t.y * (hi - lo)                       hi at the top
//! dist   = max(band.x - value, value - band.y) * size.y / (hi - lo) - 0.5
//! alpha  = clamp(0.5 - dist / fwidth(local.y), 0, 1)
//! ```
//! The half pixel keeps a silent column visible as a one-pixel line. With `stride` 2 the
//! second point of each column is `(-rms, rms)`, drawn the same way in `rms_color` over the
//! band. The edge ramps over `fwidth(local.y)` only, because a distance that jumps between
//! columns would smear across neighbors. A column count that divides the rect's width in
//! device pixels keeps every pixel center off a column edge, where GPUs may round `floor`
//! differently. The type names its points (`first_point`, `point_count`), so the pixel cache
//! keys exactly its columns (`draw/renderer.zig`, section 4a), and values are signal units,
//! never coordinates, so container shifts hold (`draw/registry.zig`, section 2).
//!
//! ## 3. The Pyramid
//! Level 0 holds blocks of `block_min` samples; level `k` merges pairs of level `k - 1`, so a
//! level-`k` block covers `block_min << k` samples. `columns` splits `count` samples from
//! `first` into `out.len` columns at integer edges `first + c * count / len` and fills each:
//! ```text
//! n >= block_min   the coarsest level whose block fits n; the blocks that touch the column,
//!                  at most three (the column may cover up to a block more on each side)
//! 1 <= n < 64      a direct scan of the column's samples
//! n == 0           the nearest sample (zoomed in past one sample per column)
//! ```
//! RMS is `sqrt(sum_sq / covered)`. Test "pyramid columns match a scan of what they cover"
//! checks every regime against a brute-force scan.
//!
//! ## 4. Rings
//! `Ring(format, Color)` is a type function for a ring texture written by
//! `textures.Ring`: the oldest column (`head`) at the left, the newest at the right. Columns
//! are read with `textureLoad`, so the newest and the oldest never blend across the seam (a
//! repeating linear sampler would), and rows interpolate linearly by hand, so every format
//! works, the unfilterable ones included:
//! ```text
//! size   = texture_size()
//! column = (head + clamp(floor(t.x * size.x), 0, size.x - 1)) mod size.x
//! y      = clamp(t.y * size.y - 0.5, 0, size.y - 1); r0 = floor(y), r1 = min(r0 + 1, last)
//! value  = mix(load(column, r0), load(column, r1), y - r0)
//! color  = ring_color(value, px)        Color.wgsl, the app's palette or bands
//! ```
//!
//! ## 5. TigerStyle Invariants
//! - The pyramid is a fixed array sized by `samples_max` at compile time; `build` and
//!   `columns` are linear and allocate nothing.
//! - `append` writes exactly `stride * columns` points and one instance, or nothing.

const std = @import("std");
const assert = std.debug.assert;
const textures = @import("textures.zig");

/// One view column: the minimum, maximum, and RMS of the samples it covers.
pub const Column = struct {
    min: f32,
    max: f32,
    rms: f32,
};

/// Samples per level-0 pyramid block.
pub const block_min: u32 = 64;

/// A min/max band per column from the point pool. See the module guide, section 2.
pub const Waveform = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    rms_color: [4]f32,
    first_point: f32,
    point_count: f32,
    /// 1: `(min, max)` per column; 2: then `(-rms, rms)`.
    stride: f32,
    lo: f32,
    hi: f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,

    pub const texture: ?textures.Format = null;
    pub const reads_points: bool = true;
    pub const pixel: []const u8 =
        \\fn wave_alpha(band: vec2<f32>, value: f32, px_per: f32, ramp: f32) -> f32 {
        \\    let dist = max(band.x - value, value - band.y) * px_per - 0.5;
        \\    return clamp(0.5 - dist / ramp, 0.0, 1.0);
        \\}
        \\
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let t = px.local / px.size;
        \\    let stride = u32(px.stride + 0.5);
        \\    let columns = u32(px.point_count + 0.5) / stride;
        \\    let column = min(u32(max(floor(t.x * f32(columns)), 0.0)), columns - 1u);
        \\    let at = u32(px.first_point + 0.5) + column * stride;
        \\    let value = px.hi - t.y * (px.hi - px.lo);
        \\    let px_per = px.size.y / (px.hi - px.lo);
        \\    let ramp = max(fwidth(px.local.y), 1.0e-5);
        \\    let rms_on = stride == 2u;
        \\    let a_band = wave_alpha(points[at], value, px_per, ramp) * px.color.a;
        \\    let a_rms = select(0.0, wave_alpha(points[at + select(0u, 1u, rms_on)], value,
        \\        px_per, ramp) * px.rms_color.a, rms_on);
        \\    let a = a_rms + a_band * (1.0 - a_rms);
        \\    let mixed = px.rms_color.rgb * a_rms + px.color.rgb * a_band * (1.0 - a_rms);
        \\    return vec4<f32>(select(px.color.rgb, mixed / max(a, 1.0e-5), a > 0.0), a);
        \\}
        \\
    ;
};

/// How `append` draws its columns.
pub const Style = struct {
    color: [4]f32,
    /// The RMS band's color, or null for no RMS band (stride 1).
    rms_color: ?[4]f32,
    /// The value range mapped to the rect; `hi` at the top.
    lo: f32 = -1,
    hi: f32 = 1,
};

/// Writes `columns` into the point pool and appends one `Waveform` over `rect`. Returns false,
/// writing nothing, when the pool, the points, or the batches are full (counted in
/// `overflow_count`).
pub fn append(
    cx: anytype,
    rect: [4]f32,
    clip: [4]f32,
    columns: []const Column,
    style: Style,
) bool {
    assert(columns.len >= 1);
    assert(style.hi > style.lo);
    const stride: u32 = if (style.rms_color == null) 1 else 2;
    const count: u32 = @intCast(columns.len * stride);
    if (cx.room(Waveform) == 0) {
        cx.refuse();
        return false;
    }
    const first = cx.reserve_points(count) orelse return false;
    const stored = cx.points[first..][0..count];
    for (columns, 0..) |column, index| {
        assert(column.min <= column.max);
        stored[index * stride] = .{ column.min, column.max };
        if (stride == 2) stored[index * stride + 1] = .{ -column.rms, column.rms };
    }
    cx.append(Waveform, null, .{
        .rect = rect,
        .clip = clip,
        .color = style.color,
        .rms_color = style.rms_color orelse .{ 0, 0, 0, 0 },
        .first_point = @floatFromInt(first),
        .point_count = @floatFromInt(count),
        .stride = @floatFromInt(stride),
        .lo = style.lo,
        .hi = style.hi,
        .pad0 = 0,
        .pad1 = 0,
        .pad2 = 0,
    }) catch |err| switch (err) {
        error.BatchFull => {
            cx.release_points(first);
            return false;
        },
        error.PoolFull, error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
    return true;
}

/// One pyramid block: the min, max, and sum of squares of the samples it covers.
pub const Block = struct {
    min: f32,
    max: f32,
    sum_sq: f32,

    fn merge(a: Block, b: Block) Block {
        return .{ .min = @min(a.min, b.min), .max = @max(a.max, b.max), .sum_sq = a.sum_sq + b.sum_sq };
    }
};

/// Min, max, and RMS levels for up to `samples_max` samples (module guide, section 3).
pub fn Pyramid(comptime samples_max: u32) type {
    const level0: u32 = std.math.divCeil(u32, samples_max, block_min) catch unreachable;
    const plan = comptime blk: {
        var counts: [32]u32 = undefined;
        var total: u32 = 0;
        var levels: u32 = 0;
        var blocks = level0;
        while (true) {
            counts[levels] = blocks;
            total += blocks;
            levels += 1;
            if (blocks == 1) break;
            blocks = (blocks + 1) / 2;
        }
        break :blk .{ .total = total, .levels = levels };
    };
    return struct {
        const Self = @This();
        pub const level_cap: u32 = plan.levels;

        blocks: [plan.total]Block,
        /// Index of each level's first block in `blocks`, and its block count.
        offsets: [plan.levels]u32,
        counts: [plan.levels]u32,
        level_count: u32,
        sample_count: u32,

        /// Builds every level from `samples` in one pass per level.
        pub fn build(self: *Self, samples: []const f32) void {
            assert(samples.len >= 1);
            assert(samples.len <= samples_max);
            self.sample_count = @intCast(samples.len);
            var blocks: u32 = std.math.divCeil(u32, self.sample_count, block_min) catch unreachable;
            var offset: u32 = 0;
            for (0..blocks) |index| {
                const start = index * block_min;
                const end = @min(start + block_min, self.sample_count);
                self.blocks[index] = scan(samples[start..end]);
            }
            self.level_count = 0;
            while (true) {
                self.offsets[self.level_count] = offset;
                self.counts[self.level_count] = blocks;
                self.level_count += 1;
                if (blocks == 1) break;
                const next = (blocks + 1) / 2;
                const below = self.blocks[offset..][0..blocks];
                const above = self.blocks[offset + blocks ..][0..next];
                for (above, 0..) |*block, index| {
                    const left = below[2 * index];
                    block.* = if (2 * index + 1 < blocks) left.merge(below[2 * index + 1]) else left;
                }
                offset += blocks;
                blocks = next;
            }
            assert(self.level_count <= level_cap);
        }

        /// Fills `out` with columns over `count` samples from `first` (module guide, 3).
        pub fn columns(
            self: *const Self,
            samples: []const f32,
            first: u32,
            count: u32,
            out: []Column,
        ) void {
            assert(samples.len == self.sample_count);
            assert(out.len >= 1);
            assert(count >= 1);
            assert(first + count <= self.sample_count);
            const len: u64 = out.len;
            for (out, 0..) |*slot, index| {
                const s0: u32 = first + @as(u32, @intCast(index * @as(u64, count) / len));
                const s1: u32 = first + @as(u32, @intCast((index + 1) * @as(u64, count) / len));
                slot.* = self.column(samples, s0, s1);
            }
        }

        /// The column over samples `[s0, s1)`.
        pub fn column(self: *const Self, samples: []const f32, s0: u32, s1: u32) Column {
            assert(s0 <= s1);
            assert(s1 <= self.sample_count);
            const n = s1 - s0;
            if (n == 0) {
                const value = samples[@min(s0, self.sample_count - 1)];
                return .{ .min = value, .max = value, .rms = @abs(value) };
            }
            if (n < block_min) return to_column(scan(samples[s0..s1]), n);
            var level: u32 = 0;
            while (level + 1 < self.level_count and (block_min << @intCast(level + 1)) <= n) {
                level += 1;
            }
            const side = block_min << @intCast(level);
            const b0 = s0 / side;
            const b1 = std.math.divCeil(u32, s1, side) catch unreachable;
            assert(b1 - b0 <= 3);
            const row = self.blocks[self.offsets[level]..][0..self.counts[level]];
            var merged = row[b0];
            for (row[b0 + 1 .. b1]) |block| merged = merged.merge(block);
            const covered = @min(b1 * side, self.sample_count) - b0 * side;
            return to_column(merged, covered);
        }
    };
}

fn scan(samples: []const f32) Block {
    assert(samples.len >= 1);
    var block: Block = .{ .min = samples[0], .max = samples[0], .sum_sq = 0 };
    for (samples) |value| {
        block.min = @min(block.min, value);
        block.max = @max(block.max, value);
        block.sum_sq += value * value;
    }
    return block;
}

fn to_column(block: Block, covered: u32) Column {
    assert(covered >= 1);
    const rms = @sqrt(block.sum_sq / @as(f32, @floatFromInt(covered)));
    return .{ .min = block.min, .max = block.max, .rms = rms };
}

/// A ring texture view (module guide, section 4). `Color` declares
/// `pub const wgsl: []const u8` holding `fn ring_color(value: vec4<f32>, px: Pixel) ->
/// vec4<f32>`; `tint` is free for it to use.
pub fn Ring(comptime format: textures.Format, comptime Color: type) type {
    return extern struct {
        rect: [4]f32,
        clip: [4]f32,
        tint: [4]f32,
        /// The oldest column, shown at the left: `textures.Ring.head`.
        head: f32,
        pad0: f32,
        pad1: f32,
        pad2: f32,

        pub const texture: ?textures.Format = format;
        pub const pixel: []const u8 = Color.wgsl ++
            \\
            \\fn pixel(px: Pixel) -> vec4<f32> {
            \\    let t = px.local / px.size;
            \\    let size = texture_size();
            \\    let step = clamp(i32(floor(t.x * f32(size.x))), 0, size.x - 1);
            \\    let column = (i32(px.head + 0.5) + step) % size.x;
            \\    let y = clamp(t.y * f32(size.y) - 0.5, 0.0, f32(size.y - 1));
            \\    let r0 = i32(floor(y));
            \\    let r1 = min(r0 + 1, size.y - 1);
            \\    let value = mix(load_texture(vec2<i32>(column, r0)),
            \\        load_texture(vec2<i32>(column, r1)), y - f32(r0));
            \\    return ring_color(value, px);
            \\}
            \\
        ;
    };
}

const testing = std.testing;
const pools = @import("pools.zig");
const registry = @import("registry.zig");

/// A brute-force column over `[s0, s1)`.
fn brute(samples: []const f32, s0: u32, s1: u32) Column {
    return to_column(scan(samples[s0..s1]), s1 - s0);
}

// Locks the pyramid (section 3) on 10,000 samples of a deterministic signal: level 0 holds
// ceil(10000 / 64) = 157 blocks and each level halves up to one; a column of n >= 64 samples
// equals a scan of the whole blocks it touches (at most three), a column of fewer equals a
// scan of exactly its samples, and a column of none is its nearest sample.
test "pyramid columns match a scan of what they cover" {
    const static = struct {
        var samples: [10_000]f32 = undefined;
        var pyramid: Pyramid(10_000) = undefined;
    };
    var state: u32 = 0x1234_5678;
    for (&static.samples, 0..) |*sample, index| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        const noise = @as(f32, @floatFromInt(state >> 8)) / 16_777_216.0 - 0.5;
        sample.* = 0.6 * @sin(@as(f32, @floatFromInt(index)) * 0.01) + 0.3 * noise;
    }
    const p = &static.pyramid;
    p.build(&static.samples);
    try testing.expectEqual(@as(u32, 157), p.counts[0]);
    try testing.expectEqual(@as(u32, 79), p.counts[1]);
    try testing.expectEqual(@as(u32, 1), p.counts[p.level_count - 1]);
    var out: [100]Column = undefined;
    p.columns(&static.samples, 0, 10_000, &out);
    for (out, 0..) |column, index| {
        const s0: u32 = @intCast(index * 100);
        const s1: u32 = s0 + 100;
        const side: u32 = 64;
        const covered = brute(&static.samples, s0 / side * side, @min(10_000, (s1 + side - 1) / side * side));
        try testing.expectEqual(covered.min, column.min);
        try testing.expectEqual(covered.max, column.max);
        try testing.expectApproxEqAbs(covered.rms, column.rms, 1e-5);
    }
    var fine: [10]Column = undefined;
    p.columns(&static.samples, 500, 300, &fine);
    try testing.expectEqual(brute(&static.samples, 530, 560), fine[1]);
    var zoomed: [8]Column = undefined;
    p.columns(&static.samples, 40, 4, &zoomed);
    try testing.expectEqual(static.samples[40], zoomed[0].min);
    try testing.expectEqual(static.samples[40], zoomed[1].max);
    try testing.expectEqual(static.samples[41], zoomed[2].min);
    const whole = p.column(&static.samples, 0, 10_000);
    try testing.expectEqual(brute(&static.samples, 0, 10_000).max, whole.max);
}

const test_draw = [_]registry.DrawType{.{ .type = Waveform, .cap = 2 }};
const TestContext = pools.Context(&test_draw, 4, 64);

// Locks the appender (section 2): with RMS, two points per column, `(min, max)` then
// `(-rms, rms)`, and the instance's range and stride; without, one point per column; and a
// view that does not fit the points writes nothing.
test "append writes one or two points per column and one instance" {
    const static = struct {
        var cx: TestContext = undefined;
    };
    const cx = &static.cx;
    cx.init();
    const columns = [_]Column{
        .{ .min = -0.5, .max = 0.25, .rms = 0.2 },
        .{ .min = 0, .max = 0, .rms = 0 },
    };
    const clip: [4]f32 = .{ 0, 0, 100, 100 };
    const style: Style = .{ .color = .{ 1, 1, 1, 1 }, .rms_color = .{ 1, 0, 0, 1 } };
    try testing.expect(append(cx, .{ 0, 0, 2, 10 }, clip, &columns, style));
    try testing.expectEqualSlices([2]f32, &.{ .{ -0.5, 0.25 }, .{ -0.2, 0.2 }, .{ 0, 0 }, .{ 0, 0 } }, cx.point_items());
    const wave = cx.items(Waveform)[0];
    try testing.expectEqual(@as(f32, 4), wave.point_count);
    try testing.expectEqual(@as(f32, 2), wave.stride);
    try testing.expectEqual(@as(f32, -1), wave.lo);
    try testing.expect(append(cx, .{ 0, 20, 2, 10 }, clip, &columns, .{ .color = .{ 1, 1, 1, 1 }, .rms_color = null }));
    try testing.expectEqual(@as(f32, 4), cx.items(Waveform)[1].first_point);
    try testing.expectEqual(@as(f32, 1), cx.items(Waveform)[1].stride);
    try testing.expectEqual(@as(usize, 6), cx.point_items().len);
    var many: [40]Column = @splat(.{ .min = 0, .max = 0, .rms = 0 });
    cx.reset();
    try testing.expect(!append(cx, .{ 0, 0, 40, 10 }, clip, &many, style));
    try testing.expectEqual(@as(usize, 0), cx.point_items().len);
}

const TestColor = struct {
    pub const wgsl: []const u8 =
        \\fn ring_color(value: vec4<f32>, px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(value.rrr, 1.0) * px.tint;
        \\}
    ;
};

// Locks the generated interfaces: Waveform reads points and names its range; a Ring of an
// unfilterable format checks against the convention, loads its texels, and calls the app's
// `ring_color`.
test "waveform and ring types assemble" {
    try testing.expect(comptime registry.check(Waveform) == null);
    try testing.expect(comptime registry.reads_points(Waveform));
    const RingType = Ring(.r32float, TestColor);
    try testing.expect(comptime registry.check(RingType) == null);
    const text = comptime registry.source(RingType);
    try testing.expect(std.mem.find(u8, text, "fn ring_color(value: vec4<f32>, px: Pixel)") != null);
    try testing.expect(std.mem.find(u8, text, "load_texture(vec2<i32>(column, r0))") != null);
    try testing.expect(std.mem.find(u8, text, "px.head = v.g3.x;") != null);
    try testing.expectEqual(@as(usize, 64), @sizeOf(RingType));
    try testing.expectEqual(@as(usize, 96), @sizeOf(Waveform));
}

comptime {
    assert(@sizeOf(Waveform) == 96);
    assert(@offsetOf(Waveform, "first_point") == 64);
    assert(block_min == 64);
}

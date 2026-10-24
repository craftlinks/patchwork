//! The drawing namespace: projection, the unit quad, uploads, and the draw type modules.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Instanced Unit Quads Instead of Immediate Geometry
//! Nearly every UI element is an axis-aligned rectangle. Rebuilding four to six vertices per
//! rectangle on the CPU each frame costs CPU time, allocator churn, and upload bandwidth that
//! grows with the rectangle count. Instead, one static unit quad (`unit_quad`, uploaded once)
//! is expanded in the vertex shader by per-instance records. The vertex fetch unit advances
//! the quad attributes per vertex and the instance attributes per instance, so a batch of
//! records is one draw call of `vertex_count` vertices times its instance count.
//!
//! ## 2. Module Map
//! ```text
//! draw/registry.zig   DrawType, the instance convention check, WGSL assembly, layouts
//! draw/prelude.wgsl   vs_main, fs_main, coverage, clip_mask, sdf_* shared by every type
//! draw/types.zig      Box, Arc, Glyph, Image, Path, AppendError, and the CPU distance twins
//! draw/pools.zig      Context: per-type pools, the point pool, layers, sort, sticky batches
//! draw/path.zig       stroked paths: flattening, chunking, twins, and the appenders
//! draw/wave.zig       Waveform and Ring types, the waveform appender, the zoom pyramid
//! draw/fx.zig         offscreen targets: device rects, projection, Composite and Blur
//! draw/textures.zig   Textures: queued creates and writes, TextureId, Format
//! draw/renderer.zig   Renderer: records setup and frames from a Context
//! ```
//! This file re-exports the public names so apps and widgets write `draw.Box`,
//! `draw.Context`, and so on. It also owns the plain geometry types `Rect` and `Inset`,
//! which layout (`ui/turtle.zig`), text placement, and hit areas share, so text depends on
//! drawing only and never on the UI layer.
//!
//! ## 3. Y-Down Orthographic Projection
//! Coordinate spaces:
//! - **UI logical pixels:** origin at the top-left of the window, `+X` right in `[0, w]`,
//!   `+Y` down in `[0, h]`.
//! - **WebGPU NDC:** `X` in `[-1, +1]` left to right, `Y` in `[-1, +1]` bottom to top (Y-up),
//!   `Z` in `[0, 1]` near to far.
//!
//! `w` and `h` are the device extent in logical pixels, `w = width_px * 120 / scale_120`, not
//! the integer logical window size. The framebuffer is `width_px = round(width_logical * s)`
//! device pixels, so with `s = scale_120 / 120` the projection maps logical `x` to device
//! pixel `x * s` exactly, and a quad whose logical edges are multiples of `1 / s` (snapped
//! glyphs, `text/layout.zig`) lands on device pixel edges even when the rounding of
//! `width_px` makes `width_px / width_logical` differ from `s`.
//!
//! The linear maps are fixed by the corner constraints `f(0) = -1, f(w) = +1` for X and
//! `g(0) = +1, g(h) = -1` for Y (the flip), with depth pinned at `z = 0`:
//! ```text
//! X_ndc = (2 / w) * x - 1
//! Y_ndc = -(2 / h) * y + 1
//! ```
//! As a column-major 4x4 `M` applied to the column vector `[x, y, 0, 1]`, matching WGSL
//! `mat4x4<f32>` memory order, the 16 floats are written column by column:
//! ```text
//! col 0: [ 2/w,   0, 0, 0 ]      col 2: [  0, 0, 1, 0 ]
//! col 1: [   0, -2/h, 0, 0 ]     col 3: [ -1, 1, 0, 1 ]
//! ```
//! Worked values: see tests "ortho maps the four corners and the center" and "ortho maps
//! logical pixels to device pixels at a fractional scale".
//!
//! ## 4. Uniform Size
//! The frame uniform holds the projection matrix, the time slot (`time_offset`, read by
//! animated draw types), and `theme.Theme`; `uniform_bytes` is their sum, enforced by the `comptime` block below. WebGPU requires dynamic uniform
//! offsets to be multiples of the `minUniformBufferOffsetAlignment` limit (WebGPU "Limits"
//! table, default 256). The buffer size is kept a multiple of that limit so the record stays
//! valid if it is ever bound at an offset. `draw/renderer.zig` owns the record and its uploads.
//!
//! ## 5. Dirty Ranges
//! `dirty_range` returns the smallest record range `[first, end)` that covers every record
//! of `new` that differs from `old` at the same index, plus every record past `old.len`.
//! A shrunk list needs no write: the draw count bounds what the GPU reads. Comparison is by
//! bytes, so it is exact and never misses a change. The renderer runs it per pool against a
//! shadow of the last upload; see `draw/renderer.zig`, section 4.
//!
//! ## 6. TigerStyle Invariants
//! - Layout facts are `comptime` asserts, so an ABI mismatch with WGSL or the web shell fails
//!   the build.
//! - Every pool, shadow, and batch list is a fixed array sized at compile time.

const std = @import("std");
const assert = std.debug.assert;
const theme = @import("theme.zig");
const registry = @import("draw/registry.zig");
const pools = @import("draw/pools.zig");
const textures_module = @import("draw/textures.zig");
const types = @import("draw/types.zig");

/// Stroked paths: `path.cubic`, `path.polyline`, `path.plot`, and their CPU twins.
pub const path = @import("draw/path.zig");

/// Offscreen effects: target device rects, `fx.composite`, `fx.blur`, and their types.
pub const fx = @import("draw/fx.zig");

/// Waveforms and rings: `wave.append`, `wave.Pyramid`, and the `Waveform` and `Ring` types.
pub const wave = @import("draw/wave.zig");

/// Exclusive-max clip in logical pixels, copied into every instance's `clip`. `x1 > x0` and
/// `y1 > y0`, all finite.
pub const Clip = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// Axis-aligned box in UI logical pixels. `(x, y)` is the top-left corner. Layout
/// (`ui/turtle.zig`), text placement, hit areas, and widgets share it.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Independent insets in UI logical pixels: container padding and child margins.
pub const Inset = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

pub const DrawType = registry.DrawType;
pub const Registry = registry.Registry;
pub const Context = pools.Context;
pub const Layer = pools.Layer;
pub const Batch = pools.Batch;
pub const layer_count = pools.layer_count;
pub const Textures = textures_module.Textures;
pub const TextureId = textures_module.TextureId;
pub const TextureFormat = textures_module.Format;
pub const TextureSampling = textures_module.Sampling;
/// A ring texture with a write head; `draw.Ring` shows it.
pub const TextureRing = textures_module.Ring;
/// How a draw type's output blends into the target (`draw/registry.zig`, section 2c).
pub const Blend = @import("gpu/commands.zig").Blend;
pub const TextureRegion = textures_module.Region;
pub const AppendError = types.AppendError;
pub const Box = types.Box;
pub const Arc = types.Arc;
pub const Glyph = types.Glyph;
pub const Image = types.Image;
pub const Path = types.Path;
pub const Waveform = wave.Waveform;
pub const Ring = wave.Ring;
pub const Composite = fx.Composite;
pub const Blur = fx.Blur;
pub const TargetKind = textures_module.TargetKind;
pub const Point = pools.Point;
pub const point_cap_max = pools.point_cap_max;
pub const sdf_box = types.sdf_box;
pub const sdf_segment = types.sdf_segment;
pub const sdf_arc = types.sdf_arc;
pub const contains_box = types.contains_box;
/// Null when a type satisfies the draw type convention, else a message naming it.
pub const check_type = registry.check;
/// The assembled WGSL module of a draw type, for tests of app-defined types.
pub const type_source = registry.source;

/// Vertices in the unit quad drawn as a triangle list. Asserted equal to `unit_quad.len / 2`.
pub const vertex_count: u32 = 6;

/// Byte size of the unit quad vertex buffer. Asserted equal to `@sizeOf` of `unit_quad`.
pub const quad_bytes: u32 = 48;

/// Byte size of one `mat4x4<f32>`. Asserted equal to `@sizeOf([16]f32)`.
pub const matrix_bytes: u32 = 64;

/// WebGPU `minUniformBufferOffsetAlignment` default (WebGPU "Limits" table).
const min_uniform_offset_alignment: u32 = 256;

/// Byte size of the frame uniform's time slot, one `vec4<f32>` whose `x` is the animation time
/// in seconds (`animator.Time`).
pub const time_bytes: u32 = 16;

/// Offset of the time slot: right after the projection, so it does not move with the theme.
pub const time_offset: u32 = matrix_bytes;

/// Offset of `theme.Theme` in the frame uniform.
pub const theme_offset: u32 = time_offset + time_bytes;

/// Byte size of the frame uniform: the projection matrix, the time slot, and `theme.Theme`.
/// Asserted to equal their sum and to be a multiple of `min_uniform_offset_alignment`.
pub const uniform_bytes: u32 = 256;

/// Two triangles covering the unit square, as flat `[x, y]` pairs drawn as a triangle list
/// without an index buffer. The winding is clockwise on screen after the projection's Y flip,
/// which is harmless because every pipeline disables face culling.
pub const unit_quad: [12]f32 = .{
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    0.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
};

/// A record range `[first, end)` to upload; `end > first`.
pub const Range = struct {
    first: u32,
    end: u32,
};

/// The smallest range covering every record of `new` that differs from `old` at the same
/// index, plus every record of `new` past `old.len`. Null when there is none, including when
/// `new` is a prefix of `old`. Records compare by bytes.
pub fn dirty_range(comptime T: type, old: []const T, new: []const T) ?Range {
    assert(old.len <= std.math.maxInt(u32));
    assert(new.len <= std.math.maxInt(u32));
    const shared: u32 = @intCast(@min(old.len, new.len));
    const count: u32 = @intCast(new.len);
    var first: u32 = 0;
    while (first < shared) : (first += 1) {
        if (!same_record(T, &old[first], &new[first])) break;
    }
    if (first == count) {
        return null;
    }
    // A grown list always writes through its new count; otherwise trim unchanged records off
    // the back of the shared prefix.
    var end: u32 = count;
    if (count <= shared) {
        while (end > first + 1) : (end -= 1) {
            if (!same_record(T, &old[end - 1], &new[end - 1])) break;
        }
    }
    assert(first < end);
    assert(end <= count);
    return .{ .first = first, .end = end };
}

fn same_record(comptime T: type, a: *const T, b: *const T) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Writes the column-major projection from top-left, Y-down logical pixels to WebGPU NDC for
/// a `width_px` by `height_px` framebuffer at `scale_120`. The derivation, including why the
/// extent comes from the device size, is in the module guide.
pub fn ortho_y_down(out: *[16]f32, width_px: u32, height_px: u32, scale_120: u32) void {
    assert(width_px != 0);
    assert(height_px != 0);
    assert(scale_120 != 0);
    const scale = @as(f32, @floatFromInt(scale_120)) / 120;
    const w = @as(f32, @floatFromInt(width_px)) / scale;
    const h = @as(f32, @floatFromInt(height_px)) / scale;
    out.* = .{
        2.0 / w, 0.0,      0.0, 0.0,
        0.0,     -2.0 / h, 0.0, 0.0,
        0.0,     0.0,      1.0, 0.0,
        -1.0,    1.0,      0.0, 1.0,
    };
    assert(out[0] > 0);
    assert(out[5] < 0);
}

comptime {
    assert(quad_bytes == @sizeOf(@TypeOf(unit_quad)));
    assert(unit_quad.len == 2 * vertex_count);
    assert(matrix_bytes == @sizeOf([16]f32));
    assert(matrix_bytes + time_bytes + theme.bytes == uniform_bytes);
    assert(theme_offset + theme.bytes == uniform_bytes);
    assert(uniform_bytes % min_uniform_offset_alignment == 0);
    // The relations above hold for any consistent change; these pin the values the hosts
    // and the tests rely on, so changing one without the others fails the build.
    assert(quad_bytes == 48);
    assert(vertex_count == 6);
    assert(matrix_bytes == 64);
    assert(time_offset == 64);
    assert(uniform_bytes == 256);
    // Layout geometry is four packed `f32`s, so a `Rect` copies like one instance field.
    assert(@sizeOf(Rect) == 16);
    assert(@sizeOf(Inset) == 16);
    assert(@alignOf(Rect) == 4);
}

test {
    _ = registry;
    _ = pools;
    _ = textures_module;
    _ = types;
    _ = path;
    _ = wave;
    _ = fx;
    _ = @import("draw/tiles.zig");
}

fn project(matrix: [16]f32, x: f32, y: f32) [2]f32 {
    const nx = matrix[0] * x + matrix[4] * y + matrix[12];
    const ny = matrix[1] * x + matrix[5] * y + matrix[13];
    return .{ nx, ny };
}

// Locks the projection: the four logical corners map to the NDC corners with Y flipped, and the
// center maps to the origin.
test "ortho maps the four corners and the center" {
    var matrix: [16]f32 = undefined;
    ortho_y_down(&matrix, 200, 100, 120);
    const top_left = project(matrix, 0, 0);
    const top_right = project(matrix, 200, 0);
    const bottom_left = project(matrix, 0, 100);
    const bottom_right = project(matrix, 200, 100);
    const center = project(matrix, 100, 50);
    try std.testing.expectApproxEqAbs(@as(f32, -1), top_left[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_left[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_right[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_right[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_left[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_left[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), bottom_right[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_right[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), center[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), center[1], 0.0001);
}

// Locks the device extent: at scale 1.5 a 1601 px framebuffer (the rounding of 1067.33
// logical) puts logical x = 2 at device pixel 3 and the right edge at NDC +1, so a quad edge
// at a multiple of 1 / 1.5 logical pixels lands on a device pixel edge.
test "ortho maps logical pixels to device pixels at a fractional scale" {
    var matrix: [16]f32 = undefined;
    ortho_y_down(&matrix, 1601, 900, 180);
    const two = project(matrix, 2, 0);
    const device_x = (two[0] + 1) * 0.5 * 1601;
    try std.testing.expectApproxEqAbs(@as(f32, 3), device_x, 0.001);
    const right = project(matrix, 1601.0 / 1.5, 600);
    try std.testing.expectApproxEqAbs(@as(f32, 1), right[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), right[1], 0.0001);
}

const Record = extern struct {
    x: f32,
    y: f32,
};

fn records(comptime count: usize, changed: ?usize) [count]Record {
    var out: [count]Record = undefined;
    for (&out, 0..) |*record, index| {
        record.* = .{ .x = @floatFromInt(index), .y = 0 };
    }
    if (changed) |index| out[index].y = 1;
    return out;
}

// Locks that identical records need no write, including a shrunk list whose remaining records
// match, and that an empty shadow writes every record.
test "dirty_range is null for identical and shrunk lists and whole for a first upload" {
    const old = records(4, null);
    const same = records(4, null);
    try std.testing.expectEqual(@as(?Range, null), dirty_range(Record, &old, &same));
    try std.testing.expectEqual(@as(?Range, null), dirty_range(Record, &old, same[0..2]));
    const whole: Range = .{ .first = 0, .end = 4 };
    try std.testing.expectEqual(whole, dirty_range(Record, &.{}, &same).?);
    try std.testing.expectEqual(@as(?Range, null), dirty_range(Record, &.{}, &.{}));
}

// Locks that one changed record writes exactly that record, two changed records write the
// span between them, and a grown list writes through its new count.
test "dirty_range covers changed records and a grown tail" {
    const old = records(6, null);
    const one = records(6, 3);
    try std.testing.expectEqual(Range{ .first = 3, .end = 4 }, dirty_range(Record, &old, &one).?);
    var two = records(6, 3);
    two[1].y = 1;
    try std.testing.expectEqual(Range{ .first = 1, .end = 4 }, dirty_range(Record, &old, &two).?);
    const grown = records(8, null);
    try std.testing.expectEqual(Range{ .first = 6, .end = 8 }, dirty_range(Record, &old, &grown).?);
}

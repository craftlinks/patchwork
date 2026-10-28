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
//! draw/types.zig      Box, Arc, Surface, Glyph, Image, Path, AppendError, and the CPU twins
//! draw/pools.zig      Context: per-type pools, the point pool, layers, sort, sticky batches
//! draw/path.zig       stroked paths: flattening, chunking, twins, and the appenders
//! draw/wave.zig       Waveform and Ring types, the waveform appender, the zoom pyramid
//! draw/fx.zig         offscreen targets: device rects, projection, Composite and Blur
//! draw/backdrop.zig   backdrops: the blur chain's sizes and passes, Glass, and the twins
//! draw/textures.zig   Textures: queued creates and writes, TextureId, Format
//! draw/renderer.zig   Renderer: records setup and frames from a Context
//! ```
//! This file re-exports the public names so apps and widgets write `draw.Box`,
//! `draw.Context`, and so on. It also owns the plain geometry types `Rect`, `Clip`, and
//! `Inset`, which layout (`ui/turtle.zig`), text placement, and hit areas share, so text
//! depends on drawing only and never on the UI layer. `Rect.array` and `Clip.array` are the
//! `[4]f32` an instance's `rect` and `clip` fields hold; `Inset.all`, `xy`, and `sides` build
//! insets.
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
//! ## 3a. Views
//! A layer with a pan/zoom view (`draw/pools.zig`, section 5c) is drawn with `M · T`, where `T`
//! takes world points to logical screen points, `s = x + zoom * w`, with columns
//! `[zoom,0,0,0], [0,zoom,0,0], [0,0,1,0], [x,y,0,1]`. `M` has only `M00`, `M11`, `M30`, `M31`
//! (and the depth 1) set, so the product changes four floats:
//! ```text
//! M00' = M00 * zoom      M30' = M00 * x + M30
//! M11' = M11 * zoom      M31' = M11 * y + M31
//! ```
//! `local` and `pos` stay in world units, so every distance field is evaluated in world units
//! and `coverage` divides by world units per device pixel: edges stay one device pixel wide.
//! Test "view_ortho maps world points through the view" locks it.
//!
//! ## 4. Uniform Size
//! The frame uniform holds the projection matrix, the time slot (`time_offset`, read by
//! animated draw types), and `theme.Theme`; `uniform_bytes` is their sum, enforced by the `comptime` block below. WebGPU requires dynamic uniform
//! offsets to be multiples of the `minUniformBufferOffsetAlignment` limit (WebGPU "Limits"
//! table, default 256). The buffer size is kept a multiple of that limit so the record stays
//! valid if it is ever bound at an offset. `draw/renderer.zig` owns the record and its uploads.
//!
//! ## 5. Dirty Ranges
//! `dirty_ranges` returns up to `upload_range_cap` record ranges `[first, end)` that cover
//! every record of `new` that differs from `old` at the same index, plus every record past
//! `old.len`: one pass finds the runs of such records, a run starting within `merge_gap`
//! records of the previous range joins it (a short gap costs less than another write), and
//! the last range grows to cover any runs past the cap. So a change at both ends of a pool (a
//! playhead first, a meter last) writes two records, not the whole pool. `dirty_range` is
//! their covering span. A shrunk list needs no write: the draw count bounds what the GPU
//! reads. Comparison is by bytes, so it is exact and never misses a change. The renderer runs
//! it per pool against a shadow of the last upload; see `draw/renderer.zig`, section 4.
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

/// Backdrops and glass: the blur chain's math and passes, `Glass`, and their CPU twins.
pub const backdrop = @import("draw/backdrop.zig");

/// Waveforms and rings: `wave.append`, `wave.Pyramid`, and the `Waveform` and `Ring` types.
pub const wave = @import("draw/wave.zig");

/// Exclusive-max clip in logical pixels, copied into every instance's `clip`. `x1 > x0` and
/// `y1 > y0`, all finite.
pub const Clip = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    /// `.{ x0, y0, x1, y1 }`, the order of an instance's `clip` field.
    pub fn array(self: Clip) [4]f32 {
        const values: [4]f32 = .{ self.x0, self.y0, self.x1, self.y1 };
        assert(values[0] == self.x0);
        assert(values[3] == self.y1);
        return values;
    }
};

/// Axis-aligned box in UI logical pixels. `(x, y)` is the top-left corner. Layout
/// (`ui/turtle.zig`), text placement, hit areas, and widgets share it.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    /// `.{ x, y, width, height }`, the order of an instance's `rect` field.
    pub fn array(self: Rect) [4]f32 {
        const values: [4]f32 = .{ self.x, self.y, self.width, self.height };
        assert(values[0] == self.x);
        assert(values[3] == self.height);
        return values;
    }
};

/// Independent insets in UI logical pixels: container padding and child margins.
pub const Inset = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    /// `value` on all four sides.
    pub fn all(value: f32) Inset {
        return sides(value, value, value, value);
    }

    /// `x` on the left and right, `y` on the top and bottom.
    pub fn xy(x: f32, y: f32) Inset {
        return sides(x, y, x, y);
    }

    /// Each side on its own, in CSS order after the left: left, top, right, bottom.
    pub fn sides(left: f32, top: f32, right: f32, bottom: f32) Inset {
        assert(left >= 0 and right >= 0);
        assert(top >= 0 and bottom >= 0);
        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }
};

pub const DrawType = registry.DrawType;
pub const Registry = registry.Registry;
pub const Context = pools.Context;
pub const Layer = pools.Layer;
/// A layer's pan/zoom view (`draw/pools.zig`, section 5c).
pub const View = pools.View;
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
/// `Box.of`'s look and `Arc.of`'s (`draw/types.zig`, section 5).
pub const BoxLook = types.BoxLook;
pub const ArcLook = types.ArcLook;
/// A rounded rect with one gradient, a rim-lit border, and a soft shadow, and its look
/// (`draw/types.zig`, section 6).
pub const Surface = types.Surface;
pub const SurfaceLook = types.SurfaceLook;
pub const Gradient = types.Gradient;
pub const Shadow = types.Shadow;
pub const transparent = types.transparent;
pub const Arc = types.Arc;
pub const Glyph = types.Glyph;
pub const Image = types.Image;
pub const Path = types.Path;
pub const Waveform = wave.Waveform;
pub const Ring = wave.Ring;
pub const Composite = fx.Composite;
pub const Glass = backdrop.Glass;
pub const GlassLook = backdrop.GlassLook;
pub const Backdrop = backdrop.Backdrop;
pub const Blur = fx.Blur;
pub const TargetKind = textures_module.TargetKind;
pub const Point = pools.Point;
pub const point_cap_max = pools.point_cap_max;
pub const sdf_box = types.sdf_box;
pub const erf = types.erf;
pub const gradient_t = types.gradient_t;
pub const mix_premultiplied = types.mix_premultiplied;
pub const shadow_alpha = types.shadow_alpha;
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

/// Ranges one pool upload may write (module guide, section 5).
pub const upload_range_cap: u32 = 4;

/// Unchanged records a range may bridge: a gap this short costs less to write than another op.
pub const merge_gap: u32 = 8;

/// The ranges to upload so that every record of `new` that differs from `old` at the same
/// index, and every record past `old.len`, is written: the runs of such records in order,
/// a run starting at most `merge_gap` records after the previous range joining it, and once
/// `upload_range_cap` ranges exist the last one growing to cover the rest. Returns how many it
/// wrote into `out`; 0 when `new` equals `old` or is a prefix of it. Records compare by bytes.
pub fn dirty_ranges(
    comptime T: type,
    old: []const T,
    new: []const T,
    out: *[upload_range_cap]Range,
) u32 {
    assert(old.len <= std.math.maxInt(u32));
    assert(new.len <= std.math.maxInt(u32));
    const shared: u32 = @intCast(@min(old.len, new.len));
    const count: u32 = @intCast(new.len);
    var ranges: u32 = 0;
    var index: u32 = 0;
    while (index < count) {
        if (index < shared and same_record(T, &old[index], &new[index])) {
            index += 1;
            continue;
        }
        // A run: records that differ, and every record past the shared prefix.
        var end = index + 1;
        while (end < count) : (end += 1) {
            if (end < shared and same_record(T, &old[end], &new[end])) break;
        }
        const joins = ranges > 0 and
            (index - out[ranges - 1].end <= merge_gap or ranges == upload_range_cap);
        if (joins) {
            out[ranges - 1].end = end;
        } else {
            out[ranges] = .{ .first = index, .end = end };
            ranges += 1;
        }
        index = end;
    }
    assert(ranges <= upload_range_cap);
    if (ranges > 0) assert(out[ranges - 1].end <= count);
    return ranges;
}

/// The smallest range covering every record `dirty_ranges` writes, or null when there is none.
pub fn dirty_range(comptime T: type, old: []const T, new: []const T) ?Range {
    var ranges: [upload_range_cap]Range = undefined;
    const count = dirty_ranges(T, old, new, &ranges);
    if (count == 0) return null;
    const span: Range = .{ .first = ranges[0].first, .end = ranges[count - 1].end };
    assert(span.first < span.end);
    return span;
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

/// Writes the projection of a layer drawn through `view`: `ortho · T`, where `T` maps world
/// points to logical screen points (`View.apply`). See the module guide, section 3a.
pub fn view_ortho(out: *[16]f32, ortho: *const [16]f32, view: View) void {
    assert(view.zoom > 0);
    assert(ortho[0] > 0);
    assert(ortho[5] < 0);
    out.* = ortho.*;
    out[0] = ortho[0] * view.zoom;
    out[5] = ortho[5] * view.zoom;
    out[12] = ortho[0] * view.x + ortho[12];
    out[13] = ortho[5] * view.y + ortho[13];
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
    _ = backdrop;
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

// Locks the view projection: world (0, 0) and (100, 50) at zoom 2 from (20, 10) land where the
// window projection puts (20, 10) and (220, 110).
test "view_ortho maps world points through the view" {
    var window: [16]f32 = undefined;
    ortho_y_down(&window, 400, 200, 120);
    var viewed: [16]f32 = undefined;
    view_ortho(&viewed, &window, .{ .x = 20, .y = 10, .zoom = 2 });
    const origin = project(viewed, 0, 0);
    const corner = project(viewed, 100, 50);
    const want_origin = project(window, 20, 10);
    const want_corner = project(window, 220, 110);
    try std.testing.expectApproxEqAbs(want_origin[0], origin[0], 1e-6);
    try std.testing.expectApproxEqAbs(want_origin[1], origin[1], 1e-6);
    try std.testing.expectApproxEqAbs(want_corner[0], corner[0], 1e-6);
    try std.testing.expectApproxEqAbs(want_corner[1], corner[1], 1e-6);
    var same: [16]f32 = undefined;
    view_ortho(&same, &window, View.identity);
    try std.testing.expectEqualSlices(f32, &window, &same);
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

// Locks the ranges (section 5): changes at both ends of 40 records are two one-record ranges;
// a gap of 8 unchanged records is bridged and a gap of 9 is not; a grown tail joins the run
// before it or starts its own; five separate runs become four ranges, the last covering two.
test "dirty_ranges splits far changes and bridges short gaps" {
    var out: [upload_range_cap]Range = undefined;
    const old = records(40, null);
    var ends = records(40, 0);
    ends[39].y = 1;
    try std.testing.expectEqual(@as(u32, 2), dirty_ranges(Record, &old, &ends, &out));
    try std.testing.expectEqual(Range{ .first = 0, .end = 1 }, out[0]);
    try std.testing.expectEqual(Range{ .first = 39, .end = 40 }, out[1]);
    try std.testing.expectEqual(Range{ .first = 0, .end = 40 }, dirty_range(Record, &old, &ends).?);
    var bridged = records(40, 10);
    bridged[19].y = 1;
    try std.testing.expectEqual(@as(u32, 1), dirty_ranges(Record, &old, &bridged, &out));
    try std.testing.expectEqual(Range{ .first = 10, .end = 20 }, out[0]);
    var apart = records(40, 10);
    apart[20].y = 1;
    try std.testing.expectEqual(@as(u32, 2), dirty_ranges(Record, &old, &apart, &out));
    var grown = records(44, 2);
    try std.testing.expectEqual(@as(u32, 2), dirty_ranges(Record, &old, &grown, &out));
    try std.testing.expectEqual(Range{ .first = 40, .end = 44 }, out[1]);
    var five = records(40, null);
    for ([_]usize{ 0, 10, 20, 30, 39 }) |at| five[at].y = 1;
    try std.testing.expectEqual(@as(u32, 4), dirty_ranges(Record, &old, &five, &out));
    try std.testing.expectEqual(Range{ .first = 30, .end = 40 }, out[3]);
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

// Locks the array views in instance order and the inset constructors: `all`, `xy` (left and
// right take x), and `sides` in argument order.
test "rect and clip arrays and inset constructors" {
    const rect: Rect = .{ .x = 1, .y = 2, .width = 30, .height = 40 };
    try std.testing.expectEqual([4]f32{ 1, 2, 30, 40 }, rect.array());
    const clip: Clip = .{ .x0 = 1, .y0 = 2, .x1 = 31, .y1 = 42 };
    try std.testing.expectEqual([4]f32{ 1, 2, 31, 42 }, clip.array());
    const twelve: Inset = .{ .left = 12, .top = 12, .right = 12, .bottom = 12 };
    try std.testing.expectEqual(twelve, Inset.all(12));
    const wide: Inset = .{ .left = 8, .top = 4, .right = 8, .bottom = 4 };
    try std.testing.expectEqual(wide, Inset.xy(8, 4));
    try std.testing.expectEqual(
        Inset{ .left = 1, .top = 2, .right = 3, .bottom = 4 },
        Inset.sides(1, 2, 3, 4),
    );
}

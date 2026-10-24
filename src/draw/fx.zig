//! Offscreen effects: device rects of targets, their projection, and the `Composite` and
//! `Blur` types that sample them.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Targets Are Layers
//! A panel faded instance by instance darkens wherever its instances overlap, and a scope's
//! persistence needs last frame's pixels. Both need a pass that draws into a texture first.
//! `Context.offscreen(layer, target, rect)` binds a draw layer to a target for one frame: the
//! renderer draws that layer's batches in the target's own pass, before the main pass, and
//! never in the main pass (`draw/renderer.zig`, section 4c). A `Composite` (or `Blur`) on
//! another layer samples the result. Layers already order batches, so a target costs no bits
//! of the batch sort key.
//!
//! ## 2. Device Rects and Projection
//! A target covers a logical rect at the frame's scale `s`, snapped outward to device pixels:
//! ```text
//! x0 = floor(x * s), y0 = floor(y * s), x1 = ceil((x + w) * s), y1 = ceil((y + h) * s)
//! texture = (x1 - x0) by (y1 - y0), at most target_edge_max a side
//! ```
//! Its projection maps logical `(x0 / s, y0 / s)` to the texture's top-left, so the layer's
//! instances keep their window coordinates (and their clips) and land on the same device
//! pixels they would on screen. `uv_of` gives a composite the texture coordinates of its rect:
//! a pixel center of the composite meets a texel center of the target exactly.
//!
//! ## 3. Premultiplied Composites
//! A target is cleared to transparent black and drawn with the usual blends; `Blend.alpha`'s
//! alpha factors (one, one_minus_src_alpha) make its pixels premultiplied color with correct
//! coverage. `Composite` and `Blur` blend `premultiplied` and output
//! ```text
//! (rgb * opacity, a * opacity * cover)
//! ```
//! so `cover = 1` composites (a group fades as one layer) and `cover = 0` only adds the
//! target's color: light, for glow and bloom. `Composite.bias` is then subtracted from every
//! channel (clamped at 0): a feedback target that draws its own last frame at opacity `o`
//! would otherwise stall where `round(v * o) == v` in 8 bits (below `0.5 / (1 - o)` levels,
//! 4 levels at 0.88) and leave a ghost wherever the trace has been; a bias of 1.5 levels makes
//! every faded texel lose at least one level per frame.
//!
//! ## 4. Blur
//! `Blur` takes `2 radius + 1` taps along `direction` (one texel, in uv) with Gaussian weights
//! `exp(-i^2 / (2 sigma^2))`, `sigma = radius / 2`, normalized over the taps (`blur_weight` is
//! the CPU twin). The loop's length is instance data, so it samples with
//! `sample_texture_level` (an explicit level needs no derivatives). A horizontal blur into a
//! target and a vertical blur out of it make a separable Gaussian.
//!
//! ## 5. TigerStyle Invariants
//! `radius <= blur_radius_max` and every device rect edge is at most `target_edge_max`, both
//! asserted.

const std = @import("std");
const assert = std.debug.assert;
const textures = @import("textures.zig");

/// Longest side of a target, in device pixels.
pub const target_edge_max: u32 = 4096;

/// Most taps per side of one blur.
pub const blur_radius_max: u32 = 16;

/// A target's device rect: origin and size in device pixels (section 2).
pub const DeviceRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// The device rect a logical `rect` covers at `scale_120` (section 2).
pub fn device_rect(rect: [4]f32, scale_120: u32) DeviceRect {
    assert(scale_120 != 0);
    assert(rect[2] > 0 and rect[3] > 0);
    assert(rect[0] >= 0 and rect[1] >= 0);
    const s = @as(f32, @floatFromInt(scale_120)) / 120;
    const x0: u32 = @intFromFloat(@floor(rect[0] * s));
    const y0: u32 = @intFromFloat(@floor(rect[1] * s));
    const x1: u32 = @intFromFloat(@ceil((rect[0] + rect[2]) * s));
    const y1: u32 = @intFromFloat(@ceil((rect[1] + rect[3]) * s));
    const out: DeviceRect = .{ .x = x0, .y = y0, .width = @max(x1 - x0, 1), .height = @max(y1 - y0, 1) };
    assert(out.width <= target_edge_max);
    assert(out.height <= target_edge_max);
    return out;
}

/// The projection of a target's pass (section 2): logical pixels to clip space, with the
/// device rect's origin at the top-left.
pub fn ortho(out: *[16]f32, device: DeviceRect, scale_120: u32) void {
    assert(scale_120 != 0);
    const s = @as(f32, @floatFromInt(scale_120)) / 120;
    const w = @as(f32, @floatFromInt(device.width)) / s;
    const h = @as(f32, @floatFromInt(device.height)) / s;
    const ox = @as(f32, @floatFromInt(device.x)) / s;
    const oy = @as(f32, @floatFromInt(device.y)) / s;
    out.* = .{
        2.0 / w,           0.0,              0.0, 0.0,
        0.0,               -2.0 / h,         0.0, 0.0,
        0.0,               0.0,              1.0, 0.0,
        -1.0 - 2 * ox / w, 1.0 + 2 * oy / h, 0.0, 1.0,
    };
}

/// The texture coordinates (u0, v0, u1, v1) of logical `rect` in a target that covers
/// `target_rect` (section 2).
pub fn uv_of(rect: [4]f32, target_rect: [4]f32, scale_120: u32) [4]f32 {
    const device = device_rect(target_rect, scale_120);
    const s = @as(f32, @floatFromInt(scale_120)) / 120;
    const w: f32 = @floatFromInt(device.width);
    const h: f32 = @floatFromInt(device.height);
    const x0: f32 = @floatFromInt(device.x);
    const y0: f32 = @floatFromInt(device.y);
    return .{
        (rect[0] * s - x0) / w,
        (rect[1] * s - y0) / h,
        ((rect[0] + rect[2]) * s - x0) / w,
        ((rect[1] + rect[3]) * s - y0) / h,
    };
}

/// Draws a target's pixels over `rect` (section 3).
pub const Composite = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32,
    opacity: f32,
    cover: f32,
    /// Subtracted from every channel after the opacity (section 3); 0 for a plain composite.
    bias: f32,
    pad0: f32,

    pub const texture: ?textures.Format = .target;
    pub const blend: @import("../gpu/commands.zig").Blend = .premultiplied;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let c = sample_texture(mix(px.uv.xy, px.uv.zw, px.local / px.size));
        \\    let rgb = max(c.rgb * px.opacity - vec3<f32>(px.bias), vec3<f32>(0.0));
        \\    return vec4<f32>(rgb, max(c.a * px.opacity * px.cover - px.bias, 0.0));
        \\}
        \\
    ;
};

/// One direction of a separable Gaussian over a target (section 4).
pub const Blur = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32,
    /// One texel along the blur, in uv, in `xy`; `z` is the radius in taps; `w` unused.
    direction: [4]f32,
    opacity: f32,
    cover: f32,
    pad0: f32,
    pad1: f32,

    pub const texture: ?textures.Format = .target;
    pub const blend: @import("../gpu/commands.zig").Blend = .premultiplied;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let uv = mix(px.uv.xy, px.uv.zw, px.local / px.size);
        \\    let radius = i32(px.direction.z + 0.5);
        \\    let sigma = max(px.direction.z * 0.5, 0.5);
        \\    var sum = vec4<f32>(0.0, 0.0, 0.0, 0.0);
        \\    var total = 0.0;
        \\    for (var i = -radius; i <= radius; i = i + 1) {
        \\        let x = f32(i);
        \\        let weight = exp(-x * x / (2.0 * sigma * sigma));
        \\        sum = sum + sample_texture_level(uv + px.direction.xy * x) * weight;
        \\        total = total + weight;
        \\    }
        \\    let c = sum / total;
        \\    return vec4<f32>(c.rgb * px.opacity, c.a * px.opacity * px.cover);
        \\}
        \\
    ;
};

/// The normalized weight of tap `i` of a blur of `radius`: the CPU twin of `Blur`'s.
pub fn blur_weight(radius: u32, i: i32) f32 {
    assert(radius <= blur_radius_max);
    const sigma = @max(@as(f32, @floatFromInt(radius)) * 0.5, 0.5);
    var total: f32 = 0;
    var tap: i32 = -@as(i32, @intCast(radius));
    while (tap <= radius) : (tap += 1) {
        const x: f32 = @floatFromInt(tap);
        total += @exp(-x * x / (2 * sigma * sigma));
    }
    const x: f32 = @floatFromInt(i);
    return @exp(-x * x / (2 * sigma * sigma)) / total;
}

/// Appends a `Composite` of `target`, which covers `target_rect`, over `rect` (section 3).
pub fn composite(
    cx: anytype,
    target: textures.TextureId,
    target_rect: [4]f32,
    rect: [4]f32,
    clip: [4]f32,
    opacity: f32,
    cover: f32,
    bias: f32,
) void {
    assert(cx.textures.is_target(target));
    assert(opacity >= 0 and opacity <= 1);
    cx.append(Composite, target, .{
        .rect = rect,
        .clip = clip,
        .uv = uv_of(rect, target_rect, cx.text.scale_120),
        .opacity = opacity,
        .cover = cover,
        .bias = bias,
        .pad0 = 0,
    }) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// Appends a `Blur` of `target` (covering `target_rect`) over `rect`, along `axis` (0 for
/// horizontal, 1 for vertical), `radius` device texels each side (section 4).
pub fn blur(
    cx: anytype,
    target: textures.TextureId,
    target_rect: [4]f32,
    rect: [4]f32,
    clip: [4]f32,
    axis: u1,
    radius: u32,
    opacity: f32,
    cover: f32,
) void {
    assert(cx.textures.is_target(target));
    assert(radius <= blur_radius_max);
    const device = device_rect(target_rect, cx.text.scale_120);
    const step_u = 1 / @as(f32, @floatFromInt(device.width));
    const step_v = 1 / @as(f32, @floatFromInt(device.height));
    cx.append(Blur, target, .{
        .rect = rect,
        .clip = clip,
        .uv = uv_of(rect, target_rect, cx.text.scale_120),
        .direction = if (axis == 0)
            .{ step_u, 0, @floatFromInt(radius), 0 }
        else
            .{ 0, step_v, @floatFromInt(radius), 0 },
        .opacity = opacity,
        .cover = cover,
        .pad0 = 0,
        .pad1 = 0,
    }) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

const testing = std.testing;
const registry = @import("registry.zig");

/// The clip-space point `matrix` maps logical `(x, y)` to.
fn project(matrix: [16]f32, x: f32, y: f32) [2]f32 {
    return .{ matrix[0] * x + matrix[4] * y + matrix[12], matrix[1] * x + matrix[5] * y + matrix[13] };
}

// Locks the device rect and projection (section 2) at scale 1.5: a rect at (10.5, 20) of
// 100 by 50 snaps to device (15, 30) to (166, 105), 151 by 75; the projection maps the snapped
// origin to the top-left corner and the far corner to the bottom-right; and a composite of
// the target's own rect starts at the fraction of a texel the snap added.
test "targets snap outward and project their origin to the top-left" {
    const rect: [4]f32 = .{ 10.5, 20, 100, 50 };
    const device = device_rect(rect, 180);
    try testing.expectEqual(DeviceRect{ .x = 15, .y = 30, .width = 151, .height = 75 }, device);
    var matrix: [16]f32 = undefined;
    ortho(&matrix, device, 180);
    const top_left = project(matrix, 10, 20);
    try testing.expectApproxEqAbs(@as(f32, -1), top_left[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), top_left[1], 1e-5);
    const bottom_right = project(matrix, (15.0 + 151.0) / 1.5, (30.0 + 75.0) / 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1), bottom_right[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), bottom_right[1], 1e-5);
    const uv = uv_of(rect, rect, 180);
    try testing.expectApproxEqAbs(@as(f32, 0.75 / 151.0), uv[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), uv[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, (165.75 - 15.0) / 151.0), uv[2], 1e-6);
}

// Locks the blur weights (section 4): they sum to 1 and fall off symmetrically, and radius 0
// is the identity.
test "blur weights sum to one" {
    var sum: f32 = 0;
    var i: i32 = -8;
    while (i <= 8) : (i += 1) sum += blur_weight(8, i);
    try testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-5);
    try testing.expectEqual(blur_weight(8, -3), blur_weight(8, 3));
    try testing.expect(blur_weight(8, 0) > blur_weight(8, 1));
    try testing.expectEqual(@as(f32, 1), blur_weight(0, 0));
}

// Locks the group-opacity claim (section 3) on the CPU blend equations: two instances of
// alpha 0.6 drawn into a transparent target and composited at 0.5 equal the group drawn
// directly and then mixed with the backdrop at 0.5, exactly: `f P + b (1 - f C)` is
// `f (P + b (1 - C)) + (1 - f) b`. Faded instance by instance, the overlap gets more coverage
// (1 - 0.7^2 = 0.51 against 0.5 * 0.84 = 0.42), so it stands out from the rest of the group.
test "a group composite fades as one layer, instances do not" {
    const backdrop: f32 = 0.1;
    const color: f32 = 0.9;
    const a: f32 = 0.6;
    const fade: f32 = 0.5;
    var premul: f32 = 0;
    var coverage: f32 = 0;
    var direct: f32 = backdrop;
    var per_instance: f32 = backdrop;
    var per_coverage: f32 = 0;
    for (0..2) |_| {
        premul = color * a + premul * (1 - a);
        coverage = a + coverage * (1 - a);
        direct = color * a + direct * (1 - a);
        per_instance = color * a * fade + per_instance * (1 - a * fade);
        per_coverage = a * fade + per_coverage * (1 - a * fade);
    }
    const one_layer = premul * fade + backdrop * (1 - coverage * fade);
    try testing.expectApproxEqAbs(direct * fade + backdrop * (1 - fade), one_layer, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.51), per_coverage, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.42), coverage * fade, 1e-6);
    try testing.expect(@abs(per_instance - one_layer) > 0.05);
}

// Locks the generated interfaces: both types sample the target format with the premultiplied
// blend, and the blur reads with an explicit level.
test "composite and blur assemble" {
    try testing.expect(comptime registry.check(Composite) == null);
    try testing.expect(comptime registry.check(Blur) == null);
    try testing.expectEqual(@import("../gpu/commands.zig").Blend.premultiplied, registry.blend_of(Blur));
    const text = comptime registry.source(Blur);
    try testing.expect(std.mem.find(u8, text, "sample_texture_level(uv + px.direction.xy * x)") != null);
    try testing.expectEqual(@as(usize, 64), @sizeOf(Composite));
    try testing.expectEqual(@as(usize, 80), @sizeOf(Blur));
}

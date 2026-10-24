//! The data example's draw types: one per new texture format, sampling mode, or blend.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Five Types
//! A draw type's texture format is fixed by `T.texture`, and its blend by `T.blend`
//! (`draw/registry.zig`, sections 2 and 2c), so each thing the screen proves is its own type:
//! ```text
//! Heat   r32float, nearest     unfilterable float: the second texture layout and sampler
//! Shade  multiply              darkens what is under it, mixing toward white by 1 - alpha
//! Tile   rg16float, repeat     half floats, linear filtering across the wrap
//! Bars   r16float, textureLoad a ring read from a write head, no sampler involved
//! Light  additive              three discs that sum to white where they overlap
//! ```
//!
//! ## 2. Pixels
//! With `t = local / size`:
//! ```text
//! Heat   v = sample(t).r                      palette: dark blue, magenta, yellow by v
//! Shade  alpha = color.a * t.y                darker toward the bottom
//! Tile   c = sample(mix(uv.xy, uv.zw, t)).rg  rgb = (c.r, c.g, 0.6)
//! Bars   column = floor(t.x * count); texel = (head + column) mod count
//!        bar = load(texel).r; filled below 1 - bar, a gap in each column's last fifth
//!        the edge ramps over fwidth(local.y) only: `coverage` of a distance that jumps
//!        between columns would smear each bar's top across its neighbors
//! Light  alpha = coverage(|local - size / 2| - radius) * color.a
//! ```
//! `history_texel` is the CPU twin of the `Bars` index. Derivatives run unconditionally in
//! every type, and `load_texture` has none (prelude guide, section 3).
//!
//! ## 3. TigerStyle Invariants
//! The `comptime` block checks every type against the draw type convention and pins sizes.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const draw = patchwork.draw;

/// A heat map of an `r32float` texture sampled nearest. See the module guide.
pub const Heat = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?draw.TextureFormat = .r32float;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let v = clamp(sample_texture(px.local / px.size).r, 0.0, 1.0);
        \\    let low = vec3<f32>(0.05, 0.06, 0.20);
        \\    let mid = vec3<f32>(0.75, 0.15, 0.55);
        \\    let high = vec3<f32>(1.00, 0.90, 0.30);
        \\    let rgb = select(mix(mid, high, v * 2.0 - 1.0), mix(low, mid, v * 2.0), v < 0.5);
        \\    return vec4<f32>(rgb, 1.0);
        \\}
        \\
    ;
};

/// A multiplying shade whose alpha grows toward the bottom. See the module guide.
pub const Shade = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const blend: draw.Blend = .multiply;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(px.color.rgb, px.color.a * px.local.y / px.size.y);
        \\}
        \\
    ;
};

/// A repeating `rg16float` tile. `uv` is the texture-space rectangle shown (x0, y0, x1, y1).
pub const Tile = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32,

    pub const texture: ?draw.TextureFormat = .rg16float;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let c = sample_texture(mix(px.uv.xy, px.uv.zw, px.local / px.size)).rg;
        \\    return vec4<f32>(c.r, c.g, 0.6, 1.0);
        \\}
        \\
    ;
};

/// Bars read from an `r16float` ring of `count` texels, oldest first from `head`.
pub const Bars = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    head: f32,
    count: f32,
    pad0: f32,
    pad1: f32,

    pub const texture: ?draw.TextureFormat = .r16float;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let t = px.local / px.size;
        \\    let count = i32(px.count);
        \\    let column = min(i32(floor(t.x * px.count)), count - 1);
        \\    let texel = (i32(px.head) + column) % count;
        \\    let bar = load_texture(vec2<i32>(texel, 0)).r;
        \\    let top = px.size.y * (1.0 - bar);
        \\    let ramp = max(fwidth(px.local.y), 1.0e-5);
        \\    let fill = clamp(0.5 - (top - px.local.y) / ramp, 0.0, 1.0);
        \\    let gap = step(0.8, fract(t.x * px.count));
        \\    return vec4<f32>(px.color.rgb, px.color.a * fill * (1.0 - gap));
        \\}
        \\
    ;
};

/// An additive disc filling its rect.
pub const Light = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const blend: draw.Blend = .additive;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let center = px.size * 0.5;
        \\    let dist = sdf_circle(px.local, center, min(center.x, center.y));
        \\    return vec4<f32>(px.color.rgb, px.color.a * coverage(dist));
        \\}
        \\
    ;
};

/// The ring texel `Bars` reads for `column`: the CPU twin of its WGSL index.
pub fn history_texel(head: u32, count: u32, column: u32) u32 {
    assert(head < count);
    assert(column < count);
    const texel = (head + column) % count;
    assert(texel < count);
    return texel;
}

comptime {
    assert(draw.check_type(Heat) == null);
    assert(draw.check_type(Shade) == null);
    assert(draw.check_type(Tile) == null);
    assert(draw.check_type(Bars) == null);
    assert(draw.check_type(Light) == null);
    assert(@sizeOf(Heat) == 32);
    assert(@sizeOf(Bars) == 64);
    assert(@offsetOf(Bars, "head") == 48);
}

// Locks the generated interfaces: the multiply mix in `Shade`, the identity in `Light`, the
// texel helper in `Bars`, and the ring order: oldest at `head`, wrapping past the end.
test "views assemble and read the ring from the head" {
    const shade = comptime draw.type_source(Shade);
    try std.testing.expect(std.mem.find(u8, shade, "mix(vec3<f32>(1.0, 1.0, 1.0), c.rgb") != null);
    const light = comptime draw.type_source(Light);
    try std.testing.expect(std.mem.find(u8, light, "return c;") != null);
    const bars = comptime draw.type_source(Bars);
    try std.testing.expect(std.mem.find(u8, bars, "px.head = v.g3.x;") != null);
    try std.testing.expect(std.mem.find(u8, bars, "fn load_texture(") != null);
    try std.testing.expectEqual(@as(u32, 40), history_texel(40, 56, 0));
    try std.testing.expectEqual(@as(u32, 55), history_texel(40, 56, 15));
    try std.testing.expectEqual(@as(u32, 0), history_texel(40, 56, 16));
}

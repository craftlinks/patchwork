//! The library draw types (`Box`, `Arc`, `Glyph`, `Image`) and their CPU distance twins.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why One Type per Primitive
//! Step 11 drew boxes and rings through one ubershader that branched on a `kind` field, with
//! every record paying for fields only the other kind used. Each primitive is now its own
//! `extern struct` and its own `pixel` function (`draw/registry.zig` assembles the module), so
//! a fragment runs only its own distance field and a record carries only its own parameters.
//! The layouts follow the registry's convention: `rect` and `clip` first, then parameter
//! groups, each 16 bytes. The `comptime` block below pins every size.
//!
//! ## 2. The Types
//! - `Box` (80 bytes): `fill`, `border_color`, then `radius`, `border_width`, `hover`, `down`.
//!   `radius` is clamped to half the short edge, so a wide box is a capsule and a square a
//!   disc. With `border_width > 0` the outer `border_width` pixels take `border_color` and the
//!   inside takes `fill`; with 0 the face is `fill` alone, exactly as in step 11. `hover` and
//!   `down` are mix weights toward the theme's `lighten` and then `darken`.
//! - `Arc` (64 bytes): `color`, then `thickness`, `sweep` (a fraction of `theme.arc_sweep`),
//!   `hover`, and a zero pad. An arc lightens on hover and never darkens.
//! - `Glyph` (64 bytes): `uv` (u0, v0, u1, v1, half-texel inset by the baker) and `color`;
//!   samples the `r8` atlas, and coverage scales `color.a`.
//! - `Image` (64 bytes): `uv` and `tint`; samples an `rgba8` texture, multiplied by `tint`.
//!
//! ## 3. Hover, Down, and Theme Colors
//! ```text
//! lit = mix(face.rgb, theme.lighten.rgb, hover)
//! rgb = mix(lit, theme.darken.rgb, down)            Box only
//! ```
//! Widgets scale their animator values by `widgets.hover_lighten` and `widgets.down_darken`
//! before writing them. Colors and arc angles come from instances and the uniform, never from
//! WGSL literals.
//!
//! ## 4. CPU Twins
//! `sdf_box` and `sdf_arc` are the CPU twins of the prelude functions of the same names, so
//! layout and hit testing are verified without a GPU. `contains_box` is the one rounded-box
//! point test that widget hit testing uses. The tests at the end of this file hold the worked
//! values.

const std = @import("std");
const assert = std.debug.assert;
const theme = @import("../theme.zig");
const textures = @import("textures.zig");

/// Why `draw.Context.append` refused an instance. `PoolFull` and `BatchFull` are also counted
/// in `Context.overflow_count`; widgets skip the instance on either.
pub const AppendError = error{
    /// `width <= 0` or `height <= 0`: degenerate geometry never reaches the GPU.
    EdgeNotPositive,
    /// A clip edge is not finite, or the clip is not exclusive-max ordered.
    ClipUnordered,
    /// The type's pool holds `cap` instances already.
    PoolFull,
    /// A new (layer, type, texture) batch would exceed `batch_cap`.
    BatchFull,
};

/// Rounded rectangle with an optional border. See the module guide.
pub const Box = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    fill: [4]f32,
    border_color: [4]f32,
    radius: f32,
    border_width: f32,
    hover: f32,
    down: f32,

    pub const texture: ?textures.Format = null;
    // `select` instead of a branch keeps both `coverage` calls in uniform control flow.
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let dist = sdf_box(px.local, px.size, px.radius);
        \\    let outer = coverage(dist);
        \\    let inner = select(1.0, coverage(dist + px.border_width), px.border_width > 0.0);
        \\    let face = mix(px.border_color, px.fill, inner);
        \\    let lit = mix(face.rgb, frame.theme.lighten.rgb, px.hover);
        \\    let rgb = mix(lit, frame.theme.darken.rgb, px.down);
        \\    return vec4<f32>(rgb, face.a * outer);
        \\}
        \\
    ;
};

/// Open ring with round caps. See the module guide.
pub const Arc = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    thickness: f32,
    sweep: f32,
    hover: f32,
    pad: f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let dist = sdf_arc(px.local, px.size, px.thickness, px.sweep);
        \\    let rgb = mix(px.color.rgb, frame.theme.lighten.rgb, px.hover);
        \\    return vec4<f32>(rgb, px.color.a * coverage(dist));
        \\}
        \\
    ;
};

/// One glyph quad sampled from the font atlas (texture 0).
pub const Glyph = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32,
    color: [4]f32,

    pub const texture: ?textures.Format = .r8;
    // UVs interpolate across the quad exactly as the step 11 per-vertex mix did.
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let uv = mix(px.uv.xy, px.uv.zw, px.local / px.size);
        \\    let coverage_sample = sample_texture(uv).r;
        \\    return vec4<f32>(px.color.rgb, px.color.a * coverage_sample);
        \\}
        \\
    ;
};

/// A textured quad sampled from an `rgba8` texture and multiplied by `tint`.
pub const Image = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    uv: [4]f32,
    tint: [4]f32,

    pub const texture: ?textures.Format = .rgba8;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let uv = mix(px.uv.xy, px.uv.zw, px.local / px.size);
        \\    return sample_texture(uv) * px.tint;
        \\}
        \\
    ;
};

/// Signed distance of a rounded rectangle, negative inside and positive outside. CPU twin of
/// `sdf_box` in `prelude.wgsl`.
///
/// `(px, py)` is in local logical pixels with the origin at the rectangle's top-left.
/// `radius` is clamped to half the shorter edge, so oversized values give a capsule or a disc.
/// With `half = (width / 2, height / 2)` and `k = min(radius, min(half.x, half.y))`:
/// ```text
/// q        = abs(point - half) - (half - k)
/// distance = min(max(q.x, q.y), 0) + length(max(q, 0)) - k
/// ```
/// `q` is the offset from an inner sharp box shrunk by `k`, folded into one quadrant. The
/// first term is the inside distance to the nearest inner face, the second is the outside
/// Euclidean distance, and subtracting `k` grows the inner box back into the rounded outline.
pub fn sdf_box(px: f32, py: f32, width: f32, height: f32, radius: f32) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(radius >= 0);
    const half_w: f32 = 0.5 * width;
    const half_h: f32 = 0.5 * height;
    // Past half the shorter edge the inner box would invert and the corner circles overlap.
    const shorter: f32 = @min(half_w, half_h);
    const k: f32 = @min(radius, shorter);
    assert(k >= 0);
    assert(k <= shorter);
    const qx: f32 = @abs(px - half_w) - (half_w - k);
    const qy: f32 = @abs(py - half_h) - (half_h - k);
    const outside_x: f32 = @max(qx, 0.0);
    const outside_y: f32 = @max(qy, 0.0);
    const outside: f32 = @sqrt(outside_x * outside_x + outside_y * outside_y);
    const inside: f32 = @min(@max(qx, qy), 0.0);
    return inside + outside - k;
}

/// Signed distance of an open ring. CPU twin of `sdf_arc` in `prelude.wgsl`.
///
/// `(px, py)` is in local logical pixels, origin at the face top-left, Y down. `thickness` is
/// the stroke width and `sweep_fraction` in `[0, 1]` scales `theme.arc_sweep`. Angles follow
/// the convention in `theme.zig`. Round caps fall out of measuring the distance to the swept
/// centerline, clamped at the sweep end, and subtracting half the thickness.
///
/// ```text
/// center = size * 0.5
/// p      = local - center
/// mid    = min(center.x, center.y) - thickness * 0.5
/// sweep  = sweep_fraction * arc_sweep
/// rel    = wrap(atan2(p.y, p.x) - arc_start, 0, tau)
/// ang    = min(rel, sweep)
/// dir    = (cos(arc_start + ang), sin(arc_start + ang))
/// dist   = length(p - dir * mid) - thickness * 0.5
/// ```
pub fn sdf_arc(
    px: f32,
    py: f32,
    width: f32,
    height: f32,
    thickness: f32,
    sweep_fraction: f32,
) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(thickness >= 0);
    assert(sweep_fraction >= 0);
    assert(sweep_fraction <= 1);
    const center_x: f32 = width * 0.5;
    const center_y: f32 = height * 0.5;
    const local_x = px - center_x;
    const local_y = py - center_y;
    const mid = @min(center_x, center_y) - thickness * 0.5;
    const sweep = sweep_fraction * theme.arc_sweep;
    const turned = std.math.atan2(local_y, local_x) - theme.arc_start;
    const rel = wrap_tau(turned);
    const ang = @min(rel, sweep);
    const dir_x = @cos(theme.arc_start + ang);
    const dir_y = @sin(theme.arc_start + ang);
    const dx = local_x - dir_x * mid;
    const dy = local_y - dir_y * mid;
    const dist = @sqrt(dx * dx + dy * dy) - thickness * 0.5;
    assert(dist == dist);
    assert(rel >= 0);
    return dist;
}

/// Wraps an angle into `[0, tau)`. Valid because `atan2` minus the start angle is less than
/// one turn away from that range.
fn wrap_tau(angle: f32) f32 {
    assert(angle == angle);
    const span = std.math.tau;
    var value = angle;
    if (value < 0) {
        value += span;
    }
    if (value >= span) {
        value -= span;
    }
    assert(value >= 0);
    assert(value < span);
    return value;
}

/// True when `(px, py)` lies inside the rounded rectangle, boundary included.
///
/// All values are logical pixels, top-left origin, Y down, and `(x, y)` is the rectangle's
/// top-left. `sdf_box <= 0` matches the shader's coverage of at least one half on the outline.
pub fn contains_box(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    px: f32,
    py: f32,
) bool {
    assert(width > 0);
    assert(height > 0);
    assert(radius >= 0);
    if (px < x) {
        return false;
    }
    if (px > x + width) {
        return false;
    }
    if (py < y) {
        return false;
    }
    if (py > y + height) {
        return false;
    }
    const dist = sdf_box(px - x, py - y, width, height, radius);
    assert(dist == dist);
    return dist <= 0;
}

comptime {
    // The layouts are an ABI with the generated WGSL and the vertex layouts, so a field
    // reorder or resize must fail the build, not the GPU.
    assert(@sizeOf(Box) == 80);
    assert(@offsetOf(Box, "fill") == 32);
    assert(@offsetOf(Box, "border_color") == 48);
    assert(@offsetOf(Box, "radius") == 64);
    assert(@offsetOf(Box, "down") == 76);
    assert(@sizeOf(Arc) == 64);
    assert(@offsetOf(Arc, "thickness") == 48);
    assert(@sizeOf(Glyph) == 64);
    assert(@offsetOf(Glyph, "uv") == 32);
    assert(@offsetOf(Glyph, "color") == 48);
    assert(@sizeOf(Image) == 64);
    assert(@offsetOf(Image, "tint") == 48);
}

// Locks the interior: the center of a sharp 20 by 10 box is half the shorter side inside.
test "sdf center is inside" {
    const dist = sdf_box(10, 5, 20, 10, 0);
    try std.testing.expect(dist < 0);
    try std.testing.expectApproxEqAbs(@as(f32, -5), dist, 0.0001);
}

// Locks that the midpoint of a box edge is on the outline.
test "sdf sharp edge midpoint is on the boundary" {
    const dist = sdf_box(10, 0, 20, 10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dist, 0.0001);
}

// Locks the exterior corner: one pixel out on both axes is sqrt(2) away from the corner.
test "sdf point outside a sharp corner is positive" {
    const dist = sdf_box(-1, -1, 20, 10, 0);
    try std.testing.expect(dist > 0);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 2)), dist, 0.0001);
}

// Locks that growing the radius moves a pixel next to the corner from inside to outside.
test "sdf grown radius puts a former inner corner outside" {
    const sharp = sdf_box(0.5, 0.5, 20, 20, 0);
    const rounded = sdf_box(0.5, 0.5, 20, 20, 8);
    try std.testing.expect(sharp < 0);
    try std.testing.expect(rounded > 0);
}

// Locks the radius clamp: a 20 by 20 box with an oversized radius is a disc of diameter 20.
test "sdf oversized radius saturates into a disc" {
    const center = sdf_box(10, 10, 20, 20, 100);
    const edge = sdf_box(10, 0, 20, 20, 100);
    const corner = sdf_box(0, 0, 20, 20, 100);
    try std.testing.expectApproxEqAbs(@as(f32, -10), center, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), edge, 0.0001);
    try std.testing.expect(corner > 0);
}

// Locks the ring: on a 56 by 56 face with thickness 4, the start-cap center is half the stroke
// inside, the face center is `mid - thickness / 2` outside, a point on the mid radius at 6
// o'clock lies in the gap, and a zero sweep leaves only the cap at the start.
test "sdf arc locks the open ring" {
    const size: f32 = 56;
    const thickness: f32 = 4;
    const mid: f32 = size * 0.5 - thickness * 0.5;
    const start_x = size * 0.5 + @cos(theme.arc_start) * mid;
    const start_y = size * 0.5 + @sin(theme.arc_start) * mid;
    try std.testing.expectApproxEqAbs(@as(f32, 15), start_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.51666), start_y, 0.001);
    const at_start = sdf_arc(start_x, start_y, size, size, thickness, 1);
    const at_center = sdf_arc(28, 28, size, size, thickness, 1);
    try std.testing.expectApproxEqAbs(@as(f32, -2), at_start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), at_center, 0.0001);
    const six = sdf_arc(28, 28 + mid, size, size, thickness, 1);
    try std.testing.expect(six > 0);
    const cap = sdf_arc(start_x, start_y, size, size, thickness, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -2), cap, 0.0001);
    const away = sdf_arc(28, 28, size, size, thickness, 0);
    try std.testing.expect(away > 0);
}

// Locks that a sharp box includes its edges and a rounded box rejects the pixel just inside
// its corner, where the box covers the point but the quarter circle does not.
test "contains_box accepts the sharp edge and rejects a rounded corner" {
    try std.testing.expect(contains_box(0, 0, 20, 10, 0, 10, 0));
    try std.testing.expect(contains_box(0, 0, 20, 10, 0, 0, 5));
    try std.testing.expect(!contains_box(0, 0, 20, 10, 0, -1, 5));
    // A pill: the radius is half the height, so the (x + 1, y + 1) pixel is outside the cap and
    // (1144, 680) is the rectangle center.
    try std.testing.expect(contains_box(1024, 656, 240, 48, 24, 1144, 680));
    try std.testing.expect(!contains_box(1024, 656, 240, 48, 24, 1025, 657));
}

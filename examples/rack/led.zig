//! The rack's own draw type: a glowing LED disc, registered in `App.config.draw`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why an App-Defined Type
//! The library ships `Box`, `Arc`, `Glyph`, and `Image`. A glow is none of them: its alpha
//! falls off smoothly past the disc instead of ending at an outline. `Led` shows that an app
//! adds a primitive with an `extern struct` and a WGSL `pixel` function, without editing the
//! library: the registry assembles its module, gives it a pipeline and a pool, and batches
//! it like any library type.
//!
//! ## 2. Instance Layout and Pixel
//! `rect`, `clip`, `color`, then `brightness` and three zero pads: 64 bytes, four groups. With
//! `center = size / 2`, `radius = min(center)`, and a core of `core_fraction * radius`:
//! ```text
//! dist  = sdf_circle(local, center, core)             the lit core, antialiased by coverage
//! reach = clamp(1 - max(dist, 0) / (radius - core), 0, 1)
//! glow  = reach^2 * brightness                        quadratic falloff to the quad edge
//! rgb   = mix(color.rgb * dim, color.rgb, brightness) an unlit LED keeps a dim body
//! alpha = max(coverage(dist), glow * glow_alpha) * color.a
//! ```
//! `coverage` runs unconditionally, so the derivative is in uniform control flow (see the
//! prelude guide). `brightness` follows the panel's meter level, set by the rack's `draw`.
//!
//! ## 3. TigerStyle Invariants
//! The `comptime` block checks the type against the draw type convention and pins its size.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const draw = patchwork.draw;

/// A glowing disc. See the module guide.
pub const Led = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    brightness: f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let center = px.size * 0.5;
        \\    let radius = min(center.x, center.y);
        \\    let core = radius * 0.45;
        \\    let dist = sdf_circle(px.local, center, core);
        \\    let reach = clamp(1.0 - max(dist, 0.0) / max(radius - core, 1.0e-5), 0.0, 1.0);
        \\    let glow = reach * reach * px.brightness;
        \\    let rgb = mix(px.color.rgb * 0.3, px.color.rgb, px.brightness);
        \\    let alpha = max(coverage(dist), glow * 0.7) * px.color.a;
        \\    return vec4<f32>(rgb, alpha);
        \\}
        \\
    ;
};

/// Side of the LED quad in logical pixels; the glow fills it.
pub const side_px: f32 = 20;

/// An LED of `color` filling the `side_px` square centered on `(center_x, center_y)`.
pub fn at(center_x: f32, center_y: f32, color: [4]f32, brightness: f32, clip: [4]f32) Led {
    assert(brightness >= 0);
    assert(brightness <= 1);
    const led: Led = .{
        .rect = .{ center_x - side_px * 0.5, center_y - side_px * 0.5, side_px, side_px },
        .clip = clip,
        .color = color,
        .brightness = brightness,
        .pad0 = 0,
        .pad1 = 0,
        .pad2 = 0,
    };
    assert(led.rect[2] == side_px);
    assert(led.pad0 == 0);
    return led;
}

comptime {
    assert(draw.check_type(Led) == null);
    assert(@sizeOf(Led) == 64);
    assert(@offsetOf(Led, "brightness") == 48);
}

// Locks the generated interface of an app-defined type: four groups at locations 1 to 4, and
// `brightness` unpacked from the first lane of the fourth group.
test "led assembles against the prelude" {
    const text = comptime draw.type_source(Led);
    try std.testing.expect(std.mem.find(u8, text, "@location(4) g3: vec4<f32>") != null);
    try std.testing.expect(std.mem.find(u8, text, "@location(5) g4") == null);
    try std.testing.expect(std.mem.find(u8, text, "px.brightness = v.g3.x;") != null);
    try std.testing.expect(std.mem.find(u8, text, "fn pixel(px: Pixel)") != null);
    const led = at(100, 50, .{ 0.4, 0.8, 0.4, 1 }, 0.5, .{ 0, 0, 200, 200 });
    try std.testing.expectEqual(@as(f32, 90), led.rect[0]);
    try std.testing.expectEqual(@as(f32, 40), led.rect[1]);
}

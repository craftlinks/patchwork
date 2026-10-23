//! The live app's own draw type: small filled icons for the transport and the parse status.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why an App-Defined Type
//! A play triangle has no library primitive (boxes, arcs, glyphs, images, and stroked paths),
//! and Noto Sans maps no check or cross. Like the rack's `Led`, `Icon` is an `extern struct`
//! plus a WGSL `pixel` function registered in `App.config.draw`, with no library edit.
//!
//! ## 2. Instance Layout and Pixel
//! `rect`, `clip`, `color`, then `shape` (a `Shape` value as an `f32`) and three zero pads:
//! 64 bytes, four groups. In the quad's local space, with `s = min(size)` and the icon drawn
//! in the centered `s` square:
//! ```text
//! back    a bar at the left and a triangle pointing left
//! play    a triangle pointing right
//! pause   two bars
//! record  a disc
//! check   two strokes (a short down-right, a long up-right)
//! cross   two crossing strokes
//! ```
//! Every distance is computed unconditionally and one is picked with `select`, so `coverage`
//! (which calls `fwidth`) runs once in uniform control flow (prelude guide).
//!
//! ## 3. TigerStyle Invariants
//! The `comptime` block checks the type against the draw type convention and pins its size.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const draw = patchwork.draw;

pub const Shape = enum(u8) {
    back = 0,
    play = 1,
    pause = 2,
    record = 3,
    check = 4,
    cross = 5,
};

/// A filled icon. See the module guide.
pub const Icon = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    shape: f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn icon_triangle(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, c: vec2<f32>) -> f32 {
        \\    let e0 = b - a;
        \\    let e1 = c - b;
        \\    let e2 = a - c;
        \\    let v0 = p - a;
        \\    let v1 = p - b;
        \\    let v2 = p - c;
        \\    let q0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
        \\    let q1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
        \\    let q2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
        \\    let s = sign(e0.x * e2.y - e0.y * e2.x);
        \\    let d0 = vec2<f32>(dot(q0, q0), s * (v0.x * e0.y - v0.y * e0.x));
        \\    let d1 = vec2<f32>(dot(q1, q1), s * (v1.x * e1.y - v1.y * e1.x));
        \\    let d2 = vec2<f32>(dot(q2, q2), s * (v2.x * e2.y - v2.y * e2.x));
        \\    let d = min(min(d0, d1), d2);
        \\    return -sqrt(d.x) * sign(d.y);
        \\}
        \\
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let side = min(px.size.x, px.size.y);
        \\    let p = (px.local - (px.size - vec2<f32>(side, side)) * 0.5) / side;
        \\    let bar = vec2<f32>(0.14, 0.7);
        \\    let back_bar = sdf_box(p - vec2<f32>(0.15, 0.15), bar, 0.03);
        \\    let back_tri = icon_triangle(p, vec2<f32>(0.85, 0.15), vec2<f32>(0.85, 0.85),
        \\        vec2<f32>(0.32, 0.5));
        \\    let back = min(back_bar, back_tri);
        \\    let play = icon_triangle(p, vec2<f32>(0.2, 0.12), vec2<f32>(0.2, 0.88),
        \\        vec2<f32>(0.88, 0.5));
        \\    let pause = min(sdf_box(p - vec2<f32>(0.22, 0.15), bar, 0.03),
        \\        sdf_box(p - vec2<f32>(0.64, 0.15), bar, 0.03));
        \\    let record = sdf_circle(p, vec2<f32>(0.5, 0.5), 0.36);
        \\    let check = min(sdf_segment(p, vec2<f32>(0.15, 0.52), vec2<f32>(0.4, 0.78)),
        \\        sdf_segment(p, vec2<f32>(0.4, 0.78), vec2<f32>(0.86, 0.22))) - 0.08;
        \\    let cross = min(sdf_segment(p, vec2<f32>(0.2, 0.2), vec2<f32>(0.8, 0.8)),
        \\        sdf_segment(p, vec2<f32>(0.8, 0.2), vec2<f32>(0.2, 0.8))) - 0.08;
        \\    let shape = u32(px.shape + 0.5);
        \\    var dist = select(back, play, shape == 1u);
        \\    dist = select(dist, pause, shape == 2u);
        \\    dist = select(dist, record, shape == 3u);
        \\    dist = select(dist, check, shape == 4u);
        \\    dist = select(dist, cross, shape == 5u);
        \\    return vec4<f32>(px.color.rgb, px.color.a * coverage(dist * side));
        \\}
        \\
    ;
};

/// An icon of `shape` filling `rect`, clipped to `clip`.
pub fn at(rect: draw.Rect, shape: Shape, color: [4]f32, clip: draw.Clip) Icon {
    assert(rect.width > 0);
    assert(rect.height > 0);
    const icon: Icon = .{
        .rect = .{ rect.x, rect.y, rect.width, rect.height },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = color,
        .shape = @floatFromInt(@backingInt(shape)),
        .pad0 = 0,
        .pad1 = 0,
        .pad2 = 0,
    };
    assert(icon.shape <= 5);
    assert(icon.pad0 == 0);
    return icon;
}

comptime {
    assert(draw.check_type(Icon) == null);
    assert(@sizeOf(Icon) == 64);
    assert(@offsetOf(Icon, "shape") == 48);
    assert(@typeInfo(Shape).@"enum".field_names.len == 6);
}

// Locks the generated interface: four groups at locations 1 to 4, `shape` unpacked from the
// first lane of the fourth group, and the helper and `pixel` in the module.
test "icon assembles against the prelude" {
    const text = comptime draw.type_source(Icon);
    try std.testing.expect(std.mem.find(u8, text, "@location(4) g3: vec4<f32>") != null);
    try std.testing.expect(std.mem.find(u8, text, "@location(5) g4") == null);
    try std.testing.expect(std.mem.find(u8, text, "px.shape = v.g3.x;") != null);
    try std.testing.expect(std.mem.find(u8, text, "fn icon_triangle(") != null);
    const icon = at(.{ .x = 10, .y = 20, .width = 16, .height = 16 }, .record, .{ 1, 0, 0, 1 }, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 100,
        .y1 = 100,
    });
    try std.testing.expectEqual(@as(f32, 3), icon.shape);
    try std.testing.expectEqual(@as(f32, 26), icon.rect[0] + icon.rect[2]);
}

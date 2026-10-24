//! The live app's animated draw type: a soft glow that breathes with the frame's time.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why an Animated Type
//! An armed record button pulses. Driving the pulse from an instance field would need a
//! `cx.redraw()`, a full `App.draw`, and a tile rehash every frame. `Glow` declares
//! `animated = true` and reads the uniform's time instead (`draw/registry.zig`, section 2b),
//! so while it is on screen and nothing else changes, a frame writes 16 bytes of uniform and
//! repaints the glow's tiles only (`draw/renderer.zig`, section 4b). The screen stops
//! animating when the app stops drawing it: disarmed and paused, the process sleeps.
//!
//! ## 2. Instance Layout and Pixel
//! `rect`, `clip`, `color`, then `rate_hz` and three zero pads: 64 bytes, four groups. With
//! `center = size / 2` and `radius = min(center)`:
//! ```text
//! reach  = clamp(1 - |local - center| / radius, 0, 1)
//! breath = 0.35 + 0.65 * time_pulse(rate_hz)          0.35 at whole periods, 1 halfway
//! rgb    = color.rgb
//! alpha  = color.a * reach * breath
//! ```
//! No derivatives and no branches, so nothing in `pixel` constrains uniform control flow.
//!
//! ## 3. TigerStyle Invariants
//! The `comptime` block checks the type against the draw type convention and pins its size.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const draw = patchwork.draw;

/// A breathing radial glow. See the module guide.
pub const Glow = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    rate_hz: f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const animated = true;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let center = px.size * 0.5;
        \\    let radius = max(min(center.x, center.y), 1.0e-5);
        \\    let reach = clamp(1.0 - length(px.local - center) / radius, 0.0, 1.0);
        \\    let breath = 0.35 + 0.65 * time_pulse(px.rate_hz);
        \\    return vec4<f32>(px.color.rgb, px.color.a * reach * breath);
        \\}
        \\
    ;
};

/// How far the glow reaches past the face it surrounds, on every side, in logical pixels.
pub const spread_px: f32 = 8;

/// A glow of `color` around `face`, breathing `rate_hz` times a second, clipped to `clip`.
pub fn around(face: draw.Rect, color: [4]f32, rate_hz: f32, clip: draw.Clip) Glow {
    assert(face.width > 0);
    assert(face.height > 0);
    assert(rate_hz > 0);
    const glow: Glow = .{
        .rect = .{
            face.x - spread_px,
            face.y - spread_px,
            face.width + 2 * spread_px,
            face.height + 2 * spread_px,
        },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = color,
        .rate_hz = rate_hz,
        .pad0 = 0,
        .pad1 = 0,
        .pad2 = 0,
    };
    assert(glow.rect[2] == face.width + 2 * spread_px);
    assert(glow.pad0 == 0);
    return glow;
}

comptime {
    assert(draw.check_type(Glow) == null);
    assert(@sizeOf(Glow) == 64);
    assert(@offsetOf(Glow, "rate_hz") == 48);
}

// Locks the generated interface (`rate_hz` from the first lane of the fourth group, the time
// helper in the module) and the spread around the face.
test "glow assembles against the prelude and surrounds its face" {
    const text = comptime draw.type_source(Glow);
    try std.testing.expect(std.mem.find(u8, text, "px.rate_hz = v.g3.x;") != null);
    try std.testing.expect(std.mem.find(u8, text, "fn time_pulse(hz: f32)") != null);
    const face: draw.Rect = .{ .x = 10, .y = 20, .width = 18, .height = 18 };
    const glow = around(face, .{ 1, 0, 0, 1 }, 1, .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 });
    try std.testing.expectEqual([4]f32{ 2, 12, 34, 34 }, glow.rect);
    try std.testing.expectEqual(@as(f32, 1), glow.rate_hz);
}

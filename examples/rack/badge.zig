//! The rack's procedural badge: a 32 by 32 RGBA image generated once, at init.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Generated
//! The badge is the rack's first image texture. Generating it in `App.init` exercises the
//! whole texture path (`Textures.create(.rgba8, ...)`, a queued `write`, the renderer's
//! flush, and `draw.Image` sampling) without shipping an asset. The pixels live in the app,
//! which outlives every stream, as `draw/textures.zig` requires.
//!
//! ## 2. The Picture
//! With `d` the distance of a texel center from the image center (in texels), straight
//! alpha, and every term clamped to `[0, 1]`:
//! ```text
//! base  = mix(top, bottom, y / (side - 1))      vertical gradient between two accents
//! disc  = clamp(edge_radius - d, 0, 1)          one-texel antialiased outline
//! ring  = clamp(1 - abs(d - ring_radius), 0, 1) a light ring
//! dot   = clamp(dot_radius - d, 0, 1)           a light center dot
//! rgb   = mix(base, white, max(ring, dot) * 0.8)
//! alpha = disc
//! ```
//! Only `@sqrt` is used, no trigonometry; test "badge is an opaque disc with a clear corner"
//! locks the samples.

const std = @import("std");
const assert = std.debug.assert;

/// Edge of the square badge texture, in texels.
pub const side: u32 = 32;

/// Bytes of one RGBA badge.
pub const bytes: u32 = side * side * 4;

const edge_radius: f32 = 15;
const ring_radius: f32 = 10;
const dot_radius: f32 = 4;
const top: [3]f32 = .{ 0.62, 0.45, 0.86 };
const bottom: [3]f32 = .{ 0.93, 0.55, 0.24 };

/// Writes the badge into `pixels`, row-major, four bytes per texel.
pub fn fill(pixels: *[bytes]u8) void {
    var y: u32 = 0;
    while (y < side) : (y += 1) {
        var x: u32 = 0;
        while (x < side) : (x += 1) {
            const texel = shade(x, y);
            const at = (y * side + x) * 4;
            for (texel, 0..) |channel, index| {
                pixels[at + index] = @intFromFloat(@round(channel * 255));
            }
        }
        assert(x == side);
    }
    assert(y == side);
}

fn shade(x: u32, y: u32) [4]f32 {
    assert(x < side);
    assert(y < side);
    const half: f32 = @as(f32, @floatFromInt(side)) * 0.5;
    const dx = @as(f32, @floatFromInt(x)) + 0.5 - half;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - half;
    const d = @sqrt(dx * dx + dy * dy);
    const t = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(side - 1));
    const disc = std.math.clamp(edge_radius - d, 0, 1);
    const ring = std.math.clamp(1 - @abs(d - ring_radius), 0, 1);
    const dot = std.math.clamp(dot_radius - d, 0, 1);
    const light = @max(ring, dot) * 0.8;
    var out: [4]f32 = undefined;
    for (0..3) |channel| {
        const base = top[channel] + (bottom[channel] - top[channel]) * t;
        out[channel] = base + (1 - base) * light;
    }
    out[3] = disc;
    assert(out[3] >= 0);
    assert(out[3] <= 1);
    return out;
}

// Locks the picture: the center texel is an opaque light dot, a corner is fully clear, and a
// texel on the ring is lighter than the gradient between it and the edge.
test "badge is an opaque disc with a clear corner" {
    var pixels: [bytes]u8 = undefined;
    fill(&pixels);
    const center = (16 * side + 16) * 4;
    try std.testing.expectEqual(@as(u8, 255), pixels[center + 3]);
    try std.testing.expect(pixels[center] > 200);
    try std.testing.expectEqual(@as(u8, 0), pixels[3]);
    const ring = (16 * side + 26) * 4;
    const plain = (16 * side + 29) * 4;
    try std.testing.expect(pixels[ring + 1] > pixels[plain + 1]);
    try std.testing.expectEqual(@as(u8, 255), pixels[plain + 3]);
}

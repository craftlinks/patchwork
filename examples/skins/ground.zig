//! What draws behind everything: Paper's pale street map and Patch's dot grid, as textures generated
//! at init.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Generated
//! `png.zig` reads only stored PNGs, and the example ships no image, so both grounds are made in
//! `App.init`, as the rack makes its badge (`Textures.create_sampled`, a queued `write`,
//! `draw.Image`). The texels live in the app, which outlives every stream. Each look draws at
//! most one `Image` over the screen, first in `draw`, so the base layer's first batch is the
//! ground and every face covers it. Codex and HUD draw none.
//!
//! ## 2. The Map
//! `map_w` by `map_h` RGBA, white ink whose alpha is the picture, linear and clamped, stretched
//! over the 1280 by 720 screen (5 px a texel): a printed street map, city blocks between
//! light streets on a grid turned about 20 degrees, and two families of diagonal roads.
//! ```text
//! (u, v)  = (0.94 x + 0.342 y, 0.94 y - 0.342 x + v_shift)     texel centres, turned
//! street  = fract(u / block_u) < street_u or fract(v / block_v) < street_v   alpha 0
//! block   = h(floor(u / block_u), floor(v / block_v))        an integer hash in [0, 1)
//!           h < open_share ? 0 : block_ink + block_spread * h
//! road    = |mod(x - 1.4 y, road_a) - road_a / 2| < road_half, or the same of x + 2.5 y
//!           with road_b: alpha road_ink, over the rest
//! ```
//! Only `+ - * /` and `@floor`: no trigonometry (the turn is two constants), so native and
//! wasm make the same bytes. The look's `ground_tint` colours the ink; Paper's is a warm grey
//! at alpha 0.22, so the map reads under the panels without competing with them.
//!
//! ## 3. The Dots
//! `dot_side` square, one disc of about three texels at the centre, repeated with nearest
//! sampling: drawn with uv `(0, 0, 80, 45)` over the screen, one dot every 16 px, one texel a
//! pixel.
//!
//! ## 4. TigerStyle Invariants
//! - Sizes are constants; the arrays are the app's, written once.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const looks = @import("looks.zig");

const Rect = quads.Rect;

pub const map_w: u32 = 256;
pub const map_h: u32 = 144;
pub const map_bytes: u32 = map_w * map_h * 4;
/// The map's blocks along each turned axis, its streets' share of a block, and how blocks ink.
const block_u: f32 = 13;
const block_v: f32 = 10;
const street_u: f32 = 0.16;
const street_v: f32 = 0.2;
const v_shift: f32 = 100;
const open_share: f32 = 0.2;
const block_ink: f32 = 0.2;
const block_spread: f32 = 0.5;
/// The two road families' periods along x, their half width, and their ink.
const road_a: f32 = 90;
const road_b: f32 = 150;
const road_half: f32 = 0.9;
const road_ink: f32 = 0.85;

pub const dot_side: u32 = 16;
pub const dot_bytes: u32 = dot_side * dot_side * 4;
/// The disc's edge: texels nearer the centre than this, less one for the soft edge, are ink.
const dot_reach: f32 = 2;

const map_sampling: quads.TextureSampling = .{
    .filter = .linear,
    .address_u = .clamp,
    .address_v = .clamp,
};
const dot_sampling: quads.TextureSampling = .{
    .filter = .nearest,
    .address_u = .repeat,
    .address_v = .repeat,
};

/// The screen the ground covers, logical pixels.
pub const screen: Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };

comptime {
    assert(street_u < 0.5 and street_v < 0.5);
    assert(block_ink + block_spread <= 1);
    assert(screen.width == 5 * @as(f32, @floatFromInt(map_w)));
    assert(screen.height == 5 * @as(f32, @floatFromInt(map_h)));
    assert(@mod(screen.width, @as(f32, @floatFromInt(dot_side))) == 0);
    assert(@mod(screen.height, @as(f32, @floatFromInt(dot_side))) == 0);
}

/// The grounds' texels and textures.
pub const Ground = struct {
    map: [map_bytes]u8,
    dots: [dot_bytes]u8,
    map_texture: quads.TextureId,
    dot_texture: quads.TextureId,

    /// Generates both pictures and queues their uploads.
    pub fn init(self: *Ground, textures: *quads.Textures) void {
        fill_map(&self.map);
        fill_dots(&self.dots);
        self.map_texture = textures.create_sampled(.rgba8, map_w, map_h, map_sampling);
        textures.write(self.map_texture, full(map_w, map_h), &self.map);
        self.dot_texture = textures.create_sampled(.rgba8, dot_side, dot_side, dot_sampling);
        textures.write(self.dot_texture, full(dot_side, dot_side), &self.dots);
        assert(self.map_texture != self.dot_texture);
    }

    /// One `Image` over the screen for `look`'s ground, or nothing.
    pub fn draw(self: *const Ground, cx: anytype, look: *const looks.Look) void {
        assert(look.ground_tint[3] >= 0);
        const texture, const uv = switch (look.ground) {
            .none => return,
            .map => .{ self.map_texture, [4]f32{ 0, 0, 1, 1 } },
            .dots => .{ self.dot_texture, dot_uv },
        };
        const record: quads.Image = .{
            .rect = screen.array(),
            .clip = .{ screen.x, screen.y, screen.x + screen.width, screen.y + screen.height },
            .uv = uv,
            .tint = look.ground_tint,
        };
        patchwork.widgets.kit.append(cx, quads.Image, texture, record);
    }
};

/// The dot tile repeated once every `dot_side` pixels over the screen.
pub const dot_uv: [4]f32 = .{
    0,
    0,
    screen.width / @as(f32, @floatFromInt(dot_side)),
    screen.height / @as(f32, @floatFromInt(dot_side)),
};

fn full(width: u32, height: u32) quads.TextureRegion {
    return .{ .x = 0, .y = 0, .width = width, .height = height };
}

/// Writes the map (section 2), row-major, four bytes a texel.
pub fn fill_map(out: *[map_bytes]u8) void {
    var y: u32 = 0;
    while (y < map_h) : (y += 1) {
        var x: u32 = 0;
        while (x < map_w) : (x += 1) {
            const at = (y * map_w + x) * 4;
            out[at + 0] = 255;
            out[at + 1] = 255;
            out[at + 2] = 255;
            out[at + 3] = map_alpha(x, y);
        }
    }
    assert(y == map_h);
}

/// The map's ink at texel `(x, y)`, 0 to 255 (section 2).
pub fn map_alpha(x: u32, y: u32) u8 {
    assert(x < map_w);
    assert(y < map_h);
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    var ink: f32 = 0;
    const u = (0.94 * px + 0.342 * py) / block_u;
    const v = (0.94 * py - 0.342 * px + v_shift) / block_v;
    assert(u >= 0 and v >= 0);
    const street = u - @floor(u) < street_u or v - @floor(v) < street_v;
    if (!street) {
        const shade = lattice(@intFromFloat(@floor(u)), @intFromFloat(@floor(v)), 7);
        if (shade >= open_share) ink = block_ink + block_spread * shade;
    }
    if (road(px - 1.4 * py, road_a) or road(px + 2.5 * py, road_b)) ink = road_ink;
    const alpha: u8 = @intFromFloat(@round(255 * @min(ink, 1)));
    assert(alpha <= 255);
    return alpha;
}

/// True when `along` lies within `road_half` of the middle of a `period` (a road's centre).
fn road(along: f32, period: f32) bool {
    assert(period > 0);
    const shifted = along + 4 * period;
    assert(shifted >= 0);
    const phase = shifted - period * @floor(shifted / period);
    return @abs(phase - period / 2) < road_half;
}

/// An integer hash of the point `(ix, iy)` and `salt`, in `[0, 1)`.
fn lattice(ix: u32, iy: u32, salt: u32) f32 {
    var h: u32 = ix *% 0x8da6b343 +% iy *% 0xd8163841 +% salt *% 0xcb1ab31f;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    h *%= 0x297a2d39;
    h ^= h >> 15;
    const value = @as(f32, @floatFromInt(h >> 8)) / 16777216.0;
    assert(value >= 0 and value < 1);
    return value;
}

/// Writes the dot tile (section 3).
pub fn fill_dots(out: *[dot_bytes]u8) void {
    const centre: f32 = @as(f32, @floatFromInt(dot_side / 2)) + 0.5;
    var y: u32 = 0;
    while (y < dot_side) : (y += 1) {
        var x: u32 = 0;
        while (x < dot_side) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - centre;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - centre;
            const coverage = std.math.clamp(dot_reach - @sqrt(dx * dx + dy * dy), 0, 1);
            const at = (y * dot_side + x) * 4;
            out[at + 0] = 255;
            out[at + 1] = 255;
            out[at + 2] = 255;
            out[at + 3] = @intFromFloat(@round(255 * coverage));
        }
    }
    assert(y == dot_side);
}

// Locks the map's picture (section 2): every texel's rgb is white; 20,127 of 36,864 texels carry
// ink (about 55 %: blocks between streets, not lines on a blank sheet), 1,239 of them roads at
// 217 (0.85 of 255); the corner (0, 0) is a street, the middle (128, 72) a block at 166.
test "the map is blocks, streets, and roads in white ink" {
    var map: [map_bytes]u8 = undefined;
    fill_map(&map);
    var inked: u32 = 0;
    var roads: u32 = 0;
    var index: u32 = 0;
    while (index < map_w * map_h) : (index += 1) {
        try std.testing.expectEqual(@as(u8, 255), map[index * 4]);
        if (map[index * 4 + 3] > 0) inked += 1;
        if (map[index * 4 + 3] == 217) roads += 1;
    }
    try std.testing.expectEqual(@as(u32, 20_127), inked);
    try std.testing.expectEqual(@as(u32, 1_239), roads);
    try std.testing.expectEqual(@as(u8, 0), map[3]);
    try std.testing.expectEqual(@as(u8, 166), map[(72 * map_w + 128) * 4 + 3]);
    try std.testing.expectEqual(map_alpha(128, 72), map[(72 * map_w + 128) * 4 + 3]);
}

// Locks the dot tile (section 3): the centre texel is opaque ink, its four neighbours too, a
// diagonal neighbour partly, and the corner texel is clear.
test "the dot tile is one small disc" {
    var dots: [dot_bytes]u8 = undefined;
    fill_dots(&dots);
    const alpha = struct {
        fn at(tile: *const [dot_bytes]u8, x: u32, y: u32) u8 {
            return tile[(y * dot_side + x) * 4 + 3];
        }
    }.at;
    try std.testing.expectEqual(@as(u8, 255), alpha(&dots, 8, 8));
    try std.testing.expectEqual(@as(u8, 255), alpha(&dots, 9, 8));
    try std.testing.expectEqual(@as(u8, 255), alpha(&dots, 8, 7));
    try std.testing.expectEqual(@as(u8, 149), alpha(&dots, 9, 9));
    try std.testing.expectEqual(@as(u8, 0), alpha(&dots, 10, 8));
    try std.testing.expectEqual(@as(u8, 0), alpha(&dots, 0, 0));
}

//! Backdrops and glass: the blur chain under a marked layer and the `Glass` type that samples it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Backdrop Is a Render Pass
//! Glass shows what lies under it, blurred. No draw type can read the pixels of the pass it
//! draws in, so the layers under the glass must be drawn somewhere a shader can sample first.
//! `Context.backdrop(layer, blur)` marks a layer: the renderer draws every layer below it into
//! a window-sized scene target, blurs that into a pack (sections 2 and 3), copies the scene
//! into the main pass, and continues with the marked layer, whose glass samples the pack
//! (`draw/renderer.zig`, section 4e). A backdrop takes no layer of its own. At most
//! `backdrop_cap` are marked per frame, one per layer: one under panels and one under popups,
//! so a popup's glass blurs the glass panel under it. Glass on the same level as other glass
//! does not see it.
//!
//! ## 2. The Chain (Dual Filter)
//! Level `k` is the scene at `1 / 2^k` of its device size, `ceil(edge / 2^k)` texels a side;
//! its texel `j` covers device pixels `[2^k j, 2^k (j + 1))`, so a level covers a little more
//! than the window when an edge is odd, and every tap is clamped into its source (`bounds`).
//! With `n` levels and offset `o` (`chain_for`):
//! ```text
//! down   scene -> level 1 (the pack's left half) -> level 2 -> ... -> level n
//!        out = (4 c + the four diagonal taps at (+-h, +-h)) / 8
//! up     level n -> level n-1 -> ... -> level 2 -> level 1 (the pack's right half)
//!        out = (the four taps at (+-2h, 0), (0, +-2h) + 2 * the four at (+-h, +-h)) / 12
//!        h = o * half a source texel, every tap bilinear
//! ```
//! `2n - 1` passes, the first at half the window's pixels and each next a quarter of the one
//! before, so a wide blur costs about what a narrow one does (Bjorge, "Bandwidth-Efficient
//! Rendering", 2015). Levels `2 .. n` live in shared temporaries; a level's up pass overwrites
//! its down result, which nothing reads again.
//!
//! ## 2a. Only Where Glass Is
//! A chain blurs only what its glass reads. The renderer takes the union of the device rects
//! of every instance that samples the backdrop (cut by their clips), grows it by `reach` (each
//! pass's tap and bilinear extent in device pixels, and the glass's own read), clamps it to the
//! window, and scissors every pass to it in that pass's texels (`scissor_of`). Texels outside
//! keep whatever they held; a pass that reads one spreads it inward by at most its own extent,
//! so after every pass the stale ring is at most `reach` deep and the union itself is exact, in
//! a cached frame as in a direct one. The union is part of the chain's key, so moving a glass
//! re-renders it, and a backdrop no instance samples renders no chain at all. A lens of 28 px
//! blurs a few hundred texels instead of the window.
//!
//! ## 3. The Pack
//! One target of `2 w1` by `h1` texels (`w1`, `h1` the level-1 size) holds two images the glass
//! mixes by its `frost`: on the left the first down pass (light, sigma about 1 device pixel),
//! on the right the last up pass (heavy). One texture, so a glass binds one bind group. A
//! fragment at device position `d` reads texel coordinate `d / 2` of a half (`pack_texel`),
//! clamped half a texel inside it so the halves never bleed into each other.
//!
//! ## 4. Strength
//! The chain's spread is calibrated against its CPU twin (`twin_chain`: the passes along one
//! axis, which is the x marginal of a vertical line impulse, read back as the glass reads the
//! pack and averaged over the impulse's phase against the coarsest level). The variance in
//! device pixels squared fits
//! ```text
//! sigma^2(n, o) = (4^n - 1) / 6 + (19 * 4^n - 67) / 36 * o^2
//! ```
//! exactly at `o = 1` and `o = 2` and within 7% from 0.5 to 2 (test "the chain's spread matches
//! the formula"). It is linear in `o^2`, so `chain_for` takes the fewest levels whose
//! `o = offset_max` reaches the asked sigma and solves for `o`; the narrowest offset of each
//! level count lies below the widest of the one before, so every sigma from 2.0 to 96 device
//! pixels has a chain (test "the levels cover every sigma"). Fewer levels at a wider offset
//! would be cheaper but sparser; this choice keeps `o <= 2`, where the taps still overlap.
//! `Context.backdrop` takes sigma in logical pixels, as CSS's `blur()` does.
//!
//! ## 5. Glass
//! `Glass` (80 bytes) is a rounded rect over the pack. Per fragment:
//! ```text
//! dist    = sdf_box(local, size, radius)             outer = coverage(dist)
//! normal  = the distance field's gradient (central differences, half a unit apart)
//! band    = clamp(1 + dist / bevel, 0, 1)            1 at the outline, 0 a bevel inside
//! device  = frag - normal * refraction * band^2 * device pixels per unit
//! color   = mix(light, heavy, frost) at pack_texel(device)
//!         -> saturation around Rec. 709 luma -> mix toward tint.rgb by tint.a
//! rim     = rim * (ring of rim_width at the outline * (0.35 + 0.65 |normal . light|)
//!                  + 0.12 band^2)                    light from the top left
//! out     = (mix(color, theme.lighten, rim), outer)
//! ```
//! The edge pixels read the backdrop nearer the centre, so the outline bends what is under it
//! like a lens; a small disc of high refraction is a magnifier. `frag` is the fragment's
//! device position, so glass only draws in window-sized passes (the scene and main passes),
//! never on a layer bound to an offscreen target. The device pixels per unit come from
//! `dpdx(pos.x)`, so they include a view's zoom. `coverage` and `dpdx` run unconditionally and
//! the pack is read with `sample_texture_level`, so the derivatives stay uniform.
//!
//! ## 6. TigerStyle Invariants
//! `levels` in `[level_min, level_max]`, `offset` in `[offset_min, offset_max]`, at most
//! `pass_max` passes per backdrop, and `Glass.of` asserts every look range.

const std = @import("std");
const assert = std.debug.assert;
const textures = @import("textures.zig");
const types = @import("types.zig");

const Rect = @import("../draw.zig").Rect;
const Clip = @import("../draw.zig").Clip;

/// Backdrops one frame may mark (section 1).
pub const backdrop_cap: u32 = 2;

/// Fewest and most levels of a chain (section 2).
pub const level_min: u32 = 2;
pub const level_max: u32 = 6;

/// The tap offset's range, in half source texels (section 4).
pub const offset_min: f32 = 0.5;
pub const offset_max: f32 = 2.0;

/// Passes of one chain at most: `level_max` down and `level_max - 1` up.
pub const pass_max: u32 = 2 * level_max - 1;

/// Shared temporaries: levels 2 to `level_max`.
pub const temp_count: u32 = level_max - 1;

/// A marked layer this frame: its layer, its blur sigma in logical pixels, and the id its
/// glass samples (section 1).
pub const Backdrop = struct {
    layer: u8,
    blur: f32,
    id: textures.TextureId,
};

/// How many levels and what offset a blur takes (section 4).
pub const Chain = struct {
    levels: u32,
    offset: f32,
};

/// The variance in device pixels squared of `levels` levels at `offset` (section 4).
pub fn variance(levels: u32, offset: f32) f32 {
    assert(levels >= level_min and levels <= level_max);
    assert(offset >= 0);
    const constant, const slope = coefficients(levels);
    return constant + slope * offset * offset;
}

/// `variance(levels, o)` is `constant + slope * o^2` (section 4).
fn coefficients(levels: u32) struct { f32, f32 } {
    assert(levels >= 1 and levels <= level_max);
    const power: f32 = @floatFromInt(@as(u32, 1) << @intCast(2 * levels));
    const constant = (power - 1) / 6;
    const slope = (19 * power - 67) / 36;
    assert(constant > 0 and slope > 0);
    return .{ constant, slope };
}

/// The fewest levels whose widest offset reaches `sigma` device pixels, and the offset that
/// gives it, clamped to the range (section 4). `sigma` beyond the widest chain gets it.
pub fn chain_for(sigma: f32) Chain {
    assert(sigma >= 0);
    assert(!std.math.isNan(sigma));
    var levels: u32 = level_min;
    while (levels < level_max) : (levels += 1) {
        if (variance(levels, offset_max) >= sigma * sigma) break;
    }
    const constant, const slope = coefficients(levels);
    const wanted = (sigma * sigma - constant) / slope;
    const offset = std.math.clamp(@sqrt(@max(wanted, 0)), offset_min, offset_max);
    assert(offset >= offset_min and offset <= offset_max);
    return .{ .levels = levels, .offset = offset };
}

/// How far, in device pixels, the chain's output and the glass's read of it reach into the
/// scene (section 2a): every pass's taps and bilinear neighbour in its source's texels, and
/// the glass's bilinear read of the pack.
pub fn reach(chain: Chain) f32 {
    assert(chain.levels >= level_min and chain.levels <= level_max);
    assert(chain.offset >= 0);
    var total: f32 = 4;
    var level: u32 = 1;
    while (level <= chain.levels) : (level += 1) {
        const texel: f32 = @floatFromInt(@as(u32, 1) << @intCast(level - 1));
        total += texel * (chain.offset * 0.5 + 1);
    }
    level = 1;
    while (level < chain.levels) : (level += 1) {
        const texel: f32 = @floatFromInt(@as(u32, 1) << @intCast(level + 1));
        total += texel * (chain.offset + 1);
    }
    assert(total > 4);
    return total;
}

/// The scissor of a pass writing `surface` (`Surface`) for a region of interest `region` in
/// device pixels (x0, y0, x1, y1) of a `width` by `height` scene (section 2a): the region in
/// the surface's texels, rounded out, clamped to its image, and for the pack's right half (the
/// last up pass) moved by the half's width.
pub fn scissor_of(region: [4]u32, width: u32, height: u32, surface: Surface, up: bool) [4]u32 {
    assert(region[0] < region[2] and region[1] < region[3]);
    assert(surface >= 1);
    const shift: u5 = @intCast(surface);
    const image_w = level_size(width, surface);
    const image_h = level_size(height, surface);
    const x0 = region[0] >> shift;
    const y0 = region[1] >> shift;
    const x1 = @min((region[2] + (@as(u32, 1) << shift) - 1) >> shift, image_w);
    const y1 = @min((region[3] + (@as(u32, 1) << shift) - 1) >> shift, image_h);
    const left: u32 = if (surface == 1 and up) image_w else 0;
    const out: [4]u32 = .{ left + x0, y0, x1 - x0, y1 - y0 };
    assert(out[2] >= 1 and out[3] >= 1);
    return out;
}

/// The texel count of level `level` along an edge of `edge` device pixels (section 2).
pub fn level_size(edge: u32, level: u32) u32 {
    assert(edge >= 1);
    assert(level <= level_max);
    const span = @as(u32, 1) << @intCast(level);
    const out = (edge + span - 1) / span;
    assert(out >= 1);
    return out;
}

/// The pack's size for a scene of `width` by `height` device pixels: two level-1 images side by
/// side (section 3).
pub fn pack_size(width: u32, height: u32) [2]u32 {
    return .{ 2 * level_size(width, 1), level_size(height, 1) };
}

/// The texel coordinate of device position `device` in either half of a pack whose half is
/// `half` texels long along that axis, clamped half a texel inside it (section 3).
pub fn pack_texel(device: f32, half: u32) f32 {
    assert(half >= 1);
    const most = @as(f32, @floatFromInt(half)) - 0.5;
    return std.math.clamp(device * 0.5, 0.5, most);
}

/// Which image a pass reads or writes: 0 the scene, 1 the pack (its left half when read, its
/// right half when written by the last pass), `k >= 2` the temporary of level `k`.
pub const Surface = u8;

/// One chain pass's instance (section 2): a quad in normalized device coordinates and how it
/// reads its source. 64 bytes, one record per pass in the renderer's chain buffer.
pub const Pass = extern struct {
    /// The quad: x0, y0 at its top-left, x1, y1 at its bottom-right, in NDC (y up).
    dst: [4]f32,
    /// The source uv at the quad's top-left (xy) and bottom-right (zw).
    src: [4]f32,
    /// Every tap is clamped into min (xy) and max (zw) source uv.
    bounds: [4]f32,
    /// The tap offset `h` in source uv in xy; z and w zero.
    step: [4]f32,
};

/// Where one pass reads and writes, and whether it is a down pass.
pub const Route = struct {
    source: Surface,
    target: Surface,
    down: bool,
};

/// A backdrop's passes for a scene of `width` by `height` device pixels (section 2): writes
/// `2 chain.levels - 1` records and routes and returns the count.
pub fn passes(
    chain: Chain,
    width: u32,
    height: u32,
    records: *[pass_max]Pass,
    routes: *[pass_max]Route,
) u32 {
    assert(chain.levels >= level_min and chain.levels <= level_max);
    assert(width >= 1 and height >= 1);
    var count: u32 = 0;
    var level: u32 = 1;
    while (level <= chain.levels) : (level += 1) {
        records[count] = pass_record(chain.offset, width, height, level - 1, level);
        routes[count] = .{ .source = @intCast(level - 1), .target = @intCast(level), .down = true };
        count += 1;
    }
    level = chain.levels - 1;
    while (level >= 1) : (level -= 1) {
        records[count] = pass_record(chain.offset, width, height, level + 1, level);
        routes[count] = .{
            .source = @intCast(level + 1),
            .target = @intCast(level),
            .down = false,
        };
        count += 1;
    }
    assert(count == 2 * chain.levels - 1);
    assert(routes[count - 1].target == 1);
    return count;
}

/// The record of the pass from level `from` to level `to` (sections 2 and 3).
fn pass_record(offset: f32, width: u32, height: u32, from: u32, to: u32) Pass {
    assert(from != to);
    assert(to >= 1);
    // The device span the destination covers, and the source's texture size and texel.
    const span_x: f32 = @floatFromInt(level_size(width, to) << @intCast(to));
    const span_y: f32 = @floatFromInt(level_size(height, to) << @intCast(to));
    const texel: f32 = @floatFromInt(@as(u32, 1) << @intCast(from));
    const source = surface_size(width, height, @intCast(from));
    const sx: f32 = @floatFromInt(source[0]);
    const sy: f32 = @floatFromInt(source[1]);
    // Level 1 is read from the pack's left half, whose valid texels end at w1.
    const valid_x: f32 = if (from == 1) sx / 2 else sx;
    const dst: [4]f32 = if (to != 1)
        .{ -1, 1, 1, -1 }
    else if (from == 0)
        .{ -1, 1, 0, -1 }
    else
        .{ 0, 1, 1, -1 };
    const record: Pass = .{
        .dst = dst,
        .src = .{ 0, 0, span_x / texel / sx, span_y / texel / sy },
        .bounds = .{ 0.5 / sx, 0.5 / sy, (valid_x - 0.5) / sx, (sy - 0.5) / sy },
        .step = .{ offset * 0.5 / sx, offset * 0.5 / sy, 0, 0 },
    };
    assert(record.bounds[2] >= record.bounds[0]);
    return record;
}

/// The texture size of surface `surface` for a scene of `width` by `height` (section 2).
pub fn surface_size(width: u32, height: u32, surface: Surface) [2]u32 {
    return switch (surface) {
        0 => .{ width, height },
        1 => pack_size(width, height),
        else => .{ level_size(width, surface), level_size(height, surface) },
    };
}

/// How a `Glass` looks (`Glass.of`, section 5). The defaults are a sharp-cornered glass of the
/// blurred level with no tint, rim, or bending.
pub const GlassLook = struct {
    radius: f32 = 0,
    /// Straight RGBA; its alpha is how far the backdrop moves toward its colour.
    tint: [4]f32 = types.transparent,
    /// 0 reads the light level, 1 the blurred one.
    frost: f32 = 1,
    /// 1 unchanged, 0 grey, above 1 more vivid; at most `saturation_max`.
    saturation: f32 = 1,
    /// `[0, 1]`: how far the rim and the bevel move toward `theme.lighten`.
    rim: f32 = 0,
    /// The lit ring's width at the outline, logical pixels.
    rim_width: f32 = 1,
    /// How far the outline bends the backdrop toward the centre, logical pixels.
    refraction: f32 = 0,
    /// The width of the bending band inside the outline, logical pixels.
    bevel: f32 = 12,
};

/// The most a glass may saturate.
pub const saturation_max: f32 = 2;

/// A rounded rect over a backdrop's pack (section 5). Appended with the id `backdrop`
/// returned, on its layer or above.
pub const Glass = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    tint: [4]f32,
    /// Radius, frost, saturation, rim.
    look: [4]f32,
    /// Refraction, bevel, rim width, unused.
    lens: [4]f32,

    pub const texture: ?textures.Format = .target;
    /// Samples a backdrop's pack, so the registry gives its context backdrops.
    pub const backdrop = true;

    /// The glass over `rect`, clipped to `clip`, looking like `look` (section 5).
    pub fn of(rect: Rect, clip: Clip, look: GlassLook) Glass {
        assert(look.radius >= 0);
        assert(look.frost >= 0 and look.frost <= 1);
        assert(look.saturation >= 0 and look.saturation <= saturation_max);
        assert(look.rim >= 0 and look.rim <= 1);
        assert(look.rim_width >= 0);
        assert(look.refraction >= 0);
        assert(look.bevel > 0);
        assert(look.tint[3] >= 0 and look.tint[3] <= 1);
        return .{
            .rect = rect.array(),
            .clip = clip.array(),
            .tint = look.tint,
            .look = .{ look.radius, look.frost, look.saturation, look.rim },
            .lens = .{ look.refraction, look.bevel, look.rim_width, 0 },
        };
    }

    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let radius = px.look.x;
        \\    let dist = sdf_box(px.local, px.size, radius);
        \\    let outer = coverage(dist);
        \\    let inner = coverage(dist + px.lens.z);
        \\    // Device pixels per unit: the scale times any view zoom (module guide, section 5).
        \\    let per_unit = 1.0 / max(abs(dpdx(px.pos.x)), 1.0e-6);
        \\    let e = vec2<f32>(0.5, 0.0);
        \\    let grad = vec2<f32>(
        \\        sdf_box(px.local + e.xy, px.size, radius) -
        \\            sdf_box(px.local - e.xy, px.size, radius),
        \\        sdf_box(px.local + e.yx, px.size, radius) -
        \\            sdf_box(px.local - e.yx, px.size, radius));
        \\    let normal = grad / max(length(grad), 1.0e-4);
        \\    let band = clamp(1.0 + dist / max(px.lens.y, 1.0e-3), 0.0, 1.0);
        \\    let spot = px.frag - normal * px.lens.x * band * band * per_unit;
        \\    let size = vec2<f32>(texture_size());
        \\    let span = vec2<f32>(size.x * 0.5, size.y);
        \\    let texel = clamp(spot * 0.5, vec2<f32>(0.5, 0.5), span - vec2<f32>(0.5, 0.5));
        \\    let light = sample_texture_level(texel / size);
        \\    let heavy = sample_texture_level((texel + vec2<f32>(span.x, 0.0)) / size);
        \\    var color = mix(light.rgb, heavy.rgb, px.look.y);
        \\    let luma = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
        \\    color = clamp(mix(vec3<f32>(luma), color, px.look.z), vec3<f32>(0.0), vec3<f32>(1.0));
        \\    color = mix(color, px.tint.rgb, px.tint.a);
        \\    let facing = abs(dot(normal, vec2<f32>(-0.4472136, -0.8944272)));
        \\    let ring = clamp(outer - inner, 0.0, 1.0) * (0.35 + 0.65 * facing);
        \\    let rim = clamp(px.look.w * (ring + 0.12 * band * band), 0.0, 1.0);
        \\    return vec4<f32>(mix(color, frame.theme.lighten.rgb, rim), outer);
        \\}
        \\
    ;
};

/// The bending band of section 5: 1 at the outline, 0 `bevel` inside it.
pub fn glass_band(dist: f32, bevel: f32) f32 {
    assert(bevel > 0);
    return std.math.clamp(1 + dist / bevel, 0, 1);
}

/// `color` saturated by `amount` around its Rec. 709 luma and clamped (section 5).
pub fn saturate(color: [3]f32, amount: f32) [3]f32 {
    assert(amount >= 0 and amount <= saturation_max);
    const luma = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
    var out: [3]f32 = undefined;
    for (&out, color) |*channel, value| {
        channel.* = std.math.clamp(luma + (value - luma) * amount, 0, 1);
    }
    return out;
}

/// The chain's WGSL head: the pass record, the source binding, and the clamped tap.
const chain_head: []const u8 =
    \\struct Record {
    \\    @location(1) dst: vec4<f32>,
    \\    @location(2) src: vec4<f32>,
    \\    @location(3) bounds: vec4<f32>,
    \\    @location(4) step: vec4<f32>,
    \\}
    \\
    \\struct Out {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) @interpolate(flat) bounds: vec4<f32>,
    \\    @location(2) @interpolate(flat) step: vec4<f32>,
    \\}
    \\
    \\@group(0) @binding(0) var source: texture_2d<f32>;
    \\@group(0) @binding(1) var source_sampler: sampler;
    \\
    \\@vertex
    \\fn vs_main(@location(0) unit: vec2<f32>, record: Record) -> Out {
    \\    var out: Out;
    \\    out.position = vec4<f32>(mix(record.dst.xy, record.dst.zw, unit), 0.0, 1.0);
    \\    out.uv = mix(record.src.xy, record.src.zw, unit);
    \\    out.bounds = record.bounds;
    \\    out.step = record.step;
    \\    return out;
    \\}
    \\
    \\fn tap(uv: vec2<f32>, bounds: vec4<f32>) -> vec4<f32> {
    \\    return textureSampleLevel(source, source_sampler, clamp(uv, bounds.xy, bounds.zw), 0.0);
    \\}
    \\
;

/// The down pass (section 2).
pub const down_wgsl: []const u8 = chain_head ++
    \\@fragment
    \\fn fs_main(v: Out) -> @location(0) vec4<f32> {
    \\    let h = v.step.xy;
    \\    let g = vec2<f32>(h.x, -h.y);
    \\    var sum = tap(v.uv, v.bounds) * 4.0;
    \\    sum = sum + tap(v.uv - h, v.bounds) + tap(v.uv + h, v.bounds);
    \\    sum = sum + tap(v.uv + g, v.bounds) + tap(v.uv - g, v.bounds);
    \\    return sum / 8.0;
    \\}
    \\
;

/// The up pass (section 2).
pub const up_wgsl: []const u8 = chain_head ++
    \\@fragment
    \\fn fs_main(v: Out) -> @location(0) vec4<f32> {
    \\    let h = v.step.xy;
    \\    let g = vec2<f32>(h.x, -h.y);
    \\    var sum = tap(v.uv + vec2<f32>(2.0 * h.x, 0.0), v.bounds);
    \\    sum = sum + tap(v.uv - vec2<f32>(2.0 * h.x, 0.0), v.bounds);
    \\    sum = sum + tap(v.uv + vec2<f32>(0.0, 2.0 * h.y), v.bounds);
    \\    sum = sum + tap(v.uv - vec2<f32>(0.0, 2.0 * h.y), v.bounds);
    \\    sum = sum + 2.0 * (tap(v.uv + h, v.bounds) + tap(v.uv - h, v.bounds));
    \\    sum = sum + 2.0 * (tap(v.uv + g, v.bounds) + tap(v.uv - g, v.bounds));
    \\    return sum / 12.0;
    \\}
    \\
;

/// The scene copy: one full-target quad that loads the source texel under each fragment, so
/// the destination gets the scene's exact bytes (`draw/renderer.zig`, section 4e).
pub const copy_wgsl: []const u8 =
    \\@group(0) @binding(0) var source: texture_2d<f32>;
    \\
    \\@vertex
    \\fn vs_main(@location(0) unit: vec2<f32>) -> @builtin(position) vec4<f32> {
    \\    return vec4<f32>(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    \\}
    \\
    \\@fragment
    \\fn fs_main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    \\    return textureLoad(source, vec2<i32>(position.xy), 0);
    \\}
    \\
;

comptime {
    assert(@sizeOf(Pass) == 64);
    assert(@sizeOf(Glass) == 80);
    assert(level_min >= 2);
    assert(pass_max == 11);
    assert(offset_min < offset_max);
}

const testing = std.testing;
const registry = @import("registry.zig");

// Locks the strength formula (section 4) at its ends and one worked value: two levels at
// offset 1 is 9.0833 px^2 (sigma 3.01), three at offset 1 is 42.4167, six at offset 2 is
// 9322.17 (sigma 96.55); and chain_for inverts it, choosing four levels at offset 0.873 for
// sigma 12 device pixels (three reach only 11.75).
test "the chain's strength follows the formula" {
    try testing.expectApproxEqAbs(@as(f32, 9.0833), variance(2, 1), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 42.4167), variance(3, 1), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 96.55), @sqrt(variance(6, 2)), 0.01);
    const chain = chain_for(12);
    try testing.expectEqual(@as(u32, 4), chain.levels);
    try testing.expectApproxEqAbs(@as(f32, 0.873), chain.offset, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 12), @sqrt(variance(chain.levels, chain.offset)), 1e-3);
    try testing.expectEqual(Chain{ .levels = 2, .offset = offset_min }, chain_for(0));
    try testing.expectEqual(Chain{ .levels = level_max, .offset = offset_max }, chain_for(500));
}

// Locks the coverage claim of section 4: each level's narrowest offset is below the widest
// offset of the level before, so every sigma from 2.04 to 96.5 device pixels has a chain that
// gives it exactly.
test "the levels cover every sigma" {
    var levels: u32 = level_min + 1;
    while (levels <= level_max) : (levels += 1) {
        try testing.expect(variance(levels, offset_min) < variance(levels - 1, offset_max));
    }
    try testing.expectApproxEqAbs(@as(f32, 2.036), @sqrt(variance(level_min, offset_min)), 1e-3);
    var sigma: f32 = 2.1;
    while (sigma < 96) : (sigma += 0.25) {
        const chain = chain_for(sigma);
        try testing.expectApproxEqRel(sigma, @sqrt(variance(chain.levels, chain.offset)), 1e-3);
    }
}

// Locks the level sizes and the pack (sections 2 and 3): an odd 1281 x 721 scene has level 1
// of 641 x 361, level 3 of 161 x 91, and a pack of 1282 x 361; device 101.5 reads texel 50.75,
// and the far edge clamps half a texel inside the half.
test "levels round up and the pack holds two halves" {
    try testing.expectEqual(@as(u32, 641), level_size(1281, 1));
    try testing.expectEqual(@as(u32, 161), level_size(1281, 3));
    try testing.expectEqual(@as(u32, 91), level_size(721, 3));
    try testing.expectEqual([2]u32{ 1282, 361 }, pack_size(1281, 721));
    try testing.expectEqual(@as(f32, 50.75), pack_texel(101.5, 641));
    try testing.expectEqual(@as(f32, 640.5), pack_texel(1300, 641));
    try testing.expectEqual(@as(f32, 0.5), pack_texel(0.2, 641));
}

// Locks the pass list for three levels of a 1280 x 720 scene: down into the pack's left half,
// then to levels 2 and 3, then up to 2 and into the pack's right half; the first pass reads the
// whole scene, the second the left half only (bounds end half a texel before u = 0.5), and the
// last writes the right half of NDC.
test "a chain's passes route through the pack and the temporaries" {
    var records: [pass_max]Pass = undefined;
    var routes: [pass_max]Route = undefined;
    const count = passes(.{ .levels = 3, .offset = 1 }, 1280, 720, &records, &routes);
    try testing.expectEqual(@as(u32, 5), count);
    const expected = [_][2]Surface{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 2 }, .{ 2, 1 } };
    for (expected, routes[0..count]) |pair, route| {
        try testing.expectEqual(pair[0], route.source);
        try testing.expectEqual(pair[1], route.target);
    }
    try testing.expectEqual([4]f32{ -1, 1, 0, -1 }, records[0].dst);
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, records[0].src);
    try testing.expectApproxEqAbs(@as(f32, 0.5 - 0.5 / 1280.0), records[1].bounds[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), records[1].src[2], 1e-6);
    try testing.expectEqual([4]f32{ 0, 1, 1, -1 }, records[4].dst);
    try testing.expectApproxEqAbs(@as(f32, 0.5 / 320.0), records[4].step[0], 1e-7);
}

/// A line of `n` texels for the CPU twin of the chain.
const twin_len: u32 = 1024;

/// Bilinear (here linear) read of `line` at uv `u`, clamped into the texel centres.
fn twin_read(line: []const f32, u: f32) f32 {
    const n: f32 = @floatFromInt(line.len);
    const x = std.math.clamp(u * n - 0.5, 0, n - 1);
    const i: usize = @intFromFloat(@floor(x));
    const j = @min(i + 1, line.len - 1);
    const t = x - @floor(x);
    return line[i] * (1 - t) + line[j] * t;
}

/// The chain on one line (the x marginal of a vertical line impulse): the CPU twin of
/// `down_wgsl` and `up_wgsl` along one axis. Returns the heavy level, `level_size(n, 1)` long.
fn twin_chain(scene: []const f32, chain: Chain, levels: *[level_max + 1][twin_len]f32) []const f32 {
    const width: u32 = @intCast(scene.len);
    var sizes: [level_max + 1]u32 = undefined;
    for (&sizes, 0..) |*size, level| size.* = level_size(width, @intCast(level));
    @memcpy(levels[0][0..width], scene);
    var level: u32 = 1;
    while (level <= chain.levels) : (level += 1) {
        const source = levels[level - 1][0..sizes[level - 1]];
        const size: f32 = @floatFromInt(sizes[level]);
        const below: f32 = @floatFromInt(sizes[level - 1]);
        const ratio = size * 2 / below;
        const h = chain.offset * 0.5 / below;
        for (levels[level][0..sizes[level]], 0..) |*out, i| {
            const u = (@as(f32, @floatFromInt(i)) + 0.5) / size * ratio;
            const sides = twin_read(source, u - h) + twin_read(source, u + h);
            out.* = (4 * twin_read(source, u) + 2 * sides) / 8;
        }
    }
    level = chain.levels - 1;
    var up: [twin_len]f32 = undefined;
    while (level >= 1) : (level -= 1) {
        const source = levels[level + 1][0..sizes[level + 1]];
        const size: f32 = @floatFromInt(sizes[level]);
        const above: f32 = @floatFromInt(sizes[level + 1]);
        const ratio = size / (above * 2);
        const h = chain.offset * 0.5 / above;
        for (up[0..sizes[level]], 0..) |*out, i| {
            const u = (@as(f32, @floatFromInt(i)) + 0.5) / size * ratio;
            const far = twin_read(source, u - 2 * h) + twin_read(source, u + 2 * h);
            const near = twin_read(source, u - h) + twin_read(source, u + h);
            out.* = (far + 2 * twin_read(source, u) + 4 * near) / 12;
        }
        @memcpy(levels[level][0..sizes[level]], up[0..sizes[level]]);
    }
    return levels[1][0..sizes[1]];
}

// Locks the formula of section 4 against the twin: a line impulse through the chain, read back
// at every device pixel as the glass reads the pack and averaged over the impulse's phase
// against the coarsest level, spreads with `variance` for every level count: within 0.1% at
// offsets 1 and 2 (n = 2: 9.0833 and 28.8333), within 7% at 0.5 and 1.5.
test "the chain's spread matches the formula" {
    var levels: [level_max + 1][twin_len]f32 = undefined;
    var scene: [twin_len]f32 = undefined;
    for ([_]f32{ 0.5, 1, 1.5, 2 }) |offset| {
        var count: u32 = level_min;
        while (count <= level_max) : (count += 1) {
            const chain: Chain = .{ .levels = count, .offset = offset };
            const phases = @as(u32, 1) << @intCast(count);
            var total: f64 = 0;
            for (0..phases) |phase| {
                @memset(&scene, 0);
                const center = twin_len / 2 + phase;
                scene[center] = 1;
                const heavy = twin_chain(&scene, chain, &levels);
                var mass: f64 = 0;
                var moment: f64 = 0;
                var second: f64 = 0;
                for (0..twin_len) |device| {
                    const span: f32 = @floatFromInt(heavy.len * 2);
                    const u = (@as(f32, @floatFromInt(device)) + 0.5) / span;
                    const value: f64 = twin_read(heavy, u);
                    const from: i64 = @as(i64, @intCast(device)) - @as(i64, @intCast(center));
                    const x: f64 = @floatFromInt(from);
                    mass += value;
                    moment += value * x;
                    second += value * x * x;
                }
                const mean = moment / mass;
                total += second / mass - mean * mean;
            }
            const measured: f32 = @floatCast(total / @as(f64, @floatFromInt(phases)));
            const tolerance: f32 = if (offset == 1 or offset == 2) 1e-3 else 0.07;
            try testing.expectApproxEqRel(variance(count, offset), measured, tolerance);
        }
    }
}

// Locks the reach and the scissors (section 2a): three levels at offset 1 reach
// 4 + (1 + 2 + 4) * 1.5 + (4 + 8) * 2 = 38.5 device pixels; a region (100, 50) to (300, 151) of a
// 1281 x 721 scene is texels (50, 25) to (150, 76) of level 1, the same moved by 641 for the
// pack's right half, and (12, 6) to (38, 19) of level 3.
test "a chain reaches a few texels per pass and scissors to its region" {
    try testing.expectEqual(@as(f32, 38.5), reach(.{ .levels = 3, .offset = 1 }));
    const region: [4]u32 = .{ 100, 50, 300, 151 };
    try testing.expectEqual([4]u32{ 50, 25, 100, 51 }, scissor_of(region, 1281, 721, 1, false));
    try testing.expectEqual([4]u32{ 691, 25, 100, 51 }, scissor_of(region, 1281, 721, 1, true));
    try testing.expectEqual([4]u32{ 12, 6, 26, 13 }, scissor_of(region, 1281, 721, 3, false));
}

// Locks the glass twins (section 5): the band is 1 at the outline, 0.5 half a bevel inside,
// and 0 deeper; saturation 0 is grey at Rec. 709 luma, 1 unchanged, and 2 clamps at 0 and 1.
test "glass bends its edge and saturates around luma" {
    try testing.expectEqual(@as(f32, 1), glass_band(0, 12));
    try testing.expectEqual(@as(f32, 0.5), glass_band(-6, 12));
    try testing.expectEqual(@as(f32, 0), glass_band(-20, 12));
    const grey = saturate(.{ 1, 0, 0 }, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.2126), grey[1], 1e-6);
    try testing.expectEqual([3]f32{ 0.2, 0.4, 0.6 }, saturate(.{ 0.2, 0.4, 0.6 }, 1));
    const vivid = saturate(.{ 0.9, 0.5, 0.1 }, 2);
    try testing.expectEqual(@as(f32, 1), vivid[0]);
    try testing.expectEqual(@as(f32, 0), vivid[2]);
}

// Locks the record (section 5): `Glass.of` packs radius, frost, saturation, rim and refraction,
// bevel, rim width in order; the type samples the target format with an explicit level and
// reads the fragment's device position.
test "glass packs its look and assembles" {
    const glass = Glass.of(.{ .x = 10, .y = 20, .width = 200, .height = 100 }, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 400,
        .y1 = 400,
    }, .{
        .radius = 16,
        .frost = 0.5,
        .saturation = 1.4,
        .rim = 0.6,
        .refraction = 8,
        .bevel = 10,
    });
    try testing.expectEqual([4]f32{ 16, 0.5, 1.4, 0.6 }, glass.look);
    try testing.expectEqual([4]f32{ 8, 10, 1, 0 }, glass.lens);
    try testing.expect(comptime registry.check(Glass) == null);
    const text = comptime registry.source(Glass);
    try testing.expect(std.mem.find(u8, text, "sample_texture_level(texel / size)") != null);
    try testing.expect(std.mem.find(u8, text, "px.frag = v.position.xy;") != null);
}

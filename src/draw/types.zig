//! The library draw types (`Box`, `Arc`, `Surface`, `Glyph`, `Image`, `Path`) and their CPU
//! twins.
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
//! - `Surface` (128 bytes, the registry's maximum): a rounded rectangle with one gradient, a
//!   border lit from the top, and a soft shadow; section 6.
//! - `Glyph` (64 bytes): `uv` (u0, v0, u1, v1) and `color`; samples the `r8` glyph atlas, and
//!   coverage scales `color.a`. The UVs sit on the exact texel edges of the glyph's bitmap,
//!   with no half-texel inset: `text.place` snaps every quad edge to a device pixel edge and
//!   the bitmap is rasterized at device size, so each fragment center samples one texel center
//!   and bilinear filtering returns that texel unchanged (`text/layout.zig`, section 3).
//! - `Image` (64 bytes): `uv` and `tint`; samples an `rgba8` texture, multiplied by `tint`.
//! - `Path` (80 bytes): one chunk of a stroked polyline whose points live in the context's
//!   point buffer (`reads_points`). `color`, then `anchor_x`, `anchor_y`, `width`, `hover`,
//!   then `first_point`, `point_count`, `prev`, `next`. `draw/path.zig` writes these records
//!   and its guide explains the fields, the seam rule, and the fragment loop.
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
//! `sdf_box`, `sdf_arc`, and `sdf_segment` are the CPU twins of the prelude functions of the
//! same names, so layout and hit testing are verified without a GPU. `contains_box` is the one
//! rounded-box point test that widget hit testing uses. The tests at the end of this file hold
//! the worked values.
//!
//! ## 5. Constructors
//! `Box.of(rect, clip, BoxLook)` and `Arc.of(ring, clip, ArcLook)` build a record from the
//! layout types (`draw.Rect`, `draw.Clip`) and a look whose defaults are the zero fields a
//! literal writes (no border, no hover, no press, a full sweep), so a face is one line. They
//! write the fields in declaration order with the same values as the literal, so the record is
//! byte-identical to it (test "constructors match the literals byte for byte"). They append
//! nothing: `widgets.kit` appends, and `ui` and `draw` append them with their own skip. Glyphs,
//! images, and paths have appenders instead (`text.place`, `draw.path`).
//!
//! ## 6. Surfaces
//! `Surface.of(rect, clip, SurfaceLook)` draws the shape over `rect`; its shadow lives inside
//! the record's own `rect`, which `of` grows by the shadow's reach, so the pixel cache's bounds
//! (`rect` and `clip`), alignment shifts, and clips cover it with no vertex function:
//! ```text
//! reach  = 1.5 * blur + max(|offset.x|, |offset.y|)     record rect = rect grown by reach
//! p      = local - reach, size = rect.zw - 2 reach, uv = p / size     (the shape's own space)
//! t      = linear: clamp(dot(uv - from, to - from) / |to - from|^2, 0, 1)
//!          radial: clamp(length((uv - center) / radius), 0, 1)
//! fill   = premultiplied mix of fill_a and fill_b at t, back to straight alpha
//! border = mix(border, theme.lighten, rim * (1 - uv.y)), then face = mix(border, fill, inner)
//! shadow = alpha * (1 - erf(sdf_box(p - offset) / (blur / 2 * sqrt 2))) / 2 * (1 - outer)
//!          (alpha * coverage(sdf_box(p - offset)) when blur is 0), black, under the face
//! ```
//! The shadow is exact for a straight edge, at 1.5 blur (three sigma) under 0.0014 of its
//! alpha, and never shows under the shape, so a translucent face stays clear. `erf` is
//! Abramowitz and Stegun 7.1.26 in both the shader and its twin. A skin that animates a surface
//! mixes its colours on the CPU: the record has no hover or press weights. The shadow is cut by
//! `clip` like any pixel, so a surface takes its parent's clip, not its own rect's.

const std = @import("std");
const assert = std.debug.assert;
const theme = @import("../theme.zig");
const textures = @import("textures.zig");
const geometry = @import("../draw.zig");

const Rect = geometry.Rect;
const Clip = geometry.Clip;

/// A color with zero alpha: a `Box` with no border.
pub const transparent: [4]f32 = .{ 0, 0, 0, 0 };

/// How a `Box` looks (`Box.of`). The defaults are a face with no border, hover, or press.
pub const BoxLook = struct {
    fill: [4]f32,
    border_color: [4]f32 = transparent,
    border_width: f32 = 0,
    radius: f32 = 0,
    /// Mix weight toward `theme.lighten`, `[0, 1]`; widgets pass an animator times
    /// `widgets.hover_lighten`.
    hover: f32 = 0,
    /// Mix weight toward `theme.darken`, `[0, 1]`, applied after the hover mix.
    down: f32 = 0,
};

/// How an `Arc` looks (`Arc.of`). The defaults are the whole sweep with no hover.
pub const ArcLook = struct {
    color: [4]f32,
    thickness: f32,
    /// The fraction of `theme.arc_sweep` drawn, `[0, 1]`.
    sweep: f32 = 1,
    /// Where it begins, a fraction of `theme.arc_sweep`; `start + sweep` is at most 1. A
    /// bipolar value (a pan) is an arc from 0.5.
    start: f32 = 0,
    /// Mix weight toward `theme.lighten`, `[0, 1]`.
    hover: f32 = 0,
};

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

    /// The box over `rect`, clipped to `clip`, looking like `look` (module guide, section 5).
    pub fn of(rect: Rect, clip: Clip, look: BoxLook) Box {
        assert(look.radius >= 0);
        assert(look.border_width >= 0);
        assert(look.hover >= 0 and look.hover <= 1);
        assert(look.down >= 0 and look.down <= 1);
        return .{
            .rect = rect.array(),
            .clip = clip.array(),
            .fill = look.fill,
            .border_color = look.border_color,
            .radius = look.radius,
            .border_width = look.border_width,
            .hover = look.hover,
            .down = look.down,
        };
    }

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
    /// Where the arc begins, a fraction of `theme.arc_sweep` from `theme.arc_start`; with
    /// `sweep` it ends at `start + sweep`, at most 1.
    start: f32,

    pub const texture: ?textures.Format = null;

    /// The ring inscribed in the square `ring`, clipped to `clip`, looking like `look`
    /// (module guide, section 5).
    pub fn of(ring: Rect, clip: Clip, look: ArcLook) Arc {
        assert(ring.width == ring.height);
        assert(look.thickness >= 0);
        assert(look.sweep >= 0 and look.sweep <= 1);
        assert(look.start >= 0 and look.start + look.sweep <= 1);
        assert(look.hover >= 0 and look.hover <= 1);
        return .{
            .rect = ring.array(),
            .clip = clip.array(),
            .color = look.color,
            .thickness = look.thickness,
            .sweep = look.sweep,
            .hover = look.hover,
            .start = look.start,
        };
    }

    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let dist = sdf_arc(px.local, px.size, px.thickness, px.start, px.sweep);
        \\    let rgb = mix(px.color.rgb, frame.theme.lighten.rgb, px.hover);
        \\    return vec4<f32>(rgb, px.color.a * coverage(dist));
        \\}
        \\
    ;
};

/// A surface's gradient, in the shape's own uv (0 to 1 across it): a line `from` to `to`, or
/// an ellipse of `radius` about `center` (module guide, section 6).
pub const Gradient = union(enum) {
    linear: struct { from: [2]f32 = .{ 0, 0 }, to: [2]f32 = .{ 0, 1 } },
    radial: struct { center: [2]f32 = .{ 0.5, 0.5 }, radius: [2]f32 = .{ 0.5, 0.5 } },
};

/// A surface's black shadow: moved by `offset`, blurred by `blur` (a Gaussian of sigma
/// `blur / 2`, 0 for a hard edge), at most `alpha` dark. The default is none.
pub const Shadow = struct {
    offset: [2]f32 = .{ 0, 0 },
    blur: f32 = 0,
    alpha: f32 = 0,
};

/// How a `Surface` looks (`Surface.of`). The defaults are a flat face with no border, rim, or
/// shadow.
pub const SurfaceLook = struct {
    /// The gradient's start, straight RGBA; alone, a flat fill.
    fill: [4]f32,
    /// The gradient's end; null is `fill`.
    fill_to: ?[4]f32 = null,
    gradient: Gradient = .{ .linear = .{} },
    radius: f32 = 0,
    border: [4]f32 = transparent,
    border_width: f32 = 0,
    /// Mix weight of the border toward `theme.lighten` along the top edge, fading to 0 at the
    /// bottom, `[0, 1]`.
    rim: f32 = 0,
    shadow: Shadow = .{},
};

/// A rounded rectangle with one gradient, a rim-lit border, and a soft shadow. See the module
/// guide, section 6.
pub const Surface = extern struct {
    /// The shape grown by `reach(shadow)` on every side.
    rect: [4]f32,
    clip: [4]f32,
    fill_a: [4]f32,
    fill_b: [4]f32,
    /// Linear: from.xy, to.xy; radial: center.xy, radius.xy; in the shape's uv.
    gradient: [4]f32,
    border: [4]f32,
    /// Offset x, offset y, blur, alpha.
    shadow: [4]f32,
    radius: f32,
    border_width: f32,
    rim: f32,
    /// 0 linear, 1 radial.
    kind: f32,

    pub const texture: ?textures.Format = null;

    /// How far a shadow reaches past its shape on every side, in logical pixels.
    pub fn reach(shadow: Shadow) f32 {
        assert(shadow.blur >= 0);
        assert(shadow.alpha >= 0 and shadow.alpha <= 1);
        if (shadow.alpha == 0) return 0;
        return 1.5 * shadow.blur + @max(@abs(shadow.offset[0]), @abs(shadow.offset[1]));
    }

    /// The surface whose shape is `rect`, clipped to `clip`, looking like `look` (module
    /// guide, section 6). The record's `rect` is `rect` grown by the shadow's reach.
    pub fn of(rect: Rect, clip: Clip, look: SurfaceLook) Surface {
        assert(look.radius >= 0);
        assert(look.border_width >= 0);
        assert(look.rim >= 0 and look.rim <= 1);
        const grow = reach(look.shadow);
        const shadow = if (look.shadow.alpha == 0) Shadow{} else look.shadow;
        var gradient: [4]f32 = undefined;
        var kind: f32 = 0;
        switch (look.gradient) {
            .linear => |line| {
                assert(line.from[0] != line.to[0] or line.from[1] != line.to[1]);
                gradient = .{ line.from[0], line.from[1], line.to[0], line.to[1] };
            },
            .radial => |ellipse| {
                assert(ellipse.radius[0] > 0 and ellipse.radius[1] > 0);
                gradient = .{ ellipse.center[0], ellipse.center[1], ellipse.radius[0], ellipse.radius[1] };
                kind = 1;
            },
        }
        return .{
            .rect = .{ rect.x - grow, rect.y - grow, rect.width + 2 * grow, rect.height + 2 * grow },
            .clip = clip.array(),
            .fill_a = look.fill,
            .fill_b = look.fill_to orelse look.fill,
            .gradient = gradient,
            .border = look.border,
            .shadow = .{ shadow.offset[0], shadow.offset[1], shadow.blur, shadow.alpha },
            .radius = look.radius,
            .border_width = look.border_width,
            .rim = look.rim,
            .kind = kind,
        };
    }

    // Both shadows and both edges call `coverage` unconditionally and are chosen with
    // `select`, so the derivatives stay in uniform control flow (prelude guide, section 3).
    pub const pixel: []const u8 =
        \\fn surface_erf(x: f32) -> f32 {
        \\    let t = 1.0 / (1.0 + 0.3275911 * abs(x));
        \\    let poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t
        \\        - 0.284496736) * t + 0.254829592) * t;
        \\    let y = 1.0 - poly * exp(-x * x);
        \\    return select(-y, y, x >= 0.0);
        \\}
        \\
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    // `Surface.of` zeroes a shadow without alpha, so this is `Surface.reach`.
        \\    let reach = 1.5 * px.shadow.z + max(abs(px.shadow.x), abs(px.shadow.y));
        \\    let shape = max(px.size - vec2<f32>(2.0 * reach), vec2<f32>(1.0e-3));
        \\    let p = px.local - vec2<f32>(reach);
        \\    let dist = sdf_box(p, shape, px.radius);
        \\    let outer = coverage(dist);
        \\    let inner = select(1.0, coverage(dist + px.border_width), px.border_width > 0.0);
        \\    let uv = p / shape;
        \\    let line = px.gradient.zw - px.gradient.xy;
        \\    let linear_t = dot(uv - px.gradient.xy, line) / max(dot(line, line), 1.0e-6);
        \\    let radial_t = length((uv - px.gradient.xy) / max(px.gradient.zw, vec2<f32>(1.0e-6)));
        \\    let t = clamp(select(linear_t, radial_t, px.kind > 0.5), 0.0, 1.0);
        \\    let alpha = mix(px.fill_a.a, px.fill_b.a, t);
        \\    let premultiplied = mix(px.fill_a.rgb * px.fill_a.a, px.fill_b.rgb * px.fill_b.a, t);
        \\    let fill = vec4<f32>(premultiplied / max(alpha, 1.0e-6), alpha);
        \\    let rim = px.rim * clamp(1.0 - uv.y, 0.0, 1.0);
        \\    let border = vec4<f32>(mix(px.border.rgb, frame.theme.lighten.rgb, rim), px.border.a);
        \\    let face = mix(border, fill, inner);
        \\    let face_a = face.a * outer;
        \\    let shadow_dist = sdf_box(p - px.shadow.xy, shape, px.radius);
        \\    let sigma = max(px.shadow.z * 0.5, 1.0e-3);
        \\    let soft = 0.5 * (1.0 - surface_erf(shadow_dist / (sigma * 1.41421356)));
        \\    let hard = coverage(shadow_dist);
        \\    let shadow_a = px.shadow.w * select(hard, soft, px.shadow.z > 0.0) * (1.0 - outer);
        \\    let out_a = face_a + shadow_a * (1.0 - face_a);
        \\    return vec4<f32>(face.rgb * face_a / max(out_a, 1.0e-6), out_a);
        \\}
        \\
    ;
};

/// One glyph quad sampled from the glyph atlas (texture 0), written by `text.place`.
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

/// One chunk of a stroked path: at most `path.chunk_points_max` points of the context's point
/// buffer, drawn with round caps. Every field is an `f32`, so the index fields carry
/// integer values (exact below 2^24), never bit patterns: a small integer's bits are a
/// denormal float, which a GPU may flush to zero. See `draw/path.zig`.
pub const Path = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    /// The path origin minus `rect.xy`: points are stored relative to that origin, so a shift
    /// of `rect.xy` moves the stroke with it.
    anchor_x: f32,
    anchor_y: f32,
    width: f32,
    /// Mix weight toward `theme.lighten`.
    hover: f32,
    first_point: f32,
    point_count: f32,
    /// 1 when an earlier chunk shares this chunk's first point, else 0.
    prev: f32,
    /// 1 when a later chunk shares this chunk's last point, else 0.
    next: f32,

    pub const texture: ?textures.Format = null;
    pub const reads_points: bool = true;
    // The quad along the chunk's chord (`draw/path.zig`, section 5a), so a diagonal chunk
    // rasterizes its stroke's neighbourhood instead of its whole axis-aligned box. The pad
    // `1.0` is `path.aa_pad`, which `path.zig` asserts. CPU twin: `path.oriented_quad`.
    pub const vertex: []const u8 =
        \\fn vertex(px: Pixel, unit: vec2<f32>) -> vec2<f32> {
        \\    let head = u32(px.first_point);
        \\    let tail = head + u32(px.point_count) - 1u;
        \\    let a = points[head];
        \\    let chord = points[tail] - a;
        \\    let chord_length = length(chord);
        \\    let along = chord / max(chord_length, 1.0e-6);
        \\    let dir = select(vec2<f32>(1.0, 0.0), along, chord_length > 1.0e-3);
        \\    let nrm = vec2<f32>(-dir.y, dir.x);
        \\    var t_lo = 0.0;
        \\    var t_hi = 0.0;
        \\    var n_lo = 0.0;
        \\    var n_hi = 0.0;
        \\    for (var i = head + 1u; i <= tail; i = i + 1u) {
        \\        let d = points[i] - a;
        \\        t_lo = min(t_lo, dot(d, dir));
        \\        t_hi = max(t_hi, dot(d, dir));
        \\        n_lo = min(n_lo, dot(d, nrm));
        \\        n_hi = max(n_hi, dot(d, nrm));
        \\    }
        \\    let r = 0.5 * px.width + 1.0;
        \\    let t = mix(t_lo - r, t_hi + r, unit.x);
        \\    let n = mix(n_lo - r, n_hi + r, unit.y);
        \\    return a + dir * t + nrm * n + vec2<f32>(px.anchor_x, px.anchor_y);
        \\}
        \\
    ;
    // `fwidth` runs before the loop, whose bound is instance data, so the derivative stays in
    // uniform control flow (prelude, section 3). For an exact distance it is one device pixel
    // in logical pixels. A fragment that a neighbouring chunk's seam segment is nearer to
    // belongs to that chunk. Distances within `tie` of each other are a tie, which the side of a
    // line through the seam decides, and the owner draws the nearest of the three distances
    // (`draw/path.zig`, section 4a). The literals are `path.seam_tie` and `path.seam_bias`,
    // which `path.zig` asserts. CPU twins: `path.chunk_alpha` and `path.seam_side`.
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let pixel_size = max(fwidth(px.local.x), 1.0e-5);
        \\    let q = px.local - vec2<f32>(px.anchor_x, px.anchor_y);
        \\    let head = u32(px.first_point);
        \\    let tail = head + u32(px.point_count) - 1u;
        \\    var own = 3.0e38;
        \\    for (var i = head; i < tail; i = i + 1u) {
        \\        own = min(own, sdf_segment(q, points[i], points[i + 1u]));
        \\    }
        \\    // The side test runs only inside a tie (`draw/path.zig`, section 4a).
        \\    let tie = 8.0e-2;
        \\    var before = 3.0e38;
        \\    var wins_before = true;
        \\    if (px.prev > 0.5) {
        \\        before = sdf_segment(q, points[head - 1u], points[head]);
        \\        wins_before = own < before - tie;
        \\        if (!wins_before && own <= before + tie) {
        \\            let a = points[head - 1u];
        \\            wins_before = path_seam_side(q, a, points[head], points[head + 1u]) > 2.5e-2;
        \\        }
        \\    }
        \\    var after = 3.0e38;
        \\    var wins_after = true;
        \\    if (px.next > 0.5) {
        \\        after = sdf_segment(q, points[tail], points[tail + 1u]);
        \\        wins_after = own < after - tie;
        \\        if (!wins_after && own <= after + tie) {
        \\            let a = points[tail - 1u];
        \\            wins_after = path_seam_side(q, a, points[tail], points[tail + 1u]) <= 2.5e-2;
        \\        }
        \\    }
        \\    let owned = select(0.0, 1.0, wins_before && wins_after);
        \\    let near = min(own, min(before, after));
        \\    let alpha = clamp(0.5 - (near - 0.5 * px.width) / pixel_size, 0.0, 1.0);
        \\    let rgb = mix(px.color.rgb, frame.theme.lighten.rgb, px.hover);
        \\    return vec4<f32>(rgb, px.color.a * alpha * owned);
        \\}
        \\
        \\// The signed distance from `q` to the line through `b` that splits a tie at the seam
        \\// between the segments a-b and b-c: negative on a-b's side, positive on b-c's. Up to a
        \\// right angle the line is the bisector of the turn; past it, the line across a-b at `b`,
        \\// so a fold goes to a-b whole. Both chunks compute it from the same three points.
        \\fn path_seam_side(q: vec2<f32>, a: vec2<f32>, b: vec2<f32>, c: vec2<f32>) -> f32 {
        \\    let into = (b - a) * inverseSqrt(max(dot(b - a, b - a), 1.0e-24));
        \\    let out = (c - b) * inverseSqrt(max(dot(c - b, c - b), 1.0e-24));
        \\    let bend = into + out;
        \\    let bisector = bend * inverseSqrt(max(dot(bend, bend), 1.0e-24));
        \\    let normal = select(into, bisector, dot(into, out) >= 0.0);
        \\    return dot(q - b, normal);
        \\}
        \\
    ;
};

/// Distance from `(px, py)` to the segment from `(ax, ay)` to `(bx, by)`. CPU twin of
/// `sdf_segment` in `prelude.wgsl`:
/// ```text
/// h    = clamp(dot(p - a, b - a) / max(dot(b - a, b - a), 1e-12), 0, 1)
/// dist = length(p - a - (b - a) * h)
/// ```
/// A degenerate segment (`a == b`) is the distance to the point.
pub fn sdf_segment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    assert(px == px);
    assert(py == py);
    const pax = px - ax;
    const pay = py - ay;
    const bax = bx - ax;
    const bay = by - ay;
    const along = (pax * bax + pay * bay) / @max(bax * bax + bay * bay, 1.0e-12);
    const h = std.math.clamp(along, 0, 1);
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    const dist = @sqrt(dx * dx + dy * dy);
    assert(dist >= 0);
    return dist;
}

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

/// The error function, Abramowitz and Stegun 7.1.26 (error below 1.5e-7). CPU twin of
/// `surface_erf` in `Surface.pixel`.
pub fn erf(x: f32) f32 {
    assert(x == x);
    const t = 1.0 / (1.0 + 0.3275911 * @abs(x));
    const poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t +
        0.254829592) * t;
    const y = 1.0 - poly * @exp(-x * x);
    assert(y >= -1e-6 and y <= 1);
    return if (x >= 0) y else -y;
}

/// Where `(u, v)` of a shape falls on `gradient`, in `[0, 1]`. CPU twin of `Surface.pixel`'s
/// `t` (module guide, section 6).
pub fn gradient_t(gradient: Gradient, u: f32, v: f32) f32 {
    assert(u == u and v == v);
    const t = switch (gradient) {
        .linear => |line| linear: {
            const dx = line.to[0] - line.from[0];
            const dy = line.to[1] - line.from[1];
            const length2 = dx * dx + dy * dy;
            assert(length2 > 0);
            break :linear ((u - line.from[0]) * dx + (v - line.from[1]) * dy) / length2;
        },
        .radial => |ellipse| radial: {
            assert(ellipse.radius[0] > 0 and ellipse.radius[1] > 0);
            const x = (u - ellipse.center[0]) / ellipse.radius[0];
            const y = (v - ellipse.center[1]) / ellipse.radius[1];
            break :radial @sqrt(x * x + y * y);
        },
    };
    return std.math.clamp(t, 0, 1);
}

/// `a` to `b` at `t`, mixed premultiplied and returned straight, so a fade to a transparent
/// stop keeps its colour. CPU twin of `Surface.pixel`'s fill.
pub fn mix_premultiplied(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    assert(t >= 0 and t <= 1);
    const alpha = a[3] + (b[3] - a[3]) * t;
    assert(alpha >= 0);
    var out: [4]f32 = .{ 0, 0, 0, alpha };
    if (alpha <= 1e-6) return out;
    for (0..3) |i| {
        const pa = a[i] * a[3];
        const pb = b[i] * b[3];
        out[i] = (pa + (pb - pa) * t) / alpha;
    }
    return out;
}

/// A soft shadow's alpha at signed distance `dist` from its (offset) shape, before the shape
/// masks it. CPU twin of `Surface.pixel`'s `soft` (blur > 0).
pub fn shadow_alpha(dist: f32, blur: f32, alpha: f32) f32 {
    assert(blur > 0);
    assert(alpha >= 0 and alpha <= 1);
    const sigma = blur * 0.5;
    return alpha * 0.5 * (1 - erf(dist / (sigma * std.math.sqrt2)));
}

/// Signed distance of an open ring. CPU twin of `sdf_arc` in `prelude.wgsl`.
///
/// `(px, py)` is in local logical pixels, origin at the face top-left, Y down. `thickness` is
/// the stroke width, `sweep_fraction` in `[0, 1]` scales `theme.arc_sweep`, and the arc
/// begins `start_fraction` of that sweep past `arc_start` (`start + sweep <= 1`). Angles follow
/// the convention in `theme.zig`. Round caps fall out of measuring the distance to the swept
/// centerline, clamped to the nearer end, and subtracting half the thickness: a point in the
/// gap's half next to the start measures against the start, so the field is continuous there
/// and the start cap is round (before step 29 it measured against the far end, which cut the
/// cap flat and left a dotted ray where `fwidth` spiked).
///
/// ```text
/// center = size * 0.5
/// p      = local - center
/// mid    = min(center.x, center.y) - thickness * 0.5
/// sweep  = sweep_fraction * arc_sweep
/// origin = arc_start + start_fraction * arc_sweep
/// rel    = wrap(atan2(p.y, p.x) - origin, 0, tau)
/// ang    = rel > sweep + (tau - sweep) / 2 ? 0 : min(rel, sweep)
/// dir    = (cos(origin + ang), sin(origin + ang))
/// dist   = length(p - dir * mid) - thickness * 0.5
/// ```
pub fn sdf_arc(
    px: f32,
    py: f32,
    width: f32,
    height: f32,
    thickness: f32,
    start_fraction: f32,
    sweep_fraction: f32,
) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(thickness >= 0);
    assert(sweep_fraction >= 0);
    assert(start_fraction >= 0 and start_fraction + sweep_fraction <= 1);
    const center_x: f32 = width * 0.5;
    const center_y: f32 = height * 0.5;
    const local_x = px - center_x;
    const local_y = py - center_y;
    const mid = @min(center_x, center_y) - thickness * 0.5;
    const sweep = sweep_fraction * theme.arc_sweep;
    const origin = theme.arc_start + start_fraction * theme.arc_sweep;
    const turned = std.math.atan2(local_y, local_x) - origin;
    const rel = wrap_tau(turned);
    const gap_middle = sweep + (std.math.tau - sweep) * 0.5;
    const ang = if (rel > gap_middle) 0 else @min(rel, sweep);
    const dir_x = @cos(origin + ang);
    const dir_y = @sin(origin + ang);
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
    assert(@sizeOf(Surface) == 128);
    assert(@offsetOf(Surface, "shadow") == 96);
    assert(@offsetOf(Surface, "radius") == 112);
    assert(@offsetOf(Surface, "kind") == 124);
    assert(@offsetOf(Arc, "thickness") == 48);
    assert(@sizeOf(Glyph) == 64);
    assert(@offsetOf(Glyph, "uv") == 32);
    assert(@offsetOf(Glyph, "color") == 48);
    assert(@sizeOf(Image) == 64);
    assert(@offsetOf(Image, "tint") == 48);
    assert(@sizeOf(Path) == 80);
    assert(@offsetOf(Path, "color") == 32);
    assert(@offsetOf(Path, "anchor_x") == 48);
    assert(@offsetOf(Path, "hover") == 60);
    assert(@offsetOf(Path, "first_point") == 64);
    assert(@offsetOf(Path, "next") == 76);
}

// Locks the segment twin: the perpendicular foot, both end caps, and a degenerate segment.
test "sdf segment measures to the nearest point of the segment" {
    try std.testing.expectApproxEqAbs(@as(f32, 3), sdf_segment(5, 3, 0, 0, 10, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), sdf_segment(-3, 4, 0, 0, 10, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), sdf_segment(13, -4, 0, 0, 10, 0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), sdf_segment(3, 4, 0, 0, 0, 0), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), sdf_segment(7, 0, 0, 0, 10, 0));
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
    const at_start = sdf_arc(start_x, start_y, size, size, thickness, 0, 1);
    const at_center = sdf_arc(28, 28, size, size, thickness, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, -2), at_start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), at_center, 0.0001);
    const six = sdf_arc(28, 28 + mid, size, size, thickness, 0, 1);
    try std.testing.expect(six > 0);
    const cap = sdf_arc(start_x, start_y, size, size, thickness, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -2), cap, 0.0001);
    const away = sdf_arc(28, 28, size, size, thickness, 0, 0);
    try std.testing.expect(away > 0);
    // 0.05 rad before the start on the centerline: inside the round start cap, at the chord
    // 2 * mid * sin(0.025) = 1.2999 from its center, so -0.7001; it used to measure the far end.
    const before = theme.arc_start - 0.05;
    const before_x = size * 0.5 + @cos(before) * mid;
    const before_y = size * 0.5 + @sin(before) * mid;
    for ([_]f32{ 1, 0.5, 0 }) |fraction| {
        const near = sdf_arc(before_x, before_y, size, size, thickness, 0, fraction);
        try std.testing.expectApproxEqAbs(@as(f32, -0.7001), near, 0.001);
    }
}

// Locks the start: an arc from 0.5 of the sweep (the top, 120 + 135 = 255 degrees) covers the
// top of the ring and not its start, and a zero sweep there is a cap at the top. Start 0 is
// the field of every arc before it (the goldens hold it bit for bit).
test "sdf arc starts where it is told" {
    const size: f32 = 56;
    const thickness: f32 = 4;
    const mid: f32 = size * 0.5 - thickness * 0.5;
    const top = theme.arc_start + 0.5 * theme.arc_sweep;
    const top_x = size * 0.5 + @cos(top) * mid;
    const top_y = size * 0.5 + @sin(top) * mid;
    try std.testing.expectApproxEqAbs(@as(f32, -2), sdf_arc(top_x, top_y, size, size, thickness, 0.5, 0.2), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -2), sdf_arc(top_x, top_y, size, size, thickness, 0.5, 0), 0.0001);
    const start_x = size * 0.5 + @cos(theme.arc_start) * mid;
    const start_y = size * 0.5 + @sin(theme.arc_start) * mid;
    try std.testing.expect(sdf_arc(start_x, start_y, size, size, thickness, 0.5, 0.2) > 0);
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

// Locks the constructors against the literals they replace, byte for byte: a default look (no
// border, hover, or press; a full sweep) and a fully set one.
test "constructors match the literals byte for byte" {
    const rect: Rect = .{ .x = 8, .y = 16, .width = 56, .height = 56 };
    const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 90 };
    const plain_box: Box = .{
        .rect = .{ 8, 16, 56, 56 },
        .clip = .{ 0, 0, 100, 90 },
        .fill = .{ 0.1, 0.2, 0.3, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    };
    const built_box = Box.of(rect, clip, .{ .fill = .{ 0.1, 0.2, 0.3, 1 } });
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&plain_box), std.mem.asBytes(&built_box));
    const full_box: Box = .{
        .rect = .{ 8, 16, 56, 56 },
        .clip = .{ 0, 0, 100, 90 },
        .fill = .{ 0.1, 0.2, 0.3, 1 },
        .border_color = .{ 0.9, 0.8, 0.7, 0.5 },
        .radius = 6,
        .border_width = 1.5,
        .hover = 0.18,
        .down = 0.3,
    };
    const built_full = Box.of(rect, clip, .{
        .fill = .{ 0.1, 0.2, 0.3, 1 },
        .border_color = .{ 0.9, 0.8, 0.7, 0.5 },
        .border_width = 1.5,
        .radius = 6,
        .hover = 0.18,
        .down = 0.3,
    });
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&full_box), std.mem.asBytes(&built_full));
    const plain_arc: Arc = .{
        .rect = .{ 8, 16, 56, 56 },
        .clip = .{ 0, 0, 100, 90 },
        .color = .{ 1, 1, 1, 1 },
        .thickness = 4,
        .sweep = 1,
        .hover = 0,
        .start = 0,
    };
    const built_arc = Arc.of(rect, clip, .{ .color = .{ 1, 1, 1, 1 }, .thickness = 4 });
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&plain_arc), std.mem.asBytes(&built_arc));
    var full_arc = plain_arc;
    full_arc.sweep = 0.7;
    full_arc.hover = 0.18;
    const built_swept = Arc.of(rect, clip, .{
        .color = .{ 1, 1, 1, 1 },
        .thickness = 4,
        .sweep = 0.7,
        .hover = 0.18,
    });
    const swept_bytes = std.mem.asBytes(&built_swept);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&full_arc), swept_bytes);
}

// Locks the error function twin (section 6): erf(0.5) = 0.5204999, erf(1) = 0.8427008,
// erf(2) = 0.9953223 within 1e-6, erf(0) = 0, and erf is odd.
test "erf matches its table" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5204999), erf(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8427008), erf(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9953223), erf(2), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), erf(0), 1e-7);
    try std.testing.expectEqual(-erf(0.7), erf(-0.7));
}

// Locks the gradient twin (section 6): linear (0, 0) to (0, 1) at (0.3, 0.25) is 0.25; the
// diagonal at (1, 0) is 0.5; the ellipse of radius (0.5, 0.25) about the centre is 0.5 at
// (0.75, 0.5) and at (0.5, 0.625), and clamps to 1 at a corner and to 0 before a line starts.
test "gradient t along a line and an ellipse" {
    try std.testing.expectEqual(@as(f32, 0.25), gradient_t(.{ .linear = .{} }, 0.3, 0.25));
    const diagonal: Gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } };
    try std.testing.expectEqual(@as(f32, 0.5), gradient_t(diagonal, 1, 0));
    try std.testing.expectEqual(@as(f32, 0), gradient_t(diagonal, -1, -1));
    const ellipse: Gradient = .{ .radial = .{ .center = .{ 0.5, 0.5 }, .radius = .{ 0.5, 0.25 } } };
    try std.testing.expectEqual(@as(f32, 0.5), gradient_t(ellipse, 0.75, 0.5));
    try std.testing.expectEqual(@as(f32, 0.5), gradient_t(ellipse, 0.5, 0.625));
    try std.testing.expectEqual(@as(f32, 1), gradient_t(ellipse, 1, 1));
}

// Locks the premultiplied mix (section 6): halfway from opaque red to transparent black is red
// at alpha 0.5, not dark red; two opaque stops mix their channels evenly.
test "a fade to a transparent stop keeps its colour" {
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 0.5 }, mix_premultiplied(red, transparent, 0.5));
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0.5, 1 }, mix_premultiplied(red, .{ 0, 0, 1, 1 }, 0.5));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, mix_premultiplied(red, transparent, 1));
}

// Locks the soft shadow (section 6) at blur 16 (sigma 8) and alpha 0.4: half its alpha at the
// shape's edge, 0.0786 of it at sigma * sqrt 2 (erf(1) = 0.8427), under 0.0014 of it at the
// reach (three sigma), and nearly all of it deep under the shape.
test "the shadow falls off as a blurred edge" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), shadow_alpha(0, 16, 0.4), 1e-6);
    const at_sigma = shadow_alpha(8 * std.math.sqrt2, 16, 0.4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4 * 0.0786496), at_sigma, 1e-6);
    try std.testing.expect(shadow_alpha(24, 16, 0.4) < 0.4 * 0.0014);
    try std.testing.expect(shadow_alpha(-24, 16, 0.4) > 0.4 * 0.998);
}

// Locks `Surface.of` (section 6): a shadow of offset (0, 6) and blur 16 reaches 1.5 * 16 + 6
// = 30, so the shape (100, 50, 200, 120) becomes the record rect (70, 20, 260, 180); a flat look
// keeps its rect, has equal stops, a linear kind, and an all-zero shadow, even with a blur but
// no alpha; a radial look writes its centre and radius and kind 1.
test "a surface's record grows its rect by the shadow's reach" {
    const shape: Rect = .{ .x = 100, .y = 50, .width = 200, .height = 120 };
    const window: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
    const shadow: Shadow = .{ .offset = .{ 0, 6 }, .blur = 16, .alpha = 0.35 };
    try std.testing.expectEqual(@as(f32, 30), Surface.reach(shadow));
    const card = Surface.of(shape, window, .{ .fill = .{ 1, 0.5, 0, 1 }, .radius = 16, .shadow = shadow });
    try std.testing.expectEqual([4]f32{ 70, 20, 260, 180 }, card.rect);
    try std.testing.expectEqual([4]f32{ 0, 6, 16, 0.35 }, card.shadow);
    const flat = Surface.of(shape, window, .{
        .fill = .{ 0.2, 0.2, 0.2, 1 },
        .shadow = .{ .blur = 8 },
    });
    try std.testing.expectEqual(shape.array(), flat.rect);
    try std.testing.expectEqual(flat.fill_a, flat.fill_b);
    try std.testing.expectEqual(@as(f32, 0), flat.kind);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, flat.shadow);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, flat.gradient);
    const glow = Surface.of(shape, window, .{
        .fill = .{ 1, 1, 1, 0.6 },
        .fill_to = transparent,
        .gradient = .{ .radial = .{ .center = .{ 0.7, 0.2 }, .radius = .{ 0.6, 0.8 } } },
    });
    try std.testing.expectEqual([4]f32{ 0.7, 0.2, 0.6, 0.8 }, glow.gradient);
    try std.testing.expectEqual(@as(f32, 1), glow.kind);
}

// Locks the registry's view of `Surface`: it satisfies the instance convention at the maximum
// of eight groups, and its assembled module carries both its functions.
test "the surface type passes the instance convention" {
    const registry = @import("registry.zig");
    try std.testing.expect(comptime registry.check(Surface) == null);
    const source = comptime registry.source(Surface);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn surface_erf") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn pixel(px: Pixel)") != null);
}

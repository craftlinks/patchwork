// The shared prelude every draw type's shader module is assembled from.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Assembly
// `draw/registry.zig` builds one module per registered draw type at compile time:
//   prelude (this file) ++ Theme (generated from `theme.Theme`) ++ texture bindings (textured
//   types only) ++ Instance, Varyings, Pixel, carry, unpack (generated from the Zig struct)
//   ++ the type's own `fn pixel(px: Pixel) -> vec4<f32>`.
// WGSL module scope is order-free, so this file refers to the generated declarations and to
// `pixel` before they appear.
//
// ## 2. Instance Convention
// Vertex buffer 0 is the unit quad (location 0). Vertex buffer 1 holds the type's records,
// one `vec4<f32>` attribute per 16 bytes at locations 1 to N: `g0` is `rect` (x, y, width,
// height in logical pixels) and `g1` is `clip` (exclusive-max x0, y0, x1, y1). The parameter
// groups `g2` to `g7` follow. `Varyings` carries every group flat to the fragment stage, plus
// the interpolated `local` position, and `unpack` exposes each Zig field by its own name in
// `Pixel`, beside `local`, `size`, and `pos` (= rect.xy + local).
//
// ## 3. Pixel Contract and Uniformity
// `fs_main` calls `pixel` unconditionally and applies the clip mask by multiplication, never
// by an early return or `discard`. WGSL requires derivatives (`fwidth`, so `coverage`) and
// implicit-LOD `textureSample` to run in uniform control flow. A `pixel` function must
// therefore call them outside any branch on instance or position data; compute both sides
// and choose with `select` or `mix` instead. A violation fails when the host compiles the
// module, which happens at startup; the error names the draw type through the module label.
//
// ## 4. Coverage, Clip, and Blend
// - `coverage(dist)` is a one-pixel linear ramp centered on the outline:
//   `clamp(0.5 - dist / max(fwidth(dist), 1e-5), 0, 1)`. Distances are in logical pixels.
// - `clip_mask` is `step(x0, x) * step(y0, y) * step(x, x1) * step(y, y1)`; `step` makes the
//   max edge inclusive even though the stored clip is exclusive-max.
// - `pixel` returns straight (not premultiplied) RGBA; the host blends source-over on
//   `src_alpha, one_minus_src_alpha`.
//
// ## 5. Distance Fields
// `sdf_box` and `sdf_arc` are twins of `draw.sdf_box` and `draw.sdf_arc`, whose CPU tests lock
// the math; arc angles come from `frame.theme.arc` (see `theme.zig`).

struct Frame {
    ortho: mat4x4<f32>,
    theme: Theme,
}

@group(0) @binding(0) var<uniform> frame: Frame;

@vertex
fn vs_main(@location(0) unit: vec2<f32>, instance: Instance) -> Varyings {
    var out = carry(instance);
    let local = unit * instance.g0.zw;
    out.position = frame.ortho * vec4<f32>(instance.g0.xy + local, 0.0, 1.0);
    out.local = local;
    return out;
}

@fragment
fn fs_main(varyings: Varyings) -> @location(0) vec4<f32> {
    let px = unpack(varyings);
    let color = pixel(px);
    return vec4<f32>(color.rgb, color.a * clip_mask(px.pos, px.clip));
}

fn clip_mask(pos: vec2<f32>, clip: vec4<f32>) -> f32 {
    return step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w);
}

fn coverage(dist: f32) -> f32 {
    let width = max(fwidth(dist), 1.0e-5);
    return clamp(0.5 - dist / width, 0.0, 1.0);
}

// Distance to a centered stroke of `width` along the outline `dist == 0`.
fn stroke(dist: f32, width: f32) -> f32 {
    return abs(dist) - width * 0.5;
}

// Rounded box with its top-left at the origin; the radius is clamped to half the short edge.
fn sdf_box(p: vec2<f32>, size: vec2<f32>, radius: f32) -> f32 {
    let half_size = 0.5 * size;
    let k = min(radius, min(half_size.x, half_size.y));
    let q = abs(p - half_size) - (half_size - vec2<f32>(k, k));
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0, 0.0))) - k;
}

fn sdf_circle(p: vec2<f32>, center: vec2<f32>, radius: f32) -> f32 {
    return length(p - center) - radius;
}

// Distance to the segment from `a` to `b` (zero width; subtract a radius for a capsule).
fn sdf_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1.0e-12), 0.0, 1.0);
    return length(pa - ba * h);
}

// Wraps an angle into [0, tau). The input is within one turn of that range.
fn wrap_tau(angle: f32) -> f32 {
    let tau = 6.283185307179586;
    var value = angle;
    if (value < 0.0) {
        value = value + tau;
    }
    if (value >= tau) {
        value = value - tau;
    }
    return value;
}

// Open ring inscribed in `size`, swept clockwise from `frame.theme.arc.x` by
// `sweep_fraction * frame.theme.arc.y`, with round caps.
fn sdf_arc(p_local: vec2<f32>, size: vec2<f32>, thickness: f32, sweep_fraction: f32) -> f32 {
    let center = size * 0.5;
    let p = p_local - center;
    let mid = min(center.x, center.y) - thickness * 0.5;
    let sweep = sweep_fraction * frame.theme.arc.y;
    let rel = wrap_tau(atan2(p.y, p.x) - frame.theme.arc.x);
    let ang = min(rel, sweep);
    let dir = vec2<f32>(cos(frame.theme.arc.x + ang), sin(frame.theme.arc.x + ang));
    return length(p - dir * mid) - thickness * 0.5;
}

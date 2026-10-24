// The shared prelude every draw type's shader module is assembled from.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Assembly
// `draw/registry.zig` builds one module per registered draw type at compile time:
//   prelude (this file) ++ Theme (generated from `theme.Theme`) ++ texture bindings (textured
//   types only) ++ the point buffer `points` (`reads_points` types only, @group(0)
//   @binding(1)) ++ Instance, Varyings, Pixel, carry, unpack (generated from the Zig struct)
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
// ## 2a. Vertex
// `vs_main` places each corner at `rect.xy + vertex_local(instance, unit)`. The registry
// generates `vertex_local`: `unit * rect.zw` (the rect itself), or the type's own
// `fn vertex(px, unit)` when it declares one (`draw/registry.zig`, section 2a). `local` is
// then interpolated, so in `pixel` it still means `pos - rect.xy` for any quad shape.
//
// ## 3. Pixel Contract and Uniformity
// `fs_main` calls `pixel` unconditionally and applies the clip mask by multiplication, never
// by an early return or `discard`. WGSL requires derivatives (`fwidth`, so `coverage`) and
// implicit-LOD `textureSample` to run in uniform control flow. A `pixel` function must
// therefore call them outside any branch on instance or position data; compute both sides
// and choose with `select` or `mix` instead. A loop whose bound is instance data is
// non-uniform too, so `draw.Path` takes its derivative before its loop. A violation fails
// when the host compiles the module, which happens at startup; the error names the draw type
// through the module label.
//
// ## 4. Coverage, Clip, and Blend
// - `coverage(dist)` is a one-pixel linear ramp centered on the outline:
//   `clamp(0.5 - dist / max(fwidth(dist), 1e-5), 0, 1)`. Distances are in logical pixels.
// - `clip_mask` is `step(x0, x) * step(y0, y) * step(x, x1) * step(y, y1)`; `step` makes the
//   max edge inclusive even though the stored clip is exclusive-max.
// - `pixel` returns straight (not premultiplied) RGBA. `fs_main` applies the clip to alpha,
//   then the type's generated `blend_out`, and the host blends by the type's `blend`
//   (`draw/registry.zig`, section 2c): source-over by default, or additive or multiply.
//
// ## 5. Distance Fields
// `sdf_box` and `sdf_arc` are twins of `draw.sdf_box` and `draw.sdf_arc`, whose CPU tests lock
// the math; arc angles come from `frame.theme.arc` (see `theme.zig`).
//
// ## 6. Time
// `frame.time.x` is the animation time in seconds, wrapped at one hour (`animator.Time`). Only
// a type that declares `animated = true` may read it, through `frame.time` or the helpers
// below; the registry rejects any other (`draw/registry.zig`, section 2b), because the pixel
// cache would keep its stale pixels. `time_pulse(hz)` rises from 0 to 1 and back once per
// period, and wraps seamlessly for any `hz` that is a multiple of 1/3600.

struct Frame {
    ortho: mat4x4<f32>,
    time: vec4<f32>,
    theme: Theme,
}

@group(0) @binding(0) var<uniform> frame: Frame;

@vertex
fn vs_main(@location(0) unit: vec2<f32>, instance: Instance) -> Varyings {
    var out = carry(instance);
    let local = vertex_local(instance, unit);
    out.position = frame.ortho * vec4<f32>(instance.g0.xy + local, 0.0, 1.0);
    out.local = local;
    return out;
}

@fragment
fn fs_main(varyings: Varyings) -> @location(0) vec4<f32> {
    let px = unpack(varyings);
    let color = pixel(px);
    return blend_out(vec4<f32>(color.rgb, color.a * clip_mask(px.pos, px.clip)));
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

fn time_seconds() -> f32 {
    return frame.time.x;
}

// 0 at whole periods, 1 halfway through: `0.5 - 0.5 * cos(tau * hz * t)`.
fn time_pulse(hz: f32) -> f32 {
    return 0.5 - 0.5 * cos(6.283185307179586 * hz * frame.time.x);
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
// `sweep_fraction * frame.theme.arc.y`, with round caps at both ends.
fn sdf_arc(p_local: vec2<f32>, size: vec2<f32>, thickness: f32, sweep_fraction: f32) -> f32 {
    let center = size * 0.5;
    let p = p_local - center;
    let mid = min(center.x, center.y) - thickness * 0.5;
    let sweep = sweep_fraction * frame.theme.arc.y;
    let rel = wrap_tau(atan2(p.y, p.x) - frame.theme.arc.x);
    // The nearer end: the gap's half next to the start measures against the start cap.
    let gap_middle = sweep + 0.5 * (6.283185307179586 - sweep);
    let ang = select(min(rel, sweep), 0.0, rel > gap_middle);
    let dir = vec2<f32>(cos(frame.theme.arc.x + ang), sin(frame.theme.arc.x + ang));
    return length(p - dir * mid) - thickness * 0.5;
}

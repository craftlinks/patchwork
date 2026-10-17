// Instanced rounded-box and open-ring quads with analytic antialiasing and a hard clip mask.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Data Flow
// One draw call expands the unit quad (vertex buffer 0, per-vertex) by instance records
// (vertex buffer 1, per-instance, layout `draw.Instance`). Each vertex becomes
// `pos = rect.xy + unit * rect.zw` in logical pixels, which `frame.ortho` projects to clip
// space. The fragment stage measures a signed distance in the same logical-pixel space, so
// `fwidth(dist)` is a screen-pixel derivative. Computing the distance in NDC would break the
// one-pixel coverage ramp.
//
// Vertex inputs, matched to `draw.Instance` by the tests in `draw.zig`:
//   location 0: unit quad corner; location 1: rect (x, y, w, h) in logical pixels;
//   location 2: straight-alpha fill; location 3: shape = (radius or thickness, hover,
//   down or sweep, kind); location 4: clip = exclusive-max (x0, y0, x1, y1).
// `kind` is 0 for a box and 1 for an arc; see `draw.kind_box` and `draw.kind_arc`.
//
// ## 2. Distance Fields
// Both functions are twins of `draw.sdf_box` and `draw.sdf_arc`; the CPU tests lock the math.
// - Box: with `half = 0.5 * size` and `k = min(radius, min(half.x, half.y))`,
//   `q = abs(local - half) - (half - k)` and
//   `dist = min(max(q.x, q.y), 0) + length(max(q, 0)) - k`.
// - Arc: angles follow `theme.zig` (atan2 in Y-down space, clockwise-positive). With
//   `center = size / 2`, `p = local - center`, `mid = min(center.x, center.y) - thickness / 2`,
//   `sweep = sweep_fraction * theme.arc.y`, `rel = wrap(atan2(p) - theme.arc.x, 0, tau)`, and
//   `ang = min(rel, sweep)`: `dist = length(p - dir(theme.arc.x + ang) * mid) - thickness / 2`.
//   Clamping `ang` is what produces round caps.
//
// ## 3. Coverage, Clip, and Blend
// - Coverage is a one-pixel linear ramp centered on the outline:
//   `pixel = max(fwidth(dist), epsilon)` and `coverage = clamp(0.5 - dist / pixel, 0, 1)`.
//   The epsilon only guards the division when the derivative is zero.
// - The clip mask is per fragment, with no `discard` and no scissor state:
//   `inside = step(x0, pos.x) * step(y0, pos.y) * step(pos.x, x1) * step(pos.y, y1)` and
//   `alpha = fill.a * coverage * inside`. `step` makes the max edge inclusive even though
//   the stored clip is exclusive-max.
// - RGB stays straight (not premultiplied) and coverage goes only into alpha, matching the
//   host's source-over blend on `src_alpha, one_minus_src_alpha`. Premultiplying RGB by
//   coverage as well would darken antialiased edges.
//
// ## 4. Hover, Down, and Theme Colors
// `lit = mix(fill.rgb, theme.lighten.rgb, hover)`, then for a box
// `rgb = mix(lit, theme.darken.rgb, down)`. An arc is not darkened, because its `down`
// field is the sweep fraction. Color and angle constants come from the uniform, never from
// literals here.
//
// ## 5. Uniform Contract
// `@group(0) @binding(0)` is `Frame { ortho, theme }`. The record layout, its size, and the
// requirement that the `Theme` declaration below match `theme.Theme` field for field are
// documented in `theme.zig` and `draw.zig`, and checked by "wgsl declarations match the Zig
// layouts".

struct Theme {
    panel: vec4<f32>,
    text: vec4<f32>,
    track: vec4<f32>,
    value: vec4<f32>,
    control: vec4<f32>,
    meter: vec4<f32>,
    lighten: vec4<f32>,
    darken: vec4<f32>,
    arc: vec4<f32>,
    pad0: vec4<f32>,
    pad1: vec4<f32>,
    pad2: vec4<f32>,
}

struct Frame {
    ortho: mat4x4<f32>,
    theme: Theme,
}

@group(0) @binding(0) var<uniform> frame: Frame;

struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) fill: vec4<f32>,
    // Logical pixels from the instance's top-left, not NDC.
    @location(1) local: vec2<f32>,
    @location(2) size: vec2<f32>,
    // (radius or thickness, hover, darken or sweep fraction, kind).
    @location(3) shape: vec4<f32>,
    @location(4) origin: vec2<f32>,
    // Exclusive-max clip in logical pixels.
    @location(5) bounds: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) fill: vec4<f32>,
    @location(3) shape: vec4<f32>,
    @location(4) bounds: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;
    let local = unit * rect.zw;
    let pos = rect.xy + local;
    out.clip = frame.ortho * vec4<f32>(pos, 0.0, 1.0);
    out.fill = fill;
    out.local = local;
    out.size = rect.zw;
    out.shape = shape;
    out.origin = rect.xy;
    out.bounds = bounds;
    return out;
}

// Inigo Quilez rounded box; see the module guide and `draw.sdf_box`.
fn sdf_box(p: vec2<f32>, size: vec2<f32>, radius: f32) -> f32 {
    let half_size = 0.5 * size;
    let k = min(radius, min(half_size.x, half_size.y));
    let q = abs(p - half_size) - (half_size - vec2<f32>(k, k));
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0, 0.0))) - k;
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

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    var dist: f32;
    var darken: f32;
    if (in.shape.w == 1.0) {
        dist = sdf_arc(in.local, in.size, in.shape.x, in.shape.z);
        darken = 0.0;
    } else {
        dist = sdf_box(in.local, in.size, in.shape.x);
        darken = in.shape.z;
    }
    let pixel = max(fwidth(dist), 1.0e-5);
    let coverage = clamp(0.5 - dist / pixel, 0.0, 1.0);
    let lit = mix(in.fill.rgb, frame.theme.lighten.rgb, in.shape.y);
    let rgb = mix(lit, frame.theme.darken.rgb, darken);
    let pos = in.origin + in.local;
    let inside = step(in.bounds.x, pos.x) * step(in.bounds.y, pos.y)
        * step(pos.x, in.bounds.z) * step(pos.y, in.bounds.w);
    return vec4<f32>(rgb, in.fill.a * coverage * inside);
}

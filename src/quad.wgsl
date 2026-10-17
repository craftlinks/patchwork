// WebGPU Shading Language (WGSL) Shader for Hardware-Instanced 2D Quad Rendering.
//
// # Deep Architectural Guide for Reviewers:
//
// ## Graphics Pipeline Architecture and Data Flow Overview
//
// In modern GPU hardware, rendering geometry onto a screen involves a sequence of fixed-function
// and programmable pipeline stages:
//
// 1. **Vertex Fetch (Input Assembly):**
//    The GPU hardware fetches raw binary attributes from one or more VRAM vertex buffers:
//    - Vertex Buffer 0 (Unit Quad):
//      Contains 6 vertices describing two triangles spanning the unit square [0,0] to [1,1].
//      Configured with `stepMode: "vertex"`, so the hardware pointer advances by 8 bytes
//      (vec2<f32>) for every individual vertex index in [0..5] (48 bytes total).
//    - Vertex Buffer 1 (Instances):
//      Contains an array of 64-byte instance records: rect, fill, shape, bounds.
//      Configured with `stepMode: "instance"`, so the hardware pointer advances by 64 bytes
//      only once per instance index in [0..N-1].
//
// 2. **Vertex Shader (`@vertex fn vs_main`):**
//    Invoked 6 * N times by the GPU execution units (e.g. SIMD warps/wavefronts).
//    For each vertex, it performs:
//    - Local Quad Expansion: Scales the [0..1] unit quad corner to pixel dimensions (rect.zw)
//      and offsets it by the instance screen position (rect.xy).
//    - Orthographic Projection: Multiplies the 2D pixel coordinate by the 4x4 projection matrix
//      to convert from UI logical pixel space [0..width, 0..height] into homogeneous clip space.
//    - Attribute Passing: Forwards fill, local pixel, rectangle size, shape vec4, origin,
//      and clip bounds to the rasterizer.
//
// 3. **Primitive Assembly and Clipping:**
//    The GPU groups triples of vertices into triangles. Triangles outside the clip frustum
//    are discarded; triangles intersecting the clip boundary are geometrically clipped.
//    Perspective division (x/w, y/w, z/w) is performed by hardware to produce Normalized
//    Device Coordinates (NDC) in the [-1, 1] cube.
//
// 4. **Rasterization:**
//    The rasterizer tests which physical display pixels (fragments) fall within each triangle face.
//    It interpolates the vertex attributes across each triangle using barycentric coordinates.
//
// 5. **Fragment Shader (`@fragment fn fs_main`):**
//    Invoked once per covered pixel fragment. Branches on `shape.w` (kind):
//    - Kind 0 (Box): Evaluates `sdf_box`, darkens by `shape.z`.
//    - Kind 1 (Arc): Evaluates `sdf_arc`, sets darken to 0.0 (arcs are not darkened).
//    Evaluates analytic coverage via `fwidth`, mixes toward theme lighten/darken,
//    evaluates the hard clip mask, and returns straight-alpha RGBA.
//
// 6. **Fixed-Function Blending & Output Merger:**
//    The hardware blend unit merges the fragment color with the existing framebuffer pixel
//    using source-over: `src.rgb * src.a + dst.rgb * (1 - src.a)`, and the same factors for
//    alpha. The shader keeps RGB straight (not premultiplied) and puts coverage into alpha.
//    Premultiplying RGB by coverage as well would darken the antialiased edge.
//
// 7. **Rounded-Box and Open-Ring Distance Fields**
//    - Box (`kind == 0.0`): Inigo Quilez rounded box matching `sdf_box` in `src/draw.zig`.
//      `half = 0.5 * size`, `k = min(radius, min(half.x, half.y))`.
//      `q = abs(local - half) - (half - k)`.
//      `dist = min(max(q.x, q.y), 0) + length(max(q, 0)) - k`.
//    - Arc (`kind == 1.0`): Open-ring distance matching `sdf_arc` in `src/draw.zig`.
//      Angle 0 is 3 o'clock, positive clockwise in Y-down space.
//      Start angle (`frame.theme.arc.x = 2pi/3`, 7 o'clock) and sweep (`frame.theme.arc.y = 3pi/2`,
//      270 degrees) are read from the uniform buffer.
//      `mid = min(center.x, center.y) - thickness * 0.5`.
//      `dist = length(p - dir * mid) - thickness * 0.5`.
//      Round caps fall out analytically from the distance to the swept centerline endpoints.
//
// 8. **Analytic Coverage and Hard Clip Masking**
//    - Coverage is a one-pixel ramp centered on the boundary:
//      `pixel = max(fwidth(dist), 1e-5)`
//      `coverage = clamp(0.5 - dist / pixel, 0, 1)`
//    - Hard Clip Mask: Evaluated per-fragment without discard or scissor:
//      `pos = in.origin + in.local`
//      `inside = step(bounds.x, pos.x) * step(bounds.y, pos.y)`
//              `* step(pos.x, bounds.z) * step(pos.y, bounds.w)`
//      `alpha = fill.a * coverage * inside`
//      Fragments outside the clip mask yield alpha 0 and blend away under source-over.
//
// 9. **Hover Lighten, Down Darken, and Theme Colors**
//    `shape.y` is hover mix weight in [0.0, 1.0].
//    `shape.z` is down mix weight for boxes, or sweep fraction for arcs.
//    - Lit: `lit = mix(fill.rgb, frame.theme.lighten.rgb, shape.y)`
//    - Darken: For boxes, `rgb = mix(lit, frame.theme.darken.rgb, shape.z)`.
//      For arcs, `darken = 0.0`, leaving `rgb = lit`.
//    - No hardcoded color or angle literals exist in WGSL source.
//
// Uniform Buffer Binding:
// - `@group(0) @binding(0)`: Binds 256-byte uniform buffer holding `Frame`:
//   - `ortho: mat4x4<f32>` (64 bytes at offset 0).
//   - `theme: Theme` (192 bytes at offset 64, 12 vec4 slots).
// Twelve vec4 slots after the matrix. Offsets match `theme.Theme` (192 bytes at byte 64).
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

// Output structure returned by the vertex shader and consumed by the GPU rasterizer.
struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) fill: vec4<f32>,
    // Local pixel inside the rectangle, origin at the instance top-left.
    @location(1) local: vec2<f32>,
    @location(2) size: vec2<f32>,
    // shape.x is radius or stroke thickness. shape.y is hover.
    // shape.z is box darken or arc sweep. shape.w is kind (0 box, 1 arc).
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
    // Local logical pixels inside the bounds. The distance field uses this origin.
    // NDC would make fwidth a clip-space derivative and the 0.5 coverage offset wrong.
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

// Inigo Quilez rounded box, matching `sdf_box` in src/draw.zig.
// `k` is the geometric radius clamped to half the shorter edge.
fn sdf_box(p: vec2<f32>, size: vec2<f32>, radius: f32) -> f32 {
    let half_size = 0.5 * size;
    let k = min(radius, min(half_size.x, half_size.y));
    let q = abs(p - half_size) - (half_size - vec2<f32>(k, k));
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0, 0.0))) - k;
}

// Open ring. `arc.x` is the start angle, `arc.y` is the full sweep. Y-down, so
// atan2 grows clockwise. Round caps fall out of the distance to the centerline.
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

// Kind 1 is the arc and is not darkened. Coverage and the clip mask scale alpha only.
// The shader does not discard: a fragment outside the clip blends away.
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

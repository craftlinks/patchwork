// Instanced glyph quads sampled from a prebaked coverage atlas.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Why a Separate Glyph Pipeline
// Glyph instances need a texture rectangle and carry no corner radius or shape kind, while
// face instances need the opposite. Folding both into `quad.wgsl` would add a kind branch
// to every fragment and a record with fields most quads never use. Two pipelines share the
// unit quad, the frame uniform, the render pass, and the blend state instead, and are drawn
// in order within one pass: faces first, then glyphs on top. The CPU bakes ASCII glyphs into
// an `r8unorm` atlas of `font.atlas_width` by `font.atlas_height` texels, so this shader does
// no curve evaluation, hinting, or rasterization.
//
// ## 2. Coordinate Spaces
// - Unit quad: `unit` in `[0, 1]^2`, `(0, 0)` at the top-left vertex.
// - UI logical pixels: top-left origin, `+X` right, `+Y` down.
// - NDC: WebGPU clip volume, `Y` up; `frame.ortho` performs the Y flip (derivation in
//   `draw.zig`).
// - Atlas UV: `[0, 1]^2` with `(0, 0)` at the top-left texel.
//
// Per vertex, with `rect = (x, y, w, h)` and `uv_rect = (u0, v0, u1, v1)`:
//   local = unit * rect.zw
//   pos   = rect.xy + local
//   clip  = ortho * (pos, 0, 1)
//   uv    = mix(uv_rect.xy, uv_rect.zw, unit)
// The baker insets `uv_rect` by half a texel on each side (see `font.zig`), so bilinear
// filtering never reads texels belonging to a neighboring glyph.
//
// ## 3. Fragment Output
// `coverage` is the red channel of the bilinearly filtered atlas sample and
// `alpha = color.a * coverage * inside`, where `inside` is the same hard clip mask as in
// `quad.wgsl` (exclusive-max rectangle, evaluated per fragment, no scissor state). RGB stays
// straight, so the host's source-over blend leaves the destination untouched where coverage
// or the mask is zero.
//
// ## 4. Bindings and Vertex Layout
// - Group 0, binding 0: the shared `Frame` uniform. Only `ortho` is read here; the `Theme`
//   declaration keeps the struct identical to `quad.wgsl` so one bind group serves both.
// - Group 1, binding 0: filterable-float `texture_2d` atlas (`r8unorm`), fragment stage.
// - Group 1, binding 1: filtering sampler, fragment stage, linear min/mag filters and
//   clamp-to-edge addressing on both axes. Both hosts configure this (`host/gpu_wgpu.zig`,
//   `web/shell.js`); clamping stops wrap-around at the atlas border.
// - Vertex inputs: location 0 is the unit quad (per-vertex); locations 1 to 4 are rect,
//   uv_rect, color, and clip from `font.Glyph` (per-instance). Their offsets and the shared
//   stride with `draw.Instance` are enforced by `comptime` asserts in `draw.zig`, and the
//   location numbers by the test "wgsl declarations match the Zig layouts".
//
// ## 5. Shader Invariants
// There are no loops or recursion. `textureSample` runs in uniform control flow because the
// fragment function has no branches before it.

// Must match `theme.Theme` field for field.
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
@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) origin: vec2<f32>,
    @location(3) local: vec2<f32>,
    @location(4) bounds: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) uv_rect: vec4<f32>,
    @location(3) color: vec4<f32>,
    @location(4) bounds: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;
    let local = unit * rect.zw;
    let pos = rect.xy + local;
    out.clip = frame.ortho * vec4<f32>(pos, 0.0, 1.0);
    out.uv = mix(uv_rect.xy, uv_rect.zw, unit);
    out.color = color;
    out.origin = rect.xy;
    out.local = local;
    out.bounds = bounds;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let coverage = textureSample(atlas, samp, in.uv).r;
    let pos = in.origin + in.local;
    let inside = step(in.bounds.x, pos.x) * step(in.bounds.y, pos.y)
        * step(pos.x, in.bounds.z) * step(pos.y, in.bounds.w);
    let alpha = in.color.a * coverage * inside;
    return vec4<f32>(in.color.rgb, alpha);
}

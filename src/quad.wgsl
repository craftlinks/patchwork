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
//      (vec2<f32>) for every individual vertex index in [0..5].
//    - Vertex Buffer 1 (Instances):
//      Contains an array of 48-byte instance records: rect, fill, radius, hover, down, pad.
//      Configured with `stepMode: "instance"`, so the hardware pointer advances by 48 bytes
//      only once per instance index in [0..N-1].
//
// 2. **Vertex Shader (`@vertex fn vs_main`):**
//    Invoked 6 * N times by the GPU execution units (e.g. SIMD warps/wavefronts).
//    For each vertex, it performs:
//    - Local Quad Expansion: Scales the [0..1] unit quad corner to pixel dimensions (rect.zw)
//      and offsets it by the instance screen position (rect.xy).
//    - Orthographic Projection: Multiplies the 2D pixel coordinate by the 4x4 projection matrix
//      to convert from UI logical pixel space [0..width, 0..height] into homogeneous clip space.
//    - Attribute Passing: Forwards the fill, the local pixel, the rectangle size, and the
//      shape vec4 (radius, hover, down, pad) to the rasterizer. Size and shape are identical at
//      every vertex of one instance, so interpolation leaves them unchanged. Local varies.
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
//    Invoked once per covered pixel fragment. Evaluates the rounded-box distance, turns it
//    into analytic coverage, lightens by hover, darkens by down, and returns
//    straight-alpha RGBA. Sections 7 through 9 derive that paint.
//
// 6. **Fixed-Function Blending & Output Merger:**
//    The hardware blend unit merges the fragment color with the existing framebuffer pixel
//    using source-over: `src.rgb * src.a + dst.rgb * (1 - src.a)`, and the same factors for
//    alpha. The shader keeps RGB straight (not premultiplied) and puts coverage into alpha.
//    Premultiplying RGB by coverage as well would darken the antialiased edge.
//
// 7. **Rounded-Box Distance**
//    The unit quad is still the rectangle's axis-aligned bounds. Corner fragments exist.
//    The fragment shader decides which of them belong to the rounded shape.
//
//    `local` is the interpolated point in logical pixels, origin at the instance top-left.
//    `size` is `(width, height)`. `shape.x` is the geometric corner radius. The function is
//    the same field as `sdf_box` in `src/draw.zig`, which is what the CPU tests lock.
//
//    With `half = 0.5 * size` and `k = min(radius, min(half.x, half.y))`:
//
//        q = abs(local - half) - (half - k)
//        dist = min(max(q.x, q.y), 0) + length(max(q, 0)) - k
//
//    Negative inside, zero on the boundary, positive outside. `k` clamps the radius to half
//    the shorter edge, so a large radius becomes a capsule and a square becomes a disc.
//    Radius 0 is the sharp rectangle. A negative radius never arrives: `DrawList.append`
//    rejects it, because the `min` would keep it and invert the field.
//
// 8. **Analytic Coverage**
//    A hard `dist < 0` test aliases the silhouette to the pixel grid. Coverage is a one-pixel
//    ramp centered on the boundary:
//
//        pixel = max(fwidth(dist), 1e-5)
//        coverage = clamp(0.5 - dist / pixel, 0, 1)
//
//    `fwidth(dist)` is `abs(dpdx(dist)) + abs(dpdy(dist))`. The distance is in logical pixels.
//    The derivatives are taken per physical fragment. Their sum is how many logical pixels of
//    distance fit across one device pixel, measured with a Manhattan screen step. Dividing
//    `dist` by that width expresses the field in device pixels. On a 1:1 surface an
//    axis-aligned edge ramps across about one pixel. On a diagonal, `|dpdx| + |dpdy|` is
//    wider than a Euclidean pixel, so that edge is slightly softer. On a surface with
//    device-pixel ratio 2, one fragment covers half a logical pixel, `fwidth` shrinks, and
//    the ramp stays about one device pixel wide.
//
//    At `dist = 0` coverage is 0.5. Half a pixel inside, coverage saturates at 1. Half a pixel
//    outside, coverage saturates at 0. The `1e-5` floor keeps a vanished derivative from
//    dividing by zero. That can happen on a one-pixel quad or on the medial axis, where the
//    nearest-edge choice changes and the numeric derivative collapses.
//
//    The shader does not `discard`. A discarded fragment cannot blend a partial edge, and a
//    zero-coverage corner must show whatever is already in the target. Under source-over,
//    alpha 0 leaves the destination unchanged, which on the first draw is the slate clear.
//    Partial coverage blends the fill over that slate. The rounded corner is the clear color
//    showing through, not a hole cut out of the pipeline.
//
// 9. **Hover Lighten, Then Down Darken**
//    `shape.y` is the hover weight in [0.0, 1.0].
//    `shape.z` is the down/press weight in [0.0, 1.0].
//    `shape.w` is the trailing attribute pad (always 0.0).
//
//    Sequential two-stage color transformation:
//
//        lit = mix(fill.rgb, vec3<f32>(1.0, 1.0, 1.0), shape.y)
//        rgb = mix(lit, vec3<f32>(0.0, 0.0, 0.0), shape.z)
//
//    - Resting state (hover=0, down=0): RGB is unchanged from `fill.rgb`.
//    - Hovered state (hover=0.18, down=0): lightens toward white by 18%.
//    - Pressed state (hover=0.18, down=0.30): lightens by 18%, then darkens by 30%.
//      The down darken wins over hover, giving immediate visual feedback for clicks.
//    - Alpha channel is strictly `fill.a * coverage`. Neither weight modifies alpha.
//    - Straight alpha (unmultiplied RGB) is preserved into the output merger.
//    - Stored instances retain their resting colors; lighting is evaluated entirely in shader.

// Uniform Buffer Binding:
// - `@group(0) @binding(0)`: Binds slot 0 of resource bind group 0 to this uniform variable.
// - `var<uniform>`: Declares read-only constant data shared across all parallel invocations of
//   the draw call.
// - Memory Alignment: WebGPU specification Table 23 requires uniform buffer offset alignments
//   of at least 256 bytes in host memory. In WGSL, `mat4x4<f32>` occupies 64 bytes.
// - Projection Role: Transforms 2D logical UI pixel coordinates into 4D clip coordinates,
//   mapping (0, 0) to top-left NDC (-1, +1) and flipping Y downwards.
@group(0) @binding(0) var<uniform> ortho: mat4x4<f32>;

// Output structure returned by the vertex shader and consumed by the GPU rasterizer.
struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) fill: vec4<f32>,
    // Local pixel inside the rectangle, origin at the instance top-left.
    @location(1) local: vec2<f32>,
    @location(2) size: vec2<f32>,
    // shape.x is radius, shape.y is hover, shape.z is down. shape.w is the pad.
    @location(3) shape: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) fill: vec4<f32>,
    @location(3) shape: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;
    // Local logical pixels inside the bounds. The distance field uses this origin.
    // NDC would make fwidth a clip-space derivative and the 0.5 coverage offset wrong.
    let local = unit * rect.zw;
    let pos = rect.xy + local;
    out.clip = ortho * vec4<f32>(pos, 0.0, 1.0);
    out.fill = fill;
    out.local = local;
    out.size = rect.zw;
    out.shape = shape;
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

// `shape.x` is radius. `shape.y` is hover. `shape.z` is down. Coverage scales alpha only.
// RGB stays straight so the source-over blend does not darken the ramp.
// Zero coverage blends away, which is why the shader does not discard.
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let dist = sdf_box(in.local, in.size, in.shape.x);
    // Floor the screen derivative so a vanished fwidth cannot divide by zero.
    let pixel = max(fwidth(dist), 1.0e-5);
    // 0.5 centers the ramp on the boundary. Dividing by fwidth makes it one device pixel.
    let coverage = clamp(0.5 - dist / pixel, 0.0, 1.0);
    // Lighten toward white, then darken that result toward black. Down wins on a press.
    let lit = mix(in.fill.rgb, vec3<f32>(1.0, 1.0, 1.0), in.shape.y);
    let rgb = mix(lit, vec3<f32>(0.0, 0.0, 0.0), in.shape.z);
    return vec4<f32>(rgb, in.fill.a * coverage);
}

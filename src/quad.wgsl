// WebGPU Shading Language (WGSL) Shader for Hardware-Instanced 2D Quad Rendering.
//
// # Graphics Pipeline Architecture and Data Flow Overview:
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
//      Contains an array of 32-byte instance records [x, y, w, h, r, g, b, a].
//      Configured with `stepMode: "instance"`, so the hardware pointer advances by 32 bytes
//      only once per instance index in [0..N-1].
//
// 2. **Vertex Shader (`@vertex fn vs_main`):**
//    Invoked $6 \times N$ times by the GPU execution units (e.g. SIMD warps/wavefronts).
//    For each vertex, it performs:
//    - Local Quad Expansion: Scales the [0..1] unit quad corner to pixel dimensions (rect.zw)
//      and offsets it by the instance screen position (rect.xy).
//    - Orthographic Projection: Multiplies the 2D pixel coordinate by the 4x4 projection matrix
//      to convert from UI logical pixel space [0..width, 0..height] into homogeneous clip space.
//    - Attribute Passing: Forwards per-instance attributes (like fill color) to the rasterizer.
//
// 3. **Primitive Assembly and Clipping:**
//    The GPU groups triples of vertices into triangles. Triangles outside the clip frustum
//    are discarded; triangles intersecting the clip boundary are geometrically clipped.
//    Perspective division ($x/w, y/w, z/w$) is performed by hardware to produce Normalized
//    Device Coordinates (NDC) in the $[-1, 1]$ cube.
//
// 4. **Rasterization:**
//    The rasterizer tests which physical display pixels (fragments) fall within each triangle face.
//    It interpolates the vertex attributes across each triangle using barycentric coordinates.
//
// 5. **Fragment Shader (`@fragment fn fs_main`):**
//    Invoked once per covered pixel fragment. Returns the final RGBA color of the primitive.
//
// 6. **Fixed-Function Blending & Output Merger:**
//    The hardware blend unit merges the fragment color with the existing framebuffer pixel
//    according to the configured alpha blending equation (e.g. standard source-over compositing).

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
    // `@builtin(position)` is a required WebGPU built-in variable.
    // Represents homogeneous clip-space coordinates [x, y, z, w].
    // For 2D orthographic projections, w is always 1.0, so the hardware perspective divide
    // [x/w, y/w, z/w] leaves the coordinates unchanged in NDC [-1, 1].
    @builtin(position) clip: vec4<f32>,

    // Inter-stage user attribute passed to the fragment shader.
    // `@location(0)` assigns this attribute to inter-stage communication slot 0.
    // The GPU rasterization hardware linearly interpolates this attribute across the triangle face.
    @location(0) fill: vec4<f32>,
};

// Vertex Shader Entry Point:
//
// Inputs fetched automatically by the GPU hardware input assembler:
// - `@location(0) unit: vec2<f32>`:
//   Fetched from Vertex Buffer 0 (`stepMode: "vertex"`).
//   Values are the static 2D corners of the unit quad: (0,0), (1,0), (1,1), etc.
// - `@location(1) rect: vec4<f32>`:
//   Fetched from Vertex Buffer 1 (`stepMode: "instance"`).
//   `rect.xy` is top-left origin (x, y) in logical UI pixels.
//   `rect.zw` is dimensions (width, height) in logical UI pixels.
// - `@location(2) fill: vec4<f32>`:
//   Fetched from Vertex Buffer 1 (`stepMode: "instance"`).
//   `fill.rgba` is the normalized RGBA color components [0.0, 1.0] for this specific instance.
@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) fill: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;

    // Mathematical Quad Reconstruction on the GPU:
    // `unit` ranges from (0, 0) at the top-left to (1, 1) at the bottom-right.
    // Multiplying `unit * rect.zw` scales the unit quad to the target rectangle size:
    // - (0, 0) * (w, h) = (0, 0)
    // - (1, 0) * (w, h) = (w, 0)
    // - (0, 1) * (w, h) = (0, h)
    // - (1, 1) * (w, h) = (w, h)
    // Adding `rect.xy` translates the scaled quad to its screen position (x, y).
    // This entirely eliminates the need for CPU-side geometry generation.
    let pos = rect.xy + unit * rect.zw;

    // Orthographic Matrix Projection:
    // Transforms the 2D logical pixel coordinate into 4D clip space [x, y, 0.0, 1.0].
    // Because `ortho` is column-major, vector multiplication is written as `matrix * vector`.
    // The resulting clip vector has:
    // - x_clip = (2 * pos.x) / width - 1.0
    // - y_clip = 1.0 - (2 * pos.y) / height  (inverting top-down Y to bottom-up NDC Y)
    // - z_clip = 0.0
    // - w_clip = 1.0
    out.clip = ortho * vec4<f32>(pos, 0.0, 1.0);

    // Forward the per-instance color directly to the fragment stage.
    // Because all 3 vertices of each triangle receive the exact same instance color,
    // barycentric interpolation across the quad face produces a uniform, flat color fill.
    out.fill = fill;
    return out;
}

// Fragment Shader Entry Point:
//
// Evaluates every rasterized pixel fragment covered by the rendered quads.
// Returns the final RGBA color vector to color attachment slot 0 (`@location(0)`).
//
// Alpha Blending Mechanics:
// The color returned here is processed by the GPU's fixed-function blending unit.
// Configured with standard non-premultiplied (straight) alpha blending:
// - Color Formula: C_result = (C_src * A_src) + (C_dst * (1.0 - A_src))
// - Alpha Formula: A_result = (A_src * A_src) + (A_dst * (1.0 - A_src))
// This allows translucent quads (A < 1.0) to blend smoothly over the background slate
// and over previously drawn quads in strict painter's algorithm order.
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    return in.fill;
}

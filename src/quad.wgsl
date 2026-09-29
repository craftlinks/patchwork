// WebGPU Shading Language (WGSL) shader for instanced 2D quad rendering.
//
// In modern GPU pipelines, graphics hardware executes two primary programmable stages:
// 1. The Vertex Shader (`@vertex fn vs_main`):
//    Runs once per vertex. Computes the screen position in Normalized Device Coordinates (NDC)
//    and passes per-vertex attributes (like colors or texture coordinates) down the pipeline.
// 2. The Fragment Shader (`@fragment fn fs_main`):
//    Runs once per fragment (pixel candidate) rasterized inside each rendered triangle.
//    Outputs the final color to be written to the color attachment (framebuffer).

// Uniform buffer: Constant data shared across all shader invocations within a draw call.
// `@group(0) @binding(0)` binds slot 0 of bind group 0 to this 4x4 matrix.
// WebGPU requires uniform buffers to be aligned to at least 256 bytes in host memory.
// This matrix converts 2D logical UI pixel coordinates into 4D homogeneous clip coordinates.
@group(0) @binding(0) var<uniform> ortho: mat4x4<f32>;

// Output structure returned by the vertex shader and fed into the GPU rasterizer.
struct VertexOut {
    // `@builtin(position)` is a mandatory WebGPU built-in representing clip space coordinates
    // [x, y, z, w]. The GPU divides x, y, z by w to produce Normalized Device Coordinates (NDC).
    @builtin(position) clip: vec4<f32>,

    // User-defined attribute passed to the fragment shader. `@location(0)` indicates
    // inter-stage location slot 0. The GPU hardware linearly interpolates values across
    // the triangle face before invoking the fragment shader.
    @location(0) fill: vec4<f32>,
};

// Vertex shader entry point.
//
// WebGPU pulls inputs from two vertex buffer bindings with different step modes:
// 1. `@location(0) unit: vec2<f32>`:
//    Read from Vertex Buffer 0 with step mode "vertex". Advances every vertex (6 times per quad).
//    Values are the 2D corners of a static unit square: (0,0), (1,0), (1,1), etc.
// 2. `@location(1) rect: vec4<f32>` and `@location(2) fill: vec4<f32>`:
//    Read from Vertex Buffer 1 with step mode "instance". Advances once per rectangle instance.
//    `rect.xy` is top-left (x, y) in logical pixels; `rect.zw` is (w, h) in logical pixels.
//    `fill` is the RGBA color of this specific rectangle instance.
@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) fill: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;

    // Scale the (0,0)-(1,1) unit square by the rectangle size (width, height) and
    // translate it by the rectangle origin (x, y). This reconstructs the physical
    // rectangle vertices directly on the GPU without CPU mesh generation.
    let pos = rect.xy + unit * rect.zw;

    // Multiply the 2D position by the 4x4 orthographic projection matrix.
    // The projection matrix maps top-left (0, 0) to NDC (-1, +1) and flips the Y-axis.
    out.clip = ortho * vec4<f32>(pos, 0.0, 1.0);

    // Pass the per-instance RGBA color down to the fragment shader.
    out.fill = fill;
    return out;
}

// Fragment shader entry point.
//
// Evaluates every pixel fragment covered by the rasterized triangles.
// Returns the final RGBA color output to `@location(0)` of the active render attachment.
// The GPU's fixed-function blending unit then merges this color into the framebuffer texture
// according to the pipeline's configured alpha blending formula.
@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    return in.fill;
}

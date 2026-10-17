// Instanced Alpha-Coverage Glyph Text Rendering and Bilinear Texture Sampling.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Core Problem & Rationale ("Why")
// In 2D graphical user interfaces, rendering text directly alongside geometric shapes poses
// a fundamental architectural dilemma:
// - **Monolithic Shader / Branched Pipeline:**
//   Attempting to handle both rounded-box SDF geometry and glyph text inside a single shader
//   requires adding conditional branches (`if (kind == GLYPH)`) or expanding the per-instance
//   vertex record to 64 bytes (adding texture IDs, UV bounds, and clip rectangles). This wastes
//   memory bandwidth for every non-text quad and introduces branch divergence in GPU warps.
// - **Immediate Vertex Generation:**
//   Decomposing text into independent textured triangles on the CPU requires generating 4 vertices
//   and 6 indices per glyph, allocating temporary geometry buffers every frame, and thrashing PCIe
//   bandwidth.
//
// **Patchwork's Dual-Pipeline Architecture:**
// - **Shared Hardware Unit Quad:** The exact same static 48-byte unit quad vertex buffer
//   (6 vertices spanning `(0, 0)` to `(1, 1)`) is bound to both the face quad pipeline and the
//   glyph text pipeline.
// - **Separate 48-Byte Instance Records:** Face instance buffer packs `(rect, fill, shape)`,
//   while glyph buffer packs `(dest_rect, uv_rect, color)`. Both strides are 48 bytes,
//   matching WebGPU 16-byte attribute alignment rules (`float32x4`).
// - **Two Draws in One Pass:** The active pass executes `draw_quads(6, quad_count)` then
//   `draw_glyphs(6, glyph_count)`. Sharing color target, depth, and blend avoids pass teardown.
// - **Pre-Baked Coverage:** The CPU pre-bakes ASCII glyphs into a 512 x 256 `r8unorm` atlas.
//   This shader performs zero curve evaluation, zero font hinting, and zero rasterization.
//
// ## 2. Mathematical Derivations & Coordinate Spaces
//
// ### Coordinate Spaces:
// - **Unit Quad Space:** `unit in [0.0, 1.0] x [0.0, 1.0]`. `(0, 0)` is the top-left vertex,
//   and `(1, 1)` is the bottom-right vertex.
// - **UI Logical Screen Space:** Measured in logical pixels. Origin `(0, 0)` is at the top-left
//   of the window. `+X` increases rightwards, and `+Y` increases downwards.
// - **Normalized Device Coordinates (NDC):** WebGPU visible clip volume:
//   `X in [-1.0, +1.0]` (left to right), `Y in [-1.0, +1.0]` (bottom to top, Y-up), and
//   `Z in [0.0, 1.0]` (depth).
// - **Atlas UV Texture Space:** Continuous range `[0.0, 1.0] x [0.0, 1.0]`. `(0, 0)` is top-left
//   texel of the 512 x 256 atlas.
//
// ### Vertex Transformation Algebra:
// Given unit quad vertex `unit = (u_x, u_y)`, destination rectangle `rect = (x, y, w, h)`,
// and normalized UV bounding box `uv_rect = (u0, v0, u1, v1)`:
//
// 1. **Local Screen-Space Position:**
//    ```text
//    local_pos = unit * rect.zw             // local_x = u_x * w,  local_y = u_y * h
//    world_pos = rect.xy + local_pos        // pos_x = x + local_x, pos_y = y + local_y
//    ```
//
// 2. **Orthographic Projection Matrix Multiplication:**
//    Matrix `ortho` is the 4x4 column-major matrix defined in `draw.zig`:
//    ```text
//    clip = ortho * vec4<f32>(world_pos.x, world_pos.y, 0.0, 1.0)
//    ```
//    Expanding the linear system:
//    ```text
//    clip.x = (2.0 / window_width) * world_pos.x - 1.0
//    clip.y = -(2.0 / window_height) * world_pos.y + 1.0
//    clip.z = 0.0
//    clip.w = 1.0
//    ```
//
// 3. **Bilinear Texture Coordinate Interpolation:**
//    The UV bounding box is linearly interpolated across the unit quad:
//    ```text
//    uv = mix(uv_rect.xy, uv_rect.zw, unit)
//       = ( (1.0 - unit.x) * u0 + unit.x * u1,  (1.0 - unit.y) * v0 + unit.y * v1 )
//    ```
//    Because the baker pre-inset `(u0, v0, u1, v1)` by half a texel (`0.5 / 512.0`, `0.5 / 256.0`),
//    `uv` never samples outside the texel centers of the glyph's atlas region.
//
// ### Analytical Coverage and Alpha Compositing:
// In the fragment shader:
// 1. **Texture Sampling:**
//    `coverage = textureSample(atlas, samp, in.uv).r`
//    The atlas is single-channel `r8unorm`. The hardware texture unit samples the red channel,
//    performing bilinear filtering between neighboring texels, returning a scalar in `[0.0, 1.0]`.
// 2. **Alpha Modulation:**
//    `alpha = in.color.a * coverage`
//    Base text opacity `color.a` is scaled directly by the antialiased glyph coverage.
// 3. **Fixed-Function Blend Equation:**
//    The pipeline is configured with standard premultiplied-equivalent straight alpha blending:
//    ```text
//    Color_out = Color_src * Alpha_src + Color_dst * (1.0 - Alpha_src)
//    Alpha_out = Alpha_src * 1.0       + Alpha_dst * (1.0 - Alpha_src)
//    ```
//    Where `Color_src = in.color.rgb` and `Alpha_src = alpha`.
//    Texels with zero coverage (`coverage == 0.0`) produce `Alpha_src == 0.0`, resulting in:
//    `Color_out = Color_dst` (the underlying widget quad is preserved with zero alteration).
//
// ## 3. Hardware, Spec Limits, and C ABI Layouts
//
// ### Bind Group Layouts:
// - **Group 0 (Uniform Buffer):**
//   - Binding 0: `var<uniform> ortho: mat4x4<f32>` (64 bytes of matrix data, padded to 256 bytes
//     to satisfy the WebGPU `minUniformBufferOffsetAlignment` specification rule).
//   - Stage Visibility: `GPUShaderStage.VERTEX`.
// - **Group 1 (Glyph Atlas & Sampler):**
//   - Binding 0: `var atlas: texture_2d<f32>` (texture format `r8unorm`, view dimension `2d`).
//     Stage Visibility: `GPUShaderStage.FRAGMENT`.
//   - Binding 1: `var samp: sampler` (filtering sampler, clamp-to-edge, linear min/mag).
//     Stage Visibility: `GPUShaderStage.FRAGMENT`.
//
// ### Vertex Attribute Locations (Stride: 48 Bytes):
// - `location(0)`: `unit: vec2<f32>` (Buffer 0, arrayStride 8, stepMode `vertex`).
// - `location(1)`: `rect: vec4<f32>` (Buffer 1, arrayStride 48, stepMode `instance`, offset 0).
// - `location(2)`: `uv_rect: vec4<f32>` (Buffer 1, arrayStride 48, stepMode `instance`, offset 16).
// - `location(3)`: `color: vec4<f32>` (Buffer 1, arrayStride 48, stepMode `instance`, offset 32).
//
// ## 4. State Machines & Data Flow
// 1. Host records face instances into `DrawList` and glyph instances into `GlyphList`.
// 2. If `flag_glyphs` and `glyph_count > 0`, host writes `glyph_count * 48` B into `glyph_buffer`.
// 3. Command encoder opens render pass with background clear color.
// 4. `draw_quads` executes with `quadPipeline`, binding `quadBuffer` (0) and `instanceBuffer` (1).
// 5. If `glyph_count > 0`, host sets `glyphPipeline`, binds group 0 (`uniform`),
//    group 1 (`atlas + sampler`), binds buffers 0 and 1, and issues `draw(6, glyph_count)`.
// 6. Render pass closes and commands submit to hardware queue.
//
// ## 5. Cross-Platform Seams & FFI
// - **Shader Compilation:** Native targets compile this source via `wgpuDeviceCreateShaderModule`
//   with `WGPUSType_ShaderSourceWGSL`. Browser targets compile via `device.createShaderModule`.
// - **Bilinear Clamp:** Both backends enforce `clamp-to-edge` on address mode U and V to eliminate
//   texture coordinate wrapping artifacts.
//
// ## 6. TigerStyle Invariants
// - **Bounded Execution:** Zero loops, zero recursion, zero dynamic branch conditions.
// - **Deterministic Output:** No screen-space derivative functions (`fwidth`) or non-uniform flow.

@group(0) @binding(0) var<uniform> ortho: mat4x4<f32>;
@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct VertexOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) unit: vec2<f32>,
    @location(1) rect: vec4<f32>,
    @location(2) uv_rect: vec4<f32>,
    @location(3) color: vec4<f32>,
) -> VertexOut {
    var out: VertexOut;
    let local = unit * rect.zw;
    let pos = rect.xy + local;
    out.clip = ortho * vec4<f32>(pos, 0.0, 1.0);
    out.uv = mix(uv_rect.xy, uv_rect.zw, unit);
    out.color = color;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let coverage = textureSample(atlas, samp, in.uv).r;
    let alpha = in.color.a * coverage;
    return vec4<f32>(in.color.rgb, alpha);
}

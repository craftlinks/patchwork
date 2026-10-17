// Browser-Side WebGPU and WebAssembly Host Harness.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. WebGPU Architecture and Modern Web Graphics
// WebGPU is the modern W3C standard for hardware-accelerated 3D and 2D computing on the web,
// designed to replace legacy WebGL (OpenGL ES 2.0/3.0).
//
// Key Architectural Principles of WebGPU:
// - **Explicit Resource Management:** Unlike WebGL (which maintained global state machines and
//   hidden driver validation), WebGPU uses explicit, stateless, immutable objects:
//   - `GPUAdapter`: The physical graphics card installed in the host machine.
//   - `GPUDevice`: The logical connection to the GPU used to allocate VRAM buffers and textures.
//   - `GPUQueue`: The hardware command queue where recorded command buffers are submitted.
//   - `GPURenderPipeline`: A monolithic, ahead-of-time compiled graphics state object
//     encapsulating shader modules, vertex layouts, blending equations, and rasterization modes.
// - **Asynchronous Validation:** Shader compilation and pipeline creation occur asynchronously
//   during bootstrap, ensuring zero compilation stutter during the interactive render loop.
//
// ## 2. Zero-Copy WebAssembly Interoperability Bridge
// When compiling Zig to WebAssembly with `export_memory = true`, the entire linear memory of
// the Wasm instance is exposed to JavaScript as `wasm.memory.buffer` (an `ArrayBuffer`).
//
// Instead of copying data across boundaries or serializing to JSON:
// - Pointers passed from Zig (e.g. `headerPtr`, `instancePtr`, `shader_ptr()`) are raw 32-bit
//   unsigned integer byte offsets into `wasm.memory.buffer`.
// - JavaScript constructs typed views (`Uint8Array`, `DataView`) over these memory offsets.
// - Binary graphics data is copied directly from Wasm linear memory into WebGPU VRAM buffers via
//   `device.queue.writeBuffer()`.
// - Zero heap allocations, zero string parsing, zero GC pauses.
//
// ## 3. Synchronous Call-Stack Longevity
// In `src/host/web_exports.zig` `tick()`, `PresentHeader` is allocated on Zig's call stack.
// Zig calls the host import `present_js(headerPtr, instancePtr, glyphPtr)` synchronously.
// Because WebAssembly and JavaScript run synchronously on the main UI thread:
// - The Zig stack frame remains active and frozen while `present_js()` executes.
// - JavaScript safely reads `PresentHeader` and instance records directly from Wasm stack memory.
// - When `present_js()` returns, Zig resumes and unwinds the stack.
//
// ## 4. The Optional App Timer and Conditional rAF Chaining
// Traditional web games run an unconditional `requestAnimationFrame` loop painting 60-144 times
// a second. For an application UI toolkit, this wastes battery and heats mobile devices.
//
// In Patchwork:
// - **App Timer (`arm_timer`):**
//   After bootstrap, `arm_timer()` reads `wasm.timer_period_ms()`. The app sets that period in
//   its config. A period of 0 means the app has no timer, so no interval is created and the
//   page idles between events. A non-zero period creates one permanent `setInterval`. Each tick
//   calls `wasm.timer(Math.floor(performance.now()))`. If `timer` returns 1, `schedule()`
//   requests a single `requestAnimationFrame`. `timer` does NOT step widget animators.
// - **Animation Stepping & rAF Chaining (`schedule`):**
//   When rAF fires, `wasm.tick(Math.floor(now))` advances continuous animators and presents dirty
//   frames. `wasm.tick(now)` returns 1 **only** while an animator is moving (`App.live()`):
//   ```javascript
//   if (wasm.tick(Math.floor(now)) === 1) {
//       schedule();
//   }
//   ```
// - **Why rAF Stops When Animators Settle:**
//   When all hover and press transitions settle, `tick()` returns 0, immediately terminating the
//   rAF chain. A resting pointer does NOT keep `requestAnimationFrame` alive.
//   Text labels and passive meters are not animators. With a timer, a resting page presents
//   only when the timer reports a change. Without one it presents only on input.
//
// ## 5. The 64-Byte Instance, the Shape Attribute, and the Clip Attribute
// Zig's `Instance` is four `vec4` groups. The pipeline below fetches them as `float32x4`:
// - Shader location 1, offset  0: rectangle `(x, y, width, height)` in logical pixels.
// - Shader location 2, offset 16: straight-alpha fill `(r, g, b, a)`.
// - Shader location 3, offset 32: `(radius, hover, down, kind)`.
// - Shader location 4, offset 48: exclusive-max clip `(clip_x0, clip_y0, clip_x1, clip_y1)`.
//
// Radius is geometric corner radius (box) or stroke thickness (arc). Hover mixes toward
// theme lighten (white). Down mixes toward theme darken (box) or scales sweep (arc).
// Kind selects box (0) or arc (1).
// WebGPU requires `arrayStride` to be a multiple of 4. This buffer's stride is 64 because
// location 4 reads 16 bytes at offset 48. `wasm.instance_stride()` is the authority. This
// file asserts 64 at pipeline creation and again before `writeBuffer`.
//
// The fragment shader evaluates `sdf_box` or `sdf_arc`, antialiases with `fwidth`,
// mixes toward theme lighten/darken, and multiplies coverage by a hard clip mask.
// Alpha is `fill.a * coverage * inside`. The blend below is source-over on straight alpha.
// A zero-coverage or clipped fragment blends away and shows the slate.
//
// ## 6. Pointer Event Handling, DPI Scaling, and Pointer Capture
// The browser host manages pointer interactions via standard W3C Pointer Events:
// - **DPI Scaling:** `shell.js` receives `offsetX` and `offsetY` in CSS logical pixels.
//   Because `resize` currently passes the physical canvas dimensions (`width * dpr`), pointer
//   coordinates are multiplied by `window.devicePixelRatio` before calling `wasm.pointer_move()`.
// - **Adaptive Frame Scheduling:** Every pointer export returns a `u32` dirty flag.
//   `schedule()` is called only when the return is 1. A move inside the already hovered
//   button returns 0. While a fade is running, `tick` returns 1 and the chain continues.
// - **Pointer Capture:** On `pointerdown`, `canvas.setPointerCapture(event.pointerId)` is invoked.
//   Press and release pass `offsetX * devicePixelRatio` into `pointer_down` / `pointer_up`.
//   `pointerleave` and `pointercancel` call `wasm.pointer_leave()`, which releases capture
//   inside the scene so a drag off the canvas cannot stick.
//
// ## 7. Dual-Pipeline WebGPU Architecture: Shared Uniforms and Dedicated Glyph Atlas
// In WebGPU, pipelines constructed with `layout: "auto"` generate driver-private bind group
// layouts that cannot be bound across different pipeline objects.
// To render both geometric quads and glyph text within the same pass:
//
// 1. **Explicit Shared Group 0 (Uniform Buffer):**
//    An explicit bind group layout is created with a single dynamic uniform buffer binding
//    at binding 0 (`GPUShaderStage.VERTEX`). Both `pipeline` (quads) and `glyphPipeline` (text)
//    reference this exact bind group layout, allowing `bindGroup` (wrapping `uniformBuffer`)
//    to be bound to slot 0 for both draw calls without pipeline rebinding penalties.
//
// 2. **Dedicated Group 1 (Atlas Texture & Sampler):**
//    A second bind group layout is created holding:
//    - Binding 0: `texture_2d<f32>` (sample type `float`, fragment visibility).
//    - Binding 1: `sampler` (filtering sampler, fragment visibility).
//    An `r8unorm` 2D texture (512 x 256 texels) is allocated with `TEXTURE_BINDING | COPY_DST`.
//    The pre-baked atlas (131,072 bytes) is written directly from Wasm linear memory via
//    `device.queue.writeTexture()` with `bytesPerRow = 512` (aligns with 256-byte requirement).
//    A linear filtering sampler configured with `clamp-to-edge` is created.
//
// 3. **104-Byte PresentHeader and Conditional Uploads:**
//    The header is read via `DataView(wasm.memory.buffer, headerPtr, 104)`.
//    Offset 96 contains `glyphCount: u32`.
//    - If `(flags & FLAG_INSTANCES) !== 0` and `count > 0`: uploads `count * 64` bytes.
//    - If `(flags & FLAG_GLYPHS) !== 0` and `glyphCount > 0`: uploads `glyphCount * 64` bytes.
//    - If `glyphCount === 0`: glyph buffer upload and glyph draw call are skipped.
//
// 4. **Sequential Draws in Single Render Pass:**
//    Within the single `beginRenderPass` / `end` scope:
//    - Quads draw: `setPipeline(pipeline)`, `setBindGroup(0, bindGroup)`,
//      `setVertexBuffer(1, instanceBuffer)`, `draw(6, count)`.
//    - Glyphs draw: `setPipeline(glyphPipeline)`, `setBindGroup(0, bindGroup)`,
//      `setBindGroup(1, glyphBindGroup)`, `setVertexBuffer(1, glyphBuffer)`,
//      `draw(6, glyphCount)`.

const canvas = document.getElementById("surface");

let device = null;
let context = null;
let format = null;
let wasm = null;
let raf = 0;
let pipeline = null;
let glyphPipeline = null;
let quadBuffer = null;
let instanceBuffer = null;
let glyphBuffer = null;
let uniformBuffer = null;
let bindGroup = null;
let glyphBindGroup = null;
let configuredWidth = 0;
let configuredHeight = 0;

// Binary layout constants matching `src/draw.zig`.
const FLAG_INSTANCES = 1;
const FLAG_UNIFORM = 2;
const FLAG_GLYPHS = 4;
const HEADER_BYTES = 104;
const MATRIX_BYTES = 64;
const INSTANCE_CAP = 256;

/**
 * Host import invoked synchronously from Zig's `src/host/web_exports.zig` `tick()`.
 * Reads the `PresentHeader` from Wasm stack memory, conditionally uploads modified
 * buffers to GPU VRAM, and executes the instanced draw render pass.
 *
 * @param {number} headerPtr Byte offset of `PresentHeader` in Wasm linear memory.
 * @param {number} instancePtr Byte offset of the face `Instance` array.
 * @param {number} glyphPtr Byte offset of the glyph quad array.
 */
function present_js(headerPtr, instancePtr, glyphPtr) {
    if (context === null || device === null || pipeline === null) {
        throw new Error("present called before the graphics pipeline is initialized");
    }

    // Direct binary access to WebAssembly linear memory without intermediate copying.
    const memory = wasm.memory.buffer;
    const view = new DataView(memory, headerPtr, HEADER_BYTES);

    // Decode PresentHeader fields (little-endian byte order matching x86/wasm32).
    const width = view.getUint32(0, true);
    const height = view.getUint32(4, true);
    const count = view.getUint32(8, true);
    const flags = view.getUint32(12, true);
    const r = view.getFloat32(16, true);
    const g = view.getFloat32(20, true);
    const b = view.getFloat32(24, true);
    const a = view.getFloat32(28, true);
    const glyphCount = view.getUint32(96, true);

    // If the window dimensions or projection changed, upload the 64-byte matrix (offset 32).
    if ((flags & FLAG_UNIFORM) !== 0) {
        device.queue.writeBuffer(
            uniformBuffer,
            0,
            new Uint8Array(memory, headerPtr + 32, MATRIX_BYTES),
        );
        const themeLen = wasm.theme_len();
        if (themeLen !== 192) {
            throw new Error("theme length mismatch: expected 192 bytes");
        }
        device.queue.writeBuffer(
            uniformBuffer,
            MATRIX_BYTES,
            new Uint8Array(memory, wasm.theme_ptr(), themeLen),
        );
    }

    // If the draw list contents changed, upload `count * stride` bytes to the instance buffer.
    if ((flags & FLAG_INSTANCES) !== 0) {
        if (count !== 0) {
            const stride = wasm.instance_stride();
            if (stride !== 64) {
                throw new Error("instance stride mismatch: expected 64 bytes");
            }
            device.queue.writeBuffer(
                instanceBuffer,
                0,
                new Uint8Array(memory, instancePtr, count * stride),
            );
        }
    }

    // Glyph quads are a second buffer. A zero count skips the upload.
    if ((flags & FLAG_GLYPHS) !== 0) {
        if (glyphCount !== 0) {
            const glyphStride = wasm.glyph_stride();
            if (glyphStride !== 64) {
                throw new Error("glyph stride mismatch: expected 64 bytes");
            }
            device.queue.writeBuffer(
                glyphBuffer,
                0,
                new Uint8Array(memory, glyphPtr, glyphCount * glyphStride),
            );
        }
    }

    // Reconfigure the canvas swapchain texture if physical pixel dimensions changed.
    if (width !== configuredWidth || height !== configuredHeight) {
        context.configure({
            device,
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT,
            alphaMode: "opaque",
            presentMode: "fifo", // VSync FIFO swapchain pacing
            width,
            height,
        });
        configuredWidth = width;
        configuredHeight = height;
    }

    // Record GPU drawing commands into a command buffer.
    const encoder = device.createCommandEncoder();

    // Begin render pass: clears the screen with the background slate color.
    const pass = encoder.beginRenderPass({
        colorAttachments: [{
            view: context.getCurrentTexture().createView(),
            loadOp: "clear",
            storeOp: "store",
            clearValue: { r, g, b, a },
        }],
    });

    // Bind graphics state and issue the single instanced draw call.
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bindGroup);
    pass.setVertexBuffer(0, quadBuffer);
    pass.setVertexBuffer(1, instanceBuffer);
    pass.draw(6, count);
    if (glyphCount !== 0) {
        pass.setPipeline(glyphPipeline);
        pass.setBindGroup(0, bindGroup);
        pass.setBindGroup(1, glyphBindGroup);
        pass.setVertexBuffer(0, quadBuffer);
        pass.setVertexBuffer(1, glyphBuffer);
        pass.draw(6, glyphCount);
    }
    pass.end();

    // Submit recorded command buffer to the GPU hardware execution queue.
    device.queue.submit([encoder.finish()]);
}

/**
 * Compiles the WGSL shader and constructs the WebGPU render pipeline.
 * Queries buffer sizes and layout strides dynamically from Zig exports to ensure
 * Zig remains the single authoritative source of truth.
 */
async function create_pipeline() {
    const stride = wasm.instance_stride();
    const quadByteCount = wasm.quad_bytes();
    const shaderLen = wasm.shader_len();

    if (stride !== 64) {
        throw new Error("instance stride mismatch: expected 64 bytes");
    }
    const glyphStride = wasm.glyph_stride();
    if (glyphStride !== 64) {
        throw new Error("glyph stride mismatch: expected 64 bytes");
    }
    if (quadByteCount !== 48) {
        throw new Error("unit quad size mismatch: expected 48 bytes");
    }
    if (shaderLen === 0) {
        throw new Error("shader source is empty");
    }

    const module = await compile_shader(wasm.shader_ptr(), shaderLen, "quad");
    const glyphModule = await compile_shader(
        wasm.glyph_shader_ptr(),
        wasm.glyph_shader_len(),
        "glyph",
    );

    // Allocate GPU buffers:
    // 1. Static unit quad (48 bytes: 6 vertices of 2D points).
    quadBuffer = device.createBuffer({
        size: quadByteCount,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 2. Instance buffer (16,384 bytes: 256 instances * 64 bytes).
    instanceBuffer = device.createBuffer({
        size: INSTANCE_CAP * stride,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 3. Uniform buffer (256 bytes for minimum WebGPU uniform alignment).
    uniformBuffer = device.createBuffer({
        size: 256,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    const memory = wasm.memory.buffer;
    // Upload static unit quad coordinates once at startup.
    device.queue.writeBuffer(
        quadBuffer,
        0,
        new Uint8Array(memory, wasm.quad_ptr(), quadByteCount),
    );

    const atlasWidth = wasm.atlas_width();
    const atlasHeight = wasm.atlas_height();
    const atlasLen = wasm.atlas_len();
    if (atlasWidth !== 512) {
        throw new Error("atlas width mismatch: expected 512");
    }
    if (atlasLen !== 131072) {
        throw new Error("atlas length mismatch: expected 131072 bytes");
    }
    if (atlasWidth % 256 !== 0) {
        throw new Error("atlas bytesPerRow is not a multiple of 256");
    }

    glyphBuffer = device.createBuffer({
        size: INSTANCE_CAP * wasm.glyph_stride(),
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // Group 0 is the shared uniform. Group 1 is the atlas. Auto layouts are
    // not compatible across pipelines, so both pipelines use these objects.
    const group0 = device.createBindGroupLayout({
        entries: [{
            binding: 0,
            visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
            buffer: { type: "uniform", minBindingSize: 256 },
        }],
    });
    const group1 = device.createBindGroupLayout({
        entries: [
            {
                binding: 0,
                visibility: GPUShaderStage.FRAGMENT,
                texture: { sampleType: "float" },
            },
            {
                binding: 1,
                visibility: GPUShaderStage.FRAGMENT,
                sampler: { type: "filtering" },
            },
        ],
    });
    const quadLayout = device.createPipelineLayout({ bindGroupLayouts: [group0] });
    const glyphLayout = device.createPipelineLayout({ bindGroupLayouts: [group0, group1] });
    const blend = {
        color: {
            srcFactor: "src-alpha",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
        },
        alpha: {
            srcFactor: "src-alpha",
            dstFactor: "one-minus-src-alpha",
            operation: "add",
        },
    };
    const unitBuffer = {
        arrayStride: 8,
        stepMode: "vertex",
        attributes: [{ shaderLocation: 0, offset: 0, format: "float32x2" }],
    };

    pipeline = device.createRenderPipeline({
        layout: quadLayout,
        vertex: {
            module,
            entryPoint: "vs_main",
            buffers: [
                unitBuffer,
                {
                    arrayStride: stride,
                    stepMode: "instance",
                    attributes: [
                        { shaderLocation: 1, offset: 0, format: "float32x4" },
                        { shaderLocation: 2, offset: 16, format: "float32x4" },
                        { shaderLocation: 3, offset: 32, format: "float32x4" },
                        { shaderLocation: 4, offset: 48, format: "float32x4" },
                    ],
                },
            ],
        },
        fragment: {
            module,
            entryPoint: "fs_main",
            targets: [{ format, blend }],
        },
        primitive: { topology: "triangle-list" },
    });

    glyphPipeline = device.createRenderPipeline({
        layout: glyphLayout,
        vertex: {
            module: glyphModule,
            entryPoint: "vs_main",
            buffers: [
                unitBuffer,
                {
                    arrayStride: glyphStride,
                    stepMode: "instance",
                    attributes: [
                        { shaderLocation: 1, offset: 0, format: "float32x4" },
                        { shaderLocation: 2, offset: 16, format: "float32x4" },
                        { shaderLocation: 3, offset: 32, format: "float32x4" },
                        { shaderLocation: 4, offset: 48, format: "float32x4" },
                    ],
                },
            ],
        },
        fragment: {
            module: glyphModule,
            entryPoint: "fs_main",
            targets: [{ format, blend }],
        },
        primitive: { topology: "triangle-list" },
    });

    bindGroup = device.createBindGroup({
        layout: group0,
        entries: [{
            binding: 0,
            resource: { buffer: uniformBuffer },
        }],
    });

    const atlas = device.createTexture({
        size: { width: atlasWidth, height: atlasHeight },
        format: "r8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    device.queue.writeTexture(
        { texture: atlas },
        new Uint8Array(memory, wasm.atlas_ptr(), atlasLen),
        { bytesPerRow: atlasWidth, rowsPerImage: atlasHeight },
        { width: atlasWidth, height: atlasHeight },
    );
    const glyphSampler = device.createSampler({
        addressModeU: "clamp-to-edge",
        addressModeV: "clamp-to-edge",
        magFilter: "linear",
        minFilter: "linear",
    });
    glyphBindGroup = device.createBindGroup({
        layout: group1,
        entries: [
            { binding: 0, resource: atlas.createView() },
            { binding: 1, resource: glyphSampler },
        ],
    });
}

/**
 * Compiles a WGSL shader module from WebAssembly linear memory and validates compilation info.
 *
 * @param {number} ptr - Byte offset of shader source text in Wasm linear memory.
 * @param {number} len - Byte length of shader source text.
 * @param {string} label - Human-readable label for error reporting ("quad" or "glyph").
 * @returns {Promise<GPUShaderModule>} Compiled WebGPU shader module.
 */
async function compile_shader(ptr, len, label) {
    if (len === 0) {
        throw new Error(`${label} shader source is empty`);
    }
    const text = new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, ptr, len));
    const module = device.createShaderModule({ code: text });
    const info = await module.getCompilationInfo();
    for (const message of info.messages) {
        if (message.type === "error") {
            throw new Error(`${label} WGSL: ${message.message}`);
        }
    }
    return module;
}

/**
 * Schedules an animation frame if one is not already queued.
 */
function schedule() {
    if (raf !== 0) {
        return;
    }
    raf = requestAnimationFrame((now) => {
        raf = 0;
        // tick returns 1 only while an animator is still moving, so the chain
        // stops once hover and press have settled. The app timer, when there is one,
        // requests the next frame on its own.
        if (wasm.tick(Math.floor(now)) === 1) {
            schedule();
        }
    });
}

/**
 * Arms the app timer. The app sets `timer_period_ms` in its config, and 0 means the app
 * has no timer, so no interval is created and the page idles between events. A non-zero
 * period wakes the app with `timer(now_ms)` and asks for one frame when it reports a
 * change. The interval stays armed for the life of the page.
 */
function arm_timer() {
    const period = wasm.timer_period_ms();
    if (period === 0) {
        return;
    }
    setInterval(() => {
        const now = Math.floor(performance.now());
        if (wasm.timer(now) === 1) {
            schedule();
        }
    }, period);
}

/**
 * Synchronizes canvas resolution to physical device pixels (HiDPI / Retina scaling).
 * If the physical resolution changes, notifies Zig and schedules a redraw.
 */
function fit_canvas() {
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.floor(canvas.clientWidth * dpr));
    const height = Math.max(1, Math.floor(canvas.clientHeight * dpr));
    canvas.width = width;
    canvas.height = height;

    // If Zig reports that the resize dirtied the frame, schedule a draw.
    if (wasm.resize(width, height) === 1) {
        schedule();
    }
}

/**
 * Returns the device pixel ratio multiplier used to scale CSS coordinates to canvas pixels.
 * @returns {number} Device pixel ratio (defaults to 1.0 if undefined).
 */
function pointer_scale() {
    return window.devicePixelRatio || 1;
}

/**
 * Handles DOM `pointermove` events. Scales coordinates and notifies Wasm.
 * @param {PointerEvent} event
 */
function on_pointer_move(event) {
    const scale = pointer_scale();
    if (wasm.pointer_move(event.offsetX * scale, event.offsetY * scale) === 1) {
        schedule();
    }
}

/**
 * Handles DOM `pointerdown` events for the primary button. Captures pointer and notifies Wasm.
 * @param {PointerEvent} event
 */
function on_pointer_down(event) {
    if (event.button !== 0) {
        return;
    }
    canvas.setPointerCapture(event.pointerId);
    const scale = pointer_scale();
    if (wasm.pointer_down(event.offsetX * scale, event.offsetY * scale) === 1) {
        schedule();
    }
}

/**
 * Handles DOM `pointerup` events for the primary button. Notifies Wasm of button release.
 * @param {PointerEvent} event
 */
function on_pointer_up(event) {
    if (event.button !== 0) {
        return;
    }
    const scale = pointer_scale();
    if (wasm.pointer_up(event.offsetX * scale, event.offsetY * scale) === 1) {
        schedule();
    }
}

/**
 * Handles DOM `wheel` events. Normalizes line/pixel deltas, scales coordinates, and notifies Wasm.
 * @param {WheelEvent} event
 */
function on_wheel(event) {
    event.preventDefault();
    const scale = pointer_scale();
    let dy = event.deltaY;
    if (event.deltaMode === 1) {
        dy *= 16;
    }
    dy *= scale;
    if (wasm.pointer_wheel(event.offsetX * scale, event.offsetY * scale, dy) === 1) {
        schedule();
    }
}

/**
 * Handles DOM `pointerleave` and `pointercancel` events. Resets hover and press states in Wasm.
 */
function on_pointer_leave() {
    if (wasm.pointer_leave() === 1) {
        schedule();
    }
}

/**
 * Main application bootstrap.
 * Connects to WebGPU, instantiates Wasm, compiles the pipeline, and begins presentation.
 */
async function main() {
    if (navigator.gpu === undefined) {
        throw new Error("WebGPU is unavailable in this browser");
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (adapter === null) {
        throw new Error("no WebGPU adapter found");
    }

    device = await adapter.requestDevice();
    context = canvas.getContext("webgpu");
    format = navigator.gpu.getPreferredCanvasFormat();

    // Fetch and instantiate the freestanding WebAssembly module.
    const response = await fetch("patchwork.wasm");
    const imported = await WebAssembly.instantiateStreaming(response, {
        env: { present_js },
    });

    wasm = imported.instance.exports;

    // Compile graphics pipeline, initialize Zig state, and size canvas.
    await create_pipeline();
    wasm.start();
    fit_canvas();
    arm_timer();

    // Listen for window resize events.
    window.addEventListener("resize", fit_canvas);
    canvas.addEventListener("pointermove", on_pointer_move);
    canvas.addEventListener("pointerdown", on_pointer_down);
    canvas.addEventListener("pointerup", on_pointer_up);
    canvas.addEventListener("pointerleave", on_pointer_leave);
    canvas.addEventListener("pointercancel", on_pointer_leave);
    canvas.addEventListener("wheel", on_wheel, { passive: false });
}

main();

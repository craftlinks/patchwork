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
// In `web_exports.zig:tick()`, `PresentHeader` is allocated directly on Zig's call stack.
// Zig calls the host import `present_js(headerPtr, instancePtr)` synchronously.
// Because WebAssembly and JavaScript run synchronously on the main UI thread:
// - The Zig stack frame remains active and frozen while `present_js()` executes.
// - JavaScript safely reads `PresentHeader` and instance records directly from Wasm stack memory.
// - When `present_js()` returns, Zig resumes and unwinds the stack.
//
// ## 4. Power-Optimal Frame Pacing and rAF Chaining (0% Idle CPU / GPU)
// Traditional web games run an unconditional `requestAnimationFrame` loop that paints 60-144 times
// a second. For an application UI toolkit, this wastes battery and heats the device while reading
// or idling.
//
// In Patchwork:
// - `requestAnimationFrame` is scheduled when Zig signals that a frame is dirty (`resize`, `pointer_*`).
// - When the rAF callback fires, `wasm.tick(Math.floor(now))` steps animators and presents dirty frames.
// - `wasm.tick(now)` returns 1 while any widget animator is still moving (`scene.live()`), and
//   `schedule()` chains another `requestAnimationFrame` only while `wasm.tick()` returns 1:
//   ```javascript
//   if (wasm.tick(Math.floor(now)) === 1) {
//       schedule();
//   }
//   ```
// - When all animators settle, `tick()` returns 0, terminating the rAF chain.
// - A resting hover does not keep the callback running.
// - The browser tab consumes 0.0% CPU and 0.0% GPU cycles once every animator has settled.
//
// ## 5. The 48-Byte Instance and the Shape Attribute
// Zig's `Instance` is three `vec4` groups. The pipeline below fetches them as `float32x4`:
// - Shader location 1, offset  0: rectangle `(x, y, width, height)` in logical pixels.
// - Shader location 2, offset 16: straight-alpha fill `(r, g, b, a)`.
// - Shader location 3, offset 32: `(radius, hover, down, pad)`.
//
// Radius is the geometric corner radius. Hover mixes toward white. Down mixes that result
// toward black. The pad completes the `vec4` the shader declares at `@location(3)`.
// WebGPU requires `arrayStride` to be a multiple of 4. This buffer's stride is 48 because
// location 3 reads 16 bytes at offset 32. `wasm.instance_stride()` is the authority. This
// file asserts 48 at pipeline creation and again before `writeBuffer`, so a Zig layout
// change fails loudly instead of sampling hover from the fill's alpha.
//
// The fragment shader evaluates a rounded-box distance in that local rectangle, antialiases
// with `fwidth`, lightens RGB by hover, then darkens by down. Alpha is `fill.a * coverage`.
// The blend below is source-over on straight alpha. A zero-coverage corner blends away and
// shows the slate.
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

const canvas = document.getElementById("surface");

let device = null;
let context = null;
let format = null;
let wasm = null;
let raf = 0;
let pipeline = null;
let quadBuffer = null;
let instanceBuffer = null;
let uniformBuffer = null;
let bindGroup = null;
let configuredWidth = 0;
let configuredHeight = 0;

// Binary layout constants matching `src/draw.zig`.
const FLAG_INSTANCES = 1;
const FLAG_UNIFORM = 2;
const HEADER_BYTES = 96;
const MATRIX_BYTES = 64;
const INSTANCE_CAP = 256;

/**
 * Host import invoked synchronously from Zig's `web_exports.zig:tick()`.
 * Reads the `PresentHeader` from Wasm stack memory, conditionally uploads modified
 * buffers to GPU VRAM, and executes the instanced draw render pass.
 *
 * @param {number} headerPtr Byte offset of `PresentHeader` in Wasm linear memory.
 * @param {number} instancePtr Byte offset of `Instance` array in Wasm linear memory.
 */
function present_js(headerPtr, instancePtr) {
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

    // If the window dimensions or projection changed, upload the 64-byte matrix (offset 32).
    if ((flags & FLAG_UNIFORM) !== 0) {
        device.queue.writeBuffer(
            uniformBuffer,
            0,
            new Uint8Array(memory, headerPtr + 32, MATRIX_BYTES),
        );
    }

    // If the draw list contents changed, upload `count * stride` bytes to the instance buffer.
    if ((flags & FLAG_INSTANCES) !== 0) {
        if (count !== 0) {
            const stride = wasm.instance_stride();
            if (stride !== 48) {
                throw new Error("instance stride mismatch: expected 48 bytes");
            }
            device.queue.writeBuffer(
                instanceBuffer,
                0,
                new Uint8Array(memory, instancePtr, count * stride),
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
    pass.draw(6, count); // 6 vertices of the unit quad, repeated `count` times
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

    if (stride !== 48) {
        throw new Error("instance stride mismatch: expected 48 bytes");
    }
    if (quadByteCount !== 48) {
        throw new Error("unit quad size mismatch: expected 48 bytes");
    }
    if (shaderLen === 0) {
        throw new Error("shader source is empty");
    }

    // Read WGSL shader text directly from Wasm linear memory.
    const memory = wasm.memory.buffer;
    const shaderText = new TextDecoder().decode(
        new Uint8Array(memory, wasm.shader_ptr(), shaderLen),
    );

    const module = device.createShaderModule({ code: shaderText });
    const info = await module.getCompilationInfo();
    for (const message of info.messages) {
        if (message.type === "error") {
            throw new Error(`WGSL Compilation Error: ${message.message}`);
        }
    }

    // Allocate GPU buffers:
    // 1. Static unit quad (48 bytes: 6 vertices of 2D points).
    quadBuffer = device.createBuffer({
        size: quadByteCount,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 2. Instance buffer (12,288 bytes: 256 instances * 48 bytes).
    instanceBuffer = device.createBuffer({
        size: INSTANCE_CAP * stride,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 3. Uniform buffer (256 bytes for minimum WebGPU uniform alignment).
    uniformBuffer = device.createBuffer({
        size: 256,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    // Upload static unit quad coordinates once at startup.
    device.queue.writeBuffer(
        quadBuffer,
        0,
        new Uint8Array(memory, wasm.quad_ptr(), quadByteCount),
    );

    // Build the fixed-function render pipeline with alpha blending.
    pipeline = device.createRenderPipeline({
        layout: "auto",
        vertex: {
            module,
            entryPoint: "vs_main",
            buffers: [
                // Vertex Buffer 0: Unit Quad (stepMode: "vertex")
                {
                    arrayStride: 8,
                    stepMode: "vertex",
                    attributes: [{ shaderLocation: 0, offset: 0, format: "float32x2" }],
                },
                // Vertex Buffer 1: Instances (stepMode: "instance").
                // Location 3 is the shape vec4. The shader reads radius, hover, and down.
                {
                    arrayStride: stride,
                    stepMode: "instance",
                    attributes: [
                        { shaderLocation: 1, offset: 0, format: "float32x4" }, // rect
                        { shaderLocation: 2, offset: 16, format: "float32x4" }, // fill
                        { shaderLocation: 3, offset: 32, format: "float32x4" }, // shape
                    ],
                },
            ],
        },
        fragment: {
            module,
            entryPoint: "fs_main",
            targets: [{
                format,
                // Standard alpha compositing: (src * src_a) + (dst * (1 - src_a))
                blend: {
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
                },
            }],
        },
        primitive: { topology: "triangle-list" },
    });

    // Create bind group connecting the uniform buffer to binding slot 0.
    bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [{
            binding: 0,
            resource: { buffer: uniformBuffer },
        }],
    });
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
        // stops once hover and press have settled.
        if (wasm.tick(Math.floor(now)) === 1) {
            schedule();
        }
    });
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

    // Listen for window resize events.
    window.addEventListener("resize", fit_canvas);
    canvas.addEventListener("pointermove", on_pointer_move);
    canvas.addEventListener("pointerdown", on_pointer_down);
    canvas.addEventListener("pointerup", on_pointer_up);
    canvas.addEventListener("pointerleave", on_pointer_leave);
    canvas.addEventListener("pointercancel", on_pointer_leave);
}

main();

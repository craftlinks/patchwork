// Browser-side WebGPU and WebAssembly host harness.
//
// Concepts for Novices:
// 1. WebGPU in the Browser:
//    WebGPU is the modern W3C graphics standard for the web (replacing WebGL).
//    Unlike WebGL (which was stateful and based on OpenGL ES), WebGPU is stateless and mirrors
//    explicit modern APIs like Vulkan, Metal, and DirectX 12.
//    - `GPUAdapter`: Represents the physical GPU hardware installed in the computer.
//    - `GPUDevice`: The logical connection to the adapter used to allocate GPU resources.
//    - `GPUCanvasContext`: Attached to an HTML5 <canvas> element to display rendered frames.
//
// 2. Zero-Copy WebAssembly Interop:
//    When Zig exports memory (`export_memory = true`), `wasm.memory.buffer` exposes the
//    entire linear memory of the WebAssembly module as an `ArrayBuffer`.
//    JavaScript can create typed array views (`Uint8Array`, `DataView`) directly over this buffer
//    using memory addresses passed from Zig. This allows copying binary graphics data directly
//    into WebGPU VRAM buffers without JSON serialization or intermediate string conversions.
//
// 3. Power-Efficient Frame Pacing (0% Idle CPU):
//    Traditional web games run a continuous `requestAnimationFrame` loop that paints 60-144 times
//    a second. For a UI toolkit, this drains battery while reading a document or typing.
//    Here, `requestAnimationFrame` is ONLY scheduled when Zig indicates the frame is dirty
//    (e.g. during an initial draw or a resize event). When clean, the browser is idle.

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

// Constants matching the binary layout defined in `src/draw.zig`.
const FLAG_INSTANCES = 1;
const FLAG_UNIFORM = 2;
const HEADER_BYTES = 96;
const MATRIX_BYTES = 64;
const INSTANCE_CAP = 256;

/**
 * Host import invoked synchronously from Zig's `web_exports.zig:tick()`.
 * Reads the `PresentHeader` from Wasm stack memory and issues the WebGPU draw pass.
 *
 * @param {number} headerPtr Memory address of the `PresentHeader` in Wasm linear memory.
 * @param {number} instancePtr Memory address of the `Instance` array in Wasm linear memory.
 */
function present_js(headerPtr, instancePtr) {
    if (context === null || device === null || pipeline === null) {
        throw new Error("present before the pipeline exists");
    }

    // Direct binary access to WebAssembly linear memory without copying.
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
            device.queue.writeBuffer(
                instanceBuffer,
                0,
                new Uint8Array(memory, instancePtr, count * stride),
            );
        }
    }

    // Reconfigure the canvas swapchain texture if the physical dimensions changed.
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

    // Begin the render pass: clears the screen with the background slate color.
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
 * Compiles the WGSL shader and builds the WebGPU render pipeline.
 */
async function create_pipeline() {
    const stride = wasm.instance_stride();
    const quadByteCount = wasm.quad_bytes();
    const shaderLen = wasm.shader_len();

    if (stride !== 32) {
        throw new Error("instance stride must be 32");
    }
    if (quadByteCount !== 48) {
        throw new Error("unit quad must be 48 bytes");
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
            throw new Error(message.message);
        }
    }

    // Allocate GPU buffers:
    // 1. Static unit quad (48 bytes: 6 vertices of 2D points).
    quadBuffer = device.createBuffer({
        size: quadByteCount,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 2. Instance buffer (8,192 bytes: 256 instances * 32 bytes).
    instanceBuffer = device.createBuffer({
        size: INSTANCE_CAP * stride,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // 3. Uniform buffer (256 bytes for minimum WebGPU uniform alignment).
    uniformBuffer = device.createBuffer({
        size: 256,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    // Upload the static unit quad coordinates once at startup.
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
                // Vertex Buffer 1: Instances (stepMode: "instance")
                {
                    arrayStride: stride,
                    stepMode: "instance",
                    attributes: [
                        { shaderLocation: 1, offset: 0, format: "float32x4" }, // rect [x, y, w, h]
                        { shaderLocation: 2, offset: 16, format: "float32x4" }, // fill [r, g, b, a]
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
    raf = requestAnimationFrame(() => {
        raf = 0;
        wasm.tick();
    });
}

/**
 * Synchronizes the canvas resolution to physical device pixels (HiDPI / Retina scaling).
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
 * Main application bootstrap.
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
}

main();

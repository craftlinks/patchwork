// Browser-side WebGPU and WebAssembly host harness.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Role and Zero-Copy Memory Bridge
// This file owns everything the freestanding Wasm module cannot touch: WebGPU device setup,
// DOM events, timers, and animation-frame scheduling. The module exposes its linear memory
// as `wasm.memory.buffer`. Pointers returned by exports (or passed to `present_js`) are u32
// byte offsets into that buffer. JavaScript wraps them in typed views and hands the bytes
// straight to `device.queue.writeBuffer` / `writeTexture`, so no data is serialized.
//
// ## 2. Contract With the Zig Exports
// The Zig side is the source of truth for shaders, strides, theme bytes, and atlas size;
// `create_pipeline` queries the exports in `src/host/web_exports.zig` rather than embedding
// them. Where this file must hard-code a layout fact, the Zig side enforces the same fact
// with `comptime` asserts (the block at the end of `web_exports.zig`). Strides, quad size,
// theme length, and atlas size are additionally checked against the exports at runtime and
// throw on mismatch; the header offsets and `INSTANCE_CAP` rely on the Zig asserts alone:
// - `PresentHeader` field offsets and size: `draw.PresentHeader`; mirrored by
//   `HEADER_BYTES` and the offsets decoded in `present_js`.
// - Upload flag bits: `draw.flag_*`; mirrored by `FLAG_*`.
// - Instance and glyph vertex attribute locations and offsets: `draw.Instance`,
//   `font.Glyph`, and the vertex layout in `src/host/gpu_wgpu.zig`.
// - Vertex buffer capacity: `draw.instance_cap` and `font.glyph_cap`; mirrored by
//   `INSTANCE_CAP`.
// - Uniform buffer size and theme offset: `draw.uniform_bytes` and `draw.matrix_bytes`.
// Numeric values are deliberately not repeated in prose; read them from those names.
//
// ## 3. Synchronous Call-Stack Longevity
// `present_js` is invoked from inside Wasm. The engine suspends the Zig frame for the
// duration of the call, so `headerPtr` points at a live `PresentHeader` on that stack.
// `present_js` must finish reading it, and must not keep the pointer or any view over it,
// before returning. Instance and glyph pointers follow the same rule.
//
// ## 4. Frame Scheduling
// There is no unconditional `requestAnimationFrame` loop; an idle UI should not burn power.
// - Every Wasm entry point that can dirty the frame returns a flag, and `schedule()` runs
//   only when it is 1.
// - `tick` (the rAF callback) returns 1 only while an animator is live, so the rAF chain
//   ends when the scene settles and is restarted by input or the app timer.
// - `arm_timer` creates one permanent interval only when `wasm.timer_period_ms()` is
//   nonzero. The timer requests a frame when the app reports a change; it never steps
//   animators.
//
// ## 5. Pointer and DPI Handling
// `resize` receives physical canvas pixels (CSS size times `devicePixelRatio`), so pointer
// positions, which the DOM reports in CSS pixels, are multiplied by the same ratio before
// crossing into Wasm. Pointer capture keeps a drag that leaves the canvas deliverable;
// `pointerleave` and `pointercancel` call `wasm.pointer_leave()` so the scene can release
// any press in progress. Wheel deltas in line mode are converted to pixels before scaling.
//
// ## 6. Pipelines and Bind Groups
// Pipelines created with `layout: "auto"` get private bind group layouts that cannot be
// shared, so both pipelines are built from explicit layouts instead: group 0 (one uniform
// buffer, shared) and group 1 (atlas texture and filtering sampler, glyph pipeline only).
// Draw order inside the single render pass is quads, then glyphs. The blend state is
// source-over on straight alpha, matching the fragment shaders' output.
// `writeTexture` does not require 256-byte row alignment, but the Zig side keeps the atlas
// width a multiple of 256 (`comptime` assert in `gpu_wgpu.zig`), which `create_pipeline`
// re-checks.

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

// Mirrors of Zig constants; see the guide, section 2, for which names they track.
const FLAG_INSTANCES = 1;
const FLAG_UNIFORM = 2;
const FLAG_GLYPHS = 4;
const HEADER_BYTES = 104;
const MATRIX_BYTES = 64;
const INSTANCE_CAP = 256;

/**
 * Host import called synchronously from `present_frame` in `src/host/web_exports.zig`.
 * Decodes the `PresentHeader`, uploads the buffers its flags name, and draws one frame.
 * Must not retain any of the pointers after returning (guide, section 3).
 *
 * @param {number} headerPtr Byte offset of `PresentHeader` in Wasm linear memory.
 * @param {number} instancePtr Byte offset of the face `Instance` array.
 * @param {number} glyphPtr Byte offset of the glyph quad array.
 */
function present_js(headerPtr, instancePtr, glyphPtr) {
    if (context === null || device === null || pipeline === null) {
        throw new Error("present called before the graphics pipeline is initialized");
    }

    const memory = wasm.memory.buffer;
    const view = new DataView(memory, headerPtr, HEADER_BYTES);

    // WebAssembly memory is little-endian. Offsets are pinned by `web_exports.zig`.
    const width = view.getUint32(0, true);
    const height = view.getUint32(4, true);
    const count = view.getUint32(8, true);
    const flags = view.getUint32(12, true);
    const r = view.getFloat32(16, true);
    const g = view.getFloat32(20, true);
    const b = view.getFloat32(24, true);
    const a = view.getFloat32(28, true);
    const glyphCount = view.getUint32(96, true);

    // The matrix is the `ortho` field; the theme follows it in the uniform buffer.
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

    // Only `count` records are uploaded; the buffer holds `INSTANCE_CAP`.
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

    // Glyph quads live in a second buffer. A zero count skips the upload.
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

    // The canvas texture must be reconfigured whenever the physical size changes.
    if (width !== configuredWidth || height !== configuredHeight) {
        context.configure({
            device,
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT,
            alphaMode: "opaque",
            presentMode: "fifo", // The only mode every WebGPU implementation must support.
            width,
            height,
        });
        configuredWidth = width;
        configuredHeight = height;
    }

    const encoder = device.createCommandEncoder();

    const pass = encoder.beginRenderPass({
        colorAttachments: [{
            view: context.getCurrentTexture().createView(),
            loadOp: "clear",
            storeOp: "store",
            clearValue: { r, g, b, a },
        }],
    });

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

    device.queue.submit([encoder.finish()]);
}

/**
 * Compiles both shaders and creates every GPU resource, validating each export-reported
 * layout value against the constants this file assumes (guide, section 2).
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

    quadBuffer = device.createBuffer({
        size: quadByteCount,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    instanceBuffer = device.createBuffer({
        size: INSTANCE_CAP * stride,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });

    // Size mirrors `draw.uniform_bytes`: matrix followed by theme.
    uniformBuffer = device.createBuffer({
        size: 256,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });

    const memory = wasm.memory.buffer;
    // The unit quad never changes, so it is uploaded once.
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

    // Explicit layouts are required so both pipelines can bind the same group 0 object.
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
 * Compiles a WGSL module from Wasm memory and throws on any compilation error message.
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
        // `tick` returns 1 only while an animator is live (guide, section 4).
        if (wasm.tick(Math.floor(now)) === 1) {
            schedule();
        }
    });
}

/**
 * Arms the app timer if `wasm.timer_period_ms()` is nonzero (guide, section 4). The interval
 * stays armed for the life of the page.
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
 * Sizes the canvas backing store to physical device pixels and tells Zig the new size.
 */
function fit_canvas() {
    const dpr = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.floor(canvas.clientWidth * dpr));
    const height = Math.max(1, Math.floor(canvas.clientHeight * dpr));
    canvas.width = width;
    canvas.height = height;

    if (wasm.resize(width, height) === 1) {
        schedule();
    }
}

/**
 * Multiplier from CSS pixels to canvas backing-store pixels.
 * @returns {number}
 */
function pointer_scale() {
    return window.devicePixelRatio || 1;
}

/**
 * Forwards `pointermove` in device pixels.
 * @param {PointerEvent} event
 */
function on_pointer_move(event) {
    const scale = pointer_scale();
    if (wasm.pointer_move(event.offsetX * scale, event.offsetY * scale) === 1) {
        schedule();
    }
}

/**
 * Forwards a primary-button press in device pixels and captures the pointer.
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
 * Forwards a primary-button release in device pixels.
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
 * Forwards a wheel event in device pixels. Line-mode deltas are converted to pixels first;
 * the conversion factor is a host heuristic, not a browser-defined value.
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
 * Forwards `pointerleave` and `pointercancel` so Wasm can clear hover and release any press.
 */
function on_pointer_leave() {
    if (wasm.pointer_leave() === 1) {
        schedule();
    }
}

/**
 * Bootstrap order matters: the pipeline is built before `start` so the first `present_js`
 * finds its resources, and `fit_canvas` runs after `start` so layout sees the real size.
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

    const response = await fetch("patchwork.wasm");
    const imported = await WebAssembly.instantiateStreaming(response, {
        env: { present_js },
    });

    wasm = imported.instance.exports;

    await create_pipeline();
    wasm.start();
    fit_canvas();
    arm_timer();

    window.addEventListener("resize", fit_canvas);
    canvas.addEventListener("pointermove", on_pointer_move);
    canvas.addEventListener("pointerdown", on_pointer_down);
    canvas.addEventListener("pointerup", on_pointer_up);
    canvas.addEventListener("pointerleave", on_pointer_leave);
    canvas.addEventListener("pointercancel", on_pointer_leave);
    canvas.addEventListener("wheel", on_wheel, { passive: false });
}

main();

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

const FLAG_INSTANCES = 1;
const FLAG_UNIFORM = 2;
const HEADER_BYTES = 96;
const MATRIX_BYTES = 64;
const INSTANCE_CAP = 256;

function present_js(headerPtr, instancePtr) {
    if (context === null || device === null || pipeline === null) {
        throw new Error("present before the pipeline exists");
    }
    const memory = wasm.memory.buffer;
    const view = new DataView(memory, headerPtr, HEADER_BYTES);
    const width = view.getUint32(0, true);
    const height = view.getUint32(4, true);
    const count = view.getUint32(8, true);
    const flags = view.getUint32(12, true);
    const r = view.getFloat32(16, true);
    const g = view.getFloat32(20, true);
    const b = view.getFloat32(24, true);
    const a = view.getFloat32(28, true);
    if ((flags & FLAG_UNIFORM) !== 0) {
        device.queue.writeBuffer(
            uniformBuffer,
            0,
            new Uint8Array(memory, headerPtr + 32, MATRIX_BYTES),
        );
    }
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
    if (width !== configuredWidth || height !== configuredHeight) {
        context.configure({
            device,
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT,
            alphaMode: "opaque",
            presentMode: "fifo",
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
    pass.end();
    device.queue.submit([encoder.finish()]);
}

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
    quadBuffer = device.createBuffer({
        size: quadByteCount,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });
    instanceBuffer = device.createBuffer({
        size: INSTANCE_CAP * stride,
        usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
    });
    uniformBuffer = device.createBuffer({
        size: 256,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    device.queue.writeBuffer(
        quadBuffer,
        0,
        new Uint8Array(memory, wasm.quad_ptr(), quadByteCount),
    );
    pipeline = device.createRenderPipeline({
        layout: "auto",
        vertex: {
            module,
            entryPoint: "vs_main",
            buffers: [
                {
                    arrayStride: 8,
                    stepMode: "vertex",
                    attributes: [{ shaderLocation: 0, offset: 0, format: "float32x2" }],
                },
                {
                    arrayStride: stride,
                    stepMode: "instance",
                    attributes: [
                        { shaderLocation: 1, offset: 0, format: "float32x4" },
                        { shaderLocation: 2, offset: 16, format: "float32x4" },
                    ],
                },
            ],
        },
        fragment: {
            module,
            entryPoint: "fs_main",
            targets: [{
                format,
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
    bindGroup = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [{
            binding: 0,
            resource: { buffer: uniformBuffer },
        }],
    });
}

function schedule() {
    if (raf !== 0) {
        return;
    }
    raf = requestAnimationFrame(() => {
        raf = 0;
        wasm.tick();
    });
}

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

async function main() {
    if (navigator.gpu === undefined) {
        throw new Error("WebGPU is unavailable in this browser");
    }
    const adapter = await navigator.gpu.requestAdapter();
    if (adapter === null) {
        throw new Error("no WebGPU adapter");
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
    window.addEventListener("resize", fit_canvas);
}

main();

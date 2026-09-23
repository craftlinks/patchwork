const canvas = document.getElementById("surface");

let device = null;
let context = null;
let format = null;
let wasm = null;
let raf = 0;

function present_clear_js(width, height, r, g, b, a) {
    if (context === null || device === null) {
        return;
    }
    context.configure({
        device,
        format,
        usage: GPUTextureUsage.RENDER_ATTACHMENT,
        alphaMode: "opaque",
        presentMode: "fifo",
        width,
        height,
    });
    const encoder = device.createCommandEncoder();
    const view = context.getCurrentTexture().createView();
    const pass = encoder.beginRenderPass({
        colorAttachments: [{
            view,
            loadOp: "clear",
            storeOp: "store",
            clearValue: { r, g, b, a },
        }],
    });
    pass.end();
    device.queue.submit([encoder.finish()]);
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
        env: { present_clear_js },
    });
    wasm = imported.instance.exports;
    wasm.start();
    fit_canvas();
    window.addEventListener("resize", fit_canvas);
}

main();

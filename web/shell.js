// Browser-side WebGPU and WebAssembly host harness.
//
// # Deep Architectural Guide for Reviewers:
//
// ## 1. Role and Zero-Copy Memory Bridge
// This file owns everything the freestanding Wasm module cannot touch: WebGPU device setup,
// DOM events, timers, and animation-frame scheduling. The module exposes its linear memory
// as `wasm.memory.buffer`. Pointers it passes are u32 byte offsets into that buffer.
// JavaScript wraps them in typed views and hands the bytes straight to
// `device.queue.writeBuffer` / `writeTexture`, so no data is serialized.
//
// ## 2. A Generic Command Interpreter
// Zig records every GPU operation into a command stream (`src/gpu/commands.zig`) and calls
// `submit_js(ptr, len)`; `draw/renderer.zig` decides what is recorded. This file knows no
// shader, stride, vertex layout, or pipeline. It reads the op table once from the
// `commands_json_ptr` / `commands_json_len` exports. The table is generated in Zig from the
// payload types and lists each op's code, name, size, and every field's offset and type.
// `decode` reads payloads by that table, so a payload edit in Zig needs no edit here. What
// stays here is the WebGPU vocabulary: the `*_TABLE` objects map Zig enum tag names to
// WebGPU strings and descriptors, and `OPS` maps each op name to the call it makes.
//
// ## 3. Synchronous Call-Stack Longevity
// `submit_js` is invoked from inside Wasm. The stream and every span in it are valid only
// for the duration of the call; linear memory can grow and detach its `ArrayBuffer`, so no
// view is kept after `submit_js` returns.
//
// ## 4. Resource Tables and Errors
// Ids map to WebGPU objects through one array per kind, sized by the table's `caps`.
// Creating an id twice or using an unset id throws with the op name. The setup stream (the
// one `start` submits) runs each op inside `pushErrorScope("validation")`, so a failure names
// the op index and op; `main` awaits those scopes before the first frame. Later errors
// arrive on the device's `uncapturederror` event and are logged with the last frame's ops.
// Loading the page with `?trace=1` logs the op names of every submitted stream.
//
// ## 5. Frame Scheduling
// There is no unconditional `requestAnimationFrame` loop; an idle UI should not burn power.
// - Every Wasm entry point that can dirty the frame returns a flag, and `schedule()` runs
//   only when it is 1.
// - `tick` (the rAF callback) returns 1 only while an animator is live, so the rAF chain
//   ends when the scene settles and is restarted by input or the app timer.
// - `arm_timer` creates one permanent interval only when `wasm.timer_period_ms()` is
//   nonzero. The timer requests a frame when the app reports a change; it never steps
//   animators.
//
// ## 6. Pointer and DPI Handling
// `resize` receives physical canvas pixels (CSS size times `devicePixelRatio`), so pointer
// positions, which the DOM reports in CSS pixels, are multiplied by the same ratio before
// crossing into Wasm. Pointer capture keeps a drag that leaves the canvas deliverable;
// `pointerleave` and `pointercancel` call `wasm.pointer_leave()` so the scene can release
// any press in progress. Wheel deltas in line mode are converted to pixels before scaling.
// `pass_begin` asserts that the recorded size equals the canvas backing size.

const canvas = document.getElementById("surface");
const trace = new URLSearchParams(window.location.search).get("trace") === "1";

let device = null;
let context = null;
let format = null;
let wasm = null;
let raf = 0;
let table = null;
let opsByCode = null;
let resources = null;
// Promises of the per-op error scopes opened while the setup stream runs (guide, section 4).
let setupScopes = null;
let lastTrace = "";

// Interpreter state for the stream being replayed.
let encoder = null;
let pass = null;

/** WebGPU vocabulary for the Zig payload enums, keyed by Zig tag name (guide, section 2). */
const VERTEX_FORMAT_TABLE = { float32x2: "float32x2", float32x4: "float32x4" };
const STEP_MODE_TABLE = { vertex: "vertex", instance: "instance" };
const TEXTURE_FORMAT_TABLE = { r8unorm: "r8unorm" };
const FILTER_TABLE = { nearest: "nearest", linear: "linear" };
const BLEND_TABLE = {
    none: undefined,
    alpha: {
        color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
        alpha: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
    },
};
const LAYOUT_ENTRY_TABLE = {
    uniform: () => ({ buffer: { type: "uniform" } }),
    storage_read: () => ({ buffer: { type: "read-only-storage" } }),
    texture: () => ({ texture: { sampleType: "float" } }),
    sampler: () => ({ sampler: { type: "filtering" } }),
};
const BIND_RESOURCE_TABLE = {
    uniform: (id) => ({ buffer: lookup("buffer", id, "bind_group_create") }),
    storage_read: (id) => ({ buffer: lookup("buffer", id, "bind_group_create") }),
    texture: (id) => lookup("view", id, "bind_group_create"),
    sampler: (id) => lookup("sampler", id, "bind_group_create"),
};

/**
 * Reads one field of the given table type at `offset` (guide, section 2). Scalars are
 * little-endian. A u64 is a zero-extended wasm32 address, so its high word must be zero.
 *
 * @param {DataView} view View over the payload.
 * @param {number} offset Byte offset of the field in `view`.
 * @param {string|object} type Table type: a scalar name, `{enum, int}`, `{array, len,
 *     stride}`, or `{fields}`.
 */
function decode(view, offset, type) {
    if (typeof type === "string") {
        switch (type) {
            case "u8": return view.getUint8(offset);
            case "u16": return view.getUint16(offset, true);
            case "u32": return view.getUint32(offset, true);
            case "f32": return view.getFloat32(offset, true);
            case "u64": {
                if (view.getUint32(offset + 4, true) !== 0) {
                    throw new Error("u64 field has a nonzero high word");
                }
                return view.getUint32(offset, true);
            }
            default: throw new Error(`unknown scalar type ${type}`);
        }
    }
    if (type.enum !== undefined) {
        const value = decode(view, offset, type.int);
        const name = table.enums[type.enum][value];
        if (name === undefined) {
            throw new Error(`${type.enum} has no value ${value}`);
        }
        return name;
    }
    if (type.array !== undefined) {
        const items = [];
        for (let i = 0; i < type.len; i += 1) {
            items.push(decode(view, offset + i * type.stride, type.array));
        }
        return items;
    }
    const value = {};
    for (const field of type.fields) {
        value[field.name] = decode(view, offset + field.offset, field.type);
    }
    return value;
}

/**
 * The bytes a decoded span names. Valid only during the current `submit_js` call.
 * @param {{address: number, len: number}} span
 */
function span_bytes(span) {
    return new Uint8Array(wasm.memory.buffer, span.address, span.len);
}

/** The object stored for `id` of `kind`; throws, naming `op`, when it was never created. */
function lookup(kind, id, op) {
    const object = resources[kind][id];
    if (object === undefined) {
        throw new Error(`${op}: ${kind} id ${id} was never created`);
    }
    return object;
}

/** Stores `object` as `id` of `kind`; throws, naming `op`, on a reused or out-of-range id. */
function store(kind, id, object, op) {
    const slots = resources[kind];
    if (id >= slots.length) {
        throw new Error(`${op}: ${kind} id ${id} is out of range ${slots.length}`);
    }
    if (slots[id] !== undefined) {
        throw new Error(`${op}: ${kind} id ${id} was already created`);
    }
    slots[id] = object;
}

/** The open render pass; throws, naming `op`, when none is open. */
function open_pass(op) {
    if (pass === null) {
        throw new Error(`${op}: no render pass is open`);
    }
    return pass;
}

/** One handler per op name. Each receives the decoded payload and the op index. */
const OPS = {
    shader_create(p, index) {
        const code = new TextDecoder().decode(span_bytes(p.source));
        const module = device.createShaderModule({ code });
        module.getCompilationInfo().then((info) => {
            for (const message of info.messages) {
                if (message.type === "error") {
                    console.error(`op ${index} shader_create ${p.id}: ${message.message}`);
                }
            }
        });
        store("shader", p.id, module, "shader_create");
    },
    layout_create(p) {
        const used = p.entries.slice(0, p.entry_count);
        const entries = used.map((entry) => ({
            binding: entry.binding,
            visibility: entry.visibility,
            ...LAYOUT_ENTRY_TABLE[entry.kind](),
        }));
        // A bind group entry's resource id names a buffer, texture, or sampler according to
        // the layout entry kind at the same binding, so keep the kinds beside the layout.
        const kinds = new Map(used.map((entry) => [entry.binding, entry.kind]));
        store("layout", p.id, { layout: device.createBindGroupLayout({ entries }), kinds }, "layout_create");
    },
    pipeline_create(p) {
        const module = lookup("shader", p.shader, "pipeline_create");
        const bindGroupLayouts = p.layouts.slice(0, p.layout_count)
            .map((id) => lookup("layout", id, "pipeline_create").layout);
        const buffers = p.vertex.slice(0, p.buffer_count).map((buffer) => ({
            arrayStride: buffer.stride,
            stepMode: STEP_MODE_TABLE[buffer.step],
            attributes: buffer.attributes.slice(0, buffer.attribute_count).map((attribute) => ({
                shaderLocation: attribute.location,
                offset: attribute.offset,
                format: VERTEX_FORMAT_TABLE[attribute.format],
            })),
        }));
        const pipeline = device.createRenderPipeline({
            layout: device.createPipelineLayout({ bindGroupLayouts }),
            vertex: { module, entryPoint: table.entry.vertex, buffers },
            fragment: {
                module,
                entryPoint: table.entry.fragment,
                targets: [{ format, blend: BLEND_TABLE[p.blend] }],
            },
            primitive: { topology: "triangle-list" },
        });
        store("pipeline", p.id, pipeline, "pipeline_create");
    },
    buffer_create(p) {
        store("buffer", p.id, device.createBuffer({ size: p.size, usage: p.usage }), "buffer_create");
    },
    texture_create(p) {
        const texture = device.createTexture({
            size: { width: p.width, height: p.height },
            format: TEXTURE_FORMAT_TABLE[p.format],
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        });
        store("texture", p.id, texture, "texture_create");
        store("view", p.id, texture.createView(), "texture_create");
    },
    sampler_create(p) {
        const filter = FILTER_TABLE[p.filter];
        const sampler = device.createSampler({
            addressModeU: "clamp-to-edge",
            addressModeV: "clamp-to-edge",
            magFilter: filter,
            minFilter: filter,
        });
        store("sampler", p.id, sampler, "sampler_create");
    },
    bind_group_create(p) {
        const layout = lookup("layout", p.layout, "bind_group_create");
        const entries = p.entries.slice(0, p.entry_count).map((entry) => {
            const kind = layout.kinds.get(entry.binding);
            if (kind === undefined) {
                throw new Error(`bind_group_create: layout ${p.layout} has no binding ${entry.binding}`);
            }
            return { binding: entry.binding, resource: BIND_RESOURCE_TABLE[kind](entry.resource) };
        });
        const group = device.createBindGroup({ layout: layout.layout, entries });
        store("bind_group", p.id, group, "bind_group_create");
    },
    buffer_write(p) {
        device.queue.writeBuffer(lookup("buffer", p.id, "buffer_write"), p.offset, span_bytes(p.data));
    },
    texture_write(p) {
        device.queue.writeTexture(
            { texture: lookup("texture", p.id, "texture_write"), origin: { x: p.x, y: p.y } },
            span_bytes(p.data),
            { bytesPerRow: p.bytes_per_row, rowsPerImage: p.height },
            { width: p.width, height: p.height },
        );
    },
    pass_begin(p) {
        if (pass !== null) {
            throw new Error("pass_begin: a render pass is already open");
        }
        if (p.width_px !== canvas.width || p.height_px !== canvas.height) {
            throw new Error(
                `pass_begin: frame is ${p.width_px}x${p.height_px} but the canvas is ` +
                `${canvas.width}x${canvas.height}`,
            );
        }
        encoder = device.createCommandEncoder();
        const [r, g, b, a] = p.clear;
        pass = encoder.beginRenderPass({
            colorAttachments: [{
                view: context.getCurrentTexture().createView(),
                loadOp: "clear",
                storeOp: "store",
                clearValue: { r, g, b, a },
            }],
        });
    },
    pipeline_set(p) {
        open_pass("pipeline_set").setPipeline(lookup("pipeline", p.id, "pipeline_set"));
    },
    bind_group_set(p) {
        open_pass("bind_group_set").setBindGroup(p.slot, lookup("bind_group", p.id, "bind_group_set"));
    },
    vertex_buffer_set(p) {
        const buffer = lookup("buffer", p.buffer, "vertex_buffer_set");
        open_pass("vertex_buffer_set").setVertexBuffer(p.slot, buffer, p.offset);
    },
    draw(p) {
        open_pass("draw").draw(p.vertex_count, p.instance_count, p.first_vertex, p.first_instance);
    },
    pass_end_present() {
        open_pass("pass_end_present").end();
        device.queue.submit([encoder.finish()]);
        pass = null;
        encoder = null;
    },
};

/**
 * Host import called synchronously from `gpu.submit` in Zig. Decodes and runs every op of the
 * stream at `ptr` (guide, sections 2 to 4). Must not retain any view after returning.
 *
 * @param {number} ptr Byte offset of the stream in Wasm linear memory, 8-byte aligned.
 * @param {number} len Byte length of the stream, a multiple of 8.
 */
function submit_js(ptr, len) {
    const view = new DataView(wasm.memory.buffer, ptr, len);
    const names = [];
    let offset = 0;
    let index = 0;
    while (offset < len) {
        const code = view.getUint16(offset, true);
        const size = view.getUint16(offset + 2, true);
        const op = opsByCode.get(code);
        if (op === undefined) {
            throw new Error(`command ${index}: unknown op code ${code}`);
        }
        if (size !== op.size) {
            throw new Error(`command ${index}: ${op.name} payload is ${size} bytes, expected ${op.size}`);
        }
        const payload = decode(new DataView(wasm.memory.buffer, ptr + offset + table.header_bytes, size), 0, op.type);
        names.push(op.name);
        if (setupScopes !== null) {
            device.pushErrorScope("validation");
        }
        OPS[op.name](payload, index);
        if (setupScopes !== null) {
            const at = index;
            const name = op.name;
            setupScopes.push(device.popErrorScope().then((error) => {
                if (error !== null) {
                    throw new Error(`setup op ${at} (${name}) failed: ${error.message}`);
                }
            }));
        }
        offset += table.header_bytes + Math.ceil(size / table.align) * table.align;
        index += 1;
    }
    if (pass !== null) {
        throw new Error("stream ended inside a render pass");
    }
    lastTrace = names.join(" ");
    if (trace) {
        console.log(`submit ${index} ops: ${lastTrace}`);
    }
}

/**
 * Reads the op table export and sizes the resource tables from its caps (guide, section 2).
 * Every op in the table must have a handler, and every handler an op.
 */
function load_table() {
    const bytes = new Uint8Array(wasm.memory.buffer, wasm.commands_json_ptr(), wasm.commands_json_len());
    table = JSON.parse(new TextDecoder().decode(bytes));
    opsByCode = new Map(table.ops.map((op) => [op.code, op]));
    for (const op of table.ops) {
        if (OPS[op.name] === undefined) {
            throw new Error(`op table names ${op.name}, which this interpreter does not handle`);
        }
    }
    for (const name of Object.keys(OPS)) {
        if (!table.ops.some((op) => op.name === name)) {
            throw new Error(`interpreter handles ${name}, which the op table does not list`);
        }
    }
    resources = { view: new Array(table.caps.texture).fill(undefined) };
    for (const [kind, cap] of Object.entries(table.caps)) {
        resources[kind] = new Array(cap).fill(undefined);
    }
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
        // `tick` returns 1 only while an animator is live (guide, section 5).
        if (wasm.tick(Math.floor(now)) === 1) {
            schedule();
        }
    });
}

/**
 * Arms the app timer if `wasm.timer_period_ms()` is nonzero (guide, section 5). The interval
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
 * Bootstrap order matters: the device and op table exist before `start`, whose setup stream
 * creates every resource; its error scopes resolve before `fit_canvas` asks for the first
 * frame, so layout sees the real size and a setup failure stops the page.
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
    device.addEventListener("uncapturederror", (event) => {
        console.error(`WebGPU error after ops [${lastTrace}]: ${event.error.message}`);
    });
    context = canvas.getContext("webgpu");
    format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device,
        format,
        usage: GPUTextureUsage.RENDER_ATTACHMENT,
        alphaMode: "opaque",
    });

    const response = await fetch("patchwork.wasm");
    const imported = await WebAssembly.instantiateStreaming(response, {
        env: { submit_js },
    });

    wasm = imported.instance.exports;
    load_table();

    setupScopes = [];
    wasm.start();
    const scopes = setupScopes;
    setupScopes = null;
    await Promise.all(scopes);

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

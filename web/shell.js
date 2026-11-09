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
// the op index and op (with the shader label, the draw type's name, for `shader_create`);
// `main` awaits those scopes before the first frame. Shader modules and their pipelines carry
// the same label, so WGSL compilation messages name the draw type. Later errors
// arrive on the device's `uncapturederror` event and are logged with the last frame's ops.
// Loading the page with `?trace=1` logs the op names of every submitted stream, and one
// "compiled shader" line per shader module with its error and warning counts (the browser has
// no `--check` mode; `getCompilationInfo` reports WGSL problems at creation).
//
// ## 5. Frame Scheduling
// There is no unconditional `requestAnimationFrame` loop; an idle UI should not burn power.
// - Every Wasm entry point that can dirty the frame returns a flag, and `schedule()` runs
//   only when it is 1.
// - `tick` (the rAF callback) returns 1 while an animator is live, an animated draw type is
//   on screen, or a redraw is still owed (the glyph cache finishes skipped glyphs on the next
//   frame), so the rAF chain ends when the scene settles and is restarted by input or the app
//   timer.
// - `sync_timer` keeps one interval of `wasm.timer_period_ms()` set exactly while
//   `wasm.timer_on()` is 1. It runs wherever `sync_cursor` runs, in the interval callback,
//   and after `start`, so an app that stops its timer stops waking the page. The timer
//   requests a frame when the app reports a change; it never steps animators.
//
// ## 6. Pointer and DPI Handling
// CSS pixels are the app's logical pixels. `fit_canvas` passes the canvas's CSS size and
// `round(devicePixelRatio * 120)` to `wasm.resize`, then sizes the backing store from
// `wasm.width_px()` and `wasm.height_px()`: Zig computes the device size (`Frame`), so the
// canvas always matches what `pass_begin` records, which `pass_begin` asserts. Pointer
// positions and wheel deltas cross into Wasm in CSS pixels, unscaled; line-mode wheel deltas
// are converted to pixels first. A `matchMedia` resolution query re-fits the canvas when
// the ratio changes without a window resize (dragging to another monitor). Pointer capture
// keeps a drag that leaves the canvas deliverable; `pointerleave` and `pointercancel` call
// `wasm.pointer_leave()` so the scene can release any press in progress. Every button is
// forwarded with the modifiers and `event.timeStamp` (Zig counts clicks); only the left button
// takes pointer capture, and the context menu is suppressed on the canvas so a right press
// reaches the app.
//
// A finger (`pointerType` "touch") has its own path: `touch-action: none` on the canvas keeps the
// browser from taking the gesture, every finger takes pointer capture (so a finger dragged off
// the canvas keeps its control), and `pointerdown`, `pointermove`, and `pointerup` call
// `wasm.touch_down`, `touch_move`, and `touch_up` with the DOM `pointerId`; `pointercancel` calls
// `touch_cancel(id)`, and `pointerleave` of a finger does nothing because it follows every lift.
// Pens stay on the mouse path. Wasm turns a finger into the pointer events the widgets already
// read (`ui/cx.zig`, section 5b), so one canvas serves a mouse and ten fingers.
//
// ## 7. Keyboard, Clipboard, and Cursor
// This file maps no keys. The canvas is focusable (`tabindex="0"`); `keydown` and `keyup`
// write `event.key` as UTF-8 into the Wasm input buffer and call `key_down` or `key_up`, and
// `preventDefault` only when `key_down` reports the key consumed (bit 1), so Tab can leave a
// canvas with nothing focusable and Ctrl+C, X, and V still raise the page's clipboard events.
// AltGraph is reported without Ctrl and Alt, so AltGr+Q types "@". Composition (IME) is not
// handled. Canvas `focus` and `blur` call `window_focus`. The document's `copy` and `cut`
// events, while the canvas has focus, put the text `copy_take` reports on the clipboard;
// `paste` writes the clipboard text into the input buffer and calls `paste`. After every Wasm
// input call and every tick, `sync_cursor` reads `cursor()` and sets `canvas.style.cursor`
// only when it changed, using the CSS names Wasm exports (`cursor_names_ptr/len`).
//
// ## 7a. File Drops
// A drag that carries files (`dataTransfer.types` includes "Files") over the canvas calls
// `drop_over` with the canvas point on every `dragenter` and `dragover`, which are always
// prevented so the drop is ours; `dropEffect` is "copy" when Wasm reports a drop target under
// the point (bit 1) and "none" otherwise. `dragleave` calls `drop_leave`. On `drop` each item
// of kind "file" is listed with `drop_add` (its name in the input buffer, its size as two
// 32-bit halves, and readable unless `webkitGetAsEntry` says it is a directory), the `File`s are
// kept by index, and `drop` dispatches them; when Wasm reports accepted files (bit 2)
// `pump_files` reads them one slice at a time: `read_next` names a ticket, a file, an offset,
// and a length; the slice's `arrayBuffer()` is written at `chunk_ptr()` (a fresh view after
// the await, since memory may grow) and `read_done` dispatches it. A rejected read or a short
// buffer is reported as failed. `window` prevents `dragover` and `drop` too, so a file dropped
// beside the canvas does not open in the tab.
//
// ## 8. Bench Timestamps
// Loading the page with `?bench=1` requests `timestamp-query` when the adapter offers it and
// times every render pass on the GPU, the browser half of the native `--bench` mode
// (`src/bench.zig`). Readback is asynchronous: each pass resolves its two timestamps into a
// buffer taken from a small pool, and a pass that finds the pool empty is not timed. Every
// `BENCH_WINDOW` timed passes, the console logs p10, p50, and p90 in microseconds, and
// `window.patchworkBench` holds the latest summary. Browsers may quantize timestamps (Chrome
// does unless a flag is set), so native numbers are the reference. Scenarios, phase timers,
// and frame dumps are native only.
//
// ## 8a. Scenario Replay
// Loading the page with `?bench=<scenario>` (any value but `1`) replays one of the app's
// scenarios on the simulated clock of the native `--regress` run (`src/host/web_exports.zig`,
// section 4c), so a screenshot compares with the headless frame pixel for pixel. The canvas
// gets the regress size (`bench_width`, `bench_height`) as both its CSS size and its backing
// size, at scale 1 whatever the device pixel ratio, and the window's resize and ratio changes
// are not watched. Every animation frame is one replay frame; when the last one is presented
// the console logs `bench done <scenario>` (or `bench failed <scenario>` when a step's target
// has no area). While replaying, Wasm ignores input, reports its timer and audio off, and
// renders audio itself, so the page arms no interval and starts no worklet. Without the
// parameter none of this runs.
//
// ## 9. Audio
// An app with an audio source exports `audio_on`'s companions (`src/host/web_exports.zig`,
// section 4b). `sync_audio` runs wherever `sync_timer` runs, so the call that sets audio on is
// inside the input handler and has the page's user activation. The first start creates an
// `AudioContext` at 48 kHz and resumes it at once, then adds `worklet.js`, fetches the wasm's
// bytes, and creates the `patchwork-audio` node, which runs the source from its own instance of
// the wasm and is connected to the speakers. Later changes resume or suspend the context, so a
// stopped app's worklet does not run. Each message from the node is `post_blocks` interleaved
// blocks: `on_audio` copies them into `audio_inbox_ptr()` and calls `audio_push`, and schedules
// a frame when it returns 1; `tick` drains the queue. No `SharedArrayBuffer`, no cross-origin
// isolation.
//
// ## 9a. The App's Web Module
// Before the wasm is instantiated the shell imports `./app.js`, the app's own ES module
// (`AppOptions.web_module`, or Patchwork's empty `web/app.js`). If it exports `imports(shell)`,
// the object it returns joins `env` beside `submit_js`, so the app's wasm may import functions
// of its own; a name Patchwork already provides is an error, shown and thrown. After
// `wasm.start()` the shell calls its `started(shell)`, if exported. `shell` is
// `{ wasm, memory, wake, canvas }`: `wasm` and `memory` are null until the instance exists, so
// an import reads them when it is called, not when it is made; `wake()` schedules one frame,
// whose `tick` calls the app's `drain` (`src/host/web_exports.zig`, section 4b'). A module that
// delivers data from another realm, such as a peer's AudioWorklet, copies it into the wasm
// through the app's own exports and then calls `wake()`. Its own worklet or worker must start
// inside a user gesture: a wasm import called from an input handler has the page's activation.

const canvas = document.getElementById("surface");
const trace = new URLSearchParams(window.location.search).get("trace") === "1";
const benchParameter = new URLSearchParams(window.location.search).get("bench");
const benchRequested = benchParameter === "1";
// The scenario `?bench=<scenario>` replays (guide, section 8a), or null.
const benchScenario = benchParameter !== null && benchParameter !== "1" ? benchParameter : null;
const BENCH_WINDOW = 120;
const BENCH_POOL = 4;

/** Timestamp query state for `?bench=1` (guide, section 8); null when off or unsupported. */
let bench = null;

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
// CSS cursor names by `ui.Cursor` value, read once from Wasm, and the value last applied.
let cursorNames = null;
let cursorShown = -1;
// The app timer's interval id, or 0 while the app's timer is stopped (guide, section 5).
let timerInterval = 0;
// The audio context once audio first started, and whether it was last resumed (section 9).
let audioContext = null;
let audioApplied = false;
// What the app's web module is handed (section 9a).
const shell = { wasm: null, memory: null, wake: () => schedule(), canvas };
// Frames per Web Audio render quantum, and interleaved samples per block.
const BLOCK_SAMPLES = 128 * 2;
const textEncoder = new TextEncoder();
/** The `File`s of the last drop, by the index Wasm lists them under (guide, section 7a). */
let droppedFiles = [];
/** True while `pump_files` is reading. */
let pumping = false;
const textDecoder = new TextDecoder();

// Interpreter state for the stream being replayed.
let encoder = null;
let pass = null;

/** WebGPU vocabulary for the Zig payload enums, keyed by Zig tag name (guide, section 2). */
const VERTEX_FORMAT_TABLE = {
    float32: "float32",
    float32x2: "float32x2",
    float32x3: "float32x3",
    float32x4: "float32x4",
};
const STEP_MODE_TABLE = { vertex: "vertex", instance: "instance" };
const TEXTURE_FORMAT_TABLE = {
    r8unorm: "r8unorm",
    rgba8unorm: "rgba8unorm",
    r16float: "r16float",
    rg16float: "rg16float",
    r32float: "r32float",
    rg32float: "rg32float",
};
const FILTER_TABLE = { nearest: "nearest", linear: "linear" };
const ADDRESS_TABLE = { clamp: "clamp-to-edge", repeat: "repeat" };
const LOAD_OP_TABLE = { clear: "clear", load: "load" };
// The factors are documented on `commands.Blend`; additive and multiply keep the target alpha.
const KEEP_ALPHA = { srcFactor: "zero", dstFactor: "one", operation: "add" };
const BLEND_TABLE = {
    none: undefined,
    alpha: {
        color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
        alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
    },
    additive: {
        color: { srcFactor: "src-alpha", dstFactor: "one", operation: "add" },
        alpha: KEEP_ALPHA,
    },
    multiply: {
        color: { srcFactor: "dst", dstFactor: "zero", operation: "add" },
        alpha: KEEP_ALPHA,
    },
    premultiplied: {
        color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
        alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
    },
};
const LAYOUT_ENTRY_TABLE = {
    uniform: () => ({ buffer: { type: "uniform" } }),
    storage_read: () => ({ buffer: { type: "read-only-storage" } }),
    texture: () => ({ texture: { sampleType: "float" } }),
    sampler: () => ({ sampler: { type: "filtering" } }),
    texture_unfilterable: () => ({ texture: { sampleType: "unfilterable-float" } }),
    sampler_non_filtering: () => ({ sampler: { type: "non-filtering" } }),
};
const BIND_RESOURCE_TABLE = {
    uniform: (id) => ({ buffer: lookup("buffer", id, "bind_group_create") }),
    storage_read: (id) => ({ buffer: lookup("buffer", id, "bind_group_create") }),
    texture: (id) => lookup("view", id, "bind_group_create"),
    sampler: (id) => lookup("sampler", id, "bind_group_create"),
    texture_unfilterable: (id) => lookup("view", id, "bind_group_create"),
    sampler_non_filtering: (id) => lookup("sampler", id, "bind_group_create"),
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
        const label = new TextDecoder().decode(span_bytes(p.label));
        const module = device.createShaderModule({ label, code });
        module.getCompilationInfo().then((info) => {
            const counts = { error: 0, warning: 0, info: 0 };
            for (const message of info.messages) {
                counts[message.type] += 1;
                const where = `${p.id} (${label} line ${message.lineNum}:${message.linePos})`;
                if (message.type === "error") {
                    console.error(`op ${index} shader_create ${where}: ${message.message}`);
                } else if (trace) {
                    console.log(`op ${index} shader_create ${where} ${message.type}: ${message.message}`);
                }
            }
            // With `?trace=1`, one line per module: the browser's answer to `zig build check`.
            if (trace) {
                const summary = `${counts.error} errors, ${counts.warning} warnings`;
                console.log(`compiled shader ${p.id} (${label}): ${summary}`);
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
        // The module label (the draw type's name) also names the pipeline in error messages.
        const pipeline = device.createRenderPipeline({
            label: module.label,
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
            addressModeU: ADDRESS_TABLE[p.address_u],
            addressModeV: ADDRESS_TABLE[p.address_v],
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
        // `replace` swaps the group an offscreen target's resize made stale.
        if (p.replace === 1) {
            lookup("bind_group", p.id, "bind_group_create");
            resources.bind_group[p.id] = undefined;
        }
        store("bind_group", p.id, group, "bind_group_create");
    },
    buffer_write(p) {
        device.queue.writeBuffer(lookup("buffer", p.id, "buffer_write"), p.offset, span_bytes(p.data));
    },
    texture_write(p) {
        // The span starts at the region's first texel and rows are `bytes_per_row` apart, so
        // a sub-rectangle of a larger image (the glyph atlas mirror) uploads in place.
        device.queue.writeTexture(
            { texture: lookup("texture", p.id, "texture_write"), origin: { x: p.x, y: p.y } },
            span_bytes(p.data),
            { offset: 0, bytesPerRow: p.bytes_per_row, rowsPerImage: p.height },
            { width: p.width, height: p.height },
        );
    },
    pass_begin(p) {
        if (pass !== null) {
            throw new Error("pass_begin: a render pass is already open");
        }
        let view;
        if (p.target === table.surface_target) {
            if (p.width_px !== canvas.width || p.height_px !== canvas.height) {
                throw new Error(
                    `pass_begin: frame is ${p.width_px}x${p.height_px} but the canvas is ` +
                    `${canvas.width}x${canvas.height}`,
                );
            }
            view = context.getCurrentTexture().createView();
        } else {
            const target = lookup("texture", p.target, "pass_begin");
            if (p.width_px !== target.width || p.height_px !== target.height) {
                throw new Error(`pass_begin: target ${p.target} is ${target.width}x` +
                    `${target.height}, the pass ${p.width_px}x${p.height_px}`);
            }
            view = lookup("view", p.target, "pass_begin");
        }
        if (encoder === null) encoder = device.createCommandEncoder();
        const [r, g, b, a] = p.clear;
        const descriptor = {
            colorAttachments: [{
                view,
                loadOp: LOAD_OP_TABLE[p.load],
                storeOp: "store",
                clearValue: { r, g, b, a },
            }],
        };
        if (bench !== null) {
            descriptor.timestampWrites = {
                querySet: bench.querySet,
                beginningOfPassWriteIndex: 0,
                endOfPassWriteIndex: 1,
            };
        }
        pass = encoder.beginRenderPass(descriptor);
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
        pass = null;
        submit_frame();
    },
    target_create(p) {
        // The one create that may repeat an id: a new size replaces the target.
        const old = resources.texture[p.id];
        if (old !== undefined) {
            old.destroy();
            resources.texture[p.id] = undefined;
            resources.view[p.id] = undefined;
        }
        const texture = device.createTexture({
            size: { width: p.width, height: p.height },
            format,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC |
                GPUTextureUsage.TEXTURE_BINDING,
        });
        store("texture", p.id, texture, "target_create");
        store("view", p.id, texture.createView(), "target_create");
    },
    scissor_set(p) {
        open_pass("scissor_set").setScissorRect(p.x, p.y, p.width, p.height);
    },
    pass_end() {
        open_pass("pass_end").end();
        pass = null;
    },
    present_copy(p) {
        if (pass !== null) {
            throw new Error("present_copy: a render pass is still open");
        }
        const source = lookup("texture", p.target, "present_copy");
        if (source.width !== canvas.width || source.height !== canvas.height) {
            throw new Error(`present_copy: target is ${source.width}x${source.height} but ` +
                `the canvas is ${canvas.width}x${canvas.height}`);
        }
        if (encoder === null) encoder = device.createCommandEncoder();
        encoder.copyTextureToTexture(
            { texture: source },
            { texture: context.getCurrentTexture() },
            [source.width, source.height],
        );
        submit_frame();
    },
};

/** Submits the frame's encoder, with the bench timestamps when they are on. */
function submit_frame() {
    const readback = bench_resolve(encoder);
    device.queue.submit([encoder.finish()]);
    if (readback !== null) bench_read(readback);
    encoder = null;
}

/**
 * Creates the query set, the resolve buffer, and the readback pool (guide, section 8).
 */
function bench_create() {
    const readback = () => device.createBuffer({
        size: 16,
        usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
    });
    bench = {
        querySet: device.createQuerySet({ type: "timestamp", count: 2 }),
        resolve: device.createBuffer({
            size: 16,
            usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC,
        }),
        free: Array.from({ length: BENCH_POOL }, readback),
        samples: [],
    };
}

/**
 * Resolves this pass's timestamps into a free readback buffer, or returns null when bench
 * mode is off or the pool is empty.
 */
function bench_resolve(frameEncoder) {
    if (bench === null || bench.free.length === 0) return null;
    const readback = bench.free.pop();
    frameEncoder.resolveQuerySet(bench.querySet, 0, 2, bench.resolve, 0);
    frameEncoder.copyBufferToBuffer(bench.resolve, 0, readback, 0, 16);
    return readback;
}

/** Reads a resolved pass time once the GPU is done, then returns the buffer to the pool. */
function bench_read(readback) {
    readback.mapAsync(GPUMapMode.READ).then(() => {
        const [begin, end] = new BigUint64Array(readback.getMappedRange());
        readback.unmap();
        bench.free.push(readback);
        if (end <= begin) return;
        bench.samples.push(Number(end - begin) / 1000);
        if (bench.samples.length < BENCH_WINDOW) return;
        const sorted = bench.samples.sort((x, y) => x - y);
        const at = (q) => sorted[Math.floor((sorted.length - 1) * q)];
        window.patchworkBench = { passes: sorted.length, p10: at(0.1), p50: at(0.5), p90: at(0.9) };
        const { p10, p50, p90 } = window.patchworkBench;
        console.log(`bench: gpu pass p10 ${p10.toFixed(1)} p50 ${p50.toFixed(1)} ` +
            `p90 ${p90.toFixed(1)} us over ${sorted.length} passes`);
        bench.samples = [];
    });
}

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
        // A shader's label (its draw type) is read now, while its span is valid.
        const name = payload.label === undefined
            ? op.name
            : `${op.name} ${new TextDecoder().decode(span_bytes(payload.label))}`;
        names.push(name);
        if (setupScopes !== null) {
            device.pushErrorScope("validation");
        }
        OPS[op.name](payload, index);
        if (setupScopes !== null) {
            const at = index;
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
 * Logs the draw's overflow report once per change, in builds with runtime safety (the wasm
 * returns 0 otherwise): instances, areas, and glyphs refused for lack of room, and icons whose
 * face does not map their codepoint (the last as `face << 21 | codepoint`).
 */
function log_overflow() {
    const at = wasm.overflow_take();
    if (at === 0) {
        return;
    }
    const counts = new Uint32Array(wasm.memory.buffer, at, 5);
    if (counts[0] + counts[1] + counts[2] > 0) {
        console.warn(`overflow: ${counts[0]} instances, ${counts[1]} areas, ${counts[2]} ` +
            "glyphs refused this frame (raise App.config caps)");
    }
    if (counts[3] > 0) {
        const codepoint = (counts[4] & 0x1FFFFF).toString(16).toUpperCase().padStart(4, "0");
        console.warn(`icons: ${counts[3]} drawn this frame are not in their face ` +
            `(last U+${codepoint} in face ${counts[4] >>> 21})`);
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
        // `tick` returns 1 while an animator is live or a frame is owed (guide, section 5); a
        // replay returns 2 after its last frame and 3 when it failed (section 8a).
        const live = wasm.tick(Math.floor(now));
        if (live === 2) {
            console.log(`bench done ${benchScenario}`);
        } else if (live === 3) {
            console.error(`bench failed ${benchScenario}`);
        }
        log_overflow();
        sync_cursor();
        sync_timer();
        sync_audio();
        if (live === 1) {
            schedule();
        }
    });
}

/**
 * Sets the app timer's interval while `wasm.timer_on()` is 1 and clears it otherwise (guide,
 * section 5). `setInterval` never returns 0, so 0 means no interval.
 */
function sync_timer() {
    const on = wasm.timer_on() === 1;
    if (on && timerInterval === 0) {
        timerInterval = setInterval(on_timer, wasm.timer_period_ms());
    } else if (!on && timerInterval !== 0) {
        clearInterval(timerInterval);
        timerInterval = 0;
    }
}

/**
 * The interval callback: runs the app's timer, schedules a frame when it owes one, and
 * applies a start or stop the timer made.
 */
function on_timer() {
    const now = Math.floor(performance.now());
    if (wasm.timer(now) === 1) {
        schedule();
    }
    sync_timer();
    sync_audio();
}

/**
 * Resumes the audio context while `wasm.audio_on()` is 1 and suspends it otherwise, creating it
 * at the first start (guide, section 9).
 */
function sync_audio() {
    const on = wasm.audio_on() === 1;
    if (on === audioApplied) {
        return;
    }
    audioApplied = on;
    if (audioContext === null) {
        start_audio();
        return;
    }
    if (on) {
        audioContext.resume();
    } else {
        audioContext.suspend();
    }
}

/**
 * Creates the context and resumes it inside the user's gesture, then loads the worklet and the
 * wasm bytes and connects the node.
 */
function start_audio() {
    audioContext = new AudioContext({ sampleRate: 48000, latencyHint: "interactive" });
    audioContext.resume();
    const context = audioContext;
    const loaded = Promise.all([
        context.audioWorklet.addModule("worklet.js"),
        fetch("patchwork.wasm").then((response) => response.arrayBuffer()),
    ]);
    loaded.then(([, bytes]) => {
        const node = new AudioWorkletNode(context, "patchwork-audio", {
            numberOfInputs: 0,
            numberOfOutputs: 1,
            outputChannelCount: [2],
            processorOptions: { wasm: bytes },
        });
        node.port.onmessage = on_audio;
        node.connect(context.destination);
    }).catch((error) => {
        console.error(`audio: ${error.message}`);
    });
}

/**
 * Copies one posted run of blocks into the wasm inbox and pushes them into the queue.
 * @param {MessageEvent} event Its data is a Float32Array of interleaved blocks.
 */
function on_audio(event) {
    const samples = event.data;
    const blocks = samples.length / BLOCK_SAMPLES;
    new Float32Array(wasm.memory.buffer, wasm.audio_inbox_ptr(), samples.length).set(samples);
    if (wasm.audio_push(blocks) === 1) {
        schedule();
    }
}

/**
 * Tells Zig the canvas's CSS size and device pixel ratio, then sizes the backing store to the
 * device size Zig derived (guide, section 6). Assigning `canvas.width` clears the canvas, so
 * it is assigned only when the size changed.
 */
function fit_canvas() {
    const width = Math.max(1, canvas.clientWidth);
    const height = Math.max(1, canvas.clientHeight);
    const scale_120 = Math.max(1, Math.round((window.devicePixelRatio || 1) * 120));
    const dirty = wasm.resize(width, height, scale_120);
    const width_px = wasm.width_px();
    const height_px = wasm.height_px();
    if (canvas.width !== width_px) {
        canvas.width = width_px;
    }
    if (canvas.height !== height_px) {
        canvas.height = height_px;
    }
    if (dirty === 1) {
        schedule();
    }
}

/**
 * Starts the `?bench=<scenario>` replay (guide, section 8a): the canvas at the regress size in
 * CSS and device pixels, then the first frame.
 */
function start_replay() {
    const width = wasm.bench_width();
    const height = wasm.bench_height();
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    canvas.width = width;
    canvas.height = height;
    if (wasm.bench_start(write_input(benchScenario)) !== 1) {
        console.error(`bench: no scenario "${benchScenario}"`);
        return;
    }
    schedule();
}

/**
 * Re-fits the canvas when the device pixel ratio changes. A resolution query matches only
 * the ratio it was made for, so each change re-arms a query for the new ratio.
 */
function watch_ratio() {
    const query = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
    query.addEventListener("change", () => {
        fit_canvas();
        watch_ratio();
    }, { once: true });
}

/**
 * Schedules a frame when a Wasm input call reports one owed (bit 0), then syncs the cursor.
 * @param {number} result The call's return value.
 */
function after_input(result) {
    if ((result & 1) === 1) {
        schedule();
    }
    sync_cursor();
    sync_timer();
    sync_audio();
}

/**
 * Sets `canvas.style.cursor` when the cursor Wasm reports changed (guide, section 7).
 */
function sync_cursor() {
    const value = wasm.cursor();
    if (value === cursorShown) {
        return;
    }
    cursorShown = value;
    canvas.style.cursor = cursorNames[value];
}

/**
 * The `input.Mods` byte: shift 1, ctrl 2, alt 4, meta 8. AltGraph clears Ctrl and Alt.
 * @param {KeyboardEvent|PointerEvent|MouseEvent} event
 */
function mods_of(event) {
    const altGraph = event.getModifierState !== undefined && event.getModifierState("AltGraph");
    const ctrl = event.ctrlKey && !altGraph;
    const alt = event.altKey && !altGraph;
    return (event.shiftKey ? 1 : 0) | (ctrl ? 2 : 0) | (alt ? 4 : 0) | (event.metaKey ? 8 : 0);
}

/**
 * Writes `text` as UTF-8 into the Wasm input buffer and returns the byte count. `encodeInto`
 * never splits a codepoint, so a long paste is cut on a boundary.
 * @param {string} text
 */
function write_input(text) {
    const view = new Uint8Array(wasm.memory.buffer, wasm.input_ptr(), wasm.input_cap());
    return textEncoder.encodeInto(text, view).written;
}

/**
 * Forwards `pointermove` in CSS (logical) pixels.
 * @param {PointerEvent} event
 */
function on_pointer_move(event) {
    if (event.pointerType === "touch") {
        const time = Math.floor(event.timeStamp) >>> 0;
        after_input(wasm.touch_move(event.pointerId, event.offsetX, event.offsetY, time));
        return;
    }
    after_input(wasm.pointer_move(event.offsetX, event.offsetY));
}

/**
 * Forwards a press of any button in CSS pixels; a left press captures the pointer.
 * @param {PointerEvent} event
 */
function on_pointer_down(event) {
    const time = Math.floor(event.timeStamp) >>> 0;
    if (event.pointerType === "touch") {
        canvas.setPointerCapture(event.pointerId);
        after_input(wasm.touch_down(event.pointerId, event.offsetX, event.offsetY, time));
        return;
    }
    if (event.button === 0) {
        canvas.setPointerCapture(event.pointerId);
    }
    const x = event.offsetX;
    const y = event.offsetY;
    after_input(wasm.pointer_down(x, y, event.button, mods_of(event), time));
}

/**
 * Forwards a release of any button in CSS pixels.
 * @param {PointerEvent} event
 */
function on_pointer_up(event) {
    const time = Math.floor(event.timeStamp) >>> 0;
    if (event.pointerType === "touch") {
        after_input(wasm.touch_up(event.pointerId, time));
        return;
    }
    const x = event.offsetX;
    const y = event.offsetY;
    after_input(wasm.pointer_up(x, y, event.button, mods_of(event), time));
}

/**
 * Forwards a wheel event in CSS pixels. Line-mode deltas are converted to pixels first; the
 * conversion factor is a host heuristic, not a browser-defined value.
 * @param {WheelEvent} event
 */
function on_wheel(event) {
    event.preventDefault();
    let dx = event.deltaX;
    let dy = event.deltaY;
    if (event.deltaMode === 1) {
        dx *= 16;
        dy *= 16;
    }
    after_input(wasm.pointer_wheel(event.offsetX, event.offsetY, dx, dy));
}

/**
 * Forwards `pointerleave` so Wasm can clear hover and release any press.
 * @param {PointerEvent} event
 */
function on_pointer_leave(event) {
    // A finger's leave follows its lift (or its cancel, which has its own handler).
    if (event.pointerType === "touch") return;
    after_input(wasm.pointer_leave());
}

/**
 * Forwards `pointercancel`: a finger the browser took ends without a click; anything else
 * releases the pointer as a leave does.
 * @param {PointerEvent} event
 */
function on_pointer_cancel(event) {
    if (event.pointerType === "touch") {
        after_input(wasm.touch_cancel(event.pointerId));
        return;
    }
    after_input(wasm.pointer_leave());
}

/**
 * Forwards a key press by name; prevents the browser default only when Wasm consumed it.
 * @param {KeyboardEvent} event
 */
function on_key_down(event) {
    if (event.isComposing || event.key === "Process") {
        return;
    }
    const length = write_input(event.key);
    const result = wasm.key_down(length, mods_of(event), event.repeat ? 1 : 0);
    if ((result & 2) === 2) {
        event.preventDefault();
    }
    after_input(result);
}

/**
 * Forwards a key release by name.
 * @param {KeyboardEvent} event
 */
function on_key_up(event) {
    if (event.isComposing) {
        return;
    }
    const length = write_input(event.key);
    after_input(wasm.key_up(length, mods_of(event)));
}

/**
 * Puts the text the last key press copied on the clipboard (`copy` and `cut` events).
 * @param {ClipboardEvent} event
 */
function on_copy(event) {
    if (document.activeElement !== canvas) {
        return;
    }
    const length = wasm.copy_take();
    if (length === 0) {
        return;
    }
    const bytes = new Uint8Array(wasm.memory.buffer, wasm.copy_ptr(), length);
    event.clipboardData.setData("text/plain", textDecoder.decode(bytes));
    event.preventDefault();
}

/**
 * Hands the clipboard text to Wasm as a paste.
 * @param {ClipboardEvent} event
 */
function on_paste(event) {
    if (document.activeElement !== canvas) {
        return;
    }
    const text = event.clipboardData.getData("text/plain");
    event.preventDefault();
    after_input(wasm.paste(write_input(text)));
}

/**
 * True for a drag that carries files.
 * @param {DragEvent} event
 */
function carries_files(event) {
    return event.dataTransfer !== null && Array.from(event.dataTransfer.types).includes("Files");
}

/**
 * Reports a file drag over the canvas and sets the drop effect from Wasm's answer.
 * @param {DragEvent} event
 */
function on_drag_over(event) {
    if (!carries_files(event)) {
        return;
    }
    event.preventDefault();
    const result = wasm.drop_over(event.offsetX, event.offsetY);
    event.dataTransfer.dropEffect = (result & 2) === 2 ? "copy" : "none";
    after_input(result);
}

/**
 * Reports that the file drag left the canvas.
 * @param {DragEvent} event
 */
function on_drag_leave(event) {
    if (!carries_files(event)) {
        return;
    }
    after_input(wasm.drop_leave());
}

/**
 * Lists the dropped files in Wasm, dispatches the drop, and reads what the app accepted.
 * @param {DragEvent} event
 */
function on_drop(event) {
    if (!carries_files(event)) {
        return;
    }
    event.preventDefault();
    droppedFiles = [];
    wasm.drop_reset();
    for (const item of Array.from(event.dataTransfer.items)) {
        if (item.kind !== "file") {
            continue;
        }
        const file = item.getAsFile();
        if (file === null) {
            continue;
        }
        const entry = item.webkitGetAsEntry !== undefined ? item.webkitGetAsEntry() : null;
        const readable = entry !== null && entry.isDirectory ? 0 : 1;
        const size = readable === 1 ? file.size : 0;
        const length = write_input(file.name);
        if (wasm.drop_add(length, size >>> 0, Math.floor(size / 4294967296), readable) === 1) {
            droppedFiles.push(file);
        }
    }
    const result = wasm.drop(event.offsetX, event.offsetY);
    after_input(result);
    if ((result & 4) === 4) {
        pump_files();
    }
}

/**
 * Reads the accepted files one slice at a time into Wasm (guide, section 7a).
 */
async function pump_files() {
    if (pumping) {
        return;
    }
    pumping = true;
    for (;;) {
        const ticket = wasm.read_next();
        after_input(1);
        if (ticket === 0) {
            break;
        }
        const file = droppedFiles[wasm.read_file()];
        const offset = wasm.read_offset_hi() * 4294967296 + wasm.read_offset_lo();
        const length = wasm.read_len();
        let bytes = null;
        try {
            bytes = new Uint8Array(await file.slice(offset, offset + length).arrayBuffer());
        } catch (error) {
            console.warn("file read failed:", file.name, error);
        }
        if (bytes === null || bytes.length !== length) {
            after_input(wasm.read_done(ticket, 0, 1));
            continue;
        }
        new Uint8Array(wasm.memory.buffer, wasm.chunk_ptr(), length).set(bytes);
        after_input(wasm.read_done(ticket, length, 0));
    }
    pumping = false;
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

    const timestamps = benchRequested && adapter.features.has("timestamp-query");
    device = await adapter.requestDevice(
        timestamps ? { requiredFeatures: ["timestamp-query"] } : {},
    );
    if (timestamps) {
        bench_create();
    } else if (benchRequested) {
        console.warn("bench: this adapter has no timestamp-query feature");
    }
    device.addEventListener("uncapturederror", (event) => {
        console.error(`WebGPU error after ops [${lastTrace}]: ${event.error.message}`);
    });
    context = canvas.getContext("webgpu");
    format = navigator.gpu.getPreferredCanvasFormat();
    context.configure({
        device,
        format,
        // COPY_DST: a cached frame copies the kept render target onto the canvas.
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_DST,
        alphaMode: "opaque",
    });

    const app = await import("./app.js");
    const env = { submit_js };
    if (typeof app.imports === "function") {
        for (const [name, value] of Object.entries(app.imports(shell))) {
            if (name in env) {
                const message = `app.js: the import ${name} is Patchwork's own`;
                console.error(message);
                throw new Error(message);
            }
            env[name] = value;
        }
    }
    const response = await fetch("patchwork.wasm");
    const imported = await WebAssembly.instantiateStreaming(response, { env });

    wasm = imported.instance.exports;
    shell.wasm = wasm;
    shell.memory = wasm.memory;
    load_table();
    const names = new Uint8Array(
        wasm.memory.buffer,
        wasm.cursor_names_ptr(),
        wasm.cursor_names_len(),
    );
    cursorNames = JSON.parse(textDecoder.decode(names));

    setupScopes = [];
    wasm.start();
    const scopes = setupScopes;
    setupScopes = null;
    await Promise.all(scopes);
    if (typeof app.started === "function") {
        app.started(shell);
    }

    if (benchScenario !== null) {
        start_replay();
    } else {
        fit_canvas();
        window.addEventListener("resize", fit_canvas);
        watch_ratio();
    }
    sync_timer();
    sync_audio();

    canvas.addEventListener("pointermove", on_pointer_move);
    canvas.addEventListener("pointerdown", on_pointer_down);
    canvas.addEventListener("pointerup", on_pointer_up);
    canvas.addEventListener("pointerleave", on_pointer_leave);
    canvas.addEventListener("pointercancel", on_pointer_cancel);
    canvas.addEventListener("wheel", on_wheel, { passive: false });
    canvas.addEventListener("contextmenu", (event) => event.preventDefault());
    canvas.addEventListener("keydown", on_key_down);
    canvas.addEventListener("keyup", on_key_up);
    canvas.addEventListener("focus", () => after_input(wasm.window_focus(1)));
    canvas.addEventListener("blur", () => after_input(wasm.window_focus(0)));
    document.addEventListener("copy", on_copy);
    document.addEventListener("cut", on_copy);
    document.addEventListener("paste", on_paste);
    canvas.addEventListener("dragenter", on_drag_over);
    canvas.addEventListener("dragover", on_drag_over);
    canvas.addEventListener("dragleave", on_drag_leave);
    canvas.addEventListener("drop", on_drop);
    // A file dropped beside the canvas must not open in the tab (guide, section 7a).
    window.addEventListener("dragover", (event) => {
        event.preventDefault();
        if (event.target !== canvas && event.dataTransfer !== null) {
            event.dataTransfer.dropEffect = "none";
        }
    });
    window.addEventListener("drop", (event) => event.preventDefault());
    sync_cursor();
}

main();

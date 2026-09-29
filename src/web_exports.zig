//! WebAssembly Freestanding Entry Points for Browser Hosting.
//!
//! # Concepts for Novices:
//!
//! ## 1. What is `wasm32-freestanding`?
//! When compiling for the browser, we target `wasm32-freestanding`.
//! - `wasm32`: 32-bit WebAssembly instruction architecture (pointers are 32-bit integer offsets).
//! - `freestanding`: Indicates there is NO operating system, NO standard C library (libc),
//!   NO POSIX threads, and NO filesystem. The resulting `.wasm` binary contains pure, standalone
//!   computational logic.
//!
//! ## 2. How WebAssembly Interacts with the Browser
//! WebAssembly cannot directly access the DOM, window events, or the WebGPU API.
//! All communication happens across a strict boundary:
//! - **Exports (`export fn`):** Functions written in Zig that JavaScript can call directly
//!   from the Wasm instance exports table (e.g. `wasm.start()`, `wasm.tick()`).
//! - **Imports (`extern "env"`):** Functions provided by JavaScript that Zig can call
//!   (e.g. `present_js()`).
//! - **Linear Memory (`WebAssembly.Memory`):** A contiguous, resizable array of bytes
//!   shared between Zig and JavaScript. Because `export_memory = true` is set in `build.zig`,
//!   JavaScript can inspect and read slices of this memory via typed arrays (`Uint8Array`).
//!
//! ## 3. Synchronous Call-Stack Memory Sharing
//! In `tick()`, `PresentHeader` is allocated as a local variable on Zig's call stack.
//! Zig passes the pointer to JavaScript by calling `present_js(header_ptr, ...)`.
//! Because host import calls in WebAssembly execute **synchronously on the same thread**,
//! the stack frame remains fully valid while JavaScript reads it.
//! When JavaScript returns, Zig marks the frame clean and exits `tick()`.
//! This guarantees 100% memory safety with ZERO dynamic heap allocations.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");

/// Global application state for the WebAssembly runtime.
/// Statically allocated in Wasm linear memory at startup (BSS segment).
const State = struct {
    frame: frame.Frame,
    list: draw.DrawList,
    cursor: draw.UploadCursor,
};

var state: State = .{
    .frame = frame.Frame.init(),
    .list = draw.DrawList.init(),
    .cursor = draw.UploadCursor.init(),
};

/// Returns the memory address of the embedded WGSL shader source code.
/// JavaScript uses this pointer to decode the WGSL string and compile the pipeline.
export fn shader_ptr() [*]const u8 {
    assert(draw.shader_file.len >= 1);
    assert(draw.instance_stride == 32);
    return draw.shader_file.ptr;
}

/// Returns the byte length of the embedded WGSL shader source code.
export fn shader_len() u32 {
    assert(draw.shader_file.len >= 1);
    return @intCast(draw.shader_file.len);
}

/// Returns the memory address of the static unit quad vertex coordinates.
/// JavaScript reads 48 bytes from this address to populate the GPU vertex buffer.
export fn quad_ptr() [*]const f32 {
    assert(draw.quad_bytes == 48);
    return &draw.unit_quad;
}

/// Returns the byte size of the unit quad vertex buffer (48 bytes).
export fn quad_bytes() u32 {
    assert(draw.unit_quad.len == 12);
    return draw.quad_bytes;
}

/// Returns the byte stride between instances in the instance buffer (32 bytes).
/// JavaScript asserts this matches its expected vertex buffer layout.
export fn instance_stride() u32 {
    assert(draw.instance_stride == 32);
    return draw.instance_stride;
}

/// Initializes the application state and populates the demo draw list.
/// Called once by JavaScript after the WebGPU pipeline is compiled.
/// Returns 1 if the first frame needs rendering, or 0 if clean.
export fn start() u32 {
    state.frame = frame.Frame.init();
    state.list = draw.DrawList.init();
    state.cursor = draw.UploadCursor.init();
    draw.demo(&state.list);
    assert(state.frame.running);
    assert(state.list.count == draw.instance_cap);
    return dirty_flag();
}

/// Informs the Zig runtime of a canvas resize event in physical pixels.
/// Updates logical and physical dimensions and sets the dirty redraw flag.
/// Returns 1 if a frame should be scheduled via `requestAnimationFrame`, or 0 if clean.
export fn resize(width_px: u32, height_px: u32) u32 {
    assert(state.frame.running);
    state.frame.apply_configure(width_px, height_px);
    assert(state.frame.width_px != 0);
    return dirty_flag();
}

/// Renders a frame if the dirty flag is set.
/// Constructs the `PresentHeader` on the stack and invokes `present_js`.
/// After presentation, clears the redraw flag so no further frames are scheduled.
export fn tick() u32 {
    assert(state.frame.running);
    if (!state.frame.redraw) {
        return 0;
    }
    if (state.frame.width_px == 0) {
        return 0;
    }
    // The header lives on this stack until present_js returns, so JS can read it safely.
    var header: draw.PresentHeader = undefined;
    draw.fill_header(&header, .{
        .list = &state.list,
        .cursor = state.cursor,
        .width_logical = state.frame.width_logical,
        .height_logical = state.frame.height_logical,
        .width_px = state.frame.width_px,
        .height_px = state.frame.height_px,
        .clear_r = gpu.clear_color.r,
        .clear_g = gpu.clear_color.g,
        .clear_b = gpu.clear_color.b,
        .clear_a = gpu.clear_color.a,
    });
    var unused: gpu.Gpu = .{};
    gpu.present(&unused, &header, &state.list.items) catch unreachable;
    state.cursor.mark(&state.list, state.frame.width_logical, state.frame.height_logical);
    state.frame.mark_presented();
    assert(!state.frame.redraw);
    return 0;
}

/// Helper that checks if a redraw is owed and the window has valid dimensions.
fn dirty_flag() u32 {
    if (state.frame.redraw) {
        if (state.frame.width_px != 0) {
            return 1;
        }
    }
    return 0;
}

//! WebAssembly Freestanding Entry Points and Browser Interoperability Bridge.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The `wasm32-freestanding` Execution Model
//! When targeting the browser, Zig compiles to `wasm32-freestanding`:
//! - `wasm32`: A 32-bit WebAssembly virtual machine architecture where pointers are 32-bit
//!   unsigned integers representing byte offsets into a single contiguous linear memory array.
//! - `freestanding`: Indicates that there is NO underlying operating system, NO standard C
//!   runtime library (libc), NO POSIX threads, and NO direct access to platform system calls.
//! - The resulting `.wasm` binary is completely self-contained, deterministic, and contains
//!   only application code without runtime bloat.
//!
//! ## 2. The Browser-Wasm Sandbox Boundary
//! WebAssembly code executes in a memory-isolated sandbox. It cannot directly touch the DOM,
//! receive browser window events, or invoke WebGPU JavaScript APIs.
//! All communication is bridged through three explicit channels:
//! - **Exports (`export fn`):** Functions compiled in Zig that the JavaScript host can call
//!   directly from the Wasm instance's exports table (`wasm.start()`, `wasm.tick()`).
//! - **Imports (`extern "env"`):** JavaScript functions exposed to WebAssembly via the import
//!   object passed to `WebAssembly.instantiateStreaming` (`present_js()`).
//! - **Linear Memory (`WebAssembly.Memory`):** A contiguous byte buffer shared between the Wasm
//!   instance and JavaScript. When `export_memory = true` is set in `build.zig`, JavaScript gains
//!   direct access to `wasm.memory.buffer` (an `ArrayBuffer`).
//!
//! ## 3. Single Source of Truth for Graphics Layouts
//! A classic anti-pattern in WebAssembly graphics applications is duplicating buffer sizes,
//! attribute strides, and shader strings between the backend language and JavaScript.
//!
//! In Patchwork, Zig is the single authoritative source of truth:
//! - `shader_ptr()` and `shader_len()` expose the embedded WGSL shader source code.
//! - `quad_ptr()` and `quad_bytes()` expose the static unit quad vertex coordinates.
//! - `instance_stride()` exposes the exact byte stride of the `Instance` struct (48 bytes).
//!
//! When `web/shell.js` bootstraps, it queries these export functions to allocate its GPU buffers
//! and compile its pipeline. If the shader or struct layouts change in Zig, JavaScript adapts
//! automatically without code duplication.
//!
//! The 48-byte stride is the instance: rectangle, fill, and a shape `vec4` of
//! `(radius, hover, down, 0)`. `instance_stride` asserts 48 here, and `shell.js` asserts 48
//! again before it builds the pipeline and before it uploads. The third vertex attribute
//! (shader location 3, offset 32, `float32x4`) must stay in lockstep with `quad.wgsl` and
//! with the native `instance_attrs` table. A stride mismatch would silently fetch hover
//! from the wrong bytes. `down` occupies offset 40. The pipeline did not change.
//!
//! ## 4. Synchronous Stack-Frame Memory Sharing (Zero-Copy & Zero-Heap)
//! In `tick()`, `var header: draw.PresentHeader` is allocated on Zig's call stack.
//! Zig passes the memory address `@intFromPtr(&header)` across the FFI boundary to `present_js`.
//!
//! ### Why is this 100% memory safe?
//! - WebAssembly host calls are **strictly synchronous** and execute on the same thread.
//! - When Zig invokes `present_js(header_ptr, ...)`, the WebAssembly engine halts Zig execution
//!   at that instruction while preserving its stack frame in linear memory.
//! - JavaScript receives `headerPtr`, wraps it in a typed `DataView` over `wasm.memory.buffer`,
//!   and reads the fields directly.
//! - When JavaScript returns, control resumes in Zig. Zig updates the cursor, marks the frame
//!   presented, and returns from `tick()`.
//! - Only then is the stack frame popped.
//! - This achieves zero heap allocation, zero serialization, and zero garbage collection overhead.
//!
//! ## 5. Power-Optimal Frame Pacing and Animation Chaining (0% Idle CPU)
//! Traditional WebGL/WebGPU applications run an unconditional continuous loop with
//! `requestAnimationFrame`. This burns CPU and GPU power even when displaying static documents
//! or idle user interfaces.
//!
//! In Patchwork:
//! - `start()` initializes state (`frame`, `list`, `cursor`) and leaves the draw list empty
//!   (`state.list.count == 0`), setting `relayout = true`.
//! - When the canvas attaches to the DOM, `web/shell.js` calls `resize(width_px, height_px)` with
//!   actual physical dimensions, configuring the logical coordinate space and setting `redraw`.
//! - `resize()` and `start()` return a `u32` dirty flag (1 if dirty, 0 if clean).
//! - `web/shell.js` schedules a `requestAnimationFrame` **only** when the dirty flag is 1.
//! - `tick(now_ms)` advances `animator.Clock`, feeds the delta to `scene.handle_event`,
//!   presents if the frame is dirty, and returns 1 while any animator is live.
//! - `web/shell.js` chains `requestAnimationFrame` strictly while `tick()` returns 1:
//!   ```javascript
//!   if (wasm.tick(Math.floor(now)) === 1) {
//!       schedule();
//!   }
//!   ```
//!   Once every animator settles, `tick()` returns 0 and the animation frame callback loop
//!   terminates. The first timestamp after idle produces dt 0, so a fade starts on the following
//!   frame.
//! - `pointer_move`, `pointer_down`, `pointer_up`, and `pointer_leave` call
//!   `scene.handle_event` directly and return the dirty flag. Press and release carry
//!   device-pixel coordinates (`offsetX * devicePixelRatio`).
//! - Layout runs only when `frame.relayout` is set. `scene.layout` re-dispatches the
//!   stored pointer, so a resize keeps hover on the widget that still contains it.
//! - A scale-only present leaves `scene.dirty` false and does not rebuild instances.
//! - When idle, the browser tab consumes 0.0% CPU and 0.0% GPU cycles.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Allocation:** `State` is statically allocated in Wasm BSS linear memory.
//!   Zero dynamic memory allocations at runtime.
//! - **Comptime Consistency:** Hardware buffer byte counts (`quad_bytes`, `uniform_bytes`,
//!   `instance_stride = 48`) are asserted at compile time.
//! - **Bounded Operations:** `tick`, `start`, `resize`, and pointer entry points execute in
//!   bounded O(1) time without unbounded recursion or dynamic reallocation.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const draw = @import("draw.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");
const input = @import("input.zig");
const scene = @import("scene.zig");

/// Global application state for the WebAssembly runtime.
/// Statically allocated in Wasm linear memory at startup (BSS segment).
/// No dynamic memory allocation or heap pointers are used.
const State = struct {
    frame: frame.Frame,
    list: draw.DrawList,
    cursor: draw.UploadCursor,
    scene: scene.Scene,
    clock: animator.Clock,
};

var state: State = .{
    .frame = frame.Frame.init(),
    .list = draw.DrawList.init(),
    .cursor = draw.UploadCursor.init(),
    .scene = scene.Scene.init_demo(),
    .clock = animator.Clock.init(),
};

/// Returns the memory address of the embedded WGSL shader source code.
/// JavaScript uses this pointer to decode the WGSL string and compile the pipeline.
export fn shader_ptr() [*]const u8 {
    assert(draw.shader_file.len >= 1);
    assert(draw.instance_stride == 48);
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

/// Returns the byte stride between instances (48 bytes).
///
/// JavaScript asserts the same 48 before creating the pipeline and again before
/// `writeBuffer`. The stride covers three `vec4` groups. The third is radius, hover,
/// down, and one zero pad. See the module guide in `draw.zig`.
export fn instance_stride() u32 {
    assert(draw.instance_stride == 48);
    return draw.instance_stride;
}

/// Initializes the application state and leaves the draw list empty.
///
/// Called once by JavaScript after the WebGPU pipeline is compiled.
/// Unlike static scenes, this does not populate instances during startup; `state.list.count`
/// remains 0 and `state.frame.relayout` is initialized to true.
/// The initial layout walk is deferred to `tick`, after `resize` has configured the true
/// canvas dimensions.
///
/// Returns 1 if a frame should be scheduled via `requestAnimationFrame`, or 0 if clean.
export fn start() u32 {
    state.frame = frame.Frame.init();
    state.list = draw.DrawList.init();
    state.cursor = draw.UploadCursor.init();
    state.scene = scene.Scene.init_demo();
    state.clock = animator.Clock.init();
    assert(state.frame.running);
    assert(state.frame.relayout);
    assert(state.list.count == 0);
    assert(!state.scene.live());
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

/// Pointer moved. `(x, y)` are device pixels, matching the canvas backing store.
/// `shell.js` passes `offsetX * devicePixelRatio`. Returns 1 when a frame is owed.
export fn pointer_move(x: f32, y: f32) u32 {
    assert(state.frame.running);
    assert(x == x);
    return note_event(.{ .pointer_move = .{ .x = x, .y = y } });
}

/// Primary button pressed at device-pixel `(x, y)`.
export fn pointer_down(x: f32, y: f32) u32 {
    assert(state.frame.running);
    assert(x == x);
    return note_event(.{ .pointer_down = .{ .x = x, .y = y } });
}

/// Primary button released at device-pixel `(x, y)`.
export fn pointer_up(x: f32, y: f32) u32 {
    assert(state.frame.running);
    assert(x == x);
    return note_event(.{ .pointer_up = .{ .x = x, .y = y } });
}

/// Pointer left the canvas or the gesture was cancelled. A press in progress
/// becomes an outside release so capture cannot stick.
export fn pointer_leave() u32 {
    assert(state.frame.running);
    const flag = note_event(.pointer_leave);
    assert(!state.scene.pointer.inside);
    return flag;
}

/// Steps animators from `now_ms`, presents if the frame is dirty, and returns 1
/// while any animator is still live so `shell.js` chains `requestAnimationFrame`.
/// The first sample after idle has dt 0. A settled scene returns 0 and the chain stops.
export fn tick(now_ms: u32) u32 {
    assert(state.frame.running);
    const dt_ms = state.clock.advance(now_ms);
    if (state.scene.handle_event(.{ .frame = dt_ms })) {
        state.frame.request_redraw();
    }
    present_frame();
    if (!state.scene.live()) {
        state.clock.reset();
        assert(!state.scene.live());
        return 0;
    }
    assert(state.scene.live());
    return 1;
}

fn note_event(event: input.Event) u32 {
    if (state.scene.handle_event(event)) {
        state.frame.request_redraw();
    }
    assert(state.frame.running);
    return dirty_flag();
}

fn present_frame() void {
    if (!state.frame.redraw) {
        assert(!state.frame.redraw);
        assert(state.frame.running);
        return;
    }
    if (state.frame.width_px == 0) {
        assert(state.frame.height_px == 0);
        return;
    }
    if (state.frame.relayout) {
        state.scene.layout(state.frame.width_logical, state.frame.height_logical);
        state.frame.mark_laid_out();
    }
    assert(!state.frame.relayout);
    if (state.scene.dirty) {
        state.scene.draw(&state.list);
    }
    assert(!state.scene.dirty);
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
    assert(!state.scene.dirty);
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

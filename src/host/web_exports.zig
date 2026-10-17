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
//! - **Exports (`@export`):** Functions exported dynamically via `export_app(App)` using `@export`
//!   so JavaScript can call them from the Wasm exports table (`wasm.start()`, `wasm.tick()`,
//!   `wasm.timer()`, etc.).
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
//! - `shader_ptr()` and `shader_len()` expose the embedded `quad.wgsl` source code.
//! - `glyph_shader_ptr()` and `glyph_shader_len()` expose the embedded `glyph.wgsl` source code.
//! - `quad_ptr()` and `quad_bytes()` expose the static unit quad vertex coordinates.
//! - `instance_stride()` exposes the exact byte stride of the `Instance` struct (64 bytes).
//! - `glyph_stride()` exposes the byte stride of the `Glyph` struct (64 bytes).
//! - `theme_ptr()` and `theme_len()` expose the 192-byte `Theme` uniform tail.
//! - `pointer_wheel()` forwards DOM wheel deltas in logical pixels to the event queue.
//! - `atlas_ptr()` and `atlas_len()` expose the pre-baked 131,072-byte `r8unorm` font atlas buffer.
//! - `atlas_width()` (512) and `atlas_height()` (256) expose atlas dimensions.
//!
//! When `web/shell.js` bootstraps, it queries these export functions to allocate its GPU buffers,
//! compile both fixed-function pipelines, and upload the atlas texture. If the shaders or struct
//! layouts change in Zig, JavaScript adapts automatically without code duplication.
//!
//! The 64-byte stride is the instance: rectangle, fill, shape `vec4` (radius, hover, down, kind),
//! and clip bounds `(clip_x0, clip_y0, clip_x1, clip_y1)`. `instance_stride` asserts 64 here,
//! and `shell.js` asserts 64 again before it builds the pipeline and before it uploads.
//! Vertex attribute location 4 at offset 48 carries the clip bounds.
//! Similarly, `glyph_stride` asserts 64 bytes for `(dest_rect, uv_rect, color, clip)`.
//!
//! ## 4. Synchronous Stack-Frame Memory Sharing (Zero-Copy & Zero-Heap)
//! In `present_frame()`, `var header: draw.PresentHeader` is allocated on Zig's call stack.
//! Zig passes three linear memory pointers across the FFI boundary:
//! `present_js(header_ptr, instance_ptr, glyph_ptr)`.
//!
//! ### Why is this 100% memory safe?
//! - WebAssembly host calls are **strictly synchronous** and execute on the same thread.
//! - When Zig invokes `present_js(header_ptr, instance_ptr, glyph_ptr)`, the WebAssembly engine
//!   halts Zig execution at that instruction while preserving its stack frame in linear memory.
//! - JavaScript receives `headerPtr`, wraps it in a typed `DataView` over `wasm.memory.buffer`,
//!   and reads the 104-byte header directly (dimensions, flags, clear, matrix, glyph count).
//! - If `flags & flag_instances` is set and `count > 0`, JavaScript uploads `count * 64` bytes
//!   directly from `instance_ptr`.
//! - If `flags & flag_glyphs` is set and `glyph_count > 0`, JavaScript uploads `glyph_count * 64`
//!   bytes directly from `glyph_ptr`.
//! - When JavaScript returns, control resumes in Zig. Zig marks the cursor and updates the frame.
//! - Only then is the stack frame popped.
//! - This achieves zero heap allocation, zero serialization, and zero garbage collection overhead.
//!
//! ## 5. Frame Pacing: Optional App Timer, `tick`, and Animation Chaining
//! Traditional WebGL/WebGPU applications run an unconditional continuous loop with
//! `requestAnimationFrame`. This burns CPU and GPU power even when displaying static documents
//! or idle user interfaces.
//!
//! In Patchwork:
//! - `start()` initializes state (`frame`, `list`, `glyphs`, `cursor`, `clock`) and leaves
//!   the draw list empty (`state.list.count == 0`), setting `relayout = true`.
//! - When the canvas attaches to the DOM, `web/shell.js` calls `resize(width_px, height_px)` with
//!   actual physical dimensions, configuring the logical coordinate space and setting `redraw`.
//! - `resize()` and `start()` return a `u32` dirty flag (1 if dirty, 0 if clean).
//! - `web/shell.js` schedules a `requestAnimationFrame` **only** when the dirty flag is 1.
//!
//! ### `timer(now_ms)` vs `tick(now_ms)`:
//! - **`timer_period_ms()` and `timer(now_ms)` (Optional App Timer):**
//!   `web/shell.js` invokes `arm_timer()`, querying `wasm.timer_period_ms()`. When the period is 0
//!   (such as in the scroll column example), no interval is created and the page idles between
//!   events. When non-zero (such as 33 ms in the rack example), `arm_timer` sets a permanent
//!   `setInterval`. On every interval tick, it invokes `wasm.timer(Math.floor(performance.now()))`.
//!   `timer` calls `app.timer(now_ms)`. If any dynamic value changes, it calls
//!   `state.frame.request_redraw()` and returns 1. If it returns 1, `shell.js` calls `schedule()`
//!   to request one `requestAnimationFrame`. Crucially, `timer` does NOT advance widget animators
//!   and does not chain rAF.
//! - **`tick(now_ms)` (Animator Step & Presentation):**
//!   When rAF runs, it calls `wasm.tick(Math.floor(now))`. `tick` advances `animator.Clock`,
//!   feeds the delta to `app.event(.{ .frame = dt_ms })`, presents if dirty, and returns 1
//!   **only** while an interactive animator is still moving (`app.live()`):
//!   ```javascript
//!   if (wasm.tick(Math.floor(now)) === 1) {
//!       schedule();
//!   }
//!   ```
//! - **Why rAF Stops When Animators Settle:**
//!   Once hover and press transitions settle, `tick()` returns 0 and the animation frame
//!   callback loop terminates. A resting pointer does not chain continuous rAF frames. Instead,
//!   subsequent frame renders are triggered on demand by user input or by `wasm.timer()` when an
//!   app timer is active.
//! - **Zero Workers and No Shared Memory:**
//!   This host-driven timing requires no background Web Workers, no `SharedArrayBuffer`, and no
//!   cross-origin isolation headers (`COOP`/`COEP`); `serve.zig` is unchanged.
//! - `pointer_move`, `pointer_down`, `pointer_up`, `pointer_wheel`, and `pointer_leave` call
//!   `app.event(...)` directly and return the dirty flag. Press and release carry
//!   device-pixel coordinates (`offsetX * devicePixelRatio`).
//! - Layout runs only when `frame.relayout` is set. `app.layout` recalculates widget geometry,
//!   so a resize keeps hover on the widget that still contains it.
//! - A scale-only present leaves `app.dirty()` false and does not rebuild instances.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Allocation:** `State` is statically allocated in Wasm BSS linear memory.
//!   Zero dynamic memory allocations at runtime.
//! - **Comptime Consistency:** Hardware buffer byte counts (`quad_bytes`, `uniform_bytes`,
//!   `instance_stride = 64`) are asserted at compile time.
//! - **Bounded Operations:** `tick`, `start`, `resize`, and pointer entry points execute in
//!   bounded O(1) time without unbounded recursion or dynamic reallocation.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const app_contract = @import("../app.zig");
const draw = @import("../draw.zig");
const font = @import("../font.zig");
const frame = @import("../frame.zig");
const gpu = @import("../gpu.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");

/// Returns the memory address of the embedded WGSL shader source code.
/// JavaScript uses this pointer to decode the WGSL string and compile the pipeline.
fn shader_ptr() callconv(.c) [*]const u8 {
    assert(draw.shader_file.len >= 1);
    assert(draw.instance_stride == 64);
    return draw.shader_file.ptr;
}

/// Returns the byte length of the embedded WGSL shader source code.
fn shader_len() callconv(.c) u32 {
    assert(draw.shader_file.len >= 1);
    return @intCast(draw.shader_file.len);
}

/// Returns the memory address of the static unit quad vertex coordinates.
/// JavaScript reads 48 bytes from this address to populate the GPU vertex buffer.
fn quad_ptr() callconv(.c) [*]const f32 {
    assert(draw.quad_bytes == 48);
    return &draw.unit_quad;
}

/// Returns the byte size of the unit quad vertex buffer (48 bytes).
fn quad_bytes() callconv(.c) u32 {
    assert(draw.unit_quad.len == 12);
    return draw.quad_bytes;
}

/// Returns the byte stride between instances (64 bytes).
///
/// JavaScript asserts the same 64 before creating the pipeline and again before
/// `writeBuffer`. Four `vec4` attributes: rect, fill, shape, and clip.
fn instance_stride() callconv(.c) u32 {
    assert(draw.instance_stride == 64);
    return draw.instance_stride;
}

/// Glyph shader source. `shell.js` compiles this as the second module.
fn glyph_shader_ptr() callconv(.c) [*]const u8 {
    assert(font.shader_file.len >= 1);
    assert(font.glyph_stride == 64);
    return font.shader_file.ptr;
}

/// Returns the byte length of the embedded `src/glyph.wgsl` shader source.
fn glyph_shader_len() callconv(.c) u32 {
    assert(font.shader_file.len >= 1);
    return @intCast(font.shader_file.len);
}

/// Byte stride of one glyph quad (64 bytes). The browser asserts 64 before upload.
fn glyph_stride() callconv(.c) u32 {
    assert(font.glyph_stride == 64);
    return font.glyph_stride;
}

/// Address of the 192-byte theme. `shell.js` writes it at uniform offset 64.
fn theme_ptr() callconv(.c) [*]const u8 {
    assert(@sizeOf(theme.Theme) == 192);
    return @ptrCast(&theme.chrome);
}

/// Byte length of the theme uniform tail.
fn theme_len() callconv(.c) u32 {
    assert(theme.bytes == 192);
    return theme.bytes;
}

/// Returns the memory address of the pre-baked 512 x 256 `r8unorm` font coverage atlas.
/// JavaScript reads 131,072 bytes from this pointer to upload the WebGPU texture once at startup.
fn atlas_ptr() callconv(.c) [*]const u8 {
    assert(font.atlas_bytes.len == 131072);
    return font.atlas_bytes.ptr;
}

/// Returns the exact byte size of the font coverage atlas (131,072 bytes).
fn atlas_len() callconv(.c) u32 {
    assert(font.atlas_bytes.len == 131072);
    return 131072;
}

/// Returns the horizontal pixel width of the font coverage atlas (512 texels).
fn atlas_width() callconv(.c) u32 {
    assert(font.atlas_width == 512);
    return font.atlas_width;
}

/// Returns the vertical pixel height of the font coverage atlas (256 texels).
fn atlas_height() callconv(.c) u32 {
    assert(font.atlas_height == 256);
    return font.atlas_height;
}

/// Exports the whole browser surface for one app type. Called once, in a `comptime` block,
/// from `src/host/web_main.zig`. `export fn` cannot live inside a generic struct, so every
/// symbol goes through `@export`. `rdynamic` in `build.zig` keeps them in the module and
/// `web/shell.js` looks each one up by the names below.
pub fn export_app(comptime App: type) void {
    comptime app_contract.check(App);
    const Web = WebApp(App);
    @export(&shader_ptr, .{ .name = "shader_ptr" });
    @export(&shader_len, .{ .name = "shader_len" });
    @export(&quad_ptr, .{ .name = "quad_ptr" });
    @export(&quad_bytes, .{ .name = "quad_bytes" });
    @export(&instance_stride, .{ .name = "instance_stride" });
    @export(&glyph_shader_ptr, .{ .name = "glyph_shader_ptr" });
    @export(&glyph_shader_len, .{ .name = "glyph_shader_len" });
    @export(&glyph_stride, .{ .name = "glyph_stride" });
    @export(&theme_ptr, .{ .name = "theme_ptr" });
    @export(&theme_len, .{ .name = "theme_len" });
    @export(&atlas_ptr, .{ .name = "atlas_ptr" });
    @export(&atlas_len, .{ .name = "atlas_len" });
    @export(&atlas_width, .{ .name = "atlas_width" });
    @export(&atlas_height, .{ .name = "atlas_height" });
    @export(&Web.start, .{ .name = "start" });
    @export(&Web.resize, .{ .name = "resize" });
    @export(&Web.pointer_move, .{ .name = "pointer_move" });
    @export(&Web.pointer_down, .{ .name = "pointer_down" });
    @export(&Web.pointer_up, .{ .name = "pointer_up" });
    @export(&Web.pointer_wheel, .{ .name = "pointer_wheel" });
    @export(&Web.pointer_leave, .{ .name = "pointer_leave" });
    @export(&Web.timer_period_ms, .{ .name = "timer_period_ms" });
    @export(&Web.timer, .{ .name = "timer" });
    @export(&Web.tick, .{ .name = "tick" });
}

/// The app-facing half of the browser host. `state` and `app` are statically allocated in
/// Wasm linear memory (BSS). There is no dynamic allocation.
fn WebApp(comptime App: type) type {
    return struct {
        const State = struct {
            frame: frame.Frame,
            list: draw.DrawList,
            glyphs: font.GlyphList,
            cursor: draw.UploadCursor,
            clock: animator.Clock,
        };

        var state: State = .{
            .frame = frame.Frame.init(),
            .list = draw.DrawList.init(),
            .glyphs = font.GlyphList.init(),
            .cursor = draw.UploadCursor.init(),
            .clock = animator.Clock.init(),
        };

        var app: App = undefined;

        /// Initializes the application state and leaves the draw list empty.
        ///
        /// Called once by JavaScript after the WebGPU pipeline is compiled.
        /// This does not populate instances during startup; `state.list.count` remains 0
        /// and `state.frame.relayout` is initialized to true. The initial layout walk is
        /// deferred to `tick`, after `resize` has configured the true canvas dimensions.
        ///
        /// Returns 1 if a frame should be scheduled via `requestAnimationFrame`, or 0 if clean.
        fn start() callconv(.c) u32 {
            state.frame = frame.Frame.init();
            state.list = draw.DrawList.init();
            state.glyphs = font.GlyphList.init();
            state.cursor = draw.UploadCursor.init();
            state.clock = animator.Clock.init();
            App.init(&app);
            assert(state.frame.running);
            assert(state.frame.relayout);
            assert(state.list.count == 0);
            assert(!app.live());
            return dirty_flag();
        }

        /// Informs the Zig runtime of a canvas resize event in physical pixels.
        /// Updates logical and physical dimensions and sets the dirty redraw flag.
        /// Returns 1 if a frame should be scheduled via `requestAnimationFrame`, or 0 if clean.
        fn resize(width_px: u32, height_px: u32) callconv(.c) u32 {
            assert(state.frame.running);
            state.frame.apply_configure(width_px, height_px);
            assert(state.frame.width_px != 0);
            return dirty_flag();
        }

        /// Pointer moved. `(x, y)` are device pixels, matching the canvas backing store.
        /// `shell.js` passes `offsetX * devicePixelRatio`. Returns 1 when a frame is owed.
        fn pointer_move(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_move = .{ .x = x, .y = y } });
        }

        /// Primary button pressed at device-pixel `(x, y)`.
        fn pointer_down(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_down = .{ .x = x, .y = y } });
        }

        /// Primary button released at device-pixel `(x, y)`.
        fn pointer_up(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_up = .{ .x = x, .y = y } });
        }

        /// Wheel at device-pixel `(x, y)`. `dy` is in the same pixel unit as the pointer.
        /// Positive `dy` scrolls the column downward.
        fn pointer_wheel(x: f32, y: f32, dy: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            assert(dy == dy);
            return note_event(.{ .wheel = .{ .x = x, .y = y, .dy = dy } });
        }

        /// Pointer left the canvas or the gesture was cancelled. A press in progress
        /// becomes an outside release so capture cannot stick.
        fn pointer_leave() callconv(.c) u32 {
            assert(state.frame.running);
            return note_event(.pointer_leave);
        }

        /// Host timer period in milliseconds. 0 means the app has no timer, and `shell.js`
        /// arms no `setInterval`.
        fn timer_period_ms() callconv(.c) u32 {
            assert(App.config.timer_period_ms <= app_contract.timer_period_ms_max);
            return App.config.timer_period_ms;
        }

        /// Calls the app's `timer`. Returns 1 when a frame is owed. Does not step
        /// animators. The interval in `shell.js` requests the next frame.
        fn timer(now_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(App.config.timer_period_ms != 0);
            if (app.timer(now_ms)) {
                state.frame.request_redraw();
            }
            assert(state.frame.running);
            return dirty_flag();
        }

        /// Steps animators from `now_ms`, presents if the frame is dirty, and returns 1
        /// while any animator is still live so `shell.js` chains `requestAnimationFrame`.
        /// The first sample after idle has dt 0. A settled app returns 0 and the chain stops.
        fn tick(now_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            const dt_ms = state.clock.advance(now_ms);
            if (app.event(.{ .frame = dt_ms })) {
                state.frame.request_redraw();
            }
            present_frame();
            if (!app.live()) {
                state.clock.reset();
                assert(!app.live());
                return 0;
            }
            assert(app.live());
            return 1;
        }

        fn note_event(event: input.Event) u32 {
            if (app.event(event)) {
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
                app.layout(state.frame.width_logical, state.frame.height_logical);
                state.frame.mark_laid_out();
            }
            assert(!state.frame.relayout);
            if (app.dirty()) {
                app.draw(&state.list, &state.glyphs);
            }
            assert(!app.dirty());
            // The header lives on this stack until present_js returns, so JS can read it safely.
            var header: draw.PresentHeader = undefined;
            draw.fill_header(&header, .{
                .list = &state.list,
                .glyphs = &state.glyphs,
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
            gpu.present(&unused, &header, &state.list.items, &state.glyphs.items) catch unreachable;
            state.cursor.mark(
                &state.list,
                &state.glyphs,
                state.frame.width_logical,
                state.frame.height_logical,
            );
            state.frame.mark_presented();
            assert(!state.frame.redraw);
            assert(!app.dirty());
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
    };
}

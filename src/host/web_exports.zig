//! WebAssembly Freestanding Entry Points and Browser Interoperability Bridge.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Sandbox Boundary and Zero-Copy Memory Sharing
//! A `wasm32-freestanding` module has no OS, libc, or threads and cannot touch the DOM or
//! WebGPU. All communication with `web/shell.js` crosses three channels:
//! - **Exports:** `export_app` publishes every symbol through `@export`; `rdynamic` in
//!   `build.zig` keeps them in the module and `shell.js` looks each one up by name.
//! - **Imports:** `submit_js` is the only host import (see `gpu.submit`).
//! - **Linear memory:** Pointers are `u32` byte offsets into `wasm.memory.buffer`. JavaScript
//!   builds typed views over them, so no data is serialized or copied on the Zig side.
//!
//! ## 2. Zig as the Single Source of Truth for Graphics
//! `shell.js` contains no WGSL, vertex layouts, strides, or pipeline literals. It learns
//! everything from two sources: the op table `commands_json_ptr` / `commands_json_len` export
//! once (`commands.table_json`, generated at compile time from the payload types), and the
//! command streams Zig submits. The setup stream, recorded by `draw/renderer.zig` in `start`,
//! carries the shader text, the static unit quad, the atlas, and every layout as spans and
//! descriptors; JavaScript only maps op fields onto WebGPU calls.
//!
//! ## 3. Synchronous Stack-Frame Memory Sharing
//! `gpu.submit` passes the stream's offset and length to `submit_js`. Spans inside it point
//! at the static draw context (its pools and queued texture bytes), the renderer's uniform
//! record, the app's own static storage, and static data. This is
//! memory safe because host calls are synchronous on one thread: the engine suspends Zig
//! inside the call and JavaScript must finish reading before control returns. JavaScript must
//! not retain the stream, any span, or any view over them after `submit_js` returns.
//!
//! ## 4. Frame Pacing: Dirty Flags, Optional Timer, and rAF Chaining
//! The browser host does not run an unconditional `requestAnimationFrame` loop, because that
//! burns power while the UI is idle.
//! - `start`, `resize`, and every `pointer_*` export return a `u32` dirty flag: 1 when a
//!   frame is owed (`dirty_flag`), 0 otherwise. `shell.js` schedules one rAF only on 1.
//! - `timer_period_ms` of 0 means the app has no timer and `shell.js` arms no interval.
//!   Otherwise `timer` runs the app's timer, requests a redraw if it reports a change, and
//!   never steps animators or chains rAF.
//! - `tick` is the rAF callback: it advances `animator.Clock`, forwards the delta as
//!   `.frame`, presents if dirty, and returns 1 only while `app.live()`. Returning 0 ends
//!   the rAF chain, and `clock.reset` makes the next sample after idle report a zero delta.
//! - `start` submits the setup stream, then leaves the draw pools empty and `relayout` set;
//!   the first layout walk happens in `present_frame` after `resize` has supplied real canvas
//!   dimensions.
//! - Pointer coordinates are device pixels (canvas backing store), the same unit `resize`
//!   receives, so layout and hit testing share one frame of reference.
//! - Timing is host-driven: no Web Workers, no `SharedArrayBuffer`, and no cross-origin
//!   isolation headers are required.
//!
//! ## 5. TigerStyle Invariants
//! - `state`, the draw context, the renderer, and the app are static globals declared
//!   `undefined`, so they occupy BSS rather than data: the module does not carry their bytes,
//!   and the linker sizes the initial memory to cover them. `start` initializes each in
//!   place. There is no runtime allocation.
//! - Payload layouts shared with the browser are described by `commands.table_json`, which
//!   is generated from the Zig types, so there is no hand-mirrored layout to check.
//! - Every export runs in bounded time with no recursion.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const app_contract = @import("../app.zig");
const commands = @import("../gpu/commands.zig");
const frame = @import("../frame.zig");
const gpu = @import("../gpu.zig");
const input = @import("../input.zig");
const renderer = @import("../draw/renderer.zig");

/// Linear-memory address of the op table (`commands.table_json`), UTF-8 JSON.
fn commands_json_ptr() callconv(.c) [*]const u8 {
    assert(commands.table_json.len >= 1);
    return commands.table_json.ptr;
}

/// Byte length of the op table.
fn commands_json_len() callconv(.c) u32 {
    assert(commands.table_json.len >= 1);
    return @intCast(commands.table_json.len);
}

/// Exports the whole browser surface for one app type. Called once, in a `comptime` block,
/// from `src/host/web_main.zig`. `export fn` cannot live inside a generic struct, so every
/// symbol goes through `@export`; the names are the contract with `web/shell.js`.
pub fn export_app(comptime App: type) void {
    comptime app_contract.check(App);
    const Web = WebApp(App);
    @export(&commands_json_ptr, .{ .name = "commands_json_ptr" });
    @export(&commands_json_len, .{ .name = "commands_json_len" });
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

/// The app-facing half of the browser host. `state` and `app` are static (BSS) storage.
fn WebApp(comptime App: type) type {
    return struct {
        const Context = app_contract.Context(App);
        const Renderer = renderer.Renderer(Context);

        const State = struct {
            frame: frame.Frame,
            commands: commands.CommandBuffer,
            clock: animator.Clock,
        };

        // Module guide, section 5: `undefined` keeps these in BSS; `start` initializes them.
        var state: State = undefined;
        var context: Context = undefined;
        var render: Renderer = undefined;
        var app: App = undefined;

        /// Initializes host state, the draw context, the renderer, and the app, then submits
        /// the setup stream. Called once by JavaScript after the device exists. The app runs
        /// first, as on native, so the textures it creates are in the setup stream and its
        /// per-op validation scopes. The pools stay empty and `relayout` stays set because the
        /// first layout needs the canvas size that only `resize` supplies. Returns the dirty
        /// flag (see `dirty_flag`).
        fn start() callconv(.c) u32 {
            state.frame = frame.Frame.init();
            state.clock = animator.Clock.init();
            state.commands.len = 0;
            state.commands.count = 0;
            context.init();
            render.init();
            App.init(&app, &context.textures);
            render.setup(&state.commands, &context);
            var unused: gpu.Gpu = .{};
            gpu.submit(&unused, &state.commands) catch unreachable;
            assert(state.frame.running);
            assert(state.frame.relayout);
            assert(context.batch_count == 0);
            assert(!app.live());
            return dirty_flag();
        }

        /// Applies a canvas size in physical pixels; both must be nonzero. Layout then runs in
        /// logical pixels derived by `frame.Frame.apply_configure`. Returns the dirty flag.
        fn resize(width_px: u32, height_px: u32) callconv(.c) u32 {
            assert(state.frame.running);
            state.frame.apply_configure(width_px, height_px);
            assert(state.frame.width_px != 0);
            return dirty_flag();
        }

        /// Pointer moved. `(x, y)` are device pixels, matching the canvas backing store.
        /// Returns the dirty flag.
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

        /// Wheel at device-pixel `(x, y)`. `dy` is in the same unit as the pointer coordinates;
        /// positive `dy` scrolls content downward.
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

        /// Host timer period in milliseconds, bounded by `app_contract.timer_period_ms_max`.
        /// Zero means the app has no timer.
        fn timer_period_ms() callconv(.c) u32 {
            assert(App.config.timer_period_ms <= app_contract.timer_period_ms_max);
            return App.config.timer_period_ms;
        }

        /// Calls the app's `timer`. Only valid when the app declared a timer period. Returns
        /// the dirty flag. Does not step animators; the host interval owns the cadence.
        fn timer(now_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(App.config.timer_period_ms != 0);
            if (app.timer(now_ms)) {
                state.frame.request_redraw();
            }
            assert(state.frame.running);
            return dirty_flag();
        }

        /// Steps animators from `now_ms`, presents if the frame is dirty, and returns 1 only
        /// while an animator is live so `shell.js` chains another rAF. The first sample after
        /// idle has dt 0 (see `animator.Clock.advance`).
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
                context.reset();
                app.draw(&context);
            }
            assert(!app.dirty());
            // Spans must outlive the host call; module guide section 3 explains why static
            // storage is enough.
            state.commands.reset();
            render.frame(&state.commands, &context, .{
                .width_logical = state.frame.width_logical,
                .height_logical = state.frame.height_logical,
                .width_px = state.frame.width_px,
                .height_px = state.frame.height_px,
            });
            var unused: gpu.Gpu = .{};
            gpu.submit(&unused, &state.commands) catch unreachable;
            state.frame.mark_presented();
            assert(!state.frame.redraw);
            assert(!app.dirty());
        }

        /// 1 when a redraw is owed and the canvas has a nonzero size, else 0. A zero-size
        /// canvas cannot be presented, so no frame is requested for it.
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

// Locks that the exported op table is the generated one, so `shell.js` decodes exactly the
// layouts the recorder encodes.
test "the op table export is commands.table_json" {
    const exported = commands_json_ptr()[0..commands_json_len()];
    try std.testing.expectEqualStrings(commands.table_json, exported);
}

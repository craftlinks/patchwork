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
//! carries the shader text, the static unit quad, the textures, and every layout as spans and
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
//!   never steps animators or chains rAF. `timer_on` reports `cx.timer_on`; `shell.js` reads
//!   it after every call (where it syncs the cursor, in the interval callback, and after
//!   `start`) and sets or clears its one interval to match, so a stopped timer wakes nothing.
//! - `tick` is the rAF callback: it advances `animator.Clock`, advances `animator.Time` while
//!   the renderer has an animated instance on screen (`draw/renderer.zig`, section 4b),
//!   forwards the delta as `.frame` through `ui.animate`, presents if dirty or animating, and
//!   returns 1 while a widget keeps animating (`cx.keep_animating`), while the renderer is
//!   animating after the present (so a click that shows the first animated instance starts
//!   the chain), or while a redraw is still owed (the glyph cache skipped
//!   glyphs for its per-frame budget or a full atlas, or the hover a draw re-resolved owes
//!   another). Returning 0 ends the rAF chain, and `clock.reset` makes the next sample after
//!   idle report a zero delta.
//! - Pointer exports dispatch through `ui.dispatch`, and `timer` calls `App.timer`; each
//!   requests a frame when the UI context is dirty afterwards. A window request (a window
//!   button, a press on a drag area) is taken and dropped: the page has no window to move,
//!   resize, or close.
//! - `present_frame` runs `ui.draw_frame`, which calls `App.draw` when the context is dirty
//!   or the glyph cache owes a draw (`Cache.owes_draw`: the scale changed since the last
//!   draw, or glyphs are pending). A changed canvas size only marks the context dirty,
//!   because layout happens while drawing.
//! - `start` submits the setup stream, then leaves the draw pools empty and `relayout` set;
//!   the first draw happens in `present_frame` after `resize` has supplied real canvas
//!   dimensions.
//! - `resize(css_width, css_height, scale_120)` receives the canvas size in CSS pixels, which
//!   are the logical pixels layout uses, and `round(devicePixelRatio * 120)`. `Frame` derives
//!   the backing size, and `shell.js` reads it back through `width_px` and `height_px` to size
//!   the canvas, so Zig is the single source of truth for the framebuffer size that
//!   `pass_begin` carries. Pointer coordinates and wheel deltas arrive in CSS pixels too, so
//!   layout and hit testing share one frame of reference at every device pixel ratio.
//! - Timing is host-driven: no Web Workers, no `SharedArrayBuffer`, and no cross-origin
//!   isolation headers are required.
//!
//! ## 4b. A Producer
//! An app with a producer (`app.zig`, section 4e) gets data from another realm, an AudioWorklet
//! or a worker, through its own web module (`web/shell.js`, section 9a), which copies it in and
//! calls `shell.wake()` to schedule a frame. `tick` calls `App.drain` once, before
//! `ui.animate`, and a drain that leaves the app dirty requests the frame's present.
//! The app's `Wake` stays at -1 here: the page does not sleep on a descriptor.
//!
//! ## 4c. Scenario Replay (`?bench=<scenario>`)
//! `bench_start(len)` names a scenario by the `len` bytes in the input buffer and, when the app
//! declares it, sets the canvas to the regress size at scale 1 (`bench.regress_size`) and
//! starts replaying it on the simulated clock of `--regress` (`bench.zig`, section 5b;
//! `host/headless.zig`, section 2). While a replay runs, `tick` ignores the rAF time: frame
//! `n` applies the scenario's next step, the app timer's ticks due by `t_n`, `ui.animate` with
//! the clock's delta, and with a producer `App.produce` with
//! `bench.producer_frames_at(n, 60)` frames and `App.drain`; then it presents with the animation
//! time of `t_n`. It returns 1 while frames remain, 2 after the last one (`shell.js` logs
//! `bench done`), and 3 when a step's target has no area. From `bench_start` on, `timer_on`
//! reports 0 (so `shell.js` arms no interval) and every input export is ignored, and after the
//! run `tick` presents nothing more, so the canvas
//! keeps the last frame for the screenshot. Without `bench_start` none of this runs.
//!
//! ## 4a. Keyboard, Clipboard, and Cursor
//! All key mapping lives in Zig, so `shell.js` stays a generic interpreter plus glue:
//! - `key_down(len, mods, repeat)` and `key_up(len, mods)` read `KeyboardEvent.key` as UTF-8
//!   from `input_ptr()` (a static `input_cap`-byte buffer that `shell.js` fills with
//!   `TextEncoder.encodeInto`). `input.key_of_dom` names the key, and a value that is one
//!   codepoint is the typed text (`input.key_press` filters it). `mods` is the `input.Mods`
//!   byte: shift 1, ctrl 2, alt 4, meta 8. `key_down` returns bit 0 = a frame is owed and
//!   bit 1 = consumed (`cx.consumed`): `shell.js` calls `preventDefault` only then, so Tab
//!   leaves a canvas with nothing focusable and Ctrl+C, X, and V reach the page's clipboard
//!   events. The browser repeats keys itself (`event.repeat`); Zig never repeats.
//! - Copy and cut: a focused field handles Ctrl+C or Ctrl+X in `key_down` and calls
//!   `cx.copy`; the page's `copy` or `cut` event that follows asks `copy_take()`, which returns
//!   the length of that pending copy (0 for none) at `copy_ptr()`. `key_down` drops a stale
//!   pending copy first, so a copy event only ever takes the text of its own keystroke.
//! - Paste: the page's `paste` event writes the text into `input_ptr()` and calls
//!   `paste(len)`, which dispatches `Event.paste` directly (never queued). A paste request
//!   from a field is cleared and ignored, because the page event delivers the text anyway.
//! - `window_focus(focused)` is the canvas `focus` and `blur`; a blur releases held keys.
//! - `cursor()` is the `ui.Cursor` value to show, and `cursor_names_ptr/len` a JSON array of
//!   the CSS names by value, generated from the enum at compile time, so `shell.js` holds no
//!   cursor table.
//! - Pointer presses and releases carry the button (0 left, 1 middle, 2 right: the DOM
//!   numbering), the modifiers, and `event.timeStamp` in whole milliseconds, which the
//!   library's click counting compares.
//!
//! ## 4d. File Drops
//! `shell.js` reports a file drag over the canvas with `drop_over(x, y)`, whose bit 1 says
//! whether a drop target is under it (`cx.drop_wanted`, so the page shows a copy or a no-drop
//! cursor), and `drop_leave()`. A drop lists its files (`drop_reset`, then `drop_add(name_len,
//! size_lo, size_hi, readable)` per file, its name in the input buffer) and dispatches them
//! with `drop(x, y)`, whose bit 2 says the app accepted some. `shell.js` then asks
//! `read_next()` for a ticket (0: done) and `read_file`, `read_offset_lo/hi`, and `read_len`,
//! reads that slice of its `File`, writes it at `chunk_ptr()`, and calls `read_done(ticket,
//! got, failed)`, which dispatches the chunk. `drop.Transfer` does the cutting (`drop.zig`), so
//! the chunks are the native host's; a read that resolves after its file was cancelled has a
//! stale ticket and is ignored. After every dispatch `note_event` starts a transfer the app
//! accepted and dispatches the `cancelled` chunks of its cancels.
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
const ui = @import("../ui.zig");
const bench = @import("../bench.zig");
const drop = @import("../drop.zig");

/// Bytes `shell.js` may write into the input buffer: a key name or a paste.
pub const input_cap: u32 = ui.cx.clipboard_cap;

/// The CSS cursor names indexed by `ui.Cursor` value, as a JSON array.
pub const cursor_names_json: []const u8 = blk: {
    var json: []const u8 = "[";
    for (@typeInfo(ui.Cursor).@"enum".field_names, 0..) |name, index| {
        var css: [name.len]u8 = name[0..name.len].*;
        for (&css) |*byte| {
            if (byte.* == '_') byte.* = '-';
        }
        const separator = if (index == 0) "" else ",";
        json = json ++ separator ++ "\"" ++ css ++ "\"";
    }
    break :blk json ++ "]";
};

fn cursor_names_ptr() callconv(.c) [*]const u8 {
    assert(cursor_names_json.len >= 2);
    return cursor_names_json.ptr;
}

fn cursor_names_len() callconv(.c) u32 {
    assert(cursor_names_json.len >= 2);
    return @intCast(cursor_names_json.len);
}

/// The `input.Mods` byte `shell.js` sends; unused bits are dropped.
fn mods_of(bits: u32) input.Mods {
    const mods: input.Mods = @bitCast(@as(u8, @truncate(bits & 0x0F)));
    assert(mods.unused == 0);
    return mods;
}

/// The DOM button number: 0 left, 1 middle, 2 right. Others are treated as middle.
fn button_of(number: u32) input.MouseButton {
    return switch (number) {
        0 => .left,
        2 => .right,
        else => .middle,
    };
}

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
    @export(&cursor_names_ptr, .{ .name = "cursor_names_ptr" });
    @export(&cursor_names_len, .{ .name = "cursor_names_len" });
    @export(&Web.start, .{ .name = "start" });
    @export(&Web.resize, .{ .name = "resize" });
    @export(&Web.width_px, .{ .name = "width_px" });
    @export(&Web.height_px, .{ .name = "height_px" });
    @export(&Web.pointer_move, .{ .name = "pointer_move" });
    @export(&Web.pointer_down, .{ .name = "pointer_down" });
    @export(&Web.pointer_up, .{ .name = "pointer_up" });
    @export(&Web.pointer_wheel, .{ .name = "pointer_wheel" });
    @export(&Web.pointer_leave, .{ .name = "pointer_leave" });
    @export(&Web.touch_down, .{ .name = "touch_down" });
    @export(&Web.touch_move, .{ .name = "touch_move" });
    @export(&Web.touch_up, .{ .name = "touch_up" });
    @export(&Web.touch_cancel, .{ .name = "touch_cancel" });
    @export(&Web.input_ptr, .{ .name = "input_ptr" });
    @export(&Web.input_capacity, .{ .name = "input_cap" });
    @export(&Web.key_down, .{ .name = "key_down" });
    @export(&Web.key_up, .{ .name = "key_up" });
    @export(&Web.paste, .{ .name = "paste" });
    @export(&Web.copy_ptr, .{ .name = "copy_ptr" });
    @export(&Web.copy_take, .{ .name = "copy_take" });
    @export(&Web.window_focus, .{ .name = "window_focus" });
    @export(&Web.drop_over, .{ .name = "drop_over" });
    @export(&Web.drop_leave, .{ .name = "drop_leave" });
    @export(&Web.drop_reset, .{ .name = "drop_reset" });
    @export(&Web.drop_add, .{ .name = "drop_add" });
    @export(&Web.drop_files, .{ .name = "drop" });
    @export(&Web.read_next, .{ .name = "read_next" });
    @export(&Web.read_file, .{ .name = "read_file" });
    @export(&Web.read_offset_lo, .{ .name = "read_offset_lo" });
    @export(&Web.read_offset_hi, .{ .name = "read_offset_hi" });
    @export(&Web.read_len, .{ .name = "read_len" });
    @export(&Web.chunk_ptr, .{ .name = "chunk_ptr" });
    @export(&Web.read_done, .{ .name = "read_done" });
    @export(&Web.cursor, .{ .name = "cursor" });
    @export(&Web.timer_period_ms, .{ .name = "timer_period_ms" });
    @export(&Web.timer_on, .{ .name = "timer_on" });
    @export(&Web.timer, .{ .name = "timer" });
    @export(&Web.tick, .{ .name = "tick" });
    @export(&Web.overflow_take, .{ .name = "overflow_take" });
    @export(&Web.bench_start, .{ .name = "bench_start" });
    @export(&Web.bench_width, .{ .name = "bench_width" });
    @export(&Web.bench_height, .{ .name = "bench_height" });
}

/// The app-facing half of the browser host. `state` and `app` are static (BSS) storage.
fn WebApp(comptime App: type) type {
    return struct {
        const Context = app_contract.Context(App);
        const Renderer = renderer.Renderer(Context.DrawContext);

        const State = struct {
            frame: frame.Frame,
            commands: commands.CommandBuffer,
            clock: animator.Clock,
            /// Animation time for animated draw types; advanced while the renderer animates.
            time: animator.Time,
        };

        // Module guide, section 5: `undefined` keeps these in BSS; `start` initializes them.
        var state: State = undefined;
        var context: Context = undefined;
        var render: Renderer = undefined;
        var app: App = undefined;

        /// A producer (section 4b), whose data the app's web module delivers.
        const has_producer = app_contract.has_producer(App);
        /// The last overflow report, and whether `overflow_take` has yet to hand it out.
        var overflow_counts: [5]u32 = @splat(0);
        var overflow_pending: bool = false;
        /// Key names and pastes from `shell.js` (section 4a).
        var input_buffer: [input_cap]u8 = undefined;
        /// The last drop's files, the transfer, the read `shell.js` is doing, and the chunk
        /// buffer it fills (section 4d).
        const Drops = struct {
            list: drop.List,
            transfer: drop.Transfer,
            read: drop.Read,
            bytes: [drop.chunk_cap]u8,
            chunk: input.Chunk,
            cancelled: [input.drop_files_max]input.Chunk,
        };
        var drops: Drops = undefined;

        /// The `?bench=` replay (section 4c); `phase` is `.off` without one.
        const scenarios: []const bench.Scenario =
            if (@hasDecl(App, "scenarios")) App.scenarios else &.{};
        const regress_size = bench.regress_size(App);
        const ReplayRun = struct {
            phase: enum { off, running, done, failed },
            scenario: *const bench.Scenario,
            replay: bench.Replay,
            /// The next frame's number on the simulated clock.
            n: u64,
            frames_max: u64,
            clock: bench.Clock,
            /// Frames the producer was stepped by (section 4c).
            producer_frames: u64,
            owns_copy: bool,
        };
        var replay_run: ReplayRun = .{
            .phase = .off,
            .scenario = undefined,
            .replay = undefined,
            .n = 0,
            .frames_max = 0,
            .clock = undefined,
            .producer_frames = 0,
            .owns_copy = false,
        };
        var replay_paste: [ui.cx.clipboard_cap]u8 = undefined;

        /// Initializes host state, the draw context, the renderer, and the app, then submits
        /// the setup stream. Called once by JavaScript after the device exists. The app runs
        /// first, as on native, so the textures it creates are in the setup stream and its
        /// per-op validation scopes. The pools stay empty and `relayout` stays set because the
        /// first draw needs the canvas size that only `resize` supplies. Returns the dirty
        /// flag (see `dirty_flag`).
        fn start() callconv(.c) u32 {
            state.frame = frame.Frame.init();
            state.clock = animator.Clock.init();
            state.time = animator.Time.init();
            state.commands.len = 0;
            state.commands.count = 0;
            context.init();
            app_contract.start(App, &context);
            drops.transfer.init();
            drops.list.reset(0, 0);
            render.init();
            App.init(&app, &context.draw.textures);
            render.setup(&state.commands, &context.draw);
            var unused: gpu.Gpu = .{};
            gpu.submit(&unused, &state.commands) catch unreachable;
            assert(state.frame.running);
            assert(state.frame.relayout);
            assert(context.draw.batch_count == 0);
            assert(context.dirty);
            return dirty_flag();
        }

        /// Applies the canvas size in CSS (logical) pixels and the device pixel ratio in 1/120
        /// units; all nonzero. `shell.js` then sizes the backing store from `width_px` and
        /// `height_px`. Returns the dirty flag.
        fn resize(css_width: u32, css_height: u32, scale_120: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(scale_120 != 0);
            state.frame.apply_configure(css_width, css_height);
            state.frame.apply_scale(scale_120) catch unreachable;
            assert(state.frame.width_px != 0);
            return dirty_flag();
        }

        /// The canvas backing width in device pixels (`Frame.width_px`).
        fn width_px() callconv(.c) u32 {
            assert(state.frame.width_px != 0);
            return state.frame.width_px;
        }

        /// The canvas backing height in device pixels (`Frame.height_px`).
        fn height_px() callconv(.c) u32 {
            assert(state.frame.height_px != 0);
            return state.frame.height_px;
        }

        /// Pointer moved. `(x, y)` are CSS pixels, the logical pixels of layout.
        /// Returns the dirty flag.
        fn pointer_move(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_move = .{ .x = x, .y = y } });
        }

        /// Button `button` (DOM numbering) pressed at CSS-pixel `(x, y)` with `mods` at
        /// `time_ms` (section 4a).
        fn pointer_down(x: f32, y: f32, button: u32, mods: u32, time_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_down = button_sample(x, y, button, mods, time_ms) });
        }

        /// Button `button` released at CSS-pixel `(x, y)`.
        fn pointer_up(x: f32, y: f32, button: u32, mods: u32, time_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .pointer_up = button_sample(x, y, button, mods, time_ms) });
        }

        /// A finger (`pointerType` touch) landed at CSS-pixel `(x, y)`. `id` is the DOM
        /// `pointerId`, unique while the finger is down. Returns the dirty flag.
        fn touch_down(id: u32, x: f32, y: f32, time_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = time_ms } });
        }

        /// A finger moved to CSS-pixel `(x, y)`.
        fn touch_move(id: u32, x: f32, y: f32, time_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(x == x);
            return note_event(.{ .touch_move = .{ .id = id, .x = x, .y = y, .time_ms = time_ms } });
        }

        /// A finger lifted.
        fn touch_up(id: u32, time_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            return note_event(.{ .touch_up = .{ .id = id, .time_ms = time_ms } });
        }

        /// The browser cancelled a finger (`pointercancel`).
        fn touch_cancel(id: u32) callconv(.c) u32 {
            assert(state.frame.running);
            return note_event(.{ .touch_cancel = id });
        }

        fn button_sample(x: f32, y: f32, button: u32, mods: u32, time_ms: u32) input.Button {
            assert(y == y);
            assert(button <= 0xFFFF);
            return .{
                .x = x,
                .y = y,
                .time_ms = time_ms,
                .button = button_of(button),
                .mods = mods_of(mods),
            };
        }

        /// Wheel at CSS-pixel `(x, y)`. The deltas are in the same unit as the pointer
        /// coordinates; positive `dy` scrolls content downward, positive `dx` right.
        fn pointer_wheel(x: f32, y: f32, dx: f32, dy: f32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(dx == dx);
            assert(dy == dy);
            return note_event(.{ .wheel = .{ .x = x, .y = y, .dx = dx, .dy = dy } });
        }

        /// The input buffer's linear-memory address.
        fn input_ptr() callconv(.c) [*]u8 {
            assert(state.frame.running);
            return &input_buffer;
        }

        fn input_capacity() callconv(.c) u32 {
            assert(input_buffer.len == input_cap);
            return input_cap;
        }

        /// A key press named by the `len` bytes of `KeyboardEvent.key` in the input buffer.
        /// Returns bit 0 = dirty, bit 1 = consumed (section 4a).
        fn key_down(len: u32, mods: u32, repeat: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(len <= input_cap);
            const name = input_buffer[0..len];
            const single = len >= 1 and input.sequence_length(name[0]) == len;
            const typed: []const u8 = if (single and len <= input.key_text_cap) name else "";
            const press = input.key_press(
                input.key_of_dom(name),
                mods_of(mods),
                repeat != 0,
                typed,
            );
            _ = context.take_copy();
            const dirty = note_event(.{ .key_down = press });
            const consumed: u32 = @intFromBool(context.consumed());
            assert(dirty <= 1);
            return dirty | consumed << 1;
        }

        /// A key release named like `key_down`. Returns the dirty flag.
        fn key_up(len: u32, mods: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(len <= input_cap);
            const key = input.key_of_dom(input_buffer[0..len]);
            return note_event(.{ .key_up = input.key_press(key, mods_of(mods), false, "") });
        }

        /// Dispatches the `len` bytes of pasted UTF-8 in the input buffer. Returns the dirty
        /// flag.
        fn paste(len: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(len <= input_cap);
            return note_event(.{ .paste = input_buffer[0..len] });
        }

        /// The address of the text `copy_take` reports.
        fn copy_ptr() callconv(.c) [*]const u8 {
            assert(context.copy_len <= ui.cx.clipboard_cap);
            return &context.clipboard;
        }

        /// The length of the copy the last key press made, or 0; clears it (section 4a).
        fn copy_take() callconv(.c) u32 {
            assert(state.frame.running);
            if (!context.take_copy()) return 0;
            assert(!context.copy_pending);
            return context.copy_len;
        }

        /// The canvas gained (1) or lost (0) keyboard focus. Returns the dirty flag.
        fn window_focus(focused: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(focused <= 1);
            return note_event(.{ .window_focus = focused != 0 });
        }

        /// A file drag over the canvas at `(x, y)`. Returns bit 0 = dirty, bit 1 = a drop
        /// target is under it (section 4d).
        fn drop_over(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            const dirty = note_event(.{ .drop_over = .{ .x = x, .y = y } });
            return dirty | @as(u32, @intFromBool(context.drop_wanted())) << 1;
        }

        /// The file drag left the canvas. Returns the dirty flag.
        fn drop_leave() callconv(.c) u32 {
            assert(state.frame.running);
            return note_event(.drop_leave);
        }

        /// Starts listing a drop's files.
        fn drop_reset() callconv(.c) void {
            assert(state.frame.running);
            drops.list.reset(0, 0);
        }

        /// Lists one dropped file, its name the `name_len` bytes in the input buffer. Returns 0
        /// when it was skipped.
        fn drop_add(name_len: u32, size_lo: u32, size_hi: u32, readable: u32) callconv(.c) u32 {
            assert(name_len <= input_cap);
            assert(readable <= 1);
            const size = @as(u64, size_hi) << 32 | size_lo;
            return @intFromBool(drops.list.add("", input_buffer[0..name_len], size, readable == 1));
        }

        /// Dispatches the listed files dropped at `(x, y)`, after cancelling a transfer still
        /// running. Returns bit 0 = dirty, bit 2 = files were accepted: `shell.js` reads them.
        fn drop_files(x: f32, y: f32) callconv(.c) u32 {
            assert(state.frame.running);
            if (drops.transfer.running()) {
                const all = std.math.maxInt(u16);
                dispatch_chunks(drops.transfer.cancel(all, &drops.cancelled));
            }
            drops.list.drop.x = x;
            drops.list.drop.y = y;
            const dirty = note_event(.{ .drop = drops.list.files() });
            return dirty | @as(u32, @intFromBool(drops.transfer.running())) << 2;
        }

        /// The ticket of the next read `shell.js` does, or 0 when the transfer ended. Empty and
        /// unreadable files end here without a read.
        fn read_next() callconv(.c) u32 {
            assert(state.frame.running);
            var guard: u32 = 0;
            while (guard <= input.drop_files_max) : (guard += 1) {
                const next = drops.transfer.next() orelse return 0;
                switch (next) {
                    .end => |end| {
                        drops.chunk = end;
                        _ = note_event(.{ .file = &drops.chunk });
                    },
                    .read => |read| {
                        drops.read = read;
                        assert(read.ticket != 0);
                        return read.ticket;
                    },
                }
            }
            return 0;
        }

        fn read_file() callconv(.c) u32 {
            return drops.read.file;
        }

        fn read_offset_lo() callconv(.c) u32 {
            return @truncate(drops.read.offset);
        }

        fn read_offset_hi() callconv(.c) u32 {
            return @intCast(drops.read.offset >> 32);
        }

        fn read_len() callconv(.c) u32 {
            assert(drops.read.len <= drop.chunk_cap);
            return drops.read.len;
        }

        /// Where `shell.js` writes a read's bytes.
        fn chunk_ptr() callconv(.c) [*]u8 {
            return &drops.bytes;
        }

        /// A read finished: `got` bytes in the chunk buffer, or failed. Dispatches its chunk
        /// unless the ticket went stale. Returns the dirty flag.
        fn read_done(ticket: u32, got: u32, failed: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(got <= drop.chunk_cap);
            const bytes = drops.bytes[0..got];
            const chunk = drops.transfer.complete(ticket, bytes, failed != 0) orelse return 0;
            drops.chunk = chunk;
            return note_event(.{ .file = &drops.chunk });
        }

        /// Dispatches cancelled chunks directly.
        fn dispatch_chunks(count: u32) void {
            assert(count <= input.drop_files_max);
            for (drops.cancelled[0..count]) |*chunk| {
                ui.dispatch(App, &app, &context, .{ .file = chunk });
                if (context.dirty) state.frame.request_redraw();
            }
        }

        /// After a dispatch: a transfer the app accepted, and the cancelled chunks of its
        /// cancels, bounded (section 4d).
        fn serve_files() void {
            if (context.take_files_accept()) |mask| drops.transfer.begin(drops.list.files(), mask);
            var guard: u32 = 0;
            while (guard < input.drop_files_max) : (guard += 1) {
                const mask = context.take_files_cancel();
                if (mask == 0) break;
                dispatch_chunks(drops.transfer.cancel(mask, &drops.cancelled));
            }
        }

        /// The `ui.Cursor` value to show over the canvas.
        fn cursor() callconv(.c) u32 {
            assert(state.frame.running);
            return @backingInt(context.cursor());
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

        /// 1 while the app wants its timer running (`cx.timer_on`), else 0. `shell.js` reads
        /// it after every call and sets or clears its interval to match (section 4).
        fn timer_on() callconv(.c) u32 {
            if (App.config.timer_period_ms == 0) assert(!context.timer_on);
            if (replay_run.phase != .off) return 0;
            return @intFromBool(context.timer_on);
        }

        /// Calls the app's `timer`. Only valid when the app declared a timer period. Returns
        /// the dirty flag. Does not step animators; the host interval owns the cadence. A
        /// tick the browser had already queued when the interval was cleared calls nothing.
        fn timer(now_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(App.config.timer_period_ms != 0);
            if (!context.timer_on) return dirty_flag();
            if (replay_run.phase != .off) return 0;
            App.timer(&app, &context, now_ms);
            if (context.dirty) {
                state.frame.request_redraw();
            }
            assert(state.frame.running);
            return dirty_flag();
        }

        /// Steps animators and the animation time from `now_ms`, presents if the frame is
        /// dirty or animating, and returns 1 while an animator is live, the renderer is
        /// animating, or a redraw is still owed, so `shell.js` chains another rAF. The first
        /// sample after idle has dt 0 (see `animator.Clock.advance`).
        fn tick(now_ms: u32) callconv(.c) u32 {
            assert(state.frame.running);
            if (replay_run.phase != .off) return replay_tick();
            drain_producer();
            const dt_ms = state.clock.advance(now_ms);
            if (render.animating) {
                state.time.advance(dt_ms);
                state.frame.request_redraw();
            }
            const animating = ui.animate(App, &app, &context, dt_ms);
            if (context.dirty) {
                state.frame.request_redraw();
            }
            present_frame();
            // After the present: the frame just drawn may be the first with an animated type.
            if (!animating and !render.animating) {
                state.clock.reset();
                return dirty_flag();
            }
            assert(animating or render.animating);
            return 1;
        }

        /// The address of the last overflow report's five words (instances, areas, glyphs,
        /// missing icons, the last missing icon as `face << 21 | codepoint`) once, or 0:
        /// `shell.js` logs it after `tick` (`ui/cx.zig`, section 10).
        fn overflow_take() callconv(.c) u32 {
            if (!overflow_pending) return 0;
            overflow_pending = false;
            return @intCast(@intFromPtr(&overflow_counts));
        }

        /// Starts replaying the scenario named by the first `len` bytes of the input buffer
        /// (section 4c). Returns 1 when the app declares it, 0 otherwise (nothing changes).
        /// Called once, after `start` and before the first frame.
        fn bench_start(len: u32) callconv(.c) u32 {
            assert(state.frame.running);
            assert(len <= input_cap);
            if (replay_run.phase != .off) return 0;
            const found = bench.find(scenarios, input_buffer[0..len]) orelse return 0;
            state.frame.apply_configure(regress_size[0], regress_size[1]);
            state.frame.apply_scale(120) catch unreachable;
            assert(state.frame.width_px == regress_size[0]);
            var setup_frames: u64 = 0;
            for (found.setup) |step| setup_frames += if (step == .wait) step.wait else 1;
            replay_run = .{
                .phase = .running,
                .scenario = found,
                .replay = .init(),
                .n = 0,
                .frames_max = setup_frames + found.frames + 1,
                .clock = .init(App.config.timer_period_ms),
                .producer_frames = 0,
                .owns_copy = false,
            };
            state.frame.request_redraw();
            return 1;
        }

        /// The regress size `bench_start` sets, in CSS and device pixels.
        fn bench_width() callconv(.c) u32 {
            return regress_size[0];
        }

        fn bench_height() callconv(.c) u32 {
            return regress_size[1];
        }

        /// One replay frame (section 4c): 1 while frames remain, 2 after the last, 3 on a
        /// step whose target has no area, 0 once the run ended.
        fn replay_tick() u32 {
            const run = &replay_run;
            if (run.phase != .running) return 0;
            const n = run.n;
            if (n > run.frames_max) {
                run.phase = .failed;
                return 3;
            }
            if (n > 0) {
                if (run.replay.next(run.scenario)) |step| {
                    if (!replay_step(step, n)) {
                        run.phase = .failed;
                        return 3;
                    }
                }
            }
            const t_ms = bench.Clock.frame_time_ms(n);
            var ticks: u32 = 0;
            while (run.clock.due(t_ms, context.timer_on)) |at| : (ticks += 1) {
                if (ticks == bench.ticks_per_frame_max) break;
                App.timer(&app, &context, at);
            }
            _ = ui.animate(App, &app, &context, bench.Clock.frame_dt(n));
            if (has_producer) {
                if (comptime app_contract.has_produce(App)) {
                    App.produce(&app, bench.producer_frames_at(run.producer_frames, 60));
                }
                run.producer_frames += 1;
                drain_producer();
            }
            state.time = .{ .ms = t_ms };
            state.frame.request_redraw();
            present_frame();
            _ = run.replay.presented(run.scenario);
            run.n += 1;
            if (run.replay.phase == .done) {
                run.phase = .done;
                return 2;
            }
            return 1;
        }

        /// Dispatches one scenario step at frame `n`; false when its target has no area.
        fn replay_step(step: bench.Step, n: u64) bool {
            var rect: ?[4]f32 = null;
            if (bench.step_target(step)) |target| {
                const found = context.find(target.id) orelse return false;
                rect = found.rect;
            }
            var events: [bench.event_cap]input.Event = undefined;
            const time_ms: u32 = @intCast(bench.Clock.frame_time_ms(n));
            const count = bench.step_events(step, rect, time_ms, &events);
            for (events[0..count]) |event| replay_dispatch(event);
            if (step == .drop) bench.replay_drop(App, &app, &context, step.drop, rect.?);
            bench.serve_window(App, &app, &context);
            return true;
        }

        /// The regress host's dispatch: a paste request pastes the app's own copy.
        fn replay_dispatch(event: input.Event) void {
            ui.dispatch(App, &app, &context, event);
            if (context.take_copy()) replay_run.owns_copy = true;
            if (!context.take_paste_request()) return;
            if (!replay_run.owns_copy) return;
            const own = context.copied();
            @memcpy(replay_paste[0..own.len], own);
            ui.dispatch(App, &app, &context, .{ .paste = replay_paste[0..own.len] });
        }

        /// The app's one call for its producer (`app.zig`, section 4e; section 4b).
        fn drain_producer() void {
            if (!has_producer) return;
            App.drain(&app, &context);
            if (context.dirty) state.frame.request_redraw();
        }

        fn note_event(event: input.Event) u32 {
            // A replay owns every event (section 4c).
            if (replay_run.phase != .off) return 0;
            ui.dispatch(App, &app, &context, event);
            // The page's own paste event delivers the text, so a request needs no action.
            _ = context.take_paste_request();
            // The page has no window to move, resize, or close (`ui/cx.zig`, section 5a).
            _ = context.take_window_request();
            serve_files();
            if (context.dirty) {
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
                state.frame.mark_laid_out();
                context.redraw();
            }
            assert(!state.frame.relayout);
            const scale_120 = state.frame.scale_120;
            _ = ui.draw_frame(
                App,
                &app,
                &context,
                state.frame.width_logical,
                state.frame.height_logical,
                scale_120,
            );
            assert(context.draw.text.drawn_scale_120 == scale_120);
            if (std.debug.runtime_safety) {
                if (context.overflow_report()) |refused| {
                    overflow_counts = .{
                        refused.instances,
                        refused.areas,
                        refused.glyphs,
                        refused.icons,
                        refused.icon,
                    };
                    overflow_pending = true;
                }
            }
            // Spans must outlive the host call; module guide section 3 explains why static
            // storage is enough.
            state.commands.reset();
            render.frame(&state.commands, &context.draw, .{
                .width_logical = state.frame.width_logical,
                .height_logical = state.frame.height_logical,
                .width_px = state.frame.width_px,
                .height_px = state.frame.height_px,
                .scale_120 = scale_120,
            }, state.time.seconds());
            // A skipped frame (`draw/renderer.zig`, section 4a) may record nothing at all; the
            // canvas keeps showing the last frame.
            if (state.commands.len != 0) {
                var unused: gpu.Gpu = .{};
                gpu.submit(&unused, &state.commands) catch unreachable;
            }
            state.frame.mark_presented();
            assert(!state.frame.redraw);
            // Glyphs skipped for the budget or a full atlas finish on the next frame, and a
            // hover that the redraw moved (`ui.draw_frame`) may have owed another draw.
            if (context.draw.text.owes_draw(scale_120)) {
                state.frame.request_redraw();
            }
            if (context.dirty) {
                state.frame.request_redraw();
            }
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

// Locks the cursor name export: the CSS names in `ui.Cursor` order.
test "the cursor names are the CSS names by value" {
    const expected = "[\"default\",\"pointer\",\"text\",\"grab\",\"grabbing\"," ++
        "\"ew-resize\",\"ns-resize\",\"nwse-resize\",\"nesw-resize\"]";
    try std.testing.expectEqualStrings(expected, cursor_names_json);
    try std.testing.expectEqual(@as(u8, 0x0B), @as(u8, @bitCast(mods_of(0xFB))));
    try std.testing.expectEqual(input.MouseButton.right, button_of(2));
}

// Locks that the exported op table is the generated one, so `shell.js` decodes exactly the
// layouts the recorder encodes.
test "the op table export is commands.table_json" {
    const exported = commands_json_ptr()[0..commands_json_len()];
    try std.testing.expectEqualStrings(commands.table_json, exported);
}

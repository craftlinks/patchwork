//! WebAssembly Freestanding Entry Points and Browser Interoperability Bridge.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Sandbox Boundary and Zero-Copy Memory Sharing
//! A `wasm32-freestanding` module has no OS, libc, or threads and cannot touch the DOM or
//! WebGPU. All communication with `web/shell.js` crosses three channels:
//! - **Exports:** `export_app` publishes every symbol through `@export`; `rdynamic` in
//!   `build.zig` keeps them in the module and `shell.js` looks each one up by name.
//! - **Imports:** `present_js` is the only host import (see `gpu.present`).
//! - **Linear memory:** Pointers are `u32` byte offsets into `wasm.memory.buffer`. JavaScript
//!   builds typed views over them, so no data is serialized or copied on the Zig side.
//!
//! ## 2. Zig as the Single Source of Truth for Graphics Layouts
//! `shell.js` queries the exports below instead of duplicating shader text, strides, theme
//! bytes, or atlas dimensions. Where `shell.js` still has to hard-code a layout fact (the
//! `PresentHeader` field offsets, the instance and glyph attribute offsets, the flag bits),
//! the `comptime` block at the end of this file enforces that fact on the Zig side so a
//! layout change fails the build instead of silently corrupting the browser decode.
//!
//! ## 3. Synchronous Stack-Frame Memory Sharing
//! `present_frame` builds `draw.PresentHeader` on its own stack and passes three pointers
//! (header, instances, glyphs) to `present_js`. This is memory safe because host calls are
//! synchronous on one thread: the engine suspends Zig inside the call, the stack frame stays
//! intact, and JavaScript must finish reading before control returns. JavaScript must not
//! retain any of the three pointers or views after `present_js` returns. The upload flags
//! and counts in the header decide which buffers JavaScript copies (see `draw.UploadCursor`).
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
//! - `start` leaves the draw list empty and `relayout` set; the first layout walk happens in
//!   `present_frame` after `resize` has supplied real canvas dimensions.
//! - Pointer coordinates are device pixels (canvas backing store), the same unit `resize`
//!   receives, so layout and hit testing share one frame of reference.
//! - Timing is host-driven: no Web Workers, no `SharedArrayBuffer`, and no cross-origin
//!   isolation headers are required.
//!
//! ## 5. TigerStyle Invariants
//! - `State` and the app live in static (BSS) linear memory; there is no runtime allocation.
//! - Buffer sizes and strides shared with the browser are checked at compile time (see the
//!   `comptime` block at the end of this file and "export ABI scalars match source constants").
//! - Every export runs in bounded time with no recursion.

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

/// Linear-memory address of the embedded quad WGSL source (`draw.shader_file`).
fn shader_ptr() callconv(.c) [*]const u8 {
    assert(draw.shader_file.len >= 1);
    assert(draw.instance_stride == 64);
    return draw.shader_file.ptr;
}

/// Byte length of the quad WGSL source.
fn shader_len() callconv(.c) u32 {
    assert(draw.shader_file.len >= 1);
    return @intCast(draw.shader_file.len);
}

/// Linear-memory address of `draw.unit_quad`. JavaScript reads `quad_bytes()` bytes from it.
fn quad_ptr() callconv(.c) [*]const f32 {
    assert(draw.quad_bytes == 48);
    return &draw.unit_quad;
}

/// Byte size of the unit quad vertex buffer (`draw.quad_bytes`).
fn quad_bytes() callconv(.c) u32 {
    assert(draw.unit_quad.len == 12);
    return draw.quad_bytes;
}

/// Byte stride of `draw.Instance` (`draw.instance_stride`). `shell.js` checks it against its
/// own hard-coded attribute layout; the offsets it assumes are enforced by the `comptime`
/// block at the end of this file.
fn instance_stride() callconv(.c) u32 {
    assert(draw.instance_stride == 64);
    return draw.instance_stride;
}

/// Linear-memory address of the glyph WGSL source (`font.shader_file`).
fn glyph_shader_ptr() callconv(.c) [*]const u8 {
    assert(font.shader_file.len >= 1);
    assert(font.glyph_stride == 64);
    return font.shader_file.ptr;
}

/// Byte length of the glyph WGSL source.
fn glyph_shader_len() callconv(.c) u32 {
    assert(font.shader_file.len >= 1);
    return @intCast(font.shader_file.len);
}

/// Byte stride of `font.Glyph` (`font.glyph_stride`).
fn glyph_stride() callconv(.c) u32 {
    assert(font.glyph_stride == 64);
    return font.glyph_stride;
}

/// Linear-memory address of `theme.chrome`. `shell.js` writes it right after the matrix,
/// at uniform offset `draw.matrix_bytes`.
fn theme_ptr() callconv(.c) [*]const u8 {
    assert(@sizeOf(theme.Theme) == 192);
    return @ptrCast(&theme.chrome);
}

/// Byte length of the theme record (`theme.bytes`).
fn theme_len() callconv(.c) u32 {
    assert(theme.bytes == 192);
    return theme.bytes;
}

/// Linear-memory address of the pre-baked `r8unorm` coverage atlas (`font.atlas_bytes`).
/// JavaScript uploads it once at startup; rows are `atlas_width()` bytes with no padding.
fn atlas_ptr() callconv(.c) [*]const u8 {
    assert(font.atlas_bytes.len == 131072);
    return font.atlas_bytes.ptr;
}

/// Byte size of the atlas, equal to `atlas_width() * atlas_height()` for one byte per texel.
fn atlas_len() callconv(.c) u32 {
    assert(font.atlas_bytes.len == 131072);
    return 131072;
}

/// Atlas width in texels (`font.atlas_width`).
fn atlas_width() callconv(.c) u32 {
    assert(font.atlas_width == 512);
    return font.atlas_width;
}

/// Atlas height in texels (`font.atlas_height`).
fn atlas_height() callconv(.c) u32 {
    assert(font.atlas_height == 256);
    return font.atlas_height;
}

/// Exports the whole browser surface for one app type. Called once, in a `comptime` block,
/// from `src/host/web_main.zig`. `export fn` cannot live inside a generic struct, so every
/// symbol goes through `@export`; the names are the contract with `web/shell.js`.
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

/// The app-facing half of the browser host. `state` and `app` are static (BSS) storage.
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

        /// Resets host state and initializes the app. Called once by JavaScript after the
        /// pipeline is compiled. The draw list stays empty and `relayout` stays set because
        /// the first layout needs the canvas size that only `resize` supplies.
        /// Returns the dirty flag (see `dirty_flag`).
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
                app.draw(&state.list, &state.glyphs);
            }
            assert(!app.dirty());
            // The header must outlive the host call; module guide section 3 explains why the
            // stack is safe.
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

comptime {
    // `web/shell.js` decodes `PresentHeader` with hard-coded offsets and configures vertex
    // attributes with hard-coded offsets. JavaScript cannot be checked at compile time, so
    // every offset it assumes is pinned here; changing a layout fails the build and forces
    // the matching edit in `web/shell.js`.
    assert(@offsetOf(draw.PresentHeader, "width_px") == 0);
    assert(@offsetOf(draw.PresentHeader, "height_px") == 4);
    assert(@offsetOf(draw.PresentHeader, "instance_count") == 8);
    assert(@offsetOf(draw.PresentHeader, "flags") == 12);
    assert(@offsetOf(draw.PresentHeader, "clear_r") == 16);
    assert(@offsetOf(draw.PresentHeader, "clear_a") == 28);
    assert(@offsetOf(draw.PresentHeader, "ortho") == 32);
    assert(@offsetOf(draw.PresentHeader, "glyph_count") == 96);
    assert(@sizeOf(draw.PresentHeader) == 104);
    assert(draw.flag_instances == 1);
    assert(draw.flag_uniform == 2);
    assert(draw.flag_glyphs == 4);
    assert(draw.matrix_bytes == @sizeOf([16]f32));

    // Both pipelines share one four-attribute vertex layout, so Instance and Glyph must agree
    // on where each vec4 group starts.
    assert(@offsetOf(draw.Instance, "x") == 0);
    assert(@offsetOf(draw.Instance, "r") == 16);
    assert(@offsetOf(draw.Instance, "radius") == 32);
    assert(@offsetOf(draw.Instance, "clip_x0") == 48);
    assert(@offsetOf(font.Glyph, "x") == 0);
    assert(@offsetOf(font.Glyph, "u0") == 16);
    assert(@offsetOf(font.Glyph, "r") == 32);
    assert(@offsetOf(font.Glyph, "clip_x0") == 48);
    assert(draw.instance_stride == font.glyph_stride);

    // `shell.js` sizes both vertex buffers with one shared capacity constant.
    assert(draw.instance_cap == font.glyph_cap);
    assert(font.atlas_bytes.len == font.atlas_width * font.atlas_height);
}

// Locks the invariant that each exported scalar reports the Zig constant it is documented
// to mirror, so `shell.js` validation against these exports cannot drift from the source.
test "export ABI scalars match source constants" {
    try std.testing.expectEqual(draw.instance_stride, instance_stride());
    try std.testing.expectEqual(draw.quad_bytes, quad_bytes());
    try std.testing.expectEqual(font.glyph_stride, glyph_stride());
    try std.testing.expectEqual(theme.bytes, theme_len());
    try std.testing.expectEqual(font.atlas_width, atlas_width());
    try std.testing.expectEqual(font.atlas_height, atlas_height());
    try std.testing.expectEqual(atlas_width() * atlas_height(), atlas_len());
    try std.testing.expectEqual(@as(u32, @intCast(draw.shader_file.len)), shader_len());
    try std.testing.expectEqual(@as(u32, @intCast(font.shader_file.len)), glyph_shader_len());
}

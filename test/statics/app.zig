//! The statics test: an app whose App has a size no other static of its native executable has,
//! so `tools/statics.zig` can count how many times the executable holds it (step 82).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Proves
//! The native executable holds the window host and the offscreen host, and both use the one App
//! in `host/statics.zig`. The tool counts the executable's data symbols whose size is
//! `@sizeOf(App)`: 1 048 580 bytes, 1 MiB of `ballast` and the 4-byte `frames`. A size that
//! round would be common; this one is the App's alone, so the count is the number of Apps.
//!
//! ## 2. Where It Is Wired
//! It is no example: `build.zig` builds its native executable and runs the tool on it as part of
//! `zig build test`, and never installs it, runs it, or builds its wasm.
//!
//! ## 3. TigerStyle Invariants
//! - The ballast is never touched: `init` writes only `frames`.

const std = @import("std");
const patchwork = @import("patchwork");
const quads = patchwork.draw;

const Context = patchwork.app.Context(App);

/// The App's bulk, which gives it a size of its own (section 1).
pub const ballast_bytes: usize = 1 << 20;

pub const App = struct {
    frames: u32,
    ballast: [ballast_bytes]u8,

    pub const config: patchwork.app.Config = .{
        .title = "statics test",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = quads.Box, .cap = 4 }},
        .area_cap = 4,
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.frames = 0;
    }

    pub fn event(app: *App, cx: *Context, event_value: patchwork.input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        _ = cx;
        app.frames +%= 1;
    }
};

comptime {
    std.debug.assert(@sizeOf(App) == ballast_bytes + 4);
}

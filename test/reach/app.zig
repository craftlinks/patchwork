//! The reach test: an app whose App is 1600 MiB (step 85), past what Zig's own Debug backend and
//! linker hold, under the 2 GiB an x86-64 executable's static data can reach.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Proves
//! - With `lld` (`build.zig`, section 4a) the App is BSS, no byte of it is in the file, and the
//!   executable starts: `zig build test` installs it and runs it with `--reach`, which the host
//!   refuses before it opens anything, so the run passes on exit 1 and `reach test:
//!   UnknownArgument` and fails on a crash at start.
//! - Without `lld` the hosts refuse it at compile time (`src/host/statics.zig`, section 4), so
//!   no 6 GB executable is ever written: a `test-contract` case.
//! - At 2048 MiB through LLD the link fails, naming the relocation that cannot reach: another
//!   `test-contract` case.
//!
//! ## 2. Where It Is Wired
//! It is no example: no `check`, `regress`, or wasm step builds it, and it is always a Debug
//! build. Its size comes from the `reach_size` options module `build.zig` gives it.
//!
//! ## 3. TigerStyle Invariants
//! - The ballast is never touched: `init` writes only `frames`, and the test run never reaches
//!   `init`.

const std = @import("std");
const patchwork = @import("patchwork");
const quads = patchwork.draw;

const Context = patchwork.app.Context(App);

/// The App's bulk, from `build.zig` (section 2).
pub const ballast_bytes: usize = @as(usize, @import("reach_size").ballast_mib) << 20;

pub const App = struct {
    frames: u32,
    ballast: [ballast_bytes]u8,

    pub const config: patchwork.app.Config = .{
        .title = "reach test",
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

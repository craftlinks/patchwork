//! Negative build test for the app contract's arguments. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports that `App.args`
//! has the wrong type (the `expect_errors` string in `build.zig`): a host hands `[:0]const u8`
//! strings, and an app that declared a plain slice must fail at build time (`src/app.zig`,
//! section 4d).

const patchwork = @import("patchwork");

/// Satisfies the whole contract but for `args`, whose strings are not terminated.
const Mistyped = struct {
    pub const config: patchwork.app.Config = .{
        .title = "source only",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
    };

    pub fn args(app: *Mistyped, arguments: []const []const u8) void {
        _ = app;
        _ = arguments;
    }

    pub fn init(app: *Mistyped, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *Mistyped,
        cx: *patchwork.app.Context(Mistyped),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *Mistyped, cx: *patchwork.app.Context(Mistyped), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *Mistyped, cx: *patchwork.app.Context(Mistyped)) void {
        _ = app;
        _ = cx;
    }
};

comptime {
    patchwork.app.check(Mistyped);
}

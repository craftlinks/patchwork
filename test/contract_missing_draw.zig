//! Negative build test for the app contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "App is missing `pub fn draw`" (the `expect_errors` string in `build.zig`). It locks the
//! compile-error path of `patchwork.app.check`: an app that forgets a declaration fails at
//! build time with a message naming it, instead of failing later inside a host. The pure
//! `conformance` checks are tested in `src/app.zig`.

const patchwork = @import("patchwork");

/// Satisfies every declaration of the contract except `draw`.
const MissingDraw = struct {
    pub const config: patchwork.app.Config = .{
        .title = "missing draw",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
    };

    pub fn init(app: *MissingDraw, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *MissingDraw,
        cx: *patchwork.app.Context(MissingDraw),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *MissingDraw, cx: *patchwork.app.Context(MissingDraw), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }
};

comptime {
    patchwork.app.check(MissingDraw);
}

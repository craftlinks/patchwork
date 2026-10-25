//! Negative build test for the app contract's theme rule. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "App.config.theme.colors.panel: a component is outside [0, 1]" (the `expect_errors` string
//! in `build.zig`): a color the GPU would clamp fails at build time, naming the field
//! (`src/app.zig`, section 4b).

const patchwork = @import("patchwork");

/// Satisfies the whole contract but for a panel green of 1.5.
const Bright = struct {
    pub const config: patchwork.app.Config = .{
        .title = "bright",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
        .theme = blk: {
            var scheme = patchwork.theme.dark;
            scheme.colors.panel[1] = 1.5;
            break :blk scheme;
        },
    };

    pub fn init(app: *Bright, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *Bright,
        cx: *patchwork.app.Context(Bright),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *Bright, cx: *patchwork.app.Context(Bright), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *Bright, cx: *patchwork.app.Context(Bright)) void {
        _ = app;
        _ = cx;
    }
};

comptime {
    patchwork.app.check(Bright);
}

//! Negative build test for the app contract's audio pair. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports "App declares
//! `Audio` but is missing `pub fn audio`" (the `expect_errors` string in `build.zig`): a source
//! whose blocks nothing receives fails at build time, not as a queue that silently fills
//! (`src/app.zig`, section 4a).

const patchwork = @import("patchwork");

/// Satisfies the whole contract and declares a source, but no `audio`.
const SourceOnly = struct {
    pub const config: patchwork.app.Config = .{
        .title = "source only",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
    };
    pub const Audio = patchwork.realtime.TestTone;

    pub fn init(app: *SourceOnly, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *SourceOnly,
        cx: *patchwork.app.Context(SourceOnly),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *SourceOnly, cx: *patchwork.app.Context(SourceOnly), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *SourceOnly, cx: *patchwork.app.Context(SourceOnly)) void {
        _ = app;
        _ = cx;
    }
};

comptime {
    patchwork.app.check(SourceOnly);
}

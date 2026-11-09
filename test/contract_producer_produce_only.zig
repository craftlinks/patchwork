//! Negative build test for the app contract's producer. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports "App declares
//! `produce` but no producer": stepping a producer by frame means nothing without a wake, a count,
//! and a drain (`src/app.zig`, section 4e).

const patchwork = @import("patchwork");

/// Satisfies the whole contract, with the producer declarations below.
const ProduceOnly = struct {
    pub const config: patchwork.app.Config = .{
        .title = "source only",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
    };

    pub fn init(app: *ProduceOnly, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *ProduceOnly,
        cx: *patchwork.app.Context(ProduceOnly),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *ProduceOnly, cx: *patchwork.app.Context(ProduceOnly), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *ProduceOnly, cx: *patchwork.app.Context(ProduceOnly)) void {
        _ = app;
        _ = cx;
    }

    pub fn produce(app: *ProduceOnly, frames: u32) void {
        _ = app;
        _ = frames;
    }
};

comptime {
    patchwork.app.check(ProduceOnly);
}

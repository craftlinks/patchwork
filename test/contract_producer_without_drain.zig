//! Negative build test for the app contract's producer. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports "App declares a
//! producer but is missing `pub fn drain`": a producer whose data nothing drains fails at build
//! time, not as a queue that silently fills (`src/app.zig`, section 4e).

const patchwork = @import("patchwork");

/// Satisfies the whole contract, with the producer declarations below.
const NoDrain = struct {
    pub const config: patchwork.app.Config = .{
        .title = "source only",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = patchwork.draw.Box, .cap = 4 }},
    };

    pub fn init(app: *NoDrain, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *NoDrain,
        cx: *patchwork.app.Context(NoDrain),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *NoDrain, cx: *patchwork.app.Context(NoDrain), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *NoDrain, cx: *patchwork.app.Context(NoDrain)) void {
        _ = app;
        _ = cx;
    }

    pub fn wake(app: *NoDrain) *patchwork.Wake {
        _ = app;
        unreachable;
    }

    pub fn pending(app: *const NoDrain) u32 {
        _ = app;
        return 0;
    }
};

comptime {
    patchwork.app.check(NoDrain);
}

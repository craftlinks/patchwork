//! Negative build test for animated draw types. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_frozen_time.Frozen: reads time but does not declare `animated = true`" (the
//! `expect_errors` string in `build.zig`). It locks that a type whose pixel reads the frame's
//! time without declaring itself animated fails the app's build, instead of freezing on screen
//! behind the pixel cache. The pure checks are tested in `src/draw/registry.zig`.

const patchwork = @import("patchwork");

/// Reads `time_pulse` but does not declare `animated`.
const Frozen = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?patchwork.draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(time_pulse(2.0));
        \\}
    ;
};

/// Satisfies the whole contract except the draw type's animated declaration.
const FrozenApp = struct {
    pub const config: patchwork.app.Config = .{
        .title = "frozen time",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = Frozen, .cap = 4 }},
    };

    pub fn init(app: *FrozenApp, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn event(
        app: *FrozenApp,
        cx: *patchwork.app.Context(FrozenApp),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *FrozenApp, cx: *patchwork.app.Context(FrozenApp), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *FrozenApp, cx: *patchwork.app.Context(FrozenApp)) void {
        _ = app;
        _ = cx;
    }
};

comptime {
    patchwork.app.check(FrozenApp);
}

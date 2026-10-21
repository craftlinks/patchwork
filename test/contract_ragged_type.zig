//! Negative build test for the draw type convention. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_ragged_type.Ragged: @sizeOf must be a multiple of 16 ..." (the `expect_errors`
//! string in `build.zig`). It locks that a draw type whose size is not a whole number of
//! 16-byte vertex attribute groups fails the app's build with a message naming the type,
//! instead of failing in a host when the pipeline is created. The pure checks are tested in
//! `src/draw/registry.zig`.

const patchwork = @import("patchwork");

/// Nine floats: 36 bytes, not a multiple of 16.
const Ragged = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    weight: f32,

    pub const texture: ?patchwork.draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(px.weight);
        \\}
    ;
};

/// Satisfies the whole contract except the draw type's size.
const RaggedApp = struct {
    pub const config: patchwork.app.Config = .{
        .title = "ragged type",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = Ragged, .cap = 4 }},
    };

    pub fn init(app: *RaggedApp, textures: *patchwork.draw.Textures) void {
        _ = app;
        _ = textures;
    }

    pub fn layout(app: *RaggedApp, width_logical: u32, height_logical: u32) void {
        _ = app;
        _ = width_logical;
        _ = height_logical;
    }

    pub fn event(app: *RaggedApp, event_value: patchwork.input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }

    pub fn timer(app: *RaggedApp, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }

    pub fn live(app: *const RaggedApp) bool {
        _ = app;
        return false;
    }

    pub fn dirty(app: *const RaggedApp) bool {
        _ = app;
        return false;
    }
};

comptime {
    patchwork.app.check(RaggedApp);
}

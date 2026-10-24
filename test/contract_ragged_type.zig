//! Negative build test for the draw type convention. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_ragged_type.Ragged: field `count` must be f32, [2]f32, or [4]f32" (the
//! `expect_errors` string in `build.zig`). It locks that a draw type with a field the vertex
//! layout cannot carry fails the app's build with a message naming the type and the field,
//! instead of failing in a host when the pipeline is created. (Before step 29 the case was a
//! 36-byte type; sizes in 4-byte steps are valid now.) The pure checks are tested in
//! `src/draw/registry.zig`.

const patchwork = @import("patchwork");

/// An integer field: the layout carries only f32 lanes.
const Ragged = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    count: u32,

    pub const texture: ?patchwork.draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(1.0);
        \\}
    ;
};

/// Satisfies the whole contract except the draw type's field.
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

    pub fn event(
        app: *RaggedApp,
        cx: *patchwork.app.Context(RaggedApp),
        event_value: patchwork.input.Event,
    ) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *RaggedApp, cx: *patchwork.app.Context(RaggedApp), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *RaggedApp, cx: *patchwork.app.Context(RaggedApp)) void {
        _ = app;
        _ = cx;
    }
};

comptime {
    patchwork.app.check(RaggedApp);
}

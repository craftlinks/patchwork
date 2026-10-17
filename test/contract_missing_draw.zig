//! Negative build test for the app contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "App is missing `pub fn draw`". It guards the first half of the contract: a hand-written
//! app that forgets a declaration fails at build time with a message naming it, instead of
//! failing later inside a host. The second half, the `@hasDecl` checks, is in `src/app.zig`.

const patchwork = @import("patchwork");

const MissingDraw = struct {
    pub const config: patchwork.app.Config = .{ .title = "missing draw", .timer_period_ms = 0 };

    pub fn init(app: *MissingDraw) void {
        _ = app;
    }

    pub fn layout(app: *MissingDraw, width_logical: u32, height_logical: u32) void {
        _ = app;
        _ = width_logical;
        _ = height_logical;
    }

    pub fn event(app: *MissingDraw, event_value: patchwork.input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }

    pub fn timer(app: *MissingDraw, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }

    pub fn live(app: *const MissingDraw) bool {
        _ = app;
        return false;
    }

    pub fn dirty(app: *const MissingDraw) bool {
        _ = app;
        return false;
    }
};

comptime {
    patchwork.app.check(MissingDraw);
}

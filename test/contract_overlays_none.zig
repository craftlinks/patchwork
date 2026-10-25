//! Negative build test for `ui.overlays`. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "ui.overlays: contract_overlays_none.Bare has no overlay field" (the `expect_errors` string
//! in `build.zig`): drawing the overlays of a target with no `draw_overlay` anywhere fails at
//! build time, naming the target (`src/ui.zig`, section 3b), so an app cannot call it on the
//! wrong value and draw no popup at all.

const patchwork = @import("patchwork");

/// An app with a widget but no popup or tooltip.
const Bare = struct {
    count: u32 = 0,
    knob_value: f32 = 0.5,
};

/// The root of a draw, as `overlays` expects it.
const Root = struct {
    phase: patchwork.ui.cx.Phase = .draw,
    depth: u32 = 1,
};

test "overlays of a target without any draw_overlay" {
    var bare: Bare = .{};
    patchwork.ui.overlays(Root{}, &bare);
}

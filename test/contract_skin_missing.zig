//! Negative build test for the skin contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_skin_missing.Bare: missing `pub fn knob(cx, widgets.KnobLook) ?widgets.Shape`"
//! (the `expect_errors` string in `build.zig`): a skin that lacks the function a widget draws
//! with fails at build time, naming the skin and the function (`src/widgets/skin.zig`,
//! section 2).

const patchwork = @import("patchwork");

/// A skin that skins nothing.
const Bare = struct {};

/// A knob drawn by a skin without `knob`.
const BareKnob = patchwork.widgets.KnobOf(Bare);

comptime {
    _ = BareKnob;
}

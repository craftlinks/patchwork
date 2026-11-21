//! Negative build test for the skin's declarations. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_skin_appends_missing.Bare: missing `pub const knob_appends: widgets.SkinAppends`"
//! (the `expect_errors` string in `build.zig`): a skin function without the declaration of
//! what it appends fails at build time, naming the skin and the declaration
//! (`src/widgets/skin.zig`, section 2b).

const patchwork = @import("patchwork");
const widgets = patchwork.widgets;

/// A skin that draws the knob and does not say what it appends.
const Bare = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        _ = cx;
        return .{ .rect = look.row, .radius = 0 };
    }
};

/// A knob drawn by a skin without `knob_appends`.
const BareKnob = widgets.KnobOf(Bare);

comptime {
    _ = BareKnob;
}

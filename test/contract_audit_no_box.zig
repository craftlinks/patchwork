//! Negative build test for the batch order audit. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "covered_glyphs needs Box in App.config.draw" (the `expect_errors` string in `build.zig`):
//! the audit counts glyphs under boxes, so an app without one of them fails at build time
//! instead of always counting 0 (`src/draw.zig`).

const patchwork = @import("patchwork");
const draw = patchwork.draw;

const glyphs_only = [_]draw.DrawType{.{ .type = draw.Glyph, .cap = 1 }};

test {
    const cx: *const draw.Context(&glyphs_only, 1, 0) = undefined;
    _ = draw.covered_glyphs(cx);
}

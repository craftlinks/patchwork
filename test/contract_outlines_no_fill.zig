//! Negative build test for outline text. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "place_outlines needs draw.Fill in App.config.draw" (the `expect_errors` string in
//! `build.zig`): outline text has no other job, so a draw context without `Fill` fails at build
//! time instead of drawing nothing (`src/text/layout.zig`, section 3b).

const patchwork = @import("patchwork");
const draw = patchwork.draw;
const text = patchwork.text;

const glyphs_only = [_]draw.DrawType{.{ .type = draw.Glyph, .cap = 1 }};

test {
    const cx: *draw.Context(&glyphs_only, 1, 0) = undefined;
    const style: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 20 };
    text.place_outlines(cx, style, "x", rect, clip, .{
        .align_x = .start,
        .align_y = .start,
        .ellipsis = false,
    });
}

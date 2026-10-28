//! `Paragraph`: text wrapped to the width it is given, as tall as its lines.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Contract
//! A paragraph carries one style and points at app-owned bytes (usually a literal) of at most
//! `text.byte_cap`. It is passive like `Label`: it records no area and has no skin. Text with
//! mixed styles (a bold word in a sentence) goes through `text.measure_runs_wrapped` and
//! `text.place_runs_wrapped` directly.
//!
//! ## 2. Height for Width
//! A leaf's walk may not be `fit` (`ui.Context.walk`), but a paragraph's height depends on its
//! width. With `walk.height == .fit` the paragraph peeks the box its width would get, measures
//! the text wrapped to that width (`text.measure_wrapped`), and walks that height as fixed, so
//! the turtle's rule stands and a fit parent sees the real extent. Any other height is walked
//! as given, with the lines from the top, clipped. The width may not be `fit`: there is nothing
//! to wrap to.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const kit = @import("kit.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;

/// Text wrapped to its box's width, in `style`. See the module guide.
pub const Paragraph = struct {
    text: []const u8,
    style: text.Style,
    align_x: text.Align = .start,

    /// Walks `walk` (a `fit` height is the height for the width, section 2) and places the
    /// lines. Returns the box, so an app can anchor to it.
    pub fn draw(self: *const Paragraph, cx: anytype, walk: Walk) Rect {
        assert(self.text.len <= text.byte_cap);
        assert(walk.width != .fit); // a paragraph needs a width to wrap to
        var placed = walk;
        if (walk.height == .fit) {
            const probe: Walk = .{
                .width = walk.width,
                .height = .{ .fixed = 0 },
                .margin = walk.margin,
            };
            const width = cx.peek(probe).width;
            placed.height = .{ .fixed = text.measure_wrapped(self.style, self.text, width) };
        }
        const rect = cx.walk(placed);
        const clip = cx.visible(rect) orelse return rect;
        kit.paragraph(cx, self.style, self.text, rect, clip, .{ .align_x = self.align_x });
        return rect;
    }
};

const testing = std.testing;
const ui = @import("../ui.zig");
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

const mono_10: text.Style = .{ .face = .mono, .size = 10, .color = .{ 1, 1, 1, 1 } };

// Locks height for width (section 2): in a down container 30 px wide, "the quick brown fox" in
// Mono 10 (6 px a codepoint, 14 px lines) wraps to 4 lines, so a fit paragraph walks 56 px and
// the next child starts 56 + 4 (spacing) below it; 16 glyphs are placed.
test "a fit paragraph is as tall as its lines at its width" {
    const cx = fixture.context();
    cx.begin_frame(1280, 720, 120);
    _ = cx.begin(ui.sized(.{ .fixed = 30 }, .{ .fixed = 300 }), .{ .flow = .down, .spacing = 4 });
    const paragraph: Paragraph = .{ .text = "the quick brown fox", .style = mono_10 };
    const rect = paragraph.draw(cx, ui.sized(.fill, .fit));
    const after = cx.walk(ui.sized(.fill, .{ .fixed = 10 }));
    _ = cx.end();
    try testing.expectEqual(@as(f32, 30), rect.width);
    try testing.expectEqual(@as(f32, 56), rect.height);
    try testing.expectEqual(rect.y + 56 + 4, after.y);
    try testing.expectEqual(@as(usize, 16), cx.draw.items(draw.Glyph).len);
    _ = cx.end_frame();
}

// Locks a given height (section 2): a fixed 28 px paragraph keeps 28 px and clips its lines to
// that box, so only the first two lines ("the", "quick": 8 glyphs) are placed.
test "a fixed-height paragraph clips its lines" {
    const cx = fixture.context();
    cx.begin_frame(1280, 720, 120);
    _ = cx.begin(ui.sized(.{ .fixed = 30 }, .{ .fixed = 300 }), .{ .flow = .down, .clip = true });
    const paragraph: Paragraph = .{ .text = "the quick brown fox", .style = mono_10 };
    _ = cx.begin(ui.sized(.fill, .{ .fixed = 28 }), .{ .flow = .down, .clip = true });
    const rect = paragraph.draw(cx, ui.sized(.fill, .fill));
    _ = cx.end();
    _ = cx.end();
    try testing.expectEqual(@as(f32, 28), rect.height);
    try testing.expectEqual(@as(usize, 8), cx.draw.items(draw.Glyph).len);
    _ = cx.end_frame();
}

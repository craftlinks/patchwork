//! `Label`: text centered in its box.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Contract
//! A label carries its own style and points at app-owned bytes (usually a literal) of at most
//! `text.byte_cap`. It is passive: it records no area. Empty text appends nothing.
//!
//! ## 2. Counts
//! `Label.appends_for(bytes)` is what one label of up to `bytes` bytes appends to a frame at
//! most (`widgets/appends.zig`): a glyph a byte, as `text.place` places at most one glyph per
//! codepoint, and no area.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const kit = @import("kit.zig");
const appends = @import("appends.zig");
const Appends = appends.Appends;

const Walk = kit.Walk;

/// Text centered in its box, in `style`. See the module guide.
pub const Label = struct {
    text: []const u8,
    style: text.Style,

    /// What one label of up to `bytes` bytes appends to a frame at most (section 2): a glyph a
    /// byte.
    pub fn appends_for(comptime bytes: u32) Appends {
        comptime {
            assert(bytes <= text.byte_cap);
            const out = appends.text_byte.times(bytes);
            assert(out.areas == 0);
            return out;
        }
    }

    pub fn draw(self: *const Label, cx: anytype, walk: Walk) void {
        assert(self.text.len <= text.byte_cap);
        assert(self.style.color[3] >= 0);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        kit.label(cx, self.style, self.text, rect, clip, kit.centered);
    }
};

const testing = std.testing;
const draw_types = @import("../draw.zig");
const theme = @import("../theme.zig");
const fixture = @import("fixture.zig");

comptime {
    // A label of "WWWW" (section 2): four glyphs, no area.
    assert(Label.appends_for(4).of(draw_types.Glyph) == 4);
    assert(Label.appends_for(4).areas == 0);
}

// Locks `Label.appends_for` (section 2): "WWWW" in a 200 px box draws Glyph 4, no area, nothing
// else and no overflow, reached.
test "Label appends at most appends_for and reaches it" {
    const cx = fixture.context();
    const label: Label = .{ .text = "WWWW", .style = theme.dark.name };
    var tally: fixture.Tally(Label.appends_for("WWWW".len)) = .{};
    fixture.draw_one(cx, &label, fixture.at(0, 0, 200, 40));
    try tally.observe(cx);
    try tally.expect_reached();
    try testing.expectEqual(@as(usize, 4), cx.draw.items(draw_types.Glyph).len);
}

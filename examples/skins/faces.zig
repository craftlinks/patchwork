//! The skins example's faces: the codepoints they keep.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Ranges
//! `build.zig` imports this file and passes `ranges` for the example's five faces
//! (`AppOptions.fonts`): Basic Latin, the degree, micro, and times signs, the en and em
//! dashes, the ellipsis, and the minus sign. Every string the screen shows lies inside them
//! (checked at compile time over `app.zig`'s label tables). Each face claims them as its own, so a
//! face without one of these glyphs fails the build naming the face and the codepoint.
//! `fonts/` holds Noto Sans Medium, Noto Sans Mono Bold, and Noto Sans Mono Light already cut
//! to these ranges; the two serif faces are the session example's, cut to a wider range that
//! holds these. This file depends on nothing but `std`, because the build runner compiles it
//! too.
//!
//! ## 2. TigerStyle Invariants
//! - The ranges are increasing and apart (the comptime block), as `subset.check_faces` needs.

const std = @import("std");

pub const ranges = [_][2]u21{
    .{ 0x0020, 0x007E }, .{ 0x00B0, 0x00B0 }, .{ 0x00B5, 0x00B5 }, .{ 0x00D7, 0x00D7 },
    .{ 0x2013, 0x2014 }, .{ 0x2026, 0x2026 }, .{ 0x2212, 0x2212 },
};

/// True when every codepoint of `utf8` lies inside `ranges`.
pub fn covers(utf8: []const u8) bool {
    var view = std.unicode.Utf8View.init(utf8) catch return false;
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (!inside(codepoint)) return false;
    }
    return true;
}

fn inside(codepoint: u21) bool {
    for (ranges) |range| {
        if (codepoint >= range[0] and codepoint <= range[1]) return true;
    }
    return false;
}

comptime {
    std.debug.assert(ranges.len == 7);
    for (ranges[1..], ranges[0 .. ranges.len - 1]) |range, before| {
        std.debug.assert(range[0] <= range[1]);
        std.debug.assert(range[0] > before[1] + 1);
    }
}

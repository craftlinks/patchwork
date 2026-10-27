//! The gallery's icons: named Lucide codepoints and the ranges its icon face keeps.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Source
//! `fonts/lucide.ttf` is the TrueType build of lucide-static 1.55.0 (ISC, `fonts/LICENSE`),
//! with every icon in the Private Use Area. The codepoints below come from that release's
//! `font/codepoints.json`; a later release may move them, so the font and this list change
//! together.
//!
//! ## 2. Ranges
//! `build.zig` imports this file and passes `ranges` as the `icons` face's ranges
//! (`AppOptions.fonts`), so the build subsets the 917 KB face to exactly the icons below. The
//! ranges are `all` with consecutive codepoints merged: increasing and apart, as `addApp`
//! requires. This file depends on nothing but `std`, because the build runner compiles it too.

const std = @import("std");
const assert = std.debug.assert;

pub const play: u21 = 0xE13C;
pub const pause: u21 = 0xE12E;
pub const stop: u21 = 0xE167; // square
pub const record: u21 = 0xE076; // circle
pub const loop: u21 = 0xE146; // repeat
pub const skip_back: u21 = 0xE15F;
pub const skip_forward: u21 = 0xE160;
pub const volume: u21 = 0xE1AB; // volume-2
pub const settings: u21 = 0xE154;
pub const folder_open: u21 = 0xE247;
pub const save: u21 = 0xE14D;
pub const plus: u21 = 0xE13D;
pub const minus: u21 = 0xE11C;
pub const close: u21 = 0xE1B2; // x

/// Every icon the gallery draws, in its icon set's order.
pub const all = [_]u21{
    play,   pause,    stop,        record, loop, skip_back, skip_forward,
    volume, settings, folder_open, save,   plus, minus,     close,
};

/// The codepoints the `icons` face keeps (section 2).
pub const ranges: [range_count][2]u21 = merged: {
    var list: [range_count][2]u21 = undefined;
    const sorted = sorted_all();
    var count: u32 = 0;
    for (sorted, 0..) |codepoint, index| {
        if (index > 0 and codepoint == sorted[index - 1] + 1) {
            list[count - 1][1] = codepoint;
        } else {
            list[count] = .{ codepoint, codepoint };
            count += 1;
        }
    }
    assert(count == range_count);
    break :merged list;
};

/// Runs of consecutive codepoints in `all`.
const range_count: u32 = counted: {
    const sorted = sorted_all();
    var count: u32 = 0;
    for (sorted, 0..) |codepoint, index| {
        if (index == 0 or codepoint != sorted[index - 1] + 1) count += 1;
    }
    break :counted count;
};

fn sorted_all() [all.len]u21 {
    var sorted = all;
    std.mem.sort(u21, &sorted, {}, std.sort.asc(u21));
    return sorted;
}

comptime {
    assert(all.len == 14);
    for (all, 0..) |codepoint, index| {
        assert(codepoint >= 0xE000 and codepoint <= 0xF8FF);
        for (all[0..index]) |before| assert(before != codepoint);
    }
}

// Locks the ranges (section 2): they increase and are apart, and they cover exactly the 14
// icons: play and plus, and skip-back and skip-forward, are adjacent, so 12 ranges.
test "the ranges cover exactly the icons" {
    try std.testing.expectEqual(@as(usize, 12), ranges.len);
    var covered: u32 = 0;
    for (ranges, 0..) |range, index| {
        try std.testing.expect(range[0] <= range[1]);
        if (index > 0) try std.testing.expect(range[0] > ranges[index - 1][1] + 1);
        covered += range[1] - range[0] + 1;
    }
    try std.testing.expectEqual(@as(u32, all.len), covered);
    for (all) |codepoint| {
        var inside = false;
        for (ranges) |range| inside = inside or (codepoint >= range[0] and codepoint <= range[1]);
        try std.testing.expect(inside);
    }
}

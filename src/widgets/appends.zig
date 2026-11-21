//! Appends: what a widget or a skin function adds to one frame at most.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Counts
//! The pools are fixed at startup from the app's comptime config (`config.draw` caps,
//! `point_cap`, `area_cap`), and each number is a sum over widgets of what each appends in a
//! frame. An undercount shows only as `overflow()` above zero and missing pieces. `Appends`
//! says what one part appends at most, keyed by draw type the way `draw.DrawType` is
//! (`{ type, count }` beside `{ type, cap }`), plus path points and hit areas, so an app sums
//! them instead of reading skins.
//!
//! ## 2. Operations
//! ```text
//! of(T)        the count for T, 0 when it is not named
//! plus(other)  both in one frame: counts added by type
//! times(n)     n of these in one frame
//! max(other)   the larger of each count: a frame draws one or the other
//! ```
//! `plus` and `max` keep `self`'s types in order and then add the types only `other` names, so
//! results are deterministic. `times(0)` keeps the type list with zero counts, and a count of
//! 0 stays in the list. A type an app does not register is legal: `of` reads only the types
//! the app asks for, so a skin may name `draw.Path` or `draw.Glass` beside its fallbacks.
//!
//! ## 3. Skin Declarations
//! `SkinAppends` is what one call of a skin function appends at most (`widgets/skin.zig`,
//! section 2b): `fixed`, besides its look's text, and `per_byte`, per byte of that text. The
//! default `per_byte` is `text_byte`, one `draw.Glyph`: text places at most one glyph per
//! codepoint, and a codepoint is at least one byte. `with(bytes)` is one call with `bytes` of
//! text in its look.
//!
//! ## 4. TigerStyle Invariants
//! - Every value is comptime-only: it holds `type`.
//! - Each type appears at most once in `draws`; the operations keep it so, and
//!   `widgets.skins.check` refuses a declaration that names one twice.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");

/// One draw type's instances.
pub const Count = struct { type: type, count: u32 };

/// What a widget appends to one frame at most (module guide): instances per draw type, path
/// points (`config.point_cap`), and hit areas (`config.area_cap`). A type it does not name is
/// 0. Each type appears at most once in `draws`.
pub const Appends = struct {
    draws: []const Count = &.{},
    points: u32 = 0,
    areas: u32 = 0,

    /// The count for draw type `T`, 0 when `draws` does not name it.
    pub fn of(comptime self: Appends, comptime T: type) u32 {
        comptime {
            assert(repeated(self.draws) == null);
            for (self.draws) |entry| {
                if (entry.type == T) return entry.count;
            }
            return 0;
        }
    }

    /// Both together, merged by type: what two widgets in one frame append.
    pub fn plus(comptime self: Appends, comptime other: Appends) Appends {
        comptime {
            const draws = merged(self.draws, other.draws, .sum);
            const out: Appends = .{
                .draws = draws,
                .points = self.points + other.points,
                .areas = self.areas + other.areas,
            };
            assert(out.draws.len >= self.draws.len);
            assert(out.draws.len >= other.draws.len);
            return out;
        }
    }

    /// `n` of these in one frame.
    pub fn times(comptime self: Appends, comptime n: u32) Appends {
        comptime {
            var draws: [self.draws.len]Count = undefined;
            for (self.draws, &draws) |entry, *scaled| {
                scaled.* = .{ .type = entry.type, .count = entry.count * n };
            }
            const fixed = draws;
            const out: Appends = .{
                .draws = &fixed,
                .points = self.points * n,
                .areas = self.areas * n,
            };
            assert(out.draws.len == self.draws.len);
            assert(out.areas == self.areas * n);
            return out;
        }
    }

    /// The larger of each count: the bound for two parts of which a frame draws one (a number
    /// box's face or its editor).
    pub fn max(comptime self: Appends, comptime other: Appends) Appends {
        comptime {
            const draws = merged(self.draws, other.draws, .max);
            const out: Appends = .{
                .draws = draws,
                .points = @max(self.points, other.points),
                .areas = @max(self.areas, other.areas),
            };
            assert(out.points >= self.points);
            assert(out.areas >= other.areas);
            return out;
        }
    }
};

/// A skin function's declaration (`widgets/skin.zig`, section 2b): what one call appends at
/// most besides its look's text, and what it appends per byte of that text.
pub const SkinAppends = struct {
    fixed: Appends = .{},
    /// Default: one `draw.Glyph` per byte, what `kit.label` and `text.place` append at most.
    per_byte: Appends = text_byte,

    /// One call with `bytes` bytes of text in its look: `fixed` plus `per_byte` times `bytes`.
    pub fn with(comptime self: SkinAppends, comptime bytes: u32) Appends {
        comptime {
            const out = self.fixed.plus(self.per_byte.times(bytes));
            assert(out.areas == self.fixed.areas + self.per_byte.areas * bytes);
            assert(out.points == self.fixed.points + self.per_byte.points * bytes);
            return out;
        }
    }
};

/// One `draw.Glyph`: what a byte of text appends at most (module guide, section 3).
pub const text_byte: Appends = .{ .draws = &.{.{ .type = draw.Glyph, .count = 1 }} };

/// The first type `draws` names twice, or null.
pub fn repeated(comptime draws: []const Count) ?type {
    comptime {
        for (draws, 0..) |entry, index| {
            for (draws[index + 1 ..]) |later| {
                if (later.type == entry.type) return entry.type;
            }
        }
        return null;
    }
}

/// How `merged` combines a type both lists name.
const Merge = enum { sum, max };

/// `first`'s entries in order, each combined with `second`'s count of its type, then the
/// entries only `second` names, in its order.
fn merged(
    comptime first: []const Count,
    comptime second: []const Count,
    comptime how: Merge,
) []const Count {
    comptime {
        assert(repeated(first) == null);
        assert(repeated(second) == null);
        var out: [first.len + second.len]Count = undefined;
        var count: usize = 0;
        for (first) |entry| {
            const other = count_of(second, entry.type);
            const combined = switch (how) {
                .sum => entry.count + other,
                .max => @max(entry.count, other),
            };
            out[count] = .{ .type = entry.type, .count = combined };
            count += 1;
        }
        for (second) |entry| {
            if (names(first, entry.type)) continue;
            out[count] = entry;
            count += 1;
        }
        // The result is copied into a constant before its address escapes the block.
        const result = out[0..count].*;
        assert(repeated(&result) == null);
        return &result;
    }
}

/// True when `draws` names `T`.
fn names(comptime draws: []const Count, comptime T: type) bool {
    comptime {
        for (draws) |entry| {
            if (entry.type == T) return true;
        }
        return false;
    }
}

/// `T`'s count in `draws`, 0 when it is not named.
fn count_of(comptime draws: []const Count, comptime T: type) u32 {
    comptime {
        for (draws) |entry| {
            if (entry.type == T) return entry.count;
        }
        return 0;
    }
}

comptime {
    assert(text_byte.of(draw.Glyph) == 1);
    assert(text_byte.of(draw.Box) == 0);
    assert(text_byte.points == 0);
    assert(text_byte.areas == 0);
}

const testing = std.testing;

/// {Box 1, Glyph 24} and {Box 3, Glyph 24}: a number box's face and its editor.
const face: Appends = .{ .draws = &.{
    .{ .type = draw.Box, .count = 1 },
    .{ .type = draw.Glyph, .count = 24 },
} };
const editor: Appends = .{ .draws = &.{
    .{ .type = draw.Box, .count = 3 },
    .{ .type = draw.Glyph, .count = 24 },
}, .areas = 1 };

// Locks `of` (section 2): Box 1 and Glyph 24 are read back, an absent type (Arc) is 0.
test "of reads a named type and 0 for an absent one" {
    try testing.expectEqual(@as(u32, 1), comptime face.of(draw.Box));
    try testing.expectEqual(@as(u32, 24), comptime face.of(draw.Glyph));
    try testing.expectEqual(@as(u32, 0), comptime face.of(draw.Arc));
    try testing.expectEqual(@as(u32, 0), comptime (Appends{}).of(draw.Box));
}

// Locks `plus` (section 2): Box 1 plus {Box 2, Arc 1, points 3, area 1} is Box 3 then Arc 1,
// in that order, points 3 and area 1; a type only the second names keeps its count.
test "plus merges by type and keeps the order" {
    const one: Appends = .{ .draws = &.{.{ .type = draw.Box, .count = 1 }} };
    const two: Appends = .{ .draws = &.{
        .{ .type = draw.Box, .count = 2 },
        .{ .type = draw.Arc, .count = 1 },
    }, .points = 3, .areas = 1 };
    const sum = comptime one.plus(two);
    try testing.expectEqual(@as(usize, 2), sum.draws.len);
    try testing.expect(sum.draws[0].type == draw.Box);
    try testing.expect(sum.draws[1].type == draw.Arc);
    try testing.expectEqual(@as(u32, 3), comptime sum.of(draw.Box));
    try testing.expectEqual(@as(u32, 1), comptime sum.of(draw.Arc));
    try testing.expectEqual(@as(u32, 3), sum.points);
    try testing.expectEqual(@as(u32, 1), sum.areas);
    const reverse = comptime two.plus(one);
    try testing.expect(reverse.draws[0].type == draw.Box);
    try testing.expectEqual(@as(u32, 3), comptime reverse.of(draw.Box));
}

// Locks `times` (section 2): the editor times 3 is Box 9, Glyph 72, areas 3; times 0 keeps
// both types at 0 and the order.
test "times scales every count and keeps the types at zero" {
    const three = comptime editor.times(3);
    try testing.expectEqual(@as(u32, 9), comptime three.of(draw.Box));
    try testing.expectEqual(@as(u32, 72), comptime three.of(draw.Glyph));
    try testing.expectEqual(@as(u32, 3), three.areas);
    const none = comptime editor.times(0);
    try testing.expectEqual(@as(usize, 2), none.draws.len);
    try testing.expect(none.draws[1].type == draw.Glyph);
    try testing.expectEqual(@as(u32, 0), none.draws[0].count);
    try testing.expectEqual(@as(u32, 0), none.draws[1].count);
    try testing.expectEqual(@as(u32, 0), none.areas);
}

// Locks `max` (section 2): {Box 1, Glyph 24} and {Box 3, Glyph 24, area 1} give {Box 3,
// Glyph 24, area 1}, Box first.
test "max takes the larger of each count" {
    const most = comptime face.max(editor);
    try testing.expectEqual(@as(usize, 2), most.draws.len);
    try testing.expect(most.draws[0].type == draw.Box);
    try testing.expectEqual(@as(u32, 3), comptime most.of(draw.Box));
    try testing.expectEqual(@as(u32, 24), comptime most.of(draw.Glyph));
    try testing.expectEqual(@as(u32, 1), most.areas);
}

// Locks `with` (section 3): the default `per_byte` adds Glyph 5 to a fixed Box 1; an empty
// `per_byte` (an icon skin) adds nothing.
test "with adds the text's bytes" {
    const button: SkinAppends = .{ .fixed = .{ .draws = &.{.{ .type = draw.Box, .count = 1 }} } };
    const five = comptime button.with(5);
    try testing.expectEqual(@as(u32, 1), comptime five.of(draw.Box));
    try testing.expectEqual(@as(u32, 5), comptime five.of(draw.Glyph));
    const icon: SkinAppends = .{ .fixed = face, .per_byte = .{} };
    try testing.expectEqual(@as(u32, 24), comptime icon.with(3).of(draw.Glyph));
}

// Locks `repeated`: Box named twice is found; distinct types give null.
test "repeated finds a type named twice" {
    const twice = [_]Count{
        .{ .type = draw.Box, .count = 1 },
        .{ .type = draw.Arc, .count = 1 },
        .{ .type = draw.Box, .count = 2 },
    };
    try testing.expect(comptime repeated(&twice).? == draw.Box);
    try testing.expect(comptime repeated(face.draws) == null);
}

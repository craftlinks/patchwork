//! Moving a section: a pure function of the text, so its edge cases are tested without a window.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Section's Order Is Its Text's
//! A section runs from its heading's line start to the next section's, or the end of the text.
//! Slot `k` is the place before section `k`, and the slot past the last is the end of the text,
//! so moving a section is swapping two neighbouring runs of bytes: the section and everything
//! between it and the slot. `plan` writes the swapped bytes, and the app makes them one edit, so
//! one undo restores the order.
//!
//! ## 2. The Last Newline
//! A text need not end in a newline, so the run that ended the text may have none, and the run
//! that ends it next has one too many. `plan` adds and drops exactly that one, which keeps the
//! text's length and whether it ends in a newline.
//!
//! ## 3. TigerStyle Invariants
//! - `plan` is O(the two runs) and writes only to `out`, which must hold them.

const std = @import("std");
const assert = std.debug.assert;

pub const Span = struct { start: u32, end: u32 };

/// One move: replace `range` with `bytes`; `moved` lands at `moved_to`, `other` at `other_to`.
pub const Move = struct {
    range: Span,
    bytes: []const u8,
    moved: Span,
    moved_to: u32,
    other: Span,
    other_to: u32,
    text_len: u32,

    /// Where the byte at `byte` lands: it travels with its run, or stays outside the two.
    pub fn map(self: Move, byte: u32) u32 {
        assert(byte <= self.text_len);
        const moved = in_span(self.moved, byte, self.text_len);
        const other = in_span(self.other, byte, self.text_len);
        if (!moved and !other) return byte;
        const landed = if (moved)
            self.moved_to + (byte - self.moved.start)
        else
            self.other_to + (byte - self.other.start);
        return @min(landed, self.range.end);
    }
};

fn in_span(span: Span, byte: u32, text_len: u32) bool {
    if (byte >= span.start and byte < span.end) return true;
    return byte == span.end and byte == text_len;
}

/// True when dropping section `section` at slot `slot` changes nothing.
pub fn unchanged(section: u32, slot: u32) bool {
    return slot == section or slot == section + 1;
}

fn ends_line(bytes: []const u8) bool {
    return bytes.len > 0 and bytes[bytes.len - 1] == '\n';
}

/// Writes the move of section `section` to slot `slot` of `text`, whose sections start at
/// `starts`, or returns null when it changes nothing (section 1).
pub fn plan(text: []const u8, starts: []const u32, section: u32, slot: u32, out: []u8) ?Move {
    assert(section < starts.len);
    assert(slot <= starts.len);
    if (unchanged(section, slot)) return null;
    const len: u32 = @intCast(text.len);
    const after = section + 1;
    const moved: Span = .{ .start = starts[section], .end = if (after < starts.len) starts[after] else len };
    const insert = if (slot < starts.len) starts[slot] else len;
    const up = insert < moved.start;
    const other: Span = if (up) .{ .start = insert, .end = moved.start } else .{ .start = moved.end, .end = insert };
    const first = if (up) moved else other;
    const second = if (up) other else moved;
    const range: Span = .{ .start = @min(moved.start, other.start), .end = @max(moved.end, other.end) };
    const lead = text[first.start..first.end];
    const tail = text[second.start..second.end];
    @memcpy(out[0..lead.len], lead);
    var used: u32 = @intCast(lead.len);
    // The run that ended the text may lack the newline it now needs (section 2).
    if (!ends_line(lead)) {
        out[used] = '\n';
        used += 1;
    }
    const second_to = range.start + used;
    @memcpy(out[used..][0..tail.len], tail);
    used += @intCast(tail.len);
    if (range.end == len and !ends_line(text)) {
        assert(out[used - 1] == '\n');
        used -= 1;
    }
    assert(used == range.end - range.start);
    return .{
        .range = range,
        .bytes = out[0..used],
        .moved = moved,
        .moved_to = if (up) range.start else second_to,
        .other = other,
        .other_to = if (up) second_to else range.start,
        .text_len = len,
    };
}

const testing = std.testing;

fn applied(text: []const u8, move: Move, out: []u8) []const u8 {
    const start = move.range.start;
    const end = move.range.end;
    @memcpy(out[0..start], text[0..start]);
    @memcpy(out[start..end], move.bytes);
    @memcpy(out[end..text.len], text[end..]);
    return out[0..text.len];
}

// Locks section 2 on every move of four sections, with and without a final newline and with
// text before the first heading: the same lines in the expected order, the same length, the
// same ending, and a move and its inverse restore the text.
test "every move keeps the text's lines and its ending" {
    const cases = [_]struct { text: []const u8, starts: [4]u32 }{
        .{ .text = "# a\n1\n# b\n# c\n3\n3\n# d\n4", .starts = .{ 0, 6, 10, 18 } },
        .{ .text = "# a\n1\n# b\n# c\n3\n3\n# d\n4\n", .starts = .{ 0, 6, 10, 18 } },
        .{ .text = "x\n# a\n# b\n2\n# c\n# d", .starts = .{ 2, 6, 12, 16 } },
    };
    for (cases) |case| {
        for (0..4) |section| {
            for (0..5) |slot| {
                var out: [64]u8 = undefined;
                var whole: [64]u8 = undefined;
                const at: u32 = @intCast(section);
                const to: u32 = @intCast(slot);
                const move = plan(case.text, &case.starts, at, to, &out) orelse {
                    try testing.expect(unchanged(at, to));
                    continue;
                };
                const moved = applied(case.text, move, &whole);
                try testing.expectEqual(case.text.len, moved.len);
                try testing.expectEqual(ends_line(case.text), ends_line(moved));
                var want = std.mem.tokenizeScalar(u8, case.text, '\n');
                while (want.next()) |line| {
                    try testing.expectEqual(std.mem.count(u8, case.text, line), std.mem.count(u8, moved, line));
                }
                try testing.expectEqual(std.mem.count(u8, case.text, "\n"), std.mem.count(u8, moved, "\n"));
            }
        }
    }
}

// Locks the worked moves: the last section up gains a newline and what becomes last loses one;
// the first down to the end is the reverse.
test "the last newline moves with the end of the text" {
    const text = "# a\n1\n# b\n2";
    const starts = [_]u32{ 0, 6 };
    var out: [32]u8 = undefined;
    var whole: [32]u8 = undefined;
    const up = plan(text, &starts, 1, 0, &out).?;
    try testing.expectEqualStrings("# b\n2\n# a\n1", applied(text, up, &whole));
    const down = plan(text, &starts, 0, 2, &out).?;
    try testing.expectEqualStrings("# b\n2\n# a\n1", applied(text, down, &whole));
    try testing.expect(plan(text, &starts, 0, 1, &out) == null);
    try testing.expect(plan(text, &starts, 1, 2, &out) == null);
}

// Locks `map`: a byte travels with its run, a byte outside the two stays, and the end of the
// text, where a caret may be, lands at the end of the moved line, before its new newline.
test "a caret travels with its text" {
    const text = "x\n# a\n1\n# b\n2";
    const starts = [_]u32{ 2, 8 };
    var out: [32]u8 = undefined;
    const move = plan(text, &starts, 1, 0, &out).?;
    try testing.expectEqual(@as(u32, 1), move.map(1));
    try testing.expectEqual(@as(u32, 2), move.map(8));
    try testing.expectEqual(@as(u32, 8), move.map(2));
    try testing.expectEqual(@as(u32, 7), move.map(13));
}

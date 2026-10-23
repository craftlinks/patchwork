//! The editing core of a single-line text field: a bounded UTF-8 buffer with a caret and a
//! selection, codepoint and word movement, and paste sanitizing (one line, or multi-line for
//! the code editor). Pure: no context, no drawing.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Contiguous Buffer
//! A field holds at most `field_cap` (256) bytes, so an insert or delete is one `memmove` of
//! at most 256 bytes, as cheap as moving a gap, and the text stays one slice for `text.place`,
//! `text.measure`, and `copy`. The gap buffer belongs to the multi-line editor (step 17),
//! where texts are large.
//!
//! ## 2. Invariants
//! `bytes[0..len]` is valid UTF-8 (inserts take only valid UTF-8; `sanitize_line` makes pasted
//! text so), `len <= limit <= field_cap`, and `caret` and `anchor` are codepoint boundaries in
//! `0..len`. The selection is the byte range between `anchor` and `caret`; it is empty when
//! they are equal. Every mutator asserts the invariants on exit (`check`).
//!
//! ## 3. Words
//! A codepoint is a word codepoint when it is an ASCII letter, digit, or `_`, or any
//! non-ASCII codepoint (so accented words stay whole); everything else separates words.
//! - `word_right` skips separators, then word codepoints: it lands at the end of the next word.
//! - `word_left` skips separators backward, then word codepoints: the start of the word.
//! - `word_around` (a double click) is the run of codepoints of the same class as the one at
//!   the index, so a double click on a space selects the run of separators.
//!
//! ## 4. Paste
//! `sanitize_line` turns arbitrary pasted bytes into one line: a CR LF pair or a lone CR, LF,
//! or tab becomes one space, other C0 controls and DEL are dropped, and invalid UTF-8 becomes
//! U+FFFD. Output stops at the last whole codepoint that fits.
//!
//! ## 4a. Multi-Line Text
//! `sanitize_text` is the code editor's counterpart (`editor.zig`): line breaks survive as LF
//! (a CR LF pair or a lone CR becomes one LF), a tab expands to spaces up to the next
//! multiple of `tab_width` from the column the text lands at, other controls are dropped,
//! and invalid UTF-8 becomes U+FFFD. The editor's buffer therefore never holds a tab or a
//! CR, so a column is always a codepoint count. The editor's buffer reuses this file's
//! boundary and word functions directly on its one contiguous slice.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation; every loop is bounded by `field_cap` or the input length.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const layout = @import("../text/layout.zig");

/// Bytes one field holds.
pub const field_cap: u32 = 256;

/// A byte range `start .. end` of the text.
pub const Range = struct {
    start: u32,
    end: u32,
};

pub const Direction = enum {
    backward,
    forward,
};

/// The buffer, caret, and selection of one field. See the module guide, section 2.
pub const Edit = struct {
    bytes: [field_cap]u8,
    len: u32,
    caret: u32,
    anchor: u32,
    /// Most bytes the text may hold, at most `field_cap`.
    limit: u32,

    /// Empty, holding at most `limit` bytes.
    pub fn init(limit: u32) Edit {
        assert(limit >= 1);
        assert(limit <= field_cap);
        const edit: Edit = .{
            .bytes = @splat(0),
            .len = 0,
            .caret = 0,
            .anchor = 0,
            .limit = limit,
        };
        edit.check();
        return edit;
    }

    /// The text.
    pub fn text(self: *const Edit) []const u8 {
        assert(self.len <= self.limit);
        return self.bytes[0..self.len];
    }

    /// Replaces the text with `utf8` (valid UTF-8, cut on a codepoint boundary at `limit`) and
    /// puts the caret at its end with nothing selected.
    pub fn set(self: *Edit, utf8: []const u8) void {
        const length = input.utf8_prefix(utf8, self.limit);
        @memcpy(self.bytes[0..length], utf8[0..length]);
        self.len = length;
        self.caret = length;
        self.anchor = length;
        self.check();
    }

    /// The selected range, ordered.
    pub fn selection(self: *const Edit) Range {
        self.check();
        return .{ .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
    }

    pub fn has_selection(self: *const Edit) bool {
        assert(self.caret <= self.len);
        return self.caret != self.anchor;
    }

    /// The selected text.
    pub fn selected(self: *const Edit) []const u8 {
        const range = self.selection();
        return self.bytes[range.start..range.end];
    }

    pub fn select_all(self: *Edit) void {
        self.anchor = 0;
        self.caret = self.len;
        self.check();
    }

    /// Selects the word, or the run of separators, at `index` (section 3).
    pub fn select_word(self: *Edit, index: u32) void {
        assert(index <= self.len);
        const range = word_around(self.text(), index);
        self.anchor = range.start;
        self.caret = range.end;
        self.check();
    }

    /// Moves the caret to `index`, a boundary; `extend` keeps the anchor, else the selection
    /// collapses.
    pub fn move_to(self: *Edit, index: u32, extend: bool) void {
        assert(index <= self.len);
        assert(is_boundary(self.text(), index));
        self.caret = index;
        if (!extend) self.anchor = index;
        self.check();
    }

    /// Replaces the selection with `utf8` (valid UTF-8), cut on a codepoint boundary to the
    /// room under `limit`. Returns true when the text changed.
    pub fn insert(self: *Edit, utf8: []const u8) bool {
        const removed = self.delete_selection();
        const room = self.limit - self.len;
        const length = input.utf8_prefix(utf8, room);
        if (length == 0) return removed;
        const at = self.caret;
        std.mem.copyBackwards(u8, self.bytes[at + length .. self.len + length], self.text()[at..]);
        @memcpy(self.bytes[at..][0..length], utf8[0..length]);
        self.len += length;
        self.caret = at + length;
        self.anchor = self.caret;
        self.check();
        return true;
    }

    /// Deletes the selection, or else one codepoint (or one word when `word`) in `direction`.
    /// Returns true when the text changed.
    pub fn erase(self: *Edit, direction: Direction, word: bool) bool {
        if (self.has_selection()) return self.delete_selection();
        const bytes = self.text();
        const target = switch (direction) {
            .backward => if (word) word_left(bytes, self.caret) else prev_boundary(
                bytes,
                self.caret,
            ),
            .forward => if (word) word_right(bytes, self.caret) else next_boundary(
                bytes,
                self.caret,
            ),
        };
        if (target == self.caret) return false;
        self.anchor = target;
        return self.delete_selection();
    }

    /// Deletes the selected bytes. Returns true when something was selected.
    pub fn delete_selection(self: *Edit) bool {
        const range = self.selection();
        if (range.start == range.end) return false;
        const removed = range.end - range.start;
        std.mem.copyForwards(u8, self.bytes[range.start..], self.bytes[range.end..self.len]);
        self.len -= removed;
        self.caret = range.start;
        self.anchor = range.start;
        self.check();
        return true;
    }

    fn check(self: *const Edit) void {
        assert(self.limit <= field_cap);
        assert(self.len <= self.limit);
        assert(self.caret <= self.len);
        assert(self.anchor <= self.len);
        assert(is_boundary(self.bytes[0..self.len], self.caret));
        assert(is_boundary(self.bytes[0..self.len], self.anchor));
    }
};

/// True when `index` is 0, the end, or the start of a codepoint of `bytes`.
pub fn is_boundary(bytes: []const u8, index: u32) bool {
    assert(index <= bytes.len);
    if (index == bytes.len) return true;
    return bytes[index] & 0xC0 != 0x80;
}

/// The boundary after the codepoint at `index`, or `index` at the end.
pub fn next_boundary(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    if (index == bytes.len) return index;
    var next = index + 1;
    while (next < bytes.len and !is_boundary(bytes, next)) next += 1;
    assert(next <= index + 4);
    return next;
}

/// The boundary before the codepoint that ends at `index`, or 0 at the start.
pub fn prev_boundary(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    if (index == 0) return 0;
    var previous = index - 1;
    while (previous > 0 and !is_boundary(bytes, previous)) previous -= 1;
    assert(previous + 4 >= index);
    return previous;
}

/// True when the codepoint led by `lead` belongs to a word (section 3).
pub fn is_word(lead: u8) bool {
    if (lead >= 0x80) return true;
    if (lead == '_') return true;
    return std.ascii.isAlphanumeric(lead);
}

/// The end of the next word after `index` (section 3).
pub fn word_right(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var at = index;
    while (at < bytes.len and !is_word(bytes[at])) at = next_boundary(bytes, at);
    while (at < bytes.len and is_word(bytes[at])) at = next_boundary(bytes, at);
    assert(at >= index);
    return at;
}

/// The start of the word before `index` (section 3).
pub fn word_left(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    var at = index;
    while (at > 0 and !is_word(bytes[prev_boundary(bytes, at)])) at = prev_boundary(bytes, at);
    while (at > 0 and is_word(bytes[prev_boundary(bytes, at)])) at = prev_boundary(bytes, at);
    assert(at <= index);
    return at;
}

/// The run of codepoints of the class of the one at `index` (the one before it at the end).
pub fn word_around(bytes: []const u8, index: u32) Range {
    assert(index <= bytes.len);
    if (bytes.len == 0) return .{ .start = 0, .end = 0 };
    const probe = if (index == bytes.len) prev_boundary(bytes, index) else index;
    const word = is_word(bytes[probe]);
    var start = probe;
    while (start > 0 and is_word(bytes[prev_boundary(bytes, start)]) == word) {
        start = prev_boundary(bytes, start);
    }
    var end = next_boundary(bytes, probe);
    while (end < bytes.len and is_word(bytes[end]) == word) end = next_boundary(bytes, end);
    assert(start <= probe);
    assert(end > probe);
    return .{ .start = start, .end = end };
}

/// Writes `source` into `out` as one line of valid UTF-8 (section 4). Returns the bytes
/// written.
pub fn sanitize_line(source: []const u8, out: []u8) u32 {
    var written: u32 = 0;
    var index: u32 = 0;
    while (index < source.len) {
        const start = index;
        const codepoint = layout.decode(source, &index);
        if (codepoint == '\r' and index < source.len and source[index] == '\n') index += 1;
        const mapped: u21 = switch (codepoint) {
            '\r', '\n', '\t' => ' ',
            else => codepoint,
        };
        if (!input.printable(mapped)) continue;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(mapped, &encoded) catch unreachable;
        if (written + length > out.len) break;
        @memcpy(out[written..][0..length], encoded[0..length]);
        written += length;
        assert(index > start);
    }
    assert(written <= out.len);
    return written;
}

/// Columns between tab stops: a tab becomes spaces up to the next multiple.
pub const tab_width: u32 = 4;

/// What `sanitize_text` wrote: `len` bytes, and whether all of `source` fit.
pub const Sanitized = struct {
    len: u32,
    complete: bool,
};

/// Writes `source` into `out` as multi-line valid UTF-8 for the code editor (section 4a): a CR
/// LF pair or a lone CR becomes LF, a tab becomes spaces up to the next multiple of
/// `tab_width` counted from `column` (the codepoint column the text lands at), other C0
/// controls and DEL are dropped, and invalid UTF-8 becomes U+FFFD. Output stops at the last
/// whole codepoint (or whole tab expansion) that fits, and `complete` is false then.
pub fn sanitize_text(source: []const u8, column: u32, out: []u8) Sanitized {
    var written: u32 = 0;
    var index: u32 = 0;
    var at_column = column;
    while (index < source.len) {
        const start = index;
        var codepoint = layout.decode(source, &index);
        if (codepoint == '\r') {
            if (index < source.len and source[index] == '\n') index += 1;
            codepoint = '\n';
        }
        assert(index > start);
        if (codepoint == '\n') {
            if (written + 1 > out.len) return .{ .len = written, .complete = false };
            out[written] = '\n';
            written += 1;
            at_column = 0;
            continue;
        }
        if (codepoint == '\t') {
            const spaces = tab_width - at_column % tab_width;
            if (written + spaces > out.len) return .{ .len = written, .complete = false };
            @memset(out[written..][0..spaces], ' ');
            written += spaces;
            at_column += spaces;
            continue;
        }
        if (!input.printable(codepoint)) continue;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
        if (written + length > out.len) return .{ .len = written, .complete = false };
        @memcpy(out[written..][0..length], encoded[0..length]);
        written += length;
        at_column += 1;
    }
    assert(written <= out.len);
    assert(index == source.len);
    return .{ .len = written, .complete = true };
}

const testing = std.testing;

fn edit_of(utf8: []const u8) Edit {
    var edit = Edit.init(field_cap);
    edit.set(utf8);
    return edit;
}

// Locks codepoint boundaries: movement steps over whole two-, three-, and four-byte sequences
// and stops at both ends.
test "boundaries step over whole UTF-8 sequences" {
    const bytes = "a\u{e4}\u{20ac}\u{1f3b9}";
    try testing.expectEqual(@as(u32, 1), next_boundary(bytes, 0));
    try testing.expectEqual(@as(u32, 3), next_boundary(bytes, 1));
    try testing.expectEqual(@as(u32, 6), next_boundary(bytes, 3));
    try testing.expectEqual(@as(u32, 10), next_boundary(bytes, 6));
    try testing.expectEqual(@as(u32, 10), next_boundary(bytes, 10));
    try testing.expectEqual(@as(u32, 6), prev_boundary(bytes, 10));
    try testing.expectEqual(@as(u32, 1), prev_boundary(bytes, 3));
    try testing.expectEqual(@as(u32, 0), prev_boundary(bytes, 0));
    try testing.expect(!is_boundary(bytes, 2));
    var edit = edit_of(bytes);
    try testing.expect(edit.erase(.backward, false));
    try testing.expectEqualStrings("a\u{e4}\u{20ac}", edit.text());
    edit.move_to(1, false);
    try testing.expect(edit.erase(.forward, false));
    try testing.expectEqualStrings("a\u{20ac}", edit.text());
}

// Locks word jumps: right lands at the end of the next word, left at the start of the
// previous one, separators are skipped first, and a non-ASCII word stays whole.
test "word jumps land on word edges" {
    const bytes = "J\u{fc}rgen  K\u{f6}hler, caf\u{e9}";
    try testing.expectEqual(@as(u32, 7), word_right(bytes, 0));
    try testing.expectEqual(@as(u32, 16), word_right(bytes, 7));
    try testing.expectEqual(@as(u32, 23), word_right(bytes, 16));
    try testing.expectEqual(@as(u32, 23), word_right(bytes, 23));
    try testing.expectEqual(@as(u32, 18), word_left(bytes, 23));
    try testing.expectEqual(@as(u32, 9), word_left(bytes, 18));
    try testing.expectEqual(@as(u32, 0), word_left(bytes, 9));
    try testing.expectEqual(Range{ .start = 9, .end = 16 }, word_around(bytes, 11));
    try testing.expectEqual(Range{ .start = 7, .end = 9 }, word_around(bytes, 8));
    try testing.expectEqual(Range{ .start = 18, .end = 23 }, word_around(bytes, 23));
    var edit = edit_of(bytes);
    try testing.expect(edit.erase(.backward, true));
    try testing.expectEqualStrings("J\u{fc}rgen  K\u{f6}hler, ", edit.text());
}

// Locks the selection: anchor and caret order either way, a typed insert replaces it, and a
// collapse leaves no selection.
test "selection orders, replaces, and collapses" {
    var edit = edit_of("osc filter");
    edit.move_to(4, false);
    edit.move_to(0, true);
    try testing.expectEqual(Range{ .start = 0, .end = 4 }, edit.selection());
    try testing.expectEqualStrings("osc ", edit.selected());
    try testing.expect(edit.insert("vco "));
    try testing.expectEqualStrings("vco filter", edit.text());
    try testing.expectEqual(@as(u32, 4), edit.caret);
    try testing.expect(!edit.has_selection());
    edit.select_all();
    try testing.expectEqualStrings("vco filter", edit.selected());
    try testing.expect(edit.erase(.forward, false));
    try testing.expectEqual(@as(u32, 0), edit.len);
    try testing.expect(!edit.erase(.backward, false));
}

// Locks the limit: an insert keeps only the whole codepoints that fit, a full field refuses
// more, and `set` truncates the same way.
test "inserts stop at the limit on a codepoint boundary" {
    var edit = Edit.init(5);
    try testing.expect(edit.insert("ab"));
    try testing.expect(edit.insert("\u{e4}\u{f6}"));
    try testing.expectEqualStrings("ab\u{e4}", edit.text());
    try testing.expect(edit.insert("c"));
    try testing.expect(!edit.insert("d"));
    try testing.expectEqual(@as(u32, 5), edit.len);
    edit.set("\u{e4}\u{f6}\u{fc}");
    try testing.expectEqualStrings("\u{e4}\u{f6}", edit.text());
    edit.move_to(2, false);
    edit.move_to(4, true);
    try testing.expect(edit.insert("xyz"));
    try testing.expectEqualStrings("\u{e4}xyz", edit.text());
}

// Locks paste sanitizing: line breaks and tabs become spaces (CR LF as one), other controls
// vanish, invalid bytes become U+FFFD, and output stops at a whole codepoint.
test "pasted text becomes one valid line" {
    var out: [32]u8 = undefined;
    const clean = out[0..sanitize_line("a\r\nb\nc\td\x07e\x7f", &out)];
    try testing.expectEqualStrings("a b c de", clean);
    const repaired = out[0..sanitize_line("x\xffy", &out)];
    try testing.expectEqualStrings("x\u{fffd}y", repaired);
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(u32, 2), sanitize_line("ab\u{20ac}", &small));
}

// Locks multi-line sanitizing: CR LF and lone CR become LF, a tab pads to the next multiple
// of four from the landing column (and restarts after a line break), controls vanish,
// invalid bytes become U+FFFD, and a cut output reports itself incomplete on a whole unit.
test "pasted code keeps its lines and expands tabs" {
    var out: [64]u8 = undefined;
    const lines = sanitize_text("a\r\nb\rc\n\td\x07\x7f", 0, &out);
    try testing.expect(lines.complete);
    try testing.expectEqualStrings("a\nb\nc\n    d", out[0..lines.len]);
    const offset = sanitize_text("x\ty\t", 1, &out);
    try testing.expectEqualStrings("x  y   ", out[0..offset.len]);
    const wide = sanitize_text("\u{e4}\tz\xff", 0, &out);
    try testing.expectEqualStrings("\u{e4}   z\u{fffd}", out[0..wide.len]);
    var tiny: [3]u8 = undefined;
    const cut = sanitize_text("ab\tc", 0, &tiny);
    try testing.expect(!cut.complete);
    try testing.expectEqualStrings("ab", tiny[0..cut.len]);
    var small: [5]u8 = undefined;
    const exact = sanitize_text("ab\u{20ac}", 0, &small);
    try testing.expect(exact.complete);
    try testing.expectEqual(@as(u32, 5), exact.len);
}

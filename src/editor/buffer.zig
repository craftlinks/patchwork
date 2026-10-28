//! The editor's text: a contiguous bounded buffer, its line index and tokenizer states, and
//! an undo history in a bounded byte arena.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Contiguous, Not a Gap Buffer
//! The text is at most `buffer_cap` (64 KiB). Moving the tail of a 64 KiB buffer with
//! `@memmove` takes about 0.8 microseconds even in Debug builds (it lowers to the compiler-rt
//! `memmove`, and to `memory.copy` on wasm, whose bulk-memory feature is on), so a gap
//! would save nothing a frame can notice, while every reader (drawing, the tokenizer, word
//! movement, copy, step 18's binding parser) would have to handle two segments. The text
//! stays one valid UTF-8 slice with no tab and no CR (`edit.sanitize_text`).
//!
//! ## 2. The One Edit Primitive
//! `replace(range, utf8, change)` is every edit: typing, deletion, paste, indent, undo, and
//! step 18's knob rewrites. It refuses atomically (returns false, sets `refusal`) when the
//! result would exceed `buffer_cap` bytes or `line_cap` lines; otherwise:
//! ```text
//! record   undo bookkeeping from the bytes about to be replaced (section 4)
//! bytes    memmove the tail, copy the new bytes in
//! lines    line_starts[first+1 ..= last] are the removed lines; the tail of the index moves
//!          by (added - removed) slots and its starts by (inserted - removed) bytes; the
//!          inserted LFs add their starts. `states` moves with the index.
//! states   from the first edited line: compute its end state; continue while the next
//!          line is new or its cached start state differs (`language.zig`, section 1)
//! longest  the longest line in bytes, rescanned over the index (O(lines))
//! revision += 1
//! ```
//! Lines are numbered from 0; line `i` is `bytes[line_starts[i] .. end)` where `end` is the
//! next start minus its LF, or `len` for the last line. There is always at least one line.
//!
//! ## 3. Costs
//! One edit is one memmove of at most 64 KiB, one shift of at most `line_cap` index slots,
//! re-tokenizing the edited lines plus any whose start state changed (bounded by the line
//! count), and the O(lines) longest-line scan. Nothing allocates.
//!
//! ## 4. Undo
//! An entry restores one span: `start`, the `old_len` bytes it replaced, and the `new_len`
//! bytes now there, plus the selections before and after. Old bytes are copied into the
//! linear `arena` when the entry opens; new bytes are copied when it is sealed, because
//! until then the text itself holds them.
//! - **Merging.** The newest entry stays open, and the next edit merges into it when a
//!   gesture is open (`gesture_begin`), or when both are `typing` or both `erasing` and the
//!   edit touches the entry's current span. A merge widens the span to the union: with the
//!   span `[s, s + n)` and the edit `[a, b)` (both in current coordinates, before the edit
//!   is applied), `lo = min(s, a)`, `hi = max(s + n, b)`, and the entry's old bytes become
//!   `text[lo .. s] ++ old ++ text[s + n .. hi]`: bytes outside the span are still
//!   original. Then `new_len = (hi - lo) - (b - a) + inserted`. Any sequence of edits,
//!   however scattered, is therefore one entry whose undo is one replace.
//! - **Sealing.** `seal` closes the open entry: the caller seals on a caret move, a word
//!   boundary while typing, focus loss, and around a gesture; `undo` and a non-merging edit
//!   seal first.
//! - **Redo** entries sit after `undo_count`; a new edit drops them.
//! - **Eviction.** Before an entry opens or grows, the oldest entries are dropped (one
//!   arena memmove for all of them) until the bytes and a slot fit. One entry holds at most
//!   `buffer_cap` old plus `buffer_cap` new bytes, which is `arena_cap`, so the newest entry
//!   always survives and is always undoable.
//! - **Marks.** Every open and every merge takes a fresh `mark`; `history_mark` is the mark
//!   of the newest undoable entry (or of the last evicted one, or of the load), so an app
//!   compares it with the mark it saved at to show a dirty marker that undo can clear.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage: about 64 KiB of text, 128 KiB of arena, 20 KiB of index and states, and
//!   256 entries. Every loop is bounded by the text, line, or entry caps.
//! - `line_starts[0] == 0`, starts ascend and follow an LF, `1 <= line_count <= line_cap`,
//!   and `undo_count <= entry_count <= entry_cap`; `verify` checks all of it (tests).

const std = @import("std");
const assert = std.debug.assert;
const edit = @import("../ui/edit.zig");
const language = @import("language.zig");
const tokenizer = @import("tokenizer.zig");

/// Bytes the text holds.
pub const buffer_cap: u32 = 65536;
/// Lines the text holds.
pub const line_cap: u32 = 4096;
/// Undo entries kept, undoable and redoable together.
pub const entry_cap: u32 = 256;
/// Bytes of old and new text the entries keep: one entry of a whole buffer each way.
pub const arena_cap: u32 = 2 * buffer_cap;

pub const Range = edit.Range;

/// A caret and the selection anchor, both byte offsets.
pub const Selection = struct {
    caret: u32,
    anchor: u32,
};

/// What an edit was, for merging (section 4).
pub const Kind = enum(u8) {
    other,
    typing,
    erasing,
};

/// The undo facts of one edit: its kind and the selections before and after it.
pub const Change = struct {
    kind: Kind,
    before: Selection,
    after: Selection,
};

/// Why the last refused edit was refused.
pub const Refusal = enum(u8) {
    none,
    /// The text would exceed `buffer_cap` bytes.
    bytes,
    /// The text would exceed `line_cap` lines.
    lines,
};

const Entry = struct {
    start: u32,
    old_len: u32,
    new_len: u32,
    /// Old bytes at `arena[offset..][0..old_len]`; once sealed, the new bytes follow them.
    offset: u32,
    before: Selection,
    after: Selection,
    mark: u64,
    kind: Kind,
    sealed: bool,
};

/// The buffer of a text in language `L` (`language.zig`): its start states are `L.State`.
pub fn BufferOf(comptime L: type) type {
    if (comptime language.check(L)) |problem| @compileError(problem);
    comptime assert(@sizeOf([line_cap]L.State) == line_cap);
    return struct {
        const Self = @This();

        bytes: [buffer_cap]u8,
        len: u32,
        line_starts: [line_cap]u32,
        line_count: u32,
        /// The language's state at the start of each line, one byte each.
        states: [line_cap]L.State,
        /// Bytes of the longest line, LF excluded.
        longest: u32,
        /// Moves on every change of the text, undo and redo included.
        revision: u64,
        refusal: Refusal,
        entries: [entry_cap]Entry,
        entry_count: u32,
        /// Entries `0 .. undo_count` are undoable, `undo_count .. entry_count` redoable.
        undo_count: u32,
        arena: [arena_cap]u8,
        arena_used: u32,
        gesture: bool,
        mark_next: u64,
        /// The mark of the state before the oldest kept entry.
        mark_base: u64,

        /// An empty text with no history. Out-pointer init: the buffer is about 220 KiB.
        pub fn init(self: *Self) void {
            self.revision = 0;
            self.mark_next = 1;
            self.refusal = .none;
            self.gesture = false;
            const loaded = self.load("");
            assert(loaded);
            assert(self.line_count == 1);
        }

        /// Replaces the whole text with `utf8` (valid UTF-8 without tabs or CRs; see
        /// `edit.sanitize_text`) and clears the history. False, with the text kept, when it
        /// does not fit.
        pub fn load(self: *Self, utf8: []const u8) bool {
            assert(!self.gesture);
            if (utf8.len > buffer_cap) return self.refuse(.bytes);
            const lines = 1 + std.mem.count(u8, utf8, "\n");
            if (lines > line_cap) return self.refuse(.lines);
            @memcpy(self.bytes[0..utf8.len], utf8);
            self.len = @intCast(utf8.len);
            self.line_starts[0] = 0;
            self.line_count = 1;
            for (utf8, 0..) |byte, index| {
                if (byte != '\n') continue;
                self.line_starts[self.line_count] = @intCast(index + 1);
                self.line_count += 1;
            }
            self.states[0] = .normal;
            self.retokenize(0, self.line_count - 1);
            self.longest = self.longest_line();
            self.entry_count = 0;
            self.undo_count = 0;
            self.arena_used = 0;
            self.mark_base = self.take_mark();
            self.revision += 1;
            self.refusal = .none;
            assert(self.line_count == lines);
            return true;
        }

        pub fn text(self: *const Self) []const u8 {
            assert(self.len <= buffer_cap);
            return self.bytes[0..self.len];
        }

        /// The bytes of line `line`, LF excluded.
        pub fn line_range(self: *const Self, line: u32) Range {
            assert(line < self.line_count);
            const start = self.line_starts[line];
            const last = line + 1 == self.line_count;
            const end = if (last) self.len else self.line_starts[line + 1] - 1;
            assert(start <= end);
            return .{ .start = start, .end = end };
        }

        pub fn line_bytes(self: *const Self, line: u32) []const u8 {
            const range = self.line_range(line);
            return self.bytes[range.start..range.end];
        }

        /// The line holding byte `byte` (the last line for the end). Binary search.
        pub fn line_of(self: *const Self, byte: u32) u32 {
            assert(byte <= self.len);
            var low: u32 = 0;
            var high: u32 = self.line_count;
            // Invariant: line_starts[low] <= byte, and every line from high on starts after it.
            while (high - low > 1) {
                const middle = low + (high - low) / 2;
                if (self.line_starts[middle] <= byte) low = middle else high = middle;
            }
            assert(self.line_starts[low] <= byte);
            if (low + 1 < self.line_count) assert(self.line_starts[low + 1] > byte);
            return low;
        }

        /// Replaces `range` with `utf8` (valid UTF-8 without tabs or CRs, `range` on codepoint
        /// boundaries) and records it for undo. False, with nothing changed, when the result
        /// would exceed a cap. See the module guide, sections 2 and 4.
        pub fn replace(self: *Self, range: Range, utf8: []const u8, change: Change) bool {
            assert(range.start <= range.end);
            assert(range.end <= self.len);
            assert(edit.is_boundary(self.text(), range.start));
            assert(edit.is_boundary(self.text(), range.end));
            const removed = self.bytes[range.start..range.end];
            if (self.len - removed.len + utf8.len > buffer_cap) return self.refuse(.bytes);
            const lines_removed = std.mem.count(u8, removed, "\n");
            const lines_added = std.mem.count(u8, utf8, "\n");
            const lines = self.line_count - lines_removed + lines_added;
            if (lines > line_cap) return self.refuse(.lines);
            self.refusal = .none;
            self.record(range, @intCast(utf8.len), change);
            self.apply(range, utf8);
            assert(self.len <= buffer_cap);
            return true;
        }

        /// Closes the open entry, so the next edit opens its own (section 4).
        pub fn seal(self: *Self) void {
            const index = self.open_index() orelse return;
            const entry = self.entries[index];
            self.make_room(entry.new_len, false);
            const open = &self.entries[self.entry_count - 1];
            assert(self.arena_used == open.offset + open.old_len);
            const new_bytes = self.bytes[open.start..][0..open.new_len];
            @memcpy(self.arena[self.arena_used..][0..open.new_len], new_bytes);
            self.arena_used += open.new_len;
            open.sealed = true;
            assert(self.open_index() == null);
        }

        /// Starts a gesture: every edit until `gesture_end` merges into one entry.
        pub fn gesture_begin(self: *Self) void {
            assert(!self.gesture);
            self.seal();
            self.gesture = true;
            assert(self.open_index() == null);
        }

        pub fn gesture_end(self: *Self) void {
            assert(self.gesture);
            self.gesture = false;
            self.seal();
            assert(self.open_index() == null);
        }

        /// Replaces the selection the open entry restores on redo, for an edit whose final
        /// selection is known only after its last replace (an indent of several lines).
        pub fn amend_after(self: *Self, after: Selection) void {
            const index = self.open_index() orelse return;
            assert(after.caret <= self.len);
            assert(after.anchor <= self.len);
            self.entries[index].after = after;
        }

        /// Reverts the newest undoable entry and returns the selection before it, or null.
        pub fn undo(self: *Self) ?Selection {
            assert(!self.gesture);
            self.seal();
            if (self.undo_count == 0) return null;
            const entry = self.entries[self.undo_count - 1];
            assert(entry.sealed);
            const range: Range = .{ .start = entry.start, .end = entry.start + entry.new_len };
            self.apply(range, self.arena[entry.offset..][0..entry.old_len]);
            self.undo_count -= 1;
            return entry.before;
        }

        /// Re-applies the oldest redoable entry and returns the selection after it, or null.
        pub fn redo(self: *Self) ?Selection {
            assert(!self.gesture);
            if (self.undo_count == self.entry_count) return null;
            const entry = self.entries[self.undo_count];
            assert(entry.sealed);
            const range: Range = .{ .start = entry.start, .end = entry.start + entry.old_len };
            self.apply(range, self.arena[entry.offset + entry.old_len ..][0..entry.new_len]);
            self.undo_count += 1;
            return entry.after;
        }

        /// The mark of the current state of the history (section 4).
        pub fn history_mark(self: *const Self) u64 {
            assert(self.undo_count <= self.entry_count);
            if (self.undo_count == 0) return self.mark_base;
            return self.entries[self.undo_count - 1].mark;
        }

        /// Checks every invariant of the module guide, section 5. O(text); for tests.
        pub fn verify(self: *const Self) void {
            assert(self.line_count >= 1);
            assert(self.line_starts[0] == 0);
            var line: u32 = 1;
            for (self.text(), 0..) |byte, index| {
                if (byte != '\n') continue;
                assert(self.line_starts[line] == index + 1);
                line += 1;
            }
            assert(line == self.line_count);
            var state: L.State = .normal;
            line = 0;
            while (line < self.line_count) : (line += 1) {
                assert(self.states[line] == state);
                state = language.verify_line(L, self.line_bytes(line), state);
            }
            assert(self.longest == self.longest_line());
            assert(self.undo_count <= self.entry_count);
            assert(std.unicode.utf8ValidateSlice(self.text()));
        }

        fn refuse(self: *Self, refusal: Refusal) bool {
            assert(refusal != .none);
            self.refusal = refusal;
            return false;
        }

        fn take_mark(self: *Self) u64 {
            const mark = self.mark_next;
            self.mark_next += 1;
            assert(mark != 0);
            return mark;
        }

        /// The index of the open (unsealed, newest, undoable) entry, or null.
        fn open_index(self: *const Self) ?u32 {
            if (self.entry_count == 0) return null;
            const index = self.entry_count - 1;
            if (self.entries[index].sealed) return null;
            assert(self.undo_count == self.entry_count);
            return index;
        }

        /// The undo half of `replace`: merge into the open entry or open a new one.
        fn record(self: *Self, range: Range, inserted: u32, change: Change) void {
            if (self.open_index()) |index| {
                if (self.merges(self.entries[index], range, change.kind)) {
                    self.merge(range, inserted, change.after);
                    return;
                }
                self.seal();
            }
            self.drop_redo();
            const old_len = range.end - range.start;
            self.make_room(old_len, true);
            const offset = self.arena_used;
            @memcpy(self.arena[offset..][0..old_len], self.bytes[range.start..range.end]);
            self.arena_used += old_len;
            self.entries[self.entry_count] = .{
                .start = range.start,
                .old_len = old_len,
                .new_len = inserted,
                .offset = offset,
                .before = change.before,
                .after = change.after,
                .mark = self.take_mark(),
                .kind = change.kind,
                .sealed = false,
            };
            self.entry_count += 1;
            self.undo_count = self.entry_count;
            assert(self.arena_used <= arena_cap);
        }

        fn merges(self: *const Self, entry: Entry, range: Range, kind: Kind) bool {
            assert(!entry.sealed);
            if (self.gesture) return true;
            if (kind == .other) return false;
            if (kind != entry.kind) return false;
            if (range.start > entry.start + entry.new_len) return false;
            return range.end >= entry.start;
        }

        /// Widens the open entry to the union of its span and `range` (section 4).
        fn merge(self: *Self, range: Range, inserted: u32, after: Selection) void {
            const open = self.entries[self.entry_count - 1];
            const low = @min(open.start, range.start);
            const high = @max(open.start + open.new_len, range.end);
            const prefix = open.start - low;
            const suffix = high - (open.start + open.new_len);
            self.make_room(prefix + suffix, false);
            const entry = &self.entries[self.entry_count - 1];
            assert(self.arena_used == entry.offset + entry.old_len);
            const old = self.arena[entry.offset..][0 .. entry.old_len + prefix];
            @memmove(old[prefix..][0..entry.old_len], old[0..entry.old_len]);
            @memcpy(old[0..prefix], self.bytes[low..entry.start]);
            const tail = entry.start + entry.new_len;
            const after_old = entry.offset + prefix + entry.old_len;
            @memcpy(self.arena[after_old..][0..suffix], self.bytes[tail..high]);
            entry.old_len += prefix + suffix;
            entry.start = low;
            entry.new_len = (high - low) - (range.end - range.start) + inserted;
            entry.after = after;
            entry.mark = self.take_mark();
            self.arena_used = entry.offset + entry.old_len;
            assert(self.arena_used <= arena_cap);
        }

        fn drop_redo(self: *Self) void {
            if (self.undo_count == self.entry_count) return;
            self.entry_count = self.undo_count;
            if (self.entry_count == 0) {
                self.arena_used = 0;
                return;
            }
            const last = self.entries[self.entry_count - 1];
            assert(last.sealed);
            self.arena_used = last.offset + last.old_len + last.new_len;
        }

        /// Drops the oldest entries until `bytes` more arena bytes (and a free slot, when
        /// `slot`) fit, with one memmove (section 4). The open entry is never dropped.
        fn make_room(self: *Self, bytes: u32, slot: bool) void {
            assert(bytes <= arena_cap);
            assert(self.undo_count == self.entry_count);
            var dropped: u32 = 0;
            var freed: u32 = 0;
            while (dropped < self.entry_count) {
                const fits = self.arena_used - freed + bytes <= arena_cap;
                const room = !slot or self.entry_count - dropped < entry_cap;
                if (fits and room) break;
                dropped += 1;
                freed = if (dropped < self.entry_count)
                    self.entries[dropped].offset
                else
                    self.arena_used;
            }
            if (dropped == 0) return;
            if (self.open_index() != null) assert(dropped < self.entry_count);
            self.mark_base = self.entries[dropped - 1].mark;
            const kept = self.entry_count - dropped;
            @memmove(self.arena[0 .. self.arena_used - freed], self.arena[freed..self.arena_used]);
            @memmove(self.entries[0..kept], self.entries[dropped..self.entry_count]);
            for (self.entries[0..kept]) |*entry| entry.offset -= freed;
            self.arena_used -= freed;
            self.entry_count = kept;
            self.undo_count = kept;
            assert(self.arena_used + bytes <= arena_cap);
        }

        /// The text half of `replace`, also used by undo and redo (section 2).
        fn apply(self: *Self, range: Range, utf8: []const u8) void {
            const removed = range.end - range.start;
            const inserted: u32 = @intCast(utf8.len);
            assert(self.len - removed + inserted <= buffer_cap);
            const first = self.line_of(range.start);
            const last = self.line_of(range.end);
            const tail_bytes = self.len - range.end;
            @memmove(
                self.bytes[range.start + inserted ..][0..tail_bytes],
                self.bytes[range.end..self.len],
            );
            @memcpy(self.bytes[range.start..][0..inserted], utf8);
            self.len = self.len - removed + inserted;
            const added: u32 = @intCast(std.mem.count(u8, utf8, "\n"));
            const tail = self.line_count - (last + 1);
            assert(first + 1 + added + tail <= line_cap);
            const target = first + 1 + added;
            @memmove(self.line_starts[target..][0..tail], self.line_starts[last + 1 ..][0..tail]);
            @memmove(self.states[target..][0..tail], self.states[last + 1 ..][0..tail]);
            for (self.line_starts[target..][0..tail]) |*start| {
                start.* = start.* - removed + inserted;
            }
            var line = first + 1;
            for (utf8, 0..) |byte, index| {
                if (byte != '\n') continue;
                self.line_starts[line] = range.start + @as(u32, @intCast(index)) + 1;
                line += 1;
            }
            assert(line == target);
            self.line_count = target + tail;
            self.retokenize(first, first + added);
            self.longest = self.longest_line();
            self.revision += 1;
            assert(self.line_starts[0] == 0);
        }

        /// Recomputes start states from line `first` on: through `last` always, then until a
        /// computed start state equals the cached one (`language.zig`, section 1).
        fn retokenize(self: *Self, first: u32, last: u32) void {
            assert(first <= last);
            assert(last < self.line_count);
            var line = first;
            while (line + 1 < self.line_count) : (line += 1) {
                const state = language.end_state(L, self.line_bytes(line), self.states[line]);
                if (line + 1 > last and self.states[line + 1] == state) break;
                self.states[line + 1] = state;
            }
            assert(line < self.line_count);
        }

        fn longest_line(self: *const Self) u32 {
            var longest: u32 = 0;
            var line: u32 = 0;
            while (line < self.line_count) : (line += 1) {
                const range = self.line_range(line);
                longest = @max(longest, range.end - range.start);
            }
            assert(longest <= self.len);
            return longest;
        }
    };
}

/// The patch language's buffer, the editor's default.
pub const Buffer = BufferOf(tokenizer);

comptime {
    assert(arena_cap == 2 * buffer_cap);
    assert(line_cap <= buffer_cap);
    assert(entry_cap >= 2);
}

const testing = std.testing;

/// Static, so tests keep the 220 KiB buffer off the stack.
const fixture = struct {
    var buffer: Buffer = undefined;
};

fn fresh(utf8: []const u8) *Buffer {
    fixture.buffer.init();
    const loaded = fixture.buffer.load(utf8);
    assert(loaded);
    return &fixture.buffer;
}

fn at(byte: u32) Selection {
    return .{ .caret = byte, .anchor = byte };
}

fn change_of(kind: Kind, before: u32, after: u32) Change {
    return .{ .kind = kind, .before = at(before), .after = at(after) };
}

fn span(start: u32, end: u32) Range {
    return .{ .start = start, .end = end };
}

// Locks the line index: starts follow every LF, a multi-line replace removes and adds lines
// and shifts the tail, line ranges exclude the LF, and line_of finds the end of the text.
test "the line index follows multi-line edits" {
    const buffer = fresh("ab\ncd\nef");
    try testing.expectEqual(@as(u32, 3), buffer.line_count);
    try testing.expectEqualSlices(u32, &.{ 0, 3, 6 }, buffer.line_starts[0..3]);
    try testing.expect(buffer.replace(span(1, 4), "X\nY\nZ", change_of(.other, 1, 6)));
    try testing.expectEqualStrings("aX\nY\nZd\nef", buffer.text());
    try testing.expectEqualSlices(u32, &.{ 0, 3, 5, 8 }, buffer.line_starts[0..4]);
    try testing.expectEqualStrings("Zd", buffer.line_bytes(2));
    try testing.expectEqual(@as(u32, 3), buffer.line_of(buffer.len));
    try testing.expectEqual(@as(u32, 1), buffer.line_of(3));
    try testing.expectEqual(@as(u32, 0), buffer.line_of(2));
    try testing.expectEqual(@as(u32, 2), buffer.longest);
    buffer.verify();
    try testing.expect(buffer.replace(span(0, buffer.len), "", change_of(.other, 0, 0)));
    try testing.expectEqual(@as(u32, 1), buffer.line_count);
    buffer.verify();
}

// Locks refusals: a replace past 64 KiB or past 4,096 lines changes nothing, records nothing,
// and names its cap; the next fitting edit clears the refusal.
test "edits over a cap are refused whole" {
    const buffer = fresh("x");
    const revision = buffer.revision;
    var big: [buffer_cap]u8 = @splat('a');
    try testing.expect(!buffer.replace(span(0, 0), &big, change_of(.other, 0, 0)));
    try testing.expectEqual(Refusal.bytes, buffer.refusal);
    var lines: [line_cap]u8 = @splat('\n');
    try testing.expect(!buffer.replace(span(0, 0), &lines, change_of(.other, 0, 0)));
    try testing.expectEqual(Refusal.lines, buffer.refusal);
    try testing.expectEqualStrings("x", buffer.text());
    try testing.expectEqual(revision, buffer.revision);
    try testing.expectEqual(@as(u32, 0), buffer.entry_count);
    const most = lines[0 .. line_cap - 1];
    try testing.expect(buffer.replace(span(1, 1), most, change_of(.other, 1, 1)));
    try testing.expectEqual(Refusal.none, buffer.refusal);
    try testing.expectEqual(line_cap, buffer.line_count);
    try testing.expect(buffer.replace(span(0, 1), big[0 .. buffer_cap - buffer.len + 1], .{
        .kind = .other,
        .before = at(0),
        .after = at(0),
    }));
    try testing.expectEqual(buffer_cap, buffer.len);
}

// Locks coalescing: adjacent typing merges into one entry, an erase run merges with itself
// but not with typing, `other` never merges, a seal splits, and undo restores the selection
// recorded before each entry.
test "typing and erasing coalesce until sealed" {
    const buffer = fresh("");
    try testing.expect(buffer.replace(span(0, 0), "a", change_of(.typing, 0, 1)));
    try testing.expect(buffer.replace(span(1, 1), "b", change_of(.typing, 1, 2)));
    try testing.expect(buffer.replace(span(2, 2), "c", change_of(.typing, 2, 3)));
    try testing.expectEqual(@as(u32, 1), buffer.entry_count);
    try testing.expect(buffer.replace(span(2, 3), "", change_of(.erasing, 3, 2)));
    try testing.expect(buffer.replace(span(1, 2), "", change_of(.erasing, 2, 1)));
    try testing.expectEqual(@as(u32, 2), buffer.entry_count);
    buffer.seal();
    try testing.expect(buffer.replace(span(1, 1), "z", change_of(.typing, 1, 2)));
    try testing.expect(buffer.replace(span(2, 2), "\n", change_of(.other, 2, 3)));
    try testing.expectEqual(@as(u32, 4), buffer.entry_count);
    try testing.expectEqualStrings("az\n", buffer.text());
    try testing.expectEqual(at(2), buffer.undo().?);
    try testing.expectEqual(at(1), buffer.undo().?);
    try testing.expectEqualStrings("a", buffer.text());
    try testing.expectEqual(at(3), buffer.undo().?);
    try testing.expectEqualStrings("abc", buffer.text());
    try testing.expectEqual(at(0), buffer.undo().?);
    try testing.expectEqualStrings("", buffer.text());
    try testing.expectEqual(@as(?Selection, null), buffer.undo());
    try testing.expectEqual(at(3), buffer.redo().?);
    try testing.expectEqualStrings("abc", buffer.text());
    buffer.verify();
}

// Locks gestures: three rewrites of one literal and an edit far away inside one gesture are
// one entry; undo restores every original byte and redo the final text; a new edit after an
// undo drops the redo entry.
test "a gesture is one entry however its edits are spread" {
    const buffer = fresh("k(0~0.5~1)\nx\ny");
    buffer.gesture_begin();
    try testing.expect(buffer.replace(span(4, 7), "0.61", change_of(.other, 0, 0)));
    try testing.expect(buffer.replace(span(4, 8), "0.7", change_of(.other, 0, 0)));
    try testing.expect(buffer.replace(span(13, 14), "yy", change_of(.other, 0, 0)));
    try testing.expect(buffer.replace(span(4, 7), "0.75", change_of(.other, 0, 0)));
    buffer.gesture_end();
    try testing.expectEqual(@as(u32, 1), buffer.entry_count);
    try testing.expectEqualStrings("k(0~0.75~1)\nx\nyy", buffer.text());
    _ = buffer.undo().?;
    try testing.expectEqualStrings("k(0~0.5~1)\nx\ny", buffer.text());
    _ = buffer.redo().?;
    try testing.expectEqualStrings("k(0~0.75~1)\nx\nyy", buffer.text());
    _ = buffer.undo().?;
    try testing.expect(buffer.replace(span(0, 1), "q", change_of(.other, 0, 1)));
    try testing.expectEqual(@as(?Selection, null), buffer.redo());
    try testing.expectEqual(@as(u32, 1), buffer.entry_count);
    buffer.verify();
}

// Locks eviction: past 256 entries the oldest go and the newest stay undoable; a whole-buffer
// replace evicts everything else yet undoes exactly; marks follow the history, so undoing
// back to the saved mark reads clean again.
test "eviction keeps the newest entry undoable and marks follow" {
    const buffer = fresh("");
    const loaded = buffer.history_mark();
    var index: u32 = 0;
    while (index < entry_cap + 10) : (index += 1) {
        const change = change_of(.other, index, index + 1);
        try testing.expect(buffer.replace(span(index, index), "a", change));
    }
    try testing.expectEqual(entry_cap, buffer.entry_count);
    const saved = buffer.history_mark();
    try testing.expect(saved != loaded);
    try testing.expect(buffer.replace(span(0, 0), "b", change_of(.typing, 0, 1)));
    try testing.expect(buffer.history_mark() != saved);
    _ = buffer.undo().?;
    try testing.expectEqual(saved, buffer.history_mark());
    var big: [buffer_cap - entry_cap - 10]u8 = @splat('z');
    try testing.expect(buffer.replace(span(0, buffer.len), &big, change_of(.other, 0, 0)));
    buffer.seal();
    try testing.expect(buffer.entry_count <= entry_cap);
    while (buffer.undo_count > 1) _ = buffer.undo().?;
    _ = buffer.undo().?;
    try testing.expectEqual(@as(u32, 0), buffer.undo_count);
    try testing.expect(buffer.len <= entry_cap + 10);
    buffer.verify();
}

// Locks the start states across edits: opening a block comment on the first line turns every
// later line's start state to block_comment, and closing it restores them, as a full
// recomputation would (`verify`).
test "a block comment edit re-tokenizes until the states settle" {
    const buffer = fresh("a\nb\nc\nd");
    try testing.expect(buffer.replace(span(0, 0), "/*", change_of(.other, 0, 2)));
    for (buffer.states[1..4]) |state| try testing.expectEqual(tokenizer.State.block_comment, state);
    buffer.verify();
    try testing.expect(buffer.replace(span(5, 5), "*/", change_of(.other, 5, 7)));
    try testing.expectEqual(tokenizer.State.block_comment, buffer.states[1]);
    try testing.expectEqual(tokenizer.State.normal, buffer.states[2]);
    buffer.verify();
}

/// A three-state test language: `>` raises the state one level and `<` lowers it, so a
/// change ripples through later lines by level, not just on and off.
const Levels = struct {
    pub const State = enum(u8) { normal, one, two };
    pub const Class = enum(u8) { word, shift };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 0, 0, 1 } };

    pub fn next(line: []const u8, at_byte: *u32, state: *State) ?language.Token(Class) {
        assert(at_byte.* <= line.len);
        var index = at_byte.*;
        while (index < line.len and line[index] == ' ') index += 1;
        at_byte.* = index;
        if (index == line.len) return null;
        const start = index;
        const byte = line[index];
        at_byte.* = index + 1;
        if (byte == '>') {
            state.* = if (state.* == .normal) .one else .two;
            return .{ .start = start, .end = start + 1, .class = .shift };
        }
        if (byte == '<') {
            state.* = if (state.* == .two) .one else .normal;
            return .{ .start = start, .end = start + 1, .class = .shift };
        }
        return .{ .start = start, .end = start + 1, .class = .word };
    }
};

const levels_fixture = struct {
    var buffer: BufferOf(Levels) = undefined;
};

// Locks re-tokenizing with three states: ">" on line 0 raises lines 1 to 3 to `one` and the
// "<" on line 3 brings line 4 back to `normal`, its cached value, where the ripple stops; a
// second ">" raises lines 1 to 3 to `two` and line 4 to `one`, and removing both restores
// every line, as a full recomputation would (`verify`).
test "a three-state language ripples by level and stops where states match" {
    const buffer = &levels_fixture.buffer;
    buffer.init();
    try testing.expect(buffer.load("a\nb\nc\n<\nd"));
    try testing.expect(buffer.replace(span(0, 0), ">", change_of(.other, 0, 1)));
    const one = [_]Levels.State{ .normal, .one, .one, .one, .normal };
    try testing.expectEqualSlices(Levels.State, &one, buffer.states[0..5]);
    buffer.verify();
    try testing.expect(buffer.replace(span(0, 0), ">", change_of(.other, 0, 1)));
    const two = [_]Levels.State{ .normal, .two, .two, .two, .one };
    try testing.expectEqualSlices(Levels.State, &two, buffer.states[0..5]);
    buffer.verify();
    try testing.expect(buffer.replace(span(0, 2), "", change_of(.other, 2, 0)));
    for (buffer.states[0..5]) |state| try testing.expectEqual(Levels.State.normal, state);
    buffer.verify();
}

// Locks undo against a seeded random sequence: inserts, deletions, and replaces of random
// kinds, with random seals and gestures, keep every invariant; undoing everything restores
// the original bytes exactly, and redoing everything restores the final bytes.
test "random edits undo and redo exactly" {
    const pieces = [_][]const u8{ "a", "b ", "\n", "/*", "*/", "\u{e4}", "x\ny\n", "  ", "0.5" };
    var prng = std.Random.DefaultPrng.init(0x5eed_0017);
    const random = prng.random();
    var round: u32 = 0;
    while (round < 8) : (round += 1) {
        const buffer = fresh("k(0~0.5~1)\n/* c */ x := 1\n");
        var original: [64]u8 = undefined;
        const original_len = buffer.len;
        @memcpy(original[0..original_len], buffer.text());
        var step: u32 = 0;
        while (step < 120) : (step += 1) {
            random_edit(buffer, random, &pieces);
            buffer.verify();
        }
        if (buffer.gesture) buffer.gesture_end();
        const final = try testing.allocator.dupe(u8, buffer.text());
        defer testing.allocator.free(final);
        while (buffer.undo()) |_| {}
        try testing.expectEqualStrings(original[0..original_len], buffer.text());
        buffer.verify();
        while (buffer.redo()) |_| {}
        try testing.expectEqualStrings(final, buffer.text());
        buffer.verify();
    }
}

fn random_edit(buffer: *Buffer, random: std.Random, pieces: []const []const u8) void {
    switch (random.uintLessThan(u32, 10)) {
        0 => buffer.seal(),
        1 => if (buffer.gesture) buffer.gesture_end() else buffer.gesture_begin(),
        else => {},
    }
    const a = boundary_near(buffer, random.uintAtMost(u32, buffer.len));
    const b = boundary_near(buffer, random.uintAtMost(u32, buffer.len));
    const range = span(@min(a, b), if (random.boolean()) @min(a, b) else @max(a, b));
    const piece = if (random.uintLessThan(u32, 4) == 0) "" else pieces[
        random.uintLessThan(
            usize,
            pieces.len,
        )
    ];
    const kind: Kind = @fromBackingInt(@intCast(random.uintLessThan(u8, 3)));
    const change = change_of(kind, range.start, range.start + @as(u32, @intCast(piece.len)));
    const done = buffer.replace(range, piece, change);
    assert(done);
}

fn boundary_near(buffer: *const Buffer, byte: u32) u32 {
    var index = byte;
    while (!edit.is_boundary(buffer.text(), index)) index -= 1;
    return index;
}

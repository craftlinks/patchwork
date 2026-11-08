//! The mix's numbers: fourteen values read out of the text, and written back to it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Text Is the Truth
//! The toggles, knobs, faders, and mutes of the mix hold no value of their own in the end: a
//! parse sets them from the text, and a moved widget rewrites its literal. Two rules keep that
//! from looping: a parse never writes, and a write never parses. A write moves the other ranges
//! with `shift` instead, so a drag costs no pass over the text.
//!
//! ## 2. Grammar (tokens of `patch.zig`, one line)
//! ```text
//! tog ( number , "name" )                         eq on, shimmer on
//! k ( number ~ number ~ number , [name =] "name" )   shimmer, wet: lo ~ value ~ hi
//! level = number , number , number , number       the first four faders, in decibels
//! send = number , number , number , number        their send knobs, in decibels
//! mute [ digit ] = number                         the first two mutes
//! number   [-] digits [. digits] [db]
//! ```
//! Walking tokens means a call inside a string is no call. The first match of a slot in the
//! whole text binds it, so a line binds the same in any section, and later ones are text.
//!
//! ## 3. Errors
//! A value outside its range binds, clamps on the widget, and marks its literal. A `level` or
//! `send` list that breaks marks the list, and its slots stay unbound. A `k` with `lo >= hi`
//! marks the call. An unbound slot's widget keeps its last value and writes nothing.
//!
//! ## 4. Literals
//! Numbers are `f32`, read by a small hand-written reader. `live` keeps fixed point because a
//! knob there writes back the digits it read; here a parse never writes, so typed digits stay
//! until the widget itself moves.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage, no allocation. A pass is bounded by the text, a line by `token_cap` tokens.
//! - Ranges lie inside the text; `shift` keeps them there.

const std = @import("std");
const assert = std.debug.assert;
const patch = @import("patch.zig");
const fixed_point = @import("patchwork").editor.literal;

/// A byte range of the text, the editor's own, so `editor.literal.shift` moves it.
pub const Span = fixed_point.Range;

/// The values the text holds, by where they go.
pub const Slot = enum(u8) {
    eq_on,
    shimmer_on,
    shimmer,
    wet,
    level_0,
    level_1,
    level_2,
    level_3,
    send_0,
    send_1,
    send_2,
    send_3,
    mute_0,
    mute_1,
};

pub const slot_count: u32 = @typeInfo(Slot).@"enum".field_names.len;
/// Tokens one line may have; a longer line's tail binds nothing.
pub const token_cap: u32 = 96;
/// Errors kept; the rest go unmarked.
pub const error_cap: u32 = 16;
/// The largest number the text may hold. A `k`'s ends are the text's, so a knob can write a value
/// this large, and it must read back what it wrote.
pub const number_max: f32 = 1e13;
/// Characters of a number after its sign and unit: 14 digits, a point, and two decimals, and one
/// spare, so everything `format` writes reads back.
const number_chars: u32 = 18;
/// Bytes of the longest literal a widget writes: `number_chars`, a sign, and the unit.
pub const literal_cap: u32 = number_chars + 3;
/// The range of a level or a send, in decibels.
pub const db_lo: f32 = -60;
pub const db_hi: f32 = 6;

pub const Value = struct {
    range: Span,
    number: f32,
    /// The ends a `k` gave; 0 and 1 for the rest.
    lo: f32 = 0,
    hi: f32 = 1,
};

const Word = struct { start: u32, end: u32 };

pub const Parse = struct {
    values: [slot_count]?Value = @splat(null),
    errors: [error_cap]Span = undefined,
    error_count: u32 = 0,

    pub fn get(self: *const Parse, slot: Slot) ?Value {
        return self.values[@backingInt(slot)];
    }

    fn mark(self: *Parse, span: Span) void {
        if (self.error_count == error_cap) return;
        self.errors[self.error_count] = span;
        self.error_count += 1;
    }

    /// Reads every slot out of `text`. A pure function of the text.
    pub fn run(text: []const u8) Parse {
        var out: Parse = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        var start: u32 = 0;
        while (lines.next()) |line| {
            if (patch.level_of(line) == 0) out.scan_line(text, line, start);
            start += @intCast(line.len + 1);
        }
        return out;
    }

    fn scan_line(self: *Parse, text: []const u8, line: []const u8, start: u32) void {
        var words: [token_cap]Word = undefined;
        var count: u32 = 0;
        var state: patch.State = .normal;
        var at: u32 = 0;
        while (count < token_cap) {
            const token = patch.next(line, &at, &state) orelse break;
            words[count] = .{ .start = start + token.start, .end = start + token.end };
            count += 1;
        }
        const scan: Scan = .{ .text = text, .words = words[0..count] };
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const word = scan.at(index);
            if (std.mem.eql(u8, word, "tog")) self.toggle(scan, index);
            if (std.mem.eql(u8, word, "k")) self.knob(scan, index);
            if (std.mem.eql(u8, word, "level")) self.list(scan, index, .level_0);
            if (std.mem.eql(u8, word, "send")) self.list(scan, index, .send_0);
            if (std.mem.eql(u8, word, "mute")) self.mute(scan, index);
        }
    }

    fn take(self: *Parse, slot: Slot, value: Value) void {
        const entry = &self.values[@backingInt(slot)];
        if (entry.* == null) entry.* = value;
    }

    fn toggle(self: *Parse, scan: Scan, index: u32) void {
        if (!scan.is(index + 1, "(")) return;
        if (!scan.is(index + 3, ",") or !scan.is(index + 5, ")")) return;
        const slot: Slot = if (scan.is(index + 4, "\"eq\""))
            .eq_on
        else if (scan.is(index + 4, "\"shimmer\""))
            .shimmer_on
        else
            return;
        self.flag(scan, index + 2, slot);
    }

    fn flag(self: *Parse, scan: Scan, index: u32, slot: Slot) void {
        const span = scan.span(index);
        // A line that stops at `mute[0] =` has no word to read.
        if (index >= scan.words.len) return self.mark(span);
        const number = read_number(scan.at(index)) orelse return self.mark(span);
        self.take(slot, .{ .range = span, .number = number });
        if (number != 0 and number != 1) self.mark(span);
    }

    fn knob(self: *Parse, scan: Scan, index: u32) void {
        if (!scan.is(index + 1, "(") or !scan.is(index + 3, "~") or !scan.is(index + 5, "~")) return;
        if (!scan.is(index + 7, ",")) return;
        const named = scan.is(index + 8, "name") and scan.is(index + 9, "=");
        const name = if (named) index + 10 else index + 8;
        const slot: Slot = if (scan.is(name, "\"shimmer\""))
            .shimmer
        else if (scan.is(name, "\"wet\""))
            .wet
        else
            return;
        const call: Span = .{ .start = scan.span(index).start, .end = scan.span(name).end };
        const lo = read_number(scan.at(index + 2)) orelse return self.mark(call);
        const number = read_number(scan.at(index + 4)) orelse return self.mark(call);
        const hi = read_number(scan.at(index + 6)) orelse return self.mark(call);
        if (lo >= hi) return self.mark(call);
        const span = scan.span(index + 4);
        self.take(slot, .{ .range = span, .number = number, .lo = lo, .hi = hi });
        if (number < lo or number > hi) self.mark(span);
    }

    /// `level = a, b, c, d` or `send = ...`: all four, or none (section 3).
    fn list(self: *Parse, scan: Scan, index: u32, first: Slot) void {
        if (!scan.is(index + 1, "=")) return;
        var values: [4]Value = undefined;
        var at = index + 2;
        for (&values, 0..) |*value, place| {
            if (place > 0) {
                if (!scan.is(at, ",")) return self.mark(scan.from(index, at));
                at += 1;
            }
            if (at >= scan.words.len) return self.mark(scan.from(index, at));
            const number = read_number(scan.at(at)) orelse return self.mark(scan.from(index, at));
            value.* = .{ .range = scan.span(at), .number = number };
            at += 1;
        }
        for (values, 0..) |value, place| {
            const slot: Slot = @fromBackingInt(@backingInt(first) + @as(u8, @intCast(place)));
            self.take(slot, value);
            if (value.number < db_lo or value.number > db_hi) self.mark(value.range);
        }
    }

    fn mute(self: *Parse, scan: Scan, index: u32) void {
        if (!scan.is(index + 1, "[") or !scan.is(index + 3, "]") or !scan.is(index + 4, "=")) return;
        const slot: Slot = if (scan.is(index + 2, "0"))
            .mute_0
        else if (scan.is(index + 2, "1"))
            .mute_1
        else
            return;
        self.flag(scan, index + 5, slot);
    }

    /// Moves every range edge at or past `after` by `delta` (section 1), as
    /// `editor.literal.shift` does: the rewritten literal's own end moves with it.
    pub fn shift(self: *Parse, after: u32, delta: i32) void {
        for (&self.values) |*entry| {
            if (entry.*) |*value| fixed_point.shift(&value.range, after, delta);
        }
        for (self.errors[0..self.error_count]) |*span| fixed_point.shift(span, after, delta);
    }
};

/// One line's tokens over the text.
const Scan = struct {
    text: []const u8,
    words: []const Word,

    fn at(self: Scan, index: u32) []const u8 {
        const word = self.words[index];
        return self.text[word.start..word.end];
    }

    fn is(self: Scan, index: u32, bytes: []const u8) bool {
        if (index >= self.words.len) return false;
        return std.mem.eql(u8, self.at(index), bytes);
    }

    fn span(self: Scan, index: u32) Span {
        if (index >= self.words.len) {
            const last = self.words[self.words.len - 1];
            return .{ .start = last.start, .end = last.end };
        }
        const word = self.words[index];
        return .{ .start = word.start, .end = word.end };
    }

    /// From word `first` through word `last`, or the line's last word.
    fn from(self: Scan, first: u32, last: u32) Span {
        return .{ .start = self.span(first).start, .end = self.span(last).end };
    }
};

/// `[-] digits [. digits] [db]`, or null (section 2).
pub fn read_number(bytes: []const u8) ?f32 {
    var rest = bytes;
    if (std.mem.endsWith(u8, rest, "db")) rest = rest[0 .. rest.len - 2];
    const negative = rest.len > 0 and rest[0] == '-';
    if (negative) rest = rest[1..];
    if (rest.len == 0 or rest.len > number_chars) return null;
    var units: f32 = 0;
    var scale: f32 = 1;
    var fraction = false;
    var digits: u32 = 0;
    for (rest) |byte| {
        if (byte == '.' and !fraction) {
            fraction = true;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return null;
        digits += 1;
        units = units * 10 + @as(f32, @floatFromInt(byte - '0'));
        if (fraction) scale *= 10;
    }
    if (digits == 0) return null;
    const number = units / scale;
    if (number > number_max) return null;
    return if (negative) -number else number;
}

/// The literal a widget writes for `number` in `slot`, into `out`.
pub fn format(slot: Slot, number: f32, out: *[literal_cap]u8) []const u8 {
    return switch (slot) {
        .eq_on, .shimmer_on, .mute_0, .mute_1 => std.fmt.bufPrint(out, "{d:.0}", .{number}),
        .shimmer, .wet => std.fmt.bufPrint(out, "{d:.2}", .{number}),
        .level_0, .level_1, .level_2, .level_3 => std.fmt.bufPrint(out, "{d:.2}db", .{number}),
        .send_0, .send_1, .send_2, .send_3 => std.fmt.bufPrint(out, "{d:.0}db", .{if (@abs(number) < 0.5) 0 else number}),
    } catch unreachable;
}

const testing = std.testing;

const sample =
    \\# mix
    \\if (tog(1, "eq")) a;
    \\if (tog(0, "shimmer")) b.c(k(0~0.16~1, name="shimmer"));
    \\wet := room.wet * k(0~0.73~1, "wet");
    \\mixed := mixer(level = -2.68db, -8.45db, -5.14db, -4.11db,
    \\send = -60db, 0db, 0db, -60db, safe[3] = 1, mute[0] = 0, mute[1] = 1);
;

fn slice_of(text: []const u8, value: Value) []const u8 {
    return text[value.range.start..value.range.end];
}

// Locks every slot on a sample of the mix: each binds, its range holds its literal, and a `k`
// keeps its ends.
test "every slot binds on the mix's lines" {
    const parsed = Parse.run(sample);
    try testing.expectEqual(@as(u32, 0), parsed.error_count);
    for (parsed.values) |value| try testing.expect(value != null);
    try testing.expectEqualStrings("1", slice_of(sample, parsed.get(.eq_on).?));
    try testing.expectEqualStrings("0", slice_of(sample, parsed.get(.shimmer_on).?));
    try testing.expectEqualStrings("0.16", slice_of(sample, parsed.get(.shimmer).?));
    try testing.expectEqualStrings("0.73", slice_of(sample, parsed.get(.wet).?));
    try testing.expectEqualStrings("-5.14db", slice_of(sample, parsed.get(.level_2).?));
    try testing.expectEqualStrings("-60db", slice_of(sample, parsed.get(.send_3).?));
    try testing.expectEqualStrings("1", slice_of(sample, parsed.get(.mute_1).?));
    try testing.expectEqual(@as(f32, -2.68), parsed.get(.level_0).?.number);
    try testing.expectEqual(@as(f32, 1), parsed.get(.wet).?.hi);
}

// Locks the literal reader: signs, decimals, a unit, and what is not a number.
test "read_number takes the forms of section 2" {
    try testing.expectEqual(@as(?f32, 0), read_number("0db"));
    try testing.expectEqual(@as(?f32, -60), read_number("-60db"));
    try testing.expectEqual(@as(?f32, 0.73), read_number("0.73"));
    try testing.expectEqual(@as(?f32, 0.5), read_number(".5"));
    try testing.expectEqual(@as(?f32, null), read_number("-"));
    try testing.expectEqual(@as(?f32, null), read_number("db"));
    try testing.expectEqual(@as(?f32, null), read_number("1.2.3"));
    try testing.expectEqual(@as(?f32, null), read_number("12ms"));
}

// Locks a slot's literal round trip: what `format` writes reads back to the same two decimals.
test "format writes what read_number reads" {
    var out: [literal_cap]u8 = undefined;
    try testing.expectEqualStrings("-2.68db", format(.level_0, -2.68, &out));
    try testing.expectEqualStrings("-60.00db", format(.level_1, -60, &out));
    try testing.expectEqualStrings("0db", format(.send_1, 0.2, &out));
    try testing.expectEqualStrings("-60db", format(.send_0, -60, &out));
    try testing.expectEqualStrings("1", format(.mute_0, 1, &out));
    try testing.expectEqualStrings("0.16", format(.shimmer, 0.16, &out));
    try testing.expectEqual(@as(?f32, -2.68), read_number(format(.level_0, -2.68, &out)));
}

// Locks section 3: a value out of range binds and marks its literal; a broken list binds none of
// its slots and marks the list; a `k` with crossed ends binds nothing and marks the call.
test "what breaks is marked and binds what it can" {
    const far = Parse.run("level = -2db, 99db, 0db, 0db");
    try testing.expectEqual(@as(f32, 99), far.get(.level_1).?.number);
    try testing.expectEqual(@as(u32, 1), far.error_count);
    const short = Parse.run("level = -2db, 3db, x");
    try testing.expectEqual(@as(?Value, null), short.get(.level_0));
    try testing.expectEqual(@as(u32, 1), short.error_count);
    const crossed = "k(1~0.5~0, \"wet\")";
    const bad = Parse.run(crossed);
    try testing.expectEqual(@as(?Value, null), bad.get(.wet));
    try testing.expectEqual(@as(u32, 1), bad.error_count);
    try testing.expectEqual(@as(u32, 0), bad.errors[0].start);
    const flag_far = Parse.run("tog(2, \"eq\")");
    try testing.expect(flag_far.get(.eq_on) != null);
    try testing.expectEqual(@as(u32, 1), flag_far.error_count);
}

// Locks what is not a binding: a deleted call leaves its slot unbound with no error, a call in a
// string binds nothing, a heading binds nothing, and the first of two binds.
test "only the first real call binds" {
    try testing.expectEqual(@as(?Value, null), Parse.run("wet := room.wet;").get(.wet));
    try testing.expectEqual(@as(?Value, null), Parse.run("x(\"k(0~0.5~1, \\\"wet\\\")\");").get(.wet));
    try testing.expectEqual(@as(?Value, null), Parse.run("# k(0~0.5~1, \"wet\")").get(.wet));
    const twice = Parse.run("k(0~0.1~1, \"wet\");\nk(0~0.2~1, \"wet\");");
    try testing.expectEqual(@as(f32, 0.1), twice.get(.wet).?.number);
}

// Locks that a widget reads what it wrote: the largest number the text may hold, in the widest
// format, fits `literal_cap` and reads back, and a number past the limit is no number.
test "the longest literal round trips" {
    var out: [literal_cap]u8 = undefined;
    const bytes = format(.shimmer, -number_max, &out);
    try testing.expectApproxEqRel(-number_max, read_number(bytes).?, 1e-5);
    try testing.expectEqual(@as(?f32, null), read_number("99999999999999999"));
}

// Locks a line cut anywhere, as typing and deleting leave it: every prefix of every line, and
// every line with one byte gone, parses without reading past its tokens. The worked case is
// `mute[1] =` at a line's end, whose value is the word after the last.
test "a line cut anywhere parses" {
    const cut = Parse.run("mute[1] =");
    try testing.expectEqual(@as(?Value, null), cut.get(.mute_1));
    try testing.expectEqual(@as(u32, 1), cut.error_count);
    var buffer: [512]u8 = undefined;
    for (0..sample.len + 1) |length| _ = Parse.run(sample[0..length]);
    for (0..sample.len) |gone| {
        @memcpy(buffer[0..gone], sample[0..gone]);
        const tail = sample[gone + 1 ..];
        @memcpy(buffer[gone..][0..tail.len], tail);
        _ = Parse.run(buffer[0 .. sample.len - 1]);
    }
}

// Locks `shift` against a full parse: rewriting each slot's literal to a longer one, its later
// ranges moved by the difference, gives what a pass over the new text gives.
test "shift agrees with a full parse after every write" {
    var buffer: [512]u8 = undefined;
    for (0..slot_count) |index| {
        var parsed = Parse.run(sample);
        const value = parsed.values[index].?;
        const start = value.range.start;
        const end = value.range.end;
        const swap = if (index < 2 or index >= 12) "0" else "-1.25";
        @memcpy(buffer[0..start], sample[0..start]);
        @memcpy(buffer[start..][0..swap.len], swap);
        const tail = sample[end..];
        @memcpy(buffer[start + swap.len ..][0..tail.len], tail);
        const rewritten = buffer[0 .. start + swap.len + tail.len];
        const delta = @as(i32, @intCast(swap.len)) - @as(i32, @intCast(end - start));
        parsed.shift(end, delta);
        try testing.expectEqual(@as(u32, @intCast(start + swap.len)), parsed.values[index].?.range.end);
        const full = Parse.run(rewritten);
        for (parsed.values, full.values) |shifted, whole| {
            try testing.expectEqual(whole.?.range, shifted.?.range);
        }
    }
}

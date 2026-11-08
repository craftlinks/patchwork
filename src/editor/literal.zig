//! Number literals in the editor's text: a fixed-point value that a widget can write back with
//! exactly the digits it read, and the shift of byte ranges after such a write.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Fixed Point
//! A knob bound to `0.023` in the text must write `0.024`, not `0.0240000002`, and a value it
//! did not move must keep its spelling. So a literal is `units / 10^decimals`, with `units` an
//! `i64`, parsed and formatted with integer arithmetic only. `bare` remembers the `.25` style
//! (no integer digit), which `format` keeps only while the value is below 1.
//! ```text
//! literal   [-] digits [. digits]  or  [-] . digits   no exponent
//! bounds    at most integer_digits_max integer digits and decimals_max decimals
//! ```
//!
//! ## 2. Steps
//! A widget over `lo ~ value ~ hi` moves in steps of the value's last digit: `steps` rounds
//! `lo` up and `hi` down to the value's decimals, and an empty result (`lo >= hi` there) means
//! the widget has nowhere to move. `with_units` is the same literal at a new value.
//!
//! ## 3. Writing Back
//! The text is the source of truth, and an app that binds widgets to literals follows two rules
//! that keep the two from looping: a parse never writes, and a write never parses. In order:
//! ```text
//! an edit the app did not cause -> the app's parse (one pass)    -> widgets set from the text
//! a widget grabbed              -> Editor.gesture_begin
//! each step of the widget       -> write (one replace)  -> shift every kept range after it
//!                                  -> the revision the widgets agree with = Editor.revision
//! the widget released           -> Editor.gesture_end (one undo entry) -> one full parse
//! ```
//! While a drag is held, keys and pastes go nowhere, since undo asserts inside a gesture. A
//! single write outside a gesture, such as a reset, is its own undo entry. `examples/live`
//! (section 3 of its guide) and `examples/session` (`bindings.zig`) are the worked apps; the
//! grammar that finds the literals stays in each app, since each app's numbers mean something
//! of their own.
//!
//! ## 4. Shift
//! `shift` moves each edge of a range at or after byte `at` by `delta`, the change in length of
//! a write that ended at `at`. A range that holds the rewritten literal grows or shrinks with
//! it; a range wholly before it stays.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: a literal is at most `literal_cap` bytes, formatted into the caller's array.
//! - `pow10` of every bound fits an `i64` with room for one more digit (the `comptime` block).

const std = @import("std");
const assert = std.debug.assert;
const buffer = @import("buffer.zig");

pub const Range = buffer.Range;

pub const integer_digits_max: u32 = 9;
pub const decimals_max: u32 = 6;
/// Bytes of the longest literal: a sign, 9 digits, a point, and 6 decimals.
pub const literal_cap: u32 = 1 + integer_digits_max + 1 + decimals_max;

/// `units / 10^decimals` (section 1).
pub const Fixed = struct {
    units: i64,
    decimals: u8,
    /// Written without an integer digit, as in `.25`.
    bare: bool,

    /// The same literal at `units`, its decimals kept; the bare style only below 1.
    pub fn with_units(fixed: Fixed, units: i64) Fixed {
        assert(fixed.decimals <= decimals_max);
        const result: Fixed = .{
            .units = units,
            .decimals = fixed.decimals,
            .bare = fixed.bare and @abs(units) < pow10(fixed.decimals),
        };
        assert(!result.bare or @abs(result.units) < pow10(result.decimals));
        return result;
    }
};

/// A widget's range of units at the value's decimals (section 2).
pub const Steps = struct { lo: i64, hi: i64 };

pub const Rounding = enum { up, down, nearest };

/// Parses `[-] digits [. digits]` or `[-] . digits` (section 1), or null.
pub fn parse(bytes: []const u8) ?Fixed {
    if (bytes.len == 0) return null;
    if (bytes.len > literal_cap) return null;
    const negative = bytes[0] == '-';
    var index: usize = @intFromBool(negative);
    var units: i64 = 0;
    var integer_digits: u32 = 0;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {
        units = units * 10 + (bytes[index] - '0');
        integer_digits += 1;
    }
    var decimals: u32 = 0;
    if (index < bytes.len and bytes[index] == '.') {
        index += 1;
        while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {
            units = units * 10 + (bytes[index] - '0');
            decimals += 1;
        }
        if (decimals == 0) return null;
    }
    if (index != bytes.len) return null;
    if (integer_digits == 0 and decimals == 0) return null;
    if (integer_digits > integer_digits_max) return null;
    if (decimals > decimals_max) return null;
    const fixed: Fixed = .{
        .units = if (negative) -units else units,
        .decimals = @intCast(decimals),
        .bare = integer_digits == 0,
    };
    assert(fixed.decimals <= decimals_max);
    return fixed;
}

/// Writes `fixed` with exactly its decimals; the bare style holds only below 1 (section 1).
pub fn format(out: *[literal_cap]u8, fixed: Fixed) []const u8 {
    assert(fixed.decimals <= decimals_max);
    const scale = pow10(fixed.decimals);
    const magnitude: u64 = @abs(fixed.units);
    const whole = magnitude / scale;
    const fraction = magnitude % scale;
    var length: usize = 0;
    if (fixed.units < 0) {
        out[0] = '-';
        length = 1;
    }
    if (!(fixed.bare and whole == 0 and fixed.decimals > 0)) {
        const printed = std.fmt.bufPrint(out[length..], "{d}", .{whole}) catch unreachable;
        length += printed.len;
    }
    if (fixed.decimals > 0) {
        out[length] = '.';
        length += 1;
        var digit: u32 = fixed.decimals;
        while (digit > 0) : (digit -= 1) {
            const place = pow10(@intCast(digit - 1));
            out[length] = '0' + @as(u8, @intCast((fraction / place) % 10));
            length += 1;
        }
    }
    assert(length <= literal_cap);
    return out[0..length];
}

/// `fixed` in steps of `decimals` decimals, rounded `way` when it has more.
pub fn rescale(fixed: Fixed, decimals: u8, way: Rounding) i64 {
    assert(decimals <= decimals_max);
    assert(fixed.decimals <= decimals_max);
    if (decimals >= fixed.decimals) {
        return fixed.units * @as(i64, @intCast(pow10(decimals - fixed.decimals)));
    }
    const divisor: i64 = @intCast(pow10(fixed.decimals - decimals));
    return switch (way) {
        .down => @divFloor(fixed.units, divisor),
        .up => -@divFloor(-fixed.units, divisor),
        // Halves round away from zero, so the rounding is symmetric about 0.
        .nearest => if (fixed.units >= 0)
            @divFloor(fixed.units * 2 + divisor, divisor * 2)
        else
            -@divFloor(-fixed.units * 2 + divisor, divisor * 2),
    };
}

/// The units a widget over `lo ~ value ~ hi` moves between (section 2), or null when there is
/// no room at the value's decimals.
pub fn steps(lo: Fixed, value: Fixed, hi: Fixed) ?Steps {
    const result: Steps = .{
        .lo = rescale(lo, value.decimals, .up),
        .hi = rescale(hi, value.decimals, .down),
    };
    if (result.lo >= result.hi) return null;
    assert(result.lo < result.hi);
    return result;
}

pub fn pow10(exponent: u8) u64 {
    assert(exponent <= decimals_max + integer_digits_max);
    var result: u64 = 1;
    var index: u8 = 0;
    while (index < exponent) : (index += 1) result *= 10;
    return result;
}

pub fn to_f32(fixed: Fixed) f32 {
    const scale: f32 = @floatFromInt(pow10(fixed.decimals));
    return @as(f32, @floatFromInt(fixed.units)) / scale;
}

pub fn to_f64(fixed: Fixed) f64 {
    const scale: f64 = @floatFromInt(pow10(fixed.decimals));
    return @as(f64, @floatFromInt(fixed.units)) / scale;
}

/// Moves each edge of `range` at or after byte `at` by `delta` (section 4).
pub fn shift(range: *Range, at: u32, delta: i32) void {
    if (range.start >= at) range.start = moved(range.start, delta);
    if (range.end >= at) range.end = moved(range.end, delta);
    assert(range.start <= range.end);
}

/// `byte` moved by `delta`, which must not move it before the start of the text.
pub fn moved(byte: u32, delta: i32) u32 {
    const result = @as(i64, byte) + delta;
    assert(result >= 0);
    return @intCast(result);
}

/// Rewrites `range` of `editor` (an `*EditorOf(L)`) with `fixed`, through `replace`, so inside
/// an open gesture it joins that gesture's undo entry (section 3). Returns the change in length
/// for `shift`, or null when the editor refused the edit.
pub fn write(editor: anytype, range: Range, fixed: Fixed) ?i32 {
    assert(range.start <= range.end);
    var out: [literal_cap]u8 = undefined;
    const bytes = format(&out, fixed);
    assert(bytes.len > 0);
    if (!editor.replace(range, bytes)) return null;
    return @as(i32, @intCast(bytes.len)) - @as(i32, @intCast(range.end - range.start));
}

comptime {
    assert(literal_cap == 17);
    // 9 integer digits and 6 decimals stay far inside an i64.
    assert(pow10(integer_digits_max + decimals_max) < std.math.maxInt(i64) / 10);
}

// ------------------------------------------------------------------------------ tests

const testing = std.testing;

// Locks section 1: each spelling formats back to itself, the bare style holds only below 1, a
// value keeps its decimals, and an exponent, a bare point, or a lone sign is refused.
test "literals round trip at their decimals" {
    var out: [literal_cap]u8 = undefined;
    const samples = [_][]const u8{ "0.023", "-0.98", ".25", "10", "4000", "-0.5", "0.000001", "-.5" };
    for (samples) |sample| {
        const fixed = parse(sample).?;
        try testing.expectEqualStrings(sample, format(&out, fixed));
    }
    try testing.expectEqualStrings("10.00", format(&out, .{ .units = 1000, .decimals = 2, .bare = false }));
    try testing.expectEqualStrings("0.00", format(&out, .{ .units = 0, .decimals = 2, .bare = false }));
    try testing.expectEqualStrings("-0.01", format(&out, .{ .units = -1, .decimals = 2, .bare = false }));
    try testing.expectEqualStrings(".30", format(&out, .{ .units = 30, .decimals = 2, .bare = true }));
    try testing.expectEqualStrings("1.00", format(&out, .{ .units = 100, .decimals = 2, .bare = true }));
    try testing.expectEqual(@as(?Fixed, null), parse("1e3"));
    try testing.expectEqual(@as(?Fixed, null), parse("1."));
    try testing.expectEqual(@as(?Fixed, null), parse("-"));
    try testing.expectEqual(@as(?Fixed, null), parse("1234567890"));
    try testing.expectEqual(@as(?Fixed, null), parse("0.1234567"));
    try testing.expectApproxEqAbs(@as(f32, -0.98), to_f32(parse("-0.98").?), 1e-6);
    try testing.expectEqual(@as(f64, 0.25), to_f64(parse(".25").?));
}

// Locks sections 1 and 2: rescaling each way, the knob's steps at the value's decimals, an empty
// range, and with_units dropping the bare style at 1 and above.
test "rescale, steps, and with_units" {
    try testing.expectEqual(@as(i64, 1), rescale(parse("0.001").?, 2, .up));
    try testing.expectEqual(@as(i64, 99), rescale(parse("0.999").?, 2, .down));
    try testing.expectEqual(@as(i64, -98), rescale(parse("-0.975").?, 2, .nearest));
    try testing.expectEqual(@as(i64, 4000), rescale(parse("40").?, 2, .down));
    try testing.expectEqual(Steps{ .lo = -980, .hi = 980 }, steps(parse("-0.98").?, parse("0.000").?, parse("0.98").?).?);
    try testing.expectEqual(Steps{ .lo = 0, .hi = 1 }, steps(parse("0").?, parse("1").?, parse("1").?).?);
    try testing.expectEqual(@as(?Steps, null), steps(parse("0.5").?, parse("1").?, parse("0.9").?));
    const bare = parse(".25").?;
    try testing.expectEqual(Fixed{ .units = 30, .decimals = 2, .bare = true }, bare.with_units(30));
    try testing.expectEqual(Fixed{ .units = 100, .decimals = 2, .bare = false }, bare.with_units(100));
}

// Locks section 4: rewriting "0.5" (bytes 6..9) as "0.75" moves the edges at or after byte 9 by
// one, so a range holding the literal grows, and a range wholly before it stays.
test "shift moves the edges at or after the write" {
    var literal_range: Range = .{ .start = 6, .end = 9 };
    var call: Range = .{ .start = 2, .end = 12 };
    var before: Range = .{ .start = 0, .end = 1 };
    var after: Range = .{ .start = 9, .end = 14 };
    for ([_]*Range{ &literal_range, &call, &before, &after }) |range| shift(range, 9, 1);
    try testing.expectEqual(Range{ .start = 6, .end = 10 }, literal_range);
    try testing.expectEqual(Range{ .start = 2, .end = 13 }, call);
    try testing.expectEqual(Range{ .start = 0, .end = 1 }, before);
    try testing.expectEqual(Range{ .start = 10, .end = 15 }, after);
    try testing.expectEqual(@as(u32, 3), moved(5, -2));
}

const fixture = struct {
    var editor: @import("editor.zig").Editor = undefined;
};

// Locks section 3 through a real editor: three writes inside one gesture, each a new spelling,
// are one undo entry.
test "writes inside a gesture are one undo entry" {
    const editor = &fixture.editor;
    editor.init(@import("../ui.zig").id("literal", 0), @TypeOf(editor.*).default_style);
    try testing.expect(editor.load("a := k(0~0.5~1, \"a\")\n"));
    var range: Range = .{ .start = 9, .end = 12 };
    try testing.expectEqualStrings("0.5", editor.text()[range.start..range.end]);
    const entries = editor.buffer.undo_count;
    editor.gesture_begin();
    var fixed = parse("0.5").?;
    for ([_]i64{ 6, 75, 100 }) |units| {
        // "0.6", then "0.75" at two decimals, then "1.00".
        fixed = if (units == 75) .{ .units = 75, .decimals = 2, .bare = false } else fixed.with_units(units);
        const delta = write(editor, range, fixed).?;
        range.end = moved(range.end, delta);
    }
    editor.gesture_end();
    try testing.expectEqualStrings("a := k(0~1.00~1, \"a\")\n", editor.text());
    try testing.expectEqual(entries + 1, editor.buffer.undo_count);
}

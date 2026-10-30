//! The patch as a language for `editor.EditorOf`: the recipe for setting code in proportional
//! faces. It declares `faces`, one per class, so the editor sets calls in italics and declared
//! names in bold and measures every glyph.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Classes
//! ```text
//! keyword      if module return sum Note       regular, grey
//! call         an identifier before "("        italic
//! declared     a name in `declared`            bold
//! bass..wet    the mixer's channels            regular, the channel's colour
//! number       digits with a unit; "-" leads one after an operator or "~"
//!              lo~VALUE~hi: the ends dim, the middle bright
//! string       "..."                           cream
//! punctuation  everything else                 grey
//! ```
//!
//! A line starting "# " is a heading: `level_of` sizes it (`scales`), its "#" is one token and
//! the rest of the line another, so a section's name may hold spaces.
//!
//! ## 2. A Pure Function of the Line
//! `next` sees one line and keeps no state, so `State` is `normal` alone and declared names are
//! a fixed list. A real language would resolve scopes; a recipe need not. Whether a "-" leads a
//! number is decided by the byte before it.
//!
//! ## 3. TigerStyle Invariants
//! - `next` makes progress on every token, so a line costs O(its bytes) tokens.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const editor = patchwork.editor;
const text = patchwork.text;
const look = @import("look.zig");

pub const State = enum(u8) { normal };
pub const Class = enum(u8) { plain, keyword, call, declared, number, range_end, string, punctuation, hash, heading, bass, pads, line, wet };

pub const faces: [14]text.Face = .{
    .serif, .serif, .serif_italic, .serif_bold, .serif, .serif, .serif, .serif, .serif, .serif_bold, .serif, .serif, .serif, .serif,
};

pub const palette: [14][4]f32 = .{
    look.ink,               look.keyword,           look.ink,               look.ink,               look.number,
    look.range_end,         look.string,            look.punctuation,       look.faint,             look.ink,
    look.channel_colors[0], look.channel_colors[1], look.channel_colors[2], look.channel_colors[3],
};

/// A heading is 26 px over code's 16.
pub const scales: [2]f32 = .{ 1, 26.0 / look.code_size };

pub fn level_of(line: []const u8) u8 {
    return if (std.mem.startsWith(u8, line, "# ")) 1 else 0;
}

const keywords = [_][]const u8{ "if", "module", "return", "sum", "Note" };

/// Names the patch declares, across its sections.
const declared = [_][]const u8{ "round", "room", "env", "a", "b", "hiss", "mixed", "diffused" };

/// The mixer's channels, in the order of their classes. They win over `declared`.
const channels = [_][]const u8{ "bass", "pads", "line", "wet" };

pub fn is_ident(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

/// True when the range starting with a number ending at `stop` (a "~" there) has three parts.
fn three_part(bytes: []const u8, stop: u32) bool {
    var tildes: u32 = 0;
    var at = stop;
    while (at < bytes.len) : (at += 1) {
        const byte = bytes[at];
        if (byte == '~') {
            tildes += 1;
        } else if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-')) break;
    }
    return tildes >= 2;
}

/// True when the code before `at` ends in a value, so a "-" there subtracts.
fn after_value(line: []const u8, at: u32) bool {
    var index = at;
    while (index > 0 and line[index - 1] == ' ') index -= 1;
    if (index == 0) return false;
    const byte = line[index - 1];
    return is_ident(byte) or byte == ')' or byte == '%';
}

pub fn next(line: []const u8, at: *u32, state: *State) ?editor.Token(Class) {
    assert(state.* == .normal);
    assert(at.* <= line.len);
    var index = at.*;
    if (index == 0 and level_of(line) == 1) {
        at.* = 1;
        return .{ .start = 0, .end = 1, .class = .hash };
    }
    while (index < line.len and line[index] == ' ') index += 1;
    at.* = index;
    if (index == line.len) return null;
    if (level_of(line) == 1) {
        at.* = @intCast(line.len);
        return .{ .start = index, .end = at.*, .class = .heading };
    }
    const first = line[index];
    var stop = index + 1;
    var class: Class = .punctuation;
    const leads_number = first == '-' and index + 1 < line.len and std.ascii.isDigit(line[index + 1]) and !after_value(line, index);
    if (std.ascii.isDigit(first) or leads_number) {
        while (stop < line.len and (std.ascii.isAlphanumeric(line[stop]) or line[stop] == '.' or line[stop] == '%')) stop += 1;
        const before_tilde = stop < line.len and line[stop] == '~';
        const after_tilde = index > 0 and line[index - 1] == '~';
        class = if (after_tilde != before_tilde) .range_end else .number;
        if (before_tilde and !after_tilde and !three_part(line, stop)) class = .number;
    } else if (is_ident(first)) {
        while (stop < line.len and is_ident(line[stop])) stop += 1;
        class = word_class(line[index..stop]);
        if (class == .plain and stop < line.len and line[stop] == '(') class = .call;
    } else if (first == '"') {
        while (stop < line.len and line[stop] != '"') stop += 1;
        stop = @min(stop + 1, @as(u32, @intCast(line.len)));
        class = .string;
    }
    at.* = stop;
    return .{ .start = index, .end = stop, .class = class };
}

fn word_class(word: []const u8) Class {
    for (channels, 0..) |name, index| {
        if (std.mem.eql(u8, word, name)) return @fromBackingInt(@backingInt(Class.bass) + @as(u8, @intCast(index)));
    }
    for (declared) |name| {
        if (std.mem.eql(u8, word, name)) return .declared;
    }
    for (keywords) |name| {
        if (std.mem.eql(u8, word, name)) return .keyword;
    }
    return .plain;
}

fn classes_of(line: []const u8, out: []Class) u32 {
    var state: State = .normal;
    var at: u32 = 0;
    var count: u32 = 0;
    while (next(line, &at, &state)) |token| {
        out[count] = token.class;
        count += 1;
    }
    return count;
}

// Locks the language on the pad's lines: declared names bold, an identifier before "(" a call,
// the range 0~0.1~1 as dim end, bright value, dim end, and a "-" between values punctuation.
test "tokens of the pad's lines" {
    var classes: [32]Class = undefined;
    var count = classes_of("a := n.unison() * saws;", &classes);
    const wanted = [_]Class{
        .declared,    .punctuation, .punctuation, .plain,       .punctuation, .call, .punctuation,
        .punctuation, .punctuation, .plain,       .punctuation,
    };
    try std.testing.expectEqualSlices(Class, &wanted, classes[0..count]);
    count = classes_of("saws = 0~0.1~1", &classes);
    try std.testing.expectEqualSlices(Class, &.{ .plain, .punctuation, .range_end, .punctuation, .number, .punctuation, .range_end }, classes[0..count]);
    count = classes_of("b := sine(n - 12) * sub;", &classes);
    try std.testing.expectEqual(Class.punctuation, classes[6]);
    try std.testing.expectEqual(Class.number, classes[7]);
}

// Locks the mix's lines: a channel's name takes its colour over `declared`, the range 0~0.73~1 is
// dim end, bright value, dim end, a string is one token, and "-2.68db" after "=" is one number
// while a minus between names is punctuation.
test "tokens of a mix line" {
    var classes: [32]Class = undefined;
    var count = classes_of("wet := room.wet * k(0~0.73~1, \"wet\");", &classes);
    const wanted = [_]Class{
        .wet,         .punctuation, .punctuation, .declared,    .punctuation, .wet,         .punctuation,
        .call,        .punctuation, .range_end,   .punctuation, .number,      .punctuation, .range_end,
        .punctuation, .string,      .punctuation, .punctuation,
    };
    try std.testing.expectEqualSlices(Class, &wanted, classes[0..count]);
    count = classes_of("level = -2.68db, n - 12", &classes);
    try std.testing.expectEqualSlices(Class, &.{ .plain, .punctuation, .number, .punctuation, .plain, .punctuation, .number }, classes[0..count]);
}

// Locks a heading: the "#" and the name are one token each, the name keeps its spaces, a line
// of "# " alone has no name, and a "#" elsewhere is punctuation at the body size.
test "a heading is two tokens and a size" {
    var classes: [4]Class = undefined;
    try std.testing.expectEqual(@as(u32, 2), classes_of("# reverb tank", &classes));
    try std.testing.expectEqualSlices(Class, &.{ .hash, .heading }, classes[0..2]);
    try std.testing.expectEqual(@as(u32, 1), classes_of("# ", &classes));
    try std.testing.expectEqual(@as(u8, 1), level_of("# "));
    try std.testing.expectEqual(@as(u8, 0), level_of("#x"));
    try std.testing.expectEqual(@as(u8, 0), level_of(" # x"));
    try std.testing.expectEqual(@as(f32, 1.625), scales[1]);
}

// Locks the contract of `language.zig`, section 2, on every line of the patch.
test "the patch's lines keep the language contract" {
    var lines = std.mem.splitScalar(u8, @import("app.zig").patch_text, '\n');
    while (lines.next()) |line| _ = editor.language.verify_line(@This(), line, .normal);
}

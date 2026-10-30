//! The patch as a language for `editor.EditorOf`: the recipe for setting code in proportional
//! faces. It declares `faces`, one per class, so the editor sets calls in italics and declared
//! names in bold and measures every glyph.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Classes
//! The classes of `code.zig`, section 3, without the mix section's `channel`: the mix stays
//! typeset there, because its numbers are slots bound to widgets. Both share `code.token_at`,
//! so a line reads the same in either.
//!
//! ## 2. A Pure Function of the Line
//! `next` sees one line and keeps no state, so `State` is `normal` alone and declared names are
//! a fixed list. A real language would resolve scopes; a recipe need not. Whether a "-" leads a
//! number is decided by the byte before it, where `code.tokenize` knows the previous token.
//!
//! ## 3. TigerStyle Invariants
//! - `next` makes progress on every token, so a line costs O(its bytes) tokens.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const editor = patchwork.editor;
const text = patchwork.text;
const look = @import("look.zig");
const code = @import("code.zig");

pub const State = enum(u8) { normal };
pub const Class = enum(u8) { plain, keyword, call, declared, number, range_end, string, punctuation };

pub const faces: [8]text.Face = .{
    .serif, .serif, .serif_italic, .serif_bold, .serif, .serif, .serif, .serif,
};

pub const palette: [8][4]f32 = .{
    look.ink, look.keyword, look.ink, look.ink, look.number, look.range_end, look.string, look.punctuation,
};

/// Names the pad and the tank declare.
const declared = [_][]const u8{ "env", "a", "b", "hiss", "mixed", "diffused" };

/// True when the code before `at` ends in a value, so a "-" there subtracts.
fn after_value(line: []const u8, at: u32) bool {
    var index = at;
    while (index > 0 and line[index - 1] == ' ') index -= 1;
    if (index == 0) return false;
    const byte = line[index - 1];
    return code.is_ident(byte) or byte == ')' or byte == '%';
}

pub fn next(line: []const u8, at: *u32, state: *State) ?editor.Token(Class) {
    assert(state.* == .normal);
    assert(at.* <= line.len);
    var index = at.*;
    while (index < line.len and line[index] == ' ') index += 1;
    at.* = index;
    if (index == line.len) return null;
    const token = code.token_at(line, index, after_value(line, index), .{ .declared = &declared });
    at.* = token.end;
    return .{ .start = token.start, .end = token.end, .class = class_of(token.class) };
}

fn class_of(class: code.Class) Class {
    return switch (class) {
        .plain, .channel, .space => .plain,
        .keyword => .keyword,
        .call => .call,
        .declared => .declared,
        .number => .number,
        .range_end => .range_end,
        .string => .string,
        .punctuation => .punctuation,
    };
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

// Locks the contract of `language.zig`, section 2, on every line of the patch.
test "the patch's lines keep the language contract" {
    var lines = std.mem.splitScalar(u8, @import("app.zig").patch_text, '\n');
    while (lines.next()) |line| _ = editor.language.verify_line(@This(), line, .normal);
}

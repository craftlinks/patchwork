//! The patch language, the editor's default: a per-line state machine with one carried state.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 0. A Language
//! This file is the reference implementation of the contract in `language.zig`: `State`,
//! `Class`, `palette`, and `next`. `editor.Editor` is `EditorOf` this language.
//!
//! ## 1. Why Per Line With a Start State
//! The editor colours only the visible lines, every frame, so tokenizing must start at any
//! line without reading the lines above it. The only construct that crosses a line break is
//! a block comment, so a line's tokens are a pure function of its bytes and one `State`.
//! `editor/buffer.zig` keeps each line's start state (`[line_cap]State`) and, after an edit,
//! recomputes them from the edited line until a start state matches its cached value. Lines
//! hold no LF; the tokenizer never sees one.
//!
//! ## 2. Token Rules
//! Bytes up to and including space separate tokens (the buffer holds no tab or CR).
//! ```text
//! comment      // to the end of the line;  /* to the next */ (not nesting), which may end
//!              on a later line: the state is then block_comment
//! string       " to the next unescaped ", or the end of the line; \ escapes one byte
//! number       digits [. digits] [e|E [+|-] digits]  or  . digits ...   (no sign: in
//!              `-0.98` the minus is an operator, so a binding parser reads the sign itself)
//! keyword      fn let if else for in return true false out
//! identifier   [A-Za-z_] [A-Za-z0-9_]* , or any run starting with a non-ASCII byte
//!              (`k` and `shape` are identifiers; step 18's parser recognizes them)
//! operator     :=  and each of  = + - * / % < > ! & | ^ ~ ?
//! punctuation  every other byte: ( ) [ ] { } , ; . : and the rest of ASCII
//! ```
//! An exponent is taken only when a digit follows it, so `2else` is a number and a keyword.
//!
//! ## 3. TigerStyle Invariants
//! - `next` consumes at least one byte per token, so a line of `n` bytes yields at most `n`
//!   tokens; `end_state` is O(line length). Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const language = @import("language.zig");

/// The state carried from the end of one line to the start of the next.
pub const State = enum(u8) {
    normal,
    block_comment,
};

/// Token classes; the value indexes the editor's palette.
pub const Class = enum(u8) {
    comment,
    number,
    string,
    keyword,
    identifier,
    operator,
    punctuation,
};

pub const class_count: u32 = 7;

/// Bytes `start .. end` of the line, of `class`.
pub const Token = language.Token(Class);

/// The default colours, straight RGBA, indexed by `Class`.
pub const palette: [class_count][4]f32 = .{
    .{ 0.47, 0.53, 0.58, 1 },
    .{ 0.95, 0.68, 0.40, 1 },
    .{ 0.62, 0.82, 0.52, 1 },
    .{ 0.80, 0.55, 0.92, 1 },
    .{ 0.86, 0.87, 0.84, 1 },
    .{ 0.45, 0.78, 0.92, 1 },
    .{ 0.62, 0.64, 0.68, 1 },
};

/// The colours on a light background (`EditorOf(L).light_palette`), indexed by `Class`.
pub const palette_light: [class_count][4]f32 = .{
    .{ 0.45, 0.50, 0.55, 1 },
    .{ 0.72, 0.38, 0.08, 1 },
    .{ 0.20, 0.50, 0.22, 1 },
    .{ 0.50, 0.25, 0.70, 1 },
    .{ 0.15, 0.16, 0.18, 1 },
    .{ 0.10, 0.45, 0.65, 1 },
    .{ 0.40, 0.42, 0.46, 1 },
};

pub const keywords = [_][]const u8{
    "fn", "let", "if", "else", "for", "in", "return", "true", "false", "out",
};

/// The next token of `line` at or after `at.*`, which advances past it; `state` carries a
/// block comment across lines. Null at the end of the line. See the module guide, section 2.
pub fn next(line: []const u8, at: *u32, state: *State) ?Token {
    assert(at.* <= line.len);
    if (state.* == .block_comment) {
        const start = at.*;
        const end = comment_end(line, start, state);
        at.* = end;
        if (end > start) return .{ .start = start, .end = end, .class = .comment };
    }
    var index = at.*;
    while (index < line.len and line[index] <= ' ') index += 1;
    if (index == line.len) {
        at.* = index;
        return null;
    }
    assert(state.* == .normal);
    const start = index;
    const lead = line[start];
    const class: Class, const end: u32 = scan: {
        if (lead == '/' and start + 1 < line.len) {
            if (line[start + 1] == '/') break :scan .{ .comment, @intCast(line.len) };
            if (line[start + 1] == '*') {
                state.* = .block_comment;
                break :scan .{ .comment, comment_end(line, start + 2, state) };
            }
        }
        if (lead == '"') break :scan .{ .string, string_end(line, start) };
        if (is_digit(lead)) break :scan .{ .number, number_end(line, start) };
        if (lead == '.' and start + 1 < line.len and is_digit(line[start + 1])) {
            break :scan .{ .number, number_end(line, start) };
        }
        if (is_word_start(lead)) {
            const word_end = identifier_end(line, start);
            const class: Class = if (is_keyword(line[start..word_end])) .keyword else .identifier;
            break :scan .{ class, word_end };
        }
        if (lead == ':' and start + 1 < line.len and line[start + 1] == '=') {
            break :scan .{ .operator, start + 2 };
        }
        if (std.mem.indexOfScalar(u8, "=+-*/%<>!&|^~?", lead) != null) {
            break :scan .{ .operator, start + 1 };
        }
        break :scan .{ .punctuation, start + 1 };
    };
    assert(end > start);
    assert(end <= line.len);
    at.* = end;
    return .{ .start = start, .end = end, .class = class };
}

/// The state at the end of `line` when it starts in `start`.
pub fn end_state(line: []const u8, start: State) State {
    return language.end_state(@This(), line, start);
}

/// Inside a block comment from `start`: the index after `*/` (the state becomes normal), or
/// the end of the line (the state stays block_comment).
fn comment_end(line: []const u8, start: u32, state: *State) u32 {
    assert(state.* == .block_comment);
    assert(start <= line.len);
    if (std.mem.indexOfPos(u8, line, start, "*/")) |close| {
        state.* = .normal;
        return @intCast(close + 2);
    }
    return @intCast(line.len);
}

fn string_end(line: []const u8, start: u32) u32 {
    assert(line[start] == '"');
    var index = start + 1;
    while (index < line.len) {
        if (line[index] == '\\') {
            index = @min(index + 2, @as(u32, @intCast(line.len)));
            continue;
        }
        if (line[index] == '"') return index + 1;
        index += 1;
    }
    return index;
}

fn number_end(line: []const u8, start: u32) u32 {
    var index = digits_end(line, start);
    if (index < line.len and line[index] == '.') index = digits_end(line, index + 1);
    if (index < line.len and (line[index] == 'e' or line[index] == 'E')) {
        var exponent = index + 1;
        if (exponent < line.len and (line[exponent] == '+' or line[exponent] == '-')) {
            exponent += 1;
        }
        if (exponent < line.len and is_digit(line[exponent])) index = digits_end(line, exponent);
    }
    assert(index > start);
    return index;
}

fn digits_end(line: []const u8, start: u32) u32 {
    var index = start;
    while (index < line.len and is_digit(line[index])) index += 1;
    return index;
}

fn identifier_end(line: []const u8, start: u32) u32 {
    var index = start + 1;
    while (index < line.len and is_word_byte(line[index])) index += 1;
    return index;
}

fn is_digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn is_word_start(byte: u8) bool {
    if (byte >= 0x80) return true;
    if (byte == '_') return true;
    return std.ascii.isAlphabetic(byte);
}

fn is_word_byte(byte: u8) bool {
    if (is_word_start(byte)) return true;
    return is_digit(byte);
}

fn is_keyword(word: []const u8) bool {
    assert(word.len >= 1);
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, word)) return true;
    }
    return false;
}

comptime {
    assert(@typeInfo(Class).@"enum".field_names.len == class_count);
    assert(@sizeOf(State) == 1);
    assert(language.check(@This()) == null);
}

const testing = std.testing;

fn expect_tokens(line: []const u8, start: State, expected: []const Token) !State {
    var state = start;
    var at: u32 = 0;
    for (expected) |want| {
        const got = next(line, &at, &state) orelse return error.TestExpectedToken;
        try testing.expectEqual(want, got);
    }
    try testing.expectEqual(@as(?Token, null), next(line, &at, &state));
    return state;
}

fn token(start: u32, end: u32, class: Class) Token {
    return .{ .start = start, .end = end, .class = class };
}

// Locks the classes on a step 18 line: a declaration, a binding call with a negative low
// bound (the minus is an operator, the number unsigned), a string, and a line comment.
test "a binding line splits into its classes" {
    const line = "hot := k(-0.98~0.445, \"flange\") // wet";
    const state = try expect_tokens(line, .normal, &.{
        token(0, 3, .identifier),
        token(4, 6, .operator),
        token(7, 8, .identifier),
        token(8, 9, .punctuation),
        token(9, 10, .operator),
        token(10, 14, .number),
        token(14, 15, .operator),
        token(15, 20, .number),
        token(20, 21, .punctuation),
        token(22, 30, .string),
        token(30, 31, .punctuation),
        token(32, 38, .comment),
    });
    try testing.expectEqual(State.normal, state);
}

// Locks keywords, numbers with exponents and leading dots, method calls, and an escaped
// quote inside a string that runs to the end of the line unterminated.
test "keywords, exponents, and strings" {
    _ = try expect_tokens("fn out() return 1.5e-3 .25 x.y", .normal, &.{
        token(0, 2, .keyword),
        token(3, 6, .keyword),
        token(6, 7, .punctuation),
        token(7, 8, .punctuation),
        token(9, 15, .keyword),
        token(16, 22, .number),
        token(23, 26, .number),
        token(27, 28, .identifier),
        token(28, 29, .punctuation),
        token(29, 30, .identifier),
    });
    _ = try expect_tokens("2e x \"a\\\"b", .normal, &.{
        token(0, 1, .number),
        token(1, 2, .identifier),
        token(3, 4, .identifier),
        token(5, 10, .string),
    });
}

// Locks block comments across lines: an opening line ends in block_comment, a middle line
// is one comment token, the closing line returns to normal after `*/`, and a `/*` inside a
// string or a line comment opens nothing.
test "block comments carry the state across lines" {
    const opened = try expect_tokens("a /* one", .normal, &.{
        token(0, 1, .identifier),
        token(2, 8, .comment),
    });
    try testing.expectEqual(State.block_comment, opened);
    try testing.expectEqual(State.block_comment, end_state("still inside", opened));
    const closed = try expect_tokens("two */ b", .block_comment, &.{
        token(0, 6, .comment),
        token(7, 8, .identifier),
    });
    try testing.expectEqual(State.normal, closed);
    try testing.expectEqual(State.normal, end_state("\"/*\" // /*", .normal));
    try testing.expectEqual(State.block_comment, end_state("", .block_comment));
    try testing.expectEqual(State.normal, end_state("/**/", .normal));
}

//! A C tokenizer for the code editor: a recipe, not library code.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Recipe
//! This file is a language for `patchwork.editor.EditorOf` (the contract in
//! `src/editor/language.zig`). An app copies it and changes it freely: it carries no API
//! promise, and it moves into the library only when three apps need the same one. This copy
//! is the docking workspace's (step 46), taken from the gallery's code page.
//!
//! ## 2. Token Rules
//! Bytes up to and including space separate tokens. The only construct that crosses a line
//! is a block comment, so the state is `normal` or `block_comment`.
//! ```text
//! comment       // to the end of the line (a line splice is not honoured);  /* to the
//!               next */ (not nesting), which may end on a later line
//! string        " to the next unescaped ", or the end of the line; \ escapes one byte; a
//!               prefix L, u, U, or u8 belongs to it; after #include, <...> is a string
//! char          ' to the next unescaped ', or the end of the line, with the same prefixes
//! number        the pp-number rule: a digit or . digit, then digits, letters, _, ., a sign
//!               right after e E p P, and ' before a digit or letter (C23 separators)
//! keyword       the C11 and C23 keywords that are not types
//! type_name     the built-in types and the common <stdint.h> and <stddef.h> names
//! preprocessor  on a line whose first non-space byte is #: the #, spaces, and the
//!               directive's name (`#  define` is one token); the rest tokenizes as usual
//! identifier    [A-Za-z_] [A-Za-z0-9_]* , or any run starting with a non-ASCII byte
//! operator      -> ++ -- <<= >>= << >> <= >= == != && || += -= *= /= %= &= |= ^=, then
//!               each of + - * / % < > = ! & | ^ ~ ?
//! punctuation   every other byte: ( ) [ ] { } , ; . : # and the rest of ASCII
//! ```
//!
//! ## 3. TigerStyle Invariants
//! - `next` consumes at least one byte per token; nothing allocates; every scan is bounded
//!   by the line.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");

pub const State = enum(u8) {
    normal,
    block_comment,
};

pub const Class = enum(u8) {
    comment,
    string,
    char,
    number,
    keyword,
    type_name,
    preprocessor,
    identifier,
    operator,
    punctuation,
};

pub const Token = patchwork.editor.Token(Class);

/// The default colours, straight RGBA, indexed by `Class`: the patch palette's family.
pub const palette: [10][4]f32 = .{
    .{ 0.47, 0.53, 0.58, 1 },
    .{ 0.62, 0.82, 0.52, 1 },
    .{ 0.52, 0.80, 0.70, 1 },
    .{ 0.95, 0.68, 0.40, 1 },
    .{ 0.80, 0.55, 0.92, 1 },
    .{ 0.95, 0.82, 0.45, 1 },
    .{ 0.92, 0.47, 0.56, 1 },
    .{ 0.86, 0.87, 0.84, 1 },
    .{ 0.45, 0.78, 0.92, 1 },
    .{ 0.62, 0.64, 0.68, 1 },
};

/// The colours on a light background (`EditorOf(c).light_palette`), indexed by `Class`.
pub const palette_light: [10][4]f32 = .{
    .{ 0.45, 0.50, 0.55, 1 },
    .{ 0.20, 0.50, 0.22, 1 },
    .{ 0.10, 0.50, 0.42, 1 },
    .{ 0.72, 0.38, 0.08, 1 },
    .{ 0.50, 0.25, 0.70, 1 },
    .{ 0.60, 0.45, 0.00, 1 },
    .{ 0.70, 0.20, 0.35, 1 },
    .{ 0.15, 0.16, 0.18, 1 },
    .{ 0.10, 0.45, 0.65, 1 },
    .{ 0.40, 0.42, 0.46, 1 },
};

pub const keywords = [_][]const u8{
    "auto",           "break",         "case",         "const",    "continue",  "default",
    "do",             "else",          "enum",         "extern",   "for",       "goto",
    "if",             "inline",        "register",     "restrict", "return",    "sizeof",
    "static",         "struct",        "switch",       "typedef",  "union",     "volatile",
    "while",          "_Alignas",      "_Alignof",     "_Atomic",  "_Generic",  "_Noreturn",
    "_Static_assert", "_Thread_local", "alignas",      "alignof",  "constexpr", "false",
    "nullptr",        "static_assert", "thread_local", "true",     "typeof",    "typeof_unqual",
};

pub const types = [_][]const u8{
    "void",    "char",      "short",    "int",       "long",     "float",      "double",
    "signed",  "unsigned",  "bool",     "_Bool",     "_Complex", "_Imaginary", "int8_t",
    "int16_t", "int32_t",   "int64_t",  "uint8_t",   "uint16_t", "uint32_t",   "uint64_t",
    "size_t",  "ptrdiff_t", "intptr_t", "uintptr_t",
};

/// Operators of two or three bytes, longest first so `<<=` wins over `<<`.
const long_operators = [_][]const u8{
    "<<=", ">>=", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||",
    "+=",  "-=",  "*=", "/=", "%=", "&=", "|=", "^=",
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
    at.* = index;
    if (index == line.len) return null;
    assert(state.* == .normal);
    const start = index;
    const class: Class, const end: u32 = scan(line, start, state);
    assert(end > start);
    assert(end <= line.len);
    at.* = end;
    return .{ .start = start, .end = end, .class = class };
}

/// The class and end of the token starting at the non-space byte `start`.
fn scan(line: []const u8, start: u32, state: *State) struct { Class, u32 } {
    assert(start < line.len);
    assert(line[start] > ' ');
    const lead = line[start];
    const length: u32 = @intCast(line.len);
    if (lead == '/' and start + 1 < length) {
        if (line[start + 1] == '/') return .{ .comment, length };
        if (line[start + 1] == '*') {
            state.* = .block_comment;
            return .{ .comment, comment_end(line, start + 2, state) };
        }
    }
    if (lead == '#' and first_on_line(line, start)) return .{ .preprocessor, directive_end(line, start) };
    if (lead == '"') return .{ .string, quoted_end(line, start, '"') };
    if (lead == '\'') return .{ .char, quoted_end(line, start, '\'') };
    if (lead == '<' and include_path_at(line) == start) return .{ .string, path_end(line, start) };
    if (is_digit(lead)) return .{ .number, number_end(line, start) };
    if (lead == '.' and start + 1 < length and is_digit(line[start + 1])) {
        return .{ .number, number_end(line, start) };
    }
    if (is_word_start(lead)) {
        const word_end = identifier_end(line, start);
        const word = line[start..word_end];
        if (word_end < length and is_prefix(word)) {
            if (line[word_end] == '"') return .{ .string, quoted_end(line, word_end, '"') };
            if (line[word_end] == '\'') return .{ .char, quoted_end(line, word_end, '\'') };
        }
        if (is_one_of(&keywords, word)) return .{ .keyword, word_end };
        if (is_one_of(&types, word)) return .{ .type_name, word_end };
        return .{ .identifier, word_end };
    }
    for (long_operators) |operator| {
        if (std.mem.startsWith(u8, line[start..], operator)) {
            return .{ .operator, start + @as(u32, @intCast(operator.len)) };
        }
    }
    if (std.mem.indexOfScalar(u8, "+-*/%<>=!&|^~?", lead) != null) return .{ .operator, start + 1 };
    return .{ .punctuation, start + 1 };
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

/// From the opening `quote` at `start`: past the next unescaped `quote`, or the line's end.
fn quoted_end(line: []const u8, start: u32, quote: u8) u32 {
    assert(line[start] == quote);
    const length: u32 = @intCast(line.len);
    var index = start + 1;
    while (index < length) {
        if (line[index] == '\\') {
            index = @min(index + 2, length);
            continue;
        }
        if (line[index] == quote) return index + 1;
        index += 1;
    }
    assert(index == length);
    return index;
}

/// Whether every byte before `index` is a space.
fn first_on_line(line: []const u8, index: u32) bool {
    assert(index < line.len);
    for (line[0..index]) |byte| {
        if (byte > ' ') return false;
    }
    return true;
}

/// Past the `#`, any spaces, and the directive's name.
fn directive_end(line: []const u8, start: u32) u32 {
    assert(line[start] == '#');
    var index = start + 1;
    while (index < line.len and line[index] == ' ') index += 1;
    if (index < line.len and is_word_start(line[index])) return identifier_end(line, index);
    // A lone `#` (the null directive), or spaces after it with no name: the `#` alone.
    return start + 1;
}

/// The index of the `<` that opens an include path on this line, or null.
fn include_path_at(line: []const u8) ?u32 {
    var index: u32 = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    if (index == line.len or line[index] != '#') return null;
    const name_end = directive_end(line, index);
    var name_start = index + 1;
    while (name_start < name_end and line[name_start] == ' ') name_start += 1;
    if (!std.mem.eql(u8, line[name_start..name_end], "include")) return null;
    var path = name_end;
    while (path < line.len and line[path] == ' ') path += 1;
    if (path == line.len or line[path] != '<') return null;
    return path;
}

/// Past the `>` closing an include path, or the end of the line.
fn path_end(line: []const u8, start: u32) u32 {
    assert(line[start] == '<');
    if (std.mem.indexOfScalarPos(u8, line, start + 1, '>')) |close| return @intCast(close + 1);
    return @intCast(line.len);
}

/// The pp-number rule (section 2).
fn number_end(line: []const u8, start: u32) u32 {
    assert(is_digit(line[start]) or line[start] == '.');
    const length: u32 = @intCast(line.len);
    var index = start + 1;
    while (index < length) {
        const byte = line[index];
        if (is_word_byte(byte) or byte == '.') {
            index += 1;
            continue;
        }
        const signed = byte == '+' or byte == '-';
        if (signed and std.mem.indexOfScalar(u8, "eEpP", line[index - 1]) != null) {
            index += 1;
            continue;
        }
        if (byte == '\'' and index + 1 < length and is_word_byte(line[index + 1])) {
            index += 2;
            continue;
        }
        break;
    }
    assert(index > start);
    return index;
}

fn identifier_end(line: []const u8, start: u32) u32 {
    var index = start + 1;
    while (index < line.len and is_word_byte(line[index])) index += 1;
    return index;
}

fn is_prefix(word: []const u8) bool {
    return is_one_of(&.{ "L", "u", "U", "u8" }, word);
}

fn is_one_of(words: []const []const u8, word: []const u8) bool {
    assert(word.len >= 1);
    for (words) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
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

comptime {
    assert(patchwork.editor.language.check(@This()) == null);
    assert(palette.len == @typeInfo(Class).@"enum".field_names.len);
}

const testing = std.testing;
const language = patchwork.editor.language;

/// One expected token: its bytes and class.
const Want = struct { []const u8, Class };

/// Tokenizes `line` from `start` and checks each token's bytes and class, then returns the
/// end state; every line also passes `language.verify_line`.
fn expect_tokens(line: []const u8, start: State, expected: []const Want) !State {
    var state = start;
    var at: u32 = 0;
    for (expected) |want| {
        const token = next(line, &at, &state) orelse return error.TestExpectedToken;
        try testing.expectEqualStrings(want[0], line[token.start..token.end]);
        try testing.expectEqual(want[1], token.class);
    }
    try testing.expectEqual(@as(?Token, null), next(line, &at, &state));
    try testing.expectEqual(state, language.verify_line(@This(), line, start));
    return state;
}

// Locks a function line: storage keywords, a stdint type, a pointer star as an operator,
// a suffixed hex number, and the braces and semicolon as punctuation.
test "a function line splits into its classes" {
    _ = try expect_tokens("static inline uint32_t mix(const char *s, size_t n) { return 0x1Fu; }", .normal, &.{
        .{ "static", .keyword }, .{ "inline", .keyword },   .{ "uint32_t", .type_name },
        .{ "mix", .identifier }, .{ "(", .punctuation },    .{ "const", .keyword },
        .{ "char", .type_name }, .{ "*", .operator },       .{ "s", .identifier },
        .{ ",", .punctuation },  .{ "size_t", .type_name }, .{ "n", .identifier },
        .{ ")", .punctuation },  .{ "{", .punctuation },    .{ "return", .keyword },
        .{ "0x1Fu", .number },   .{ ";", .punctuation },    .{ "}", .punctuation },
    });
    _ = try expect_tokens("p->x <<= 2 && q != r++;", .normal, &.{
        .{ "p", .identifier }, .{ "->", .operator }, .{ "x", .identifier },  .{ "<<=", .operator },
        .{ "2", .number },     .{ "&&", .operator }, .{ "q", .identifier },  .{ "!=", .operator },
        .{ "r", .identifier }, .{ "++", .operator }, .{ ";", .punctuation },
    });
}

// Locks the preprocessor: the directive with its spaces is one token, an include path in
// angle brackets is a string, a quoted one too, and a `#` that is not first is punctuation.
test "preprocessor lines" {
    _ = try expect_tokens("#include <stdio.h>", .normal, &.{
        .{ "#include", .preprocessor }, .{ "<stdio.h>", .string },
    });
    _ = try expect_tokens("  # include \"wav.h\"", .normal, &.{
        .{ "# include", .preprocessor }, .{ "\"wav.h\"", .string },
    });
    _ = try expect_tokens("#  define MAX(a, b) ((a) > (b) ? (a) : (b))", .normal, &.{
        .{ "#  define", .preprocessor }, .{ "MAX", .identifier }, .{ "(", .punctuation },
        .{ "a", .identifier },           .{ ",", .punctuation },  .{ "b", .identifier },
        .{ ")", .punctuation },          .{ "(", .punctuation },  .{ "(", .punctuation },
        .{ "a", .identifier },           .{ ")", .punctuation },  .{ ">", .operator },
        .{ "(", .punctuation },          .{ "b", .identifier },   .{ ")", .punctuation },
        .{ "?", .operator },             .{ "(", .punctuation },  .{ "a", .identifier },
        .{ ")", .punctuation },          .{ ":", .punctuation },  .{ "(", .punctuation },
        .{ "b", .identifier },           .{ ")", .punctuation },  .{ ")", .punctuation },
    });
    _ = try expect_tokens("x # y < z", .normal, &.{
        .{ "x", .identifier }, .{ "#", .punctuation }, .{ "y", .identifier },
        .{ "<", .operator },   .{ "z", .identifier },
    });
    _ = try expect_tokens("#", .normal, &.{.{ "#", .preprocessor }});
}

// Locks the pp-number rule: exponents with signs, a leading dot, a hex float, a C23
// separator, and a binary literal are one token each, while `1+2` is three and `x.y` keeps
// the dot as punctuation.
test "numbers follow the pp-number rule" {
    _ = try expect_tokens("1.5e-3f .5 0x1p-4 1'000 0b1010 1+2 x.y", .normal, &.{
        .{ "1.5e-3f", .number }, .{ ".5", .number },     .{ "0x1p-4", .number },
        .{ "1'000", .number },   .{ "0b1010", .number }, .{ "1", .number },
        .{ "+", .operator },     .{ "2", .number },      .{ "x", .identifier },
        .{ ".", .punctuation },  .{ "y", .identifier },
    });
}

// Locks strings and chars: prefixes belong to the literal, an escaped quote does not close
// it, an escaped quote char is one char, and an unterminated string runs to the line's end.
test "strings and chars with prefixes and escapes" {
    _ = try expect_tokens("L\"wide\" u8\"utf\" 'a' '\\'' U'x' \"esc \\\" q\" u8x \"open", .normal, &.{
        .{ "L\"wide\"", .string }, .{ "u8\"utf\"", .string }, .{ "'a'", .char },
        .{ "'\\''", .char },       .{ "U'x'", .char },        .{ "\"esc \\\" q\"", .string },
        .{ "u8x", .identifier },   .{ "\"open", .string },
    });
}

// Locks block comments across lines: an opening line ends in block_comment, a middle line
// is one comment token, the closing line returns to normal after `*/`, and a `/*` inside a
// string or a line comment opens nothing.
test "block comments carry the state across lines" {
    const opened = try expect_tokens("int a; /* one", .normal, &.{
        .{ "int", .type_name },  .{ "a", .identifier }, .{ ";", .punctuation },
        .{ "/* one", .comment },
    });
    try testing.expectEqual(State.block_comment, opened);
    const middle = try expect_tokens("#still inside", .block_comment, &.{
        .{ "#still inside", .comment },
    });
    try testing.expectEqual(State.block_comment, middle);
    const closed = try expect_tokens("  two */ b", .block_comment, &.{
        .{ "  two */", .comment }, .{ "b", .identifier },
    });
    try testing.expectEqual(State.normal, closed);
    try testing.expectEqual(State.normal, try expect_tokens("\"/*\" // /*", .normal, &.{
        .{ "\"/*\"", .string }, .{ "// /*", .comment },
    }));
}

// Locks the contract on generated lines: 2,000 lines of random C fragments, joined by one
// or two spaces, pass `language.verify_line` from both states, and the end states chain.
test "random C lines meet the language contract" {
    const fragments = [_][]const u8{
        "int", "x", "=",   "0x1F",  ";",    "/*",  "*/",  "//",   "\"s\\\"",
        "'c'", "#", "#if", "<a.h>", "1e+5", "->",  "<<=", "u8\"", "\u{e4}",
        "{",   "}", "...", "'",     "\"",   "1'0", ".5",  "##",   "L'",
    };
    var prng = std.Random.DefaultPrng.init(0x5eed_0044);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    var chained: State = .normal;
    var round: u32 = 0;
    while (round < 2000) : (round += 1) {
        var length: usize = 0;
        const pieces = random.intRangeAtMost(u32, 0, 12);
        for (0..pieces) |_| {
            const piece = fragments[random.uintLessThan(usize, fragments.len)];
            const gap: usize = random.intRangeAtMost(usize, 0, 2);
            if (length + gap + piece.len > buffer.len) break;
            @memset(buffer[length..][0..gap], ' ');
            length += gap;
            @memcpy(buffer[length..][0..piece.len], piece);
            length += piece.len;
        }
        const line = buffer[0..length];
        _ = language.verify_line(@This(), line, .normal);
        _ = language.verify_line(@This(), line, .block_comment);
        chained = language.verify_line(@This(), line, chained);
    }
}

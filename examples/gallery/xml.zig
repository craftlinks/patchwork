//! An XML tokenizer for the code editor: a recipe, not library code.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Recipe
//! This file is a language for `patchwork.editor.EditorOf` (the contract in
//! `src/editor/language.zig`). An app copies it and changes it freely: it carries no API
//! promise, and it moves into the library only when three apps need the same one. The
//! gallery's code page draws `layout.xml` with it; the UI designer (step 47) copies it.
//!
//! ## 2. States
//! Tags, quoted values, comments, CDATA, processing instructions, and a DOCTYPE may all
//! cross lines, so the state says which one is open:
//! ```text
//! normal         text content
//! tag            inside a start or end tag, after its name
//! value_double   inside an attribute value in "..."      (returns to tag)
//! value_single   inside an attribute value in '...'      (returns to tag)
//! comment        inside <!-- ... -->                     (returns to normal)
//! cdata          inside <![CDATA[ ... ]]>
//! instruction    inside <? ... ?>
//! doctype        inside <!DOCTYPE ... >                  (its first > ends it: an internal
//!                                                         subset [...] is not parsed)
//! ```
//!
//! ## 3. Token Rules
//! Bytes up to and including space separate tokens. A token of an open construct starts
//! where the last one ended (its leading spaces included) and runs to the closer, which
//! returns to the state above, or to the end of the line, which keeps the state.
//! ```text
//! normal   <!-- comment, <![CDATA[ cdata, <? and <! meta (opening the state);
//!          < or </ before a name: delimiter, and the name after it is an element (the
//!          state becomes tag); any other < is a delimiter; &name; and &#...; are an
//!          entity; any other run up to a space, < or & is text
//! tag      a name is an attribute, = is equals, "..." or '...' a value, > and /> are
//!          delimiters that return to normal, any other byte a delimiter (tolerant)
//! ```
//! A name is `[A-Za-z_:]` then `[A-Za-z0-9_:.-]*`, or any run starting with a non-ASCII
//! byte. An element's name is found by looking back at the `<` before it, which reads only
//! the line, so tokens stay a function of the line and its start state. `--` inside a
//! comment is not checked.
//!
//! ## 4. TigerStyle Invariants
//! - `next` consumes at least one byte per token; nothing allocates; every scan is bounded
//!   by the line.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");

pub const State = enum(u8) {
    normal,
    tag,
    value_double,
    value_single,
    comment,
    cdata,
    instruction,
    doctype,
};

pub const Class = enum(u8) {
    text,
    entity,
    delimiter,
    element,
    attribute,
    equals,
    value,
    comment,
    cdata,
    meta,
};

pub const Token = patchwork.editor.Token(Class);

/// The default colours, straight RGBA, indexed by `Class`.
pub const palette: [10][4]f32 = .{
    .{ 0.86, 0.87, 0.84, 1 },
    .{ 0.95, 0.82, 0.45, 1 },
    .{ 0.62, 0.64, 0.68, 1 },
    .{ 0.58, 0.64, 0.98, 1 },
    .{ 0.95, 0.68, 0.40, 1 },
    .{ 0.62, 0.64, 0.68, 1 },
    .{ 0.62, 0.82, 0.52, 1 },
    .{ 0.47, 0.53, 0.58, 1 },
    .{ 0.45, 0.78, 0.80, 1 },
    .{ 0.68, 0.55, 0.80, 1 },
};

/// The colours on a light background (`EditorOf(xml).light_palette`), indexed by `Class`.
pub const palette_light: [10][4]f32 = .{
    .{ 0.15, 0.16, 0.18, 1 },
    .{ 0.60, 0.45, 0.00, 1 },
    .{ 0.45, 0.47, 0.52, 1 },
    .{ 0.20, 0.30, 0.75, 1 },
    .{ 0.72, 0.38, 0.08, 1 },
    .{ 0.45, 0.47, 0.52, 1 },
    .{ 0.20, 0.50, 0.22, 1 },
    .{ 0.45, 0.50, 0.55, 1 },
    .{ 0.10, 0.48, 0.52, 1 },
    .{ 0.48, 0.32, 0.60, 1 },
};

/// An open construct: what closes it, its class, and the state it returns to.
const Open = struct {
    closer: []const u8,
    class: Class,
    after: State,
};

fn open_of(state: State) ?Open {
    return switch (state) {
        .normal, .tag => null,
        .value_double => .{ .closer = "\"", .class = .value, .after = .tag },
        .value_single => .{ .closer = "'", .class = .value, .after = .tag },
        .comment => .{ .closer = "-->", .class = .comment, .after = .normal },
        .cdata => .{ .closer = "]]>", .class = .cdata, .after = .normal },
        .instruction => .{ .closer = "?>", .class = .meta, .after = .normal },
        .doctype => .{ .closer = ">", .class = .meta, .after = .normal },
    };
}

/// The next token of `line` at or after `at.*`, which advances past it; `state` carries
/// what is open across lines. Null at the end of the line. See the module guide, section 3.
pub fn next(line: []const u8, at: *u32, state: *State) ?Token {
    assert(at.* <= line.len);
    if (open_of(state.*)) |open| {
        const start = at.*;
        const end = open_end(line, start, state);
        at.* = end;
        if (end > start) return .{ .start = start, .end = end, .class = open.class };
    }
    var index = at.*;
    while (index < line.len and line[index] <= ' ') index += 1;
    at.* = index;
    if (index == line.len) return null;
    assert(state.* == .normal or state.* == .tag);
    const start = index;
    const class: Class, const end: u32 = if (state.* == .tag)
        scan_tag(line, start, state)
    else
        scan_text(line, start, state);
    assert(end > start);
    assert(end <= line.len);
    at.* = end;
    return .{ .start = start, .end = end, .class = class };
}

/// Inside the open construct of `state` from `from`: past its closer (the state returns to
/// the one above), or the end of the line (the state stays).
fn open_end(line: []const u8, from: u32, state: *State) u32 {
    assert(from <= line.len);
    const open = open_of(state.*).?;
    if (std.mem.indexOfPos(u8, line, from, open.closer)) |close| {
        state.* = open.after;
        return @intCast(close + open.closer.len);
    }
    return @intCast(line.len);
}

/// A token in text content, starting at the non-space byte `start`.
fn scan_text(line: []const u8, start: u32, state: *State) struct { Class, u32 } {
    assert(state.* == .normal);
    assert(line[start] > ' ');
    const rest = line[start..];
    const length: u32 = @intCast(line.len);
    const openers = [_]struct { []const u8, State, Class }{
        .{ "<!--", .comment, .comment },
        .{ "<![CDATA[", .cdata, .cdata },
        .{ "<?", .instruction, .meta },
        .{ "<!", .doctype, .meta },
    };
    for (openers) |opener| {
        if (!std.mem.startsWith(u8, rest, opener[0])) continue;
        state.* = opener[1];
        return .{ opener[2], open_end(line, start + @as(u32, @intCast(opener[0].len)), state) };
    }
    if (rest[0] == '<') {
        const slash = start + 1 < length and line[start + 1] == '/';
        const name = start + @as(u32, if (slash) 2 else 1);
        if (name < length and is_name_start(line[name])) return .{ .delimiter, name };
        return .{ .delimiter, start + 1 };
    }
    if (after_open_angle(line, start) and is_name_start(rest[0])) {
        state.* = .tag;
        return .{ .element, name_end(line, start) };
    }
    if (rest[0] == '&') {
        if (entity_end(line, start)) |end| return .{ .entity, end };
    }
    var index = start + 1;
    while (index < length and line[index] > ' ' and line[index] != '<' and
        line[index] != '&') index += 1;
    return .{ .text, index };
}

/// A token inside a tag, starting at the non-space byte `start`.
fn scan_tag(line: []const u8, start: u32, state: *State) struct { Class, u32 } {
    assert(state.* == .tag);
    assert(line[start] > ' ');
    const lead = line[start];
    if (is_name_start(lead)) return .{ .attribute, name_end(line, start) };
    if (lead == '=') return .{ .equals, start + 1 };
    if (lead == '"' or lead == '\'') {
        state.* = if (lead == '"') .value_double else .value_single;
        return .{ .value, open_end(line, start + 1, state) };
    }
    if (lead == '>') {
        state.* = .normal;
        return .{ .delimiter, start + 1 };
    }
    if (lead == '/' and start + 1 < line.len and line[start + 1] == '>') {
        state.* = .normal;
        return .{ .delimiter, start + 2 };
    }
    return .{ .delimiter, start + 1 };
}

/// Whether `index` directly follows a `<` or `</`.
fn after_open_angle(line: []const u8, index: u32) bool {
    if (index >= 1 and line[index - 1] == '<') return true;
    return index >= 2 and line[index - 1] == '/' and line[index - 2] == '<';
}

/// Past `&name;` or `&#...;` starting at `start`, or null when no `;` ends the reference
/// before a byte that cannot be in one.
fn entity_end(line: []const u8, start: u32) ?u32 {
    assert(line[start] == '&');
    var index = start + 1;
    if (index < line.len and line[index] == '#') index += 1;
    const body = index;
    while (index < line.len and is_name_byte(line[index])) index += 1;
    if (index == body or index == line.len or line[index] != ';') return null;
    return index + 1;
}

fn name_end(line: []const u8, start: u32) u32 {
    assert(is_name_start(line[start]));
    var index = start + 1;
    while (index < line.len and is_name_byte(line[index])) index += 1;
    return index;
}

fn is_name_start(byte: u8) bool {
    if (byte >= 0x80) return true;
    if (byte == '_' or byte == ':') return true;
    return std.ascii.isAlphabetic(byte);
}

fn is_name_byte(byte: u8) bool {
    if (is_name_start(byte)) return true;
    return std.ascii.isDigit(byte) or byte == '.' or byte == '-';
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

// Locks a start tag with a double- and a single-quoted attribute and a self-closing end,
// then text with a named and a numeric entity and a bare `&`, which is text.
test "a tag, its attributes, and text with entities" {
    const state = try expect_tokens("<knob id=\"gain\" min='-60'/> Tom &amp; Jerry &#x2192; &x", .normal, &.{
        .{ "<", .delimiter },     .{ "knob", .element },   .{ "id", .attribute },
        .{ "=", .equals },        .{ "\"gain\"", .value }, .{ "min", .attribute },
        .{ "=", .equals },        .{ "'-60'", .value },    .{ "/>", .delimiter },
        .{ "Tom", .text },        .{ "&amp;", .entity },   .{ "Jerry", .text },
        .{ "&#x2192;", .entity }, .{ "&x", .text },
    });
    try testing.expectEqual(State.normal, state);
    _ = try expect_tokens("</row><a>b</a>", .normal, &.{
        .{ "</", .delimiter }, .{ "row", .element },  .{ ">", .delimiter },
        .{ "<", .delimiter },  .{ "a", .element },    .{ ">", .delimiter },
        .{ "b", .text },       .{ "</", .delimiter }, .{ "a", .element },
        .{ ">", .delimiter },
    });
}

// Locks tags and values across lines: a tag left open carries `tag` into the next line,
// a value left open carries `value_double`, and its closing quote returns to `tag`.
test "tags and values continue on later lines" {
    const opened = try expect_tokens("<knob id=\"q\"", .normal, &.{
        .{ "<", .delimiter }, .{ "knob", .element }, .{ "id", .attribute },
        .{ "=", .equals },    .{ "\"q\"", .value },
    });
    try testing.expectEqual(State.tag, opened);
    const value = try expect_tokens("  label=\"Q", .tag, &.{
        .{ "label", .attribute }, .{ "=", .equals }, .{ "\"Q", .value },
    });
    try testing.expectEqual(State.value_double, value);
    try testing.expectEqual(State.value_double, try expect_tokens("  of the", .value_double, &.{
        .{ "  of the", .value },
    }));
    const closed = try expect_tokens("filter' x\" />", .value_double, &.{
        .{ "filter' x\"", .value }, .{ "/>", .delimiter },
    });
    try testing.expectEqual(State.normal, closed);
    try testing.expectEqual(State.value_single, try expect_tokens("<a b='c", .normal, &.{
        .{ "<", .delimiter }, .{ "a", .element }, .{ "b", .attribute }, .{ "=", .equals },
        .{ "'c", .value },
    }));
}

// Locks the four open constructs: a comment, CDATA, a processing instruction, and a DOCTYPE
// each open on one line, fill the next as one token, and close on the third, returning to
// text, where a tag opens.
test "comments, CDATA, instructions, and a DOCTYPE cross lines" {
    const cases = [_]struct { [3][]const u8, State, Class }{
        .{ .{ "<!-- a", "middle -- line", "end --> <a" }, .comment, .comment },
        .{ .{ "<![CDATA[ if (a < b", "&& c)", "]]> <a" }, .cdata, .cdata },
        .{ .{ "<?xml version=\"1.0\"", "encoding=\"UTF-8\"", "?> <a" }, .instruction, .meta },
        .{ .{ "<!DOCTYPE window", "SYSTEM \"w.dtd\"", "> <a" }, .doctype, .meta },
    };
    for (cases) |case| {
        const lines = case[0];
        try testing.expectEqual(case[1], try expect_tokens(lines[0], .normal, &.{
            .{ lines[0], case[2] },
        }));
        try testing.expectEqual(case[1], try expect_tokens(lines[1], case[1], &.{
            .{ lines[1], case[2] },
        }));
        const closer = lines[2][0 .. lines[2].len - " <a".len];
        try testing.expectEqual(State.tag, try expect_tokens(lines[2], case[1], &.{
            .{ closer, case[2] }, .{ "<", .delimiter }, .{ "a", .element },
        }));
    }
}

// Locks broken input: a `<` before a space, comparison text, an unclosed tag at the end
// of the text, and a run of `<`, each still tokenized within the contract.
test "broken input stays well formed" {
    _ = try expect_tokens("< a", .normal, &.{ .{ "<", .delimiter }, .{ "a", .text } });
    _ = try expect_tokens("a < b & c", .normal, &.{
        .{ "a", .text }, .{ "<", .delimiter }, .{ "b", .text }, .{ "&", .text },
        .{ "c", .text },
    });
    try testing.expectEqual(State.tag, try expect_tokens("x<a", .normal, &.{
        .{ "x", .text }, .{ "<", .delimiter }, .{ "a", .element },
    }));
    _ = try expect_tokens("<<<", .normal, &.{
        .{ "<", .delimiter }, .{ "<", .delimiter }, .{ "<", .delimiter },
    });
    _ = try expect_tokens("<a < = >", .normal, &.{
        .{ "<", .delimiter }, .{ "a", .element },   .{ "<", .delimiter },
        .{ "=", .equals },    .{ ">", .delimiter },
    });
}

// Locks the contract on generated lines: 2,000 lines of random XML fragments, joined by
// zero to two spaces, pass `language.verify_line` from every state, and the end states
// chain.
test "random XML lines meet the language contract" {
    const fragments = [_][]const u8{
        "<a",   "</a>",   ">",         "/>",   "=",   "\"v\"", "'v'",       "\"",    "'",
        "<!--", "-->",    "<![CDATA[", "]]>",  "<?",  "?>",    "<!DOCTYPE", "&amp;", "&",
        "text", "\u{e4}", "<",         "&#1;", "x:y", "-",
    };
    var prng = std.Random.DefaultPrng.init(0x5eed_0045);
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
        for (std.enums.values(State)) |start| _ = language.verify_line(@This(), line, start);
        chained = language.verify_line(@This(), line, chained);
    }
}

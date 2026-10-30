//! The language contract: what the editor needs from a language to colour its lines, the
//! check that names a broken one, and what the library derives from it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Contract
//! A language is a namespace (a file or a struct) passed to `EditorOf` and `BufferOf` at
//! compile time. It declares four things:
//! ```text
//! State    enum(u8) with a `normal` tag   carried from the end of one line to the next;
//!                                         line 0 starts in `normal`
//! Class    enum(u8), 1 to 16 tags         token classes, numbered 0, 1, ... (the default)
//!          numbered from 0
//! palette  [N][4]f32                      straight RGBA per class: the default colours
//! next     fn (line: []const u8, at: *u32, state: *State) ?Token(Class)
//! ```
//! A language may also declare `palette_light: [N][4]f32`, its class colours on a light
//! background (`EditorOf(L).light_palette`); without it the light palette reuses `palette`.
//! It may declare `faces: [N]text.Face`, one face per class: `proportional(L)` is then true and
//! `EditorOf(L)` sets each class in its own face instead of on the monospace grid, chosen at
//! compile time, so a mono editor keeps its code and its size (`editor.zig`, section 2).
//! The editor caches one `State` per line (`[line_cap]State`, one byte each) and tokenizes
//! only the visible lines, each from its cached start state (`buffer.zig`, section 2). The
//! patch language (`tokenizer.zig`) is the reference implementation and the default.
//!
//! ## 2. What `next` Must Do
//! - Tokens come in order, do not overlap, and are not empty: `at.* <= start < end <=
//!   line.len`, and `at.*` becomes `end`. A line of `n` bytes yields at most `n` tokens.
//! - Every byte outside a token is a space (0x20): the editor counts a gap as one column per
//!   byte without decoding it. The text holds no tab, CR, or other control byte
//!   (`edit.sanitize_text`), so skipping bytes `<= ' '` meets this. A token may hold spaces.
//!   In a language with `faces` a gap is spaces of `faces[0]`: columns still count codepoints,
//!   and only their x changes.
//! - Null only when the line is used up, with `at.* == line.len`; further calls keep
//!   returning null and leave `state` alone.
//! - Tokens are a pure function of the line's bytes and its start state, so start states
//!   may be cached.
//! `verify_line` asserts all of it for one line (`Buffer.verify` runs it on every line).
//!
//! ## 3. The Check
//! `check(L)` returns the first problem, in the order of section 1, as a message that names
//! `L` and the declaration (`"c.Bare: missing ``pub fn next(...)``"`); `EditorOf` and
//! `BufferOf` turn it into a compile error, as `XOf(Skin)` does for skins.
//! `zig build test-contract` locks one case.
//!
//! ## 4. TigerStyle Invariants
//! - `end_state` and `verify_line` are O(line length); `next` makes progress on every
//!   token, so their loops are bounded by the line's bytes. Nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");

/// Classes a language has at most, so a palette is at most 16 colours.
pub const class_max: u32 = 16;

/// Bytes `start .. end` of a line, of `class`. Memoized per `Class`, so a language's
/// `Token` and the editor's are one type.
pub fn Token(comptime Class: type) type {
    return struct {
        start: u32,
        end: u32,
        class: Class,
    };
}

/// The number of `L.Class` tags.
pub fn class_count(comptime L: type) u32 {
    const count = @typeInfo(L.Class).@"enum".field_names.len;
    comptime assert(count >= 1);
    comptime assert(count <= class_max);
    return count;
}

/// True when `L` sets each class in its own face (section 1).
pub fn proportional(comptime L: type) bool {
    return @hasDecl(L, "faces");
}

/// The first reason `L` is not a language, naming `L` and the declaration, or null.
pub fn check(comptime L: type) ?[]const u8 {
    const prefix = @typeName(L) ++ ": ";
    switch (@typeInfo(L)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return prefix ++ "a language must be a struct type",
    }
    if (!@hasDecl(L, "State")) {
        return prefix ++ "missing `pub const State = enum(u8) { normal, ... }`";
    }
    if (!state_ok(L.State)) {
        return prefix ++ "`State` must be an enum(u8) with a `normal` tag";
    }
    if (!@hasDecl(L, "Class")) return prefix ++ "missing `pub const Class = enum(u8) { ... }`";
    if (!class_ok(L.Class)) {
        return prefix ++ "`Class` must be an enum(u8) of 1 to 16 tags numbered from 0";
    }
    const count = std.fmt.comptimePrint("{d}", .{class_count(L)});
    if (!@hasDecl(L, "palette")) return prefix ++ "missing `pub const palette: [" ++ count ++
        "][4]f32`";
    if (@TypeOf(L.palette) != [class_count(L)][4]f32) {
        return prefix ++ "`palette` must be [" ++ count ++ "][4]f32, one colour per Class";
    }
    if (@hasDecl(L, "palette_light") and @TypeOf(L.palette_light) != [class_count(L)][4]f32) {
        return prefix ++ "`palette_light` must be [" ++ count ++ "][4]f32, one colour per Class";
    }
    if (@hasDecl(L, "faces") and @TypeOf(L.faces) != [class_count(L)]text.Face) {
        return prefix ++ "`faces` must be [" ++ count ++ "]text.Face, one face per Class";
    }
    const shown = "pub fn next(line: []const u8, at: *u32, state: *State) " ++
        "?editor.Token(Class)";
    if (!@hasDecl(L, "next")) return prefix ++ "missing `" ++ shown ++ "`";
    const Wanted = fn ([]const u8, *u32, *L.State) ?Token(L.Class);
    if (@TypeOf(L.next) != Wanted) return prefix ++ "`next` must be `" ++ shown ++ "`";
    return null;
}

fn state_ok(comptime State: type) bool {
    if (@typeInfo(State) != .@"enum") return false;
    const info = @typeInfo(State).@"enum";
    if (info.tag_type != u8) return false;
    return @hasField(State, "normal");
}

fn class_ok(comptime Class: type) bool {
    if (@typeInfo(Class) != .@"enum") return false;
    const info = @typeInfo(Class).@"enum";
    if (info.tag_type != u8) return false;
    if (info.mode != .exhaustive) return false;
    if (info.field_names.len < 1) return false;
    if (info.field_names.len > class_max) return false;
    for (info.field_values, 0..) |value, index| {
        if (value != index) return false;
    }
    return true;
}

/// The state at the end of `line` when it starts in `start`. O(line length).
pub fn end_state(comptime L: type, line: []const u8, start: L.State) L.State {
    var state = start;
    var at: u32 = 0;
    var tokens: u32 = 0;
    while (L.next(line, &at, &state)) |_| {
        tokens += 1;
        assert(tokens <= line.len);
    }
    assert(at == line.len);
    return state;
}

/// Walks `line` from `start`, asserting the rules of section 2 at every token, and returns
/// the end state. O(line length); for tests and `Buffer.verify`.
pub fn verify_line(comptime L: type, line: []const u8, start: L.State) L.State {
    var state = start;
    var at: u32 = 0;
    var position: u32 = 0;
    var tokens: u32 = 0;
    while (L.next(line, &at, &state)) |token| {
        assert(token.start >= position);
        assert(token.start < token.end);
        assert(token.end <= line.len);
        assert(at == token.end);
        for (line[position..token.start]) |byte| assert(byte == ' ');
        assert(@backingInt(token.class) < class_count(L));
        position = token.end;
        tokens += 1;
        assert(tokens <= line.len);
    }
    assert(at == line.len);
    for (line[position..]) |byte| assert(byte == ' ');
    const after = state;
    assert(L.next(line, &at, &state) == null);
    assert(state == after);
    return state;
}

const testing = std.testing;
const tokenizer = @import("tokenizer.zig");

/// A language with three states, to check the contract beyond two.
const Quotes = struct {
    pub const State = enum(u8) { normal, single, double };
    pub const Class = enum(u8) { word, quoted };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 0, 1, 0, 1 } };

    pub fn next(line: []const u8, at: *u32, state: *State) ?Token(Class) {
        assert(at.* <= line.len);
        var index = at.*;
        if (state.* == .normal) {
            while (index < line.len and line[index] == ' ') index += 1;
        }
        if (index == line.len) {
            at.* = index;
            return null;
        }
        const start = index;
        if (state.* == .normal and (line[index] == '\'' or line[index] == '"')) {
            state.* = if (line[index] == '\'') .single else .double;
            index += 1;
        }
        if (state.* != .normal) {
            const close: u8 = if (state.* == .single) '\'' else '"';
            while (index < line.len and line[index] != close) index += 1;
            if (index < line.len) {
                index += 1;
                state.* = .normal;
            }
            at.* = index;
            return .{ .start = start, .end = index, .class = .quoted };
        }
        while (index < line.len and line[index] != ' ' and line[index] != '\'' and
            line[index] != '"') index += 1;
        at.* = index;
        return .{ .start = start, .end = index, .class = .word };
    }
};

const NoState = struct {};
const WideState = struct {
    pub const State = enum(u16) { normal };
};
const NoNormal = struct {
    pub const State = enum(u8) { plain };
};
const NoClass = struct {
    pub const State = enum(u8) { normal };
};
const Gappy = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a = 1, b = 2 };
};
const Crowded = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) {
        c0,
        c1,
        c2,
        c3,
        c4,
        c5,
        c6,
        c7,
        c8,
        c9,
        c10,
        c11,
        c12,
        c13,
        c14,
        c15,
        c16,
    };
};
const NoPalette = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
};
const ShortPalette = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [1][4]f32 = .{.{ 1, 1, 1, 1 }};
};
const ShortLight = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
    pub const palette_light: [3][4]f32 = .{ .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 1 }, .{ 0, 0, 0, 1 } };
};
const ShortFaces = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
    pub const faces: [1]text.Face = .{.sans};
};
const NoNext = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
};
const OwnToken = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
    pub const Own = struct { start: u32, end: u32, class: Class };

    pub fn next(line: []const u8, at: *u32, state: *State) ?Own {
        _ = line;
        _ = at;
        _ = state;
        return null;
    }
};

// Locks the check: the patch language and a three-state language pass, and each broken
// language gets the message for its first problem, naming it.
test "check names the first problem of a language" {
    try testing.expectEqual(@as(?[]const u8, null), comptime check(tokenizer));
    try testing.expectEqual(@as(?[]const u8, null), comptime check(Quotes));
    const cases = .{
        .{ u32, "a language must be a struct type" },
        .{ NoState, "missing `pub const State = enum(u8) { normal, ... }`" },
        .{ WideState, "`State` must be an enum(u8) with a `normal` tag" },
        .{ NoNormal, "`State` must be an enum(u8) with a `normal` tag" },
        .{ NoClass, "missing `pub const Class = enum(u8) { ... }`" },
        .{ Gappy, "`Class` must be an enum(u8) of 1 to 16 tags numbered from 0" },
        .{ Crowded, "`Class` must be an enum(u8) of 1 to 16 tags numbered from 0" },
        .{ NoPalette, "missing `pub const palette: [2][4]f32`" },
        .{ ShortPalette, "`palette` must be [2][4]f32, one colour per Class" },
        .{ ShortLight, "`palette_light` must be [2][4]f32, one colour per Class" },
        .{ ShortFaces, "`faces` must be [2]text.Face, one face per Class" },
        .{ NoNext, "missing `pub fn next(line: []const u8, at: *u32, " ++
            "state: *State) ?editor.Token(Class)`" },
        .{ OwnToken, "`next` must be `pub fn next(line: []const u8, " ++
            "at: *u32, state: *State) ?editor.Token(Class)`" },
    };
    inline for (cases) |case| {
        const expected = @typeName(case[0]) ++ ": " ++ case[1];
        try testing.expectEqualStrings(expected, comptime check(case[0]).?);
    }
}

// Locks the comptime switch: a language with `faces` is proportional, one without is not.
test "proportional follows the faces declaration" {
    try testing.expect(comptime proportional(ShortFaces));
    try testing.expect(!comptime proportional(tokenizer));
}

// Locks the derived walks: a quote opened on one line carries `single` or `double` into the
// next, `end_state` and `verify_line` agree on every line, and the patch language's block
// comment lines agree too.
test "end_state and verify_line agree across states" {
    try testing.expectEqual(Quotes.State.single, end_state(Quotes, "ab 'cd", .normal));
    try testing.expectEqual(Quotes.State.single, verify_line(Quotes, "ab 'cd", .normal));
    try testing.expectEqual(Quotes.State.double, end_state(Quotes, "  still", .double));
    try testing.expectEqual(Quotes.State.normal, verify_line(Quotes, "x\" y 'z'", .double));
    try testing.expectEqual(Quotes.State.normal, verify_line(Quotes, "", .normal));
    const lines = [_][]const u8{ "a /* one", "still inside", "two */ b", "\"/*\" // /*", "/**/" };
    var state: tokenizer.State = .normal;
    for (lines) |line| {
        const walked = verify_line(tokenizer, line, state);
        try testing.expectEqual(end_state(tokenizer, line, state), walked);
        state = walked;
    }
    try testing.expectEqual(tokenizer.State.normal, state);
    try testing.expectEqual(@as(u32, 7), class_count(tokenizer));
}

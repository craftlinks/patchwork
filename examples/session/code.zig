//! The patch as typeset code: a template per line with value slots, a tokenizer, and a placer
//! that sets each token in its own serif face, colour, and width.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Not the Editor
//! The osc, pad, and reverb tank sections are an `editor.EditorOf(patch)` (`patch.zig`). The mix
//! section stays typeset here: its numbers are slots bound to widgets, and binding them both
//! ways is a job of its own. So these lines are read-only and placed token by token with
//! `text.measure` and `kit.label`, which is also what lets a token's alpha follow its gate.
//!
//! ## 2. Templates and Slots
//! A line is a template; `$` and a letter is slot `letter - 'a'`, whose text the app formats
//! from its widgets each frame (`Slots`). `expand` writes the line and the byte span of every
//! slot it used, so the app can find a bound value's x (`x_of`) to hang a curve or an area on.
//!
//! ## 3. Classes
//! ```text
//! keyword      if module return sum Note       regular, grey
//! call         an identifier before "("        italic
//! declared     a name in `Context.declared`    bold
//! channel      a name in `Context.channels`    regular, the channel's colour
//! number       digits with a unit; "-" leads one after an operator or "~"
//!              lo~VALUE~hi: the ends dim, the middle bright
//! string       "..."                           cream
//! punctuation  everything else                 grey
//! ```
//!
//! ## 4. TigerStyle Invariants
//! - Fixed buffers: a line is at most `line_cap` bytes and `token_cap` tokens.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const look = @import("look.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;

pub const line_cap: u32 = 192;
pub const token_cap: u32 = 96;
pub const slot_count: u32 = 26;
pub const slot_text_cap: u32 = 12;

/// The text of every slot, written by the app.
pub const Slots = struct {
    bytes: [slot_count][slot_text_cap]u8 = undefined,
    lens: [slot_count]u8 = @splat(0),

    pub fn set(self: *Slots, slot: u8, comptime format: []const u8, args: anytype) void {
        assert(slot < slot_count);
        const written = std.fmt.bufPrint(&self.bytes[slot], format, args) catch unreachable;
        self.lens[slot] = @intCast(written.len);
    }

    pub fn get(self: *const Slots, slot: u8) []const u8 {
        assert(slot < slot_count);
        return self.bytes[slot][0..self.lens[slot]];
    }
};

/// A slot's byte span in an expanded line; `len` 0 when the line has no such slot.
pub const Span = struct { start: u8 = 0, len: u8 = 0 };

/// Writes `template` with its slots filled into `out`; records each slot's span.
pub fn expand(out: *[line_cap]u8, template: []const u8, slots: *const Slots, spans: *[slot_count]Span) []const u8 {
    assert(template.len <= line_cap);
    spans.* = @splat(.{});
    var len: u32 = 0;
    var index: u32 = 0;
    while (index < template.len) : (index += 1) {
        const byte = template[index];
        if (byte == '$' and index + 1 < template.len) {
            const slot = template[index + 1] - 'a';
            const value = slots.get(slot);
            assert(len + value.len <= line_cap);
            @memcpy(out[len..][0..value.len], value);
            spans[slot] = .{ .start = @intCast(len), .len = @intCast(value.len) };
            len += @intCast(value.len);
            index += 1;
            continue;
        }
        assert(len < line_cap);
        out[len] = byte;
        len += 1;
    }
    return out[0..len];
}

pub const Class = enum { space, keyword, call, declared, plain, channel, number, range_end, string, punctuation };

pub const Token = struct { start: u8, end: u8, class: Class, channel: u8 = 0 };

/// What a section's highlighting knows: the names it declares and the mixer's channel names.
pub const Context = struct {
    declared: []const []const u8 = &.{},
    channels: []const []const u8 = &.{},
    /// A section turned off draws its code at this alpha.
    alpha: f32 = 1,
};

const keywords = [_][]const u8{ "if", "module", "return", "sum", "Note" };

pub fn is_ident(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

/// Splits `bytes` into tokens (section 3). Returns how many.
pub fn tokenize(bytes: []const u8, context: Context, out: *[token_cap]Token) u32 {
    assert(bytes.len <= line_cap);
    var count: u32 = 0;
    var at: u32 = 0;
    var previous: Class = .space;
    var previous_byte: u8 = ' ';
    while (at < bytes.len) {
        assert(count < token_cap);
        const value_before = previous == .plain or previous == .number or previous_byte == ')';
        const token = token_at(bytes, at, value_before, context);
        out[count] = token;
        count += 1;
        if (token.class != .space) previous = token.class;
        if (token.class != .space) previous_byte = bytes[token.end - 1];
        at = token.end;
    }
    return count;
}

/// The token at byte `at`. `value_before`: a value ends before it, so a "-" there subtracts.
pub fn token_at(bytes: []const u8, at: u32, value_before: bool, context: Context) Token {
    assert(at < bytes.len);
    const first = bytes[at];
    var stop = at + 1;
    var class: Class = .punctuation;
    var channel: u8 = 0;
    const leads_number = first == '-' and at + 1 < bytes.len and std.ascii.isDigit(bytes[at + 1]) and !value_before;
    if (first == ' ') {
        while (stop < bytes.len and bytes[stop] == ' ') stop += 1;
        class = .space;
    } else if (std.ascii.isDigit(first) or leads_number) {
        while (stop < bytes.len and (std.ascii.isAlphanumeric(bytes[stop]) or bytes[stop] == '.' or bytes[stop] == '%')) stop += 1;
        const before_tilde = stop < bytes.len and bytes[stop] == '~';
        const after_tilde = at > 0 and bytes[at - 1] == '~';
        class = if (after_tilde and !before_tilde) .range_end else if (before_tilde and !after_tilde) .range_end else .number;
        if (before_tilde and !after_tilde and !three_part(bytes, stop)) class = .number;
    } else if (is_ident(first)) {
        while (stop < bytes.len and is_ident(bytes[stop])) stop += 1;
        const word = bytes[at..stop];
        class = .plain;
        for (keywords) |name| if (std.mem.eql(u8, word, name)) {
            class = .keyword;
        };
        for (context.declared) |name| if (std.mem.eql(u8, word, name)) {
            class = .declared;
        };
        for (context.channels, 0..) |name, index| if (std.mem.eql(u8, word, name)) {
            class = .channel;
            channel = @intCast(index);
        };
        if (class == .plain and stop < bytes.len and bytes[stop] == '(') class = .call;
    } else if (first == '"') {
        while (stop < bytes.len and bytes[stop] != '"') stop += 1;
        stop = @min(stop + 1, @as(u32, @intCast(bytes.len)));
        class = .string;
    }
    return .{ .start = @intCast(at), .end = @intCast(stop), .class = class, .channel = channel };
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

/// The style of a token.
pub fn style_of(token: Token, context: Context) text.Style {
    const size = look.code_size;
    var s: text.Style = switch (token.class) {
        .space, .plain => look.style(.serif, size, look.ink),
        .keyword => look.style(.serif, size, look.keyword),
        .call => look.style(.serif_italic, size, look.ink),
        .declared => look.style(.serif_bold, size, look.ink),
        .channel => look.style(.serif, size, look.channel_colors[token.channel]),
        .number => look.style(.serif, size, look.number),
        .range_end => look.style(.serif, size, look.range_end),
        .string => look.style(.serif, size, look.string),
        .punctuation => look.style(.serif, size, look.punctuation),
    };
    s.color[3] *= context.alpha;
    return s;
}

/// Draws `bytes` as one line from `x` in `line` (the line's box), under `clip`. Returns the
/// pen's end.
pub fn draw_line(cx: anytype, bytes: []const u8, x: f32, line: Rect, clip: Clip, context: Context) f32 {
    var tokens: [token_cap]Token = undefined;
    const count = tokenize(bytes, context, &tokens);
    var pen = x;
    for (tokens[0..count]) |token| {
        const piece = bytes[token.start..token.end];
        const s = style_of(token, context);
        const width = text.measure(s, piece);
        if (token.class != .space and pen < clip.x1 and pen + width > clip.x0) {
            const rect: Rect = .{ .x = pen, .y = line.y, .width = width + 4, .height = line.height };
            kit.label(cx, s, piece, rect, clip, look.start);
        }
        pen += width;
    }
    return pen;
}

/// The pen's x at byte `offset` of `bytes` set from `x`: where a slot or a call begins.
pub fn x_of(bytes: []const u8, offset: u32, x: f32, context: Context) f32 {
    assert(offset <= bytes.len);
    var tokens: [token_cap]Token = undefined;
    const count = tokenize(bytes, context, &tokens);
    var pen = x;
    for (tokens[0..count]) |token| {
        const s = style_of(token, context);
        if (token.end <= offset) {
            pen += text.measure(s, bytes[token.start..token.end]);
            continue;
        }
        if (token.start < offset) pen += text.measure(s, bytes[token.start..offset]);
        break;
    }
    return pen;
}

// Locks the classes of section 3 on a line from the mix: the declared name bold, calls
// italic, the string cream, and the range 0~0.73~1 as dim end, bright value, dim end.
test "tokens of a mix line" {
    var tokens: [token_cap]Token = undefined;
    const line = "wet := room.wet * k(0~0.73~1, \"wet\");";
    const context: Context = .{ .declared = &.{"wet"} };
    const count = tokenize(line, context, &tokens);
    var classes: [token_cap]Class = undefined;
    var shown: u32 = 0;
    for (tokens[0..count]) |token| {
        if (token.class == .space) continue;
        classes[shown] = token.class;
        shown += 1;
    }
    const expected = [_]Class{
        .declared,    .punctuation, .punctuation, .plain,       .punctuation, .declared,    .punctuation,
        .call,        .punctuation, .range_end,   .punctuation, .number,      .punctuation, .range_end,
        .punctuation, .string,      .punctuation, .punctuation,
    };
    try std.testing.expectEqualSlices(Class, &expected, classes[0..shown]);
}

// Locks negative numbers and slots: "-2.68db" after "=" is one number, a minus between names
// is punctuation, and expand records the slot's span.
test "negative numbers and slot spans" {
    var tokens: [token_cap]Token = undefined;
    const count = tokenize("level = -2.68db, n - 12", .{}, &tokens);
    try std.testing.expectEqual(@as(u32, 12), count);
    try std.testing.expectEqual(Class.number, tokens[4].class);
    try std.testing.expectEqualStrings("-2.68db", "level = -2.68db, n - 12"[tokens[4].start..tokens[4].end]);
    try std.testing.expectEqual(Class.punctuation, tokens[9].class);
    var slots: Slots = .{};
    slots.set(2, "{d:.2}", .{0.73});
    var out: [line_cap]u8 = undefined;
    var spans: [slot_count]Span = undefined;
    const line = expand(&out, "k(0~$c~1)", &slots, &spans);
    try std.testing.expectEqualStrings("k(0~0.73~1)", line);
    try std.testing.expectEqual(Span{ .start = 4, .len = 4 }, spans[2]);
}

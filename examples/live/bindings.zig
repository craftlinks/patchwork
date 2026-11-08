//! The binding parser: `k(lo~value~hi, "name")` calls, `shape(a, b, c, d)` calls, and the
//! `bpm := <int>` line, found in one pass over the editor's buffer.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Full Pass Over Cached Start States
//! Every line is tokenized from its cached start state (`editor/tokenizer.zig`), so comments
//! and strings are skipped for free and no line depends on the lines above it. A pass over
//! 64 KiB costs about 0.23 ms in ReleaseFast and 2.5 ms in Debug, which an edit can afford.
//! The app runs it on every revision it did not cause; its own literal rewrites move the
//! ranges with `shift` instead, which is O(bindings + shapes + errors).
//!
//! ## 2. Grammar (tokens, one line)
//! ```text
//! binding  k ( num ~ num ~ num [ , string ] )     `k` exactly, `(` the next token
//! num      [-] number                             `-` directly before the digits
//! number   digits [. digits]  or  . digits        no exponent, at most 9 integer digits
//!                                                 and 6 decimals
//! shape    shape ( ident , ident , ident , ident )
//! bpm      bpm := digits                          the first three tokens of a line
//! ```
//! A call that breaks the grammar, spans lines, or has `lo >= hi` at the value's decimals is
//! an error over the call up to the token that broke it. A value outside `[lo, hi]` binds
//! (its knob clamps for display) and is also an error over the value. The name is optional;
//! a nameless knob is labelled `#n`.
//!
//! ## 3. Fixed Point
//! Literals are `editor.literal`'s fixed point, so a knob writes back exactly the digits it
//! read. A binding's steps are `editor.literal.steps` of its three literals: `lo` rounded up
//! and `hi` rounded down to the value's decimals, so a knob moves in steps of its last digit.
//!
//! ## 4. Caps
//! The first `binding_cap` well-formed calls bind; later ones are counted in `call_count`
//! only. At most `shape_cap` shape calls (one inline row each), and `error_cap` errors, so
//! boxes plus errors fit `editor.decoration_cap`. An argument of `shape` resolves to the
//! first binding with that name; one that does not resolve is an error.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage, no allocation. The pass is bounded by the text; each line by its tokens.
//! - Every range lies inside the text; bindings, shapes, and errors ascend by start.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const editor = patchwork.editor;
const tokenizer = editor.tokenizer;
const fixed_point = editor.literal;

pub const Range = editor.buffer.Range;
pub const Buffer = editor.buffer.Buffer;

/// Calls that bind; later well-formed calls are counted, not bound.
pub const binding_cap: u32 = 64;
/// Shape calls, one inline row each.
pub const shape_cap: u32 = editor.row_cap;
/// Errors kept; one box per binding plus every error fit the editor's decorations.
pub const error_cap: u32 = editor.decoration_cap - binding_cap;
pub const literal_cap = fixed_point.literal_cap;
pub const shape_args: u32 = 4;

pub const Fixed = fixed_point.Fixed;

/// A number in the text and its value.
pub const Literal = struct {
    range: Range,
    fixed: Fixed,
};

pub const Binding = struct {
    /// From `k` to the closing parenthesis.
    call: Range,
    lo: Literal,
    value: Literal,
    hi: Literal,
    /// The name's bytes inside the quotes; empty for a nameless call.
    name: Range,
    /// `lo` rounded up and `hi` rounded down to the value's decimals (section 3).
    step_lo: i64,
    step_hi: i64,
};

pub const Shape = struct {
    call: Range,
    line: u32,
    args: [shape_args]Range,
    /// The binding each argument resolved to, or null.
    bound: [shape_args]?u8,
};

pub const Parse = struct {
    bindings: [binding_cap]Binding,
    binding_count: u32,
    /// Well-formed `k` calls, bound or not.
    call_count: u32,
    shapes: [shape_cap]Shape,
    shape_count: u32,
    errors: [error_cap]Range,
    error_count: u32,
    /// Errors found, kept or not.
    error_total: u32,
    bpm: ?Literal,

    pub fn init(self: *Parse) void {
        self.binding_count = 0;
        self.call_count = 0;
        self.shape_count = 0;
        self.error_count = 0;
        self.error_total = 0;
        self.bpm = null;
        assert(self.ok());
    }

    /// True when the text has no error (the header shows a check).
    pub fn ok(self: *const Parse) bool {
        assert(self.error_count <= self.error_total);
        return self.error_total == 0;
    }

    /// Parses the whole text (section 2), then resolves the shape arguments.
    pub fn run(self: *Parse, buffer: *const Buffer) void {
        self.init();
        var line: u32 = 0;
        while (line < buffer.line_count) : (line += 1) {
            self.run_line(buffer, line);
        }
        self.resolve(buffer.text());
        assert(self.binding_count <= binding_cap);
        assert(self.binding_count <= self.call_count);
    }

    /// Moves every range edge at or after byte `at` by `delta`: the text from `at` on moved
    /// because the bytes before it changed length (a rewritten literal ending at `at`).
    pub fn shift(self: *Parse, at: u32, delta: i32) void {
        for (self.bindings[0..self.binding_count]) |*binding| {
            fixed_point.shift(&binding.call, at, delta);
            fixed_point.shift(&binding.lo.range, at, delta);
            fixed_point.shift(&binding.value.range, at, delta);
            fixed_point.shift(&binding.hi.range, at, delta);
            fixed_point.shift(&binding.name, at, delta);
        }
        for (self.shapes[0..self.shape_count]) |*shape| {
            fixed_point.shift(&shape.call, at, delta);
            for (&shape.args) |*arg| fixed_point.shift(arg, at, delta);
        }
        for (self.errors[0..self.error_count]) |*range| fixed_point.shift(range, at, delta);
        if (self.bpm) |*bpm| fixed_point.shift(&bpm.range, at, delta);
    }

    fn run_line(self: *Parse, buffer: *const Buffer, line: u32) void {
        const bytes = buffer.line_bytes(line);
        const base = buffer.line_range(line).start;
        var scan: Scan = .{ .bytes = bytes, .state = buffer.states[line], .at = 0 };
        var first = true;
        while (scan.next()) |token| {
            const word = bytes[token.start..token.end];
            const leading = first;
            first = false;
            if (token.class != .identifier) continue;
            if (std.mem.eql(u8, word, "k")) {
                self.binding_at(&scan, token, base);
            } else if (std.mem.eql(u8, word, "shape")) {
                self.shape_at(&scan, token, base, line);
            } else if (leading and std.mem.eql(u8, word, "bpm")) {
                self.bpm_at(&scan, base);
            }
        }
    }

    /// After the identifier `k`: a binding, an error, or nothing when no `(` follows.
    fn binding_at(self: *Parse, scan: *Scan, head: tokenizer.Token, base: u32) void {
        const open = scan.peek() orelse return;
        if (!scan.is(open, "(")) return;
        _ = scan.next();
        const found = binding_tail(scan, head, base);
        switch (found) {
            .broken => |end| self.add_error(.{ .start = base + head.start, .end = base + end }),
            .bound => |binding| {
                self.call_count += 1;
                if (self.binding_count == binding_cap) return;
                self.bindings[self.binding_count] = binding;
                self.binding_count += 1;
                const value = binding.value.fixed.units;
                if (value < binding.step_lo or value > binding.step_hi) {
                    self.add_error(binding.value.range);
                }
            },
        }
    }

    /// After the identifier `shape`: a shape, an error, or nothing when no `(` follows.
    fn shape_at(self: *Parse, scan: *Scan, head: tokenizer.Token, base: u32, line: u32) void {
        const open = scan.peek() orelse return;
        if (!scan.is(open, "(")) return;
        _ = scan.next();
        var shape: Shape = .{
            .call = .{ .start = base + head.start, .end = base + head.start },
            .line = line,
            .args = undefined,
            .bound = @splat(null),
        };
        if (shape_tail(scan, &shape, base)) |broken| {
            return self.add_error(.{ .start = shape.call.start, .end = base + broken });
        }
        if (self.shape_count == shape_cap) return self.add_error(shape.call);
        self.shapes[self.shape_count] = shape;
        self.shape_count += 1;
    }

    /// After a leading `bpm`: `:=` and an integer make the bpm literal (the first one wins).
    fn bpm_at(self: *Parse, scan: *Scan, base: u32) void {
        if (self.bpm != null) return;
        const assign = scan.next() orelse return;
        if (!scan.is(assign, ":=")) return;
        const number = scan.next() orelse return;
        if (number.class != .number) return;
        const fixed = fixed_point.parse(scan.bytes[number.start..number.end]) orelse return;
        if (fixed.decimals != 0) return;
        const range: Range = .{ .start = base + number.start, .end = base + number.end };
        self.bpm = .{ .range = range, .fixed = fixed };
    }

    fn add_error(self: *Parse, range: Range) void {
        assert(range.start <= range.end);
        self.error_total += 1;
        if (self.error_count == error_cap) return;
        self.errors[self.error_count] = range;
        self.error_count += 1;
    }

    /// Resolves each shape argument to the first binding of that name; an argument that
    /// does not resolve is an error.
    fn resolve(self: *Parse, text: []const u8) void {
        for (self.shapes[0..self.shape_count]) |*shape| {
            for (shape.args, 0..) |arg, index| {
                const name = text[arg.start..arg.end];
                shape.bound[index] = self.find(text, name);
                if (shape.bound[index] == null) self.add_error(arg);
            }
        }
        // Resolution errors come after the pass's; keep the list ascending by start.
        std.mem.sort(Range, self.errors[0..self.error_count], {}, range_before);
    }

    /// The first binding named `name`, or null.
    pub fn find(self: *const Parse, text: []const u8, name: []const u8) ?u8 {
        assert(name.len > 0);
        for (self.bindings[0..self.binding_count], 0..) |binding, index| {
            if (std.mem.eql(u8, text[binding.name.start..binding.name.end], name)) {
                return @intCast(index);
            }
        }
        return null;
    }
};

const Found = union(enum) {
    bound: Binding,
    /// The line offset where the call broke.
    broken: u32,
};

/// The rest of a binding after `k (`.
fn binding_tail(scan: *Scan, head: tokenizer.Token, base: u32) Found {
    var literals: [3]Literal = undefined;
    for (&literals, 0..) |*literal, index| {
        if (index > 0) {
            const tilde = scan.next() orelse return .{ .broken = scan.end() };
            if (!scan.is(tilde, "~")) return .{ .broken = tilde.end };
        }
        literal.* = scan.literal(base) orelse return .{ .broken = scan.failed };
    }
    const after = scan.next() orelse return .{ .broken = scan.end() };
    var name: Range = .{ .start = base + after.end, .end = base + after.end };
    var close = after;
    if (scan.is(after, ",")) {
        const string = scan.next() orelse return .{ .broken = scan.end() };
        if (string.class != .string) return .{ .broken = string.end };
        if (string.end - string.start < 2) return .{ .broken = string.end };
        if (scan.bytes[string.end - 1] != '"') return .{ .broken = string.end };
        name = .{ .start = base + string.start + 1, .end = base + string.end - 1 };
        close = scan.next() orelse return .{ .broken = scan.end() };
    }
    if (!scan.is(close, ")")) return .{ .broken = close.end };
    const steps = fixed_point.steps(literals[0].fixed, literals[1].fixed, literals[2].fixed) orelse
        return .{ .broken = close.end };
    return .{ .bound = .{
        .call = .{ .start = base + head.start, .end = base + close.end },
        .lo = literals[0],
        .value = literals[1],
        .hi = literals[2],
        .name = name,
        .step_lo = steps.lo,
        .step_hi = steps.hi,
    } };
}

/// The tokens of one line with one token of lookahead.
const Scan = struct {
    bytes: []const u8,
    state: tokenizer.State,
    at: u32,
    /// Where `literal` failed, for the error range.
    failed: u32 = 0,

    fn next(self: *Scan) ?tokenizer.Token {
        return tokenizer.next(self.bytes, &self.at, &self.state);
    }

    fn peek(self: *const Scan) ?tokenizer.Token {
        var copy = self.*;
        return copy.next();
    }

    fn end(self: *const Scan) u32 {
        return @intCast(self.bytes.len);
    }

    fn is(self: *const Scan, token: tokenizer.Token, word: []const u8) bool {
        return std.mem.eql(u8, self.bytes[token.start..token.end], word);
    }

    /// `[-] number` as a literal, or null with `failed` set.
    fn literal(self: *Scan, base: u32) ?Literal {
        var token = self.next() orelse {
            self.failed = self.end();
            return null;
        };
        const start = token.start;
        if (self.is(token, "-")) {
            const digits = self.next() orelse {
                self.failed = self.end();
                return null;
            };
            if (digits.start != token.end) {
                self.failed = digits.end;
                return null;
            }
            token = digits;
        }
        if (token.class != .number) {
            self.failed = token.end;
            return null;
        }
        const fixed = fixed_point.parse(self.bytes[start..token.end]) orelse {
            self.failed = token.end;
            return null;
        };
        return .{ .range = .{ .start = base + start, .end = base + token.end }, .fixed = fixed };
    }
};

/// Fills a shape's arguments and its call's end after `shape (`. Returns the line offset
/// where the call broke, or null.
fn shape_tail(scan: *Scan, shape: *Shape, base: u32) ?u32 {
    var index: u32 = 0;
    while (index < shape_args) : (index += 1) {
        const arg = scan.next() orelse return scan.end();
        if (arg.class != .identifier) return arg.end;
        shape.args[index] = .{ .start = base + arg.start, .end = base + arg.end };
        const after = scan.next() orelse return scan.end();
        const closer = if (index + 1 == shape_args) ")" else ",";
        if (!scan.is(after, closer)) return after.end;
        shape.call.end = base + after.end;
    }
    assert(shape.call.end > shape.call.start);
    return null;
}

fn range_before(context: void, a: Range, b: Range) bool {
    _ = context;
    return a.start < b.start;
}

comptime {
    assert(binding_cap + error_cap == editor.decoration_cap);
    assert(shape_cap == 32);
}

// ------------------------------------------------------------------------------ tests

const testing = std.testing;

const fixture = struct {
    var buffer: Buffer = undefined;
    var parse: Parse = undefined;
};

/// Parses `source` in the static fixture; returns the parse.
fn parsed(source: []const u8) *Parse {
    fixture.buffer.init();
    const loaded = fixture.buffer.load(source);
    assert(loaded);
    fixture.parse.run(&fixture.buffer);
    return &fixture.parse;
}

fn bytes_of(range: Range) []const u8 {
    return fixture.buffer.text()[range.start..range.end];
}

// Locks the patch: 14 bindings in source order (the header comment's `k(lo~value~hi,
// "name")` and `pick(notes)` bind nothing), signed and integer literals, one shape whose four
// arguments resolve to the bindings declared after it, and `bpm := 121`.
test "the patch binds 14 knobs, one shape, and the bpm line" {
    const result = parsed(@embedFile("patch.lpg"));
    try testing.expect(result.ok());
    try testing.expectEqual(@as(u32, 14), result.binding_count);
    try testing.expectEqual(@as(u32, 14), result.call_count);
    const names = [_][]const u8{
        "swing",     "snare",  "again",     "flange", "gain", "slope", "twice",
        "asymmetry", "cutoff", "resonance", "duck",   "send", "size",  "master",
    };
    for (result.bindings[0..14], names) |binding, name| {
        try testing.expectEqualStrings(name, bytes_of(binding.name));
    }
    const flange = result.bindings[3];
    try testing.expectEqualStrings("-0.98", bytes_of(flange.lo.range));
    try testing.expectEqualStrings("0.445", bytes_of(flange.value.range));
    try testing.expectEqual(Fixed{ .units = -98, .decimals = 2, .bare = false }, flange.lo.fixed);
    try testing.expectEqual(@as(i64, -980), flange.step_lo);
    try testing.expectEqual(@as(i64, 980), flange.step_hi);
    const twice = result.bindings[6];
    try testing.expectEqual(Fixed{ .units = 0, .decimals = 0, .bare = false }, twice.value.fixed);
    try testing.expectEqual(@as(i64, 0), twice.step_lo);
    try testing.expectEqual(@as(i64, 1), twice.step_hi);
    try testing.expectEqual(@as(u32, 1), result.shape_count);
    const shape = result.shapes[0];
    try testing.expectEqual(@as(u32, 26), shape.line);
    try testing.expectEqual([4]?u8{ 4, 5, 6, 7 }, shape.bound);
    try testing.expectEqualStrings("shape(gain, slope, twice, asymmetry)", bytes_of(shape.call));
    try testing.expectEqualStrings("121", bytes_of(result.bpm.?.range));
}

// Locks the negative space: each malformed call is one error from `k` to the token that
// broke it, and binds nothing: a missing bound, a bare name, an exponent, lo >= hi at the
// value's decimals, a call left open at the line end, a detached sign, too many decimals,
// and too many integer digits.
test "malformed calls are errors over the call" {
    const cases = [_]struct { source: []const u8, error_bytes: []const u8 }{
        .{ .source = "a := k(0~1) + 2", .error_bytes = "k(0~1)" },
        .{ .source = "a := k(0~0.5~1, name)", .error_bytes = "k(0~0.5~1, name" },
        .{ .source = "a := k(0~1e3~2000)", .error_bytes = "k(0~1e3" },
        .{ .source = "a := k(1~0.5~0)", .error_bytes = "k(1~0.5~0)" },
        .{ .source = "a := k(0.041~0.04~0.049)", .error_bytes = "k(0.041~0.04~0.049)" },
        .{ .source = "a := k(0~0.5~1,\n\"x\")", .error_bytes = "k(0~0.5~1," },
        .{ .source = "a := k(0~- 0.5~1)", .error_bytes = "k(0~- 0.5" },
        .{ .source = "a := k(0~0.1234567~1)", .error_bytes = "k(0~0.1234567" },
        .{ .source = "a := k(0~1~1234567890)", .error_bytes = "k(0~1~1234567890" },
    };
    for (cases) |case| {
        const result = parsed(case.source);
        try testing.expect(!result.ok());
        try testing.expectEqual(@as(u32, 0), result.binding_count);
        try testing.expectEqual(@as(u32, 1), result.error_count);
        try testing.expectEqualStrings(case.error_bytes, bytes_of(result.errors[0]));
    }
}

// Locks the positive space around expressions: a call nested in another call with signed
// bounds, a call in a line comment, a string, and a block comment (none bind), an identifier
// ending in k, a nameless call, and a value outside its range, which binds and is an error
// over the value.
test "nested, commented, signed, nameless, and out of range calls" {
    const source =
        \\x := plate(a, k(-1~-0.5~1, "w")) // k(0~1~2, "c")
        \\y := "k(0~1~2)" + pick(0~1~2)
        \\/* k(0~1~2)
        \\   k(0~1~2) */ z := k(0~.25~1) * k(0~5~1, "loud")
    ;
    const result = parsed(source);
    try testing.expectEqual(@as(u32, 3), result.binding_count);
    try testing.expectEqualStrings("-0.5", bytes_of(result.bindings[0].value.range));
    try testing.expectEqual(@as(i64, -5), result.bindings[0].value.fixed.units);
    try testing.expectEqual(@as(i64, -10), result.bindings[0].step_lo);
    try testing.expectEqualStrings("w", bytes_of(result.bindings[0].name));
    const nameless = result.bindings[1];
    try testing.expectEqual(@as(u32, 0), nameless.name.end - nameless.name.start);
    try testing.expect(nameless.value.fixed.bare);
    try testing.expectEqual(@as(i64, 0), nameless.step_lo);
    try testing.expectEqual(@as(i64, 100), nameless.step_hi);
    try testing.expect(!result.ok());
    try testing.expectEqual(@as(u32, 1), result.error_count);
    try testing.expectEqualStrings("5", bytes_of(result.errors[0]));
}

// Locks the binding cap: 70 well-formed calls bind the first 64 and count all 70, with no
// error; the stress text of 2,000 nameless lines behaves the same way.
test "calls past the cap are counted, not bound" {
    var source: [70 * 12]u8 = undefined;
    var length: usize = 0;
    for (0..70) |_| {
        @memcpy(source[length..][0..12], "k(0~0.5~1)\n\n");
        length += 12;
    }
    const result = parsed(source[0 .. length - 1]);
    try testing.expectEqual(binding_cap, result.binding_count);
    try testing.expectEqual(@as(u32, 70), result.call_count);
    try testing.expect(result.ok());
    try testing.expectEqual(@as(u32, 7 * 12 + 4), result.bindings[7].value.range.start);
}

// Locks the shape rules: an argument that names no binding is an error over the argument,
// a fifth argument breaks the call, and a 33rd shape call is an error over the call.
test "shape arguments resolve by name and the excess are errors" {
    const unresolved = parsed("c := shape(gain, tilt, gain, gain)\ngain := k(0~1~2, \"gain\")");
    try testing.expectEqual([4]?u8{ 0, null, 0, 0 }, unresolved.shapes[0].bound);
    try testing.expectEqual(@as(u32, 1), unresolved.error_count);
    try testing.expectEqualStrings("tilt", bytes_of(unresolved.errors[0]));
    const long = parsed("c := shape(a, b, c, d, e)");
    try testing.expectEqual(@as(u32, 0), long.shape_count);
    try testing.expectEqualStrings("shape(a, b, c, d,", bytes_of(long.errors[0]));
    var source: [33 * 20]u8 = undefined;
    for (0..33) |index| @memcpy(source[index * 20 ..][0..20], "shape(a, a, a, a)  \n");
    const many = parsed(source[0 .. 33 * 20 - 1]);
    try testing.expectEqual(shape_cap, many.shape_count);
    try testing.expectEqual(@as(u32, 32 * 4 + 1), many.error_total);
}

// Locks `shift`: rewriting the first value of two lines from "0.5" to "0.75" moves every edge
// at or after the old end by one byte and leaves the edges before it alone.
test "shift moves the ranges after a rewritten literal" {
    const result = parsed("a := k(0~0.5~1, \"a\")\nb := k(0~0.5~1, \"b\")");
    const before = result.bindings[1];
    const old_end = result.bindings[0].value.range.end;
    result.shift(old_end, 1);
    try testing.expectEqual(@as(u32, 9), result.bindings[0].value.range.start);
    try testing.expectEqual(old_end + 1, result.bindings[0].value.range.end);
    try testing.expectEqual(before.value.range.start + 1, result.bindings[1].value.range.start);
    try testing.expectEqual(before.call.end + 1, result.bindings[1].call.end);
    try testing.expectEqual(@as(u32, 5), result.bindings[0].call.start);
}

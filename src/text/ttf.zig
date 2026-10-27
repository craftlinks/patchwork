//! TrueType reader: table directory, character map, horizontal metrics, and glyph outlines.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Comptime-Parsed Reader
//! The three faces are `@embedFile`d (`text.zig`), so their bytes are known at compile time.
//! `parse` runs at compile time: it finds the tables, picks the character map, reads the
//! vertical metrics, and resolves the printable ASCII glyph ids into `Font.ascii`. Startup
//! therefore parses nothing, and the frame path only reads `cmap` (outside ASCII), `hmtx`,
//! `loca`, and `glyf` at offsets computed here. The font bytes are trusted build inputs, so
//! malformed data trips an assert instead of returning an error.
//!
//! ## 2. Tables
//! - `head`: `unitsPerEm` and `indexToLocFormat` (short `loca` stores offsets / 2).
//! - `hhea`: ascender, descender (stored as a positive `descent`), `numberOfHMetrics`.
//! - `maxp`: `numGlyphs`, which must fit `glyph_cap` (the cache key holds 12 bits of id).
//! - `hmtx`: advances; glyphs past `numberOfHMetrics` reuse the last advance.
//! - `cmap`: format 12 (`(3, 10)` or `(0, 4)`) is preferred, format 4 (`(3, 1)` or `(0, 3)`)
//!   is the fallback. Both are binary searches bounded by 32 steps.
//! - `loca` and `glyf`: one glyph's bytes are `glyf[loca[id] .. loca[id + 1]]`; an empty range
//!   is a glyph without ink (space).
//!
//! ## 3. Outlines
//! A simple glyph is decoded into `Outline` as points in font units (+Y up) with on-curve
//! flags, and contour end indices. A composite is flattened without recursion: an explicit
//! stack of at most `depth_cap` frames holds the cursor into each composite's component list
//! and the accumulated offset. Each component adds its `(dx, dy)` and appends the points of a
//! simple child, or pushes a frame for a composite child. Only `ARGS_ARE_XY_VALUES` offsets
//! are supported, which is every component in the shipped faces: a component with a scale or
//! a 2x2 transform, point matching, a stack deeper than `depth_cap`, more than
//! `component_cap` components, or more than `point_cap` points or `contour_cap` contours
//! makes `load` return `.replace`, and the caller draws glyph 0 (`.notdef`, a box) instead.
//!
//! The bounding box is computed from the decoded points, so a composite's box is exactly the
//! union of its offset components (test "composite e bounds are the union of base and
//! accent"), and does not trust the box a glyph's header stores (some icon fonts write 0 for
//! every `xMin` and `yMin`).
//!
//! ## 4. TigerStyle Invariants
//! - `Outline` is a fixed scratch owned by the cache; nothing allocates.
//! - Every loop is bounded by a point, contour, component, or search-step cap.

const std = @import("std");
const assert = std.debug.assert;

/// Points one outline may hold after composite flattening.
pub const point_cap: u32 = 512;
/// Contours one outline may hold after composite flattening.
pub const contour_cap: u32 = 128;
/// Nesting depth of composite glyphs the flattening stack holds.
pub const depth_cap: u32 = 4;
/// Component records one composite may expand into, all levels together.
pub const component_cap: u32 = 64;
/// Glyph ids must fit the 12-bit glyph field of the cache key.
pub const glyph_cap: u32 = 4096;
/// The glyph drawn in place of one that cannot be loaded: `.notdef`, a box in Noto.
pub const replacement: u16 = 0;
/// Steps that bound a binary search over a 16-bit or 32-bit table.
const search_steps_max: u32 = 32;

/// Offsets and metrics of one parsed face. See the module guide, section 2.
pub const Font = struct {
    bytes: []const u8,
    units_per_em: u32,
    /// Font units above the baseline (`hhea.ascender`).
    ascent: u32,
    /// Font units below the baseline, positive (`-hhea.descender`).
    descent: u32,
    glyph_count: u32,
    metric_count: u32,
    hmtx: u32,
    loca: u32,
    loca_long: bool,
    glyf: u32,
    /// Offset of the chosen `cmap` subtable.
    cmap: u32,
    cmap_format: u16,
    /// Glyph ids of codepoints 0 to 127, resolved at compile time.
    ascii: [128]u16,
};

/// One decoded outline in font units. See the module guide, section 3.
pub const Outline = struct {
    x: [point_cap]f32,
    y: [point_cap]f32,
    on: [point_cap]bool,
    flags: [point_cap]u8,
    ends: [contour_cap]u16,
    point_count: u32,
    contour_count: u32,
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
};

/// What `load` produced.
pub const Load = enum {
    /// No points: the glyph has no ink.
    empty,
    ready,
    /// Unsupported or over a cap; draw `replacement` instead.
    replace,
};

/// Parses `bytes` at compile time. See the module guide, sections 1 and 2.
pub fn parse(comptime bytes: []const u8) Font {
    @setEvalBranchQuota(200_000);
    return comptime read(bytes);
}

/// `parse` at run time, for tests that read a face built at run time (`text/subset.zig`).
pub fn read(bytes: []const u8) Font {
    const head = table(bytes, "head");
    const hhea = table(bytes, "hhea");
    const maxp = table(bytes, "maxp");
    var font: Font = .{
        .bytes = bytes,
        .units_per_em = read_u16(bytes, head + 18),
        .ascent = @intCast(read_i16(bytes, hhea + 4)),
        .descent = @intCast(-@as(i32, read_i16(bytes, hhea + 6))),
        .glyph_count = read_u16(bytes, maxp + 4),
        .metric_count = read_u16(bytes, hhea + 34),
        .hmtx = table(bytes, "hmtx"),
        .loca = table(bytes, "loca"),
        .loca_long = read_i16(bytes, head + 50) == 1,
        .glyf = table(bytes, "glyf"),
        .cmap = 0,
        .cmap_format = 0,
        .ascii = undefined,
    };
    select_cmap(&font, table(bytes, "cmap"));
    for (&font.ascii, 0..) |*id, codepoint| {
        id.* = cmap_lookup(&font, @intCast(codepoint));
    }
    assert(font.units_per_em >= 16);
    assert(font.glyph_count <= glyph_cap);
    assert(font.metric_count >= 1);
    assert(font.metric_count <= font.glyph_count);
    assert(font.cmap_format == 12 or font.cmap_format == 4);
    return font;
}

/// Glyph id for `codepoint`; 0 when the face does not map it.
pub fn glyph_id(font: *const Font, codepoint: u21) u16 {
    if (codepoint < 128) {
        return font.ascii[codepoint];
    }
    const id = cmap_lookup(font, codepoint);
    assert(id < font.glyph_count);
    return id;
}

/// Advance width of `glyph` in font units.
pub fn advance(font: *const Font, glyph: u16) u32 {
    assert(glyph < font.glyph_count);
    const index: u32 = @min(glyph, font.metric_count - 1);
    const units = read_u16(font.bytes, font.hmtx + 4 * index);
    assert(units <= 4 * font.units_per_em);
    return units;
}

/// Decodes `glyph` into `out`, flattening composites. See the module guide, section 3.
pub fn load(font: *const Font, glyph: u16, out: *Outline) Load {
    assert(glyph < font.glyph_count);
    out.point_count = 0;
    out.contour_count = 0;
    const range = glyph_range(font, glyph);
    if (range.start == range.end) {
        return .empty;
    }
    const at = font.glyf + range.start;
    const ok = if (read_i16(font.bytes, at) >= 0)
        append_simple(font, at, 0, 0, out)
    else
        append_composite(font, at, out);
    if (!ok) {
        return .replace;
    }
    if (out.point_count == 0) {
        return .empty;
    }
    bound(out);
    assert(out.x_min <= out.x_max);
    assert(out.contour_count >= 1);
    return .ready;
}

const Range = struct {
    start: u32,
    end: u32,
};

fn glyph_range(font: *const Font, glyph: u16) Range {
    assert(glyph < font.glyph_count);
    const range: Range = if (font.loca_long) .{
        .start = read_u32(font.bytes, font.loca + 4 * @as(u32, glyph)),
        .end = read_u32(font.bytes, font.loca + 4 * @as(u32, glyph) + 4),
    } else .{
        .start = 2 * @as(u32, read_u16(font.bytes, font.loca + 2 * @as(u32, glyph))),
        .end = 2 * @as(u32, read_u16(font.bytes, font.loca + 2 * @as(u32, glyph) + 2)),
    };
    assert(range.start <= range.end);
    assert(font.glyf + range.end <= font.bytes.len);
    return range;
}

/// Appends the simple glyph at `at`, offset by `(dx, dy)`. False when a cap would overflow.
fn append_simple(font: *const Font, at: u32, dx: f32, dy: f32, out: *Outline) bool {
    const bytes = font.bytes;
    const contours: u32 = @intCast(read_i16(bytes, at));
    const base = out.point_count;
    if (contours == 0) {
        return true;
    }
    if (out.contour_count + contours > contour_cap) {
        return false;
    }
    const last_end: u32 = read_u16(bytes, at + 10 + 2 * (contours - 1));
    const count = last_end + 1;
    if (base + count > point_cap) {
        return false;
    }
    var contour: u32 = 0;
    while (contour < contours) : (contour += 1) {
        const end: u32 = read_u16(bytes, at + 10 + 2 * contour);
        assert(end < count);
        out.ends[out.contour_count + contour] = @intCast(base + end);
    }
    const instructions = at + 10 + 2 * contours;
    var cursor = instructions + 2 + read_u16(bytes, instructions);
    cursor = read_flags(bytes, cursor, out.flags[base..][0..count]);
    cursor = read_axis(bytes, cursor, out.flags[base..][0..count], out.x[base..][0..count], .{
        .short = 0x02,
        .same = 0x10,
        .offset = dx,
    });
    _ = read_axis(bytes, cursor, out.flags[base..][0..count], out.y[base..][0..count], .{
        .short = 0x04,
        .same = 0x20,
        .offset = dy,
    });
    for (out.on[base..][0..count], out.flags[base..][0..count]) |*on, flag| {
        on.* = flag & 0x01 != 0;
    }
    out.point_count = base + count;
    out.contour_count += contours;
    assert(out.point_count <= point_cap);
    assert(out.contour_count <= contour_cap);
    return true;
}

/// Expands the run-length coded flags into `flags`; returns the cursor after them.
fn read_flags(bytes: []const u8, start: u32, flags: []u8) u32 {
    var cursor = start;
    var index: u32 = 0;
    const count: u32 = @intCast(flags.len);
    while (index < count) {
        const flag = bytes[cursor];
        cursor += 1;
        flags[index] = flag;
        index += 1;
        if (flag & 0x08 != 0) {
            const repeat: u32 = bytes[cursor];
            cursor += 1;
            assert(index + repeat <= count);
            @memset(flags[index..][0..repeat], flag);
            index += repeat;
        }
    }
    assert(index == count);
    return cursor;
}

const Axis = struct {
    /// Flag bit: the delta is one unsigned byte.
    short: u8,
    /// Flag bit: with `short`, the byte is positive; without, the delta is zero.
    same: u8,
    offset: f32,
};

/// Decodes one coordinate axis of delta-coded values; returns the cursor after it.
fn read_axis(bytes: []const u8, start: u32, flags: []const u8, out: []f32, axis: Axis) u32 {
    assert(flags.len == out.len);
    var cursor = start;
    var value: i32 = 0;
    for (flags, out) |flag, *coordinate| {
        if (flag & axis.short != 0) {
            const magnitude: i32 = bytes[cursor];
            cursor += 1;
            value += if (flag & axis.same != 0) magnitude else -magnitude;
        } else if (flag & axis.same == 0) {
            value += read_i16(bytes, cursor);
            cursor += 2;
        }
        coordinate.* = @as(f32, @floatFromInt(value)) + axis.offset;
    }
    assert(cursor >= start);
    return cursor;
}

const Frame = struct {
    /// Offset of the next component record.
    at: u32,
    dx: f32,
    dy: f32,
    more: bool,
};

/// Component flags (OpenType `glyf`, composite glyph description).
const arg_words: u16 = 0x0001;
const args_xy: u16 = 0x0002;
const scale_one: u16 = 0x0008;
const more_components: u16 = 0x0020;
const scale_xy: u16 = 0x0040;
const scale_2x2: u16 = 0x0080;

/// Flattens the composite at `at` with an explicit stack. False when unsupported.
fn append_composite(font: *const Font, at: u32, out: *Outline) bool {
    const bytes = font.bytes;
    var stack: [depth_cap]Frame = undefined;
    stack[0] = .{ .at = at + 10, .dx = 0, .dy = 0, .more = true };
    var depth: u32 = 1;
    var steps: u32 = 0;
    while (depth > 0) : (steps += 1) {
        if (steps == 2 * component_cap) {
            return false;
        }
        const top = &stack[depth - 1];
        if (!top.more) {
            depth -= 1;
            continue;
        }
        const flags = read_u16(bytes, top.at);
        const child: u16 = read_u16(bytes, top.at + 2);
        if (flags & args_xy == 0) {
            return false;
        }
        if (flags & (scale_one | scale_xy | scale_2x2) != 0) {
            return false;
        }
        const words = flags & arg_words != 0;
        const dx = top.dx + arg_at(bytes, top.at + 4, words, 0);
        const dy = top.dy + arg_at(bytes, top.at + 4, words, 1);
        top.at += if (words) 8 else 6;
        top.more = flags & more_components != 0;
        assert(child < font.glyph_count);
        const range = glyph_range(font, child);
        if (range.start == range.end) {
            continue;
        }
        const child_at = font.glyf + range.start;
        if (read_i16(bytes, child_at) >= 0) {
            if (!append_simple(font, child_at, dx, dy, out)) return false;
            continue;
        }
        if (depth == depth_cap) {
            return false;
        }
        stack[depth] = .{ .at = child_at + 10, .dx = dx, .dy = dy, .more = true };
        depth += 1;
    }
    assert(depth == 0);
    return true;
}

/// The `index`th signed offset argument of a component whose arguments start at `at`.
fn arg_at(bytes: []const u8, at: u32, words: bool, index: u32) f32 {
    assert(index < 2);
    if (words) {
        return @floatFromInt(read_i16(bytes, at + 2 * index));
    }
    const byte: i8 = @bitCast(bytes[at + index]);
    return @floatFromInt(byte);
}

/// Writes the bounding box of the decoded points.
fn bound(out: *Outline) void {
    assert(out.point_count >= 1);
    const count = out.point_count;
    out.x_min = std.math.floatMax(f32);
    out.y_min = std.math.floatMax(f32);
    out.x_max = -std.math.floatMax(f32);
    out.y_max = -std.math.floatMax(f32);
    for (out.x[0..count], out.y[0..count]) |x, y| {
        out.x_min = @min(out.x_min, x);
        out.y_min = @min(out.y_min, y);
        out.x_max = @max(out.x_max, x);
        out.y_max = @max(out.y_max, y);
    }
    assert(out.x_min <= out.x_max);
    assert(out.y_min <= out.y_max);
}

/// Picks the format 12 subtable, else the format 4 one. See the module guide, section 2.
fn select_cmap(font: *Font, cmap: u32) void {
    const bytes = font.bytes;
    const count = read_u16(bytes, cmap + 2);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = cmap + 4 + 8 * index;
        const platform = read_u16(bytes, record);
        const encoding = read_u16(bytes, record + 2);
        const sub = cmap + read_u32(bytes, record + 4);
        const format = read_u16(bytes, sub);
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (!unicode) continue;
        if (format == 12) {
            font.cmap = sub;
            font.cmap_format = 12;
            return;
        }
        if (format == 4 and font.cmap_format == 0) {
            font.cmap = sub;
            font.cmap_format = 4;
        }
    }
    assert(font.cmap_format == 4);
}

fn cmap_lookup(font: *const Font, codepoint: u21) u16 {
    return switch (font.cmap_format) {
        12 => lookup_format12(font, codepoint),
        4 => lookup_format4(font, codepoint),
        else => unreachable,
    };
}

/// Binary search over the sequential map groups `(start, end, first_glyph)`.
fn lookup_format12(font: *const Font, codepoint: u21) u16 {
    const bytes = font.bytes;
    const groups = read_u32(bytes, font.cmap + 12);
    var low: u32 = 0;
    var high: u32 = groups;
    var steps: u32 = 0;
    while (low < high) : (steps += 1) {
        assert(steps < search_steps_max);
        const middle = low + (high - low) / 2;
        const group = font.cmap + 16 + 12 * middle;
        const start = read_u32(bytes, group);
        const end = read_u32(bytes, group + 4);
        if (codepoint < start) {
            high = middle;
        } else if (codepoint > end) {
            low = middle + 1;
        } else {
            const id = read_u32(bytes, group + 8) + (codepoint - start);
            if (id >= font.glyph_count) return 0;
            return @intCast(id);
        }
    }
    return 0;
}

/// Binary search over the segment end codes, then the delta or the glyph id array.
fn lookup_format4(font: *const Font, codepoint: u21) u16 {
    if (codepoint > 0xFFFF) {
        return 0;
    }
    const bytes = font.bytes;
    const segments: u32 = read_u16(bytes, font.cmap + 6) / 2;
    const ends = font.cmap + 14;
    const starts = ends + 2 * segments + 2;
    const deltas = starts + 2 * segments;
    const offsets = deltas + 2 * segments;
    var low: u32 = 0;
    var high: u32 = segments;
    var steps: u32 = 0;
    while (low < high) : (steps += 1) {
        assert(steps < search_steps_max);
        const middle = low + (high - low) / 2;
        if (read_u16(bytes, ends + 2 * middle) < codepoint) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low == segments) return 0;
    if (read_u16(bytes, starts + 2 * low) > codepoint) return 0;
    const delta = read_u16(bytes, deltas + 2 * low);
    const range_offset = read_u16(bytes, offsets + 2 * low);
    var id: u16 = @truncate(codepoint);
    if (range_offset != 0) {
        const start = read_u16(bytes, starts + 2 * low);
        const at = offsets + 2 * low + range_offset + 2 * (@as(u32, id) - start);
        id = read_u16(bytes, at);
        if (id == 0) return 0;
    }
    const mapped = id +% delta;
    if (mapped >= font.glyph_count) return 0;
    return mapped;
}

fn table(bytes: []const u8, comptime tag: *const [4]u8) u32 {
    const count = read_u16(bytes, 4);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = 12 + 16 * index;
        if (std.mem.eql(u8, bytes[record..][0..4], tag)) {
            const offset = read_u32(bytes, record + 8);
            assert(offset + read_u32(bytes, record + 12) <= bytes.len);
            return offset;
        }
    }
    unreachable;
}

fn read_u16(bytes: []const u8, offset: u32) u16 {
    assert(offset + 2 <= bytes.len);
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn read_i16(bytes: []const u8, offset: u32) i16 {
    assert(offset + 2 <= bytes.len);
    return std.mem.readInt(i16, bytes[offset..][0..2], .big);
}

fn read_u32(bytes: []const u8, offset: u32) u32 {
    assert(offset + 4 <= bytes.len);
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

comptime {
    assert(glyph_cap == 1 << 12);
    assert(depth_cap >= 1);
    assert(point_cap <= std.math.maxInt(u16));
    assert(contour_cap <= point_cap);
}

const testing = std.testing;

/// The full faces from the repo, not the build's subsets (`text/subset.zig`): these tests
/// exercise tables a subset drops, such as the format 4 `cmap` and supplementary planes.
const full = struct {
    const sans = parse(@embedFile("fonts/NotoSans-Regular.ttf"));
    const sans_bold = parse(@embedFile("fonts/NotoSans-Bold.ttf"));
    const mono = parse(@embedFile("fonts/NotoSansMono-Regular.ttf"));
};

// Locks the format 12 path: the faces' map covers codepoints past the BMP, which a format 4
// table cannot hold, and agrees with the format 4 table for BMP codepoints outside ASCII.
test "cmap 12 maps a supplementary codepoint and agrees with format 4" {
    const font = &full.sans;
    try testing.expectEqual(@as(u16, 12), font.cmap_format);
    // U+1DF00 (Latin Small Letter Retroflex Click) is in Noto Sans's format 12 table.
    try testing.expect(glyph_id(font, 0x1DF00) != 0);
    var four = font.*;
    select_format4(&four);
    try testing.expectEqual(@as(u16, 4), four.cmap_format);
    for ([_]u21{ 0xE9, 0xFC, 0xB7, 0x2026, 0xFFFD, 0x0416 }) |codepoint| {
        try testing.expect(glyph_id(font, codepoint) != 0);
        try testing.expectEqual(glyph_id(font, codepoint), glyph_id(&four, codepoint));
    }
    try testing.expectEqual(@as(u16, 0), glyph_id(&four, 0x1DF00));
    try testing.expectEqual(@as(u16, 0), glyph_id(font, 0xE000));
}

/// Points `font` at its format 4 subtable, for the test above.
fn select_format4(font: *Font) void {
    const cmap = table(font.bytes, "cmap");
    const count = read_u16(font.bytes, cmap + 2);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = cmap + 4 + 8 * index;
        const sub = cmap + read_u32(font.bytes, record + 4);
        if (read_u16(font.bytes, sub) == 4) {
            font.cmap = sub;
            font.cmap_format = 4;
            return;
        }
    }
    unreachable;
}

/// Static scratch, so the outline tests keep the 6 KiB outline off the stack.
const scratch = struct {
    var outline: Outline = undefined;
    var other: Outline = undefined;
};

// Locks composite flattening: "e acute" is a composite of "e" and an offset acute accent, and
// its decoded box is exactly the union of the base's box and the accent's offset box.
test "composite e bounds are the union of base and accent" {
    const font = &full.sans;
    const composite = glyph_id(font, 0xE9);
    const at = font.glyf + glyph_range(font, composite).start;
    try testing.expect(read_i16(font.bytes, at) < 0);
    try testing.expectEqual(Load.ready, load(font, composite, &scratch.outline));
    const whole = scratch.outline;
    // Walk the two component records by hand: base first, then the accent with its offset.
    const first = at + 10;
    const base_flags = read_u16(font.bytes, first);
    const base_size: u32 = if (base_flags & arg_words != 0) 8 else 6;
    try testing.expect(base_flags & more_components != 0);
    const accent_id = read_u16(font.bytes, first + base_size + 2);
    const accent_words = read_u16(font.bytes, first + base_size) & arg_words != 0;
    const dx = arg_at(font.bytes, first + base_size + 4, accent_words, 0);
    const dy = arg_at(font.bytes, first + base_size + 4, accent_words, 1);
    try testing.expectEqual(Load.ready, load(font, glyph_id(font, 'e'), &scratch.other));
    const base = scratch.other;
    try testing.expectEqual(Load.ready, load(font, accent_id, &scratch.other));
    const accent = scratch.other;
    try testing.expectEqual(@min(base.x_min, accent.x_min + dx), whole.x_min);
    try testing.expectEqual(@max(base.x_max, accent.x_max + dx), whole.x_max);
    try testing.expectEqual(@min(base.y_min, accent.y_min + dy), whole.y_min);
    try testing.expectEqual(@max(base.y_max, accent.y_max + dy), whole.y_max);
    try testing.expectEqual(base.point_count + accent.point_count, whole.point_count);
    // The accent rises above the base, so the union is taller than "e" alone.
    try testing.expect(accent.y_max + dy > base.y_max);
    try testing.expect(whole.y_max > base.y_max);
}

// Locks the monospace face: every printable ASCII glyph advances 600 units, and the
// proportional face does not.
test "mono advance is identical for all printable ASCII" {
    const mono = &full.mono;
    const sans = &full.sans;
    var codepoint: u21 = ' ';
    while (codepoint <= '~') : (codepoint += 1) {
        try testing.expectEqual(@as(u32, 600), advance(mono, glyph_id(mono, codepoint)));
    }
    try testing.expect(advance(sans, glyph_id(sans, 'i')) != advance(sans, glyph_id(sans, 'W')));
}

// Locks the empty and replacement paths: space has no outline, and glyph 0 (`.notdef`) is a
// drawable two-contour box.
test "space is empty and the replacement glyph is a box" {
    const font = &full.sans_bold;
    try testing.expectEqual(Load.empty, load(font, glyph_id(font, ' '), &scratch.outline));
    try testing.expectEqual(Load.ready, load(font, replacement, &scratch.outline));
    try testing.expectEqual(@as(u32, 2), scratch.outline.contour_count);
    try testing.expect(scratch.outline.x_max > scratch.outline.x_min);
}

//! TrueType subsetter: keeps the glyphs of chosen codepoint ranges and writes the tables the
//! reader (`text/ttf.zig`) needs, at build time (`tools/subset.zig`).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Subset
//! The three Noto faces are 1.85 MB, nearly all of a ReleaseSmall wasm. The UI draws a few
//! hundred codepoints of them. The build runs this file through `tools/subset.zig` once per
//! range set and the library embeds the result (`patchwork_fonts`, `build.zig`), so both
//! targets carry the same small faces. This file depends on `std` only, so the tool builds
//! without the library it feeds.
//!
//! ## 2. The Glyph Set
//! ```text
//! cmap format 12 groups -> every codepoint in `ranges` -> its glyph   (pairs, codepoint order)
//! keep = { .notdef } + those glyphs
//! worklist: pop a glyph; a composite pushes each component not yet kept
//! new_id[old] = how many kept glyphs precede it       (old order, so .notdef stays 0)
//! ```
//! The set is closed over components before anything is written, so no composite ever names
//! a dropped glyph. The worklist holds each glyph at most once, so it is bounded by the glyph
//! count.
//!
//! ## 3. The Tables Written
//! Only what the reader reads, in tag order, 4-byte aligned, each with its checksum:
//! ```text
//! cmap  version 0, one (3, 10) format 12 subtable; a group per run of consecutive
//!       codepoints with consecutive new ids
//! glyf  simple glyphs: instructionLength 0 and the instructions dropped, contours, flags,
//!       and coordinates byte for byte; composites: component ids renumbered, the
//!       instructions flag (0x0100) cleared and the instructions dropped; padded to 2 bytes
//! head  copied; indexToLocFormat and checkSumAdjustment rewritten
//! hhea  copied; numberOfHMetrics = n (one full metric per kept glyph)
//! hmtx  (advance, lsb) per kept glyph; past the input's numberOfHMetrics, the last advance
//! loca  short (offset / 2) when glyf is under 128 KiB, else long
//! maxp  copied; numGlyphs = n
//! ```
//! Hinting instructions are dropped because the rasterizer (`text/raster.zig`) never runs
//! them; outlines and advances are unchanged, which the tests check glyph by glyph.
//! `checkSumAdjustment = 0xB1B0AFBA - sum of the file's words`, computed with it zeroed.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: `Scratch` holds the fixed tables, and the output goes into the caller's
//!   buffer; a short buffer is `error.NoSpace`.
//! - Every loop is bounded by the glyph count, a component count, or a codepoint group.

const std = @import("std");
const assert = std.debug.assert;

/// Glyphs a face may have: the reader's cache key holds 12 bits of id (`ttf.glyph_cap`).
pub const glyph_cap: u32 = 4096;
/// Codepoints the kept ranges may map.
pub const codepoint_cap: u32 = 16384;
/// Components one composite may list.
const component_cap: u32 = 64;
/// Tables written.
const table_count: u32 = 7;
const directory_bytes: u32 = 12 + 16 * table_count;

/// An inclusive codepoint range.
pub const Range = [2]u21;

/// The ranges an app gets unless it passes its own (`AppOptions.font_ranges`): Basic Latin,
/// Latin-1, Latin Extended-A, the punctuation and symbols UI text uses, and U+FFFD, which
/// invalid UTF-8 decodes to. `build.zig` reads this list.
pub const default_ranges = [_]Range{
    .{ 0x0020, 0x007E }, .{ 0x00A0, 0x00FF }, .{ 0x0100, 0x017F },
    .{ 0x2010, 0x2027 }, .{ 0x2030, 0x2030 }, .{ 0x2032, 0x2033 },
    .{ 0x2039, 0x203A }, .{ 0x2044, 0x2044 }, .{ 0x20AC, 0x20AC },
    .{ 0x2122, 0x2122 }, .{ 0x2190, 0x2193 }, .{ 0x2212, 0x2212 },
    .{ 0x2248, 0x2248 }, .{ 0x2260, 0x2260 }, .{ 0x2264, 0x2265 },
    .{ 0xFFFD, 0xFFFD },
};

pub const Error = error{
    /// A required table or a Unicode format 12 `cmap` is missing, or the face is malformed.
    Unsupported,
    /// The output buffer is too small.
    NoSpace,
    /// The ranges map more than `codepoint_cap` codepoints.
    TooManyCodepoints,
};

/// What `subset` kept: for the tool's report and the tests.
pub const Summary = struct {
    bytes: u32,
    glyphs: u32,
    codepoints: u32,
};

/// Fixed working storage, about 120 KiB. Out-pointer use only.
pub const Scratch = struct {
    keep: [glyph_cap]bool,
    new_id: [glyph_cap]u16,
    worklist: [glyph_cap]u16,
    /// New `glyf` offsets per new id, and one past the last.
    offsets: [glyph_cap + 1]u32,
    /// `(codepoint, old glyph)` in codepoint order.
    pairs: [codepoint_cap][2]u32,
};

const Tables = struct {
    head: Slice,
    hhea: Slice,
    maxp: Slice,
    hmtx: Slice,
    loca: Slice,
    glyf: Slice,
    cmap: Slice,
};

const Slice = struct {
    offset: u32,
    length: u32,
};

const Face = struct {
    bytes: []const u8,
    tables: Tables,
    glyph_count: u32,
    metric_count: u32,
    loca_long: bool,
    /// Offset of the format 12 subtable.
    cmap12: u32,
};

/// Writes the subset of `input` covering `ranges` into `out` (see the module guide).
pub fn subset(
    scratch: *Scratch,
    input: []const u8,
    ranges: []const Range,
    out: []u8,
) Error!Summary {
    assert(ranges.len >= 1);
    for (ranges) |range| assert(range[0] <= range[1]);
    const face = try open(input);
    const codepoints = try collect(scratch, &face, ranges);
    const glyphs = try close_over_components(scratch, &face);
    var writer: Writer = .{ .out = out, .len = directory_bytes };
    if (out.len < directory_bytes) return error.NoSpace;
    @memset(out[0..directory_bytes], 0);
    var records: [table_count]Record = undefined;
    // Tag order: cmap, glyf, head, hhea, hmtx, loca, maxp.
    records[0] = try writer.table("cmap", write_cmap, .{ scratch, codepoints });
    records[1] = try writer.table("glyf", write_glyf, .{ scratch, &face, glyphs });
    const glyf_length = records[1].length;
    const long = glyf_length >= 0x20000;
    records[2] = try writer.table("head", write_head, .{ &face, long });
    records[3] = try writer.table("hhea", write_hhea, .{ &face, glyphs });
    records[4] = try writer.table("hmtx", write_hmtx, .{ scratch, &face, glyphs });
    records[5] = try writer.table("loca", write_loca, .{ scratch, glyphs, long });
    records[6] = try writer.table("maxp", write_maxp, .{ &face, glyphs });
    write_directory(out, &records);
    const total = checksum(out[0..writer.len]);
    const head_at = records[2].offset;
    std.mem.writeInt(u32, out[head_at + 8 ..][0..4], 0xB1B0AFBA -% total, .big);
    assert(writer.len % 4 == 0);
    return .{ .bytes = writer.len, .glyphs = glyphs, .codepoints = codepoints };
}

fn open(input: []const u8) Error!Face {
    if (input.len < 12) return error.Unsupported;
    const tables: Tables = .{
        .head = try find(input, "head"),
        .hhea = try find(input, "hhea"),
        .maxp = try find(input, "maxp"),
        .hmtx = try find(input, "hmtx"),
        .loca = try find(input, "loca"),
        .glyf = try find(input, "glyf"),
        .cmap = try find(input, "cmap"),
    };
    if (tables.head.length < 54 or tables.hhea.length < 36 or tables.maxp.length < 6) {
        return error.Unsupported;
    }
    const glyph_count: u32 = read_u16(input, tables.maxp.offset + 4);
    const metric_count: u32 = read_u16(input, tables.hhea.offset + 34);
    if (glyph_count == 0 or glyph_count > glyph_cap) return error.Unsupported;
    if (metric_count == 0 or metric_count > glyph_count) return error.Unsupported;
    return .{
        .bytes = input,
        .tables = tables,
        .glyph_count = glyph_count,
        .metric_count = metric_count,
        .loca_long = read_u16(input, tables.head.offset + 50) == 1,
        .cmap12 = try find_cmap12(input, tables.cmap.offset),
    };
}

fn find(input: []const u8, comptime tag: *const [4]u8) Error!Slice {
    const count: u32 = read_u16(input, 4);
    if (12 + 16 * count > input.len) return error.Unsupported;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = 12 + 16 * index;
        if (!std.mem.eql(u8, input[record..][0..4], tag)) continue;
        const slice: Slice = .{
            .offset = read_u32(input, record + 8),
            .length = read_u32(input, record + 12),
        };
        if (@as(u64, slice.offset) + slice.length > input.len) return error.Unsupported;
        return slice;
    }
    return error.Unsupported;
}

fn find_cmap12(input: []const u8, cmap: u32) Error!u32 {
    const count: u32 = read_u16(input, cmap + 2);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = cmap + 4 + 8 * index;
        const platform = read_u16(input, record);
        const encoding = read_u16(input, record + 2);
        const sub = cmap + read_u32(input, record + 4);
        const unicode = platform == 0 or (platform == 3 and encoding == 10);
        if (unicode and read_u16(input, sub) == 12) return sub;
    }
    return error.Unsupported;
}

/// Records every `(codepoint, glyph)` in `ranges` in codepoint order and keeps the glyphs.
fn collect(scratch: *Scratch, face: *const Face, ranges: []const Range) Error!u32 {
    @memset(&scratch.keep, false);
    scratch.keep[0] = true;
    const bytes = face.bytes;
    const groups = read_u32(bytes, face.cmap12 + 12);
    var count: u32 = 0;
    var group: u32 = 0;
    while (group < groups) : (group += 1) {
        const at = face.cmap12 + 16 + 12 * group;
        const start = read_u32(bytes, at);
        const end = read_u32(bytes, at + 4);
        const first = read_u32(bytes, at + 8);
        if (end < start or end > 0x10FFFF) return error.Unsupported;
        for (ranges) |range| {
            const low = @max(start, range[0]);
            const high = @min(end, range[1]);
            if (low > high) continue;
            var codepoint = low;
            while (codepoint <= high) : (codepoint += 1) {
                const glyph = first + (codepoint - start);
                if (glyph == 0 or glyph >= face.glyph_count) continue;
                if (count == codepoint_cap) return error.TooManyCodepoints;
                scratch.pairs[count] = .{ codepoint, glyph };
                scratch.keep[glyph] = true;
                count += 1;
            }
        }
    }
    // Groups are sorted, but overlapping ranges may list a codepoint twice or out of order.
    std.mem.sort([2]u32, scratch.pairs[0..count], {}, less_codepoint);
    var unique: u32 = 0;
    for (scratch.pairs[0..count]) |pair| {
        if (unique > 0 and scratch.pairs[unique - 1][0] == pair[0]) continue;
        scratch.pairs[unique] = pair;
        unique += 1;
    }
    return unique;
}

fn less_codepoint(_: void, a: [2]u32, b: [2]u32) bool {
    return a[0] < b[0];
}

/// Closes the kept set over composite components (section 2), assigns new ids, and returns
/// the kept count.
fn close_over_components(scratch: *Scratch, face: *const Face) Error!u32 {
    var pending: u32 = 0;
    for (scratch.keep[0..face.glyph_count], 0..) |kept, glyph| {
        if (kept) {
            scratch.worklist[pending] = @intCast(glyph);
            pending += 1;
        }
    }
    while (pending > 0) {
        pending -= 1;
        const glyph = scratch.worklist[pending];
        var components: [component_cap]u16 = undefined;
        const count = try components_of(face, glyph, &components);
        for (components[0..count]) |child| {
            if (child >= face.glyph_count) return error.Unsupported;
            if (scratch.keep[child]) continue;
            scratch.keep[child] = true;
            assert(pending < glyph_cap);
            scratch.worklist[pending] = child;
            pending += 1;
        }
    }
    var next: u16 = 0;
    for (scratch.keep[0..face.glyph_count], 0..) |kept, glyph| {
        if (!kept) continue;
        scratch.new_id[glyph] = next;
        next += 1;
    }
    assert(scratch.new_id[0] == 0);
    return next;
}

const Bounds = struct {
    start: u32,
    end: u32,
};

fn glyph_bounds(face: *const Face, glyph: u32) Error!Bounds {
    assert(glyph < face.glyph_count);
    const bytes = face.bytes;
    const loca = face.tables.loca.offset;
    const bounds: Bounds = if (face.loca_long) .{
        .start = read_u32(bytes, loca + 4 * glyph),
        .end = read_u32(bytes, loca + 4 * glyph + 4),
    } else .{
        .start = 2 * @as(u32, read_u16(bytes, loca + 2 * glyph)),
        .end = 2 * @as(u32, read_u16(bytes, loca + 2 * glyph + 2)),
    };
    if (bounds.end < bounds.start or bounds.end > face.tables.glyf.length) return error.Unsupported;
    return bounds;
}

/// Component flags (OpenType `glyf`, composite glyph description).
const arg_words: u16 = 0x0001;
const scale_one: u16 = 0x0008;
const more_components: u16 = 0x0020;
const scale_xy: u16 = 0x0040;
const scale_2x2: u16 = 0x0080;
const have_instructions: u16 = 0x0100;

/// Bytes of one component record with `flags`: flags, glyph, arguments, and transform.
fn component_bytes(flags: u16) u32 {
    var size: u32 = 4;
    size += if (flags & arg_words != 0) 4 else 2;
    if (flags & scale_one != 0) size += 2;
    if (flags & scale_xy != 0) size += 4;
    if (flags & scale_2x2 != 0) size += 8;
    return size;
}

/// The component ids of `glyph`, none for a simple or empty glyph.
fn components_of(face: *const Face, glyph: u32, out: *[component_cap]u16) Error!u32 {
    const bounds = try glyph_bounds(face, glyph);
    if (bounds.start == bounds.end) return 0;
    const bytes = face.bytes;
    const at = face.tables.glyf.offset + bounds.start;
    if (read_i16(bytes, at) >= 0) return 0;
    var cursor = at + 10;
    var count: u32 = 0;
    while (true) {
        if (count == component_cap) return error.Unsupported;
        const flags = read_u16(bytes, cursor);
        out[count] = read_u16(bytes, cursor + 2);
        count += 1;
        cursor += component_bytes(flags);
        if (cursor > face.tables.glyf.offset + bounds.end) return error.Unsupported;
        if (flags & more_components == 0) break;
    }
    return count;
}

const Record = struct {
    tag: [4]u8,
    checksum: u32,
    offset: u32,
    length: u32,
};

/// Appends tables to `out` past the directory, each 4-byte aligned.
const Writer = struct {
    out: []u8,
    len: u32,

    /// Runs `body(self, args...)`, which appends one table's bytes, and returns its record.
    fn table(
        self: *Writer,
        comptime tag: *const [4]u8,
        comptime body: anytype,
        args: anytype,
    ) Error!Record {
        assert(self.len % 4 == 0);
        const offset = self.len;
        try @call(.auto, body, .{self} ++ args);
        const length = self.len - offset;
        while (self.len % 4 != 0) try self.byte(0);
        return .{
            .tag = tag.*,
            .checksum = checksum(self.out[offset..self.len]),
            .offset = offset,
            .length = length,
        };
    }

    fn bytes(self: *Writer, data: []const u8) Error!void {
        if (self.out.len - self.len < data.len) return error.NoSpace;
        @memcpy(self.out[self.len..][0..data.len], data);
        self.len += @intCast(data.len);
    }

    fn byte(self: *Writer, value: u8) Error!void {
        return self.bytes(&.{value});
    }

    fn u16be(self: *Writer, value: u16) Error!void {
        var word: [2]u8 = undefined;
        std.mem.writeInt(u16, &word, value, .big);
        return self.bytes(&word);
    }

    fn u32be(self: *Writer, value: u32) Error!void {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, value, .big);
        return self.bytes(&word);
    }
};

fn write_cmap(writer: *Writer, scratch: *const Scratch, codepoints: u32) Error!void {
    const pairs = scratch.pairs[0..codepoints];
    var groups: u32 = 0;
    for (pairs, 0..) |pair, index| {
        if (index == 0 or !continues(scratch, pairs[index - 1], pair)) groups += 1;
    }
    try writer.u16be(0);
    try writer.u16be(1);
    try writer.u16be(3);
    try writer.u16be(10);
    try writer.u32be(12);
    try writer.u16be(12);
    try writer.u16be(0);
    try writer.u32be(16 + 12 * groups);
    try writer.u32be(0);
    try writer.u32be(groups);
    var index: u32 = 0;
    var written: u32 = 0;
    while (index < codepoints) {
        var end = index;
        while (end + 1 < codepoints and continues(scratch, pairs[end], pairs[end + 1])) end += 1;
        try writer.u32be(pairs[index][0]);
        try writer.u32be(pairs[end][0]);
        try writer.u32be(scratch.new_id[pairs[index][1]]);
        written += 1;
        index = end + 1;
    }
    assert(written == groups);
}

/// True when `next` extends the run ending at `last`: both the codepoint and the new id
/// advance by one.
fn continues(scratch: *const Scratch, last: [2]u32, next: [2]u32) bool {
    if (next[0] != last[0] + 1) return false;
    return scratch.new_id[next[1]] == scratch.new_id[last[1]] + 1;
}

fn write_glyf(writer: *Writer, scratch: *Scratch, face: *const Face, glyphs: u32) Error!void {
    const start = writer.len;
    var id: u32 = 0;
    for (scratch.keep[0..face.glyph_count], 0..) |kept, glyph| {
        if (!kept) continue;
        scratch.offsets[id] = writer.len - start;
        try copy_glyph(writer, scratch, face, @intCast(glyph));
        if ((writer.len - start) % 2 != 0) try writer.byte(0);
        id += 1;
    }
    assert(id == glyphs);
    scratch.offsets[glyphs] = writer.len - start;
}

/// Copies one glyph without its instructions, renumbering a composite's components.
fn copy_glyph(writer: *Writer, scratch: *const Scratch, face: *const Face, glyph: u32) Error!void {
    const bounds = try glyph_bounds(face, glyph);
    if (bounds.start == bounds.end) return;
    const bytes = face.bytes;
    const at = face.tables.glyf.offset + bounds.start;
    const end = face.tables.glyf.offset + bounds.end;
    if (end - at < 10) return error.Unsupported;
    const contours = read_i16(bytes, at);
    try writer.bytes(bytes[at..][0..10]);
    if (contours >= 0) {
        const ends_bytes = 2 * @as(u32, @intCast(contours));
        const instructions = at + 10 + ends_bytes;
        if (instructions + 2 > end) return error.Unsupported;
        try writer.bytes(bytes[at + 10 ..][0..ends_bytes]);
        try writer.u16be(0);
        const rest = instructions + 2 + read_u16(bytes, instructions);
        if (rest > end) return error.Unsupported;
        try writer.bytes(bytes[rest..end]);
        return;
    }
    var cursor = at + 10;
    var count: u32 = 0;
    while (true) : (count += 1) {
        if (count == component_cap) return error.Unsupported;
        const flags = read_u16(bytes, cursor);
        const size = component_bytes(flags);
        if (cursor + size > end) return error.Unsupported;
        const child = read_u16(bytes, cursor + 2);
        assert(scratch.keep[child]);
        try writer.u16be(flags & ~have_instructions);
        try writer.u16be(scratch.new_id[child]);
        try writer.bytes(bytes[cursor + 4 ..][0 .. size - 4]);
        cursor += size;
        if (flags & more_components == 0) break;
    }
}

fn write_head(writer: *Writer, face: *const Face, long: bool) Error!void {
    const head = face.bytes[face.tables.head.offset..][0..54];
    const at = writer.len;
    try writer.bytes(head);
    @memset(writer.out[at + 8 ..][0..4], 0);
    std.mem.writeInt(i16, writer.out[at + 50 ..][0..2], if (long) 1 else 0, .big);
}

fn write_hhea(writer: *Writer, face: *const Face, glyphs: u32) Error!void {
    const at = writer.len;
    try writer.bytes(face.bytes[face.tables.hhea.offset..][0..36]);
    std.mem.writeInt(u16, writer.out[at + 34 ..][0..2], @intCast(glyphs), .big);
}

fn write_hmtx(writer: *Writer, scratch: *const Scratch, face: *const Face, glyphs: u32) Error!void {
    const bytes = face.bytes;
    const hmtx = face.tables.hmtx.offset;
    const metrics = face.metric_count;
    var written: u32 = 0;
    for (scratch.keep[0..face.glyph_count], 0..) |kept, glyph_usize| {
        if (!kept) continue;
        const glyph: u32 = @intCast(glyph_usize);
        const advance = read_u16(bytes, hmtx + 4 * @min(glyph, metrics - 1));
        const lsb = if (glyph < metrics)
            read_u16(bytes, hmtx + 4 * glyph + 2)
        else
            read_u16(bytes, hmtx + 4 * metrics + 2 * (glyph - metrics));
        try writer.u16be(advance);
        try writer.u16be(lsb);
        written += 1;
    }
    assert(written == glyphs);
}

fn write_loca(writer: *Writer, scratch: *const Scratch, glyphs: u32, long: bool) Error!void {
    for (scratch.offsets[0 .. glyphs + 1]) |offset| {
        if (long) {
            try writer.u32be(offset);
        } else {
            assert(offset % 2 == 0);
            try writer.u16be(@intCast(offset / 2));
        }
    }
}

fn write_maxp(writer: *Writer, face: *const Face, glyphs: u32) Error!void {
    const at = writer.len;
    try writer.bytes(face.bytes[face.tables.maxp.offset..][0..face.tables.maxp.length]);
    std.mem.writeInt(u16, writer.out[at + 4 ..][0..2], @intCast(glyphs), .big);
}

fn write_directory(out: []u8, records: *const [table_count]Record) void {
    std.mem.writeInt(u32, out[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, out[4..6], table_count, .big);
    // searchRange, entrySelector, rangeShift for 7 tables: 4 is the largest power of two.
    std.mem.writeInt(u16, out[6..8], 4 * 16, .big);
    std.mem.writeInt(u16, out[8..10], 2, .big);
    std.mem.writeInt(u16, out[10..12], table_count * 16 - 4 * 16, .big);
    for (records, 0..) |record, index| {
        const at = 12 + 16 * index;
        @memcpy(out[at..][0..4], &record.tag);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], record.checksum, .big);
        std.mem.writeInt(u32, out[at + 8 ..][0..4], record.offset, .big);
        std.mem.writeInt(u32, out[at + 12 ..][0..4], record.length, .big);
    }
    for (records[0 .. table_count - 1], records[1..]) |a, b| {
        assert(std.mem.order(u8, &a.tag, &b.tag) == .lt);
    }
}

/// The OpenType table checksum: the sum of big-endian words, the tail zero-padded.
fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index < data.len) : (index += 4) {
        var word: [4]u8 = @splat(0);
        const take = @min(4, data.len - index);
        @memcpy(word[0..take], data[index..][0..take]);
        sum +%= std.mem.readInt(u32, &word, .big);
    }
    return sum;
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
    assert(directory_bytes == 124);
    assert(glyph_cap <= std.math.maxInt(u16) + 1);
}

const testing = std.testing;
const ttf = @import("ttf.zig");

const full_faces = [_][]const u8{
    @embedFile("fonts/NotoSans-Regular.ttf"),
    @embedFile("fonts/NotoSans-Bold.ttf"),
    @embedFile("fonts/NotoSansMono-Regular.ttf"),
};

const fixture = struct {
    var scratch: Scratch = undefined;
    var out: [256 * 1024]u8 = undefined;
    var again: [256 * 1024]u8 = undefined;
    var a: ttf.Outline = undefined;
    var b: ttf.Outline = undefined;
};

// Locks the subset against the full faces (sections 2 and 3): for every codepoint of the
// default ranges, the subset maps a glyph exactly when the full face does, with the same
// advance and the same decoded outline (points, on-curve flags, contour ends), so text draws
// the same; a codepoint outside the ranges (U+0416) maps to .notdef, which still loads.
test "the default subset draws every kept codepoint as the full face does" {
    inline for (full_faces) |bytes| {
        const full = comptime ttf.parse(bytes);
        const summary = try subset(&fixture.scratch, bytes, &default_ranges, &fixture.out);
        const sub = ttf.read(fixture.out[0..summary.bytes]);
        try testing.expect(summary.glyphs < 400);
        try testing.expectEqual(summary.glyphs, sub.glyph_count);
        try testing.expectEqual(full.units_per_em, sub.units_per_em);
        try testing.expectEqual(full.ascent, sub.ascent);
        try testing.expectEqual(full.descent, sub.descent);
        try testing.expect(!sub.loca_long);
        for (default_ranges) |range| {
            var codepoint: u21 = range[0];
            while (codepoint <= range[1]) : (codepoint += 1) {
                const old = ttf.glyph_id(&full, codepoint);
                const new = ttf.glyph_id(&sub, codepoint);
                try testing.expectEqual(old == 0, new == 0);
                if (old == 0) continue;
                try testing.expectEqual(ttf.advance(&full, old), ttf.advance(&sub, new));
                try expect_same_outline(&full, old, &sub, new);
            }
        }
        try testing.expect(ttf.glyph_id(&full, 0x0416) != 0);
        try testing.expectEqual(@as(u16, 0), ttf.glyph_id(&sub, 0x0416));
        try expect_same_outline(&full, 0, &sub, 0);
    }
}

fn expect_same_outline(full: *const ttf.Font, old: u16, sub: *const ttf.Font, new: u16) !void {
    const a = &fixture.a;
    const b = &fixture.b;
    try testing.expectEqual(ttf.load(full, old, a), ttf.load(sub, new, b));
    try testing.expectEqual(a.point_count, b.point_count);
    try testing.expectEqual(a.contour_count, b.contour_count);
    try testing.expectEqualSlices(f32, a.x[0..a.point_count], b.x[0..b.point_count]);
    try testing.expectEqualSlices(f32, a.y[0..a.point_count], b.y[0..b.point_count]);
    try testing.expectEqualSlices(bool, a.on[0..a.point_count], b.on[0..b.point_count]);
    try testing.expectEqualSlices(u16, a.ends[0..a.contour_count], b.ends[0..b.contour_count]);
}

// Locks the composite rewrite and the file shape (section 3): e-acute stays a composite whose
// components were kept and renumbered below the kept count; two runs are byte-identical; the
// file has the seven tables; a short buffer is refused.
test "composites are renumbered, the output is deterministic, and space is checked" {
    const bytes = full_faces[0];
    const summary = try subset(&fixture.scratch, bytes, &default_ranges, &fixture.out);
    const again = try subset(&fixture.scratch, bytes, &default_ranges, &fixture.again);
    try testing.expectEqualSlices(u8, fixture.out[0..summary.bytes], fixture.again[0..again.bytes]);
    const output = fixture.out[0..summary.bytes];
    const sub = ttf.read(output);
    const face = try open(output);
    var components: [component_cap]u16 = undefined;
    const count = try components_of(&face, ttf.glyph_id(&sub, 0xE9), &components);
    try testing.expect(count >= 2);
    for (components[0..count]) |child| try testing.expect(child < summary.glyphs);
    try testing.expectEqual(@as(u16, table_count), read_u16(output, 4));
    try testing.expectEqual(@as(u32, 0), checksum(output) -% 0xB1B0AFBA);
    var short: [1024]u8 = undefined;
    const refused = subset(&fixture.scratch, bytes, &default_ranges, &short);
    try testing.expectError(error.NoSpace, refused);
}

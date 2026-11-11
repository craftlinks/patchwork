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
//! cmap groups (format 12) or segments (format 4)
//!   -> every codepoint in `ranges` -> its glyph                       (pairs, codepoint order)
//! keep = { .notdef } + those glyphs
//! worklist: pop a glyph; a composite pushes each component not yet kept
//! new_id[old] = how many kept glyphs precede it       (old order, so .notdef stays 0)
//! ```
//! The set is closed over components before anything is written, so no composite ever names
//! a dropped glyph. The worklist holds each glyph at most once, so it is bounded by the glyph
//! count. The input's Unicode `cmap` is format 12 (`(3, 10)` or platform 0), else format 4
//! (`(3, 1)` or platform 0); the output is always format 12.
//!
//! The face cut from may have any number of glyphs: the working arrays indexed by an old id
//! (`keep`, `new_id`, `worklist`) hold `source_glyph_cap`, the most `maxp` can count. What is
//! written must fit the reader (`ttf.glyph_cap`, the cache key's 12 bits of id), so a set
//! that keeps more than `glyph_cap` glyphs is refused with its count.
//!
//! ## 2a. Claims
//! A codepoint in the ranges that the face does not map is skipped: the app-wide ranges are
//! shared by faces that differ, so a range keeps only what its face holds. A face's own ranges
//! (`Claim.own`) are a claim instead: every codepoint in them must map to a glyph other than
//! `.notdef`, or the subset is `error.MissingGlyph`, with the first such codepoint and their
//! count, so a typo in an icon list fails the build.
//!
//! ## 2b. Refusals
//! Each refusal is its own error, and `Scratch.detail` holds the number or the table that
//! explains it; `message` turns the two into the sentence `tools/subset.zig` prints after the
//! file's name. A face without a `glyf` table (CFF or CFF2 outlines) is `error.NoGlyf`.
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
//! ## 4. App Faces
//! An app adds up to `app_face_max` faces beside the library's three (`AppOptions.fonts`,
//! `build.zig`), each subset by this file like the library's. `check_faces` is the
//! configure-time check of that list: the count, each name a Zig identifier that is not a
//! library face's and not repeated, and each range list non-empty, each range ordered, the
//! ranges increasing and apart. `build.zig` panics with `problem_text` and the face named.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: `Scratch` holds the fixed tables, and the output goes into the caller's
//!   buffer; a short buffer is `error.NoSpace`.
//! - Every loop is bounded by the glyph count, a component count, a codepoint group, or a
//!   range (`check_claim`, whose binary search takes at most 15 steps).

const std = @import("std");
const assert = std.debug.assert;

/// Glyphs a subset may keep: the reader's cache key holds 12 bits of id (`ttf.glyph_cap`).
pub const glyph_cap: u32 = 4096;
/// Glyphs the face cut from may have: every face, since `maxp.numGlyphs` is 16 bits.
pub const source_glyph_cap: u32 = 65535;
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

/// Faces an app may add beside the library's three (section 4): eight in all, the faces the
/// glyph cache key holds.
pub const app_face_max: u32 = 5;
/// The library's faces, in `text.Face` order: the first three tags of every app's `Face`.
pub const library_faces = [_][]const u8{ "sans", "sans_bold", "mono" };
/// Bytes of an app face's name.
pub const face_name_max: u32 = 32;

/// One app face as `check_faces` sees it: its `text.Face` tag and its ranges (null: the app's
/// `font_ranges`).
pub const FaceSpec = struct {
    name: []const u8,
    ranges: ?[]const Range,
};

/// What is wrong with an app's face list (section 4).
pub const FaceProblem = enum {
    too_many,
    name_invalid,
    name_reserved,
    name_duplicate,
    ranges_empty,
    ranges_reversed,
    ranges_unordered,
};

/// The first problem `check_faces` found, and the index of the face it is in.
pub const FaceError = struct {
    index: u32,
    problem: FaceProblem,
};

/// Checks an app's face list (section 4); null when it is valid.
pub fn check_faces(specs: []const FaceSpec) ?FaceError {
    if (specs.len > app_face_max) return .{ .index = app_face_max, .problem = .too_many };
    for (specs, 0..) |spec, index_usize| {
        const index: u32 = @intCast(index_usize);
        const name = spec.name;
        const valid = name.len <= face_name_max and std.zig.isValidId(name) and
            !std.zig.isUnderscore(name);
        if (!valid) return .{ .index = index, .problem = .name_invalid };
        for (library_faces) |library| {
            if (std.mem.eql(u8, name, library)) {
                return .{ .index = index, .problem = .name_reserved };
            }
        }
        for (specs[0..index]) |before| {
            if (std.mem.eql(u8, name, before.name)) {
                return .{ .index = index, .problem = .name_duplicate };
            }
        }
        const ranges = spec.ranges orelse continue;
        if (ranges.len == 0) return .{ .index = index, .problem = .ranges_empty };
        for (ranges, 0..) |range, at| {
            if (range[0] > range[1]) return .{ .index = index, .problem = .ranges_reversed };
            if (at > 0 and range[0] <= ranges[at - 1][1]) {
                return .{ .index = index, .problem = .ranges_unordered };
            }
        }
    }
    return null;
}

/// The message `build.zig` panics with for `problem`.
pub fn problem_text(problem: FaceProblem) []const u8 {
    return switch (problem) {
        .too_many => "more than app_face_max (5) faces",
        .name_invalid => "the name must be a Zig identifier of at most 32 bytes, not `_`",
        .name_reserved => "the name is a library face's (sans, sans_bold, mono)",
        .name_duplicate => "the name is an earlier face's",
        .ranges_empty => "ranges is empty (pass null to use font_ranges)",
        .ranges_reversed => "a range ends before it starts",
        .ranges_unordered => "ranges must increase and must not overlap",
    };
}

/// Why `subset` refused (section 2b); `Scratch.detail` says more.
pub const Error = error{
    /// The file ends inside its table directory, or inside the table `detail.table` names.
    Truncated,
    /// The face has no `glyf` table: its outlines are CFF or CFF2, which the reader cannot
    /// draw.
    NoGlyf,
    /// The table `detail.table` names is not in the face.
    MissingTable,
    /// The face has no Unicode `cmap` subtable of format 12 or 4.
    NoUnicodeCmap,
    /// The table `detail.table` names holds an offset, a count, or a record it cannot.
    Malformed,
    /// The ranges keep `detail.glyphs` glyphs, more than `glyph_cap`.
    TooManyGlyphs,
    /// The ranges map more than `codepoint_cap` codepoints.
    TooManyCodepoints,
    /// A codepoint of the face's own ranges has no glyph (section 2a): `detail.codepoint` is
    /// the first, `detail.missing` the count.
    MissingGlyph,
    /// The output buffer is too small.
    NoSpace,
};

/// Whose ranges `subset` is given (section 2a).
pub const Claim = enum {
    /// The app's `font_ranges`, shared by faces that differ: a codepoint without a glyph is
    /// skipped.
    shared,
    /// The face's own `ranges`: every codepoint in them must have a glyph.
    own,
};

/// What explains a refusal (section 2b). Fields a refusal does not use are zero.
pub const Detail = struct {
    /// The table a `Truncated`, `MissingTable`, or `Malformed` is about; zeros when none.
    table: [4]u8,
    /// `TooManyGlyphs`: the glyphs the ranges keep, components included.
    glyphs: u32,
    /// `MissingGlyph`: the first codepoint without a glyph, and how many there are.
    codepoint: u21,
    missing: u32,

    pub const none: Detail = .{ .table = @splat(0), .glyphs = 0, .codepoint = 0, .missing = 0 };
};

/// Bytes `message` may write.
pub const message_max: u32 = 160;

/// The sentence `tools/subset.zig` prints after the file's name for `err` (section 2b), with
/// the number or table `detail` holds, written into `buffer`.
pub fn message(buffer: *[message_max]u8, err: Error, detail: *const Detail) []const u8 {
    if (err == error.TooManyGlyphs) assert(detail.glyphs > glyph_cap);
    if (err == error.MissingGlyph) assert(detail.missing >= 1);
    var count: [16]u8 = undefined;
    var cap: [16]u8 = undefined;
    const table: []const u8 = &detail.table;
    const has_table = detail.table[0] != 0;
    const text = switch (err) {
        error.Truncated => if (has_table)
            std.fmt.bufPrint(buffer, "the file ends inside its '{s}' table", .{table})
        else
            std.fmt.bufPrint(buffer, "the file ends inside its table directory", .{}),
        error.NoGlyf => std.fmt.bufPrint(
            buffer,
            "no glyf table; CFF outlines are not supported, use a TrueType (glyf) face",
            .{},
        ),
        error.MissingTable => std.fmt.bufPrint(buffer, "no '{s}' table", .{table}),
        error.NoUnicodeCmap => std.fmt.bufPrint(buffer, "no Unicode cmap of format 4 or 12", .{}),
        error.Malformed => std.fmt.bufPrint(buffer, "a malformed '{s}' table", .{table}),
        error.TooManyGlyphs => std.fmt.bufPrint(
            buffer,
            "the ranges keep {s} glyphs, and a subset keeps at most {s}: narrow the ranges",
            .{ grouped(&count, detail.glyphs), grouped(&cap, glyph_cap) },
        ),
        error.TooManyCodepoints => std.fmt.bufPrint(
            buffer,
            "the ranges map more than {s} codepoints",
            .{grouped(&cap, codepoint_cap)},
        ),
        error.MissingGlyph => if (detail.missing == 1) std.fmt.bufPrint(
            buffer,
            "U+{X:0>4} is in the face's own ranges and has no glyph",
            .{detail.codepoint},
        ) else std.fmt.bufPrint(
            buffer,
            "U+{X:0>4} is in the face's own ranges and has no glyph, nor do {s} more of them",
            .{ detail.codepoint, grouped(&count, detail.missing - 1) },
        ),
        error.NoSpace => std.fmt.bufPrint(buffer, "the subset is larger than its buffer", .{}),
    };
    return text catch unreachable;
}

/// Bytes of a file name `refusal` takes: Linux's `PATH_MAX`.
pub const path_max: u32 = 4096;
/// Bytes `refusal` may write.
pub const refusal_max: u32 = path_max + face_name_max + message_max + 32;

/// The line `tools/subset.zig` prints when `subset` refuses `path` (section 2b): the file, the
/// face when its own ranges were given (`Claim.own`), and `message`.
pub fn refusal(
    buffer: *[refusal_max]u8,
    path: []const u8,
    face: ?[]const u8,
    err: Error,
    detail: *const Detail,
) []const u8 {
    assert(path.len <= path_max);
    if (face) |name| assert(name.len <= face_name_max);
    var reason: [message_max]u8 = undefined;
    const text = message(&reason, err, detail);
    const line = if (face) |name|
        std.fmt.bufPrint(buffer, "subset: face '{s}' ({s}): {s}", .{ name, path, text })
    else
        std.fmt.bufPrint(buffer, "subset: {s}: {s}", .{ path, text });
    return line catch unreachable;
}

/// `value` in decimal with a comma every three digits: 5014 is "5,014".
fn grouped(buffer: *[16]u8, value: u32) []const u8 {
    var digits: [10]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    var len: u32 = 0;
    for (plain, 0..) |digit, index| {
        if (index > 0 and (plain.len - index) % 3 == 0) {
            buffer[len] = ',';
            len += 1;
        }
        buffer[len] = digit;
        len += 1;
    }
    assert(len <= buffer.len);
    assert(len >= plain.len);
    return buffer[0..len];
}

/// What `subset` kept: for the tool's report and the tests.
pub const Summary = struct {
    bytes: u32,
    glyphs: u32,
    codepoints: u32,
};

/// Fixed working storage, about 460 KiB: arrays by old id hold `source_glyph_cap`, arrays by
/// new id `glyph_cap`. Out-pointer use only.
pub const Scratch = struct {
    keep: [source_glyph_cap]bool,
    new_id: [source_glyph_cap]u16,
    worklist: [source_glyph_cap]u16,
    /// New `glyf` offsets per new id, and one past the last.
    offsets: [glyph_cap + 1]u32,
    /// `(codepoint, old glyph)` in codepoint order.
    pairs: [codepoint_cap][2]u32,
    /// What explains the last refusal (section 2b).
    detail: Detail,
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
    /// Offset of the Unicode subtable `collect` reads, and its format (12 or 4).
    cmap: u32,
    cmap_format: u16,
};

/// Writes the subset of `input` covering `ranges` into `out` (see the module guide). On a
/// refusal, `scratch.detail` explains it (section 2b).
pub fn subset(
    scratch: *Scratch,
    input: []const u8,
    ranges: []const Range,
    claim: Claim,
    out: []u8,
) Error!Summary {
    assert(ranges.len >= 1);
    for (ranges) |range| assert(range[0] <= range[1]);
    scratch.detail = .none;
    const face = try open(input, &scratch.detail);
    const codepoints = try collect(scratch, &face, ranges);
    if (claim == .own) try check_claim(scratch, ranges, codepoints);
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

fn open(input: []const u8, detail: *Detail) Error!Face {
    if (input.len < 12) return error.Truncated;
    const glyf = find(input, "glyf", detail) catch |err| switch (err) {
        error.MissingTable => return error.NoGlyf,
        else => return err,
    };
    const tables: Tables = .{
        .head = try find(input, "head", detail),
        .hhea = try find(input, "hhea", detail),
        .maxp = try find(input, "maxp", detail),
        .hmtx = try find(input, "hmtx", detail),
        .loca = try find(input, "loca", detail),
        .glyf = glyf,
        .cmap = try find(input, "cmap", detail),
    };
    if (tables.head.length < 54) return malformed(detail, "head");
    if (tables.hhea.length < 36) return malformed(detail, "hhea");
    if (tables.maxp.length < 6) return malformed(detail, "maxp");
    const glyph_count: u32 = read_u16(input, tables.maxp.offset + 4);
    const metric_count: u32 = read_u16(input, tables.hhea.offset + 34);
    if (glyph_count == 0) return malformed(detail, "maxp");
    assert(glyph_count <= source_glyph_cap);
    if (metric_count == 0 or metric_count > glyph_count) return malformed(detail, "hhea");
    if (4 * @as(u64, metric_count) + 2 * @as(u64, glyph_count - metric_count) >
        tables.hmtx.length) return malformed(detail, "hmtx");
    const loca_long = read_u16(input, tables.head.offset + 50) == 1;
    const loca_entry: u64 = if (loca_long) 4 else 2;
    if (loca_entry * (glyph_count + 1) > tables.loca.length) return malformed(detail, "loca");
    const map = find_cmap(input, tables.cmap) catch |err| {
        if (err == error.Malformed) detail.table = "cmap".*;
        return err;
    };
    return .{
        .bytes = input,
        .tables = tables,
        .glyph_count = glyph_count,
        .metric_count = metric_count,
        .loca_long = loca_long,
        .cmap = map.offset,
        .cmap_format = map.format,
    };
}

/// Records `tag` in `detail` and returns `error.Malformed`.
fn malformed(detail: *Detail, comptime tag: *const [4]u8) Error {
    detail.table = tag.*;
    return error.Malformed;
}

fn find(input: []const u8, comptime tag: *const [4]u8, detail: *Detail) Error!Slice {
    assert(input.len >= 12);
    const count: u32 = read_u16(input, 4);
    if (12 + 16 * count > input.len) return error.Truncated;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = 12 + 16 * index;
        if (!std.mem.eql(u8, input[record..][0..4], tag)) continue;
        const slice: Slice = .{
            .offset = read_u32(input, record + 8),
            .length = read_u32(input, record + 12),
        };
        if (@as(u64, slice.offset) + slice.length > input.len) {
            detail.table = tag.*;
            return error.Truncated;
        }
        return slice;
    }
    detail.table = tag.*;
    return error.MissingTable;
}

const Map = struct {
    offset: u32,
    format: u16,
};

/// The Unicode format 12 subtable, else the Unicode format 4 one (section 2).
fn find_cmap(input: []const u8, cmap: Slice) Error!Map {
    if (cmap.length < 4) return error.Malformed;
    const count: u32 = read_u16(input, cmap.offset + 2);
    if (4 + 8 * count > cmap.length) return error.Malformed;
    var found: ?Map = null;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = cmap.offset + 4 + 8 * index;
        const platform = read_u16(input, record);
        const encoding = read_u16(input, record + 2);
        const at = read_u32(input, record + 4);
        if (@as(u64, at) + 16 > cmap.length) return error.Malformed;
        const sub = cmap.offset + at;
        const format = read_u16(input, sub);
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (!unicode) continue;
        if (format == 12) return .{ .offset = sub, .format = 12 };
        if (format == 4 and found == null) found = .{ .offset = sub, .format = 4 };
    }
    return found orelse error.NoUnicodeCmap;
}

/// Records every `(codepoint, glyph)` in `ranges` in codepoint order and keeps the glyphs.
fn collect(scratch: *Scratch, face: *const Face, ranges: []const Range) Error!u32 {
    @memset(&scratch.keep, false);
    scratch.keep[0] = true;
    const collected = switch (face.cmap_format) {
        12 => collect12(scratch, face, ranges),
        4 => collect4(scratch, face, ranges),
        else => unreachable,
    };
    const count = collected catch |err| {
        if (err == error.Malformed) scratch.detail.table = "cmap".*;
        return err;
    };
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

/// `collect` over the sequential map groups `(start, end, first_glyph)` of format 12.
fn collect12(scratch: *Scratch, face: *const Face, ranges: []const Range) Error!u32 {
    const bytes = face.bytes;
    const groups = read_u32(bytes, face.cmap + 12);
    if (face.cmap + 16 + @as(u64, groups) * 12 > bytes.len) return error.Malformed;
    var count: u32 = 0;
    var group: u32 = 0;
    while (group < groups) : (group += 1) {
        const at = face.cmap + 16 + 12 * group;
        const start = read_u32(bytes, at);
        const end = read_u32(bytes, at + 4);
        const first = read_u32(bytes, at + 8);
        if (end < start or end > 0x10FFFF) return error.Malformed;
        for (ranges) |range| {
            const low = @max(start, range[0]);
            const high = @min(end, range[1]);
            if (low > high) continue;
            var codepoint = low;
            while (codepoint <= high) : (codepoint += 1) {
                const glyph = first + (codepoint - start);
                try keep_pair(scratch, face, &count, codepoint, glyph);
            }
        }
    }
    assert(count <= codepoint_cap);
    return count;
}

/// `collect` over the segments `(end, start, delta, range_offset)` of format 4: a glyph is
/// `codepoint + delta`, or, with a range offset, the glyph id array's entry plus `delta`
/// (mod 65536), as `text/ttf.zig` reads it.
fn collect4(scratch: *Scratch, face: *const Face, ranges: []const Range) Error!u32 {
    const bytes = face.bytes;
    const segments: u32 = read_u16(bytes, face.cmap + 6) / 2;
    const ends = face.cmap + 14;
    const starts = ends + 2 * segments + 2;
    const deltas = starts + 2 * segments;
    const offsets = deltas + 2 * segments;
    if (offsets + 2 * segments > bytes.len) return error.Malformed;
    var count: u32 = 0;
    var segment: u32 = 0;
    while (segment < segments) : (segment += 1) {
        const start: u32 = read_u16(bytes, starts + 2 * segment);
        const end: u32 = read_u16(bytes, ends + 2 * segment);
        const delta = read_u16(bytes, deltas + 2 * segment);
        const range_offset: u32 = read_u16(bytes, offsets + 2 * segment);
        if (end < start) return error.Malformed;
        for (ranges) |range| {
            const low = @max(start, range[0]);
            const high = @min(end, range[1]);
            if (low > high) continue;
            var codepoint = low;
            while (codepoint <= high) : (codepoint += 1) {
                var id: u16 = @intCast(codepoint);
                if (range_offset != 0) {
                    const at = offsets + 2 * segment + range_offset + 2 * (codepoint - start);
                    if (at + 2 > bytes.len) return error.Malformed;
                    id = read_u16(bytes, at);
                    if (id == 0) continue;
                }
                try keep_pair(scratch, face, &count, codepoint, id +% delta);
            }
        }
    }
    assert(count <= codepoint_cap);
    return count;
}

/// Refuses with `MissingGlyph` when a codepoint of `ranges` is not among the `codepoints`
/// pairs `collect` recorded (section 2a), naming the first and counting them all.
fn check_claim(scratch: *Scratch, ranges: []const Range, codepoints: u32) Error!void {
    assert(ranges.len >= 1);
    assert(codepoints <= codepoint_cap);
    const pairs = scratch.pairs[0..codepoints];
    var missing: u32 = 0;
    var first: u21 = 0;
    for (ranges) |range| {
        var codepoint: u32 = range[0];
        while (codepoint <= range[1]) : (codepoint += 1) {
            if (has_pair(pairs, codepoint)) continue;
            if (missing == 0) first = @intCast(codepoint);
            missing += 1;
        }
    }
    if (missing == 0) return;
    scratch.detail.codepoint = first;
    scratch.detail.missing = missing;
    return error.MissingGlyph;
}

/// True when the codepoint-ordered `pairs` hold `codepoint`: a binary search, at most 15
/// steps over `codepoint_cap` pairs.
fn has_pair(pairs: []const [2]u32, codepoint: u32) bool {
    assert(pairs.len <= codepoint_cap);
    var low: usize = 0;
    var high: usize = pairs.len;
    var steps: u32 = 0;
    while (low < high) : (steps += 1) {
        assert(steps <= 15);
        const middle = low + (high - low) / 2;
        if (pairs[middle][0] == codepoint) return true;
        if (pairs[middle][0] < codepoint) low = middle + 1 else high = middle;
    }
    return false;
}

/// Records `(codepoint, glyph)` and keeps the glyph; glyph 0 and ids past the face are
/// unmapped.
fn keep_pair(
    scratch: *Scratch,
    face: *const Face,
    count: *u32,
    codepoint: u32,
    glyph: u32,
) Error!void {
    if (glyph == 0 or glyph >= face.glyph_count) return;
    if (count.* == codepoint_cap) return error.TooManyCodepoints;
    scratch.pairs[count.*] = .{ codepoint, glyph };
    scratch.keep[glyph] = true;
    count.* += 1;
}

/// Closes the kept set over composite components (section 2), assigns new ids, and returns
/// the kept count; more than `glyph_cap` is `TooManyGlyphs`, with the count.
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
        const count = components_of(face, glyph, &components) catch |err| {
            return glyf_error(&scratch.detail, err);
        };
        for (components[0..count]) |child| {
            if (child >= face.glyph_count) return malformed(&scratch.detail, "glyf");
            if (scratch.keep[child]) continue;
            scratch.keep[child] = true;
            assert(pending < source_glyph_cap);
            scratch.worklist[pending] = child;
            pending += 1;
        }
    }
    var next: u32 = 0;
    for (scratch.keep[0..face.glyph_count], 0..) |kept, glyph| {
        if (!kept) continue;
        scratch.new_id[glyph] = @intCast(next);
        next += 1;
    }
    assert(scratch.new_id[0] == 0);
    assert(next >= 1);
    assert(next <= face.glyph_count);
    if (next > glyph_cap) {
        scratch.detail.glyphs = next;
        return error.TooManyGlyphs;
    }
    return next;
}

/// Records the table a `Malformed` from a glyph's bytes is about: `loca` or `glyf`.
fn glyf_error(detail: *Detail, err: Error) Error {
    if (err == error.Malformed and detail.table[0] == 0) detail.table = "glyf".*;
    return err;
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
    if (bounds.end < bounds.start or bounds.end > face.tables.glyf.length) {
        return error.Malformed;
    }
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
        if (count == component_cap) return error.Malformed;
        if (cursor + 4 > face.tables.glyf.offset + bounds.end) return error.Malformed;
        const flags = read_u16(bytes, cursor);
        out[count] = read_u16(bytes, cursor + 2);
        count += 1;
        cursor += component_bytes(flags);
        if (cursor > face.tables.glyf.offset + bounds.end) return error.Malformed;
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
        copy_glyph(writer, scratch, face, @intCast(glyph)) catch |err| {
            return glyf_error(&scratch.detail, err);
        };
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
    if (end - at < 10) return error.Malformed;
    const contours = read_i16(bytes, at);
    try writer.bytes(bytes[at..][0..10]);
    if (contours >= 0) {
        const ends_bytes = 2 * @as(u32, @intCast(contours));
        const instructions = at + 10 + ends_bytes;
        if (instructions + 2 > end) return error.Malformed;
        try writer.bytes(bytes[at + 10 ..][0..ends_bytes]);
        try writer.u16be(0);
        const rest = instructions + 2 + read_u16(bytes, instructions);
        if (rest > end) return error.Malformed;
        try writer.bytes(bytes[rest..end]);
        return;
    }
    var cursor = at + 10;
    var count: u32 = 0;
    while (true) : (count += 1) {
        if (count == component_cap) return error.Malformed;
        const flags = read_u16(bytes, cursor);
        const size = component_bytes(flags);
        if (cursor + size > end) return error.Malformed;
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
    // `maxp.numGlyphs` is 16 bits, so every face fits the arrays by old id.
    assert(source_glyph_cap == std.math.maxInt(u16));
    assert(glyph_cap < source_glyph_cap);
    assert(@sizeOf(Scratch) < 480 * 1024);
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
    var pairs: [codepoint_cap][2]u32 = undefined;
};

// Locks the subset against the full faces (sections 2 and 3): for every codepoint of the
// default ranges, the subset maps a glyph exactly when the full face does, with the same
// advance and the same decoded outline (points, on-curve flags, contour ends), so text draws
// the same; a codepoint outside the ranges (U+0416) maps to .notdef, which still loads.
test "the default subset draws every kept codepoint as the full face does" {
    inline for (full_faces) |bytes| {
        const full = comptime ttf.parse(bytes);
        const summary = try subset(&fixture.scratch, bytes, &default_ranges, .shared, &fixture.out);
        const sub = ttf.read(fixture.out[0..summary.bytes]);
        try testing.expect(summary.glyphs < 400);
        try testing.expectEqual(summary.glyphs, sub.glyph_count);
        try testing.expectEqual(full.units_per_em, sub.units_per_em);
        try testing.expectEqual(full.ascent, sub.ascent);
        try testing.expectEqual(full.descent, sub.descent);
        try testing.expectEqual(full.line_gap, sub.line_gap);
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
    const summary = try subset(&fixture.scratch, bytes, &default_ranges, .shared, &fixture.out);
    const again = try subset(&fixture.scratch, bytes, &default_ranges, .shared, &fixture.again);
    try testing.expectEqualSlices(u8, fixture.out[0..summary.bytes], fixture.again[0..again.bytes]);
    const output = fixture.out[0..summary.bytes];
    const sub = ttf.read(output);
    const face = try open(output, &fixture.scratch.detail);
    var components: [component_cap]u16 = undefined;
    const count = try components_of(&face, ttf.glyph_id(&sub, 0xE9), &components);
    try testing.expect(count >= 2);
    for (components[0..count]) |child| try testing.expect(child < summary.glyphs);
    try testing.expectEqual(@as(u16, table_count), read_u16(output, 4));
    try testing.expectEqual(@as(u32, 0), checksum(output) -% 0xB1B0AFBA);
    var short: [1024]u8 = undefined;
    const refused = subset(&fixture.scratch, bytes, &default_ranges, .shared, &short);
    try testing.expectError(error.NoSpace, refused);
}

// Locks the app face check (section 4): a valid list passes; each problem is found at the face
// that has it, the first problem first; null ranges skip the range checks.
test "check_faces refuses each bad face list" {
    const icons: []const Range = &.{ .{ 0xE000, 0xE010 }, .{ 0xE100, 0xE100 } };
    try testing.expectEqual(@as(?FaceError, null), check_faces(&.{
        .{ .name = "icons", .ranges = icons },
        .{ .name = "display_2", .ranges = null },
    }));
    try testing.expectEqual(@as(?FaceError, null), check_faces(&.{}));
    const six: [6]FaceSpec = @splat(.{ .name = "a", .ranges = null });
    const cases = [_]struct { specs: []const FaceSpec, index: u32, problem: FaceProblem }{
        .{ .specs = &six, .index = 5, .problem = .too_many },
        .{ .specs = &.{.{ .name = "2d", .ranges = null }}, .index = 0, .problem = .name_invalid },
        .{ .specs = &.{.{ .name = "_", .ranges = null }}, .index = 0, .problem = .name_invalid },
        .{ .specs = &.{.{ .name = "enum", .ranges = null }}, .index = 0, .problem = .name_invalid },
        .{ .specs = &.{.{ .name = "", .ranges = null }}, .index = 0, .problem = .name_invalid },
        .{
            .specs = &.{.{ .name = "sans_bold", .ranges = null }},
            .index = 0,
            .problem = .name_reserved,
        },
        .{
            .specs = &.{ .{ .name = "a", .ranges = null }, .{ .name = "a", .ranges = null } },
            .index = 1,
            .problem = .name_duplicate,
        },
        .{ .specs = &.{.{ .name = "a", .ranges = &.{} }}, .index = 0, .problem = .ranges_empty },
        .{
            .specs = &.{.{ .name = "a", .ranges = &.{.{ 9, 8 }} }},
            .index = 0,
            .problem = .ranges_reversed,
        },
        .{
            .specs = &.{.{ .name = "a", .ranges = &.{ .{ 1, 8 }, .{ 8, 9 } } }},
            .index = 0,
            .problem = .ranges_unordered,
        },
    };
    for (cases) |case| {
        const found = check_faces(case.specs).?;
        try testing.expectEqual(case.index, found.index);
        try testing.expectEqual(case.problem, found.problem);
        try testing.expect(problem_text(found.problem).len > 0);
    }
}

// Locks the outline check (sections 2 and 2b): a face without a `glyf` table is refused as
// `NoGlyf` before anything else is read, not as a malformed face, and the tool's line keeps the
// words it had before step 57.
test "a face without glyf is refused by name" {
    var bytes: [4096]u8 = undefined;
    @memcpy(bytes[0..], full_faces[0][0..4096]);
    // Rename the `glyf` directory entry, as a CFF face has no such entry.
    const count = read_u16(&bytes, 4);
    var index: u32 = 0;
    var renamed = false;
    while (index < count) : (index += 1) {
        const record = 12 + 16 * index;
        if (std.mem.eql(u8, bytes[record..][0..4], "glyf")) {
            @memcpy(bytes[record..][0..4], "CFF ");
            renamed = true;
        }
    }
    try testing.expect(renamed);
    const refused = subset(&fixture.scratch, &bytes, &default_ranges, .shared, &fixture.out);
    try testing.expectError(error.NoGlyf, refused);
    try expect_refusal(error.NoGlyf, null, "subset: a.otf: no glyf table; CFF outlines are not " ++
        "supported, use a TrueType (glyf) face");
}

// Locks the format 4 input (section 2): the full Noto Sans read through its format 4 subtable
// collects the same (codepoint, glyph) pairs of the default ranges as through its format 12 one.
test "a format 4 cmap collects as format 12 does" {
    var face = try open(full_faces[0], &fixture.scratch.detail);
    try testing.expectEqual(@as(u16, 12), face.cmap_format);
    const count12 = try collect(&fixture.scratch, &face, &default_ranges);
    try testing.expect(count12 > 300);
    @memcpy(fixture.pairs[0..count12], fixture.scratch.pairs[0..count12]);
    const bytes = face.bytes;
    const cmap = face.tables.cmap.offset;
    const tables: u32 = read_u16(bytes, cmap + 2);
    var index: u32 = 0;
    while (index < tables) : (index += 1) {
        const sub = cmap + read_u32(bytes, cmap + 4 + 8 * index + 4);
        if (read_u16(bytes, sub) == 4) face.cmap = sub;
    }
    face.cmap_format = 4;
    const count4 = try collect(&fixture.scratch, &face, &default_ranges);
    try testing.expectEqual(count12, count4);
    const pairs4 = fixture.scratch.pairs[0..count4];
    try testing.expectEqualSlices([2]u32, fixture.pairs[0..count12], pairs4);
}

/// Checks that the last refusal was `err` and that the tool's line for the file `a.otf` reads
/// `want`.
fn expect_refusal(err: Error, face: ?[]const u8, comptime want: []const u8) !void {
    var buffer: [refusal_max]u8 = undefined;
    const line = refusal(&buffer, "a.otf", face, err, &fixture.scratch.detail);
    try testing.expectEqualStrings(want, line);
}

// Locks the refusals of a cut file (section 2b): Noto Sans cut to its first 40 bytes ends
// inside its table directory (17 records of 16 bytes); cut to 4 KiB the directory is whole and
// the first table looked up, `glyf`, runs past the end; each line says which.
test "a truncated face is refused naming where it ends" {
    const bytes = full_faces[0];
    const scratch = &fixture.scratch;
    const out = &fixture.out;
    const ranges = &default_ranges;
    try testing.expectEqual(@as(u16, 17), read_u16(bytes, 4));
    const directory = subset(scratch, bytes[0..40], ranges, .shared, out);
    try testing.expectError(error.Truncated, directory);
    try expect_refusal(error.Truncated, null, "subset: a.otf: the file ends inside its " ++
        "table directory");
    const table = subset(scratch, bytes[0..4096], ranges, .shared, out);
    try testing.expectError(error.Truncated, table);
    try expect_refusal(error.Truncated, null, "subset: a.otf: the file ends inside its " ++
        "'glyf' table");
    var buffer: [message_max]u8 = undefined;
    fixture.scratch.detail = .none;
    const cases = [_]struct { err: Error, want: []const u8 }{
        .{ .err = error.NoUnicodeCmap, .want = "no Unicode cmap of format 4 or 12" },
        .{ .err = error.TooManyCodepoints, .want = "the ranges map more than 16,384 codepoints" },
        .{ .err = error.NoSpace, .want = "the subset is larger than its buffer" },
    };
    for (cases) |case| {
        const text = message(&buffer, case.err, &fixture.scratch.detail);
        try testing.expectEqualStrings(case.want, text);
    }
}

// Locks a face's own ranges as a claim (section 2a): Noto Sans has no arrows, so its own range
// U+2190 to U+2193 is refused at U+2190 with three more missing, and the line names the face;
// the same range shared keeps nothing but `.notdef`; an own range it holds (A to Z) subsets.
test "a face's own range that names a codepoint without a glyph is refused" {
    const bytes = full_faces[0];
    const arrows = [_]Range{.{ 0x2190, 0x2193 }};
    const refused = subset(&fixture.scratch, bytes, &arrows, .own, &fixture.out);
    try testing.expectError(error.MissingGlyph, refused);
    try testing.expectEqual(@as(u21, 0x2190), fixture.scratch.detail.codepoint);
    try testing.expectEqual(@as(u32, 4), fixture.scratch.detail.missing);
    try expect_refusal(error.MissingGlyph, "arrows", "subset: face 'arrows' (a.otf): U+2190 is " ++
        "in the face's own ranges and has no glyph, nor do 3 more of them");
    const one = [_]Range{ .{ 0x41, 0x5A }, .{ 0x2192, 0x2192 } };
    const typo = subset(&fixture.scratch, bytes, &one, .own, &fixture.out);
    try testing.expectError(error.MissingGlyph, typo);
    try expect_refusal(error.MissingGlyph, "arrows", "subset: face 'arrows' (a.otf): U+2192 is " ++
        "in the face's own ranges and has no glyph");
    const shared = try subset(&fixture.scratch, bytes, &arrows, .shared, &fixture.out);
    try testing.expectEqual(@as(u32, 1), shared.glyphs);
    try testing.expectEqual(@as(u32, 0), shared.codepoints);
    const letters = [_]Range{.{ 0x41, 0x5A }};
    const own = try subset(&fixture.scratch, bytes, &letters, .own, &fixture.out);
    try testing.expectEqual(@as(u32, 26), own.codepoints);
}

/// A face of more than `glyph_cap` glyphs, built at run time (no such face is in the
/// repository): `glyph_count` glyphs, glyph `g` mapped from `first_codepoint + g - 1` by one
/// format 12 group, every advance `500 + 10 * (g % 7)`. Only `.notdef`, the `simple` glyphs,
/// and `composite` (`component` moved by (120, -30)) have outlines, three points each, with
/// two bytes of instructions the subset drops; every other glyph is empty, so the face is
/// about 26 KB: 16.8 KB of `hmtx` and 8.4 KB of short `loca`.
const large = struct {
    const glyph_count: u32 = 4200;
    const first_codepoint: u21 = 0x10000;
    const simple = [_]u16{ 0, 4151, 4153, 4190 };
    const composite: u16 = 4180;
    const component: u16 = 4190;
    var bytes: [32 * 1024]u8 = undefined;

    fn codepoint(glyph: u16) u21 {
        assert(glyph >= 1);
        return first_codepoint + glyph - 1;
    }

    /// Builds the face into `bytes`; returns it and its reader record, made by hand because
    /// `ttf.read` refuses a face over `ttf.glyph_cap`.
    fn build() struct { bytes: []const u8, font: ttf.Font } {
        @memset(&bytes, 0);
        var at: u32 = directory_bytes;
        var records: [table_count]Record = undefined;
        // cmap: one (3, 10) record, one format 12 subtable of one group.
        const cmap = at;
        put16(cmap + 2, 1);
        put16(cmap + 4, 3);
        put16(cmap + 6, 10);
        put32(cmap + 8, 12);
        put16(cmap + 12, 12);
        put32(cmap + 16, 28);
        put32(cmap + 24, 1);
        put32(cmap + 28, first_codepoint);
        put32(cmap + 32, codepoint(glyph_count - 1));
        put32(cmap + 36, 1);
        at = record(&records[0], "cmap", cmap, 40);
        // glyf, with the loca offsets kept for later.
        const glyf = at;
        var offsets: [glyph_count + 1]u32 = undefined;
        var glyph: u32 = 0;
        while (glyph < glyph_count) : (glyph += 1) {
            offsets[glyph] = at - glyf;
            if (glyph == composite) {
                put16(at, 0xFFFF); // numberOfContours -1
                put16(at + 10, 0x0003); // arguments are words, and x and y offsets
                put16(at + 12, component);
                put16(at + 14, 120);
                put16(at + 16, @bitCast(@as(i16, -30)));
                at += 18;
            } else if (std.mem.indexOfScalar(u16, &simple, @intCast(glyph)) != null) {
                const shape: u16 = @intCast(glyph % 37);
                put16(at, 1); // one contour, ending at point 2
                put16(at + 10, 2);
                put16(at + 12, 2); // two bytes of instructions
                bytes[at + 14] = 0xB0;
                bytes[at + 15] = 0x01;
                @memset(bytes[at + 16 ..][0..3], 0x01); // on curve, 16-bit deltas
                put16(at + 19, 10 + shape);
                put16(at + 21, 90);
                put16(at + 23, @bitCast(@as(i16, -50)));
                put16(at + 25, 0);
                put16(at + 27, 0);
                put16(at + 29, 100 + shape);
                at += 32; // 31 bytes, padded to 2
            }
        }
        offsets[glyph_count] = at - glyf;
        at = record(&records[1], "glyf", glyf, at - glyf);
        const head = at;
        put32(head, 0x00010000);
        put32(head + 12, 0x5F0F3CF5);
        put16(head + 18, 1000);
        at = record(&records[2], "head", head, 54);
        const hhea = at;
        put32(hhea, 0x00010000);
        put16(hhea + 4, 800);
        put16(hhea + 6, @bitCast(@as(i16, -200)));
        put16(hhea + 34, glyph_count);
        at = record(&records[3], "hhea", hhea, 36);
        const hmtx = at;
        glyph = 0;
        while (glyph < glyph_count) : (glyph += 1) {
            put16(hmtx + 4 * glyph, @intCast(500 + 10 * (glyph % 7)));
            put16(hmtx + 4 * glyph + 2, @intCast(glyph % 5));
        }
        at = record(&records[4], "hmtx", hmtx, 4 * glyph_count);
        const loca = at;
        for (offsets, 0..) |offset, index| {
            put16(loca + 2 * @as(u32, @intCast(index)), @intCast(offset / 2));
        }
        at = record(&records[5], "loca", loca, 2 * (glyph_count + 1));
        const maxp = at;
        put32(maxp, 0x00005000);
        put16(maxp + 4, glyph_count);
        at = record(&records[6], "maxp", maxp, 6);
        write_directory(&bytes, &records);
        assert(at <= bytes.len);
        return .{ .bytes = bytes[0..at], .font = .{
            .bytes = bytes[0..at],
            .units_per_em = 1000,
            .ascent = 800,
            .descent = 200,
            .line_gap = 0,
            .glyph_count = glyph_count,
            .metric_count = glyph_count,
            .hmtx = hmtx,
            .loca = loca,
            .loca_long = false,
            .glyf = glyf,
            .cmap = cmap + 12,
            .cmap_format = 12,
            .ascii = @splat(0),
        } };
    }

    /// Fills `out` for the table at `offset` of `length` bytes; returns the next 4-byte offset.
    fn record(out: *Record, comptime tag: *const [4]u8, offset: u32, length: u32) u32 {
        out.* = .{ .tag = tag.*, .checksum = 0, .offset = offset, .length = length };
        return std.mem.alignForward(u32, offset + length, 4);
    }

    fn put16(at: u32, value: u16) void {
        std.mem.writeInt(u16, bytes[at..][0..2], value, .big);
    }

    fn put32(at: u32, value: u32) void {
        std.mem.writeInt(u32, bytes[at..][0..4], value, .big);
    }
};

// Locks cutting from a face of any size (section 2): from the 4,200-glyph face, the ranges of
// glyphs 4151 to 4153 and the composite 4180 keep six glyphs (.notdef, the three, the composite,
// and its unmapped component 4190); each kept codepoint has the full face's advance and outline,
// the composite's flattened with its (120, -30) offset; the face is about 26 KB.
test "a face of more than 4,096 glyphs subsets to a few" {
    const full = large.build();
    try testing.expect(full.bytes.len > 25_000 and full.bytes.len < 27_000);
    try testing.expect(large.glyph_count > glyph_cap);
    const ranges = [_]Range{
        .{ large.codepoint(4151), large.codepoint(4153) },
        .{ large.codepoint(large.composite), large.codepoint(large.composite) },
    };
    const summary = try subset(&fixture.scratch, full.bytes, &ranges, .own, &fixture.out);
    try testing.expectEqual(@as(u32, 6), summary.glyphs);
    try testing.expectEqual(@as(u32, 4), summary.codepoints);
    const sub = ttf.read(fixture.out[0..summary.bytes]);
    try testing.expectEqual(@as(u32, 6), sub.glyph_count);
    for (ranges) |range| {
        var codepoint: u21 = range[0];
        while (codepoint <= range[1]) : (codepoint += 1) {
            const old = ttf.glyph_id(&full.font, codepoint);
            const new = ttf.glyph_id(&sub, codepoint);
            try testing.expect(old != 0 and new != 0);
            try testing.expectEqual(ttf.advance(&full.font, old), ttf.advance(&sub, new));
            try expect_same_outline(&full.font, old, &sub, new);
        }
    }
    const placed = ttf.load(&sub, ttf.glyph_id(&sub, large.codepoint(large.composite)), &fixture.b);
    try testing.expectEqual(ttf.Load.ready, placed);
    try testing.expectEqual(@as(f32, 120 + 10 + 4190 % 37), fixture.b.x[0]);
    try testing.expectEqual(@as(f32, -30), fixture.b.y[0]);
    try expect_same_outline(&full.font, 0, &sub, 0);
}

// Locks the cap on what is kept (sections 2 and 2b): every codepoint of the 4,200-glyph face
// keeps all 4,200 glyphs, over the 4,096 a subset may keep, and the line gives the count.
test "a subset that keeps more than 4,096 glyphs is refused with the count" {
    const full = large.build();
    const everything = [_]Range{.{ large.first_codepoint, large.codepoint(large.glyph_count - 1) }};
    const refused = subset(&fixture.scratch, full.bytes, &everything, .shared, &fixture.out);
    try testing.expectError(error.TooManyGlyphs, refused);
    try testing.expectEqual(@as(u32, 4200), fixture.scratch.detail.glyphs);
    try expect_refusal(error.TooManyGlyphs, null, "subset: a.otf: the ranges keep 4,200 glyphs, " ++
        "and a subset keeps at most 4,096: narrow the ranges");
}

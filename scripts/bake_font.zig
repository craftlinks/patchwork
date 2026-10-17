//! Offline TrueType Font Baker: Quadratic Bézier Decomposition, Supersampled Coverage,
//! 2D Shelf Packing, and Pre-Scaled Binary Serialization.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! Real-time GPU rendering engines cannot afford to parse TrueType vector outlines on the critical
//! animation frame path. A traditional runtime font pipeline (such as FreeType, DirectWrite, or
//! CoreText) incurs severe drawbacks:
//! - **Unbounded CPU Latency & Micro-Stutter:** Parsing complex binary font tables (`cmap`, `loca`,
//!   `glyf`), performing quadratic Bézier curve flattening, and computing fractional pixel coverage
//!   burns milliseconds of CPU time per frame when new characters appear.
//! - **Memory Churn & Dynamic Allocation:** Dynamic glyph atlas allocators fragment the heap and
//!   require complex cache invalidation, atlas repackaging, and dynamic texture uploads.
//! - **Target Portability:** On freestanding targets (such as `wasm32-freestanding`), shipping
//!   a full font rendering engine increases binary size by hundreds of kilobytes and introduces
//!   OS font dependencies.
//!
//! **Patchwork's Ahead-of-Time Pre-Baking Solution:**
//! - This script executes **offline** during development (or when updating the font asset).
//! - It reads `assets/NotoSans-Regular.ttf` once, extracts ASCII (U+0020..U+007E, 95 glyphs),
//!   rasterizes each glyph into a 512 x 256 alpha coverage atlas (`font_atlas.bin`),
//!   and emits pre-scaled metrics in UI logical pixels (`font_metrics.bin`).
//! - The frame path consumes these static binaries via `@embedFile`, achieving 100% deterministic
//!   layout, zero runtime allocation, and zero frame-time rasterization overhead.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! - **Font Design Space (FUnits):** Integer Cartesian coordinate system specified in the TrueType
//!   `head` table (`unitsPerEm = 1000`). Origin `(0, 0)` is on baseline, and `+Y` points upwards.
//! - **Bake Pixel Space:** Rasterizer pixel grid at 32 px per em.
//!   Scale factor:
//!   ```text
//!   scale = ppem / units_per_em = 32.0 / 1000.0 = 0.032
//!   ```
//!   Flipped to Y-down to align directly with screen and texture coordinates:
//!   ```text
//!   top_y = ceil(yMax * scale)
//!   py = top_y - y * scale
//!   ```
//! - **UI Logical Screen Space:** Target display coordinate system at 16 px logical size.
//!   Because bake space is 32 px, logical values are exactly half the baked pixel values:
//!   ```text
//!   logical_value = bake_pixel_value / 2.0
//!   ```
//!
//! ### TrueType Quadratic Bézier Decomposition:
//! TrueType contours consist of straight line segments and 2nd-degree quadratic Bézier curves.
//! A quadratic Bézier curve is parameterized by control points `P0` (on-curve), `P1` (off-curve),
//! and `P2` (on-curve) for parameter `t in [0.0, 1.0]`:
//! ```text
//! B(t) = (1 - t)^2 * P0 + 2 * (1 - t) * t * P1 + t^2 * P2
//! ```
//! In `flatten_contour`, curves are subdivided into 8 linear chord segments (`t = step / 8.0`
//! for `step = 1..8`).
//!
//! **Consecutive Off-Curve Midpoint Rule:**
//! TrueType specifications permit consecutive off-curve points `P_a` and `P_b`. The specification
//! mandates an implicit on-curve midpoint `P_mid` positioned exactly halfway between them:
//! ```text
//! P_mid = (P_a + P_b) * 0.5
//! ```
//! `expand_contour` detects consecutive off-curve points and inserts explicit on-curve midpoints,
//! transforming the outline into a canonical alternating sequence of on and off-curve vertices.
//!
//! ### 4x4 Sub-Pixel Supersampled Coverage Rasterization:
//! To produce crisp, antialiased alpha coverage without analytical ray-marching or distance fields,
//! `rasterize` evaluates fractional pixel occupancy using a uniform 4x4 sub-pixel grid:
//! - For each integer pixel `(px, py)` within the glyph bounding box:
//!   - 16 sample rays are cast horizontally from sub-pixel coordinates:
//!     ```text
//!     sample_x = px + (sx + 0.5) / 4.0   for sx = 0..3
//!     sample_y = py + (sy + 0.5) / 4.0   for sy = 0..3
//!     ```
//!   - For each sample, the **Non-Zero Winding Rule** is evaluated against all contour edges:
//!     ```text
//!     winding = sum( edge_wind(edge, sample_x, sample_y) )
//!     inside = (winding != 0)
//!     ```
//!   - An edge crossing upwards contributes `+1`; an edge crossing downwards contributes `-1`.
//!   - Total sub-pixel hits `hits in [0, 16]` are quantized to an 8-bit unsigned integer:
//!     ```text
//!     coverage = (hits * 255) / 16
//!     ```
//!
//! ### 2D Shelf Packing Algorithm:
//! 94 ink glyphs are packed into the 512 x 256 atlas using a shelf-first bin packing heuristic:
//! - Shelf state: `(shelf_x, shelf_y, shelf_h)`.
//! - A 1-texel gutter separates glyphs horizontally and vertically to prevent bilinear bleed.
//! - When a glyph of dimension `(gw, gh)` fits horizontally (`shelf_x + gw <= 512`):
//!   It is placed at `(shelf_x, shelf_y)`, `shelf_x += gw + 1`, and `shelf_h = max(shelf_h, gh)`.
//! - When it exceeds 512, a new shelf is opened:
//!   `shelf_x = 0`, `shelf_y += shelf_h + 1`, `shelf_h = 0`.
//!
//! ### Half-Texel UV Inset Derivation:
//! To guarantee that bilinear texture filtering never samples outside the dedicated texel bounds:
//! ```text
//! u0 = (atlas_x + 0.5) / 512.0
//! v0 = (atlas_y + 0.5) / 256.0
//! u1 = (atlas_x + glyph_w - 0.5) / 512.0
//! v1 = (atlas_y + glyph_h - 0.5) / 256.0
//! ```
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### `src/font_atlas.bin` Layout:
//! - Dimensions: 512 x 256 texels.
//! - Format: Single-channel `r8unorm` (1 byte per texel).
//! - Total size: `512 * 256 = 131,072` bytes.
//! - Row Stride: 512 bytes (`bytesPerRow = 512`), which is an exact multiple of the WebGPU
//!   256-byte alignment requirement (`512 = 2 * 256`).
//!
//! ### `src/font_metrics.bin` Binary ABI (3,832 Bytes):
//! Formatted as little-endian binary data:
//! - **Header (32 Bytes):**
//!   `atlas_width` (u32), `atlas_height` (u32), `glyph_count` (95), `codepoint_first` (32),
//!   `ascent` (f32), `descent` (f32), `line_height` (f32), `pad` (u32 = 0).
//! - **95 Records (40 Bytes Each):**
//!   `advance` (f32), `left` (f32), `top` (f32), `width` (f32), `height` (f32),
//!   `u0` (f32), `v0` (f32), `u1` (f32), `v1` (f32), `pad` (u32 = 0).
//!
//! ## 4. State Machines & Data Flow
//!
//! ```text
//! [assets/NotoSans-Regular.ttf]
//!       │
//!       ▼
//! [load_font_tables()] ──► cmap (format 4), head, hhea, hmtx, maxp, loca, glyf
//!       │
//!       ▼
//! [bake_codepoint(32..126)]
//!       ├─► [read_points()]     (Parses TrueType simple glyph contours and flags)
//!       ├─► [expand_contour()]  (Inserts implicit on-curve midpoints)
//!       ├─► [flatten_contour()] (Decomposes quadratic Béziers into 8 linear chords)
//!       ├─► [rasterize()]       (Evaluates 4x4 supersampled non-zero winding coverage)
//!       ├─► [pack_shelf()]      (Allocates 2D slot in 512x256 atlas with 1px gutter)
//!       └─► [blit()]            (Copies 8-bit coverage into global atlas buffer)
//!       │
//!       ▼
//! [write_outputs()]
//!       ├─► src/font_atlas.bin   (131,072 bytes)
//!       ├─► src/font_metrics.bin (3,832 bytes)
//!       └─► assets/OFL.txt       (SIL Open Font License text from name table)
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **TrueType Big-Endian Parsing:** TrueType fonts use big-endian integer encoding.
//!   Helpers `read_u16`, `read_i16`, and `read_u32` decode network-order integers to host integers.
//! - **OFL Extraction:** Decodes platform 3 (Windows) UTF-16BE name table entries (IDs 0 and 13)
//!   and transcodes them to standard UTF-8 text for `assets/OFL.txt`.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Memory Bounds:**
//!   `file_cap = 1048576` (1 MB max TTF file size).
//!   `point_cap = 256`, `contour_cap = 32`, `segment_cap = 2048`, `bitmap_cap = 64`.
//! - **Zero Runtime Allocation:** All scratch arrays (`file_bytes`, `points`, `edges`, `bitmap`)
//!   are statically allocated global arrays in BSS memory. Zero heap allocation.
//! - **Defensive Bounds Verification:** All loops bound to fixed caps; all buffer bounds asserted.

const std = @import("std");
const assert = std.debug.assert;

const file_cap: u32 = 1024 * 1024;
const point_cap: u32 = 256;
const contour_cap: u32 = 32;
const segment_cap: u32 = point_cap * 8;
const edge_cap: u32 = segment_cap;
const bitmap_cap: u32 = 64;
const table_cap: u32 = 32;
const seg_cap: u32 = 256;
const name_cap: u32 = 64;
const atlas_width: u32 = 512;
const atlas_height: u32 = 256;
const glyph_count: u32 = 95;
const codepoint_first: u32 = 32;
const ppem: f32 = 32;
const license_cap: u32 = 4096;
const metrics_bytes: u32 = 32 + glyph_count * 40;

const font_path = "assets/NotoSans-Regular.ttf";
const atlas_path = "src/font_atlas.bin";
const metrics_path = "src/font_metrics.bin";
const license_path = "assets/OFL.txt";

const Point = struct {
    x: f32,
    y: f32,
    on: bool,
};

const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

const Table = struct {
    offset: u32,
    length: u32,
};

const Record = struct {
    advance: f32,
    left: f32,
    top: f32,
    width: f32,
    height: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

const Spot = struct {
    x: u32,
    y: u32,
};

var file_bytes: [file_cap]u8 = undefined;
var file_len: u32 = 0;
var points: [point_cap]Point = undefined;
var point_count: u32 = 0;
var contour_ends: [contour_cap]u32 = undefined;
var contour_count: u32 = 0;
var curve: [point_cap]Point = undefined;
var edges: [edge_cap]Edge = undefined;
var edge_count: u32 = 0;
var bitmap: [bitmap_cap][bitmap_cap]u8 = undefined;
var atlas: [atlas_height][atlas_width]u8 = undefined;
var records: [glyph_count]Record = undefined;

var scale: f32 = 0;
var origin_x: f32 = 0;
var top_y: f32 = 0;
var units_per_em: u32 = 0;
var num_glyphs: u32 = 0;
var loca_format: i16 = 0;
var loca_off: u32 = 0;
var glyf_off: u32 = 0;
var hmtx_off: u32 = 0;
var hmetrics: u32 = 0;
var ascent_fu: i16 = 0;
var descent_fu: i16 = 0;

var seg_count: u32 = 0;
var end_code: [seg_cap]u16 = undefined;
var start_code: [seg_cap]u16 = undefined;
var id_delta: [seg_cap]i16 = undefined;
var id_range: [seg_cap]u16 = undefined;
var range_base: u32 = 0;

var shelf_x: u32 = 0;
var shelf_y: u32 = 0;
var shelf_h: u32 = 0;

comptime {
    assert(file_cap == 1024 * 1024);
    assert(segment_cap == point_cap * 8);
    assert(edge_cap == segment_cap);
    assert(bitmap_cap == 64);
    assert(atlas_width == 512);
    assert(atlas_height == 256);
    assert(glyph_count == 95);
    assert(codepoint_first == 32);
    assert(metrics_bytes == 32 + 95 * 40);
    assert(ppem == 32);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.mem.Allocator.failing, .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
        .argv0 = .init(init.args),
        .environ = init.environ,
        .disable_memory_mapping = false,
    });
    defer threaded.deinit();
    const io = threaded.io();
    try read_font(io);
    try bake_ascii();
    try write_outputs(io);
    try write_license(io);
}

fn read_font(io: std.Io) !void {
    assert(font_path.len != 0);
    var file = try open_path(io, font_path);
    defer file.close(io);
    const info = try file.stat(io);
    if (info.size > file_cap) {
        return error.FileTooLarge;
    }
    const length: u32 = @intCast(info.size);
    const read_n = try file.readPositionalAll(io, file_bytes[0..length], 0);
    if (read_n != length) {
        return error.FileShortRead;
    }
    file_len = length;
    assert(file_len != 0);
    assert(file_len <= file_cap);
}

fn open_path(io: std.Io, path: []const u8) !std.Io.File {
    assert(path.len != 0);
    const options: std.Io.Dir.OpenFileOptions = .{
        .mode = .read_only,
        .allow_directory = false,
        .path_only = false,
        .lock = .none,
        .lock_nonblocking = false,
        .allow_ctty = false,
        .follow_symlinks = true,
        .resolve_beneath = false,
    };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    }
    assert(!std.fs.path.isAbsolute(path));
    return std.Io.Dir.cwd().openFile(io, path, options);
}

fn bake_ascii() !void {
    assert(file_len != 0);
    try load_font_tables();
    clear_atlas();
    var codepoint: u32 = codepoint_first;
    while (codepoint <= 126) : (codepoint += 1) {
        try bake_codepoint(codepoint);
    }
    assert(codepoint == 127);
    assert(shelf_y < atlas_height);
}

fn load_font_tables() !void {
    const head = try find_table("head");
    const maxp = try find_table("maxp");
    const hhea = try find_table("hhea");
    const hmtx = try find_table("hmtx");
    const loca = try find_table("loca");
    const glyf = try find_table("glyf");
    units_per_em = read_u16(head.offset + 18);
    loca_format = read_i16(head.offset + 50);
    num_glyphs = read_u16(maxp.offset + 4);
    ascent_fu = read_i16(hhea.offset + 4);
    descent_fu = read_i16(hhea.offset + 6);
    hmetrics = read_u16(hhea.offset + 34);
    hmtx_off = hmtx.offset;
    loca_off = loca.offset;
    glyf_off = glyf.offset;
    assert(units_per_em != 0);
    scale = ppem / @as(f32, @floatFromInt(units_per_em));
    assert(scale > 0);
    try parse_cmap();
}

fn find_table(tag: *const [4]u8) !Table {
    const count = read_u16(4);
    assert(count <= table_cap);
    if (count > table_cap) {
        return error.TableMissing;
    }
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const rec = 12 + index * 16;
        if (std.mem.eql(u8, file_bytes[rec .. rec + 4], tag)) {
            const found: Table = .{
                .offset = read_u32(rec + 8),
                .length = read_u32(rec + 12),
            };
            assert(found.length != 0);
            return found;
        }
    }
    return error.TableMissing;
}

fn parse_cmap() !void {
    const table = try find_table("cmap");
    const tables = read_u16(table.offset + 2);
    assert(tables <= table_cap);
    var index: u32 = 0;
    while (index < tables) : (index += 1) {
        const rec = table.offset + 4 + index * 8;
        const sub = table.offset + read_u32(rec + 4);
        if (read_u16(sub) == 4) {
            try load_format4(sub);
            return;
        }
    }
    return error.CmapFormat;
}

fn load_format4(sub: u32) !void {
    if (read_u16(sub) != 4) {
        return error.CmapFormat;
    }
    const segs: u32 = read_u16(sub + 6) / 2;
    if (segs > seg_cap) {
        return error.CmapFormat;
    }
    assert(segs >= 1);
    seg_count = segs;
    var index: u32 = 0;
    while (index < segs) : (index += 1) {
        end_code[index] = read_u16(sub + 14 + index * 2);
    }
    const start_at = sub + 14 + segs * 2 + 2;
    const delta_at = start_at + segs * 2;
    range_base = delta_at + segs * 2;
    index = 0;
    while (index < segs) : (index += 1) {
        start_code[index] = read_u16(start_at + index * 2);
        id_delta[index] = read_i16(delta_at + index * 2);
        id_range[index] = read_u16(range_base + index * 2);
    }
    assert(seg_count == segs);
    assert(range_base > sub);
}

fn glyph_id(codepoint: u32) !u32 {
    assert(codepoint >= codepoint_first);
    assert(codepoint <= 126);
    var index: u32 = 0;
    while (index < seg_count) : (index += 1) {
        if (end_code[index] >= codepoint) {
            if (start_code[index] > codepoint) {
                return error.GlyphMissing;
            }
            return lookup_segment(index, codepoint);
        }
    }
    return error.GlyphMissing;
}

fn lookup_segment(index: u32, codepoint: u32) !u32 {
    assert(index < seg_count);
    assert(codepoint >= start_code[index]);
    if (id_range[index] == 0) {
        return delta_id(id_delta[index], codepoint);
    }
    const delta_code = codepoint - start_code[index];
    const byte_off = range_base + index * 2 + @as(u32, id_range[index]) + delta_code * 2;
    const raw = read_u16(byte_off);
    if (raw == 0) {
        return 0;
    }
    return delta_id(id_delta[index], raw);
}

fn delta_id(delta: i16, codepoint: u32) u32 {
    const sum = @as(i32, delta) + @as(i32, @intCast(codepoint));
    const id: u32 = @intCast(sum & 0xFFFF);
    assert(id <= 0xFFFF);
    return id;
}

fn loca_at(glyph: u32) !u32 {
    if (loca_format != 1) {
        return error.LocaFormat;
    }
    assert(glyph <= num_glyphs);
    const offset = read_u32(loca_off + glyph * 4);
    assert(offset <= file_len);
    return offset;
}

fn bake_codepoint(codepoint: u32) !void {
    assert(codepoint >= codepoint_first);
    const slot = codepoint - codepoint_first;
    const id = try glyph_id(codepoint);
    const start = try loca_at(id);
    const end = try loca_at(id + 1);
    const advance = advance_of(id);
    if (start == end) {
        records[slot] = empty_record(advance);
        assert(records[slot].width == 0);
        return;
    }
    try bake_outline(slot, glyf_off + start, advance);
    assert(records[slot].advance > 0);
}

fn bake_outline(slot: u32, offset: u32, advance: f32) !void {
    const x_min: f32 = @floatFromInt(read_i16(offset + 2));
    const y_min: f32 = @floatFromInt(read_i16(offset + 4));
    const x_max: f32 = @floatFromInt(read_i16(offset + 6));
    const y_max: f32 = @floatFromInt(read_i16(offset + 8));
    const x0 = floor_px(x_min * scale);
    const x1 = ceil_px(x_max * scale);
    const y0 = floor_px(y_min * scale);
    const y1 = ceil_px(y_max * scale);
    if (x1 <= x0) {
        return error.InsetCollapsed;
    }
    if (y1 <= y0) {
        return error.InsetCollapsed;
    }
    const width: u32 = @intCast(x1 - x0);
    const height: u32 = @intCast(y1 - y0);
    if (width < 2) {
        return error.InsetCollapsed;
    }
    if (height < 2) {
        return error.InsetCollapsed;
    }
    origin_x = @floatFromInt(x0);
    top_y = @floatFromInt(y1);
    try load_simple(offset);
    try flatten();
    try rasterize(width, height);
    const spot = try pack_shelf(width, height);
    blit(spot, width, height);
    records[slot] = ink_record(advance, x0, y1, width, height, spot);
    assert(records[slot].u0 < records[slot].u1);
}

fn empty_record(advance: f32) Record {
    assert(advance > 0);
    const record: Record = .{
        .advance = advance,
        .left = 0,
        .top = 0,
        .width = 0,
        .height = 0,
        .u0 = 0,
        .v0 = 0,
        .u1 = 0,
        .v1 = 0,
    };
    assert(record.width == 0);
    assert(record.u0 == 0);
    return record;
}

fn ink_record(
    advance: f32,
    x0: i32,
    y1: i32,
    width: u32,
    height: u32,
    spot: Spot,
) Record {
    const ax: f32 = @floatFromInt(spot.x);
    const ay: f32 = @floatFromInt(spot.y);
    const gw: f32 = @floatFromInt(width);
    const gh: f32 = @floatFromInt(height);
    const record: Record = .{
        .advance = advance,
        .left = @as(f32, @floatFromInt(x0)) / 2.0,
        .top = -@as(f32, @floatFromInt(y1)) / 2.0,
        .width = gw / 2.0,
        .height = gh / 2.0,
        .u0 = (ax + 0.5) / @as(f32, atlas_width),
        .v0 = (ay + 0.5) / @as(f32, atlas_height),
        .u1 = (ax + gw - 0.5) / @as(f32, atlas_width),
        .v1 = (ay + gh - 0.5) / @as(f32, atlas_height),
    };
    assert(record.width > 0);
    assert(record.u0 < record.u1);
    return record;
}

fn advance_of(glyph: u32) f32 {
    assert(hmetrics != 0);
    const index = if (glyph < hmetrics) glyph else hmetrics - 1;
    const units = read_u16(hmtx_off + index * 4);
    const logical = fu_to_logical(@floatFromInt(units));
    assert(logical > 0);
    return logical;
}

fn fu_to_logical(units: f32) f32 {
    assert(scale > 0);
    const logical = units * scale / 2.0;
    assert(logical == logical);
    return logical;
}

fn load_simple(offset: u32) !void {
    const contours = read_i16(offset);
    if (contours < 0) {
        return error.CompositeGlyph;
    }
    if (contours == 0) {
        contour_count = 0;
        point_count = 0;
        return;
    }
    if (@as(u32, @intCast(contours)) > contour_cap) {
        return error.ContourCap;
    }
    contour_count = @intCast(contours);
    var index: u32 = 0;
    while (index < contour_count) : (index += 1) {
        contour_ends[index] = read_u16(offset + 10 + index * 2);
    }
    const npts = contour_ends[contour_count - 1] + 1;
    if (npts > point_cap) {
        return error.PointCap;
    }
    const instr_at = offset + 10 + contour_count * 2;
    const instr_len: u32 = read_u16(instr_at);
    try read_points(instr_at + 2 + instr_len, npts);
    assert(point_count == npts);
    assert(contour_count >= 1);
}

fn read_points(flag_at: u32, npts: u32) !void {
    var flags: [point_cap]u8 = undefined;
    var cursor = try read_flags(flag_at, npts, &flags);
    cursor = read_axis(flags[0..npts], cursor, 2, 16, .x);
    _ = read_axis(flags[0..npts], cursor, 4, 32, .y);
    point_count = npts;
    assert(point_count == npts);
    assert(cursor <= file_len);
}

fn read_flags(flag_at: u32, npts: u32, flags: *[point_cap]u8) !u32 {
    assert(npts <= point_cap);
    var cursor = flag_at;
    var index: u32 = 0;
    while (index < npts) {
        const flag = file_bytes[cursor];
        cursor += 1;
        var repeat: u32 = 1;
        if ((flag & 8) != 0) {
            repeat += file_bytes[cursor];
            cursor += 1;
        }
        var left = repeat;
        while (left > 0) : (left -= 1) {
            if (index >= npts) {
                return error.PointCap;
            }
            flags[index] = flag;
            index += 1;
        }
    }
    assert(index == npts);
    assert(cursor > flag_at);
    return cursor;
}

const Axis = enum { x, y };

fn read_axis(flags: []const u8, cursor_in: u32, short_bit: u8, same_bit: u8, axis: Axis) u32 {
    assert(flags.len <= point_cap);
    var cursor = cursor_in;
    var index: u32 = 0;
    var value: f32 = 0;
    while (index < flags.len) : (index += 1) {
        value += delta_coord(flags[index], &cursor, short_bit, same_bit);
        switch (axis) {
            .x => points[index].x = value,
            .y => points[index].y = value,
        }
        points[index].on = (flags[index] & 1) != 0;
    }
    assert(index == flags.len);
    assert(cursor >= cursor_in);
    return cursor;
}

fn delta_coord(flag: u8, cursor: *u32, short_bit: u8, same_bit: u8) f32 {
    assert(cursor.* < file_len);
    if ((flag & short_bit) != 0) {
        const mag: f32 = @floatFromInt(file_bytes[cursor.*]);
        cursor.* += 1;
        if ((flag & same_bit) != 0) {
            return mag;
        }
        return -mag;
    }
    if ((flag & same_bit) != 0) {
        return 0;
    }
    const delta: f32 = @floatFromInt(read_i16(cursor.*));
    cursor.* += 2;
    assert(delta == delta);
    return delta;
}

fn flatten() !void {
    assert(contour_count <= contour_cap);
    edge_count = 0;
    var contour: u32 = 0;
    var start: u32 = 0;
    while (contour < contour_count) : (contour += 1) {
        const end = contour_ends[contour];
        try flatten_contour(start, end);
        start = end + 1;
    }
    assert(contour == contour_count);
    assert(edge_count <= edge_cap);
}

fn flatten_contour(start: u32, end: u32) !void {
    assert(end >= start);
    assert(end < point_count);
    const seq_n = try expand_contour(start, end);
    const origin = first_on(seq_n);
    var prev = curve[origin];
    var step: u32 = 1;
    while (step <= seq_n) {
        const cur = ring_at(origin, step, seq_n);
        if (cur.on) {
            try add_line(prev, cur);
            prev = cur;
            step += 1;
        } else {
            const next = ring_at(origin, step + 1, seq_n);
            assert(next.on);
            try add_quad(prev, cur, next);
            prev = next;
            step += 2;
        }
    }
    assert(step > seq_n);
    assert(edge_count >= 1);
}

fn expand_contour(start: u32, end: u32) !u32 {
    var seq_n: u32 = 0;
    var index = start;
    while (index <= end) : (index += 1) {
        const cur = points[index];
        const next = if (index == end) points[start] else points[index + 1];
        if (seq_n == point_cap) {
            return error.PointCap;
        }
        curve[seq_n] = cur;
        seq_n += 1;
        if (!cur.on) {
            if (!next.on) {
                if (seq_n == point_cap) {
                    return error.PointCap;
                }
                curve[seq_n] = midpoint(cur, next);
                seq_n += 1;
            }
        }
    }
    assert(seq_n >= 1);
    assert(seq_n <= point_cap);
    return seq_n;
}

fn first_on(seq_n: u32) u32 {
    assert(seq_n >= 1);
    var index: u32 = 0;
    while (index < seq_n) : (index += 1) {
        if (curve[index].on) {
            assert(curve[index].on);
            return index;
        }
    }
    assert(index == seq_n);
    return 0;
}

fn ring_at(origin: u32, step: u32, seq_n: u32) Point {
    assert(seq_n != 0);
    assert(origin < seq_n);
    const index = (origin + step) % seq_n;
    assert(index < seq_n);
    return curve[index];
}

fn midpoint(a: Point, b: Point) Point {
    const mid: Point = .{
        .x = (a.x + b.x) * 0.5,
        .y = (a.y + b.y) * 0.5,
        .on = true,
    };
    assert(mid.on);
    assert(mid.x == mid.x);
    return mid;
}

fn add_line(a: Point, b: Point) !void {
    const p0 = font_to_pixel(a);
    const p1 = font_to_pixel(b);
    try add_edge(p0.x, p0.y, p1.x, p1.y);
    assert(edge_count >= 1);
}

fn add_quad(a: Point, b: Point, c: Point) !void {
    const p0 = font_to_pixel(a);
    const p1 = font_to_pixel(b);
    const p2 = font_to_pixel(c);
    var prev_x = p0.x;
    var prev_y = p0.y;
    var step: u32 = 1;
    while (step <= 8) : (step += 1) {
        assert(step <= segment_cap);
        const t: f32 = @as(f32, @floatFromInt(step)) / 8.0;
        const u = 1.0 - t;
        const x = u * u * p0.x + 2.0 * u * t * p1.x + t * t * p2.x;
        const y = u * u * p0.y + 2.0 * u * t * p1.y + t * t * p2.y;
        try add_edge(prev_x, prev_y, x, y);
        prev_x = x;
        prev_y = y;
    }
    assert(step == 9);
    assert(edge_count <= edge_cap);
}

fn add_edge(x0: f32, y0: f32, x1: f32, y1: f32) !void {
    if (edge_count == edge_cap) {
        return error.EdgeCap;
    }
    edges[edge_count] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    edge_count += 1;
    assert(edge_count <= edge_cap);
    assert(edge_count <= segment_cap);
}

fn font_to_pixel(p: Point) Point {
    assert(scale > 0);
    const pixel: Point = .{
        .x = p.x * scale - origin_x,
        .y = top_y - p.y * scale,
        .on = p.on,
    };
    assert(pixel.x == pixel.x);
    assert(pixel.y == pixel.y);
    return pixel;
}

fn rasterize(width: u32, height: u32) !void {
    if (width > bitmap_cap) {
        return error.BitmapCap;
    }
    if (height > bitmap_cap) {
        return error.BitmapCap;
    }
    assert(width >= 2);
    assert(height >= 2);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        fill_scanline(y, width);
    }
    assert(y == height);
    assert(bitmap[0][0] <= 255);
}

fn fill_scanline(y: u32, width: u32) void {
    assert(y < bitmap_cap);
    assert(width <= bitmap_cap);
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        bitmap[y][x] = coverage_at(x, y);
    }
    while (x < bitmap_cap) : (x += 1) {
        bitmap[y][x] = 0;
    }
    assert(x == bitmap_cap);
}

fn coverage_at(x: u32, y: u32) u8 {
    assert(x < bitmap_cap);
    assert(y < bitmap_cap);
    var hits: u32 = 0;
    var sy: u32 = 0;
    while (sy < 4) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < 4) : (sx += 1) {
            const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4.0;
            const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4.0;
            if (winding_at(px, py) != 0) {
                hits += 1;
            }
        }
    }
    assert(hits <= 16);
    const coverage: u8 = @intCast(hits * 255 / 16);
    assert(coverage <= 255);
    return coverage;
}

fn winding_at(px: f32, py: f32) i32 {
    assert(edge_count <= edge_cap);
    var winding: i32 = 0;
    var index: u32 = 0;
    while (index < edge_count) : (index += 1) {
        winding += edge_wind(edges[index], px, py);
    }
    assert(index == edge_count);
    return winding;
}

fn edge_wind(edge: Edge, px: f32, py: f32) i32 {
    if (edge.y0 == edge.y1) {
        return 0;
    }
    const up = edge.y0 <= py and py < edge.y1;
    const down = edge.y1 <= py and py < edge.y0;
    if (!up) {
        if (!down) {
            return 0;
        }
    }
    const t = (py - edge.y0) / (edge.y1 - edge.y0);
    const x = edge.x0 + t * (edge.x1 - edge.x0);
    if (px >= x) {
        return 0;
    }
    if (edge.y1 > edge.y0) {
        return 1;
    }
    return -1;
}

fn pack_shelf(width: u32, height: u32) !Spot {
    assert(width >= 1);
    assert(height >= 1);
    if (width == 1) {
        return error.InsetCollapsed;
    }
    if (height == 1) {
        return error.InsetCollapsed;
    }
    if (width > atlas_width) {
        return error.AtlasFull;
    }
    if (shelf_x + width > atlas_width) {
        shelf_y += shelf_h + 1;
        shelf_x = 0;
        shelf_h = 0;
    }
    if (shelf_y + height > atlas_height) {
        return error.AtlasFull;
    }
    const spot: Spot = .{ .x = shelf_x, .y = shelf_y };
    shelf_x += width + 1;
    if (height > shelf_h) {
        shelf_h = height;
    }
    assert(spot.x + width <= atlas_width);
    assert(spot.y + height <= atlas_height);
    return spot;
}

fn blit(spot: Spot, width: u32, height: u32) void {
    assert(width <= bitmap_cap);
    assert(height <= bitmap_cap);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            atlas[spot.y + row][spot.x + col] = bitmap[row][col];
        }
        assert(col == width);
    }
    assert(row == height);
}

fn clear_atlas() void {
    var row: u32 = 0;
    while (row < atlas_height) : (row += 1) {
        var col: u32 = 0;
        while (col < atlas_width) : (col += 1) {
            atlas[row][col] = 0;
        }
    }
    assert(row == atlas_height);
    assert(atlas[0][0] == 0);
}

fn write_outputs(io: std.Io) !void {
    var metrics: [metrics_bytes]u8 = undefined;
    write_header(&metrics);
    var slot: u32 = 0;
    while (slot < glyph_count) : (slot += 1) {
        write_record(&metrics, slot);
    }
    assert(metrics_bytes == 32 + 95 * 40);
    assert(slot == glyph_count);
    try write_bytes(io, atlas_path, std.mem.sliceAsBytes(atlas[0..]));
    try write_bytes(io, metrics_path, metrics[0..]);
    const ascent = fu_to_logical(@floatFromInt(ascent_fu));
    const descent = -fu_to_logical(@floatFromInt(descent_fu));
    std.debug.print(
        "baked {d} glyphs, ascent {d}, descent {d}\n",
        .{ glyph_count, ascent, descent },
    );
}

fn write_header(metrics: *[metrics_bytes]u8) void {
    const ascent = fu_to_logical(@floatFromInt(ascent_fu));
    const descent = -fu_to_logical(@floatFromInt(descent_fu));
    write_u32(metrics, 0, atlas_width);
    write_u32(metrics, 4, atlas_height);
    write_u32(metrics, 8, glyph_count);
    write_u32(metrics, 12, codepoint_first);
    write_f32(metrics, 16, ascent);
    write_f32(metrics, 20, descent);
    write_f32(metrics, 24, ascent + descent);
    write_u32(metrics, 28, 0);
    assert(ascent > 0);
    assert(descent > 0);
}

fn write_record(metrics: *[metrics_bytes]u8, slot: u32) void {
    assert(slot < glyph_count);
    const record = records[slot];
    const at = 32 + slot * 40;
    write_f32(metrics, at + 0, record.advance);
    write_f32(metrics, at + 4, record.left);
    write_f32(metrics, at + 8, record.top);
    write_f32(metrics, at + 12, record.width);
    write_f32(metrics, at + 16, record.height);
    write_f32(metrics, at + 20, record.u0);
    write_f32(metrics, at + 24, record.v0);
    write_f32(metrics, at + 28, record.u1);
    write_f32(metrics, at + 32, record.v1);
    write_u32(metrics, at + 36, 0);
    assert(record.advance > 0);
    assert(metrics[at + 36] == 0);
}

fn write_license(io: std.Io) !void {
    var text: [license_cap]u8 = undefined;
    const copyright = try copy_name(0, text[0..]);
    assert(copyright >= 1);
    text[copyright] = '\n';
    text[copyright + 1] = '\n';
    const license = try copy_name(13, text[copyright + 2 ..]);
    const end = copyright + 2 + license;
    text[end] = '\n';
    try write_bytes(io, license_path, text[0 .. end + 1]);
    assert(end + 1 <= license_cap);
    assert(text[end] == '\n');
}

fn copy_name(name_id: u16, dest: []u8) !u32 {
    assert(dest.len != 0);
    const table = try find_table("name");
    const count = read_u16(table.offset + 2);
    assert(count <= name_cap);
    const storage = table.offset + read_u16(table.offset + 4);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const rec = table.offset + 6 + index * 12;
        const platform = read_u16(rec);
        const id = read_u16(rec + 6);
        if (platform == 3) {
            if (id == name_id) {
                const len = read_u16(rec + 8);
                const off = read_u16(rec + 10);
                return utf16_utf8(storage + off, len, dest);
            }
        }
    }
    return error.NameMissing;
}

fn utf16_utf8(offset: u32, byte_len: u32, dest: []u8) !u32 {
    assert(byte_len % 2 == 0);
    var input: u32 = 0;
    var output: u32 = 0;
    while (input < byte_len) : (input += 2) {
        const unit = read_u16(offset + input);
        output = try push_utf8(dest, output, unit);
    }
    assert(input == byte_len);
    assert(output <= dest.len);
    return output;
}

fn push_utf8(dest: []u8, output: u32, unit: u16) !u32 {
    assert(output <= dest.len);
    if (unit < 0x80) {
        dest[output] = @intCast(unit);
        return output + 1;
    }
    if (unit < 0x800) {
        dest[output] = @intCast(0xC0 | (unit >> 6));
        dest[output + 1] = @intCast(0x80 | (unit & 0x3F));
        return output + 2;
    }
    dest[output] = @intCast(0xE0 | (unit >> 12));
    dest[output + 1] = @intCast(0x80 | ((unit >> 6) & 0x3F));
    dest[output + 2] = @intCast(0x80 | (unit & 0x3F));
    assert(unit >= 0x800);
    return output + 3;
}

fn write_bytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    assert(path.len != 0);
    assert(bytes.len != 0);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{
            .read = false,
            .truncate = true,
            .exclusive = false,
            .lock = .none,
            .lock_nonblocking = false,
            .permissions = .default_file,
            .resolve_beneath = false,
        },
    });
    assert(bytes.len <= file_cap);
}

fn write_u32(metrics: *[metrics_bytes]u8, offset: u32, value: u32) void {
    assert(offset + 4 <= metrics_bytes);
    std.mem.writeInt(u32, metrics[offset..][0..4], value, .little);
    assert(std.mem.readInt(u32, metrics[offset..][0..4], .little) == value);
}

fn write_f32(metrics: *[metrics_bytes]u8, offset: u32, value: f32) void {
    assert(value == value);
    write_u32(metrics, offset, @bitCast(value));
    assert(offset + 4 <= metrics_bytes);
}

fn read_u16(offset: u32) u16 {
    assert(offset + 2 <= file_len);
    const value = std.mem.readInt(u16, file_bytes[offset..][0..2], .big);
    assert(offset + 2 <= file_len);
    return value;
}

fn read_i16(offset: u32) i16 {
    assert(offset + 2 <= file_len);
    return std.mem.readInt(i16, file_bytes[offset..][0..2], .big);
}

fn read_u32(offset: u32) u32 {
    assert(offset + 4 <= file_len);
    const value = std.mem.readInt(u32, file_bytes[offset..][0..4], .big);
    assert(value == value);
    return value;
}

fn floor_px(value: f32) i32 {
    assert(value == value);
    return @intFromFloat(@floor(value));
}

fn ceil_px(value: f32) i32 {
    assert(value == value);
    const rounded: i32 = @intFromFloat(@ceil(value));
    assert(@as(f32, @floatFromInt(rounded)) >= value);
    return rounded;
}

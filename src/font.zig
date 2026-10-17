//! Baked coverage atlas, metrics decoding, and runtime glyph layout.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Baked Atlas?
//! Runtime outline parsing and rasterization put TrueType table decoding, Bézier flattening,
//! and atlas allocation on the frame path. That costs latency spikes, allocator churn, and
//! binary size on `wasm32-freestanding`. MSDF atlases avoid the rasterizer but need a
//! multi-channel texture and a median-of-channels fragment shader, and they soften small text.
//!
//! Instead `scripts/bake_font.zig` rasterizes once, offline, into a single-channel (`r8unorm`)
//! coverage atlas (`font_atlas.bin`) and a pre-scaled metrics table (`font_metrics.bin`). Both
//! are `@embedFile`d, so the frame path decodes nothing at runtime and allocates nothing.
//!
//! Glyph quads use their own pipeline (`glyph.wgsl`) and share the quad instance stride
//! (`glyph_stride`). Text carries no `Animator`, so static labels never keep the frame loop
//! alive.
//!
//! ## 2. Coordinate Spaces & Layout Algebra
//! - **Bake pixel space:** the rasterizer grid, Y-down. Internal to the baker.
//! - **UI logical space:** top-left origin, `+X` right, `+Y` down. Every `Metric` field except
//!   the UVs is in this space. The atlas texel grid is sampled at twice the logical density,
//!   so a quad's logical size is half its texel size (test "ink quads are half their texel
//!   size").
//! - **UV space:** `[0, 1] x [0, 1]` across `atlas_width x atlas_height`.
//!
//! `place` lays out `N` glyphs `C_i` inside `inner = (x, y, width, height)`:
//! ```text
//! text_width = sum(advance(C_i))
//! pen_x      = inner.x + (inner.width - text_width) * 0.5
//! line_h     = ascent + descent            (descent stored as a positive distance)
//! baseline_y = inner.y + (inner.height - line_h) * 0.5 + ascent
//! dest_x     = pen_x + left                (per glyph, then pen_x += advance)
//! dest_y     = baseline_y + top            (top is negative above the baseline)
//! dest_w, dest_h = width, height
//! ```
//! A glyph with `width == 0` (space) advances the pen and emits no quad. Worked values: see
//! tests "place centers a glyph on the line box" and "space places no quad and a positive pen
//! delta".
//!
//! ### Half-Texel UV Inset
//! WebGPU samples texel `(x, y)` at its center `(x + 0.5, y + 0.5)`. A quad whose UVs sit on
//! the glyph's texel edges would, under bilinear filtering, blend in the neighboring gutter or
//! glyph at its border. The baker therefore insets every UV by half a texel:
//! ```text
//! u0 = (atlas_x + 0.5) / atlas_width            v0 = (atlas_y + 0.5) / atlas_height
//! u1 = (atlas_x + glyph_w - 0.5) / atlas_width  v1 = (atlas_y + glyph_h - 0.5) / atlas_height
//! ```
//! The runtime and shader consume the UVs as-is, with no clamping. Locked by test "ink UVs sit
//! on half-texel centers".
//!
//! ## 3. Layouts
//! - **`Glyph`** is an `extern struct` of four consecutive `float32x4` vertex attributes in
//!   this order: dest rect `(x, y, w, h)`, UV rect `(u0, v0, u1, v1)`, color `(r, g, b, a)`,
//!   clip `(x0, y0, x1, y1)`. See the vertex input of `glyph.wgsl`. The comptime block below
//!   asserts the size, stride, and the offset of each group.
//! - **`font_metrics.bin`** is little-endian: a header of `header_bytes`, then
//!   `codepoint_count` records of `record_bytes`. Every field is four bytes.
//!   - Header: `atlas_width`, `atlas_height`, `glyph_count`, `codepoint_first` (all `u32`),
//!     `ascent`, `descent`, `line_height` (`f32`, logical pixels, `line_height == ascent +
//!     descent`), then one zero `u32`.
//!   - Record, indexed by `byte - codepoint_first`: `advance`, `left`, `top`, `width`,
//!     `height`, `u0`, `v0`, `u1`, `v1` (`f32`), then one zero `u32`.
//!
//!   The comptime block checks the total length, the header's dimension and range fields
//!   against the constants here, and the header pad. `read_metric` asserts each record pad.
//! - **`font_atlas.bin`** is row-major `r8unorm`, `atlas_width` bytes per row. The row length
//!   must be a multiple of the WebGPU buffer-to-texture `bytesPerRow` alignment (see
//!   `gpu_wgpu.zig`); the comptime block asserts it.
//!
//! ## 4. Data Flow
//! `widgets.place_label` computes the padded box, `place` appends one `Glyph` per ink glyph, and
//! every `append` or `clear` bumps `GlyphList.revision`. `draw.UploadCursor.flags` compares that
//! revision with its remembered one and sets `flag_glyphs`; the host then uploads
//! `count * glyph_stride` bytes and draws the glyph pass.
//!
//! ## 5. Cross-Platform Seams
//! On `wasm32-freestanding`, `web_exports.zig` exposes `atlas_bytes` to JavaScript by pointer
//! and length with no copy. The host uploads it once at startup. Texture usage flags and bind
//! group layout rules for the two pipelines live with their owners (`gpu_wgpu.zig`, `shell.js`).
//!
//! ## 6. TigerStyle Invariants
//! - Bounded by `glyph_cap`, `text_cap`, and the closed range of `codepoint_count` codepoints
//!   starting at `codepoint_first`.
//! - No heap: `GlyphList` is a fixed array and the metrics are decoded at compile time.
//! - `append` rejects bad input with an error; `place` requires its capacity precondition.

const std = @import("std");
const assert = std.debug.assert;

const metrics_file: []const u8 = @embedFile("font_metrics.bin");

/// Coverage atlas: `atlas_width * atlas_height` bytes, one `r8unorm` texel per byte,
/// row-major.
pub const atlas_bytes: []const u8 = @embedFile("font_atlas.bin");

/// Glyph shader. Separate from `quad.wgsl` while sharing the quad instance stride.
pub const shader_file: []const u8 = @embedFile("glyph.wgsl");

/// Atlas dimensions in texels. Must match the baker's constants and the metrics header; the
/// comptime block below checks the header.
pub const atlas_width: u32 = 512;
pub const atlas_height: u32 = 256;

/// Hard cap on glyph quads queued for one frame.
pub const glyph_cap: u32 = 256;

/// Hard cap on a label string, in bytes.
pub const text_cap: u32 = 64;

/// Byte size of one `Glyph` instance. Enforced equal to `@sizeOf(Glyph)` below.
pub const glyph_stride: u32 = 64;

/// Count of printable ASCII codepoints covered, `codepoint_first` through its last.
const codepoint_count: u32 = 95;

/// First covered codepoint: space (U+0020).
const codepoint_first: u8 = 32;

/// Byte size of the `font_metrics.bin` header: eight four-byte fields.
const header_bytes: u32 = 32;

/// Byte size of one `font_metrics.bin` record: ten four-byte fields.
const record_bytes: u32 = 40;

/// One instanced glyph quad in the glyph vertex buffer.
///
/// `extern struct` so the field order is the GPU attribute order with no compiler padding.
/// Fields group into four `float32x4` attributes, each asserted by `@offsetOf` in the comptime
/// block: the destination rect `x, y, width, height` in UI logical pixels; the UV rect
/// `u0, v0, u1, v1` (half-texel inset, within `[0, 1]`); the straight (non-premultiplied)
/// color `r, g, b, a` that the fragment shader scales by atlas coverage; and the exclusive-max
/// clip `clip_x0, clip_y0, clip_x1, clip_y1`. The fragment applies a hard inside mask, and
/// there is no "unclipped" sentinel.
pub const Glyph = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    clip_x0: f32,
    clip_y0: f32,
    clip_x1: f32,
    clip_y1: f32,
};

/// Exclusive-max clip in logical pixels. `x1 > x0` and `y1 > y0`, all finite.
pub const Clip = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// Bounding rectangle in UI logical pixels.
/// Origin (0, 0) is at the top-left corner. +X extends rightwards, +Y extends downwards.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Straight RGBA color written into the glyph instance.
/// The fragment shader multiplies `a` by the atlas coverage sample `r`.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Pre-scaled glyph metrics. All fields but the UVs are in UI logical pixels; the UVs are
/// normalized with the half-texel inset described in the module guide.
const Metric = struct {
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

/// Pre-decoded font-wide vertical metrics and per-codepoint records.
const Baked = struct {
    ascent: f32,
    descent: f32,
    line_height: f32,
    glyphs: [codepoint_count]Metric,
};

/// Fixed-capacity list of glyph instances for the glyph draw pass, bounded by `glyph_cap`.
///
/// `revision` bumps on every append and clear so `draw.UploadCursor` can detect change and
/// raise `flag_glyphs`.
pub const GlyphList = struct {
    items: [glyph_cap]Glyph,
    count: u32,
    revision: u32,

    /// Empty list with zeroed storage, so no stale bytes reach the GPU buffer.
    pub fn init() GlyphList {
        const list: GlyphList = .{
            .items = std.mem.zeroes([glyph_cap]Glyph),
            .count = 0,
            .revision = 0,
        };
        assert(list.count == 0);
        assert(list.revision == 0);
        return list;
    }

    pub const AppendError = error{
        EdgeNotPositive,
        UvOutOfRange,
        ListFull,
        ClipUnordered,
    };

    /// Appends one ink quad. The list is unchanged on error.
    ///
    /// - `error.EdgeNotPositive`: `width <= 0` or `height <= 0`.
    /// - `error.UvOutOfRange`: not `0 <= u0 < u1 <= 1` and `0 <= v0 < v1 <= 1`.
    /// - `error.ClipUnordered`: a clip edge is non-finite, or `clip_x1 <= clip_x0`, or
    ///   `clip_y1 <= clip_y0`.
    /// - `error.ListFull`: `count == glyph_cap`.
    ///
    /// Success increments both `count` and `revision`.
    pub fn append(self: *GlyphList, glyph: Glyph) AppendError!void {
        assert(self.count <= glyph_cap);
        if (glyph.width <= 0) {
            return error.EdgeNotPositive;
        }
        if (glyph.height <= 0) {
            return error.EdgeNotPositive;
        }
        if (!uv_ok(glyph.u0, glyph.u1)) {
            return error.UvOutOfRange;
        }
        if (!uv_ok(glyph.v0, glyph.v1)) {
            return error.UvOutOfRange;
        }
        if (!clip_ordered(glyph)) {
            return error.ClipUnordered;
        }
        if (self.count == glyph_cap) {
            return error.ListFull;
        }
        assert(glyph.width > 0);
        assert(glyph.u0 < glyph.u1);
        self.items[self.count] = glyph;
        self.count += 1;
        self.revision += 1;
        assert(self.items[self.count - 1].width > 0);
        assert(self.items[self.count - 1].clip_x1 > self.items[self.count - 1].clip_x0);
        assert(self.count <= glyph_cap);
    }

    /// Resets `count` to zero and bumps `revision`, even when already empty, so the upload
    /// cursor always observes a frame that rebuilt the list.
    pub fn clear(self: *GlyphList) void {
        assert(self.count <= glyph_cap);
        self.count = 0;
        self.revision += 1;
        assert(self.count == 0);
        assert(self.revision >= 1);
    }
};

// The vertex layout in `glyph.wgsl` and the embedded binaries are produced outside this file, so
// every fact they must agree on is asserted here rather than trusted.
comptime {
    // Glyph instance layout: four consecutive float32x4 attributes.
    assert(@sizeOf(Glyph) == 64);
    assert(@alignOf(Glyph) >= 4);
    assert(glyph_stride == @sizeOf(Glyph));
    assert(@offsetOf(Glyph, "x") == 0);
    assert(@offsetOf(Glyph, "u0") == 16);
    assert(@offsetOf(Glyph, "r") == 32);
    assert(@offsetOf(Glyph, "clip_x0") == 48);
    assert(glyph_cap == 256);
    assert(text_cap == 64);
    assert(shader_file.len >= 1);

    // Atlas: one byte per texel. The row length must be a multiple of the WebGPU
    // buffer-to-texture `bytesPerRow` alignment of 256 so the upload needs no row padding.
    assert(atlas_width == 512);
    assert(atlas_height == 256);
    assert(atlas_bytes.len == atlas_width * atlas_height);
    assert(atlas_width % 256 == 0);

    // Metrics file: length, field counts, and the header fields shared with the baker.
    assert(header_bytes == 8 * 4);
    assert(record_bytes == 10 * 4);
    assert(metrics_file.len == header_bytes + codepoint_count * record_bytes);
    assert(read_u32(0) == atlas_width);
    assert(read_u32(4) == atlas_height);
    assert(read_u32(8) == codepoint_count);
    assert(read_u32(12) == codepoint_first);
    assert(read_u32(28) == 0);
    assert(baked.line_height == baked.ascent + baked.descent);
    assert(baked.ascent > 0);
    assert(baked.descent > 0);
}

const baked: Baked = decode_metrics();

/// True for a printable ASCII byte, including space. Control bytes and DEL are outside.
pub fn codepoint_ok(byte: u8) bool {
    if (byte < codepoint_first) {
        return false;
    }
    if (byte > 126) {
        return false;
    }
    assert(byte >= codepoint_first);
    assert(byte <= 126);
    return true;
}

/// Sum of advances in logical pixels. An empty string measures 0.
pub fn measure(text: []const u8) f32 {
    assert(text.len <= text_cap);
    const count: u32 = @intCast(text.len);
    var sum: f32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        assert(codepoint_ok(text[index]));
        sum += advance_at(text[index]);
    }
    assert(index == count);
    assert(sum >= 0);
    return sum;
}

/// Centers `text` in `rect` (UI logical pixels) and appends one quad per glyph with positive
/// width, using the algebra in the module guide. Every quad copies `color` and `clip`.
///
/// Preconditions: every byte satisfies `codepoint_ok`, at least `text.len` slots are free, and
/// `clip` is finite and ordered. Under them `append` cannot fail, so its error is `unreachable`.
pub fn place(list: *GlyphList, text: []const u8, rect: Rect, color: Color, clip: Clip) void {
    assert(text.len <= text_cap);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    const count: u32 = @intCast(text.len);
    assert(glyph_cap - list.count >= count);
    const text_width = measure(text);
    var pen_x = rect.x + (rect.width - text_width) * 0.5;
    const line_height = baked.line_height;
    const baseline_y = rect.y + (rect.height - line_height) * 0.5 + baked.ascent;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const metric = metric_at(text[index]);
        if (metric.width > 0) {
            assert(metric.height > 0);
            list.append(.{
                .x = pen_x + metric.left,
                .y = baseline_y + metric.top,
                .width = metric.width,
                .height = metric.height,
                .u0 = metric.u0,
                .v0 = metric.v0,
                .u1 = metric.u1,
                .v1 = metric.v1,
                .r = color.r,
                .g = color.g,
                .b = color.b,
                .a = color.a,
                .clip_x0 = clip.x0,
                .clip_y0 = clip.y0,
                .clip_x1 = clip.x1,
                .clip_y1 = clip.y1,
            }) catch unreachable;
        }
        pen_x += metric.advance;
    }
    assert(index == count);
    assert(list.count <= glyph_cap);
}

/// False for NaN and infinities.
fn finite_f32(value: f32) bool {
    if (value != value) {
        return false;
    }
    if (std.math.isInf(value)) {
        return false;
    }
    assert(value == value);
    return true;
}

/// True when all four clip edges are finite and ordered `x0 < x1`, `y0 < y1`.
fn clip_ordered(glyph: Glyph) bool {
    if (!finite_f32(glyph.clip_x0)) {
        return false;
    }
    if (!finite_f32(glyph.clip_y0)) {
        return false;
    }
    if (!finite_f32(glyph.clip_x1)) {
        return false;
    }
    if (!finite_f32(glyph.clip_y1)) {
        return false;
    }
    if (!(glyph.clip_x1 > glyph.clip_x0)) {
        return false;
    }
    if (!(glyph.clip_y1 > glyph.clip_y0)) {
        return false;
    }
    assert(glyph.clip_x1 > glyph.clip_x0);
    assert(glyph.clip_y1 > glyph.clip_y0);
    return true;
}

/// True if and only if `0 <= min_c < max_c <= 1`.
fn uv_ok(min_c: f32, max_c: f32) bool {
    if (min_c < 0) {
        return false;
    }
    if (min_c >= max_c) {
        return false;
    }
    if (max_c > 1) {
        return false;
    }
    assert(min_c >= 0);
    assert(min_c < max_c);
    return true;
}

/// Pen advance for `byte` in UI logical pixels. Precondition: `codepoint_ok(byte)`.
fn advance_at(byte: u8) f32 {
    assert(codepoint_ok(byte));
    const advance = metric_at(byte).advance;
    assert(advance > 0);
    return advance;
}

/// Metric record for `byte`. Precondition: `codepoint_ok(byte)`.
fn metric_at(byte: u8) Metric {
    assert(codepoint_ok(byte));
    const slot: u32 = byte - codepoint_first;
    assert(slot < codepoint_count);
    return baked.glyphs[slot];
}

/// Decodes `font_metrics.bin` at compile time into `baked`. The branch quota covers one
/// `read_metric` per codepoint.
fn decode_metrics() Baked {
    @setEvalBranchQuota(10000);
    assert(metrics_file.len == header_bytes + codepoint_count * record_bytes);
    var data: Baked = undefined;
    data.ascent = read_f32(16);
    data.descent = read_f32(20);
    data.line_height = read_f32(24);
    var slot: u32 = 0;
    while (slot < codepoint_count) : (slot += 1) {
        data.glyphs[slot] = read_metric(slot);
    }
    assert(data.line_height == data.ascent + data.descent);
    assert(slot == codepoint_count);
    return data;
}

/// Reads the record for `slot` (`byte - codepoint_first`). Asserts a positive advance and a
/// zero pad word, which pins the record layout from the module guide.
fn read_metric(slot: u32) Metric {
    assert(slot < codepoint_count);
    const at = header_bytes + slot * record_bytes;
    const metric: Metric = .{
        .advance = read_f32(at + 0),
        .left = read_f32(at + 4),
        .top = read_f32(at + 8),
        .width = read_f32(at + 12),
        .height = read_f32(at + 16),
        .u0 = read_f32(at + 20),
        .v0 = read_f32(at + 24),
        .u1 = read_f32(at + 28),
        .v1 = read_f32(at + 32),
    };
    assert(metric.advance > 0);
    assert(read_u32(at + 36) == 0);
    return metric;
}

/// Little-endian `u32` at byte `offset` of `metrics_file`.
fn read_u32(offset: u32) u32 {
    assert(offset + 4 <= metrics_file.len);
    return std.mem.readInt(u32, metrics_file[offset..][0..4], .little);
}

/// Little-endian `f32` at byte `offset` of `metrics_file`. Asserts the value is not NaN.
fn read_f32(offset: u32) f32 {
    const value: f32 = @bitCast(read_u32(offset));
    assert(value == value);
    return value;
}

/// Opaque white for test fixtures.
const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

/// Label box for placement tests.
const sample_rect: Rect = .{ .x = 10, .y = 20, .width = 400, .height = 64 };

const sample_clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };

/// A glyph that passes every `append` check, for capacity and rejection tests.
fn unit_glyph() Glyph {
    const glyph: Glyph = .{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .u0 = 0,
        .v0 = 0,
        .u1 = 1,
        .v1 = 1,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .clip_x0 = 0,
        .clip_y0 = 0,
        .clip_x1 = 1,
        .clip_y1 = 1,
    };
    assert(glyph.width > 0);
    assert(glyph.u0 < glyph.u1);
    return glyph;
}

// Locks the printable range: space is accepted; the bytes just outside it are rejected.
test "codepoint_ok accepts space and rejects the neighbors" {
    try std.testing.expect(codepoint_ok(' '));
    try std.testing.expect(!codepoint_ok(31));
    try std.testing.expect(!codepoint_ok(127));
}

// Locks that an empty string measures zero.
test "measure of an empty string is zero" {
    try std.testing.expectEqual(@as(f32, 0), measure(""));
}

// Locks that `measure` is the plain sum of per-glyph advances.
test "measure of Cycle is the five advances" {
    const expected =
        advance_at('C') + advance_at('y') + advance_at('c') + advance_at('l') + advance_at('e');
    try std.testing.expectEqual(expected, measure("Cycle"));
}

// Locks that a space emits no quad but still advances the pen. Centering " A" instead of "A"
// widens the text by one space advance, which moves the pen start left by half of it; the
// space then advances the full amount, so 'A' lands half a space advance to the right.
test "space places no quad and a positive pen delta" {
    var blank = GlyphList.init();
    place(&blank, " ", sample_rect, white, sample_clip);
    try std.testing.expectEqual(@as(u32, 0), blank.count);
    var alone = GlyphList.init();
    place(&alone, "A", sample_rect, white, sample_clip);
    var spaced = GlyphList.init();
    place(&spaced, " A", sample_rect, white, sample_clip);
    try std.testing.expectEqual(@as(u32, 1), alone.count);
    try std.testing.expectEqual(@as(u32, 1), spaced.count);
    const delta = spaced.items[0].x - alone.items[0].x;
    try std.testing.expect(delta > 0);
    try std.testing.expectApproxEqAbs(advance_at(' ') * 0.5, delta, 0.0001);
}

// Locks one quad per ink glyph, and UVs strictly inside the unit square (the half-texel inset
// keeps them off the atlas border).
test "Patchwork places nine quads inside the unit square" {
    var list = GlyphList.init();
    place(&list, "Patchwork", sample_rect, white, sample_clip);
    try std.testing.expectEqual(@as(u32, 9), list.count);
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const glyph = list.items[index];
        try std.testing.expect(glyph.u0 > 0);
        try std.testing.expect(glyph.u1 < 1);
        try std.testing.expect(glyph.u0 < glyph.u1);
        try std.testing.expect(glyph.v0 > 0);
        try std.testing.expect(glyph.v1 < 1);
        try std.testing.expect(glyph.v0 < glyph.v1);
    }
}

// Locks that the append after `glyph_cap` quads fails with `error.ListFull`.
test "a full glyph list returns ListFull" {
    var list = GlyphList.init();
    var index: u32 = 0;
    while (index < glyph_cap) : (index += 1) {
        try list.append(unit_glyph());
    }
    try std.testing.expectError(error.ListFull, list.append(unit_glyph()));
    try std.testing.expectEqual(glyph_cap, list.count);
}

// Locks that a non-positive width or height is rejected and leaves the list unchanged.
test "a non-positive edge returns EdgeNotPositive" {
    var list = GlyphList.init();
    var glyph = unit_glyph();
    glyph.width = 0;
    try std.testing.expectError(error.EdgeNotPositive, list.append(glyph));
    glyph = unit_glyph();
    glyph.height = -1;
    try std.testing.expectError(error.EdgeNotPositive, list.append(glyph));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks the centering algebra from the module guide for a single glyph: horizontal centering
// uses the advance (not the ink width), vertical centering uses the line box, and `left` and
// `top` offset the quad from the pen and baseline. Also locks that `color` and `clip` are
// copied into the instance.
test "place centers a glyph on the line box" {
    var list = GlyphList.init();
    place(&list, "A", sample_rect, white, sample_clip);
    try std.testing.expectEqual(@as(u32, 1), list.count);
    const metric = metric_at('A');
    const pen_x = sample_rect.x + (sample_rect.width - metric.advance) * 0.5;
    const line_top = sample_rect.y + (sample_rect.height - baked.line_height) * 0.5;
    const baseline_y = line_top + baked.ascent;
    const glyph = list.items[0];
    try std.testing.expectApproxEqAbs(pen_x + metric.left, glyph.x, 0.0001);
    try std.testing.expectApproxEqAbs(baseline_y + metric.top, glyph.y, 0.0001);
    try std.testing.expectEqual(metric.width, glyph.width);
    try std.testing.expectEqual(metric.height, glyph.height);
    try std.testing.expectEqual(white.a, glyph.a);
    try std.testing.expectEqual(sample_clip.x1, glyph.clip_x1);
}

// Locks the half-texel UV inset from the module guide: every ink glyph's `u0, v0` is a texel
// center and `u1, v1` is a texel center one texel short of the glyph's far edge, so each is an
// integer texel index plus or minus 0.5. Atlas dimensions are powers of two, so the float
// products below are exact and the integer checks need no tolerance.
test "ink UVs sit on half-texel centers" {
    var checked: u32 = 0;
    for (baked.glyphs) |metric| {
        if (metric.width > 0) {
            const x0 = metric.u0 * @as(f32, atlas_width) - 0.5;
            const y0 = metric.v0 * @as(f32, atlas_height) - 0.5;
            const x1 = metric.u1 * @as(f32, atlas_width) + 0.5;
            const y1 = metric.v1 * @as(f32, atlas_height) + 0.5;
            try std.testing.expectEqual(@floor(x0), x0);
            try std.testing.expectEqual(@floor(y0), y0);
            try std.testing.expectEqual(@floor(x1), x1);
            try std.testing.expectEqual(@floor(y1), y1);
            try std.testing.expect(x0 >= 0);
            try std.testing.expect(y0 >= 0);
            try std.testing.expect(x1 <= @as(f32, atlas_width));
            try std.testing.expect(y1 <= @as(f32, atlas_height));
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}

// Locks the atlas-to-logical scale from the module guide: the glyph's texel extent is
// `(u1 - u0) * atlas_width + 1` (undoing the half-texel inset on both sides), and its logical
// quad size is half of that. This also pins the order of the width, height, and UV fields in
// the metrics record.
test "ink quads are half their texel size" {
    var checked: u32 = 0;
    for (baked.glyphs) |metric| {
        if (metric.width > 0) {
            const texel_w = (metric.u1 - metric.u0) * @as(f32, atlas_width) + 1;
            const texel_h = (metric.v1 - metric.v0) * @as(f32, atlas_height) + 1;
            try std.testing.expectEqual(texel_w * 0.5, metric.width);
            try std.testing.expectEqual(texel_h * 0.5, metric.height);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
}

//! Baked Noto Sans coverage atlas, metrics decoding, and runtime glyph layout.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In immediate and retained GPU user interfaces, rendering text has historically been divided
//! into two problematic extremes:
//! - **Runtime Vector Font Parsing (FreeType, HarfBuzz, Fontdue):**
//!   Parsing TrueType tables, decoding quadratic Bézier outlines, and rasterizing glyphs into a
//!   dynamic texture atlas on the main UI frame path causes latency spikes (jank), allocator
//!   churn, heap fragmentation, and non-deterministic cache behavior. On constrained targets
//!   (such as `wasm32-freestanding`), shipping a full TrueType parser bloats binary size.
//! - **Multi-Channel Signed Distance Fields (MSDF):**
//!   While MSDF provides scalability, it introduces artifacts at small UI text sizes (12-16 px),
//!   requires expensive fragment shader evaluation (median of three color channels plus
//!   screen-space derivative antialiasing), and requires multi-channel textures (3-4 bytes/texel).
//!
//! **Patchwork's Baked Coverage Architecture:**
//! - **Ahead-of-Time Pre-Rasterization:** `scripts/bake_font.zig` executes once during development,
//!   rasterizing printable ASCII (codepoints 32..126) at 32 px per em into a single 512 x 256
//!   single-channel (`r8unorm`) alpha coverage atlas (`src/font_atlas.bin`, exactly 131,072 bytes).
//! - **Pre-Scaled Metrics Table:** Glyph advances, bounding boxes, bearings, and normalized UV
//!   coordinates are precalculated and serialized into `src/font_metrics.bin` (3,832 bytes) at
//!   the target 16 px UI logical size (`pixel / 2`).
//! - **Zero Runtime Allocation:** Both binaries are compiled directly into linear memory via
//!   `@embedFile`. The frame path allocates zero bytes of dynamic heap memory and performs zero
//!   font parsing or scale division.
//! - **Separation of Concerns:** Quad faces (`quad.wgsl`) retain their 48-byte instance stride
//!   `(rect, fill, radius, hover, down, 0)`. Glyph quads (`glyph.wgsl`) use a separate 48-byte
//!   stride `(rect, uv_rect, color)`. Text does not carry an `Animator`, so static labels do not
//!   keep frame loops alive (0% idle CPU invariant).
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Frame Definitions:
//! - **Font Design Units (FUnits):** Integer coordinate grid defined in TrueType `head` table
//!   (`unitsPerEm = 1000`). Origin `(0, 0)` sits on font baseline with `+Y` pointing upwards.
//! - **Bake Pixel Space:** Rasterizer pixel grid at 32 px per em (`scale = 32 / 1000 = 0.032`).
//!   Flipped to Y-down during rasterization so `py = ceil(yMax * scale) - y * scale`.
//! - **UI Logical Screen Space:** 16 px logical size (`logical = pixel / 2 = 0.5 * bake_pixel`).
//!   Origin `(0, 0)` is at the top-left of the display or container. `+X` increases rightwards,
//!   and `+Y` increases downwards.
//! - **Normalized Texture Coordinates (UV):** Continuous domain `[0.0, 1.0] x [0.0, 1.0]` across
//!   the 512 x 256 atlas.
//!
//! ### Text Layout & Centering Analytical Algebra:
//! Given an inner bounding container rectangle `inner = (X, Y, W, H)` (e.g. widget border box
//! inset by container padding) and a string of ASCII characters `C_0, C_1, ..., C_{N-1}`:
//!
//! 1. **Horizontal Advance Accumulation:**
//!    ```text
//!    text_width = sum_{i=0}^{N-1} advance(C_i)
//!    ```
//!    Where `advance(C_i)` is the logical advance width stored in `Metric.advance`.
//!
//! 2. **Horizontal Centering:**
//!    The pen origin is centered within the container's available width:
//!    ```text
//!    pen_x = inner.x + (inner.width - text_width) * 0.5
//!    ```
//!
//! 3. **Vertical Baseline Alignment:**
//!    Font vertical extents are dictated by `ascent` (height of ink above baseline) and `descent`
//!    (depth of ink below baseline, stored as a positive scalar).
//!    ```text
//!    line_height = ascent + descent
//!    baseline_y  = inner.y + (inner.height - line_height) * 0.5 + ascent
//!    ```
//!
//! 4. **Per-Glyph Destination Rectangles:**
//!    For each character `C_i`, `left` is the horizontal bearing, and `top` is the vertical bearing
//!    (negative when ink extends upwards above the baseline):
//!    ```text
//!    dest_x = pen_x + left
//!    dest_y = baseline_y + top
//!    dest_w = width
//!    dest_h = height
//!    pen_x += advance
//!    ```
//!    If `width == 0` (such as ASCII 32 space), the pen advances, but no quad is emitted.
//!
//! ### Half-Texel UV Inset Derivation:
//! In WebGPU texture sampling, integer texel coordinates `(x, y)` in `[0, W-1] x [0, H-1]`
//! correspond to sampling sample centers at continuous coordinates `(x + 0.5, y + 0.5)`.
//! When mapping a sub-rectangle of the atlas `[x, x + w]` to normalized UV coordinates `[u0, u1]`:
//! Naive normalization `u0 = x / W` and `u1 = (x + w) / W` places the quad boundary directly on
//! texel edges. With bilinear filtering, sampling along the outer quad edge interpolates
//! across the boundary, bleeding unwritten texels or adjacent glyph ink across the gutter.
//!
//! To eliminate bilinear bleeding, UV coordinates are pre-inset by exactly half a texel:
//! ```text
//! u0 = (atlas_x + 0.5) / atlas_width       (= (atlas_x + 0.5) / 512.0)
//! v0 = (atlas_y + 0.5) / atlas_height      (= (atlas_y + 0.5) / 256.0)
//! u1 = (atlas_x + glyph_w - 0.5) / 512.0
//! v1 = (atlas_y + glyph_h - 0.5) / 256.0
//! ```
//! Because UVs are pre-inset in `font_metrics.bin`, the runtime layout and the WGSL fragment shader
//! evaluate normalized coordinates directly without runtime clamping or inset arithmetic.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### 1. `Glyph` Instance Layout (48 Bytes):
//! `Glyph` instances are sent to the GPU in Vertex Buffer 1. Marked as `extern struct` to guarantee
//! exact C ABI field ordering and alignment with zero compiler padding:
//!
//! ```text
//! +-----------------------------------+-----------------------------------+
//! | Byte Offset                       | Field & WGSL Vertex Attribute     |
//! +-----------------------------------+-----------------------------------+
//! |  0..15  (16 bytes, float32x4)     | Location 1: dest_rect (x,y,w,h)   |
//! | 16..31  (16 bytes, float32x4)     | Location 2: uv_rect (u0,v0,u1,v1) |
//! | 32..47  (16 bytes, float32x4)     | Location 3: color (r,g,b,a)       |
//! +-----------------------------------+-----------------------------------+
//! ```
//! Total size: exactly 48 bytes (`@sizeOf(Glyph) == 48`). Matches the 48-byte instance stride
//! of the face buffer, enabling vertex layout sharing while strictly separating shader logic.
//!
//! ### 2. `font_metrics.bin` Binary File Format:
//! Formatted as little-endian binary data totaling `32 + 95 * 40 = 3,832` bytes:
//!
//! - **Header (32 Bytes):**
//!   - Offset  0: `atlas_width` (u32 = 512)
//!   - Offset  4: `atlas_height` (u32 = 256)
//!   - Offset  8: `glyph_count` (u32 = 95)
//!   - Offset 12: `codepoint_first` (u32 = 32)
//!   - Offset 16: `ascent` (f32, logical pixels)
//!   - Offset 20: `descent` (f32, logical pixels, positive distance)
//!   - Offset 24: `line_height` (f32, = ascent + descent)
//!   - Offset 28: `pad` (u32 = 0)
//!
//! - **Records (95 records x 40 Bytes each = 3,800 Bytes):**
//!   Codepoint index `i = byte - 32` for ASCII 32 (' ') through 126 ('~'):
//!   - Offset  0: `advance` (f32) - Logical horizontal pen advance
//!   - Offset  4: `left` (f32)    - Horizontal bearing from pen to ink
//!   - Offset  8: `top` (f32)     - Vertical bearing from baseline to ink top (negative)
//!   - Offset 12: `width` (f32)   - Logical ink quad width
//!   - Offset 16: `height` (f32)  - Logical ink quad height
//!   - Offset 20: `u0` (f32)      - Normalized left texture coordinate (half-texel inset)
//!   - Offset 24: `v0` (f32)      - Normalized top texture coordinate (half-texel inset)
//!   - Offset 28: `u1` (f32)      - Normalized right texture coordinate (half-texel inset)
//!   - Offset 32: `v1` (f32)      - Normalized bottom texture coordinate (half-texel inset)
//!   - Offset 36: `pad` (u32 = 0) - Alignment padding to 40 bytes
//!
//! ### 3. `font_atlas.bin` Memory Layout:
//! Continuous array of `512 * 256 = 131,072` bytes (`r8unorm`).
//! Row-major ordering with 512 bytes per row. Because 512 is an exact multiple of 256
//! (`512 = 256 * 2`), it satisfies the WebGPU specification requirement for buffer-to-texture
//! copy operations (`bytesPerRow` alignment of 256 bytes).
//!
//! ## 4. State Machines & Data Flow
//!
//! ```text
//! [Scene.layout()]
//!       │
//!       ▼
//! [place_label()]  (Calculates border box inset by padding)
//!       │
//!       ▼
//! [font.place()]   (Measures text, computes pen_x & baseline_y, looks up metrics)
//!       │
//!       ▼
//! [GlyphList.append()] (Appends 48-byte Glyph to items array, bumps revision)
//!       │
//!       ▼
//! [UploadCursor.flags()] ─── revision != glyph_revision? ──► flag_glyphs = 4
//!       │                                                         │
//!       ▼                                                         ▼
//! [gpu.present()] ◄───────────────────────────────────────────────┘
//!       │
//!       ├─► [write_uploads()] (Writes glyph buffer if flag_glyphs and count > 0)
//!       │
//!       └─► [RenderPass]
//!             ├─► draw_quads()   (Draws 6 vertices * quad_count)
//!             └─► draw_glyphs()  (Draws 6 vertices * glyph_count)
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **WebAssembly Linear Memory Access:**
//!   In `src/web_exports.zig`, `atlas_ptr()` and `atlas_len()` expose the embedded atlas buffer
//!   directly to JavaScript without copying.
//! - **WebGPU Texture Copy Rules:**
//!   `shell.js` and `gpu_wgpu.zig` upload the atlas once during initialization using
//!   `queue.writeTexture`. The native backend utilizes `texture_usage_copy_dst = 0x2`
//!   (avoiding buffer `0x8` which represents `STORAGE_BINDING` on textures).
//! - **Two Pipeline Layouts with Shared Group 0:**
//!   WebGPU forbids cross-pipeline bind group sharing when pipelines use `layout: "auto"`.
//!   Both backends create explicit bind group layouts: `group0` (uniform buffer) is shared by
//!   `quadPipeline` and `glyphPipeline`; `group1` (atlas and sampler) binds to `glyphPipeline`.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Upper Bounds:**
//!   `glyph_cap = 256`: Hard limit on the number of glyph instances per frame.
//!   `text_cap = 64`: Hard limit on individual label string byte lengths.
//!   `codepoint_count = 95`: Closed printable ASCII domain `[32, 126]`.
//! - **Zero Runtime Allocation:** BSS static arrays for `items`, zero heap pointers.
//! - **Pairwise Defensive Assertions:**
//!   Bounds and validity checked at source, transformation, and submission.
//!   Every function has split assertions testing preconditions and invariants.

const std = @import("std");
const assert = std.debug.assert;

const metrics_file: []const u8 = @embedFile("font_metrics.bin");

/// Coverage atlas, 512 by 256, one `r8` byte per texel.
pub const atlas_bytes: []const u8 = @embedFile("font_atlas.bin");

/// Glyph shader. Separate from `quad.wgsl` so the face instance stays 48 bytes.
pub const shader_file: []const u8 = @embedFile("glyph.wgsl");

pub const atlas_width: u32 = 512;
pub const atlas_height: u32 = 256;

/// Hard cap on glyph quads queued for one frame.
pub const glyph_cap: u32 = 256;

/// Hard cap on a label string, in bytes. The demo strings are shorter.
pub const text_cap: u32 = 64;

/// Byte size of one glyph quad. Twelve floats, no trailing pad.
pub const glyph_stride: u32 = 48;

/// Total number of printable ASCII codepoints supported (32 through 126 inclusive).
const codepoint_count: u32 = 95;

/// First printable ASCII codepoint: space (ASCII 32, U+0020).
const codepoint_first: u8 = 32;

/// Byte size of the font_metrics.bin header (8 u32/f32 fields * 4 bytes = 32 bytes).
const header_bytes: u32 = 32;

/// Byte size of each glyph metric record in font_metrics.bin (10 fields * 4 bytes = 40 bytes).
const record_bytes: u32 = 40;

/// One instanced glyph quad submitted to the GPU in Vertex Buffer 1.
///
/// Marked as `extern struct` to guarantee exact C ABI memory layout with no compiler padding.
/// Memory Layout (48 bytes total):
/// - Offset  0: `x` (f32) - Left destination edge in UI logical pixels.
/// - Offset  4: `y` (f32) - Top destination edge in UI logical pixels.
/// - Offset  8: `width` (f32) - Rendered quad width in UI logical pixels.
/// - Offset 12: `height` (f32) - Rendered quad height in UI logical pixels.
/// - Offset 16: `u0` (f32) - Normalized left texture coordinate in [0.0, 1.0] (half-texel inset).
/// - Offset 20: `v0` (f32) - Normalized top texture coordinate in [0.0, 1.0] (half-texel inset).
/// - Offset 24: `u1` (f32) - Normalized right texture coordinate in [0.0, 1.0] (half-texel inset).
/// - Offset 28: `v1` (f32) - Normalized bottom texture coordinate in [0.0, 1.0] (half-texel inset).
/// - Offset 32: `r` (f32) - Straight red color component in [0.0, 1.0].
/// - Offset 36: `g` (f32) - Straight green color component in [0.0, 1.0].
/// - Offset 40: `b` (f32) - Straight blue color component in [0.0, 1.0].
/// - Offset 44: `a` (f32) - Base alpha component before coverage modulation in [0.0, 1.0].
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

/// Pre-scaled glyph metrics in UI logical pixels (16 px ppem = 32 px bake / 2).
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

/// Statically bounded list of glyph instances to be submitted in the second GPU draw pass.
///
/// Follows TigerStyle invariants: zero dynamic heap allocation, bounded by `glyph_cap` (256).
/// Tracks an incrementing `revision` counter that bumps whenever items are appended or cleared,
/// allowing `UploadCursor` to detect changes and emit `flag_glyphs` dirty upload flags.
pub const GlyphList = struct {
    items: [glyph_cap]Glyph,
    count: u32,
    revision: u32,

    /// Initializes an empty glyph list with zeroed memory.
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

    /// Explicit error set for glyph appending.
    pub const AppendError = error{
        EdgeNotPositive,
        UvOutOfRange,
        ListFull,
    };

    /// Appends one ink quad to the glyph list.
    ///
    /// Preconditions and Error Handling:
    /// - `error.EdgeNotPositive`: Returned if either `glyph.width <= 0` or `glyph.height <= 0`.
    ///   Degenerate or inverted destination boxes are rejected.
    /// - `error.UvOutOfRange`: Returned if texture coordinates do not satisfy `0 <= u0 < u1 <= 1`
    ///   or `0 <= v0 < v1 <= 1`.
    /// - `error.ListFull`: Returned if `self.count == glyph_cap` (256).
    ///
    /// Memory & Revision:
    /// - Copies all twelve 32-bit floats into `self.items[self.count]` (zero padding bytes).
    /// - Increments both `count` and `revision` on success.
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
        if (self.count == glyph_cap) {
            return error.ListFull;
        }
        assert(glyph.width > 0);
        assert(glyph.u0 < glyph.u1);
        self.items[self.count] = .{
            .x = glyph.x,
            .y = glyph.y,
            .width = glyph.width,
            .height = glyph.height,
            .u0 = glyph.u0,
            .v0 = glyph.v0,
            .u1 = glyph.u1,
            .v1 = glyph.v1,
            .r = glyph.r,
            .g = glyph.g,
            .b = glyph.b,
            .a = glyph.a,
        };
        self.count += 1;
        self.revision += 1;
        assert(self.items[self.count - 1].width > 0);
        assert(self.count <= glyph_cap);
    }

    /// Resets item count to zero and increments `revision`.
    ///
    /// Bumping revision even when the list was already empty guarantees that any frame
    /// where text was cleared causes `UploadCursor` to detect the revision change and
    /// clear old GPU instance data.
    pub fn clear(self: *GlyphList) void {
        assert(self.count <= glyph_cap);
        self.count = 0;
        self.revision += 1;
        assert(self.count == 0);
        assert(self.revision >= 1);
    }
};

comptime {
    assert(@sizeOf(Glyph) == 48);
    assert(@alignOf(Glyph) >= 4);
    assert(glyph_stride == 48);
    assert(glyph_cap == 256);
    assert(text_cap == 64);
    assert(atlas_width == 512);
    assert(atlas_height == 256);
    assert(atlas_bytes.len == 131072);
    assert(metrics_file.len == header_bytes + codepoint_count * record_bytes);
    assert(shader_file.len >= 1);
    assert(baked.line_height == baked.ascent + baked.descent);
    assert(baked.ascent > 0);
    assert(baked.descent > 0);
}

const baked: Baked = decode_metrics();

/// True for a printable ASCII byte, including space. 31 and 127 are outside.
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

/// Centers `text` in `rect` and appends one quad per glyph with positive width.
///
/// The caller must have left at least `text.len` free slots. Space advances the
/// pen and appends nothing. `append` after that capacity check uses
/// `catch unreachable`.
pub fn place(list: *GlyphList, text: []const u8, rect: Rect, color: Color) void {
    assert(text.len <= text_cap);
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
            }) catch unreachable;
        }
        pen_x += metric.advance;
    }
    assert(index == count);
    assert(list.count <= glyph_cap);
}

/// Validates normalized texture coordinates.
/// Returns true if and only if 0.0 <= min_c < max_c <= 1.0.
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

/// Looks up the horizontal pen advance for a single printable ASCII codepoint.
/// Returns advance in UI logical pixels. Precondition: `codepoint_ok(byte)` is true.
fn advance_at(byte: u8) f32 {
    assert(codepoint_ok(byte));
    const advance = metric_at(byte).advance;
    assert(advance > 0);
    return advance;
}

/// Looks up the metric record for a given ASCII byte.
/// Precondition: `codepoint_ok(byte)` is true.
fn metric_at(byte: u8) Metric {
    assert(codepoint_ok(byte));
    const slot: u32 = byte - codepoint_first;
    assert(slot < codepoint_count);
    return baked.glyphs[slot];
}

/// Decodes font_metrics.bin at compile time into the global `baked` constant.
///
/// Sets evaluation branch quota to 10000 to allow loop iteration over all 95 glyph records.
/// Verifies binary length, line height invariant, and returns the structured `Baked` record.
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

/// Reads a 40-byte metric record at the specified slot index [0..94].
/// Asserts that horizontal advance is strictly positive and trailing padding is zero.
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

/// Decodes a 32-bit little-endian unsigned integer from `metrics_file` at `offset`.
fn read_u32(offset: u32) u32 {
    assert(offset + 4 <= metrics_file.len);
    return std.mem.readInt(u32, metrics_file[offset..][0..4], .little);
}

/// Decodes a 32-bit little-endian IEEE-754 float from `metrics_file` at `offset`.
/// Asserts that the decoded float is not NaN (`value == value`).
fn read_f32(offset: u32) f32 {
    const value: f32 = @bitCast(read_u32(offset));
    assert(value == value);
    return value;
}

/// Constant white color for test fixtures.
const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };

/// Sample bounding rectangle for test assertions.
const sample_rect: Rect = .{ .x = 10, .y = 20, .width = 400, .height = 64 };

/// Constructs a valid 1x1 unit glyph with full UV range [0, 1] for queue capacity testing.
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
    };
    assert(glyph.width > 0);
    assert(glyph.u0 < glyph.u1);
    return glyph;
}

// Verifies ASCII boundaries: space (32) accepted, control (31) and DEL (127) rejected.
test "codepoint_ok accepts space and rejects the neighbors" {
    try std.testing.expect(codepoint_ok(' '));
    try std.testing.expect(!codepoint_ok(31));
    try std.testing.expect(!codepoint_ok(127));
}

// Verifies that an empty string has zero accumulated advance width.
test "measure of an empty string is zero" {
    try std.testing.expectEqual(@as(f32, 0), measure(""));
}

// Verifies that `measure("Cycle")` exactly equals the sum of individual character advances.
test "measure of Cycle is the five advances" {
    const expected =
        advance_at('C') + advance_at('y') + advance_at('c') + advance_at('l') + advance_at('e');
    try std.testing.expectEqual(expected, measure("Cycle"));
}

// Verifies space handling: space emits no ink quads, but advances the pen.
// When placing "A" vs " A" in the same centered box:
// Both strings are centered: pen_x = rect.x + (rect.w - text_w)*0.5.
// " A" has text_w = advance(' ') + advance('A').
// The pen starts (advance(' ')*0.5) to the left, but then space advances it by advance(' '),
// resulting in 'A' landing exactly (advance(' ') * 0.5) further right.
test "space places no quad and a positive pen delta" {
    var blank = GlyphList.init();
    place(&blank, " ", sample_rect, white);
    try std.testing.expectEqual(@as(u32, 0), blank.count);
    var alone = GlyphList.init();
    place(&alone, "A", sample_rect, white);
    var spaced = GlyphList.init();
    place(&spaced, " A", sample_rect, white);
    try std.testing.expectEqual(@as(u32, 1), alone.count);
    try std.testing.expectEqual(@as(u32, 1), spaced.count);
    const delta = spaced.items[0].x - alone.items[0].x;
    try std.testing.expect(delta > 0);
    try std.testing.expectApproxEqAbs(advance_at(' ') * 0.5, delta, 0.0001);
}

// Verifies that placing "Patchwork" produces exactly 9 ink quads whose UV coordinates
// lie strictly within the interior of the unit square [0, 1] due to half-texel insetting.
test "Patchwork places nine quads inside the unit square" {
    var list = GlyphList.init();
    place(&list, "Patchwork", sample_rect, white);
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

// Verifies that `GlyphList` rejects appends beyond `glyph_cap` (256) with `error.ListFull`.
test "a full glyph list returns ListFull" {
    var list = GlyphList.init();
    var index: u32 = 0;
    while (index < glyph_cap) : (index += 1) {
        try list.append(unit_glyph());
    }
    try std.testing.expectError(error.ListFull, list.append(unit_glyph()));
    try std.testing.expectEqual(glyph_cap, list.count);
}

// Verifies that non-positive glyph width or height is rejected with `error.EdgeNotPositive`.
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

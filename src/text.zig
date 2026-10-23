//! Text: three embedded faces, measurement, and glyph placement through the glyph cache.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Pipeline
//! ```text
//! compile time  parse the three embedded faces (text/ttf.zig): tables, cmap, ASCII ids
//! frame         text.place(cx, style, utf8, rect, clip, options)
//!                 decode UTF-8 (U+FFFD per invalid byte) -> glyph id -> advance
//!                 cx.text.glyph(face, glyph, size_q)            (text/cache.zig)
//!                   hit: entry      miss: rasterize within the frame budget (text/raster.zig)
//!                 append one draw.Glyph per inked glyph with the entry's atlas UVs
//! ```
//! The module map: `text/ttf.zig` reads the fonts, `text/raster.zig` scan-converts,
//! `text/cache.zig` owns the atlas, `text/layout.zig` measures and places, and
//! `text/mono.zig` is the monospace grid a code editor draws through (one column per
//! codepoint, a per-frame ASCII entry table, the same instances as `place`).
//!
//! ## 2. Faces
//! `Face.sans` is Noto Sans Regular, `Face.sans_bold` Noto Sans Bold, and `Face.mono` Noto
//! Sans Mono Regular, all SIL OFL 1.1 (`text/fonts/OFL.txt`). Both targets `@embedFile` them
//! from `text/fonts/`, so the browser needs no font fetch and a consumer project built with
//! `addApp` gets them with the library.
//!
//! ## 3. Units
//! `Style.size` is the em size in logical pixels; `measure` and the pen advance in logical
//! pixels, independent of the display scale, so a scale change never needs a layout pass.
//! Placement snaps each glyph origin to the device pixel grid; see `text/layout.zig`.
//!
//! ## 4. Scope
//! No kerning, shaping, ligatures, right-to-left, colour fonts, fallback chains, hinting, or
//! subpixel antialiasing. A codepoint a face does not map draws its `.notdef` box.
//!
//! ## 5. TigerStyle Invariants
//! - `byte_cap` bounds the bytes of one `place` or `place_runs` call, `run_cap` its runs.
//! - All cache and scratch state lives in `draw.Context`; nothing here allocates.

const std = @import("std");
const assert = std.debug.assert;
const layout = @import("text/layout.zig");

pub const ttf = @import("text/ttf.zig");
pub const raster = @import("text/raster.zig");
pub const cache = @import("text/cache.zig");
pub const mono = @import("text/mono.zig");
pub const Cache = cache.Cache;
pub const Mono = mono.Mono;

/// Bytes of UTF-8 one `place` or `place_runs` call may lay out.
pub const byte_cap: u32 = 4096;
/// Runs one `place_runs` call may lay out.
pub const run_cap: u32 = 8;
/// Largest `Style.size` in logical pixels.
pub const size_max: f32 = 512;

/// The embedded faces. The value is the face's index into `fonts` and its cache key field.
pub const Face = enum(u8) {
    sans = 0,
    sans_bold = 1,
    mono = 2,
};

/// The parsed faces, indexed by `Face`. Parsed at compile time.
pub const fonts: [3]ttf.Font = .{
    ttf.parse(@embedFile("text/fonts/NotoSans-Regular.ttf")),
    ttf.parse(@embedFile("text/fonts/NotoSans-Bold.ttf")),
    ttf.parse(@embedFile("text/fonts/NotoSansMono-Regular.ttf")),
};

/// How a run of text looks. `size` is the em size in logical pixels; `color` is straight
/// RGBA, and the shader multiplies its alpha by the coverage sample.
pub const Style = struct {
    face: Face,
    size: f32,
    color: [4]f32,
};

/// Placement of the text's extent inside the rect on one axis.
pub const Align = enum {
    start,
    center,
    end,
};

/// `ellipsis` cuts text wider than the rect and ends it with U+2026 so it fits.
pub const Options = struct {
    align_x: Align,
    align_y: Align,
    ellipsis: bool,
};

/// One styled span of a line for `place_runs`.
pub const Run = struct {
    style: Style,
    bytes: []const u8,
};

/// Width of `utf8` in `style`, in logical pixels: the sum of its advances. O(bytes); never
/// touches the cache.
pub const measure = layout.measure;

/// The codepoint boundary of `utf8` nearest to `x` logical pixels from the pen start. Pure.
pub const index_at = layout.index_at;

/// Lays out `utf8` in `rect` and appends one `draw.Glyph` per inked glyph to `cx`, each with
/// `clip`. See `text/layout.zig`.
pub const place = layout.place;

/// Lays out `runs` as one line sharing a baseline. See `text/layout.zig`.
pub const place_runs = layout.place_runs;

/// The face record of `face`.
pub fn font_of(face: Face) *const ttf.Font {
    return &fonts[@backingInt(face)];
}

/// The cache size key of an em of `size` logical pixels at `scale_120`: quarter device px.
pub fn size_key(size: f32, scale_120: u32) u32 {
    assert(size > 0);
    assert(size <= size_max);
    assert(scale_120 >= 1);
    const quarters = @round(size * @as(f32, @floatFromInt(scale_120)) / 30);
    const key: u32 = @intFromFloat(@max(1, quarters));
    assert(key <= cache.size_q_max);
    return key;
}

comptime {
    assert(fonts.len == @typeInfo(Face).@"enum".field_names.len);
    assert(byte_cap == 4096);
    assert(size_max * 1920 / 30 <= cache.size_q_max);
    for (fonts) |font| {
        assert(font.units_per_em == 1000);
        assert(font.cmap_format == 12);
    }
}

test {
    _ = ttf;
    _ = mono;
    _ = raster;
    _ = cache;
    _ = layout;
}

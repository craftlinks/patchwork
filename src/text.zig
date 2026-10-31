//! Text: embedded faces, measurement, and glyph placement through the glyph cache.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Pipeline
//! ```text
//! compile time  parse the embedded faces (text/ttf.zig): tables, cmap, ASCII ids
//! frame         text.place(cx, style, utf8, rect, clip, options)
//!               text.place_wrapped(cx, style, utf8, rect, clip, wrap_options)
//!                 text.Lines breaks the text into lines (text/layout.zig, 2b), then each
//!                 line is placed as below on its own snapped baseline
//!                 decode UTF-8 (U+FFFD per invalid byte) -> glyph id -> advance
//!                 cx.text.glyph(face, glyph, size_q)            (text/cache.zig)
//!                   hit: entry      miss: rasterize within the frame budget (text/raster.zig)
//!                 append one draw.Glyph per inked glyph with the entry's atlas UVs
//!               text.place_outlines(cx, ...)         the same layout, a draw.Fill per glyph
//!                 (text/layout.zig, 3b); text.Glyphs yields each glyph's pen for a caller's loop
//!               text.icon(cx, face, codepoint, size, rect, clip, color)
//!                 one glyph, its ink centred on rect               (text/layout.zig, 3a)
//! ```
//! The module map: `text/ttf.zig` reads the fonts, `text/raster.zig` scan-converts,
//! `text/cache.zig` owns the atlas, `text/layout.zig` measures and places, and
//! `text/mono.zig` is the monospace grid a code editor draws through (one column per
//! codepoint, a per-frame ASCII entry table, the same instances as `place`).
//!
//! ## 2. Faces
//! `Face.sans` is Noto Sans Regular, `Face.sans_bold` Noto Sans Bold, and `Face.mono` Noto
//! Sans Mono Regular, all SIL OFL 1.1 (`text/fonts/OFL.txt`). Both targets `@embedFile` them
//! through the `patchwork_fonts` module, so the browser needs no font fetch and a consumer
//! project built with `addApp` gets them with the library.
//!
//! ## 2a. Subsets
//! The build subsets the three faces in `text/fonts/` to `AppOptions.font_ranges`
//! (`text/subset.zig` through `tools/subset.zig`; by default Basic Latin, Latin-1, Latin
//! Extended-A, and UI punctuation), and `patchwork_fonts` embeds the results, with the ranges
//! and `subset`. Both targets get the same bytes, so native and browser draw the same. A
//! codepoint outside the ranges maps to glyph 0 and draws `.notdef`, as an unmapped one
//! always has; `font_ranges = null` embeds the full faces.
//!
//! ## 2b. App Faces
//! An app adds up to five faces of its own (`AppOptions.fonts`, `build.zig`): any TrueType
//! face with `glyf` outlines, any `units_per_em` in `[16, 16384]`, and a format 12 or 4
//! `cmap`, subset like the library's. `patchwork_fonts` generates `Face` per app: `sans`,
//! `sans_bold`, and `mono` at 0, 1, and 2, then the app's names in order, so the library's
//! cache keys and tests keep their values and a face tag type-checks only in an app that
//! declared it. `fonts` is parsed from `font_data.data`, one entry per tag. Eight faces in all
//! is what the glyph cache key holds (`face_cap`). The library's own code names only its three
//! faces and never switches over `Face` exhaustively.
//!
//! ## 3. Units
//! `Style.size` is the em size in logical pixels; `measure` and the pen advance in logical
//! pixels, independent of the display scale, so a scale change never needs a layout pass.
//! Placement snaps each glyph origin to the device pixel grid; see `text/layout.zig`.
//!
//! ## 4. Scope
//! No kerning, shaping, ligatures, right-to-left, colour fonts, fallback chains, hinting, or
//! subpixel antialiasing. A codepoint a face does not map (or the subset dropped) draws its
//! `.notdef` box.
//!
//! ## 5. TigerStyle Invariants
//! - `byte_cap` bounds the bytes of one `place`, `place_runs`, or wrapped call, `run_cap` its
//!   runs.
//! - All cache and scratch state lives in `draw.Context`; nothing here allocates.

const std = @import("std");
const assert = std.debug.assert;
const layout = @import("text/layout.zig");

pub const ttf = @import("text/ttf.zig");
pub const raster = @import("text/raster.zig");
pub const cache = @import("text/cache.zig");
pub const mono = @import("text/mono.zig");
pub const faces = @import("text/faces.zig");
pub const Cache = cache.Cache;
pub const Mono = mono.Mono;
pub const FaceSet = faces.FaceSet;

/// Bytes of UTF-8 one `place` or `place_runs` call may lay out.
pub const byte_cap: u32 = 4096;
/// Runs one `place_runs` call may lay out.
pub const run_cap: u32 = 64;
/// Largest `Style.size` in logical pixels.
pub const size_max: f32 = 512;

/// The faces' bytes: the build's subsets of `text/fonts/` and of the app's faces (section 2b).
pub const font_data = @import("patchwork_fonts");

/// The embedded faces, generated per app (section 2b): `sans`, `sans_bold`, and `mono` at 0,
/// 1, and 2, then the app's own. The value is the face's index into `fonts` and its cache key
/// field.
pub const Face = font_data.Face;

/// Faces the glyph cache key holds (`text/cache.zig`, section 2).
pub const face_cap: u32 = 8;

/// The parsed faces, indexed by `Face`. Parsed at compile time.
pub const fonts: [font_data.data.len]ttf.Font = parsed: {
    var list: [font_data.data.len]ttf.Font = undefined;
    for (font_data.data, &list) |bytes, *font| font.* = ttf.parse(bytes);
    break :parsed list;
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

/// Where wrapped text sits in its rect: each line by `align_x`, the block of lines by
/// `align_y`. There is no ellipsis: text taller than the rect is clipped.
pub const WrapOptions = struct {
    align_x: Align = .start,
    align_y: Align = .start,
};

/// A byte of one run of a text: `runs[run].bytes[byte]`, or the end of that run.
pub const Position = struct {
    run: u32,
    byte: u32,
};

/// One wrapped line: the bytes `start .. end` (hanging spaces and the hard break excluded)
/// and their width in logical pixels. An empty line has `start == end` and width 0.
pub const Line = struct {
    start: Position,
    end: Position,
    width: f32,
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

/// The line pitch of `style` in whole logical pixels: ascent, descent, and line gap, rounded
/// up. Pure. See `text/layout.zig`, section 2b.
pub const line_height = layout.line_height;

/// The greedy line iterator over runs and a width. Pure. See `text/layout.zig`, section 2b.
pub const Lines = layout.Lines;

/// The height `utf8` in `style` takes wrapped to `width`: lines times the line height. Pure.
pub const measure_wrapped = layout.measure_wrapped;

/// `measure_wrapped` for runs: the block's line height is the tallest run's. Pure.
pub const measure_runs_wrapped = layout.measure_runs_wrapped;

/// Lays out `utf8` wrapped to `rect.width`, one snapped baseline per line; lines outside
/// `clip` append nothing. See `text/layout.zig`, section 2b.
pub const place_wrapped = layout.place_wrapped;

/// `place_wrapped` for runs: a run boundary is not a break opportunity.
pub const place_runs_wrapped = layout.place_runs_wrapped;

/// Draws one glyph with its ink box centred on a rect: an icon from an icon face. A codepoint
/// the face does not map draws nothing and is counted in the overflow report. See
/// `text/layout.zig`, section 3a.
pub const icon = layout.icon;

/// One glyph's outline into a `draw.fill.Builder`. See `text/layout.zig`, section 3b.
pub const contours = layout.contours;

/// The codepoints of a line or a wrapped block with their unsnapped pens. Pure.
pub const Glyphs = layout.Glyphs;
pub const Glyph = layout.Glyph;

/// `place` with each glyph a `draw.Fill` shape: display text that rotates, grows past
/// `size_max`, and morphs. The atlas stays the default for UI text; the caller chooses.
pub const place_outlines = layout.place_outlines;
pub const place_runs_outlines = layout.place_runs_outlines;
pub const place_wrapped_outlines = layout.place_wrapped_outlines;
pub const place_runs_wrapped_outlines = layout.place_runs_wrapped_outlines;

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
    assert(fonts.len <= face_cap);
    assert(@backingInt(Face.sans) == 0);
    assert(@backingInt(Face.sans_bold) == 1);
    assert(@backingInt(Face.mono) == 2);
    assert(byte_cap == 4096);
    assert(size_max * 1920 / 30 <= cache.size_q_max);
    for (fonts) |font| {
        assert(font.units_per_em >= 16);
        assert(font.units_per_em <= 16384);
        assert(font.cmap_format == 12 or font.cmap_format == 4);
    }
}

test {
    _ = ttf;
    _ = mono;
    _ = faces;
    _ = @import("text/subset.zig");
    _ = raster;
    _ = cache;
    _ = layout;
}

// Locks the embedded faces (section 2a): the library's build embeds the default subsets, every
// printable ASCII codepoint, the ellipsis `place` cuts with, the replacement character, and
// "Jürgen Köhler · Café" (the live patch) map to inked or spacing glyphs, and a codepoint
// outside the ranges (U+0416) draws `.notdef`.
test "the embedded faces are the default subsets and cover the UI text" {
    try std.testing.expect(font_data.subset);
    try std.testing.expectEqual(@as(u21, 0x20), font_data.ranges[0][0]);
    for (&fonts) |*font| {
        try std.testing.expect(font.glyph_count < 400);
        var codepoint: u21 = 0x20;
        while (codepoint <= 0x7E) : (codepoint += 1) {
            try std.testing.expect(ttf.glyph_id(font, codepoint) != 0);
        }
        const name = "Jürgen Köhler · Café";
        var index: u32 = 0;
        while (index < name.len) {
            try std.testing.expect(ttf.glyph_id(font, layout.decode(name, &index)) != 0);
        }
        try std.testing.expect(ttf.glyph_id(font, layout.ellipsis_char) != 0);
        try std.testing.expect(ttf.glyph_id(font, layout.replacement_char) != 0);
        try std.testing.expectEqual(@as(u16, 0), ttf.glyph_id(font, 0x0416));
    }
}

// Locks the generated faces without app faces (section 2b): the library's own build, like
// every app that adds none, gets exactly `sans`, `sans_bold`, and `mono` at 0, 1, and 2, each
// keeping the library's ranges.
test "without app faces Face is the library's three" {
    const names = @typeInfo(Face).@"enum".field_names;
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqual(@as(usize, 3), font_data.names.len);
    for (names, font_data.names, [_][]const u8{ "sans", "sans_bold", "mono" }) |tag, name, want| {
        try std.testing.expectEqualStrings(want, tag);
        try std.testing.expectEqualStrings(want, name);
    }
    for (font_data.face_ranges) |kept| try std.testing.expectEqual(font_data.ranges.ptr, kept.ptr);
}

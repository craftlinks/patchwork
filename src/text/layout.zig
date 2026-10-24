//! Line layout: UTF-8 decoding, measurement, alignment, ellipsis, and device-pixel snapping.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. UTF-8
//! `decode` reads one codepoint and advances the index. Any byte that does not start a
//! well-formed sequence (a stray continuation, a truncated or overlong sequence, a surrogate,
//! or a value above U+10FFFF) yields U+FFFD and advances one byte, so every byte is consumed
//! exactly once and a loop over a slice is bounded by its length.
//!
//! ## 2. Line Algebra (logical pixels)
//! For runs `R_i` with em sizes `s_i` and faces of `units_per_em` `u_i`:
//! ```text
//! width    = sum over codepoints of advance_units * s_i / u_i
//! ascent   = max_i(ascent_units_i * s_i / u_i)       descent likewise (positive)
//! pen_x    = rect.x + offset(align_x, rect.width - width)
//! top      = rect.y + offset(align_y, rect.height - (ascent + descent))
//! baseline = top + ascent
//! offset(start, gap) = 0, offset(center, gap) = gap / 2, offset(end, gap) = gap
//! ```
//! Mixed sizes share the one baseline. With `ellipsis` and `width > rect.width`, the line is
//! cut before the first codepoint at which the kept width plus the ellipsis advance (in the
//! style of the run being cut) would exceed `rect.width`, and U+2026 is appended; the cut
//! width replaces `width` in the alignment. If not even the ellipsis fits, nothing is drawn.
//!
//! ## 3. Device Snapping
//! With `s = cx.text.device_scale()` (`scale_120 / 120`, times the glyph zoom inside a canvas,
//! `text/cache.zig` section 2a) and the cache entry's raster pixel box (`left`, `top`, `width`,
//! `height`, rasterized at `raster_q`; `k = size_q / raster_q`, 1 unless the glyph was clamped):
//! ```text
//! x_dev = round(pen_x * s) + left * k         y_dev = round(baseline * s) - top * k
//! rect  = (x_dev, y_dev, width * k, height * k) / s
//! uv    = (atlas_x, atlas_y, atlas_x + width, atlas_y + height) / atlas_side
//! ```
//! The pen itself advances unsnapped, so `place` and `measure` agree. Because the projection
//! maps logical pixels to device pixels by exactly `s` (`draw.ortho_y_down`), every quad edge
//! lands on a device pixel edge and each fragment center samples one texel center: the UVs
//! need no half-texel inset and the gutter is never read.
//!
//! ## 4. TigerStyle Invariants
//! - Loops are bounded by `text.byte_cap` bytes and `text.run_cap` runs.
//! - `measure` is pure; only `place_runs` touches the cache, through `cx.text`.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const ttf = @import("ttf.zig");
const cache = @import("cache.zig");
const types = @import("../draw/types.zig");
const draw = @import("../draw.zig");

/// The codepoint drawn for invalid UTF-8.
pub const replacement_char: u21 = 0xFFFD;
/// The codepoint that ends a cut line.
pub const ellipsis_char: u21 = 0x2026;

/// Decodes the codepoint at `index.*` and advances it. See the module guide, section 1.
pub fn decode(bytes: []const u8, index: *u32) u21 {
    const at = index.*;
    assert(at < bytes.len);
    const lead = bytes[at];
    index.* = at + 1;
    if (lead < 0x80) {
        return lead;
    }
    const length: u32 = if (lead >= 0xC2 and lead <= 0xDF)
        2
    else if (lead >= 0xE0 and lead <= 0xEF)
        3
    else if (lead >= 0xF0 and lead <= 0xF4)
        4
    else
        return replacement_char;
    if (at + length > bytes.len) {
        return replacement_char;
    }
    var value: u32 = lead & (@as(u32, 0x7F) >> @intCast(length));
    var position: u32 = 1;
    while (position < length) : (position += 1) {
        const byte = bytes[at + position];
        if (byte & 0xC0 != 0x80) {
            return replacement_char;
        }
        value = value << 6 | (byte & 0x3F);
    }
    const minimum: u32 = switch (length) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (value < minimum) return replacement_char;
    if (value > 0x10FFFF) return replacement_char;
    if (value >= 0xD800 and value <= 0xDFFF) return replacement_char;
    index.* = at + length;
    assert(index.* <= bytes.len);
    return @intCast(value);
}

/// Width of `utf8` in `style`, in logical pixels. See the module guide, section 2.
pub fn measure(style: text.Style, utf8: []const u8) f32 {
    assert(utf8.len <= text.byte_cap);
    assert(style.size > 0);
    const font = text.font_of(style.face);
    const units = advance_units(font, utf8);
    const width = units_to_logical(units, style.size, font.units_per_em);
    assert(width >= 0);
    return width;
}

/// The codepoint boundary of `utf8` nearest to `x` logical pixels from the pen start: the
/// index of the first codepoint whose midpoint lies right of `x`, or the end. O(bytes).
pub fn index_at(style: text.Style, utf8: []const u8, x: f32) u32 {
    assert(utf8.len <= text.byte_cap);
    assert(x == x);
    const font = text.font_of(style.face);
    var pen: f32 = 0;
    var index: u32 = 0;
    while (index < utf8.len) {
        const start = index;
        const width = glyph_width(font, decode(utf8, &index), style.size);
        if (x < pen + width * 0.5) return start;
        pen += width;
    }
    assert(index == utf8.len);
    return index;
}

/// Lays out one run; see `place_runs`.
pub fn place(
    cx: anytype,
    style: text.Style,
    utf8: []const u8,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.Options,
) void {
    const runs = [1]text.Run{.{ .style = style, .bytes = utf8 }};
    place_runs(cx, &runs, rect, clip, options);
}

/// Lays out `runs` as one line in `rect` and appends one `draw.Glyph` per inked glyph to
/// `cx` with `clip`. See the module guide. A glyph the cache skips this frame (budget or a
/// full atlas) is left out and the cache asks the host for another frame.
pub fn place_runs(
    cx: anytype,
    runs: []const text.Run,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.Options,
) void {
    assert(runs.len >= 1);
    assert(runs.len <= text.run_cap);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    const line = line_of(runs);
    var cut: ?Cut = null;
    var width = line.width;
    if (options.ellipsis) {
        if (line.width > rect.width) {
            cut = cut_of(runs, rect.width);
            width = cut.?.width;
            if (!cut.?.fits) return;
        }
    }
    const scale = cx.text.device_scale();
    const pen: Pen = .{
        .x = rect.x + offset(options.align_x, rect.width - width),
        .baseline_px = @round(
            (rect.y + offset(options.align_y, rect.height - line.ascent - line.descent) +
                line.ascent) * scale,
        ),
        .scale = scale,
    };
    emit_runs(cx, runs, pen, clip, cut);
}

const Line = struct {
    width: f32,
    ascent: f32,
    descent: f32,
};

/// Width and the shared vertical metrics of `runs`, in logical pixels.
fn line_of(runs: []const text.Run) Line {
    var line: Line = .{ .width = 0, .ascent = 0, .descent = 0 };
    var bytes: u32 = 0;
    for (runs) |run| {
        const font = text.font_of(run.style.face);
        const em = run.style.size / @as(f32, @floatFromInt(font.units_per_em));
        line.width += measure(run.style, run.bytes);
        line.ascent = @max(line.ascent, @as(f32, @floatFromInt(font.ascent)) * em);
        line.descent = @max(line.descent, @as(f32, @floatFromInt(font.descent)) * em);
        bytes += @intCast(run.bytes.len);
    }
    assert(bytes <= text.byte_cap);
    assert(line.ascent > 0);
    return line;
}

/// Where a cut line stops: before byte `byte` of run `run`. `width` includes the ellipsis.
const Cut = struct {
    run: u32,
    byte: u32,
    width: f32,
    fits: bool,
};

/// The last position whose kept width plus the ellipsis fits `limit`. See section 2.
fn cut_of(runs: []const text.Run, limit: f32) Cut {
    var best: Cut = .{ .run = 0, .byte = 0, .width = 0, .fits = false };
    var kept: f32 = 0;
    for (runs, 0..) |run, run_index| {
        const font = text.font_of(run.style.face);
        const ellipsis = glyph_width(font, ellipsis_char, run.style.size);
        var index: u32 = 0;
        while (index < run.bytes.len) {
            if (kept + ellipsis <= limit) {
                best = .{
                    .run = @intCast(run_index),
                    .byte = index,
                    .width = kept + ellipsis,
                    .fits = true,
                };
            }
            const codepoint = decode(run.bytes, &index);
            kept += glyph_width(font, codepoint, run.style.size);
        }
    }
    if (best.fits) assert(best.width <= limit);
    return best;
}

const Pen = struct {
    /// Unsnapped pen position in logical pixels.
    x: f32,
    /// The baseline, already rounded to a device pixel.
    baseline_px: f32,
    scale: f32,
};

fn emit_runs(cx: anytype, runs: []const text.Run, start: Pen, clip: draw.Clip, cut: ?Cut) void {
    var pen = start;
    for (runs, 0..) |run, run_index| {
        const font = text.font_of(run.style.face);
        const size_q = cx.text.size_key_of(run.style.size);
        var index: u32 = 0;
        while (index < run.bytes.len) {
            if (cut) |c| {
                if (c.run == run_index and c.byte == index) {
                    _ = emit(cx, run.style, font, size_q, ellipsis_char, pen, clip);
                    return;
                }
            }
            const codepoint = decode(run.bytes, &index);
            pen.x += emit(cx, run.style, font, size_q, codepoint, pen, clip);
        }
    }
    assert(cut == null);
}

/// Appends the glyph for `codepoint` at `pen` and returns its advance in logical pixels.
fn emit(
    cx: anytype,
    style: text.Style,
    font: *const ttf.Font,
    size_q: u32,
    codepoint: u21,
    pen: Pen,
    clip: draw.Clip,
) f32 {
    const id = ttf.glyph_id(font, codepoint);
    const advance = units_to_logical(ttf.advance(font, id), style.size, font.units_per_em);
    const face: u8 = @backingInt(style.face);
    const entry = cx.text.glyph(face, font, id, size_q) orelse return advance;
    if (entry.width == 0) {
        return advance;
    }
    append_glyph(cx, instance_of(entry, size_q, pen.x, pen.baseline_px, pen.scale, .{
        .clip = clip,
        .color = style.color,
    }));
    return advance;
}

/// What a glyph instance carries besides its cache entry and pen.
pub const Paint = struct {
    clip: draw.Clip,
    color: [4]f32,
};

/// The instance of an inked cache `entry` at `size_q` with its pen at `pen_x` logical pixels
/// on the device row `baseline_px`, at `scale` device pixels per logical pixel. The snapping
/// of the module guide, section 3; `text/mono.zig` shares it, so both paths write the same
/// records.
pub fn instance_of(
    entry: cache.Entry,
    size_q: u32,
    pen_x: f32,
    baseline_px: f32,
    scale: f32,
    paint: Paint,
) types.Glyph {
    assert(entry.width != 0);
    assert(scale > 0);
    const stretch = @as(f32, @floatFromInt(size_q)) / @as(f32, @floatFromInt(entry.raster_q));
    const left: f32 = @floatFromInt(entry.left);
    const top: f32 = @floatFromInt(entry.top);
    const width: f32 = @floatFromInt(entry.width);
    const height: f32 = @floatFromInt(entry.height);
    const x_px = @round(pen_x * scale) + left * stretch;
    const y_px = baseline_px - top * stretch;
    const atlas: f32 = @floatFromInt(cache.atlas_side);
    const u_left = @as(f32, @floatFromInt(entry.x)) / atlas;
    const v_top = @as(f32, @floatFromInt(entry.y)) / atlas;
    const glyph: types.Glyph = .{
        .rect = .{
            x_px / scale,
            y_px / scale,
            width * stretch / scale,
            height * stretch / scale,
        },
        .clip = .{ paint.clip.x0, paint.clip.y0, paint.clip.x1, paint.clip.y1 },
        .uv = .{ u_left, v_top, u_left + width / atlas, v_top + height / atlas },
        .color = paint.color,
    };
    assert(glyph.rect[2] > 0);
    return glyph;
}

/// Appends `glyph`; a full pool or batch list skips it and counts it in `overflow_count`.
pub fn append_glyph(cx: anytype, glyph: types.Glyph) void {
    assert(glyph.rect[2] > 0);
    assert(glyph.rect[3] > 0);
    cx.append(types.Glyph, .atlas, glyph) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

fn offset(alignment: text.Align, gap: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => gap * 0.5,
        .end => gap,
    };
}

/// Sum of the advances of `utf8` in font units.
fn advance_units(font: *const ttf.Font, utf8: []const u8) u32 {
    var units: u32 = 0;
    var index: u32 = 0;
    while (index < utf8.len) {
        const codepoint = decode(utf8, &index);
        units += ttf.advance(font, ttf.glyph_id(font, codepoint));
    }
    assert(index == utf8.len);
    return units;
}

fn glyph_width(font: *const ttf.Font, codepoint: u21, size: f32) f32 {
    const units = ttf.advance(font, ttf.glyph_id(font, codepoint));
    return units_to_logical(units, size, font.units_per_em);
}

fn units_to_logical(units: u32, size: f32, units_per_em: u32) f32 {
    assert(units_per_em >= 1);
    const em: f32 = @floatFromInt(units_per_em);
    return @as(f32, @floatFromInt(units)) * size / em;
}

const testing = std.testing;
const registry = @import("../draw/registry.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Glyph, .cap = 64 },
};

const TestContext = draw.Context(&test_draw, 4, 0);

/// A freshly initialized static context at `scale_120`, so tests keep the pools and the
/// cache off the stack.
fn test_context(scale_120: u32) *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    static.context.text.scale_120 = scale_120;
    static.context.reset();
    return &static.context;
}

const sans_16: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
const window: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };

// Locks the monospace measure: ten digits at 16 px are ten advances of 600 / 1000 em.
test "measure of a mono string is count times advance" {
    const mono: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };
    try testing.expectEqual(@as(f32, 10 * 9.6), measure(mono, "0123456789"));
    try testing.expectEqual(@as(f32, 0), measure(mono, ""));
    // Two-byte "u with diaeresis" is one codepoint and one advance.
    try testing.expectEqual(@as(f32, 2 * 9.6), measure(mono, "\u{fc}a"));
}

// Locks the caret hit: in a 9.6 px monospace run each boundary owns the half advance on
// either side, the far left is 0, the far right is the end, and a two-byte codepoint is one
// step.
test "index_at picks the nearest codepoint boundary" {
    const mono: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };
    try testing.expectEqual(@as(u32, 0), index_at(mono, "abc", -5));
    try testing.expectEqual(@as(u32, 0), index_at(mono, "abc", 4.7));
    try testing.expectEqual(@as(u32, 1), index_at(mono, "abc", 4.9));
    try testing.expectEqual(@as(u32, 2), index_at(mono, "abc", 14.5));
    try testing.expectEqual(@as(u32, 3), index_at(mono, "abc", 100));
    try testing.expectEqual(@as(u32, 3), index_at(mono, "\u{e4}bc", 9.7 + 4.9));
    try testing.expectEqual(@as(u32, 0), index_at(mono, "", 3));
}

// Locks the decoder's negative space: a truncated, overlong, surrogate, or stray byte each
// becomes one U+FFFD and consumes one byte, while a valid two-byte sequence is one codepoint.
test "invalid UTF-8 becomes U+FFFD one byte at a time" {
    const cases = [_]struct { bytes: []const u8, codepoints: []const u21 }{
        .{ .bytes = "\xC3\xA9", .codepoints = &.{0xE9} },
        .{ .bytes = "\xC3", .codepoints = &.{0xFFFD} },
        .{ .bytes = "\xE2\x82", .codepoints = &.{ 0xFFFD, 0xFFFD } },
        .{ .bytes = "\xC0\xAF", .codepoints = &.{ 0xFFFD, 0xFFFD } },
        .{ .bytes = "\xED\xA0\x80", .codepoints = &.{ 0xFFFD, 0xFFFD, 0xFFFD } },
        .{ .bytes = "\xF4\x90\x80\x80", .codepoints = &.{ 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD } },
        .{ .bytes = "a\x80b", .codepoints = &.{ 'a', 0xFFFD, 'b' } },
        .{ .bytes = "\xF0\x9F\x8E\xB9", .codepoints = &.{0x1F3B9} },
    };
    for (cases) |case| {
        var index: u32 = 0;
        for (case.codepoints) |expected| {
            try testing.expectEqual(expected, decode(case.bytes, &index));
        }
        try testing.expectEqual(case.bytes.len, index);
    }
    try testing.expectEqual(measure(sans_16, "\u{fffd}\u{fffd}"), measure(sans_16, "\xC3\xFF"));
}

// Locks the alignment algebra at scale 1: start, center, and end place the same glyph at pen
// offsets 0, gap / 2, and gap (each snapped to a whole pixel), and vertical centering puts the
// baseline at round(top + ascent) with top = y + (height - line height) / 2.
test "alignment offsets the pen by zero, half the gap, and the gap" {
    const rect: draw.Rect = .{ .x = 10, .y = 20, .width = 200, .height = 40 };
    var x: [3]f32 = undefined;
    var y: f32 = 0;
    for ([_]text.Align{ .start, .center, .end }, 0..) |alignment, index| {
        const cx = test_context(120);
        const options: text.Options = .{
            .align_x = alignment,
            .align_y = .center,
            .ellipsis = false,
        };
        place(cx, sans_16, "H", rect, window, options);
        const glyphs = cx.items(types.Glyph);
        try testing.expectEqual(@as(usize, 1), glyphs.len);
        x[index] = glyphs[0].rect[0];
        y = glyphs[0].rect[1];
    }
    const gap = rect.width - measure(sans_16, "H");
    try testing.expectEqual(@round(rect.x + gap * 0.5) - @round(rect.x), x[1] - x[0]);
    try testing.expectEqual(@round(rect.x + gap) - @round(rect.x), x[2] - x[0]);
    const font = text.font_of(.sans);
    const ascent = @as(f32, @floatFromInt(font.ascent)) * 16 / 1000;
    const descent = @as(f32, @floatFromInt(font.descent)) * 16 / 1000;
    const baseline = @round(rect.y + (rect.height - ascent - descent) * 0.5 + ascent);
    // "H" sits on the baseline: its bitmap's bottom row is the baseline row.
    const glyph = test_context(120).text.glyph(0, font, ttf.glyph_id(font, 'H'), 64).?;
    try testing.expectEqual(baseline - @as(f32, @floatFromInt(glyph.top)), y);
    try testing.expectEqual(baseline, y + @as(f32, @floatFromInt(glyph.height)));
}

// Locks the ellipsis: a line wider than its rect is cut so the kept text plus U+2026 fits, the
// last glyph is the ellipsis, and a rect narrower than the ellipsis draws nothing.
test "ellipsis cuts the line so it fits the rect" {
    const long = "Patchwork draws text";
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
    const cut = cut_of(&.{.{ .style = sans_16, .bytes = long }}, rect.width);
    try testing.expect(cut.fits);
    try testing.expect(cut.width <= rect.width);
    const ellipsis = glyph_width(text.font_of(.sans), ellipsis_char, 16);
    try testing.expect(cut.width + measure(sans_16, long[cut.byte..][0..1]) > rect.width);
    try testing.expectEqual(measure(sans_16, long[0..cut.byte]) + ellipsis, cut.width);
    const cx = test_context(120);
    place(cx, sans_16, long, rect, window, options);
    const glyphs = cx.items(types.Glyph);
    const last = glyphs[glyphs.len - 1];
    try testing.expect(last.rect[0] + last.rect[2] <= rect.x + rect.width);
    // The ellipsis glyph is three dots: wider than tall, sitting on the baseline.
    try testing.expect(last.rect[2] > last.rect[3]);
    const narrow: draw.Rect = .{ .x = 0, .y = 0, .width = ellipsis * 0.5, .height = 24 };
    const empty = test_context(120);
    place(empty, sans_16, long, narrow, window, options);
    try testing.expectEqual(@as(usize, 0), empty.items(types.Glyph).len);
}

// Locks device snapping at scale 1.5: every quad edge lands on a device pixel edge, and each
// UV rect spans exactly the quad's device size in texels (no half-texel inset).
test "glyph quads snap to the device grid at a fractional scale" {
    const cx = test_context(180);
    const rect: draw.Rect = .{ .x = 10.3, .y = 7.1, .width = 300, .height = 30 };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    place(cx, sans_16, "Snap \u{e9}", rect, window, options);
    const glyphs = cx.items(types.Glyph);
    try testing.expectEqual(@as(usize, 5), glyphs.len);
    for (glyphs) |glyph| {
        for (glyph.rect) |edge| {
            const device = edge * 1.5;
            try testing.expectApproxEqAbs(@round(device), device, 0.001);
        }
        const texels_wide = (glyph.uv[2] - glyph.uv[0]) * cache.atlas_side;
        try testing.expectApproxEqAbs(glyph.rect[2] * 1.5, texels_wide, 0.001);
    }
}

// Locks mixed runs: two sizes share one baseline, so the bottoms of "H" at 32 px and at 14 px
// (both sit on the baseline) are the same device row.
test "runs of different sizes share one baseline" {
    const cx = test_context(120);
    const big: text.Style = .{ .face = .mono, .size = 32, .color = .{ 1, 1, 1, 1 } };
    const small: text.Style = .{ .face = .sans_bold, .size = 14, .color = .{ 1, 1, 1, 1 } };
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 400, .height = 52 };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    place_runs(cx, &.{
        .{ .style = big, .bytes = "H" },
        .{ .style = small, .bytes = "H" },
    }, rect, window, options);
    const glyphs = cx.items(types.Glyph);
    try testing.expectEqual(@as(usize, 2), glyphs.len);
    const big_bottom = glyphs[0].rect[1] + glyphs[0].rect[3];
    try testing.expectEqual(big_bottom, glyphs[1].rect[1] + glyphs[1].rect[3]);
    try testing.expect(glyphs[0].rect[3] > glyphs[1].rect[3]);
}

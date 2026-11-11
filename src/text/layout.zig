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
//! ## 2b. Wrapping
//! `Lines` walks runs and cuts them into lines no wider than `width` (at least 0), greedily.
//! A line breaks only at a break opportunity, between two codepoints:
//! - after the last of a run of U+0020 spaces (U+00A0 and tab are not spaces here);
//! - after U+002D when the codepoint before it on the line is not a space and the one after
//!   it is not an ASCII digit ("-6.5" stays whole), and after U+2010, U+2013, and U+2014
//!   when something precedes them on the line;
//! - never at the start of a line (leading spaces are indentation) or at a run boundary.
//! U+000A ends the line (U+000D directly before it is dropped with it); a text ending in it
//! ends with one empty line, and empty text has no lines. A line takes every segment (text up
//! to and including the next opportunity) that fits, comparing with `<=`. Trailing spaces
//! hang: they are in neither the line's `end` nor its width. A segment that does not fit an
//! empty line breaks before the first codepoint that does not fit, after at least one, so
//! every line consumes a byte and `next` is bounded by the bytes.
//!
//! A block of runs has one line height, the tallest run's, so lines are evenly spaced:
//! ```text
//! line_height(style) = ceil((ascent + descent + line_gap) * size / units_per_em)
//! lead               = (line_height - (ascent + descent)) / 2          (block maxima)
//! top                = rect.y + offset(align_y, rect.height - lines * line_height)
//! baseline_px(i)     = round((top + i * line_height + lead + ascent) * s)
//! pen_x(line)        = rect.x + offset(align_x, rect.width - line.width)
//! ```
//! Whole logical pixels keep the spacing exact at integer scales; at a fractional scale each
//! baseline rounds on its own, so gaps differ by at most one device pixel. In a rect one line
//! high, a line lands where `place` with `align_y = .center` puts it. A line whose box
//! `[top + i h, top + (i + 1) h)` misses the clip appends nothing and costs no cache lookup.
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
//! ## 3a. Icons
//! `icon` draws one glyph centred by its ink, not its advance and line. The ink is the cache
//! entry's raster box (the decoded points' box, floored and ceiled to device pixels; the
//! glyph header's box is not trusted, since some icon fonts store 0 for every minimum). With
//! the rect's centre `(c_x, c_y)` and the box in device pixels (`left`, `top`, `width`,
//! `height`, each times `k`):
//! ```text
//! pen_x       = round(c_x * s - width / 2 - left) / s
//! baseline_px = round(c_y * s + top - height / 2)
//! ```
//! so the quad's centre lands within half a device pixel of the rect's centre whatever the
//! face's advances and baseline (icon fonts are often inconsistent in both), and its edges on
//! the grid as above. A codepoint the face does not map draws nothing, not `.notdef`, and is
//! counted for the overflow report (`cache.miss_icon`).
//!
//! ## 3b. Outlines
//! `Glyphs` is the layout of `place_runs` and `place_runs_wrapped` without the atlas: the same
//! `line_of`, `cut_of`, `Lines`, `Block`, and `offset`, so each codepoint's pen is the one
//! `emit_runs` and `emit_span` walk, before the baseline snaps to a device pixel:
//! ```text
//! pen[0]  = Pen.x                                  pen[1] = the baseline, unsnapped
//! round(pen[1] * s) = Pen.baseline_px
//! ```
//! `contours` adds one glyph's outline to a `draw.fill.Builder` at `size / units_per_em`, and the
//! `place_*_outlines` family fills each glyph as its own shape, so one refused glyph costs only
//! itself. Neither path hints or kerns, so their advances agree. A glyph is skipped before its
//! outline loads when its box `[x - size, x + 2 size] x [y - 2 size, y + size]` misses the clip.
//!
//! ## 4. TigerStyle Invariants
//! - Loops are bounded by `text.byte_cap` bytes and `text.run_cap` runs; each `Lines.next`
//!   consumes at least one byte, so a wrapped text has at most `byte_cap + 1` lines.
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

/// The line pitch of `style`: ascent, descent, and line gap rounded up to a whole logical
/// pixel. See the module guide, section 2b.
pub fn line_height(style: text.Style) f32 {
    assert(style.size > 0);
    assert(style.size <= text.size_max);
    const font = text.font_of(style.face);
    const em = style.size / @as(f32, @floatFromInt(font.units_per_em));
    const extent = @as(f32, @floatFromInt(font.ascent + font.descent + font.line_gap)) * em;
    const height = @ceil(extent);
    assert(height >= 1);
    return height;
}

/// The vertical metrics a wrapped block shares: the tallest run's line height, ascent, and
/// descent, and the baseline's offset from the top of a line box.
const Block = struct {
    line_height: f32,
    ascent: f32,
    descent: f32,

    fn of(runs: []const text.Run) Block {
        assert(runs.len >= 1);
        assert(runs.len <= text.run_cap);
        var block: Block = .{ .line_height = 0, .ascent = 0, .descent = 0 };
        for (runs) |run| {
            const font = text.font_of(run.style.face);
            const em = run.style.size / @as(f32, @floatFromInt(font.units_per_em));
            block.line_height = @max(block.line_height, line_height(run.style));
            block.ascent = @max(block.ascent, @as(f32, @floatFromInt(font.ascent)) * em);
            block.descent = @max(block.descent, @as(f32, @floatFromInt(font.descent)) * em);
        }
        assert(block.line_height >= block.ascent + block.descent);
        return block;
    }

    /// The baseline below the top of a line box: half the leading, then the ascent.
    fn baseline(self: Block) f32 {
        const lead = (self.line_height - self.ascent - self.descent) * 0.5;
        assert(lead >= 0);
        return lead + self.ascent;
    }
};

/// One codepoint of a text and where it starts and ends (`next`).
const Step = struct {
    at: text.Position,
    next: text.Position,
    codepoint: u21,
};

/// The codepoint at `position`, past the ends of runs, or null at the end of the text.
fn step_at(runs: []const text.Run, position: text.Position) ?Step {
    var at = position;
    assert(at.run <= runs.len);
    while (at.run < runs.len and at.byte == runs[at.run].bytes.len) {
        at = .{ .run = at.run + 1, .byte = 0 };
    }
    if (at.run == runs.len) return null;
    var index = at.byte;
    const codepoint = decode(runs[at.run].bytes, &index);
    assert(index > at.byte);
    return .{ .at = at, .next = .{ .run = at.run, .byte = index }, .codepoint = codepoint };
}

fn bytes_of(runs: []const text.Run) u32 {
    var bytes: u32 = 0;
    for (runs) |run| bytes += @intCast(run.bytes.len);
    return bytes;
}

fn is_digit(codepoint: u21) bool {
    return codepoint >= '0' and codepoint <= '9';
}

/// Greedy lines of `runs` no wider than `width`. See the module guide, section 2b. `runs`
/// must outlive the iterator; each `next` is O(bytes of its line and the spaces after it).
pub const Lines = struct {
    runs: []const text.Run,
    width: f32,
    /// Where the next line starts.
    at: text.Position,
    /// A hard break ended the text, so one empty line is still owed.
    owed_empty: bool,
    done: bool,

    pub fn init(runs: []const text.Run, width: f32) Lines {
        assert(runs.len <= text.run_cap);
        assert(width >= 0);
        assert(bytes_of(runs) <= text.byte_cap);
        return .{
            .runs = runs,
            .width = width,
            .at = .{ .run = 0, .byte = 0 },
            .owed_empty = false,
            .done = false,
        };
    }

    pub fn next(self: *Lines) ?text.Line {
        if (self.done) return null;
        const start = self.at;
        if (step_at(self.runs, start) == null) {
            self.done = true;
            if (!self.owed_empty) return null;
            self.owed_empty = false;
            return .{ .start = start, .end = start, .width = 0 };
        }
        // `content_*` is the line so far without its trailing spaces; `pen` includes them.
        var content_end = start;
        var content_width: f32 = 0;
        var pen: f32 = 0;
        var consumed = false;
        var previous: ?u21 = null;
        var after_space = false;
        var after_hyphen = false;
        var opportunity: ?Opportunity = null;
        var position = start;
        var budget: u32 = bytes_of(self.runs) + 1;
        while (step_at(self.runs, position)) |step| {
            assert(budget > 0);
            budget -= 1;
            const codepoint = step.codepoint;
            if (codepoint == '\n') {
                self.at = step.next;
                self.owed_empty = step_at(self.runs, step.next) == null;
                return .{ .start = start, .end = content_end, .width = content_width };
            }
            if (codepoint == '\r') {
                if (step_at(self.runs, step.next)) |after| {
                    if (after.codepoint == '\n') {
                        position = step.next;
                        continue;
                    }
                }
            }
            const style = self.runs[step.at.run].style;
            const advance = glyph_width(text.font_of(style.face), codepoint, style.size);
            if (codepoint == ' ') {
                pen += advance;
                consumed = true;
                after_space = previous != null;
                after_hyphen = false;
                position = step.next;
                continue;
            }
            if (after_space or after_hyphen) {
                opportunity = .{ .end = content_end, .width = content_width, .next = step.at };
            }
            if (pen + advance > self.width) {
                if (opportunity) |taken| {
                    self.at = taken.next;
                    return .{ .start = start, .end = taken.end, .width = taken.width };
                }
                if (consumed) {
                    self.at = step.at;
                    return .{ .start = start, .end = content_end, .width = content_width };
                }
            }
            after_hyphen = switch (codepoint) {
                '-' => hyphen: {
                    const before = previous orelse break :hyphen false;
                    if (before == ' ') break :hyphen false;
                    const after = step_at(self.runs, step.next) orelse break :hyphen false;
                    break :hyphen !is_digit(after.codepoint);
                },
                0x2010, 0x2013, 0x2014 => previous != null,
                else => false,
            };
            pen += advance;
            content_end = step.next;
            content_width = pen;
            consumed = true;
            previous = codepoint;
            after_space = false;
            position = step.next;
        }
        self.done = true;
        self.at = position;
        assert(consumed);
        return .{ .start = start, .end = content_end, .width = content_width };
    }

    /// The last break opportunity seen on a line: the line's end and width if it breaks
    /// there, and where the next line starts.
    const Opportunity = struct {
        end: text.Position,
        width: f32,
        next: text.Position,
    };
};

/// The height `utf8` in `style` takes wrapped to `width`. See the module guide, section 2b.
pub fn measure_wrapped(style: text.Style, utf8: []const u8, width: f32) f32 {
    const runs = [1]text.Run{.{ .style = style, .bytes = utf8 }};
    return measure_runs_wrapped(&runs, width);
}

/// The height `runs` take wrapped to `width`: lines times the block's line height.
pub fn measure_runs_wrapped(runs: []const text.Run, width: f32) f32 {
    assert(runs.len >= 1);
    assert(width >= 0);
    const count = count_lines(runs, width);
    return @as(f32, @floatFromInt(count)) * Block.of(runs).line_height;
}

fn count_lines(runs: []const text.Run, width: f32) u32 {
    var lines = Lines.init(runs, width);
    var count: u32 = 0;
    while (lines.next()) |_| {
        count += 1;
        assert(count <= text.byte_cap + 1);
    }
    return count;
}

/// Lays out `utf8` wrapped in `rect`; see `place_runs_wrapped`.
pub fn place_wrapped(
    cx: anytype,
    style: text.Style,
    utf8: []const u8,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.WrapOptions,
) void {
    const runs = [1]text.Run{.{ .style = style, .bytes = utf8 }};
    place_runs_wrapped(cx, &runs, rect, clip, options);
}

/// Lays out `runs` wrapped to `rect.width`, one snapped baseline per line, and appends one
/// `draw.Glyph` per inked glyph of every line that meets `clip`. See the module guide,
/// section 2b.
pub fn place_runs_wrapped(
    cx: anytype,
    runs: []const text.Run,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.WrapOptions,
) void {
    assert(runs.len >= 1);
    assert(runs.len <= text.run_cap);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    const width = @max(rect.width, 0);
    const block = Block.of(runs);
    var top = rect.y;
    if (options.align_y != .start) {
        const height = @as(f32, @floatFromInt(count_lines(runs, width))) * block.line_height;
        top += offset(options.align_y, rect.height - height);
    }
    const scale = cx.text.device_scale();
    var lines = Lines.init(runs, width);
    var y = top;
    while (lines.next()) |line| : (y += block.line_height) {
        if (y >= clip.y1) break;
        if (y + block.line_height <= clip.y0) continue;
        const pen: Pen = .{
            .x = rect.x + offset(options.align_x, width - line.width),
            .baseline_px = @round((y + block.baseline()) * scale),
            .scale = scale,
        };
        emit_span(cx, runs, line, pen, clip);
    }
}

/// Appends the glyphs of `line` from `start`'s pen; the spaces inside it advance the pen.
fn emit_span(
    cx: anytype,
    runs: []const text.Run,
    line: text.Line,
    start: Pen,
    clip: draw.Clip,
) void {
    var pen = start;
    var position = line.start;
    var budget: u32 = bytes_of(runs) + 1;
    while (!std.meta.eql(position, line.end)) {
        assert(budget > 0);
        budget -= 1;
        const run = runs[position.run];
        if (position.byte == run.bytes.len) {
            position = .{ .run = position.run + 1, .byte = 0 };
            continue;
        }
        const font = text.font_of(run.style.face);
        const size_q = cx.text.size_key_of(run.style.size);
        var index = position.byte;
        const codepoint = decode(run.bytes, &index);
        pen.x += emit(cx, run.style, font, size_q, codepoint, pen, clip);
        position.byte = index;
    }
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

const Extent = struct {
    width: f32,
    ascent: f32,
    descent: f32,
};

/// Width and the shared vertical metrics of `runs`, in logical pixels.
fn line_of(runs: []const text.Run) Extent {
    var line: Extent = .{ .width = 0, .ascent = 0, .descent = 0 };
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

/// Adds `glyph` of `face` at `size` logical px with its pen at `pen`, +y down, to `shape`. False
/// when it adds nothing: no ink, or an outline `ttf.zig` cannot read. An outline over the
/// loader's caps draws `.notdef`, as the atlas does. See the module guide, section 3b.
pub fn contours(
    shape: *draw.fill.Builder,
    face: text.Face,
    glyph: u16,
    size: f32,
    pen: draw.Point,
) bool {
    assert(size > 0);
    assert(!shape.open);
    const font = text.font_of(face);
    assert(glyph < font.glyph_count);
    var outline: ttf.Outline = undefined;
    var loaded = ttf.load(font, glyph, &outline);
    if (loaded == .replace) loaded = ttf.load(font, ttf.replacement, &outline);
    if (loaded != .ready) return false;
    const scale = size / @as(f32, @floatFromInt(font.units_per_em));
    shape.outline(&outline, scale, pen);
    return true;
}

/// One codepoint of a laid-out text (`Glyphs`). `pen` is `place`'s before snapping.
pub const Glyph = struct {
    glyph: u16,
    codepoint: u21,
    style: text.Style,
    /// The unsnapped pen and baseline, logical px.
    pen: [2]f32,
    advance: f32,
    line: u32,
    /// The nth codepoint yielded, from 0.
    index: u32,
};

/// The codepoints of a line or a wrapped block with their pens, in order. Pure: it holds no
/// cache and never touches a draw context. `runs` must outlive it. See the module guide,
/// section 3b.
pub const Glyphs = struct {
    runs: []const text.Run,
    /// The wrapped lines; null for a single line.
    lines: ?Lines,
    block: Block,
    /// The wrapped block's x, width, and alignment; a single line's pen starts at `x`.
    x: f32,
    width: f32,
    align_x: text.Align,
    /// The baseline of a single line; the top of the next wrapped line.
    y: f32,
    cut: ?Cut,
    /// The line being walked, if any.
    active: bool,
    position: text.Position,
    end: ?text.Position,
    pen_x: f32,
    baseline: f32,
    line_count: u32,
    index: u32,
    done: bool,
    /// Loop turns one `next` may take: every turn moves a position, a run, or a line.
    spin_cap: u32,

    /// The layout of `place_runs`.
    pub fn line(runs: []const text.Run, rect: draw.Rect, options: text.Options) Glyphs {
        assert(runs.len >= 1);
        assert(runs.len <= text.run_cap);
        const extent = line_of(runs);
        var self = Glyphs.empty(runs);
        var width = extent.width;
        if (options.ellipsis and extent.width > rect.width) {
            const cut = cut_of(runs, rect.width);
            if (!cut.fits) {
                self.done = true;
                return self;
            }
            self.cut = cut;
            width = cut.width;
        }
        self.active = true;
        self.pen_x = rect.x + offset(options.align_x, rect.width - width);
        self.baseline = rect.y +
            offset(options.align_y, rect.height - extent.ascent - extent.descent) + extent.ascent;
        return self;
    }

    /// The layout of `place_runs_wrapped`.
    pub fn wrapped(runs: []const text.Run, rect: draw.Rect, options: text.WrapOptions) Glyphs {
        assert(runs.len >= 1);
        assert(runs.len <= text.run_cap);
        const width = @max(rect.width, 0);
        var self = Glyphs.empty(runs);
        self.block = Block.of(runs);
        self.lines = Lines.init(runs, width);
        self.x = rect.x;
        self.width = width;
        self.align_x = options.align_x;
        self.y = rect.y;
        if (options.align_y != .start) {
            const height = @as(f32, @floatFromInt(count_lines(runs, width))) *
                self.block.line_height;
            self.y += offset(options.align_y, rect.height - height);
        }
        return self;
    }

    fn empty(runs: []const text.Run) Glyphs {
        assert(bytes_of(runs) <= text.byte_cap);
        return .{
            .runs = runs,
            .lines = null,
            .block = .{ .line_height = 0, .ascent = 0, .descent = 0 },
            .x = 0,
            .width = 0,
            .align_x = .start,
            .y = 0,
            .cut = null,
            .active = false,
            .position = .{ .run = 0, .byte = 0 },
            .end = null,
            .pen_x = 0,
            .baseline = 0,
            .line_count = 0,
            .index = 0,
            .done = false,
            .spin_cap = 4 * (bytes_of(runs) + text.run_cap + 2),
        };
    }

    /// The next codepoint, spaces included, or null after the last.
    pub fn next(self: *Glyphs) ?Glyph {
        if (self.done) return null;
        var spins: u32 = 0;
        while (true) : (spins += 1) {
            assert(spins <= self.spin_cap);
            if (!self.active and !self.begin_line()) {
                self.done = true;
                return null;
            }
            if (self.end) |end| {
                if (std.meta.eql(self.position, end)) {
                    self.finish_line();
                    continue;
                }
            }
            if (self.position.run == self.runs.len) {
                self.finish_line();
                continue;
            }
            const run = self.runs[self.position.run];
            if (self.position.byte == run.bytes.len) {
                self.position = .{ .run = self.position.run + 1, .byte = 0 };
                continue;
            }
            if (self.cut) |cut| {
                if (cut.run == self.position.run and cut.byte == self.position.byte) {
                    self.cut = null;
                    self.done = true;
                    return self.record(run.style, ellipsis_char);
                }
            }
            var index = self.position.byte;
            const codepoint = decode(run.bytes, &index);
            self.position.byte = index;
            return self.record(run.style, codepoint);
        }
    }

    /// The record of `codepoint` at the pen, which then advances.
    fn record(self: *Glyphs, style: text.Style, codepoint: u21) Glyph {
        const font = text.font_of(style.face);
        const id = ttf.glyph_id(font, codepoint);
        const advance = units_to_logical(ttf.advance(font, id), style.size, font.units_per_em);
        const result: Glyph = .{
            .glyph = id,
            .codepoint = codepoint,
            .style = style,
            .pen = .{ self.pen_x, self.baseline },
            .advance = advance,
            .line = self.line_count -| 1,
            .index = self.index,
        };
        self.pen_x += advance;
        self.index += 1;
        return result;
    }

    /// Moves to the next wrapped line; false when there is none. A single line is begun by
    /// `line`, so it has no next.
    fn begin_line(self: *Glyphs) bool {
        const lines = if (self.lines) |*lines| lines else return false;
        const wrapped_line = lines.next() orelse return false;
        self.active = true;
        self.position = wrapped_line.start;
        self.end = wrapped_line.end;
        self.pen_x = self.x + offset(self.align_x, self.width - wrapped_line.width);
        self.baseline = self.y + self.block.baseline();
        self.y += self.block.line_height;
        self.line_count += 1;
        return true;
    }

    fn finish_line(self: *Glyphs) void {
        self.active = false;
        if (self.lines == null) self.done = true;
    }
};

/// Fills every glyph of `glyphs` that meets `clip` as its own shape.
fn fill_glyphs(cx: anytype, glyphs: *Glyphs, clip: draw.Clip) void {
    comptime {
        const Draw = @TypeOf(cx.*);
        if (!Draw.Registry.has(draw.Fill)) {
            @compileError("place_outlines needs draw.Fill in App.config.draw");
        }
    }
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    var shape: draw.fill.Builder = .init(cx.text.device_scale());
    while (glyphs.next()) |glyph| {
        const size = glyph.style.size;
        const x = glyph.pen[0];
        const y = glyph.pen[1];
        if (x - size >= clip.x1 or x + 2 * size <= clip.x0) continue;
        if (y - 2 * size >= clip.y1 or y + size <= clip.y0) continue;
        shape.reset();
        if (!contours(&shape, glyph.style.face, glyph.glyph, size, glyph.pen)) continue;
        _ = draw.fill.append(cx, &shape, .{ .color = glyph.style.color }, clip);
    }
}

/// `place` with each glyph a `draw.Fill` shape instead of an atlas bitmap; see
/// `place_runs_outlines`.
pub fn place_outlines(
    cx: anytype,
    style: text.Style,
    utf8: []const u8,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.Options,
) void {
    const runs = [1]text.Run{.{ .style = style, .bytes = utf8 }};
    place_runs_outlines(cx, &runs, rect, clip, options);
}

/// `place_runs`' layout with one `draw.Fill` shape per glyph, non-zero, in the glyph's colour.
/// A refused glyph is counted by `fill.append` and the next one still draws. Needs `draw.Fill`
/// in the draw context's registry. See the module guide, section 3b.
pub fn place_runs_outlines(
    cx: anytype,
    runs: []const text.Run,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.Options,
) void {
    var glyphs = Glyphs.line(runs, rect, options);
    fill_glyphs(cx, &glyphs, clip);
}

/// `place_wrapped` as outlines; see `place_runs_wrapped_outlines`.
pub fn place_wrapped_outlines(
    cx: anytype,
    style: text.Style,
    utf8: []const u8,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.WrapOptions,
) void {
    const runs = [1]text.Run{.{ .style = style, .bytes = utf8 }};
    place_runs_wrapped_outlines(cx, &runs, rect, clip, options);
}

/// `place_runs_wrapped`' layout as outlines (`place_runs_outlines`).
pub fn place_runs_wrapped_outlines(
    cx: anytype,
    runs: []const text.Run,
    rect: draw.Rect,
    clip: draw.Clip,
    options: text.WrapOptions,
) void {
    var glyphs = Glyphs.wrapped(runs, rect, options);
    fill_glyphs(cx, &glyphs, clip);
}

/// Draws `codepoint` of `face` at `size` with its ink centred on `rect`, clipped to `clip`. See
/// the module guide, section 3a.
pub fn icon(
    cx: anytype,
    face: text.Face,
    codepoint: u21,
    size: f32,
    rect: draw.Rect,
    clip: draw.Clip,
    color: [4]f32,
) void {
    assert(size > 0);
    assert(size <= text.size_max);
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    const font = text.font_of(face);
    const id = ttf.glyph_id(font, codepoint);
    if (id == 0) {
        cx.text.miss_icon(@backingInt(face), codepoint);
        return;
    }
    const scale = cx.text.device_scale();
    const size_q = cx.text.size_key_of(size);
    const entry = cx.text.glyph(@backingInt(face), font, id, size_q) orelse return;
    if (entry.width == 0) return;
    const stretch = @as(f32, @floatFromInt(size_q)) / @as(f32, @floatFromInt(entry.raster_q));
    const left = @as(f32, @floatFromInt(entry.left)) * stretch;
    const top = @as(f32, @floatFromInt(entry.top)) * stretch;
    const width = @as(f32, @floatFromInt(entry.width)) * stretch;
    const height = @as(f32, @floatFromInt(entry.height)) * stretch;
    const centre_x = (rect.x + rect.width * 0.5) * scale;
    const centre_y = (rect.y + rect.height * 0.5) * scale;
    const pen_x = @round(centre_x - width * 0.5 - left) / scale;
    const baseline_px = @round(centre_y + top - height * 0.5);
    append_glyph(cx, instance_of(entry, size_q, pen_x, baseline_px, scale, .{
        .clip = clip,
        .color = color,
    }));
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

pub fn units_to_logical(units: u32, size: f32, units_per_em: u32) f32 {
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
    const em: f32 = @floatFromInt(font.units_per_em);
    const ascent = @as(f32, @floatFromInt(font.ascent)) * 16 / em;
    const descent = @as(f32, @floatFromInt(font.descent)) * 16 / em;
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

// Locks icon centring (section 3a) at scale 1.5: "." has its ink low and left of its advance
// box, yet its quad's centre lands on the rect's centre to within half a device pixel, with
// every edge on the device grid; `place` would have put it on the baseline instead.
test "icon centres the ink box on the rect to the device pixel" {
    const cx = test_context(180);
    const rect: draw.Rect = .{ .x = 10.3, .y = 7.1, .width = 64, .height = 48 };
    icon(cx, .sans, '.', 40, rect, window, .{ 1, 1, 1, 1 });
    const glyphs = cx.items(types.Glyph);
    try testing.expectEqual(@as(usize, 1), glyphs.len);
    const quad = glyphs[0].rect;
    for (quad) |edge| {
        try testing.expectApproxEqAbs(@round(edge * 1.5), edge * 1.5, 0.001);
    }
    const centre_x = (quad[0] + quad[2] * 0.5) * 1.5;
    const centre_y = (quad[1] + quad[3] * 0.5) * 1.5;
    try testing.expect(@abs(centre_x - (rect.x + rect.width * 0.5) * 1.5) <= 0.5);
    try testing.expect(@abs(centre_y - (rect.y + rect.height * 0.5) * 1.5) <= 0.5);
    try testing.expectEqual(@as(u32, 0), cx.text.icon_missing);
    // `place` puts the period on the baseline, far below the centre.
    const placed = test_context(180);
    place(placed, .{ .face = .sans, .size = 40, .color = .{ 1, 1, 1, 1 } }, ".", rect, window, .{
        .align_x = .center,
        .align_y = .center,
        .ellipsis = false,
    });
    const dot = placed.items(types.Glyph)[0].rect;
    try testing.expect(dot[1] + dot[3] * 0.5 > rect.y + rect.height * 0.5 + 4);
}

// Locks the missing icon (section 3a): a codepoint the face does not map (U+0416 is outside
// the subset) appends nothing, not `.notdef`, and is counted with its face and codepoint.
test "icon of an unmapped codepoint appends nothing and is counted" {
    const cx = test_context(120);
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 32, .height = 32 };
    icon(cx, .sans_bold, 0x0416, 18, rect, window, .{ 1, 1, 1, 1 });
    try testing.expectEqual(@as(usize, 0), cx.items(types.Glyph).len);
    try testing.expectEqual(@as(u32, 1), cx.text.icon_missing);
    try testing.expectEqual(@as(u32, 1 << 21 | 0x0416), cx.text.icon_last);
    cx.reset();
    try testing.expectEqual(@as(u32, 0), cx.text.icon_missing);
}

const mono_10: text.Style = .{ .face = .mono, .size = 10, .color = .{ 1, 1, 1, 1 } };

// Locks the line pitch (section 2b): ascent 1069 plus descent 293 units (line gap 0) of a
// 1000-unit em, rounded up: 21.792 -> 22 for Sans and Sans Bold at 16, 20.43 -> 21 for Mono at
// 15 (the editor's line), and 13.62 -> 14 for Mono at 10.
test "line height rounds the face's line up to a whole pixel" {
    try testing.expectEqual(@as(u32, 0), text.font_of(.sans).line_gap);
    try testing.expectEqual(@as(u32, 0), text.font_of(.mono).line_gap);
    try testing.expectEqual(@as(f32, 22), line_height(sans_16));
    const bold_16: text.Style = .{ .face = .sans_bold, .size = 16, .color = .{ 1, 1, 1, 1 } };
    const mono_15: text.Style = .{ .face = .mono, .size = 15, .color = .{ 1, 1, 1, 1 } };
    try testing.expectEqual(@as(f32, 22), line_height(bold_16));
    try testing.expectEqual(@as(f32, 21), line_height(mono_15));
    try testing.expectEqual(@as(f32, 14), line_height(mono_10));
}

/// One expected line: start byte, end byte, width.
const Expected = [3]f32;

fn expect_lines(utf8: []const u8, width: f32, expected: []const Expected) !void {
    const runs = [1]text.Run{.{ .style = mono_10, .bytes = utf8 }};
    var lines = Lines.init(&runs, width);
    for (expected) |want| {
        const line = lines.next() orelse return error.TooFewLines;
        try testing.expectEqual(@as(u32, 0), line.start.run);
        try testing.expectEqual(want[0], @as(f32, @floatFromInt(line.start.byte)));
        try testing.expectEqual(want[1], @as(f32, @floatFromInt(line.end.byte)));
        try testing.expectEqual(want[2], line.width);
    }
    try testing.expect(lines.next() == null);
    try testing.expect(lines.next() == null);
}

// Locks the break rules (section 2b) in Mono 10, 6 px a codepoint, as [start, end, width]:
// spaces hang, a hyphen breaks after it but not before a digit, the no-break space does not
// break, a too-long word breaks at the last codepoint that fits, leading spaces stay, hard
// breaks (and CR LF) end lines with a trailing one owing an empty line, and width 0 puts one
// codepoint on each line.
test "lines break after spaces and hyphens, at hard breaks, and inside long words" {
    const fox = "the quick brown fox";
    try expect_lines(fox, 60, &.{ .{ 0, 9, 54 }, .{ 10, 19, 54 } });
    try expect_lines(fox, 30, &.{ .{ 0, 3, 18 }, .{ 4, 9, 30 }, .{ 10, 15, 30 }, .{ 16, 19, 18 } });
    try expect_lines(fox, 1000, &.{.{ 0, 19, 114 }});
    try expect_lines("abcdefghij", 24, &.{ .{ 0, 4, 24 }, .{ 4, 8, 24 }, .{ 8, 10, 12 } });
    try expect_lines("well-known", 36, &.{ .{ 0, 5, 30 }, .{ 5, 10, 30 } });
    try expect_lines("x -6.5", 30, &.{ .{ 0, 1, 6 }, .{ 2, 6, 24 } });
    try expect_lines("a\u{a0}b", 12, &.{ .{ 0, 3, 12 }, .{ 3, 4, 6 } });
    try expect_lines("a   b", 6, &.{ .{ 0, 1, 6 }, .{ 4, 5, 6 } });
    try expect_lines("  a b", 18, &.{ .{ 0, 3, 18 }, .{ 4, 5, 6 } });
    try expect_lines("a\n\nb", 1000, &.{ .{ 0, 1, 6 }, .{ 2, 2, 0 }, .{ 3, 4, 6 } });
    try expect_lines("a\n", 1000, &.{ .{ 0, 1, 6 }, .{ 2, 2, 0 } });
    try expect_lines("a\r\nb", 1000, &.{ .{ 0, 1, 6 }, .{ 3, 4, 6 } });
    try expect_lines("   ", 1000, &.{.{ 0, 0, 0 }});
    try expect_lines("", 1000, &.{});
    try expect_lines("ab", 0, &.{ .{ 0, 1, 6 }, .{ 1, 2, 6 } });
}

// Locks run boundaries (section 2b): "the qu" + "ick brown fox" at 60 breaks where the joined
// text does, with positions in the runs: {0,0}..{1,3} width 54, then {1,4}..{1,13} width 54.
test "a run boundary is not a break opportunity" {
    const runs = [_]text.Run{
        .{ .style = mono_10, .bytes = "the qu" },
        .{ .style = mono_10, .bytes = "ick brown fox" },
    };
    var lines = Lines.init(&runs, 60);
    const first = lines.next().?;
    try testing.expectEqual(text.Position{ .run = 0, .byte = 0 }, first.start);
    try testing.expectEqual(text.Position{ .run = 1, .byte = 3 }, first.end);
    try testing.expectEqual(@as(f32, 54), first.width);
    const second = lines.next().?;
    try testing.expectEqual(text.Position{ .run = 1, .byte = 4 }, second.start);
    try testing.expectEqual(text.Position{ .run = 1, .byte = 13 }, second.end);
    try testing.expectEqual(@as(f32, 54), second.width);
    try testing.expect(lines.next() == null);
}

// Locks the iterator's bound (section 4): on texts of spaces, newlines, and one long word at
// width 0, `next` returns null within bytes + 1 calls.
test "every wrapped text ends within its bytes plus one lines" {
    const texts = [_][]const u8{ "", "a", "   ", "\n\n\n", "abcdefghij", "a b c", "-\u{2014}-" };
    for (texts) |utf8| {
        const runs = [1]text.Run{.{ .style = mono_10, .bytes = utf8 }};
        var lines = Lines.init(&runs, 0);
        var count: u32 = 0;
        while (lines.next()) |_| count += 1;
        try testing.expect(count <= utf8.len + 1);
    }
}

// Locks the wrapped height: the fox at 30 is 4 lines of 14 px.
test "measure_wrapped is lines times the line height" {
    try testing.expectEqual(@as(f32, 56), measure_wrapped(mono_10, "the quick brown fox", 30));
    try testing.expectEqual(@as(f32, 14), measure_wrapped(mono_10, "the quick brown fox", 1000));
    try testing.expectEqual(@as(f32, 0), measure_wrapped(mono_10, "", 30));
}

/// The device row of the bottom of each line's first "n", which sits flat on the baseline, for
/// a text that wraps like the fox at 30.
fn fox_baselines(scale_120: u32, out: *[4]f32) !void {
    const cx = test_context(scale_120);
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 30, .height = 100 };
    place_wrapped(cx, mono_10, "nnn nnnnn nnnnn nnn", rect, window, .{});
    const glyphs = cx.items(types.Glyph);
    try testing.expectEqual(@as(usize, 16), glyphs.len);
    const firsts = [_]usize{ 0, 3, 8, 13 };
    const scale = @as(f32, @floatFromInt(scale_120)) / 120;
    for (firsts, out) |index, *row| {
        const glyph = glyphs[index];
        row.* = @round((glyph.rect[1] + glyph.rect[3]) * scale);
    }
}

// Locks the baselines (section 2b) of 14 px lines with baseline 10.88 below each box's top:
// rows 11, 25, 39, 53 at scale 1; at 1.25 rows 14, 31, 49, 66 (13.6, 31.1, 48.6, 66.1
// rounded), so gaps of 17, 18, 17 device pixels.
test "wrapped baselines snap per line" {
    var rows: [4]f32 = undefined;
    try fox_baselines(120, &rows);
    try testing.expectEqual([4]f32{ 11, 25, 39, 53 }, rows);
    try fox_baselines(150, &rows);
    try testing.expectEqual([4]f32{ 14, 31, 49, 66 }, rows);
}

// Locks the alignments (section 2b): the fox's lines are 18, 30, 30, 18 wide in a 30 px rect,
// so center moves their first glyphs 6, 0, 0, 6 and end 12, 0, 0, 12; the 56 px block in a
// 100 px rect starts 22 lower centered and 44 lower at the end.
test "wrapped lines align per line and as a block" {
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 30, .height = 100 };
    const firsts = [_]usize{ 0, 3, 8, 13 };
    var starts: [3][4]f32 = undefined;
    var tops: [3]f32 = undefined;
    for ([_]text.Align{ .start, .center, .end }, 0..) |alignment, a| {
        const cx = test_context(120);
        place_wrapped(cx, mono_10, "the quick brown fox", rect, window, .{
            .align_x = alignment,
            .align_y = alignment,
        });
        const glyphs = cx.items(types.Glyph);
        for (firsts, 0..) |index, line| starts[a][line] = glyphs[index].rect[0];
        tops[a] = glyphs[0].rect[1];
    }
    for (0..4) |line| {
        const center = [4]f32{ 6, 0, 0, 6 };
        const end = [4]f32{ 12, 0, 0, 12 };
        try testing.expectEqual(center[line], starts[1][line] - starts[0][line]);
        try testing.expectEqual(end[line], starts[2][line] - starts[0][line]);
    }
    try testing.expectEqual(@as(f32, 22), tops[1] - tops[0]);
    try testing.expectEqual(@as(f32, 44), tops[2] - tops[0]);
}

// Locks culling (section 2b): with the clip over the second line's box only, the fox at 30
// appends the five glyphs of "quick".
test "lines outside the clip append nothing" {
    const cx = test_context(120);
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 30, .height = 100 };
    const band: draw.Clip = .{ .x0 = 0, .y0 = 14, .x1 = 100, .y1 = 28 };
    place_wrapped(cx, mono_10, "the quick brown fox", rect, band, .{});
    try testing.expectEqual(@as(usize, 5), cx.items(types.Glyph).len);
}

// Locks `text.run_cap`: 64 runs of one byte place like the 64 bytes as one run.
test "a line of 64 runs places like one run" {
    const bytes: [text.run_cap]u8 = @splat('a');
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 900, .height = 24 };
    const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 900, .y1 = 24 };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    const style: text.Style = .{ .face = .sans, .size = 15, .color = .{ 1, 1, 1, 1 } };
    const cx = test_context(120);
    place(cx, style, &bytes, rect, clip, options);
    var whole: [64]types.Glyph = undefined;
    @memcpy(&whole, cx.items(types.Glyph));
    cx.reset();
    var runs: [text.run_cap]text.Run = undefined;
    for (&runs, 0..) |*run, index| run.* = .{ .style = style, .bytes = bytes[index..][0..1] };
    place_runs(cx, &runs, rect, clip, options);
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(&whole),
        std.mem.sliceAsBytes(cx.items(types.Glyph)),
    );
}

// Locks one-line equality (section 2b): in a rect one line high, a wrapped line writes the
// records `place` writes with `align_y = .center`, at scales 1 and 1.25.
test "a one-line wrapped text places like place" {
    for ([_]u32{ 120, 150 }) |scale_120| {
        const rect: draw.Rect = .{ .x = 3.3, .y = 7.1, .width = 200, .height = 22 };
        const placed = test_context(scale_120);
        place(placed, sans_16, "Wrapped line", rect, window, .{
            .align_x = .start,
            .align_y = .center,
            .ellipsis = false,
        });
        var expected: [16]types.Glyph = undefined;
        const count = placed.items(types.Glyph).len;
        @memcpy(expected[0..count], placed.items(types.Glyph));
        const wrapped = test_context(scale_120);
        place_wrapped(wrapped, sans_16, "Wrapped line", rect, window, .{});
        try testing.expectEqual(count, wrapped.items(types.Glyph).len);
        for (expected[0..count], wrapped.items(types.Glyph)) |want, got| {
            try testing.expectEqual(want, got);
        }
    }
}

const outline_draw = [_]registry.DrawType{
    .{ .type = types.Glyph, .cap = 64 },
    .{ .type = draw.Fill, .cap = 256 },
};

const OutlineContext = draw.Context(&outline_draw, 4, 65536);

/// A freshly initialized static context with a `Fill` and the whole point pool, at `scale_120`.
fn outline_context(scale_120: u32) *OutlineContext {
    const static = struct {
        var context: OutlineContext = undefined;
    };
    static.context.init();
    static.context.text.scale_120 = scale_120;
    static.context.reset();
    return &static.context;
}

/// Checks every record of `glyphs` against the atlas instance `place` appended for it: the
/// instance `instance_of` builds from the record's pen and the rounded baseline. Records with
/// no ink have no instance. The first record's pen is also checked against `first_x`.
fn expect_pens(cx: *TestContext, glyphs: *Glyphs, scale: f32) !void {
    const placed = cx.items(types.Glyph);
    var at: usize = 0;
    var previous: ?Glyph = null;
    while (glyphs.next()) |glyph| {
        if (previous) |before| {
            if (before.line == glyph.line) {
                try testing.expectEqual(before.pen[0] + before.advance, glyph.pen[0]);
                try testing.expectEqual(before.pen[1], glyph.pen[1]);
            }
            try testing.expectEqual(before.index + 1, glyph.index);
        }
        previous = glyph;
        const font = text.font_of(glyph.style.face);
        const size_q = cx.text.size_key_of(glyph.style.size);
        const face: u8 = @backingInt(glyph.style.face);
        const entry = cx.text.glyph(face, font, glyph.glyph, size_q) orelse continue;
        if (entry.width == 0) continue;
        const want = instance_of(entry, size_q, glyph.pen[0], @round(glyph.pen[1] * scale), scale, .{
            .clip = window,
            .color = glyph.style.color,
        });
        try testing.expect(at < placed.len);
        try testing.expectEqual(want, placed[at]);
        at += 1;
    }
    try testing.expectEqual(placed.len, at);
}

// Locks the pens of `Glyphs.line` against `place_runs` (section 3b): over a mixed run with every
// alignment, at scales 1, 1.25, and 2, each inked record's instance is the one `place_runs`
// appended; the ellipsis record sits where `place_runs` puts it, and a line that cannot fit even
// its ellipsis yields nothing.
test "Glyphs.line walks the pens place_runs walks" {
    const big: text.Style = .{ .face = .sans_bold, .size = 21, .color = .{ 1, 0, 0, 1 } };
    const runs = [_]text.Run{
        .{ .style = sans_16, .bytes = "Pens, " },
        .{ .style = big, .bytes = "and h\u{e9}ights " },
        .{ .style = mono_10, .bytes = "ok" },
    };
    const rects = [_]draw.Rect{
        .{ .x = 3.3, .y = 7.1, .width = 400, .height = 40 },
        .{ .x = 3.3, .y = 7.1, .width = 150, .height = 40 },
    };
    const alignments = [_]text.Align{ .start, .center, .end };
    for ([_]u32{ 120, 150, 240 }) |scale_120| {
        const scale = @as(f32, @floatFromInt(scale_120)) / 120;
        for (rects) |rect| {
            for (alignments) |align_x| {
                const options: text.Options = .{
                    .align_x = align_x,
                    .align_y = .center,
                    .ellipsis = true,
                };
                const cx = test_context(scale_120);
                place_runs(cx, &runs, rect, window, options);
                var glyphs: Glyphs = .line(&runs, rect, options);
                try expect_pens(cx, &glyphs, scale);
            }
        }
    }
    const cx = test_context(120);
    const narrow: draw.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    const cut: text.Options = .{ .align_x = .start, .align_y = .start, .ellipsis = true };
    var glyphs: Glyphs = .line(&runs, narrow, cut);
    var last: Glyph = glyphs.next().?;
    while (glyphs.next()) |glyph| last = glyph;
    try testing.expectEqual(ellipsis_char, last.codepoint);
    place_runs(cx, &runs, narrow, window, cut);
    try testing.expect(last.pen[0] < narrow.width);
    var none: Glyphs = .line(&runs, .{ .x = 0, .y = 0, .width = 1, .height = 20 }, cut);
    try testing.expectEqual(@as(?Glyph, null), none.next());
}

// Locks the pens of `Glyphs.wrapped` against `place_runs_wrapped` over the fox's four lines,
// with start, center, and end alignment at scales 1 and 1.25 (baselines 11, 25, 39, 53 and 14,
// 31, 49, 66 at the line); the `line` counts are 0 to 3; a trailing space hangs and a hard break
// is dropped, so "ab cd " yields 5 records.
test "Glyphs.wrapped walks the pens place_runs_wrapped walks" {
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 30, .height = 100 };
    const runs = [_]text.Run{.{ .style = mono_10, .bytes = "nnn nnnnn nnnnn nnn" }};
    for ([_]u32{ 120, 150 }) |scale_120| {
        const scale = @as(f32, @floatFromInt(scale_120)) / 120;
        for ([_]text.Align{ .start, .center, .end }) |align_x| {
            for ([_]text.Align{ .start, .center, .end }) |align_y| {
                const options: text.WrapOptions = .{ .align_x = align_x, .align_y = align_y };
                const cx = test_context(scale_120);
                place_runs_wrapped(cx, &runs, rect, window, options);
                var glyphs: Glyphs = .wrapped(&runs, rect, options);
                try expect_pens(cx, &glyphs, scale);
            }
        }
    }
    var glyphs: Glyphs = .wrapped(&runs, rect, .{});
    var per_line: [4]u32 = @splat(0);
    while (glyphs.next()) |glyph| per_line[glyph.line] += 1;
    try testing.expectEqual([4]u32{ 3, 5, 5, 3 }, per_line);
    const hang = [_]text.Run{.{ .style = mono_10, .bytes = "ab cd " }};
    var hung: Glyphs = .wrapped(&hang, .{ .x = 0, .y = 0, .width = 500, .height = 20 }, .{});
    var count: u32 = 0;
    while (hung.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 5), count);
}

// Locks the codepoints: every one is yielded, spaces too, in order, and `index` counts them; a
// break space between lines belongs to neither ("aa bb" at 2 columns is 4 records).
test "Glyphs yields every codepoint and counts them" {
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 500, .height = 20 };
    const runs = [_]text.Run{
        .{ .style = mono_10, .bytes = "a b" },
        .{ .style = sans_16, .bytes = " c" },
    };
    var glyphs: Glyphs = .line(&runs, rect, .{ .align_x = .start, .align_y = .start, .ellipsis = false });
    var seen: [8]u21 = undefined;
    var count: u32 = 0;
    while (glyphs.next()) |glyph| {
        try testing.expectEqual(count, glyph.index);
        seen[count] = glyph.codepoint;
        count += 1;
    }
    try testing.expectEqualSlices(u21, &.{ 'a', ' ', 'b', ' ', 'c' }, seen[0..count]);
    const words = [_]text.Run{.{ .style = mono_10, .bytes = "aa bb" }};
    var wrapped: Glyphs = .wrapped(&words, .{ .x = 0, .y = 0, .width = 12, .height = 40 }, .{});
    var lines: [4]u32 = undefined;
    count = 0;
    while (wrapped.next()) |glyph| : (count += 1) lines[count] = glyph.line;
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1 }, lines[0..count]);
}

// Locks the outlines against the atlas: at 64 px and scale 1, with the pen rounded to device
// pixels as the atlas does, every pixel of each glyph's box in "Rag&g" is covered within 2/255
// of the cached bitmap. The Builder's zoom of 1/4 cancels `fill.tolerance_px`'s factor of 4, so
// the chords are the rasterizer's and only the pens can differ.
test "outline glyphs cover what the atlas bitmap covers" {
    const cx = test_context(120);
    const style: text.Style = .{ .face = .sans, .size = 64, .color = .{ 1, 1, 1, 1 } };
    const rect: draw.Rect = .{ .x = 5.4, .y = 3.2, .width = 600, .height = 90 };
    const runs = [_]text.Run{.{ .style = style, .bytes = "Rag&g" }};
    var glyphs: Glyphs = .line(&runs, rect, .{ .align_x = .start, .align_y = .center, .ellipsis = false });
    const shape = &test_shape;
    while (glyphs.next()) |glyph| {
        const font = text.font_of(glyph.style.face);
        const size_q = cx.text.size_key_of(glyph.style.size);
        const entry = cx.text.glyph(0, font, glyph.glyph, size_q).?;
        const pen: draw.Point = .{ @round(glyph.pen[0]), @round(glyph.pen[1]) };
        shape.* = .init(0.25);
        try testing.expect(contours(shape, glyph.style.face, glyph.glyph, 64, pen));
        var worst: f32 = 0;
        for (0..entry.height) |row| {
            for (0..entry.width) |column| {
                const texel = cx.text.mirror[(entry.y + row) * cache.atlas_side + entry.x + column];
                const x = pen[0] + @as(f32, @floatFromInt(entry.left)) + @as(f32, @floatFromInt(column)) + 0.5;
                const y = pen[1] - @as(f32, @floatFromInt(entry.top)) + @as(f32, @floatFromInt(row)) + 0.5;
                const got = draw.fill.coverage(shape.items(), .non_zero, x, y, 1);
                worst = @max(worst, @abs(got - @as(f32, @floatFromInt(texel)) / 255));
            }
        }
        try testing.expect(worst <= 2.0 / 255.0);
    }
}

var test_shape: draw.fill.Builder = undefined;

// Locks `contours`: a space has no ink and returns false; a codepoint the face does not map
// (U+0416 is outside the subset) draws `.notdef`'s box; a size of 2,000 is accepted, past
// `text.size_max`; and the glyph lands with its pen at the left of its advance, +y down.
test "contours add one glyph's outline" {
    const shape = &test_shape;
    shape.* = .init(1);
    const font = text.font_of(.sans);
    try testing.expect(!contours(shape, .sans, ttf.glyph_id(font, ' '), 16, .{ 0, 0 }));
    try testing.expectEqual(@as(u32, 0), shape.count);
    try testing.expect(contours(shape, .sans, ttf.glyph_id(font, 0x0416), 16, .{ 0, 0 }));
    const notdef = shape.count;
    try testing.expect(notdef >= 4);
    shape.reset();
    try testing.expect(contours(shape, .sans, ttf.replacement, 16, .{ 0, 0 }));
    try testing.expectEqual(notdef, shape.count);
    shape.reset();
    try testing.expect(contours(shape, .sans, ttf.glyph_id(font, 'H'), 2000, .{ 100, 1500 }));
    var low: f32 = 1.0e9;
    var high: f32 = -1.0e9;
    for (shape.items()) |edge| {
        low = @min(low, edge.a[1]);
        high = @max(high, edge.a[1]);
    }
    // H is a cap height tall: 0.714 of an em, standing on the baseline.
    try testing.expectApproxEqAbs(@as(f32, 1500), high, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1500 - 1429), low, 2);
}

// Locks the tolerance bound: every glyph from U+0021 to U+007E of the embedded faces is
// accepted, in one band plan, at 16, 64, 512, and 2,000 px. (The step page measures U+017F.)
test "every embedded glyph fits at tolerance_px" {
    const shape = &test_shape;
    for (&text.fonts, 0..) |*font, face_index| {
        const face: text.Face = @fromBackingInt(@as(u8, @intCast(face_index)));
        var code: u21 = 0x21;
        while (code < 0x7F) : (code += 1) {
            const id = ttf.glyph_id(font, code);
            if (id == 0) continue;
            for ([_]f32{ 16, 64, 512, 2000 }) |size| {
                shape.* = .init(1);
                if (!contours(shape, face, id, size, .{ 0, 0 })) continue;
                try testing.expect(!shape.overflowed);
                try testing.expect(draw.fill.plan_bands(shape.items()) != null);
            }
        }
    }
}

/// Points `place_outlines` made.
fn points_of(cx: *OutlineContext) u32 {
    return cx.point_count;
}

// Locks the clip box: a glyph whose box misses the clip costs no point (the same word placed
// wholly right of a clip that ends 60 px left of it appends nothing), a word half in is drawn whole, and the points of a
// word are the sum of its glyphs'.
test "place_outlines skips glyphs outside the clip" {
    const style: text.Style = .{ .face = .sans, .size = 32, .color = .{ 1, 0.5, 0, 1 } };
    const rect: draw.Rect = .{ .x = 10, .y = 10, .width = 600, .height = 40 };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    const cx = outline_context(120);
    place_outlines(cx, style, "Clip", rect, window, options);
    const whole = points_of(cx);
    try testing.expect(whole > 0);
    try testing.expectEqual(@as(u32, 0), cx.overflow_count);
    const instances = cx.items(draw.Fill).len;
    var sum: u32 = 0;
    for ("Clip") |letter| {
        const one = outline_context(120);
        const font = text.font_of(.sans);
        var shape: draw.fill.Builder = .init(1);
        try testing.expect(contours(&shape, .sans, ttf.glyph_id(font, letter), 32, .{ 10, 40 }));
        _ = draw.fill.append(one, &shape, .{ .color = style.color }, window);
        sum += points_of(one);
    }
    try testing.expectEqual(sum, whole);
    const far = outline_context(120);
    const left_of: draw.Clip = .{ .x0 = -200, .y0 = 0, .x1 = -60, .y1 = 720 };
    place_outlines(far, style, "Clip", rect, left_of, options);
    try testing.expectEqual(@as(u32, 0), points_of(far));
    const half = outline_context(120);
    const middle: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 12, .y1 = 720 };
    place_outlines(half, style, "Clip", rect, middle, options);
    try testing.expect(points_of(half) > 0 and points_of(half) < whole);
    try testing.expect(half.items(draw.Fill).len <= instances);
}

// Locks a refusal per glyph: at 16 px "i" takes 20 points and "W" 44, so a pool of 60 holds both
// i's but not the W after the first: "iWi" draws the i's and counts the W once.
test "place_outlines keeps the glyphs around a refused one" {
    const Small = draw.Context(&outline_draw, 4, 60);
    const static = struct {
        var context: Small = undefined;
    };
    static.context.init();
    static.context.reset();
    const cx = &static.context;
    const style: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
    place_outlines(cx, style, "iWi", .{ .x = 0, .y = 0, .width = 200, .height = 30 }, window, .{
        .align_x = .start,
        .align_y = .center,
        .ellipsis = false,
    });
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    const bands = cx.items(draw.Fill);
    try testing.expect(bands.len >= 2);
    try testing.expect(bands[0].rect[0] < bands[bands.len - 1].rect[0]);
}

// Locks the wrapped family: the same lines as `place_wrapped_outlines` draw, so a wrapped
// paragraph's shapes span as many lines as the layout has and none is refused.
test "place_wrapped_outlines draws every line" {
    const cx = outline_context(120);
    const style: text.Style = .{ .face = .sans, .size = 20, .color = .{ 1, 1, 1, 1 } };
    const rect: draw.Rect = .{ .x = 0, .y = 0, .width = 120, .height = 300 };
    const utf8 = "Outlines wrap like the atlas does";
    place_wrapped_outlines(cx, style, utf8, rect, window, .{});
    try testing.expectEqual(@as(u32, 0), cx.overflow_count);
    var tops: [8]f32 = undefined;
    var lines: u32 = 0;
    for (cx.items(draw.Fill)) |band| {
        var known = false;
        for (tops[0..lines]) |top| known = known or @abs(top - band.rect[1]) < 20;
        if (!known) {
            tops[lines] = band.rect[1];
            lines += 1;
        }
    }
    try testing.expectEqual(count_lines(&.{.{ .style = style, .bytes = utf8 }}, 120), lines);
}

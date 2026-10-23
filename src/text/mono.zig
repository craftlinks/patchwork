//! The monospace grid: one column per codepoint, a per-frame ASCII table, and direct appends.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Fast Path Beside `place_runs`
//! A code line is dozens of coloured tokens, and an editor draws thousands of glyphs a frame.
//! `place_runs` measures each run, then probes the glyph cache's hash table once per glyph.
//! In Noto Sans Mono every printable ASCII glyph advances the same 600 units (asserted at
//! compile time below), so column `c` sits at `x0 + c * advance` with no measuring at all,
//! and the cache entries of the 94 inked ASCII glyphs can be looked up once per frame into a
//! table indexed by byte. A glyph is then a table load and an append.
//!
//! ## 2. Frame Protocol
//! ```text
//! prepare(cx, size)   once per draw: metrics, size key, scale, and the ASCII table
//!                     (94 cache lookups; a miss rasterizes, so this is also the pre-warm,
//!                     and 94 is under the cache's per-frame `budget` of 256)
//! emit(cx, cp, x, baseline_px, paint)
//!                     ASCII: table entry; other codepoints: one cache lookup
//!                     skipped entry (budget, full atlas) or no ink: nothing appended
//! ```
//! A table slot whose key is 0 was skipped this frame; the cache already counted it as
//! pending, so the host draws again and the next `prepare` fills it.
//!
//! ## 3. Grid Algebra (logical pixels)
//! ```text
//! advance     = 600 * size / 1000                       (9.0 at 15 px)
//! line_height = ceil((ascent + descent) * size / 1000)  (21 at 15 px)
//! baseline_px = round((top + (line_height - ascent - descent) / 2 + ascent) * scale)
//! ```
//! The advance stays unsnapped, so layout does not depend on the display scale; each glyph's
//! origin is snapped exactly as `text.place` snaps it, because both build the instance with
//! `layout.instance_of`. `baseline_px` equals `place`'s vertically centred baseline in a rect
//! `line_height` tall, so a mono line and `place` of the same bytes write the same records
//! (test "mono emits the records text.place writes").
//!
//! ## 4. Codepoints
//! One column per codepoint. A glyph wider than a column (U+FFFD advances 1200 units)
//! overlaps the next column, and a zero-advance combining mark takes a column of its own.
//!
//! ## 5. TigerStyle Invariants
//! - The table is 128 entries in the caller's storage; nothing allocates.
//! - `emit` is O(1); one cache probe at most.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const ttf = @import("ttf.zig");
const cache = @import("cache.zig");
const layout = @import("layout.zig");

pub const Paint = layout.Paint;

/// Font units every printable ASCII glyph of the mono face advances.
pub const advance_units: u32 = 600;

const face = text.Face.mono;

/// The column width of the mono face at `size`, in logical pixels.
pub fn advance_of(size: f32) f32 {
    assert(size > 0);
    assert(size <= text.size_max);
    const font = text.font_of(face);
    return @as(f32, @floatFromInt(advance_units)) * size /
        @as(f32, @floatFromInt(font.units_per_em));
}

/// The line pitch of the mono face at `size`: ascent plus descent, rounded up to a whole
/// logical pixel so lines tile without seams at integer scales.
pub fn line_height_of(size: f32) f32 {
    assert(size > 0);
    assert(size <= text.size_max);
    const font = text.font_of(face);
    const em = size / @as(f32, @floatFromInt(font.units_per_em));
    const extent = @as(f32, @floatFromInt(font.ascent + font.descent)) * em;
    return @ceil(extent);
}

/// The per-frame grid. See the module guide, section 2.
pub const Mono = struct {
    /// Cache entries of ASCII glyphs by byte; key 0 is skipped this frame or not drawn.
    table: [128]cache.Entry,
    size: f32,
    size_q: u32,
    scale: f32,
    advance: f32,
    ascent: f32,
    descent: f32,
    line_height: f32,

    /// Fills the grid for `size` at the draw context's scale and looks up the inked ASCII
    /// glyphs. Draw phase only; `cx` is the draw context.
    pub fn prepare(self: *Mono, cx: anytype, size: f32) void {
        assert(size > 0);
        assert(cx.text.scale_120 >= 1);
        const font = text.font_of(face);
        const em = size / @as(f32, @floatFromInt(font.units_per_em));
        self.size = size;
        self.size_q = text.size_key(size, cx.text.scale_120);
        self.scale = @as(f32, @floatFromInt(cx.text.scale_120)) / 120;
        self.advance = advance_of(size);
        self.ascent = @as(f32, @floatFromInt(font.ascent)) * em;
        self.descent = @as(f32, @floatFromInt(font.descent)) * em;
        self.line_height = line_height_of(size);
        for (&self.table) |*slot| slot.key = 0;
        var byte: u8 = '!';
        while (byte <= '~') : (byte += 1) {
            const glyph = cx.text.glyph(@backingInt(face), font, font.ascii[byte], self.size_q);
            if (glyph) |entry| self.table[byte] = entry;
        }
        assert(self.table[' '].key == 0);
        assert(self.line_height >= self.ascent + self.descent);
    }

    /// The device row of the baseline of a line whose top is `top` (section 3).
    pub fn baseline_of(self: *const Mono, top: f32) f32 {
        assert(self.scale > 0);
        assert(top == top);
        const gap = self.line_height - self.ascent - self.descent;
        return @round((top + gap * 0.5 + self.ascent) * self.scale);
    }

    /// Appends the glyph of `codepoint` with its pen at `pen_x` on `baseline_px`. Nothing
    /// for a glyph without ink, a control, or one the cache skipped this frame.
    pub fn emit(
        self: *const Mono,
        cx: anytype,
        codepoint: u21,
        pen_x: f32,
        baseline_px: f32,
        paint: Paint,
    ) void {
        assert(self.size_q >= 1);
        assert(paint.clip.x1 > paint.clip.x0);
        const entry = if (codepoint < 128) self.table[codepoint] else self.lookup(cx, codepoint);
        if (entry.key == 0) return;
        if (entry.width == 0) return;
        const glyph = layout.instance_of(entry, self.size_q, pen_x, baseline_px, self.scale, paint);
        layout.append_glyph(cx, glyph);
    }

    fn lookup(self: *const Mono, cx: anytype, codepoint: u21) cache.Entry {
        assert(codepoint >= 128);
        const font = text.font_of(face);
        const id = ttf.glyph_id(font, codepoint);
        const none: cache.Entry = .{
            .key = 0,
            .x = 0,
            .y = 0,
            .left = 0,
            .top = 0,
            .raster_q = 1,
            .width = 0,
            .height = 0,
        };
        return cx.text.glyph(@backingInt(face), font, id, self.size_q) orelse none;
    }
};

comptime {
    @setEvalBranchQuota(20_000);
    const font = &text.fonts[@backingInt(face)];
    var byte: u8 = ' ';
    while (byte <= '~') : (byte += 1) {
        assert(ttf.advance(font, font.ascii[byte]) == advance_units);
    }
    assert(font.units_per_em == 1000);
}

const testing = std.testing;
const types = @import("../draw/types.zig");
const draw = @import("../draw.zig");
const registry = @import("../draw/registry.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Glyph, .cap = 256 },
};

const TestContext = draw.Context(&test_draw, 4, 0);

fn test_context(scale_120: u32) *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    static.context.text.scale_120 = scale_120;
    static.context.reset();
    return &static.context;
}

// Locks the 15 px grid the editor uses: a 9.0 px advance and a 21 px line pitch.
test "mono metrics at 15 px are a 9 px advance and a 21 px line" {
    try testing.expectEqual(@as(f32, 9), advance_of(15));
    try testing.expectEqual(@as(f32, 21), line_height_of(15));
    try testing.expectEqual(@as(f32, 9.6), advance_of(16));
}

// Locks byte-for-byte agreement with `text.place`: a mono line emitted column by column at
// scales 1, 1.5, and 2 writes exactly the records `place` writes for the same bytes in a rect
// one line tall (start aligned on x, centred on y), non-ASCII included, once both caches
// packed their glyphs in the same order.
test "mono emits the records text.place writes" {
    const line = "k(-0.98~0.445, \"fl\u{e4}nge\") // x";
    const rect: draw.Rect = .{ .x = 10.25, .y = 31.5, .width = 900, .height = line_height_of(15) };
    const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
    const color: [4]f32 = .{ 0.5, 0.75, 1, 1 };
    for ([_]u32{ 120, 180, 240 }) |scale_120| {
        const placed = test_context(scale_120);
        // Warm the atlas in the grid's order, so both paths pack glyphs at the same texels.
        var warm: Mono = undefined;
        warm.prepare(placed, 15);
        const style: text.Style = .{ .face = .mono, .size = 15, .color = color };
        const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
        text.place(placed, style, line, rect, clip, options);
        var expected: [64]types.Glyph = undefined;
        const count = placed.items(types.Glyph).len;
        @memcpy(expected[0..count], placed.items(types.Glyph));
        const gridded = test_context(scale_120);
        var mono: Mono = undefined;
        mono.prepare(gridded, 15);
        const baseline = mono.baseline_of(rect.y);
        var index: u32 = 0;
        var column: u32 = 0;
        while (index < line.len) : (column += 1) {
            const codepoint = layout.decode(line, &index);
            const x = rect.x + @as(f32, @floatFromInt(column)) * mono.advance;
            mono.emit(gridded, codepoint, x, baseline, .{ .clip = clip, .color = color });
        }
        try testing.expectEqual(count, gridded.items(types.Glyph).len);
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(expected[0..count]),
            std.mem.sliceAsBytes(gridded.items(types.Glyph)),
        );
    }
}

// Locks the table as the pre-warm: one `prepare` rasterizes the 94 inked ASCII glyphs within
// the frame budget, leaves nothing pending, and a second frame's `prepare` rasterizes none.
test "prepare warms the ASCII set within one frame budget" {
    const cx = test_context(120);
    var mono: Mono = undefined;
    mono.prepare(cx, 15);
    try testing.expectEqual(@as(u32, 94), cx.text.new_count);
    try testing.expectEqual(@as(u32, 0), cx.text.pending);
    try testing.expect(mono.table['a'].key != 0);
    try testing.expectEqual(@as(u32, 0), mono.table[' '].key);
    cx.reset();
    mono.prepare(cx, 15);
    try testing.expectEqual(@as(u32, 0), cx.text.new_count);
}

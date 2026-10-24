//! Glyph cache: an open-addressing table over a shelf-packed `r8` atlas with a CPU mirror.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Rasterize on Demand at Device Size
//! A baked single-size atlas downsamples at one scale and blurs at another, and cannot hold
//! several sizes, bold, monospace, and non-ASCII text. The cache instead rasterizes each
//! (face, glyph, size) the first time a frame draws it, at the device pixel size the frame
//! is presented at, into a `atlas_side` square `r8` texture (texture 0). A scale change
//! re-rasterizes only what is drawn afterwards.
//!
//! ## 2. Keys and Entries
//! The size key is `size_q = round(size_logical * scale_120 / 30)`, the em size in quarter
//! device pixels. The key packs an occupied bit, the face, `size_q`, and the 12-bit glyph id:
//! ```text
//! key = 1 << 31 | face << 28 | size_q << 12 | glyph
//! ```
//! `slot_count` slots are probed linearly from a multiplicative hash, and at most
//! `entry_cap` (half of them) are filled, so a probe sequence stays short and always ends on
//! an empty slot. An entry holds the bitmap's atlas position, size, and `raster::Box`
//! bearings (`left`, `top`) in raster pixels, and `raster_q`, the size it was rasterized at.
//! A glyph whose bitmap would exceed `raster.side_cap` is rasterized at the largest
//! `raster_q` that fits, and the quad is stretched by `size_q / raster_q`. A glyph without
//! ink is an entry with zero width that takes no atlas space.
//!
//! ## 2a. Zoom
//! Inside a canvas (`ui/cx.zig`) text is placed in world pixels and drawn through a view at a
//! zoom. `zoom` is the canvas's glyph zoom, a rung of the zoom ladder (`ui/canvas.zig`), and 1
//! elsewhere. `device_scale` (`scale_120 / 120 * zoom`) is what placement snaps to, and
//! `size_key_of(size)` keys `size * zoom`, so a canvas at rung `q` rasterizes and snaps exactly as
//! unzoomed text at `q` times the size would. Multiplying by 1 is exact, so text outside a
//! canvas keys and snaps bit for bit as before.
//!
//! ## 3. Frame Protocol
//! ```text
//! begin_frame   (Context.reset)  reset the table and shelves if `reset_owed`; zero the
//!                                per-frame counters; note whether the atlas starts empty
//! glyph         (text.place)     hit: return the entry
//!                                miss: within `budget` and space: load, rasterize into the
//!                                mirror, pack, insert, grow the dirty rectangle
//!                                over budget: `pending += 1`, skip the glyph
//!                                atlas or table full: `reset_owed`, `pending += 1`, skip
//! queue_upload  (Renderer.frame) one strided write of the dirty rectangle, then clear it
//! owes_draw     (hosts)          the scale moved, or `pending` or `reset_owed` is set
//! ```
//! A reset happens only at the start of a frame, so no instance of the frame being drawn
//! can point at a region that was reused. A host that sees `owes_draw` after presenting
//! requests another frame, which draws again and finishes the pending glyphs.
//!
//! Thrash guard: a frame that starts on an empty atlas and fills it cannot be helped by a
//! reset, so its skipped glyphs count in `overflow_count` instead of `pending` and no reset
//! is owed. `epoch` counts resets and is read only by tests.
//!
//! ## 4. Mirror and Uploads
//! `mirror` is the CPU copy of the atlas. A new glyph is rasterized straight into it at its
//! packed position, and the one-texel gutter to its right and below is zeroed, so filtering
//! at a glyph's edge never reads a neighbour or a stale glyph from before a reset. A reset
//! therefore clears only the table's keys (`slot_count` words), never the 1 MiB mirror:
//! every texel a later entry references is rewritten when that entry is packed.
//!
//! `queue_upload` queues one `Textures.write_strided` of the dirty rectangle with
//! `bytes_per_row = atlas_side`, pointing into the mirror. The mirror must not change between
//! that call and the submit of the stream that carries the write; it does not, because the
//! renderer records the write after `App.draw` and the next change happens in the next draw.
//!
//! ## 5. TigerStyle Invariants
//! - All storage is fixed arrays inside `draw.Context` (BSS on wasm); nothing allocates.
//! - New-glyph work per frame is bounded by `budget`, `raster.side_cap`, and
//!   `raster.edge_cap`. A hit is one hash probe sequence; `begin_frame` is O(1) unless a
//!   reset is owed.

const std = @import("std");
const assert = std.debug.assert;
const raster = @import("raster.zig");
const text = @import("../text.zig");
const textures = @import("../draw/textures.zig");
const ttf = @import("ttf.zig");

/// Atlas edge in texels. A power of two, so UVs are exact.
pub const atlas_side: u32 = 1024;
/// Hash table slots.
pub const slot_count: u32 = 4096;
/// Entries the table may hold: half the slots, so probes stay short.
pub const entry_cap: u32 = slot_count / 2;
/// New rasterizations per frame; the rest are pending until the next frame.
pub const budget: u32 = 256;
/// Texels kept empty right of and below every glyph.
pub const gutter: u32 = 1;
/// Largest `size_q` the key holds.
pub const size_q_max: u32 = (1 << 16) - 1;

/// Where one rasterized glyph lives and how it sits on the pen. See the module guide.
pub const Entry = struct {
    key: u32,
    x: u16,
    y: u16,
    left: i16,
    top: i16,
    raster_q: u16,
    width: u8,
    height: u8,
};

/// The texel rectangle written since the last upload, exclusive max.
const Dirty = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

pub const Cache = struct {
    mirror: [atlas_side * atlas_side]u8,
    entries: [slot_count]Entry,
    entry_count: u32,
    shelf_x: u32,
    shelf_y: u32,
    shelf_height: u32,
    /// Display scale for this frame's draw, in 1/120 units. The host sets it.
    scale_120: u32,
    /// The glyph zoom of the open canvas (section 2a), 1 outside one.
    zoom: f32,
    /// `scale_120` at the last `begin_frame`; 0 before the first.
    drawn_scale_120: u32,
    /// Glyphs rasterized since `begin_frame`.
    new_count: u32,
    /// Glyphs skipped this frame that a later frame will draw.
    pending: u32,
    /// Glyphs skipped this frame that no reset can fit (thrash guard).
    overflow_count: u32,
    /// Resets so far.
    epoch: u32,
    reset_owed: bool,
    /// True when this frame began with an empty table.
    fresh: bool,
    dirty: ?Dirty,
    outline: ttf.Outline,
    raster: raster.Raster,

    /// An empty cache at scale 1. Out-pointer init so a static cache needs no stack copy.
    pub fn init(self: *Cache) void {
        self.clear_table();
        self.scale_120 = 120;
        self.zoom = 1;
        self.drawn_scale_120 = 0;
        self.new_count = 0;
        self.pending = 0;
        self.overflow_count = 0;
        self.epoch = 0;
        self.reset_owed = false;
        self.fresh = true;
        self.dirty = null;
        assert(self.entry_count == 0);
        assert(!self.reset_owed);
    }

    /// Device pixels per logical (or, in a canvas, world) pixel of text drawn now:
    /// `scale_120 / 120 * zoom` (section 2a).
    pub fn device_scale(self: *const Cache) f32 {
        assert(self.scale_120 >= 1);
        assert(self.zoom > 0);
        return @as(f32, @floatFromInt(self.scale_120)) / 120 * self.zoom;
    }

    /// The size key of an em of `size` pixels drawn now: `size * zoom` at the frame's scale.
    pub fn size_key_of(self: *const Cache, size: f32) u32 {
        assert(self.zoom > 0);
        return text.size_key(size * self.zoom, self.scale_120);
    }

    /// Starts a frame's draw: resets if owed, zeroes the per-frame counters, and records the
    /// scale the frame draws at. See the module guide, section 3.
    pub fn begin_frame(self: *Cache) void {
        assert(self.scale_120 >= 1);
        if (self.reset_owed) {
            self.clear_table();
            self.reset_owed = false;
            self.epoch += 1;
        }
        self.fresh = self.entry_count == 0;
        self.new_count = 0;
        self.pending = 0;
        self.overflow_count = 0;
        self.drawn_scale_120 = self.scale_120;
        assert(!self.reset_owed);
        assert(self.pending == 0);
    }

    /// True when the scene must be drawn again even if the app is clean: the display scale
    /// differs from the last draw's, or glyphs were skipped that a frame can still draw.
    pub fn owes_draw(self: *const Cache, scale_120: u32) bool {
        assert(scale_120 >= 1);
        if (scale_120 != self.drawn_scale_120) {
            return true;
        }
        if (self.reset_owed) {
            assert(!self.fresh);
            return true;
        }
        return self.pending != 0;
    }

    /// The entry for `glyph` of `face` at `size_q`, rasterizing it on a miss. Null when the
    /// glyph is skipped this frame (budget, full atlas, or overflow).
    pub fn glyph(
        self: *Cache,
        face: u8,
        font: *const ttf.Font,
        glyph_id: u16,
        size_q: u32,
    ) ?Entry {
        assert(face < 4);
        assert(size_q >= 1);
        assert(size_q <= size_q_max);
        assert(glyph_id < ttf.glyph_cap);
        const key: u32 = 1 << 31 | @as(u32, face) << 28 | size_q << 12 | glyph_id;
        const slot = self.probe(key);
        if (self.entries[slot].key == key) {
            return self.entries[slot];
        }
        assert(self.entries[slot].key == 0);
        return self.miss(slot, key, font, glyph_id, size_q);
    }

    /// Queues the dirty rectangle of the mirror as one strided write to texture 0.
    pub fn queue_upload(self: *Cache, table: *textures.Textures) void {
        const dirty = self.dirty orelse return;
        assert(dirty.x1 > dirty.x0);
        assert(dirty.y1 > dirty.y0);
        assert(dirty.x1 <= atlas_side);
        assert(dirty.y1 <= atlas_side);
        const region: textures.Region = .{
            .x = dirty.x0,
            .y = dirty.y0,
            .width = dirty.x1 - dirty.x0,
            .height = dirty.y1 - dirty.y0,
        };
        const first = dirty.y0 * atlas_side + dirty.x0;
        const length = (region.height - 1) * atlas_side + region.width;
        table.write_strided(.atlas, region, atlas_side, self.mirror[first..][0..length]);
        self.dirty = null;
    }

    /// The slot holding `key`, or the empty slot where it belongs.
    fn probe(self: *const Cache, key: u32) u32 {
        assert(key != 0);
        assert(self.entry_count < slot_count);
        const hash: u32 = @truncate((@as(u64, key) *% 0x9E3779B97F4A7C15) >> 52);
        var slot = hash & (slot_count - 1);
        var steps: u32 = 0;
        while (steps < slot_count) : (steps += 1) {
            const found = self.entries[slot].key;
            if (found == key) return slot;
            if (found == 0) return slot;
            slot = (slot + 1) & (slot_count - 1);
        }
        unreachable;
    }

    fn miss(
        self: *Cache,
        slot: u32,
        key: u32,
        font: *const ttf.Font,
        glyph_id: u16,
        size_q: u32,
    ) ?Entry {
        if (self.reset_owed) {
            self.pending += 1;
            return null;
        }
        if (self.new_count == budget) {
            self.pending += 1;
            return null;
        }
        if (self.entry_count == entry_cap) {
            self.note_full();
            return null;
        }
        const scaled = self.load_scaled(font, glyph_id, size_q);
        var entry: Entry = .{
            .key = key,
            .x = 0,
            .y = 0,
            .left = 0,
            .top = 0,
            .raster_q = @intCast(scaled.raster_q),
            .width = 0,
            .height = 0,
        };
        if (scaled.ink) {
            const spot = self.pack(scaled.box.width, scaled.box.height) orelse {
                self.note_full();
                return null;
            };
            self.draw_into(scaled.box, spot);
            entry.x = @intCast(spot.x);
            entry.y = @intCast(spot.y);
            entry.left = @intCast(scaled.box.left);
            entry.top = @intCast(scaled.box.top);
            entry.width = @intCast(scaled.box.width);
            entry.height = @intCast(scaled.box.height);
            self.new_count += 1;
        }
        self.entries[slot] = entry;
        self.entry_count += 1;
        assert(self.entry_count <= entry_cap);
        return entry;
    }

    const Scaled = struct {
        ink: bool,
        raster_q: u32,
        box: raster.Box,
    };

    /// Loads the outline (or the replacement) into `self.outline`, picks the raster size,
    /// and flattens it into `self.raster`. See the module guide, section 2.
    fn load_scaled(self: *Cache, font: *const ttf.Font, glyph_id: u16, size_q: u32) Scaled {
        var outcome = ttf.load(font, glyph_id, &self.outline);
        if (outcome == .replace) {
            outcome = ttf.load(font, ttf.replacement, &self.outline);
            assert(outcome == .ready);
        }
        if (outcome == .empty) {
            return .{ .ink = false, .raster_q = size_q, .box = undefined };
        }
        const raster_q = fit_q(&self.outline, font.units_per_em, size_q);
        var scale = scale_of(raster_q, font.units_per_em);
        var box = raster.box_of(&self.outline, scale);
        if (!raster.flatten(&self.raster, &self.outline, scale, box)) {
            const replaced = ttf.load(font, ttf.replacement, &self.outline);
            assert(replaced == .ready);
            scale = scale_of(fit_q(&self.outline, font.units_per_em, raster_q), font.units_per_em);
            box = raster.box_of(&self.outline, scale);
            const flattened = raster.flatten(&self.raster, &self.outline, scale, box);
            assert(flattened);
        }
        if (box.width == 0 or box.height == 0) {
            return .{ .ink = false, .raster_q = raster_q, .box = box };
        }
        assert(box.width <= raster.side_cap);
        assert(box.height <= raster.side_cap);
        return .{ .ink = true, .raster_q = raster_q, .box = box };
    }

    const Spot = struct {
        x: u32,
        y: u32,
    };

    /// Places a `width` by `height` bitmap plus its gutter on the shelves; null when full.
    fn pack(self: *Cache, width: u32, height: u32) ?Spot {
        assert(width >= 1);
        assert(height >= 1);
        const cell_width = width + gutter;
        const cell_height = height + gutter;
        if (self.shelf_x + cell_width > atlas_side) {
            self.shelf_y += self.shelf_height;
            self.shelf_x = 0;
            self.shelf_height = 0;
        }
        if (self.shelf_y + cell_height > atlas_side) {
            return null;
        }
        const spot: Spot = .{ .x = self.shelf_x, .y = self.shelf_y };
        self.shelf_x += cell_width;
        self.shelf_height = @max(self.shelf_height, cell_height);
        assert(spot.x + cell_width <= atlas_side);
        assert(spot.y + cell_height <= atlas_side);
        return spot;
    }

    /// Rasterizes the flattened edges into the mirror at `spot`, zeroes the gutter, and
    /// grows the dirty rectangle over the cell.
    fn draw_into(self: *Cache, box: raster.Box, spot: Spot) void {
        const first = spot.y * atlas_side + spot.x;
        const target = self.mirror[first..][0 .. (box.height - 1) * atlas_side + box.width];
        raster.fill(&self.raster, box, target, atlas_side);
        var row: u32 = 0;
        while (row < box.height) : (row += 1) {
            self.mirror[first + row * atlas_side + box.width] = 0;
        }
        @memset(self.mirror[first + box.height * atlas_side ..][0 .. box.width + gutter], 0);
        const x1 = spot.x + box.width + gutter;
        const y1 = spot.y + box.height + gutter;
        if (self.dirty) |*dirty| {
            dirty.x0 = @min(dirty.x0, spot.x);
            dirty.y0 = @min(dirty.y0, spot.y);
            dirty.x1 = @max(dirty.x1, x1);
            dirty.y1 = @max(dirty.y1, y1);
        } else {
            self.dirty = .{ .x0 = spot.x, .y0 = spot.y, .x1 = x1, .y1 = y1 };
        }
        assert(self.dirty.?.x1 <= atlas_side);
        assert(self.dirty.?.y1 <= atlas_side);
    }

    /// The atlas or the table is full: owe a reset, unless this frame began empty.
    fn note_full(self: *Cache) void {
        if (self.fresh) {
            self.overflow_count += 1;
            assert(!self.reset_owed);
            return;
        }
        self.reset_owed = true;
        self.pending += 1;
        assert(self.reset_owed);
    }

    fn clear_table(self: *Cache) void {
        for (&self.entries) |*entry| {
            entry.key = 0;
        }
        self.entry_count = 0;
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_height = 0;
        assert(self.entry_count == 0);
    }
};

/// Pixels per font unit at `size_q` quarter pixels per em.
fn scale_of(size_q: u32, units_per_em: u32) f32 {
    assert(size_q >= 1);
    assert(units_per_em >= 1);
    const em_px = @as(f32, @floatFromInt(size_q)) / 4;
    return em_px / @as(f32, @floatFromInt(units_per_em));
}

/// The largest raster size at most `size_q` whose bitmap fits `raster.side_cap`.
fn fit_q(outline: *const ttf.Outline, units_per_em: u32, size_q: u32) u32 {
    assert(outline.point_count >= 1);
    const extent = @max(outline.x_max - outline.x_min, outline.y_max - outline.y_min);
    if (extent <= 0) {
        return size_q;
    }
    // A box spans at most the extent plus one pixel at each end, so two pixels are reserved.
    const usable: f32 = @floatFromInt(raster.side_cap - 2);
    const em: f32 = @floatFromInt(units_per_em);
    const largest: u32 = @intFromFloat(@floor(4 * usable * em / extent));
    assert(largest >= 1);
    return @min(size_q, largest);
}

comptime {
    assert(std.math.isPowerOfTwo(slot_count));
    assert(std.math.isPowerOfTwo(atlas_side));
    assert(entry_cap * 2 == slot_count);
    assert(atlas_side <= std.math.maxInt(u16));
    assert(raster.side_cap <= std.math.maxInt(u8));
    assert(size_q_max < 1 << 16);
    assert(@sizeOf(Entry) == 16);
    assert(budget <= entry_cap);
}

const testing = std.testing;

/// The static cache the tests share; each test starts with `init`.
const fixture = struct {
    var cache: Cache = undefined;
    var table: textures.Textures = undefined;
};

fn fresh_cache() *Cache {
    fixture.cache.init();
    fixture.cache.begin_frame();
    return &fixture.cache;
}

/// The glyph id of `codepoint` in Noto Sans.
fn id_of(codepoint: u21) u16 {
    return ttf.glyph_id(text.font_of(.sans), codepoint);
}

// Locks the hit and miss paths: a miss rasterizes once and inserts, a hit returns the same
// entry without new work, a glyph without ink is an entry of zero width that takes no budget,
// and the first frame's dirty rectangle uploads as one strided write.
test "a miss rasterizes once and a hit reuses the entry" {
    const cache = fresh_cache();
    const font = text.font_of(.sans);
    const first = cache.glyph(0, font, id_of('H'), 64).?;
    try testing.expectEqual(@as(u32, 1), cache.new_count);
    try testing.expectEqual(@as(u32, 1), cache.entry_count);
    try testing.expectEqual(@as(u16, 64), first.raster_q);
    const again = cache.glyph(0, font, id_of('H'), 64).?;
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(u32, 1), cache.new_count);
    const space = cache.glyph(0, font, id_of(' '), 64).?;
    try testing.expectEqual(@as(u8, 0), space.width);
    try testing.expectEqual(@as(u32, 1), cache.new_count);
    // Another size is another key.
    _ = cache.glyph(0, font, id_of('H'), 96).?;
    try testing.expectEqual(@as(u32, 2), cache.new_count);
    fixture.table.init();
    _ = fixture.table.create(.r8, atlas_side, atlas_side);
    cache.queue_upload(&fixture.table);
    try testing.expectEqual(@as(u32, 1), fixture.table.write_count);
    try testing.expectEqual(atlas_side, fixture.table.writes[0].bytes_per_row);
    cache.queue_upload(&fixture.table);
    try testing.expectEqual(@as(u32, 1), fixture.table.write_count);
}

// Locks the per-frame budget: the glyph after `budget` new ones is skipped and pending, the
// cache owes a draw, and the next frame rasterizes only that glyph. A settled frame after it
// rasterizes nothing and dirties nothing.
test "the budget carries the rest over to the next frame" {
    const cache = fresh_cache();
    const font = text.font_of(.sans);
    var drawn: u32 = 0;
    // Distinct sizes give distinct keys for one inked glyph.
    while (drawn <= budget) : (drawn += 1) {
        _ = cache.glyph(0, font, id_of('x'), 40 + drawn);
    }
    try testing.expectEqual(budget, cache.new_count);
    try testing.expectEqual(@as(u32, 1), cache.pending);
    try testing.expect(cache.owes_draw(120));
    cache.begin_frame();
    drawn = 0;
    while (drawn <= budget) : (drawn += 1) {
        try testing.expect(cache.glyph(0, font, id_of('x'), 40 + drawn) != null);
    }
    try testing.expectEqual(@as(u32, 1), cache.new_count);
    try testing.expect(!cache.owes_draw(120));
    cache.dirty = null;
    cache.begin_frame();
    drawn = 0;
    while (drawn <= budget) : (drawn += 1) {
        _ = cache.glyph(0, font, id_of('x'), 40 + drawn);
    }
    try testing.expectEqual(@as(u32, 0), cache.new_count);
    try testing.expectEqual(@as(?Dirty, null), cache.dirty);
    try testing.expect(!cache.owes_draw(120));
    try testing.expect(cache.owes_draw(180));
}

/// Requests "M" at `count` distinct large sizes; each clamps to a bitmap near `side_cap`.
fn request_large(cache: *Cache, first_q: u32, count: u32) void {
    const font = text.font_of(.sans);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        _ = cache.glyph(0, font, id_of('M'), first_q + index);
    }
}

// Locks the full-atlas rule and its thrash guard. A frame that did not start empty and fills
// the atlas skips the glyph as pending and owes a reset; the next frame resets the table and
// shelves (the epoch moves) and starts fresh. A fresh frame that fills the atlas again counts
// overflow, owes no reset, and asks for no further frame.
test "a full atlas resets next frame and a fresh overflow does not thrash" {
    const cache = fresh_cache();
    request_large(cache, 4000, 1);
    try testing.expectEqual(@as(u32, 1), cache.entry_count);
    cache.begin_frame();
    try testing.expect(!cache.fresh);
    request_large(cache, 5000, 64);
    try testing.expect(cache.reset_owed);
    try testing.expect(cache.pending >= 1);
    try testing.expectEqual(@as(u32, 0), cache.overflow_count);
    try testing.expect(cache.owes_draw(120));
    const filled = cache.entry_count;
    try testing.expect(filled >= 30);
    cache.begin_frame();
    try testing.expectEqual(@as(u32, 1), cache.epoch);
    try testing.expectEqual(@as(u32, 0), cache.entry_count);
    try testing.expect(cache.fresh);
    request_large(cache, 6000, 64);
    try testing.expect(!cache.reset_owed);
    try testing.expectEqual(@as(u32, 0), cache.pending);
    try testing.expect(cache.overflow_count >= 1);
    try testing.expect(!cache.owes_draw(120));
    try testing.expectEqual(filled, cache.entry_count);
}

// Locks the clamp: a glyph whose bitmap would exceed `raster.side_cap` is rasterized at the
// largest quarter-pixel size that fits, and its entry records that size for the stretch.
test "an oversized glyph is rasterized at the clamped size" {
    const cache = fresh_cache();
    const entry = cache.glyph(0, text.font_of(.sans), id_of('M'), 4 * 400).?;
    try testing.expect(entry.raster_q < 4 * 400);
    try testing.expect(entry.width <= raster.side_cap);
    try testing.expect(entry.height <= raster.side_cap);
    try testing.expect(@max(entry.width, entry.height) >= raster.side_cap - 8);
}

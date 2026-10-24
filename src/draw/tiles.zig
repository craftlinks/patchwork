//! Tile hashes: which parts of the window a frame changed, for the pixel cache.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Hash Tiles
//! Every frame rebuilds every instance (immediate mode), and most frames change a few percent
//! of the window: a playhead, a caret line, a meter. The renderer keeps the last frame's pixels
//! in a render target and repaints only what changed (`draw/renderer.zig`, section 6). This
//! module decides what changed without any dirty tracking in widgets: the window is a grid of
//! `side_px` device-pixel tiles, every instance folds a key (its record bytes, its batch, and
//! what else it reads) into each tile its bounds touch, in draw order, and a tile whose hash
//! differs from the last frame's is dirty. Idea and measurements: Blick's "Caching an
//! immediate-mode UI" and the step-18 review (0.2 to 3.2% of tiles change per frame).
//!
//! ## 2. Data Flow
//! ```text
//! begin(width_px, height_px)   grid = ceil(size / side_px); a new grid has no previous frame
//! add(bounds, key) per instance, in draw order:
//!     every tile the bounds touch:  hash = (hash ^ key) * prime
//! force(bounds) per animated instance: every tile the bounds touch is dirty this frame
//! finish()                     dirty = hash != previous (all, without a previous frame)
//!                              or forced; previous = hash
//! repeat()                     instead of begin/add/finish, for a frame whose instances are
//!                              the last frame's: dirty = the last frame's forced tiles
//! rects(out)                   dirty runs per row, merged down rows with equal spans, at most
//!                              `out.len` rects, else one bounding rect; device pixels
//! ```
//! The fold is order dependent, so a reorder (a batch moving above another) dirties the tiles
//! it touches. Bounds are the instance's `rect` intersected with its `clip`, in device pixels,
//! grown by one pixel on every side so rounding at a tile edge can never miss a pixel the
//! instance touches. A draw type leaves every pixel outside its `rect` untouched (registry
//! guide, section 2a), so the bounds are exact up to that pixel.
//!
//! An animated instance (`draw/registry.zig`, section 2b) changes pixels without changing its
//! key, so its tiles are forced dirty every frame. When the renderer knows the instances are
//! exactly the last frame's (no record, point, texture, or size changed), the hashes would equal
//! `previous` by construction, and `repeat` skips folding them.
//!
//! ## 3. TigerStyle Invariants
//! - Fixed storage: `tile_cap` hashes twice and two bit sets, about 260 KiB; a target with more
//!   tiles than that is not cached (`begin` returns false).
//! - `add` is linear in the tiles an instance touches; `finish` and `rects` in the tile count.

const std = @import("std");
const assert = std.debug.assert;

/// Tile side in device pixels.
pub const side_px: u32 = 64;

/// Most tiles: an 8192 by 8192 target.
pub const tile_cap: u32 = 16384;

/// Most rects `rects` returns for one frame.
pub const rect_cap: u32 = 8;

const prime: u64 = 0x100000001b3;

/// The odd multiplier of `key_of` (2^64 divided by the golden ratio).
const golden: u64 = 0x9E3779B97F4A7C15;

/// A key for `bytes` (a whole number of 4-byte words, as every record and point list is),
/// cheaper than a general hash. Each step `h = mix(h ^ word)` is a bijection of `h`, so
/// changing any one word changes the key; several changes collide with probability about
/// 2^-64. Bytes are folded 8 at a time; a 4-byte tail (a draw type in 4-byte steps,
/// `draw/registry.zig` section 2) is one more word, zero-extended, so a whole number of
/// 8-byte words keys exactly as before.
pub fn key_of(seed: u64, bytes: []const u8) u64 {
    assert(bytes.len % 4 == 0);
    var hash = seed ^ (@as(u64, bytes.len) *% golden);
    const whole = bytes.len - bytes.len % 8;
    var index: usize = 0;
    while (index < whole) : (index += 8) {
        const product = (hash ^ std.mem.readInt(u64, bytes[index..][0..8], .little)) *% golden;
        hash = product ^ (product >> 29);
    }
    if (whole < bytes.len) {
        const tail: u64 = std.mem.readInt(u32, bytes[whole..][0..4], .little);
        const product = (hash ^ tail) *% golden;
        hash = product ^ (product >> 29);
    }
    return hash;
}

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Tiles = struct {
    hashes: [tile_cap]u64,
    previous: [tile_cap]u64,
    /// One bit per tile, set when dirty. Plain words read through `self`, because
    /// `std.StaticBitSet`'s methods take the set by value and copied 2 KiB per query.
    dirty: [tile_cap / 64]u64,
    /// One bit per tile an animated instance touched in the last `begin` .. `finish`.
    forced: [tile_cap / 64]u64,
    columns: u32,
    rows: u32,
    width_px: u32,
    height_px: u32,
    /// `previous` holds the last frame on this grid.
    valid: bool,
    dirty_count: u32,

    /// Out-pointer init so a static renderer needs no stack copy.
    pub fn init(self: *Tiles) void {
        self.columns = 0;
        self.rows = 0;
        self.width_px = 0;
        self.height_px = 0;
        self.valid = false;
        self.dirty_count = 0;
        assert(!self.valid);
        assert(self.columns == 0);
    }

    /// Starts a frame for a `width_px` by `height_px` target. A new size forgets the last
    /// frame. Returns false, and forgets it too, when the grid exceeds `tile_cap`.
    pub fn begin(self: *Tiles, width_px: u32, height_px: u32) bool {
        assert(width_px >= 1);
        assert(height_px >= 1);
        const columns = std.math.divCeil(u32, width_px, side_px) catch unreachable;
        const rows = std.math.divCeil(u32, height_px, side_px) catch unreachable;
        if (columns != self.columns or rows != self.rows) self.valid = false;
        if (width_px != self.width_px or height_px != self.height_px) self.valid = false;
        self.columns = columns;
        self.rows = rows;
        self.width_px = width_px;
        self.height_px = height_px;
        if (@as(u64, columns) * rows > tile_cap) {
            self.valid = false;
            return false;
        }
        @memset(self.hashes[0 .. columns * rows], 0);
        @memset(&self.forced, 0);
        assert(self.columns * self.rows <= tile_cap);
        return true;
    }

    /// Forgets the last frame, so the next `finish` marks every tile dirty.
    pub fn invalidate(self: *Tiles) void {
        self.valid = false;
        assert(!self.valid);
    }

    /// Folds `key` into every tile `bounds` touches (x0, y0, x1, y1 in device pixels, grown
    /// by one pixel here). Empty or off-target bounds touch nothing.
    pub fn add(self: *Tiles, bounds: [4]f32, key: u64) void {
        const box = self.touched(bounds) orelse return;
        var row = box[2];
        while (row <= box[3]) : (row += 1) {
            const base = row * self.columns;
            for (self.hashes[base + box[0] .. base + box[1] + 1]) |*hash| {
                hash.* = (hash.* ^ key) *% prime;
            }
        }
    }

    /// Marks every tile `bounds` touches dirty for this frame, whatever its hash (an animated
    /// instance). Returns true when it touched any.
    pub fn force(self: *Tiles, bounds: [4]f32) bool {
        const box = self.touched(bounds) orelse return false;
        var row = box[2];
        while (row <= box[3]) : (row += 1) {
            var index = row * self.columns + box[0];
            while (index <= row * self.columns + box[1]) : (index += 1) {
                self.forced[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            }
        }
        return true;
    }

    /// The tile box (first column, last column, first row, last row; inclusive) that `bounds`
    /// touches after the one-pixel growth, or null when none.
    fn touched(self: *const Tiles, bounds: [4]f32) ?[4]u32 {
        assert(self.columns * self.rows <= tile_cap);
        const x0 = bounds[0] - 1;
        const y0 = bounds[1] - 1;
        const x1 = bounds[2] + 1;
        const y1 = bounds[3] + 1;
        if (!(x1 > x0 and y1 > y0)) return null;
        if (x1 <= 0 or y1 <= 0) return null;
        const span = tile_span(x0, x1, self.columns) orelse return null;
        const rows = tile_span(y0, y1, self.rows) orelse return null;
        return .{ span[0], span[1], rows[0], rows[1] };
    }

    /// Compares this frame's hashes with the last frame's, records the dirty tiles, and keeps
    /// this frame as the last. Returns the dirty count.
    pub fn finish(self: *Tiles) u32 {
        const total = self.columns * self.rows;
        assert(total <= tile_cap);
        @memset(&self.dirty, 0);
        var count: u32 = 0;
        for (0..total) |index| {
            const bit = @as(u64, 1) << @intCast(index % 64);
            const forced = self.forced[index / 64] & bit != 0;
            if (!forced and self.valid and self.hashes[index] == self.previous[index]) continue;
            self.dirty[index / 64] |= bit;
            count += 1;
        }
        @memcpy(self.previous[0..total], self.hashes[0..total]);
        self.valid = true;
        self.dirty_count = count;
        assert(count <= total);
        return count;
    }

    /// For a frame whose instances equal the last frame's, in place of `begin`, `add`, and
    /// `finish`: the last frame's forced tiles are this frame's dirty tiles, and `previous` and
    /// `forced` stay as they are. Returns the dirty count. Needs a last frame on this grid.
    pub fn repeat(self: *Tiles) u32 {
        assert(self.valid);
        const total = self.columns * self.rows;
        assert(total <= tile_cap);
        const words = std.math.divCeil(u32, total, 64) catch unreachable;
        var count: u32 = 0;
        for (self.dirty[0..words], self.forced[0..words]) |*dirty, forced| {
            dirty.* = forced;
            count += @popCount(forced);
        }
        @memset(self.dirty[words..], 0);
        self.dirty_count = count;
        assert(count <= total);
        return count;
    }

    /// The tile count of the current grid.
    pub fn tile_count(self: *const Tiles) u32 {
        assert(self.columns * self.rows <= tile_cap);
        return self.columns * self.rows;
    }

    /// Writes the dirty tiles as at most `out.len` rects in device pixels, clamped to the
    /// target (module guide, section 2), and returns how many.
    pub fn rects(self: *const Tiles, out: []Rect) u32 {
        assert(out.len >= 1);
        assert(out.len <= rect_cap);
        if (self.dirty_count == 0) return 0;
        var spans: [rect_cap][4]u32 = undefined;
        var count: u32 = 0;
        var overflow = false;
        for (0..self.rows) |row_index| {
            const row: u32 = @intCast(row_index);
            var column: u32 = 0;
            while (column < self.columns) {
                if (!self.is_dirty(row * self.columns + column)) {
                    column += 1;
                    continue;
                }
                const start = column;
                while (column < self.columns and self.is_dirty(row * self.columns + column)) {
                    column += 1;
                }
                if (!overflow) {
                    if (extend(spans[0..count], start, column, row)) continue;
                    if (count == out.len) {
                        overflow = true;
                    } else {
                        spans[count] = .{ start, column, row, row + 1 };
                        count += 1;
                    }
                }
            }
        }
        if (overflow) {
            spans[0] = self.dirty_box();
            count = 1;
        }
        for (spans[0..count], out[0..count]) |span, *rect| rect.* = self.to_pixels(span);
        assert(count >= 1);
        return count;
    }

    /// The tile box (column start, column end, row start, row end; ends exclusive) of every
    /// dirty tile.
    fn dirty_box(self: *const Tiles) [4]u32 {
        assert(self.dirty_count >= 1);
        var box: [4]u32 = .{ self.columns, 0, self.rows, 0 };
        for (0..self.columns * self.rows) |index| {
            if (!self.is_dirty(@intCast(index))) continue;
            const column: u32 = @intCast(index % self.columns);
            const row: u32 = @intCast(index / self.columns);
            box = .{
                @min(box[0], column),
                @max(box[1], column + 1),
                @min(box[2], row),
                @max(box[3], row + 1),
            };
        }
        return box;
    }

    /// True when tile `index` changed in the last `finish`.
    pub fn is_dirty(self: *const Tiles, index: u32) bool {
        assert(index < self.columns * self.rows);
        return self.dirty[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }

    fn to_pixels(self: *const Tiles, span: [4]u32) Rect {
        assert(span[0] < span[1]);
        assert(span[2] < span[3]);
        const x = span[0] * side_px;
        const y = span[2] * side_px;
        const rect: Rect = .{
            .x = x,
            .y = y,
            .width = @min(span[1] * side_px, self.width_px) - x,
            .height = @min(span[3] * side_px, self.height_px) - y,
        };
        assert(rect.width >= 1);
        assert(rect.height >= 1);
        return rect;
    }
};

/// Extends the span in `spans` that covers columns `start .. end` and ends at `row`. Returns
/// false when none does.
fn extend(spans: [][4]u32, start: u32, end: u32, row: u32) bool {
    for (spans) |*span| {
        if (span[0] == start and span[1] == end and span[3] == row) {
            span[3] = row + 1;
            return true;
        }
    }
    return false;
}

/// The first and last tile index (inclusive) that `[low, high)` pixels touch in a line of
/// `count` tiles, or null when none.
fn tile_span(low: f32, high: f32, count: u32) ?[2]u32 {
    assert(count >= 1);
    assert(high > low);
    const limit: f32 = @floatFromInt(count * side_px);
    if (low >= limit) return null;
    const side: f32 = @floatFromInt(side_px);
    const first: u32 = @intFromFloat(@max(0, @floor(low / side)));
    const last_pixel = @min(high, limit) - 0.001;
    const last: u32 = @min(count - 1, @as(u32, @intFromFloat(@max(0, @floor(last_pixel / side)))));
    if (last < first) return null;
    return .{ first, last };
}

const testing = std.testing;

fn new_tiles() *Tiles {
    const static = struct {
        var tiles: Tiles = undefined;
    };
    static.tiles.init();
    return &static.tiles;
}

// Locks the first frame and the steady state: without a previous frame every tile is dirty,
// and the same instances again dirty nothing.
test "a first frame is all dirty and a repeat is clean" {
    const tiles = new_tiles();
    try testing.expect(tiles.begin(200, 130));
    try testing.expectEqual(@as(u32, 4 * 3), tiles.tile_count());
    tiles.add(.{ 10, 10, 50, 50 }, 7);
    try testing.expectEqual(@as(u32, 12), tiles.finish());
    try testing.expect(tiles.begin(200, 130));
    tiles.add(.{ 10, 10, 50, 50 }, 7);
    try testing.expectEqual(@as(u32, 0), tiles.finish());
    var out: [rect_cap]Rect = undefined;
    try testing.expectEqual(@as(u32, 0), tiles.rects(&out));
}

// Locks what dirties a tile: a moved instance dirties its old and its new tiles, a changed key
// dirties only its own, a reorder dirties the tiles both instances share, and the one-pixel
// growth reaches across a tile edge.
test "moves, changes, reorders, and edges dirty the right tiles" {
    const tiles = new_tiles();
    _ = tiles.begin(256, 64);
    tiles.add(.{ 10, 10, 20, 20 }, 1);
    tiles.add(.{ 130, 10, 140, 20 }, 2);
    _ = tiles.finish();
    _ = tiles.begin(256, 64);
    tiles.add(.{ 70, 10, 80, 20 }, 1);
    tiles.add(.{ 130, 10, 140, 20 }, 2);
    try testing.expectEqual(@as(u32, 2), tiles.finish());
    try testing.expect(tiles.is_dirty(0));
    try testing.expect(tiles.is_dirty(1));
    _ = tiles.begin(256, 64);
    tiles.add(.{ 130, 10, 140, 20 }, 2);
    tiles.add(.{ 70, 10, 80, 20 }, 1);
    try testing.expectEqual(@as(u32, 0), tiles.finish());
    _ = tiles.begin(256, 64);
    tiles.add(.{ 70, 10, 140, 20 }, 3);
    tiles.add(.{ 70, 10, 140, 20 }, 4);
    _ = tiles.finish();
    _ = tiles.begin(256, 64);
    tiles.add(.{ 70, 10, 140, 20 }, 4);
    tiles.add(.{ 70, 10, 140, 20 }, 3);
    try testing.expectEqual(@as(u32, 2), tiles.finish());
    _ = tiles.begin(256, 64);
    tiles.add(.{ 0, 0, 63.5, 10 }, 9);
    try testing.expect(tiles.hashes[1] != 0);
    try testing.expectEqual(@as(u64, 0), tiles.hashes[2]);
}

// Locks animated tiles: a forced tile is dirty with an unchanged hash, `repeat` returns exactly
// the last frame's forced tiles as dirty (and nothing when none was forced), and `begin` clears
// them. Bounds off the target force nothing.
test "forced tiles are dirty every frame and repeat keeps them" {
    const tiles = new_tiles();
    _ = tiles.begin(256, 128);
    tiles.add(.{ 10, 10, 20, 20 }, 1);
    tiles.add(.{ 140, 70, 150, 80 }, 2);
    _ = tiles.finish();
    _ = tiles.begin(256, 128);
    tiles.add(.{ 10, 10, 20, 20 }, 1);
    tiles.add(.{ 140, 70, 150, 80 }, 2);
    try testing.expect(tiles.force(.{ 140, 70, 150, 80 }));
    try testing.expect(!tiles.force(.{ 300, 10, 320, 20 }));
    try testing.expectEqual(@as(u32, 1), tiles.finish());
    try testing.expect(tiles.is_dirty(4 + 2));
    try testing.expectEqual(@as(u32, 1), tiles.repeat());
    try testing.expect(tiles.is_dirty(4 + 2));
    try testing.expect(!tiles.is_dirty(0));
    var out: [rect_cap]Rect = undefined;
    try testing.expectEqual(@as(u32, 1), tiles.rects(&out));
    try testing.expectEqual(Rect{ .x = 128, .y = 64, .width = 64, .height = 64 }, out[0]);
    _ = tiles.begin(256, 128);
    tiles.add(.{ 10, 10, 20, 20 }, 1);
    tiles.add(.{ 140, 70, 150, 80 }, 2);
    try testing.expectEqual(@as(u32, 0), tiles.finish());
    try testing.expectEqual(@as(u32, 0), tiles.repeat());
}

// Locks the key's sensitivity: every single-bit change of any word, and a different seed,
// changes the key.
test "a key changes with any one word and with its seed" {
    var record = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const base = key_of(9, std.mem.asBytes(&record));
    try testing.expect(base != key_of(10, std.mem.asBytes(&record)));
    for (0..record.len) |word| {
        for (0..64) |bit| {
            record[word] ^= @as(u64, 1) << @intCast(bit);
            try testing.expect(key_of(9, std.mem.asBytes(&record)) != base);
            record[word] ^= @as(u64, 1) << @intCast(bit);
        }
    }
    try testing.expectEqual(base, key_of(9, std.mem.asBytes(&record)));
}

// Locks the rect merge: runs merge down rows with equal spans, rects are clamped to the
// target, too many rects become one bounding rect, and a new size dirties everything.
test "dirty tiles merge into rects, and overflow becomes one box" {
    const tiles = new_tiles();
    _ = tiles.begin(300, 300);
    _ = tiles.finish();
    _ = tiles.begin(300, 300);
    tiles.add(.{ 70, 70, 120, 200 }, 5);
    tiles.add(.{ 260, 260, 300, 300 }, 6);
    try testing.expectEqual(@as(u32, 1 * 3 + 1), tiles.finish());
    var out: [rect_cap]Rect = undefined;
    try testing.expectEqual(@as(u32, 2), tiles.rects(&out));
    try testing.expectEqual(Rect{ .x = 64, .y = 64, .width = 64, .height = 192 }, out[0]);
    try testing.expectEqual(Rect{ .x = 256, .y = 256, .width = 44, .height = 44 }, out[1]);
    try testing.expectEqual(@as(u32, 1), tiles.rects(out[0..1]));
    try testing.expectEqual(Rect{ .x = 64, .y = 64, .width = 236, .height = 236 }, out[0]);
    try testing.expect(tiles.begin(320, 300));
    try testing.expectEqual(tiles.tile_count(), tiles.finish());
    try testing.expect(!tiles.begin(8192, 8256));
    try testing.expect(!tiles.valid);
}

comptime {
    assert(side_px >= 16);
    assert(tile_cap >= (4096 / side_px) * (4096 / side_px));
    assert(rect_cap >= 1);
}

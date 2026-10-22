//! The draw context: one instance pool per draw type, layers, and sticky batches.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Sticky Batches and Layers
//! Drawing in strict paint order costs one draw call per type switch: a knob is arc, arc,
//! glyph, glyph, so a long list of knobs becomes thousands of draws. Instead every draw type
//! has its own pool, and instances of the same type and texture merge into one batch per
//! layer, even when other types were appended between them (Makepad's sticky draw calls).
//! Content that must cover other content (tooltips, popups, cables) goes to a higher layer,
//! and layers draw in order. Within a layer, batches draw in order of the first appearance of
//! each (type, texture) pair in the frame; within a batch, instances keep append order.
//!
//! ## 2. Data Flow
//! ```text
//! reset                 empty every pool, layer = base, and   (the host, before App.draw)
//!                       start the glyph cache's frame (`text.begin_frame`)
//! append(T, tex, inst)  pool[T] gets inst and key = layer * texture_slots(T) + texture
//!                       first use of (layer, T, texture) appends to `appearance`
//! finalize              per pool: prefix sums of the key histogram -> starts;
//!                       if a key ever decreased, stable counting sort by key
//!                       batches = appearance stably sorted by layer, with first/count
//!                       read from the pool's starts and histogram
//! ```
//! The histogram is filled by `append`, so `finalize` is linear in the instance count plus
//! a constant per pool (`layer_count * texture_slots` keys). An app that draws its overlays
//! last appends in key order, and then `finalize` sorts nothing.
//!
//! ## 3. Keys
//! `texture_slots` is 1 for an untextured type and `textures.texture_cap` for a textured one,
//! so a key is `layer` or `layer * texture_cap + texture` and fits a `u8` (asserted). Sorting
//! by key groups each (layer, texture) run contiguously, which is what lets one draw call
//! with `first_instance` cover a batch.
//!
//! ## 4. Overflow
//! A full pool returns `error.PoolFull`, and a new batch beyond `batch_cap` returns
//! `error.BatchFull`. Both increment `overflow_count`, which `reset` clears, so a test that
//! draws a frame can assert that nothing was dropped. Widgets skip the instance.
//!
//! ## 5. Revisions
//! Each pool's `revision` (a `u64`, so it cannot wrap in practice) moves on every `reset`
//! and `append`. The renderer compares it with its shadow to skip unchanged pools without
//! looking at their records; see `draw/renderer.zig`.
//!
//! ## 6. TigerStyle Invariants
//! - All storage is fixed arrays sized at compile time from `App.config.draw` and
//!   `batch_cap`; the hosts keep the context in static memory (BSS on wasm).
//! - The context also owns the glyph cache (`text: text.Cache`, about 1.25 MiB: the 1 MiB
//!   atlas mirror, the table, and raster scratch), so `text.place` reaches it through `cx`
//!   and every test context gets its own. `init` creates its atlas as texture 0.
//! - Every loop is bounded by a pool count, a key count, or `batch_cap`.

const std = @import("std");
const assert = std.debug.assert;
const cache = @import("../text/cache.zig");
const registry = @import("registry.zig");
const textures = @import("textures.zig");
const types = @import("types.zig");

/// Layers per frame. A layer is drawn entirely after every lower layer.
pub const layer_count: u32 = 8;

/// A draw layer, `0 .. layer_count`. `base` holds ordinary content and `overlay` content that
/// must cover it, such as tooltips; other values are free for an app's own use.
pub const Layer = enum(u8) {
    base = 0,
    overlay = 4,
    _,
};

/// One draw call: `count` instances of type `type_id` starting at `first` in its pool.
pub const Batch = struct {
    type_id: u8,
    key: u8,
    layer: u8,
    /// The texture of a textured type's batch, else `TextureId.atlas` (unused).
    texture: textures.TextureId,
    first: u32,
    count: u32,
};

const Appearance = struct {
    type_id: u8,
    key: u8,
    layer: u8,
};

/// The pool of one draw type. See the module guide.
fn Pool(comptime T: type, comptime cap: u32) type {
    const slots: u32 = if (T.texture == null) 1 else textures.texture_cap;
    const key_total: u32 = layer_count * slots;
    comptime {
        assert(key_total <= 256);
        assert(cap >= 1);
    }
    return struct {
        items: [cap]T,
        keys: [cap]u8,
        histogram: [key_total]u32,
        starts: [key_total]u32,
        count: u32,
        revision: u64,
        last_key: u8,
        /// True while every key appended since the last sort is at least the one before.
        ordered: bool,

        pub const Item = T;
        pub const capacity: u32 = cap;
        pub const texture_slots: u32 = slots;
        pub const key_count: u32 = key_total;
        pub const bytes: u32 = cap * @sizeOf(T);
    };
}

/// The draw context for one app: `App.draw` receives a pointer to it. See the module guide.
pub fn Context(comptime entries: []const registry.DrawType, comptime batch_cap: u32) type {
    comptime {
        assert(batch_cap >= 1);
    }
    const R = registry.Registry(entries);
    const pool_types: [R.count]type = blk: {
        var out: [R.count]type = undefined;
        for (0..R.count) |index| out[index] = Pool(R.Type(index), R.caps[index]);
        break :blk out;
    };
    const scratch_bytes: u32 = blk: {
        var most: u32 = 0;
        for (pool_types) |P| most = @max(most, P.bytes);
        break :blk most;
    };
    return struct {
        const Self = @This();

        pools: @Tuple(&pool_types),
        textures: textures.Textures,
        /// The glyph cache and atlas mirror `text.place` draws through; see `text/cache.zig`.
        text: cache.Cache,
        layer_now: Layer,
        /// Instances refused for `PoolFull` or `BatchFull` since the last `reset`.
        overflow_count: u32,
        appearance: [batch_cap]Appearance,
        appearance_count: u32,
        batches: [batch_cap]Batch,
        batch_count: u32,
        finalized: bool,
        /// Counting-sort target, sized for the largest pool and shared by all of them.
        scratch: [scratch_bytes]u8 align(16),

        pub const Registry = R;
        pub const batch_capacity: u32 = batch_cap;

        /// Empties every pool and the glyph cache and creates the glyph atlas as texture 0.
        /// The atlas starts empty (WebGPU zero-fills it); the cache uploads what it draws.
        /// Out-pointer init so a static context needs no stack copy.
        pub fn init(self: *Self) void {
            self.textures.init();
            const atlas = self.textures.create(.r8, cache.atlas_side, cache.atlas_side);
            assert(atlas == .atlas);
            self.text.init();
            inline for (0..R.count) |index| {
                self.pools[index].revision = 0;
            }
            self.reset();
            assert(self.textures.count == 1);
            assert(self.batch_count == 0);
            assert(self.text.entry_count == 0);
        }

        /// Empties every pool, returns to the base layer, and starts the glyph cache's frame
        /// (`Cache.begin_frame`). Bumps every pool revision. The host sets
        /// `text.scale_120` first.
        pub fn reset(self: *Self) void {
            self.text.begin_frame();
            inline for (0..R.count) |index| {
                const pool = &self.pools[index];
                pool.count = 0;
                @memset(&pool.histogram, 0);
                pool.revision += 1;
                pool.last_key = 0;
                pool.ordered = true;
            }
            self.layer_now = .base;
            self.overflow_count = 0;
            self.appearance_count = 0;
            self.batch_count = 0;
            self.finalized = false;
            assert(self.appearance_count == 0);
            assert(self.layer_now == .base);
        }

        /// Sets the layer later appends go to and returns the previous one, so a widget can
        /// restore it with `defer _ = cx.layer(previous);`.
        pub fn layer(self: *Self, next: Layer) Layer {
            assert(@intFromEnum(next) < layer_count);
            const previous = self.layer_now;
            self.layer_now = next;
            assert(self.layer_now == next);
            return previous;
        }

        /// Appends `instance` to `T`'s pool on the current layer. `texture` is required
        /// exactly when `T` declares a texture format, and must have that format. Nothing is
        /// stored on error; see `types.AppendError`.
        pub fn append(
            self: *Self,
            comptime T: type,
            texture: ?textures.TextureId,
            instance: T,
        ) types.AppendError!void {
            const type_id = comptime R.id(T);
            const pool = &self.pools[type_id];
            const P = @TypeOf(pool.*);
            assert(pool.count <= P.capacity);
            const slot = self.texture_slot(T, texture);
            if (!(instance.rect[2] > 0)) return error.EdgeNotPositive;
            if (!(instance.rect[3] > 0)) return error.EdgeNotPositive;
            if (!clip_ordered(instance.clip)) return error.ClipUnordered;
            if (pool.count == P.capacity) {
                self.overflow_count += 1;
                return error.PoolFull;
            }
            const layer_index: u8 = @intFromEnum(self.layer_now);
            const key: u8 = @intCast(layer_index * P.texture_slots + slot);
            if (pool.histogram[key] == 0) {
                if (self.appearance_count == batch_cap) {
                    self.overflow_count += 1;
                    return error.BatchFull;
                }
                self.appearance[self.appearance_count] = .{
                    .type_id = type_id,
                    .key = key,
                    .layer = layer_index,
                };
                self.appearance_count += 1;
            }
            pool.items[pool.count] = instance;
            pool.keys[pool.count] = key;
            pool.histogram[key] += 1;
            if (key < pool.last_key) {
                pool.ordered = false;
            } else {
                pool.last_key = key;
            }
            pool.count += 1;
            pool.revision += 1;
            self.finalized = false;
            assert(pool.count <= P.capacity);
            assert(pool.histogram[key] >= 1);
        }

        fn texture_slot(self: *const Self, comptime T: type, texture: ?textures.TextureId) u32 {
            if (comptime T.texture) |format| {
                const id = texture.?;
                assert(self.textures.exists(id));
                assert(self.textures.format_of(id) == format);
                return @intFromEnum(id);
            }
            assert(texture == null);
            return 0;
        }

        /// The live instances of `T`, in pool order (key order after `finalize`).
        pub fn items(self: *const Self, comptime T: type) []const T {
            const pool = &self.pools[comptime R.id(T)];
            return pool.items[0..pool.count];
        }

        /// The revision of `T`'s pool; it moves on every `reset` and `append`.
        pub fn revision(self: *const Self, comptime T: type) u64 {
            const pool = &self.pools[comptime R.id(T)];
            assert(pool.revision >= 1);
            return pool.revision;
        }

        /// The layer of `T`'s instance at `index`.
        pub fn layer_at(self: *const Self, comptime T: type, index: u32) Layer {
            const pool = &self.pools[comptime R.id(T)];
            const P = @TypeOf(pool.*);
            assert(index < pool.count);
            return @enumFromInt(pool.keys[index] / P.texture_slots);
        }

        /// The batches `finalize` formed, in draw order.
        pub fn batch_list(self: *const Self) []const Batch {
            assert(self.finalized);
            return self.batches[0..self.batch_count];
        }

        /// Sorts each pool by key when needed and forms the batches. Idempotent until the
        /// next `append` or `reset`.
        pub fn finalize(self: *Self) void {
            if (self.finalized) {
                assert(self.batch_count == self.appearance_count);
                return;
            }
            inline for (0..R.count) |index| {
                const pool = &self.pools[index];
                prefix_starts(@TypeOf(pool.*), pool);
                if (!pool.ordered) {
                    sort_pool(@TypeOf(pool.*), pool, &self.scratch);
                }
            }
            self.form_batches();
            self.finalized = true;
            assert(self.batch_count == self.appearance_count);
        }

        fn form_batches(self: *Self) void {
            var layer_starts = [_]u32{0} ** layer_count;
            for (self.appearance[0..self.appearance_count]) |entry| {
                layer_starts[entry.layer] += 1;
            }
            var total: u32 = 0;
            for (&layer_starts) |*start| {
                const here = start.*;
                start.* = total;
                total += here;
            }
            assert(total == self.appearance_count);
            for (self.appearance[0..self.appearance_count]) |entry| {
                const at = layer_starts[entry.layer];
                layer_starts[entry.layer] += 1;
                self.batches[at] = self.batch_of(entry);
            }
            self.batch_count = self.appearance_count;
        }

        fn batch_of(self: *const Self, entry: Appearance) Batch {
            inline for (0..R.count) |index| {
                if (entry.type_id == index) {
                    const pool = &self.pools[index];
                    const P = @TypeOf(pool.*);
                    const batch: Batch = .{
                        .type_id = entry.type_id,
                        .key = entry.key,
                        .layer = entry.layer,
                        .texture = @enumFromInt(entry.key % P.texture_slots),
                        .first = pool.starts[entry.key],
                        .count = pool.histogram[entry.key],
                    };
                    assert(batch.count >= 1);
                    assert(batch.first + batch.count <= pool.count);
                    return batch;
                }
            }
            unreachable;
        }
    };
}

fn prefix_starts(comptime P: type, pool: *P) void {
    assert(pool.count <= P.capacity);
    var total: u32 = 0;
    for (&pool.starts, pool.histogram) |*start, count| {
        start.* = total;
        total += count;
    }
    assert(total == pool.count);
}

/// Stable counting sort of `pool` by key through `scratch`; `starts` must be current.
fn sort_pool(comptime P: type, pool: *P, scratch: []align(16) u8) void {
    const T = P.Item;
    assert(scratch.len >= pool.count * @sizeOf(T));
    assert(!pool.ordered);
    const sorted: [*]T = @ptrCast(scratch.ptr);
    var cursor: [P.key_count]u32 = pool.starts;
    for (pool.items[0..pool.count], pool.keys[0..pool.count]) |item, key| {
        sorted[cursor[key]] = item;
        cursor[key] += 1;
    }
    @memcpy(pool.items[0..pool.count], sorted[0..pool.count]);
    for (pool.starts, pool.histogram, 0..) |start, count, key| {
        @memset(pool.keys[start..][0..count], @intCast(key));
    }
    pool.ordered = true;
    pool.last_key = pool.keys[pool.count - 1];
    assert(pool.keys[0] <= pool.last_key);
    assert(cursor[pool.last_key] == pool.count);
}

fn finite(value: f32) bool {
    if (value != value) return false;
    if (std.math.isInf(value)) return false;
    assert(value == value);
    return true;
}

fn clip_ordered(clip: [4]f32) bool {
    for (clip) |edge| {
        if (!finite(edge)) return false;
    }
    if (!(clip[2] > clip[0])) return false;
    if (!(clip[3] > clip[1])) return false;
    assert(clip[2] > clip[0]);
    assert(clip[3] > clip[1]);
    return true;
}

comptime {
    assert(layer_count == 8);
    assert(@intFromEnum(Layer.overlay) < layer_count);
    // The sort key of a textured type must fit a u8.
    assert(layer_count * textures.texture_cap <= 256);
}

const testing = std.testing;

const test_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 8 },
    .{ .type = types.Glyph, .cap = 8 },
    .{ .type = types.Image, .cap = 4 },
};

const TestContext = Context(&test_draw, 6);

fn test_box(x: f32) types.Box {
    return .{
        .rect = .{ x, 0, 10, 10 },
        .clip = .{ 0, 0, 100, 100 },
        .fill = .{ 1, 1, 1, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    };
}

fn test_glyph(x: f32) types.Glyph {
    return .{
        .rect = .{ x, 0, 4, 8 },
        .clip = .{ 0, 0, 100, 100 },
        .uv = .{ 0, 0, 1, 1 },
        .color = .{ 1, 1, 1, 1 },
    };
}

fn new_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

// Locks sticky batching: box, glyph, box, glyph in one layer is two batches in order of first
// appearance, and a box and glyph on the overlay layer add two more, drawn after.
test "box glyph box glyph is two batches and the overlay adds two after" {
    const cx = new_context();
    try cx.append(types.Box, null, test_box(0));
    try cx.append(types.Glyph, .atlas, test_glyph(0));
    try cx.append(types.Box, null, test_box(20));
    try cx.append(types.Glyph, .atlas, test_glyph(20));
    cx.finalize();
    const base = cx.batch_list();
    try testing.expectEqual(@as(usize, 2), base.len);
    try testing.expectEqual(@as(u8, 0), base[0].type_id);
    try testing.expectEqual(@as(u32, 2), base[0].count);
    try testing.expectEqual(@as(u8, 1), base[1].type_id);
    try testing.expectEqual(@as(u32, 2), base[1].count);
    const previous = cx.layer(.overlay);
    try testing.expectEqual(Layer.base, previous);
    try cx.append(types.Box, null, test_box(40));
    try cx.append(types.Glyph, .atlas, test_glyph(40));
    _ = cx.layer(previous);
    try cx.append(types.Box, null, test_box(60));
    cx.finalize();
    const all = cx.batch_list();
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqual(@as(u8, 0), all[0].layer);
    try testing.expectEqual(@as(u32, 3), all[0].count);
    try testing.expectEqual(@as(u8, 0), all[1].layer);
    try testing.expectEqual(@as(u8, 4), all[2].layer);
    try testing.expectEqual(@as(u8, 0), all[2].type_id);
    try testing.expectEqual(@as(u32, 3), all[2].first);
    try testing.expectEqual(@as(u8, 4), all[3].layer);
    try testing.expectEqual(@as(u8, 1), all[3].type_id);
    // The late base box was sorted ahead of the overlay box, keeping append order per key.
    const boxes = cx.items(types.Box);
    try testing.expectEqual(@as(f32, 0), boxes[0].rect[0]);
    try testing.expectEqual(@as(f32, 20), boxes[1].rect[0]);
    try testing.expectEqual(@as(f32, 60), boxes[2].rect[0]);
    try testing.expectEqual(@as(f32, 40), boxes[3].rect[0]);
    try testing.expectEqual(Layer.overlay, cx.layer_at(types.Box, 3));
    try testing.expectEqual(@as(u32, 0), cx.overflow_count);
}

// Locks that appends already in key order are not sorted, and textures split batches.
test "ordered appends skip the sort and textures split a type" {
    const cx = new_context();
    const badge = cx.textures.create(.rgba8, 2, 2);
    const other = cx.textures.create(.rgba8, 2, 2);
    const image: types.Image = .{
        .rect = .{ 0, 0, 2, 2 },
        .clip = .{ 0, 0, 10, 10 },
        .uv = .{ 0, 0, 1, 1 },
        .tint = .{ 1, 1, 1, 1 },
    };
    try cx.append(types.Image, badge, image);
    try cx.append(types.Image, other, image);
    try cx.append(types.Image, badge, image);
    try testing.expect(!cx.pools[2].ordered);
    cx.finalize();
    const batches = cx.batch_list();
    try testing.expectEqual(@as(usize, 2), batches.len);
    try testing.expectEqual(badge, batches[0].texture);
    try testing.expectEqual(@as(u32, 2), batches[0].count);
    try testing.expectEqual(other, batches[1].texture);
    try testing.expectEqual(@as(u32, 2), batches[1].first);
    cx.reset();
    try cx.append(types.Box, null, test_box(0));
    _ = cx.layer(.overlay);
    try cx.append(types.Box, null, test_box(1));
    try testing.expect(cx.pools[0].ordered);
}

// Locks the overflow rules: a full pool and a batch beyond `batch_cap` are refused, counted,
// and store nothing; degenerate geometry is refused without counting.
test "a full pool and a full batch list are counted and skipped" {
    const cx = new_context();
    var index: u32 = 0;
    while (index < 8) : (index += 1) {
        try cx.append(types.Box, null, test_box(@floatFromInt(index)));
    }
    try testing.expectError(error.PoolFull, cx.append(types.Box, null, test_box(9)));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    var flat = test_box(0);
    flat.rect[2] = 0;
    try testing.expectError(error.EdgeNotPositive, cx.append(types.Box, null, flat));
    var crossed = test_box(0);
    crossed.clip = .{ 5, 0, 5, 10 };
    try testing.expectError(error.ClipUnordered, cx.append(types.Box, null, crossed));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    cx.reset();
    var level: u8 = 0;
    while (level < 6) : (level += 1) {
        _ = cx.layer(@enumFromInt(level));
        try cx.append(types.Box, null, test_box(0));
    }
    _ = cx.layer(@enumFromInt(7));
    try testing.expectError(error.BatchFull, cx.append(types.Box, null, test_box(0)));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expectEqual(@as(u32, 6), cx.items(types.Box).len);
}

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
//! The consequence that surprises: a Box appended after any Glyph on the same layer draws
//! under every glyph of that layer, because the Glyph batch appeared first. An app that places
//! a title, then a panel face, then labels on the face sees the labels vanish under the face.
//! Append faces before any text on a layer, or put what must cover on a higher layer (the
//! audio example orders its faces first for this reason). There is no runtime warning: the
//! only symptom is overlap, and finding it would cost a pass over every pair of batches.
//!
//! First appearance also depends on what is on screen: scrolling can change which row appends
//! first, and with it the order. `App.config.batch_order` picks the rule for the whole app.
//! `.appearance`, the default, is the one above. `.registered` draws a layer's batches in
//! `App.config.draw`'s order, then by texture, on every frame, so a screen that lists faces
//! before text needs no care about what it appends first. Pick `.registered` for a new screen;
//! an app on `.appearance` can assert `draw.covered_glyphs` is 0 in a test instead. Within a
//! batch, instances keep append order under either rule.
//!
//! ## 2. Data Flow
//! ```text
//! reset                 empty every pool, layer = base, and   (the host, before App.draw)
//!                       start the glyph cache's frame (`text.begin_frame`)
//! append(T, tex, inst)  pool[T] gets inst and key = layer * texture_slots(T) + texture
//!                       first use of (layer, T, texture) appends to `appearance`
//! finalize              per pool: prefix sums of the key histogram -> starts;
//!                       if a key ever decreased, stable counting sort by key
//!                       batches = appearance (sorted by registered order under
//!                       `.registered`) stably sorted by layer, with first/count
//!                       read from the pool's starts and histogram
//! ```
//! The histogram is filled by `append`, so `finalize` is linear in the instance count plus
//! a constant per pool (`layer_count * texture_slots` keys). An app that draws its overlays
//! last appends in key order, and then `finalize` sorts nothing.
//!
//! ## 3. Keys
//! `texture_slots` is 1 for an untextured type and `textures.texture_cap` for a textured one,
//! so a key is `layer` or `layer * texture_cap + texture` and fits a `u16` (asserted), so the
//! layer count and the texture slots no longer bound each other (they shared a `u8` before
//! step 29: 8 layers × 32 textures). Sorting
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
//! ## 5a. Shifting a Range
//! `counts` snapshots every pool's count and `shift` adds a delta to `rect.xy` of everything
//! appended since. The UI layer uses the pair to align a container after its children drew
//! (`ui/cx.zig`). Keys, layers, and append order are untouched, so sorting and batching are
//! unaffected; the cost is linear in the shifted instances only.
//!
//! ## 5b. Points
//! A registry with a `reads_points` type (`draw.Path`) gives the context a point pool:
//! `point_cap` (from `App.config.point_cap`) `[2]f32` points, emptied by `reset`, with its own
//! revision. `draw/path.zig` reserves a path's points with `reserve_points` and appends the
//! instances that index them; `release_points` takes a reservation back when the first
//! instance is refused. Instances move in the counting sort and in `shift`; points never
//! move, so an instance's `first_point` stays valid. Without such a type the pool has no
//! storage (`point_capacity == 0`).
//!
//! ## 5c. Views
//! `view(layer, view)` gives a layer a pan/zoom view for one frame: its instances are in world
//! coordinates and land on the screen at `(view.x + view.zoom * wx, view.y + view.zoom * wy)`.
//! The renderer draws the layer with its own frame uniform, whose projection is the window's
//! times that map (`draw.view_ortho`), so no record and no shader changes. A layer is viewed or
//! bound to a target, never both, and the base layer is never viewed. `open_views(mask, zoom)`
//! and `close_views` bracket a canvas (`ui/cx.zig`): while open, every append must go to a layer
//! of `mask`, and outside it no append may go to a viewed layer, one mask test per append.
//! `view_zoom` is the open canvas's zoom (1 otherwise), which `draw/path.zig` flattens by.
//!
//! ## 5d. Backdrops
//! `backdrop(layer, blur)` marks a layer for one frame: the renderer draws every layer below it
//! (but bound ones) into a scene, blurs it into a pack, and draws the marked layer and those
//! above over a copy of the scene (`draw/backdrop.zig`, `draw/renderer.zig` section 4e). It
//! returns the pack's id, which a backdrop type (`draw.Glass`) is appended with; such an
//! instance must sit on the marked layer or above (asserted). The context owns the ids: the
//! first call of a frame gets the first id, created the first time it is needed, so an app that
//! marks its backdrops in the same order every frame keeps them. `backdrop_under(layer)` is the
//! highest marked layer at or below `layer`, which skins ask before drawing glass. A context
//! whose registry has no backdrop type has no backdrops (`backdrop_capacity == 0`), and calling
//! `backdrop` fails the build.
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
const theme = @import("../theme.zig");
const textures = @import("textures.zig");
const types = @import("types.zig");
const backdrop_module = @import("backdrop.zig");

/// One path point in logical pixels, relative to its path's origin (`draw/path.zig`).
pub const Point = [2]f32;

/// Largest `App.config.point_cap`: point indices stay exact as `f32` instance fields.
pub const point_cap_max: u32 = 65536;

/// Layers per frame. A layer is drawn entirely after every lower layer.
pub const layer_count: u32 = 8;

/// A draw layer, `0 .. layer_count`. `base` holds ordinary content and `overlay` content that
/// must cover it, such as an app's own hover boxes; `popup` holds menus and dialogs
/// (`ui.Context.begin_popup`) and `tooltip` tooltips, above everything else. Other values are
/// free for an app's own use (canvases take 1 to 4).
pub const Layer = enum(u8) {
    base = 0,
    overlay = 4,
    popup = 6,
    tooltip = 7,
    _,
};

/// How a layer's batches order (section 1): by first appearance in the frame, or by
/// `App.config.draw`'s order, then texture.
pub const BatchOrder = enum(u8) { appearance, registered };

/// A layer drawn into an offscreen target this frame (`Context.offscreen`): its target and the
/// logical rect the target covers (x, y, width, height).
pub const Binding = struct {
    layer: u8,
    target: textures.TextureId,
    rect: [4]f32,
};

/// A layer marked as a backdrop this frame (section 5d), `draw/backdrop.zig`.
pub const Backdrop = backdrop_module.Backdrop;

/// A pan/zoom view of a layer (section 5c): world `(wx, wy)` lands on the logical screen point
/// `(x + zoom * wx, y + zoom * wy)`. 16 bytes, so it folds into a tile key whole.
pub const View = extern struct {
    x: f32,
    y: f32,
    zoom: f32,
    unused: f32 = 0,

    /// The identity: what a layer without a view draws with.
    pub const identity: View = .{ .x = 0, .y = 0, .zoom = 1 };

    /// The screen point of the world point `(wx, wy)`.
    pub fn apply(self: View, wx: f32, wy: f32) [2]f32 {
        assert(self.zoom > 0);
        return .{ self.x + self.zoom * wx, self.y + self.zoom * wy };
    }

    /// The world point under the screen point `(sx, sy)`.
    pub fn invert(self: View, sx: f32, sy: f32) [2]f32 {
        assert(self.zoom > 0);
        return .{ (sx - self.x) / self.zoom, (sy - self.y) / self.zoom };
    }
};

/// One draw call: `count` instances of type `type_id` starting at `first` in its pool.
pub const Batch = struct {
    type_id: u8,
    key: u16,
    layer: u8,
    /// The texture of a textured type's batch, else `TextureId.atlas` (unused).
    texture: textures.TextureId,
    first: u32,
    count: u32,
};

const Appearance = struct {
    type_id: u8,
    key: u16,
    layer: u8,

    fn before(_: void, a: Appearance, b: Appearance) bool {
        if (a.layer != b.layer) return a.layer < b.layer;
        if (a.type_id != b.type_id) return a.type_id < b.type_id;
        return a.key < b.key;
    }
};

/// The pool of one draw type. See the module guide.
fn Pool(comptime T: type, comptime cap: u32) type {
    const slots: u32 = if (T.texture == null) 1 else textures.texture_cap;
    const key_total: u32 = layer_count * slots;
    comptime {
        assert(key_total <= 65536);
        assert(cap >= 1);
    }
    return struct {
        items: [cap]T,
        keys: [cap]u16,
        histogram: [key_total]u32,
        starts: [key_total]u32,
        count: u32,
        revision: u64,
        last_key: u16,
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
/// `point_cap` sizes the point pool when a registered type reads points (section 5b).
pub fn Context(
    comptime entries: []const registry.DrawType,
    comptime batch_cap: u32,
    comptime point_cap: u32,
) type {
    comptime {
        assert(batch_cap >= 1);
        assert(point_cap <= point_cap_max);
    }
    const R = registry.Registry(entries);
    const point_total: u32 = if (R.uses_points) point_cap else 0;
    comptime {
        if (R.uses_points) assert(point_total >= 1);
    }
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
        /// The rule `form_batches` orders a layer by (section 1): `.appearance` from `init`,
        /// `App.config.batch_order` from `app.start`. `reset` keeps it.
        batch_order: BatchOrder,
        /// Counting-sort target, sized for the largest pool and shared by all of them.
        scratch: [scratch_bytes]u8 align(16),
        /// The point pool (section 5b): `points[0..point_count]` are this frame's points.
        points: [point_total]Point,
        point_count: u32,
        /// Moves on every `reset`, `reserve_points`, and `release_points`.
        point_revision: u64,
        /// The layers drawn into offscreen targets this frame (`offscreen`), in call order.
        bindings: [textures.target_cap]Binding,
        binding_count: u32,
        /// The views of this frame (section 5c), meaningful where `view_mask` has the bit.
        views: [layer_count]View,
        view_mask: u8,
        /// The layers of the open canvas, 0 when none is open.
        open_mask: u8,
        /// The open canvas's zoom, 1 when none is open.
        view_zoom: f32,
        /// This frame's backdrops (section 5d), in call order, and the ids each call order
        /// owns: the first call of a frame always gets `backdrop_ids[0]`.
        backdrops: [backdrop_capacity]Backdrop,
        backdrop_count: u32,
        backdrop_ids: [backdrop_capacity]textures.TextureId,
        /// The theme record the renderer uploads (`theme.zig`): `theme.dark`'s from `init`,
        /// then the app's scheme's (`ui.Context.set_theme`). `reset` keeps it.
        theme: theme.Theme,

        pub const Registry = R;
        pub const batch_capacity: u32 = batch_cap;
        pub const point_capacity: u32 = point_total;
        /// Backdrops a frame may mark: `backdrop.backdrop_cap` when a registered type samples
        /// one (`registry.zig`, section 2d), else 0.
        pub const backdrop_capacity: u32 = if (R.any_backdrop) backdrop_module.backdrop_cap else 0;

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
            self.point_revision = 0;
            self.backdrop_count = 0;
            for (&self.backdrop_ids) |*id| id.* = .atlas;
            self.batch_order = .appearance;
            self.theme = theme.dark.record();
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
            self.point_count = 0;
            self.point_revision += 1;
            self.layer_now = .base;
            self.overflow_count = 0;
            self.appearance_count = 0;
            self.batch_count = 0;
            self.finalized = false;
            self.binding_count = 0;
            self.backdrop_count = 0;
            self.view_mask = 0;
            self.open_mask = 0;
            self.view_zoom = 1;
            assert(self.appearance_count == 0);
            assert(self.layer_now == .base);
        }

        /// Draws `layer` into the offscreen `target` this frame, covering the logical `rect`
        /// (x, y, width, height): its instances render in the target's pass, not the main
        /// pass (`draw/fx.zig`). Not the base layer, one target per layer and one layer per
        /// target. `reset` clears every binding.
        pub fn offscreen(self: *Self, layer_value: Layer, target: textures.TextureId, rect: [4]f32) void {
            const layer_index: u8 = @backingInt(layer_value);
            assert(layer_index != @backingInt(Layer.base));
            assert(layer_index < layer_count);
            assert(self.textures.is_target(target));
            assert(rect[2] > 0 and rect[3] > 0);
            assert(self.view_mask & bit_of(layer_index) == 0);
            assert(self.binding_count < textures.target_cap);
            for (self.bindings[0..self.binding_count]) |binding| {
                assert(binding.layer != layer_index);
                assert(binding.target != target);
            }
            self.bindings[self.binding_count] = .{ .layer = layer_index, .target = target, .rect = rect };
            self.binding_count += 1;
        }

        /// Marks `layer_value` as a backdrop this frame (section 5d) with a blur of sigma `blur`
        /// logical pixels, and returns the id its glass samples. Every layer below it draws
        /// into a scene the renderer blurs (`draw/backdrop.zig`). Not the base layer and not a
        /// layer bound to a target; at most `backdrop_capacity` layers. Marking a layer again
        /// keeps the wider blur and returns the same id. `reset` clears every backdrop.
        pub fn backdrop(self: *Self, layer_value: Layer, blur: f32) textures.TextureId {
            comptime {
                if (backdrop_capacity == 0) {
                    @compileError("a backdrop needs a registered type that samples one " ++
                        "(draw.Glass)");
                }
            }
            const layer_index: u8 = @backingInt(layer_value);
            assert(layer_index != @backingInt(Layer.base));
            assert(layer_index < layer_count);
            assert(blur >= 0 and !std.math.isInf(blur));
            assert(self.binding_of(layer_index) == null);
            for (self.backdrops[0..self.backdrop_count]) |*marked| {
                if (marked.layer == layer_index) {
                    marked.blur = @max(marked.blur, blur);
                    return marked.id;
                }
            }
            assert(self.backdrop_count < backdrop_capacity);
            const slot = self.backdrop_count;
            if (slot == self.textures.backdrop_count) {
                self.backdrop_ids[slot] = self.textures.create_backdrop();
            }
            assert(self.textures.is_backdrop(self.backdrop_ids[slot]));
            self.backdrops[slot] = .{
                .layer = layer_index,
                .blur = blur,
                .id = self.backdrop_ids[slot],
            };
            self.backdrop_count += 1;
            return self.backdrops[slot].id;
        }

        /// The backdrop a glass on `layer_value` samples: the highest one marked at or below
        /// it this frame, or null (section 5d).
        pub fn backdrop_under(self: *const Self, layer_value: Layer) ?Backdrop {
            const layer_index: u8 = @backingInt(layer_value);
            assert(layer_index < layer_count);
            var best: ?Backdrop = null;
            for (self.backdrops[0..self.backdrop_count]) |marked| {
                if (marked.layer > layer_index) continue;
                if (best == null or marked.layer > best.?.layer) best = marked;
            }
            return best;
        }

        /// This frame's backdrops, in call order.
        pub fn backdrop_list(self: *const Self) []const Backdrop {
            return self.backdrops[0..self.backdrop_count];
        }

        /// The binding of `layer_index` this frame, or null when it draws to the main pass.
        pub fn binding_of(self: *const Self, layer_index: u8) ?Binding {
            for (self.bindings[0..self.binding_count]) |binding| {
                if (binding.layer == layer_index) return binding;
            }
            return null;
        }

        /// Gives `layer_value` the pan/zoom `next` for this frame (section 5c). Not the base
        /// layer, once per layer, and never a layer bound to a target. `reset` clears it.
        pub fn view(self: *Self, layer_value: Layer, next: View) void {
            const layer_index: u8 = @backingInt(layer_value);
            assert(layer_index != @backingInt(Layer.base));
            assert(layer_index < layer_count);
            assert(self.view_mask & bit_of(layer_index) == 0);
            assert(self.binding_of(layer_index) == null);
            assert(next.zoom > 0 and !std.math.isInf(next.zoom));
            assert(finite(next.x) and finite(next.y));
            self.views[layer_index] = next;
            self.view_mask |= bit_of(layer_index);
        }

        /// The view of `layer_index` this frame, or null when it has none.
        pub fn view_of(self: *const Self, layer_index: u8) ?View {
            assert(layer_index < layer_count);
            if (self.view_mask & bit_of(layer_index) == 0) return null;
            return self.views[layer_index];
        }

        /// Opens a canvas over the viewed layers `mask` at `zoom` (section 5c).
        pub fn open_views(self: *Self, mask: u8, zoom: f32) void {
            assert(self.open_mask == 0);
            assert(mask != 0);
            assert(mask & self.view_mask == mask);
            assert(zoom > 0);
            self.open_mask = mask;
            self.view_zoom = zoom;
        }

        /// Closes the open canvas.
        pub fn close_views(self: *Self) void {
            assert(self.open_mask != 0);
            self.open_mask = 0;
            self.view_zoom = 1;
        }

        /// This frame's offscreen bindings.
        pub fn binding_list(self: *const Self) []const Binding {
            return self.bindings[0..self.binding_count];
        }

        /// Sets the layer later appends go to and returns the previous one, so a widget can
        /// restore it with `defer _ = cx.layer(previous);`.
        pub fn layer(self: *Self, next: Layer) Layer {
            assert(@backingInt(next) < layer_count);
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
            const layer_index: u8 = @backingInt(self.layer_now);
            // Inside a canvas only its layers; outside it no viewed layer (section 5c).
            if (self.open_mask != 0) {
                assert(self.open_mask & bit_of(layer_index) != 0);
            } else {
                assert(self.view_mask & bit_of(layer_index) == 0);
            }
            // A backdrop's glass draws on its layer or above (section 5d).
            if (comptime R.any_backdrop and T.texture != null) {
                const id = texture.?;
                if (self.textures.is_backdrop(id)) self.assert_over_backdrop(id, layer_index);
            }
            const key: u16 = @intCast(layer_index * P.texture_slots + slot);
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

        fn assert_over_backdrop(self: *const Self, id: textures.TextureId, layer_index: u8) void {
            for (self.backdrops[0..self.backdrop_count]) |marked| {
                if (marked.id == id) {
                    assert(layer_index >= marked.layer);
                    return;
                }
            }
            unreachable; // The backdrop was not marked this frame.
        }

        fn texture_slot(self: *const Self, comptime T: type, texture: ?textures.TextureId) u32 {
            if (comptime T.texture) |format| {
                const id = texture.?;
                assert(self.textures.exists(id));
                assert(self.textures.format_of(id) == format);
                return @backingInt(id);
            }
            assert(texture == null);
            return 0;
        }

        /// Instances `T`'s pool can still take this frame.
        pub fn room(self: *const Self, comptime T: type) u32 {
            const pool = &self.pools[comptime R.id(T)];
            const P = @TypeOf(pool.*);
            assert(pool.count <= P.capacity);
            return P.capacity - pool.count;
        }

        /// Counts an instance a caller refused before appending it, such as a path whose
        /// chunks would not fit (`draw/path.zig`).
        pub fn refuse(self: *Self) void {
            const before = self.overflow_count;
            self.overflow_count += 1;
            assert(self.overflow_count == before + 1);
        }

        /// Reserves `count` points and returns the index of the first, or null (counted in
        /// `overflow_count`) when the pool cannot hold them. The caller writes
        /// `points[first..][0..count]` before the frame is recorded.
        pub fn reserve_points(self: *Self, count: u32) ?u32 {
            comptime assert(point_total >= 1);
            assert(count >= 1);
            assert(self.point_count <= point_total);
            if (count > point_total - self.point_count) {
                self.refuse();
                return null;
            }
            const first = self.point_count;
            self.point_count += count;
            self.point_revision += 1;
            assert(self.point_count <= point_total);
            assert(first + count == self.point_count);
            return first;
        }

        /// Takes back the reservation that started at `first`, which must be the last one.
        pub fn release_points(self: *Self, first: u32) void {
            assert(first < self.point_count);
            self.point_count = first;
            self.point_revision += 1;
            assert(self.point_count == first);
        }

        /// This frame's points, in reservation order.
        pub fn point_items(self: *const Self) []const Point {
            assert(self.point_count <= point_total);
            return self.points[0..self.point_count];
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
            return @fromBackingInt(@intCast(pool.keys[index] / P.texture_slots));
        }

        /// The instance count of every pool, indexed by type id. The UI layer records it
        /// when a container begins, so `shift` can move exactly what the container drew.
        pub fn counts(self: *const Self) [R.count]u32 {
            var out: [R.count]u32 = undefined;
            inline for (0..R.count) |index| {
                out[index] = self.pools[index].count;
            }
            assert(out.len == R.count);
            return out;
        }

        /// Adds `(dx, dy)` to `rect.xy` of every instance appended since `starts` (from
        /// `counts`), in every pool and on every layer. Only `rect` moves: every draw type
        /// expresses its geometry relative to `rect` (`draw/registry.zig`, section 2), and
        /// clips stay put. Pools are append-only until `finalize`, so `[start, count)` is
        /// exactly what was drawn since `starts`. Bumps the revision of each moved pool.
        pub fn shift(self: *Self, starts: [R.count]u32, dx: f32, dy: f32) void {
            assert(!self.finalized);
            assert(dx == dx);
            assert(dy == dy);
            inline for (0..R.count) |index| {
                const pool = &self.pools[index];
                const P = @TypeOf(pool.*);
                const start = starts[index];
                assert(start <= pool.count);
                if (start < pool.count) {
                    shift_items(P.Item, pool.items[start..pool.count], dx, dy);
                    pool.revision += 1;
                }
            }
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
            const seen = self.appearance[0..self.appearance_count];
            if (self.batch_order == .appearance) {
                self.place_batches(seen);
                return;
            }
            var sorted: [batch_cap]Appearance = undefined;
            assert(seen.len <= sorted.len);
            const order = sorted[0..seen.len];
            @memcpy(order, seen);
            std.sort.insertion(Appearance, order, {}, Appearance.before);
            self.place_batches(order);
        }

        fn place_batches(self: *Self, order: []const Appearance) void {
            var layer_starts: [layer_count]u32 = @splat(0);
            for (order) |entry| {
                layer_starts[entry.layer] += 1;
            }
            var total: u32 = 0;
            for (&layer_starts) |*start| {
                const here = start.*;
                start.* = total;
                total += here;
            }
            assert(total == self.appearance_count);
            for (order) |entry| {
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
                        .texture = @fromBackingInt(@intCast(entry.key % P.texture_slots)),
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

fn bit_of(layer_index: u8) u8 {
    assert(layer_index < layer_count);
    return @as(u8, 1) << @intCast(layer_index);
}

/// The hot loop of `Context.shift`, over one pool's records.
fn shift_items(comptime T: type, items: []T, dx: f32, dy: f32) void {
    comptime assert(@offsetOf(T, "rect") == 0);
    assert(items.len >= 1);
    for (items) |*item| {
        item.rect[0] += dx;
        item.rect[1] += dy;
    }
    assert(items[0].rect[2] > 0);
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
    assert(@backingInt(Layer.overlay) < layer_count);
    assert(@backingInt(Layer.overlay) < @backingInt(Layer.popup));
    assert(@backingInt(Layer.popup) < @backingInt(Layer.tooltip));
    assert(@backingInt(Layer.tooltip) == layer_count - 1);
    // The sort key of a textured type must fit a u16.
    assert(layer_count * textures.texture_cap <= 65536);
    // One bit per layer in the view masks.
    assert(layer_count <= 8);
    assert(@sizeOf(View) == 16);
    assert(backdrop_module.backdrop_cap == textures.backdrop_cap);
}

const testing = std.testing;
const geometry = @import("../draw.zig");

const test_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 8 },
    .{ .type = types.Glyph, .cap = 8 },
    .{ .type = types.Image, .cap = 4 },
};

const TestContext = Context(&test_draw, 6, 0);

fn test_box(x: f32) types.Box {
    const rect: geometry.Rect = .{ .x = x, .y = 0, .width = 10, .height = 10 };
    const clip: geometry.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    return .of(rect, clip, .{ .fill = .{ 1, 1, 1, 1 } });
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

/// One frame of a glyph on the overlay and, on the base layer, two textures of images, a glyph,
/// and a box, appended in the order `scrambled` or its reverse.
fn append_scrambled(
    cx: *TestContext,
    first: textures.TextureId,
    second: textures.TextureId,
    scrambled: bool,
) !void {
    const image: types.Image = .{
        .rect = .{ 0, 0, 2, 2 },
        .clip = .{ 0, 0, 10, 10 },
        .uv = .{ 0, 0, 1, 1 },
        .tint = .{ 1, 1, 1, 1 },
    };
    if (scrambled) {
        _ = cx.layer(.overlay);
        try cx.append(types.Glyph, .atlas, test_glyph(0));
        _ = cx.layer(.base);
        try cx.append(types.Image, second, image);
        try cx.append(types.Glyph, .atlas, test_glyph(0));
        try cx.append(types.Image, first, image);
        try cx.append(types.Box, null, test_box(0));
    } else {
        try cx.append(types.Box, null, test_box(0));
        try cx.append(types.Image, first, image);
        try cx.append(types.Glyph, .atlas, test_glyph(0));
        try cx.append(types.Image, second, image);
        _ = cx.layer(.overlay);
        try cx.append(types.Glyph, .atlas, test_glyph(0));
    }
}

// Locks the two orders (section 1): a scrambled frame keeps its first appearance under
// `.appearance`; `.registered` gives Box, Glyph, Image of the lower texture, Image of the
// higher, then the overlay's Glyph, the same batches for the reverse append order, and `reset`
// keeps it.
test "registered order follows the draw list whatever was appended first" {
    const cx = new_context();
    const first = cx.textures.create(.rgba8, 2, 2);
    const second = cx.textures.create(.rgba8, 2, 2);
    try testing.expectEqual(BatchOrder.appearance, cx.batch_order);
    try append_scrambled(cx, first, second, true);
    cx.finalize();
    const seen = cx.batch_list();
    try testing.expectEqual(@as(usize, 5), seen.len);
    try testing.expectEqual(@as(u8, 2), seen[0].type_id);
    try testing.expectEqual(second, seen[0].texture);
    try testing.expectEqual(@as(u8, 1), seen[1].type_id);
    try testing.expectEqual(@as(u8, 2), seen[2].type_id);
    try testing.expectEqual(first, seen[2].texture);
    try testing.expectEqual(@as(u8, 0), seen[3].type_id);
    try testing.expectEqual(@as(u8, 4), seen[4].layer);

    cx.reset();
    cx.batch_order = .registered;
    try append_scrambled(cx, first, second, true);
    cx.finalize();
    var scrambled: [5]Batch = undefined;
    @memcpy(&scrambled, cx.batch_list());
    try testing.expectEqual(@as(u8, 0), scrambled[0].type_id);
    try testing.expectEqual(@as(u8, 1), scrambled[1].type_id);
    try testing.expectEqual(@as(u8, 2), scrambled[2].type_id);
    try testing.expectEqual(first, scrambled[2].texture);
    try testing.expectEqual(@as(u8, 2), scrambled[3].type_id);
    try testing.expectEqual(second, scrambled[3].texture);
    try testing.expectEqual(@as(u8, 1), scrambled[4].type_id);
    try testing.expectEqual(@as(u8, 4), scrambled[4].layer);

    cx.reset();
    try testing.expectEqual(BatchOrder.registered, cx.batch_order);
    try append_scrambled(cx, first, second, false);
    cx.finalize();
    try testing.expectEqualSlices(Batch, &scrambled, cx.batch_list());
}

// Locks that a frame finalized under `.registered` takes a late append: a box appended after
// `finalize` still draws before the glyph that came first.
test "registered order holds through an append after finalize" {
    const cx = new_context();
    cx.batch_order = .registered;
    try cx.append(types.Glyph, .atlas, test_glyph(0));
    cx.finalize();
    try cx.append(types.Box, null, test_box(0));
    cx.finalize();
    const batches = cx.batch_list();
    try testing.expectEqual(@as(usize, 2), batches.len);
    try testing.expectEqual(@as(u8, 0), batches[0].type_id);
    try testing.expectEqual(@as(u8, 1), batches[1].type_id);
}

// Locks that `shift` moves only what was appended after the snapshot, in every pool and on
// every layer, leaves clips alone, and moves the revisions of the pools it touched.
test "shift moves the instances appended since counts" {
    const cx = new_context();
    try cx.append(types.Box, null, test_box(0));
    const starts = cx.counts();
    try testing.expectEqual(@as(u32, 1), starts[0]);
    try testing.expectEqual(@as(u32, 0), starts[1]);
    try cx.append(types.Box, null, test_box(20));
    _ = cx.layer(.overlay);
    try cx.append(types.Glyph, .atlas, test_glyph(30));
    const box_revision = cx.revision(types.Box);
    const image_revision = cx.revision(types.Image);
    cx.shift(starts, 5, -2);
    const boxes = cx.items(types.Box);
    try testing.expectEqual(@as(f32, 0), boxes[0].rect[0]);
    try testing.expectEqual(@as(f32, 25), boxes[1].rect[0]);
    try testing.expectEqual(@as(f32, -2), boxes[1].rect[1]);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 100, 100 }, &boxes[1].clip);
    try testing.expectEqual(@as(f32, 35), cx.items(types.Glyph)[0].rect[0]);
    try testing.expect(cx.revision(types.Box) > box_revision);
    try testing.expectEqual(image_revision, cx.revision(types.Image));
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
        _ = cx.layer(@fromBackingInt(@intCast(level)));
        try cx.append(types.Box, null, test_box(0));
    }
    _ = cx.layer(@fromBackingInt(7));
    try testing.expectError(error.BatchFull, cx.append(types.Box, null, test_box(0)));
    try testing.expectEqual(@as(u32, 1), cx.overflow_count);
    try testing.expectEqual(@as(u32, 6), cx.items(types.Box).len);
}

// Locks views (section 5c): a viewed layer keeps its view until `reset`, the maps are inverse
// (world (10, 20) at zoom 2 from (100, 50) lands on (120, 90)), and the mask brackets a canvas.
test "a view maps world points and lasts one frame" {
    const cx = new_context();
    const view: View = .{ .x = 100, .y = 50, .zoom = 2 };
    try testing.expectEqual([2]f32{ 120, 90 }, view.apply(10, 20));
    try testing.expectEqual([2]f32{ 10, 20 }, view.invert(120, 90));
    cx.view(@fromBackingInt(1), view);
    try testing.expectEqual(view, cx.view_of(1).?);
    try testing.expectEqual(@as(?View, null), cx.view_of(2));
    cx.open_views(0b10, 2);
    _ = cx.layer(@fromBackingInt(1));
    try cx.append(types.Box, null, test_box(0));
    try testing.expectEqual(@as(f32, 2), cx.view_zoom);
    cx.close_views();
    _ = cx.layer(.base);
    try cx.append(types.Box, null, test_box(1));
    try testing.expectEqual(@as(f32, 1), cx.view_zoom);
    cx.reset();
    try testing.expectEqual(@as(?View, null), cx.view_of(1));
}

// Locks the u16 key (section 3): with all 64 texture slots taken, an image of the last texture
// on layer 7 gets key 7 * 64 + 63 = 511, past what a u8 held, and batches with that texture
// after the image of texture 1 on the base layer.
test "64 textures batch on the top layer with keys past 255" {
    const cx = new_context();
    var last: textures.TextureId = .atlas;
    while (cx.textures.count < textures.texture_cap) last = cx.textures.create(.rgba8, 2, 2);
    try testing.expectEqual(@as(u8, 63), @backingInt(last));
    const image: types.Image = .{
        .rect = .{ 0, 0, 2, 2 },
        .clip = .{ 0, 0, 10, 10 },
        .uv = .{ 0, 0, 1, 1 },
        .tint = .{ 1, 1, 1, 1 },
    };
    _ = cx.layer(@fromBackingInt(7));
    try cx.append(types.Image, last, image);
    _ = cx.layer(.base);
    try cx.append(types.Image, @fromBackingInt(1), image);
    cx.finalize();
    const batches = cx.batch_list();
    try testing.expectEqual(@as(usize, 2), batches.len);
    try testing.expectEqual(@as(u16, 1), batches[0].key);
    try testing.expectEqual(@as(u16, 511), batches[1].key);
    try testing.expectEqual(last, batches[1].texture);
    try testing.expectEqual(@as(u8, 7), batches[1].layer);
}

const glass_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 4 },
    .{ .type = backdrop_module.Glass, .cap = 4 },
};

const GlassContext = Context(&glass_draw, 6, 0);

// Locks the backdrop ids (section 5d): the first mark of a frame creates the first id and the
// second the second; marking a layer again keeps the wider blur and returns its id; a glass
// on layer 5 samples the backdrop at 4, one on layer 3 the one at 2, and the base layer none;
// the next frame marking the same layers in the same order gets the same ids and creates
// none; a context without a backdrop type has no capacity.
test "backdrops keep their ids by call order and glass finds the one under it" {
    var cx: GlassContext = undefined;
    cx.init();
    cx.text.scale_120 = 120;
    try std.testing.expectEqual(@as(u32, 2), GlassContext.backdrop_capacity);
    try std.testing.expectEqual(@as(u32, 0), TestContext.backdrop_capacity);
    const upper = cx.backdrop(@fromBackingInt(4), 8);
    const lower = cx.backdrop(@fromBackingInt(2), 16);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(upper));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(lower));
    try std.testing.expectEqual(upper, cx.backdrop(@fromBackingInt(4), 12));
    try std.testing.expectEqual(@as(f32, 12), cx.backdrop_under(@fromBackingInt(7)).?.blur);
    try std.testing.expectEqual(upper, cx.backdrop_under(@fromBackingInt(5)).?.id);
    try std.testing.expectEqual(lower, cx.backdrop_under(@fromBackingInt(3)).?.id);
    try std.testing.expect(cx.backdrop_under(.base) == null);
    _ = cx.layer(@fromBackingInt(5));
    const rect: [4]f32 = .{ 0, 0, 10, 10 };
    const glass: backdrop_module.Glass = .{
        .rect = rect,
        .clip = rect,
        .tint = @splat(0),
        .look = @splat(0),
        .lens = .{ 0, 1, 0, 0 },
    };
    try cx.append(backdrop_module.Glass, upper, glass);
    cx.reset();
    try std.testing.expectEqual(@as(usize, 0), cx.backdrop_list().len);
    try std.testing.expectEqual(upper, cx.backdrop(@fromBackingInt(4), 8));
    try std.testing.expectEqual(lower, cx.backdrop(@fromBackingInt(2), 8));
    try std.testing.expectEqual(@as(u32, 3), cx.textures.count);
}

//! Sampled textures: a fixed table of ids, with creates and writes queued until the next stream.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Queue Instead of Recording Directly
//! An app creates its images in `App.init`, and the native host calls `init` before the GPU
//! device exists. `Textures` therefore only records what was asked: `create` reserves the
//! next `TextureId` and remembers its format and size, and `write` remembers a region and the
//! bytes for it. `draw/renderer.zig` drains both queues into the next command stream it
//! records (setup or frame), creating each texture, its bind group, and its uploads before the
//! pass that samples them. Nothing here touches a GPU, so it is unit tested directly.
//!
//! ## 2. Ids and Formats
//! `TextureId` is the index into this table, `0 .. texture_cap`. Id 0 is the glyph atlas
//! (`TextureId.atlas`): `draw.Context.init` creates it before anything else, empty, and the
//! glyph cache (`text/cache.zig`) queues the regions it rasterizes into. `Format.r8` is
//! single-channel coverage (`r8unorm`) and `Format.rgba8` straight-alpha color (`rgba8unorm`);
//! `r16float` and `rg16float` (bytes are `f16` bit patterns) and `r32float` and `rg32float`
//! (`f32`) are data. Every format samples as `texture_2d<f32>`. The 32-bit float formats are
//! not filterable without an optional WebGPU feature, so they are `Class.unfilterable`: they
//! bind through a second layout with a non-filtering sampler, and `create_sampled` asserts
//! they are sampled `nearest`.
//!
//! ## 2b. Offscreen Targets
//! `create_target(kind)` reserves an id with format `.target`: the surface format, filterable,
//! sampled linear and clamped. A target has no size and nothing to write: the renderer sizes
//! and renders it when a layer is bound to it (`draw/fx.zig`, `draw/renderer.zig`, section
//! 4c). A `.feedback` target is two textures behind one id, so a layer can draw over its own
//! last frame. At most `target_cap` targets exist, counted against `texture_cap`.
//! `create_backdrop` reserves a target of kind `.backdrop`: a backdrop's pack, which the draw
//! context asks for when a frame first marks a backdrop and the renderer sizes and writes with
//! its blur chain (`draw/backdrop.zig`). At most `backdrop_cap`, also counted against
//! `texture_cap` but not `target_cap`.
//!
//! ## 2a. Sampling
//! Each texture has a `Sampling`: its filter and its address mode per axis (clamp to the
//! edge, or repeat). `create` takes the default (linear, clamp, clamp). There are
//! `sampling_count` modes; `Sampling.index` numbers them, and the renderer creates one sampler
//! per mode the first time a texture uses it (`draw/renderer.zig`, section 2).
//!
//! ## 3. Lifetime of Written Bytes and Row Strides
//! `write` and `write_strided` store a slice, not a copy. The bytes must stay valid and
//! unchanged until the stream that carries the write has been submitted, which is the next
//! present. App-owned storage (the app lives for the whole program), static data, and the
//! glyph cache's mirror inside the context all qualify.
//!
//! `write` takes tightly packed rows. `write_strided` takes rows `bytes_per_row` apart, so a
//! sub-rectangle of a larger CPU image uploads in place: `data` starts at the region's first
//! texel and holds `bytes_per_row * (height - 1) + width * bytes_per_texel` bytes, the exact
//! length WebGPU's `writeTexture` requires. Neither host needs `bytes_per_row` aligned to
//! 256: that rule applies to buffer-to-texture copies, not to `queue.writeTexture`.
//!
//! ## 3a. Rings
//! `Ring(format, width, height)` is an app-owned mirror of `width` by `height` texels with
//! `head`, the column the next `push` writes. `push` copies one column into the mirror,
//! advances `head = (head + 1) mod width`, and counts it pending; it queues nothing, so any
//! number of pushes between two streams (a timer that ticks while the window is hidden and
//! frame callbacks stop) costs no queue room. `flush`, called once per draw, queues the pending
//! columns with `write_strided` (rows `width * texel` bytes apart): one write, or two when
//! they wrap past the last column, or the whole mirror once `width` columns are pending. `set`
//! writes a column without counting it, and `fill` queues the whole mirror, for a prefill.
//! `draw.Ring` shows the oldest column (`head`) at the left (`draw/wave.zig`).
//!
//! ## 4. TigerStyle Invariants
//! - `texture_cap` bounds the table and `write_cap` bounds the queued writes per stream; both
//!   are asserted, and `layer_count * texture_cap` must fit the `u16` sort key in `pools.zig`.
//! - Ids are never freed: every texture lives for the whole program.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");

/// Textures one app may create, the glyph atlas included.
pub const texture_cap: u32 = 64;

/// Writes that may be queued between two recorded streams.
pub const write_cap: u32 = 16;

/// Texel formats a draw type can sample.
pub const Format = enum(u8) {
    r8,
    rgba8,
    r16float,
    rg16float,
    r32float,
    rg32float,
    /// An offscreen target in the surface format (section 2b).
    target,
};

/// How an offscreen target keeps its pixels (section 2b).
pub const TargetKind = enum(u8) {
    /// Re-rendered when its content changes.
    single,
    /// Re-rendered every frame it is bound, over its own last frame.
    feedback,
    /// A backdrop's pack (`draw/backdrop.zig`): the renderer's blur chain writes it.
    backdrop,
};

/// Backdrop ids one app may hold, `backdrop.backdrop_cap` (asserted in `draw/pools.zig`).
pub const backdrop_cap: u32 = 2;

/// Offscreen targets one app may create.
pub const target_cap: u32 = 4;

/// Which texture bind group layout a format binds through (module guide, section 2).
pub const Class = enum(u8) {
    filterable,
    unfilterable,
};

/// How a texture is sampled (module guide, section 2a).
pub const Sampling = struct {
    filter: commands.Filter = .linear,
    address_u: commands.Address = .clamp,
    address_v: commands.Address = .clamp,

    /// The mode's number, `0 .. sampling_count`: filter, then u, then v.
    pub fn index(self: Sampling) u32 {
        const value = @as(u32, @backingInt(self.filter)) * 4 +
            @as(u32, @backingInt(self.address_u)) * 2 + @backingInt(self.address_v);
        assert(value < sampling_count);
        return value;
    }
};

/// Distinct sampling modes: two filters times two address modes per axis.
pub const sampling_count: u32 = 8;

/// Index into the texture table. `atlas` is always id 0.
pub const TextureId = enum(u8) {
    atlas = 0,
    _,
};

/// A texel region in a texture, origin at its top-left.
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// One queued upload. Rows of `data` are `bytes_per_row` apart; the last may be short.
pub const Write = struct {
    id: TextureId,
    region: Region,
    bytes_per_row: u32,
    data: []const u8,
};

/// The app's textures: creates and writes queued for the renderer's next stream (section 2).
pub const Textures = struct {
    count: u32,
    /// Ids below `created` have been recorded into a stream; the rest are pending.
    created: u32,
    formats: [texture_cap]Format,
    widths: [texture_cap]u32,
    heights: [texture_cap]u32,
    samplings: [texture_cap]Sampling,
    /// The kind of each `.target` entry; meaningless for the others.
    kinds: [texture_cap]TargetKind,
    target_count: u32,
    /// Backdrop ids created so far (`create_backdrop`); not counted in `target_count`.
    backdrop_count: u32,
    writes: [write_cap]Write,
    write_count: u32,
    /// Moves on every queued write of a texture: the pixel cache folds it into the tiles that
    /// sample the texture, because a rewrite changes pixels without changing any record.
    revisions: [texture_cap]u32,

    /// An empty table. Out-pointer init so a static table needs no stack copy.
    pub fn init(self: *Textures) void {
        self.count = 0;
        self.created = 0;
        self.write_count = 0;
        self.target_count = 0;
        self.backdrop_count = 0;
        self.revisions = @splat(0);
        assert(self.count == 0);
        assert(self.write_count == 0);
    }

    /// Reserves the next id for a `width` by `height` texture of `format`, sampled linear and
    /// clamped. The GPU texture and its bind group are created in the next recorded stream.
    pub fn create(self: *Textures, format: Format, width: u32, height: u32) TextureId {
        return self.create_sampled(format, width, height, .{});
    }

    /// Reserves the next id for an offscreen target of `kind` (module guide, section 2b).
    pub fn create_target(self: *Textures, kind: TargetKind) TextureId {
        assert(self.count < texture_cap);
        assert(self.target_count < target_cap);
        assert(kind != .backdrop);
        const index = self.count;
        self.formats[index] = .target;
        self.widths[index] = 0;
        self.heights[index] = 0;
        self.samplings[index] = .{};
        self.kinds[index] = kind;
        self.count += 1;
        self.target_count += 1;
        assert(self.count == index + 1);
        return @fromBackingInt(@intCast(index));
    }

    /// Reserves the next id for a backdrop's pack (module guide, section 2b). The draw context
    /// calls it the first time a frame marks more backdrops than it has ids.
    pub fn create_backdrop(self: *Textures) TextureId {
        assert(self.count < texture_cap);
        assert(self.backdrop_count < backdrop_cap);
        const index = self.count;
        self.formats[index] = .target;
        self.widths[index] = 0;
        self.heights[index] = 0;
        self.samplings[index] = .{};
        self.kinds[index] = .backdrop;
        self.count += 1;
        self.backdrop_count += 1;
        assert(self.count == index + 1);
        return @fromBackingInt(@intCast(index));
    }

    /// True when `id` is a backdrop's pack.
    pub fn is_backdrop(self: *const Textures, id: TextureId) bool {
        return self.format_of(id) == .target and self.kinds[@backingInt(id)] == .backdrop;
    }

    /// True when `id` is an offscreen target.
    pub fn is_target(self: *const Textures, id: TextureId) bool {
        return self.format_of(id) == .target;
    }

    /// `create` with a sampling mode (module guide, section 2a). An unfilterable format must
    /// be sampled `nearest`.
    pub fn create_sampled(
        self: *Textures,
        format: Format,
        width: u32,
        height: u32,
        sampling: Sampling,
    ) TextureId {
        assert(self.count < texture_cap);
        assert(width != 0);
        assert(height != 0);
        assert(format != .target);
        if (class_of(format) == .unfilterable) assert(sampling.filter == .nearest);
        const index = self.count;
        self.formats[index] = format;
        self.widths[index] = width;
        self.heights[index] = height;
        self.samplings[index] = sampling;
        self.count += 1;
        assert(self.count == index + 1);
        return @fromBackingInt(@intCast(index));
    }

    /// Queues `data` for `region` of texture `id`. Rows are tightly packed, so `data` holds
    /// exactly `region.width * bytes_per_texel(format) * region.height` bytes. See the module
    /// guide for how long `data` must stay valid.
    pub fn write(self: *Textures, id: TextureId, region: Region, data: []const u8) void {
        const index = @backingInt(id);
        assert(index < self.count);
        assert(self.formats[index] != .target);
        assert(self.write_count < write_cap);
        assert(region.width != 0);
        assert(region.height != 0);
        assert(region.x + region.width <= self.widths[index]);
        assert(region.y + region.height <= self.heights[index]);
        const bytes_per_row = region.width * bytes_per_texel(self.formats[index]);
        assert(data.len == bytes_per_row * region.height);
        self.writes[self.write_count] = .{
            .id = id,
            .region = region,
            .bytes_per_row = bytes_per_row,
            .data = data,
        };
        self.write_count += 1;
        self.revisions[index] +%= 1;
        assert(self.write_count <= write_cap);
    }

    /// Queues `data` for `region` of texture `id`, with rows `bytes_per_row` apart. `data`
    /// starts at the region's first texel; see the module guide, section 3.
    pub fn write_strided(
        self: *Textures,
        id: TextureId,
        region: Region,
        bytes_per_row: u32,
        data: []const u8,
    ) void {
        const index = @backingInt(id);
        assert(index < self.count);
        assert(self.formats[index] != .target);
        assert(self.write_count < write_cap);
        assert(region.width != 0);
        assert(region.height != 0);
        assert(region.x + region.width <= self.widths[index]);
        assert(region.y + region.height <= self.heights[index]);
        const row_bytes = region.width * bytes_per_texel(self.formats[index]);
        assert(bytes_per_row >= row_bytes);
        assert(data.len == bytes_per_row * (region.height - 1) + row_bytes);
        self.writes[self.write_count] = .{
            .id = id,
            .region = region,
            .bytes_per_row = bytes_per_row,
            .data = data,
        };
        self.write_count += 1;
        self.revisions[index] +%= 1;
        assert(self.write_count <= write_cap);
    }

    /// How many writes `id` has had queued, wrapping (see `revisions`).
    pub fn revision_of(self: *const Textures, id: TextureId) u32 {
        const index = @backingInt(id);
        assert(index < self.count);
        return self.revisions[index];
    }

    /// The format `id` was created with.
    pub fn format_of(self: *const Textures, id: TextureId) Format {
        const index = @backingInt(id);
        assert(index < self.count);
        return self.formats[index];
    }

    /// True when `id` names a created (possibly still pending) texture.
    pub fn exists(self: *const Textures, id: TextureId) bool {
        assert(self.count <= texture_cap);
        return @backingInt(id) < self.count;
    }
};

/// A ring texture with a write head (module guide, section 3a). Initialize with `init`.
pub fn Ring(comptime format: Format, comptime width: u32, comptime height: u32) type {
    comptime {
        assert(width >= 1);
        assert(height >= 1);
    }
    return struct {
        const Self = @This();
        pub const texel_bytes: u32 = bytes_per_texel(format);
        pub const row_bytes: u32 = width * texel_bytes;
        pub const column_bytes: u32 = height * texel_bytes;
        pub const columns: u32 = width;
        pub const rows: u32 = height;

        texels: [width * height * texel_bytes]u8,
        /// The column the next `push` writes: the oldest one.
        head: u32,
        /// Columns pushed since the last `flush`, at most `width` (then all of them).
        pending: u32,
        id: TextureId,

        /// Creates the texture (sampled nearest, though `draw.Ring` only loads texels) and
        /// zeroes the mirror. The texture holds whatever its first write puts there.
        pub fn init(self: *Self, table: *Textures) void {
            self.id = table.create_sampled(format, width, height, .{ .filter = .nearest });
            @memset(&self.texels, 0);
            self.head = 0;
            self.pending = 0;
            assert(table.format_of(self.id) == format);
        }

        /// Writes `column` (`column_bytes`, top row first) at `index` of the mirror only.
        pub fn set(self: *Self, index: u32, column: []const u8) void {
            assert(index < width);
            assert(column.len == column_bytes);
            for (0..height) |row| {
                const at = row * row_bytes + index * texel_bytes;
                @memcpy(self.texels[at..][0..texel_bytes], column[row * texel_bytes ..][0..texel_bytes]);
            }
        }

        /// Writes `column` at `head`, advances `head`, and counts the column pending.
        pub fn push(self: *Self, column: []const u8) void {
            self.set(self.head, column);
            self.head = (self.head + 1) % width;
            self.pending = @min(self.pending + 1, width);
            assert(self.head < width);
        }

        /// Queues the pending columns (module guide, section 3a). Returns how many writes it
        /// queued: 0, 1, or 2.
        pub fn flush(self: *Self, table: *Textures) u32 {
            const count = self.pending;
            self.pending = 0;
            if (count == 0) return 0;
            if (count == width) {
                self.fill(table);
                return 1;
            }
            const first = (self.head + width - count) % width;
            const before_end = @min(count, width - first);
            self.queue(table, first, before_end);
            if (before_end == count) return 1;
            self.queue(table, 0, count - before_end);
            return 2;
        }

        fn queue(self: *Self, table: *Textures, x: u32, count: u32) void {
            assert(count >= 1);
            assert(x + count <= width);
            const first = x * texel_bytes;
            table.write_strided(
                self.id,
                .{ .x = x, .y = 0, .width = count, .height = height },
                row_bytes,
                self.texels[first..][0 .. row_bytes * (height - 1) + count * texel_bytes],
            );
        }

        /// Queues the whole mirror, after a prefill with `set`.
        pub fn fill(self: *Self, table: *Textures) void {
            table.write(self.id, .{ .x = 0, .y = 0, .width = width, .height = height }, &self.texels);
        }
    };
}

pub fn bytes_per_texel(format: Format) u32 {
    return switch (format) {
        .r8 => 1,
        .rgba8 => 4,
        .r16float => 2,
        .rg16float => 4,
        .r32float => 4,
        .rg32float => 8,
        .target => 4,
    };
}

/// The command-stream format for `format`.
pub fn gpu_format(format: Format) commands.TextureFormat {
    return switch (format) {
        .r8 => .r8unorm,
        .rgba8 => .rgba8unorm,
        .r16float => .r16float,
        .rg16float => .rg16float,
        .r32float => .r32float,
        .rg32float => .rg32float,
        // Targets are created by `target_create`, which carries no format.
        .target => unreachable,
    };
}

/// The layout class of `format` (module guide, section 2).
pub fn class_of(format: Format) Class {
    return switch (format) {
        .r8, .rgba8, .r16float, .rg16float, .target => .filterable,
        .r32float, .rg32float => .unfilterable,
    };
}

comptime {
    assert(texture_cap <= commands.caps.get(.texture));
    // One bind group per texture plus the frame group.
    assert(texture_cap + 1 <= commands.caps.get(.bind_group));
    // Every texture, a feedback target's second texture, and the kept target.
    assert(texture_cap + target_cap + 1 <= commands.caps.get(.texture));
    assert(write_cap >= 1);
    assert(@backingInt(TextureId.atlas) == 0);
    assert(target_cap <= texture_cap);
    // Every sampling mode gets its own sampler.
    assert(sampling_count <= commands.caps.get(.sampler));
    assert(sampling_count == 2 * 2 * 2);
}

// Locks the ring (section 3a): pushes queue nothing; a flush of two consecutive columns is
// one strided write two columns wide, holding each row's two texels; pushes that wrap past
// the last column flush as two writes; a ring pushed more than its width flushes the whole
// mirror once; and a flush with nothing pending queues nothing.
test "ring pushes queue nothing and flush one or two writes" {
    var textures: Textures = undefined;
    textures.init();
    var ring: Ring(.r16float, 3, 2) = undefined;
    ring.init(&textures);
    try std.testing.expectEqual(@as(u32, 6), @TypeOf(ring).row_bytes);
    ring.push(&.{ 1, 2, 3, 4 });
    ring.push(&.{ 5, 6, 7, 8 });
    try std.testing.expectEqual(@as(u32, 0), textures.write_count);
    try std.testing.expectEqual(@as(u32, 1), ring.flush(&textures));
    try std.testing.expectEqual(Region{ .x = 0, .y = 0, .width = 2, .height = 2 }, textures.writes[0].region);
    try std.testing.expectEqual(@as(u32, 6), textures.writes[0].bytes_per_row);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 5, 6, 0, 0, 3, 4, 7, 8 }, textures.writes[0].data);
    ring.push(&.{ 9, 9, 9, 9 });
    ring.push(&.{ 4, 4, 4, 4 });
    try std.testing.expectEqual(@as(u32, 1), ring.head);
    try std.testing.expectEqual(@as(u32, 2), ring.flush(&textures));
    try std.testing.expectEqual(@as(u32, 2), textures.writes[1].region.x);
    try std.testing.expectEqual(@as(u32, 0), textures.writes[2].region.x);
    try std.testing.expectEqual(@as(u32, 1), textures.writes[2].region.width);
    for (0..7) |_| ring.push(&.{ 7, 7, 7, 7 });
    try std.testing.expectEqual(@as(u32, 1), ring.flush(&textures));
    try std.testing.expectEqual(@as(u32, 3), textures.writes[3].region.width);
    try std.testing.expectEqual(@as(u32, 0), ring.flush(&textures));
    try std.testing.expectEqual(@as(u32, 4), textures.write_count);
}

// Locks the formats: bytes per texel, the command-stream name, and the class, and that a
// 32-bit float texture keeps its nearest, repeating mode while `create` defaults to linear
// clamping. Mode numbers run filter, u, v.
test "float formats have their sizes, classes, and sampling modes" {
    var textures: Textures = undefined;
    textures.init();
    const atlas = textures.create(.r8, 4, 4);
    const heat = textures.create_sampled(.r32float, 8, 4, .{
        .filter = .nearest,
        .address_u = .repeat,
    });
    try std.testing.expectEqual(Sampling{}, textures.samplings[@backingInt(atlas)]);
    try std.testing.expectEqual(commands.Address.repeat, textures.samplings[1].address_u);
    try std.testing.expectEqual(Format.r32float, textures.format_of(heat));
    try std.testing.expectEqual(@as(u32, 2), bytes_per_texel(.r16float));
    try std.testing.expectEqual(@as(u32, 8), bytes_per_texel(.rg32float));
    try std.testing.expectEqual(commands.TextureFormat.rg16float, gpu_format(.rg16float));
    try std.testing.expectEqual(Class.unfilterable, class_of(.rg32float));
    try std.testing.expectEqual(Class.filterable, class_of(.rg16float));
    try std.testing.expectEqual(@as(u32, 4), (Sampling{}).index());
    try std.testing.expectEqual(@as(u32, 2), textures.samplings[1].index());
    // A 16-bit float texel is the `f16` bit pattern: 0.5 is 0x3800 and -2 is 0xC000.
    const half = [_]f16{ 0.5, -2 };
    const data = std.mem.sliceAsBytes(&half);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x38, 0x00, 0xC0 }, data);
}

// Locks id assignment in creation order, the per-format row size of a write, and the queue.
test "create assigns ids in order and write queues packed rows" {
    var textures: Textures = undefined;
    textures.init();
    const atlas = textures.create(.r8, 512, 256);
    const badge = textures.create(.rgba8, 32, 32);
    try std.testing.expectEqual(TextureId.atlas, atlas);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(badge));
    try std.testing.expectEqual(Format.rgba8, textures.format_of(badge));
    const pixels: [32 * 4 * 2]u8 = @splat(0);
    textures.write(badge, .{ .x = 0, .y = 30, .width = 32, .height = 2 }, &pixels);
    try std.testing.expectEqual(@as(u32, 1), textures.write_count);
    try std.testing.expectEqual(@as(u32, 128), textures.writes[0].bytes_per_row);
    try std.testing.expect(textures.exists(badge));
    try std.testing.expect(!textures.exists(@fromBackingInt(2)));
    try std.testing.expectEqual(@as(u32, 0), textures.created);
}

// Locks a strided write: the row stride is kept and the data ends at the last row's width.
test "write_strided keeps the row stride of a sub-rectangle" {
    var textures: Textures = undefined;
    textures.init();
    const atlas = textures.create(.r8, 16, 8);
    const image: [16 * 8]u8 = @splat(0);
    const first = 2 * 16 + 3;
    const region: Region = .{ .x = 3, .y = 2, .width = 5, .height = 4 };
    textures.write_strided(atlas, region, 16, image[first..][0 .. 3 * 16 + 5]);
    try std.testing.expectEqual(@as(u32, 16), textures.writes[0].bytes_per_row);
    try std.testing.expectEqual(@as(usize, 53), textures.writes[0].data.len);
}

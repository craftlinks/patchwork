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
//! single-channel coverage (`r8unorm`), and `Format.rgba8` is straight-alpha color
//! (`rgba8unorm`). Both sample as filterable float, so one bind group layout and one clamping
//! linear sampler serve every texture.
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
//! ## 4. TigerStyle Invariants
//! - `texture_cap` bounds the table and `write_cap` bounds the queued writes per stream; both
//!   are asserted, and `layer_count * texture_cap` must fit the `u8` sort key in `pools.zig`.
//! - Ids are never freed: every texture lives for the whole program.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");

/// Textures one app may create, the glyph atlas included.
pub const texture_cap: u32 = 32;

/// Writes that may be queued between two recorded streams.
pub const write_cap: u32 = 16;

/// Texel formats a draw type can sample.
pub const Format = enum(u8) {
    r8,
    rgba8,
};

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

pub const Textures = struct {
    count: u32,
    /// Ids below `created` have been recorded into a stream; the rest are pending.
    created: u32,
    formats: [texture_cap]Format,
    widths: [texture_cap]u32,
    heights: [texture_cap]u32,
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
        self.revisions = @splat(0);
        assert(self.count == 0);
        assert(self.write_count == 0);
    }

    /// Reserves the next id for a `width` by `height` texture of `format`. The GPU texture
    /// and its bind group are created in the next recorded stream.
    pub fn create(self: *Textures, format: Format, width: u32, height: u32) TextureId {
        assert(self.count < texture_cap);
        assert(width != 0);
        assert(height != 0);
        const index = self.count;
        self.formats[index] = format;
        self.widths[index] = width;
        self.heights[index] = height;
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

pub fn bytes_per_texel(format: Format) u32 {
    return switch (format) {
        .r8 => 1,
        .rgba8 => 4,
    };
}

/// The command-stream format for `format`.
pub fn gpu_format(format: Format) commands.TextureFormat {
    return switch (format) {
        .r8 => .r8unorm,
        .rgba8 => .rgba8unorm,
    };
}

comptime {
    assert(texture_cap <= commands.caps.get(.texture));
    // One bind group per texture plus the frame group.
    assert(texture_cap + 1 <= commands.caps.get(.bind_group));
    assert(write_cap >= 1);
    assert(@backingInt(TextureId.atlas) == 0);
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

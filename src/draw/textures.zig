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
//! `TextureId` is the index into this table, `0 .. texture_cap`. Id 0 is the font atlas
//! (`TextureId.atlas`): `draw.Context.init` creates it before anything else and queues the
//! upload of `font.atlas_bytes`. `Format.r8` is single-channel coverage (`r8unorm`), and
//! `Format.rgba8` is straight-alpha color (`rgba8unorm`). Both sample as filterable float, so
//! one bind group layout and one clamping linear sampler serve every texture.
//!
//! ## 3. Lifetime of Written Bytes
//! `write` stores a slice, not a copy. The bytes must stay valid and unchanged until the
//! stream that carries the write has been submitted, which is the next present. App-owned
//! storage (the app lives for the whole program) and static data both qualify.
//!
//! ## 4. TigerStyle Invariants
//! - `texture_cap` bounds the table and `write_cap` bounds the queued writes per stream; both
//!   are asserted, and `layer_count * texture_cap` must fit the `u8` sort key in `pools.zig`.
//! - Ids are never freed: every texture lives for the whole program.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");

/// Textures one app may create, the font atlas included.
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

/// One queued upload. `data` holds `region.height` rows of `bytes_per_row` bytes.
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

    /// An empty table. Out-pointer init so a static table needs no stack copy.
    pub fn init(self: *Textures) void {
        self.count = 0;
        self.created = 0;
        self.write_count = 0;
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
        return @enumFromInt(index);
    }

    /// Queues `data` for `region` of texture `id`. Rows are tightly packed, so `data` holds
    /// exactly `region.width * bytes_per_texel(format) * region.height` bytes. See the module
    /// guide for how long `data` must stay valid.
    pub fn write(self: *Textures, id: TextureId, region: Region, data: []const u8) void {
        const index = @intFromEnum(id);
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
        assert(self.write_count <= write_cap);
    }

    /// The format `id` was created with.
    pub fn format_of(self: *const Textures, id: TextureId) Format {
        const index = @intFromEnum(id);
        assert(index < self.count);
        return self.formats[index];
    }

    /// True when `id` names a created (possibly still pending) texture.
    pub fn exists(self: *const Textures, id: TextureId) bool {
        assert(self.count <= texture_cap);
        return @intFromEnum(id) < self.count;
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
    assert(@intFromEnum(TextureId.atlas) == 0);
}

// Locks id assignment in creation order, the per-format row size of a write, and the queue.
test "create assigns ids in order and write queues packed rows" {
    var textures: Textures = undefined;
    textures.init();
    const atlas = textures.create(.r8, 512, 256);
    const badge = textures.create(.rgba8, 32, 32);
    try std.testing.expectEqual(TextureId.atlas, atlas);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(badge));
    try std.testing.expectEqual(Format.rgba8, textures.format_of(badge));
    const pixels = [_]u8{0} ** (32 * 4 * 2);
    textures.write(badge, .{ .x = 0, .y = 30, .width = 32, .height = 2 }, &pixels);
    try std.testing.expectEqual(@as(u32, 1), textures.write_count);
    try std.testing.expectEqual(@as(u32, 128), textures.writes[0].bytes_per_row);
    try std.testing.expect(textures.exists(badge));
    try std.testing.expect(!textures.exists(@enumFromInt(2)));
    try std.testing.expectEqual(@as(u32, 0), textures.created);
}

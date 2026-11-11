//! PNG files: an uncompressed writer and the reader of exactly what it writes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Its Own Namespace
//! A tool that writes a frame (`--render --out`, a consumer's export) looks for `png`, not for
//! the bench. `patchwork.png` is that name; `bench.png_write`, `png_size`, and `png_read_stored`
//! stay as aliases of `write`, `size`, and `read_stored`, so nothing that calls them changes.
//!
//! ## 2. What `write` Writes
//! 8-bit RGB, no compression: one `IDAT` holding a zlib stream of stored deflate blocks (at most
//! 65535 bytes each) over the rows, each row led by filter byte 0, with CRC-32 and Adler-32 from
//! `std.hash`. Any viewer opens it and it needs no deflate encoder. A file is 3 bytes a pixel
//! plus a byte a row and a few hundred bytes of framing: `size` is its exact length. A tool
//! that wants small files pipes raw frames to an encoder (`--render --out -`).
//!
//! ## 3. What `read_stored` Reads
//! Exactly that form back (the regress host's baselines, `zig build compare`), into the caller's
//! buffer; anything else (compressed blocks, another color type, filters) is
//! `error.Unsupported`, and a damaged file is `error.BadChecksum` or `error.Truncated`.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: `write` streams to the caller's writer, `read_stored` fills the caller's
//!   buffer.
//! - Bounds: a side is at most `bench.width_max` pixels; the block loop of `read_stored` is
//!   bounded by the blocks the image's size needs.

const std = @import("std");
const assert = std.debug.assert;
const bench = @import("bench.zig");

/// An image `read_stored` returns: rows of RGB pixels, top to bottom.
pub const Image = bench.Image;

/// Bytes `write` writes for a `width` by `height` image.
pub fn size(width: u32, height: u32) u64 {
    assert(width >= 1 and width <= bench.width_max);
    assert(height >= 1);
    const raw = raw_len_of(width, height);
    const blocks = (raw + block_max - 1) / block_max;
    const zlib = 2 + blocks * 5 + raw + 4;
    return signature.len + (12 + 13) + (12 + zlib) + 12;
}

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
/// Most bytes one stored deflate block holds.
const block_max: u64 = 65535;

/// The filtered rows' length: a filter byte and `width` RGB pixels per row.
fn raw_len_of(width: u32, height: u32) u64 {
    return @as(u64, height) * (1 + @as(u64, width) * 3);
}

/// Writes `rgb` (`height` rows of `width` RGB pixels, top to bottom) as a PNG (section 2).
pub fn write(
    writer: *std.Io.Writer,
    width: u32,
    height: u32,
    rgb: []const u8,
) std.Io.Writer.Error!void {
    assert(rgb.len == @as(u64, width) * height * 3);
    const raw_len = raw_len_of(width, height);
    const blocks = (raw_len + block_max - 1) / block_max;
    try writer.writeAll(&signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    // Bit depth 8, color type 2 (RGB), deflate, no filter method extension, no interlace.
    header[8..13].* = .{ 8, 2, 0, 0, 0 };
    try chunk_write(writer, "IHDR", &header);
    const zlib_len = 2 + blocks * 5 + raw_len + 4;
    var chunk: Chunk = try .begin(writer, "IDAT", @intCast(zlib_len));
    // CMF 0x78 (deflate, 32 KiB window) and FLG 0x01 (no dictionary, check bits).
    try chunk.write(&.{ 0x78, 0x01 });
    var adler: std.hash.Adler32 = .{};
    var left: u64 = raw_len;
    var block_left: u64 = 0;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const pixels = rgb[@as(usize, row) * width * 3 ..][0 .. width * 3];
        const filter = [1]u8{0};
        for ([2][]const u8{ &filter, pixels }) |piece| {
            var at: usize = 0;
            while (at < piece.len) {
                if (block_left == 0) {
                    block_left = @min(left, block_max);
                    const len: u16 = @intCast(block_left);
                    var stored: [5]u8 = undefined;
                    stored[0] = @intFromBool(left == block_left);
                    std.mem.writeInt(u16, stored[1..3], len, .little);
                    std.mem.writeInt(u16, stored[3..5], ~len, .little);
                    try chunk.write(&stored);
                }
                const take: usize = @intCast(@min(block_left, piece.len - at));
                try chunk.write(piece[at..][0..take]);
                adler.update(piece[at..][0..take]);
                at += take;
                block_left -= take;
                left -= take;
            }
        }
    }
    assert(left == 0);
    var check: [4]u8 = undefined;
    std.mem.writeInt(u32, &check, adler.adler, .big);
    try chunk.write(&check);
    try chunk.end();
    try chunk_write(writer, "IEND", "");
}

/// One chunk being written: its CRC-32 covers the type and the data.
const Chunk = struct {
    writer: *std.Io.Writer,
    crc: std.hash.Crc32,
    left: u32,

    fn begin(writer: *std.Io.Writer, kind: *const [4]u8, len: u32) !Chunk {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, len, .big);
        try writer.writeAll(&length);
        var chunk: Chunk = .{ .writer = writer, .crc = .init(), .left = len + 4 };
        try chunk.write(kind);
        return chunk;
    }

    fn write(self: *Chunk, bytes: []const u8) !void {
        assert(bytes.len <= self.left);
        self.crc.update(bytes);
        self.left -= @intCast(bytes.len);
        try self.writer.writeAll(bytes);
    }

    fn end(self: *Chunk) !void {
        assert(self.left == 0);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, self.crc.final(), .big);
        try self.writer.writeAll(&crc);
    }
};

fn chunk_write(writer: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var chunk: Chunk = try .begin(writer, kind, @intCast(data.len));
    try chunk.write(data);
    try chunk.end();
}

pub const Error = error{ NotPng, Unsupported, Truncated, BadChecksum, TooLarge };

/// Reads a PNG in `write`'s form (section 3) into `out`, which must hold its pixels.
/// Any other PNG (compressed blocks, another color type, filters) is `error.Unsupported`.
pub fn read_stored(bytes: []const u8, out: []u8) Error!Image {
    const fixed = signature.len + 8 + 13 + 4 + 8;
    if (bytes.len < fixed) return error.NotPng;
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return error.NotPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.NotPng;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (!std.mem.eql(u8, bytes[24..29], &.{ 8, 2, 0, 0, 0 })) return error.Unsupported;
    if (width == 0 or height == 0 or width > bench.width_max) return error.Unsupported;
    const pixels: u64 = @as(u64, width) * height * 3;
    if (pixels > out.len) return error.TooLarge;
    const idat = 33;
    const zlib_len = std.mem.readInt(u32, bytes[idat..][0..4], .big);
    if (!std.mem.eql(u8, bytes[idat + 4 ..][0..4], "IDAT")) return error.Unsupported;
    if (bytes.len < idat + 8 + @as(u64, zlib_len) + 4) return error.Truncated;
    const zlib = bytes[idat + 8 ..][0..zlib_len];
    const crc = std.mem.readInt(u32, bytes[idat + 8 + zlib_len ..][0..4], .big);
    if (std.hash.Crc32.hash(bytes[idat + 4 ..][0 .. 4 + zlib_len]) != crc) {
        return error.BadChecksum;
    }
    if (zlib.len < 6 or zlib[0] != 0x78) return error.Unsupported;
    const raw_len = raw_len_of(width, height);
    var cursor: usize = 2;
    var raw_at: u64 = 0;
    var adler: std.hash.Adler32 = .{};
    var final = false;
    const blocks_max = raw_len / block_max + 1;
    var blocks: u64 = 0;
    while (!final) : (blocks += 1) {
        if (blocks == blocks_max) return error.Unsupported;
        if (zlib.len - cursor < 5) return error.Truncated;
        if (zlib[cursor] & 0xFE != 0) return error.Unsupported;
        final = zlib[cursor] == 1;
        const len = std.mem.readInt(u16, zlib[cursor + 1 ..][0..2], .little);
        const nlen = std.mem.readInt(u16, zlib[cursor + 3 ..][0..2], .little);
        if (nlen != ~len) return error.BadChecksum;
        cursor += 5;
        if (zlib.len - cursor < len or raw_at + len > raw_len) return error.Truncated;
        const data = zlib[cursor..][0..len];
        adler.update(data);
        for (data, 0..) |byte, offset| {
            const at = raw_at + offset;
            const row = at / (1 + @as(u64, width) * 3);
            const column = at % (1 + @as(u64, width) * 3);
            if (column == 0) {
                if (byte != 0) return error.Unsupported;
                continue;
            }
            out[@intCast(row * width * 3 + column - 1)] = byte;
        }
        raw_at += len;
        cursor += len;
    }
    if (raw_at != raw_len) return error.Truncated;
    if (zlib.len - cursor < 4) return error.Truncated;
    if (std.mem.readInt(u32, zlib[cursor..][0..4], .big) != adler.adler) return error.BadChecksum;
    const image: Image = .{ .width = width, .height = height, .pixels = out[0..@intCast(pixels)] };
    assert(image.pixels.len == pixels);
    return image;
}

const testing = std.testing;

const test_rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30, 40, 50, 60, 70, 80, 90 };

// Locks the PNG layout of a 3 x 2 image: signature, IHDR (CRC 0x1216F14D), one IDAT of 31
// bytes (zlib header 78 01, one final stored block of 20 bytes, Adler-32 0x335904C0, CRC
// 0xC5321E86), and IEND (CRC 0xAE426082); 88 bytes in all, which `size` predicts, and the
// file reads back to the same pixels. Values from Python's zlib.
test "png writes stored blocks with the known checksums and reads back" {
    var bytes: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try write(&writer, 3, 2, &test_rgb);
    const file = writer.buffered();
    try testing.expectEqual(size(3, 2), file.len);
    try testing.expectEqual(@as(usize, 88), file.len);
    try testing.expectEqualSlices(u8, &signature, file[0..8]);
    try testing.expectEqual(@as(u32, 0x1216F14D), std.mem.readInt(u32, file[29..33], .big));
    try testing.expectEqual(@as(u32, 31), std.mem.readInt(u32, file[33..37], .big));
    try testing.expectEqualStrings("IDAT", file[37..41]);
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x01, 0x01, 20, 0, 0xEB, 0xFF }, file[41..48]);
    try testing.expectEqual(@as(u32, 0x335904C0), std.mem.readInt(u32, file[68..72], .big));
    try testing.expectEqual(@as(u32, 0xC5321E86), std.mem.readInt(u32, file[72..76], .big));
    try testing.expectEqual(@as(u32, 0xAE426082), std.mem.readInt(u32, file[84..88], .big));
    var pixels: [18]u8 = undefined;
    const image = try read_stored(file, &pixels);
    try testing.expectEqual(@as(u32, 3), image.width);
    try testing.expectEqualSlices(u8, &test_rgb, image.pixels);
    var broken = bytes;
    broken[50] +%= 1;
    try testing.expectError(error.BadChecksum, read_stored(broken[0..file.len], &pixels));
}

// Locks block splitting: 200 x 120 RGB is 72,120 filtered bytes, two stored blocks (65,535
// and 6,585), and the image reads back.
test "png splits rows across stored blocks" {
    const static = struct {
        var rgb: [200 * 120 * 3]u8 = undefined;
        var file: [80_000]u8 = undefined;
        var back: [200 * 120 * 3]u8 = undefined;
    };
    for (&static.rgb, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var writer: std.Io.Writer = .fixed(&static.file);
    try write(&writer, 200, 120, &static.rgb);
    try testing.expectEqual(size(200, 120), writer.buffered().len);
    try testing.expectEqual(@as(u64, 72_120), raw_len_of(200, 120));
    const image = try read_stored(writer.buffered(), &static.back);
    try testing.expectEqualSlices(u8, &static.rgb, image.pixels);
}

// Locks the size the reference quotes: 1920 x 1080 is 1080 rows of 1 + 5,760 bytes (6,221,880),
// 95 stored blocks, and 6,222,418 bytes in all, 6.2 MB.
test "png size of a 1080p frame" {
    try testing.expectEqual(@as(u64, 6_221_880), raw_len_of(1920, 1080));
    try testing.expectEqual(@as(u64, 6_222_418), size(1920, 1080));
}

// Locks the old names: `bench.png_write`, `png_size`, and `png_read_stored` are `write`, `size`,
// and `read_stored`, so a file written through one reads back through the other.
test "bench keeps the png names as aliases" {
    try testing.expect(bench.png_write == write);
    try testing.expect(bench.png_size == size);
    try testing.expect(bench.png_read_stored == read_stored);
    var bytes: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try bench.png_write(&writer, 3, 2, &test_rgb);
    var pixels: [18]u8 = undefined;
    const image = try read_stored(writer.buffered(), &pixels);
    try testing.expectEqualSlices(u8, &test_rgb, image.pixels);
}

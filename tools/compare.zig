//! `zig build compare -- a b [--crop x y w h] [--diff d.png] [--png out.png]`: how two frame
//! images differ (`bench.compare`), and PNG pictures of them.
//!
//! An image is a PPM dump (`--dump`) or a PNG the regress host wrote (`bench.png_read_stored`,
//! so only that uncompressed form). Prints the differing pixel count, the maximum channel
//! difference, the bounding box, and the pixels per range of difference (1, 2, 3-8, 9-32,
//! 33-255). `--crop x y w h` compares only that rect of both images, so a 1280 x 720 regress
//! frame and a larger window dump compare over the part they share; the box is then relative
//! to the crop. `--diff d.png` writes the diff picture (`bench.diff_rgb`: equal pixels dim
//! grey, differing ones red by their difference), `--png out.png` the first image, cropped.
//! With one image only `--png` applies: a crop to PNG. Exits 0 when the images are identical
//! (or with one image, when the PNG was written), 1 when they differ, and 2 on a usage error.
//! Linux only: files are mapped, so nothing is allocated through an allocator.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const bench = @import("patchwork").bench;

const Options = struct {
    paths: [2]?[:0]const u8,
    crop: ?[4]u32,
    diff: ?[:0]const u8,
    png: ?[:0]const u8,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    const options = parse(&args) orelse return usage();
    const a = try load(options.paths[0].?);
    const crop = options.crop orelse [4]u32{ 0, 0, a.width, a.height };
    const view_a = cropped(a, crop) orelse return outside(a, crop);
    if (options.png) |path| try write_png(path, view_a);
    const path_b = options.paths[1] orelse {
        if (options.png == null) return usage();
        return 0;
    };
    const b = try load(path_b);
    if (options.crop == null and (a.width != b.width or a.height != b.height)) {
        std.debug.print("size differs: {d}x{d} and {d}x{d}\n", .{
            a.width, a.height, b.width, b.height,
        });
        return 1;
    }
    const view_b = cropped(b, crop) orelse return outside(b, crop);
    const diff = bench.compare(view_a, view_b) catch unreachable;
    report(&diff);
    if (options.diff) |path| {
        const out = try anonymous(view_a.pixels.len);
        bench.diff_rgb(view_a.pixels, view_b.pixels, out);
        try write_png(path, .{ .width = view_a.width, .height = view_a.height, .pixels = out });
    }
    return if (diff.differing == 0) 0 else 1;
}

fn parse(args: *std.process.Args.Iterator) ?Options {
    var options: Options = .{ .paths = .{ null, null }, .crop = null, .diff = null, .png = null };
    var count: u32 = 0;
    var guard: u32 = 0;
    while (args.next()) |arg| : (guard += 1) {
        if (guard == 16) return null;
        if (std.mem.eql(u8, arg, "--crop")) {
            var rect: [4]u32 = undefined;
            for (&rect) |*value| {
                const text = args.next() orelse return null;
                value.* = std.fmt.parseInt(u32, text, 10) catch return null;
            }
            if (rect[2] == 0 or rect[3] == 0) return null;
            options.crop = rect;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            options.diff = args.next() orelse return null;
        } else if (std.mem.eql(u8, arg, "--png")) {
            options.png = args.next() orelse return null;
        } else {
            if (count == 2 or std.mem.startsWith(u8, arg, "--")) return null;
            options.paths[count] = arg;
            count += 1;
        }
    }
    if (count == 0) return null;
    if (options.diff != null and count != 2) return null;
    return options;
}

fn usage() u8 {
    std.debug.print("usage: zig build compare -- a.ppm|a.png [b.ppm|b.png] [--crop x y w h] " ++
        "[--diff d.png] [--png out.png]\n", .{});
    return 2;
}

fn outside(image: bench.Image, crop: [4]u32) u8 {
    std.debug.print("crop {d} {d} {d} {d} is outside the {d}x{d} image\n", .{
        crop[0], crop[1], crop[2], crop[3], image.width, image.height,
    });
    return 2;
}

fn report(diff: *const bench.Diff) void {
    assert(diff.pixels > 0);
    const percent = @as(f64, @floatFromInt(diff.differing)) * 100 /
        @as(f64, @floatFromInt(diff.pixels));
    std.debug.print("{d} pixels, {d} differ ({d:.4}%), max channel difference {d}\n", .{
        diff.pixels, diff.differing, percent, diff.max,
    });
    if (diff.differing == 0) return;
    std.debug.print("box x {d}..{d} y {d}..{d}\npixels by difference:", .{
        diff.box[0], diff.box[2], diff.box[1], diff.box[3],
    });
    // Ranges that separate rounding noise (1, 2) from small and large real differences.
    const ranges = [_][2]u32{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 8 }, .{ 9, 32 }, .{ 33, 255 } };
    for (ranges) |range| {
        var count: u64 = 0;
        for (diff.histogram[range[0] .. range[1] + 1]) |bucket| count += bucket;
        if (range[0] == range[1]) {
            std.debug.print(" {d}: {d}", .{ range[0], count });
        } else {
            std.debug.print(" {d}-{d}: {d}", .{ range[0], range[1], count });
        }
    }
    std.debug.print("\n", .{});
}

/// The image at `path`: a PPM parsed in place, or a stored PNG decoded into new pages.
fn load(path: [:0]const u8) !bench.Image {
    const bytes = try map_file(path);
    if (bytes.len >= 24 and bytes[0] == 0x89) {
        const width = std.mem.readInt(u32, bytes[16..20], .big);
        const height = std.mem.readInt(u32, bytes[20..24], .big);
        if (width == 0 or height == 0 or width > bench.width_max) return error.BadPng;
        const out = try anonymous(@as(usize, width) * height * 3);
        return bench.png_read_stored(bytes, out) catch |err| {
            std.debug.print("{s}: {s} (only the regress host's uncompressed PNGs are read)\n", .{
                path, @errorName(err),
            });
            return err;
        };
    }
    return bench.ppm_parse(bytes);
}

/// `rect` of `image` copied into new pages, or null when it does not fit inside. The whole
/// image is returned as it is.
fn cropped(image: bench.Image, rect: [4]u32) ?bench.Image {
    if (@as(u64, rect[0]) + rect[2] > image.width) return null;
    if (@as(u64, rect[1]) + rect[3] > image.height) return null;
    if (rect[0] == 0 and rect[1] == 0 and rect[2] == image.width and rect[3] == image.height) {
        return image;
    }
    const out = anonymous(@as(usize, rect[2]) * rect[3] * 3) catch return null;
    const row_bytes = @as(usize, rect[2]) * 3;
    for (0..rect[3]) |row| {
        const from = ((rect[1] + row) * image.width + rect[0]) * 3;
        @memcpy(out[row * row_bytes ..][0..row_bytes], image.pixels[from..][0..row_bytes]);
    }
    return .{ .width = rect[2], .height = rect[3], .pixels = out };
}

fn write_png(path: [:0]const u8, image: bench.Image) !void {
    const size: usize = @intCast(bench.png_size(image.width, image.height));
    const bytes = try anonymous(size);
    var writer: std.Io.Writer = .fixed(bytes);
    try bench.png_write(&writer, image.width, image.height, image.pixels);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("cannot write {s}\n", .{path});
        return error.OpenFailed;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const png = writer.buffered();
    var done: usize = 0;
    var tries: u32 = 0;
    while (done < png.len and tries < 4096) : (tries += 1) {
        const rc = linux.write(fd, png[done..].ptr, png.len - done);
        if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
        done += rc;
    }
    if (done != png.len) return error.WriteFailed;
    std.debug.print("wrote {s} ({d}x{d})\n", .{ path, image.width, image.height });
}

/// `len` zeroed bytes of new private pages, for the life of the process.
fn anonymous(len: usize) ![]u8 {
    assert(len > 0);
    const mapped = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
    }, -1, 0);
    if (linux.errno(mapped) != .SUCCESS) return error.MapFailed;
    const bytes: [*]u8 = @ptrFromInt(mapped);
    return bytes[0..len];
}

/// Maps `path` read-only for the life of the process.
fn map_file(path: [:0]const u8) ![]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0) return error.EmptyFile;
    const mapped = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(mapped) != .SUCCESS) return error.MapFailed;
    const bytes: [*]const u8 = @ptrFromInt(mapped);
    assert(size > 0);
    return bytes[0..size];
}

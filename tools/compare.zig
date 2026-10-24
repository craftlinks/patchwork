//! `zig build compare -- a.ppm b.ppm`: how two frame dumps differ (`bench.compare`).
//!
//! Prints the differing pixel count, the maximum channel difference, the bounding box, and the
//! pixels per range of difference (1, 2, 3-8, 9-32, 33-255). Exits 0 when the images are
//! identical and 1 otherwise, so a script can gate on it. Linux only: the files are mapped
//! read-only, so nothing is allocated.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const bench = @import("patchwork").bench;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    const path_a = args.next() orelse return usage();
    const path_b = args.next() orelse return usage();
    if (args.next() != null) return usage();
    const a = try bench.ppm_parse(try map_file(path_a));
    const b = try bench.ppm_parse(try map_file(path_b));
    const diff = bench.compare(a, b) catch {
        std.debug.print("size differs: {d}x{d} and {d}x{d}\n", .{
            a.width, a.height, b.width, b.height,
        });
        return 1;
    };
    report(&diff);
    return if (diff.differing == 0) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: zig build compare -- a.ppm b.ppm\n", .{});
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

//! `subset <in.ttf> <out.ttf> <ranges>`: writes the subset of a TrueType face covering
//! `<ranges>` (hex, `20-7E,A0-17F,...`) for the build's `patchwork_fonts` module
//! (`src/text/subset.zig`, `build.zig`).
//!
//! Silent on success, because the build counts a run step's stderr as a failure; errors name
//! the input. Linux only, like `tools/compare.zig`: the input is mapped read-only and the
//! output written from a static buffer, so nothing is allocated.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const subset = @import("subset");

/// Most ranges on the command line.
const range_cap: u32 = 64;
/// Largest output: a subset of a face is never larger than the face, and the shipped faces
/// are under 1 MiB.
const out_cap: u32 = 4 * 1024 * 1024;

var scratch: subset.Scratch = undefined;
var output: [out_cap]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    const path_in = args.next() orelse return usage();
    const path_out = args.next() orelse return usage();
    const spec = args.next() orelse return usage();
    if (args.next() != null) return usage();
    var ranges: [range_cap]subset.Range = undefined;
    const count = parse_ranges(spec, &ranges) catch {
        std.debug.print("subset: bad ranges '{s}'\n", .{spec});
        return 2;
    };
    const input = try map_file(path_in);
    const summary = subset.subset(&scratch, input, ranges[0..count], &output) catch |err| {
        if (err == error.NoGlyf) {
            std.debug.print(
                "subset: {s}: no glyf table; CFF outlines are not supported, " ++
                    "use a TrueType (glyf) face\n",
                .{path_in},
            );
            return 1;
        }
        std.debug.print("subset: {s}: {s}\n", .{ path_in, @errorName(err) });
        return 1;
    };
    try write_file(path_out, output[0..summary.bytes]);
    assert(summary.glyphs >= 1);
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: subset in.ttf out.ttf 20-7E,A0-FF\n", .{});
    return 2;
}

/// Parses `spec` (comma-separated `lo-hi` or `cp`, hex) into `out`.
fn parse_ranges(spec: []const u8, out: *[range_cap]subset.Range) !u32 {
    var count: u32 = 0;
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |part| {
        if (count == range_cap) return error.TooMany;
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const low_text = if (dash) |at| part[0..at] else part;
        const high_text = if (dash) |at| part[at + 1 ..] else part;
        const low = try std.fmt.parseInt(u21, low_text, 16);
        const high = try std.fmt.parseInt(u21, high_text, 16);
        if (low > high) return error.Reversed;
        out[count] = .{ low, high };
        count += 1;
    }
    if (count == 0) return error.Empty;
    return count;
}

/// Maps `path` read-only for the life of the process.
fn map_file(path: [:0]const u8) ![]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("subset: cannot open {s}\n", .{path});
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

/// Creates or truncates `path` and writes `bytes` to it.
fn write_file(path: [:0]const u8, bytes: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("subset: cannot create {s}\n", .{path});
        return error.CreateFailed;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        assert(result > 0);
        written += result;
    }
    assert(written == bytes.len);
}

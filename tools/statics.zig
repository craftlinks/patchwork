//! `statics EXE`: how many times an app's native executable holds its App, its UI context, and its
//! renderer, and how much writable static data it has (step 82).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Counts
//! The window host and the offscreen host share one App, one context, and one renderer
//! (`host/statics.zig`). The tool reads the executable's ELF symbol table and counts the data
//! symbols (`STT_OBJECT`) whose size is `@sizeOf` of each of the three, from the `app` and
//! `patchwork` modules `build.zig` imports, so the tool and the executable agree on the types.
//! Each count must be 1. A host that declares its own App again makes the App's count 2. The
//! count names no symbol, so a rename cannot hide a second copy. It needs sizes no other static
//! has, which `test/statics/app.zig` gives the App (1 048 580 bytes); that app's context
//! (1 373 600 bytes in Debug, 1 373 504 in ReleaseFast) and renderer (272 264) have sizes of
//! their own too.
//!
//! ## 2. What It States
//! The writable static data: the sum of the sizes of the sections that are both allocated and
//! writable (`.data`, `.bss`, `.tdata`, `.tbss`, `.got`, ...). A Debug build of the self-hosted
//! backend puts an `undefined` static in `.data`, an LLVM build in `.bss`, so no one section is
//! the measure. It is printed, not judged: it follows every buffer of the hosts.
//!
//! ## 3. Output
//! One line on stderr, `statics: App 1048580 bytes x1, context 1373600 bytes x1, renderer 272264
//! bytes x1; writable static data 49904810 bytes`, then `held once`, or `not held once:` and the
//! names whose count is not 1.
//! Exit 0 when every count is 1, 1 when one is not, 2 for a file it cannot read.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: the file is mapped read-only and only its headers and symbols are read.
//! - Every loop is bounded by a count from the file, checked against the file's size first.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const patchwork = @import("patchwork");
const app = @import("app");

const Context = patchwork.app.Context(app.App);
const Renderer = patchwork.renderer.Renderer(Context.DrawContext);

/// The ELF64 section header, as the file holds it (System V gABI).
const SectionHeader = extern struct {
    name: u32,
    type: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

/// The ELF64 symbol, as the file holds it.
const Symbol = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,
};

const flag_write: u64 = 0x1;
const flag_alloc: u64 = 0x2;
const type_symtab: u32 = 2;
const symbol_object: u8 = 1;
/// Offsets in the ELF64 file header.
const shoff_at = 0x28;
const shentsize_at = 0x3A;
const shnum_at = 0x3C;

comptime {
    assert(@sizeOf(SectionHeader) == 64);
    assert(@sizeOf(Symbol) == 24);
}

/// What `measure` found in one executable.
pub const Measure = struct {
    /// Sum of the allocated, writable sections (module guide, section 2).
    writable: u64,
    /// Data symbols of each size asked, in the order asked.
    counts: [3]u32,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: statics EXE\n", .{});
        return 2;
    };
    const bytes = map_file(path) catch return 2;
    const sizes = [3]u64{ @sizeOf(app.App), @sizeOf(Context), @sizeOf(Renderer) };
    const found = measure(bytes, sizes) orelse {
        std.debug.print("statics: {s} is not an ELF64 executable with a symbol table\n", .{path});
        return 2;
    };
    const names = [3][]const u8{ "App", "context", "renderer" };
    std.debug.print("statics: ", .{});
    for (names, sizes, found.counts, 0..) |name, size, count, index| {
        const separator = if (index == 0) "" else ", ";
        std.debug.print("{s}{s} {d} bytes x{d}", .{ separator, name, size, count });
    }
    std.debug.print("; writable static data {d} bytes\n", .{found.writable});
    var once = true;
    for (names, found.counts) |name, count| {
        if (count == 1) continue;
        if (once) std.debug.print("not held once:", .{});
        std.debug.print(" {s}", .{name});
        once = false;
    }
    if (once) {
        std.debug.print("held once\n", .{});
        return 0;
    }
    std.debug.print("\n", .{});
    return 1;
}

/// The writable static data and the count of data symbols of each of `sizes`, or null for a file
/// that is not ELF64 little-endian, has no symbol table, or has a table past its end.
pub fn measure(bytes: []const u8, sizes: [3]u64) ?Measure {
    if (bytes.len < 64) return null;
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return null;
    if (bytes[4] != 2 or bytes[5] != 1) return null;
    const shoff = std.mem.readInt(u64, bytes[shoff_at..][0..8], .little);
    const shentsize = std.mem.readInt(u16, bytes[shentsize_at..][0..2], .little);
    const shnum = std.mem.readInt(u16, bytes[shnum_at..][0..2], .little);
    if (shentsize != @sizeOf(SectionHeader)) return null;
    if (shoff > bytes.len or @as(u64, shnum) * shentsize > bytes.len - shoff) return null;
    var result: Measure = .{ .writable = 0, .counts = @splat(0) };
    var symtabs: u32 = 0;
    for (0..shnum) |index| {
        const at: usize = @intCast(shoff + index * shentsize);
        const header = std.mem.bytesToValue(SectionHeader, bytes[at..][0..@sizeOf(SectionHeader)]);
        const wanted = flag_write | flag_alloc;
        if (header.flags & wanted == wanted) result.writable += header.size;
        if (header.type != type_symtab) continue;
        if (header.offset > bytes.len or header.size > bytes.len - header.offset) return null;
        symtabs += 1;
        const count = header.size / @sizeOf(Symbol);
        for (0..count) |symbol_index| {
            const from: usize = @intCast(header.offset + symbol_index * @sizeOf(Symbol));
            const symbol = std.mem.bytesToValue(Symbol, bytes[from..][0..@sizeOf(Symbol)]);
            if (symbol.info & 0xf != symbol_object) continue;
            for (sizes, &result.counts) |size, *counted| {
                if (symbol.size == size) counted.* += 1;
            }
        }
    }
    if (symtabs == 0) return null;
    return result;
}

fn map_file(path: [:0]const u8) ![]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("statics: cannot open {s}\n", .{path});
        return error.OpenFailed;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0) return error.EmptyFile;
    const mapped = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(mapped) != .SUCCESS) return error.MapFailed;
    const bytes: [*]const u8 = @ptrFromInt(mapped);
    return bytes[0..size];
}

const fixture_bytes = 64 + 5 * 64 + 4 * 24;

/// Four sections and a symbol table. Allocated and writable: 8 and 4096 bytes; read-only: 100;
/// writable, not allocated: 50. Symbols: two objects of 4096 bytes, one of 8, and a function of
/// 4096 bytes, which does not count.
fn fixture(out: *[fixture_bytes]u8) []const u8 {
    @memset(out, 0);
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 2;
    out[5] = 1;
    std.mem.writeInt(u64, out[shoff_at..][0..8], 64, .little);
    std.mem.writeInt(u16, out[shentsize_at..][0..2], 64, .little);
    std.mem.writeInt(u16, out[shnum_at..][0..2], 5, .little);
    const symtab_at = 64 + 5 * 64;
    const sections = [_]struct { type: u32, flags: u64, offset: u64, size: u64 }{
        .{ .type = 1, .flags = flag_write | flag_alloc, .offset = 0, .size = 8 },
        .{ .type = 1, .flags = flag_alloc, .offset = 0, .size = 100 },
        .{ .type = 8, .flags = flag_write | flag_alloc, .offset = 0, .size = 4096 },
        .{ .type = 1, .flags = flag_write, .offset = 0, .size = 50 },
        .{ .type = type_symtab, .flags = 0, .offset = symtab_at, .size = 4 * 24 },
    };
    for (sections, 0..) |section, index| {
        const header: SectionHeader = .{
            .name = 0,
            .type = section.type,
            .flags = section.flags,
            .addr = 0,
            .offset = section.offset,
            .size = section.size,
            .link = 0,
            .info = 0,
            .addralign = 8,
            .entsize = if (section.type == type_symtab) 24 else 0,
        };
        @memcpy(out[64 + index * 64 ..][0..64], std.mem.asBytes(&header));
    }
    const symbols = [_]struct { info: u8, size: u64 }{
        .{ .info = symbol_object, .size = 4096 },
        .{ .info = symbol_object, .size = 8 },
        .{ .info = 2, .size = 4096 },
        .{ .info = 0x10 | symbol_object, .size = 4096 },
    };
    for (symbols, 0..) |entry, index| {
        const symbol: Symbol = .{
            .name = 0,
            .info = entry.info,
            .other = 0,
            .shndx = 3,
            .value = 0,
            .size = entry.size,
        };
        @memcpy(out[symtab_at + index * 24 ..][0..24], std.mem.asBytes(&symbol));
    }
    return out;
}

// Locks the measure: only sections both allocated and writable count, 8 + 4096 = 4104; objects
// of 4096 bytes, local and global, are 2, the function is not counted, and no symbol is 12 bytes.
test "the measure sums writable sections and counts objects by size" {
    var buffer: [fixture_bytes]u8 = undefined;
    const bytes = fixture(&buffer);
    const found = measure(bytes, .{ 4096, 8, 12 }).?;
    try std.testing.expectEqual(@as(u64, 4104), found.writable);
    try std.testing.expectEqual([3]u32{ 2, 1, 0 }, found.counts);
}

// Locks the refusals: a section table past the end of the file, and a file that is not ELF.
test "a short or foreign file is refused" {
    var buffer: [fixture_bytes]u8 = undefined;
    const bytes = fixture(&buffer);
    try std.testing.expectEqual(@as(?Measure, null), measure(bytes[0 .. 64 + 4 * 64], .{ 1, 2, 3 }));
    const text = "not an executable at all, but long enough to read a header from it.";
    try std.testing.expectEqual(@as(?Measure, null), measure(text, .{ 1, 2, 3 }));
}

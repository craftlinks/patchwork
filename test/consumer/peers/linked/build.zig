//! A peer that links a system library natively and nothing on wasm. Linking needs a known target,
//! so this module cannot be target-less, and a consumer builds it once per target.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = target.result.cpu.arch != .wasm32;
    const module = b.addModule("linked", .{
        .root_source_file = b.path("linked.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = native,
    });
    if (native) module.linkSystemLibrary("xkbcommon", .{});
}

//! A peer with no system library: one target-less module, which one `imports` entry gives both
//! of the consumer's targets.

const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("pure", .{ .root_source_file = b.path("pure.zig") });
}

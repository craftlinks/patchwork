const std = @import("std");
const patchwork = @import("patchwork");

pub fn main() !void {
    std.debug.print("Hello from Patchwork!\n", .{});
    const sum = patchwork.add(20, 22);
    std.debug.print("20 + 22 = {d}\n", .{sum});
}

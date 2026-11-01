//! A package outside Patchwork's build graph, which sees it only as a consumer does: through
//! `addApp`, `addTool`, and the `.path` dependency in `build.zig.zon`. `zig build test-consumer` in
//! the repository's root drives every step here (`docs/reference.md`, Use Patchwork From Another
//! Project).

const std = @import("std");
const patchwork = @import("patchwork");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("patchwork", .{ .target = target, .optimize = optimize });
    const pure = b.dependency("pure", .{}).module("pure");
    const linked = b.dependency("linked", .{ .target = target }).module("linked");
    const wasm = b.resolveTargetQuery(patchwork.wasm_query);
    const linked_wasm = b.dependency("linked", .{ .target = wasm }).module("linked");
    const steps = patchwork.addApp(b, dep.builder, .{
        .name = "consumer",
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pure", .module = pure }},
        .native_imports = &.{.{ .name = "linked", .module = linked }},
        .wasm_imports = &.{.{ .name = "linked", .module = linked_wasm }},
    });
    b.getInstallStep().dependOn(steps.install);
    const tool = patchwork.addTool(b, .{
        .name = "consumer-tool",
        .root_source_file = b.path("tool.zig"),
        .target = target,
        .optimize = optimize,
        .app = steps,
        .imports = &.{.{ .name = "linked", .module = linked }},
    });
    b.installArtifact(tool);
    b.step("run", "Run natively").dependOn(steps.run);
    b.step("wasm", "Build for the browser").dependOn(steps.wasm);
    b.step("serve", "Serve on localhost").dependOn(steps.serve);
    b.step("regress", "Render the scenarios against test/golden").dependOn(steps.regress);
    b.step("test", "Run the app's tests").dependOn(steps.tests);
}

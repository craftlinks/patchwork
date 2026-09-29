const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wgpu_lib_dir = b.option(
        []const u8,
        "wgpu-lib-dir",
        "Directory that contains libwgpu_native.so (wgpu-native v29.0.1.1)",
    );

    const patchwork = b.addModule("patchwork", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    add_native(b, target, optimize, wgpu_lib_dir);
    add_tests(b, patchwork);
    const wasm = add_wasm(b, optimize);
    add_serve(b, target, optimize, wasm);
}

fn add_native(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wgpu_lib_dir: ?[]const u8,
) void {
    const dir = wgpu_lib_dir orelse {
        const missing = b.addFail(
            "native build requires -Dwgpu-lib-dir= pointing at the directory that contains libwgpu_native.so",
        );
        b.getInstallStep().dependOn(&missing.step);
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&missing.step);
        return;
    };

    const exe = b.addExecutable(.{
        .name = "patchwork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addLibraryPath(.{ .cwd_relative = dir });
    exe.root_module.addRPath(.{ .cwd_relative = dir });
    exe.root_module.linkSystemLibrary("wayland-client", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .yes,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    exe.root_module.linkSystemLibrary("wgpu_native", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn add_tests(b: *std.Build, patchwork: *std.Build.Module) void {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = patchwork.resolved_target,
            .optimize = patchwork.optimize.?,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn add_wasm(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const wasm = b.addExecutable(.{
        .name = "patchwork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_exports.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // shell.js reads the shader and instance bytes out of the wasm linear memory.
    wasm.export_memory = true;
    const wasm_step = b.step("wasm", "Build the browser module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
    return wasm;
}

fn add_serve(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wasm: *std.Build.Step.Compile,
) void {
    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const serve_run = b.addRunArtifact(serve_exe);
    serve_run.step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
    serve_run.addFileArg(b.path("web/index.html"));
    serve_run.addFileArg(b.path("web/shell.js"));
    serve_run.addFileArg(wasm.getEmittedBin());
    const serve_step = b.step("serve", "Serve the browser surface on localhost");
    serve_step.dependOn(&serve_run.step);
}

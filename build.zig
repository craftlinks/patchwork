//! Build Graph Configuration and Multi-Target Orchestration.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Build Pipeline Architecture & Step Matrix
//! Patchwork compiles to two distinct platform targets from a single Zig codebase:
//! - `native` (`zig build` / `zig build run`):
//!   Compiles `src/main.zig` for the host platform (Linux x86_64), linking against
//!   `libwayland-client.so` and `libwgpu_native.so` (v29.0.1.1 C ABI).
//!   Automatically resolves `libwgpu_native.so` via the `wgpu_native` package dependency
//!   declared in `build.zig.zon` and cached by Zig's package manager. An optional
//!   `-Dwgpu-lib-dir=` override allows linking against a custom directory if desired.
//! - `wasm` (`zig build wasm`):
//!   Compiles `src/web_exports.zig` for `wasm32-freestanding`. Zero libc, zero OS syscalls.
//!   Sets `export_memory = true` so linear memory can be inspected zero-copy by JavaScript.
//! - `test` (`zig build test`):
//!   Compiles pure logic tests in `src/root.zig` (`draw.zig` and `frame.zig`).
//!   Requires NO GPU drivers, NO Wayland display, and NO external dynamic libraries.
//! - `serve` (`zig build serve`):
//!   Compiles and launches the lightweight static HTTP server in `src/serve.zig` to serve
//!   `index.html`, `shell.js`, and `patchwork.wasm` on `http://127.0.0.1:8080/`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wgpu_lib_dir = b.option(
        []const u8,
        "wgpu-lib-dir",
        "Override directory containing libwgpu_native.so (defaults to wgpu_native package in build.zig.zon)",
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

/// Configures native Wayland + WebGPU compilation for the host executable.
/// - Resolves `libwgpu_native.so` and its dynamic runtime linker path (RPATH) from the
///   `wgpu_native` dependency package declared in `build.zig.zon`, or from the user-provided
///   `wgpu_lib_dir` override when specified via `-Dwgpu-lib-dir=`.
/// - Dynamically links `libwayland-client.so` and `libwgpu_native.so`.
fn add_native(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wgpu_lib_dir: ?[]const u8,
) void {
    const lib_path: std.Build.LazyPath = if (wgpu_lib_dir) |dir|
        .{ .cwd_relative = dir }
    else
        b.dependency("wgpu_native", .{}).path("lib");

    const exe = b.addExecutable(.{
        .name = "patchwork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addLibraryPath(lib_path);
    exe.root_module.addRPath(lib_path);
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

/// Configures compilation of the freestanding WebAssembly browser module.
/// - Targets `wasm32-freestanding`: No OS, no libc, no runtime overhead.
/// - `entry = .disabled`: Freestanding library without a `main()` function.
/// - `rdynamic = true`: Preserves exported symbols (`start`, `resize`, `tick`, etc.).
/// - `export_memory = true`: Exposes `WebAssembly.Memory` as `wasm.memory.buffer`
///   so `web/shell.js` can read WGSL shader code, vertex layouts, and instance arrays
///   directly without data copies.
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

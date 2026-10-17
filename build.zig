//! Build graph and the `addApp` helper another project's `build.zig` calls.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One App File, Three Targets
//! An app is one Zig file that declares `pub const App` (the contract in `src/app.zig`).
//! `addApp` compiles that file twice, once for the host and once for `wasm32-freestanding`,
//! each time next to one library module, and links it to a generated host root:
//!
//! ```text
//!   app file (consumer)          src/root.zig  (module "patchwork", one per target)
//!         |  import "patchwork"        |
//!         v                            v
//!   module "app" -----------> src/host/native_main.zig  -> executable   (run)
//!                       \---> src/host/web_main.zig     -> .wasm        (wasm, serve)
//!   module "app" ------------> test runner                              (tests)
//! ```
//!
//! The host roots are plain files in this repo. They contain no app code, only
//! `linux_window.run(app.App)` and `export_app(app.App)`.
//!
//! ## 2. Why Every Path Comes From the Patchwork Builder
//! `addApp(b, patchwork_builder, options)` takes two builders. `b` is the consumer's. The
//! consumer's `build.zig.zon` lists only `patchwork`. `patchwork_builder` is that
//! dependency's builder, so `src/host/*`, `web/*`, and the `wgpu_native` package resolve
//! against Patchwork's own tree. A `b.path` call here would look for `src/host` in the
//! consumer's tree. Inside this repo the two builders are the same object.
//!
//! ## 3. One Library Module Per Target
//! The app module and the host root must import the same `patchwork` module instance for a
//! target, or the types in the contract would be distinct. `addApp` creates one for the
//! native target and one for wasm, and gives each to both of its users.
//!
//! ## 4. Steps
//! - `run` builds and runs the native executable (Wayland and wgpu-native).
//! - `wasm` installs `<name>.wasm` (no libc, no OS, `export_memory`, `rdynamic`).
//! - `serve` serves `index.html`, `shell.js`, and the wasm on `http://127.0.0.1:8080/`.
//! - `tests` runs the app's own tests. They need no GPU and no display.
//! - `zig build test` in this repo adds the library tests. `zig build test-contract`
//!   compiles an app with no `draw` and passes only if the compiler rejects it.
//! - Examples: `run`, `serve`, `wasm` use the rack. `run-column`, `serve-column`, and
//!   `wasm-column` use the column.

const std = @import("std");

/// Options for `addApp`. `target` and `optimize` apply to the native executable and the
/// tests. The wasm module always targets `wasm32-freestanding` at `optimize`.
pub const AppOptions = struct {
    /// Executable and wasm base name.
    name: []const u8,
    /// The file that declares `pub const App`.
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Directory holding `libwgpu_native.so`. Null uses the `wgpu_native` package.
    wgpu_lib_dir: ?[]const u8 = null,
};

/// The steps `addApp` creates. The caller attaches them to its own named steps.
pub const AppSteps = struct {
    /// Installs the native executable into the prefix.
    install: *std.Build.Step,
    /// Runs the native executable. Depends on its install step.
    run: *std.Build.Step,
    /// Installs `<name>.wasm`.
    wasm: *std.Build.Step,
    /// Serves the browser surface on localhost. Depends on the wasm install.
    serve: *std.Build.Step,
    /// Runs the app's own unit tests.
    tests: *std.Build.Step,
};

/// Adds the native, wasm, serve, and test targets for one app. `patchwork_builder` is the
/// Patchwork dependency's builder (`dep.builder`), or `b` itself inside this repo.
pub fn addApp(
    b: *std.Build,
    patchwork_builder: *std.Build,
    options: AppOptions,
) AppSteps {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const native_library = add_library_module(patchwork_builder, options.target, options.optimize);
    const wasm_library = add_library_module(patchwork_builder, wasm_target, options.optimize);
    const native_app = add_app_module(b, options, options.target, native_library);
    const wasm_app = add_app_module(b, options, wasm_target, wasm_library);

    const exe = add_native(b, patchwork_builder, options, .{
        .library = native_library,
        .app = native_app,
    });
    const install = b.addInstallArtifact(exe, .{});
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const wasm = add_wasm(b, patchwork_builder, options, .{
        .library = wasm_library,
        .app = wasm_app,
    });
    const wasm_install = b.addInstallArtifact(wasm, .{});

    const tests = b.addTest(.{ .root_module = native_app });
    return .{
        .install = &install.step,
        .run = &run_cmd.step,
        .wasm = &wasm_install.step,
        .serve = add_serve(b, patchwork_builder, options, wasm, &wasm_install.step),
        .tests = &b.addRunArtifact(tests).step,
    };
}

/// The two modules a host root imports.
const Modules = struct {
    library: *std.Build.Module,
    app: *std.Build.Module,
};

/// One `patchwork` module for one target. Owned by the Patchwork builder so every
/// path inside it resolves in Patchwork's tree.
fn add_library_module(
    patchwork_builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return patchwork_builder.createModule(.{
        .root_source_file = patchwork_builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// The consumer's app file, compiled against the library module of the same target.
fn add_app_module(
    b: *std.Build,
    options: AppOptions,
    target: std.Build.ResolvedTarget,
    library: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
    });
    module.addImport("patchwork", library);
    return module;
}

/// Native Wayland + WebGPU executable.
/// - Resolves `libwgpu_native.so` and its runtime linker path (RPATH) from the `wgpu_native`
///   package of the Patchwork builder, or from `options.wgpu_lib_dir` when set.
/// - Dynamically links `libwayland-client.so` and `libwgpu_native.so`.
fn add_native(
    b: *std.Build,
    patchwork_builder: *std.Build,
    options: AppOptions,
    modules: Modules,
) *std.Build.Step.Compile {
    const lib_path: std.Build.LazyPath = if (options.wgpu_lib_dir) |dir|
        .{ .cwd_relative = dir }
    else
        patchwork_builder.dependency("wgpu_native", .{}).path("lib");

    const root = b.createModule(.{
        .root_source_file = patchwork_builder.path("src/host/native_main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    root.addImport("patchwork", modules.library);
    root.addImport("app", modules.app);
    const exe = b.addExecutable(.{ .name = options.name, .root_module = root });
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
    return exe;
}

/// Freestanding WebAssembly module.
/// - `entry = .disabled`: a library without a `main()` function.
/// - `rdynamic = true`: keeps every symbol `export_app` exports (`start`, `tick`, ...).
/// - `export_memory = true`: exposes `WebAssembly.Memory` so `web/shell.js` reads shader
///   source, vertex layouts, and instance arrays without copies.
fn add_wasm(
    b: *std.Build,
    patchwork_builder: *std.Build,
    options: AppOptions,
    modules: Modules,
) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = patchwork_builder.path("src/host/web_main.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = options.optimize,
    });
    root.addImport("patchwork", modules.library);
    root.addImport("app", modules.app);
    const wasm = b.addExecutable(.{ .name = options.name, .root_module = root });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    return wasm;
}

/// The development HTTP server. It always serves the module as `/patchwork.wasm`, so
/// `web/shell.js` does not depend on the app name.
fn add_serve(
    b: *std.Build,
    patchwork_builder: *std.Build,
    options: AppOptions,
    wasm: *std.Build.Step.Compile,
    wasm_install: *std.Build.Step,
) *std.Build.Step {
    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_module = b.createModule(.{
            .root_source_file = patchwork_builder.path("src/serve.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
    });
    const serve_run = b.addRunArtifact(serve_exe);
    serve_run.step.dependOn(wasm_install);
    serve_run.addFileArg(patchwork_builder.path("web/index.html"));
    serve_run.addFileArg(patchwork_builder.path("web/shell.js"));
    serve_run.addFileArg(wasm.getEmittedBin());
    return &serve_run.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wgpu_lib_dir = b.option(
        []const u8,
        "wgpu-lib-dir",
        "Override directory containing libwgpu_native.so (defaults to the wgpu_native package)",
    );

    // The library module for projects that import it directly.
    const library = b.addModule("patchwork", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rack = addApp(b, b, .{
        .name = "rack",
        .root_source_file = b.path("examples/rack/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    const column = addApp(b, b, .{
        .name = "column",
        .root_source_file = b.path("examples/column/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(rack.install);
    b.getInstallStep().dependOn(column.install);
    add_example_steps(b, "", "the rack", rack);
    add_example_steps(b, "-column", "the scroll column", column);
    add_test_steps(b, library, .{ rack, column });
}

/// Names the steps of one example. The rack owns the plain names.
fn add_example_steps(
    b: *std.Build,
    suffix: []const u8,
    what: []const u8,
    steps: AppSteps,
) void {
    const run = b.step(
        b.fmt("run{s}", .{suffix}),
        b.fmt("Run {s} natively", .{what}),
    );
    run.dependOn(steps.run);
    const wasm = b.step(
        b.fmt("wasm{s}", .{suffix}),
        b.fmt("Build {s} for the browser", .{what}),
    );
    wasm.dependOn(steps.wasm);
    const serve = b.step(
        b.fmt("serve{s}", .{suffix}),
        b.fmt("Serve {s} on localhost", .{what}),
    );
    serve.dependOn(steps.serve);
}

/// `test` runs the library tests and every example's tests. A test root that imported only
/// the library would drop the examples without an error, so each example is listed here.
/// `test-contract` runs a compile that must fail.
fn add_test_steps(
    b: *std.Build,
    library: *std.Build.Module,
    examples: [2]AppSteps,
) void {
    const library_tests = b.addTest(.{ .root_module = library });
    const test_step = b.step("test", "Run library and example unit tests");
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    for (examples) |example| {
        test_step.dependOn(example.tests);
    }

    const contract = b.createModule(.{
        .root_source_file = b.path("test/contract_missing_draw.zig"),
        .target = library.resolved_target,
        .optimize = library.optimize.?,
    });
    contract.addImport("patchwork", library);
    const contract_test = b.addTest(.{ .root_module = contract });
    contract_test.expect_errors = .{ .contains = "App is missing `pub fn draw`" };
    const contract_step = b.step(
        "test-contract",
        "Check that an app without `draw` fails to compile",
    );
    contract_step.dependOn(&contract_test.step);
}

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
//! The host roots are plain files in this repo. They contain no app code, only the call that
//! instantiates the matching host for `app.App`.
//!
//! ## 2. Why Every Path Comes From the Patchwork Builder
//! `addApp(b, patchwork_builder, options)` takes two builders. `b` is the consumer's and
//! `patchwork_builder` is the Patchwork dependency's. Host roots, web assets, and the
//! `wgpu_native` package must resolve in Patchwork's tree, so they go through
//! `patchwork_builder`. A `b.path` call for them would search the consumer's tree. Inside
//! this repo the two builders are the same object.
//!
//! ## 3. One Library Module Per Target
//! The app module and the host root must import the same `patchwork` module instance for a
//! target, or the types in the contract would be distinct. `addApp` creates one for the
//! native target and one for wasm, and gives each to both of its users.
//!
//! ## 4. Install Layout and RUNPATH
//! The Zig 0.17 build runner hands the compiler paths relative to the build root, so a RUNPATH
//! taken from the `wgpu_native` package would be `zig-pkg/<hash>/lib`, which the loader
//! resolves against the working directory. `addApp` therefore installs the library with the
//! executable and points RUNPATH at it:
//!
//! ```text
//!   <prefix>/bin/<name>              RUNPATH $ORIGIN/../lib  (each_lib_rpath off)
//!   <prefix>/lib/libwgpu_native.so   from the package, or from `wgpu_lib_dir`
//!   <prefix>/bin/<name>.wasm         from the wasm step
//! ```
//!
//! A consumer's `install` step gets the same layout under its own prefix, and its `run` step
//! starts the installed executable, never the copy in the cache.
//!
//! ## 5. Steps
//! - `run` installs, then runs the installed native executable (Wayland, libxkbcommon, and
//!   wgpu-native).
//! - Native executables link `libwayland-client` and `libxkbcommon` dynamically through
//!   pkg-config (`link_xkbcommon`): a consumer's build machine needs both `.so` files and
//!   their `.pc` files, and its users need both libraries. The wasm build links nothing.
//! - `wasm` installs `<name>.wasm` (freestanding, `export_memory`, `rdynamic`).
//! - `serve` serves the page, `shell.js`, the wasm, and `worklet.js` through `src/serve.zig`,
//!   which owns the address and port.
//! - `bench` runs the installed native executable with `--bench` and the arguments after
//!   `--`: a scenario name, `--frames`, `--adapter`, `--dump`, `--csv` (`src/bench.zig`).
//!   Build with `-Doptimize=ReleaseFast` for numbers that mean something; the report names
//!   the mode.
//! - `check` runs the installed native executable with `--check` and the arguments after `--`
//!   (`--adapter low|high`): it compiles every shader and pipeline the app creates at startup
//!   on a device with no window and fails naming the first broken draw type
//!   (`src/host/gpu_wgpu.zig`, section 10). It needs a GPU, so it is not part of `test`; in
//!   this repo `zig build check` checks every example.
//! - `regress` runs the installed native executable with `--regress` and the arguments after
//!   `--` (`--adapter high|low|both`, `--bless`, `--only <scenario>`, `--keep`), from the
//!   build root: it renders every regressed scenario with no window, cache on and off, and
//!   compares each frame's hash with `test/golden/<adapter>/<name>.txt`
//!   (`src/host/headless.zig`). It needs a GPU, so it is not part of `test`; in this repo
//!   `zig build regress` runs every example's, in parallel, each printing its report once.
//! - `tests` runs the app's own tests. They need no GPU and no display.
//! - `zig build test` in this repo adds the library tests and the native-only tests
//!   (`src/native_tests.zig`, linked with libxkbcommon and libwayland-client).
//!   `zig build test-contract` compiles an app with no `draw`, an app whose draw type is not a
//!   multiple of 16 bytes, an app whose draw type reads time without declaring `animated`, an
//!   app that declares `Audio` without `audio`, a theme color out of range, a knob whose
//!   skin lacks `knob`, overlays on a type without an overlay field, an editor whose
//!   language lacks `next`, the batch audit without a `Box`, and an editor language with
//!   too few `faces`, and passes only if the compiler rejects each with its expected message.
//! - Each example in this repo gets `run`, `serve`, `wasm`, and `bench` steps through
//!   `add_example_steps`, with a name suffix for every example but the first.
//! - `zig build compare -- a.ppm b.ppm [--diff d.png] [--crop x y w h --png out.png]`
//!   compares two frame dumps, and writes a diff picture or a cropped PNG of the first
//!   (`tools/compare.zig`).
//!
//! ## 6. Fonts
//! `add_font_module(patchwork_builder, ranges, fonts)` builds `tools/subset.zig` for the host,
//! runs it once per face in `src/text/fonts/` with `ranges` (`src/text/subset.zig`) and once
//! per app face (`AppOptions.fonts`) with that face's ranges, and writes the outputs beside a
//! generated `fonts.zig` that embeds them: the `patchwork_fonts` module every library module
//! imports. `fonts.zig` declares `Face`, the library's three tags at 0, 1, and 2 and then the
//! app's in order, so `.{ .face = .icons }` compiles only in an app that added `icons`. The
//! module has no target, so one serves the native and wasm libraries, and the default ranges'
//! module without app faces is made once per builder. Null ranges copy a face whole instead.
//! The tool's runs are cached, so a build with unchanged faces and ranges runs it zero times.
//! `addApp` checks the app's face list first (`subset.check_faces`) and panics naming the
//! face and the problem.

const std = @import("std");
const subset = @import("src/text/subset.zig");
const gallery_icons = @import("examples/gallery/icons.zig");
const session_faces = @import("examples/session/faces.zig");

/// The codepoints an app's faces cover unless it passes `font_ranges` (`src/text/subset.zig`).
pub const default_font_ranges: []const [2]u21 = &subset.default_ranges;

/// Faces an app may add beside the library's three (section 6).
pub const app_face_max: u32 = subset.app_face_max;

/// One face an app adds beside the library's three (section 6).
pub const FontOption = struct {
    /// A Zig identifier: becomes the `text.Face` tag. Not sans, sans_bold, or mono.
    name: []const u8,
    /// A TrueType face with `glyf` outlines, usually `b.path(...)` in the consumer's tree.
    source: std.Build.LazyPath,
    /// Codepoints to keep, increasing and apart. Null keeps the app's `font_ranges` (null
    /// there: the full face).
    ranges: ?[]const [2]u21 = null,
};

/// Options for `addApp`. `target` applies to the native executable and the tests, and
/// `optimize` applies to every artifact. The wasm module always targets `wasm32-freestanding`.
pub const AppOptions = struct {
    /// Executable and wasm base name.
    name: []const u8,
    /// The file that declares `pub const App`.
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// Directory holding `libwgpu_native.so`. Null uses the `wgpu_native` package.
    wgpu_lib_dir: ?[]const u8 = null,
    /// Codepoint ranges the embedded faces keep, on both targets (section 6). Null embeds
    /// the full faces.
    font_ranges: ?[]const [2]u21 = default_font_ranges,
    /// Faces the app adds, at most `app_face_max`: `text.Face` tags after the library's three
    /// (section 6).
    fonts: []const FontOption = &.{},
};

/// The steps `addApp` creates. The caller attaches them to its own named steps.
pub const AppSteps = struct {
    /// Installs the native executable into `<prefix>/bin` and `libwgpu_native.so` into
    /// `<prefix>/lib`.
    install: *std.Build.Step,
    /// Runs the installed native executable. Depends on its install step.
    run: *std.Build.Step,
    /// Installs `<name>.wasm`.
    wasm: *std.Build.Step,
    /// Serves the browser surface on localhost. Depends on the wasm install.
    serve: *std.Build.Step,
    /// Runs the installed native executable in bench mode (`--bench` plus the arguments).
    bench: *std.Build.Step,
    /// Runs the installed native executable with `--check` plus the arguments: compiles every
    /// shader and pipeline on a device with no window and fails on the first error. Needs a
    /// GPU, so it is not part of `test`.
    check: *std.Build.Step,
    /// Runs the installed native executable with `--regress` plus the arguments, from the
    /// build root: every regressed scenario with no window, against the golden files. Needs a
    /// GPU, so it is not part of `test`.
    regress: *std.Build.Step,
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
    check_fonts(options);
    const fonts = add_font_module(patchwork_builder, options.font_ranges, options.fonts);
    const optimize = options.optimize;
    const native_library = add_library_module(patchwork_builder, options.target, optimize, fonts);
    const wasm_library = add_library_module(patchwork_builder, wasm_target, optimize, fonts);
    const native_app = add_app_module(b, options, options.target, native_library);
    const wasm_app = add_app_module(b, options, wasm_target, wasm_library);

    const wgpu_lib = wgpu_lib_path(patchwork_builder, options);
    const exe = add_native(b, patchwork_builder, options, wgpu_lib, .{
        .library = native_library,
        .app = native_app,
    });
    const install = b.addInstallArtifact(exe, .{});
    // The executable finds the library through `$ORIGIN/../lib`, so it is installed with it.
    const wgpu_install = b.addInstallLibFile(wgpu_lib.path(b, wgpu_lib_name), wgpu_lib_name);
    install.step.dependOn(&wgpu_install.step);

    const wasm = add_wasm(b, patchwork_builder, options, .{
        .library = wasm_library,
        .app = wasm_app,
    });
    const wasm_install = b.addInstallArtifact(wasm, .{});

    const tests = b.addTest(.{ .root_module = native_app });
    return .{
        .install = &install.step,
        .run = add_run(b, options, &install.step, "run", &.{}),
        .bench = add_run(b, options, &install.step, "bench", &.{"--bench"}),
        .check = add_run(b, options, &install.step, "check", &.{"--check"}),
        .regress = add_regress(b, options, &install.step),
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
    optimize: std.lang.Optimize,
    fonts: *std.Build.Module,
) *std.Build.Module {
    const module = patchwork_builder.createModule(.{
        .root_source_file = patchwork_builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("patchwork_fonts", fonts);
    return module;
}

/// The faces in `src/text/fonts/`, by the name `patchwork_fonts` gives them.
const faces = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "sans", .source = "src/text/fonts/NotoSans-Regular.ttf" },
    .{ .name = "sans_bold", .source = "src/text/fonts/NotoSans-Bold.ttf" },
    .{ .name = "mono", .source = "src/text/fonts/NotoSansMono-Regular.ttf" },
};

comptime {
    std.debug.assert(faces.len == subset.library_faces.len);
    for (faces, subset.library_faces) |face, name| {
        std.debug.assert(std.mem.eql(u8, face.name, name));
    }
}

/// The default ranges' module without app faces, made once per Patchwork builder and shared by
/// every such app and both targets.
var default_fonts: ?struct { builder: *std.Build, module: *std.Build.Module } = null;

/// Panics, naming the app and the face, when `options.fonts` breaks `subset.check_faces`
/// (section 6). Configure time, so a bad list never reaches the compiler.
fn check_fonts(options: AppOptions) void {
    var specs: [app_face_max + 1]subset.FaceSpec = undefined;
    const count = @min(options.fonts.len, specs.len);
    for (options.fonts[0..count], specs[0..count]) |font, *spec| {
        spec.* = .{ .name = font.name, .ranges = font.ranges };
    }
    const found = subset.check_faces(specs[0..count]) orelse return;
    const name = if (found.index < options.fonts.len) options.fonts[found.index].name else "";
    std.debug.panic("addApp {s}: fonts[{d}] '{s}': {s}", .{
        options.name,
        found.index,
        name,
        subset.problem_text(found.problem),
    });
}

/// The generated `patchwork_fonts` module (section 6): the three faces subset to `ranges` and
/// each of `fonts` to its own ranges (else `ranges`) by `tools/subset.zig`, or copied whole
/// when those are null, and `fonts.zig`, which embeds them. It has no target of its own, so
/// the native and wasm libraries share it.
pub fn add_font_module(
    patchwork_builder: *std.Build,
    ranges: ?[]const [2]u21,
    fonts: []const FontOption,
) *std.Build.Module {
    const b = patchwork_builder;
    const is_default = fonts.len == 0 and
        if (ranges) |list| list.ptr == default_font_ranges.ptr else false;
    if (is_default) {
        if (default_fonts) |made| {
            if (made.builder == b) return made.module;
        }
    }
    const files = b.addWriteFiles();
    var tool: ?*std.Build.Step.Compile = null;
    for (faces) |face| {
        add_face(b, files, &tool, .{ .name = face.name, .source = b.path(face.source) }, ranges);
    }
    for (fonts) |font| add_face(b, files, &tool, font, font.ranges orelse ranges);
    _ = files.add("fonts.zig", fonts_source(b, ranges, fonts));
    const root = files.getDirectory().path(b, "fonts.zig");
    const module = b.createModule(.{ .root_source_file = root });
    if (is_default) default_fonts = .{ .builder = b, .module = module };
    return module;
}

/// Writes `<name>.ttf` into `files`: `font` subset to `ranges` by the tool (built on first
/// use into `tool`), or copied whole when `ranges` is null.
fn add_face(
    b: *std.Build,
    files: *std.Build.Step.WriteFile,
    tool: *?*std.Build.Step.Compile,
    font: FontOption,
    ranges: ?[]const [2]u21,
) void {
    const name = b.fmt("{s}.ttf", .{font.name});
    const list = ranges orelse {
        _ = files.addCopyFile(font.source, name);
        return;
    };
    const subsetter = tool.* orelse made: {
        const exe = b.addExecutable(.{
            .name = "subset",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/subset.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        exe.root_module.addImport("subset", b.createModule(.{
            .root_source_file = b.path("src/text/subset.zig"),
        }));
        tool.* = exe;
        break :made exe;
    };
    const run = b.addRunArtifact(subsetter);
    run.addFileArg(font.source);
    const output = run.addOutputFileArg(name);
    run.addArg(ranges_arg(b, list));
    _ = files.addCopyFile(output, name);
}

/// `ranges` as the tool's argument: `20-7E,A0-FF,...` in hex.
fn ranges_arg(b: *std.Build, ranges: []const [2]u21) []const u8 {
    std.debug.assert(ranges.len >= 1);
    var spec: []const u8 = "";
    for (ranges, 0..) |range, index| {
        const separator = if (index == 0) "" else ",";
        spec = b.fmt("{s}{s}{X}-{X}", .{ spec, separator, range[0], range[1] });
    }
    return spec;
}

/// The generated `fonts.zig` of `patchwork_fonts` (section 6).
fn fonts_source(b: *std.Build, ranges: ?[]const [2]u21, fonts: []const FontOption) []const u8 {
    var tags: []const u8 = "";
    var names: []const u8 = "";
    var data: []const u8 = "";
    var kept: []const u8 = "";
    for (faces, 0..) |face, index| {
        tags = b.fmt("{s}    {s} = {d},\n", .{ tags, face.name, index });
        names = b.fmt("{s}    \"{s}\",\n", .{ names, face.name });
        data = b.fmt("{s}    @embedFile(\"{s}.ttf\"),\n", .{ data, face.name });
        kept = b.fmt("{s}    ranges,\n", .{kept});
    }
    for (fonts, faces.len..) |font, index| {
        tags = b.fmt("{s}    {s} = {d},\n", .{ tags, font.name, index });
        names = b.fmt("{s}    \"{s}\",\n", .{ names, font.name });
        data = b.fmt("{s}    @embedFile(\"{s}.ttf\"),\n", .{ data, font.name });
        kept = b.fmt("{s}    {s},\n", .{ kept, ranges_source(b, font.ranges orelse ranges) });
    }
    return b.fmt(
        \\//! Generated by Patchwork's `build.zig` (`add_font_module`): the faces `text.zig` embeds.
        \\/// The faces: the library's three, then the app's (`AppOptions.fonts`) in order.
        \\pub const Face = enum(u8) {{
        \\{s}}};
        \\/// Each face's name, by `Face`.
        \\pub const names = [_][]const u8{{
        \\{s}}};
        \\/// Each face's bytes, by `Face`.
        \\pub const data = [_][]const u8{{
        \\{s}}};
        \\/// False when the library's faces are the full files.
        \\pub const subset = {};
        \\/// The codepoints the library's faces keep.
        \\pub const ranges: []const [2]u21 = {s};
        \\/// The codepoints each face keeps, by `Face`.
        \\pub const face_ranges = [_][]const [2]u21{{
        \\{s}}};
        \\
    , .{ tags, names, data, ranges != null, ranges_source(b, ranges), kept });
}

/// `ranges` as a Zig slice literal; null is every codepoint.
fn ranges_source(b: *std.Build, ranges: ?[]const [2]u21) []const u8 {
    const everything: []const [2]u21 = &.{.{ 0, 0x10FFFF }};
    var list: []const u8 = "";
    for (ranges orelse everything) |range| {
        list = b.fmt("{s} .{{ 0x{X}, 0x{X} }},", .{ list, range[0], range[1] });
    }
    return b.fmt("&.{{{s} }}", .{list});
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

/// The file name `addApp` links against and installs into `<prefix>/lib`.
const wgpu_lib_name = "libwgpu_native.so";

/// The directory holding `libwgpu_native.so`: `options.wgpu_lib_dir` when set, otherwise the
/// `wgpu_native` package of the Patchwork builder.
fn wgpu_lib_path(patchwork_builder: *std.Build, options: AppOptions) std.Build.LazyPath {
    if (options.wgpu_lib_dir) |dir| return patchwork_builder.graph.cwdRelativePath(dir);
    return patchwork_builder.dependency("wgpu_native", .{}).path("lib");
}

/// Runs the installed executable rather than the cached one, because its RUNPATH
/// (`$ORIGIN/../lib`) resolves only next to the installed library. `what` names the step
/// (`run`, `bench`, `check`); `leading` goes before the arguments after `--`.
fn add_run(
    b: *std.Build,
    options: AppOptions,
    install: *std.Build.Step,
    what: []const u8,
    leading: []const []const u8,
) *std.Build.Step {
    const run_cmd = std.Build.Step.Run.create(b, b.fmt("{s} {s}", .{ what, options.name }));
    run_cmd.addFileArg(b.graph.path(.install_bin, options.name));
    run_cmd.addArgs(leading);
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(install);
    return &run_cmd.step;
}

/// `add_run` for `regress`, from the build root, where `test/golden` and `zig-out/regress`
/// resolve.
fn add_regress(b: *std.Build, options: AppOptions, install: *std.Build.Step) *std.Build.Step {
    const step = add_run(b, options, install, "regress", &.{"--regress"});
    const run_cmd: *std.Build.Step.Run = @fieldParentPtr("step", step);
    run_cmd.setCwd(b.path("."));
    run_cmd.stdio = .inherit;
    return step;
}

/// Native Wayland + WebGPU executable.
/// - Links `libwgpu_native.so` from `lib_path` and sets RUNPATH to `$ORIGIN/../lib`, where
///   `addApp` installs the library. The 0.17 build runner hands the compiler paths relative to
///   the build root, so a RUNPATH taken from `lib_path` would resolve against the working
///   directory of whoever starts the executable.
/// - Dynamically links `libwayland-client.so`, `libxkbcommon.so`, and `libwgpu_native.so`.
fn add_native(
    b: *std.Build,
    patchwork_builder: *std.Build,
    options: AppOptions,
    lib_path: std.Build.LazyPath,
    modules: Modules,
) *std.Build.Step.Compile {
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
    exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    exe.each_lib_rpath = false;
    exe.root_module.linkSystemLibrary("wayland-client", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .yes,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    link_xkbcommon(exe.root_module);
    exe.root_module.linkSystemLibrary("wgpu_native", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    return exe;
}

/// Links `libxkbcommon.so` dynamically through pkg-config: native keyboard input
/// (`src/host/xkb.zig`). Required at build and run time, like `libwayland-client`.
fn link_xkbcommon(module: *std.Build.Module) void {
    module.linkSystemLibrary("xkbcommon", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .yes,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
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
    serve_run.addFileArg(patchwork_builder.path("web/worklet.js"));
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

    // Exposed so other projects can import the library without `addApp`.
    const library = b.addModule("patchwork", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("patchwork_fonts", add_font_module(b, default_font_ranges, &.{}));

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
    const live = addApp(b, b, .{
        .name = "live",
        .root_source_file = b.path("examples/live/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(rack.install);
    b.getInstallStep().dependOn(column.install);
    const data = addApp(b, b, .{
        .name = "data",
        .root_source_file = b.path("examples/data/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(live.install);
    const wave = addApp(b, b, .{
        .name = "wave",
        .root_source_file = b.path("examples/wave/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(data.install);
    const fx = addApp(b, b, .{
        .name = "fx",
        .root_source_file = b.path("examples/fx/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(wave.install);
    b.getInstallStep().dependOn(fx.install);
    const audio = addApp(b, b, .{
        .name = "audio",
        .root_source_file = b.path("examples/audio/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(audio.install);
    add_example_steps(b, "", "the rack", rack);
    add_example_steps(b, "-column", "the scroll column", column);
    add_example_steps(b, "-live", "the live editor", live);
    add_example_steps(b, "-data", "the data textures", data);
    add_example_steps(b, "-wave", "the wave views", wave);
    add_example_steps(b, "-fx", "the offscreen effects", fx);
    const canvas = addApp(b, b, .{
        .name = "canvas",
        .root_source_file = b.path("examples/canvas/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(canvas.install);
    add_example_steps(b, "-audio", "the audio meters and scope", audio);
    add_example_steps(b, "-canvas", "the pan and zoom canvas", canvas);
    const gallery = addApp(b, b, .{
        .name = "gallery",
        .root_source_file = b.path("examples/gallery/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
        .fonts = &.{.{
            .name = "icons",
            .source = b.path("examples/gallery/fonts/lucide.ttf"),
            .ranges = &gallery_icons.ranges,
        }},
    });
    b.getInstallStep().dependOn(gallery.install);
    add_example_steps(b, "-gallery", "the widget gallery", gallery);
    const workspace = addApp(b, b, .{
        .name = "workspace",
        .root_source_file = b.path("examples/workspace/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
    });
    b.getInstallStep().dependOn(workspace.install);
    add_example_steps(b, "-workspace", "the docking workspace", workspace);
    const session = addApp(b, b, .{
        .name = "session",
        .root_source_file = b.path("examples/session/app.zig"),
        .target = target,
        .optimize = optimize,
        .wgpu_lib_dir = wgpu_lib_dir,
        .fonts = &.{
            .{ .name = "serif", .source = b.path("examples/session/fonts/NotoSerif-Regular.ttf"), .ranges = &session_faces.ranges },
            .{ .name = "serif_italic", .source = b.path("examples/session/fonts/NotoSerif-Italic.ttf"), .ranges = &session_faces.ranges },
            .{ .name = "serif_bold", .source = b.path("examples/session/fonts/NotoSerif-Bold.ttf"), .ranges = &session_faces.ranges },
        },
    });
    b.getInstallStep().dependOn(session.install);
    add_example_steps(b, "-session", "the live-coding session", session);
    const examples = [_]AppSteps{ rack, column, live, data, wave, fx, audio, canvas, gallery, workspace, session };
    add_test_steps(b, library, examples);
    add_check_step(b, &examples);
    add_regress_step(b, &examples);
    add_compare_step(b, library);
}

/// `check`: every example's windowless shader and pipeline check, with the arguments after
/// `--` (`zig build check -- --adapter low`).
fn add_check_step(b: *std.Build, examples: []const AppSteps) void {
    const step = b.step("check", "Compile every example's shaders and pipelines with no window");
    for (examples) |example| step.dependOn(example.check);
}

/// `regress`: every example's headless regress run, with the arguments after `--`
/// (`zig build regress -Doptimize=ReleaseFast -- --bless`).
fn add_regress_step(b: *std.Build, examples: []const AppSteps) void {
    const step = b.step("regress", "Render every example's scenarios headless against the goldens");
    for (examples) |example| step.dependOn(example.regress);
}

/// `compare`: the frame-dump diff tool, run with the arguments after `--`.
fn add_compare_step(b: *std.Build, library: *std.Build.Module) void {
    const root = b.createModule(.{
        .root_source_file = b.path("tools/compare.zig"),
        .target = library.resolved_target,
        .optimize = library.optimize.?,
    });
    root.addImport("patchwork", library);
    const exe = b.addExecutable(.{ .name = "compare", .root_module = root });
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const step = b.step("compare", "Compare two frame dumps: zig build compare -- a.ppm b.ppm");
    step.dependOn(&run_cmd.step);
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
    const bench_step = b.step(
        b.fmt("bench{s}", .{suffix}),
        b.fmt("Run a bench scenario of {s}: -- <scenario> [options]", .{what}),
    );
    bench_step.dependOn(steps.bench);
}

/// `test` runs the library tests and every example's tests. A test root that imported only
/// the library would drop the examples without an error, so each example is listed here.
/// `test-contract` runs compiles that must fail.
fn add_test_steps(
    b: *std.Build,
    library: *std.Build.Module,
    examples: [11]AppSteps,
) void {
    const library_tests = b.addTest(.{ .root_module = library });
    const test_step = b.step("test", "Run library and example unit tests");
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    // Native-only tests call libxkbcommon, and the drop tests reference libwayland-client's
    // proxy calls, so they get their own root and link both.
    const native = b.createModule(.{
        .root_source_file = b.path("src/native_tests.zig"),
        .target = library.resolved_target,
        .optimize = library.optimize.?,
        .link_libc = true,
    });
    link_xkbcommon(native);
    native.linkSystemLibrary("wayland-client", .{
        .needed = true,
        .weak = false,
        .use_pkg_config = .yes,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    const native_tests = b.addTest(.{ .root_module = native });
    test_step.dependOn(&b.addRunArtifact(native_tests).step);
    for (examples) |example| {
        test_step.dependOn(example.tests);
    }

    const contract_step = b.step(
        "test-contract",
        "Check that a broken app contract or draw type fails to compile",
    );
    const contracts = [_]struct { path: []const u8, expected: []const u8 }{
        .{
            .path = "test/contract_missing_draw.zig",
            .expected = "App is missing `pub fn draw`",
        },
        .{
            .path = "test/contract_ragged_type.zig",
            .expected = "contract_ragged_type.Ragged: field `count` must be f32, [2]f32, or [4]f32",
        },
        .{
            .path = "test/contract_frozen_time.zig",
            .expected = "contract_frozen_time.Frozen: reads time but does not declare " ++
                "`animated = true`",
        },
        .{
            .path = "test/contract_audio_without_sink.zig",
            .expected = "App declares `Audio` but is missing `pub fn audio`",
        },
        .{
            .path = "test/contract_theme_range.zig",
            .expected = "App.config.theme.colors.panel: a component is outside [0, 1]",
        },
        .{
            .path = "test/contract_skin_missing.zig",
            .expected = "contract_skin_missing.Bare: missing " ++
                "`pub fn knob(cx, widgets.KnobLook) ?widgets.Shape`",
        },
        .{
            .path = "test/contract_overlays_none.zig",
            .expected = "ui.overlays: contract_overlays_none.Bare has no overlay field",
        },
        .{
            .path = "test/contract_language_missing.zig",
            .expected = "contract_language_missing.Bare: missing `pub fn next(line: []const u8, " ++
                "at: *u32, state: *State) ?editor.Token(Class)`",
        },
        .{
            .path = "test/contract_audit_no_box.zig",
            .expected = "covered_glyphs needs Box in App.config.draw",
        },
        .{
            .path = "test/contract_faces_short.zig",
            .expected = "contract_faces_short.Short: `faces` must be [2]text.Face, one face per Class",
        },
    };
    for (contracts) |case| {
        const contract = b.createModule(.{
            .root_source_file = b.path(case.path),
            .target = library.resolved_target,
            .optimize = library.optimize.?,
        });
        contract.addImport("patchwork", library);
        const contract_test = b.addTest(.{ .root_module = contract });
        contract_test.expect_errors = .{ .contains = case.expected };
        contract_step.dependOn(&contract_test.step);
    }
}

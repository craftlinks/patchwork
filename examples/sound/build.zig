//! Patchwork's examples that make sound: `audio` and `rack`, on Thrum's test tone (Patchwork's
//! step 55). A package of its own, as `test/consumer` is, so Patchwork's own build never names
//! Thrum and its library cannot import it; this package takes both as path dependencies, and
//! Thrum's checkout must sit beside Patchwork's.
//!
//! ```text
//! zig build run           the rack, natively, the tone on the default output (needs libpipewire)
//! zig build run-audio     the meters, scope, and XY trace
//! zig build serve         the rack in the browser; serve-audio the other; Space plays the tone
//! zig build test          both apps' tests and the glue's, no device and no window
//! zig build regress       both apps' scenarios against test/golden
//! ```
//!
//! `zig build test-sound` in Patchwork's root runs `install`, `wasm`, `test`, and `regress` here.

const std = @import("std");
const patchwork = @import("patchwork");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("patchwork", .{ .target = target, .optimize = optimize });
    const thrum = b.dependency("thrum", .{ .target = target });
    const wasm = b.resolveTargetQuery(patchwork.wasm_query);
    const thrum_wasm = b.dependency("thrum", .{ .target = wasm });
    const native_imports = [_]patchwork.Import{
        .{ .name = "thrum", .module = thrum.module("thrum") },
        .{ .name = "testtone", .module = thrum.module("testtone") },
    };
    const wasm_imports = [_]patchwork.Import{
        .{ .name = "thrum", .module = thrum_wasm.module("thrum") },
        .{ .name = "testtone", .module = thrum_wasm.module("testtone") },
    };
    // Each page plays the tone in Thrum's worklet from its own wasm (`tone.zig`, section 4).
    const web_files = [_]patchwork.WebFile{
        .{ .route = "/thrum-worklet.js", .path = thrum.path("web/worklet.js") },
    };
    const examples = [_]struct { name: []const u8, root: []const u8, suffix: []const u8 }{
        .{ .name = "rack", .root = "rack.zig", .suffix = "" },
        .{ .name = "audio", .root = "audio.zig", .suffix = "-audio" },
    };
    const test_step = b.step("test", "Run both apps' tests");
    const regress = b.step("regress", "Render both apps' scenarios against test/golden");
    const wasm_step = b.step("wasm", "Build both apps for the browser");
    for (examples) |example| {
        const steps = patchwork.addApp(b, dep.builder, .{
            .name = example.name,
            .root_source_file = b.path(example.root),
            .target = target,
            .optimize = optimize,
            .native_imports = &native_imports,
            .wasm_imports = &wasm_imports,
            .web_module = b.path("tone.js"),
            .web_files = &web_files,
        });
        b.getInstallStep().dependOn(steps.install);
        test_step.dependOn(steps.tests);
        regress.dependOn(steps.regress);
        wasm_step.dependOn(steps.wasm);
        const run = b.fmt("run{s}", .{example.suffix});
        b.step(run, b.fmt("Run {s} natively", .{example.name})).dependOn(steps.run);
        const serve = b.fmt("serve{s}", .{example.suffix});
        b.step(serve, b.fmt("Serve {s} on localhost", .{example.name})).dependOn(steps.serve);
        // The name Patchwork's `tools/browser_check.py --root` serves the rack by.
        if (example.suffix.len == 0) {
            b.step("serve-rack", "The same as serve").dependOn(steps.serve);
        }
        const bench = b.fmt("bench{s}", .{example.suffix});
        b.step(bench, b.fmt("Bench {s}: -- <scenario>", .{example.name})).dependOn(steps.bench);
    }
}

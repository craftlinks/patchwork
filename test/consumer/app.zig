//! The consumer's app: one file that imports two peers beside Patchwork, and takes a file's name.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Proves
//! `pure` reaches both targets through one module. `linked` is a module per target, and its answer
//! is the same on both, so the native and browser pictures match. The screen shows each peer's
//! answer, the file named on the command line, and a bar as long as the app's time.
//!
//! ## 2. Arguments
//! `consumer <file>` reads the file in `args`, which runs before the display is connected. `Io`
//! belongs to `main`, which the host owns, so `args` builds a single-threaded one for the call: it
//! needs no allocator and nothing to tear down. `consumer <file> --print` reports and exits there,
//! so `zig build test-consumer` checks it with no window. `args` compiles only natively: the wasm
//! build never references it.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the file and every line are static, and the name is cut to `name_cap` bytes.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const pure = @import("pure");
const linked = @import("linked");
const quads = patchwork.draw;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

const Context = patchwork.app.Context(App);

const name_cap: u32 = 64;
const line_cap: u32 = 128;
/// Logical pixels of the bar per second of the app's time.
const bar_px_per_s: f32 = 100;

/// The bar's top-left, in logical pixels from the window's.
pub const bar_x: f32 = 16;
pub const bar_y: f32 = 144;
pub const bar_height: f32 = 24;

const style: text.Style = .{
    .face = .sans,
    .size = 16,
    .color = patchwork.theme.dark.colors.text,
};
const bar_color: [4]f32 = .{ 0.35, 0.80, 0.55, 1 };

var file_buffer: [4096]u8 = undefined;

pub const App = struct {
    /// The app's time, which a transport would advance; a tool sets it.
    time_ms: u64,
    /// The file named on the command line, with `size` bytes read; empty without one.
    name: [name_cap]u8,
    name_len: u32,
    size: ?u64,

    pub const config: patchwork.app.Config = .{
        .title = "consumer",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 4 },
            .{ .type = quads.Glyph, .cap = 256 },
        },
        .area_cap = 4,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 3 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 10 },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.time_ms = 0;
        app.name_len = 0;
        app.size = null;
    }

    /// Module guide, section 2.
    pub fn args(app: *App, arguments: []const [:0]const u8) void {
        if (arguments.len == 0) return;
        const name = arguments[0];
        app.name_len = @min(name.len, name_cap);
        @memcpy(app.name[0..app.name_len], name[0..app.name_len]);
        var threaded: std.Io.Threaded = .init_single_threaded;
        const dir = std.Io.Dir.cwd();
        const bytes = dir.readFile(threaded.io(), name, &file_buffer) catch null;
        app.size = if (bytes) |read| read.len else null;
        if (arguments.len == 1) return;
        var line: [line_cap]u8 = undefined;
        std.debug.print("consumer: {s}\n", .{app.file_line(&line)});
        std.process.exit(if (app.size == null) 1 else 0);
    }

    pub fn event(app: *App, cx: *Context, event_value: patchwork.input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const panel: widgets.Panel = .{ .paint = widgets.paint_of(cx.theme().colors.panel, 0) };
        _ = panel.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(16) });
        const row = ui.sized(.fill, .{ .fixed = 32 });
        const peers: widgets.Label = .{ .text = pure.greeting, .style = style };
        peers.draw(cx, row);
        var key_line: [line_cap]u8 = undefined;
        const key: widgets.Label = .{ .text = key_text(&key_line), .style = style };
        key.draw(cx, row);
        var file_line_text: [line_cap]u8 = undefined;
        const file: widgets.Label = .{ .text = app.file_line(&file_line_text), .style = style };
        file.draw(cx, row);
        _ = cx.end();
        const bar: quads.Rect = .{
            .x = bar_x,
            .y = bar_y,
            .width = app.bar_width(),
            .height = bar_height,
        };
        if (bar.width == 0) return;
        const clip: quads.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 8192, .y1 = 8192 };
        cx.append(quads.Box, null, .of(bar, clip, .{ .fill = bar_color })) catch {};
    }

    /// The bar's length: at 1.5 s, 150 logical pixels.
    pub fn bar_width(app: *const App) f32 {
        const seconds = @as(f32, @floatFromInt(app.time_ms)) / 1000;
        return seconds * bar_px_per_s;
    }

    /// What the command line named: `song.txt: 22 bytes`, `song.txt: unreadable`, or `no file`.
    fn file_line(app: *const App, out: *[line_cap]u8) []const u8 {
        const name = app.name[0..app.name_len];
        if (name.len == 0) return "no file";
        const size = app.size orelse return bufprint(out, "{s}: unreadable", .{name});
        return bufprint(out, "{s}: {d} bytes", .{ name, size });
    }
};

/// The linked peer's answer, the same on both targets.
fn key_text(out: *[line_cap]u8) []const u8 {
    return bufprint(out, "keysym of q: 0x{x}", .{linked.keysym("q")});
}

fn bufprint(out: *[line_cap]u8, comptime format: []const u8, values: anytype) []const u8 {
    return std.fmt.bufPrint(out, format, values) catch unreachable;
}

var context: Context = undefined;

// Locks both peers from the app's own test binary, which `native_imports` must link: the screen
// shows the greeting, and `q`'s keysym from libxkbcommon is 0x71.
test "both peers reach the app" {
    try std.testing.expectEqualStrings("pure peer", pure.greeting);
    try std.testing.expectEqual(@as(u32, 0x71), linked.keysym("q"));
    context.init();
    var app: App = undefined;
    App.init(&app, &context.draw.textures);
    try std.testing.expect(ui.draw_frame(App, &app, &context, 640, 360, 120));
    try std.testing.expect(context.draw.items(quads.Glyph).len > 0);
}

// Locks `args`: no arguments leave the app as it was, and a file that is not there is named as
// unreadable.
test "args names the file" {
    var app: App = undefined;
    App.init(&app, &context.draw.textures);
    app.args(&.{});
    var line: [line_cap]u8 = undefined;
    try std.testing.expectEqualStrings("no file", app.file_line(&line));
    app.args(&.{"missing.txt"});
    try std.testing.expectEqualStrings("missing.txt: unreadable", app.file_line(&line));
}

// Locks the bar a tool measures: 150 logical pixels at 1500 ms.
test "the bar follows the app's time" {
    var app: App = undefined;
    App.init(&app, &context.draw.textures);
    app.time_ms = 1500;
    try std.testing.expectEqual(@as(f32, 150), app.bar_width());
}

comptime {
    patchwork.app.check(App);
    assert(name_cap < line_cap);
}

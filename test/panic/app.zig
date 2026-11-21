//! The panic test: a page that panics on its first frame, for `tools/browser_check.py`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Proves
//! `draw` makes Treadle's mistake on purpose: it formats `knob <n>` into a 7-byte label with
//! `bufPrint(...) catch unreachable`. Natively `n` is 99, `knob 99` fits, and the frame renders,
//! so `--regress --only still --keep` leaves the reference frame the browser check needs. In the
//! browser `n` is 100, one byte too many, and the first draw panics with `attempt to unwrap
//! error: NoSpaceLeft`: the same code path on both targets, one byte apart. The check must fail
//! within seconds and print that message (`host/web_exports.zig`, section 4e; `web/shell.js`,
//! section 4a). The panic needs a build with safety checks, Debug or ReleaseSafe: in ReleaseFast
//! the same call is undefined behaviour and in ReleaseSmall it is not checked. `zig build
//! serve-panic` builds Debug unless told otherwise, and `browser_check.py` uses it.
//!
//! ## 2. Where It Is Wired
//! It is no example a reader learns from and is in no regress, check, or example-test list:
//! `build.zig` gives it `run-panic`, `wasm-panic`, `serve-panic`, and `bench-panic`, installs it
//! with `zig build`, and puts its tests on `test`. It has no golden file: the regress row of its
//! one scenario is `new`.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the label is the app's own 7 bytes.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

const Context = patchwork.app.Context(App);

/// Bytes of the label: `knob 99` fits, `knob 100` does not.
const label_cap: u32 = 7;

const style: text.Style = .{
    .face = .sans,
    .size = 16,
    .color = patchwork.theme.dark.colors.text,
};

pub const App = struct {
    /// The number the label shows: 99 natively, 100 in the browser (section 1).
    knobs: u32,
    /// The label's bytes, as the last draw formatted them.
    label: [label_cap]u8,
    label_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "panic test",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 4 },
            .{ .type = quads.Glyph, .cap = 64 },
        },
        .area_cap = 4,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{
            .name = "still",
            .setup = &.{.{ .wait = 3 }},
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        // A field, so the value is runtime-known and the overflow is not a compile error.
        app.knobs = if (builtin.target.cpu.arch == .wasm32) 100 else 99;
        app.label_len = 0;
        assert(app.knobs >= 99);
        assert(app.knobs <= 100);
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
        assert(app.knobs >= 99);
        // The mistake on purpose (section 1): `knob 100` is 8 bytes.
        const label_text = std.fmt.bufPrint(&app.label, "knob {d}", .{app.knobs}) catch unreachable;
        app.label_len = @intCast(label_text.len);
        assert(app.label_len <= label_cap);
        const panel: widgets.Panel = .{ .paint = widgets.paint_of(cx.theme().colors.panel, 0) };
        _ = panel.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(16) });
        const label: widgets.Label = .{ .text = label_text, .style = style };
        label.draw(cx, ui.sized(.fill, .{ .fixed = 32 }));
        _ = cx.end();
    }
};

var context: Context = undefined;

// Locks the native side: "knob 99" fits the 7-byte label, so only the wasm panics.
test "the native label fits" {
    context.init();
    var app: App = undefined;
    App.init(&app, &context.draw.textures);
    try std.testing.expectEqual(@as(u32, 99), app.knobs);
    try std.testing.expect(ui.draw_frame(App, &app, &context, 640, 360, 120));
    try std.testing.expectEqualStrings("knob 99", app.label[0..app.label_len]);
    try std.testing.expectEqual(@as(usize, 6), context.draw.items(quads.Glyph).len);
}

//! Workspace example: four panels in a `widgets.Dock`, rearranged by dragging their tabs.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The docking workspace of the review after step 37, step 46's regression app. A dock holds
//! four panels (files, editor, log, appearance); dragging a tab onto another panel's page
//! joins it (the centre) or splits it (a side), onto the dock's edge splits the whole layout,
//! within or between bars reorders or moves it, and its "×" closes it. Save keeps the layout
//! as bytes, Load restores them, and Reset rebuilds the default. The status line and the log
//! panel report what the dock did ("moved log", "closed files").
//!
//! ## 2. Layout (logical pixels)
//! A fixed 1280 by 704 screen from the top-left, so a native dump and a browser screenshot
//! compare region for region:
//! ```text
//! screen  flow down, padding 16, spacing 8
//!   bar   fill x 40     a panel: "workspace", the status, then Save, Load, Reset (80 x 32)
//!   dock  1248 x 624 at (16, 64)
//! default layout (slots in parentheses; bench targets name them)
//!   root split (2), horizontal 0.2: files (set 1) | split (4), vertical 0.7:
//!     split (6), horizontal 0.75: editor (set 0) | appearance (set 5)
//!     log (set 3)
//! ```
//!
//! ## 3. Panels
//! - files: a `ListBox` of the example's own file names; a click reports "file app.zig".
//! - editor: `EditorOf(c)` on `sample.c` (`c.zig` is the gallery's recipe, copied).
//! - log: the dock's last `log_lines` actions, newest last.
//! - appearance: the "light" toggle (`theme.light`, and the editor's light palette) and a
//!   line of help.
//!
//! ## 4. TigerStyle Invariants
//! - Fixed storage: the dock, the editor, the saved bytes, and the log ring; no allocation.
//! - The comptime block checks the pools against the dock's and the editor's bounds.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const editor = patchwork.editor;
const bench = patchwork.bench;
const kit = widgets.kit;
const c = @import("c.zig");

const Rect = quads.Rect;
const CEditor = editor.EditorOf(c);

const screen_w: f32 = 1280;
const screen_h: f32 = 704;
const screen_padding: f32 = 16;
const gap_px: f32 = 8;
const bar_px: f32 = 40;
const button_w: f32 = 80;
const button_h: f32 = 32;
/// The dock's box: the screen inside its padding, under the bar.
const dock_w: f32 = screen_w - 2 * screen_padding;
const dock_h: f32 = screen_h - 2 * screen_padding - bar_px - gap_px;
const status_cap: u32 = 48;
const log_lines: u32 = 8;
const log_cap: u32 = 40;
const row_px: f32 = 24;
const panel_pad: f32 = 8;

/// The panels, by id.
pub const panel_files: u32 = 0;
pub const panel_editor: u32 = 1;
pub const panel_log: u32 = 2;
pub const panel_appearance: u32 = 3;
const panel_labels = [_][]const u8{ "files", "editor", "log", "appearance" };

/// The default layout's slots (section 2).
pub const slot_editor: u8 = 0;
pub const slot_files: u8 = 1;
pub const slot_root: u8 = 2;
pub const slot_log: u8 = 3;
pub const slot_appearance: u8 = 5;

/// The files panel's names.
const file_names = [_][]const u8{
    "app.zig",   "c.zig",    "sample.c", "wav.c",      "wav.h",     "build.zig",
    "README.md", "dock.zig", "tabs.zig", "editor.zig", "theme.zig", "LICENSE",
};

const help = "drag a tab onto a panel to join it or onto a side to split it";

pub const dock_id = ui.id("dock", 0);
const files_id = ui.id("files", 0);
const code_id = ui.id("code", 0);
const light_id = ui.id("light", 0);
const save_id = ui.id("save", 0);
const load_id = ui.id("load", 0);
const reset_id = ui.id("reset", 0);

const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
const button_style: text.Style = .{ .face = .sans, .size = 16, .color = theme.dark.colors.text };

/// Pools: the editor at its largest viewport (the dock's box), and the rest generously.
const glyph_cap: u32 = editor.glyph_bound(dock_w, dock_h, 15) + 1024;
const box_cap: u32 = 512;
const arc_cap: u32 = 8;
const area_cap: u32 = 128;

const Context = patchwork.app.Context(App);

pub const App = struct {
    dock: widgets.Dock,
    files: widgets.ListBox,
    code: CEditor,
    light: widgets.Toggle,
    save: widgets.Button,
    load: widgets.Button,
    reset: widgets.Button,
    /// The bytes Save kept, if any.
    saved: [widgets.dock_save_max]u8,
    saved_len: u32,
    /// The dock's last actions, a ring of `log_lines`.
    log: [log_lines][log_cap]u8,
    log_lens: [log_lines]u32,
    log_count: u32,
    status: [status_cap]u8,
    status_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork workspace",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
        },
        .area_cap = area_cap,
    };

    pub const scenarios: []const bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{ .name = "dock-centre", .setup = &centre_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-left", .setup = &left_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-right", .setup = &right_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-top", .setup = &top_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-bottom", .setup = &bottom_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-edge", .setup = &edge_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-close", .setup = &close_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-resize", .setup = &resize_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-ghost", .setup = &ghost_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dock-save", .setup = &save_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        app.dock.init(dock_id, &panel_labels);
        build_default(&app.dock);
        app.files = widgets.ListBox.init(files_id, file_names.len, row_px);
        app.code.init(code_id, CEditor.default_style);
        const loaded = app.code.load(@embedFile("sample.c"));
        assert(loaded);
        app.light = widgets.Toggle.init(light_id, "light", false);
        app.save = button(save_id, "Save");
        app.load = button(load_id, "Load");
        app.reset = button(reset_id, "Reset");
        app.saved_len = 0;
        app.log_count = 0;
        app.status_len = 0;
        app.set_status(&.{"ready"});
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.dock.handle(cx, event_value)) {
            .none => {},
            .activated => |panel| app.report(cx, "activated ", panel),
            .closed => |panel| app.report(cx, "closed ", panel),
            .moved => |panel| app.report(cx, "moved ", panel),
            .resized => app.note(cx, &.{"resized"}),
        }
        switch (app.files.handle(cx, event_value)) {
            .selected, .activated => |row| app.note(cx, &.{ "file ", file_names[row] }),
            .none => {},
        }
        switch (app.code.handle(cx, event_value)) {
            .changed => app.note(cx, &.{"editor changed"}),
            .refused => app.note(cx, &.{"editor refused"}),
            .none => {},
        }
        switch (app.light.handle(cx, event_value)) {
            .toggled => |on| {
                cx.set_theme(if (on) theme.light else theme.dark);
                app.code.style = if (on) CEditor.light_style else CEditor.default_style;
                app.note(cx, &.{ "theme ", if (on) "light" else "dark" });
            },
            .none => {},
        }
        if (app.save.handle(cx, event_value) == .clicked) {
            const bytes = app.dock.save(&app.saved);
            app.saved_len = @intCast(bytes.len);
            app.note(cx, &.{"saved"});
        }
        if (app.load.handle(cx, event_value) == .clicked) {
            const ok = app.saved_len > 0 and app.dock.load(app.saved[0..app.saved_len]);
            cx.redraw();
            app.note(cx, &.{if (ok) "loaded" else "load refused"});
        }
        if (app.reset.handle(cx, event_value) == .clicked) {
            build_default(&app.dock);
            cx.redraw();
            app.note(cx, &.{"reset"});
        }
    }

    /// No timer: `config.timer_period_ms` is 0, so the host never calls it.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        assert(app.status_len <= status_cap);
        assert(cx.phase == .idle);
        assert(now_ms == now_ms);
    }

    /// The screen of section 2.
    pub fn draw(app: *App, cx: *Context) void {
        const screen: ui.Walk = .{ .width = .{ .fixed = screen_w }, .height = .{ .fixed = screen_h } };
        _ = cx.begin(screen, .{ .flow = .down, .spacing = gap_px, .padding = .all(screen_padding) });
        app.draw_bar(cx);
        app.dock.begin(cx, .{ .width = .{ .fixed = dock_w }, .height = .{ .fixed = dock_h } });
        while (app.dock.next(cx)) |panel| switch (panel.id) {
            panel_files => app.draw_files(cx),
            panel_editor => app.code.draw(cx, ui.sized(.fill, .fill)),
            panel_log => app.draw_log(cx),
            panel_appearance => app.draw_appearance(cx),
            else => unreachable,
        };
        app.dock.end(cx);
        _ = cx.end();
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    /// The bar: its panel face first, so the frame's first instance is a box and the base
    /// layer's box batch draws under its glyph batch (text over every face below).
    fn draw_bar(app: *App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = widgets.paint_of(cx.theme().colors.panel, 8) };
        _ = face.begin(cx, ui.sized(.fill, .{ .fixed = bar_px }), .{ .flow = .right, .spacing = gap_px, .padding = .sides(12, 0, 4, 0) });
        const title = cx.walk(ui.sized(.{ .fixed = 140 }, .fill));
        if (cx.visible(title)) |clip| kit.label(cx, styled(cx, .sans_bold, 18), "workspace", title, clip, start);
        const status_w = dock_w - 16 - 140 - 3 * button_w - 4 * gap_px;
        const status = cx.walk(ui.sized(.{ .fixed = status_w }, .fill));
        if (cx.visible(status)) |clip| kit.label(cx, styled(cx, .sans, 14), app.status_text(), status, clip, start);
        var walk = ui.sized(.{ .fixed = button_w }, .{ .fixed = button_h });
        walk.margin.top = (bar_px - button_h) * 0.5;
        app.save.draw(cx, walk);
        app.load.draw(cx, walk);
        app.reset.draw(cx, walk);
        _ = cx.end();
    }

    fn draw_files(app: *App, cx: *Context) void {
        _ = app.files.begin(cx, ui.sized(.fill, .fill));
        while (app.files.next(cx)) |row| {
            const inner = ui.cx.inset(row.rect, .xy(panel_pad, 0));
            kit.label(cx, styled(cx, .sans, 14), file_names[row.index], inner, row.clip, start);
        }
        app.files.end(cx);
    }

    fn draw_log(app: *const App, cx: *Context) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(panel_pad) });
        const shown = @min(app.log_count, log_lines);
        if (shown == 0) {
            const rect = cx.walk(ui.sized(.fill, .{ .fixed = 20 }));
            if (cx.visible(rect)) |clip| kit.label(cx, styled(cx, .sans, 13), "the dock's actions show here", rect, clip, start);
        }
        var line: u32 = 0;
        while (line < shown) : (line += 1) {
            const slot = (app.log_count - shown + line) % log_lines;
            const rect = cx.walk(ui.sized(.fill, .{ .fixed = 20 }));
            const clip = cx.visible(rect) orelse continue;
            kit.label(cx, styled(cx, .mono, 13), app.log[slot][0..app.log_lens[slot]], rect, clip, start);
        }
        _ = cx.end();
    }

    fn draw_appearance(app: *const App, cx: *Context) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap_px, .padding = .all(panel_pad) });
        app.light.draw(cx, ui.sized(.fill, .{ .fixed = widgets.toggle_height }));
        const paragraph: widgets.Paragraph = .{ .text = help, .style = styled(cx, .sans, 13) };
        _ = paragraph.draw(cx, ui.sized(.fill, .fit));
        _ = cx.end();
    }

    /// Logs and shows a dock action on `panel`.
    fn report(app: *App, cx: *Context, verb: []const u8, panel: u32) void {
        app.note(cx, &.{ verb, panel_labels[panel] });
        const slot = app.log_count % log_lines;
        const line = std.fmt.bufPrint(&app.log[slot], "{s}{s}", .{ verb, panel_labels[panel] }) catch unreachable;
        app.log_lens[slot] = @intCast(line.len);
        app.log_count += 1;
    }

    fn note(app: *App, cx: *Context, parts: []const []const u8) void {
        app.set_status(parts);
        cx.redraw();
    }

    fn set_status(app: *App, parts: []const []const u8) void {
        var len: u32 = 0;
        for (parts) |part| {
            const room = status_cap - len;
            const take: u32 = @intCast(@min(part.len, room));
            @memcpy(app.status[len..][0..take], part[0..take]);
            len += take;
        }
        app.status_len = len;
        assert(app.status_len <= status_cap);
    }

    pub fn status_text(app: *const App) []const u8 {
        return app.status[0..app.status_len];
    }
};

/// The default layout (section 2), built with the dock's own operations.
fn build_default(dock: *widgets.Dock) void {
    dock.clear();
    dock.add(dock.root, panel_editor);
    _ = dock.split(slot_editor, .left, panel_files, 0.2).?;
    _ = dock.split(slot_editor, .bottom, panel_log, 0.3).?;
    _ = dock.split(slot_editor, .right, panel_appearance, 0.25).?;
    dock.nodes[slot_editor].tabs.selected = 0;
}

fn button(id: ui.Id, label: []const u8) widgets.Button {
    return .{
        .id = id,
        .label = label,
        .style = button_style,
        .padding = .xy(8, 0),
        .paint = button_paint,
        .hover = .init(widgets.hover_rate_per_ms),
        .down = .init(widgets.down_rate_per_ms),
    };
}

fn styled(cx: *Context, face: text.Face, size: f32) text.Style {
    return .{ .face = face, .size = size, .color = cx.theme().colors.text };
}

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

// ---------------------------------------------------------------------------- scenarios

/// Panel `panel`'s tab in the default layout's set `slot`, and its close button.
fn tab_target(slot: u8, panel: u32) bench.Target {
    return .{ .id = dock_id.derive(@as(u64, slot) + 1).derive(panel), .name = "dock tab", .index = panel };
}
fn close_target(slot: u8, panel: u32) bench.Target {
    return .{ .id = dock_id.derive(@as(u64, slot) + 1).derive(panel).derive(widgets.close_salt), .name = "dock close", .index = panel };
}

/// The editor's page is (270, 96, 741, 401): its centre zone x 455 to 826 and y 196 to 397.
/// log's tab grabs at (290, 518); appearance's at (1037, 79); files' at (36, 79).
const centre_steps = [_]bench.Step{
    .{ .drag = .{ .target = tab_target(slot_log, panel_log), .from_x = 20, .from_y = 15, .dx = 350, .dy = -218 } },
    .{ .wait = 12 },
};
const left_steps = [_]bench.Step{
    .{ .drag = .{ .target = tab_target(slot_appearance, panel_appearance), .from_x = 20, .from_y = 15, .dx = -737, .dy = 221 } },
    .{ .wait = 12 },
};
const right_steps = [_]bench.Step{
    .{ .drag = .{ .target = tab_target(slot_appearance, panel_appearance), .from_x = 20, .from_y = 15, .dx = -57, .dy = 221 } },
    .{ .wait = 12 },
};
const top_steps = [_]bench.Step{
    .{ .drag = .{ .target = tab_target(slot_appearance, panel_appearance), .from_x = 20, .from_y = 15, .dx = -397, .dy = 51 } },
    .{ .wait = 12 },
};
const bottom_steps = [_]bench.Step{
    .{ .drag = .{ .target = tab_target(slot_appearance, panel_appearance), .from_x = 20, .from_y = 15, .dx = -397, .dy = 391 } },
    .{ .wait = 12 },
};
/// The edge strips exist only while a drag is drawn: hold over the right edge, then release.
const edge_steps = [_]bench.Step{
    .{ .hold = .{ .target = tab_target(slot_files, panel_files), .from_x = 20, .from_y = 15, .dx = 1216, .dy = 221 } },
    .{ .release = .{ .target = .{ .id = edge_target_id, .name = "dock edge", .index = 1 }, .x = 12, .y = 236 } },
    .{ .wait = 12 },
};
const close_steps = [_]bench.Step{
    .{ .click = close_target(slot_log, panel_log) },
    .{ .wait = 12 },
};
const resize_steps = [_]bench.Step{
    .{ .drag = .{ .target = .{ .id = dock_id.derive(@as(u64, slot_root) + 1).derive(widgets.divider_salt), .name = "dock divider", .index = 0 }, .from_x = 3, .from_y = 300, .dx = 80, .dy = 0 } },
    .{ .wait = 12 },
};
const ghost_steps = [_]bench.Step{
    .{ .hold = .{ .target = tab_target(slot_files, panel_files), .from_x = 20, .from_y = 15, .dx = 944, .dy = 221 } },
    .{ .wait = 12 },
};
const save_steps = [_]bench.Step{
    .{ .click = .{ .id = save_id, .name = "save", .index = 0 } },
    .{ .click = close_target(slot_log, panel_log) },
    .{ .click = .{ .id = load_id, .name = "load", .index = 0 } },
    .{ .wait = 12 },
};
const edge_target_id = dock_id.derive(widgets.dock_edge_salt + @as(u64, @backingInt(widgets.DockZone.right)));

comptime {
    // Boxes: per set (at most four) its bar line, four tab faces, an underline, a close band,
    // and the insertion marker; three dividers, the overlay, the ghost; the editor's faces, a
    // band per line, its caret and thumb; the list's band and thumb; the toggle; three buttons.
    const lines = editor.lines_bound(dock_h, 15);
    assert(4 * (1 + 4 + 1 + 1 + 1) + 3 + 1 + 1 + (2 + lines + 2) + 2 + 3 + 3 <= box_cap);
    // Areas: per set its bar, page, four tabs, and four close buttons; three dividers, four
    // edges; the editor's three; the list's view, thumb, and rows; the toggle; three buttons.
    const rows: u32 = @intFromFloat(@ceil(dock_h / row_px) + 1);
    assert(4 * (2 + 4 + 4) + 3 + 4 + 3 + 2 + rows + 1 + 3 <= area_cap);
    patchwork.app.check(App);
    assert(dock_w == 1248 and dock_h == 624);
    assert(panel_labels.len <= widgets.dock_panels_max);
}

// ---------------------------------------------------------------------------- tests

var test_context: Context = undefined;

fn new_app() *App {
    const static = struct {
        var app: App = undefined;
    };
    test_context.init();
    App.init(&static.app, &test_context.draw.textures);
    return &static.app;
}

fn frame(app: *App) *Context {
    test_context.redraw();
    assert(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
    assert(test_context.draw.overflow_count == 0);
    return &test_context;
}

fn replay(app: *App, name: []const u8) !void {
    const scenario = bench.find(App.scenarios, name).?;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1));
    _ = frame(app);
}

test {
    _ = c;
}

fn expect_page(slot: u8, x: f32, y: f32, width: f32, height: f32) !void {
    const page = test_context_app().dock.nodes[slot].page;
    try std.testing.expectEqual(Rect{ .x = x, .y = y, .width = width, .height = height }, page);
}

fn test_context_app() *App {
    return test_app.app;
}

const test_app = struct {
    var app: *App = undefined;
};

/// A fresh app with one frame drawn, then the scenario `name` replayed.
fn scenario_app(name: []const u8) !*App {
    const app = new_app();
    test_app.app = app;
    _ = frame(app);
    try replay(app, name);
    app.dock.verify();
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
    return app;
}

/// The split holding set `set`, and whether `set` is its pane a.
fn joint_of(app: *const App, set: u8) struct { widgets.Dock.Node, bool } {
    const parent = app.dock.nodes[set].parent;
    const joint = app.dock.nodes[parent];
    return .{ joint, joint.a == set };
}

// Locks the default layout of section 2 in the 1248 x 624 dock at (16, 64): the slots bench
// targets name, and the pages: files 248 wide (0.2 of 1242) and the rest from x 270, the
// editor 741 and appearance 247 across (0.75 of 988), 401 high over log (0.7 of 618).
test "the workspace's default layout" {
    const app = new_app();
    test_app.app = app;
    _ = frame(app);
    app.dock.verify();
    try std.testing.expectEqual(slot_root, app.dock.root);
    try std.testing.expectEqual(@as(?u8, slot_editor), app.dock.set_of(panel_editor));
    try std.testing.expectEqual(@as(?u8, slot_files), app.dock.set_of(panel_files));
    try std.testing.expectEqual(@as(?u8, slot_log), app.dock.set_of(panel_log));
    try std.testing.expectEqual(@as(?u8, slot_appearance), app.dock.set_of(panel_appearance));
    try expect_page(slot_files, 16, 96, 248, 592);
    try expect_page(slot_editor, 270, 96, 741, 401);
    try expect_page(slot_appearance, 1017, 96, 247, 401);
    try expect_page(slot_log, 270, 535, 994, 153);
    try std.testing.expectEqual(app.dock.tab_id(panel_log).?, tab_target(slot_log, panel_log).id);
    try std.testing.expectEqualStrings("ready", app.status_text());
}

// Locks the drop scenarios (section 1): log into the editor's centre joins its set; appearance
// onto each side of the editor's page makes a split with the editor on the far side; files at
// the dock's right edge splits the root, its pane a quarter on the right.
test "the drop scenarios join, split, and edge-split" {
    var app = try scenario_app("dock-centre");
    try std.testing.expectEqual(@as(?u8, slot_editor), app.dock.set_of(panel_log));
    try std.testing.expectEqual(Kind.free, app.dock.nodes[slot_log].kind);
    try std.testing.expectEqualStrings("moved log", app.status_text());
    const sides = [_]struct { []const u8, splitter_axis, bool }{
        .{ "dock-left", .horizontal, true },
        .{ "dock-right", .horizontal, false },
        .{ "dock-top", .vertical, true },
        .{ "dock-bottom", .vertical, false },
    };
    for (sides) |side| {
        app = try scenario_app(side[0]);
        const set = app.dock.set_of(panel_appearance).?;
        try std.testing.expect(set != slot_appearance);
        const joint, const first = joint_of(app, set);
        try std.testing.expectEqual(side[1], joint.splitter.axis);
        try std.testing.expectEqual(side[2], first);
        try std.testing.expectEqual(slot_editor, if (first) joint.b else joint.a);
        try std.testing.expectEqualStrings("moved appearance", app.status_text());
    }
    app = try scenario_app("dock-edge");
    const root = app.dock.nodes[app.dock.root];
    try std.testing.expectEqual(app.dock.set_of(panel_files).?, root.b);
    try std.testing.expectEqual(@as(f32, 0.75), root.splitter.ratio);
    try std.testing.expectEqualStrings("moved files", app.status_text());
}

// Locks close, resize, the ghost, and save and load: log's "×" frees its set and split and
// logs "closed log"; the files divider dragged 80 px gives a ratio of (347 - 16 - 3) / 1242;
// files held over the editor's right zone draws the overlay over its right half on the popup
// layer; Save, a close, and Load give back the default layout.
test "close, resize, ghost, and save scenarios" {
    var app = try scenario_app("dock-close");
    try std.testing.expectEqual(@as(?u8, null), app.dock.set_of(panel_log));
    try std.testing.expectEqual(Kind.free, app.dock.nodes[slot_log].kind);
    try std.testing.expectEqualStrings("closed log", app.status_text());
    try std.testing.expectEqualStrings("closed log", app.log[0][0..app.log_lens[0]]);
    app = try scenario_app("dock-resize");
    const ratio = app.dock.nodes[slot_root].splitter.ratio;
    try std.testing.expectApproxEqAbs(@as(f32, (347.0 - 16.0 - 3.0) / 1242.0), ratio, 1e-5);
    try std.testing.expectEqualStrings("resized", app.status_text());
    app = try scenario_app("dock-ghost");
    const drag = test_context.dragging().?;
    try std.testing.expectEqual(app.dock.page_id(slot_editor), drag.target);
    var overlay = false;
    for (test_context.draw.items(quads.Box), 0..) |box, index| {
        if (test_context.draw.layer_at(quads.Box, @intCast(index)) != .popup) continue;
        try std.testing.expectEqualSlices(f32, &.{ 640.5, 96, 370.5, 401 }, &box.rect);
        overlay = true;
    }
    try std.testing.expect(overlay);
    app = try scenario_app("dock-save");
    try std.testing.expectEqual(@as(?u8, slot_log), app.dock.set_of(panel_log));
    try std.testing.expectEqualStrings("loaded", app.status_text());
    _ = frame(app);
    try expect_page(slot_log, 270, 535, 994, 153);
}

const Kind = @TypeOf(@as(widgets.Dock.Node, undefined).kind);
const splitter_axis = @TypeOf(@as(widgets.Dock.Node, undefined).splitter.axis);

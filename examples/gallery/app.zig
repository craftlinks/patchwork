//! Gallery example: every library widget on one screen, built only from the kit.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The regression app of phases 6 and 7: each step of those phases adds a section here. It is
//! written with `widgets.kit` and the layout defaults only (one-statement containers, no Box
//! literal, no private append helper), so it is also the template for an app's own screens.
//! Every widget reports its last action on the status line, for example "knob 1 changed 0.75".
//!
//! ## 2. Layout (logical pixels)
//! A fixed `screen_w` by `screen_h` screen from the top-left, so it fits the 1280 by 720
//! browser viewport and a native dump and a browser screenshot compare region for region:
//! ```text
//! screen   1088 x 640 at (0, 0), flow down, padding 16, spacing 8
//!   title  fill x 40        "gallery" and the status line
//!   band   fill x 152       buttons (176) | sliders (288) | knobs (fill: 4 cells of 140)
//!   band   fill x 152       toggles (176) | meter (176)   | text field (fill; field 240 x 32)
//!   list   fill x 240       a view of 40 rows of 28, the selected row highlighted
//! ```
//! Each group is a `Panel` with padding 8 that clips its children. The knobs have rings of 56,
//! 40, 56, and 72 (`Knob.sized`) in 72 px rows; the meter follows slider 0.
//!
//! ## 3. Events
//! `event` hands every event to each widget itself, because the status line needs each
//! action (`ui.route` returns only how many acted), then to the view (it takes its id), then
//! to the rows it drew last through `kit.clicked`, which also repaints a row on hover.
//!
//! ## 4. Scenarios
//! `still`; `interact` (click button 0, drag slider 0 by +80 px, click toggle 1, drag knob 1
//! by -30 px, click the field and type "abc", wheel the list by 3 rows, click row 5, then let
//! the animations settle); `hover` (hover button 1, then wait for its animator to settle). The
//! app tests replay `interact` headless and check every value it leaves.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed widget arrays, a fixed status buffer, and no allocation; every loop is bounded.
//! - The comptime block checks the layout arithmetic and the capacities.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const bench = patchwork.bench;

const Rect = quads.Rect;

const screen_w: f32 = 1088;
const screen_h: f32 = 640;
const screen_padding: f32 = 16;
const gap_px: f32 = 8;
const title_px: f32 = 40;
const band_px: f32 = 152;
const group_padding: f32 = 8;
const narrow_px: f32 = 176;
const sliders_px: f32 = 288;
const knob_cell_px: f32 = 140;
const button_px: f32 = 40;
const slider_px: f32 = 24;
const caption_px: f32 = 20;
const field_w: f32 = 240;
const field_h: f32 = 32;
const meter_track_px: f32 = 120;
const row_px: f32 = 28;
const row_count: u32 = 40;
const row_inset_px: f32 = 12;
const title_inset_px: f32 = 12;
const status_cap: u32 = 48;

const knob_rings = [_]f32{ 56, 40, 56, 72 };
const knob_names = [_][]const u8{ "gain", "tone", "mix", "drive" };
const knob_values = [_]f32{ 0.25, 0.5, 0.75, 0.6 };
const button_labels = [_][]const u8{ "Play", "Stop", "Record" };
const slider_names = [_][]const u8{ "level", "pan" };
const slider_values = [_]f32{ 0.25, 0.5 };
const toggle_names = [_][]const u8{ "mute", "solo", "arm" };
const toggle_values = [_]bool{ false, true, false };

/// The slider the meter follows.
const meter_slider: u32 = 0;

const view_id = ui.id("view", 0);
const field_id = ui.id("field", 0);

const panel_paint: widgets.Paint = widgets.paint_of(theme.chrome.panel, 8);
const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
const selected_fill: [4]f32 = .{ 0.26, 0.42, 0.72, 1 };

const title_style: text.Style = .{ .face = .sans_bold, .size = 18, .color = theme.chrome.text };
const status_style: text.Style = .{ .face = .sans, .size = 14, .color = theme.chrome.text };
const caption_style: text.Style = .{ .face = .sans, .size = 14, .color = theme.chrome.text };
const button_style: text.Style = .{ .face = .sans, .size = 16, .color = theme.chrome.text };
const field_style: text.Style = .{ .face = .mono, .size = 16, .color = theme.chrome.text };

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };

/// The rows: 40 of 28 px in the list's view.
const rows: ui.List = .{ .row_height = row_px, .count = row_count };
/// Rows one viewport can show partly: `ceil(224 / 28) + 1`.
const rows_drawn_max: u32 = 9;

/// Pool and area capacities; the comptime block checks them against the counts.
const box_cap: u32 = 64;
const arc_cap: u32 = 16;
const glyph_cap: u32 = 512;
const area_cap: u32 = 48;

const Context = patchwork.app.Context(App);

/// A group: a panel face with padding that clips its children, flowing down.
const group_layout: ui.Layout = .{
    .flow = .down,
    .spacing = gap_px,
    .padding = .all(group_padding),
    .clip = true,
};

/// The gallery. `timer_period_ms` is 0: nothing wakes the host while the pointer rests.
pub const App = struct {
    buttons: [button_labels.len]widgets.Button,
    sliders: [slider_names.len]widgets.Slider,
    knobs: [knob_names.len]widgets.Knob,
    toggles: [toggle_names.len]widgets.Toggle,
    meter: widgets.Meter,
    field: widgets.TextField,
    view: ui.ViewState,
    /// The rows drawn last, which `event` routes.
    drawn: ui.List.Range,
    selected: ?u32,
    status: [status_cap]u8,
    status_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork gallery",
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
        .{ .name = "interact", .setup = &interact_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hover", .setup = &hover_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
    };

    /// The widgets at their starting values; the gallery creates no textures.
    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        for (&app.buttons, button_labels, 0..) |*button, label, index| {
            button.* = .{
                .id = ui.id("button", @intCast(index)),
                .label = label,
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            };
        }
        for (&app.sliders, slider_values, 0..) |*slider, value, index| {
            slider.* = .{
                .id = ui.id("slider", @intCast(index)),
                .hover = .init(widgets.hover_rate_per_ms),
                .value = value,
                .track = widgets.paint_of(theme.chrome.track, widgets.track_radius),
                .fill = widgets.paint_of(theme.chrome.value, widgets.track_radius),
                .knob = widgets.paint_of(theme.chrome.control, widgets.knob_radius),
            };
        }
        for (&app.knobs, knob_names, knob_values, knob_rings, 0..) |*knob, name, value, ring, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            knob.* = widgets.Knob.init(ui.id("knob", @intCast(index)), name, value, accent).sized(ring);
        }
        for (&app.toggles, toggle_names, toggle_values, 0..) |*toggle, name, on, index| {
            toggle.* = widgets.Toggle.init(ui.id("toggle", @intCast(index)), name, on);
        }
        app.meter = .{ .name = "level", .value = slider_values[meter_slider], .track_h = meter_track_px };
        app.field = widgets.TextField.init(field_id, 32, field_style);
        app.view = ui.ViewState.init();
        app.drawn = .{ .first = 0, .end = 0 };
        app.selected = null;
        app.status = @splat(0);
        app.status_len = 0;
        app.set_status(&.{"ready"});
        assert(app.knobs[3].ring == 72);
        assert(!app.toggles[0].on);
    }

    /// Every widget, the view, then the rows drawn last (module guide, section 3).
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.buttons, 0..) |*button, index| {
            if (button.handle(cx, event_value) == .clicked) app.note(cx, &.{ "button ", digit(index), " clicked" });
        }
        for (&app.sliders, 0..) |*slider, index| {
            switch (slider.handle(cx, event_value)) {
                .changed => |value| {
                    if (index == meter_slider and app.meter.set_value(value)) cx.redraw();
                    var bytes: [8]u8 = undefined;
                    widgets.write_hundredths(&bytes, value);
                    app.note(cx, &.{ "slider ", digit(index), " changed ", bytes[0..4] });
                },
                .none, .released => {},
            }
        }
        for (&app.knobs, 0..) |*knob, index| {
            switch (knob.handle(cx, event_value)) {
                .changed => app.note(cx, &.{ "knob ", digit(index), " changed ", knob.value_text[0..4] }),
                .reset => app.note(cx, &.{ "knob ", digit(index), " reset ", knob.value_text[0..4] }),
                .none, .released => {},
            }
        }
        for (&app.toggles, 0..) |*toggle, index| {
            switch (toggle.handle(cx, event_value)) {
                .toggled => |on| app.note(cx, &.{ "toggle ", digit(index), if (on) " on" else " off" }),
                .none => {},
            }
        }
        switch (app.field.handle(cx, event_value)) {
            .changed => app.note(cx, &.{ "field ", app.field.bytes() }),
            .committed => app.note(cx, &.{"field committed"}),
            .cancelled => app.note(cx, &.{"field cancelled"}),
            .none => {},
        }
        _ = app.view.handle(cx, view_id, event_value);
        var row = app.drawn.first;
        while (row < app.drawn.end) : (row += 1) {
            if (kit.clicked(cx, ui.id("row", row), event_value)) app.select(cx, row);
        }
        assert(app.status_len <= status_cap);
    }

    /// No timer is armed, so no host calls this.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        assert(app.status_len <= status_cap);
        assert(cx.phase == .idle);
        assert(now_ms == now_ms);
    }

    /// The screen of section 2.
    pub fn draw(app: *App, cx: *Context) void {
        const screen: ui.Walk = .{ .width = .{ .fixed = screen_w }, .height = .{ .fixed = screen_h } };
        _ = cx.begin(screen, .{ .flow = .down, .spacing = gap_px, .padding = .all(screen_padding) });
        app.draw_title(cx);
        _ = cx.begin(ui.sized(.fill, .{ .fixed = band_px }), .{ .flow = .right, .spacing = gap_px });
        app.draw_buttons(cx);
        app.draw_sliders(cx);
        app.draw_knobs(cx);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .{ .fixed = band_px }), .{ .flow = .right, .spacing = gap_px });
        app.draw_toggles(cx);
        app.draw_meter(cx);
        app.draw_field(cx);
        _ = cx.end();
        app.draw_list(cx);
        _ = cx.end();
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    /// The status line's text.
    pub fn status_text(app: *const App) []const u8 {
        assert(app.status_len <= status_cap);
        return app.status[0..app.status_len];
    }

    fn draw_title(app: *const App, cx: *Context) void {
        const bar = cx.walk(ui.sized(.fill, .{ .fixed = title_px }));
        const clip = cx.visible(bar) orelse return;
        kit.face(cx, bar, clip, panel_paint.look(0, 0));
        const inner = ui.cx.inset(bar, .xy(title_inset_px, 0));
        kit.label(cx, title_style, "gallery", inner, clip, start);
        kit.label(cx, status_style, app.status_text(), inner, clip, end);
    }

    fn draw_buttons(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.buttons) |*button| button.draw(cx, ui.sized(.fill, .{ .fixed = button_px }));
        _ = cx.end();
    }

    fn draw_sliders(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.{ .fixed = sliders_px }, .fill), group_layout);
        for (&app.sliders, slider_names) |*slider, name| {
            caption(cx, name);
            slider.draw(cx, ui.sized(.fill, .{ .fixed = slider_px }));
        }
        _ = cx.end();
    }

    fn draw_knobs(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        const row: ui.Layout = .{ .flow = .right, .padding = .all(group_padding), .alignment = .{ .x = 0, .y = 0.5 }, .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .fill), row);
        const cell = ui.sized(.{ .fixed = knob_cell_px }, .{ .fixed = widgets.knob_height });
        for (&app.knobs) |*knob| knob.draw(cx, cell);
        _ = cx.end();
    }

    fn draw_toggles(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.toggles) |*toggle| toggle.draw(cx, ui.sized(.fill, .{ .fixed = widgets.toggle_height }));
        _ = cx.end();
    }

    fn draw_meter(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        app.meter.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    fn draw_field(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        caption(cx, "name");
        app.field.draw(cx, ui.sized(.{ .fixed = field_w }, .{ .fixed = field_h }));
        _ = cx.end();
    }

    /// The list: a view of the visible rows only, standing in for the others with `skip`.
    fn draw_list(app: *App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint };
        _ = face.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(group_padding) });
        const port = cx.begin_view(view_id, ui.sized(.fill, .fill), .{ .flow = .down }, &app.view);
        const range = rows.visible(app.view.scroll_y, port.height);
        assert(range.end - range.first <= rows_drawn_max);
        app.drawn = range;
        cx.skip(@as(f32, @floatFromInt(range.first)) * row_px);
        var row = range.first;
        while (row < range.end) : (row += 1) app.draw_row(cx, row);
        cx.skip(@as(f32, @floatFromInt(row_count - range.end)) * row_px);
        cx.end_view();
        _ = cx.end();
    }

    /// One row: its area, a highlight when selected or hovered, and its name.
    fn draw_row(app: *const App, cx: *Context, row: u32) void {
        assert(row < row_count);
        const rect = cx.walk(ui.sized(.fill, .{ .fixed = row_px }));
        const clip = cx.visible(rect) orelse return;
        const id = ui.id("row", row);
        cx.area(id, rect, 0, ui.cx.plain);
        const selected = app.selected != null and app.selected.? == row;
        if (selected or cx.hovered() == id) {
            kit.face(cx, rect, clip, .{ .fill = if (selected) selected_fill else theme.chrome.track, .radius = 4 });
        }
        var bytes: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&bytes, "row {d:0>2}", .{row}) catch unreachable;
        kit.label(cx, status_style, name, ui.cx.inset(rect, .xy(row_inset_px, 0)), clip, start);
    }

    fn select(app: *App, cx: *Context, row: u32) void {
        assert(row < row_count);
        app.selected = row;
        var bytes: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&bytes, "{d}", .{row}) catch unreachable;
        app.note(cx, &.{ "row ", name, " selected" });
        assert(app.selected.? == row);
    }

    /// Writes `parts` to the status line and owes a draw.
    fn note(app: *App, cx: *Context, parts: []const []const u8) void {
        app.set_status(parts);
        cx.redraw();
    }

    /// Joins `parts` into the status buffer, cut at `status_cap`.
    fn set_status(app: *App, parts: []const []const u8) void {
        var used: u32 = 0;
        for (parts) |part| {
            const take: u32 = @intCast(@min(part.len, status_cap - used));
            @memcpy(app.status[used..][0..take], part[0..take]);
            used += take;
        }
        @memset(app.status[used..], 0);
        app.status_len = used;
        assert(app.status_len <= status_cap);
    }
};

/// A caption line above a control.
fn caption(cx: *Context, words: []const u8) void {
    const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
    const clip = cx.visible(line) orelse return;
    kit.label(cx, caption_style, words, line, clip, start);
}

/// The decimal digit of `index`, below 10.
fn digit(index: usize) []const u8 {
    assert(index < 10);
    return "0123456789"[index..][0..1];
}

/// `interact` (module guide, section 4). Slider 0 is pressed at its knob (value 0.25 on a
/// 272 px slider: x = 12 + 0.25 * 248 = 74) and moved 80 px; knob 1's 40 px ring is pressed
/// at its centre and moved up 30 px, a quarter of `drag_span_px`.
const interact_steps = [_]bench.Step{
    .{ .click = bench.area("button", 0) },
    .{ .drag = .{ .target = bench.area("slider", 0), .from_x = 74, .from_y = 12, .dx = 80, .dy = 0 } },
    .{ .click = bench.area("toggle", 1) },
    .{ .drag = .{ .target = bench.area("knob", 1), .from_x = 20, .from_y = 20, .dx = 0, .dy = -30 } },
    .{ .click = bench.area("field", 0) },
    .{ .key = .{ .key = .a, .text = "a" } },
    .{ .key = .{ .key = .b, .text = "b" } },
    .{ .key = .{ .key = .c, .text = "c" } },
    .{ .wheel = .{ .target = bench.area("view", 0), .dx = 0, .dy = 3 * row_px } },
    .{ .click = bench.area("row", 5) },
    .{ .wait = 12 },
};

/// `hover`: the pointer rests on button 1 until its hover animator settles (100 ms).
const hover_steps = [_]bench.Step{
    .{ .hover = .{ .target = bench.area("button", 1), .x = 80, .y = 20 } },
    .{ .wait = 12 },
};

comptime {
    // The bands' widths: the knob group fits four cells exactly.
    const inner_w = screen_w - 2 * screen_padding;
    assert(inner_w - narrow_px - sliders_px - 2 * gap_px == 4 * knob_cell_px + 2 * group_padding);
    // Three 40 px buttons or toggles with two gaps fill a band's inner height.
    assert(3 * button_px + 2 * gap_px == band_px - 2 * group_padding);
    assert(3 * widgets.toggle_height + 2 * gap_px == band_px - 2 * group_padding);
    // The list takes what remains: 240 px, a 224 px viewport.
    const list_h = screen_h - 2 * screen_padding - title_px - 2 * band_px - 3 * gap_px;
    assert(list_h == 240);
    assert(@ceil((list_h - 2 * group_padding) / row_px) + 1 == rows_drawn_max);
    for (knob_rings) |ring| assert(ring <= widgets.knob_height);
    // Faces: title, 7 groups, 3 buttons, 3 per slider, 2 per toggle, 2 meter, 3 field, 2
    // highlighted rows, the thumb.
    assert(1 + 7 + 3 + 3 * 2 + 2 * 3 + 2 + 3 + 2 + 1 <= box_cap);
    assert(2 * knob_names.len <= arc_cap);
    // Areas: every widget, the view and its thumb, and the rows drawn.
    assert(3 + 2 + 4 + 3 + 1 + 2 + rows_drawn_max <= area_cap);
    assert(knob_names.len <= 10 and button_labels.len <= 10);
}

// ------------------------------------------------------------------------------------ tests

/// The test context: static, like the hosts', so its pools stay off the stack.
var test_context: Context = undefined;

fn new_app() *App {
    const static = struct {
        var app: App = undefined;
    };
    test_context.init();
    App.init(&static.app, &test_context.draw.textures);
    return &static.app;
}

/// Draws a 1280 by 720 frame the way a host does after a resize.
fn frame(app: *App) *Context {
    test_context.redraw();
    assert(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
    assert(test_context.draw.overflow_count == 0);
    return &test_context;
}

fn area_rect(id: ui.Id) Rect {
    const values = test_context.find(id).?.rect;
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

// Locks the layout of section 2: the title face, the first button and slider, the knob rings
// centered in the knob band (56, 40, 56, 72 px), the first toggle's pill, the field, the
// list's viewport, and that the first frame leaves nothing owed.
test "gallery layout at 1280 by 720" {
    const app = new_app();
    const cx = frame(app);
    try expect_rect(area_rect(app.buttons[0].id), 24, 72, 160, 40);
    try expect_rect(area_rect(app.sliders[0].id), 208, 100, 272, 24);
    // Knob cells start at 16 + 176 + 8 + 288 + 8 + 8 = 504; the 72 px rows sit at
    // 64 + 8 + (136 - 72) / 2 = 104, and each ring is centered in its row.
    try expect_rect(area_rect(app.knobs[0].id), 512, 112, 56, 56);
    try expect_rect(area_rect(app.knobs[1].id), 652, 120, 40, 40);
    try expect_rect(area_rect(app.knobs[3].id), 932, 104, 72, 72);
    try expect_rect(area_rect(app.toggles[0].id), 32, 240, 44, 24);
    try expect_rect(area_rect(field_id), 392, 260, 240, 32);
    try expect_rect(app.view.viewport, 24, 392, 1040, 224);
    try std.testing.expectEqual(@as(f32, 1120), app.view.content_h);
    try expect_rect(area_rect(ui.id("row", 0)), 24, 392, 1040 - ui.view.gutter_px, 28);
    // 224 / 28: rows 0 to 7 fill the viewport exactly, so row 8 is not drawn.
    try std.testing.expect(cx.find(ui.id("row", 7)) != null);
    try std.testing.expect(cx.find(ui.id("row", 8)) == null);
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!ui.draw_frame(App, app, cx, 1280, 720, 120));
}

// Locks the `interact` scenario (section 4) replayed headless through `ui.dispatch` and
// `ui.draw_frame`: every value it leaves, the status line of its last action, and no overflow.
test "the interact scenario leaves the expected values" {
    const app = new_app();
    _ = frame(app);
    const interact = bench.find(App.scenarios, "interact").?;
    const steps = try bench.replay_headless(App, app, &test_context, interact, .{ 1280, 720 }, interact_steps.len + 1);
    try std.testing.expectEqual(@as(u32, interact_steps.len + 1), steps);
    // Slider 0: pressed at 74 (unchanged 0.25), released at 154: (154 - 12) / 248.
    try std.testing.expectEqual(@as(f32, 142.0 / 248.0), app.sliders[0].value);
    try std.testing.expectEqual(app.sliders[0].value, app.meter.value);
    try std.testing.expect(app.toggles[1].on == !toggle_values[1]);
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[1].value);
    try std.testing.expectEqualStrings("abc", app.field.bytes());
    try std.testing.expectEqual(@as(f32, 3 * row_px), app.view.scroll_y);
    try std.testing.expectEqual(@as(?u32, 5), app.selected);
    try std.testing.expectEqualStrings("row 5 selected", app.status_text());
    try std.testing.expectEqual(ui.Id.none, test_context.focus);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks each widget's status line: a click, a slider, a knob, and a toggle report as section 1
// says.
test "each action reports on the status line" {
    const app = new_app();
    _ = frame(app);
    const press = area_rect(app.buttons[2].id);
    const point: input.Point = .{ .x = press.x + 10, .y = press.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    try std.testing.expectEqualStrings("button 2 clicked", app.status_text());
    const ring = area_rect(app.knobs[2].id);
    const wheel: input.Wheel = .{ .x = ring.x + 20, .y = ring.y + 20, .dx = 0, .dy = 30 };
    ui.dispatch(App, app, &test_context, .{ .wheel = wheel });
    try std.testing.expectEqualStrings("knob 2 changed 0.50", app.status_text());
    _ = frame(app);
    const pill = area_rect(app.toggles[0].id);
    const on: input.Point = .{ .x = pill.x + 10, .y = pill.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(on) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(on) });
    try std.testing.expectEqualStrings("toggle 0 on", app.status_text());
}

// Locks the hover scenario: the pointer stays on button 1, so its hover aims at 1 and the
// replay never leaves the window.
test "the hover scenario keeps button 1 hovered" {
    const app = new_app();
    _ = frame(app);
    const hover = bench.find(App.scenarios, "hover").?;
    _ = try bench.replay_headless(App, app, &test_context, hover, .{ 1280, 720 }, 3);
    try std.testing.expectEqual(@as(f32, 1), app.buttons[1].hover.target);
    try std.testing.expectEqual(app.buttons[1].id, test_context.hovered());
}

comptime {
    patchwork.app.check(App);
}

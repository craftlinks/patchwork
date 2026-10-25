//! Gallery example: every library widget on one screen, built only from the kit.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The regression app of phases 6 and 7: each step of those phases adds a section here. It is
//! written with `widgets.kit` and the layout defaults only (one-statement containers, no Box
//! literal, no private append helper), so it is also the template for an app's own screens.
//! Every widget reports its last action on the status line, for example "knob 1 changed 0.75".
//! A "light" toggle in the title bar switches the app between `theme.dark` and `theme.light`
//! with `cx.set_theme` (section 3a). A hardware row shows the same knob, button, and toggle
//! behaviour in the gallery's own skin (section 3b). A popups column right of the screen shows
//! the overlay model: a dropdown, a "File" menu, a context menu, tooltips on every knob, and an
//! About dialog (section 3c).
//!
//! ## 2. Layout (logical pixels)
//! A fixed `screen_w` by `screen_h` screen from the top-left, so it fits the 1280 by 720
//! browser viewport and a native dump and a browser screenshot compare region for region:
//! ```text
//! screen   1088 x 704 at (0, 0), flow down, padding 16, spacing 8
//!   title  fill x 40        "gallery", the "light" toggle (160 x 40 at x 156), the status
//!   band   fill x 152       buttons (176) | sliders (288) | knobs (fill: 4 cells of 140)
//!   band   fill x 152       toggles (176) | meter (176)   | text field (fill; field 240 x 32)
//!   row    fill x 88        hardware: 4 knob cells of 140 | 2 buttons of 96 | 2 toggles of 116
//!   list   fill x 208       a view of 40 rows of 28, the selected row highlighted
//! popups   184 x 672 at (1080, 16), flow down, padding 8, spacing 8
//!   caption 20 | "wave" dropdown 32 | "File" button 40 | right-click panel 120
//!   "flip" dropdown 168 x 32 at (1088, 632): 40 px above the frame's bottom
//! ```
//! The frame, `(0, 0, 1280, 704)`, is the 1280 by 720 browser viewport's width and the screen's
//! height. The popups column sits right of the screen's own 1088 px, so the screen's pixels are
//! the same as without it.
//! Each group is a `Panel` with padding 8 that clips its children. The knobs have rings of 56,
//! 40, 56, and 72 (`Knob.sized`) in 72 px rows, the hardware knobs 56, 48, 64, and 72; the
//! hardware row spaces its widgets by 8 and centers them vertically; the meter follows
//! slider 0.
//!
//! ## 3. Events
//! `event` hands every event to each widget itself, because the status line needs each
//! action (`ui.route` returns only how many acted), then to the view (it takes its id), then
//! to the rows it drew last through `kit.clicked`, which also repaints a row on hover. The
//! default and hardware rows share one routine per widget kind (`knob_events`, ...), since a
//! skinned widget has the default one's behaviour and actions.
//!
//! ## 3a. Theme
//! Everything the gallery draws reads `cx.theme()`: the group faces, the text styles, the
//! highlighted rows, and the widgets themselves. Colors stored in widgets (the sliders'
//! paints, the knobs' accents, the field's text style) are restyled from the scheme when the
//! toggle switches it (`restyle`), so they follow it too. The buttons keep their own blue
//! paint and light label in both themes: an instance color wins over the scheme.
//!
//! ## 3b. Hardware Skin
//! `HardKnob`, `HardButton`, and `HardToggle` are `widgets.KnobOf(hardware.Skin)` and its
//! siblings: the library behaviour with the look of `hardware.zig` (a `Dial` with a drop
//! shadow, `Bevel` faces, the rack's `Led`), registered in `config.draw`. They take presses on
//! the dial's body, the bevel, and the housing, and report as "hardware knob 0 changed 0.83".
//! Their accents are restyled with the default knobs'.
//!
//! ## 3c. Popups
//! The popups draw last: `draw` ends with `ui.overlays(cx, app)`, which reaches the two
//! dropdowns, the File menu, the context menu, the About dialog, and the tooltip, in field
//! order. Each popup is placed inside `frame` (`bounds`), not the window, because the native
//! window is larger than the frame and the compositor picks its size, which would move a popup
//! that flips at the window's edge. The "flip" dropdown sits 40 px above the frame's bottom, so
//! its list opens above it. The File menu holds New, Open…, Save, Save as… (disabled),
//! About…, and Quit; About… opens a modal dialog centered in the frame over a dimmed backdrop,
//! closed by its Close button or Escape. A right press on the panel opens the context menu
//! (Copy, Paste, Reset) at the pointer. Hovering any knob, default or hardware, for
//! `widgets.tooltip_delay_ms` shows "name value" beside its ring. An outside press only
//! dismisses: the button under it does not click.
//!
//! ## 4. Scenarios
//! `still`; `interact` (click button 0, drag slider 0 by +80 px, click toggle 1, drag knob 1
//! by -30 px, click the field and type "abc", wheel the list by 3 rows, click row 5, then let
//! the animations settle); `hover` (hover button 1, then wait for its animator to settle);
//! `light` (click the "light" toggle, click the field, type "abc", select it by dragging
//! across it, then wait for the animations to settle, so the light theme shows the focus ring,
//! the selection band, and the caret); `hardware` (drag hardware knob 0 up 40 px, click
//! hardware button 1, flip hardware toggle 0, then settle). Popups (section 3c): `dropdown`
//! (click the wave dropdown, Down twice, Enter: "dropdown changed 2", closed); `menu-open`
//! (click File, wait 2); `menu-flip` (click the flip dropdown, wait 2: its list above it);
//! `context` (right-click the panel, click Reset); `dismiss` (open the File menu, click button
//! 0 through the backdrop: no click, the menu closed); `tooltip` (hover knob 0 for 40 frames);
//! `about` (choose About… from the File menu: the dialog over the dimmed screen). The app tests
//! replay `interact`, `light`, `hardware`, and the popup scenarios headless and check every
//! value they leave.
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
const hardware = @import("hardware.zig");

const Rect = quads.Rect;

const screen_w: f32 = 1088;
const screen_h: f32 = 704;
const screen_padding: f32 = 16;
const gap_px: f32 = 8;
const title_px: f32 = 40;
const band_px: f32 = 152;
const hardware_px: f32 = 88;
const group_padding: f32 = 8;
const narrow_px: f32 = 176;
const sliders_px: f32 = 288;
const knob_cell_px: f32 = 140;
const hard_button_px: f32 = 96;
const hard_toggle_px: f32 = 116;
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

/// The frame popups stay inside (section 3c), and the popups column right of the screen.
const frame_w: f32 = 1280;
const frame_rect: Rect = .{ .x = 0, .y = 0, .width = frame_w, .height = screen_h };
const column_x: f32 = screen_w - screen_padding + gap_px;
const column_w: f32 = frame_w - screen_padding - column_x;
const column_h: f32 = screen_h - 2 * screen_padding;
const dropdown_h: f32 = 32;
const scratch_px: f32 = 120;
/// The flip dropdown's bottom is this far above the frame's.
const flip_margin_px: f32 = 40;
const about_size: [2]f32 = .{ 320, 136 };
const about_close_size: [2]f32 = .{ 96, 36 };
/// The About dialog's backdrop alpha.
const about_dim: f32 = 0.4;

const knob_rings = [_]f32{ 56, 40, 56, 72 };
const knob_names = [_][]const u8{ "gain", "tone", "mix", "drive" };
const knob_values = [_]f32{ 0.25, 0.5, 0.75, 0.6 };
const button_labels = [_][]const u8{ "Play", "Stop", "Record" };
const slider_names = [_][]const u8{ "level", "pan" };
const slider_values = [_]f32{ 0.25, 0.5 };
const toggle_names = [_][]const u8{ "mute", "solo", "arm" };
const toggle_values = [_]bool{ false, true, false };

const hard_knob_rings = [_]f32{ 56, 48, 64, 72 };
const hard_knob_names = [_][]const u8{ "freq", "res", "env", "level" };
const hard_knob_values = [_]f32{ 0.5, 0.3, 0.7, 0.85 };
const hard_button_labels = [_][]const u8{ "Tap", "Sync" };
const hard_toggle_names = [_][]const u8{ "power", "bypass" };
const hard_toggle_values = [_]bool{ false, true };

const wave_items = [_][]const u8{ "sine", "triangle", "saw", "square", "noise", "sample & hold" };
const file_items = [_][]const u8{ "New", "Open…", "Save", "Save as…", "About…", "Quit" };
const file_disabled: u32 = 3;
const file_about: u32 = 4;
const context_items = [_][]const u8{ "Copy", "Paste", "Reset" };

/// The hardware row's widgets: the library behaviour in the gallery's skin (`hardware.zig`).
const HardKnob = widgets.KnobOf(hardware.Skin);
const HardButton = widgets.ButtonOf(hardware.Skin);
const HardToggle = widgets.ToggleOf(hardware.Skin);

/// The slider the meter follows.
const meter_slider: u32 = 0;

const view_id = ui.id("view", 0);
const field_id = ui.id("field", 0);
const theme_id = ui.id("theme", 0);
const wave_id = ui.id("wave", 0);
const flip_id = ui.id("flip", 0);
const file_id = ui.id("file", 0);
const file_menu_id = ui.id("file_menu", 0);
const scratch_id = ui.id("scratch", 0);
const context_id = ui.id("context", 0);
const about_id = ui.id("about", 0);
const close_id = ui.id("close", 0);

/// The "light" toggle's box in the title bar: right of "gallery", one toggle row high.
const theme_toggle_x: f32 = 156;
const theme_toggle_w: f32 = 160;

const panel_radius: f32 = 8;
const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
/// The buttons' label: the dark scheme's text in both themes, on their own blue (section 3a).
const button_style: text.Style = .{ .face = .sans, .size = 16, .color = theme.dark.colors.text };
/// The hardware buttons' bevel face: a dark grey that keeps its light label readable in both
/// themes.
const hard_button_paint: widgets.Paint = .{ .r = 0.32, .g = 0.34, .b = 0.38, .a = 1, .radius = 6 };

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };

/// The rows: 40 of 28 px in the list's view.
const rows: ui.List = .{ .row_height = row_px, .count = row_count };
/// Rows one viewport can show partly: `ceil(192 / 28) + 1`.
const rows_drawn_max: u32 = 8;

/// Pool and area capacities; the comptime block checks them against the counts.
const box_cap: u32 = 64;
const arc_cap: u32 = 16;
const glyph_cap: u32 = 640;
const path_cap: u32 = 4;
const point_cap: u32 = 16;
const dial_cap: u32 = 8;
const bevel_cap: u32 = 8;
const led_cap: u32 = 4;
const area_cap: u32 = 56;

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
    /// The title bar's "light" toggle: on is `theme.light`.
    light: widgets.Toggle,
    buttons: [button_labels.len]widgets.Button,
    sliders: [slider_names.len]widgets.Slider,
    knobs: [knob_names.len]widgets.Knob,
    toggles: [toggle_names.len]widgets.Toggle,
    hard_knobs: [hard_knob_names.len]HardKnob,
    hard_buttons: [hard_button_labels.len]HardButton,
    hard_toggles: [hard_toggle_names.len]HardToggle,
    meter: widgets.Meter,
    field: widgets.TextField,
    /// The popups column (section 3c). Overlays draw in this field order.
    wave: widgets.Dropdown,
    flip: widgets.Dropdown,
    file: widgets.Button,
    file_menu: widgets.Menu,
    context: widgets.ContextMenu,
    about: About,
    tooltip: widgets.Tooltip,
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
            .{ .type = hardware.Dial, .cap = dial_cap },
            .{ .type = hardware.Bevel, .cap = bevel_cap },
            .{ .type = hardware.Led, .cap = led_cap },
            .{ .type = quads.Path, .cap = path_cap },
        },
        .area_cap = area_cap,
        .point_cap = point_cap,
    };

    pub const scenarios: []const bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{ .name = "interact", .setup = &interact_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hover", .setup = &hover_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "light", .setup = &light_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hardware", .setup = &hardware_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dropdown", .setup = &dropdown_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "menu-open", .setup = &menu_open_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "menu-flip", .setup = &menu_flip_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "context", .setup = &context_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dismiss", .setup = &dismiss_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "tooltip", .setup = &tooltip_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "about", .setup = &about_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
    };

    /// The widgets at their starting values, styled from `config.theme`; the gallery creates
    /// no textures.
    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        app.light = widgets.Toggle.init(theme_id, "light", false);
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
                .track = undefined,
                .fill = undefined,
                .knob = undefined,
            };
        }
        for (&app.knobs, knob_names, knob_values, knob_rings, 0..) |*knob, name, value, ring, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            knob.* = widgets.Knob.init(ui.id("knob", @intCast(index)), name, value, accent).sized(ring);
        }
        for (&app.toggles, toggle_names, toggle_values, 0..) |*toggle, name, on, index| {
            toggle.* = widgets.Toggle.init(ui.id("toggle", @intCast(index)), name, on);
        }
        for (&app.hard_knobs, hard_knob_names, hard_knob_values, hard_knob_rings, 0..) |*knob, name, value, ring, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            knob.* = HardKnob.init(ui.id("hknob", @intCast(index)), name, value, accent).sized(ring);
        }
        for (&app.hard_buttons, hard_button_labels, 0..) |*button, label, index| {
            button.* = .{
                .id = ui.id("hbutton", @intCast(index)),
                .label = label,
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = hard_button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            };
        }
        for (&app.hard_toggles, hard_toggle_names, hard_toggle_values, 0..) |*toggle, name, on, index| {
            toggle.* = HardToggle.init(ui.id("htoggle", @intCast(index)), name, on);
        }
        app.meter = .{ .name = "level", .value = slider_values[meter_slider], .track_h = meter_track_px };
        app.field = widgets.TextField.init(field_id, 32, field_style(&config.theme));
        app.view = ui.ViewState.init();
        app.wave = widgets.Dropdown.init(wave_id, &wave_items, 0);
        app.wave.menu.bounds = frame_rect;
        app.flip = widgets.Dropdown.init(flip_id, &wave_items, 0);
        app.flip.menu.bounds = frame_rect;
        app.file = .{
            .id = file_id,
            .label = "File",
            .style = button_style,
            .padding = .xy(12, 0),
            .paint = button_paint,
            .hover = .init(widgets.hover_rate_per_ms),
            .down = .init(widgets.down_rate_per_ms),
        };
        app.file_menu = widgets.Menu.init(file_menu_id, &file_items);
        app.file_menu.set_enabled(file_disabled, false);
        app.file_menu.bounds = frame_rect;
        app.context = widgets.ContextMenu.init(context_id, &context_items);
        app.context.menu.bounds = frame_rect;
        app.about = About.init();
        app.tooltip = widgets.Tooltip.init();
        app.tooltip.bounds = frame_rect;
        app.drawn = .{ .first = 0, .end = 0 };
        app.selected = null;
        app.status = @splat(0);
        app.status_len = 0;
        app.set_status(&.{"ready"});
        app.restyle(&config.theme);
        assert(app.knobs[3].ring == 72);
        assert(!app.toggles[0].on);
    }

    /// Every widget, the view, then the rows drawn last (module guide, section 3).
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.light.handle(cx, event_value)) {
            .toggled => |on| {
                cx.set_theme(if (on) theme.light else theme.dark);
                app.restyle(cx.theme());
                app.note(cx, &.{ "theme ", if (on) "light" else "dark" });
            },
            .none => {},
        }
        app.button_events(cx, "", &app.buttons, event_value);
        app.button_events(cx, "hardware ", &app.hard_buttons, event_value);
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
        app.knob_events(cx, "", &app.knobs, event_value);
        app.knob_events(cx, "hardware ", &app.hard_knobs, event_value);
        app.toggle_events(cx, "", &app.toggles, event_value);
        app.toggle_events(cx, "hardware ", &app.hard_toggles, event_value);
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
        app.popup_events(cx, event_value);
        assert(app.status_len <= status_cap);
    }

    /// The popups column (section 3c): the dropdowns, the File button and its menu, the context
    /// menu over the panel, the About dialog, and the knobs' tooltip.
    fn popup_events(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.wave.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "dropdown changed ", digit(index) }),
            .none => {},
        }
        switch (app.flip.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "flip changed ", digit(index) }),
            .none => {},
        }
        if (app.file.handle(cx, event_value) == .clicked) {
            app.file_menu.open_at(cx, .{ .id = file_id }, .below);
            app.note(cx, &.{"file menu"});
        }
        switch (app.file_menu.handle(cx, event_value)) {
            .chosen => |index| {
                app.note(cx, &.{ "file ", file_items[index] });
                if (index == file_about) app.about.show(cx);
            },
            .none, .dismissed => {},
        }
        switch (app.context.handle(cx, event_value, scratch_id)) {
            .chosen => |index| app.note(cx, &.{ "context ", context_items[index] }),
            .none, .dismissed => {},
        }
        if (app.about.handle(cx, event_value)) app.note(cx, &.{"about closed"});
        var bytes: [16]u8 = undefined;
        app.tooltip.handle(cx, event_value, app.hovered_tip(cx, &bytes));
    }

    /// The hovered knob's tip, default or hardware: its id and "name value" in `bytes`.
    fn hovered_tip(app: *const App, cx: *Context, bytes: *[16]u8) ?widgets.Tip {
        const hovered = cx.hovered();
        if (hovered == .none) return null;
        for (&app.knobs) |*knob| {
            if (knob.id == hovered) return tip_of(bytes, knob.id, knob.name, knob.value_text[0..4]);
        }
        for (&app.hard_knobs) |*knob| {
            if (knob.id == hovered) return tip_of(bytes, knob.id, knob.name, knob.value_text[0..4]);
        }
        return null;
    }

    /// Hands `event_value` to each button of `buttons`, default or skinned (they share the
    /// behaviour), and reports a click on the status line after `row`.
    fn button_events(app: *App, cx: *Context, row: []const u8, buttons: anytype, event_value: input.Event) void {
        for (buttons, 0..) |*button, index| {
            if (button.handle(cx, event_value) == .clicked) app.note(cx, &.{ row, "button ", digit(index), " clicked" });
        }
    }

    /// Hands `event_value` to each knob of `knobs` and reports a change or a reset.
    fn knob_events(app: *App, cx: *Context, row: []const u8, knobs: anytype, event_value: input.Event) void {
        for (knobs, 0..) |*knob, index| {
            switch (knob.handle(cx, event_value)) {
                .changed => app.note(cx, &.{ row, "knob ", digit(index), " changed ", knob.value_text[0..4] }),
                .reset => app.note(cx, &.{ row, "knob ", digit(index), " reset ", knob.value_text[0..4] }),
                .none, .released => {},
            }
        }
    }

    /// Hands `event_value` to each toggle of `toggles` and reports a flip.
    fn toggle_events(app: *App, cx: *Context, row: []const u8, toggles: anytype, event_value: input.Event) void {
        for (toggles, 0..) |*toggle, index| {
            switch (toggle.handle(cx, event_value)) {
                .toggled => |on| app.note(cx, &.{ row, "toggle ", digit(index), if (on) " on" else " off" }),
                .none => {},
            }
        }
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
        app.draw_hardware(cx);
        app.draw_list(cx);
        _ = cx.end();
        app.draw_popups(cx);
        ui.overlays(cx, app);
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    /// The colors the widgets store, from `scheme` (section 3a): the sliders' paints, the knobs'
    /// accents, and the field's text style. Under `theme.dark` they are the step 30 values.
    fn restyle(app: *App, scheme: *const theme.Scheme) void {
        for (&app.sliders) |*slider| {
            slider.track = widgets.paint_of(scheme.colors.track, widgets.track_radius);
            slider.fill = widgets.paint_of(scheme.colors.value, widgets.track_radius);
            slider.knob = widgets.paint_of(scheme.colors.control, widgets.knob_radius);
        }
        for (&app.knobs, 0..) |*knob, index| {
            const color = scheme.accents[index % theme.accent_count];
            knob.accent = widgets.paint_of(color, widgets.kit.accent_radius);
        }
        for (&app.hard_knobs, 0..) |*knob, index| {
            const color = scheme.accents[index % theme.accent_count];
            knob.accent = widgets.paint_of(color, widgets.kit.accent_radius);
        }
        app.field.style = field_style(scheme);
        assert(app.sliders[0].track.radius == widgets.track_radius);
        assert(app.field.style.face == .mono);
    }

    /// The status line's text.
    pub fn status_text(app: *const App) []const u8 {
        assert(app.status_len <= status_cap);
        return app.status[0..app.status_len];
    }

    fn draw_title(app: *const App, cx: *Context) void {
        const bar = cx.walk(ui.sized(.fill, .{ .fixed = title_px }));
        const clip = cx.visible(bar) orelse return;
        kit.face(cx, bar, clip, panel_paint(cx).look(cx.theme(), 0, 0));
        const inner = ui.cx.inset(bar, .xy(title_inset_px, 0));
        kit.label(cx, styled(cx, .sans_bold, 18), "gallery", inner, clip, start);
        kit.label(cx, styled(cx, .sans, 14), app.status_text(), inner, clip, end);
        const cell: Rect = .{ .x = bar.x + theme_toggle_x - screen_padding, .y = bar.y, .width = theme_toggle_w, .height = title_px };
        _ = cx.begin_at(cell, .{ .flow = .down });
        app.light.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    fn draw_buttons(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.buttons) |*button| button.draw(cx, ui.sized(.fill, .{ .fixed = button_px }));
        _ = cx.end();
    }

    fn draw_sliders(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = sliders_px }, .fill), group_layout);
        for (&app.sliders, slider_names) |*slider, name| {
            caption(cx, name);
            slider.draw(cx, ui.sized(.fill, .{ .fixed = slider_px }));
        }
        _ = cx.end();
    }

    fn draw_knobs(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const row: ui.Layout = .{ .flow = .right, .padding = .all(group_padding), .alignment = .{ .x = 0, .y = 0.5 }, .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .fill), row);
        const cell = ui.sized(.{ .fixed = knob_cell_px }, .{ .fixed = widgets.knob_height });
        for (&app.knobs) |*knob| knob.draw(cx, cell);
        _ = cx.end();
    }

    fn draw_toggles(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.toggles) |*toggle| toggle.draw(cx, ui.sized(.fill, .{ .fixed = widgets.toggle_height }));
        _ = cx.end();
    }

    fn draw_meter(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        app.meter.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    fn draw_field(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        caption(cx, "name");
        app.field.draw(cx, ui.sized(.{ .fixed = field_w }, .{ .fixed = field_h }));
        _ = cx.end();
    }

    /// The hardware row: four skinned knobs, two buttons, and two toggles in one panel, centered
    /// vertically.
    fn draw_hardware(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const row: ui.Layout = .{ .flow = .right, .spacing = gap_px, .padding = .all(group_padding), .alignment = .{ .x = 0, .y = 0.5 }, .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .{ .fixed = hardware_px }), row);
        const cell = ui.sized(.{ .fixed = knob_cell_px }, .{ .fixed = widgets.knob_height });
        for (&app.hard_knobs) |*knob| knob.draw(cx, cell);
        for (&app.hard_buttons) |*button| button.draw(cx, ui.sized(.{ .fixed = hard_button_px }, .{ .fixed = button_px }));
        for (&app.hard_toggles) |*toggle| toggle.draw(cx, ui.sized(.{ .fixed = hard_toggle_px }, .{ .fixed = widgets.toggle_height }));
        _ = cx.end();
    }

    /// The popups column right of the screen (section 2): its widgets; their popups draw in
    /// `ui.overlays`.
    fn draw_popups(app: *const App, cx: *Context) void {
        const column: Rect = .{ .x = column_x, .y = screen_padding, .width = column_w, .height = column_h };
        const clip = cx.visible(column) orelse return;
        kit.face(cx, column, clip, panel_paint(cx).look(cx.theme(), 0, 0));
        _ = cx.begin_at(column, group_layout);
        caption(cx, "popups");
        app.wave.draw(cx, ui.sized(.fill, .{ .fixed = dropdown_h }));
        app.file.draw(cx, ui.sized(.fill, .{ .fixed = button_px }));
        const scratch = cx.walk(ui.sized(.fill, .{ .fixed = scratch_px }));
        if (cx.visible(scratch)) |inside| {
            kit.face(cx, scratch, inside, .{ .fill = cx.theme().colors.track, .radius = 6 });
            cx.area(scratch_id, scratch, 6, ui.cx.plain);
            kit.label(cx, styled(cx, .sans, 14), "right-click me", scratch, inside, widgets.centered);
        }
        const flip: Rect = .{
            .x = column_x + group_padding,
            .y = frame_rect.height - flip_margin_px - dropdown_h,
            .width = column_w - 2 * group_padding,
            .height = dropdown_h,
        };
        _ = cx.begin_at(flip, .{ .flow = .down });
        app.flip.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.end();
    }

    /// The list: a view of the visible rows only, standing in for the others with `skip`.
    fn draw_list(app: *App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
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
            const colors = &cx.theme().colors;
            kit.face(cx, rect, clip, .{ .fill = if (selected) colors.selection else colors.track, .radius = 4 });
        }
        var bytes: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&bytes, "row {d:0>2}", .{row}) catch unreachable;
        kit.label(cx, styled(cx, .sans, 14), name, ui.cx.inset(rect, .xy(row_inset_px, 0)), clip, start);
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

/// The About dialog (section 3c): a modal popup centered in the frame over a dimmed backdrop,
/// with a Close button. Escape closes it too; a press on the backdrop does nothing.
const About = struct {
    open: bool,
    close: widgets.Button,

    fn init() About {
        return .{
            .open = false,
            .close = .{
                .id = close_id,
                .label = "Close",
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            },
        };
    }

    /// Opens the dialog and requests its popup.
    fn show(self: *About, cx: *Context) void {
        assert(!self.open);
        self.open = true;
        cx.request_popup(about_id);
    }

    /// True on the event that closed it.
    fn handle(self: *About, cx: *Context, event_value: input.Event) bool {
        if (event_value == .frame) {
            _ = self.close.handle(cx, event_value);
            return false;
        }
        if (!self.open) return false;
        const clicked = self.close.handle(cx, event_value) == .clicked;
        const escape = event_value == .key_down and event_value.key_down.key == .escape;
        if (!clicked and !escape) return false;
        self.open = false;
        cx.redraw();
        return true;
    }

    pub fn draw_overlay(self: *const About, cx: *Context) void {
        if (!self.open) return;
        const rect = ui.popup.centered(about_size, frame_rect);
        _ = cx.begin_popup(about_id, rect, .{ .flow = .down, .spacing = gap_px, .padding = .all(16), .clip = true }, about_dim);
        const clip = cx.clip().?;
        kit.face(cx, rect, clip, .{
            .fill = cx.theme().colors.panel,
            .border_color = cx.theme().colors.control,
            .border_width = 1,
            .radius = panel_radius,
        });
        const title = cx.walk(ui.sized(.fill, .{ .fixed = 24 }));
        kit.label(cx, styled(cx, .sans_bold, 18), "patchwork gallery", title, clip, start);
        const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
        kit.label(cx, styled(cx, .sans, 14), "Every widget, skin, and popup.", line, clip, start);
        cx.skip(gap_px);
        self.close.draw(cx, ui.sized(.{ .fixed = about_close_size[0] }, .{ .fixed = about_close_size[1] }));
        cx.end_popup();
    }
};

/// A tip for knob `id`: "name value" written into `bytes`.
fn tip_of(bytes: *[16]u8, id: ui.Id, name: []const u8, value: []const u8) widgets.Tip {
    assert(name.len + 1 + value.len <= bytes.len);
    @memcpy(bytes[0..name.len], name);
    bytes[name.len] = ' ';
    @memcpy(bytes[name.len + 1 ..][0..value.len], value);
    return .{ .anchor = id, .text = bytes[0 .. name.len + 1 + value.len] };
}

/// A caption line above a control.
fn caption(cx: *Context, words: []const u8) void {
    const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
    const clip = cx.visible(line) orelse return;
    kit.label(cx, styled(cx, .sans, 14), words, line, clip, start);
}

/// The group faces' paint: the scheme's panel color.
fn panel_paint(cx: *Context) widgets.Paint {
    return widgets.paint_of(cx.theme().colors.panel, panel_radius);
}

/// Text in `face` at `size` in the scheme's text color: the title, status, captions, and rows.
fn styled(cx: *Context, face: text.Face, size: f32) text.Style {
    assert(size > 0);
    return .{ .face = face, .size = size, .color = cx.theme().colors.text };
}

/// The field's text: Noto Sans Mono 16 in the scheme's text color.
fn field_style(scheme: *const theme.Scheme) text.Style {
    return .{ .face = .mono, .size = 16, .color = scheme.colors.text };
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

/// `light`: switch to the light theme, focus the field and type "abc", then select it by a
/// drag from before its first glyph (x 4 of 240) to past its last (x 64), which selects all
/// three bytes however the press counts as a click; the pointer rests over the field.
const light_steps = [_]bench.Step{
    .{ .click = bench.area("theme", 0) },
    .{ .click = bench.area("field", 0) },
    .{ .key = .{ .key = .a, .text = "a" } },
    .{ .key = .{ .key = .b, .text = "b" } },
    .{ .key = .{ .key = .c, .text = "c" } },
    .{ .drag = .{ .target = bench.area("field", 0), .from_x = 4, .from_y = 16, .dx = 60, .dy = 0 } },
    .{ .wait = 12 },
};

/// `hardware`: drag hardware knob 0 (a 56 px dial) from its center up 40 px, a third of
/// `drag_span_px` (0.50 to 0.83), click hardware button 1, flip hardware toggle 0, then let the
/// animations settle.
const hardware_steps = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("hknob", 0), .from_x = 19, .from_y = 19, .dx = 0, .dy = -40 } },
    .{ .click = bench.area("hbutton", 1) },
    .{ .click = bench.area("htoggle", 0) },
    .{ .wait = 12 },
};

/// The context menu's row `index`, a click target of the `context` scenario.
fn context_row(index: u32) bench.Target {
    return .{ .id = context_id.derive(index), .name = "context row", .index = index };
}

/// The File menu's row `index`.
fn file_row(index: u32) bench.Target {
    return .{ .id = file_menu_id.derive(index), .name = "file row", .index = index };
}

/// `dropdown`: open the wave dropdown, Down twice from "sine", Enter: "dropdown changed 2".
const dropdown_steps = [_]bench.Step{
    .{ .click = bench.area("wave", 0) },
    .{ .key = .{ .key = .down, .text = "" } },
    .{ .key = .{ .key = .down, .text = "" } },
    .{ .key = .{ .key = .enter, .text = "" } },
    .{ .wait = 12 },
};

/// `menu-open`: the File menu open below its button.
const menu_open_steps = [_]bench.Step{
    .{ .click = bench.area("file", 0) },
    .{ .wait = 2 },
};

/// `menu-flip`: the flip dropdown's list, which has no room below it in the frame, above it.
const menu_flip_steps = [_]bench.Step{
    .{ .click = bench.area("flip", 0) },
    .{ .wait = 2 },
};

/// `context`: a right click 40 px into the panel opens the context menu there; click Reset.
const context_steps = [_]bench.Step{
    .{ .right_click = .{ .target = bench.area("scratch", 0), .x = 40, .y = 30 } },
    .{ .click = context_row(2) },
    .{ .wait = 12 },
};

/// `dismiss`: open the File menu, then click button 0 through its backdrop: the menu closes,
/// the button does not click, and the status still reads "file menu".
const dismiss_steps = [_]bench.Step{
    .{ .click = bench.area("file", 0) },
    .{ .wait = 2 },
    .{ .click = bench.area("button", 0) },
    .{ .wait = 12 },
};

/// `tooltip`: the pointer rests on knob 0's ring until its tooltip shows (40 frames, 667 ms).
const tooltip_steps = [_]bench.Step{
    .{ .hover = .{ .target = bench.area("knob", 0), .x = 28, .y = 28 } },
    .{ .wait = 40 },
};

/// `about`: choose About… from the File menu: the dialog over the dimmed screen.
const about_steps = [_]bench.Step{
    .{ .click = bench.area("file", 0) },
    .{ .click = file_row(file_about) },
    .{ .wait = 12 },
};

comptime {
    // The popups column: right of the screen's panels, inside the frame.
    assert(column_x == screen_w - screen_padding + gap_px);
    assert(column_x + column_w + screen_padding == frame_w);
    assert(3 * gap_px + caption_px + dropdown_h + button_px + scratch_px + 2 * group_padding < frame_rect.height - flip_margin_px - dropdown_h - screen_padding);
    // The title: the toggle sits right of "gallery" and inside the bar.
    assert(theme_toggle_x + theme_toggle_w < screen_w - screen_padding);
    assert(widgets.toggle_height == title_px);
    // The bands' widths: the knob group fits four cells exactly.
    const inner_w = screen_w - 2 * screen_padding;
    assert(inner_w - narrow_px - sliders_px - 2 * gap_px == 4 * knob_cell_px + 2 * group_padding);
    // Three 40 px buttons or toggles with two gaps fill a band's inner height.
    assert(3 * button_px + 2 * gap_px == band_px - 2 * group_padding);
    assert(3 * widgets.toggle_height + 2 * gap_px == band_px - 2 * group_padding);
    // The hardware row: four knob cells, two buttons, and two toggles with seven gaps fill it.
    assert(4 * knob_cell_px + 2 * hard_button_px + 2 * hard_toggle_px + 7 * gap_px == inner_w - 2 * group_padding);
    assert(widgets.knob_height == hardware_px - 2 * group_padding);
    for (hard_knob_rings) |ring| assert(ring <= widgets.knob_height);
    // The list takes what remains: 208 px, a 192 px viewport.
    const list_h = screen_h - 2 * screen_padding - title_px - 2 * band_px - hardware_px - 4 * gap_px;
    assert(list_h == 208);
    assert(@ceil((list_h - 2 * group_padding) / row_px) + 1 == rows_drawn_max);
    for (knob_rings) |ring| assert(ring <= widgets.knob_height);
    // Faces: title, 7 groups, 3 buttons, 3 per slider, 2 per toggle (the title's too), 2
    // meter, 3 field, 2 highlighted rows, the thumb; the popups column, its two dropdowns,
    // button, and panel; a popup's dim, face, and band or button; the tooltip.
    assert(1 + 8 + 3 + 3 * 2 + 2 * 4 + 2 + 3 + 2 + 1 + 5 + 3 + 1 <= box_cap);
    assert(2 * knob_names.len + hard_knob_names.len <= arc_cap);
    // The hardware row: a dial per knob, a bevel per button and toggle, an LED per toggle.
    assert(hard_knob_names.len <= dial_cap);
    assert(hard_button_labels.len + hard_toggle_names.len <= bevel_cap);
    assert(hard_toggle_names.len <= led_cap);
    // Areas: every widget, the title's toggle, the view and its thumb, the rows drawn, the
    // hardware row, the popups column (two dropdowns, the button, the panel), and one popup:
    // its backdrop and at most six rows (the dialog: its backdrop and its button).
    assert(3 + 2 + 4 + 3 + 1 + 1 + 2 + rows_drawn_max + 4 + 2 + 2 + 4 + 1 + file_items.len <= area_cap);
    assert(wave_items.len >= file_items.len and file_items.len >= context_items.len);
    // Paths: one chevron per dropdown, three points each.
    assert(2 <= path_cap and 2 * 3 <= point_cap);
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
    // The title's toggle: its pill 8 px into its 160 px cell at x 156, centered in the bar.
    try expect_rect(area_rect(theme_id), 164, 24, 44, 24);
    try expect_rect(area_rect(app.sliders[0].id), 208, 100, 272, 24);
    // Knob cells start at 16 + 176 + 8 + 288 + 8 + 8 = 504; the 72 px rows sit at
    // 64 + 8 + (136 - 72) / 2 = 104, and each ring is centered in its row.
    try expect_rect(area_rect(app.knobs[0].id), 512, 112, 56, 56);
    try expect_rect(area_rect(app.knobs[1].id), 652, 120, 40, 40);
    try expect_rect(area_rect(app.knobs[3].id), 932, 104, 72, 72);
    try expect_rect(area_rect(app.toggles[0].id), 32, 240, 44, 24);
    try expect_rect(area_rect(field_id), 392, 260, 240, 32);
    // The hardware row's panel starts at 16 + 40 + 8 + 2 * (152 + 8) = 384, its cells at 392:
    // hardware knob 0's 56 px ring at (32, 400), its dial body 9 px inside it; knob 1's 48 px
    // ring at (180, 404); the buttons after four cells and four gaps at x 616 and 720, centered
    // in the 72 px row; the toggles' housings 8 px into their cells at 824 and 948.
    try expect_rect(area_rect(app.hard_knobs[0].id), 41, 409, 38, 38);
    try std.testing.expectEqual(@as(f32, 19), cx.find(app.hard_knobs[0].id).?.radius);
    try expect_rect(area_rect(app.hard_knobs[1].id), 189, 413, 30, 30);
    try expect_rect(area_rect(app.hard_buttons[0].id), 616, 408, 96, 40);
    try expect_rect(area_rect(app.hard_buttons[1].id), 720, 408, 96, 40);
    try expect_rect(area_rect(app.hard_toggles[0].id), 832, 416, 44, 24);
    try expect_rect(area_rect(app.hard_toggles[1].id), 956, 416, 44, 24);
    try expect_rect(app.view.viewport, 24, 488, 1040, 192);
    try std.testing.expectEqual(@as(f32, 1120), app.view.content_h);
    try expect_rect(area_rect(ui.id("row", 0)), 24, 488, 1040 - ui.view.gutter_px, 28);
    // 192 / 28: row 6 is the last one the viewport shows (partly), so row 7 is not drawn.
    try std.testing.expect(cx.find(ui.id("row", 6)) != null);
    try std.testing.expect(cx.find(ui.id("row", 7)) == null);
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

// Locks the `hardware` scenario (section 4) replayed headless: the dial dragged up 40 px from
// its center moves 40 / 120 from 0.50 to 0.83, hardware button 1 clicked, hardware toggle 0
// on with its thumb (the bevel's press and the LED) aimed at 1; the default row is untouched;
// the faces drew on layer 1 and the LEDs on layer 2, the layer is back at base, and nothing
// overflowed.
test "the hardware scenario drives the skinned row" {
    const app = new_app();
    _ = frame(app);
    const scenario = bench.find(App.scenarios, "hardware").?;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, hardware_steps.len + 1);
    try std.testing.expectEqualStrings("0.83", app.hard_knobs[0].value_text[0..4]);
    try std.testing.expect(app.hard_toggles[0].on);
    try std.testing.expectEqual(@as(f32, 1), app.hard_toggles[0].thumb.target);
    try std.testing.expectEqualStrings("hardware toggle 0 on", app.status_text());
    try std.testing.expectEqual(knob_values[0], app.knobs[0].value);
    try std.testing.expect(!app.toggles[0].on);
    try std.testing.expectEqual(@as(usize, 4), test_context.draw.items(hardware.Dial).len);
    try std.testing.expectEqual(@as(usize, 4), test_context.draw.items(hardware.Bevel).len);
    const leds = test_context.draw.items(hardware.Led);
    try std.testing.expectEqual(@as(usize, 2), leds.len);
    // The replay steps no frames, so toggle 0's LED is still dark and toggle 1's (on) lit.
    try std.testing.expectEqual(@as(f32, 0), leds[0].brightness);
    try std.testing.expectEqual(@as(f32, 1), leds[1].brightness);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(test_context.draw.layer_at(hardware.Dial, 0)));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(test_context.draw.layer_at(hardware.Led, 0)));
    try std.testing.expectEqual(quads.Layer.base, test_context.draw.layer_now);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks the status line of each hardware widget: a hardware button click and a wheel on a
// hardware dial report with the row's prefix.
test "hardware actions report on the status line" {
    const app = new_app();
    _ = frame(app);
    const press = area_rect(app.hard_buttons[0].id);
    const point: input.Point = .{ .x = press.x + 10, .y = press.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    try std.testing.expectEqualStrings("hardware button 0 clicked", app.status_text());
    const body = area_rect(app.hard_knobs[2].id);
    const wheel: input.Wheel = .{ .x = body.x + body.width * 0.5, .y = body.y + body.height * 0.5, .dx = 0, .dy = 12 };
    ui.dispatch(App, app, &test_context, .{ .wheel = wheel });
    try std.testing.expectEqualStrings("hardware knob 2 changed 0.60", app.status_text());
}

// Locks the `light` scenario (section 4) replayed headless: the toggle is on, the context holds
// `theme.light` and its record, the restyled colors follow it (slider 0's track, knob 2's
// accent, the field's text), the field keeps focus with "abc" selected, the drawn rows and
// group faces use the light colors, and nothing overflows. Toggling back restores
// `theme.dark` and the step 30 colors.
test "the light scenario switches the theme and restyles the widgets" {
    const app = new_app();
    _ = frame(app);
    const light = bench.find(App.scenarios, "light").?;
    _ = try bench.replay_headless(App, app, &test_context, light, .{ 1280, 720 }, light_steps.len + 1);
    try std.testing.expect(app.light.on);
    try std.testing.expect(std.meta.eql(theme.light, test_context.theme().*));
    try std.testing.expectEqual(theme.light.colors.background, test_context.draw.theme.background);
    try std.testing.expectEqual(theme.light.colors.track[0], app.sliders[0].track.r);
    try std.testing.expectEqual(theme.light.accents[2][0], app.knobs[2].accent.r);
    try std.testing.expectEqual(theme.light.colors.text, app.field.style.color);
    try std.testing.expectEqual(field_id, test_context.focus);
    try std.testing.expectEqualStrings("abc", app.field.bytes());
    try std.testing.expectEqual(@as(u32, 0), app.field.edit.selection().start);
    try std.testing.expectEqual(@as(u32, 3), app.field.edit.selection().end);
    try std.testing.expectEqualStrings("field abc", app.status_text());
    const boxes = test_context.draw.items(quads.Box);
    try std.testing.expectEqual(theme.light.colors.panel, boxes[0].fill);
    var selection_band = false;
    for (boxes) |box| selection_band = selection_band or std.meta.eql(box.fill, theme.light.colors.selection);
    try std.testing.expect(selection_band);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    test_context.event_begin(.{ .frame = 0 });
    app.restyle(&theme.dark);
    test_context.set_theme(theme.dark);
    test_context.event_end();
    try std.testing.expectEqual(widgets.accents[2], app.knobs[2].accent);
    try std.testing.expectEqual(theme.dark.colors.track[0], app.sliders[0].track.r);
}

/// Replays the popup scenario `name` headless (all its setup steps) and draws once more.
fn replay(app: *App, name: []const u8) !void {
    const scenario = bench.find(App.scenarios, name).?;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1));
    _ = frame(app);
}

/// The rect of the area `id` in the last frame.
fn area_of(id: ui.Id) Rect {
    return area_rect(id);
}

// Locks the `dropdown` scenario (section 4): the click opens the wave list with "sine"
// highlighted, Down twice and Enter choose "saw" (2), the status reads "dropdown changed 2",
// the list is closed, and focus is back on the dropdown.
test "the dropdown scenario changes the wave to 2" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "dropdown");
    try std.testing.expectEqual(@as(u32, 2), app.wave.selected);
    try std.testing.expectEqualStrings("dropdown changed 2", app.status_text());
    try std.testing.expect(!app.wave.menu.open);
    try std.testing.expectEqual(wave_id, test_context.focus);
    try std.testing.expect(test_context.find(test_context.popup_backdrop(app.wave.menu.id)) == null);
}

// Locks the popups' placement (section 3c): the File menu's first row is 2 + 4 px below the
// File button on the popup layer over a backdrop covering the window; the flip dropdown's list
// opens above it (its last row ends 2 + 4 px above the dropdown), inside the frame.
test "the file menu opens below its button and the flip list above its dropdown" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "menu-open");
    try std.testing.expect(app.file_menu.open);
    const button = area_of(file_id);
    const row0 = test_context.find(file_menu_id.derive(0)).?;
    try std.testing.expectEqual(button.x, row0.rect[0]);
    try std.testing.expectEqual(button.y + button.height + ui.popup.popup_gap + widgets.menu_pad_y, row0.rect[1]);
    try std.testing.expectEqual(@as(u8, 6), row0.layer);
    const backdrop = test_context.find(test_context.popup_backdrop(file_menu_id)).?;
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 1280, 720 }, &backdrop.rect);
    const flip_app = new_app();
    _ = frame(flip_app);
    try replay(flip_app, "menu-flip");
    const face = area_of(flip_id);
    try std.testing.expectEqual(@as(f32, 704 - 40 - 32), face.y);
    const last = test_context.find(flip_app.flip.menu.id.derive(wave_items.len - 1)).?;
    try std.testing.expectEqual(face.y - ui.popup.popup_gap - widgets.menu_pad_y, last.rect[1] + last.rect[3]);
    const first = test_context.find(flip_app.flip.menu.id.derive(0)).?;
    try std.testing.expect(first.rect[1] >= ui.popup.popup_margin);
    try std.testing.expect(first.rect[0] + first.rect[2] <= frame_w - ui.popup.popup_margin);
}

// Locks the `context` and `dismiss` scenarios (section 3c): a right click on the panel opens
// the context menu at the pointer and Reset chooses item 2; a click on button 0 through the
// File menu's backdrop closes the menu and does not click the button.
test "the context menu chooses Reset and an outside click only dismisses" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "context");
    try std.testing.expectEqualStrings("context Reset", app.status_text());
    try std.testing.expect(!app.context.menu.open);
    const dismiss = new_app();
    _ = frame(dismiss);
    try replay(dismiss, "dismiss");
    try std.testing.expect(!dismiss.file_menu.open);
    try std.testing.expectEqualStrings("file menu", dismiss.status_text());
    try std.testing.expectEqual(@as(f32, 0), dismiss.buttons[0].down.target);
}

// Locks the `tooltip` scenario (section 3c): hovering knob 0 shows nothing until the dwell
// completes; after 500 ms of frames "gain 0.25" shows to the right of its ring on the
// tooltip layer, inside the frame, and no area was added.
test "the tooltip scenario shows the knob's name and value beside it" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "tooltip");
    const areas_before = test_context.area_list().len;
    try std.testing.expect(!app.tooltip.visible());
    var frames: u32 = 0;
    while (frames < 31) : (frames += 1) _ = ui.animate(App, app, &test_context, 1000.0 / 60.0);
    try std.testing.expect(app.tooltip.visible());
    try std.testing.expectEqualStrings("gain 0.25", app.tooltip.text_of());
    _ = frame(app);
    try std.testing.expectEqual(areas_before, test_context.area_list().len);
    const boxes = test_context.draw.items(quads.Box);
    const last = boxes.len - 1;
    try std.testing.expectEqual(quads.Layer.tooltip, test_context.draw.layer_at(quads.Box, @intCast(last)));
    const ring = area_of(app.knobs[0].id);
    try std.testing.expectEqual(ring.x + ring.width + ui.popup.popup_gap, boxes[last].rect[0]);
    try std.testing.expectEqual(ring.y, boxes[last].rect[1]);
}

// Locks the `about` scenario (section 3c): About… opens the dialog centered in the frame over a
// black face at alpha 0.4 covering the window; a press on the backdrop leaves it open, Close
// closes it with "about closed".
test "the about dialog is modal and closes on its button" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "about");
    try std.testing.expect(app.about.open);
    try std.testing.expectEqualStrings("file About…", app.status_text());
    var dimmed = false;
    for (test_context.draw.items(quads.Box)) |box| {
        dimmed = dimmed or std.meta.eql(box.fill, [4]f32{ 0, 0, 0, about_dim });
    }
    try std.testing.expect(dimmed);
    const close = area_of(close_id);
    try std.testing.expectEqual(@as(f32, 480 + 16), close.x);
    const outside: input.Point = .{ .x = 20, .y = 20 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(outside) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(outside) });
    try std.testing.expect(app.about.open);
    const press: input.Point = .{ .x = close.x + 10, .y = close.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_move = press });
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(press) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(press) });
    try std.testing.expect(!app.about.open);
    try std.testing.expectEqualStrings("about closed", app.status_text());
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

const Renderer = patchwork.renderer.Renderer(Context.DrawContext);

/// The frame the renderer records for the test context at 1280 by 720.
fn record(renderer: *Renderer, buffer: *patchwork.commands.CommandBuffer) void {
    buffer.reset();
    renderer.frame(buffer, &test_context.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = 1280,
        .height_px = 720,
        .scale_120 = 120,
    }, 0);
}

// Locks the cost of a theme switch (section 3a) as the renderer records it: the click on the
// "light" toggle draws once and records one stream whose first write is the whole 256-byte
// uniform and whose pass is direct (every tile changed), cleared to light's background; the
// thumb then eases over frames that each repaint only the toggle (cached); once settled the
// gallery records nothing.
test "a theme switch records one uniform write and one full repaint" {
    const static = struct {
        var renderer: Renderer = undefined;
        var buffer: patchwork.commands.CommandBuffer = undefined;
    };
    const renderer = &static.renderer;
    const buffer = &static.buffer;
    const app = new_app();
    renderer.init();
    buffer.* = .init();
    renderer.setup(buffer, &test_context.draw);
    _ = frame(app);
    record(renderer, buffer);
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.skipped, renderer.last);
    const pill = area_rect(theme_id);
    const point: input.Point = .{ .x = pill.x + 10, .y = pill.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .pointer_leave);
    try std.testing.expect(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.direct, renderer.last);
    var reader = buffer.reader();
    const first = reader.next().?.buffer_write;
    try std.testing.expectEqual(renderer.resources.uniform_buffer, first.id);
    try std.testing.expectEqual(@as(u32, 256), first.data.len);
    var uniform_writes: u32 = 0;
    var written: u32 = 0;
    var writes: u32 = 0;
    reader = buffer.reader();
    while (reader.next()) |op| switch (op) {
        .buffer_write => |write| {
            writes += 1;
            written += write.data.len;
            if (write.id == renderer.resources.uniform_buffer) uniform_writes += 1;
        },
        .pass_begin => |pass| try std.testing.expectEqual(theme.light.colors.background, pass.clear),
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 1), uniform_writes);
    // The uniform and the seven pools' changed ranges (Box, Arc, Glyph, the hardware row's
    // Dial, Bevel, and Led, and the dropdowns' chevron Paths): every text and face color moved.
    try std.testing.expectEqual(@as(u32, 8), writes);
    try std.testing.expect(written > 256);
    var frames: u32 = 0;
    while (ui.animate(App, app, &test_context, 1000.0 / 60.0)) : (frames += 1) {
        _ = ui.draw_frame(App, app, &test_context, 1280, 720, 120);
        record(renderer, buffer);
        try std.testing.expect(renderer.last == .full or renderer.last == .cached);
        try std.testing.expect(frames < 30);
    }
    _ = ui.draw_frame(App, app, &test_context, 1280, 720, 120);
    record(renderer, buffer);
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.skipped, renderer.last);
    try std.testing.expectEqual(@as(u32, 0), buffer.count);
}

test {
    _ = hardware;
}

comptime {
    patchwork.app.check(App);
}

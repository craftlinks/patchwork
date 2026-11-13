//! Skins example: four looks over one set of widgets, switched live.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! Paper, Codex, Patch, and HUD (`looks.zig`) are four values of one shape: a `theme.Scheme`
//! with its form and spaced heading, plus the few things a scheme cannot say. A switch is
//! `cx.set_theme(look.scheme)` and `restyle`: one uniform write and every tile repainted. The
//! tabs, panels, toggle, checkboxes, dropdown, number box, and text field are `skins.Default`,
//! drawing what the scheme's form says. Two example skin types read the scheme on every call:
//! `looks.Skin` (parameter cells, meters, section headers, the tooltip card, the slider) and
//! `looks.Object` (the patch's boxes and every button). Nothing here is library code.
//!
//! ## 2. Layout (logical pixels, from the top-left)
//! Every width, height, gap, and inset is a multiple of 4, so scales 1, 1.25, 1.5, and 2 put
//! every edge on a device pixel (the comptime block):
//! ```text
//! bar      (0, 0, 1280, 48)   title (16, 0, 104, 48) in the look's module style; the look
//!                             switcher, widgets.Tabs, at (136, 8, 384, 32); the flow toggle
//!                             at (536, 8, 112, 32); the status, right-aligned, ending at 1264;
//!                             a hairline rule along the bar's bottom
//! column 1 (16, 64, 300, 640)  a panel, padding 8, flow down, spacing 8 from y 72:
//!   72  RACK CONTROL | CPU 8% disclosure header 28, its count at the end
//!   108 PLAY SYNC STOP ARM    buttons 68 x 28, 4 apart: plain, accents 0, 1, 2
//!   144 OSC FILTER AMP        widgets.Tabs bar, 32
//!   184 CUTOFF RES DRIVE MIX  parameter cells 68 x 48
//!   240 level                 slider 24
//!   272 sync                  toggle 28
//!   308 loop                  checkbox 28, on
//!   344 OUTPUT 0.72, 376 CPU 0.86 (past the 0.8 tick)   meters 24
//!   408 CH 1, S, M            the channel name and two 24 x 24 badges
//!   440 CHANNELS | 5 OF 5     then five rows 28 high, 4 apart: a dim square, the name, a
//!                             mini level bar, and an "S" badge
//! column 2 (332, 64, 300, 640) a panel: MASTER FX (the dropdown "hall", the number box
//!                             2.40 s, the text field, cells SIZE DAMP PRE WET); ADVANCED
//!                             (closed: one checkbox); OBJECTS, four palette rows 20 high with
//!                             a spaced row label and three object buttons each, and a SEND row
//!                             of accent buttons; FIGURES, three big numbers with spaced
//!                             captions, and two status words in accents 2 and 3
//! patch    (648, 64, 616, 640) a panel at the look's `patch_alpha`, columns 3 and 4 joined:
//!                             PATCH, the three object boxes (144 x 28), their ports, the
//!                             cables, and the pills (patch.zig)
//! ```
//! The disclosure header is the library's `disclosure_h`, 28. Object buttons are as wide as
//! their label in the look's object style, rounded up to 4.
//!
//! ## 3. Events
//! Each widget gets every event and its action goes to the status line: "look Codex",
//! "cutoff 0.75", "lpf~ 0.75", "flow on", "menu room", "object osc~", "solo pad". Keys 1 to 4
//! switch looks while no text is edited, so a scripted switch never focuses the switcher.
//! Hovering an object box shows the card "PATCH\nosc~ 440\nthe tone under everything" after
//! its dwell, `leader_px` to the right of the box; `TooltipOf(looks.Skin)` has a fixed `size`
//! because the library sizes the box from one line of `scheme.name`. The app draws a thin
//! leader with a dot from the box to the card on the tooltip layer.
//!
//! ## 4. Decorations
//! After the widgets, the app draws what one look adds (`looks.Decor`), because the app knows
//! the look and the skins only see the scheme: Paper's and Codex's ports (a `port_side`
//! square on the top-right corner of each object button, in `Look.port`, placed from the
//! button's area) and HUD's viewport brackets (an L of arm `bracket_arm`, a hairline thick, in
//! `colors.control`, `bracket_inset` inside each corner of the patch panel). A look's
//! `patch_alpha` lets Paper's map show through the patch and makes Patch's ground its canvas.
//!
//! ## 5. Draw Order
//! `draw` appends the ground `Image` first, then the bar's rule, so the base layer runs Image,
//! Box, Glyph, then Path (the chevrons, the checkbox mark, the cables). The pills are on
//! `patch.pill_layer`, over the cables; the dropdown's list and the tooltip on the library's
//! popup and tooltip layers.
//!
//! ## 6. Flow
//! The flow toggle starts and stops the 16 ms timer (`config.timer_armed = false`). Each tick
//! adds the time since the last to `flow_elapsed_ms`, sets the cables' dash offset from it
//! (`patch.flow_offset`), and asks for a draw. With flow off the screen is idle: no timer, no
//! frame owed.
//!
//! ## 7. Scenarios
//! `still`; `paper`, `codex`, `patch`, `hud` (click the look, rest on box A until the card
//! shows); the four `-menu` ones (click the look, open the dropdown); `switch` (keys 2, 3, 4,
//! 1: back to Paper, so its golden equals `still`'s); `switching` (one switch a frame, for its
//! cost, also ending on `still`'s frame); `drag` (Codex, box B dragged up 30 px:
//! "lpf~ 0.75", then dragged down and up again every frame); `flow` (Patch, flow on, 31 frames
//! in). Long runs are measured offscreen on the scenario's clock: `--render flow --frames
//! 36000 --out -` (600 s) against 3,600, and the same for `drag`.
//!
//! ## 8. TigerStyle Invariants
//! - Capacities are constants; the status line is a fixed buffer; nothing allocates.
//! - Every label the screen shows lies inside `faces.ranges` (comptime).

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
const looks = @import("looks.zig");
const patch = @import("patch.zig");
const ground_file = @import("ground.zig");
const faces = @import("faces.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;

// ---------------------------------------------------------------------------- layout

pub const screen_w: f32 = 1280;
pub const screen_h: f32 = 720;
pub const bar_h: f32 = 48;
pub const gutter: f32 = 16;
pub const column_w: f32 = 300;
pub const panel_y: f32 = bar_h + gutter;
pub const panel_h: f32 = 640;
pub const panel_pad: f32 = 8;
pub const spacing: f32 = 8;
pub const inner_w: f32 = column_w - 2 * panel_pad;
pub const button_w: f32 = 68;
pub const button_h: f32 = 28;
pub const row_gap: f32 = 4;
pub const tabs_h: f32 = 32;
pub const cell_h: f32 = 48;
pub const slider_h: f32 = 24;
pub const toggle_h: f32 = 28;
pub const checkbox_h: f32 = 28;
pub const meter_h: f32 = 24;
pub const badge_side: f32 = 24;
pub const field_h: f32 = 28;
pub const port_side: f32 = 4;
pub const bracket_arm: f32 = 16;
/// The brackets' inset from the patch panel's corners.
pub const bracket_inset: f32 = 8;
pub const row_h: f32 = 24;
pub const object_h: f32 = 20;
/// The palette's row label column, and an object button's text padding.
pub const palette_label_w: f32 = 56;
pub const object_pad_x: f32 = 6;
pub const figure_h: f32 = 52;
pub const figure_w: f32 = 92;
pub const figure_size: f32 = 22;
pub const status_word_h: f32 = 24;
pub const channel_dot: f32 = 8;
pub const channel_bar_w: f32 = 72;
pub const channel_bar_h: f32 = 3;
pub const channel_badge: f32 = 20;
/// How far the card sits from the box it describes; the leader spans the gap.
pub const leader_px: f32 = 24;
pub const leader_dot_r: f32 = 2;

pub const title_rect: Rect = .{ .x = gutter, .y = 0, .width = 104, .height = bar_h };
pub const switcher_rect: Rect = .{ .x = 136, .y = 8, .width = 384, .height = 32 };
pub const flow_rect: Rect = .{ .x = 536, .y = 8, .width = 112, .height = 32 };
pub const status_rect: Rect = .{ .x = 664, .y = 0, .width = 600, .height = bar_h };
pub const column_rects = [2]Rect{
    .{ .x = gutter, .y = panel_y, .width = column_w, .height = panel_h },
    .{ .x = 2 * gutter + column_w, .y = panel_y, .width = column_w, .height = panel_h },
};
pub const patch_rect: Rect = .{
    .x = 3 * gutter + 2 * column_w,
    .y = panel_y,
    .width = 2 * column_w + gutter,
    .height = panel_h,
};
pub const screen_rect: Rect = .{ .x = 0, .y = 0, .width = screen_w, .height = screen_h };
/// The four main buttons' row: y = 72 + 28 + 8.
pub const buttons_y: f32 = panel_y + panel_pad + widgets.disclosure_h + spacing;

/// Every rect of section 2 by name, for the layout test.
pub const named_rects = [_]struct { name: []const u8, rect: Rect }{
    .{ .name = "title", .rect = title_rect },
    .{ .name = "switcher", .rect = switcher_rect },
    .{ .name = "flow", .rect = flow_rect },
    .{ .name = "status", .rect = status_rect },
    .{ .name = "column 1", .rect = column_rects[0] },
    .{ .name = "column 2", .rect = column_rects[1] },
    .{ .name = "patch", .rect = patch_rect },
    .{ .name = "box A", .rect = patch.boxes[0] },
    .{ .name = "box B", .rect = patch.boxes[1] },
    .{ .name = "box C", .rect = patch.boxes[2] },
};

/// The first rect of `named_rects` with an edge off the 4 px grid, or null.
pub fn off_grid() ?[]const u8 {
    for (named_rects) |entry| {
        const r = entry.rect;
        for ([_]f32{ r.x, r.y, r.width, r.height }) |edge| {
            if (@mod(edge, 4) != 0) return entry.name;
        }
    }
    return null;
}

comptime {
    assert(gutter + 4 * column_w + 4 * gutter == screen_w);
    assert(bar_h + gutter + panel_h + gutter == screen_h);
    assert(off_grid() == null);
    assert(4 * button_w + 3 * row_gap == inner_w);
    assert(inner_w - 2 * (badge_side + row_gap) > 0);
    assert(@mod(widgets.disclosure_h, 4) == 0);
    assert(status_rect.x + status_rect.width == screen_w - gutter);
    assert(patch_rect.x + patch_rect.width == screen_w - gutter);
}

// ---------------------------------------------------------------------------- content

const Cell = widgets.KnobOf(looks.Skin);
const Box = widgets.KnobOf(looks.Object);
const ObjectButton = widgets.ButtonOf(looks.Object);
const Slider = widgets.SliderOf(looks.Skin);
const Meter = widgets.MeterOf(looks.Skin);
const Section = widgets.DisclosureOf(looks.Skin);
const Tooltip = widgets.TooltipOf(looks.Skin);

/// How a cell writes its value.
pub const Unit = enum(u8) { plain, kilo, decibel, percent, millis, whole };

pub const CellSpec = struct {
    name: []const u8,
    /// The status line's name.
    report: []const u8,
    value: f32,
    unit: Unit,
    scale: f32 = 1,
};

pub const cell_count: u32 = 8;
pub const cell_specs = [cell_count]CellSpec{
    .{ .name = "CUTOFF", .report = "cutoff", .value = 0.5, .unit = .kilo, .scale = 2.4 },
    .{ .name = "RES", .report = "res", .value = 0.45, .unit = .plain },
    .{ .name = "DRIVE", .report = "drive", .value = 0.5, .unit = .decibel, .scale = 6 },
    .{ .name = "MIX", .report = "mix", .value = 0.5, .unit = .percent },
    .{ .name = "SIZE", .report = "size", .value = 0.6, .unit = .plain },
    .{ .name = "DAMP", .report = "damp", .value = 0.35, .unit = .plain },
    .{ .name = "PRE", .report = "pre", .value = 0.25, .unit = .millis, .scale = 48 },
    .{ .name = "WET", .report = "wet", .value = 0.3, .unit = .percent },
};
pub const box_specs = [patch.box_count]CellSpec{
    .{ .name = patch.box_names[0], .report = patch.box_names[0], .value = 0.5, .unit = .whole, .scale = 880 },
    .{ .name = patch.box_names[1], .report = patch.box_names[1], .value = 0.5, .unit = .whole, .scale = 2400 },
    .{ .name = patch.box_names[2], .report = patch.box_names[2], .value = 0.8, .unit = .plain },
};

pub const button_labels = [4][]const u8{ "PLAY", "SYNC", "STOP", "ARM" };
pub const badge_labels = [2][]const u8{ "S", "M" };
pub const osc_labels = [3][]const u8{ "OSC", "FILTER", "AMP" };
pub const reverb_items = [4][]const u8{ "plate", "hall", "room", "spring" };
/// Each header's title, a tab, and what it shows at its end (`looks.Skin.disclosure`).
pub const section_labels = [_][]const u8{
    "RACK CONTROL\tCPU 8%", "MASTER FX\tPOST", "ADVANCED\t1",      "PATCH\t3 OF 3",
    "CHANNELS\t5 OF 5",     "OBJECTS\t12",     "FIGURES\t120 BPM",
};
pub const section_names = [section_labels.len][]const u8{ "rack control", "master fx", "advanced", "patch", "channels", "objects", "figures" };
pub const section_open = [section_labels.len]bool{ true, true, false, true, true, true, true };
pub const meter_names = [2][]const u8{ "OUTPUT", "CPU" };
pub const meter_values = [2]f32{ 0.72, 0.86 };
pub const look_names = [4][]const u8{ "Paper", "Codex", "Patch", "HUD" };
pub const channel = "CH 1";
pub const tooltip_caption = "PATCH";
pub const tooltip_size: [2]f32 = .{ 248, 64 };
pub const box_notes = [patch.box_count][]const u8{ "the tone under everything", "a low-pass on the tone", "out to the speakers" };

pub const channel_names = [_][]const u8{ "drone", "pad", "bass", "noise", "keys" };
pub const channel_levels = [channel_names.len]f32{ 0.62, 0.45, 0.70, 0.30, 0.55 };
pub const palette_rows = [_][]const u8{ "SOURCES", "LOGIC", "TIME", "SHAPE" };
pub const palette_objects = [palette_rows.len][3][]const u8{
    .{ "osc~", "noise~", "dust~" },
    .{ "clock~", "div~", "and~" },
    .{ "delay~", "tape~", "loop~" },
    .{ "fold~", "bits~", "diode~" },
};
pub const send_row = "SEND";
pub const send_labels = [3][]const u8{ "FBK", "DRIVE", "WET" };
pub const figures = [3][2][]const u8{ .{ "120", "TEMPO" }, .{ "4.2", "DELAY MS" }, .{ "0.72", "GAIN" } };
pub const status_words = [2][2][]const u8{ .{ "LINK", "READY" }, .{ "TEMP", "HOT" } };
pub const object_count: u32 = palette_rows.len * 3;

const section_rack: u32 = 0;
const section_fx: u32 = 1;
const section_advanced: u32 = 2;
const section_patch: u32 = 3;
const section_channels: u32 = 4;
const section_objects: u32 = 5;
const section_figures: u32 = 6;

const switcher_id = ui.id("look", 0);
const flow_id = ui.id("flow", 0);
const osc_id = ui.id("osc", 0);
const level_id = ui.id("level", 0);
const sync_id = ui.id("sync", 0);
const loop_id = ui.id("loop", 0);
const freeze_id = ui.id("freeze", 0);
const reverb_id = ui.id("reverb", 0);
const time_id = ui.id("time", 0);
const name_id = ui.id("name", 0);

const status_cap: u32 = 48;
const value_cap: u32 = 16;
const tip_cap: u32 = 64;

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };
const end_tight: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = false };

comptime {
    // Every string the screen shows is inside the faces' ranges (faces.zig).
    @setEvalBranchQuota(20_000);
    const tables = .{ button_labels, badge_labels, osc_labels, reverb_items, section_names, meter_names, look_names, channel_names, palette_rows, send_labels, box_notes };
    // A header's tab is not drawn: the skin splits the label at it.
    for (section_labels) |label| {
        const parts = looks.split_tab(label);
        assert(faces.covers(parts.left));
        assert(faces.covers(parts.right));
    }
    for (tables) |table| {
        for (table) |label| assert(faces.covers(label));
    }
    for (palette_objects) |row| {
        for (row) |label| assert(faces.covers(label));
    }
    for (figures ++ status_words) |pair| {
        for (pair) |label| assert(faces.covers(label));
    }
    for (cell_specs ++ box_specs) |spec| assert(faces.covers(spec.name));
    for (looks.all) |look| assert(faces.covers(look.name));
    assert(faces.covers(channel ++ tooltip_caption ++ send_row ++ "skins flow loop freeze sync level night drive 0123456789.%kdBms~ "));
}

// ---------------------------------------------------------------------------- the app

/// The skins screen. See the module guide.
pub const App = struct {
    /// The look shown: an index into `looks.all`.
    look: u32,
    switcher: widgets.Tabs,
    flow: widgets.Toggle,
    sections: [section_labels.len]Section,
    buttons: [button_labels.len]ObjectButton,
    badges: [badge_labels.len]ObjectButton,
    /// The channel rows' "S" badges, the palette's objects, and its send row.
    solos: [channel_names.len]ObjectButton,
    objects: [object_count]ObjectButton,
    sends: [send_labels.len]ObjectButton,
    osc: widgets.Tabs,
    cells: [cell_count]Cell,
    level: Slider,
    sync: widgets.Toggle,
    loop: widgets.Checkbox,
    freeze: widgets.Checkbox,
    meters: [meter_names.len]Meter,
    /// Overlays draw in field order: the dropdown's list, then the tooltip.
    reverb: widgets.Dropdown,
    time: widgets.NumberBox,
    name: widgets.TextField,
    boxes: [patch.box_count]Box,
    tooltip: Tooltip,
    /// The panels' paint, and the patch panel's at the look's `patch_alpha`, from the look
    /// (`restyle`).
    panel_paint: kit.Paint,
    patch_paint: kit.Paint,
    ground: ground_file.Ground,
    /// Flow (section 6): the time it has run, and the last tick's clock.
    flowing: bool,
    flow_elapsed_ms: u64,
    flow_last_ms: ?u64,
    status: [status_cap]u8,
    status_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "skins",
        .timer_period_ms = 16,
        .timer_armed = false,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = quads.Image, .cap = 1 },
        },
        .batch_cap = 32,
        .area_cap = area_cap,
        .point_cap = point_cap,
        .theme = looks.paper.scheme,
    };

    pub const scenarios: []const bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{ .name = "paper", .setup = &look_steps(0), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "codex", .setup = &look_steps(1), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "patch", .setup = &look_steps(2), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hud", .setup = &look_steps(3), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "paper-menu", .setup = &menu_steps(0), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "codex-menu", .setup = &menu_steps(1), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "patch-menu", .setup = &menu_steps(2), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hud-menu", .setup = &menu_steps(3), .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "switch", .setup = &switch_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        // A switch every frame, for its cost; 60 frames end on Paper, so its line is `still`'s.
        .{ .name = "switching", .setup = &.{.{ .wait = 1 }}, .cycle = &switch_cycle, .frames = 60 },
        .{ .name = "drag", .setup = &drag_steps, .cycle = &drag_cycle, .frames = 60 },
        .{ .name = "flow", .setup = &flow_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        app.look = 0;
        app.switcher = widgets.Tabs.init(switcher_id, &look_labels, 0);
        app.flow = widgets.Toggle.init(flow_id, "flow", false);
        for (&app.sections, section_labels, section_open, 0..) |*section, label, open, index| {
            section.* = Section.init(ui.id("section", @intCast(index)), label, open);
        }
        for (&app.buttons, button_labels, 0..) |*button, label, index| {
            button.* = button_of(ui.id("button", @intCast(index)), label);
        }
        for (&app.badges, badge_labels, 0..) |*badge, label, index| {
            badge.* = button_of(ui.id("badge", @intCast(index)), label);
        }
        for (&app.solos, 0..) |*solo, index| solo.* = button_of(ui.id("solo", @intCast(index)), "S");
        for (&app.objects, 0..) |*object, index| {
            object.* = button_of(ui.id("object", @intCast(index)), palette_objects[index / 3][index % 3]);
            object.padding = .xy(object_pad_x, 0);
        }
        for (&app.sends, send_labels, 0..) |*send, label, index| {
            send.* = button_of(ui.id("send", @intCast(index)), label);
        }
        app.osc = widgets.Tabs.init(osc_id, &osc_labels, 0);
        for (&app.cells, cell_specs, 0..) |*cell, spec, index| {
            cell.* = Cell.init(ui.id("cell", @intCast(index)), spec.name, spec.value, kit.paint_of(.{ 1, 1, 1, 1 }, 0));
        }
        for (&app.boxes, box_specs, 0..) |*box, spec, index| {
            box.* = Box.init(ui.id("box", @intCast(index)), spec.name, spec.value, kit.paint_of(.{ 1, 1, 1, 1 }, 0));
        }
        app.level = .{ .id = level_id, .hover = .init(widgets.hover_rate_per_ms), .value = 0.6, .track = undefined, .fill = undefined, .knob = undefined };
        app.sync = widgets.Toggle.init(sync_id, "sync", true);
        app.loop = widgets.Checkbox.init(loop_id, "loop", true);
        app.freeze = widgets.Checkbox.init(freeze_id, "freeze", false);
        for (&app.meters, meter_names, meter_values) |*meter, name, value| {
            meter.* = .{ .name = name, .value = value };
        }
        app.reverb = widgets.Dropdown.init(reverb_id, &reverb_items, 1);
        app.reverb.menu.bounds = screen_rect;
        app.time = widgets.NumberBox.init(time_id, 2.4, 0.1, 10, 0.1, .{ .decimals = 2, .unit = " s" });
        app.name = widgets.TextField.init(name_id, 32, config.theme.value);
        app.name.load("night drive");
        app.tooltip = Tooltip.init();
        app.tooltip.size = tooltip_size;
        app.tooltip.offset = .{ leader_px, 0 };
        app.tooltip.bounds = screen_rect;
        app.ground.init(textures);
        app.flowing = false;
        app.flow_elapsed_ms = 0;
        app.flow_last_ms = null;
        app.status = @splat(0);
        app.status_len = 0;
        // The status a switch back to Paper writes too, so `switch` ends on `still`'s frame.
        app.note(null, &.{ "look ", look_names[0] });
        app.restyle(&looks.all[0]);
        assert(app.reverb.selected == 1);
        assert(!app.flowing);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.switcher.handle(cx, event_value)) {
            .changed => |index| app.switch_to(cx, index),
            else => {},
        }
        switch (app.flow.handle(cx, event_value)) {
            .toggled => |on| app.set_flow(cx, on),
            .none => {},
        }
        for (&app.sections, section_names) |*section, name| {
            switch (section.handle(cx, event_value)) {
                .toggled => |open| app.note(cx, &.{ name, if (open) " open" else " closed" }),
                .none => {},
            }
        }
        app.control_events(cx, event_value);
        app.cell_events(cx, &app.cells, &cell_specs, event_value);
        app.box_events(cx, event_value);
        app.fx_events(cx, event_value);
        if (event_value == .key_down) app.key(cx, event_value.key_down);
        var bytes: [tip_cap]u8 = undefined;
        app.tooltip.handle(cx, event_value, app.hovered_tip(cx, &bytes));
        assert(app.status_len <= status_cap);
    }

    /// The buttons, the badges, the oscillator tabs, the slider, the toggle, and the checkboxes.
    fn control_events(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.buttons, button_labels) |*button, label| {
            if (button.handle(cx, event_value) == .clicked) app.note(cx, &.{lower_label(label)});
        }
        for (&app.badges, badge_labels) |*badge, label| {
            if (badge.handle(cx, event_value) == .clicked) app.note(cx, &.{ "badge ", label });
        }
        for (&app.solos, channel_names) |*solo, name| {
            if (solo.handle(cx, event_value) == .clicked) app.note(cx, &.{ "solo ", name });
        }
        for (&app.objects) |*object| {
            if (object.handle(cx, event_value) == .clicked) app.note(cx, &.{ "object ", object.label });
        }
        for (&app.sends, send_labels) |*send, label| {
            if (send.handle(cx, event_value) == .clicked) app.note(cx, &.{ "send ", lower_label(label) });
        }
        switch (app.osc.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "page ", lower_label(osc_labels[index]) }),
            else => {},
        }
        switch (app.level.handle(cx, event_value)) {
            .changed => |value| {
                var digits: [8]u8 = undefined;
                widgets.write_hundredths(&digits, value);
                app.note(cx, &.{ "level ", digits[0..4] });
            },
            .none, .released => {},
        }
        switch (app.sync.handle(cx, event_value)) {
            .toggled => |on| app.note(cx, &.{ "sync ", if (on) "on" else "off" }),
            .none => {},
        }
        switch (app.loop.handle(cx, event_value)) {
            .toggled => |on| app.note(cx, &.{ "loop ", if (on) "on" else "off" }),
            .none => {},
        }
        switch (app.freeze.handle(cx, event_value)) {
            .toggled => |on| app.note(cx, &.{ "freeze ", if (on) "on" else "off" }),
            .none => {},
        }
    }

    /// The dropdown, the number box, and the text field.
    fn fx_events(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.reverb.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "menu ", reverb_items[index] }),
            .none => {},
        }
        switch (app.time.handle(cx, event_value)) {
            .changed, .committed => {
                var bytes: [widgets.number_text_cap]u8 = undefined;
                app.note(cx, &.{ "time ", app.time.text_of(&bytes) });
            },
            .none => {},
        }
        switch (app.name.handle(cx, event_value)) {
            .changed => app.note(cx, &.{ "name ", app.name.bytes() }),
            .committed, .cancelled, .none => {},
        }
    }

    /// Hands `event_value` to each cell and reports a change: "cutoff 0.75".
    fn cell_events(app: *App, cx: *Context, cells: []Cell, specs: []const CellSpec, event_value: input.Event) void {
        assert(cells.len == specs.len);
        for (cells, specs) |*cell, spec| {
            switch (cell.handle(cx, event_value)) {
                .changed, .reset => app.note(cx, &.{ spec.report, " ", cell.value_text[0..4] }),
                .none, .released => {},
            }
        }
    }

    /// Hands `event_value` to each object box and reports a change: "lpf~ 0.75".
    fn box_events(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.boxes, box_specs) |*box, spec| {
            switch (box.handle(cx, event_value)) {
                .changed, .reset => app.note(cx, &.{ spec.report, " ", box.value_text[0..4] }),
                .none, .released => {},
            }
        }
    }

    /// Keys 1 to 4 switch looks while no text is edited (section 3).
    fn key(app: *App, cx: *Context, press: input.KeyPress) void {
        if (cx.focused(name_id) or app.time.editing) return;
        const typed = press.typed();
        if (typed.len != 1) return;
        if (typed[0] < '1' or typed[0] > '4') return;
        const index: u32 = typed[0] - '1';
        assert(index < looks.all.len);
        app.switch_to(cx, index);
    }

    /// Shows look `index` (section 1): the switcher's tab, the scheme, the stored paints, the
    /// status.
    pub fn switch_to(app: *App, cx: *Context, index: u32) void {
        assert(index < looks.all.len);
        app.look = index;
        app.switcher.selected = index;
        cx.set_theme(looks.all[index].scheme);
        app.restyle(&looks.all[index]);
        cx.redraw();
        app.note(cx, &.{ "look ", look_names[index] });
        assert(app.switcher.selected == index);
    }

    /// Flow on or off (section 6).
    fn set_flow(app: *App, cx: *Context, on: bool) void {
        app.flowing = on;
        app.flow_last_ms = null;
        cx.set_timer(on);
        app.note(cx, &.{ "flow ", if (on) "on" else "off" });
        assert(cx.timer_on == on);
    }

    /// One flow tick (section 6).
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        if (!app.flowing) return;
        if (app.flow_last_ms) |last| {
            if (now_ms > last) app.flow_elapsed_ms += now_ms - last;
        }
        app.flow_last_ms = now_ms;
        cx.redraw();
        assert(app.flow_last_ms.? == now_ms);
    }

    /// The colours and corners the widgets store, from `look` (`theme.zig` section 8: an
    /// instance's paint wins over the scheme, so it is rebuilt on a switch).
    pub fn restyle(app: *App, look: *const looks.Look) void {
        const scheme = &look.scheme;
        const colors = &scheme.colors;
        const form = &scheme.form;
        app.level.track = kit.paint_of(colors.track, 0);
        app.level.fill = kit.paint_of(colors.value, 0);
        app.level.knob = kit.paint_of(colors.text, looks.slider_dot_r);
        for (&app.buttons, 0..) |*button, index| {
            const role: ?u32 = if (index == 0) null else @intCast(index - 1);
            restyle_button(button, look, role, look.button);
        }
        for (&app.badges) |*badge| restyle_button(badge, look, null, look.button);
        for (&app.solos) |*solo| restyle_button(solo, look, null, look.button);
        for (&app.objects) |*object| restyle_button(object, look, null, look.object);
        for (&app.sends) |*send| restyle_button(send, look, 0, look.button);
        for (&app.boxes) |*box| box.accent = kit.paint_of(look.object_fill, form.radius.control);
        app.panel_paint = kit.paint_of(colors.panel, form.radius.popup);
        app.patch_paint = app.panel_paint;
        app.patch_paint.a = look.patch_alpha;
        app.sync.accent = scheme.accents[0];
        app.flow.accent = scheme.accents[0];
        app.name.style = scheme.value;
        assert(app.panel_paint.radius == form.radius.popup);
        assert(app.level.knob.radius == looks.slider_dot_r);
    }

    /// The flow's dash offset now (section 6).
    pub fn offset(app: *const App) f32 {
        return patch.flow_offset(app.flow_elapsed_ms);
    }

    pub fn draw(app: *App, cx: *Context) void {
        const look = &looks.all[app.look];
        app.ground.draw(cx, look);
        app.draw_bar(cx, look);
        app.draw_rack(cx, look);
        app.draw_fx(cx, look);
        app.draw_patch(cx, look);
        app.draw_decor(cx, look);
        ui.overlays(cx, app);
        app.draw_leader(cx);
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    fn draw_bar(app: *const App, cx: *Context, look: *const looks.Look) void {
        const scheme = cx.theme();
        const rule: Rect = .{ .x = 0, .y = bar_h - 1, .width = screen_w, .height = 1 };
        kit.face(cx, rule, clip_of(screen_rect), .{ .fill = scheme.colors.control });
        kit.label(cx, look.module, "skins", title_rect, clip_of(title_rect), start);
        _ = cx.begin_at(switcher_rect, ui.flow_of(.down));
        app.switcher.bar(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.begin_at(flow_rect, ui.flow_of(.down));
        app.flow.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        kit.label(cx, look.caption, app.status_text(), status_rect, clip_of(status_rect), end);
    }

    /// Column 1: RACK CONTROL and CHANNELS.
    fn draw_rack(app: *const App, cx: *Context, look: *const looks.Look) void {
        app.begin_panel(cx, column_rects[0], app.panel_paint);
        const section = &app.sections[section_rack];
        if (section.begin(cx, ui.sized(.fill, .fit), column_layout)) {
            _ = cx.begin(ui.sized(.fill, .{ .fixed = button_h }), row_layout);
            for (&app.buttons) |*button| button.draw(cx, ui.sized(.{ .fixed = button_w }, .fill));
            _ = cx.end();
            app.osc.bar(cx, ui.sized(.fill, .{ .fixed = tabs_h }));
            app.draw_cells(cx, app.cells[0..4], cell_specs[0..4]);
            app.level.draw(cx, ui.sized(.fill, .{ .fixed = slider_h }));
            app.sync.draw(cx, ui.sized(.fill, .{ .fixed = toggle_h }));
            app.loop.draw(cx, ui.sized(.fill, .{ .fixed = checkbox_h }));
            for (&app.meters) |*meter| meter.draw(cx, ui.sized(.fill, .{ .fixed = meter_h }));
            _ = cx.begin(ui.sized(.fill, .{ .fixed = badge_side }), row_layout);
            const name = cx.walk(ui.sized(.{ .fixed = inner_w - 2 * (badge_side + row_gap) }, .fill));
            if (cx.visible(name)) |clip| kit.label(cx, look.module, channel, name, clip, start);
            for (&app.badges) |*badge| badge.draw(cx, ui.sized(.{ .fixed = badge_side }, .fill));
            _ = cx.end();
        }
        section.end(cx);
        const channels = &app.sections[section_channels];
        if (channels.begin(cx, ui.sized(.fill, .fit), list_layout)) {
            for (&app.solos, channel_names, channel_levels) |*solo, name, level| {
                const row = cx.walk(ui.sized(.fill, .{ .fixed = row_h }));
                draw_channel(cx, look, row, name, level, solo);
            }
        }
        channels.end(cx);
        end_panel(cx);
    }

    /// Column 2: MASTER FX, ADVANCED, OBJECTS, and FIGURES.
    fn draw_fx(app: *const App, cx: *Context, look: *const looks.Look) void {
        app.begin_panel(cx, column_rects[1], app.panel_paint);
        const fx = &app.sections[section_fx];
        if (fx.begin(cx, ui.sized(.fill, .fit), column_layout)) {
            app.reverb.draw(cx, ui.sized(.fill, .{ .fixed = field_h }));
            app.time.draw(cx, ui.sized(.fill, .{ .fixed = field_h }));
            app.name.draw(cx, ui.sized(.fill, .{ .fixed = field_h }));
            app.draw_cells(cx, app.cells[4..8], cell_specs[4..8]);
        }
        fx.end(cx);
        const advanced = &app.sections[section_advanced];
        if (advanced.begin(cx, ui.sized(.fill, .fit), column_layout)) {
            app.freeze.draw(cx, ui.sized(.fill, .{ .fixed = checkbox_h }));
        }
        advanced.end(cx);
        const objects = &app.sections[section_objects];
        if (objects.begin(cx, ui.sized(.fill, .fit), list_layout)) {
            for (palette_rows, 0..) |label, row| draw_palette_row(cx, label, app.objects[row * 3 ..][0..3]);
            draw_palette_row(cx, send_row, &app.sends);
        }
        objects.end(cx);
        const figures_section = &app.sections[section_figures];
        if (figures_section.begin(cx, ui.sized(.fill, .fit), column_layout)) draw_figures(cx, look);
        figures_section.end(cx);
        end_panel(cx);
    }

    /// A row of four parameter cells with their values in their units.
    fn draw_cells(app: *const App, cx: *Context, cells: []const Cell, specs: []const CellSpec) void {
        assert(cells.len == specs.len);
        assert(app.look < looks.all.len);
        _ = cx.begin(ui.sized(.fill, .{ .fixed = cell_h }), row_layout);
        for (cells, specs) |*cell, spec| {
            var bytes: [value_cap]u8 = undefined;
            cell.draw_text(cx, ui.sized(.{ .fixed = button_w }, .fill), value_text(&bytes, spec, cell.value));
        }
        _ = cx.end();
    }

    /// The patch panel (patch.zig): the boxes, the ports, the cables, and the pills.
    fn draw_patch(app: *const App, cx: *Context, look: *const looks.Look) void {
        app.begin_panel(cx, patch_rect, app.patch_paint);
        const section = &app.sections[section_patch];
        const open = section.begin(cx, ui.sized(.fill, .fit), column_layout);
        section.end(cx);
        end_panel(cx);
        if (!open) return;
        for (&app.boxes, box_specs, patch.boxes) |*box, spec, rect| {
            _ = cx.begin_at(rect, ui.flow_of(.down));
            var bytes: [value_cap]u8 = undefined;
            box.draw_text(cx, ui.sized(.fill, .fill), value_text(&bytes, spec, box.value));
            _ = cx.end();
        }
        const clip = clip_of(patch_rect);
        patch.draw_ports(cx, clip);
        patch.draw_cables(cx, look, app.offset(), clip);
        patch.draw_pills(cx, look, clip);
    }

    fn begin_panel(app: *const App, cx: *Context, rect: Rect, paint: kit.Paint) void {
        assert(rect.width > 0);
        assert(app.look < looks.all.len);
        _ = cx.begin_at(rect, ui.flow_of(.down));
        const face: widgets.Panel = .{ .paint = paint };
        _ = face.begin(cx, ui.sized(.fill, .fill), panel_layout);
    }

    /// The look's ornaments over the widgets (section 4): the objects' ports, the viewport's
    /// brackets.
    fn draw_decor(app: *const App, cx: *Context, look: *const looks.Look) void {
        const scheme = cx.theme();
        const clip = clip_of(screen_rect);
        if (look.decor.ports) {
            for (&app.objects) |*object| {
                const found = cx.find(object.id) orelse continue;
                const square: Rect = .{ .x = found.rect[0] + found.rect[2] - port_side + 1, .y = found.rect[1] - 1, .width = port_side, .height = port_side };
                kit.face(cx, square, clip, .{ .fill = look.port });
            }
        }
        if (look.decor.brackets) {
            const view = ui.cx.inset(patch_rect, .all(bracket_inset));
            draw_brackets(cx, view, scheme.form.hairline, scheme.colors.control, clip);
        }
    }

    /// A thin line from the described box to the shown card, with a dot at the box (section 3).
    fn draw_leader(app: *const App, cx: *Context) void {
        if (!app.tooltip.visible()) return;
        const found = cx.find(app.tooltip.anchor) orelse return;
        const anchor: Rect = .{ .x = found.rect[0], .y = found.rect[1], .width = found.rect[2], .height = found.rect[3] };
        const card = app.tooltip.box_of(anchor, cx.theme().name, screen_rect);
        const x0 = anchor.x + anchor.width + leader_dot_r;
        if (card.x <= x0) return;
        const y = @floor(anchor.y + anchor.height * 0.5);
        const colors = &cx.theme().colors;
        const previous = cx.drawing().layer(.tooltip);
        defer _ = cx.drawing().layer(previous);
        const clip = clip_of(screen_rect);
        kit.face(cx, .{ .x = x0, .y = y, .width = card.x - x0, .height = 1 }, clip, .{ .fill = colors.control });
        const dot: Rect = .{ .x = x0 - leader_dot_r, .y = y + 0.5 - leader_dot_r, .width = 2 * leader_dot_r, .height = 2 * leader_dot_r };
        kit.face(cx, dot, clip, .{ .fill = colors.text, .radius = leader_dot_r });
    }

    /// The hovered object box's card text, "PATCH\nosc~ 440\nthe tone under everything", in
    /// `bytes`.
    fn hovered_tip(app: *const App, cx: *Context, bytes: *[tip_cap]u8) ?widgets.Tip {
        const hovered = cx.hovered();
        if (hovered == .none) return null;
        for (&app.boxes, box_specs, 0..) |*box, spec, index| {
            if (box.id != hovered) continue;
            var digits: [value_cap]u8 = undefined;
            const shown = value_text(&digits, spec, box.value);
            const tip = std.fmt.bufPrint(bytes, "{s}\n{s} {s}\n{s}", .{ tooltip_caption, spec.name, shown, box_notes[index] }) catch unreachable;
            return .{ .anchor = box.id, .text = tip };
        }
        return null;
    }

    /// Writes `parts` to the status line; with a context, owes a draw.
    fn note(app: *App, cx: ?*Context, parts: []const []const u8) void {
        var len: u32 = 0;
        for (parts) |part| {
            const room = status_cap - len;
            const take: u32 = @intCast(@min(part.len, room));
            @memcpy(app.status[len..][0..take], part[0..take]);
            len += take;
        }
        app.status_len = len;
        if (cx) |context| context.redraw();
        assert(app.status_len <= status_cap);
    }

    pub fn status_text(app: *const App) []const u8 {
        assert(app.status_len <= status_cap);
        return app.status[0..app.status_len];
    }
};

pub const Context = patchwork.app.Context(App);

const look_labels = [4][]const u8{ looks.all[0].name, looks.all[1].name, looks.all[2].name, looks.all[3].name };

const panel_layout: ui.Layout = .{ .flow = .down, .spacing = spacing, .padding = .all(panel_pad) };
const column_layout: ui.Layout = .{ .flow = .down, .spacing = spacing };
const row_layout: ui.Layout = .{ .flow = .right, .spacing = row_gap };
const list_layout: ui.Layout = .{ .flow = .down, .spacing = row_gap };

fn end_panel(cx: *Context) void {
    _ = cx.end();
    _ = cx.end();
}

/// A button whose paint and style `restyle` sets.
fn button_of(id: ui.Id, label: []const u8) ObjectButton {
    assert(id != .none);
    assert(label.len > 0);
    return .{
        .id = id,
        .label = label,
        .style = looks.paper.button,
        .padding = .xy(4, 0),
        .paint = kit.paint_of(.{ 0, 0, 0, 1 }, 0),
        .hover = .init(widgets.hover_rate_per_ms),
        .down = .init(widgets.down_rate_per_ms),
    };
}

/// A button's paint and label from `look`: plain (`role` null: the object fill, the style's
/// colour) or accent `role`, as the look shows accents (`looks.AccentButtons`): a face in the
/// accent with its label in `colors.panel`; a dark face tinted by the accent with its label the
/// accent lightened; or the object face with its label in the accent.
pub fn restyle_button(button: *ObjectButton, look: *const looks.Look, role: ?u32, style: text.Style) void {
    const scheme = &look.scheme;
    const colors = &scheme.colors;
    var label = style;
    var face = look.object_fill;
    if (role) |index| {
        const accent = scheme.accents[index];
        switch (look.accent_buttons) {
            .filled => {
                face = accent;
                label.color = colors.panel;
            },
            .tinted => {
                face = looks.mix(colors.background, accent, accent_tint);
                face[3] = 1;
                label.color = looks.mix(accent, colors.lighten, accent_lift);
            },
            .text => label.color = accent,
        }
    }
    button.paint = kit.paint_of(face, scheme.form.radius.control);
    button.style = label;
    assert(button.paint.radius == scheme.form.radius.control);
}

/// How far a tinted accent button's face moves toward the accent, and its label toward white.
const accent_tint: f32 = 0.18;
const accent_lift: f32 = 0.3;

/// A channel row (section 2): a face like an object's, a dim square, the name, a mini level
/// bar, and its solo badge at the end.
fn draw_channel(cx: *Context, look: *const looks.Look, row: Rect, name: []const u8, level: f32, solo: *const ObjectButton) void {
    assert(level >= 0 and level <= 1);
    const clip = cx.visible(row) orelse return;
    const scheme = cx.theme();
    const colors = &scheme.colors;
    const outlined = scheme.form.controls == .outlined;
    kit.face(cx, row, clip, .{
        .fill = look.object_fill,
        .border_color = colors.control,
        .border_width = if (outlined) scheme.form.hairline else 0,
        .radius = scheme.form.radius.control,
    });
    const middle = row.y + row.height * 0.5;
    kit.face(cx, .{ .x = row.x + 8, .y = middle - channel_dot / 2, .width = channel_dot, .height = channel_dot }, clip, .{ .fill = colors.control });
    const label: Rect = .{ .x = row.x + 24, .y = row.y, .width = 112, .height = row.height };
    kit.label(cx, look.object, name, label, clip, start);
    const badge_x = row.x + row.width - channel_badge - 4;
    const bar: Rect = .{ .x = badge_x - 12 - channel_bar_w, .y = @floor(middle - channel_bar_h / 2), .width = channel_bar_w, .height = channel_bar_h };
    kit.face(cx, bar, clip, .{ .fill = colors.track });
    kit.face(cx, .{ .x = bar.x, .y = bar.y, .width = bar.width * level, .height = bar.height }, clip, .{ .fill = colors.value });
    _ = cx.begin_at(.{ .x = badge_x, .y = row.y + 4, .width = channel_badge, .height = channel_badge }, ui.flow_of(.down));
    solo.draw(cx, ui.sized(.fill, .fill));
    _ = cx.end();
}

/// One palette row (section 2): its label right-aligned in a column, then its buttons at their
/// text's width, rounded up to 4 px.
fn draw_palette_row(cx: *Context, label: []const u8, buttons: []const ObjectButton) void {
    assert(buttons.len > 0);
    assert(label.len > 0);
    _ = cx.begin(ui.sized(.fill, .{ .fixed = object_h }), row_layout);
    const cell = cx.walk(ui.sized(.{ .fixed = palette_label_w }, .fill));
    if (cx.visible(cell)) |clip| {
        var style = cx.theme().heading;
        style.size -= 2;
        style.tracking = @min(style.tracking, 0.08);
        var inner = cell;
        inner.width -= 4;
        kit.label(cx, style, label, inner, clip, end_tight);
    }
    for (buttons) |*button| {
        const width = 4 * @ceil((text.measure(button.style, button.label) + 2 * object_pad_x) / 4);
        button.draw(cx, ui.sized(.{ .fixed = width }, .fill));
    }
    _ = cx.end();
}

/// Big figures with spaced captions under them, then status words (section 2).
fn draw_figures(cx: *Context, look: *const looks.Look) void {
    const scheme = cx.theme();
    var big = scheme.value;
    big.size = figure_size;
    big.color = scheme.colors.text;
    var caption = scheme.heading;
    caption.size -= 2;
    caption.color = scheme.name.color;
    _ = cx.begin(ui.sized(.fill, .{ .fixed = figure_h }), row_layout);
    for (figures) |figure| {
        const cell = cx.walk(ui.sized(.{ .fixed = figure_w }, .fill));
        const clip = cx.visible(cell) orelse continue;
        kit.label(cx, big, figure[0], .{ .x = cell.x, .y = cell.y, .width = cell.width, .height = 34 }, clip, start);
        kit.label(cx, caption, figure[1], .{ .x = cell.x, .y = cell.y + 34, .width = cell.width, .height = 16 }, clip, start);
    }
    _ = cx.end();
    _ = cx.begin(ui.sized(.fill, .{ .fixed = status_word_h }), row_layout);
    for (status_words, [2]u32{ 2, 3 }) |pair, accent| {
        const cell = cx.walk(ui.sized(.{ .fixed = (inner_w - row_gap) / 2 }, .fill));
        const clip = cx.visible(cell) orelse continue;
        kit.label(cx, look.object, pair[0], cell, clip, start);
        var word = scheme.heading;
        word.color = scheme.accents[accent];
        const shift = @ceil(looks.label_extent(look.object, pair[0]) + 8);
        kit.label(cx, word, pair[1], .{ .x = cell.x + shift, .y = cell.y, .width = cell.width - shift, .height = cell.height }, clip, start);
    }
    _ = cx.end();
}

/// An L at each corner of `rect`, `thickness` wide, its arms `bracket_arm` long.
fn draw_brackets(cx: anytype, rect: Rect, thickness: f32, color: [4]f32, clip: Clip) void {
    assert(thickness > 0);
    assert(rect.width > 2 * bracket_arm);
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    const arms = [8]Rect{
        .{ .x = rect.x, .y = rect.y, .width = bracket_arm, .height = thickness },
        .{ .x = rect.x, .y = rect.y, .width = thickness, .height = bracket_arm },
        .{ .x = right - bracket_arm, .y = rect.y, .width = bracket_arm, .height = thickness },
        .{ .x = right - thickness, .y = rect.y, .width = thickness, .height = bracket_arm },
        .{ .x = rect.x, .y = bottom - thickness, .width = bracket_arm, .height = thickness },
        .{ .x = rect.x, .y = bottom - bracket_arm, .width = thickness, .height = bracket_arm },
        .{ .x = right - bracket_arm, .y = bottom - thickness, .width = bracket_arm, .height = thickness },
        .{ .x = right - thickness, .y = bottom - bracket_arm, .width = thickness, .height = bracket_arm },
    };
    for (arms) |arm| kit.face(cx, arm, clip, .{ .fill = color });
}

/// A cell's value in its unit (`CellSpec`): "1.2k", "0.45", "3.0dB", "50%", "12ms", "440".
pub fn value_text(out: *[value_cap]u8, spec: CellSpec, value: f32) []const u8 {
    assert(value >= 0 and value <= 1);
    assert(spec.scale > 0);
    const scaled = value * spec.scale;
    const shown = switch (spec.unit) {
        .plain => std.fmt.bufPrint(out, "{d:.2}", .{scaled}),
        .kilo => std.fmt.bufPrint(out, "{d:.1}k", .{scaled}),
        .decibel => std.fmt.bufPrint(out, "{d:.1}dB", .{scaled}),
        .percent => std.fmt.bufPrint(out, "{d}%", .{@as(u32, @intFromFloat(@round(scaled * 100)))}),
        .millis => std.fmt.bufPrint(out, "{d}ms", .{@as(u32, @intFromFloat(@round(scaled)))}),
        .whole => std.fmt.bufPrint(out, "{d}", .{@as(u32, @intFromFloat(@round(scaled)))}),
    } catch unreachable;
    assert(shown.len > 0);
    return shown;
}

/// An ASCII label in lower case, for the status line, from a fixed table.
fn lower_label(label: []const u8) []const u8 {
    inline for (button_labels ++ osc_labels ++ section_labels) |known| {
        if (std.mem.eql(u8, label, known)) return comptime lower(known);
    }
    return label;
}

fn lower(comptime label: []const u8) []const u8 {
    comptime {
        var out: [label.len]u8 = undefined;
        for (label, &out) |c, *o| o.* = std.ascii.toLower(c);
        const final = out;
        return &final;
    }
}

fn clip_of(rect: Rect) Clip {
    assert(rect.width > 0);
    assert(rect.height > 0);
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

// ---------------------------------------------------------------------------- capacities

/// Panels, faces, cells and their bars, ports, decorations, and the popups' faces and rows.
const box_cap: u32 = 512;
/// Every label once, the meters' labels twice, the menu, and the card.
const glyph_cap: u32 = 2048;
/// The cables' chunks, the chevrons, the dropdown's, and the checkbox marks.
const path_cap: u32 = 128;
const point_cap: u32 = 4096;
const area_cap: u32 = 128;

// ---------------------------------------------------------------------------- scenarios

fn tab(index: u32) bench.Target {
    return .{ .id = switcher_id.derive(index), .name = "look", .index = index };
}

/// Click look `index`, rest on box A until the card shows (40 frames: the 500 ms dwell and a
/// margin).
fn look_steps(index: u32) [3]bench.Step {
    return .{
        .{ .click = tab(index) },
        .{ .hover = .{ .target = bench.area("box", 0), .x = 72, .y = 20 } },
        .{ .wait = 40 },
    };
}

/// Click look `index`, open the dropdown.
fn menu_steps(index: u32) [3]bench.Step {
    return .{
        .{ .click = tab(index) },
        .{ .click = bench.area("reverb", 0) },
        .{ .wait = 5 },
    };
}

fn key_step(comptime digit: []const u8) bench.Step {
    return .{ .key = .{ .key = .other, .text = digit } };
}

/// Codex, Patch, HUD, then Paper again, by key: the switcher never takes focus.
const switch_steps = [_]bench.Step{ key_step("2"), key_step("3"), key_step("4"), key_step("1"), .{ .wait = 5 } };

/// Codex, Patch, HUD, Paper: one switch a frame.
const switch_cycle = [_]bench.Step{ key_step("2"), key_step("3"), key_step("4"), key_step("1") };

/// Codex, then box B dragged up 30 px: 0.50 to 0.75.
const drag_steps = [_]bench.Step{
    key_step("2"),
    .{ .drag = .{ .target = bench.area("box", 1), .from_x = 72, .from_y = 20, .dx = 0, .dy = -30 } },
    .{ .wait = 2 },
};
/// Down and up again: every measured frame drags, and an even count ends at 0.75.
const drag_cycle = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("box", 1), .from_x = 72, .from_y = 20, .dx = 0, .dy = 30 } },
    .{ .drag = .{ .target = bench.area("box", 1), .from_x = 72, .from_y = 20, .dx = 0, .dy = -30 } },
};

/// Patch, flow on, 31 frames: the offset is not a whole period.
const flow_steps = [_]bench.Step{
    key_step("3"),
    .{ .click = bench.area("flow", 0) },
    .{ .wait = 31 },
};

// ---------------------------------------------------------------------------- tests

const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

fn frame(app: *App) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, 1280, 720, 120));
    cx.draw.finalize();
    assert(cx.draw.overflow_count == 0);
    return cx;
}

fn replay(app: *App, name: []const u8) !void {
    const scenario = bench.find(App.scenarios, name).?;
    _ = try bench.replay_headless_paced(App, app, &fixture.context, scenario, .{ 1280, 720 }, 4096, 16);
}

// Locks the layout (section 2): 16 + 4 x 300 + 4 x 16 = 1280 and 48 + 16 + 640 + 16 = 720,
// panels at x 16, 332, and 648, the patch 616 wide, and every rect on the 4 px grid.
test "the layout fills 1280 by 720 in multiples of 4" {
    try std.testing.expectEqual(@as(?[]const u8, null), off_grid());
    try std.testing.expectEqual(@as(f32, 16), column_rects[0].x);
    try std.testing.expectEqual(@as(f32, 332), column_rects[1].x);
    try std.testing.expectEqual(@as(f32, 648), patch_rect.x);
    try std.testing.expectEqual(@as(f32, 616), patch_rect.width);
    try std.testing.expectEqual(@as(f32, 108), buttons_y);
}

// Locks the idle screen (section 6): after the first frame nothing is owed and the timer is off;
// the flow toggle starts the timer, a second toggle stops it, and nothing is owed after.
test "the screen is idle with flow off" {
    const app = new_app();
    const cx = frame(app);
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!cx.timer_on);
    try std.testing.expect(!ui.draw_frame(App, app, cx, 1280, 720, 120));
    app.set_flow(cx, true);
    try std.testing.expect(cx.timer_on);
    app.timer(cx, 1000);
    app.timer(cx, 1234);
    try std.testing.expectEqual(@as(u64, 234), app.flow_elapsed_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 4.68), app.offset(), 1e-5);
    app.set_flow(cx, false);
    try std.testing.expect(!cx.timer_on);
    _ = frame(app);
    try std.testing.expect(!ui.draw_frame(App, app, cx, 1280, 720, 120));
}

// Locks the cells' units: 1.2k, 0.45, 3.0dB, 50%, 0.60, 0.35, 12ms, 30%, and the boxes' 440,
// 1200, and 0.80.
test "cells write their values in their units" {
    const expected = [_][]const u8{ "1.2k", "0.45", "3.0dB", "50%", "0.60", "0.35", "12ms", "30%" };
    for (cell_specs, expected) |spec, shown| {
        var bytes: [value_cap]u8 = undefined;
        try std.testing.expectEqualStrings(shown, value_text(&bytes, spec, spec.value));
    }
    const boxes_expected = [_][]const u8{ "440", "1200", "0.80" };
    for (box_specs, boxes_expected) |spec, shown| {
        var bytes: [value_cap]u8 = undefined;
        try std.testing.expectEqualStrings(shown, value_text(&bytes, spec, spec.value));
    }
}

// Locks the scenarios: each replays headless to its frame count with nothing overflowing.
test "the scenarios replay headless" {
    for (App.scenarios) |scenario| {
        const app = new_app();
        try replay(app, scenario.name);
        try std.testing.expectEqual(@as(u32, 0), fixture.context.draw.overflow_count);
    }
}

const wide: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };

/// A fresh app, `scheme` set, and a frame begun, for drawing pieces alone.
fn skin_frame(scheme: theme.Scheme) *Context {
    _ = new_app();
    const cx = &fixture.context;
    cx.set_theme(scheme);
    cx.begin_frame(1280, 720, 120);
    return cx;
}

fn cell_look(row: Rect, value: f32) widgets.KnobLook {
    return .{
        .row = row,
        .clip = wide,
        .ring = widgets.ring_min,
        .value = value,
        .hover = 0,
        .accent = kit.paint_of(.{ 1, 1, 1, 1 }, 0),
        .name = "RES",
        .value_text = "0.45",
    };
}

/// The first Box whose rect is `rect`.
fn box_at(cx: *Context, rect: Rect) ?quads.Box {
    for (cx.draw.items(quads.Box)) |box| {
        if (std.meta.eql(box.rect, rect.array())) return box;
    }
    return null;
}

// Locks the parameter cell (looks.zig, section 3): under Codex (outlined) a 68 x 48 cell at 0.5
// draws no face, an underline inset by 6 and lifted 4, (106, 142, 56, 2) in `colors.track`, and
// its value part 28 wide in `colors.value`; under Patch (filled) a face in `colors.track` with
// radius 2 and the underline flush along its bottom; the hit shape is the whole cell. The `drag`
// scenario moves box B from 0.50 to 0.75 (30 px of `drag_span_px` 120) and reports it.
test "a parameter cell bars its value and takes presses anywhere" {
    const row: Rect = .{ .x = 100, .y = 100, .width = 68, .height = 48 };
    var cx = skin_frame(looks.codex.scheme);
    const shape = looks.Skin.knob(cx, cell_look(row, 0.5)).?;
    _ = cx.end_frame();
    const codex = &looks.codex.scheme;
    try std.testing.expectEqual(row, shape.rect);
    try std.testing.expectEqual(@as(f32, 2), shape.radius);
    const boxes = cx.draw.items(quads.Box);
    try std.testing.expectEqual(@as(usize, 2), boxes.len);
    try std.testing.expectEqual([4]f32{ 106, 142, 56, 2 }, boxes[0].rect);
    try std.testing.expectEqual(codex.colors.track, boxes[0].fill);
    try std.testing.expectEqual([4]f32{ 106, 142, 28, 2 }, boxes[1].rect);
    try std.testing.expectEqual(codex.colors.value, boxes[1].fill);
    cx = skin_frame(looks.patch_look.scheme);
    _ = looks.Skin.knob(cx, cell_look(row, 0.5)).?;
    _ = cx.end_frame();
    const patch_boxes = cx.draw.items(quads.Box);
    try std.testing.expectEqual(looks.patch_look.scheme.colors.track, patch_boxes[0].fill);
    try std.testing.expectEqual(@as(f32, 2), patch_boxes[0].radius);
    try std.testing.expectEqual([4]f32{ 100, 146, 34, 2 }, patch_boxes[2].rect);
    const app = new_app();
    try replay(app, "drag");
    try std.testing.expectEqual(@as(f32, 0.75), app.boxes[1].value);
    try std.testing.expectEqualStrings("lpf~ 0.75", app.status_text());
}

// Locks the object box (looks.zig, section 3a): a 144 x 28 box at 0.5 under Patch is a face in
// its accent paint with no border, and a value bar along its bottom 72 wide and 3 high
// (form.mark + 1) in `colors.value`; under Codex the face has a 1 px border in `colors.control`.
test "an object box bars its value along its bottom" {
    const row: Rect = .{ .x = 688, .y = 136, .width = 144, .height = 28 };
    var look = cell_look(row, 0.5);
    look.accent = kit.paint_of(looks.patch_look.object_fill, 2);
    var cx = skin_frame(looks.patch_look.scheme);
    _ = looks.Object.knob(cx, look).?;
    _ = cx.end_frame();
    var boxes = cx.draw.items(quads.Box);
    try std.testing.expectEqual(looks.patch_look.object_fill, boxes[0].fill);
    try std.testing.expectEqual(@as(f32, 0), boxes[0].border_width);
    try std.testing.expectEqual([4]f32{ 688, 161, 72, 3 }, boxes[1].rect);
    try std.testing.expectEqual(looks.patch_look.scheme.colors.value, boxes[1].fill);
    cx = skin_frame(looks.codex.scheme);
    _ = looks.Object.knob(cx, look).?;
    _ = cx.end_frame();
    boxes = cx.draw.items(quads.Box);
    try std.testing.expectEqual(@as(f32, 1), boxes[0].border_width);
    try std.testing.expectEqual(looks.codex.scheme.colors.control, boxes[0].border_color);
}

// Locks the meter (looks.zig, section 3): a 284 x 24 bar at 0.86 draws its track (radius 12
// under Patch, 24 x 0.5, unframed), the 17.04 px past the tick in `accents[1]` reaching 12 back,
// the fill to the tick over it, and a 1 px tick at x + 227.2 in `colors.text`; under Paper the
// radius is 0 and the track is framed by a 1 px hairline in `colors.control`.
test "the meter bar labels inside and ticks at 0.8" {
    const row: Rect = .{ .x = 20, .y = 100, .width = 284, .height = 24 };
    const look: widgets.MeterLook = .{ .row = row, .clip = wide, .value = 0.86, .track_h = 24, .name = "CPU" };
    var cx = skin_frame(looks.patch_look.scheme);
    looks.Skin.meter(cx, look);
    _ = cx.end_frame();
    const scheme = &looks.patch_look.scheme;
    const boxes = cx.draw.items(quads.Box);
    try std.testing.expectEqual(@as(usize, 4), boxes.len);
    try std.testing.expectEqual(@as(f32, 12), boxes[0].radius);
    try std.testing.expectEqual(@as(f32, 0), boxes[0].border_width);
    try std.testing.expectApproxEqAbs(@as(f32, 17.04 + 12), boxes[1].rect[2], 1e-3);
    try std.testing.expectEqual(scheme.accents[1], boxes[1].fill);
    try std.testing.expectApproxEqAbs(@as(f32, 227.2), boxes[2].rect[2], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20 + 227.2), boxes[3].rect[0], 1e-3);
    try std.testing.expectEqual(@as(f32, 1), boxes[3].rect[2]);
    try std.testing.expectEqual(scheme.colors.text, boxes[3].fill);
    try std.testing.expect(cx.draw.items(quads.Glyph).len > 0);
    cx = skin_frame(looks.paper.scheme);
    looks.Skin.meter(cx, look);
    _ = cx.end_frame();
    try std.testing.expectEqual(@as(f32, 0), cx.draw.items(quads.Box)[0].radius);
    try std.testing.expectEqual(@as(f32, 1), cx.draw.items(quads.Box)[0].border_width);
}

// Locks the section header (looks.zig, section 3): under HUD its rule starts 8 px after the
// label's extent (`measure` less the hanging gap, step 64), rounded up, past the 24 px chevron
// cell, is `form.hairline` (1) high in `colors.control`, and runs to the header's end; with a
// tab, the text after it ends the header and the rule stops 8 px before it.
test "the disclosure rule starts after the label" {
    const header: Rect = .{ .x = 24, .y = 72, .width = 284, .height = 28 };
    var cx = skin_frame(looks.hud.scheme);
    var look: widgets.DisclosureLook = .{ .rect = header, .clip = wide, .label = "RACK CONTROL", .turn = 1, .hover = 0, .focused = false };
    const shape = looks.Skin.disclosure(cx, look).?;
    _ = cx.end_frame();
    const hud = &looks.hud.scheme;
    const extent = text.measure(hud.heading, "RACK CONTROL") - text.tracking_px(hud.heading);
    const rule = cx.draw.items(quads.Box)[0];
    try std.testing.expectEqual(@ceil(24 + 24 + extent + 8), rule.rect[0]);
    try std.testing.expectEqual(@as(f32, 86), rule.rect[1]);
    try std.testing.expectEqual(@as(f32, 1), rule.rect[3]);
    try std.testing.expectEqual(@as(f32, 24 + 284), rule.rect[0] + rule.rect[2]);
    try std.testing.expectEqual(hud.colors.control, rule.fill);
    try std.testing.expectEqual(header, shape.rect);
    try std.testing.expectEqual(@as(usize, 1), cx.draw.items(quads.Path).len);
    look.label = "RACK CONTROL\t2 OF 2";
    cx = skin_frame(hud.*);
    _ = looks.Skin.disclosure(cx, look).?;
    _ = cx.end_frame();
    const count = @ceil(text.measure(hud.name, "2 OF 2") - text.tracking_px(hud.name) + 8);
    const short = cx.draw.items(quads.Box)[0];
    try std.testing.expectEqual(24 + 284 - count, short.rect[0] + short.rect[2]);
}

// Locks the card (looks.zig, section 3): "PATCH\nosc~ 440\nthe tone" draws the caption in
// `name`'s colour, the title larger in `colors.text`, and the line in `name`; "osc~" alone is
// one title line in `colors.text`; the face is `fill`, or `colors.panel` without one, with a
// hairline in `colors.control`.
test "the tooltip card splits caption, title, and line" {
    const card: Rect = .{ .x = 858, .y = 136, .width = 248, .height = 64 };
    const scheme = &looks.patch_look.scheme;
    var cx = skin_frame(scheme.*);
    looks.Skin.tooltip(cx, .{ .rect = card, .clip = wide, .label = "PATCH\nosc~ 440\nthe tone" });
    _ = cx.end_frame();
    try std.testing.expectEqual(scheme.colors.panel, cx.draw.items(quads.Box)[0].fill);
    try std.testing.expectEqual(scheme.colors.control, cx.draw.items(quads.Box)[0].border_color);
    const glyphs = cx.draw.items(quads.Glyph);
    try std.testing.expectEqual(scheme.name.color, glyphs[0].color);
    try std.testing.expectEqual(scheme.name.color, glyphs[glyphs.len - 1].color);
    var tallest: f32 = 0;
    for (glyphs) |glyph| {
        if (std.meta.eql(glyph.color, scheme.colors.text)) tallest = @max(tallest, glyph.rect[3]);
    }
    try std.testing.expect(tallest > glyphs[0].rect[3]);
    const fill = [4]f32{ 0.2, 0.2, 0.2, 1 };
    cx = skin_frame(scheme.*);
    looks.Skin.tooltip(cx, .{ .rect = card, .clip = wide, .label = "osc~", .fill = fill });
    _ = cx.end_frame();
    try std.testing.expectEqual(fill, cx.draw.items(quads.Box)[0].fill);
    for (cx.draw.items(quads.Glyph)) |glyph| try std.testing.expectEqual(scheme.colors.text, glyph.color);
}

/// Boxes of the last frame `width` by `height` filled with `fill`.
fn count_boxes(cx: *Context, width: f32, height: f32, fill: [4]f32) u32 {
    var count: u32 = 0;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.rect[2] == width and box.rect[3] == height and std.meta.eql(box.fill, fill)) count += 1;
    }
    return count;
}

// Locks the decorations (section 4): Paper and Codex put a 4 x 4 port in `Look.port` on each of
// the 12 object buttons, the first at the top-right of "osc~"; HUD draws 8 thin bracket arms
// (16 x 1 and 1 x 16) inside the patch viewport's corners and nothing else does; with
// `theme.dark` set and HUD's look the brackets still draw: they follow the look, not the
// scheme.
test "decorations follow the look, not the scheme" {
    const ports = [4]u32{ 12, 12, 0, 0 };
    const arms = [4]u32{ 0, 0, 0, 4 };
    for (looks.all, ports, arms, 0..) |look, port_count, arm_count, index| {
        const app = new_app();
        app.switch_to(&fixture.context, @intCast(index));
        const cx = frame(app);
        try std.testing.expectEqual(port_count, count_boxes(cx, port_side, port_side, look.port));
        try std.testing.expectEqual(arm_count, count_boxes(cx, bracket_arm, 1, look.scheme.colors.control));
        try std.testing.expectEqual(arm_count, count_boxes(cx, 1, bracket_arm, look.scheme.colors.control));
    }
    const app = new_app();
    const cx = frame(app);
    const osc = cx.find(app.objects[0].id).?;
    try std.testing.expect(box_at(cx, .{ .x = osc.rect[0] + osc.rect[2] - 3, .y = osc.rect[1] - 1, .width = 4, .height = 4 }) != null);
    app.switch_to(cx, 3);
    cx.set_theme(theme.dark);
    _ = frame(app);
    try std.testing.expectEqual(@as(u32, 4), count_boxes(cx, bracket_arm, 1, theme.dark.colors.control));
}

// Locks the ports (patch.zig, section 1): six 6 x 6 squares in `colors.value` under every look,
// A's outlets from (693, 161) and (821, 161).
test "every look draws the boxes' ports" {
    for (looks.all) |look| {
        const cx = skin_frame(look.scheme);
        patch.draw_ports(cx, wide);
        _ = cx.end_frame();
        const boxes = cx.draw.items(quads.Box);
        try std.testing.expectEqual(@as(usize, 6), boxes.len);
        try std.testing.expectEqual([4]f32{ 693, 161, 6, 6 }, boxes[0].rect);
        try std.testing.expectEqual([4]f32{ 821, 161, 6, 6 }, boxes[1].rect);
        for (boxes) |box| try std.testing.expectEqual(look.scheme.colors.value, box.fill);
    }
}

// Locks how each look shows its buttons (`restyle_button`, looks.zig section 3a) and what
// `skins.Default` makes of the forms (step 63): Paper's STOP is filled in `accents[1]` with its
// label in `colors.panel`; Codex's SYNC is tinted, its face the background 18 % of the way to
// `accents[0]`, its edge the label at 0.45 alpha, radius 2; Patch's SYNC is the object face
// with no edge and its label in `accents[0]`; under HUD the switcher's selected tab is filled with
// `accents[0]` and tab 0 is an outline in `colors.control`; under Paper the selected tab has a
// 1 px underline in `accents[0]`.
test "each look shows its buttons, and Default reads the form" {
    const sync_rect: Rect = .{ .x = 24 + button_w + row_gap, .y = buttons_y, .width = button_w, .height = button_h };
    const stop_rect: Rect = .{ .x = 24 + 2 * (button_w + row_gap), .y = buttons_y, .width = button_w, .height = button_h };
    var app = new_app();
    var cx = frame(app);
    const stop = box_at(cx, stop_rect).?;
    try std.testing.expectEqual(looks.paper.scheme.accents[1], stop.fill);
    try std.testing.expectEqual(looks.paper.scheme.colors.panel, app.buttons[2].style.color);
    app.switch_to(cx, 1);
    cx = frame(app);
    const codex = &looks.codex.scheme;
    const tinted = box_at(cx, sync_rect).?;
    var face = looks.mix(codex.colors.background, codex.accents[0], 0.18);
    face[3] = 1;
    try std.testing.expectEqual(face, tinted.fill);
    try std.testing.expectEqual(looks.with_alpha(app.buttons[1].style.color, 0.45), tinted.border_color);
    try std.testing.expectEqual(@as(f32, 2), tinted.radius);
    app.switch_to(cx, 2);
    cx = frame(app);
    const plain = box_at(cx, sync_rect).?;
    try std.testing.expectEqual(looks.patch_look.object_fill, plain.fill);
    try std.testing.expectEqual(@as(f32, 0), plain.border_width);
    try std.testing.expectEqual(looks.patch_look.scheme.accents[0], app.buttons[1].style.color);
    app = new_app();
    app.switch_to(&fixture.context, 3);
    cx = frame(app);
    const area = struct {
        fn of(context: *Context, index: u32) Rect {
            const found = context.find(switcher_id.derive(index)).?;
            return .{ .x = found.rect[0], .y = found.rect[1], .width = found.rect[2], .height = found.rect[3] };
        }
    }.of;
    const hud = &looks.hud.scheme;
    try std.testing.expectEqual(hud.accents[0], box_at(cx, area(cx, 3)).?.fill);
    try std.testing.expectEqual(hud.colors.control, box_at(cx, area(cx, 0)).?.border_color);
    cx = frame(new_app());
    var underline = false;
    for (cx.draw.items(quads.Box)) |box| {
        const inside = box.rect[1] >= switcher_rect.y and box.rect[1] < switcher_rect.y + switcher_rect.height;
        if (inside and box.rect[3] == 1 and std.meta.eql(box.fill, looks.paper.scheme.accents[0])) underline = true;
    }
    try std.testing.expect(underline);
}

// Locks the switch (section 1): replaying `switch` (keys 2, 3, 4, 1) ends on Paper's scheme with
// the same instance records as `still`, and every restyled paint is Paper's: the slider fill in
// `colors.value`, the toggle's accent `accents[0]`, the PLAY paint the object fill; under Patch
// the PLAY paint is Patch's object fill with radius 2 and the patch panel is bare.
test "a switch round trip leaves no trace" {
    const still = new_app();
    try replay(still, "still");
    const boxes_still = fixture.context.draw.items(quads.Box).len;
    const glyphs_still = fixture.context.draw.items(quads.Glyph).len;
    var first_box: [256]quads.Box = undefined;
    @memcpy(first_box[0..@min(256, boxes_still)], fixture.context.draw.items(quads.Box)[0..@min(256, boxes_still)]);
    const app = new_app();
    try replay(app, "switch");
    const cx = &fixture.context;
    try std.testing.expect(std.meta.eql(cx.theme().*, looks.paper.scheme));
    try std.testing.expectEqual(@as(u32, 0), app.look);
    try std.testing.expectEqual(boxes_still, cx.draw.items(quads.Box).len);
    try std.testing.expectEqual(glyphs_still, cx.draw.items(quads.Glyph).len);
    for (first_box[0..@min(256, boxes_still)], cx.draw.items(quads.Box)[0..@min(256, boxes_still)]) |a, b| {
        try std.testing.expect(std.meta.eql(a, b));
    }
    const paper = &looks.paper;
    try std.testing.expectEqual(kit.paint_of(paper.scheme.colors.value, 0), app.level.fill);
    try std.testing.expectEqual(paper.scheme.accents[0], app.sync.accent.?);
    try std.testing.expectEqual(kit.paint_of(paper.object_fill, 0), app.buttons[0].paint);
    app.switch_to(cx, 2);
    try std.testing.expectEqual(kit.paint_of(looks.patch_look.object_fill, 2), app.buttons[0].paint);
    try std.testing.expectEqual(@as(f32, 0), app.patch_paint.a);
}

comptime {
    patchwork.app.check(App);
}

test {
    _ = looks;
    _ = patch;
    _ = ground_file;
    _ = faces;
}

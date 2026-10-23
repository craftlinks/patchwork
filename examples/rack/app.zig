//! Demo: a synthesizer rack of panels of knobs and meters, beside a list of 1,000 presets.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Layout While Drawing
//! The rack owns its widgets as plain arrays (`knobs`, `meters`) and lays them out while it
//! draws, with nested `cx.begin` and `cx.end` (`ui/cx.zig`). Nesting is the call structure:
//! ```text
//! frame          flow down, padding 16, spacing 8
//!   header       fill by header_px
//!   body         fill by fill, flow right, spacing 8
//!     panels     room - preset_column_px - 8 by fill, flow down, spacing 8
//!       panel    fill by share(3), padding 8, clipped    (Panel.begin draws the face)
//!         band   fill by min(title_band_px, room)         title, badge, LED (overlay flow)
//!         body   fill by fill, flow right
//!           row  knob_row_width(body) by fill             knob cells 144 by 72, gap 8
//!           cell meter_column_px by fill, clipped         meter
//!     presets    preset_column_px by fill, flow down, spacing 8
//!       list     fill by room - status - 8 (capped), padding 8; a view of 1,000 rows
//!       status   fill by status_px                        the last action
//! ```
//! Three rules need a little explicit logic, written against `cx.remaining()` and
//! `cx.fits()` instead of a solver: the panels take what the preset column leaves (a main
//! fill would take it all), a knob cell is drawn only if its whole box fits the row beside
//! the meter and the body height (otherwise it is walked but not drawn, so the cells keep
//! their positions), and the meter is drawn only when the body is at least
//! `meter_column_px` wide and has positive height; without it the knobs take the full body.
//! The header rect is always walked, so the panels start at the same y whether or not the
//! window can hold the header's text. Worked layouts: tests "rack layout at 1280 by 720",
//! "rack layout at 800 by 600", "a narrow window keeps only knobs that clear the meter", and
//! "a short window hides knobs that would leave the panel".
//!
//! ### Scissor-Free Clipping
//! Panels are clipping containers, so knob faces and title text clip to their panel. The
//! meter sits in its own clipping cell because its track has a fixed height
//! (`widgets.meter_track_h`) and would otherwise cover the panel title on a short panel. The
//! shader masks fragments outside each instance's clip; no GPU scissor state is involved.
//!
//! ## 2. Events and Actions
//! `event` routes every event, `.frame` included, to every knob's `handle`, which resolves it
//! against the areas of the last draw; knobs record their ring as a wheel area while drawing.
//! A `changed` action rewrites the status line ("filter.cut changed 0.42"); meters are
//! passive.
//!
//! ## 2a. Presets and the Status Line
//! The preset list is a `ui.List` of `preset_count` rows of `preset_row_px` in a view
//! (`cx.begin_view`). `draw` asks `List.visible` for the rows under the viewport, skips the
//! rest with `cx.skip`, and stores the range it drew; `event` resolves hits only for that
//! range, so a frame and an event both cost the visible rows, not 1,000. Each drawn row
//! records an area; a release inside a row selects it, and the selected and hovered rows
//! draw a highlight. The view's height is capped so at most `preset_rows_max` rows are ever
//! visible, which bounds the pools at any window size. The status line is formatted into a
//! fixed `[status_cap]u8` from the rack's own name tables; the comptime block proves the
//! longest message fits.
//!
//! ## 3. Draw Types, Layers, and the Title Band
//! `config.draw` registers the library's `Box`, `Arc`, `Glyph`, and `Image` and the rack's
//! own `Led` (`led.zig`). Each panel's title band carries the procedural badge (`badge.zig`,
//! an `Image` of the texture `init` creates) at its left end and an LED centered over the
//! meter track whose brightness is that panel's meter level; the title is centered between
//! them. Everything is on the base layer except the tooltip.
//!
//! ## 3a. Header and Text Styles
//! The header bar holds the tempo readout (`tempo_runs`: "121.00" in 32 px mono and " BPM"
//! in 14 px bold, one baseline through `text.place_runs`) at its left and `patch_author`
//! (non-ASCII, with composite glyphs) right-aligned in the rest, cut with an ellipsis when it
//! does not fit. Panel titles use `title_style` (bold 14 px).
//!
//! ## 3b. Tooltip
//! Hovering a knob for `tooltip_delay_ms` shows its name and value in a bordered box beside
//! the ring. The box overlaps the neighbouring knob's name, so it goes on the overlay layer,
//! which is drawn after every base batch. The delay is a `dwell` animator keyed by the
//! hovered knob's id (`cx.hovered()`); a change of hovered knob restarts it. `event` owes a
//! redraw only when the tooltip appears or disappears, so the dwell frames between draw
//! nothing. The tooltip is anchored to the knob's area (`cx.find`) and records no area of
//! its own, so it never takes the hover from the knob under it. Test "the tooltip box covers
//! the neighbour's text on the overlay layer" locks the rule.
//!
//! ## 4. Meter Data Flow
//! The host calls `App.timer(cx, now_ms)` every `config.timer_period_ms`:
//! ```text
//! levels.sample(now_ms) -> Meter.set_value per meter -> cx.redraw() only if a value changed
//! ```
//! `draw` reads only the stored `meter.value`, and knob gestures never write meter values;
//! test "timer writes the sample and a knob drag does not" locks both.
//!
//! ## 5. TigerStyle Invariants
//! - Widget arrays are fixed at `panel_count` and `knob_count`; there is no allocation.
//! - Every loop is bounded by `panel_count`, `knobs_per_panel`, or `preset_rows_max`.
//! - The comptime block checks the worst case of every pool, the batch list, and the areas.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const animator = patchwork.animator;
const text = patchwork.text;
const quads = patchwork.draw;
const input = patchwork.input;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const levels = @import("levels.zig");
const led = @import("led.zig");
const badge = @import("badge.zig");

const Rect = quads.Rect;

/// Panels in the rack.
pub const panel_count: u32 = 3;

/// Knobs in one panel row.
pub const knobs_per_panel: u32 = 4;

/// Knobs in the rack, indexed `panel * knobs_per_panel + knob`.
pub const knob_count: u32 = panel_count * knobs_per_panel;

const frame_padding: quads.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
const panel_padding: quads.Inset = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 };
const panel_gap_px: f32 = 8;
const title_band_px: f32 = 24;
const meter_column_px: f32 = 80;
const knob_cell_px: f32 = 144;
const knob_gap_px: f32 = 8;
const panel_radius: f32 = 8;

const panel_names = [_][]const u8{ "osc", "filter", "amp" };

/// Header bar above the panels: its height. The gap below it is `panel_gap_px`.
const header_px: f32 = 52;
/// Horizontal inset of the header text from the bar's edges.
const header_inset_px: f32 = 16;
const header_radius: f32 = 8;

/// The header's tempo readout: a 32 px monospace value and a bold unit, sharing a baseline.
const tempo_value = "121.00";
const tempo_unit = " BPM";
const tempo_runs = [_]text.Run{
    .{
        .style = .{ .face = .mono, .size = 32, .color = theme.chrome.text },
        .bytes = tempo_value,
    },
    .{
        .style = .{ .face = .sans_bold, .size = 14, .color = theme.chrome.text },
        .bytes = tempo_unit,
    },
};

/// A non-ASCII label (composite glyphs: u and o with diaeresis, e acute, middle dot),
/// right-aligned in the header and cut with an ellipsis when the bar is narrow.
const patch_author = "J\u{fc}rgen K\u{f6}hler \u{b7} Caf\u{e9}";
const author_style: text.Style = .{ .face = .sans, .size = 16, .color = theme.chrome.text };

/// Panel titles: bold 14 px.
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.chrome.text };

/// Inked glyphs the header draws at most: the tempo runs and the author label.
const header_glyph_cap: u32 = 32;

/// Hover time before a knob's tooltip appears.
pub const tooltip_delay_ms: f32 = 500;

/// Tooltip box relative to the knob cell. A cell's name column (`widgets.name_box`) spans
/// 72 to 144 px into the cell and the next cell starts 152 px in, so a box from 128 to 304
/// clears the rack's short names centered at 108 and covers the whole neighbouring name
/// column (224 to 296).
const tooltip_offset_x: f32 = 128;
const tooltip_offset_y: f32 = 4;
const tooltip_width: f32 = 176;
const tooltip_height: f32 = 32;
const tooltip_radius: f32 = 6;
const tooltip_border_px: f32 = 1;
const tooltip_fill: [4]f32 = .{ 0.08, 0.09, 0.11, 1 };

/// Badge quad edge in the title band, in logical pixels, and its inset from the band's left.
const badge_px: f32 = 20;
const badge_inset_px: f32 = 2;

/// LED color: the theme's meter green.
const led_color = theme.chrome.meter;

/// The preset column: its width, rows, and the cap on visible rows (module guide, 2a).
const preset_column_px: f32 = 240;
const preset_count: u32 = 1000;
const preset_row_px: f32 = 24;
const preset_rows_max: u32 = 48;
/// The tallest viewport: at most `preset_rows_max` rows overlap it at any offset, counting a
/// partial row at each end.
const preset_view_max_px: f32 = @as(f32, @floatFromInt(preset_rows_max - 2)) * preset_row_px;
const preset_inset_px: f32 = 8;
const preset_radius: f32 = 4;
const preset_list: ui.List = .{ .row_height = preset_row_px, .count = preset_count };
/// The selected row's highlight: the first knob accent, dark enough under the light text.
const selected_fill: [4]f32 = .{
    widgets.accents[0].r,
    widgets.accents[0].g,
    widgets.accents[0].b,
    widgets.accents[0].a,
};
const preset_view_id = ui.id("presets", 0);
/// Bytes of a row name: "preset " and up to three digits.
const preset_name_cap: u32 = 10;
/// Inked glyphs of a row name at most: its bytes without the space.
const preset_glyphs: u32 = preset_name_cap - 1;

/// The status line under the list and its fixed buffer.
const status_px: f32 = 24;
const status_cap: u32 = 48;
const status_style: text.Style = .{ .face = .sans, .size = 14, .color = theme.chrome.text };

/// Pool, batch, and area capacities. The comptime block checks each against the worst case.
const box_cap: u32 = 24;
const arc_cap: u32 = 32;
const glyph_cap: u32 = 768;
const image_cap: u32 = 4;
const led_cap: u32 = 4;
const batch_cap: u32 = 16;
const area_cap: u32 = 64;

/// Bytes of the tooltip text: a name of up to 8, a space, and the 4-byte value.
const tooltip_text_cap: u32 = 13;

const knob_table = [_]struct { name: []const u8, value: f32 }{
    .{ .name = "rate", .value = 0.25 },
    .{ .name = "fine", .value = 0.50 },
    .{ .name = "wave", .value = 0.75 },
    .{ .name = "mix", .value = 0 },
    .{ .name = "cut", .value = 0.50 },
    .{ .name = "res", .value = 0.25 },
    .{ .name = "env", .value = 0.50 },
    .{ .name = "key", .value = 1 },
    .{ .name = "gain", .value = 0.50 },
    .{ .name = "pan", .value = 0.50 },
    .{ .name = "atk", .value = 0.25 },
    .{ .name = "rel", .value = 0.75 },
};

const Context = patchwork.app.Context(App);

/// The rack app: panels of knobs and meters. `timer` writes the procedural meter levels at
/// the period in `config`.
pub const App = struct {
    knobs: [knob_count]widgets.Knob,
    meters: [panel_count]widgets.Meter,
    /// Hover time toward the tooltip; see the module guide, section 3b.
    dwell: animator.Animator,
    /// The knob `dwell` is timing, or null when no knob is hovered.
    dwell_knob: ?u32,
    /// The badge texture and its pixels, which must outlive the stream that uploads them.
    badge_texture: quads.TextureId,
    badge_pixels: [badge.bytes]u8,
    /// The preset list's offset, the rows the last draw drew, and the selected row.
    presets: ui.ViewState,
    preset_range: ui.List.Range,
    preset_selected: ?u32,
    /// The last action, in `status[0..status_len]`.
    status: [status_cap]u8,
    status_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork",
        .timer_period_ms = levels.meter_period_ms,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Image, .cap = image_cap },
            .{ .type = led.Led, .cap = led_cap },
        },
        .batch_cap = batch_cap,
        .area_cap = area_cap,
    };

    /// Builds every widget and generates the badge texture.
    pub fn init(app: *App, textures: *quads.Textures) void {
        badge.fill(&app.badge_pixels);
        app.badge_texture = textures.create(.rgba8, badge.side, badge.side);
        textures.write(app.badge_texture, .{
            .x = 0,
            .y = 0,
            .width = badge.side,
            .height = badge.side,
        }, &app.badge_pixels);
        app.dwell = animator.Animator.init(1.0 / tooltip_delay_ms);
        app.dwell_knob = null;
        for (&app.knobs, knob_table, 0..) |*knob, spec, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            const id = ui.id("knob", @intCast(index));
            knob.* = widgets.Knob.init(id, spec.name, spec.value, accent);
        }
        for (&app.meters) |*meter| meter.* = .{ .name = "", .value = 0.5 };
        app.presets = ui.ViewState.init();
        app.preset_range = .{ .first = 0, .end = 0 };
        app.preset_selected = null;
        app.status = @splat(0);
        app.status_len = 0;
        app.set_status(&.{"ready"});
        assert(app.knobs[knob_count - 1].value == knob_table[knob_count - 1].value);
        assert(!app.dwell.live());
    }

    /// Routes the event to every knob, the preset view, and the rows it drew last, then times
    /// the tooltip.
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.knobs, 0..) |*knob, index| {
            switch (knob.handle(cx, event_value)) {
                .changed => app.note_change(cx, @intCast(index)),
                .none, .released => {},
            }
        }
        _ = app.presets.handle(cx, preset_view_id, event_value);
        var row = app.preset_range.first;
        while (row < app.preset_range.end) : (row += 1) {
            switch (cx.hit(ui.id("preset", row), event_value)) {
                .hover_in, .hover_out => cx.redraw(),
                .up => |up| if (up.inside) app.select_preset(cx, row),
                .none, .down, .drag, .wheel => {},
            }
        }
        app.retarget_dwell(cx);
        if (event_value == .frame) app.step_dwell(cx, event_value.frame);
        assert(app.dwell_knob == null or app.dwell.target == 1);
    }

    /// Writes the latest samples onto the meters. Owes a draw only when one changes.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        const sampled = levels.sample(now_ms);
        for (&app.meters, sampled) |*meter, value| {
            if (meter.set_value(value)) cx.redraw();
            assert(meter.value == value);
        }
    }

    /// Draws the header, the panels, the preset column, and the tooltip on the overlay layer.
    pub fn draw(app: *App, cx: *Context) void {
        var frame = ui.flow_of(.down);
        frame.padding = frame_padding;
        frame.spacing = panel_gap_px;
        _ = cx.begin(ui.sized(.fill, .fill), frame);
        draw_header(cx, cx.walk(ui.sized(.fill, .{ .fixed = header_px })));
        var body = ui.flow_of(.right);
        body.spacing = panel_gap_px;
        _ = cx.begin(ui.sized(.fill, .fill), body);
        const room = cx.remaining();
        var column = ui.flow_of(.down);
        column.spacing = panel_gap_px;
        const panels_w = @max(0, room.width - preset_column_px - panel_gap_px);
        _ = cx.begin(ui.sized(.{ .fixed = panels_w }, .fill), column);
        var panel_index: u32 = 0;
        while (panel_index < panel_count) : (panel_index += 1) {
            app.draw_panel(cx, panel_index);
        }
        _ = cx.end();
        app.draw_presets(cx);
        _ = cx.end();
        _ = cx.end();
        app.draw_tooltip(cx);
        // A window smaller than one panel has no positive face, so that frame is empty.
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
        assert(cx.draw.layer_now == .base);
    }

    /// The status line's text.
    pub fn status_text(app: *const App) []const u8 {
        assert(app.status_len <= status_cap);
        return app.status[0..app.status_len];
    }

    /// The list in a panel, then the status line under it. Stores the rows it drew.
    fn draw_presets(app: *App, cx: *Context) void {
        var column = ui.flow_of(.down);
        column.spacing = panel_gap_px;
        _ = cx.begin(ui.sized(.{ .fixed = preset_column_px }, .fill), column);
        const room = cx.remaining();
        const list_h = std.math.clamp(
            room.height - status_px - panel_gap_px,
            0,
            preset_view_max_px + panel_padding.top + panel_padding.bottom,
        );
        const face: widgets.Panel = .{ .paint = panel_paint };
        var layout = ui.flow_of(.down);
        layout.padding = panel_padding;
        _ = face.begin(cx, ui.sized(.fill, .{ .fixed = list_h }), layout);
        const fill = ui.sized(.fill, .fill);
        const port = cx.begin_view(preset_view_id, fill, ui.flow_of(.down), &app.presets);
        const range = preset_list.visible(app.presets.scroll_y, port.height);
        assert(range.end - range.first <= preset_rows_max);
        app.preset_range = range;
        cx.skip(@as(f32, @floatFromInt(range.first)) * preset_row_px);
        var row = range.first;
        while (row < range.end) : (row += 1) app.draw_preset(cx, row);
        cx.skip(@as(f32, @floatFromInt(preset_count - range.end)) * preset_row_px);
        cx.end_view();
        _ = cx.end();
        const line = cx.walk(ui.sized(.fill, .{ .fixed = status_px }));
        if (cx.visible(line)) |clip| {
            text.place(cx.drawing(), status_style, app.status_text(), line, clip, .{
                .align_x = .start,
                .align_y = .center,
                .ellipsis = true,
            });
        }
        _ = cx.end();
    }

    /// One preset row: its area, a highlight when selected or hovered, and its name.
    fn draw_preset(app: *const App, cx: *Context, row: u32) void {
        assert(row < preset_count);
        const rect = cx.walk(ui.sized(.fill, .{ .fixed = preset_row_px }));
        const clip = cx.visible(rect) orelse return;
        const id = ui.id("preset", row);
        cx.area(id, rect, 0, ui.cx.plain);
        const selected = app.preset_selected == row;
        if (selected or cx.hovered() == id) {
            const fill = if (selected) selected_fill else theme.chrome.track;
            append_or_skip(cx, quads.Box, null, .{
                .rect = .{ rect.x, rect.y, rect.width, rect.height },
                .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
                .fill = fill,
                .border_color = .{ 0, 0, 0, 0 },
                .radius = preset_radius,
                .border_width = 0,
                .hover = 0,
                .down = 0,
            });
        }
        var bytes: [preset_name_cap]u8 = undefined;
        const name = preset_name(&bytes, row);
        const inset: quads.Inset = .{ .left = preset_inset_px, .top = 0, .right = 0, .bottom = 0 };
        const inner = ui.cx.inset(rect, inset);
        text.place(cx.drawing(), status_style, name, inner, clip, .{
            .align_x = .start,
            .align_y = .center,
            .ellipsis = false,
        });
    }

    /// Selects `row` and reports it on the status line.
    fn select_preset(app: *App, cx: *Context, row: u32) void {
        assert(row < preset_count);
        app.preset_selected = row;
        var bytes: [preset_name_cap]u8 = undefined;
        app.set_status(&.{ preset_name(&bytes, row), " selected" });
        cx.redraw();
        assert(app.preset_selected.? == row);
    }

    /// Reports knob `index`'s new value on the status line: "filter.cut changed 0.42".
    fn note_change(app: *App, cx: *Context, index: u32) void {
        assert(index < knob_count);
        const knob = &app.knobs[index];
        const panel = panel_names[index / knobs_per_panel];
        app.set_status(&.{ panel, ".", knob.name, " changed ", knob.value_text[0..4] });
        cx.redraw();
    }

    /// Joins `parts` into the status buffer. The comptime block bounds every message.
    fn set_status(app: *App, parts: []const []const u8) void {
        var used: u32 = 0;
        for (parts) |part| {
            assert(used + part.len <= status_cap);
            @memcpy(app.status[used..][0..part.len], part);
            used += @intCast(part.len);
        }
        @memset(app.status[used..], 0);
        app.status_len = used;
        assert(app.status_len <= status_cap);
    }

    /// True while the tooltip of `dwell_knob` is showing.
    pub fn tooltip_visible(app: *const App) bool {
        if (app.dwell_knob == null) return false;
        return app.dwell.value == 1;
    }

    /// One panel: the face, the title band, then the knob row and the meter cell.
    fn draw_panel(app: *const App, cx: *Context, panel_index: u32) void {
        assert(panel_index < panel_count);
        const face: widgets.Panel = .{ .paint = panel_paint };
        var layout = ui.flow_of(.down);
        layout.padding = panel_padding;
        layout.clip = true;
        _ = face.begin(cx, ui.sized(.fill, .{ .share = panel_count }), layout);
        const room = cx.remaining();
        const band_h = band_height(room.height);
        const meter_on = room.width >= meter_column_px and room.height - band_h > 0;
        const band = cx.begin(ui.sized(.fill, .{ .fixed = band_h }), ui.flow_of(.overlay));
        const title: widgets.Label = .{ .text = panel_names[panel_index], .style = title_style };
        title.draw(cx, ui.sized(.fill, .fill));
        app.draw_title_marks(cx, panel_index, band, meter_on);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .fill), ui.flow_of(.right));
        const body = cx.remaining();
        _ = cx.begin(ui.sized(.{ .fixed = knob_row_width(body.width) }, .fill), ui.flow_of(.right));
        var knob_index: u32 = 0;
        while (knob_index < knobs_per_panel) : (knob_index += 1) {
            const knob = &app.knobs[panel_index * knobs_per_panel + knob_index];
            if (cx.fits(knob_cell)) knob.draw(cx, knob_cell) else _ = cx.walk(knob_cell);
        }
        _ = cx.end();
        if (meter_on) {
            var cell = ui.flow_of(.down);
            cell.clip = true;
            _ = cx.begin(ui.sized(.{ .fixed = meter_column_px }, .fill), cell);
            app.meters[panel_index].draw(cx, ui.sized(.fill, .fill));
            _ = cx.end();
        }
        _ = cx.end();
        _ = cx.end();
    }

    /// The badge at the band's left end and the LED over the meter track. A band too short
    /// or too narrow for them omits them; the LED needs the meter.
    fn draw_title_marks(
        app: *const App,
        cx: *Context,
        panel_index: u32,
        band: Rect,
        meter_on: bool,
    ) void {
        assert(panel_index < panel_count);
        if (band.height < badge_px) return;
        if (band.width < 4 * badge_px) return;
        const clip = cx.visible(band) orelse return;
        const clip_rect: [4]f32 = .{ clip.x0, clip.y0, clip.x1, clip.y1 };
        const y = band.y + (band.height - badge_px) * 0.5;
        append_or_skip(cx, quads.Image, app.badge_texture, .{
            .rect = .{ band.x + badge_inset_px, y, badge_px, badge_px },
            .clip = clip_rect,
            .uv = .{ 0, 0, 1, 1 },
            .tint = .{ 1, 1, 1, 1 },
        });
        if (!meter_on) return;
        const meter_x = band.x + band.width - meter_column_px;
        const center_x = meter_x + widgets.ring_inset + widgets.ring_size * 0.5;
        const center_y = band.y + band.height * 0.5;
        const level = app.meters[panel_index].value;
        append_or_skip(cx, led.Led, null, led.at(center_x, center_y, led_color, level, clip_rect));
    }

    /// The hovered knob's name and value in a bordered box on the overlay layer, so it
    /// covers the neighbouring knob's text. See the module guide, section 3b.
    fn draw_tooltip(app: *const App, cx: *Context) void {
        if (!app.tooltip_visible()) return;
        const knob = &app.knobs[app.dwell_knob.?];
        const ring = cx.find(knob.id) orelse return;
        const window = cx.clip().?;
        const box = tooltip_rect(ring.rect);
        const previous = cx.draw.layer(.overlay);
        defer _ = cx.draw.layer(previous);
        append_or_skip(cx, quads.Box, null, .{
            .rect = .{ box.x, box.y, box.width, box.height },
            .clip = .{ window.x0, window.y0, window.x1, window.y1 },
            .fill = tooltip_fill,
            .border_color = theme.chrome.text,
            .radius = tooltip_radius,
            .border_width = tooltip_border_px,
            .hover = 0,
            .down = 0,
        });
        var bytes: [tooltip_text_cap]u8 = undefined;
        const label = tooltip_text(&bytes, knob);
        text.place(cx.drawing(), widgets.name_style, label, box, window, widgets.centered);
    }

    /// Restarts the dwell when the hovered knob changed. Owes a draw when that hid the
    /// tooltip.
    fn retarget_dwell(app: *App, cx: *Context) void {
        const next = hovered_knob(app, cx.hovered());
        if (next == app.dwell_knob) return;
        const was_visible = app.tooltip_visible();
        app.dwell = animator.Animator.init(1.0 / tooltip_delay_ms);
        app.dwell_knob = next;
        if (next != null) {
            const aimed = app.dwell.set_target(1);
            assert(aimed);
            cx.keep_animating();
        }
        if (was_visible) cx.redraw();
        assert(!app.tooltip_visible());
    }

    /// Steps the dwell. Owes a draw only on the step that shows the tooltip.
    fn step_dwell(app: *App, cx: *Context, dt_ms: f32) void {
        assert(dt_ms >= 0);
        const was_visible = app.tooltip_visible();
        _ = app.dwell.step(dt_ms);
        if (app.dwell.live()) cx.keep_animating();
        if (!was_visible and app.tooltip_visible()) cx.redraw();
    }
};

/// The face of the rack's panels and the preset panel.
const panel_paint: widgets.Paint = widgets.paint_of(theme.chrome.panel, panel_radius);

/// The knob cell: 144 by 72 after an 8 px gap.
const knob_cell: ui.Walk = .{
    .width = .{ .fixed = knob_cell_px },
    .height = .{ .fixed = widgets.knob_height },
    .margin = .{ .left = knob_gap_px, .top = 0, .right = 0, .bottom = 0 },
};

/// The header bar: a face, the tempo readout at its left, and the author label at its right.
/// A bar too narrow for its text or below the window's bottom draws nothing.
fn draw_header(cx: *Context, bar: Rect) void {
    if (bar.width <= 2 * header_inset_px) return;
    if (bar.y + bar.height > cx.window.height) return;
    const window = cx.clip().?;
    append_or_skip(cx, quads.Box, null, .{
        .rect = .{ bar.x, bar.y, bar.width, bar.height },
        .clip = .{ window.x0, window.y0, window.x1, window.y1 },
        .fill = theme.chrome.panel,
        .border_color = .{ 0, 0, 0, 0 },
        .radius = header_radius,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    });
    const sides: quads.Inset = .{
        .left = header_inset_px,
        .top = 0,
        .right = header_inset_px,
        .bottom = 0,
    };
    const inner = ui.cx.inset(bar, sides);
    const bar_clip = ui.cx.clip_of(bar);
    text.place_runs(cx.drawing(), &tempo_runs, inner, bar_clip, .{
        .align_x = .start,
        .align_y = .center,
        .ellipsis = false,
    });
    // The author takes the space right of the tempo readout and is cut when it does not fit.
    const tempo_width = text.measure(tempo_runs[0].style, tempo_value) +
        text.measure(tempo_runs[1].style, tempo_unit) + header_inset_px;
    if (inner.width <= tempo_width) return;
    const author: Rect = .{
        .x = inner.x + tempo_width,
        .y = inner.y,
        .width = inner.width - tempo_width,
        .height = inner.height,
    };
    text.place(cx.drawing(), author_style, patch_author, author, bar_clip, .{
        .align_x = .end,
        .align_y = .center,
        .ellipsis = true,
    });
}

/// Appends through `cx`, skipping on a full pool or batch list (the context counts it).
fn append_or_skip(cx: *Context, comptime T: type, texture: ?quads.TextureId, instance: T) void {
    assert(instance.rect[2] > 0);
    assert(instance.rect[3] > 0);
    cx.append(T, texture, instance) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// The index of the knob whose id is `hovered`, or null.
fn hovered_knob(app: *const App, hovered: ui.Id) ?u32 {
    if (hovered == .none) return null;
    for (app.knobs, 0..) |knob, index| {
        if (knob.id == hovered) return @intCast(index);
    }
    return null;
}

/// The tooltip box beside the knob cell around `ring` (`widgets.ring_of` inverted).
fn tooltip_rect(ring: [4]f32) Rect {
    const cell_x = ring[0] - widgets.ring_inset;
    const cell_y = ring[1] - (widgets.knob_height - widgets.ring_size) * 0.5;
    const rect: Rect = .{
        .x = cell_x + tooltip_offset_x,
        .y = cell_y + tooltip_offset_y,
        .width = tooltip_width,
        .height = tooltip_height,
    };
    assert(rect.width == tooltip_width);
    assert(rect.x > cell_x);
    return rect;
}

/// Writes "name d.dd" into `out` and returns the used prefix.
fn tooltip_text(out: *[tooltip_text_cap]u8, knob: *const widgets.Knob) []const u8 {
    assert(knob.name.len <= 8);
    assert(knob.value_text[1] == '.');
    const name_len = knob.name.len;
    @memcpy(out[0..name_len], knob.name);
    out[name_len] = ' ';
    @memcpy(out[name_len + 1 ..][0..4], knob.value_text[0..4]);
    const used = name_len + 1 + 4;
    assert(used <= tooltip_text_cap);
    return out[0..used];
}

/// Writes "preset N" into `out` and returns the used prefix.
fn preset_name(out: *[preset_name_cap]u8, row: u32) []const u8 {
    assert(row < preset_count);
    const prefix = "preset ";
    @memcpy(out[0..prefix.len], prefix);
    var digits: [3]u8 = undefined;
    var count: u32 = 0;
    var rest = row;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    assert(count <= digits.len);
    var index: u32 = 0;
    while (index < count) : (index += 1) out[prefix.len + index] = digits[count - 1 - index];
    return out[0 .. prefix.len + count];
}

/// Width left of the meter. Below `meter_column_px` the meter is dropped and the knobs may
/// use the whole body width.
fn knob_row_width(body_w: f32) f32 {
    if (body_w >= meter_column_px) return body_w - meter_column_px;
    return @max(0, body_w);
}

/// A short panel keeps the `title_band_px` title when it fits, and uses the inner height
/// when it does not.
fn band_height(inner_h: f32) f32 {
    return std.math.clamp(inner_h, 0, title_band_px);
}

comptime {
    assert(panel_count == 3);
    assert(knobs_per_panel == 4);
    assert(knob_count == 12);
    assert(levels.meter_count == panel_count);
    // Worst-case boxes: one per panel, two per meter, the tooltip, the header bar, the
    // preset panel, the selected and the hovered row, and the thumb.
    assert(panel_count + panel_count * 2 + 1 + 1 + 1 + 2 + 1 <= box_cap);
    // Worst-case arcs: two per knob (track and value arc).
    assert(knob_count * 2 <= arc_cap);
    // Worst-case glyphs: a label of up to 8 per panel, up to 8 for each knob name and 4 for
    // each value text, the tooltip text, the header, the visible preset rows, and the status
    // line; 75 of 768 to spare.
    assert(panel_count * 8 + knob_count * (8 + 4) + tooltip_text_cap + header_glyph_cap +
        preset_rows_max * preset_glyphs + status_cap + 75 == glyph_cap);
    // The largest row index fits the name buffer, and the longest status messages fit theirs.
    assert(preset_count <= 1000);
    assert("preset ".len + 3 == preset_name_cap);
    var longest_panel: usize = 0;
    for (panel_names) |name| longest_panel = @max(longest_panel, name.len);
    var longest_knob: usize = 0;
    for (knob_table) |spec| longest_knob = @max(longest_knob, spec.name.len);
    assert(longest_panel + 1 + longest_knob + " changed ".len + 4 <= status_cap);
    assert(preset_name_cap + " selected".len <= status_cap);
    // Every codepoint of the header draws at most one glyph.
    const author_codepoints = std.unicode.utf8CountCodepoints(patch_author) catch unreachable;
    assert(tempo_value.len + tempo_unit.len + author_codepoints <= header_glyph_cap);
    // One badge and one LED per panel.
    assert(panel_count <= image_cap);
    assert(panel_count <= led_cap);
    // Base: box, glyph, image, LED, arc; overlay: box and glyph.
    assert(5 + 2 <= batch_cap);
    // Areas: one ring per knob, the preset view and its thumb, and the visible rows.
    assert(knob_count + 2 + preset_rows_max <= area_cap);
    // At most `preset_rows_max` rows overlap the tallest viewport, partial rows included.
    assert(preset_view_max_px / preset_row_px + 2 <= preset_rows_max);
    // The box covers the neighbouring cell's whole name column.
    assert(tooltip_offset_x + tooltip_width >= knob_cell_px + knob_gap_px + 72 + 72);
    assert(knob_table.len == knob_count);
    assert(panel_names.len == panel_count);
    assert(title_band_px == 24);
    assert(meter_column_px == 80);
    assert(knob_cell_px == 144);
}

/// The test app and context: static, like the hosts', so the badge pixels the context's
/// queued write points at stay put, and the pools stay off the stack.
const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

/// A fresh app, initialized against a fresh context the way a host does.
fn new_app() *App {
    fixture.context.init();
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

/// Draws a `width` by `height` frame the way a host does after a resize, then finalizes it.
fn frame_at(app: *App, width: u32, height: u32) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, width, height, 120));
    cx.draw.finalize();
    assert(cx.draw.overflow_count == 0);
    return cx;
}

/// Dispatches `event` the way a host does. Returns true when it owed a draw.
fn send(app: *App, event: input.Event) bool {
    const cx = &fixture.context;
    cx.dirty = false;
    ui.dispatch(App, app, cx, event);
    return cx.dirty;
}

// Pulls the levels, LED, and badge modules' tests into this app's test run.
test {
    _ = levels;
    _ = led;
    _ = badge;
}

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

fn rect_of(values: [4]f32) Rect {
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

/// The ring area knob `index` recorded at the last draw, or null when it was not drawn.
fn ring_at(cx: *const Context, app: *const App, index: u32) ?Rect {
    const area = cx.find(app.knobs[index].id) orelse return null;
    return rect_of(area.rect);
}

/// The center of knob `index`'s ring.
fn ring_center(cx: *const Context, app: *const App, index: u32) input.Point {
    const ring = ring_at(cx, app, index).?;
    return .{ .x = ring.x + ring.width * 0.5, .y = ring.y + ring.height * 0.5 };
}

/// The face of panel `panel_index`: the boxes of panel radius after the header bar's.
fn panel_face(cx: *const Context, panel_index: u32) Rect {
    var seen: u32 = 0;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.radius != panel_radius) continue;
        if (seen == panel_index + 1) return rect_of(box.rect);
        seen += 1;
    }
    unreachable;
}

/// The cell of meter `panel_index`: the clip of its track, or null when it was not drawn.
fn meter_cell(cx: *const Context, panel_index: u32) ?Rect {
    var seen: u32 = 0;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.rect[2] != widgets.meter_track_w) continue;
        if (box.rect[3] != widgets.meter_track_h) continue;
        if (seen == panel_index) {
            return .{
                .x = box.clip[0],
                .y = box.clip[1],
                .width = box.clip[2] - box.clip[0],
                .height = box.clip[3] - box.clip[1],
            };
        }
        seen += 1;
    }
    return null;
}

fn rects_overlap(a: Rect, b: Rect) bool {
    if (a.x + a.width <= b.x) return false;
    if (b.x + b.width <= a.x) return false;
    if (a.y + a.height <= b.y) return false;
    if (b.y + b.height <= a.y) return false;
    return true;
}

// Locks the header, panel, ring, meter, and preset rects, the ring clip, the omitted value
// arc of a zero-valued knob, and that the 1,000-row list draws only its 25 visible rows.
test "rack layout at 1280 by 720" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    // The frame is inset by 16; the header is 52 tall; panels start 8 below it at y = 76.
    // Panel height = (720 - 32 - 52 - 8 - 2 * 8 spacing) / 3 = 204 (`share(3)`). Step 14
    // moved the widths: the preset column takes 240 + 8 of the 1248, leaving 1000 (was 1248).
    try expect_rect(rect_of(cx.draw.items(quads.Box)[0].rect), 16, 16, 1248, 52);
    try expect_rect(panel_face(cx, 0), 16, 76, 1000, 204);
    try expect_rect(panel_face(cx, 1), 16, 288, 1000, 204);
    try expect_rect(panel_face(cx, 2), 16, 500, 1000, 204);
    // First ring: cell x = 16 panel + 8 padding + 8 gap, y = 76 + 8 + 24 band; ring + 8.
    try expect_rect(ring_at(cx, app, 0).?, 40, 116, 56, 56);
    // Meter: right edge of the inner rect (16 + 1000 - 8), 80 wide (x was 1176 before the
    // preset column), body height 204 - 16 - 24.
    try expect_rect(meter_cell(cx, 0).?, 928, 108, 80, 164);
    // Presets: x = 16 + 1000 + 8, list 628 - 24 status - 8 = 596 tall, viewport 580 tall.
    try expect_rect(app.presets.viewport, 1032, 84, 224, 580);
    try std.testing.expectEqual(@as(f32, 24000), app.presets.content_h);
    try std.testing.expectEqual(ui.List.Range{ .first = 0, .end = 25 }, app.preset_range);
    // Boxes: the header, 3 panels, 3 meters * 2 faces, the preset panel, and its thumb.
    // Arcs: 12 knobs * 2 minus the zero-valued knob's arc. Glyphs: titles 3 + 6 + 3, knob
    // names 40, values 12 * 4, the tempo 6 + 3, the author 17 (its two spaces have no ink),
    // 25 preset names (10 * 7 + 15 * 8 = 190), and "ready" (5).
    try std.testing.expectEqual(@as(usize, 12), cx.draw.items(quads.Box).len);
    try std.testing.expectEqual(@as(usize, 23), cx.draw.items(quads.Arc).len);
    try std.testing.expectEqual(@as(usize, 321), cx.draw.items(quads.Glyph).len);
    try std.testing.expectEqual(@as(usize, 3), cx.draw.items(quads.Image).len);
    try std.testing.expectEqual(@as(usize, 3), cx.draw.items(led.Led).len);
    // Areas: 12 rings, the view, 25 rows, and the thumb.
    try std.testing.expectEqual(@as(usize, knob_count + 1 + 25 + 1), cx.area_list().len);
    const mix = ring_at(cx, app, 3).?;
    var arcs: u32 = 0;
    for (cx.draw.items(quads.Arc)) |arc| {
        // The first ring clips to its panel rect.
        if (arc.rect[0] == 40 and arc.rect[1] == 116) {
            try std.testing.expectEqualSlices(f32, &.{ 16, 76, 1016, 280 }, &arc.clip);
        }
        if (arc.rect[0] == mix.x and arc.rect[1] == mix.y) arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
    try std.testing.expect(!cx.dirty);
}

// Locks that a smaller window shrinks panel heights and the meter cell, not the knob cells.
// The preset column leaves the panels 520 of the 768 (was 768), so the 424 px knob row keeps
// two knobs and the meter moves to x = 16 + 520 - 8 - 80 (was 696).
test "rack layout at 800 by 600" {
    const app = new_app();
    const cx = frame_at(app, 800, 600);
    try expect_rect(panel_face(cx, 0), 16, 76, 520, 164);
    try expect_rect(panel_face(cx, 1), 16, 248, 520, 164);
    try expect_rect(panel_face(cx, 2), 16, 420, 520, 164);
    try expect_rect(ring_at(cx, app, 0).?, 40, 116, 56, 56);
    try expect_rect(ring_at(cx, app, 1).?, 192, 116, 56, 56);
    try std.testing.expect(ring_at(cx, app, 2) == null);
    try expect_rect(meter_cell(cx, 0).?, 448, 108, 80, 124);
}

// Locks that `timer` writes meters only when a sample changes and knob drags never do.
test "timer writes the sample and a knob drag does not" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    cx.dirty = false;
    App.timer(app, cx, 0);
    try std.testing.expect(!cx.dirty);
    try std.testing.expectEqual(@as(f32, 0.5), app.meters[0].value);
    App.timer(app, cx, 500);
    try std.testing.expect(cx.dirty);
    const sampled = levels.sample(500);
    try std.testing.expectEqual(@as(f32, 1), sampled[0]);
    try std.testing.expect(sampled[1] != 1);
    for (app.meters, sampled) |meter, value| try std.testing.expectEqual(value, meter.value);
    const amp = app.meters[2].value;
    const center = ring_center(cx, app, 8);
    try std.testing.expect(send(app, .{ .pointer_down = center }));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = center.x, .y = center.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[8].value);
    try std.testing.expectEqual(amp, app.meters[2].value);
    cx.dirty = false;
    App.timer(app, cx, 500);
    try std.testing.expect(!cx.dirty);
}

// Locks ring drag and ring wheel through dispatch, and that a wheel off the ring is ignored.
test "a ring drag and a ring wheel change the knob" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const center = ring_center(cx, app, 0);
    try std.testing.expect(send(app, .{ .pointer_down = center }));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = center.x, .y = center.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[0].value);
    try std.testing.expect(send(app, .{ .pointer_up = .{ .x = center.x, .y = center.y - 60 } }));
    const wheel: input.Wheel = .{ .x = center.x, .y = center.y, .dy = -60 };
    try std.testing.expect(send(app, .{ .wheel = wheel }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = 40, .y = 30 } }));
    try std.testing.expect(!send(app, .{ .wheel = .{ .x = 40, .y = 30, .dy = 40 } }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
}

// Locks that raising a zero-valued knob adds exactly one face.
test "dragging mix off zero adds the value arc" {
    const app = new_app();
    const center = ring_center(frame_at(app, 1280, 720), app, 3);
    try std.testing.expect(send(app, .{ .pointer_down = center }));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = center.x, .y = center.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.5), app.knobs[3].value);
    const drawn = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(usize, 24), drawn.draw.items(quads.Arc).len);
    // The knob's glyphs are unchanged; the status line grew from "ready" (5) to
    // "osc.mix changed 0.50" (18).
    try std.testing.expectEqual(@as(usize, 321 - 5 + 18), drawn.draw.items(quads.Glyph).len);
    try std.testing.expectEqualStrings("osc.mix changed 0.50", app.status_text());
}

// Locks hover easing and that a settled rack stops animating and stays clean.
test "hover on rate eases and a later frame stays clean" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(send(app, .{ .pointer_move = ring_center(cx, app, 0) }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].hover.target);
    try std.testing.expect(ui.animate(App, app, cx, 50));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), app.knobs[0].hover.value, 0.0001);
    try std.testing.expect(cx.dirty);
    // The knob settles, but the tooltip dwell keeps the frames coming until it shows.
    _ = ui.animate(App, app, cx, 50);
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].hover.value);
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(ui.animate(App, app, cx, 100));
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!ui.animate(App, app, cx, 1000));
    try std.testing.expect(app.tooltip_visible());
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expect(!cx.dirty);
}

// Locks that knob cells crossing the meter column are dropped, not painted over the bar.
// 648 px leaves the panels the 272 px knob row a 400 px window gave before the preset column
// took 248 of the width.
test "a narrow window keeps only knobs that clear the meter" {
    const app = new_app();
    const cx = frame_at(app, 648, 720);
    try std.testing.expect(ring_at(cx, app, 0) != null);
    try std.testing.expect(ring_at(cx, app, 1) == null);
    try std.testing.expect(ring_at(cx, app, 2) == null);
    try std.testing.expect(ring_at(cx, app, 3) == null);
    const meter = meter_cell(cx, 0).?;
    try std.testing.expectEqual(@as(f32, 80), meter.width);
    try std.testing.expect(!rects_overlap(ring_at(cx, app, 0).?, meter));
    try std.testing.expect(cx.draw.items(quads.Box).len >= 3);
}

// Locks that a body shorter than a knob row drops the knob instead of leaking into the
// next panel, while the meter keeps a positive cell.
test "a short window hides knobs that would leave the panel" {
    const app = new_app();
    // 260 leaves the panels the 168 px a 200 px window gave before the header.
    const cx = frame_at(app, 1280, 260);
    for (0..knob_count) |index| try std.testing.expect(ring_at(cx, app, @intCast(index)) == null);
    const meter = meter_cell(cx, 0).?;
    try std.testing.expect(meter.height > 0);
    try std.testing.expect(meter.height < widgets.knob_height);
}

// Locks that degenerate windows draw without aborting and draw nothing they cannot hold.
test "a tiny window still draws" {
    const app = new_app();
    try std.testing.expectEqual(@as(usize, 0), frame_at(app, 32, 32).draw.items(quads.Box).len);
    const narrow = frame_at(app, 48, 720);
    try std.testing.expect(narrow.draw.items(quads.Box).len >= 1);
    for (0..knob_count) |index| {
        try std.testing.expect(ring_at(narrow, app, @intCast(index)) == null);
    }
}

const fixture_gpu = struct {
    var renderer: patchwork.renderer.Renderer(Context.DrawContext) = undefined;
    var buffer: patchwork.commands.CommandBuffer = undefined;
};

/// Records the setup stream the way a host does after `App.init`.
fn setup_renderer() void {
    fixture_gpu.renderer.init();
    fixture_gpu.buffer = .init();
    fixture_gpu.renderer.setup(&fixture_gpu.buffer, &fixture.context.draw);
}

/// Draws the app when a draw is owed, the way a host does, then records one 1280 by 720
/// logical frame at `scale_120`.
fn record(app: *App, scale_120: u32) void {
    const cx = &fixture.context;
    _ = ui.draw_frame(App, app, cx, 1280, 720, scale_120);
    assert(cx.draw.overflow_count == 0);
    fixture_gpu.buffer.reset();
    fixture_gpu.renderer.frame(&fixture_gpu.buffer, &cx.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = patchwork.frame.pixel_size(1280, scale_120),
        .height_px = patchwork.frame.pixel_size(720, scale_120),
        .scale_120 = scale_120,
    });
}

/// The `texture_write` ops of the last recorded stream.
fn texture_writes(out: []patchwork.commands.TextureWrite) []patchwork.commands.TextureWrite {
    var reader = fixture_gpu.buffer.reader();
    var count: usize = 0;
    while (reader.next()) |op| {
        switch (op) {
            .texture_write => |write| {
                out[count] = write;
                count += 1;
            },
            else => {},
        }
    }
    return out[0..count];
}

// Locks the rack's command streams. Setup creates five pipelines and both textures (the atlas
// and the badge). The first frame writes the uniform, the atlas rectangle the glyph cache
// rasterized, and the five pools, binds the frame group and unit quad once, and draws one call
// per batch in first-appearance order: boxes, glyphs (atlas), the badge, LEDs, arcs. A scale
// change redraws: it writes the uniform, a new atlas rectangle, and the glyph pool, and no box
// or arc record. A present with nothing owed writes nothing, and a hover frame writes only the
// changed arc records, because every other rebuilt pool is identical.
test "rack frames record the step 13 op sequences" {
    const Code = patchwork.commands.Code;
    const app = new_app();
    setup_renderer();
    var codes: [64]Code = undefined;
    const setup_codes = patchwork.renderer.codes(&fixture_gpu.buffer, &codes);
    var textures: u32 = 0;
    var pipelines: u32 = 0;
    for (setup_codes) |code| {
        if (code == .texture_create) textures += 1;
        if (code == .pipeline_create) pipelines += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), textures);
    try std.testing.expectEqual(@as(u32, 5), pipelines);
    var writes: [8]patchwork.commands.BufferWrite = undefined;

    record(app, 120);
    const first = [_]Code{
        .buffer_write,      .texture_write,     .buffer_write,
        .buffer_write,      .buffer_write,      .buffer_write,
        .buffer_write,      .pass_begin,        .bind_group_set,
        .vertex_buffer_set, .pipeline_set,      .vertex_buffer_set,
        .draw,              .pipeline_set,      .vertex_buffer_set,
        .bind_group_set,    .draw,              .pipeline_set,
        .vertex_buffer_set, .bind_group_set,    .draw,
        .pipeline_set,      .vertex_buffer_set, .draw,
        .pipeline_set,      .vertex_buffer_set, .draw,
        .pass_end_present,
    };
    var atlas: [4]patchwork.commands.TextureWrite = undefined;
    try std.testing.expectEqual(@as(usize, 1), texture_writes(&atlas).len);
    try std.testing.expectEqual(@as(u32, 1024), atlas[0].bytes_per_row);
    const first_codes = patchwork.renderer.codes(&fixture_gpu.buffer, &codes);
    try std.testing.expectEqualSlices(Code, &first, first_codes);
    const batches = fixture.context.draw.batch_list();
    try std.testing.expectEqual(@as(usize, 5), batches.len);
    try std.testing.expectEqual(@as(u8, 0), batches[0].type_id);
    try std.testing.expectEqual(@as(u8, 2), batches[1].type_id);
    try std.testing.expectEqual(@as(u8, 3), batches[2].type_id);
    try std.testing.expectEqual(app.badge_texture, batches[2].texture);
    try std.testing.expectEqual(@as(u8, 4), batches[3].type_id);
    try std.testing.expectEqual(@as(u8, 1), batches[4].type_id);

    record(app, 240);
    const rescaled = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    const resources = &fixture_gpu.renderer.resources;
    try std.testing.expectEqual(@as(usize, 2), rescaled.len);
    try std.testing.expectEqual(resources.uniform_buffer, rescaled[0].id);
    try std.testing.expectEqual(resources.instance_buffers[2], rescaled[1].id);
    try std.testing.expectEqual(@as(usize, 1), texture_writes(&atlas).len);

    record(app, 240);
    try std.testing.expectEqual(@as(usize, 0), patchwork.renderer.writes(
        &fixture_gpu.buffer,
        &writes,
    ).len);
    try std.testing.expectEqual(@as(usize, 0), texture_writes(&atlas).len);

    try std.testing.expect(send(app, .{ .pointer_move = ring_center(&fixture.context, app, 0) }));
    _ = ui.animate(App, app, &fixture.context, 50);
    record(app, 240);
    const hover = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(@as(usize, 1), hover.len);
    const arc_buffer = fixture_gpu.renderer.resources.instance_buffers[1];
    try std.testing.expectEqual(arc_buffer, hover[0].id);
    const arcs = fixture.context.draw.items(quads.Arc);
    try std.testing.expect(hover[0].data.len < arcs.len * @sizeOf(quads.Arc));
}

// Locks the layer rule for the tooltip: it appears only after `tooltip_delay_ms` of hover,
// its box overlaps the neighbouring knob's name glyphs, it sits on the overlay layer with no
// area of its own, and both overlay batches (box, then text) are drawn after every base
// batch. A move to the neighbour hides it.
test "the tooltip box covers the neighbour's text on the overlay layer" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(send(app, .{ .pointer_move = ring_center(cx, app, 0) }));
    var waited: u32 = 0;
    while (waited < 4) : (waited += 1) {
        try std.testing.expect(ui.animate(App, app, cx, 100));
        cx.dirty = false;
    }
    try std.testing.expect(!app.tooltip_visible());
    try std.testing.expect(!ui.animate(App, app, cx, 100));
    try std.testing.expect(app.tooltip_visible());
    try std.testing.expect(cx.dirty);
    _ = frame_at(app, 1280, 720);
    // The same areas as a frame without the tooltip: 12 rings, the view, 25 rows, the thumb.
    try std.testing.expectEqual(@as(usize, knob_count + 1 + 25 + 1), cx.area_list().len);
    const boxes = cx.draw.items(quads.Box);
    const last = boxes.len - 1;
    try std.testing.expectEqual(quads.Layer.overlay, cx.draw.layer_at(quads.Box, @intCast(last)));
    const tip = rect_of(boxes[last].rect);
    const neighbour = ring_at(cx, app, 1).?;
    var covered: u32 = 0;
    for (cx.draw.items(quads.Glyph), 0..) |glyph, index| {
        if (cx.draw.layer_at(quads.Glyph, @intCast(index)) != .base) continue;
        if (glyph.rect[0] < neighbour.x) continue;
        if (rects_overlap(tip, rect_of(glyph.rect))) covered += 1;
    }
    try std.testing.expect(covered >= 1);
    const batches = cx.draw.batch_list();
    const overlay: u8 = @backingInt(quads.Layer.overlay);
    try std.testing.expectEqual(overlay, batches[batches.len - 2].layer);
    try std.testing.expectEqual(@as(u8, 0), batches[batches.len - 2].type_id);
    try std.testing.expectEqual(overlay, batches[batches.len - 1].layer);
    try std.testing.expectEqual(@as(u8, 2), batches[batches.len - 1].type_id);
    for (batches[0 .. batches.len - 2]) |batch| {
        try std.testing.expectEqual(@as(u8, 0), batch.layer);
    }
    try std.testing.expect(send(app, .{ .pointer_move = ring_center(cx, app, 1) }));
    try std.testing.expect(!app.tooltip_visible());
}

// Locks the title band: each panel's badge samples the badge texture and clears the centered
// title text, and each LED's brightness is its panel's meter level.
test "badges clear the title and leds follow the meters" {
    const app = new_app();
    const cx = &fixture.context;
    App.timer(app, cx, 500);
    _ = frame_at(app, 1280, 720);
    const images = cx.draw.items(quads.Image);
    try std.testing.expectEqual(@as(usize, panel_count), images.len);
    for (images) |image| {
        for (cx.draw.items(quads.Glyph)) |glyph| {
            try std.testing.expect(!rects_overlap(rect_of(image.rect), rect_of(glyph.rect)));
        }
    }
    const lights = cx.draw.items(led.Led);
    try std.testing.expectEqual(@as(usize, panel_count), lights.len);
    for (lights, app.meters) |light, meter| {
        try std.testing.expectEqual(meter.value, light.brightness);
    }
}

/// The rect of preset `row` at the last draw.
fn preset_rect(cx: *const Context, row: u32) Rect {
    return rect_of(cx.find(ui.id("preset", row)).?.rect);
}

// Locks preset selection: a release inside a row selects it, reports it on the status line,
// and draws a highlight over exactly that row; a hovered row draws one too.
test "clicking a preset row selects and highlights it" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const point = center_of(preset_rect(cx, 3));
    try std.testing.expect(send(app, .{ .pointer_move = point }));
    try std.testing.expect(!send(app, .{ .pointer_down = point }));
    try std.testing.expect(send(app, .{ .pointer_up = point }));
    try std.testing.expectEqual(@as(?u32, 3), app.preset_selected);
    try std.testing.expectEqualStrings("preset 3 selected", app.status_text());
    _ = frame_at(app, 1280, 720);
    // Rows are the viewport width minus the gutter: 224 - 16 = 208. Row 3 is 3 * 24 down.
    try std.testing.expectEqual(@as(u32, 1), count_highlights(cx));
    for (cx.draw.items(quads.Box)) |box| {
        if (box.rect[2] != 208) continue;
        try std.testing.expectEqualSlices(f32, &.{ 1032, 156, 208, 24 }, &box.rect);
        try std.testing.expectEqualSlices(f32, &selected_fill, &box.fill);
    }
    try std.testing.expect(send(app, .{ .pointer_move = center_of(preset_rect(cx, 5)) }));
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 2), count_highlights(cx));
}

// Locks the virtualized list in the app: a wheel over the rows scrolls the view, the next
// frame draws only the rows under the viewport (412 to 436) with one area each, and clicking
// the first of them selects preset 412.
test "the preset list scrolls and draws only its visible rows" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const top = center_of(preset_rect(cx, 0));
    try std.testing.expect(send(app, .{ .wheel = .{ .x = top.x, .y = top.y, .dy = 412 * 24 } }));
    try std.testing.expectEqual(@as(f32, 412 * 24), app.presets.scroll_y);
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(ui.List.Range{ .first = 412, .end = 437 }, app.preset_range);
    try std.testing.expect(cx.find(ui.id("preset", 411)) == null);
    try std.testing.expect(cx.find(ui.id("preset", 437)) == null);
    try std.testing.expectEqual(@as(usize, knob_count + 1 + 25 + 1), cx.area_list().len);
    const first = preset_rect(cx, 412);
    try std.testing.expectEqual(app.presets.viewport.y, first.y);
    const point = center_of(first);
    _ = send(app, .{ .pointer_down = point });
    _ = send(app, .{ .pointer_up = point });
    try std.testing.expectEqualStrings("preset 412 selected", app.status_text());
    try std.testing.expectEqual(@as(u32, 0), cx.area_overflow);
}

// Locks the status line for a knob: a wheel that turns filter.cut from 0.50 to 0.42 reports
// "filter.cut changed 0.42".
test "a knob change is reported on the status line" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expectEqualStrings("ready", app.status_text());
    const cut = ring_center(cx, app, 4);
    try std.testing.expect(send(app, .{ .wheel = .{ .x = cut.x, .y = cut.y, .dy = 9.6 } }));
    try std.testing.expectEqualStrings("filter.cut changed 0.42", app.status_text());
}

/// Row highlights in the box pool: the boxes as wide as a preset row.
fn count_highlights(cx: *const Context) u32 {
    var count: u32 = 0;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.rect[2] == 208) count += 1;
    }
    return count;
}

fn center_of(rect: Rect) input.Point {
    return .{ .x = rect.x + rect.width * 0.5, .y = rect.y + rect.height * 0.5 };
}

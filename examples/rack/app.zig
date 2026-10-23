//! Demo: a synthesizer rack of panels of knobs, meters, patch cables, and an envelope, beside
//! a list of 1,000 presets.
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
//!       panel    fill by share(4), padding 8, clipped    (Panel.begin draws the face)
//!         band   fill by min(title_band_px, room)         title, badge, LED (overlay flow)
//!         body   fill by fill, flow right
//!           row  knob_row_width(body) by fill             knob cells 144 by 72, gap 8, hubs
//!           cell meter_column_px by fill, clipped         meter (voice panels)
//!           cell fill by fill, margin 8                   envelope display (env panel)
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
//! The envelope panel has no meter: its row is at most four cells wide (`env_row_width`) and
//! the display takes the rest when that is at least `display_min_px`.
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
//! A `changed` action rewrites the status line ("filter.cut changed 0.42"); a right press on
//! a knob resets it to its initial value ("filter.cut reset 0.50"); meters are passive. Knob
//! rings show the grab cursor (grabbing while dragged). The ring's center is the knob's jack
//! hub (section 3c), so a press there patches a cable instead of turning the knob.
//!
//! ## 2b. Renaming a Panel
//! Panel titles are owned bytes (`titles`, at most `title_cap`), each with an area
//! `id("title", panel)`. A double press on a title loads it into the one shared `rename`
//! field (`widgets.TextField`, limit `title_cap`), selects all of it, and gives the field focus;
//! the band then draws the field (I-beam cursor) instead of the title. Enter or a press
//! elsewhere commits ("osc renamed vco"; an empty or unchanged name keeps the old one), and
//! Escape cancels. Copy, cut, and paste work in the field through the host clipboard. Test
//! "a double click renames a panel and Escape cancels" locks the flow.
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
//! `config.draw` registers the library's `Box`, `Arc`, `Glyph`, `Image`, and `Path` and the
//! rack's own `Led` (`led.zig`). Each panel's title band carries the procedural badge
//! (`badge.zig`, an `Image` of the texture `init` creates) at its left end and, on a voice
//! panel, an LED centered over the meter track whose brightness is that panel's meter level;
//! the title is centered between them. Everything is on the base layer except the playhead
//! and the cables (`cable_layer`, 2) and the tooltip (overlay, 4).
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
//! ## 3c. Patch Cables
//! Each drawn knob gets a jack hub: a `hub_radius` disc at its ring's center with its own
//! area `knob.id.derive(jack_salt)`, recorded after the ring so it takes presses inside its
//! radius, with the pointer cursor and no wheel flag, so the wheel still turns the knob.
//! ```text
//! hub down    patching = knob, patch_end = pointer           (the hub captures)
//! hub drag    patch_end = pointer; draw owes a preview cable from the hub to the pointer
//! hub up      the knob whose ring contains the release (found over the knob areas, since a
//!             cable may be the hot area there) gets a cable, unless it is the source, the
//!             pair is already patched either way, or the table is full ("cables full")
//! cable hover redraw; the cable lightens (`hover_lighten`)
//! cable right press removes it ("cable removed")
//! ```
//! `cables[0..cable_count]` holds at most `cable_cap` pairs of knob indices; two exist at
//! `init`. A cable is a cubic from hub to hub whose inner control points hang `cable_sag`
//! below the chord's thirds, drawn with `draw.path.cubic` at alpha `cable_alpha` (so a joint
//! drawn twice would show) on `cable_layer`, with a path area of `cable_width / 2 + 3`. The
//! layer puts cables over panels and text and under the tooltip, and makes a cable's area
//! win over the knobs under it: a right press on a cable over a knob removes the cable, and a
//! wheel over a cable does not reach the knob beneath (accepted). A cable covers its hubs'
//! lower halves, so a second cable starts from the hub's top. The preview records no area, so
//! the knob under the pointer stays hot, and it is drawn last, so earlier points do not move.
//! Tests: "a hub drag patches a cable and a right press removes it", "the worst patch frame
//! fits every pool and a full table refuses", and "cables sag by their length".
//!
//! ## 3d. Envelope Panel
//! The fourth panel's knobs are attack, decay, sustain, and release. Its display draws their
//! envelope as a 64-point `draw.path.polyline` (`envelope_points`): stage lengths
//! `0.05 + attack`, `0.05 + decay`, a fixed hold, and `0.05 + release`, with cubic ease
//! curves, 21 attack points, 20 decay points, the hold's end, and 22 release points, so every
//! corner is a point. The display's area starts the playhead on hover: each `.frame` event
//! while hovered advances `envelope_phase` by `dt / playhead_loop_ms`, calls
//! `cx.keep_animating()` and `cx.redraw()`, and the dot is drawn at the envelope's point on the
//! cable layer. It therefore moves once per displayed frame (the display's refresh rate, 60
//! Hz on most displays), and leaving the display stops the frames: an unhovered rack asks for
//! none (the meters' timer still wakes it). Tests: "the playhead runs only while the display
//! is hovered" and "the envelope polyline follows the four knobs".
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
//! - Widget arrays are fixed at `panel_count`, `meter_panel_count`, `knob_count`, and
//!   `cable_cap`; there is no allocation.
//! - Every loop is bounded by `panel_count`, `knobs_per_panel`, `knob_count`, `cable_cap`, or
//!   `preset_rows_max`.
//! - The comptime block checks the worst case of every pool, the points, the batch list, and
//!   the areas, and sets the box, arc, glyph, path, and area capacities to it exactly.

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

/// Panels in the rack: three voice panels, then the envelope panel.
pub const panel_count: u32 = 4;

/// Panels with a meter and an LED: every panel before the envelope panel.
pub const meter_panel_count: u32 = 3;

/// The envelope panel; its display cell takes the place of the meter (section 3d).
pub const env_panel: u32 = 3;

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

const panel_names = [_][]const u8{ "osc", "filter", "amp", "env" };

/// Bytes of a panel title, and the rename field's width in its band.
pub const title_cap: u32 = 16;
const rename_width_px: f32 = 160;
const rename_id = ui.id("rename", 0);

/// A panel title the user can rename.
pub const Title = struct {
    bytes: [title_cap]u8,
    len: u8,

    pub fn of(utf8: []const u8) Title {
        assert(utf8.len <= title_cap);
        var title: Title = .{ .bytes = @splat(0), .len = @intCast(utf8.len) };
        @memcpy(title.bytes[0..utf8.len], utf8);
        assert(title.len <= title_cap);
        return title;
    }

    pub fn text(self: *const Title) []const u8 {
        assert(self.len <= title_cap);
        return self.bytes[0..self.len];
    }
};

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
const status_cap: u32 = 52;
const status_style: text.Style = .{ .face = .sans, .size = 14, .color = theme.chrome.text };

/// Pool, batch, area, and point capacities. The comptime block checks each against the worst
/// case.
const box_cap: u32 = 37;
const arc_cap: u32 = 32;
const glyph_cap: u32 = 785;
const image_cap: u32 = 4;
const led_cap: u32 = 3;
const path_cap: u32 = 288;
const batch_cap: u32 = 16;
const area_cap: u32 = 104;
const point_cap: u32 = 2048;

/// Cables the rack holds at most (module guide, section 3c).
pub const cable_cap: u32 = 16;

/// The layer cables draw on: above the panels and their text, below the tooltip's overlay.
pub const cable_layer: quads.Layer = @fromBackingInt(2);

/// Cable stroke width and alpha. The alpha is below 1 so a joint drawn twice would show.
pub const cable_width: f32 = 4;
const cable_alpha: f32 = 0.85;

/// The jack hub at the center of each knob's ring: its radius and its id salt.
pub const hub_radius: f32 = 8;
const jack_salt: u64 = 1;
const hub_border_px: f32 = 2;

/// Hubs and cables show the pointer cursor and take no wheel, so the wheel turns the knob.
const patch_flags: ui.Flags = .{ .wheel = false, .focusable = false, .cursor = .pointer };

/// A patch cable from knob `from`'s hub to knob `to`'s hub.
pub const Cable = struct {
    from: u8,
    to: u8,
};

/// The cables at `init`: osc.mix to filter.res and env.attack to amp.tone.
const default_cables = [_]Cable{ .{ .from = 3, .to = 5 }, .{ .from = 12, .to = 11 } };

/// The envelope display cell: its narrowest width, its plot inset, and its corner radius.
const display_min_px: f32 = 96;
const display_inset_px: f32 = 8;
const display_radius: f32 = 6;
const display_fill: [4]f32 = .{ 0.11, 0.12, 0.14, 1 };
const envelope_id = ui.id("envelope", 0);
const envelope_width: f32 = 2;

/// Points of the envelope polyline (section 3d).
pub const envelope_point_count: u32 = 64;

/// One loop of the playhead over the whole envelope, and its dot's edge.
pub const playhead_loop_ms: f32 = 2000;
const playhead_px: f32 = 8;

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
    .{ .name = "drive", .value = 0.25 },
    .{ .name = "tone", .value = 0.75 },
    .{ .name = "attack", .value = 0.20 },
    .{ .name = "decay", .value = 0.30 },
    .{ .name = "sustain", .value = 0.60 },
    .{ .name = "release", .value = 0.40 },
};

const Context = patchwork.app.Context(App);

/// The rack app: panels of knobs and meters. `timer` writes the procedural meter levels at
/// the period in `config`.
pub const App = struct {
    knobs: [knob_count]widgets.Knob,
    meters: [meter_panel_count]widgets.Meter,
    /// Panel titles, the shared rename field, and the panel it renames (section 2b).
    titles: [panel_count]Title,
    rename: widgets.TextField,
    renaming: ?u32,
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
    /// Patch cables in `cables[0..cable_count]` (section 3c).
    cables: [cable_cap]Cable,
    cable_count: u32,
    /// The knob whose hub a cable is being dragged from, and the pointer it is dragged to.
    patching: ?u32,
    patch_end: input.Point,
    /// The envelope playhead: shown and moving while the display is hovered (section 3d).
    envelope_hovered: bool,
    envelope_phase: f32,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork",
        .timer_period_ms = levels.meter_period_ms,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Image, .cap = image_cap },
            .{ .type = led.Led, .cap = led_cap },
            .{ .type = quads.Path, .cap = path_cap },
        },
        .batch_cap = batch_cap,
        .area_cap = area_cap,
        .point_cap = point_cap,
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
        for (&app.titles, panel_names) |*title, name| title.* = Title.of(name);
        app.rename = widgets.TextField.init(rename_id, title_cap, title_style);
        app.renaming = null;
        app.presets = ui.ViewState.init();
        app.preset_range = .{ .first = 0, .end = 0 };
        app.preset_selected = null;
        app.status = @splat(0);
        app.status_len = 0;
        app.set_status(&.{"ready"});
        app.cables = @splat(.{ .from = 0, .to = 0 });
        @memcpy(app.cables[0..default_cables.len], &default_cables);
        app.cable_count = default_cables.len;
        app.patching = null;
        app.patch_end = .{ .x = 0, .y = 0 };
        app.envelope_hovered = false;
        app.envelope_phase = 0;
        assert(app.knobs[knob_count - 1].value == knob_table[knob_count - 1].value);
        assert(!app.dwell.live());
    }

    /// Routes the event to the rename field, the titles, every knob, the preset view, and the
    /// rows it drew last, then times the tooltip.
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.rename.handle(cx, event_value)) {
            .committed => app.finish_rename(cx, true),
            .cancelled => app.finish_rename(cx, false),
            .none, .changed => {},
        }
        var panel: u32 = 0;
        while (panel < panel_count) : (panel += 1) {
            switch (cx.hit(ui.id("title", panel), event_value)) {
                .down => |press| if (press.clicks == 2) app.start_rename(cx, panel),
                else => {},
            }
        }
        for (&app.knobs, 0..) |*knob, index| {
            switch (knob.handle(cx, event_value)) {
                .changed => app.note_knob(cx, @intCast(index), " changed "),
                .reset => app.note_knob(cx, @intCast(index), " reset "),
                .none, .released => {},
            }
        }
        app.route_hubs(cx, event_value);
        app.route_cables(cx, event_value);
        app.route_envelope(cx, event_value);
        _ = app.presets.handle(cx, preset_view_id, event_value);
        var row = app.preset_range.first;
        while (row < app.preset_range.end) : (row += 1) {
            switch (cx.hit(ui.id("preset", row), event_value)) {
                .hover_in, .hover_out => cx.redraw(),
                .up => |up| if (up.inside) app.select_preset(cx, row),
                .none, .down, .drag, .wheel, .secondary => {},
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

    /// Draws the header, the panels, the preset column, the playhead and cables on the cable
    /// layer, and the tooltip on the overlay layer.
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
        app.draw_patch_layer(cx);
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

    /// Reports knob `index`'s new value on the status line: "filter.cut changed 0.42" or
    /// "filter.cut reset 0.50", `verb` being the middle word with its spaces.
    fn note_knob(app: *App, cx: *Context, index: u32, verb: []const u8) void {
        assert(index < knob_count);
        assert(verb.len <= " changed ".len);
        const knob = &app.knobs[index];
        const panel = app.titles[index / knobs_per_panel].text();
        app.set_status(&.{ panel, ".", knob.name, verb, knob.value_text[0..4] });
        cx.redraw();
    }

    /// Opens the rename field on `panel`'s title with all of it selected (section 2b).
    fn start_rename(app: *App, cx: *Context, panel: u32) void {
        assert(panel < panel_count);
        app.rename.load(app.titles[panel].text());
        app.renaming = panel;
        cx.set_focus(rename_id);
        cx.redraw();
        assert(app.rename.edit.has_selection() or app.rename.edit.len == 0);
    }

    /// Closes the rename field; `commit` writes a non-empty, changed name and reports it
    /// ("osc renamed vco").
    fn finish_rename(app: *App, cx: *Context, commit: bool) void {
        const panel = app.renaming orelse return;
        app.renaming = null;
        cx.redraw();
        if (!commit) return;
        const name = app.rename.bytes();
        if (name.len == 0) return;
        const old = app.titles[panel];
        if (std.mem.eql(u8, old.text(), name)) return;
        app.titles[panel] = Title.of(name);
        app.set_status(&.{ old.text(), " renamed ", name });
        assert(app.renaming == null);
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

    /// One panel: the face, the title band, then the knob row and the meter cell, or for the
    /// envelope panel the display cell (section 3d).
    fn draw_panel(app: *const App, cx: *Context, panel_index: u32) void {
        assert(panel_index < panel_count);
        const face: widgets.Panel = .{ .paint = panel_paint };
        var layout = ui.flow_of(.down);
        layout.padding = panel_padding;
        layout.clip = true;
        _ = face.begin(cx, ui.sized(.fill, .{ .share = panel_count }), layout);
        const room = cx.remaining();
        const band_h = band_height(room.height);
        const metered = panel_index < meter_panel_count;
        const meter_on = metered and room.width >= meter_column_px and room.height - band_h > 0;
        const band = cx.begin(ui.sized(.fill, .{ .fixed = band_h }), ui.flow_of(.overlay));
        if (app.renaming == panel_index) {
            app.draw_rename(cx, band);
        } else {
            draw_title(cx, app.titles[panel_index].text(), panel_index);
        }
        app.draw_title_marks(cx, panel_index, band, meter_on);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .fill), ui.flow_of(.right));
        const body = cx.remaining();
        const row_w = if (metered) knob_row_width(body.width) else env_row_width(body.width);
        _ = cx.begin(ui.sized(.{ .fixed = row_w }, .fill), ui.flow_of(.right));
        var knob_index: u32 = 0;
        while (knob_index < knobs_per_panel) : (knob_index += 1) {
            const knob = &app.knobs[panel_index * knobs_per_panel + knob_index];
            if (cx.fits(knob_cell)) {
                const row = cx.peek(knob_cell);
                knob.draw(cx, knob_cell);
                draw_hub(cx, knob, row);
            } else {
                _ = cx.walk(knob_cell);
            }
        }
        _ = cx.end();
        if (!metered) app.draw_display(cx);
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

    /// The envelope display beside the envelope knobs: a face, the 64-point envelope of the
    /// four knobs, and the area whose hover runs the playhead. Omitted when narrower than
    /// `display_min_px` or empty (section 3d).
    fn draw_display(app: *const App, cx: *Context) void {
        if (cx.remaining().width < display_min_px + knob_gap_px) return;
        var walk = ui.sized(.fill, .fill);
        walk.margin.left = knob_gap_px;
        const cell = cx.walk(walk);
        if (!(cell.height > 2 * display_inset_px)) return;
        const clip = cx.visible(cell) orelse return;
        append_or_skip(cx, quads.Box, null, .{
            .rect = .{ cell.x, cell.y, cell.width, cell.height },
            .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
            .fill = display_fill,
            .border_color = .{ 0, 0, 0, 0 },
            .radius = display_radius,
            .border_width = 0,
            .hover = 0,
            .down = 0,
        });
        cx.area(envelope_id, cell, display_radius, ui.cx.plain);
        var points: [envelope_point_count]quads.Point = undefined;
        envelope_points(&points, stages_of(&app.knobs), plot_of(cell));
        const accent = widgets.accents[3];
        const stroke: quads.path.Stroke = .{
            .color = .{ accent.r, accent.g, accent.b, 1 },
            .width = envelope_width,
            .hover = 0,
        };
        _ = quads.path.polyline(cx.drawing(), &points, stroke, clip);
    }

    /// The playhead dot and every cable on `cable_layer`, then the cable being dragged, which
    /// records no area so the drop target stays hot (section 3c).
    fn draw_patch_layer(app: *const App, cx: *Context) void {
        assert(app.cable_count <= cable_cap);
        const window = cx.clip().?;
        const previous = cx.draw.layer(cable_layer);
        defer _ = cx.draw.layer(previous);
        app.draw_playhead(cx);
        var index: u32 = 0;
        while (index < app.cable_count) : (index += 1) {
            const cable = app.cables[index];
            const from = hub_center(cx, &app.knobs[cable.from]) orelse continue;
            const to = hub_center(cx, &app.knobs[cable.to]) orelse continue;
            const id = cable_id(index);
            const lit = cx.hovered() == id;
            const stroke = cable_stroke(app.knobs[cable.from].accent, lit);
            const control = cable_control(from, to);
            const placed = quads.path.cubic(cx.drawing(), control, stroke, window) orelse continue;
            cx.path_area(id, placed, cable_width, patch_flags);
        }
        const source = app.patching orelse return;
        const from = hub_center(cx, &app.knobs[source]) orelse return;
        const to: quads.Point = .{ app.patch_end.x, app.patch_end.y };
        const stroke = cable_stroke(app.knobs[source].accent, false);
        _ = quads.path.cubic(cx.drawing(), cable_control(from, to), stroke, window);
    }

    /// The playhead dot on the envelope at `envelope_phase`, while the display is hovered.
    fn draw_playhead(app: *const App, cx: *Context) void {
        if (!app.envelope_hovered) return;
        const display = cx.find(envelope_id) orelse return;
        const stages = stages_of(&app.knobs);
        const plot = plot_of(rect_of(display.rect));
        const at = point_at(stages, plot, app.envelope_phase * stages.total());
        const half = playhead_px * 0.5;
        append_or_skip(cx, quads.Box, null, .{
            .rect = .{ at[0] - half, at[1] - half, playhead_px, playhead_px },
            .clip = display.clip,
            .fill = theme.chrome.text,
            .border_color = .{ 0, 0, 0, 0 },
            .radius = half,
            .border_width = 0,
            .hover = 0,
            .down = 0,
        });
    }

    /// Hub presses start a cable, drags move its free end, and the release connects it to
    /// the knob under the pointer, found geometrically because a cable may be hot there.
    fn route_hubs(app: *App, cx: *Context, event_value: input.Event) void {
        if (event_value == .frame) return;
        for (&app.knobs, 0..) |*knob, slot| {
            const index: u32 = @intCast(slot);
            switch (cx.hit(hub_id(knob), event_value)) {
                .down => |press| {
                    app.patching = index;
                    app.patch_end = .{ .x = press.x, .y = press.y };
                    cx.redraw();
                },
                .drag => |press| {
                    assert(app.patching == index);
                    app.patch_end = .{ .x = press.x, .y = press.y };
                    cx.redraw();
                },
                .up => |up| {
                    assert(app.patching == index);
                    app.patching = null;
                    cx.redraw();
                    const target = knob_under(app, cx, up.x, up.y) orelse continue;
                    app.connect(index, target);
                },
                .none, .hover_in, .hover_out, .wheel, .secondary => {},
            }
        }
    }

    /// Cable hover lightens it; a right press removes it. Cables are on `cable_layer`, so a
    /// right press on a cable over a knob removes the cable instead of resetting the knob.
    fn route_cables(app: *App, cx: *Context, event_value: input.Event) void {
        if (event_value == .frame) return;
        var index: u32 = 0;
        while (index < app.cable_count) : (index += 1) {
            switch (cx.hit(cable_id(index), event_value)) {
                .hover_in, .hover_out => cx.redraw(),
                .secondary => {
                    app.remove_cable(index);
                    cx.redraw();
                    return;
                },
                .none, .down, .drag, .up, .wheel => {},
            }
        }
    }

    /// Hovering the display starts the playhead; each frame while hovered advances it, keeps
    /// the frames coming, and owes a draw. Leaving stops it, so an unhovered rack asks for no
    /// frames (section 3d).
    fn route_envelope(app: *App, cx: *Context, event_value: input.Event) void {
        if (event_value == .frame) {
            if (!app.envelope_hovered) return;
            const step = event_value.frame / playhead_loop_ms;
            app.envelope_phase = @mod(app.envelope_phase + step, 1);
            cx.keep_animating();
            cx.redraw();
            assert(app.envelope_phase < 1);
            return;
        }
        switch (cx.hit(envelope_id, event_value)) {
            .hover_in => {
                app.envelope_hovered = true;
                cx.redraw();
            },
            .hover_out => {
                app.envelope_hovered = false;
                cx.redraw();
            },
            .none, .down, .drag, .up, .wheel, .secondary => {},
        }
    }

    /// Adds the cable `from` to `to` and reports it ("osc.mix -> filter.res"). A self link or
    /// a pair already patched (either way) is ignored; a full table is refused and reported.
    fn connect(app: *App, from: u32, to: u32) void {
        assert(from < knob_count);
        assert(to < knob_count);
        if (from == to) return;
        for (app.cables[0..app.cable_count]) |cable| {
            if (cable.from == from and cable.to == to) return;
            if (cable.from == to and cable.to == from) return;
        }
        if (app.cable_count == cable_cap) {
            app.set_status(&.{"cables full"});
            return;
        }
        app.cables[app.cable_count] = .{ .from = @intCast(from), .to = @intCast(to) };
        app.cable_count += 1;
        const source = &app.knobs[from];
        const target = &app.knobs[to];
        app.set_status(&.{
            app.titles[from / knobs_per_panel].text(), ".", source.name, " -> ",
            app.titles[to / knobs_per_panel].text(),   ".", target.name,
        });
        assert(app.cable_count <= cable_cap);
    }

    /// Removes cable `index`, keeping the others in order, and reports it.
    fn remove_cable(app: *App, index: u32) void {
        assert(index < app.cable_count);
        const count = app.cable_count;
        std.mem.copyForwards(Cable, app.cables[index .. count - 1], app.cables[index + 1 .. count]);
        app.cable_count = count - 1;
        app.set_status(&.{"cable removed"});
        assert(app.cable_count + 1 == count);
    }

    /// The rename field centered in the title band, as wide as `rename_width_px` allows
    /// between the badges' room at both ends.
    fn draw_rename(app: *const App, cx: *Context, band: Rect) void {
        assert(app.renaming != null);
        const room = band.width - 2 * (badge_inset_px + badge_px + 8);
        const width = std.math.clamp(room, 0, rename_width_px);
        var walk = ui.sized(.{ .fixed = width }, .fill);
        walk.margin.left = @max(0, (band.width - width) * 0.5);
        app.rename.draw(cx, walk);
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

/// A panel title centered in the band, with its area over the text (section 2b).
fn draw_title(cx: *Context, title: []const u8, panel_index: u32) void {
    assert(title.len <= title_cap);
    assert(panel_index < panel_count);
    const label: widgets.Label = .{ .text = title, .style = title_style };
    const rect = cx.peek(ui.sized(.fill, .fill));
    label.draw(cx, ui.sized(.fill, .fill));
    _ = cx.visible(rect) orelse return;
    const width = @min(rect.width, text.measure(title_style, title) + 8);
    if (!(width > 0)) return;
    const area: Rect = .{
        .x = rect.x + (rect.width - width) * 0.5,
        .y = rect.y,
        .width = width,
        .height = rect.height,
    };
    cx.area(ui.id("title", panel_index), area, 0, ui.cx.plain);
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

/// The id of `knob`'s jack hub.
fn hub_id(knob: *const widgets.Knob) ui.Id {
    return knob.id.derive(jack_salt);
}

/// The id of cable `index`.
fn cable_id(index: u32) ui.Id {
    assert(index < cable_cap);
    return ui.id("cable", index);
}

/// The jack hub at the center of the knob's ring in `row` (the cell the knob drew in): a
/// disc with the knob's accent as its border and an area recorded after the ring's, so it
/// wins the press inside its radius. A row the knob did not draw in gets no hub.
fn draw_hub(cx: *Context, knob: *const widgets.Knob, row: Rect) void {
    if (row.height < widgets.ring_size) return;
    const clip = cx.visible(row) orelse return;
    const ring = widgets.ring_of(row);
    const hub: Rect = .{
        .x = ring.x + ring.width * 0.5 - hub_radius,
        .y = ring.y + ring.height * 0.5 - hub_radius,
        .width = 2 * hub_radius,
        .height = 2 * hub_radius,
    };
    append_or_skip(cx, quads.Box, null, .{
        .rect = .{ hub.x, hub.y, hub.width, hub.height },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .fill = theme.chrome.panel,
        .border_color = .{ knob.accent.r, knob.accent.g, knob.accent.b, knob.accent.a },
        .radius = hub_radius,
        .border_width = hub_border_px,
        .hover = 0,
        .down = 0,
    });
    cx.area(hub_id(knob), hub, hub_radius, patch_flags);
}

/// The center of `knob`'s hub at this frame's draw, or null when it was not drawn.
fn hub_center(cx: *const Context, knob: *const widgets.Knob) ?quads.Point {
    const hub = cx.find(hub_id(knob)) orelse return null;
    return .{ hub.rect[0] + hub.rect[2] * 0.5, hub.rect[1] + hub.rect[3] * 0.5 };
}

/// The knob whose ring (hub included) contains `(x, y)` at the last draw, or null.
fn knob_under(app: *const App, cx: *const Context, x: f32, y: f32) ?u32 {
    for (&app.knobs, 0..) |*knob, index| {
        const ring = cx.find(knob.id) orelse continue;
        if (ui.areas.contains(&ring, &.{}, x, y)) return @intCast(index);
    }
    return null;
}

/// How far a cable of `length` sags: `min(24 + 0.2 * length, 160)` logical pixels.
pub fn cable_sag(length: f32) f32 {
    assert(length >= 0);
    const sag = @min(24 + 0.2 * length, 160);
    assert(sag >= 24);
    return sag;
}

/// The cubic of a cable from `from` to `to`: the inner control points sit a third and two
/// thirds along the chord, both lowered by `cable_sag` (Y down).
pub fn cable_control(from: quads.Point, to: quads.Point) [4]quads.Point {
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const sag = cable_sag(@sqrt(dx * dx + dy * dy));
    return .{
        from,
        .{ from[0] + dx / 3, from[1] + dy / 3 + sag },
        .{ from[0] + 2 * dx / 3, from[1] + 2 * dy / 3 + sag },
        to,
    };
}

/// A cable's stroke in its source knob's accent, lightened when hovered.
fn cable_stroke(accent: widgets.Paint, lit: bool) quads.path.Stroke {
    return .{
        .color = .{ accent.r, accent.g, accent.b, cable_alpha },
        .width = cable_width,
        .hover = if (lit) widgets.hover_lighten else 0,
    };
}

/// Envelope stage lengths (attack, decay, a fixed hold, release, in arbitrary time units)
/// and the sustain level, from the envelope panel's knobs (section 3d).
pub const Stages = struct {
    attack: f32,
    decay: f32,
    hold: f32,
    release: f32,
    sustain: f32,

    pub fn total(self: Stages) f32 {
        const sum = self.attack + self.decay + self.hold + self.release;
        assert(sum > 0);
        return sum;
    }
};

/// Shortest stage, so a zero knob still draws a visible slope.
const stage_floor: f32 = 0.05;
/// The sustain hold between decay and release.
const stage_hold: f32 = 0.5;

fn stages_of(knobs: *const [knob_count]widgets.Knob) Stages {
    const first = env_panel * knobs_per_panel;
    const stages: Stages = .{
        .attack = stage_floor + knobs[first].value,
        .decay = stage_floor + knobs[first + 1].value,
        .hold = stage_hold,
        .release = stage_floor + knobs[first + 3].value,
        .sustain = knobs[first + 2].value,
    };
    assert(stages.sustain >= 0);
    assert(stages.sustain <= 1);
    return stages;
}

/// The envelope level at time `t` in `[0, total]`: a cubic ease up to 1 over the attack,
/// down to the sustain over the decay, held, then down to 0 over the release.
pub fn envelope_level(stages: Stages, t: f32) f32 {
    assert(t >= 0);
    var rest = t;
    if (rest < stages.attack) return 1 - cube(1 - rest / stages.attack);
    rest -= stages.attack;
    if (rest < stages.decay) {
        return stages.sustain + (1 - stages.sustain) * cube(1 - rest / stages.decay);
    }
    rest -= stages.decay;
    if (rest < stages.hold) return stages.sustain;
    rest -= stages.hold;
    const along = std.math.clamp(rest / stages.release, 0, 1);
    return stages.sustain * cube(1 - along);
}

fn cube(value: f32) f32 {
    return value * value * value;
}

/// The point of the envelope at time `t` in `plot`: time maps to x, level 1 to the top.
fn point_at(stages: Stages, plot: Rect, t: f32) quads.Point {
    const level = envelope_level(stages, t);
    assert(level >= 0);
    assert(level <= 1.0001);
    return .{
        plot.x + plot.width * std.math.clamp(t / stages.total(), 0, 1),
        plot.y + plot.height * (1 - level),
    };
}

/// The 64-point envelope in `plot`: 21 attack points from 0, 20 decay points, the hold's
/// end, and 22 release points to the total, so every stage corner is a point.
pub fn envelope_points(out: *[envelope_point_count]quads.Point, stages: Stages, plot: Rect) void {
    const held = stages.attack + stages.decay;
    const spans = [_]struct { start: f32, length: f32, steps: u32 }{
        .{ .start = 0, .length = stages.attack, .steps = 20 },
        .{ .start = stages.attack, .length = stages.decay, .steps = 20 },
        .{ .start = held, .length = stages.hold, .steps = 1 },
        .{ .start = held + stages.hold, .length = stages.release, .steps = 22 },
    };
    out[0] = point_at(stages, plot, 0);
    var count: u32 = 1;
    for (spans) |span| {
        var step: u32 = 1;
        while (step <= span.steps) : (step += 1) {
            const along = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(span.steps));
            out[count] = point_at(stages, plot, span.start + span.length * along);
            count += 1;
        }
    }
    assert(count == envelope_point_count);
    assert(out[count - 1][1] == plot.y + plot.height);
}

/// The envelope plot inside a display cell.
fn plot_of(cell: Rect) Rect {
    const plot = ui.cx.inset(cell, .{
        .left = display_inset_px,
        .top = display_inset_px,
        .right = display_inset_px,
        .bottom = display_inset_px,
    });
    assert(plot.width > 0);
    return plot;
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

/// The envelope panel's knob row: four knob cells, or the whole body when narrower, so the
/// display takes the rest.
fn env_row_width(body_w: f32) f32 {
    const cells = @as(f32, @floatFromInt(knobs_per_panel)) * (knob_cell_px + knob_gap_px);
    return std.math.clamp(body_w, 0, cells);
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
    assert(panel_count == 4);
    assert(meter_panel_count == 3);
    assert(env_panel == meter_panel_count);
    assert(knobs_per_panel == 4);
    assert(knob_count == 16);
    assert(levels.meter_count == meter_panel_count);
    // Worst-case boxes: one face per panel, two per meter, the tooltip, the header bar, the
    // preset panel, the selected and the hovered row, the thumb, the rename field's face,
    // selection, and caret, one hub per knob, the display face, and the playhead.
    assert(panel_count + meter_panel_count * 2 + 1 + 1 + 1 + 2 + 1 + 3 + knob_count + 1 + 1 ==
        box_cap);
    // Worst-case arcs: two per knob (track and value arc).
    assert(knob_count * 2 == arc_cap);
    // Worst-case glyphs: a title of up to `title_cap` per panel (the rename field replaces
    // its panel's title and holds as many), up to 8 for each knob name and 4 for each value
    // text, the tooltip text, the header, the visible preset rows, and the status line.
    assert(panel_count * title_cap + knob_count * (8 + 4) + tooltip_text_cap +
        header_glyph_cap + preset_rows_max * preset_glyphs + status_cap == glyph_cap);
    for (knob_table) |spec| assert(spec.name.len <= 8);
    // Worst-case paths: the envelope and every cable plus the one being dragged, each a
    // polyline of at most 65 points cut into at most `chunks_max` chunks.
    const cable_paths = cable_cap + 1;
    const cable_points = quads.path.cubic_points_max;
    assert(quads.path.chunks_max(envelope_point_count) +
        cable_paths * quads.path.chunks_max(cable_points) == path_cap);
    assert(envelope_point_count + cable_paths * cable_points <= point_cap);
    assert(default_cables.len <= cable_cap);
    for (default_cables) |cable| {
        assert(cable.from < knob_count);
        assert(cable.to < knob_count);
        assert(cable.from != cable.to);
    }
    // The largest row index fits the name buffer, and the longest status messages fit theirs.
    assert(preset_count <= 1000);
    assert("preset ".len + 3 == preset_name_cap);
    var longest_knob: usize = 0;
    for (knob_table) |spec| longest_knob = @max(longest_knob, spec.name.len);
    assert(title_cap + 1 + longest_knob + " changed ".len + 4 <= status_cap);
    assert(title_cap + " renamed ".len + title_cap <= status_cap);
    assert(2 * (title_cap + 1 + longest_knob) + " -> ".len == status_cap);
    for (panel_names) |name| assert(name.len <= title_cap);
    assert(preset_name_cap + " selected".len <= status_cap);
    // Every codepoint of the header draws at most one glyph.
    const author_codepoints = std.unicode.utf8CountCodepoints(patch_author) catch unreachable;
    assert(tempo_value.len + tempo_unit.len + author_codepoints <= header_glyph_cap);
    // One badge per panel and one LED per meter.
    assert(panel_count == image_cap);
    assert(meter_panel_count == led_cap);
    // Base: box, glyph, image, LED, arc, path; cable layer: box and path; overlay: box and
    // glyph.
    assert(6 + 2 + 2 <= batch_cap);
    assert(@backingInt(cable_layer) > @backingInt(quads.Layer.base));
    assert(@backingInt(cable_layer) < @backingInt(quads.Layer.overlay));
    // Areas: a ring and a hub per knob, the preset view and its thumb, the visible rows, one
    // title per panel, the rename field, one per cable, and the envelope display.
    assert(2 * knob_count + 2 + preset_rows_max + panel_count + 1 + cable_cap + 1 == area_cap);
    // At most `preset_rows_max` rows overlap the tallest viewport, partial rows included.
    assert(preset_view_max_px / preset_row_px + 2 <= preset_rows_max);
    // The box covers the neighbouring cell's whole name column.
    assert(tooltip_offset_x + tooltip_width >= knob_cell_px + knob_gap_px + 72 + 72);
    assert(knob_table.len == knob_count);
    assert(panel_names.len == panel_count);
    // The hub sits inside the ring's hole, so the ring band stays grabbable around it.
    assert(hub_radius < widgets.ring_size * 0.5 - widgets.ring_thickness);
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

/// The areas a 1280 by 720 frame records with the presets at the top: a ring and a hub per
/// knob, the view, 25 rows, the thumb, a title per panel, the default cables, and the
/// envelope display.
const areas_at_rest: usize = 2 * knob_count + 1 + 25 + 1 + panel_count + default_cables.len + 1;

/// The ring area knob `index` recorded at the last draw, or null when it was not drawn.
fn ring_at(cx: *const Context, app: *const App, index: u32) ?Rect {
    const area = cx.find(app.knobs[index].id) orelse return null;
    return rect_of(area.rect);
}

/// The center of knob `index`'s ring, where its jack hub sits.
fn hub_point(cx: *const Context, app: *const App, index: u32) input.Point {
    const ring = ring_at(cx, app, index).?;
    return .{ .x = ring.x + ring.width * 0.5, .y = ring.y + ring.height * 0.5 };
}

/// A point on knob `index`'s ring above its hub, where a press turns the knob. Cables leave
/// a hub downward, so this point stays clear of the knob's own cables.
fn ring_grip(cx: *const Context, app: *const App, index: u32) input.Point {
    const center = hub_point(cx, app, index);
    return .{ .x = center.x, .y = center.y - 18 };
}

/// The face of panel `panel_index`: the boxes of panel radius after the header bar's.
fn panel_face(cx: *const Context, panel_index: u32) Rect {
    var seen: u32 = 0;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.radius != panel_radius) continue;
        // Hubs share the radius; they are the only boxes as wide as two radii.
        if (box.rect[2] == 2 * hub_radius) continue;
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
    // Step 16 added the envelope panel, so the panel height is now (720 - 32 - 52 - 8 - 3 * 8
    // spacing) / 4 = 151 (`share(4)`; it was 204 with three panels). The preset column takes
    // 240 + 8 of the 1248, leaving 1000.
    try expect_rect(rect_of(cx.draw.items(quads.Box)[0].rect), 16, 16, 1248, 52);
    try expect_rect(panel_face(cx, 0), 16, 76, 1000, 151);
    try expect_rect(panel_face(cx, 1), 16, 235, 1000, 151);
    try expect_rect(panel_face(cx, 2), 16, 394, 1000, 151);
    try expect_rect(panel_face(cx, 3), 16, 553, 1000, 151);
    // First ring: cell x = 16 panel + 8 padding + 8 gap, y = 76 + 8 + 24 band; ring + 8.
    try expect_rect(ring_at(cx, app, 0).?, 40, 116, 56, 56);
    // The envelope panel's first ring sits three panel steps (159) lower.
    try expect_rect(ring_at(cx, app, 12).?, 40, 116 + 3 * 159, 56, 56);
    // Meter: right edge of the inner rect (16 + 1000 - 8), 80 wide, body height 151 - 16 - 24
    // (164 with three panels).
    try expect_rect(meter_cell(cx, 0).?, 928, 108, 80, 111);
    // The display: after the 608 px row of four 152 px cells (from the inner left edge 24)
    // and an 8 px gap, to the inner right edge 1008, as tall as the body.
    try expect_rect(rect_of(cx.find(envelope_id).?.rect), 24 + 608 + 8, 585, 1008 - 640, 111);
    // Presets: x = 16 + 1000 + 8, list 628 - 24 status - 8 = 596 tall, viewport 580 tall.
    try expect_rect(app.presets.viewport, 1032, 84, 224, 580);
    try std.testing.expectEqual(@as(f32, 24000), app.presets.content_h);
    try std.testing.expectEqual(ui.List.Range{ .first = 0, .end = 25 }, app.preset_range);
    // Boxes: the header, 4 panels, 3 meters * 2 faces, the preset panel, its thumb, 16 hubs,
    // and the display face. Arcs: 16 knobs * 2 minus the zero-valued knob's arc. Glyphs:
    // titles 3 + 6 + 3 + 3, knob names 68, values 16 * 4, the tempo 6 + 3, the author 17
    // (its two spaces have no ink), 25 preset names (10 * 7 + 15 * 8 = 190), and "ready" (5).
    try std.testing.expectEqual(@as(usize, 30), cx.draw.items(quads.Box).len);
    try std.testing.expectEqual(@as(usize, 31), cx.draw.items(quads.Arc).len);
    try std.testing.expectEqual(@as(usize, 368), cx.draw.items(quads.Glyph).len);
    try std.testing.expectEqual(@as(usize, 4), cx.draw.items(quads.Image).len);
    try std.testing.expectEqual(@as(usize, 3), cx.draw.items(led.Led).len);
    try std.testing.expectEqual(areas_at_rest, cx.area_list().len);
    const mix = ring_at(cx, app, 3).?;
    var arcs: u32 = 0;
    for (cx.draw.items(quads.Arc)) |arc| {
        // The first ring clips to its panel rect.
        if (arc.rect[0] == 40 and arc.rect[1] == 116) {
            try std.testing.expectEqualSlices(f32, &.{ 16, 76, 1016, 227 }, &arc.clip);
        }
        if (arc.rect[0] == mix.x and arc.rect[1] == mix.y) arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
    try std.testing.expect(!cx.dirty);
}

// Locks that a smaller window shrinks panel heights and the meter cell, not the knob cells.
// The preset column leaves the panels 520 of the 768, so the 424 px knob row keeps two knobs
// and the meter sits at x = 16 + 520 - 8 - 80. Step 16's fourth panel made every panel
// (600 - 32 - 52 - 8 - 3 * 8) / 4 = 121 tall (was 164). The envelope row has no meter, so
// its 504 px body keeps three knobs and leaves no room for the display.
test "rack layout at 800 by 600" {
    const app = new_app();
    const cx = frame_at(app, 800, 600);
    try expect_rect(panel_face(cx, 0), 16, 76, 520, 121);
    try expect_rect(panel_face(cx, 1), 16, 205, 520, 121);
    try expect_rect(panel_face(cx, 2), 16, 334, 520, 121);
    try expect_rect(panel_face(cx, 3), 16, 463, 520, 121);
    try expect_rect(ring_at(cx, app, 0).?, 40, 116, 56, 56);
    try expect_rect(ring_at(cx, app, 1).?, 192, 116, 56, 56);
    try std.testing.expect(ring_at(cx, app, 2) == null);
    try expect_rect(ring_at(cx, app, 14).?, 344, 503, 56, 56);
    try std.testing.expect(ring_at(cx, app, 15) == null);
    try std.testing.expect(cx.find(envelope_id) == null);
    try expect_rect(meter_cell(cx, 0).?, 448, 108, 80, 81);
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
    const center = ring_grip(cx, app, 8);
    try std.testing.expect(send(app, .{ .pointer_down = input.left_at(center) }));
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
    const center = ring_grip(cx, app, 0);
    try std.testing.expect(send(app, .{ .pointer_down = input.left_at(center) }));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = center.x, .y = center.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[0].value);
    try std.testing.expect(send(
        app,
        .{ .pointer_up = input.left_at(.{ .x = center.x, .y = center.y - 60 }) },
    ));
    const wheel: input.Wheel = .{ .x = center.x, .y = center.y, .dx = 0, .dy = -60 };
    try std.testing.expect(send(app, .{ .wheel = wheel }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = 40, .y = 30 } }));
    try std.testing.expect(!send(app, .{ .wheel = .{ .x = 40, .y = 30, .dx = 0, .dy = 40 } }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
}

// Locks that raising a zero-valued knob adds exactly one face.
test "dragging mix off zero adds the value arc" {
    const app = new_app();
    const center = ring_grip(frame_at(app, 1280, 720), app, 3);
    try std.testing.expect(send(app, .{ .pointer_down = input.left_at(center) }));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = center.x, .y = center.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.5), app.knobs[3].value);
    const drawn = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(usize, 32), drawn.draw.items(quads.Arc).len);
    // The knob's glyphs are unchanged; the status line grew from "ready" (5) to
    // "osc.mix changed 0.50" (18).
    try std.testing.expectEqual(@as(usize, 368 - 5 + 18), drawn.draw.items(quads.Glyph).len);
    try std.testing.expectEqualStrings("osc.mix changed 0.50", app.status_text());
}

// Locks hover easing and that a settled rack stops animating and stays clean.
test "hover on rate eases and a later frame stays clean" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(send(app, .{ .pointer_move = ring_grip(cx, app, 0) }));
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
    // 360 leaves each of the four panels (360 - 32 - 52 - 8 - 24) / 4 = 61 px: a 21 px body
    // under the title band, shorter than a knob row (the window was 260 with three panels).
    const cx = frame_at(app, 1280, 360);
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

// Locks the rack's command streams. Setup creates six pipelines, both textures (the atlas and
// the badge), and the point buffer. The first frame writes the uniform, the atlas rectangle
// the glyph cache rasterized, the six pools, and the points, binds the frame group (uniform
// and points) and unit quad once, and draws one call per batch in first-appearance order:
// boxes, glyphs (atlas), the badge, LEDs, arcs, and the envelope path on the base layer, then
// the cables on the cable layer with no pipeline change. A scale change redraws: it writes the
// uniform, a new atlas rectangle, and the glyph pool, and no box, arc, path record, or point.
// A present with nothing owed writes nothing.
test "rack frames record the step 16 op sequences" {
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
    try std.testing.expectEqual(@as(u32, 6), pipelines);
    var writes: [16]patchwork.commands.BufferWrite = undefined;

    record(app, 120);
    const first = [_]Code{
        .buffer_write,      .texture_write,     .buffer_write,
        .buffer_write,      .buffer_write,      .buffer_write,
        .buffer_write,      .buffer_write,      .buffer_write,
        .pass_begin,        .bind_group_set,    .vertex_buffer_set,
        .pipeline_set,      .vertex_buffer_set, .draw,
        .pipeline_set,      .vertex_buffer_set, .bind_group_set,
        .draw,              .pipeline_set,      .vertex_buffer_set,
        .bind_group_set,    .draw,              .pipeline_set,
        .vertex_buffer_set, .draw,              .pipeline_set,
        .vertex_buffer_set, .draw,              .pipeline_set,
        .vertex_buffer_set, .draw,              .draw,
        .pass_end_present,
    };
    const resources = &fixture_gpu.renderer.resources;
    const first_writes = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(resources.points_buffer, first_writes[7].id);
    var atlas: [4]patchwork.commands.TextureWrite = undefined;
    try std.testing.expectEqual(@as(usize, 1), texture_writes(&atlas).len);
    try std.testing.expectEqual(@as(u32, 1024), atlas[0].bytes_per_row);
    const first_codes = patchwork.renderer.codes(&fixture_gpu.buffer, &codes);
    try std.testing.expectEqualSlices(Code, &first, first_codes);
    const batches = fixture.context.draw.batch_list();
    try std.testing.expectEqual(@as(usize, 7), batches.len);
    try std.testing.expectEqual(@as(u8, 0), batches[0].type_id);
    try std.testing.expectEqual(@as(u8, 2), batches[1].type_id);
    try std.testing.expectEqual(@as(u8, 3), batches[2].type_id);
    try std.testing.expectEqual(app.badge_texture, batches[2].texture);
    try std.testing.expectEqual(@as(u8, 4), batches[3].type_id);
    try std.testing.expectEqual(@as(u8, 1), batches[4].type_id);
    try std.testing.expectEqual(@as(u8, 5), batches[5].type_id);
    try std.testing.expectEqual(@as(u8, 5), batches[6].type_id);
    try std.testing.expectEqual(@backingInt(cable_layer), batches[6].layer);

    record(app, 240);
    const rescaled = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
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
}

// Locks the hover uploads after the first frame: a cable hover writes only path records (no
// points), moving to a ring writes the darkened cable and the lit arc, and the ring's next
// eased frame writes only arc records, fewer than the whole arc pool.
test "rack hovers write only the records they change" {
    const app = new_app();
    setup_renderer();
    var writes: [16]patchwork.commands.BufferWrite = undefined;
    const resources = &fixture_gpu.renderer.resources;
    record(app, 120);
    record(app, 120);
    try std.testing.expectEqual(@as(usize, 0), patchwork.renderer.writes(
        &fixture_gpu.buffer,
        &writes,
    ).len);
    try std.testing.expect(send(app, .{ .pointer_move = cable_point(&fixture.context, 0) }));
    record(app, 120);
    const lit = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(@as(usize, 1), lit.len);
    try std.testing.expectEqual(resources.instance_buffers[5], lit[0].id);

    try std.testing.expect(send(app, .{ .pointer_move = ring_grip(&fixture.context, app, 0) }));
    _ = ui.animate(App, app, &fixture.context, 50);
    record(app, 120);
    const hover = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    // The cable went dark again (path records) and the ring lit (arc records).
    try std.testing.expectEqual(@as(usize, 2), hover.len);
    try std.testing.expectEqual(resources.instance_buffers[5], hover[1].id);
    _ = ui.animate(App, app, &fixture.context, 50);
    record(app, 120);
    const settled = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(@as(usize, 1), settled.len);
    const arc_buffer = fixture_gpu.renderer.resources.instance_buffers[1];
    try std.testing.expectEqual(arc_buffer, settled[0].id);
    const arcs = fixture.context.draw.items(quads.Arc);
    try std.testing.expect(settled[0].data.len < arcs.len * @sizeOf(quads.Arc));
}

// Locks the layer rule for the tooltip: it appears only after `tooltip_delay_ms` of hover,
// its box overlaps the neighbouring knob's name glyphs, it sits on the overlay layer with no
// area of its own, and both overlay batches (box, then text) are drawn after every base
// batch. A move to the neighbour hides it.
test "the tooltip box covers the neighbour's text on the overlay layer" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(send(app, .{ .pointer_move = ring_grip(cx, app, 0) }));
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
    // The same areas as a frame without the tooltip.
    try std.testing.expectEqual(areas_at_rest, cx.area_list().len);
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
        try std.testing.expect(batch.layer <= @backingInt(cable_layer));
    }
    try std.testing.expect(send(app, .{ .pointer_move = ring_grip(cx, app, 1) }));
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
    try std.testing.expectEqual(@as(usize, meter_panel_count), lights.len);
    for (lights, app.meters) |light, meter| {
        try std.testing.expectEqual(meter.value, light.brightness);
    }
}

/// The middle point of cable `index`'s polyline at the last draw, on its stroke.
fn cable_point(cx: *const Context, index: u32) input.Point {
    const area = cx.find(cable_id(index)).?;
    const point = cx.draw.point_items()[area.first_point + area.point_count / 2];
    const origin_x = area.rect[0] + area.radius;
    const origin_y = area.rect[1] + area.radius;
    return .{ .x = origin_x + point[0], .y = origin_y + point[1] };
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
    try std.testing.expect(!send(app, .{ .pointer_down = input.left_at(point) }));
    try std.testing.expect(send(app, .{ .pointer_up = input.left_at(point) }));
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
    try std.testing.expect(send(
        app,
        .{ .wheel = .{ .x = top.x, .y = top.y, .dx = 0, .dy = 412 * 24 } },
    ));
    try std.testing.expectEqual(@as(f32, 412 * 24), app.presets.scroll_y);
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(ui.List.Range{ .first = 412, .end = 437 }, app.preset_range);
    try std.testing.expect(cx.find(ui.id("preset", 411)) == null);
    try std.testing.expect(cx.find(ui.id("preset", 437)) == null);
    try std.testing.expectEqual(areas_at_rest, cx.area_list().len);
    const first = preset_rect(cx, 412);
    try std.testing.expectEqual(app.presets.viewport.y, first.y);
    const point = center_of(first);
    _ = send(app, .{ .pointer_down = input.left_at(point) });
    _ = send(app, .{ .pointer_up = input.left_at(point) });
    try std.testing.expectEqualStrings("preset 412 selected", app.status_text());
    try std.testing.expectEqual(@as(u32, 0), cx.area_overflow);
}

// Locks the status line for a knob: a wheel that turns filter.cut from 0.50 to 0.42 reports
// "filter.cut changed 0.42".
test "a knob change is reported on the status line" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expectEqualStrings("ready", app.status_text());
    const cut = ring_grip(cx, app, 4);
    try std.testing.expect(send(
        app,
        .{ .wheel = .{ .x = cut.x, .y = cut.y, .dx = 0, .dy = 9.6 } },
    ));
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

fn press_at(point: input.Point, which: input.MouseButton, time_ms: u32) input.Event {
    const sample: input.Button = .{
        .x = point.x,
        .y = point.y,
        .time_ms = time_ms,
        .button = which,
        .mods = .none,
    };
    return .{ .pointer_down = sample };
}

fn release_at(point: input.Point, which: input.MouseButton, time_ms: u32) input.Event {
    const sample = press_at(point, which, time_ms).pointer_down;
    return .{ .pointer_up = sample };
}

fn key(name: input.Key, utf8: []const u8) input.Event {
    return .{ .key_down = input.key_press(name, .none, false, utf8) };
}

/// Double-presses the title of `panel` at `time_ms` and draws the frame that shows the field.
fn double_click_title(app: *App, panel: u32, time_ms: u32) *Context {
    const title = center_of(rect_of(fixture.context.find(ui.id("title", panel)).?.rect));
    _ = send(app, press_at(title, .left, time_ms));
    _ = send(app, release_at(title, .left, time_ms + 50));
    _ = send(app, press_at(title, .left, time_ms + 150));
    _ = send(app, release_at(title, .left, time_ms + 200));
    return frame_at(app, 1280, 720);
}

// Locks renaming: a double press on the "osc" title opens the focused field with all of it
// selected in place of the title (the I-beam over it), typing replaces it, Enter commits
// "osc renamed vco" and the status line names knobs by the new title, and a second rename
// cancelled with Escape keeps "vco".
test "a double click renames a panel and Escape cancels" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const cx = double_click_title(app, 0, 1000);
    try std.testing.expectEqual(@as(?u32, 0), app.renaming);
    try std.testing.expect(cx.focused(rename_id));
    try std.testing.expectEqualStrings("osc", app.rename.edit.selected());
    try std.testing.expect(cx.find(ui.id("title", 0)) == null);
    const field = center_of(rect_of(cx.find(rename_id).?.rect));
    _ = send(app, .{ .pointer_move = field });
    try std.testing.expectEqual(ui.Cursor.text, cx.cursor());
    for ("vco") |byte| _ = send(app, key(input.key_of_dom(&.{byte}), &.{byte}));
    try std.testing.expect(send(app, key(.enter, "")));
    try std.testing.expectEqualStrings("osc renamed vco", app.status_text());
    try std.testing.expectEqualStrings("vco", app.titles[0].text());
    try std.testing.expectEqual(@as(?u32, null), app.renaming);
    try std.testing.expectEqual(ui.Id.none, cx.focus);
    _ = frame_at(app, 1280, 720);
    const rate = ring_grip(cx, app, 0);
    _ = send(app, .{ .wheel = .{ .x = rate.x, .y = rate.y, .dx = 0, .dy = -12 } });
    try std.testing.expectEqualStrings("vco.rate changed 0.35", app.status_text());
    _ = double_click_title(app, 0, 5000);
    _ = send(app, key(.x, "x"));
    try std.testing.expect(send(app, key(.escape, "")));
    try std.testing.expectEqualStrings("vco", app.titles[0].text());
    try std.testing.expectEqual(ui.Id.none, cx.focus);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks blur commits and the knob reset: End then "!" extends the selected title, a press on
// a knob while renaming commits it ("filter renamed filter!"), and a right press on
// filter.cut after a wheel resets it to 0.50 ("filter!.cut reset 0.50") without capturing,
// while the ring shows the grab cursor.
test "a press elsewhere commits a rename and a right click resets a knob" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const cx = double_click_title(app, 1, 1000);
    _ = send(app, key(.end, ""));
    _ = send(app, key(.other, "!"));
    const cut = ring_grip(cx, app, 4);
    _ = send(app, press_at(cut, .left, 3000));
    try std.testing.expectEqualStrings("filter!", app.titles[1].text());
    try std.testing.expectEqualStrings("filter renamed filter!", app.status_text());
    _ = send(app, release_at(cut, .left, 3050));
    _ = frame_at(app, 1280, 720);
    _ = send(app, .{ .pointer_move = cut });
    try std.testing.expectEqual(ui.Cursor.grab, cx.cursor());
    _ = send(app, .{ .wheel = .{ .x = cut.x, .y = cut.y, .dx = 0, .dy = 9.6 } });
    try std.testing.expectEqual(@as(f32, 0.42), app.knobs[4].value);
    try std.testing.expect(send(app, press_at(cut, .right, 4000)));
    try std.testing.expectEqual(@as(f32, 0.5), app.knobs[4].value);
    try std.testing.expectEqual(ui.Id.none, cx.capture);
    try std.testing.expectEqualStrings("filter!.cut reset 0.50", app.status_text());
}

// Locks patching: a press on osc.rate's hub captures it without turning the knob, the drag
// draws a preview cable with no area, and the release on filter.cut's ring adds the cable and
// reports "osc.rate -> filter.cut". A drop on the source itself or on a pair already patched
// adds nothing. A right press on the new cable removes it ("cable removed") and resets no
// knob, and the hub shows the pointer cursor.
test "a hub drag patches a cable and a right press removes it" {
    const app = new_app();
    var cx = frame_at(app, 1280, 720);
    const hub = hub_point(cx, app, 0);
    _ = send(app, .{ .pointer_move = hub });
    try std.testing.expectEqual(ui.Cursor.pointer, cx.cursor());
    try std.testing.expect(send(app, press_at(hub, .left, 1000)));
    const target = ring_grip(cx, app, 4);
    try std.testing.expect(send(app, .{ .pointer_move = target }));
    try std.testing.expectEqual(@as(?u32, 0), app.patching);
    try std.testing.expectEqual(@as(f32, 0.25), app.knobs[0].value);
    const resting_paths = cx.draw.items(quads.Path).len;
    cx = frame_at(app, 1280, 720);
    try std.testing.expect(cx.draw.items(quads.Path).len > resting_paths);
    try std.testing.expectEqual(areas_at_rest, cx.area_list().len);
    try std.testing.expect(send(app, release_at(target, .left, 1100)));
    try std.testing.expectEqual(@as(?u32, null), app.patching);
    try std.testing.expectEqual(@as(u32, 3), app.cable_count);
    try std.testing.expectEqual(Cable{ .from = 0, .to = 4 }, app.cables[2]);
    try std.testing.expectEqualStrings("osc.rate -> filter.cut", app.status_text());
    cx = frame_at(app, 1280, 720);
    // Dropping on the source, or patching filter.cut back to osc.rate, adds nothing.
    for ([_][2]u32{ .{ 0, 0 }, .{ 4, 0 } }) |pair| {
        const from = hub_point(cx, app, pair[0]);
        _ = send(app, press_at(from, .left, 2000));
        _ = send(app, release_at(ring_grip(cx, app, pair[1]), .left, 2100));
        try std.testing.expectEqual(@as(u32, 3), app.cable_count);
    }
    cx = frame_at(app, 1280, 720);
    try std.testing.expectEqual(areas_at_rest + 1, cx.area_list().len);
    const on_cable = cable_point(cx, 2);
    try std.testing.expect(send(app, .{ .pointer_move = on_cable }));
    try std.testing.expect(send(app, press_at(on_cable, .right, 3000)));
    try std.testing.expectEqual(@as(u32, 2), app.cable_count);
    try std.testing.expectEqualStrings("cable removed", app.status_text());
    try std.testing.expectEqual(ui.Id.none, cx.capture);
    for (app.knobs, knob_table) |knob, spec| try std.testing.expectEqual(spec.value, knob.value);
}

// Locks the table bound: with `cable_cap` cables a new drop is refused and reported, and the
// worst frame (every cable, the drag preview, the playhead, a hovered and a selected row, and
// the tooltip) overflows no pool, batch list, or area list.
test "the worst patch frame fits every pool and a full table refuses" {
    const app = new_app();
    var cx = frame_at(app, 1280, 720);
    app.cable_count = 0;
    var from: u8 = 0;
    while (app.cable_count < cable_cap) : (from += 1) {
        app.connect(from, (from + 5) % knob_count);
    }
    try std.testing.expectEqual(cable_cap, app.cable_count);
    cx = frame_at(app, 1280, 720);
    _ = send(app, press_at(center_of(preset_rect(cx, 2)), .left, 500));
    _ = send(app, release_at(center_of(preset_rect(cx, 2)), .left, 550));
    _ = send(app, .{ .pointer_move = center_of(preset_rect(cx, 4)) });
    _ = send(app, .{ .pointer_move = center_of(rect_of(cx.find(envelope_id).?.rect)) });
    try std.testing.expect(app.envelope_hovered);
    _ = send(app, .{ .pointer_move = ring_grip(cx, app, 1) });
    _ = ui.animate(App, app, cx, 0);
    _ = ui.animate(App, app, cx, 600);
    try std.testing.expect(app.tooltip_visible());
    app.envelope_hovered = true;
    // Cables leave a hub downward and cover its center, so the press takes the hub's top.
    const top = hub_point(cx, app, 15);
    _ = send(app, press_at(.{ .x = top.x, .y = top.y - 6 }, .left, 1000));
    _ = send(app, .{ .pointer_move = .{ .x = 900, .y = 120 } });
    try std.testing.expectEqual(@as(?u32, 15), app.patching);
    cx = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), cx.area_overflow);
    try std.testing.expectEqual(@as(usize, cable_cap), count_cable_areas(cx));
    _ = send(app, release_at(ring_grip(cx, app, 2), .left, 1100));
    try std.testing.expectEqual(cable_cap, app.cable_count);
    try std.testing.expectEqualStrings("cables full", app.status_text());
}

/// The path areas of the last draw: one per drawn cable.
fn count_cable_areas(cx: *const Context) usize {
    var count: usize = 0;
    for (cx.area_list()) |area| {
        if (area.point_count != 0) count += 1;
    }
    return count;
}

// Locks the playhead's idle rule: hovering the display owes a draw, each frame while it is
// hovered advances the phase by `dt / playhead_loop_ms`, keeps the frames coming, and draws
// the dot on the cable layer; leaving the display stops the frames, so an unhovered rack is
// not animating.
test "the playhead runs only while the display is hovered" {
    const app = new_app();
    var cx = frame_at(app, 1280, 720);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    const display = center_of(rect_of(cx.find(envelope_id).?.rect));
    try std.testing.expect(send(app, .{ .pointer_move = display }));
    try std.testing.expect(app.envelope_hovered);
    try std.testing.expect(ui.animate(App, app, cx, 0));
    try std.testing.expect(ui.animate(App, app, cx, 500));
    try std.testing.expectEqual(@as(f32, 0.25), app.envelope_phase);
    try std.testing.expect(cx.dirty);
    const boxes = cx.draw.items(quads.Box).len;
    cx = frame_at(app, 1280, 720);
    const drawn = cx.draw.items(quads.Box);
    try std.testing.expectEqual(boxes + 1, drawn.len);
    try std.testing.expectEqual(cable_layer, cx.draw.layer_at(quads.Box, @intCast(drawn.len - 1)));
    try std.testing.expect(send(app, .{ .pointer_move = .{ .x = 1100, .y = 30 } }));
    try std.testing.expect(!app.envelope_hovered);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    try std.testing.expectEqual(@as(f32, 0.25), app.envelope_phase);
}

// Locks the envelope polyline for the initial knobs (attack 0.20, decay 0.30, sustain 0.60,
// release 0.40): stages 0.25, 0.35, 0.5, and 0.45 long (total 1.55), so the peak (point 20)
// is 0.25 / 1.55 across at the top, the decay ends at point 40 on the sustain level, the hold
// ends at point 41, and the release ends at the bottom right; x never decreases.
test "the envelope polyline follows the four knobs" {
    const app = new_app();
    const plot: Rect = .{ .x = 100, .y = 50, .width = 310, .height = 100 };
    const stages = stages_of(&app.knobs);
    try std.testing.expectApproxEqAbs(@as(f32, 1.55), stages.total(), 1.0e-5);
    var points: [envelope_point_count]quads.Point = undefined;
    envelope_points(&points, stages, plot);
    try std.testing.expectEqual(quads.Point{ 100, 150 }, points[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 150), points[20][0], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 50), points[20][1], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 220), points[40][0], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 90), points[40][1], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 320), points[41][0], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 90), points[41][1], 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 410), points[63][0], 1.0e-3);
    try std.testing.expectEqual(@as(f32, 150), points[63][1]);
    for (points[1..], points[0 .. points.len - 1]) |point, before| {
        try std.testing.expect(point[0] >= before[0]);
    }
}

// Locks the cable shape: the sag is `min(24 + 0.2 * length, 160)`, and the inner control
// points sit a third and two thirds along the chord, lowered by it.
test "cables sag by their length" {
    try std.testing.expectEqual(@as(f32, 24), cable_sag(0));
    try std.testing.expectEqual(@as(f32, 84), cable_sag(300));
    try std.testing.expectEqual(@as(f32, 160), cable_sag(1000));
    const control = cable_control(.{ 0, 0 }, .{ 300, 0 });
    try std.testing.expectEqual(quads.Point{ 100, 84 }, control[1]);
    try std.testing.expectEqual(quads.Point{ 200, 84 }, control[2]);
}

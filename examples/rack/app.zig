//! Retained demo: a synthesizer rack of panels, each holding a row of knobs and a level meter.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Flat Widget List
//! The rack is one flat array of sibling widgets in `ui.Scene(Widget, widget_cap)` rather than
//! a tree of container widgets. A tree would duplicate the pointer and gesture arbitration
//! that `Scene` and `Scroll` already own. `Scene` hit-tests from the last slot to the first,
//! so a knob or meter, stored after its panel, wins over the panel behind it. Only layout
//! knows which widgets belong to which panel.
//!
//! ### Scissor-Free Clipping
//! Panel faces use the window clip, knob faces clip to their parent panel, and meter faces
//! clip to the meter cell. The meter needs its own clip because its track has a fixed height
//! (`widgets.meter_track_h`) and would otherwise cover the panel title on a short panel.
//! `clip_for` writes the clip rectangle into each instance and the shader masks fragments
//! outside it, so no GPU scissor state is involved.
//!
//! ## 2. Coordinate Spaces and Layout
//! All measurements are UI logical pixels, top-left origin, `+Y` down. The header bar is
//! `header_px` tall at the top of the window, inset by `column_padding`, and omitted when the
//! window cannot hold it. `turtle.place_column` stacks the panels below it, in a column that
//! starts `header_px + header_gap_px` from the top, each with `width = fill`,
//! `height = fill`, and a top margin of `panel_gap_px` except the first, inside a column inset
//! by `column_padding`.
//!
//! Per panel, with `inner = panel.rect inset by panel.padding`:
//! ```text
//! band   = clamp(inner.height, 0, title_band_px)       title label height
//! body   = inner below the band
//! row    = body.x, body.y, knob_row_width(inner.width) knob cells via turtle.place_row
//! meter  = (body.x + body.width - meter_column_px, body.y, meter_column_px, body.height)
//! ```
//! Space that cannot hold a control omits it instead of overlapping: a knob cell survives only
//! if its whole fixed box lies inside the row beside the meter and the body height, and the
//! meter survives only if the body is at least `meter_column_px` wide and has positive height.
//! An omitted widget gets an empty rect, and `draw` skips any rect with a non-positive size.
//! Worked layouts: tests "rack layout at 1280 by 720", "rack layout at 800 by 600",
//! "a narrow window keeps only knobs that clear the meter", and "a short window hides knobs
//! that would leave the panel".
//!
//! ## 3. Slot Layout and Capacity
//! Slots are grouped per panel: the panel, then `knobs_per_panel` knobs, then the meter, so
//! `panel_stride = knobs_per_panel + 2` and `demo_count = panel_count * panel_stride`. The
//! comptime block asserts the stride, the table sizes, and that the worst case fits each
//! draw pool in `config.draw` and `widget_cap`; tests assert `overflow_count == 0`.
//!
//! ## 3a. Draw Types, Layers, and the Title Band
//! `config.draw` registers the library's `Box`, `Arc`, `Glyph`, and `Image` and the rack's
//! own `Led` (`led.zig`). Each panel's title band carries the procedural badge
//! (`badge.zig`, an `Image` of the texture `init` creates) at its left end and an LED centered
//! over the meter track whose brightness is that panel's meter level; the title text is
//! centered between them. Everything is on the base layer except the tooltip.
//!
//! ## 3c. Header and Text Styles
//! `App.draw` draws the header bar directly, not as a scene widget, so the slot math above is
//! unchanged and the bar never hit-tests. It holds the tempo readout (`tempo_runs`: "121.00"
//! in 32 px mono and " BPM" in 14 px bold, one baseline through `text.place_runs`) at its
//! left and `patch_author` (non-ASCII, with composite glyphs) right-aligned in the rest, cut
//! with an ellipsis when it does not fit. Panel titles use `title_style` (bold 14 px); knob
//! names and values use `widgets.name_style` and the monospace `widgets.value_style`.
//!
//! ## 3b. Tooltip
//! Hovering a knob for `tooltip_delay_ms` shows its name and value in a bordered box beside
//! the ring. The box overlaps the neighbouring knob's name, so it goes on the overlay layer,
//! which is drawn after every base batch; on the base layer the sticky glyph batch would draw
//! the neighbour's text over it. The delay is a `dwell` animator local to the rack: hovering a
//! knob aims it at 1 over `tooltip_delay_ms`, and a change of hovered knob restarts it.
//! `event` reports a change only when the tooltip appears or disappears, so the dwell frames
//! between redraw nothing. Test "the tooltip box covers the neighbour's text on the overlay
//! layer" locks the rule.
//!
//! ## 4. Meter Data Flow
//! The host calls `App.timer(now_ms)` every `config.timer_period_ms`:
//! ```text
//! levels.sample(now_ms) -> Meter.set_value per meter -> scene.dirty only if a value changed
//! ```
//! `draw` reads only the stored `meter.value`, and knob gestures never write meter values; test
//! "apply_meters writes the sample and a knob drag does not" locks both. Pointer routing, hover,
//! and capture are owned by `ui.Scene`; see the `ui.zig` guide.
//!
//! ## 5. TigerStyle Invariants
//! - The widget array is fixed at `widget_cap` slots; there is no runtime allocation.
//! - Every loop is bounded by `widget_cap`, `panel_count`, or `knobs_per_panel`.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const animator = patchwork.animator;
const text = patchwork.text;
const quads = patchwork.draw;
const input = patchwork.input;
const theme = patchwork.theme;
const turtle = patchwork.turtle;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const levels = @import("levels.zig");
const led = @import("led.zig");
const badge = @import("badge.zig");

/// Maximum widgets in the rack scene; `demo_count` of them are in use.
pub const widget_cap: u32 = 32;

/// Panels in the rack. Each one is followed by its knobs and one meter.
pub const panel_count: u32 = 3;

/// Knobs in one panel row.
pub const knobs_per_panel: u32 = 4;

/// Slots from one panel to the next: the panel, its knobs, and its meter.
pub const panel_stride: u32 = 6;

/// Widgets in the running rack.
pub const demo_count: u32 = panel_count * panel_stride;

const column_padding: turtle.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
const zero_margin: turtle.Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

const empty_rect: turtle.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

const panel_padding: turtle.Inset = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 };
const panel_gap_px: f32 = 8;
const title_band_px: f32 = 24;
const meter_column_px: f32 = 80;
const knob_cell_px: f32 = 144;
const panel_radius: f32 = 8;

const panel_names = [_][]const u8{ "osc", "filter", "amp" };

/// Header bar above the panels: its height, and the gap between it and the first panel.
const header_px: f32 = 52;
const header_gap_px: f32 = 8;
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

/// Pool capacities. The comptime block checks each against the rack's worst case.
const box_cap: u32 = 16;
const arc_cap: u32 = 32;
const glyph_cap: u32 = 256;
const image_cap: u32 = 4;
const led_cap: u32 = 4;
const batch_cap: u32 = 16;

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

/// The widget kinds the rack uses. The tag selects the behavior; the scene scans the array.
pub const Widget = union(enum) {
    panel: widgets.Panel,
    knob: widgets.Knob,
    meter: widgets.Meter,
};

const Scene = ui.Scene(Widget, widget_cap);

/// The rack app: one flat scene of panels, knobs, and meters. `timer` writes the procedural
/// meter levels at the period in `config`.
pub const App = struct {
    scene: Scene,
    /// Hover time toward the tooltip; see the module guide, section 3b.
    dwell: animator.Animator,
    /// The knob slot `dwell` is timing, or null when no knob is hovered.
    dwell_slot: ?u32,
    /// The badge texture and its pixels, which must outlive the stream that uploads them.
    badge_texture: quads.TextureId,
    badge_pixels: [badge.bytes]u8,

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
    };

    /// Fills every slot and generates the badge texture. Rects are empty until `layout`.
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
        app.dwell_slot = null;
        app.scene = Scene.init(demo_count);
        var panel_index: u32 = 0;
        while (panel_index < panel_count) : (panel_index += 1) {
            fill_panel(&app.scene, panel_index);
        }
        assert(app.scene.count == demo_count);
        assert(!app.scene.pointer.inside);
    }

    /// Places the panels, then each panel's knob row and meter.
    pub fn layout(app: *App, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
        assert(app.scene.count == demo_count);
        place_panels(&app.scene, width_logical, height_logical);
        app.scene.finish_layout(width_logical, height_logical);
        assert(app.scene.dirty);
    }

    /// Routes the event through the scene, then times the tooltip. Dirty when the scene
    /// changed or the tooltip appeared or disappeared.
    pub fn event(app: *App, event_value: input.Event) bool {
        assert(app.scene.count == demo_count);
        var changed = app.scene.handle_event(event_value);
        if (app.retarget_dwell()) {
            changed = true;
        }
        switch (event_value) {
            .frame => |dt_ms| {
                if (app.step_dwell(dt_ms)) {
                    changed = true;
                }
            },
            else => {},
        }
        if (changed) {
            app.scene.dirty = true;
        }
        assert(app.dwell_slot == null or app.dwell.target == 1);
        return changed;
    }

    /// Writes the latest samples onto the meters. Dirty only when one changes.
    pub fn timer(app: *App, now_ms: u64) bool {
        assert(app.scene.count == demo_count);
        const sampled = levels.sample(now_ms);
        var changed = false;
        var index: u32 = 0;
        while (index < panel_count) : (index += 1) {
            const meter = &app.scene.widgets[meter_slot(index)].meter;
            if (meter.set_value(sampled[index])) {
                changed = true;
            }
            assert(meter.value == sampled[index]);
        }
        if (changed) {
            app.scene.dirty = true;
        }
        assert(index == panel_count);
        assert(app.scene.count == demo_count);
        return changed;
    }

    pub fn live(app: *const App) bool {
        assert(app.scene.count == demo_count);
        if (app.dwell.live()) {
            return true;
        }
        return app.scene.live();
    }

    pub fn dirty(app: *const App) bool {
        assert(app.scene.count == demo_count);
        return app.scene.dirty;
    }

    /// Draws the header bar, every widget into the freshly reset context, each panel's
    /// badge and LED after the panel, then the tooltip on the overlay layer. The window clip
    /// is the full frame.
    pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void {
        assert(app.scene.width_logical != 0);
        assert(app.scene.height_logical != 0);
        const clip: quads.Clip = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = @floatFromInt(app.scene.width_logical),
            .y1 = @floatFromInt(app.scene.height_logical),
        };
        draw_header(cx, app.scene.width_logical, app.scene.height_logical, clip);
        var index: u32 = 0;
        while (index < app.scene.count) : (index += 1) {
            const face_clip = clip_for(&app.scene, index, clip);
            widget_draw(&app.scene.widgets[index], cx, face_clip);
            if (index % panel_stride == 0) {
                app.draw_title_marks(cx, index / panel_stride, face_clip);
            }
        }
        app.draw_tooltip(cx, clip);
        app.scene.finish_draw();
        // A window smaller than one panel has no positive face, so that frame is empty.
        assert(cx.overflow_count == 0);
        assert(cx.layer_now == .base);
    }

    /// True while the tooltip of `dwell_slot` is showing.
    pub fn tooltip_visible(app: *const App) bool {
        if (app.dwell_slot == null) {
            return false;
        }
        return app.dwell.value == 1;
    }

    /// Restarts the dwell when the hovered knob changed. True when that hid the tooltip.
    fn retarget_dwell(app: *App) bool {
        const next = hovered_knob(&app.scene);
        if (same_slot(app.dwell_slot, next)) {
            return false;
        }
        const was_visible = app.tooltip_visible();
        app.dwell = animator.Animator.init(1.0 / tooltip_delay_ms);
        app.dwell_slot = next;
        if (next != null) {
            const aimed = app.dwell.set_target(1);
            assert(aimed);
        }
        assert(!app.tooltip_visible());
        return was_visible;
    }

    /// Steps the dwell. True only on the step that shows the tooltip.
    fn step_dwell(app: *App, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        const was_visible = app.tooltip_visible();
        _ = app.dwell.step(dt_ms);
        if (was_visible) {
            assert(app.tooltip_visible());
            return false;
        }
        return app.tooltip_visible();
    }

    /// The badge at the band's left end and the LED over the meter track, both clipped to
    /// the panel. A band too short or too narrow for them omits them.
    fn draw_title_marks(app: *const App, cx: anytype, panel_index: u32, clip: quads.Clip) void {
        assert(panel_index < panel_count);
        const band = app.scene.widgets[panel_slot(panel_index)].panel.label.rect;
        if (band.height < badge_px) {
            return;
        }
        if (band.width < 4 * badge_px) {
            return;
        }
        const clip_rect: [4]f32 = .{ clip.x0, clip.y0, clip.x1, clip.y1 };
        const y = band.y + (band.height - badge_px) * 0.5;
        append_or_skip(cx, quads.Image, app.badge_texture, .{
            .rect = .{ band.x + badge_inset_px, y, badge_px, badge_px },
            .clip = clip_rect,
            .uv = .{ 0, 0, 1, 1 },
            .tint = .{ 1, 1, 1, 1 },
        });
        const meter = app.scene.widgets[meter_slot(panel_index)].meter;
        if (meter.rect.width <= 0) {
            return;
        }
        const center_x = meter.rect.x + widgets.ring_inset + widgets.ring_size * 0.5;
        const center_y = band.y + band.height * 0.5;
        const light = led.at(center_x, center_y, led_color, meter.value, clip_rect);
        append_or_skip(cx, led.Led, null, light);
    }

    /// The hovered knob's name and value in a bordered box on the overlay layer, so it
    /// covers the neighbouring knob's text. See the module guide, section 3b.
    fn draw_tooltip(app: *const App, cx: anytype, window: quads.Clip) void {
        if (!app.tooltip_visible()) {
            return;
        }
        const knob = app.scene.widgets[app.dwell_slot.?].knob;
        assert(knob.rect.width > 0);
        const box = tooltip_rect(knob.rect);
        const previous = cx.layer(.overlay);
        defer _ = cx.layer(previous);
        const text_color = theme.chrome.text;
        append_or_skip(cx, quads.Box, null, .{
            .rect = .{ box.x, box.y, box.width, box.height },
            .clip = .{ window.x0, window.y0, window.x1, window.y1 },
            .fill = tooltip_fill,
            .border_color = text_color,
            .radius = tooltip_radius,
            .border_width = tooltip_border_px,
            .hover = 0,
            .down = 0,
        });
        var bytes: [tooltip_text_cap]u8 = undefined;
        const label = tooltip_text(&bytes, knob);
        text.place(cx, widgets.name_style, label, box, window, widgets.centered);
    }
};

/// The header bar's rect, or null when the window is too small to hold it.
fn header_rect(width_logical: u32, height_logical: u32) ?turtle.Rect {
    const width: f32 = @floatFromInt(width_logical);
    const height: f32 = @floatFromInt(height_logical);
    const rect: turtle.Rect = .{
        .x = column_padding.left,
        .y = column_padding.top,
        .width = width - column_padding.left - column_padding.right,
        .height = header_px,
    };
    if (rect.width <= 2 * header_inset_px) {
        return null;
    }
    if (rect.y + rect.height > height) {
        return null;
    }
    assert(rect.width > 0);
    return rect;
}

/// The header bar: a face, the tempo readout at its left, and the author label at its right.
fn draw_header(cx: anytype, width_logical: u32, height_logical: u32, window: quads.Clip) void {
    const bar = header_rect(width_logical, height_logical) orelse return;
    const color = theme.chrome.panel;
    append_or_skip(cx, quads.Box, null, .{
        .rect = .{ bar.x, bar.y, bar.width, bar.height },
        .clip = .{ window.x0, window.y0, window.x1, window.y1 },
        .fill = color,
        .border_color = .{ 0, 0, 0, 0 },
        .radius = header_radius,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    });
    const inner: turtle.Rect = .{
        .x = bar.x + header_inset_px,
        .y = bar.y,
        .width = bar.width - 2 * header_inset_px,
        .height = bar.height,
    };
    const bar_clip = rect_clip(bar);
    text.place_runs(cx, &tempo_runs, inner, bar_clip, .{
        .align_x = .start,
        .align_y = .center,
        .ellipsis = false,
    });
    // The author takes the space right of the tempo readout and is cut when it does not fit.
    const tempo_width = text.measure(tempo_runs[0].style, tempo_value) +
        text.measure(tempo_runs[1].style, tempo_unit) + header_inset_px;
    if (inner.width <= tempo_width) {
        return;
    }
    const author: turtle.Rect = .{
        .x = inner.x + tempo_width,
        .y = inner.y,
        .width = inner.width - tempo_width,
        .height = inner.height,
    };
    text.place(cx, author_style, patch_author, author, bar_clip, .{
        .align_x = .end,
        .align_y = .center,
        .ellipsis = true,
    });
}

fn widget_draw(widget: *const Widget, cx: anytype, clip: quads.Clip) void {
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    switch (widget.*) {
        inline else => |*payload| payload.draw(cx, clip),
    }
}

/// Appends through `cx`, skipping on a full pool or batch list (the context counts it).
fn append_or_skip(cx: anytype, comptime T: type, texture: ?quads.TextureId, instance: T) void {
    assert(instance.rect[2] > 0);
    assert(instance.rect[3] > 0);
    cx.append(T, texture, instance) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// The knob slot under the pointer, or null when the hovered widget is not a visible knob.
fn hovered_knob(scene: *const Scene) ?u32 {
    const slot = scene.hovered orelse return null;
    assert(slot < scene.count);
    switch (scene.widgets[slot]) {
        .knob => |knob| {
            if (knob.rect.width <= 0) {
                return null;
            }
            return slot;
        },
        else => return null,
    }
}

fn same_slot(current: ?u32, next: ?u32) bool {
    if (current) |a| {
        if (next) |b| {
            return a == b;
        }
        return false;
    }
    return next == null;
}

fn tooltip_rect(knob: turtle.Rect) turtle.Rect {
    assert(knob.width > 0);
    const rect: turtle.Rect = .{
        .x = knob.x + tooltip_offset_x,
        .y = knob.y + tooltip_offset_y,
        .width = tooltip_width,
        .height = tooltip_height,
    };
    assert(rect.width == tooltip_width);
    assert(rect.x > knob.x);
    return rect;
}

/// Writes "name d.dd" into `out` and returns the used prefix.
fn tooltip_text(out: *[tooltip_text_cap]u8, knob: widgets.Knob) []const u8 {
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

fn fill_panel(scene: *Scene, panel_index: u32) void {
    assert(panel_index < panel_count);
    const gap: f32 = if (panel_index == 0) 0 else panel_gap_px;
    scene.widgets[panel_slot(panel_index)] = .{ .panel = rack_panel(panel_index, gap) };
    var knob_index: u32 = 0;
    while (knob_index < knobs_per_panel) : (knob_index += 1) {
        const flat = panel_index * knobs_per_panel + knob_index;
        const slot = knob_slot(panel_index, knob_index);
        scene.widgets[slot] = .{ .knob = rack_knob(flat) };
    }
    scene.widgets[meter_slot(panel_index)] = .{ .meter = rack_meter(panel_index) };
    assert(scene.widgets[panel_slot(panel_index)].panel.id != 0);
    assert(knob_index == knobs_per_panel);
}

fn place_panels(scene: *Scene, width_logical: u32, height_logical: u32) void {
    assert(width_logical != 0);
    assert(height_logical != 0);
    var walks: [panel_count]turtle.Walk = undefined;
    var rects: [panel_count]turtle.Rect = undefined;
    var index: u32 = 0;
    while (index < panel_count) : (index += 1) {
        walks[index] = scene.widgets[panel_slot(index)].panel.walk;
    }
    assert(index == panel_count);
    // The panels' column starts below the header bar and its gap (module guide, section 2).
    const top = header_px + header_gap_px;
    const column: turtle.Column = .{
        .rect = .{
            .x = 0,
            .y = top,
            .width = @floatFromInt(width_logical),
            .height = @max(0, @as(f32, @floatFromInt(height_logical)) - top),
        },
        .padding = column_padding,
    };
    turtle.place_column(column, &walks, &rects);
    index = 0;
    while (index < panel_count) : (index += 1) {
        const slot = panel_slot(index);
        scene.widgets[slot].panel.rect = rects[index];
        widgets.place_label(
            &scene.widgets[slot].panel.label,
            rects[index],
            scene.widgets[slot].panel.padding,
        );
        const band = band_height(scene.widgets[slot].panel.label.rect.height);
        scene.widgets[slot].panel.label.rect.height = band;
        assert(band <= title_band_px);
        place_panel_body(scene, index);
    }
    assert(index == panel_count);
}

fn place_panel_body(scene: *Scene, panel_index: u32) void {
    assert(panel_index < panel_count);
    const panel = &scene.widgets[panel_slot(panel_index)].panel;
    const inner_x = panel.rect.x + panel.padding.left;
    const inner_y = panel.rect.y + panel.padding.top;
    const inner_w = panel.rect.width - panel.padding.left - panel.padding.right;
    const inner_h = panel.rect.height - panel.padding.top - panel.padding.bottom;
    const band = band_height(inner_h);
    const body_y = inner_y + band;
    const body_h = inner_h - band;
    assert(body_h == inner_h - band);
    assert(band <= title_band_px);
    var walks: [knobs_per_panel]turtle.Walk = undefined;
    var rects: [knobs_per_panel]turtle.Rect = undefined;
    var knob_index: u32 = 0;
    while (knob_index < knobs_per_panel) : (knob_index += 1) {
        walks[knob_index] = scene.widgets[knob_slot(panel_index, knob_index)].knob.walk;
    }
    const span = knob_row_width(inner_w);
    const knob_row: turtle.Column = .{
        .rect = .{
            .x = inner_x,
            .y = body_y,
            .width = span,
            .height = widgets.knob_height,
        },
        .padding = zero_margin,
    };
    turtle.place_row(knob_row, &walks, &rects);
    knob_index = 0;
    while (knob_index < knobs_per_panel) : (knob_index += 1) {
        const slot = knob_slot(panel_index, knob_index);
        scene.widgets[slot].knob.rect = rects[knob_index];
    }
    keep_fitted_knobs(scene, panel_index, .{
        .x = inner_x,
        .y = body_y,
        .width = span,
        .height = body_h,
    });
    place_meter_cell(scene, panel_index, .{
        .x = inner_x,
        .y = body_y,
        .width = inner_w,
        .height = body_h,
    });
    assert(knob_index == knobs_per_panel);
    assert(span == knob_row_width(inner_w));
}

/// Width left of the meter. Below `meter_column_px` the meter is dropped and the knobs may
/// use the whole inner width.
fn knob_row_width(inner_w: f32) f32 {
    assert(inner_w == inner_w);
    if (inner_w >= meter_column_px) {
        assert(inner_w >= meter_column_px);
        return inner_w - meter_column_px;
    }
    if (inner_w > 0) {
        assert(inner_w < meter_column_px);
        return inner_w;
    }
    assert(inner_w <= 0);
    return 0;
}

/// Drops a knob whose fixed cell crosses the meter column or the panel bottom.
fn keep_fitted_knobs(scene: *Scene, panel_index: u32, limit: turtle.Rect) void {
    assert(panel_index < panel_count);
    var knob_index: u32 = 0;
    while (knob_index < knobs_per_panel) : (knob_index += 1) {
        const knob = &scene.widgets[knob_slot(panel_index, knob_index)].knob;
        if (!rect_inside(knob.rect, limit)) {
            knob.rect = empty_rect;
        }
    }
    assert(knob_index == knobs_per_panel);
    assert(panel_index < panel_count);
}

fn place_meter_cell(scene: *Scene, panel_index: u32, body: turtle.Rect) void {
    assert(panel_index < panel_count);
    assert(body.x == body.x);
    const meter = &scene.widgets[meter_slot(panel_index)].meter;
    if (body.width < meter_column_px) {
        assert(body.width < meter_column_px);
        meter.rect = empty_rect;
        return;
    }
    if (body.height <= 0) {
        assert(body.height <= 0);
        meter.rect = empty_rect;
        return;
    }
    meter.rect = .{
        .x = body.x + body.width - meter_column_px,
        .y = body.y,
        .width = meter_column_px,
        .height = body.height,
    };
    assert(meter.rect.width == meter_column_px);
    assert(meter.rect.height > 0);
}

fn rect_inside(child: turtle.Rect, parent: turtle.Rect) bool {
    assert(child.x == child.x);
    assert(parent.x == parent.x);
    if (parent.width <= 0) {
        assert(parent.width <= 0);
        return false;
    }
    if (parent.height <= 0) {
        assert(parent.height <= 0);
        return false;
    }
    if (child.width <= 0) {
        assert(child.width <= 0);
        return false;
    }
    if (child.height <= 0) {
        assert(child.height <= 0);
        return false;
    }
    if (child.x < parent.x) {
        return false;
    }
    if (child.y < parent.y) {
        return false;
    }
    if (child.x + child.width > parent.x + parent.width) {
        return false;
    }
    if (child.y + child.height > parent.y + parent.height) {
        return false;
    }
    return true;
}

fn rack_panel(panel_index: u32, gap: f32) widgets.Panel {
    assert(panel_index < panel_count);
    assert(gap >= 0);
    const color = theme.chrome.panel;
    const panel: widgets.Panel = .{
        .id = panel_index + 1,
        .rect = empty_rect,
        .walk = .{
            .margin = .{ .left = 0, .top = gap, .right = 0, .bottom = 0 },
            .width = .fill,
            .height = .fill,
            .align_x = 0,
        },
        .padding = panel_padding,
        .label = .{
            .text = panel_names[panel_index],
            .rect = empty_rect,
            .style = title_style,
        },
        .paint = .{
            .r = color[0],
            .g = color[1],
            .b = color[2],
            .a = color[3],
            .radius = panel_radius,
        },
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .down = animator.Animator.init(widgets.down_rate_per_ms),
    };
    assert(panel.id != 0);
    assert(!panel.hover.live());
    return panel;
}

fn rack_knob(flat: u32) widgets.Knob {
    assert(flat < knob_table.len);
    const spec = knob_table[flat];
    var knob: widgets.Knob = .{
        .id = 10 + flat,
        .rect = empty_rect,
        .walk = knob_cell_walk(),
        .name = spec.name,
        .value_text = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .value = spec.value,
        .accent = widgets.accents[flat % widgets.accent_count],
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .drag_y = 0,
    };
    knob.set_value(spec.value);
    assert(knob.name.len <= 8);
    assert(knob.value == spec.value);
    return knob;
}

fn rack_meter(panel_index: u32) widgets.Meter {
    assert(panel_index < panel_count);
    const meter: widgets.Meter = .{
        .id = 30 + panel_index,
        .rect = empty_rect,
        .walk = .{
            .margin = zero_margin,
            .width = .{ .fixed = meter_column_px },
            .height = .fill,
            .align_x = 0,
        },
        .name = "",
        .value = 0.5,
    };
    assert(meter.name.len == 0);
    assert(meter.value == 0.5);
    return meter;
}

fn knob_cell_walk() turtle.Walk {
    const walk: turtle.Walk = .{
        .margin = .{ .left = 8, .top = 0, .right = 0, .bottom = 0 },
        .width = .{ .fixed = knob_cell_px },
        .height = .{ .fixed = widgets.knob_height },
        .align_x = 0,
    };
    assert(walk.width.fixed == knob_cell_px);
    assert(walk.height.fixed == widgets.knob_height);
    return walk;
}

fn panel_slot(panel_index: u32) u32 {
    assert(panel_index < panel_count);
    const slot = panel_index * panel_stride;
    assert(slot < demo_count);
    return slot;
}

fn knob_slot(panel_index: u32, knob_index: u32) u32 {
    assert(knob_index < knobs_per_panel);
    const slot = panel_slot(panel_index) + 1 + knob_index;
    assert(slot < demo_count);
    return slot;
}

fn meter_slot(panel_index: u32) u32 {
    const slot = panel_slot(panel_index) + 1 + knobs_per_panel;
    assert(slot == panel_slot(panel_index) + 5);
    return slot;
}

/// A short window keeps the `title_band_px` title when it fits, and uses the inner height
/// when it does not. A non-positive inner rect contributes no band.
fn band_height(inner_h: f32) f32 {
    assert(inner_h == inner_h);
    if (inner_h >= title_band_px) {
        assert(inner_h >= title_band_px);
        return title_band_px;
    }
    if (inner_h > 0) {
        assert(inner_h < title_band_px);
        return inner_h;
    }
    assert(inner_h <= 0);
    return 0;
}

fn clip_for(scene: *const Scene, index: u32, window: quads.Clip) quads.Clip {
    assert(index < scene.count);
    assert(window.x1 > window.x0);
    switch (scene.widgets[index]) {
        .knob => {
            const slot = index - (index % panel_stride);
            assert(slot % panel_stride == 0);
            return panel_clip(scene.widgets[slot].panel.rect, window);
        },
        .meter => |meter| {
            const slot = index - (index % panel_stride);
            assert(slot % panel_stride == 0);
            const panel = panel_clip(scene.widgets[slot].panel.rect, window);
            return meter_face_clip(meter.rect, panel);
        },
        .panel => return window,
    }
}

/// Knob faces clip to the panel. A degenerate panel has no exclusive rect, so
/// those faces use the window clip instead of aborting the frame.
fn panel_clip(rect: turtle.Rect, window: quads.Clip) quads.Clip {
    assert(window.x1 > window.x0);
    if (rect.width <= 0) {
        assert(rect.width <= 0);
        return window;
    }
    if (rect.height <= 0) {
        assert(rect.height <= 0);
        return window;
    }
    return rect_clip(rect);
}

fn rect_clip(rect: turtle.Rect) quads.Clip {
    assert(rect.width > 0);
    assert(rect.height > 0);
    const clip: quads.Clip = .{
        .x0 = rect.x,
        .y0 = rect.y,
        .x1 = rect.x + rect.width,
        .y1 = rect.y + rect.height,
    };
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    return clip;
}

/// The meter track has a fixed height even when the cell is shorter. Clipping to the cell
/// keeps that bar off the title and off the knobs beside it.
fn meter_face_clip(rect: turtle.Rect, panel: quads.Clip) quads.Clip {
    assert(panel.x1 > panel.x0);
    assert(panel.y1 > panel.y0);
    if (rect.width <= 0) {
        assert(rect.width <= 0);
        return panel;
    }
    if (rect.height <= 0) {
        assert(rect.height <= 0);
        return panel;
    }
    return rect_clip(rect);
}

comptime {
    assert(widget_cap == 32);
    assert(panel_count == 3);
    assert(knobs_per_panel == 4);
    assert(panel_stride == 6);
    assert(demo_count == 18);
    assert(panel_count * panel_stride == demo_count);
    assert(demo_count <= widget_cap);
    assert(levels.meter_count == panel_count);
    assert(panel_stride == 1 + knobs_per_panel + 1);
    // Worst-case boxes: one per panel, two per meter, the tooltip, and the header bar.
    assert(panel_count + panel_count * 2 + 1 + 1 <= box_cap);
    // Worst-case arcs: two per knob (track and value arc).
    assert(panel_count * knobs_per_panel * 2 <= arc_cap);
    // Worst-case glyphs: a label of up to 8 per panel, up to 8 for each knob name and 4 for
    // each value text, the tooltip text, and the header; 43 of 256 to spare.
    assert(panel_count * 8 + panel_count * knobs_per_panel * (8 + 4) + tooltip_text_cap +
        header_glyph_cap + 43 == glyph_cap);
    // Every codepoint of the header draws at most one glyph.
    const author_codepoints = std.unicode.utf8CountCodepoints(patch_author) catch unreachable;
    assert(tempo_value.len + tempo_unit.len + author_codepoints <= header_glyph_cap);
    // One badge and one LED per panel.
    assert(panel_count <= image_cap);
    assert(panel_count <= led_cap);
    // Base: box, glyph, image, LED, arc; overlay: box and glyph.
    assert(5 + 2 <= batch_cap);
    // The box covers the neighbouring cell's whole name column.
    assert(tooltip_offset_x + tooltip_width >= knob_cell_px + 8 + 72 + 72);
    assert(widget_cap <= turtle.child_cap);
    assert(column_padding.left == 16);
    assert(knob_table.len == panel_count * knobs_per_panel);
    assert(panel_names.len == panel_count);
    assert(title_band_px == 24);
    assert(meter_column_px == 80);
    assert(knob_cell_px == 144);
}

const Context = patchwork.app.Context(App);

/// The test app and draw context: static, like the hosts', so the badge pixels the context's
/// queued write points at stay put, and the pools stay off the stack.
const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

/// A fresh app, initialized against a fresh context the way a host does.
fn new_app() *App {
    fixture.context.init();
    App.init(&fixture.app, &fixture.context.textures);
    return &fixture.app;
}

/// Resets the context and draws the app into it, the way a host does, then finalizes it.
fn draw_frame(app: *App) *Context {
    const cx = &fixture.context;
    cx.reset();
    app.draw(cx);
    cx.finalize();
    assert(cx.overflow_count == 0);
    return cx;
}

// Pulls the levels, LED, and badge modules' tests into this app's test run.
test {
    _ = levels;
    _ = led;
    _ = badge;
}

fn expect_rect(rect: turtle.Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

fn rect_of(rect: [4]f32) turtle.Rect {
    return .{ .x = rect[0], .y = rect[1], .width = rect[2], .height = rect[3] };
}

fn knob_at(app: *App, panel_index: u32, knob_index: u32) *widgets.Knob {
    return &app.scene.widgets[knob_slot(panel_index, knob_index)].knob;
}

fn meter_at(app: *App, panel_index: u32) *widgets.Meter {
    return &app.scene.widgets[meter_slot(panel_index)].meter;
}

// Locks panel, knob, ring, and meter rects, the knob and meter clips, and the omitted value
// arc of a zero-valued knob.
test "rack layout at 1280 by 720" {
    const app = new_app();
    app.layout(1280, 720);
    // The column starts below the 52 px header and its 8 px gap, at y = 60. Panel height =
    // (720 - 60 - 2 * 16 padding - 2 * 8 gap) / 3; the panels start 8 below each other.
    try expect_rect(header_rect(1280, 720).?, 16, 16, 1248, 52);
    try expect_rect(app.scene.widgets[panel_slot(0)].panel.rect, 16, 76, 1248, 204);
    try expect_rect(app.scene.widgets[panel_slot(1)].panel.rect, 16, 288, 1248, 204);
    try expect_rect(app.scene.widgets[panel_slot(2)].panel.rect, 16, 500, 1248, 204);
    // First knob: x = 16 panel + 8 padding + 8 cell margin, y = 76 + 8 + 24 title band.
    try expect_rect(knob_at(app, 0, 0).rect, 32, 108, 144, 72);
    try expect_rect(widgets.ring_of(knob_at(app, 0, 0).rect), 40, 116, 56, 56);
    // Meter: right edge of the inner rect, 80 wide, body height 204 - 16 - 24.
    try expect_rect(meter_at(app, 0).rect, 1176, 108, 80, 164);
    const title = app.scene.widgets[panel_slot(0)].panel.label.rect;
    try std.testing.expectEqual(@as(f32, 24), title.height);
    const cx = draw_frame(app);
    // The header + 3 panels + 3 meters * 2 faces; 12 knobs * 2 arcs minus the zero-valued
    // knob's arc. Glyphs: titles 3 + 6 + 3, knob names 40, values 12 * 4, the tempo 6 + 3,
    // and the author 17 (its two spaces have no ink).
    try std.testing.expectEqual(@as(usize, 10), cx.items(quads.Box).len);
    try std.testing.expectEqual(@as(usize, 23), cx.items(quads.Arc).len);
    try std.testing.expectEqual(@as(usize, 126), cx.items(quads.Glyph).len);
    try std.testing.expectEqual(@as(usize, 3), cx.items(quads.Image).len);
    try std.testing.expectEqual(@as(usize, 3), cx.items(led.Led).len);
    const ring = widgets.ring_of(knob_at(app, 0, 3).rect);
    var arcs: u32 = 0;
    for (cx.items(quads.Arc)) |arc| {
        // The first ring clips to its panel rect.
        if (arc.rect[0] == 40 and arc.rect[1] == 116) {
            try std.testing.expectEqualSlices(f32, &.{ 16, 76, 1264, 280 }, &arc.clip);
        }
        if (arc.rect[0] == ring.x and arc.rect[1] == ring.y) {
            arcs += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
    try std.testing.expect(!app.dirty());
}

// Locks that a smaller window shrinks panel heights and the meter cell, not the knob cells.
test "rack layout at 800 by 600" {
    const app = new_app();
    app.layout(800, 600);
    try expect_rect(app.scene.widgets[panel_slot(0)].panel.rect, 16, 76, 768, 164);
    try expect_rect(app.scene.widgets[panel_slot(1)].panel.rect, 16, 248, 768, 164);
    try expect_rect(app.scene.widgets[panel_slot(2)].panel.rect, 16, 420, 768, 164);
    try expect_rect(widgets.ring_of(knob_at(app, 0, 0).rect), 40, 116, 56, 56);
    try expect_rect(meter_at(app, 0).rect, 696, 108, 80, 124);
}

// Locks that `timer` writes meters only when a sample changes and knob drags never do.
test "apply_meters writes the sample and a knob drag does not" {
    const app = new_app();
    app.layout(1280, 720);
    try std.testing.expect(!app.timer(0));
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(app, 0).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(app, 1).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(app, 2).value);
    try std.testing.expect(app.timer(500));
    const sampled = levels.sample(500);
    try std.testing.expectEqual(@as(f32, 1), sampled[0]);
    try std.testing.expect(sampled[1] != 1);
    try std.testing.expect(sampled[2] != 1);
    try std.testing.expectEqual(sampled[0], meter_at(app, 0).value);
    try std.testing.expectEqual(sampled[1], meter_at(app, 1).value);
    try std.testing.expectEqual(sampled[2], meter_at(app, 2).value);
    const amp = meter_at(app, 2).value;
    const ring = widgets.ring_of(knob_at(app, 2, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(app, 2, 0).value);
    try std.testing.expectEqual(amp, meter_at(app, 2).value);
    try std.testing.expect(!app.timer(500));
    try std.testing.expectEqual(amp, meter_at(app, 2).value);
}

// Locks ring drag and ring wheel through the scene, and that a wheel off the ring is ignored.
test "a ring drag and a ring wheel change the knob" {
    const app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(app, 0, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), knob_at(app, 0, 0).value);
    try std.testing.expect(app.event(.{ .pointer_up = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expect(app.event(.{ .wheel = .{ .x = cx, .y = cy, .dy = -60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(app, 0, 0).value);
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = 40, .y = 30 } }));
    try std.testing.expect(!app.event(.{ .wheel = .{ .x = 40, .y = 30, .dy = 40 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(app, 0, 0).value);
}

// Locks that raising a zero-valued knob adds exactly one face.
test "dragging mix off zero adds the value arc" {
    const app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(app, 0, 3).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.5), knob_at(app, 0, 3).value);
    const drawn = draw_frame(app);
    try std.testing.expectEqual(@as(usize, 24), drawn.items(quads.Arc).len);
    try std.testing.expectEqual(@as(usize, 126), drawn.items(quads.Glyph).len);
}

// Locks hover easing and that a settled scene stays clean across frames.
test "hover on rate eases and a later frame stays clean" {
    const app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(app, 0, 0).rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(app.event(.{ .pointer_move = point }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(app, 0, 0).hover.target);
    try std.testing.expect(app.live());
    try std.testing.expect(app.event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), knob_at(app, 0, 0).hover.value, 0.0001);
    try std.testing.expect(app.event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(app, 0, 0).hover.value);
    try std.testing.expect(!app.live());
    _ = draw_frame(app);
    try std.testing.expect(!app.dirty());
    try std.testing.expect(!app.event(.{ .frame = 16 }));
    try std.testing.expect(!app.dirty());
}

fn rects_overlap(a: turtle.Rect, b: turtle.Rect) bool {
    if (a.width <= 0) {
        return false;
    }
    if (a.height <= 0) {
        return false;
    }
    if (b.width <= 0) {
        return false;
    }
    if (b.height <= 0) {
        return false;
    }
    if (a.x + a.width <= b.x) {
        return false;
    }
    if (b.x + b.width <= a.x) {
        return false;
    }
    if (a.y + a.height <= b.y) {
        return false;
    }
    if (b.y + b.height <= a.y) {
        return false;
    }
    return true;
}

// Locks that knob cells crossing the meter column are dropped, not painted over the bar.
test "a narrow window keeps only knobs that clear the meter" {
    const app = new_app();
    app.layout(400, 720);
    try std.testing.expectEqual(@as(f32, 144), knob_at(app, 0, 0).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(app, 0, 1).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(app, 0, 2).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(app, 0, 3).rect.width);
    try std.testing.expectEqual(@as(f32, 80), meter_at(app, 0).rect.width);
    try std.testing.expect(!rects_overlap(knob_at(app, 0, 0).rect, meter_at(app, 0).rect));
    const cx = draw_frame(app);
    try std.testing.expect(cx.items(quads.Box).len >= 3);
}

// Locks that a body shorter than a knob row drops the knob instead of leaking into the
// next panel.
test "a short window hides knobs that would leave the panel" {
    const app = new_app();
    // 260 leaves the panels' column the 200 px a 200 px window gave before the header.
    app.layout(1280, 260);
    try std.testing.expectEqual(@as(f32, 0), knob_at(app, 0, 0).rect.height);
    try std.testing.expect(meter_at(app, 0).rect.height > 0);
    try std.testing.expect(meter_at(app, 0).rect.height < widgets.knob_height);
    try std.testing.expect(!rects_overlap(knob_at(app, 0, 0).rect, meter_at(app, 0).rect));
    const cx = draw_frame(app);
    try std.testing.expect(cx.items(quads.Box).len >= 3);
}

// Locks that degenerate windows draw without aborting and never overlap a knob and a meter.
test "a tiny window still draws" {
    const app = new_app();
    app.layout(32, 32);
    const empty = draw_frame(app);
    try std.testing.expectEqual(@as(usize, 0), empty.items(quads.Box).len);
    app.layout(48, 720);
    const narrow = draw_frame(app);
    try std.testing.expect(narrow.items(quads.Box).len >= 1);
    try std.testing.expect(!rects_overlap(knob_at(app, 0, 0).rect, meter_at(app, 0).rect));
}

const fixture_gpu = struct {
    var renderer: patchwork.renderer.Renderer(Context) = undefined;
    var buffer: patchwork.commands.CommandBuffer = undefined;
};

/// Records the setup stream the way a host does after `App.init`.
fn setup_renderer() void {
    fixture_gpu.renderer.init();
    fixture_gpu.buffer = .init();
    fixture_gpu.renderer.setup(&fixture_gpu.buffer, &fixture.context);
}

/// Draws the app when it is dirty or the glyph cache owes a draw, the way a host does, then
/// records one 1280 by 720 logical frame at `scale_120`.
fn record(app: *App, scale_120: u32) void {
    const cx = &fixture.context;
    if (app.dirty() or cx.text.owes_draw(scale_120)) {
        cx.text.scale_120 = scale_120;
        cx.reset();
        app.draw(cx);
        assert(cx.overflow_count == 0);
    }
    fixture_gpu.buffer.reset();
    fixture_gpu.renderer.frame(&fixture_gpu.buffer, cx, .{
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

/// Hovers the center of `knob`'s ring.
fn hover_knob(app: *App, knob: *const widgets.Knob) !void {
    const ring = widgets.ring_of(knob.rect);
    try std.testing.expect(app.event(.{ .pointer_move = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    } }));
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
    app.layout(1280, 720);
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
    const batches = fixture.context.batch_list();
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

    try hover_knob(app, knob_at(app, 0, 0));
    try std.testing.expect(app.event(.{ .frame = 50 }));
    record(app, 240);
    const hover = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(@as(usize, 1), hover.len);
    const arc_buffer = fixture_gpu.renderer.resources.instance_buffers[1];
    try std.testing.expectEqual(arc_buffer, hover[0].id);
    const arcs = fixture.context.items(quads.Arc);
    try std.testing.expect(hover[0].data.len < arcs.len * @sizeOf(quads.Arc));
}

// Locks the layer rule for the tooltip: it appears only after `tooltip_delay_ms` of hover,
// its box overlaps the neighbouring knob's name glyphs, it sits on the overlay layer, and both
// overlay batches (box, then text) are drawn after every base batch. A move to the neighbour
// hides it.
test "the tooltip box covers the neighbour's text on the overlay layer" {
    const app = new_app();
    app.layout(1280, 720);
    try hover_knob(app, knob_at(app, 0, 0));
    try std.testing.expect(app.live());
    var waited: u32 = 0;
    while (waited < 4) : (waited += 1) {
        try std.testing.expect(!app.event(.{ .frame = 100 }) or waited == 0);
    }
    try std.testing.expect(!app.tooltip_visible());
    try std.testing.expect(app.event(.{ .frame = 100 }));
    try std.testing.expect(app.tooltip_visible());
    try std.testing.expect(!app.live());
    const cx = draw_frame(app);
    const boxes = cx.items(quads.Box);
    const last = boxes.len - 1;
    try std.testing.expectEqual(quads.Layer.overlay, cx.layer_at(quads.Box, @intCast(last)));
    const tip = rect_of(boxes[last].rect);
    const neighbour = knob_at(app, 0, 1).rect;
    var covered: u32 = 0;
    for (cx.items(quads.Glyph), 0..) |glyph, index| {
        if (cx.layer_at(quads.Glyph, @intCast(index)) != .base) continue;
        if (glyph.rect[0] < neighbour.x) continue;
        if (rects_overlap(tip, rect_of(glyph.rect))) covered += 1;
    }
    try std.testing.expect(covered >= 1);
    const batches = cx.batch_list();
    const overlay: u8 = @backingInt(quads.Layer.overlay);
    try std.testing.expectEqual(overlay, batches[batches.len - 2].layer);
    try std.testing.expectEqual(@as(u8, 0), batches[batches.len - 2].type_id);
    try std.testing.expectEqual(overlay, batches[batches.len - 1].layer);
    try std.testing.expectEqual(@as(u8, 2), batches[batches.len - 1].type_id);
    for (batches[0 .. batches.len - 2]) |batch| {
        try std.testing.expectEqual(@as(u8, 0), batch.layer);
    }
    try hover_knob(app, knob_at(app, 0, 1));
    try std.testing.expect(!app.tooltip_visible());
}

// Locks the title band: each panel's badge samples the badge texture and clears the centered
// title text, and each LED's brightness is its panel's meter level.
test "badges clear the title and leds follow the meters" {
    const app = new_app();
    app.layout(1280, 720);
    try std.testing.expect(app.timer(500));
    const cx = draw_frame(app);
    const images = cx.items(quads.Image);
    try std.testing.expectEqual(@as(usize, panel_count), images.len);
    for (images) |image| {
        for (cx.items(quads.Glyph)) |glyph| {
            try std.testing.expect(!rects_overlap(rect_of(image.rect), rect_of(glyph.rect)));
        }
    }
    const lights = cx.items(led.Led);
    try std.testing.expectEqual(@as(usize, panel_count), lights.len);
    var index: u32 = 0;
    while (index < panel_count) : (index += 1) {
        try std.testing.expectEqual(meter_at(app, index).value, lights[index].brightness);
    }
}

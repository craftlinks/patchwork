//! Retained demo: synthesizer rack of three panels, twelve knobs, and three meters.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! Production audio workstation and modular synthesizer interfaces present dense groupings of
//! parameters organized into hardware-style equipment racks.
//!
//! Patchwork implements this running example as a modular synthesizer rack:
//! - **Three Equipment Panels:** Oscillator (`osc`), Filter (`filter`), and Amplifier (`amp`)
//!   stacked vertically across the window.
//! - **Why the Rack is a Flat Widget List:** Rather than introducing a hierarchical tree of
//!   nested container widgets (which would duplicate the pointer and gesture arbitration logic
//!   of `Scroll`), the rack is stored as a flat array of sibling widgets (`widget_cap = 32`,
//!   `demo_count = 18`) inside `ui.Scene(Widget, widget_cap)`. The scene array performs
//!   back-to-front hit testing; because later slots win over earlier slots, a knob ring or meter
//!   cell automatically wins over its backing panel. Layout is the only subsystem that knows
//!   about panel grouping.
//! - **Retained Column Example:** The Step 8 single-scroll column architecture lives in
//!   `examples/column/app.zig`, preserving existing scroll regression tests and locks.
//! - **Scissor-Free Hierarchical Clipping:** Panel faces use the window clip. Knob faces clip
//!   to the parent panel. Meter faces clip to the meter cell, because the track is 144 px tall
//!   and would cover the title on a short panel. `clip_for` writes that rectangle into
//!   attribute location 4. The shader masks fragments outside it, with no GPU scissor.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All measurements are in UI logical pixels, top-left origin `(0, 0)`, `+X` right, and `+Y` down.
//!
//! ### Rack Column & Panel Geometry:
//! Root container column has outer padding 16 px on all sides.
//! Panels specify: `width = .fill`, `height = .fill`, `align_x = 0`.
//! The first panel has `margin.top = 0`; the subsequent two panels have `margin.top = 8`.
//! Leftover vertical space is distributed equally among all three panels.
//!
//! ### Panel Interior: Title Band, Knob Row, and Meter:
//! Each panel has internal padding 8 px on all sides:
//! - `inner_x = panel.rect.x + 8`, `inner_y = panel.rect.y + 8`.
//! - `inner_w = panel.rect.width - 16`, `inner_h = panel.rect.height - 16`.
//! - **Title Band:** Occupies 24 px at the top of the inner rect. `place_label` centers the
//!   title within the panel; layout then explicitly clamps label height to 24 px.
//! - **Body Rect:** Starts below the title band:
//!   `body_y = inner_y + 24`, `body_h = inner_h - 24`.
//! - **Knob Row:** Packed left-to-right via `turtle.place_row`:
//!   - Width: `inner_w - 80` while the meter column fits, otherwise the whole `inner_w`.
//!   - Height: fixed 72 px (`widgets.knob_height`).
//!   - Walk per knob cell: `margin.left = 8`, `width = .fixed(144)`, `height = .fixed(72)`,
//!     `align_x = 0`. Four knob cells cost 608 px main axis (`4 * (144 + 8)`).
//! - **Meter Column:** Placed at right edge: `x = inner_x + inner_w - 80`, `y = body_y`,
//!   `width = 80`, `height = body_h`.
//! - **What does not fit is omitted:** A knob cell is kept only when its whole 144 by 72 box
//!   lies in the row beside the meter, and the meter is kept only when its column lies in the
//!   body. The meter face is clipped to its cell: the track is always 144 px tall and would
//!   otherwise cover the title on a short panel.
//!
//! ### Relative Drag & Wheel Derivations:
//! - **Vertical Pointer Drag:** Pointer travel `dy = y - drag_y` adjusts knob value by
//!   `-dy / 120.0` (dragging up increases value). Drag span is 120 px across `[0.0, 1.0]`.
//! - **Mouse Wheel Nudge:** Wheel delta `wheel.dy` over a knob ring nudges value by `-dy / 120.0`.
//! - **Meter Passthrough:** Meters hit-test for containment to occlude underlying panel surfaces,
//!   but ignore gestures.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Static Memory Budgets & Slot Layout:
//! - `widget_cap = 32`: Root scene capacity in `ui.Scene(Widget, widget_cap)`.
//! - `panel_count = 3`, `knobs_per_panel = 4`, `panel_stride = 6`.
//! - `demo_count = 18` (3 panels * 6 slots):
//!   - Slot `p * 6 + 0`: Panel container.
//!   - Slots `p * 6 + 1 .. p * 6 + 4`: Four knobs.
//!   - Slot `p * 6 + 5`: Vertical level meter.
//! - Concrete worked coordinates, controls roster, and first-frame quad/glyph budgets belong in
//!   tests and `README.md`. Worst-case allocations strictly respect `draw.instance_cap = 256` and
//!   `font.glyph_cap = 256`.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Retained Pointer Routing (Back-to-Front Hit Testing):
//! `App` wraps `ui.Scene(Widget, widget_cap)`:
//! 1. `pointer_move`: Scans `widgets` array in reverse order (`count - 1` down to 0).
//!    The first widget returning `contains(x, y) == true` becomes `hovered`.
//! 2. `pointer_down`: Hit-tests back-to-front. If a knob ring is pressed, sets `capture` to that
//!    slot and initializes `drag_y`.
//! 3. `pointer_up`: Clears `capture` and releases active drag.
//!
//! ### Host-Driven Meter Synchronization:
//! Host event loops call `App.timer(now_ms)` at approximately 30 Hz (`timer_period_ms = 33`):
//! - Samples procedural triangle waves from `levels.sample(now_ms)`.
//! - Calls `Meter.set_value()` on slots 5, 11, and 17.
//! - `Meter.set_value()` returns `true` only when the value actually changes.
//! - Returns `true` only when at least one meter value changes, dirtying `app.scene`.
//! - Drawing reads stored `meter.value` only; dragging a knob does not alter meter levels.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Native (Linux Wayland):** Main loop in `src/host/linux_window.zig` sleeps in `ppoll` with a
//!   nonblocking `timerfd` (33 ms). On wake, `drain_timer` calls `app.timer(now_ms)`.
//! - **Web (WebAssembly):** `web/shell.js` invokes `setInterval` at `timer_period_ms()` (33 ms),
//!   calling `wasm.timer(now_ms)`. If dirty, schedules one `requestAnimationFrame`.
//! - **Wheel Normalization:** Wayland pointer axis and DOM wheel events normalize to logical pixel
//!   deltas forwarded to `app.event(.{ .wheel = ... })`.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Allocation:** Fixed 32-element widget array (`widget_cap = 32`).
//!   Zero runtime heap allocation.
//! - **Bounded Operations:** All iterations bounded by `widget_cap`, `panel_count`, or
//!   `knobs_per_panel`.
//! - **Split Assertions:** Boundary conditions and non-zero dimensions asserted individually.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const animator = patchwork.animator;
const font = patchwork.font;
const quads = patchwork.draw;
const input = patchwork.input;
const theme = patchwork.theme;
const turtle = patchwork.turtle;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const levels = @import("levels.zig");

/// Maximum widgets in the rack scene. The rack uses 18.
pub const widget_cap: u32 = 32;

/// Panels in the rack. Each one is followed by four knobs and one meter.
pub const panel_count: u32 = 3;

/// Knobs in one panel row.
pub const knobs_per_panel: u32 = 4;

/// Slots from one panel to the next: panel, four knobs, meter.
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

/// The rack app: one flat scene of three panels, twelve knobs, and three meters.
/// `timer` writes the procedural meter levels at the period in `config`.
pub const App = struct {
    scene: Scene,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork",
        .timer_period_ms = levels.meter_period_ms,
    };

    /// One rack: three panels, four knobs each, one meter each. Rects are empty until `layout`.
    pub fn init(app: *App) void {
        app.scene = Scene.init(demo_count);
        var panel_index: u32 = 0;
        while (panel_index < panel_count) : (panel_index += 1) {
            fill_panel(&app.scene, panel_index);
        }
        assert(app.scene.count == demo_count);
        assert(!app.scene.pointer.inside);
    }

    /// Places the three panels, then each panel's knob row and meter.
    pub fn layout(app: *App, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
        assert(app.scene.count == demo_count);
        place_panels(&app.scene, width_logical, height_logical);
        app.scene.finish_layout(width_logical, height_logical);
        assert(app.scene.dirty);
    }

    pub fn event(app: *App, event_value: input.Event) bool {
        assert(app.scene.count == demo_count);
        return app.scene.handle_event(event_value);
    }

    /// Writes the latest samples onto the three meters. Dirty only when one changes.
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
        return app.scene.live();
    }

    pub fn dirty(app: *const App) bool {
        assert(app.scene.count == demo_count);
        return app.scene.dirty;
    }

    /// Clears both lists and draws every widget. The window clip is the full frame.
    pub fn draw(app: *App, list: *quads.DrawList, glyphs: *font.GlyphList) void {
        assert(app.scene.width_logical != 0);
        assert(app.scene.height_logical != 0);
        list.clear();
        glyphs.clear();
        const clip: font.Clip = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = @floatFromInt(app.scene.width_logical),
            .y1 = @floatFromInt(app.scene.height_logical),
        };
        var index: u32 = 0;
        while (index < app.scene.count) : (index += 1) {
            const face_clip = clip_for(&app.scene, index, clip);
            widget_draw(&app.scene.widgets[index], list, glyphs, face_clip);
        }
        app.scene.finish_draw();
        // A window smaller than one panel has no positive face. That frame is empty.
        assert(list.count <= quads.instance_cap);
        assert(glyphs.count <= font.glyph_cap);
    }
};

fn widget_draw(
    widget: *const Widget,
    list: *quads.DrawList,
    glyphs: *font.GlyphList,
    clip: font.Clip,
) void {
    assert(list.count <= quads.instance_cap);
    assert(clip.x1 > clip.x0);
    switch (widget.*) {
        inline else => |*payload| payload.draw(list, glyphs, clip),
    }
    assert(list.count <= quads.instance_cap);
    assert(glyphs.count <= font.glyph_cap);
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
    const column: turtle.Column = .{
        .rect = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width_logical),
            .height = @floatFromInt(height_logical),
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

/// Width left of the meter. Below an 80 px body the meter is dropped and the
/// knobs may use the whole inner width.
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
    const text = theme.chrome.text;
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
            .r = text[0],
            .g = text[1],
            .b = text[2],
            .a = text[3],
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

/// A short window keeps the 24 px title when it fits, and uses the inner height
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

fn clip_for(scene: *const Scene, index: u32, window: font.Clip) font.Clip {
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
fn panel_clip(rect: turtle.Rect, window: font.Clip) font.Clip {
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

fn rect_clip(rect: turtle.Rect) font.Clip {
    assert(rect.width > 0);
    assert(rect.height > 0);
    const clip: font.Clip = .{
        .x0 = rect.x,
        .y0 = rect.y,
        .x1 = rect.x + rect.width,
        .y1 = rect.y + rect.height,
    };
    assert(clip.x1 > clip.x0);
    assert(clip.y1 > clip.y0);
    return clip;
}

/// The meter track is 144 px tall even when the cell is shorter. Clipping to the
/// cell keeps that bar off the title and off the knobs beside it.
fn meter_face_clip(rect: turtle.Rect, panel: font.Clip) font.Clip {
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
    assert(3 + 12 * 2 + 3 * 2 <= quads.instance_cap);
    assert(3 * 8 + 12 * 8 + 12 * 4 <= font.glyph_cap);
    assert(widget_cap <= turtle.child_cap);
    assert(column_padding.left == 16);
    assert(knob_table.len == panel_count * knobs_per_panel);
    assert(panel_names.len == panel_count);
    assert(title_band_px == 24);
    assert(meter_column_px == 80);
    assert(knob_cell_px == 144);
}

fn new_app() App {
    var app: App = undefined;
    App.init(&app);
    return app;
}

test {
    _ = levels;
}

fn expect_rect(rect: turtle.Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

fn expect_box(instance: quads.Instance, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, instance.x);
    try std.testing.expectEqual(y, instance.y);
    try std.testing.expectEqual(width, instance.width);
    try std.testing.expectEqual(height, instance.height);
}

fn knob_at(app: *App, panel_index: u32, knob_index: u32) *widgets.Knob {
    return &app.scene.widgets[knob_slot(panel_index, knob_index)].knob;
}

fn meter_at(app: *App, panel_index: u32) *widgets.Meter {
    return &app.scene.widgets[meter_slot(panel_index)].meter;
}

test "rack layout at 1280 by 720" {
    var app = new_app();
    app.layout(1280, 720);
    try expect_rect(app.scene.widgets[panel_slot(0)].panel.rect, 16, 16, 1248, 224);
    try expect_rect(app.scene.widgets[panel_slot(1)].panel.rect, 16, 248, 1248, 224);
    try expect_rect(app.scene.widgets[panel_slot(2)].panel.rect, 16, 480, 1248, 224);
    try expect_rect(knob_at(&app, 0, 0).rect, 32, 48, 144, 72);
    try expect_rect(widgets.ring_of(knob_at(&app, 0, 0).rect), 40, 56, 56, 56);
    try expect_rect(meter_at(&app, 0).rect, 1176, 48, 80, 184);
    try std.testing.expectEqual(@as(f32, 24), app.scene.widgets[panel_slot(0)].panel.label.rect.height);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 32), list.count);
    try std.testing.expectEqual(@as(u32, 100), glyphs.count);
    const ring = widgets.ring_of(knob_at(&app, 0, 3).rect);
    var arcs: u32 = 0;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const face = list.items[index];
        if (face.x == 40 and face.y == 56) {
            try std.testing.expectEqual(@as(f32, 16), face.clip_x0);
            try std.testing.expectEqual(@as(f32, 16), face.clip_y0);
            try std.testing.expectEqual(@as(f32, 1264), face.clip_x1);
            try std.testing.expectEqual(@as(f32, 240), face.clip_y1);
        }
        if (face.kind != quads.kind_arc) {
            continue;
        }
        if (face.x != ring.x) {
            continue;
        }
        if (face.y != ring.y) {
            continue;
        }
        arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
    try std.testing.expect(!app.dirty());
}

test "rack layout at 800 by 600" {
    var app = new_app();
    app.layout(800, 600);
    try expect_rect(app.scene.widgets[panel_slot(0)].panel.rect, 16, 16, 768, 184);
    try expect_rect(app.scene.widgets[panel_slot(1)].panel.rect, 16, 208, 768, 184);
    try expect_rect(app.scene.widgets[panel_slot(2)].panel.rect, 16, 400, 768, 184);
    try expect_rect(widgets.ring_of(knob_at(&app, 0, 0).rect), 40, 56, 56, 56);
    try expect_rect(meter_at(&app, 0).rect, 696, 48, 80, 144);
}

test "apply_meters writes the sample and a knob drag does not" {
    var app = new_app();
    app.layout(1280, 720);
    try std.testing.expect(!app.timer(0));
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&app, 0).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&app, 1).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&app, 2).value);
    try std.testing.expect(app.timer(500));
    const sampled = levels.sample(500);
    try std.testing.expectEqual(@as(f32, 1), sampled[0]);
    try std.testing.expect(sampled[1] != 1);
    try std.testing.expect(sampled[2] != 1);
    try std.testing.expectEqual(sampled[0], meter_at(&app, 0).value);
    try std.testing.expectEqual(sampled[1], meter_at(&app, 1).value);
    try std.testing.expectEqual(sampled[2], meter_at(&app, 2).value);
    const amp = meter_at(&app, 2).value;
    const ring = widgets.ring_of(knob_at(&app, 2, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&app, 2, 0).value);
    try std.testing.expectEqual(amp, meter_at(&app, 2).value);
    try std.testing.expect(!app.timer(500));
    try std.testing.expectEqual(amp, meter_at(&app, 2).value);
}

test "a ring drag and a ring wheel change the knob" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&app, 0, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), knob_at(&app, 0, 0).value);
    try std.testing.expect(app.event(.{ .pointer_up = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expect(app.event(.{ .wheel = .{ .x = cx, .y = cy, .dy = -60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&app, 0, 0).value);
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = 40, .y = 30 } }));
    try std.testing.expect(!app.event(.{ .wheel = .{ .x = 40, .y = 30, .dy = 40 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&app, 0, 0).value);
}

test "dragging mix off zero adds the value arc" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&app, 0, 3).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.5), knob_at(&app, 0, 3).value);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 33), list.count);
    try std.testing.expectEqual(@as(u32, 100), glyphs.count);
}

test "hover on rate eases and a later frame stays clean" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&app, 0, 0).rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(app.event(.{ .pointer_move = point }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&app, 0, 0).hover.target);
    try std.testing.expect(app.live());
    try std.testing.expect(app.event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), knob_at(&app, 0, 0).hover.value, 0.0001);
    try std.testing.expect(app.event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&app, 0, 0).hover.value);
    try std.testing.expect(!app.live());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
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

// 400 px leaves room for the meter and one 152 px knob cell. The other three
// used to keep their fixed boxes and paint across the bar.
test "a narrow window keeps only knobs that clear the meter" {
    var app = new_app();
    app.layout(400, 720);
    try std.testing.expectEqual(@as(f32, 144), knob_at(&app, 0, 0).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&app, 0, 1).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&app, 0, 2).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&app, 0, 3).rect.width);
    try std.testing.expectEqual(@as(f32, 80), meter_at(&app, 0).rect.width);
    try std.testing.expect(!rects_overlap(knob_at(&app, 0, 0).rect, meter_at(&app, 0).rect));
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 3);
}

// Below the 72 px body, a placed knob would stick out of its panel into the next.
test "a short window hides knobs that would leave the panel" {
    var app = new_app();
    app.layout(1280, 200);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&app, 0, 0).rect.height);
    try std.testing.expect(meter_at(&app, 0).rect.height > 0);
    try std.testing.expect(meter_at(&app, 0).rect.height < widgets.knob_height);
    try std.testing.expect(!rects_overlap(knob_at(&app, 0, 0).rect, meter_at(&app, 0).rect));
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 3);
}

test "a tiny window still draws" {
    var app = new_app();
    app.layout(32, 32);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 0), list.count);
    app.layout(48, 720);
    app.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 1);
    try std.testing.expect(!rects_overlap(knob_at(&app, 0, 0).rect, meter_at(&app, 0).rect));
}

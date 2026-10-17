//! Retained demo: synthesizer rack of three panels, twelve knobs, and three meters.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! Production audio workstation and modular synthesizer interfaces present dense groupings of
//! parameters organized into hardware-style equipment racks.
//!
//! In Step 9, Patchwork transitions its running demo from the single-column scroll inspector of
//! Step 8 to an interactive modular synthesizer rack:
//! - **Three Equipment Panels:** Oscillator (`osc`), Filter (`filter`), and Amplifier (`amp`)
//!   stacked vertically across the window.
//! - **Why the Rack is a Flat Widget List:** Rather than introducing a hierarchical tree of
//!   nested container widgets (which would duplicate the pointer and gesture arbitration logic
//!   of `Scroll`), the rack is stored as a flat array of sibling widgets (`widget_cap = 32`,
//!   `demo_count = 18`). The scene array already performs back-to-front hit testing; because
//!   later slots win over earlier slots, a knob ring or meter cell automatically wins over its
//!   backing panel. Layout is the only subsystem that knows about panel grouping.
//! - **Retained Test Scene:** `Scene.init_column` and `Scene.layout_column` retain the Step 8
//!   single-scroll column architecture so that Step 8 scroll regression tests keep their locks.
//!   `Panel`, `Button`, `Slider`, and `Scroll` remain fully implemented and tested in the codebase.
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
//!
//! - **At 1280 x 720:**
//!   - Available width: `1280 - 32 = 1248 px`.
//!   - Available height: `720 - 32 = 688 px`.
//!   - Fixed margin cost: `2 * 8 = 16 px`.
//!   - Leftover height: `688 - 16 = 672 px`.
//!   - Height per panel: `672 / 3 = 224 px`.
//!   - `osc`:    `(16,  16, 1248, 224)`.
//!   - `filter`: `(16, 248, 1248, 224)`.
//!   - `amp`:    `(16, 480, 1248, 224)` (bottom edge: `480 + 224 = 704`).
//! - **At 800 x 600:**
//!   - Available width: `800 - 32 = 768 px`.
//!   - Available height: `600 - 32 = 568 px`.
//!   - Leftover height: `568 - 16 = 552 px`.
//!   - Height per panel: `552 / 3 = 184 px`.
//!   - `osc`:    `(16,  16, 768, 184)`.
//!   - `filter`: `(16, 208, 768, 184)`.
//!   - `amp`:    `(16, 400, 768, 184)` (bottom edge: `400 + 184 = 584`).
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
//!     `align_x = 0`.
//!   - Main-axis cost for 4 knobs: `4 * (144 + 8) = 608 px`.
//! - **Meter Column:**
//!   - Placed at right edge: `x = inner_x + inner_w - 80`, `y = body_y`, `width = 80`,
//!     `height = body_h`.
//! - **What does not fit is omitted.** A knob cell is kept only when its whole 144 by 72
//!   box lies in the row beside the meter, and the meter is kept only when its column lies
//!   in the body. The meter is placed independently of the row, so a fixed cell drawn past
//!   that row paints over the bar. The meter face is clipped to its cell: the track is
//!   always 144 px tall and would otherwise cover the title on a short panel.
//!
//! ### Concrete Worked Coordinates:
//! - **At 1280 x 720:**
//!   - `osc` body rect: `(24, 48, 1232, 184)`.
//!   - First knob cell: `(32, 48, 144, 72)`.
//!   - First knob ring: `(40, 56, 56, 56)`.
//!   - `osc` meter cell: `(1176, 48, 80, 184)`.
//!   - `osc` meter track: `(1206, 68, 12, 144)`.
//! - **At 800 x 600:**
//!   - First knob ring: `(40, 56, 56, 56)` (invariant).
//!   - `osc` meter cell: `(696, 48, 80, 144)`.
//!   - `osc` meter track: `(726, 48, 12, 144)` (fills cell height).
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
//! - `widget_cap = 32`: Root scene capacity.
//! - `panel_count = 3`, `knobs_per_panel = 4`, `panel_stride = 6`.
//! - `demo_count = 18` (3 panels * 6 slots):
//!   - Slot `p * 6 + 0`: Panel container.
//!   - Slots `p * 6 + 1 .. p * 6 + 4`: Four knobs.
//!   - Slot `p * 6 + 5`: Vertical level meter.
//!
//! ### Demo Controls Roster & Initial Values:
//! - **Oscillator (`osc`):** `rate` (0.25), `fine` (0.50), `wave` (0.75), `mix` (0.00).
//!   (Note: `mix` value arc is omitted on first frame because value is 0.0).
//! - **Filter (`filter`):** `cut` (0.50), `res` (0.25), `env` (0.50), `key` (1.00).
//! - **Amplifier (`amp`):** `gain` (0.50), `pan` (0.50), `atk` (0.25), `rel` (0.75).
//! - **Accents:** Knobs cycle across 4 palette accents: purple `(0.62, 0.45, 0.86)`, green
//!   `(0.40, 0.78, 0.48)`, orange `(0.93, 0.55, 0.24)`, and yellow `(0.93, 0.80, 0.32)`.
//! - **Meters:** Empty name string `""`. Width 80 px ensures side-label box has positive width,
//!   but zero glyphs are emitted.
//!
//! ### First-Frame Budgets:
//! - **Quad Instances (32):**
//!   - 3 panels + 12 knob track arcs + 11 knob value arcs (omitting `mix` at 0) + 6 meter faces
//!     (3 tracks + 3 fills) = 32 instances.
//!   - Dragging `mix` off 0 creates the 12th value arc, bringing total instances to 33.
//! - **Text Glyphs (100):**
//!   - 12 panel title letters (`osc`, `filter`, `amp`) + 40 knob name letters + 48 formatted value
//!     letters (12 knobs * 4 characters `0.xx`) = 100 glyphs.
//! - **Budget Assertion:** Worst-case glyph budget is `3*8 + 12*8 + 12*4 = 168 <= 256`.
//!   `quads.instance_cap = 256` and `font.glyph_cap = 256` are strictly respected.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Retained Pointer Routing (Back-to-Front Hit Testing):
//! 1. `pointer_move`: Scans `widgets` array in reverse order (`count - 1` down to 0).
//!    The first widget returning `contains(x, y) == true` becomes `hovered`.
//! 2. `pointer_down`: Hit-tests back-to-front. If a knob ring is pressed, sets `capture` to that
//!    slot and initializes `drag_y`.
//! 3. `pointer_up`: Clears `capture` and releases active drag.
//!
//! ### Host-Driven Meter Synchronization:
//! Host event loops call `Scene.apply_meters(now_ms)` at approximately 30 Hz:
//! - Samples procedural triangle waves from `levels.sample(now_ms)`.
//! - Calls `Meter.set_value()` on slots 5, 11, and 17.
//! - `Meter.set_value()` returns `true` only when the value actually changes.
//! - `self.dirty` is set only when at least one meter value changes.
//! - Drawing reads stored `meter.value` only; dragging a knob does not alter meter levels.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Native (Linux Wayland):** Main loop sleeps in `ppoll` with a nonblocking `timerfd` (33 ms).
//!   On wake, drains the timer and calls `Scene.apply_meters(now_ms)`.
//! - **Web (WebAssembly):** `web/shell.js` invokes `setInterval` at `meter_period_ms()` (33 ms),
//!   calling `wasm.meter_clock(now_ms)`. If dirty, schedules one `requestAnimationFrame`.
//! - **Wheel Normalization:** Wayland pointer axis and DOM wheel events normalize to logical pixel
//!   deltas forwarded to `Scene.handle_event(.{ .wheel = ... })`.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Allocation:** Fixed 32-element widget array (`widget_cap = 32`).
//!   Zero runtime heap allocation.
//! - **Bounded Operations:** All iterations bounded by `widget_cap`, `panel_count`, or
//!   `knobs_per_panel`.
//! - **Split Assertions:** Boundary conditions and non-zero dimensions asserted individually.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const font = @import("font.zig");
const quads = @import("draw.zig");
const input = @import("input.zig");
const levels = @import("levels.zig");
const theme = @import("theme.zig");
const turtle = @import("turtle.zig");
const widgets = @import("widgets.zig");

/// Maximum widgets in one scene. The rack uses 18. The column test uses 1.
pub const widget_cap: u32 = 32;

pub const slot_scroll: u32 = 0;

/// Panels in the rack. Each one is followed by four knobs and one meter.
pub const panel_count: u32 = 3;

/// Knobs in one panel row.
pub const knobs_per_panel: u32 = 4;

/// Slots from one panel to the next: panel, four knobs, meter.
pub const panel_stride: u32 = 6;

/// Widgets in the running rack.
pub const demo_count: u32 = panel_count * panel_stride;

const column_count: u32 = 1;

const id_scroll: u32 = 1;

const column_padding: turtle.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
const scroll_padding: turtle.Inset = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 };
const row_margin: turtle.Inset = .{ .left = 0, .top = 8, .right = 0, .bottom = 0 };
const zero_margin: turtle.Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

const knob_specs = [_]struct { name: []const u8, value: f32 }{
    .{ .name = "gain", .value = 0.25 },
    .{ .name = "slope", .value = 0.50 },
    .{ .name = "twice", .value = 0.75 },
    .{ .name = "skew", .value = 0 },
    .{ .name = "echo", .value = 1 },
    .{ .name = "room", .value = 0.50 },
    .{ .name = "out", .value = 0.50 },
    .{ .name = "drive", .value = 0.50 },
};

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

/// One retained widget. The tag selects the behavior; the scene scans the array.
pub const Widget = union(enum) {
    panel: widgets.Panel,
    button: widgets.Button,
    slider: widgets.Slider,
    scroll: widgets.Scroll,
    knob: widgets.Knob,
    meter: widgets.Meter,
};

/// Retained demo. `capture` and `hovered` are slots in `widgets`, or null.
pub const Scene = struct {
    widgets: [widget_cap]Widget,
    count: u32,
    pointer: input.Pointer,
    was_down: bool,
    capture: ?u32,
    hovered: ?u32,
    dirty: bool,
    width_logical: u32,
    height_logical: u32,

    /// One rack: three panels, four knobs each, one meter each. Rects are empty until `layout`.
    pub fn init_demo() Scene {
        var scene: Scene = .{
            .widgets = undefined,
            .count = demo_count,
            .pointer = input.Pointer.init(),
            .was_down = false,
            .capture = null,
            .hovered = null,
            .dirty = false,
            .width_logical = 0,
            .height_logical = 0,
        };
        var panel_index: u32 = 0;
        while (panel_index < panel_count) : (panel_index += 1) {
            fill_panel(&scene, panel_index);
        }
        assert(scene.count == demo_count);
        assert(!scene.pointer.inside);
        return scene;
    }

    /// The step 8 column, kept so the scroll locks still have a scene to drive.
    pub fn init_column() Scene {
        var scene: Scene = .{
            .widgets = undefined,
            .count = column_count,
            .pointer = input.Pointer.init(),
            .was_down = false,
            .capture = null,
            .hovered = null,
            .dirty = false,
            .width_logical = 0,
            .height_logical = 0,
        };
        scene.widgets[slot_scroll] = .{ .scroll = demo_scroll() };
        assert(scene.count == column_count);
        assert(!scene.pointer.inside);
        return scene;
    }

    /// Places the three panels, then each panel's knob row and meter.
    pub fn layout(self: *Scene, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
        assert(self.count == demo_count);
        place_panels(self, width_logical, height_logical);
        self.width_logical = width_logical;
        self.height_logical = height_logical;
        self.dirty = true;
        self.redispatch();
        assert(self.dirty);
        assert(self.width_logical == width_logical);
    }

    /// Places the scroll column the step 8 tests still lock.
    pub fn layout_column(self: *Scene, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
        assert(self.count == column_count);
        var walks: [widget_cap]turtle.Walk = undefined;
        var rects: [widget_cap]turtle.Rect = undefined;
        const count: usize = @intCast(self.count);
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            walks[index] = widget_walk(&self.widgets[index]);
        }
        assert(index == self.count);
        const column: turtle.Column = .{
            .rect = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width_logical),
                .height = @floatFromInt(height_logical),
            },
            .padding = column_padding,
        };
        turtle.place_column(column, walks[0..count], rects[0..count]);
        index = 0;
        while (index < self.count) : (index += 1) {
            widget_set_rect(&self.widgets[index], rects[index]);
            widget_place(&self.widgets[index]);
        }
        self.width_logical = width_logical;
        self.height_logical = height_logical;
        self.dirty = true;
        self.redispatch();
        assert(self.dirty);
        assert(self.width_logical == width_logical);
    }

    /// Writes the latest samples onto the three meters. Dirty only when one changes.
    pub fn apply_meters(self: *Scene, now_ms: u64) bool {
        assert(self.count == demo_count);
        const sampled = levels.sample(now_ms);
        var changed = false;
        var index: u32 = 0;
        while (index < panel_count) : (index += 1) {
            const meter = &self.widgets[meter_slot(index)].meter;
            if (meter.set_value(sampled[index])) {
                changed = true;
            }
            assert(meter.value == sampled[index]);
        }
        if (changed) {
            self.dirty = true;
        }
        assert(index == panel_count);
        assert(self.count == demo_count);
        return changed;
    }

    /// Applies one event. A move inside the scroll is forwarded so child hover
    /// can change without the scene slot changing.
    pub fn handle_event(self: *Scene, event: input.Event) bool {
        assert(self.count <= widget_cap);
        assert(self.width_logical == self.width_logical);
        switch (event) {
            .pointer_move => |point| return self.on_move(point),
            .pointer_down => |point| return self.on_down(point),
            .pointer_up => |point| return self.on_up(point),
            .pointer_leave => return self.on_leave(),
            .frame => |dt_ms| return self.on_frame(dt_ms),
            .wheel => |wheel| return self.on_wheel(wheel),
        }
    }

    /// True while any widget animator has not reached its target.
    pub fn live(self: *const Scene) bool {
        assert(self.count <= widget_cap);
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            if (widget_live(&self.widgets[index])) {
                assert(index < self.count);
                return true;
            }
        }
        assert(index == self.count);
        return false;
    }

    /// Clears both lists and draws the scroll. The window clip is the full frame.
    pub fn draw(self: *Scene, list: *quads.DrawList, glyphs: *font.GlyphList) void {
        assert(self.width_logical != 0);
        assert(self.height_logical != 0);
        list.clear();
        glyphs.clear();
        const clip: font.Clip = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = @floatFromInt(self.width_logical),
            .y1 = @floatFromInt(self.height_logical),
        };
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            const face_clip = clip_for(self, index, clip);
            widget_draw(&self.widgets[index], list, glyphs, face_clip);
        }
        self.dirty = false;
        assert(!self.dirty);
        // A window smaller than one panel has no positive face. That frame is empty.
        assert(list.count <= quads.instance_cap);
        assert(glyphs.count <= font.glyph_cap);
    }

    fn on_move(self: *Scene, point: input.Point) bool {
        assert(point.x == point.x);
        assert(point.y == point.y);
        self.pointer.move(point.x, point.y);
        self.was_down = self.pointer.down;
        if (self.capture) |index| {
            assert(self.pointer.down);
            return self.mark(self.send(index, .{ .drag = point }));
        }
        var changed = self.dispatch_hover(point);
        if (self.hovered) |index| {
            if (self.send(index, .{ .move = point })) {
                changed = true;
            }
        }
        return self.mark(changed);
    }

    fn on_down(self: *Scene, point: input.Point) bool {
        self.pointer.move(point.x, point.y);
        self.pointer.button(true);
        self.was_down = true;
        var changed = self.dispatch_hover(point);
        if (self.hovered) |index| {
            if (self.send(index, .{ .move = point })) {
                changed = true;
            }
            self.capture = index;
            if (self.send(index, .{ .down = point })) {
                changed = true;
            }
        }
        assert(self.pointer.down);
        assert(self.was_down);
        return self.mark(changed);
    }

    fn on_up(self: *Scene, point: input.Point) bool {
        self.pointer.move(point.x, point.y);
        self.pointer.button(false);
        self.was_down = false;
        var changed = false;
        if (self.capture) |index| {
            const inside = widget_contains(&self.widgets[index], point.x, point.y);
            const up: widgets.Up = .{ .x = point.x, .y = point.y, .inside = inside };
            if (self.send(index, .{ .up = up })) {
                changed = true;
            }
            self.capture = null;
        }
        if (self.dispatch_hover(point)) {
            changed = true;
        }
        if (self.hovered) |index| {
            if (self.send(index, .{ .move = point })) {
                changed = true;
            }
        }
        assert(!self.pointer.down);
        assert(self.capture == null);
        return self.mark(changed);
    }

    fn on_leave(self: *Scene) bool {
        var changed = false;
        if (self.capture) |index| {
            const up: widgets.Up = .{
                .x = self.pointer.x,
                .y = self.pointer.y,
                .inside = false,
            };
            if (self.send(index, .{ .up = up })) {
                changed = true;
            }
            self.capture = null;
        }
        if (self.hovered) |index| {
            if (self.send(index, .hover_out)) {
                changed = true;
            }
            self.hovered = null;
        }
        self.pointer.leave();
        self.was_down = false;
        assert(self.capture == null);
        assert(!self.pointer.down);
        return self.mark(changed);
    }

    fn on_frame(self: *Scene, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.count <= widget_cap);
        var changed = false;
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            if (widget_animate(&self.widgets[index], dt_ms)) {
                changed = true;
            }
        }
        assert(index == self.count);
        return self.mark(changed);
    }

    fn on_wheel(self: *Scene, wheel: input.Wheel) bool {
        assert(wheel.dy == wheel.dy);
        self.pointer.move(wheel.x, wheel.y);
        var changed = false;
        if (self.capture == null) {
            if (self.dispatch_hover(.{ .x = wheel.x, .y = wheel.y })) {
                changed = true;
            }
            if (self.hovered) |index| {
                if (self.send(index, .{ .move = .{ .x = wheel.x, .y = wheel.y } })) {
                    changed = true;
                }
            }
        }
        if (self.topmost(wheel.x, wheel.y)) |index| {
            if (self.send(index, .{ .wheel = wheel })) {
                changed = true;
            }
        }
        assert(self.count <= widget_cap);
        return self.mark(changed);
    }

    fn redispatch(self: *Scene) void {
        assert(self.count <= widget_cap);
        if (!self.pointer.inside) {
            self.clear_hover();
            assert(!self.pointer.inside);
            return;
        }
        const point: input.Point = .{ .x = self.pointer.x, .y = self.pointer.y };
        if (self.capture) |index| {
            assert(self.was_down);
            _ = self.send(index, .{ .drag = point });
            return;
        }
        _ = self.dispatch_hover(point);
        if (self.hovered) |index| {
            _ = self.send(index, .{ .move = point });
        }
        assert(self.pointer.inside);
    }

    fn dispatch_hover(self: *Scene, point: input.Point) bool {
        assert(self.count <= widget_cap);
        const next = self.topmost(point.x, point.y);
        if (same_hover(self.hovered, next)) {
            assert(self.count <= widget_cap);
            return false;
        }
        var changed = false;
        if (self.hovered) |previous| {
            if (self.send(previous, .hover_out)) {
                changed = true;
            }
        }
        if (next) |chosen| {
            if (self.send(chosen, .hover_in)) {
                changed = true;
            }
        }
        self.hovered = next;
        assert(same_hover(self.hovered, next));
        return changed;
    }

    fn clear_hover(self: *Scene) void {
        if (self.hovered) |previous| {
            _ = self.send(previous, .hover_out);
            self.hovered = null;
        }
        assert(self.hovered == null);
        assert(self.count <= widget_cap);
    }

    fn topmost(self: *const Scene, x: f32, y: f32) ?u32 {
        assert(self.count <= widget_cap);
        var index: u32 = self.count;
        while (index > 0) {
            index -= 1;
            if (widget_contains(&self.widgets[index], x, y)) {
                assert(index < self.count);
                return index;
            }
        }
        assert(index == 0);
        return null;
    }

    fn send(self: *Scene, index: u32, hit: widgets.Hit) bool {
        assert(index < self.count);
        assert(self.count <= widget_cap);
        return widget_handle(&self.widgets[index], hit);
    }

    fn mark(self: *Scene, changed: bool) bool {
        if (changed) {
            self.dirty = true;
        }
        assert(self.count <= widget_cap);
        assert(self.capture == null or self.capture.? < self.count);
        return changed;
    }
};

fn same_hover(hovered: ?u32, next: ?u32) bool {
    if (hovered) |previous| {
        if (next) |chosen| {
            assert(previous < widget_cap);
            return previous == chosen;
        }
        assert(next == null);
        return false;
    }
    if (next == null) {
        assert(hovered == null);
        return true;
    }
    assert(next != null);
    return false;
}

fn widget_handle(widget: *Widget, hit: widgets.Hit) bool {
    const before = widget_id(widget);
    assert(before != 0);
    const changed = switch (widget.*) {
        .panel => |*panel| panel.handle(hit),
        .button => |*button| button.handle(hit),
        .slider => |*slider| slider.handle(hit),
        .scroll => |*scroll| scroll.handle(hit),
        .knob => |*knob| knob.handle(hit),
        .meter => |*meter| meter.handle(hit),
    };
    assert(widget_id(widget) == before);
    return changed;
}

fn widget_animate(widget: *Widget, dt_ms: f32) bool {
    assert(dt_ms >= 0);
    assert(widget_id(widget) != 0);
    return switch (widget.*) {
        .panel => |*panel| panel.animate(dt_ms),
        .button => |*button| button.animate(dt_ms),
        .slider => |*slider| slider.animate(dt_ms),
        .scroll => |*scroll| scroll.animate(dt_ms),
        .knob => |*knob| knob.animate(dt_ms),
        .meter => |*meter| meter.animate(dt_ms),
    };
}

fn widget_live(widget: *const Widget) bool {
    assert(widget_id(widget) != 0);
    switch (widget.*) {
        .panel => |*panel| return panel.live(),
        .button => |*button| return button.live(),
        .slider => |*slider| return slider.live(),
        .scroll => |*scroll| return scroll.live(),
        .knob => |*knob| return knob.live(),
        .meter => |*meter| return meter.live(),
    }
}

fn widget_contains(widget: *const Widget, x: f32, y: f32) bool {
    assert(x == x);
    assert(y == y);
    return switch (widget.*) {
        .panel => |*panel| panel.contains(x, y),
        .button => |*button| button.contains(x, y),
        .slider => |*slider| slider.contains(x, y),
        .scroll => |*scroll| scroll.contains(x, y),
        .knob => |*knob| knob.contains(x, y),
        .meter => |*meter| meter.contains(x, y),
    };
}

fn widget_draw(
    widget: *const Widget,
    list: *quads.DrawList,
    glyphs: *font.GlyphList,
    clip: font.Clip,
) void {
    assert(list.count <= quads.instance_cap);
    assert(clip.x1 > clip.x0);
    switch (widget.*) {
        .panel => |*panel| panel.draw(list, glyphs, clip),
        .button => |*button| button.draw(list, glyphs, clip),
        .slider => |*slider| slider.draw(list, clip),
        .scroll => |*scroll| scroll.draw(list, glyphs, clip),
        .knob => |*knob| knob.draw(list, glyphs, knob.rect, clip),
        .meter => |*meter| meter.draw(list, glyphs, meter.rect, clip),
    }
    assert(list.count <= quads.instance_cap);
    assert(glyphs.count <= font.glyph_cap);
}

fn widget_place(widget: *Widget) void {
    assert(widget_id(widget) != 0);
    switch (widget.*) {
        .panel => |*panel| widgets.place_label(&panel.label, panel.rect, panel.padding),
        .button => |*button| widgets.place_label(&button.label, button.rect, button.padding),
        .slider => assert(widget_id(widget) != 0),
        .scroll => |*scroll| scroll.layout_children(),
        .knob => assert(widget_id(widget) != 0),
        .meter => assert(widget_id(widget) != 0),
    }
}

fn widget_walk(widget: *const Widget) turtle.Walk {
    switch (widget.*) {
        .panel => |*panel| return panel.walk,
        .button => |*button| return button.walk,
        .slider => |*slider| return slider.walk,
        .scroll => |*scroll| {
            assert(scroll.walk.align_x == 1);
            return scroll.walk;
        },
        .knob => |*knob| return knob.walk,
        .meter => |*meter| return meter.walk,
    }
}

fn widget_set_rect(widget: *Widget, rect: turtle.Rect) void {
    assert(rect.x == rect.x);
    assert(rect.y == rect.y);
    switch (widget.*) {
        .panel => |*panel| panel.rect = rect,
        .button => |*button| button.rect = rect,
        .slider => |*slider| slider.rect = rect,
        .scroll => |*scroll| scroll.rect = rect,
        .knob => |*knob| knob.rect = rect,
        .meter => |*meter| meter.rect = rect,
    }
}

fn widget_id(widget: *const Widget) u32 {
    switch (widget.*) {
        .panel => |*panel| return panel.id,
        .button => |*button| return button.id,
        .slider => |*slider| return slider.id,
        .scroll => |*scroll| {
            assert(scroll.child_count <= widgets.scroll_child_cap);
            return scroll.id;
        },
        .knob => |*knob| return knob.id,
        .meter => |*meter| return meter.id,
    }
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
        .panel, .button, .slider, .scroll => return window,
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

fn demo_scroll() widgets.Scroll {
    var scroll: widgets.Scroll = .{
        .id = id_scroll,
        .rect = empty_rect,
        .walk = .{
            .margin = zero_margin,
            .width = .{ .fixed = 320 },
            .height = .fill,
            .align_x = 1,
        },
        .padding = scroll_padding,
        .children = undefined,
        .child_count = 11,
        .scroll_y = 0,
        .content_h = 0,
        .press = .none,
        .hot = null,
    };
    var index: u32 = 0;
    while (index < knob_specs.len) : (index += 1) {
        scroll.children[index] = .{ .knob = demo_knob(index) };
    }
    scroll.children[8] = .{ .meter = demo_meter() };
    scroll.children[9] = .{ .toggle = demo_toggle(11, "take", true) };
    scroll.children[10] = .{ .toggle = demo_toggle(12, "drums", false) };
    assert(scroll.child_count == 11);
    assert(scroll.children[0].knob.value == 0.25);
    return scroll;
}

fn demo_knob(index: u32) widgets.Knob {
    assert(index < knob_specs.len);
    const spec = knob_specs[index];
    var knob: widgets.Knob = .{
        .id = index + 2,
        .rect = empty_rect,
        .walk = row_walk(widgets.knob_height),
        .name = spec.name,
        .value_text = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .value = spec.value,
        .accent = widgets.accents[index % widgets.accent_count],
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .drag_y = 0,
    };
    knob.set_value(spec.value);
    assert(knob.name.len <= 8);
    assert(knob.value == spec.value);
    return knob;
}

fn demo_meter() widgets.Meter {
    const meter: widgets.Meter = .{
        .id = 10,
        .rect = empty_rect,
        .walk = row_walk(widgets.meter_height),
        .name = "meter",
        .value = 0.50,
    };
    assert(meter.value == 0.50);
    assert(meter.walk.height.fixed == widgets.meter_height);
    return meter;
}

fn demo_toggle(id: u32, name: []const u8, on: bool) widgets.Toggle {
    assert(name.len <= 8);
    const toggle: widgets.Toggle = .{
        .id = id,
        .rect = empty_rect,
        .walk = row_walk(widgets.toggle_height),
        .name = name,
        .on = on,
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .thumb = widgets.settled(widgets.hover_rate_per_ms, on),
    };
    assert(toggle.on == on);
    assert(!toggle.thumb.live());
    return toggle;
}

fn row_walk(height: f32) turtle.Walk {
    assert(height > 0);
    const walk: turtle.Walk = .{
        .margin = row_margin,
        .width = .fill,
        .height = .{ .fixed = height },
        .align_x = 0,
    };
    assert(walk.margin.top == 8);
    assert(walk.height.fixed == height);
    return walk;
}

comptime {
    assert(widget_cap == 32);
    assert(panel_count == 3);
    assert(knobs_per_panel == 4);
    assert(panel_stride == 6);
    assert(demo_count == 18);
    assert(panel_count * panel_stride == demo_count);
    assert(1 + 1 + widgets.scroll_child_cap * 2 <= quads.instance_cap);
    assert(widgets.scroll_child_cap * 12 <= font.glyph_cap);
    assert(3 + 12 * 2 + 3 * 2 <= quads.instance_cap);
    assert(3 * 8 + 12 * 8 + 12 * 4 <= font.glyph_cap);
    assert(widget_cap <= turtle.child_cap);
    assert(column_padding.left == 16);
    assert(scroll_padding.left == 8);
    assert(knob_specs.len == 8);
    assert(knob_table.len == panel_count * knobs_per_panel);
    assert(panel_names.len == panel_count);
    assert(title_band_px == 24);
    assert(meter_column_px == 80);
    assert(knob_cell_px == 144);
}

fn scroll_of(scene: *Scene) *widgets.Scroll {
    assert(scene.count >= 1);
    return &scene.widgets[slot_scroll].scroll;
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

const view_clip: font.Clip = .{ .x0 = 952, .y0 = 24, .x1 = 1256, .y1 = 696 };

fn glyph_has_clip(glyph: font.Glyph, clip: font.Clip) bool {
    if (glyph.clip_x0 != clip.x0) {
        return false;
    }
    if (glyph.clip_y0 != clip.y0) {
        return false;
    }
    if (glyph.clip_x1 != clip.x1) {
        return false;
    }
    if (glyph.clip_y1 != clip.y1) {
        return false;
    }
    return true;
}

// 1280 by 720 parks the column on the right. The first ring is the gain knob.
test "demo layout at 1280 by 720" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const scroll = scroll_of(&scene);
    try expect_rect(scroll.rect, 944, 16, 320, 688);
    try expect_rect(scroll.viewport(), 952, 24, 304, 672);
    try expect_rect(scroll.content_column(), 952, 24, 288, 672);
    try std.testing.expectEqual(@as(f32, 904), scroll.content_h);
    try std.testing.expectEqual(@as(f32, 232), scroll.max_scroll());
    try expect_rect(scroll.children[0].knob.rect, 952, 32, 288, 72);
    try expect_rect(widgets.ring_of(scroll.children[0].knob.rect), 960, 40, 56, 56);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try expect_box(list.items[1], 960, 40, 56, 56);
    try std.testing.expectEqual(quads.kind_arc, list.items[1].kind);
    try std.testing.expectEqual(@as(f32, 1), list.items[1].down);
    try expect_box(list.items[2], 960, 40, 56, 56);
    try std.testing.expectEqual(@as(f32, 0.25), list.items[2].down);
    try std.testing.expect(!scene.dirty);
}

test "demo layout at 800 by 600" {
    var scene = Scene.init_column();
    scene.layout_column(800, 600);
    const scroll = scroll_of(&scene);
    try expect_rect(scroll.rect, 464, 16, 320, 568);
    try std.testing.expectEqual(@as(f32, 904), scroll.content_h);
    try std.testing.expectEqual(@as(f32, 352), scroll.max_scroll());
}

test "scroll 0 clips the meter and omits the toggles" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    var meter_faces: u32 = 0;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const face = list.items[index];
        if (face.y >= 840) {
            try std.testing.expect(false);
        }
        if (face.width == widgets.meter_track_w) {
            meter_faces += 1;
            try std.testing.expectEqual(view_clip.x0, face.clip_x0);
            try std.testing.expectEqual(view_clip.y0, face.clip_y0);
            try std.testing.expectEqual(view_clip.x1, face.clip_x1);
            try std.testing.expectEqual(view_clip.y1, face.clip_y1);
        }
    }
    try std.testing.expect(meter_faces >= 1);
    var gain_glyph = false;
    var meter_glyph = false;
    index = 0;
    while (index < glyphs.count) : (index += 1) {
        const glyph = glyphs.items[index];
        try std.testing.expect(glyph_has_clip(glyph, view_clip));
        if (glyph.y < 80) {
            gain_glyph = true;
        }
        if (glyph.y > 700) {
            meter_glyph = true;
        }
    }
    try std.testing.expect(gain_glyph);
    try std.testing.expect(meter_glyph);
}

test "value 0 omits the value arc" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const skew = scroll_of(&scene).children[3].knob.rect;
    const ring = widgets.ring_of(skew);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    var arcs: u32 = 0;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const face = list.items[index];
        if (face.kind != quads.kind_arc) {
            continue;
        }
        if (face.y != ring.y) {
            continue;
        }
        arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
}

test "a tall window draws the short toggle rows" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 1000);
    const scroll = scroll_of(&scene);
    try std.testing.expectEqual(@as(f32, 0), scroll.max_scroll());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    const drums = scroll.children[10].toggle.rect;
    const pill_y = drums.y + (drums.height - widgets.pill_h) * 0.5;
    var found = false;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        if (list.items[index].y == pill_y) {
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(glyphs.count > 0);
}

test "scroll 232 shows drums and clamps a further wheel" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const scroll = scroll_of(&scene);
    const view = scroll.viewport();
    const wheel_x = view.x + view.width - 8;
    const wheel_y = view.y + 40;
    try std.testing.expect(scene.handle_event(.{ .wheel = .{
        .x = wheel_x,
        .y = wheel_y,
        .dy = 232,
    } }));
    try std.testing.expectEqual(@as(f32, 232), scroll.scroll_y);
    const drums = scroll.children[10].toggle.rect;
    const bottom = drums.y - scroll.scroll_y + drums.height;
    try std.testing.expectEqual(view.y + view.height, bottom);
    try std.testing.expect(!scene.handle_event(.{ .wheel = .{
        .x = wheel_x,
        .y = wheel_y,
        .dy = 40,
    } }));
    try std.testing.expectEqual(@as(f32, 232), scroll.scroll_y);
}

test "knob drag from the ring center clamps at both ends" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&scene).children[0].knob.value);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy + 4000 } }));
    try std.testing.expectEqual(@as(f32, 0), scroll_of(&scene).children[0].knob.value);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy - 4000 } }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&scene).children[0].knob.value);
}

test "wheel on the ring nudges and wheel on the label scrolls" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .wheel = .{ .x = cx, .y = cy, .dy = -60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&scene).children[0].knob.value);
    try std.testing.expectEqual(@as(f32, 0), scroll_of(&scene).scroll_y);
    try std.testing.expect(scene.handle_event(.{ .wheel = .{
        .x = ring.x + 80,
        .y = cy,
        .dy = 40,
    } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&scene).children[0].knob.value);
    try std.testing.expectEqual(@as(f32, 40), scroll_of(&scene).scroll_y);
}

test "toggle up inside drums slides the thumb" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const scroll = scroll_of(&scene);
    const view = scroll.viewport();
    try std.testing.expect(scene.handle_event(.{ .wheel = .{
        .x = view.x + view.width - 8,
        .y = view.y + 40,
        .dy = 232,
    } }));
    const row = scroll.children[10].toggle.rect;
    const visual_y = row.y - scroll.scroll_y;
    const pill_x = row.x + widgets.ring_inset + widgets.pill_w * 0.5;
    const pill_y = visual_y + row.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_up = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(scroll.children[10].toggle.on);
    try std.testing.expectEqual(@as(f32, 1), scroll.children[10].toggle.thumb.target);
    try std.testing.expect(scene.handle_event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        scroll.children[10].toggle.thumb.value,
        0.0001,
    );
    try std.testing.expect(scene.handle_event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), scroll.children[10].toggle.thumb.value);
}

test "toggle up outside does not flip" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const scroll = scroll_of(&scene);
    const view = scroll.viewport();
    try std.testing.expect(scene.handle_event(.{ .wheel = .{
        .x = view.x + view.width - 8,
        .y = view.y + 40,
        .dy = 232,
    } }));
    const row = scroll.children[10].toggle.rect;
    const pill_x = row.x + widgets.ring_inset + widgets.pill_w * 0.5;
    const pill_y = row.y - scroll.scroll_y + row.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_up = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(!scroll.children[10].toggle.on);
    try std.testing.expectEqual(@as(f32, 0), scroll.children[10].toggle.thumb.target);
}

test "hover on gain eases and a later frame stays clean" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(scene.handle_event(.{ .pointer_move = point }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&scene).children[0].knob.hover.target);
    try std.testing.expect(scene.live());
    try std.testing.expect(scene.handle_event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        scroll_of(&scene).children[0].knob.hover.value,
        0.0001,
    );
    try std.testing.expect(scene.handle_event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&scene).children[0].knob.hover.value);
    try std.testing.expect(!scene.live());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expect(!scene.dirty);
    try std.testing.expect(!scene.handle_event(.{ .frame = 16 }));
    try std.testing.expect(!scene.dirty);
}

test "relayout by 8 px keeps gain hover" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(scene.handle_event(.{ .pointer_move = point }));
    scene.layout_column(1288, 720);
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&scene).children[0].knob.hover.target);
    try std.testing.expectEqual(slot_scroll, scene.hovered.?);
    try std.testing.expectEqual(@as(u32, 0), scroll_of(&scene).hot.?);
}

test "pointer leave during a knob press releases capture" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(scene.handle_event(.{ .pointer_down = point }));
    try std.testing.expect(scene.handle_event(.pointer_leave));
    try std.testing.expect(scene.capture == null);
    try std.testing.expect(!scene.pointer.inside);
    try std.testing.expectEqual(@as(f32, 0.25), scroll_of(&scene).children[0].knob.value);
}

test "a settled scene does not rebuild on a scale-style present" {
    var scene = Scene.init_column();
    scene.layout_column(1280, 720);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    const revision = list.revision;
    var cursor = quads.UploadCursor.init();
    cursor.mark(&list, &glyphs, 1280, 720);
    try std.testing.expect(!scene.dirty);
    try std.testing.expectEqual(@as(u32, 0), cursor.flags(&list, &glyphs, 1280, 720));
    try std.testing.expectEqual(revision, list.revision);
}

fn knob_at(scene: *Scene, panel_index: u32, knob_index: u32) *widgets.Knob {
    return &scene.widgets[knob_slot(panel_index, knob_index)].knob;
}

fn meter_at(scene: *Scene, panel_index: u32) *widgets.Meter {
    return &scene.widgets[meter_slot(panel_index)].meter;
}

test "rack layout at 1280 by 720" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try expect_rect(scene.widgets[panel_slot(0)].panel.rect, 16, 16, 1248, 224);
    try expect_rect(scene.widgets[panel_slot(1)].panel.rect, 16, 248, 1248, 224);
    try expect_rect(scene.widgets[panel_slot(2)].panel.rect, 16, 480, 1248, 224);
    try expect_rect(knob_at(&scene, 0, 0).rect, 32, 48, 144, 72);
    try expect_rect(widgets.ring_of(knob_at(&scene, 0, 0).rect), 40, 56, 56, 56);
    try expect_rect(meter_at(&scene, 0).rect, 1176, 48, 80, 184);
    try std.testing.expectEqual(@as(f32, 24), scene.widgets[panel_slot(0)].panel.label.rect.height);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 32), list.count);
    try std.testing.expectEqual(@as(u32, 100), glyphs.count);
    const ring = widgets.ring_of(knob_at(&scene, 0, 3).rect);
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
    try std.testing.expect(!scene.dirty);
}

test "rack layout at 800 by 600" {
    var scene = Scene.init_demo();
    scene.layout(800, 600);
    try expect_rect(scene.widgets[panel_slot(0)].panel.rect, 16, 16, 768, 184);
    try expect_rect(scene.widgets[panel_slot(1)].panel.rect, 16, 208, 768, 184);
    try expect_rect(scene.widgets[panel_slot(2)].panel.rect, 16, 400, 768, 184);
    try expect_rect(widgets.ring_of(knob_at(&scene, 0, 0).rect), 40, 56, 56, 56);
    try expect_rect(meter_at(&scene, 0).rect, 696, 48, 80, 144);
}

test "apply_meters writes the sample and a knob drag does not" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(!scene.apply_meters(0));
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&scene, 0).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&scene, 1).value);
    try std.testing.expectEqual(@as(f32, 0.5), meter_at(&scene, 2).value);
    try std.testing.expect(scene.apply_meters(500));
    const sampled = levels.sample(500);
    try std.testing.expectEqual(@as(f32, 1), sampled[0]);
    try std.testing.expect(sampled[1] != 1);
    try std.testing.expect(sampled[2] != 1);
    try std.testing.expectEqual(sampled[0], meter_at(&scene, 0).value);
    try std.testing.expectEqual(sampled[1], meter_at(&scene, 1).value);
    try std.testing.expectEqual(sampled[2], meter_at(&scene, 2).value);
    const amp = meter_at(&scene, 2).value;
    const ring = widgets.ring_of(knob_at(&scene, 2, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&scene, 2, 0).value);
    try std.testing.expectEqual(amp, meter_at(&scene, 2).value);
    try std.testing.expect(!scene.apply_meters(500));
    try std.testing.expectEqual(amp, meter_at(&scene, 2).value);
}

test "a ring drag and a ring wheel change the knob" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&scene, 0, 0).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), knob_at(&scene, 0, 0).value);
    try std.testing.expect(scene.handle_event(.{ .pointer_up = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expect(scene.handle_event(.{ .wheel = .{ .x = cx, .y = cy, .dy = -60 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&scene, 0, 0).value);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 40, .y = 30 } }));
    try std.testing.expect(!scene.handle_event(.{ .wheel = .{ .x = 40, .y = 30, .dy = 40 } }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&scene, 0, 0).value);
}

test "dragging mix off zero adds the value arc" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&scene, 0, 3).rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.5), knob_at(&scene, 0, 3).value);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 33), list.count);
    try std.testing.expectEqual(@as(u32, 100), glyphs.count);
}

test "hover on rate eases and a later frame stays clean" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    const ring = widgets.ring_of(knob_at(&scene, 0, 0).rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(scene.handle_event(.{ .pointer_move = point }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&scene, 0, 0).hover.target);
    try std.testing.expect(scene.live());
    try std.testing.expect(scene.handle_event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), knob_at(&scene, 0, 0).hover.value, 0.0001);
    try std.testing.expect(scene.handle_event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), knob_at(&scene, 0, 0).hover.value);
    try std.testing.expect(!scene.live());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expect(!scene.dirty);
    try std.testing.expect(!scene.handle_event(.{ .frame = 16 }));
    try std.testing.expect(!scene.dirty);
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
    var scene = Scene.init_demo();
    scene.layout(400, 720);
    try std.testing.expectEqual(@as(f32, 144), knob_at(&scene, 0, 0).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&scene, 0, 1).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&scene, 0, 2).rect.width);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&scene, 0, 3).rect.width);
    try std.testing.expectEqual(@as(f32, 80), meter_at(&scene, 0).rect.width);
    try std.testing.expect(!rects_overlap(knob_at(&scene, 0, 0).rect, meter_at(&scene, 0).rect));
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 3);
}

// Below the 72 px body, a placed knob would stick out of its panel into the next.
test "a short window hides knobs that would leave the panel" {
    var scene = Scene.init_demo();
    scene.layout(1280, 200);
    try std.testing.expectEqual(@as(f32, 0), knob_at(&scene, 0, 0).rect.height);
    try std.testing.expect(meter_at(&scene, 0).rect.height > 0);
    try std.testing.expect(meter_at(&scene, 0).rect.height < widgets.knob_height);
    try std.testing.expect(!rects_overlap(knob_at(&scene, 0, 0).rect, meter_at(&scene, 0).rect));
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 3);
}

test "a tiny window still draws" {
    var scene = Scene.init_demo();
    scene.layout(32, 32);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    scene.draw(&list, &glyphs);
    try std.testing.expectEqual(@as(u32, 0), list.count);
    scene.layout(48, 720);
    scene.draw(&list, &glyphs);
    try std.testing.expect(list.count >= 1);
    try std.testing.expect(!rects_overlap(knob_at(&scene, 0, 0).rect, meter_at(&scene, 0).rect));
}

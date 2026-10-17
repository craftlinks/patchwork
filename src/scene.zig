//! Retained demo: one right-hand scroll container of knobs, a meter, and toggles.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! User interfaces in production audio workstations, synthesizers, and creative tools rely on
//! dense inspector sidebars and channel strips containing continuous dials, peak meters,
//! switches, and scrollable container viewports.
//!
//! Rather than laying out a flat list of disparate top-level widgets across the window, Step 8
//! consolidates the retained UI into a single right-hand `Scroll` container widget:
//! - **The Channel Strip Inspector:** A 320 px wide column anchored to the right window edge.
//! - **Two-Tier Pointer Dispatch:** The top-level `Scene` manages coarse spatial routing across
//!   the root widget array (`widget_cap = 32`), tracking `scene.capture` and `scene.hovered`.
//!   When interacting with the scroll column, `scene.capture` is set to `slot_scroll` (0).
//!   The `Scroll` container then internally arbitrates sub-element interactions via `Scroll.press`
//!   (`.none`, `.child(u32)`, or `.thumb`).
//! - **Hierarchical Scissor-Free Clipping:** The scroll container background panel and
//!   the scrollbar thumb carry the unclipped window clip (`[0, 0, width, height]`), ensuring
//!   the gutter is never masked. All child control faces and text glyphs carry the inner
//!   viewport clip rect, masking straddling elements analytically in shaders with zero
//!   GPU scissor changes or render pass breaks.
//! - **Zero Allocation & Viewport Culling:** Stored child rectangles are unscrolled. Children
//!   outside the visible viewport are completely omitted from draw lists, saving GPU vertex
//!   bandwidth while strictly maintaining O(1) memory guarantees.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All positions are defined in UI logical pixels, top-left origin `(0, 0)`, `+X` right, `+Y` down.
//!
//! ### Root Column and Channel Strip Geometry:
//! Root container column has outer padding 16 px on all sides.
//! The `Scroll` widget specifies: `width = .fixed(320)`, `height = .fill`, `align_x = 1.0` (right),
//! and internal `padding = Inset(8, 8, 8, 8)`.
//!
//! - **At 1280 x 720:**
//!   - Available width after padding: `1280 - 32 = 1248`.
//!   - Scroll border box: `x = 16 + (1248 - 320) = 944`, `y = 16`, `width = 320`, `height = 688`.
//!   - Border box rect: `(944, 16, 320, 688)`.
//!   - Viewport rect (inset by padding 8): `(952, 24, 304, 672)`.
//!   - Content column (inset by 16 px gutter): `(952, 24, 288, 672)`.
//! - **At 800 x 600:**
//!   - Available width after padding: `800 - 32 = 768`.
//!   - Scroll border box: `x = 16 + (768 - 320) = 464`, `y = 16`, `width = 320`, `height = 568`.
//!   - Viewport rect: `(472, 24, 304, 552)`.
//!   - Content column: `(472, 24, 288, 552)`.
//!
//! ### Children Content Span and Scroll Limits:
//! The scroll container hosts 11 children with `margin.top = 8` and `width = .fill`:
//! - 8 Knobs: height 72 px each -> `8 * (72 + 8) = 640 px`.
//! - 1 Meter: height 160 px -> `1 * (160 + 8) = 168 px`.
//! - 2 Toggles: height 40 px each -> `2 * (40 + 8) = 96 px`.
//! - Total content span: `content_h = 640 + 168 + 96 = 904 px`.
//!
//! Maximum scroll span is `max_scroll = max(content_h - viewport_h, 0)`:
//! - At 1280 x 720: `viewport_h = 672`, `max_scroll = 904 - 672 = 232 px`.
//! - At 800 x 600: `viewport_h = 552`, `max_scroll = 904 - 552 = 352 px`.
//!
//! ### Scrolled Child Coordinates and Viewport Overlap:
//! Stored child rectangles are stored unscrolled (`rect.y` is layout position).
//! During rendering and hit testing:
//! ```text
//! row.x = rect.x
//! row.y = rect.y - scroll_y
//! ```
//! Viewport overlap condition:
//! ```text
//! overlaps = (row.y < view.y + view.height) and (row.y + row.height > view.y)
//! ```
//! Children with `overlaps == false` are omitted. Straddling rows are drawn with the viewport clip.
//!
//! ### Scrollbar Thumb Geometry & Travel Projection:
//! Let `view_h = viewport.height`, `content_h = 904`.
//! ```text
//! thumb_h = max(24.0, view_h * view_h / content_h)
//! travel  = max(view_h - thumb_h, 0.0)
//! unit    = scroll_y / max_scroll       (in [0.0, 1.0])
//! thumb.y = view.y + unit * travel
//! ```
//! When dragged by pointer:
//! ```text
//! unit = clamp((pointer_y - view.y - thumb_h * 0.5) / travel, 0.0, 1.0)
//! scroll_y = unit * max_scroll
//! ```
//! A press on the thumb jumps to center on pointer; a press on the gutter outside the thumb
//! is ignored.
//!
//! ### Wheel Event Routing:
//! - Over a visible knob ring: nudges that knob by `-dy / 120.0` and consumes the event
//!   without scrolling.
//! - Elsewhere within the viewport: adds `dy` to `scroll_y`, clamped to `[0, max_scroll]`.
//! - Horizontal wheel axis is ignored.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Static Memory Budgets:
//! - `widget_cap = 32`: Root scene capacity.
//! - `scroll_child_cap = 16`: Scroll container child capacity (11 used in demo).
//! - **Instance Budget:** `1 + 1 + scroll_child_cap * 2 <= instance_cap`:
//!   1 (scroll background) + 1 (thumb) + 16 * 2 (max 2 faces per child) = 34 <= 256.
//! - **Glyph Budget:** `scroll_child_cap * 12 <= font.glyph_cap`:
//!   16 * 12 = 192 <= 256.
//!
//! ### Demo Controls Roster & Initial Values:
//! - Knobs (8):
//!   - `gain`:  0.25 (accent purple)
//!   - `slope`: 0.50 (accent green)
//!   - `twice`: 0.75 (accent orange)
//!   - `skew`:  0.00 (accent yellow, value arc omitted at 0)
//!   - `echo`:  1.00 (accent purple)
//!   - `room`:  0.50 (accent green)
//!   - `out`:   0.50 (accent orange)
//!   - `drive`: 0.50 (accent yellow)
//! - Meter (1): `meter` (0.50)
//! - Toggles (2): `take` (true / on), `drums` (false / off)
//!
//! Note: `Panel`, `Button`, and `Slider` remain in `widgets.zig` and are tested, but are not in
//! the demo scene.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Scene vs. Scroll Gesture Arbitration:
//! ```text
//! [pointer_down]
//!       |
//!       v
//! scene.capture = slot_scroll
//!       |
//!       v
//! scroll.press_at(point)
//!       |---> Inside thumb rect?   ==> scroll.press = .thumb (drags scroll_y)
//!       |---> Inside gutter?       ==> scroll.press = .none (ignores)
//!       |---> Inside child?        ==> scroll.press = .child(i) (dispatches to child)
//!       +---> Outside children?    ==> scroll.press = .none
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Platform Wheel Translation:** Wayland sends `wl_pointer.axis` opcode 4 (axis 0), converted
//!   to logical pixels via `input.fixed_to_logical`. In the browser, `web/shell.js` handles `wheel`
//!   with `deltaMode` scaling, calling `wasm.pointer_wheel`. Both feed `input.Event.wheel`.
//!
//! ## 6. TigerStyle Invariants
//! - **Bounded Arrays:** Fixed 32-element widget array. Fixed 16-element scroll child array.
//! - **Zero Runtime Allocation:** Scene and scroll initialization allocate no dynamic heap memory.
//! - **Split Preconditions:** Invariants (`width_logical != 0`, `height_logical != 0`, bounds)
//!   are asserted individually at function boundaries.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const font = @import("font.zig");
const quads = @import("draw.zig");
const input = @import("input.zig");
const turtle = @import("turtle.zig");
const widgets = @import("widgets.zig");

/// Maximum widgets in one scene. The demo stores one scroll.
pub const widget_cap: u32 = 32;

pub const slot_scroll: u32 = 0;
pub const demo_count: u32 = 1;

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

/// One retained widget. The tag selects the behavior; the scene scans the array.
pub const Widget = union(enum) {
    panel: widgets.Panel,
    button: widgets.Button,
    slider: widgets.Slider,
    scroll: widgets.Scroll,
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

    /// One right-aligned scroll. Rects are empty until `layout`.
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
        scene.widgets[slot_scroll] = .{ .scroll = demo_scroll() };
        assert(scene.count == demo_count);
        assert(!scene.pointer.inside);
        return scene;
    }

    /// Places the scroll, then its children, then re-hits the stored pointer.
    pub fn layout(self: *Scene, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
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
            widget_draw(&self.widgets[index], list, glyphs, clip);
        }
        self.dirty = false;
        assert(!self.dirty);
        assert(list.count >= 1);
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
    };
}

fn widget_live(widget: *const Widget) bool {
    assert(widget_id(widget) != 0);
    switch (widget.*) {
        .panel => |*panel| return panel.live(),
        .button => |*button| return button.live(),
        .slider => |*slider| return slider.live(),
        .scroll => |*scroll| return scroll.live(),
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
    }
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
    assert(1 + 1 + widgets.scroll_child_cap * 2 <= quads.instance_cap);
    assert(widgets.scroll_child_cap * 12 <= font.glyph_cap);
    assert(widget_cap <= turtle.child_cap);
    assert(demo_count == 1);
    assert(column_padding.left == 16);
    assert(scroll_padding.left == 8);
    assert(knob_specs.len == 8);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(800, 600);
    const scroll = scroll_of(&scene);
    try expect_rect(scroll.rect, 464, 16, 320, 568);
    try std.testing.expectEqual(@as(f32, 904), scroll.content_h);
    try std.testing.expectEqual(@as(f32, 352), scroll.max_scroll());
}

test "scroll 0 clips the meter and omits the toggles" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 1000);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&scene).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(scene.handle_event(.{ .pointer_move = point }));
    scene.layout(1288, 720);
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&scene).children[0].knob.hover.target);
    try std.testing.expectEqual(slot_scroll, scene.hovered.?);
    try std.testing.expectEqual(@as(u32, 0), scroll_of(&scene).hot.?);
}

test "pointer leave during a knob press releases capture" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
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

//! Retained demo scene: a column of a header, a body panel, a slider, and a button.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In Step 5, the layout engine (`turtle.paint_column`) directly appended instance quads into
//! the draw list. While straightforward, direct geometry emission creates significant architectural
//! limitations:
//! - Geometry is ephemeral: when the window resizes or scale changes, the draw list is wiped,
//!   destroying hover weights, click counters, and slider values.
//! - The turtle only understands geometry: it cannot manage pointer capture, button press
//!   gestures, or multi-stage color palettes.
//!
//! `Scene` introduces a retained UI architecture:
//! - **Retained State:** `Scene` maintains a fixed-capacity array of widgets (`[widget_cap]Widget`).
//! - **Separation of Layout and Drawing:** `Scene.layout()` queries the turtle to calculate
//!   border-box rectangles for each widget's walk. `Scene.draw()` generates GPU instances from
//!   widget state only when `dirty` is set.
//! - **Pointer Capture Semantics:** When a pointer press occurs over a widget, that widget
//!   captures all subsequent motion events (`.drag`), and hover state remains locked to that
//!   widget until release. On pointer release, the scene computes whether the pointer was released
//!   inside the widget (`up.inside`), sends `.up`, releases capture, checks for state changes
//!   (such as advancing the body palette on a button click), and re-dispatches hover for the
//!   current pointer location.
//! - **Pointer Cancellation:** If `pointer_leave` fires while capture is held (e.g. cursor moves
//!   outside the window), the scene sends `.up` with `inside: false` to release the press cleanly
//!   without triggering an activation.
//! - **Passive Occlusion:** The body panel returns `false` from `handle()` (ignoring hits), but
//!   participates in reverse-order hit testing, shielding any widgets underneath it.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All positions and dimensions are expressed in UI logical pixels, top-left origin `(0, 0)`,
//! `+X` right, and `+Y` down.
//!
//! ### Column Layout Budget & Derivations:
//! - Column padding: `column_padding = 16` on all sides (`left, top, right, bottom`).
//! - Inner logical width: `inner_w = width_logical - 32`.
//! - Inner logical height: `inner_h = height_logical - 32`.
//!
//! #### Fixed Main-Axis Heights:
//! 1. Header: `fixed 64`, zero margin. Main-axis cost = `64`.
//! 2. Body Panel: `margin.top = 16`, `height = .fill`. Main-axis margin cost = `16`.
//! 3. Slider: `margin.top = 16`, `fixed 24`. Main-axis cost = `16 + 24 = 40`.
//! 4. Button: `margin.top = 16`, `fixed 48`, `align_x = 1.0` (right-aligned, width `fixed 240`).
//!    Main-axis cost = `16 + 48 = 64`.
//!
//! Total fixed main-axis cost:
//! ```text
//! fixed_sum = 64 + 16 + 40 + 64 = 184
//! ```
//! Share allocated to fill children (`fill_count = 1` for body):
//! ```text
//! body_height = max(inner_h - fixed_sum, 0) / 1
//! ```
//!
//! ### Worked Verification Cases:
//!
//! #### 1. Standard Desktop Size (1280 x 720):
//! - `inner_h = 720 - 32 = 688`
//! - `body_height = 688 - 184 = 504`
//! - Header rect: `(16, 16, 1248, 64)`, corner radius 8.
//! - Body rect: `(16, 96, 1248, 504)`, corner radius 16.
//! - Slider rect: `(16, 616, 1248, 24)`. Track: `(28, 625, 1224, 6)`.
//!   At default `value = 0.5`: Fill `(28, 625, 612, 6)`, Knob disc `(628, 616, 24, 24)`.
//! - Button rect: `(1024, 656, 240, 48)` where `1024 = 16 + (1248 - 240)`, `656 = 616 + 24 + 16`.
//!   Bottom boundary check: `656 + 48 + 16 = 720` (exact pixel match with window height).
//! - Instance count: 1 column background + 1 header + 1 body + 3 slider faces + 1 button = 7 instances.
//!   (At `slider.value == 0`, fill is omitted, yielding 6 instances).
//!
//! #### 2. Compact Size (800 x 600):
//! - `inner_h = 600 - 32 = 568`
//! - `body_height = 568 - 184 = 384`
//! - Header rect: `(16, 16, 768, 64)`
//! - Body rect: `(16, 96, 768, 384)`
//! - Slider rect: `(16, 496, 768, 24)`
//! - Button rect: `(544, 536, 240, 48)` where `544 = 16 + (768 - 240)`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Capacity Constraints:
//! - `widget_cap = 32`: Maximum retained widgets in one scene.
//! - Draw list allocation invariant:
//!   `comptime assert(1 + widget_cap * 3 <= quads.instance_cap)` (1 + 32 * 3 = 97 <= 256).
//!   1 root column instance + up to 3 instances per widget fits entirely in the 256-quad buffer.
//!
//! ### Memory Layout:
//! - `Widget`: Tagged union of `Panel`, `Button`, `Slider`.
//! - `Scene`: Statically allocated record containing:
//!   - `widgets: [widget_cap]Widget`
//!   - `count: u32`
//!   - `pointer: input.Pointer`
//!   - `capture: ?u32` (index of captured widget, or null)
//!   - `hovered: ?u32` (index of hovered widget, or null)
//!   - `dirty: bool` (true when state changed and draw list must be rebuilt)
//!   - `palette_index: u32` (active index in `body_palette`)
//!   - `width_logical, height_logical: u32`
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Pointer Dispatch and Capture Architecture:
//! ```text
//! Event Received:
//!   |
//!   +---> .pointer_move(pt)
//!   |       |
//!   |       +-- capture != null ? --> send(capture, .drag(pt))
//!   |       |
//!   |       +-- capture == null ? --> topmost(pt) -> update hovered
//!   |                                 send .hover_out and .hover_in
//!   |
//!   +---> .pointer_down(pt)
//!   |       topmost(pt) -> capture = hit_index
//!   |       send(capture, .down(pt))
//!   |
//!   +---> .pointer_up(pt)
//!   |       inside = widget_contains(capture, pt)
//!   |       send(capture, .up{inside})
//!   |       capture = null
//!   |       note_clicks() (advance body palette if button clicked)
//!   |       dispatch_hover(pt)
//!   |
//!   +---> .pointer_leave
//!   |       if capture != null: send(capture, .up{inside = false})
//!   |       capture = null
//!   |       clear_hover()
//!   |       pointer.leave()
//!   |
//!   +---> .frame(dt_ms)
//!           step animators on all widgets
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Pointer Preservation Across Relayout:**
//!   When a window resize occurs, `Scene.layout()` updates all widget rectangles, then calls
//!   `redispatch()` using `self.pointer.x` and `self.pointer.y`. If a button moved beneath the
//!   cursor during resize, hover target stays aimed at 1.0.
//! - **Selective Draw Rebuilds:**
//!   `Scene.draw()` is executed only when `scene.dirty` is set. Scale-only window presents leave
//!   `scene.dirty` false, ensuring zero CPU overhead and zero GPU buffer uploads.
//!
//! ## 6. TigerStyle Invariants
//! - **Zero Runtime Allocation:** All widget arrays, geometry slices, and event dispatches are
//!   statically allocated at compile time.
//! - **Bounded Reverse Scans:** Hit testing scans from `count` down to 0, terminating at O(N)
//!   where `N <= widget_cap = 32`.
//! - **Strict Preconditions:** Checked assertions on all array indexes, logical dimensions,
//!   and palette boundaries.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const quads = @import("draw.zig");
const input = @import("input.zig");
const turtle = @import("turtle.zig");
const widgets = @import("widgets.zig");

/// Maximum widgets in one scene. A slider emits up to three instances.
pub const widget_cap: u32 = 32;

/// Body fills the button cycles through. Index 0 is the resting blue-gray.
pub const palette_len: u32 = 3;

pub const slot_header: u32 = 0;
pub const slot_body: u32 = 1;
pub const slot_slider: u32 = 2;
pub const slot_button: u32 = 3;
pub const demo_count: u32 = 4;

const id_header: u32 = 1;
const id_body: u32 = 2;
const id_slider: u32 = 3;
const id_button: u32 = 4;

const zero_margin: turtle.Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
const top_margin: turtle.Inset = .{ .left = 0, .top = 16, .right = 0, .bottom = 0 };
const column_padding: turtle.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };

const column_paint: widgets.Paint = .{
    .r = 0.18,
    .g = 0.19,
    .b = 0.24,
    .a = 1,
    .radius = 0,
};

const header_paint: widgets.Paint = .{
    .r = 0.24,
    .g = 0.32,
    .b = 0.42,
    .a = 1,
    .radius = 8,
};

const button_paint: widgets.Paint = .{
    .r = 0.30,
    .g = 0.46,
    .b = 0.70,
    .a = 1,
    .radius = 24,
};

const track_paint: widgets.Paint = .{
    .r = 0.12,
    .g = 0.13,
    .b = 0.16,
    .a = 1,
    .radius = widgets.track_radius,
};

const fill_paint: widgets.Paint = .{
    .r = 0.30,
    .g = 0.46,
    .b = 0.70,
    .a = 1,
    .radius = widgets.track_radius,
};

const knob_paint: widgets.Paint = .{
    .r = 0.86,
    .g = 0.88,
    .b = 0.92,
    .a = 1,
    .radius = widgets.knob_radius,
};

const body_palette: [palette_len]widgets.Paint = .{
    .{ .r = 0.20, .g = 0.26, .b = 0.34, .a = 1, .radius = 16 },
    .{ .r = 0.42, .g = 0.28, .b = 0.24, .a = 1, .radius = 16 },
    .{ .r = 0.22, .g = 0.36, .b = 0.32, .a = 1, .radius = 16 },
};

/// One retained widget. The tag selects the behavior; the scene scans the array.
pub const Widget = union(enum) {
    panel: widgets.Panel,
    button: widgets.Button,
    slider: widgets.Slider,
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
    palette_index: u32,
    seen_clicks: u32,
    body_slot: u32,
    button_slot: u32,
    width_logical: u32,
    height_logical: u32,

    /// Header, body, slider at 0.5, and a right-aligned button. Rects are empty
    /// until `layout`. The body starts on palette entry 0.
    pub fn init_demo() Scene {
        var scene: Scene = .{
            .widgets = undefined,
            .count = demo_count,
            .pointer = input.Pointer.init(),
            .was_down = false,
            .capture = null,
            .hovered = null,
            .dirty = false,
            .palette_index = 0,
            .seen_clicks = 0,
            .body_slot = slot_body,
            .button_slot = slot_button,
            .width_logical = 0,
            .height_logical = 0,
        };
        scene.widgets[slot_header] = .{ .panel = header_panel() };
        scene.widgets[slot_body] = .{ .panel = body_panel() };
        scene.widgets[slot_slider] = .{ .slider = demo_slider() };
        scene.widgets[slot_button] = .{ .button = demo_button() };
        assert(scene.count == demo_count);
        assert(!scene.pointer.inside);
        return scene;
    }

    /// Places every walk in a padded column of the logical window, then re-hits
    /// the stored pointer so a resize does not leave hover on a widget that moved
    /// away. Sets `dirty` so the next present rebuilds instances.
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
        }
        self.width_logical = width_logical;
        self.height_logical = height_logical;
        self.dirty = true;
        self.redispatch();
        assert(self.dirty);
        assert(self.width_logical == width_logical);
    }

    /// Applies one event. Returns true when widget state changed, and sets
    /// `dirty` in that case. A repeated move inside the same widget returns false.
    pub fn handle_event(self: *Scene, event: input.Event) bool {
        assert(self.count <= widget_cap);
        assert(self.palette_index < palette_len);
        switch (event) {
            .pointer_move => |point| return self.on_move(point),
            .pointer_down => |point| return self.on_down(point),
            .pointer_up => |point| return self.on_up(point),
            .pointer_leave => return self.on_leave(),
            .frame => |dt_ms| return self.on_frame(dt_ms),
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

    /// Clears `list` and appends the column plus every widget face. Clears `dirty`.
    /// Call only when `dirty` is set; a scale-only present skips this and uploads
    /// no instances.
    pub fn draw(self: *Scene, list: *quads.DrawList) void {
        assert(self.width_logical != 0);
        assert(self.height_logical != 0);
        list.clear();
        append_column(list, self.width_logical, self.height_logical);
        var index: u32 = 0;
        while (index < self.count) : (index += 1) {
            widget_draw(&self.widgets[index], list);
        }
        self.dirty = false;
        assert(!self.dirty);
        assert(list.count >= 1);
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
        assert(self.capture == null);
        return self.mark(self.dispatch_hover(point));
    }

    fn on_down(self: *Scene, point: input.Point) bool {
        self.pointer.move(point.x, point.y);
        self.pointer.button(true);
        self.was_down = true;
        var changed = self.dispatch_hover(point);
        if (self.hovered) |index| {
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
        if (self.note_clicks()) {
            changed = true;
        }
        if (self.dispatch_hover(point)) {
            changed = true;
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
        if (self.note_clicks()) {
            changed = true;
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

    fn note_clicks(self: *Scene) bool {
        assert(self.button_slot < self.count);
        assert(self.body_slot < self.count);
        const clicks = self.widgets[self.button_slot].button.clicks;
        if (clicks == self.seen_clicks) {
            assert(clicks == self.seen_clicks);
            return false;
        }
        self.seen_clicks = clicks;
        self.palette_index = clicks % palette_len;
        self.widgets[self.body_slot].panel.paint = body_palette[self.palette_index];
        assert(self.palette_index < palette_len);
        assert(self.seen_clicks == clicks);
        return true;
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
        assert(self.palette_index < palette_len);
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
    };
}

fn widget_live(widget: *const Widget) bool {
    assert(widget_id(widget) != 0);
    switch (widget.*) {
        .panel => |*panel| {
            assert(panel.id != 0);
            return panel.live();
        },
        .button => |*button| {
            assert(button.id != 0);
            return button.live();
        },
        .slider => |*slider| {
            assert(slider.id != 0);
            return slider.live();
        },
    }
}

fn widget_contains(widget: *const Widget, x: f32, y: f32) bool {
    assert(x == x);
    assert(y == y);
    return switch (widget.*) {
        .panel => |*panel| panel.contains(x, y),
        .button => |*button| button.contains(x, y),
        .slider => |*slider| slider.contains(x, y),
    };
}

fn widget_draw(widget: *const Widget, list: *quads.DrawList) void {
    assert(list.count <= quads.instance_cap);
    switch (widget.*) {
        .panel => |*panel| panel.draw(list),
        .button => |*button| button.draw(list),
        .slider => |*slider| slider.draw(list),
    }
    assert(list.count <= quads.instance_cap);
}

fn widget_walk(widget: *const Widget) turtle.Walk {
    switch (widget.*) {
        .panel => |*panel| {
            assert(panel.walk.align_x >= 0);
            assert(panel.walk.align_x <= 1);
            return panel.walk;
        },
        .button => |*button| {
            assert(button.walk.align_x >= 0);
            assert(button.walk.align_x <= 1);
            return button.walk;
        },
        .slider => |*slider| {
            assert(slider.walk.align_x >= 0);
            assert(slider.walk.align_x <= 1);
            return slider.walk;
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
    }
}

fn widget_id(widget: *const Widget) u32 {
    switch (widget.*) {
        .panel => |*panel| {
            assert(panel.paint.a == 1);
            return panel.id;
        },
        .button => |*button| {
            assert(button.paint.a == 1);
            return button.id;
        },
        .slider => |*slider| {
            assert(slider.value >= 0);
            return slider.id;
        },
    }
}

fn append_column(list: *quads.DrawList, width: u32, height: u32) void {
    assert(width != 0);
    assert(height != 0);
    list.append(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .r = column_paint.r,
        .g = column_paint.g,
        .b = column_paint.b,
        .a = column_paint.a,
        .radius = column_paint.radius,
        .hover = 0,
        .down = 0,
        .pad1 = 0,
    }) catch unreachable;
    assert(list.count >= 1);
    assert(list.items[0].radius == 0);
}

fn header_panel() widgets.Panel {
    const panel: widgets.Panel = .{
        .id = id_header,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .walk = .{
            .margin = zero_margin,
            .width = .fill,
            .height = .{ .fixed = 64 },
            .align_x = 0,
        },
        .paint = header_paint,
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .down = animator.Animator.init(widgets.down_rate_per_ms),
    };
    assert(panel.id == id_header);
    assert(panel.walk.height.fixed == 64);
    return panel;
}

fn body_panel() widgets.Panel {
    const panel: widgets.Panel = .{
        .id = id_body,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .walk = .{
            .margin = top_margin,
            .width = .fill,
            .height = .fill,
            .align_x = 0,
        },
        .paint = body_palette[0],
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .down = animator.Animator.init(widgets.down_rate_per_ms),
    };
    assert(panel.id == id_body);
    assert(panel.walk.height == .fill);
    return panel;
}

fn demo_slider() widgets.Slider {
    const slider: widgets.Slider = .{
        .id = id_slider,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .walk = .{
            .margin = top_margin,
            .width = .fill,
            .height = .{ .fixed = 24 },
            .align_x = 0,
        },
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .value = 0.5,
        .track = track_paint,
        .fill = fill_paint,
        .knob = knob_paint,
    };
    assert(slider.value == 0.5);
    assert(slider.walk.height.fixed == 24);
    return slider;
}

fn demo_button() widgets.Button {
    const button: widgets.Button = .{
        .id = id_button,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .walk = .{
            .margin = top_margin,
            .width = .{ .fixed = 240 },
            .height = .{ .fixed = 48 },
            .align_x = 1,
        },
        .paint = button_paint,
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .down = animator.Animator.init(widgets.down_rate_per_ms),
        .clicks = 0,
    };
    assert(button.clicks == 0);
    assert(button.walk.align_x == 1);
    return button;
}

comptime {
    assert(widget_cap == 32);
    assert(1 + widget_cap * 3 <= quads.instance_cap);
    assert(widget_cap <= turtle.child_cap);
    assert(demo_count == 4);
    assert(palette_len == 3);
    assert(column_padding.left == 16);
    assert(header_paint.radius == 8);
    assert(button_paint.radius == 24);
    assert(body_palette[0].radius == 16);
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

// 1280 by 720 places the four widgets and emits seven faces at slider value 0.5.
test "demo layout at 1280 by 720" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    const header = scene.widgets[slot_header].panel.rect;
    const body = scene.widgets[slot_body].panel.rect;
    const slider = scene.widgets[slot_slider].slider.rect;
    const button = scene.widgets[slot_button].button.rect;
    try expect_rect(header, 16, 16, 1248, 64);
    try expect_rect(body, 16, 96, 1248, 504);
    try expect_rect(slider, 16, 616, 1248, 24);
    try expect_rect(button, 1024, 656, 240, 48);
    try std.testing.expectEqual(@as(f32, 720), button.y + button.height + column_padding.bottom);
    var list = quads.DrawList.init();
    scene.draw(&list);
    try std.testing.expectEqual(@as(u32, 7), list.count);
    try expect_box(list.items[0], 0, 0, 1280, 720);
    try expect_box(list.items[1], 16, 16, 1248, 64);
    try expect_box(list.items[2], 16, 96, 1248, 504);
    try expect_box(list.items[3], 28, 625, 1224, 6);
    try expect_box(list.items[4], 28, 625, 612, 6);
    try expect_box(list.items[5], 628, 616, 24, 24);
    try expect_box(list.items[6], 1024, 656, 240, 48);
    try std.testing.expectEqual(@as(f32, 8), list.items[1].radius);
    try std.testing.expectEqual(@as(f32, 16), list.items[2].radius);
    try std.testing.expectEqual(@as(f32, 3), list.items[3].radius);
    try std.testing.expectEqual(@as(f32, 12), list.items[5].radius);
    try std.testing.expectEqual(@as(f32, 24), list.items[6].radius);
    try std.testing.expect(!scene.dirty);
}

// 800 by 600 shrinks the body and parks the button on the right.
test "demo layout at 800 by 600" {
    var scene = Scene.init_demo();
    scene.layout(800, 600);
    try expect_rect(scene.widgets[slot_header].panel.rect, 16, 16, 768, 64);
    try expect_rect(scene.widgets[slot_body].panel.rect, 16, 96, 768, 384);
    try expect_rect(scene.widgets[slot_slider].slider.rect, 16, 496, 768, 24);
    try expect_rect(scene.widgets[slot_button].button.rect, 544, 536, 240, 48);
}

// Widening the window moves the right-aligned button, and the stored pointer
// still lands on it, so hover stays aimed at 1.
test "relayout keeps hover on the moved button" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 1144, .y = 680 } }));
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_button].button.hover.target);
    scene.layout(1360, 720);
    try expect_rect(scene.widgets[slot_button].button.rect, 1104, 656, 240, 48);
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_button].button.hover.target);
    try std.testing.expectEqual(slot_button, scene.hovered.?);
}

// Hover eases to 1. After the present that shows the settled value, a further
// frame changes nothing and leaves the scene clean.
test "hover eases and then rests" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 1144, .y = 680 } }));
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_button].button.hover.target);
    try std.testing.expect(scene.live());
    try std.testing.expect(scene.dirty);
    try std.testing.expect(scene.handle_event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        scene.widgets[slot_button].button.hover.value,
        0.0001,
    );
    try std.testing.expect(scene.dirty);
    try std.testing.expect(scene.handle_event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_button].button.hover.value);
    try std.testing.expect(!scene.live());
    var list = quads.DrawList.init();
    scene.draw(&list);
    try std.testing.expect(!scene.dirty);
    try std.testing.expectEqual(widgets.hover_lighten, list.items[6].hover);
    try std.testing.expect(!scene.handle_event(.{ .frame = 16 }));
    try std.testing.expect(!scene.dirty);
    try std.testing.expect(!scene.handle_event(.{ .pointer_move = .{ .x = 1200, .y = 680 } }));
}

// A press and release on the button counts one click and advances the body palette.
test "a click cycles the body palette" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = 1144, .y = 680 } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_up = .{ .x = 1144, .y = 680 } }));
    try std.testing.expectEqual(@as(u32, 1), scene.widgets[slot_button].button.clicks);
    try std.testing.expectEqual(@as(u32, 1), scene.palette_index);
    try std.testing.expectEqual(body_palette[1].r, scene.widgets[slot_body].panel.paint.r);
}

// Dragging off the button before release is not a click, and hover follows the pointer.
test "a drag off the button does not click" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = 1144, .y = 680 } }));
    // The drag is captured by the button and does not change its value. Hover
    // stays locked until release, so this move is not a state change.
    try std.testing.expect(!scene.handle_event(.{ .pointer_move = .{ .x = 640, .y = 368 } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_up = .{ .x = 640, .y = 368 } }));
    try std.testing.expectEqual(@as(u32, 0), scene.widgets[slot_button].button.clicks);
    try std.testing.expectEqual(@as(f32, 0), scene.widgets[slot_button].button.down.target);
    try std.testing.expectEqual(@as(f32, 0), scene.widgets[slot_button].button.hover.target);
    try std.testing.expect(scene.hovered.? != slot_button);
    try std.testing.expect(scene.capture == null);
}

// Leaving the surface during a press delivers an outside release and drops capture.
test "pointer leave during a press releases outside" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = 1144, .y = 680 } }));
    try std.testing.expect(scene.handle_event(.pointer_leave));
    try std.testing.expectEqual(@as(u32, 0), scene.widgets[slot_button].button.clicks);
    try std.testing.expectEqual(@as(f32, 0), scene.widgets[slot_button].button.down.target);
    try std.testing.expect(scene.capture == null);
    try std.testing.expect(!scene.pointer.inside);
    try std.testing.expect(!scene.pointer.down);
}

// The slider maps pointer x onto value. A held slider keeps the hover highlight
// and writes no darken. Zero omits the fill face.
test "slider drag sets an absolute value" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 1144, .y = 680 } }));
    try std.testing.expect(scene.handle_event(.{ .pointer_down = .{ .x = 640, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 0), scene.widgets[slot_button].button.hover.target);
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_slider].slider.hover.target);
    try std.testing.expectEqual(@as(f32, 0.5), scene.widgets[slot_slider].slider.value);
    try std.testing.expect(scene.handle_event(.{ .frame = widgets.hover_duration_ms }));
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_slider].slider.hover.value);
    var held = quads.DrawList.init();
    scene.draw(&held);
    // Column, header, body, then track, fill, and knob. Value is still 0.5.
    try std.testing.expectEqual(@as(u32, 7), held.count);
    var face: u32 = 3;
    while (face < 6) : (face += 1) {
        try std.testing.expectEqual(widgets.hover_lighten, held.items[face].hover);
        try std.testing.expectEqual(@as(f32, 0), held.items[face].down);
    }
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 28, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 0), scene.widgets[slot_slider].slider.value);
    var list = quads.DrawList.init();
    scene.draw(&list);
    try std.testing.expectEqual(@as(u32, 6), list.count);
    try std.testing.expect(scene.handle_event(.{ .pointer_move = .{ .x = 2000, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 1), scene.widgets[slot_slider].slider.value);
}

// After a rebuild, an unchanged logical size uploads nothing.
test "a settled scene does not rebuild on a scale-style present" {
    var scene = Scene.init_demo();
    scene.layout(1280, 720);
    var list = quads.DrawList.init();
    scene.draw(&list);
    const revision = list.revision;
    var cursor = quads.UploadCursor.init();
    cursor.mark(&list, 1280, 720);
    try std.testing.expect(!scene.dirty);
    try std.testing.expectEqual(@as(u32, 0), cursor.flags(&list, 1280, 720));
    try std.testing.expectEqual(revision, list.revision);
}

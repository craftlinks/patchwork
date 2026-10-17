//! Retained UI widgets: panels, buttons, sliders, knobs, meters, toggles, and scroll containers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In an instanced GPU user interface, there is a fundamental tension between retained widget
//! state (interaction models, animators, value tracking, scroll offsets) and immediate-style
//! GPU submission (draw lists and glyph lists wiped and rebuilt on dirty frames).
//!
//! ### Retained Widgets vs. Ephemeral Draw Lists:
//! All interactive and visual state lives permanently in retained widget structures:
//! - Each widget owns its border-box `Rect` and layout `Walk`.
//! - Active controls own continuous `Animator` instances (such as hover and thumb transitions).
//! - Continuous controls retain their normalized scalar `value: f32` in `[0.0, 1.0]`.
//! - On redraw, `draw()` copies current animated weights and shapes into fresh 64-byte GPU
//!   `Instance` records and `Glyph` records.
//! - Shaders remain completely decoupled: they receive standard 64-byte records and know nothing
//!   about widget types or interaction trees.
//!
//! ### Widget Suite Taxonomy:
//! - **Panel:** Passive container. Hit-tested to occlude underlying elements, but ignores hits.
//! - **Button:** Clickable trigger. Animates hover (100 ms) and down (50 ms). Tracks click counts.
//! - **Slider:** Continuous horizontal bar. Maps absolute pointer X to `[0.0, 1.0]`.
//!   *(Note: `Panel`, `Button`, and `Slider` remain fully implemented and tested in this module,
//!   though Step 8 features an audio channel strip demo built with the widgets below).*
//! - **Knob:** Continuous rotary control. Open-ring arc with relative vertical drag and mouse
//!   wheel adjustments. Displays name and formatted numeric hundredths value string.
//! - **Meter:** Passive vertical level indicator. Upward-growing fill column; ignores hits.
//! - **Toggle:** Binary state capsule switch. Animated thumb travel over 100 ms on release inside.
//! - **Scroll:** Viewport container managing a scrollable column of controls with a
//!   draggable thumb, viewport culling, wheel routing, and per-child scissor-free clipping.
//!
//! ### Scaled Shader Blend Weights:
//! An `Animator` travels across `[0.0, 1.0]`. If written directly to the GPU instance,
//! a hover weight of 1.0 would mix the fill color 100% to pure white, and down 1.0
//! would mix 100% to solid black. Instead, widgets scale normalized animator values:
//! - `hover_weight = animator.value * hover_lighten` (`0.18`).
//! - `down_weight = animator.value * down_darken` (`0.30`, applied after hover).
//! - For `Knob`, `hover` lightens the active value arc only; the track remains dark.
//! - For `Toggle`, `hover` lightens the thumb disc; the track remains dark.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! Geometries are defined in UI logical pixels, top-left origin `(0, 0)`, `+X` right, `+Y` down.
//!
//! ### Knob Analytical Ring & Relative Drag Derivation:
//! A knob occupies a row bounding box of height 72 px. Within this row:
//! - The ring bounds `ring_of(row)` is a square `(row.x + 8, row.y + 8, 56, 56)`.
//! - Ring center: `(ring.x + 28, ring.y + 28)`.
//! - Track thickness: `ring_thickness = 4.0`.
//! - Two `kind_arc` (kind = 1) faces are emitted:
//!   1. **Track Arc:** Backing ring with fill `theme.chrome.track`, hover 0, down 1 (full sweep).
//!   2. **Value Arc:** Active ring segment with fill `knob.accent`, hover weight,
//!      down = `knob.value`.
//!      If `knob.value == 0`, the value arc instance is completely omitted.
//! - **Hit Test:** Tested against the full 28 px radius bounding disc (`ring_contains`), so
//!   clicking inside the inner hole still grabs and drags the knob.
//! - **Relative Vertical Drag:**
//!   `dy = point.y - knob.drag_y`
//!   `value = clamp(value - dy / 120.0, 0.0, 1.0)`
//!   Dragging upward (`-dy`) increases the value; downward decreases it. Drag span is 120 px.
//! - **Wheel Nudge:** Wheel delta `wheel.dy` nudges the knob by `-wheel.dy / 120.0`.
//! - **Text Labels:** Label names are static string slices. Values are formatted into an `[8]u8`
//!   scratch buffer as four-character hundredths strings (`0.00` to `1.00`) with zero allocation.
//!
//! ### Meter Analytical Vertical Fill:
//! A meter occupies a row bounding box of height 160 px:
//! - Track rectangle `meter_track(row)`: width 12 px, height 144 px, corner radius 6 px.
//! - Fill rectangle: grows upward from the bottom of the track:
//!   `fill.height = value * 144.0`
//!   `fill.y = track.y + 144.0 - fill.height`
//!   If `value == 0`, the fill instance is omitted.
//!
//! ### Toggle Analytical Capsule & Thumb:
//! A toggle occupies a row bounding box of height 40 px:
//! - Pill rectangle `pill_of(row)`: width 44 px, height 24 px, corner radius 12 px (capsule).
//! - Thumb disc: diameter 20 px (width 20, height 20, radius 10), inset by 2 px.
//! - Thumb horizontal travel:
//!   `travel = pill.width - thumb_side - 2 * thumb_inset = 44 - 20 - 4 = 20 px`.
//! - Thumb position: `thumb.x = pill.x + thumb_inset + thumb_animator.value * travel`.
//! - Thumb Y position: `thumb.y = pill.y + thumb_inset`.
//! - Release gesture: Releasing inside the pill (`up.inside == true`) flips `toggle.on` and
//!   aims the thumb animator toward 1 (on) or 0 (off) over 100 ms. Releasing outside does not flip.
//!
//! ### Scroll Viewport, Content, and Gutter Geometry:
//! A `Scroll` widget occupies `scroll.rect` with padding (8 px all sides):
//! - `viewport = inset(scroll.rect, padding)`.
//! - `content_column = (viewport.x, viewport.y, viewport.width - 16, viewport.height)`
//!   (16 px gutter).
//! - Children are laid out in the content column. Stored child rectangles are unscrolled.
//! - **Scrolled Coordinates:** `row.y = child.rect.y - scroll_y`.
//! - **Viewport Culling:** If `!overlaps(row, viewport)`, child faces and glyphs are omitted.
//! - **Straddler Masking:** Children overlapping viewport boundaries carry
//!   `clip = clip_of(viewport)`.
//! - **Scrollbar Thumb:**
//!   `thumb_h = max(24.0, viewport_h * viewport_h / content_h)`.
//!   `travel = viewport_h - thumb_h`.
//!   `thumb.y = viewport.y + (scroll_y / max_scroll) * travel`.
//!   When dragged: `unit = clamp((pointer_y - view.y - thumb_h * 0.5) / travel, 0.0, 1.0)`.
//!   `scroll_y = unit * max_scroll`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### GPU Instance Emission (64 Bytes per Record):
//! Each quad appended to `DrawList` occupies 64 bytes matching WebGPU Vertex Buffer 1 stride:
//! - Location 1 (Offset  0): `(x, y, width, height)` (4x f32)
//! - Location 2 (Offset 16): `(r, g, b, a)` (4x f32)
//! - Location 3 (Offset 32): `(radius, hover, down, kind)` (4x f32)
//!   `kind` is `kind_box` (0.0) or `kind_arc` (1.0).
//! - Location 4 (Offset 48): `(clip_x0, clip_y0, clip_x1, clip_y1)` (4x f32)
//!   Exclusive-max clip boundary in logical screen pixels.
//!
//! ### Static Memory Budgets:
//! - `scroll_child_cap = 16`.
//! - `DrawList.items: [256]Instance` (256 * 64 = 16,384 bytes).
//! - `GlyphList.items: [256]Glyph` (256 * 64 = 16,384 bytes).
//! - Instance budget: `1 (panel) + 1 (thumb) + scroll_child_cap * 2 <= instance_cap` (34 <= 256).
//! - Glyph budget: `scroll_child_cap * 12 <= font.glyph_cap` (192 <= 256).
//!
//! ### Knob Accent Palette (Demo Choice):
//! Knob active arcs do not read theme slots; they use per-instance fills.
//! The demo cycles four accents by knob index:
//! - Purple: `(0.62, 0.45, 0.86, 1.0)`
//! - Green:  `(0.40, 0.78, 0.48, 1.0)`
//! - Orange: `(0.93, 0.55, 0.24, 1.0)`
//! - Yellow: `(0.93, 0.80, 0.32, 1.0)`
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Scroll Event Delegation:
//! - `.hover_in` / `.hover_out`: Manages hot child tracking.
//! - `.down`: Hits thumb rect -> grabs thumb; hits child -> records active child;
//!   hits gutter -> ignores.
//! - `.drag`: Drags thumb or forwards to active child.
//! - `.wheel`: Over visible knob ring -> nudges knob; elsewhere in viewport -> scrolls viewport Y.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - Pointer coordinates and wheel deltas are normalized to UI logical pixels
//!   before entering widgets.
//! - Wayland 24.8 fixed point is scaled by 1/256; browser CSS pixels are scaled
//!   by `devicePixelRatio`.
//!
//! ## 6. TigerStyle Invariants
//! - Zero runtime allocation: all structures, buffers, and text arrays are statically bounded.
//! - Pure geometric calculations separated from mutating dispatchers.
//! - Defensive assertion pairs on all function entries and exits.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const font = @import("font.zig");
const quads = @import("draw.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");
const turtle = @import("turtle.zig");

/// Shader mix toward white at animator value 1. Matches the step 5 weight.
pub const hover_lighten: f32 = 0.18;

/// Shader mix toward black at animator value 1. Applied after the lighten.
pub const down_darken: f32 = 0.30;

/// Wall time for hover to travel the unit range. Makepad's button hover is 0.1 s.
pub const hover_duration_ms: f32 = 100;

/// Wall time for the press darken to travel the unit range.
pub const down_duration_ms: f32 = 50;

/// Fraction of the unit range covered in one millisecond of hover.
pub const hover_rate_per_ms: f32 = 1.0 / hover_duration_ms;

/// Fraction of the unit range covered in one millisecond of press.
pub const down_rate_per_ms: f32 = 1.0 / down_duration_ms;

/// Slider knob radius in logical pixels. The demo slider is 24 px tall, so the
/// knob is a disc that fills that height.
pub const knob_radius: f32 = 12;

/// Slider track thickness in logical pixels, centered in the widget rect.
pub const track_height: f32 = 6;

/// Track corner radius. Half the thickness, so the track is a capsule.
pub const track_radius: f32 = 3;

/// A point in UI logical pixels. Same type the event queue carries.
pub const Point = input.Point;

/// Release sample. `inside` is true when the pointer is still on that widget.
pub const Up = struct {
    x: f32,
    y: f32,
    inside: bool,
};

/// A hit the scene resolved for one widget. The widget does not scan siblings.
pub const Hit = union(enum) {
    hover_in,
    hover_out,
    down: Point,
    drag: Point,
    up: Up,
    move: Point,
    wheel: input.Wheel,
};

/// Fill and corner radius copied onto each instance this widget appends.
pub const Paint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
};

/// Text drawn into a padding box. Empty `text` appends no glyphs. The label
/// does not hit-test, animate, or append a face quad. `text` points at a literal.
pub const Label = struct {
    text: []const u8,
    rect: turtle.Rect,
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    /// Places one coverage quad per ink glyph inside `rect`. Every quad copies `clip`.
    pub fn draw(self: Label, glyphs: *font.GlyphList, clip: font.Clip) void {
        assert(self.text.len <= font.text_cap);
        assert(self.a >= 0);
        assert(clip.x1 > clip.x0);
        font.place(glyphs, self.text, .{
            .x = self.rect.x,
            .y = self.rect.y,
            .width = self.rect.width,
            .height = self.rect.height,
        }, .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = self.a,
        }, clip);
    }
};

/// Writes the border box inset by `padding` onto `label.rect`.
pub fn place_label(label: *Label, border: turtle.Rect, padding: turtle.Inset) void {
    assert(padding.left >= 0);
    assert(padding.top >= 0);
    assert(padding.right >= 0);
    assert(padding.bottom >= 0);
    label.rect = .{
        .x = border.x + padding.left,
        .y = border.y + padding.top,
        .width = border.width - padding.left - padding.right,
        .height = border.height - padding.top - padding.bottom,
    };
    assert(label.rect.x == border.x + padding.left);
    assert(label.text.len <= font.text_cap);
}

/// Passive rounded rectangle. Hit-tested so it occludes, and then ignored.
pub const Panel = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    padding: turtle.Inset,
    label: Label,
    paint: Paint,
    hover: animator.Animator,
    down: animator.Animator,

    /// Ignores the hit. The scene still records this panel as the hovered widget
    /// so a control underneath does not receive the pointer.
    pub fn handle(self: *Panel, hit: Hit) bool {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        switch (hit) {
            .hover_in => return false,
            .hover_out => return false,
            .down => return false,
            .drag => return false,
            .up => return false,
            .move => return false,
            .wheel => return false,
        }
    }

    pub fn animate(self: *Panel, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.id != 0);
        return step_pair(&self.hover, &self.down, dt_ms);
    }

    pub fn live(self: Panel) bool {
        assert(self.id != 0);
        assert(self.paint.a >= 0);
        return pair_live(self.hover, self.down);
    }

    pub fn contains(self: Panel, x: f32, y: f32) bool {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        return face_contains(self.rect, self.paint.radius, x, y);
    }

    pub fn draw(self: Panel, list: *quads.DrawList, glyphs: *font.GlyphList, clip: font.Clip) void {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        append_weighted(list, self.rect, self.paint, self.hover, self.down, clip);
        self.label.draw(glyphs, clip);
    }
};

/// Clickable face. `clicks` increments on `up` while `inside` is true.
pub const Button = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    padding: turtle.Inset,
    label: Label,
    paint: Paint,
    hover: animator.Animator,
    down: animator.Animator,
    clicks: u32,

    pub fn handle(self: *Button, hit: Hit) bool {
        assert(self.id != 0);
        assert(self.clicks < std.math.maxInt(u32));
        switch (hit) {
            .hover_in => return self.hover.set_target(1),
            .hover_out => return self.hover.set_target(0),
            .down => return self.down.set_target(1),
            .drag => return false,
            .move => return false,
            .wheel => return false,
            .up => |up| {
                const released = self.down.set_target(0);
                if (!up.inside) {
                    assert(!up.inside);
                    return released;
                }
                self.clicks += 1;
                assert(self.clicks >= 1);
                return true;
            },
        }
    }

    pub fn animate(self: *Button, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.id != 0);
        return step_pair(&self.hover, &self.down, dt_ms);
    }

    pub fn live(self: Button) bool {
        assert(self.id != 0);
        assert(self.clicks == self.clicks);
        return pair_live(self.hover, self.down);
    }

    pub fn contains(self: Button, x: f32, y: f32) bool {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        return face_contains(self.rect, self.paint.radius, x, y);
    }

    pub fn draw(
        self: Button,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        clip: font.Clip,
    ) void {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        append_weighted(list, self.rect, self.paint, self.hover, self.down, clip);
        self.label.draw(glyphs, clip);
    }
};

/// Absolute slider. Press and drag both set `value` from the pointer x.
/// The hover animator is the highlight for the whole gesture. There is no
/// press-darken channel: a held slider stays lightened, including while the
/// pointer is captured outside the track.
pub const Slider = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    hover: animator.Animator,
    value: f32,
    track: Paint,
    fill: Paint,
    knob: Paint,

    pub fn handle(self: *Slider, hit: Hit) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        switch (hit) {
            .hover_in => return self.hover.set_target(1),
            .hover_out => return self.hover.set_target(0),
            .down => |point| return self.set_value_at(point.x),
            .drag => |point| return self.set_value_at(point.x),
            .move => return false,
            .wheel => return false,
            .up => |up| {
                assert(up.x == up.x);
                assert(up.y == up.y);
                return false;
            },
        }
    }

    pub fn animate(self: *Slider, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.value >= 0);
        assert(self.hover.rate_per_ms > 0);
        return self.hover.step(dt_ms);
    }

    pub fn live(self: Slider) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        return self.hover.live();
    }

    /// The hit face is the widget rect, rounded by the knob radius, so the disc
    /// at either end is part of the control.
    pub fn contains(self: Slider, x: f32, y: f32) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        return face_contains(self.rect, knob_radius, x, y);
    }

    /// Track, then fill (omitted at value 0), then the knob on top.
    pub fn draw(self: Slider, list: *quads.DrawList, clip: font.Clip) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        if (self.rect.width <= 0) {
            assert(self.rect.width <= 0);
            return;
        }
        if (self.rect.height <= 0) {
            assert(self.rect.height <= 0);
            return;
        }
        const track = track_rect(self.rect);
        // The rate is unused. This animator is never stepped. Value and target
        // stay 0 so the shader's darken mix does not run on a held slider.
        const rest = animator.Animator.init(down_rate_per_ms);
        assert(rest.value == 0);
        assert(rest.target == 0);
        append_weighted(list, track, self.track, self.hover, rest, clip);
        if (self.value > 0) {
            var fill_rect = track;
            fill_rect.width = self.value * track.width;
            append_weighted(list, fill_rect, self.fill, self.hover, rest, clip);
        }
        const knob = knob_rect(self.rect, self.value);
        append_weighted(list, knob, self.knob, self.hover, rest, clip);
        assert(list.count <= quads.instance_cap);
    }

    fn set_value_at(self: *Slider, x: f32) bool {
        const next = value_at(self.rect, x);
        assert(next >= 0);
        assert(next <= 1);
        if (self.value == next) {
            assert(self.value == next);
            return false;
        }
        self.value = next;
        assert(self.value == next);
        return true;
    }
};

/// Unit position of `x` along the knob travel, clamped to `[0, 1]`.
/// Travel is `width - 2 * knob_radius`. A non-positive travel returns 0.
pub fn value_at(rect: turtle.Rect, x: f32) f32 {
    assert(x == x);
    const span = rect.width - 2.0 * knob_radius;
    if (span <= 0) {
        assert(span <= 0);
        return 0;
    }
    var unit = (x - rect.x - knob_radius) / span;
    if (unit < 0) {
        unit = 0;
    }
    if (unit > 1) {
        unit = 1;
    }
    assert(unit >= 0);
    assert(unit <= 1);
    return unit;
}

/// Track centered vertically in `rect`, inset by the knob radius on x.
pub fn track_rect(rect: turtle.Rect) turtle.Rect {
    assert(rect.height == rect.height);
    const track: turtle.Rect = .{
        .x = rect.x + knob_radius,
        .y = rect.y + (rect.height - track_height) * 0.5,
        .width = rect.width - 2.0 * knob_radius,
        .height = track_height,
    };
    assert(track.height == track_height);
    assert(track.x == rect.x + knob_radius);
    return track;
}

/// Knob disc. Side is `2 * knob_radius`. `value` 0 sits on the left edge.
pub fn knob_rect(rect: turtle.Rect, value: f32) turtle.Rect {
    assert(value >= 0);
    assert(value <= 1);
    const side = 2.0 * knob_radius;
    const travel = positive_span(rect.width - side);
    const knob: turtle.Rect = .{
        .x = rect.x + value * travel,
        .y = rect.y + (rect.height - side) * 0.5,
        .width = side,
        .height = side,
    };
    assert(knob.width == side);
    assert(knob.height == side);
    return knob;
}

fn step_pair(
    hover: *animator.Animator,
    down: *animator.Animator,
    dt_ms: f32,
) bool {
    assert(dt_ms >= 0);
    assert(hover.rate_per_ms > 0);
    const hover_moved = hover.step(dt_ms);
    const down_moved = down.step(dt_ms);
    if (hover_moved) {
        return true;
    }
    return down_moved;
}

fn pair_live(hover: animator.Animator, down: animator.Animator) bool {
    if (hover.live()) {
        assert(hover.live());
        return true;
    }
    if (down.live()) {
        assert(down.live());
        return true;
    }
    assert(!hover.live());
    assert(!down.live());
    return false;
}

fn face_contains(rect: turtle.Rect, radius: f32, x: f32, y: f32) bool {
    assert(radius >= 0);
    if (rect.width <= 0) {
        assert(rect.width <= 0);
        return false;
    }
    if (rect.height <= 0) {
        assert(rect.height <= 0);
        return false;
    }
    assert(rect.width > 0);
    assert(rect.height > 0);
    return quads.contains_box(rect.x, rect.y, rect.width, rect.height, radius, x, y);
}

fn append_weighted(
    list: *quads.DrawList,
    rect: turtle.Rect,
    paint: Paint,
    hover: animator.Animator,
    down: animator.Animator,
    clip: font.Clip,
) void {
    assert(paint.radius >= 0);
    assert(list.count <= quads.instance_cap);
    if (rect.width <= 0) {
        assert(rect.width <= 0);
        return;
    }
    if (rect.height <= 0) {
        assert(rect.height <= 0);
        return;
    }
    const hover_weight = mix_weight(hover.value, hover_lighten);
    const down_weight = mix_weight(down.value, down_darken);
    list.append(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .r = paint.r,
        .g = paint.g,
        .b = paint.b,
        .a = paint.a,
        .radius = paint.radius,
        .hover = hover_weight,
        .down = down_weight,
        .kind = quads.kind_box,
        .clip_x0 = clip.x0,
        .clip_y0 = clip.y0,
        .clip_x1 = clip.x1,
        .clip_y1 = clip.y1,
    }) catch unreachable;
    assert(list.count >= 1);
    assert(list.count <= quads.instance_cap);
}

fn mix_weight(amount: f32, scale: f32) f32 {
    assert(amount >= 0);
    assert(amount <= 1);
    const weight = amount * scale;
    assert(weight >= 0);
    assert(weight <= scale);
    return weight;
}

fn positive_span(span: f32) f32 {
    assert(span == span);
    if (span > 0) {
        assert(span > 0);
        return span;
    }
    assert(span <= 0);
    return 0;
}

/// Children one scroll may own. The demo uses 11.
pub const scroll_child_cap: u32 = 16;

/// Gutter reserved for the thumb, in logical pixels.
pub const gutter_px: f32 = 16;

/// Drag and wheel travel that covers the unit range.
pub const drag_span_px: f32 = 120;

/// Knob ring edge. The hit disc uses half of this so the hole still drags.
pub const ring_size: f32 = 56;

/// Ring stroke. Stored in the arc instance's `radius`.
pub const ring_thickness: f32 = 4;

/// Inset of the ring and the pill from the row's left edge.
pub const ring_inset: f32 = 8;

pub const knob_height: f32 = 72;
pub const meter_height: f32 = 160;
pub const toggle_height: f32 = 40;
pub const meter_track_w: f32 = 12;
pub const meter_track_h: f32 = 144;
pub const meter_radius: f32 = 6;
pub const pill_w: f32 = 44;
pub const pill_h: f32 = 24;
pub const pill_radius: f32 = 12;
pub const thumb_side: f32 = 20;
pub const thumb_inset: f32 = 2;
pub const thumb_min_px: f32 = 24;
pub const label_line_px: f32 = 36;
pub const accent_count: u32 = 4;

/// Purple, green, orange, yellow. Cycled by knob index. Not theme slots.
pub const accents: [accent_count]Paint = .{
    .{ .r = 0.62, .g = 0.45, .b = 0.86, .a = 1, .radius = ring_thickness },
    .{ .r = 0.40, .g = 0.78, .b = 0.48, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.55, .b = 0.24, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.80, .b = 0.32, .a = 1, .radius = ring_thickness },
};

/// What the scroll grabbed. The scene capture stays the scroll's own slot.
pub const Press = union(enum) {
    none,
    child: u32,
    thumb,
};

pub const Control = union(enum) {
    knob: Knob,
    meter: Meter,
    toggle: Toggle,
};

/// Open ring. Drag is relative: up increases `value`. Value 0 omits the value arc.
pub const Knob = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    name: []const u8,
    value_text: [8]u8,
    value: f32,
    accent: Paint,
    hover: animator.Animator,
    drag_y: f32,

    pub fn handle(self: *Knob, hit: Hit) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        switch (hit) {
            .hover_in => return self.hover.set_target(1),
            .hover_out => return self.hover.set_target(0),
            .down => |point| {
                self.drag_y = point.y;
                return self.hover.set_target(1);
            },
            .drag => |point| return self.drag_by(point.y),
            .up => return false,
            .move => return false,
            .wheel => |wheel| return self.nudge(-wheel.dy / drag_span_px),
        }
    }

    pub fn animate(self: *Knob, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.hover.rate_per_ms > 0);
        return self.hover.step(dt_ms);
    }

    pub fn live(self: Knob) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        return self.hover.live();
    }

    pub fn draw(
        self: Knob,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        row: turtle.Rect,
        clip: font.Clip,
    ) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const ring = ring_of(row);
        const track = paint_of(theme.chrome.track, ring_thickness);
        append_arc(list, ring, track, 0, 1, clip);
        if (self.value > 0) {
            const weight = mix_weight(self.hover.value, hover_lighten);
            append_arc(list, ring, self.accent, weight, self.value, clip);
        }
        place_text(glyphs, self.name, name_box(row), clip);
        place_text(glyphs, self.value_text[0..4], value_box(row), clip);
        assert(list.count <= quads.instance_cap);
    }

    pub fn set_value(self: *Knob, value: f32) void {
        assert(value >= 0);
        assert(value <= 1);
        self.value = value;
        write_hundredths(&self.value_text, value);
        assert(self.value_text[1] == '.');
        assert(self.value == value);
    }

    fn drag_by(self: *Knob, y: f32) bool {
        const dy = y - self.drag_y;
        self.drag_y = y;
        assert(self.drag_y == y);
        return self.nudge(-dy / drag_span_px);
    }

    fn nudge(self: *Knob, delta: f32) bool {
        assert(delta == delta);
        var next = self.value + delta;
        if (next < 0) {
            next = 0;
        }
        if (next > 1) {
            next = 1;
        }
        if (self.value == next) {
            assert(self.value == next);
            return false;
        }
        self.set_value(next);
        assert(self.value == next);
        return true;
    }
};

/// Passive column. It occludes hits and ignores them. No animator.
pub const Meter = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    name: []const u8,
    value: f32,

    pub fn handle(self: *Meter, hit: Hit) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        switch (hit) {
            .hover_in => return false,
            .hover_out => return false,
            .down => return false,
            .drag => return false,
            .up => return false,
            .move => return false,
            .wheel => return false,
        }
    }

    pub fn animate(self: *Meter, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.id != 0);
        return false;
    }

    pub fn live(self: Meter) bool {
        assert(self.value >= 0);
        assert(self.value <= 1);
        return false;
    }

    pub fn draw(
        self: Meter,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        row: turtle.Rect,
        clip: font.Clip,
    ) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const track = meter_track(row);
        const rest = animator.Animator.init(down_rate_per_ms);
        append_weighted(list, track, paint_of(theme.chrome.track, meter_radius), rest, rest, clip);
        if (self.value > 0) {
            var fill = track;
            fill.height = self.value * track.height;
            fill.y = track.y + track.height - fill.height;
            append_weighted(
                list,
                fill,
                paint_of(theme.chrome.meter, meter_radius),
                rest,
                rest,
                clip,
            );
        }
        place_text(glyphs, self.name, side_box(row), clip);
        assert(list.count >= 1);
    }
};

/// Pill with a sliding thumb. Click on the pill flips the bool. The thumb aims over 100 ms.
pub const Toggle = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    name: []const u8,
    on: bool,
    hover: animator.Animator,
    thumb: animator.Animator,

    pub fn handle(self: *Toggle, hit: Hit) bool {
        assert(self.id != 0);
        assert(self.thumb.rate_per_ms > 0);
        switch (hit) {
            .hover_in => return self.hover.set_target(1),
            .hover_out => return self.hover.set_target(0),
            .down => return false,
            .drag => return false,
            .move => return false,
            .wheel => return false,
            .up => |up| {
                if (!up.inside) {
                    assert(!up.inside);
                    return false;
                }
                return self.flip();
            },
        }
    }

    pub fn animate(self: *Toggle, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.id != 0);
        return step_pair(&self.hover, &self.thumb, dt_ms);
    }

    pub fn live(self: Toggle) bool {
        assert(self.id != 0);
        assert(self.thumb.rate_per_ms > 0);
        return pair_live(self.hover, self.thumb);
    }

    pub fn draw(
        self: Toggle,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        row: turtle.Rect,
        clip: font.Clip,
    ) void {
        assert(self.thumb.value >= 0);
        assert(self.thumb.value <= 1);
        const pill = pill_of(row);
        const rest = animator.Animator.init(down_rate_per_ms);
        append_weighted(list, pill, paint_of(theme.chrome.track, pill_radius), rest, rest, clip);
        const thumb = toggle_thumb(pill, self.thumb.value);
        const disc = paint_of(theme.chrome.control, thumb_side * 0.5);
        append_weighted(list, thumb, disc, self.hover, rest, clip);
        place_text(glyphs, self.name, side_box(row), clip);
        assert(list.count >= 1);
    }

    fn flip(self: *Toggle) bool {
        self.on = !self.on;
        const target: f32 = if (self.on) 1 else 0;
        const aimed = self.thumb.set_target(target);
        assert(aimed);
        assert(self.thumb.target == target);
        return true;
    }
};

/// One column of controls. Child `rect.y` is the placed y. Draw and hit subtract `scroll_y`.
pub const Scroll = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
    padding: turtle.Inset,
    children: [scroll_child_cap]Control,
    child_count: u32,
    scroll_y: f32,
    content_h: f32,
    press: Press,
    hot: ?u32,

    pub fn handle(self: *Scroll, hit: Hit) bool {
        assert(self.child_count <= scroll_child_cap);
        assert(self.id != 0);
        switch (hit) {
            .hover_in => return false,
            .hover_out => return self.clear_hot(),
            .down => |point| return self.press_at(point),
            .drag => |point| return self.drag_at(point),
            .up => |up| return self.release_at(up),
            .move => |point| return self.retarget(point),
            .wheel => |wheel| return self.wheel_at(wheel),
        }
    }

    pub fn animate(self: *Scroll, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(self.child_count <= scroll_child_cap);
        var changed = false;
        var index: u32 = 0;
        while (index < self.child_count) : (index += 1) {
            if (control_animate(&self.children[index], dt_ms)) {
                changed = true;
            }
        }
        assert(index == self.child_count);
        return changed;
    }

    pub fn live(self: Scroll) bool {
        assert(self.child_count <= scroll_child_cap);
        assert(self.id != 0);
        var index: u32 = 0;
        while (index < self.child_count) : (index += 1) {
            if (control_live(&self.children[index])) {
                assert(index < self.child_count);
                return true;
            }
        }
        assert(index == self.child_count);
        return false;
    }

    /// The scene hits the border box. Children are resolved inside `handle`.
    pub fn contains(self: Scroll, x: f32, y: f32) bool {
        assert(self.id != 0);
        assert(self.padding.left >= 0);
        return face_contains(self.rect, 0, x, y);
    }

    pub fn draw(
        self: Scroll,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        window: font.Clip,
    ) void {
        assert(self.id != 0);
        assert(window.x1 > window.x0);
        const rest = animator.Animator.init(down_rate_per_ms);
        append_weighted(list, self.rect, paint_of(theme.chrome.panel, 0), rest, rest, window);
        const view = self.viewport();
        const clip = clip_of(view);
        self.draw_children(list, glyphs, view, clip);
        if (self.max_scroll() > 0) {
            if (view.height > 0) {
                const thumb = paint_of(theme.chrome.control, 4);
                append_weighted(list, self.thumb_rect(), thumb, rest, rest, window);
            }
        }
        assert(list.count <= quads.instance_cap);
        assert(glyphs.count <= font.glyph_cap);
    }

    /// Places children in the content column, then clamps `scroll_y`.
    pub fn layout_children(self: *Scroll) void {
        assert(self.child_count <= scroll_child_cap);
        assert(self.rect.width > 0);
        var walks: [scroll_child_cap]turtle.Walk = undefined;
        var rects: [scroll_child_cap]turtle.Rect = undefined;
        const count: usize = @intCast(self.child_count);
        var index: u32 = 0;
        while (index < self.child_count) : (index += 1) {
            walks[index] = control_walk(&self.children[index]);
        }
        const content = self.content_column();
        const pad: turtle.Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        turtle.place_column(.{ .rect = content, .padding = pad }, walks[0..count], rects[0..count]);
        index = 0;
        while (index < self.child_count) : (index += 1) {
            control_set_rect(&self.children[index], rects[index]);
        }
        self.content_h = span_of(walks[0..count]);
        self.clamp_scroll();
        assert(self.content_h >= 0);
        assert(self.scroll_y <= self.max_scroll());
    }

    pub fn viewport(self: Scroll) turtle.Rect {
        assert(self.padding.left >= 0);
        assert(self.padding.top >= 0);
        const rect: turtle.Rect = .{
            .x = self.rect.x + self.padding.left,
            .y = self.rect.y + self.padding.top,
            .width = self.rect.width - self.padding.left - self.padding.right,
            .height = self.rect.height - self.padding.top - self.padding.bottom,
        };
        assert(rect.x == self.rect.x + self.padding.left);
        assert(rect.y == self.rect.y + self.padding.top);
        return rect;
    }

    pub fn content_column(self: Scroll) turtle.Rect {
        const view = self.viewport();
        assert(view.width >= gutter_px);
        const rect: turtle.Rect = .{
            .x = view.x,
            .y = view.y,
            .width = view.width - gutter_px,
            .height = view.height,
        };
        assert(rect.width == view.width - gutter_px);
        assert(rect.y == view.y);
        return rect;
    }

    pub fn max_scroll(self: Scroll) f32 {
        const room = self.content_h - self.viewport().height;
        if (room <= 0) {
            assert(room <= 0);
            return 0;
        }
        assert(room > 0);
        return room;
    }

    fn draw_children(
        self: Scroll,
        list: *quads.DrawList,
        glyphs: *font.GlyphList,
        view: turtle.Rect,
        clip: font.Clip,
    ) void {
        assert(clip.x1 > clip.x0);
        assert(self.child_count <= scroll_child_cap);
        var index: u32 = 0;
        while (index < self.child_count) : (index += 1) {
            const row = scrolled(control_rect(&self.children[index]), self.scroll_y);
            if (!overlaps(row, view)) {
                continue;
            }
            control_draw(&self.children[index], list, glyphs, row, clip);
        }
        assert(index == self.child_count);
    }

    fn press_at(self: *Scroll, point: Point) bool {
        assert(point.x == point.x);
        if (self.max_scroll() > 0) {
            if (point_inside(self.thumb_rect(), point.x, point.y)) {
                self.press = .thumb;
                return self.set_scroll(self.scroll_at_pointer(point.y));
            }
            if (in_gutter(self.viewport(), point.x, point.y)) {
                self.press = .none;
                assert(self.press == .none);
                return false;
            }
        }
        if (self.child_at(point.x, point.y)) |index| {
            self.press = .{ .child = index };
            return control_handle(&self.children[index], .{ .down = point });
        }
        self.press = .none;
        assert(self.press == .none);
        return false;
    }

    fn drag_at(self: *Scroll, point: Point) bool {
        assert(point.y == point.y);
        switch (self.press) {
            .none => return false,
            .thumb => return self.set_scroll(self.scroll_at_pointer(point.y)),
            .child => |index| {
                assert(index < self.child_count);
                return control_handle(&self.children[index], .{ .drag = point });
            },
        }
    }

    fn release_at(self: *Scroll, up: Up) bool {
        const press = self.press;
        self.press = .none;
        switch (press) {
            .none => return false,
            .thumb => return false,
            .child => |index| {
                const inside = self.child_face(index, up.x, up.y);
                const sample: Up = .{ .x = up.x, .y = up.y, .inside = inside };
                return control_handle(&self.children[index], .{ .up = sample });
            },
        }
    }

    fn wheel_at(self: *Scroll, wheel: input.Wheel) bool {
        assert(wheel.dy == wheel.dy);
        if (!point_inside(self.viewport(), wheel.x, wheel.y)) {
            assert(self.child_count <= scroll_child_cap);
            return false;
        }
        if (self.ring_at(wheel.x, wheel.y)) |index| {
            return control_handle(&self.children[index], .{ .wheel = wheel });
        }
        return self.set_scroll(self.scroll_y + wheel.dy);
    }

    fn retarget(self: *Scroll, point: Point) bool {
        const next = self.hot_at(point.x, point.y);
        if (same_optional(self.hot, next)) {
            assert(self.child_count <= scroll_child_cap);
            return false;
        }
        var changed = false;
        if (self.hot) |previous| {
            if (control_handle(&self.children[previous], .hover_out)) {
                changed = true;
            }
        }
        if (next) |index| {
            if (control_handle(&self.children[index], .hover_in)) {
                changed = true;
            }
        }
        self.hot = next;
        assert(same_optional(self.hot, next));
        return changed;
    }

    fn clear_hot(self: *Scroll) bool {
        const previous = self.hot;
        self.hot = null;
        if (previous) |index| {
            assert(index < self.child_count);
            return control_handle(&self.children[index], .hover_out);
        }
        assert(self.hot == null);
        return false;
    }

    fn clamp_scroll(self: *Scroll) void {
        const limit = self.max_scroll();
        if (self.scroll_y < 0) {
            self.scroll_y = 0;
        }
        if (self.scroll_y > limit) {
            self.scroll_y = limit;
        }
        assert(self.scroll_y >= 0);
        assert(self.scroll_y <= limit);
    }

    fn set_scroll(self: *Scroll, next: f32) bool {
        assert(next == next);
        var clamped = next;
        const limit = self.max_scroll();
        if (clamped < 0) {
            clamped = 0;
        }
        if (clamped > limit) {
            clamped = limit;
        }
        if (self.scroll_y == clamped) {
            assert(self.scroll_y == clamped);
            return false;
        }
        self.scroll_y = clamped;
        assert(self.scroll_y == clamped);
        return true;
    }

    fn thumb_rect(self: Scroll) turtle.Rect {
        const view = self.viewport();
        const height = thumb_height(view.height, self.content_h);
        const travel = positive_span(view.height - height);
        var unit: f32 = 0;
        const limit = self.max_scroll();
        if (limit > 0) {
            unit = self.scroll_y / limit;
        }
        assert(unit >= 0);
        assert(unit <= 1);
        return .{
            .x = view.x + view.width - gutter_px,
            .y = view.y + unit * travel,
            .width = gutter_px,
            .height = height,
        };
    }

    fn scroll_at_pointer(self: Scroll, pointer_y: f32) f32 {
        const view = self.viewport();
        const height = thumb_height(view.height, self.content_h);
        const travel = view.height - height;
        if (travel <= 0) {
            assert(travel <= 0);
            return 0;
        }
        var unit = (pointer_y - view.y - height * 0.5) / travel;
        if (unit < 0) {
            unit = 0;
        }
        if (unit > 1) {
            unit = 1;
        }
        assert(unit >= 0);
        assert(unit <= 1);
        return unit * self.max_scroll();
    }

    fn child_at(self: *const Scroll, x: f32, y: f32) ?u32 {
        return self.scan(x, y, true);
    }

    fn hot_at(self: *const Scroll, x: f32, y: f32) ?u32 {
        return self.scan(x, y, false);
    }

    fn child_face(self: *const Scroll, index: u32, x: f32, y: f32) bool {
        assert(index < self.child_count);
        const row = scrolled(control_rect(&self.children[index]), self.scroll_y);
        const hit = control_hit(&self.children[index], row, x, y, true);
        assert(self.child_count <= scroll_child_cap);
        return hit;
    }

    fn ring_at(self: *const Scroll, x: f32, y: f32) ?u32 {
        assert(self.child_count <= scroll_child_cap);
        const view = self.viewport();
        var index: u32 = self.child_count;
        while (index > 0) {
            index -= 1;
            switch (self.children[index]) {
                .knob => |knob| {
                    const row = scrolled(knob.rect, self.scroll_y);
                    if (!overlaps(row, view)) {
                        continue;
                    }
                    if (ring_hit(row, x, y)) {
                        assert(index < self.child_count);
                        return index;
                    }
                },
                else => {},
            }
        }
        assert(index == 0);
        return null;
    }

    fn scan(self: *const Scroll, x: f32, y: f32, include_meter: bool) ?u32 {
        assert(self.child_count <= scroll_child_cap);
        const view = self.viewport();
        var index: u32 = self.child_count;
        while (index > 0) {
            index -= 1;
            const row = scrolled(control_rect(&self.children[index]), self.scroll_y);
            if (!overlaps(row, view)) {
                continue;
            }
            if (control_hit(&self.children[index], row, x, y, include_meter)) {
                assert(index < self.child_count);
                return index;
            }
        }
        assert(index == 0);
        return null;
    }
};

pub fn paint_of(color: [4]f32, radius: f32) Paint {
    assert(radius >= 0);
    assert(color[3] >= 0);
    const paint: Paint = .{
        .r = color[0],
        .g = color[1],
        .b = color[2],
        .a = color[3],
        .radius = radius,
    };
    assert(paint.radius == radius);
    assert(paint.a == color[3]);
    return paint;
}

pub fn settled(rate: f32, at_end: bool) animator.Animator {
    var value = animator.Animator.init(rate);
    if (at_end) {
        value.value = 1;
        value.target = 1;
    }
    assert(!value.live());
    assert(value.rate_per_ms == rate);
    return value;
}

pub fn ring_of(row: turtle.Rect) turtle.Rect {
    assert(row.height >= ring_size);
    const ring: turtle.Rect = .{
        .x = row.x + ring_inset,
        .y = row.y + (row.height - ring_size) * 0.5,
        .width = ring_size,
        .height = ring_size,
    };
    assert(ring.width == ring_size);
    assert(ring.height == ring_size);
    return ring;
}

pub fn write_hundredths(text: *[8]u8, value: f32) void {
    assert(value >= 0);
    assert(value <= 1);
    var hundredths: i32 = @intFromFloat(@round(value * 100.0));
    if (hundredths < 0) {
        hundredths = 0;
    }
    if (hundredths > 100) {
        hundredths = 100;
    }
    const whole: u32 = @intCast(hundredths);
    text[0] = '0' + @as(u8, @intCast(whole / 100));
    const rest = whole % 100;
    text[1] = '.';
    text[2] = '0' + @as(u8, @intCast(rest / 10));
    text[3] = '0' + @as(u8, @intCast(rest % 10));
    text[4] = 0;
    text[5] = 0;
    text[6] = 0;
    text[7] = 0;
    assert(text[1] == '.');
    if (text[0] != '0') {
        assert(text[0] == '1');
    }
}

fn name_box(row: turtle.Rect) turtle.Rect {
    const ring = ring_of(row);
    const box: turtle.Rect = .{
        .x = ring.x + 64,
        .y = row.y,
        .width = row.x + row.width - (ring.x + 64),
        .height = label_line_px,
    };
    assert(box.x == ring.x + 64);
    assert(box.height == label_line_px);
    return box;
}

fn value_box(row: turtle.Rect) turtle.Rect {
    var box = name_box(row);
    box.y = row.y + label_line_px;
    assert(box.y == row.y + label_line_px);
    assert(box.height == label_line_px);
    return box;
}

fn side_box(row: turtle.Rect) turtle.Rect {
    // Toggle rows are shorter than the knob ring. The label column is still
    // `ring_inset + 64` from the row, which is `ring.x + 64` on a knob row.
    const x = row.x + ring_inset + 64;
    const box: turtle.Rect = .{
        .x = x,
        .y = row.y,
        .width = row.x + row.width - x,
        .height = row.height,
    };
    assert(box.x == row.x + ring_inset + 64);
    assert(box.width > 0);
    return box;
}

fn meter_track(row: turtle.Rect) turtle.Rect {
    const center_x = row.x + ring_inset + ring_size * 0.5;
    const track: turtle.Rect = .{
        .x = center_x - meter_track_w * 0.5,
        .y = row.y + (row.height - meter_track_h) * 0.5,
        .width = meter_track_w,
        .height = meter_track_h,
    };
    assert(track.width == meter_track_w);
    assert(track.height == meter_track_h);
    return track;
}

fn pill_of(row: turtle.Rect) turtle.Rect {
    const pill: turtle.Rect = .{
        .x = row.x + ring_inset,
        .y = row.y + (row.height - pill_h) * 0.5,
        .width = pill_w,
        .height = pill_h,
    };
    assert(pill.width == pill_w);
    assert(pill.height == pill_h);
    return pill;
}

fn toggle_thumb(pill: turtle.Rect, value: f32) turtle.Rect {
    assert(value >= 0);
    assert(value <= 1);
    const thumb: turtle.Rect = .{
        .x = pill.x + thumb_inset + value * 20,
        .y = pill.y + thumb_inset,
        .width = thumb_side,
        .height = thumb_side,
    };
    assert(thumb.width == thumb_side);
    assert(thumb.y == pill.y + thumb_inset);
    return thumb;
}

fn clip_of(rect: turtle.Rect) font.Clip {
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

fn scrolled(rect: turtle.Rect, scroll_y: f32) turtle.Rect {
    assert(scroll_y == scroll_y);
    var row = rect;
    row.y = rect.y - scroll_y;
    assert(row.height == rect.height);
    assert(row.x == rect.x);
    return row;
}

fn overlaps(rect: turtle.Rect, view: turtle.Rect) bool {
    assert(view.width == view.width);
    assert(view.height == view.height);
    if (rect.width <= 0) {
        return false;
    }
    if (rect.height <= 0) {
        return false;
    }
    if (rect.y >= view.y + view.height) {
        return false;
    }
    if (rect.y + rect.height <= view.y) {
        return false;
    }
    if (rect.x >= view.x + view.width) {
        return false;
    }
    if (rect.x + rect.width <= view.x) {
        return false;
    }
    return true;
}

fn point_inside(rect: turtle.Rect, x: f32, y: f32) bool {
    assert(x == x);
    assert(y == y);
    if (x < rect.x) {
        return false;
    }
    if (y < rect.y) {
        return false;
    }
    if (x > rect.x + rect.width) {
        return false;
    }
    if (y > rect.y + rect.height) {
        return false;
    }
    return true;
}

fn in_gutter(view: turtle.Rect, x: f32, y: f32) bool {
    const gutter: turtle.Rect = .{
        .x = view.x + view.width - gutter_px,
        .y = view.y,
        .width = gutter_px,
        .height = view.height,
    };
    const inside = point_inside(gutter, x, y);
    assert(gutter.width == gutter_px);
    return inside;
}

fn thumb_height(view_h: f32, content_h: f32) f32 {
    assert(view_h > 0);
    assert(content_h > 0);
    const ratio = view_h * view_h / content_h;
    if (ratio < thumb_min_px) {
        return thumb_min_px;
    }
    if (ratio > view_h) {
        return view_h;
    }
    assert(ratio >= thumb_min_px);
    return ratio;
}

fn span_of(walks: []const turtle.Walk) f32 {
    assert(walks.len <= scroll_child_cap);
    const count: u32 = @intCast(walks.len);
    var sum: f32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        sum += walks[index].margin.top;
        sum += walks[index].margin.bottom;
        switch (walks[index].height) {
            .fixed, .fit => |height| sum += height,
            .fill => assert(walks[index].height == .fill),
        }
    }
    assert(index == count);
    assert(sum >= 0);
    return sum;
}

fn ring_hit(row: turtle.Rect, x: f32, y: f32) bool {
    const ring = ring_of(row);
    assert(ring.width == ring_size);
    return quads.contains_box(
        ring.x,
        ring.y,
        ring.width,
        ring.height,
        ring_size * 0.5,
        x,
        y,
    );
}

fn same_optional(hot: ?u32, next: ?u32) bool {
    if (hot) |previous| {
        if (next) |chosen| {
            assert(previous < scroll_child_cap);
            return previous == chosen;
        }
        return false;
    }
    if (next == null) {
        assert(hot == null);
        return true;
    }
    return false;
}

fn place_text(glyphs: *font.GlyphList, text: []const u8, rect: turtle.Rect, clip: font.Clip) void {
    assert(text.len <= 8);
    assert(clip.x1 > clip.x0);
    const color = theme.chrome.text;
    font.place(glyphs, text, .{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
    }, .{
        .r = color[0],
        .g = color[1],
        .b = color[2],
        .a = color[3],
    }, clip);
    assert(glyphs.count <= font.glyph_cap);
}

fn append_arc(
    list: *quads.DrawList,
    rect: turtle.Rect,
    paint: Paint,
    hover: f32,
    sweep: f32,
    clip: font.Clip,
) void {
    assert(hover >= 0);
    assert(hover <= 1);
    assert(sweep >= 0);
    assert(sweep <= 1);
    assert(list.count < quads.instance_cap);
    list.append(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .r = paint.r,
        .g = paint.g,
        .b = paint.b,
        .a = paint.a,
        .radius = ring_thickness,
        .hover = hover,
        .down = sweep,
        .kind = quads.kind_arc,
        .clip_x0 = clip.x0,
        .clip_y0 = clip.y0,
        .clip_x1 = clip.x1,
        .clip_y1 = clip.y1,
    }) catch unreachable;
    assert(list.items[list.count - 1].kind == quads.kind_arc);
    assert(list.count <= quads.instance_cap);
}

fn control_handle(control: *Control, hit: Hit) bool {
    assert(control_id(control) != 0);
    const changed = switch (control.*) {
        .knob => |*knob| knob.handle(hit),
        .meter => |*meter| meter.handle(hit),
        .toggle => |*toggle| toggle.handle(hit),
    };
    assert(control_id(control) != 0);
    return changed;
}

fn control_animate(control: *Control, dt_ms: f32) bool {
    assert(dt_ms >= 0);
    assert(control_id(control) != 0);
    return switch (control.*) {
        .knob => |*knob| knob.animate(dt_ms),
        .meter => |*meter| meter.animate(dt_ms),
        .toggle => |*toggle| toggle.animate(dt_ms),
    };
}

fn control_live(control: *const Control) bool {
    assert(control_id(control) != 0);
    return switch (control.*) {
        .knob => |*knob| knob.live(),
        .meter => |*meter| meter.live(),
        .toggle => |*toggle| toggle.live(),
    };
}

fn control_draw(
    control: *const Control,
    list: *quads.DrawList,
    glyphs: *font.GlyphList,
    row: turtle.Rect,
    clip: font.Clip,
) void {
    assert(clip.y1 > clip.y0);
    assert(list.count <= quads.instance_cap);
    switch (control.*) {
        .knob => |*knob| knob.draw(list, glyphs, row, clip),
        .meter => |*meter| meter.draw(list, glyphs, row, clip),
        .toggle => |*toggle| toggle.draw(list, glyphs, row, clip),
    }
}

fn control_walk(control: *const Control) turtle.Walk {
    switch (control.*) {
        .knob => |*knob| {
            assert(knob.walk.align_x >= 0);
            return knob.walk;
        },
        .meter => |*meter| {
            assert(meter.walk.align_x >= 0);
            return meter.walk;
        },
        .toggle => |*toggle| {
            assert(toggle.walk.align_x >= 0);
            return toggle.walk;
        },
    }
}

fn control_rect(control: *const Control) turtle.Rect {
    switch (control.*) {
        .knob => |*knob| {
            assert(knob.id != 0);
            return knob.rect;
        },
        .meter => |*meter| {
            assert(meter.id != 0);
            return meter.rect;
        },
        .toggle => |*toggle| {
            assert(toggle.id != 0);
            return toggle.rect;
        },
    }
}

fn control_set_rect(control: *Control, rect: turtle.Rect) void {
    assert(rect.x == rect.x);
    assert(rect.y == rect.y);
    switch (control.*) {
        .knob => |*knob| knob.rect = rect,
        .meter => |*meter| meter.rect = rect,
        .toggle => |*toggle| toggle.rect = rect,
    }
}

fn control_hit(
    control: *const Control,
    row: turtle.Rect,
    x: f32,
    y: f32,
    include_meter: bool,
) bool {
    assert(x == x);
    assert(y == y);
    switch (control.*) {
        .knob => return ring_hit(row, x, y),
        .meter => {
            if (!include_meter) {
                return false;
            }
            return point_inside(row, x, y);
        },
        .toggle => {
            const pill = pill_of(row);
            return quads.contains_box(
                pill.x,
                pill.y,
                pill.width,
                pill.height,
                pill_radius,
                x,
                y,
            );
        },
    }
}

fn control_id(control: *const Control) u32 {
    switch (control.*) {
        .knob => |*knob| {
            assert(knob.value >= 0);
            return knob.id;
        },
        .meter => |*meter| {
            assert(meter.value >= 0);
            return meter.id;
        },
        .toggle => |*toggle| {
            assert(toggle.thumb.rate_per_ms > 0);
            return toggle.id;
        },
    }
}

comptime {
    assert(hover_lighten == 0.18);
    assert(down_darken == 0.30);
    assert(hover_duration_ms == 100);
    assert(down_duration_ms == 50);
    assert(knob_radius == 12);
    assert(track_height == 6);
    assert(track_radius == 3);
    assert(hover_rate_per_ms > 0);
    assert(down_rate_per_ms > hover_rate_per_ms);
    assert(scroll_child_cap == 16);
    assert(scroll_child_cap * 12 <= font.glyph_cap);
    assert(gutter_px == 16);
    assert(drag_span_px == 120);
    assert(ring_size == 56);
    assert(ring_thickness == 4);
    assert(knob_height == 72);
    assert(meter_height == 160);
    assert(toggle_height == 40);
    assert(accent_count == 4);
}

// Locks slider analytical geometry and worked values at 1280x720:
// Bounding rect (16, 616, 1248, 24), knob_radius 12, travel 1224.
// Verifies exact track dimensions (28, 625, 1224, 6), knob disc (628, 616, 24, 24) at value 0.5,
// and boundary mapping for pointer samples at 640 (0.5), 28 (0.0), and 2000 (clamped to 1.0).
test "slider value at the worked pointer" {
    const rect: turtle.Rect = .{ .x = 16, .y = 616, .width = 1248, .height = 24 };
    try std.testing.expectEqual(@as(f32, 0.5), value_at(rect, 640));
    try std.testing.expectEqual(@as(f32, 0), value_at(rect, 28));
    try std.testing.expectEqual(@as(f32, 1), value_at(rect, 2000));
    const track = track_rect(rect);
    try std.testing.expectEqual(@as(f32, 28), track.x);
    try std.testing.expectEqual(@as(f32, 625), track.y);
    try std.testing.expectEqual(@as(f32, 1224), track.width);
    try std.testing.expectEqual(@as(f32, 6), track.height);
    const knob = knob_rect(rect, 0.5);
    try std.testing.expectEqual(@as(f32, 628), knob.x);
    try std.testing.expectEqual(@as(f32, 616), knob.y);
    try std.testing.expectEqual(@as(f32, 24), knob.width);
}

fn sample_button() Button {
    const button: Button = .{
        .id = 4,
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 48 },
        .walk = .{
            .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .width = .{ .fixed = 80 },
            .height = .{ .fixed = 48 },
            .align_x = 0,
        },
        .padding = .{ .left = 16, .top = 0, .right = 16, .bottom = 0 },
        .label = .{
            .text = "Cycle",
            .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .r = 1,
            .g = 1,
            .b = 1,
            .a = 1,
        },
        .paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 24 },
        .hover = animator.Animator.init(hover_rate_per_ms),
        .down = animator.Animator.init(down_rate_per_ms),
        .clicks = 0,
    };
    assert(button.clicks == 0);
    assert(button.id == 4);
    return button;
}

fn sample_slider() Slider {
    const slider: Slider = .{
        .id = 3,
        .rect = .{ .x = 16, .y = 616, .width = 1248, .height = 24 },
        .walk = .{
            .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .width = .fill,
            .height = .{ .fixed = 24 },
            .align_x = 0,
        },
        .hover = animator.Animator.init(hover_rate_per_ms),
        .value = 0.5,
        .track = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1, .radius = track_radius },
        .fill = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = track_radius },
        .knob = .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1, .radius = knob_radius },
    };
    assert(slider.value == 0.5);
    assert(slider.id == 3);
    return slider;
}

const sample_clip: font.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };

test "button up inside counts one click" {
    var button = sample_button();
    try std.testing.expect(button.handle(.hover_in));
    try std.testing.expect(button.handle(.{ .down = .{ .x = 40, .y = 24 } }));
    try std.testing.expect(button.handle(.{ .up = .{ .x = 40, .y = 24, .inside = true } }));
    try std.testing.expectEqual(@as(u32, 1), button.clicks);
    try std.testing.expectEqual(@as(f32, 0), button.down.target);
}

test "button up outside does not click" {
    var button = sample_button();
    try std.testing.expect(button.handle(.hover_in));
    try std.testing.expect(button.handle(.{ .down = .{ .x = 40, .y = 24 } }));
    try std.testing.expect(button.handle(.{ .up = .{ .x = 0, .y = 0, .inside = false } }));
    try std.testing.expectEqual(@as(u32, 0), button.clicks);
    try std.testing.expectEqual(@as(f32, 0), button.down.target);
    try std.testing.expect(button.handle(.hover_out));
    try std.testing.expectEqual(@as(f32, 0), button.hover.target);
}

test "slider drag sets an absolute value" {
    var slider = sample_slider();
    try std.testing.expect(slider.handle(.hover_in));
    try std.testing.expect(!slider.handle(.{ .down = .{ .x = 640, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 0.5), slider.value);
    try std.testing.expectEqual(@as(f32, 1), slider.hover.target);
    try std.testing.expect(slider.animate(hover_duration_ms));
    try std.testing.expectEqual(@as(f32, 1), slider.hover.value);
    var held = quads.DrawList.init();
    slider.draw(&held, sample_clip);
    try std.testing.expectEqual(@as(u32, 3), held.count);
    var face: u32 = 0;
    while (face < 3) : (face += 1) {
        try std.testing.expectEqual(hover_lighten, held.items[face].hover);
        try std.testing.expectEqual(@as(f32, 0), held.items[face].down);
    }
    try std.testing.expect(slider.handle(.{ .drag = .{ .x = 28, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 0), slider.value);
    var list = quads.DrawList.init();
    slider.draw(&list, sample_clip);
    try std.testing.expectEqual(@as(u32, 2), list.count);
    try std.testing.expect(slider.handle(.{ .drag = .{ .x = 2000, .y = 628 } }));
    try std.testing.expectEqual(@as(f32, 1), slider.value);
}

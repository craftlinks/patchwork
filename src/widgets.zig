//! Widgets: panels, labels, buttons, sliders, knobs, meters, and toggles as plain structs.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Plain Structs, Drawn in Place
//! A widget is a struct the app owns: its id, its value, and its animators. It has no rect
//! and no layout pass. `draw(self, cx, walk)` asks the turtle for its box (`cx.walk`), culls
//! itself when the box is outside the clip (`cx.visible`), records its hit area
//! (`cx.area`), and appends `draw.Box`, `draw.Arc`, and `draw.Glyph` records. `cx` is the
//! app's `ui.Context`; it is `anytype` because that type depends on the app's draw types,
//! so a widget fails to compile against an app that did not register a type it draws.
//!
//! ## 2. Events and Actions
//! `handle(self, cx, event) Action` is called by the app for every event, `.frame`
//! included:
//! - `.frame` steps the widget's animators; a moved value calls `cx.redraw()` and a live one
//!   `cx.keep_animating()`, which keeps frame callbacks coming. Animators never step in draw.
//! - Every other event is resolved by `cx.hit(self.id, event)` in O(1) against the areas of
//!   the last frame. `down` and `drag` carry that area's rect, so geometry such as the
//!   slider's travel needs no stored rect. A press or wheel counts as hovering, because
//!   one event delivers one hit and a press may arrive without a prior move.
//! - The return value says what changed for the app (`Knob.Action.changed`), so an app can
//!   react to a value, not only repaint.
//! `Panel`, `Label`, and `Meter` are passive: they draw and record no area.
//!
//! ### Blend Weights
//! An `Animator` travels over `[0, 1]`. Widgets scale it before writing the instance:
//! ```text
//! hover_weight = hover.value * hover_lighten
//! down_weight  = down.value  * down_darken      (applied after the hover mix)
//! ```
//! `Knob` lightens only the value arc and `Toggle` only the thumb disc.
//!
//! ## 3. Geometry
//! All geometry is UI logical pixels, origin top-left, `+Y` down; `row` is the box the
//! turtle gave the widget.
//! - **Slider:** `span = rect.width - 2 * knob_radius`,
//!   `value = clamp((x - rect.x - knob_radius) / span, 0, 1)`; a non-positive span yields 0.
//!   The hit area is the rect rounded by `knob_radius`. Test "slider value at the worked
//!   pointer".
//! - **Knob:** `ring_of(row)` is a `ring_size` square at `row.x + ring_inset`, centered
//!   vertically; the hit area is the disc inscribed in it and takes the wheel. Drag and
//!   wheel are relative: `value' = clamp(value - delta / drag_span_px, 0, 1)` with
//!   `delta = y - drag_y` for drags and `delta = wheel.dy` for the wheel. A row shorter than
//!   the ring draws nothing. Test "knob drag is relative and clamped".
//! - **Value text:** hundredths as `d.dd` in the fixed `[8]u8` `value_text`, tail zeroed.
//! - **Meter:** the track is `meter_track_w` by `meter_track_h`, centered over the ring
//!   column and vertically in `row`; the fill grows up from the track bottom and is omitted at
//!   0. The track may be taller than a short row, so a caller that needs it contained opens a
//!   clipping container for it. Test "meter fill grows upward from the track bottom".
//! - **Toggle:** `pill_of(row)` is a `pill_w` by `pill_h` capsule at `row.x + ring_inset`;
//!   the thumb is a `thumb_side` disc, `thumb.x = pill.x + thumb_inset + thumb.value *
//!   travel`. The pill is the hit area; a release inside flips `on`.
//!
//! ## 4. Capacity
//! Every append goes through `push`, which skips an instance whose pool or batch list is
//! full; the context counts the drop in `overflow_count`, and app tests assert it is zero.
//!
//! ## 5. Text Styles
//! Control names use `name_style` (Noto Sans 16 px) and knob values `value_style` (Noto Sans
//! Mono 16 px), so readouts keep their width as digits change. A `Label` carries its own
//! style.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: label text points at app-owned bytes bounded by `text.byte_cap`; a
//!   knob's value text is inline.
//! - Geometry helpers are pure; `handle` is the only mutator.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const quads = @import("draw.zig");
const text = @import("text.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

pub const Rect = quads.Rect;
pub const Inset = quads.Inset;
pub const Walk = ui.Walk;
pub const Id = ui.Id;

/// Shader mix toward white at animator value 1.
pub const hover_lighten: f32 = 0.18;

/// Shader mix toward black at animator value 1. Applied after the lighten.
pub const down_darken: f32 = 0.30;

/// Wall time for hover to travel the unit range.
pub const hover_duration_ms: f32 = 100;

/// Wall time for the press darken to travel the unit range.
pub const down_duration_ms: f32 = 50;

/// Fraction of the unit range covered in one millisecond of hover.
pub const hover_rate_per_ms: f32 = 1.0 / hover_duration_ms;

/// Fraction of the unit range covered in one millisecond of press.
pub const down_rate_per_ms: f32 = 1.0 / down_duration_ms;

/// Slider knob radius in logical pixels. The knob is a disc of diameter `2 * knob_radius`
/// and the track is inset by this radius at both ends.
pub const knob_radius: f32 = 12;

/// Slider track thickness in logical pixels, centered in the widget rect.
pub const track_height: f32 = 6;

/// Track corner radius. Half the thickness, so the track is a capsule.
pub const track_radius: f32 = 3;

/// Knob drag and wheel distance, in logical pixels, that covers the unit range.
pub const drag_span_px: f32 = 120;

/// Knob ring edge. The hit disc is inscribed in it, so the hole still drags.
pub const ring_size: f32 = 56;

/// Ring stroke. Stored in the arc instance's `thickness`.
pub const ring_thickness: f32 = 4;

/// Inset of the ring and the pill from the row's left edge.
pub const ring_inset: f32 = 8;

// Row heights and face metrics, in logical pixels. `ring_of`, `meter_track`, and `pill_of`
// place the faces inside a row of the matching height; `label_line_px` is the height of one
// text line beside the ring.
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
pub const label_line_px: f32 = 36;
pub const accent_count: u32 = 4;

/// Fill and corner radius copied onto each instance a widget appends.
pub const Paint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
};

/// Per-knob accent fills, cycled by knob index modulo `accent_count`. Not theme slots: each
/// knob's value arc carries its own fill.
pub const accents: [accent_count]Paint = .{
    .{ .r = 0.62, .g = 0.45, .b = 0.86, .a = 1, .radius = ring_thickness },
    .{ .r = 0.40, .g = 0.78, .b = 0.48, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.55, .b = 0.24, .a = 1, .radius = ring_thickness },
    .{ .r = 0.93, .g = 0.80, .b = 0.32, .a = 1, .radius = ring_thickness },
};

/// Control names beside a ring, meter, or pill.
pub const name_style: text.Style = .{
    .face = .sans,
    .size = 16,
    .color = theme.chrome.text,
};

/// Knob value readouts: monospace, so the digits do not shift as the value changes.
pub const value_style: text.Style = .{
    .face = .mono,
    .size = 16,
    .color = theme.chrome.text,
};

/// Text centered on both axes, without an ellipsis.
pub const centered: text.Options = .{
    .align_x = .center,
    .align_y = .center,
    .ellipsis = false,
};

/// Text centered in its box, in `style`. Empty `text` appends nothing. `text` points at
/// app-owned bytes (usually a literal) of at most `text.byte_cap`.
pub const Label = struct {
    text: []const u8,
    style: text.Style,

    pub fn draw(self: *const Label, cx: anytype, walk: Walk) void {
        assert(self.text.len <= text.byte_cap);
        assert(self.style.color[3] >= 0);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        text.place(cx.drawing(), self.style, self.text, rect, clip, centered);
    }
};

/// A rounded face behind other content. Passive: it records no area.
pub const Panel = struct {
    paint: Paint,

    /// Draws the face over the box `walk` gets, under the enclosing clip, then opens a
    /// container laid out by `layout` over it. The caller closes it with `cx.end()`. The
    /// face is appended before the container opens, so aligning the children leaves it in
    /// place; a fit panel has no box yet and draws no face.
    pub fn begin(self: *const Panel, cx: anytype, walk: Walk, layout: ui.Layout) Rect {
        assert(self.paint.radius >= 0);
        const rect = cx.peek(walk);
        if (cx.visible(rect)) |clip| face(cx, rect, self.paint, 0, 0, clip);
        const opened = cx.begin(walk, layout);
        assert(opened.x == rect.x);
        assert(opened.y == rect.y);
        return opened;
    }

    /// Draws the face alone, as a leaf.
    pub fn draw(self: *const Panel, cx: anytype, walk: Walk) void {
        assert(self.paint.radius >= 0);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        face(cx, rect, self.paint, 0, 0, clip);
    }
};

/// A clickable face with a centered label.
pub const Button = struct {
    id: Id,
    label: []const u8,
    style: text.Style,
    padding: Inset,
    paint: Paint,
    hover: animator.Animator,
    down: animator.Animator,

    pub const Action = enum {
        none,
        clicked,
    };

    pub fn handle(self: *Button, cx: anytype, event: input.Event) Action {
        assert(self.id != .none);
        if (event == .frame) {
            step(cx, &self.hover, event.frame);
            step(cx, &self.down, event.frame);
            return .none;
        }
        switch (cx.hit(self.id, event)) {
            .none, .drag, .wheel => return .none,
            .hover_in => aim(cx, &self.hover, 1),
            .hover_out => aim(cx, &self.hover, 0),
            .down => {
                aim(cx, &self.hover, 1);
                aim(cx, &self.down, 1);
            },
            .up => |up| {
                aim(cx, &self.down, 0);
                if (up.inside) return .clicked;
                aim(cx, &self.hover, 0);
            },
        }
        return .none;
    }

    pub fn draw(self: *const Button, cx: anytype, walk: Walk) void {
        assert(self.id != .none);
        assert(self.label.len <= text.byte_cap);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        cx.area(self.id, rect, self.paint.radius, ui.cx.plain);
        face(cx, rect, self.paint, self.hover.value, self.down.value, clip);
        const inner = ui.cx.inset(rect, self.padding);
        text.place(cx.drawing(), self.style, self.label, inner, clip, centered);
    }
};

/// Absolute slider: press and drag set `value` from the pointer x. The hover animator is
/// the highlight for the whole gesture; there is no press-darken channel.
pub const Slider = struct {
    id: Id,
    hover: animator.Animator,
    value: f32,
    track: Paint,
    fill: Paint,
    knob: Paint,

    pub const Action = union(enum) {
        none,
        changed: f32,
        released,
    };

    pub fn handle(self: *Slider, cx: anytype, event: input.Event) Action {
        assert(self.value >= 0);
        assert(self.value <= 1);
        if (event == .frame) {
            step(cx, &self.hover, event.frame);
            return .none;
        }
        switch (cx.hit(self.id, event)) {
            .none, .wheel => return .none,
            .hover_in => aim(cx, &self.hover, 1),
            .hover_out => aim(cx, &self.hover, 0),
            .down => |press| {
                aim(cx, &self.hover, 1);
                return self.set_at(cx, press);
            },
            .drag => |press| return self.set_at(cx, press),
            .up => |up| {
                if (!up.inside) aim(cx, &self.hover, 0);
                return .released;
            },
        }
        return .none;
    }

    /// Track, then fill (omitted at value 0), then the knob on top.
    pub fn draw(self: *const Slider, cx: anytype, walk: Walk) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        cx.area(self.id, rect, knob_radius, ui.cx.plain);
        const track = track_rect(rect);
        face(cx, track, self.track, self.hover.value, 0, clip);
        if (self.value > 0) {
            var fill_rect = track;
            fill_rect.width = self.value * track.width;
            face(cx, fill_rect, self.fill, self.hover.value, 0, clip);
        }
        face(cx, knob_rect(rect, self.value), self.knob, self.hover.value, 0, clip);
    }

    fn set_at(self: *Slider, cx: anytype, press: ui.Press) Action {
        const next = value_at(press.rect, press.x);
        if (self.value == next) return .none;
        self.value = next;
        cx.redraw();
        assert(self.value == next);
        return .{ .changed = next };
    }
};

/// Open ring. Drag is relative: up increases `value`. Value 0 omits the value arc.
pub const Knob = struct {
    id: Id,
    name: []const u8,
    value_text: [8]u8,
    value: f32,
    accent: Paint,
    hover: animator.Animator,
    drag_y: f32,

    pub const Action = union(enum) {
        none,
        changed: f32,
        released,
    };

    /// A knob at `value` with its text written.
    pub fn init(id: Id, name: []const u8, value: f32, accent: Paint) Knob {
        assert(id != .none);
        assert(name.len <= 8);
        var knob: Knob = .{
            .id = id,
            .name = name,
            .value_text = @splat(0),
            .value = value,
            .accent = accent,
            .hover = animator.Animator.init(hover_rate_per_ms),
            .drag_y = 0,
        };
        knob.set_value(value);
        assert(knob.value == value);
        return knob;
    }

    pub fn handle(self: *Knob, cx: anytype, event: input.Event) Action {
        assert(self.value >= 0);
        assert(self.value <= 1);
        if (event == .frame) {
            step(cx, &self.hover, event.frame);
            return .none;
        }
        switch (cx.hit(self.id, event)) {
            .none => return .none,
            .hover_in => aim(cx, &self.hover, 1),
            .hover_out => aim(cx, &self.hover, 0),
            .down => |press| {
                self.drag_y = press.y;
                aim(cx, &self.hover, 1);
            },
            .drag => |press| {
                const dy = press.y - self.drag_y;
                self.drag_y = press.y;
                return self.nudge(cx, -dy / drag_span_px);
            },
            .up => |up| {
                if (!up.inside) aim(cx, &self.hover, 0);
                return .released;
            },
            .wheel => |wheel| {
                aim(cx, &self.hover, 1);
                return self.nudge(cx, -wheel.dy / drag_span_px);
            },
        }
        return .none;
    }

    /// Draws the ring, the value arc, the name, and the value text in the box `walk` gets,
    /// and records the ring's disc as a wheel area. A box shorter than the ring draws
    /// nothing.
    pub fn draw(self: *const Knob, cx: anytype, walk: Walk) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const row = cx.walk(walk);
        if (row.height < ring_size) return;
        const clip = cx.visible(row) orelse return;
        const ring = ring_of(row);
        cx.area(self.id, ring, ring_size * 0.5, ui.cx.wheel_flag);
        append_arc(cx, ring, paint_of(theme.chrome.track, ring_thickness), 0, 1, clip);
        if (self.value > 0) {
            const weight = mix_weight(self.hover.value, hover_lighten);
            append_arc(cx, ring, self.accent, weight, self.value, clip);
        }
        place_text(cx, name_style, self.name, name_box(row), clip);
        place_text(cx, value_style, self.value_text[0..4], value_box(row), clip);
    }

    pub fn set_value(self: *Knob, value: f32) void {
        assert(value >= 0);
        assert(value <= 1);
        self.value = value;
        write_hundredths(&self.value_text, value);
        assert(self.value_text[1] == '.');
        assert(self.value == value);
    }

    fn nudge(self: *Knob, cx: anytype, delta: f32) Action {
        assert(delta == delta);
        const next = std.math.clamp(self.value + delta, 0, 1);
        if (self.value == next) return .none;
        self.set_value(next);
        cx.redraw();
        return .{ .changed = next };
    }
};

/// A level column. Passive: drawing only reads `value`.
pub const Meter = struct {
    name: []const u8,
    value: f32,

    /// Writes `value` when it differs. Returns true when it changed.
    pub fn set_value(self: *Meter, value: f32) bool {
        assert(value >= 0);
        assert(value <= 1);
        if (self.value == value) return false;
        self.value = value;
        assert(self.value == value);
        return true;
    }

    pub fn draw(self: *const Meter, cx: anytype, walk: Walk) void {
        assert(self.value >= 0);
        assert(self.value <= 1);
        const row = cx.walk(walk);
        const clip = cx.visible(row) orelse return;
        const track = meter_track(row);
        face(cx, track, paint_of(theme.chrome.track, meter_radius), 0, 0, clip);
        if (self.value > 0) {
            var fill = track;
            fill.height = self.value * track.height;
            fill.y = track.y + track.height - fill.height;
            face(cx, fill, paint_of(theme.chrome.meter, meter_radius), 0, 0, clip);
        }
        place_text(cx, name_style, self.name, side_box(row), clip);
    }
};

/// Pill with a sliding thumb. A release on the pill flips `on` and re-aims the thumb.
pub const Toggle = struct {
    id: Id,
    name: []const u8,
    on: bool,
    hover: animator.Animator,
    thumb: animator.Animator,

    pub const Action = union(enum) {
        none,
        toggled: bool,
    };

    /// A toggle at rest, thumb on the side `on` selects.
    pub fn init(id: Id, name: []const u8, on: bool) Toggle {
        assert(id != .none);
        assert(name.len <= 8);
        const toggle: Toggle = .{
            .id = id,
            .name = name,
            .on = on,
            .hover = animator.Animator.init(hover_rate_per_ms),
            .thumb = settled(hover_rate_per_ms, on),
        };
        assert(!toggle.thumb.live());
        return toggle;
    }

    pub fn handle(self: *Toggle, cx: anytype, event: input.Event) Action {
        assert(self.id != .none);
        assert(self.thumb.rate_per_ms > 0);
        if (event == .frame) {
            step(cx, &self.hover, event.frame);
            step(cx, &self.thumb, event.frame);
            return .none;
        }
        switch (cx.hit(self.id, event)) {
            .none, .drag, .wheel => return .none,
            .hover_in, .down => aim(cx, &self.hover, 1),
            .hover_out => aim(cx, &self.hover, 0),
            .up => |up| {
                if (!up.inside) {
                    aim(cx, &self.hover, 0);
                    return .none;
                }
                self.on = !self.on;
                aim(cx, &self.thumb, if (self.on) 1 else 0);
                return .{ .toggled = self.on };
            },
        }
        return .none;
    }

    pub fn draw(self: *const Toggle, cx: anytype, walk: Walk) void {
        assert(self.thumb.value >= 0);
        assert(self.thumb.value <= 1);
        const row = cx.walk(walk);
        const clip = cx.visible(row) orelse return;
        const pill = pill_of(row);
        cx.area(self.id, pill, pill_radius, ui.cx.plain);
        face(cx, pill, paint_of(theme.chrome.track, pill_radius), 0, 0, clip);
        const thumb = toggle_thumb(pill, self.thumb.value);
        const disc = paint_of(theme.chrome.control, thumb_side * 0.5);
        face(cx, thumb, disc, self.hover.value, 0, clip);
        place_text(cx, name_style, self.name, side_box(row), clip);
    }
};

/// Steps `value` by `dt_ms`: a moved value owes a redraw and a live one another frame.
fn step(cx: anytype, value: *animator.Animator, dt_ms: f32) void {
    assert(dt_ms >= 0);
    if (value.step(dt_ms)) cx.redraw();
    if (value.live()) cx.keep_animating();
}

/// Aims `value` at `target`; a new target owes a redraw.
fn aim(cx: anytype, value: *animator.Animator, target: f32) void {
    assert(target >= 0);
    assert(target <= 1);
    if (value.set_target(target)) cx.redraw();
}

/// Unit position of `x` along the knob travel, clamped to `[0, 1]`.
/// Travel is `width - 2 * knob_radius`. A non-positive travel returns 0.
pub fn value_at(rect: Rect, x: f32) f32 {
    assert(x == x);
    const span = rect.width - 2.0 * knob_radius;
    if (span <= 0) return 0;
    const unit = std.math.clamp((x - rect.x - knob_radius) / span, 0, 1);
    assert(unit >= 0);
    assert(unit <= 1);
    return unit;
}

/// Track centered vertically in `rect`, inset by the knob radius on x.
pub fn track_rect(rect: Rect) Rect {
    assert(rect.height == rect.height);
    const track: Rect = .{
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
pub fn knob_rect(rect: Rect, value: f32) Rect {
    assert(value >= 0);
    assert(value <= 1);
    const side = 2.0 * knob_radius;
    const travel = @max(0, rect.width - side);
    const knob: Rect = .{
        .x = rect.x + value * travel,
        .y = rect.y + (rect.height - side) * 0.5,
        .width = side,
        .height = side,
    };
    assert(knob.width == side);
    assert(knob.height == side);
    return knob;
}

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

/// An animator resting at 0, or at 1 when `at_end`.
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

pub fn ring_of(row: Rect) Rect {
    assert(row.height >= ring_size);
    const ring: Rect = .{
        .x = row.x + ring_inset,
        .y = row.y + (row.height - ring_size) * 0.5,
        .width = ring_size,
        .height = ring_size,
    };
    assert(ring.width == ring_size);
    assert(ring.height == ring_size);
    return ring;
}

pub fn write_hundredths(out: *[8]u8, value: f32) void {
    assert(value >= 0);
    assert(value <= 1);
    const scaled: i32 = @intFromFloat(@round(value * 100.0));
    const whole: u32 = @intCast(std.math.clamp(scaled, 0, 100));
    out[0] = '0' + @as(u8, @intCast(whole / 100));
    const rest = whole % 100;
    out[1] = '.';
    out[2] = '0' + @as(u8, @intCast(rest / 10));
    out[3] = '0' + @as(u8, @intCast(rest % 10));
    @memset(out[4..], 0);
    assert(out[1] == '.');
    if (out[0] != '0') assert(out[0] == '1');
}

fn name_box(row: Rect) Rect {
    const ring = ring_of(row);
    const box: Rect = .{
        .x = ring.x + 64,
        .y = row.y,
        .width = row.x + row.width - (ring.x + 64),
        .height = label_line_px,
    };
    assert(box.x == ring.x + 64);
    assert(box.height == label_line_px);
    return box;
}

fn value_box(row: Rect) Rect {
    var box = name_box(row);
    box.y = row.y + label_line_px;
    assert(box.y == row.y + label_line_px);
    assert(box.height == label_line_px);
    return box;
}

/// The label column beside a meter or pill. It lands at the same x as `name_box`; the
/// comptime block asserts that.
fn side_box(row: Rect) Rect {
    const x = row.x + ring_inset + 64;
    const box: Rect = .{
        .x = x,
        .y = row.y,
        .width = row.x + row.width - x,
        .height = row.height,
    };
    assert(box.x == row.x + ring_inset + 64);
    assert(box.height == row.height);
    return box;
}

pub fn meter_track(row: Rect) Rect {
    const center_x = row.x + ring_inset + ring_size * 0.5;
    const track: Rect = .{
        .x = center_x - meter_track_w * 0.5,
        .y = row.y + (row.height - meter_track_h) * 0.5,
        .width = meter_track_w,
        .height = meter_track_h,
    };
    assert(track.width == meter_track_w);
    assert(track.height == meter_track_h);
    return track;
}

pub fn pill_of(row: Rect) Rect {
    const pill: Rect = .{
        .x = row.x + ring_inset,
        .y = row.y + (row.height - pill_h) * 0.5,
        .width = pill_w,
        .height = pill_h,
    };
    assert(pill.width == pill_w);
    assert(pill.height == pill_h);
    return pill;
}

pub fn toggle_thumb(pill: Rect, value: f32) Rect {
    assert(value >= 0);
    assert(value <= 1);
    const thumb: Rect = .{
        .x = pill.x + thumb_inset + value * 20,
        .y = pill.y + thumb_inset,
        .width = thumb_side,
        .height = thumb_side,
    };
    assert(thumb.width == thumb_side);
    assert(thumb.y == pill.y + thumb_inset);
    return thumb;
}

/// Appends `instance` through `cx`, skipping it when its pool or the batch list is full;
/// the context counts the drop. Widgets append only positive, ordered geometry.
fn push(cx: anytype, comptime T: type, instance: T) void {
    comptime assert(T.texture == null);
    assert(instance.rect[2] > 0);
    assert(instance.clip[2] > instance.clip[0]);
    cx.append(T, null, instance) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// A `draw.Box` face with the hover and press weights of the animator values given.
fn face(cx: anytype, rect: Rect, paint: Paint, hover: f32, down: f32, clip: quads.Clip) void {
    assert(paint.radius >= 0);
    if (rect.width <= 0) return;
    if (rect.height <= 0) return;
    push(cx, quads.Box, .{
        .rect = .{ rect.x, rect.y, rect.width, rect.height },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .fill = .{ paint.r, paint.g, paint.b, paint.a },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = paint.radius,
        .border_width = 0,
        .hover = mix_weight(hover, hover_lighten),
        .down = mix_weight(down, down_darken),
    });
}

fn append_arc(
    cx: anytype,
    rect: Rect,
    paint: Paint,
    hover: f32,
    sweep: f32,
    clip: quads.Clip,
) void {
    assert(hover >= 0);
    assert(sweep >= 0);
    assert(sweep <= 1);
    assert(rect.width == ring_size);
    push(cx, quads.Arc, .{
        .rect = .{ rect.x, rect.y, rect.width, rect.height },
        .clip = .{ clip.x0, clip.y0, clip.x1, clip.y1 },
        .color = .{ paint.r, paint.g, paint.b, paint.a },
        .thickness = ring_thickness,
        .sweep = sweep,
        .hover = hover,
        .pad = 0,
    });
}

fn place_text(
    cx: anytype,
    style: text.Style,
    bytes: []const u8,
    rect: Rect,
    clip: quads.Clip,
) void {
    assert(bytes.len <= 8);
    assert(clip.x1 > clip.x0);
    text.place(cx.drawing(), style, bytes, rect, clip, centered);
}

fn mix_weight(amount: f32, scale: f32) f32 {
    assert(amount >= 0);
    assert(amount <= 1);
    const weight = amount * scale;
    assert(weight >= 0);
    assert(weight <= scale);
    return weight;
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
    assert(drag_span_px == 120);
    assert(ring_size == 56);
    assert(ring_thickness == 4);
    assert(knob_height == 72);
    assert(meter_height == 160);
    assert(toggle_height == 40);
    assert(accent_count == 4);
    // The literal 64 in `name_box` and `side_box` is the label column offset: the ring plus
    // its inset. `toggle_thumb` hardcodes the thumb travel as 20.
    assert(ring_inset + ring_size == 64);
    assert(pill_w - thumb_side - 2 * thumb_inset == 20);
    // Capsules: the corner radius is half the short side.
    assert(track_radius * 2 == track_height);
    assert(pill_radius * 2 == pill_h);
    assert(meter_radius * 2 == meter_track_w);
}

const testing = std.testing;

const test_draw = [_]quads.DrawType{
    .{ .type = quads.Box, .cap = 16 },
    .{ .type = quads.Arc, .cap = 16 },
    .{ .type = quads.Glyph, .cap = 64 },
};

const TestContext = ui.Context(quads.Context(&test_draw, 16), 16);

/// A freshly initialized static context, so tests keep the pools off the stack.
fn test_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

/// The walk that puts a `width` by `height` box at `(x, y)` under the root turtle.
fn at(x: f32, y: f32, width: f32, height: f32) Walk {
    return .{
        .width = .{ .fixed = width },
        .height = .{ .fixed = height },
        .margin = .{ .left = x, .top = y, .right = 0, .bottom = 0 },
    };
}

/// Dispatches `event` to one widget the way an app's `event` does.
fn send(cx: *TestContext, widget: anytype, event: input.Event) @TypeOf(widget.*).Action {
    cx.event_begin(event);
    const action = widget.handle(cx, event);
    cx.event_end();
    return action;
}

/// Draws one widget at `walk` in a fresh 1280 by 720 frame.
fn draw_one(cx: *TestContext, widget: anytype, walk: Walk) void {
    cx.begin_frame(1280, 720, 120);
    widget.draw(cx, walk);
    _ = cx.end_frame();
}

// Locks the slider's pointer-to-value map, its clamping, and the track and knob placement.
test "slider value at the worked pointer" {
    // Rect x = 16, width = 1248, so travel = width - 2 * knob_radius = 1224.
    const rect: Rect = .{ .x = 16, .y = 616, .width = 1248, .height = 24 };
    // (640 - 16 - 12) / 1224 = 0.5; x = 28 is the left stop; x = 2000 clamps to the right.
    try testing.expectEqual(@as(f32, 0.5), value_at(rect, 640));
    try testing.expectEqual(@as(f32, 0), value_at(rect, 28));
    try testing.expectEqual(@as(f32, 1), value_at(rect, 2000));
    // Track: x = 16 + 12, y = 616 + (24 - 6) / 2, width = travel.
    const track = track_rect(rect);
    try testing.expectEqual(@as(f32, 28), track.x);
    try testing.expectEqual(@as(f32, 625), track.y);
    try testing.expectEqual(@as(f32, 1224), track.width);
    try testing.expectEqual(@as(f32, 6), track.height);
    // Knob at value 0.5: x = 16 + 0.5 * 1224, a 24 px disc filling the row height.
    const knob = knob_rect(rect, 0.5);
    try testing.expectEqual(@as(f32, 628), knob.x);
    try testing.expectEqual(@as(f32, 616), knob.y);
    try testing.expectEqual(@as(f32, 24), knob.width);
}

fn sample_button() Button {
    return .{
        .id = ui.id("button", 0),
        .label = "Cycle",
        .style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } },
        .padding = .{ .left = 16, .top = 0, .right = 16, .bottom = 0 },
        .paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 24 },
        .hover = animator.Animator.init(hover_rate_per_ms),
        .down = animator.Animator.init(down_rate_per_ms),
    };
}

// Locks the click rule: a release over the button clicks once, a release elsewhere does not,
// and both release the press darken.
test "button up inside clicks and up outside does not" {
    const cx = test_context();
    var button = sample_button();
    draw_one(cx, &button, at(0, 0, 80, 48));
    const inside: input.Point = .{ .x = 40, .y = 24 };
    const outside: input.Point = .{ .x = 400, .y = 400 };
    try testing.expectEqual(Button.Action.none, send(cx, &button, .{ .pointer_down = inside }));
    try testing.expectEqual(@as(f32, 1), button.down.target);
    try testing.expectEqual(Button.Action.clicked, send(cx, &button, .{ .pointer_up = inside }));
    try testing.expectEqual(@as(f32, 0), button.down.target);
    _ = send(cx, &button, .{ .pointer_down = inside });
    try testing.expectEqual(Button.Action.none, send(cx, &button, .{ .pointer_up = outside }));
    try testing.expectEqual(@as(f32, 0), button.hover.target);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the slider gesture: a press sets the value from the area's rect, the hover weight
// lightens every face while held, a drag to the left stop omits the fill, and the release
// reports `released`.
test "slider drag sets an absolute value" {
    const cx = test_context();
    var slider: Slider = .{
        .id = ui.id("slider", 0),
        .hover = animator.Animator.init(hover_rate_per_ms),
        .value = 0.25,
        .track = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1, .radius = track_radius },
        .fill = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = track_radius },
        .knob = .{ .r = 0.86, .g = 0.88, .b = 0.92, .a = 1, .radius = knob_radius },
    };
    const walk = at(16, 616, 1248, 24);
    draw_one(cx, &slider, walk);
    const pressed = send(cx, &slider, .{ .pointer_down = .{ .x = 640, .y = 628 } });
    try testing.expectEqual(@as(f32, 0.5), pressed.changed);
    _ = send(cx, &slider, .{ .frame = hover_duration_ms });
    try testing.expectEqual(@as(f32, 1), slider.hover.value);
    draw_one(cx, &slider, walk);
    const held = cx.draw.items(quads.Box);
    try testing.expectEqual(@as(usize, 3), held.len);
    for (held) |box| try testing.expectEqual(hover_lighten, box.hover);
    const dragged = send(cx, &slider, .{ .pointer_move = .{ .x = 28, .y = 628 } });
    try testing.expectEqual(@as(f32, 0), dragged.changed);
    draw_one(cx, &slider, walk);
    try testing.expectEqual(@as(usize, 2), cx.draw.items(quads.Box).len);
    const released = send(cx, &slider, .{ .pointer_up = .{ .x = 28, .y = 628 } });
    try testing.expectEqual(Slider.Action.released, released);
}

/// A point on the knob ring's vertical center line at `y`.
fn at_y(y: f32) input.Point {
    return .{ .x = 36, .y = y };
}

// Locks the relative drag rule: upward motion adds `delta / drag_span_px`, the wheel uses the
// same scale with the opposite sign of `dy`, results clamp to `[0, 1]`, and the text follows.
test "knob drag is relative and clamped" {
    const cx = test_context();
    var knob = Knob.init(ui.id("knob", 0), "k", 0.25, accents[0]);
    try testing.expectEqualStrings("0.25", knob.value_text[0..4]);
    // The ring sits at (8, 8 + 72 - 56) / 2 inside a 200 by 72 row at the origin: center 36.
    draw_one(cx, &knob, at(0, 0, 200, knob_height));
    try testing.expectEqual(Knob.Action.none, send(cx, &knob, .{ .pointer_down = at_y(36) }));
    // Move up 30 px: 30 / drag_span_px = 0.25 added.
    try testing.expectEqual(@as(f32, 0.5), send(cx, &knob, .{ .pointer_move = at_y(6) }).changed);
    try testing.expectEqualStrings("0.50", knob.value_text[0..4]);
    // A move of exactly drag_span_px down removes the whole range; further down is clamped.
    try testing.expectEqual(@as(f32, 0), send(cx, &knob, .{ .pointer_move = at_y(126) }).changed);
    try testing.expectEqual(Knob.Action.none, send(cx, &knob, .{ .pointer_move = at_y(4000) }));
    try testing.expectEqual(Knob.Action.released, send(cx, &knob, .{ .pointer_up = at_y(36) }));
    // Wheel dy = -60 adds 60 / drag_span_px; a further push up clamps at 1.
    const up_60: input.Wheel = .{ .x = 36, .y = 36, .dy = -60 };
    try testing.expectEqual(@as(f32, 0.5), send(cx, &knob, .{ .wheel = up_60 }).changed);
    const up_far: input.Wheel = .{ .x = 36, .y = 36, .dy = -4000 };
    try testing.expectEqual(@as(f32, 1), send(cx, &knob, .{ .wheel = up_far }).changed);
    try testing.expectEqualStrings("1.00", knob.value_text[0..4]);
    // A wheel off the ring does nothing.
    const off_ring: input.Wheel = .{ .x = 150, .y = 36, .dy = 60 };
    try testing.expectEqual(Knob.Action.none, send(cx, &knob, .{ .wheel = off_ring }));
}

// Locks the toggle thumb travel to the pill interior and the release-inside flip rule, and
// that the thumb eases on `.frame` while asking for more frames.
test "toggle thumb spans the pill and flips only on an inside release" {
    const cx = test_context();
    var toggle = Toggle.init(ui.id("toggle", 0), "t", false);
    // Row y = 0 and height = 40, so the pill is centered: y = (40 - 24) / 2 = 8.
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = toggle_height };
    const pill = pill_of(row);
    const off = toggle_thumb(pill, 0);
    const on = toggle_thumb(pill, 1);
    try testing.expectEqual(pill.x + thumb_inset, off.x);
    try testing.expectEqual(pill.x + pill.width - thumb_inset, on.x + on.width);
    try testing.expectEqual(pill.y + thumb_inset, off.y);
    draw_one(cx, &toggle, at(0, 0, 200, toggle_height));
    _ = send(cx, &toggle, .{ .pointer_down = .{ .x = 30, .y = 20 } });
    const outside: input.Point = .{ .x = 300, .y = 20 };
    try testing.expectEqual(Toggle.Action.none, send(cx, &toggle, .{ .pointer_up = outside }));
    try testing.expect(!toggle.on);
    _ = send(cx, &toggle, .{ .pointer_down = .{ .x = 30, .y = 20 } });
    try testing.expect(send(cx, &toggle, .{ .pointer_up = .{ .x = 30, .y = 20 } }).toggled);
    try testing.expectEqual(@as(f32, 1), toggle.thumb.target);
    cx.animating = false;
    _ = send(cx, &toggle, .{ .frame = 50 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), toggle.thumb.value, 0.0001);
    try testing.expect(cx.animating);
}

// Locks the meter fill anchoring (bottom edge fixed, grows upward) and the omitted fill at 0.
test "meter fill grows upward from the track bottom" {
    const cx = test_context();
    var meter: Meter = .{ .name = "", .value = 0.25 };
    const walk = at(0, 0, 100, meter_height);
    const track = meter_track(.{ .x = 0, .y = 0, .width = 100, .height = meter_height });
    draw_one(cx, &meter, walk);
    try testing.expectEqual(@as(usize, 2), cx.draw.items(quads.Box).len);
    // Quarter value: fill height = 0.25 * meter_track_h (exact in binary floating point).
    const fill = cx.draw.items(quads.Box)[1];
    try testing.expectEqual(@as(f32, 0.25) * meter_track_h, fill.rect[3]);
    try testing.expectEqual(track.y + track.height, fill.rect[1] + fill.rect[3]);
    try testing.expectEqual(track.x, fill.rect[0]);
    try testing.expect(!meter.set_value(0.25));
    try testing.expect(meter.set_value(0));
    draw_one(cx, &meter, walk);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(quads.Box).len);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

//! Panel, button, and slider widgets. Each owns its rectangle, walk, and animators.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In an instanced GPU user interface, there is a fundamental tension between retained widget
//! state (interaction models, animations, click counts, value tracking) and immediate-style
//! GPU submission (draw lists that are wiped and rebuilt on dirty frames).
//!
//! ### Retained Widgets vs. Ephemeral Draw Lists:
//! In Step 5, hover and down weights were written directly into the `DrawList` array. Because
//! layout rebuilds discard the draw list, transient state (such as in-flight hover fades, button
//! click counters, and slider thumb positions) could not survive a relayout.
//! In Step 6, state lives permanently in retained widgets (`Panel`, `Button`, `Slider`):
//! - Each widget owns its border-box `Rect` and layout `Walk`.
//! - `Panel` and `Button` own an `Animator` pair (`hover`, `down`).
//! - `Button` retains its cumulative `clicks` counter.
//! - `Slider` retains its normalized scalar `value: f32` in `[0.0, 1.0]` and a hover animator.
//!   Press and drag keep that highlight. They do not aim a darken.
//! - On redraw, `draw()` copies current animated weights into fresh 48-byte GPU `Instance` records.
//! - The WGSL shader remains completely decoupled: it receives standard 48-byte instance records
//!   and has no knowledge of widgets.
//!
//! ### Scaled Shader Blend Weights:
//! An `Animator` travels across the unit range `[0.0, 1.0]`. If written directly to the GPU instance,
//! a hover weight of 1.0 would mix the fill color 100% to pure white, and a down weight of 1.0
//! would mix 100% to solid black.
//! Instead, widgets scale the normalized animator values:
//! - `hover_weight = animator.value * hover_lighten` (`0.18`, matching Step 5).
//! - `down_weight = animator.value * down_darken` (`0.30`, applied after hover).
//! - A slider face passes a resting down animator, so its `down_weight` stays `0`.
//!   The hover lighten is the pressed color.
//!
//! ### Passive Occlusion vs. Interactive Response:
//! - **Panel:** Passive container. It participates in the scene's reverse-order hit scan so that
//!   clicks or pointer motions over the panel body occlude controls beneath it. Its `handle()`
//!   method returns `false` for all events, ensuring it consumes hits without triggering dirty frames.
//! - **Button:** Active trigger. Responds to `.hover_in` / `.hover_out` by aiming `hover` at 1 or 0,
//!   and `.down` by aiming `down` at 1. On `.up`, it registers a click if and only if `up.inside` is
//!   true (pointer was released within button bounds).
//! - **Slider:** Continuous control. Dragging and pressing map the absolute pointer X coordinate
//!   directly into `[0.0, 1.0]`. Absolute positioning eliminates relative delta accumulation drift
//!   and guarantees idempotent state for any pointer position. The gesture keeps the hover
//!   highlight. It does not mix toward black the way a button press does.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All widget geometries are expressed in UI logical pixels, top-left origin `(0, 0)`, `+X` right,
//! and `+Y` down.
//!
//! ### Slider Track, Fill, and Knob Analytical Derivation:
//! Let `rect = (x, y, width, height)` be the slider's bounding box assigned by the turtle.
//! Fixed constants: `knob_radius = 12`, `track_height = 6`, `track_radius = 3`.
//! The knob is a circle of diameter `2 * knob_radius = 24`.
//! To allow the knob to reach both edges without overflowing `rect`:
//! - Total travel span: `travel = max(width - 2 * knob_radius, 0)`
//! - Horizontal insetting: The track is inset on left and right by `knob_radius`.
//!
//! 1. **Track Rectangle:**
//!    ```text
//!    track.x = rect.x + knob_radius
//!    track.y = rect.y + (rect.height - track_height) * 0.5
//!    track.width = rect.width - 2 * knob_radius
//!    track.height = track_height  (= 6)
//!    track.radius = track_radius  (= 3, capsule ends)
//!    ```
//!
//! 2. **Fill Rectangle:**
//!    Represents active progress from the left track edge up to the knob center:
//!    ```text
//!    fill.x = track.x
//!    fill.y = track.y
//!    fill.width = value * track.width
//!    fill.height = track.height
//!    fill.radius = track.radius
//!    ```
//!    *Optimization:* When `value == 0`, the fill instance is completely omitted from the draw list.
//!
//! 3. **Knob Rectangle (Analytical Disc):**
//!    ```text
//!    knob.x = rect.x + value * travel
//!    knob.y = rect.y + (rect.height - 2 * knob_radius) * 0.5
//!    knob.width = 2 * knob_radius  (= 24)
//!    knob.height = 2 * knob_radius (= 24)
//!    knob.radius = knob_radius     (= 12)
//!    ```
//!    In `sdf_box`, corner radius is clamped to `min(radius, min(w/2, h/2))`. For a 24x24 box with
//!    radius 12, `k = 12`, transforming the box into an exact analytical circle with zero vertex overhead.
//!
//! 4. **Absolute Value Projection (`value_at`):**
//!    Maps an arbitrary pointer coordinate `px` to the normalized interval `[0.0, 1.0]`:
//!    ```text
//!    if (travel <= 0):
//!        value = 0.0
//!    else:
//!        unit = (px - rect.x - knob_radius) / travel
//!        value = clamp(unit, 0.0, 1.0)
//!    ```
//!
//! ### Worked Mathematical Verification (1280 x 720 Demo):
//! Slider assigned rect: `(16, 616, 1248, 24)`.
//! - `travel = 1248 - 2 * 12 = 1224`.
//! - `track = (16 + 12, 616 + (24 - 6)*0.5, 1224, 6) = (28, 625, 1224, 6)`.
//! - For pointer `x = 640`:
//!   `unit = (640 - 16 - 12) / 1224 = 612 / 1224 = 0.5`.
//!   `knob.x = 16 + 0.5 * 1224 = 16 + 612 = 628`.
//!   `knob = (628, 616, 24, 24)`.
//! - For pointer `x = 28` (left edge): `unit = (28 - 28) / 1224 = 0.0`.
//! - For pointer `x = 2000` (beyond right edge): clamped to `1.0`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Struct Layouts:
//! - `Paint` (20 bytes, 4-byte aligned): `r, g, b, a, radius: f32`.
//! - `Up` (12 bytes, 4-byte aligned): `x: f32, y: f32, inside: bool, pad: 3 bytes`.
//! - `Point` (8 bytes, 4-byte aligned): `x: f32, y: f32`.
//! - `Panel` and `Button`: `Rect`, `Walk`, `Paint`, and an `Animator` pair (`hover`, `down`).
//! - `Slider`: `Rect`, `Walk`, three `Paint`s, one hover `Animator`, and `value`. No down animator.
//!
//! ### GPU Instance Emission (`append_weighted`):
//! Each quad appended to `DrawList` occupies 48 bytes matching WebGPU Vertex Buffer 1 stride:
//! - Location 1 (Offset 0): `(x, y, width, height)` (4x f32)
//! - Location 2 (Offset 16): `(r, g, b, a)` (4x f32)
//! - Location 3 (Offset 32): `(radius, hover_weight, down_weight, 0.0)` (4x f32)
//!
//! ### Instance Emission Quotas:
//! - `Panel`: 1 instance.
//! - `Button`: 1 instance.
//! - `Slider`: up to 3 instances (track, fill, knob; 2 instances when `value == 0`).
//! - Capacity assertion: `1 + widget_cap * 3 <= instance_cap` (1 + 32 * 3 = 97 <= 256).
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Button Interaction State Machine:
//! ```text
//!                  +--------------------------------+
//!                  |             Idle               |
//!                  |  (hover = 0, down = 0, !live)  |
//!                  +--------------------------------+
//!                       |                      ^
//!              hover_in |                      | hover_out
//!                       v                      |
//!                  +--------------------------------+
//!                  |            Hovered             |
//!                  |     (hover -> 1, down = 0)     |
//!                  +--------------------------------+
//!                       |                      ^
//!                  down |                      | up (inside == true)
//!                       v                      | [clicks += 1]
//!                  +--------------------------------+
//!                  |            Pressed             |
//!                  |     (hover -> 1, down -> 1)    |
//!                  +--------------------------------+
//!                       |                      ^
//!                       | up (inside == false) |
//!                       v                      |
//!                  [down -> 0, no click count] |
//! ```
//!
//! ### Slider Interaction State Machine:
//! ```text
//! .hover_in  --> self.hover.set_target(1)
//! .hover_out --> self.hover.set_target(0)
//! .down(pt)  --> set_value_at(pt.x)  (hover stays aimed at 1; no darken)
//! .drag(pt)  --> set_value_at(pt.x)  (absolute position update)
//! .up        --> no weight change; the scene redispatches hover
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Unified Event Coordinates:** `Point` coordinates passed to `handle()` are in UI logical
//!   pixels across all operating systems.
//! - **Wayland Translation:** In `linux_window.zig`, `wl_pointer` signed 24.8 fixed-point is
//!   divided by 256.0 before reaching `widgets`.
//! - **WebAssembly Translation:** In `web/shell.js`, DOM PointerEvent `offsetX/offsetY` CSS pixels
//!   are scaled by `window.devicePixelRatio` before reaching `widgets`.
//!
//! ## 6. TigerStyle Invariants
//! - **Zero Runtime Allocation:** Widgets allocate no memory.
//! - **Degenerate Rect Guard:** In `draw()` and `face_contains()`, if `rect.width <= 0` or
//!   `rect.height <= 0`, functions return immediately without appending invalid instances or
//!   generating math errors.
//! - **Bounded Execution:** `handle`, `animate`, and `draw` execute in bounded O(1) steps.
//! - **Split Preconditions:** Invariant conditions (`id != 0`, `radius >= 0`, `value in [0, 1]`)
//!   are asserted independently at every boundary.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const quads = @import("draw.zig");
const input = @import("input.zig");
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
};

/// Fill and corner radius copied onto each instance this widget appends.
pub const Paint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
};

/// Passive rounded rectangle. Hit-tested so it occludes, and then ignored.
pub const Panel = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
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

    pub fn draw(self: Panel, list: *quads.DrawList) void {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        append_weighted(list, self.rect, self.paint, self.hover, self.down);
    }
};

/// Clickable face. `clicks` increments on `up` while `inside` is true.
pub const Button = struct {
    id: u32,
    rect: turtle.Rect,
    walk: turtle.Walk,
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

    pub fn draw(self: Button, list: *quads.DrawList) void {
        assert(self.id != 0);
        assert(self.paint.radius >= 0);
        append_weighted(list, self.rect, self.paint, self.hover, self.down);
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
    pub fn draw(self: Slider, list: *quads.DrawList) void {
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
        append_weighted(list, track, self.track, self.hover, rest);
        if (self.value > 0) {
            var fill_rect = track;
            fill_rect.width = self.value * track.width;
            append_weighted(list, fill_rect, self.fill, self.hover, rest);
        }
        const knob = knob_rect(self.rect, self.value);
        append_weighted(list, knob, self.knob, self.hover, rest);
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
        .pad1 = 0,
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

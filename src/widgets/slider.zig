//! `Slider`: an absolute slider over a capsule track.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! All geometry is UI logical pixels, origin top-left, `+Y` down; `rect` is the box the turtle
//! gave the slider.
//! ```text
//! [t0, t1] = Skin.slider_travel(rect)          default: [rect.x + knob_radius,
//!                                                        rect.x + rect.width - knob_radius]
//! value    = clamp((x - t0) / (t1 - t0), 0, 1)  a non-positive span yields 0
//! ```
//! The track is `track_height` thick, centered vertically and inset by `knob_radius` at both
//! ends; the knob is a `2 * knob_radius` disc at `rect.x + value * (rect.width - 2 *
//! knob_radius)`. The hit area is the rect rounded by `knob_radius`. Test "slider value at the
//! worked pointer".
//!
//! ## 2. Events
//! Press and drag set `value` from the pointer x along the skin's travel of the rect the press
//! carries, so the slider stores no rect and a skin maps presses onto what it drew. The hover
//! animator is the highlight for the whole gesture (the kit's table without a press channel);
//! a release reports `released`.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// Slider knob radius in logical pixels. The knob is a disc of diameter `2 * knob_radius`
/// and the track is inset by this radius at both ends.
pub const knob_radius: f32 = 12;

/// Slider track thickness in logical pixels, centered in the widget rect.
pub const track_height: f32 = 6;

/// Track corner radius. Half the thickness, so the track is a capsule.
pub const track_radius: f32 = 3;

/// The default slider: `SliderOf(skins.Default)`, a capsule track with a disc knob.
pub const Slider = SliderOf(skin.Default);

/// An absolute slider drawn by `Skin` (`widgets/skin.zig`): press and drag set `value` from
/// the pointer x along `Skin.slider_travel`. The hover animator is the highlight for the whole
/// gesture; there is no press-darken channel.
pub fn SliderOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .slider)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        hover: animator.Animator,
        value: f32,
        track: kit.Paint,
        fill: kit.Paint,
        knob: kit.Paint,

        pub const Action = union(enum) {
            none,
            changed: f32,
            released,
        };

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.value >= 0);
            assert(self.value <= 1);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                return .none;
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            switch (hit) {
                .none, .wheel, .secondary, .hover_in, .hover_out => return .none,
                .down, .drag => |press| return self.set_at(cx, press),
                .up => return .released,
            }
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns. The
        /// default skin draws the track, the fill (omitted at value 0), then the knob on top.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.value >= 0);
            assert(self.value <= 1);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            const shape = Skin.slider(cx, .{
                .rect = rect,
                .clip = clip,
                .value = self.value,
                .hover = self.hover.value,
                .track = self.track,
                .fill = self.fill,
                .knob = self.knob,
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, ui.cx.plain);
        }

        fn set_at(self: *Self, cx: anytype, press: ui.Press) Action {
            const next = skin.travel_value(Skin.slider_travel(press.rect), press.x);
            if (self.value == next) return .none;
            self.value = next;
            cx.redraw();
            assert(self.value == next);
            return .{ .changed = next };
        }
    };
}

/// Unit position of `x` along the default knob travel, clamped to `[0, 1]`: the skin map
/// (`skin.travel_value`) over `skins.Default.slider_travel(rect)`. Travel is
/// `width - 2 * knob_radius`; a non-positive travel returns 0.
pub fn value_at(rect: Rect, x: f32) f32 {
    assert(x == x);
    const unit = skin.travel_value(skin.Default.slider_travel(rect), x);
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

comptime {
    assert(knob_radius == 12);
    assert(track_height == 6);
    assert(track_radius == 3);
    // A capsule: the corner radius is half the thickness.
    assert(track_radius * 2 == track_height);
}

const testing = std.testing;
const quads = @import("../draw.zig");
const fixture = @import("fixture.zig");
const test_context = fixture.context;
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;
const hover_lighten = kit.hover_lighten;
const hover_duration_ms = kit.hover_duration_ms;
const hover_rate_per_ms = kit.hover_rate_per_ms;

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
    const pressed = send(cx, &slider, .{ .pointer_down = input.left_at(.{ .x = 640, .y = 628 }) });
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
    const released = send(cx, &slider, .{ .pointer_up = input.left_at(.{ .x = 28, .y = 628 }) });
    try testing.expectEqual(Slider.Action.released, released);
}

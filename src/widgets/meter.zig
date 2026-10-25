//! `Meter`: a passive level column.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! The track is `meter_track_w` by `meter.track_h` (default `meter_track_h`), centered over the
//! default knob's ring column (`ring_inset + ring_size / 2`, `widgets/knob.zig`) and vertically
//! in the row; the fill grows up from the track bottom and is omitted at 0. The name sits in
//! the knob's label column (`side_box`). The track may be taller than a short row, so a
//! caller that needs it contained opens a clipping container for it. Test "meter fill grows
//! upward from the track bottom".
//!
//! ## 2. Events
//! None: drawing only reads `value` and hands it to the skin (`widgets/skin.zig`; `Meter` is
//! `MeterOf(skins.Default)`), and it records no area. `set_value` reports a change so
//! the caller owes a draw only then.

const std = @import("std");
const assert = std.debug.assert;
const theme = @import("../theme.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const knob_file = @import("knob.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;

/// A meter row's height in logical pixels.
pub const meter_height: f32 = 160;
pub const meter_track_w: f32 = 12;
pub const meter_track_h: f32 = 144;
pub const meter_radius: f32 = 6;

/// The default meter: `MeterOf(skins.Default)`, a capsule level column.
pub const Meter = MeterOf(skin.Default);

/// A level column drawn by `Skin` (`widgets/skin.zig`). Passive: drawing only reads `value`.
pub fn MeterOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .meter)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        name: []const u8,
        value: f32,
        /// The track's height in logical pixels (section 1).
        track_h: f32 = meter_track_h,

        /// Writes `value` when it differs. Returns true when it changed.
        pub fn set_value(self: *Self, value: f32) bool {
            assert(value >= 0);
            assert(value <= 1);
            if (self.value == value) return false;
            self.value = value;
            assert(self.value == value);
            return true;
        }

        /// Hands the box `walk` gets to the skin; a meter records no area.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.value >= 0);
            assert(self.value <= 1);
            const row = cx.walk(walk);
            const clip = cx.visible(row) orelse return;
            Skin.meter(cx, .{
                .row = row,
                .clip = clip,
                .value = self.value,
                .track_h = self.track_h,
                .name = self.name,
            });
        }
    };
}

pub fn meter_track(row: Rect) Rect {
    return meter_track_sized(row, meter_track_h);
}

/// A meter track `height` tall in `row`, centered over the ring column (section 1).
pub fn meter_track_sized(row: Rect, height: f32) Rect {
    assert(height > 0);
    const center_x = row.x + knob_file.ring_inset + knob_file.ring_size * 0.5;
    const track: Rect = .{
        .x = center_x - meter_track_w * 0.5,
        .y = row.y + (row.height - height) * 0.5,
        .width = meter_track_w,
        .height = height,
    };
    assert(track.width == meter_track_w);
    assert(track.height == height);
    return track;
}

comptime {
    assert(meter_height == 160);
    // A capsule: the corner radius is half the width.
    assert(meter_radius * 2 == meter_track_w);
    assert(meter_track_h < meter_height);
}

const testing = std.testing;
const quads = @import("../draw.zig");
const ui = @import("../ui.zig");
const fixture = @import("fixture.zig");
const test_context = fixture.context;
const draw_one = fixture.draw_one;
const at = fixture.at;
const Knob = knob_file.Knob;
const accents = knob_file.accents;
const knob_height = knob_file.knob_height;
const name_box = knob_file.name_box;

// Locks per-instance sizes (section 3): a 40 px knob in a 200 by 72 row has its ring at
// (8, 16), its disc area of radius 20 centered at (28, 36), and its labels at x = 56; a 96 px
// meter track is centered in a 160 px row at y = 32, under the default ring column.
test "a knob and a meter take their own sizes" {
    const cx = test_context();
    const knob = Knob.init(ui.id("small", 0), "k", 0.5, accents[0]).sized(40);
    draw_one(cx, &knob, at(0, 0, 200, knob_height));
    const area = cx.find(ui.id("small", 0)).?;
    try testing.expectEqualSlices(f32, &.{ 8, 16, 40, 40 }, &area.rect);
    try testing.expectEqual(@as(f32, 20), area.radius);
    const glyphs = cx.draw.items(quads.Glyph);
    try testing.expect(glyphs.len >= 1);
    for (glyphs) |glyph| try testing.expect(glyph.rect[0] >= 56);
    const row: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 72 };
    try testing.expectEqual(@as(f32, 56), name_box(row, 40).x);
    const track = meter_track_sized(.{ .x = 0, .y = 0, .width = 100, .height = meter_height }, 96);
    try testing.expectEqual(@as(f32, 32), track.y);
    try testing.expectEqual(meter_track(.{ .x = 0, .y = 0, .width = 100, .height = 1 }).x, track.x);
    const meter: Meter = .{ .name = "m", .value = 0.5, .track_h = 96 };
    draw_one(cx, &meter, at(0, 0, 100, meter_height));
    try testing.expectEqual(@as(f32, 96), cx.draw.items(quads.Box)[0].rect[3]);
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

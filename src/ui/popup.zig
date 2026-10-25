//! Popup placement: where a menu, a dropdown list, a tooltip, or a dialog goes beside the thing
//! it belongs to, kept inside the window. Pure math, no context.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Overlay Model
//! A popup is drawn by the widget that owns it at the end of `App.draw` (`ui.overlays`), at the
//! root of the turtle stack, on its own draw layer (`Layer.popup`, `Layer.tooltip`). Under it,
//! `cx.begin_popup` records a backdrop area over the whole window on the same layer, so every
//! press outside the popup resolves to the backdrop (`ui/areas.zig`, section 4: the highest
//! layer wins) and nothing new is needed in input. This file only decides where the popup's
//! rect goes.
//!
//! ## 2. Placement
//! `place(anchor, size, window, side)` puts a `size` box beside `anchor`, at least
//! `popup_margin` from every edge of `window` and `popup_gap` from the anchor:
//! ```text
//! below   x = anchor.x                    y = anchor.bottom + gap
//! above   x = anchor.x                    y = anchor.y - gap - h
//! right   x = anchor.right + gap          y = anchor.y
//! left    x = anchor.x - gap - w          y = anchor.y
//! at      x = anchor.x                    y = anchor.y      (a context menu at the pointer)
//! ```
//! A side that overflows its window edge flips to the opposite side when the space there is
//! larger: `below` and `above` flip vertically, `right` and `left` horizontally, `at` on both
//! axes independently (flipped, its right or bottom edge sits on the anchor's top-left). Then
//! the box is cut to the window minus the margins, if larger (the caller's list scrolls), and
//! clamped into it on both axes.
//!
//! ## 3. Anchors
//! `Anchor` is what a popup hangs from: the area of an id drawn this frame (a button, a knob),
//! or a point (the pointer of a right press). `anchor_rect` turns a point into an empty rect at
//! that point, which `place` accepts.
//!
//! ## 4. TigerStyle Invariants
//! - No state and no loops: every function is a few comparisons.
//! - The window minus its margins is positive on both axes (asserted), so the cut and the clamp
//!   always have room.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const areas = @import("areas.zig");

pub const Rect = draw.Rect;
pub const Id = areas.Id;

/// The least distance from a popup to every window edge, in logical pixels.
pub const popup_margin: f32 = 4;

/// The distance from a popup to its anchor, in logical pixels.
pub const popup_gap: f32 = 2;

/// The salt of a popup's backdrop area: `id.derive(backdrop_salt)` (`cx.popup_backdrop`).
pub const backdrop_salt: u64 = 0x706f7075;

/// Popups open at a time: one (`cx.begin_popup` asserts it); submenus are deferred.
pub const popup_depth_max: u32 = 1;

/// The side of the anchor a popup goes on. See the module guide, section 2.
pub const Side = enum { below, above, right, left, at };

/// What a popup hangs from (section 3).
pub const Anchor = union(enum) {
    /// The area of this id at the current frame.
    id: Id,
    /// A point in logical pixels, such as the pointer of a right press.
    point: [2]f32,
};

/// An empty rect at `point`: the anchor of a popup opened at a point.
pub fn anchor_rect(point: [2]f32) Rect {
    assert(point[0] == point[0]);
    assert(point[1] == point[1]);
    return .{ .x = point[0], .y = point[1], .width = 0, .height = 0 };
}

/// The rect of a `size` popup on `side` of `anchor` inside `window` (section 2).
pub fn place(anchor: Rect, size: [2]f32, window: Rect, side: Side) Rect {
    assert(size[0] > 0 and size[1] > 0);
    assert(anchor.width >= 0 and anchor.height >= 0);
    assert(window.width > 2 * popup_margin);
    assert(window.height > 2 * popup_margin);
    const low_x = window.x + popup_margin;
    const low_y = window.y + popup_margin;
    const high_x = window.x + window.width - popup_margin;
    const high_y = window.y + window.height - popup_margin;
    const width = @min(size[0], high_x - low_x);
    const height = @min(size[1], high_y - low_y);
    const right = anchor.x + anchor.width;
    const bottom = anchor.y + anchor.height;
    var x = anchor.x;
    var y = anchor.y;
    switch (side) {
        .below, .above => {
            const below = bottom + popup_gap;
            const above = anchor.y - popup_gap - height;
            const room_below = high_y - below;
            const room_above = anchor.y - popup_gap - low_y;
            if (side == .below) {
                const flip = below + height > high_y and room_above > room_below;
                y = if (flip) above else below;
            } else {
                const flip = above < low_y and room_below > room_above;
                y = if (flip) below else above;
            }
        },
        .right, .left => {
            const beside_right = right + popup_gap;
            const beside_left = anchor.x - popup_gap - width;
            const room_right = high_x - beside_right;
            const room_left = anchor.x - popup_gap - low_x;
            if (side == .right) {
                const flip = beside_right + width > high_x and room_left > room_right;
                x = if (flip) beside_left else beside_right;
            } else {
                const flip = beside_left < low_x and room_right > room_left;
                x = if (flip) beside_right else beside_left;
            }
        },
        .at => {
            if (anchor.x + width > high_x and anchor.x - low_x > high_x - anchor.x) {
                x = anchor.x - width;
            }
            if (anchor.y + height > high_y and anchor.y - low_y > high_y - anchor.y) {
                y = anchor.y - height;
            }
        },
    }
    const placed: Rect = .{
        .x = std.math.clamp(x, low_x, high_x - width),
        .y = std.math.clamp(y, low_y, high_y - height),
        .width = width,
        .height = height,
    };
    assert(placed.x >= low_x and placed.x + placed.width <= high_x);
    assert(placed.y >= low_y and placed.y + placed.height <= high_y);
    return placed;
}

/// A `size` box centered in `window`, cut to it minus the margins: a dialog's rect.
pub fn centered(size: [2]f32, window: Rect) Rect {
    assert(size[0] > 0 and size[1] > 0);
    assert(window.width > 2 * popup_margin);
    const width = @min(size[0], window.width - 2 * popup_margin);
    const height = @min(size[1], window.height - 2 * popup_margin);
    const rect: Rect = .{
        .x = window.x + @round((window.width - width) * 0.5),
        .y = window.y + @round((window.height - height) * 0.5),
        .width = width,
        .height = height,
    };
    assert(rect.width <= window.width);
    return rect;
}

const testing = std.testing;

const screen: Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try testing.expectEqual(Rect{ .x = x, .y = y, .width = width, .height = height }, rect);
}

// Locks each side with room to spare: a 100 x 40 anchor at (200, 300) and a 120 x 80 popup go
// 2 px below (y 342), above (300 - 2 - 80 = 218), right (300 + 2 = 302), left (200 - 2 - 120 =
// 78), and at the anchor's top-left.
test "each side places beside the anchor with the gap" {
    const anchor: Rect = .{ .x = 200, .y = 300, .width = 100, .height = 40 };
    const size: [2]f32 = .{ 120, 80 };
    try expect_rect(place(anchor, size, screen, .below), 200, 342, 120, 80);
    try expect_rect(place(anchor, size, screen, .above), 200, 218, 120, 80);
    try expect_rect(place(anchor, size, screen, .right), 302, 300, 120, 80);
    try expect_rect(place(anchor, size, screen, .left), 78, 300, 120, 80);
    try expect_rect(place(anchor, size, screen, .at), 200, 300, 120, 80);
}

// Locks the flips: a 176 px list below an anchor ending at 664 would end at 842, past 716, and
// the room above (626) beats below (50), so it goes above at 632 - 2 - 176 = 454; one above an
// anchor at y 20 flips below (62); right of an anchor ending at 1200 flips left (1100 - 2 - 120
// = 978); left of one at x 40 flips right (142); `at` at (1250, 700) flips on both axes, its
// bottom-right corner on the point.
test "a side that overflows flips when the other side has more room" {
    const low: Rect = .{ .x = 300, .y = 632, .width = 168, .height = 32 };
    try expect_rect(place(low, .{ 168, 176 }, screen, .below), 300, 454, 168, 176);
    const high: Rect = .{ .x = 300, .y = 20, .width = 100, .height = 40 };
    try expect_rect(place(high, .{ 120, 80 }, screen, .above), 300, 62, 120, 80);
    const east: Rect = .{ .x = 1100, .y = 300, .width = 100, .height = 40 };
    try expect_rect(place(east, .{ 120, 80 }, screen, .right), 978, 300, 120, 80);
    const west: Rect = .{ .x = 40, .y = 300, .width = 100, .height = 40 };
    try expect_rect(place(west, .{ 120, 80 }, screen, .left), 142, 300, 120, 80);
    const corner = anchor_rect(.{ 1250, 700 });
    try expect_rect(place(corner, .{ 120, 80 }, screen, .at), 1130, 620, 120, 80);
}

// Locks the clamp: a list below an anchor at x 1220 is moved left to end 4 px inside the edge
// (1280 - 4 - 120 = 1156); an anchor too near the bottom with less room above stays below and
// is clamped up to 716 - 300 = 416; `at` near the left edge is clamped to x 4.
test "a popup is clamped inside the window margins" {
    const anchor: Rect = .{ .x = 1220, .y = 100, .width = 50, .height = 20 };
    try expect_rect(place(anchor, .{ 120, 80 }, screen, .below), 1156, 122, 120, 80);
    const low: Rect = .{ .x = 100, .y = 500, .width = 50, .height = 20 };
    // Below: 522 + 300 > 716; room above 494 > room below 194, so it flips to 198.
    try expect_rect(place(low, .{ 120, 300 }, screen, .below), 100, 198, 120, 300);
    const lower: Rect = .{ .x = 100, .y = 200, .width = 50, .height = 460 };
    // Below at 662: room below 54, room above 194: flips to 200 - 2 - 300 = -102, clamped to 4.
    try expect_rect(place(lower, .{ 120, 300 }, screen, .below), 100, 4, 120, 300);
    try expect_rect(place(anchor_rect(.{ 1, 100 }), .{ 120, 80 }, screen, .at), 4, 100, 120, 80);
}

// Locks the cut: a popup taller than the window minus its margins (712) becomes 712 tall at
// y 4, and one wider (1272) 1272 wide at x 4.
test "a popup larger than the window is cut to it" {
    const anchor: Rect = .{ .x = 200, .y = 300, .width = 100, .height = 40 };
    try expect_rect(place(anchor, .{ 120, 900 }, screen, .below), 200, 4, 120, 712);
    try expect_rect(place(anchor, .{ 2000, 80 }, screen, .right), 4, 300, 1272, 80);
    try expect_rect(centered(.{ 320, 160 }, screen), 480, 280, 320, 160);
    try expect_rect(centered(.{ 320, 900 }, screen), 480, 4, 320, 712);
}

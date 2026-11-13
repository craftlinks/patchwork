//! Scrolling views and the virtualized list: the state a view keeps between frames, its
//! scrollbar geometry, and the visible row range of a uniform list.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Division of Labour
//! `cx.begin_view(id, walk, layout, *ViewState)` and `cx.end_view()` (`ui/cx.zig`) do the
//! drawing side: they register the view's area before the children, clip the children to
//! the viewport, start the children `scroll_y` above the viewport top, measure the content
//! height at the end, and draw the thumb with its own area from that same frame's height.
//! This file owns what survives the frame (`ViewState`), the pure geometry, and the event
//! side (`ViewState.handle`). Views scroll vertically only; they read the wheel's `dy` and
//! ignore its `dx`.
//!
//! ## 2. Geometry
//! The viewport is the view's border box inset by its layout padding. The children walk in
//! the viewport narrowed on the right by `gutter_px`, which holds the thumb.
//! ```text
//! max_scroll = max(0, content_h - view_h)
//! thumb_h    = clamp(view_h * view_h / content_h, thumb_min_px, view_h)
//! thumb.y    = viewport.y + (scroll_y / max_scroll) * (view_h - thumb_h)
//! pointer:   scroll_y = clamp((pointer_y - viewport.y - thumb_h / 2) / travel, 0, 1)
//!                       * max_scroll
//! ```
//! Test "the thumb follows the offset and the pointer" locks these.
//!
//! ## 3. Events
//! A wheel resolved to the view's id adds `dy` to `scroll_y`; a press or drag on the thumb's
//! id (`view_id.derive(thumb_salt)`) maps the pointer onto the range. The offset is clamped
//! with the content height the last frame measured, so it is at most one frame stale, and
//! `begin_view` clamps again before drawing. `end_view` takes the wheel flag off the view's
//! area when this frame's content fits, so a view with nothing to scroll leaves the wheel to
//! the one around it; the wheel target resolves at the next event, after that frame.
//!
//! ## 4. Lists
//! `List.visible` turns the offset into the rows that overlap the viewport. The app skips the
//! rows above with `cx.skip(first * row_height)`, draws `first .. end`, and skips the rest,
//! so the measured content height is exact while only visible rows emit instances and areas.
//! The list's layout must have zero spacing for the skip arithmetic to hold.
//!
//! ## 5. TigerStyle Invariants
//! - Every function is O(1). `scroll_y` stays in `[0, max_scroll]` after every write.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const areas = @import("areas.zig");

pub const Rect = draw.Rect;
pub const Id = areas.Id;

/// Width of the thumb's gutter on the right of every viewport, in logical pixels.
pub const gutter_px: f32 = 16;
/// Shortest thumb, so a long content keeps a grabbable handle.
pub const thumb_min_px: f32 = 24;
/// Corner radius of the thumb face in the default form; the thumb reads the app's
/// (`scheme.form.radius.control`).
pub const thumb_radius: f32 = 4;
/// The `derive` salt of a view's thumb id.
pub const thumb_salt: u64 = 1;

/// What one view keeps between frames. The app owns it; `begin_view` writes `viewport` and
/// `end_view` writes `content_h`.
pub const ViewState = struct {
    scroll_y: f32,
    content_h: f32,
    viewport: Rect,

    pub const Action = enum {
        none,
        scrolled,
    };

    /// Scrolled to the top, before any frame measured it.
    pub fn init() ViewState {
        const state: ViewState = .{
            .scroll_y = 0,
            .content_h = 0,
            .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
        assert(state.scroll_y == 0);
        assert(state.max_scroll() == 0);
        return state;
    }

    /// The largest offset for the last measured content.
    pub fn max_scroll(self: *const ViewState) f32 {
        assert(self.content_h >= 0);
        const room = self.content_h - self.viewport.height;
        if (room > 0) return room;
        return 0;
    }

    /// Applies the wheel and thumb gestures of `event` for the view `view_id`. Marks the
    /// context for redraw and returns `scrolled` when the offset moved.
    pub fn handle(self: *ViewState, cx: anytype, view_id: Id, event: anytype) Action {
        assert(view_id != .none);
        switch (cx.hit(view_id, event)) {
            .wheel => |wheel| return self.scroll_to(cx, self.scroll_y + wheel.dy),
            else => {},
        }
        switch (cx.hit(view_id.derive(thumb_salt), event)) {
            .down => |press| return self.scroll_to(cx, self.at_pointer(press.y)),
            .drag => |press| return self.scroll_to(cx, self.at_pointer(press.y)),
            else => return .none,
        }
    }

    /// Clamps `next` to the range and stores it.
    pub fn scroll_to(self: *ViewState, cx: anytype, next: f32) Action {
        assert(next == next);
        const clamped = std.math.clamp(next, 0, self.max_scroll());
        if (clamped == self.scroll_y) return .none;
        self.scroll_y = clamped;
        cx.redraw();
        assert(self.scroll_y <= self.max_scroll());
        return .scrolled;
    }

    /// The offset that puts the thumb's center under `pointer_y`.
    pub fn at_pointer(self: *const ViewState, pointer_y: f32) f32 {
        assert(pointer_y == pointer_y);
        const view = self.viewport;
        if (!(view.height > 0)) return 0;
        if (!(self.content_h > 0)) return 0;
        const height = thumb_height(view.height, self.content_h);
        const travel = view.height - height;
        if (!(travel > 0)) return 0;
        const unit = std.math.clamp((pointer_y - view.y - height * 0.5) / travel, 0, 1);
        assert(unit >= 0);
        return unit * self.max_scroll();
    }

    /// The thumb's rect in the gutter for the current offset. Requires a scrollable content.
    pub fn thumb_rect(self: *const ViewState) Rect {
        const view = self.viewport;
        const limit = self.max_scroll();
        assert(limit > 0);
        assert(view.height > 0);
        const height = thumb_height(view.height, self.content_h);
        const travel = @max(0, view.height - height);
        const unit = std.math.clamp(self.scroll_y / limit, 0, 1);
        return .{
            .x = view.x + view.width - gutter_px,
            .y = view.y + unit * travel,
            .width = gutter_px,
            .height = height,
        };
    }
};

/// Thumb height for a viewport of `view_h` over a content of `content_h`.
pub fn thumb_height(view_h: f32, content_h: f32) f32 {
    assert(view_h > 0);
    assert(content_h > 0);
    const ratio = view_h * view_h / content_h;
    const height = std.math.clamp(ratio, @min(thumb_min_px, view_h), view_h);
    assert(height <= view_h);
    return height;
}

/// A uniform list of `count` rows of `row_height`. See the module guide, section 4.
pub const List = struct {
    row_height: f32,
    count: u32,

    /// Rows `first .. end` overlap a viewport `view_h` tall scrolled by `scroll_y`.
    pub const Range = struct {
        first: u32,
        end: u32,
    };

    pub fn visible(self: List, scroll_y: f32, view_h: f32) Range {
        assert(self.row_height > 0);
        assert(scroll_y >= 0);
        const top = @floor(scroll_y / self.row_height);
        const first: u32 = @intFromFloat(@min(top, @as(f32, @floatFromInt(self.count))));
        if (!(view_h > 0)) return .{ .first = first, .end = first };
        const bottom = @ceil((scroll_y + view_h) / self.row_height);
        const end: u32 = @intFromFloat(@min(bottom, @as(f32, @floatFromInt(self.count))));
        assert(first <= end);
        assert(end <= self.count);
        return .{ .first = first, .end = end };
    }

    /// The content height of every row.
    pub fn height(self: List) f32 {
        assert(self.row_height > 0);
        return self.row_height * @as(f32, @floatFromInt(self.count));
    }
};

const testing = std.testing;

// Locks the scrollbar formulas: thumb height, its position from the offset, the inverse
// pointer map, and the minimum height.
test "the thumb follows the offset and the pointer" {
    var state = ViewState.init();
    state.viewport = .{ .x = 8, .y = 8, .width = 304, .height = 184 };
    state.content_h = 368;
    // max_scroll = 368 - 184 = 184, thumb_h = 184 * 184 / 368 = 92, travel = 92.
    try testing.expectEqual(@as(f32, 184), state.max_scroll());
    state.scroll_y = 92;
    const thumb = state.thumb_rect();
    try testing.expectEqual(@as(f32, 92), thumb.height);
    try testing.expectEqual(@as(f32, 54), thumb.y);
    try testing.expectEqual(@as(f32, 296), thumb.x);
    try testing.expectEqual(@as(f32, 92), state.at_pointer(100));
    state.content_h = 2000;
    try testing.expectEqual(thumb_min_px, state.thumb_rect().height);
}

// Locks the visible range: the rows that overlap the viewport, partial rows included, and the
// clamps at both ends of the list.
test "the list's visible range follows the offset" {
    const list: List = .{ .row_height = 24, .count = 1000 };
    try testing.expectEqual(List.Range{ .first = 0, .end = 10 }, list.visible(0, 240));
    try testing.expectEqual(List.Range{ .first = 4, .end = 15 }, list.visible(100, 240));
    try testing.expectEqual(List.Range{ .first = 990, .end = 1000 }, list.visible(23760, 240));
    try testing.expectEqual(List.Range{ .first = 3, .end = 3 }, list.visible(72, 0));
    try testing.expectEqual(@as(f32, 24000), list.height());
}

//! `Tooltip`: one line of text beside the hovered thing after a dwell, on the tooltip layer.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Hovered
//! The app knows which widget means what, so it says what is hovered: every event it calls
//! `handle(cx, event, hovered)` with a `Tip` (the anchor id and the text) or null. A new anchor
//! restarts the dwell, an `Animator` that travels to 1 over `tooltip_delay_ms`; the tooltip
//! shows when it arrives. Only the step that shows it and the event that hides it owe a draw,
//! so the dwell frames between draw nothing, and once shown nothing animates. A press of any
//! button hides it until the anchor changes. The text is copied (at most `tooltip_text_cap`
//! bytes), so it may live in a buffer the app reuses; a different text while shown owes a draw.
//!
//! ## 2. Drawing
//! `draw_overlay(cx)` (called by `ui.overlays`) draws nothing until the tooltip shows. Then it
//! finds the anchor's area of this frame, moves that rect by `offset`, and places a box with
//! `popup.place` on `side` (`.right` by default, flipping) inside `bounds` (null for the
//! window): `size` when set, else the text's width plus `tooltip_pad_x` on each side by one
//! line plus `tooltip_pad_y`. On `Layer.tooltip` it hands the skin a `TooltipLook` (the box,
//! the window clip, the text, and `fill`), and the skin draws the face and the text:
//! `TooltipOf(Skin)` is skinnable like `MenuOf`. `Default.tooltip` draws a face in `fill` or
//! the scheme's `panel`, with a `hairline` border in `text` and `radius.popup` corners
//! (`theme.Form`), then the text in the scheme's `name` style, centered in the box. The
//! tooltip records no area, so it never takes the hover from what it describes.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the text is an inline copy; `draw_overlay` reads the state.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Id = kit.Id;
const Rect = kit.Rect;
const popup = ui.popup;

/// Hover time before a tooltip shows.
pub const tooltip_delay_ms: f32 = 500;

/// Space left and right of the text, and above and below its line.
pub const tooltip_pad_x: f32 = 8;
pub const tooltip_pad_y: f32 = 4;

/// One line's height as a multiple of the text size.
pub const tooltip_line_ratio: f32 = 1.5;

/// Bytes of text a tooltip keeps.
pub const tooltip_text_cap: u32 = 64;

/// What the app says is hovered: the anchor's id and the text to show beside it.
pub const Tip = struct {
    anchor: Id,
    text: []const u8,
};

/// The default tooltip: `TooltipOf(skins.Default)`.
pub const Tooltip = TooltipOf(skin.Default);

/// A tooltip drawn by `Skin` (`Skin.tooltip`; `widgets/skin.zig`).
pub fn TooltipOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .tooltip)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        /// The hovered anchor, `.none` when nothing is.
        anchor: Id,
        bytes: [tooltip_text_cap]u8,
        len: u32,
        dwell: animator.Animator,
        /// A press hid the tooltip until the anchor changes.
        hidden: bool,
        /// Where the box goes beside the anchor (section 2).
        side: popup.Side,
        /// Added to the anchor's position before placing.
        offset: [2]f32,
        /// A fixed box size, or null for the text's.
        size: ?[2]f32,
        /// The face's fill, or null for the skin's own (the default skin's: the scheme's
        /// `panel`).
        fill: ?[4]f32,
        /// The rect the box stays inside; null is the window.
        bounds: ?Rect,

        /// Nothing hovered, placed to the right of its anchor.
        pub fn init() Self {
            const tooltip: Self = .{
                .anchor = .none,
                .bytes = @splat(0),
                .len = 0,
                .dwell = .init(1.0 / tooltip_delay_ms),
                .hidden = false,
                .side = .right,
                .offset = .{ 0, 0 },
                .size = null,
                .fill = null,
                .bounds = null,
            };
            assert(!tooltip.visible());
            return tooltip;
        }

        /// True while the tooltip shows.
        pub fn visible(self: *const Self) bool {
            assert(self.len <= tooltip_text_cap);
            if (self.anchor == .none or self.hidden) return false;
            return self.dwell.value == 1;
        }

        /// The text it shows.
        pub fn text_of(self: *const Self) []const u8 {
            assert(self.len <= tooltip_text_cap);
            return self.bytes[0..self.len];
        }

        /// Follows what the app says is hovered and times the dwell (section 1).
        pub fn handle(self: *Self, cx: anytype, event: input.Event, hovered: ?Tip) void {
            const next: Id = if (hovered) |tip| tip.anchor else .none;
            const was_visible = self.visible();
            if (next != self.anchor) {
                self.anchor = next;
                self.hidden = false;
                self.dwell = .init(1.0 / tooltip_delay_ms);
                if (next != .none) {
                    const aimed = self.dwell.set_target(1);
                    assert(aimed);
                    cx.keep_animating();
                }
                if (was_visible) cx.redraw();
            }
            if (hovered) |tip| {
                const length: u32 = @intCast(@min(tip.text.len, tooltip_text_cap));
                const same = std.mem.eql(u8, self.bytes[0..self.len], tip.text[0..length]);
                if (!same) {
                    @memcpy(self.bytes[0..length], tip.text[0..length]);
                    self.len = length;
                    if (self.visible()) cx.redraw();
                }
            }
            if (event == .pointer_down and self.anchor != .none and !self.hidden) {
                const showing = self.visible();
                self.hidden = true;
                if (showing) cx.redraw();
            }
            if (event == .frame and self.anchor != .none and !self.hidden) {
                const before = self.visible();
                _ = self.dwell.step(event.frame);
                if (self.dwell.live()) cx.keep_animating();
                if (!before and self.visible()) cx.redraw();
            }
            assert(self.anchor == next);
        }

        /// The box beside `anchor` (an area's rect) for `style` (section 2).
        pub fn box_of(self: *const Self, anchor: Rect, style: text.Style, window: Rect) Rect {
            assert(style.size > 0);
            const size = self.size orelse [2]f32{
                @ceil(text.measure(style, self.text_of())) + 2 * tooltip_pad_x,
                @ceil(style.size * tooltip_line_ratio) + 2 * tooltip_pad_y,
            };
            const moved: Rect = .{
                .x = anchor.x + self.offset[0],
                .y = anchor.y + self.offset[1],
                .width = anchor.width,
                .height = anchor.height,
            };
            return popup.place(moved, size, window, self.side);
        }

        /// Draws the shown tooltip on `Layer.tooltip` (section 2). `ui.overlays` calls it.
        pub fn draw_overlay(self: *const Self, cx: anytype) void {
            assert(cx.depth == 1);
            if (!self.visible()) return;
            const found = cx.find(self.anchor) orelse return;
            const anchor: Rect = .{
                .x = found.rect[0],
                .y = found.rect[1],
                .width = found.rect[2],
                .height = found.rect[3],
            };
            const scheme = cx.theme();
            const box = self.box_of(anchor, scheme.name, self.bounds orelse cx.window);
            const window = cx.clip().?;
            const previous = cx.draw.layer(.tooltip);
            defer _ = cx.draw.layer(previous);
            Skin.tooltip(cx, .{
                .rect = box,
                .clip = window,
                .label = self.text_of(),
                .fill = self.fill,
            });
            assert(cx.draw.layer_now == .tooltip);
        }
    };
}

const testing = std.testing;
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

fn hover_frame(cx: *fixture.Context, tooltip: anytype) void {
    cx.begin_frame(1280, 720, 120);
    cx.area(ui.id("knob", 0), .{ .x = 100, .y = 100, .width = 56, .height = 56 }, 0, ui.cx.plain);
    ui.overlays(cx, tooltip);
    _ = cx.end_frame();
}

fn step(cx: *fixture.Context, tooltip: anytype, event: input.Event, tip: ?Tip) void {
    cx.event_begin(event);
    tooltip.handle(cx, event, tip);
    cx.event_end();
}

// Locks the dwell (section 1): hovered, it is not shown after 480 ms and shown at 500, the
// step that shows it owes a draw and stops animating; it draws on the tooltip layer to the
// right of the 56 px anchor at (100, 100) with no area; a press hides it until the anchor
// changes, and a new anchor restarts the dwell.
test "a tooltip shows after its dwell and hides on a press" {
    const cx = fixture.context();
    var tooltip = Tooltip.init();
    const tip: Tip = .{ .anchor = ui.id("knob", 0), .text = "gain 0.63" };
    hover_frame(cx, &tooltip);
    step(cx, &tooltip, .{ .pointer_move = .{ .x = 120, .y = 120 } }, tip);
    try testing.expect(cx.animating);
    cx.animating = false;
    cx.dirty = false;
    step(cx, &tooltip, .{ .frame = 480 }, tip);
    try testing.expect(!tooltip.visible());
    try testing.expect(cx.animating);
    try testing.expect(!cx.dirty);
    cx.animating = false;
    step(cx, &tooltip, .{ .frame = 20 }, tip);
    try testing.expect(tooltip.visible());
    try testing.expect(cx.dirty);
    try testing.expect(!cx.animating);
    hover_frame(cx, &tooltip);
    try testing.expectEqual(@as(usize, 1), cx.area_list().len);
    const boxes = cx.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    try testing.expectEqual(@as(f32, 100 + 56 + popup.popup_gap), boxes[0].rect[0]);
    try testing.expectEqual(@as(f32, 100), boxes[0].rect[1]);
    try testing.expectEqual(@as(f32, 32), boxes[0].rect[3]);
    try testing.expectEqual(draw.Layer.tooltip, cx.draw.layer_at(draw.Box, 0));
    try testing.expectEqual(draw.Layer.base, cx.draw.layer_now);
    cx.dirty = false;
    step(cx, &tooltip, .{ .pointer_down = input.left_at(.{ .x = 120, .y = 120 }) }, tip);
    try testing.expect(!tooltip.visible());
    try testing.expect(cx.dirty);
    step(cx, &tooltip, .{ .frame = 600 }, tip);
    try testing.expect(!tooltip.visible());
    step(cx, &tooltip, .{ .pointer_move = .{ .x = 900, .y = 900 } }, null);
    try testing.expectEqual(Id.none, tooltip.anchor);
    step(cx, &tooltip, .{ .pointer_move = .{ .x = 120, .y = 120 } }, tip);
    step(cx, &tooltip, .{ .frame = 500 }, tip);
    try testing.expect(tooltip.visible());
}

/// A skin whose tooltip is one red Box over the look's rect, and which keeps the look.
const Fixed = struct {
    var last: ?skin.TooltipLook = null;

    pub fn tooltip(cx: anytype, look: skin.TooltipLook) void {
        assert(look.label.len <= tooltip_text_cap);
        last = look;
        kit.face(cx, look.rect, look.clip, .{ .fill = .{ 1, 0, 0, 1 } });
    }
};

// Locks the skin call (section 2): after the dwell over the 56 px anchor at (100, 100), a
// `TooltipOf(Fixed)` hands its skin the placed box (100 + 56 + `popup_gap`, 100, w, 32), the
// text "gain 0.63", and no fill (then the app's fill once set); the skin's one Box is on
// `Layer.tooltip`, the layer is back to `base` after, and the only area is the anchor's.
test "a skinned tooltip draws what its skin draws" {
    const cx = fixture.context();
    var tooltip = TooltipOf(Fixed).init();
    const tip: Tip = .{ .anchor = ui.id("knob", 0), .text = "gain 0.63" };
    Fixed.last = null;
    hover_frame(cx, &tooltip);
    step(cx, &tooltip, .{ .pointer_move = .{ .x = 120, .y = 120 } }, tip);
    step(cx, &tooltip, .{ .frame = 500 }, tip);
    try testing.expect(tooltip.visible());
    hover_frame(cx, &tooltip);
    const look = Fixed.last.?;
    try testing.expectEqual(@as(f32, 100 + 56 + popup.popup_gap), look.rect.x);
    try testing.expectEqual(@as(f32, 100), look.rect.y);
    try testing.expectEqual(@as(f32, 32), look.rect.height);
    try testing.expect(look.rect.width > 0);
    try testing.expectEqualStrings("gain 0.63", look.label);
    try testing.expect(look.fill == null);
    const boxes = cx.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, boxes[0].fill);
    try testing.expectEqual(draw.Layer.tooltip, cx.draw.layer_at(draw.Box, 0));
    try testing.expectEqual(draw.Layer.base, cx.draw.layer_now);
    try testing.expectEqual(@as(usize, 1), cx.area_list().len);
    tooltip.fill = .{ 0.2, 0.3, 0.4, 1 };
    hover_frame(cx, &tooltip);
    try testing.expectEqual([4]f32{ 0.2, 0.3, 0.4, 1 }, Fixed.last.?.fill.?);
}

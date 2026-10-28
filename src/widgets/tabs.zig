//! `Tabs`: a bar of tabs over a page, and the selected tab's index. The app draws the page.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! Tabs keep the turtle's begin/end shape and own no page: `begin(cx, walk, layout)` draws the
//! bar at the top of the box `walk` gets and opens a container for the page under it, which
//! the caller closes with `cx.end()`, as with `Panel.begin`. The app draws the selected page
//! with a `switch` on `selected`; the tabs never call back.
//! ```text
//! _ = tabs.begin(cx, walk, layout)      bar (tab_bar_h) + an open page container
//! switch (tabs.selected) { 0 => page_0(cx), 1 => page_1(cx), ... }
//! _ = cx.end()
//! ```
//!
//! ## 2. Bar Geometry
//! Tabs are left-aligned, `tab_gap` apart, each `ceil(measure(label)) + 2 * tab_pad_x` wide
//! in the scheme's name style. When they do not fit the bar they shrink evenly: each round
//! takes an equal share of what is still too wide from every tab above its floor
//! (`tab_min_w`, or its natural width if smaller), at most `tabs_max` rounds; a label wider
//! than its tab is cut with an ellipsis. Tabs that do not fit even at their floors run past
//! the bar and are clipped by it. Each tab is `tab_bar_h - tab_line_px` high, so the bar's
//! bottom line shows under them. Test "tab widths shrink evenly to their floors" locks it.
//!
//! ## 2a. Arrangements and the Bar Alone
//! The skin picks the arrangement: an optional `pub const tab_arrange: widgets.TabArrange`,
//! read at compile time (`natural` without it), as a slider's skin owns its travel. `natural`
//! is section 2. `even` is a segmented control: the tabs fill the bar inset by
//! `segment_inset` on every side, `tab_gap` apart, in equal whole-pixel widths with the
//! remainder given one pixel at a time from the first (`even_widths`). `bar(cx, walk)` draws
//! the bar in the whole box `walk` gets and opens no page, so the caller draws nothing under
//! it and calls no `cx.end()`; `widgets.Segmented` is `TabsOf(skins.Segmented)`, which
//! arranges `even` and draws a track with the selected segment raised.
//!
//! ## 3. Events
//! The bar is a focusable area (`id`) under the tabs (`id.derive(index)`).
//! ```text
//! tab hover_in / hover_out   hover follows (redraw)
//! tab down                   focus the bar; changed when a different tab
//! Left / Right               previous / next tab, wrapping           (bar focused)
//! Ctrl+Tab / Ctrl+Shift+Tab  next / previous tab, wrapping           (bar focused)
//! ```
//! Ctrl+Tab never moves focus (`ui/cx.zig`, section 7), so the bar keeps it.
//!
//! ## 4. Drawing
//! `TabsOf(Skin)` hands `Skin.tab_bar` a `TabBarLook`, then `Skin.tab` a `TabLook` per tab,
//! recording the shape each tab returns; `Tabs` is `TabsOf(skins.Default)`: a line along the
//! bar's bottom (the focus color while focused), tabs in `colors.track`, the selected one in
//! `colors.panel` with a 2 px accent underline.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: labels are app-owned, at most `tabs_max`; widths live on the stack.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// Tabs one bar holds at most.
pub const tabs_max: u32 = 16;

/// The bar's height, in logical pixels.
pub const tab_bar_h: f32 = 32;

/// Space left and right of a tab's label.
pub const tab_pad_x: f32 = 16;

/// The narrowest a tab shrinks to.
pub const tab_min_w: f32 = 48;

/// Space between two tabs.
pub const tab_gap: f32 = 2;

/// The default look's corner radius, its bar line, and the selected tab's underline.
pub const tab_radius: f32 = 4;
pub const tab_line_px: f32 = 1;
pub const tab_underline_px: f32 = 2;

/// How a bar lays out its tabs (section 2a); a skin picks one with `tab_arrange`.
pub const TabArrange = enum { natural, even };

/// An `even` bar's inset around its tabs, and the space left and right of their labels.
pub const segment_inset: f32 = 3;
pub const segment_pad_x: f32 = 6;

/// Labels are centered and cut with an ellipsis when the tab shrank.
pub const tab_text_options: text.Options = .{
    .align_x = .center,
    .align_y = .center,
    .ellipsis = true,
};

/// The bar takes presses and focus.
pub const tabs_flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = false,
    .cursor = .default,
};

/// The default tabs: `TabsOf(skins.Default)`.
pub const Tabs = TabsOf(skin.Default);

/// The width of a tab whose label is `label` in `style` (section 2).
pub fn natural_width(style: text.Style, label: []const u8) f32 {
    assert(label.len <= text.byte_cap);
    const width = @ceil(text.measure(style, label)) + 2 * tab_pad_x;
    assert(width >= 2 * tab_pad_x);
    return width;
}

/// Writes the widths of tabs whose natural widths are `natural` into `out`, shrunk evenly to
/// fit `room` with `tab_gap` between them (section 2), each rounded to a whole pixel.
pub fn tab_widths(natural: []const f32, room: f32, out: []f32) void {
    assert(natural.len >= 1 and natural.len <= tabs_max);
    assert(out.len == natural.len);
    const count: f32 = @floatFromInt(natural.len);
    var excess = (count - 1) * tab_gap - room;
    for (natural, out) |width, *slot| {
        assert(width > 0);
        slot.* = width;
        excess += width;
    }
    var round: u32 = 0;
    while (excess > 0 and round < tabs_max) : (round += 1) {
        var active: f32 = 0;
        for (natural, out) |width, slot| {
            if (slot > @min(width, tab_min_w)) active += 1;
        }
        if (active == 0) break;
        const share = excess / active;
        for (natural, out) |width, *slot| {
            const floor = @min(width, tab_min_w);
            if (!(slot.* > floor)) continue;
            const cut = @min(share, slot.* - floor);
            slot.* -= cut;
            excess -= cut;
        }
    }
    for (natural, out) |width, *slot| {
        slot.* = @round(slot.*);
        assert(slot.* <= width);
        assert(slot.* >= @min(width, tab_min_w) - 0.5);
    }
}

/// Writes `out.len` equal whole-pixel widths that fill `room` with `tab_gap` between them,
/// the remainder one pixel each from the first (section 2a).
pub fn even_widths(room: f32, out: []f32) void {
    assert(out.len >= 1 and out.len <= tabs_max);
    assert(room >= 0);
    const count: f32 = @floatFromInt(out.len);
    const free = @max(0, @floor(room - (count - 1) * tab_gap));
    const base = @floor(free / count);
    var extra = free - base * count;
    for (out) |*width| {
        width.* = base + @as(f32, if (extra > 0) 1 else 0);
        extra -= 1;
    }
    assert(out[0] - out[out.len - 1] <= 1);
    assert(out[0] >= base);
}

/// A bar of tabs drawn by `Skin` (`Skin.tab_bar`, `Skin.tab`; `widgets/skin.zig`).
pub fn TabsOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .tabs)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        /// The skin's arrangement (section 2a).
        pub const arrange: TabArrange = if (@hasDecl(Skin, "tab_arrange"))
            Skin.tab_arrange
        else
            .natural;

        id: Id,
        labels: []const []const u8,
        selected: u32,
        /// The tab under the pointer.
        hover: ?u32,

        pub const Action = union(enum) {
            none,
            /// A different tab was selected; its index.
            changed: u32,
        };

        /// Tabs over `labels` (1 to `tabs_max`) with `selected` selected.
        pub fn init(id: Id, labels: []const []const u8, selected: u32) Self {
            assert(id != .none);
            assert(labels.len >= 1 and labels.len <= tabs_max);
            assert(selected < labels.len);
            return .{ .id = id, .labels = labels, .selected = selected, .hover = null };
        }

        /// Tab `index`'s id.
        pub fn tab_id(self: *const Self, index: u32) Id {
            assert(index < self.labels.len);
            return self.id.derive(index);
        }

        /// Draws the bar at the top of the box `walk` gets (fixed or fill on both axes) and
        /// opens the page container under it, laid out by `layout`; the caller closes it with
        /// `cx.end()`. Returns the page's rect. Draw phase.
        pub fn begin(self: *const Self, cx: anytype, walk: Walk, layout: ui.Layout) Rect {
            assert(walk.width != .fit and walk.height != .fit);
            assert(self.selected < self.labels.len);
            const rect = cx.peek(walk);
            const strip: Rect = .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = @min(tab_bar_h, rect.height),
            };
            if (cx.visible(strip)) |clip| self.draw_bar(cx, strip, clip);
            var page_layout = layout;
            page_layout.padding.top += strip.height;
            const opened = cx.begin(walk, page_layout);
            assert(opened.x == rect.x and opened.y == rect.y);
            return .{
                .x = rect.x,
                .y = rect.y + strip.height,
                .width = rect.width,
                .height = rect.height - strip.height,
            };
        }

        /// Draws the bar alone in the whole box `walk` gets, with no page under it (section
        /// 2a): a segmented control. Draw phase.
        pub fn bar(self: *const Self, cx: anytype, walk: Walk) void {
            assert(walk.width != .fit and walk.height != .fit);
            assert(self.selected < self.labels.len);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            self.draw_bar(cx, rect, clip);
        }

        fn draw_bar(self: *const Self, cx: anytype, strip: Rect, clip: kit.Clip) void {
            assert(strip.width > 0 and strip.height > 0);
            cx.area(self.id, strip, 0, tabs_flags);
            Skin.tab_bar(cx, .{ .rect = strip, .clip = clip, .focused = cx.focused(self.id) });
            const style = cx.theme().name;
            var natural: [tabs_max]f32 = undefined;
            var widths: [tabs_max]f32 = undefined;
            const count = self.labels.len;
            const inset: f32 = if (arrange == .even) segment_inset else 0;
            if (arrange == .even) {
                even_widths(@max(0, strip.width - 2 * inset), widths[0..count]);
            } else {
                for (self.labels, natural[0..count]) |label, *width| {
                    width.* = natural_width(style, label);
                }
                tab_widths(natural[0..count], strip.width, widths[0..count]);
            }
            const height = if (arrange == .even)
                strip.height - 2 * inset
            else
                strip.height - tab_line_px;
            var x = strip.x + inset;
            for (self.labels, widths[0..count], 0..) |label, width, index| {
                const at: u32 = @intCast(index);
                const tab: Rect = .{
                    .x = x,
                    .y = strip.y + inset,
                    .width = width,
                    .height = @max(0, height),
                };
                x += width + tab_gap;
                if (!(tab.width > 0) or !(tab.height > 0)) continue;
                const inside = cx.visible(tab) orelse continue;
                const shape = Skin.tab(cx, .{
                    .rect = tab,
                    .clip = inside,
                    .label = label,
                    .selected = at == self.selected,
                    .hovered = self.hover != null and self.hover.? == at,
                }) orelse continue;
                cx.area(self.tab_id(at), shape.rect, shape.radius, ui.cx.plain);
            }
        }

        /// Presses, hover, and keys (section 3).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.selected < self.labels.len);
            if (event == .frame) return .none;
            if (event == .key_down) {
                if (!cx.focused(self.id)) return .none;
                return self.key(cx, event.key_down);
            }
            var action: Action = .none;
            for (0..self.labels.len) |index| {
                const at: u32 = @intCast(index);
                switch (cx.hit(self.tab_id(at), event)) {
                    .hover_in => self.hover_tab(cx, at),
                    .hover_out => if (self.hover == at) self.hover_tab(cx, null),
                    .down => {
                        cx.set_focus(self.id);
                        action = self.select(cx, at);
                    },
                    .none, .drag, .up, .wheel, .secondary => {},
                }
            }
            return action;
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(cx.focused(self.id));
            const count: u32 = @intCast(self.labels.len);
            const next = (self.selected + 1) % count;
            const previous = (self.selected + count - 1) % count;
            return switch (press.key) {
                .right => self.select(cx, next),
                .left => self.select(cx, previous),
                .tab => {
                    if (!press.mods.ctrl) return .none;
                    return self.select(cx, if (press.mods.shift) previous else next);
                },
                else => .none,
            };
        }

        fn select(self: *Self, cx: anytype, index: u32) Action {
            assert(index < self.labels.len);
            if (index == self.selected) return .none;
            self.selected = index;
            cx.redraw();
            return .{ .changed = index };
        }

        fn hover_tab(self: *Self, cx: anytype, index: ?u32) void {
            if (std.meta.eql(self.hover, index)) return;
            self.hover = index;
            cx.redraw();
        }
    };
}

comptime {
    assert(tab_min_w >= 2 * tab_pad_x);
    assert(tab_bar_h > tab_underline_px + tab_line_px);
    assert(tabs_max <= 32);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const theme = @import("../theme.zig");
const fixture = @import("fixture.zig");

// Locks section 2: natural widths 80, 120, and 60 with two 2 px gaps fit a 300 px bar as they
// are; in 202 px (198 of tabs) round one takes 20.67 from each but the third stops at its
// 48 px floor (cut 12), round two takes the remaining 8.67 from the other two: 55, 95, 48. In
// 100 px every tab is at its floor and they run past the bar; a 40 px tab keeps its width.
test "tab widths shrink evenly to their floors" {
    const natural = [_]f32{ 80, 120, 60 };
    var out: [3]f32 = undefined;
    tab_widths(&natural, 300, &out);
    try testing.expectEqual([3]f32{ 80, 120, 60 }, out);
    tab_widths(&natural, 202, &out);
    try testing.expectEqual([3]f32{ 55, 95, 48 }, out);
    tab_widths(&natural, 100, &out);
    try testing.expectEqual([3]f32{ 48, 48, 48 }, out);
    const small = [_]f32{ 40, 200 };
    var pair: [2]f32 = undefined;
    tab_widths(&small, 102, &pair);
    try testing.expectEqual([2]f32{ 40, 60 }, pair);
}

const tab_labels = [_][]const u8{ "basics", "popups", "containers" };

/// Draws `tabs` over a 600 x 300 box at (0, 0) with a box on the page; returns the page rect.
fn draw_tabs(cx: *fixture.Context, tabs: *const Tabs) Rect {
    cx.begin_frame(1280, 720, 120);
    const page = tabs.begin(cx, fixture.at(0, 0, 600, 300), .{ .flow = .down });
    const filler = cx.walk(ui.sized(.fill, .{ .fixed = 10 }));
    kit.face(cx, filler, cx.clip().?, .{ .fill = .{ 1, 0, 0, 1 } });
    _ = cx.end();
    _ = cx.end_frame();
    return page;
}

fn tab_center(cx: *fixture.Context, tabs: anytype, index: u32) input.Point {
    const area = cx.find(tabs.tab_id(index)).?;
    return .{ .x = area.rect[0] + area.rect[2] * 0.5, .y = area.rect[1] + area.rect[3] * 0.5 };
}

// Locks the bar (sections 2 and 4): the page starts under the 32 px bar and its content walks
// there; the tabs sit left-aligned 2 px apart at their natural widths, 31 px high; the
// selected tab draws its face and accent underline; the bar is a focusable area.
test "tabs lay out the bar and open the page under it" {
    const cx = fixture.context();
    const tabs = Tabs.init(ui.id("tabs", 0), &tab_labels, 0);
    const page = draw_tabs(cx, &tabs);
    try testing.expectEqual(Rect{ .x = 0, .y = 32, .width = 600, .height = 268 }, page);
    const style = theme.dark.name;
    var x: f32 = 0;
    for (0..tab_labels.len) |index| {
        const area = cx.find(tabs.tab_id(@intCast(index))).?;
        const width = natural_width(style, tab_labels[index]);
        try testing.expectEqualSlices(f32, &.{ x, 0, width, 31 }, &area.rect);
        x += width + tab_gap;
    }
    try testing.expect(cx.find(tabs.id).?.flags.focusable);
    const boxes = cx.draw.items(draw.Box);
    // The bar line, tab 0 and its underline, tabs 1 and 2, then the page's box at y 32.
    try testing.expectEqual(@as(usize, 6), boxes.len);
    try testing.expectEqual(theme.dark.accents[0], boxes[2].fill);
    try testing.expectEqual(@as(f32, 29), boxes[2].rect[1]);
    try testing.expectEqual(@as(f32, 32), boxes[5].rect[1]);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the events of section 3: a press on a different tab changes it and focuses the bar,
// the same tab again does nothing, Right and Left wrap, Ctrl+Tab and Ctrl+Shift+Tab move
// while focused, keys without focus do nothing, and hover follows the pointer.
test "tabs change on a press and on keys while focused" {
    const cx = fixture.context();
    var tabs = Tabs.init(ui.id("tabs", 0), &tab_labels, 0);
    _ = draw_tabs(cx, &tabs);
    const right = input.key_press(.right, .none, false, "");
    try testing.expectEqual(Tabs.Action.none, fixture.send(cx, &tabs, .{ .key_down = right }));
    const two = tab_center(cx, &tabs, 2);
    _ = fixture.send(cx, &tabs, .{ .pointer_move = two });
    try testing.expectEqual(@as(?u32, 2), tabs.hover);
    const changed = fixture.send(cx, &tabs, .{ .pointer_down = input.left_at(two) });
    try testing.expectEqual(Tabs.Action{ .changed = 2 }, changed);
    try testing.expect(cx.focused(tabs.id));
    _ = fixture.send(cx, &tabs, .{ .pointer_up = input.left_at(two) });
    _ = draw_tabs(cx, &tabs);
    const again = fixture.send(cx, &tabs, .{ .pointer_down = input.left_at(two) });
    try testing.expectEqual(Tabs.Action.none, again);
    _ = fixture.send(cx, &tabs, .{ .pointer_up = input.left_at(two) });
    const to_0: Tabs.Action = .{ .changed = 0 };
    const to_2: Tabs.Action = .{ .changed = 2 };
    try testing.expectEqual(to_0, fixture.send(cx, &tabs, .{ .key_down = right }));
    const left = input.key_press(.left, .none, false, "");
    try testing.expectEqual(to_2, fixture.send(cx, &tabs, .{ .key_down = left }));
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    const next = input.key_press(.tab, ctrl, false, "");
    try testing.expectEqual(to_0, fixture.send(cx, &tabs, .{ .key_down = next }));
    try testing.expect(cx.focused(tabs.id));
    ctrl.shift = true;
    const back = input.key_press(.tab, ctrl, false, "");
    try testing.expectEqual(to_2, fixture.send(cx, &tabs, .{ .key_down = back }));
    _ = fixture.send(cx, &tabs, .pointer_leave);
    try testing.expectEqual(@as(?u32, null), tabs.hover);
}

// Locks routing: `ui.route` reaches a `Tabs` field, which reports the change it made.
test "tabs route" {
    const cx = fixture.context();
    const Holder = struct { tabs: Tabs };
    var holder: Holder = .{ .tabs = Tabs.init(ui.id("tabs", 0), &tab_labels, 0) };
    _ = draw_tabs(cx, &holder.tabs);
    const one = tab_center(cx, &holder.tabs, 1);
    const down: input.Event = .{ .pointer_down = input.left_at(one) };
    cx.event_begin(down);
    try testing.expectEqual(@as(u32, 1), ui.route(cx, down, &holder));
    cx.event_end();
    try testing.expectEqual(@as(u32, 1), holder.tabs.selected);
}

// Locks `even_widths` (section 2a): 234 px for three tabs leaves 230 after two 2 px gaps,
// 76 each and 2 over, so 77, 77, 76; a room too small for the gaps gives zero widths.
test "even widths fill the room with the remainder first" {
    var out: [3]f32 = undefined;
    even_widths(234, &out);
    try testing.expectEqual([3]f32{ 77, 77, 76 }, out);
    even_widths(10, &out);
    try testing.expectEqual([3]f32{ 2, 2, 2 }, out);
    even_widths(3, &out);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, out);
}

// Locks the segmented control (section 2a): `bar` draws in the whole 240 x 32 box with no
// page; the segments sit 3 px in, 77, 77, and 76 wide and 26 high, 2 px apart, each a capsule
// hit shape; the track and the selected segment are the two boxes; Right selects the next.
test "a segmented bar draws alone with even segments" {
    const Segmented = TabsOf(skin.Segmented);
    try testing.expectEqual(TabArrange.even, Segmented.arrange);
    try testing.expectEqual(TabArrange.natural, Tabs.arrange);
    const cx = fixture.context();
    var segmented = Segmented.init(ui.id("segments", 0), &tab_labels, 1);
    cx.begin_frame(1280, 720, 120);
    segmented.bar(cx, fixture.at(0, 0, 240, 32));
    _ = cx.end_frame();
    const xs = [_]f32{ 3, 82, 161 };
    const ws = [_]f32{ 77, 77, 76 };
    for (xs, ws, 0..) |x, width, index| {
        const area = cx.find(segmented.tab_id(@intCast(index))).?;
        try testing.expectEqualSlices(f32, &.{ x, 3, width, 26 }, &area.rect);
        try testing.expectEqual(@as(f32, 13), area.radius);
    }
    try testing.expectEqual(@as(usize, 2), cx.draw.items(draw.Box).len);
    try testing.expectEqual(theme.dark.colors.panel, cx.draw.items(draw.Box)[1].fill);
    const two = tab_center(cx, &segmented, 2);
    _ = fixture.send(cx, &segmented, .{ .pointer_down = input.left_at(two) });
    try testing.expectEqual(@as(u32, 2), segmented.selected);
    const right = input.key_press(.right, .none, false, "");
    const wrapped = fixture.send(cx, &segmented, .{ .key_down = right });
    try testing.expectEqual(Segmented.Action{ .changed = 0 }, wrapped);
}

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
//! ## 2b. Close Buttons
//! A `closable` tab is `closable_width` wide: its natural width with the close button, its gap,
//! and its inset in place of the right padding. The button (`close_rect`) is `tab_close_w`
//! square, `tab_close_inset` from the tab's right, centred; the label is centred between
//! `tab_pad_x` and `tab_close_gap` before it. Shrinking is unchanged.
//!
//! ## 3. Events
//! The bar is a focusable area (`id`) under the tabs (`id.derive(key)`, section 3c), and a
//! closable tab's button is `tab_id(i).derive(close_salt)`, recorded after its tab.
//! ```text
//! tab hover_in / hover_out   hover follows (redraw)
//! tab down                   focus the bar; changed when a different tab
//! Left / Right               previous / next tab, wrapping           (bar focused)
//! Ctrl+Tab / Ctrl+Shift+Tab  next / previous tab, wrapping           (bar focused)
//! ```
//! Ctrl+Tab never moves focus (`ui/cx.zig`, section 7), so the bar keeps it.
//!
//! ## 3a. Closing
//! ```text
//! close button down, up inside       closed i
//! middle press over tab i            closed i   (reads `cx.hovered()`: no new `Hit` arm)
//! ```
//!
//! ## 3b. Moving
//! A `movable` bar's tabs move, and the bar is flagged `drag_target`, so it takes drags between
//! widgets (`ui/cx.zig`, section 7b):
//! ```text
//! tab down                           grab = { key, the press's offset in the tab, its size }
//! grabbed tab drag, inside the band  to = insertion(the other tabs, x); to != i: moved { i, to }
//! grabbed tab drag, outside it       cx.drag_begin(tab_id(i), key): the tab leaves as a drag
//! bar dropped, its own tab           moved { i, insertion(the others, x) }, unless unchanged
//! bar dropped, any other payload     received { payload, insertion(all, x) }; selects it
//! own tab's drag ended elsewhere     dragged_out i
//! ```
//! The band is the bar's rect at the last draw widened by `tab_detach_px` above and below, not
//! to the sides, so a tab dragged off the bar's end onto a bar beside it leaves. `insertion`
//! counts the tabs whose centre (from their areas at the last draw) lies left of the pointer;
//! after a swap the neighbour's centre is on the pointer's far side, so it cannot oscillate.
//! While a drag is over the bar, `draw` passes the skin `insert_x`, the gap that count names;
//! while this bar's tab is dragged, `draw` draws its ghost on `Layer.tooltip` at the pointer
//! less the grab's offset, with no area, and the tab itself stays in its slot: a cancel
//! (Escape, the pointer leaving) puts nothing anywhere. Both come from `cx.dragging()` and
//! `cx.drag_hovering(id)`, so the bar keeps no drag state but `grab`.
//!
//! ## 3c. Keys and Ownership
//! `labels` and `keys` are the app's arrays. `init` keys tabs by index (ids as before);
//! `init_keyed` takes distinct `u64` keys, so a tab keeps its id, and a held press its
//! capture, when it moves; `movable` needs them. The bar never writes the arrays: it adjusts
//! `selected` as if the app applied each action, and the app updates its arrays and calls `set`
//! before the next draw:
//! ```text
//! closed i, dragged_out i   remove_item; selected - 1 below i, min(i, count - 2) at i
//! moved { from, to }        move_item;   selected follows the tab or shifts across it
//! received { payload, i }   insert_item; selected = i (an app that refuses sets it back)
//! ```
//! A bar may be empty: it draws its strip and, when movable, takes drops at index 0.
//!
//! ## 4. Drawing
//! `TabsOf(Skin)` hands `Skin.tab_bar` a `TabBarLook`, then `Skin.tab` a `TabLook` per tab,
//! recording the shape each tab returns; `Tabs` is `TabsOf(skins.Default)`: a line along the
//! bar's bottom (the focus color while focused), tabs in `colors.track`, the selected one in
//! `colors.panel` with a 2 px accent underline. The looks carry the insertion gap
//! (`insert_x`), a tab's close button and its hover, and `ghost`, all defaulted, so a skin
//! that ignores them still compiles: Default draws a 2 px focus marker, a "×", and the ghost
//! at 95 % opacity.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: labels and keys are app-owned, at most `tabs_max`; widths, rects, and
//!   the insertion scan live on the stack, so a drag event is O(tabs_max) plus `cx.find`.

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

/// A closable tab's close button: its side, its inset from the tab's right, and the gap
/// between it and the label (section 2b).
pub const tab_close_w: f32 = 16;
pub const tab_close_inset: f32 = 8;
pub const tab_close_gap: f32 = 4;

/// How far above and below its bar a movable tab may be dragged before it leaves the bar as
/// a drag between widgets (section 3b).
pub const tab_detach_px: f32 = 24;

/// The `derive` salt of a tab's close button id: "close".
pub const close_salt: u64 = 0x636c6f7365 << 24;

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

/// The width of a closable tab whose label is `label` in `style` (section 2b): room for the
/// close button and its gap and inset in place of the right padding.
pub fn closable_width(style: text.Style, label: []const u8) f32 {
    const width = natural_width(style, label) - tab_pad_x + tab_close_gap + tab_close_w +
        tab_close_inset;
    assert(width > tab_close_w + tab_close_inset);
    return width;
}

/// The close button of a closable tab at `tab` (section 2b): `tab_close_w` square,
/// `tab_close_inset` from its right edge, centred vertically.
pub fn close_rect(tab: Rect) Rect {
    assert(tab.width > 0);
    assert(tab.height > 0);
    return .{
        .x = tab.x + tab.width - tab_close_inset - tab_close_w,
        .y = tab.y + (tab.height - tab_close_w) * 0.5,
        .width = tab_close_w,
        .height = tab_close_w,
    };
}

/// Where a drop at `x` lands among the tabs at `rects` (section 3b): the number of them,
/// `skip` aside, whose centre lies left of `x`. With `skip` the moving tab, it is the index
/// `move_item` moves it to.
pub fn insertion(rects: []const Rect, skip: ?u32, x: f32) u32 {
    assert(rects.len <= tabs_max);
    assert(skip == null or skip.? < rects.len);
    var index: u32 = 0;
    for (rects, 0..) |rect, at| {
        if (skip != null and skip.? == at) continue;
        if (rect.x + rect.width * 0.5 < x) index += 1;
    }
    assert(index <= rects.len);
    return index;
}

/// Moves `items[from]` to `items[to]`, shifting the items between by one: the array update
/// for `moved` (section 3c).
pub fn move_item(comptime T: type, items: []T, from: u32, to: u32) void {
    assert(from < items.len);
    assert(to < items.len);
    if (from < to) {
        std.mem.rotate(T, items[from .. to + 1], 1);
    } else if (to < from) {
        std.mem.rotate(T, items[to .. from + 1], from - to);
    }
}

/// Removes `items[index]`, shifting the rest left; the caller's count drops by one: the array
/// update for `closed` and `dragged_out` (section 3c).
pub fn remove_item(comptime T: type, items: []T, index: u32) void {
    assert(index < items.len);
    std.mem.copyForwards(T, items[index .. items.len - 1], items[index + 1 ..]);
}

/// Inserts `value` at `index` among the first `len` of `items`, shifting the rest right; the
/// caller's count rises by one: the array update for `received` (section 3c).
pub fn insert_item(comptime T: type, items: []T, len: u32, index: u32, value: T) void {
    assert(len < items.len);
    assert(index <= len);
    std.mem.copyBackwards(T, items[index + 1 .. len + 1], items[index..len]);
    items[index] = value;
}

/// The press that grabbed a movable tab (section 3b): its key, where in the tab it landed
/// (the ghost keeps it under the pointer), and the tab's size.
pub const Grab = struct {
    key: u64,
    dx: f32,
    dy: f32,
    width: f32,
    height: f32,
};

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
        /// App-owned labels, and keys (one per label) when the tabs are keyed (section 3c).
        labels: []const []const u8,
        keys: ?[]const u64,
        /// The selected tab, or 0 for an empty bar.
        selected: u32,
        /// The tab under the pointer.
        hover: ?u32,
        /// Close buttons, and a middle press closes (section 3a).
        closable: bool,
        /// Reorder by dragging, drag a tab out, and take dropped tabs (section 3b).
        movable: bool,
        /// The tab whose close button is under the pointer.
        hover_close: ?u32,
        /// The press that grabbed a tab of a movable bar.
        grab: ?Grab,

        pub const Move = struct { from: u32, to: u32 };
        pub const Received = struct { payload: u64, index: u32 };

        pub const Action = union(enum) {
            none,
            /// A different tab was selected; its index.
            changed: u32,
            /// The tab was closed; the app removes it (section 3c).
            closed: u32,
            /// The tab moved within the bar; the app moves it (`move_item`).
            moved: Move,
            /// The tab was dropped on another drag target; the app removes it.
            dragged_out: u32,
            /// A drag carrying `payload` was dropped at `index`; the app inserts the tab.
            received: Received,
        };

        /// Tabs over `labels` (0 to `tabs_max`) with `selected` selected, keyed by index: no
        /// close buttons and no moving.
        pub fn init(id: Id, labels: []const []const u8, selected: u32) Self {
            assert(id != .none);
            assert(labels.len <= tabs_max);
            assert(selected < labels.len or (labels.len == 0 and selected == 0));
            return .{
                .id = id,
                .labels = labels,
                .keys = null,
                .selected = selected,
                .hover = null,
                .closable = false,
                .movable = false,
                .hover_close = null,
                .grab = null,
            };
        }

        /// Tabs whose ids come from `keys` (distinct, one per label), so a tab keeps its id
        /// when it moves; set `closable` and `movable` after (section 3c).
        pub fn init_keyed(
            id: Id,
            labels: []const []const u8,
            keys: []const u64,
            selected: u32,
        ) Self {
            var self = init(id, labels, selected);
            self.set(labels, keys);
            self.selected = selected;
            assert(self.keys != null);
            return self;
        }

        /// Points the tabs at the app's arrays after it changed them (section 3c), and clamps
        /// `selected`, `hover`, and `hover_close` to them.
        pub fn set(self: *Self, labels: []const []const u8, keys: ?[]const u64) void {
            assert(labels.len <= tabs_max);
            assert(keys == null or keys.?.len == labels.len);
            assert(!self.movable or keys != null);
            if (std.debug.runtime_safety) {
                if (keys) |all| {
                    for (all, 0..) |one, at| {
                        for (all[0..at]) |earlier| assert(earlier != one);
                    }
                }
            }
            self.labels = labels;
            self.keys = keys;
            const total: u32 = @intCast(labels.len);
            self.selected = if (total == 0) 0 else @min(self.selected, total - 1);
            if (self.hover != null and self.hover.? >= total) self.hover = null;
            if (self.hover_close != null and self.hover_close.? >= total) self.hover_close = null;
        }

        /// The number of tabs.
        pub fn count(self: *const Self) u32 {
            assert(self.labels.len <= tabs_max);
            return @intCast(self.labels.len);
        }

        /// Tab `index`'s key: its entry in `keys`, or the index itself.
        pub fn key_of(self: *const Self, index: u32) u64 {
            assert(index < self.labels.len);
            if (self.keys) |keys| return keys[index];
            return index;
        }

        /// The index of the tab keyed `key`, or null.
        pub fn index_of(self: *const Self, wanted: u64) ?u32 {
            for (0..self.labels.len) |index| {
                if (self.key_of(@intCast(index)) == wanted) return @intCast(index);
            }
            return null;
        }

        /// Tab `index`'s id: the bar's id derived by its key.
        pub fn tab_id(self: *const Self, index: u32) Id {
            assert(index < self.labels.len);
            return self.id.derive(self.key_of(index));
        }

        /// Tab `index`'s close button's id.
        pub fn close_id(self: *const Self, index: u32) Id {
            return self.tab_id(index).derive(close_salt);
        }

        /// Draws the bar at the top of the box `walk` gets (fixed or fill on both axes) and
        /// opens the page container under it, laid out by `layout`; the caller closes it with
        /// `cx.end()`. Returns the page's rect. Draw phase.
        pub fn begin(self: *const Self, cx: anytype, walk: Walk, layout: ui.Layout) Rect {
            assert(walk.width != .fit and walk.height != .fit);
            assert(self.selected < self.labels.len or self.labels.len == 0);
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
            assert(self.selected < self.labels.len or self.labels.len == 0);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            self.draw_bar(cx, rect, clip);
        }

        /// The tabs' rects in `strip` (sections 2 and 2a).
        fn layout_tabs(self: *const Self, cx: anytype, strip: Rect, out: *[tabs_max]Rect) []Rect {
            const style = cx.theme().name;
            var natural: [tabs_max]f32 = undefined;
            var widths: [tabs_max]f32 = undefined;
            const total = self.count();
            if (total == 0) return out[0..0];
            const inset: f32 = if (arrange == .even) segment_inset else 0;
            if (arrange == .even) {
                even_widths(@max(0, strip.width - 2 * inset), widths[0..total]);
            } else {
                for (self.labels, natural[0..total]) |label, *width| {
                    width.* = if (self.closable)
                        closable_width(style, label)
                    else
                        natural_width(style, label);
                }
                tab_widths(natural[0..total], strip.width, widths[0..total]);
            }
            const height = if (arrange == .even)
                strip.height - 2 * inset
            else
                strip.height - tab_line_px;
            var x = strip.x + inset;
            for (widths[0..total], out[0..total]) |width, *rect| {
                rect.* = .{
                    .x = x,
                    .y = strip.y + inset,
                    .width = width,
                    .height = @max(0, height),
                };
                x += width + tab_gap;
            }
            return out[0..total];
        }

        fn draw_bar(self: *const Self, cx: anytype, strip: Rect, clip: kit.Clip) void {
            assert(strip.width > 0 and strip.height > 0);
            var flags = tabs_flags;
            flags.drag_target = self.movable;
            cx.area(self.id, strip, 0, flags);
            var storage: [tabs_max]Rect = undefined;
            const rects = self.layout_tabs(cx, strip, &storage);
            var insert_x: ?f32 = null;
            if (self.movable and cx.drag_hovering(self.id)) {
                const at = insertion(rects, null, cx.dragging().?.x);
                insert_x = gap_x(rects, at, strip);
            }
            Skin.tab_bar(cx, .{
                .rect = strip,
                .clip = clip,
                .focused = cx.focused(self.id),
                .insert_x = insert_x,
            });
            for (self.labels, rects, 0..) |label, tab, index| {
                const at: u32 = @intCast(index);
                if (!(tab.width > 0) or !(tab.height > 0)) continue;
                const inside = cx.visible(tab) orelse continue;
                const close: ?Rect = if (self.closable) close_rect(tab) else null;
                const shape = Skin.tab(cx, .{
                    .rect = tab,
                    .clip = inside,
                    .label = label,
                    .selected = at == self.selected,
                    .hovered = self.hover != null and self.hover.? == at,
                    .close = close,
                    .close_hovered = self.hover_close != null and self.hover_close.? == at,
                }) orelse continue;
                cx.area(self.tab_id(at), shape.rect, shape.radius, ui.cx.plain);
                if (close) |button| cx.area(self.close_id(at), button, 4, ui.cx.plain);
            }
            self.draw_ghost(cx);
        }

        /// The floating copy of this bar's tab while a drag of it is in flight (section 3b):
        /// on the tooltip layer, at the pointer less the grab's offset, with no area.
        fn draw_ghost(self: *const Self, cx: anytype) void {
            const grab = self.grab orelse return;
            const dragging = cx.dragging() orelse return;
            const index = self.index_of(grab.key) orelse return;
            if (dragging.source != self.tab_id(index)) return;
            const rect: Rect = .{
                .x = dragging.x - grab.dx,
                .y = dragging.y - grab.dy,
                .width = grab.width,
                .height = grab.height,
            };
            const clip = ui.cx.intersect(ui.cx.clip_of(cx.window), rect) orelse return;
            const previous = cx.drawing().layer(.tooltip);
            _ = Skin.tab(cx, .{
                .rect = rect,
                .clip = clip,
                .label = self.labels[index],
                .selected = false,
                .hovered = false,
                .ghost = true,
            });
            _ = cx.drawing().layer(previous);
        }

        /// Presses, hover, keys, and drags (section 3).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.selected < self.labels.len or self.labels.len == 0);
            if (event == .frame) return .none;
            var action: Action = .none;
            if (self.movable) {
                if (self.drag_events(cx, event)) |dragged| action = dragged;
            }
            if (event == .key_down) {
                if (action != .none or !cx.focused(self.id)) return action;
                return self.key(cx, event.key_down);
            }
            if (self.closable and event == .pointer_down and
                event.pointer_down.button == .middle)
            {
                for (0..self.labels.len) |index| {
                    const at: u32 = @intCast(index);
                    const hovered = cx.hovered();
                    if (hovered == self.tab_id(at) or hovered == self.close_id(at)) {
                        return self.close_tab(cx, at);
                    }
                }
            }
            for (0..self.labels.len) |index| {
                const at: u32 = @intCast(index);
                switch (cx.hit(self.tab_id(at), event)) {
                    .hover_in => self.hover_tab(cx, at),
                    .hover_out => if (self.hover == at) self.hover_tab(cx, null),
                    .down => |press| {
                        cx.set_focus(self.id);
                        action = self.select(cx, at);
                        if (self.movable) self.grab = .{
                            .key = self.key_of(at),
                            .dx = press.x - press.rect.x,
                            .dy = press.y - press.rect.y,
                            .width = press.rect.width,
                            .height = press.rect.height,
                        };
                    },
                    .drag => |press| if (self.drag_tab(cx, at, press)) |moved| {
                        action = moved;
                    },
                    .up => self.grab = null,
                    .none, .wheel, .secondary => {},
                }
                if (!self.closable or at >= self.labels.len) continue;
                switch (cx.hit(self.close_id(at), event)) {
                    .hover_in => self.hover_close_tab(cx, at),
                    .hover_out => if (self.hover_close == at) self.hover_close_tab(cx, null),
                    .up => |up| if (up.inside) {
                        action = self.close_tab(cx, at);
                    },
                    .none, .down, .drag, .wheel, .secondary => {},
                }
            }
            return action;
        }

        /// A grabbed tab dragged with no drag in flight (section 3b): inside the bar's band it
        /// reorders, outside it begins a drag between widgets carrying its key.
        fn drag_tab(self: *Self, cx: anytype, index: u32, press: ui.Press) ?Action {
            assert(index < self.labels.len);
            if (!self.movable) return null;
            const grab = self.grab orelse return null;
            if (grab.key != self.key_of(index)) return null;
            if (cx.dragging() != null) return null;
            const strip = cx.find(self.id) orelse return null;
            const top = strip.rect[1] - tab_detach_px;
            const bottom = strip.rect[1] + strip.rect[3] + tab_detach_px;
            const inside_x = press.x >= strip.rect[0] and press.x < strip.rect[0] + strip.rect[2];
            if (!inside_x or press.y < top or press.y >= bottom) {
                cx.drag_begin(self.tab_id(index), grab.key);
                self.hover_tab(cx, null);
                return null;
            }
            var storage: [tabs_max]Rect = undefined;
            const to = insertion(self.last_rects(cx, &storage), index, press.x);
            if (to == index) return null;
            return self.move_tab(cx, index, to);
        }

        /// The drag hits of a movable bar (section 3b): a drop on the bar moves its own tab or
        /// receives another, and the end of its own tab's drag elsewhere lets the tab go.
        fn drag_events(self: *Self, cx: anytype, event: input.Event) ?Action {
            assert(self.movable);
            var action: ?Action = null;
            switch (cx.drag_hit(self.id, event)) {
                .dropped => |over| {
                    var storage: [tabs_max]Rect = undefined;
                    const rects = self.last_rects(cx, &storage);
                    const own = self.index_of(over.payload);
                    if (own != null and over.source == self.tab_id(own.?)) {
                        const to = insertion(rects, own.?, over.x);
                        if (to != own.?) action = self.move_tab(cx, own.?, to);
                    } else {
                        const at = insertion(rects, null, over.x);
                        self.selected = at;
                        cx.redraw();
                        action = .{ .received = .{ .payload = over.payload, .index = at } };
                    }
                },
                .none, .drag_in, .over, .drag_out, .ended => {},
            }
            const grab = self.grab orelse return action;
            const index = self.index_of(grab.key) orelse return action;
            switch (cx.drag_hit(self.tab_id(index), event)) {
                .ended => |end| {
                    self.grab = null;
                    cx.redraw();
                    if (end.target != .none and end.target != self.id) {
                        self.removed(index);
                        return .{ .dragged_out = index };
                    }
                },
                .none, .drag_in, .over, .drag_out, .dropped => {},
            }
            return action;
        }

        /// The tabs' rects at the last draw, read from their areas; a tab that was not drawn
        /// lies past every point.
        fn last_rects(self: *const Self, cx: anytype, out: *[tabs_max]Rect) []Rect {
            const total = self.count();
            for (out[0..total], 0..) |*rect, index| {
                rect.* = .{ .x = std.math.inf(f32), .y = 0, .width = 0, .height = 0 };
                const found = cx.find(self.tab_id(@intCast(index))) orelse continue;
                rect.* = .{
                    .x = found.rect[0],
                    .y = found.rect[1],
                    .width = found.rect[2],
                    .height = found.rect[3],
                };
            }
            return out[0..total];
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(cx.focused(self.id));
            const total = self.count();
            if (total == 0) return .none;
            const next = (self.selected + 1) % total;
            const previous = (self.selected + total - 1) % total;
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

        /// `closed`: `selected` as if the app removed the tab (section 3c).
        fn close_tab(self: *Self, cx: anytype, index: u32) Action {
            assert(index < self.labels.len);
            self.removed(index);
            self.hover = null;
            self.hover_close = null;
            cx.redraw();
            return .{ .closed = index };
        }

        /// `moved`: `selected` follows the tab, or shifts by one across it (section 3c).
        fn move_tab(self: *Self, cx: anytype, from: u32, to: u32) Action {
            assert(from < self.labels.len and to < self.labels.len);
            assert(from != to);
            if (self.selected == from) {
                self.selected = to;
            } else if (from < self.selected and self.selected <= to) {
                self.selected -= 1;
            } else if (to <= self.selected and self.selected < from) {
                self.selected += 1;
            }
            self.hover = null;
            cx.redraw();
            return .{ .moved = .{ .from = from, .to = to } };
        }

        /// `selected` once tab `index` is gone.
        fn removed(self: *Self, index: u32) void {
            const total = self.count();
            assert(index < total);
            if (total == 1) {
                self.selected = 0;
            } else if (index < self.selected) {
                self.selected -= 1;
            } else if (index == self.selected) {
                self.selected = @min(index, total - 2);
            }
            assert(self.selected < @max(total - 1, 1));
        }

        fn hover_tab(self: *Self, cx: anytype, index: ?u32) void {
            if (std.meta.eql(self.hover, index)) return;
            self.hover = index;
            cx.redraw();
        }

        fn hover_close_tab(self: *Self, cx: anytype, index: ?u32) void {
            if (std.meta.eql(self.hover_close, index)) return;
            self.hover_close = index;
            cx.redraw();
        }
    };
}

/// The x of the gap before tab `index` among `rects` in `strip` (section 3b): half a gap left
/// of that tab, half a gap right of the last one, or the strip's start for an empty bar.
fn gap_x(rects: []const Rect, index: u32, strip: Rect) f32 {
    assert(index <= rects.len);
    if (rects.len == 0) return strip.x + tab_gap;
    if (index < rects.len) return @max(strip.x + tab_gap * 0.5, rects[index].x - tab_gap * 0.5);
    const last = rects[rects.len - 1];
    return last.x + last.width + tab_gap * 0.5;
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
const Dragging = ui.Dragging;

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

const one_two_three = [_][]const u8{ "one", "two", "three" };
const four_five = [_][]const u8{ "four", "five" };

/// A bar's app-owned arrays, as an app keeps them, and the bar over them.
const Owned = struct {
    labels: [tabs_max][]const u8,
    keys: [tabs_max]u64,
    len: u32,
    tabs: Tabs,

    fn init(self: *Owned, id: Id, labels: []const []const u8, first_key: u64) void {
        for (labels, 0..) |label, index| {
            self.labels[index] = label;
            self.keys[index] = first_key + index;
        }
        self.len = @intCast(labels.len);
        self.tabs = Tabs.init_keyed(id, self.labels[0..self.len], self.keys[0..self.len], 0);
        self.tabs.movable = true;
    }

    /// Applies `action` to the arrays, as the gallery's tabs page does; `received` takes its
    /// label from `names` by payload.
    fn apply(self: *Owned, action: Tabs.Action, names: []const []const u8) void {
        switch (action) {
            .none, .changed => return,
            .closed, .dragged_out => |index| {
                remove_item([]const u8, self.labels[0..self.len], index);
                remove_item(u64, self.keys[0..self.len], index);
                self.len -= 1;
            },
            .moved => |move| {
                move_item([]const u8, self.labels[0..self.len], move.from, move.to);
                move_item(u64, self.keys[0..self.len], move.from, move.to);
            },
            .received => |got| {
                const label = names[@intCast(got.payload)];
                insert_item([]const u8, &self.labels, self.len, got.index, label);
                insert_item(u64, &self.keys, self.len, got.index, got.payload);
                self.len += 1;
            },
        }
        self.tabs.set(self.labels[0..self.len], self.keys[0..self.len]);
    }
};

/// Labels by key, for `received`: keys 10 to 12 and 20 to 21.
const names_by_key = blk: {
    var names: [24][]const u8 = @splat("?");
    names[10] = "one";
    names[11] = "two";
    names[12] = "three";
    names[20] = "four";
    names[21] = "five";
    break :blk names;
};

const bars_static = struct {
    var a: Owned = undefined;
    var b: Owned = undefined;
};

/// Bar A (keys 10..12) at (0, 0) and bar B (keys 20..21) at (0, 150), both 400 x 100.
fn two_bars() struct { *Owned, *Owned } {
    bars_static.a.init(ui.id("bar a", 0), &one_two_three, 10);
    bars_static.b.init(ui.id("bar b", 0), &four_five, 20);
    return .{ &bars_static.a, &bars_static.b };
}

fn draw_bars(cx: *fixture.Context, a: *const Owned, b: *const Owned) void {
    cx.begin_frame(1280, 720, 120);
    _ = a.tabs.begin(cx, fixture.at(0, 0, 400, 100), .{ .flow = .down });
    _ = cx.end();
    _ = b.tabs.begin(cx, fixture.at(0, 50, 400, 100), .{ .flow = .down });
    _ = cx.end();
    _ = cx.end_frame();
}

/// Dispatches `event` to both bars, applying their actions; returns them.
fn send_bars(cx: *fixture.Context, a: *Owned, b: *Owned, event: input.Event) [2]Tabs.Action {
    cx.event_begin(event);
    const actions: [2]Tabs.Action = .{ a.tabs.handle(cx, event), b.tabs.handle(cx, event) };
    cx.event_end();
    a.apply(actions[0], &names_by_key);
    b.apply(actions[1], &names_by_key);
    return actions;
}

fn point(x: f32, y: f32) input.Point {
    return .{ .x = x, .y = y };
}

// Locks section 2b: a closable "one" is its natural width plus 12 (the close gap, button,
// and inset in place of the right padding); its close button is 16 x 16, 8 px from the
// tab's right and centred in the 31 px tab; a plain tab keeps its natural width.
test "closable tabs make room for their close buttons" {
    const cx = fixture.context();
    var tabs = Tabs.init(ui.id("tabs", 0), &one_two_three, 0);
    tabs.closable = true;
    _ = draw_tabs(cx, &tabs);
    const style = theme.dark.name;
    const first = cx.find(tabs.tab_id(0)).?;
    try testing.expectEqual(natural_width(style, "one") + 12, first.rect[2]);
    const close = cx.find(tabs.close_id(0)).?;
    const right = first.rect[0] + first.rect[2];
    try testing.expectEqualSlices(f32, &.{ right - 24, 7.5, 16, 16 }, &close.rect);
    try testing.expectEqual(closable_width(style, "two"), cx.find(tabs.tab_id(1)).?.rect[2]);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks closing (section 3a): a press and release on tab 1's close button closes it with
// `selected` untouched; a press on a close button released outside does nothing; a middle
// press over the selected tab 2 closes it and selects tab 1.
test "a close button or a middle press closes a tab" {
    const cx = fixture.context();
    var tabs = Tabs.init(ui.id("tabs", 0), &one_two_three, 0);
    tabs.closable = true;
    _ = draw_tabs(cx, &tabs);
    const close = cx.find(tabs.close_id(1)).?;
    const at_close = point(close.rect[0] + 8, close.rect[1] + 8);
    _ = fixture.send(cx, &tabs, .{ .pointer_move = at_close });
    try testing.expectEqual(@as(?u32, 1), tabs.hover_close);
    _ = fixture.send(cx, &tabs, .{ .pointer_down = input.left_at(at_close) });
    const closed = fixture.send(cx, &tabs, .{ .pointer_up = input.left_at(at_close) });
    try testing.expectEqual(Tabs.Action{ .closed = 1 }, closed);
    try testing.expectEqual(@as(u32, 0), tabs.selected);
    _ = draw_tabs(cx, &tabs);
    _ = fixture.send(cx, &tabs, .{ .pointer_down = input.left_at(at_close) });
    _ = fixture.send(cx, &tabs, .{ .pointer_move = point(300, 200) });
    const outside = fixture.send(cx, &tabs, .{ .pointer_up = input.left_at(point(300, 200)) });
    try testing.expectEqual(Tabs.Action.none, outside);
    tabs.selected = 2;
    _ = draw_tabs(cx, &tabs);
    const two = tab_center(cx, &tabs, 2);
    _ = fixture.send(cx, &tabs, .{ .pointer_move = two });
    var middle = input.left_at(two);
    middle.button = .middle;
    const closed_two = fixture.send(cx, &tabs, .{ .pointer_down = middle });
    try testing.expectEqual(Tabs.Action{ .closed = 2 }, closed_two);
    try testing.expectEqual(@as(u32, 1), tabs.selected);
}

// Locks reordering (sections 3b and 3c): tab 0 dragged past tab 2's centre is moved
// { 0, 2 } and stays selected at 2; after the app moved its arrays, the tab keeps its id, so
// its capture holds, and a second move to the same point moves nothing; the release drops
// nothing.
test "dragging a tab within its bar reorders it" {
    const cx = fixture.context();
    const a, const b = two_bars();
    draw_bars(cx, a, b);
    const grabbed = a.tabs.tab_id(0);
    _ = send_bars(cx, a, b, .{ .pointer_down = input.left_at(tab_center(cx, &a.tabs, 0)) });
    const three = cx.find(a.tabs.tab_id(2)).?;
    const past = point(three.rect[0] + three.rect[2] * 0.5 + 4, 16);
    const moved = send_bars(cx, a, b, .{ .pointer_move = past });
    try testing.expectEqual(Tabs.Action{ .moved = .{ .from = 0, .to = 2 } }, moved[0]);
    try testing.expectEqualStrings("one", a.labels[2]);
    try testing.expectEqual(@as(u32, 2), a.tabs.selected);
    try testing.expectEqual(grabbed, a.tabs.tab_id(2));
    try testing.expectEqual(grabbed, cx.capture);
    try testing.expectEqual(Tabs.Action.none, send_bars(cx, a, b, .{ .pointer_move = past })[0]);
    const released = send_bars(cx, a, b, .{ .pointer_up = input.left_at(past) });
    try testing.expectEqual([2]Tabs.Action{ .none, .none }, released);
    try testing.expectEqual(@as(?Grab, null), a.tabs.grab);
}

// Locks a drag between bars (sections 3b and 4): leaving A's band begins a drag carrying the
// key of "two"; the next draw puts its ghost on the tooltip layer at the pointer less the
// grab's offset, with no area; over B the next draw shows B's 2 px marker in the gap before
// "five"; the release gives A dragged_out 1 and B received { 11, 1 }, selected; the arrays
// then hold one, three and four, two, five.
test "a tab dragged onto another bar moves there" {
    const cx = fixture.context();
    const a, const b = two_bars();
    draw_bars(cx, a, b);
    const start = tab_center(cx, &a.tabs, 1);
    _ = send_bars(cx, a, b, .{ .pointer_down = input.left_at(start) });
    _ = send_bars(cx, a, b, .{ .pointer_move = point(start.x, 80) });
    const dragging = cx.dragging().?;
    try testing.expectEqual(a.tabs.tab_id(1), dragging.source);
    try testing.expectEqual(@as(u64, 11), dragging.payload);
    draw_bars(cx, a, b);
    const grab = a.tabs.grab.?;
    const boxes = cx.draw.items(draw.Box);
    var ghosts: u32 = 0;
    for (boxes, 0..) |box, index| {
        if (cx.draw.layer_at(draw.Box, @intCast(index)) != .tooltip) continue;
        ghosts += 1;
        try testing.expectEqual(start.x - grab.dx, box.rect[0]);
        try testing.expectEqual(80 - grab.dy, box.rect[1]);
    }
    try testing.expectEqual(@as(u32, 1), ghosts);
    const five = cx.find(b.tabs.tab_id(1)).?;
    const gap = point(five.rect[0] + 2, 166);
    _ = send_bars(cx, a, b, .{ .pointer_move = gap });
    try testing.expect(cx.drag_hovering(b.tabs.id));
    draw_bars(cx, a, b);
    var marker = false;
    for (cx.draw.items(draw.Box)) |box| {
        if (box.rect[2] == 2 and box.rect[0] == five.rect[0] - 2) marker = true;
    }
    try testing.expect(marker);
    const released = send_bars(cx, a, b, .{ .pointer_up = input.left_at(gap) });
    try testing.expectEqual(Tabs.Action{ .dragged_out = 1 }, released[0]);
    try testing.expectEqual(Tabs.Action{ .received = .{ .payload = 11, .index = 1 } }, released[1]);
    try testing.expectEqual(@as(u32, 2), a.len);
    try testing.expectEqualStrings("three", a.labels[1]);
    try testing.expectEqualStrings("two", b.labels[1]);
    try testing.expectEqual(@as(u32, 1), b.tabs.selected);
    try testing.expectEqual(@as(?Dragging, null), cx.dragging());
    draw_bars(cx, a, b);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks a drag that comes back (section 3b): tab 0 dragged out of A and dropped on A past
// tab 2's centre is moved { 0, 2 }, not dragged out; B sees nothing.
test "a tab dropped back on its own bar moves within it" {
    const cx = fixture.context();
    const a, const b = two_bars();
    draw_bars(cx, a, b);
    const three = cx.find(a.tabs.tab_id(2)).?;
    _ = send_bars(cx, a, b, .{ .pointer_down = input.left_at(tab_center(cx, &a.tabs, 0)) });
    _ = send_bars(cx, a, b, .{ .pointer_move = point(20, 80) });
    const back = point(three.rect[0] + three.rect[2] * 0.5 + 4, 16);
    _ = send_bars(cx, a, b, .{ .pointer_move = back });
    const released = send_bars(cx, a, b, .{ .pointer_up = input.left_at(back) });
    try testing.expectEqual(Tabs.Action{ .moved = .{ .from = 0, .to = 2 } }, released[0]);
    try testing.expectEqual(Tabs.Action.none, released[1]);
    try testing.expectEqualStrings("one", a.labels[2]);
}

// Locks the cancel (section 3b): Escape mid-drag ends it with no action and no ghost in the
// next draw; the tab stays where it was, and the release drops nothing.
test "Escape cancels a tab's drag" {
    const cx = fixture.context();
    const a, const b = two_bars();
    draw_bars(cx, a, b);
    const start = tab_center(cx, &a.tabs, 1);
    _ = send_bars(cx, a, b, .{ .pointer_down = input.left_at(start) });
    _ = send_bars(cx, a, b, .{ .pointer_move = point(start.x, 166) });
    const escape: input.Event = .{ .key_down = input.key_press(.escape, .none, false, "") };
    try testing.expectEqual([2]Tabs.Action{ .none, .none }, send_bars(cx, a, b, escape));
    try testing.expectEqual(@as(?Dragging, null), cx.dragging());
    draw_bars(cx, a, b);
    for (0..cx.draw.items(draw.Box).len) |index| {
        try testing.expect(cx.draw.layer_at(draw.Box, @intCast(index)) != .tooltip);
    }
    const released = send_bars(cx, a, b, .{ .pointer_up = input.left_at(point(start.x, 166)) });
    try testing.expectEqual([2]Tabs.Action{ .none, .none }, released);
    try testing.expectEqual(@as(u32, 3), a.len);
    try testing.expectEqual(@as(u32, 2), b.len);
}

// Locks an empty movable bar (sections 3b and 3c): B emptied of its tabs still draws its strip
// as a drag target, and a tab dropped on it is received at index 0.
test "an empty movable bar takes a dropped tab" {
    const cx = fixture.context();
    const a, const b = two_bars();
    b.len = 0;
    b.tabs.set(b.labels[0..0], b.keys[0..0]);
    draw_bars(cx, a, b);
    try testing.expect(cx.find(b.tabs.id).?.flags.drag_target);
    const start = tab_center(cx, &a.tabs, 2);
    _ = send_bars(cx, a, b, .{ .pointer_down = input.left_at(start) });
    _ = send_bars(cx, a, b, .{ .pointer_move = point(start.x, 80) });
    _ = send_bars(cx, a, b, .{ .pointer_move = point(100, 166) });
    const released = send_bars(cx, a, b, .{ .pointer_up = input.left_at(point(100, 166)) });
    try testing.expectEqual(Tabs.Action{ .received = .{ .payload = 12, .index = 0 } }, released[1]);
    try testing.expectEqualStrings("three", b.labels[0]);
    try testing.expectEqual(@as(u32, 1), b.len);
}

// Locks the array helpers (section 3c): moving 0 to 2 and back, removing the middle, and
// inserting at the front and the end.
test "move_item, remove_item, and insert_item update an app's arrays" {
    var items = [_]u8{ 'a', 'b', 'c', 'd', 0 };
    move_item(u8, items[0..4], 0, 2);
    try testing.expectEqualSlices(u8, "bcad", items[0..4]);
    move_item(u8, items[0..4], 2, 0);
    try testing.expectEqualSlices(u8, "abcd", items[0..4]);
    remove_item(u8, items[0..4], 1);
    try testing.expectEqualSlices(u8, "acd", items[0..3]);
    insert_item(u8, &items, 3, 0, 'z');
    try testing.expectEqualSlices(u8, "zacd", items[0..4]);
    insert_item(u8, &items, 4, 4, 'y');
    try testing.expectEqualSlices(u8, "zacdy", &items);
}

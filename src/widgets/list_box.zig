//! `ListBox`: a virtual list of uniform rows with a selection, keys, and scroll-into-view.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! A list box wraps a scrolling view (`ui/view.zig`) and keeps the turtle's begin/end shape: it
//! owns the rows' geometry, areas, highlight bands, and input, and the app draws each row's
//! content into the rect `next` hands it.
//! ```text
//! range = lb.begin(cx, walk)       the view, List.visible, skip(first * row_h)
//! while (lb.next(cx)) |row| {      walks the row, records its area, draws its band
//!     ... app draws into row.rect under row.clip ...
//! }
//! lb.end(cx)                       skips the rows after the last walked one, end_view
//! ```
//! Only rows overlapping the viewport are walked, so a list of `list_rows_max` rows costs its
//! visible rows. `begin` and `end` assert the order with `open`.
//!
//! ## 2. Ids
//! The view's area is `id` (the wheel and focus); the thumb is `id.derive(view.thumb_salt)`;
//! row `i` is `id.derive(row_salt + i)`, so the app never builds row ids and they never meet
//! the thumb's salt.
//!
//! ## 3. Events
//! `handle` routes the view's wheel and thumb itself (`ViewState.handle` needs the id), so
//! `ui.route` reaches a list box like any widget.
//! ```text
//! row hover_in / hover_out   redraw (the band follows the hover)
//! row down                   focus the list; a double press is activated
//! row up inside              selected (unless the press was a double press)
//! Up / Down                  the previous / next row; from none the first
//! Page Up / Page Down        a viewport of rows back / forward
//! Home / End                 the first / last row
//! Enter                      activated (the selection)
//! ```
//! Keys count while the view's area has focus (it is focusable, so Tab reaches it). A key that
//! moves the selection scrolls it into view:
//! ```text
//! scroll_y = clamp(scroll_y, sel * row_h + row_h - view_h, sel * row_h)
//! ```
//! with the upper bound winning when a row is taller than the view (`scroll_for`).
//!
//! ## 4. Drawing
//! `ListBoxOf(Skin)` hands `Skin.list_row` a `ListRowLook` per walked row before the app draws
//! the row; `ListBox` is `ListBoxOf(skins.Default)`: `colors.selection` under the selected row,
//! `colors.track` under the hovered one.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation; `handle` is O(visible rows), `next` O(1).
//! - `selected` is below `count` whenever it is set (asserted at `begin`).

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Clip = kit.Clip;
const Walk = kit.Walk;
const Id = kit.Id;

/// Rows one list box holds at most.
pub const list_rows_max: u32 = 1 << 20;

/// The salt row ids start from: row `i` is `id.derive(row_salt + i)` (section 2).
pub const row_salt: u64 = 0x726f7773 << 32;

/// The default band's corner radius.
pub const list_row_radius: f32 = 4;

/// The view's area: it takes the wheel and focus.
pub const list_flags: ui.Flags = .{
    .wheel = true,
    .focusable = true,
    .tab = false,
    .cursor = .default,
};

/// One walked row: its index, its rect and clip, and whether it is selected or hovered.
pub const Row = struct {
    index: u32,
    rect: Rect,
    clip: Clip,
    selected: bool,
    hovered: bool,
};

/// The offset that shows row `index` (section 3): `scroll_y` moved the least so the row is
/// inside a `view_h` viewport, its top when it cannot fit.
pub fn scroll_for(scroll_y: f32, index: u32, row_h: f32, view_h: f32) f32 {
    assert(row_h > 0);
    assert(scroll_y >= 0);
    const top = @as(f32, @floatFromInt(index)) * row_h;
    const low = top + row_h - view_h;
    const offset = @max(0, @min(@max(scroll_y, low), top));
    assert(offset <= top);
    assert(offset >= 0);
    return offset;
}

/// The default list box: `ListBoxOf(skins.Default)`.
pub const ListBox = ListBoxOf(skin.Default);

/// A virtual list whose row bands are drawn by `Skin` (`Skin.list_row`; `widgets/skin.zig`).
pub fn ListBoxOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .list_box)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        view: ui.ViewState,
        count: u32,
        row_h: f32,
        selected: ?u32,
        /// The rows the last draw walked over, which `handle` resolves.
        range: ui.List.Range,
        /// The next row `next` walks, while open.
        cursor: u32,
        open: bool,
        /// The current press was a double press (activated on its down).
        double: bool,

        pub const Action = union(enum) {
            none,
            /// A click or a key selected this row.
            selected: u32,
            /// A double click or Enter activated this row.
            activated: u32,
        };

        /// A list of `count` rows of `row_h`, scrolled to the top, nothing selected.
        pub fn init(id: Id, count: u32, row_h: f32) Self {
            assert(id != .none);
            assert(count <= list_rows_max);
            assert(row_h > 0);
            return .{
                .id = id,
                .view = ui.ViewState.init(),
                .count = count,
                .row_h = row_h,
                .selected = null,
                .range = .{ .first = 0, .end = 0 },
                .cursor = 0,
                .open = false,
                .double = false,
            };
        }

        /// Row `index`'s id (section 2).
        pub fn row_id(self: *const Self, index: u32) Id {
            assert(index < list_rows_max);
            return self.id.derive(row_salt + index);
        }

        /// Opens the view for `walk` and skips the rows above the viewport; returns the rows
        /// `next` will walk. Draw phase.
        pub fn begin(self: *Self, cx: anytype, walk: Walk) ui.List.Range {
            assert(!self.open);
            assert(self.count <= list_rows_max);
            if (self.selected) |index| assert(index < self.count);
            const layout = ui.flow_of(.down);
            const port = cx.begin_view_with(self.id, walk, layout, &self.view, list_flags);
            const list: ui.List = .{ .row_height = self.row_h, .count = self.count };
            self.range = list.visible(self.view.scroll_y, port.height);
            cx.skip(@as(f32, @floatFromInt(self.range.first)) * self.row_h);
            self.cursor = self.range.first;
            self.open = true;
            return self.range;
        }

        /// Walks the next visible row: records its area, hands its band to the skin, and
        /// returns it for the app to draw into; null after the last.
        pub fn next(self: *Self, cx: anytype) ?Row {
            assert(self.open);
            assert(self.cursor >= self.range.first);
            while (self.cursor < self.range.end) {
                const index = self.cursor;
                self.cursor += 1;
                const rect = cx.walk(ui.sized(.fill, .{ .fixed = self.row_h }));
                const clip = cx.visible(rect) orelse continue;
                const id = self.row_id(index);
                cx.area(id, rect, 0, ui.cx.plain);
                const row: Row = .{
                    .index = index,
                    .rect = rect,
                    .clip = clip,
                    .selected = self.selected != null and self.selected.? == index,
                    .hovered = cx.hovered() == id,
                };
                Skin.list_row(cx, .{
                    .rect = rect,
                    .clip = clip,
                    .selected = row.selected,
                    .hovered = row.hovered,
                });
                return row;
            }
            return null;
        }

        /// Skips the rows after the last one walked and closes the view.
        pub fn end(self: *Self, cx: anytype) void {
            assert(self.open);
            assert(self.cursor <= self.count);
            cx.skip(@as(f32, @floatFromInt(self.count - self.cursor)) * self.row_h);
            cx.end_view();
            self.open = false;
        }

        /// The view, the rows of the last draw, and keys while focused (section 3).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(!self.open);
            assert(self.range.end <= self.count or self.count == 0);
            if (event == .frame) return .none;
            _ = self.view.handle(cx, self.id, event);
            if (event == .key_down) {
                if (!cx.focused(self.id)) return .none;
                return self.key(cx, event.key_down);
            }
            var action: Action = .none;
            var index = self.range.first;
            while (index < @min(self.range.end, self.count)) : (index += 1) {
                switch (cx.hit(self.row_id(index), event)) {
                    .hover_in, .hover_out => cx.redraw(),
                    .down => |press| {
                        cx.set_focus(self.id);
                        self.double = press.clicks >= 2;
                        if (self.double) action = self.activate(cx, index);
                    },
                    .up => |up| {
                        if (up.inside and !self.double) action = self.choose(cx, index);
                        self.double = false;
                    },
                    .none, .drag, .wheel, .secondary => {},
                }
            }
            return action;
        }

        /// Scrolls so row `index` is inside the viewport (section 3). Event phase.
        pub fn scroll_into_view(self: *Self, cx: anytype, index: u32) void {
            assert(index < self.count);
            const view_h = self.view.viewport.height;
            const offset = scroll_for(self.view.scroll_y, index, self.row_h, view_h);
            _ = self.view.scroll_to(cx, offset);
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(cx.focused(self.id));
            if (self.count == 0) return .none;
            const last = self.count - 1;
            const rows: f32 = @floor(self.view.viewport.height / self.row_h);
            const page: u32 = @intFromFloat(@max(1, rows));
            const target: u32 = switch (press.key) {
                .enter => {
                    const index = self.selected orelse return .none;
                    return .{ .activated = index };
                },
                .down => if (self.selected) |at| @min(at + 1, last) else 0,
                .up => if (self.selected) |at| at -| 1 else 0,
                .page_down => if (self.selected) |at| @min(at +| page, last) else 0,
                .page_up => if (self.selected) |at| at -| page else 0,
                .home => 0,
                .end => last,
                else => return .none,
            };
            assert(target <= last);
            self.scroll_into_view(cx, target);
            if (self.selected != null and self.selected.? == target) return .none;
            return self.choose(cx, target);
        }

        fn choose(self: *Self, cx: anytype, index: u32) Action {
            assert(index < self.count);
            self.selected = index;
            cx.redraw();
            return .{ .selected = index };
        }

        fn activate(self: *Self, cx: anytype, index: u32) Action {
            assert(index < self.count);
            self.selected = index;
            cx.redraw();
            return .{ .activated = index };
        }
    };
}

comptime {
    assert(row_salt > ui.view.thumb_salt);
    assert(row_salt + list_rows_max > row_salt);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

// Locks the scroll-into-view formula of section 3 in a 240 px view of 24 px rows: row 23 from
// the top scrolls to 23 * 24 + 24 - 240 = 336; a row already visible leaves the offset; a row
// above scrolls to its top; a view shorter than a row shows the row's top.
test "scroll_for moves the least that shows the row" {
    try testing.expectEqual(@as(f32, 336), scroll_for(0, 23, 24, 240));
    try testing.expectEqual(@as(f32, 336), scroll_for(336, 20, 24, 240));
    try testing.expectEqual(@as(f32, 48), scroll_for(336, 2, 24, 240));
    try testing.expectEqual(@as(f32, 0), scroll_for(0, 3, 24, 240));
    try testing.expectEqual(@as(f32, 96), scroll_for(0, 4, 24, 10));
}

/// Draws `list` in a 216 x 240 box at (0, 0) (a 200 px row width beside the gutter), with a
/// box per row as its content; returns the range drawn.
fn draw_list(cx: *fixture.Context, list: *ListBox) ui.List.Range {
    cx.begin_frame(1280, 720, 120);
    const range = list.begin(cx, fixture.at(0, 0, 216, 240));
    var walked: u32 = 0;
    while (list.next(cx)) |row| : (walked += 1) {
        assert(row.rect.width == 200);
    }
    assert(walked == range.end - range.first);
    list.end(cx);
    _ = cx.end_frame();
    return range;
}

fn row_center(cx: *fixture.Context, list: *const ListBox, index: u32) input.Point {
    const area = cx.find(list.row_id(index)).?;
    return .{ .x = area.rect[0] + area.rect[2] * 0.5, .y = area.rect[1] + area.rect[3] * 0.5 };
}

fn key(name: input.Key) input.Event {
    return .{ .key_down = input.key_press(name, .none, false, "") };
}

// Locks the virtual rows (sections 1 and 2): 1,000 rows of 24 px scrolled to 100 walk rows 4 to
// 14 only, each with a derived id and the first 4 px above the viewport; the content is the
// whole list; the view's area is focusable and takes the wheel; no row id is the thumb's.
test "a list box walks only the visible rows" {
    const cx = fixture.context();
    var list = ListBox.init(ui.id("list", 0), 1000, 24);
    _ = draw_list(cx, &list);
    list.view.scroll_y = 100;
    const range = draw_list(cx, &list);
    try testing.expectEqual(ui.List.Range{ .first = 4, .end = 15 }, range);
    try testing.expectEqual(@as(f32, 24000), list.view.content_h);
    try testing.expect(cx.find(list.row_id(3)) == null);
    try testing.expectEqual(@as(f32, -4), cx.find(list.row_id(4)).?.rect[1]);
    try testing.expect(cx.find(list.row_id(14)) != null);
    const view_area = cx.find(list.id).?;
    try testing.expect(view_area.flags.focusable and view_area.flags.wheel);
    try testing.expect(list.row_id(0) != list.id.derive(ui.view.thumb_salt));
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks selection and keys (section 3): a click on row 3 selects it and focuses the list, Down
// 20 times selects row 23 and scrolls it into view (336), Page Down moves a viewport (10 rows),
// End and Home reach the ends, Enter activates, Up at row 0 does nothing, and a band is drawn
// under the selected row only.
test "a list box selects by click and keys and scrolls the selection into view" {
    const cx = fixture.context();
    var list = ListBox.init(ui.id("list", 0), 1000, 24);
    _ = draw_list(cx, &list);
    const three = row_center(cx, &list, 3);
    _ = fixture.send(cx, &list, .{ .pointer_down = input.left_at(three) });
    try testing.expect(cx.focused(list.id));
    const clicked = fixture.send(cx, &list, .{ .pointer_up = input.left_at(three) });
    try testing.expectEqual(ListBox.Action{ .selected = 3 }, clicked);
    var step: u32 = 0;
    var last: ListBox.Action = .none;
    while (step < 20) : (step += 1) last = fixture.send(cx, &list, key(.down));
    try testing.expectEqual(ListBox.Action{ .selected = 23 }, last);
    try testing.expectEqual(@as(f32, 336), list.view.scroll_y);
    _ = draw_list(cx, &list);
    var bands: u32 = 0;
    for (cx.draw.items(draw.Box)) |box| {
        if (box.rect[2] == 200) bands += 1;
    }
    try testing.expectEqual(@as(u32, 1), bands);
    const paged: ListBox.Action = .{ .selected = 33 };
    try testing.expectEqual(paged, fixture.send(cx, &list, key(.page_down)));
    try testing.expectEqual(ListBox.Action{ .selected = 999 }, fixture.send(cx, &list, key(.end)));
    try testing.expectEqual(@as(f32, 24000 - 240), list.view.scroll_y);
    try testing.expectEqual(ListBox.Action{ .selected = 0 }, fixture.send(cx, &list, key(.home)));
    try testing.expectEqual(@as(f32, 0), list.view.scroll_y);
    try testing.expectEqual(ListBox.Action.none, fixture.send(cx, &list, key(.up)));
    try testing.expectEqual(ListBox.Action{ .activated = 0 }, fixture.send(cx, &list, key(.enter)));
}

fn press_at(point: input.Point, time_ms: u32) input.Event {
    var sample = input.left_at(point);
    sample.time_ms = time_ms;
    return .{ .pointer_down = sample };
}

fn release_at(point: input.Point, time_ms: u32) input.Event {
    var sample = input.left_at(point);
    sample.time_ms = time_ms;
    return .{ .pointer_up = sample };
}

// Locks activation by pointer and routing: a double click on row 5 is selected on the first
// release, activated on the second press, and its release adds nothing; `ui.route` reaches a
// list box field, wheel included.
test "a double click activates and a list box routes" {
    const cx = fixture.context();
    const Holder = struct { list: ListBox };
    var holder: Holder = .{ .list = ListBox.init(ui.id("list", 0), 1000, 24) };
    const list = &holder.list;
    _ = draw_list(cx, list);
    const five = row_center(cx, list, 5);
    _ = fixture.send(cx, list, press_at(five, 0));
    const selected: ListBox.Action = .{ .selected = 5 };
    const activated: ListBox.Action = .{ .activated = 5 };
    try testing.expectEqual(selected, fixture.send(cx, list, release_at(five, 0)));
    try testing.expectEqual(activated, fixture.send(cx, list, press_at(five, 100)));
    try testing.expectEqual(ListBox.Action.none, fixture.send(cx, list, release_at(five, 100)));
    const wheel: input.Event = .{ .wheel = .{ .x = five.x, .y = five.y, .dx = 0, .dy = 48 } };
    cx.event_begin(wheel);
    _ = ui.route(cx, wheel, &holder);
    cx.event_end();
    try testing.expectEqual(@as(f32, 48), list.view.scroll_y);
}

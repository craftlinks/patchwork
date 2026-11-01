//! `ColumnHeader`: labelled columns that resize by their right edges and sort by a click, and
//! the spans a table's rows draw into.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Columns
//! Up to `columns_max` columns, each a label, a width, and a minimum. Every column but the last
//! keeps its width; the last spans the rest of the header, at least its minimum:
//! ```text
//! x(i)      = sum of the widths before i
//! width(i)  = widths[i]                                 i < count - 1
//!           = max(min[last], header.width - x(last))    the last
//! ```
//! `cell(row, i)` is that span on a row's rect, inset `header_pad_x` on both sides, so a table's
//! rows (a `ListBox`'s, say) draw each column's text where the header's label is. The header
//! does not sort anything: the app sorts its rows by `sort`.
//!
//! ## 2. Events
//! ```text
//! cell hover_in / hover_out     hovered follows (redraw)
//! cell up inside                the sorted column: flip descending; another: ascending  sorted
//! divider down                  grab: where on the divider the press landed
//! divider drag                  width = clamp(pointer - grab - left, min, room)         resized
//! divider double press          the width at init                                       resized
//! ```
//! A divider is `header_divider_w` wide, centred on the right edge of every column but the
//! last, recorded after the cells so it is on top, with the `ew_resize` cursor. `room` keeps
//! the other fixed columns and the last column's minimum inside the width of the last draw:
//! `room(i) = drawn.width - sum(widths[j], j != i, j < count - 1) - min[last]`, at least
//! `min[i]`.
//!
//! ## 3. Ids
//! Cell `i` is `id.derive(i)` and divider `i` is `id.derive(divider_salt + i)`.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const text = @import("../text.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// Columns one header holds at most.
pub const columns_max: u32 = 16;
/// A header's usual height, the label inset, a divider's width, and the cell's right line, in
/// logical pixels.
pub const header_h: f32 = 28;
pub const header_pad_x: f32 = 8;
pub const header_divider_w: f32 = 8;
pub const header_line_px: f32 = 1;
/// The salt divider ids start from (section 3).
pub const divider_salt: u64 = 0x636f6c73 << 32;

/// Labels start at the cell's left inside the pad and are cut with an ellipsis.
pub const header_text_options: text.Options = .{
    .align_x = .start,
    .align_y = .center,
    .ellipsis = true,
};

/// A divider's area: the resize cursor, no focus.
pub const divider_flags: ui.Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .ew_resize,
    .primary_only = true,
};

/// One column: its label, its width, and the narrowest it resizes to.
pub const Column = struct {
    label: []const u8,
    width: f32,
    min: f32,
};

/// The sorted column and its direction.
pub const Sort = struct {
    column: u32,
    descending: bool,
};

/// The default header: `ColumnHeaderOf(skins.Default)`.
pub const ColumnHeader = ColumnHeaderOf(skin.Default);

/// Columns drawn by `Skin` (`Skin.header_cell`; `widgets/skin.zig`).
pub fn ColumnHeaderOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .column_header)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        columns: [columns_max]Column,
        /// Each column's width at init, which a double press on its divider restores.
        defaults: [columns_max]f32,
        count: u32,
        sort: ?Sort,
        hovered: ?u32,
        /// The header's rect at the last draw; `room` reads its width.
        drawn: Rect,
        /// The dragged divider: where on it the press landed, and its column's left edge.
        grab: f32,
        left: f32,

        pub const Action = union(enum) {
            none,
            sorted: Sort,
            resized: Resized,
        };

        pub const Resized = struct { column: u32, width: f32 };

        /// A header over `columns` (1 to `columns_max`), unsorted.
        pub fn init(id: Id, columns: []const Column) Self {
            assert(id != .none);
            assert(columns.len >= 1 and columns.len <= columns_max);
            var header: Self = .{
                .id = id,
                .columns = undefined,
                .defaults = undefined,
                .count = @intCast(columns.len),
                .sort = null,
                .hovered = null,
                .drawn = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .grab = 0,
                .left = 0,
            };
            for (columns, 0..) |column, index| {
                assert(column.min > 0 and column.width >= column.min);
                header.columns[index] = column;
                header.defaults[index] = column.width;
            }
            return header;
        }

        /// Cell `index`'s id (section 3).
        pub fn cell_id(self: *const Self, index: u32) Id {
            assert(index < columns_max);
            return self.id.derive(index);
        }

        /// Divider `index`'s id, on column `index`'s right edge (section 3).
        pub fn divider_id(self: *const Self, index: u32) Id {
            assert(index < columns_max);
            return self.id.derive(divider_salt + index);
        }

        /// Column `index`'s whole span on `row` (section 1).
        pub fn span(self: *const Self, row: Rect, index: u32) Rect {
            assert(index < self.count);
            var x: f32 = 0;
            for (self.columns[0..index]) |column| x += column.width;
            const last = index + 1 == self.count;
            const width = if (last)
                @max(self.columns[index].min, row.width - x)
            else
                self.columns[index].width;
            return .{ .x = row.x + x, .y = row.y, .width = width, .height = row.height };
        }

        /// Column `index`'s span on `row` inset `header_pad_x`: where a row draws its text.
        pub fn cell(self: *const Self, row: Rect, index: u32) Rect {
            const whole = self.span(row, index);
            return .{
                .x = whole.x + header_pad_x,
                .y = whole.y,
                .width = @max(0, whole.width - 2 * header_pad_x),
                .height = whole.height,
            };
        }

        /// Draws the cells in the box `walk` gets and records their areas, then the dividers
        /// on top. Draw phase.
        pub fn draw(self: *Self, cx: anytype, walk: Walk) void {
            assert(self.count >= 1 and self.count <= columns_max);
            const rect = cx.walk(walk);
            self.drawn = rect;
            const clip = cx.visible(rect) orelse return;
            for (0..self.count) |at| {
                const index: u32 = @intCast(at);
                const whole = self.span(rect, index);
                const inside = cx.visible(whole) orelse continue;
                const sorted: ?bool = if (self.sort) |sort|
                    (if (sort.column == index) sort.descending else null)
                else
                    null;
                const shape = Skin.header_cell(cx, .{
                    .rect = whole,
                    .clip = inside,
                    .label = self.columns[index].label,
                    .sorted = sorted,
                    .hovered = self.hovered != null and self.hovered.? == index,
                }) orelse continue;
                cx.area(self.cell_id(index), shape.rect, shape.radius, ui.cx.primary_flag);
            }
            for (0..self.count - 1) |at| {
                const index: u32 = @intCast(at);
                const whole = self.span(rect, index);
                const divider: Rect = .{
                    .x = whole.x + whole.width - header_divider_w * 0.5,
                    .y = rect.y,
                    .width = header_divider_w,
                    .height = rect.height,
                };
                if (cx.visible(divider) == null) continue;
                cx.area(self.divider_id(index), divider, 0, divider_flags);
            }
            _ = clip;
        }

        /// Cells and dividers (section 2).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.count >= 1 and self.count <= columns_max);
            if (event == .frame) return .none;
            var action: Action = .none;
            for (0..self.count) |at| {
                const index: u32 = @intCast(at);
                switch (cx.hit(self.cell_id(index), event)) {
                    .hover_in => self.hover(cx, index),
                    .hover_out => if (self.hovered == index) self.hover(cx, null),
                    .up => |up| if (up.inside) {
                        action = self.sort_by(cx, index);
                    },
                    .none, .down, .drag, .wheel, .secondary => {},
                }
                if (index + 1 == self.count) continue;
                switch (cx.hit(self.divider_id(index), event)) {
                    .down => |press| {
                        const edge = press.rect.x + press.rect.width * 0.5;
                        self.grab = press.x - edge;
                        self.left = edge - self.columns[index].width;
                        if (press.clicks >= 2) {
                            action = self.resize(cx, index, self.defaults[index]);
                        }
                    },
                    .drag => |press| {
                        const wanted = press.x - self.grab - self.left;
                        action = self.resize(cx, index, wanted);
                    },
                    .none, .hover_in, .hover_out, .up, .wheel, .secondary => {},
                }
            }
            return action;
        }

        /// The widest column `index` may be (section 2).
        pub fn room(self: *const Self, index: u32) f32 {
            assert(index + 1 < self.count);
            var others: f32 = 0;
            for (self.columns[0 .. self.count - 1], 0..) |column, at| {
                if (at != index) others += column.width;
            }
            const last = self.columns[self.count - 1].min;
            return @max(self.columns[index].min, self.drawn.width - others - last);
        }

        fn resize(self: *Self, cx: anytype, index: u32, wanted: f32) Action {
            assert(index + 1 < self.count);
            const width = @round(std.math.clamp(wanted, self.columns[index].min, self.room(index)));
            if (width == self.columns[index].width) return .none;
            self.columns[index].width = width;
            cx.redraw();
            return .{ .resized = .{ .column = index, .width = width } };
        }

        fn sort_by(self: *Self, cx: anytype, index: u32) Action {
            assert(index < self.count);
            var descending = false;
            if (self.sort) |sort| descending = sort.column == index and !sort.descending;
            self.sort = .{ .column = index, .descending = descending };
            cx.redraw();
            return .{ .sorted = self.sort.? };
        }

        fn hover(self: *Self, cx: anytype, index: ?u32) void {
            if (std.meta.eql(self.hovered, index)) return;
            self.hovered = index;
            cx.redraw();
        }
    };
}

comptime {
    assert(divider_salt > columns_max);
    assert(header_divider_w > 0 and header_pad_x > 0);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const sample = [_]Column{
    .{ .label = "name", .width = 200, .min = 80 },
    .{ .label = "kind", .width = 100, .min = 60 },
    .{ .label = "size", .width = 80, .min = 60 },
};

fn draw_header(cx: *fixture.Context, header: *ColumnHeader, width: f32) void {
    cx.begin_frame(1280, 720, 120);
    header.draw(cx, fixture.at(0, 0, width, header_h));
    _ = cx.end_frame();
}

fn expect_sorted(column: u32, descending: bool, action: ColumnHeader.Action) !void {
    const sort: Sort = .{ .column = column, .descending = descending };
    try testing.expectEqual(ColumnHeader.Action{ .sorted = sort }, action);
}

fn expect_resized(width: f32, action: ColumnHeader.Action) !void {
    const resized: ColumnHeader.Resized = .{ .column = 0, .width = width };
    try testing.expectEqual(ColumnHeader.Action{ .resized = resized }, action);
}

fn centre_of(cx: *fixture.Context, id: Id) input.Point {
    const area = cx.find(id).?;
    return .{ .x = area.rect[0] + area.rect[2] * 0.5, .y = area.rect[1] + area.rect[3] * 0.5 };
}

// Locks section 1: in a 500 px header the columns start at 0, 200, and 300, the last spanning
// the 200 px left; a row's cell is the span inset 8; in a 320 px header the last keeps its
// 60 px minimum; the dividers sit on the first two right edges.
test "columns span their widths and the last spans the rest" {
    const cx = fixture.context();
    var header = ColumnHeader.init(ui.id("header", 0), &sample);
    draw_header(cx, &header, 500);
    const row: Rect = .{ .x = 10, .y = 40, .width = 500, .height = 24 };
    const last: Rect = .{ .x = 310, .y = 40, .width = 200, .height = 24 };
    try testing.expectEqual(last, header.span(row, 2));
    const first: Rect = .{ .x = 18, .y = 40, .width = 184, .height = 24 };
    try testing.expectEqual(first, header.cell(row, 0));
    try testing.expectEqualSlices(f32, &.{ 300, 0, 200, 28 }, &cx.find(header.cell_id(2)).?.rect);
    try testing.expectEqualSlices(f32, &.{ 196, 0, 8, 28 }, &cx.find(header.divider_id(0)).?.rect);
    try testing.expect(cx.find(header.divider_id(2)) == null);
    const narrow: Rect = .{ .x = 0, .y = 0, .width = 320, .height = 24 };
    try testing.expectEqual(@as(f32, 60), header.span(narrow, 2).width);
}

// Locks the sort cycle of section 2: a click on kind sorts it ascending, again descending, and a
// click on name sorts name ascending.
test "a header click sorts and a second click flips the direction" {
    const cx = fixture.context();
    var header = ColumnHeader.init(ui.id("header", 0), &sample);
    draw_header(cx, &header, 500);
    const kind = centre_of(cx, header.cell_id(1));
    _ = fixture.send(cx, &header, .{ .pointer_down = input.left_at(kind) });
    const first = fixture.send(cx, &header, .{ .pointer_up = input.left_at(kind) });
    try expect_sorted(1, false, first);
    _ = fixture.send(cx, &header, .{ .pointer_down = input.left_at(kind) });
    const second = fixture.send(cx, &header, .{ .pointer_up = input.left_at(kind) });
    try expect_sorted(1, true, second);
    const name = centre_of(cx, header.cell_id(0));
    _ = fixture.send(cx, &header, .{ .pointer_down = input.left_at(name) });
    const third = fixture.send(cx, &header, .{ .pointer_up = input.left_at(name) });
    try expect_sorted(0, false, third);
}

// Locks resizing (section 2): dragging name's divider 60 px right makes it 260; far left stops
// at its 80 px minimum; far right stops at the room, 500 - 100 (kind) - 60 (size's minimum) =
// 340; a double press restores 200.
test "a divider drag resizes within the minimum and the room" {
    const cx = fixture.context();
    var header = ColumnHeader.init(ui.id("header", 0), &sample);
    draw_header(cx, &header, 500);
    const edge = centre_of(cx, header.divider_id(0));
    _ = fixture.send(cx, &header, .{ .pointer_down = input.left_at(edge) });
    const moved: input.Point = .{ .x = edge.x + 60, .y = edge.y };
    const wider = fixture.send(cx, &header, .{ .pointer_move = moved });
    try expect_resized(260, wider);
    _ = fixture.send(cx, &header, .{ .pointer_move = .{ .x = -400, .y = edge.y } });
    try testing.expectEqual(@as(f32, 80), header.columns[0].width);
    _ = fixture.send(cx, &header, .{ .pointer_move = .{ .x = 1000, .y = edge.y } });
    try testing.expectEqual(@as(f32, 340), header.columns[0].width);
    _ = fixture.send(cx, &header, .{ .pointer_up = input.left_at(.{ .x = 1000, .y = edge.y }) });
    draw_header(cx, &header, 500);
    const shifted = centre_of(cx, header.divider_id(0));
    var press = input.left_at(shifted);
    press.time_ms = 5000;
    _ = fixture.send(cx, &header, .{ .pointer_down = press });
    _ = fixture.send(cx, &header, .{ .pointer_up = press });
    press.time_ms = 5100;
    const reset = fixture.send(cx, &header, .{ .pointer_down = press });
    try expect_resized(200, reset);
}

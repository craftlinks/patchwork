//! `Palette`: a field over a filtered list in a popup, for picking one of many items by typing.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! A palette is a popup that owns a `TextFieldOf(Skin)` and a list. The app owns the items
//! (`PaletteItem`: a label, a right-aligned detail, an enabled flag); the palette keeps the
//! indices of the items shown (`shown`, inline, `config.capacity` of them) and a highlight,
//! which is a row, not an item. It handles every event before the field sees it: it takes Up,
//! Down, Page Up, Page Down, Enter, and Escape itself, with any modifiers, and hands the rest
//! to the field, so the field keeps the caret while the highlight moves. It does not embed a
//! `ListBox`: a list box's view is focusable and takes focus on a row press, which would take
//! focus from the field. The palette draws its rows with the same primitives instead
//! (`ui.ViewState`, `cx.begin_view`, `ui.List.visible`, `list_box.scroll_for`). `TextField`,
//! `ListBox`, and `Menu` are untouched. Home and End stay with the field.
//!
//! ## 2. Filtering
//! With `filter = .label` every text change runs `filter_items`: the items whose label starts
//! with the text, in item order, then those that hold it elsewhere, in item order; ASCII case
//! is folded and other bytes compare exactly; an empty text lists every item. With `.app` a
//! change leaves the rows alone and returns `filtered`; the app then calls `show(cx, rows)`
//! with its own item indices. `open_at` always shows every item in order. After changing the
//! items while open, an app with `.label` calls `filter_now(cx)`. After any refilter the
//! highlight is the first enabled row, the scroll is 0, and the view's content height is
//! set, so a key before the next draw clamps against the new content.
//!
//! ## 3. Events
//! `handle(cx, event) Action` (`none`, `filtered`, `chosen: item`, `dismissed`), in order,
//! each step running only when the earlier ones did not return:
//! ```text
//! closed, or a frame        none
//! id anchor not drawn       dismissed
//! field focus_lost          dismissed (Tab, a focusable area pressed, the app moved focus),
//!                           except on pointer_down
//! key_down                  the keys (section 4); paste goes to the field
//! backdrop down, secondary  dismissed: the press reaches nothing beneath
//! any other pointer_down    focus the field (a press on an unfocusable row clears it)
//! view                      the wheel and the thumb
//! rows (last draw)          hover_in on an enabled row highlights it without scrolling
//!                           (a wheel hovers the row under the pointer, and scrolling it into
//!                           view would undo the wheel); up inside on an enabled row: chosen;
//!                           hover_out does nothing; a press on a disabled row does nothing
//! everything else           the field: caret, selection, drag; a change refilters, filtered
//! ```
//! Row ids are by row, not item, so a refilter under a resting pointer moves no hot id and no
//! synthetic hover pulls the highlight off the first row.
//!
//! ## 4. Keys
//! Keys count only while the field is focused, and the event that gave it focus is ignored,
//! so the `/` or Ctrl+K that opened the palette is not typed (and the context counts it
//! consumed in the browser, `ui/cx.zig` section 7). Escape dismisses. Enter chooses an
//! enabled highlight and does nothing for none or a disabled one. Down and Up move to the
//! next or previous enabled row, wrapping; from none, the first or last. Page Down and Page
//! Up move over up to `config.rows` enabled rows, stopping at the last enabled row before the
//! end. A key move scrolls the row into view. Tab moves focus before the palette sees it, so
//! it arrives as `focus_lost` and dismisses. Closing clears focus and never restores it.
//!
//! ## 5. Drawing and Geometry
//! The popup is `width` wide and `height_for(rows)` high. It is placed once, at the height of
//! `config.rows` rows, so the field never moves while the text changes; it is drawn from that
//! top-left at the height of the rows shown (at least one). Inside the popup's padding:
//! the face's own plain area (a press on the padding is the palette's), `menu_face`, the
//! field, then either the list (a view of rows of `palette_row_h`, walked over
//! `ui.List.visible`, with skips giving the view its full content height) or, when nothing is
//! shown, one disabled `palette_row` of `empty`. Rows are the viewport less the view's gutter.
//!
//! ## 6. Counts
//! `appends_for(PaletteText)`: the face, the field's, the larger of the list (rows + 1 walked
//! rows, the view's thumb, an area per row, the view, and the thumb) and the empty line, and
//! two areas (the backdrop and the face). The palette is a popup with no face of its own, so
//! an app takes the `max` of it and its other popups (`widgets.zig`, section 4).
//!
//! ## 7. TigerStyle Invariants
//! - No allocation: `shown` is inline and every index in it is below `items.len`.
//! - `highlight` is below `count` when set.
//! - A draw walks at most `rows + 1` rows (asserted); `handle` is O(walked rows) plus
//!   O(items * text) on a change.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const draw = @import("../draw.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const menu_file = @import("menu.zig");
const list_box = @import("list_box.zig");
const field_file = @import("text_field.zig");
const appends = @import("appends.zig");
const Appends = appends.Appends;

const Id = kit.Id;
const Rect = kit.Rect;
const popup = ui.popup;

/// The most items a palette's `capacity` may be.
pub const palette_items_max: u32 = 1 << 16;
/// The popup's width unless the app sets `width`.
pub const palette_width: f32 = 360;
/// Space inside the face around the field and the list.
pub const palette_pad: f32 = 6;
/// The field's height.
pub const palette_field_h: f32 = 32;
/// Space between the field and the list.
pub const palette_gap: f32 = 4;
/// A row's height: a menu row's.
pub const palette_row_h: f32 = menu_file.menu_row_h;
/// Rows the list shows before it scrolls unless the config says otherwise.
pub const palette_rows_default: u32 = 8;
/// A row's text inset from its sides: the field's, so labels line up under the typed text.
pub const palette_text_inset: f32 = field_file.field_padding_x;
/// The least room between a row's label and its detail.
pub const palette_detail_gap: f32 = 12;
/// The line the list shows when no row is shown, unless the app sets `empty`.
pub const palette_empty = "No matches";
/// Salts of the field's id, the list view's id, and the rows' ids: `id.derive(...)`.
pub const palette_field_salt: u64 = 0x6669656c64;
pub const palette_list_salt: u64 = 0x6c697374;
pub const palette_row_salt: u64 = list_box.row_salt;

/// A detail is drawn at the right, never cut.
pub const palette_detail_options: text.Options = .{
    .align_x = .end,
    .align_y = .center,
    .ellipsis = false,
};

/// One item: what its row shows and whether it can be highlighted and chosen.
pub const PaletteItem = struct {
    label: []const u8,
    detail: []const u8 = "",
    enabled: bool = true,
};

pub const PaletteConfig = struct {
    /// Items the palette holds at most, and so rows it shows at most.
    capacity: u32,
    /// Rows the list shows before it scrolls.
    rows: u32 = palette_rows_default,
};

/// Who fills the shown rows when the text changes.
pub const PaletteFilter = enum { label, app };

/// What a palette's text is at most, for `appends_for`.
pub const PaletteText = struct {
    field: field_file.FieldText,
    label_max: u32,
    detail_max: u32 = 0,
    empty: u32 = palette_empty.len,

    /// The longest label and detail of `items`, beside `field`.
    pub fn of(
        comptime items: []const PaletteItem,
        comptime field: field_file.FieldText,
    ) PaletteText {
        comptime {
            var label_max: u32 = 0;
            var detail_max: u32 = 0;
            for (items) |item| {
                label_max = @max(label_max, item.label.len);
                detail_max = @max(detail_max, item.detail.len);
            }
            return .{ .field = field, .label_max = label_max, .detail_max = detail_max };
        }
    }
};

/// The items whose label matches `needle`, ASCII case folded, into `out` in item order: those
/// that start with it, then those that hold it elsewhere. An empty needle matches every item.
/// Returns how many.
pub fn filter_items(items: []const PaletteItem, needle: []const u8, out: []u32) u32 {
    assert(items.len <= out.len);
    var count: u32 = 0;
    for (items, 0..) |item, index| {
        if (!std.ascii.startsWithIgnoreCase(item.label, needle)) continue;
        out[count] = @intCast(index);
        count += 1;
    }
    for (items, 0..) |item, index| {
        if (std.ascii.startsWithIgnoreCase(item.label, needle)) continue;
        if (std.ascii.findIgnoreCase(item.label, needle) == null) continue;
        out[count] = @intCast(index);
        count += 1;
    }
    assert(count <= items.len);
    return count;
}

/// The popup's height with `rows` list rows.
pub fn height_for(rows: u32) f32 {
    assert(rows >= 1);
    const list_h = @as(f32, @floatFromInt(rows)) * palette_row_h;
    return 2 * palette_pad + palette_field_h + palette_gap + list_h;
}

pub fn Palette(comptime config: PaletteConfig) type {
    return PaletteOf(skin.Default, config);
}

pub fn PaletteOf(comptime Skin: type, comptime config: PaletteConfig) type {
    if (comptime skin.check(Skin, .palette)) |problem| @compileError(problem);
    comptime assert(config.capacity >= 1 and config.capacity <= palette_items_max);
    comptime assert(config.rows >= 1 and config.rows <= config.capacity);
    return struct {
        const Self = @This();

        pub const Field = field_file.TextFieldOf(Skin);

        id: Id,
        field: Field,
        items: []const PaletteItem,
        shown: [config.capacity]u32,
        count: u32,
        highlight: ?u32,
        view: ui.ViewState,
        range: ui.List.Range,
        open: bool,
        anchor: popup.Anchor,
        side: popup.Side,
        bounds: ?Rect,
        filter: PaletteFilter = .label,
        width: f32 = palette_width,
        empty: []const u8 = palette_empty,
        material: ?kit.Material = null,

        pub const Action = union(enum) {
            none,
            filtered,
            chosen: u32,
            dismissed,
        };

        pub fn appends_for(comptime palette_text: PaletteText) Appends {
            comptime {
                assert(palette_text.label_max <= text.byte_cap);
                assert(palette_text.detail_max <= text.byte_cap);
                assert(palette_text.empty <= text.byte_cap);
                const walked = config.rows + 1;
                const bytes = palette_text.label_max + palette_text.detail_max;
                const walked_rows = Skin.palette_row_appends.with(bytes).times(walked);
                const list = walked_rows.plus(.{
                    .draws = &.{.{ .type = draw.Box, .count = 1 }},
                    .areas = walked + 2,
                });
                const empty = Skin.palette_row_appends.with(palette_text.empty);
                const face = Skin.menu_face_appends.with(0);
                const field = Field.appends_for(palette_text.field);
                return face.plus(field).plus(list.max(empty)).plus(.{ .areas = 2 });
            }
        }

        pub fn init(id: Id, items: []const PaletteItem, limit: u32, style: text.Style) Self {
            assert(id != .none);
            assert(items.len <= config.capacity);
            return .{
                .id = id,
                .field = Field.init(id.derive(palette_field_salt), limit, style),
                .items = items,
                .shown = undefined,
                .count = 0,
                .highlight = null,
                .view = ui.ViewState.init(),
                .range = .{ .first = 0, .end = 0 },
                .open = false,
                .anchor = .{ .id = id },
                .side = .below,
                .bounds = null,
            };
        }

        pub fn list_id(self: *const Self) Id {
            return self.id.derive(palette_list_salt);
        }

        pub fn row_id(self: *const Self, row: u32) Id {
            assert(row < palette_items_max);
            return self.id.derive(palette_row_salt + row);
        }

        pub fn rows(self: *const Self) []const u32 {
            return self.shown[0..self.count];
        }

        pub fn open_at(self: *Self, cx: anytype, anchor: popup.Anchor, side: popup.Side) void {
            self.open = true;
            self.anchor = anchor;
            self.side = side;
            self.field.load("");
            self.range = .{ .first = 0, .end = 0 };
            self.filter_now(cx);
            cx.set_focus(self.field.id);
            cx.request_popup(self.id);
            assert(self.open);
        }

        pub fn close(self: *Self, cx: anytype) void {
            self.open = false;
            self.highlight = null;
            if (cx.focused(self.field.id)) cx.clear_focus();
            cx.redraw();
        }

        pub fn filter_now(self: *Self, cx: anytype) void {
            assert(self.items.len <= config.capacity);
            self.count = filter_items(self.items, self.field.bytes(), &self.shown);
            self.reset(cx);
        }

        pub fn show(self: *Self, cx: anytype, shown_rows: []const u32) void {
            assert(shown_rows.len <= config.capacity);
            for (shown_rows, 0..) |item, at| {
                assert(item < self.items.len);
                self.shown[at] = item;
            }
            self.count = @intCast(shown_rows.len);
            self.reset(cx);
        }

        fn reset(self: *Self, cx: anytype) void {
            self.highlight = self.step_from(null, true);
            self.view.scroll_y = 0;
            self.view.content_h = @as(f32, @floatFromInt(self.count)) * palette_row_h;
            cx.redraw();
        }

        fn enabled_row(self: *const Self, row: u32) bool {
            assert(row < self.count);
            return self.items[self.shown[row]].enabled;
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            if (!self.open) return .none;
            if (event == .frame) return .none;
            if (self.anchor == .id and cx.find(self.anchor.id) == null) return self.dismiss(cx);
            const field_id = self.field.id;
            if (cx.focus_lost(field_id) and event != .pointer_down) return self.dismiss(cx);
            switch (event) {
                .key_down => |press| return self.key(cx, press),
                .paste => return self.typed(cx, event),
                else => {},
            }
            switch (cx.hit(cx.popup_backdrop(self.id), event)) {
                .down, .secondary => return self.dismiss(cx),
                else => {},
            }
            if (event == .pointer_down) cx.set_focus(field_id);
            _ = self.view.handle(cx, self.list_id(), event);
            var row = self.range.first;
            while (row < @min(self.range.end, self.count)) : (row += 1) {
                switch (cx.hit(self.row_id(row), event)) {
                    .hover_in => if (self.enabled_row(row)) self.hover_to(cx, row),
                    .up => |up| {
                        if (up.inside and self.enabled_row(row)) return self.choose(cx, row);
                    },
                    else => {},
                }
            }
            return self.typed(cx, event);
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(self.open);
            if (!cx.focused(self.field.id)) return .none;
            if (cx.focus_gained(self.field.id)) return .none;
            switch (press.key) {
                .escape => return self.dismiss(cx),
                .enter => {
                    const row = self.highlight orelse return .none;
                    if (!self.enabled_row(row)) return .none;
                    return self.choose(cx, row);
                },
                .down => self.move_to(cx, self.step_from(self.highlight, true)),
                .up => self.move_to(cx, self.step_from(self.highlight, false)),
                .page_down => self.move_to(cx, self.page_from(self.highlight, true)),
                .page_up => self.move_to(cx, self.page_from(self.highlight, false)),
                else => return self.typed(cx, .{ .key_down = press }),
            }
            return .none;
        }

        fn typed(self: *Self, cx: anytype, event: input.Event) Action {
            switch (self.field.handle(cx, event)) {
                .changed => {
                    if (self.filter == .label) self.filter_now(cx);
                    return .filtered;
                },
                .none, .committed, .cancelled => return .none,
            }
        }

        fn step_from(self: *const Self, from: ?u32, forward: bool) ?u32 {
            if (self.count == 0) return null;
            const count = self.count;
            var at: u32 = if (from) |row| row else if (forward) count - 1 else 0;
            var tried: u32 = 0;
            while (tried < count) : (tried += 1) {
                at = if (forward) (at + 1) % count else (at + count - 1) % count;
                if (self.enabled_row(at)) return at;
            }
            return null;
        }

        fn page_from(self: *const Self, from: ?u32, forward: bool) ?u32 {
            const start = from orelse return self.step_from(null, forward);
            assert(start < self.count);
            var best: u32 = start;
            var passed: u32 = 0;
            var at = start;
            while (passed < config.rows) {
                if (forward) {
                    if (at + 1 >= self.count) break;
                    at += 1;
                } else {
                    if (at == 0) break;
                    at -= 1;
                }
                if (!self.enabled_row(at)) continue;
                best = at;
                passed += 1;
            }
            return best;
        }

        fn hover_to(self: *Self, cx: anytype, row: u32) void {
            if (self.highlight != null and self.highlight.? == row) return;
            self.highlight = row;
            cx.redraw();
        }

        fn move_to(self: *Self, cx: anytype, row: ?u32) void {
            if (std.meta.eql(self.highlight, row)) return;
            self.highlight = row;
            cx.redraw();
            const index = row orelse return;
            const view_h = self.view.viewport.height;
            const offset = list_box.scroll_for(self.view.scroll_y, index, palette_row_h, view_h);
            _ = self.view.scroll_to(cx, offset);
        }

        fn choose(self: *Self, cx: anytype, row: u32) Action {
            assert(self.enabled_row(row));
            const item = self.shown[row];
            self.close(cx);
            return .{ .chosen = item };
        }

        fn dismiss(self: *Self, cx: anytype) Action {
            assert(self.open);
            self.close(cx);
            return .dismissed;
        }

        pub fn draw_overlay(self: *Self, cx: anytype) void {
            assert(self.id != .none);
            if (!self.open) return;
            const anchor: Rect = switch (self.anchor) {
                .id => |anchor_id| blk: {
                    const found = cx.find(anchor_id) orelse {
                        cx.skip_popup(self.id);
                        return;
                    };
                    break :blk .{
                        .x = found.rect[0],
                        .y = found.rect[1],
                        .width = found.rect[2],
                        .height = found.rect[3],
                    };
                },
                .point => |point| popup.anchor_rect(point),
            };
            const full: [2]f32 = .{ self.width, height_for(config.rows) };
            var rect = popup.place(anchor, full, self.bounds orelse cx.window, self.side);
            const list_rows: u32 = @max(1, @min(self.count, config.rows));
            rect.height = @min(rect.height, height_for(list_rows));
            const material = self.material orelse cx.theme().material;
            _ = kit.backdrop(cx, .popup, material);
            const layout: ui.Layout = .{
                .flow = .down,
                .spacing = palette_gap,
                .padding = .all(palette_pad),
                .clip = true,
            };
            _ = cx.begin_popup(self.id, rect, layout, 0);
            const clip = cx.clip().?;
            cx.area(self.id, rect, cx.theme().form.radius.popup, ui.cx.plain);
            Skin.menu_face(cx, .{ .rect = rect, .clip = clip, .material = material });
            self.field.draw(cx, ui.sized(.fill, .{ .fixed = palette_field_h }));
            const style = cx.theme().name;
            if (self.count == 0) {
                self.range = .{ .first = 0, .end = 0 };
                const line = cx.walk(ui.sized(.fill, .{ .fixed = palette_row_h }));
                if (cx.visible(line)) |line_clip| Skin.palette_row(cx, .{
                    .rect = line,
                    .clip = line_clip,
                    .label = self.empty,
                    .detail = "",
                    .style = style,
                    .enabled = false,
                    .highlighted = false,
                });
                cx.end_popup();
                return;
            }
            const fill = ui.sized(.fill, .fill);
            const port = cx.begin_view(self.list_id(), fill, ui.flow_of(.down), &self.view);
            const list: ui.List = .{ .row_height = palette_row_h, .count = self.count };
            self.range = list.visible(self.view.scroll_y, port.height);
            assert(self.range.end - self.range.first <= config.rows + 1);
            cx.skip(@as(f32, @floatFromInt(self.range.first)) * palette_row_h);
            var row = self.range.first;
            while (row < self.range.end) : (row += 1) {
                const row_rect = cx.walk(ui.sized(.fill, .{ .fixed = palette_row_h }));
                const row_clip = cx.visible(row_rect) orelse continue;
                cx.area(self.row_id(row), row_rect, 0, ui.cx.primary_flag);
                const item = self.items[self.shown[row]];
                Skin.palette_row(cx, .{
                    .rect = row_rect,
                    .clip = row_clip,
                    .label = item.label,
                    .detail = item.detail,
                    .style = style,
                    .enabled = item.enabled,
                    .highlighted = item.enabled and std.meta.eql(self.highlight, row),
                });
            }
            cx.skip(@as(f32, @floatFromInt(self.count - self.range.end)) * palette_row_h);
            cx.end_view();
            cx.end_popup();
        }
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const theme = @import("../theme.zig");

const test_items = [_]PaletteItem{
    .{ .label = "Go to basics", .detail = "page" },
    .{ .label = "Go to popups", .detail = "page" },
    .{ .label = "Go to containers", .detail = "page" },
    .{ .label = "Go to type", .detail = "page" },
    .{ .label = "Go to files", .detail = "page" },
    .{ .label = "Go to surfaces", .detail = "page" },
    .{ .label = "Go to glass", .detail = "page" },
    .{ .label = "Go to data", .detail = "page" },
    .{ .label = "Go to code", .detail = "page" },
    .{ .label = "Go to tabs", .detail = "page" },
    .{ .label = "Light theme", .detail = "view" },
    .{ .label = "Dark theme", .detail = "view" },
    .{ .label = "Wave sine", .detail = "wave" },
    .{ .label = "Wave triangle", .detail = "wave" },
    .{ .label = "Wave saw", .detail = "wave" },
    .{ .label = "Wave square", .detail = "wave" },
    .{ .label = "Wave noise", .detail = "wave" },
    .{ .label = "Wave sample & hold", .detail = "wave" },
    .{ .label = "About…", .detail = "help" },
    .{ .label = "Undo", .detail = "edit", .enabled = false },
    .{ .label = "Redo", .detail = "edit", .enabled = false },
};

const P = Palette(.{ .capacity = 21 });
const test_style: text.Style = .{ .face = .sans, .size = 14, .color = .{ 1, 1, 1, 1 } };
const test_text = PaletteText.of(&test_items, .{ .limit = 32 });

fn begin_frame(cx: anytype) void {
    cx.begin_frame(1280, 720, 120);
}

fn frame_of(cx: anytype, p: *P) void {
    begin_frame(cx);
    ui.overlays(cx, p);
    _ = cx.end_frame();
}

fn opened(cx: anytype, p: *P) void {
    frame_of(cx, p);
    cx.event_begin(.{ .frame = 0 });
    p.open_at(cx, .{ .point = .{ 460, 104 } }, .at);
    cx.event_end();
    frame_of(cx, p);
}

fn press_key(cx: anytype, p: *P, key: input.Key, typed: []const u8) P.Action {
    return fixture.send(cx, p, .{ .key_down = input.key_press(key, .none, false, typed) });
}

fn rect_of(cx: anytype, id: Id) [4]f32 {
    return cx.find(id).?.rect;
}

fn center_of(cx: anytype, id: Id) input.Point {
    const rect = rect_of(cx, id);
    return .{ .x = rect[0] + 10, .y = rect[1] + 10 };
}

// Locks the filter: every item for "", ten "Go to" pages for "go", the prefix before the
// substring ("da": Dark theme, then Go to data), disabled items listed like any, case folded,
// and nothing for "zz".
test "filter_items lists prefix matches, then the rest, case folded" {
    var out: [test_items.len]u32 = undefined;
    try testing.expectEqual(@as(u32, 21), filter_items(&test_items, "", &out));
    try testing.expectEqual(@as(u32, 10), filter_items(&test_items, "go", &out));
    var count = filter_items(&test_items, "da", &out);
    try testing.expectEqualSlices(u32, &.{ 11, 7 }, out[0..count]);
    count = filter_items(&test_items, "re", &out);
    try testing.expectEqualSlices(u32, &.{ 20, 15 }, out[0..count]);
    count = filter_items(&test_items, "TH", &out);
    try testing.expectEqualSlices(u32, &.{ 10, 11 }, out[0..count]);
    count = filter_items(&test_items, "a", &out);
    const expected = [_]u32{ 18, 0, 2, 5, 6, 7, 9, 11, 12, 13, 14, 15, 16, 17 };
    try testing.expectEqualSlices(u32, &expected, out[0..count]);
    try testing.expectEqual(@as(u32, 0), filter_items(&test_items, "zz", &out));
}

// Locks the open palette's geometry at (460, 104): face (460, 104, 360, 272), field (466, 110,
// 348, 32), list (466, 146, 348, 224), row 0 (466, 146, 332, 28), rows 0 to 7 walked.
test "an open palette places its field and rows" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    try testing.expect(cx.focused(p.field.id));
    try testing.expectEqual(@as(u32, 21), p.count);
    try testing.expectEqual(@as(?u32, 0), p.highlight);
    try testing.expectEqualSlices(f32, &.{ 460, 104, 360, 272 }, &rect_of(cx, p.id));
    try testing.expectEqualSlices(f32, &.{ 466, 110, 348, 32 }, &rect_of(cx, p.field.id));
    try testing.expectEqualSlices(f32, &.{ 466, 146, 348, 224 }, &rect_of(cx, p.list_id()));
    try testing.expectEqualSlices(f32, &.{ 466, 146, 332, 28 }, &rect_of(cx, p.row_id(0)));
    try testing.expect(cx.find(p.row_id(7)) != null);
    try testing.expect(cx.find(p.row_id(8)) == null);
    try testing.expectEqual(ui.List.Range{ .first = 0, .end = 8 }, p.range);
    try testing.expect(cx.find(cx.popup_backdrop(p.id)) != null);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the keys: "a" lists 14 rows; Page Down goes to row 8 (scroll 28), Down to 9 (56, rows 2
// to 9 walked), Page Up to 1; Home moves the field's caret and not the highlight; Page Down
// stops at the last row, Down wraps to 0 and Up to 13; Enter chooses item 17.
test "keys move the highlight while the field keeps the caret" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    try testing.expectEqual(P.Action.filtered, press_key(cx, &p, .a, "a"));
    frame_of(cx, &p);
    try testing.expectEqual(@as(u32, 14), p.count);
    try testing.expectEqual(@as(?u32, 0), p.highlight);
    try testing.expectEqual(P.Action.none, press_key(cx, &p, .page_down, ""));
    try testing.expectEqual(@as(?u32, 8), p.highlight);
    try testing.expectEqual(@as(f32, 28), p.view.scroll_y);
    frame_of(cx, &p);
    _ = press_key(cx, &p, .down, "");
    try testing.expectEqual(@as(?u32, 9), p.highlight);
    try testing.expectEqual(@as(f32, 56), p.view.scroll_y);
    frame_of(cx, &p);
    try testing.expectEqual(ui.List.Range{ .first = 2, .end = 10 }, p.range);
    _ = press_key(cx, &p, .page_up, "");
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    try testing.expectEqual(@as(f32, 28), p.view.scroll_y);
    _ = press_key(cx, &p, .home, "");
    try testing.expectEqual(@as(u32, 0), p.field.edit.caret);
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    try testing.expectEqual(@as(f32, 28), p.view.scroll_y);
    frame_of(cx, &p);
    _ = press_key(cx, &p, .page_down, "");
    try testing.expectEqual(@as(?u32, 9), p.highlight);
    frame_of(cx, &p);
    _ = press_key(cx, &p, .page_down, "");
    try testing.expectEqual(@as(?u32, 13), p.highlight);
    try testing.expectEqual(@as(f32, 168), p.view.scroll_y);
    frame_of(cx, &p);
    _ = press_key(cx, &p, .down, "");
    try testing.expectEqual(@as(?u32, 0), p.highlight);
    try testing.expectEqual(@as(f32, 0), p.view.scroll_y);
    _ = press_key(cx, &p, .up, "");
    try testing.expectEqual(@as(?u32, 13), p.highlight);
    try testing.expectEqual(P.Action{ .chosen = 17 }, press_key(cx, &p, .enter, ""));
    try testing.expect(!p.open);
    try testing.expect(!cx.focused(p.field.id));
}

// Locks disabled rows: "re" shows Redo (disabled) then Wave square; the highlight starts on row
// 1 and Down, Up, and Page Up stay there; only row 1 draws a selection band, at y 174; Enter
// chooses item 15.
test "disabled rows are shown, greyed, and skipped" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    _ = press_key(cx, &p, .r, "r");
    _ = press_key(cx, &p, .e, "e");
    try testing.expectEqualSlices(u32, &.{ 20, 15 }, p.rows());
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    _ = press_key(cx, &p, .down, "");
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    _ = press_key(cx, &p, .up, "");
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    _ = press_key(cx, &p, .page_up, "");
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    frame_of(cx, &p);
    var bands: u32 = 0;
    for (cx.draw.items(draw.Box)) |box| {
        if (!std.meta.eql(box.fill, theme.dark.colors.selection)) continue;
        bands += 1;
        try testing.expectEqual(@as(f32, 174), box.rect[1]);
    }
    try testing.expectEqual(@as(u32, 1), bands);
    try testing.expectEqual(P.Action{ .chosen = 15 }, press_key(cx, &p, .enter, ""));
}

// Locks the empty line: "zz" shows no list, a face 76 high, and Enter does nothing; Backspace
// keeps 0 matches for "z" and 21 for ""; Escape dismisses and clears focus.
test "no match shows the empty line and Enter does nothing" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    _ = press_key(cx, &p, .z, "z");
    _ = press_key(cx, &p, .z, "z");
    frame_of(cx, &p);
    try testing.expectEqual(@as(u32, 0), p.count);
    try testing.expectEqual(@as(?u32, null), p.highlight);
    try testing.expect(cx.find(p.list_id()) == null);
    try testing.expect(cx.find(p.row_id(0)) == null);
    try testing.expectEqual(@as(f32, 76), rect_of(cx, p.id)[3]);
    try testing.expectEqual(P.Action.none, press_key(cx, &p, .enter, ""));
    try testing.expect(p.open);
    try testing.expectEqual(P.Action.filtered, press_key(cx, &p, .backspace, ""));
    try testing.expectEqualStrings("z", p.field.bytes());
    try testing.expectEqual(@as(u32, 0), p.count);
    try testing.expectEqual(P.Action.filtered, press_key(cx, &p, .backspace, ""));
    try testing.expectEqualStrings("", p.field.bytes());
    try testing.expectEqual(@as(u32, 21), p.count);
    try testing.expectEqual(@as(?u32, 0), p.highlight);
    try testing.expectEqual(P.Action.dismissed, press_key(cx, &p, .escape, ""));
    try testing.expect(!cx.focused(p.field.id));
}

// Locks the pointer: a wheel of 400 scrolls to 364 and the hover does not pull it back (rows 13
// to 20 walked); Redo (disabled) is not highlighted and a press there keeps focus and the
// palette; About (18) highlights and a click chooses it; a press on the padding stays open and
// a press outside dismisses.
test "the pointer wheels, hovers, and clicks" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    const list = rect_of(cx, p.list_id());
    const wheel: input.Event = .{
        .wheel = .{ .x = list[0] + 100, .y = list[1] + 100, .dx = 0, .dy = 400 },
    };
    _ = fixture.send(cx, &p, wheel);
    try testing.expectEqual(@as(f32, 364), p.view.scroll_y);
    frame_of(cx, &p);
    try testing.expectEqual(ui.List.Range{ .first = 13, .end = 21 }, p.range);
    const before = p.highlight;
    const redo = center_of(cx, p.row_id(20));
    _ = fixture.send(cx, &p, .{ .pointer_move = redo });
    try testing.expectEqual(before, p.highlight);
    _ = fixture.send(cx, &p, .{ .pointer_down = input.left_at(redo) });
    try testing.expect(cx.focused(p.field.id));
    const up = fixture.send(cx, &p, .{ .pointer_up = input.left_at(redo) });
    try testing.expectEqual(P.Action.none, up);
    try testing.expect(p.open);
    const about = center_of(cx, p.row_id(18));
    _ = fixture.send(cx, &p, .{ .pointer_move = about });
    try testing.expectEqual(@as(?u32, 18), p.highlight);
    _ = fixture.send(cx, &p, .{ .pointer_down = input.left_at(about) });
    const chosen = fixture.send(cx, &p, .{ .pointer_up = input.left_at(about) });
    try testing.expectEqual(P.Action{ .chosen = 18 }, chosen);
    try testing.expect(!p.open);
    opened(cx, &p);
    const pad: input.Point = .{ .x = 462, .y = 106 };
    _ = fixture.send(cx, &p, .{ .pointer_move = pad });
    _ = fixture.send(cx, &p, .{ .pointer_down = input.left_at(pad) });
    try testing.expect(cx.focused(p.field.id));
    try testing.expect(p.open);
    _ = fixture.send(cx, &p, .{ .pointer_up = input.left_at(pad) });
    const outside: input.Point = .{ .x = 20, .y = 600 };
    _ = fixture.send(cx, &p, .{ .pointer_move = outside });
    const down = fixture.send(cx, &p, .{ .pointer_down = input.left_at(outside) });
    try testing.expectEqual(P.Action.dismissed, down);
}

fn other_frame(cx: anytype, p: *P) void {
    begin_frame(cx);
    const area: Rect = .{ .x = 0, .y = 600, .width = 80, .height = 20 };
    cx.area(ui.id("other", 0), area, 0, field_file.field_flags);
    ui.overlays(cx, p);
    _ = cx.end_frame();
}

// Locks the opening key: a "/" that opens the palette is not typed and counts consumed; Tab
// dismisses and focus lands on the first focusable area.
test "the key that opens the palette is not typed, and Tab dismisses" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    other_frame(cx, &p);
    const slash: input.Event = .{ .key_down = input.key_press(.other, .none, false, "/") };
    cx.event_begin(slash);
    p.open_at(cx, .{ .point = .{ 460, 104 } }, .at);
    try testing.expectEqual(P.Action.none, p.handle(cx, slash));
    cx.event_end();
    try testing.expect(cx.consumed());
    try testing.expectEqual(@as(usize, 0), p.field.bytes().len);
    other_frame(cx, &p);
    try testing.expectEqual(P.Action.dismissed, press_key(cx, &p, .tab, ""));
    try testing.expect(!p.open);
    try testing.expect(cx.focused(ui.id("other", 0)));
}

// Locks the app filter: a change returns filtered and leaves 21 rows; show lists items 19 and 4,
// the first row (19) disabled so the highlight is row 1, at scroll 0.
test "an app filter shows the app's rows" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    opened(cx, &p);
    p.filter = .app;
    try testing.expectEqual(P.Action.filtered, press_key(cx, &p, .x, "x"));
    try testing.expectEqual(@as(u32, 21), p.count);
    cx.event_begin(.{ .frame = 0 });
    p.show(cx, &.{ 19, 4 });
    cx.event_end();
    try testing.expectEqualSlices(u32, &.{ 19, 4 }, p.rows());
    try testing.expectEqual(@as(?u32, 1), p.highlight);
    try testing.expectEqual(@as(f32, 0), p.view.scroll_y);
}

// Locks the anchor rule: below an id that is drawn it opens with a backdrop; a frame without
// the anchor skips the popup and the next event dismisses.
test "a palette anchored to an id closes when the anchor is not drawn" {
    const cx = fixture.wide_context();
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    const anchor = ui.id("anchor", 0);
    const anchor_rect: Rect = .{ .x = 20, .y = 20, .width = 80, .height = 32 };
    begin_frame(cx);
    cx.area(anchor, anchor_rect, 0, ui.cx.primary_flag);
    ui.overlays(cx, &p);
    _ = cx.end_frame();
    cx.event_begin(.{ .frame = 0 });
    p.open_at(cx, .{ .id = anchor }, .below);
    cx.event_end();
    begin_frame(cx);
    cx.area(anchor, anchor_rect, 0, ui.cx.primary_flag);
    ui.overlays(cx, &p);
    _ = cx.end_frame();
    try testing.expect(cx.find(cx.popup_backdrop(p.id)) != null);
    frame_of(cx, &p);
    try testing.expect(cx.find(cx.popup_backdrop(p.id)) == null);
    try testing.expectEqual(P.Action.dismissed, press_key(cx, &p, .a, "a"));
    try testing.expect(!p.open);
}

// Locks the count with a counted skin: 4 rows walked (rows 0 to 3, scroll 14) give Box 22, Glyph
// 48, areas 9, and the tally reaches every bound.
test "Palette appends exactly appends_for with a counted skin" {
    const cx = fixture.wide_context();
    const Counted = PaletteOf(fixture.Counted, .{ .capacity = 12, .rows = 3 });
    const items: [12]PaletteItem = @splat(.{
        .label = fixture.inked(7),
        .detail = fixture.inked(3),
    });
    const need = comptime Counted.appends_for(.{
        .field = .{ .limit = 8 },
        .label_max = 7,
        .detail_max = 3,
    });
    var tally: fixture.Tally(need) = .{};
    var counted = Counted.init(ui.id("palette", 0), &items, 8, test_style);
    cx.begin_frame(1280, 720, 120);
    ui.overlays(cx, &counted);
    _ = cx.end_frame();
    try tally.observe(cx);
    cx.event_begin(.{ .frame = 0 });
    counted.open_at(cx, .{ .point = .{ 100, 100 } }, .at);
    counted.field.load(fixture.inked(8));
    counted.view.scroll_y = 14;
    cx.event_end();
    cx.begin_frame(1280, 720, 120);
    ui.overlays(cx, &counted);
    _ = cx.end_frame();
    try testing.expectEqual(ui.List.Range{ .first = 0, .end = 4 }, counted.range);
    try testing.expectEqual(@as(usize, 22), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 48), cx.draw.items(draw.Glyph).len);
    try testing.expectEqual(@as(u32, 9), cx.area_count);
    try tally.observe(cx);
    try tally.expect_reached();
}

// Locks the default skin's worked bound (Box 14, Glass 1, Glyph 239, areas 14), PaletteText.of,
// and the keys test's frames under the tally.
test "Palette appends at most appends_for" {
    const need = comptime P.appends_for(.{
        .field = .{ .limit = 32, .hint = 12 },
        .label_max = 18,
        .detail_max = 5,
    });
    try testing.expectEqual(@as(u32, 14), comptime need.of(draw.Box));
    try testing.expectEqual(@as(u32, 1), comptime need.of(draw.Glass));
    try testing.expectEqual(@as(u32, 239), comptime need.of(draw.Glyph));
    try testing.expectEqual(@as(u32, 14), comptime need.areas);
    try testing.expectEqual(@as(u32, 18), test_text.label_max);
    try testing.expectEqual(@as(u32, 4), test_text.detail_max);
    const cx = fixture.wide_context();
    var tally: fixture.Tally(P.appends_for(test_text)) = .{};
    var p = P.init(ui.id("palette", 0), &test_items, 32, test_style);
    frame_of(cx, &p);
    try tally.observe(cx);
    cx.event_begin(.{ .frame = 0 });
    p.open_at(cx, .{ .point = .{ 460, 104 } }, .at);
    cx.event_end();
    frame_of(cx, &p);
    try tally.observe(cx);
    _ = press_key(cx, &p, .a, "a");
    frame_of(cx, &p);
    try tally.observe(cx);
    _ = press_key(cx, &p, .page_down, "");
    frame_of(cx, &p);
    try tally.observe(cx);
    _ = press_key(cx, &p, .down, "");
    frame_of(cx, &p);
    try tally.observe(cx);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

//! `MenuBar`: menu titles side by side, each opening its `Menu` below it; one open at a time.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. State
//! A bar holds its titles and one `MenuOf(Skin)` per title (at most `menubar_menus_max`, ids
//! `id.derive(menubar_menu_salt + i)`), the open menu's index, and the hovered title. Title `i`
//! records `id.derive(i)` where it was drawn, and its menu hangs below that area
//! (`popup.Anchor.id`), so the popup follows the title wherever the app put the bar.
//!
//! ## 2. Events
//! ```text
//! closed  title hover_in / hover_out        highlight it
//!         title down                        open its menu, focused          opened(i)
//! open    move over another title           close, open that one            opened(j)
//!         left down on the open title       close                           closed
//!         left down on another title        close, open that one            opened(j)
//!         Left / Right (the menu focused)   the previous / next menu, wrapping, its first
//!                                           enabled item highlighted        opened(j)
//!         anything else                     the menu's own handle: chosen   chosen { menu, item }
//!                                                                  dismissed  closed
//! ```
//! A move switches only when it enters a title other than the one it was last over: after Left
//! or Right the pointer may rest on another title, and the synthetic move a redraw sends there
//! (`ui/cx.zig`, section 6) must not switch back.
//! While a menu is open its popup's backdrop lies over the whole window, titles included, so
//! the titles get no hover and no press from `cx.hit`. The bar finds the title under a move or
//! a left press by geometry instead, over the areas of the last draw (`cx.find`, at most
//! `menubar_menus_max` titles, only while open), and answers before the menu does, so a press
//! on a title never reaches the backdrop's dismiss.
//!
//! ## 3. Drawing
//! `draw(cx, walk)` opens a row container for `walk` (typically `fit` wide and `fill` high),
//! walks each title as wide as its label in the name style plus `menubar_pad_x` on both sides
//! and as high as the row, hands the skin a `MenuTitleLook`, and records the shape. The open
//! menu draws in `draw_overlay` (`ui.overlays` calls it).

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const menu_file = @import("menu.zig");

const Id = kit.Id;
const Rect = kit.Rect;
const Walk = kit.Walk;

/// Titles one bar holds at most.
pub const menubar_menus_max: u32 = 8;
/// Space left and right of a title's label.
pub const menubar_pad_x: f32 = 10;
/// The title band's height, centred in the row.
pub const menubar_band_h: f32 = 28;
/// Added to a menu's index for its id: "menu" in the high word, clear of the title indices.
pub const menubar_menu_salt: u64 = 0x6d656e75 << 32;

/// The titles' areas: the default cursor, not focusable (the open menu takes the keys).
pub const menubar_title_flags: ui.Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .primary_only = true,
};

/// The default bar: `MenuBarOf(skins.Default)`.
pub const MenuBar = MenuBarOf(skin.Default);

/// The item a bar's menu chose.
pub const MenuChoice = struct {
    menu: u32,
    item: u32,
};

/// A menu bar drawn by `Skin` (`Skin.menu_title`, and the menus' `menu_face` and `menu_row`).
pub fn MenuBarOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .menu_bar)) |problem| @compileError(problem);
    return struct {
        const Self = @This();
        pub const Menu = menu_file.MenuOf(Skin);

        id: Id,
        titles: []const []const u8,
        /// `menus[0..count]` are the titles' menus; the rest are closed placeholders.
        menus: [menubar_menus_max]Menu,
        count: u32,
        open: ?u32,
        hovered: ?u32,
        /// While open: the title the pointer was over at the last move or press (section 2).
        under: ?u32,

        pub const Action = union(enum) {
            none,
            /// This title's menu opened (a press, a switch by hover, or Left / Right).
            opened: u32,
            chosen: MenuChoice,
            /// The open menu closed without a choice.
            closed,
        };

        /// A bar of `titles`, title `i` opening a menu of `items[i]`, all closed.
        pub fn init(id: Id, titles: []const []const u8, items: []const []const []const u8) Self {
            assert(id != .none);
            assert(titles.len >= 1 and titles.len <= menubar_menus_max);
            assert(items.len == titles.len);
            var bar: Self = .{
                .id = id,
                .titles = titles,
                .menus = undefined,
                .count = @intCast(titles.len),
                .open = null,
                .hovered = null,
                .under = null,
            };
            for (&bar.menus, 0..) |*slot, index| {
                const menu_id = id.derive(menubar_menu_salt + index);
                const listed = if (index < items.len) items[index] else &placeholder;
                slot.* = Menu.init(menu_id, listed);
            }
            assert(bar.open == null);
            return bar;
        }

        const placeholder = [_][]const u8{""};

        /// The id of title `index`'s area.
        pub fn title_id(self: *const Self, index: u32) Id {
            assert(index < self.count);
            return self.id.derive(index);
        }

        /// Menu `index`, to enable or disable its items.
        pub fn menu(self: *Self, index: u32) *Menu {
            assert(index < self.count);
            return &self.menus[index];
        }

        /// The bar's answer to `event` (section 2).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.count >= 1 and self.count <= menubar_menus_max);
            if (event == .frame) return .none;
            const open = self.open orelse return self.handle_closed(cx, event);
            assert(open < self.count);
            if (!self.menus[open].open) {
                // Closed by the app (`Menu.close`) since the last event.
                self.open = null;
                return self.handle_closed(cx, event);
            }
            if (event == .key_down and cx.focused(self.menus[open].id)) {
                const step: u32 = switch (event.key_down.key) {
                    .left => self.count - 1,
                    .right => 1,
                    else => 0,
                };
                if (step != 0) return self.switch_to(cx, (open + step) % self.count, true);
            }
            const point_title = self.title_under(cx, event);
            if (event == .pointer_move) {
                // Only entering another title switches: a move that stays on one (the synthetic
                // move after a redraw, or after Left / Right) keeps the open menu.
                const entered = !std.meta.eql(point_title, self.under);
                self.under = point_title;
                if (point_title) |title| {
                    if (entered and title != open) return self.switch_to(cx, title, false);
                }
            }
            if (event == .pointer_down) {
                if (point_title) |title| {
                    if (title == open) {
                        self.menus[open].close(cx);
                        self.open = null;
                        return .closed;
                    }
                    return self.switch_to(cx, title, false);
                }
            }
            switch (self.menus[open].handle(cx, event)) {
                .none => return .none,
                .chosen => |item| {
                    self.open = null;
                    return .{ .chosen = .{ .menu = open, .item = item } };
                },
                .dismissed => {
                    self.open = null;
                    return .closed;
                },
            }
        }

        fn handle_closed(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.open == null);
            var index: u32 = 0;
            while (index < self.count) : (index += 1) {
                switch (cx.hit(self.title_id(index), event)) {
                    .hover_in => self.hover_title(cx, index),
                    .hover_out => if (self.hovered == index) self.hover_title(cx, null),
                    .down => return self.open_menu(cx, index, false),
                    else => {},
                }
            }
            return .none;
        }

        fn hover_title(self: *Self, cx: anytype, index: ?u32) void {
            if (index) |title| assert(title < self.count);
            if (std.meta.eql(self.hovered, index)) return;
            self.hovered = index;
            cx.redraw();
        }

        /// The title under a move or a left press while a menu is open (section 2).
        fn title_under(self: *const Self, cx: anytype, event: input.Event) ?u32 {
            const point: input.Point = switch (event) {
                .pointer_move => |moved| moved,
                .pointer_down => |down| if (down.button == .left)
                    .{ .x = down.x, .y = down.y }
                else
                    return null,
                else => return null,
            };
            var index: u32 = 0;
            while (index < self.count) : (index += 1) {
                const found = cx.find(self.title_id(index)) orelse continue;
                const r = found.rect;
                const inside_x = point.x >= r[0] and point.x < r[0] + r[2];
                const inside_y = point.y >= r[1] and point.y < r[1] + r[3];
                if (inside_x and inside_y) return index;
            }
            return null;
        }

        fn switch_to(self: *Self, cx: anytype, index: u32, keyboard: bool) Action {
            assert(index < self.count);
            const open = self.open.?;
            assert(index != open or keyboard);
            self.menus[open].close(cx);
            self.open = null;
            return self.open_menu(cx, index, keyboard);
        }

        /// Opens menu `index` below its title, focused; from the keyboard its first enabled
        /// item is highlighted.
        fn open_menu(self: *Self, cx: anytype, index: u32, keyboard: bool) Action {
            assert(index < self.count);
            const opened = &self.menus[index];
            opened.open_at(cx, .{ .id = self.title_id(index) }, .below);
            if (keyboard) opened.highlight = first_enabled(opened);
            if (!keyboard) self.under = index;
            self.open = index;
            self.hovered = null;
            cx.redraw();
            assert(opened.open);
            return .{ .opened = index };
        }

        fn first_enabled(opened: *const Menu) ?u32 {
            var item: u32 = 0;
            while (item < opened.items.len) : (item += 1) {
                if (opened.is_enabled(item)) return item;
            }
            return null;
        }

        /// A title's width: its label in `style`, padded (section 3).
        pub fn title_width(style: text.Style, title: []const u8) f32 {
            assert(title.len <= text.byte_cap);
            const width = @ceil(text.measure(style, title)) + 2 * menubar_pad_x;
            assert(width >= 2 * menubar_pad_x);
            return width;
        }

        /// Draws the titles in a row container for `walk` (section 3). Draw phase.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.count >= 1);
            _ = cx.begin(walk, .{ .flow = .right });
            const style = cx.theme().name;
            for (self.titles, 0..) |title, position| {
                const index: u32 = @intCast(position);
                const cell = cx.walk(ui.sized(.{ .fixed = title_width(style, title) }, .fill));
                const clip = cx.visible(cell) orelse continue;
                const shape = Skin.menu_title(cx, .{
                    .rect = cell,
                    .clip = clip,
                    .label = title,
                    .open = self.open != null and self.open.? == index,
                    .hovered = self.hovered != null and self.hovered.? == index,
                }) orelse continue;
                cx.area(self.title_id(index), shape.rect, shape.radius, menubar_title_flags);
            }
            _ = cx.end();
        }

        /// Draws the open menu (section 3). `ui.overlays` calls it.
        pub fn draw_overlay(self: *const Self, cx: anytype) void {
            const open = self.open orelse return;
            assert(open < self.count);
            self.menus[open].draw_overlay(cx);
        }
    };
}

comptime {
    assert(menubar_menus_max <= 32);
    assert(menubar_menu_salt > menubar_menus_max);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const file_items = [_][]const u8{ "New", "Open", "Save" };
const edit_items = [_][]const u8{ "Undo", "Cut", "Copy" };
const view_items = [_][]const u8{ "Light", "Dark" };
const test_titles = [_][]const u8{ "File", "Edit", "View" };
const test_items = [_][]const []const u8{ &file_items, &edit_items, &view_items };

/// Draws the bar fit x 40 at (0, 0) and its open menu.
fn draw_bar(cx: *fixture.Context, bar: *const MenuBar) void {
    cx.begin_frame(1280, 720, 120);
    bar.draw(cx, .{ .width = .fit, .height = .{ .fixed = 40 } });
    bar.draw_overlay(cx);
    _ = cx.end_frame();
}

fn centre_of(cx: *fixture.Context, bar: *const MenuBar, index: u32) input.Point {
    const rect = cx.find(bar.title_id(index)).?.rect;
    return .{ .x = rect[0] + rect[2] * 0.5, .y = rect[1] + rect[3] * 0.5 };
}

fn key(name: input.Key) input.Event {
    return .{ .key_down = input.key_press(name, .none, false, "") };
}

// Locks sections 2 and 3: the titles sit side by side from x 0, each its label plus 20 wide; a
// press opens File focused; a move onto Edit switches to it; Right goes to View with Light
// highlighted and Right again wraps to File; Left wraps back to View; a move that stays on Edit
// keeps View open, and entering File switches.
test "a menu bar opens on a press and switches by hover and by Left and Right" {
    const cx = fixture.context();
    var bar = MenuBar.init(ui.id("bar", 0), &test_titles, &test_items);
    draw_bar(cx, &bar);
    const file = cx.find(bar.title_id(0)).?.rect;
    const edit = cx.find(bar.title_id(1)).?.rect;
    try testing.expectEqual(@as(f32, 0), file[0]);
    try testing.expectEqual(file[0] + file[2], edit[0]);
    try testing.expectEqual(MenuBar.title_width(cx.theme().name, "File"), file[2]);
    const at_file = centre_of(cx, &bar, 0);
    const opened = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_file) });
    try testing.expectEqual(MenuBar.Action{ .opened = 0 }, opened);
    try testing.expect(cx.focused(bar.menus[0].id));
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_file) });
    draw_bar(cx, &bar);
    const switched = fixture.send(cx, &bar, .{ .pointer_move = centre_of(cx, &bar, 1) });
    try testing.expectEqual(MenuBar.Action{ .opened = 1 }, switched);
    try testing.expect(!bar.menus[0].open and bar.menus[1].open);
    draw_bar(cx, &bar);
    try testing.expectEqual(MenuBar.Action{ .opened = 2 }, fixture.send(cx, &bar, key(.right)));
    try testing.expectEqual(@as(?u32, 0), bar.menus[2].highlight);
    try testing.expectEqual(MenuBar.Action{ .opened = 0 }, fixture.send(cx, &bar, key(.right)));
    try testing.expectEqual(MenuBar.Action{ .opened = 2 }, fixture.send(cx, &bar, key(.left)));
    try testing.expectEqual(@as(?u32, 2), bar.open);
    draw_bar(cx, &bar);
    // The pointer still rests on Edit: a move there (a redraw's) keeps View open.
    const resting = fixture.send(cx, &bar, .{ .pointer_move = centre_of(cx, &bar, 1) });
    try testing.expectEqual(MenuBar.Action.none, resting);
    try testing.expectEqual(@as(?u32, 2), bar.open);
    const entered = fixture.send(cx, &bar, .{ .pointer_move = centre_of(cx, &bar, 0) });
    try testing.expectEqual(MenuBar.Action{ .opened = 0 }, entered);
}

// Locks section 2: Down and Enter choose View's first item and close the bar; a press on the
// open title closes it; Escape dismisses as closed; a press elsewhere dismisses too.
test "a menu bar chooses, closes on its title, and dismisses" {
    const cx = fixture.context();
    var bar = MenuBar.init(ui.id("bar", 0), &test_titles, &test_items);
    draw_bar(cx, &bar);
    const at_view = centre_of(cx, &bar, 2);
    _ = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_view) });
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_view) });
    draw_bar(cx, &bar);
    _ = fixture.send(cx, &bar, key(.down));
    const chosen = fixture.send(cx, &bar, key(.enter));
    try testing.expectEqual(MenuBar.Action{ .chosen = .{ .menu = 2, .item = 0 } }, chosen);
    try testing.expectEqual(@as(?u32, null), bar.open);
    draw_bar(cx, &bar);
    _ = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_view) });
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_view) });
    draw_bar(cx, &bar);
    const closed = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_view) });
    try testing.expectEqual(MenuBar.Action.closed, closed);
    try testing.expect(!bar.menus[2].open);
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_view) });
    draw_bar(cx, &bar);
    _ = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_view) });
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_view) });
    draw_bar(cx, &bar);
    try testing.expectEqual(MenuBar.Action.closed, fixture.send(cx, &bar, key(.escape)));
    draw_bar(cx, &bar);
    _ = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(at_view) });
    _ = fixture.send(cx, &bar, .{ .pointer_up = input.left_at(at_view) });
    draw_bar(cx, &bar);
    const away: input.Point = .{ .x = 600, .y = 400 };
    const dismissed = fixture.send(cx, &bar, .{ .pointer_down = input.left_at(away) });
    try testing.expectEqual(MenuBar.Action.closed, dismissed);
}

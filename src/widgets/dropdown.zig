//! `Dropdown`: a face showing the selected item, opening a `Menu` of the items below it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Events
//! While its list is closed the dropdown is a button that opens on a release inside, or on
//! Enter, Space, or Down while its face has focus (the face is focusable, so a press or Tab
//! gives it focus). Opening highlights the selected item, so Down moves to the next one. While
//! open, every event goes to the menu: a chosen item different from the selected one becomes
//! selected and returns `changed`, the same item returns nothing; either way focus returns to
//! the face. A dismissal returns nothing.
//!
//! ## 2. Drawing
//! `DropdownOf(Skin)` hands the skin a `DropdownLook` (`widgets/skin.zig`) and records the hit
//! shape it returns; `draw_overlay` draws the list, at least the face's width, below it
//! (flipping above when the bounds have more room there). The default face is a bordered box,
//! the label at the left, and a chevron of two `draw.Path` segments at the right, so an app with
//! a default dropdown registers `draw.Path`.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the items are app-owned labels, at most `menu.menu_items_max`.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const menu_file = @import("menu.zig");

const Id = kit.Id;
const Rect = kit.Rect;
const Walk = kit.Walk;

/// The salt of a dropdown's menu id: `id.derive(list_salt)`.
pub const list_salt: u64 = 0x6c697374;

/// The chevron's half width and half height, its stroke, and the room it takes from the label.
pub const chevron_half_w: f32 = 5;
pub const chevron_half_h: f32 = 2.5;
pub const chevron_stroke: f32 = 2;
pub const chevron_room: f32 = 2 * chevron_half_w + 8;

/// The face takes presses and focus, with the default cursor.
pub const dropdown_flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = false,
    .cursor = .default,
};

/// The default dropdown: `DropdownOf(skins.Default)`.
pub const Dropdown = DropdownOf(skin.Default);

/// The chevron's three points: a "v" whose right end is `menu_pad_x` inside `rect`'s right
/// edge, centered vertically.
pub fn chevron_points(rect: Rect) [3][2]f32 {
    assert(rect.width > 0);
    assert(rect.height > 0);
    const center_x = rect.x + rect.width - menu_file.menu_pad_x - chevron_half_w;
    const center_y = rect.y + rect.height * 0.5;
    return .{
        .{ center_x - chevron_half_w, center_y - chevron_half_h },
        .{ center_x, center_y + chevron_half_h },
        .{ center_x + chevron_half_w, center_y - chevron_half_h },
    };
}

/// A dropdown drawn by `Skin` (`Skin.dropdown` for the face, `MenuOf(Skin)` for the list).
pub fn DropdownOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .dropdown)) |problem| @compileError(problem);
    const List = menu_file.MenuOf(Skin);
    return struct {
        const Self = @This();

        id: Id,
        selected: u32,
        hover: animator.Animator,
        /// The list; its `bounds` is the dropdown's (null for the window).
        menu: List,

        pub const Action = union(enum) {
            none,
            /// The selected item changed to this index.
            changed: u32,
        };

        /// A closed dropdown of `items` with `selected` selected.
        pub fn init(id: Id, items: []const []const u8, selected: u32) Self {
            assert(id != .none);
            assert(selected < items.len);
            var list = List.init(id.derive(list_salt), items);
            list.fit_anchor = true;
            const dropdown: Self = .{
                .id = id,
                .selected = selected,
                .hover = .init(kit.hover_rate_per_ms),
                .menu = list,
            };
            assert(!dropdown.menu.open);
            return dropdown;
        }

        /// The selected item's label.
        pub fn label(self: *const Self) []const u8 {
            assert(self.selected < self.menu.items.len);
            return self.menu.items[self.selected];
        }

        /// Opens the list below the face with the selected item highlighted.
        pub fn open(self: *Self, cx: anytype) void {
            self.menu.open_at(cx, .{ .id = self.id }, .below);
            self.menu.highlight = self.selected;
            assert(self.menu.open);
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                return .none;
            }
            if (self.menu.open) {
                switch (self.menu.handle(cx, event)) {
                    .chosen => |index| {
                        cx.set_focus(self.id);
                        if (index == self.selected) return .none;
                        self.selected = index;
                        cx.redraw();
                        return .{ .changed = index };
                    },
                    .dismissed, .none => return .none,
                }
            }
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            if (hit == .up and hit.up.inside) self.open(cx);
            if (event == .key_down and cx.focused(self.id)) {
                const press = event.key_down;
                const space = press.key == .other and std.mem.eql(u8, press.typed(), " ");
                if (press.key == .enter or press.key == .down or space) self.open(cx);
            }
            return .none;
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.id != .none);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            const shape = Skin.dropdown(cx, .{
                .rect = rect,
                .clip = clip,
                .label = self.label(),
                .hover = self.hover.value,
                .open = self.menu.open,
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, dropdown_flags);
        }

        /// Draws the open list (`ui.overlays` calls it).
        pub fn draw_overlay(self: *const Self, cx: anytype) void {
            self.menu.draw_overlay(cx);
        }
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const waves = [_][]const u8{ "sine", "triangle", "saw", "square", "noise", "sample & hold" };

fn dropdown_frame(cx: *fixture.Context, dropdown: *const Dropdown) void {
    cx.begin_frame(1280, 720, 120);
    dropdown.draw(cx, fixture.at(100, 100, 168, 32));
    ui.overlays(cx, dropdown);
    _ = cx.end_frame();
}

// Locks the dropdown (section 1): a click opens the list below the face at least the face's
// width, with the selected item highlighted; Down twice and Enter choose item 2 and return
// `changed` with focus back on the face; opening again and choosing the same item returns
// nothing; Enter on the focused face opens it.
test "a dropdown changes only on a different item" {
    const cx = fixture.context();
    var dropdown = Dropdown.init(ui.id("wave", 0), &waves, 0);
    dropdown_frame(cx, &dropdown);
    const center: input.Point = .{ .x = 184, .y = 116 };
    _ = fixture.send(cx, &dropdown, .{ .pointer_down = input.left_at(center) });
    _ = fixture.send(cx, &dropdown, .{ .pointer_up = input.left_at(center) });
    try testing.expect(dropdown.menu.open);
    try testing.expectEqual(@as(?u32, 0), dropdown.menu.highlight);
    dropdown_frame(cx, &dropdown);
    const row0 = cx.find(dropdown.menu.id.derive(0)).?;
    try testing.expectEqual(@as(f32, 100), row0.rect[0]);
    try testing.expectEqual(@as(f32, 134 + menu_file.menu_pad_y), row0.rect[1]);
    try testing.expect(row0.rect[2] >= 168);
    const down = input.key_press(.down, .none, false, "");
    const enter = input.key_press(.enter, .none, false, "");
    _ = fixture.send(cx, &dropdown, .{ .key_down = down });
    _ = fixture.send(cx, &dropdown, .{ .key_down = down });
    const changed = fixture.send(cx, &dropdown, .{ .key_down = enter });
    try testing.expectEqual(Dropdown.Action{ .changed = 2 }, changed);
    try testing.expect(!dropdown.menu.open);
    try testing.expectEqualStrings("saw", dropdown.label());
    try testing.expect(cx.focused(dropdown.id));
    dropdown_frame(cx, &dropdown);
    _ = fixture.send(cx, &dropdown, .{ .key_down = enter });
    try testing.expect(dropdown.menu.open);
    try testing.expectEqual(@as(?u32, 2), dropdown.menu.highlight);
    dropdown_frame(cx, &dropdown);
    const again = fixture.send(cx, &dropdown, .{ .key_down = enter });
    try testing.expectEqual(Dropdown.Action.none, again);
    try testing.expectEqual(@as(u32, 2), dropdown.selected);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the chevron: a "v" 12 px inside the right edge of a 168 x 32 face at (100, 100), 10
// px wide and 5 high around the face's middle.
test "the chevron sits inside the face's right edge" {
    const points = chevron_points(.{ .x = 100, .y = 100, .width = 168, .height = 32 });
    try testing.expectEqual([2]f32{ 246, 113.5 }, points[0]);
    try testing.expectEqual([2]f32{ 251, 118.5 }, points[1]);
    try testing.expectEqual([2]f32{ 256, 113.5 }, points[2]);
}

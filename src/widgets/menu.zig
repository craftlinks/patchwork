//! `Menu` and `ContextMenu`: a vertical list of labels in a popup, chosen by pointer or keys.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. State and Opening
//! A menu holds its items (app-owned labels, at most `menu_items_max`), one enabled bit per
//! item, the highlighted item, whether it is open, and what it hangs from: an `Anchor` (an id
//! drawn this frame, or a point) and a `popup.Side`. `open_at(cx, anchor, side)` opens it with
//! no highlight, gives it keyboard focus, and requests its popup (`cx.request_popup`), so a
//! safe build that never draws it panics naming the id. `bounds` is the rect the popup stays
//! inside (null for the window), which keeps placement deterministic in a window whose size the
//! compositor picks.
//!
//! ## 2. Events
//! `handle(cx, event) Action` reads nothing while closed. Open, it answers:
//! ```text
//! row hover_in          highlight the row when enabled (redraw)
//! row hover_out         clear the highlight if it was that row
//! row down              keep focus on the menu (a press clears it otherwise)
//! row up inside         chosen (enabled rows only), close
//! backdrop down         dismissed, close: the press does not reach what is under it
//! backdrop secondary    dismissed, close
//! Up / Down             previous / next enabled item, wrapping; from none the last / first
//! Home / End            first / last enabled item
//! Enter                 chosen (the highlight), close
//! Escape                dismissed, close; the context clears focus after the event
//! Tab (focus moved)     dismissed, close
//! anchor not drawn      dismissed, close (the anchor scrolled away or was culled)
//! ```
//! Keys count only while the menu has focus. The backdrop and the rows are areas of the last
//! drawn frame on `Layer.popup` (`ui/cx.zig`, section 3c).
//!
//! ## 3. Drawing
//! `draw_overlay(cx)` (called by `ui.overlays`) does nothing while closed. Open, it measures
//! the widest label, sizes the popup `(width + 2 * menu_pad_x, items * menu_row_h + 2 *
//! menu_pad_y)` (at least the anchor's width when `fit_anchor`), places it with `popup.place`
//! inside `bounds`, and inside `cx.begin_popup` hands the skin one `MenuFaceLook` and then a
//! `MenuRowLook` per item, recording `id.derive(row)` over each row. The face comes before any
//! label, so the popup layer's Box batch draws under its Glyph batch. Rows past a cut popup
//! (one taller than its bounds) are not drawn.
//!
//! ## 4. ContextMenu
//! A `Menu` opened at the pointer (`.at`) by a right press on a target id the app names:
//! `handle(cx, event, target)`. Its actions are the menu's.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: labels are app-owned; every loop is bounded by `menu_items_max`.
//! - `handle` is the only mutator; `draw_overlay` reads the state.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Id = kit.Id;
const Rect = kit.Rect;
const popup = ui.popup;

/// Items a menu holds at most; `enabled` has one bit per item.
pub const menu_items_max: u32 = 32;

/// A row's height, in logical pixels.
pub const menu_row_h: f32 = 28;

/// Space left and right of the widest label.
pub const menu_pad_x: f32 = 12;

/// Space above the first row and below the last.
pub const menu_pad_y: f32 = 4;

/// The default face's corner radius and border.
pub const menu_radius: f32 = 6;
pub const menu_border_px: f32 = 1;

/// The highlight band's inset from the row's sides and its corner radius.
pub const menu_band_inset: f32 = 4;
pub const menu_band_radius: f32 = 4;

/// Labels start at the left, centered vertically, cut with an ellipsis when the popup was cut.
pub const menu_text_options: text.Options = .{
    .align_x = .start,
    .align_y = .center,
    .ellipsis = true,
};

/// Every item enabled.
pub const all_enabled: u32 = std.math.maxInt(u32);

/// The default menu: `MenuOf(skins.Default)`.
pub const Menu = MenuOf(skin.Default);

/// The default context menu: `ContextMenuOf(skins.Default)`.
pub const ContextMenu = ContextMenuOf(skin.Default);

/// What a menu event did.
pub const MenuAction = union(enum) {
    none,
    /// The item at this index was chosen; the menu closed.
    chosen: u32,
    /// The menu closed without a choice.
    dismissed,
};

/// A menu drawn by `Skin` (`Skin.menu_face`, `Skin.menu_row`; `widgets/skin.zig`).
pub fn MenuOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .menu)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        items: []const []const u8,
        /// Bit `i` set when item `i` can be highlighted and chosen.
        enabled: u32,
        highlight: ?u32,
        open: bool,
        anchor: popup.Anchor,
        side: popup.Side,
        /// The rect the popup stays inside; null is the window.
        bounds: ?Rect,
        /// The popup is at least as wide as the anchor's area (a dropdown's list).
        fit_anchor: bool,
        /// The popup's material; null takes the scheme's (`theme.zig`, section 7). A glass one
        /// marks the popup layer as a backdrop while the menu is open.
        material: ?kit.Material = null,

        pub const Action = MenuAction;

        /// A closed menu of `items`, all enabled.
        pub fn init(id: Id, items: []const []const u8) Self {
            assert(id != .none);
            assert(items.len >= 1 and items.len <= menu_items_max);
            const menu: Self = .{
                .id = id,
                .items = items,
                .enabled = all_enabled,
                .highlight = null,
                .open = false,
                .anchor = .{ .id = id },
                .side = .below,
                .bounds = null,
                .fit_anchor = false,
            };
            assert(!menu.open);
            return menu;
        }

        /// True when item `index` is enabled.
        pub fn is_enabled(self: *const Self, index: u32) bool {
            assert(index < self.items.len);
            assert(self.items.len <= menu_items_max);
            return self.enabled & (@as(u32, 1) << @intCast(index)) != 0;
        }

        /// Enables or disables item `index`.
        pub fn set_enabled(self: *Self, index: u32, on: bool) void {
            assert(index < self.items.len);
            const bit = @as(u32, 1) << @intCast(index);
            if (on) self.enabled |= bit else self.enabled &= ~bit;
            assert(self.is_enabled(index) == on);
        }

        /// Opens the menu on `side` of `anchor` with nothing highlighted, gives it focus, and
        /// requests its popup (section 1). Event phase.
        pub fn open_at(self: *Self, cx: anytype, anchor: popup.Anchor, side: popup.Side) void {
            assert(self.id != .none);
            self.open = true;
            self.highlight = null;
            self.anchor = anchor;
            self.side = side;
            cx.set_focus(self.id);
            cx.request_popup(self.id);
            assert(self.open);
        }

        /// Closes the menu, gives up its focus, and owes a draw. Event phase.
        pub fn close(self: *Self, cx: anytype) void {
            assert(self.id != .none);
            self.open = false;
            self.highlight = null;
            if (cx.focused(self.id)) cx.clear_focus();
            cx.redraw();
            assert(!self.open);
        }

        /// The menu's answer to `event` (section 2).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            if (!self.open) return .none;
            if (event == .frame) return .none;
            if (self.anchor == .id and cx.find(self.anchor.id) == null) return self.dismiss(cx);
            if (event == .key_down) return self.key(cx, event.key_down);
            if (cx.focus_lost(self.id) and event != .pointer_down) return self.dismiss(cx);
            switch (cx.hit(cx.popup_backdrop(self.id), event)) {
                .down, .secondary => return self.dismiss(cx),
                else => {},
            }
            var row: u32 = 0;
            while (row < self.items.len) : (row += 1) {
                switch (cx.hit(self.id.derive(row), event)) {
                    .hover_in => if (self.is_enabled(row)) self.highlight_row(cx, row),
                    .hover_out => if (self.highlight == row) self.highlight_row(cx, null),
                    .down => cx.set_focus(self.id),
                    .up => |up| if (up.inside and self.is_enabled(row)) return self.choose(cx, row),
                    .none, .drag, .wheel, .secondary => {},
                }
            }
            return .none;
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(self.open);
            if (!cx.focused(self.id)) {
                if (cx.focus_lost(self.id)) return self.dismiss(cx);
                return .none;
            }
            switch (press.key) {
                .escape => return self.dismiss(cx),
                .enter => if (self.highlight) |row| return self.choose(cx, row),
                .down => self.highlight_row(cx, self.step_from(self.highlight, true)),
                .up => self.highlight_row(cx, self.step_from(self.highlight, false)),
                .home => self.highlight_row(cx, self.step_from(null, true)),
                .end => self.highlight_row(cx, self.step_from(null, false)),
                else => {},
            }
            return .none;
        }

        /// The next enabled item after `from` (or before, unless `forward`), wrapping; from
        /// null the first (or last). Null when no item is enabled.
        fn step_from(self: *const Self, from: ?u32, forward: bool) ?u32 {
            const count: u32 = @intCast(self.items.len);
            assert(count >= 1 and count <= menu_items_max);
            var at: u32 = if (from) |row| row else if (forward) count - 1 else 0;
            var tried: u32 = 0;
            while (tried < count) : (tried += 1) {
                at = if (forward) (at + 1) % count else (at + count - 1) % count;
                if (self.is_enabled(at)) return at;
            }
            return null;
        }

        fn highlight_row(self: *Self, cx: anytype, row: ?u32) void {
            if (row) |index| assert(index < self.items.len);
            if (std.meta.eql(self.highlight, row)) return;
            self.highlight = row;
            cx.redraw();
        }

        fn choose(self: *Self, cx: anytype, row: u32) Action {
            assert(row < self.items.len);
            assert(self.is_enabled(row));
            self.close(cx);
            return .{ .chosen = row };
        }

        fn dismiss(self: *Self, cx: anytype) Action {
            assert(self.open);
            self.close(cx);
            return .dismissed;
        }

        /// The popup's size before placement: the widest label and the rows, padded (section
        /// 3), at least `min_width` wide.
        pub fn size_of(self: *const Self, style: text.Style, min_width: f32) [2]f32 {
            assert(min_width >= 0);
            var widest: f32 = 0;
            for (self.items) |label| widest = @max(widest, text.measure(style, label));
            const rows: f32 = @floatFromInt(self.items.len);
            const size: [2]f32 = .{
                @max(@ceil(widest) + 2 * menu_pad_x, min_width),
                rows * menu_row_h + 2 * menu_pad_y,
            };
            assert(size[0] > 0 and size[1] > 0);
            return size;
        }

        /// Draws the open menu in its popup (section 3). `ui.overlays` calls it.
        pub fn draw_overlay(self: *const Self, cx: anytype) void {
            assert(self.id != .none);
            if (!self.open) return;
            var anchor_width: f32 = 0;
            const anchor: Rect = switch (self.anchor) {
                .id => |anchor_id| blk: {
                    const found = cx.find(anchor_id) orelse {
                        cx.skip_popup(self.id);
                        return;
                    };
                    anchor_width = found.rect[2];
                    break :blk .{
                        .x = found.rect[0],
                        .y = found.rect[1],
                        .width = found.rect[2],
                        .height = found.rect[3],
                    };
                },
                .point => |point| popup.anchor_rect(point),
            };
            const style = cx.theme().name;
            const size = self.size_of(style, if (self.fit_anchor) anchor_width else 0);
            const rect = popup.place(anchor, size, self.bounds orelse cx.window, self.side);
            const material = self.material orelse cx.theme().material;
            _ = kit.backdrop(cx, .popup, material);
            _ = cx.begin_popup(self.id, rect, .{ .flow = .down, .clip = true }, 0);
            const clip = cx.clip().?;
            Skin.menu_face(cx, .{ .rect = rect, .clip = clip, .material = material });
            const bottom = rect.y + rect.height - menu_pad_y;
            for (self.items, 0..) |label, index| {
                const row: u32 = @intCast(index);
                const y = rect.y + menu_pad_y + @as(f32, @floatFromInt(row)) * menu_row_h;
                if (y + menu_row_h > bottom) break;
                const row_rect: Rect = .{
                    .x = rect.x,
                    .y = y,
                    .width = rect.width,
                    .height = menu_row_h,
                };
                cx.area(self.id.derive(row), row_rect, 0, ui.cx.plain);
                Skin.menu_row(cx, .{
                    .rect = row_rect,
                    .clip = clip,
                    .label = label,
                    .style = style,
                    .enabled = self.is_enabled(row),
                    .highlighted = self.highlight != null and self.highlight.? == row,
                });
            }
            cx.end_popup();
        }
    };
}

/// A menu opened at the pointer by a right press on a target (section 4), drawn by `Skin`.
pub fn ContextMenuOf(comptime Skin: type) type {
    return struct {
        const Self = @This();

        menu: MenuOf(Skin),

        pub const Action = MenuAction;

        /// A closed context menu of `items`, all enabled.
        pub fn init(id: Id, items: []const []const u8) Self {
            const context: Self = .{ .menu = MenuOf(Skin).init(id, items) };
            assert(!context.menu.open);
            return context;
        }

        /// Opens on a right press on `target` at the pointer; otherwise the menu's answer.
        pub fn handle(self: *Self, cx: anytype, event: input.Event, target: Id) Action {
            assert(target != .none);
            assert(target != self.menu.id);
            if (self.menu.open) return self.menu.handle(cx, event);
            if (event == .frame) return .none;
            switch (cx.hit(target, event)) {
                .secondary => |press| {
                    self.menu.open_at(cx, .{ .point = .{ press.x, press.y } }, .at);
                },
                else => {},
            }
            return .none;
        }

        pub fn draw_overlay(self: *const Self, cx: anytype) void {
            self.menu.draw_overlay(cx);
        }
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const file_items = [_][]const u8{ "New", "Open", "Save", "Save as", "Quit" };

/// One frame: the anchor area "file" at (20, 20, 80, 32) unless `anchorless`, then `menu`'s
/// overlay.
fn menu_frame(cx: *fixture.Context, menu: *const Menu, anchorless: bool) void {
    cx.begin_frame(1280, 720, 120);
    const anchor: Rect = .{ .x = 20, .y = 20, .width = 80, .height = 32 };
    if (!anchorless) cx.area(ui.id("file", 0), anchor, 0, ui.cx.plain);
    cx.area(ui.id("under", 0), .{ .x = 400, .y = 400, .width = 80, .height = 32 }, 0, ui.cx.plain);
    ui.overlays(cx, menu);
    _ = cx.end_frame();
}

fn send_key(cx: *fixture.Context, menu: *Menu, key_value: input.Key) MenuAction {
    return fixture.send(cx, menu, .{ .key_down = input.key_press(key_value, .none, false, "") });
}

fn opened(cx: *fixture.Context, menu: *Menu) void {
    menu_frame(cx, menu, false);
    cx.event_begin(.{ .frame = 0 });
    menu.open_at(cx, .{ .id = ui.id("file", 0) }, .below);
    cx.event_end();
    menu_frame(cx, menu, false);
}

// Locks the menu's placement and rows (section 3): below the 80 x 32 anchor at (20, 20) with
// the 2 px gap, five rows of 28 plus 4 + 4 of padding (148 high), the backdrop first on the
// popup layer and one area per row after it.
test "an open menu draws below its anchor with one area per row" {
    const cx = fixture.context();
    var menu = Menu.init(ui.id("menu", 0), &file_items);
    opened(cx, &menu);
    const backdrop = cx.find(cx.popup_backdrop(menu.id)).?;
    try testing.expectEqual(@as(u8, 6), backdrop.layer);
    const row0 = cx.find(menu.id.derive(0)).?;
    try testing.expectEqual(@as(f32, 20), row0.rect[0]);
    try testing.expectEqual(@as(f32, 54 + menu_pad_y), row0.rect[1]);
    try testing.expectEqual(@as(f32, menu_row_h), row0.rect[3]);
    const row4 = cx.find(menu.id.derive(4)).?;
    try testing.expectEqual(@as(f32, 54 + menu_pad_y + 4 * menu_row_h), row4.rect[1]);
    try testing.expectEqual(@as(f32, 148), menu.size_of(cx.theme().name, 0)[1]);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the keys (section 2): Down from no highlight goes to the first enabled item, skips a
// disabled one (item 1), wraps from the last to the first; Up from none goes to the last; Enter
// chooses the highlight and closes; Escape dismisses and the context clears focus.
test "menu keys move over enabled items, wrap, choose, and dismiss" {
    const cx = fixture.context();
    var menu = Menu.init(ui.id("menu", 0), &file_items);
    menu.set_enabled(1, false);
    opened(cx, &menu);
    try testing.expect(cx.focused(menu.id));
    try testing.expectEqual(MenuAction.none, send_key(cx, &menu, .down));
    try testing.expectEqual(@as(?u32, 0), menu.highlight);
    _ = send_key(cx, &menu, .down);
    try testing.expectEqual(@as(?u32, 2), menu.highlight);
    _ = send_key(cx, &menu, .end);
    try testing.expectEqual(@as(?u32, 4), menu.highlight);
    _ = send_key(cx, &menu, .down);
    try testing.expectEqual(@as(?u32, 0), menu.highlight);
    _ = send_key(cx, &menu, .up);
    try testing.expectEqual(@as(?u32, 4), menu.highlight);
    try testing.expectEqual(MenuAction{ .chosen = 4 }, send_key(cx, &menu, .enter));
    try testing.expect(!menu.open);
    try testing.expect(!cx.focused(menu.id));
    opened(cx, &menu);
    _ = send_key(cx, &menu, .up);
    try testing.expectEqual(@as(?u32, 4), menu.highlight);
    try testing.expectEqual(MenuAction.dismissed, send_key(cx, &menu, .escape));
    try testing.expect(!menu.open);
    try testing.expectEqual(Id.none, cx.focus);
}

// Locks dismissal (section 2): a press outside the menu (over another area) returns
// `dismissed` and closes, and the area under it sees no `up` inside on the release; a click on
// an enabled row chooses it, a click on a disabled row neither chooses nor closes.
test "an outside press dismisses and a row click chooses" {
    const cx = fixture.context();
    var menu = Menu.init(ui.id("menu", 0), &file_items);
    menu.set_enabled(3, false);
    opened(cx, &menu);
    const under = ui.id("under", 0);
    const outside: input.Point = .{ .x = 420, .y = 410 };
    _ = fixture.send(cx, &menu, .{ .pointer_move = outside });
    const press_outside: input.Event = .{ .pointer_down = input.left_at(outside) };
    try testing.expectEqual(MenuAction.dismissed, fixture.send(cx, &menu, press_outside));
    try testing.expect(!menu.open);
    menu_frame(cx, &menu, false);
    cx.event_begin(.{ .pointer_up = input.left_at(outside) });
    const release = cx.hit(under, .{ .pointer_up = input.left_at(outside) });
    cx.event_end();
    try testing.expect(release != .up);
    opened(cx, &menu);
    const row3 = cx.find(menu.id.derive(3)).?.rect;
    const disabled: input.Point = .{ .x = row3[0] + 10, .y = row3[1] + 10 };
    _ = fixture.send(cx, &menu, .{ .pointer_move = disabled });
    try testing.expectEqual(@as(?u32, null), menu.highlight);
    _ = fixture.send(cx, &menu, .{ .pointer_down = input.left_at(disabled) });
    const release_disabled: input.Event = .{ .pointer_up = input.left_at(disabled) };
    try testing.expectEqual(MenuAction.none, fixture.send(cx, &menu, release_disabled));
    try testing.expect(menu.open);
    const row2 = cx.find(menu.id.derive(2)).?.rect;
    const enabled: input.Point = .{ .x = row2[0] + 10, .y = row2[1] + 10 };
    _ = fixture.send(cx, &menu, .{ .pointer_move = enabled });
    try testing.expectEqual(@as(?u32, 2), menu.highlight);
    _ = fixture.send(cx, &menu, .{ .pointer_down = input.left_at(enabled) });
    try testing.expect(cx.focused(menu.id));
    const release_enabled: input.Event = .{ .pointer_up = input.left_at(enabled) };
    try testing.expectEqual(MenuAction{ .chosen = 2 }, fixture.send(cx, &menu, release_enabled));
    try testing.expect(!menu.open);
}

// Locks the culled anchor (section 2): a frame that did not draw the anchor draws no popup
// (and meets the request), and the next event dismisses the menu.
test "a menu whose anchor was not drawn closes on the next event" {
    const cx = fixture.context();
    var menu = Menu.init(ui.id("menu", 0), &file_items);
    opened(cx, &menu);
    menu_frame(cx, &menu, true);
    try testing.expect(cx.find(cx.popup_backdrop(menu.id)) == null);
    const away: input.Event = .{ .pointer_move = .{ .x = 5, .y = 5 } };
    try testing.expectEqual(MenuAction.dismissed, fixture.send(cx, &menu, away));
    try testing.expect(!menu.open);
}

// Locks the context menu (section 4): a left press on the target opens nothing, a right press
// opens the menu at the pointer (its top-left there), and a right press on the backdrop
// dismisses it.
test "a context menu opens at a right press on its target" {
    const cx = fixture.context();
    var context = ContextMenu.init(ui.id("context", 0), &file_items);
    const target = ui.id("under", 0);
    cx.begin_frame(1280, 720, 120);
    cx.area(target, .{ .x = 400, .y = 400, .width = 80, .height = 32 }, 0, ui.cx.plain);
    _ = cx.end_frame();
    const point: input.Point = .{ .x = 410, .y = 405 };
    var right = input.left_at(point);
    right.button = .right;
    const send = struct {
        fn call(c: *fixture.Context, w: *ContextMenu, event: input.Event, t: Id) MenuAction {
            c.event_begin(event);
            const action = w.handle(c, event, t);
            c.event_end();
            return action;
        }
    }.call;
    _ = send(cx, &context, .{ .pointer_move = point }, target);
    _ = send(cx, &context, .{ .pointer_down = input.left_at(point) }, target);
    _ = send(cx, &context, .{ .pointer_up = input.left_at(point) }, target);
    try testing.expect(!context.menu.open);
    _ = send(cx, &context, .{ .pointer_down = right }, target);
    try testing.expect(context.menu.open);
    cx.begin_frame(1280, 720, 120);
    cx.area(target, .{ .x = 400, .y = 400, .width = 80, .height = 32 }, 0, ui.cx.plain);
    ui.overlays(cx, &context);
    _ = cx.end_frame();
    const row0 = cx.find(context.menu.id.derive(0)).?;
    try testing.expectEqual(@as(f32, 410), row0.rect[0]);
    try testing.expectEqual(@as(f32, 405 + menu_pad_y), row0.rect[1]);
    var far = right;
    far.x = 900;
    far.y = 100;
    _ = send(cx, &context, .{ .pointer_move = .{ .x = 900, .y = 100 } }, target);
    const press_far: input.Event = .{ .pointer_down = far };
    try testing.expectEqual(MenuAction.dismissed, send(cx, &context, press_far, target));
}

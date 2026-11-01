//! Window chrome: the drag area, the resize edges, and `WindowButtons` (minimize, maximize or
//! restore, close), for an app that draws its own title bar.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Areas the Window Manager Answers
//! A press on an area whose flags name a window part is a request to the window manager, made
//! by the context (`ui/cx.zig`, section 5a), not a widget's press:
//! ```text
//! window_drag(cx, id, rect)   a drag area: press moves, a double press maximizes or restores,
//!                             a right press opens the window manager's menu
//! window_edges(cx, id)        4 strips edge_px wide and 4 corners corner_px square over
//!                             cx.window: press resizes from that edge; ns / ew / nwse / nesw
//! ```
//! A drag area goes under what sits on the bar: record it before the titles and buttons, so
//! they are appended after it and take the pointer over it. The edges go over everything:
//! `window_edges` is the last call of `App.draw`, after `ui.overlays`, with only the root open.
//! There are none while the window is maximized or fullscreen or the window manager draws the
//! frame, and a tiled side loses its strip and its two corners (`input.WindowState`).
//!
//! ## 2. WindowButtons
//! ```text
//! draw(cx)            in a row: minimize (if can_minimize), maximize or restore (if
//!                     can_maximize; restore while maximized), close; each
//!                     window_button_w x fill, area id.derive(button); nothing at all while
//!                     the window manager draws the frame
//! width(cx)           what draw walks: window_button_w per shown button, or 0
//! handle(cx, event)   up inside: cx.minimize, cx.toggle_maximize, or cx.close
//!                     -> pressed(button)
//! ```
//! Hover and press ease per button. The look (`WindowButtonLook`) names the button, so a skin
//! draws its own icons; `active` is the window's `activated` state, which a skin may dim.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Id = kit.Id;

/// A window button's width, in logical pixels; its height is its row's.
pub const window_button_w: f32 = 46;
/// The resize strips' width along each side of the window.
pub const window_edge_px: f32 = 4;
/// The resize corners' side.
pub const window_corner_px: f32 = 12;

/// A drag area's flags: the default cursor, not focusable, the drag part.
pub const window_drag_flags: ui.Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .window = .drag,
    .primary_only = true,
};

/// The window buttons' areas: the default cursor, not focusable.
pub const window_button_flags: ui.Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .default,
    .primary_only = true,
};

/// One of the window buttons, in drawing order.
pub const WindowButton = enum(u2) {
    minimize,
    /// Maximize, drawn as restore while the window is maximized.
    maximize,
    close,
};

/// The default buttons: `WindowButtonsOf(skins.Default)`.
pub const WindowButtons = WindowButtonsOf(skin.Default);

/// Records a drag area over `rect` (section 1). Draw phase.
pub fn window_drag(cx: anytype, id: Id, rect: Rect) void {
    assert(id != .none);
    assert(rect.width >= 0 and rect.height >= 0);
    if (cx.visible(rect) == null) return;
    cx.area(id, rect, 0, window_drag_flags);
}

/// The window parts `window_edges` records, in order.
const edge_parts = [_]ui.WindowPart{
    .top,
    .bottom,
    .left,
    .right,
    .top_left,
    .top_right,
    .bottom_left,
    .bottom_right,
};

/// Records the resize areas over the window (section 1), ids `id.derive(part)`. The last call
/// of `App.draw`, with only the root open.
pub fn window_edges(cx: anytype, id: Id) void {
    assert(id != .none);
    assert(cx.depth == 1);
    const state = cx.window_state();
    if (state.decorations == .server or state.maximized or state.fullscreen) return;
    for (edge_parts) |part| {
        if (tiled(state, part)) continue;
        const rect = edge_rect(cx.window, part);
        const flags: ui.Flags = .{
            .wheel = false,
            .focusable = false,
            .tab = false,
            .cursor = cursor_of(part),
            .window = part,
            .primary_only = true,
        };
        cx.area(id.derive(@backingInt(part)), rect, 0, flags);
    }
}

/// True when `part` lies on a side the window is tiled on.
fn tiled(state: input.WindowState, part: ui.WindowPart) bool {
    const top = part == .top or part == .top_left or part == .top_right;
    const bottom = part == .bottom or part == .bottom_left or part == .bottom_right;
    const left = part == .left or part == .top_left or part == .bottom_left;
    const right = part == .right or part == .top_right or part == .bottom_right;
    assert(top or bottom or left or right);
    return (top and state.tiled_top) or (bottom and state.tiled_bottom) or
        (left and state.tiled_left) or (right and state.tiled_right);
}

/// The rect of an edge part over `window`: a strip between the corners, or a corner square.
pub fn edge_rect(window: Rect, part: ui.WindowPart) Rect {
    assert(window.width >= 2 * window_corner_px);
    assert(window.height >= 2 * window_corner_px);
    const corner = window_corner_px;
    const edge = window_edge_px;
    const right = window.x + window.width;
    const bottom = window.y + window.height;
    const long_w = window.width - 2 * corner;
    const long_h = window.height - 2 * corner;
    return switch (part) {
        .none, .drag => unreachable,
        .top => .{ .x = window.x + corner, .y = window.y, .width = long_w, .height = edge },
        .bottom => .{ .x = window.x + corner, .y = bottom - edge, .width = long_w, .height = edge },
        .left => .{ .x = window.x, .y = window.y + corner, .width = edge, .height = long_h },
        .right => .{ .x = right - edge, .y = window.y + corner, .width = edge, .height = long_h },
        .top_left => .{ .x = window.x, .y = window.y, .width = corner, .height = corner },
        .top_right => .{ .x = right - corner, .y = window.y, .width = corner, .height = corner },
        .bottom_left => .{ .x = window.x, .y = bottom - corner, .width = corner, .height = corner },
        .bottom_right => .{
            .x = right - corner,
            .y = bottom - corner,
            .width = corner,
            .height = corner,
        },
    };
}

/// The resize cursor of an edge part.
fn cursor_of(part: ui.WindowPart) ui.Cursor {
    return switch (part) {
        .none, .drag => unreachable,
        .top, .bottom => .ns_resize,
        .left, .right => .ew_resize,
        .top_left, .bottom_right => .nwse_resize,
        .top_right, .bottom_left => .nesw_resize,
    };
}

/// Minimize, maximize or restore, and close, drawn by `Skin` (`Skin.window_button`;
/// `widgets/skin.zig`), for a client-decorated window (section 2).
pub fn WindowButtonsOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .window_buttons)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        hover: [3]animator.Animator,
        down: [3]animator.Animator,

        pub const Action = union(enum) {
            none,
            /// The button was clicked; its request is made.
            pressed: WindowButton,
        };

        /// The buttons at rest.
        pub fn init(id: Id) Self {
            assert(id != .none);
            const buttons: Self = .{
                .id = id,
                .hover = @splat(animator.Animator.init(kit.hover_rate_per_ms)),
                .down = @splat(animator.Animator.init(kit.down_rate_per_ms)),
            };
            assert(!buttons.hover[0].live());
            return buttons;
        }

        /// The id of `button`'s area.
        pub fn button_id(self: *const Self, button: WindowButton) Id {
            assert(self.id != .none);
            return self.id.derive(@backingInt(button));
        }

        /// True when `button` is drawn in `state` (section 2).
        pub fn shown(state: input.WindowState, button: WindowButton) bool {
            if (state.decorations == .server) return false;
            return switch (button) {
                .minimize => state.can_minimize,
                .maximize => state.can_maximize,
                .close => true,
            };
        }

        /// The width `draw` walks: `window_button_w` per shown button, 0 under server
        /// decorations.
        pub fn width(self: *const Self, cx: anytype) f32 {
            assert(self.id != .none);
            const state = cx.window_state();
            var count: f32 = 0;
            for (std.enums.values(WindowButton)) |button| {
                if (shown(state, button)) count += 1;
            }
            assert(count <= 3);
            return count * window_button_w;
        }

        /// Walks and draws the shown buttons in the current row (section 2). Draw phase.
        pub fn draw(self: *const Self, cx: anytype) void {
            assert(self.id != .none);
            const state = cx.window_state();
            for (std.enums.values(WindowButton)) |button| {
                if (!shown(state, button)) continue;
                const index = @backingInt(button);
                const rect = cx.walk(ui.sized(.{ .fixed = window_button_w }, .fill));
                const clip = cx.visible(rect) orelse continue;
                const kind: skin.WindowButtonKind = switch (button) {
                    .minimize => .minimize,
                    .maximize => if (state.maximized) .restore else .maximize,
                    .close => .close,
                };
                const shape = Skin.window_button(cx, .{
                    .rect = rect,
                    .clip = clip,
                    .kind = kind,
                    .hover = self.hover[index].value,
                    .down = self.down[index].value,
                    .active = state.activated,
                }) orelse continue;
                cx.area(self.button_id(button), shape.rect, shape.radius, window_button_flags);
            }
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            if (event == .frame) {
                for (&self.hover, &self.down) |*hover, *down| {
                    kit.step(cx, hover, event.frame);
                    kit.step(cx, down, event.frame);
                }
                return .none;
            }
            var action: Action = .none;
            for (std.enums.values(WindowButton)) |button| {
                const index = @backingInt(button);
                const hit = cx.hit(self.button_id(button), event);
                kit.respond(cx, hit, &self.hover[index], &self.down[index]);
                if (hit != .up or !hit.up.inside) continue;
                switch (button) {
                    .minimize => cx.minimize(),
                    .maximize => cx.toggle_maximize(),
                    .close => cx.close(),
                }
                action = .{ .pressed = button };
            }
            return action;
        }
    };
}

comptime {
    assert(window_corner_px > window_edge_px);
    assert(window_button_w > 0);
    assert(edge_parts.len == 8);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

/// Draws the buttons in a 200 x 40 row at (100, 0), then the edges, in a 1280 x 720 frame.
fn draw_chrome(cx: *fixture.Context, buttons: *const WindowButtons) void {
    cx.begin_frame(1280, 720, 120);
    _ = cx.begin(fixture.at(100, 0, 200, 40), .{ .flow = .right });
    buttons.draw(cx);
    _ = cx.end();
    window_edges(cx, ui.id("edges", 0));
    _ = cx.end_frame();
}

fn set_state(cx: *fixture.Context, state: input.WindowState) void {
    cx.event_begin(.{ .window_state = state });
    cx.event_end();
}

// Locks section 1: eight edge areas over the 1280 x 720 window (the top strip from x 12 to
// 1268, 4 high; the bottom-right corner 12 square with the nwse cursor and its part), none
// while maximized, and a window tiled left loses its left strip and both left corners.
test "window edges cover the window's border unless it is snapped" {
    const cx = fixture.context();
    const buttons = WindowButtons.init(ui.id("chrome", 0));
    const edges = ui.id("edges", 0);
    draw_chrome(cx, &buttons);
    const top = cx.find(edges.derive(@backingInt(ui.WindowPart.top))).?;
    try testing.expectEqualSlices(f32, &.{ 12, 0, 1256, 4 }, &top.rect);
    try testing.expectEqual(ui.Cursor.ns_resize, top.flags.cursor);
    const corner = cx.find(edges.derive(@backingInt(ui.WindowPart.bottom_right))).?;
    try testing.expectEqualSlices(f32, &.{ 1268, 708, 12, 12 }, &corner.rect);
    try testing.expectEqual(ui.Cursor.nwse_resize, corner.flags.cursor);
    try testing.expectEqual(ui.WindowPart.bottom_right, corner.flags.window);
    try testing.expectEqual(@as(u32, 3 + 8), cx.area_count);
    set_state(cx, .{ .maximized = true });
    draw_chrome(cx, &buttons);
    try testing.expectEqual(@as(u32, 3), cx.area_count);
    set_state(cx, .{ .tiled_left = true });
    draw_chrome(cx, &buttons);
    try testing.expectEqual(@as(u32, 3 + 5), cx.area_count);
    try testing.expect(cx.find(edges.derive(@backingInt(ui.WindowPart.top_left))) == null);
    try testing.expect(cx.find(edges.derive(@backingInt(ui.WindowPart.top_right))) != null);
}

// Locks section 2: three buttons of 46 from x 100 (138 wide), two without minimize, and none
// under server decorations, which draw no edges either.
test "window buttons follow the capabilities and the decorations" {
    const cx = fixture.context();
    const buttons = WindowButtons.init(ui.id("chrome", 0));
    draw_chrome(cx, &buttons);
    try testing.expectEqual(@as(f32, 138), buttons.width(cx));
    const close = cx.find(buttons.button_id(.close)).?;
    try testing.expectEqualSlices(f32, &.{ 192, 0, 46, 40 }, &close.rect);
    set_state(cx, .{ .can_minimize = false });
    draw_chrome(cx, &buttons);
    try testing.expectEqual(@as(f32, 92), buttons.width(cx));
    try testing.expect(cx.find(buttons.button_id(.minimize)) == null);
    const moved = cx.find(buttons.button_id(.close)).?;
    try testing.expectEqualSlices(f32, &.{ 146, 0, 46, 40 }, &moved.rect);
    set_state(cx, .{ .decorations = .server });
    draw_chrome(cx, &buttons);
    try testing.expectEqual(@as(f32, 0), buttons.width(cx));
    try testing.expectEqual(@as(u32, 0), cx.area_count);
}

// Locks section 2: a click on each button makes its request and returns it; a release outside
// makes none.
test "a window button click makes its request" {
    const cx = fixture.context();
    var buttons = WindowButtons.init(ui.id("chrome", 0));
    draw_chrome(cx, &buttons);
    const xs = [_]f32{ 120, 160, 210 };
    const requests = [_]ui.WindowRequest{ .minimize, .toggle_maximize, .close };
    for (std.enums.values(WindowButton), xs, requests) |button, x, request| {
        const point: input.Point = .{ .x = x, .y = 20 };
        _ = fixture.send(cx, &buttons, .{ .pointer_down = input.left_at(point) });
        const action = fixture.send(cx, &buttons, .{ .pointer_up = input.left_at(point) });
        try testing.expectEqual(WindowButtons.Action{ .pressed = button }, action);
        try testing.expectEqual(@as(?ui.WindowRequest, request), cx.take_window_request());
    }
    const inside: input.Point = .{ .x = 120, .y = 20 };
    const outside: input.Point = .{ .x = 600, .y = 300 };
    _ = fixture.send(cx, &buttons, .{ .pointer_down = input.left_at(inside) });
    const released = fixture.send(cx, &buttons, .{ .pointer_up = input.left_at(outside) });
    try testing.expectEqual(WindowButtons.Action.none, released);
    try testing.expectEqual(@as(?ui.WindowRequest, null), cx.take_window_request());
}

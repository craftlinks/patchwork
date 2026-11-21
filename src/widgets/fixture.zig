//! Test support shared by the widget files: one static UI context and the helpers that drive a
//! widget the way an app does. Only tests import it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Static
//! A UI context holds its pools inline, so it lives in a static, never on the test's stack.
//! `context` re-initializes it, so every test starts from a fresh one. `bare_context` is a
//! second one without `draw.Path` and `draw.Glass`, for the skins' fallback branches.
//! `wide_context` is a third with room for a container's worst frame (more areas, Box, Path,
//! and Glyph than `context`), which `context` keeps small because `kit`'s append test fills
//! its Box pool.
//!
//! ## 2. Tally
//! `Tally(need)` checks that frames hold exactly what an `Appends` says (`widgets/appends.zig`):
//! `observe`, after `end_frame`, reads every type the context registers, its points, and its
//! areas, and fails when one is above `need` (a type `need` does not name must be 0) or when
//! anything overflowed; `expect_reached` fails unless every count of `need` was reached by some
//! observed frame. A type no observed context registers is skipped (`draw.Glass` in a tally of
//! bare frames only). Reading every registered type, not only those `need` names, is what makes
//! an undeclared append fail.
//!
//! ## 3. Counted
//! `Counted` is a skin for a container's composition tests. Each of its functions appends
//! exactly what it declares on every call, whatever its look's state: `k` `draw.Box` faces over
//! the look's rect, and then the look's label, if it has one, every byte of it (no ellipsis),
//! so a byte of inked text is a glyph. A container's `appends_for` is `calls x per-call bound +
//! its own instances and areas` (`widgets.zig`, section 4); with `Counted` every call reaches
//! its bound, so a `Tally` of the formula is reached exactly, and a wrong number of calls,
//! bytes, or areas fails. The `k` differ between functions, so a multiplier taken from the
//! wrong function fails too. A kind that gains a function stops `Counted` compiling at its
//! comptime block, which is the signal to give it the function and a `k`.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const appends = @import("appends.zig");
const text = @import("../text.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

/// Box instances the context holds; `kit`'s append test fills it.
pub const box_cap: u32 = 16;

const draw_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = box_cap },
    .{ .type = draw.Arc, .cap = 16 },
    .{ .type = draw.Glyph, .cap = 128 },
    .{ .type = draw.Path, .cap = 8 },
    .{ .type = draw.Glass, .cap = 4 },
};

pub const Context = ui.Context(draw.Context(&draw_types, 16, 64), 16);

/// A freshly initialized static context, so tests keep the pools off the stack.
pub fn context() *Context {
    const static = struct {
        var value: Context = undefined;
    };
    static.value.init();
    assert(static.value.draw.overflow_count == 0);
    return &static.value;
}

/// `context`'s types and caps without `draw.Path` and `draw.Glass`.
const bare_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = box_cap },
    .{ .type = draw.Arc, .cap = 16 },
    .{ .type = draw.Glyph, .cap = 128 },
};

pub const BareContext = ui.Context(draw.Context(&bare_types, 16, 64), 16);

/// A freshly initialized static context that registers Box, Arc, and Glyph only, so a skin
/// takes its fallback branches.
pub fn bare_context() *BareContext {
    const static = struct {
        var value: BareContext = undefined;
    };
    static.value.init();
    assert(static.value.draw.overflow_count == 0);
    comptime assert(!BareContext.DrawContext.Registry.has(draw.Path));
    return &static.value;
}

/// `context`'s types with room for a container's worst frame (module guide, section 1).
const wide_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 256 },
    .{ .type = draw.Arc, .cap = 16 },
    .{ .type = draw.Glyph, .cap = 512 },
    .{ .type = draw.Path, .cap = 32 },
    .{ .type = draw.Glass, .cap = 4 },
};

pub const WideContext = ui.Context(draw.Context(&wide_types, 32, 256), 64);

/// A freshly initialized static context with Box 256, Glyph 512, Path 32, points 256, and 64
/// areas, for the containers' worst frames.
pub fn wide_context() *WideContext {
    const static = struct {
        var value: WideContext = undefined;
    };
    static.value.init();
    assert(static.value.draw.overflow_count == 0);
    comptime assert(WideContext.DrawContext.Registry.has(draw.Path));
    return &static.value;
}

/// Checks observed frames against `need` (module guide, section 2).
pub fn Tally(comptime need: appends.Appends) type {
    comptime {
        assert(appends.repeated(need.draws) == null);
    }
    return struct {
        const Self = @This();

        /// The most each entry of `need.draws` reached, and whether a context registered it.
        most: [need.draws.len]u32 = @splat(0),
        seen: [need.draws.len]bool = @splat(false),
        points_most: u32 = 0,
        points_seen: bool = false,
        areas_most: u32 = 0,
        frames: u32 = 0,

        /// Reads one frame of `cx` (after `end_frame`): fails when a count is above `need` or
        /// anything overflowed, and keeps each count's maximum.
        pub fn observe(self: *Self, cx: anytype) !void {
            const R = @TypeOf(cx.*).DrawContext.Registry;
            if (!std.meta.eql(cx.overflow(), ui.cx.Overflow.zero)) {
                std.debug.print("overflow: {any}\n", .{cx.overflow()});
                return error.TallyOverflow;
            }
            inline for (0..R.count) |index| {
                const T = R.Type(index);
                const count: u32 = @intCast(cx.draw.items(T).len);
                const bound = comptime need.of(T);
                if (count > bound) {
                    std.debug.print("{s}: {d} over {d}\n", .{ @typeName(T), count, bound });
                    return error.TallyExceeded;
                }
                if (comptime slot(T)) |entry_index| {
                    self.seen[entry_index] = true;
                    self.most[entry_index] = @max(self.most[entry_index], count);
                }
            }
            if (R.uses_points) self.points_seen = true;
            if (cx.draw.point_count > need.points) {
                std.debug.print("points: {d} over {d}\n", .{ cx.draw.point_count, need.points });
                return error.TallyExceeded;
            }
            if (cx.area_count > need.areas) {
                std.debug.print("areas: {d} over {d}\n", .{ cx.area_count, need.areas });
                return error.TallyExceeded;
            }
            self.points_most = @max(self.points_most, cx.draw.point_count);
            self.areas_most = @max(self.areas_most, cx.area_count);
            self.frames += 1;
            assert(self.points_most <= need.points);
            assert(self.areas_most <= need.areas);
        }

        /// Fails unless every count of `need` equals its maximum over the observed frames.
        pub fn expect_reached(self: *const Self) !void {
            assert(self.frames >= 1);
            assert(self.areas_most <= need.areas);
            inline for (need.draws, 0..) |entry, entry_index| {
                if (self.seen[entry_index] and self.most[entry_index] != entry.count) {
                    const name = @typeName(entry.type);
                    const most = self.most[entry_index];
                    std.debug.print("{s}: reached {d} of {d}\n", .{ name, most, entry.count });
                    return error.TallyNotReached;
                }
            }
            if (self.points_seen and self.points_most != need.points) {
                std.debug.print("points: reached {d} of {d}\n", .{ self.points_most, need.points });
                return error.TallyNotReached;
            }
            if (self.areas_most != need.areas) {
                std.debug.print("areas: reached {d} of {d}\n", .{ self.areas_most, need.areas });
                return error.TallyNotReached;
            }
        }

        /// The index of `T` in `need.draws`, or null.
        fn slot(comptime T: type) ?usize {
            for (need.draws, 0..) |entry, entry_index| {
                if (entry.type == T) return entry_index;
            }
            return null;
        }
    };
}

/// The walk that puts a `width` by `height` box at `(x, y)` under the root turtle.
pub fn at(x: f32, y: f32, width: f32, height: f32) ui.Walk {
    assert(width >= 0);
    assert(height >= 0);
    return .{
        .width = .{ .fixed = width },
        .height = .{ .fixed = height },
        .margin = .{ .left = x, .top = y, .right = 0, .bottom = 0 },
    };
}

/// Dispatches `event` to one widget the way an app's `event` does; `cx` is any of the fixture's
/// contexts.
pub fn send(cx: anytype, widget: anytype, event: input.Event) @TypeOf(widget.*).Action {
    assert(cx.phase != .draw);
    cx.event_begin(event);
    const action = widget.handle(cx, event);
    cx.event_end();
    return action;
}

/// Draws one widget at `walk` in a fresh 1280 by 720 frame; `cx` is any of the fixture's
/// contexts.
pub fn draw_one(cx: anytype, widget: anytype, walk: ui.Walk) void {
    assert(cx.phase != .draw);
    cx.begin_frame(1280, 720, 120);
    widget.draw(cx, walk);
    _ = cx.end_frame();
}

/// Dispatches a touch event to one widget the way `ui.dispatch` does: each pointer event the
/// touch means, in order, with the contact's state loaded. Returns the widget's action for each
/// (`.none` for a lift's second event when it did nothing), and null when the event was for no
/// contact. A repeated down of a live id is not cancelled here.
pub fn send_touch(
    cx: *Context,
    widget: anytype,
    event: input.Event,
) ?[2]@TypeOf(widget.*).Action {
    const plan = cx.touch_begin(event) orelse return null;
    var actions: [2]@TypeOf(widget.*).Action = .{ .none, .none };
    for (plan.events[0..plan.count], 0..) |pointer_event, slot| {
        cx.event_begin(pointer_event);
        actions[slot] = widget.handle(cx, pointer_event);
        cx.event_end();
    }
    cx.touch_end();
    return actions;
}

/// A finger landing at `(x, y)`.
pub fn finger_down(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = 0, .serial = 100 + id } };
}

/// A finger moving to `(x, y)`.
pub fn finger_move(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_move = .{ .id = id, .x = x, .y = y, .time_ms = 0 } };
}

/// A finger lifting.
pub fn finger_up(id: u32) input.Event {
    return .{ .touch_up = .{ .id = id, .time_ms = 0 } };
}

/// A skin whose every function appends exactly its declaration on every call (module guide,
/// section 3).
pub const Counted = struct {
    pub const menu_face_appends = counted(2);
    pub fn menu_face(cx: anytype, look: skin.MenuFaceLook) void {
        faces(cx, look.rect, look.clip, 2);
    }

    pub const menu_row_appends = counted(3);
    pub fn menu_row(cx: anytype, look: skin.MenuRowLook) void {
        faces(cx, look.rect, look.clip, 3);
        place(cx, look.style, look.label, look.rect, look.clip);
    }

    pub const dropdown_appends = counted(5);
    pub fn dropdown(cx: anytype, look: skin.DropdownLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 5);
        place(cx, cx.theme().name, look.label, look.rect, look.clip);
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub const tab_bar_appends = counted(2);
    pub fn tab_bar(cx: anytype, look: skin.TabBarLook) void {
        faces(cx, look.rect, look.clip, 2);
    }

    pub const tab_appends = counted(3);
    pub fn tab(cx: anytype, look: skin.TabLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 3);
        place(cx, cx.theme().name, look.label, look.rect, look.clip);
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub const divider_appends = counted(1);
    pub fn divider(cx: anytype, look: skin.DividerLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 1);
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub const list_row_appends = counted(2);
    pub fn list_row(cx: anytype, look: skin.ListRowLook) void {
        faces(cx, look.rect, look.clip, 2);
    }

    pub const tree_chevron_appends = counted(1);
    pub fn tree_chevron(cx: anytype, look: skin.ChevronLook) void {
        faces(cx, look.rect, look.clip, 1);
    }

    pub const menu_title_appends = counted(4);
    pub fn menu_title(cx: anytype, look: skin.MenuTitleLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 4);
        place(cx, cx.theme().name, look.label, look.rect, look.clip);
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub const window_button_appends = counted(2);
    pub fn window_button(cx: anytype, look: skin.WindowButtonLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 2);
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub const header_cell_appends = counted(3);
    pub fn header_cell(cx: anytype, look: skin.HeaderCellLook) ?skin.Shape {
        faces(cx, look.rect, look.clip, 3);
        place(cx, cx.theme().name, look.label, look.rect, look.clip);
        return .{ .rect = look.rect, .radius = 0 };
    }

    /// `k` Box faces a call, and the default `per_byte`: a glyph a byte of the label.
    fn counted(comptime k: u32) appends.SkinAppends {
        comptime {
            assert(k >= 1);
            const out: appends.SkinAppends = .{ .fixed = .{
                .draws = &.{.{ .type = draw.Box, .count = k }},
            } };
            assert(out.per_byte.of(draw.Glyph) == 1);
            return out;
        }
    }

    /// `k` faces over `rect` under `clip`.
    fn faces(cx: anytype, rect: kit.Rect, clip: kit.Clip, comptime k: u32) void {
        assert(rect.width > 0);
        assert(rect.height > 0);
        for (0..k) |_| kit.face(cx, rect, clip, .{ .fill = .{ 1, 1, 1, 1 } });
    }

    /// `label` from `rect`'s left, centred vertically, never cut, so every inked byte draws.
    fn place(
        cx: anytype,
        style: text.Style,
        label: []const u8,
        rect: kit.Rect,
        clip: kit.Clip,
    ) void {
        assert(label.len <= text.byte_cap);
        assert(rect.width > 0);
        kit.label(cx, style, label, rect, clip, counted_text_options);
    }
};

/// `Counted`'s labels: from the left, centred, no ellipsis.
const counted_text_options: text.Options = .{
    .align_x = .start,
    .align_y = .center,
    .ellipsis = false,
};

comptime {
    // `Counted` covers every container kind (module guide, section 3).
    for ([_]skin.Kind{
        .menu, .dropdown,      .tabs,           .splitter, .list_box,
        .tree, .column_header, .window_buttons, .menu_bar,
    }) |kind| {
        assert(skin.check(Counted, kind) == null);
    }
    assert(Counted.menu_row_appends.with(7).of(draw.Glyph) == 7);
}

const testing = std.testing;
const theme = @import("../theme.zig");

/// Eight inked bytes: no spaces, which have no ink.
const counted_label = "WWWWWWWW";

/// A wide rect at `y`, so no label is cut.
fn counted_rect(y: f32) kit.Rect {
    assert(y >= 0);
    assert(y < 720);
    return .{ .x = 0, .y = y, .width = 600, .height = 32 };
}

/// One frame of `cx` with one call of `function` with `look`, observed by a tally of its
/// declaration with `bytes` of text, reached.
fn counted_reach(
    cx: anytype,
    comptime function: anytype,
    look: anytype,
    comptime declaration: appends.SkinAppends,
    comptime bytes: u32,
) !void {
    var tally: Tally(declaration.with(bytes)) = .{};
    cx.begin_frame(1280, 720, 120);
    _ = function(cx, look);
    _ = cx.end_frame();
    try tally.observe(cx);
    try tally.expect_reached();
    assert(tally.frames == 1);
}

// Locks `Counted` (module guide, section 3): one call of each function appends its `k` Box
// faces (menu_face 2, menu_row 3, dropdown 5, tab_bar 2, tab 3, divider 1, list_row 2,
// tree_chevron 1, menu_title 4, window_button 2, header_cell 3) and Glyph 8 for an 8-byte label,
// reached exactly.
test "Counted appends its declarations" {
    const cx = wide_context();
    const clip: kit.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
    const rect = counted_rect(0);
    const style = theme.dark.name;
    const C = Counted;
    const face: skin.MenuFaceLook = .{ .rect = rect, .clip = clip };
    try counted_reach(cx, C.menu_face, face, C.menu_face_appends, 0);
    try counted_reach(cx, C.menu_row, skin.MenuRowLook{
        .rect = rect,
        .clip = clip,
        .label = counted_label,
        .style = style,
        .enabled = true,
        .highlighted = false,
    }, C.menu_row_appends, counted_label.len);
    try counted_reach(cx, C.dropdown, skin.DropdownLook{
        .rect = rect,
        .clip = clip,
        .label = counted_label,
        .hover = 0,
        .open = false,
    }, C.dropdown_appends, counted_label.len);
    const bar: skin.TabBarLook = .{ .rect = rect, .clip = clip, .focused = false };
    try counted_reach(cx, C.tab_bar, bar, C.tab_bar_appends, 0);
    try counted_reach(cx, C.tab, skin.TabLook{
        .rect = rect,
        .clip = clip,
        .label = counted_label,
        .selected = false,
        .hovered = false,
    }, C.tab_appends, counted_label.len);
    try counted_reach(cx, C.divider, skin.DividerLook{
        .rect = rect,
        .clip = clip,
        .axis = .horizontal,
        .hover = 0,
    }, C.divider_appends, 0);
    try counted_reach(cx, C.list_row, skin.ListRowLook{
        .rect = rect,
        .clip = clip,
        .selected = false,
        .hovered = false,
    }, C.list_row_appends, 0);
    try counted_reach(cx, C.tree_chevron, skin.ChevronLook{
        .rect = rect,
        .clip = clip,
        .turn = 0,
        .hovered = false,
    }, C.tree_chevron_appends, 0);
    try counted_reach(cx, C.menu_title, skin.MenuTitleLook{
        .rect = rect,
        .clip = clip,
        .label = counted_label,
        .open = false,
        .hovered = false,
    }, C.menu_title_appends, counted_label.len);
    try counted_reach(cx, C.window_button, skin.WindowButtonLook{
        .rect = rect,
        .clip = clip,
        .kind = .close,
        .hover = 0,
        .down = 0,
        .active = true,
    }, C.window_button_appends, 0);
    try counted_reach(cx, C.header_cell, skin.HeaderCellLook{
        .rect = rect,
        .clip = clip,
        .label = counted_label,
        .sorted = null,
        .hovered = false,
    }, C.header_cell_appends, counted_label.len);
}

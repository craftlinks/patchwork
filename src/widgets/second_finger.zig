//! Test support for the multi-touch audit (`ui/cx.zig`, section 5b): the widgets whose ids
//! share press state keep it when a second finger presses another of their ids.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Table
//! One test per audited row that needs a fixture: a widget of one id is safe by construction
//! (its state is per press, and a second finger on its area is joined), so only the widgets
//! with several ids are driven here. Each presses one id with finger 0, presses another id of
//! the same widget with finger 1, and checks that the widget's shared state is the first
//! finger's and that the second finger's whole touch answered nothing.

const std = @import("std");
const testing = std.testing;
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const fixture = @import("fixture.zig");
const list_box = @import("list_box.zig");
const tabs = @import("tabs.zig");
const text = @import("../text.zig");
const text_field = @import("text_field.zig");

const point = struct {
    fn of(cx: *fixture.Context, id: ui.Id) [2]f32 {
        const area = cx.find(id).?;
        return .{ area.rect[0] + area.rect[2] * 0.5, area.rect[1] + area.rect[3] * 0.5 };
    }
};

// Locks the list box (its `double` is shared by every row): finger 0 holds row 1, finger 1
// presses and lifts on row 3 and nothing is selected; row 3 is never selected or activated, and
// finger 0's lift then selects row 1 as a plain click.
test "a second finger leaves a list box's rows alone" {
    const cx = fixture.context();
    var list = list_box.ListBox.init(ui.id("list", 0), 20, 24);
    cx.begin_frame(1280, 720, 120);
    _ = list.begin(cx, fixture.at(0, 0, 216, 240));
    while (list.next(cx)) |_| {}
    list.end(cx);
    _ = cx.end_frame();
    const first = point.of(cx, list.row_id(1));
    const third = point.of(cx, list.row_id(3));
    const down = fixture.send_touch(cx, &list, fixture.finger_down(0, first[0], first[1])).?;
    try testing.expectEqual(list_box.ListBox.Action.none, down[0]);
    const second = fixture.send_touch(cx, &list, fixture.finger_down(1, third[0], third[1])).?;
    try testing.expectEqual(list_box.ListBox.Action.none, second[0]);
    const lifted = fixture.send_touch(cx, &list, fixture.finger_up(1)).?;
    try testing.expectEqual(list_box.ListBox.Action.none, lifted[0]);
    try testing.expectEqual(@as(?u32, null), list.selected);
    try testing.expectEqual(list.row_id(1), cx.contacts[0].slot.capture);
    const done = fixture.send_touch(cx, &list, fixture.finger_up(0)).?;
    try testing.expectEqual(list_box.ListBox.Action{ .selected = 1 }, done[0]);
    try testing.expectEqual(@as(?u32, 1), list.selected);
}

// Locks the tabs (one `grab` across every tab id): finger 0 holds tab 0, finger 1 presses tab 2,
// and the selection and the grab stay tab 0's; the second finger's move and lift answer nothing,
// so no tab moves or closes.
test "a second finger leaves a tab bar's grab alone" {
    const cx = fixture.context();
    const labels = [_][]const u8{ "one", "two", "three" };
    var bar = tabs.Tabs.init(ui.id("tabs", 0), &labels, 0);
    bar.closable = true;
    bar.movable = true;
    cx.begin_frame(1280, 720, 120);
    _ = bar.begin(cx, fixture.at(0, 0, 600, 300), .{ .flow = .down });
    _ = cx.end();
    _ = cx.end_frame();
    const one = point.of(cx, bar.tab_id(0));
    const three = point.of(cx, bar.tab_id(2));
    _ = fixture.send_touch(cx, &bar, fixture.finger_down(0, one[0], one[1])).?;
    const grabbed = bar.grab;
    try testing.expect(grabbed != null);
    const second = fixture.send_touch(cx, &bar, fixture.finger_down(1, three[0], three[1])).?;
    try testing.expectEqual(tabs.Tabs.Action.none, second[0]);
    const moved = fixture.send_touch(cx, &bar, fixture.finger_move(1, three[0] - 200, 16)).?;
    try testing.expectEqual(tabs.Tabs.Action.none, moved[0]);
    const lifted = fixture.send_touch(cx, &bar, fixture.finger_up(1)).?;
    try testing.expectEqual(tabs.Tabs.Action.none, lifted[0]);
    try testing.expectEqual(@as(u32, 0), bar.selected);
    try testing.expectEqual(grabbed, bar.grab);
}

// Locks the text field's focus: finger 0 focuses it, and finger 1 pressing a pad elsewhere does
// not blur it, because only the primary contact moves focus.
test "a second finger does not blur a field" {
    const cx = fixture.context();
    const style: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };
    var field = text_field.TextField.init(ui.id("field", 0), 32, style);
    fixture.draw_one(cx, &field, fixture.at(0, 0, 106, 24));
    cx.begin_frame(1280, 720, 120);
    field.draw(cx, fixture.at(0, 0, 106, 24));
    cx.area(ui.id("other", 0), .{ .x = 300, .y = 0, .width = 40, .height = 40 }, 0, ui.cx.plain);
    _ = cx.end_frame();
    _ = fixture.send_touch(cx, &field, fixture.finger_down(0, 30, 10)).?;
    try testing.expect(cx.focused(field.id));
    _ = fixture.send_touch(cx, &field, fixture.finger_down(1, 310, 10)).?;
    try testing.expect(cx.focused(field.id));
    _ = fixture.send_touch(cx, &field, fixture.finger_up(1)).?;
    try testing.expect(cx.focused(field.id));
}

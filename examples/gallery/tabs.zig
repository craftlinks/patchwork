//! The gallery's tabs page (step 45): two bars of tabs that close, reorder, and move between
//! each other as drags between widgets.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Shows
//! Two movable, closable `widgets.Tabs`, "left" and "right", keyed by the index of their
//! file in `names`, so a tab keeps its id wherever it goes. Each bar's labels and keys are
//! this page's arrays (`Bar`); `Bar.apply` updates them for every action the bar reports
//! (`widgets.move_item`, `remove_item`, `insert_item`, then `Tabs.set`), which is all an app
//! does to own its tabs. Under each bar a panel names the selected file. Reset restores both.
//!
//! ## 2. Layout (logical pixels, from the page's top-left)
//! ```text
//! page    1248 x 584, flow down, 8 apart
//!   row   fill x 40     the hint | Reset (96 x 32) flush right
//!   bars  fill x fill   two panels of 620 (padding 8) 8 apart, each its bar over its page:
//!                       the bars at (24, 160) and (652, 160), 604 x 32
//! ```
//!
//! ## 3. Events
//! `Page.handle` hands every event to Reset and both bars and reports the last action:
//! "select app.zig", "close app.zig", "move main.zig to 2", "drop app.zig on right 1", and
//! "reset". A tab dragged from one bar onto the other is two actions in one event, the
//! source's `dragged_out` and the target's `received`; both apply, and the drop reports.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const input = patchwork.input;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;

/// The files, by key.
pub const names = [_][]const u8{
    "main.zig", "app.zig", "ui.zig", "draw.zig", "text.zig", "README.md", "build.zig",
};
/// The file keyed `key`.
pub fn name_of(key: u64) []const u8 {
    assert(key < names.len);
    const index: usize = @intCast(key);
    return names[index];
}

/// The left bar starts with keys 0 to 4, the right with 5 and 6.
pub const left_first: u64 = 0;
pub const left_count: u32 = 5;
pub const right_first: u64 = 5;
pub const right_count: u32 = 2;

pub const left_id = ui.id("tabs left", 0);
pub const right_id = ui.id("tabs right", 0);
pub const reset_id = ui.id("tabs reset", 0);

pub const hint = "drag a tab to reorder it or onto the other bar; \u{d7} or a middle press closes it";

/// The gallery's page.
pub const page_w: f32 = 1248;
pub const gap_px: f32 = 8;
/// Each bar's panel: half the page less half the gap.
pub const panel_w: f32 = (page_w - gap_px) / 2;
pub const row_px: f32 = 40;
pub const reset_w: f32 = 96;
pub const reset_h: f32 = 32;
const pad_px: f32 = 8;
const panel_radius: f32 = 8;

/// One bar and the arrays it shows.
pub const Bar = struct {
    labels: [widgets.tabs_max][]const u8,
    keys: [widgets.tabs_max]u64,
    len: u32,
    tabs: widgets.Tabs,

    /// The bar over `count` files from key `first`, the first selected.
    fn reset(self: *Bar, id: ui.Id, first: u64, count: u32) void {
        assert(count <= widgets.tabs_max);
        assert(first + count <= names.len);
        for (0..count) |index| {
            self.keys[index] = first + index;
            self.labels[index] = name_of(first + index);
        }
        self.len = count;
        self.tabs = widgets.Tabs.init_keyed(id, self.labels[0..count], self.keys[0..count], 0);
        self.tabs.closable = true;
        self.tabs.movable = true;
    }

    /// Applies `action` to the arrays and points the bar at them (section 1). A received tab
    /// that does not fit is refused: the selection goes back.
    fn apply(self: *Bar, action: widgets.Tabs.Action) void {
        assert(self.len <= widgets.tabs_max);
        switch (action) {
            .none, .changed => return,
            .closed, .dragged_out => |index| {
                widgets.remove_item([]const u8, self.labels[0..self.len], index);
                widgets.remove_item(u64, self.keys[0..self.len], index);
                self.len -= 1;
            },
            .moved => |move| {
                widgets.move_item([]const u8, self.labels[0..self.len], move.from, move.to);
                widgets.move_item(u64, self.keys[0..self.len], move.from, move.to);
            },
            .received => |got| {
                if (self.len == widgets.tabs_max or got.payload >= names.len) {
                    self.tabs.selected = 0;
                    return;
                }
                const label = name_of(got.payload);
                widgets.insert_item([]const u8, &self.labels, self.len, got.index, label);
                widgets.insert_item(u64, &self.keys, self.len, got.index, got.payload);
                self.len += 1;
            },
        }
        self.tabs.set(self.labels[0..self.len], self.keys[0..self.len]);
        assert(self.tabs.count() == self.len);
    }

    /// The selected tab's key, or null for an empty bar.
    pub fn selected_key(self: *const Bar) ?u64 {
        if (self.len == 0) return null;
        return self.keys[self.tabs.selected];
    }
};

/// What the page did, for the status line.
pub const Report = union(enum) {
    select: u64,
    close: u64,
    move: struct { key: u64, to: u32 },
    drop: struct { key: u64, right: bool, index: u32 },
    reset,
};

pub const Page = struct {
    left: Bar,
    right: Bar,
    reset: widgets.Button,

    /// Both bars as at the start, Reset painted like the gallery's buttons.
    pub fn init(self: *Page, paint: widgets.Paint, style: text.Style) void {
        self.left.reset(left_id, left_first, left_count);
        self.right.reset(right_id, right_first, right_count);
        self.reset = .{
            .id = reset_id,
            .label = "Reset",
            .style = style,
            .padding = .xy(8, 0),
            .paint = paint,
            .hover = .init(widgets.hover_rate_per_ms),
            .down = .init(widgets.down_rate_per_ms),
        };
    }

    pub fn handle(self: *Page, cx: anytype, event: input.Event) ?Report {
        var report: ?Report = null;
        if (self.reset.handle(cx, event) == .clicked) {
            self.left.reset(left_id, left_first, left_count);
            self.right.reset(right_id, right_first, right_count);
            cx.redraw();
            report = .reset;
        }
        // Both bars see the event before either applies its action, so a cross-bar drop's two
        // halves read the same arrays.
        const actions = [2]widgets.Tabs.Action{
            self.left.tabs.handle(cx, event),
            self.right.tabs.handle(cx, event),
        };
        const bars = [2]*Bar{ &self.left, &self.right };
        for (actions, bars, 0..) |action, bar, side| {
            if (bar_report(bar, action, side == 1)) |made| report = made;
            bar.apply(action);
        }
        return report;
    }

    pub fn draw(self: *Page, cx: anytype) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap_px });
        _ = cx.begin(ui.sized(.fill, .{ .fixed = row_px }), .{ .flow = .right, .spacing = gap_px });
        const line = cx.walk(ui.sized(.{ .fixed = page_w - reset_w - gap_px }, .fill));
        if (cx.visible(line)) |clip| kit.label(cx, styled(cx, 14), hint, line, clip, start);
        var button = ui.sized(.{ .fixed = reset_w }, .{ .fixed = reset_h });
        button.margin.top = (row_px - reset_h) * 0.5;
        self.reset.draw(cx, button);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .right, .spacing = gap_px });
        draw_bar(cx, &self.left);
        draw_bar(cx, &self.right);
        _ = cx.end();
        _ = cx.end();
    }
};

/// The status of `action` on `bar` (section 3), read before the arrays change.
fn bar_report(bar: *const Bar, action: widgets.Tabs.Action, right: bool) ?Report {
    return switch (action) {
        .none, .dragged_out => null,
        .changed => |index| .{ .select = bar.keys[index] },
        .closed => |index| .{ .close = bar.keys[index] },
        .moved => |move| .{ .move = .{ .key = bar.keys[move.from], .to = move.to } },
        .received => |got| .{ .drop = .{ .key = got.payload, .right = right, .index = got.index } },
    };
}

/// A panel holding `bar` over its page: the selected file's name and key, or "no tabs".
fn draw_bar(cx: anytype, bar: *const Bar) void {
    const face: widgets.Panel = .{ .paint = widgets.paint_of(cx.theme().colors.panel, panel_radius) };
    _ = face.begin(cx, ui.sized(.{ .fixed = panel_w }, .fill), .{ .flow = .down, .padding = .all(pad_px), .clip = true });
    _ = bar.tabs.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap_px, .padding = .sides(12, gap_px, 12, 0) });
    const title = cx.walk(ui.sized(.fill, .{ .fixed = 40 }));
    const shown = if (bar.selected_key()) |key| name_of(key) else "no tabs";
    if (cx.visible(title)) |clip| kit.label(cx, styled(cx, 28), shown, title, clip, start);
    if (bar.selected_key()) |key| {
        var digits: [24]u8 = undefined;
        const caption = std.fmt.bufPrint(&digits, "key {d}", .{key}) catch unreachable;
        const line = cx.walk(ui.sized(.fill, .{ .fixed = 20 }));
        if (cx.visible(line)) |clip| kit.label(cx, styled(cx, 14), caption, line, clip, start);
    }
    _ = cx.end();
    _ = cx.end();
}

fn styled(cx: anytype, size: f32) text.Style {
    assert(size > 0);
    return .{ .face = .sans, .size = size, .color = cx.theme().colors.text };
}

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

comptime {
    assert(left_first + left_count == right_first);
    assert(right_first + right_count == names.len);
    assert(names.len <= widgets.tabs_max);
}

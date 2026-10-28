//! The gallery's data page (step 42): a project tree, the selected folder's files in a sortable
//! table, and a property grid of folding groups.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Shows
//! - A `widgets.TreeView` over `nodes`, the repository's own tree in pre-order (folders first,
//!   then files), with `patchwork` and `src` expanded. Folder names are bold.
//! - A `widgets.ColumnHeader` (name, kind, size) over a `widgets.ListBox` of the children of the
//!   tree's folder: the selected node when it has children, else its parent, else the root.
//!   The page sorts the children itself by the header's `sort` (insertion sort of at most
//!   `children_max` indices, ties by name), and each row draws its three cells into the
//!   header's spans (`ColumnHeader.cell`). A folder's size is the sum of its files'.
//! - Three `widgets.Disclosure`s, "transform" and "appearance" open and "layout" closed, each a
//!   section of label and value rows; "appearance" also holds a `widgets.Checkbox`.
//!
//! ## 2. Layout (logical pixels, from the page's top-left)
//! ```text
//! row      flow right, spacing 8, the page
//! tree     300 x fill   caption "project" | the tree, rows of 24
//! table    612 x fill   caption "files" | the header (fill x 28) | the list, rows of 24
//! props    fill x fill  (320 in the gallery) three disclosures (fill x fit), 8 apart; rows of
//!                       24 inset 12
//! ```
//!
//! ## 3. Events
//! `Page.handle` hands every event to the tree, the header, the table, the groups, and the
//! checkbox, and reports the last action for the status line. A new folder clears the table's
//! selection and scrolls it to the top.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const input = patchwork.input;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;

const Rect = patchwork.draw.Rect;

/// One entry of the sample tree: its name, its parent's index, whether it is a folder, and a
/// file's size in bytes (a folder's is summed at init).
const Entry = struct {
    name: []const u8,
    parent: u32,
    folder: bool = false,
    size: u32 = 0,
};

const root = widgets.tree_root;

/// The repository at step 42, in pre-order: every folder's subtree follows it.
pub const entries = [_]Entry{
    .{ .name = "patchwork", .parent = root, .folder = true },
    .{ .name = "examples", .parent = 0, .folder = true },
    .{ .name = "gallery", .parent = 1, .folder = true },
    .{ .name = "app.zig", .parent = 2, .size = 149804 },
    .{ .name = "data.zig", .parent = 2, .size = 17000 },
    .{ .name = "glass.zig", .parent = 2, .size = 20612 },
    .{ .name = "icons.zig", .parent = 2, .size = 4059 },
    .{ .name = "surfaces.zig", .parent = 2, .size = 21515 },
    .{ .name = "rack", .parent = 1, .folder = true },
    .{ .name = "app.zig", .parent = 8, .size = 115361 },
    .{ .name = "src", .parent = 0, .folder = true },
    .{ .name = "draw", .parent = 10, .folder = true },
    .{ .name = "backdrop.zig", .parent = 11, .size = 34351 },
    .{ .name = "path.zig", .parent = 11, .size = 40784 },
    .{ .name = "renderer.zig", .parent = 11, .size = 161772 },
    .{ .name = "types.zig", .parent = 11, .size = 42622 },
    .{ .name = "text", .parent = 10, .folder = true },
    .{ .name = "layout.zig", .parent = 16, .size = 48800 },
    .{ .name = "ttf.zig", .parent = 16, .size = 24314 },
    .{ .name = "widgets", .parent = 10, .folder = true },
    .{ .name = "checkbox.zig", .parent = 19, .size = 12456 },
    .{ .name = "column_header.zig", .parent = 19, .size = 16546 },
    .{ .name = "disclosure.zig", .parent = 19, .size = 8585 },
    .{ .name = "kit.zig", .parent = 19, .size = 32198 },
    .{ .name = "list_box.zig", .parent = 19, .size = 18109 },
    .{ .name = "skin.zig", .parent = 19, .size = 51469 },
    .{ .name = "tabs.zig", .parent = 19, .size = 22334 },
    .{ .name = "text_field.zig", .parent = 19, .size = 33234 },
    .{ .name = "tree_view.zig", .parent = 19, .size = 23081 },
    .{ .name = "app.zig", .parent = 10, .size = 25994 },
    .{ .name = "draw.zig", .parent = 10, .size = 25000 },
    .{ .name = "text.zig", .parent = 10, .size = 11353 },
    .{ .name = "ui.zig", .parent = 10, .size = 16636 },
    .{ .name = "widgets.zig", .parent = 10, .size = 18808 },
    .{ .name = "web", .parent = 0, .folder = true },
    .{ .name = "index.html", .parent = 34, .size = 600 },
    .{ .name = "shell.js", .parent = 34, .size = 48314 },
    .{ .name = "build.zig", .parent = 0, .size = 34830 },
    .{ .name = "README.md", .parent = 0, .size = 122555 },
};

pub const node_count: u32 = entries.len;
/// Nodes the page names in tests and scenarios.
pub const node_src: u32 = 10;
pub const node_text: u32 = 16;
pub const node_widgets: u32 = 19;
/// The most children one folder has: the table's room.
pub const children_max: u32 = 16;

pub const Tree = widgets.TreeView(node_count);

pub const tree_id = ui.id("data_tree", 0);
pub const header_id = ui.id("data_header", 0);
pub const table_id = ui.id("data_table", 0);
pub const visible_id = ui.id("data_visible", 0);
/// Group `i` is `ui.id("group", i)`.
pub const group_names = [_][]const u8{ "transform", "appearance", "layout" };
const group_open = [_]bool{ true, true, false };

pub const row_px: f32 = 24;
pub const tree_w: f32 = 300;
/// The table is fixed so the property grid after it gets the rest (a `fill` takes all the
/// room left when it is walked): 1248 - 300 - 320 - 2 * 8.
pub const table_w: f32 = 612;
pub const props_w: f32 = 320;
pub const gap_px: f32 = 8;
const pad_px: f32 = 8;
const caption_px: f32 = 20;
const prop_inset: f32 = 12;
const panel_radius: f32 = 8;

pub const columns = [_]widgets.Column{
    .{ .label = "name", .width = 220, .min = 120 },
    .{ .label = "kind", .width = 100, .min = 72 },
    .{ .label = "size", .width = 96, .min = 80 },
};
const column_name: u32 = 0;
const column_kind: u32 = 1;
const column_size: u32 = 2;

/// Each group's rows: a label and a value.
const Prop = struct { label: []const u8, value: []const u8 };
const transform_props = [_]Prop{
    .{ .label = "x", .value = "120" },
    .{ .label = "y", .value = "48" },
    .{ .label = "width", .value = "320" },
    .{ .label = "height", .value = "200" },
};
const appearance_props = [_]Prop{
    .{ .label = "opacity", .value = "0.85" },
    .{ .label = "blend", .value = "normal" },
};
const layout_props = [_]Prop{
    .{ .label = "flow", .value = "down" },
    .{ .label = "spacing", .value = "8" },
    .{ .label = "padding", .value = "16" },
};
const group_props = [_][]const Prop{ &transform_props, &appearance_props, &layout_props };

const panel_layout: ui.Layout = .{
    .flow = .down,
    .spacing = gap_px,
    .padding = .all(pad_px),
    .clip = true,
};

/// What the page did, for the status line.
pub const Report = union(enum) {
    selected: u32,
    toggled: Toggled,
    opened: u32,
    sorted: widgets.ColumnSort,
    resized: Resized,
    file: u32,
    group: Group,
    visible: bool,

    pub const Toggled = struct { node: u32, expanded: bool };
    pub const Resized = struct { column: u32, width: f32 };
    pub const Group = struct { index: u32, open: bool };
};

pub const Page = struct {
    nodes: [node_count]widgets.TreeNode,
    /// Each node's size: a file's own, a folder's summed.
    sizes: [node_count]u64,
    tree: Tree,
    header: widgets.ColumnHeader,
    table: widgets.ListBox,
    /// The table's folder and its children, sorted.
    folder: u32,
    files: [children_max]u32,
    file_count: u32,
    groups: [group_names.len]widgets.Disclosure,
    visible: widgets.Checkbox,

    /// The tree with `patchwork` and `src` expanded, the table on the root, the groups as
    /// `group_open` says. In place: the tree points at `nodes`.
    pub fn init(self: *Page) void {
        for (entries, &self.nodes, &self.sizes) |entry, *node, *size| {
            node.* = .{ .parent = entry.parent, .has_children = entry.folder };
            size.* = entry.size;
        }
        self.nodes[0].expanded = true;
        self.nodes[node_src].expanded = true;
        var index: u32 = node_count;
        while (index > 1) {
            index -= 1;
            const parent = entries[index].parent;
            assert(parent < index);
            self.sizes[parent] += self.sizes[index];
        }
        self.tree = Tree.init(tree_id, &self.nodes, row_px);
        self.header = widgets.ColumnHeader.init(header_id, &columns);
        self.table = widgets.ListBox.init(table_id, 0, row_px);
        self.folder = 0;
        self.file_count = 0;
        self.gather();
        for (&self.groups, group_names, group_open, 0..) |*group, name, open, at| {
            group.* = widgets.Disclosure.init(ui.id("group", @intCast(at)), name, open);
        }
        self.visible = widgets.Checkbox.init(visible_id, "visible", true);
        assert(self.file_count == 5);
    }

    /// The folder the table shows: the selected node with children, else its parent, else
    /// the root.
    pub fn folder_of(self: *const Page) u32 {
        const node = self.tree.selected orelse return 0;
        if (entries[node].folder) return node;
        const parent = entries[node].parent;
        return if (parent == root) 0 else parent;
    }

    /// Collects `folder`'s children and sorts them by the header.
    fn gather(self: *Page) void {
        var count: u32 = 0;
        for (entries, 0..) |entry, at| {
            if (entry.parent != self.folder) continue;
            assert(count < children_max);
            self.files[count] = @intCast(at);
            count += 1;
        }
        self.file_count = count;
        if (self.header.sort) |sort| {
            std.sort.insertion(u32, self.files[0..count], Order{ .page = self, .sort = sort }, Order.less);
        }
        assert(self.file_count <= children_max);
    }

    const Order = struct {
        page: *const Page,
        sort: widgets.ColumnSort,

        fn less(order: Order, a: u32, b: u32) bool {
            const forward = order.ascending(a, b);
            const backward = order.ascending(b, a);
            if (forward == backward) return std.mem.lessThan(u8, entries[a].name, entries[b].name);
            return if (order.sort.descending) backward else forward;
        }

        /// Whether `a` comes strictly before `b` in the sorted column, ascending.
        fn ascending(order: Order, a: u32, b: u32) bool {
            return switch (order.sort.column) {
                column_name => std.mem.lessThan(u8, entries[a].name, entries[b].name),
                column_kind => std.mem.lessThan(u8, kind_of(a), kind_of(b)),
                else => order.page.sizes[a] < order.page.sizes[b],
            };
        }
    };

    pub fn handle(self: *Page, cx: anytype, event: input.Event) ?Report {
        var report: ?Report = null;
        switch (self.tree.handle(cx, event)) {
            .none => {},
            .selected => |node| report = .{ .selected = node },
            .activated => |node| report = .{ .opened = node },
            .toggled => |toggled| report = .{ .toggled = .{ .node = toggled.node, .expanded = toggled.expanded } },
        }
        const folder = self.folder_of();
        if (folder != self.folder) {
            self.folder = folder;
            self.table.selected = null;
            self.table.view.scroll_y = 0;
            cx.redraw();
        }
        switch (self.header.handle(cx, event)) {
            .none => {},
            .sorted => |sort| report = .{ .sorted = sort },
            .resized => |resized| report = .{ .resized = .{ .column = resized.column, .width = resized.width } },
        }
        switch (self.table.handle(cx, event)) {
            .none => {},
            .selected, .activated => |row| report = .{ .file = self.files[row] },
        }
        for (&self.groups, 0..) |*group, at| {
            switch (group.handle(cx, event)) {
                .none => {},
                .toggled => |open| report = .{ .group = .{ .index = @intCast(at), .open = open } },
            }
        }
        switch (self.visible.handle(cx, event)) {
            .none => {},
            .toggled => |on| report = .{ .visible = on },
        }
        return report;
    }

    pub fn draw(self: *Page, cx: anytype) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .right, .spacing = gap_px });
        self.draw_tree(cx);
        self.draw_table(cx);
        self.draw_props(cx);
        _ = cx.end();
    }

    fn draw_tree(self: *Page, cx: anytype) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = tree_w }, .fill), panel_layout);
        caption(cx, "project");
        _ = self.tree.begin(cx, ui.sized(.fill, .fill));
        while (self.tree.next(cx)) |row| {
            const style = name_style(cx, entries[row.node].folder);
            kit.label(cx, style, entries[row.node].name, row.rect, row.clip, start);
        }
        self.tree.end(cx);
        _ = cx.end();
    }

    fn draw_table(self: *Page, cx: anytype) void {
        self.gather();
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = table_w }, .fill), panel_layout);
        caption(cx, "files");
        self.header.draw(cx, ui.sized(.fill, .{ .fixed = widgets.header_h }));
        self.table.count = self.file_count;
        if (self.table.selected) |row| {
            if (row >= self.file_count) self.table.selected = null;
        }
        _ = self.table.begin(cx, ui.sized(.fill, .fill));
        const value = cx.theme().value;
        while (self.table.next(cx)) |row| {
            const node = self.files[row.index];
            const name = self.header.cell(row.rect, column_name);
            kit.label(cx, name_style(cx, entries[node].folder), entries[node].name, name, row.clip, cut);
            kit.label(cx, styled(cx, .sans), kind_of(node), self.header.cell(row.rect, column_kind), row.clip, cut);
            var digits: [16]u8 = undefined;
            const size = format_size(&digits, self.sizes[node]);
            kit.label(cx, value, size, self.header.cell(row.rect, column_size), row.clip, end);
        }
        self.table.end(cx);
        _ = cx.end();
    }

    fn draw_props(self: *const Page, cx: anytype) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), panel_layout);
        for (&self.groups, group_props, 0..) |*group, props, at| {
            if (group.begin(cx, ui.sized(.fill, .fit), .{ .flow = .down })) {
                for (props) |prop| prop_row(cx, prop);
                if (at == 1) {
                    var walk = ui.sized(.fill, .{ .fixed = widgets.checkbox_height });
                    walk.margin.left = prop_inset;
                    self.visible.draw(cx, walk);
                }
            }
            group.end(cx);
        }
        _ = cx.end();
    }
};

/// A file's extension, or "folder".
pub fn kind_of(node: u32) []const u8 {
    assert(node < node_count);
    const entry = entries[node];
    if (entry.folder) return "folder";
    const dot = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse return "file";
    return entry.name[dot + 1 ..];
}

/// `bytes` as "600 B", "12.5 KB", or "1.18 MB" (decimal units).
pub fn format_size(out: *[16]u8, bytes: u64) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1000) return std.fmt.bufPrint(out, "{d} B", .{bytes}) catch unreachable;
    if (bytes < 1000_000) return std.fmt.bufPrint(out, "{d:.1} KB", .{value / 1000}) catch unreachable;
    return std.fmt.bufPrint(out, "{d:.2} MB", .{value / 1000_000}) catch unreachable;
}

/// One label and value row of a group, inset `prop_inset`.
fn prop_row(cx: anytype, prop: Prop) void {
    const rect = cx.walk(ui.sized(.fill, .{ .fixed = row_px }));
    const clip = cx.visible(rect) orelse return;
    const inner = ui.cx.inset(rect, .xy(prop_inset, 0));
    kit.label(cx, styled(cx, .sans), prop.label, inner, clip, start);
    kit.label(cx, cx.theme().value, prop.value, inner, clip, end);
}

fn caption(cx: anytype, words: []const u8) void {
    const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
    const clip = cx.visible(line) orelse return;
    kit.label(cx, styled(cx, .sans), words, line, clip, start);
}

fn panel_paint(cx: anytype) widgets.Paint {
    return widgets.paint_of(cx.theme().colors.panel, panel_radius);
}

/// Sans 14 in the scheme's text colour.
fn styled(cx: anytype, face: text.Face) text.Style {
    return .{ .face = face, .size = 14, .color = cx.theme().colors.text };
}

/// A tree or table name: bold for a folder.
fn name_style(cx: anytype, folder: bool) text.Style {
    return styled(cx, if (folder) .sans_bold else .sans);
}

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const cut: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = false };

comptime {
    // Pre-order: every parent comes before its children, and only folders are parents.
    for (entries, 0..) |entry, index| {
        if (entry.parent == root) continue;
        assert(entry.parent < index);
        assert(entries[entry.parent].folder);
    }
    assert(entries[node_src].folder and entries[node_widgets].folder and entries[node_text].folder);
    assert(columns.len <= widgets.columns_max);
}

// Locks the sample data: folder sizes sum their files, kinds come from extensions, and sizes
// format in decimal units.
test "the sample tree sums folders and formats sizes" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("600 B", format_size(&out, 600));
    try std.testing.expectEqualStrings("12.5 KB", format_size(&out, 12456));
    try std.testing.expectEqualStrings("1.18 MB", format_size(&out, 1183000));
    try std.testing.expectEqualStrings("zig", kind_of(3));
    try std.testing.expectEqualStrings("folder", kind_of(node_src));
    try std.testing.expectEqualStrings("md", kind_of(node_count - 1));
}

//! `TreeView`: the app's nodes as a list box of visible rows, with chevrons and the tree's keys.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Nodes
//! The app owns a slice of `TreeNode`s in pre-order: a node's parent comes before it and every
//! subtree is contiguous, the order a depth-first listing of a folder gives. A node carries its
//! `parent` (`tree_root` for a root), whether it is `expanded`, and whether it `has_children`
//! (true for a folder not loaded yet, so it still shows a chevron). The app keeps names and
//! anything else in its own arrays, indexed by node.
//!
//! ## 2. Flattening
//! `flatten` turns the nodes into the visible rows in one linear pass with an explicit stack of
//! the open ancestors, at most `tree_depth_max` deep; there is no recursion:
//! ```text
//! for each node i:
//!   pop the stack down to parent(i)          (asserted found: the nodes are in pre-order)
//!   depth = stack length
//!   if hidden and depth <= hidden_depth: no longer hidden
//!   if not hidden: emit (i, depth)
//!   if has_children: push i; if not hidden and not expanded: hidden at depth
//! ```
//! `begin` flattens again every draw, so a change to the nodes needs no call; the tree also
//! flattens right after its own toggles, so the keys of the same event batch see the new rows.
//! The selection is a node, not a row: when a collapse hides it, it moves to the nearest
//! visible ancestor.
//!
//! ## 3. Rows
//! The rows are a `ListBoxOf(Skin)` of `count` rows (`widgets/list_box.zig`): its view, row
//! areas, bands, wheel, and keys. `next` adds the depth and the chevron:
//! ```text
//! chevron cell   tree_chevron_w x row height at row.x + tree_pad + depth * tree_indent
//! content        from the chevron cell's right + tree_pad to the row's right (TreeRow.rect)
//! ```
//! A node with children draws `Skin.tree_chevron` (turned down when expanded) and records its
//! chevron area, `id.derive(chevron_salt + node)`, on top of the row.
//!
//! ## 4. Events
//! ```text
//! chevron down                  toggle that node, focus the list          toggled
//! row click, Up, Down, Page Up, Page Down, Home, End   the list's        selected (a node)
//! double click or Enter         a node with children toggles             toggled
//!                               a leaf                                   activated
//! Right (focused)               collapsed parent: expand; expanded parent: its first child
//! Left  (focused)               expanded parent: collapse; otherwise: its parent
//! ```
//! Right on a leaf and Left on a collapsed root do nothing. A move scrolls into view.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: `capacity` rows and depths live in the widget; flattening is O(nodes) with
//!   a `tree_depth_max` stack.
//! - Every visible row is a node below `nodes.len`; `selected` is a node below it.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const list_box = @import("list_box.zig");

const Rect = kit.Rect;
const Clip = kit.Clip;
const Walk = kit.Walk;
const Id = kit.Id;

/// The parent of a root node.
pub const tree_root: u32 = std.math.maxInt(u32);
/// The deepest a node may be: the flattening stack's size.
pub const tree_depth_max: u32 = 32;
/// The most nodes a tree's `capacity` may be.
pub const tree_nodes_max: u32 = 4096;
/// Each depth's indent, the chevron's cell, and the space around it, in logical pixels.
pub const tree_indent: f32 = 16;
pub const tree_chevron_w: f32 = 16;
pub const tree_pad: f32 = 4;
/// The salt chevron ids start from: node `i`'s is `id.derive(chevron_salt + i)`.
pub const chevron_salt: u64 = 0x63686576 << 32;

/// One node of the app's tree (section 1).
pub const TreeNode = struct {
    parent: u32 = tree_root,
    expanded: bool = false,
    has_children: bool = false,
};

/// One walked row: its node and depth, the content rect after the chevron, its clip, and the
/// node's state.
pub const TreeRow = struct {
    node: u32,
    depth: u32,
    rect: Rect,
    clip: Clip,
    selected: bool,
    hovered: bool,
    expanded: bool,
    has_children: bool,
};

/// Writes the visible rows of `nodes` (pre-order) into `rows` and their depths into `depths`
/// (section 2); returns how many.
pub fn flatten(nodes: []const TreeNode, rows: []u32, depths: []u8) u32 {
    assert(nodes.len <= rows.len and nodes.len <= depths.len);
    assert(nodes.len <= tree_nodes_max);
    var stack: [tree_depth_max]u32 = undefined;
    var height: u32 = 0;
    var hidden: ?u32 = null;
    var count: u32 = 0;
    for (nodes, 0..) |node, at| {
        const index: u32 = @intCast(at);
        if (node.parent == tree_root) {
            height = 0;
        } else {
            assert(node.parent < index);
            while (height > 0 and stack[height - 1] != node.parent) height -= 1;
            assert(height > 0);
        }
        const depth = height;
        if (hidden) |level| {
            if (depth <= level) hidden = null;
        }
        if (hidden == null) {
            rows[count] = index;
            depths[count] = @intCast(depth);
            count += 1;
        }
        if (node.has_children) {
            assert(height < tree_depth_max);
            stack[height] = index;
            height += 1;
            if (hidden == null and !node.expanded) hidden = depth;
        }
    }
    assert(count <= nodes.len);
    return count;
}

/// The default tree with room for `capacity` nodes: `TreeViewOf(skins.Default, capacity)`.
pub fn TreeView(comptime capacity: u32) type {
    return TreeViewOf(skin.Default, capacity);
}

/// A tree of at most `capacity` nodes whose bands and chevrons `Skin` draws (`Skin.list_row`,
/// `Skin.tree_chevron`; `widgets/skin.zig`).
pub fn TreeViewOf(comptime Skin: type, comptime capacity: u32) type {
    if (comptime skin.check(Skin, .tree)) |problem| @compileError(problem);
    comptime assert(capacity >= 1 and capacity <= tree_nodes_max);
    return struct {
        const Self = @This();

        /// The rows' list box.
        pub const List = list_box.ListBoxOf(Skin);

        list: List,
        nodes: []TreeNode,
        /// The node of each visible row, and its depth.
        rows: [capacity]u32,
        depths: [capacity]u8,
        count: u32,
        /// The selected node.
        selected: ?u32,

        pub const Action = union(enum) {
            none,
            /// A click or a key selected this node.
            selected: u32,
            /// A double click or Enter on a leaf.
            activated: u32,
            /// A chevron, a key, a double click, or Enter expanded or collapsed this node.
            toggled: Toggled,
        };

        pub const Toggled = struct { node: u32, expanded: bool };

        /// A tree over `nodes` (pre-order, at most `capacity`) in rows of `row_h`, nothing
        /// selected.
        pub fn init(id: Id, nodes: []TreeNode, row_h: f32) Self {
            assert(nodes.len <= capacity);
            assert(row_h > 0);
            var tree: Self = .{
                .list = List.init(id, 0, row_h),
                .nodes = nodes,
                .rows = undefined,
                .depths = undefined,
                .count = 0,
                .selected = null,
            };
            tree.refresh();
            return tree;
        }

        /// The chevron of node `node`'s id (section 3).
        pub fn chevron_id(self: *const Self, node: u32) Id {
            assert(node < tree_nodes_max);
            return self.list.id.derive(chevron_salt + node);
        }

        /// The row showing `node`, or null when it is hidden.
        pub fn row_of(self: *const Self, node: u32) ?u32 {
            assert(node < self.nodes.len);
            for (self.rows[0..self.count], 0..) |shown, row| {
                if (shown == node) return @intCast(row);
            }
            return null;
        }

        /// Flattens the nodes again (section 2), moves a hidden selection to its nearest
        /// visible ancestor, and brings the list's count, selection, and range along.
        pub fn refresh(self: *Self) void {
            assert(self.nodes.len <= capacity);
            self.count = flatten(self.nodes, &self.rows, &self.depths);
            self.list.count = self.count;
            self.list.range.end = @min(self.list.range.end, self.count);
            self.list.range.first = @min(self.list.range.first, self.list.range.end);
            self.list.selected = null;
            const start = self.selected orelse return;
            assert(start < self.nodes.len);
            var node = start;
            var steps: u32 = 0;
            while (steps <= tree_depth_max) : (steps += 1) {
                if (self.row_of(node)) |row| {
                    self.selected = node;
                    self.list.selected = row;
                    return;
                }
                node = self.nodes[node].parent;
                if (node == tree_root) break;
            }
            self.selected = null;
        }

        /// Flattens the nodes and opens the list for `walk`; returns the rows `next` walks.
        /// Draw phase.
        pub fn begin(self: *Self, cx: anytype, walk: Walk) ui.List.Range {
            self.refresh();
            return self.list.begin(cx, walk);
        }

        /// Walks the next visible row: its band, its chevron and chevron area, and the content
        /// rect for the app; null after the last.
        pub fn next(self: *Self, cx: anytype) ?TreeRow {
            const row = self.list.next(cx) orelse return null;
            assert(row.index < self.count);
            const node = self.rows[row.index];
            const depth: u32 = self.depths[row.index];
            const state = self.nodes[node];
            const indent = @as(f32, @floatFromInt(depth)) * tree_indent;
            const cell: Rect = .{
                .x = row.rect.x + tree_pad + indent,
                .y = row.rect.y,
                .width = tree_chevron_w,
                .height = row.rect.height,
            };
            if (state.has_children) {
                const id = self.chevron_id(node);
                if (cx.visible(cell) != null) {
                    Skin.tree_chevron(cx, .{
                        .rect = cell,
                        .clip = row.clip,
                        .turn = if (state.expanded) 1 else 0,
                        .hovered = cx.hovered() == id,
                    });
                    cx.area(id, cell, 0, ui.cx.plain);
                }
            }
            const start = cell.x + tree_chevron_w + tree_pad;
            const stop = row.rect.x + row.rect.width;
            return .{
                .node = node,
                .depth = depth,
                .rect = .{
                    .x = start,
                    .y = row.rect.y,
                    .width = @max(0, stop - start),
                    .height = row.rect.height,
                },
                .clip = row.clip,
                .selected = row.selected,
                .hovered = row.hovered,
                .expanded = state.expanded,
                .has_children = state.has_children,
            };
        }

        /// Closes the list.
        pub fn end(self: *Self, cx: anytype) void {
            self.list.end(cx);
        }

        /// Chevrons, the tree's keys, then the list's rows and keys (section 4).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(!self.list.open);
            assert(self.count <= capacity);
            if (event == .frame) return .none;
            if (event == .key_down and cx.focused(self.list.id)) {
                switch (event.key_down.key) {
                    .left => return self.key_left(cx),
                    .right => return self.key_right(cx),
                    else => {},
                }
            }
            var index = self.list.range.first;
            while (index < @min(self.list.range.end, self.count)) : (index += 1) {
                const node = self.rows[index];
                if (!self.nodes[node].has_children) continue;
                switch (cx.hit(self.chevron_id(node), event)) {
                    .hover_in, .hover_out => cx.redraw(),
                    .down => {
                        cx.set_focus(self.list.id);
                        return self.toggle(cx, node);
                    },
                    .none, .drag, .up, .wheel, .secondary => {},
                }
            }
            return switch (self.list.handle(cx, event)) {
                .none => .none,
                .selected => |row| self.picked(self.rows[row]),
                .activated => |row| {
                    const node = self.rows[row];
                    self.selected = node;
                    if (self.nodes[node].has_children) return self.toggle(cx, node);
                    return .{ .activated = node };
                },
            };
        }

        fn picked(self: *Self, node: u32) Action {
            assert(node < self.nodes.len);
            self.selected = node;
            return .{ .selected = node };
        }

        /// Right: expand a collapsed parent, or step into an expanded one's first child.
        fn key_right(self: *Self, cx: anytype) Action {
            const node = self.selected orelse return .none;
            const state = self.nodes[node];
            if (!state.has_children) return .none;
            if (!state.expanded) return self.toggle(cx, node);
            const child = node + 1;
            if (child >= self.nodes.len or self.nodes[child].parent != node) return .none;
            return self.select(cx, child);
        }

        /// Left: collapse an expanded parent, or step out to the parent.
        fn key_left(self: *Self, cx: anytype) Action {
            const node = self.selected orelse return .none;
            const state = self.nodes[node];
            if (state.has_children and state.expanded) return self.toggle(cx, node);
            if (state.parent == tree_root) return .none;
            return self.select(cx, state.parent);
        }

        fn select(self: *Self, cx: anytype, node: u32) Action {
            assert(node < self.nodes.len);
            self.selected = node;
            self.refresh();
            const row = self.list.selected.?;
            self.list.scroll_into_view(cx, row);
            cx.redraw();
            return .{ .selected = node };
        }

        fn toggle(self: *Self, cx: anytype, node: u32) Action {
            assert(node < self.nodes.len);
            assert(self.nodes[node].has_children);
            self.nodes[node].expanded = !self.nodes[node].expanded;
            self.refresh();
            if (self.list.selected) |row| self.list.scroll_into_view(cx, row);
            cx.redraw();
            return .{ .toggled = .{ .node = node, .expanded = self.nodes[node].expanded } };
        }
    };
}

comptime {
    // Chevron ids sit between the view's thumb and the rows: no row or thumb id meets one.
    assert(chevron_salt > ui.view.thumb_salt);
    assert(chevron_salt + tree_nodes_max <= list_box.row_salt);
    assert(tree_depth_max <= std.math.maxInt(u8));
    assert(tree_chevron_w > 0 and tree_indent > 0);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

/// a (b (c), d), e (f): a and e expanded, b collapsed.
fn sample() [6]TreeNode {
    return .{
        .{ .expanded = true, .has_children = true },
        .{ .parent = 0, .has_children = true },
        .{ .parent = 1 },
        .{ .parent = 0 },
        .{ .expanded = true, .has_children = true },
        .{ .parent = 4 },
    };
}

// Locks flattening (section 2): with b collapsed the rows are a, b, d, e, f at depths 0, 1,
// 1, 0, 1; expanding b shows c at depth 2; collapsing a hides its whole subtree.
test "flatten emits the visible nodes with their depths" {
    var nodes = sample();
    var rows: [6]u32 = undefined;
    var depths: [6]u8 = undefined;
    var count = flatten(&nodes, &rows, &depths);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 4, 5 }, rows[0..count]);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 1, 0, 1 }, depths[0..count]);
    nodes[1].expanded = true;
    count = flatten(&nodes, &rows, &depths);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, rows[0..count]);
    try testing.expectEqual(@as(u8, 2), depths[2]);
    nodes[0].expanded = false;
    count = flatten(&nodes, &rows, &depths);
    try testing.expectEqualSlices(u32, &.{ 0, 4, 5 }, rows[0..count]);
}

// Locks the depth bound: a chain of `tree_depth_max` nodes flattens, its last at depth 31.
test "flatten reaches the depth bound" {
    var nodes: [tree_depth_max]TreeNode = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = .{
            .parent = if (index == 0) tree_root else @intCast(index - 1),
            .expanded = true,
            .has_children = index + 1 < nodes.len,
        };
    }
    var rows: [tree_depth_max]u32 = undefined;
    var depths: [tree_depth_max]u8 = undefined;
    try testing.expectEqual(tree_depth_max, flatten(&nodes, &rows, &depths));
    try testing.expectEqual(@as(u8, tree_depth_max - 1), depths[tree_depth_max - 1]);
}

const Tree = TreeView(8);

/// Draws `tree` in a 216 x 240 box at (0, 0), rows of 24, and returns the rows walked.
fn draw_tree(cx: *fixture.Context, tree: *Tree, out: []TreeRow) []TreeRow {
    cx.begin_frame(1280, 720, 120);
    _ = tree.begin(cx, fixture.at(0, 0, 216, 240));
    var count: usize = 0;
    while (tree.next(cx)) |row| : (count += 1) out[count] = row;
    tree.end(cx);
    _ = cx.end_frame();
    return out[0..count];
}

fn key(name: input.Key) input.Event {
    return .{ .key_down = input.key_press(name, .none, false, "") };
}

fn centre_of(cx: *fixture.Context, id: Id) input.Point {
    const area = cx.find(id).?;
    return .{ .x = area.rect[0] + area.rect[2] * 0.5, .y = area.rect[1] + area.rect[3] * 0.5 };
}

// Locks the rows (section 3): each row's content starts at 4 + depth * 16 + 16 + 4, only the
// parents have chevron areas (16 px wide at 4 + depth * 16), and a hidden selection moves to
// its visible ancestor when a collapse hides it.
test "a tree draws indented rows with chevrons on parents" {
    const cx = fixture.context();
    var nodes = sample();
    var tree = Tree.init(ui.id("tree", 0), &nodes, 24);
    var out: [8]TreeRow = undefined;
    const rows = draw_tree(cx, &tree, &out);
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqual(@as(f32, 24), rows[0].rect.x);
    try testing.expectEqual(@as(f32, 40), rows[1].rect.x);
    try testing.expectEqual(@as(u32, 1), rows[1].depth);
    try testing.expectEqualSlices(f32, &.{ 20, 24, 16, 24 }, &cx.find(tree.chevron_id(1)).?.rect);
    try testing.expect(cx.find(tree.chevron_id(3)) == null);
    try testing.expectEqual(@as(u32, 3), @as(u32, @intCast(cx.draw.items(draw.Path).len)));
    nodes[1].expanded = true;
    tree.selected = 2;
    tree.refresh();
    try testing.expectEqual(@as(?u32, 2), tree.list.selected);
    nodes[0].expanded = false;
    tree.refresh();
    try testing.expectEqual(@as(?u32, 0), tree.selected);
    try testing.expectEqual(@as(?u32, 0), tree.list.selected);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the keys of section 4 at the edges: Down selects a; Left collapses it (a, e, f left)
// and Left again does nothing (a root); Right expands, Right steps into b, Right expands b,
// Right steps into c, Right on the leaf does nothing, Left steps out to b; End selects f and
// Enter activates the leaf; Up selects e and Enter collapses it.
test "tree keys expand, collapse, and walk the edges" {
    const cx = fixture.context();
    var nodes = sample();
    var tree = Tree.init(ui.id("tree", 0), &nodes, 24);
    var out: [8]TreeRow = undefined;
    _ = draw_tree(cx, &tree, &out);
    cx.event_begin(.{ .frame = 0 });
    cx.set_focus(tree.list.id);
    cx.event_end();
    try testing.expectEqual(Tree.Action{ .selected = 0 }, fixture.send(cx, &tree, key(.down)));
    const closed: Tree.Action = .{ .toggled = .{ .node = 0, .expanded = false } };
    try testing.expectEqual(closed, fixture.send(cx, &tree, key(.left)));
    try testing.expectEqual(@as(u32, 3), tree.count);
    try testing.expectEqual(Tree.Action.none, fixture.send(cx, &tree, key(.left)));
    const opened: Tree.Action = .{ .toggled = .{ .node = 0, .expanded = true } };
    try testing.expectEqual(opened, fixture.send(cx, &tree, key(.right)));
    try testing.expectEqual(Tree.Action{ .selected = 1 }, fixture.send(cx, &tree, key(.right)));
    const b_open: Tree.Action = .{ .toggled = .{ .node = 1, .expanded = true } };
    try testing.expectEqual(b_open, fixture.send(cx, &tree, key(.right)));
    try testing.expectEqual(Tree.Action{ .selected = 2 }, fixture.send(cx, &tree, key(.right)));
    try testing.expectEqual(Tree.Action.none, fixture.send(cx, &tree, key(.right)));
    try testing.expectEqual(Tree.Action{ .selected = 1 }, fixture.send(cx, &tree, key(.left)));
    try testing.expectEqual(Tree.Action{ .selected = 5 }, fixture.send(cx, &tree, key(.end)));
    try testing.expectEqual(Tree.Action{ .activated = 5 }, fixture.send(cx, &tree, key(.enter)));
    try testing.expectEqual(Tree.Action{ .selected = 4 }, fixture.send(cx, &tree, key(.up)));
    const e_closed: Tree.Action = .{ .toggled = .{ .node = 4, .expanded = false } };
    try testing.expectEqual(e_closed, fixture.send(cx, &tree, key(.enter)));
    try testing.expectEqual(@as(u32, 5), tree.count);
}

// Locks the chevron (sections 3 and 4): a press on b's chevron expands it without selecting it
// and focuses the list; the next draw shows c; a click on a row selects its node.
test "a chevron press toggles its node and a row click selects" {
    const cx = fixture.context();
    var nodes = sample();
    var tree = Tree.init(ui.id("tree", 0), &nodes, 24);
    var out: [8]TreeRow = undefined;
    _ = draw_tree(cx, &tree, &out);
    const chevron = centre_of(cx, tree.chevron_id(1));
    const toggled = fixture.send(cx, &tree, .{ .pointer_down = input.left_at(chevron) });
    try testing.expectEqual(Tree.Action{ .toggled = .{ .node = 1, .expanded = true } }, toggled);
    try testing.expect(cx.focused(tree.list.id));
    try testing.expectEqual(@as(?u32, null), tree.selected);
    _ = fixture.send(cx, &tree, .{ .pointer_up = input.left_at(chevron) });
    const rows = draw_tree(cx, &tree, &out);
    try testing.expectEqual(@as(usize, 6), rows.len);
    try testing.expectEqual(@as(u32, 2), rows[2].node);
    const row = centre_of(cx, tree.list.row_id(3));
    _ = fixture.send(cx, &tree, .{ .pointer_down = input.left_at(row) });
    const picked = fixture.send(cx, &tree, .{ .pointer_up = input.left_at(row) });
    try testing.expectEqual(Tree.Action{ .selected = 3 }, picked);
}

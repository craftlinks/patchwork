//! `Dock`: panels in a tree of splits and tab sets that a dragged tab restructures.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! A dock owns where panels are, never what they show: `init(id, labels)` names the panels
//! (a panel's id is its index in `labels`), and the app draws each visible panel itself:
//! ```text
//! dock.begin(cx, walk)
//! while (dock.next(cx)) |panel| switch (panel.id) { files => …, editor => …, else => {} }
//! dock.end(cx)
//! dock.handle(cx, event) -> none | activated | closed | moved: panel | resized
//! ```
//! It is a fixed array of `dock_nodes_max` nodes, each `free`, a `split` (two children and a
//! `Splitter`, whose ratio is pane a's share), or a `set` (its own labels and keys arrays and
//! a closable, movable `Tabs` keyed by panel id, step 45). The root is any node; an empty dock
//! is an empty root set. A node's ids are `id.derive(slot + 1)` and, for a set's page, that
//! derived by `page_salt`; slots are allocated lowest-free, so a layout built the same way
//! has the same ids (bench targets name them). Before drawing and handling, each set's `Tabs`
//! is re-pointed at its own arrays, so a copied `Dock` stays correct.
//!
//! ## 2. The Tree
//! ```text
//! add(set, panel)                      append to a set and select it
//! split(set, zone, panel, share)       a new set on `zone`'s side of `set`, taking `share`;
//!                                      left and right split horizontally, top and bottom
//!                                      vertically; the new set is pane a for left and top
//! split_root(zone, panel, share)       the same around the whole tree (an edge drop)
//! close(panel)                         remove it; an empty set collapses
//! show(panel)                          select it, or add it to the first set when closed
//! ```
//! A split needs two free nodes (the new set and the split) and returns null without them.
//! Collapse: an empty set that is not the root frees itself and its parent split, and the
//! sibling takes the split's place in the grandparent (or becomes the root).
//!
//! ## 3. Drawing
//! `next` walks the tree with an explicit stack of `(node, stage)`, never recursion: a split
//! is `splitter.begin`, its pane a, `splitter.next`, its pane b, `splitter.end`; a set is
//! `tabs.begin` (its page a clipped column), its page area flagged `drag_target`, and the
//! selected panel returned with the page's rect for the app to fill; the next call closes
//! the page. An empty set closes at once.
//!
//! ## 4. Zones and Edges
//! While a drag between widgets is over a set's page (`ui/cx.zig`, section 7b), the zone
//! under the pointer is the nearest side when its normalized distance is under
//! `dock_zone_fraction`, else the centre; the overlay covers that half of the page (all of
//! it for the centre). While any drag is in flight, `end` records four `dock_edge_px` strips
//! along the dock's edges after everything else (so they win near the edges, and never block
//! a press otherwise); over one, the overlay is that quarter of the dock. The overlay is
//! `colors.focus` at `dock_overlay_alpha` with a border, on `Layer.popup`, under the ghost.
//!
//! ## 5. Events and Moving a Panel
//! `handle` gives every split's `Splitter` (moved or reset: `resized`) and every set's `Tabs`
//! the event and asks `drag_hit` of every page and edge, collecting before applying, so a
//! drag's two halves (the source bar's `dragged_out`, the target's drop) read the same tree:
//! ```text
//! changed i      activated
//! closed i       close: closed
//! moved          the set's arrays move: moved
//! received       target the bar at its index        (from the target bar)
//! page dropped   target (set, zone of the point)
//! edge dropped   target (edge, its side)
//! dragged_out    ignored: the target half moves the panel
//! ```
//! Moving to a target removes the panel from its set, inserts or splits at the target and
//! selects it there, then collapses the old set if empty: `moved`. No-ops (a centre drop on
//! its own set, a side drop on its own set holding only it, an edge drop while it is the
//! lone panel of the root) and refusals (a side or edge drop with fewer than two free nodes, a
//! payload that is not a panel) change nothing, and every set's selection is restored from
//! before the event. A panel that is not docked (dragged in from elsewhere) is added.
//!
//! ## 6. Save and Load
//! ```text
//! "PWDK"  version 1  node_count  root  0
//! per node 0 .. node_count:  kind (0 free, 1 split, 2 set)
//!   split  axis (0 horizontal, 1 vertical)  ratio (u16 LE, ratio * 65535)  a  b
//!   set    count  selected  panel ids (count bytes)
//! ```
//! `load` decodes into scratch and checks everything before it replaces the layout: the
//! magic, the version, the exact length, node kinds and axes, children in range, used, not
//! the root, each a child once; every used node reached from the root exactly once (an
//! explicit stack: no cycle, no orphan); set counts within `tabs_max`, `selected < count`
//! (0 when empty); panel ids below `labels.len`, each once; and only the root may be empty.
//! A refused load changes nothing; the app keeps its layout or builds its default.
//!
//! ## 7. TigerStyle Invariants
//! - No allocation: `dock_nodes_max` nodes inline, each set `tabs_max` panels; the draw stack
//!   is `dock_nodes_max` deep. Every loop is bounded by the node or panel caps.
//! - Parents and children agree, every used node is reachable once from the root, and each
//!   panel is in at most one set (`verify`, for tests).

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const tabs_file = @import("tabs.zig");
const splitter_file = @import("splitter.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;
const tabs_max = tabs_file.tabs_max;

/// Nodes one dock holds: 32 sets of one panel each and the 31 splits between them, and one
/// spare.
pub const dock_nodes_max: u32 = 64;
/// Panels one dock names.
pub const dock_panels_max: u32 = 32;
/// The strips along the dock's edges that take an edge drop while a drag is in flight.
pub const dock_edge_px: f32 = 24;
/// A side zone is the outer quarter of a set's page (section 4).
pub const dock_zone_fraction: f32 = 0.25;
/// A pane's minimum length: both minimums of every split's `Splitter`.
pub const dock_pane_min: f32 = 96;
/// The share of a side drop's new pane, and of an edge drop's.
pub const dock_zone_share: f32 = 0.5;
pub const dock_edge_share: f32 = 0.25;
/// The overlay's fill opacity.
pub const dock_overlay_alpha: f32 = 0.25;
/// Bytes `save` writes at most (section 6).
pub const dock_save_max: u32 = 8 + dock_nodes_max * (3 + tabs_max);
/// The `derive` salts of a set's page and of the edge strips.
pub const page_salt: u64 = 0x70616765;
pub const edge_salt: u64 = 0x65646765 << 8;

/// Where a drop lands on a set's page (section 4).
pub const Zone = enum(u8) { centre, left, right, top, bottom };

/// What a node is (section 1).
pub const Kind = enum(u8) { free, split, set };

const none: u8 = 0xff;
const magic = "PWDK";
const version: u8 = 1;

/// A visible panel: its id and its page, an open clipped column the app fills.
pub const Panel = struct {
    id: u32,
    rect: Rect,
};

/// The zone of the point `(x, y)` in a page `rect` (section 4).
pub fn zone_of(rect: Rect, x: f32, y: f32) Zone {
    assert(rect.width > 0 and rect.height > 0);
    const u = (x - rect.x) / rect.width;
    const v = (y - rect.y) / rect.height;
    const sides = [4]struct { f32, Zone }{
        .{ u, .left },
        .{ 1 - u, .right },
        .{ v, .top },
        .{ 1 - v, .bottom },
    };
    var best = sides[0];
    for (sides[1..]) |side| {
        if (side[0] < best[0]) best = side;
    }
    if (best[0] >= dock_zone_fraction) return .centre;
    return best[1];
}

/// The part of `rect` a drop on `zone` takes: its half on that side, or all of it.
pub fn zone_rect(rect: Rect, zone: Zone) Rect {
    var out = rect;
    switch (zone) {
        .centre => {},
        .left => out.width = rect.width * 0.5,
        .right => {
            out.width = rect.width * 0.5;
            out.x = rect.x + rect.width - out.width;
        },
        .top => out.height = rect.height * 0.5,
        .bottom => {
            out.height = rect.height * 0.5;
            out.y = rect.y + rect.height - out.height;
        },
    }
    assert(out.width <= rect.width and out.height <= rect.height);
    return out;
}

/// The strip along `rect`'s side `zone` (never `centre`) that takes an edge drop, and, with
/// `fraction`, the part of `rect` on that side an edge drop's overlay shows.
pub fn edge_rect(rect: Rect, zone: Zone, depth: f32) Rect {
    assert(zone != .centre);
    assert(depth > 0);
    var out = rect;
    switch (zone) {
        .centre => unreachable,
        .left => out.width = @min(depth, rect.width),
        .right => {
            out.width = @min(depth, rect.width);
            out.x = rect.x + rect.width - out.width;
        },
        .top => out.height = @min(depth, rect.height),
        .bottom => {
            out.height = @min(depth, rect.height);
            out.y = rect.y + rect.height - out.height;
        },
    }
    return out;
}

/// The four sides an edge drop takes, in the order their strips are recorded.
const edges = [4]Zone{ .left, .right, .top, .bottom };

/// A dock whose tabs and dividers `Skin` draws (it skins `.tabs` and `.splitter`).
pub fn DockOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .tabs)) |problem| @compileError(problem);
    if (comptime skin.check(Skin, .splitter)) |problem| @compileError(problem);
    const Tabs = tabs_file.TabsOf(Skin);
    const Splitter = splitter_file.SplitterOf(Skin);
    return struct {
        const Self = @This();

        pub const TabsType = Tabs;
        pub const SplitterType = Splitter;

        /// One node (section 1). A split uses `a`, `b`, and `splitter`; a set the rest.
        pub const Node = struct {
            kind: Kind,
            parent: u8,
            a: u8,
            b: u8,
            splitter: Splitter,
            labels: [tabs_max][]const u8,
            keys: [tabs_max]u64,
            len: u32,
            tabs: Tabs,
            /// The set's page at the last draw.
            page: Rect,
        };

        /// Where a drop lands (section 5).
        pub const Target = union(enum) {
            bar: struct { set: u8, index: u32 },
            zone: struct { set: u8, zone: Zone },
            edge: Zone,
        };

        pub const Action = union(enum) {
            none,
            /// A tab was selected: its panel.
            activated: u32,
            /// A panel left the layout.
            closed: u32,
            /// A panel moved within its set or to another place.
            moved: u32,
            /// A divider moved.
            resized,
        };

        const Frame = struct { node: u8, stage: u8 };

        id: Id,
        /// The app's panel labels; a panel's id is its index.
        labels: []const []const u8,
        nodes: [dock_nodes_max]Node,
        root: u8,
        /// The draw's stack (section 3), its depth, and whether a page is open.
        stack: [dock_nodes_max]Frame,
        depth: u32,
        page_open: bool,
        /// The dock's rect at the last draw.
        drawn: Rect,

        /// An empty root set over `labels` (1 to `dock_panels_max`). Out-pointer init: a dock
        /// is about 40 KiB.
        pub fn init(self: *Self, id: Id, labels: []const []const u8) void {
            assert(id != .none);
            assert(labels.len >= 1 and labels.len <= dock_panels_max);
            self.id = id;
            self.labels = labels;
            self.clear();
            self.depth = 0;
            self.page_open = false;
            self.drawn = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            assert(self.nodes[self.root].kind == .set);
        }

        /// Every node free but an empty root set in slot 0.
        pub fn clear(self: *Self) void {
            for (&self.nodes) |*node| {
                node.kind = .free;
                node.parent = none;
                node.len = 0;
            }
            self.root = 0;
            self.init_set(0);
            assert(self.nodes[self.root].kind == .set);
        }

        /// Node `slot`'s widget id: its set's tabs or its split's splitter.
        pub fn node_id(self: *const Self, slot: u8) Id {
            assert(slot < dock_nodes_max);
            return self.id.derive(@as(u64, slot) + 1);
        }

        /// The drag target over set `slot`'s page.
        pub fn page_id(self: *const Self, slot: u8) Id {
            return self.node_id(slot).derive(page_salt);
        }

        /// The drag target of the edge strip on side `zone`.
        pub fn edge_id(self: *const Self, zone: Zone) Id {
            assert(zone != .centre);
            return self.id.derive(edge_salt + @backingInt(zone));
        }

        // ------------------------------------------------------------------ tree

        /// Appends `panel` to set `set` and selects it (section 2).
        pub fn add(self: *Self, set: u8, panel: u32) void {
            const node = &self.nodes[set];
            assert(node.kind == .set);
            self.insert(set, panel, node.len);
        }

        /// A new set holding `panel` on `zone`'s side of set `set`, taking `share` of it, or
        /// null when fewer than two nodes are free (section 2).
        pub fn split(self: *Self, set: u8, zone: Zone, panel: u32, share: f32) ?u8 {
            assert(self.nodes[set].kind == .set);
            return self.split_node(set, zone, panel, share);
        }

        /// A new set holding `panel` on `zone`'s side of the whole tree (an edge drop).
        pub fn split_root(self: *Self, zone: Zone, panel: u32, share: f32) ?u8 {
            return self.split_node(self.root, zone, panel, share);
        }

        /// Removes `panel` from the layout; an empty set collapses (section 2).
        pub fn close(self: *Self, panel: u32) void {
            const set = self.set_of(panel) orelse return;
            self.remove(set, panel);
            self.collapse(set);
        }

        /// Selects `panel`, or adds it to the first set when it is not docked.
        pub fn show(self: *Self, panel: u32) void {
            assert(panel < self.labels.len);
            if (self.set_of(panel)) |set| {
                const node = &self.nodes[set];
                node.tabs.selected = index_in(node, panel).?;
                return;
            }
            for (self.nodes, 0..) |node, slot| {
                if (node.kind == .set) return self.add(@intCast(slot), panel);
            }
            unreachable;
        }

        /// The set holding `panel`, or null.
        pub fn set_of(self: *const Self, panel: u32) ?u8 {
            for (&self.nodes, 0..) |*node, slot| {
                if (node.kind != .set) continue;
                if (index_in(node, panel) != null) return @intCast(slot);
            }
            return null;
        }

        /// `panel`'s tab id, or null when it is not docked.
        pub fn tab_id(self: *const Self, panel: u32) ?Id {
            const set = self.set_of(panel) orelse return null;
            return self.node_id(set).derive(panel);
        }

        /// `panel`'s close button id, or null when it is not docked.
        pub fn close_id(self: *const Self, panel: u32) ?Id {
            const tab = self.tab_id(panel) orelse return null;
            return tab.derive(tabs_file.close_salt);
        }

        /// Panels docked, and free nodes.
        pub fn panels_docked(self: *const Self) u32 {
            var count: u32 = 0;
            for (self.nodes) |node| {
                if (node.kind == .set) count += node.len;
            }
            return count;
        }

        pub fn free_count(self: *const Self) u32 {
            var count: u32 = 0;
            for (self.nodes) |node| count += @intFromBool(node.kind == .free);
            return count;
        }

        fn index_in(node: *const Node, panel: u32) ?u32 {
            for (node.keys[0..node.len], 0..) |key, at| {
                if (key == panel) return @intCast(at);
            }
            return null;
        }

        /// Inserts `panel` (not docked) into set `set` at `index` and selects it.
        fn insert(self: *Self, set: u8, panel: u32, index: u32) void {
            assert(panel < self.labels.len);
            assert(self.set_of(panel) == null);
            const node = &self.nodes[set];
            assert(node.kind == .set);
            assert(node.len < tabs_max);
            const at = @min(index, node.len);
            tabs_file.insert_item([]const u8, &node.labels, node.len, at, self.labels[panel]);
            tabs_file.insert_item(u64, &node.keys, node.len, at, panel);
            node.len += 1;
            node.tabs.set(node.labels[0..node.len], node.keys[0..node.len]);
            node.tabs.selected = at;
        }

        /// Removes `panel` from set `set`, keeping its `Tabs` selection as a close would.
        fn remove(self: *Self, set: u8, panel: u32) void {
            const node = &self.nodes[set];
            assert(node.kind == .set);
            const at = index_in(node, panel).?;
            const selected = node.tabs.selected;
            tabs_file.remove_item([]const u8, node.labels[0..node.len], at);
            tabs_file.remove_item(u64, node.keys[0..node.len], at);
            node.len -= 1;
            node.tabs.selected = if (at < selected) selected - 1 else selected;
            node.tabs.set(node.labels[0..node.len], node.keys[0..node.len]);
            assert(self.set_of(panel) == null);
        }

        fn split_node(self: *Self, target: u8, zone: Zone, panel: u32, share: f32) ?u8 {
            assert(zone != .centre);
            assert(share > 0 and share < 1);
            assert(self.nodes[target].kind != .free);
            if (self.free_count() < 2) return null;
            const fresh = self.alloc_set().?;
            self.insert(fresh, panel, 0);
            const parent = self.nodes[target].parent;
            const axis: splitter_file.Axis = switch (zone) {
                .left, .right => .horizontal,
                .top, .bottom => .vertical,
                .centre => unreachable,
            };
            const first = zone == .left or zone == .top;
            const ratio = if (first) share else 1 - share;
            const pair: [2]u8 = if (first) .{ fresh, target } else .{ target, fresh };
            const joint = self.alloc_split(axis, ratio, pair[0], pair[1]).?;
            self.replace_child(parent, target, joint);
            return fresh;
        }

        /// Frees an empty set that is not the root, and its parent split; the sibling takes
        /// the split's place (section 2).
        fn collapse(self: *Self, set: u8) void {
            const node = &self.nodes[set];
            assert(node.kind == .set);
            if (node.len > 0 or set == self.root) return;
            const joint = node.parent;
            assert(self.nodes[joint].kind == .split);
            const pair = self.nodes[joint];
            const sibling = if (pair.a == set) pair.b else pair.a;
            self.replace_child(self.nodes[joint].parent, joint, sibling);
            node.kind = .free;
            node.parent = none;
            self.nodes[joint].kind = .free;
            self.nodes[joint].parent = none;
        }

        /// Puts `fresh` where `old` was among `parent`'s children, or at the root.
        fn replace_child(self: *Self, parent: u8, old: u8, fresh: u8) void {
            assert(old != fresh);
            self.nodes[fresh].parent = parent;
            if (parent == none) {
                assert(self.root == old);
                self.root = fresh;
                return;
            }
            const joint = &self.nodes[parent];
            assert(joint.kind == .split);
            if (joint.a == old) {
                joint.a = fresh;
            } else {
                assert(joint.b == old);
                joint.b = fresh;
            }
        }

        fn alloc(self: *Self) ?u8 {
            for (&self.nodes, 0..) |*node, slot| {
                if (node.kind == .free) return @intCast(slot);
            }
            return null;
        }

        fn alloc_set(self: *Self) ?u8 {
            const slot = self.alloc() orelse return null;
            self.init_set(slot);
            return slot;
        }

        /// An empty set in the free slot `slot`.
        fn init_set(self: *Self, slot: u8) void {
            const node = &self.nodes[slot];
            assert(node.kind == .free);
            node.kind = .set;
            node.parent = none;
            node.len = 0;
            node.page = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            node.tabs = Tabs.init_keyed(self.node_id(slot), node.labels[0..0], node.keys[0..0], 0);
            node.tabs.closable = true;
            node.tabs.movable = true;
        }

        fn alloc_split(self: *Self, axis: splitter_file.Axis, ratio: f32, a: u8, b: u8) ?u8 {
            const slot = self.alloc() orelse return null;
            const node = &self.nodes[slot];
            node.kind = .split;
            node.parent = none;
            node.a = a;
            node.b = b;
            node.splitter = self.splitter_at(slot, axis, ratio);
            self.nodes[a].parent = slot;
            self.nodes[b].parent = slot;
            return slot;
        }

        /// Split `slot`'s splitter: both minimums `dock_pane_min`.
        fn splitter_at(self: *const Self, slot: u8, axis: splitter_file.Axis, ratio: f32) Splitter {
            return Splitter.init(self.node_id(slot), axis, ratio, dock_pane_min, dock_pane_min);
        }

        /// Points every set's `Tabs` at its own arrays (section 1).
        fn refresh(self: *Self) void {
            for (&self.nodes) |*node| {
                if (node.kind != .set) continue;
                node.tabs.set(node.labels[0..node.len], node.keys[0..node.len]);
            }
        }

        /// Checks the invariants of section 7. O(nodes * panels); for tests.
        pub fn verify(self: *const Self) void {
            assert(self.nodes[self.root].kind != .free);
            assert(self.nodes[self.root].parent == none);
            var seen: u64 = 0;
            var panels: u64 = 0;
            var stack: [dock_nodes_max]u8 = undefined;
            var depth: u32 = 1;
            stack[0] = self.root;
            while (depth > 0) {
                depth -= 1;
                const slot = stack[depth];
                assert(seen & (@as(u64, 1) << @intCast(slot)) == 0);
                seen |= @as(u64, 1) << @intCast(slot);
                const node = &self.nodes[slot];
                switch (node.kind) {
                    .free => unreachable,
                    .split => {
                        for ([2]u8{ node.a, node.b }) |child| {
                            assert(self.nodes[child].parent == slot);
                            stack[depth] = child;
                            depth += 1;
                        }
                    },
                    .set => {
                        assert(node.len > 0 or slot == self.root);
                        assert(node.tabs.selected < node.len or node.len == 0);
                        for (node.keys[0..node.len]) |key| {
                            assert(key < self.labels.len);
                            assert(panels & (@as(u64, 1) << @intCast(key)) == 0);
                            panels |= @as(u64, 1) << @intCast(key);
                        }
                    },
                }
            }
            for (self.nodes, 0..) |node, slot| {
                const used = node.kind != .free;
                assert(used == (seen & (@as(u64, 1) << @intCast(slot)) != 0));
            }
        }

        // ------------------------------------------------------------------ draw

        /// Opens the dock for `walk` (fixed or fill on both axes). Draw phase.
        pub fn begin(self: *Self, cx: anytype, walk: Walk) void {
            assert(self.depth == 0 and !self.page_open);
            assert(walk.width != .fit and walk.height != .fit);
            self.refresh();
            self.drawn = cx.begin(walk, .{ .flow = .down });
            self.stack[0] = .{ .node = self.root, .stage = 0 };
            self.depth = 1;
        }

        /// The next visible panel, its page open for the app to fill, or null (section 3).
        pub fn next(self: *Self, cx: anytype) ?Panel {
            if (self.page_open) {
                _ = cx.end();
                self.page_open = false;
            }
            const fill = ui.sized(.fill, .fill);
            while (self.depth > 0) {
                const top = &self.stack[self.depth - 1];
                const slot = top.node;
                const node = &self.nodes[slot];
                switch (node.kind) {
                    .free => unreachable,
                    .split => switch (top.stage) {
                        0 => {
                            _ = node.splitter.begin(cx, fill);
                            top.stage = 1;
                            self.push(node.a);
                        },
                        1 => {
                            _ = node.splitter.next(cx);
                            top.stage = 2;
                            self.push(node.b);
                        },
                        else => {
                            node.splitter.end(cx);
                            self.depth -= 1;
                        },
                    },
                    .set => {
                        self.depth -= 1;
                        const page = node.tabs.begin(cx, fill, page_layout);
                        node.page = page;
                        if (page.width > 0 and page.height > 0) {
                            cx.area(self.page_id(slot), page, 0, ui.cx.drag_target_flag);
                        }
                        if (node.len == 0) {
                            _ = cx.end();
                            continue;
                        }
                        self.page_open = true;
                        return .{ .id = @intCast(node.keys[node.tabs.selected]), .rect = page };
                    },
                }
            }
            return null;
        }

        /// Closes the last page, records the edge strips and draws the drop overlay while a
        /// drag is in flight (section 4), and closes the dock. Draw phase.
        pub fn end(self: *Self, cx: anytype) void {
            while (self.next(cx)) |_| {}
            assert(self.depth == 0 and !self.page_open);
            if (cx.dragging()) |drag| self.draw_drop(cx, drag);
            _ = cx.end();
        }

        fn push(self: *Self, slot: u8) void {
            assert(self.depth < dock_nodes_max);
            assert(self.nodes[slot].kind != .free);
            self.stack[self.depth] = .{ .node = slot, .stage = 0 };
            self.depth += 1;
        }

        fn draw_drop(self: *Self, cx: anytype, drag: ui.Dragging) void {
            for (edges) |zone| {
                const strip = edge_rect(self.drawn, zone, dock_edge_px);
                if (strip.width > 0 and strip.height > 0) {
                    cx.area(self.edge_id(zone), strip, 0, ui.cx.drag_target_flag);
                }
            }
            const shown = self.overlay(drag) orelse return;
            const colors = &cx.theme().colors;
            var fill = colors.focus;
            fill[3] *= dock_overlay_alpha;
            const clip = ui.cx.clip_of(cx.window);
            const previous = cx.drawing().layer(.popup);
            kit.face(cx, shown, clip, .{
                .fill = fill,
                .border_color = colors.focus,
                .border_width = 2,
                .radius = 4,
            });
            _ = cx.drawing().layer(previous);
        }

        /// The overlay's rect for the drag's target, when it is one of this dock's.
        pub fn overlay(self: *const Self, drag: ui.Dragging) ?Rect {
            if (drag.target == .none) return null;
            for (edges) |zone| {
                if (drag.target == self.edge_id(zone)) {
                    return edge_rect(self.drawn, zone, self.edge_depth(zone));
                }
            }
            for (&self.nodes, 0..) |*node, slot| {
                if (node.kind != .set) continue;
                if (drag.target != self.page_id(@intCast(slot))) continue;
                if (!(node.page.width > 0 and node.page.height > 0)) return null;
                return zone_rect(node.page, zone_of(node.page, drag.x, drag.y));
            }
            return null;
        }

        fn edge_depth(self: *const Self, zone: Zone) f32 {
            const across = if (zone == .left or zone == .right)
                self.drawn.width
            else
                self.drawn.height;
            return @max(1, across * dock_edge_share);
        }

        // ---------------------------------------------------------------- events

        /// Dividers, tabs, and drops (section 5).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.depth == 0);
            self.refresh();
            var action: Action = .none;
            var selections: [dock_nodes_max]u32 = undefined;
            var closing: ?u32 = null;
            var target: ?Target = null;
            var payload: u64 = 0;
            for (&self.nodes, 0..) |*node, index| {
                const slot: u8 = @intCast(index);
                switch (node.kind) {
                    .free => {},
                    .split => switch (node.splitter.handle(cx, event)) {
                        .moved, .reset => action = .resized,
                        .none => {},
                    },
                    .set => {
                        selections[slot] = node.tabs.selected;
                        switch (node.tabs.handle(cx, event)) {
                            .none, .dragged_out => {},
                            .changed => |at| action = .{ .activated = @intCast(node.keys[at]) },
                            .closed => |at| closing = @intCast(node.keys[at]),
                            .moved => |move| action = .{ .moved = reorder(node, move) },
                            .received => |got| {
                                target = .{ .bar = .{ .set = slot, .index = got.index } };
                                payload = got.payload;
                            },
                        }
                        switch (cx.drag_hit(self.page_id(slot), event)) {
                            .dropped => |over| {
                                if (node.page.width > 0 and node.page.height > 0) {
                                    const zone = zone_of(node.page, over.x, over.y);
                                    target = .{ .zone = .{ .set = slot, .zone = zone } };
                                    payload = over.payload;
                                }
                            },
                            .none, .drag_in, .over, .drag_out, .ended => {},
                        }
                    },
                }
            }
            for (edges) |zone| {
                switch (cx.drag_hit(self.edge_id(zone), event)) {
                    .dropped => |over| {
                        target = .{ .edge = zone };
                        payload = over.payload;
                    },
                    .none, .drag_in, .over, .drag_out, .ended => {},
                }
            }
            if (closing != null or target != null) {
                // Each `Tabs` adjusted its selection as if an app applied its action; the dock
                // applies the actions itself, from the selections before the event.
                for (&self.nodes, 0..) |*node, slot| {
                    if (node.kind == .set) node.tabs.selected = selections[slot];
                }
            }
            if (closing) |panel| {
                self.close(panel);
                cx.redraw();
                action = .{ .closed = panel };
            }
            if (target) |where| {
                if (self.move_panel(payload, where)) |panel| action = .{ .moved = panel };
                cx.redraw();
            }
            self.refresh();
            return action;
        }

        /// A tab moved within its set's bar: the set's arrays follow; returns its panel.
        fn reorder(node: *Node, move: Tabs.Move) u32 {
            assert(node.kind == .set);
            const len = node.len;
            tabs_file.move_item([]const u8, node.labels[0..len], move.from, move.to);
            tabs_file.move_item(u64, node.keys[0..len], move.from, move.to);
            node.tabs.set(node.labels[0..len], node.keys[0..len]);
            return @intCast(node.keys[move.to]);
        }

        /// Moves the panel `payload` names to `where` (section 5): its panel, or null for a
        /// no-op or a refusal.
        pub fn move_panel(self: *Self, payload: u64, where: Target) ?u32 {
            if (payload >= self.labels.len) return null;
            const panel: u32 = @intCast(payload);
            const source = self.set_of(panel);
            const alone = if (source) |set| self.nodes[set].len == 1 else false;
            switch (where) {
                .bar => |bar| {
                    if (source == bar.set) return null;
                    if (source) |set| self.remove(set, panel);
                    self.insert(bar.set, panel, bar.index);
                },
                .zone => |drop| {
                    if (source == drop.set and (drop.zone == .centre or alone)) return null;
                    if (drop.zone == .centre) {
                        if (source) |set| self.remove(set, panel);
                        self.add(drop.set, panel);
                    } else {
                        if (self.free_count() < 2) return null;
                        if (source) |set| self.remove(set, panel);
                        _ = self.split(drop.set, drop.zone, panel, dock_zone_share).?;
                    }
                },
                .edge => |zone| {
                    if (source == self.root and alone) return null;
                    if (self.free_count() < 2) return null;
                    if (source) |set| self.remove(set, panel);
                    _ = self.split_root(zone, panel, dock_edge_share).?;
                },
            }
            if (source) |set| self.collapse(set);
            return panel;
        }

        // ------------------------------------------------------------- save/load

        /// Writes the layout (section 6) into `out`; returns the bytes written.
        pub fn save(self: *const Self, out: *[dock_save_max]u8) []const u8 {
            var count: u32 = 0;
            for (self.nodes, 0..) |node, slot| {
                if (node.kind != .free) count = @intCast(slot + 1);
            }
            @memcpy(out[0..4], magic);
            out[4] = version;
            out[5] = @intCast(count);
            out[6] = self.root;
            out[7] = 0;
            var at: u32 = 8;
            for (self.nodes[0..count]) |*node| {
                out[at] = @backingInt(node.kind);
                at += 1;
                switch (node.kind) {
                    .free => {},
                    .split => {
                        out[at] = @backingInt(node.splitter.axis);
                        const ratio: u16 = @intFromFloat(@round(node.splitter.ratio * 65535));
                        std.mem.writeInt(u16, out[at + 1 ..][0..2], ratio, .little);
                        out[at + 3] = node.a;
                        out[at + 4] = node.b;
                        at += 5;
                    },
                    .set => {
                        out[at] = @intCast(node.len);
                        out[at + 1] = @intCast(node.tabs.selected);
                        for (node.keys[0..node.len], out[at + 2 ..][0..node.len]) |key, *byte| {
                            byte.* = @intCast(key);
                        }
                        at += 2 + node.len;
                    },
                }
            }
            assert(at <= dock_save_max);
            return out[0..at];
        }

        /// Replaces the layout with `bytes` when they pass every check of section 6; false,
        /// with nothing changed, otherwise.
        pub fn load(self: *Self, bytes: []const u8) bool {
            const decoded = decode(bytes, @intCast(self.labels.len)) orelse return false;
            for (&self.nodes) |*node| {
                node.kind = .free;
                node.parent = none;
                node.len = 0;
            }
            for (decoded.nodes[0..decoded.count], 0..) |entry, index| {
                const slot: u8 = @intCast(index);
                switch (entry.kind) {
                    .free => {},
                    .set => {
                        self.init_set(slot);
                        for (entry.panels[0..entry.count]) |panel| {
                            self.add(slot, panel);
                        }
                        self.nodes[slot].tabs.selected = entry.selected;
                    },
                    .split => {},
                }
            }
            for (decoded.nodes[0..decoded.count], 0..) |entry, index| {
                if (entry.kind != .split) continue;
                const slot: u8 = @intCast(index);
                const node = &self.nodes[slot];
                node.kind = .split;
                node.a = entry.a;
                node.b = entry.b;
                node.splitter = self.splitter_at(slot, entry.axis, entry.ratio);
            }
            for (decoded.nodes[0..decoded.count], 0..) |entry, index| {
                if (entry.kind != .split) continue;
                self.nodes[entry.a].parent = @intCast(index);
                self.nodes[entry.b].parent = @intCast(index);
            }
            self.root = decoded.root;
            self.nodes[self.root].parent = none;
            self.refresh();
            return true;
        }
    };
}

/// A clipped column under each set's bar.
const page_layout: ui.Layout = .{ .flow = .down, .clip = true };

/// One node of a layout being loaded.
const Entry = struct {
    kind: Kind,
    axis: splitter_file.Axis,
    ratio: f32,
    a: u8,
    b: u8,
    count: u32,
    selected: u32,
    panels: [tabs_max]u8,
};

const Decoded = struct {
    nodes: [dock_nodes_max]Entry,
    count: u32,
    root: u8,
};

/// `bytes` decoded and checked against section 6 for `panel_count` panels, or null.
fn decode(bytes: []const u8, panel_count: u32) ?Decoded {
    assert(panel_count <= dock_panels_max);
    if (bytes.len < 8 or bytes.len > dock_save_max) return null;
    if (!std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version or bytes[7] != 0) return null;
    var out: Decoded = undefined;
    out.count = bytes[5];
    out.root = bytes[6];
    if (out.count == 0 or out.count > dock_nodes_max or out.root >= out.count) return null;
    var at: usize = 8;
    for (out.nodes[0..out.count]) |*entry| {
        if (at >= bytes.len) return null;
        const kind = bytes[at];
        at += 1;
        if (kind > @backingInt(Kind.set)) return null;
        entry.kind = @fromBackingInt(kind);
        entry.count = 0;
        entry.selected = 0;
        switch (entry.kind) {
            .free => {},
            .split => {
                if (at + 5 > bytes.len or bytes[at] > 1) return null;
                entry.axis = if (bytes[at] == 0) .horizontal else .vertical;
                const ratio = std.mem.readInt(u16, bytes[at + 1 ..][0..2], .little);
                entry.ratio = @as(f32, @floatFromInt(ratio)) / 65535;
                entry.a = bytes[at + 3];
                entry.b = bytes[at + 4];
                at += 5;
            },
            .set => {
                if (at + 2 > bytes.len) return null;
                entry.count = bytes[at];
                entry.selected = bytes[at + 1];
                if (entry.count > tabs_max) return null;
                if (entry.selected >= @max(entry.count, 1)) return null;
                if (at + 2 + entry.count > bytes.len) return null;
                @memcpy(entry.panels[0..entry.count], bytes[at + 2 ..][0..entry.count]);
                at += 2 + entry.count;
            },
        }
    }
    if (at != bytes.len) return null;
    if (!shape_valid(&out, panel_count)) return null;
    return out;
}

/// The tree checks of section 6: children used, not the root, each a child once; every used
/// node reached once from the root; panels below `panel_count`, each once; only the root may
/// be an empty set.
fn shape_valid(decoded: *const Decoded, panel_count: u32) bool {
    const nodes = decoded.nodes[0..decoded.count];
    if (nodes[decoded.root].kind == .free) return false;
    var child_of: u64 = 0;
    var panels: u64 = 0;
    for (nodes, 0..) |entry, slot| {
        switch (entry.kind) {
            .free => {},
            .split => for ([2]u8{ entry.a, entry.b }) |child| {
                if (child >= nodes.len or child == decoded.root or child == slot) return false;
                if (nodes[child].kind == .free) return false;
                const bit = @as(u64, 1) << @intCast(child);
                if (child_of & bit != 0) return false;
                child_of |= bit;
            },
            .set => {
                if (entry.count == 0 and slot != decoded.root) return false;
                for (entry.panels[0..entry.count]) |panel| {
                    if (panel >= panel_count) return false;
                    const bit = @as(u64, 1) << @intCast(panel);
                    if (panels & bit != 0) return false;
                    panels |= bit;
                }
            },
        }
    }
    var seen: u64 = 0;
    var stack: [dock_nodes_max + 2]u8 = undefined;
    var depth: u32 = 1;
    stack[0] = decoded.root;
    var visits: u32 = 0;
    while (depth > 0) {
        depth -= 1;
        const slot = stack[depth];
        const bit = @as(u64, 1) << @intCast(slot);
        if (seen & bit != 0) return false;
        seen |= bit;
        visits += 1;
        if (visits > nodes.len) return false;
        const entry = nodes[slot];
        if (entry.kind != .split) continue;
        stack[depth] = entry.a;
        stack[depth + 1] = entry.b;
        depth += 2;
    }
    for (nodes, 0..) |entry, slot| {
        const used = entry.kind != .free;
        if (used != (seen & (@as(u64, 1) << @intCast(slot)) != 0)) return false;
    }
    return true;
}

/// The default dock: `DockOf(skins.Default)`.
pub const Dock = DockOf(skin.Default);

comptime {
    assert(dock_nodes_max <= 64);
    assert(dock_panels_max <= 64);
    assert(dock_save_max <= 4096);
    assert(dock_zone_fraction > 0 and dock_zone_fraction < 0.5);
}

const testing = std.testing;
const draw = @import("../draw.zig");

const test_types = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 256 },
    .{ .type = draw.Glyph, .cap = 1024 },
    .{ .type = draw.Path, .cap = 16 },
};
const TestContext = ui.Context(draw.Context(&test_types, 16, 64), 128);

const test_static = struct {
    var context: TestContext = undefined;
    var dock: Dock = undefined;
    var copy: Dock = undefined;
};

const files: u32 = 0;
const editor: u32 = 1;
const log: u32 = 2;
const appearance: u32 = 3;
const four = [_][]const u8{ "files", "editor", "log", "appearance" };

/// The workspace's default: files left (0.2), editor in the middle, log under it (0.3), and
/// appearance right of the editor (0.25). Slots: editor's set 0, files 1, split 2 (root),
/// log 3, split 4, appearance 5, split 6.
fn default_dock() *Dock {
    const dock = &test_static.dock;
    dock.init(ui.id("dock", 0), &four);
    dock.add(dock.root, editor);
    _ = dock.split(0, .left, files, 0.2).?;
    _ = dock.split(0, .bottom, log, 0.3).?;
    _ = dock.split(0, .right, appearance, 0.25).?;
    dock.verify();
    return dock;
}

fn fresh_context() *TestContext {
    test_static.context.init();
    return &test_static.context;
}

/// Draws `dock` in a 1000 x 600 box at (0, 0) and writes the panels it gave, in order.
fn draw_dock(cx: *TestContext, dock: *Dock, out: []Panel) []Panel {
    cx.begin_frame(1280, 720, 120);
    dock.begin(cx, .{ .width = .{ .fixed = 1000 }, .height = .{ .fixed = 600 } });
    var count: usize = 0;
    while (dock.next(cx)) |panel| {
        out[count] = panel;
        count += 1;
    }
    dock.end(cx);
    _ = cx.end_frame();
    return out[0..count];
}

fn send(cx: *TestContext, dock: *Dock, event: input.Event) Dock.Action {
    cx.event_begin(event);
    const action = dock.handle(cx, event);
    cx.event_end();
    return action;
}

fn centre_of(cx: *TestContext, id: Id) input.Point {
    const rect = cx.find(id).?.rect;
    return .{ .x = rect[0] + rect[2] * 0.5, .y = rect[1] + rect[3] * 0.5 };
}

// Locks the tree operations (section 2): the default layout's slots, axes, pane order, and
// ratios (the new pane takes its share); closing log collapses its set and split, so the
// right-hand split takes their place; `show` puts log back in the first set, selected; closing
// files makes the root's other child the root.
test "splits put new sets where the zone says and empty sets collapse" {
    const dock = default_dock();
    try testing.expectEqual(@as(u8, 2), dock.root);
    const root = dock.nodes[2];
    try testing.expectEqual(splitter_file.Axis.horizontal, root.splitter.axis);
    try testing.expectEqual([2]u8{ 1, 4 }, [2]u8{ root.a, root.b });
    try testing.expectEqual(@as(f32, 0.2), root.splitter.ratio);
    const below = dock.nodes[4];
    try testing.expectEqual(splitter_file.Axis.vertical, below.splitter.axis);
    try testing.expectEqual([2]u8{ 6, 3 }, [2]u8{ below.a, below.b });
    try testing.expectApproxEqAbs(@as(f32, 0.7), below.splitter.ratio, 1e-6);
    const right = dock.nodes[6];
    try testing.expectEqual([2]u8{ 0, 5 }, [2]u8{ right.a, right.b });
    try testing.expectEqual(@as(f32, 0.75), right.splitter.ratio);
    try testing.expectEqual(@as(?u8, 3), dock.set_of(log));
    dock.close(log);
    dock.verify();
    try testing.expectEqual(Kind.free, dock.nodes[3].kind);
    try testing.expectEqual(Kind.free, dock.nodes[4].kind);
    try testing.expectEqual(@as(u8, 6), dock.nodes[2].b);
    dock.show(log);
    try testing.expectEqual(@as(?u8, 0), dock.set_of(log));
    try testing.expectEqual(@as(u32, 1), dock.nodes[0].tabs.selected);
    dock.close(files);
    dock.verify();
    try testing.expectEqual(@as(u8, 6), dock.root);
    try testing.expectEqual(@as(u32, 4), dock.panels_docked() + 1);
}

// Locks drawing (section 3) in a 1000 x 600 dock: panels come in tree order (files, editor,
// appearance, log), each page under its 32 px bar: files 199 wide (0.2 of 994), the rest 795
// from x 205, split 416 / 178 down (0.7 of 594), the editor 592 and appearance 197 across
// (0.75 of 789). Every page is a drag target; an empty root set gives no panel.
test "the dock draws its panels in tree order with their pages" {
    const cx = fresh_context();
    const dock = default_dock();
    var storage: [8]Panel = undefined;
    const panels = draw_dock(cx, dock, &storage);
    try testing.expectEqual(@as(usize, 4), panels.len);
    const ids = [4]u32{ files, editor, appearance, log };
    const rects = [4]Rect{
        .{ .x = 0, .y = 32, .width = 199, .height = 568 },
        .{ .x = 205, .y = 32, .width = 592, .height = 384 },
        .{ .x = 803, .y = 32, .width = 197, .height = 384 },
        .{ .x = 205, .y = 454, .width = 795, .height = 146 },
    };
    for (panels, ids, rects) |panel, id, rect| {
        try testing.expectEqual(id, panel.id);
        try testing.expectEqual(rect, panel.rect);
    }
    try testing.expect(cx.find(dock.page_id(0)).?.flags.drag_target);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try testing.expectEqual(@as(u32, 0), cx.area_overflow);
    const empty = &test_static.copy;
    empty.init(ui.id("empty", 0), &four);
    try testing.expectEqual(@as(usize, 0), draw_dock(cx, empty, &storage).len);
}

// Locks the zones (section 4) of a 100 x 100 page: the nearest side under a quarter wins,
// a corner goes to the nearer side, exactly a quarter is the centre; the overlay is that half.
test "a point's zone is the nearest side under a quarter" {
    const page: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try testing.expectEqual(Zone.left, zone_of(page, 10, 50));
    try testing.expectEqual(Zone.right, zone_of(page, 90, 50));
    try testing.expectEqual(Zone.top, zone_of(page, 50, 10));
    try testing.expectEqual(Zone.bottom, zone_of(page, 50, 90));
    try testing.expectEqual(Zone.centre, zone_of(page, 50, 50));
    try testing.expectEqual(Zone.centre, zone_of(page, 25, 50));
    try testing.expectEqual(Zone.top, zone_of(page, 10, 5));
    const right: Rect = .{ .x = 50, .y = 0, .width = 50, .height = 100 };
    try testing.expectEqual(right, zone_rect(page, .right));
    const bottom: Rect = .{ .x = 0, .y = 50, .width = 100, .height = 50 };
    try testing.expectEqual(bottom, zone_rect(page, .bottom));
    try testing.expectEqual(page, zone_rect(page, .centre));
}

// Locks moving a panel (section 5) from the default layout: log into the editor's centre
// joins its set and collapses its own; appearance onto each side of the editor's set makes a
// split with the editor on the far side; a centre drop on its own set and a side drop of a
// lone panel on its own set do nothing; an edge drop splits the root with the new pane a
// quarter; a bar drop inserts at the index and selects.
test "a dropped panel joins, splits, or moves to the edge" {
    var dock = default_dock();
    const centre: Dock.Target = .{ .zone = .{ .set = 0, .zone = .centre } };
    try testing.expectEqual(@as(?u32, log), dock.move_panel(log, centre));
    dock.verify();
    try testing.expectEqual(@as(?u8, 0), dock.set_of(log));
    try testing.expectEqual(@as(u32, 1), dock.nodes[0].tabs.selected);
    const sides = [4]Zone{ .left, .right, .top, .bottom };
    for (sides) |side| {
        dock = default_dock();
        const moved = dock.move_panel(appearance, .{ .zone = .{ .set = 0, .zone = side } });
        try testing.expectEqual(@as(?u32, appearance), moved);
        dock.verify();
        const set = dock.set_of(appearance).?;
        const joint = dock.nodes[dock.nodes[set].parent];
        const first = side == .left or side == .top;
        try testing.expectEqual(if (first) set else 0, joint.a);
        try testing.expectEqual(if (first) 0 else set, joint.b);
        const across = side == .left or side == .right;
        const axis: splitter_file.Axis = if (across) .horizontal else .vertical;
        try testing.expectEqual(axis, joint.splitter.axis);
        try testing.expectEqual(@as(f32, 0.5), joint.splitter.ratio);
    }
    dock = default_dock();
    try testing.expectEqual(@as(?u32, null), dock.move_panel(editor, centre));
    const lone: Dock.Target = .{ .zone = .{ .set = 1, .zone = .left } };
    try testing.expectEqual(@as(?u32, null), dock.move_panel(files, lone));
    try testing.expectEqual(@as(?u32, null), dock.move_panel(99, .{ .edge = .left }));
    try testing.expectEqual(@as(?u32, files), dock.move_panel(files, .{ .edge = .right }));
    dock.verify();
    const root = dock.nodes[dock.root];
    try testing.expectEqual(dock.set_of(files).?, root.b);
    try testing.expectEqual(@as(f32, 0.75), root.splitter.ratio);
    dock = default_dock();
    const bar: Dock.Target = .{ .bar = .{ .set = 1, .index = 0 } };
    try testing.expectEqual(@as(?u32, log), dock.move_panel(log, bar));
    dock.verify();
    try testing.expectEqual(@as(u64, log), dock.nodes[1].keys[0]);
    try testing.expectEqual(@as(u32, 0), dock.nodes[1].tabs.selected);
}

const thirty_two = blk: {
    @setEvalBranchQuota(100_000);
    var names: [dock_panels_max][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = std.fmt.comptimePrint("p{d}", .{index});
    break :blk names;
};

// Locks refusal (section 5): 32 panels in 32 sets fill 63 nodes, so one is free and a side
// or edge drop is refused with the layout unchanged, while a centre drop still works.
test "a full dock refuses a split and keeps the tab" {
    const dock = &test_static.dock;
    dock.init(ui.id("dock", 0), &thirty_two);
    dock.add(dock.root, 0);
    var panel: u32 = 1;
    while (panel < dock_panels_max) : (panel += 1) {
        _ = dock.split(dock.set_of(panel - 1).?, .right, panel, 0.5).?;
    }
    dock.verify();
    try testing.expectEqual(@as(u32, 1), dock.free_count());
    try testing.expectEqual(@as(?u8, null), dock.split(0, .left, 5, 0.5));
    const before = dock.set_of(31).?;
    const side: Dock.Target = .{ .zone = .{ .set = 0, .zone = .left } };
    try testing.expectEqual(@as(?u32, null), dock.move_panel(31, side));
    try testing.expectEqual(@as(?u32, null), dock.move_panel(31, .{ .edge = .top }));
    try testing.expectEqual(@as(?u8, before), dock.set_of(31));
    dock.verify();
    const centre: Dock.Target = .{ .zone = .{ .set = 0, .zone = .centre } };
    try testing.expectEqual(@as(?u32, 31), dock.move_panel(31, centre));
    dock.verify();
    try testing.expectEqual(@as(u32, 3), dock.free_count());
}

// Locks a drop by events (section 5): log's tab pressed, dragged off its bar, and released
// over the right zone of the editor's page splits the editor's set; the source bar's
// `dragged_out` is ignored and the move reported once; the overlay showed the zone's half on
// the popup layer while in flight, and the edge strips were targets.
test "dragging a tab onto a page's side splits it" {
    const cx = fresh_context();
    const dock = default_dock();
    var storage: [8]Panel = undefined;
    _ = draw_dock(cx, dock, &storage);
    const tab = centre_of(cx, dock.tab_id(log).?);
    _ = send(cx, dock, .{ .pointer_down = input.left_at(tab) });
    _ = send(cx, dock, .{ .pointer_move = .{ .x = tab.x, .y = 300 } });
    try testing.expect(cx.dragging() != null);
    const right_zone: input.Point = .{ .x = 780, .y = 200 };
    _ = send(cx, dock, .{ .pointer_move = right_zone });
    try testing.expect(cx.drag_hovering(dock.page_id(0)));
    _ = draw_dock(cx, dock, &storage);
    try testing.expect(cx.find(dock.edge_id(.left)) != null);
    var overlay = false;
    for (cx.draw.items(draw.Box), 0..) |box, index| {
        if (cx.draw.layer_at(draw.Box, @intCast(index)) != .popup) continue;
        try testing.expectEqualSlices(f32, &.{ 501, 32, 296, 384 }, &box.rect);
        overlay = true;
    }
    try testing.expect(overlay);
    const action = send(cx, dock, .{ .pointer_up = input.left_at(right_zone) });
    try testing.expectEqual(Dock.Action{ .moved = log }, action);
    dock.verify();
    const set = dock.set_of(log).?;
    try testing.expectEqual(set, dock.nodes[dock.nodes[set].parent].b);
    try testing.expectEqual(Kind.free, dock.nodes[3].kind);
    _ = draw_dock(cx, dock, &storage);
    try testing.expectEqual(@as(?ui.Dragging, null), cx.dragging());
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks save and load (section 6): a round trip restores the tree, the ratios (to 1/65535),
// and the selections; each broken rule refuses the bytes with the layout unchanged.
test "save and load round-trip and refuse a bad layout" {
    const dock = default_dock();
    dock.nodes[2].splitter.ratio = 0.3;
    dock.nodes[0].tabs.selected = 0;
    var buffer: [dock_save_max]u8 = undefined;
    const saved = dock.save(&buffer);
    var bytes: [dock_save_max]u8 = undefined;
    @memcpy(bytes[0..saved.len], saved);
    const good = bytes[0..saved.len];
    dock.close(log);
    dock.close(files);
    try testing.expect(dock.load(good));
    dock.verify();
    try testing.expectEqual(@as(u8, 2), dock.root);
    try testing.expectApproxEqAbs(@as(f32, 0.3), dock.nodes[2].splitter.ratio, 1.0 / 65535.0);
    try testing.expectEqual(@as(?u8, 3), dock.set_of(log));
    var again: [dock_save_max]u8 = undefined;
    try testing.expectEqualSlices(u8, good, dock.save(&again));
    const Breaker = struct { at: usize, value: u8 };
    // magic, version, root out of range, a split's child the root, a split's child itself,
    // a set's count past its bytes, a panel past the labels, a selected past the count.
    const breaks = [_]Breaker{
        .{ .at = 0, .value = 'X' },
        .{ .at = 4, .value = 2 },
        .{ .at = 6, .value = 40 },
    };
    for (breaks) |broken| {
        var bad = bytes;
        bad[broken.at] = broken.value;
        try testing.expect(!dock.load(bad[0..saved.len]));
    }
    try testing.expect(!dock.load(good[0 .. good.len - 1]));
    // Slot 0 is the editor's set: kind, count, selected, panel.
    try testing.expectEqual(@as(u8, 2), good[8]);
    var dup = bytes;
    dup[11] = files;
    try testing.expect(!dock.load(dup[0..saved.len]));
    var past = bytes;
    past[11] = 9;
    try testing.expect(!dock.load(past[0..saved.len]));
    var selected = bytes;
    selected[10] = 1;
    try testing.expect(!dock.load(selected[0..saved.len]));
    // Slot 2 (the root split) follows slots 0 and 1 (4 bytes each): kind, axis, ratio, a, b.
    const root_at = 8 + 4 + 4;
    try testing.expectEqual(@as(u8, 1), good[root_at]);
    var cycle = bytes;
    cycle[root_at + 4] = 2;
    try testing.expect(!dock.load(cycle[0..saved.len]));
    var orphan = bytes;
    orphan[root_at + 5] = 1;
    try testing.expect(!dock.load(orphan[0..saved.len]));
    dock.verify();
    try testing.expectEqualSlices(u8, good, dock.save(&again));
}

// Locks copying (section 1): a `Dock` copied by value draws the same panels at the same
// rects, since drawing re-points each set's tabs at its own arrays.
test "a copied dock draws like the original" {
    const cx = fresh_context();
    const dock = default_dock();
    var first: [8]Panel = undefined;
    const original = draw_dock(cx, dock, &first);
    test_static.copy = dock.*;
    var second: [8]Panel = undefined;
    const copied = draw_dock(cx, &test_static.copy, &second);
    try testing.expectEqualSlices(Panel, original, copied);
    const copy = &test_static.copy;
    try testing.expect(copy.nodes[0].tabs.labels.ptr == &copy.nodes[0].labels);
}

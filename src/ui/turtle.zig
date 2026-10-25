//! Pure turtle math: where one child goes in its parent, how a fit container resolves its
//! size, and the alignment deltas `ui/cx.zig` applies after the fact.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Pure
//! Layout runs while drawing (`ui/cx.zig`): a container `begin`s, its children walk, and it
//! `end`s. The arithmetic of one step, placing a child or closing a container, does not need
//! pools, areas, or widgets, so it lives here over a plain `Turtle` value and is tested with
//! plain numbers. `cx.zig` owns the stack of turtles and the side effects (shifting
//! instances, clips, hit areas).
//!
//! ## 2. Coordinate Space and Box Model
//! All values are UI logical pixels: origin top-left, `+X` right, `+Y` down.
//! ```text
//! Margin Box = the space a child consumes; the parent's cursor advances past it.
//! Border Box = the `Rect` a walk returns: the margin box inset by the child's margins.
//! Inner Rect = a container's border box inset by its `Layout.padding`.
//! ```
//!
//! ## 3. Flows and Axes
//! `Flow.right` lays children along X (the main axis) and `Flow.down` along Y. Spacing is
//! added before every child but the first. `Flow.overlay` has no main axis: every child
//! starts at the inner origin, and both axes are cross axes.
//!
//! ## 4. Sizes
//! - `fixed`: an explicit span.
//! - `fill` on the main axis: what remains at placement time,
//!   `max(0, inner_end - cursor - margin_start - margin_end)`. A second fill in the same
//!   flow therefore gets 0; `share` divides space evenly. Test: "a second fill gets zero".
//! - `share(n)` on the main axis: `max(0, (inner - (n - 1) * spacing) / n) - margins`, so
//!   `n` siblings of `share(n)` with no margins tile the inner span exactly.
//! - Cross-axis `fill`: `max(0, inner - margins)`. Cross-axis `share(n)`: `inner / n -
//!   margins`.
//! - `fit`: only for containers. The span is provisional (0) while the children walk and is
//!   resolved by `close`: `extent - rect_start + padding_end`, where `extent` is the farthest
//!   margin-box edge any child reached. A fit axis may not hold `fill` or `share` children,
//!   and its own alignment on that axis must be 0 (both asserted), because neither has a
//!   span to divide until the children are done.
//! Every resolved span is clamped to at least 0; a widget skips a box with a zero edge.
//!
//! ## 5. Placement Algebra (`place`)
//! ```text
//! main axis:  cursor += spacing (if not the first child)
//!             pos = cursor + margin_start             len = main span (section 4)
//! cross axis: avail = inner_len - margin_start - margin_end
//!             len = cross span (section 4)
//!             pos = inner_start + margin_start + align * max(0, avail - len)
//!             (a fit child takes no alignment here; see section 6)
//! ```
//! `advance` then moves the main cursor to the far edge of the margin box and widens the
//! extent on both axes. `ui/cx.zig` places a leaf with `place` plus `advance`; a container is
//! placed by `place` at `begin` and advanced at `end`, once its size is known.
//!
//! ## 6. Alignment After the Fact
//! A fixed, fill, or share child is aligned on the cross axis when it is placed. Two cases
//! need sizes known only at `end`, and each yields one delta for a contiguous range:
//! - `main_shift`: a container with main-axis alignment moves all of its children by
//!   `align * max(0, inner_end - cursor)` (skipped on a fit main axis, whose slack is 0).
//! - `self_shift`: a fit child aligned on a cross axis of its parent moves itself by
//!   `align * max(0, avail - len)` once `close` resolved it.
//!
//! ## 7. TigerStyle Invariants
//! - Every function is O(1); there are no child arrays, so no child cap. Nesting depth is
//!   bounded by `depth_max` in `ui/cx.zig`.
//! - Spacing, padding, margins, and fixed spans are non-negative and finite, alignment is in
//!   `[0, 1]`, and `share(n)` has `n >= 1`; each is asserted independently.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");

pub const Rect = draw.Rect;
pub const Inset = draw.Inset;

/// Turtles one frame may nest, the root included.
pub const depth_max: u32 = 32;

/// How a container lays out its children. See the module guide, section 3.
pub const Flow = enum(u8) {
    right,
    down,
    overlay,
};

/// Where children sit in leftover space, per axis, from 0 (start) to 1 (end).
pub const Align = struct {
    x: f32,
    y: f32,
};

/// How one axis of a walk is sized. See the module guide, section 4.
pub const Size = union(enum) {
    fixed: f32,
    fill,
    fit,
    share: u8,
};

/// One child's request: its two spans and its margins, none by default.
pub const Walk = struct {
    width: Size,
    height: Size,
    margin: Inset = zero_inset,
};

/// How a container places its children. `clip` intersects the clip of everything inside with
/// the container's border box (`ui/cx.zig`), so it needs a non-fit size on both axes. Only
/// `flow` is required: by default there is no spacing, padding, alignment, or clip, so a
/// container opens in one statement, `.{ .flow = .down, .spacing = 8, .padding = .all(12) }`.
pub const Layout = struct {
    flow: Flow,
    spacing: f32 = 0,
    padding: Inset = zero_inset,
    alignment: Align = .{ .x = 0, .y = 0 },
    clip: bool = false,
};

/// One open container. `rect` is its border box; a fit axis holds 0 until `close`.
/// `cursor` is the next child's margin-box start on the main axis (both entries start at the
/// inner origin), `extent` the farthest margin-box edge reached, and `count` the children
/// placed so far.
pub const Turtle = struct {
    rect: Rect,
    walk: Walk,
    layout: Layout,
    cursor: [2]f32,
    extent: [2]f32,
    count: u32,
};

pub const zero_inset: Inset = .all(0);

comptime {
    assert(depth_max == 32);
    assert(@sizeOf(Size) == 8);
    assert(@sizeOf(Walk) == 32);
    assert(@sizeOf(Align) == 8);
}

/// A container over `rect` whose own walk is `walk`. A fit axis of `walk` must have a zero
/// span in `rect` and zero alignment in `layout` (module guide, section 4).
pub fn open(rect: Rect, walk: Walk, layout: Layout) Turtle {
    assert_layout(layout);
    assert_walk(walk);
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        if (size_of(walk, axis) == .fit) {
            assert(length_of(rect, axis) == 0);
            assert(align_of(layout.alignment, axis) == 0);
        }
    }
    const turtle: Turtle = .{
        .rect = rect,
        .walk = walk,
        .layout = layout,
        .cursor = .{ rect.x + layout.padding.left, rect.y + layout.padding.top },
        .extent = .{ rect.x + layout.padding.left, rect.y + layout.padding.top },
        .count = 0,
    };
    assert(turtle.count == 0);
    assert(turtle.cursor[0] == turtle.extent[0]);
    return turtle;
}

/// A turtle whose walk is the fixed size of `rect`, for the root of a frame and for tests.
pub fn root(rect: Rect, layout: Layout) Turtle {
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    const walk: Walk = .{
        .width = .{ .fixed = rect.width },
        .height = .{ .fixed = rect.height },
        .margin = zero_inset,
    };
    return open(rect, walk, layout);
}

/// The border box of the next child of `turtle` for `walk` (module guide, section 5). Adds
/// the spacing and counts the child; the caller advances with `advance` once the size is
/// final.
pub fn place(turtle: *Turtle, walk: Walk) Rect {
    assert_walk(walk);
    const main = main_axis(turtle.layout.flow);
    if (main) |axis| {
        if (turtle.count > 0) turtle.cursor[axis] += turtle.layout.spacing;
    }
    turtle.count += 1;
    var pos: [2]f32 = undefined;
    var len: [2]f32 = undefined;
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        const spec = size_of(walk, axis);
        if (size_of(turtle.walk, axis) == .fit) {
            assert(spec != .fill);
            assert(spec != .share);
        }
        if (main == axis) {
            pos[axis] = turtle.cursor[axis] + margin_start(walk.margin, axis);
            len[axis] = main_span(turtle, walk, axis, pos[axis]);
        } else {
            const placed = cross_place(turtle, walk, axis);
            pos[axis] = placed[0];
            len[axis] = placed[1];
        }
        assert(len[axis] >= 0);
    }
    assert(turtle.count >= 1);
    return .{ .x = pos[0], .y = pos[1], .width = len[0], .height = len[1] };
}

/// Moves the main cursor past `rect`'s margin box and widens the extent on both axes.
pub fn advance(turtle: *Turtle, walk: Walk, rect: Rect) void {
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    const main = main_axis(turtle.layout.flow);
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        const far = start_of(rect, axis) + length_of(rect, axis) + margin_end(walk.margin, axis);
        if (main == axis) turtle.cursor[axis] = far;
        turtle.extent[axis] = @max(turtle.extent[axis], far);
    }
    assert(axis == 2);
}

/// Advances the main cursor by `span` without placing a child, so a list can stand in for
/// rows it does not draw. Requires a main axis.
pub fn skip(turtle: *Turtle, span: f32) void {
    assert(span >= 0);
    const axis = main_axis(turtle.layout.flow).?;
    turtle.cursor[axis] += span;
    turtle.extent[axis] = @max(turtle.extent[axis], turtle.cursor[axis]);
    assert(turtle.extent[axis] >= turtle.cursor[axis]);
}

/// The border box with every fit axis resolved from the children's extent.
pub fn close(turtle: *const Turtle) Rect {
    var rect = turtle.rect;
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        if (size_of(turtle.walk, axis) == .fit) {
            const span = turtle.extent[axis] - start_of(rect, axis) +
                margin_end(turtle.layout.padding, axis);
            set_length(&rect, axis, @max(0, span));
        }
    }
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    return rect;
}

/// The delta that main-axis alignment applies to every child of `turtle` at its end.
pub fn main_shift(turtle: *const Turtle) [2]f32 {
    var delta: [2]f32 = .{ 0, 0 };
    const axis = main_axis(turtle.layout.flow) orelse return delta;
    if (size_of(turtle.walk, axis) == .fit) return delta;
    const amount = align_of(turtle.layout.alignment, axis);
    if (amount == 0) return delta;
    const inner = inner_rect(turtle);
    const slack = start_of(inner, axis) + length_of(inner, axis) - turtle.cursor[axis];
    delta[axis] = amount * @max(0, slack);
    assert(delta[axis] >= 0);
    return delta;
}

/// The delta that moves a fit child, closed to `rect`, to its alignment on the cross axes of
/// `parent`. Zero on every axis the child does not fit.
pub fn self_shift(parent: *const Turtle, walk: Walk, rect: Rect) [2]f32 {
    var delta: [2]f32 = .{ 0, 0 };
    const main = main_axis(parent.layout.flow);
    const inner = inner_rect(parent);
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        if (main == axis) continue;
        if (size_of(walk, axis) != .fit) continue;
        const avail = length_of(inner, axis) - margin_start(walk.margin, axis) -
            margin_end(walk.margin, axis);
        const slack = @max(0, avail - length_of(rect, axis));
        delta[axis] = align_of(parent.layout.alignment, axis) * slack;
    }
    assert(delta[0] >= 0);
    assert(delta[1] >= 0);
    return delta;
}

/// The border box `place` would return for `walk`, without placing anything.
pub fn peek(turtle: *const Turtle, walk: Walk) Rect {
    var probe = turtle.*;
    const rect = place(&probe, walk);
    assert(probe.count == turtle.count + 1);
    return rect;
}

/// True when the next child for `walk` would have positive edges and lie inside the inner
/// rect on both axes. Places nothing.
pub fn fits(turtle: *const Turtle, walk: Walk) bool {
    const rect = peek(turtle, walk);
    const inner = inner_rect(turtle);
    var axis: u32 = 0;
    while (axis < 2) : (axis += 1) {
        if (!(length_of(inner, axis) > 0)) return false;
        if (!(length_of(rect, axis) > 0)) return false;
        if (start_of(rect, axis) < start_of(inner, axis)) return false;
        const far = start_of(rect, axis) + length_of(rect, axis);
        if (far > start_of(inner, axis) + length_of(inner, axis)) return false;
    }
    assert(axis == 2);
    return true;
}

/// The part of the inner rect the next child could use: from the cursor (after spacing) to
/// the inner end on the main axis, the whole inner span on a cross axis. Edges clamp to 0.
pub fn remaining(turtle: *const Turtle) Rect {
    var rect = inner_rect(turtle);
    if (main_axis(turtle.layout.flow)) |axis| {
        var start = turtle.cursor[axis];
        if (turtle.count > 0) start += turtle.layout.spacing;
        const end = start_of(rect, axis) + length_of(rect, axis);
        set_start(&rect, axis, start);
        set_length(&rect, axis, end - start);
    }
    rect.width = @max(0, rect.width);
    rect.height = @max(0, rect.height);
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    return rect;
}

/// The border box inset by the padding. Spans may be negative when the padding does not fit.
pub fn inner_rect(turtle: *const Turtle) Rect {
    const pad = turtle.layout.padding;
    const rect: Rect = .{
        .x = turtle.rect.x + pad.left,
        .y = turtle.rect.y + pad.top,
        .width = turtle.rect.width - pad.left - pad.right,
        .height = turtle.rect.height - pad.top - pad.bottom,
    };
    assert(rect.x == turtle.rect.x + pad.left);
    assert(rect.y == turtle.rect.y + pad.top);
    return rect;
}

/// The main axis of `flow`: 0 for X, 1 for Y, null for an overlay.
pub fn main_axis(flow: Flow) ?u32 {
    switch (flow) {
        .right => return 0,
        .down => return 1,
        .overlay => return null,
    }
}

fn main_span(turtle: *const Turtle, walk: Walk, axis: u32, pos: f32) f32 {
    const inner = inner_rect(turtle);
    const margins = margin_start(walk.margin, axis) + margin_end(walk.margin, axis);
    switch (size_of(walk, axis)) {
        .fixed => |value| return value,
        .fit => return 0,
        .fill => {
            const end = start_of(inner, axis) + length_of(inner, axis);
            return @max(0, end - pos - margin_end(walk.margin, axis));
        },
        .share => |parts| {
            assert(parts >= 1);
            const count: f32 = @floatFromInt(parts);
            const gaps = (count - 1) * turtle.layout.spacing;
            const span = @max(0, (length_of(inner, axis) - gaps) / count);
            return @max(0, span - margins);
        },
    }
}

/// The start and span of a child on a cross axis of `turtle`.
fn cross_place(turtle: *const Turtle, walk: Walk, axis: u32) [2]f32 {
    const inner = inner_rect(turtle);
    const lead = margin_start(walk.margin, axis);
    const avail = length_of(inner, axis) - lead - margin_end(walk.margin, axis);
    const spec = size_of(walk, axis);
    const span: f32 = switch (spec) {
        .fixed => |value| value,
        .fit => 0,
        .fill => @max(0, avail),
        .share => |parts| blk: {
            assert(parts >= 1);
            const count: f32 = @floatFromInt(parts);
            break :blk @max(0, length_of(inner, axis) / count - (avail_margins(walk, axis)));
        },
    };
    var slack = @max(0, avail - span);
    if (spec == .fit) slack = 0;
    const pos = start_of(inner, axis) + lead + align_of(turtle.layout.alignment, axis) * slack;
    assert(span >= 0);
    assert(slack >= 0);
    return .{ pos, span };
}

fn avail_margins(walk: Walk, axis: u32) f32 {
    return margin_start(walk.margin, axis) + margin_end(walk.margin, axis);
}

fn assert_inset(inset: Inset) void {
    assert(inset.left >= 0);
    assert(inset.top >= 0);
    assert(inset.right >= 0);
    assert(inset.bottom >= 0);
}

fn assert_size(size: Size) void {
    switch (size) {
        .fixed => |value| {
            assert(value >= 0);
            assert(value == value);
        },
        .share => |parts| assert(parts >= 1),
        .fill, .fit => {},
    }
}

fn assert_walk(walk: Walk) void {
    assert_inset(walk.margin);
    assert_size(walk.width);
    assert_size(walk.height);
}

fn assert_layout(layout: Layout) void {
    assert_inset(layout.padding);
    assert(layout.spacing >= 0);
    assert(layout.alignment.x >= 0);
    assert(layout.alignment.x <= 1);
    assert(layout.alignment.y >= 0);
    assert(layout.alignment.y <= 1);
}

fn size_of(walk: Walk, axis: u32) Size {
    assert(axis < 2);
    return if (axis == 0) walk.width else walk.height;
}

fn margin_start(inset: Inset, axis: u32) f32 {
    assert(axis < 2);
    return if (axis == 0) inset.left else inset.top;
}

fn margin_end(inset: Inset, axis: u32) f32 {
    assert(axis < 2);
    return if (axis == 0) inset.right else inset.bottom;
}

fn align_of(alignment: Align, axis: u32) f32 {
    assert(axis < 2);
    return if (axis == 0) alignment.x else alignment.y;
}

fn start_of(rect: Rect, axis: u32) f32 {
    assert(axis < 2);
    return if (axis == 0) rect.x else rect.y;
}

fn length_of(rect: Rect, axis: u32) f32 {
    assert(axis < 2);
    return if (axis == 0) rect.width else rect.height;
}

fn set_start(rect: *Rect, axis: u32, value: f32) void {
    assert(axis < 2);
    if (axis == 0) rect.x = value else rect.y = value;
}

fn set_length(rect: *Rect, axis: u32, value: f32) void {
    assert(axis < 2);
    if (axis == 0) rect.width = value else rect.height = value;
}

const testing = std.testing;

const flat: Layout = .{
    .flow = .down,
    .spacing = 0,
    .padding = zero_inset,
    .alignment = .{ .x = 0, .y = 0 },
    .clip = false,
};

fn sized(width: Size, height: Size) Walk {
    return .{ .width = width, .height = height, .margin = zero_inset };
}

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try testing.expectEqual(x, rect.x);
    try testing.expectEqual(y, rect.y);
    try testing.expectEqual(width, rect.width);
    try testing.expectEqual(height, rect.height);
}

/// Places and advances one leaf, the way `cx.walk` does.
fn walk_leaf(turtle: *Turtle, walk: Walk) Rect {
    const rect = place(turtle, walk);
    advance(turtle, walk, rect);
    return rect;
}

// Locks the column algebra: padding insets the first child, spacing separates children, a
// cross fill takes the inner width minus margins, and cross alignment centers a fixed width.
test "a column places fixed children with padding, spacing, and alignment" {
    var layout = flat;
    layout.padding = .{ .left = 8, .top = 10, .right = 8, .bottom = 10 };
    layout.spacing = 4;
    layout.alignment.x = 0.5;
    var column = root(.{ .x = 0, .y = 0, .width = 200, .height = 300 }, layout);
    // Inner rect: x 8, y 10, width 184. Centered 100 wide: 8 + (184 - 100) / 2 = 50.
    const narrow = sized(.{ .fixed = 100 }, .{ .fixed = 20 });
    try expect_rect(walk_leaf(&column, narrow), 50, 10, 100, 20);
    var walk = sized(.fill, .{ .fixed = 30 });
    walk.margin.left = 4;
    try expect_rect(walk_leaf(&column, walk), 12, 34, 180, 30);
    try testing.expectEqual(@as(f32, 64), column.cursor[1]);
}

// Locks the row algebra: margins advance the cursor outside the border box, and a fixed
// height sits at the top of a taller row unless the row aligns it.
test "a row packs fixed cells from the left" {
    var layout = flat;
    layout.flow = .right;
    var row = root(.{ .x = 10, .y = 20, .width = 640, .height = 72 }, layout);
    var cell = sized(.{ .fixed = 144 }, .{ .fixed = 50 });
    cell.margin.left = 8;
    try expect_rect(walk_leaf(&row, cell), 18, 20, 144, 50);
    try expect_rect(walk_leaf(&row, cell), 170, 20, 144, 50);
    row.layout.alignment.y = 1;
    try expect_rect(walk_leaf(&row, cell), 322, 42, 144, 50);
}

// Locks the overlay flow: every child starts at the inner origin, the cursor does not move,
// and alignment applies on both axes.
test "an overlay stacks children at the inner origin" {
    var layout = flat;
    layout.flow = .overlay;
    layout.padding = .{ .left = 5, .top = 5, .right = 5, .bottom = 5 };
    var stack = root(.{ .x = 0, .y = 0, .width = 110, .height = 60 }, layout);
    try expect_rect(walk_leaf(&stack, sized(.fill, .fill)), 5, 5, 100, 50);
    stack.layout.alignment = .{ .x = 1, .y = 0.5 };
    try expect_rect(walk_leaf(&stack, sized(.{ .fixed = 20 }, .{ .fixed = 10 })), 85, 25, 20, 10);
    try testing.expectEqual(@as(f32, 5), stack.cursor[0]);
}

// Locks `share(3)`: three panels with spacing 8 tile 628 px exactly at 204 each (the rack).
test "share three gives equal panels" {
    var layout = flat;
    layout.spacing = 8;
    var column = root(.{ .x = 16, .y = 76, .width = 1248, .height = 628 }, layout);
    const panel = sized(.fill, .{ .share = 3 });
    try expect_rect(walk_leaf(&column, panel), 16, 76, 1248, 204);
    try expect_rect(walk_leaf(&column, panel), 16, 288, 1248, 204);
    try expect_rect(walk_leaf(&column, panel), 16, 500, 1248, 204);
    try testing.expectEqual(@as(f32, 704), column.cursor[1]);
}

// Locks the main-axis fill rule: the first fill takes everything that remains at placement,
// so a second fill gets zero, and an overfull flow clamps to zero rather than going negative.
test "a second fill gets zero" {
    var column = root(.{ .x = 0, .y = 0, .width = 100, .height = 200 }, flat);
    _ = walk_leaf(&column, sized(.fill, .{ .fixed = 50 }));
    try expect_rect(walk_leaf(&column, sized(.fill, .fill)), 0, 50, 100, 150);
    try expect_rect(walk_leaf(&column, sized(.fill, .fill)), 0, 200, 100, 0);
    try expect_rect(remaining(&column), 0, 200, 100, 0);
}

// Locks fit: a fit container measures its children plus padding on both axes, and a fit child
// in a centered column moves by `self_shift` once its width is known.
test "a fit container measures its children" {
    var layout = flat;
    layout.alignment.x = 0.5;
    var column = root(.{ .x = 0, .y = 0, .width = 300, .height = 300 }, layout);
    const walk = sized(.fit, .fit);
    const provisional = place(&column, walk);
    try expect_rect(provisional, 0, 0, 0, 0);
    var inner_layout = flat;
    inner_layout.flow = .right;
    inner_layout.padding = .{ .left = 4, .top = 2, .right = 6, .bottom = 3 };
    var row = open(provisional, walk, inner_layout);
    _ = walk_leaf(&row, sized(.{ .fixed = 40 }, .{ .fixed = 10 }));
    _ = walk_leaf(&row, sized(.{ .fixed = 50 }, .{ .fixed = 20 }));
    const closed = close(&row);
    try expect_rect(closed, 0, 0, 100, 25);
    // Centered: (300 - 100) / 2 on X; the column's main axis takes no self shift.
    const delta = self_shift(&column, walk, closed);
    try testing.expectEqual(@as(f32, 100), delta[0]);
    try testing.expectEqual(@as(f32, 0), delta[1]);
}

// Locks main-axis alignment: an end-aligned column moves its children by the unused span, and
// a fit main axis has no slack to align.
test "main shift moves children by the unused span" {
    var layout = flat;
    layout.alignment.y = 1;
    var column = root(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, layout);
    _ = walk_leaf(&column, sized(.fill, .{ .fixed = 30 }));
    try testing.expectEqual(@as(f32, 70), main_shift(&column)[1]);
    var fit = open(.{ .x = 0, .y = 0, .width = 100, .height = 0 }, sized(.fill, .fit), flat);
    _ = walk_leaf(&fit, sized(.fill, .{ .fixed = 30 }));
    try testing.expectEqual(@as(f32, 0), main_shift(&fit)[1]);
}

// Locks `fits` over its negative space: a cell that crosses the inner end, a cell taller
// than the row, and a zero edge are refused; a cell that lands exactly on the end fits.
test "fits refuses a cell that would leave the inner rect" {
    var layout = flat;
    layout.flow = .right;
    var row = root(.{ .x = 0, .y = 0, .width = 304, .height = 72 }, layout);
    var cell = sized(.{ .fixed = 144 }, .{ .fixed = 72 });
    cell.margin.left = 8;
    try testing.expect(fits(&row, cell));
    _ = walk_leaf(&row, cell);
    try testing.expect(fits(&row, cell));
    _ = walk_leaf(&row, cell);
    try testing.expect(!fits(&row, cell));
    var short = root(.{ .x = 0, .y = 0, .width = 304, .height = 71 }, layout);
    try testing.expect(!fits(&short, cell));
    try testing.expect(!fits(&short, sized(.{ .fixed = 0 }, .{ .fixed = 10 })));
    try testing.expectEqual(@as(u32, 0), short.count);
}

// Locks `skip`: a list stands in for rows it does not draw, and the extent follows.
test "skip advances the cursor and the extent" {
    var column = root(.{ .x = 0, .y = 0, .width = 100, .height = 50 }, flat);
    skip(&column, 240);
    try expect_rect(walk_leaf(&column, sized(.fill, .{ .fixed = 24 })), 0, 240, 100, 24);
    skip(&column, 960);
    try testing.expectEqual(@as(f32, 1224), column.extent[1]);
}

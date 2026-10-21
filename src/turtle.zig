//! Pure 2D layout solver: column and row cursors, border-box algebra, and fill distribution.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Standalone Solver
//! Layout must not depend on colors, shaders, widgets, input, or GPU state, so it can be
//! tested with plain numbers. `place_column` and `place_row` take one `Walk` per child and
//! write one border-box `Rect` per child into a caller-owned slice of the same length. The
//! app's layout pass is the caller: it gathers `Walk`s from its widgets, calls the solver, and
//! writes the rectangles back. Drawing happens later and consumes the rectangles.
//!
//! `place_row` is the horizontal transpose of `place_column`. It exists so that side-by-side
//! controls need neither nested containers nor a constraint solver.
//!
//! ## 2. Coordinate Space and Box Model
//! All values are UI logical pixels: origin top-left, `+X` right, `+Y` down.
//! ```text
//! Margin Box = space a child consumes (the cursor advances by it).
//! Border Box = the emitted `Rect`: the margin box inset by the child's margins.
//! Inner Rect = the container rect inset by the container's padding.
//! ```
//!
//! ## 3. Sizing Rules
//! - `fixed`: an explicit span.
//! - `fit`: a span the caller measured. The solver treats it exactly like `fixed`: it is not
//!   a fill share and is never clamped to the inner rect. Test: "fit matches fixed of the
//!   same span".
//! - `fill`: takes leftover space. Main-axis fills split the leftover equally, and a cross-axis
//!   fill takes the full available extent independently for each child.
//!
//! ## 4. Column Algebra (`place_column`)
//! For `column.rect = (X, Y, W, H)` and padding `P`:
//! ```text
//! inner_x = X + P.left               inner_y = Y + P.top
//! inner_w = W - P.left - P.right     inner_h = H - P.top - P.bottom
//!
//! fixed_sum  = sum over i of (margin.top + margin.bottom
//!                             + height payload if fixed or fit, else 0)
//! fill_count = count of i with height == .fill
//! fill_share = max(inner_h - fixed_sum, 0) / fill_count      (0 if fill_count == 0)
//!
//! avail_w = inner_w - margin.left - margin.right
//! width   = width payload if fixed or fit, else avail_w
//! height  = height payload if fixed or fit, else fill_share
//! x       = inner_x + margin.left + align_x * max(avail_w - width, 0)
//! y       = cursor_y + margin.top
//! cursor_y += margin.top + height + margin.bottom             (cursor_y starts at inner_y)
//! ```
//!
//! ## 5. Row Algebra (`place_row`)
//! The main axis is X and the cross axis is Y:
//! ```text
//! fixed_sum  = sum over i of (margin.left + margin.right
//!                             + width payload if fixed or fit, else 0)
//! fill_count = count of i with width == .fill
//! fill_share = max(inner_w - fixed_sum, 0) / fill_count      (0 if fill_count == 0)
//!
//! width   = width payload if fixed or fit, else fill_share
//! avail_h = inner_h - margin.top - margin.bottom
//! height  = height payload if fixed or fit, else avail_h
//! x       = cursor_x + margin.left                           (cursor_x starts at inner_x)
//! y       = inner_y + margin.top
//! cursor_x += margin.left + width + margin.right
//! ```
//! - A row has no cross-axis alignment: `align_x` is validated but does not move children.
//!   Test: "align_x does not move a row child".
//! - Oversized fixed spans are not clamped.
//! - A non-positive resolved edge is still stored and the cursor still advances, so siblings
//!   keep stable positions. Widgets skip such an edge when drawing, and `draw.Context.append`
//!   rejects one with `error.EdgeNotPositive`, so it never reaches the GPU.
//!
//! ## 6. Layout Types and Capacity
//! The plain-data types are laid out as `f32` fields in declaration order with 4-byte
//! alignment. The comptime block below asserts their sizes. `child_cap` bounds one column or
//! row; it is independent of the draw pools, whose capacities each app configures.
//!
//! ## 7. Scale Invariance
//! Layout runs in logical pixels, so a display scale change must not trigger it. That rule is
//! enforced by `Frame.apply_scale` never setting `Frame.relayout`.
//!
//! ## 8. TigerStyle Invariants
//! - Two bounded linear passes over `walks.len` (cost summation, then placement), no recursion.
//! - `walks.len == out.len <= child_cap`, caller-supplied storage, no allocation.
//! - Padding, margins, and fixed spans are non-negative and `align_x` is in `[0, 1]`. Each is
//!   asserted independently.

const std = @import("std");
const assert = std.debug.assert;
/// Maximum walks in one column or row.
pub const child_cap: u32 = 255;

/// Axis-aligned border box in UI logical pixels. `(x, y)` is the top-left corner.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Independent insets in UI logical pixels. A negative component fails an assertion.
pub const Inset = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// Axis sizing. `fixed` and `fit` carry a span in logical pixels and resolve identically;
/// `fit` marks a span the caller measured. `fill` consumes leftover space.
pub const Size = union(enum) {
    fixed: f32,
    fit: f32,
    fill,
};

/// One child of a column or row. The cursor consumes the margin box and the emitted
/// rectangle is the border box. In a column, `align_x` in `[0, 1]` places a narrower child
/// within the horizontal slack. A row ignores it.
pub const Walk = struct {
    margin: Inset,
    width: Size,
    height: Size,
    align_x: f32,
};

/// Container rectangle and the padding that insets its children. Used for rows too.
pub const Column = struct {
    rect: Rect,
    padding: Inset,
};

const AxisCost = struct {
    sum: f32,
    fill_count: u32,
};

comptime {
    assert(child_cap == 255);
    assert(@sizeOf(Rect) == 16);
    assert(@sizeOf(Inset) == 16);
    assert(@sizeOf(Size) == 8);
    assert(@sizeOf(Walk) == 36);
    assert(@sizeOf(Column) == 32);
    assert(@alignOf(Rect) == 4);
    assert(@alignOf(Inset) == 4);
    assert(@alignOf(Size) == 4);
    assert(@alignOf(Walk) == 4);
    assert(@alignOf(Column) == 4);
}

/// Writes one border box per walk into `out`, stacked top to bottom. The formulas are in the
/// module guide.
///
/// Preconditions, asserted: `walks.len == out.len <= child_cap`, padding, margins, and fixed
/// spans are non-negative, and `align_x` is in `[0, 1]`. A non-positive resolved edge is still
/// stored and the cursor still advances past that child.
pub fn place_column(column: Column, walks: []const Walk, out: []Rect) void {
    assert(walks.len == out.len);
    assert(walks.len <= @as(usize, child_cap));
    assert_inset(column.padding);
    const inner = inner_rect(column);
    const cost = column_fixed_cost(walks);
    const share = fill_share(inner.height, cost);
    place_walks(inner, walks, share, out);
    assert(out.len == walks.len);
    assert(share >= 0);
}

fn assert_inset(inset: Inset) void {
    assert(inset.left >= 0);
    assert(inset.top >= 0);
    assert(inset.right >= 0);
    assert(inset.bottom >= 0);
}

fn assert_size(size: Size) void {
    switch (size) {
        .fixed, .fit => |value| {
            assert(value >= 0);
            assert(value == value);
        },
        .fill => {
            assert(size == .fill);
            assert(@sizeOf(Size) >= @sizeOf(f32));
        },
    }
}

fn assert_walk(walk: Walk) void {
    assert_inset(walk.margin);
    assert_size(walk.width);
    assert_size(walk.height);
    assert(walk.align_x >= 0);
    assert(walk.align_x <= 1);
}

fn inner_rect(column: Column) Rect {
    assert_inset(column.padding);
    const rect: Rect = .{
        .x = column.rect.x + column.padding.left,
        .y = column.rect.y + column.padding.top,
        .width = column.rect.width - column.padding.left - column.padding.right,
        .height = column.rect.height - column.padding.top - column.padding.bottom,
    };
    assert(rect.x == column.rect.x + column.padding.left);
    assert(rect.y == column.rect.y + column.padding.top);
    return rect;
}

fn column_fixed_cost(walks: []const Walk) AxisCost {
    assert(walks.len <= @as(usize, child_cap));
    const count: u32 = @intCast(walks.len);
    var sum: f32 = 0;
    var fill_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const walk = walks[index];
        assert_walk(walk);
        sum += walk.margin.top;
        sum += walk.margin.bottom;
        switch (walk.height) {
            .fill => fill_count += 1,
            .fixed, .fit => |height| sum += height,
        }
    }
    assert(index == count);
    assert(fill_count <= count);
    return .{ .sum = sum, .fill_count = fill_count };
}

fn fill_share(inner_h: f32, cost: AxisCost) f32 {
    assert(cost.fill_count <= child_cap);
    assert(cost.sum == cost.sum);
    if (cost.fill_count == 0) {
        return 0;
    }
    const leftover = inner_h - cost.sum;
    if (leftover <= 0) {
        assert(leftover <= 0);
        return 0;
    }
    const count: f32 = @floatFromInt(cost.fill_count);
    const share = leftover / count;
    assert(share > 0);
    return share;
}

fn place_walks(inner: Rect, walks: []const Walk, share: f32, out: []Rect) void {
    assert(walks.len == out.len);
    assert(share >= 0);
    const count: u32 = @intCast(walks.len);
    var cursor_y = inner.y;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const walk = walks[index];
        assert_walk(walk);
        const avail_w = inner.width - walk.margin.left - walk.margin.right;
        const width = resolved_width(walk.width, avail_w);
        const height = resolved_height(walk.height, share);
        const slack = positive_slack(avail_w - width);
        out[index] = .{
            .x = inner.x + walk.margin.left + walk.align_x * slack,
            .y = cursor_y + walk.margin.top,
            .width = width,
            .height = height,
        };
        cursor_y += walk.margin.top + height + walk.margin.bottom;
    }
    assert(index == count);
    assert(cursor_y >= inner.y);
}

fn resolved_width(size: Size, avail_w: f32) f32 {
    assert(avail_w == avail_w);
    switch (size) {
        .fixed, .fit => |value| {
            assert(value >= 0);
            return value;
        },
        .fill => {
            assert(size == .fill);
            return avail_w;
        },
    }
}

fn resolved_height(size: Size, share: f32) f32 {
    assert(share >= 0);
    switch (size) {
        .fixed, .fit => |value| {
            assert(value >= 0);
            return value;
        },
        .fill => {
            assert(size == .fill);
            return share;
        },
    }
}

fn positive_slack(slack: f32) f32 {
    assert(slack == slack);
    if (slack > 0) {
        assert(slack > 0);
        return slack;
    }
    assert(slack <= 0);
    return 0;
}

/// Writes one border box per walk into `out`, packed left to right. Same preconditions and
/// edge handling as `place_column`, with the main axis on X. `align_x` is validated but does
/// not move a child. See the module guide for the formulas.
pub fn place_row(row: Column, walks: []const Walk, out: []Rect) void {
    assert(walks.len == out.len);
    assert(walks.len <= @as(usize, child_cap));
    assert_inset(row.padding);
    const inner = inner_rect(row);
    const cost = row_fixed_cost(walks);
    const share = fill_share(inner.width, cost);
    place_row_walks(inner, walks, share, out);
    assert(out.len == walks.len);
    assert(share >= 0);
}

fn row_fixed_cost(walks: []const Walk) AxisCost {
    assert(walks.len <= @as(usize, child_cap));
    const count: u32 = @intCast(walks.len);
    var sum: f32 = 0;
    var fill_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const walk = walks[index];
        assert_walk(walk);
        sum += walk.margin.left;
        sum += walk.margin.right;
        switch (walk.width) {
            .fill => fill_count += 1,
            .fixed, .fit => |width| sum += width,
        }
    }
    assert(index == count);
    assert(fill_count <= count);
    return .{ .sum = sum, .fill_count = fill_count };
}

fn place_row_walks(inner: Rect, walks: []const Walk, share: f32, out: []Rect) void {
    assert(walks.len == out.len);
    assert(share >= 0);
    const count: u32 = @intCast(walks.len);
    var cursor_x = inner.x;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const walk = walks[index];
        assert_walk(walk);
        const width = row_main(walk.width, share);
        const avail_h = inner.height - walk.margin.top - walk.margin.bottom;
        const height = row_cross(walk.height, avail_h);
        out[index] = .{
            .x = cursor_x + walk.margin.left,
            .y = inner.y + walk.margin.top,
            .width = width,
            .height = height,
        };
        cursor_x += walk.margin.left + width + walk.margin.right;
        assert(out[index].y == inner.y + walk.margin.top);
    }
    assert(index == count);
    assert(cursor_x >= inner.x);
}

fn row_main(size: Size, share: f32) f32 {
    assert(share >= 0);
    switch (size) {
        .fixed, .fit => |value| {
            assert(value >= 0);
            return value;
        },
        .fill => {
            assert(size == .fill);
            return share;
        },
    }
}

fn row_cross(size: Size, avail_h: f32) f32 {
    assert(avail_h == avail_h);
    switch (size) {
        .fixed, .fit => |value| {
            assert(value >= 0);
            return value;
        },
        .fill => {
            assert(size == .fill);
            return avail_h;
        },
    }
}

const zero_inset: Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

const column_padding: Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };

// Locks the equal split of leftover main-axis height among fill children.
test "two fills split a 200 tall inner rect" {
    const column: Column = .{
        .rect = .{ .x = 0, .y = 0, .width = 100, .height = 200 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .{ .fixed = 40 },
            .height = .fill,
            .align_x = 0,
        },
        .{
            .margin = zero_inset,
            .width = .{ .fixed = 40 },
            .height = .fill,
            .align_x = 0,
        },
    };
    var out: [2]Rect = undefined;
    place_column(column, &walks, &out);
    try std.testing.expectEqual(@as(f32, 100), out[0].height);
    try std.testing.expectEqual(@as(f32, 100), out[1].height);
    try std.testing.expectEqual(@as(f32, 0), out[0].y);
    try std.testing.expectEqual(@as(f32, 100), out[1].y);
}

// Locks `align_x` placement: 0.5 centers a fixed width in the slack (20 + (300 - 100) / 2).
test "align_x centers a fixed width" {
    const column: Column = .{
        .rect = .{ .x = 20, .y = 0, .width = 300, .height = 50 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 10 },
            .align_x = 0.5,
        },
    };
    var out: [1]Rect = undefined;
    place_column(column, &walks, &out);
    try std.testing.expectEqual(@as(f32, 120), out[0].x);
    try std.testing.expectEqual(@as(f32, 100), out[0].width);
}

// Locks padding: it insets the origin and shrinks a fill width (200 - 2 * 16).
test "padding insets the first child and shrinks a fill width" {
    const column: Column = .{
        .rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 },
        .padding = column_padding,
    };
    const walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .fill,
            .height = .{ .fixed = 10 },
            .align_x = 0,
        },
    };
    var out: [1]Rect = undefined;
    place_column(column, &walks, &out);
    try std.testing.expectEqual(@as(f32, 16), out[0].x);
    try std.testing.expectEqual(@as(f32, 16), out[0].y);
    try std.testing.expectEqual(@as(f32, 168), out[0].width);
}

// Locks that margins sit outside the border box and the cursor advances past them
// (second y = 10 + 20 + 4).
test "margin advances the cursor outside the border box" {
    const column: Column = .{
        .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = .{ .left = 0, .top = 10, .right = 0, .bottom = 4 },
            .width = .{ .fixed = 30 },
            .height = .{ .fixed = 20 },
            .align_x = 0,
        },
        .{
            .margin = zero_inset,
            .width = .fill,
            .height = .{ .fixed = 8 },
            .align_x = 0,
        },
    };
    var out: [2]Rect = undefined;
    place_column(column, &walks, &out);
    try std.testing.expectEqual(@as(f32, 10), out[0].y);
    try std.testing.expectEqual(@as(f32, 20), out[0].height);
    try std.testing.expectEqual(@as(f32, 34), out[1].y);
}

// Locks that `Size.fit` yields the same border box as `Size.fixed` of the same span.
test "fit matches fixed of the same span" {
    const column: Column = .{
        .rect = .{ .x = 0, .y = 0, .width = 300, .height = 80 },
        .padding = zero_inset,
    };
    const fit_walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .{ .fit = 80 },
            .height = .{ .fit = 24 },
            .align_x = 1,
        },
    };
    const fixed_walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .{ .fixed = 80 },
            .height = .{ .fixed = 24 },
            .align_x = 1,
        },
    };
    var fit_out: [1]Rect = undefined;
    var fixed_out: [1]Rect = undefined;
    place_column(column, &fit_walks, &fit_out);
    place_column(column, &fixed_walks, &fixed_out);
    try std.testing.expectEqual(fixed_out[0].x, fit_out[0].x);
    try std.testing.expectEqual(fixed_out[0].y, fit_out[0].y);
    try std.testing.expectEqual(fixed_out[0].width, fit_out[0].width);
    try std.testing.expectEqual(fixed_out[0].height, fit_out[0].height);
}

// Locks left-to-right packing: each x advances by margin.left + width (8 + 144 = 152).
test "four fixed cells pack from the left of a row" {
    const row: Column = .{
        .rect = .{ .x = 24, .y = 48, .width = 1152, .height = 72 },
        .padding = zero_inset,
    };
    const walk: Walk = .{
        .margin = .{ .left = 8, .top = 0, .right = 0, .bottom = 0 },
        .width = .{ .fixed = 144 },
        .height = .{ .fixed = 72 },
        .align_x = 0,
    };
    const walks = [_]Walk{ walk, walk, walk, walk };
    var out: [4]Rect = undefined;
    place_row(row, &walks, &out);
    try std.testing.expectEqual(@as(f32, 32), out[0].x);
    try std.testing.expectEqual(@as(f32, 184), out[1].x);
    try std.testing.expectEqual(@as(f32, 336), out[2].x);
    try std.testing.expectEqual(@as(f32, 488), out[3].x);
    try std.testing.expectEqual(@as(f32, 48), out[0].y);
    try std.testing.expectEqual(@as(f32, 144), out[0].width);
    try std.testing.expectEqual(@as(f32, 72), out[0].height);
}

// Locks the row fill rules: widths split leftover equally, and each height fill takes the
// whole row height rather than a share.
test "fill widths split leftover and fill heights take the row" {
    const row: Column = .{
        .rect = .{ .x = 0, .y = 10, .width = 200, .height = 80 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .fill,
            .height = .fill,
            .align_x = 0,
        },
        .{
            .margin = zero_inset,
            .width = .fill,
            .height = .fill,
            .align_x = 1,
        },
    };
    var out: [2]Rect = undefined;
    place_row(row, &walks, &out);
    try std.testing.expectEqual(@as(f32, 0), out[0].x);
    try std.testing.expectEqual(@as(f32, 100), out[1].x);
    try std.testing.expectEqual(@as(f32, 100), out[0].width);
    try std.testing.expectEqual(@as(f32, 100), out[1].width);
    try std.testing.expectEqual(@as(f32, 10), out[0].y);
    try std.testing.expectEqual(@as(f32, 80), out[0].height);
    try std.testing.expectEqual(@as(f32, 80), out[1].height);
}

// Locks that `align_x` does not move a row child.
test "align_x does not move a row child" {
    const row: Column = .{
        .rect = .{ .x = 20, .y = 0, .width = 300, .height = 40 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = zero_inset,
            .width = .{ .fixed = 100 },
            .height = .{ .fixed = 10 },
            .align_x = 1,
        },
    };
    var out: [1]Rect = undefined;
    place_row(row, &walks, &out);
    try std.testing.expectEqual(@as(f32, 20), out[0].x);
    try std.testing.expectEqual(@as(f32, 100), out[0].width);
}

// Locks that a short fixed-height child sits at the top of a taller row.
test "fixed height stays at the top of a taller row" {
    const row: Column = .{
        .rect = .{ .x = 0, .y = 48, .width = 400, .height = 184 },
        .padding = zero_inset,
    };
    const walks = [_]Walk{
        .{
            .margin = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
            .width = .{ .fixed = 144 },
            .height = .{ .fixed = 72 },
            .align_x = 0,
        },
    };
    var out: [1]Rect = undefined;
    place_row(row, &walks, &out);
    try std.testing.expectEqual(@as(f32, 48), out[0].y);
    try std.testing.expectEqual(@as(f32, 72), out[0].height);
}

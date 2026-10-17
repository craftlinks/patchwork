//! Pure 2D turtle layout engine: column cursor, border box algebra, and fill distribution.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In retained and immediate GUI systems alike, calculating the spatial layout of visual elements
//! must be completely decoupled from graphics rendering, widget event dispatching, and hardware
//! device drivers.
//!
//! ### Purpose in the Frame:
//! `place_column` and `place_row` are Patchwork's core layout primitives. They are pure
//! geometric solvers:
//! - They have no knowledge of colors, corner radiuses, shaders, widgets, or GPU draw lists.
//! - The caller provides an array of `Walk` layout specifications and an output slice of `Rect`
//!   border boxes of the exact same length.
//! - `scene.Scene.layout` is that caller: it extracts `Walk` specifications from its retained
//!   widgets, passes them to `place_column` (for top-level stacked panels) and `place_row`
//!   (for horizontal knob rows inside panel bodies), writes the resolved border boxes back to
//!   the widgets, and updates scene bounds. `scene.Scene.draw` later appends GPU instances.
//!
//! ### Why `place_row` Exists (Horizontal Axis Transpose):
//! While top-level layouts commonly flow vertically as a column, complex UI components—such as
//! audio synthesizer panels, toolbars, and inspector strips—require packing controls side by side.
//! Rather than introducing nested containers or complex constraint solvers:
//! - `place_row` provides a horizontal transpose of `place_column`.
//! - It advances a layout cursor horizontally along the X axis from left to right.
//! - Width `fill` distributes available horizontal space among row siblings, while height `fill`
//!   allows each sibling to stretch to the full available row height independently.
//!
//! ### Sizing Primitives:
//! - `fixed`: Explicit span in logical pixels (e.g. 144 px knob cell, 72 px knob height).
//! - `fill`: Consumes remaining space. In a column, width fills available inner width, while height
//!   shares leftover main-axis space. In a row, width shares leftover main-axis space, while height
//!   takes the row height minus that child's vertical margins.
//! - `fit`: A premeasured span in logical pixels. Layout treats the payload like `fixed`: it is
//!   not a fill share, and a value wider than the inner rect is not clamped.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! All measurements are in UI logical pixels, top-left origin `(0, 0)`, `+X` right, and `+Y` down.
//!
//! ### Box Model Definitions:
//! ```text
//! Margin Box = Total spatial allocation consumed by child (advance of the layout cursor).
//! Border Box = The rendered visual box, inset from the margin box by child margins.
//! Inner Rect = The container rectangle inset by container padding.
//! ```
//!
//! ### Analytical Layout Algebra for Columns (`place_column`):
//! Given `column.rect = (X, Y, W, H)` and `column.padding = P`:
//! ```text
//! inner_x = X + P.left
//! inner_y = Y + P.top
//! inner_w = W - P.left - P.right
//! inner_h = H - P.top - P.bottom
//! ```
//!
//! #### Column Main-Axis (Y) Budgeting:
//! Fixed main-axis cost is summed across all children `i = 0..N-1`:
//! ```text
//! fixed_sum = sum(walk[i].margin.top + walk[i].margin.bottom +
//!                 (walk[i].height payload when fixed or fit, else 0))
//! fill_count = count of children where walk[i].height == .fill
//! leftover = inner_h - fixed_sum
//! fill_share = max(leftover, 0) / fill_count   (0 if fill_count == 0)
//! ```
//!
//! #### Column Cross-Axis (X) and Placement:
//! For each child `i`:
//! ```text
//! avail_w = inner_w - walk[i].margin.left - walk[i].margin.right
//! width   = walk[i].width payload when fixed or fit, else avail_w
//! height  = walk[i].height payload when fixed or fit, else fill_share
//!
//! slack_x = max(avail_w - width, 0)
//! x       = inner_x + walk[i].margin.left + walk[i].align_x * slack_x
//! y       = cursor_y + walk[i].margin.top
//!
//! cursor_y += walk[i].margin.top + height + walk[i].margin.bottom
//! ```
//!
//! ### Analytical Layout Algebra for Rows (`place_row`):
//! `place_row` transposes the main axis to X and the cross axis to Y.
//!
//! #### Row Main-Axis (X) Budgeting:
//! Fixed main-axis cost is summed across all children `i = 0..N-1`:
//! ```text
//! fixed_sum = sum(walk[i].margin.left + walk[i].margin.right +
//!                 (walk[i].width payload when fixed or fit, else 0))
//! fill_count = count of children where walk[i].width == .fill
//! leftover = inner_w - fixed_sum
//! fill_share = max(leftover, 0) / fill_count   (0 if fill_count == 0)
//! ```
//!
//! #### Row Cross-Axis (Y) and Placement:
//! For each child `i`:
//! ```text
//! width   = walk[i].width payload when fixed or fit, else fill_share
//! avail_h = inner_h - walk[i].margin.top - walk[i].margin.bottom
//! height  = walk[i].height payload when fixed or fit, else avail_h
//!
//! x       = cursor_x + walk[i].margin.left
//! y       = inner_y + walk[i].margin.top
//!
//! cursor_x += walk[i].margin.left + width + walk[i].margin.right
//! ```
//!
//! #### Row Alignment & Cross-Axis Sizing Invariants:
//! - **Height Fill Does Not Split:** Unlike main-axis fill shares, `height = .fill` in a row
//!   takes the entire available row height `avail_h` independently for each child.
//! - **`align_x` Ignored in Rows:** `align_x` is checked (`assert_walk`) but does not alter child
//!   positions in `place_row`. Children pack strictly left-to-right from `cursor_x`. Cross-axis
//!   alignment (`align_y`) does not exist on `Walk`; children sit at `inner_y + margin.top`.
//! - **No Clamping of Oversized Fixed Sizes:** Oversized fixed widths or heights are not clamped.
//! - **Degenerate Edge Handling:** Non-positive dimensions (`width <= 0` or `height <= 0`) are
//!   stored in `out` so layout cursor advancement remains stable for all siblings. Downstream,
//!   `DrawList.append` rejects degenerate edges (`error.EdgeNotPositive`), omitting them from GPU
//!   draw calls.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Struct Layouts:
//! - `Rect`: 16 bytes (`x, y, width, height: f32`). Alignment: 4 bytes.
//! - `Inset`: 16 bytes (`left, top, right, bottom: f32`). Alignment: 4 bytes.
//! - `Size`: Tagged union (`fixed: f32`, `fill`). Size: 8 bytes. Alignment: 4 bytes.
//! - `Walk`: 36 bytes (`margin: Inset`, `width: Size`, `height: Size`, `align_x: f32`).
//! - `Column`: 32 bytes (`rect: Rect`, `padding: Inset`).
//!
//! ### Capacity Constraints:
//! - `child_cap = draw.instance_cap - 1 = 255`: Maximum children in a column or row.
//!   Leaves at least 1 slot in the 256-instance draw list for container background quads.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Two-Pass Geometric Solver Pipeline:
//! ```text
//! [Input: container (Column), walks[]]
//!           |
//!           v
//! Pass 1: Fixed Cost Summation
//!         - Column: column_fixed_cost() sums vertical margins & fixed heights
//!         - Row:    row_fixed_cost() sums horizontal margins & fixed widths
//!           |
//!           v
//! Calculation: fill_share()
//!         Computes equal share of positive leftover main-axis span
//!           |
//!           v
//! Pass 2: Cursor Placement Walk
//!         - Column: place_walks() advances cursor_y, resolves align_x slack
//!         - Row:    place_row_walks() advances cursor_x, y = inner.y + margin.top
//!           |
//!           v
//! [Output: out[] populated with resolved border-box Rects]
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Platform Neutrality:** `turtle.zig` is 100% pure Zig code with zero dependencies on
//!   Wayland, POSIX, WebGPU, or WebAssembly host environments.
//! - **Scale Invariance:** Because UI layout operates entirely in logical pixels, display scale
//!   changes (`Frame.apply_scale`) do NOT set `Frame.relayout`. Layout recalculation is triggered
//!   only when logical window bounds change.
//!
//! ## 6. TigerStyle Invariants
//! - **Bounded Operations:** Layout functions take pre-allocated output slices of bounded size
//!   (`walks.len <= child_cap`).
//! - **Zero Runtime Allocation:** All operations execute strictly in-place on caller-supplied
//!   buffers without heap allocation.
//! - **Split Preconditions:** Invariants (`walks.len == out.len`, padding bounds, margin bounds)
//!   are asserted independently at function boundaries.
//!
//! ## 6. TigerStyle Invariants
//! - **Bounded Execution:** Layout runs in strictly two bounded linear passes over `walks.len`.
//! - **Zero Dynamic Allocation:** Uses caller-supplied output slices; zero heap allocations.
//! - **Precondition Assertions:** Validates non-negative insets, non-negative fixed sizes,
//!   `align_x in [0, 1]`, and `walks.len == out.len <= child_cap`.
//! - **No Recursion:** Fully iterative column cursor arithmetic.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");

/// Maximum child walks in one column.
/// One draw-list slot stays available for the column background the scene appends.
pub const child_cap: u32 = draw.instance_cap - 1;

/// Axis-aligned border box in UI logical pixels. Origin is the top-left. Y grows down.
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Independent insets in UI logical pixels. Negative components are a programmer error.
pub const Inset = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// Axis sizing. `fixed` and `fit` are spans in logical pixels. `fit` is a
/// premeasured extent, not a fill share. `fill` consumes leftover space.
/// A `fit` wider than the inner rect is not clamped.
pub const Size = union(enum) {
    fixed: f32,
    fit: f32,
    fill,
};

/// One child of a column. The cursor consumes the margin box. The emitted
/// rectangle is the border box. `align_x` in `[0, 1]` places a fixed width in slack.
pub const Walk = struct {
    margin: Inset,
    width: Size,
    height: Size,
    align_x: f32,
};

/// Parent rectangle and the padding that insets the child walk.
pub const Column = struct {
    rect: Rect,
    padding: Inset,
};

const AxisCost = struct {
    sum: f32,
    fill_count: u32,
};

comptime {
    assert(child_cap == draw.instance_cap - 1);
    assert(child_cap == 255);
}

/// Writes one border box per walk into `out`.
///
/// `walks.len` equals `out.len` and is at most `child_cap`. Padding, margins, and
/// fixed sizes are non-negative. `align_x` is in `[0, 1]`. A non-positive resolved
/// edge is still stored, and the cursor still advances past that child.
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

/// Writes one border box per walk, packed left to right.
///
/// The main axis is X. Width `fill` shares leftover width. Height `fill` takes
/// the row height minus that child's vertical margins. `y` is the top of the
/// inner rect plus `margin.top`. `align_x` is checked and does not move a child:
/// a row has no cross-axis align. An oversized fixed width is not clamped, and
/// a non-positive edge is still stored.
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

// Two fill children split a 200 px inner height into equal 100 px shares.
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

// align_x 0.5 centers a 100 px child in a 300 px column that starts at x 20.
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

// Padding of 16 shrinks a fill width from 200 to 168 and insets the origin.
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

// Margin sits outside the border box, so the next sibling starts after it.
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

// Verifies that `Size.fit` resolves to the identical border-box geometry as `Size.fixed`
// when provided with the same pixel dimensions, ensuring that content-fitted elements participate
// in cross-axis alignment and fixed-cost accounting identically to explicit spans.
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

// Four fixed knob cells pack from the left. align is not consulted.
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

// Two fill widths split 200 px. Both fill heights take the full row, side by side.
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

// A fixed width in a wider row stays at the left edge when align_x is 1.
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

// A short fixed child stays on the top of a taller row.
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

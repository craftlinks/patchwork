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
//! `place_column` is Patchwork's core layout primitive. It is a pure geometric solver:
//! - It has no knowledge of colors, corner radiuses, shaders, widgets, or GPU draw lists.
//! - The caller provides an array of `Walk` layout specifications and an output slice of `Rect`
//!   border boxes of the exact same length.
//! - In Step 6, `scene.Scene.layout` is that caller: it extracts `Walk` specifications from its
//!   retained widgets, passes them to `place_column`, writes the resolved border boxes back to
//!   the widgets, and updates scene bounds. `scene.Scene.draw` later appends GPU instances.
//!
//! ### Where the Demo Went:
//! In Steps 4 and 5, `turtle.paint_column` directly laid out and painted hard-coded demo panels.
//! In Step 6, `turtle.paint_column` has been completely superseded:
//! - The demo walks (header, body panel, slider, and button) live on the widgets in `src/scene.zig`.
//! - This module (`turtle.zig`) no longer contains demo definitions or painting routines.
//! - The demo's main-axis fixed cost increased from 144 px (in Step 5) to 184 px (in Step 6) due
//!   to the addition of the fixed 24 px slider and its 16 px top margin (`40` px added).
//!
//! ### Sizing Primitives:
//! - `fixed`: Explicit span in logical pixels (e.g. 64 px header, 48 px button).
//! - `fill`: Consumes remaining space. On width, fills available inner column width minus child
//!   margins. On height, receives an equal share of leftover main-axis space after summing all
//!   fixed heights and margins.
//! - `fit`: Content-derived sizing; deferred until font rasterization and text measurement exist.
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
//! Inner Rect = The column's container rectangle inset by column padding.
//! ```
//!
//! ### Analytical Layout Algebra:
//! Given `column.rect = (X, Y, W, H)` and `column.padding = P`:
//! ```text
//! inner_x = X + P.left
//! inner_y = Y + P.top
//! inner_w = W - P.left - P.right
//! inner_h = H - P.top - P.bottom
//! ```
//!
//! #### Main-Axis (Y) Budgeting:
//! Fixed main-axis cost is summed across all children `i = 0..N-1`:
//! ```text
//! fixed_sum = sum(walk[i].margin.top + walk[i].margin.bottom +
//!                 (walk[i].height.fixed if fixed else 0))
//! fill_count = count of children where walk[i].height == .fill
//! leftover = inner_h - fixed_sum
//! fill_share = max(leftover, 0) / fill_count   (0 if fill_count == 0)
//! ```
//!
//! #### Cross-Axis (X) and Placement:
//! For each child `i`:
//! ```text
//! avail_w = inner_w - walk[i].margin.left - walk[i].margin.right
//! width   = walk[i].width.fixed if fixed else avail_w
//! height  = walk[i].height.fixed if fixed else fill_share
//!
//! slack_x = max(avail_w - width, 0)
//! x       = inner_x + walk[i].margin.left + walk[i].align_x * slack_x
//! y       = cursor_y + walk[i].margin.top
//!
//! cursor_y += walk[i].margin.top + height + walk[i].margin.bottom
//! ```
//!
//! ### Alignment and Negative Slack:
//! - `align_x` in `[0.0, 1.0]` interpolates position within positive horizontal slack (`0.0` = left,
//!   `0.5` = centered, `1.0` = right).
//! - If a child's fixed width exceeds available width (`avail_w < width`), `slack_x` clamps to `0.0`,
//!   preventing negative shifts or reverse layout movement. Oversized fixed sizes are not clamped.
//! - Non-positive dimensions (`width <= 0` or `height <= 0`) are written to `out` unchanged and the
//!   cursor advances normally so sibling offsets remain stable. Downstream, `DrawList.append` rejects
//!   degenerate edges (`error.EdgeNotPositive`), omitting them from the GPU draw list.
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
//! - `child_cap = draw.instance_cap - 1 = 255`: Maximum children in a column.
//!   Leaves at least 1 slot in the 256-instance draw list for the column background quad.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Two-Pass Execution Pipeline:
//! ```text
//! [Input: column, walks[]]
//!           |
//!           v
//! Pass 1: column_fixed_cost()
//!         Sums margins and fixed heights (fixed_sum)
//!         Counts children with .fill height (fill_count)
//!           |
//!           v
//! Calculation: fill_share()
//!         Computes equal share of positive leftover height
//!           |
//!           v
//! Pass 2: place_walks()
//!         Iterates cursor_y from inner_y
//!         Resolves width, height, alignment slack
//!         Writes border box Rect into out[]
//!         Advances cursor_y by margin box
//!           |
//!           v
//! [Output: out[] populated with Rects]
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

/// Axis sizing. `fixed` is a span in logical pixels. `fill` consumes leftover space.
pub const Size = union(enum) {
    fixed: f32,
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
        .fixed => |value| {
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
            .fixed => |height| sum += height,
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
        .fixed => |value| {
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
        .fixed => |value| {
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

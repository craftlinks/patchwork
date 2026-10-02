//! Places the rectangles that the instanced draw paints.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Purpose in the frame
//! A frame is a logical window size, a list of rectangle instances, and one draw call.
//! `draw.zig` stores each instance and the shader paints it as a rounded box. This file
//! is the step that chooses those rectangles.
//!
//! The window's logical size is the parent rectangle. `paint_column` walks a column of
//! panels inside it and appends one instance per panel whose border box has two positive
//! edges. Native `present_if_dirty` and the browser `tick` call that walk when
//! `Frame.relayout` is set, which means the logical size changed. The same panels then
//! occupy the new window. A scale change leaves the logical size alone, so the rectangles
//! already in the draw list stay valid and the walk does not run again.
//!
//! A walk is the layout record for one child: size, margin, and horizontal alignment.
//! The panel table in this file adds the paint: color, corner radius, and hover. What
//! leaves the file is a border box copied into `DrawList`. The running picture is that
//! column filling the window: a fixed-height header, a body that takes the leftover
//! height, and a fixed-width footer on the right.
//!
//! ## 2. The column cursor
//! A column has a rectangle and a padding inset. Each child has a walk: a `fixed` or `fill`
//! size on each axis, a margin, and a horizontal alignment factor `align_x`. The turtle
//! starts `cursor_y` at the inner top. For each child, in order, it writes one border-box
//! rectangle and then advances `cursor_y` by that child's margin box. Those rectangles are
//! the instance `x, y, width, height` drawn by `draw.zig`.
//!
//! `fixed` is an explicit span in logical pixels. `fill` on the width uses the inner width
//! after that child's horizontal margins. `fill` on the height uses an equal share of the
//! leftover main-axis space, computed before any child is placed.
//!
//! ## 3. The box algebra (logical pixels, top-left, Y down)
//! Layout operates in the same UI logical coordinate space as `draw.ortho_y_down`. Coordinates
//! and spans use `f32` throughout. `paint_column` converts the `u32` logical window dimensions
//! once upon entry.
//!
//! ```text
//! margin box = cursor advance (includes margin.top, height, margin.bottom)
//! border box = margin box inset by child's margin   <- Instance rectangle sent to GPU
//! inner rect = column rect inset by column padding  <- bounded region where children walk
//! ```
//!
//! Padding lives on the column container, not on leaf children. A leaf child's padding would
//! shrink its painted face by the exact amount a larger margin would, making the two
//! indistinguishable. Column padding insets the first child and shortens the span available
//! to a `fill`. The rendered instance is the border box: child margins sit outside it, and
//! the column padding defines the inner rectangle those border boxes walk in.
//!
//! For column rectangle `(X, Y, W, H)` and container padding `P`, flow is strictly downward:
//!
//! ```text
//! inner_x   = X + P.left
//! inner_y   = Y + P.top
//! inner_w   = W - P.left - P.right
//! inner_h   = H - P.top - P.bottom
//!
//! fixed_sum = sum of (margin.top + margin.bottom + fixed_height) for all children
//!             a fill height contributes 0 to fixed_sum; its margins still count
//! fill_n    = number of children whose height is fill
//! leftover  = inner_h - fixed_sum
//! share     = max(leftover, 0) / fill_n     // 0 fills means share is 0 (no division)
//!
//! per child, evaluated sequentially in downward order:
//! avail_w   = inner_w - margin.left - margin.right
//! width     = fixed_width, or avail_w when width is fill
//! height    = fixed_height, or share when height is fill
//! slack_x   = max(avail_w - width, 0)
//! x         = inner_x + margin.left + align_x * slack_x
//! y         = cursor_y + margin.top
//! cursor_y += margin.top + height + margin.bottom
//! ```
//!
//! `cursor_y` initializes to `inner_y`. The alignment ratio `align_x` lies in `[0.0, 1.0]`:
//! 0.0 aligns left, 0.5 centers, and 1.0 aligns right. It positions a `fixed` width within
//! positive horizontal slack (`slack_x`). A `fill` width expands to `avail_w`, leaving zero
//! slack, so `align_x` has no effect. Flow is downward, so there is no per-child vertical
//! alignment. A fixed size exceeding available space is not clamped. Negative horizontal
//! slack is clamped to 0 by `positive_slack`, preventing children from shifting backward.
//! Any overflowing geometry is naturally clipped by the viewport frustum.
//!
//! When several children have `fill` height, they split `leftover` equally.
//!
//! A non-positive width or height (e.g. from extreme padding or zero window bounds) is still
//! computed and stored into `out` by `place_column`, and `cursor_y` still advances by that
//! child's margin box. This preserves spacing so subsequent siblings do not jump upward.
//! However, `paint_column` filters out non-positive rectangles and does not append them to the
//! draw list. `DrawList.append` rejects non-positive edges, and a degenerate or 1x1 window must
//! never trigger an error in the render loop.
//!
//! ## 4. Demo Scene and Worked Numerical Derivations
//! The standard demo scene consists of a root window column and three child panels:
//! - Root Column: bounds `(0, 0, width_logical, height_logical)`, padding 16 on all edges.
//! - Header: width `fill`, height `fixed 64`, margin 0, radius 8, hover 0.
//! - Body: width `fill`, height `fill`, margin top 16, radius 16, hover 0.
//! - Footer: width `fixed 240`, height `fixed 48`, margin top 16, align_x 1.0, radius 24, hover 1.
//!
//! ### Worked Case 1: Default 1280 x 720 Window
//! - Column Rect: `(0, 0, 1280, 720)`. Padding: left 16, top 16, right 16, bottom 16.
//! - Inner Rect: `x = 16`, `y = 16`, `w = 1248`, `h = 688`.
//! - Fixed Cost Pass (`column_fixed_cost`):
//!   - Header: margin top 0, margin bottom 0, height 64 -> cost = 64.
//!   - Body: margin top 16, margin bottom 0, height fill -> cost = 16, fill_count = 1.
//!   - Footer: margin top 16, margin bottom 0, height 48 -> cost = 16 + 48 = 64.
//!   - Total `fixed_sum = 64 + 16 + 64 = 144`.
//! - Main Axis Leftover & Share:
//!   - `leftover = 688 - 144 = 544`.
//!   - `share = 544 / 1 = 544`.
//! - Placement Pass (`place_walks`):
//!   - `cursor_y` begins at `inner_y = 16`.
//!   - Header: `avail_w = 1248 - 0 = 1248`. `width = 1248`. `height = 64`.
//!     `slack_x = max(1248 - 1248, 0) = 0`.
//!     `x = 16 + 0 + 0 = 16`, `y = 16 + 0 = 16`.
//!     Rect = `(16, 16, 1248, 64)`.
//!     `cursor_y += 0 + 64 + 0 = 64` -> `cursor_y = 80`.
//!   - Body: `avail_w = 1248`. `width = 1248`. `height = share = 544`.
//!     `slack_x = 0`.
//!     `x = 16`, `y = 80 + 16 = 96`.
//!     Rect = `(16, 96, 1248, 544)`.
//!     `cursor_y += 16 + 544 + 0 = 560` -> `cursor_y = 80 + 560 = 640`.
//!   - Footer: `avail_w = 1248`. `width = 240`. `height = 48`.
//!     `slack_x = max(1248 - 240, 0) = 1008`.
//!     `x = 16 + 0 + 1.0 * 1008 = 1024`.
//!     `y = 640 + 16 = 656`.
//!     Rect = `(1024, 656, 240, 48)`.
//!     `cursor_y += 16 + 48 + 0 = 64` -> `cursor_y = 704`.
//!     Bottom margin check: `704 + 16 (padding.bottom) = 720` (exact window boundary).
//!
//! ### Worked Case 2: 800 x 600 Window
//! - Column Rect: `(0, 0, 800, 600)`. Inner: `x = 16, y = 16, w = 768, h = 568`.
//! - `leftover = 568 - 144 = 424`. Body height = 424.
//! - Header: `(16, 16, 768, 64)`.
//! - Body: `(16, 96, 768, 424)`.
//! - Footer: `avail_w = 768`, `slack_x = 768 - 240 = 528`.
//!   `x = 16 + 528 = 544`, `y = 536`. Rect = `(544, 536, 240, 48)`.
//!
//! ### Worked Case 3: Degenerate 1 x 1 Window
//! - Column Rect: `(0, 0, 1, 1)`. Padding: 16 each side.
//! - `inner_w = 1 - 32 = -31`, `inner_h = 1 - 32 = -31`.
//! - `leftover = -31 - 144 = -175 <= 0` -> `share = 0`.
//! - Header: `width = -31 <= 0` -> filtered by `paint_column`.
//! - Body: `width = -31 <= 0`, `height = 0 <= 0` -> filtered by `paint_column`.
//! - Footer: `width = 240 > 0`, `height = 48 > 0`. `slack_x = max(-31 - 240, 0) = 0`.
//!   `x = 16 + 0 + 1.0 * 0 = 16`. `cursor_y` advanced past header (64) and body (16) ->
//!   `y = 16 + 80 + 16 = 112`.
//!   Both dimensions are strictly positive, so the footer is appended to the draw list.
//!   Result: Exactly 2 instances drawn (the 1x1 root window rect and the 240x48 footer).
//!
//! ## 5. Two passes, then the relayout flag
//! Layout executes in two bounded passes:
//! 1. `column_fixed_cost`: Accumulates fixed main-axis vertical margins and heights, and
//!    counts `fill` children.
//! 2. `place_walks`: Resolves per-child widths and heights, computes horizontal slack, and
//!    emits the final border boxes.
//! Both passes are statically bounded by `child_cap`. There is no recursion, no dynamic
//! list growth, and zero heap allocation.
//!
//! Presentation pacing is governed by `Frame.relayout`:
//! - A window resize or configure event with changed dimensions sets both `redraw` and `relayout`.
//! - When `relayout` is set, `present_if_dirty` (native) or `tick` (wasm) calls `paint_column`,
//!   which clears the `DrawList` (incrementing `DrawList.revision`) and writes new rectangles.
//!   `mark_laid_out()` then resets `relayout = false`.
//! - A display scale change sets `redraw` to re-render the swapchain texture, but leaves
//!   `relayout` false. Because logical UI coordinates are unchanged, the existing instance
//!   rectangles remain valid. Skipping `paint_column` prevents clearing the draw list and avoids
//!   incrementing `revision`, so `UploadCursor.flags` reports 0 for instances and avoids
//!   redundant GPU vertex buffer transfers.
//!
//! ## 6. TigerStyle bounds and safety invariants
//! - **Capacity Bounds:** `child_cap = instance_cap - 1` (255) because the root column
//!   rectangle takes one slot in the fixed 256-instance draw list (`draw.instance_cap`).
//! - **Static Memory:** Walks and output rectangles are caller-provided fixed slices.
//!   Zero heap allocation or dynamic reallocation occurs during layout.
//! - **Defensive Assertions:** Insets and fixed sizes must be non-negative. Alignment ratios
//!   must reside within `[0.0, 1.0]`. Preconditions and postconditions use split assertions.
//! - **Comptime Locking:** The static demo table properties (dimensions, margins, alignments,
//!   paints) are asserted in a `comptime` block against unintended changes.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");

/// The maximum number of child walks permitted in a single column layout.
/// Equals `draw.instance_cap - 1` (255) because the root column rectangle occupies
/// the first slot in the draw list.
pub const child_cap: u32 = draw.instance_cap - 1;

/// An axis-aligned border box in UI logical pixels. Origin is the top-left; Y grows downward.
pub const Rect = struct {
    /// Left edge in logical pixels.
    x: f32,
    /// Top edge in logical pixels.
    y: f32,
    /// Horizontal span in logical pixels.
    width: f32,
    /// Vertical span in logical pixels.
    height: f32,
};

/// Independent left, top, right, and bottom insets, in UI logical pixels.
/// Used for column padding and child margins. Negative values trigger assertions.
pub const Inset = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// Axis sizing policy for a walk.
/// - `fixed`: Explicit span in logical pixels. A negative value is a programmer error.
/// - `fill`: On the width, the inner width after this child's horizontal margins.
///   On the height, an equal share of the leftover main-axis space.
pub const Size = union(enum) {
    fixed: f32,
    fill,
};

/// Layout specifications for a single child within a vertical column.
/// The cursor consumes the margin box; the emitted rectangle is the border box.
/// `align_x` in [0.0, 1.0] positions fixed-width children within positive horizontal slack.
pub const Walk = struct {
    /// Inset surrounding the child's border box in logical pixels.
    margin: Inset,
    /// Sizing mode along the cross axis (horizontal).
    width: Size,
    /// Sizing mode along the main axis (vertical).
    height: Size,
    /// Horizontal alignment ratio in [0.0, 1.0]: 0.0 is left, 0.5 is centered, 1.0 is right.
    /// Only active for fixed-width walks with positive horizontal slack.
    align_x: f32,
};

/// The parent bounding rectangle and the padding insetting the area where children walk.
pub const Column = struct {
    /// Outer bounding rectangle in logical pixels.
    rect: Rect,
    /// Inner padding insetting the child layout area.
    padding: Inset,
};

const AxisCost = struct {
    sum: f32,
    fill_count: u32,
};

const Paint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    hover: f32,
};

const Panel = struct {
    walk: Walk,
    paint: Paint,
};

const panel_count: u32 = 3;

const zero_inset: Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

const column_padding: Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };

const column_paint: Paint = .{
    .r = 0.18,
    .g = 0.19,
    .b = 0.24,
    .a = 1,
    .radius = 0,
    .hover = 0,
};

/// Header, body, and footer. The body is the fill that grows with the window.
/// The footer keeps a fixed width and sits on the right.
const panels: [panel_count]Panel = .{
    .{
        .walk = .{
            .margin = zero_inset,
            .width = .fill,
            .height = .{ .fixed = 64 },
            .align_x = 0,
        },
        .paint = .{
            .r = 0.24,
            .g = 0.32,
            .b = 0.42,
            .a = 1,
            .radius = 8,
            .hover = 0,
        },
    },
    .{
        .walk = .{
            .margin = .{ .left = 0, .top = 16, .right = 0, .bottom = 0 },
            .width = .fill,
            .height = .fill,
            .align_x = 0,
        },
        .paint = .{
            .r = 0.20,
            .g = 0.26,
            .b = 0.34,
            .a = 1,
            .radius = 16,
            .hover = 0,
        },
    },
    .{
        .walk = .{
            .margin = .{ .left = 0, .top = 16, .right = 0, .bottom = 0 },
            .width = .{ .fixed = 240 },
            .height = .{ .fixed = 48 },
            .align_x = 1,
        },
        .paint = .{
            .r = 0.30,
            .g = 0.46,
            .b = 0.70,
            .a = 1,
            .radius = 24,
            .hover = 1,
        },
    },
};

comptime {
    assert(panel_count == 3);
    assert(panel_count <= child_cap);
    assert(child_cap == draw.instance_cap - 1);
    assert(column_padding.left == 16);
    assert(column_padding.top == 16);
    assert(column_padding.right == 16);
    assert(column_padding.bottom == 16);
    assert(column_paint.radius == 0);
    assert(column_paint.hover == 0);
    assert(panels[0].walk.width == .fill);
    assert(panels[0].walk.height.fixed == 64);
    assert(panels[0].walk.margin.top == 0);
    assert(panels[0].walk.margin.bottom == 0);
    assert(panels[0].paint.radius == 8);
    assert(panels[1].walk.width == .fill);
    assert(panels[1].walk.height == .fill);
    assert(panels[1].walk.margin.top == 16);
    assert(panels[1].walk.margin.bottom == 0);
    assert(panels[1].paint.radius == 16);
    assert(panels[2].walk.width.fixed == 240);
    assert(panels[2].walk.height.fixed == 48);
    assert(panels[2].walk.margin.top == 16);
    assert(panels[2].walk.align_x == 1);
    assert(panels[2].paint.radius == 24);
    assert(panels[2].paint.hover == 1);
}

/// Resolves layout for a sequence of child walks inside a parent column container,
/// writing resulting border-box rectangles into `out`.
///
/// Preconditions:
/// - `walks.len` must equal `out.len`.
/// - `walks.len` must not exceed `child_cap` (255).
/// - `column.padding` components must be non-negative.
/// - Every walk must have non-negative margins, valid sizes, and `align_x` in [0.0, 1.0].
///
/// Non-Positive Dimensions:
/// If container padding or child margins exceed available dimensions, or if a child's
/// resolved size is non-positive, the resulting rectangle is still stored in `out`, and
/// the main-axis cursor still advances by that child's margin box. This guarantees stable
/// downward positioning for subsequent siblings.
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

/// Executes layout for the standard demo scene and populates `list` with instances.
///
/// Coordinate Frame & Units:
/// - `width_logical` and `height_logical` are window dimensions in UI logical pixels,
///   matching the space used by the orthographic projection matrix (`draw.ortho_y_down`).
///
/// Lifecycle:
/// 1. Clears `list`, resetting `list.count = 0` and incrementing `list.revision`.
/// 2. Creates a full-window root column `(0, 0, width_logical, height_logical)` with
///    16px padding on all sides.
/// 3. Appends the background column instance (with radius 0, hover 0).
/// 4. Executes two-pass layout (`place_column`) for the 3 demo child panels (header, body, footer).
/// 5. Appends each child panel whose width and height are both strictly positive. Any child
///    with a zero or negative edge is safely skipped so degenerate windows (such as 1x1) do not
///    trigger errors or fail presentation.
pub fn paint_column(list: *draw.DrawList, width_logical: u32, height_logical: u32) void {
    assert(width_logical != 0);
    assert(height_logical != 0);
    assert(list.count <= draw.instance_cap);
    list.clear();
    assert(list.count == 0);
    const column = window_column(width_logical, height_logical);
    append_paint(list, column.rect, column_paint);
    var rects: [panel_count]Rect = undefined;
    const walks = demo_walks();
    place_column(column, &walks, &rects);
    append_panels(list, &rects);
    assert(list.count >= 1);
    assert(list.count <= 1 + panel_count);
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

fn window_column(width_logical: u32, height_logical: u32) Column {
    assert(width_logical != 0);
    assert(height_logical != 0);
    return .{
        .rect = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width_logical),
            .height = @floatFromInt(height_logical),
        },
        .padding = column_padding,
    };
}

fn demo_walks() [panel_count]Walk {
    var walks: [panel_count]Walk = undefined;
    var index: u32 = 0;
    while (index < panel_count) : (index += 1) {
        walks[index] = panels[index].walk;
    }
    assert(walks[0].height == .fixed);
    assert(walks[2].align_x == 1);
    return walks;
}

fn append_panels(list: *draw.DrawList, rects: *const [panel_count]Rect) void {
    assert(list.count == 1);
    var index: u32 = 0;
    while (index < panel_count) : (index += 1) {
        const rect = rects[index];
        if (rect.width <= 0) {
            assert(rect.width <= 0);
            continue;
        }
        if (rect.height <= 0) {
            assert(rect.height <= 0);
            continue;
        }
        append_paint(list, rect, panels[index].paint);
    }
    assert(list.count >= 1);
    assert(list.count <= 1 + panel_count);
}

fn append_paint(list: *draw.DrawList, rect: Rect, paint: Paint) void {
    assert(rect.width > 0);
    assert(rect.height > 0);
    list.append(.{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
        .r = paint.r,
        .g = paint.g,
        .b = paint.b,
        .a = paint.a,
        .radius = paint.radius,
        .hover = paint.hover,
        .pad0 = 0,
        .pad1 = 0,
    }) catch unreachable;
    assert(list.count >= 1);
    assert(list.count <= draw.instance_cap);
}

fn expect_box(instance: draw.Instance, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, instance.x);
    try std.testing.expectEqual(y, instance.y);
    try std.testing.expectEqual(width, instance.width);
    try std.testing.expectEqual(height, instance.height);
}

// Verifies the worked numerical derivation for the 3-panel demo layout at default 1280x720:
// - Root column: (0, 0, 1280, 720) with 16px padding on all sides.
// - Header: (16, 16, 1248, 64) with radius 8.
// - Body: (16, 96, 1248, 544) with radius 16, receiving the 544px leftover height.
// - Footer: (1024, 656, 240, 48) with radius 24 and hover 1.0, right-aligned (align_x = 1.0).
test "column at 1280 by 720" {
    var list = draw.DrawList.init();
    paint_column(&list, 1280, 720);
    try std.testing.expectEqual(@as(u32, 4), list.count);
    try expect_box(list.items[0], 0, 0, 1280, 720);
    try expect_box(list.items[1], 16, 16, 1248, 64);
    try expect_box(list.items[2], 16, 96, 1248, 544);
    try expect_box(list.items[3], 1024, 656, 240, 48);
    try std.testing.expectEqual(@as(f32, 704), list.items[3].y + list.items[3].height);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].radius);
    try std.testing.expectEqual(@as(f32, 8), list.items[1].radius);
    try std.testing.expectEqual(@as(f32, 16), list.items[2].radius);
    try std.testing.expectEqual(@as(f32, 24), list.items[3].radius);
    try std.testing.expectEqual(@as(f32, 1), list.items[3].hover);
}

// Verifies layout adaptation on window resize to 800x600:
// - Header: shrinks in width to 768px.
// - Body: leftover height contracts to 424px (568 inner height - 144 fixed cost).
// - Footer: positioned at x = 544 (16 inner_x + 528 horizontal slack).
test "column at 800 by 600" {
    var list = draw.DrawList.init();
    paint_column(&list, 800, 600);
    try std.testing.expectEqual(@as(u32, 4), list.count);
    try expect_box(list.items[0], 0, 0, 800, 600);
    try expect_box(list.items[1], 16, 16, 768, 64);
    try expect_box(list.items[2], 16, 96, 768, 424);
    try expect_box(list.items[3], 544, 536, 240, 48);
    try std.testing.expectEqual(@as(f32, 584), list.items[3].y + list.items[3].height);
    try std.testing.expectEqual(@as(f32, 240), list.items[3].width);
}

// Verifies that multiple fill children divide available leftover main-axis space equally.
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

// Verifies that align_x = 0.5 centers a fixed-width child within positive horizontal slack.
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

// Verifies that column padding insets child origin and reduces available width for fills.
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

// Verifies that child margins advance cursor_y outside the child's emitted border box.
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

// Verifies degenerate 1x1 window handling: children with non-positive edges are omitted from
// the draw list while positive-dimension fixed children (the footer) are retained.
test "a 1 by 1 window keeps the column and the fixed footer" {
    var list = draw.DrawList.init();
    paint_column(&list, 1, 1);
    try std.testing.expectEqual(@as(u32, 2), list.count);
    try expect_box(list.items[0], 0, 0, 1, 1);
    try expect_box(list.items[1], 16, 112, 240, 48);
    try std.testing.expectEqual(@as(f32, 24), list.items[1].radius);
    try std.testing.expectEqual(@as(f32, 1), list.items[1].hover);
}

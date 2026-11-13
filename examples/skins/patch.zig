//! The patch: three object boxes, their ports, three dashed cables, the cables' value pills,
//! and the flow of the dashes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! The boxes are parameter cells (`looks.Skin.knob`) at fixed rects (`boxes`). Their ports are
//! `port_side` squares centred on the boxes' top (inlets) and bottom (outlets) edges, in
//! `colors.value`, in every look: they are where cables end, so they belong with the
//! cables, not with the cell skin, which also draws the panels' cells.
//! ```text
//! cable 1   A outlet 0 -> B inlet 0   cubic, controls cubic_pull below and above   pill
//! cable 2   B outlet 0 -> C inlet 0   cubic                                        pill
//! cable 3   A outlet 1 -> C inlet 1   route(): right angles, rounded corners        no pill
//! ```
//!
//! ## 2. `route`
//! Down from `a` to `mid_y = (a.y + b.y) / 2`, across to `b.x`, down to `b`. Each corner is a
//! quarter circle of `r = min(radius, |b.x - a.x| / 2, |b.y - a.y| / 4)` flattened into
//! `corner_segments` segments from a comptime table of `(cos, sin)`: `a`, five points a
//! corner, `b`, so `route_points_max` is 12. With `a.x == b.x` it is the two end points.
//!
//! ## 3. Dashes and Flow
//! Every cable is a `draw.path` stroke `cable_width` wide, dashed `dash_on` on and `dash_off`
//! off with round ends (step 65), unless its look marks it solid (`Look.cables_solid`). `kit.stroke` draws solid, so the cables call `draw.path`
//! directly. The dashes flow toward the cables' ends when the app lowers the offset:
//! ```text
//! flow_offset(elapsed_ms) = (elapsed_ms mod flow_period_ms) * flow_px_per_ms   in [0, 7)
//! Dash.offset             = -flow_offset(elapsed_ms)
//! ```
//! The remainder is taken in integers first, so the offset is exact at any uptime and a frame's
//! cost cannot grow with it; one pattern period passes every `flow_period_ms`.
//!
//! ## 4. Pills
//! A pill sits at `pill_t` along its cubic on `pill_layer`, over the cables: a
//! `pill_h` high capsule in `colors.background` with a `hairline` border in the cable's colour,
//! the value in the scheme's value face at `pill_text_size` in the cable's colour. On the base layer
//! a pill's Box would draw under every Path, because a layer's batches draw where their type
//! first appeared.
//!
//! ## 5. TigerStyle Invariants
//! - `route` writes into a fixed array and returns the count; no allocation.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const kit = patchwork.widgets.kit;
const looks = @import("looks.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.Point;

/// The layer of the pills and their text, over the cables on the base layer (section 4).
pub const pill_layer: quads.Layer = @fromBackingInt(1);

pub const box_count: u32 = 3;
/// The object boxes A, B, and C: osc~, lpf~, dac~.
pub const boxes = [box_count]Rect{
    .{ .x = 688, .y = 136, .width = 144, .height = 28 },
    .{ .x = 944, .y = 280, .width = 144, .height = 28 },
    .{ .x = 720, .y = 520, .width = 144, .height = 28 },
};
pub const box_names = [box_count][]const u8{ "osc~", "lpf~", "dac~" };

pub const port_side: f32 = 6;
/// A port's centre from its box's left edge.
pub const port_inset: f32 = 8;
/// The six ports' centres: A's outlets 0 and 1, B's inlet and outlet, C's inlets 0 and 1.
pub const ports = [6]Point{
    outlet(0, port_inset),
    outlet(0, boxes[0].width - port_inset),
    inlet(1, port_inset),
    outlet(1, port_inset),
    inlet(2, port_inset),
    inlet(2, port_inset + 128),
};

fn outlet(box: u32, x: f32) Point {
    return .{ boxes[box].x + x, boxes[box].y + boxes[box].height };
}

fn inlet(box: u32, x: f32) Point {
    return .{ boxes[box].x + x, boxes[box].y };
}

pub const Kind = enum(u8) { cubic, routed };

pub const Cable = struct {
    from: Point,
    to: Point,
    kind: Kind,
    /// The value its pill shows, or none.
    pill: ?[]const u8,
};

pub const cables = [3]Cable{
    .{ .from = ports[0], .to = ports[2], .kind = .cubic, .pill = "0.45" },
    .{ .from = ports[3], .to = ports[4], .kind = .cubic, .pill = "0.80" },
    .{ .from = ports[1], .to = ports[5], .kind = .routed, .pill = null },
};

pub const cable_width: f32 = 1.5;
pub const dash_on: f32 = 4;
pub const dash_off: f32 = 3;
/// How far a cubic's control points pull below the outlet and above the inlet.
pub const cubic_pull: f32 = 80;
/// The routed cable's corner radius.
pub const corner_radius: f32 = 12;

/// Where along its cubic a pill sits: a third of the way, not the middle, because both cubics'
/// middles lie on the routed cable (x 824 and 840 against its verticals at 824 and 856).
pub const pill_t: f32 = 0.3;
pub const pill_h: f32 = 16;
pub const pill_pad_x: f32 = 6;
pub const pill_text_size: f32 = 11;

pub const flow_period_ms: u64 = 350;
pub const flow_px_per_ms: f32 = 0.02;

comptime {
    assert(ports.len == 6);
    assert(@as(f32, @floatFromInt(flow_period_ms)) * flow_px_per_ms == dash_on + dash_off);
    assert(ports[0][0] == 696 and ports[0][1] == 164);
    assert(ports[1][0] == 824);
    assert(ports[5][0] == 856 and ports[5][1] == 520);
}

/// The dash offset after `elapsed_ms` of flow, in `[0, dash_on + dash_off)` (section 3).
pub fn flow_offset(elapsed_ms: u64) f32 {
    const offset = @as(f32, @floatFromInt(elapsed_ms % flow_period_ms)) * flow_px_per_ms;
    assert(offset >= 0);
    assert(offset < dash_on + dash_off);
    return offset;
}

pub const corner_segments: u32 = 4;
pub const route_points_max: u32 = 2 + 2 * (corner_segments + 1);

/// `(cos, sin)` at 0, 22.5, 45, 67.5, and 90 degrees.
const turns: [corner_segments + 1][2]f32 = blk: {
    var table: [corner_segments + 1][2]f32 = undefined;
    for (&table, 0..) |*entry, index| {
        const angle = @as(f64, @floatFromInt(index)) * std.math.pi / 2.0 / corner_segments;
        entry.* = .{ @floatCast(@cos(angle)), @floatCast(@sin(angle)) };
    }
    table[0] = .{ 1, 0 };
    table[corner_segments] = .{ 0, 1 };
    break :blk table;
};

/// The routed cable from `a` down to `b` (section 2) into `out`; returns the point count.
pub fn route(a: Point, b: Point, radius: f32, out: *[route_points_max]Point) u32 {
    assert(b[1] > a[1]);
    assert(radius > 0);
    out[0] = a;
    if (a[0] == b[0]) {
        out[1] = b;
        return 2;
    }
    const dx = b[0] - a[0];
    const side: f32 = if (dx > 0) 1 else -1;
    const r = @min(radius, @abs(dx) / 2, (b[1] - a[1]) / 4);
    const mid_y = (a[1] + b[1]) / 2;
    const first: Point = .{ a[0] + side * r, mid_y - r };
    const second: Point = .{ b[0] - side * r, mid_y + r };
    for (turns, 0..) |turn, index| {
        out[1 + index] = .{ first[0] - side * r * turn[0], first[1] + r * turn[1] };
        out[2 + corner_segments + index] = .{ second[0] + side * r * turn[1], second[1] - r * turn[0] };
    }
    out[route_points_max - 1] = b;
    assert(out[corner_segments + 1][1] == mid_y);
    return route_points_max;
}

/// A cubic cable's four control points (section 1).
pub fn cubic_of(cable: Cable) [4]Point {
    assert(cable.kind == .cubic);
    assert(cable.to[1] != cable.from[1]);
    return .{
        cable.from,
        .{ cable.from[0], cable.from[1] + cubic_pull },
        .{ cable.to[0], cable.to[1] - cubic_pull },
        cable.to,
    };
}

/// The point at `t` of a cubic.
pub fn cubic_at(control: [4]Point, t: f32) Point {
    assert(t >= 0 and t <= 1);
    const u = 1 - t;
    const weights = [4]f32{ u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t };
    var out: Point = .{ 0, 0 };
    for (control, weights) |point, weight| {
        out[0] += point[0] * weight;
        out[1] += point[1] * weight;
    }
    assert(out[0] == out[0]);
    return out;
}

/// The six ports, `port_side` squares in `colors.value`.
pub fn draw_ports(cx: anytype, clip: Clip) void {
    const color = cx.theme().colors.value;
    assert(color[3] >= 0);
    for (ports) |centre| {
        const square: Rect = .{
            .x = centre[0] - port_side / 2,
            .y = centre[1] - port_side / 2,
            .width = port_side,
            .height = port_side,
        };
        kit.face(cx, square, clip, .{ .fill = color });
    }
}

/// The three cables in `look`'s colours, dashed and flowing by `offset` (section 3).
pub fn draw_cables(cx: anytype, look: *const looks.Look, offset: f32, clip: Clip) void {
    assert(offset >= 0);
    assert(offset < dash_on + dash_off);
    for (cables, look.cables, look.cables_solid) |cable, color, solid| {
        const dash: quads.path.Dash = .{ .on = dash_on, .off = dash_off, .offset = -offset };
        const stroke: quads.path.Stroke = .{
            .color = color,
            .width = cable_width,
            .hover = 0,
            .dash = if (solid) null else dash,
        };
        switch (cable.kind) {
            .cubic => _ = quads.path.cubic(cx.drawing(), cubic_of(cable), stroke, clip),
            .routed => {
                var points: [route_points_max]Point = undefined;
                const count = route(cable.from, cable.to, corner_radius, &points);
                _ = quads.path.polyline(cx.drawing(), points[0..count], stroke, clip);
            },
        }
    }
}

/// The pills of the cubic cables on `pill_layer` (section 4).
pub fn draw_pills(cx: anytype, look: *const looks.Look, clip: Clip) void {
    const scheme = cx.theme();
    var style = scheme.value;
    style.size = pill_text_size;
    const previous = cx.drawing().layer(pill_layer);
    defer _ = cx.drawing().layer(previous);
    for (cables, look.cables) |cable, color| {
        const value = cable.pill orelse continue;
        style.color = color;
        const rect = pill_rect(cubic_at(cubic_of(cable), pill_t), text.measure(style, value));
        kit.face(cx, rect, clip, .{
            .fill = scheme.colors.background,
            .border_color = color,
            .border_width = scheme.form.hairline,
            .radius = pill_h / 2,
        });
        kit.label(cx, style, value, rect, clip, kit.centered);
    }
    assert(cx.drawing().layer_now == pill_layer);
}

/// A pill `text_w` of text wide centred on `centre`, its edges on whole pixels.
pub fn pill_rect(centre: Point, text_w: f32) Rect {
    assert(text_w >= 0);
    const width = @ceil(text_w) + 2 * pill_pad_x;
    const rect: Rect = .{
        .x = @round(centre[0] - width / 2),
        .y = @round(centre[1] - pill_h / 2),
        .width = width,
        .height = pill_h,
    };
    assert(rect.height == pill_h);
    return rect;
}

// Locks `route` (section 2): two rounded corners from (700, 160) to (900, 300) at radius 12 make
// 12 points, mid y 230; corner 1 runs from (700, 218) to (712, 230) around (712, 218), corner 2
// from (888, 230) to (900, 242) around (888, 242), every corner point 12 px from its centre; a
// 10 px offset clamps the radius to 5; a straight drop is two points.
test "route turns two rounded corners" {
    var points: [route_points_max]Point = undefined;
    const count = route(.{ 700, 160 }, .{ 900, 300 }, 12, &points);
    try std.testing.expectEqual(@as(u32, 12), count);
    try std.testing.expectEqual(Point{ 700, 160 }, points[0]);
    try std.testing.expectEqual(Point{ 900, 300 }, points[11]);
    try std.testing.expectEqual(Point{ 700, 218 }, points[1]);
    try std.testing.expectEqual(Point{ 712, 230 }, points[5]);
    try std.testing.expectEqual(Point{ 888, 230 }, points[6]);
    try std.testing.expectEqual(Point{ 900, 242 }, points[10]);
    for (points[1..6]) |point| {
        try std.testing.expectApproxEqAbs(@as(f32, 12), std.math.hypot(point[0] - 712, point[1] - 218), 1e-4);
    }
    for (points[6..11]) |point| {
        try std.testing.expectApproxEqAbs(@as(f32, 12), std.math.hypot(point[0] - 888, point[1] - 242), 1e-4);
    }
    _ = route(.{ 700, 160 }, .{ 710, 300 }, 12, &points);
    try std.testing.expectEqual(Point{ 705, 230 }, points[5]);
    try std.testing.expectEqual(Point{ 710, 235 }, points[10]);
    try std.testing.expectEqual(@as(u32, 2), route(.{ 700, 160 }, .{ 700, 300 }, 12, &points));
    try std.testing.expectEqual(Point{ 700, 300 }, points[1]);
}

// Locks the flow offset (section 3): it wraps in integers, 0 at 0, 3.68 at 1234 ms, 2 at
// 600,000 ms, 6 at 36,000,250 ms, and never reaches the 7 px period.
test "flow offset wraps in integers" {
    try std.testing.expectEqual(@as(f32, 0), flow_offset(0));
    try std.testing.expectApproxEqAbs(@as(f32, 3.68), flow_offset(1234), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), flow_offset(600_000), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6), flow_offset(36_000_250), 1e-5);
    try std.testing.expect(flow_offset(349) < 7);
    try std.testing.expect(flow_offset(std.math.maxInt(u64)) < 7);
}

// Locks the patch geometry (section 1): A's outlets at x 696 and 824 on its bottom edge (y 164),
// B's inlet at (952, 280), C's inlets at x 728 and 856 on y 520; cable 1's middle is (824, 222),
// on the routed cable, so its pill sits at t 0.3, (751.3, 209.2), 16 high and on whole pixels.
test "ports sit on the boxes' edges" {
    try std.testing.expectEqual(Point{ 696, 164 }, ports[0]);
    try std.testing.expectEqual(Point{ 824, 164 }, ports[1]);
    try std.testing.expectEqual(Point{ 952, 280 }, ports[2]);
    try std.testing.expectEqual(Point{ 952, 308 }, ports[3]);
    try std.testing.expectEqual(Point{ 728, 520 }, ports[4]);
    try std.testing.expectEqual(Point{ 856, 520 }, ports[5]);
    const middle = cubic_at(cubic_of(cables[0]), 0.5);
    try std.testing.expectEqual(Point{ 824, 222 }, middle);
    const at = cubic_at(cubic_of(cables[0]), pill_t);
    try std.testing.expectApproxEqAbs(@as(f32, 751.296), at[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 209.216), at[1], 1e-3);
    const pill = pill_rect(at, 23.2);
    try std.testing.expectEqual(Rect{ .x = 733, .y = 201, .width = 36, .height = 16 }, pill);
}

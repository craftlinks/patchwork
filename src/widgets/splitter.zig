//! `Splitter`: two panes and a draggable divider between them, with minimum pane sizes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! A splitter is a container with the turtle's begin/end shape: the library owns the divider,
//! the geometry, and the input, and the app draws each pane's content between the calls.
//! ```text
//! a = sp.begin(cx, walk)    opens the splitter, then pane a (a clipped free container)
//! ... pane a's content ...
//! b = sp.next(cx)           closes a, draws and records the divider, opens pane b
//! ... pane b's content ...
//! sp.end(cx)                closes b and the splitter
//! ```
//! Each call asserts the stage the last one left (`Stage`), so a missing `next` or `end` fails
//! at the call that broke the order. Panes are containers, so a splitter nests in a pane.
//!
//! ## 2. Geometry
//! For `.horizontal` (panes side by side) over the splitter's rect `r`; `.vertical` (stacked)
//! swaps the axes:
//! ```text
//! span    = max(0, r.width - divider)
//! a_w     = clamp(round(ratio * span), min_a, span - min_b)
//!           when min_a + min_b > span: a_w = span * min_a / (min_a + min_b)
//! pane a  = (r.x, r.y, a_w, r.height)
//! divider = (r.x + a_w, r.y, divider, r.height)           cursor ew_resize (ns_resize)
//! pane b  = (r.x + a_w + divider, r.y, span - a_w, r.height)
//! ```
//! `split` is this, pure; test "splitter geometry clamps to the minimums" locks it.
//!
//! ## 3. Events
//! A press on the divider keeps the pointer's offset from the divider's centre (`grab`), so the
//! divider does not jump; a drag then moves the centre under the pointer:
//! ```text
//! ratio = clamp((pointer - grab - origin - divider / 2) / span, min_a / span, 1 - min_b / span)
//! ```
//! and returns `moved`. Clamping to the minimums at the drag, not only at the draw, leaves no
//! dead zone past a minimum. A double click resets the ratio to `default` (`reset`). The drag
//! needs the splitter's rect, which the divider's `Press.rect` does not carry, so the splitter
//! keeps the rect of its last draw (`drawn`): the one widget that stores a rect.
//!
//! ## 4. Drawing
//! `SplitterOf(Skin)` hands `Skin.divider` a `DividerLook` and records the hit shape it
//! returns under `id.derive(divider_salt)`; `Splitter` is `SplitterOf(skins.Default)`, a thin
//! `colors.control` line down the divider's middle, lightened by hover.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation; every function is O(1). `ratio` stays in `[0, 1]`.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// The divider's thickness across the axis, in logical pixels.
pub const splitter_px: f32 = 6;

/// The default divider line's thickness.
pub const divider_line_px: f32 = 2;

/// The salt of the divider's id: `id.derive(divider_salt)`.
pub const divider_salt: u64 = 0x64697669;

/// How the panes are laid out: `.horizontal` side by side, `.vertical` stacked.
pub const Axis = enum { horizontal, vertical };

/// The three rects of a splitter (section 2).
pub const Panes = struct {
    a: Rect,
    divider: Rect,
    b: Rect,
};

/// Where a splitter is in its begin/next/end sequence (section 1).
pub const Stage = enum { closed, a, b };

/// Pane a's length along the axis for a `span` (section 2).
pub fn pane_a_len(span: f32, ratio: f32, min_a: f32, min_b: f32) f32 {
    assert(span >= 0);
    assert(ratio >= 0 and ratio <= 1);
    assert(min_a >= 0 and min_b >= 0);
    if (min_a + min_b > span) return span * min_a / (min_a + min_b);
    const length = std.math.clamp(@round(ratio * span), min_a, span - min_b);
    assert(length >= 0);
    assert(length <= span);
    return length;
}

/// The panes and the divider of a splitter over `rect` (section 2).
pub fn split(rect: Rect, axis: Axis, ratio: f32, min_a: f32, min_b: f32, divider: f32) Panes {
    assert(divider > 0);
    assert(rect.width >= 0 and rect.height >= 0);
    const along = if (axis == .horizontal) rect.width else rect.height;
    const span = @max(0, along - divider);
    const thick = @min(divider, along);
    const a = pane_a_len(span, ratio, min_a, min_b);
    const panes: Panes = switch (axis) {
        .horizontal => .{
            .a = .{ .x = rect.x, .y = rect.y, .width = a, .height = rect.height },
            .divider = .{ .x = rect.x + a, .y = rect.y, .width = thick, .height = rect.height },
            .b = .{
                .x = rect.x + a + thick,
                .y = rect.y,
                .width = span - a,
                .height = rect.height,
            },
        },
        .vertical => .{
            .a = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = a },
            .divider = .{ .x = rect.x, .y = rect.y + a, .width = rect.width, .height = thick },
            .b = .{ .x = rect.x, .y = rect.y + a + thick, .width = rect.width, .height = span - a },
        },
    };
    assert(panes.a.width >= 0 and panes.b.width >= 0);
    assert(panes.a.height >= 0 and panes.b.height >= 0);
    return panes;
}

/// The ratio a drag gives (section 3): the divider's centre under `pointer` less `grab`, along
/// a span from `origin`, clamped to the minimums (or to `[0, 1]` when they do not fit).
pub fn ratio_at(
    origin: f32,
    span: f32,
    divider: f32,
    grab: f32,
    pointer: f32,
    min_a: f32,
    min_b: f32,
) f32 {
    assert(span > 0);
    assert(divider > 0);
    const raw = (pointer - grab - origin - divider * 0.5) / span;
    const low: f32 = if (min_a + min_b > span) 0 else min_a / span;
    const high: f32 = if (min_a + min_b > span) 1 else 1 - min_b / span;
    const ratio = std.math.clamp(raw, low, high);
    assert(ratio >= 0);
    assert(ratio <= 1);
    return ratio;
}

/// The default splitter: `SplitterOf(skins.Default)`.
pub const Splitter = SplitterOf(skin.Default);

/// The panes' layout: flowing down, clipped to the pane.
pub const pane_layout: ui.Layout = .{ .flow = .down, .clip = true };

/// A two-pane splitter whose divider is drawn by `Skin` (`Skin.divider`; `widgets/skin.zig`).
pub fn SplitterOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .splitter)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        axis: Axis,
        /// Pane a's share of the span, in `[0, 1]`.
        ratio: f32,
        /// The ratio a double click on the divider restores.
        default: f32,
        /// The panes' minimum lengths along the axis, in logical pixels.
        min_a: f32,
        min_b: f32,
        /// The divider's thickness.
        divider: f32,
        hover: animator.Animator,
        stage: Stage,
        /// The splitter's rect at its last draw (section 3).
        drawn: Rect,
        /// The press's offset from the divider's centre, along the axis.
        grab: f32,

        pub const Action = union(enum) {
            none,
            /// The divider moved; the new ratio.
            moved: f32,
            /// A double click restored `default`.
            reset: f32,
        };

        /// A splitter at `ratio` (also its default) with minimum pane lengths.
        pub fn init(id: Id, axis: Axis, ratio: f32, min_a: f32, min_b: f32) Self {
            assert(id != .none);
            assert(ratio >= 0 and ratio <= 1);
            assert(min_a >= 0 and min_b >= 0);
            const splitter: Self = .{
                .id = id,
                .axis = axis,
                .ratio = ratio,
                .default = ratio,
                .min_a = min_a,
                .min_b = min_b,
                .divider = splitter_px,
                .hover = .init(kit.hover_rate_per_ms),
                .stage = .closed,
                .drawn = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .grab = 0,
            };
            assert(splitter.stage == .closed);
            return splitter;
        }

        /// The divider's id.
        pub fn divider_id(self: *const Self) Id {
            assert(self.id != .none);
            return self.id.derive(divider_salt);
        }

        /// The panes of this splitter over `rect`.
        pub fn panes(self: *const Self, rect: Rect) Panes {
            return split(rect, self.axis, self.ratio, self.min_a, self.min_b, self.divider);
        }

        /// Opens the splitter for `walk` (fixed or fill on both axes) and pane a in it; returns
        /// pane a's rect. Draw phase.
        pub fn begin(self: *Self, cx: anytype, walk: Walk) Rect {
            assert(self.stage == .closed);
            assert(walk.width != .fit and walk.height != .fit);
            const rect = cx.begin(walk, .{ .flow = .down });
            self.drawn = rect;
            const pane = self.panes(rect).a;
            _ = cx.begin_at(pane, pane_layout);
            self.stage = .a;
            return pane;
        }

        /// Closes pane a, draws and records the divider, and opens pane b; returns its rect.
        pub fn next(self: *Self, cx: anytype) Rect {
            assert(self.stage == .a);
            _ = cx.end();
            const all = self.panes(self.drawn);
            if (cx.visible(all.divider)) |clip| {
                const look: skin.DividerLook = .{
                    .rect = all.divider,
                    .clip = clip,
                    .axis = self.axis,
                    .hover = self.hover.value,
                };
                if (Skin.divider(cx, look)) |shape| {
                    cx.area(self.divider_id(), shape.rect, shape.radius, self.flags());
                }
            }
            _ = cx.begin_at(all.b, pane_layout);
            self.stage = .b;
            return all.b;
        }

        /// Closes pane b and the splitter.
        pub fn end(self: *Self, cx: anytype) void {
            assert(self.stage == .b);
            _ = cx.end();
            _ = cx.end();
            self.stage = .closed;
        }

        /// Hover, drag, and double click on the divider (section 3).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.stage == .closed);
            assert(self.ratio >= 0 and self.ratio <= 1);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                return .none;
            }
            const hit = cx.hit(self.divider_id(), event);
            kit.respond(cx, hit, &self.hover, null);
            switch (hit) {
                .down => |press| {
                    if (press.clicks >= 2) return self.reset(cx);
                    const centre = self.along(self.divider_rect()) + self.divider * 0.5;
                    self.grab = self.pointer(press) - centre;
                    return .none;
                },
                .drag => |press| {
                    const span = self.span_now();
                    if (!(span > 0)) return .none;
                    const next_ratio = ratio_at(
                        self.along(self.drawn),
                        span,
                        self.divider,
                        self.grab,
                        self.pointer(press),
                        self.min_a,
                        self.min_b,
                    );
                    if (next_ratio == self.ratio) return .none;
                    self.ratio = next_ratio;
                    cx.redraw();
                    return .{ .moved = next_ratio };
                },
                .none, .hover_in, .hover_out, .up, .wheel, .secondary => return .none,
            }
        }

        fn reset(self: *Self, cx: anytype) Action {
            if (self.ratio == self.default) return .none;
            self.ratio = self.default;
            cx.redraw();
            assert(self.ratio == self.default);
            return .{ .reset = self.default };
        }

        /// The span of the last draw: the splitter's length less the divider.
        fn span_now(self: *const Self) f32 {
            const length = if (self.axis == .horizontal) self.drawn.width else self.drawn.height;
            return @max(0, length - self.divider);
        }

        fn divider_rect(self: *const Self) Rect {
            return self.panes(self.drawn).divider;
        }

        /// `rect`'s start along the axis.
        fn along(self: *const Self, rect: Rect) f32 {
            return if (self.axis == .horizontal) rect.x else rect.y;
        }

        fn pointer(self: *const Self, press: ui.Press) f32 {
            return if (self.axis == .horizontal) press.x else press.y;
        }

        fn flags(self: *const Self) ui.Flags {
            return .{
                .wheel = false,
                .focusable = false,
                .tab = false,
                .cursor = if (self.axis == .horizontal) .ew_resize else .ns_resize,
            };
        }
    };
}

comptime {
    assert(splitter_px > divider_line_px);
    assert(divider_salt != ui.view.thumb_salt);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try testing.expectEqual(x, rect.x);
    try testing.expectEqual(y, rect.y);
    try testing.expectEqual(width, rect.width);
    try testing.expectEqual(height, rect.height);
}

// Locks the geometry of section 2: a 1000 px splitter at x 10 with a 6 px divider has a span
// of 994, so ratio 0.3 gives round(298.2) = 298, the divider at 308, and pane b 696 wide; a
// ratio of 0.05 clamps up to min_a 100 and 0.95 down to 994 - 200 = 794; a 206 px splitter
// (span 200) cannot fit 150 + 100 and splits 200 * 150 / 250 = 120; vertical swaps the axes.
test "splitter geometry clamps to the minimums" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 1000, .height = 400 };
    const p = split(rect, .horizontal, 0.3, 100, 200, 6);
    try expect_rect(p.a, 10, 20, 298, 400);
    try expect_rect(p.divider, 308, 20, 6, 400);
    try expect_rect(p.b, 314, 20, 696, 400);
    try testing.expectEqual(@as(f32, 100), split(rect, .horizontal, 0.05, 100, 200, 6).a.width);
    try testing.expectEqual(@as(f32, 794), split(rect, .horizontal, 0.95, 100, 200, 6).a.width);
    const narrow: Rect = .{ .x = 0, .y = 0, .width = 206, .height = 50 };
    const fallback = split(narrow, .horizontal, 0.9, 150, 100, 6);
    try testing.expectEqual(@as(f32, 120), fallback.a.width);
    try testing.expectEqual(@as(f32, 80), fallback.b.width);
    const tall: Rect = .{ .x = 0, .y = 100, .width = 300, .height = 506 };
    const v = split(tall, .vertical, 0.5, 0, 0, 6);
    try expect_rect(v.a, 0, 100, 300, 250);
    try expect_rect(v.divider, 0, 350, 300, 6);
    try expect_rect(v.b, 0, 356, 300, 250);
    // A splitter thinner than its divider: no span, the divider takes what there is.
    const sliver = split(.{ .x = 0, .y = 0, .width = 4, .height = 10 }, .horizontal, 0.5, 0, 0, 6);
    try testing.expectEqual(@as(f32, 0), sliver.a.width);
    try testing.expectEqual(@as(f32, 4), sliver.divider.width);
    try testing.expectEqual(@as(f32, 0), sliver.b.width);
}

// Locks the drag map of section 3: the centre under the pointer less the grab, over the span,
// clamped to the minimums; past them it stays at the bound, so dragging back moves at once.
test "ratio_at keeps the grab and clamps to the minimums" {
    // Origin 10, span 994, divider 6: a pointer at 10 + 3 + 497 = 510 is ratio 0.5.
    try testing.expectEqual(@as(f32, 0.5), ratio_at(10, 994, 6, 0, 510, 0, 0));
    try testing.expectEqual(@as(f32, 0.5), ratio_at(10, 994, 6, 2, 512, 0, 0));
    try testing.expectEqual(@as(f32, 100.0 / 994.0), ratio_at(10, 994, 6, 0, 0, 100, 200));
    const high = @as(f32, 1) - @as(f32, 200) / @as(f32, 994);
    try testing.expectEqual(high, ratio_at(10, 994, 6, 0, 2000, 100, 200));
    try testing.expectEqual(@as(f32, 1), ratio_at(0, 200, 6, 0, 500, 150, 100));
}

/// Draws `splitter` over (0, 0, 1000, 400) with one box in each pane.
fn draw_split(cx: *fixture.Context, splitter: *Splitter) [2]Rect {
    const row_walk = ui.sized(.fill, .{ .fixed = 20 });
    cx.begin_frame(1280, 720, 120);
    const a = splitter.begin(cx, fixture.at(0, 0, 1000, 400));
    kit.face(cx, cx.walk(row_walk), cx.clip().?, .{ .fill = .{ 1, 0, 0, 1 } });
    const b = splitter.next(cx);
    kit.face(cx, cx.walk(row_walk), cx.clip().?, .{ .fill = .{ 0, 1, 0, 1 } });
    splitter.end(cx);
    _ = cx.end_frame();
    return .{ a, b };
}

fn press_at(x: f32, y: f32, time_ms: u32) input.Event {
    return .{ .pointer_down = left_button(x, y, time_ms) };
}

fn release_at(x: f32, y: f32, time_ms: u32) input.Event {
    return .{ .pointer_up = left_button(x, y, time_ms) };
}

fn left_button(x: f32, y: f32, time_ms: u32) input.Button {
    return .{ .x = x, .y = y, .time_ms = time_ms, .button = .left, .mods = .none };
}

// Locks the widget: panes clip their content, the divider records an ew_resize area, a press
// 2 px right of its centre and a drag by -120 move the centre by -120 (ratio (497 - 120) /
// 994 from 0.5), a drag far left stops at min_a, and a double click resets to the default.
test "a splitter drags its divider and resets on a double click" {
    const cx = fixture.context();
    var splitter = Splitter.init(ui.id("split", 0), .horizontal, 0.5, 100, 200);
    const panes = draw_split(cx, &splitter);
    try expect_rect(panes[0], 0, 0, 497, 400);
    try expect_rect(panes[1], 503, 0, 497, 400);
    const boxes = cx.draw.items(draw.Box);
    try testing.expectEqual(@as(f32, 497), boxes[0].clip[2]);
    try testing.expectEqual(@as(f32, 503), boxes[2].clip[0]);
    const area = cx.find(splitter.divider_id()).?;
    try testing.expectEqualSlices(f32, &.{ 497, 0, 6, 400 }, &area.rect);
    try testing.expectEqual(ui.Cursor.ew_resize, area.flags.cursor);
    _ = fixture.send(cx, &splitter, .{ .pointer_move = .{ .x = 502, .y = 50 } });
    try testing.expectEqual(@as(f32, 1), splitter.hover.target);
    _ = fixture.send(cx, &splitter, press_at(502, 50, 0));
    const moved = fixture.send(cx, &splitter, .{ .pointer_move = .{ .x = 382, .y = 50 } });
    try testing.expectEqual(Splitter.Action{ .moved = 377.0 / 994.0 }, moved);
    _ = fixture.send(cx, &splitter, release_at(382, 50, 0));
    _ = draw_split(cx, &splitter);
    try testing.expectEqual(@as(f32, 377), cx.find(splitter.divider_id()).?.rect[0]);
    _ = fixture.send(cx, &splitter, press_at(380, 50, 1000));
    _ = fixture.send(cx, &splitter, .{ .pointer_move = .{ .x = 0, .y = 50 } });
    _ = fixture.send(cx, &splitter, release_at(0, 50, 1000));
    try testing.expectEqual(@as(f32, 100.0 / 994.0), splitter.ratio);
    _ = draw_split(cx, &splitter);
    const at = cx.find(splitter.divider_id()).?.rect[0] + 3;
    _ = fixture.send(cx, &splitter, press_at(at, 50, 3000));
    _ = fixture.send(cx, &splitter, release_at(at, 50, 3000));
    const reset = fixture.send(cx, &splitter, press_at(at, 50, 3100));
    try testing.expectEqual(Splitter.Action{ .reset = 0.5 }, reset);
    _ = fixture.send(cx, &splitter, release_at(at, 50, 3100));
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks nesting and routing: a vertical splitter inside pane b splits it (its divider a
// horizontal strip with the ns_resize cursor), and `ui.route` reaches both splitters.
test "splitters nest in a pane and route" {
    const cx = fixture.context();
    const Pair = struct { outer: Splitter, inner: Splitter };
    var pair: Pair = .{
        .outer = Splitter.init(ui.id("outer", 0), .horizontal, 0.5, 0, 0),
        .inner = Splitter.init(ui.id("inner", 0), .vertical, 0.25, 0, 0),
    };
    cx.begin_frame(1280, 720, 120);
    _ = pair.outer.begin(cx, fixture.at(0, 0, 1006, 406));
    _ = pair.outer.next(cx);
    const top = pair.inner.begin(cx, ui.sized(.fill, .fill));
    _ = pair.inner.next(cx);
    pair.inner.end(cx);
    pair.outer.end(cx);
    _ = cx.end_frame();
    try expect_rect(top, 506, 0, 500, 100);
    const strip = cx.find(pair.inner.divider_id()).?;
    try testing.expectEqualSlices(f32, &.{ 506, 100, 500, 6 }, &strip.rect);
    try testing.expectEqual(ui.Cursor.ns_resize, strip.flags.cursor);
    _ = fixture.send(cx, &pair.inner, press_at(700, 103, 0));
    const move: input.Event = .{ .pointer_move = .{ .x = 700, .y = 203 } };
    cx.event_begin(move);
    try testing.expectEqual(@as(u32, 1), ui.route(cx, move, &pair));
    cx.event_end();
    try testing.expectEqual(@as(f32, 0.5), pair.inner.ratio);
    try testing.expectEqual(@as(f32, 0.5), pair.outer.ratio);
}

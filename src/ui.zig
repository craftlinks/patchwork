//! The UI layer: layout while drawing, hit areas, views, and the three calls hosts make.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Model
//! Layout moves into drawing, as in Makepad: `App.draw` opens containers with `cx.begin`,
//! widgets walk and append instances, and `cx.end` resolves fit sizes and alignment. Nesting
//! is the call structure, so a new screen needs no placement code, and widgets are plain
//! structs the app owns. Widgets record hit areas while drawing; events resolve against the
//! areas of the last frame, which is what the user sees.
//! ```text
//! frame N, draw:   App.draw(cx)
//!                    cx.begin(walk, layout)
//!                      knob.draw(cx, walk): rect = cx.walk(walk); append; cx.area(id, ...)
//!                    cx.end()          fit and alignment resolved, instances shifted
//! frame N+1, event: App.event(cx, event)
//!                    action = knob.handle(cx, event)
//!                      cx.hit(knob.id, event): O(1) against areas[N]
//! ```
//! Widgets return actions (`Knob.Action.changed`), so an app learns which value changed.
//!
//! ## 2. Module Map
//! ```text
//! ui/turtle.zig   pure placement math: Walk, Size, Layout, Flow, fit, alignment deltas
//! ui/areas.zig    Id, Area, the resolve scan, the duplicate-id stamps
//! ui/cx.zig       Context: draw context + turtle stack + areas + pointer, hover, capture
//! ui/view.zig     ViewState, scrollbar geometry, List
//! ui/canvas.zig   CanvasState, the zoom ladder, wheel and drag
//! ui/edit.zig     the single-line editing core: bounded UTF-8 buffer, caret, selection, words,
//!                 and paste sanitizing for one line and the code editor's multi-line text
//! ```
//!
//! ## 3. Host Calls
//! - `dispatch(App, app, cx, event)` resolves the event once (`cx.event_begin`), lets the
//!   app route it to its widgets (`App.event`), and commits capture (`cx.event_end`).
//! - `animate(App, app, cx, dt_ms)` dispatches `.frame` with `cx.animating` cleared first
//!   and returns whether a widget called `cx.keep_animating`, which gates frame callbacks.
//! - `draw_frame(App, app, cx, width, height, scale_120)` draws when `cx.dirty` or the glyph
//!   cache owes a draw, then re-resolves hover under the pointer and dispatches a synthetic
//!   `pointer_move` if it changed (`ui/cx.zig`, section 6).
//! Hosts and app tests use the same three calls, so a test drives exactly what a host does.
//!
//! ## 3a. Routing
//! `App.event` calls each widget's `handle` itself, which is how it learns what changed. For
//! widgets whose result it does not need, `route(cx, event, target)` calls every widget the
//! target names: a widget, a slice or array of widgets, or the fields of a struct (one level,
//! in field order) that are widgets or arrays of widgets. A widget is a type with a
//! three-parameter `handle(self, cx, event)`; `ViewState.handle` takes an id too, so a view is
//! routed by hand. Routing every field of the app (`route(cx, event, app)`) means a widget
//! added to the app is never silently dead. Test "route reaches every widget field" locks it.
//!
//! ## 3b. Overflow Reports
//! After each draw, in builds with runtime safety, both hosts log `cx.overflow_report()`: the
//! instances, areas, and glyphs refused this frame, when that differs from the last report and
//! is not all zero, so a capacity guessed too low shows once, not every frame.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation, no recursion: nesting is bounded by `turtle.depth_max`, areas by the
//!   app's `config.area_cap`.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const input = @import("input.zig");

pub const turtle = @import("ui/turtle.zig");
pub const areas = @import("ui/areas.zig");
pub const view = @import("ui/view.zig");
pub const canvas = @import("ui/canvas.zig");
pub const cx = @import("ui/cx.zig");
pub const edit = @import("ui/edit.zig");

pub const Context = cx.Context;
pub const Rect = draw.Rect;
pub const Inset = draw.Inset;
pub const Walk = turtle.Walk;
pub const Size = turtle.Size;
pub const Layout = turtle.Layout;
pub const Flow = turtle.Flow;
pub const Align = turtle.Align;
pub const Id = areas.Id;
pub const id = areas.id;
pub const Area = areas.Area;
pub const Flags = areas.Flags;
pub const Cursor = areas.Cursor;
pub const Hit = cx.Hit;
pub const Press = cx.Press;
pub const Up = cx.Up;
pub const ViewState = view.ViewState;
pub const CanvasState = canvas.CanvasState;
pub const List = view.List;
pub const zero_inset = turtle.zero_inset;

/// A walk with no margins: `.{ .width = width, .height = height }`.
pub fn sized(width: Size, height: Size) Walk {
    const walk: Walk = .{ .width = width, .height = height };
    assert(walk.margin.left == 0);
    assert(walk.margin.top == 0);
    return walk;
}

/// A layout with no spacing, padding, alignment, or clip, flowing by `flow`:
/// `.{ .flow = flow }`.
pub fn flow_of(flow: Flow) Layout {
    comptime assert(@typeInfo(Flow).@"enum".field_names.len == 3);
    assert(@backingInt(flow) < 3);
    const layout: Layout = .{ .flow = flow };
    assert(layout.spacing == 0);
    assert(!layout.clip);
    return layout;
}

/// Calls `handle(cx, event)` on every widget `target` names and returns how many returned
/// something other than `.none` (module guide, section 3a). `target` is a pointer to a widget,
/// a slice or a pointer to an array of widgets, or a pointer to a struct, whose fields that are
/// widgets or arrays of widgets are routed in field order. A widget is a type with a
/// three-parameter `handle(self, cx, event)` whose result has a `none` tag; other fields are
/// skipped at compile time, and a target that names no widget at all is a compile error.
pub fn route(context: anytype, event: input.Event, target: anytype) u32 {
    const Target = @TypeOf(target);
    const info = @typeInfo(Target);
    if (info != .pointer) {
        @compileError("ui.route: the target must be a pointer, not " ++ @typeName(Target));
    }
    const Child = info.pointer.child;
    if (info.pointer.size == .slice) {
        comptime if (!is_widget(Child)) {
            @compileError("ui.route: " ++ @typeName(Child) ++ " is not a widget");
        };
        return route_each(context, event, target);
    }
    if (comptime is_widget(Child)) return route_one(context, event, target);
    if (comptime is_widgets(Child)) return route_each(context, event, target);
    comptime {
        if (@typeInfo(Child) != .@"struct") {
            @compileError("ui.route: " ++ @typeName(Child) ++ " names no widget");
        }
        var any = false;
        for (@typeInfo(Child).@"struct".field_types) |F| any = any or is_widget(F) or is_widgets(F);
        if (!any) @compileError("ui.route: " ++ @typeName(Child) ++ " has no widget field");
    }
    var acted: u32 = 0;
    const fields = @typeInfo(Child).@"struct";
    inline for (fields.field_names, fields.field_types) |name, F| {
        if (comptime is_widget(F)) acted += route_one(context, event, &@field(target.*, name));
        if (comptime is_widgets(F)) acted += route_each(context, event, &@field(target.*, name));
    }
    return acted;
}

/// True for a type with a three-parameter `handle` (`route`).
fn is_widget(comptime W: type) bool {
    switch (@typeInfo(W)) {
        .@"struct", .@"union", .@"enum" => {},
        else => return false,
    }
    if (!@hasDecl(W, "handle")) return false;
    const handle = @typeInfo(@TypeOf(W.handle));
    if (handle != .@"fn") return false;
    return handle.@"fn".param_types.len == 3;
}

/// True for an array of widgets.
fn is_widgets(comptime W: type) bool {
    const info = @typeInfo(W);
    if (info != .array) return false;
    return is_widget(info.array.child);
}

fn route_one(context: anytype, event: input.Event, widget: anytype) u32 {
    const result = widget.handle(context, event);
    return @intFromBool(result != .none);
}

fn route_each(context: anytype, event: input.Event, widgets: anytype) u32 {
    var acted: u32 = 0;
    for (widgets) |*widget| acted += route_one(context, event, widget);
    return acted;
}

/// Resolves `event` once and lets the app route it. See the module guide, section 3.
pub fn dispatch(comptime App: type, app: *App, context: anytype, event: input.Event) void {
    assert(context.phase == .idle);
    context.event_begin(event);
    App.event(app, context, event);
    context.event_end();
    assert(context.phase == .idle);
}

/// Dispatches `.frame` and returns true while a widget keeps animating.
pub fn animate(comptime App: type, app: *App, context: anytype, dt_ms: f32) bool {
    assert(dt_ms >= 0);
    assert(context.phase == .idle);
    context.animating = false;
    dispatch(App, app, context, .{ .frame = dt_ms });
    return context.animating;
}

/// Draws the app when a draw is owed, then re-resolves hover. Returns true when it drew.
pub fn draw_frame(
    comptime App: type,
    app: *App,
    context: anytype,
    width: u32,
    height: u32,
    scale_120: u32,
) bool {
    assert(width != 0);
    assert(height != 0);
    if (!context.dirty and !context.draw.text.owes_draw(scale_120)) return false;
    context.begin_frame(width, height, scale_120);
    App.draw(app, context);
    if (context.end_frame()) {
        const point: input.Point = .{ .x = context.pointer.x, .y = context.pointer.y };
        dispatch(App, app, context, .{ .pointer_move = point });
    }
    assert(context.draw.text.drawn_scale_120 == scale_120);
    return true;
}

test {
    _ = turtle;
    _ = areas;
    _ = view;
    _ = canvas;
    _ = cx;
    _ = edit;
}

const testing = std.testing;

// Locks the layout defaults: `.{ .flow = flow }` is `flow_of(flow)` for every flow (no spacing,
// padding, alignment, or clip), a walk's margin defaults to zero, and `sized` is the literal.
test "layout and walk defaults equal flow_of and sized" {
    for ([_]Flow{ .right, .down, .overlay }) |flow| {
        const literal: Layout = .{ .flow = flow };
        try testing.expectEqual(flow_of(flow), literal);
        const explicit: Layout = .{
            .flow = flow,
            .spacing = 0,
            .padding = zero_inset,
            .alignment = .{ .x = 0, .y = 0 },
            .clip = false,
        };
        try testing.expectEqual(explicit, literal);
    }
    const walk: Walk = .{ .width = .fill, .height = .{ .fixed = 24 } };
    try testing.expectEqual(zero_inset, walk.margin);
    try testing.expectEqual(sized(.fill, .{ .fixed = 24 }), walk);
    const padded: Layout = .{ .flow = .down, .spacing = 8, .padding = .all(12) };
    try testing.expectEqual(@as(f32, 12), padded.padding.bottom);
}

const Counter = struct {
    hits: u32 = 0,
    acts: bool,

    const Action = enum { none, acted };

    pub fn handle(self: *Counter, context: anytype, event: input.Event) Action {
        _ = context;
        _ = event;
        self.hits += 1;
        return if (self.acts) .acted else .none;
    }
};

const Screen = struct {
    one: Counter,
    row: [3]Counter,
    count: u32,
    view: view.ViewState,
};

// Locks routing (section 3a): a struct's widget field and array field are each handled once
// per event, the count is the handles that acted, and data and a view are skipped.
test "route reaches every widget field" {
    var screen: Screen = .{
        .one = .{ .acts = true },
        .row = .{ .{ .acts = false }, .{ .acts = true }, .{ .acts = false } },
        .count = 7,
        .view = .init(),
    };
    const event: input.Event = .{ .frame = 16 };
    try testing.expectEqual(@as(u32, 2), route({}, event, &screen));
    try testing.expectEqual(@as(u32, 1), screen.one.hits);
    for (screen.row) |widget| try testing.expectEqual(@as(u32, 1), widget.hits);
    try testing.expectEqual(@as(u32, 1), route({}, event, screen.row[0..]));
    try testing.expectEqual(@as(u32, 1), route({}, event, &screen.one));
    try testing.expectEqual(@as(u32, 7), screen.count);
}

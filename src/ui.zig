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
pub const List = view.List;
pub const zero_inset = turtle.zero_inset;

/// A walk with no margins.
pub fn sized(width: Size, height: Size) Walk {
    const walk: Walk = .{ .width = width, .height = height, .margin = zero_inset };
    assert(walk.margin.left == 0);
    assert(walk.margin.top == 0);
    return walk;
}

/// A layout with no spacing, padding, alignment, or clip, flowing by `flow`.
pub fn flow_of(flow: Flow) Layout {
    comptime assert(@typeInfo(Flow).@"enum".field_names.len == 3);
    assert(@backingInt(flow) < 3);
    return .{
        .flow = flow,
        .spacing = 0,
        .padding = zero_inset,
        .alignment = .{ .x = 0, .y = 0 },
        .clip = false,
    };
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
    _ = cx;
    _ = edit;
}

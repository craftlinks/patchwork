//! Canvas example: a 1,000-module grid with cables that pans, zooms, selects, and drags.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The pan/zoom canvas (step 27, `ui/canvas.zig`): modules are placed at world rects with
//! `cx.begin_at` inside `cx.begin_canvas`, drawn on two viewed layers (modules, then cables),
//! culled in world pixels by `cx.visible`, and hit through areas mapped to the screen. At fixed
//! positions from the top-left:
//! ```text
//! title   16, 16, 1248 by 24
//! canvas  16, 56, 1248 by 592   modules at world (16 + 208 col, 16 + 144 row), 176 by 112
//! status  16, 664, 1248 by 24   zoom, offset, visible modules, glyph cache epoch and pending
//! ```
//!
//! ## 2. The Grid
//! `columns * rows` modules in a 40 by 25 grid. Module `i` has a face, a header with its title
//! ("osc 17"), an input port on the left, an output port on the right, and a `widgets.Knob`
//! with a 40 px ring (`Knob.sized`), its name, and its value. Cables run from each module's output to the next module's input in its row, and
//! from every third column to the module below. Below zoom 0.5 a module is its face and header
//! only, and text is placed only when its on-screen em is at least `label_min_px` (level of
//! detail; `ui/canvas.zig`, section 3).
//!
//! ## 3. Input
//! ```text
//! wheel on the canvas     one zoom rung about the pointer       drag the background  pans
//! press a module          selects it                            drag its header      moves it
//! drag or wheel a knob    turns it (`widgets.Knob`, routed with `ui.route`, at any zoom)
//! arrows                  pan by pan_step                       = and -              a rung about
//! 0                       back to the start view                                     the center
//! ```
//! A header drag keeps the world point under the pointer under it: on press the grab is the
//! world offset of the pointer from the module's origin (`CanvasState.to_world`), and each drag
//! puts the origin at the pointer's world point minus that offset.
//!
//! ## 4. TigerStyle Invariants
//! Capacities hold the zoomed-out grid (comptime block); a frame is O(modules + cables).

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;
const widgets = patchwork.widgets;
const canvas = ui.canvas;

const Rect = quads.Rect;
const Point = quads.path.Point;

pub const title_rect: Rect = .{ .x = 16, .y = 16, .width = 1248, .height = 24 };
pub const canvas_rect: Rect = .{ .x = 16, .y = 56, .width = 1248, .height = 592 };
pub const status_rect: Rect = .{ .x = 16, .y = 664, .width = 1248, .height = 24 };

pub const columns: u32 = 40;
pub const rows: u32 = 25;
pub const module_count: u32 = columns * rows;
pub const module_width: f32 = 176;
pub const module_height: f32 = 112;
pub const pitch_x: f32 = 208;
pub const pitch_y: f32 = 144;
pub const margin: f32 = 16;
pub const header_height: f32 = 24;
pub const port_size: f32 = 10;
/// Each module's knob: a `widgets.Knob` with a 40 px ring, 8 px below the header.
pub const knob_ring: f32 = 40;
pub const knob_top: f32 = 8;
/// The port row, from a module's top.
pub const port_y: f32 = 64;
/// Smallest on-screen em, in logical pixels, that is placed (section 2).
pub const label_min_px: f32 = 6;
/// Below this zoom a module is its face and header only (section 2).
pub const detail_zoom: f32 = 0.5;
/// Arrow-key pan, in logical pixels.
pub const pan_step: f32 = 64;
/// Every `drop_every` columns a cable runs to the module below.
pub const drop_every: u32 = 3;
pub const cable_width: f32 = 2.5;
/// How far a cable hangs below its chord, plus 15% of its length.
pub const cable_sag: f32 = 24;

pub const horizontal_cables: u32 = (columns - 1) * rows;
pub const vertical_cables: u32 = ((columns + drop_every - 1) / drop_every) * (rows - 1);
pub const cable_count: u32 = horizontal_cables + vertical_cables;

pub const modules_layer: quads.Layer = @fromBackingInt(1);
pub const cables_layer: quads.Layer = @fromBackingInt(2);

pub const canvas_id = ui.id("canvas", 0);

/// World (0, 0) at the canvas's top-left, at zoom 1.
pub const start_x: f32 = canvas_rect.x;
pub const start_y: f32 = canvas_rect.y;

const canvas_color: [4]f32 = .{ 0.07, 0.08, 0.10, 1 };
const face_color: [4]f32 = .{ 0.16, 0.18, 0.22, 1 };
const header_color: [4]f32 = .{ 0.22, 0.26, 0.34, 1 };
const port_color: [4]f32 = .{ 0.55, 0.60, 0.68, 1 };
const select_color: [4]f32 = .{ 1.0, 0.80, 0.30, 1 };
const cable_colors = [_][4]f32{
    .{ 0.35, 0.75, 1.0, 0.85 },
    .{ 0.45, 1.0, 0.55, 0.85 },
    .{ 1.0, 0.50, 0.45, 0.85 },
    .{ 0.85, 0.55, 1.0, 0.85 },
};
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const status_style: text.Style = .{ .face = .sans, .size = 13, .color = theme.dark.colors.text };
const header_style: text.Style = .{ .face = .sans_bold, .size = 13, .color = theme.dark.colors.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

/// A zoomed-out frame draws the face and header of every module, plus the canvas face.
const box_cap: u32 = 2 * module_count + 64;
/// Two arcs per knob, for the modules visible at the detail zoom.
const arc_cap: u32 = 512;
const glyph_cap: u32 = 4096;
const path_cap: u32 = 2 * cable_count + 64;
const point_cap: u32 = 16384;
const area_cap: u32 = 2 * module_count + 8;
const status_cap: u32 = 160;

comptime {
    assert(module_count == 1000);
    assert(margin + columns * pitch_x <= 8400);
    assert(module_width < pitch_x and module_height < pitch_y);
    assert(port_y + port_size <= module_height);
}

/// A header drag in progress (section 3).
const Drag = struct {
    index: u32,
    grab: [2]f32,
};

/// The canvas screen. See the module guide.
pub const App = struct {
    view: ui.CanvasState,
    /// Each module's world origin.
    origins: [module_count]Point,
    /// Each module's knob, routed with `ui.route` (section 3).
    knobs: [module_count]widgets.Knob,
    selected: ?u32,
    drag: ?Drag,
    /// What the last frame drew, for the status line.
    visible: u32,
    cables_drawn: u32,

    pub const config: patchwork.app.Config = .{
        .title = "canvas",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Path, .cap = path_cap },
        },
        .batch_cap = 16,
        .area_cap = area_cap,
        .point_cap = point_cap,
    };

    const center = patchwork.bench.area("canvas", 0);
    const zoom_in: patchwork.bench.Step = .{ .wheel = .{ .target = center, .dx = 0, .dy = -10 } };
    const zoom_out: patchwork.bench.Step = .{ .wheel = .{ .target = center, .dx = 0, .dy = 10 } };
    const right: patchwork.bench.Step = .{ .key = .{ .key = .right, .text = "" } };
    const back: patchwork.bench.Step = .{ .key = .{ .key = .left, .text = "" } };
    const wait: patchwork.bench.Step = .{ .wait = 5 };

    fn steps(comptime count: usize, comptime step: patchwork.bench.Step) [count]patchwork.bench.Step {
        return @splat(step);
    }

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{
            .name = "zoom",
            .setup = &.{.{ .wait = 5 }},
            .cycle = &(steps(8, zoom_in) ++ steps(16, zoom_out) ++ steps(8, zoom_in)),
            .frames = 320,
        },
        .{
            .name = "pan",
            .setup = &.{.{ .wait = 5 }},
            .cycle = &(steps(16, right) ++ steps(16, back)),
            .frames = 320,
        },
        .{
            .name = "zoomed",
            .setup = &(steps(1, wait) ++ steps(3, zoom_in) ++ steps(5, right) ++ steps(1, wait)),
            .cycle = &.{.{ .wait = 1 }},
            .frames = 60,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.view = .init(start_x, start_y, 1);
        for (&app.origins, &app.knobs, 0..) |*origin, *knob, index_usize| {
            const index: u32 = @intCast(index_usize);
            origin.* = home_of(index);
            const accent = widgets.accents[index % widgets.accents.len];
            knob.* = widgets.Knob.init(knob_id(index), "gain", value_of(index), accent).sized(knob_ring);
        }
        app.selected = null;
        app.drag = null;
        app.visible = 0;
        app.cables_drawn = 0;
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .key_down => |press| app.key(cx, press),
            else => {},
        }
        // Every knob, then selection and header drags, then the background (section 3).
        _ = ui.route(cx, event_value, &app.knobs);
        if (app.route_modules(cx, event_value)) return;
        _ = app.view.handle(cx, canvas_id, event_value);
    }

    /// Selection and header drags (section 3). True when a module took the event.
    fn route_modules(app: *App, cx: *Context, event_value: input.Event) bool {
        if (app.drag) |drag| {
            switch (cx.hit(header_id(drag.index), event_value)) {
                .drag => |press| {
                    const at = app.view.to_world(press.x, press.y);
                    app.origins[drag.index] = .{ at[0] - drag.grab[0], at[1] - drag.grab[1] };
                    cx.redraw();
                    return true;
                },
                .up => {
                    app.drag = null;
                    return true;
                },
                else => {},
            }
        }
        // Only a press resolves to a module; `hit` is O(1) per id.
        if (event_value != .pointer_down) return false;
        for (0..module_count) |index_usize| {
            const index: u32 = @intCast(index_usize);
            switch (cx.hit(header_id(index), event_value)) {
                .down => |press| {
                    const at = app.view.to_world(press.x, press.y);
                    const origin = app.origins[index];
                    app.drag = .{ .index = index, .grab = .{ at[0] - origin[0], at[1] - origin[1] } };
                    app.select(cx, index);
                    return true;
                },
                else => {},
            }
            switch (cx.hit(module_id(index), event_value)) {
                .down => {
                    app.select(cx, index);
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn select(app: *App, cx: *Context, index: u32) void {
        assert(index < module_count);
        if (app.selected != null and app.selected.? == index) return;
        app.selected = index;
        cx.redraw();
    }

    fn key(app: *App, cx: *Context, press: input.KeyPress) void {
        const mid_x = canvas_rect.x + canvas_rect.width / 2;
        const mid_y = canvas_rect.y + canvas_rect.height / 2;
        switch (press.key) {
            .left => _ = app.view.pan_by(cx, pan_step, 0),
            .right => _ = app.view.pan_by(cx, -pan_step, 0),
            .up => _ = app.view.pan_by(cx, 0, pan_step),
            .down => _ = app.view.pan_by(cx, 0, -pan_step),
            else => {
                const typed = press.typed();
                if (std.mem.eql(u8, typed, "=") or std.mem.eql(u8, typed, "+")) {
                    _ = app.view.step_at(cx, mid_x, mid_y, 1);
                } else if (std.mem.eql(u8, typed, "-")) {
                    _ = app.view.step_at(cx, mid_x, mid_y, -1);
                } else if (std.mem.eql(u8, typed, "0")) {
                    app.view = .init(start_x, start_y, 1);
                    cx.redraw();
                }
            },
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const window = clip_of(cx.window);
        // Faces first, so the Box batch of each layer precedes its Glyph batch.
        append_box(cx, canvas_rect, canvas_color, window, 6, 0, null);
        text.place(cx.drawing(), title_style, "canvas: wheel zooms, drag pans, drag a header moves a module", title_rect, window, left);
        const layers = [_]quads.Layer{ modules_layer, cables_layer };
        const walk = ui.sized(.{ .fixed = canvas_rect.width }, .{ .fixed = canvas_rect.height });
        _ = cx.begin_at(canvas_rect, ui.flow_of(.down));
        _ = cx.begin_canvas(canvas_id, walk, ui.flow_of(.down), &app.view, &layers);
        app.visible = 0;
        for (0..module_count) |index| app.draw_module(cx, @intCast(index));
        _ = cx.drawing().layer(cables_layer);
        app.cables_drawn = app.draw_cables(cx);
        cx.end_canvas();
        _ = cx.end();
        app.draw_status(cx, window);
        assert(cx.draw.overflow_count == 0);
    }

    fn draw_module(app: *App, cx: *Context, index: u32) void {
        const origin = app.origins[index];
        const rect: Rect = .{ .x = origin[0], .y = origin[1], .width = module_width, .height = module_height };
        const clip = cx.visible(rect) orelse return;
        app.visible += 1;
        const zoom = app.view.drawn.zoom;
        const selected = app.selected != null and app.selected.? == index;
        _ = cx.begin_at(rect, .{ .flow = .down });
        const header = cx.walk(ui.sized(.fill, .{ .fixed = header_height }));
        append_box(cx, rect, face_color, clip, 8, if (selected) 2 else 0, if (selected) select_color else null);
        append_box(cx, header, header_color, clip, 8, 0, null);
        // The face's area first, so the knob's, recorded later on the same layer, wins over it.
        cx.area(module_id(index), rect, 8, ui.cx.plain);
        if (zoom >= detail_zoom) {
            const in_port: Rect = .{ .x = rect.x - port_size / 2, .y = rect.y + port_y, .width = port_size, .height = port_size };
            const out_port: Rect = .{ .x = rect.x + rect.width - port_size / 2, .y = rect.y + port_y, .width = port_size, .height = port_size };
            if (cx.visible(in_port)) |port_clip| append_box(cx, in_port, port_color, port_clip, port_size / 2, 0, null);
            if (cx.visible(out_port)) |port_clip| append_box(cx, out_port, port_color, port_clip, port_size / 2, 0, null);
            app.knobs[index].draw(cx, .{ .width = .fill, .height = .{ .fixed = widgets.knob_height }, .margin = .sides(0, knob_top, 0, 0) });
            if (zoom * header_style.size >= label_min_px) {
                var buffer: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&buffer, "osc {d}", .{index}) catch unreachable;
                const label: Rect = .{ .x = header.x + 10, .y = header.y, .width = header.width - 20, .height = header.height };
                text.place(cx.drawing(), header_style, name, label, clip, left);
            }
        }
        cx.area(header_id(index), header, 8, grab_flags);
        _ = cx.end();
    }

    /// Draws every cable whose control hull is visible; returns how many.
    fn draw_cables(app: *const App, cx: *Context) u32 {
        var drawn: u32 = 0;
        for (0..rows) |row| {
            for (0..columns) |col| {
                const index: u32 = @intCast(row * columns + col);
                if (col + 1 < columns) {
                    if (app.cable(cx, index, index + 1, row)) drawn += 1;
                }
                if (col % drop_every == 0 and row + 1 < rows) {
                    if (app.cable(cx, index, index + columns, col)) drawn += 1;
                }
            }
        }
        assert(drawn <= cable_count);
        return drawn;
    }

    /// A cable that hangs from `from`'s output to `to`'s input: each control point a third of
    /// the way along, both dropped by the sag, so it never folds back on itself.
    fn cable(app: *const App, cx: *Context, from: u32, to: u32, tint: usize) bool {
        const a = app.origins[from];
        const b = app.origins[to];
        const start: Point = .{ a[0] + module_width, a[1] + port_y + port_size / 2 };
        const end: Point = .{ b[0], b[1] + port_y + port_size / 2 };
        const dx = end[0] - start[0];
        const dy = end[1] - start[1];
        const sag = cable_sag + 0.15 * @sqrt(dx * dx + dy * dy);
        const control = [4]Point{
            start,
            .{ start[0] + dx / 3, start[1] + dy / 3 + sag },
            .{ start[0] + 2 * dx / 3, start[1] + 2 * dy / 3 + sag },
            end,
        };
        var low = control[0];
        var high = control[0];
        for (control[1..]) |point| {
            low = .{ @min(low[0], point[0]), @min(low[1], point[1]) };
            high = .{ @max(high[0], point[0]), @max(high[1], point[1]) };
        }
        const pad = cable_width;
        const bounds: Rect = .{ .x = low[0] - pad, .y = low[1] - pad, .width = high[0] - low[0] + 2 * pad, .height = high[1] - low[1] + 2 * pad };
        const clip = cx.visible(bounds) orelse return false;
        const color = cable_colors[tint % cable_colors.len];
        _ = quads.path.cubic(cx.drawing(), control, .{ .color = color, .width = cable_width, .hover = 0 }, clip);
        return true;
    }

    fn draw_status(app: *const App, cx: *Context, window: quads.Clip) void {
        var buffer: [status_cap]u8 = undefined;
        const v = app.view.drawn;
        const glyphs = &cx.draw.text;
        const line = std.fmt.bufPrint(&buffer, "zoom {d:.0}%    offset {d:.0}, {d:.0}    modules {d} visible    cables {d}    glyph cache: epoch {d}, pending {d}", .{
            v.zoom * 100, v.x, v.y, app.visible, app.cables_drawn, glyphs.epoch, glyphs.pending,
        }) catch unreachable;
        text.place(cx.drawing(), status_style, line, status_rect, window, left);
    }
};

pub const Context = patchwork.app.Context(App);

const grab_flags: ui.Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .grab };

pub fn module_id(index: u32) ui.Id {
    return ui.id("module", index);
}

pub fn header_id(index: u32) ui.Id {
    return ui.id("header", index);
}

pub fn knob_id(index: u32) ui.Id {
    return ui.id("knob", index);
}

/// The start origin of module `index` (section 2).
pub fn home_of(index: u32) Point {
    assert(index < module_count);
    const col: f32 = @floatFromInt(index % columns);
    const row: f32 = @floatFromInt(index / columns);
    return .{ margin + col * pitch_x, margin + row * pitch_y };
}

/// The knob value of module `index`, in `[0, 1)`.
pub fn value_of(index: u32) f32 {
    return @as(f32, @floatFromInt((index * 37) % 100)) / 100;
}

fn append_box(cx: *Context, rect: Rect, color: [4]f32, clip: quads.Clip, radius: f32, border: f32, border_color: ?[4]f32) void {
    kit.append(cx, quads.Box, null, .of(rect, clip, .{
        .fill = color,
        .border_color = border_color orelse quads.transparent,
        .border_width = border,
        .radius = radius,
    }));
}

fn clip_of(rect: Rect) quads.Clip {
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

fn frame_at(app: *App) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, 1280, 720, 120));
    cx.draw.finalize();
    assert(cx.draw.overflow_count == 0);
    return cx;
}

fn send(app: *App, event_value: input.Event) void {
    ui.dispatch(App, app, &fixture.context, event_value);
}

// Locks the start screen (section 1): at zoom 1 the canvas shows columns 0 to 5 and rows 0 to
// 3 (world 1248 by 592 from the origin; row 4 starts at 592), the modules' areas are mapped (module 0's header at
// the screen point (32, 72)), and nothing overflows.
test "the start screen culls to the visible modules" {
    const app = new_app();
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(u32, 6 * 4), app.visible);
    const header = cx.find(header_id(0)).?;
    try std.testing.expectEqualSlices(f32, &.{ 32, 72, 176, 24 }, &header.rect);
    try std.testing.expectEqual(@as(?ui.Area, null), cx.find(module_id(6 + 40 * 5)));
    try std.testing.expectEqual(@as(u32, 0), cx.draw.text.epoch);
}

// Locks the zoomed-out grid (section 2): at the bottom rung the canvas shows world 4992 by
// 2368, so columns 0 to 23 and rows 0 to 16, drawn as face and header only, with no knob and
// every pool within capacity. Panned to the far corner, the last module is drawn.
test "the zoomed-out grid draws its visible modules without detail" {
    const app = new_app();
    app.view = .init(start_x, start_y, canvas.zoom_min);
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(u32, 24 * 17), app.visible);
    try std.testing.expectEqual(@as(usize, 0), cx.draw.items(quads.Arc).len);
    try std.testing.expectEqual(@as(usize, 1 + 2 * 24 * 17), cx.draw.items(quads.Box).len);
    app.view = .init(start_x - 1200, start_y - 400, canvas.zoom_min);
    const corner = frame_at(app);
    try std.testing.expect(corner.find(module_id(module_count - 1)) != null);
}

// Locks a header drag at zoom 2 (section 3): dragging 30 screen pixels right moves the module
// 15 world pixels, and the selection follows the press.
test "a header drag moves its module by the world delta" {
    const app = new_app();
    app.view = .init(start_x, start_y, 2);
    _ = frame_at(app);
    const header = fixture.context.find(header_id(0)).?;
    const x = header.rect[0] + 20;
    const y = header.rect[1] + 10;
    send(app, .{ .pointer_move = .{ .x = x, .y = y } });
    send(app, .{ .pointer_down = input.left_at(.{ .x = x, .y = y }) });
    try std.testing.expectEqual(@as(?u32, 0), app.selected);
    _ = frame_at(app);
    send(app, .{ .pointer_move = .{ .x = x + 30, .y = y } });
    send(app, .{ .pointer_up = input.left_at(.{ .x = x + 30, .y = y }) });
    try std.testing.expectEqual(home_of(0)[0] + 15, app.origins[0][0]);
    try std.testing.expectEqual(home_of(0)[1], app.origins[0][1]);
    try std.testing.expectEqual(@as(?Drag, null), app.drag);
}

// Locks a widget inside the canvas (section 3): at zoom 2 module 0's knob area is its 40 px
// ring mapped to an 80 px disc, and a drag 30 screen pixels up through `ui.route` turns it by
// 30 / drag_span_px = 0.25, the same as outside a canvas, while the module does not move.
test "a knob in the canvas turns by screen pixels at any zoom" {
    const app = new_app();
    app.view = .init(start_x, start_y, 2);
    _ = frame_at(app);
    const ring = fixture.context.find(knob_id(0)).?;
    try std.testing.expectEqual(@as(f32, 80), ring.rect[2]);
    try std.testing.expectEqual(@as(f32, 40), ring.radius);
    const x = ring.rect[0] + 40;
    const y = ring.rect[1] + 40;
    send(app, .{ .pointer_move = .{ .x = x, .y = y } });
    send(app, .{ .pointer_down = input.left_at(.{ .x = x, .y = y }) });
    send(app, .{ .pointer_move = .{ .x = x, .y = y - 30 } });
    send(app, .{ .pointer_up = input.left_at(.{ .x = x, .y = y - 30 }) });
    try std.testing.expectEqual(@as(f32, 0.25), app.knobs[0].value);
    try std.testing.expectEqual(home_of(0)[0], app.origins[0][0]);
}

// Locks the zoom cycle against the glyph cache (`text/cache.zig`, section 2a): a full sweep of
// the ladder in and out never resets the atlas and leaves no glyph pending twice in a row.
test "a zoom sweep never resets the glyph atlas" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    const zoom = bench.find(App.scenarios, "zoom").?;
    const app = new_app();
    const steps = try bench.replay_headless(App, app, cx, zoom, .{ 1280, 720 }, 5 + 64);
    try std.testing.expectEqual(@as(u32, 5 + 64), steps);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.text.epoch);
    try std.testing.expectEqual(@as(f32, 1), app.view.zoom);
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a): pan moves by whole steps
// and zoomed ends three rungs in.
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    const pan = bench.find(App.scenarios, "pan").?;
    const app = new_app();
    _ = try bench.replay_headless(App, app, cx, pan, .{ 1280, 720 }, 5 + 16);
    try std.testing.expectEqual(start_x - 16 * pan_step, app.view.x);
    const zoomed = bench.find(App.scenarios, "zoomed").?;
    const again = new_app();
    _ = try bench.replay_headless(App, again, cx, zoomed, .{ 1280, 720 }, 20);
    try std.testing.expectEqual(canvas.rungs[canvas.rung_one + 3], again.view.zoom);
    const still = bench.find(App.scenarios, "still").?;
    _ = try bench.replay_headless(App, new_app(), cx, still, .{ 1280, 720 }, 10);
}

comptime {
    patchwork.app.check(App);
}

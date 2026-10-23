//! Column example: one scrolling view of knobs, a meter, and toggles docked on the right.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! A fixed-width panel parked on the right edge of a padded window holds one scrolling view
//! (`cx.begin_view`) of mixed controls, and the app requests no host timer. It exists to lock
//! the view, wheel, toggle, and hover behavior that the rack example does not exercise.
//! Every worked number lives in this file's tests, for example "demo layout at 1280 by 720".
//!
//! ## 2. Coordinate Space and Layout
//! All measurements are UI logical pixels, top-left origin, `+Y` down.
//! ```text
//! frame    flow down, padding 16, alignment.x = 1     parks the panel on the right
//!   panel  320 by fill, padding 8                     the face (`Panel.begin`)
//!     view fill by fill, flow down                    viewport = the panel's inner rect
//!       row  fill by knob_height / meter_height / toggle_height, margin top 8
//! ```
//! The children walk in the viewport minus the thumb's gutter, `scroll_y` above its top;
//! `end_view` measures the content height and draws the thumb from it.
//!
//! ## 3. Contract With the Library
//! `config.timer_period_ms` is 0, so the host never calls `timer`, and a resting pointer
//! causes no wakeups. `event` routes every event to every knob, the toggles, and the view.
//!
//! ## 4. Draw Types
//! The column registers the library's `Box`, `Arc`, and `Glyph` (`config.draw`). It draws
//! everything on the base layer, so the frame is three batches at most.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed widget arrays and no allocation; every loop is bounded by them.
//! - The comptime block asserts that every row fits the configured pool and area capacities.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

const Rect = quads.Rect;

const frame_padding: quads.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
const panel_padding: quads.Inset = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 };
const panel_width_px: f32 = 320;
const row_gap_px: f32 = 8;

const knob_specs = [_]struct { name: []const u8, value: f32 }{
    .{ .name = "gain", .value = 0.25 },
    .{ .name = "slope", .value = 0.50 },
    .{ .name = "twice", .value = 0.75 },
    .{ .name = "skew", .value = 0 },
    .{ .name = "echo", .value = 1 },
    .{ .name = "room", .value = 0.50 },
    .{ .name = "out", .value = 0.50 },
    .{ .name = "drive", .value = 0.50 },
};

const toggle_specs = [_]struct { name: []const u8, on: bool }{
    .{ .name = "take", .on = true },
    .{ .name = "drums", .on = false },
};

/// The view's id; its thumb is `view_id.derive(ui.view.thumb_salt)`.
const view_id = ui.id("view", 0);

/// Pool and area capacities: one panel and one thumb box plus two faces per row, two arcs
/// per knob, up to 12 glyphs per row, and one area per knob and toggle plus the view and
/// its thumb. The comptime block checks them.
const box_cap: u32 = 64;
const arc_cap: u32 = 32;
const glyph_cap: u32 = 256;
const area_cap: u32 = 16;
const row_count: u32 = knob_specs.len + 1 + toggle_specs.len;

const Context = patchwork.app.Context(App);

/// The column app. `timer_period_ms` is 0: nothing wakes the host while the pointer rests.
pub const App = struct {
    knobs: [knob_specs.len]widgets.Knob,
    meter: widgets.Meter,
    toggles: [toggle_specs.len]widgets.Toggle,
    view: ui.ViewState,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork column",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
        },
        .area_cap = area_cap,
    };

    /// The column draws no images, so it creates no textures.
    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        for (&app.knobs, knob_specs, 0..) |*knob, spec, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            const id = ui.id("knob", @intCast(index));
            knob.* = widgets.Knob.init(id, spec.name, spec.value, accent);
        }
        app.meter = .{ .name = "meter", .value = 0.5 };
        for (&app.toggles, toggle_specs, 0..) |*toggle, spec, index| {
            toggle.* = widgets.Toggle.init(ui.id("toggle", @intCast(index)), spec.name, spec.on);
        }
        app.view = ui.ViewState.init();
        assert(app.knobs[0].value == knob_specs[0].value);
        assert(app.toggles[0].on);
    }

    /// Routes the event to every knob, every toggle, and the view.
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.knobs) |*knob| _ = knob.handle(cx, event_value);
        for (&app.toggles) |*toggle| _ = toggle.handle(cx, event_value);
        _ = app.view.handle(cx, view_id, event_value);
        assert(app.view.scroll_y >= 0);
    }

    /// No timer is armed, so this is never called by a host. It satisfies the contract.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        assert(app.view.scroll_y >= 0);
        assert(cx.phase == .idle);
        assert(now_ms == now_ms);
    }

    /// The panel on the right, its view, and one row per control.
    pub fn draw(app: *App, cx: *Context) void {
        var frame = ui.flow_of(.down);
        frame.padding = frame_padding;
        frame.alignment.x = 1;
        _ = cx.begin(ui.sized(.fill, .fill), frame);
        const panel: widgets.Panel = .{ .paint = widgets.paint_of(theme.chrome.panel, 0) };
        var layout = ui.flow_of(.down);
        layout.padding = panel_padding;
        _ = panel.begin(cx, ui.sized(.{ .fixed = panel_width_px }, .fill), layout);
        _ = cx.begin_view(view_id, ui.sized(.fill, .fill), ui.flow_of(.down), &app.view);
        for (&app.knobs) |*knob| knob.draw(cx, row(widgets.knob_height));
        app.meter.draw(cx, row(widgets.meter_height));
        for (&app.toggles) |*toggle| toggle.draw(cx, row(widgets.toggle_height));
        cx.end_view();
        _ = cx.end();
        _ = cx.end();
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }
};

/// A full-width row of `height` below an 8 px gap.
fn row(height: f32) ui.Walk {
    assert(height > 0);
    return .{
        .width = .fill,
        .height = .{ .fixed = height },
        .margin = .{ .left = 0, .top = row_gap_px, .right = 0, .bottom = 0 },
    };
}

comptime {
    assert(row_count == 11);
    assert(1 + 1 + row_count * 2 <= box_cap);
    assert(knob_specs.len * 2 <= arc_cap);
    assert(row_count * 12 <= glyph_cap);
    assert(knob_specs.len + toggle_specs.len + 2 <= area_cap);
}

/// The test context: static, like the hosts', so its pools stay off the stack.
var test_context: Context = undefined;

/// A fresh app, initialized against a fresh test context the way a host does.
fn new_app() App {
    test_context.init();
    var app: App = undefined;
    App.init(&app, &test_context.draw.textures);
    return app;
}

/// Draws a `width` by `height` frame the way a host does after a resize, then finalizes it.
fn frame_at(app: *App, width: u32, height: u32) *Context {
    test_context.redraw();
    assert(ui.draw_frame(App, app, &test_context, width, height, 120));
    test_context.draw.finalize();
    assert(test_context.draw.overflow_count == 0);
    return &test_context;
}

/// Dispatches `event` the way a host does. Returns true when it owed a draw.
fn send(app: *App, event: input.Event) bool {
    test_context.dirty = false;
    ui.dispatch(App, app, &test_context, event);
    return test_context.dirty;
}

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

fn rect_of(values: [4]f32) Rect {
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

/// The area `id` recorded at the last draw.
fn area_rect(id: ui.Id) Rect {
    return rect_of(test_context.find(id).?.rect);
}

/// The center of `rect`.
fn center(rect: Rect) input.Point {
    return .{ .x = rect.x + rect.width * 0.5, .y = rect.y + rect.height * 0.5 };
}

/// A wheel in the view's gutter, 40 px below its top, where no control sits.
fn gutter_wheel(app: *const App, dy: f32) input.Event {
    const view = app.view.viewport;
    return .{ .wheel = .{ .x = view.x + view.width - 8, .y = view.y + 40, .dx = 0, .dy = dy } };
}

fn has_clip(instance_clip: [4]f32, clip: quads.Clip) bool {
    return std.mem.eql(f32, &instance_clip, &.{ clip.x0, clip.y0, clip.x1, clip.y1 });
}

const view_clip: quads.Clip = .{ .x0 = 952, .y0 = 24, .x1 = 1256, .y1 = 696 };

// Locks the panel, viewport, and ring rects, the measured content, the first knob's faces,
// and that a draw clears the dirty flag.
test "demo layout at 1280 by 720" {
    var app = new_app();
    const cx = frame_at(&app, 1280, 720);
    try expect_rect(rect_of(cx.draw.items(quads.Box)[0].rect), 944, 16, 320, 688);
    try expect_rect(app.view.viewport, 952, 24, 304, 672);
    try std.testing.expectEqual(@as(f32, 904), app.view.content_h);
    try std.testing.expectEqual(@as(f32, 232), app.view.max_scroll());
    try expect_rect(area_rect(app.knobs[0].id), 960, 40, 56, 56);
    const arcs = cx.draw.items(quads.Arc);
    try expect_rect(rect_of(arcs[0].rect), 960, 40, 56, 56);
    try std.testing.expectEqual(@as(f32, 1), arcs[0].sweep);
    try expect_rect(rect_of(arcs[1].rect), 960, 40, 56, 56);
    try std.testing.expectEqual(@as(f32, 0.25), arcs[1].sweep);
    try std.testing.expect(!cx.dirty);
}

// Locks that the panel and `max_scroll` follow the window while content height does not.
test "demo layout at 800 by 600" {
    var app = new_app();
    const cx = frame_at(&app, 800, 600);
    try expect_rect(rect_of(cx.draw.items(quads.Box)[0].rect), 464, 16, 320, 568);
    try std.testing.expectEqual(@as(f32, 904), app.view.content_h);
    try std.testing.expectEqual(@as(f32, 352), app.view.max_scroll());
}

// Locks that rows below the viewport are culled and visible meter faces and every glyph
// carry the viewport clip.
test "scroll 0 clips the meter and omits the toggles" {
    var app = new_app();
    const cx = frame_at(&app, 1280, 720);
    var meter_faces: u32 = 0;
    for (cx.draw.items(quads.Box)) |face| {
        try std.testing.expect(face.rect[1] < 840);
        if (face.rect[2] == widgets.meter_track_w) {
            meter_faces += 1;
            try std.testing.expect(has_clip(face.clip, view_clip));
        }
    }
    try std.testing.expect(meter_faces >= 1);
    var gain_glyph = false;
    var meter_glyph = false;
    for (cx.draw.items(quads.Glyph)) |glyph| {
        try std.testing.expect(has_clip(glyph.clip, view_clip));
        if (glyph.rect[1] < 80) gain_glyph = true;
        if (glyph.rect[1] > 700) meter_glyph = true;
    }
    try std.testing.expect(gain_glyph);
    try std.testing.expect(meter_glyph);
    try std.testing.expect(cx.find(app.toggles[1].id) == null);
}

// Locks that a zero-valued knob emits only its track arc.
test "value 0 omits the value arc" {
    var app = new_app();
    const cx = frame_at(&app, 1280, 720);
    const ring = area_rect(app.knobs[3].id);
    var arcs: u32 = 0;
    for (cx.draw.items(quads.Arc)) |arc| {
        if (arc.rect[1] == ring.y) arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
}

// Locks that toggle rows, shorter than knob rows, still draw when nothing needs scrolling,
// and that no thumb is drawn then.
test "a tall window draws the short toggle rows" {
    var app = new_app();
    const cx = frame_at(&app, 1280, 1000);
    try std.testing.expectEqual(@as(f32, 0), app.view.max_scroll());
    const pill = area_rect(app.toggles[1].id);
    var found = false;
    for (cx.draw.items(quads.Box)) |face| {
        if (face.rect[1] == pill.y) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(cx.find(view_id.derive(ui.view.thumb_salt)) == null);
}

// Locks wheel scrolling to the last row and its clamp at `max_scroll`.
test "scroll 232 shows drums and clamps a further wheel" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    try std.testing.expect(send(&app, gutter_wheel(&app, 232)));
    try std.testing.expectEqual(@as(f32, 232), app.view.scroll_y);
    try std.testing.expect(!send(&app, gutter_wheel(&app, 40)));
    try std.testing.expectEqual(@as(f32, 232), app.view.scroll_y);
    _ = frame_at(&app, 1280, 720);
    // The drums row is the last: its 40 px row ends on the viewport's bottom edge.
    const pill = area_rect(app.toggles[1].id);
    const row_y = pill.y - (widgets.toggle_height - widgets.pill_h) * 0.5;
    const view = app.view.viewport;
    try std.testing.expectEqual(view.y + view.height, row_y + widgets.toggle_height);
}

// Locks the relative knob drag through dispatch, including clamping at both ends.
test "knob drag from the ring center clamps at both ends" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    const point = center(area_rect(app.knobs[0].id));
    try std.testing.expect(send(&app, .{ .pointer_down = input.left_at(point) }));
    try std.testing.expect(send(&app, .{ .pointer_move = .{ .x = point.x, .y = point.y - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[0].value);
    try std.testing.expect(send(&app, .{ .pointer_move = .{ .x = point.x, .y = point.y + 4000 } }));
    try std.testing.expectEqual(@as(f32, 0), app.knobs[0].value);
    try std.testing.expect(send(&app, .{ .pointer_move = .{ .x = point.x, .y = point.y - 4000 } }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].value);
}

// Locks wheel routing: a ring wheel nudges the knob, any other viewport wheel scrolls.
test "wheel on the ring nudges and wheel on the label scrolls" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    const ring = area_rect(app.knobs[0].id);
    const point = center(ring);
    try std.testing.expect(send(
        &app,
        .{ .wheel = .{ .x = point.x, .y = point.y, .dx = 0, .dy = -60 } },
    ));
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[0].value);
    try std.testing.expectEqual(@as(f32, 0), app.view.scroll_y);
    try std.testing.expect(send(
        &app,
        .{ .wheel = .{ .x = ring.x + 80, .y = point.y, .dx = 0, .dy = 40 } },
    ));
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[0].value);
    try std.testing.expectEqual(@as(f32, 40), app.view.scroll_y);
}

/// Scrolls to the bottom and redraws, so the drums toggle is visible and hittable.
fn scroll_to_drums(app: *App) input.Point {
    assert(send(app, gutter_wheel(app, 232)));
    _ = frame_at(app, 1280, 720);
    return center(area_rect(app.toggles[1].id));
}

// Locks that an inside release flips a scrolled toggle and the thumb eases to its target.
test "toggle up inside drums slides the thumb" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    const pill = scroll_to_drums(&app);
    try std.testing.expect(send(&app, .{ .pointer_down = input.left_at(pill) }));
    try std.testing.expect(send(&app, .{ .pointer_up = input.left_at(pill) }));
    try std.testing.expect(app.toggles[1].on);
    try std.testing.expectEqual(@as(f32, 1), app.toggles[1].thumb.target);
    try std.testing.expect(ui.animate(App, &app, &test_context, 50));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), app.toggles[1].thumb.value, 0.0001);
    _ = ui.animate(App, &app, &test_context, 1000);
    try std.testing.expectEqual(@as(f32, 1), app.toggles[1].thumb.value);
}

// Locks that a release outside the pill leaves the toggle unchanged.
test "toggle up outside does not flip" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    const pill = scroll_to_drums(&app);
    _ = send(&app, .{ .pointer_down = input.left_at(pill) });
    _ = send(&app, .{ .pointer_up = input.left_at(.{ .x = 0, .y = 0 }) });
    try std.testing.expect(!app.toggles[1].on);
    try std.testing.expectEqual(@as(f32, 0), app.toggles[1].thumb.target);
}

// Locks hover easing and that a settled column stops animating and stays clean.
test "hover on gain eases and a later frame stays clean" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    try std.testing.expect(send(&app, .{ .pointer_move = center(area_rect(app.knobs[0].id)) }));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].hover.target);
    try std.testing.expect(ui.animate(App, &app, &test_context, 50));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), app.knobs[0].hover.value, 0.0001);
    try std.testing.expect(!ui.animate(App, &app, &test_context, 1000));
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].hover.value);
    _ = frame_at(&app, 1280, 720);
    try std.testing.expect(!ui.animate(App, &app, &test_context, 16));
    try std.testing.expect(!test_context.dirty);
}

// Locks that a redraw at a new size re-resolves the stored pointer and keeps hover on the
// knob still under it, without a synthetic move.
test "relayout by 8 px keeps gain hover" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    try std.testing.expect(send(&app, .{ .pointer_move = center(area_rect(app.knobs[0].id)) }));
    _ = frame_at(&app, 1288, 720);
    try std.testing.expectEqual(@as(f32, 1), app.knobs[0].hover.target);
    try std.testing.expectEqual(app.knobs[0].id, test_context.hovered());
    try std.testing.expect(!test_context.dirty);
}

// Locks that pointer leave drops capture without changing the value.
test "pointer leave during a knob press releases capture" {
    var app = new_app();
    _ = frame_at(&app, 1280, 720);
    try std.testing.expect(send(
        &app,
        .{ .pointer_down = input.left_at(center(area_rect(app.knobs[0].id))) },
    ));
    _ = send(&app, .pointer_leave);
    try std.testing.expectEqual(ui.Id.none, test_context.capture);
    try std.testing.expect(!test_context.pointer.inside);
    try std.testing.expectEqual(@as(f32, 0.25), app.knobs[0].value);
    try std.testing.expectEqual(@as(f32, 0), app.knobs[0].hover.target);
}

/// Records one 1280 by 720 logical frame of `cx` at `scale_120`.
fn record_at(
    renderer: *patchwork.renderer.Renderer(Context.DrawContext),
    buffer: *patchwork.commands.CommandBuffer,
    cx: *Context,
    scale_120: u32,
) void {
    buffer.reset();
    renderer.frame(buffer, &cx.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = patchwork.frame.pixel_size(1280, scale_120),
        .height_px = patchwork.frame.pixel_size(720, scale_120),
        .scale_120 = scale_120,
    });
}

// Locks the scale rules for a settled column: a present at the same scale draws nothing and
// writes nothing; a scale change owes a draw, which writes the glyph pool (and uniform and
// atlas) but no box or arc record; afterwards the column is idle again and rasterizes nothing.
test "a settled scene redraws only glyphs on a scale change" {
    var app = new_app();
    const cx = frame_at(&app, 1280, 720);
    const static = struct {
        var renderer: patchwork.renderer.Renderer(Context.DrawContext) = undefined;
        var buffer: patchwork.commands.CommandBuffer = undefined;
    };
    const renderer = &static.renderer;
    const buffer = &static.buffer;
    renderer.init();
    buffer.* = .init();
    renderer.setup(buffer, &cx.draw);
    record_at(renderer, buffer, cx, 120);
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!ui.draw_frame(App, &app, cx, 1280, 720, 120));
    const box_revision = cx.draw.revision(quads.Box);
    record_at(renderer, buffer, cx, 120);
    var writes: [4]patchwork.commands.BufferWrite = undefined;
    try std.testing.expectEqual(@as(usize, 0), patchwork.renderer.writes(buffer, &writes).len);
    try std.testing.expectEqual(box_revision, cx.draw.revision(quads.Box));

    try std.testing.expect(cx.draw.text.owes_draw(240));
    try std.testing.expect(ui.draw_frame(App, &app, cx, 1280, 720, 240));
    record_at(renderer, buffer, cx, 240);
    const written = patchwork.renderer.writes(buffer, &writes);
    const resources = &renderer.resources;
    try std.testing.expectEqual(@as(usize, 2), written.len);
    try std.testing.expectEqual(resources.uniform_buffer, written[0].id);
    try std.testing.expectEqual(resources.instance_buffers[2], written[1].id);
    try std.testing.expect(!cx.draw.text.owes_draw(240));
    try std.testing.expect(cx.draw.text.new_count > 0);

    // Idle: the host calls no draw, so nothing is rasterized and nothing is written.
    const entries = cx.draw.text.entry_count;
    try std.testing.expect(!ui.draw_frame(App, &app, cx, 1280, 720, 240));
    record_at(renderer, buffer, cx, 240);
    try std.testing.expectEqual(@as(usize, 0), patchwork.renderer.writes(buffer, &writes).len);
    try std.testing.expectEqual(entries, cx.draw.text.entry_count);
}

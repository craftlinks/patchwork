//! Fx example: a phosphor scope with bloom, and a panel that fades as one layer beside the
//! same panel faded instance by instance.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! Offscreen targets (step 25, `draw/fx.zig`), at fixed positions from the top-left:
//! ```text
//! scope        16, 56, 512 by 384     feedback target on layer 1: its own last frame at
//!                                     `persistence`, then this frame's trace (a Path)
//!              glow                   single target on layer 2: the scope blurred across;
//!                                     the base layer blurs it down with cover 0 (light)
//! one layer    544, 56, 256 by 384    the panel drawn into a single target on layer 3 and
//!                                     composited at opacity alpha
//! per instance 816, 56, 256 by 384    the same panel drawn directly, every alpha times alpha
//! ```
//! Where the panel's translucent cards overlap, "one layer" keeps the overlap as it is at
//! full opacity, only fainter; "per instance" lets the overlap pile up more coverage, so it
//! stands out (`draw/fx.zig`, test "a group composite fades as one layer, instances do not").
//!
//! ## 2. The Scope
//! A Lissajous figure of a drifting 3:2 pair, `trace_points` points over one period of the
//! figure, phase `phase_step` per drawn frame, over its last frame at `persistence` less
//! `fade_bias`, so the trail always fades to black: the clock is frames, not seconds, so frame N is
//! the same picture in every run (bench dumps compare). Space pauses: the trace stops, and the
//! scope keeps drawing `decay_frames` more frames, until `persistence^n` is below 1/255, then
//! the screen sleeps.
//!
//! ## 3. Opacity
//! A press on either fade panel steps alpha through `fades` (1, 0.7, 0.45, 0.25).
//!
//! ## 4. TigerStyle Invariants
//! Capacities are exact (comptime block); nothing allocates.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;
const fx = quads.fx;

const Rect = quads.Rect;

pub const scope_rect: Rect = .{ .x = 16, .y = 56, .width = 512, .height = 384 };
pub const one_rect: Rect = .{ .x = 544, .y = 56, .width = 256, .height = 384 };
pub const each_rect: Rect = .{ .x = 816, .y = 56, .width = 256, .height = 384 };

pub const trace_points: u32 = 256;
pub const persistence: f32 = 0.88;
/// Frames until `persistence^n < 1/255`: 0.88^44 = 0.0036.
pub const decay_frames: u32 = 44;
pub const phase_step: f32 = 0.045;
/// Levels a faded scope texel loses per frame beyond `persistence` (`draw/fx.zig`, section 3).
pub const fade_bias: f32 = 1.5 / 255.0;
pub const glow_radius: u32 = 8;
pub const fades = [_]f32{ 1, 0.7, 0.45, 0.25 };

const scope_layer: quads.Layer = @fromBackingInt(@intCast(1));
const glow_layer: quads.Layer = @fromBackingInt(@intCast(2));
const panel_layer: quads.Layer = @fromBackingInt(@intCast(3));

const trace_color: [4]f32 = .{ 0.35, 1.0, 0.55, 1 };
const card_colors = [3][4]f32{
    .{ 0.95, 0.45, 0.30, 0.6 },
    .{ 0.30, 0.70, 0.95, 0.6 },
    .{ 0.95, 0.85, 0.30, 0.6 },
};
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const label_style: text.Style = .{ .face = .sans, .size = 13, .color = theme.dark.colors.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

const one_id = ui.id("fade", 0);
const each_id = ui.id("fade", 1);

/// Panels and faces: the scope panel, two fade panel backgrounds and three cards each, and
/// their two inner faces.
const box_cap: u32 = 1 + 2 * (1 + 3 + 1);
const glyph_cap: u32 = 160;
const arc_cap: u32 = 2;
const path_cap: u32 = quads.path.chunks_max(trace_points);
const point_cap: u32 = trace_points;

comptime {
    assert(std.math.pow(f32, persistence, decay_frames) < 1.0 / 255.0);
    assert(std.math.pow(f32, persistence, decay_frames - 1) >= 1.0 / 255.0);
}

/// The fx screen. See the module guide.
pub const App = struct {
    scope: quads.TextureId,
    glow: quads.TextureId,
    panel: quads.TextureId,
    /// Drawn frames of the scope so far: its clock (section 2).
    frame: u32,
    running: bool,
    /// Frames still owed after a pause, while the trail decays.
    decaying: u32,
    fade: u8,

    pub const config: patchwork.app.Config = .{
        .title = "fx",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = quads.Composite, .cap = 3 },
            .{ .type = quads.Blur, .cap = 2 },
        },
        .batch_cap = 32,
        .area_cap = 2,
        .point_cap = point_cap,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "scope", .setup = &.{.{ .wait = 5 }}, .cycle = &.{}, .frames = 300 },
        .{
            .name = "fade",
            .setup = &.{ .{ .key = .{ .key = .other, .text = " " } }, .{ .wait = decay_frames + 4 } },
            .cycle = &.{ .{ .click = patchwork.bench.area("fade", 0) }, .{ .wait = 1 } },
            .frames = 200,
        },
        .{
            .name = "still",
            .setup = &.{ .{ .key = .{ .key = .other, .text = " " } }, .{ .wait = decay_frames + 4 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 60,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        app.scope = textures.create_target(.feedback);
        app.glow = textures.create_target(.single);
        app.panel = textures.create_target(.single);
        app.frame = 0;
        app.running = true;
        app.decaying = 0;
        app.fade = 0;
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .frame => {
                if (app.running or app.decaying > 0) {
                    cx.redraw();
                    cx.keep_animating();
                }
                return;
            },
            .key_down => |press| {
                if (press.key == .other and std.mem.eql(u8, press.typed(), " ")) {
                    app.running = !app.running;
                    app.decaying = if (app.running) 0 else decay_frames;
                    cx.redraw();
                }
                return;
            },
            else => {},
        }
        for ([_]ui.Id{ one_id, each_id }) |id| {
            switch (cx.hit(id, event_value)) {
                .down => {
                    app.fade = @intCast((app.fade + 1) % fades.len);
                    cx.redraw();
                },
                else => {},
            }
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = cx.window;
        const band: Rect = .{ .x = 16, .y = 0, .width = 1056, .height = 40 };
        const title = if (app.running) "fx: scope running (space pauses), click a panel to fade" else "fx: scope paused (space runs), click a panel to fade";
        text.place(draw_cx, title_style, title, band, clip_of(window), left);
        append_box(cx, scope_rect, .{ 0.05, 0.07, 0.06, 1 }, scope_rect, 8);
        app.draw_scope(cx);
        const alpha = fades[app.fade];
        // One layer: the panel into its target, composited at alpha.
        const one = one_rect.array();
        draw_cx.offscreen(panel_layer, app.panel, one);
        const previous = draw_cx.layer(panel_layer);
        draw_panel(cx, one_rect, 1);
        _ = draw_cx.layer(previous);
        fx.composite(draw_cx, app.panel, one, one, clip_of(one_rect).array(), alpha, 1, 0);
        // Per instance: the same panel, every alpha times alpha.
        draw_panel(cx, each_rect, alpha);
        cx.area(one_id, one_rect, 0, ui.cx.plain);
        cx.area(each_id, each_rect, 0, ui.cx.plain);
        const label_y = one_rect.y + one_rect.height;
        text.place(draw_cx, label_style, "one layer", .{ .x = one_rect.x, .y = label_y, .width = 256, .height = 24 }, clip_of(window), left);
        text.place(draw_cx, label_style, "per instance", .{ .x = each_rect.x, .y = label_y, .width = 256, .height = 24 }, clip_of(window), left);
        text.place(draw_cx, label_style, "feedback target, blurred glow", .{ .x = scope_rect.x, .y = label_y, .width = 512, .height = 24 }, clip_of(window), left);
        if (!app.running and app.decaying > 0) app.decaying -= 1;
        if (app.running) app.frame += 1;
    }

    /// The scope (section 2): last frame at `persistence`, this frame's trace, and the glow.
    fn draw_scope(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const inner = inset(scope_rect, 8);
        const target = inner.array();
        const clip = clip_of(inner).array();
        draw_cx.offscreen(scope_layer, app.scope, target);
        const previous = draw_cx.layer(scope_layer);
        fx.composite(draw_cx, app.scope, target, target, clip, persistence, 1, fade_bias);
        if (app.running) {
            var points: [trace_points]quads.path.Point = undefined;
            trace(app.frame, inner, &points);
            _ = quads.path.polyline(draw_cx, &points, .{ .color = trace_color, .width = 2, .hover = 0 }, clip_of(inner));
        }
        draw_cx.offscreen(glow_layer, app.glow, target);
        _ = draw_cx.layer(glow_layer);
        fx.blur(draw_cx, app.scope, target, target, clip, 0, glow_radius, 1, 1);
        _ = draw_cx.layer(previous);
        fx.composite(draw_cx, app.scope, target, target, clip, 1, 1, 0);
        fx.blur(draw_cx, app.glow, target, target, clip, 1, glow_radius, 0.9, 0);
    }
};

pub const Context = patchwork.app.Context(App);

/// The trace of drawn frame `frame` in `rect` (section 2).
pub fn trace(frame: u32, rect: Rect, out: *[trace_points]quads.path.Point) void {
    const phase = @as(f32, @floatFromInt(frame)) * phase_step;
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const rx = rect.width * 0.42;
    const ry = rect.height * 0.42;
    const swell = 0.85 + 0.15 * @sin(phase * 0.7);
    for (out, 0..) |*point, index| {
        const t = std.math.tau * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(trace_points - 1));
        point.* = .{
            cx + rx * swell * @sin(3 * t + phase),
            cy + ry * swell * @sin(2 * t),
        };
    }
}

/// The fade panel at `rect`, every alpha times `alpha`: a face, three overlapping cards, a
/// ring, and a label.
fn draw_panel(cx: *Context, rect: Rect, alpha: f32) void {
    const face = inset(rect, 0);
    append_box(cx, face, scale_alpha(.{ 0.20, 0.24, 0.32, 1 }, alpha), rect, 10);
    for (card_colors, 0..) |color, index| {
        const offset = @as(f32, @floatFromInt(index)) * 46;
        const card: Rect = .{ .x = rect.x + 28 + offset, .y = rect.y + 40 + offset, .width = 120, .height = 150 };
        append_box(cx, card, scale_alpha(color, alpha), rect, 12);
    }
    const ring: Rect = .{ .x = rect.x + 64, .y = rect.y + 250, .width = 96, .height = 96 };
    const ring_look: quads.ArcLook = .{ .color = scale_alpha(.{ 0.55, 0.85, 0.45, 0.8 }, alpha), .thickness = 10, .sweep = 0.7 };
    cx.append(quads.Arc, null, .of(ring, clip_of(rect), ring_look)) catch {};
    var style = label_style;
    style.color = scale_alpha(cx.theme().colors.text, alpha);
    text.place(cx.drawing(), style, "translucent cards", .{ .x = rect.x + 16, .y = rect.y + 8, .width = rect.width - 32, .height = 24 }, clip_of(rect), left);
}

fn scale_alpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

fn inset(rect: Rect, by: f32) Rect {
    return .{ .x = rect.x + by, .y = rect.y + by, .width = rect.width - 2 * by, .height = rect.height - 2 * by };
}

fn append_box(cx: *Context, rect: Rect, color: [4]f32, clip: Rect, radius: f32) void {
    kit.append(cx, quads.Box, null, .of(rect, clip_of(clip), .{ .fill = color, .radius = radius }));
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

// Locks the bindings and the instances (section 1): three layers bound to the three targets,
// the scope's composite of itself and its trace on layer 1, its blur on layer 2, and on the
// base layer the scope, the glow (cover 0), and the panel's composite at alpha 1.
test "the screen binds three targets and composites them" {
    const app = new_app();
    const cx = frame_at(app);
    const bindings = cx.draw.binding_list();
    try std.testing.expectEqual(@as(usize, 3), bindings.len);
    try std.testing.expectEqual(app.scope, bindings[0].target);
    try std.testing.expectEqual(@as(u8, 1), bindings[0].layer);
    try std.testing.expectEqual(app.panel, bindings[2].target);
    try std.testing.expectEqual([4]f32{ 24, 64, 496, 368 }, bindings[0].rect);
    const composites = cx.draw.items(quads.Composite);
    try std.testing.expectEqual(@as(usize, 3), composites.len);
    const blurs = cx.draw.items(quads.Blur);
    try std.testing.expectEqual(@as(usize, 2), blurs.len);
    var light = false;
    for (blurs) |blur| light = light or blur.cover == 0;
    try std.testing.expect(light);
    try std.testing.expect(cx.draw.items(quads.Path).len >= 1);
}

// Locks opacity (section 3): a press on a fade panel steps alpha, the one-layer composite
// carries it, and the per-instance panel scales each card's alpha instead.
test "a press steps the fade and the two panels apply it differently" {
    const app = new_app();
    _ = frame_at(app);
    const press: input.Button = .{ .x = one_rect.x + 10, .y = one_rect.y + 10, .time_ms = 0, .button = .left, .mods = .none };
    send(app, .{ .pointer_move = .{ .x = press.x, .y = press.y } });
    send(app, .{ .pointer_down = press });
    send(app, .{ .pointer_up = press });
    try std.testing.expectEqual(@as(u8, 1), app.fade);
    const cx = frame_at(app);
    var panel_alpha: f32 = 0;
    for (cx.draw.items(quads.Composite)) |composite| {
        if (composite.rect[0] == one_rect.x) panel_alpha = composite.opacity;
    }
    try std.testing.expectEqual(@as(f32, 0.7), panel_alpha);
    var faded_card = false;
    for (cx.draw.items(quads.Box)) |box| {
        if (box.rect[0] == each_rect.x + 28) faded_card = @abs(box.fill[3] - 0.6 * 0.7) < 1e-6;
    }
    try std.testing.expect(faded_card);
}

// Locks the scope clock (section 2): the trace is a function of the drawn frame only; Space
// pauses it, the scope keeps animating `decay_frames` frames with no trace, then nothing is
// owed and the screen sleeps.
test "the scope pauses, decays, and sleeps" {
    var a: [trace_points]quads.path.Point = undefined;
    var b: [trace_points]quads.path.Point = undefined;
    trace(7, scope_rect, &a);
    trace(7, scope_rect, &b);
    try std.testing.expectEqualSlices(quads.path.Point, &a, &b);
    const app = new_app();
    _ = frame_at(app);
    try std.testing.expectEqual(@as(u32, 1), app.frame);
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(!app.running);
    for (0..decay_frames) |_| {
        try std.testing.expect(ui.animate(App, app, &fixture.context, 16));
        const cx = frame_at(app);
        try std.testing.expectEqual(@as(usize, 0), cx.draw.items(quads.Path).len);
    }
    try std.testing.expect(!ui.animate(App, app, &fixture.context, 16));
    try std.testing.expectEqual(@as(u32, 1), app.frame);
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a): fade pauses the scope
// and steps alpha by clicks.
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    const app = new_app();
    const fade = bench.find(App.scenarios, "fade").?;
    // The decay wait is `decay_frames + 4` frames; the first click comes after it.
    _ = try bench.replay_headless(App, app, cx, fade, .{ 1280, 720 }, decay_frames + 8);
    try std.testing.expect(!app.running);
    try std.testing.expect(app.fade != 0);
}

comptime {
    patchwork.app.check(App);
}

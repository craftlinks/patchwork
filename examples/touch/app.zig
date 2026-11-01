//! Touch example: several fingers at once, each under its own pointer state.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! Multi-touch through the pointer events widgets already read (`ui/cx.zig`, section 5b): the app
//! never sees a touch event, so every widget here is an ordinary one, and a finger on each moves
//! it. The mouse works on all of it by construction. At fixed positions from the top-left:
//! ```text
//! title    16, 0, 1248 by 40
//! pads     8 pads, 140 by 140, at x = 16 + 156 * i, y = 56: each lights while any pointer holds it
//! sliders  two `widgets.Slider`s, 600 by 40 at (16, 232) and (664, 232), moved by two fingers
//! knob     one `widgets.Knob` at (16, 296), dragged by a finger up or down
//! box      400, 296, 480 by 340: a `ui.gestures.Recognizer` over every kind, moving a square
//! hud      16, 664, 1248 by 24: live contacts, the most at once, and the refused ones
//! ```
//!
//! ## 2. Pads
//! A `Pad` is one id with `held`, set by `down` and cleared by `up`, and it counts its presses. A
//! second finger on a held pad is joined: it does not press the pad again, and its lift does not
//! release it. Ten fingers are eight pads and two sliders, in one frame (scenario `chord`).
//!
//! ## 2a. The Box
//! The square moves and grows with the gestures its box recognizes (`ui/gestures.zig`): a
//! one-finger drag moves it, a pinch scales it, a two-finger pan moves it, a two-finger tap puts it
//! back, a long-press turns it orange, and a tap names itself on the box's first line. The
//! mouse's left button gives the one-finger set.
//!
//! ## 3. Scenarios
//! Fingers are absolute points (`bench.Finger`), so a step is a chord:
//! ```text
//! still    the screen at rest
//! sliders  two fingers land on the two sliders and move in one step each: both values follow
//! chord    ten fingers land in one step: eight pads and the two sliders, none lifted
//! cancel   fingers on pads 0 and 1, the system takes finger 0: pad 0 releases with no press
//! pinch    two fingers land on the box in one step and move apart: the square grows
//! two-tap  two fingers land on the box and lift a frame later: the square goes back
//! long-press  a finger rests on the box for 500 ms: the square turns orange
//! ```
//!
//! ## 4. TigerStyle Invariants
//! - No allocation, no timer (`timer_period_ms` 0): the app sleeps with a finger held.
//! - The HUD's text is formatted into a fixed buffer; every capacity is checked in the comptime
//!   block.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const input = patchwork.input;
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const gestures = ui.gestures;

const Rect = quads.Rect;
const Clip = quads.Clip;

pub const pad_count: u32 = 8;
pub const pad_side: f32 = 140;
pub const pad_pitch: f32 = 156;
pub const pad_y: f32 = 56;
pub const slider_width: f32 = 600;
pub const slider_height: f32 = 40;
pub const slider_y: f32 = 232;
pub const slider_x = [2]f32{ 16, 664 };
pub const knob_rect: Rect = .{ .x = 16, .y = 296, .width = 160, .height = 80 };
pub const hud_rect: Rect = .{ .x = 16, .y = 664, .width = 1248, .height = 24 };
pub const hud_cap: u32 = 96;
pub const box_rect: Rect = .{ .x = 400, .y = 296, .width = 480, .height = 340 };
/// The square's side at scale 1.
pub const square_side: f32 = 100;
const box_id = ui.id("box", 0);

const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const label_style: text.Style = .{ .face = .sans_bold, .size = 22, .color = theme.dark.colors.text };
const hud_style: text.Style = .{ .face = .mono, .size = 13, .color = theme.dark.colors.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

/// Where pad `index` is.
pub fn pad_rect(index: u32) Rect {
    assert(index < pad_count);
    return .{
        .x = 16 + pad_pitch * @as(f32, @floatFromInt(index)),
        .y = pad_y,
        .width = pad_side,
        .height = pad_side,
    };
}

/// The centre of pad `index`: where a scenario's finger lands.
pub fn pad_centre(index: u32) [2]f32 {
    const rect = pad_rect(index);
    return .{ rect.x + rect.width * 0.5, rect.y + rect.height * 0.5 };
}

/// The x of a slider's value `value` along its travel, for a scenario's finger.
pub fn slider_at(index: u32, value: f32) f32 {
    assert(index < 2);
    assert(value >= 0 and value <= 1);
    const travel = slider_width - 2 * widgets.knob_radius;
    return slider_x[index] + widgets.knob_radius + value * travel;
}

const slider_mid_y: f32 = slider_y + slider_height * 0.5;

/// A pad: lit while a pointer holds it.
pub const Pad = struct {
    id: ui.Id,
    index: u32,
    held: bool,
    presses: u32,

    pub const Action = union(enum) {
        none,
        pressed,
        released,
    };

    pub fn handle(self: *Pad, cx: anytype, event: input.Event) Action {
        switch (cx.hit(self.id, event)) {
            .down => {
                self.held = true;
                self.presses += 1;
                cx.redraw();
                return .pressed;
            },
            .up => {
                self.held = false;
                cx.redraw();
                return .released;
            },
            .none, .hover_in, .hover_out, .drag, .wheel, .secondary => return .none,
        }
    }

    pub fn draw(self: *const Pad, cx: anytype) void {
        const rect = pad_rect(self.index);
        const clip = cx.visible(rect) orelse return;
        const scheme = cx.theme();
        const fill = if (self.held) scheme.accents[self.index % theme.accent_count] else scheme.colors.track;
        kit.face(cx, rect, clip, .{ .fill = fill, .radius = 12 });
        var buffer: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{self.index + 1}) catch unreachable;
        text.place(cx.drawing(), label_style, label, rect, clip, kit.centered);
        cx.area(self.id, rect, 12, ui.cx.plain);
    }
};

const box_fill: [4]f32 = .{ 0.16, 0.18, 0.25, 1 };

/// The touch screen. See the module guide.
pub const App = struct {
    pads: [pad_count]Pad,
    sliders: [2]widgets.Slider,
    knob: widgets.Knob,
    hud: [hud_cap]u8,
    hud_len: u32,
    recognizer: gestures.Recognizer,
    /// The square: its scale and offset now, and at the start of the gesture moving it.
    scale: f32,
    offset: [2]f32,
    base_scale: f32,
    base_offset: [2]f32,
    armed: bool,
    last: []const u8,

    pub const config: patchwork.app.Config = .{
        .title = "touch",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 64 },
            .{ .type = quads.Arc, .cap = 16 },
            .{ .type = quads.Glyph, .cap = 512 },
        },
        .batch_order = .registered,
        .batch_cap = 16,
        .area_cap = 32,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 3 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 10 },
        .{
            .name = "sliders",
            .setup = &.{
                .{ .touch = &.{
                    .{ .id = 0, .phase = .down, .x = slider_at(0, 0.25), .y = slider_mid_y },
                    .{ .id = 1, .phase = .down, .x = slider_at(1, 0.75), .y = slider_mid_y },
                } },
                .{ .touch = &.{
                    .{ .id = 0, .phase = .move, .x = slider_at(0, 0.6), .y = slider_mid_y },
                    .{ .id = 1, .phase = .move, .x = slider_at(1, 0.2), .y = slider_mid_y },
                } },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "chord",
            .setup = &.{
                .{ .touch = &.{
                    .{ .id = 0, .phase = .down, .x = pad_centre(0)[0], .y = pad_centre(0)[1] },
                    .{ .id = 1, .phase = .down, .x = pad_centre(1)[0], .y = pad_centre(1)[1] },
                    .{ .id = 2, .phase = .down, .x = pad_centre(2)[0], .y = pad_centre(2)[1] },
                    .{ .id = 3, .phase = .down, .x = pad_centre(3)[0], .y = pad_centre(3)[1] },
                    .{ .id = 4, .phase = .down, .x = pad_centre(4)[0], .y = pad_centre(4)[1] },
                    .{ .id = 5, .phase = .down, .x = pad_centre(5)[0], .y = pad_centre(5)[1] },
                    .{ .id = 6, .phase = .down, .x = pad_centre(6)[0], .y = pad_centre(6)[1] },
                    .{ .id = 7, .phase = .down, .x = pad_centre(7)[0], .y = pad_centre(7)[1] },
                    .{ .id = 8, .phase = .down, .x = slider_at(0, 0.5), .y = slider_mid_y },
                    .{ .id = 9, .phase = .down, .x = slider_at(1, 0.5), .y = slider_mid_y },
                } },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "pinch",
            .setup = &.{
                .{ .touch = &.{
                    .{ .id = 0, .phase = .down, .x = 560, .y = 466 },
                    .{ .id = 1, .phase = .down, .x = 720, .y = 466 },
                } },
                .{ .touch = &.{
                    .{ .id = 0, .phase = .move, .x = 540, .y = 466 },
                    .{ .id = 1, .phase = .move, .x = 740, .y = 466 },
                } },
                .{ .touch = &.{
                    .{ .id = 0, .phase = .move, .x = 520, .y = 466 },
                    .{ .id = 1, .phase = .move, .x = 760, .y = 466 },
                } },
                .{ .touch = &.{
                    .{ .id = 0, .phase = .move, .x = 500, .y = 466 },
                    .{ .id = 1, .phase = .move, .x = 780, .y = 466 },
                } },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "two-tap",
            .setup = &.{
                .{ .touch = &.{
                    .{ .id = 0, .phase = .down, .x = 560, .y = 466 },
                    .{ .id = 1, .phase = .down, .x = 720, .y = 466 },
                } },
                .{ .touch = &.{
                    .{ .id = 0, .phase = .up },
                    .{ .id = 1, .phase = .up },
                } },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "long-press",
            .setup = &.{
                .{ .touch = &.{.{ .id = 0, .phase = .down, .x = 640, .y = 466 }} },
                .{ .wait = 30 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "cancel",
            .setup = &.{
                .{ .touch = &.{
                    .{ .id = 0, .phase = .down, .x = pad_centre(0)[0], .y = pad_centre(0)[1] },
                    .{ .id = 1, .phase = .down, .x = pad_centre(1)[0], .y = pad_centre(1)[1] },
                } },
                .{ .touch = &.{.{ .id = 0, .phase = .cancel }} },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        for (&app.pads, 0..) |*pad, index| {
            pad.* = .{
                .id = ui.id("pad", @intCast(index)),
                .index = @intCast(index),
                .held = false,
                .presses = 0,
            };
        }
        for (&app.sliders, [2]f32{ 0.5, 0.5 }, 0..) |*slider, value, index| {
            slider.* = .{
                .id = ui.id("slider", @intCast(index)),
                .hover = .init(widgets.hover_rate_per_ms),
                .value = value,
                .track = widgets.paint_of(theme.dark.colors.track, widgets.track_radius),
                .fill = widgets.paint_of(theme.dark.colors.value, widgets.track_radius),
                .knob = widgets.paint_of(theme.dark.colors.control, widgets.knob_radius),
            };
        }
        app.knob = widgets.Knob.init(ui.id("knob", 0), "gain", 0.5, widgets.accents[0]);
        app.hud_len = 0;
        app.recognizer = .init(.all, .{});
        app.scale = 1;
        app.offset = .{ 0, 0 };
        app.base_scale = 1;
        app.base_offset = .{ 0, 0 };
        app.armed = false;
        app.last = "none";
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        // The HUD counts contacts, which change on every touch event.
        if (cx.touch() != null) cx.redraw();
        _ = ui.route(cx, event_value, app);
        const gesture = app.recognizer.handle(cx, box_id, event_value);
        if (gesture != .none) {
            app.apply(gesture);
            cx.redraw();
        }
    }

    /// What a gesture does to the square (module guide, section 2a).
    fn apply(app: *App, gesture: gestures.Gesture) void {
        switch (gesture) {
            .none => {},
            .tap => app.last = "tap",
            .long_press => {
                app.last = "long press";
                app.armed = true;
            },
            .drag => |drag| {
                if (drag.phase == .began) app.base_offset = app.offset;
                app.last = "drag";
                app.offset = .{ app.base_offset[0] + drag.dx, app.base_offset[1] + drag.dy };
            },
            .two_finger_tap => {
                app.last = "two-finger tap";
                app.scale = 1;
                app.offset = .{ 0, 0 };
                app.armed = false;
            },
            .two_finger => |two| {
                if (two.phase == .began) {
                    app.base_scale = app.scale;
                    app.base_offset = app.offset;
                }
                app.last = if (two.pinching and two.panning)
                    "pinch and pan"
                else if (two.pinching) "pinch" else "two-finger pan";
                if (two.phase == .cancelled) {
                    app.scale = app.base_scale;
                    app.offset = app.base_offset;
                } else {
                    app.scale = std.math.clamp(app.base_scale * two.scale, 0.3, 3);
                    app.offset = .{ app.base_offset[0] + two.dx, app.base_offset[1] + two.dy };
                }
            },
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    /// The gesture box: its face, the square, and the last gesture's name.
    fn draw_box(app: *const App, cx: *Context, clip: Clip) void {
        const scheme = cx.theme();
        kit.face(cx, box_rect, clip, .{ .fill = box_fill, .radius = 12 });
        const side = square_side * app.scale;
        const centre_x = box_rect.x + box_rect.width * 0.5 + app.offset[0];
        const centre_y = box_rect.y + box_rect.height * 0.5 + app.offset[1];
        const square: Rect = .{
            .x = centre_x - side * 0.5,
            .y = centre_y - side * 0.5,
            .width = side,
            .height = side,
        };
        const inside = quads.Clip{
            .x0 = box_rect.x,
            .y0 = box_rect.y,
            .x1 = box_rect.x + box_rect.width,
            .y1 = box_rect.y + box_rect.height,
        };
        const fill = if (app.armed) scheme.accents[2] else scheme.accents[0];
        kit.face(cx, square, inside, .{ .fill = fill, .radius = 8 });
        var buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "last: {s}   scale {d:.2}", .{ app.last, app.scale }) catch unreachable;
        const label: Rect = .{ .x = box_rect.x + 12, .y = box_rect.y + 8, .width = box_rect.width - 24, .height = 24 };
        text.place(cx.drawing(), hud_style, line, label, inside, left);
        cx.area(box_id, box_rect, 12, ui.cx.plain);
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = cx.window.width, .y1 = cx.window.height };
        const title: Rect = .{ .x = 16, .y = 0, .width = 1248, .height = 40 };
        text.place(draw_cx, title_style, "touch: one finger per pad and slider, the mouse too", title, clip, left);
        for (&app.pads) |*pad| pad.draw(cx);
        for (&app.sliders, slider_x) |*slider, x| {
            const rect: Rect = .{ .x = x, .y = slider_y, .width = slider_width, .height = slider_height };
            _ = cx.begin_at(rect, .{ .flow = .down });
            slider.draw(cx, ui.sized(.fill, .fill));
            _ = cx.end();
        }
        _ = cx.begin_at(knob_rect, .{ .flow = .down });
        app.knob.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        app.draw_box(cx, clip);
        const hud = std.fmt.bufPrint(
            &app.hud,
            "live {d}  most {d}  refused {d}",
            .{ cx.contacts_live(), cx.contacts_most, cx.contacts_refused },
        ) catch unreachable;
        app.hud_len = @intCast(hud.len);
        text.place(draw_cx, hud_style, hud, hud_rect, clip, left);
    }
};

pub const Context = patchwork.app.Context(App);

comptime {
    patchwork.app.check(App);
    assert(pad_pitch * (pad_count - 1) + pad_side + 16 <= 1280);
    assert(slider_x[1] + slider_width + 16 == 1280);
}

const fixture = struct {
    var context: Context = undefined;
    var app: App = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    var textures: quads.Textures = undefined;
    App.init(&fixture.app, &textures);
    return &fixture.app;
}

fn frame_at(app: *App) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, 1280, 720, 120));
    return cx;
}

fn send(app: *App, event_value: input.Event) void {
    ui.dispatch(App, app, &fixture.context, event_value);
}

fn down(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = 0 } };
}

fn move(id: u32, x: f32, y: f32) input.Event {
    return .{ .touch_move = .{ .id = id, .x = x, .y = y, .time_ms = 0 } };
}

fn lift(id: u32) input.Event {
    return .{ .touch_up = .{ .id = id, .time_ms = 0 } };
}

// Locks two sliders under two fingers: each follows its own finger to its own value, the knob
// beside them is untouched, and the mouse can press a pad in the same frames.
test "two sliders move at once under two fingers" {
    const app = new_app();
    const cx = frame_at(app);
    send(app, down(0, slider_at(0, 0.25), slider_mid_y));
    send(app, down(1, slider_at(1, 0.75), slider_mid_y));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), app.sliders[0].value, 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), app.sliders[1].value, 1.0e-3);
    send(app, move(0, slider_at(0, 0.6), slider_mid_y));
    send(app, move(1, slider_at(1, 0.2), slider_mid_y));
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), app.sliders[0].value, 1.0e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), app.sliders[1].value, 1.0e-3);
    const centre = pad_centre(2);
    send(app, .{ .pointer_down = input.left_at(.{ .x = centre[0], .y = centre[1] }) });
    try std.testing.expect(app.pads[2].held);
    send(app, move(0, slider_at(0, 0.7), slider_mid_y));
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), app.sliders[0].value, 1.0e-3);
    try std.testing.expect(app.pads[2].held);
    try std.testing.expectEqual(@as(u32, 2), cx.contacts_live());
}

// Locks the chord: ten fingers in one step hold all eight pads and both sliders at once, the
// HUD's counts say ten, and lifting them frees the table.
test "a chord of ten holds eight pads and two sliders" {
    const app = new_app();
    const cx = frame_at(app);
    for (0..8) |index| {
        const centre = pad_centre(@intCast(index));
        send(app, down(@intCast(index), centre[0], centre[1]));
    }
    send(app, down(8, slider_at(0, 0.5), slider_mid_y));
    send(app, down(9, slider_at(1, 0.5), slider_mid_y));
    for (app.pads) |pad| try std.testing.expect(pad.held);
    try std.testing.expectEqual(@as(u32, 10), cx.contacts_live());
    _ = frame_at(app);
    try std.testing.expectEqualStrings("live 10  most 10  refused 0", app.hud[0..app.hud_len]);
    for (0..10) |id| send(app, lift(@intCast(id)));
    for (app.pads) |pad| try std.testing.expect(!pad.held);
    try std.testing.expectEqual(@as(u32, 0), cx.contacts_live());
}

// Locks a second finger on a held pad: it is joined, so the pad counts one press and one lift
// of the second finger leaves it lit until the first lifts.
test "a second finger on a held pad does not press it again" {
    const app = new_app();
    _ = frame_at(app);
    const centre = pad_centre(0);
    send(app, down(0, centre[0], centre[1]));
    send(app, down(1, centre[0] + 5, centre[1] + 5));
    try std.testing.expectEqual(@as(u32, 1), app.pads[0].presses);
    send(app, lift(1));
    try std.testing.expect(app.pads[0].held);
    send(app, lift(0));
    try std.testing.expect(!app.pads[0].held);
}

// Locks cancel: the system taking finger 0 releases pad 0 with no click, and pad 1 stays held.
test "a cancelled finger releases its pad" {
    const app = new_app();
    _ = frame_at(app);
    const a = pad_centre(0);
    const b = pad_centre(1);
    send(app, down(0, a[0], a[1]));
    send(app, down(1, b[0], b[1]));
    send(app, .{ .touch_cancel = 0 });
    try std.testing.expect(!app.pads[0].held);
    try std.testing.expect(app.pads[1].held);
    send(app, .{ .touch_cancel = null });
    try std.testing.expect(!app.pads[1].held);
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a).
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    for (App.scenarios) |*scenario| {
        const app = new_app();
        _ = try bench.replay_headless(App, app, cx, scenario, .{ 1280, 720 }, 6);
        try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    }
}

fn timed_down(id: u32, x: f32, y: f32, time_ms: u32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = time_ms } };
}

// Locks the box: a pinch by two fingers that landed together grows the square by the distance
// ratio (160 px to 280 is 1.75) and a pan of the pair moves it; a two-finger tap puts both back;
// the mouse's left drag moves it too.
test "the box pinches, pans, resets, and drags" {
    const app = new_app();
    _ = frame_at(app);
    send(app, timed_down(0, 560, 466, 1000));
    send(app, timed_down(1, 720, 466, 1010));
    // Fingers move one event at a time, so each step is small enough that the pair's centroid
    // never strays past the pan's slop between two of them.
    for ([_]f32{ 20, 40, 60 }) |travel| {
        send(app, move(0, 560 - travel, 466));
        send(app, move(1, 720 + travel, 466));
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), app.scale, 1.0e-4);
    try std.testing.expectEqualStrings("pinch", app.last);
    send(app, lift(0));
    send(app, lift(1));
    send(app, timed_down(0, 560, 466, 2000));
    send(app, timed_down(1, 720, 466, 2010));
    send(app, .{ .touch_up = .{ .id = 0, .time_ms = 2100 } });
    send(app, .{ .touch_up = .{ .id = 1, .time_ms = 2110 } });
    try std.testing.expectEqualStrings("two-finger tap", app.last);
    try std.testing.expectEqual(@as(f32, 1), app.scale);
    send(app, .{ .pointer_down = input.left_at(.{ .x = 500, .y = 400 }) });
    send(app, .{ .pointer_move = .{ .x = 560, .y = 430 } });
    try std.testing.expectEqualStrings("drag", app.last);
    try std.testing.expectEqual([2]f32{ 60, 30 }, app.offset);
}

// Locks the long-press: a finger resting on the box for 400 ms of frames turns the square orange
// (`armed`), and the app asks for frames until then and not after.
test "a finger resting on the box arms it after 400 ms" {
    const app = new_app();
    const cx = frame_at(app);
    send(app, down(0, 640, 466));
    var frames: u32 = 0;
    while (frames < 40 and !app.armed) : (frames += 1) {
        const more = ui.animate(App, app, cx, 16);
        // The frame that fires it asks for no more.
        try std.testing.expect(more or app.armed);
    }
    try std.testing.expect(app.armed);
    try std.testing.expectEqualStrings("long press", app.last);
    try std.testing.expect(!ui.animate(App, app, cx, 16));
}

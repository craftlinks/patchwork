//! Audio example: stereo meters, a triggered scope, and an XY trace with persistence, all fed by
//! Thrum's test tone through Patchwork's producer seam.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! A peer's audio through the producer contract (`app.zig`, section 4e; step 55): the app owns a
//! `tone.Tone`, which plays Thrum's test tone on a PipeWire device natively and in Thrum's
//! AudioWorklet in the browser, audible on both, and hands each block it played to the UI thread
//! (`tone.zig`). At fixed positions from the top-left:
//! ```text
//! meters  16, 56, 160 by 384    L and R: RMS fill, peak line, hold tick, 60 dB scale
//! scope   192, 56, 512 by 384   L and R, 512 frames from the latest rising crossing of L
//! xy      720, 56, 352 by 384   L against R, the last 512 frames over the trace's own last
//!                               frame at `persistence` (a feedback target, step 25)
//! stats   16, 456, 1056 by 24   blocks received, blocks dropped, running or stopped
//! ```
//!
//! ## 2. Data Flow
//! `drain` takes every block waiting; each updates four `thrum.level.Ballistics` (RMS and peak of
//! L and R, on the meter scale), pushes into the `thrum.level.Scope` history, counts, and owes a
//! draw. The meters therefore move by the block (2.67 ms), not by the frame, and a frame draws
//! whatever arrived since the last one. Nothing here runs on a timer: with the tone stopped no
//! block arrives and nothing is drawn.
//!
//! ## 3. Start and Stop
//! Space toggles the tone. Stopping resets the meters to 0 and keeps the scope's last window; the
//! XY trail keeps drawing `decay_frames` frames until it has faded below 1/255, then the screen
//! sleeps. Regress and the bench step the tone frame by frame through `produce`, so `play` dumps
//! are deterministic. Natively a start that cannot open the device says so in the title.
//!
//! ## 4. TigerStyle Invariants
//! Capacities are exact (comptime block); a block costs O(128) and a frame O(scope frames).

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const thrum = @import("thrum");
const testtone = @import("testtone");
const tone = @import("tone.zig");
const quads = patchwork.draw;
const input = patchwork.input;
const level = thrum.level;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;
const fx = quads.fx;

const Rect = quads.Rect;

pub const meters_rect: Rect = .{ .x = 16, .y = 56, .width = 160, .height = 384 };
pub const scope_rect: Rect = .{ .x = 192, .y = 56, .width = 512, .height = 384 };
pub const xy_rect: Rect = .{ .x = 720, .y = 56, .width = 352, .height = 384 };
pub const stats_rect: Rect = .{ .x = 16, .y = 456, .width = 1056, .height = 24 };

/// Frames the scope and the XY trace show: one per scope pixel.
pub const scope_frames: u32 = 512;
/// Pixels per unit of signal: the tone's peak of 0.5 is 150 px from the center.
pub const signal_scale: f32 = 300;
/// The meter tracks: the bars' tops, their height (60 dB, so 16/3 px per dB), and x positions.
pub const track_top: f32 = 80;
pub const track_height: f32 = 320;
pub const bar_width: f32 = 32;
pub const bar_x = [tone.channels]f32{ 48, 112 };
/// The scale marks, in dBFS.
pub const marks_db = [_]f32{ -6, -12, -24, -48 };

pub const persistence: f32 = 0.88;
/// Frames until `persistence^n < 1/255`: 0.88^44 = 0.0036.
pub const decay_frames: u32 = 44;
/// Levels a faded XY texel loses per frame beyond `persistence` (`draw/fx.zig`, section 3).
pub const fade_bias: f32 = 1.5 / 255.0;

pub const Scope = level.Scope(scope_frames, tone.channels);

const xy_layer: quads.Layer = @fromBackingInt(@intCast(1));

const face_color: [4]f32 = .{ 0.05, 0.07, 0.06, 1 };
const rms_color: [4]f32 = .{ 0.25, 0.75, 0.40, 1 };
const peak_color: [4]f32 = .{ 0.75, 1.0, 0.80, 1 };
const hold_color: [4]f32 = .{ 1.0, 0.75, 0.25, 1 };
const mark_color: [4]f32 = .{ 1, 1, 1, 0.18 };
const trace_colors = [tone.channels][4]f32{
    .{ 0.35, 1.0, 0.55, 1 },
    .{ 0.40, 0.70, 1.0, 1 },
};
const xy_color: [4]f32 = .{ 0.35, 1.0, 0.55, 1 };
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const label_style: text.Style = .{ .face = .sans, .size = 13, .color = theme.dark.colors.text };
const mark_style: text.Style = .{ .face = .sans, .size = 11, .color = theme.dark.colors.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
const centered: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = false };

/// The three faces, per bar a track, an RMS fill, a peak line, and a hold tick, the marks, and
/// the scope's center line.
const box_cap: u32 = 3 + tone.channels * 4 + marks_db.len + 1;
const glyph_cap: u32 = 256;
/// Two scope traces and the XY trace.
const trace_count: u32 = 3;
const path_cap: u32 = trace_count * quads.path.chunks_max(scope_frames);
const point_cap: u32 = trace_count * scope_frames;
const stats_cap: u32 = 96;
/// The title band's longest line: a failure names the device's error.
const title_cap: u32 = 96;

comptime {
    assert(std.math.pow(f32, persistence, decay_frames) < 1.0 / 255.0);
    assert(std.math.pow(f32, persistence, decay_frames - 1) >= 1.0 / 255.0);
    assert(scope_rect.width == @as(f32, @floatFromInt(scope_frames)));
    assert(track_top + track_height <= meters_rect.y + meters_rect.height);
    // The tone's peak stays inside the scope and the XY panel.
    assert((testtone.gain_floor + testtone.gain_swing) * signal_scale < scope_rect.height / 2);
    assert((testtone.gain_floor + testtone.gain_swing) * signal_scale < xy_rect.width / 2);
}

/// One meter bar's ballistics.
pub const Bar = struct {
    rms: level.Ballistics,
    peak: level.Ballistics,

    pub const zero: Bar = .{ .rms = .zero, .peak = .zero };
};

/// The audio screen. See the module guide.
pub const App = struct {
    bars: [tone.channels]Bar,
    scope: Scope,
    xy: quads.TextureId,
    /// Blocks received since startup.
    blocks: u64,
    /// Frames still owed after a stop, while the XY trail decays.
    decaying: u32,
    /// The tone and its hosts (`tone.zig`).
    tone: tone.Tone,
    /// Why the last start played nothing, natively; empty when it played (section 3).
    failure: []const u8,

    pub const config: patchwork.app.Config = .{
        .title = "audio",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = quads.Composite, .cap = 2 },
        },
        .batch_cap = 32,
        .area_cap = 1,
        .point_cap = point_cap,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{
            .name = "play",
            .setup = &.{ .{ .wait = 5 }, .{ .key = .{ .key = .other, .text = " " } }, .{ .wait = 5 } },
            .cycle = &.{},
            .frames = 300,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        app.bars = @splat(.zero);
        app.scope.init();
        app.xy = textures.create_target(.feedback);
        app.blocks = 0;
        app.decaying = 0;
        app.tone.init("patchwork-audio");
        app.failure = "";
    }

    /// Lets Space open the audio device: only the native window host calls this (`tone.zig`).
    pub fn args(app: *App, arguments: []const [:0]const u8) void {
        _ = arguments;
        app.tone.allow_device();
    }

    pub fn wake(app: *App) *patchwork.Wake {
        return app.tone.wake();
    }

    pub fn pending(app: *const App) u32 {
        return app.tone.pending();
    }

    /// Takes every block waiting (section 2), at most the monitor's capacity.
    pub fn drain(app: *App, cx: *Context) void {
        var count: u32 = 0;
        while (count < tone.monitor_blocks) : (count += 1) {
            const block = app.tone.pop() orelse break;
            app.block_in(cx, &block);
        }
        assert(count <= tone.monitor_blocks);
    }

    /// Steps the tone by `frames` where no device plays (section 3).
    pub fn produce(app: *App, frames: u32) void {
        app.tone.produce(frames);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .frame => {
                if (app.decaying > 0) {
                    cx.redraw();
                    cx.keep_animating();
                }
            },
            .key_down => |press| {
                if (press.key == .other and std.mem.eql(u8, press.typed(), " ")) {
                    app.toggle(cx);
                }
            },
            else => {},
        }
    }

    /// Starts or stops the tone (section 3).
    fn toggle(app: *App, cx: *Context) void {
        const on = !app.tone.playing;
        switch (app.tone.set_playing(on)) {
            .playing => app.failure = "",
            .failed => |reason| app.failure = reason,
        }
        if (!on) {
            app.bars = @splat(.zero);
            app.decaying = decay_frames;
        } else {
            app.decaying = 0;
        }
        cx.redraw();
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    /// One block of the tone (section 2).
    fn block_in(app: *App, cx: *Context, block: *const tone.Block) void {
        assert(app.tone.playing);
        const levels = level.levels(tone.channels, block);
        for (&app.bars, 0..) |*bar, channel| {
            bar.rms.step(level.meter_of(levels.rms[channel]));
            bar.peak.step(level.meter_of(levels.peak[channel]));
        }
        app.scope.push(block);
        app.blocks += 1;
        cx.redraw();
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = clip_of(cx.window);
        const band: Rect = .{ .x = 16, .y = 0, .width = 1056, .height = 40 };
        var failed: [title_cap]u8 = undefined;
        const title = if (app.failure.len > 0)
            std.fmt.bufPrint(&failed, "audio: no sound, the device did not open ({s})", .{
                app.failure,
            }) catch unreachable
        else if (app.tone.playing)
            "audio: test tone running (space stops)"
        else
            "audio: test tone stopped (space plays)";
        // Faces first: batches draw in order of first appearance, so the Box batch must come
        // before the Glyph batch for labels on a face to show.
        append_box(cx, meters_rect, face_color, meters_rect, 8);
        append_box(cx, scope_rect, face_color, scope_rect, 8);
        append_box(cx, xy_rect, face_color, xy_rect, 8);
        text.place(draw_cx, title_style, title, band, window, left);
        app.draw_meters(cx);
        app.draw_scope(cx);
        app.draw_xy(cx);
        app.draw_stats(cx);
        if (!app.tone.playing and app.decaying > 0) app.decaying -= 1;
        assert(cx.draw.overflow_count == 0);
    }

    fn draw_meters(app: *const App, cx: *Context) void {
        const draw_cx = cx.drawing();
        for (app.bars, bar_x, [_][]const u8{ "L", "R" }) |bar, x, name| {
            const track: Rect = .{ .x = x, .y = track_top, .width = bar_width, .height = track_height };
            append_box(cx, track, cx.theme().colors.track, meters_rect, 3);
            if (bar.rms.value > 0) {
                const height = bar.rms.value * track_height;
                const fill: Rect = .{ .x = x, .y = track_top + track_height - height, .width = bar_width, .height = height };
                append_box(cx, fill, rms_color, meters_rect, 3);
            }
            if (bar.peak.value > 0) append_box(cx, level_line(x, bar.peak.value), peak_color, meters_rect, 0);
            if (bar.peak.hold > 0) append_box(cx, level_line(x, bar.peak.hold), hold_color, meters_rect, 0);
            const label: Rect = .{ .x = x, .y = track_top + track_height + 8, .width = bar_width, .height = 24 };
            text.place(draw_cx, label_style, name, label, clip_of(meters_rect), centered);
        }
        for (marks_db) |db| {
            const y = mark_y(db);
            append_box(cx, .{ .x = bar_x[0], .y = y, .width = bar_x[1] + bar_width - bar_x[0], .height = 1 }, mark_color, meters_rect, 0);
            var buffer: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buffer, "{d}", .{db}) catch unreachable;
            const at: Rect = .{ .x = bar_x[1] + bar_width + 2, .y = y - 8, .width = 24, .height = 16 };
            text.place(draw_cx, mark_style, label, at, clip_of(meters_rect), left);
        }
    }

    fn draw_scope(app: *const App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const center_y = scope_rect.y + scope_rect.height / 2;
        append_box(cx, .{ .x = scope_rect.x, .y = center_y, .width = scope_rect.width, .height = 1 }, mark_color, scope_rect, 0);
        var window: Scope.Window = undefined;
        _ = app.scope.window_of(&window);
        for (window, trace_colors) |samples, color| {
            var points: [scope_frames]quads.path.Point = undefined;
            for (&points, samples, 0..) |*point, value, index| {
                point.* = .{ scope_rect.x + 0.5 + @as(f32, @floatFromInt(index)), center_y - value * signal_scale };
            }
            _ = quads.path.polyline(draw_cx, &points, .{ .color = color, .width = 1.5, .hover = 0 }, clip_of(scope_rect));
        }
    }

    /// The XY trace over its own last frame (section 1); the newest `scope_frames` frames.
    fn draw_xy(app: *const App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const inner = inset(xy_rect, 8);
        const target = inner.array();
        const clip = clip_of(inner).array();
        draw_cx.offscreen(xy_layer, app.xy, target);
        const previous = draw_cx.layer(xy_layer);
        fx.composite(draw_cx, app.xy, target, target, clip, persistence, 1, fade_bias);
        if (app.tone.playing and app.blocks > 0) {
            var window: Scope.Window = undefined;
            app.scope.newest(&window);
            const center_x = inner.x + inner.width / 2;
            const center_y = inner.y + inner.height / 2;
            var points: [scope_frames]quads.path.Point = undefined;
            for (&points, window[0], window[1]) |*point, l, r| {
                point.* = .{ center_x + l * signal_scale, center_y - r * signal_scale };
            }
            _ = quads.path.polyline(draw_cx, &points, .{ .color = xy_color, .width = 1.5, .hover = 0 }, clip_of(inner));
        }
        _ = draw_cx.layer(previous);
        fx.composite(draw_cx, app.xy, target, target, clip, 1, 1, 0);
    }

    fn draw_stats(app: *const App, cx: *Context) void {
        var buffer: [stats_cap]u8 = undefined;
        const state = if (app.tone.playing) "running" else "stopped";
        const line = std.fmt.bufPrint(&buffer, "blocks {d}    dropped {d}    {s}", .{
            app.blocks, app.tone.dropped(), state,
        }) catch unreachable;
        text.place(cx.drawing(), label_style, line, stats_rect, clip_of(cx.window), left);
    }
};

pub const Context = patchwork.app.Context(App);

/// The y of meter value `value` (0 at the bottom of the track, 1 at its top).
pub fn value_y(value: f32) f32 {
    assert(value >= 0);
    assert(value <= 1);
    return track_top + track_height - value * track_height;
}

/// The y of the `db` mark.
pub fn mark_y(db: f32) f32 {
    return value_y((db + level.meter_range_db) / level.meter_range_db);
}

/// A 2-pixel line across a bar at meter value `value`, inside the track.
fn level_line(x: f32, value: f32) Rect {
    const y = @min(value_y(value), track_top + track_height - 2);
    return .{ .x = x, .y = y, .width = bar_width, .height = 2 };
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

fn send_space(app: *App) void {
    ui.dispatch(App, app, &fixture.context, .{ .key_down = input.key_press(.other, .none, false, " ") });
}

/// Steps the tone by `count` blocks where no device plays, draining each as a host does.
fn feed(app: *App, count: u32) void {
    for (0..count) |_| {
        App.produce(app, testtone.block_frames);
        App.drain(app, &fixture.context);
    }
}

// Locks the stopped screen (section 1): the three faces, two empty tracks, the four marks at
// their dB heights (-6 dB at 80 + 320 * 6 / 60 = 112), the center line, and the XY target bound
// to layer 1 at the inner rect, with no trace drawn.
test "the stopped screen draws the panels and no trace" {
    const app = new_app();
    try std.testing.expect(!app.tone.playing);
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(f32, 112), mark_y(-6));
    try std.testing.expectEqual(@as(f32, 336), mark_y(-48));
    try std.testing.expectEqual(@as(usize, 3 + 2 + marks_db.len + 1), cx.draw.items(quads.Box).len);
    const bindings = cx.draw.binding_list();
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqual([4]f32{ 728, 64, 336, 368 }, bindings[0].rect);
    // The two scope traces of the silent history.
    try std.testing.expect(cx.draw.items(quads.Path).len >= 2);
}

// Locks the data flow (section 2): Space starts the source; blocks move the bars and count;
// after one second of tone (375 blocks) both peaks sit between the tone's floor (-26 dB) and its
// top (-6 dB) on the meter scale, every bar part is drawn, and the XY trace is drawn only while
// running.
test "blocks move the meters and draw the trace" {
    const app = new_app();
    send_space(app);
    try std.testing.expect(app.tone.playing);
    feed(app, 375);
    try std.testing.expectEqual(@as(u64, 375), app.blocks);
    for (app.bars) |bar| {
        try std.testing.expect(bar.peak.value > level.meter_of(0.05));
        try std.testing.expect(bar.peak.value <= level.meter_of(0.5) + 1e-6);
        try std.testing.expect(bar.rms.value < bar.peak.value);
    }
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(usize, 3 + 2 * 4 + marks_db.len + 1), cx.draw.items(quads.Box).len);
    const running_paths = cx.draw.items(quads.Path).len;
    // Stopped, the scope keeps its window and the XY trace is gone.
    send_space(app);
    const stopped = frame_at(app);
    try std.testing.expect(stopped.draw.items(quads.Path).len < running_paths);
    try std.testing.expect(stopped.draw.items(quads.Path).len >= 2);
}

// Locks the stop (section 3): Space stops the source and zeroes the bars; the trail decays for
// `decay_frames` frames, then nothing is owed.
test "a stop zeroes the meters, decays, and sleeps" {
    const app = new_app();
    send_space(app);
    feed(app, 40);
    send_space(app);
    try std.testing.expect(!app.tone.playing);
    try std.testing.expectEqual(@as(f32, 0), app.bars[0].peak.value);
    for (0..decay_frames) |_| {
        try std.testing.expect(ui.animate(App, app, &fixture.context, 16));
        _ = frame_at(app);
    }
    try std.testing.expect(!ui.animate(App, app, &fixture.context, 16));
}

// Locks the scenarios without a GPU (`patchwork.bench`, section 2a): play starts the source.
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    const play = bench.find(App.scenarios, "play").?;
    _ = try bench.replay_headless(App, new_app(), cx, play, .{ 1280, 720 }, 20);
    try std.testing.expect(fixture.app.tone.playing);
    const still = bench.find(App.scenarios, "still").?;
    _ = try bench.replay_headless(App, new_app(), cx, still, .{ 1280, 720 }, 10);
}

comptime {
    patchwork.app.check(App);
    tone.exports();
}

test {
    _ = tone;
}

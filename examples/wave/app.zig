//! Wave example: an overview, a zoomable sample view, a 3-band scrolling DJ waveform, and a
//! spectrogram of a synthetic track.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The library's audio views (step 24), each at a fixed position from the top-left:
//! ```text
//! overview     16, 56, 1024 by 72    draw.Waveform of the whole track, 1,024 columns from
//!                                    the pyramid; a playhead and the zoom range on top
//! sample view  16, 144, 1024 by 160  draw.Waveform with RMS over the zoom range
//! DJ waveform  16, 320, 1024 by 96   draw.Ring(.rgba8): one band texel per tick
//! spectrogram  16, 432, 1024 by 192  draw.Ring(.r16float): one 128-bin column per tick
//! ```
//! `track.zig` holds the signal and the analysis.
//!
//! ## 2. Transport and Rings
//! Space toggles play; the timer (`tick_ms`) runs only while playing, so a paused screen
//! sleeps. Each tick advances the playhead one tick block (wrapping at the end) and pushes one
//! column into each ring's mirror (`draw.TextureRing.push`): 4 bytes into the DJ ring, 128
//! `f16`s into the spectrogram. `draw` flushes both rings, so the columns pushed since the
//! last frame upload as one write per ring (two when they wrap), however many ticks ran. `init` prefills both rings as if the track had played to `start_tick`
//! (zeros before the track), then queues each mirror once. A ring shows its oldest column, the
//! ring's `head`, at the left.
//!
//! ## 3. Zoom
//! The sample view shows `view_count` samples from `view_first`, between `count_min` (1/8 of a
//! sample per column) and the whole track. A wheel step zooms by 0.8 or 1.25 around the sample
//! under the pointer, which stays under the pointer; a horizontal wheel pans by its pixels.
//! A press on the overview seeks there and centers the view on it.
//!
//! ## 4. Colors
//! The DJ ring draws three bands mirrored around its middle, low widest and high narrowest,
//! each covering `|2 t.y - 1| < level * reach` with its edge ramped over `fwidth`. The
//! spectrogram maps its value through a dark-blue, magenta, yellow palette.
//!
//! ## 5. TigerStyle Invariants
//! Capacities are exact (comptime block); the per-frame work is O(columns), and a tick is
//! O(window * bins).

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;
const track = @import("track.zig");

const Rect = quads.Rect;
const wave = quads.wave;

pub const view_x: f32 = 16;
pub const view_width: f32 = 1024;
pub const columns: u32 = 1024;
pub const overview_rect: Rect = .{ .x = view_x, .y = 56, .width = view_width, .height = 72 };
pub const sample_rect: Rect = .{ .x = view_x, .y = 144, .width = view_width, .height = 160 };
pub const dj_rect: Rect = .{ .x = view_x, .y = 320, .width = view_width, .height = 96 };
pub const spectrum_rect: Rect = .{ .x = view_x, .y = 432, .width = view_width, .height = 192 };

pub const tick_ms: u32 = 20;
pub const start_tick: u32 = 600;
pub const dj_columns: u32 = 1024;
pub const spectrum_columns: u32 = 512;
pub const count_min: u32 = columns / 8;
pub const count_start: u32 = columns * 16;

pub const DjRing = quads.TextureRing(.rgba8, dj_columns, 1);
pub const SpectrumRing = quads.TextureRing(.r16float, spectrum_columns, track.bins);

pub const DjColor = struct {
    pub const wgsl: []const u8 =
        \\fn dj_band(level: f32, reach: f32, d: f32, ramp: f32) -> f32 {
        \\    return clamp((level * reach - d) / ramp + 0.5, 0.0, 1.0);
        \\}
        \\
        \\fn ring_color(value: vec4<f32>, px: Pixel) -> vec4<f32> {
        \\    let d = abs(2.0 * px.local.y / px.size.y - 1.0);
        \\    let ramp = max(fwidth(d), 1.0e-5);
        \\    let low = dj_band(value.r, 1.0, d, ramp);
        \\    let mid = dj_band(value.g, 0.7, d, ramp);
        \\    let high = dj_band(value.b, 0.45, d, ramp);
        \\    var rgb = vec3<f32>(0.20, 0.45, 0.95);
        \\    rgb = mix(rgb, vec3<f32>(0.95, 0.60, 0.20), mid);
        \\    rgb = mix(rgb, vec3<f32>(0.95, 0.95, 0.95), high);
        \\    return vec4<f32>(rgb, max(low, max(mid, high)) * px.tint.a);
        \\}
    ;
};

pub const SpectrumColor = struct {
    pub const wgsl: []const u8 =
        \\fn ring_color(value: vec4<f32>, px: Pixel) -> vec4<f32> {
        \\    let v = clamp(value.r, 0.0, 1.0);
        \\    let low = vec3<f32>(0.05, 0.06, 0.20);
        \\    let mid = vec3<f32>(0.75, 0.15, 0.55);
        \\    let high = vec3<f32>(1.00, 0.90, 0.30);
        \\    let rgb = select(mix(mid, high, v * 2.0 - 1.0), mix(low, mid, v * 2.0), v < 0.5);
        \\    return vec4<f32>(rgb, px.tint.a);
        \\}
    ;
};

pub const DjView = quads.Ring(.rgba8, DjColor);
pub const SpectrumView = quads.Ring(.r16float, SpectrumColor);

const overview_id = ui.id("overview", 0);
const sample_id = ui.id("samples", 0);

const overview_style: wave.Style = .{ .color = .{ 0.55, 0.85, 0.45, 1 }, .rms_color = null };
const sample_style: wave.Style = .{
    .color = .{ 0.35, 0.60, 0.90, 1 },
    .rms_color = .{ 0.75, 0.88, 1.00, 1 },
};
const playhead_color: [4]f32 = .{ 1, 1, 1, 0.9 };
const range_color: [4]f32 = .{ 1, 1, 1, 0.12 };
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.chrome.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

/// The panel faces, the overview's range and playhead, and the sample view's playhead.
const box_cap: u32 = 4 + 3;
const glyph_cap: u32 = 64;
/// The overview's columns plus the sample view's, two points each for RMS.
const point_cap: u32 = columns + 2 * columns;

comptime {
    assert(columns == @as(u32, @intFromFloat(view_width)));
    assert(@mod(view_width, @as(f32, @floatFromInt(spectrum_columns))) == 0);
    assert(count_start <= track.sample_count);
    assert(start_tick >= spectrum_columns);
}

/// The wave screen. See the module guide.
pub const App = struct {
    samples: [track.sample_count]f32,
    pyramid: wave.Pyramid(track.sample_count),
    bands: [track.tick_count][4]u8,
    analyzer: track.Analyzer,
    dj: DjRing,
    spectrum: SpectrumRing,
    /// The tick the playhead is at; its block is the last one pushed.
    tick: u32,
    playing: bool,
    view_first: u32,
    view_count: u32,

    pub const config: patchwork.app.Config = .{
        .title = "wave",
        .timer_period_ms = tick_ms,
        .timer_armed = false,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Waveform, .cap = 2 },
            .{ .type = DjView, .cap = 1 },
            .{ .type = SpectrumView, .cap = 1 },
        },
        .batch_cap = 16,
        .area_cap = 2,
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
        .{
            .name = "zoom",
            .setup = &.{.{ .wait = 5 }},
            .cycle = &.{
                .{ .wheel = .{ .target = patchwork.bench.area("samples", 0), .dx = 0, .dy = -21 } },
                .{ .wheel = .{ .target = patchwork.bench.area("samples", 0), .dx = 0, .dy = 21 } },
            },
            .frames = 300,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        track.fill(&app.samples);
        app.pyramid.build(&app.samples);
        track.fill_bands(&app.samples, &app.bands);
        app.analyzer.init();
        app.dj.init(textures);
        app.spectrum.init(textures);
        app.tick = start_tick;
        app.playing = false;
        app.view_count = count_start;
        app.view_first = clamp_first(start_tick * track.tick_samples - count_start / 2, count_start);
        // Prefill: the rings as if the track had played to `start_tick` (section 2).
        for (0..dj_columns) |index| {
            const back: i64 = @as(i64, start_tick) - dj_columns + @as(i64, @intCast(index));
            const texel: [4]u8 = if (back >= 0) app.bands[@intCast(back)] else .{ 0, 0, 0, 255 };
            app.dj.set(@intCast(index), &texel);
        }
        for (0..spectrum_columns) |index| {
            const tick: u32 = start_tick - spectrum_columns + @as(u32, @intCast(index));
            var column: [track.bins]f16 = undefined;
            track.spectrum(&app.samples, &app.analyzer, (tick + 1) * track.tick_samples, &column);
            app.spectrum.set(@intCast(index), std.mem.sliceAsBytes(&column));
        }
        app.dj.fill(textures);
        app.spectrum.fill(textures);
        assert(app.dj.head == 0);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .key_down => |press| {
                if (press.key == .other and std.mem.eql(u8, press.typed(), " ")) {
                    app.playing = !app.playing;
                    cx.set_timer(app.playing);
                    cx.redraw();
                }
                return;
            },
            else => {},
        }
        switch (cx.hit(sample_id, event_value)) {
            .wheel => |w| {
                app.wheel(w);
                cx.redraw();
            },
            else => {},
        }
        switch (cx.hit(overview_id, event_value)) {
            .down => |press| {
                app.seek(press.x);
                cx.redraw();
            },
            else => {},
        }
    }

    /// One tick (section 2): advance the playhead and push one column into each ring.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = now_ms;
        if (!app.playing) return;
        app.tick = (app.tick + 1) % track.tick_count;
        app.dj.push(&app.bands[app.tick]);
        var column: [track.bins]f16 = undefined;
        track.spectrum(&app.samples, &app.analyzer, (app.tick + 1) * track.tick_samples, &column);
        app.spectrum.push(std.mem.sliceAsBytes(&column));
        cx.redraw();
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = cx.window;
        const band: Rect = .{ .x = view_x, .y = 0, .width = view_width, .height = 40 };
        const title = if (app.playing) "wave: playing (space pauses, wheel zooms)" else "wave: paused (space plays, wheel zooms)";
        text.place(draw_cx, title_style, title, band, clip_of(window), left);
        for ([_]Rect{ overview_rect, sample_rect, dj_rect, spectrum_rect }) |rect| {
            append_box(cx, rect, theme.chrome.panel, window);
        }
        cx.area(overview_id, overview_rect, 0, ui.cx.plain);
        cx.area(sample_id, sample_rect, 0, ui.cx.wheel_flag);
        var out: [columns]wave.Column = undefined;
        app.pyramid.columns(&app.samples, 0, track.sample_count, &out);
        _ = wave.append(draw_cx, overview_rect.array(), clip_of(overview_rect).array(), &out, overview_style);
        app.pyramid.columns(&app.samples, app.view_first, app.view_count, &out);
        _ = wave.append(draw_cx, sample_rect.array(), clip_of(sample_rect).array(), &out, sample_style);
        _ = app.dj.flush(&draw_cx.textures);
        _ = app.spectrum.flush(&draw_cx.textures);
        append_ring(cx, DjView, app.dj.id, dj_rect, app.dj.head);
        append_ring(cx, SpectrumView, app.spectrum.id, spectrum_rect, app.spectrum.head);
        const previous = draw_cx.layer(.overlay);
        const total: f32 = @floatFromInt(track.sample_count);
        const range: Rect = .{
            .x = overview_rect.x + overview_rect.width * @as(f32, @floatFromInt(app.view_first)) / total,
            .y = overview_rect.y,
            .width = @max(1, overview_rect.width * @as(f32, @floatFromInt(app.view_count)) / total),
            .height = overview_rect.height,
        };
        append_box(cx, range, range_color, overview_rect);
        const head = app.playhead();
        append_box(cx, line_at(overview_rect, @as(f32, @floatFromInt(head)) / total), playhead_color, overview_rect);
        if (head >= app.view_first and head < app.view_first + app.view_count) {
            const fraction = @as(f32, @floatFromInt(head - app.view_first)) /
                @as(f32, @floatFromInt(app.view_count));
            append_box(cx, line_at(sample_rect, fraction), playhead_color, sample_rect);
        }
        _ = draw_cx.layer(previous);
    }

    /// The sample at the playhead: the end of the last pushed block.
    pub fn playhead(app: *const App) u32 {
        return (app.tick + 1) * track.tick_samples - 1;
    }

    /// Zooms around the sample under the pointer, or pans (section 3).
    fn wheel(app: *App, w: input.Wheel) void {
        const at = std.math.clamp((w.x - sample_rect.x) / sample_rect.width, 0, 1);
        if (w.dy != 0) {
            const anchor = @as(f32, @floatFromInt(app.view_first)) + at * @as(f32, @floatFromInt(app.view_count));
            const factor: f32 = if (w.dy < 0) 0.8 else 1.25;
            const wanted = @round(@as(f32, @floatFromInt(app.view_count)) * factor);
            const lowest: f32 = @floatFromInt(count_min);
            const highest: f32 = @floatFromInt(track.sample_count);
            const count: u32 = @intFromFloat(std.math.clamp(wanted, lowest, highest));
            const first = @max(0, @round(anchor - at * @as(f32, @floatFromInt(count))));
            app.view_count = count;
            app.view_first = clamp_first(@intFromFloat(first), count);
        }
        if (w.dx != 0) {
            const per_px = @as(f32, @floatFromInt(app.view_count)) / sample_rect.width;
            const moved = @as(f32, @floatFromInt(app.view_first)) + w.dx * per_px;
            app.view_first = clamp_first(@intFromFloat(@max(0, @round(moved))), app.view_count);
        }
        assert(app.view_first + app.view_count <= track.sample_count);
    }

    /// Seeks to the overview position `x` and centers the view there.
    fn seek(app: *App, x: f32) void {
        const at = std.math.clamp((x - overview_rect.x) / overview_rect.width, 0, 1);
        const tick: u32 = @intFromFloat(@min(at * track.tick_count, track.tick_count - 1));
        app.tick = tick;
        const center = app.playhead();
        app.view_first = clamp_first(center -| app.view_count / 2, app.view_count);
    }
};

pub const Context = patchwork.app.Context(App);

/// `first`, moved so `[first, first + count)` stays inside the track.
fn clamp_first(first: u32, count: u32) u32 {
    assert(count <= track.sample_count);
    return @min(first, track.sample_count - count);
}

/// A two-pixel playhead at `fraction` of `rect`'s width.
fn line_at(rect: Rect, fraction: f32) Rect {
    return .{ .x = rect.x + rect.width * fraction - 1, .y = rect.y, .width = 2, .height = rect.height };
}

fn append_box(cx: *Context, rect: Rect, color: [4]f32, clip: Rect) void {
    kit.append(cx, quads.Box, null, .of(rect, clip_of(clip), .{ .fill = color }));
}

fn append_ring(cx: *Context, comptime T: type, id: quads.TextureId, rect: Rect, head: u32) void {
    cx.append(T, id, .{
        .rect = rect.array(),
        .clip = clip_of(rect).array(),
        .tint = .{ 1, 1, 1, 1 },
        .head = @floatFromInt(head),
        .pad0 = 0,
        .pad1 = 0,
        .pad2 = 0,
    }) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
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
    patchwork.app.start_timer(App, &fixture.context);
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

fn frame_at(app: *App, width: u32, height: u32) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, width, height, 120));
    cx.draw.finalize();
    assert(cx.draw.overflow_count == 0);
    return cx;
}

fn send(app: *App, event_value: input.Event) void {
    ui.dispatch(App, app, &fixture.context, event_value);
}

// Locks the layout and the instances (section 1): two waveforms, the overview with 1,024
// points and the sample view with 2,048 (RMS), the rings at their heads, and the prefill:
// both mirrors queued once and the DJ ring's last column holding the band of tick 599.
test "the views draw at fixed rects with their columns" {
    const app = new_app();
    const textures = &fixture.context.draw.textures;
    try std.testing.expectEqual(@as(u32, 2), textures.write_count);
    try std.testing.expectEqualSlices(u8, &app.bands[start_tick - 1], app.dj.texels[(dj_columns - 1) * 4 ..][0..4]);
    const cx = frame_at(app, 1280, 720);
    const waves = cx.draw.items(quads.Waveform);
    try std.testing.expectEqual(@as(usize, 2), waves.len);
    try std.testing.expectEqual([4]f32{ 16, 56, 1024, 72 }, waves[0].rect);
    try std.testing.expectEqual(@as(f32, 1024), waves[0].point_count);
    try std.testing.expectEqual(@as(f32, 2048), waves[1].point_count);
    try std.testing.expectEqual(@as(usize, 3072), cx.draw.point_items().len);
    try std.testing.expectEqual(@as(f32, 0), cx.draw.items(DjView)[0].head);
    try std.testing.expectEqual([4]f32{ 16, 432, 1024, 192 }, cx.draw.items(SpectrumView)[0].rect);
}

// Locks a tick (section 2): Space starts the timer; one tick and a frame queue exactly one DJ
// texel (a 1 by 1 region, 4 bytes) and one 1 by 128 spectrogram column (256 bytes at a
// 1,024-byte row stride), at column 0 of each ring, and advance both heads; three ticks
// before a frame queue one write per ring three columns wide; Space again stops the timer,
// and a paused screen owes nothing.
test "a tick pushes one column into each ring" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    cx.draw.textures.write_count = 0;
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(cx.timer_on);
    App.timer(app, cx, 0);
    const textures = &cx.draw.textures;
    try std.testing.expectEqual(@as(u32, 0), textures.write_count);
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 2), textures.write_count);
    const dj = textures.writes[0];
    try std.testing.expectEqual(quads.TextureRegion{ .x = 0, .y = 0, .width = 1, .height = 1 }, dj.region);
    try std.testing.expectEqual(@as(usize, 4), dj.data.len);
    const spectrum = textures.writes[1];
    try std.testing.expectEqual(@as(u32, 128), spectrum.region.height);
    try std.testing.expectEqual(@as(u32, 1024), spectrum.bytes_per_row);
    try std.testing.expectEqual(spectrum.region.width * spectrum.region.height * 2, 256);
    try std.testing.expectEqual(@as(u32, 1), app.dj.head);
    try std.testing.expectEqual(@as(u32, start_tick + 1), app.tick);
    textures.write_count = 0;
    for (0..3) |_| App.timer(app, cx, 0);
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 2), textures.write_count);
    try std.testing.expectEqual(@as(u32, 3), textures.writes[0].region.width);
    try std.testing.expectEqual(@as(u32, 1), textures.writes[1].region.x);
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(!cx.timer_on);
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(!cx.dirty);
}

// Locks the zoom (section 3): a wheel step in over the view's middle keeps the middle sample
// there and scales the count by 0.8; zooming out past the track clamps to the whole track;
// a press on the overview's middle seeks to tick 400 and centers the view on its playhead.
test "the wheel zooms around the pointer and the overview seeks" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const middle = sample_rect.x + sample_rect.width / 2;
    const before = app.view_first + app.view_count / 2;
    send(app, .{ .wheel = .{ .x = middle, .y = sample_rect.y + 10, .dx = 0, .dy = -21 } });
    try std.testing.expectEqual(@as(u32, count_start * 4 / 5), app.view_count);
    try std.testing.expectEqual(before, app.view_first + app.view_count / 2);
    for (0..40) |_| send(app, .{ .wheel = .{ .x = middle, .y = sample_rect.y + 10, .dx = 0, .dy = 21 } });
    try std.testing.expectEqual(track.sample_count, app.view_count);
    try std.testing.expectEqual(@as(u32, 0), app.view_first);
    _ = frame_at(app, 1280, 720);
    const press: input.Button = .{ .x = overview_rect.x + overview_rect.width / 2, .y = overview_rect.y + 5, .time_ms = 0, .button = .left, .mods = .none };
    send(app, .{ .pointer_move = .{ .x = press.x, .y = press.y } });
    send(app, .{ .pointer_down = press });
    try std.testing.expectEqual(@as(u32, 400), app.tick);
}

// Locks the scenarios against this screen without a GPU (`patchwork.bench`, section 2a): play
// starts the timer, and zoom's wheel steps resolve the sample view.
test "the scenarios replay headless" {
    const bench = patchwork.bench;
    const cx = &fixture.context;
    const play = bench.find(App.scenarios, "play").?;
    _ = try bench.replay_headless(App, new_app(), cx, play, .{ 1280, 720 }, 20);
    try std.testing.expect(cx.timer_on);
    const app = new_app();
    const zoom = bench.find(App.scenarios, "zoom").?;
    const steps = try bench.replay_headless(App, app, cx, zoom, .{ 1280, 720 }, 21);
    try std.testing.expectEqual(@as(u32, 21), steps);
    // The steps alternate in and out, so the view is at its start or one step in.
    const one_in = count_start * 4 / 5;
    try std.testing.expect(app.view_count == count_start or app.view_count == one_in);
}

comptime {
    patchwork.app.check(App);
}

test {
    _ = track;
}

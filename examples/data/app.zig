//! Data example: float textures, per-texture sampling modes, and additive and multiply blends.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The GPU vocabulary that data views need (step 23), one panel each, with no input and no
//! timer, so the screen draws once and then sleeps:
//! ```text
//! Heat     r32float 56x28, nearest, clamp        a synthetic spectrogram, palette in WGSL;
//!                                               a multiply Shade darkens its lower third
//! Tile     rg16float 8x8, linear, repeat u, v   one period of two sines, shown 3x3 times
//! History  r16float 56x1, textureLoad           bars read oldest-first from head 40
//! Lights   additive                             red, green, and blue discs overlapping
//! ```
//! The draw types are in `views.zig`.
//!
//! ## 2. Layout (logical pixels)
//! Every panel is at a fixed position from the top-left, whatever the window size, so a
//! native frame dump and a browser screenshot compare region for region:
//! ```text
//! title    16, 0, by title_px, in the title band
//! panel i  x = margin + i * (panel_px + margin), y = title_px + margin, panel_px square
//! content  the panel inset by inset_px on every side
//! label    under the panel, label_px tall
//! ```
//!
//! ## 3. Fields
//! The texture data lives in the app, which outlives every stream (`draw/textures.zig`,
//! section 3), and is generated once in `init`:
//! ```text
//! heat(x, y)    rows from the bottom: f0 = 3 + 2 sin(0.14 x); for k in 1..4:
//!               v += exp(-((row - k f0) / 0.8)^2) / k; then min(v, 1)
//! tile(x, y)    (0.5 + 0.5 sin(2 pi x / 8), 0.5 + 0.5 sin(2 pi y / 8)) as f16
//! history(i)    0.5 + 0.4 sin(0.35 i) as f16; head 40 is the oldest sample
//! ```
//! The heat map and the history are 56 texels wide on 224-pixel content: 4 pixels per texel,
//! so no pixel center lands on a texel edge, where GPUs may round a nearest sample or a
//! `floor` either way (64 texels, 3.5 pixels each, differed between the RTX 3060 and the
//! UHD 770 on a few columns).
//!
//! The tile holds one whole period on each axis, so repeating it with linear filtering is
//! seamless; clamping would smear the edge texels instead.
//!
//! ## 4. TigerStyle Invariants
//! Capacities are exact (see the comptime block); tests assert nothing overflows.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;
const views = @import("views.zig");

const Rect = quads.Rect;

pub const title_px: f32 = 40;
pub const margin_px: f32 = 16;
pub const panel_px: f32 = 240;
pub const inset_px: f32 = 8;
pub const label_px: f32 = 24;
pub const panel_count: u32 = 4;

pub const heat_width: u32 = 56;
pub const heat_height: u32 = 28;
pub const tile_side: u32 = 8;
pub const history_count: u32 = 56;
pub const history_head: u32 = 40;

const heat_sampling: quads.TextureSampling = .{ .filter = .nearest };
const tile_sampling: quads.TextureSampling = .{ .address_u = .repeat, .address_v = .repeat };
/// The texture rectangle the tile shows: three periods, starting half a period in.
const tile_uv: [4]f32 = .{ 0.5, 0.5, 3.5, 3.5 };
const shade_color: [4]f32 = .{ 0.25, 0.30, 0.55, 1 };
const bars_color: [4]f32 = .{ 0.40, 0.80, 0.75, 1 };
const light_colors = [3][4]f32{
    .{ 1, 0.1, 0.1, 1 },
    .{ 0.1, 1, 0.1, 1 },
    .{ 0.1, 0.1, 1, 1 },
};
const light_side_px: f32 = 120;

const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.chrome.text };
const label_style: text.Style = .{ .face = .sans, .size = 13, .color = theme.chrome.text };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
const labels = [panel_count][]const u8{
    "r32float, nearest, multiply shade",
    "rg16float, linear, repeat",
    "r16float, textureLoad ring",
    "additive",
};

/// The panel faces.
const box_cap: u32 = panel_count;
/// The title and the four labels, at most 40 glyphs each.
const glyph_cap: u32 = 5 * 40;
const area_cap: u32 = 1;

comptime {
    assert(margin_px + panel_count * (panel_px + margin_px) <= 1280);
    // Whole pixels per texel (module guide, section 3).
    assert(@mod(panel_px - 2 * inset_px, @as(f32, @floatFromInt(heat_width))) == 0);
    assert(@mod(panel_px - 2 * inset_px, @as(f32, @floatFromInt(history_count))) == 0);
    assert(history_head < history_count);
    for (labels) |label| assert(label.len <= 40);
    // The discs sit a quarter side off center, so together they span 1.5 sides.
    assert(light_side_px * 1.5 <= panel_px - 2 * inset_px);
}

/// The data screen. See the module guide.
pub const App = struct {
    heat: [heat_width * heat_height]f32,
    tile: [tile_side * tile_side * 2]f16,
    history: [history_count]f16,
    heat_texture: quads.TextureId,
    tile_texture: quads.TextureId,
    history_texture: quads.TextureId,

    pub const config: patchwork.app.Config = .{
        .title = "data",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = views.Heat, .cap = 1 },
            .{ .type = views.Shade, .cap = 1 },
            .{ .type = views.Tile, .cap = 1 },
            .{ .type = views.Bars, .cap = 1 },
            .{ .type = views.Light, .cap = light_colors.len },
        },
        .batch_cap = 16,
        .area_cap = area_cap,
    };

    /// `still` presents unchanged frames, for frame dumps (every one is skipped by the cache).
    pub const scenarios: []const patchwork.bench.Scenario = &.{.{
        .name = "still",
        .setup = &.{.{ .wait = 5 }},
        .cycle = &.{.{ .wait = 1 }},
        .frames = 60,
    }};

    pub fn init(app: *App, textures: *quads.Textures) void {
        fill_heat(&app.heat);
        fill_tile(&app.tile);
        fill_history(&app.history);
        app.heat_texture = textures.create_sampled(.r32float, heat_width, heat_height, heat_sampling);
        textures.write(app.heat_texture, full(heat_width, heat_height), std.mem.sliceAsBytes(&app.heat));
        app.tile_texture = textures.create_sampled(.rg16float, tile_side, tile_side, tile_sampling);
        textures.write(app.tile_texture, full(tile_side, tile_side), std.mem.sliceAsBytes(&app.tile));
        app.history_texture = textures.create(.r16float, history_count, 1);
        textures.write(app.history_texture, full(history_count, 1), std.mem.sliceAsBytes(&app.history));
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = cx.window;
        const band: Rect = .{ .x = margin_px, .y = 0, .width = window.width - margin_px, .height = title_px };
        text.place(draw_cx, title_style, "data textures, samplers, and blending", band, clip_of(window), left);
        for (0..panel_count) |index| {
            const panel = panel_rect(@intCast(index));
            kit.append(cx, quads.Box, null, .of(panel, clip_of(window), .{
                .fill = theme.chrome.panel,
                .border_color = theme.chrome.track,
                .border_width = 1,
                .radius = 6,
            }));
            const label: Rect = .{
                .x = panel.x,
                .y = panel.y + panel.height,
                .width = panel.width,
                .height = label_px,
            };
            text.place(draw_cx, label_style, labels[index], label, clip_of(window), left);
        }
        app.draw_heat(cx);
        app.draw_tile(cx);
        app.draw_history(cx);
        draw_lights(cx);
    }

    fn draw_heat(app: *App, cx: *Context) void {
        const content = content_rect(0);
        kit.append(cx, views.Heat, app.heat_texture, .{
            .rect = content.array(),
            .clip = clip_of(content).array(),
        });
        const third = content.height / 3;
        const shade: Rect = .{
            .x = content.x,
            .y = content.y + content.height - third,
            .width = content.width,
            .height = third,
        };
        kit.append(cx, views.Shade, null, .{
            .rect = shade.array(),
            .clip = clip_of(content).array(),
            .color = shade_color,
        });
    }

    fn draw_tile(app: *App, cx: *Context) void {
        const content = content_rect(1);
        kit.append(cx, views.Tile, app.tile_texture, .{
            .rect = content.array(),
            .clip = clip_of(content).array(),
            .uv = tile_uv,
        });
    }

    fn draw_history(app: *App, cx: *Context) void {
        const content = content_rect(2);
        kit.append(cx, views.Bars, app.history_texture, .{
            .rect = content.array(),
            .clip = clip_of(content).array(),
            .color = bars_color,
            .head = @floatFromInt(history_head),
            .count = @floatFromInt(history_count),
            .pad0 = 0,
            .pad1 = 0,
        });
    }
};

pub const Context = patchwork.app.Context(App);

/// Three discs on a triangle around the content's center, overlapping in the middle.
fn draw_lights(cx: *Context) void {
    const content = content_rect(3);
    const center_x = content.x + content.width / 2;
    const center_y = content.y + content.height / 2;
    const offsets = [3][2]f32{ .{ 0, -0.25 }, .{ -0.25, 0.2 }, .{ 0.25, 0.2 } };
    for (light_colors, offsets) |color, offset| {
        const x = center_x + offset[0] * light_side_px - light_side_px / 2;
        const y = center_y + offset[1] * light_side_px - light_side_px / 2;
        kit.append(cx, views.Light, null, .{
            .rect = .{ x, y, light_side_px, light_side_px },
            .clip = clip_of(content).array(),
            .color = color,
        });
    }
}

/// Panel `index` (module guide, section 2).
pub fn panel_rect(index: u32) Rect {
    assert(index < panel_count);
    return .{
        .x = margin_px + @as(f32, @floatFromInt(index)) * (panel_px + margin_px),
        .y = title_px + margin_px,
        .width = panel_px,
        .height = panel_px,
    };
}

/// Panel `index` inset by `inset_px`.
pub fn content_rect(index: u32) Rect {
    const panel = panel_rect(index);
    return .{
        .x = panel.x + inset_px,
        .y = panel.y + inset_px,
        .width = panel.width - 2 * inset_px,
        .height = panel.height - 2 * inset_px,
    };
}

fn full(width: u32, height: u32) quads.TextureRegion {
    return .{ .x = 0, .y = 0, .width = width, .height = height };
}

fn clip_of(rect: Rect) quads.Clip {
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

/// The heat field at texel `(x, y)`, `y` from the top (module guide, section 3).
pub fn heat_at(x: u32, y: u32) f32 {
    assert(x < heat_width);
    assert(y < heat_height);
    const row: f32 = @floatFromInt(heat_height - 1 - y);
    const f0 = 3 + 2 * @sin(0.14 * @as(f32, @floatFromInt(x)));
    var value: f32 = 0;
    for (1..5) |k| {
        const harmonic: f32 = @floatFromInt(k);
        const distance = (row - harmonic * f0) / 0.8;
        value += @exp(-distance * distance) / harmonic;
    }
    const clamped = @min(value, 1);
    assert(clamped >= 0);
    return clamped;
}

fn fill_heat(out: *[heat_width * heat_height]f32) void {
    for (0..heat_height) |y| {
        for (0..heat_width) |x| out[y * heat_width + x] = heat_at(@intCast(x), @intCast(y));
    }
}

fn fill_tile(out: *[tile_side * tile_side * 2]f16) void {
    const side: f32 = @floatFromInt(tile_side);
    for (0..tile_side) |y| {
        for (0..tile_side) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const at = (y * tile_side + x) * 2;
            out[at] = @floatCast(0.5 + 0.5 * @sin(std.math.tau * fx / side));
            out[at + 1] = @floatCast(0.5 + 0.5 * @sin(std.math.tau * fy / side));
        }
    }
}

fn fill_history(out: *[history_count]f16) void {
    for (out, 0..) |*sample, index| {
        sample.* = @floatCast(0.5 + 0.4 * @sin(0.35 * @as(f32, @floatFromInt(index))));
    }
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

// Locks the layout (section 2): panels at fixed offsets from the top-left, the same in any
// window, one instance of each view clipped to its content, and three lights.
test "panels sit at fixed offsets in any window" {
    const app = new_app();
    try std.testing.expectEqual(Rect{ .x = 16, .y = 56, .width = 240, .height = 240 }, panel_rect(0));
    try std.testing.expectEqual(Rect{ .x = 784, .y = 56, .width = 240, .height = 240 }, panel_rect(3));
    for ([_][2]u32{ .{ 1280, 720 }, .{ 1900, 1100 } }) |size| {
        const cx = frame_at(app, size[0], size[1]);
        const heat = cx.draw.items(views.Heat);
        try std.testing.expectEqual([4]f32{ 24, 64, 224, 224 }, heat[0].rect);
        try std.testing.expectEqual(@as(usize, 4), cx.draw.items(quads.Box).len);
        try std.testing.expectEqual(@as(usize, 3), cx.draw.items(views.Light).len);
        const shade = cx.draw.items(views.Shade)[0];
        try std.testing.expectApproxEqAbs(@as(f32, 64 + 224 - 224.0 / 3.0), shade.rect[1], 1e-4);
    }
}

// Locks the batch order: within the one layer, batches follow first appearance, so the
// multiply shade comes after the heat map it darkens and the additive lights after the panels.
test "the shade draws after the heat it multiplies" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const R = Context.DrawContext.Registry;
    var order: [16]u8 = undefined;
    var count: usize = 0;
    for (cx.draw.batch_list()) |batch| {
        order[count] = batch.type_id;
        count += 1;
    }
    const heat = std.mem.findScalar(u8, order[0..count], comptime R.id(views.Heat)).?;
    const shade = std.mem.findScalar(u8, order[0..count], comptime R.id(views.Shade)).?;
    const box = std.mem.findScalar(u8, order[0..count], comptime R.id(quads.Box)).?;
    const light = std.mem.findScalar(u8, order[0..count], comptime R.id(views.Light)).?;
    try std.testing.expect(heat < shade);
    try std.testing.expect(box < light);
    try std.testing.expectEqual(quads.Blend.multiply, R.blends[comptime R.id(views.Shade)]);
    try std.testing.expectEqual(quads.Blend.additive, R.blends[comptime R.id(views.Light)]);
}

// Locks the fields (section 3) and the textures: the heat map peaks on its first harmonic
// (row f0 = 3 at x 0, so y = 28) and is near zero high above it; tile texel (2, 0) is
// (1, 0.5) and (6, 0) is (0, 0.5) as f16; history sample 0 is 0.5; and each texture keeps its
// format and sampling mode, with all three writes queued for the first stream.
test "fields hold their worked values and textures their modes" {
    const app = new_app();
    try std.testing.expectApproxEqAbs(@as(f32, 1), heat_at(0, heat_height - 1 - 3), 1e-3);
    try std.testing.expect(heat_at(0, 0) < 1e-3);
    try std.testing.expectEqual(@as(f16, 1), app.tile[2 * 2]);
    try std.testing.expectEqual(@as(f16, 0.5), app.tile[2 * 2 + 1]);
    try std.testing.expectApproxEqAbs(@as(f16, 0), app.tile[6 * 2], 1e-3);
    try std.testing.expectEqual(@as(f16, 0.5), app.history[0]);
    const textures = &fixture.context.draw.textures;
    try std.testing.expectEqual(quads.TextureFormat.r32float, textures.format_of(app.heat_texture));
    try std.testing.expectEqual(heat_sampling, textures.samplings[@backingInt(app.heat_texture)]);
    try std.testing.expectEqual(tile_sampling, textures.samplings[@backingInt(app.tile_texture)]);
    try std.testing.expectEqual(@as(u32, 3), textures.write_count);
    try std.testing.expectEqual(@as(usize, heat_width * heat_height * 4), textures.writes[0].data.len);
    try std.testing.expectEqual(@as(u32, 4), textures.writes[1].bytes_per_row / tile_side);
}

// Locks the idle screen: after the first frame nothing is owed, and the bench scenario replays
// headless.
test "the screen draws once and the still scenario replays" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!ui.draw_frame(App, app, cx, 1280, 720, 120));
    const still = patchwork.bench.find(App.scenarios, "still").?;
    const steps = try patchwork.bench.replay_headless(App, new_app(), cx, still, .{ 1280, 720 }, 10);
    try std.testing.expectEqual(@as(u32, 10), steps);
}

comptime {
    patchwork.app.check(App);
}

test {
    _ = views;
}

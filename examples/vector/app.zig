//! Vector example: filled shapes on the GPU, from a star to a glyph outline.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! `draw.fill` on one screen: a five-point star filled non-zero and even-odd side by side, whose
//! inner edges draw nothing under non-zero; a ring, a hole by winding; the region under a plotted
//! curve with its `draw.Path` stroke on top; one glyph from `ttf.load` filled beside the same
//! glyph from the atlas; a translucent comb tall enough to split into bands, whose seams show
//! as a stripe if a row ever blends twice; a closed stroke from `path.polygon` round a hexagon;
//! and a shape morphing from a circle to a rounded square.
//!
//! Page 4 is display text as outlines (`text.place_outlines`, step 50): letters that rock and
//! pulse each on its own transform, a paragraph written on glyph by glyph, and one word in outlines
//! beside the atlas at 16, 64, and 512 px.
//!
//! Page 5 is folds (`draw.Path`, step 62): Tapestry's comb, three spikes as one polyline, up each
//! and back down, so the middle spike's tip is a chunk seam where the stroke turns straight back
//! (or lands 0.05 or 0.4 px off). Below each comb its middle spike is drawn again on its own, as
//! one chunk, 52 px lower; the two must match pixel for pixel at any scale whose 52 px are whole
//! device pixels. Before step 62 single pixels inside the folded spike and beside its cap did not.
//!
//! Page 6 is dashes (`draw.path.Dash`, step 65): a line at 10 on, 5 off, dots, an L whose dash
//! ends at its corner, a hairpin, a sagging cable of several chunks, a right-angle route with
//! rounded corners (the Patch look's cable), a dashed hexagon fitted to its ring, and a long cable
//! whose dashes flow toward its end at `flow_speed` while Space runs the clock.
//!
//! ## 2. Pages
//! Digit keys pick a page, so the two cost scenarios draw one thing over the whole window:
//! ```text
//! 1  shapes     everything above
//! 2  glyph      one '&', em = window height / 1.08: 1,000 logical px in 1920 x 1080
//! 3  curtain    a single band at the 48-segment cap over the whole window: the worst fragment
//! 4  display    three views, which a further press of 4 steps through: title, write, sizes
//! 5  folds      six rows (stroke width and miss) by six sub-pixel offsets of combs
//! 6  dashes     dashed strokes, one of them flowing
//! ```
//!
//! ## 3. The Morph and the Clock
//! Space runs the clock. The morph is four lines and four cubics with a corner radius between half
//! its side (a circle) and a quarter of that, on the `frame` event's delta, so it rebuilds and
//! uploads its points on every frame while it runs. The title's letters take their angles and
//! scales from the same clock. The write-on has its own, restarted by Space once it has finished,
//! and takes one glyph every 3 frames at 60 Hz. The flowing cable lowers its dash offset by
//! `flow_speed` per second, wrapped to its period, so its records change and its points do not.
//! The app sleeps whenever nothing on the shown page moves: stopped, on a page with no motion, or
//! with the paragraph written.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: a `Builder` and an outline are static, and every shape is bounded by
//!   `fill.segment_cap`.
//! - The tests assert no shape is refused, on any page.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const input = patchwork.input;
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const ttf = text.ttf;
const ui = patchwork.ui;
const fill = quads.fill;
const Transform = quads.Transform;
const Point = quads.Point;
const Rect = quads.Rect;
const Clip = quads.Clip;

const star_radius: f32 = 92;
const curve_samples: u32 = 128;
const glyph_em: f32 = 120;
/// Seconds for the morph to go from the circle to the square and back.
const morph_period_s: f32 = 2;
const morph_side: f32 = 150;
/// Teeth of the tall comb: enough for at least three bands.
const comb_teeth: u32 = 60;
const comb_pitch: f32 = 5.5;
/// Edges of the curtain, all of them the window's height: the band cap.
const curtain_edges: u32 = fill.segments_max;

const orange: [4]f32 = .{ 0.95, 0.60, 0.25, 1 };
const blue: [4]f32 = .{ 0.35, 0.60, 0.95, 1 };
const green: [4]f32 = .{ 0.45, 0.80, 0.55, 1 };
const pink: [4]f32 = .{ 0.92, 0.45, 0.68, 1 };
const violet: [4]f32 = .{ 0.65, 0.55, 0.95, 1 };

const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const label_style: text.Style = .{ .face = .sans, .size = 12, .color = theme.dark.colors.text };
const glyph_style: text.Style = .{ .face = .sans, .size = glyph_em, .color = pink };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

const Page = enum { shapes, glyph, curtain, display, folds, dashes };

/// The views of the display page, in the order key 4 steps through them.
const View = enum { title, write, sizes };

/// Seconds for the write-on to show one more glyph: 3 frames at 60 Hz.
const write_glyph_s: f32 = 0.05;
/// Glyphs on screen at once while a glyph grows in.
const write_overlap: f32 = 2;
/// The write-on's clock when its text is complete.
const write_done_s: f32 = 1.0e6;

/// The flowing cable's pattern and its speed toward the cable's end, in logical pixels.
const flow_dash: quads.path.Dash = .{ .on = 10, .off = 5 };
const flow_speed: f32 = 40;

const title_word = "Patchwork";
const title_em: f32 = 200;
const write_em: f32 = 34;
const paragraph = "Glyphs are geometry here. Each letter is one filled shape that a program can " ++
    "turn, scale, and fade on its own, so text can be written on, grown past any atlas, " ++
    "or zoomed with no raster to rebuild. Pixel-snapped bitmaps stay the better choice for " ++
    "interface text.";
const sizes_word = "co";
const sizes_rows = [_]struct { size: f32, y: f32 }{
    .{ .size = 16, .y = 44 },
    .{ .size = 64, .y = 80 },
    .{ .size = 512, .y = 96 },
};

/// Static, so a frame's shapes are not 16 KiB of stack each, and one outline at a time.
var shape: fill.Builder = undefined;
var outline: ttf.Outline = undefined;

/// The vector screen. See the module guide.
pub const App = struct {
    page: Page,
    view: View,
    /// The clock of the morph and the title, in seconds, the write-on's, and whether they run.
    clock_s: f32,
    write_s: f32,
    running: bool,
    /// The flowing cable's dash offset, in `[0, period)` (section 3).
    flow_offset: f32,

    pub const config: patchwork.app.Config = .{
        .title = "vector",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 16 },
            .{ .type = quads.Fill, .cap = 512 },
            .{ .type = quads.Path, .cap = 128 },
            .{ .type = quads.Glyph, .cap = 256 },
        },
        .batch_order = .registered,
        .batch_cap = 16,
        .area_cap = 2,
        .point_cap = 32768,
    };

    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 3 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 10 },
        .{
            .name = "morph",
            .setup = &.{.{ .key = .{ .key = .other, .text = " " } }},
            .cycle = &.{},
            .frames = 90,
        },
        .{
            .name = "glyph",
            .setup = &.{ .{ .key = .{ .key = .other, .text = "2" } }, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 300,
        },
        .{
            .name = "curtain",
            .setup = &.{ .{ .key = .{ .key = .other, .text = "3" } }, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 300,
        },
        .{
            .name = "folds",
            .setup = &.{ .{ .key = .{ .key = .other, .text = "5" } }, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "dashes",
            .setup = &.{ .{ .key = .{ .key = .other, .text = "6" } }, .{ .wait = 3 } },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
        .{
            .name = "dash-flow",
            .setup = &.{
                .{ .key = .{ .key = .other, .text = "6" } },
                .{ .key = .{ .key = .other, .text = " " } },
            },
            .cycle = &.{},
            .frames = 90,
        },
        .{
            .name = "title",
            .setup = &.{
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .key = .{ .key = .other, .text = " " } },
            },
            .cycle = &.{},
            .frames = 90,
        },
        .{
            .name = "write",
            .setup = &.{
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .key = .{ .key = .other, .text = " " } },
            },
            .cycle = &.{},
            .frames = 240,
        },
        .{
            .name = "sizes",
            .setup = &.{
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .key = .{ .key = .other, .text = "4" } },
                .{ .wait = 3 },
            },
            .cycle = &.{.{ .wait = 1 }},
            .frames = 10,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.page = .shapes;
        app.view = .title;
        app.clock_s = 0;
        app.write_s = write_done_s;
        app.running = false;
        app.flow_offset = 0;
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .frame => |dt_ms| {
                if (!app.animating()) return;
                app.clock_s += dt_ms / 1000;
                if (app.page == .display and app.view == .write) app.write_s += dt_ms / 1000;
                if (app.page == .dashes) {
                    const period = flow_dash.on + flow_dash.off;
                    app.flow_offset = @mod(app.flow_offset - flow_speed * dt_ms / 1000, period);
                }
                cx.redraw();
                cx.keep_animating();
            },
            .key_down => |press| {
                if (press.key != .other or press.typed().len != 1) return;
                switch (press.typed()[0]) {
                    ' ' => {
                        app.running = !app.running;
                        if (app.running and app.write_s >= write_end_s()) app.write_s = 0;
                    },
                    '1' => app.page = .shapes,
                    '2' => app.page = .glyph,
                    '3' => app.page = .curtain,
                    '5' => app.page = .folds,
                    '6' => app.page = .dashes,
                    '4' => {
                        const next: View = if (app.page != .display) .title else switch (app.view) {
                            .title => .write,
                            .write => .sizes,
                            .sizes => .title,
                        };
                        app.page = .display;
                        app.view = next;
                    },
                    else => return,
                }
                cx.redraw();
            },
            else => {},
        }
    }

    /// True while something on the shown page moves.
    fn animating(app: *const App) bool {
        if (!app.running) return false;
        return switch (app.page) {
            .shapes, .dashes => true,
            .glyph, .curtain, .folds => false,
            .display => switch (app.view) {
                .title => true,
                .write => app.write_s < write_end_s(),
                .sizes => false,
            },
        };
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = cx.window;
        const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = window.width, .y1 = window.height };
        // Screen pixels per logical pixel, so chords follow the shape's size on screen.
        shape = .init(draw_cx.text.device_scale());
        switch (app.page) {
            .shapes => app.draw_shapes(cx, clip),
            .glyph => draw_big_glyph(cx, clip),
            .curtain => draw_curtain(cx, clip),
            .folds => draw_folds(cx, clip),
            .dashes => app.draw_dashes(cx, clip),
            .display => switch (app.view) {
                .title => app.draw_title(cx, clip),
                .write => app.draw_write(cx, clip),
                .sizes => draw_sizes(cx, clip),
            },
        }
    }

    fn draw_shapes(app: *const App, cx: *Context, clip: Clip) void {
        const draw_cx = cx.drawing();
        const band: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
        const title = "vector: draw.Fill, space runs the morph, 1 2 3 4 pick a page";
        text.place(draw_cx, title_style, title, band, clip, left);
        const labels = [_]struct { x: f32, y: f32, name: []const u8 }{
            .{ .x = 24, .y = 240, .name = "non-zero" },
            .{ .x = 224, .y = 240, .name = "even-odd" },
            .{ .x = 424, .y = 240, .name = "ring, closed stroke" },
            .{ .x = 624, .y = 392, .name = "translucent bands" },
            .{ .x = 824, .y = 240, .name = "morph" },
            .{ .x = 24, .y = 480, .name = "under a curve" },
            .{ .x = 624, .y = 480, .name = "filled, atlas" },
        };
        for (labels) |item| {
            const rect: Rect = .{ .x = item.x, .y = item.y, .width = 190, .height = 20 };
            text.place(draw_cx, label_style, item.name, rect, clip, left);
        }
        star_at(.{ 116, 144 });
        _ = fill.append(draw_cx, &shape, .{ .color = orange }, clip);
        shape.reset();
        star_at(.{ 316, 144 });
        _ = fill.append(draw_cx, &shape, .{ .color = blue, .rule = .even_odd }, clip);
        shape.reset();
        ring_at(.{ 516, 144 });
        _ = fill.append(draw_cx, &shape, .{ .color = green }, clip);
        shape.reset();
        draw_hexagon(cx, .{ 516, 144 }, clip);
        draw_comb(cx, clip);
        morph_at(.{ 900, 144 }, morph_amount(app.clock_s));
        _ = fill.append(draw_cx, &shape, .{ .color = violet }, clip);
        shape.reset();
        draw_curve(cx, .{ .x = 24, .y = 280, .width = 560, .height = 190 }, clip);
        draw_glyphs(cx, clip);
    }

    /// The dashes page (section 1): every shape at a fixed place from the top-left, labelled.
    fn draw_dashes(app: *const App, cx: *Context, clip: Clip) void {
        const draw_cx = cx.drawing();
        const band: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
        const title = "dashes: draw.path.Dash, round caps, space runs the flow";
        text.place(draw_cx, title_style, title, band, clip, left);
        const labels = [_]struct { x: f32, y: f32, name: []const u8 }{
            .{ .x = 40, .y = 100, .name = "line 10 / 5" },
            .{ .x = 200, .y = 100, .name = "dots 0 / 6" },
            .{ .x = 380, .y = 140, .name = "L, a dash ends at the corner" },
            .{ .x = 620, .y = 100, .name = "hairpin 6 / 4" },
            .{ .x = 840, .y = 140, .name = "hexagon, fitted" },
            .{ .x = 40, .y = 330, .name = "cable 10 / 5, several chunks" },
            .{ .x = 760, .y = 420, .name = "route, rounded corners" },
            .{ .x = 40, .y = 660, .name = "flowing cable" },
        };
        for (labels) |item| {
            const rect: Rect = .{ .x = item.x, .y = item.y, .width = 240, .height = 20 };
            text.place(draw_cx, label_style, item.name, rect, clip, left);
        }
        const path = quads.path;
        const mint: [4]f32 = .{ 0.55, 0.95, 0.80, 1 };
        const line = [_]Point{ .{ 40, 80 }, .{ 140, 80 } };
        _ = path.polyline(draw_cx, &line, dashed(orange, 2, .{ .on = 10, .off = 5 }), clip);
        const dots = [_]Point{ .{ 200, 80 }, .{ 320, 80 } };
        _ = path.polyline(draw_cx, &dots, dashed(blue, 4, .{ .on = 0, .off = 6 }), clip);
        // 55 px to the corner: with offset 25 the dash [35, 55] ends exactly there.
        const corner = [_]Point{ .{ 380, 60 }, .{ 435, 60 }, .{ 435, 115 } };
        _ = path.polyline(draw_cx, &corner, dashed(green, 4, .{ .on = 20, .off = 10, .offset = 25 }), clip);
        const hairpin = [_]Point{ .{ 620, 60 }, .{ 720, 60 }, .{ 744, 70 }, .{ 720, 80 }, .{ 620, 80 } };
        _ = path.polyline(draw_cx, &hairpin, dashed(pink, 3, .{ .on = 6, .off = 4 }), clip);
        var hexagon: [6]Point = undefined;
        for (&hexagon, 0..) |*point, index| {
            const turn = @as(f32, @floatFromInt(index)) * std.math.pi / 3;
            point.* = .{ 900 + 40 * @cos(turn), 90 + 40 * @sin(turn) };
        }
        _ = path.polygon(draw_cx, &hexagon, dashed(violet, 3, .{ .on = 10, .off = 5 }), clip);
        const sag = [4]Point{ .{ 40, 200 }, .{ 240, 300 }, .{ 440, 300 }, .{ 640, 200 } };
        _ = path.cubic(draw_cx, sag, dashed(orange, 3, .{ .on = 10, .off = 5 }), clip);
        var route: [route_points_max]Point = undefined;
        const corners = [_]Point{ .{ 700, 200 }, .{ 920, 200 }, .{ 920, 320 }, .{ 780, 320 }, .{ 780, 400 }, .{ 1200, 400 } };
        const count = rounded_route(&route, &corners, 16);
        _ = path.polyline(draw_cx, route[0..count], dashed(mint, 3, .{ .on = 8, .off = 6 }), clip);
        const flow = [4]Point{ .{ 40, 480 }, .{ 440, 640 }, .{ 840, 640 }, .{ 1240, 480 } };
        var flowing = flow_dash;
        flowing.offset = app.flow_offset;
        _ = path.cubic(draw_cx, flow, dashed(mint, 4, flowing), clip);
    }

    /// "Patchwork" in outlines, each letter rocking and pulsing on its own transform about its
    /// centre. The letters are one shape each, so a transform per letter costs one `set_transform`.
    fn draw_title(app: *const App, cx: *Context, clip: Clip) void {
        const draw_cx = cx.drawing();
        const window = cx.window;
        const header: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
        text.place(draw_cx, title_style, "title: text.Glyphs, one Transform per glyph", header, clip, left);
        const style: text.Style = .{ .face = .sans_bold, .size = title_em, .color = pink };
        const runs = [1]text.Run{.{ .style = style, .bytes = title_word }};
        const rect: Rect = .{ .x = 0, .y = 0, .width = window.width, .height = window.height };
        var glyphs: text.Glyphs = .line(&runs, rect, .{
            .align_x = .center,
            .align_y = .center,
            .ellipsis = false,
        });
        const colors = [_][4]f32{ pink, orange, green, blue, violet };
        while (glyphs.next()) |glyph| {
            const phase = @as(f32, @floatFromInt(glyph.index));
            const rock = 0.5 * @sin(app.clock_s * 3 + phase * 0.8);
            const pulse = 1 + 0.12 * @sin(app.clock_s * 4 + phase);
            const centre: Point = .{
                glyph.pen[0] + 0.5 * glyph.advance,
                glyph.pen[1] - 0.36 * title_em,
            };
            shape.reset();
            shape.set_transform(.around(centre, Transform.rotation(rock).then(.scaling(pulse, pulse))));
            if (!text.contours(&shape, glyph.style.face, glyph.glyph, glyph.style.size, glyph.pen)) continue;
            const color = colors[glyph.index % colors.len];
            _ = fill.append(draw_cx, &shape, .{ .color = color }, clip);
        }
    }

    /// A wrapped paragraph written on glyph by glyph (the step page, 2.6): each glyph grows from
    /// its pen and fades in, one more every `write_glyph_s`.
    fn draw_write(app: *const App, cx: *Context, clip: Clip) void {
        const draw_cx = cx.drawing();
        const header: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
        text.place(draw_cx, title_style, "write: a glyph every 3 frames, space starts it over", header, clip, left);
        const style: text.Style = .{ .face = .sans, .size = write_em, .color = theme.dark.colors.text };
        const runs = [1]text.Run{.{ .style = style, .bytes = paragraph }};
        const rect: Rect = .{ .x = 60, .y = 80, .width = cx.window.width - 120, .height = 560 };
        var glyphs: text.Glyphs = .wrapped(&runs, rect, .{});
        while (glyphs.next()) |glyph| {
            const local = std.math.clamp(
                (app.write_s / write_glyph_s - @as(f32, @floatFromInt(glyph.index))) / write_overlap,
                0,
                1,
            );
            if (local <= 0) continue;
            shape.reset();
            shape.set_transform(.around(glyph.pen, .scaling(local, local)));
            if (!text.contours(&shape, glyph.style.face, glyph.glyph, glyph.style.size, glyph.pen)) continue;
            const color = glyph.style.color;
            const faded = .{ color[0], color[1], color[2], color[3] * local };
            _ = fill.append(draw_cx, &shape, .{ .color = faded }, clip);
        }
    }
};

pub const Context = patchwork.app.Context(App);

/// The clock at which the write-on has shown every glyph of `paragraph`.
fn write_end_s() f32 {
    return (@as(f32, @floatFromInt(paragraph.len)) + write_overlap) * write_glyph_s;
}

/// `sizes_word` as outlines and from the atlas, side by side at 16, 64, and 512 px: the atlas
/// stretches its 160 px raster at the last, the outlines stay sharp.
fn draw_sizes(cx: *Context, clip: Clip) void {
    const draw_cx = cx.drawing();
    const header: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
    text.place(draw_cx, title_style, "sizes: outlines left, atlas right", header, clip, left);
    const widest: text.Style = .{ .face = .sans, .size = 512, .color = pink };
    const atlas_x = 16 + text.measure(widest, sizes_word) + 48;
    for (sizes_rows) |row| {
        const style: text.Style = .{ .face = .sans, .size = row.size, .color = pink };
        const height = text.line_height(style);
        const options: text.Options = .{ .align_x = .start, .align_y = .start, .ellipsis = false };
        const outlines: Rect = .{ .x = 16, .y = row.y, .width = 1200, .height = height };
        text.place_outlines(draw_cx, style, sizes_word, outlines, clip, options);
        const atlas: Rect = .{ .x = atlas_x, .y = row.y, .width = 1200, .height = height };
        text.place(draw_cx, .{ .face = .sans, .size = row.size, .color = blue }, sizes_word, atlas, clip, options);
    }
}

/// The five points of a star of `star_radius` round `centre`, joined every second point, so the
/// contour crosses itself.
fn star_at(centre: Point) void {
    var points: [5]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * 4 * std.math.pi / 5;
        point.* = .{
            centre[0] + star_radius * @sin(turn),
            centre[1] - star_radius * @cos(turn),
        };
    }
    shape.polygon(&points);
}

/// A circle of four cubics, run clockwise or counterclockwise.
fn circle_at(centre: Point, radius: f32, clockwise: bool) void {
    const k = 0.5523 * radius;
    const c = centre;
    const r = if (clockwise) radius else -radius;
    const j = if (clockwise) k else -k;
    shape.move_to(.{ c[0], c[1] - radius });
    shape.cubic_to(.{ .{ c[0] + j, c[1] - radius }, .{ c[0] + r, c[1] - k } }, .{ c[0] + r, c[1] });
    shape.cubic_to(.{ .{ c[0] + r, c[1] + k }, .{ c[0] + j, c[1] + radius } }, .{ c[0], c[1] + radius });
    shape.cubic_to(.{ .{ c[0] - j, c[1] + radius }, .{ c[0] - r, c[1] + k } }, .{ c[0] - r, c[1] });
    shape.cubic_to(.{ .{ c[0] - r, c[1] - k }, .{ c[0] - j, c[1] - radius } }, .{ c[0], c[1] - radius });
    shape.close();
}

/// A disc with a hole: the inner contour runs the other way.
fn ring_at(centre: Point) void {
    circle_at(centre, 80, true);
    circle_at(centre, 44, false);
}

/// A closed stroke inside the ring's hole, which `path.polygon` joins at its start.
fn draw_hexagon(cx: *Context, centre: Point, clip: Clip) void {
    var points: [6]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = @as(f32, @floatFromInt(index)) * std.math.pi / 3;
        point.* = .{ centre[0] + 30 * @cos(turn), centre[1] + 30 * @sin(turn) };
    }
    const stroke: quads.path.Stroke = .{ .color = orange, .width = 3, .hover = 0 };
    _ = quads.path.polygon(cx.drawing(), &points, stroke, clip);
}

/// A dashed stroke of `color` and `width`.
fn dashed(color: [4]f32, width: f32, dash: quads.path.Dash) quads.path.Stroke {
    return .{ .color = color, .width = width, .hover = 0, .dash = dash };
}

/// Segments of each rounded corner of a route.
const route_corner_segments: u32 = 6;
/// Corners a route takes at most, ends included.
const route_corners_max: u32 = 8;
const route_points_max: u32 = 2 + (route_corners_max - 2) * (route_corner_segments + 1);

/// The Patch look's cable (step 65's page): straight runs between `corners` (axis-aligned), each
/// inner corner rounded by a quarter circle of `radius`, written into `out`. Returns the count.
fn rounded_route(out: *[route_points_max]Point, corners: []const Point, radius: f32) u32 {
    assert(corners.len >= 2);
    assert(corners.len <= route_corners_max);
    out[0] = corners[0];
    var count: u32 = 1;
    for (corners[1 .. corners.len - 1], 1..) |corner, index| {
        const into = unit(corners[index - 1], corner);
        const away = unit(corner, corners[index + 1]);
        const start: Point = .{ corner[0] - into[0] * radius, corner[1] - into[1] * radius };
        const end: Point = .{ corner[0] + away[0] * radius, corner[1] + away[1] * radius };
        // A quarter circle from `start` to `end`, whose centre is `start` moved by `away`.
        const centre: Point = .{ start[0] + away[0] * radius, start[1] + away[1] * radius };
        var step: u32 = 0;
        while (step <= route_corner_segments) : (step += 1) {
            const angle = @as(f32, @floatFromInt(step)) / route_corner_segments * std.math.pi / 2;
            const back = @cos(angle);
            const along = @sin(angle);
            out[count] = .{
                centre[0] - away[0] * radius * back + into[0] * radius * along,
                centre[1] - away[1] * radius * back + into[1] * radius * along,
            };
            count += 1;
        }
        assert(@abs(out[count - 1][0] - end[0]) < 1.0e-3);
    }
    out[count] = corners[corners.len - 1];
    count += 1;
    assert(count <= route_points_max);
    return count;
}

/// The unit vector from `a` to `b`.
fn unit(a: Point, b: Point) Point {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const span = @sqrt(dx * dx + dy * dy);
    assert(span > 0);
    return .{ dx / span, dy / span };
}

/// The rows of the folds page: a stroke width and how far the spike's way down lands from its
/// way up, 0 turning straight back along itself.
const fold_rows = [_]struct { width: f32, miss: f32 }{
    .{ .width = 2, .miss = 0 },
    .{ .width = 3, .miss = 0 },
    .{ .width = 5, .miss = 0 },
    .{ .width = 2.5, .miss = 0.05 },
    .{ .width = 3, .miss = 0.4 },
    .{ .width = 5, .miss = 0.05 },
};
/// The columns' sub-pixel offsets, so a spike lies on pixel centres and between them.
const fold_phases = [_]f32{ 0, 0.25, 0.5, 0.75, 0.125, 0.3 };
const fold_spike: f32 = 40;
const fold_row_pitch: f32 = 110;
const fold_column_pitch: f32 = 140;
/// How far below its comb a middle spike is drawn again on its own.
const fold_alone_dy: f32 = 52;

/// Tapestry's comb (Patchwork step 62): three spikes as one polyline, up and back down each,
/// so the middle spike's tip is a chunk seam where the stroke turns back. Below each, the
/// middle spike drawn alone as one chunk: the two must match pixel for pixel.
fn draw_folds(cx: *Context, clip: Clip) void {
    const draw_cx = cx.drawing();
    const band: Rect = .{ .x = 16, .y = 0, .width = 1000, .height = 40 };
    const title = "folds: a stroke turning back at a chunk seam, above the same spike drawn alone";
    text.place(draw_cx, title_style, title, band, clip, left);
    for (fold_rows, 0..) |row, row_index| {
        for (fold_phases, 0..) |phase, column| {
            const x0 = 40 + @as(f32, @floatFromInt(column)) * fold_column_pitch + phase;
            const base = 96 + @as(f32, @floatFromInt(row_index)) * fold_row_pitch + phase;
            const top = base - fold_spike;
            var comb: [9]Point = undefined;
            for (0..3) |spike| {
                const x = x0 + @as(f32, @floatFromInt(spike)) * fold_spike;
                comb[3 * spike] = .{ x, base };
                comb[3 * spike + 1] = .{ x, top };
                comb[3 * spike + 2] = .{ x + row.miss, base };
            }
            const stroke: quads.path.Stroke = .{ .color = orange, .width = row.width, .hover = 0 };
            _ = quads.path.polyline(draw_cx, &comb, stroke, clip);
            const below = base + fold_alone_dy;
            const alone = [_]Point{ .{ comb[3][0], below }, .{ comb[4][0], below - fold_spike }, .{ comb[5][0], below } };
            _ = quads.path.polyline(draw_cx, &alone, stroke, clip);
        }
    }
}

/// The comb, translucent over a bright bar, so a row blended twice shows as a stripe.
fn draw_comb(cx: *Context, clip: Clip) void {
    const draw_cx = cx.drawing();
    const bar: Rect = .{ .x = 660, .y = 44, .width = 24, .height = 346 };
    draw_cx.append(quads.Box, null, .of(bar, clip, .{ .fill = blue })) catch {};
    const x: f32 = 628;
    const y: f32 = 56;
    shape.move_to(.{ x, y });
    var tooth: u32 = 0;
    while (tooth < comb_teeth) : (tooth += 1) {
        const top = y + @as(f32, @floatFromInt(tooth)) * comb_pitch;
        shape.line_to(.{ x + 150, top + 0.25 * comb_pitch });
        shape.line_to(.{ x + 150, top + 0.5 * comb_pitch });
        shape.line_to(.{ x + 90, top + 0.75 * comb_pitch });
        shape.line_to(.{ x + 90, top + comb_pitch });
    }
    shape.line_to(.{ x, y + @as(f32, @floatFromInt(comb_teeth)) * comb_pitch });
    _ = fill.append(draw_cx, &shape, .{ .color = .{ 1, 1, 1, 0.5 } }, clip);
    shape.reset();
}

/// How far the morph is from the circle, 0 to 1 and back on `morph_period_s`, eased.
fn morph_amount(seconds: f32) f32 {
    const phase = @mod(seconds / morph_period_s, 1);
    const up = 1 - @abs(2 * phase - 1);
    return up * up * (3 - 2 * up);
}

/// A rounded square of `morph_side`: `amount` 0 is a circle, 1 a square with corners of a quarter
/// of that radius.
fn morph_at(centre: Point, amount: f32) void {
    const half = morph_side / 2;
    const radius = half * (1 - 0.75 * amount);
    const k = 0.5523 * radius;
    const x0 = centre[0] - half;
    const x1 = centre[0] + half;
    const y0 = centre[1] - half;
    const y1 = centre[1] + half;
    shape.move_to(.{ x0 + radius, y0 });
    shape.line_to(.{ x1 - radius, y0 });
    shape.cubic_to(.{ .{ x1 - radius + k, y0 }, .{ x1, y0 + radius - k } }, .{ x1, y0 + radius });
    shape.line_to(.{ x1, y1 - radius });
    shape.cubic_to(.{ .{ x1, y1 - radius + k }, .{ x1 - radius + k, y1 } }, .{ x1 - radius, y1 });
    shape.line_to(.{ x0 + radius, y1 });
    shape.cubic_to(.{ .{ x0 + radius - k, y1 }, .{ x0, y1 - radius + k } }, .{ x0, y1 - radius });
    shape.line_to(.{ x0, y0 + radius });
    shape.cubic_to(.{ .{ x0, y0 + radius - k }, .{ x0 + radius - k, y0 } }, .{ x0 + radius, y0 });
    shape.close();
}

/// The region under a plotted curve, with the same samples stroked on top.
fn draw_curve(cx: *Context, rect: Rect, clip: Clip) void {
    const draw_cx = cx.drawing();
    var samples: [curve_samples]f32 = undefined;
    var points: [curve_samples]Point = undefined;
    for (&samples, 0..) |*sample, index| {
        const t = @as(f32, @floatFromInt(index)) / (curve_samples - 1);
        const wave = @sin(t * 9) * 0.28 + @sin(t * 23 + 1) * 0.12;
        sample.* = 0.5 + wave * (0.4 + 0.6 * t);
    }
    quads.path.plot_points(&points, &samples, rect, .{ 0, 1 });
    const floor = rect.y + rect.height;
    shape.move_to(.{ rect.x, floor });
    for (points) |point| shape.line_to(point);
    shape.line_to(.{ rect.x + rect.width, floor });
    const area = .{ green[0], green[1], green[2], 0.35 };
    _ = fill.append(draw_cx, &shape, .{ .color = area }, clip);
    shape.reset();
    const stroke: quads.path.Stroke = .{ .color = green, .width = 2, .hover = 0 };
    _ = quads.path.plot(draw_cx, &samples, rect, .{ 0, 1 }, stroke, clip);
}

/// `code` of the sans face at `em` logical pixels with its pen at `pen`, into `shape`.
fn glyph_at(code: u21, em: f32, pen: Point) void {
    const font = text.font_of(.sans);
    const id = ttf.glyph_id(font, code);
    assert(id != 0);
    const loaded = ttf.load(font, id, &outline);
    assert(loaded == .ready);
    shape.outline(&outline, em / @as(f32, @floatFromInt(font.units_per_em)), pen);
}

/// The same glyph at one size: from its outline as a shape, then from the atlas.
fn draw_glyphs(cx: *Context, clip: Clip) void {
    const draw_cx = cx.drawing();
    glyph_at('g', glyph_em, .{ 632, 620 });
    _ = fill.append(draw_cx, &shape, .{ .color = pink }, clip);
    shape.reset();
    const rect: Rect = .{ .x = 780, .y = 500, .width = 120, .height = 160 };
    text.place(draw_cx, glyph_style, "g", rect, clip, left);
}

/// The cost page: one large glyph, em a fixed share of the window's height.
fn draw_big_glyph(cx: *Context, clip: Clip) void {
    const em = cx.window.height / 1.08;
    glyph_at('&', em, .{ 0.5 * (cx.window.width - em * 0.75), cx.window.height * 0.86 });
    _ = fill.append(cx.drawing(), &shape, .{ .color = pink }, clip);
    shape.reset();
}

/// The cost page's worst case: long edges side by side over the whole window, so every fragment
/// loops over `curtain_edges` segments.
fn draw_curtain(cx: *Context, clip: Clip) void {
    const window = cx.window;
    const step = window.width / @as(f32, @floatFromInt(curtain_edges));
    shape.move_to(.{ 0, 0 });
    var edge: u32 = 1;
    while (edge <= curtain_edges) : (edge += 1) {
        const x = @as(f32, @floatFromInt(edge)) * step;
        shape.line_to(.{ x, if (edge % 2 == 1) window.height else 0 });
    }
    shape.line_to(.{ window.width, 0 });
    const color = .{ violet[0], violet[1], violet[2], 0.8 };
    _ = fill.append(cx.drawing(), &shape, .{ .color = color, .rule = .even_odd }, clip);
    shape.reset();
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

// Locks every page: no shape is refused on any page at 1x or at 2x, the comb splits into at
// least three bands, the star's points are 2 per segment, and the curtain is one band at the cap.
test "every page's shapes fit" {
    const app = new_app();
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    const bands = cx.draw.items(quads.Fill);
    try std.testing.expectEqual(@as(f32, 10), bands[0].point_count);
    var tallest: u32 = 0;
    for (bands) |band| {
        try std.testing.expect(band.point_count <= 2 * fill.segments_max);
        tallest = @max(tallest, @as(u32, @intFromFloat(band.point_count)));
    }
    try std.testing.expect(tallest > 48);
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, 1280, 720, 240));
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    send(app, .{ .key_down = input.key_press(.other, .none, false, "2") });
    try std.testing.expectEqual(Page.glyph, app.page);
    _ = frame_at(app);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try std.testing.expect(cx.draw.items(quads.Fill).len >= 2);
    send(app, .{ .key_down = input.key_press(.other, .none, false, "3") });
    _ = frame_at(app);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try std.testing.expectEqual(@as(usize, 1), cx.draw.items(quads.Fill).len);
    const curtain = cx.draw.items(quads.Fill)[0];
    try std.testing.expectEqual(@as(f32, 2 * fill.segments_max), curtain.point_count);
}

// Locks the display page: key 4 steps title, write, sizes, title; none of the views refuses a
// glyph at 1x or 2x, the title is nine letters of at least one band each, and the finished
// paragraph is one shape per inked glyph of `paragraph`.
test "the display views fit" {
    const app = new_app();
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expectEqual(Page.display, app.page);
    try std.testing.expectEqual(View.title, app.view);
    for ([_]u32{ 120, 240 }) |scale_120| {
        const cx = &fixture.context;
        cx.redraw();
        assert(ui.draw_frame(App, app, cx, 1280, 720, scale_120));
        try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
        try std.testing.expect(cx.draw.items(quads.Fill).len >= title_word.len);
    }
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expectEqual(View.write, app.view);
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    var inked: usize = 0;
    for (paragraph) |letter| inked += @intFromBool(letter != ' ');
    try std.testing.expect(cx.draw.items(quads.Fill).len >= inked);
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expectEqual(View.sizes, app.view);
    _ = frame_at(app);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expectEqual(View.title, app.view);
}

// Locks the write-on: Space restarts it from nothing (no fills at its first frame), a glyph is
// shown every 3 frames at 60 Hz, the app asks for frames until the last glyph has grown and then
// sleeps, and the title runs on the clock until stopped.
test "the write-on runs, finishes, and sleeps" {
    const app = new_app();
    for ("44") |key| send(app, .{ .key_down = input.key_press(.other, .none, false, &.{key}) });
    try std.testing.expectEqual(View.write, app.view);
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expectEqual(@as(f32, 0), app.write_s);
    const cx = frame_at(app);
    try std.testing.expectEqual(@as(usize, 0), cx.draw.items(quads.Fill).len);
    var frames: u32 = 0;
    while (ui.animate(App, app, cx, 16)) : (frames += 1) {
        try std.testing.expect(frames < 2000);
        if (frames == 29) {
            _ = frame_at(app);
            const shown = cx.draw.items(quads.Fill).len;
            try std.testing.expect(shown >= 8 and shown <= 30);
        }
    }
    try std.testing.expect(app.write_s >= write_end_s());
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expectEqual(View.title, app.view);
    try std.testing.expect(ui.animate(App, app, cx, 16));
    send(app, .{ .key_down = input.key_press(.other, .none, false, "4") });
    try std.testing.expect(!ui.animate(App, app, cx, 16));
}

// Locks the folds page: no stroke is refused at 1x or 2x, and each comb's first chunk ends at
// its middle spike's tip (5 points), so the stroke turns back at a seam, while the spike drawn
// alone below it is one chunk of 3 points.
test "the folds page turns every comb back at a seam" {
    const app = new_app();
    send(app, .{ .key_down = input.key_press(.other, .none, false, "5") });
    try std.testing.expectEqual(Page.folds, app.page);
    for ([_]u32{ 120, 240 }) |scale_120| {
        const cx = &fixture.context;
        cx.redraw();
        assert(ui.draw_frame(App, app, cx, 1280, 720, scale_120));
        try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
        const chunks = cx.draw.items(quads.Path);
        try std.testing.expectEqual(fold_rows.len * fold_phases.len * 3, chunks.len);
        var index: usize = 0;
        while (index < chunks.len) : (index += 3) {
            try std.testing.expectEqual(@as(f32, 5), chunks[index].point_count);
            try std.testing.expectEqual(@as(f32, 1), chunks[index].next);
            try std.testing.expectEqual(@as(f32, 1), chunks[index + 1].prev);
            try std.testing.expectEqual(@as(f32, 3), chunks[index + 2].point_count);
        }
    }
}

// Locks the dashes page: no stroke is refused at 1x or 2x, every chunk on it is dashed, the
// route's corners are quarter circles that end on the next run, and Space flows the cable's
// offset at `flow_speed`, wrapped to its period, until stopped.
test "the dashes page draws dashed strokes and flows on space" {
    const app = new_app();
    send(app, .{ .key_down = input.key_press(.other, .none, false, "6") });
    try std.testing.expectEqual(Page.dashes, app.page);
    for ([_]u32{ 120, 240 }) |scale_120| {
        const cx = &fixture.context;
        cx.redraw();
        assert(ui.draw_frame(App, app, cx, 1280, 720, scale_120));
        try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
        const chunks = cx.draw.items(quads.Path);
        try std.testing.expect(chunks.len >= 12);
        for (chunks) |chunk| try std.testing.expect(chunk.dash_period > 0);
    }
    var route: [route_points_max]Point = undefined;
    const corners = [_]Point{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 } };
    const count = rounded_route(&route, &corners, 16);
    try std.testing.expectEqual(@as(u32, 2 + route_corner_segments + 1), count);
    try std.testing.expectEqual(Point{ 84, 0 }, route[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 100), route[count - 2][0], 1.0e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 16), route[count - 2][1], 1.0e-4);
    const cx = &fixture.context;
    try std.testing.expect(!ui.animate(App, app, cx, 16));
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(ui.animate(App, app, cx, 16));
    try std.testing.expectApproxEqAbs(@as(f32, 15 - 0.64), app.flow_offset, 1.0e-4);
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(!ui.animate(App, app, cx, 16));
}

// Locks the comb's bands, the seam the translucent golden shows: at least three, whose rects meet.
test "the tall comb splits into at least three bands" {
    const app = new_app();
    const cx = frame_at(app);
    var comb_bands: u32 = 0;
    var last_bottom: f32 = 0;
    for (cx.draw.items(quads.Fill)) |band| {
        if (band.color[3] != 0.5) continue;
        if (comb_bands != 0) try std.testing.expectEqual(last_bottom, band.rect[1]);
        comb_bands += 1;
        last_bottom = band.rect[1] + band.rect[3];
    }
    try std.testing.expect(comb_bands >= 3);
}

// Locks the morph's ends and its clock: 0 at the start, 1 at half the period, 0 again at the
// period; it runs on Space, and asks for no frame once stopped.
test "the morph runs on space and sleeps when stopped" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), morph_amount(0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), morph_amount(1), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), morph_amount(2), 1.0e-6);
    const app = new_app();
    _ = frame_at(app);
    try std.testing.expect(!ui.animate(App, app, &fixture.context, 16));
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(ui.animate(App, app, &fixture.context, 16));
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), app.clock_s, 1.0e-5);
    send(app, .{ .key_down = input.key_press(.other, .none, false, " ") });
    try std.testing.expect(!ui.animate(App, app, &fixture.context, 16));
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

comptime {
    patchwork.app.check(App);
}

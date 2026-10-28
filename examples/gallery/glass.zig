//! The gallery's glass page (step 40): backdrops, `draw.Glass`, and the theme's materials.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Shows
//! A music screen: sixteen album cards scroll in a view under three floating glass faces, a
//! sidebar (`widgets.Panel` with the page's material), a segmented bar that picks that material
//! (Clear, Frosted, Tinted, Solid), and a transport bar. The sidebar holds a `widgets.Dropdown`
//! whose list is glass on the popup level, so it blurs the sidebar under it. The transport's
//! position slider is `widgets.SliderOf(LensSkin)`: the library slider whose knob is a small
//! clear glass disc on the popup level, bending the track under it like a lens. Every colour
//! comes from the scheme: the cards are gradients between its accents.
//!
//! ## 2. Levels (layers)
//! ```text
//! 1  content_layer   the page's gradient and the cards (draw.Surface), in a view
//! 2  ink_layer       the cards' titles
//! 3  glass_layer     backdrop A (the page's material): the sidebar, the bar, the transport,
//!                    then the boxes on them and the dropdown
//! 4  label_layer     the text and icons on the glass, over those boxes
//! 6  popup           backdrop B: the lens (LensSkin) and the dropdown's open list
//! ```
//! Within layer 3 the glass faces are appended first, so the `Glass` batch draws under the
//! boxes on them; the page's own text goes one layer up, because a `Glyph` batch that opened
//! before a box on the same layer would draw under it. The dropdown's label stays on 3 after its
//! face, the first glyph there. With the Solid material `kit.backdrop` marks nothing and the faces
//! are solid; the lens keeps its own backdrop.
//!
//! ## 3. Layout (logical pixels, from the page's top-left; the page is 1248 x 584)
//! ```text
//! view      the whole page; content 1232 wide (the gutter), 16 inset, 4 columns of 282 x 200
//!           cards 24 apart, 4 rows, and 96 below the last so it scrolls clear of the transport
//! sidebar   (16, 16), 240 wide, 16 above the bottom, radius 22: title, five rows of 32, and
//!           the output dropdown 216 x 32, 12 inside its bottom
//! bar       392 x 40 centred over the content right of the sidebar, at y 16; segments 93 x 32
//! transport 600 x 64 centred likewise, 16 above the bottom: three icons in 40 px cells from 16,
//!           the slider 360 x 28 from 152, the time from 528
//! ```

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const icons = @import("icons.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;

const content_layer: quads.Layer = @fromBackingInt(1);
const ink_layer: quads.Layer = @fromBackingInt(2);
pub const glass_layer: quads.Layer = @fromBackingInt(3);
const label_layer: quads.Layer = @fromBackingInt(4);

pub const inset: f32 = 16;
pub const sidebar_w: f32 = 240;
pub const sidebar_radius: f32 = 22;
pub const row_h: f32 = 32;
pub const bar_w: f32 = 392;
pub const bar_h: f32 = 40;
pub const segment_inset: f32 = 4;
pub const segment_gap: f32 = 4;
pub const segment_w: f32 = (bar_w - 2 * segment_inset - (material_names.len - 1) * segment_gap) / material_names.len;
pub const transport_w: f32 = 600;
pub const transport_h: f32 = 64;
pub const slider_x: f32 = 152;
pub const slider_w: f32 = 360;
pub const slider_h: f32 = 28;
pub const lens_side: f32 = 28;
pub const columns: u32 = 4;
pub const card_w: f32 = 282;
pub const card_h: f32 = 200;
pub const card_gap: f32 = 24;
pub const card_radius: f32 = 18;
/// Room under the last row, so it scrolls clear of the transport.
pub const tail_h: f32 = 96;
pub const grid_h: f32 = inset + rows * card_h + (rows - 1) * card_gap + tail_h;
const rows: f32 = @floatFromInt(album_names.len / columns);

comptime {
    assert(segment_w == 93);
    assert(album_names.len % columns == 0);
    // Four cards and three gaps fill the view's content width (1248 less the gutter) inset 16.
    assert(2 * inset + columns * card_w + (columns - 1) * card_gap == 1248 - 16);
    assert(grid_h == 984);
}

pub const material_names = [_][]const u8{ "Clear", "Frosted", "Tinted", "Solid" };
const materials = [_]theme.Material{ .clear, .frosted, .tinted, .solid };
const material_start: u32 = 1;
pub const row_names = [_][]const u8{ "Listen now", "Browse", "Radio", "Albums", "Songs" };
pub const output_names = [_][]const u8{ "Speakers", "Headphones", "Studio monitors" };
pub const album_names = [_][]const u8{
    "Aurora", "Basalt",  "Cinder", "Delta", "Ember",  "Fjord",  "Glow", "Harbor",
    "Indigo", "Juniper", "Kelp",   "Lumen", "Meadow", "Nimbus", "Opal", "Prism",
};

pub const view_id = ui.id("glass_view", 0);
pub const segment_id = ui.id("glass_segment", 0);
pub const output_id = ui.id("glass_output", 0);
pub const position_id = ui.id("glass_position", 0);
const button_flags: ui.Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .pointer };

/// The lens: a clear disc that bends the whole of itself and reads the lightly filtered level.
const lens_material: theme.Material = .clear;
const lens_look: kit.GlassLook = .{
    .radius = lens_side * 0.5,
    .frost = 0,
    .saturation = 1.1,
    .rim = 0.8,
    .refraction = 12,
    .bevel = lens_side * 0.5,
};

/// The transport's position slider: the library behaviour, the lens look (section 1).
pub const LensSlider = widgets.SliderOf(LensSkin);

/// A thin track in the text colour, filled to the value, and a glass disc on the popup level
/// as the knob; a solid disc where the app has no glass.
pub const LensSkin = struct {
    pub fn slider(cx: anytype, look: widgets.SliderLook) ?widgets.Shape {
        assert(look.value >= 0 and look.value <= 1);
        const colors = &cx.theme().colors;
        const travel = slider_travel(look.rect);
        const track: Rect = .{ .x = travel[0], .y = look.rect.y + look.rect.height * 0.5 - 2, .width = travel[1] - travel[0], .height = 4 };
        kit.face(cx, track, look.clip, .{ .fill = alpha(colors.text, 0.25), .radius = 2 });
        var filled = track;
        filled.width = look.value * track.width;
        kit.face(cx, filled, look.clip, .{ .fill = alpha(colors.text, 0.85), .radius = 2 });
        const center = travel[0] + look.value * (travel[1] - travel[0]);
        const disc: Rect = .{
            .x = center - lens_side * 0.5,
            .y = look.rect.y + (look.rect.height - lens_side) * 0.5,
            .width = lens_side,
            .height = lens_side,
        };
        _ = kit.backdrop(cx, .popup, lens_material);
        const previous = cx.drawing().layer(.popup);
        defer _ = cx.drawing().layer(previous);
        if (!kit.glass(cx, disc, look.clip, lens_look)) {
            kit.face(cx, disc, look.clip, .{ .fill = colors.control, .radius = lens_side * 0.5, .hover = kit.weight(look.hover, cx.theme().hover_lighten) });
        }
        return .{ .rect = look.rect, .radius = lens_side * 0.5 };
    }

    /// The disc's centre travels the rect inset by half its side.
    pub fn slider_travel(area: Rect) [2]f32 {
        return .{ area.x + lens_side * 0.5, area.x + area.width - lens_side * 0.5 };
    }
};

/// What an event on the page did.
pub const Report = union(enum) {
    material: u32,
    output: u32,
    position: f32,
};

/// The page's state (section 1).
pub const Page = struct {
    material: u32,
    segments: [material_names.len]kit.Interaction,
    view: ui.ViewState,
    output: widgets.Dropdown,
    position: LensSlider,

    /// The page with Frosted picked; popups stay inside `bounds`.
    pub fn init(self: *Page, bounds: Rect) void {
        self.material = material_start;
        for (&self.segments) |*item| item.* = kit.Interaction.init(kit.hover_rate_per_ms, kit.down_rate_per_ms);
        self.view = ui.ViewState.init();
        self.output = widgets.Dropdown.init(output_id, &output_names, 0);
        self.output.menu.bounds = bounds;
        self.output.menu.material = materials[material_start];
        self.position = .{
            .id = position_id,
            .hover = .init(kit.hover_rate_per_ms),
            .value = 0.35,
            .track = kit.paint_of(theme.dark.colors.track, 2),
            .fill = kit.paint_of(theme.dark.colors.text, 2),
            .knob = kit.paint_of(theme.dark.colors.control, lens_side * 0.5),
        };
        assert(self.material < material_names.len);
    }

    /// The picked material.
    pub fn picked(self: *const Page) theme.Material {
        return materials[self.material];
    }

    pub fn handle(self: *Page, cx: anytype, event: input.Event) ?Report {
        if (event == .frame) {
            for (&self.segments) |*item| item.frame(cx, event.frame);
            _ = self.output.handle(cx, event);
            _ = self.position.handle(cx, event);
            return null;
        }
        var report: ?Report = null;
        for (&self.segments, 0..) |*item, index| {
            const hit = cx.hit(segment_id.derive(index), event);
            item.react(cx, hit);
            if (hit == .up and hit.up.inside and self.material != index) {
                self.material = @intCast(index);
                self.output.menu.material = materials[index];
                cx.redraw();
                report = .{ .material = @intCast(index) };
            }
        }
        switch (self.output.handle(cx, event)) {
            .changed => |index| report = .{ .output = index },
            .none => {},
        }
        switch (self.position.handle(cx, event)) {
            .changed => |value| report = .{ .position = value },
            .released, .none => {},
        }
        _ = self.view.handle(cx, view_id, event);
        return report;
    }

    /// Fills the rest of the current container with the page (section 3).
    pub fn draw(self: *Page, cx: anytype) void {
        const page = cx.peek(ui.sized(.fill, .fill));
        const clip = cx.visible(page) orelse {
            _ = cx.walk(ui.sized(.fill, .fill));
            return;
        };
        const scheme = cx.theme();
        const previous = cx.drawing().layer(content_layer);
        defer _ = cx.drawing().layer(previous);
        kit.surface(cx, page, clip, .{
            .fill = mix(scheme.colors.background, scheme.colors.darken, 0.2),
            .fill_to = mix(scheme.colors.background, scheme.colors.focus, 0.15),
            .gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } },
            .radius = 12,
        });
        self.draw_cards(cx);
        const material = self.picked();
        _ = kit.backdrop(cx, glass_layer, material);
        _ = cx.drawing().layer(glass_layer);
        const sidebar: Rect = .{ .x = page.x + inset, .y = page.y + inset, .width = sidebar_w, .height = page.height - 2 * inset };
        const content_x = sidebar.x + sidebar_w + 24;
        const content_w = page.x + page.width - inset - content_x;
        const bar: Rect = .{ .x = content_x + (content_w - bar_w) * 0.5, .y = page.y + inset, .width = bar_w, .height = bar_h };
        const transport: Rect = .{
            .x = content_x + (content_w - transport_w) * 0.5,
            .y = page.y + page.height - inset - transport_h,
            .width = transport_w,
            .height = transport_h,
        };
        // The faces first, so the Glass batch draws under everything on them (section 2).
        const panel: widgets.Panel = .{ .paint = kit.paint_of(scheme.colors.panel, sidebar_radius), .material = material };
        _ = cx.begin_at(sidebar, .{ .flow = .down });
        panel.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        floating(cx, bar, clip, material, bar_h * 0.5);
        floating(cx, transport, clip, material, transport_h * 0.5);
        self.draw_sidebar(cx, sidebar, clip, material);
        self.draw_bar(cx, bar, clip);
        self.draw_transport(cx, transport, clip);
    }

    /// The open output list (`ui.overlays`).
    pub fn draw_overlay(self: *const Page, cx: anytype) void {
        self.output.draw_overlay(cx);
    }

    /// The view of cards (section 3), on `content_layer` and their titles on `ink_layer`.
    fn draw_cards(self: *Page, cx: anytype) void {
        const scheme = cx.theme();
        _ = cx.begin_view(view_id, ui.sized(.fill, .fill), .{ .flow = .down }, &self.view);
        const grid = cx.walk(ui.sized(.fill, .{ .fixed = grid_h }));
        for (album_names, 0..) |name, index| {
            const rect = card_rect(grid.x, grid.y, @intCast(index));
            const card_clip = cx.visible(rect) orelse continue;
            const from = scheme.accents[index % theme.accent_count];
            const to = mix(scheme.accents[(index + 1) % theme.accent_count], scheme.colors.darken, 0.35);
            kit.surface(cx, rect, card_clip, .{
                .fill = from,
                .fill_to = to,
                .gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } },
                .radius = card_radius,
            });
            kit.surface(cx, rect, card_clip, .{
                .fill = alpha(scheme.colors.lighten, 0.22),
                .fill_to = alpha(scheme.colors.lighten, 0),
                .gradient = .{ .radial = .{ .center = .{ 0.25, 0.2 }, .radius = .{ 0.7, 0.8 } } },
                .radius = card_radius,
            });
            const title: Rect = .{ .x = rect.x + 16, .y = rect.y + rect.height - 44, .width = rect.width - 32, .height = 28 };
            const style: text.Style = .{ .face = .sans_bold, .size = 18, .color = scheme.colors.lighten };
            ink(cx, ink_layer, style, name, title, card_clip, .start);
        }
        cx.end_view();
    }

    /// The sidebar's title, rows, and output dropdown.
    fn draw_sidebar(self: *Page, cx: anytype, sidebar: Rect, clip: Clip, material: theme.Material) void {
        const colors = &cx.theme().colors;
        const title: Rect = .{ .x = sidebar.x + 16, .y = sidebar.y + 12, .width = sidebar_w - 32, .height = 36 };
        ink(cx, label_layer, .{ .face = .sans_bold, .size = 22, .color = colors.text }, "Library", title, clip, .start);
        for (row_names, 0..) |name, index| {
            const row: Rect = .{ .x = sidebar.x + 8, .y = sidebar.y + 56 + @as(f32, @floatFromInt(index)) * row_h, .width = sidebar_w - 16, .height = row_h - 4 };
            if (index == 0) kit.face(cx, row, clip, .{ .fill = alpha(colors.text, 0.12), .radius = 8 });
            ink(cx, label_layer, .{ .face = .sans, .size = 15, .color = colors.text }, name, ui.cx.inset(row, .xy(12, 0)), clip, .start);
        }
        const caption: Rect = .{ .x = sidebar.x + 16, .y = sidebar.y + sidebar.height - 12 - 32 - 26, .width = sidebar_w - 32, .height = 22 };
        ink(cx, label_layer, .{ .face = .sans, .size = 13, .color = alpha(colors.text, 0.7) }, "Output", caption, clip, .start);
        const face: Rect = .{ .x = sidebar.x + 12, .y = sidebar.y + sidebar.height - 12 - 32, .width = sidebar_w - 24, .height = 32 };
        assert(self.output.menu.material.?.kind == material.kind);
        _ = cx.begin_at(face, .{ .flow = .down });
        self.output.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    /// The segmented bar: the picked material's segment a focus-coloured pill.
    fn draw_bar(self: *const Page, cx: anytype, bar: Rect, clip: Clip) void {
        const scheme = cx.theme();
        const colors = &scheme.colors;
        for (material_names, 0..) |name, index| {
            const segment = segment_rect(bar.x, bar.y, @intCast(index));
            const item = &self.segments[index];
            const selected = index == self.material;
            if (selected) {
                kit.face(cx, segment, clip, .{
                    .fill = colors.focus,
                    .radius = segment.height * 0.5,
                    .hover = kit.weight(item.hover.value, scheme.hover_lighten),
                    .down = kit.weight(item.down_value(), scheme.down_darken),
                });
            } else if (item.hover.value > 0) {
                kit.face(cx, segment, clip, .{ .fill = alpha(colors.text, 0.08 * item.hover.value), .radius = segment.height * 0.5 });
            }
            cx.area(segment_id.derive(index), segment, segment.height * 0.5, button_flags);
            const color = if (selected) colors.lighten else colors.text;
            ink(cx, label_layer, .{ .face = .sans, .size = 14, .color = color }, name, segment, clip, .center);
        }
    }

    /// The transport: three icons, the lens slider, and the time.
    fn draw_transport(self: *Page, cx: anytype, transport: Rect, clip: Clip) void {
        const colors = &cx.theme().colors;
        const glyphs = [_]u21{ icons.skip_back, icons.play, icons.skip_forward };
        for (glyphs, 0..) |codepoint, index| {
            const cell: Rect = .{ .x = transport.x + 16 + @as(f32, @floatFromInt(index)) * 40, .y = transport.y + 12, .width = 40, .height = 40 };
            const previous = cx.drawing().layer(label_layer);
            defer _ = cx.drawing().layer(previous);
            kit.icon(cx, .icons, codepoint, 20, cell, clip, colors.text);
        }
        const slot: Rect = .{ .x = transport.x + slider_x, .y = transport.y + (transport_h - slider_h) * 0.5, .width = slider_w, .height = slider_h };
        _ = cx.begin_at(slot, .{ .flow = .down });
        self.position.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        const time: Rect = .{ .x = transport.x + 528, .y = transport.y, .width = 56, .height = transport_h };
        ink(cx, label_layer, .{ .face = .mono, .size = 14, .color = colors.text }, "1:24", time, clip, .end);
    }
};

/// A floating face: glass of `material` over backdrop A, or the solid panel face.
fn floating(cx: anytype, rect: Rect, clip: Clip, material: theme.Material, radius: f32) void {
    const scheme = cx.theme();
    if (material.glass() and kit.glass(cx, rect, clip, kit.glass_look(scheme, material, radius))) return;
    kit.face(cx, rect, clip, .{ .fill = scheme.colors.panel, .radius = radius });
}

/// Segment `index` of a bar whose top-left is `(x, y)` (section 3).
pub fn segment_rect(x: f32, y: f32, index: u32) Rect {
    assert(index < material_names.len);
    return .{
        .x = x + segment_inset + @as(f32, @floatFromInt(index)) * (segment_w + segment_gap),
        .y = y + segment_inset,
        .width = segment_w,
        .height = bar_h - 2 * segment_inset,
    };
}

/// Card `index` of a grid whose top-left is `(x, y)` (section 3).
pub fn card_rect(x: f32, y: f32, index: u32) Rect {
    assert(index < album_names.len);
    const column: f32 = @floatFromInt(index % columns);
    const row: f32 = @floatFromInt(index / columns);
    return .{
        .x = x + inset + column * (card_w + card_gap),
        .y = y + inset + row * (card_h + card_gap),
        .width = card_w,
        .height = card_h,
    };
}

/// Text on `layer`, restoring the caller's.
fn ink(cx: anytype, layer: quads.Layer, style: text.Style, words: []const u8, rect: Rect, clip: Clip, align_x: text.Align) void {
    const previous = cx.drawing().layer(layer);
    defer _ = cx.drawing().layer(previous);
    kit.label(cx, style, words, rect, clip, .{ .align_x = align_x, .align_y = .center, .ellipsis = false });
}

/// `a`'s rgb `t` of the way to `b`'s; `a`'s alpha.
fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    assert(t >= 0 and t <= 1);
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] };
}

/// `color` at alpha `a`.
fn alpha(color: [4]f32, a: f32) [4]f32 {
    assert(a >= 0 and a <= 1);
    return .{ color[0], color[1], color[2], a };
}

// Locks the grid and the bar (section 3): card 0 at (16, 16) of the grid, card 5 one column and
// row on, card 15 ending 16 inside the 1232 px content; the segments 93 x 32, 4 inside the bar.
test "the cards and segments sit where section 3 puts them" {
    try std.testing.expectEqual(Rect{ .x = 16, .y = 16, .width = 282, .height = 200 }, card_rect(0, 0, 0));
    try std.testing.expectEqual(Rect{ .x = 322, .y = 240, .width = 282, .height = 200 }, card_rect(0, 0, 5));
    const last = card_rect(0, 0, 15);
    try std.testing.expectEqual(@as(f32, 1232 - 16), last.x + last.width);
    try std.testing.expectEqual(Rect{ .x = 4, .y = 4, .width = 93, .height = 32 }, segment_rect(0, 0, 0));
    try std.testing.expectEqual(bar_w - segment_inset, segment_rect(0, 0, 3).x + segment_w);
}

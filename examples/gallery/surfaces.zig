//! The gallery's surfaces page (step 39): `draw.Surface` gradients, rims, and shadows.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Shows
//! A music-player-like screen built from `kit.surface` alone: a faint gradient backdrop, a
//! glass-like side panel (a translucent fill, a rim-lit border, a shadow, and no blur, which
//! step 40 adds), a floating pill bar with one selected pill, and six cards. Each card is two
//! surfaces, a diagonal gradient between two muted colours and a radial highlight that fades to
//! transparent, plus a rim-lit label pill.
//!
//! ## 1b. Colours
//! Every colour comes from the app's scheme (`Palette.of(cx.theme())`), so the page follows the
//! gallery's light toggle. A scheme whose background is lighter than mid grey is light.
//! ```text
//!                  dark                               light
//! backdrop         background 25% toward darken,      background 50% toward lighten,
//!                  then 10% toward focus              then 6% toward focus
//! glass            text at 6%, border text at 14%     lighten at 60%, border text at 10%
//! shadows          alpha 0.40                         alpha 0.12
//! cards            the muted stops as they are        the stops 72% toward lighten
//! highlight        lighten at 8%                      lighten at 50%
//! label pills      text at 10%, border text at 20%    lighten at 55%, border text at 12%
//! selected row     text at 10%                        text at 7%
//! selected pill    focus to focus 18% toward darken, its label in lighten
//! hover face       text at 7% times the hover         text at 5% times the hover
//! text             the scheme's text
//! ```
//!
//! ## 1a. Interaction
//! The pills, the panel's rows, and the cards are clickable. Each has a `kit.Interaction` (hover
//! and press animators) and an area with the pointer cursor; `Page.handle` aims the animators
//! from the hit, steps them on `.frame`, and reports a click: a pill or a row becomes the
//! selection, a card is named on the status line. A surface has no hover or press weights, so
//! the selected pill and row and every card's gradient go through `kit.lit` before
//! `kit.surface`, lighting and darkening as a `Box` face does; an unselected pill or row shows
//! its hover as a faint face whose alpha follows the hover animator, and draws nothing
//! at rest, so the page at rest is the page without interaction.
//!
//! ## 2. Layout (logical pixels, from the page's top-left)
//! ```text
//! page      the tab page, 1248 x 584 at (16, 104); the backdrop fills it, radius 12
//! panel     (16, 16), 264 wide, 16 above the bottom; radius 20; title and five rows
//! content   from x 304 to 16 before the right edge: 928 wide
//! pills     392 x 40, centred over the content at y 16; four pills of 93 x 32, 4 apart and
//!           4 inside the bar on every side
//! heading   y 72, 40 high
//! cards     3 x 2 of 288 x 180 from y 128, 32 apart across and 24 down
//! ```
//!
//! ## 3. Draw Order
//! Within a layer a type's batch draws where its first instance appeared, and the title bar
//! has already put `Glyph` first in the base layer. The page appends its surfaces on
//! `face_layer` and its text on `ink_layer`, then restores the caller's layer, as the hardware
//! skin does.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;

const Rect = quads.Rect;
const Clip = quads.Clip;

const face_layer: quads.Layer = @fromBackingInt(1);
const ink_layer: quads.Layer = @fromBackingInt(2);

pub const inset: f32 = 16;
pub const panel_w: f32 = 264;
pub const content_gap: f32 = 24;
pub const pill_bar_w: f32 = 392;
pub const pill_bar_h: f32 = 40;
/// The pills' inset from the bar's edges and the gap between two pills.
pub const pill_inset: f32 = 4;
pub const pill_gap: f32 = 4;
/// The bar's inner width shared by the pills and their gaps: 93.
pub const pill_w: f32 = (pill_bar_w - 2 * pill_inset - (pill_names.len - 1) * pill_gap) / pill_names.len;

comptime {
    assert(pill_w == 93);
    assert(pill_w == @floor(pill_w));
}

/// Pill `index` of a bar whose top-left is `(x, y)`; section 2.
pub fn pill_rect(x: f32, y: f32, index: u32) Rect {
    assert(index < pill_names.len);
    return .{
        .x = x + pill_inset + @as(f32, @floatFromInt(index)) * (pill_w + pill_gap),
        .y = y + pill_inset,
        .width = pill_w,
        .height = pill_bar_h - 2 * pill_inset,
    };
}
pub const heading_y: f32 = 72;
pub const heading_h: f32 = 40;
pub const cards_y: f32 = 128;
pub const card_w: f32 = 288;
pub const card_h: f32 = 180;
pub const card_gap_x: f32 = 32;
pub const card_gap_y: f32 = 24;
pub const columns: u32 = 3;
pub const label_h: f32 = 30;
pub const row_h: f32 = 32;
pub const row_radius: f32 = 8;
pub const card_radius: f32 = 18;

const glass_offset: [2]f32 = .{ 0, 8 };
const glass_blur: f32 = 24;
const card_offset: [2]f32 = .{ 0, 6 };
const card_blur: f32 = 16;

/// A card: its name and its gradient's two stops as the dark scheme draws them.
const Card = struct {
    name: []const u8,
    from: [4]f32,
    to: [4]f32,
};

/// An opaque colour from 8-bit channels.
fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) [4]f32 {
    return .{ @as(f32, r) / 255, @as(f32, g) / 255, @as(f32, b) / 255, 1 };
}

pub const cards = [_]Card{
    .{ .name = "Slate", .from = rgb(0x3b, 0x4a, 0x5c), .to = rgb(0x2c, 0x36, 0x44) },
    .{ .name = "Moss", .from = rgb(0x3f, 0x52, 0x46), .to = rgb(0x2e, 0x3c, 0x33) },
    .{ .name = "Plum", .from = rgb(0x4e, 0x3f, 0x57), .to = rgb(0x3a, 0x2f, 0x42) },
    .{ .name = "Clay", .from = rgb(0x5c, 0x46, 0x3c), .to = rgb(0x45, 0x34, 0x2c) },
    .{ .name = "Steel", .from = rgb(0x3d, 0x4f, 0x63), .to = rgb(0x2d, 0x3b, 0x4a) },
    .{ .name = "Ink", .from = rgb(0x33, 0x3a, 0x4a), .to = rgb(0x26, 0x2b, 0x37) },
};

/// The page's colours, derived from a scheme (section 1b).
pub const Palette = struct {
    text: [4]f32,
    on_accent: [4]f32,
    backdrop_from: [4]f32,
    backdrop_to: [4]f32,
    glass_fill: [4]f32,
    glass_border: [4]f32,
    shade: f32,
    accent_from: [4]f32,
    accent_to: [4]f32,
    highlight: [4]f32,
    label_fill: [4]f32,
    label_border: [4]f32,
    selected: [4]f32,
    hover: [4]f32,
    /// How far a card's stops move toward `lighten`: 0 in a dark scheme.
    tint: f32,
    lighten: [4]f32,

    pub fn of(scheme: *const patchwork.theme.Scheme) Palette {
        const colors = scheme.colors;
        const background = colors.background;
        const luminance = 0.2126 * background[0] + 0.7152 * background[1] + 0.0722 * background[2];
        const light = luminance > 0.5;
        const from = mix(background, if (light) colors.lighten else colors.darken, if (light) 0.5 else 0.25);
        const palette: Palette = .{
            .text = colors.text,
            .on_accent = colors.lighten,
            .backdrop_from = from,
            .backdrop_to = mix(from, colors.focus, if (light) 0.06 else 0.10),
            .glass_fill = if (light) alpha(colors.lighten, 0.6) else alpha(colors.text, 0.06),
            .glass_border = alpha(colors.text, if (light) 0.10 else 0.14),
            .shade = if (light) 0.12 else 0.40,
            .accent_from = colors.focus,
            .accent_to = mix(colors.focus, colors.darken, 0.18),
            .highlight = alpha(colors.lighten, if (light) 0.5 else 0.08),
            .label_fill = if (light) alpha(colors.lighten, 0.55) else alpha(colors.text, 0.10),
            .label_border = alpha(colors.text, if (light) 0.12 else 0.20),
            .selected = alpha(colors.text, if (light) 0.07 else 0.10),
            .hover = alpha(colors.text, if (light) 0.05 else 0.07),
            .tint = if (light) 0.72 else 0,
            .lighten = colors.lighten,
        };
        assert(palette.shade > 0);
        assert(palette.tint >= 0 and palette.tint < 1);
        return palette;
    }

    /// A card's stop in this palette: as it is in a dark scheme, tinted in a light one.
    fn stop(self: Palette, color: [4]f32) [4]f32 {
        return mix(color, self.lighten, self.tint);
    }

    fn shadow(self: Palette, offset: [2]f32, blur: f32) quads.Shadow {
        return .{ .offset = offset, .blur = blur, .alpha = self.shade };
    }
};

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

pub const pill_names = [_][]const u8{ "Today", "Library", "Radio", "More" };
pub const row_names = [_][]const u8{ "Listen now", "Browse", "Playlists", "Artists", "Albums" };
const pill_start: u32 = 1;
const row_start: u32 = 0;

pub const pill_id = ui.id("surface_pill", 0);
pub const row_id = ui.id("surface_row", 0);
pub const card_id = ui.id("surface_card", 0);
const button_flags: ui.Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .pointer };

/// What a click on the page did.
pub const Report = union(enum) {
    pill: u32,
    row: u32,
    card: u32,
};

/// The page's state: the selections and every clickable's animators (section 1a).
pub const Page = struct {
    pill: u32,
    row: u32,
    pills: [pill_names.len]kit.Interaction,
    rows: [row_names.len]kit.Interaction,
    cards: [cards.len]kit.Interaction,

    pub fn init(self: *Page) void {
        self.pill = pill_start;
        self.row = row_start;
        for (&self.pills) |*item| item.* = interaction();
        for (&self.rows) |*item| item.* = interaction();
        for (&self.cards) |*item| item.* = interaction();
        assert(self.pill < pill_names.len);
        assert(self.row < row_names.len);
    }

    /// Steps the animators on `.frame`; otherwise aims them from each hit and reports a click
    /// (an inside release). A click on a pill or a row also selects it.
    pub fn handle(self: *Page, cx: anytype, event: patchwork.input.Event) ?Report {
        if (event == .frame) {
            for (&self.pills) |*item| item.frame(cx, event.frame);
            for (&self.rows) |*item| item.frame(cx, event.frame);
            for (&self.cards) |*item| item.frame(cx, event.frame);
            return null;
        }
        var report: ?Report = null;
        for (&self.pills, 0..) |*item, index| {
            if (clicked(cx, item, pill_id.derive(index), event)) {
                if (self.pill != index) cx.redraw();
                self.pill = @intCast(index);
                report = .{ .pill = @intCast(index) };
            }
        }
        for (&self.rows, 0..) |*item, index| {
            if (clicked(cx, item, row_id.derive(index), event)) {
                if (self.row != index) cx.redraw();
                self.row = @intCast(index);
                report = .{ .row = @intCast(index) };
            }
        }
        for (&self.cards, 0..) |*item, index| {
            if (clicked(cx, item, card_id.derive(index), event)) report = .{ .card = @intCast(index) };
        }
        return report;
    }

    /// Fills the rest of the current container with the page. See the module guide.
    pub fn draw(self: *const Page, cx: anytype) void {
        draw_page(self, cx);
    }
};

fn interaction() kit.Interaction {
    return kit.Interaction.init(kit.hover_rate_per_ms, kit.down_rate_per_ms);
}

/// Aims `item` from the hit on `id` and returns true on an inside release.
fn clicked(cx: anytype, item: *kit.Interaction, id: ui.Id, event: patchwork.input.Event) bool {
    const hit = cx.hit(id, event);
    item.react(cx, hit);
    return hit == .up and hit.up.inside;
}

/// The look of a selected pill or row, lit by its animators.
fn lit(cx: anytype, look: kit.SurfaceLook, item: *const kit.Interaction) kit.SurfaceLook {
    return kit.lit(look, cx.theme(), item.hover.value, item.down_value());
}

/// The faint face an unselected pill or row shows while hovered; nothing at rest.
fn hover_face(cx: anytype, colors: Palette, rect: Rect, clip: Clip, radius: f32, item: *const kit.Interaction) void {
    const amount = item.hover.value;
    if (amount <= 0) return;
    kit.surface(cx, rect, clip, .{ .fill = alpha(colors.hover, colors.hover[3] * amount), .radius = radius });
}

/// The rect of card `index` on a page whose top-left is `(x, y)`; section 2.
pub fn card_rect(x: f32, y: f32, index: u32) Rect {
    assert(index < cards.len);
    const column: f32 = @floatFromInt(index % columns);
    const row: f32 = @floatFromInt(index / columns);
    const content_x = x + inset + panel_w + content_gap;
    return .{
        .x = content_x + column * (card_w + card_gap_x),
        .y = y + cards_y + row * (card_h + card_gap_y),
        .width = card_w,
        .height = card_h,
    };
}

fn draw_page(self: *const Page, cx: anytype) void {
    const page = cx.walk(ui.sized(.fill, .fill));
    const clip = cx.visible(page) orelse return;
    const previous = cx.drawing().layer(face_layer);
    defer _ = cx.drawing().layer(previous);
    const colors = Palette.of(cx.theme());
    kit.surface(cx, page, clip, .{
        .fill = colors.backdrop_from,
        .fill_to = colors.backdrop_to,
        .gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } },
        .radius = 12,
    });
    draw_panel(self, cx, colors, page, clip);
    const content_x = page.x + inset + panel_w + content_gap;
    const content_w = page.x + page.width - inset - content_x;
    draw_pills(self, cx, colors, content_x + (content_w - pill_bar_w) * 0.5, page.y + inset, clip);
    const heading: Rect = .{ .x = content_x, .y = page.y + heading_y, .width = content_w, .height = heading_h };
    ink(cx, .{ .face = .sans_bold, .size = 28, .color = colors.text }, "Good evening", heading, clip, .start);
    for (0..cards.len) |index| {
        draw_card(cx, colors, card_rect(page.x, page.y, @intCast(index)), cards[index], clip, &self.cards[index]);
        cx.area(card_id.derive(index), card_rect(page.x, page.y, @intCast(index)), card_radius, button_flags);
    }
}

/// The glass-like side panel: title and rows, the selected one lit, the others hover faces.
fn draw_panel(self: *const Page, cx: anytype, colors: Palette, page: Rect, clip: Clip) void {
    const panel: Rect = .{
        .x = page.x + inset,
        .y = page.y + inset,
        .width = panel_w,
        .height = page.height - 2 * inset,
    };
    kit.surface(cx, panel, clip, glass(colors, 20));
    const title: Rect = .{ .x = panel.x + 16, .y = panel.y + 12, .width = panel_w - 32, .height = 36 };
    ink(cx, .{ .face = .sans, .size = 22, .color = colors.text }, "Library", title, clip, .start);
    for (row_names, 0..) |name, index| {
        const row: Rect = .{
            .x = panel.x + 8,
            .y = panel.y + 60 + @as(f32, @floatFromInt(index)) * row_h,
            .width = panel_w - 16,
            .height = row_h - 4,
        };
        const item = &self.rows[index];
        if (index == self.row) {
            kit.surface(cx, row, clip, lit(cx, .{ .fill = colors.selected, .radius = row_radius }, item));
        } else {
            hover_face(cx, colors, row, clip, row_radius, item);
        }
        cx.area(row_id.derive(index), row, row_radius, button_flags);
        const words = ui.cx.inset(row, .xy(12, 0));
        ink(cx, .{ .face = .sans, .size = 14, .color = colors.text }, name, words, clip, .start);
    }
}

/// The floating pill bar at `(x, y)`: four pills, the selected one in the scheme's focus blue.
fn draw_pills(self: *const Page, cx: anytype, colors: Palette, x: f32, y: f32, clip: Clip) void {
    const bar: Rect = .{ .x = x, .y = y, .width = pill_bar_w, .height = pill_bar_h };
    kit.surface(cx, bar, clip, glass(colors, pill_bar_h * 0.5));
    for (pill_names, 0..) |name, index| {
        const pill = pill_rect(x, y, @intCast(index));
        const item = &self.pills[index];
        const selected = index == self.pill;
        if (selected) {
            kit.surface(cx, pill, clip, lit(cx, .{
                .fill = colors.accent_from,
                .fill_to = colors.accent_to,
                .radius = pill.height * 0.5,
                .border = alpha(colors.on_accent, 0.25),
                .border_width = 1,
                .rim = 0.5,
            }, item));
        } else {
            hover_face(cx, colors, pill, clip, pill.height * 0.5, item);
        }
        cx.area(pill_id.derive(index), pill, pill.height * 0.5, button_flags);
        const color = if (selected) colors.on_accent else colors.text;
        ink(cx, .{ .face = .sans, .size = 14, .color = color }, name, pill, clip, .center);
    }
}

/// One card: its gradient (lit by `item`), its highlight, and its label pill.
fn draw_card(cx: anytype, colors: Palette, rect: Rect, card: Card, clip: Clip, item: *const kit.Interaction) void {
    kit.surface(cx, rect, clip, lit(cx, .{
        .fill = colors.stop(card.from),
        .fill_to = colors.stop(card.to),
        .gradient = .{ .linear = .{ .from = .{ 0, 0 }, .to = .{ 1, 1 } } },
        .radius = card_radius,
        .shadow = colors.shadow(card_offset, card_blur),
    }, item));
    kit.surface(cx, rect, clip, .{
        .fill = colors.highlight,
        .fill_to = alpha(colors.highlight, 0),
        .gradient = .{ .radial = .{ .center = .{ 0.8, 0.15 }, .radius = .{ 0.6, 0.8 } } },
        .radius = card_radius,
    });
    const style: text.Style = .{ .face = .sans, .size = 14, .color = colors.text };
    const label_w = @ceil(text.measure(style, card.name)) + 24;
    const label: Rect = .{ .x = rect.x + 12, .y = rect.y + rect.height - label_h - 12, .width = label_w, .height = label_h };
    kit.surface(cx, label, clip, .{
        .fill = colors.label_fill,
        .radius = label_h * 0.5,
        .border = colors.label_border,
        .border_width = 1,
        .rim = 0.4,
    });
    ink(cx, style, card.name, label, clip, .center);
}

/// The glass look without blur: a translucent fill, a rim-lit border, and a shadow.
fn glass(colors: Palette, radius: f32) kit.SurfaceLook {
    assert(radius > 0);
    return .{
        .fill = colors.glass_fill,
        .radius = radius,
        .border = colors.glass_border,
        .border_width = 1,
        .rim = 0.5,
        .shadow = colors.shadow(glass_offset, glass_blur),
    };
}

/// Text on `ink_layer`, over every surface of the page.
fn ink(cx: anytype, style: text.Style, words: []const u8, rect: Rect, clip: Clip, align_x: text.Align) void {
    const previous = cx.drawing().layer(ink_layer);
    defer _ = cx.drawing().layer(previous);
    kit.label(cx, style, words, rect, clip, .{ .align_x = align_x, .align_y = .center, .ellipsis = false });
}

// Locks the card grid (section 2): on the page at (16, 104), card 0 is at (320, 232), card 2 at
// (960, 232), card 3 at (320, 436); three cards and two gaps fill the 928 px content exactly,
// so the last card's right edge is the page's inset, 1248.
test "the cards tile the content area" {
    try std.testing.expectEqual(Rect{ .x = 320, .y = 232, .width = 288, .height = 180 }, card_rect(16, 104, 0));
    try std.testing.expectEqual(@as(f32, 960), card_rect(16, 104, 2).x);
    try std.testing.expectEqual(@as(f32, 436), card_rect(16, 104, 3).y);
    const last = card_rect(16, 104, 5);
    try std.testing.expectEqual(@as(f32, 16 + 1248 - 16), last.x + last.width);
}

// Locks the pill bar (section 2): the pills sit 4 inside the 392 x 40 bar on every side and 4
// apart, so the first starts at 4, the last ends at 388, and each is 93 x 32.
test "the pills are inset evenly in their bar" {
    const first = pill_rect(0, 0, 0);
    const last = pill_rect(0, 0, pill_names.len - 1);
    try std.testing.expectEqual(Rect{ .x = 4, .y = 4, .width = 93, .height = 32 }, first);
    try std.testing.expectEqual(pill_bar_w - pill_inset, last.x + last.width);
    try std.testing.expectEqual(pill_bar_h - pill_inset, last.y + last.height);
    try std.testing.expectEqual(pill_gap, pill_rect(0, 0, 1).x - (first.x + first.width));
}

// Locks the palette (section 1b): the dark scheme keeps the muted card stops and shades at 0.40
// with its backdrop below the window's background; the light scheme tints the stops 72% toward
// white, shades at 0.12, and lifts its backdrop above its background; both draw text in the
// scheme's text colour and the selected pill in its focus colour.
test "the palette follows the scheme" {
    const theme = patchwork.theme;
    const dark = Palette.of(&theme.dark);
    try std.testing.expectEqual(@as(f32, 0.40), dark.shade);
    try std.testing.expectEqual(cards[0].from, dark.stop(cards[0].from));
    try std.testing.expect(dark.backdrop_from[2] < theme.dark.colors.background[2]);
    try std.testing.expectEqual(theme.dark.colors.text, dark.text);
    try std.testing.expectEqual(theme.dark.colors.focus, dark.accent_from);
    const light = Palette.of(&theme.light);
    try std.testing.expectEqual(@as(f32, 0.12), light.shade);
    const tinted = light.stop(cards[0].from);
    try std.testing.expectApproxEqAbs(cards[0].from[0] + (1 - cards[0].from[0]) * 0.72, tinted[0], 1e-6);
    try std.testing.expect(light.backdrop_from[1] > theme.light.colors.background[1]);
    try std.testing.expectEqual(theme.light.colors.text, light.text);
}

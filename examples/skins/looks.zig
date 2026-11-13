//! The four looks: what each one is as values, and the two skin types that draw all four.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Look Is Mostly a Scheme
//! `Look` is a `theme.Scheme` plus what the scheme cannot say: the title's, the status line's,
//! the toolbar buttons', and the objects' text styles, the objects' fill, how accent buttons
//! show their colour, three cable colours and which of them are solid, the ground behind
//! everything, and the decorations one look adds. `all` holds Paper, Codex, Patch, and HUD, in
//! the switcher's order. The scheme carries the colours, the three text styles (`name`,
//! `value`, `heading` with its `tracking`), and the form: corner radii, `capsule`, `hairline`,
//! `mark`, filled or outlined controls, the tab mark, and framed panels. `skins.Default` reads
//! all of it, so the tabs, panels, toggles, checkboxes, dropdown, number box, and text field
//! follow a switch with no code of the app's.
//!
//! ## 2. One Skin for Four Schemes
//! A skin is a type, picked at compile time (`KnobOf(Skin)`); a scheme is a value, read at
//! draw time. Every function here reads `cx.theme()` and its look on every call and keeps
//! nothing, so after `cx.set_theme` the same functions draw the next look on the next frame.
//! They read only what a scheme carries and what the app stored in the widget (a button's
//! paint and label style, a box's accent paint), so under `theme.dark` the same skins round and
//! fill. A look's own ornaments (HUD's viewport brackets, the object ports of Paper and Codex,
//! the patch panel's opacity) are the app's, which knows the look (`Look.decor`, `app.zig` section
//! 4). Guessing the look from a colour would break the day a colour is tuned.
//!
//! ## 3. What `Skin` Draws (parameter cells, meters, headers, the card, the slider)
//! ```text
//! knob        a parameter cell: the name in name, the value text under it in value, and an
//!             underline form.mark high: colors.track across, colors.value over value * width,
//!             lit by hover. Filled forms give the cell a face in colors.track, flush bar at
//!             its bottom; outlined forms draw no face and inset the underline. The cell,
//!             rounded by radius.control, is the hit shape.
//! meter       a bar across the row, rounded by height * capsule, framed forms with a hairline:
//!             colors.track, the level in colors.meter up to meter_threshold over accents[1]
//!             past it, a one-pixel tick at the threshold. The name (heading) at the left and
//!             the percent (value) at the right, inside the bar; over the fill the text takes
//!             whichever of colors.background and colors.text (dimmed) differs more from it.
//! disclosure  a form.mark-wide chevron, the label in heading, and a hairline rule in
//!             colors.control from past the label to the header's end. A label "TITLE\tright"
//!             puts "right" at the header's end in name, and the rule stops before it.
//! tooltip     a card (fill or colors.panel, a hairline in colors.control, radius.popup). A
//!             label "CAPTION\ntitle\nline" puts the caption (heading's face, in name's
//!             colour) and the title (sans bold, title_size, colors.text) on one line and the
//!             line under them in name; a label without "\n" is one centred title.
//! slider      a thin track and fill (slider_line high, the app's paints) and a small dot of
//!             slider_dot_r in the knob paint's colour; the travel is the track.
//! ```
//!
//! ## 3a. What `Object` Draws (the patch's boxes, the object and toolbar buttons)
//! ```text
//! knob        an object box: a face in the box's accent paint (the app's object fill), a
//!             hairline in colors.control when controls are outlined, "name value" on one line
//!             in value at object_size, and the value as a bar along the bottom edge,
//!             form.mark + 1 high, in colors.value, lit by hover. The box is the hit shape.
//! button      a face in the paint, rounded by its radius, lit and pressed; outlined forms give
//!             it a hairline in the label's colour at button_edge_alpha; the label centred.
//! ```
//! `meter_threshold` is the skin's constant, since `MeterLook` carries no threshold.
//!
//! ## 4. TigerStyle Invariants
//! - Skin functions are stateless; text is formatted into stack buffers.
//! - Every look passes `theme.problem` and keeps its background off 8-bit rounding ties
//!   (`theme.zig`, section 5), checked at compile time.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const widgets = patchwork.widgets;
const kit = widgets.kit;

const Rect = quads.Rect;
const Clip = quads.Clip;

/// What draws behind everything (`ground.zig`).
pub const Ground = enum(u8) { none, map, dots };

/// How an accent button shows its colour (`app.zig`, `restyle_button`).
pub const AccentButtons = enum(u8) {
    /// A face in the accent, its label in `colors.panel`.
    filled,
    /// A dark face tinted by the accent, its label and edge the accent lightened.
    tinted,
    /// The object face, its label in the accent.
    text,
};

/// What the app draws for one look only: the scheme cannot say it (section 2).
pub const Decor = struct {
    /// A small filled square on the top-right corner of each object button, in `port`.
    ports: bool = false,
    /// Thin brackets inside the corners of the patch viewport.
    brackets: bool = false,
};

pub const Look = struct {
    /// The switcher's label.
    name: []const u8,
    scheme: theme.Scheme,
    /// The title and the channel name.
    module: text.Style,
    /// The status line.
    caption: text.Style,
    /// The toolbar's and the accent row's labels: upper case, lightly spaced.
    button: text.Style,
    /// Object buttons' and list rows' labels.
    object: text.Style,
    /// The face of object boxes, object buttons, plain toolbar buttons, and list rows.
    object_fill: [4]f32,
    accent_buttons: AccentButtons,
    /// The object ports' colour (`decor.ports`).
    port: [4]f32,
    /// Cables 1, 2, and 3, and which are solid rather than dashed.
    cables: [3][4]f32,
    cables_solid: [3]bool,
    ground: Ground,
    /// The ground image's tint (`draw.Image.tint`) over its white ink.
    ground_tint: [4]f32,
    /// The patch panel's opacity: 1 a panel like the others, below 1 the ground shows through,
    /// 0 the ground is the patch's canvas.
    patch_alpha: f32,
    decor: Decor,
};

// ---------------------------------------------------------------------------- the looks

const square_outlined: theme.Form = .{
    .radius = .{ .control = 0, .popup = 0, .band = 0 },
    .capsule = 0,
    .hairline = 1,
    .mark = 2,
    .controls = .outlined,
    .tab_mark = .underline,
    .framed = true,
};

const ink = [4]f32{ 0.10, 0.10, 0.10, 1 };
const paper_grey = [4]f32{ 0.45, 0.45, 0.44, 1 };

pub const paper: Look = .{
    .name = "PAPER",
    .scheme = .{
        .colors = .{
            .background = .{ 0.86, 0.86, 0.84, 1 },
            .panel = .{ 0.89, 0.89, 0.87, 1 },
            .text = ink,
            .track = .{ 0.74, 0.74, 0.72, 1 },
            .value = .{ 0.22, 0.22, 0.22, 1 },
            .control = .{ 0.32, 0.32, 0.31, 1 },
            .meter = .{ 0.40, 0.40, 0.39, 1 },
            .focus = .{ 0, 0, 0, 1 },
            .selection = .{ 0.74, 0.74, 0.72, 1 },
            .lighten = .{ 1, 1, 1, 1 },
            .darken = .{ 0, 0, 0, 1 },
        },
        .accents = .{
            .{ 0.20, 0.20, 0.20, 1 },
            .{ 0.60, 0.18, 0.14, 1 },
            .{ 0.18, 0.40, 0.22, 1 },
            .{ 0.62, 0.32, 0.10, 1 },
        },
        .name = .{ .face = .sans, .size = 11, .color = paper_grey },
        .value = .{ .face = .sans, .size = 13, .color = .{ 0.25, 0.25, 0.25, 1 } },
        .heading = .{ .face = .sans_bold, .size = 11, .color = .{ 0.16, 0.16, 0.16, 1 }, .tracking = 0.16 },
        .hover_lighten = 0.10,
        .down_darken = 0.15,
        .form = blk: {
            var form = square_outlined;
            form.mark = 1;
            break :blk form;
        },
    },
    .module = .{ .face = .serif, .size = 18, .color = ink },
    .caption = .{ .face = .serif_italic, .size = 13, .color = .{ 0.30, 0.30, 0.29, 1 } },
    .button = .{ .face = .sans_medium, .size = 12, .color = ink, .tracking = 0.05 },
    .object = .{ .face = .sans, .size = 12, .color = .{ 0.20, 0.20, 0.20, 1 } },
    .object_fill = .{ 0.92, 0.92, 0.90, 1 },
    .accent_buttons = .filled,
    .port = ink,
    .cables = .{ ink, ink, ink },
    .cables_solid = .{ false, false, false },
    .ground = .map,
    .ground_tint = .{ 0.30, 0.30, 0.29, 0.22 },
    .patch_alpha = 0.6,
    .decor = .{ .ports = true },
};

const codex_text = [4]f32{ 0.86, 0.86, 0.84, 1 };
const codex_blue = [4]f32{ 0.32, 0.62, 0.90, 1 };

pub const codex: Look = .{
    .name = "CODEX",
    .scheme = .{
        .colors = .{
            .background = .{ 0.035, 0.035, 0.04, 1 },
            .panel = .{ 0.065, 0.065, 0.07, 1 },
            .text = codex_text,
            .track = .{ 0.19, 0.19, 0.20, 1 },
            .value = .{ 0.58, 0.58, 0.57, 1 },
            .control = .{ 0.24, 0.24, 0.25, 1 },
            .meter = .{ 0.46, 0.47, 0.46, 1 },
            .focus = codex_blue,
            .selection = .{ 0.12, 0.24, 0.34, 1 },
            .lighten = .{ 1, 1, 1, 1 },
            .darken = .{ 0, 0, 0, 1 },
        },
        .accents = .{
            codex_blue,
            .{ 0.92, 0.32, 0.30, 1 },
            .{ 0.40, 0.82, 0.45, 1 },
            .{ 0.96, 0.56, 0.20, 1 },
        },
        .name = .{ .face = .sans, .size = 11, .color = .{ 0.42, 0.42, 0.42, 1 } },
        .value = .{ .face = .sans, .size = 13, .color = .{ 0.80, 0.80, 0.78, 1 } },
        .heading = .{ .face = .sans_bold, .size = 11, .color = .{ 0.82, 0.82, 0.80, 1 }, .tracking = 0.18 },
        .hover_lighten = 0.18,
        .down_darken = 0.30,
        .form = blk: {
            var form = square_outlined;
            form.radius = .{ .control = 2, .popup = 4, .band = 2 };
            break :blk form;
        },
    },
    .module = .{ .face = .serif, .size = 18, .color = codex_text },
    .caption = .{ .face = .serif_italic, .size = 13, .color = .{ 0.52, 0.52, 0.52, 1 } },
    .button = .{ .face = .sans_medium, .size = 12, .color = codex_text, .tracking = 0.05 },
    .object = .{ .face = .sans, .size = 12, .color = .{ 0.84, 0.84, 0.82, 1 } },
    .object_fill = .{ 0.11, 0.11, 0.115, 1 },
    .accent_buttons = .tinted,
    .port = .{ 0.94, 0.94, 0.92, 1 },
    .cables = .{
        .{ 0.96, 0.56, 0.20, 1 },
        .{ 0.38, 0.56, 0.96, 1 },
        .{ 0.90, 0.90, 0.88, 1 },
    },
    .cables_solid = .{ false, false, false },
    .ground = .none,
    .ground_tint = .{ 0, 0, 0, 0 },
    .patch_alpha = 1,
    .decor = .{ .ports = true },
};

const mint = [4]f32{ 0.42, 0.85, 0.70, 1 };
const patch_grey = [4]f32{ 0.55, 0.58, 0.57, 1 };

pub const patch_look: Look = .{
    .name = "PATCH",
    .scheme = .{
        .colors = .{
            .background = .{ 0.035, 0.04, 0.04, 1 },
            .panel = .{ 0.06, 0.065, 0.065, 1 },
            .text = .{ 0.93, 0.94, 0.94, 1 },
            .track = .{ 0.17, 0.18, 0.18, 1 },
            .value = mint,
            .control = .{ 0.30, 0.32, 0.32, 1 },
            .meter = mint,
            .focus = .{ 0.62, 1.00, 0.86, 1 },
            .selection = .{ 0.14, 0.30, 0.27, 1 },
            .lighten = .{ 1, 1, 1, 1 },
            .darken = .{ 0, 0, 0, 1 },
        },
        .accents = .{
            mint,
            .{ 0.95, 0.40, 0.45, 1 },
            .{ 0.50, 0.90, 0.50, 1 },
            .{ 0.95, 0.76, 0.36, 1 },
        },
        .name = .{ .face = .mono, .size = 11, .color = patch_grey },
        .value = .{ .face = .mono, .size = 12, .color = mint },
        // The "PATCH" caption beside the card's title.
        .heading = .{ .face = .mono_bold, .size = 10, .color = patch_grey, .tracking = 0.2 },
        .hover_lighten = 0.15,
        .down_darken = 0.25,
        .form = .{
            .radius = .{ .control = 2, .popup = 6, .band = 2 },
            .capsule = 0.5,
            .hairline = 1,
            .mark = 2,
            .controls = .filled,
            .tab_mark = .underline,
            .framed = false,
        },
    },
    .module = .{ .face = .mono, .size = 13, .color = mint },
    .caption = .{ .face = .mono_light, .size = 12, .color = patch_grey },
    .button = .{ .face = .mono, .size = 11, .color = mint, .tracking = 0.05 },
    .object = .{ .face = .mono, .size = 12, .color = mint },
    .object_fill = .{ 0.17, 0.18, 0.18, 1 },
    .accent_buttons = .text,
    .port = mint,
    .cables = .{ .{ 0.42, 0.85, 0.70, 0.9 }, .{ 0.42, 0.85, 0.70, 0.9 }, .{ 0.42, 0.44, 0.44, 1 } },
    .cables_solid = .{ false, false, true },
    .ground = .dots,
    .ground_tint = .{ 0.55, 0.62, 0.60, 0.10 },
    .patch_alpha = 0,
    .decor = .{},
};

const hud_text = [4]f32{ 0.84, 0.88, 0.92, 1 };
const hud_cyan = [4]f32{ 0.38, 0.82, 0.90, 1 };
const hud_grey = [4]f32{ 0.52, 0.58, 0.64, 1 };

pub const hud: Look = .{
    .name = "HUD",
    .scheme = .{
        .colors = .{
            .background = .{ 0.04, 0.055, 0.08, 1 },
            .panel = .{ 0.06, 0.08, 0.11, 1 },
            .text = hud_text,
            .track = .{ 0.035, 0.05, 0.075, 1 },
            .value = hud_cyan,
            .control = .{ 0.18, 0.26, 0.32, 1 },
            .meter = .{ 0.20, 0.40, 0.44, 1 },
            .focus = hud_cyan,
            .selection = .{ 0.10, 0.24, 0.32, 1 },
            .lighten = .{ 1, 1, 1, 1 },
            .darken = .{ 0, 0, 0, 1 },
        },
        .accents = .{
            hud_cyan,
            .{ 0.52, 0.30, 0.16, 1 },
            .{ 0.40, 0.85, 0.50, 1 },
            .{ 0.95, 0.66, 0.25, 1 },
        },
        .name = .{ .face = .sans, .size = 12, .color = hud_grey },
        .value = .{ .face = .mono_light, .size = 13, .color = hud_text },
        .heading = .{ .face = .sans_bold, .size = 11, .color = .{ 0.45, 0.78, 0.85, 1 }, .tracking = 0.16 },
        .hover_lighten = 0.15,
        .down_darken = 0.30,
        .form = blk: {
            var form = square_outlined;
            form.radius = .{ .control = 0, .popup = 2, .band = 0 };
            form.tab_mark = .filled;
            break :blk form;
        },
    },
    .module = .{ .face = .sans_bold, .size = 16, .color = hud_text, .tracking = 0.12 },
    .caption = .{ .face = .mono_light, .size = 12, .color = hud_grey },
    .button = .{ .face = .sans, .size = 12, .color = hud_text, .tracking = 0.03 },
    .object = .{ .face = .sans, .size = 12, .color = hud_text },
    .object_fill = .{ 0.07, 0.095, 0.13, 1 },
    .accent_buttons = .tinted,
    .port = hud_cyan,
    .cables = .{ hud_cyan, .{ 0.95, 0.66, 0.25, 1 }, .{ 0.80, 0.86, 0.92, 1 } },
    .cables_solid = .{ false, false, false },
    .ground = .none,
    .ground_tint = .{ 0, 0, 0, 0 },
    .patch_alpha = 1,
    .decor = .{ .brackets = true },
};

/// The looks in the switcher's order: keys 1 to 4.
pub const all = [4]Look{ paper, codex, patch_look, hud };

/// True when no component of `color` lies within 0.01 of an 8-bit rounding tie.
pub fn off_ties(color: [4]f32) bool {
    for (color[0..3]) |component| {
        const scaled = component * 255;
        if (@abs(scaled - @floor(scaled) - 0.5) <= 0.01) return false;
    }
    return true;
}

comptime {
    for (all) |look| {
        assert(theme.problem(look.scheme) == null);
        assert(off_ties(look.scheme.colors.background));
        assert(look.name.len <= 8);
        assert(look.ground == .none or look.ground_tint[3] > 0);
        assert(look.patch_alpha >= 0 and look.patch_alpha <= 1);
    }
}

// ---------------------------------------------------------------------------- the skins

/// The meter's warning level: the fill past it is `accents[1]` (section 3).
pub const meter_threshold: f32 = 0.8;
/// The tooltip card's title size (section 3).
pub const title_size: f32 = 22;
/// Text inside a cell, a meter, or a card, from its left and right edges.
pub const inset_x: f32 = 6;
/// The gap between a disclosure label's extent and its rule.
pub const rule_gap: f32 = 8;
/// A cell's name line and the card's caption line, from the top.
const name_top: f32 = 3;
const name_h: f32 = 16;
/// The shortest cell the skin draws: a name line, a value line, and the bar.
pub const cell_h_min: f32 = 32;
/// The slider's line thickness and its dot's radius.
pub const slider_line: f32 = 2;
pub const slider_dot_r: f32 = 6;
/// An object box's text size.
pub const object_size: f32 = 12;
/// An outlined button's edge: its label's colour at this alpha.
pub const button_edge_alpha: f32 = 0.45;
/// A meter label's alpha over a dark fill.
const dim_alpha: f32 = 0.65;

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = false };
const centered: text.Options = .{ .align_x = .center, .align_y = .center, .ellipsis = false };

/// The skin of the parameter cells, the meters, the section headers, the tooltip, and the
/// slider (section 3). Every function reads `cx.theme()` and the look, nothing else.
pub const Skin = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        assert(look.value >= 0 and look.value <= 1);
        assert(look.row.width >= 0);
        if (look.row.height < cell_h_min) return null;
        const scheme = cx.theme();
        const form = &scheme.form;
        const hover = kit.weight(look.hover, scheme.hover_lighten);
        const filled = form.controls == .filled;
        if (filled) {
            kit.face(cx, look.row, look.clip, .{ .fill = scheme.colors.track, .radius = form.radius.control, .hover = hover });
        }
        const line = cell_line(look.row, form.mark, filled);
        kit.face(cx, line, look.clip, .{ .fill = if (filled) scheme.colors.panel else scheme.colors.track });
        var value_line = line;
        value_line.width = line.width * look.value;
        kit.face(cx, value_line, look.clip, .{ .fill = scheme.colors.value, .hover = hover });
        const inner = Rect{ .x = look.row.x + inset_x, .y = look.row.y, .width = look.row.width - 2 * inset_x, .height = look.row.height };
        if (inner.width > 0) {
            const name: Rect = .{ .x = inner.x, .y = inner.y + name_top, .width = inner.width, .height = name_h };
            kit.label(cx, scheme.name, look.name, name, look.clip, start);
            const top = name_top + name_h;
            const value: Rect = .{ .x = inner.x, .y = inner.y + top, .width = inner.width, .height = line.y - inner.y - top };
            kit.label(cx, scheme.value, look.value_text, value, look.clip, start);
        }
        return .{ .rect = look.row, .radius = form.radius.control };
    }

    pub fn meter(cx: anytype, look: widgets.MeterLook) void {
        assert(look.value >= 0 and look.value <= 1);
        assert(look.row.width >= 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const form = &scheme.form;
        const row = look.row;
        const radius = row.height * form.capsule;
        kit.face(cx, row, look.clip, .{
            .fill = colors.track,
            .border_color = colors.control,
            .border_width = if (form.framed) form.hairline else 0,
            .radius = radius,
        });
        const lit = meter_fill(row, look.value, radius);
        kit.face(cx, lit.past, look.clip, .{ .fill = scheme.accents[1], .radius = radius });
        kit.face(cx, lit.below, look.clip, .{ .fill = colors.meter, .radius = radius });
        const tick: Rect = .{ .x = row.x + meter_threshold * row.width, .y = row.y, .width = 1, .height = row.height };
        kit.face(cx, tick, look.clip, .{ .fill = colors.text });
        const split = row.x + look.value * row.width;
        const inner: Rect = .{ .x = row.x + inset_x, .y = row.y, .width = row.width - 2 * inset_x, .height = row.height };
        if (inner.width <= 0) return;
        const over = over_fill(scheme);
        var name = scheme.heading;
        name.color = with_alpha(colors.text, dim_alpha);
        split_label(cx, name, look.name, inner, look.clip, split, over, start);
        var digits: [8]u8 = undefined;
        const percent = percent_text(&digits, look.value);
        split_label(cx, scheme.value, percent, inner, look.clip, split, over, end);
    }

    pub fn disclosure(cx: anytype, look: widgets.DisclosureLook) ?widgets.Shape {
        assert(look.turn >= 0 and look.turn <= 1);
        assert(look.rect.width > 0);
        const scheme = cx.theme();
        const form = &scheme.form;
        const heading = scheme.heading;
        if (look.focused) {
            kit.face(cx, look.rect, look.clip, .{
                .fill = transparent_of(scheme.colors.focus),
                .border_color = scheme.colors.focus,
                .border_width = @max(form.hairline, 1),
                .radius = form.radius.control,
            });
        }
        const centre: [2]f32 = .{ look.rect.x + chevron_cell_w * 0.5, look.rect.y + look.rect.height * 0.5 };
        const points = kit.chevron_points(centre, chevron_half, look.turn);
        const hover = kit.weight(look.hover, scheme.hover_lighten);
        _ = kit.stroke(cx, &points, look.clip, mix(heading.color, scheme.colors.lighten, hover), form.mark);
        const parts = split_tab(look.label);
        const label: Rect = .{
            .x = look.rect.x + chevron_cell_w,
            .y = look.rect.y,
            .width = @max(0, look.rect.width - chevron_cell_w),
            .height = look.rect.height,
        };
        if (label.width > 0) kit.label(cx, heading, parts.left, label, look.clip, start);
        var rule_end = look.rect.x + look.rect.width;
        if (parts.right.len > 0 and label.width > 0) {
            kit.label(cx, scheme.name, parts.right, label, look.clip, end);
            rule_end -= @ceil(label_extent(scheme.name, parts.right) + rule_gap);
        }
        const rule_x = @ceil(label.x + label_extent(heading, parts.left) + rule_gap);
        const rule: Rect = .{
            .x = rule_x,
            .y = @floor(look.rect.y + look.rect.height * 0.5),
            .width = rule_end - rule_x,
            .height = form.hairline,
        };
        kit.face(cx, rule, look.clip, .{ .fill = scheme.colors.control });
        return .{ .rect = look.rect, .radius = form.radius.control };
    }

    pub fn tooltip(cx: anytype, look: widgets.TooltipLook) void {
        assert(look.label.len <= text.byte_cap);
        assert(look.clip.x1 > look.clip.x0);
        const scheme = cx.theme();
        const form = &scheme.form;
        kit.face(cx, look.rect, look.clip, .{
            .fill = look.fill orelse scheme.colors.panel,
            .border_color = scheme.colors.control,
            .border_width = form.hairline,
            .radius = form.radius.popup,
        });
        const title: text.Style = .{ .face = .sans_bold, .size = title_size, .color = scheme.colors.text };
        const inner: Rect = .{ .x = look.rect.x + 3 * inset_x, .y = look.rect.y, .width = look.rect.width - 6 * inset_x, .height = look.rect.height };
        if (inner.width <= 0) return;
        const lines = card_lines(look.label) orelse {
            kit.label(cx, title, look.label, look.rect, look.clip, centered);
            return;
        };
        var caption = scheme.heading;
        caption.color = scheme.name.color;
        const top: Rect = .{ .x = inner.x, .y = inner.y + 4, .width = inner.width, .height = title_size * 1.5 };
        kit.label(cx, caption, lines.caption, top, look.clip, start);
        var after = top;
        const shift = @ceil(label_extent(caption, lines.caption) + 2 * inset_x);
        after.x += shift;
        after.width = @max(0, after.width - shift);
        if (after.width > 0) kit.label(cx, title, lines.title, after, look.clip, start);
        var note = scheme.name;
        note.size = 13;
        const below: Rect = .{ .x = inner.x, .y = top.y + top.height, .width = inner.width, .height = inner.y + inner.height - top.y - top.height - 4 };
        if (below.height > 0) kit.label(cx, note, lines.note, below, look.clip, start);
    }

    pub fn slider(cx: anytype, look: widgets.SliderLook) ?widgets.Shape {
        assert(look.value >= 0 and look.value <= 1);
        assert(look.rect.width > 2 * slider_dot_r);
        const scheme = cx.theme();
        const hover = kit.weight(look.hover, scheme.hover_lighten);
        const track: Rect = .{
            .x = look.rect.x + slider_dot_r,
            .y = look.rect.y + (look.rect.height - slider_line) * 0.5,
            .width = look.rect.width - 2 * slider_dot_r,
            .height = slider_line,
        };
        kit.face(cx, track, look.clip, look.track.look(scheme, 0, 0));
        var fill = track;
        fill.width = track.width * look.value;
        kit.face(cx, fill, look.clip, look.fill.look(scheme, 0, 0));
        const centre_x = track.x + fill.width;
        const dot: Rect = .{
            .x = centre_x - slider_dot_r,
            .y = look.rect.y + look.rect.height * 0.5 - slider_dot_r,
            .width = 2 * slider_dot_r,
            .height = 2 * slider_dot_r,
        };
        const k = look.knob;
        kit.face(cx, dot, look.clip, .{ .fill = .{ k.r, k.g, k.b, k.a }, .radius = slider_dot_r, .hover = hover });
        return .{ .rect = look.rect, .radius = 0 };
    }

    pub fn slider_travel(area: Rect) [2]f32 {
        assert(area.width > 2 * slider_dot_r);
        const travel: [2]f32 = .{ area.x + slider_dot_r, area.x + area.width - slider_dot_r };
        assert(travel[1] > travel[0]);
        return travel;
    }
};

/// The skin of the patch's object boxes and of the object and toolbar buttons (section 3a).
pub const Object = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        assert(look.value >= 0 and look.value <= 1);
        assert(look.row.width >= 0);
        if (look.row.height < 2 * object_size) return null;
        const scheme = cx.theme();
        const form = &scheme.form;
        const hover = kit.weight(look.hover, scheme.hover_lighten);
        const a = look.accent;
        kit.face(cx, look.row, look.clip, .{
            .fill = .{ a.r, a.g, a.b, a.a },
            .border_color = scheme.colors.control,
            .border_width = if (form.controls == .outlined) form.hairline else 0,
            .radius = form.radius.control,
            .hover = hover,
        });
        const bar_h = form.mark + 1;
        const bar: Rect = .{ .x = look.row.x, .y = look.row.y + look.row.height - bar_h, .width = look.row.width * look.value, .height = bar_h };
        kit.face(cx, bar, look.clip, .{ .fill = scheme.colors.value, .hover = hover });
        var bytes: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&bytes, "{s} {s}", .{ look.name, look.value_text }) catch look.name;
        var style = scheme.value;
        style.size = object_size;
        const inner: Rect = .{ .x = look.row.x + inset_x, .y = look.row.y, .width = look.row.width - 2 * inset_x, .height = look.row.height - bar_h };
        if (inner.width > 0) kit.label(cx, style, line, inner, look.clip, start);
        return .{ .rect = look.row, .radius = form.radius.control };
    }

    pub fn button(cx: anytype, look: widgets.ButtonLook) ?widgets.Shape {
        assert(look.paint.radius >= 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const p = look.paint;
        const outlined = scheme.form.controls == .outlined;
        kit.face(cx, look.rect, look.clip, .{
            .fill = .{ p.r, p.g, p.b, p.a },
            .border_color = with_alpha(look.style.color, button_edge_alpha),
            .border_width = if (outlined) scheme.form.hairline else 0,
            .radius = p.radius,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
            .down = kit.weight(look.down, scheme.down_darken),
        });
        const inner = patchwork.ui.cx.inset(look.rect, look.padding);
        kit.label(cx, look.style, look.label, inner, look.clip, centered);
        return .{ .rect = look.rect, .radius = p.radius };
    }
};

/// The chevron's cell at the header's left, as the default skin's, and its half length.
const chevron_cell_w: f32 = 24;
const chevron_half: f32 = 4;

/// A cell's underline (section 3): flush along the bottom of a filled cell, inset under the
/// value of an outlined one.
pub fn cell_line(row: Rect, mark: f32, filled: bool) Rect {
    assert(mark > 0);
    assert(row.height >= mark);
    const inset: f32 = if (filled) 0 else inset_x;
    const lift: f32 = if (filled) 0 else 4;
    const line: Rect = .{ .x = row.x + inset, .y = row.y + row.height - mark - lift, .width = row.width - 2 * inset, .height = mark };
    assert(line.width <= row.width);
    return line;
}

/// The meter's fill below the threshold and past it.
pub const MeterFill = struct { below: Rect, past: Rect };

/// The part past the threshold reaches `radius` back under the part below it, which draws
/// over it, so a rounded bar changes colour at the rounded end of the part below, not at a gap.
pub fn meter_fill(row: Rect, value: f32, radius: f32) MeterFill {
    assert(value >= 0 and value <= 1);
    assert(radius >= 0);
    var below = row;
    below.width = @min(value, meter_threshold) * row.width;
    var past = row;
    past.width = @max(0, value - meter_threshold) * row.width;
    if (past.width > 0) past.width += radius;
    past.x = row.x + meter_threshold * row.width - (if (past.width > 0) radius else 0);
    assert(below.width <= row.width);
    assert(past.x + past.width <= row.x + row.width + 1e-3);
    return .{ .below = below, .past = past };
}

/// The colour of text over the meter's fill: whichever of the background and the text (dimmed)
/// lies further from the fill in luma.
pub fn over_fill(scheme: *const theme.Scheme) [4]f32 {
    const colors = &scheme.colors;
    const fill = luma(colors.meter);
    const from_background = @abs(luma(colors.background) - fill);
    const from_text = @abs(luma(colors.text) - fill);
    assert(fill >= 0);
    if (from_background >= from_text) return colors.background;
    return with_alpha(colors.text, dim_alpha);
}

fn luma(color: [4]f32) f32 {
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2];
}

/// `value` in `[0, 1]` as a whole percent, "72%".
pub fn percent_text(out: *[8]u8, value: f32) []const u8 {
    assert(value >= 0 and value <= 1);
    const percent: u32 = @intFromFloat(@round(value * 100));
    const shown = std.fmt.bufPrint(out, "{d}%", .{percent}) catch unreachable;
    assert(shown.len >= 2);
    return shown;
}

/// Where `bytes` in `style` ends on screen: its measure less the hanging gap (step 64).
pub fn label_extent(style: text.Style, bytes: []const u8) f32 {
    if (bytes.len == 0) return 0;
    const extent = text.measure(style, bytes) - text.tracking_px(style);
    assert(extent >= 0);
    return extent;
}

/// A header label split at its tab: the title, and what goes at the header's end.
pub const TabParts = struct { left: []const u8, right: []const u8 };

pub fn split_tab(label: []const u8) TabParts {
    const at = std.mem.findScalar(u8, label, '\t') orelse return .{ .left = label, .right = "" };
    assert(at < label.len);
    return .{ .left = label[0..at], .right = label[at + 1 ..] };
}

/// A card label "caption\ntitle\nline" in its parts; null without a "\n".
pub const CardLines = struct { caption: []const u8, title: []const u8, note: []const u8 };

pub fn card_lines(label: []const u8) ?CardLines {
    const first = std.mem.findScalar(u8, label, '\n') orelse return null;
    const rest = label[first + 1 ..];
    const second = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
    const note = if (second < rest.len) rest[second + 1 ..] else "";
    return .{ .caption = label[0..first], .title = rest[0..second], .note = note };
}

/// `bytes` drawn twice (section 3): in `over` left of `split_x` (over a fill) and in the
/// style's colour right of it.
fn split_label(
    cx: anytype,
    style: text.Style,
    bytes: []const u8,
    rect: Rect,
    clip: Clip,
    split_x: f32,
    over: [4]f32,
    options: text.Options,
) void {
    assert(clip.x1 > clip.x0);
    assert(split_x == split_x);
    var left = clip;
    left.x1 = @min(clip.x1, split_x);
    if (left.x1 > left.x0) {
        var shaded = style;
        shaded.color = over;
        kit.label(cx, shaded, bytes, rect, left, options);
    }
    var right = clip;
    right.x0 = @max(clip.x0, split_x);
    if (right.x1 > right.x0) kit.label(cx, style, bytes, rect, right, options);
}

/// `color`'s rgb at alpha 0: a fill that blends into its own border without a fringe.
fn transparent_of(color: [4]f32) [4]f32 {
    assert(color[3] >= 0);
    return .{ color[0], color[1], color[2], 0 };
}

pub fn with_alpha(color: [4]f32, alpha: f32) [4]f32 {
    assert(alpha >= 0 and alpha <= 1);
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

pub fn mix(a: [4]f32, b: [4]f32, amount: f32) [4]f32 {
    assert(amount >= 0 and amount <= 1);
    var out: [4]f32 = undefined;
    for (&out, a, b) |*channel, from, to| channel.* = from + (to - from) * amount;
    return out;
}

comptime {
    for (@typeInfo(widgets.skins.Kind).@"enum".field_names) |name| {
        const kind = @field(widgets.skins.Kind, name);
        const covered = kind == .knob or kind == .meter or kind == .disclosure or kind == .tooltip or kind == .slider;
        if (covered) assert(widgets.skins.check(Skin, kind) == null);
    }
    assert(widgets.skins.check(Object, .knob) == null);
    assert(widgets.skins.check(Object, .button) == null);
    assert(meter_threshold > 0 and meter_threshold < 1);
    assert(cell_h_min >= name_top + name_h);
}

// Locks the schemes (section 4): each look passes `theme.problem`, and its background lies off
// the 8-bit ties: Paper 219.3 / 219.3 / 214.2, Codex 8.925 / 8.925 / 10.2, Patch 8.925 / 10.2 /
// 10.2, HUD 10.2 / 14.025 / 20.4 out of 255.
test "each look is a valid scheme off the rounding ties" {
    const expected = [4][3]f32{
        .{ 219.3, 219.3, 214.2 },
        .{ 8.925, 8.925, 10.2 },
        .{ 8.925, 10.2, 10.2 },
        .{ 10.2, 14.025, 20.4 },
    };
    inline for (all, expected) |look, levels| {
        try std.testing.expectEqual(@as(?[]const u8, null), comptime theme.problem(look.scheme));
        try std.testing.expect(off_ties(look.scheme.colors.background));
        for (levels, look.scheme.colors.background[0..3]) |level, component| {
            try std.testing.expectApproxEqAbs(level, component * 255, 1e-3);
        }
    }
    try std.testing.expect(!off_ties(.{ 0.90, 0.5, 0.5, 1 }));
}

// Locks the forms (step 63): Paper, Codex, and HUD are outlined and framed with no capsule;
// Paper's corners are square, Codex's 2 / 4 / 2, HUD's 0 / 2 / 0; Patch has radii 2 / 6 / 2,
// capsule 0.5, filled controls, and no frame; only HUD fills the selected tab; Paper's mark is 1,
// the others' 2.
test "the forms are the references'" {
    for ([_]Look{ paper, codex, hud }) |look| {
        const form = look.scheme.form;
        try std.testing.expectEqual(@as(f32, 0), form.capsule);
        try std.testing.expectEqual(theme.Form.Controls.outlined, form.controls);
        try std.testing.expect(form.framed);
    }
    try std.testing.expectEqual(theme.Form.Radii{ .control = 0, .popup = 0, .band = 0 }, paper.scheme.form.radius);
    try std.testing.expectEqual(theme.Form.Radii{ .control = 2, .popup = 4, .band = 2 }, codex.scheme.form.radius);
    try std.testing.expectEqual(theme.Form.Radii{ .control = 0, .popup = 2, .band = 0 }, hud.scheme.form.radius);
    const patch = patch_look.scheme.form;
    try std.testing.expectEqual(theme.Form.Radii{ .control = 2, .popup = 6, .band = 2 }, patch.radius);
    try std.testing.expectEqual(@as(f32, 0.5), patch.capsule);
    try std.testing.expectEqual(theme.Form.Controls.filled, patch.controls);
    try std.testing.expect(!patch.framed);
    for (all, [4]theme.Form.TabMark{ .underline, .underline, .underline, .filled }) |look, mark| {
        try std.testing.expectEqual(mark, look.scheme.form.tab_mark);
    }
    try std.testing.expectEqual(@as(f32, 1), paper.scheme.form.mark);
    try std.testing.expectEqual(@as(f32, 2), hud.scheme.form.mark);
}

// Locks the label splits (section 3): a header's tab puts its count at the end; a card's
// label is caption, title, and line; one line is a title alone.
test "headers and cards split their labels" {
    const header = split_tab("RACK CONTROL\tCPU 8%");
    try std.testing.expectEqualStrings("RACK CONTROL", header.left);
    try std.testing.expectEqualStrings("CPU 8%", header.right);
    try std.testing.expectEqualStrings("", split_tab("ADVANCED").right);
    const card = card_lines("PATCH\nosc~ 440\nthe first oscillator").?;
    try std.testing.expectEqualStrings("PATCH", card.caption);
    try std.testing.expectEqualStrings("osc~ 440", card.title);
    try std.testing.expectEqualStrings("the first oscillator", card.note);
    try std.testing.expectEqualStrings("", card_lines("A\nB").?.note);
    try std.testing.expectEqual(@as(?CardLines, null), card_lines("osc~"));
}

// Locks the text over a meter's fill: Paper's and Codex's grey fills take the background, HUD's
// dark teal the text dimmed.
test "meter text keeps its contrast over the fill" {
    try std.testing.expectEqual(paper.scheme.colors.background, over_fill(&paper.scheme));
    try std.testing.expectEqual(codex.scheme.colors.background, over_fill(&codex.scheme));
    try std.testing.expectEqual(with_alpha(hud.scheme.colors.text, dim_alpha), over_fill(&hud.scheme));
}

// Locks the meter's pieces (section 3): at 0.72 in 284 px the fill is 204.48 and nothing is past
// the tick; at 0.86 the fill stops at the tick, 227.2, and 17.04 lies past it, reaching 12 back
// under the fill when rounded by 12; "72%" and "100%".
test "the meter fills to the tick and past it" {
    const row: Rect = .{ .x = 20, .y = 100, .width = 284, .height = 24 };
    const output = meter_fill(row, 0.72, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 204.48), output.below.width, 1e-3);
    try std.testing.expectEqual(@as(f32, 0), output.past.width);
    const cpu = meter_fill(row, 0.86, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 227.2), cpu.below.width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 17.04), cpu.past.width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20 + 227.2), cpu.past.x, 1e-3);
    const round = meter_fill(row, 0.86, 12);
    try std.testing.expectApproxEqAbs(@as(f32, 17.04 + 12), round.past.width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20 + 227.2 - 12), round.past.x, 1e-3);
    var digits: [8]u8 = undefined;
    try std.testing.expectEqualStrings("72%", percent_text(&digits, 0.72));
    try std.testing.expectEqualStrings("100%", percent_text(&digits, 1));
}

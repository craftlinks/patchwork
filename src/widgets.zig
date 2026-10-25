//! Widgets: panels, labels, buttons, sliders, knobs, meters, toggles, a text field, menus, a
//! dropdown, and a tooltip as plain structs, and the kit they are built from.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Plain Structs, Drawn in Place
//! A widget is a struct the app owns: its id, its value, and its animators. It has no rect
//! and no layout pass. `draw(self, cx, walk)` asks the turtle for its box (`cx.walk`), culls
//! itself when the box is outside the clip (`cx.visible`), hands the box to its skin, which
//! appends the records (`draw.Box`, `draw.Arc`, and `draw.Glyph` for the default skin) and
//! returns the hit shape, and records that hit area (`cx.area`; section 6). `cx` is the
//! app's `ui.Context`; it is `anytype` because that type depends on the app's draw types,
//! so a widget fails to compile against an app that did not register a type it draws.
//!
//! ## 2. Events and Actions
//! `handle(self, cx, event) Action` is called by the app for every event, `.frame`
//! included:
//! - `.frame` steps the widget's animators; a moved value calls `cx.redraw()` and a live one
//!   `cx.keep_animating()`, which keeps frame callbacks coming. Animators never step in draw.
//! - Every other event is resolved by `cx.hit(self.id, event)` in O(1) against the areas of
//!   the last frame. `down` and `drag` carry that area's rect, so geometry such as the
//!   slider's travel needs no stored rect. A press or wheel counts as hovering, because
//!   one event delivers one hit and a press may arrive without a prior move.
//! - The return value says what changed for the app (`Knob.Action.changed`), so an app can
//!   react to a value, not only repaint.
//! - A right press reaches only the hot widget, as `secondary`; the knob resets on it
//!   (`Knob.Action.reset`), the others ignore it.
//! - Keyboard and paste events answer `none` from `hit`; only the focused `TextField` reads
//!   them.
//! `Panel`, `Label`, and `Meter` are passive: they draw and record no area.
//!
//! ## 3. Files
//! One file per widget, each with its constants, geometry helpers, guide, and tests; this file
//! re-exports every name, so `widgets.Knob` and `widgets.ring_size` are where they always were
//! (test "widgets re-exports every public name of step 29").
//! ```text
//! widgets/kit.zig         append, face, arc, label, step, aim, weight, clicked, Interaction,
//!                         Paint, the hover and press constants, the shared text styles
//! widgets/skin.zig        the look structs, Shape, skins.check, and skins.Default
//! widgets/label.zig       Label
//! widgets/panel.zig       Panel
//! widgets/button.zig      Button
//! widgets/slider.zig      Slider and its track geometry
//! widgets/knob.zig        Knob, the ring and label-column geometry, accents
//! widgets/meter.zig       Meter
//! widgets/toggle.zig      Toggle and its pill geometry
//! widgets/text_field.zig  TextField
//! widgets/menu.zig        Menu and ContextMenu: a list in a popup (`ui/popup.zig`)
//! widgets/dropdown.zig    Dropdown: a face and its Menu
//! widgets/tooltip.zig     Tooltip: one line after a hover dwell, on the tooltip layer
//! widgets/fixture.zig     the tests' static context and drivers
//! ```
//! A widget file imports `kit.zig` and `skin.zig` (and `knob.zig` for the shared row
//! geometry), never this file; `skin.zig` imports the widget files back for their geometry,
//! which Zig resolves lazily. An app's own widget is built the same way, from
//! `widgets.kit`.
//!
//! ## 4. Capacity
//! Every append goes through `kit.append`, which skips an instance whose pool or batch list is
//! full; the context counts the drop in `overflow_count`, and app tests assert it is zero.
//!
//! ## 5. Theme and Text Styles
//! Widgets read their colors, text styles, and hover and press weights from the app's scheme
//! at draw time (`cx.theme()`, `theme.zig`): control names in `scheme.name` and knob values in
//! `scheme.value` (Noto Sans and Noto Sans Mono, so readouts keep their width as digits
//! change). A color or style the app stored in a widget (`Button.paint`, `Knob.accent`, a
//! `Label`'s style) wins. `name_style`, `value_style`, `accents`, `hover_lighten`,
//! `down_darken`, `field_focus_border`, and `field_selection` are `theme.dark`'s values, kept
//! as constants for code that names them; `kit.accent(cx, i)` is the app scheme's accent.
//!
//! ## 6. Skins
//! Every widget but `Label` is generic over a skin, a struct of draw functions passed at
//! compile time (`widgets/skin.zig`): `KnobOf(Skin)`, `ButtonOf`, `SliderOf`, `ToggleOf`,
//! `MeterOf`, `PanelOf`, and `TextFieldOf` (its face only). The plain names are the default
//! skin, `Knob = KnobOf(skins.Default)`, and draw exactly what they drew before skins. A skin
//! gets a look struct of values and returns the hit shape; a missing or mistyped function is
//! a compile error naming the skin (`skins.check`). `ui.route` routes any of them.
//!
//! ## 6a. Popups
//! `Menu`, `ContextMenu`, `Dropdown`, and `Tooltip` draw their popups in `draw_overlay(cx)`,
//! which `ui.overlays(cx, app)` calls at the end of `App.draw`, at the root, on `Layer.popup`
//! and `Layer.tooltip` (`ui/cx.zig`, section 3c). A menu's backdrop takes every press outside
//! it, so an outside press only dismisses. `bounds` (null for the window) is the rect a popup
//! stays inside.
//!
//! ## 7. TigerStyle Invariants
//! - No allocation: label text points at app-owned bytes bounded by `text.byte_cap`; a
//!   knob's value text and a field's bytes are inline.
//! - Geometry helpers are pure; `handle` is the only mutator.

const std = @import("std");
const quads = @import("draw.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

/// The widget-authoring kit (`widgets/kit.zig`).
pub const kit = @import("widgets/kit.zig");
/// Skins: the look of each widget, apart from its behaviour (`widgets/skin.zig`).
pub const skins = @import("widgets/skin.zig");
const label = @import("widgets/label.zig");
const panel = @import("widgets/panel.zig");
const button = @import("widgets/button.zig");
const slider = @import("widgets/slider.zig");
const knob = @import("widgets/knob.zig");
const meter = @import("widgets/meter.zig");
const toggle = @import("widgets/toggle.zig");
const text_field = @import("widgets/text_field.zig");
const menu = @import("widgets/menu.zig");
const dropdown = @import("widgets/dropdown.zig");
const tooltip = @import("widgets/tooltip.zig");

pub const Rect = quads.Rect;
pub const Inset = quads.Inset;
pub const Walk = ui.Walk;
pub const Id = ui.Id;

pub const hover_lighten = kit.hover_lighten;
pub const down_darken = kit.down_darken;
pub const hover_duration_ms = kit.hover_duration_ms;
pub const down_duration_ms = kit.down_duration_ms;
pub const hover_rate_per_ms = kit.hover_rate_per_ms;
pub const down_rate_per_ms = kit.down_rate_per_ms;
pub const Paint = kit.Paint;
pub const name_style = kit.name_style;
pub const value_style = kit.value_style;
pub const centered = kit.centered;
pub const paint_of = kit.paint_of;
pub const settled = kit.settled;

pub const Shape = skins.Shape;
pub const ButtonLook = skins.ButtonLook;
pub const SliderLook = skins.SliderLook;
pub const KnobLook = skins.KnobLook;
pub const ToggleLook = skins.ToggleLook;
pub const MeterLook = skins.MeterLook;
pub const PanelLook = skins.PanelLook;
pub const FieldLook = skins.FieldLook;
pub const MenuFaceLook = skins.MenuFaceLook;
pub const MenuRowLook = skins.MenuRowLook;
pub const DropdownLook = skins.DropdownLook;

pub const Label = label.Label;
pub const Panel = panel.Panel;
pub const Button = button.Button;
pub const ButtonOf = button.ButtonOf;
pub const PanelOf = panel.PanelOf;

pub const Slider = slider.Slider;
pub const SliderOf = slider.SliderOf;
pub const knob_radius = slider.knob_radius;
pub const track_height = slider.track_height;
pub const track_radius = slider.track_radius;
pub const value_at = slider.value_at;
pub const track_rect = slider.track_rect;
pub const knob_rect = slider.knob_rect;

pub const Knob = knob.Knob;
pub const KnobOf = knob.KnobOf;
pub const drag_span_px = knob.drag_span_px;
pub const ring_size = knob.ring_size;
pub const ring_thickness = knob.ring_thickness;
pub const ring_inset = knob.ring_inset;
pub const ring_min = knob.ring_min;
pub const label_gap = knob.label_gap;
pub const knob_height = knob.knob_height;
pub const label_line_px = knob.label_line_px;
pub const accent_count = knob.accent_count;
pub const accents = knob.accents;
pub const knob_flags = knob.knob_flags;
pub const ring_of = knob.ring_of;
pub const ring_sized = knob.ring_sized;
pub const write_hundredths = knob.write_hundredths;
pub const name_box = knob.name_box;
pub const value_box = knob.value_box;
pub const side_box = knob.side_box;

pub const Meter = meter.Meter;
pub const MeterOf = meter.MeterOf;
pub const meter_height = meter.meter_height;
pub const meter_track_w = meter.meter_track_w;
pub const meter_track_h = meter.meter_track_h;
pub const meter_radius = meter.meter_radius;
pub const meter_track = meter.meter_track;
pub const meter_track_sized = meter.meter_track_sized;

pub const Toggle = toggle.Toggle;
pub const ToggleOf = toggle.ToggleOf;
pub const toggle_height = toggle.toggle_height;
pub const pill_w = toggle.pill_w;
pub const pill_h = toggle.pill_h;
pub const pill_radius = toggle.pill_radius;
pub const thumb_side = toggle.thumb_side;
pub const thumb_inset = toggle.thumb_inset;
pub const pill_of = toggle.pill_of;
pub const toggle_thumb = toggle.toggle_thumb;

pub const TextField = text_field.TextField;
pub const TextFieldOf = text_field.TextFieldOf;
pub const field_flags = text_field.field_flags;
pub const field_padding_x = text_field.field_padding_x;
pub const field_radius = text_field.field_radius;
pub const field_border_px = text_field.field_border_px;
pub const field_caret_inset = text_field.field_caret_inset;
pub const field_focus_border = text_field.field_focus_border;
pub const field_selection = text_field.field_selection;
pub const field_text_options = text_field.field_text_options;
pub const field_inner = text_field.field_inner;

pub const Menu = menu.Menu;
pub const MenuOf = menu.MenuOf;
pub const MenuAction = menu.MenuAction;
pub const ContextMenu = menu.ContextMenu;
pub const ContextMenuOf = menu.ContextMenuOf;
pub const menu_items_max = menu.menu_items_max;
pub const menu_row_h = menu.menu_row_h;
pub const menu_pad_x = menu.menu_pad_x;
pub const menu_pad_y = menu.menu_pad_y;

pub const Dropdown = dropdown.Dropdown;
pub const DropdownOf = dropdown.DropdownOf;

pub const Tooltip = tooltip.Tooltip;
pub const Tip = tooltip.Tip;
pub const tooltip_delay_ms = tooltip.tooltip_delay_ms;
pub const tooltip_text_cap = tooltip.tooltip_text_cap;

test {
    _ = kit;
    _ = skins;
    _ = label;
    _ = panel;
    _ = button;
    _ = slider;
    _ = knob;
    _ = meter;
    _ = toggle;
    _ = text_field;
    _ = menu;
    _ = dropdown;
    _ = tooltip;
}

/// Every public name of `widgets.zig` at step 29, before the split.
const step_29_names = [_][]const u8{
    "Rect",              "Inset",              "Walk",              "Id",
    "hover_lighten",     "down_darken",        "hover_duration_ms", "down_duration_ms",
    "hover_rate_per_ms", "down_rate_per_ms",   "knob_radius",       "track_height",
    "track_radius",      "drag_span_px",       "ring_size",         "ring_thickness",
    "ring_inset",        "ring_min",           "label_gap",         "knob_height",
    "meter_height",      "toggle_height",      "meter_track_w",     "meter_track_h",
    "meter_radius",      "pill_w",             "pill_h",            "pill_radius",
    "thumb_side",        "thumb_inset",        "label_line_px",     "accent_count",
    "field_flags",       "field_padding_x",    "field_radius",      "field_border_px",
    "field_caret_inset", "field_focus_border", "field_selection",   "field_text_options",
    "knob_flags",        "Paint",              "accents",           "name_style",
    "value_style",       "centered",           "Label",             "Panel",
    "Button",            "Slider",             "Knob",              "Meter",
    "Toggle",            "TextField",          "field_inner",       "value_at",
    "track_rect",        "knob_rect",          "paint_of",          "settled",
    "ring_of",           "ring_sized",         "write_hundredths",  "meter_track",
    "meter_track_sized", "pill_of",            "toggle_thumb",
};

// Locks the dark defaults (section 5): the style, accent, weight, and field constants equal
// `theme.dark`'s, so code that names them draws what the default scheme draws.
test "the widget constants are the dark scheme's" {
    const dark = theme.dark;
    try std.testing.expect(std.meta.eql(dark.name, name_style));
    try std.testing.expect(std.meta.eql(dark.value, value_style));
    try std.testing.expectEqual(dark.hover_lighten, hover_lighten);
    try std.testing.expectEqual(dark.down_darken, down_darken);
    try std.testing.expectEqual(dark.colors.focus, field_focus_border);
    try std.testing.expectEqual(dark.colors.selection, field_selection);
    for (accents, dark.accents) |paint, color| {
        try std.testing.expectEqual(color, [4]f32{ paint.r, paint.g, paint.b, paint.a });
    }
}

// Locks the split's compatibility: each of the 67 public names of step 29's `widgets.zig` is
// still declared here, so an app that compiled against step 29 compiles against step 30.
test "widgets re-exports every public name of step 29" {
    try std.testing.expectEqual(@as(usize, 67), step_29_names.len);
    inline for (step_29_names) |name| {
        try std.testing.expect(@hasDecl(@This(), name));
        _ = @field(@This(), name);
    }
}

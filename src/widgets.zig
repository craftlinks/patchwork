//! Widgets: panels, labels, buttons, sliders, knobs, meters, toggles, checkboxes, a text field
//! (with a hint, a secret mode, and a leading icon), menus, a dropdown, a tooltip, tabs (and a
//! segmented control), a splitter, a list box, and a number box as plain structs, and the kit
//! they are built from.
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
//! `Panel`, `Label`, `Paragraph`, and `Meter` are passive: they draw and record no area.
//!
//! ## 3. Files
//! One file per widget, each with its constants, geometry helpers, guide, and tests; this file
//! re-exports every name, so `widgets.Knob` and `widgets.ring_size` are where they always were
//! (test "widgets re-exports every public name of step 29").
//! ```text
//! widgets/kit.zig         append, face, arc, label, paragraph, step, aim, weight, clicked,
//!                         Interaction, Paint, the hover and press constants, the shared text
//!                         styles
//! widgets/skin.zig        the look structs, Shape, skins.check, and skins.Default
//! widgets/label.zig       Label
//! widgets/paragraph.zig   Paragraph: text wrapped to its width, a fit height for that width
//! widgets/panel.zig       Panel
//! widgets/button.zig      Button
//! widgets/slider.zig      Slider and its track geometry
//! widgets/knob.zig        Knob, the ring and label-column geometry, accents
//! widgets/meter.zig       Meter
//! widgets/toggle.zig      Toggle and its pill geometry
//! widgets/checkbox.zig    Checkbox: a box, a check mark or a mixed bar, and its label
//! widgets/text_field.zig  TextField
//! widgets/menu.zig        Menu and ContextMenu: a list in a popup (`ui/popup.zig`)
//! widgets/dropdown.zig    Dropdown: a face and its Menu
//! widgets/tooltip.zig     Tooltip: one line after a hover dwell, on the tooltip layer
//! widgets/tabs.zig        Tabs: a bar of tabs over a page the app draws, or alone (Segmented)
//! widgets/splitter.zig    Splitter: two panes and a draggable divider, begin/next/end
//! widgets/dock.zig        Dock: panels in a tree of splits and tab sets; drop zones, save/load
//! widgets/list_box.zig    ListBox: a virtual list with selection, keys, scroll-into-view
//! widgets/number_box.zig  NumberBox: drag, wheel, or type a value with a unit; format, parse
//! widgets/tree_view.zig   TreeView: pre-order nodes flattened into a ListBox, chevrons, keys
//! widgets/disclosure.zig  Disclosure: a header with a chevron over a section drawn while open
//! widgets/column_header.zig  ColumnHeader: resizable, sortable columns and a row's spans
//! widgets/window_chrome.zig  WindowButtons, the drag area, and the resize edges
//! widgets/menu_bar.zig    MenuBar: menus side by side; hover and Left / Right switch them
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
//! `CheckboxOf`, `MeterOf`, `PanelOf`, `TextFieldOf` (its face only), `MenuOf`, `DropdownOf`,
//! `TabsOf`, `SplitterOf`, `ListBoxOf`, and `NumberBoxOf`. The plain names are the default
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
//! ## 6b. Containers
//! `Tabs`, `Splitter`, and `ListBox` keep the turtle's begin/end shape: the library owns the
//! chrome, the geometry, and the input, and the app draws the content between the calls
//! (`tabs.begin` ... `cx.end()`; `sp.begin`, `sp.next`, `sp.end`; `lb.begin`, `while
//! (lb.next(cx)) |row|`, `lb.end`). No widget takes a callback. The splitter and the list box
//! keep state from their draw (the splitter's rect, the list's walked rows), so their draw
//! calls take `*Self`. `NumberBox` is a leaf that swaps in its `TextField` while editing.
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
const paragraph = @import("widgets/paragraph.zig");
const panel = @import("widgets/panel.zig");
const button = @import("widgets/button.zig");
const slider = @import("widgets/slider.zig");
const knob = @import("widgets/knob.zig");
const meter = @import("widgets/meter.zig");
const toggle = @import("widgets/toggle.zig");
const checkbox = @import("widgets/checkbox.zig");
const text_field = @import("widgets/text_field.zig");
const menu = @import("widgets/menu.zig");
const dropdown = @import("widgets/dropdown.zig");
const tooltip = @import("widgets/tooltip.zig");
const splitter = @import("widgets/splitter.zig");
const tabs = @import("widgets/tabs.zig");
const list_box = @import("widgets/list_box.zig");
const dock = @import("widgets/dock.zig");
const number_box = @import("widgets/number_box.zig");
const tree_view = @import("widgets/tree_view.zig");
const disclosure = @import("widgets/disclosure.zig");
const column_header = @import("widgets/column_header.zig");
const window_chrome = @import("widgets/window_chrome.zig");
const menu_bar = @import("widgets/menu_bar.zig");

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
pub const CheckboxLook = skins.CheckboxLook;
pub const MeterLook = skins.MeterLook;
pub const PanelLook = skins.PanelLook;
pub const FieldLook = skins.FieldLook;
pub const MenuFaceLook = skins.MenuFaceLook;
pub const MenuRowLook = skins.MenuRowLook;
pub const DropdownLook = skins.DropdownLook;
pub const TabBarLook = skins.TabBarLook;
pub const TabLook = skins.TabLook;
pub const DividerLook = skins.DividerLook;
pub const ListRowLook = skins.ListRowLook;
pub const NumberLook = skins.NumberLook;
pub const ChevronLook = skins.ChevronLook;
pub const DisclosureLook = skins.DisclosureLook;
pub const HeaderCellLook = skins.HeaderCellLook;
pub const WindowButtonLook = skins.WindowButtonLook;
pub const WindowButtonKind = skins.WindowButtonKind;
pub const MenuTitleLook = skins.MenuTitleLook;

pub const Label = label.Label;
pub const Paragraph = paragraph.Paragraph;
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
pub const name_max = knob.name_max;
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

pub const Checkbox = checkbox.Checkbox;
pub const CheckboxOf = checkbox.CheckboxOf;
pub const checkbox_height = checkbox.checkbox_height;
pub const checkbox_flags = checkbox.checkbox_flags;
pub const checkbox_label_max = checkbox.checkbox_label_max;

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

pub const Splitter = splitter.Splitter;
pub const SplitterOf = splitter.SplitterOf;
pub const Axis = splitter.Axis;
pub const Panes = splitter.Panes;
pub const splitter_px = splitter.splitter_px;
pub const split = splitter.split;
pub const divider_salt = splitter.divider_salt;

pub const Tabs = tabs.Tabs;
pub const TabsOf = tabs.TabsOf;
/// A segmented control: tabs arranged `even` in a track, drawn with `bar` (no page).
pub const Segmented = TabsOf(skins.Segmented);
pub const TabArrange = tabs.TabArrange;
pub const even_widths = tabs.even_widths;
pub const segment_inset = tabs.segment_inset;
pub const tabs_max = tabs.tabs_max;
pub const tab_bar_h = tabs.tab_bar_h;
pub const tab_widths = tabs.tab_widths;
pub const closable_width = tabs.closable_width;
pub const close_rect = tabs.close_rect;
pub const insertion = tabs.insertion;
pub const move_item = tabs.move_item;
pub const remove_item = tabs.remove_item;
pub const insert_item = tabs.insert_item;
pub const TabGrab = tabs.Grab;
pub const tab_close_w = tabs.tab_close_w;
pub const tab_detach_px = tabs.tab_detach_px;
pub const close_salt = tabs.close_salt;

pub const Dock = dock.Dock;
pub const DockOf = dock.DockOf;
pub const DockZone = dock.Zone;
pub const DockPanel = dock.Panel;
pub const dock_nodes_max = dock.dock_nodes_max;
pub const dock_panels_max = dock.dock_panels_max;
pub const dock_save_max = dock.dock_save_max;
pub const dock_edge_px = dock.dock_edge_px;
pub const dock_edge_salt = dock.edge_salt;
pub const dock_page_salt = dock.page_salt;
pub const dock_zone_of = dock.zone_of;
pub const dock_zone_rect = dock.zone_rect;

pub const ListBox = list_box.ListBox;
pub const ListBoxOf = list_box.ListBoxOf;
pub const ListRow = list_box.Row;
pub const list_rows_max = list_box.list_rows_max;
pub const list_row_salt = list_box.row_salt;

pub const TreeView = tree_view.TreeView;
pub const TreeViewOf = tree_view.TreeViewOf;
pub const TreeNode = tree_view.TreeNode;
pub const TreeRow = tree_view.TreeRow;
pub const tree_root = tree_view.tree_root;
pub const tree_depth_max = tree_view.tree_depth_max;
pub const tree_nodes_max = tree_view.tree_nodes_max;
pub const tree_flatten = tree_view.flatten;

pub const Disclosure = disclosure.Disclosure;
pub const DisclosureOf = disclosure.DisclosureOf;
pub const disclosure_h = disclosure.disclosure_h;

pub const ColumnHeader = column_header.ColumnHeader;
pub const ColumnHeaderOf = column_header.ColumnHeaderOf;
pub const Column = column_header.Column;
pub const ColumnSort = column_header.Sort;
pub const columns_max = column_header.columns_max;
pub const header_h = column_header.header_h;
pub const column_divider_salt = column_header.divider_salt;

pub const WindowButtons = window_chrome.WindowButtons;
pub const WindowButtonsOf = window_chrome.WindowButtonsOf;
pub const WindowButton = window_chrome.WindowButton;
pub const window_button_w = window_chrome.window_button_w;
pub const window_drag = window_chrome.window_drag;
pub const window_drag_flags = window_chrome.window_drag_flags;
pub const window_edges = window_chrome.window_edges;
pub const window_edge_px = window_chrome.window_edge_px;
pub const window_corner_px = window_chrome.window_corner_px;

pub const MenuBar = menu_bar.MenuBar;
pub const MenuBarOf = menu_bar.MenuBarOf;
pub const MenuChoice = menu_bar.MenuChoice;
pub const menubar_menus_max = menu_bar.menubar_menus_max;

pub const NumberBox = number_box.NumberBox;
pub const NumberBoxOf = number_box.NumberBoxOf;
pub const NumberFormat = number_box.Format;
pub const number_text_cap = number_box.number_text_cap;
pub const number_drag_px = number_box.number_drag_px;
pub const format_number = number_box.format;
pub const parse_number = number_box.parse;

test {
    _ = kit;
    _ = skins;
    _ = label;
    _ = paragraph;
    _ = panel;
    _ = button;
    _ = slider;
    _ = knob;
    _ = meter;
    _ = toggle;
    _ = checkbox;
    _ = text_field;
    _ = menu;
    _ = dropdown;
    _ = tooltip;
    _ = splitter;
    _ = tabs;
    _ = list_box;
    _ = dock;
    _ = number_box;
    _ = tree_view;
    _ = disclosure;
    _ = column_header;
    _ = window_chrome;
    _ = menu_bar;
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

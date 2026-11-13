//! Skins: how a widget looks, apart from how it behaves.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Behaviour and Look
//! A library widget is generic over a skin: `KnobOf(Skin)`, `ButtonOf(Skin)`, `SliderOf(Skin)`,
//! `ToggleOf(Skin)`, `CheckboxOf(Skin)`, `MeterOf(Skin)`, `PanelOf(Skin)`, `TextFieldOf(Skin)`,
//! `MenuOf(Skin)` (and `ContextMenuOf`), `DropdownOf(Skin)`, `TabsOf(Skin)`, `SplitterOf(Skin)`,
//! `ListBoxOf(Skin)`, `NumberBoxOf(Skin)`, `TooltipOf(Skin)`, and the rest of the table below.
//! The behaviour
//! (fields, `init`, `handle`, `Action`) is written once in the widget's file. Its `draw` asks
//! the turtle for the box, culls it, builds a look struct of plain values, and hands it to the
//! skin, which appends the instances and returns the hit shape the behaviour records:
//! ```text
//! row   = cx.walk(walk); clip = cx.visible(row) orelse return
//! shape = Skin.knob(cx, KnobLook{ row, clip, ring, value, hover, ... }) orelse return
//! cx.area(id, shape.rect, shape.radius, knob_flags)
//! ```
//! A skin is any struct type. It declares the functions of the widgets it skins and nothing
//! else; `KnobOf(S)` checks only `S.knob`. A skin may append its own draw types, which the
//! app registers in `config.draw` like any other. `Default` is the library's look, and
//! `widgets.Knob` is `KnobOf(Default)`, so the plain names draw what they always drew.
//! There is no vtable and no function pointer: a different look is a different type
//! (`widgets.Knob` beside `widgets.KnobOf(hardware.Skin)`), and `ui.route` routes both because
//! it looks only for `handle`.
//!
//! ## 2. The Contract
//! ```text
//! widget          skin function                        returns
//! ButtonOf(S)     button(cx, ButtonLook)               ?Shape   null draws and records nothing
//! SliderOf(S)     slider(cx, SliderLook)               ?Shape
//!                 slider_travel(area: Rect)            [2]f32   the x span a press maps onto
//! KnobOf(S)       knob(cx, KnobLook)                   ?Shape
//! ToggleOf(S)     toggle(cx, ToggleLook)               ?Shape
//! CheckboxOf(S)   checkbox(cx, CheckboxLook)           ?Shape
//! MeterOf(S)      meter(cx, MeterLook)                 void     passive
//! PanelOf(S)      panel(cx, PanelLook)                 void     passive
//! TextFieldOf(S)  field(cx, FieldLook)                 void     the face and border only
//! MenuOf(S)       menu_face(cx, MenuFaceLook)          void     the popup's face
//!                 menu_row(cx, MenuRowLook)            void     one row: band and label
//! DropdownOf(S)   dropdown(cx, DropdownLook)           ?Shape   the face; its list is MenuOf(S)
//! TabsOf(S)       tab_bar(cx, TabBarLook)              void     the strip under the tabs
//!                 tab(cx, TabLook)                     ?Shape   one tab
//! SplitterOf(S)   divider(cx, DividerLook)             ?Shape
//! ListBoxOf(S)    list_row(cx, ListRowLook)            void     the band under one row
//! NumberBoxOf(S)  number_face(cx, NumberLook)          ?Shape
//!                 field(cx, FieldLook)                 void     its editor is TextFieldOf(S)
//! TreeViewOf(S)   list_row(cx, ListRowLook)            void     its rows are ListBoxOf(S)
//!                 tree_chevron(cx, ChevronLook)        void     a parent's chevron
//! DisclosureOf(S) disclosure(cx, DisclosureLook)       ?Shape   the header
//! ColumnHeaderOf(S) header_cell(cx, HeaderCellLook)    ?Shape   one column's cell
//! WindowButtonsOf(S) window_button(cx, WindowButtonLook) ?Shape  one window button
//! MenuBarOf(S)    menu_title(cx, MenuTitleLook)        ?Shape   one title; its menus are
//!                                                               MenuOf(S)
//! TooltipOf(S)    tooltip(cx, TooltipLook)             void     on Layer.tooltip
//! ```
//! `check` reads the table of each widget's functions (`functions_of`), in this order.
//! - A look carries values, never the widget, so a skin cannot change state. Animator values
//!   arrive raw in `[0, 1]`; the skin applies the scheme's weights (`cx.theme()`).
//! - Only the skin knows where what it drew is, so it returns the hit shape: a dial with a
//!   drop shadow does not take presses on its shadow. The behaviour keeps the id, the flags,
//!   and the recording.
//! - A text field's selection band, glyphs, and caret are editing, not look; they stay in the
//!   behaviour.
//! - `check(S, kind)` returns the first problem as a message naming the skin and the function
//!   (`"hardware.Skin: missing ``pub fn knob(cx, widgets.KnobLook) ?widgets.Shape``"`, or
//!   `"... ``knob`` must return ?widgets.Shape"`); each `XOf` turns it into a compile error.
//!   `zig build test-contract` locks one case.
//!
//! ## 3. Slider Travel
//! A press maps onto the slider's value through the skin's travel, so a skin whose knob is
//! wider or whose track is inset maps presses onto what it drew:
//! ```text
//! [t0, t1] = S.slider_travel(press.rect)
//! value    = clamp((x - t0) / (t1 - t0), 0, 1)     a non-positive span gives 0
//! ```
//! `Default.slider_travel` is the track inset by `knob_radius` at both ends, and
//! `widgets.value_at` is this map over it.
//!
//! ## 4. `Default`
//! The bodies of the step 31 `draw` functions, moved here unchanged, and the looks of the
//! widgets added since. Draw order within a
//! layer follows first appearance, so each appends in exactly the order it always did. The
//! geometry helpers (`ring_sized`, `name_box`, `pill_of`, ...) stay in the widget files.
//!
//! Corners and strokes come from the scheme's form (`cx.theme().form`, `theme.zig` section
//! 8), not from constants: `radius.control`, `radius.popup`, `radius.band`, `capsule`,
//! `hairline`, and `mark`. The default form is the old constants, and the comptime block after
//! `Default` asserts the names a consumer can still reach (`field_radius`, `pill_radius`, ...)
//! equal it. With `controls = .outlined`, `button`, `dropdown` (solid), `number_face`, `field`,
//! `checkbox`, `toggle`'s pill, and an unselected `tab` each replace their filled Box with one
//! `outline` Box: a `hairline` border in the ink over the ink's rgb at an alpha of the hover
//! plus press weights, so a resting outline is the bare border. The meter, knob, slider, menu
//! face, rows, bands, disclosure, header cells, window buttons, and `Segmented` stay filled
//! and read only the radii, `capsule`, and `hairline`. `tab_mark` and `framed` apply in either
//! mode. A skin of its own reads `cx.theme().form` to follow the scheme's corners.
//!
//! ## 4a. `Segmented`
//! The library's second skin, for `TabsOf` only: `widgets.Segmented` is
//! `TabsOf(skins.Segmented)`. It declares `tab_arrange = .even` (`widgets/tabs.zig`, section
//! 2a), the one optional declaration `check` reads besides the functions: when present it
//! must be a `widgets.TabArrange`. Its track and segments are rounded by `capsule` of their
//! height, and its focus border is `hairline` wide.
//!
//! ## 5. TigerStyle Invariants
//! - Skin functions are stateless: everything they need is in the look and `cx.theme()`.
//! - `check` runs at compile time only; a skin that does not satisfy it does not compile.

const std = @import("std");
const assert = std.debug.assert;
const quads = @import("../draw.zig");
const text = @import("../text.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const theme = @import("../theme.zig");
const slider_file = @import("slider.zig");
const knob_file = @import("knob.zig");
const toggle_file = @import("toggle.zig");
const checkbox_file = @import("checkbox.zig");
const meter_file = @import("meter.zig");
const field_file = @import("text_field.zig");
const menu_file = @import("menu.zig");
const dropdown_file = @import("dropdown.zig");
const tabs_file = @import("tabs.zig");
const splitter_file = @import("splitter.zig");
const list_box_file = @import("list_box.zig");
const number_box_file = @import("number_box.zig");
const disclosure_file = @import("disclosure.zig");
const column_header_file = @import("column_header.zig");
const window_chrome_file = @import("window_chrome.zig");
const menu_bar_file = @import("menu_bar.zig");

const Rect = kit.Rect;
const Clip = kit.Clip;
const Inset = kit.Inset;
const Paint = kit.Paint;

/// The hit area a skin returns: where the behaviour records its id, rounded by `radius`.
pub const Shape = struct { rect: Rect, radius: f32 };

/// A button's face: its box, the label inside `padding`, its paint, and the raw hover and
/// press animator values.
pub const ButtonLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    style: text.Style,
    padding: Inset,
    paint: Paint,
    hover: f32,
    down: f32,
};

/// A slider at `value` in `rect`, its three paints, and the raw hover value.
pub const SliderLook = struct {
    rect: Rect,
    clip: Clip,
    value: f32,
    hover: f32,
    track: Paint,
    fill: Paint,
    knob: Paint,
};

/// A knob row: the box, the ring's side, the value and its text, the raw hover value, and the
/// knob's accent and name.
pub const KnobLook = struct {
    row: Rect,
    clip: Clip,
    ring: f32,
    value: f32,
    hover: f32,
    accent: Paint,
    name: []const u8,
    value_text: []const u8,
};

/// A toggle row: the thumb's eased position in `[0, 1]`, the raw hover value, the name, and
/// the thumb's colour when on (null: the skin's own).
pub const ToggleLook = struct {
    row: Rect,
    clip: Clip,
    thumb: f32,
    hover: f32,
    name: []const u8,
    accent: ?[4]f32 = null,
};

/// A checkbox row: its label, the check's eased value in `[0, 1]`, whether it is mixed, the raw
/// hover value, and whether it has keyboard focus.
pub const CheckboxLook = struct {
    row: Rect,
    clip: Clip,
    label: []const u8,
    check: f32,
    mixed: bool,
    hover: f32,
    focused: bool,
};

/// A meter row: the level, the track's height, and the name.
pub const MeterLook = struct {
    row: Rect,
    clip: Clip,
    value: f32,
    track_h: f32,
    name: []const u8,
};

/// A panel's face.
pub const PanelLook = struct {
    rect: Rect,
    clip: Clip,
    paint: Paint,
    /// The panel's own material, or the scheme's (`theme.zig`, section 7).
    material: theme.Material = .solid,
};

/// A text field's face and border; `focused` selects the focus border.
pub const FieldLook = struct {
    rect: Rect,
    clip: Clip,
    focused: bool,
};

/// A menu's popup face: the whole popup rect.
pub const MenuFaceLook = struct {
    rect: Rect,
    clip: Clip,
    /// The menu's own material, or the scheme's (`theme.zig`, section 7).
    material: theme.Material = .solid,
};

/// One menu row: its rect, its label in `style`, whether it is enabled, and whether it is the
/// highlighted row.
pub const MenuRowLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    style: text.Style,
    enabled: bool,
    highlighted: bool,
};

/// A dropdown's face: its box, the selected item's label, the raw hover value, and whether its
/// list is open.
pub const DropdownLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    hover: f32,
    open: bool,
    /// The list's material, or the scheme's (`theme.zig`, section 7).
    material: theme.Material = .solid,
};

/// A tab bar's strip under its tabs; `focused` while the bar has keyboard focus.
pub const TabBarLook = struct {
    rect: Rect,
    clip: Clip,
    focused: bool,
    /// While a drag between widgets is over a movable bar: the x of the gap a drop would
    /// land in (`widgets/tabs.zig`, section 3b).
    insert_x: ?f32 = null,
};

/// One tab: its rect, its label (cut with an ellipsis when the tab shrank), and whether it is
/// the selected or the hovered tab.
pub const TabLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    selected: bool,
    hovered: bool,
    /// A closable tab's close button, inside `rect` at its right (`widgets/tabs.zig`,
    /// section 2b), and whether the pointer is over it.
    close: ?Rect = null,
    close_hovered: bool = false,
    /// The floating copy of a tab dragged out of its bar, on the tooltip layer; its shape is
    /// not recorded.
    ghost: bool = false,
};

/// A splitter's divider: its rect across the splitter, the axis the panes are laid along, and
/// the raw hover value (1 while dragged).
pub const DividerLook = struct {
    rect: Rect,
    clip: Clip,
    axis: splitter_file.Axis,
    hover: f32,
};

/// The band under one list box row: whether the row is selected and whether it is hovered.
/// The app draws the row's content after it.
pub const ListRowLook = struct {
    rect: Rect,
    clip: Clip,
    selected: bool,
    hovered: bool,
};

/// A tree row's chevron: its cell, `turn` from 0 (pointing right, collapsed) to 1 (down,
/// expanded), and whether the pointer is on it.
pub const ChevronLook = struct {
    rect: Rect,
    clip: Clip,
    turn: f32,
    hovered: bool,
};

/// A disclosure's header: its label, the chevron's eased `turn` (0 closed, 1 open), the raw
/// hover value, and whether it has keyboard focus.
pub const DisclosureLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    turn: f32,
    hover: f32,
    focused: bool,
};

/// One column header cell: its label, `sorted` (null, or whether it sorts descending), and
/// whether the pointer is on it.
pub const HeaderCellLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    sorted: ?bool,
    hovered: bool,
};

/// A menu bar's title: its label, whether its menu is open, and whether the pointer is on it.
pub const MenuTitleLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    open: bool,
    hovered: bool,
};

/// What a window button shows: maximize turns into restore while the window is maximized.
pub const WindowButtonKind = enum(u2) {
    minimize,
    maximize,
    restore,
    close,
};

/// A window button: which one, the raw hover and press values, and whether the window is
/// activated (a skin may dim an inactive window's buttons).
pub const WindowButtonLook = struct {
    rect: Rect,
    clip: Clip,
    kind: WindowButtonKind,
    hover: f32,
    down: f32,
    active: bool,
};

/// A number box's face: the formatted value, its unit, and the raw hover value.
pub const NumberLook = struct {
    rect: Rect,
    clip: Clip,
    value_text: []const u8,
    unit: []const u8,
    hover: f32,
};

/// A shown tooltip: its placed box, the window clip, its text, and the app's fill (null: the
/// skin's own).
pub const TooltipLook = struct {
    rect: Rect,
    clip: Clip,
    label: []const u8,
    fill: ?[4]f32 = null,
};

/// The widgets a skin may cover.
pub const Kind = enum {
    button,
    slider,
    knob,
    toggle,
    checkbox,
    meter,
    panel,
    field,
    menu,
    dropdown,
    tabs,
    splitter,
    list_box,
    number_box,
    tree,
    disclosure,
    column_header,
    window_buttons,
    menu_bar,
    tooltip,
};

/// One skin function: its name, its look's type and name, and whether it returns the hit
/// shape (`?Shape`) or nothing.
const Function = struct {
    name: []const u8,
    look: []const u8,
    Look: type,
    shape: bool,
};

/// The skin functions `widget` draws with, in the order `check` reports them (section 2).
fn functions_of(comptime widget: Kind) []const Function {
    return switch (widget) {
        .button => &.{
            .{ .name = "button", .look = "ButtonLook", .Look = ButtonLook, .shape = true },
        },
        .slider => &.{
            .{ .name = "slider", .look = "SliderLook", .Look = SliderLook, .shape = true },
        },
        .knob => &.{.{ .name = "knob", .look = "KnobLook", .Look = KnobLook, .shape = true }},
        .toggle => &.{
            .{ .name = "toggle", .look = "ToggleLook", .Look = ToggleLook, .shape = true },
        },
        .checkbox => &.{
            .{ .name = "checkbox", .look = "CheckboxLook", .Look = CheckboxLook, .shape = true },
        },
        .meter => &.{.{ .name = "meter", .look = "MeterLook", .Look = MeterLook, .shape = false }},
        .panel => &.{.{ .name = "panel", .look = "PanelLook", .Look = PanelLook, .shape = false }},
        .field => &.{.{ .name = "field", .look = "FieldLook", .Look = FieldLook, .shape = false }},
        .menu => &.{
            .{ .name = "menu_face", .look = "MenuFaceLook", .Look = MenuFaceLook, .shape = false },
            .{ .name = "menu_row", .look = "MenuRowLook", .Look = MenuRowLook, .shape = false },
        },
        .dropdown => &.{
            .{ .name = "dropdown", .look = "DropdownLook", .Look = DropdownLook, .shape = true },
        },
        .tabs => &.{
            .{ .name = "tab_bar", .look = "TabBarLook", .Look = TabBarLook, .shape = false },
            .{ .name = "tab", .look = "TabLook", .Look = TabLook, .shape = true },
        },
        .splitter => &.{
            .{ .name = "divider", .look = "DividerLook", .Look = DividerLook, .shape = true },
        },
        .list_box => &.{
            .{ .name = "list_row", .look = "ListRowLook", .Look = ListRowLook, .shape = false },
        },
        .number_box => &.{
            .{ .name = "number_face", .look = "NumberLook", .Look = NumberLook, .shape = true },
            .{ .name = "field", .look = "FieldLook", .Look = FieldLook, .shape = false },
        },
        .tree => &.{
            .{ .name = "list_row", .look = "ListRowLook", .Look = ListRowLook, .shape = false },
            .{
                .name = "tree_chevron",
                .look = "ChevronLook",
                .Look = ChevronLook,
                .shape = false,
            },
        },
        .disclosure => &.{.{
            .name = "disclosure",
            .look = "DisclosureLook",
            .Look = DisclosureLook,
            .shape = true,
        }},
        .column_header => &.{.{
            .name = "header_cell",
            .look = "HeaderCellLook",
            .Look = HeaderCellLook,
            .shape = true,
        }},
        .window_buttons => &.{.{
            .name = "window_button",
            .look = "WindowButtonLook",
            .Look = WindowButtonLook,
            .shape = true,
        }},
        .menu_bar => &.{
            .{ .name = "menu_face", .look = "MenuFaceLook", .Look = MenuFaceLook, .shape = false },
            .{ .name = "menu_row", .look = "MenuRowLook", .Look = MenuRowLook, .shape = false },
            .{
                .name = "menu_title",
                .look = "MenuTitleLook",
                .Look = MenuTitleLook,
                .shape = true,
            },
        },
        .tooltip => &.{
            .{ .name = "tooltip", .look = "TooltipLook", .Look = TooltipLook, .shape = false },
        },
    };
}

/// The first reason `S` cannot skin `widget`, naming `S` and the function, or null.
pub fn check(comptime S: type, comptime widget: Kind) ?[]const u8 {
    switch (@typeInfo(S)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return @typeName(S) ++ ": a skin must be a struct type",
    }
    for (functions_of(widget)) |function| {
        const result = if (function.shape) "?widgets.Shape" else "void";
        const Result = if (function.shape) ?Shape else void;
        const shown = "pub fn " ++ function.name ++ "(cx, widgets." ++ function.look ++ ") " ++
            result;
        const params: []const ?type = &.{ null, function.Look };
        if (problem(S, function.name, params, Result, shown, result)) |message| return message;
    }
    if (widget == .tabs and @hasDecl(S, "tab_arrange")) {
        if (@TypeOf(S.tab_arrange) != tabs_file.TabArrange) {
            return @typeName(S) ++ ": `tab_arrange` must be a `widgets.TabArrange`";
        }
    }
    if (widget != .slider) return null;
    const travel = "pub fn slider_travel(area: widgets.Rect) [2]f32";
    return problem(S, "slider_travel", &.{Rect}, [2]f32, travel, "[2]f32");
}

/// The first way `S.name` differs from `params` and `Result`. A null parameter is the
/// context, which a skin may take as `anytype` or as its app's concrete type.
fn problem(
    comptime S: type,
    comptime name: []const u8,
    comptime params: []const ?type,
    comptime Result: type,
    comptime shown: []const u8,
    comptime result: []const u8,
) ?[]const u8 {
    const prefix = @typeName(S) ++ ": ";
    if (!@hasDecl(S, name)) return prefix ++ "missing `" ++ shown ++ "`";
    const info = @typeInfo(@TypeOf(@field(S, name)));
    if (info != .@"fn") return prefix ++ "`" ++ name ++ "` must be `" ++ shown ++ "`";
    const function = info.@"fn";
    if (function.param_types.len != params.len) {
        return prefix ++ "`" ++ name ++ "` must be `" ++ shown ++ "`";
    }
    for (params, function.param_types) |wanted, got| {
        const Wanted = wanted orelse continue;
        if (got != Wanted) return prefix ++ "`" ++ name ++ "` must be `" ++ shown ++ "`";
    }
    const Returned = function.return_type orelse {
        return prefix ++ "`" ++ name ++ "` must return " ++ result;
    };
    if (Returned != Result) return prefix ++ "`" ++ name ++ "` must return " ++ result;
    return null;
}

/// The unit position of `x` along `travel` (section 3), clamped to `[0, 1]`; a non-positive
/// span gives 0.
pub fn travel_value(travel: [2]f32, x: f32) f32 {
    assert(x == x);
    assert(travel[0] == travel[0]);
    const span = travel[1] - travel[0];
    if (!(span > 0)) return 0;
    const unit = std.math.clamp((x - travel[0]) / span, 0, 1);
    assert(unit >= 0);
    assert(unit <= 1);
    return unit;
}

/// `a` moved toward `b` by `amount` in `[0, 1]`, alpha included.
fn mix(a: [4]f32, b: [4]f32, amount: f32) [4]f32 {
    assert(amount >= 0);
    assert(amount <= 1);
    var out: [4]f32 = undefined;
    for (&out, a, b) |*channel, from, to| channel.* = from + (to - from) * amount;
    return out;
}

/// The chevrons' half length, in logical pixels.
const chevron_half: f32 = 4;

/// A chevron centred in `rect` turned by `turn`, in the text colour (lit while `lit`), or the
/// "+" / "−" glyph without `draw.Path`.
fn chevron_in(cx: anytype, rect: Rect, clip: Clip, turn: f32, lit: bool) void {
    assert(turn >= 0 and turn <= 1);
    assert(rect.width > 0);
    const scheme = cx.theme();
    const colors = &scheme.colors;
    const color = if (lit) mix(colors.text, colors.lighten, scheme.hover_lighten) else colors.text;
    const centre: [2]f32 = .{ rect.x + rect.width * 0.5, rect.y + rect.height * 0.5 };
    if (kit.chevron(cx, centre, chevron_half, turn, clip, color)) return;
    const sign = if (turn >= 0.5) "\u{2212}" else "+";
    var style = scheme.name;
    style.color = color;
    kit.label(cx, style, sign, rect, clip, kit.centered);
}

/// A dragged tab's ghost's opacity (`widgets/tabs.zig`).
const tab_ghost_alpha: f32 = 0.95;

/// The close button's hover band: a fixed red, as window managers draw it, whatever the scheme.
pub const close_red: [4]f32 = .{ 0.77, 0.17, 0.17, 1 };

/// A window button's hover band: its inset from the button on every side, and its radius, so it
/// sits inside a rounded title bar.
const window_band_inset: f32 = 4;
const window_band_radius: f32 = 6;

/// A window button's icon: half its side, and its stroke width.
const window_icon_half: f32 = 5;
const window_icon_stroke: f32 = 1;

/// The icon of `kind` centred in `rect` (section 4): a line, a square, two offset squares, or
/// an X, stroked one pixel wide on pixel centres; without `draw.Path`, a glyph.
fn window_icon(cx: anytype, rect: Rect, clip: Clip, kind: WindowButtonKind, color: [4]f32) void {
    assert(rect.width > 0);
    assert(color[3] >= 0);
    const x = @floor(rect.x + rect.width * 0.5) + 0.5;
    const y = @floor(rect.y + rect.height * 0.5) + 0.5;
    const h = window_icon_half - 0.5;
    const w = window_icon_stroke;
    const drawn = switch (kind) {
        .minimize => kit.stroke(cx, &.{ .{ x - h, y }, .{ x + h, y } }, clip, color, w),
        .maximize => kit.stroke(cx, &.{
            .{ x - h, y - h }, .{ x + h, y - h }, .{ x + h, y + h },
            .{ x - h, y + h }, .{ x - h, y - h },
        }, clip, color, w),
        .restore => kit.stroke(cx, &.{
            .{ x - h, y - h + 2 }, .{ x + h - 2, y - h + 2 }, .{ x + h - 2, y + h },
            .{ x - h, y + h },     .{ x - h, y - h + 2 },
        }, clip, color, w) and kit.stroke(cx, &.{
            .{ x - h + 2, y - h + 2 }, .{ x - h + 2, y - h },     .{ x + h, y - h },
            .{ x + h, y + h - 2 },     .{ x + h - 2, y + h - 2 },
        }, clip, color, w),
        .close => kit.stroke(cx, &.{ .{ x - h, y - h }, .{ x + h, y + h } }, clip, color, w) and
            kit.stroke(cx, &.{ .{ x + h, y - h }, .{ x - h, y + h } }, clip, color, w),
    };
    if (drawn) return;
    const glyph = switch (kind) {
        .minimize => "\u{2212}",
        .maximize => "+",
        .restore => "\u{00B1}",
        .close => "\u{00D7}",
    };
    var style = cx.theme().name;
    style.color = color;
    kit.label(cx, style, glyph, rect, clip, kit.centered);
}

/// A checkbox label starts at its box's left and is centred vertically, never cut.
const checkbox_text_options: text.Options = .{
    .align_x = .start,
    .align_y = .center,
    .ellipsis = false,
};

/// An outlined face (section 4): a `hairline` border in `ink` over `ink`'s rgb at an alpha
/// that is 0 at rest and grows with the hover and press weights, so a hover shows a tint of
/// the ink and a press deepens it. The fill keeps the ink's rgb, never `draw.transparent`:
/// the Box shader mixes the border toward the fill at the border's inner edge, and a black
/// fill would leave a dark fringe inside the outline. The Box's own hover and press mixes
/// still lighten and darken the whole face, border included.
fn outline(
    scheme: *const theme.Scheme,
    ink: [4]f32,
    radius: f32,
    hover: f32,
    down: f32,
) quads.BoxLook {
    assert(radius >= 0);
    assert(scheme.form.hairline > 0);
    const hover_weight = kit.weight(hover, scheme.hover_lighten);
    const down_weight = kit.weight(down, scheme.down_darken);
    var fill = ink;
    fill[3] = ink[3] * @min(1, hover_weight + down_weight);
    const look: quads.BoxLook = .{
        .fill = fill,
        .border_color = ink,
        .border_width = scheme.form.hairline,
        .radius = radius,
        .hover = hover_weight,
        .down = down_weight,
    };
    assert(look.fill[3] <= ink[3]);
    return look;
}

/// True when `scheme`'s form outlines controls (section 4).
fn outlined(scheme: *const theme.Scheme) bool {
    return scheme.form.controls == .outlined;
}

/// The library's look (section 4): `widgets.Knob` is `KnobOf(Default)`, and so on.
pub const Default = struct {
    /// The face (`Paint.look` of the two animator values), then the label inside `padding`.
    /// Outlined, the face is `outline` in the paint's colour and the label takes that colour
    /// too (the style's face and size kept). The face is the hit shape, rounded by the
    /// paint's radius.
    pub fn button(cx: anytype, look: ButtonLook) ?Shape {
        assert(look.paint.radius >= 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        var style = look.style;
        if (outlined(scheme)) {
            const ink: [4]f32 = .{ look.paint.r, look.paint.g, look.paint.b, look.paint.a };
            const face = outline(scheme, ink, look.paint.radius, look.hover, look.down);
            kit.face(cx, look.rect, look.clip, face);
            style.color = ink;
        } else {
            kit.face(cx, look.rect, look.clip, look.paint.look(scheme, look.hover, look.down));
        }
        const inner = ui.cx.inset(look.rect, look.padding);
        kit.label(cx, style, look.label, inner, look.clip, kit.centered);
        return .{ .rect = look.rect, .radius = look.paint.radius };
    }

    /// Track, then fill (omitted at value 0), then the knob on top, every face lightened by
    /// hover. The whole rect is the hit shape, rounded by `knob_radius`.
    pub fn slider(cx: anytype, look: SliderLook) ?Shape {
        assert(look.value >= 0);
        assert(look.value <= 1);
        const scheme = cx.theme();
        const track = slider_file.track_rect(look.rect);
        kit.face(cx, track, look.clip, look.track.look(scheme, look.hover, 0));
        if (look.value > 0) {
            var fill_rect = track;
            fill_rect.width = look.value * track.width;
            kit.face(cx, fill_rect, look.clip, look.fill.look(scheme, look.hover, 0));
        }
        const disc = slider_file.knob_rect(look.rect, look.value);
        kit.face(cx, disc, look.clip, look.knob.look(scheme, look.hover, 0));
        return .{ .rect = look.rect, .radius = slider_file.knob_radius };
    }

    /// The track inset by `knob_radius` at both ends: the knob's center travels over it.
    pub fn slider_travel(area: Rect) [2]f32 {
        assert(area.width == area.width);
        const travel: [2]f32 = .{
            area.x + slider_file.knob_radius,
            area.x + area.width - slider_file.knob_radius,
        };
        assert(travel[0] == area.x + slider_file.knob_radius);
        return travel;
    }

    /// A track arc over the whole sweep, the value arc over `value` of it in the accent
    /// (omitted at 0, lightened by hover), the name, and the value text. The disc inscribed
    /// in the ring is the hit shape. A row shorter than the ring draws nothing.
    pub fn knob(cx: anytype, look: KnobLook) ?Shape {
        assert(look.value >= 0);
        assert(look.value <= 1);
        if (look.row.height < look.ring) return null;
        const ring = knob_file.ring_sized(look.row, look.ring);
        const scheme = cx.theme();
        const thickness = knob_file.ring_thickness;
        kit.arc(cx, ring, look.clip, .{ .color = scheme.colors.track, .thickness = thickness });
        if (look.value > 0) {
            const accent = look.accent;
            kit.arc(cx, ring, look.clip, .{
                .color = .{ accent.r, accent.g, accent.b, accent.a },
                .thickness = thickness,
                .sweep = look.value,
                .hover = kit.weight(look.hover, scheme.hover_lighten),
            });
        }
        const centered = kit.centered;
        const name_box = knob_file.name_box(look.row, look.ring);
        kit.label(cx, scheme.name, look.name, name_box, look.clip, centered);
        const value_box = knob_file.value_box(look.row, look.ring);
        kit.label(cx, scheme.value, look.value_text, value_box, look.clip, centered);
        return .{ .rect = ring, .radius = look.ring * 0.5 };
    }

    /// The pill (`colors.track`, or outlined in `colors.control`), the thumb disc (lightened
    /// by hover, moving toward the accent with the thumb when there is one), and the name in
    /// the label column. The pill is the hit shape.
    pub fn toggle(cx: anytype, look: ToggleLook) ?Shape {
        assert(look.thumb >= 0);
        assert(look.thumb <= 1);
        const pill = toggle_file.pill_of(look.row);
        const scheme = cx.theme();
        const form = &scheme.form;
        const pill_radius = pill.height * form.capsule;
        if (outlined(scheme)) {
            const ink = scheme.colors.control;
            kit.face(cx, pill, look.clip, outline(scheme, ink, pill_radius, 0, 0));
        } else {
            kit.face(cx, pill, look.clip, .{ .fill = scheme.colors.track, .radius = pill_radius });
        }
        const thumb = toggle_file.toggle_thumb(pill, look.thumb);
        var thumb_color = scheme.colors.control;
        if (look.accent) |accent| {
            for (thumb_color[0..4], accent) |*channel, target| channel.* += (target - channel.*) * look.thumb;
        }
        const disc = kit.paint_of(thumb_color, toggle_file.thumb_side * form.capsule);
        kit.face(cx, thumb, look.clip, disc.look(scheme, look.hover, 0));
        const side_box = knob_file.side_box(look.row);
        kit.label(cx, scheme.name, look.name, side_box, look.clip, kit.centered);
        return .{ .rect = pill, .radius = pill_radius };
    }

    /// The box in `colors.track` moving toward `colors.focus` with the check (all the way when
    /// mixed), lightened by hover, its border `colors.focus` while focused, the fill once
    /// checked, and `colors.control` otherwise; then the mark in `colors.panel` at the check's
    /// alpha (a `draw.Path`, or a small square without one) or the mixed bar; then the label in
    /// the name style. Outlined, the box's fill is `colors.focus` at the check's alpha, bare
    /// while unchecked. The box and the label are the hit shape.
    pub fn checkbox(cx: anytype, look: CheckboxLook) ?Shape {
        assert(look.check >= 0);
        assert(look.check <= 1);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const box = checkbox_file.box_of(look.row);
        const amount: f32 = if (look.mixed) 1 else look.check;
        var fill = mix(colors.track, colors.focus, amount);
        if (outlined(scheme)) {
            fill = colors.focus;
            fill[3] *= amount;
        }
        const border = if (look.focused)
            colors.focus
        else
            mix(colors.control, colors.focus, amount);
        kit.face(cx, box, look.clip, .{
            .fill = fill,
            .border_color = border,
            .border_width = scheme.form.hairline,
            .radius = scheme.form.radius.control,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
        });
        var ink = colors.panel;
        if (look.mixed) {
            const bar: Rect = .{
                .x = box.x + (box.width - checkbox_file.mixed_w) * 0.5,
                .y = box.y + (box.height - checkbox_file.mixed_h) * 0.5,
                .width = checkbox_file.mixed_w,
                .height = checkbox_file.mixed_h,
            };
            const radius = checkbox_file.mixed_h * scheme.form.capsule;
            kit.face(cx, bar, look.clip, .{ .fill = ink, .radius = radius });
        } else if (look.check > 0) {
            ink[3] *= look.check;
            const points = checkbox_file.mark_points(box);
            const width = checkbox_file.mark_width;
            if (!kit.stroke(cx, &points, look.clip, ink, width)) {
                const side = checkbox_file.mark_square;
                const square: Rect = .{
                    .x = box.x + (box.width - side) * 0.5,
                    .y = box.y + (box.height - side) * 0.5,
                    .width = side,
                    .height = side,
                };
                kit.face(cx, square, look.clip, .{ .fill = ink, .radius = 1 });
            }
        }
        const label = checkbox_file.label_of(look.row);
        if (label.width > 0) {
            kit.label(cx, scheme.name, look.label, label, look.clip, checkbox_text_options);
        }
        const hit = checkbox_file.hit_of(look.row, scheme.name, look.label);
        return .{ .rect = hit, .radius = 0 };
    }

    /// The track, the fill growing up from its bottom (omitted at 0), and the name.
    pub fn meter(cx: anytype, look: MeterLook) void {
        assert(look.value >= 0);
        assert(look.value <= 1);
        const track = meter_file.meter_track_sized(look.row, look.track_h);
        const scheme = cx.theme();
        const radius = track.width * scheme.form.capsule;
        kit.face(cx, track, look.clip, .{ .fill = scheme.colors.track, .radius = radius });
        if (look.value > 0) {
            var fill = track;
            fill.height = look.value * track.height;
            fill.y = track.y + track.height - fill.height;
            kit.face(cx, fill, look.clip, .{ .fill = scheme.colors.meter, .radius = radius });
        }
        const side_box = knob_file.side_box(look.row);
        kit.label(cx, scheme.name, look.name, side_box, look.clip, kit.centered);
    }

    /// The face in the panel's paint, or glass of its material over the backdrop under it
    /// (`kit.glass`); without one, the solid face, with a `hairline` border in
    /// `colors.control` when the form is `framed`.
    pub fn panel(cx: anytype, look: PanelLook) void {
        assert(look.paint.radius >= 0);
        assert(look.rect.width > 0);
        const scheme = cx.theme();
        if (look.material.glass()) {
            const glass = kit.glass_look(scheme, look.material, look.paint.radius);
            if (kit.glass(cx, look.rect, look.clip, glass)) return;
        }
        var face = look.paint.look(scheme, 0, 0);
        if (scheme.form.framed) {
            face.border_color = scheme.colors.control;
            face.border_width = scheme.form.hairline;
        }
        kit.face(cx, look.rect, look.clip, face);
    }

    /// The face in `colors.track` with a `hairline` border, `colors.focus` while focused and
    /// `colors.control` otherwise; outlined, the bare border.
    pub fn field(cx: anytype, look: FieldLook) void {
        assert(look.rect.width > 0);
        assert(look.rect.height > 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const border = if (look.focused) colors.focus else colors.control;
        const radius = scheme.form.radius.control;
        var face: quads.BoxLook = .{
            .fill = colors.track,
            .border_color = border,
            .border_width = scheme.form.hairline,
            .radius = radius,
        };
        if (outlined(scheme)) face = outline(scheme, border, radius, 0, 0);
        kit.append(cx, quads.Box, null, quads.Box.of(look.rect, look.clip, face));
    }

    /// The popup face in `colors.panel` with a one-pixel `colors.control` border, or glass of
    /// its material over the popup layer's backdrop, which the menu marked, with a hairline in
    /// `colors.lighten` at its edge. Either way a Box comes first, so the bands draw under the
    /// labels.
    pub fn menu_face(cx: anytype, look: MenuFaceLook) void {
        assert(look.rect.width > 0);
        assert(look.rect.height > 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const form = &scheme.form;
        if (look.material.glass()) {
            const glass = kit.glass_look(scheme, look.material, form.radius.popup);
            if (kit.glass(cx, look.rect, look.clip, glass)) {
                // A hairline over the glass's edge. It is also the popup layer's first Box, as
                // the solid face is, so the rows' bands draw under their labels (a Box batch
                // that opened after a Glyph would draw over every glyph of the layer).
                var edge = colors.lighten;
                edge[3] = look.material.rim * 0.35;
                kit.face(cx, look.rect, look.clip, .{
                    .fill = quads.transparent,
                    .border_color = edge,
                    .border_width = form.hairline,
                    .radius = form.radius.popup,
                });
                return;
            }
        }
        kit.face(cx, look.rect, look.clip, .{
            .fill = colors.panel,
            .border_color = colors.control,
            .border_width = form.hairline,
            .radius = form.radius.popup,
        });
    }

    /// The highlight band in `colors.selection` (inset by `menu_band_inset`), then the label
    /// inside `menu_pad_x`, at half alpha when disabled.
    pub fn menu_row(cx: anytype, look: MenuRowLook) void {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        if (look.highlighted) {
            const band = ui.cx.inset(look.rect, .xy(menu_file.menu_band_inset, 0));
            const scheme = cx.theme();
            const fill = scheme.colors.selection;
            kit.face(cx, band, look.clip, .{ .fill = fill, .radius = scheme.form.radius.band });
        }
        var style = look.style;
        if (!look.enabled) style.color[3] *= 0.5;
        const inner = ui.cx.inset(look.rect, .xy(menu_file.menu_pad_x, 0));
        kit.label(cx, style, look.label, inner, look.clip, menu_file.menu_text_options);
    }

    /// A button-like face in `colors.track` with a `colors.control` border (`colors.focus`
    /// while the list is open), lightened by hover, or outlined in that border's colour; the
    /// label at the left, and a chevron (two `draw.Path` segments) at the right; with a glass
    /// material, `kit.glass_face`. The face is the hit shape.
    pub fn dropdown(cx: anytype, look: DropdownLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const radius = scheme.form.radius.popup;
        if (look.material.glass()) {
            var face = kit.glass_face(scheme, look.material, radius, look.hover);
            if (look.open) face.border_color = colors.focus;
            kit.face(cx, look.rect, look.clip, face);
        } else if (outlined(scheme)) {
            const ink = if (look.open) colors.focus else colors.control;
            kit.face(cx, look.rect, look.clip, outline(scheme, ink, radius, look.hover, 0));
        } else {
            kit.face(cx, look.rect, look.clip, .{
                .fill = colors.track,
                .border_color = if (look.open) colors.focus else colors.control,
                .border_width = scheme.form.hairline,
                .radius = radius,
                .hover = kit.weight(look.hover, scheme.hover_lighten),
            });
        }
        const chevron = dropdown_file.chevron_points(look.rect);
        const stroke: quads.path.Stroke = .{
            .color = colors.text,
            .width = dropdown_file.chevron_stroke,
            .hover = 0,
        };
        _ = quads.path.polyline(cx.drawing(), &chevron, stroke, look.clip);
        var inner = ui.cx.inset(look.rect, .xy(menu_file.menu_pad_x, 0));
        inner.width -= dropdown_file.chevron_room;
        if (inner.width > 0) {
            kit.label(cx, scheme.name, look.label, inner, look.clip, menu_file.menu_text_options);
        }
        return .{ .rect = look.rect, .radius = radius };
    }

    /// A one-pixel line along the bar's bottom: `colors.focus` while the bar has focus,
    /// `colors.control` otherwise, and a `tab_marker_px` insertion marker in `colors.focus`
    /// at `insert_x`, as tall as the tabs, in the gap between two. The tabs draw over it.
    pub fn tab_bar(cx: anytype, look: TabBarLook) void {
        assert(look.rect.width > 0);
        assert(look.rect.height >= tabs_file.tab_line_px);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const line: Rect = .{
            .x = look.rect.x,
            .y = look.rect.y + look.rect.height - tabs_file.tab_line_px,
            .width = look.rect.width,
            .height = tabs_file.tab_line_px,
        };
        const fill = if (look.focused) colors.focus else colors.control;
        kit.face(cx, line, look.clip, .{ .fill = fill });
        if (look.insert_x) |x| {
            const marker_px = scheme.form.mark;
            const marker: Rect = .{
                .x = x - marker_px * 0.5,
                .y = look.rect.y,
                .width = marker_px,
                .height = look.rect.height - tabs_file.tab_line_px,
            };
            kit.face(cx, marker, look.clip, .{ .fill = colors.focus });
        }
    }

    /// The tab's face (`tab_face`), the selected tab's accent underline under `tab_mark =
    /// .underline`, and the label centered inside `tab_pad_x` (before the close button's gap
    /// when closable), cut with an ellipsis, in `colors.panel` on a filled mark. A close
    /// button is a "×" over a `colors.control` band while hovered; a ghost is the face and
    /// label at `tab_ghost_alpha`, with no underline. The face is the hit shape.
    pub fn tab(cx: anytype, look: TabLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const marked = look.selected and scheme.form.tab_mark == .filled;
        var face = tab_face(scheme, look);
        var name = scheme.name;
        if (marked) name.color = colors.panel;
        if (look.ghost) {
            face.fill[3] *= tab_ghost_alpha;
            face.border_color[3] *= tab_ghost_alpha;
            name.color[3] *= tab_ghost_alpha;
        }
        kit.face(cx, look.rect, look.clip, face);
        var inner = ui.cx.inset(look.rect, .xy(tabs_file.tab_pad_x, 0));
        if (look.close) |close| {
            inner.width = @max(0, close.x - tabs_file.tab_close_gap - inner.x);
            if (look.close_hovered) {
                const band: quads.BoxLook = .{
                    .fill = colors.control,
                    .radius = scheme.form.radius.control,
                };
                kit.face(cx, close, look.clip, band);
            }
            kit.label(cx, name, "\u{d7}", close, look.clip, kit.centered);
        }
        if (inner.width > 0) {
            kit.label(cx, name, look.label, inner, look.clip, tabs_file.tab_text_options);
        }
        if (look.selected and !look.ghost and scheme.form.tab_mark == .underline) {
            const underline: Rect = .{
                .x = look.rect.x,
                .y = look.rect.y + look.rect.height - scheme.form.mark,
                .width = look.rect.width,
                .height = scheme.form.mark,
            };
            kit.face(cx, underline, look.clip, .{ .fill = scheme.accents[0] });
        }
        return .{ .rect = look.rect, .radius = scheme.form.radius.control };
    }

    /// A tab's face before the ghost's alpha: under a filled mark the selected tab is
    /// `accents[0]` (and its border, outlined); filled, `colors.panel` when selected and
    /// `colors.track` otherwise, lightened while hovered; outlined, `outline` in
    /// `colors.control`, lit while hovered.
    fn tab_face(scheme: *const theme.Scheme, look: TabLook) quads.BoxLook {
        assert(look.rect.width > 0);
        assert(scheme.form.radius.control >= 0);
        const colors = &scheme.colors;
        const radius = scheme.form.radius.control;
        const lit = look.hovered and !look.selected;
        if (look.selected and scheme.form.tab_mark == .filled) {
            const accent = scheme.accents[0];
            if (!outlined(scheme)) return .{ .fill = accent, .radius = radius };
            return .{
                .fill = accent,
                .border_color = accent,
                .border_width = scheme.form.hairline,
                .radius = radius,
            };
        }
        if (outlined(scheme)) {
            return outline(scheme, colors.control, radius, if (lit) 1 else 0, 0);
        }
        return .{
            .fill = if (look.selected) colors.panel else colors.track,
            .radius = radius,
            .hover = if (lit) scheme.hover_lighten else 0,
        };
    }

    /// A `mark`-wide line down the middle of the divider in `colors.control`, rounded by
    /// `capsule` and lightened by hover. The whole divider is the hit shape.
    pub fn divider(cx: anytype, look: DividerLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.rect.height > 0);
        const scheme = cx.theme();
        const thin = scheme.form.mark;
        const line: Rect = switch (look.axis) {
            .horizontal => .{
                .x = look.rect.x + (look.rect.width - thin) * 0.5,
                .y = look.rect.y,
                .width = @min(thin, look.rect.width),
                .height = look.rect.height,
            },
            .vertical => .{
                .x = look.rect.x,
                .y = look.rect.y + (look.rect.height - thin) * 0.5,
                .width = look.rect.width,
                .height = @min(thin, look.rect.height),
            },
        };
        kit.face(cx, line, look.clip, .{
            .fill = scheme.colors.control,
            .radius = thin * scheme.form.capsule,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
        });
        return .{ .rect = look.rect, .radius = 0 };
    }

    /// A band over the row: `colors.selection` when selected, `colors.track` when hovered,
    /// nothing otherwise.
    pub fn list_row(cx: anytype, look: ListRowLook) void {
        assert(look.rect.width > 0);
        assert(look.rect.height > 0);
        if (!look.selected and !look.hovered) return;
        const scheme = cx.theme();
        const colors = &scheme.colors;
        kit.face(cx, look.rect, look.clip, .{
            .fill = if (look.selected) colors.selection else colors.track,
            .radius = scheme.form.radius.band,
        });
    }

    /// A chevron centred in the cell in `colors.text` (lightened toward `colors.lighten` while
    /// hovered), turned by `turn` (`kit.chevron`); without `draw.Path`, "+" closed or "−" open
    /// in the name style.
    pub fn tree_chevron(cx: anytype, look: ChevronLook) void {
        assert(look.turn >= 0 and look.turn <= 1);
        assert(look.rect.width > 0);
        chevron_in(cx, look.rect, look.clip, look.turn, look.hovered);
    }

    /// The header in `colors.track` (lightened by hover) with a one-pixel `colors.focus` border
    /// while focused, the chevron in its left cell turned by `turn`, and the label in the
    /// scheme's heading style. The header is the hit shape.
    pub fn disclosure(cx: anytype, look: DisclosureLook) ?Shape {
        assert(look.turn >= 0 and look.turn <= 1);
        assert(look.rect.width > 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const radius = scheme.form.radius.control;
        kit.face(cx, look.rect, look.clip, .{
            .fill = colors.track,
            .border_color = colors.focus,
            .border_width = if (look.focused) scheme.form.hairline else 0,
            .radius = radius,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
        });
        const cell: Rect = .{
            .x = look.rect.x,
            .y = look.rect.y,
            .width = disclosure_file.disclosure_chevron_w,
            .height = look.rect.height,
        };
        chevron_in(cx, cell, look.clip, look.turn, false);
        const start = disclosure_file.disclosure_chevron_w;
        const label: Rect = .{
            .x = look.rect.x + start,
            .y = look.rect.y,
            .width = @max(0, look.rect.width - start),
            .height = look.rect.height,
        };
        if (label.width > 0) {
            kit.label(cx, scheme.heading, look.label, label, look.clip, checkbox_text_options);
        }
        return .{ .rect = look.rect, .radius = radius };
    }

    /// A `colors.track` band `menubar_band_h` high centred in the title while its menu is open
    /// (lightened) or the pointer is on it, then the label centred in the name style. The band
    /// is the hit shape.
    pub fn menu_title(cx: anytype, look: MenuTitleLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const height = @min(look.rect.height, menu_bar_file.menubar_band_h);
        const band: Rect = .{
            .x = look.rect.x,
            .y = look.rect.y + @round((look.rect.height - height) * 0.5),
            .width = look.rect.width,
            .height = height,
        };
        const radius = scheme.form.radius.band;
        if (look.open or look.hovered) {
            kit.face(cx, band, look.clip, .{
                .fill = scheme.colors.track,
                .radius = radius,
                .hover = if (look.open) scheme.hover_lighten else 0,
            });
        }
        kit.label(cx, scheme.name, look.label, look.rect, look.clip, kit.centered);
        return .{ .rect = band, .radius = radius };
    }

    /// A band inset `window_band_inset` while hovered or pressed (`colors.track`, or `close_red`
    /// for close) at the hover value's alpha, darkened by the press, then the icon
    /// (`window_icon`) in `colors.text`, white over the red band, at half alpha while the window
    /// is not activated. The button is the hit shape.
    pub fn window_button(cx: anytype, look: WindowButtonLook) ?Shape {
        assert(look.hover >= 0 and look.hover <= 1);
        assert(look.rect.width > 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const close = look.kind == .close;
        if (look.hover > 0 or look.down > 0) {
            var fill = if (close) close_red else colors.track;
            fill[3] *= @max(look.hover, look.down);
            const band = ui.cx.inset(look.rect, .all(window_band_inset));
            kit.face(cx, band, look.clip, .{
                .fill = fill,
                .radius = window_band_radius,
                .down = kit.weight(look.down, scheme.down_darken),
            });
        }
        var color = colors.text;
        if (close) color = mix(color, .{ 1, 1, 1, 1 }, look.hover);
        if (!look.active) color[3] *= 0.5;
        window_icon(cx, look.rect, look.clip, look.kind, color);
        return .{ .rect = look.rect, .radius = 0 };
    }

    /// The cell in `colors.track` (lightened while hovered), a one-pixel `colors.control` line
    /// at its right, the label at the left inside `header_pad_x`, and on the sorted column "↑"
    /// (ascending) or "↓" (descending) at the right, in the mono face (Noto Sans has no arrows).
    /// The cell is the hit shape.
    pub fn header_cell(cx: anytype, look: HeaderCellLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        kit.face(cx, look.rect, look.clip, .{
            .fill = colors.track,
            .hover = if (look.hovered) scheme.hover_lighten else 0,
        });
        const line_px = scheme.form.hairline;
        const line: Rect = .{
            .x = look.rect.x + look.rect.width - line_px,
            .y = look.rect.y,
            .width = line_px,
            .height = look.rect.height,
        };
        kit.face(cx, line, look.clip, .{ .fill = colors.control });
        var inner = ui.cx.inset(look.rect, .xy(column_header_file.header_pad_x, 0));
        if (look.sorted) |descending| {
            const arrow = if (descending) "\u{2193}" else "\u{2191}";
            const at_end: text.Options = .{
                .align_x = .end,
                .align_y = .center,
                .ellipsis = false,
            };
            // Only the mono face has the arrows; it takes the name style's size and colour.
            var style = scheme.value;
            style.size = scheme.name.size;
            style.color = scheme.name.color;
            if (inner.width > 0) kit.label(cx, style, arrow, inner, look.clip, at_end);
            inner.width -= @ceil(text.measure(style, arrow)) + 4;
        }
        if (inner.width > 0) {
            const options = column_header_file.header_text_options;
            kit.label(cx, scheme.name, look.label, inner, look.clip, options);
        }
        return .{ .rect = look.rect, .radius = 0 };
    }

    /// A field-like face (`colors.track`, a `hairline` `colors.control` border, lightened by
    /// hover; or outlined in `colors.control`), then the value in `scheme.value` and the unit
    /// in `scheme.name` at `number_unit_alpha`, right-aligned on one baseline inside
    /// `number_pad_x`. The face is the hit shape.
    pub fn number_face(cx: anytype, look: NumberLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.value_text.len >= 1);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const radius = scheme.form.radius.control;
        if (outlined(scheme)) {
            const face = outline(scheme, colors.control, radius, look.hover, 0);
            kit.face(cx, look.rect, look.clip, face);
        } else {
            kit.face(cx, look.rect, look.clip, .{
                .fill = colors.track,
                .border_color = colors.control,
                .border_width = scheme.form.hairline,
                .radius = radius,
                .hover = kit.weight(look.hover, scheme.hover_lighten),
            });
        }
        var unit_style = scheme.name;
        unit_style.color[3] *= number_box_file.number_unit_alpha;
        const runs = [_]text.Run{
            .{ .style = scheme.value, .bytes = look.value_text },
            .{ .style = unit_style, .bytes = look.unit },
        };
        const count: usize = if (look.unit.len > 0) 2 else 1;
        const inner = ui.cx.inset(look.rect, .xy(number_box_file.number_pad_x, 0));
        if (inner.width > 0) {
            const options = number_box_file.number_text_options;
            text.place_runs(cx.drawing(), runs[0..count], inner, look.clip, options);
        }
        return .{ .rect = look.rect, .radius = scheme.form.radius.control };
    }

    /// The face in `fill` or `colors.panel` with a `hairline` border in `colors.text` and
    /// `radius.popup` corners, then the label centred in the name style.
    pub fn tooltip(cx: anytype, look: TooltipLook) void {
        assert(look.label.len <= text.byte_cap);
        assert(look.clip.x1 > look.clip.x0);
        const scheme = cx.theme();
        kit.face(cx, look.rect, look.clip, .{
            .fill = look.fill orelse scheme.colors.panel,
            .border_color = scheme.colors.text,
            .border_width = scheme.form.hairline,
            .radius = scheme.form.radius.popup,
        });
        kit.label(cx, scheme.name, look.label, look.rect, look.clip, kit.centered);
    }
};

comptime {
    for (@typeInfo(Kind).@"enum".field_names) |name| {
        assert(check(Default, @field(Kind, name)) == null);
    }
}

// The names a consumer can still reach are the default form's values (section 4), and the
// deleted constants' old values are what the default form gives, so `dark` and `light` draw
// exactly what they drew before forms.
comptime {
    const form: theme.Form = .{};
    assert(field_file.field_radius == form.radius.control);
    assert(field_file.field_border_px == form.hairline);
    assert(toggle_file.pill_h * form.capsule == toggle_file.pill_radius);
    assert(meter_file.meter_track_w * form.capsule == meter_file.meter_radius);
    assert(ui.view.thumb_radius == form.radius.control);
    // tab_radius, number_radius, box_radius, disclosure_radius, and the close band were 4.
    assert(form.radius.control == 4);
    // menu_radius and tooltip_radius were 6.
    assert(form.radius.popup == 6);
    // menu_band_radius, list_row_radius, menubar_band_radius, and the dock overlay were 4.
    assert(form.radius.band == 4);
    // menu_border_px, header_line_px, and tooltip_border_px were 1.
    assert(form.hairline == 1);
    // tab_underline_px, tab_marker_px, divider_line_px, and the dock overlay's border were 2.
    assert(form.mark == 2);
    // The toggle thumb, the mixed bar, the divider, and the segments halved their side.
    assert(form.capsule == 0.5);
    assert(form.controls == .filled);
    assert(form.tab_mark == .underline);
    assert(!form.framed);
}

/// The segmented control's look (`widgets.Segmented`, `widgets/tabs.zig`, section 2a): the
/// tabs arranged `even` in a track capsule, the selected segment raised.
pub const Segmented = struct {
    pub const tab_arrange: tabs_file.TabArrange = .even;

    /// The track: a capsule in `colors.track`, bordered in `colors.focus` while focused.
    pub fn tab_bar(cx: anytype, look: TabBarLook) void {
        assert(look.rect.width > 0);
        assert(look.rect.height > 0);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        kit.face(cx, look.rect, look.clip, .{
            .fill = colors.track,
            .border_color = colors.focus,
            .border_width = if (look.focused) scheme.form.hairline else 0,
            .radius = look.rect.height * scheme.form.capsule,
        });
    }

    /// The selected segment a capsule in `colors.panel`, a hovered one the track lightened,
    /// the others bare; the label centred inside `segment_pad_x`, cut with an ellipsis. The
    /// capsule is the hit shape.
    pub fn tab(cx: anytype, look: TabLook) ?Shape {
        assert(look.rect.width > 0);
        assert(look.label.len <= text.byte_cap);
        const scheme = cx.theme();
        const colors = &scheme.colors;
        const radius = look.rect.height * scheme.form.capsule;
        if (look.selected) {
            kit.face(cx, look.rect, look.clip, .{ .fill = colors.panel, .radius = radius });
        } else if (look.hovered) {
            kit.face(cx, look.rect, look.clip, .{
                .fill = colors.track,
                .radius = radius,
                .hover = scheme.hover_lighten,
            });
        }
        const inner = ui.cx.inset(look.rect, .xy(tabs_file.segment_pad_x, 0));
        if (inner.width > 0) {
            kit.label(cx, scheme.name, look.label, inner, look.clip, tabs_file.tab_text_options);
        }
        return .{ .rect = look.rect, .radius = radius };
    }
};

const testing = std.testing;
const input = @import("../input.zig");
const fixture = @import("fixture.zig");

/// A skin that covers the knob alone.
const KnobOnly = struct {
    pub fn knob(cx: anytype, look: KnobLook) ?Shape {
        _ = cx;
        return .{ .rect = look.row, .radius = 0 };
    }
};

/// A skin whose knob returns nothing.
const Silent = struct {
    pub fn knob(cx: anytype, look: KnobLook) void {
        _ = cx;
        _ = look;
    }
};

/// A skin whose knob takes the wrong look.
const Mixed = struct {
    pub fn knob(cx: anytype, look: ButtonLook) ?Shape {
        _ = cx;
        _ = look;
        return null;
    }
};

// Locks the contract check (section 2): `Default` covers all 20 kinds; a skin covering the
// knob alone passes for the knob and names the missing `button`, `tab_bar`, and `tooltip`; a
// wrong return type and a wrong look each give their message; a slider skin needs
// `slider_travel` too, and a number box skin `field` for its editor.
test "check names the skin and the first problem" {
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        const kind = @field(Kind, name);
        try testing.expectEqual(@as(?[]const u8, null), comptime check(Default, kind));
    }
    try testing.expectEqual(@as(?[]const u8, null), comptime check(KnobOnly, .knob));
    try testing.expectEqualStrings(
        "widgets.skin.KnobOnly: missing `pub fn button(cx, widgets.ButtonLook) ?widgets.Shape`",
        comptime check(KnobOnly, .button).?,
    );
    try testing.expectEqualStrings(
        "widgets.skin.Silent: `knob` must return ?widgets.Shape",
        comptime check(Silent, .knob).?,
    );
    try testing.expectEqualStrings(
        "widgets.skin.Mixed: `knob` must be `pub fn knob(cx, widgets.KnobLook) ?widgets.Shape`",
        comptime check(Mixed, .knob).?,
    );
    const SliderOnly = struct {
        pub fn slider(cx: anytype, look: SliderLook) ?Shape {
            _ = cx;
            return .{ .rect = look.rect, .radius = 0 };
        }
    };
    const message = comptime check(SliderOnly, .slider).?;
    try testing.expect(std.mem.endsWith(
        u8,
        message,
        ": missing `pub fn slider_travel(area: widgets.Rect) [2]f32`",
    ));
    try testing.expectEqualStrings(
        "widgets.skin.KnobOnly: missing `pub fn tab_bar(cx, widgets.TabBarLook) void`",
        comptime check(KnobOnly, .tabs).?,
    );
    try testing.expectEqualStrings(
        "widgets.skin.KnobOnly: missing `pub fn tooltip(cx, widgets.TooltipLook) void`",
        comptime check(KnobOnly, .tooltip).?,
    );
    try testing.expectEqual(@as(usize, 20), @typeInfo(Kind).@"enum".field_names.len);
    const FaceOnly = struct {
        pub fn number_face(cx: anytype, look: NumberLook) ?Shape {
            _ = cx;
            return .{ .rect = look.rect, .radius = 0 };
        }
    };
    const editor = comptime check(FaceOnly, .number_box).?;
    const no_field = ": missing `pub fn field(cx, widgets.FieldLook) void`";
    try testing.expect(std.mem.endsWith(u8, editor, no_field));
    const not_struct = comptime check(u32, .meter).?;
    try testing.expectEqualStrings("u32: a skin must be a struct type", not_struct);
}

// Locks the travel map (section 3) at the worked pointer of "slider value at the worked
// pointer": rect x = 16, width = 1248, so the travel is [28, 1252] and x = 640 maps to
// (640 - 28) / 1224 = 0.5, exactly `value_at`; the stops clamp and an empty span gives 0.
test "default slider travel reproduces value_at" {
    const rect: Rect = .{ .x = 16, .y = 616, .width = 1248, .height = 24 };
    const travel = Default.slider_travel(rect);
    try testing.expectEqual([2]f32{ 28, 1252 }, travel);
    try testing.expectEqual(@as(f32, 0.5), travel_value(travel, 640));
    try testing.expectEqual(slider_file.value_at(rect, 640), travel_value(travel, 640));
    try testing.expectEqual(@as(f32, 0), travel_value(travel, 28));
    try testing.expectEqual(@as(f32, 1), travel_value(travel, 2000));
    const narrow: Rect = .{ .x = 0, .y = 0, .width = 24, .height = 24 };
    try testing.expectEqual(@as(f32, 0), travel_value(Default.slider_travel(narrow), 12));
}

/// A skin whose knob hit shape is a fixed 10 px disc at (50, 20), or nothing.
const FixedSkin = struct {
    var absent: bool = false;

    pub fn knob(cx: anytype, look: KnobLook) ?Shape {
        assert(look.value >= 0);
        if (absent) return null;
        kit.face(cx, look.row, look.clip, .{ .fill = .{ 1, 0, 0, 1 } });
        return .{ .rect = .{ .x = 50, .y = 20, .width = 20, .height = 20 }, .radius = 10 };
    }
};

// Locks the behaviour's recording: a `KnobOf(FixedSkin)` records exactly the shape the skin
// returns (a 20 px square at (50, 20), radius 10) under the knob's id and flags, and appends
// only what the skin appended; a skin returning null records no area.
test "a skinned knob records the shape its skin returns" {
    const cx = fixture.context();
    const Fixed = knob_file.KnobOf(FixedSkin);
    const knob = Fixed.init(ui.id("fixed", 0), "f", 0.5, knob_file.accents[0]);
    FixedSkin.absent = false;
    fixture.draw_one(cx, &knob, fixture.at(0, 0, 200, knob_file.knob_height));
    const area = cx.find(ui.id("fixed", 0)).?;
    try testing.expectEqualSlices(f32, &.{ 50, 20, 20, 20 }, &area.rect);
    try testing.expectEqual(@as(f32, 10), area.radius);
    try testing.expect(area.flags.wheel);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(quads.Box).len);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(quads.Arc).len);
    FixedSkin.absent = true;
    fixture.draw_one(cx, &knob, fixture.at(0, 0, 200, knob_file.knob_height));
    try testing.expect(cx.find(ui.id("fixed", 0)) == null);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(quads.Box).len);
}

// Locks routing (section 1): `ui.route` reaches a `KnobOf(FixedSkin)` field beside a default
// `Knob`, because it looks only for `handle`; a wheel up of 60 over the skinned knob's
// shape changes it by 0.5 and leaves the default knob alone.
test "ui.route reaches a skinned widget field" {
    const cx = fixture.context();
    const Fixed = knob_file.KnobOf(FixedSkin);
    const Panel = struct {
        plain: knob_file.Knob,
        skinned: Fixed,
        count: u32,
    };
    var panel: Panel = .{
        .plain = knob_file.Knob.init(ui.id("plain", 0), "p", 0.25, knob_file.accents[0]),
        .skinned = Fixed.init(ui.id("fixed", 0), "f", 0.25, knob_file.accents[1]),
        .count = 0,
    };
    FixedSkin.absent = false;
    cx.begin_frame(1280, 720, 120);
    panel.plain.draw(cx, fixture.at(0, 100, 200, knob_file.knob_height));
    panel.skinned.draw(cx, fixture.at(0, 0, 200, knob_file.knob_height));
    _ = cx.end_frame();
    const wheel: input.Event = .{ .wheel = .{ .x = 60, .y = 30, .dx = 0, .dy = -60 } };
    cx.event_begin(wheel);
    try testing.expectEqual(@as(u32, 1), ui.route(cx, wheel, &panel));
    cx.event_end();
    try testing.expectEqual(@as(f32, 0.75), panel.skinned.value);
    try testing.expectEqual(@as(f32, 0.25), panel.plain.value);
}

// Locks the optional `tab_arrange` (section 4a): a skin whose `tab_arrange` is not a
// `widgets.TabArrange` is refused by name; `Segmented` and `Default` pass.
test "check refuses a tab_arrange of the wrong type" {
    const Wrong = struct {
        pub const tab_arrange: u8 = 1;
        pub fn tab_bar(cx: anytype, look: TabBarLook) void {
            _ = cx;
            _ = look;
        }
        pub fn tab(cx: anytype, look: TabLook) ?Shape {
            _ = cx;
            _ = look;
            return null;
        }
    };
    try std.testing.expectEqualStrings(
        @typeName(Wrong) ++ ": `tab_arrange` must be a `widgets.TabArrange`",
        comptime check(Wrong, .tabs).?,
    );
    try std.testing.expect(comptime check(Segmented, .tabs) == null);
    try std.testing.expect(comptime check(Default, .tabs) == null);
}

/// `dark` with every corner square and every pill-shaped part square.
fn square_scheme() theme.Scheme {
    var scheme = theme.dark;
    scheme.form.radius = .{ .control = 0, .popup = 0, .band = 0 };
    scheme.form.capsule = 0;
    assert(scheme.form.problem() == null);
    return scheme;
}

/// `dark` with outlined controls.
fn outlined_scheme() theme.Scheme {
    var scheme = theme.dark;
    scheme.form.controls = .outlined;
    assert(scheme.form.problem() == null);
    return scheme;
}

// Locks the square form (theme.zig, section 8) through `cx.set_theme`: radius 0 on every role
// and capsule 0 draw a `TextField`'s Box and record its area with radius 0, a `Dropdown`'s too,
// a `Toggle`'s pill and thumb and a `Meter`'s track at radius 0, and a `Segmented` bar's
// segment areas at radius 0 (13 under `dark`, as `tabs.zig`'s test locks).
test "a square form draws square faces" {
    const cx = fixture.context();
    cx.set_theme(square_scheme());
    const field = field_file.TextField.init(ui.id("field", 0), 32, theme.dark.name);
    fixture.draw_one(cx, &field, fixture.at(0, 0, 200, 28));
    try testing.expectEqual(@as(f32, 0), cx.draw.items(quads.Box)[0].radius);
    try testing.expectEqual(@as(f32, 0), cx.find(field.id).?.radius);
    const items = [_][]const u8{ "one", "two" };
    const dropdown = dropdown_file.Dropdown.init(ui.id("dropdown", 0), &items, 0);
    fixture.draw_one(cx, &dropdown, fixture.at(0, 0, 200, 28));
    try testing.expectEqual(@as(f32, 0), cx.draw.items(quads.Box)[0].radius);
    try testing.expectEqual(@as(f32, 0), cx.find(dropdown.id).?.radius);
    const toggle = toggle_file.Toggle.init(ui.id("toggle", 0), "t", false);
    fixture.draw_one(cx, &toggle, fixture.at(0, 0, 200, toggle_file.toggle_height));
    const pill_and_thumb = cx.draw.items(quads.Box);
    try testing.expectEqual(@as(usize, 2), pill_and_thumb.len);
    try testing.expectEqual(@as(f32, 0), pill_and_thumb[0].radius);
    try testing.expectEqual(@as(f32, 0), pill_and_thumb[1].radius);
    const meter: meter_file.Meter = .{ .name = "m", .value = 0.5 };
    fixture.draw_one(cx, &meter, fixture.at(0, 0, 200, meter_file.meter_height));
    try testing.expectEqual(@as(f32, 0), cx.draw.items(quads.Box)[0].radius);
    const labels = [_][]const u8{ "a", "b", "c" };
    const segmented = tabs_file.TabsOf(Segmented).init(ui.id("segments", 0), &labels, 1);
    cx.begin_frame(1280, 720, 120);
    segmented.bar(cx, fixture.at(0, 0, 240, 32));
    _ = cx.end_frame();
    for (0..labels.len) |index| {
        const area = cx.find(segmented.tab_id(@intCast(index))).?;
        try testing.expectEqual(@as(f32, 0), area.radius);
    }
}

// Locks the form as CPU state (theme.zig, section 8): switching to `dark` with capsule 0 owes
// a redraw, and the draw context's GPU record stays byte-equal to `dark.record()`.
test "a form switch is a redraw" {
    const cx = fixture.context();
    cx.dirty = false;
    var scheme = theme.dark;
    scheme.form.capsule = 0;
    cx.set_theme(scheme);
    try testing.expect(cx.dirty);
    const record = theme.dark.record();
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&cx.draw.theme), std.mem.asBytes(&record)));
    try testing.expectEqual(@as(f32, 0), cx.theme().form.capsule);
}

/// The Box counts after a button (at `hover` and `down`), a number box, a checked and an
/// unchecked checkbox, and a toggle, drawn in one frame under `scheme`.
fn draw_controls(cx: *fixture.Context, scheme: theme.Scheme, hover: f32, down: f32) [5]usize {
    assert(hover >= 0 and hover <= 1);
    assert(down >= 0 and down <= 1);
    cx.set_theme(scheme);
    cx.begin_frame(1280, 720, 120);
    const clip = cx.clip().?;
    var counts: [5]usize = undefined;
    _ = Default.button(cx, .{
        .rect = .{ .x = 0, .y = 0, .width = 120, .height = 32 },
        .clip = clip,
        .label = "go",
        .style = scheme.name,
        .padding = .all(8),
        .paint = kit.paint_of(.{ 0.30, 0.46, 0.70, 1 }, 0),
        .hover = hover,
        .down = down,
    });
    counts[0] = cx.draw.items(quads.Box).len;
    _ = Default.number_face(cx, .{
        .rect = .{ .x = 0, .y = 40, .width = 120, .height = 28 },
        .clip = clip,
        .value_text = "1",
        .unit = "",
        .hover = 0,
    });
    counts[1] = cx.draw.items(quads.Box).len;
    for ([_]f32{ 1, 0 }, 2..) |checked, slot| {
        _ = Default.checkbox(cx, .{
            .row = .{ .x = 0, .y = 40 * @as(f32, @floatFromInt(slot)), .width = 200, .height = 28 },
            .clip = clip,
            .label = "c",
            .check = checked,
            .mixed = false,
            .hover = 0,
            .focused = false,
        });
        counts[slot] = cx.draw.items(quads.Box).len;
    }
    _ = Default.toggle(cx, .{
        .row = .{ .x = 0, .y = 200, .width = 200, .height = 40 },
        .clip = clip,
        .thumb = 0,
        .hover = 0,
        .name = "t",
    });
    counts[4] = cx.draw.items(quads.Box).len;
    _ = cx.end_frame();
    return counts;
}

// Locks outlined controls (section 4) on `dark`: a button painted (0.30, 0.46, 0.70, 1) is
// one Box, at rest its fill that colour at alpha 0, border the paint, `border_width` 1; at
// hover 1 fill alpha and `hover` 0.18; at hover 1 and down 1 fill alpha 0.48 and `down` 0.30;
// its glyphs in the paint. A number box's border is `colors.control` (0.78, 0.79, 0.82, 1)
// over alpha 0; a checked checkbox is filled `colors.focus` (0.40, 0.62, 0.95, 1), an
// unchecked one bare in `control`; a toggle's pill is a bare 1 px `control` border. Each
// draws as many Boxes as filled.
test "outlined controls" {
    const cx = fixture.context();
    const filled = draw_controls(cx, theme.dark, 0, 0);
    const counts = draw_controls(cx, outlined_scheme(), 0, 0);
    try testing.expectEqual(filled, counts);
    const boxes = cx.draw.items(quads.Box);
    const paint: [4]f32 = .{ 0.30, 0.46, 0.70, 1 };
    try testing.expectEqual(@as(usize, 1), counts[0]);
    try testing.expectEqual([4]f32{ 0.30, 0.46, 0.70, 0 }, boxes[0].fill);
    try testing.expectEqual(paint, boxes[0].border_color);
    try testing.expectEqual(@as(f32, 1), boxes[0].border_width);
    try testing.expectEqual(paint, cx.draw.items(quads.Glyph)[0].color);
    const number = boxes[counts[0]];
    try testing.expectEqual(theme.dark.colors.control, number.border_color);
    try testing.expectEqual([4]f32{ 0.78, 0.79, 0.82, 1 }, number.border_color);
    try testing.expectEqual(@as(f32, 0), number.fill[3]);
    try testing.expectEqual([4]f32{ 0.40, 0.62, 0.95, 1 }, boxes[counts[1]].fill);
    const unchecked = boxes[counts[2]];
    try testing.expectEqual(@as(f32, 0), unchecked.fill[3]);
    try testing.expectEqual(theme.dark.colors.control, unchecked.border_color);
    const pill = boxes[counts[3]];
    try testing.expectEqual(theme.dark.colors.control, pill.border_color);
    try testing.expectEqual(@as(f32, 0), pill.fill[3]);
    try testing.expectEqual(@as(f32, 1), pill.border_width);
    _ = draw_controls(cx, outlined_scheme(), 1, 0);
    const lit = cx.draw.items(quads.Box)[0];
    try testing.expectApproxEqAbs(@as(f32, 0.18), lit.fill[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.18), lit.hover, 1e-6);
    _ = draw_controls(cx, outlined_scheme(), 1, 1);
    const pressed = cx.draw.items(quads.Box)[0];
    try testing.expectApproxEqAbs(@as(f32, 0.48), pressed.fill[3], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.30), pressed.down, 1e-6);
}

/// One frame of `tabs`'s bar alone, 600 by 32 at the origin.
fn tab_bar_frame(cx: *fixture.Context, tabs: *const tabs_file.Tabs) void {
    cx.begin_frame(1280, 720, 120);
    tabs.bar(cx, fixture.at(0, 0, 600, 32));
    _ = cx.end_frame();
}

// Locks the tab mark (theme.zig, section 8): with `tab_mark = .filled` on `dark` the selected
// tab's Box is `accents[0]` (0.62, 0.45, 0.86, 1), its label glyphs `colors.panel` (0.16,
// 0.17, 0.20, 1), and the bar draws one Box fewer than with `.underline`; with `.underline`
// and `mark = 1` the underline is 1 high and a splitter's divider line 1 wide.
test "the selected tab is filled or underlined" {
    const cx = fixture.context();
    const labels = [_][]const u8{ "a", "b", "c" };
    const tabs = tabs_file.Tabs.init(ui.id("tabs", 0), &labels, 0);
    tab_bar_frame(cx, &tabs);
    const underlined = cx.draw.items(quads.Box).len;
    var scheme = theme.dark;
    scheme.form.tab_mark = .filled;
    cx.set_theme(scheme);
    tab_bar_frame(cx, &tabs);
    const boxes = cx.draw.items(quads.Box);
    try testing.expectEqual(underlined - 1, boxes.len);
    try testing.expectEqual([4]f32{ 0.62, 0.45, 0.86, 1 }, boxes[1].fill);
    try testing.expectEqual([4]f32{ 0.16, 0.17, 0.20, 1 }, cx.draw.items(quads.Glyph)[0].color);
    scheme = theme.dark;
    scheme.form.mark = 1;
    cx.set_theme(scheme);
    tab_bar_frame(cx, &tabs);
    try testing.expectEqual(underlined, cx.draw.items(quads.Box).len);
    try testing.expectEqual(@as(f32, 1), cx.draw.items(quads.Box)[2].rect[3]);
    try testing.expectEqual(theme.dark.accents[0], cx.draw.items(quads.Box)[2].fill);
    cx.begin_frame(1280, 720, 120);
    _ = Default.divider(cx, .{
        .rect = .{ .x = 100, .y = 0, .width = 6, .height = 300 },
        .clip = cx.clip().?,
        .axis = .horizontal,
        .hover = 0,
    });
    _ = cx.end_frame();
    try testing.expectEqual(@as(f32, 1), cx.draw.items(quads.Box)[0].rect[2]);
}

// Locks `framed` (theme.zig, section 8): on `dark` a solid panel's Box has no border; framed,
// a 1 px border in `colors.control`.
test "a framed panel has a hairline" {
    const cx = fixture.context();
    const look: PanelLook = .{
        .rect = .{ .x = 100, .y = 100, .width = 200, .height = 120 },
        .clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 },
        .paint = kit.paint_of(.{ 0.2, 0.2, 0.2, 1 }, 8),
    };
    cx.begin_frame(1280, 720, 120);
    Default.panel(cx, look);
    _ = cx.end_frame();
    try testing.expectEqual(@as(f32, 0), cx.draw.items(quads.Box)[0].border_width);
    var scheme = theme.dark;
    scheme.form.framed = true;
    cx.set_theme(scheme);
    cx.begin_frame(1280, 720, 120);
    Default.panel(cx, look);
    _ = cx.end_frame();
    const box = cx.draw.items(quads.Box)[0];
    try testing.expectEqual(theme.dark.colors.control, box.border_color);
    try testing.expectEqual(@as(f32, 1), box.border_width);
}

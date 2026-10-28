//! Gallery example: every library widget on five tabbed pages, built only from the kit.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The regression app of phases 6 and 7: each step of those phases adds a section here. It is
//! written with `widgets.kit` and the layout defaults only (one-statement containers, no Box
//! literal, no private append helper), so it is also the template for an app's own screens.
//! Every widget reports its last action on the status line, for example "knob 1 changed 0.75".
//! A "light" toggle in the title bar switches the app between `theme.dark` and `theme.light`
//! with `cx.set_theme` (section 3a). A hardware row shows the same knob, button, and toggle
//! behaviour in the gallery's own skin (section 3b). A `widgets.Tabs` bar under the title holds
//! one page per phase-6/7 section (section 2a): "basics" (steps 30 to 32, and step 41's form
//! group, section 2f), "popups" (step 33:
//! a dropdown, a "File" menu, a context menu, and an About dialog; section 3c), and
//! "containers" (step 34: splitters, a list box, and number boxes), "type" (step 36: an icon
//! face beside the library's three; step 38: wrapped text; section 2b), and "files" (step 37: a drop zone, the
//! dropped files, and a WAV's waveform; section 2c), "surfaces" (step 39: gradients, rims,
//! and shadows; section 2d), and "glass" (step 40: backdrops, glass, and materials; section
//! 2e). Tooltips show on every knob of the
//! basics page and every button of the type page's toolbar.
//!
//! ## 2. Layout (logical pixels)
//! A fixed `screen_w` by `screen_h` screen from the top-left, so it fits the 1280 by 720
//! browser viewport and a native dump and a browser screenshot compare region for region:
//! ```text
//! screen   1280 x 704 at (0, 0), flow down, padding 16, spacing 8
//!   title  fill x 40        "gallery", the "light" toggle (160 x 40 at x 156), the status
//!   tabs   fill x fill      the bar (32), then the selected page from y 104, 1248 x 584
//! basics
//!   band   fill x 152       buttons (176) | sliders (288) | knobs (fill: 4 cells of 140)
//!   band   fill x 152       toggles (176) | meter (176)   | form (fill, three columns 16 apart):
//!                           name and password fields (240) | search field and segments
//!                           (240) | three checkboxes of 28 (fill); fields 240 x 32
//!   row    fill x 88        hardware: 4 knob cells of 140 | 2 buttons of 96 | 2 toggles of 116
//!   list   fill x 168       a view of 40 rows of 28, the selected row highlighted
//! popups
//!   column 240 x fill       caption 20 | "wave" dropdown 32 | "File" button 40 | right-click
//!                           panel 120; the "flip" dropdown 224 x 32 at (24, 632), 40 px above
//!                           the frame's bottom
//!   notes  fill x fill      three lines on the overlay model
//! containers
//!   split  fill x fill      horizontal: the presets (a list box in a panel) | vertical: the
//!                           parameter grid (2 rows of 3 number boxes) over the preset panel
//! type
//!   band   fill x 92        transport (336: 5 buttons of 56 x 40) | toolbar (176: 3 of 40 x 40)
//!                           | sizes (fill: 5 cells of 64 x 48)
//!   set    fill x 84        the 14 icons at 24 px in 40 px cells
//!   faces  fill x fill      a line in each library face at 16 px, 28 px apart
//! files
//!   column 400 x fill       the drop zone (fill x 200) over the files' list box (fill x fill)
//!   wave   fill x fill      the WAV's info line (20), then its waveform (fill x fill)
//! ```
//! The frame, `(0, 0, 1280, 704)`, is the 1280 by 720 browser viewport's width and the screen's
//! height.
//! Each group is a `Panel` with padding 8 that clips its children. The knobs have rings of 56,
//! 40, 56, and 72 (`Knob.sized`) in 72 px rows, the hardware knobs 56, 48, 64, and 72; the
//! hardware row spaces its widgets by 8 and centers them vertically; the meter follows
//! slider 0.
//!
//! ## 2a. Pages
//! The tabs keep no page: `draw` opens the page under the bar (`Tabs.begin`) and draws the
//! selected one with a `switch`, so a page that is not shown records no area and its widgets'
//! `handle` sees nothing; switching pages is one redraw ("page containers"). The containers
//! page is a `widgets.Splitter` (ratio 0.25, panes at least 160 and 400 px) whose left pane is
//! a `widgets.ListBox` of 1,000 presets ("preset 0001" ...) and whose right pane is a vertical
//! splitter (ratio 0.4) of six `widgets.NumberBox`es (frequency 20 to 20000 Hz, gain -60 to 12
//! dB, attack, release, q, mix) over a panel naming the selected preset and the last activated
//! one. Each reports on the status line: "split 0.15", "preset 0024 selected", "frequency
//! 4436.0 Hz", "gain = -6.5 dB" (a typed value).
//!
//! ## 2b. Type
//! The gallery adds one face, `icons`: Lucide (`icons.zig`, `fonts/lucide.ttf`), which
//! `build.zig` passes in `AppOptions.fonts` subset to the 14 icons `icons.zig` names, so
//! `text.Face` here has a fourth tag. The type page's buttons are `widgets.ButtonOf(IconSkin)`:
//! the default face, then the label's one codepoint drawn with `text.icon` at 18 px, its ink
//! centred in the button whatever the icon's advance and baseline. The transport (skip back,
//! play, stop, record, loop) reports "transport play"; play toggles to pause and back, and stop
//! shows play again. The toolbar (open, save, settings) reports "toolbar save", and each of its
//! buttons shows a tooltip. The size ladder draws the settings icon at 12, 16, 24, 32, and 48
//! px, each centred in a cell, and the icon set every icon at 24 px; no hinting, so the
//! smallest is soft. Last, a horizontal `widgets.Splitter` (ratio 0.5, panes at least 240 and
//! 200 px; step 38): a line in each Noto face, which stays one line and is cut at the pane's
//! edge, beside a panel of wrapped text: three bullets, each a bold lead and the rest as two
//! runs wrapped with `text.place_runs_wrapped` beside a dot, and a `widgets.Paragraph` whose fit
//! height is the height of its lines. Under the caption they sit in a view, which measures
//! those heights and scrolls (wheel or thumb) when the pane or the window is too small to show
//! them; when they fit there is no thumb. Moving the divider reports "type split 0.31".
//!
//! ## 2c. Files
//! The files page is `files.zig`: one area flagged `drop` (step 37) over a panel that highlights
//! its border in the accent while a file drag is over it (`cx.drop_hovering`); the dropped
//! files in a `ListBox` with their sizes and statuses ("reading 42%", "done", "folder", "cut at
//! 21.8 s"); and the first WAV among them, decoded chunk by chunk (`wav.zig`) into one
//! `samples_max` buffer and drawn as a `draw.Waveform` from a `wave.Pyramid`. A WAV longer than
//! the buffer cancels itself (`cx.cancel_files`); the other files are counted, not stored. The
//! status line reports "drop 3 files", "file tone.wav done", "file long.wav cut", and "drop on
//! nothing".
//!
//! ## 2d. Surfaces
//! The surfaces page is `surfaces.zig`: a music-player-like screen of `draw.Surface`s alone, a
//! faint gradient backdrop, a glass-like side panel and pill bar (translucent fill, rim-lit
//! border, shadow; no blur), and six cards, each a diagonal gradient, a radial highlight, and a
//! label pill, with shadows. Its colours come from the theme (muted cards in dark, pale tints in
//! light), so the light toggle restyles it. Its surfaces draw on layer 1 and its text on
//! layer 2, so the labels sit on the faces although the title bar put `Glyph` first. The pills,
//! rows, and cards are clickable (`surfaces.zig`, section 1a): a pill or row becomes the
//! selection ("pill Radio", "row Browse"), a card is named ("card Slate"), and each lights on
//! hover and darkens on press through `kit.lit`.
//!
//! ## 2e. Glass
//! The glass page is `glass.zig`: sixteen album cards (gradients between the scheme's accents)
//! scroll in a view under a glass sidebar (`widgets.Panel` with the page's material), a
//! segmented bar that picks that material (Clear, Frosted, Tinted, Solid; "material Clear"),
//! and a transport bar. The page marks backdrop A at layer 3 for the material; its text sits on
//! layer 4. The sidebar's output `widgets.Dropdown` opens a glass list on the popup layer
//! ("output Headphones"), which marks backdrop B, so the list blurs the sidebar under it. The
//! transport's position slider is `widgets.SliderOf(glass.LensSkin)`: its knob is a clear glass
//! disc on the popup layer, a lens over the track ("position 0.62"). Solid marks no backdrop A
//! and draws solid faces.
//!
//! ## 2f. Form
//! The basics page's third group (step 41) holds the form controls in three columns: the name
//! field (hint "untitled") over a secret password field (a lock icon, hint "password"); a
//! search field (a search icon, hint "search presets") over a `widgets.Segmented` bar (Sine,
//! Saw, Square) drawn with `bar`; and three `widgets.Checkbox`es, "loop", "sync" (on), and "all
//! voices" (mixed). The two icons are Lucide codepoints kept by the icons face beside the type
//! page's set (`icons.fields`). The status line reports "password changed" (never its text),
//! "search saw", "wave Saw", and "checkbox 0 on".
//!
//! ## 3. Events
//! `event` hands every event to each widget itself, because the status line needs each
//! action (`ui.route` returns only how many acted), then to the view (it takes its id), then
//! to the rows it drew last through `kit.clicked`, which also repaints a row on hover, then to
//! the form group (`form_events`), the popups (`popup_events`) and to the tabs and the containers page (`container_events`; the
//! list box routes its own view). The default and hardware rows share one routine per widget
//! kind (`knob_events`, ...), since a skinned widget has the default one's behaviour and
//! actions.
//!
//! ## 3a. Theme
//! Everything the gallery draws reads `cx.theme()`: the group faces, the text styles, the
//! highlighted rows, and the widgets themselves. Colors stored in widgets (the sliders'
//! paints, the knobs' accents, the field's text style) are restyled from the scheme when the
//! toggle switches it (`restyle`), so they follow it too. The buttons keep their own blue
//! paint and light label in both themes: an instance color wins over the scheme.
//!
//! ## 3b. Hardware Skin
//! `HardKnob`, `HardButton`, and `HardToggle` are `widgets.KnobOf(hardware.Skin)` and its
//! siblings: the library behaviour with the look of `hardware.zig` (a `Dial` with a drop
//! shadow, `Bevel` faces, the rack's `Led`), registered in `config.draw`. They take presses on
//! the dial's body, the bevel, and the housing, and report as "hardware knob 0 changed 0.83".
//! Their accents are restyled with the default knobs'.
//!
//! ## 3c. Popups
//! The popups draw last: `draw` ends with `ui.overlays(cx, app)`, which reaches the two
//! dropdowns, the File menu, the context menu, the About dialog, and the tooltip, in field
//! order. Each popup is placed inside `frame` (`bounds`), not the window, because the native
//! window is larger than the frame and the compositor picks its size, which would move a popup
//! that flips at the window's edge. The "flip" dropdown sits 40 px above the frame's bottom, so
//! its list opens above it. The File menu holds New, Open…, Save, Save as… (disabled),
//! About…, and Quit; About… opens a modal dialog centered in the frame over a dimmed backdrop,
//! closed by its Close button or Escape. A right press on the panel opens the context menu
//! (Copy, Paste, Reset) at the pointer. Hovering any knob, default or hardware, for
//! `widgets.tooltip_delay_ms` shows "name value" beside its ring. An outside press only
//! dismisses: the dropdown under it does not open.
//!
//! ## 4. Scenarios
//! `still`; `interact` (click button 0, drag slider 0 by +80 px, click toggle 1, drag knob 1
//! by -30 px, click the field and type "abc", wheel the list by 3 rows, click row 5, then let
//! the animations settle); `hover` (hover button 1, then wait for its animator to settle);
//! `light` (click the "light" toggle, click the field, type "abc", select it by dragging
//! across it, then wait for the animations to settle, so the light theme shows the focus ring,
//! the selection band, and the caret); `hardware` (drag hardware knob 0 up 40 px, click
//! hardware button 1, flip hardware toggle 0, then settle). Popups (section 3c): `dropdown`
//! (click the wave dropdown, Down twice, Enter: "dropdown changed 2", closed); `menu-open`
//! (click File, wait 2); `menu-flip` (click the flip dropdown, wait 2: its list above it);
//! `context` (right-click the panel, click Reset); `dismiss` (open the File menu, click the
//! wave dropdown through the backdrop: it does not open, the menu closed); `tooltip` (hover
//! knob 0 for 40 frames); `about` (choose About… from the File menu: the dialog over the dimmed
//! screen); each popup scenario but `tooltip` first clicks the popups tab. Containers (section
//! 2a): `tabs` (click each tab in turn, ending on containers); `split` (drag the presets'
//! divider 120 px left); `list` (click preset row 3, then Down 20 times: preset 0024 scrolled
//! into view); `number` (drag the frequency up 40 px, double-click the gain, type "-6.5",
//! Enter). Type (section 2b): `type` (the type page, still); `wrap` (the
//! type divider dragged 240 px left: the wrapped text widens); `wrap-narrow` (dragged right to
//! the wrapped pane's 200 px minimum: "antidisestablishmentarianism" breaks between letters);
//! `wrap-scroll` (that, then the wheel over the wrapped text: scrolled to its end);
//! `transport` (click play: its icon
//! is pause). Files (section 2c): `files` (the files page, empty); `drop-hover` (files dragged
//! over the zone: its border lit); `drop` (three files dropped on the zone: `tone.wav`, 96,044
//! bytes of a 120 Hz tone in two chunks, `readme.txt`, and a folder: the tone's waveform).
//! Surfaces (section 2d): `surfaces` (the surfaces page, still); `surfaces-click` (click the
//! Radio pill, the Browse row, and the Slate card, then rest on Moss: lit); `surfaces-light`
//! (the light toggle, then the page: restyled from the light scheme). Glass (section 2e):
//! `glass` (the page, still: frosted); `glass-scroll` (scrolled 120 px, then the wheel 24 px
//! down and back up every frame: a scroll under the glass each frame, for benches);
//! `glass-popup` (the output list open over the sidebar, Down pressed: row 1 highlighted); `glass-clear` (the Clear segment);
//! `glass-light` (the light toggle, then the page). Form (section 2f): `form` (click Saw, tick
//! "loop", click the password field and type "hunter2": seven bullets and the caret);
//! `form-search` (click the mixed "all voices": on; click the search field and type "saw": the
//! hint gone, the text after the icon). The
//! app tests replay all but `still` and `hover` headless (`number` a 60 Hz frame
//! apart, so its two clicks are a double click as in regress) and check every value they
//! leave.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed widget arrays, a fixed status buffer, and no allocation; every loop is bounded.
//! - The comptime block checks the layout arithmetic and the capacities.

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
const bench = patchwork.bench;
const hardware = @import("hardware.zig");
const icons = @import("icons.zig");
const files_page = @import("files.zig");
const surfaces_page = @import("surfaces.zig");
const glass_page = @import("glass.zig");

const Rect = quads.Rect;

const screen_w: f32 = 1280;
const screen_h: f32 = 704;
const screen_padding: f32 = 16;
const gap_px: f32 = 8;
const title_px: f32 = 40;
const band_px: f32 = 152;
const hardware_px: f32 = 88;
const group_padding: f32 = 8;
const narrow_px: f32 = 176;
const sliders_px: f32 = 288;
const knob_cell_px: f32 = 140;
const hard_button_px: f32 = 96;
const hard_toggle_px: f32 = 116;
const button_px: f32 = 40;
const slider_px: f32 = 24;
const caption_px: f32 = 20;
const field_w: f32 = 240;
const field_h: f32 = 32;
const meter_track_px: f32 = 120;
const row_px: f32 = 28;
const row_count: u32 = 40;
/// Where every page starts: under the title, the tab bar, and a gap.
const page_y: f32 = screen_padding + title_px + gap_px + widgets.tab_bar_h + gap_px;
/// The page's height: the rest of the screen inside its padding.
const page_h: f32 = screen_h - screen_padding - page_y;
const row_inset_px: f32 = 12;
const title_inset_px: f32 = 12;
const status_cap: u32 = 48;

/// The frame popups stay inside (section 3c): the screen.
const frame_w: f32 = screen_w;
const frame_rect: Rect = .{ .x = 0, .y = 0, .width = frame_w, .height = screen_h };
/// The popups page's column.
const popups_w: f32 = 240;
const dropdown_h: f32 = 32;
const scratch_px: f32 = 120;
/// The flip dropdown's bottom is this far above the frame's.
const flip_margin_px: f32 = 40;
const about_size: [2]f32 = .{ 320, 136 };
const about_close_size: [2]f32 = .{ 96, 36 };
/// The About dialog's backdrop alpha.
const about_dim: f32 = 0.4;

const knob_rings = [_]f32{ 56, 40, 56, 72 };
const knob_names = [_][]const u8{ "gain", "tone", "mix", "drive" };
const knob_values = [_]f32{ 0.25, 0.5, 0.75, 0.6 };
const button_labels = [_][]const u8{ "Play", "Stop", "Record" };
const slider_names = [_][]const u8{ "level", "pan" };
const slider_values = [_]f32{ 0.25, 0.5 };
const toggle_names = [_][]const u8{ "mute", "solo", "arm" };
const toggle_values = [_]bool{ false, true, false };

const hard_knob_rings = [_]f32{ 56, 48, 64, 72 };
const hard_knob_names = [_][]const u8{ "freq", "res", "env", "level" };
const hard_knob_values = [_]f32{ 0.5, 0.3, 0.7, 0.85 };
const hard_button_labels = [_][]const u8{ "Tap", "Sync" };
const hard_toggle_names = [_][]const u8{ "power", "bypass" };
const hard_toggle_values = [_]bool{ false, true };

const wave_items = [_][]const u8{ "sine", "triangle", "saw", "square", "noise", "sample & hold" };
const file_items = [_][]const u8{ "New", "Open…", "Save", "Save as…", "About…", "Quit" };
const file_disabled: u32 = 3;
const file_about: u32 = 4;
const context_items = [_][]const u8{ "Copy", "Paste", "Reset" };

/// The form group (section 2): two columns of `form_column_w` and the checkboxes, 16 apart.
const form_column_w: f32 = 240;
const form_gap_px: f32 = 16;
const checkbox_names = [_][]const u8{ "loop", "sync", "all voices" };
const checkbox_values = [_]bool{ false, true, false };
/// The checkbox that starts mixed: a parent of differing children.
const checkbox_mixed: u32 = 2;
const segment_labels = [_][]const u8{ "Sine", "Saw", "Square" };

/// The hardware row's widgets: the library behaviour in the gallery's skin (`hardware.zig`).
const HardKnob = widgets.KnobOf(hardware.Skin);
const HardButton = widgets.ButtonOf(hardware.Skin);
const HardToggle = widgets.ToggleOf(hardware.Skin);

/// The type page's buttons (section 2b): the library behaviour, the default face, and an icon.
const IconButton = widgets.ButtonOf(IconSkin);

/// The icon buttons' skin (section 2b): the default face, then the label's one codepoint in the
/// label style's face and size, its ink centred in the button (`text.icon`).
const IconSkin = struct {
    pub fn button(cx: anytype, look: widgets.ButtonLook) ?widgets.Shape {
        assert(look.label.len == 3);
        assert(look.style.size > 0);
        kit.face(cx, look.rect, look.clip, look.paint.look(cx.theme(), look.hover, look.down));
        const codepoint = std.unicode.utf8Decode(look.label) catch unreachable;
        kit.icon(cx, look.style.face, codepoint, look.style.size, look.rect, look.clip, look.style.color);
        return .{ .rect = look.rect, .radius = look.paint.radius };
    }
};

/// The slider the meter follows.
const meter_slider: u32 = 0;

const view_id = ui.id("view", 0);
const field_id = ui.id("field", 0);
const password_id = ui.id("password", 0);
const search_id = ui.id("search", 0);
const segments_id = ui.id("segments", 0);
const theme_id = ui.id("theme", 0);
const wave_id = ui.id("wave", 0);
const flip_id = ui.id("flip", 0);
const file_id = ui.id("file", 0);
const file_menu_id = ui.id("file_menu", 0);
const scratch_id = ui.id("scratch", 0);
const context_id = ui.id("context", 0);
const about_id = ui.id("about", 0);
const close_id = ui.id("close", 0);
const tabs_id = ui.id("tabs", 0);
const split_id = ui.id("split", 0);
const side_id = ui.id("side", 0);
const type_split_id = ui.id("type_split", 0);
const wrap_view_id = ui.id("wrap_view", 0);
const presets_id = ui.id("presets", 0);

/// The pages (section 2a), in tab order.
const page_labels = [_][]const u8{ "basics", "popups", "containers", "type", "files", "surfaces", "glass" };
const page_basics: u32 = 0;
const page_popups: u32 = 1;
const page_containers: u32 = 2;
const page_type: u32 = 3;
const page_files: u32 = 4;
const page_surfaces: u32 = 5;
const page_glass: u32 = 6;

/// The type page (section 2b): the icon buttons' icon size and boxes, the size ladder, the
/// icon set, and the face lines.
const icon_px: f32 = 18;
const transport_w: f32 = 336;
const transport_button_w: f32 = 56;
const tool_button_w: f32 = 40;
const ladder_sizes = [_]f32{ 12, 16, 24, 32, 48 };
const ladder_cell_w: f32 = 64;
const ladder_cell_h: f32 = 48;
/// The band: a caption, a gap, and a row of ladder cells inside the panel's padding.
const type_band_px: f32 = 2 * group_padding + caption_px + gap_px + ladder_cell_h;
const set_icon_px: f32 = 24;
const set_cell_px: f32 = 40;
const set_px: f32 = 2 * group_padding + caption_px + gap_px + set_cell_px;
const face_line_px: f32 = 28;
/// The type page's splitter (step 38): the face lines | the wrapped text, half and half.
const type_split_ratio: f32 = 0.5;
const type_split_min_a: f32 = 240;
const type_split_min_b: f32 = 200;
/// A bullet's gutter, and its dot centred on the first line.
const bullet_gutter_px: f32 = 16;
const bullet_dot_px: f32 = 4;
const wrap_size: f32 = 16;
const wrap_words =
    "Text in a paragraph wraps to the width it is given: at spaces, after hyphens, and at a " ++
    "new line. Drag the divider to the left and the lines grow; drag it to the right and they " ++
    "shrink, while the face lines beside it keep their single line and are cut at the pane's edge.";
/// The bullets: a bold lead and the rest, one block of runs each.
const bullets = [_][2][]const u8{
    .{ "Spaces", " at the end of a line hang outside it, so a centred or right-aligned line ends at its last letter." },
    .{ "Hyphens", " allow a break after them, but a minus before a digit stays with it: -6.5 never splits." },
    .{ "Long words", " such as antidisestablishmentarianism break between letters when nothing else fits." },
};
const transport_icons = [_]u21{ icons.skip_back, icons.play, icons.stop, icons.record, icons.loop };
const transport_names = [_][]const u8{ "skip back", "play", "stop", "record", "loop" };
const transport_play: u32 = 1;
const transport_stop: u32 = 2;
const transport_record: u32 = 3;
const tool_icons = [_]u21{ icons.folder_open, icons.save, icons.settings };
const tool_names = [_][]const u8{ "open", "save", "settings" };
const tool_tips = [_][]const u8{ "Open…", "Save", "Settings" };
/// The record button's icon: a red that reads on the buttons' blue in both themes.
const record_color: [4]f32 = .{ 0.95, 0.42, 0.42, 1 };
const face_lines = [_]struct { face: text.Face, words: []const u8 }{
    .{ .face = .sans, .words = "Noto Sans: The quick brown fox jumps over the lazy dog. 0123456789" },
    .{ .face = .sans_bold, .words = "Noto Sans Bold: The quick brown fox jumps over the lazy dog." },
    .{ .face = .mono, .words = "Noto Sans Mono: fn main() !void { return; } // 0O 1lI" },
};

/// `codepoints` as UTF-8, the icon buttons' labels: every icon is in the Private Use Area, three
/// bytes each.
fn utf8_of(comptime codepoints: []const u21) [codepoints.len][3]u8 {
    var out: [codepoints.len][3]u8 = undefined;
    for (codepoints, &out) |codepoint, *bytes| {
        const length = std.unicode.utf8Encode(codepoint, bytes) catch unreachable;
        assert(length == 3);
    }
    return out;
}

const transport_labels = utf8_of(&transport_icons);
const tool_labels = utf8_of(&tool_icons);
const pause_label = utf8_of(&.{icons.pause});

/// The containers page (section 2a): 1,000 presets in a list box beside a splitter of six
/// number boxes over a panel naming the selected preset.
const preset_count: u32 = 1000;
const preset_row_px: f32 = 28;
/// Rows the presets' viewport (at most the page less the panel's padding) shows partly.
const preset_rows_max: u32 = 22;
const split_ratio: f32 = 0.25;
const split_min_a: f32 = 160;
const split_min_b: f32 = 400;
const side_ratio: f32 = 0.4;
const side_min_b: f32 = 96;
/// A parameter cell: its caption, a gap, and the box.
const param_gap_px: f32 = 4;
const param_row_px: f32 = caption_px + param_gap_px + field_h;
/// The parameter grid's height: two rows, a gap, and the panel's padding.
const params_h: f32 = 2 * param_row_px + gap_px + 2 * group_padding;
const param_names = [_][]const u8{ "frequency", "gain", "attack", "release", "q", "mix" };
/// Each parameter: its value, range, step, decimals, and unit.
const Param = struct { value: f64, min: f64, max: f64, step: f64, format: widgets.NumberFormat };
const params = [_]Param{
    .{ .value = 440, .min = 20, .max = 20000, .step = 0, .format = .{ .decimals = 1, .unit = " Hz" } },
    .{ .value = 0, .min = -60, .max = 12, .step = 0.1, .format = .{ .decimals = 1, .unit = " dB" } },
    .{ .value = 10, .min = 0, .max = 2000, .step = 1, .format = .{ .decimals = 0, .unit = " ms" } },
    .{ .value = 200, .min = 0, .max = 5000, .step = 1, .format = .{ .decimals = 0, .unit = " ms" } },
    .{ .value = 0.71, .min = 0.1, .max = 10, .step = 0.01, .format = .{ .decimals = 2, .unit = "" } },
    .{ .value = 50, .min = 0, .max = 100, .step = 1, .format = .{ .decimals = 0, .unit = " %" } },
};
/// Bytes of a preset's name: "preset 0001".
const preset_name_cap: u32 = 11;
/// The selected preset's name line.
const preset_title_px: f32 = 32;
/// The popups page's notes beside its column.
const popup_notes = [_][]const u8{
    "Menus, lists, and dialogs draw last, on the popup layer.",
    "A press outside a popup only closes it.",
    "Hover a knob on the basics page for its tooltip.",
};

/// The "light" toggle's box in the title bar: right of "gallery", one toggle row high.
const theme_toggle_x: f32 = 156;
const theme_toggle_w: f32 = 160;

const panel_radius: f32 = 8;
const button_paint: widgets.Paint = .{ .r = 0.30, .g = 0.46, .b = 0.70, .a = 1, .radius = 8 };
/// The buttons' label: the dark scheme's text in both themes, on their own blue (section 3a).
const button_style: text.Style = .{ .face = .sans, .size = 16, .color = theme.dark.colors.text };
/// The hardware buttons' bevel face: a dark grey that keeps its light label readable in both
/// themes.
const hard_button_paint: widgets.Paint = .{ .r = 0.32, .g = 0.34, .b = 0.38, .a = 1, .radius = 6 };

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };

/// The rows: 40 of 28 px in the list's view.
const rows: ui.List = .{ .row_height = row_px, .count = row_count };
/// Rows one viewport can show partly: `ceil(152 / 28) + 1`.
const rows_drawn_max: u32 = 7;

/// Pool and area capacities; the comptime block checks them against the counts.
const box_cap: u32 = 64;
const arc_cap: u32 = 16;
const glyph_cap: u32 = 2048;
/// The surfaces page: the backdrop, the panel and a row, the bar and a pill, and three per
/// card; the glass page: its gradient and two per card.
const surface_cap: u32 = 40;
/// The glass page: the sidebar, the bar, the transport, the lens, and the output list.
const glass_cap: u32 = 8;
const path_cap: u32 = 4;
const point_cap: u32 = 2048;
const dial_cap: u32 = 8;
const bevel_cap: u32 = 8;
const led_cap: u32 = 4;
const area_cap: u32 = 56;

/// A page under the tab bar: flowing down, a gap below the bar.
const page_layout: ui.Layout = .{ .flow = .down, .spacing = gap_px, .padding = .sides(0, gap_px, 0, 0) };

const Context = patchwork.app.Context(App);

/// A group: a panel face with padding that clips its children, flowing down.
const group_layout: ui.Layout = .{
    .flow = .down,
    .spacing = gap_px,
    .padding = .all(group_padding),
    .clip = true,
};

/// The gallery. `timer_period_ms` is 0: nothing wakes the host while the pointer rests.
pub const App = struct {
    /// The title bar's "light" toggle: on is `theme.light`.
    light: widgets.Toggle,
    /// The pages (section 2a); the app draws the selected one.
    tabs: widgets.Tabs,
    buttons: [button_labels.len]widgets.Button,
    sliders: [slider_names.len]widgets.Slider,
    knobs: [knob_names.len]widgets.Knob,
    toggles: [toggle_names.len]widgets.Toggle,
    hard_knobs: [hard_knob_names.len]HardKnob,
    hard_buttons: [hard_button_labels.len]HardButton,
    hard_toggles: [hard_toggle_names.len]HardToggle,
    meter: widgets.Meter,
    field: widgets.TextField,
    /// The form group (section 2): a secret field, a search field, a segmented control, and
    /// checkboxes.
    password: widgets.TextField,
    search: widgets.TextField,
    segments: widgets.Segmented,
    checkboxes: [checkbox_names.len]widgets.Checkbox,
    /// The popups column (section 3c). Overlays draw in this field order.
    wave: widgets.Dropdown,
    flip: widgets.Dropdown,
    file: widgets.Button,
    file_menu: widgets.Menu,
    context: widgets.ContextMenu,
    about: About,
    tooltip: widgets.Tooltip,
    /// The containers page (section 2a).
    split: widgets.Splitter,
    side: widgets.Splitter,
    presets: widgets.ListBox,
    params: [param_names.len]widgets.NumberBox,
    /// The preset last activated (a double click or Enter).
    activated: ?u32,
    /// The type page (section 2b): the transport, playing or not, and the toolbar.
    transport: [transport_icons.len]IconButton,
    playing: bool,
    tools: [tool_icons.len]IconButton,
    /// The surfaces page (section 2d): its selections and its clickables' animators.
    surfaces: surfaces_page.Page,
    /// The glass page (section 2e): its material, cards' view, output dropdown, and lens.
    glass: glass_page.Page,
    /// The face lines | the wrapped text (step 38), which scrolls when it does not fit.
    type_split: widgets.Splitter,
    wrap_view: ui.ViewState,
    /// The files page (section 2c): the drop zone, the dropped files, and a WAV's samples.
    drops: files_page.Page,
    view: ui.ViewState,
    /// The rows drawn last, which `event` routes.
    drawn: ui.List.Range,
    selected: ?u32,
    status: [status_cap]u8,
    status_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork gallery",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = hardware.Dial, .cap = dial_cap },
            .{ .type = hardware.Bevel, .cap = bevel_cap },
            .{ .type = hardware.Led, .cap = led_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = quads.Waveform, .cap = 1 },
            .{ .type = quads.Surface, .cap = surface_cap },
            .{ .type = quads.Glass, .cap = glass_cap },
        },
        .area_cap = area_cap,
        .point_cap = point_cap,
    };

    pub const scenarios: []const bench.Scenario = &.{
        .{ .name = "still", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 60 },
        .{ .name = "interact", .setup = &interact_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hover", .setup = &hover_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "light", .setup = &light_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "hardware", .setup = &hardware_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dropdown", .setup = &dropdown_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "menu-open", .setup = &menu_open_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "menu-flip", .setup = &menu_flip_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "context", .setup = &context_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "dismiss", .setup = &dismiss_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "tooltip", .setup = &tooltip_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "about", .setup = &about_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "tabs", .setup = &tabs_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "split", .setup = &split_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "list", .setup = &list_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "number", .setup = &number_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "type", .setup = &type_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "transport", .setup = &transport_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "wrap", .setup = &wrap_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "wrap-narrow", .setup = &wrap_narrow_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "wrap-scroll", .setup = &wrap_scroll_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "files", .setup = &files_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "drop-hover", .setup = &drop_hover_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "drop", .setup = &drop_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "surfaces", .setup = &surfaces_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "surfaces-click", .setup = &surfaces_click_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "surfaces-light", .setup = &surfaces_light_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "glass", .setup = &glass_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "glass-scroll", .setup = &glass_scroll_steps, .cycle = &glass_scroll_cycle, .frames = 30 },
        .{ .name = "glass-popup", .setup = &glass_popup_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "glass-clear", .setup = &glass_clear_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "glass-light", .setup = &glass_light_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "form", .setup = &form_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{ .name = "form-search", .setup = &form_search_steps, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
    };

    /// The widgets at their starting values, styled from `config.theme`; the gallery creates
    /// no textures.
    pub fn init(app: *App, textures: *quads.Textures) void {
        assert(textures.count >= 1);
        app.light = widgets.Toggle.init(theme_id, "light", false);
        app.tabs = widgets.Tabs.init(tabs_id, &page_labels, page_basics);
        app.split = widgets.Splitter.init(split_id, .horizontal, split_ratio, split_min_a, split_min_b);
        app.side = widgets.Splitter.init(side_id, .vertical, side_ratio, params_h, side_min_b);
        app.presets = widgets.ListBox.init(presets_id, preset_count, preset_row_px);
        for (&app.params, params, 0..) |*number, param, index| {
            number.* = widgets.NumberBox.init(ui.id("param", @intCast(index)), param.value, param.min, param.max, param.step, param.format);
        }
        app.activated = null;
        for (&app.transport, &transport_labels, 0..) |*button, *label, index| {
            const color = if (index == transport_record) record_color else button_style.color;
            button.* = icon_button(ui.id("transport", @intCast(index)), label, transport_button_w, color);
        }
        app.playing = false;
        app.type_split = widgets.Splitter.init(type_split_id, .horizontal, type_split_ratio, type_split_min_a, type_split_min_b);
        app.wrap_view = ui.ViewState.init();
        app.surfaces.init();
        app.glass.init(frame_rect);
        app.drops.init();
        for (&app.tools, &tool_labels, 0..) |*button, *label, index| {
            button.* = icon_button(ui.id("tool", @intCast(index)), label, tool_button_w, button_style.color);
        }
        for (&app.buttons, button_labels, 0..) |*button, label, index| {
            button.* = .{
                .id = ui.id("button", @intCast(index)),
                .label = label,
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            };
        }
        for (&app.sliders, slider_values, 0..) |*slider, value, index| {
            slider.* = .{
                .id = ui.id("slider", @intCast(index)),
                .hover = .init(widgets.hover_rate_per_ms),
                .value = value,
                .track = undefined,
                .fill = undefined,
                .knob = undefined,
            };
        }
        for (&app.knobs, knob_names, knob_values, knob_rings, 0..) |*knob, name, value, ring, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            knob.* = widgets.Knob.init(ui.id("knob", @intCast(index)), name, value, accent).sized(ring);
        }
        for (&app.toggles, toggle_names, toggle_values, 0..) |*toggle, name, on, index| {
            toggle.* = widgets.Toggle.init(ui.id("toggle", @intCast(index)), name, on);
        }
        for (&app.hard_knobs, hard_knob_names, hard_knob_values, hard_knob_rings, 0..) |*knob, name, value, ring, index| {
            const accent = widgets.accents[index % widgets.accent_count];
            knob.* = HardKnob.init(ui.id("hknob", @intCast(index)), name, value, accent).sized(ring);
        }
        for (&app.hard_buttons, hard_button_labels, 0..) |*button, label, index| {
            button.* = .{
                .id = ui.id("hbutton", @intCast(index)),
                .label = label,
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = hard_button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            };
        }
        for (&app.hard_toggles, hard_toggle_names, hard_toggle_values, 0..) |*toggle, name, on, index| {
            toggle.* = HardToggle.init(ui.id("htoggle", @intCast(index)), name, on);
        }
        app.meter = .{ .name = "level", .value = slider_values[meter_slider], .track_h = meter_track_px };
        app.field = widgets.TextField.init(field_id, 32, field_style(&config.theme));
        app.field.hint = "untitled";
        app.password = widgets.TextField.init(password_id, 32, field_style(&config.theme));
        app.password.secret = true;
        app.password.hint = "password";
        app.password.icon = .{ .face = .icons, .codepoint = icons.lock };
        app.search = widgets.TextField.init(search_id, 32, field_style(&config.theme));
        app.search.hint = "search presets";
        app.search.icon = .{ .face = .icons, .codepoint = icons.search };
        app.segments = widgets.Segmented.init(segments_id, &segment_labels, 0);
        for (&app.checkboxes, checkbox_names, checkbox_values, 0..) |*checkbox, name, on, index| {
            checkbox.* = widgets.Checkbox.init(ui.id("checkbox", @intCast(index)), name, on);
        }
        app.checkboxes[checkbox_mixed].mixed = true;
        app.view = ui.ViewState.init();
        app.wave = widgets.Dropdown.init(wave_id, &wave_items, 0);
        app.wave.menu.bounds = frame_rect;
        app.flip = widgets.Dropdown.init(flip_id, &wave_items, 0);
        app.flip.menu.bounds = frame_rect;
        app.file = .{
            .id = file_id,
            .label = "File",
            .style = button_style,
            .padding = .xy(12, 0),
            .paint = button_paint,
            .hover = .init(widgets.hover_rate_per_ms),
            .down = .init(widgets.down_rate_per_ms),
        };
        app.file_menu = widgets.Menu.init(file_menu_id, &file_items);
        app.file_menu.set_enabled(file_disabled, false);
        app.file_menu.bounds = frame_rect;
        app.context = widgets.ContextMenu.init(context_id, &context_items);
        app.context.menu.bounds = frame_rect;
        app.about = About.init();
        app.tooltip = widgets.Tooltip.init();
        app.tooltip.bounds = frame_rect;
        app.drawn = .{ .first = 0, .end = 0 };
        app.selected = null;
        app.status = @splat(0);
        app.status_len = 0;
        app.set_status(&.{"ready"});
        app.restyle(&config.theme);
        assert(app.knobs[3].ring == 72);
        assert(!app.toggles[0].on);
    }

    /// Every widget, the view, then the rows drawn last (module guide, section 3).
    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.light.handle(cx, event_value)) {
            .toggled => |on| {
                cx.set_theme(if (on) theme.light else theme.dark);
                app.restyle(cx.theme());
                app.note(cx, &.{ "theme ", if (on) "light" else "dark" });
            },
            .none => {},
        }
        app.button_events(cx, "", &app.buttons, event_value);
        app.button_events(cx, "hardware ", &app.hard_buttons, event_value);
        for (&app.sliders, 0..) |*slider, index| {
            switch (slider.handle(cx, event_value)) {
                .changed => |value| {
                    if (index == meter_slider and app.meter.set_value(value)) cx.redraw();
                    var bytes: [8]u8 = undefined;
                    widgets.write_hundredths(&bytes, value);
                    app.note(cx, &.{ "slider ", digit(index), " changed ", bytes[0..4] });
                },
                .none, .released => {},
            }
        }
        app.knob_events(cx, "", &app.knobs, event_value);
        app.knob_events(cx, "hardware ", &app.hard_knobs, event_value);
        app.toggle_events(cx, "", &app.toggles, event_value);
        app.toggle_events(cx, "hardware ", &app.hard_toggles, event_value);
        switch (app.field.handle(cx, event_value)) {
            .changed => app.note(cx, &.{ "field ", app.field.bytes() }),
            .committed => app.note(cx, &.{"field committed"}),
            .cancelled => app.note(cx, &.{"field cancelled"}),
            .none => {},
        }
        app.form_events(cx, event_value);
        _ = app.view.handle(cx, view_id, event_value);
        var row = app.drawn.first;
        while (row < app.drawn.end) : (row += 1) {
            if (kit.clicked(cx, ui.id("row", row), event_value)) app.select(cx, row);
        }
        app.popup_events(cx, event_value);
        app.container_events(cx, event_value);
        app.type_events(cx, event_value);
        if (app.drops.handle(cx, event_value)) |report| app.note(cx, report.slice());
        if (app.surfaces.handle(cx, event_value)) |report| switch (report) {
            .pill => |index| app.note(cx, &.{ "pill ", surfaces_page.pill_names[index] }),
            .row => |index| app.note(cx, &.{ "row ", surfaces_page.row_names[index] }),
            .card => |index| app.note(cx, &.{ "card ", surfaces_page.cards[index].name }),
        };
        if (app.glass.handle(cx, event_value)) |report| switch (report) {
            .material => |index| app.note(cx, &.{ "material ", glass_page.material_names[index] }),
            .output => |index| app.note(cx, &.{ "output ", glass_page.output_names[index] }),
            .position => |value| {
                var digits: [8]u8 = undefined;
                const shown = std.fmt.bufPrint(&digits, "{d:.2}", .{value}) catch unreachable;
                app.note(cx, &.{ "position ", shown });
            },
        };
        assert(app.status_len <= status_cap);
    }

    /// The form group (section 2): the password field reports only that it changed, never its
    /// text; the search field its text; the segments the wave; a checkbox its new value.
    fn form_events(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.password.handle(cx, event_value)) {
            .changed => app.note(cx, &.{"password changed"}),
            .committed => app.note(cx, &.{"password committed"}),
            .cancelled => app.note(cx, &.{"password cancelled"}),
            .none => {},
        }
        switch (app.search.handle(cx, event_value)) {
            .changed => app.note(cx, &.{ "search ", app.search.bytes() }),
            .committed => app.note(cx, &.{"search committed"}),
            .cancelled => app.note(cx, &.{"search cancelled"}),
            .none => {},
        }
        switch (app.segments.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "wave ", segment_labels[index] }),
            .none => {},
        }
        for (&app.checkboxes, 0..) |*checkbox, index| {
            switch (checkbox.handle(cx, event_value)) {
                .toggled => |on| app.note(cx, &.{ "checkbox ", digit(index), if (on) " on" else " off" }),
                .none => {},
            }
        }
    }

    /// The type page's transport and toolbar (section 2b): play toggles to pause and back, and
    /// stop shows play again.
    fn type_events(app: *App, cx: *Context, event_value: input.Event) void {
        for (&app.transport, 0..) |*button, index| {
            if (button.handle(cx, event_value) != .clicked) continue;
            if (index == transport_play) {
                app.set_playing(!app.playing);
                app.note(cx, &.{ "transport ", if (app.playing) "play" else "pause" });
                continue;
            }
            if (index == transport_stop) app.set_playing(false);
            app.note(cx, &.{ "transport ", transport_names[index] });
        }
        for (&app.tools, tool_names) |*button, name| {
            if (button.handle(cx, event_value) == .clicked) app.note(cx, &.{ "toolbar ", name });
        }
    }

    /// Shows the play button as pause while playing.
    fn set_playing(app: *App, playing: bool) void {
        app.playing = playing;
        app.transport[transport_play].label = if (playing) &pause_label[0] else &transport_labels[transport_play];
        assert(app.transport[transport_play].label.len == 3);
    }

    /// The tabs and the containers page (section 2a): the splitters, the list box, and the
    /// number boxes.
    fn container_events(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.tabs.handle(cx, event_value)) {
            .changed => |page| app.note(cx, &.{ "page ", page_labels[page] }),
            .none => {},
        }
        app.splitter_events(cx, "split ", &app.split, event_value);
        app.splitter_events(cx, "side ", &app.side, event_value);
        app.splitter_events(cx, "type split ", &app.type_split, event_value);
        _ = app.wrap_view.handle(cx, wrap_view_id, event_value);
        var name: [preset_name_cap]u8 = undefined;
        switch (app.presets.handle(cx, event_value)) {
            .selected => |row| app.note(cx, &.{ preset_name(&name, row), " selected" }),
            .activated => |row| {
                app.activated = row;
                app.note(cx, &.{ preset_name(&name, row), " activated" });
            },
            .none => {},
        }
        for (&app.params, param_names) |*number, label| {
            var bytes: [widgets.number_text_cap]u8 = undefined;
            switch (number.handle(cx, event_value)) {
                .changed => app.note(cx, &.{ label, " ", number.text_of(&bytes) }),
                .committed => app.note(cx, &.{ label, " = ", number.text_of(&bytes) }),
                .none => {},
            }
        }
    }

    /// Reports a splitter's move or reset after `name`.
    fn splitter_events(app: *App, cx: *Context, name: []const u8, splitter: *widgets.Splitter, event_value: input.Event) void {
        var bytes: [8]u8 = undefined;
        switch (splitter.handle(cx, event_value)) {
            .moved => |ratio| {
                widgets.write_hundredths(&bytes, ratio);
                app.note(cx, &.{ name, bytes[0..4] });
            },
            .reset => app.note(cx, &.{ name, "reset" }),
            .none => {},
        }
    }

    /// The popups column (section 3c): the dropdowns, the File button and its menu, the context
    /// menu over the panel, the About dialog, and the knobs' tooltip.
    fn popup_events(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.wave.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "dropdown changed ", digit(index) }),
            .none => {},
        }
        switch (app.flip.handle(cx, event_value)) {
            .changed => |index| app.note(cx, &.{ "flip changed ", digit(index) }),
            .none => {},
        }
        if (app.file.handle(cx, event_value) == .clicked) {
            app.file_menu.open_at(cx, .{ .id = file_id }, .below);
            app.note(cx, &.{"file menu"});
        }
        switch (app.file_menu.handle(cx, event_value)) {
            .chosen => |index| {
                app.note(cx, &.{ "file ", file_items[index] });
                if (index == file_about) app.about.show(cx);
            },
            .none, .dismissed => {},
        }
        switch (app.context.handle(cx, event_value, scratch_id)) {
            .chosen => |index| app.note(cx, &.{ "context ", context_items[index] }),
            .none, .dismissed => {},
        }
        if (app.about.handle(cx, event_value)) app.note(cx, &.{"about closed"});
        var bytes: [16]u8 = undefined;
        app.tooltip.handle(cx, event_value, app.hovered_tip(cx, &bytes));
    }

    /// The hovered knob's tip, default or hardware: its id and "name value" in `bytes`; or the
    /// hovered toolbar button's.
    fn hovered_tip(app: *const App, cx: *Context, bytes: *[16]u8) ?widgets.Tip {
        const hovered = cx.hovered();
        if (hovered == .none) return null;
        for (&app.tools, tool_tips) |*button, tip| {
            if (button.id == hovered) return .{ .anchor = button.id, .text = tip };
        }
        for (&app.knobs) |*knob| {
            if (knob.id == hovered) return tip_of(bytes, knob.id, knob.name, knob.value_text[0..4]);
        }
        for (&app.hard_knobs) |*knob| {
            if (knob.id == hovered) return tip_of(bytes, knob.id, knob.name, knob.value_text[0..4]);
        }
        return null;
    }

    /// Hands `event_value` to each button of `buttons`, default or skinned (they share the
    /// behaviour), and reports a click on the status line after `row`.
    fn button_events(app: *App, cx: *Context, row: []const u8, buttons: anytype, event_value: input.Event) void {
        for (buttons, 0..) |*button, index| {
            if (button.handle(cx, event_value) == .clicked) app.note(cx, &.{ row, "button ", digit(index), " clicked" });
        }
    }

    /// Hands `event_value` to each knob of `knobs` and reports a change or a reset.
    fn knob_events(app: *App, cx: *Context, row: []const u8, knobs: anytype, event_value: input.Event) void {
        for (knobs, 0..) |*knob, index| {
            switch (knob.handle(cx, event_value)) {
                .changed => app.note(cx, &.{ row, "knob ", digit(index), " changed ", knob.value_text[0..4] }),
                .reset => app.note(cx, &.{ row, "knob ", digit(index), " reset ", knob.value_text[0..4] }),
                .none, .released => {},
            }
        }
    }

    /// Hands `event_value` to each toggle of `toggles` and reports a flip.
    fn toggle_events(app: *App, cx: *Context, row: []const u8, toggles: anytype, event_value: input.Event) void {
        for (toggles, 0..) |*toggle, index| {
            switch (toggle.handle(cx, event_value)) {
                .toggled => |on| app.note(cx, &.{ row, "toggle ", digit(index), if (on) " on" else " off" }),
                .none => {},
            }
        }
    }

    /// No timer is armed, so no host calls this.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        assert(app.status_len <= status_cap);
        assert(cx.phase == .idle);
        assert(now_ms == now_ms);
    }

    /// The screen of section 2.
    pub fn draw(app: *App, cx: *Context) void {
        const screen: ui.Walk = .{ .width = .{ .fixed = screen_w }, .height = .{ .fixed = screen_h } };
        _ = cx.begin(screen, .{ .flow = .down, .spacing = gap_px, .padding = .all(screen_padding) });
        app.draw_title(cx);
        _ = app.tabs.begin(cx, ui.sized(.fill, .fill), page_layout);
        switch (app.tabs.selected) {
            page_basics => app.draw_basics(cx),
            page_popups => app.draw_popups(cx),
            page_containers => app.draw_containers(cx),
            page_type => app.draw_type(cx),
            page_files => app.drops.draw(cx, gap_px, group_padding, panel_paint(cx)),
            page_surfaces => app.surfaces.draw(cx),
            page_glass => app.glass.draw(cx),
            else => unreachable,
        }
        _ = cx.end();
        _ = cx.end();
        ui.overlays(cx, app);
        assert(cx.draw.overflow_count == 0);
        assert(cx.area_overflow == 0);
    }

    /// The colors the widgets store, from `scheme` (section 3a): the sliders' paints, the knobs'
    /// accents, and the field's text style. Under `theme.dark` they are the step 30 values.
    fn restyle(app: *App, scheme: *const theme.Scheme) void {
        for (&app.sliders) |*slider| {
            slider.track = widgets.paint_of(scheme.colors.track, widgets.track_radius);
            slider.fill = widgets.paint_of(scheme.colors.value, widgets.track_radius);
            slider.knob = widgets.paint_of(scheme.colors.control, widgets.knob_radius);
        }
        for (&app.knobs, 0..) |*knob, index| {
            const color = scheme.accents[index % theme.accent_count];
            knob.accent = widgets.paint_of(color, widgets.kit.accent_radius);
        }
        for (&app.hard_knobs, 0..) |*knob, index| {
            const color = scheme.accents[index % theme.accent_count];
            knob.accent = widgets.paint_of(color, widgets.kit.accent_radius);
        }
        app.field.style = field_style(scheme);
        app.password.style = field_style(scheme);
        app.search.style = field_style(scheme);
        assert(app.sliders[0].track.radius == widgets.track_radius);
        assert(app.field.style.face == .mono);
    }

    /// The status line's text.
    pub fn status_text(app: *const App) []const u8 {
        assert(app.status_len <= status_cap);
        return app.status[0..app.status_len];
    }

    fn draw_title(app: *const App, cx: *Context) void {
        const bar = cx.walk(ui.sized(.fill, .{ .fixed = title_px }));
        const clip = cx.visible(bar) orelse return;
        kit.face(cx, bar, clip, panel_paint(cx).look(cx.theme(), 0, 0));
        const inner = ui.cx.inset(bar, .xy(title_inset_px, 0));
        kit.label(cx, styled(cx, .sans_bold, 18), "gallery", inner, clip, start);
        kit.label(cx, styled(cx, .sans, 14), app.status_text(), inner, clip, end);
        const cell: Rect = .{ .x = bar.x + theme_toggle_x - screen_padding, .y = bar.y, .width = theme_toggle_w, .height = title_px };
        _ = cx.begin_at(cell, .{ .flow = .down });
        app.light.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    /// The basics page: the widgets of steps 30 to 32 in two bands, the hardware row, and the
    /// list.
    fn draw_basics(app: *App, cx: *Context) void {
        _ = cx.begin(ui.sized(.fill, .{ .fixed = band_px }), .{ .flow = .right, .spacing = gap_px });
        app.draw_buttons(cx);
        app.draw_sliders(cx);
        app.draw_knobs(cx);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .{ .fixed = band_px }), .{ .flow = .right, .spacing = gap_px });
        app.draw_toggles(cx);
        app.draw_meter(cx);
        app.draw_form(cx);
        _ = cx.end();
        app.draw_hardware(cx);
        app.draw_list(cx);
    }

    fn draw_buttons(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.buttons) |*button| button.draw(cx, ui.sized(.fill, .{ .fixed = button_px }));
        _ = cx.end();
    }

    fn draw_sliders(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = sliders_px }, .fill), group_layout);
        for (&app.sliders, slider_names) |*slider, name| {
            caption(cx, name);
            slider.draw(cx, ui.sized(.fill, .{ .fixed = slider_px }));
        }
        _ = cx.end();
    }

    fn draw_knobs(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const row: ui.Layout = .{ .flow = .right, .padding = .all(group_padding), .alignment = .{ .x = 0, .y = 0.5 }, .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .fill), row);
        const cell = ui.sized(.{ .fixed = knob_cell_px }, .{ .fixed = widgets.knob_height });
        for (&app.knobs) |*knob| knob.draw(cx, cell);
        _ = cx.end();
    }

    fn draw_toggles(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        for (&app.toggles) |*toggle| toggle.draw(cx, ui.sized(.fill, .{ .fixed = widgets.toggle_height }));
        _ = cx.end();
    }

    fn draw_meter(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        app.meter.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
    }

    /// The form group (section 2): the name and password fields, the search field and the
    /// segments, and the checkboxes, in three columns.
    fn draw_form(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const row: ui.Layout = .{ .flow = .right, .spacing = form_gap_px, .padding = .all(group_padding), .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .fill), row);
        const column: ui.Layout = .{ .flow = .down, .spacing = gap_px };
        const field = ui.sized(.{ .fixed = field_w }, .{ .fixed = field_h });
        _ = cx.begin(ui.sized(.{ .fixed = form_column_w }, .fill), column);
        caption(cx, "name");
        app.field.draw(cx, field);
        caption(cx, "password");
        app.password.draw(cx, field);
        _ = cx.end();
        _ = cx.begin(ui.sized(.{ .fixed = form_column_w }, .fill), column);
        caption(cx, "search");
        app.search.draw(cx, field);
        caption(cx, "wave");
        app.segments.bar(cx, field);
        _ = cx.end();
        _ = cx.begin(ui.sized(.fill, .fill), column);
        caption(cx, "options");
        for (&app.checkboxes) |*checkbox| checkbox.draw(cx, ui.sized(.fill, .{ .fixed = widgets.checkbox_height }));
        _ = cx.end();
        _ = cx.end();
    }

    /// The hardware row: four skinned knobs, two buttons, and two toggles in one panel, centered
    /// vertically.
    fn draw_hardware(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const row: ui.Layout = .{ .flow = .right, .spacing = gap_px, .padding = .all(group_padding), .alignment = .{ .x = 0, .y = 0.5 }, .clip = true };
        _ = face.begin(cx, ui.sized(.fill, .{ .fixed = hardware_px }), row);
        const cell = ui.sized(.{ .fixed = knob_cell_px }, .{ .fixed = widgets.knob_height });
        for (&app.hard_knobs) |*knob| knob.draw(cx, cell);
        for (&app.hard_buttons) |*button| button.draw(cx, ui.sized(.{ .fixed = hard_button_px }, .{ .fixed = button_px }));
        for (&app.hard_toggles) |*toggle| toggle.draw(cx, ui.sized(.{ .fixed = hard_toggle_px }, .{ .fixed = widgets.toggle_height }));
        _ = cx.end();
    }

    /// The popups page (section 2): a column of their widgets beside a panel of notes; the
    /// popups draw in `ui.overlays`.
    fn draw_popups(app: *const App, cx: *Context) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .right, .spacing = gap_px });
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        const column = face.begin(cx, ui.sized(.{ .fixed = popups_w }, .fill), group_layout);
        caption(cx, "popups");
        app.wave.draw(cx, ui.sized(.fill, .{ .fixed = dropdown_h }));
        app.file.draw(cx, ui.sized(.fill, .{ .fixed = button_px }));
        const scratch = cx.walk(ui.sized(.fill, .{ .fixed = scratch_px }));
        if (cx.visible(scratch)) |inside| {
            kit.face(cx, scratch, inside, .{ .fill = cx.theme().colors.track, .radius = 6 });
            cx.area(scratch_id, scratch, 6, ui.cx.plain);
            kit.label(cx, styled(cx, .sans, 14), "right-click me", scratch, inside, widgets.centered);
        }
        const flip: Rect = .{
            .x = column.x + group_padding,
            .y = frame_rect.height - flip_margin_px - dropdown_h,
            .width = popups_w - 2 * group_padding,
            .height = dropdown_h,
        };
        _ = cx.begin_at(flip, .{ .flow = .down });
        app.flip.draw(cx, ui.sized(.fill, .fill));
        _ = cx.end();
        _ = cx.end();
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        for (popup_notes) |line| caption(cx, line);
        _ = cx.end();
        _ = cx.end();
    }

    /// The containers page (section 2a): a horizontal splitter of the presets and a vertical
    /// splitter of the parameters over the selected preset.
    fn draw_containers(app: *App, cx: *Context) void {
        _ = app.split.begin(cx, ui.sized(.fill, .fill));
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(group_padding) });
        const range = app.presets.begin(cx, ui.sized(.fill, .fill));
        assert(range.end - range.first <= preset_rows_max);
        while (app.presets.next(cx)) |row| draw_preset(cx, row);
        app.presets.end(cx);
        _ = cx.end();
        _ = app.split.next(cx);
        _ = app.side.begin(cx, ui.sized(.fill, .fill));
        app.draw_params(cx);
        _ = app.side.next(cx);
        app.draw_preset_panel(cx);
        app.side.end(cx);
        app.split.end(cx);
    }

    /// The type page (section 2b): the transport, the toolbar, and the size ladder in a band,
    /// the icon set, and a line in each library face.
    fn draw_type(app: *App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = cx.begin(ui.sized(.fill, .{ .fixed = type_band_px }), .{ .flow = .right, .spacing = gap_px });
        _ = face.begin(cx, ui.sized(.{ .fixed = transport_w }, .fill), group_layout);
        caption(cx, "transport");
        _ = cx.begin(ui.sized(.fill, .{ .fixed = button_px }), .{ .flow = .right, .spacing = gap_px });
        for (&app.transport) |*button| button.draw(cx, ui.sized(.{ .fixed = transport_button_w }, .fill));
        _ = cx.end();
        _ = cx.end();
        _ = face.begin(cx, ui.sized(.{ .fixed = narrow_px }, .fill), group_layout);
        caption(cx, "toolbar");
        _ = cx.begin(ui.sized(.fill, .{ .fixed = button_px }), .{ .flow = .right, .spacing = gap_px });
        for (&app.tools) |*button| button.draw(cx, ui.sized(.{ .fixed = tool_button_w }, .fill));
        _ = cx.end();
        _ = cx.end();
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        caption(cx, "sizes: 12, 16, 24, 32, 48 px");
        _ = cx.begin(ui.sized(.fill, .{ .fixed = ladder_cell_h }), .{ .flow = .right, .spacing = gap_px });
        for (ladder_sizes) |size| {
            const cell = cx.walk(ui.sized(.{ .fixed = ladder_cell_w }, .fill));
            const clip = cx.visible(cell) orelse continue;
            kit.face(cx, cell, clip, .{ .fill = cx.theme().colors.track, .radius = 4 });
            kit.icon(cx, .icons, icons.settings, size, cell, clip, cx.theme().colors.text);
        }
        _ = cx.end();
        _ = cx.end();
        _ = cx.end();
        _ = face.begin(cx, ui.sized(.fill, .{ .fixed = set_px }), group_layout);
        caption(cx, "lucide 1.55.0: 14 icons at 24 px");
        _ = cx.begin(ui.sized(.fill, .{ .fixed = set_cell_px }), .{ .flow = .right, .spacing = gap_px });
        for (icons.all) |codepoint| {
            const cell = cx.walk(ui.sized(.{ .fixed = set_cell_px }, .fill));
            const clip = cx.visible(cell) orelse continue;
            kit.icon(cx, .icons, codepoint, set_icon_px, cell, clip, cx.theme().colors.text);
        }
        _ = cx.end();
        _ = cx.end();
        _ = app.type_split.begin(cx, ui.sized(.fill, .fill));
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        for (face_lines) |line| {
            const row = cx.walk(ui.sized(.fill, .{ .fixed = face_line_px }));
            const clip = cx.visible(row) orelse continue;
            kit.label(cx, styled(cx, line.face, 16), line.words, row, clip, start);
        }
        _ = cx.end();
        _ = app.type_split.next(cx);
        draw_wrapped(cx, &app.wrap_view);
        app.type_split.end(cx);
    }

    /// Two rows of three number boxes, each under its caption.
    fn draw_params(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        var line: u32 = 0;
        while (line < 2) : (line += 1) {
            _ = cx.begin(ui.sized(.fill, .{ .fixed = param_row_px }), .{ .flow = .right, .spacing = gap_px });
            for (0..3) |column| {
                const index = line * 3 + column;
                _ = cx.begin(ui.sized(.{ .share = 3 }, .fill), .{ .flow = .down, .spacing = param_gap_px });
                caption(cx, param_names[index]);
                app.params[index].draw(cx, ui.sized(.fill, .{ .fixed = field_h }));
                _ = cx.end();
            }
            _ = cx.end();
        }
        _ = cx.end();
    }

    /// The selected preset's name, large, and the last activated one.
    fn draw_preset_panel(app: *const App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
        var name: [preset_name_cap]u8 = undefined;
        const title = cx.walk(ui.sized(.fill, .{ .fixed = preset_title_px }));
        if (cx.visible(title)) |clip| {
            const words = if (app.presets.selected) |row| preset_name(&name, row) else "no preset selected";
            kit.label(cx, styled(cx, .sans_bold, 22), words, title, clip, start);
        }
        if (app.activated) |row| {
            var line: [preset_name_cap + 11]u8 = undefined;
            const shown = preset_name(&name, row);
            @memcpy(line[0..11], "activated: ");
            @memcpy(line[11..][0..shown.len], shown);
            caption(cx, line[0 .. 11 + shown.len]);
        } else {
            caption(cx, "double-click or Enter activates a preset");
        }
        _ = cx.end();
    }

    /// The list: a view of the visible rows only, standing in for the others with `skip`.
    fn draw_list(app: *App, cx: *Context) void {
        const face: widgets.Panel = .{ .paint = panel_paint(cx) };
        _ = face.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(group_padding) });
        const port = cx.begin_view(view_id, ui.sized(.fill, .fill), .{ .flow = .down }, &app.view);
        const range = rows.visible(app.view.scroll_y, port.height);
        assert(range.end - range.first <= rows_drawn_max);
        app.drawn = range;
        cx.skip(@as(f32, @floatFromInt(range.first)) * row_px);
        var row = range.first;
        while (row < range.end) : (row += 1) app.draw_row(cx, row);
        cx.skip(@as(f32, @floatFromInt(row_count - range.end)) * row_px);
        cx.end_view();
        _ = cx.end();
    }

    /// One row: its area, a highlight when selected or hovered, and its name.
    fn draw_row(app: *const App, cx: *Context, row: u32) void {
        assert(row < row_count);
        const rect = cx.walk(ui.sized(.fill, .{ .fixed = row_px }));
        const clip = cx.visible(rect) orelse return;
        const id = ui.id("row", row);
        cx.area(id, rect, 0, ui.cx.plain);
        const selected = app.selected != null and app.selected.? == row;
        if (selected or cx.hovered() == id) {
            const colors = &cx.theme().colors;
            kit.face(cx, rect, clip, .{ .fill = if (selected) colors.selection else colors.track, .radius = 4 });
        }
        var bytes: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&bytes, "row {d:0>2}", .{row}) catch unreachable;
        kit.label(cx, styled(cx, .sans, 14), name, ui.cx.inset(rect, .xy(row_inset_px, 0)), clip, start);
    }

    fn select(app: *App, cx: *Context, row: u32) void {
        assert(row < row_count);
        app.selected = row;
        var bytes: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&bytes, "{d}", .{row}) catch unreachable;
        app.note(cx, &.{ "row ", name, " selected" });
        assert(app.selected.? == row);
    }

    /// Writes `parts` to the status line and owes a draw. A native safe build also logs it to
    /// stderr, so a manual run (a file drop from a file manager) leaves a record.
    fn note(app: *App, cx: *Context, parts: []const []const u8) void {
        app.set_status(parts);
        cx.redraw();
        const native = @import("builtin").os.tag == .linux and !@import("builtin").is_test;
        if (native and std.debug.runtime_safety) std.debug.print("status: {s}\n", .{app.status_text()});
    }

    /// Joins `parts` into the status buffer, cut at `status_cap`.
    fn set_status(app: *App, parts: []const []const u8) void {
        var used: u32 = 0;
        for (parts) |part| {
            const take: u32 = @intCast(@min(part.len, status_cap - used));
            @memcpy(app.status[used..][0..take], part[0..take]);
            used += take;
        }
        @memset(app.status[used..], 0);
        app.status_len = used;
        assert(app.status_len <= status_cap);
    }
};

/// The About dialog (section 3c): a modal popup centered in the frame over a dimmed backdrop,
/// with a Close button. Escape closes it too; a press on the backdrop does nothing.
const About = struct {
    open: bool,
    close: widgets.Button,

    fn init() About {
        return .{
            .open = false,
            .close = .{
                .id = close_id,
                .label = "Close",
                .style = button_style,
                .padding = .xy(12, 0),
                .paint = button_paint,
                .hover = .init(widgets.hover_rate_per_ms),
                .down = .init(widgets.down_rate_per_ms),
            },
        };
    }

    /// Opens the dialog and requests its popup.
    fn show(self: *About, cx: *Context) void {
        assert(!self.open);
        self.open = true;
        cx.request_popup(about_id);
    }

    /// True on the event that closed it.
    fn handle(self: *About, cx: *Context, event_value: input.Event) bool {
        if (event_value == .frame) {
            _ = self.close.handle(cx, event_value);
            return false;
        }
        if (!self.open) return false;
        const clicked = self.close.handle(cx, event_value) == .clicked;
        const escape = event_value == .key_down and event_value.key_down.key == .escape;
        if (!clicked and !escape) return false;
        self.open = false;
        cx.redraw();
        return true;
    }

    pub fn draw_overlay(self: *const About, cx: *Context) void {
        if (!self.open) return;
        const rect = ui.popup.centered(about_size, frame_rect);
        _ = cx.begin_popup(about_id, rect, .{ .flow = .down, .spacing = gap_px, .padding = .all(16), .clip = true }, about_dim);
        const clip = cx.clip().?;
        kit.face(cx, rect, clip, .{
            .fill = cx.theme().colors.panel,
            .border_color = cx.theme().colors.control,
            .border_width = 1,
            .radius = panel_radius,
        });
        const title = cx.walk(ui.sized(.fill, .{ .fixed = 24 }));
        kit.label(cx, styled(cx, .sans_bold, 18), "patchwork gallery", title, clip, start);
        const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
        kit.label(cx, styled(cx, .sans, 14), "Every widget, skin, and popup.", line, clip, start);
        cx.skip(gap_px);
        self.close.draw(cx, ui.sized(.{ .fixed = about_close_size[0] }, .{ .fixed = about_close_size[1] }));
        cx.end_popup();
    }
};

/// An icon button of the type page (section 2b): `label` is one icon's UTF-8, drawn at
/// `icon_px` in `color` on the buttons' blue.
fn icon_button(id: ui.Id, label: *const [3]u8, width: f32, color: [4]f32) IconButton {
    assert(width >= button_px);
    assert(color[3] == 1);
    return .{
        .id = id,
        .label = label,
        .style = .{ .face = .icons, .size = icon_px, .color = color },
        .padding = .xy(0, 0),
        .paint = button_paint,
        .hover = .init(widgets.hover_rate_per_ms),
        .down = .init(widgets.down_rate_per_ms),
    };
}

/// A tip for knob `id`: "name value" written into `bytes`.
fn tip_of(bytes: *[16]u8, id: ui.Id, name: []const u8, value: []const u8) widgets.Tip {
    assert(name.len + 1 + value.len <= bytes.len);
    @memcpy(bytes[0..name.len], name);
    bytes[name.len] = ' ';
    @memcpy(bytes[name.len + 1 ..][0..value.len], value);
    return .{ .anchor = id, .text = bytes[0 .. name.len + 1 + value.len] };
}

/// Writes "preset 0001" for `row` 0 into `out`.
fn preset_name(out: *[preset_name_cap]u8, row: u32) []const u8 {
    assert(row < preset_count);
    @memcpy(out[0..7], "preset ");
    var number = row + 1;
    var place: usize = 4;
    while (place > 0) {
        place -= 1;
        out[7 + place] = '0' + @as(u8, @intCast(number % 10));
        number /= 10;
    }
    assert(number == 0);
    return out[0..preset_name_cap];
}

/// One preset row's name, after the list box drew its band.
fn draw_preset(cx: *Context, row: widgets.ListRow) void {
    var bytes: [preset_name_cap]u8 = undefined;
    const inner = ui.cx.inset(row.rect, .xy(row_inset_px, 0));
    kit.label(cx, styled(cx, .sans, 14), preset_name(&bytes, row.index), inner, row.clip, start);
}

/// The type page's wrapped text (step 38): under the caption, a view of the bullets, each a
/// bold lead and the rest wrapped with `text.place_runs_wrapped` beside a dot, then a
/// `widgets.Paragraph` of `wrap_words`. The view measures their heights and scrolls them when
/// the pane is too narrow or the window too short to show them all.
fn draw_wrapped(cx: *Context, view: *ui.ViewState) void {
    const face: widgets.Panel = .{ .paint = panel_paint(cx) };
    _ = face.begin(cx, ui.sized(.fill, .fill), group_layout);
    caption(cx, "wrapped: drag the divider");
    _ = cx.begin_view(wrap_view_id, ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap_px }, view);
    const bold = styled(cx, .sans_bold, wrap_size);
    const regular = styled(cx, .sans, wrap_size);
    for (bullets) |bullet| {
        const runs = [_]text.Run{ .{ .style = bold, .bytes = bullet[0] }, .{ .style = regular, .bytes = bullet[1] } };
        const width = cx.peek(ui.sized(.fill, .{ .fixed = 0 })).width - bullet_gutter_px;
        const height = text.measure_runs_wrapped(&runs, @max(width, 0));
        const row = cx.walk(ui.sized(.fill, .{ .fixed = height }));
        const clip = cx.visible(row) orelse continue;
        const line_h = text.line_height(regular);
        const dot: Rect = .{
            .x = row.x + (bullet_gutter_px - bullet_dot_px) * 0.5,
            .y = row.y + (line_h - bullet_dot_px) * 0.5,
            .width = bullet_dot_px,
            .height = bullet_dot_px,
        };
        kit.face(cx, dot, clip, .{ .fill = regular.color, .radius = bullet_dot_px * 0.5 });
        const body = ui.cx.inset(row, .sides(bullet_gutter_px, 0, 0, 0));
        text.place_runs_wrapped(cx.drawing(), &runs, body, clip, .{});
    }
    const paragraph: widgets.Paragraph = .{ .text = wrap_words, .style = regular };
    _ = paragraph.draw(cx, ui.sized(.fill, .fit));
    cx.end_view();
    _ = cx.end();
}

/// A caption line above a control.
fn caption(cx: *Context, words: []const u8) void {
    const line = cx.walk(ui.sized(.fill, .{ .fixed = caption_px }));
    const clip = cx.visible(line) orelse return;
    kit.label(cx, styled(cx, .sans, 14), words, line, clip, start);
}

/// The group faces' paint: the scheme's panel color.
fn panel_paint(cx: *Context) widgets.Paint {
    return widgets.paint_of(cx.theme().colors.panel, panel_radius);
}

/// Text in `face` at `size` in the scheme's text color: the title, status, captions, and rows.
fn styled(cx: *Context, face: text.Face, size: f32) text.Style {
    assert(size > 0);
    return .{ .face = face, .size = size, .color = cx.theme().colors.text };
}

/// The field's text: Noto Sans Mono 16 in the scheme's text color.
fn field_style(scheme: *const theme.Scheme) text.Style {
    return .{ .face = .mono, .size = 16, .color = scheme.colors.text };
}

/// The decimal digit of `index`, below 10.
fn digit(index: usize) []const u8 {
    assert(index < 10);
    return "0123456789"[index..][0..1];
}

/// `interact` (module guide, section 4). Slider 0 is pressed at its knob (value 0.25 on a
/// 272 px slider: x = 12 + 0.25 * 248 = 74) and moved 80 px; knob 1's 40 px ring is pressed
/// at its centre and moved up 30 px, a quarter of `drag_span_px`.
const interact_steps = [_]bench.Step{
    .{ .click = bench.area("button", 0) },
    .{ .drag = .{ .target = bench.area("slider", 0), .from_x = 74, .from_y = 12, .dx = 80, .dy = 0 } },
    .{ .click = bench.area("toggle", 1) },
    .{ .drag = .{ .target = bench.area("knob", 1), .from_x = 20, .from_y = 20, .dx = 0, .dy = -30 } },
    .{ .click = bench.area("field", 0) },
    .{ .key = .{ .key = .a, .text = "a" } },
    .{ .key = .{ .key = .b, .text = "b" } },
    .{ .key = .{ .key = .c, .text = "c" } },
    .{ .wheel = .{ .target = bench.area("view", 0), .dx = 0, .dy = 3 * row_px } },
    .{ .click = bench.area("row", 5) },
    .{ .wait = 12 },
};

/// `hover`: the pointer rests on button 1 until its hover animator settles (100 ms).
const hover_steps = [_]bench.Step{
    .{ .hover = .{ .target = bench.area("button", 1), .x = 80, .y = 20 } },
    .{ .wait = 12 },
};

/// `light`: switch to the light theme, focus the field and type "abc", then select it by a
/// drag from before its first glyph (x 4 of 240) to past its last (x 64), which selects all
/// three bytes however the press counts as a click; the pointer rests over the field.
const light_steps = [_]bench.Step{
    .{ .click = bench.area("theme", 0) },
    .{ .click = bench.area("field", 0) },
    .{ .key = .{ .key = .a, .text = "a" } },
    .{ .key = .{ .key = .b, .text = "b" } },
    .{ .key = .{ .key = .c, .text = "c" } },
    .{ .drag = .{ .target = bench.area("field", 0), .from_x = 4, .from_y = 16, .dx = 60, .dy = 0 } },
    .{ .wait = 12 },
};

/// `form` (section 4): the Saw segment, the "loop" checkbox, then the password field with
/// "hunter2" typed: seven bullets and the caret, the focus on the password field.
const form_steps = [_]bench.Step{
    .{ .click = segment(1) },
    .{ .click = bench.area("checkbox", 0) },
    .{ .click = bench.area("password", 0) },
    .{ .key = .{ .key = .h, .text = "h" } },
    .{ .key = .{ .key = .u, .text = "u" } },
    .{ .key = .{ .key = .n, .text = "n" } },
    .{ .key = .{ .key = .t, .text = "t" } },
    .{ .key = .{ .key = .e, .text = "e" } },
    .{ .key = .{ .key = .r, .text = "r" } },
    .{ .key = .{ .key = .d2, .text = "2" } },
    .{ .wait = 12 },
};

/// `form-search` (section 4): the mixed "all voices" checkbox clicked (on), then "saw" typed
/// into the search field: its hint gone, the text after the icon.
const form_search_steps = [_]bench.Step{
    .{ .click = bench.area("checkbox", checkbox_mixed) },
    .{ .click = bench.area("search", 0) },
    .{ .key = .{ .key = .s, .text = "s" } },
    .{ .key = .{ .key = .a, .text = "a" } },
    .{ .key = .{ .key = .w, .text = "w" } },
    .{ .wait = 12 },
};

/// Segment `index` of the form's segmented control, a click target.
fn segment(index: u32) bench.Target {
    return .{ .id = segments_id.derive(index), .name = "segment", .index = index };
}

/// `hardware`: drag hardware knob 0 (a 56 px dial) from its center up 40 px, a third of
/// `drag_span_px` (0.50 to 0.83), click hardware button 1, flip hardware toggle 0, then let the
/// animations settle.
const hardware_steps = [_]bench.Step{
    .{ .drag = .{ .target = bench.area("hknob", 0), .from_x = 19, .from_y = 19, .dx = 0, .dy = -40 } },
    .{ .click = bench.area("hbutton", 1) },
    .{ .click = bench.area("htoggle", 0) },
    .{ .wait = 12 },
};

/// The context menu's row `index`, a click target of the `context` scenario.
fn context_row(index: u32) bench.Target {
    return .{ .id = context_id.derive(index), .name = "context row", .index = index };
}

/// The File menu's row `index`.
fn file_row(index: u32) bench.Target {
    return .{ .id = file_menu_id.derive(index), .name = "file row", .index = index };
}

/// `dropdown`: open the wave dropdown, Down twice from "sine", Enter: "dropdown changed 2".
const dropdown_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .click = bench.area("wave", 0) },
    .{ .key = .{ .key = .down, .text = "" } },
    .{ .key = .{ .key = .down, .text = "" } },
    .{ .key = .{ .key = .enter, .text = "" } },
    .{ .wait = 12 },
};

/// `menu-open`: the File menu open below its button.
const menu_open_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .click = bench.area("file", 0) },
    .{ .wait = 2 },
};

/// `menu-flip`: the flip dropdown's list, which has no room below it in the frame, above it.
const menu_flip_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .click = bench.area("flip", 0) },
    .{ .wait = 2 },
};

/// `context`: a right click 40 px into the panel opens the context menu there; click Reset.
const context_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .right_click = .{ .target = bench.area("scratch", 0), .x = 40, .y = 30 } },
    .{ .click = context_row(2) },
    .{ .wait = 12 },
};

/// `dismiss`: open the File menu, then click the wave dropdown through its backdrop: the menu
/// closes, the dropdown does not open, and the status still reads "file menu".
const dismiss_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .click = bench.area("file", 0) },
    .{ .wait = 2 },
    .{ .click = bench.area("wave", 0) },
    .{ .wait = 12 },
};

/// `tooltip`: the pointer rests on knob 0's ring until its tooltip shows (40 frames, 667 ms).
const tooltip_steps = [_]bench.Step{
    .{ .hover = .{ .target = bench.area("knob", 0), .x = 28, .y = 28 } },
    .{ .wait = 40 },
};

/// The tab of page `index`, a click target.
fn tab(index: u32) bench.Target {
    return .{ .id = tabs_id.derive(index), .name = "tab", .index = index };
}

/// The containers page's horizontal divider, a drag target.
fn split_divider() bench.Target {
    return .{ .id = split_id.derive(widgets.divider_salt), .name = "split divider", .index = 0 };
}

/// `tabs`: click each tab in turn; the last, containers, stays shown.
const tabs_steps = [_]bench.Step{
    .{ .click = tab(page_basics) },
    .{ .click = tab(page_popups) },
    .{ .click = tab(page_containers) },
    .{ .wait = 12 },
};

/// `split`: drag the presets' divider 120 px left from its middle.
const split_steps = [_]bench.Step{
    .{ .click = tab(page_containers) },
    .{ .drag = .{ .target = split_divider(), .from_x = 3, .from_y = 200, .dx = -120, .dy = 0 } },
    .{ .wait = 12 },
};

/// `list`: click preset row 3 (preset 0004), then Down 20 times: preset 0024, scrolled into
/// view.
const list_steps = blk: {
    var steps: [2 + 20 + 1]bench.Step = undefined;
    steps[0] = .{ .click = tab(page_containers) };
    steps[1] = .{ .click_at = .{ .target = bench.area("presets", 0), .x = 60, .y = 3 * preset_row_px + preset_row_px / 2 } };
    for (steps[2..22]) |*step| step.* = .{ .key = .{ .key = .down, .text = "" } };
    steps[22] = .{ .wait = 12 };
    break :blk steps;
};

/// `number`: drag the frequency up 40 px (440 to 4436 Hz), then double-click the gain, type
/// "-6.5", and Enter. The two clicks are one frame apart, a double click on the regress clock.
const number_steps = [_]bench.Step{
    .{ .click = tab(page_containers) },
    .{ .drag = .{ .target = bench.area("param", 0), .from_x = 40, .from_y = 16, .dx = 0, .dy = -40 } },
    .{ .click = bench.area("param", 1) },
    .{ .click = bench.area("param", 1) },
    .{ .key = .{ .key = .other, .text = "-" } },
    .{ .key = .{ .key = .d6, .text = "6" } },
    .{ .key = .{ .key = .other, .text = "." } },
    .{ .key = .{ .key = .d5, .text = "5" } },
    .{ .key = .{ .key = .enter, .text = "" } },
    .{ .wait = 12 },
};

/// The type page's divider (step 38), a drag target.
fn type_divider() bench.Target {
    return .{ .id = type_split_id.derive(widgets.divider_salt), .name = "type divider", .index = 0 };
}

/// `wrap`: the type page with its divider dragged 240 px left: the wrapped text widens.
const wrap_steps = [_]bench.Step{
    .{ .click = tab(page_type) },
    .{ .drag = .{ .target = type_divider(), .from_x = 3, .from_y = 100, .dx = -240, .dy = 0 } },
    .{ .wait = 12 },
};

/// `wrap-narrow`: the divider dragged right to the wrapped pane's 200 px minimum: the long
/// word breaks between letters.
const wrap_narrow_steps = [_]bench.Step{
    .{ .click = tab(page_type) },
    .{ .drag = .{ .target = type_divider(), .from_x = 3, .from_y = 100, .dx = 600, .dy = 0 } },
    .{ .wait = 12 },
};

/// `wrap-scroll`: `wrap-narrow`, then the wheel over the wrapped text far down: the view
/// scrolls to its end, showing the paragraph's last line and the thumb at the bottom.
const wrap_scroll_steps = [_]bench.Step{
    .{ .click = tab(page_type) },
    .{ .drag = .{ .target = type_divider(), .from_x = 3, .from_y = 100, .dx = 600, .dy = 0 } },
    .{ .wheel = .{ .target = bench.area("wrap_view", 0), .dx = 0, .dy = 2000 } },
    .{ .wait = 12 },
};

/// A clickable of the surfaces page: `id` derived by `index`, a click or hover target.
fn surface_target(id: ui.Id, name: []const u8, index: u32) bench.Target {
    return .{ .id = id.derive(index), .name = name, .index = index };
}

/// `surfaces-click`: select the Radio pill and the Browse row, click the Slate card, then rest
/// the pointer on Moss: its gradient lit, the status "card Slate".
const surfaces_click_steps = [_]bench.Step{
    .{ .click = tab(page_surfaces) },
    .{ .click = surface_target(surfaces_page.pill_id, "surface pill", 2) },
    .{ .click = surface_target(surfaces_page.row_id, "surface row", 1) },
    .{ .click = surface_target(surfaces_page.card_id, "surface card", 0) },
    .{ .hover = .{ .target = surface_target(surfaces_page.card_id, "surface card", 1), .x = 144, .y = 60 } },
    .{ .wait = 12 },
};

/// `surfaces-light`: the light theme, then the surfaces page: its palette restyled.
const surfaces_light_steps = [_]bench.Step{
    .{ .click = bench.area("theme", 0) },
    .{ .click = tab(page_surfaces) },
    .{ .wait = 12 },
};

/// `glass`: the glass page, still: frosted (section 2e).
const glass_steps = [_]bench.Step{
    .{ .click = tab(page_glass) },
    .{ .wait = 12 },
};

/// `glass-scroll`: the glass page scrolled 120 px, then the wheel over the cards every frame
/// (each step is one frame), 24 px down and back up: every frame moves the cards under the
/// glass and blurs them again, for as many frames as a bench asks.
const glass_scroll_steps = [_]bench.Step{
    .{ .click = tab(page_glass) },
    .{ .wheel = .{ .target = bench.area("glass_view", 0), .dx = 0, .dy = 120 } },
    .{ .wait = 2 },
};
const glass_scroll_cycle = [_]bench.Step{
    .{ .wheel = .{ .target = bench.area("glass_view", 0), .dx = 0, .dy = 24 } },
    .{ .wheel = .{ .target = bench.area("glass_view", 0), .dx = 0, .dy = -24 } },
};

/// `glass-popup`: the output dropdown opened and Down pressed: its glass list over the
/// sidebar's glass, the second row highlighted under its label.
const glass_popup_steps = [_]bench.Step{
    .{ .click = tab(page_glass) },
    .{ .click = .{ .id = glass_page.output_id, .name = "glass output", .index = 0 } },
    .{ .key = .{ .key = .down, .text = "" } },
    .{ .wait = 12 },
};

/// `glass-clear`: the Clear segment picked: little blur, a strong lens at every edge.
const glass_clear_steps = [_]bench.Step{
    .{ .click = tab(page_glass) },
    .{ .click = .{ .id = glass_page.segment_id.derive(0), .name = "glass segment", .index = 0 } },
    .{ .wait = 12 },
};

/// `glass-light`: the light theme, then the glass page.
const glass_light_steps = [_]bench.Step{
    .{ .click = bench.area("theme", 0) },
    .{ .click = tab(page_glass) },
    .{ .wait = 12 },
};

/// `surfaces`: the surfaces page, still (section 2d).
const surfaces_steps = [_]bench.Step{
    .{ .click = tab(page_surfaces) },
    .{ .wait = 12 },
};

/// `type`: the type page, still (section 2b).
const type_steps = [_]bench.Step{
    .{ .click = tab(page_type) },
    .{ .wait = 12 },
};

/// `transport`: click play on the type page: its icon turns to pause.
const transport_steps = [_]bench.Step{
    .{ .click = tab(page_type) },
    .{ .click = bench.area("transport", transport_play) },
    .{ .wait = 12 },
};

/// `files`: the files page, empty (section 2c).
const files_steps = [_]bench.Step{
    .{ .click = tab(page_files) },
    .{ .wait = 12 },
};

/// `drop-hover`: files dragged over the zone: its border in the accent.
const drop_hover_steps = [_]bench.Step{
    .{ .click = tab(page_files) },
    .{ .drop_hover = drop_zone },
    .{ .wait = 12 },
};

/// `drop`: three files dropped on the zone: the tone (96,044 bytes, two chunks), a text file,
/// and a folder; the tone's waveform shows.
const drop_steps = [_]bench.Step{
    .{ .click = tab(page_files) },
    .{ .drop = .{ .target = drop_zone, .files = &dropped_files } },
    .{ .wait = 12 },
};

const drop_zone: bench.Target = .{ .id = files_page.zone_id, .name = "drop_zone", .index = 0 };

const dropped_files = [_]bench.File{
    .{ .name = "tone.wav", .parts = &.{
        .{ .bytes = &files_page.tone_header },
        .{ .bytes = &files_page.tone_cycle, .repeat = files_page.tone_periods },
    } },
    .{ .name = "readme.txt", .parts = &.{.{ .bytes = files_page.readme }} },
    .{ .name = "samples", .parts = &.{}, .readable = false },
};

/// `about`: choose About… from the File menu: the dialog over the dimmed screen.
const about_steps = [_]bench.Step{
    .{ .click = tab(page_popups) },
    .{ .click = bench.area("file", 0) },
    .{ .click = file_row(file_about) },
    .{ .wait = 12 },
};

comptime {
    // Every page starts under the title, the tab bar, and a gap: y 104, 584 px tall.
    assert(page_y == 104 and page_h == 584);
    // The popups page: the column's widgets end above the flip dropdown, which sits inside the
    // column 40 px above the frame's bottom.
    assert(page_y + group_padding + 3 * gap_px + caption_px + dropdown_h + button_px + scratch_px < frame_rect.height - flip_margin_px - dropdown_h);
    assert(frame_rect.height - flip_margin_px <= page_y + page_h);
    // The title: the toggle sits right of "gallery" and inside the bar.
    assert(theme_toggle_x + theme_toggle_w < screen_w - screen_padding);
    assert(widgets.toggle_height == title_px);
    // The bands' widths: the knob group holds four cells.
    const inner_w = screen_w - 2 * screen_padding;
    assert(inner_w - narrow_px - sliders_px - 2 * gap_px >= 4 * knob_cell_px + 2 * group_padding);
    // Three 40 px buttons or toggles with two gaps fill a band's inner height.
    assert(3 * button_px + 2 * gap_px == band_px - 2 * group_padding);
    assert(3 * widgets.toggle_height + 2 * gap_px == band_px - 2 * group_padding);
    // The hardware row: four knob cells, two buttons, and two toggles with seven gaps fit it.
    assert(4 * knob_cell_px + 2 * hard_button_px + 2 * hard_toggle_px + 7 * gap_px <= inner_w - 2 * group_padding);
    assert(widgets.knob_height == hardware_px - 2 * group_padding);
    for (hard_knob_rings) |ring| assert(ring <= widgets.knob_height);
    // The list takes what remains of the basics page: 168 px, a 152 px viewport.
    const list_h = page_h - 2 * band_px - hardware_px - 3 * gap_px;
    assert(list_h == 168);
    assert(@ceil((list_h - 2 * group_padding) / row_px) + 1 == rows_drawn_max);
    for (knob_rings) |ring| assert(ring <= widgets.knob_height);
    // The containers page: the presets' viewport is at most the page less the panel's padding,
    // and both splitters' minimums fit.
    assert(@ceil((page_h - 2 * group_padding) / preset_row_px) + 1 == preset_rows_max);
    assert(split_min_a + split_min_b + widgets.splitter_px <= inner_w);
    assert(params_h + side_min_b + widgets.splitter_px <= page_h);
    assert(params.len == param_names.len and params.len == 6);
    // Faces, on the busiest page (basics): the title and its toggle (2), the tab bar's line,
    // four tabs, and the underline, 7 groups, 3 buttons, 3 per slider, 2 per toggle, 2 meter,
    // 3 for the focused field and 1 for each other field, the segments' track, selected, and
    // hovered segment, a box per checkbox and the mixed bar, 2 highlighted rows, the thumb; a
    // popup's dim, face, and band; the tooltip.
    assert(1 + 2 + 6 + 7 + 3 + 3 * 2 + 2 * 3 + 2 + 3 + 2 + 3 + checkbox_names.len + 1 + 2 + 1 + 3 + 1 <= box_cap);
    // The containers page: the title (3), the tabs (6), the list's panel, two bands, and thumb,
    // two dividers, the grid's panel, six faces (one an editing field: face, band, caret), and
    // the preset panel.
    assert(3 + 6 + 4 + 2 + 1 + 6 + 2 + 1 <= box_cap);
    // The type page: the title (3), the tabs (6), five panels, eight buttons, five ladder
    // cells, and the tooltip.
    assert(3 + 6 + 5 + 8 + 5 + 1 <= box_cap);
    assert(2 * knob_names.len + hard_knob_names.len <= arc_cap);
    // The hardware row: a dial per knob, a bevel per button and toggle, an LED per toggle.
    assert(hard_knob_names.len <= dial_cap);
    assert(hard_button_labels.len + hard_toggle_names.len <= bevel_cap);
    assert(hard_toggle_names.len <= led_cap);
    // Areas: the title's toggle, the bar and its tabs, and per page: basics (every widget, the
    // form's three fields, segments bar and segments, and checkboxes, the view and its thumb,
    // the rows drawn, the hardware row); popups (two dropdowns, the button,
    // the panel, and one popup: its backdrop and at most six rows); containers (the list box's
    // view, thumb, and rows, two dividers, six number boxes).
    const chrome = 1 + 1 + page_labels.len;
    assert(chrome + 3 + 2 + 4 + 3 + 3 + 1 + segment_labels.len + checkbox_names.len + 2 + rows_drawn_max + 8 <= area_cap);
    assert(chrome + 4 + 1 + file_items.len <= area_cap);
    assert(chrome + 2 + preset_rows_max + 2 + param_names.len <= area_cap);
    assert(wave_items.len >= file_items.len and file_items.len >= context_items.len);
    // Paths: one chevron per dropdown (popups) or one mark per checkbox (basics), three points
    // each.
    assert(2 <= path_cap and 2 * 3 <= point_cap);
    assert(checkbox_names.len <= path_cap and 3 * checkbox_names.len <= point_cap);
    // The form group: two field columns and the checkboxes' column fit its inner width; two
    // captioned fields fit its inner height, as do the caption and the checkboxes.
    const form_w = inner_w - 2 * narrow_px - 2 * gap_px - 2 * group_padding;
    assert(2 * form_column_w + 2 * form_gap_px + 160 <= form_w);
    assert(field_w == form_column_w);
    assert(2 * (caption_px + gap_px + field_h) + gap_px <= band_px - 2 * group_padding);
    const checks_h: f32 = @as(f32, @floatFromInt(checkbox_names.len)) * widgets.checkbox_height;
    assert(caption_px + gap_px + checks_h + 2 * gap_px <= band_px - 2 * group_padding);
    assert(knob_names.len <= 10 and button_labels.len <= 10);
    assert(preset_count <= 9999);
    // The type page: the transport's five buttons and the toolbar's three fit their panels, the
    // ladder's five cells and the icon set's fourteen fit the page, and the band, the set, and
    // three face lines fit its height.
    assert(transport_icons.len * transport_button_w + 4 * gap_px <= transport_w - 2 * group_padding);
    assert(tool_icons.len * tool_button_w + 2 * gap_px <= narrow_px - 2 * group_padding);
    assert(ladder_sizes.len * ladder_cell_w + 4 * gap_px <= inner_w - transport_w - narrow_px - 2 * gap_px - 2 * group_padding);
    for (ladder_sizes) |size| assert(size <= ladder_cell_h);
    assert(icons.all.len * set_cell_px + (icons.all.len - 1) * gap_px <= inner_w - 2 * group_padding);
    assert(type_band_px + set_px + 2 * gap_px + 2 * group_padding + face_lines.len * face_line_px <= page_h);
    assert(transport_names.len == transport_icons.len and tool_tips.len == tool_icons.len);
    // Areas: the chrome and the eight icon buttons.
    assert(chrome + transport_icons.len + tool_icons.len <= area_cap);
    // The files page: the zone over the list, beside the waveform panel; the list shows at
    // most 14 rows. Boxes: the title (3), the tabs (7), the zone, the list's panel, a band,
    // and its thumb, the wave panel and its track. Areas: the zone, the list's view and
    // thumb, and its rows.
    assert(files_page.zone_h + gap_px + 2 * group_padding + files_page.row_px <= page_h - gap_px);
    assert(3 + 7 + 1 + 1 + 2 + 2 <= box_cap);
    assert(chrome + 3 + 14 <= area_cap);
    // Points: the waveform's columns with RMS, then the dropdowns' chevrons.
    assert(2 * (inner_w - files_page.zone_w - gap_px - 2 * group_padding) + 2 * 3 <= point_cap);
}

// ------------------------------------------------------------------------------------ tests

/// The test context: static, like the hosts', so its pools stay off the stack.
var test_context: Context = undefined;

fn new_app() *App {
    const static = struct {
        var app: App = undefined;
    };
    test_context.init();
    App.init(&static.app, &test_context.draw.textures);
    return &static.app;
}

/// Draws a 1280 by 720 frame the way a host does after a resize.
fn frame(app: *App) *Context {
    test_context.redraw();
    assert(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
    assert(test_context.draw.overflow_count == 0);
    return &test_context;
}

fn area_rect(id: ui.Id) Rect {
    const values = test_context.find(id).?.rect;
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

fn expect_rect(rect: Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

// Locks the layout of section 2: the title face, the tab bar and its first tab, the first
// button and slider, the knob rings centered in the knob band (56, 40, 56, 72 px), the first
// toggle's pill, the field, the list's viewport, and that the first frame leaves nothing owed.
test "gallery layout at 1280 by 720" {
    const app = new_app();
    const cx = frame(app);
    // The tab bar: 1248 px under the title at y 16 + 40 + 8 = 64; tab 0 at its left.
    try expect_rect(area_rect(tabs_id), 16, 64, 1248, 32);
    try std.testing.expectEqual(@as(f32, 16), area_rect(app.tabs.tab_id(0)).x);
    try std.testing.expectEqual(@as(f32, 31), area_rect(app.tabs.tab_id(0)).height);
    // The basics page starts at y 104: its first band's panel padding puts button 0 at 112.
    try expect_rect(area_rect(app.buttons[0].id), 24, 112, 160, 40);
    // The title's toggle: its pill 8 px into its 160 px cell at x 156, centered in the bar.
    try expect_rect(area_rect(theme_id), 164, 24, 44, 24);
    try expect_rect(area_rect(app.sliders[0].id), 208, 140, 272, 24);
    // Knob cells start at 16 + 176 + 8 + 288 + 8 + 8 = 504; the 72 px rows sit at
    // 104 + 8 + (136 - 72) / 2 = 144, and each ring is centered in its row.
    try expect_rect(area_rect(app.knobs[0].id), 512, 152, 56, 56);
    try expect_rect(area_rect(app.knobs[1].id), 652, 160, 40, 40);
    try expect_rect(area_rect(app.knobs[3].id), 932, 144, 72, 72);
    try expect_rect(area_rect(app.toggles[0].id), 32, 280, 44, 24);
    try expect_rect(area_rect(field_id), 392, 300, 240, 32);
    // The form group (section 2f): its columns at 392, 648, and 904; a caption (20), a gap,
    // a field (32), a gap, then the second caption and field at 368.
    try expect_rect(area_rect(password_id), 392, 368, 240, 32);
    try expect_rect(area_rect(search_id), 648, 300, 240, 32);
    try expect_rect(area_rect(segments_id), 648, 368, 240, 32);
    try expect_rect(area_rect(segments_id.derive(0)), 651, 371, 77, 26);
    for (0..checkbox_names.len) |index| {
        const box = area_rect(ui.id("checkbox", @intCast(index)));
        try std.testing.expectEqual(@as(f32, 904), box.x);
        try std.testing.expectEqual(300 + @as(f32, @floatFromInt(index)) * 36, box.y);
        try std.testing.expectEqual(widgets.checkbox_height, box.height);
    }
    // The hardware row's panel starts at 104 + 2 * (152 + 8) = 424, its cells at 432:
    // hardware knob 0's 56 px ring at (32, 440), its dial body 9 px inside it; knob 1's 48 px
    // ring at (180, 444); the buttons after four cells and four gaps at x 616 and 720, centered
    // in the 72 px row; the toggles' housings 8 px into their cells at 824 and 948.
    try expect_rect(area_rect(app.hard_knobs[0].id), 41, 449, 38, 38);
    try std.testing.expectEqual(@as(f32, 19), cx.find(app.hard_knobs[0].id).?.radius);
    try expect_rect(area_rect(app.hard_knobs[1].id), 189, 453, 30, 30);
    try expect_rect(area_rect(app.hard_buttons[0].id), 616, 448, 96, 40);
    try expect_rect(area_rect(app.hard_buttons[1].id), 720, 448, 96, 40);
    try expect_rect(area_rect(app.hard_toggles[0].id), 832, 456, 44, 24);
    try expect_rect(area_rect(app.hard_toggles[1].id), 956, 456, 44, 24);
    try expect_rect(app.view.viewport, 24, 528, 1232, 152);
    try std.testing.expectEqual(@as(f32, 1120), app.view.content_h);
    try expect_rect(area_rect(ui.id("row", 0)), 24, 528, 1232 - ui.view.gutter_px, 28);
    // 152 / 28: row 5 is the last one the viewport shows (partly), so row 6 is not drawn.
    try std.testing.expect(cx.find(ui.id("row", 5)) != null);
    try std.testing.expect(cx.find(ui.id("row", 6)) == null);
    // Only the selected page draws: nothing of the popups or containers pages.
    try std.testing.expect(cx.find(wave_id) == null);
    try std.testing.expect(cx.find(presets_id) == null);
    try std.testing.expect(!cx.dirty);
    try std.testing.expect(!ui.draw_frame(App, app, cx, 1280, 720, 120));
}

// Locks the `interact` scenario (section 4) replayed headless through `ui.dispatch` and
// `ui.draw_frame`: every value it leaves, the status line of its last action, and no overflow.
test "the interact scenario leaves the expected values" {
    const app = new_app();
    _ = frame(app);
    const interact = bench.find(App.scenarios, "interact").?;
    const steps = try bench.replay_headless(App, app, &test_context, interact, .{ 1280, 720 }, interact_steps.len + 1);
    try std.testing.expectEqual(@as(u32, interact_steps.len + 1), steps);
    // Slider 0: pressed at 74 (unchanged 0.25), released at 154: (154 - 12) / 248.
    try std.testing.expectEqual(@as(f32, 142.0 / 248.0), app.sliders[0].value);
    try std.testing.expectEqual(app.sliders[0].value, app.meter.value);
    try std.testing.expect(app.toggles[1].on == !toggle_values[1]);
    try std.testing.expectEqual(@as(f32, 0.75), app.knobs[1].value);
    try std.testing.expectEqualStrings("abc", app.field.bytes());
    try std.testing.expectEqual(@as(f32, 3 * row_px), app.view.scroll_y);
    try std.testing.expectEqual(@as(?u32, 5), app.selected);
    try std.testing.expectEqualStrings("row 5 selected", app.status_text());
    try std.testing.expectEqual(ui.Id.none, test_context.focus);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks each widget's status line: a click, a slider, a knob, and a toggle report as section 1
// says.
test "each action reports on the status line" {
    const app = new_app();
    _ = frame(app);
    const press = area_rect(app.buttons[2].id);
    const point: input.Point = .{ .x = press.x + 10, .y = press.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    try std.testing.expectEqualStrings("button 2 clicked", app.status_text());
    const ring = area_rect(app.knobs[2].id);
    const wheel: input.Wheel = .{ .x = ring.x + 20, .y = ring.y + 20, .dx = 0, .dy = 30 };
    ui.dispatch(App, app, &test_context, .{ .wheel = wheel });
    try std.testing.expectEqualStrings("knob 2 changed 0.50", app.status_text());
    _ = frame(app);
    const pill = area_rect(app.toggles[0].id);
    const on: input.Point = .{ .x = pill.x + 10, .y = pill.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(on) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(on) });
    try std.testing.expectEqualStrings("toggle 0 on", app.status_text());
}

// Locks the hover scenario: the pointer stays on button 1, so its hover aims at 1 and the
// replay never leaves the window.
test "the hover scenario keeps button 1 hovered" {
    const app = new_app();
    _ = frame(app);
    const hover = bench.find(App.scenarios, "hover").?;
    _ = try bench.replay_headless(App, app, &test_context, hover, .{ 1280, 720 }, 3);
    try std.testing.expectEqual(@as(f32, 1), app.buttons[1].hover.target);
    try std.testing.expectEqual(app.buttons[1].id, test_context.hovered());
}

// Locks the `hardware` scenario (section 4) replayed headless: the dial dragged up 40 px from
// its center moves 40 / 120 from 0.50 to 0.83, hardware button 1 clicked, hardware toggle 0
// on with its thumb (the bevel's press and the LED) aimed at 1; the default row is untouched;
// the faces drew on layer 1 and the LEDs on layer 2, the layer is back at base, and nothing
// overflowed.
test "the hardware scenario drives the skinned row" {
    const app = new_app();
    _ = frame(app);
    const scenario = bench.find(App.scenarios, "hardware").?;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, hardware_steps.len + 1);
    try std.testing.expectEqualStrings("0.83", app.hard_knobs[0].value_text[0..4]);
    try std.testing.expect(app.hard_toggles[0].on);
    try std.testing.expectEqual(@as(f32, 1), app.hard_toggles[0].thumb.target);
    try std.testing.expectEqualStrings("hardware toggle 0 on", app.status_text());
    try std.testing.expectEqual(knob_values[0], app.knobs[0].value);
    try std.testing.expect(!app.toggles[0].on);
    try std.testing.expectEqual(@as(usize, 4), test_context.draw.items(hardware.Dial).len);
    try std.testing.expectEqual(@as(usize, 4), test_context.draw.items(hardware.Bevel).len);
    const leds = test_context.draw.items(hardware.Led);
    try std.testing.expectEqual(@as(usize, 2), leds.len);
    // The replay steps no frames, so toggle 0's LED is still dark and toggle 1's (on) lit.
    try std.testing.expectEqual(@as(f32, 0), leds[0].brightness);
    try std.testing.expectEqual(@as(f32, 1), leds[1].brightness);
    try std.testing.expectEqual(@as(u8, 1), @backingInt(test_context.draw.layer_at(hardware.Dial, 0)));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(test_context.draw.layer_at(hardware.Led, 0)));
    try std.testing.expectEqual(quads.Layer.base, test_context.draw.layer_now);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks the status line of each hardware widget: a hardware button click and a wheel on a
// hardware dial report with the row's prefix.
test "hardware actions report on the status line" {
    const app = new_app();
    _ = frame(app);
    const press = area_rect(app.hard_buttons[0].id);
    const point: input.Point = .{ .x = press.x + 10, .y = press.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    try std.testing.expectEqualStrings("hardware button 0 clicked", app.status_text());
    const body = area_rect(app.hard_knobs[2].id);
    const wheel: input.Wheel = .{ .x = body.x + body.width * 0.5, .y = body.y + body.height * 0.5, .dx = 0, .dy = 12 };
    ui.dispatch(App, app, &test_context, .{ .wheel = wheel });
    try std.testing.expectEqualStrings("hardware knob 2 changed 0.60", app.status_text());
}

// Locks the `light` scenario (section 4) replayed headless: the toggle is on, the context holds
// `theme.light` and its record, the restyled colors follow it (slider 0's track, knob 2's
// accent, the field's text), the field keeps focus with "abc" selected, the drawn rows and
// group faces use the light colors, and nothing overflows. Toggling back restores
// `theme.dark` and the step 30 colors.
test "the light scenario switches the theme and restyles the widgets" {
    const app = new_app();
    _ = frame(app);
    const light = bench.find(App.scenarios, "light").?;
    _ = try bench.replay_headless(App, app, &test_context, light, .{ 1280, 720 }, light_steps.len + 1);
    try std.testing.expect(app.light.on);
    try std.testing.expect(std.meta.eql(theme.light, test_context.theme().*));
    try std.testing.expectEqual(theme.light.colors.background, test_context.draw.theme.background);
    try std.testing.expectEqual(theme.light.colors.track[0], app.sliders[0].track.r);
    try std.testing.expectEqual(theme.light.accents[2][0], app.knobs[2].accent.r);
    try std.testing.expectEqual(theme.light.colors.text, app.field.style.color);
    try std.testing.expectEqual(field_id, test_context.focus);
    try std.testing.expectEqualStrings("abc", app.field.bytes());
    try std.testing.expectEqual(@as(u32, 0), app.field.edit.selection().start);
    try std.testing.expectEqual(@as(u32, 3), app.field.edit.selection().end);
    try std.testing.expectEqualStrings("field abc", app.status_text());
    const boxes = test_context.draw.items(quads.Box);
    try std.testing.expectEqual(theme.light.colors.panel, boxes[0].fill);
    var selection_band = false;
    for (boxes) |box| selection_band = selection_band or std.meta.eql(box.fill, theme.light.colors.selection);
    try std.testing.expect(selection_band);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    test_context.event_begin(.{ .frame = 0 });
    app.restyle(&theme.dark);
    test_context.set_theme(theme.dark);
    test_context.event_end();
    try std.testing.expectEqual(widgets.accents[2], app.knobs[2].accent);
    try std.testing.expectEqual(theme.dark.colors.track[0], app.sliders[0].track.r);
}

/// Replays the popup scenario `name` headless (all its setup steps) and draws once more.
fn replay(app: *App, name: []const u8) !void {
    const scenario = bench.find(App.scenarios, name).?;
    _ = try bench.replay_headless(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1));
    _ = frame(app);
}

/// The rect of the area `id` in the last frame.
fn area_of(id: ui.Id) Rect {
    return area_rect(id);
}

// Locks the `form` scenario (section 2f): Saw is the selected segment, "loop" is ticked, and
// the password field holds "hunter2" and has focus; the status line says only that it
// changed, and nothing overflows.
test "the form scenario picks Saw, ticks loop, and types a secret" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "form");
    try std.testing.expectEqual(@as(u32, 1), app.segments.selected);
    try std.testing.expect(app.checkboxes[0].on);
    try std.testing.expectEqualStrings("hunter2", app.password.bytes());
    try std.testing.expectEqual(password_id, test_context.focus);
    try std.testing.expectEqualStrings("password changed", app.status_text());
    try std.testing.expect(app.search.bytes().len == 0);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks the `form-search` scenario (section 2f): the mixed checkbox's click turns it on and
// clears `mixed`, and "saw" typed into the search field reports on the status line.
test "the form-search scenario turns the mixed box on and searches" {
    const app = new_app();
    _ = frame(app);
    try std.testing.expect(app.checkboxes[checkbox_mixed].mixed);
    try replay(app, "form-search");
    try std.testing.expect(app.checkboxes[checkbox_mixed].on);
    try std.testing.expect(!app.checkboxes[checkbox_mixed].mixed);
    try std.testing.expectEqualStrings("saw", app.search.bytes());
    try std.testing.expectEqualStrings("search saw", app.status_text());
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks the `dropdown` scenario (section 4): the click opens the wave list with "sine"
// highlighted, Down twice and Enter choose "saw" (2), the status reads "dropdown changed 2",
// the list is closed, and focus is back on the dropdown.
test "the dropdown scenario changes the wave to 2" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "dropdown");
    try std.testing.expectEqual(@as(u32, 2), app.wave.selected);
    try std.testing.expectEqualStrings("dropdown changed 2", app.status_text());
    try std.testing.expect(!app.wave.menu.open);
    try std.testing.expectEqual(wave_id, test_context.focus);
    try std.testing.expect(test_context.find(test_context.popup_backdrop(app.wave.menu.id)) == null);
}

// Locks the popups' placement (section 3c): the File menu's first row is 2 + 4 px below the
// File button on the popup layer over a backdrop covering the window; the flip dropdown's list
// opens above it (its last row ends 2 + 4 px above the dropdown), inside the frame.
test "the file menu opens below its button and the flip list above its dropdown" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "menu-open");
    try std.testing.expect(app.file_menu.open);
    const button = area_of(file_id);
    const row0 = test_context.find(file_menu_id.derive(0)).?;
    try std.testing.expectEqual(button.x, row0.rect[0]);
    try std.testing.expectEqual(button.y + button.height + ui.popup.popup_gap + widgets.menu_pad_y, row0.rect[1]);
    try std.testing.expectEqual(@as(u8, 6), row0.layer);
    const backdrop = test_context.find(test_context.popup_backdrop(file_menu_id)).?;
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 1280, 720 }, &backdrop.rect);
    const flip_app = new_app();
    _ = frame(flip_app);
    try replay(flip_app, "menu-flip");
    const face = area_of(flip_id);
    try std.testing.expectEqual(@as(f32, 704 - 40 - 32), face.y);
    const last = test_context.find(flip_app.flip.menu.id.derive(wave_items.len - 1)).?;
    try std.testing.expectEqual(face.y - ui.popup.popup_gap - widgets.menu_pad_y, last.rect[1] + last.rect[3]);
    const first = test_context.find(flip_app.flip.menu.id.derive(0)).?;
    try std.testing.expect(first.rect[1] >= ui.popup.popup_margin);
    try std.testing.expect(first.rect[0] + first.rect[2] <= frame_w - ui.popup.popup_margin);
}

// Locks the `context` and `dismiss` scenarios (section 3c): a right click on the panel opens
// the context menu at the pointer and Reset chooses item 2; a click on the wave dropdown
// through the File menu's backdrop closes the menu and does not open the dropdown.
test "the context menu chooses Reset and an outside click only dismisses" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "context");
    try std.testing.expectEqualStrings("context Reset", app.status_text());
    try std.testing.expect(!app.context.menu.open);
    const dismiss = new_app();
    _ = frame(dismiss);
    try replay(dismiss, "dismiss");
    try std.testing.expect(!dismiss.file_menu.open);
    try std.testing.expectEqualStrings("file menu", dismiss.status_text());
    try std.testing.expect(!dismiss.wave.menu.open);
}

// Locks the `tooltip` scenario (section 3c): hovering knob 0 shows nothing until the dwell
// completes; after 500 ms of frames "gain 0.25" shows to the right of its ring on the
// tooltip layer, inside the frame, and no area was added.
test "the tooltip scenario shows the knob's name and value beside it" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "tooltip");
    const areas_before = test_context.area_list().len;
    try std.testing.expect(!app.tooltip.visible());
    var frames: u32 = 0;
    while (frames < 31) : (frames += 1) _ = ui.animate(App, app, &test_context, 1000.0 / 60.0);
    try std.testing.expect(app.tooltip.visible());
    try std.testing.expectEqualStrings("gain 0.25", app.tooltip.text_of());
    _ = frame(app);
    try std.testing.expectEqual(areas_before, test_context.area_list().len);
    const boxes = test_context.draw.items(quads.Box);
    const last = boxes.len - 1;
    try std.testing.expectEqual(quads.Layer.tooltip, test_context.draw.layer_at(quads.Box, @intCast(last)));
    const ring = area_of(app.knobs[0].id);
    try std.testing.expectEqual(ring.x + ring.width + ui.popup.popup_gap, boxes[last].rect[0]);
    try std.testing.expectEqual(ring.y, boxes[last].rect[1]);
}

// Locks the `about` scenario (section 3c): About… opens the dialog centered in the frame over a
// black face at alpha 0.4 covering the window; a press on the backdrop leaves it open, Close
// closes it with "about closed".
test "the about dialog is modal and closes on its button" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "about");
    try std.testing.expect(app.about.open);
    try std.testing.expectEqualStrings("file About…", app.status_text());
    var dimmed = false;
    for (test_context.draw.items(quads.Box)) |box| {
        dimmed = dimmed or std.meta.eql(box.fill, [4]f32{ 0, 0, 0, about_dim });
    }
    try std.testing.expect(dimmed);
    const close = area_of(close_id);
    try std.testing.expectEqual(@as(f32, 480 + 16), close.x);
    const outside: input.Point = .{ .x = 20, .y = 20 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(outside) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(outside) });
    try std.testing.expect(app.about.open);
    const press: input.Point = .{ .x = close.x + 10, .y = close.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_move = press });
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(press) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(press) });
    try std.testing.expect(!app.about.open);
    try std.testing.expectEqualStrings("about closed", app.status_text());
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks the `tabs` scenario (section 4): each tab clicked in turn leaves the containers page
// selected and reported, the bar focused, and only that page drawn: the list box, its rows,
// the two dividers, and the six number boxes, with no overflow.
test "the tabs scenario ends on the containers page" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "tabs");
    try std.testing.expectEqual(page_containers, app.tabs.selected);
    try std.testing.expectEqualStrings("page containers", app.status_text());
    try std.testing.expectEqual(tabs_id, test_context.focus);
    try std.testing.expect(test_context.find(app.buttons[0].id) == null);
    try std.testing.expect(test_context.find(app.split.divider_id()) != null);
    try std.testing.expect(test_context.find(app.side.divider_id()) != null);
    try std.testing.expect(test_context.find(app.presets.row_id(0)) != null);
    for (&app.params) |*number| try std.testing.expect(test_context.find(number.id) != null);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
}

// Locks the containers page's layout (section 2a): the horizontal splitter fills the page
// (1248 x 584 at (16, 104)), its span 1242 at ratio 0.25 gives the list pane round(310.5) = 311
// px and the divider at x 327; the vertical splitter in the right pane gives the grid
// round(0.4 * 578) = 231 px; the list's viewport is the pane inside the panel's padding.
test "the containers page splits the presets from the parameters" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "tabs");
    try expect_rect(area_rect(app.split.divider_id()), 16 + 311, page_y, widgets.splitter_px, page_h);
    const right_x = 16 + 311 + widgets.splitter_px;
    try expect_rect(area_rect(app.side.divider_id()), right_x, page_y + 231, 1264 - right_x, widgets.splitter_px);
    try expect_rect(app.presets.view.viewport, 24, page_y + 8, 311 - 16, page_h - 16);
    try std.testing.expectEqual(@as(f32, preset_count * preset_row_px), app.presets.view.content_h);
    const number = area_rect(app.params[0].id);
    try std.testing.expectEqual(right_x + group_padding, number.x);
    try std.testing.expectEqual(page_y + group_padding + caption_px + param_gap_px, number.y);
}

// Locks the `split` scenario (section 4): the divider dragged 120 px left from its middle
// leaves the list pane 311 - 120 = 191 px wide (ratio 191 / 1242) and reports it.
test "the split scenario drags the presets' divider" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "split");
    try std.testing.expectEqual(@as(f32, 191.0 / 1242.0), app.split.ratio);
    try std.testing.expectEqualStrings("split 0.15", app.status_text());
    try std.testing.expectEqual(@as(f32, 16 + 191), area_rect(app.split.divider_id()).x);
}

// Locks the `list` scenario (section 4): a click on row 3 selects preset 0004 and focuses the
// list; Down 20 times selects preset 0024 and scrolls it into view: 23 * 28 + 28 - 568 = 104.
test "the list scenario selects preset 24 and scrolls it into view" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "list");
    try std.testing.expectEqual(@as(?u32, 23), app.presets.selected);
    try std.testing.expectEqualStrings("preset 0024 selected", app.status_text());
    try std.testing.expectEqual(presets_id, test_context.focus);
    try std.testing.expectEqual(@as(f32, 104), app.presets.view.scroll_y);
    const row = area_rect(app.presets.row_id(23));
    const port = app.presets.view.viewport;
    try std.testing.expectEqual(port.y + port.height, row.y + row.height);
}

// Locks the `number` scenario (section 4), replayed a 60 Hz frame apart as regress runs it:
// the frequency dragged up 40 px is 440 + 40 * 19980 / 200 = 4436 Hz; the two clicks on the
// gain make a double click, "-6.5" and Enter commit -6.5 dB; the editor is closed.
test "the number scenario drags the frequency and types the gain" {
    const app = new_app();
    _ = frame(app);
    const scenario = bench.find(App.scenarios, "number").?;
    _ = try bench.replay_headless_paced(App, app, &test_context, scenario, .{ 1280, 720 }, @intCast(scenario.setup.len + 1), 16);
    try std.testing.expectEqual(@as(f64, 4436), app.params[0].value);
    try std.testing.expectEqual(@as(f64, -6.5), app.params[1].value);
    try std.testing.expect(!app.params[1].editing);
    try std.testing.expectEqualStrings("gain = -6.5 dB", app.status_text());
}

// Locks the generated faces (section 2b): the gallery's `text.Face` has the library's three
// tags at 0 to 2 and `icons` at 3, and its icons face is the Lucide subset: 16 icons (the
// set's 14 and the form's 2) and `.notdef`, each icon mapped, its ranges exactly
// `icons.ranges`, at 1000 units per em.
test "the gallery adds an icons face after the library's three" {
    const names = @typeInfo(text.Face).@"enum".field_names;
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqual(@as(u8, 0), @backingInt(text.Face.sans));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(text.Face.sans_bold));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(text.Face.mono));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(text.Face.icons));
    try std.testing.expectEqualStrings("icons", text.font_data.names[3]);
    const font = text.font_of(.icons);
    try std.testing.expectEqual(@as(u32, icons.kept.len + 1), font.glyph_count);
    try std.testing.expectEqual(@as(u32, 1000), font.units_per_em);
    for (icons.kept) |codepoint| try std.testing.expect(text.ttf.glyph_id(font, codepoint) != 0);
    try std.testing.expectEqualSlices([2]u21, &icons.ranges, text.font_data.face_ranges[3]);
    // The library's faces keep the default ranges.
    try std.testing.expect(text.font_data.subset);
    try std.testing.expectEqual(@as(u16, 0), text.ttf.glyph_id(font, 'A'));
}

/// The centre of each glyph quad drawn last, in logical pixels.
fn glyph_centres(out: [][2]f32) [][2]f32 {
    const glyphs = test_context.draw.items(quads.Glyph);
    assert(glyphs.len <= out.len);
    for (glyphs, out[0..glyphs.len]) |glyph, *centre| {
        centre.* = .{ glyph.rect[0] + glyph.rect[2] / 2, glyph.rect[1] + glyph.rect[3] / 2 };
    }
    return out[0..glyphs.len];
}

/// True when one of `centres` is within half a pixel of `rect`'s centre.
fn centred_in(centres: []const [2]f32, rect: Rect) bool {
    for (centres) |centre| {
        const dx = @abs(centre[0] - (rect.x + rect.width / 2));
        const dy = @abs(centre[1] - (rect.y + rect.height / 2));
        if (dx <= 0.5 and dy <= 0.5) return true;
    }
    return false;
}

// Locks the `type` scenario (section 2b): the type page under the bar, the transport's buttons
// at (24, 140) 64 px apart (56 wide, 40 tall: the panel's padding, the caption, a gap), the
// toolbar's at x 368 (16 + 336 + 8 + 8); every icon button's glyph centred on its button to
// half a pixel; no icon missing from the face, and no overflow.
test "the type scenario centres each icon in its button" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "type");
    try std.testing.expectEqual(page_type, app.tabs.selected);
    try std.testing.expectEqualStrings("page type", app.status_text());
    try expect_rect(area_rect(app.transport[0].id), 24, 140, 56, 40);
    try expect_rect(area_rect(app.transport[1].id), 88, 140, 56, 40);
    try expect_rect(area_rect(app.tools[0].id), 368, 140, 40, 40);
    var storage: [glyph_cap][2]f32 = undefined;
    const centres = glyph_centres(&storage);
    for (&app.transport) |*button| try std.testing.expect(centred_in(centres, area_rect(button.id)));
    for (&app.tools) |*button| try std.testing.expect(centred_in(centres, area_rect(button.id)));
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.text.icon_missing);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), test_context.area_overflow);
    try std.testing.expect(test_context.find(app.buttons[0].id) == null);
}

// Locks the `transport` scenario (section 2b): play shows pause while playing and reports
// "transport play"; a second click pauses; stop while playing shows play again.
// Locks the `wrap` scenarios (section 2b): the type splitter starts at half its 1242 px span
// (pane a 621); dragging 240 px left leaves 381 ("type split 0.31", divider at 16 + 381), and
// dragging far right stops at the wrapped pane's 200 px minimum (1042, "0.84", divider at
// 1058). Nothing overflows the pools on either.
test "the wrap scenarios move the type divider" {
    const wide = new_app();
    _ = frame(wide);
    try replay(wide, "wrap");
    try std.testing.expectEqual(@as(f32, 381.0 / 1242.0), wide.type_split.ratio);
    try std.testing.expectEqualStrings("type split 0.31", wide.status_text());
    try std.testing.expectEqual(@as(f32, 16 + 381), area_rect(wide.type_split.divider_id()).x);
    const narrow = new_app();
    _ = frame(narrow);
    try replay(narrow, "wrap-narrow");
    try std.testing.expectEqualStrings("type split 0.84", narrow.status_text());
    try std.testing.expectEqual(@as(f32, 16 + 1042), area_rect(narrow.type_split.divider_id()).x);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks the wrapped text's view (section 2b): at half the span everything fits (no scroll
// range, so no thumb); at the 200 px minimum the content is taller than the view, and the
// `wrap-scroll` wheel moves it to the end of its range, a frame-exact clamp.
test "the wrapped text scrolls only when it does not fit" {
    const wide = new_app();
    _ = frame(wide);
    try replay(wide, "type");
    try std.testing.expectEqual(@as(f32, 0), wide.wrap_view.max_scroll());
    const narrow = new_app();
    _ = frame(narrow);
    try replay(narrow, "wrap-narrow");
    try std.testing.expect(narrow.wrap_view.max_scroll() > 0);
    try std.testing.expectEqual(@as(f32, 0), narrow.wrap_view.scroll_y);
    const scrolled = new_app();
    _ = frame(scrolled);
    try replay(scrolled, "wrap-scroll");
    try std.testing.expect(scrolled.wrap_view.scroll_y > 0);
    try std.testing.expectEqual(scrolled.wrap_view.max_scroll(), scrolled.wrap_view.scroll_y);
}

// Locks the `surfaces` scenario (section 2d): the sixth tab draws 23 surfaces (the backdrop,
// the panel and its selected row, the bar and its selected pill, and three per card),
// the first card's shadow grows its record by 30 px a side, and nothing overflows.
test "the surfaces scenario draws the page of surfaces" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "surfaces");
    try std.testing.expectEqual(page_surfaces, app.tabs.selected);
    try std.testing.expectEqualStrings("page surfaces", app.status_text());
    const drawn = test_context.draw.items(quads.Surface);
    try std.testing.expectEqual(@as(usize, 23), drawn.len);
    var card: ?quads.Surface = null;
    for (drawn) |surface| {
        if (surface.rect[0] == 320 - 30 and surface.rect[1] == 232 - 30) card = surface;
    }
    try std.testing.expectEqual([4]f32{ 290, 202, 348, 240 }, card.?.rect);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks the surfaces page's interaction (section 2d): a click on the Radio pill and on the
// Browse row selects them, a click on Slate names it, and the pointer resting on Moss aims its
// hover at 1 with no press (Slate's back at 0); the lit gradient leaves the count of surfaces at
// 23.
test "the surfaces-click scenario selects, names, and lights" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "surfaces-click");
    try std.testing.expectEqual(@as(u32, 2), app.surfaces.pill);
    try std.testing.expectEqual(@as(u32, 1), app.surfaces.row);
    try std.testing.expectEqualStrings("card Slate", app.status_text());
    try std.testing.expectEqual(surfaces_page.card_id.derive(1), test_context.hovered());
    try std.testing.expectEqual(@as(f32, 1), app.surfaces.cards[1].hover.target);
    try std.testing.expectEqual(@as(f32, 0), app.surfaces.cards[1].down.?.target);
    try std.testing.expectEqual(@as(f32, 0), app.surfaces.cards[0].hover.target);
    try std.testing.expectEqual(@as(usize, 23), test_context.draw.items(quads.Surface).len);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks `surfaces-light` (section 2d): after the light toggle the page's first card draws the
// light palette's tinted stops, which are lighter than the dark ones, and the backdrop starts
// above the light scheme's background.
test "the surfaces-light scenario restyles the page from the light scheme" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "surfaces-light");
    try std.testing.expect(app.light.on);
    try std.testing.expectEqual(page_surfaces, app.tabs.selected);
    const palette = surfaces_page.Palette.of(&theme.light);
    var found = false;
    for (test_context.draw.items(quads.Surface)) |surface| {
        if (surface.rect[0] != 320 - 30 or surface.rect[1] != 232 - 30) continue;
        found = true;
        try std.testing.expect(surface.fill_a[0] > surfaces_page.cards[0].from[0]);
    }
    try std.testing.expect(found);
    try std.testing.expect(palette.backdrop_from[1] > theme.light.colors.background[1]);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

test "the transport scenario turns play into pause" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "transport");
    try std.testing.expect(app.playing);
    try std.testing.expectEqualStrings("transport play", app.status_text());
    try std.testing.expectEqualSlices(u8, &pause_label[0], app.transport[transport_play].label);
    const again = [_]bench.Step{.{ .click = bench.area("transport", transport_play) }};
    const pause: bench.Scenario = .{ .name = "pause", .setup = &again, .cycle = &.{.{ .wait = 1 }}, .frames = 1 };
    _ = try bench.replay_headless(App, app, &test_context, &pause, .{ 1280, 720 }, 2);
    try std.testing.expect(!app.playing);
    try std.testing.expectEqualStrings("transport pause", app.status_text());
    const play_then_stop = [_]bench.Step{
        .{ .click = bench.area("transport", transport_play) },
        .{ .click = bench.area("transport", transport_stop) },
    };
    const stop: bench.Scenario = .{ .name = "stop", .setup = &play_then_stop, .cycle = &.{.{ .wait = 1 }}, .frames = 1 };
    _ = try bench.replay_headless(App, app, &test_context, &stop, .{ 1280, 720 }, 3);
    try std.testing.expect(!app.playing);
    try std.testing.expectEqualStrings("transport stop", app.status_text());
    try std.testing.expectEqualSlices(u8, &transport_labels[transport_play], app.transport[transport_play].label);
}

// Locks the toolbar (section 2b): a click on save reports "toolbar save", and hovering the
// settings button past the dwell shows its "Settings" tooltip.
test "the toolbar reports clicks and shows tooltips" {
    const app = new_app();
    _ = frame(app);
    const steps = [_]bench.Step{
        .{ .click = tab(page_type) },
        .{ .click = bench.area("tool", 1) },
        .{ .hover = .{ .target = bench.area("tool", 2), .x = 20, .y = 20 } },
    };
    const scenario: bench.Scenario = .{ .name = "tools", .setup = &steps, .cycle = &.{.{ .wait = 1 }}, .frames = 1 };
    _ = try bench.replay_headless(App, app, &test_context, &scenario, .{ 1280, 720 }, steps.len + 1);
    try std.testing.expectEqualStrings("toolbar save", app.status_text());
    var frames: u32 = 0;
    while (frames < 31) : (frames += 1) _ = ui.animate(App, app, &test_context, 1000.0 / 60.0);
    try std.testing.expect(app.tooltip.visible());
    try std.testing.expectEqualStrings("Settings", app.tooltip.text_of());
}

// Locks the preset names: row 0 is "preset 0001" and row 999 "preset 1000".
test "preset names count from 0001" {
    var bytes: [preset_name_cap]u8 = undefined;
    try std.testing.expectEqualStrings("preset 0001", preset_name(&bytes, 0));
    try std.testing.expectEqualStrings("preset 1000", preset_name(&bytes, 999));
}

const Renderer = patchwork.renderer.Renderer(Context.DrawContext);

/// The frame the renderer records for the test context at 1280 by 720.
fn record(renderer: *Renderer, buffer: *patchwork.commands.CommandBuffer) void {
    buffer.reset();
    renderer.frame(buffer, &test_context.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = 1280,
        .height_px = 720,
        .scale_120 = 120,
    }, 0);
}

// Locks the cost of a theme switch (section 3a) as the renderer records it: the click on the
// "light" toggle draws once and records one stream whose first write is the whole 256-byte
// uniform and whose pass is direct (every tile changed), cleared to light's background; the
// thumb then eases over frames that each repaint only the toggle (cached); once settled the
// gallery records nothing.
test "a theme switch records one uniform write and one full repaint" {
    const static = struct {
        var renderer: Renderer = undefined;
        var buffer: patchwork.commands.CommandBuffer = undefined;
    };
    const renderer = &static.renderer;
    const buffer = &static.buffer;
    const app = new_app();
    renderer.init();
    buffer.* = .init();
    renderer.setup(buffer, &test_context.draw);
    _ = frame(app);
    record(renderer, buffer);
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.skipped, renderer.last);
    const pill = area_rect(theme_id);
    const point: input.Point = .{ .x = pill.x + 10, .y = pill.y + 10 };
    ui.dispatch(App, app, &test_context, .{ .pointer_down = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .{ .pointer_up = input.left_at(point) });
    ui.dispatch(App, app, &test_context, .pointer_leave);
    try std.testing.expect(ui.draw_frame(App, app, &test_context, 1280, 720, 120));
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.direct, renderer.last);
    var reader = buffer.reader();
    const first = reader.next().?.buffer_write;
    try std.testing.expectEqual(renderer.resources.uniform_buffer, first.id);
    try std.testing.expectEqual(@as(u32, 256), first.data.len);
    var uniform_writes: u32 = 0;
    var written: u32 = 0;
    var writes: u32 = 0;
    reader = buffer.reader();
    while (reader.next()) |op| switch (op) {
        .buffer_write => |write| {
            writes += 1;
            written += write.data.len;
            if (write.id == renderer.resources.uniform_buffer) uniform_writes += 1;
        },
        .pass_begin => |pass| try std.testing.expectEqual(theme.light.colors.background, pass.clear),
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 1), uniform_writes);
    // The uniform and the seven pools' changed ranges (Box, Arc, Glyph, the hardware row's
    // Dial, Bevel, and Led, and the checked checkbox's mark, a Path): every text and face
    // color moved. The mark's points do not move, so the point buffer is not written.
    try std.testing.expectEqual(@as(u32, 8), writes);
    try std.testing.expect(written > 256);
    var frames: u32 = 0;
    while (ui.animate(App, app, &test_context, 1000.0 / 60.0)) : (frames += 1) {
        _ = ui.draw_frame(App, app, &test_context, 1280, 720, 120);
        record(renderer, buffer);
        try std.testing.expect(renderer.last == .full or renderer.last == .cached);
        try std.testing.expect(frames < 30);
    }
    _ = ui.draw_frame(App, app, &test_context, 1280, 720, 120);
    record(renderer, buffer);
    record(renderer, buffer);
    try std.testing.expectEqual(patchwork.renderer.Kind.skipped, renderer.last);
    try std.testing.expectEqual(@as(u32, 0), buffer.count);
}

// Locks the `glass` scenario (section 2e): the seventh tab marks two backdrops, the page's at
// layer 3 with the frosted blur of 16 and the lens's on the popup layer; four glass faces (the
// sidebar, the bar, the transport, and the lens) sample them, the first three backdrop A and the
// lens backdrop B; twelve cards show at the top of the view, so 25 surfaces with the gradient.
test "the glass scenario marks two backdrops under four glass faces" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "glass");
    try std.testing.expectEqual(page_glass, app.tabs.selected);
    try std.testing.expectEqualStrings("page glass", app.status_text());
    const marked = test_context.draw.backdrop_list();
    try std.testing.expectEqual(@as(usize, 2), marked.len);
    try std.testing.expectEqual(@as(u8, 3), marked[0].layer);
    try std.testing.expectEqual(@as(f32, 16), marked[0].blur);
    try std.testing.expectEqual(@as(u8, 6), marked[1].layer);
    const glass = test_context.draw.items(quads.Glass);
    try std.testing.expectEqual(@as(usize, 4), glass.len);
    try std.testing.expectEqual(@as(usize, 25), test_context.draw.items(quads.Surface).len);
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks `glass-popup` (section 2e): the output list is open on the popup layer with a glass
// face, a fifth glass that samples backdrop B, which keeps the wider of the list's blur (16)
// and the lens's (4); and its highlighted band draws under the labels.
test "the glass-popup scenario opens a glass list over the glass sidebar" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "glass-popup");
    try std.testing.expect(app.glass.output.menu.open);
    try std.testing.expectEqual(@as(usize, 5), test_context.draw.items(quads.Glass).len);
    const marked = test_context.draw.backdrop_list();
    try std.testing.expectEqual(@as(f32, 16), marked[1].blur);
    try std.testing.expectEqual(quads.Layer.popup, test_context.draw.layer_at(quads.Glass, 4));
    // Down highlighted row 1, whose band draws under the labels: on the popup layer the Box
    // batch (the glass face's hairline) opens before the Glyph batch, which row 0's label
    // opened.
    try std.testing.expectEqual(@as(?u32, 1), app.glass.output.menu.highlight);
    test_context.draw.finalize();
    var box_at: ?usize = null;
    var glyph_at: ?usize = null;
    for (test_context.draw.batch_list(), 0..) |batch, index| {
        if (batch.layer != @backingInt(quads.Layer.popup)) continue;
        const box_id = comptime Context.DrawContext.Registry.id(quads.Box);
        const glyph_id = comptime Context.DrawContext.Registry.id(quads.Glyph);
        if (batch.type_id == box_id and box_at == null) box_at = index;
        if (batch.type_id == glyph_id and glyph_at == null) glyph_at = index;
    }
    try std.testing.expect(box_at.? < glyph_at.?);
}

// Locks `glass-clear` and the solid material (section 2e): the Clear segment picks the clear
// material for the sidebar and the list ("material Clear", backdrop A's blur 4); picking Solid
// marks no backdrop for the page, so only the lens is glass.
test "the glass-clear scenario picks the clear material and solid drops the glass" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "glass-clear");
    try std.testing.expectEqualStrings("material Clear", app.status_text());
    try std.testing.expectEqual(theme.Material.Kind.clear, app.glass.output.menu.material.?.kind);
    try std.testing.expectEqual(@as(f32, 4), test_context.draw.backdrop_list()[0].blur);
    app.glass.material = 3;
    app.glass.output.menu.material = .solid;
    _ = frame(app);
    try std.testing.expectEqual(@as(usize, 1), test_context.draw.backdrop_list().len);
    try std.testing.expectEqual(@as(usize, 1), test_context.draw.items(quads.Glass).len);
}

// Locks `glass-scroll` (section 2e): the setup's wheel scrolls the cards 120 px under the glass.
test "the glass-scroll scenario scrolls the cards under the glass" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "glass-scroll");
    try std.testing.expectEqual(@as(f32, 120), app.glass.view.scroll_y);
}

test {
    _ = hardware;
    _ = surfaces_page;
    _ = glass_page;
}

comptime {
    patchwork.app.check(App);
}

// Locks the `files` and `drop-hover` scenarios (section 2c): the zone is 400 x 200 at the
// page's top-left with one drop area, and a drag over it highlights its border in the accent.
test "the drop zone highlights under a file drag" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "files");
    try std.testing.expectEqual(page_files, app.tabs.selected);
    try expect_rect(area_rect(files_page.zone_id), 16, 104, 400, 200);
    try std.testing.expect(test_context.find(files_page.zone_id).?.flags.drop);
    try std.testing.expect(!test_context.drop_hovering(files_page.zone_id));
    try replay(app, "drop-hover");
    try std.testing.expect(test_context.drop_hovering(files_page.zone_id));
    var found = false;
    for (test_context.draw.items(quads.Box)) |box| {
        if (box.rect[0] == 16 and box.rect[1] == 104 and box.rect[2] == 400) {
            try std.testing.expectEqual(@as(f32, 2), box.border_width);
            try std.testing.expectEqual(test_context.theme().accents[0], box.border_color);
            found = true;
        }
    }
    try std.testing.expect(found);
}

// Locks the `drop` scenario (section 2c): three files listed with their sizes and statuses
// ("tone.wav 93.8 KB done", "readme.txt 112 B done", "samples folder"), the tone decoded to
// 48,000 samples of 48 kHz mono, its waveform drawn one column per pixel, and the status line.
test "the drop scenario lists three files and draws the tone" {
    const app = new_app();
    _ = frame(app);
    try replay(app, "drop");
    const page = &app.drops;
    try std.testing.expectEqual(@as(u8, 3), page.count);
    try std.testing.expectEqualStrings("tone.wav", page.names[0][0..page.name_lens[0]]);
    try std.testing.expectEqual(@as(u64, 96044), page.sizes[0]);
    try std.testing.expectEqual(@as(u64, 96044), page.received[0]);
    try std.testing.expectEqual(files_page.Status.done, page.status[0]);
    try std.testing.expectEqual(files_page.Status.done, page.status[1]);
    try std.testing.expectEqual(@as(u64, 112), page.received[1]);
    try std.testing.expectEqual(files_page.Status.folder, page.status[2]);
    try std.testing.expectEqual(@as(u32, 48000), page.decoder.count);
    try std.testing.expectEqual(@as(u32, 48000), page.decoder.rate);
    try std.testing.expect(page.shown);
    try std.testing.expectEqualStrings("tone.wav · 48000 Hz · mono · 16-bit · 1.00 s", page.info[0..page.info_len]);
    try std.testing.expectEqualStrings("file readme.txt done", app.status_text());
    const waves = test_context.draw.items(quads.Waveform);
    try std.testing.expectEqual(@as(usize, 1), waves.len);
    try std.testing.expectEqual(@as(f32, 824 * 2), waves[0].point_count);
    var size: [16]u8 = undefined;
    try std.testing.expectEqualStrings("93.8 KB", files_page.size_text(&size, 96044));
    try std.testing.expectEqualStrings("112 B", files_page.size_text(&size, 112));
    try std.testing.expectEqualStrings("4.0 MB", files_page.size_text(&size, 4 << 20));
    try std.testing.expect(!test_context.drop_hovering(files_page.zone_id));
    try std.testing.expectEqual(@as(u32, 0), test_context.draw.overflow_count);
}

// Locks the big-file path (section 2c): a 30 s WAV dropped with a text file fills the
// 1,048,576 samples, cancels only itself ("cut at 21.8 s"), and the text file after it still
// arrives; the waveform shows what was kept.
test "a long wav is cut at the sample cap and cancels only itself" {
    const app = new_app();
    _ = frame(app);
    const seconds: u32 = 30;
    const long_header = comptime @import("wav.zig").header(48000, 1, 48000 * 2 * 30);
    const long = [_]bench.File{
        .{ .name = "long.WAV", .parts = &.{
            .{ .bytes = &long_header },
            .{ .bytes = &files_page.tone_cycle, .repeat = 120 * seconds },
        } },
        .{ .name = "notes.txt", .parts = &.{.{ .bytes = "abc" }} },
    };
    const steps = [_]bench.Step{
        .{ .click = tab(page_files) },
        .{ .drop = .{ .target = drop_zone, .files = &long } },
    };
    const scenario: bench.Scenario = .{ .name = "long", .setup = &steps, .cycle = &.{.{ .wait = 1 }}, .frames = 1 };
    _ = try bench.replay_headless(App, app, &test_context, &scenario, .{ 1280, 720 }, 3);
    _ = frame(app);
    const page = &app.drops;
    try std.testing.expectEqual(files_page.Status.cut, page.status[0]);
    try std.testing.expectEqual(files_page.samples_max, page.decoder.count);
    try std.testing.expectEqualStrings("cut at 21.8 s", page.cut_text[0..page.cut_len]);
    try std.testing.expect(page.received[0] < page.sizes[0]);
    try std.testing.expectEqual(files_page.Status.done, page.status[1]);
    try std.testing.expect(page.shown);
}

//! Live example: the live-coding screen. A patch in the code editor, knobs bound to its
//! `k(lo~value~hi, "name")` calls, curves from each value to its knob, an inline shaper row,
//! automation lanes, and a transport.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! Text and widgets bound in both directions with no DSL evaluation and no audio: the values
//! are UI state that lives in the text. Editing a number moves its knob; dragging a knob
//! rewrites the number with the same decimals, one undo entry per gesture. Every worked number
//! lives in this file's tests, for example "live layout at 1280 by 720".
//!
//! ## 2. Layout (logical pixels)
//! ```text
//! frame        overlay, fill by fill
//!   body       overlay, margin top header_px
//!     panel    panel_width(w) by fill at the right (none below panel_window_min_px)
//!       band   fill by band_px: back, play/pause, record (`icon.zig`)
//!       column a view of uniform row_px rows (`ui.List`): ring 44, label, lane
//!     editor   the rest by fill: the patch, with one inline row per shape() call
//!   curves     layer 2, clipped to the body left of the rings
//!   header     fill by header_px, drawn last: name, check or cross, the bound count, key,
//!              bpm field, snap, line:col, and the refusal status
//! ```
//! The panel is `min(panel_px_max, 0.3 * w)` wide; the lane takes what the knob and label
//! leave and is hidden below `lane_min_px`. The panel draws before the editor so the path
//! pool holds the lanes, then the shaper curves, then the binding curves.
//!
//! ## 3. Binding Data Flow
//! ```text
//! revision the app did not cause -> bindings.Parse.run (full pass) -> decorations (a box per
//!   bound value, the errors), inline rows, lanes bound, bpm field reloaded
//! knob grabbed  -> gesture_begin; the knob owns the literal until release
//! knob turned   -> position += delta; steps = lo + round(position * (hi - lo)); when the
//!                  step changed: Editor.replace + Parse.shift, parsed revision = revision
//! knob released -> gesture_end (one undo entry) and one full pass
//! ```
//! A wheel run on one knob is one gesture, closed by any event other than a wheel on that
//! knob, a pointer move, or a frame. While a drag is held, keys and pastes are dropped (undo
//! would assert inside a gesture); a wheel gesture is closed and the key routed. A right press
//! resets to the value at load (matched by label), or to lo for a binding added since.
//!
//! ## 4. Curves
//! One cubic per binding with a visible end, from the right edge of the value (`rect_of`) to
//! the ring's left edge, with horizontal tangents. A value scrolled out of the editor clamps
//! to its viewport's edge, a knob scrolled out of the column to the column's. Alpha
//! `curve_near_alpha` for the caret's line and a hovered or held knob, `curve_far_alpha`
//! otherwise; a change of alpha rewrites `Path` records only.
//!
//! ## 5. Transport and Lanes
//! `lanes.zig` holds the semantics. `config.timer_period_ms` is 33 and `timer_armed` false:
//! play starts the host timer (`cx.set_timer`), pause stops it, so a paused screen sleeps.
//! Each lane plots its ring against the binding's `[lo, hi]` anchored at the lane rect
//! (`path.polyline_at`), and one Box on layer 2 is the playhead. While record is armed, a
//! `Glow` (`glow.zig`, an animated draw type) breathes around the record icon at
//! `record_glow_hz` from the frame's time, playing or not; armed and paused, frames repaint
//! only the glow's tiles and run no `App.draw`. Disarmed and paused, nothing animates.
//!
//! ## 6. Texts
//! F1 loads `patch.lpg` (embedded), F2 a generated stress text of 2,000 lines: 50 lines of
//! 120 columns in the middle (lines 975 to 1024) and short nameless bindings around them,
//! 58,699 bytes in all. Each long line ends in a cut call, so the stress text has 50 errors
//! and 2,100 well-formed calls, of which 64 bind.
//!
//! ## 7. Contract With the Library
//! Every pool, the point pool, and the areas are sized for their worst case in the comptime
//! block after the constants; tests assert nothing overflows.
//!
//! ## 8. TigerStyle Invariants
//! - The app is static in both hosts; nothing allocates.
//! - Per-frame work is bounded by the visible lines, the bindings, the visible column rows,
//!   and the inline rows, never by capacities.

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
const editor = patchwork.editor;
const fixed_point = editor.literal;
const bindings = @import("bindings.zig");
const knob = @import("knob.zig");
const shaper = @import("shaper.zig");
const lanes = @import("lanes.zig");
const icon = @import("icon.zig");
const glow = @import("glow.zig");
const live_bench = @import("bench.zig");

const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.path.Point;
const Context = patchwork.app.Context(App);
const binding_cap = bindings.binding_cap;
const literal_cap = bindings.literal_cap;

/// The embedded patch the editor opens with.
pub const patch_source = @embedFile("patch.lpg");

// Header (section 2). Offsets are from the header's inner left edge.
const header_px: f32 = 40;
const header_inset_px: f32 = 16;
const name_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.dark.colors.text };
const position_style: text.Style = .{ .face = .mono, .size = 14, .color = theme.dark.colors.text };
const status_style: text.Style = .{ .face = .sans, .size = 14, .color = .{ 0.95, 0.55, 0.45, 1 } };
const dim_style: text.Style = .{ .face = .sans, .size = 14, .color = .{ 0.62, 0.64, 0.68, 1 } };
const field_style: text.Style = .{ .face = .mono, .size = 14, .color = theme.dark.colors.text };
const name_width_px: f32 = 160;
const status_icon_left_px: f32 = 168;
const status_icon_px: f32 = 16;
const count_left_px: f32 = 192;
const count_width_px: f32 = 76;
const key_left_px: f32 = 272;
const bpm_left_px: f32 = 336;
const bpm_width_px: f32 = 40;
const bpm_height_px: f32 = 26;
const bpm_unit_left_px: f32 = 382;
const snap_left_px: f32 = 418;
const position_left_px: f32 = 470;
const position_width_px: f32 = 80;
const check_color: [4]f32 = .{ 0.45, 0.82, 0.48, 1 };
const cross_color: [4]f32 = .{ 0.95, 0.40, 0.38, 1 };

/// Bytes of the header's texts, which bound its glyphs.
const name_cap: u32 = 22;
const count_cap: u32 = 12;
const key_text = "C major";
const unit_text = "bpm";
const snap_text = "snap";
const bpm_digits_max: u32 = 3;
const position_cap: u32 = 10;
const status_cap: u32 = 34;
const header_glyph_cap: u32 = name_cap + count_cap + key_text.len + bpm_digits_max +
    unit_text.len + snap_text.len + position_cap + status_cap;
const bpm_min: u32 = 20;
const bpm_max: u32 = 300;

// Panel and column (section 2).
const panel_px_max: f32 = 380;
const panel_share: f32 = 0.3;
const panel_window_min_px: f32 = 640;
const band_px: f32 = 40;
const row_px: f32 = 48;
const ring_px: f32 = 44;
const ring_left_px: f32 = 4;
const label_left_px: f32 = ring_left_px + ring_px + 8;
const knob_column_px: f32 = 140;
const lane_min_px: f32 = 120;
const lane_inset_px: f32 = 6;
const label_cap: u32 = 16;
const label_style: text.Style = .{ .face = .sans, .size = 13, .color = theme.dark.colors.text };
const struck_style: text.Style = .{ .face = .mono, .size = 11, .color = .{ 0.62, 0.64, 0.68, 1 } };
const transport_hit_px: f32 = 28;
const transport_icon_px: f32 = 18;
const transport_left_px: f32 = 12;
const transport_gap_px: f32 = 8;
const transport_color: [4]f32 = .{ 0.80, 0.82, 0.85, 1 };
const record_color: [4]f32 = .{ 0.95, 0.30, 0.30, 1 };
const record_idle_color: [4]f32 = .{ 0.55, 0.35, 0.35, 1 };
/// The armed record glow: the record color at partial alpha, one breath per second.
const record_glow_color: [4]f32 = .{ 0.95, 0.30, 0.30, 0.9 };
const record_glow_hz: f32 = 1;
const lane_fill: [4]f32 = .{ 1, 1, 1, 0.03 };
const playhead_color: [4]f32 = .{ 0.95, 0.95, 0.90, 0.85 };
const playhead_px: f32 = 1.5;
const lane_stroke_px: f32 = 1.5;

// Inline shaper rows (section 2).
const inline_row_px: f32 = 96;
const inline_ring_px: f32 = 64;
const inline_cell_px: f32 = 76;
const inline_pad_px: f32 = 8;
const plot_px_max: f32 = 240;
const plot_min_px: f32 = 40;
const inline_fill: [4]f32 = .{ 1, 1, 1, 0.025 };
const plot_color: [4]f32 = .{ 0.86, 0.87, 0.84, 0.9 };
const disabled_color: [4]f32 = .{ 0.5, 0.5, 0.5, 1 };

// Curves (section 4).
pub const curve_layer: quads.Layer = @fromBackingInt(2);
const curve_px: f32 = 1.5;
const curve_near_alpha: f32 = 0.85;
const curve_far_alpha: f32 = 0.35;

/// Accents by binding index.
const accent_count: u32 = 8;
const accents: [accent_count][4]f32 = .{
    .{ 0.62, 0.45, 0.86, 1 },
    .{ 0.92, 0.48, 0.78, 1 },
    .{ 0.40, 0.82, 0.48, 1 },
    .{ 0.93, 0.80, 0.32, 1 },
    .{ 0.93, 0.55, 0.24, 1 },
    .{ 0.40, 0.70, 0.95, 1 },
    .{ 0.45, 0.85, 0.80, 1 },
    .{ 0.95, 0.45, 0.42, 1 },
};

/// Stress text shape (section 6).
pub const stress_lines: u32 = 2000;
pub const stress_long_first: u32 = 975;
pub const stress_long_count: u32 = 50;
pub const stress_long_columns: u32 = 120;

// Worst cases per frame (section 7).
const transport_count: u32 = 3;
const inline_knob_cap: u32 = bindings.shape_cap * bindings.shape_args;
/// The editor: its faces, a current line or selection band per visible line, a box per
/// bound value and two per error, the caret, and its thumb; the inline row faces; the panel,
/// one lane face per row, the held knob's bar, the column thumb, and the playhead; the header
/// and the bpm field's face, selection, and caret.
const box_cap: u32 = (2 + editor.lines_max + 2 * editor.decoration_cap + 1 + 1) +
    bindings.shape_cap + (1 + binding_cap + 1 + 1 + 1) + (1 + 3);
/// A track and a value arc per knob.
const arc_cap: u32 = 2 * (binding_cap + inline_knob_cap);
/// The editor, the header, a value and a label per knob, and the held knob's original.
const glyph_cap: u32 = editor.glyph_max + header_glyph_cap +
    (binding_cap + inline_knob_cap) * (literal_cap + label_cap) + literal_cap;
/// Lanes, then shaper curves, then binding curves, each at its most chunks.
const path_cap: u32 = binding_cap * quads.path.chunks_max(lanes.sample_count) +
    bindings.shape_cap * quads.path.chunks_max(shaper.sample_count) +
    binding_cap * quads.path.chunks_max(quads.path.cubic_points_max);
const point_need: u32 = binding_cap * lanes.sample_count +
    bindings.shape_cap * shaper.sample_count + binding_cap * quads.path.cubic_points_max;
const point_cap: u32 = 24_576;
const icon_cap: u32 = transport_count + 1;
/// The armed record button's glow.
const glow_cap: u32 = 1;
/// The editor's area, view, and thumb; the column view and thumb; every knob; the transport;
/// the bpm field.
const area_cap: u32 = 3 + 2 + binding_cap + inline_knob_cap + transport_count + 1;

const editor_id = ui.id("editor", 0);
const column_id = ui.id("column", 0);
const bpm_id = ui.id("bpm", 0);
const transport_ids = [transport_count]ui.Id{
    ui.id("transport", 0),
    ui.id("transport", 1),
    ui.id("transport", 2),
};
const transport_flags: ui.Flags = .{
    .wheel = false,
    .focusable = false,
    .tab = false,
    .cursor = .pointer,
};

comptime {
    assert(header_glyph_cap == 95);
    assert(box_cap == 4_332);
    assert(arc_cap == 384);
    assert(glyph_cap == 32_560);
    assert(path_cap == 5_632);
    assert(point_need == 22_592);
    assert(point_need <= point_cap);
    assert(area_cap == 201);
    assert(knob_column_px + lane_min_px + ui.view.gutter_px <= panel_px_max);
    assert(stress_long_first + stress_long_count <= stress_lines);
    assert(bindings.shape_cap == editor.row_cap);
    assert(inline_row_px <= editor.row_height_max);
    assert(@backingInt(curve_layer) > @backingInt(editor.over_layer));
    assert(@backingInt(curve_layer) < @backingInt(quads.Layer.overlay));
}

pub const Text = enum(u8) {
    patch,
    stress,
};

/// The knob gesture in progress (section 3).
const Grip = struct {
    kind: Kind,
    id: ui.Id,
    binding: u8,
    /// The knob's continuous position in its range, `[0, 1]`.
    position: f32,
    drag_y: f32,
    wrote: bool,
    /// The literal when the gesture began, shown struck through until release.
    original: [literal_cap]u8,
    original_len: u8,

    const Kind = enum(u8) { none, drag, wheel };

    const idle: Grip = .{
        .kind = .none,
        .id = .none,
        .binding = 0,
        .position = 0,
        .drag_y = 0,
        .wrote = false,
        .original = @splat(0),
        .original_len = 0,
    };
};

/// A binding's value at load, for the right-press reset.
const Default = struct {
    key: u64,
    fixed: bindings.Fixed,
};

/// Where the last draw put the column, for curves and event routing.
const Column = struct {
    shown: bool,
    viewport: Rect,
    ring_x: f32,
    first: u32,
    end: u32,
    lane_x: f32,
    lane_width: f32,
};

pub const App = struct {
    editor: editor.Editor,
    shown: Text,
    parse: bindings.Parse,
    parsed_revision: u64,
    /// Full passes so far: a knob drag must not add any until release.
    parse_count: u64,
    defaults: [binding_cap]Default,
    default_count: u32,
    grip: Grip,
    transport: lanes.Transport,
    lanes: lanes.Lanes(binding_cap),
    column_view: ui.ViewState,
    column: Column,
    /// Curves the last draw appended.
    curve_count: u32,
    bpm_field: widgets.TextField,
    load_mark: u64,
    status: [status_cap]u8,
    status_len: u32,
    stress: [editor.buffer.buffer_cap]u8,
    stress_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "live",
        .timer_period_ms = 33,
        .timer_armed = false,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
            .{ .type = quads.Arc, .cap = arc_cap },
            .{ .type = quads.Path, .cap = path_cap },
            .{ .type = icon.Icon, .cap = icon_cap },
            .{ .type = glow.Glow, .cap = glow_cap },
        },
        .batch_cap = 16,
        .area_cap = area_cap,
        .point_cap = point_cap,
    };

    /// The bench runs (`bench.zig`): idle, then transport and typing on the patch and the
    /// stress text.
    pub const scenarios: []const patchwork.bench.Scenario = &live_bench.scenarios;

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.editor.init(editor_id, editor.default_style);
        app.stress_len = generate_stress(&app.stress);
        app.status_len = 0;
        app.parse_count = 0;
        app.grip = Grip.idle;
        app.transport = .stopped;
        app.lanes.init();
        app.column_view = ui.ViewState.init();
        app.column = .{
            .shown = false,
            .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .ring_x = 0,
            .first = 0,
            .end = 0,
            .lane_x = 0,
            .lane_width = 0,
        };
        app.curve_count = 0;
        app.bpm_field = widgets.TextField.init(bpm_id, bpm_digits_max, field_style);
        app.show(.patch);
        assert(app.editor.buffer.line_count > 1);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        app.close_wheel(cx, event_value);
        if (app.grip.kind == .drag and !cx.holds(app.grip.id)) app.release(cx);
        switch (event_value) {
            .key_down => |press| {
                if (app.grip.kind == .drag) return;
                if (press.key == .f1 or press.key == .f2) {
                    app.show(if (press.key == .f1) .patch else .stress);
                    cx.redraw();
                    return;
                }
            },
            .paste => if (app.grip.kind == .drag) return,
            else => {},
        }
        app.route_transport(cx, event_value);
        app.route_bpm(cx, event_value);
        app.route_knobs(cx, event_value);
        _ = app.column_view.handle(cx, column_id, event_value);
        switch (app.editor.handle(cx, event_value)) {
            .none => {},
            .changed => app.status_len = 0,
            .refused => app.set_status(null),
        }
        app.sync();
    }

    /// One transport tick (section 5): record at the head, then advance it.
    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = now_ms;
        if (!app.transport.playing) return;
        if (app.transport.recording) {
            const head = app.transport.head;
            for (0..app.parse.binding_count) |index| {
                const value = fixed_point.to_f32(app.parse.bindings[index].value.fixed);
                _ = app.lanes.write(@intCast(index), head, value);
            }
        }
        app.transport.step();
        cx.redraw();
    }

    pub fn draw(app: *App, cx: *Context) void {
        assert(app.parsed_revision == app.editor.revision());
        _ = cx.begin(ui.sized(.fill, .fill), ui.flow_of(.overlay));
        const body_walk: ui.Walk = .{ .width = .fill, .height = .fill, .margin = .sides(0, header_px, 0, 0) };
        const body = cx.begin(body_walk, .{ .flow = .overlay });
        const panel_width = panel_width_of(body.width);
        app.column.shown = false;
        app.curve_count = 0;
        if (panel_width > 0) app.draw_panel(cx, body, panel_width);
        app.draw_editor(cx, body.width - panel_width);
        _ = cx.end();
        if (app.column.shown) app.draw_curves(cx, body);
        app.draw_header(cx);
        _ = cx.end();
    }

    // ------------------------------------------------------------------ texts

    fn show(app: *App, shown: Text) void {
        const source = switch (shown) {
            .patch => patch_source,
            .stress => app.stress[0..app.stress_len],
        };
        app.load(source);
        app.shown = shown;
    }

    /// Loads `source` (history cleared), parses it, and records the load-time values.
    fn load(app: *App, source: []const u8) void {
        assert(app.grip.kind == .none);
        const loaded = app.editor.load(source);
        assert(loaded);
        app.status_len = 0;
        app.column_view.scroll_y = 0;
        app.reparse();
        app.default_count = app.parse.binding_count;
        for (0..app.parse.binding_count) |index| {
            var buffer: [label_cap]u8 = undefined;
            app.defaults[index] = .{
                .key = lanes.key_of(app.label_of(@intCast(index), &buffer)),
                .fixed = app.parse.bindings[index].value.fixed,
            };
        }
        app.load_mark = app.editor.history_mark();
    }

    fn set_status(app: *App, what_override: ?[]const u8) void {
        const what = what_override orelse switch (app.editor.refused_source) {
            .key => "edit",
            .paste => "paste",
            .call => "load",
        };
        const why = switch (app.editor.refusal) {
            .none, .bytes => "buffer full",
            .lines => "line limit",
        };
        const printed = std.fmt.bufPrint(&app.status, "{s} refused: {s}", .{ what, why });
        app.status_len = @intCast((printed catch unreachable).len);
        assert(app.status_len <= status_cap);
    }

    // ---------------------------------------------------------------- parsing

    /// Runs the full pass when the text changed in a way the app did not cause (section 3).
    fn sync(app: *App) void {
        if (app.parsed_revision == app.editor.revision()) return;
        app.reparse();
    }

    fn reparse(app: *App) void {
        assert(app.grip.kind == .none);
        app.parse.run(&app.editor.buffer);
        app.parse_count += 1;
        app.parsed_revision = app.editor.revision();
        for (0..app.parse.binding_count) |index| {
            var buffer: [label_cap]u8 = undefined;
            const lane_key = lanes.key_of(app.label_of(@intCast(index), &buffer));
            const value = fixed_point.to_f32(app.parse.bindings[index].value.fixed);
            app.lanes.bind(@intCast(index), lane_key, value);
        }
        app.decorate();
        app.load_bpm();
        assert(app.parsed_revision == app.editor.revision());
    }

    /// A box per bound value, every kept error, and one inline row per shape.
    fn decorate(app: *App) void {
        const shown = &app.editor;
        shown.decoration_count = 0;
        for (app.parse.bindings[0..app.parse.binding_count]) |binding| {
            shown.decorations[shown.decoration_count] = .{
                .start = binding.value.range.start,
                .end = binding.value.range.end,
                .kind = .box,
            };
            shown.decoration_count += 1;
        }
        for (app.parse.errors[0..app.parse.error_count]) |range| {
            shown.decorations[shown.decoration_count] = .{
                .start = range.start,
                .end = range.end,
                .kind = .@"error",
            };
            shown.decoration_count += 1;
        }
        assert(shown.decoration_count <= editor.decoration_cap);
        shown.row_count = app.parse.shape_count;
        for (app.parse.shapes[0..app.parse.shape_count], 0..) |shape, index| {
            shown.rows[index] = .{ .after_line = shape.line, .height = inline_row_px };
        }
        assert(shown.row_count <= editor.row_cap);
    }

    fn load_bpm(app: *App) void {
        const literal = app.parse.bpm orelse return app.bpm_field.load("");
        const digits = app.editor.text()[literal.range.start..literal.range.end];
        app.bpm_field.load(digits[0..@min(digits.len, bpm_digits_max)]);
    }

    /// The knob label of binding `index`: its name cut to `label_cap` bytes on a codepoint
    /// boundary, or `#n` for a nameless call.
    fn label_of(app: *const App, index: u8, out: *[label_cap]u8) []const u8 {
        assert(index < app.parse.binding_count);
        const name = app.parse.bindings[index].name;
        if (name.end == name.start) {
            return std.fmt.bufPrint(out, "#{d}", .{index + 1}) catch unreachable;
        }
        const bytes = app.editor.text()[name.start..name.end];
        if (bytes.len <= label_cap) return bytes;
        return bytes[0..ui.edit.prev_boundary(bytes, label_cap + 1)];
    }

    /// The literal bytes of binding `index`'s value.
    fn value_bytes(app: *const App, index: u8) []const u8 {
        const range = app.parse.bindings[index].value.range;
        assert(range.end - range.start <= literal_cap);
        return app.editor.text()[range.start..range.end];
    }

    /// Binding `index`'s value as a position in its range, clamped to `[0, 1]`.
    fn fraction(app: *const App, index: u8) f32 {
        const binding = &app.parse.bindings[index];
        assert(binding.step_hi > binding.step_lo);
        const units = std.math.clamp(binding.value.fixed.units, binding.step_lo, binding.step_hi);
        const span: f32 = @floatFromInt(binding.step_hi - binding.step_lo);
        const result = @as(f32, @floatFromInt(units - binding.step_lo)) / span;
        assert(result >= 0);
        assert(result <= 1);
        return result;
    }

    /// The step at `position` of binding `index`'s range.
    fn units_at(app: *const App, index: u8, position: f32) i64 {
        assert(position >= 0);
        assert(position <= 1);
        const binding = &app.parse.bindings[index];
        const span: f32 = @floatFromInt(binding.step_hi - binding.step_lo);
        const units = binding.step_lo + @as(i64, @intFromFloat(@round(position * span)));
        assert(units >= binding.step_lo);
        assert(units <= binding.step_hi);
        return units;
    }

    // ----------------------------------------------------------------- events

    fn route_transport(app: *App, cx: *Context, event_value: input.Event) void {
        for (transport_ids, 0..) |id, index| {
            switch (cx.hit(id, event_value)) {
                .down => app.press_transport(cx, @intCast(index)),
                else => {},
            }
        }
    }

    /// Back, play or pause, record (section 5).
    fn press_transport(app: *App, cx: *Context, index: u32) void {
        assert(index < transport_count);
        switch (index) {
            0 => app.transport.head = 0,
            1 => {
                app.transport.playing = !app.transport.playing;
                cx.set_timer(app.transport.playing);
            },
            else => app.transport.recording = !app.transport.recording,
        }
        cx.redraw();
        assert(cx.timer_on == app.transport.playing);
    }

    fn route_bpm(app: *App, cx: *Context, event_value: input.Event) void {
        switch (app.bpm_field.handle(cx, event_value)) {
            .none, .changed => {},
            .committed => app.commit_bpm(cx),
            .cancelled => app.load_bpm(),
        }
    }

    /// Rewrites `bpm := <int>` with the field's integer in `bpm_min ..= bpm_max`, as one undo
    /// entry; anything else reverts the field.
    fn commit_bpm(app: *App, cx: *Context) void {
        assert(app.grip.kind == .none);
        const literal = app.parse.bpm orelse return app.load_bpm();
        const value = std.fmt.parseInt(u32, app.bpm_field.bytes(), 10) catch {
            return app.load_bpm();
        };
        if (value < bpm_min or value > bpm_max) return app.load_bpm();
        var digits: [bpm_digits_max]u8 = undefined;
        const printed = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
        const current = app.editor.text()[literal.range.start..literal.range.end];
        if (std.mem.eql(u8, printed, current)) return app.load_bpm();
        if (!app.editor.replace(literal.range, printed)) {
            app.set_status("bpm");
            return app.load_bpm();
        }
        cx.redraw();
        app.sync();
        assert(app.parsed_revision == app.editor.revision());
    }

    fn route_knobs(app: *App, cx: *Context, event_value: input.Event) void {
        var index = app.column.first;
        while (index < app.column.end and index < app.parse.binding_count) : (index += 1) {
            app.knob_event(cx, column_knob_id(index), @intCast(index), event_value);
        }
        for (0..app.parse.shape_count) |row| {
            for (app.parse.shapes[row].bound, 0..) |bound, arg| {
                const target = bound orelse continue;
                const id = shape_knob_id(@intCast(row), @intCast(arg));
                app.knob_event(cx, id, target, event_value);
            }
        }
    }

    fn knob_event(app: *App, cx: *Context, id: ui.Id, index: u8, event_value: input.Event) void {
        const held = app.grip.kind != .none and app.grip.id == id;
        switch (knob.interpret(cx, id, event_value, &app.grip.drag_y)) {
            .none, .hover => {},
            .grabbed => app.grab(cx, id, index, .drag),
            .turned => |delta| if (held and app.grip.kind == .drag) app.turn(cx, delta),
            .released => if (held and app.grip.kind == .drag) app.release(cx),
            .wheel => |delta| {
                // The wheel reaches its target even while a left drag holds the capture
                // (`ui/cx.zig`, section 5); only the held knob may turn then.
                if (!held and app.grip.kind == .drag) return;
                if (!held) app.grab(cx, id, index, .wheel);
                app.turn(cx, delta);
            },
            .reset => app.reset(cx, index),
        }
    }

    /// Ends a wheel gesture unless `event_value` continues it (section 3).
    fn close_wheel(app: *App, cx: *Context, event_value: input.Event) void {
        if (app.grip.kind != .wheel) return;
        switch (event_value) {
            .pointer_move, .frame => return,
            .wheel => if (cx.hit(app.grip.id, event_value) == .wheel) return,
            else => {},
        }
        app.release(cx);
    }

    fn grab(app: *App, cx: *Context, id: ui.Id, index: u8, kind: Grip.Kind) void {
        assert(app.grip.kind == .none);
        assert(kind != .none);
        assert(index < app.parse.binding_count);
        app.editor.gesture_begin();
        const original = app.value_bytes(index);
        var grip = Grip.idle;
        grip.kind = kind;
        grip.id = id;
        grip.binding = index;
        grip.position = app.fraction(index);
        grip.drag_y = app.grip.drag_y;
        @memcpy(grip.original[0..original.len], original);
        grip.original_len = @intCast(original.len);
        app.grip = grip;
        cx.redraw();
    }

    fn turn(app: *App, cx: *Context, delta: f32) void {
        assert(app.grip.kind != .none);
        assert(delta == delta);
        app.grip.position = std.math.clamp(app.grip.position + delta, 0, 1);
        const index = app.grip.binding;
        if (app.write(cx, index, app.units_at(index, app.grip.position))) app.grip.wrote = true;
    }

    /// Ends the gesture as one undo entry; a gesture that wrote gets one full pass.
    fn release(app: *App, cx: *Context) void {
        assert(app.grip.kind != .none);
        app.editor.gesture_end();
        const wrote = app.grip.wrote;
        const drag_y = app.grip.drag_y;
        app.grip = Grip.idle;
        app.grip.drag_y = drag_y;
        if (wrote) app.reparse();
        cx.redraw();
    }

    /// Sets binding `index` to its load-time value (or lo), as one undo entry.
    fn reset(app: *App, cx: *Context, index: u8) void {
        assert(app.grip.kind == .none);
        const binding = app.parse.bindings[index];
        var buffer: [label_cap]u8 = undefined;
        const lane_key = lanes.key_of(app.label_of(index, &buffer));
        var target = binding.step_lo;
        for (app.defaults[0..app.default_count]) |default| {
            if (default.key != lane_key) continue;
            const units = fixed_point.rescale(default.fixed, binding.value.fixed.decimals, .nearest);
            target = std.math.clamp(units, binding.step_lo, binding.step_hi);
            break;
        }
        if (app.write(cx, index, target)) app.reparse();
    }

    /// Rewrites binding `index`'s value literal with `units` at its decimals and moves every
    /// later range (section 3). Returns false when the literal is unchanged or the edit was
    /// refused.
    fn write(app: *App, cx: *Context, index: u8, units: i64) bool {
        assert(app.parsed_revision == app.editor.revision());
        const binding = &app.parse.bindings[index];
        assert(units >= binding.step_lo);
        assert(units <= binding.step_hi);
        if (units == binding.value.fixed.units) return false;
        const fixed = binding.value.fixed.with_units(units);
        const old = binding.value.range;
        const delta = fixed_point.write(&app.editor, old, fixed) orelse {
            app.set_status("knob");
            return false;
        };
        app.parse.shift(old.end, delta);
        binding.value.fixed = fixed;
        assert(binding.value.range.end - binding.value.range.start == fixed_point.moved(old.end - old.start, delta));
        app.parsed_revision = app.editor.revision();
        app.decorate();
        app.status_len = 0;
        cx.redraw();
        return true;
    }

    // ------------------------------------------------------------------- draw

    fn draw_editor(app: *App, cx: *Context, width: f32) void {
        assert(width >= 0);
        app.editor.draw_begin(cx, ui.sized(.{ .fixed = width }, .fill));
        while (app.editor.next_row(cx)) |slot| app.draw_shape_row(cx, slot);
        app.editor.draw_end(cx);
    }

    /// One inline row: four knobs mirroring the shape's bindings and the transfer curve.
    fn draw_shape_row(app: *App, cx: *Context, slot: editor.RowSlot) void {
        assert(slot.index < app.parse.shape_count);
        const row = cx.walk(slot.walk);
        const clip = cx.visible(row) orelse return;
        const face: Rect = .{
            .x = row.x,
            .y = row.y + 4,
            .width = row.width,
            .height = row.height - 8,
        };
        kit.face(cx, face, clip, .{ .fill = inline_fill });
        const shape = app.parse.shapes[slot.index];
        var values: [bindings.shape_args]f32 = @splat(0);
        for (0..bindings.shape_args) |arg| {
            const ring: Rect = .{
                .x = row.x + inline_pad_px + @as(f32, @floatFromInt(arg)) * inline_cell_px,
                .y = row.y + (row.height - inline_ring_px) * 0.5,
                .width = inline_ring_px,
                .height = inline_ring_px,
            };
            app.draw_shape_knob(cx, slot.index, @intCast(arg), ring);
            if (shape.bound[arg]) |target| {
                values[arg] = fixed_point.to_f32(app.parse.bindings[target].value.fixed);
            }
        }
        const plot_x = row.x + 2 * inline_pad_px + bindings.shape_args * inline_cell_px;
        const plot_width = @min(plot_px_max, row.x + row.width - plot_x - inline_pad_px);
        if (plot_width < plot_min_px) return;
        var samples: [shaper.sample_count]f32 = undefined;
        shaper.transfer(&samples, values[0], values[1], values[2], values[3]);
        const plot: Rect = .{
            .x = plot_x,
            .y = row.y + 14,
            .width = plot_width,
            .height = row.height - 28,
        };
        const stroke: quads.path.Stroke = .{ .color = plot_color, .width = 1.5, .hover = 0 };
        _ = quads.path.plot(cx.drawing(), &samples, plot, .{ -1, 1 }, stroke, clip);
    }

    fn draw_shape_knob(app: *App, cx: *Context, row: u32, arg: u32, ring: Rect) void {
        const shape = app.parse.shapes[row];
        const name = app.editor.text()[shape.args[arg].start..shape.args[arg].end];
        const label = name[0..ui.edit.prev_boundary(name, @intCast(@min(name.len, label_cap)))];
        const label_bytes = if (name.len <= label_cap) name else label;
        const id = shape_knob_id(row, arg);
        const target = shape.bound[arg] orelse {
            knob.draw(cx, id, .{
                .ring = ring,
                .fraction = 0,
                .accent = disabled_color,
                .value = "--",
                .label = label_bytes,
                .enabled = false,
                .lit = 0,
            });
            return;
        };
        knob.draw(cx, id, .{
            .ring = ring,
            .fraction = app.fraction(target),
            .accent = accents[target % accent_count],
            .value = app.value_bytes(target),
            .label = label_bytes,
            .enabled = true,
            .lit = app.lit(cx, id),
        });
    }

    fn draw_panel(app: *App, cx: *Context, body: Rect, panel_width: f32) void {
        assert(panel_width > 0);
        const walk: ui.Walk = .{ .width = .{ .fixed = panel_width }, .height = .fill, .margin = .sides(body.width - panel_width, 0, 0, 0) };
        const panel = cx.begin(walk, .{ .flow = .down });
        if (cx.visible(panel)) |clip| {
            kit.face(cx, panel, clip, .{ .fill = cx.theme().colors.panel });
            const band = cx.walk(ui.sized(.fill, .{ .fixed = band_px }));
            app.draw_transport(cx, band, clip);
            app.draw_column(cx);
        }
        _ = cx.end();
    }

    fn draw_transport(app: *App, cx: *Context, band: Rect, clip: Clip) void {
        const play: icon.Shape = if (app.transport.playing) .pause else .play;
        const shapes = [transport_count]icon.Shape{ .back, play, .record };
        // Before the icons, so the glow's batch draws under them (section 5).
        if (app.transport.recording and cx.visible(transport_hit(band, 2)) != null) {
            const face = transport_face(transport_hit(band, 2));
            append_glow(cx, glow.around(face, record_glow_color, record_glow_hz, clip));
        }
        for (shapes, transport_ids, 0..) |shape, id, index| {
            const hit = transport_hit(band, @intCast(index));
            if (cx.visible(hit) == null) continue;
            cx.area(id, hit, 4, transport_flags);
            const face = transport_face(hit);
            var color = transport_color;
            if (shape == .record) {
                color = if (app.transport.recording) record_color else record_idle_color;
            }
            append_icon(cx, icon.at(face, shape, color, clip));
        }
    }

    /// The column: a view of `row_px` rows, only the visible ones drawn (section 2).
    fn draw_column(app: *App, cx: *Context) void {
        const viewport = cx.begin_view(
            column_id,
            ui.sized(.fill, .fill),
            ui.flow_of(.down),
            &app.column_view,
        );
        const list: ui.List = .{ .row_height = row_px, .count = app.parse.binding_count };
        const range = list.visible(app.column_view.scroll_y, viewport.height);
        const lane_width = viewport.width - ui.view.gutter_px - knob_column_px;
        app.column = .{
            .shown = viewport.width > 0 and viewport.height > 0,
            .viewport = viewport,
            .ring_x = viewport.x + ring_left_px,
            .first = range.first,
            .end = range.end,
            .lane_x = viewport.x + knob_column_px,
            .lane_width = if (lane_width >= lane_min_px) lane_width else 0,
        };
        cx.skip(@as(f32, @floatFromInt(range.first)) * row_px);
        var index = range.first;
        while (index < range.end) : (index += 1) app.draw_row(cx, @intCast(index));
        cx.skip(@as(f32, @floatFromInt(app.parse.binding_count - range.end)) * row_px);
        cx.end_view();
        if (app.column.lane_width > 0 and range.end > range.first) app.draw_playhead(cx);
    }

    fn draw_row(app: *App, cx: *Context, index: u8) void {
        const row = cx.walk(ui.sized(.fill, .{ .fixed = row_px }));
        const clip = cx.visible(row) orelse return;
        const id = column_knob_id(index);
        const ring: Rect = .{
            .x = row.x + ring_left_px,
            .y = row.y + (row_px - ring_px) * 0.5,
            .width = ring_px,
            .height = ring_px,
        };
        knob.draw(cx, id, .{
            .ring = ring,
            .fraction = app.fraction(index),
            .accent = accents[index % accent_count],
            .value = app.value_bytes(index),
            .label = "",
            .enabled = true,
            .lit = app.lit(cx, id),
        });
        var buffer: [label_cap]u8 = undefined;
        const label = app.label_of(index, &buffer);
        var label_box: Rect = .{
            .x = row.x + label_left_px,
            .y = row.y,
            .width = knob_column_px - label_left_px - 4,
            .height = row_px,
        };
        const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
        if (app.grip.kind != .none and app.grip.binding == index) {
            label_box.height = row_px * 0.5;
            label_box.y += 2;
            var struck = label_box;
            struck.y = row.y + row_px * 0.5;
            struck.height = row_px * 0.5 - 4;
            const original = app.grip.original[0..app.grip.original_len];
            text.place(cx.drawing(), struck_style, original, struck, clip, left);
            const bar: Rect = .{
                .x = struck.x,
                .y = struck.y + struck.height * 0.5,
                .width = text.measure(struck_style, original),
                .height = 1,
            };
            kit.face(cx, bar, clip, .{ .fill = struck_style.color });
        }
        text.place(cx.drawing(), label_style, label, label_box, clip, left);
        if (app.column.lane_width > 0) {
            const lane: Rect = .{
                .x = row.x + knob_column_px,
                .y = row.y + lane_inset_px,
                .width = app.column.lane_width,
                .height = row_px - 2 * lane_inset_px,
            };
            kit.face(cx, lane, clip, .{ .fill = lane_fill });
            app.draw_lane(cx, index, lane, clip);
        }
    }

    /// The lane's ring plotted against the binding's range, anchored at the lane rect so one
    /// changed sample is one changed point (section 5).
    fn draw_lane(app: *App, cx: *Context, index: u8, lane: Rect, clip: Clip) void {
        const binding = &app.parse.bindings[index];
        const low = fixed_point.to_f32(binding.lo.fixed);
        const high = fixed_point.to_f32(binding.hi.fixed);
        const range: [2]f32 = .{ low, high };
        var points: [lanes.sample_count]Point = undefined;
        quads.path.plot_points(&points, app.lanes.samples(index), lane, range);
        var color = accents[index % accent_count];
        color[3] = 0.9;
        const stroke: quads.path.Stroke = .{ .color = color, .width = lane_stroke_px, .hover = 0 };
        _ = quads.path.polyline_at(cx.drawing(), &points, .{ lane.x, lane.y }, stroke, clip);
    }

    /// One vertical bar over every lane at the head, on the curve layer.
    fn draw_playhead(app: *App, cx: *Context) void {
        const column = app.column;
        const clip = ui.cx.intersect(cx.clip(), column.viewport) orelse return;
        const last: f32 = @floatFromInt(lanes.sample_count - 1);
        const head: f32 = @floatFromInt(app.transport.head);
        // From the view's top to the last row's bottom, at most the viewport.
        const rows: f32 = @floatFromInt(app.parse.binding_count);
        const bottom = column.viewport.y - app.column_view.scroll_y + rows * row_px;
        const bar: Rect = .{
            .x = column.lane_x + column.lane_width * head / last - playhead_px * 0.5,
            .y = column.viewport.y,
            .width = playhead_px,
            .height = @min(column.viewport.height, bottom - column.viewport.y),
        };
        const previous = cx.drawing().layer(curve_layer);
        kit.face(cx, bar, clip, .{ .fill = playhead_color });
        _ = cx.drawing().layer(previous);
    }

    /// One cubic per binding with a visible end (section 4).
    fn draw_curves(app: *App, cx: *Context, body: Rect) void {
        const clip: Clip = .{
            .x0 = body.x,
            .y0 = body.y,
            .x1 = app.column.ring_x,
            .y1 = body.y + body.height,
        };
        if (!(clip.x1 > clip.x0) or !(clip.y1 > clip.y0)) return;
        const caret_line = app.editor.caret_position()[0];
        const hovered = app.hovered_binding(cx);
        const previous = cx.drawing().layer(curve_layer);
        for (0..app.parse.binding_count) |index| {
            const target: u8 = @intCast(index);
            const ends = app.curve_ends(target) orelse continue;
            const binding = &app.parse.bindings[index];
            var near = app.editor.buffer.line_of(binding.value.range.start) == caret_line;
            if (hovered == target) near = true;
            if (app.grip.kind != .none and app.grip.binding == target) near = true;
            var color = accents[index % accent_count];
            color[3] = if (near) curve_near_alpha else curve_far_alpha;
            const dx = ends[1][0] - ends[0][0];
            const control = [4]Point{
                ends[0],
                .{ ends[0][0] + dx * 0.5, ends[0][1] },
                .{ ends[1][0] - dx * 0.5, ends[1][1] },
                ends[1],
            };
            const stroke: quads.path.Stroke = .{ .color = color, .width = curve_px, .hover = 0 };
            if (quads.path.cubic(cx.drawing(), control, stroke, clip) != null) app.curve_count += 1;
        }
        _ = cx.drawing().layer(previous);
    }

    /// The ends of binding `index`'s curve from the last draw's geometry, each clamped to its
    /// viewport, or null when both ends are out of view or the panel is hidden (section 4).
    fn curve_ends(app: *const App, index: u8) ?[2]Point {
        if (!app.column.shown) return null;
        const port = app.editor.viewport();
        const view = app.column.viewport;
        const source = app.editor.rect_of(app.parse.bindings[index].value.range.end);
        const sx = source.x;
        const sy = source.y + source.height * 0.5;
        const scrolled = view.y - app.column_view.scroll_y;
        const ky = scrolled + (@as(f32, @floatFromInt(index)) + 0.5) * row_px;
        const source_seen = inside(sx, port.x, port.x + port.width) and
            inside(sy, port.y, port.y + port.height);
        const knob_seen = inside(ky, view.y, view.y + view.height);
        if (!source_seen and !knob_seen) return null;
        const start: Point = .{
            std.math.clamp(sx, port.x, port.x + port.width),
            std.math.clamp(sy, port.y, port.y + port.height),
        };
        const end: Point = .{ app.column.ring_x, std.math.clamp(ky, view.y, view.y + view.height) };
        if (!(end[0] > start[0])) return null;
        return .{ start, end };
    }

    /// The binding whose column or inline knob is hovered, or null.
    fn hovered_binding(app: *const App, cx: *const Context) ?u8 {
        const hovered = cx.hovered();
        if (hovered == .none) return null;
        for (0..app.parse.binding_count) |index| {
            if (column_knob_id(@intCast(index)) == hovered) return @intCast(index);
        }
        for (app.parse.shapes[0..app.parse.shape_count], 0..) |shape, row| {
            for (shape.bound, 0..) |bound, arg| {
                if (shape_knob_id(@intCast(row), @intCast(arg)) == hovered) return bound;
            }
        }
        return null;
    }

    /// 1 for a hovered or held knob, else 0.
    fn lit(app: *const App, cx: *const Context, id: ui.Id) f32 {
        if (app.grip.kind != .none and app.grip.id == id) return 1;
        if (cx.hovered() == id) return 1;
        return 0;
    }

    /// The header (section 2), in its own overlay container so it draws last.
    fn draw_header(app: *App, cx: *Context) void {
        const bar = cx.begin(ui.sized(.fill, .{ .fixed = header_px }), ui.flow_of(.overlay));
        if (bar.width > 2 * header_inset_px) {
            if (cx.visible(bar)) |clip| app.draw_header_parts(cx, bar, clip);
        }
        _ = cx.end();
    }

    fn draw_header_parts(app: *App, cx: *Context, bar: Rect, clip: Clip) void {
        kit.face(cx, bar, clip, .{ .fill = cx.theme().colors.panel });
        const inner = ui.cx.inset(bar, .xy(header_inset_px, 0));
        const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
        var name: [name_cap]u8 = undefined;
        const base = switch (app.shown) {
            .patch => "patch.lpg",
            .stress => "stress, 2,000 lines",
        };
        const modified = app.editor.history_mark() != app.load_mark;
        const marker = if (modified) " *" else "";
        const title = std.fmt.bufPrint(&name, "{s}{s}", .{ base, marker }) catch unreachable;
        text.place(cx.drawing(), name_style, title, column_at(inner, 0, name_width_px), clip, left);
        const status_rect: Rect = .{
            .x = inner.x + status_icon_left_px,
            .y = bar.y + (header_px - status_icon_px) * 0.5,
            .width = status_icon_px,
            .height = status_icon_px,
        };
        const ok = app.parse.ok();
        const status_shape: icon.Shape = if (ok) .check else .cross;
        const status_color = if (ok) check_color else cross_color;
        append_icon(cx, icon.at(status_rect, status_shape, status_color, clip));
        if (app.parse.call_count > binding_cap) {
            var count: [count_cap]u8 = undefined;
            const shown = write_count(&count, app.parse.binding_count, app.parse.call_count);
            const box = column_at(inner, count_left_px, count_width_px);
            text.place(cx.drawing(), dim_style, shown, box, clip, left);
        }
        const key_box = column_at(inner, key_left_px, 60);
        text.place(cx.drawing(), dim_style, key_text, key_box, clip, left);
        app.draw_bpm(cx, inner, clip);
        const unit_box = column_at(inner, bpm_unit_left_px, 32);
        text.place(cx.drawing(), dim_style, unit_text, unit_box, clip, left);
        const snap_box = column_at(inner, snap_left_px, 44);
        text.place(cx.drawing(), dim_style, snap_text, snap_box, clip, left);
        const position = app.editor.caret_position();
        var digits: [position_cap + 2]u8 = undefined;
        const printed = std.fmt.bufPrint(&digits, "{d}:{d}", .{ position[0] + 1, position[1] + 1 });
        const readout = printed catch unreachable;
        assert(readout.len <= position_cap);
        const position_box = column_at(inner, position_left_px, position_width_px);
        text.place(cx.drawing(), position_style, readout, position_box, clip, left);
        const status_left = position_left_px + position_width_px;
        const rest = column_at(inner, status_left, inner.width - status_left);
        const right: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };
        text.place(cx.drawing(), status_style, app.status[0..app.status_len], rest, clip, right);
    }

    /// The bpm field over the `bpm :=` literal, or "--" when the text has none.
    fn draw_bpm(app: *App, cx: *Context, inner: Rect, clip: Clip) void {
        if (app.parse.bpm == null) {
            const box = column_at(inner, bpm_left_px, bpm_width_px);
            text.place(cx.drawing(), dim_style, "--", box, clip, widgets.centered);
            return;
        }
        var walk = ui.sized(.{ .fixed = bpm_width_px }, .{ .fixed = bpm_height_px });
        walk.margin.left = header_inset_px + bpm_left_px;
        walk.margin.top = (header_px - bpm_height_px) * 0.5;
        app.bpm_field.draw(cx, walk);
    }
};

fn column_knob_id(index: u32) ui.Id {
    assert(index < binding_cap);
    return ui.id("knob", index);
}

fn shape_knob_id(row: u32, arg: u32) ui.Id {
    assert(row < bindings.shape_cap);
    assert(arg < bindings.shape_args);
    return ui.id("shape", row * bindings.shape_args + arg);
}

/// The panel's width for a body `width` wide: none below `panel_window_min_px`.
fn panel_width_of(width: f32) f32 {
    assert(width >= 0);
    if (width < panel_window_min_px) return 0;
    const result = @min(panel_px_max, @floor(width * panel_share));
    assert(result > 0);
    return result;
}

fn inside(value: f32, low: f32, high: f32) bool {
    return value >= low and value <= high;
}

/// The part of `inner` from `left` to `left + width`, clamped to it.
fn column_at(inner: Rect, left: f32, width: f32) Rect {
    const x = inner.x + left;
    return .{
        .x = x,
        .y = inner.y,
        .width = std.math.clamp(inner.x + inner.width - x, 0, @max(0, width)),
        .height = inner.height,
    };
}

/// "64/2,100": the bound and found counts with thousands separators.
fn write_count(out: *[count_cap]u8, bound: u32, found: u32) []const u8 {
    assert(bound <= found);
    assert(found < 1_000_000);
    var length: usize = 0;
    length += write_thousands(out[length..], bound);
    out[length] = '/';
    length += 1;
    length += write_thousands(out[length..], found);
    assert(length <= count_cap);
    return out[0..length];
}

fn write_thousands(out: []u8, number: u32) usize {
    assert(number < 1_000_000);
    const printed = if (number >= 1000)
        std.fmt.bufPrint(out, "{d},{d:0>3}", .{ number / 1000, number % 1000 })
    else
        std.fmt.bufPrint(out, "{d}", .{number});
    return (printed catch unreachable).len;
}

/// The hit rect of transport button `index` in `band`.
fn transport_hit(band: Rect, index: u32) Rect {
    assert(index < transport_count);
    const step = transport_hit_px + transport_gap_px;
    return .{
        .x = band.x + transport_left_px + @as(f32, @floatFromInt(index)) * step,
        .y = band.y + (band_px - transport_hit_px) * 0.5,
        .width = transport_hit_px,
        .height = transport_hit_px,
    };
}

/// The icon face centered in a transport hit rect.
fn transport_face(hit: Rect) Rect {
    const inset = (transport_hit_px - transport_icon_px) * 0.5;
    return .{
        .x = hit.x + inset,
        .y = hit.y + inset,
        .width = transport_icon_px,
        .height = transport_icon_px,
    };
}

fn append_glow(cx: *Context, instance: glow.Glow) void {
    cx.append(glow.Glow, null, instance) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

fn append_icon(cx: *Context, instance: icon.Icon) void {
    cx.append(icon.Icon, null, instance) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// Writes the stress text into `out` and returns its length (section 3).
fn generate_stress(out: []u8) u32 {
    var length: u32 = 0;
    var line: u32 = 0;
    while (line < stress_lines) : (line += 1) {
        const long = line >= stress_long_first and line < stress_long_first + stress_long_count;
        if (long) {
            length += long_line(out[length..], line);
        } else {
            const format = "v{d:0>4} := k(0~0.5~1) * 0.25\n";
            const short = std.fmt.bufPrint(out[length..], format, .{line}) catch unreachable;
            length += @intCast(short.len);
        }
    }
    // The text ends without a line break, so it is exactly `stress_lines` lines.
    length -= 1;
    assert(length <= editor.buffer.buffer_cap);
    return length;
}

/// One line of exactly `stress_long_columns` columns plus its LF.
fn long_line(out: []u8, line: u32) u32 {
    const head = std.fmt.bufPrint(out, "w{d:0>4} := ", .{line}) catch unreachable;
    var length: u32 = @intCast(head.len);
    const pattern = "osc(0.25) * k(-1~0.5~1, \"x\") + ";
    while (length < stress_long_columns) : (length += 1) {
        out[length] = pattern[(length - head.len) % pattern.len];
    }
    out[length] = '\n';
    assert(length == stress_long_columns);
    return length + 1;
}

// ------------------------------------------------------------------------------ tests

/// The test app and context: static, like the hosts', so 300 KiB stay off the stack.
const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

/// Draws a `width` by `height` frame the way a host does after a resize, then finalizes it.
fn frame_at(app: *App, width: u32, height: u32) *Context {
    const cx = &fixture.context;
    cx.redraw();
    assert(ui.draw_frame(App, app, cx, width, height, 120));
    cx.draw.finalize();
    assert(cx.draw.overflow_count == 0);
    assert(cx.area_overflow == 0);
    return cx;
}

/// Dispatches `event` the way a host does. Returns true when it owed a draw.
fn send(app: *App, event_value: input.Event) bool {
    const cx = &fixture.context;
    cx.dirty = false;
    ui.dispatch(App, app, cx, event_value);
    return cx.dirty;
}

fn key(app: *App, name: input.Key, mods: input.Mods, typed: []const u8) bool {
    return send(app, .{ .key_down = input.key_press(name, mods, false, typed) });
}

fn click(app: *App, x: f32, y: f32) void {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = .left, .mods = .none };
    const owed = send(app, .{ .pointer_down = sample });
    _ = send(app, .{ .pointer_up = sample });
    // A host draws between the two; keep the press's draw owed for the next frame.
    if (owed) fixture.context.dirty = true;
}

fn press_at(app: *App, x: f32, y: f32, button: input.MouseButton) void {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = button, .mods = .none };
    _ = send(app, .{ .pointer_down = sample });
}

fn release_at(app: *App, x: f32, y: f32) void {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = .left, .mods = .none };
    _ = send(app, .{ .pointer_up = sample });
}

/// The center of column knob `index` at the last draw.
fn ring_center(index: u32) [2]f32 {
    const area = fixture.context.find(column_knob_id(index)).?;
    return .{ area.rect[0] + area.rect[2] * 0.5, area.rect[1] + area.rect[3] * 0.5 };
}

fn value_text(app: *const App, index: u8) []const u8 {
    return app.value_bytes(index);
}

// Locks the screen at 1280 by 720: the header is 40 px, the panel 380 px at the right (the
// band 40 px, the column view below it), the editor's viewport the rest, and the first line's
// first byte at the editor's text origin (gutter 45, half a column, padding 4).
test "live layout at 1280 by 720" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const viewport: Rect = .{ .x = 0, .y = 40, .width = 900, .height = 680 };
    try std.testing.expectEqual(viewport, app.editor.viewport());
    const origin: Rect = .{ .x = 49.5, .y = 44, .width = 9, .height = 21 };
    try std.testing.expectEqual(origin, app.editor.rect_of(0));
    try std.testing.expectEqual(@as(u32, 80), app.editor.buffer.line_count);
    const column: Rect = .{ .x = 900, .y = 80, .width = 380, .height = 640 };
    try std.testing.expectEqual(column, app.column.viewport);
    try std.testing.expectEqual(@as(f32, 904), app.column.ring_x);
    try std.testing.expectEqual(@as(f32, 224), app.column.lane_width);
    try std.testing.expectEqual(@as(u32, 14), app.column.end);
    const ring = cx.find(column_knob_id(0)).?.rect;
    try std.testing.expectEqual([4]f32{ 904, 82, 44, 44 }, ring);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try std.testing.expect(cx.find(editor_id) != null);
    try std.testing.expect(!cx.timer_on);
}

// Locks the panel's widths: 0.3 of the window up to 380 px, the lanes hidden when the panel
// leaves them less than 120 px (800 px: 240 - 16 - 140 = 84), and no panel below 640 px.
test "the panel narrows and hides with the window" {
    try std.testing.expectEqual(@as(f32, 380), panel_width_of(1280));
    try std.testing.expectEqual(@as(f32, 240), panel_width_of(800));
    try std.testing.expectEqual(@as(f32, 0), panel_width_of(639));
    const app = new_app();
    _ = frame_at(app, 800, 600);
    try std.testing.expectEqual(@as(f32, 0), app.column.lane_width);
    try std.testing.expectEqual(@as(f32, 560), app.editor.viewport().width);
    _ = frame_at(app, 600, 600);
    try std.testing.expect(!app.column.shown);
    try std.testing.expectEqual(@as(u32, 0), app.curve_count);
    try std.testing.expectEqual(@as(f32, 600), app.editor.viewport().width);
}

// Locks the decorations of the patch: a box on each of the 14 bound values, no error, and one
// 96 px inline row after line 27 (the shape call).
test "each bound value gets a box and the shape an inline row" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const shown = &app.editor;
    try std.testing.expectEqual(@as(u32, 14), shown.decoration_count);
    for (shown.decorations[0..14], app.parse.bindings[0..14]) |decoration, binding| {
        try std.testing.expectEqual(editor.Decoration.Kind.box, decoration.kind);
        try std.testing.expectEqual(binding.value.range.start, decoration.start);
    }
    const first = shown.decorations[0];
    try std.testing.expectEqualStrings("0.12", shown.text()[first.start..first.end]);
    try std.testing.expectEqual(@as(u32, 1), shown.row_count);
    try std.testing.expectEqual(editor.InlineRow{ .after_line = 26, .height = 96 }, shown.rows[0]);
    try std.testing.expect(app.parse.ok());
}

// Locks the texts: F2 loads the 2,000-line stress text with 50 lines of 120 columns from
// line 975 (64 of its 2,100 calls bind, the 50 cut calls are errors), F1 reloads the patch,
// and each load clears the history.
test "F2 loads the stress text and F1 the patch" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(key(app, .f2, .none, ""));
    try std.testing.expectEqual(stress_lines, app.editor.buffer.line_count);
    try std.testing.expectEqual(stress_long_columns, app.editor.buffer.longest);
    const long = app.editor.buffer.line_range(stress_long_first);
    try std.testing.expectEqual(stress_long_columns, long.end - long.start);
    try std.testing.expect(app.editor.buffer.len < editor.buffer.buffer_cap);
    try std.testing.expectEqual(@as(u32, 58_699), app.stress_len);
    try std.testing.expectEqual(binding_cap, app.parse.binding_count);
    try std.testing.expectEqual(@as(u32, 2_100), app.parse.call_count);
    try std.testing.expectEqual(@as(u32, 50), app.parse.error_total);
    var count: [count_cap]u8 = undefined;
    try std.testing.expectEqualStrings("64/2,100", write_count(&count, 64, 2_100));
    var buffer: [label_cap]u8 = undefined;
    try std.testing.expectEqualStrings("#1", app.label_of(0, &buffer));
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(key(app, .f1, .none, ""));
    try std.testing.expectEqualStrings(patch_source, app.editor.text());
    try std.testing.expectEqual(@as(u32, 0), app.editor.buffer.entry_count);
}

// Locks the refusal message: a paste that would pass 64 KiB leaves the text alone and the
// header says "paste refused: buffer full" until the next accepted edit clears it.
test "a refused paste shows in the header" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    click(app, 200, 60);
    const big: [editor.buffer.buffer_cap]u8 = @splat('z');
    try std.testing.expect(send(app, .{ .paste = &big }));
    try std.testing.expectEqualStrings("paste refused: buffer full", app.status[0..app.status_len]);
    try std.testing.expectEqualStrings(patch_source, app.editor.text());
    _ = frame_at(app, 1280, 720);
    try std.testing.expect(key(app, .other, .none, "x"));
    try std.testing.expectEqual(@as(u32, 0), app.status_len);
}

// Locks the tall window: at 1280 by 2160 on the stress text scrolled into its long lines,
// the editor draws down to the window's bottom (the last glyph row starts within one line of
// it), the 64 boxes and 50 errors are decorations, and nothing overflows a pool.
test "a tall window fills to the bottom" {
    const app = new_app();
    _ = key(app, .f2, .none, "");
    app.editor.view.scroll_y = 960 * 21;
    const cx = frame_at(app, 1280, 2160);
    var bottom: f32 = 0;
    for (cx.draw.items(quads.Glyph)) |glyph| bottom = @max(bottom, glyph.rect[1]);
    try std.testing.expect(bottom > 2160 - 2 * 21);
    try std.testing.expectEqual(@as(u32, 114), app.editor.decoration_count);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

const ctrl: input.Mods = .{ .shift = false, .ctrl = true, .alt = false, .meta = false };

// Locks a drag on the "again" knob (0~0.023~0.05, steps of 0.001): 12 px up is a tenth of
// the range, 0.46 + 0.1 = 0.56, so the literal becomes "0.028"; the drag events run no full
// pass, the release runs one, the header shows the modified marker, the knob row shows the
// original until release, and one undo restores "0.023" and moves the knob back.
test "a knob drag rewrites its literal as one undo entry" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const center = ring_center(2);
    try std.testing.expectEqualStrings("0.023", value_text(app, 2));
    const passes = app.parse_count;
    press_at(app, center[0], center[1], .left);
    try std.testing.expectEqual(Grip.Kind.drag, app.grip.kind);
    _ = send(app, .{ .pointer_move = .{ .x = center[0], .y = center[1] - 6 } });
    _ = send(app, .{ .pointer_move = .{ .x = center[0], .y = center[1] - 12 } });
    try std.testing.expectEqualStrings("0.028", value_text(app, 2));
    try std.testing.expectEqualStrings("0.023", app.grip.original[0..app.grip.original_len]);
    try std.testing.expectEqual(passes, app.parse_count);
    try std.testing.expectEqual(app.parsed_revision, app.editor.revision());
    _ = frame_at(app, 1280, 720);
    release_at(app, center[0], center[1] - 12);
    try std.testing.expectEqual(Grip.Kind.none, app.grip.kind);
    try std.testing.expectEqual(passes + 1, app.parse_count);
    try std.testing.expectEqual(@as(f32, 28.0 / 50.0), app.fraction(2));
    try std.testing.expect(app.editor.history_mark() != app.load_mark);
    try std.testing.expectEqual(@as(u32, 1), app.editor.buffer.undo_count);
    _ = frame_at(app, 1280, 720);
    click(app, 200, 600);
    _ = key(app, .z, ctrl, "");
    try std.testing.expectEqualStrings("0.023", value_text(app, 2));
    try std.testing.expectEqual(@as(f32, 23.0 / 50.0), app.fraction(2));
    try std.testing.expectEqualStrings(patch_source, app.editor.text());
}

// Locks the literal formats under wheel steps: 9.99 + 0.01 is "10.00" (the line grows by
// one byte and the later bindings move with it), -0.01 + 0.01 is "0.00", the bare ".25" + 0.05
// is ".30", and the integer knob 0~0~1 steps to "1"; a full pass afterwards reads the same
// values, so knob, text, and knob agree.
test "literals keep their decimals across carries, signs, and steps" {
    const app = new_app();
    app.load(
        \\a := k(0~9.99~20, "a")
        \\b := k(-1~-0.01~1, "b")
        \\c := k(0~.25~1, "c")
        \\d := k(0~0~1, "d")
    );
    _ = frame_at(app, 1280, 720);
    const b_start = app.parse.bindings[1].call.start;
    const steps = [_]struct { index: u8, dy: f32, expected: []const u8 }{
        .{ .index = 0, .dy = -knob.drag_span_px / 2000, .expected = "10.00" },
        .{ .index = 1, .dy = -knob.drag_span_px / 200, .expected = "0.00" },
        .{ .index = 2, .dy = -knob.drag_span_px * 0.05, .expected = ".30" },
        .{ .index = 3, .dy = -knob.drag_span_px * 0.5, .expected = "1" },
    };
    for (steps) |step| {
        const center = ring_center(step.index);
        _ = send(app, .{ .wheel = .{ .x = center[0], .y = center[1], .dx = 0, .dy = step.dy } });
        try std.testing.expectEqualStrings(step.expected, value_text(app, step.index));
    }
    try std.testing.expectEqual(b_start + 1, app.parse.bindings[1].call.start);
    _ = send(app, .{ .pointer_leave = {} });
    try std.testing.expectEqual(Grip.Kind.none, app.grip.kind);
    try std.testing.expectEqualStrings(
        "a := k(0~10.00~20, \"a\")\nb := k(-1~0.00~1, \"b\")\n" ++
            "c := k(0~.30~1, \"c\")\nd := k(0~1~1, \"d\")",
        app.editor.text(),
    );
    try std.testing.expectEqual(@as(f32, 0.5), app.fraction(0));
    try std.testing.expectEqual(@as(f32, 0.5), app.fraction(1));
    try std.testing.expectEqual(@as(f32, 1), app.fraction(3));
    try std.testing.expectEqual(@as(u32, 4), app.editor.buffer.undo_count);
}

// Locks the gesture rules: while a drag is held, a typed key, Ctrl+Z, and a paste are
// dropped (undo inside a gesture would assert); two wheel events on one knob are one undo
// entry, and a key closes that gesture and still reaches the editor.
test "keys are dropped during a drag and close a wheel gesture" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    click(app, 200, 600);
    const center = ring_center(0);
    press_at(app, center[0], center[1], .left);
    _ = send(app, .{ .pointer_move = .{ .x = center[0], .y = center[1] - 24 } });
    const dragged = app.editor.revision();
    _ = key(app, .other, .none, "x");
    _ = key(app, .z, ctrl, "");
    _ = send(app, .{ .paste = "pasted" });
    try std.testing.expectEqual(dragged, app.editor.revision());
    release_at(app, center[0], center[1] - 24);
    try std.testing.expectEqualStrings("0.22", value_text(app, 0));
    _ = frame_at(app, 1280, 720);
    const entries = app.editor.buffer.undo_count;
    for (0..2) |_| {
        _ = send(app, .{ .wheel = .{ .x = center[0], .y = center[1], .dx = 0, .dy = -6 } });
    }
    try std.testing.expectEqual(Grip.Kind.wheel, app.grip.kind);
    try std.testing.expectEqualStrings("0.27", value_text(app, 0));
    _ = key(app, .end, .none, "");
    try std.testing.expectEqual(Grip.Kind.none, app.grip.kind);
    try std.testing.expectEqual(entries + 1, app.editor.buffer.undo_count);
}

// Locks the wheel during a drag: while the gain knob is held (12 px up: 15 + 8 of 80 steps
// is "2.3"), a wheel over the snare knob and over the inline knob mirroring gain changes
// nothing, a wheel over the held knob still turns it (+5 steps, "2.8"), and the release
// leaves one undo entry.
test "a wheel elsewhere during a drag is ignored" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const center = ring_center(4);
    press_at(app, center[0], center[1], .left);
    _ = send(app, .{ .pointer_move = .{ .x = center[0], .y = center[1] - 12 } });
    try std.testing.expectEqualStrings("2.3", value_text(app, 4));
    const snare = ring_center(1);
    _ = send(app, .{ .wheel = .{ .x = snare[0], .y = snare[1], .dx = 0, .dy = -12 } });
    const mirror = cx.find(shape_knob_id(0, 0)).?.rect;
    const mirror_x = mirror[0] + mirror[2] * 0.5;
    const mirror_y = mirror[1] + mirror[3] * 0.5;
    _ = send(app, .{ .wheel = .{ .x = mirror_x, .y = mirror_y, .dx = 0, .dy = -12 } });
    try std.testing.expectEqual(Grip.Kind.drag, app.grip.kind);
    try std.testing.expectEqual(column_knob_id(4), app.grip.id);
    try std.testing.expectEqualStrings("0.8", value_text(app, 1));
    try std.testing.expectEqualStrings("2.3", value_text(app, 4));
    const held = ring_center(4);
    _ = send(app, .{ .wheel = .{ .x = held[0], .y = held[1], .dx = 0, .dy = -7.5 } });
    try std.testing.expectEqualStrings("2.8", value_text(app, 4));
    release_at(app, center[0], center[1] - 12);
    try std.testing.expectEqual(Grip.Kind.none, app.grip.kind);
    try std.testing.expectEqual(@as(u32, 1), app.editor.buffer.undo_count);
}

// Locks the reset: after a drag, a right press on the knob writes the load-time value back
// as one more undo entry, and a second right press changes nothing.
test "a right press resets a knob to its load-time value" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const center = ring_center(3);
    press_at(app, center[0], center[1], .left);
    _ = send(app, .{ .pointer_move = .{ .x = center[0], .y = center[1] - 30 } });
    release_at(app, center[0], center[1] - 30);
    try std.testing.expectEqualStrings("0.935", value_text(app, 3));
    _ = frame_at(app, 1280, 720);
    press_at(app, center[0], center[1], .right);
    try std.testing.expectEqualStrings("0.445", value_text(app, 3));
    try std.testing.expectEqual(@as(u32, 2), app.editor.buffer.undo_count);
    const revision = app.editor.revision();
    press_at(app, center[0], center[1], .right);
    try std.testing.expectEqual(revision, app.editor.revision());
}

// Locks the inline knobs: the shape row's second knob is "slope", the same binding as column
// knob 5, so a wheel on it rewrites the slope literal and moves both.
test "an inline knob edits the binding it mirrors" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const area = cx.find(shape_knob_id(0, 1)).?;
    const x = area.rect[0] + area.rect[2] * 0.5;
    const y = area.rect[1] + area.rect[3] * 0.5;
    _ = send(app, .{ .wheel = .{ .x = x, .y = y, .dx = 0, .dy = -6 } });
    try std.testing.expectEqualStrings("0.35", value_text(app, 5));
    try std.testing.expectEqual(@as(f32, 135.0 / 200.0), app.fraction(5));
    try std.testing.expectEqual(app.grip.id, shape_knob_id(0, 1));
}

// Locks the curves at 1280 by 720: one per binding with a visible end (13: the last knob's
// row and its value are both out of view), starting at the value's right edge and ending at
// the ring's left edge; scrolled to the bottom, the first binding's value is above the
// viewport, so its curve starts on the viewport's top edge.
test "one curve per binding with a visible end, clamped to the viewport" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 13), app.curve_count);
    const ends = app.curve_ends(0).?;
    const value_end = app.editor.rect_of(app.parse.bindings[0].value.range.end);
    try std.testing.expectEqual(value_end.x, ends[0][0]);
    try std.testing.expectEqual(@as(f32, 904), ends[1][0]);
    try std.testing.expectEqual(@as(f32, 80 + 24), ends[1][1]);
    try std.testing.expectEqual(@as(?[2]Point, null), app.curve_ends(13));
    app.editor.view.scroll_y = 10_000;
    _ = frame_at(app, 1280, 720);
    const clamped = app.curve_ends(0).?;
    try std.testing.expectEqual(@as(f32, 40), clamped[0][1]);
}

// Locks the transport: a paused screen has no timer; play starts it and each tick advances
// the head, wrapping after 256; record while playing writes values at the head; pause stops
// the timer again; back returns the head to 0.
test "the transport gates the timer and the ring wraps" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    try std.testing.expect(!cx.timer_on);
    const play = cx.find(transport_ids[1]).?.rect;
    click(app, play[0] + 4, play[1] + 4);
    try std.testing.expect(cx.timer_on);
    for (0..lanes.sample_count + 3) |_| App.timer(app, cx, 0);
    try std.testing.expectEqual(@as(u32, 3), app.transport.head);
    app.transport.recording = true;
    app.parse.bindings[0].value.fixed.units = 30;
    App.timer(app, cx, 0);
    try std.testing.expectEqual(@as(f32, 0.3), app.lanes.samples(0)[3]);
    try std.testing.expectEqual(@as(f32, 0.12), app.lanes.samples(0)[4]);
    app.parse.bindings[0].value.fixed.units = 12;
    _ = frame_at(app, 1280, 720);
    click(app, play[0] + 4, play[1] + 4);
    try std.testing.expect(!cx.timer_on);
    const back = cx.find(transport_ids[0]).?.rect;
    click(app, back[0] + 4, back[1] + 4);
    try std.testing.expectEqual(@as(u32, 0), app.transport.head);
}

// Locks the bench scenarios against this screen without a GPU (`patchwork.bench`, section
// 2a): the typing scenario's targets resolve, its click focuses the editor, and an even number
// of cycle steps leaves the stress text as loaded; the transport scenario starts the timer and
// then has no step of its own to run; the pulse scenario arms record and leaves the timer off.
test "the bench scenarios replay headless" {
    const bench = patchwork.bench;
    const size: [2]u32 = .{ 1280, 720 };
    var app = new_app();
    const cx = &fixture.context;
    const typing = bench.find(App.scenarios, "typing-stress").?;
    const typed = try bench.replay_headless(App, app, cx, typing, size, 20);
    try std.testing.expectEqual(@as(u32, 20), typed);
    try std.testing.expectEqual(editor_id, cx.focus);
    try std.testing.expectEqual(stress_lines, app.editor.buffer.line_count);
    try std.testing.expectEqualStrings(app.stress[0..app.stress_len], app.editor.text());
    app = new_app();
    const transport = bench.find(App.scenarios, "transport").?;
    const played = try bench.replay_headless(App, app, cx, transport, size, 20);
    try std.testing.expectEqual(@as(u32, 11), played);
    try std.testing.expect(cx.timer_on);
    try std.testing.expect(app.transport.playing);
    app = new_app();
    const pulse = bench.find(App.scenarios, "pulse").?;
    const pulsed = try bench.replay_headless(App, app, cx, pulse, size, 20);
    try std.testing.expectEqual(@as(u32, 20), pulsed);
    try std.testing.expect(app.transport.recording);
    try std.testing.expect(!cx.timer_on);
}

// Locks the bpm field: Enter after typing 130 rewrites `bpm := 121` as one undo entry;
// 999 is out of range and the field reverts to the text's value.
test "the bpm field rewrites the bpm line" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const field = cx.find(bpm_id).?.rect;
    click(app, field[0] + 4, field[1] + 4);
    _ = key(app, .a, ctrl, "");
    _ = key(app, .other, .none, "1");
    _ = key(app, .other, .none, "3");
    _ = key(app, .other, .none, "0");
    _ = key(app, .enter, .none, "");
    try std.testing.expect(std.mem.find(u8, app.editor.text(), "bpm := 130\n") != null);
    try std.testing.expectEqualStrings("130", app.bpm_field.bytes());
    _ = frame_at(app, 1280, 720);
    click(app, field[0] + 4, field[1] + 4);
    _ = key(app, .a, ctrl, "");
    _ = key(app, .other, .none, "9");
    _ = key(app, .other, .none, "9");
    _ = key(app, .other, .none, "9");
    _ = key(app, .enter, .none, "");
    try std.testing.expectEqualStrings("130", app.bpm_field.bytes());
    try std.testing.expectEqual(@as(u32, 1), app.editor.buffer.undo_count);
}

// Locks a value outside its range: it binds, its knob shows the clamped end, the value is an
// error decoration after the binding's box, and the header's status is a cross.
test "an out of range value binds clamped and is an error" {
    const app = new_app();
    app.load("a := k(0~5~1, \"a\")");
    _ = frame_at(app, 1280, 720);
    try std.testing.expectEqual(@as(u32, 1), app.parse.binding_count);
    try std.testing.expectEqual(@as(f32, 1), app.fraction(0));
    try std.testing.expect(!app.parse.ok());
    try std.testing.expectEqual(@as(u32, 2), app.editor.decoration_count);
    try std.testing.expectEqual(editor.Decoration.Kind.@"error", app.editor.decorations[1].kind);
    const icons = fixture.context.draw.items(icon.Icon);
    const cross: f32 = @floatFromInt(@backingInt(icon.Shape.cross));
    try std.testing.expectEqual(cross, icons[icons.len - 1].shape);
}

const fixture_gpu = struct {
    var renderer: patchwork.renderer.Renderer(Context.DrawContext) = undefined;
    var buffer: patchwork.commands.CommandBuffer = undefined;
};

/// Pool order in `config.draw`, plus the point buffer last.
const Upload = enum(u8) { box, glyph, arc, path, icon, glow, points };

/// Draws when owed and records one 1280 by 720 frame at scale 1; returns the bytes the
/// stream's buffer writes carry per `Upload`.
fn record(app: *App) [7]u64 {
    const cx = &fixture.context;
    _ = ui.draw_frame(App, app, cx, 1280, 720, 120);
    assert(cx.draw.overflow_count == 0);
    fixture_gpu.buffer.reset();
    fixture_gpu.renderer.frame(&fixture_gpu.buffer, &cx.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = 1280,
        .height_px = 720,
        .scale_120 = 120,
    }, 0);
    var writes: [16]patchwork.commands.BufferWrite = undefined;
    const resources = &fixture_gpu.renderer.resources;
    var bytes: [7]u64 = @splat(0);
    for (patchwork.renderer.writes(&fixture_gpu.buffer, &writes)) |write| {
        for (resources.instance_buffers, 0..) |id, index| {
            if (write.id == id) bytes[index] += write.data.len;
        }
        if (write.id == resources.points_buffer) {
            bytes[@backingInt(Upload.points)] += write.data.len;
        }
    }
    return bytes;
}

fn start_gpu() void {
    fixture_gpu.renderer.init();
    fixture_gpu.buffer = .init();
    fixture_gpu.renderer.setup(&fixture_gpu.buffer, &fixture.context.draw);
}

// Locks the upload ranges on the stress text at 1280 by 720, scrolled to line 960 (the long
// lines from 975 are in view): a settled redraw writes nothing; a one-line wheel scroll
// rewrites 41 boxes (3,280 bytes) and 1,898 glyph records (121,472 bytes); a key typed on
// line 982, 21 lines down the viewport, writes 3 boxes and 104 glyphs (6,896 bytes), because
// up to four ranges skip the records that came out equal at their index (one covering range
// wrote 29 boxes and 1,093 glyphs, 72,272 bytes, before step 29). The panel draws before the
// editor, so its records never move.
test "uploads of a scrolled frame and a typed key" {
    const app = new_app();
    start_gpu();
    _ = key(app, .f2, .none, "");
    app.editor.view.scroll_y = 960 * 21;
    _ = record(app);
    fixture.context.redraw();
    try std.testing.expectEqual([7]u64{ 0, 0, 0, 0, 0, 0, 0 }, record(app));
    _ = send(app, .{ .wheel = .{ .x = 600, .y = 400, .dx = 0, .dy = 21 } });
    const scrolled = record(app);
    try std.testing.expectEqual([7]u64{ 3_280, 121_472, 0, 0, 0, 0, 0 }, scrolled);
    click(app, 49.5 + 4 * 9, 40 + 4 + 10.5 + 20 * 21);
    _ = record(app);
    _ = key(app, .other, .none, "q");
    const typed = record(app);
    try std.testing.expectEqual(@as(u32, 981), app.editor.caret_position()[0]);
    try std.testing.expectEqual([7]u64{ 240, 6_656, 0, 0, 0, 0, 0 }, typed);
}

// Locks the transport's uploads on the patch at 1280 by 720: an idle redraw writes nothing;
// play swaps one icon record (64 bytes); a tick while playing writes only the playhead's Box
// record (80 bytes); after a knob moved and record was armed (one more icon), a recording
// tick writes the playhead, that lane's one changed point (8 bytes), and the one Path record
// holding it (80 bytes), and no other lane's points.
test "transport ticks upload the playhead and one recorded point" {
    const app = new_app();
    start_gpu();
    _ = record(app);
    fixture.context.redraw();
    try std.testing.expectEqual([7]u64{ 0, 0, 0, 0, 0, 0, 0 }, record(app));
    const cx = &fixture.context;
    app.transport.playing = true;
    cx.set_timer(true);
    cx.redraw();
    try std.testing.expectEqual([7]u64{ 0, 0, 0, 0, 64, 0, 0 }, record(app));
    App.timer(app, cx, 0);
    try std.testing.expectEqual([7]u64{ 80, 0, 0, 0, 0, 0, 0 }, record(app));
    const center = ring_center(4);
    _ = send(app, .{ .wheel = .{ .x = center[0], .y = center[1], .dx = 0, .dy = -12 } });
    _ = send(app, .{ .pointer_leave = {} });
    _ = record(app);
    app.transport.recording = true;
    cx.redraw();
    try std.testing.expectEqual([7]u64{ 0, 0, 0, 0, 64, 64, 0 }, record(app));
    App.timer(app, cx, 0);
    try std.testing.expectEqual([7]u64{ 80, 0, 0, 80, 0, 0, 8 }, record(app));
}

// Locks the record glow (section 5): arming record while paused draws one glow, centered on
// the record icon and under it, and the next undrawn frame is an animation-only frame (no
// pool write, a 16-byte time write, cached, not hashed); disarming drops the glow, and the
// frame after that is skipped with nothing animating, so the paused screen sleeps.
test "an armed record glows from time and a disarmed one sleeps" {
    const app = new_app();
    start_gpu();
    _ = record(app);
    const cx = &fixture.context;
    try std.testing.expect(!fixture_gpu.renderer.animating);
    const armed = cx.find(transport_ids[2]).?.rect;
    click(app, armed[0] + 4, armed[1] + 4);
    try std.testing.expect(app.transport.recording);
    try std.testing.expect(!cx.timer_on);
    try std.testing.expectEqual([7]u64{ 0, 0, 0, 0, 64, 64, 0 }, record(app));
    const glows = cx.draw.items(glow.Glow);
    try std.testing.expectEqual(@as(usize, 1), glows.len);
    try std.testing.expectEqual(armed[0] + 5 - glow.spread_px, glows[0].rect[0]);
    try std.testing.expectEqual(transport_icon_px + 2 * glow.spread_px, glows[0].rect[2]);
    try std.testing.expect(glow_batch_first(&cx.draw));
    try std.testing.expect(fixture_gpu.renderer.animating);
    try std.testing.expect(!cx.dirty);
    const drew = ui.draw_frame(App, app, cx, 1280, 720, 120);
    try std.testing.expect(!drew);
    fixture_gpu.buffer.reset();
    fixture_gpu.renderer.frame(&fixture_gpu.buffer, &cx.draw, .{
        .width_logical = 1280,
        .height_logical = 720,
        .width_px = 1280,
        .height_px = 720,
        .scale_120 = 120,
    }, 0.25);
    try std.testing.expect(!fixture_gpu.renderer.hashed);
    try std.testing.expect(fixture_gpu.renderer.animating);
    var writes: [4]patchwork.commands.BufferWrite = undefined;
    const recorded = patchwork.renderer.writes(&fixture_gpu.buffer, &writes);
    try std.testing.expectEqual(@as(usize, 1), recorded.len);
    try std.testing.expectEqual(quads.time_offset, recorded[0].offset);
    click(app, armed[0] + 4, armed[1] + 4);
    try std.testing.expect(!app.transport.recording);
    _ = record(app);
    try std.testing.expectEqual(@as(usize, 0), cx.draw.items(glow.Glow).len);
    try std.testing.expect(!fixture_gpu.renderer.animating);
    _ = record(app);
    try std.testing.expectEqual(patchwork.renderer.Kind.skipped, fixture_gpu.renderer.last);
}

/// True when the glow's batch comes before every icon batch, so it draws under the icons.
fn glow_batch_first(draw_cx: *const Context.DrawContext) bool {
    const glow_id = comptime Context.DrawContext.Registry.id(glow.Glow);
    const icon_id = comptime Context.DrawContext.Registry.id(icon.Icon);
    for (draw_cx.batch_list()) |batch| {
        if (batch.type_id == glow_id) return true;
        if (batch.type_id == icon_id) return false;
    }
    return false;
}

comptime {
    patchwork.app.check(App);
}

test {
    _ = bindings;
    _ = knob;
    _ = shaper;
    _ = lanes;
    _ = icon;
    _ = glow;
}

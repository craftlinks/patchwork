//! Live example: the code editor on a patch file, under a header bar.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The editor widget (`patchwork.editor`) filling the window under a header: syntax colours
//! from the tokenizer, editing with undo, selection, the clipboard, Tab indenting, both
//! scroll directions, and a box decoration around every number literal in view. It is the
//! base step 18 builds on (knobs bound to `k(lo~value~hi, "name")` calls). Every worked
//! number lives in this file's tests, for example "live layout at 1280 by 720".
//!
//! ## 2. Layout (logical pixels)
//! ```text
//! frame     flow down
//!   header  fill by header_px: the file name, the caret's line:col, and a status message
//!   editor  fill by fill
//! ```
//!
//! ## 3. Texts
//! F1 loads `patch.lpg` (embedded), F2 a generated stress text of 2,000 lines: 50 lines of
//! 120 columns in the middle (lines 975 to 1024) and short lines around them, 58,699 bytes
//! in all (test "F2 loads the stress text and F1 the patch"), under the editor's 64 KiB.
//! Both load through `Editor.load`, which clears the history.
//!
//! ## 4. Decorations
//! On a new revision or a new first visible line, the app tokenizes the lines a draw can
//! show (`editor.lines_max` from the first visible one) and boxes every number literal, at
//! most `editor.decoration_cap`. That is the visible-only rebuild step 18's binding parser
//! will replace.
//!
//! ## 5. Refusals
//! An edit the editor refuses (`Action.refused`) puts "paste refused: buffer full" or the
//! like into the header until the next accepted change.
//!
//! ## 6. Contract With the Library
//! `config.timer_period_ms` is 0 and the caret is steady, so an idle editor sleeps. The glyph
//! pool holds `editor.glyph_max` plus the header's `header_glyph_cap` (asserted).
//!
//! ## 7. TigerStyle Invariants
//! - The app is static in both hosts (about 300 KiB of editor plus the stress text).
//! - Every loop is bounded by the editor's caps or the stress line count.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const editor = patchwork.editor;

const Rect = quads.Rect;
const Context = patchwork.app.Context(App);

/// The embedded patch the editor opens with.
pub const patch_source = @embedFile("patch.lpg");

const header_px: f32 = 40;
const header_inset_px: f32 = 16;
const name_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = theme.chrome.text };
const position_style: text.Style = .{ .face = .mono, .size = 14, .color = theme.chrome.text };
const status_style: text.Style = .{ .face = .sans, .size = 14, .color = .{ 0.95, 0.55, 0.45, 1 } };
const position_left_px: f32 = 160;

/// Bytes of the header's three texts, which bound its glyphs.
const name_cap: u32 = 20;
const position_cap: u32 = 10;
const status_cap: u32 = 34;
const header_glyph_cap: u32 = name_cap + position_cap + status_cap;

/// Stress text shape (section 3).
pub const stress_lines: u32 = 2000;
pub const stress_long_first: u32 = 975;
pub const stress_long_count: u32 = 50;
pub const stress_long_columns: u32 = 120;

/// One box per decoration (numbers are single-line), a selection or line band per visible
/// line, and the faces, caret, thumb, and header.
const box_cap: u32 = editor.decoration_cap + editor.lines_max + 8;
/// Exactly the editor's worst draw plus the header (comptime block below).
const glyph_cap: u32 = editor.glyph_max + header_glyph_cap;
const area_cap: u32 = 8;

const editor_id = ui.id("editor", 0);

pub const Text = enum(u8) {
    patch,
    stress,
};

pub const App = struct {
    editor: editor.Editor,
    shown: Text,
    /// The revision and first line the decorations were built for.
    decorated_revision: u64,
    decorated_first: u32,
    status: [status_cap]u8,
    status_len: u32,
    stress: [editor.buffer.buffer_cap]u8,
    stress_len: u32,

    pub const config: patchwork.app.Config = .{
        .title = "live",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = box_cap },
            .{ .type = quads.Glyph, .cap = glyph_cap },
        },
        .batch_cap = 8,
        .area_cap = area_cap,
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.editor.init(editor_id, editor.default_style);
        app.stress_len = generate_stress(&app.stress);
        app.status_len = 0;
        app.show(.patch);
        assert(app.editor.buffer.line_count > 1);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .key_down => |press| {
                if (press.key == .f1 or press.key == .f2) {
                    app.show(if (press.key == .f1) .patch else .stress);
                    cx.redraw();
                    return;
                }
            },
            else => {},
        }
        switch (app.editor.handle(cx, event_value)) {
            .none => {},
            .changed => app.status_len = 0,
            .refused => app.set_status(),
        }
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        app.decorate();
        // The header is walked first but drawn last: its line:col readout changes with every
        // caret move, and records at the tail of the pools keep the upload ranges of a typed
        // key starting at the edited line (test "uploads of a scrolled frame and a typed key").
        const bar = cx.walk(ui.sized(.fill, .{ .fixed = header_px }));
        app.editor.draw(cx, ui.sized(.fill, .fill));
        draw_header(app, cx, bar);
    }

    fn show(app: *App, shown: Text) void {
        const source = switch (shown) {
            .patch => patch_source,
            .stress => app.stress[0..app.stress_len],
        };
        const loaded = app.editor.load(source);
        assert(loaded);
        app.shown = shown;
        app.status_len = 0;
        // A load always moves the revision, so the next draw rebuilds the decorations.
        app.decorated_revision = 0;
    }

    fn set_status(app: *App) void {
        const what = switch (app.editor.refused_source) {
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

    /// Boxes every number literal on the lines a draw can show (section 4).
    fn decorate(app: *App) void {
        const shown = &app.editor;
        const first = shown.first_visible_line();
        if (app.decorated_revision == shown.revision() and app.decorated_first == first) return;
        app.decorated_revision = shown.revision();
        app.decorated_first = first;
        shown.decoration_count = 0;
        const buffer = &shown.buffer;
        const end = @min(buffer.line_count, first + editor.lines_max);
        var line = first;
        while (line < end) : (line += 1) {
            const start = buffer.line_range(line).start;
            var state = buffer.states[line];
            var at: u32 = 0;
            while (editor.tokenizer.next(buffer.line_bytes(line), &at, &state)) |token| {
                if (token.class != .number) continue;
                if (shown.decoration_count == editor.decoration_cap) return;
                shown.decorations[shown.decoration_count] = .{
                    .start = start + token.start,
                    .end = start + token.end,
                    .kind = .box,
                };
                shown.decoration_count += 1;
            }
        }
        assert(shown.decoration_count <= editor.decoration_cap);
    }
};

/// The header: a face, the file name, the caret's line:col, and the status message.
fn draw_header(app: *const App, cx: *Context, bar: Rect) void {
    if (bar.width <= 2 * header_inset_px) return;
    const window = cx.clip() orelse return;
    cx.append(quads.Box, null, .{
        .rect = .{ bar.x, bar.y, bar.width, bar.height },
        .clip = .{ window.x0, window.y0, window.x1, window.y1 },
        .fill = theme.chrome.panel,
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    }) catch {};
    const sides: quads.Inset = .{
        .left = header_inset_px,
        .top = 0,
        .right = header_inset_px,
        .bottom = 0,
    };
    const inner = ui.cx.inset(bar, sides);
    const bar_clip = ui.cx.clip_of(bar);
    const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
    const name = switch (app.shown) {
        .patch => "patch.lpg",
        .stress => "stress, 2,000 lines",
    };
    comptime assert("stress, 2,000 lines".len <= name_cap);
    text.place(cx.drawing(), name_style, name, inner, bar_clip, left);
    const position = app.editor.caret_position();
    var digits: [position_cap + 2]u8 = undefined;
    const printed = std.fmt.bufPrint(&digits, "{d}:{d}", .{ position[0] + 1, position[1] + 1 });
    const readout = printed catch unreachable;
    assert(readout.len <= position_cap);
    const column: Rect = .{
        .x = inner.x + position_left_px,
        .y = inner.y,
        .width = @max(0, inner.width - position_left_px),
        .height = inner.height,
    };
    if (!(column.width > 0)) return;
    text.place(cx.drawing(), position_style, readout, column, bar_clip, left);
    const right: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = true };
    text.place(cx.drawing(), status_style, app.status[0..app.status_len], column, bar_clip, right);
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

comptime {
    assert(editor.glyph_max + header_glyph_cap == glyph_cap);
    assert(glyph_cap == 26_176);
    assert(header_glyph_cap == 64);
    assert(stress_long_first + stress_long_count <= stress_lines);
}

// ------------------------------------------------------------------------------ tests

/// The test app and context: static, like the hosts', so 300 KiB stay off the stack.
const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

fn new_app() *App {
    fixture.context.init();
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

// Locks the screen at 1280 by 720: the header is 40 px, the editor's viewport is the rest,
// and the first line's first byte sits at the editor's text origin (gutter 45, half a column,
// padding 4).
test "live layout at 1280 by 720" {
    const app = new_app();
    const cx = frame_at(app, 1280, 720);
    const viewport: Rect = .{ .x = 0, .y = 40, .width = 1280, .height = 680 };
    try std.testing.expectEqual(viewport, app.editor.viewport());
    const origin: Rect = .{ .x = 49.5, .y = 44, .width = 9, .height = 21 };
    try std.testing.expectEqual(origin, app.editor.rect_of(0));
    try std.testing.expectEqual(@as(u32, 80), app.editor.buffer.line_count);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
    try std.testing.expect(cx.find(editor_id) != null);
}

// Locks the decorations: every number literal of the patch's 80 lines is boxed (79 of them),
// the first is "121" on line 5, and each box covers a number.
test "every number literal in view gets a box" {
    const app = new_app();
    _ = frame_at(app, 1280, 720);
    const shown = &app.editor;
    try std.testing.expectEqual(@as(u32, 79), shown.decoration_count);
    const first = shown.decorations[0];
    try std.testing.expectEqualStrings("121", shown.text()[first.start..first.end]);
    try std.testing.expectEqual(@as(u32, 4), shown.buffer.line_of(first.start));
    for (shown.decorations[0..shown.decoration_count]) |decoration| {
        const bytes = shown.text()[decoration.start..decoration.end];
        try std.testing.expect(std.ascii.isDigit(bytes[0]) or bytes[0] == '.');
    }
}

// Locks the texts: F2 loads the 2,000-line stress text with 50 lines of 120 columns from
// line 975, F1 reloads the patch, and each load clears the history.
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
// it), every number in view is boxed below the cap, and nothing overflows a pool.
test "a tall window fills to the bottom" {
    const app = new_app();
    _ = key(app, .f2, .none, "");
    app.editor.view.scroll_y = 960 * 21;
    const cx = frame_at(app, 1280, 2160);
    var bottom: f32 = 0;
    for (cx.draw.items(quads.Glyph)) |glyph| bottom = @max(bottom, glyph.rect[1]);
    try std.testing.expect(bottom > 2160 - 2 * 21);
    try std.testing.expect(app.editor.decoration_count < editor.decoration_cap);
    try std.testing.expectEqual(@as(u32, 1062), app.editor.decoration_count);
    try std.testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

const fixture_gpu = struct {
    var renderer: patchwork.renderer.Renderer(Context.DrawContext) = undefined;
    var buffer: patchwork.commands.CommandBuffer = undefined;
};

/// Draws when owed and records one 1280 by 720 frame at scale 1; returns the bytes the
/// stream's buffer writes carry, per pool, as (boxes, glyphs).
fn record(app: *App) [2]u64 {
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
    });
    var writes: [8]patchwork.commands.BufferWrite = undefined;
    const resources = &fixture_gpu.renderer.resources;
    var bytes: [2]u64 = .{ 0, 0 };
    for (patchwork.renderer.writes(&fixture_gpu.buffer, &writes)) |write| {
        if (write.id == resources.instance_buffers[0]) bytes[0] += write.data.len;
        if (write.id == resources.instance_buffers[1]) bytes[1] += write.data.len;
    }
    return bytes;
}

// Locks the upload ranges on the stress text at 1280 by 720, scrolled to line 960 (the long
// lines from 975 are in view): a settled redraw writes nothing; a one-line wheel scroll
// rewrites 2,369 of the 2,371 glyph records (151,616 bytes) and 287 of 349 boxes (22,960
// bytes); a key typed on line 982, 21 lines down the viewport, writes the glyphs from that
// line on (indices shift by one), 1,369 records or 87,616 bytes, and 198 boxes.
test "uploads of a scrolled frame and a typed key" {
    const app = new_app();
    fixture_gpu.renderer.init();
    fixture_gpu.buffer = .init();
    fixture_gpu.renderer.setup(&fixture_gpu.buffer, &fixture.context.draw);
    _ = key(app, .f2, .none, "");
    app.editor.view.scroll_y = 960 * 21;
    _ = record(app);
    fixture.context.redraw();
    try std.testing.expectEqual([2]u64{ 0, 0 }, record(app));
    _ = send(app, .{ .wheel = .{ .x = 600, .y = 400, .dx = 0, .dy = 21 } });
    const scrolled = record(app);
    const glyph_count = fixture.context.draw.items(quads.Glyph).len;
    try std.testing.expectEqual(@as(usize, 2371), glyph_count);
    try std.testing.expectEqual(@as(u64, 151_616), scrolled[1]);
    try std.testing.expectEqual(@as(u64, 22_960), scrolled[0]);
    click(app, 49.5 + 4 * 9, 40 + 4 + 10.5 + 20 * 21);
    _ = record(app);
    _ = key(app, .other, .none, "q");
    const typed = record(app);
    try std.testing.expectEqual(@as(u32, 981), app.editor.caret_position()[0]);
    try std.testing.expectEqual(@as(u64, 87_616), typed[1]);
    try std.testing.expectEqual(@as(u64, 15_840), typed[0]);
}

comptime {
    patchwork.app.check(App);
}

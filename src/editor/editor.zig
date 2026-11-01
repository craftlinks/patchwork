//! The code editor widget: a buffer drawn on the monospace grid, or in a language's own faces,
//! in a scrolling view, with a caret, selection, keys, clipboard, undo, decorations, and inline
//! rows.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Shape
//! `EditorOf(L)` is the editor of language `L` (section 8), and `Editor` is the patch
//! language's. It is a plain widget struct like `TextField`: the app owns it (about 300 KiB, so
//! `init` takes an out-pointer and the app lives in static memory), routes every event to
//! `handle`, and calls `draw` (or the row iterator, section 6) while drawing. It records one
//! area, `id`, over the viewport: focusable, the I-beam, and `tab`, so a focused editor
//! takes Tab and Shift+Tab (`ui/cx.zig`, section 7); Escape still clears focus. Its view is
//! `id.derive(view_salt)`, whose thumb is that id derived again (`ui/view.zig`).
//!
//! ## 2. Geometry (logical pixels)
//! `g` is the last draw's geometry; `adv` and `lh` come from `text/mono.zig` (9 and 21 at
//! the default 15 px).
//! ```text
//! gutter_w    = (max(3, digits(line_count)) + 2) * adv     line numbers, right-aligned
//! text_left   = viewport.x + gutter_w + adv / 2            window x of column 0 unscrolled
//! text_w      = viewport.width - gutter_w - adv / 2 - view.gutter_px
//! line_top(i) = padding_px + i * lh + (heights of the rows after lines before i)
//! content_h   = 2 * padding_px + line_count * lh + (heights of all rows)
//! rect_of(b)  = (text_left - scroll_x + column(b) * adv,
//!                viewport.y - scroll_y + line_top(line_of(b)), adv, lh)
//! ```
//! `column(b)` counts the codepoints from the line start (the buffer holds no tabs), so it
//! is O(column); `line_of` is a binary search and `line_top` adds at most `row_cap` rows:
//! `rect_of` is O(log lines + column + rows). The rect is unclamped: a byte scrolled out
//! lies outside `viewport()`, and an app anchoring to it clamps. `style.gutter` off drops the
//! numbers: `gutter_w` is 0 and `text_left` is `viewport.x + padding_px`.
//!
//! In a language with `faces` (section 8) a line is a sum of advances, so "column to x" is a
//! table instead of a multiplication; a mono editor stores none of it (test "a mono editor pays
//! nothing for proportional faces").
//! ```text
//!                mono                         proportional
//! x of a byte    column * adv                 pens[line][column] when visible, else a walk
//! x to a byte    round(x / adv)               walk until pen + advance / 2 > x
//! goal           a column                     an x
//! widest line    (longest + 1) * adv          widest_px(), a walk of the text per revision
//! lh             text/mono.zig                text/faces.zig: the faces' largest
//! ```
//! `pens` is filled at the top of `draw_begin` for the visible lines, from each line's cached
//! state, and read wherever a rect is made, so a decoration stays O(1). It belongs to one
//! revision and size: between an edit and the next draw, `x_of` walks the line instead. The
//! gutter stays on the mono grid, so digits align. `rect_of`'s width is the codepoint's advance,
//! a space's at a line's end, and at least 1 for a mark that advances nothing.
//!
//! In a language with `scales` a tall line is a body line plus an extra height, so the buffer's
//! list of tall lines joins inline rows in the walks above:
//! ```text
//! line_top(i)  = padding_px + i * lh + (rows before i) + (extras of tall lines before i)
//! content_h    = 2 * padding_px + line_count * lh + (all rows) + (all extras)
//! ```
//! Its pens, advances, and baseline are `FaceSet`'s at that scale (`text/faces.zig`, section 4a).
//! Page Up and Down and the bounds of section 4 stay on the body pitch: a tall line only makes
//! fewer lines fit.
//!
//! ## 3. Scrolling
//! Vertical: the step 14 view (`ViewState`): the wheel's `dy`, the thumb, and a measured
//! content height; the editor skips the turtle over everything it draws itself, so the
//! view measures exactly `content_h`. Horizontal: the editor's own `scroll_x`, from the
//! wheel's `dx` (or `dy` with Shift), clamped to `[0, (longest + 1) * adv - text_w]` with
//! the buffer's longest line; there is no horizontal thumb. Every caret move and edit keeps
//! the caret visible both ways (`follow`). Dragging a selection past an edge selects what
//! lies there but does not scroll, because scrolling would need frames while the pointer
//! rests. A view with no height to scroll leaves the wheel alone (`ui/view.zig`, section 3),
//! so the editor's own area takes it while there is a horizontal range.
//!
//! ## 4. Drawing (per frame, visible lines only)
//! ```text
//! base layer   text and gutter faces, current line, selection, box and error decorations
//!              gutter numbers and glyphs coloured per token (the language's `next` runs
//!              from each visible line's cached start state; columns outside the clip are
//!              skipped)
//! layer 1      strike decorations and the caret
//! ```
//! At most `lines_max` lines and `columns_max` columns per line are drawn, so one draw
//! appends at most `glyph_max` glyphs. A viewport `w` by `h` at text size `s` bounds it
//! tighter, and `draw` asserts the bound:
//! ```text
//! lines_bound(h, s)     = min(lines_max, floor(h / lh) + 2)    tops inside, and the cut one
//! glyph_bound(w, h, s)  = lines_bound(h, s) * (min(columns_max, floor(w / adv) + 3)
//!                         + digits_max)                        x in (clip.x0 - 2 adv, x1)
//! ```
//! Both are callable at compile time, so an app sizes its glyph pool by its editors'
//! largest viewports (`glyph_max` is the bound for a viewport of any size). In proportional
//! faces a width bounds no columns, so `glyph_bound_of(L, w, h, s)` allows each drawn line
//! `columns_max`, and the slop left of the clip is `2 * s`, for italic overhang. Boxes
//! appended before the first glyph put the base layer's box batch under its glyph batch.
//! The caret is steady and nothing animates, so an idle editor never wakes the host.
//!
//! ## 5. Editing
//! Every change is `buffer.replace` (`editor/buffer.zig`), which may refuse: the action is
//! then `refused`, with `refusal` and `refused_source` saying why. Typing coalesces per word
//! (a word codepoint typed after a separator seals the open entry), runs of single
//! Backspace or Delete coalesce, and every other edit (Enter with auto-indent, Tab, paste,
//! cut, a word erase) is its own entry; indenting several lines is one gesture. Any caret
//! move seals. `replace(range, utf8)`, `replace_keeping(range, utf8, after)`, and
//! `gesture_begin`/`gesture_end` are the programmatic API (step 18's knobs rewrite literals
//! through them).
//! Keys: arrows (Ctrl or Meta: words), Up and Down keep a goal column, Home and End (with
//! Ctrl: the text), Page Up and Down by the visible lines, Shift extends, Backspace and
//! Delete (with Ctrl: words), Enter copies the line's leading spaces, Tab inserts spaces to
//! the next multiple of four or indents the selected lines, Shift+Tab outdents them, and
//! with Ctrl or Meta: A, C, X, V, Z (Shift: redo), and Y. Clicks 1, 2, and 3 place the
//! caret, select a word, and select a line; a drag extends.
//!
//! ## 6. Decorations and Inline Rows
//! The app owns `decorations[0..decoration_count]` (byte ranges and a kind) and
//! `rows[0..row_count]` (sorted by `after_line`), and rebuilds them when `revision()`
//! moves, because edits shift bytes. Decorations outside the visible bytes cost one compare;
//! the rest draw one box per visible line they cover. A row reserves `height` below its line
//! and is filled by the app through the iterator:
//! ```text
//! editor.draw_begin(cx, walk);
//! while (editor.next_row(cx)) |slot| { cx.begin(slot.walk, layout); ...; _ = cx.end(); }
//! editor.draw_end(cx);
//! ```
//! `next_row` skips the view's turtle to the next visible row and returns a walk the app
//! must consume (or ignore, leaving the row empty); rows ignore `scroll_x`.
//!
//! ## 7. TigerStyle Invariants
//! - Fixed storage; per-frame work is bounded by `lines_max`, `columns_max`,
//!   `decoration_cap`, and `row_cap`, never by the text.
//! - `caret` and `anchor` are codepoint boundaries in `0 ..= len` after every event.
//!
//! ## 8. Languages
//! `EditorOf(L)` checks `L` against the contract in `language.zig` at compile time (a named
//! compile error, like a skin) and keeps `L.State` per line in its `BufferOf(L)`. The
//! language decides the states, the classes, their default colours (`L.palette`, which
//! `default_palette` puts over the chrome colours), and the tokens. Columns are not its to
//! change: one per codepoint, and a gap between tokens is spaces, one column per byte (asserted
//! in safe builds). An optional `L.faces` sets each class in its own face, which changes where
//! a column lands and nothing else (section 2). Colours are per instance: an app may set
//! `style.palette` at any time. `default_palette` suits a dark scheme and `light_palette` a light one (the
//! language's optional `palette_light` over a light chrome); an app sets one when its scheme
//! changes. The editor never reads the theme itself.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const text = @import("../text.zig");
const mono_grid = @import("../text/mono.zig");
const layout = @import("../text/layout.zig");
const input = @import("../input.zig");
const ui = @import("../ui.zig");
const edit = @import("../ui/edit.zig");
const view = @import("../ui/view.zig");
const buffer_module = @import("buffer.zig");
const language = @import("language.zig");
const tokenizer = @import("tokenizer.zig");

const Rect = draw.Rect;
const Clip = draw.Clip;
const Id = ui.Id;
const Range = buffer_module.Range;
const Selection = buffer_module.Selection;

/// Decorations an app may set: enough for every number literal in a full `lines_max` view of
/// dense code (the live app's stress text needs about 1,060).
pub const decoration_cap: u32 = 2048;
/// Inline rows an app may set.
pub const row_cap: u32 = 32;
/// Lines one draw shows at most; a taller viewport leaves the rest empty.
pub const lines_max: u32 = 128;
/// Columns one line shows at most.
pub const columns_max: u32 = 200;
/// Digits a line number has at most (`buffer.line_cap` is 4,096).
pub const digits_max: u32 = 4;
/// Glyphs one draw appends at most: the text cells and the gutter numbers.
pub const glyph_max: u32 = lines_max * (columns_max + digits_max);
/// Lines one draw shows at most in a viewport `height` logical pixels tall at text `size`:
/// those whose tops fall inside it, plus the one the top edge cuts. At most `lines_max`.
pub fn lines_bound(height: f32, size: f32) u32 {
    return lines_of_pitch(height, mono_grid.line_height_of(size));
}

fn lines_of_pitch(height: f32, pitch: f32) u32 {
    assert(height >= 0);
    assert(pitch > 0);
    const fit = @min(height / pitch, @as(f32, lines_max));
    return @min(lines_max, @as(u32, @intFromFloat(@floor(fit))) + 2);
}

/// Glyphs one draw appends at most in a viewport `width` by `height` logical pixels at text
/// `size` (section 4): per drawn line, its gutter digits and the columns from two left of
/// the clip to its right edge. At most `glyph_max`; callable at compile time, so an app
/// sizes its glyph pool by its editors' largest viewports.
pub fn glyph_bound(width: f32, height: f32, size: f32) u32 {
    assert(width >= 0);
    assert(size > 0);
    const fit = @min(width / mono_grid.advance_of(size), @as(f32, columns_max));
    const columns = @min(columns_max, @as(u32, @intFromFloat(@floor(fit))) + 3);
    const bound = lines_bound(height, size) * (columns + digits_max);
    assert(bound <= glyph_max);
    return bound;
}

/// The face tables of language `L`: a `text.FaceSet` when `L` declares `faces`, else nothing.
fn FacesOf(comptime L: type) type {
    return if (language.proportional(L)) text.FaceSet(&L.faces) else void;
}

/// The line pitch of language `L` at `size`. Callable at compile time.
pub fn line_height_of(comptime L: type, size: f32) f32 {
    if (comptime language.proportional(L)) return FacesOf(L).line_height_of(size);
    return mono_grid.line_height_of(size);
}

/// `lines_bound` for language `L`, whose pitch comes from its faces (section 4).
pub fn lines_bound_of(comptime L: type, height: f32, size: f32) u32 {
    return lines_of_pitch(height, line_height_of(L, size));
}

/// `glyph_bound` for language `L`. A width bounds no columns in proportional faces, where an
/// "i" is a quarter of an em, so each drawn line may take `columns_max` (section 4).
pub fn glyph_bound_of(comptime L: type, width: f32, height: f32, size: f32) u32 {
    if (comptime !language.proportional(L)) return glyph_bound(width, height, size);
    assert(width >= 0);
    const bound = lines_bound_of(L, height, size) * (columns_max + digits_max);
    assert(bound <= glyph_max);
    return bound;
}

/// Space above the first line and below the last.
pub const padding_px: f32 = 4;
/// Tallest inline row.
pub const row_height_max: f32 = 640;
/// The `derive` salt of the editor's view id.
pub const view_salt: u64 = 1;
/// The layer of strikes and the caret, above the base layer's glyphs.
pub const over_layer: draw.Layer = @fromBackingInt(1);
/// Width of the caret in device pixels.
pub const caret_px: f32 = 2;

/// The editor's area flags (section 1).
pub const flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = true,
    .cursor = .text,
    .primary_only = true,
};

/// Colours, straight RGBA, of an editor of language `L`: `classes` is indexed by `L.Class`
/// (section 8).
pub fn PaletteOf(comptime L: type) type {
    return struct {
        classes: [language.class_count(L)][4]f32,
        background: [4]f32,
        gutter: [4]f32,
        gutter_text: [4]f32,
        gutter_current: [4]f32,
        current_line: [4]f32,
        selection: [4]f32,
        caret: [4]f32,
        box: [4]f32,
        strike: [4]f32,
        error_line: [4]f32,
        error_fill: [4]f32,
    };
}

/// The text size and colours of an editor of language `L`.
pub fn StyleOf(comptime L: type) type {
    return struct {
        size: f32,
        palette: PaletteOf(L),
        /// False: no line numbers, and the text starts `padding_px` into the viewport.
        gutter: bool = true,
    };
}

/// A drawn mark over bytes `start .. end` (section 6).
pub const Decoration = struct {
    start: u32,
    end: u32,
    kind: Kind,

    pub const Kind = enum(u8) {
        /// A bordered box with a transparent fill, under the text.
        box,
        /// A 2 px bar through the text, over it.
        strike,
        /// A red underline and a faint red fill, under the text.
        @"error",
    };
};

/// `height` logical pixels reserved below line `after_line` (section 6).
pub const InlineRow = struct {
    after_line: u32,
    height: f32,
};

/// A visible inline row: `walk` places it in the view's turtle; `rect` is where it lands.
pub const RowSlot = struct {
    index: u32,
    walk: ui.Walk,
    rect: Rect,
};

pub const Action = enum {
    none,
    changed,
    /// A cap refused the edit; see `refusal` and `refused_source`.
    refused,
};

/// What asked for the last refused edit.
pub const Source = enum(u8) {
    key,
    paste,
    call,
};

/// The last draw's geometry (section 2).
const Geometry = struct {
    viewport: Rect,
    text_left: f32,
    text_width: f32,
    gutter_width: f32,
    drawn: bool,
};

/// State of one draw between `draw_begin` and `draw_end`.
const Pass = struct {
    open: bool,
    /// The view's clip is empty: nothing draws and no row is offered.
    empty: bool,
    next_row: u32,
};

/// The visible lines of one draw: the first, how many, and each one's window top.
const Visible = struct {
    first: u32,
    count: u32,
    tops: [lines_max]f32,
};

/// What a proportional editor keeps of its lines' x (section 2): the pens of the visible lines
/// and the widest line. A mono editor has none of it.
const Pens = struct {
    /// Each visible line's pens, relative to column 0: `x[offset][column]`.
    x: [lines_max][columns_max + 1]f32,
    /// Pens per visible line: its codepoints plus one, at most `columns_max + 1`.
    counts: [lines_max]u16,
    first: u32,
    lines: u32,
    /// The text and size the table was filled for; an edit outdates it until the next draw.
    revision: u64,
    size: f32,
    /// The widest line in pixels, and the text and size it was measured for.
    widest: f32,
    widest_revision: u64,
    widest_size: f32,
    /// Walks of the whole text, which one revision pays once.
    widest_walks: u32,
};

/// One codepoint of a line in a proportional walk: bytes `byte .. end` of the line.
const Cell = struct {
    byte: u32,
    end: u32,
    codepoint: u21,
    /// `L.Class` as a number; a gap between tokens is class 0 (`language.zig`, section 2).
    class: u8,
    gap: bool,
};

/// Walks a line codepoint by codepoint, gaps included, from its cached start state.
fn LineWalk(comptime L: type) type {
    return struct {
        const Self = @This();

        bytes: []const u8,
        state: L.State,
        at: u32 = 0,
        byte: u32 = 0,
        token: ?language.Token(L.Class) = null,
        spent: bool = false,

        fn next(self: *Self) ?Cell {
            assert(self.byte <= self.bytes.len);
            if (self.byte == self.bytes.len) return null;
            if (self.token == null and !self.spent) {
                self.token = L.next(self.bytes, &self.at, &self.state);
                self.spent = self.token == null;
            }
            const start = self.byte;
            if (self.token) |token| {
                if (start >= token.start) {
                    const codepoint = layout.decode(self.bytes, &self.byte);
                    if (self.byte >= token.end) self.token = null;
                    return .{
                        .byte = start,
                        .end = self.byte,
                        .codepoint = codepoint,
                        .class = @backingInt(token.class),
                        .gap = false,
                    };
                }
            }
            self.byte += 1;
            return .{ .byte = start, .end = self.byte, .codepoint = ' ', .class = 0, .gap = true };
        }
    };
}

/// The editor of language `L` (`language.zig`; section 8). `L` is checked at compile time.
pub fn EditorOf(comptime L: type) type {
    if (comptime language.check(L)) |problem| @compileError(problem);
    const proportional = language.proportional(L);
    const sized = language.scaled(L);
    return struct {
        const Self = @This();
        const Buffer = buffer_module.BufferOf(L);
        const Faces = FacesOf(L);
        /// What Up and Down aim for: a column on the grid, an x in proportional faces.
        const Goal = if (proportional) f32 else u32;

        /// The language this editor colours.
        pub const Language = L;
        pub const Palette = PaletteOf(L);
        pub const Style = StyleOf(L);

        /// The language's class colours over the default chrome.
        pub const default_palette: Palette = .{
            .classes = L.palette,
            .background = .{ 0.11, 0.12, 0.15, 1 },
            .gutter = .{ 0.09, 0.10, 0.12, 1 },
            .gutter_text = .{ 0.40, 0.43, 0.48, 1 },
            .gutter_current = .{ 0.80, 0.82, 0.85, 1 },
            .current_line = .{ 1, 1, 1, 0.04 },
            .selection = .{ 0.26, 0.42, 0.70, 0.45 },
            .caret = .{ 0.95, 0.95, 0.90, 1 },
            .box = .{ 0.95, 0.68, 0.40, 0.65 },
            .strike = .{ 0.90, 0.40, 0.40, 0.90 },
            .error_line = .{ 0.95, 0.33, 0.33, 1 },
            .error_fill = .{ 0.95, 0.33, 0.33, 0.12 },
        };

        pub const default_style: Style = .{ .size = 15, .palette = default_palette };

        /// The language's light class colours (`L.palette_light`, else `L.palette`) over a
        /// light chrome, for an app to set on a light scheme (section 8).
        pub const light_palette: Palette = .{
            .classes = if (@hasDecl(L, "palette_light")) L.palette_light else L.palette,
            .background = .{ 0.98, 0.98, 0.99, 1 },
            .gutter = .{ 0.94, 0.95, 0.96, 1 },
            .gutter_text = .{ 0.60, 0.62, 0.66, 1 },
            .gutter_current = .{ 0.20, 0.22, 0.25, 1 },
            .current_line = .{ 0, 0, 0, 0.04 },
            .selection = .{ 0.72, 0.81, 0.97, 0.70 },
            .caret = .{ 0.12, 0.13, 0.15, 1 },
            .box = .{ 0.79, 0.47, 0.20, 0.70 },
            .strike = .{ 0.80, 0.25, 0.25, 0.90 },
            .error_line = .{ 0.85, 0.20, 0.20, 1 },
            .error_fill = .{ 0.85, 0.20, 0.20, 0.10 },
        };

        pub const light_style: Style = .{ .size = 15, .palette = light_palette };

        id: Id,
        style: Style,
        buffer: Buffer,
        caret: u32,
        anchor: u32,
        /// What Up and Down aim for, kept across vertical moves.
        goal: ?Goal,
        view: ui.ViewState,
        scroll_x: f32,
        decorations: [decoration_cap]Decoration,
        decoration_count: u32,
        rows: [row_cap]InlineRow,
        row_count: u32,
        refusal: buffer_module.Refusal,
        refused_source: Source,
        /// Paste sanitizing and load staging.
        scratch: [buffer_module.buffer_cap]u8,
        mono: mono_grid.Mono,
        faces: Faces,
        pens: if (proportional) Pens else void,
        geometry: Geometry,
        pass: Pass,

        /// An empty editor. Out-pointer init (section 1).
        pub fn init(self: *Self, id: Id, style: Style) void {
            assert(id != .none);
            assert(style.size > 0);
            self.id = id;
            self.style = style;
            self.buffer.init();
            self.caret = 0;
            self.anchor = 0;
            self.goal = null;
            self.view = ui.ViewState.init();
            self.scroll_x = 0;
            self.decoration_count = 0;
            self.row_count = 0;
            self.refusal = .none;
            self.refused_source = .call;
            self.geometry = .{
                .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .text_left = 0,
                .text_width = 0,
                .gutter_width = 0,
                .drawn = false,
            };
            self.pass = .{ .open = false, .empty = true, .next_row = 0 };
            if (comptime proportional) {
                self.pens.lines = 0;
                self.pens.size = 0;
                self.pens.widest_size = 0;
                self.pens.widest_walks = 0;
            }
            assert(self.buffer.len == 0);
        }

        /// Replaces the text with `utf8`, sanitized (`edit.sanitize_text`), clears the history,
        /// and puts the caret at the start, scrolled home. False when it does not fit.
        pub fn load(self: *Self, utf8: []const u8) bool {
            assert(!self.pass.open);
            const sanitized = edit.sanitize_text(utf8, 0, &self.scratch);
            if (!sanitized.complete) {
                self.refusal = .bytes;
                self.refused_source = .call;
                return false;
            }
            if (!self.buffer.load(self.scratch[0..sanitized.len])) {
                self.refusal = self.buffer.refusal;
                self.refused_source = .call;
                return false;
            }
            self.caret = 0;
            self.anchor = 0;
            self.goal = null;
            self.view.scroll_y = 0;
            self.scroll_x = 0;
            self.refusal = .none;
            assert(self.buffer.line_count >= 1);
            return true;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.buffer.text();
        }

        /// Moves on every change of the text, undo and redo included.
        pub fn revision(self: *const Self) u64 {
            return self.buffer.revision;
        }

        /// The selected byte range, ordered.
        pub fn selection(self: *const Self) Range {
            assert(self.caret <= self.buffer.len);
            assert(self.anchor <= self.buffer.len);
            const start = @min(self.caret, self.anchor);
            return .{ .start = start, .end = @max(self.caret, self.anchor) };
        }

        /// The caret's line and codepoint column, both from 0.
        pub fn caret_position(self: *const Self) [2]u32 {
            const line = self.buffer.line_of(self.caret);
            return .{ line, self.column_of(self.caret) };
        }

        /// The first line the current scroll shows. A draw shows at most `lines_max` lines from
        /// it, so an app that decorates only what is visible scans those.
        /// The offset is clamped as the next draw will clamp it, so an edit that shortened the
        /// text names the line that draw shows.
        pub fn first_visible_line(self: *const Self) u32 {
            assert(self.view.scroll_y >= 0);
            const room = self.content_height() - self.geometry.viewport.height;
            return self.line_at(std.math.clamp(self.view.scroll_y, 0, @max(0, room)));
        }

        /// The viewport of the last draw.
        pub fn viewport(self: *const Self) Rect {
            assert(self.geometry.viewport.width >= 0);
            return self.geometry.viewport;
        }

        /// The logical rect of the character at `byte` (section 2).
        pub fn rect_of(self: *const Self, byte: u32) Rect {
            assert(byte <= self.buffer.len);
            const g = self.geometry;
            const line = self.buffer.line_of(byte);
            const rect: Rect = .{
                .x = g.text_left - self.scroll_x + self.x_of(line, byte),
                .y = g.viewport.y - self.view.scroll_y + self.line_top(line),
                .width = self.width_at(line, byte),
                .height = self.height_of_line(line),
            };
            assert(rect.width > 0);
            return rect;
        }

        /// Replaces `range` with `utf8` as one undo entry, or as part of an open gesture; the
        /// caret and anchor follow the text. The caller owes a redraw. False when refused.
        pub fn replace(self: *Self, range: Range, utf8: []const u8) bool {
            assert(range.end <= self.buffer.len);
            const delta_end = range.start + @as(u32, @intCast(utf8.len));
            return self.replace_keeping(range, utf8, .{
                .caret = map_through(self.caret, range, delta_end),
                .anchor = map_through(self.anchor, range, delta_end),
            });
        }

        /// `replace` with the selection the caller works out, kept in the undo entry so redo
        /// restores it: for an edit that moves text, whose caret should move with it.
        pub fn replace_keeping(self: *Self, range: Range, utf8: []const u8, after: Selection) bool {
            assert(range.end <= self.buffer.len);
            const change: buffer_module.Change = .{
                .kind = .other,
                .before = self.selection_now(),
                .after = after,
            };
            if (!self.buffer.replace(range, utf8, change)) {
                self.refusal = self.buffer.refusal;
                self.refused_source = .call;
                return false;
            }
            self.caret = after.caret;
            self.anchor = after.anchor;
            assert(self.caret <= self.buffer.len);
            return true;
        }

        pub fn gesture_begin(self: *Self) void {
            self.buffer.gesture_begin();
        }

        pub fn gesture_end(self: *Self) void {
            self.buffer.gesture_end();
        }

        /// The history mark for a dirty marker (`editor/buffer.zig`, section 4).
        pub fn history_mark(self: *const Self) u64 {
            return self.buffer.history_mark();
        }

        pub fn view_id(self: *const Self) Id {
            return self.id.derive(view_salt);
        }

        // ------------------------------------------------------------------- events

        /// Applies one event; see the module guide, sections 3 and 5.
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(!self.pass.open);
            if (event == .frame) return .none;
            if (cx.focus_lost(self.id)) {
                self.buffer.seal();
                cx.redraw();
            }
            // Tab can bring focus without a press; the caret and line band must appear.
            if (cx.focus_gained(self.id)) cx.redraw();
            switch (event) {
                .key_down => |press| {
                    if (!cx.focused(self.id)) return .none;
                    return self.key(cx, press);
                },
                .paste => |pasted| {
                    if (!cx.focused(self.id)) return .none;
                    return self.paste(cx, pasted);
                },
                .wheel => {
                    for ([_]Id{ self.view_id(), self.id }) |target| {
                        switch (cx.hit(target, event)) {
                            .wheel => |wheel| self.scroll_by(cx, wheel),
                            else => {},
                        }
                    }
                    return .none;
                },
                else => {},
            }
            _ = self.view.handle(cx, self.view_id(), event);
            self.pointer(cx, cx.hit(self.id, event));
            return .none;
        }

        fn scroll_by(self: *Self, cx: anytype, wheel: input.Wheel) void {
            var dx = wheel.dx;
            var dy = wheel.dy;
            if (cx.mods.shift) {
                dx += dy;
                dy = 0;
            }
            if (dy != 0) _ = self.view.scroll_to(cx, self.view.scroll_y + dy);
            if (dx != 0) {
                const next = std.math.clamp(self.scroll_x + dx, 0, self.scroll_x_max());
                if (next != self.scroll_x) {
                    self.scroll_x = next;
                    cx.redraw();
                }
            }
            assert(self.scroll_x >= 0);
        }

        fn pointer(self: *Self, cx: anytype, hit: ui.Hit) void {
            switch (hit) {
                .down => |press| {
                    self.buffer.seal();
                    const byte = self.byte_at(press.x, press.y);
                    if (press.clicks >= 3) {
                        const line = self.buffer.line_of(byte);
                        const range = self.buffer.line_range(line);
                        self.anchor = range.start;
                        self.caret = @min(range.end + 1, self.buffer.len);
                    } else if (press.clicks == 2) {
                        const range = edit.word_around(self.text(), byte);
                        self.anchor = range.start;
                        self.caret = range.end;
                    } else {
                        self.caret = byte;
                        if (!press.mods.shift) self.anchor = byte;
                    }
                    self.goal = null;
                    self.follow();
                    cx.redraw();
                },
                .drag => |press| {
                    const byte = self.byte_at(press.x, press.y);
                    if (byte != self.caret) {
                        self.caret = byte;
                        self.goal = null;
                        cx.redraw();
                    }
                },
                else => {},
            }
            assert(self.caret <= self.buffer.len);
        }

        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(cx.focused(self.id));
            if (press.mods.shortcut()) return self.shortcut(cx, press);
            switch (press.key) {
                .left, .right, .up, .down, .home, .end, .page_up, .page_down => {
                    self.move(cx, press.key, press.mods.shift, false);
                    return .none;
                },
                .backspace => return self.erase(cx, .backward, false),
                .delete => return self.erase(cx, .forward, false),
                .enter => return self.enter(cx),
                .tab => return self.tab(cx, press.mods.shift),
                .escape => return .none,
                else => {
                    if (press.len == 0) return .none;
                    return self.type_text(cx, press.typed());
                },
            }
        }

        fn shortcut(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(press.mods.shortcut());
            const shift = press.mods.shift;
            switch (press.key) {
                .a => {
                    self.buffer.seal();
                    self.anchor = 0;
                    self.caret = self.buffer.len;
                    cx.redraw();
                },
                .c => {
                    const range = self.selection();
                    if (range.end > range.start) cx.copy(self.text()[range.start..range.end]);
                },
                .x => {
                    const range = self.selection();
                    if (range.end == range.start) return .none;
                    cx.copy(self.text()[range.start..range.end]);
                    return self.commit(cx, range, "", .other, .key);
                },
                .v => cx.request_paste(),
                .z => return self.history(cx, if (shift) .redo else .undo),
                .y => return self.history(cx, .redo),
                .left, .right, .home, .end => self.move(cx, press.key, shift, true),
                .backspace => return self.erase(cx, .backward, true),
                .delete => return self.erase(cx, .forward, true),
                else => {},
            }
            return .none;
        }

        /// Takes back the last edit, as Ctrl+Z does, for an app that routes the key itself.
        pub fn undo(self: *Self, cx: anytype) Action {
            return self.history(cx, .undo);
        }

        /// Restores the last edit undone, as Ctrl+Y does.
        pub fn redo(self: *Self, cx: anytype) Action {
            return self.history(cx, .redo);
        }

        fn history(self: *Self, cx: anytype, way: enum { undo, redo }) Action {
            const restored = switch (way) {
                .undo => self.buffer.undo(),
                .redo => self.buffer.redo(),
            } orelse return .none;
            self.caret = @min(restored.caret, self.buffer.len);
            self.anchor = @min(restored.anchor, self.buffer.len);
            self.goal = null;
            self.follow();
            cx.redraw();
            assert(edit.is_boundary(self.text(), self.caret));
            return .changed;
        }

        /// Moves the caret for a navigation key; `word` is Ctrl or Meta (section 5).
        fn move(self: *Self, cx: anytype, key_name: input.Key, extend: bool, word: bool) void {
            self.buffer.seal();
            const bytes = self.text();
            const range = self.selection();
            const collapse = range.end > range.start and !extend;
            const vertical = switch (key_name) {
                .up, .down, .page_up, .page_down => true,
                else => false,
            };
            if (!vertical) self.goal = null;
            const target: u32 = switch (key_name) {
                .left => if (collapse) range.start else if (word)
                    edit.word_left(bytes, self.caret)
                else
                    edit.prev_boundary(bytes, self.caret),
                .right => if (collapse) range.end else if (word)
                    edit.word_right(bytes, self.caret)
                else
                    edit.next_boundary(bytes, self.caret),
                .home => if (word) 0 else self.buffer.line_range(self.caret_line()).start,
                .end => if (word)
                    self.buffer.len
                else
                    self.buffer.line_range(self.caret_line()).end,
                .up => self.vertical_target(-1),
                .down => self.vertical_target(1),
                .page_up => self.vertical_target(-@as(i32, @intCast(self.page_lines()))),
                .page_down => self.vertical_target(@intCast(self.page_lines())),
                else => unreachable,
            };
            self.caret = target;
            if (!extend) self.anchor = target;
            self.follow();
            cx.redraw();
            assert(edit.is_boundary(self.text(), self.caret));
        }

        /// The byte `lines` lines away at the goal, which the first vertical move sets.
        fn vertical_target(self: *Self, lines: i32) u32 {
            const goal = self.goal orelse self.goal_now();
            self.goal = goal;
            const line: i64 = @as(i64, self.caret_line()) + lines;
            if (line < 0) return 0;
            if (line >= self.buffer.line_count) return self.buffer.len;
            if (comptime proportional) return self.byte_at_x(@intCast(line), goal);
            return self.byte_of_column(@intCast(line), goal);
        }

        fn goal_now(self: *const Self) Goal {
            if (comptime proportional) return self.x_of(self.caret_line(), self.caret);
            return self.column_of(self.caret);
        }

        fn type_text(self: *Self, cx: anytype, typed: []const u8) Action {
            assert(typed.len >= 1);
            const range = self.selection();
            if (range.end > range.start) self.buffer.seal();
            if (edit.is_word(typed[0]) and self.caret > 0) {
                const previous = edit.prev_boundary(self.text(), self.caret);
                if (!edit.is_word(self.text()[previous])) self.buffer.seal();
            }
            return self.commit(cx, range, typed, .typing, .key);
        }

        fn erase(self: *Self, cx: anytype, direction: edit.Direction, word: bool) Action {
            const range = self.selection();
            if (range.end > range.start) return self.commit(cx, range, "", .other, .key);
            const bytes = self.text();
            const target = switch (direction) {
                .backward => if (word)
                    edit.word_left(bytes, self.caret)
                else
                    edit.prev_boundary(bytes, self.caret),
                .forward => if (word)
                    edit.word_right(bytes, self.caret)
                else
                    edit.next_boundary(bytes, self.caret),
            };
            if (target == self.caret) return .none;
            const low = @min(target, self.caret);
            const span: Range = .{ .start = low, .end = @max(target, self.caret) };
            return self.commit(cx, span, "", if (word) .other else .erasing, .key);
        }

        /// Enter: a line break plus the current line's leading spaces before the caret.
        fn enter(self: *Self, cx: anytype) Action {
            const range = self.selection();
            const line = self.buffer.line_range(self.buffer.line_of(range.start));
            var indent: u32 = 0;
            while (line.start + indent < range.start and self.text()[line.start + indent] == ' ') {
                indent += 1;
            }
            const room: u32 = @intCast(self.scratch.len - 1);
            indent = @min(indent, room);
            self.scratch[0] = '\n';
            @memset(self.scratch[1..][0..indent], ' ');
            return self.commit(cx, range, self.scratch[0 .. indent + 1], .other, .key);
        }

        /// Tab: spaces to the next stop, or with several lines selected (or Shift) an indent or
        /// outdent of every selected line as one gesture.
        fn tab(self: *Self, cx: anytype, outdent: bool) Action {
            const range = self.selection();
            const first = self.buffer.line_of(range.start);
            const last = self.buffer.line_of(range.end);
            if (!outdent and first == last) {
                const column = self.column_of(range.start);
                const spaces = edit.tab_width - column % edit.tab_width;
                @memset(self.scratch[0..spaces], ' ');
                return self.commit(cx, range, self.scratch[0..spaces], .other, .key);
            }
            const before = self.selection_now();
            self.buffer.gesture_begin();
            var refused = false;
            var line = last + 1;
            while (line > first) {
                line -= 1;
                if (!self.indent_line(line, outdent, before)) refused = true;
            }
            self.anchor = self.buffer.line_range(first).start;
            self.caret = self.buffer.line_range(last).end;
            self.buffer.amend_after(self.selection_now());
            self.buffer.gesture_end();
            self.goal = null;
            self.follow();
            cx.redraw();
            if (refused) {
                self.refusal = self.buffer.refusal;
                self.refused_source = .key;
                return .refused;
            }
            return .changed;
        }

        /// Adds `tab_width` leading spaces to `line`, or removes up to that many.
        /// `before` is the selection when the indent began; the gesture's entry restores it.
        fn indent_line(self: *Self, line: u32, outdent: bool, before: Selection) bool {
            const range = self.buffer.line_range(line);
            const change: buffer_module.Change = .{
                .kind = .other,
                .before = before,
                .after = before,
            };
            if (!outdent) {
                const at: Range = .{ .start = range.start, .end = range.start };
                return self.buffer.replace(at, "    ", change);
            }
            var spaces: u32 = 0;
            while (spaces < edit.tab_width and range.start + spaces < range.end and
                self.text()[range.start + spaces] == ' ') spaces += 1;
            if (spaces == 0) return true;
            const cut: Range = .{ .start = range.start, .end = range.start + spaces };
            return self.buffer.replace(cut, "", change);
        }

        fn paste(self: *Self, cx: anytype, pasted: []const u8) Action {
            const range = self.selection();
            const column = self.column_of(range.start);
            const sanitized = edit.sanitize_text(pasted, column, &self.scratch);
            if (!sanitized.complete) {
                self.refusal = .bytes;
                self.refused_source = .paste;
                cx.redraw();
                return .refused;
            }
            self.buffer.seal();
            return self.commit(cx, range, self.scratch[0..sanitized.len], .other, .paste);
        }

        /// Replaces `range` with `utf8`, puts the caret after it, and keeps it visible.
        fn commit(
            self: *Self,
            cx: anytype,
            range: Range,
            utf8: []const u8,
            kind: buffer_module.Kind,
            source: Source,
        ) Action {
            const end = range.start + @as(u32, @intCast(utf8.len));
            const change: buffer_module.Change = .{
                .kind = kind,
                .before = self.selection_now(),
                .after = .{ .caret = end, .anchor = end },
            };
            cx.redraw();
            if (!self.buffer.replace(range, utf8, change)) {
                self.refusal = self.buffer.refusal;
                self.refused_source = source;
                return .refused;
            }
            self.refusal = .none;
            self.caret = end;
            self.anchor = end;
            self.goal = null;
            self.follow();
            assert(self.caret <= self.buffer.len);
            return .changed;
        }

        /// Scrolls so the caret is inside the viewport both ways (section 3). Before the first
        /// draw there is no viewport and nothing scrolls.
        fn follow(self: *Self) void {
            const g = self.geometry;
            if (!g.drawn) return;
            self.view.content_h = self.content_height();
            const top = self.line_top(self.caret_line());
            const bottom = top + self.height_of_line(self.caret_line()) + padding_px;
            var scroll_y = self.view.scroll_y;
            if (top - padding_px < scroll_y) scroll_y = top - padding_px;
            if (bottom > scroll_y + g.viewport.height) scroll_y = bottom - g.viewport.height;
            self.view.scroll_y = std.math.clamp(scroll_y, 0, self.view.max_scroll());
            const line = self.caret_line();
            const x = self.x_of(line, self.caret);
            const width = self.width_at(line, self.caret);
            if (x < self.scroll_x) self.scroll_x = x;
            if (x + width > self.scroll_x + g.text_width) {
                self.scroll_x = x + width - g.text_width;
            }
            self.scroll_x = std.math.clamp(self.scroll_x, 0, self.scroll_x_max());
            assert(self.view.scroll_y >= 0);
            assert(self.scroll_x >= 0);
        }

        // ----------------------------------------------------------------- geometry

        fn advance(self: *const Self) f32 {
            return mono_grid.advance_of(self.style.size);
        }

        /// The space between the gutter's right edge and column 0.
        fn lead(self: *const Self) f32 {
            return if (self.style.gutter) self.advance() * 0.5 else padding_px;
        }

        fn line_height(self: *const Self) f32 {
            return line_height_of(L, self.style.size);
        }

        /// The device row of the baseline of `line`, whose top is `top`.
        fn baseline_of(self: *const Self, line: u32, top: f32) f32 {
            if (comptime proportional) return self.faces.baseline_at(top, self.scale_at(line));
            return self.mono.baseline_of(top);
        }

        /// The scale of `line`; 1 unless the language sizes its lines.
        fn scale_at(self: *const Self, line: u32) f32 {
            if (comptime !sized) return 1;
            return L.scales[self.buffer.level_at(line)];
        }

        /// How much taller than a body line each level is.
        fn extras(self: *const Self) [L.scales.len]f32 {
            comptime assert(sized);
            var out: [L.scales.len]f32 = undefined;
            const body = self.line_height();
            for (&out, L.scales) |*extra, scale| {
                extra.* = line_height_of(L, self.style.size * scale) - body;
            }
            return out;
        }

        /// The height of `line`.
        fn height_of_line(self: *const Self, line: u32) f32 {
            if (comptime !sized) return self.line_height();
            return line_height_of(L, self.style.size * self.scale_at(line));
        }

        /// The extra heights of the tall lines before `line`; 0 unless the language sizes lines.
        fn extra_above(self: *const Self, line: u32) f32 {
            if (comptime !sized) return 0;
            const each = self.extras();
            var sum: f32 = 0;
            for (self.buffer.tall[0..self.buffer.tall_count]) |entry| {
                if (entry.line >= line) break;
                sum += each[entry.level];
            }
            return sum;
        }

        fn device_scale(self: *const Self) f32 {
            if (comptime proportional) return self.faces.scale;
            return self.mono.scale;
        }

        fn line_walk(self: *const Self, line: u32) LineWalk(L) {
            return .{ .bytes = self.buffer.line_bytes(line), .state = self.buffer.states[line] };
        }

        fn cell_advance(self: *const Self, cell: Cell, scale: f32) f32 {
            return self.faces.advance_at(Faces.slots[cell.class], cell.codepoint, scale);
        }

        /// A space of `faces[0]`: what a gap is made of, and the column past a line's end.
        fn space_advance(self: *const Self, scale: f32) f32 {
            return self.faces.advance_at(0, ' ', scale);
        }

        /// The x of `byte` on `line`, relative to column 0 (section 2).
        pub fn x_of(self: *const Self, line: u32, byte: u32) f32 {
            const range = self.buffer.line_range(line);
            assert(byte >= range.start);
            assert(byte <= range.end);
            return self.x_of_column(line, codepoints(self.text()[range.start..byte]));
        }

        /// The x of codepoint column `column` of `line`; past its end, columns of spaces.
        fn x_of_column(self: *const Self, line: u32, column: u32) f32 {
            if (comptime !proportional) return @as(f32, @floatFromInt(column)) * self.advance();
            const pens = &self.pens;
            const scale = self.scale_at(line);
            const current = pens.revision == self.buffer.revision and pens.size == self.style.size;
            if (current and line >= pens.first and line - pens.first < pens.lines) {
                const offset = line - pens.first;
                const count = pens.counts[offset];
                if (column < count) return pens.x[offset][column];
                // A table that stopped short of `columns_max` holds the whole line.
                if (count <= columns_max) {
                    const past: f32 = @floatFromInt(column - count + 1);
                    return pens.x[offset][count - 1] + past * self.space_advance(scale);
                }
            }
            var walk = self.line_walk(line);
            var pen: f32 = 0;
            var at: u32 = 0;
            while (walk.next()) |cell| : (at += 1) {
                if (at == column) return pen;
                pen += self.cell_advance(cell, scale);
            }
            return pen + @as(f32, @floatFromInt(column - at)) * self.space_advance(scale);
        }

        /// The width of the codepoint at `byte`, or of a space at the line's end; at least 1,
        /// because `rect_of` promises a rect and a mark advances nothing.
        fn width_at(self: *const Self, line: u32, byte: u32) f32 {
            if (comptime !proportional) return self.advance();
            const range = self.buffer.line_range(line);
            const column = codepoints(self.text()[range.start..byte]);
            return @max(1, self.x_of_column(line, column + 1) - self.x_of_column(line, column));
        }

        /// The byte of `line` nearest the x `x`, relative to column 0: the walk stops at the
        /// first codepoint whose middle lies right of it, as `@round` does on the grid.
        pub fn byte_at_x(self: *const Self, line: u32, x: f32) u32 {
            comptime assert(proportional);
            const range = self.buffer.line_range(line);
            const scale = self.scale_at(line);
            var walk = self.line_walk(line);
            var pen: f32 = 0;
            while (walk.next()) |cell| {
                const width = self.cell_advance(cell, scale);
                if (pen + width * 0.5 > x) return range.start + cell.byte;
                pen += width;
            }
            return range.end;
        }

        /// Fills the pens of the visible lines, at most `columns_max` columns each.
        fn fill_pens(self: *Self, visible: *const Visible) void {
            comptime assert(proportional);
            const pens = &self.pens;
            pens.first = visible.first;
            pens.lines = visible.count;
            for (0..visible.count) |offset| {
                const line = visible.first + @as(u32, @intCast(offset));
                const scale = self.scale_at(line);
                var walk = self.line_walk(line);
                const row = &pens.x[offset];
                row[0] = 0;
                var count: u16 = 1;
                while (count <= columns_max) : (count += 1) {
                    const cell = walk.next() orelse break;
                    row[count] = row[count - 1] + self.cell_advance(cell, scale);
                }
                pens.counts[offset] = count;
            }
            pens.revision = self.buffer.revision;
            pens.size = self.style.size;
        }

        /// The widest line in pixels: a walk of the whole text, once per revision and size.
        pub fn widest_px(self: *Self) f32 {
            comptime assert(proportional);
            const pens = &self.pens;
            const current = pens.widest_revision == self.buffer.revision and
                pens.widest_size == self.style.size;
            if (current) return pens.widest;
            var most: f32 = 0;
            for (0..self.buffer.line_count) |line| {
                const scale = self.scale_at(@intCast(line));
                var walk = self.line_walk(@intCast(line));
                var pen: f32 = 0;
                while (walk.next()) |cell| pen += self.cell_advance(cell, scale);
                most = @max(most, pen);
            }
            pens.widest = most;
            pens.widest_revision = self.buffer.revision;
            pens.widest_size = self.style.size;
            pens.widest_walks += 1;
            return most;
        }

        fn caret_line(self: *const Self) u32 {
            return self.buffer.line_of(self.caret);
        }

        fn selection_now(self: *const Self) Selection {
            assert(self.caret <= self.buffer.len);
            return .{ .caret = self.caret, .anchor = self.anchor };
        }

        fn page_lines(self: *const Self) u32 {
            const lines = self.geometry.viewport.height / self.line_height();
            return @max(1, @as(u32, @intFromFloat(@max(0, @floor(lines)))));
        }

        /// The codepoint column of `byte` in its line.
        fn column_of(self: *const Self, byte: u32) u32 {
            const start = self.buffer.line_range(self.buffer.line_of(byte)).start;
            return codepoints(self.text()[start..byte]);
        }

        /// The byte at codepoint column `column` of `line`, or the line's end.
        fn byte_of_column(self: *const Self, line: u32, column: u32) u32 {
            const range = self.buffer.line_range(line);
            var byte = range.start;
            var at: u32 = 0;
            while (at < column and byte < range.end) : (at += 1) {
                byte = edit.next_boundary(self.text()[0..range.end], byte);
            }
            assert(byte <= range.end);
            return byte;
        }

        /// The caret position under the window point `(x, y)` of the last draw.
        fn byte_at(self: *const Self, x: f32, y: f32) u32 {
            const g = self.geometry;
            const line = self.line_at(y - g.viewport.y + self.view.scroll_y);
            const offset = x - g.text_left + self.scroll_x;
            if (comptime proportional) return self.byte_at_x(line, offset);
            const column = @round(offset / self.advance());
            return self.byte_of_column(line, @intFromFloat(@max(0, column)));
        }

        /// The row's line, clamped to the text: a row left behind by a shrink sits at the end.
        fn row_line(self: *const Self, index: u32) u32 {
            assert(index < self.row_count);
            return @min(self.rows[index].after_line, self.buffer.line_count - 1);
        }

        /// The content y of the top of `line` (section 2).
        fn line_top(self: *const Self, line: u32) f32 {
            assert(line < self.buffer.line_count);
            var above: f32 = 0;
            for (0..self.row_count) |index| {
                if (self.row_line(@intCast(index)) >= line) break;
                above += self.rows[index].height;
            }
            return padding_px + @as(f32, @floatFromInt(line)) * self.line_height() + above +
                self.extra_above(line);
        }

        /// The content y of the top of row `index`.
        fn row_top(self: *const Self, index: u32) f32 {
            const line = self.row_line(index);
            var above: f32 = 0;
            for (self.rows[0..index]) |row| above += row.height;
            return padding_px + @as(f32, @floatFromInt(line + 1)) * self.line_height() + above +
                self.extra_above(line + 1);
        }

        /// The line at content y `y`; a row maps to the line above it.
        fn line_at(self: *const Self, y: f32) u32 {
            const height = self.line_height();
            var above: f32 = 0;
            for (0..self.row_count) |index| {
                const row_y = self.row_top(@intCast(index));
                if (y < row_y) break;
                if (y < row_y + self.rows[index].height) return self.row_line(@intCast(index));
                above += self.rows[index].height;
            }
            const rest = y - padding_px - above;
            const extra = if (comptime sized) self.tall_walk(rest) else 0;
            if (comptime sized) {
                if (extra.line) |line| return line;
            }
            const taller = if (comptime sized) extra.above else 0;
            const lines = @floor((rest - taller) / height);
            const last: f32 = @floatFromInt(self.buffer.line_count - 1);
            return @intFromFloat(std.math.clamp(lines, 0, last));
        }

        /// Walks the tall lines at `y` past the padding and the rows above it: the tall line
        /// there, if any, and the extra heights before `y`.
        fn tall_walk(self: *const Self, y: f32) struct { line: ?u32, above: f32 } {
            comptime assert(sized);
            const each = self.extras();
            const height = self.line_height();
            var above: f32 = 0;
            for (self.buffer.tall[0..self.buffer.tall_count]) |entry| {
                const top = @as(f32, @floatFromInt(entry.line)) * height + above;
                if (y < top) break;
                if (y < top + height + each[entry.level]) return .{ .line = entry.line, .above = above };
                above += each[entry.level];
            }
            return .{ .line = null, .above = above };
        }

        /// The height of every line and row with the padding (section 2).
        pub fn content_height(self: *const Self) f32 {
            var rows: f32 = 0;
            for (self.rows[0..self.row_count]) |row| rows += row.height;
            const lines: f32 = @floatFromInt(self.buffer.line_count);
            const last = self.buffer.line_count;
            return 2 * padding_px + lines * self.line_height() + rows + self.extra_above(last);
        }

        fn scroll_x_max(self: *Self) f32 {
            const wide = if (comptime proportional)
                self.widest_px() + self.space_advance(1)
            else
                @as(f32, @floatFromInt(self.buffer.longest + 1)) * self.advance();
            return @max(0, wide - self.geometry.text_width);
        }

        // --------------------------------------------------------------------- draw

        /// Draws the editor in the view `walk` places, all of it except inline rows (section 6).
        pub fn draw(self: *Self, cx: anytype, walk: ui.Walk) void {
            self.draw_begin(cx, walk);
            while (self.next_row(cx)) |slot| _ = cx.walk(slot.walk);
            self.draw_end(cx);
        }

        /// Opens the view and draws the lines, selection, decorations, and caret.
        pub fn draw_begin(self: *Self, cx: anytype, walk: ui.Walk) void {
            assert(!self.pass.open);
            self.check_rows();
            // The view clamps the offset with the content height before it draws, so it gets
            // this frame's height, not the one measured before an edit or a load.
            self.view.content_h = self.content_height();
            const port = cx.begin_view(self.view_id(), walk, ui.flow_of(.down), &self.view);
            self.pass = .{ .open = true, .empty = true, .next_row = 0 };
            // The grid draws the gutter's numbers whatever the text is set in.
            const drawing = cx.drawing();
            if (!proportional or self.style.gutter) self.mono.prepare(drawing, self.style.size);
            if (comptime proportional) self.faces.prepare(drawing, self.style.size);
            const digits = @max(3, digit_count(self.buffer.line_count));
            const columns: f32 = @floatFromInt(digits + 2);
            const gutter = if (self.style.gutter) columns * self.advance() else 0;
            self.geometry = .{
                .viewport = port,
                .text_left = port.x + gutter + self.lead(),
                .text_width = @max(0, port.width - gutter - self.lead() - view.gutter_px),
                .gutter_width = gutter,
                .drawn = true,
            };
            self.view.content_h = self.content_height();
            self.view.scroll_y = std.math.clamp(self.view.scroll_y, 0, self.view.max_scroll());
            self.scroll_x = std.math.clamp(self.scroll_x, 0, self.scroll_x_max());
            const clip = cx.clip() orelse return;
            if (!(port.width > 0) or !(port.height > 0)) return;
            self.pass.empty = false;
            // A view with no height to scroll drops the wheel, and `dx` still needs it.
            var own = flags;
            own.wheel = self.scroll_x_max() > 0;
            cx.area(self.id, port, 0, own);
            var visible: Visible = undefined;
            self.visible_lines(&visible);
            if (comptime proportional) self.fill_pens(&visible);
            self.draw_faces(cx, clip, &visible, cx.focused(self.id));
            self.draw_decorations(cx, clip, &visible, false);
            const glyphs = self.draw_text(cx, clip, &visible);
            assert(glyphs <= glyph_bound_of(L, port.width, port.height, self.style.size));
            const previous = cx.drawing().layer(over_layer);
            self.draw_decorations(cx, clip, &visible, true);
            if (cx.focused(self.id)) self.draw_caret(cx, clip, &visible);
            _ = cx.drawing().layer(previous);
            assert(self.pass.open);
        }

        /// The next visible inline row, with the view's turtle skipped to its top, or null.
        pub fn next_row(self: *Self, cx: anytype) ?RowSlot {
            assert(self.pass.open);
            const g = self.geometry;
            while (self.pass.next_row < self.row_count) {
                const index = self.pass.next_row;
                self.pass.next_row += 1;
                if (self.pass.empty) continue;
                const top = g.viewport.y - self.view.scroll_y + self.row_top(index);
                const height = self.rows[index].height;
                if (top + height <= g.viewport.y) continue;
                if (top >= g.viewport.y + g.viewport.height) continue;
                const span = top - cx.remaining().y;
                assert(span > -0.01);
                cx.skip(@max(0, span));
                // From the gutter's right edge to the thumb's gutter, like the text clip.
                const width = g.text_width + self.lead();
                var walk = ui.sized(.{ .fixed = width }, .{ .fixed = height });
                walk.margin.left = g.gutter_width;
                return .{ .index = index, .walk = walk, .rect = cx.peek(walk) };
            }
            return null;
        }

        /// Skips the turtle to the end of the content and closes the view.
        pub fn draw_end(self: *Self, cx: anytype) void {
            assert(self.pass.open);
            const g = self.geometry;
            const end = g.viewport.y - self.view.scroll_y + self.content_height();
            const span = end - cx.remaining().y;
            assert(span > -0.01);
            cx.skip(@max(0, span));
            cx.end_view();
            self.pass.open = false;
            assert(!self.pass.open);
        }

        fn check_rows(self: *const Self) void {
            assert(self.row_count <= row_cap);
            assert(self.decoration_count <= decoration_cap);
            for (self.rows[0..self.row_count], 0..) |row, index| {
                assert(row.height > 0);
                assert(row.height <= row_height_max);
                if (index > 0) assert(self.rows[index - 1].after_line <= row.after_line);
            }
        }

        /// The lines that overlap the viewport, at most `lines_max`, with their window tops.
        fn visible_lines(self: *const Self, visible: *Visible) void {
            const g = self.geometry;
            const first = self.line_at(self.view.scroll_y);
            var top = g.viewport.y - self.view.scroll_y + self.line_top(first);
            var row: u32 = 0;
            while (row < self.row_count and self.row_line(row) < first) row += 1;
            visible.first = first;
            visible.count = 0;
            var line = first;
            while (line < self.buffer.line_count and visible.count < lines_max) : (line += 1) {
                if (top >= g.viewport.y + g.viewport.height) break;
                visible.tops[visible.count] = top;
                visible.count += 1;
                top += self.height_of_line(line);
                while (row < self.row_count and self.row_line(row) == line) : (row += 1) {
                    top += self.rows[row].height;
                }
            }
            assert(visible.count <= lines_max);
        }

        /// Faces, the current line, and the selection bands, on the base layer.
        fn draw_faces(
            self: *Self,
            cx: anytype,
            clip: Clip,
            visible: *const Visible,
            focused: bool,
        ) void {
            const g = self.geometry;
            const palette = &self.style.palette;
            const gutter: Rect = .{
                .x = g.viewport.x,
                .y = g.viewport.y,
                .width = g.gutter_width,
                .height = g.viewport.height,
            };
            push_box(cx, g.viewport, clip, palette.background);
            if (self.style.gutter) push_box(cx, gutter, clip, palette.gutter);
            const text_clip = self.clip_text(clip) orelse return;
            const range = self.selection();
            const current = self.caret_line();
            for (0..visible.count) |offset| {
                const line = visible.first + @as(u32, @intCast(offset));
                const top = visible.tops[offset];
                if (focused and line == current and range.start == range.end) {
                    const band: Rect = .{
                        .x = g.text_left,
                        .y = top,
                        .width = g.text_width,
                        .height = self.height_of_line(line),
                    };
                    push_box(cx, band, text_clip, palette.current_line);
                }
                const span = self.line_span(line, range.start, range.end, true) orelse continue;
                push_box(cx, self.span_rect(line, span, top), text_clip, palette.selection);
            }
        }

        /// The columns `[0]` to `[1]` of the part of bytes `start .. end` on `line`; with
        /// `newline`, a selection that continues past the line end covers one more column.
        fn line_span(self: *const Self, line: u32, start: u32, end: u32, newline: bool) ?[2]u32 {
            const range = self.buffer.line_range(line);
            if (end <= start) return null;
            if (end < range.start) return null;
            if (start > range.end) return null;
            const bytes = self.text();
            const first = if (start > range.start) codepoints(bytes[range.start..start]) else 0;
            var last = codepoints(bytes[range.start..@min(end, range.end)]);
            if (newline and end > range.end) last += 1;
            if (last <= first) return null;
            return .{ first, last };
        }

        fn span_rect(self: *const Self, line: u32, columns: [2]u32, top: f32) Rect {
            assert(columns[1] > columns[0]);
            const x0 = self.geometry.text_left - self.scroll_x;
            if (comptime proportional) {
                const left = self.x_of_column(line, columns[0]);
                return .{
                    .x = x0 + left,
                    .y = top,
                    .width = self.x_of_column(line, columns[1]) - left,
                    .height = self.height_of_line(line),
                };
            }
            const first: f32 = @floatFromInt(columns[0]);
            const count: f32 = @floatFromInt(columns[1] - columns[0]);
            return .{
                .x = x0 + first * self.advance(),
                .y = top,
                .width = count * self.advance(),
                .height = self.line_height(),
            };
        }

        fn clip_text(self: *const Self, clip: Clip) ?Clip {
            const g = self.geometry;
            if (!(g.text_width > 0)) return null;
            const area: Rect = .{
                .x = g.viewport.x + g.gutter_width,
                .y = g.viewport.y,
                .width = g.text_width + self.lead(),
                .height = g.viewport.height,
            };
            return ui.cx.intersect(clip, area);
        }

        /// The decorations of one layer: box and error under the text, strike over it.
        fn draw_decorations(
            self: *Self,
            cx: anytype,
            clip: Clip,
            visible: *const Visible,
            over: bool,
        ) void {
            if (visible.count == 0) return;
            const text_clip = self.clip_text(clip) orelse return;
            const first_byte = self.buffer.line_range(visible.first).start;
            const last_line = visible.first + visible.count - 1;
            const last_byte = self.buffer.line_range(last_line).end;
            for (self.decorations[0..self.decoration_count]) |decoration| {
                assert(decoration.start <= decoration.end);
                if ((decoration.kind == .strike) != over) continue;
                if (decoration.end < first_byte or decoration.start > last_byte) continue;
                if (decoration.end > self.buffer.len) continue;
                const from = @max(visible.first, self.buffer.line_of(decoration.start));
                const to = @min(last_line, self.buffer.line_of(decoration.end));
                var line = from;
                while (line <= to) : (line += 1) {
                    const found = self.line_span(line, decoration.start, decoration.end, false);
                    const span = found orelse continue;
                    const rect = self.span_rect(line, span, visible.tops[line - visible.first]);
                    self.draw_decoration(cx, decoration.kind, rect, text_clip);
                }
            }
        }

        fn draw_decoration(
            self: *const Self,
            cx: anytype,
            kind: Decoration.Kind,
            rect: Rect,
            clip: Clip,
        ) void {
            const palette = &self.style.palette;
            switch (kind) {
                .box => {
                    const framed: Rect = .{
                        .x = rect.x - 1,
                        .y = rect.y + 1,
                        .width = rect.width + 2,
                        .height = rect.height - 2,
                    };
                    append_box(cx, framed, clip, .{ 0, 0, 0, 0 }, palette.box, 1, 3);
                },
                .strike => {
                    const bar: Rect = .{
                        .x = rect.x,
                        .y = rect.y + rect.height * 0.5 - 1,
                        .width = rect.width,
                        .height = 2,
                    };
                    push_box(cx, bar, clip, palette.strike);
                },
                .@"error" => {
                    push_box(cx, rect, clip, palette.error_fill);
                    const line: Rect = .{
                        .x = rect.x,
                        .y = rect.y + rect.height - 2,
                        .width = rect.width,
                        .height = 2,
                    };
                    push_box(cx, line, clip, palette.error_line);
                },
            }
        }

        /// Gutter numbers and the coloured glyphs of every visible line. Returns the glyphs
        /// emitted, which `glyph_bound` bounds.
        fn draw_text(self: *Self, cx: anytype, clip: Clip, visible: *const Visible) u32 {
            const g = self.geometry;
            const gutter_area: Rect = .{
                .x = g.viewport.x,
                .y = g.viewport.y,
                .width = g.gutter_width,
                .height = g.viewport.height,
            };
            const gutter_clip = if (self.style.gutter)
                ui.cx.intersect(clip, gutter_area)
            else
                null;
            const text_clip = self.clip_text(clip);
            const current = self.caret_line();
            const palette = &self.style.palette;
            var emitted: u32 = 0;
            for (0..visible.count) |offset| {
                const line = visible.first + @as(u32, @intCast(offset));
                const baseline = self.baseline_of(line, visible.tops[offset]);
                if (gutter_clip) |numbers| {
                    const now = line == current;
                    const color = if (now) palette.gutter_current else palette.gutter_text;
                    const paint: mono_grid.Paint = .{ .clip = numbers, .color = color };
                    emitted += self.draw_number(cx, line + 1, baseline, paint);
                }
                if (text_clip) |cells| {
                    const job: LineJob(L) = .{
                        .bytes = self.buffer.line_bytes(line),
                        .state = self.buffer.states[line],
                        .left = g.text_left - self.scroll_x,
                        .baseline_px = baseline,
                        .scale = self.scale_at(line),
                        .clip = cells,
                        .palette = &palette.classes,
                    };
                    emitted += if (comptime proportional)
                        emit_line_faces(L, &self.faces, cx.drawing(), job)
                    else
                        emit_line(L, &self.mono, cx.drawing(), job);
                }
            }
            return emitted;
        }

        fn draw_number(
            self: *const Self,
            cx: anytype,
            number: u32,
            baseline: f32,
            paint: mono_grid.Paint,
        ) u32 {
            assert(number >= 1);
            var digits: [digits_max]u8 = undefined;
            const printed = std.fmt.bufPrint(&digits, "{d}", .{number}) catch unreachable;
            const right = self.geometry.viewport.x + self.geometry.gutter_width - self.advance();
            var x = right - @as(f32, @floatFromInt(printed.len)) * self.advance();
            for (printed) |digit| {
                self.mono.emit(cx.drawing(), digit, x, baseline, paint);
                x += self.advance();
            }
            assert(printed.len <= digits_max);
            return @intCast(printed.len);
        }

        fn draw_caret(self: *const Self, cx: anytype, clip: Clip, visible: *const Visible) void {
            const line = self.caret_line();
            if (line < visible.first or line >= visible.first + visible.count) return;
            const text_clip = self.clip_text(clip) orelse return;
            const scale = self.device_scale();
            const x = self.geometry.text_left - self.scroll_x + self.x_of(line, self.caret);
            const caret: Rect = .{
                .x = @round(x * scale) / scale - 1 / scale,
                .y = visible.tops[line - visible.first],
                .width = caret_px / scale,
                .height = self.height_of_line(line),
            };
            push_box(cx, caret, text_clip, self.style.palette.caret);
        }
    };
}

/// The patch language's editor, the default.
pub const Editor = EditorOf(tokenizer);

/// One line of glyphs for `emit_line`, in language `L`.
fn LineJob(comptime L: type) type {
    return struct {
        bytes: []const u8,
        state: L.State,
        /// Window x of column 0.
        left: f32,
        baseline_px: f32,
        /// The line's scale; 1 but for a sized language's tall lines.
        scale: f32 = 1,
        clip: Clip,
        palette: *const [language.class_count(L)][4]f32,
    };
}

/// The hot loop: tokenize one line and emit each codepoint of each token in its class
/// colour, skipping columns left of the clip and stopping right of it or at `columns_max`.
/// Returns the glyphs emitted.
fn emit_line(comptime L: type, grid: *const mono_grid.Mono, cx: anytype, job: LineJob(L)) u32 {
    assert(job.clip.x1 > job.clip.x0);
    const advance = grid.advance;
    var state = job.state;
    var at: u32 = 0;
    var column: u32 = 0;
    var position: u32 = 0;
    var emitted: u32 = 0;
    while (L.next(job.bytes, &at, &state)) |token| {
        // Separators are ASCII spaces: one column per byte (`language.zig`, section 2).
        assert(token.start >= position);
        if (std.debug.runtime_safety) {
            for (job.bytes[position..token.start]) |byte| assert(byte == ' ');
        }
        column += token.start - position;
        position = token.end;
        const paint: mono_grid.Paint = .{
            .clip = job.clip,
            .color = job.palette[@backingInt(token.class)],
        };
        var index = token.start;
        while (index < token.end) : (column += 1) {
            const codepoint = layout.decode(job.bytes, &index);
            const x = job.left + @as(f32, @floatFromInt(column)) * advance;
            if (x >= job.clip.x1) return emitted;
            if (x + 2 * advance <= job.clip.x0) continue;
            grid.emit(cx, codepoint, x, job.baseline_px, paint);
            emitted += 1;
            if (emitted == columns_max) return emitted;
        }
    }
    return emitted;
}

/// `emit_line` in proportional faces: each token's class picks its slot and the pen is a sum of
/// advances. Gaps advance and draw nothing. The slop left of the clip is `2 * size`, for wide
/// glyphs and italic overhang. Returns the glyphs emitted.
fn emit_line_faces(comptime L: type, faces: *const FacesOf(L), cx: anytype, job: LineJob(L)) u32 {
    assert(job.clip.x1 > job.clip.x0);
    const slop = 2 * faces.size * job.scale;
    var walk: LineWalk(L) = .{ .bytes = job.bytes, .state = job.state };
    var pen = job.left;
    var emitted: u32 = 0;
    while (walk.next()) |cell| {
        const slot = FacesOf(L).slots[cell.class];
        const x = pen;
        pen += faces.advance_at(slot, cell.codepoint, job.scale);
        if (x >= job.clip.x1) return emitted;
        if (cell.gap or x + slop <= job.clip.x0) continue;
        const paint: mono_grid.Paint = .{ .clip = job.clip, .color = job.palette[cell.class] };
        faces.emit_at(cx, slot, cell.codepoint, x, job.baseline_px, job.scale, paint);
        emitted += 1;
        if (emitted == columns_max) return emitted;
    }
    return emitted;
}

/// Maps `byte` through replacing `range` with bytes ending at `end`: after the range it
/// moves by the length change, inside it lands at `end`.
fn map_through(byte: u32, range: Range, end: u32) u32 {
    if (byte >= range.end) return byte - range.end + end;
    if (byte > range.start) return end;
    return byte;
}

fn codepoints(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

fn digit_count(number: u32) u32 {
    var digits: u32 = 1;
    var rest = number / 10;
    while (rest > 0) : (rest /= 10) digits += 1;
    assert(digits <= 10);
    return digits;
}

fn push_box(cx: anytype, rect: Rect, clip: Clip, fill: [4]f32) void {
    append_box(cx, rect, clip, fill, draw.transparent, 0, 0);
}

fn append_box(
    cx: anytype,
    rect: Rect,
    clip: Clip,
    fill: [4]f32,
    border_color: [4]f32,
    border_width: f32,
    radius: f32,
) void {
    if (!(rect.width > 0)) return;
    if (!(rect.height > 0)) return;
    const look: draw.BoxLook = .{
        .fill = fill,
        .border_color = border_color,
        .border_width = border_width,
        .radius = radius,
    };
    cx.append(draw.Box, null, .of(rect, clip, look)) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

comptime {
    // 128 lines of 21 px cover 2,688 logical pixels: a 2160 px monitor at scale 1 fills.
    assert(glyph_max == 26_112);
    assert(lines_max * 21 >= 2160);
    assert(digit_count(buffer_module.line_cap) <= digits_max);
    assert(row_cap * row_height_max <= 65536);
}

const testing = std.testing;

const test_draw = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 1024 },
    .{ .type = draw.Glyph, .cap = glyph_max },
};

const TestContext = ui.Context(draw.Context(&test_draw, 16, 0), 16);

/// The test editor and context: static, like an app's, so 300 KiB stay off the stack.
const fixture = struct {
    var context: TestContext = undefined;
    var editor: Editor = undefined;
};

const test_id = ui.id("editor", 0);

fn test_fresh(utf8: []const u8) *Editor {
    fixture.context.init();
    fixture.editor.init(test_id, Editor.default_style);
    const loaded = fixture.editor.load(utf8);
    assert(loaded);
    return &fixture.editor;
}

fn test_frame(width: u32, height: u32) *TestContext {
    const context = &fixture.context;
    context.begin_frame(width, height, 120);
    fixture.editor.draw(context, ui.sized(.fill, .fill));
    _ = context.end_frame();
    return context;
}

fn test_send(event: input.Event) Action {
    const context = &fixture.context;
    context.event_begin(event);
    const action = fixture.editor.handle(context, event);
    context.event_end();
    return action;
}

fn test_key(name: input.Key, mods: input.Mods) Action {
    return test_send(.{ .key_down = input.key_press(name, mods, false, "") });
}

fn test_typed(bytes: []const u8) void {
    for (bytes) |byte| {
        const action = test_send(.{ .key_down = input.key_press(.other, .none, false, &.{byte}) });
        assert(action == .changed);
    }
}

fn test_press(x: f32, y: f32, down: bool) void {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = .left, .mods = .none };
    _ = test_send(if (down) .{ .pointer_down = sample } else .{ .pointer_up = sample });
}

fn test_focus_at(x: f32, y: f32) void {
    test_press(x, y, true);
    test_press(x, y, false);
}

const mods_ctrl: input.Mods = .{ .shift = false, .ctrl = true, .alt = false, .meta = false };
const mods_shift: input.Mods = .{ .shift = true, .ctrl = false, .alt = false, .meta = false };
const mods_ctrl_shift: input.Mods = .{ .shift = true, .ctrl = true, .alt = false, .meta = false };

/// A two-class test language: a run starting with a digit is a number, any other a word.
const Duo = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { word, number };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 0, 0, 1 } };

    pub fn next(line: []const u8, at: *u32, state: *State) ?language.Token(Class) {
        assert(state.* == .normal);
        var index = at.*;
        while (index < line.len and line[index] == ' ') index += 1;
        at.* = index;
        if (index == line.len) return null;
        const start = index;
        const digit = std.ascii.isDigit(line[start]);
        while (index < line.len and line[index] != ' ') index += 1;
        at.* = index;
        return .{ .start = start, .end = index, .class = if (digit) .number else .word };
    }
};

const duo_fixture = struct {
    var editor: EditorOf(Duo) = undefined;
};

// Locks the seam: an editor of a test language draws "ab 12 c3" with its own palette: the
// gutter's "1" first (the caret's line), then a and b in the word colour, 1 and 2 in the
// number colour, and c and 3 in the word colour; its buffer keeps the language's states.
test "an editor of another language colours tokens with its palette" {
    fixture.context.init();
    const editor = &duo_fixture.editor;
    editor.init(test_id, EditorOf(Duo).default_style);
    try testing.expect(editor.load("ab 12 c3"));
    const context = &fixture.context;
    context.begin_frame(400, 100, 120);
    editor.draw(context, ui.sized(.fill, .fill));
    _ = context.end_frame();
    const glyphs = context.draw.items(draw.Glyph);
    try testing.expectEqual(@as(usize, 7), glyphs.len);
    try testing.expectEqual(EditorOf(Duo).default_palette.gutter_current, glyphs[0].color);
    const colours = [_]Duo.Class{ .word, .word, .number, .number, .word, .word };
    for (colours, glyphs[1..]) |class, glyph| {
        try testing.expectEqual(Duo.palette[@backingInt(class)], glyph.color);
    }
    try testing.expectEqual(Duo.State.normal, editor.buffer.states[0]);
    try testing.expectEqual(@as(usize, 2), editor.style.palette.classes.len);
}

// Locks the light palette: a language without `palette_light` keeps its class colours over
// the light chrome, the patch language takes its own light colours, and both share the
// light background, which is lighter than the dark one.
test "light palettes take palette_light or fall back to palette" {
    const duo = EditorOf(Duo).light_palette;
    try testing.expectEqual(Duo.palette, duo.classes);
    try testing.expectEqual(tokenizer.palette_light, Editor.light_palette.classes);
    try testing.expectEqual(duo.background, Editor.light_palette.background);
    try testing.expect(duo.background[0] > Editor.default_palette.background[0]);
    try testing.expectEqual(Editor.light_palette, Editor.light_style.palette);
}

// Locks the viewport bounds at 15 px (a 9 px column, a 21 px line): 800 x 600 is 30 lines of
// 91 columns and 4 digits, an empty viewport 2 lines of 3, and a huge one `glyph_max`; all
// at compile time. Then draws over a grid of viewports and scroll offsets of a dense text
// with long lines, where `draw` asserts its glyphs against the bound.
test "glyph_bound bounds every draw" {
    try testing.expectEqual(@as(u32, 30), comptime lines_bound(600, 15));
    try testing.expectEqual(@as(u32, 30 * 95), comptime glyph_bound(800, 600, 15));
    try testing.expectEqual(@as(u32, 2 * 7), comptime glyph_bound(0, 0, 15));
    try testing.expectEqual(glyph_max, comptime glyph_bound(1e6, 1e6, 15));
    try testing.expectEqual(lines_max, comptime lines_bound(1e9, 15));
    const long: [300]u8 = @splat('x');
    var source: [buffer_module.buffer_cap]u8 = undefined;
    var length: u32 = 0;
    var line: u32 = 0;
    while (line < 150) : (line += 1) {
        const written = std.fmt.bufPrint(source[length..], "{d} {s}\n", .{
            line,
            &long,
        }) catch unreachable;
        length += @intCast(written.len);
    }
    const editor = test_fresh(source[0..length]);
    var width: u32 = 40;
    while (width <= 1240) : (width += 75) {
        var height: u32 = 30;
        while (height <= 900) : (height += 87) {
            editor.view.scroll_y = @floatFromInt(height * 7 % 4000);
            editor.scroll_x = @floatFromInt(width * 3 % 1700);
            const context = test_frame(width, height);
            const glyphs: u32 = @intCast(context.draw.items(draw.Glyph).len);
            const bound = glyph_bound(@floatFromInt(width), @floatFromInt(height), 15);
            try testing.expect(glyphs <= bound);
            try testing.expect(glyphs > 0);
        }
    }
}

// Locks the geometry of section 2 at 15 px: the gutter is five 9 px columns, column 0 sits
// half a column further, line `i` starts at 4 + 21 i, a 30 px row after line 0 pushes later
// lines down, and scrolling moves the rect by the offsets.
test "rect_of follows the grid, rows, and scroll" {
    const editor = test_fresh("ab\ncd\nxyz\u{e4}q\n");
    _ = test_frame(800, 600);
    try testing.expectEqual(Rect{ .x = 49.5, .y = 4, .width = 9, .height = 21 }, editor.rect_of(0));
    const at = editor.rect_of(6 + 4);
    try testing.expectEqual(@as(f32, 49.5 + 4 * 9), at.x);
    try testing.expectEqual(@as(f32, 4 + 2 * 21), at.y);
    try testing.expectEqual(@as(f32, 49.5 + 5 * 9), editor.rect_of(6 + 6).x);
    editor.rows[0] = .{ .after_line = 0, .height = 30 };
    editor.row_count = 1;
    _ = test_frame(800, 600);
    try testing.expectEqual(@as(f32, 4 + 2 * 21 + 30), editor.rect_of(6).y);
    try testing.expectEqual(@as(f32, 4), editor.rect_of(1).y);
    try testing.expectEqual(@as(f32, 2 * 4 + 4 * 21 + 30), editor.view.content_h);
    editor.scroll_x = 5;
    editor.view.scroll_y = 0;
    try testing.expectEqual(@as(f32, 49.5 - 5), editor.rect_of(0).x);
}

// Locks the visible-only draw: a 2,000-line buffer scrolled to its middle in an 800 by 600
// window draws only the 30 lines the viewport overlaps (lines 999 to 1028: 19 inked cells
// and a four-digit number each), every glyph inside the viewport rows, and the view measures
// all 2,001 lines (the text ends with an LF).
test "a 2,000-line buffer emits glyphs only for visible lines" {
    var source: [buffer_module.buffer_cap]u8 = undefined;
    var length: u32 = 0;
    var line: u32 = 0;
    while (line < 2000) : (line += 1) {
        const written = std.fmt.bufPrint(source[length..], "row{d:0>4} := k(0~0.5~1)\n", .{line});
        length += @intCast((written catch unreachable).len);
    }
    const editor = test_fresh(source[0..length]);
    try testing.expectEqual(@as(u32, 2001), editor.buffer.line_count);
    _ = test_frame(800, 600);
    editor.view.scroll_y = 1000 * 21;
    const context = test_frame(800, 600);
    try testing.expectEqual(@as(f32, 2 * 4 + 2001 * 21), editor.view.content_h);
    const glyphs = context.draw.items(draw.Glyph);
    try testing.expectEqual(@as(usize, 30 * (19 + 4)), glyphs.len);
    for (glyphs) |glyph| {
        try testing.expect(glyph.rect[1] > -21);
        try testing.expect(glyph.rect[1] < 600 + 21);
    }
    try testing.expectEqual(@as(u32, 0), context.draw.overflow_count);
}

// Locks coalescing through keys: typing "hello world" is two entries ("hello " and
// "world"), so the first undo leaves "hello " with the caret after it; a Backspace run is
// one entry; redo is Ctrl+Shift+Z.
test "typing coalesces per word and undoes word by word" {
    const editor = test_fresh("");
    _ = test_frame(800, 600);
    test_focus_at(100, 10);
    test_typed("hello world");
    try testing.expectEqualStrings("hello world", editor.text());
    try testing.expectEqual(@as(u32, 2), editor.buffer.entry_count);
    try testing.expectEqual(Action.changed, test_key(.z, mods_ctrl));
    try testing.expectEqualStrings("hello ", editor.text());
    try testing.expectEqual(@as(u32, 6), editor.caret);
    try testing.expectEqual(Action.changed, test_key(.z, mods_ctrl_shift));
    try testing.expectEqualStrings("hello world", editor.text());
    _ = test_key(.backspace, .none);
    _ = test_key(.backspace, .none);
    _ = test_key(.backspace, .none);
    try testing.expectEqualStrings("hello wo", editor.text());
    _ = test_key(.z, mods_ctrl);
    try testing.expectEqualStrings("hello world", editor.text());
}

// Locks selection: Shift+arrows extend, a double press selects a word, a triple press the
// line with its LF, Ctrl+A everything, and Ctrl+C copies the selected bytes.
test "selection by keys and clicks" {
    const editor = test_fresh("let gain := 0.5\nout = gain\n");
    _ = test_frame(800, 600);
    test_focus_at(49.5 + 5 * 9, 10);
    try testing.expectEqual(@as(u32, 5), editor.caret);
    _ = test_key(.right, mods_shift);
    _ = test_key(.right, mods_shift);
    try testing.expectEqual(Range{ .start = 5, .end = 7 }, editor.selection());
    const context = &fixture.context;
    context.clicks = .{ .count = 1, .time_ms = 0, .x = 49.5 + 5 * 9, .y = 10, .button = .left };
    test_press(49.5 + 5 * 9, 10, true);
    test_press(49.5 + 5 * 9, 10, false);
    try testing.expectEqual(Range{ .start = 4, .end = 8 }, editor.selection());
    test_press(49.5 + 5 * 9, 10, true);
    test_press(49.5 + 5 * 9, 10, false);
    try testing.expectEqual(Range{ .start = 0, .end = 16 }, editor.selection());
    _ = test_key(.a, mods_ctrl);
    _ = test_key(.c, mods_ctrl);
    try testing.expectEqualStrings(editor.text(), context.copied());
}

// Locks Tab: spaces to the next stop without a multi-line selection, an indent of every
// selected line as one undo entry, Shift+Tab outdenting up to four spaces, and Enter copying
// the leading spaces; Tab keeps focus because the area is flagged `tab`.
test "tab indents, shift tab outdents, enter keeps the indent" {
    const editor = test_fresh("a\n  b\nc");
    _ = test_frame(800, 600);
    test_focus_at(49.5 + 1 * 9, 10);
    _ = test_key(.tab, .none);
    try testing.expectEqualStrings("a   \n  b\nc", editor.text());
    try testing.expect(fixture.context.focused(test_id));
    _ = test_key(.a, mods_ctrl);
    const entries = editor.buffer.entry_count;
    _ = test_key(.tab, .none);
    try testing.expectEqualStrings("    a   \n      b\n    c", editor.text());
    try testing.expectEqual(entries + 1, editor.buffer.entry_count);
    _ = test_key(.tab, mods_shift);
    _ = test_key(.tab, mods_shift);
    try testing.expectEqualStrings("a   \nb\nc", editor.text());
    _ = test_key(.z, mods_ctrl);
    _ = test_key(.z, mods_ctrl);
    try testing.expectEqualStrings("    a   \n      b\n    c", editor.text());
    _ = test_key(.z, mods_ctrl);
    try testing.expectEqualStrings("a   \n  b\nc", editor.text());
    editor.caret = 8;
    editor.anchor = 8;
    _ = test_key(.enter, .none);
    try testing.expectEqualStrings("a   \n  b\n  \nc", editor.text());
    try testing.expectEqual(@as(u32, 11), editor.caret);
}

// Locks vertical movement: Up and Down keep the goal column across a short line, Page Down
// moves by the visible lines, Ctrl+End reaches the end, and the view follows the caret.
test "vertical moves keep the goal column and the view follows" {
    var source: [4096]u8 = undefined;
    var length: u32 = 0;
    var line: u32 = 0;
    while (line < 100) : (line += 1) {
        const piece = if (line == 1) "x\n" else "abcdefgh\n";
        @memcpy(source[length..][0..piece.len], piece);
        length += @intCast(piece.len);
    }
    const editor = test_fresh(source[0..length]);
    _ = test_frame(800, 212);
    test_focus_at(49.5 + 6 * 9, 10);
    _ = test_key(.down, .none);
    try testing.expectEqual(@as(u32, 9 + 1), editor.caret);
    _ = test_key(.down, .none);
    try testing.expectEqual(@as(u32, 11 + 6), editor.caret);
    _ = test_key(.page_down, .none);
    // 212 / 21 is ten lines: from line 2 to line 12, still at column 6.
    try testing.expectEqual(editor.buffer.line_range(12).start + 6, editor.caret);
    try testing.expect(editor.view.scroll_y > 0);
    _ = test_key(.end, mods_ctrl);
    try testing.expectEqual(editor.buffer.len, editor.caret);
    try testing.expectEqual(editor.view.max_scroll(), editor.view.scroll_y);
}

// Locks refusals and paste: a paste is sanitized (CR LF to LF, tab to spaces at its column),
// a paste that would pass 64 KiB is refused with nothing changed, and the source and cap are
// reported for the app to show.
test "a paste over the cap is refused and reported" {
    const editor = test_fresh("ab");
    _ = test_frame(800, 600);
    test_focus_at(49.5 + 2 * 9, 10);
    try testing.expectEqual(Action.changed, test_send(.{ .paste = "\tx\r\ny" }));
    try testing.expectEqualStrings("ab  x\ny", editor.text());
    const big: [buffer_module.buffer_cap]u8 = @splat('z');
    try testing.expectEqual(Action.refused, test_send(.{ .paste = &big }));
    try testing.expectEqual(Source.paste, editor.refused_source);
    try testing.expectEqual(buffer_module.Refusal.bytes, editor.refusal);
    try testing.expectEqualStrings("ab  x\ny", editor.text());
}

// Locks the public undo: it takes back an edit with no focus on the editor, redo restores it, and
// with nothing to take back the action is `none`.
test "undo and redo work without focus" {
    const editor = test_fresh("ab");
    _ = test_frame(400, 300);
    try testing.expect(editor.replace(.{ .start = 2, .end = 2 }, "c"));
    const context = &fixture.context;
    const event: input.Event = .{ .key_down = input.key_press(.z, mods_ctrl, false, "") };
    context.event_begin(event);
    try testing.expectEqual(Action.changed, editor.undo(context));
    try testing.expectEqualStrings("ab", editor.text());
    try testing.expectEqual(Action.none, editor.undo(context));
    try testing.expectEqual(Action.changed, editor.redo(context));
    try testing.expectEqualStrings("abc", editor.text());
    context.event_end();
}

// Locks `replace_keeping`: the caret lands where the caller says instead of at the end of the
// replaced range, and undo and redo restore both selections.
test "replace_keeping keeps the caller's selection through undo and redo" {
    const editor = test_fresh("ab cd");
    editor.caret = 1;
    editor.anchor = 1;
    try testing.expect(editor.replace_keeping(.{ .start = 0, .end = 5 }, "cd ab", .{ .caret = 4, .anchor = 4 }));
    try testing.expectEqualStrings("cd ab", editor.text());
    try testing.expectEqual(@as(u32, 4), editor.caret);
    _ = test_frame(400, 300);
    test_focus_at(300, 200);
    editor.caret = 4;
    editor.anchor = 4;
    _ = test_key(.z, mods_ctrl);
    try testing.expectEqualStrings("ab cd", editor.text());
    try testing.expectEqual(@as(u32, 1), editor.caret);
    _ = test_key(.y, mods_ctrl);
    try testing.expectEqual(@as(u32, 4), editor.caret);
}

// Locks scrolling input: the wheel's dy scrolls the view, its dx (or dy with Shift) scrolls
// horizontally up to the longest line, and the programmatic replace keeps the caret after the
// replaced range in place relative to the text.
test "wheels scroll both ways and replace keeps the caret" {
    var long: [400]u8 = @splat('w');
    long[399] = '\n';
    const editor = test_fresh(&long);
    _ = test_frame(400, 300);
    _ = test_send(.{ .wheel = .{ .x = 100, .y = 100, .dx = 50, .dy = 0 } });
    try testing.expectEqual(@as(f32, 50), editor.scroll_x);
    _ = test_send(.{ .wheel = .{ .x = 100, .y = 100, .dx = 1e6, .dy = 0 } });
    const width = editor.geometry.text_width;
    try testing.expectEqual(@as(f32, 400 * 9) - width, editor.scroll_x);
    editor.caret = 10;
    editor.anchor = 10;
    try testing.expect(editor.replace(.{ .start = 2, .end = 4 }, "abc"));
    try testing.expectEqual(@as(u32, 11), editor.caret);
    try testing.expectEqual(@as(u32, 1), editor.buffer.entry_count);
}

// Locks `Style.gutter` off: no gutter box and no numbers, column 0 at the viewport's left plus
// `padding_px`, and an inline row from the viewport's left edge, its width the text clip's.
test "an editor without a gutter starts at the padding" {
    const editor = test_fresh("ab\ncd\n");
    editor.style.gutter = false;
    editor.rows[0] = .{ .after_line = 0, .height = 40 };
    editor.row_count = 1;
    const context = &fixture.context;
    context.begin_frame(800, 600, 120);
    editor.draw_begin(context, ui.sized(.fill, .fill));
    const slot = editor.next_row(context).?;
    try testing.expectEqual(@as(f32, 0), slot.rect.x);
    try testing.expectEqual(@as(f32, 800 - 16), slot.rect.width);
    editor.draw_end(context);
    _ = context.end_frame();
    try testing.expectEqual(@as(f32, padding_px), editor.rect_of(0).x);
    try testing.expectEqual(@as(usize, 4), context.draw.items(draw.Glyph).len);
    try testing.expectEqual(@as(f32, 0), editor.geometry.gutter_width);
}

// Locks the wheel of a text that fits its height: the view has nothing to scroll and drops the
// wheel, and a long line keeps it through the editor's own area, so `dx` still scrolls; with
// no range either way the editor takes no wheel at all, leaving it to a view around it.
test "a short editor scrolls sideways and leaves the rest of the wheel alone" {
    var long: [101]u8 = @splat('x');
    long[100] = '\n';
    const editor = test_fresh(&long);
    _ = test_frame(400, 300);
    _ = test_frame(400, 300);
    try testing.expectEqual(@as(f32, 0), editor.view.max_scroll());
    const wheel: input.Wheel = .{ .x = 200, .y = 100, .dx = 30, .dy = 0 };
    _ = test_send(.{ .wheel = wheel });
    try testing.expectEqual(@as(f32, 30), editor.scroll_x);
    const short = test_fresh("x\n");
    _ = test_frame(400, 300);
    _ = test_frame(400, 300);
    _ = test_send(.{ .wheel = wheel });
    try testing.expectEqual(@as(f32, 0), short.scroll_x);
    try testing.expectEqual(ui.Id.none, fixture.context.wheel);
}

// Locks inline rows: the iterator offers the visible row with a walk that lands it right
// under its line and right of the gutter, the app fills it with its own container, and the
// view still measures the whole content.
test "inline rows are handed to the app in place" {
    const editor = test_fresh("a\nb\nc\n");
    editor.rows[0] = .{ .after_line = 1, .height = 40 };
    editor.rows[1] = .{ .after_line = 30, .height = 40 };
    editor.row_count = 2;
    const context = &fixture.context;
    context.begin_frame(800, 600, 120);
    editor.draw_begin(context, ui.sized(.fill, .fill));
    const slot = editor.next_row(context).?;
    try testing.expectEqual(@as(u32, 0), slot.index);
    try testing.expectEqual(@as(f32, 4 + 2 * 21), slot.rect.y);
    try testing.expectEqual(@as(f32, 45), slot.rect.x);
    try testing.expectEqual(@as(f32, 800 - 45 - 16), slot.rect.width);
    _ = context.begin(slot.walk, ui.flow_of(.right));
    _ = context.end();
    // The second row clamps to the last line and is visible too.
    const clamped = editor.next_row(context).?;
    try testing.expectEqual(@as(f32, 4 + 4 * 21 + 40), clamped.rect.y);
    try testing.expectEqual(@as(?RowSlot, null), editor.next_row(context));
    editor.draw_end(context);
    _ = context.end_frame();
    try testing.expectEqual(@as(f32, 2 * 4 + 4 * 21 + 80), editor.view.content_h);
}

/// A language in a narrow and a wide face: words in sans, numbers on the mono face's 9 px.
const Pair = struct {
    pub const State = Duo.State;
    pub const Class = Duo.Class;
    pub const palette = Duo.palette;
    pub const faces: [2]text.Face = .{ .sans, .mono };
    pub const next = Duo.next;
};

const PairEditor = EditorOf(Pair);

const pair_fixture = struct {
    var editor: PairEditor = undefined;
};

fn pair_fresh(utf8: []const u8) *PairEditor {
    fixture.context.init();
    const editor = &pair_fixture.editor;
    editor.init(test_id, PairEditor.default_style);
    assert(editor.load(utf8));
    return editor;
}

fn pair_frame(width: u32, height: u32) *TestContext {
    const context = &fixture.context;
    context.begin_frame(width, height, 120);
    pair_fixture.editor.draw(context, ui.sized(.fill, .fill));
    _ = context.end_frame();
    return context;
}

fn pair_send(event: input.Event) Action {
    const context = &fixture.context;
    context.event_begin(event);
    const action = pair_fixture.editor.handle(context, event);
    context.event_end();
    return action;
}

fn pair_key(name: input.Key, mods: input.Mods) Action {
    return pair_send(.{ .key_down = input.key_press(name, mods, false, "") });
}

// Locks the seam of section 2: on a line of both classes every boundary round-trips through
// `x_of` and `byte_at_x`, a number's digits are 9 px apart, a word's "i" is narrower, a click
// left of a glyph's middle lands before it and right of it after, and past the end is the end.
test "x_of and byte_at_x round trip on every boundary of a mixed line" {
    const line = "if 12 il 7w";
    const editor = pair_fresh(line);
    _ = pair_frame(800, 300);
    var byte: u32 = 0;
    while (byte <= line.len) : (byte += 1) {
        try testing.expectEqual(byte, editor.byte_at_x(0, editor.x_of(0, byte)));
    }
    try testing.expectEqual(@as(f32, 9), editor.x_of(0, 4) - editor.x_of(0, 3));
    try testing.expect(editor.x_of(0, 1) < 9);
    const left = editor.x_of(0, 3);
    const middle = left + 4.5;
    try testing.expectEqual(@as(u32, 3), editor.byte_at_x(0, middle - 0.5));
    try testing.expectEqual(@as(u32, 4), editor.byte_at_x(0, middle + 0.5));
    try testing.expectEqual(@as(u32, line.len), editor.byte_at_x(0, 1e6));
    try testing.expectEqual(@as(u32, 0), editor.byte_at_x(0, -5));
}

// Locks every helper against `x_of`: a rect's x and width, a selection band over a gap and into
// the newline's extra column, a box decoration, and the caret. The pens agree with the walk
// past `columns_max`, where a line outruns the table.
test "rects, spans, decorations, and the caret follow the pens" {
    const editor = pair_fresh("word 12 w\nnext\n");
    _ = pair_frame(800, 300);
    const left = editor.geometry.text_left;
    const rect = editor.rect_of(5);
    try testing.expectEqual(left + editor.x_of(0, 5), rect.x);
    try testing.expectEqual(@as(f32, 9), rect.width);
    try testing.expectApproxEqAbs(editor.space_advance(1), editor.rect_of(9).width, 0.001);
    try testing.expectEqual(editor.x_of(0, 9) + editor.space_advance(1), editor.x_of_column(0, 10));
    const band = editor.span_rect(0, editor.line_span(0, 2, 12, true).?, 4);
    try testing.expectEqual(left + editor.x_of(0, 2), band.x);
    try testing.expectEqual(editor.x_of_column(0, 10) - editor.x_of(0, 2), band.width);
    editor.decorations[0] = .{ .start = 5, .end = 7, .kind = .strike };
    editor.decoration_count = 1;
    editor.caret = 7;
    editor.anchor = 7;
    test_focus_pair(editor);
    const context = pair_frame(800, 300);
    var found_strike = false;
    var found_caret = false;
    for (context.draw.items(draw.Box)) |box| {
        if (std.meta.eql(box.fill, editor.style.palette.strike)) {
            found_strike = true;
            try testing.expectEqual(left + editor.x_of(0, 5), box.rect[0]);
            try testing.expectEqual(@as(f32, 18), box.rect[2]);
        }
        if (std.meta.eql(box.fill, editor.style.palette.caret)) {
            found_caret = true;
            try testing.expectEqual(@round(left + editor.x_of(0, 7)) - 1, box.rect[0]);
        }
    }
    try testing.expect(found_strike and found_caret);
    var long: [260]u8 = @splat('i');
    long[259] = '\n';
    const wide = pair_fresh(&long);
    _ = pair_frame(800, 300);
    const walked = wide.x_of(0, 250);
    try testing.expectApproxEqAbs(@as(f32, 250) * wide.x_of(0, 1), walked, 0.01);
    try testing.expectEqual(@as(u32, 250), wide.byte_at_x(0, walked));
}

fn test_focus_pair(editor: *PairEditor) void {
    const point: input.Point = .{ .x = 700, .y = 200 };
    const saved = [2]u32{ editor.caret, editor.anchor };
    _ = pair_send(.{ .pointer_move = point });
    _ = pair_send(.{ .pointer_down = input.left_at(point) });
    _ = pair_send(.{ .pointer_up = input.left_at(point) });
    editor.caret = saved[0];
    editor.anchor = saved[1];
}

// Locks a stale table: an edit moves the text before any draw, and `x_of` walks the new text
// instead of reading the last frame's pens, here the 9 px of a digit typed at the start.
test "x_of after an edit does not read last frame's pens" {
    const editor = pair_fresh("iii");
    _ = pair_frame(800, 300);
    const before = editor.x_of(0, 3);
    try testing.expect(editor.replace(.{ .start = 0, .end = 0 }, "7 "));
    try testing.expectEqual(9 + editor.space_advance(1) + before, editor.x_of(0, 5));
}

// Locks the goal as an x: from the end of a long word line, Down lands on the column nearest the
// same x on a line of wide digits, not the same column; the short line in between clamps the
// caret and keeps the goal; a horizontal move clears it.
test "up and down keep their x across a short line" {
    const editor = pair_fresh("iiiiiiiiiiii\ni\n7777777777\n");
    _ = pair_frame(800, 300);
    editor.caret = 12;
    editor.anchor = 12;
    test_focus_pair(editor);
    const x = editor.x_of(0, 12);
    _ = pair_key(.down, .none);
    try testing.expectEqual(@as(u32, 14), editor.caret);
    try testing.expectEqual(@as(?f32, x), editor.goal);
    _ = pair_key(.down, .none);
    try testing.expectEqual(editor.byte_at_x(2, x), editor.caret);
    try testing.expect(editor.caret - 15 < 12);
    _ = pair_key(.left, .none);
    try testing.expectEqual(@as(?f32, null), editor.goal);
}

// Locks the measured range of section 3: `widest_px` follows an edit, a load, and a size change,
// and however often the range is read it walks the text once per revision and size.
test "widest_px is measured once per revision" {
    const editor = pair_fresh("i\n77\n");
    _ = pair_frame(800, 300);
    try testing.expectEqual(@as(f32, 18), editor.widest_px());
    const walks = editor.pens.widest_walks;
    _ = editor.scroll_x_max();
    _ = editor.widest_px();
    try testing.expectEqual(walks, editor.pens.widest_walks);
    try testing.expect(editor.replace(.{ .start = 2, .end = 2 }, "7"));
    try testing.expectEqual(@as(f32, 27), editor.widest_px());
    try testing.expectEqual(walks + 1, editor.pens.widest_walks);
    try testing.expect(editor.load("7777"));
    try testing.expectEqual(@as(f32, 36), editor.widest_px());
    editor.style.size = 30;
    _ = pair_frame(800, 300);
    try testing.expectEqual(@as(f32, 72), editor.widest_px());
}

// Locks the wide cost of proportional faces: a line of 200 "i" shows every column in a viewport
// the grid would fill with far fewer, inside `glyph_bound_of`, which a width does not bound;
// `lines_bound_of` takes the faces' pitch.
test "glyph_bound_of holds on a line of narrow glyphs" {
    var line: [200]u8 = @splat('i');
    line[199] = '\n';
    const editor = pair_fresh(&line);
    _ = pair_frame(800, 300);
    const glyphs = fixture.context.draw.items(draw.Glyph).len;
    try testing.expect(glyphs > glyph_bound(800, 21, 15) / 2);
    const bound = comptime glyph_bound_of(Pair, 800, 300, 15);
    try testing.expectEqual(lines_bound_of(Pair, 300, 15) * (columns_max + digits_max), bound);
    const mono_bound = comptime glyph_bound_of(tokenizer, 800, 300, 15);
    try testing.expectEqual(glyph_bound(800, 300, 15), mono_bound);
    try testing.expectEqual(editor.line_height(), comptime line_height_of(Pair, 15));
}

// Locks the price of the seam: a mono editor stores no pens or faces, so its size is what it
// was plus `Style.gutter`, and a proportional one carries 103 KB of pens on top.
test "a mono editor pays nothing for proportional faces" {
    try testing.expectEqual(@as(usize, 322_272 + 8), @sizeOf(Editor));
    try testing.expect(@sizeOf(PairEditor) > @sizeOf(EditorOf(Duo)) + @sizeOf(Pens));
}

/// `Pair` with headings: a line starting "# " is twice the size.
const Tiered = struct {
    pub const State = Pair.State;
    pub const Class = Pair.Class;
    pub const palette = Pair.palette;
    pub const faces = Pair.faces;
    pub const next = Pair.next;
    pub const scales: [2]f32 = .{ 1, 2 };

    pub fn level_of(line: []const u8) u8 {
        return if (std.mem.startsWith(u8, line, "# ")) 1 else 0;
    }
};

const TieredEditor = EditorOf(Tiered);

const tiered_fixture = struct {
    var editor: TieredEditor = undefined;
};

fn tiered_fresh(utf8: []const u8) *TieredEditor {
    fixture.context.init();
    const editor = &tiered_fixture.editor;
    editor.init(test_id, TieredEditor.default_style);
    assert(editor.load(utf8));
    return editor;
}

fn tiered_frame(width: u32, height: u32) *TestContext {
    const context = &fixture.context;
    context.begin_frame(width, height, 120);
    tiered_fixture.editor.draw(context, ui.sized(.fill, .fill));
    _ = context.end_frame();
    return context;
}

fn tiered_send(event: input.Event) Action {
    const context = &fixture.context;
    context.event_begin(event);
    const action = tiered_fixture.editor.handle(context, event);
    context.event_end();
    return action;
}

// Locks the walk of section 2 over tall lines and rows in any order: every line's top maps back
// to the line through `line_at`, as do its bottom edge and its middle; a y in a row is the line
// above it; and the content height is the bottom of the last line.
test "line_top and line_at round trip across tall lines and rows" {
    const editor = tiered_fresh("# a\nb\n# c\n# d\ne\nf\n# g");
    editor.rows[0] = .{ .after_line = 0, .height = 30 };
    editor.rows[1] = .{ .after_line = 3, .height = 50 };
    editor.rows[2] = .{ .after_line = 3, .height = 10 };
    editor.row_count = 3;
    var line: u32 = 0;
    while (line < editor.buffer.line_count) : (line += 1) {
        const top = editor.line_top(line);
        const height = editor.height_of_line(line);
        try testing.expectEqual(line, editor.line_at(top));
        try testing.expectEqual(line, editor.line_at(top + height * 0.5));
        try testing.expectEqual(line, editor.line_at(top + height - 0.25));
    }
    try testing.expectEqual(@as(u32, 0), editor.line_at(editor.row_top(0) + 5));
    try testing.expectEqual(@as(u32, 3), editor.line_at(editor.row_top(2) + 5));
    const last = editor.buffer.line_count - 1;
    const bottom = editor.line_top(last) + editor.height_of_line(last) + padding_px;
    try testing.expectEqual(bottom, editor.content_height());
    try testing.expectEqual(line_height_of(Tiered, 30), editor.height_of_line(0));
}

// Locks a heading's geometry: a click on it lands on it, `x_of` and `byte_at_x` round trip at its
// scale, its caret and band take its height, its glyphs are twice the size, and the line after
// it starts where it ends.
test "a heading is a taller line of real text" {
    const line = "# title word";
    const editor = tiered_fresh(line ++ "\nbody\n");
    _ = tiered_frame(800, 300);
    var byte: u32 = 0;
    while (byte <= line.len) : (byte += 1) {
        try testing.expectEqual(byte, editor.byte_at_x(0, editor.x_of(0, byte)));
    }
    const tall = editor.rect_of(4);
    const body = editor.rect_of(13);
    try testing.expectEqual(editor.height_of_line(0), tall.height);
    try testing.expectEqual(tall.y + tall.height, body.y);
    const point: input.Point = .{ .x = tall.x + tall.width * 0.25, .y = tall.y + tall.height - 2 };
    _ = tiered_send(.{ .pointer_move = point });
    _ = tiered_send(.{ .pointer_down = input.left_at(point) });
    _ = tiered_send(.{ .pointer_up = input.left_at(point) });
    try testing.expectEqual(@as(u32, 4), editor.caret);
    const context = tiered_frame(800, 300);
    var found = false;
    for (context.draw.items(draw.Box)) |box| {
        if (!std.meta.eql(box.fill, editor.style.palette.caret)) continue;
        found = true;
        try testing.expectEqual(tall.height, box.rect[3]);
    }
    try testing.expect(found);
    const glyphs = context.draw.items(draw.Glyph);
    const big = glyphs[1].rect[3];
    try testing.expect(big > 1.5 * glyphs[glyphs.len - 1].rect[3]);
}

// Locks the list: an edit, undo, and a load all move it; an edit on one line changes no other's
// height; past `tall_cap` a heading is a body line in size and height alike.
test "the tall lines follow the text" {
    const editor = tiered_fresh("a\nb\n");
    _ = tiered_frame(800, 300);
    const body = editor.line_height();
    try testing.expectEqual(body, editor.height_of_line(0));
    try testing.expect(editor.replace(.{ .start = 0, .end = 0 }, "# "));
    try testing.expectEqual(line_height_of(Tiered, 30), editor.height_of_line(0));
    try testing.expectEqual(body, editor.height_of_line(1));
    _ = tiered_send(.{ .key_down = input.key_press(.left, .none, false, "") });
    try testing.expectEqual(@as(u32, 1), editor.buffer.tall_count);
    try testing.expect(editor.buffer.undo() != null);
    try testing.expectEqual(@as(u32, 0), editor.buffer.tall_count);
    var many: [(buffer_module.tall_cap + 2) * 4]u8 = undefined;
    for (0..buffer_module.tall_cap + 2) |index| @memcpy(many[index * 4 ..][0..4], "# a\n");
    try testing.expect(editor.load(&many));
    try testing.expectEqual(buffer_module.tall_cap, editor.buffer.tall_count);
    const past = buffer_module.tall_cap + 1;
    try testing.expectEqual(body, editor.height_of_line(past));
    try testing.expectEqual(@as(f32, 1), editor.scale_at(past));
}

// Locks that sizing lines costs other languages nothing: a language of faces alone stays as it
// was, and only a sized one carries the list.
test "only a sized language keeps tall lines" {
    try testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(pair_fixture.editor.buffer.tall)));
    try testing.expect(@sizeOf(TieredEditor) > @sizeOf(PairEditor));
}

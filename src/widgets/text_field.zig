//! `TextField`: a single-line field over the pure editing core.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Model
//! The field wraps `ui/edit.zig`: a contiguous buffer of at most `edit.field_cap` bytes, here
//! limited to the field's `limit`. Its area is focusable with the I-beam cursor
//! (`field_flags`); a left press focuses it (`ui/cx.zig`, section 7). Keyboard and paste
//! events answer `none` from `hit`, so only the focused field reads them.
//!
//! ## 2. Pointer
//! A press puts the caret at `text.index_at` of the press, Shift extends, a double press
//! selects the word and a triple press everything (`Press.clicks`), and a drag extends the
//! selection. There is no auto-scroll past the edges.
//!
//! ## 3. Keys
//! While focused: arrows, Home, End (Up, Page Up and Down, Page Down act as Home and End),
//! Backspace, Delete, typed text, and with Ctrl or Meta: A selects all, C copies, X cuts, V
//! asks for a paste, arrows jump words, Backspace and Delete erase words. Enter clears focus
//! and returns `committed`, Escape returns `cancelled` (the context clears focus after), and
//! losing focus to a press or Tab returns `committed`. There is no undo. A paste is made one
//! line (`edit.sanitize_line`) and cut to the limit.
//!
//! ## 4. Scroll
//! `scroll_x` keeps the caret inside the inner box (`field_inner`, the rect inset by
//! `field_padding_x`), measured with `cx.focused_rect()` for keys and the press rect for the
//! pointer, and never scrolls past the text's end. Test "a field scrolls to keep the caret
//! visible".
//!
//! ## 5. Drawing
//! The face (with the focus border) is the skin's (`widgets/skin.zig`; `TextField` is
//! `TextFieldOf(skins.Default)`); the selection band, the glyphs offset by `-scroll_x` and
//! clipped to the inner box, and while focused a steady caret one device pixel wide snapped to
//! the device grid. It never blinks, so a focused field keeps the host asleep. Measuring the
//! caret is O(bytes), at most 256 per drawn frame.
//!
//! ## 5a. Hint and Icon
//! `hint` is drawn in the field's `style` at `hint_alpha` while the field is empty, focused or
//! not, under the caret; never once text exists, and never masked. `icon` is one codepoint of
//! an app face (`text.icon`), `field_icon_px`, centred in the field's left `field_icon_w` in
//! the hint's colour; the text box then starts after that cell (`field_inner_lead`), so the
//! text, the caret, the selection, presses, and scrolling all move with it.
//!
//! ## 6. Secret
//! A `secret` field keeps its real bytes in the editing core and shows a `bullet` (U+2022) per
//! codepoint. Every measure goes through the shown text: boundary `i` of the text is
//! `mask_index(i)` (three bytes per codepoint before it) of the shown, and a press maps back
//! with `unmask_index`. Copy and cut do nothing (the browser's `copy` event then finds nothing
//! to take). Word moves and word erasure go to the ends, and a double press selects all, so
//! the text's word structure never shows. The number of codepoints does: platform behaviour.

const std = @import("std");
const assert = std.debug.assert;
const quads = @import("../draw.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");
const edit = @import("../ui/edit.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;
const Id = kit.Id;

/// A text field's area: focusable, with the I-beam cursor.
pub const field_flags: ui.Flags = .{
    .wheel = false,
    .focusable = true,
    .tab = false,
    .cursor = .text,
};
/// Text field metrics in logical pixels: the text inset, the face's corner radius and border,
/// and the caret's inset from the top and bottom.
pub const field_padding_x: f32 = 6;
pub const field_radius: f32 = 4;
pub const field_border_px: f32 = 1;
pub const field_caret_inset: f32 = 4;
/// The dark scheme's focused field border and selection band behind the text. The field reads
/// the app's (`cx.theme().colors.focus` and `.selection`).
pub const field_focus_border: [4]f32 = theme.dark.colors.focus;
pub const field_selection: [4]f32 = theme.dark.colors.selection;
/// A hint's alpha, and a leading icon's, against the field style's color.
pub const hint_alpha: f32 = 0.45;
/// A leading icon's cell at the field's left (the text starts after it) and the icon's size.
pub const field_icon_w: f32 = 28;
pub const field_icon_px: f32 = 16;
/// A secret field shows this for every codepoint (section 6).
pub const bullet = "\u{2022}";
const bullet_len: u32 = bullet.len;
/// Bytes of a secret field's shown text at most: one bullet per byte of a full field.
pub const mask_cap: u32 = bullet_len * edit.field_cap;

/// A leading icon: a codepoint of one of the app's faces (`text.icon`).
pub const FieldIcon = struct {
    face: text.Face,
    codepoint: u21,
};

/// Field text starts at the left and is centered vertically, never cut.
pub const field_text_options: text.Options = .{
    .align_x = .start,
    .align_y = .center,
    .ellipsis = false,
};

/// The default field: `TextFieldOf(skins.Default)`.
pub const TextField = TextFieldOf(skin.Default);

/// A single-line text field over the editing core (`ui/edit.zig`) whose face and border are
/// drawn by `Skin` (`widgets/skin.zig`). Its area is focusable and shows the I-beam. See the
/// module guide.
pub fn TextFieldOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .field)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        id: Id,
        edit: edit.Edit,
        /// How far the text is scrolled left inside the field, in logical pixels.
        scroll_x: f32,
        style: text.Style,
        /// Drawn in `style` at `hint_alpha` while the field is empty (section 5a).
        hint: []const u8 = "",
        /// Shows a bullet per codepoint and refuses copy and cut (section 6).
        secret: bool = false,
        /// Drawn in the field's left `field_icon_w`, before the text (section 5a).
        icon: ?FieldIcon = null,

        pub const Action = enum {
            none,
            changed,
            /// Enter, or focus moved away (a press elsewhere or Tab).
            committed,
            /// Escape.
            cancelled,
        };

        /// An empty field holding at most `limit` bytes.
        pub fn init(id: Id, limit: u32, style: text.Style) Self {
            assert(id != .none);
            assert(limit <= edit.field_cap);
            const field: Self = .{
                .id = id,
                .edit = edit.Edit.init(limit),
                .scroll_x = 0,
                .style = style,
            };
            assert(field.edit.len == 0);
            return field;
        }

        /// The text.
        pub fn bytes(self: *const Self) []const u8 {
            assert(self.id != .none);
            return self.edit.text();
        }

        /// Replaces the text with `utf8` and selects all of it, scrolled to the start.
        pub fn load(self: *Self, utf8: []const u8) void {
            self.edit.set(utf8);
            self.edit.select_all();
            self.scroll_x = 0;
            assert(self.edit.anchor == 0);
        }

        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.scroll_x >= 0);
            if (event == .frame) return .none;
            if (cx.focus_lost(self.id)) {
                cx.redraw();
                return .committed;
            }
            switch (event) {
                .key_down => |press| {
                    if (!cx.focused(self.id)) return .none;
                    return self.key(cx, press);
                },
                .paste => |pasted| {
                    if (!cx.focused(self.id)) return .none;
                    var line: [edit.field_cap]u8 = undefined;
                    const length = edit.sanitize_line(pasted, &line);
                    return self.changed_if(cx, self.edit.insert(line[0..length]));
                },
                else => {},
            }
            switch (cx.hit(self.id, event)) {
                .down => |press| {
                    const index = self.index_at(press);
                    if (press.clicks >= 3) {
                        self.edit.select_all();
                    } else if (press.clicks == 2 and self.secret) {
                        self.edit.select_all();
                    } else if (press.clicks == 2) {
                        self.edit.select_word(index);
                    } else {
                        self.edit.move_to(index, press.mods.shift);
                    }
                    self.follow(press.rect);
                    cx.redraw();
                },
                .drag => |press| {
                    self.edit.move_to(self.index_at(press), true);
                    self.follow(press.rect);
                    cx.redraw();
                },
                else => {},
            }
            return .none;
        }

        /// Draws the face (the skin's), the selection and the caret while focused, and the text
        /// scrolled by `scroll_x` and clipped to the field, and records the focusable I-beam area.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.scroll_x >= 0);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            const focused = cx.focused(self.id);
            cx.area(self.id, rect, field_radius, field_flags);
            Skin.field(cx, .{ .rect = rect, .clip = clip, .focused = focused });
            const colors = &cx.theme().colors;
            var faint = self.style.color;
            faint[3] *= hint_alpha;
            if (self.icon) |icon| {
                const cell: Rect = .{
                    .x = rect.x,
                    .y = rect.y,
                    .width = field_icon_w,
                    .height = rect.height,
                };
                kit.icon(cx, icon.face, icon.codepoint, field_icon_px, cell, clip, faint);
            }
            const inner = self.inner_of(rect);
            const inner_clip = ui.cx.intersect(clip, inner) orelse return;
            const origin = inner.x - self.scroll_x;
            var buffer: [mask_cap]u8 = undefined;
            const shown = self.shown_text(&buffer);
            if (focused and self.edit.has_selection()) {
                const range = self.edit.selection();
                const x0 = origin + text.measure(self.style, shown[0..self.to_shown(range.start)]);
                const x1 = origin + text.measure(self.style, shown[0..self.to_shown(range.end)]);
                const band: Rect = .{
                    .x = x0,
                    .y = inner.y,
                    .width = x1 - x0,
                    .height = inner.height,
                };
                kit.face(cx, band, inner_clip, .{ .fill = colors.selection });
            }
            const line: Rect = .{
                .x = origin,
                .y = inner.y,
                .width = inner.width + self.scroll_x,
                .height = inner.height,
            };
            if (self.edit.len == 0 and self.hint.len > 0) {
                var style = self.style;
                style.color = faint;
                kit.label(cx, style, self.hint, inner, inner_clip, field_text_options);
            }
            kit.label(cx, self.style, shown, line, inner_clip, field_text_options);
            if (focused) {
                const scale = cx.drawing().text.device_scale();
                const caret_x = origin +
                    text.measure(self.style, shown[0..self.to_shown(self.edit.caret)]);
                const caret: Rect = .{
                    .x = @round(caret_x * scale) / scale,
                    .y = inner.y + field_caret_inset,
                    .width = 1 / scale,
                    .height = inner.height - 2 * field_caret_inset,
                };
                kit.face(cx, caret, inner_clip, .{ .fill = colors.text });
            }
        }

        /// The text box inside `rect`: after the icon's cell when there is one.
        fn inner_of(self: *const Self, rect: Rect) Rect {
            const lead = if (self.icon != null) field_icon_w else field_padding_x;
            return field_inner_lead(rect, lead);
        }

        /// The text as drawn: the bytes, or a bullet per codepoint when secret (section 6).
        fn shown_text(self: *const Self, buffer: *[mask_cap]u8) []const u8 {
            if (!self.secret) return self.edit.text();
            return mask(self.edit.text(), buffer);
        }

        /// The shown index of text boundary `index`.
        fn to_shown(self: *const Self, index: u32) u32 {
            if (!self.secret) return index;
            return mask_index(self.edit.text(), index);
        }

        /// The caret's target for a word move left: the word's start, or 0 when secret.
        fn word_left(self: *const Self, all: []const u8, caret: u32) u32 {
            if (self.secret) return 0;
            return edit.word_left(all, caret);
        }

        /// The caret's target for a word move right: the word's end, or the end when secret.
        fn word_right(self: *const Self, all: []const u8, caret: u32) u32 {
            if (self.secret) return self.edit.len;
            return edit.word_right(all, caret);
        }

        /// Erases the selection, or else a word in `direction`; a secret field erases to that
        /// end instead, so its word structure never shows.
        fn erase_word(self: *Self, direction: edit.Direction) bool {
            if (!self.secret or self.edit.has_selection()) return self.edit.erase(direction, true);
            const target = if (direction == .backward) 0 else self.edit.len;
            if (target == self.edit.caret) return false;
            self.edit.move_to(target, true);
            return self.edit.delete_selection();
        }

        /// One key press while focused: shortcuts, movement, deletion, Enter, Escape, or typed
        /// text. Tab is the library's (`ui/cx.zig`, section 7).
        fn key(self: *Self, cx: anytype, press: input.KeyPress) Action {
            assert(cx.focused(self.id));
            const shift = press.mods.shift;
            const all = self.edit.text();
            const caret = self.edit.caret;
            if (press.mods.shortcut()) {
                switch (press.key) {
                    .a => self.edit.select_all(),
                    .c => {
                        if (self.secret) return .none;
                        if (self.edit.has_selection()) cx.copy(self.edit.selected());
                    },
                    .x => {
                        if (self.secret) return .none;
                        if (!self.edit.has_selection()) return .none;
                        cx.copy(self.edit.selected());
                        return self.changed_if(cx, self.edit.delete_selection());
                    },
                    .v => cx.request_paste(),
                    .left => self.edit.move_to(self.word_left(all, caret), shift),
                    .right => self.edit.move_to(self.word_right(all, caret), shift),
                    .backspace => return self.changed_if(cx, self.erase_word(.backward)),
                    .delete => return self.changed_if(cx, self.erase_word(.forward)),
                    else => return .none,
                }
                self.moved(cx);
                return .none;
            }
            const range = self.edit.selection();
            const collapse = self.edit.has_selection() and !shift;
            switch (press.key) {
                .left => {
                    const target = if (collapse) range.start else edit.prev_boundary(all, caret);
                    self.edit.move_to(target, shift);
                },
                .right => {
                    const target = if (collapse) range.end else edit.next_boundary(all, caret);
                    self.edit.move_to(target, shift);
                },
                .home, .up, .page_up => self.edit.move_to(0, shift),
                .end, .down, .page_down => self.edit.move_to(self.edit.len, shift),
                .backspace => return self.changed_if(cx, self.edit.erase(.backward, false)),
                .delete => return self.changed_if(cx, self.edit.erase(.forward, false)),
                .enter => {
                    cx.clear_focus();
                    cx.redraw();
                    return .committed;
                },
                .escape => {
                    cx.redraw();
                    return .cancelled;
                },
                .tab => return .none,
                else => {
                    if (press.len == 0) return .none;
                    return self.changed_if(cx, self.edit.insert(press.typed()));
                },
            }
            self.moved(cx);
            return .none;
        }

        fn changed_if(self: *Self, cx: anytype, changed: bool) Action {
            self.moved(cx);
            if (changed) return .changed;
            return .none;
        }

        /// After the caret or text moved: keep the caret in view and owe a draw.
        fn moved(self: *Self, cx: anytype) void {
            self.follow(cx.focused_rect());
            cx.redraw();
            assert(self.scroll_x >= 0);
        }

        /// Scrolls so the caret is inside the field's inner box, and never past the text's end.
        /// A field not drawn yet has no box and keeps its scroll.
        fn follow(self: *Self, rect: Rect) void {
            const room = self.inner_of(rect).width;
            if (!(room > 0)) return;
            var buffer: [mask_cap]u8 = undefined;
            const shown = self.shown_text(&buffer);
            const caret_x = text.measure(self.style, shown[0..self.to_shown(self.edit.caret)]);
            if (caret_x - self.scroll_x > room) self.scroll_x = caret_x - room;
            if (caret_x < self.scroll_x) self.scroll_x = caret_x;
            const limit = @max(0, text.measure(self.style, shown) - room);
            self.scroll_x = std.math.clamp(self.scroll_x, 0, limit);
            assert(self.scroll_x >= 0);
        }

        /// The boundary under a press, from the field's rect at the last draw.
        fn index_at(self: *const Self, press: ui.Press) u32 {
            const local = press.x - self.inner_of(press.rect).x + self.scroll_x;
            var buffer: [mask_cap]u8 = undefined;
            const shown = self.shown_text(&buffer);
            const found = text.index_at(self.style, shown, local);
            const index = if (self.secret) unmask_index(self.edit.text(), found) else found;
            assert(index <= self.edit.len);
            return index;
        }
    };
}

/// The text box of a field: its rect inset by `field_padding_x` on both sides.
pub fn field_inner(rect: Rect) Rect {
    return field_inner_lead(rect, field_padding_x);
}

/// The text box of a field whose text starts `lead` in from the left (`field_icon_w` after an
/// icon): its rect inset by `lead` on the left and `field_padding_x` on the right.
pub fn field_inner_lead(rect: Rect, lead: f32) Rect {
    assert(lead >= field_padding_x);
    const inner: Rect = .{
        .x = rect.x + lead,
        .y = rect.y,
        .width = rect.width - lead - field_padding_x,
        .height = rect.height,
    };
    assert(inner.height == rect.height);
    assert(inner.x == rect.x + lead);
    return inner;
}

/// Writes a `bullet` per codepoint of `bytes` (valid UTF-8, at most `edit.field_cap` bytes)
/// into `out` and returns them (section 6).
pub fn mask(bytes: []const u8, out: *[mask_cap]u8) []const u8 {
    assert(bytes.len <= edit.field_cap);
    var index: u32 = 0;
    var length: u32 = 0;
    while (index < bytes.len) : (index = edit.next_boundary(bytes, index)) {
        @memcpy(out[length..][0..bullet_len], bullet);
        length += bullet_len;
    }
    assert(length <= mask_cap);
    assert(length % bullet_len == 0);
    return out[0..length];
}

/// The masked index of boundary `index` of `bytes`: a bullet's bytes per codepoint before it.
pub fn mask_index(bytes: []const u8, index: u32) u32 {
    assert(index <= bytes.len);
    assert(edit.is_boundary(bytes, index));
    var cursor: u32 = 0;
    var count: u32 = 0;
    while (cursor < index) : (cursor = edit.next_boundary(bytes, cursor)) count += 1;
    assert(cursor == index);
    return count * bullet_len;
}

/// The boundary of `bytes` before codepoint `masked / bullet_len`: `mask_index`'s inverse,
/// rounding a masked index inside a bullet down and one past the end to the end.
pub fn unmask_index(bytes: []const u8, masked: u32) u32 {
    assert(bytes.len <= edit.field_cap);
    const wanted = masked / bullet_len;
    var cursor: u32 = 0;
    var count: u32 = 0;
    while (cursor < bytes.len and count < wanted) : (count += 1) {
        cursor = edit.next_boundary(bytes, cursor);
    }
    assert(cursor <= bytes.len);
    assert(edit.is_boundary(bytes, cursor));
    return cursor;
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const TestContext = fixture.Context;
const test_context = fixture.context;
const send = fixture.send;
const draw_one = fixture.draw_one;
const at = fixture.at;

const field_style: text.Style = .{ .face = .mono, .size = 16, .color = .{ 1, 1, 1, 1 } };

fn typed(key: input.Key, utf8: []const u8) input.Event {
    return .{ .key_down = input.key_press(key, .none, false, utf8) };
}

fn chord(key: input.Key, mods: input.Mods) input.Event {
    return .{ .key_down = input.key_press(key, mods, false, "") };
}

fn click_at(x: f32, time_ms: u32) input.Event {
    return .{ .pointer_down = .{
        .x = x,
        .y = 10,
        .time_ms = time_ms,
        .button = .left,
        .mods = .none,
    } };
}

fn release_at(x: f32, time_ms: u32) input.Event {
    return .{ .pointer_up = .{
        .x = x,
        .y = 10,
        .time_ms = time_ms,
        .button = .left,
        .mods = .none,
    } };
}

/// A field drawn at (0, 0), 106 px wide: 94 px of text room, about 9.8 mono advances.
fn drawn_field(cx: *TestContext, field: *TextField) void {
    draw_one(cx, field, at(0, 0, 106, 24));
}

// Locks typing and the field's actions: a press focuses it, text inserts at the caret,
// Backspace and arrows edit, Ctrl+Left jumps a word, Enter commits and drops focus, and
// Escape cancels.
test "a field types, edits, commits on Enter, and cancels on Escape" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    drawn_field(cx, &field);
    try testing.expectEqual(TextField.Action.none, send(cx, &field, click_at(30, 0)));
    _ = send(cx, &field, release_at(30, 0));
    try testing.expect(cx.focused(field.id));
    try testing.expectEqual(TextField.Action.changed, send(cx, &field, typed(.o, "o")));
    _ = send(cx, &field, typed(.s, "s"));
    _ = send(cx, &field, typed(.other, " "));
    _ = send(cx, &field, typed(.c, "c"));
    try testing.expectEqualStrings("os c", field.bytes());
    try testing.expectEqual(TextField.Action.changed, send(cx, &field, chord(.backspace, .none)));
    _ = send(cx, &field, chord(.left, .none));
    _ = send(cx, &field, typed(.other, "\u{e4}"));
    try testing.expectEqualStrings("os\u{e4} ", field.bytes());
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    _ = send(cx, &field, chord(.left, ctrl));
    try testing.expectEqual(@as(u32, 0), field.edit.caret);
    try testing.expectEqual(TextField.Action.none, send(cx, &field, typed(.q, "")));
    try testing.expectEqual(TextField.Action.committed, send(cx, &field, chord(.enter, .none)));
    try testing.expect(!cx.focused(field.id));
    _ = send(cx, &field, click_at(30, 1000));
    _ = send(cx, &field, release_at(30, 1000));
    try testing.expectEqual(TextField.Action.cancelled, send(cx, &field, chord(.escape, .none)));
    try testing.expectEqual(Id.none, cx.focus);
}

// Locks the pointer: one press puts the caret at the nearest boundary (9.6 px mono advances
// from x = 6), a drag extends the selection, a double press selects the word and a triple
// press everything, and a press elsewhere commits.
test "a field selects by press, drag, double, and triple click" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    field.load("ab cd");
    drawn_field(cx, &field);
    // x = 6 + 2.4 * 9.6 = 29.04: nearest to the boundary after "ab".
    _ = send(cx, &field, click_at(29.04, 0));
    try testing.expectEqual(@as(u32, 2), field.edit.caret);
    try testing.expect(!field.edit.has_selection());
    _ = send(cx, &field, .{ .pointer_move = .{ .x = 50, .y = 10 } });
    try testing.expectEqualStrings(" cd", field.edit.selected());
    _ = send(cx, &field, release_at(50, 0));
    _ = send(cx, &field, click_at(48, 1000));
    _ = send(cx, &field, release_at(48, 1000));
    _ = send(cx, &field, click_at(48, 1200));
    try testing.expectEqualStrings("cd", field.edit.selected());
    _ = send(cx, &field, release_at(48, 1200));
    _ = send(cx, &field, click_at(48, 1300));
    try testing.expectEqualStrings("ab cd", field.edit.selected());
    _ = send(cx, &field, release_at(48, 1300));
    try testing.expectEqual(TextField.Action.committed, send(cx, &field, click_at(500, 5000)));
}

// Locks the clipboard keys and paste: Ctrl+C copies the selection, Ctrl+X copies and deletes
// it, Ctrl+V asks the host, and a paste is one sanitized line cut to the limit.
test "a field copies, cuts, and pastes one line within its limit" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), 8, field_style);
    field.load("vco");
    drawn_field(cx, &field);
    cx.event_begin(.{ .frame = 0 });
    cx.set_focus(field.id);
    cx.event_end();
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    _ = send(cx, &field, chord(.c, ctrl));
    try testing.expectEqualStrings("vco", cx.copied());
    try testing.expect(cx.take_copy());
    try testing.expectEqual(TextField.Action.changed, send(cx, &field, chord(.x, ctrl)));
    try testing.expectEqual(@as(u32, 0), field.edit.len);
    try testing.expect(cx.take_copy());
    _ = send(cx, &field, chord(.v, ctrl));
    try testing.expect(cx.take_paste_request());
    const action = send(cx, &field, .{ .paste = "lfo\r\nbank 2" });
    try testing.expectEqual(TextField.Action.changed, action);
    try testing.expectEqualStrings("lfo bank", field.bytes());
}

// Locks horizontal scroll: typing past the 94 px room scrolls so the caret stays at the right
// edge, Home scrolls back to 0, and the drawn glyphs are clipped to the field's inner box.
test "a field scrolls to keep the caret visible" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    drawn_field(cx, &field);
    _ = send(cx, &field, click_at(30, 0));
    _ = send(cx, &field, release_at(30, 0));
    var index: u32 = 0;
    while (index < 12) : (index += 1) _ = send(cx, &field, typed(.x, "x"));
    // Twelve advances of 9.6 px = 115.2 px; room 94 px, so the scroll is 21.2 px.
    try testing.expectApproxEqAbs(@as(f32, 115.2 - 94), field.scroll_x, 0.001);
    drawn_field(cx, &field);
    for (cx.draw.items(quads.Glyph)) |glyph| {
        try testing.expectEqual(@as(f32, field_padding_x), glyph.clip[0]);
        try testing.expectEqual(@as(f32, 106 - field_padding_x), glyph.clip[2]);
    }
    _ = send(cx, &field, chord(.home, .none));
    try testing.expectEqual(@as(f32, 0), field.scroll_x);
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

/// A field drawn at (0, 0), 106 px wide, and focused, so its keys arrive.
fn focused_field(cx: *TestContext, field: *TextField) void {
    drawn_field(cx, field);
    cx.event_begin(.{ .frame = 0 });
    cx.set_focus(field.id);
    cx.event_end();
}

// Locks the mask maps of section 6 over 1-, 2-, and 4-byte codepoints: "p\u{e4}\u{1f600}" is 7
// bytes, shown as 9 (three bullets); its boundaries 0, 1, 3, 7 are shown 0, 3, 6, 9, and a
// shown index inside a bullet rounds down.
test "the secret mask maps boundaries both ways" {
    const bytes = "p\u{e4}\u{1f600}";
    var out: [mask_cap]u8 = undefined;
    try testing.expectEqualStrings(bullet ++ bullet ++ bullet, mask(bytes, &out));
    const boundaries = [_]u32{ 0, 1, 3, 7 };
    for (boundaries, 0..) |boundary, index| {
        const shown: u32 = @intCast(index * 3);
        try testing.expectEqual(shown, mask_index(bytes, boundary));
        try testing.expectEqual(boundary, unmask_index(bytes, shown));
    }
    try testing.expectEqual(@as(u32, 1), unmask_index(bytes, 5));
    try testing.expectEqual(@as(u32, 7), unmask_index(bytes, 12));
    try testing.expectEqual(@as(usize, 0), mask("", &out).len);
}

// Locks a secret field (section 6): three codepoints draw three bullet glyphs; a press 1.4 mono
// advances in lands after "p" (byte 1) and Shift+Right after the two-byte "\u{e4}" (byte 3); the
// selection band spans one bullet (9.6 px); copy and cut do nothing; a double press selects
// all; Ctrl+Left goes to 0 and Ctrl+Delete erases to the end.
test "a secret field shows bullets, maps presses, and refuses copy" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    field.secret = true;
    field.load("p\u{e4}\u{1f600}");
    focused_field(cx, &field);
    try testing.expectEqual(@as(usize, 3), cx.draw.items(quads.Glyph).len);
    _ = send(cx, &field, click_at(field_padding_x + 1.4 * 9.6, 0));
    _ = send(cx, &field, release_at(field_padding_x + 1.4 * 9.6, 0));
    try testing.expectEqual(@as(u32, 1), field.edit.caret);
    var shift = input.Mods.none;
    shift.shift = true;
    _ = send(cx, &field, chord(.right, shift));
    try testing.expectEqual(@as(u32, 3), field.edit.caret);
    drawn_field(cx, &field);
    const band = cx.draw.items(quads.Box)[1];
    try testing.expectApproxEqAbs(@as(f32, field_padding_x + 9.6), band.rect[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 9.6), band.rect[2], 0.001);
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    try testing.expectEqual(TextField.Action.none, send(cx, &field, chord(.c, ctrl)));
    try testing.expect(!cx.take_copy());
    try testing.expectEqual(TextField.Action.none, send(cx, &field, chord(.x, ctrl)));
    try testing.expectEqual(@as(u32, 7), field.edit.len);
    _ = send(cx, &field, click_at(20, 1000));
    _ = send(cx, &field, release_at(20, 1000));
    _ = send(cx, &field, click_at(20, 1100));
    _ = send(cx, &field, release_at(20, 1100));
    try testing.expectEqualStrings("p\u{e4}\u{1f600}", field.edit.selected());
    _ = send(cx, &field, chord(.right, .none));
    _ = send(cx, &field, chord(.left, ctrl));
    try testing.expectEqual(@as(u32, 0), field.edit.caret);
    const erased = send(cx, &field, chord(.delete, ctrl));
    try testing.expectEqual(TextField.Action.changed, erased);
    try testing.expectEqual(@as(u32, 0), field.edit.len);
}

// Locks the hint (section 5a): an empty field draws its 3-byte hint at 0.45 of the style's
// alpha, focused or not; once a byte is typed only that byte's glyph is drawn.
test "a hint draws only while the field is empty" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    field.hint = "abc";
    drawn_field(cx, &field);
    const glyphs = cx.draw.items(quads.Glyph);
    try testing.expectEqual(@as(usize, 3), glyphs.len);
    try testing.expectApproxEqAbs(hint_alpha, glyphs[0].color[3], 0.0001);
    focused_field(cx, &field);
    try testing.expectEqual(@as(usize, 3), cx.draw.items(quads.Glyph).len);
    _ = send(cx, &field, typed(.x, "x"));
    drawn_field(cx, &field);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(quads.Glyph).len);
    try testing.expectEqual(@as(f32, 1), cx.draw.items(quads.Glyph)[0].color[3]);
}

// Locks the icon (section 5a): the text box starts at `field_icon_w` (28), so glyphs clip
// from there and a press 2.4 mono advances past it lands at boundary 2; the icon is one more
// glyph in the hint's colour.
test "an icon moves the text start" {
    const cx = test_context();
    var field = TextField.init(ui.id("field", 0), edit.field_cap, field_style);
    field.icon = .{ .face = .sans, .codepoint = 'Q' };
    field.load("abcd");
    focused_field(cx, &field);
    const glyphs = cx.draw.items(quads.Glyph);
    try testing.expectEqual(@as(usize, 5), glyphs.len);
    try testing.expectApproxEqAbs(hint_alpha, glyphs[0].color[3], 0.0001);
    for (glyphs[1..]) |glyph| try testing.expectEqual(field_icon_w, glyph.clip[0]);
    _ = send(cx, &field, click_at(field_icon_w + 2.4 * 9.6, 0));
    try testing.expectEqual(@as(u32, 2), field.edit.caret);
    try testing.expectEqual(@as(f32, 106 - field_icon_w - field_padding_x), field_inner_lead(
        .{ .x = 0, .y = 0, .width = 106, .height = 24 },
        field_icon_w,
    ).width);
}

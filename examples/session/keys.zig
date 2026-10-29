//! `Keyboard`: a piano of `white_count` white keys from `first_note`, played with the pointer
//! or the computer's keys, the session's own widget.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Geometry
//! White keys are `key_w` wide and the box's height; black keys are `black_w` wide and
//! `black_ratio` of it high, centred on the seam after C, D, F, G, and A. One area covers the
//! whole keyboard and the note under a point is found by geometry (`note_at`), black keys
//! first: one area instead of sixty-one.
//!
//! ## 2. Notes
//! A press holds the note under it; a drag slides to the note under the pointer; a release
//! lets it go. Computer keys play two rows from `row_base` (z s x d c v g b h n j m , l . ; /)
//! and `row_base + 12` (q 2 w 3 e r 5 t 6 y 7 u i 9 o 0 p), the tracker layout; their letters
//! are printed on the keys. A key's release carries no text, so `,` `.` `;` `/` (key `other`)
//! release the last such note.
//!
//! ## 3. TigerStyle Invariants
//! - `held` is a 128-bit set; every loop is bounded by the key count.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const look = @import("look.zig");

const Rect = quads.Rect;

pub const first_note: u8 = 36;
pub const white_count: u32 = 36;
pub const key_w: f32 = 33;
pub const black_w: f32 = 20;
pub const black_ratio: f32 = 0.6;
pub const row_base: u8 = 48;

const lower_row = "zsxdcvgbhnjm,l.;/";
const upper_keys = "q2w3er5t6y7ui9o0p";

const white_fill = [4]f32{ 0.98, 0.98, 0.97, 1 };
const black_fill = [4]f32{ 0.13, 0.13, 0.14, 1 };
const seam = [4]f32{ 0.72, 0.72, 0.72, 1 };
const held_fill = [4]f32{ 0.30, 0.62, 0.90, 1 };
const letter = [4]f32{ 0.55, 0.55, 0.55, 1 };

const flags: ui.Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .pointer };

/// True when `note` is a black key.
pub fn is_black(note: u8) bool {
    return switch (note % 12) {
        1, 3, 6, 8, 10 => true,
        else => false,
    };
}

/// The white keys before `note` counted from `first_note`.
fn white_index(note: u8) u32 {
    assert(note >= first_note);
    var count: u32 = 0;
    var at = first_note;
    while (at < note) : (at += 1) {
        if (!is_black(at)) count += 1;
    }
    return count;
}

pub fn last_note() u8 {
    var note = first_note;
    var whites: u32 = 1;
    while (whites < white_count) {
        note += 1;
        if (!is_black(note)) whites += 1;
    }
    return note;
}

/// The rect of `note` in a keyboard at `rect`.
pub fn key_rect(rect: Rect, note: u8) Rect {
    assert(note >= first_note and note <= last_note());
    const index: f32 = @floatFromInt(white_index(note));
    if (!is_black(note)) return .{ .x = rect.x + index * key_w, .y = rect.y, .width = key_w, .height = rect.height };
    return .{ .x = rect.x + index * key_w - black_w * 0.5, .y = rect.y, .width = black_w, .height = rect.height * black_ratio };
}

/// The note under `(x, y)` in a keyboard at `rect`, black keys first.
pub fn note_at(rect: Rect, x: f32, y: f32) ?u8 {
    if (x < rect.x or y < rect.y or y >= rect.y + rect.height) return null;
    const last = last_note();
    var note = first_note;
    while (note <= last) : (note += 1) {
        if (!is_black(note)) continue;
        const key = key_rect(rect, note);
        if (x >= key.x and x < key.x + key.width and y < key.y + key.height) return note;
    }
    const index: u32 = @intFromFloat(@floor((x - rect.x) / key_w));
    if (index >= white_count) return null;
    note = first_note;
    var whites: u32 = 0;
    while (note <= last) : (note += 1) {
        if (is_black(note)) continue;
        if (whites == index) return note;
        whites += 1;
    }
    return null;
}

/// The note a typed computer key plays.
pub fn note_of_key(byte: u8) ?u8 {
    if (std.mem.indexOfScalar(u8, lower_row, byte)) |at| return row_base + @as(u8, @intCast(at));
    if (std.mem.indexOfScalar(u8, upper_keys, byte)) |at| return row_base + 12 + @as(u8, @intCast(at));
    return null;
}

pub const Keyboard = struct {
    id: ui.Id,
    held: std.StaticBitSet(128) = .empty,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    pointer_note: ?u8 = null,
    other_note: ?u8 = null,

    pub fn handle(self: *Keyboard, cx: anytype, event: input.Event) bool {
        switch (event) {
            .key_down => |press| return self.key(cx, press, true),
            .key_up => |press| return self.key(cx, press, false),
            .window_focus => |focused| {
                if (focused or self.held.count() == 0) return false;
                self.held = .empty;
                cx.redraw();
                return true;
            },
            else => {},
        }
        switch (cx.hit(self.id, event)) {
            .down, .drag => |press| return self.slide(cx, note_at(self.rect, press.x, press.y)),
            .up => return self.slide(cx, null),
            else => return false,
        }
    }

    fn slide(self: *Keyboard, cx: anytype, note: ?u8) bool {
        if (note == self.pointer_note) return false;
        if (self.pointer_note) |old| self.held.unset(old);
        if (note) |new| self.held.set(new);
        self.pointer_note = note;
        cx.redraw();
        return true;
    }

    fn key(self: *Keyboard, cx: anytype, press: input.KeyPress, down: bool) bool {
        if (press.mods.shortcut() or press.repeat) return false;
        var byte: u8 = 0;
        if (down and press.len == 1) byte = std.ascii.toLower(press.text[0]);
        if (!down) byte = switch (press.key) {
            .other => 0,
            else => letter_of(press.key) orelse return false,
        };
        const note = if (byte != 0) note_of_key(byte) orelse return false else self.other_note orelse return false;
        if (down and press.key == .other) self.other_note = note;
        if (down == self.held.isSet(note)) return false;
        self.held.setValue(note, down);
        cx.redraw();
        return true;
    }

    /// Draws the keys in `rect` and records the keyboard's area.
    pub fn draw(self: *Keyboard, cx: anytype, rect: Rect) void {
        self.rect = rect;
        const clip = cx.visible(rect) orelse return;
        const last = last_note();
        var note = first_note;
        while (note <= last) : (note += 1) {
            if (is_black(note)) continue;
            const face = key_rect(rect, note);
            const fill = if (self.held.isSet(note)) held_fill else white_fill;
            kit.face(cx, face, clip, .{ .fill = fill, .border_color = seam, .border_width = 0.5 });
        }
        note = first_note;
        while (note <= last) : (note += 1) {
            if (!is_black(note)) continue;
            const face = key_rect(rect, note);
            const fill = if (self.held.isSet(note)) held_fill else black_fill;
            kit.face(cx, face, clip, .{ .fill = fill, .radius = 1.5 });
        }
        self.letters(cx, rect, clip);
        cx.area(self.id, rect, 0, flags);
    }

    fn letters(self: *const Keyboard, cx: anytype, rect: Rect, clip: quads.Clip) void {
        _ = self;
        const s = look.style(.serif, 9, letter);
        for (lower_row, 0..) |byte, index| {
            label_key(cx, rect, row_base + @as(u8, @intCast(index)), byte, 0, s, clip);
        }
        for (upper_keys, 0..) |byte, index| {
            label_key(cx, rect, row_base + 12 + @as(u8, @intCast(index)), byte, 1, s, clip);
        }
    }
};

fn label_key(cx: anytype, rect: Rect, note: u8, byte: u8, row: u32, s: patchwork.text.Style, clip: quads.Clip) void {
    const key = key_rect(rect, note);
    const lift: f32 = @as(f32, @floatFromInt(row)) * 11;
    const bottom = key.y + key.height - 4 - lift;
    const box: Rect = .{ .x = key.x, .y = bottom - 10, .width = key.width, .height = 10 };
    var color = s;
    if (is_black(note)) color.color = .{ 0.75, 0.75, 0.75, 1 };
    kit.label(cx, color, &.{byte}, box, clip, look.centered);
}

/// The lowercase letter of a letter or digit key, or null.
fn letter_of(key: input.Key) ?u8 {
    const name = @tagName(key);
    if (name.len == 2 and name[0] == 'd' and std.ascii.isDigit(name[1])) return name[1];
    if (name.len != 1) return null;
    return name[0];
}

comptime {
    assert(lower_row.len == 17 and upper_keys.len == 17);
}

// Locks the keyboard's span and hit geometry: 36 white keys from C2 end on C7 (96); x 0 is
// C2, the seam after C2 near the top is C#2, the same x low on the key is C2 again, and the
// tracker rows map z to C3 and q to C4.
test "keyboard geometry and keys" {
    try std.testing.expectEqual(@as(u8, 96), last_note());
    const rect: Rect = .{ .x = 0, .y = 0, .width = key_w * white_count, .height = 50 };
    try std.testing.expectEqual(@as(?u8, 36), note_at(rect, 1, 40));
    try std.testing.expectEqual(@as(?u8, 37), note_at(rect, key_w, 10));
    try std.testing.expectEqual(@as(?u8, 36), note_at(rect, key_w - 2, 45));
    try std.testing.expectEqual(@as(?u8, 48), note_of_key('z'));
    try std.testing.expectEqual(@as(?u8, 60), note_of_key('q'));
    try std.testing.expectEqual(@as(?u8, 64), note_of_key('/'));
}

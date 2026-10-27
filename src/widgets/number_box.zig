//! `NumberBox`: a value with a unit, changed by a vertical drag or the wheel, or typed in.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Model
//! The value is an `f64` in `[min, max]`, optionally quantised to `step` (0 is continuous),
//! shown with `format.decimals` digits after the point and `format.unit` (" Hz", " dB"). f64
//! because a long drag over a wide range in fine steps adds many small deltas; it costs
//! nothing here and does not drift. Values stay within `number_abs_max` (eight integer digits)
//! so the text fits `number_text_cap` bytes.
//!
//! ## 2. Events
//! ```text
//! drag (vertical, relative)  value += -dy * (max - min) / number_drag_px * scale
//!                            scale 0.1 with Shift (fine), 10 with Ctrl or Meta (coarse)
//! wheel                      one step per event (1% of the range when step is 0); up adds
//! double press               edit: the field loads the value without the unit, all selected
//! right press                reset to `default`
//! Enter / focus lost         parse; a number is clamped and `committed`, anything else keeps
//!                            the old value
//! Escape                     cancel the edit
//! ```
//! A drag accumulates into `drag_value` and quantises from it, so steps smaller than a pixel's
//! worth still add up. The drag is vertical only, like the knob, so a column of boxes stays
//! dense. A wheel event is one notch whatever its delta: hosts disagree on a notch's pixels.
//!
//! ## 3. Text
//! `format` writes into a fixed `[number_text_cap]u8` with no allocation: an optional sign
//! (never on a value that rounds to zero), the integer digits, the point and `decimals`
//! digits (rounded half away from zero), then the unit. `parse` reads an optional sign,
//! digits, and an optional fraction, with spaces around; anything else (an exponent, a unit,
//! a second point, no digit) is null. Both are pure and freestanding: no locale, no
//! `std.fmt`, so the wasm build carries no float formatting.
//!
//! ## 4. Drawing
//! `NumberBoxOf(Skin)` hands `Skin.number_face` a `NumberLook` and records the hit shape it
//! returns (the wheel and the vertical resize cursor); while editing, its `TextFieldOf(Skin)`
//! draws in its place instead. `NumberBox` is `NumberBoxOf(skins.Default)`: a field-like face,
//! the value right-aligned in the mono value style, and the unit dimmer.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation; `format` and `parse` loop at most `number_text_cap` times.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const text_field = @import("text_field.zig");

const Walk = kit.Walk;
const Id = kit.Id;

/// Bytes a formatted value takes at most: a sign, eight digits, the point, six decimals, and
/// an eight-byte unit.
pub const number_text_cap: u32 = 24;

/// Decimals and unit bytes a format takes at most.
pub const decimals_max: u8 = 6;
pub const unit_cap: u32 = 8;

/// The largest magnitude a number box holds: eight integer digits.
pub const number_abs_max: f64 = 99_999_999;

/// Drag distance, in logical pixels, that covers the whole range.
pub const number_drag_px: f32 = 200;

/// The drag's scale with Shift (fine) and with Ctrl or Meta (coarse).
pub const fine_scale: f64 = 0.1;
pub const coarse_scale: f64 = 10;

/// A wheel event's change when `step` is 0: this fraction of the range.
pub const wheel_fraction: f64 = 0.01;

/// The salt of the editing field's id: `id.derive(field_salt)`.
pub const field_salt: u64 = 0x6669656c64;

/// The default face's corner radius, text inset, and the unit's alpha.
pub const number_radius: f32 = 4;
pub const number_pad_x: f32 = 8;
pub const number_unit_alpha: f32 = 0.6;

/// The value and unit sit at the right, centered vertically, cut when too wide.
pub const number_text_options: text.Options = .{
    .align_x = .end,
    .align_y = .center,
    .ellipsis = true,
};

/// The face takes the wheel and shows the vertical resize cursor.
pub const number_flags: ui.Flags = .{
    .wheel = true,
    .focusable = false,
    .tab = false,
    .cursor = .ns_resize,
};

/// How a value is shown: `decimals` (at most `decimals_max`) digits after the point, then
/// `unit` (at most `unit_cap` bytes, app-owned).
pub const Format = struct {
    decimals: u8,
    unit: []const u8,
};

/// Powers of ten, exact in f64 up to 10^22; `parse` uses up to 10^17.
const powers = blk: {
    var table: [18]f64 = undefined;
    var value: f64 = 1;
    for (&table) |*slot| {
        slot.* = value;
        value *= 10;
    }
    break :blk table;
};

/// Writes `value` with `decimals` digits after the point and then `unit` into `out` (section
/// 3); returns the written prefix.
pub fn format(out: *[number_text_cap]u8, value: f64, decimals: u8, unit: []const u8) []const u8 {
    assert(decimals <= decimals_max);
    assert(unit.len <= unit_cap);
    assert(@abs(value) <= number_abs_max);
    const scale: u64 = @intFromFloat(powers[decimals]);
    const scaled: u64 = @intFromFloat(@round(@abs(value) * powers[decimals]));
    var at: usize = 0;
    if (value < 0 and scaled != 0) {
        out[at] = '-';
        at += 1;
    }
    const whole = scaled / scale;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = whole;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        out[at] = digits[count];
        at += 1;
    }
    if (decimals > 0) {
        out[at] = '.';
        at += 1;
        var fraction = scaled % scale;
        var place: usize = decimals;
        while (place > 0) {
            place -= 1;
            out[at + place] = '0' + @as(u8, @intCast(fraction % 10));
            fraction /= 10;
        }
        at += decimals;
    }
    @memcpy(out[at..][0..unit.len], unit);
    at += unit.len;
    assert(at <= number_text_cap);
    return out[0..at];
}

/// The number in `bytes` (section 3), or null when it is not one.
pub fn parse(bytes: []const u8) ?f64 {
    var start: usize = 0;
    var end = bytes.len;
    while (start < end and bytes[start] == ' ') start += 1;
    while (end > start and bytes[end - 1] == ' ') end -= 1;
    const body = bytes[start..end];
    if (body.len == 0 or body.len > number_text_cap) return null;
    var at: usize = 0;
    var negative = false;
    if (body[0] == '-' or body[0] == '+') {
        negative = body[0] == '-';
        at = 1;
    }
    var whole: f64 = 0;
    var digits: usize = 0;
    while (at < body.len and body[at] >= '0' and body[at] <= '9') : (at += 1) {
        whole = whole * 10 + @as(f64, @floatFromInt(body[at] - '0'));
        digits += 1;
    }
    var fraction: f64 = 0;
    var places: usize = 0;
    if (at < body.len and body[at] == '.') {
        at += 1;
        while (at < body.len and body[at] >= '0' and body[at] <= '9') : (at += 1) {
            fraction = fraction * 10 + @as(f64, @floatFromInt(body[at] - '0'));
            places += 1;
        }
    }
    if (at != body.len) return null;
    if (digits + places == 0) return null;
    if (digits + places >= powers.len) return null;
    const magnitude = whole + fraction / powers[places];
    assert(magnitude >= 0);
    return if (negative) -magnitude else magnitude;
}

/// `value` on the grid `min + k * step` (unless `step` is 0), clamped to `[min, max]`.
pub fn quantize(value: f64, min: f64, max: f64, step: f64) f64 {
    assert(min <= max);
    assert(step >= 0);
    const snapped = if (step > 0) min + @round((value - min) / step) * step else value;
    const result = std.math.clamp(snapped, min, max);
    assert(result >= min and result <= max);
    return result;
}

/// The default number box: `NumberBoxOf(skins.Default)`.
pub const NumberBox = NumberBoxOf(skin.Default);

/// A number box drawn by `Skin` (`Skin.number_face`, and `Skin.field` while editing).
pub fn NumberBoxOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .number_box)) |problem| @compileError(problem);
    const Field = text_field.TextFieldOf(Skin);
    return struct {
        const Self = @This();

        id: Id,
        value: f64,
        min: f64,
        max: f64,
        /// The grid values snap to while dragging and on the wheel; 0 is continuous.
        step: f64,
        /// The value a right press restores: the value at `init`.
        default: f64,
        format: Format,
        /// The editor shown while `editing`.
        field: Field,
        editing: bool,
        hover: animator.Animator,
        /// The pointer's last y and the unquantised value of the current drag.
        drag_y: f32,
        drag_value: f64,

        pub const Action = union(enum) {
            none,
            /// A drag, the wheel, or a reset changed the value.
            changed: f64,
            /// A typed value was entered.
            committed: f64,
        };

        /// A box at `value` (also its default) in `[min, max]`.
        pub fn init(id: Id, value: f64, min: f64, max: f64, step: f64, shown: Format) Self {
            assert(id != .none);
            assert(min < max);
            assert(@abs(min) <= number_abs_max and @abs(max) <= number_abs_max);
            assert(value >= min and value <= max);
            assert(step >= 0 and step <= max - min);
            assert(shown.decimals <= decimals_max and shown.unit.len <= unit_cap);
            return .{
                .id = id,
                .value = value,
                .min = min,
                .max = max,
                .step = step,
                .default = value,
                .format = shown,
                .field = Field.init(id.derive(field_salt), number_text_cap, theme.dark.value),
                .editing = false,
                .hover = .init(kit.hover_rate_per_ms),
                .drag_y = 0,
                .drag_value = value,
            };
        }

        /// The value as shown, with its unit, written into `out`.
        pub fn text_of(self: *const Self, out: *[number_text_cap]u8) []const u8 {
            return format(out, self.value, self.format.decimals, self.format.unit);
        }

        /// Hands the box `walk` gets to the skin and records the shape it returns; while
        /// editing, the field draws there instead.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.value >= self.min and self.value <= self.max);
            if (self.editing) return self.field.draw(cx, walk);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            var bytes: [number_text_cap]u8 = undefined;
            const shown = format(&bytes, self.value, self.format.decimals, "");
            const shape = Skin.number_face(cx, .{
                .rect = rect,
                .clip = clip,
                .value_text = shown,
                .unit = self.format.unit,
                .hover = self.hover.value,
            }) orelse return;
            cx.area(self.id, shape.rect, shape.radius, number_flags);
        }

        /// Drag, wheel, double press, right press, and the edit (section 2).
        pub fn handle(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.id != .none);
            assert(self.value >= self.min and self.value <= self.max);
            if (event == .frame) {
                kit.step(cx, &self.hover, event.frame);
                return .none;
            }
            if (self.editing) return self.edit_event(cx, event);
            const hit = cx.hit(self.id, event);
            kit.respond(cx, hit, &self.hover, null);
            switch (hit) {
                .down => |press| {
                    if (press.clicks >= 2) {
                        self.start_edit(cx);
                        return .none;
                    }
                    self.drag_y = press.y;
                    self.drag_value = self.value;
                    return .none;
                },
                .drag => |press| {
                    const dy: f64 = press.y - self.drag_y;
                    self.drag_y = press.y;
                    const scale: f64 = if (press.mods.shift)
                        fine_scale
                    else if (press.mods.shortcut())
                        coarse_scale
                    else
                        1;
                    const span = self.max - self.min;
                    const moved = self.drag_value - dy * span / number_drag_px * scale;
                    self.drag_value = std.math.clamp(moved, self.min, self.max);
                    return self.set(cx, self.drag_value);
                },
                .wheel => |wheel| {
                    if (wheel.dy == 0) return .none;
                    kit.aim(cx, &self.hover, 1);
                    const span = self.max - self.min;
                    const notch = if (self.step > 0) self.step else span * wheel_fraction;
                    const next = if (wheel.dy < 0) self.value + notch else self.value - notch;
                    return self.set(cx, next);
                },
                .secondary => {
                    kit.aim(cx, &self.hover, 1);
                    return self.set(cx, self.default);
                },
                .none, .hover_in, .hover_out, .up => return .none,
            }
        }

        /// Opens the editor: the value without its unit, all selected, focused.
        fn start_edit(self: *Self, cx: anytype) void {
            assert(!self.editing);
            var bytes: [number_text_cap]u8 = undefined;
            self.field.style = cx.theme().value;
            self.field.load(format(&bytes, self.value, self.format.decimals, ""));
            // The face is not drawn while editing, so it gets no hover_out: let go now.
            kit.aim(cx, &self.hover, 0);
            self.editing = true;
            cx.set_focus(self.field.id);
            cx.redraw();
        }

        fn edit_event(self: *Self, cx: anytype, event: input.Event) Action {
            assert(self.editing);
            switch (self.field.handle(cx, event)) {
                .none, .changed => return .none,
                .cancelled => {
                    self.editing = false;
                    cx.redraw();
                    return .none;
                },
                .committed => {
                    self.editing = false;
                    cx.redraw();
                    const entered = parse(self.field.bytes()) orelse return .none;
                    self.value = std.math.clamp(entered, self.min, self.max);
                    return .{ .committed = self.value };
                },
            }
        }

        /// Quantises and clamps `next`; `changed` when the value moved.
        fn set(self: *Self, cx: anytype, next: f64) Action {
            const value = quantize(next, self.min, self.max, self.step);
            if (value == self.value) return .none;
            self.value = value;
            cx.redraw();
            return .{ .changed = value };
        }
    };
}

comptime {
    assert(1 + 8 + 1 + decimals_max + unit_cap == number_text_cap);
    assert(number_abs_max < powers[8]);
    assert(field_salt != ui.view.thumb_salt);
}

const testing = std.testing;
const draw = @import("../draw.zig");
const fixture = @import("fixture.zig");

fn formatted(value: f64, decimals: u8, unit: []const u8) []const u8 {
    const static = struct {
        var bytes: [number_text_cap]u8 = undefined;
    };
    return format(&static.bytes, value, decimals, unit);
}

// Locks `format` (section 3): one decimal and a unit, a negative value, rounding half away from
// zero at the last decimal, no sign on a value that rounds to zero, no point at 0 decimals,
// zero-padded decimals, and the widest text, 24 bytes.
test "format writes the value, its decimals, and its unit" {
    try testing.expectEqualStrings("440.0 Hz", formatted(440.0, 1, " Hz"));
    try testing.expectEqualStrings("-6.5 dB", formatted(-6.5, 1, " dB"));
    try testing.expectEqualStrings("1.3", formatted(1.25, 1, ""));
    try testing.expectEqualStrings("-1.3", formatted(-1.25, 1, ""));
    try testing.expectEqualStrings("0.0", formatted(-0.04, 1, ""));
    try testing.expectEqualStrings("20000 Hz", formatted(20000, 0, " Hz"));
    try testing.expectEqualStrings("0.050", formatted(0.05, 3, ""));
    try testing.expectEqualStrings("0", formatted(0, 0, ""));
    const widest = formatted(-number_abs_max, 6, " samples");
    try testing.expectEqualStrings("-99999999.000000 samples", widest);
    try testing.expectEqual(@as(usize, number_text_cap), widest.len);
}

// Locks `parse` (section 3): signs, a bare fraction, a trailing point, spaces around, and the
// refusals: empty, a lone sign or point, a second point, letters, a unit, an exponent.
test "parse reads a decimal and refuses anything else" {
    try testing.expectEqual(@as(?f64, -6.5), parse("-6.5"));
    try testing.expectEqual(@as(?f64, 440), parse("440"));
    try testing.expectEqual(@as(?f64, 0.5), parse(".5"));
    try testing.expectEqual(@as(?f64, 3), parse("+3."));
    try testing.expectEqual(@as(?f64, 12.25), parse("  12.25 "));
    for ([_][]const u8{ "", " ", "-", ".", "1.2.3", "abc", "5 Hz", "1e3", "--1", "1-" }) |bad| {
        try testing.expectEqual(@as(?f64, null), parse(bad));
    }
}

// Locks `quantize`: to the grid from `min`, then clamped; a step of 0 only clamps.
test "quantize snaps to the step grid and clamps" {
    try testing.expectEqual(@as(f64, 1.0), quantize(1.08, -60, 12, 0.5));
    try testing.expectEqual(@as(f64, -59.5), quantize(-59.3, -60, 12, 0.5));
    try testing.expectEqual(@as(f64, 12), quantize(40, -60, 12, 0.5));
    try testing.expectEqual(@as(f64, 440.25), quantize(440.25, 20, 20000, 0));
}

fn frequency() NumberBox {
    return NumberBox.init(ui.id("freq", 0), 440, 20, 20000, 0, .{ .decimals = 1, .unit = " Hz" });
}

fn draw_box(cx: *fixture.Context, number: *const NumberBox) void {
    fixture.draw_one(cx, number, fixture.at(0, 0, 160, 32));
}

fn button(x: f32, y: f32, time_ms: u32, mods: input.Mods, down: bool) input.Event {
    const sample: input.Button = .{
        .x = x,
        .y = y,
        .time_ms = time_ms,
        .button = .left,
        .mods = mods,
    };
    return if (down) .{ .pointer_down = sample } else .{ .pointer_up = sample };
}

/// Drags `number` from (80, 16) by `dy` with `mods`, at `time_ms`; returns the drag's action.
fn drag(
    cx: *fixture.Context,
    number: *NumberBox,
    dy: f32,
    mods: input.Mods,
    time_ms: u32,
) NumberBox.Action {
    _ = fixture.send(cx, number, button(80, 16, time_ms, mods, true));
    const action = fixture.send(cx, number, .{ .pointer_move = .{ .x = 80, .y = 16 + dy } });
    _ = fixture.send(cx, number, button(80, 16 + dy, time_ms, mods, false));
    return action;
}

// Locks the drag of section 2 on 20 to 20000 Hz: up 40 px adds 40 * 19980 / 200 = 3996 (440 to
// 4436); with Shift a tenth (399.6); with Ctrl ten times, clamped at 20000; on a 0.5 dB grid
// up 3 px is 1.08 dB, snapped to 1.0. The face records a wheel area with the ns_resize cursor
// and draws the value and the unit.
test "a number box drags relative, fine, coarse, and on its grid" {
    const cx = fixture.context();
    var number = frequency();
    draw_box(cx, &number);
    const area = cx.find(number.id).?;
    try testing.expect(area.flags.wheel);
    try testing.expectEqual(ui.Cursor.ns_resize, area.flags.cursor);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 8 - 1), cx.draw.items(draw.Glyph).len);
    try testing.expectEqual(NumberBox.Action{ .changed = 4436 }, drag(cx, &number, -40, .none, 0));
    var shift = input.Mods.none;
    shift.shift = true;
    const fine = drag(cx, &number, -40, shift, 1000);
    try testing.expectApproxEqAbs(@as(f64, 4436 + 399.6), fine.changed, 1e-9);
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    const top: NumberBox.Action = .{ .changed = 20000 };
    try testing.expectEqual(top, drag(cx, &number, -40, ctrl, 2000));
    var gain = NumberBox.init(ui.id("freq", 0), 0, -60, 12, 0.5, .{ .decimals = 1, .unit = " dB" });
    draw_box(cx, &gain);
    try testing.expectEqual(NumberBox.Action{ .changed = 1.0 }, drag(cx, &gain, -3, .none, 3000));
    try testing.expectEqual(@as(u32, 0), cx.draw.overflow_count);
}

// Locks the wheel and the reset (section 2): a wheel up adds one step (0.5 dB), a wheel down
// takes one away, a step of 0 moves 1% of the range (199.8 Hz); a right press restores the
// default and a second one changes nothing.
test "a number box wheels one step and resets on a right press" {
    const cx = fixture.context();
    var gain = NumberBox.init(ui.id("gain", 0), 0, -60, 12, 0.5, .{ .decimals = 1, .unit = " dB" });
    draw_box(cx, &gain);
    const up: input.Event = .{ .wheel = .{ .x = 80, .y = 16, .dx = 0, .dy = -120 } };
    const down: input.Event = .{ .wheel = .{ .x = 80, .y = 16, .dx = 0, .dy = 3 } };
    try testing.expectEqual(NumberBox.Action{ .changed = 0.5 }, fixture.send(cx, &gain, up));
    _ = fixture.send(cx, &gain, up);
    try testing.expectEqual(NumberBox.Action{ .changed = 0.5 }, fixture.send(cx, &gain, down));
    var number = frequency();
    draw_box(cx, &number);
    const notched = fixture.send(cx, &number, up).changed;
    try testing.expectApproxEqAbs(@as(f64, 440 + 199.8), notched, 1e-9);
    var press = input.left_at(.{ .x = 80, .y = 16 });
    press.button = .right;
    const right: input.Event = .{ .pointer_down = press };
    try testing.expectEqual(NumberBox.Action{ .changed = 440 }, fixture.send(cx, &number, right));
    try testing.expectEqual(NumberBox.Action.none, fixture.send(cx, &number, right));
}

fn typed(key: input.Key, utf8: []const u8) input.Event {
    return .{ .key_down = input.key_press(key, .none, false, utf8) };
}

/// Double-clicks `number` at `time_ms`, opening its editor.
fn double_click(cx: *fixture.Context, number: *NumberBox, time_ms: u32) void {
    _ = fixture.send(cx, number, button(80, 16, time_ms, .none, true));
    _ = fixture.send(cx, number, button(80, 16, time_ms, .none, false));
    _ = fixture.send(cx, number, button(80, 16, time_ms + 100, .none, true));
    _ = fixture.send(cx, number, button(80, 16, time_ms + 100, .none, false));
}

// Locks typing (section 2): a double click opens the field with "0.0" all selected and
// focused, and the field draws in the face's place; typing "-6.5" and Enter commits -6.5;
// Escape cancels; text that is not a number keeps the old value; a typed value past the range
// is clamped; the editor's field routes through `ui.route` with the box.
test "a number box edits on a double click and commits on Enter" {
    const cx = fixture.context();
    const Holder = struct { gain: NumberBox };
    const decibels: Format = .{ .decimals = 1, .unit = " dB" };
    var holder: Holder = .{ .gain = NumberBox.init(ui.id("gain", 0), 0, -60, 12, 0.5, decibels) };
    const gain = &holder.gain;
    draw_box(cx, gain);
    double_click(cx, gain, 0);
    try testing.expect(gain.editing);
    try testing.expectEqual(@as(f32, 0), gain.hover.target);
    try testing.expectEqualStrings("0.0", gain.field.bytes());
    try testing.expectEqualStrings("0.0", gain.field.edit.selected());
    try testing.expect(cx.focused(gain.field.id));
    draw_box(cx, gain);
    try testing.expect(cx.find(gain.field.id) != null);
    try testing.expect(cx.find(gain.id) == null);
    const keys = [_]input.Event{
        typed(.other, "-"),
        typed(.d6, "6"),
        typed(.other, "."),
        typed(.d5, "5"),
    };
    for (keys) |key| {
        cx.event_begin(key);
        _ = ui.route(cx, key, &holder);
        cx.event_end();
    }
    try testing.expectEqualStrings("-6.5", gain.field.bytes());
    const entered: NumberBox.Action = .{ .committed = -6.5 };
    try testing.expectEqual(entered, fixture.send(cx, gain, typed(.enter, "")));
    try testing.expect(!gain.editing);
    draw_box(cx, gain);
    double_click(cx, gain, 1000);
    _ = fixture.send(cx, gain, typed(.d9, "9"));
    try testing.expectEqual(NumberBox.Action.none, fixture.send(cx, gain, typed(.escape, "")));
    try testing.expectEqual(@as(f64, -6.5), gain.value);
    draw_box(cx, gain);
    double_click(cx, gain, 2000);
    _ = fixture.send(cx, gain, typed(.x, "x"));
    try testing.expectEqual(NumberBox.Action.none, fixture.send(cx, gain, typed(.enter, "")));
    try testing.expectEqual(@as(f64, -6.5), gain.value);
    draw_box(cx, gain);
    double_click(cx, gain, 3000);
    _ = fixture.send(cx, gain, typed(.d9, "9"));
    _ = fixture.send(cx, gain, typed(.d9, "9"));
    const clamped: NumberBox.Action = .{ .committed = 12 };
    try testing.expectEqual(clamped, fixture.send(cx, gain, typed(.enter, "")));
}

//! The widget kit: the building blocks every library widget is made of, public so an app's own
//! widget is made of the same ones.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Kit
//! A widget appends records, places text, eases animators, and reacts to hover and press. Up
//! to step 29 those helpers were private to `widgets.zig`, so an app writing its own control
//! copied them (`examples/live/knob.zig` had its own `append_arc`, the rack its own
//! `append_or_skip`, the live app its own `push_box`). The kit is those helpers, public:
//! ```text
//! append(cx, T, texture, record)   append; skip on a full pool or batch list (counted)
//! face(cx, rect, clip, BoxLook)    a draw.Box, skipped when rect has a non-positive edge
//! arc(cx, ring, clip, ArcLook)     a draw.Arc
//! surface(cx, rect, clip, SurfaceLook)  a draw.Surface: gradient, rim, shadow; empty skipped
//! lit(look, scheme, hover, down)   a SurfaceLook's colours mixed as a Box's are on the GPU
//! label(cx, style, bytes, rect, clip, options)   text.place with the kit's asserts
//! paragraph(cx, style, bytes, rect, clip, wrap)  text.place_wrapped, label's wrapped twin
//! icon(cx, face, codepoint, size, rect, clip, color)  text.icon: one glyph centred by its ink
//! step(cx, *Animator, dt_ms)       a moved value redraws, a live one keeps animating
//! aim(cx, *Animator, target)       a new target redraws
//! weight(amount, scale)            an animator value scaled to a shader mix weight
//! clicked(cx, id, event)           a row that clicks on an inside release
//! respond / Interaction            the hover and press table (section 3)
//! accent(cx, index)                the app scheme's accent `index` as a `Paint`
//! ```
//! It sits under `widgets` because it carries the widgets' look (`Paint`, the dark defaults);
//! `ui` and `draw` never import it and use `draw.Box.of` with their own skip.
//!
//! ## 2. Appending
//! `append` skips an instance whose pool or batch list is full; the draw context counts the
//! drop in `overflow_count`, and app tests assert it is zero. A non-positive edge or an
//! unordered clip is a caller bug, asserted before the call and `unreachable` after it, so a
//! caller that may compute an empty rect uses `face`, which returns first.
//!
//! ## 3. Hover and Press
//! An `Animator` travels over `[0, 1]`; a widget scales it before writing an instance:
//! ```text
//! hover_weight = hover.value * scheme.hover_lighten
//! down_weight  = down.value  * scheme.down_darken      (applied after the hover mix)
//! ```
//! `Paint.look(scheme, hover, down)` applies both, with the app's `cx.theme()` as `scheme`;
//! `hover_lighten` and `down_darken` are the dark scheme's, kept for code that names them.
//! `respond(cx, hit, hover, down)` aims the pair from one hit; `Interaction` stores the pair
//! and calls it:
//! ```text
//! hit          hover   down
//! hover_in     1       -
//! hover_out    0       -
//! down         1       1
//! up inside    -       0
//! up outside   0       0
//! drag, wheel, secondary, none: no change
//! ```
//! A `draw.Surface` has no hover or press weights (its record is full), so `lit(look, scheme,
//! hover, down)` applies the same two mixes to its colours on the CPU before `surface`:
//! ```text
//! rgb = mix(mix(rgb, lighten.rgb, hover * scheme.hover_lighten), darken.rgb,
//!           down * scheme.down_darken)        for fill, fill_to, and border; alpha kept
//! ```
//! so a surface lights and darkens exactly as a `Box` face does.
//!
//! A widget without a press channel passes no `down`. A widget that lightens on the wheel or
//! a right press aims `hover` itself. Test "respond follows the table row by row".
//!
//! ## 4. TigerStyle Invariants
//! - No allocation and no state: every function works on the caller's records and animators.
//! - Geometry reaching `append` is positive and ordered (asserted).

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const draw = @import("../draw.zig");
const text = @import("../text.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const ui = @import("../ui.zig");

pub const Rect = draw.Rect;
pub const Clip = draw.Clip;
pub const Inset = draw.Inset;
pub const Walk = ui.Walk;
pub const Id = ui.Id;
pub const Animator = animator.Animator;
pub const BoxLook = draw.BoxLook;
pub const ArcLook = draw.ArcLook;
pub const SurfaceLook = draw.SurfaceLook;

/// The dark scheme's shader mix toward white at animator value 1. Widgets read the app's
/// (`cx.theme().hover_lighten`).
pub const hover_lighten: f32 = theme.dark.hover_lighten;

/// The dark scheme's shader mix toward black at animator value 1, applied after the lighten.
/// Widgets read the app's (`cx.theme().down_darken`).
pub const down_darken: f32 = theme.dark.down_darken;

/// The corner radius of an accent `Paint`: the knob ring's stroke, which `knob.zig` asserts.
pub const accent_radius: f32 = 4;

/// Wall time for hover to travel the unit range.
pub const hover_duration_ms: f32 = 100;

/// Wall time for the press darken to travel the unit range.
pub const down_duration_ms: f32 = 50;

/// Fraction of the unit range covered in one millisecond of hover.
pub const hover_rate_per_ms: f32 = 1.0 / hover_duration_ms;

/// Fraction of the unit range covered in one millisecond of press.
pub const down_rate_per_ms: f32 = 1.0 / down_duration_ms;

/// Fill and corner radius copied onto each instance a widget appends.
pub const Paint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,

    /// The box look of this paint at the animator values `hover` and `down`, each scaled to
    /// its mix weight in `scheme` (section 3).
    pub fn look(self: Paint, scheme: *const theme.Scheme, hover: f32, down: f32) BoxLook {
        assert(self.radius >= 0);
        assert(self.a >= 0);
        return .{
            .fill = .{ self.r, self.g, self.b, self.a },
            .radius = self.radius,
            .hover = weight(hover, scheme.hover_lighten),
            .down = weight(down, scheme.down_darken),
        };
    }
};

/// The dark scheme's control names beside a ring, meter, or pill. Widgets read the app's
/// (`cx.theme().name`).
pub const name_style: text.Style = theme.dark.name;

/// The dark scheme's knob value readouts: monospace, so the digits do not shift as the value
/// changes. Widgets read the app's (`cx.theme().value`).
pub const value_style: text.Style = theme.dark.value;

/// Text centered on both axes, without an ellipsis.
pub const centered: text.Options = .{
    .align_x = .center,
    .align_y = .center,
    .ellipsis = false,
};

pub fn paint_of(color: [4]f32, radius: f32) Paint {
    assert(radius >= 0);
    assert(color[3] >= 0);
    const paint: Paint = .{
        .r = color[0],
        .g = color[1],
        .b = color[2],
        .a = color[3],
        .radius = radius,
    };
    assert(paint.radius == radius);
    assert(paint.a == color[3]);
    return paint;
}

/// The app scheme's accent `index` (cycled modulo `theme.accent_count`) as a paint with
/// `accent_radius`, for an app that wants its knob accents to follow the theme. Reads
/// `cx.theme()`, so it works in any phase.
pub fn accent(cx: anytype, index: u32) Paint {
    const scheme = cx.theme();
    const paint = paint_of(scheme.accents[index % theme.accent_count], accent_radius);
    assert(paint.radius == accent_radius);
    assert(paint.a >= 0);
    return paint;
}

/// An animator resting at 0, or at 1 when `at_end`.
pub fn settled(rate: f32, at_end: bool) Animator {
    var value = Animator.init(rate);
    if (at_end) {
        value.value = 1;
        value.target = 1;
    }
    assert(!value.live());
    assert(value.rate_per_ms == rate);
    return value;
}

/// Appends `record` of draw type `T` (sampling `texture`, null for an untextured type)
/// through the UI context `cx`, skipping it when its pool or the batch list is full; the
/// context counts the drop (section 2). `record` has a positive rect and an ordered clip.
pub fn append(cx: anytype, comptime T: type, texture: ?draw.TextureId, record: T) void {
    assert(record.rect[2] > 0);
    assert(record.rect[3] > 0);
    assert(record.clip[2] > record.clip[0]);
    assert(record.clip[3] > record.clip[1]);
    cx.append(T, texture, record) catch |err| switch (err) {
        error.PoolFull, error.BatchFull => {},
        error.EdgeNotPositive, error.ClipUnordered => unreachable,
    };
}

/// A `draw.Box` over `rect` under `clip`; nothing when `rect` has a non-positive edge.
pub fn face(cx: anytype, rect: Rect, clip: Clip, look: BoxLook) void {
    assert(look.radius >= 0);
    assert(clip.x1 > clip.x0);
    if (!(rect.width > 0)) return;
    if (!(rect.height > 0)) return;
    append(cx, draw.Box, null, draw.Box.of(rect, clip, look));
}

/// A `draw.Surface` whose shape is `rect`, under `clip` (`draw/types.zig`, section 6). Its
/// shadow reaches past `rect` and is cut by `clip`, so pass the parent's clip, not one of
/// `rect` itself. A rect with a non-positive edge appends nothing.
pub fn surface(cx: anytype, rect: Rect, clip: Clip, look: SurfaceLook) void {
    assert(look.radius >= 0);
    assert(clip.x1 > clip.x0);
    if (!(rect.width > 0)) return;
    if (!(rect.height > 0)) return;
    append(cx, draw.Surface, null, draw.Surface.of(rect, clip, look));
}

/// `look` at the animator values `hover` and `down`: its fill, end stop, and border mixed
/// toward `scheme.colors.lighten` and then `darken` by the scheme's weights, as `Box`'s shader
/// mixes (section 3). Alphas, the gradient, and the shadow are unchanged; 0 and 0 return `look`.
pub fn lit(look: SurfaceLook, scheme: *const theme.Scheme, hover: f32, down: f32) SurfaceLook {
    const lighten = weight(hover, scheme.hover_lighten);
    const darken = weight(down, scheme.down_darken);
    var out = look;
    out.fill = mix_toward(look.fill, scheme.colors.lighten, scheme.colors.darken, lighten, darken);
    if (look.fill_to) |end| {
        out.fill_to = mix_toward(end, scheme.colors.lighten, scheme.colors.darken, lighten, darken);
    }
    out.border = mix_toward(look.border, scheme.colors.lighten, scheme.colors.darken, lighten, darken);
    assert(out.fill[3] == look.fill[3]);
    return out;
}

/// `color`'s rgb mixed toward `light` by `toward_light`, then toward `dark` by `toward_dark`.
fn mix_toward(color: [4]f32, light: [4]f32, dark: [4]f32, toward_light: f32, toward_dark: f32) [4]f32 {
    assert(toward_light >= 0 and toward_light <= 1);
    assert(toward_dark >= 0 and toward_dark <= 1);
    var out = color;
    for (0..3) |i| {
        const lifted = color[i] + (light[i] - color[i]) * toward_light;
        out[i] = lifted + (dark[i] - lifted) * toward_dark;
    }
    return out;
}

/// A `draw.Arc` inscribed in the square `ring` under `clip`.
pub fn arc(cx: anytype, ring: Rect, clip: Clip, look: ArcLook) void {
    assert(ring.width == ring.height);
    assert(look.thickness >= 0);
    append(cx, draw.Arc, null, draw.Arc.of(ring, clip, look));
}

/// `bytes` in `style`, placed in `rect` by `options` under `clip`. `bytes` points at app-owned
/// text of at most `text.byte_cap` bytes; empty text appends nothing.
pub fn label(
    cx: anytype,
    style: text.Style,
    bytes: []const u8,
    rect: Rect,
    clip: Clip,
    options: text.Options,
) void {
    assert(bytes.len <= text.byte_cap);
    assert(clip.x1 > clip.x0);
    text.place(cx.drawing(), style, bytes, rect, clip, options);
}

/// `bytes` in `style`, wrapped to `rect.width` and placed by `options` under `clip`
/// (`text.place_wrapped`): `label`'s twin for text longer than a line. `bytes` points at
/// app-owned text of at most `text.byte_cap` bytes; lines outside `clip` append nothing.
pub fn paragraph(
    cx: anytype,
    style: text.Style,
    bytes: []const u8,
    rect: Rect,
    clip: Clip,
    options: text.WrapOptions,
) void {
    assert(bytes.len <= text.byte_cap);
    assert(clip.x1 > clip.x0);
    text.place_wrapped(cx.drawing(), style, bytes, rect, clip, options);
}

/// `codepoint` of `face` at `size`, its ink centred on `rect` under `clip` (`text.icon`): an
/// icon from an app's icon face. A codepoint the face does not map appends nothing.
pub fn icon(
    cx: anytype,
    font: text.Face,
    codepoint: u21,
    size: f32,
    rect: Rect,
    clip: Clip,
    color: [4]f32,
) void {
    assert(size > 0);
    assert(clip.x1 > clip.x0);
    text.icon(cx.drawing(), font, codepoint, size, rect, clip, color);
}

/// Steps `value` by `dt_ms`: a moved value owes a redraw and a live one another frame.
pub fn step(cx: anytype, value: *Animator, dt_ms: f32) void {
    assert(dt_ms >= 0);
    assert(value.rate_per_ms > 0);
    if (value.step(dt_ms)) cx.redraw();
    if (value.live()) cx.keep_animating();
}

/// Aims `value` at `target`; a new target owes a redraw.
pub fn aim(cx: anytype, value: *Animator, target: f32) void {
    assert(target >= 0);
    assert(target <= 1);
    if (value.set_target(target)) cx.redraw();
}

/// The shader mix weight of animator value `amount`: `amount * scale`.
pub fn weight(amount: f32, scale: f32) f32 {
    assert(amount >= 0);
    assert(amount <= 1);
    const result = amount * scale;
    assert(result >= 0);
    assert(result <= scale);
    return result;
}

/// True when `event` releases a press of area `id` over it: a clickable row. A row that
/// highlights on hover repaints, so a hover change owes a redraw.
pub fn clicked(cx: anytype, id: Id, event: input.Event) bool {
    assert(id != .none);
    switch (cx.hit(id, event)) {
        .hover_in, .hover_out => cx.redraw(),
        .up => |up| return up.inside,
        .none, .down, .drag, .wheel, .secondary => {},
    }
    return false;
}

/// Aims `hover` and `down` (null for a widget without a press channel) from one hit, by the
/// table in section 3.
pub fn respond(cx: anytype, hit: ui.Hit, hover: *Animator, down: ?*Animator) void {
    switch (hit) {
        .none, .drag, .wheel, .secondary => {},
        .hover_in => aim(cx, hover, 1),
        .hover_out => aim(cx, hover, 0),
        .down => {
            aim(cx, hover, 1);
            if (down) |press| aim(cx, press, 1);
        },
        .up => |up| {
            if (down) |press| aim(cx, press, 0);
            if (!up.inside) aim(cx, hover, 0);
        },
    }
}

/// A widget's hover and press animators (section 3). `down` is null for a widget with no
/// press channel.
pub const Interaction = struct {
    hover: Animator,
    down: ?Animator,

    /// Both at rest at 0; `down_rate` null for no press channel.
    pub fn init(hover_rate: f32, down_rate: ?f32) Interaction {
        assert(hover_rate > 0);
        const interaction: Interaction = .{
            .hover = Animator.init(hover_rate),
            .down = if (down_rate) |rate| Animator.init(rate) else null,
        };
        assert(!interaction.hover.live());
        assert(interaction.hover.value == 0);
        return interaction;
    }

    /// Steps both animators (`step`).
    pub fn frame(self: *Interaction, cx: anytype, dt_ms: f32) void {
        assert(dt_ms >= 0);
        step(cx, &self.hover, dt_ms);
        if (self.down) |*press| step(cx, press, dt_ms);
    }

    /// Aims both animators from `hit` (`respond`). The widget still switches on `hit` for its
    /// own action.
    pub fn react(self: *Interaction, cx: anytype, hit: ui.Hit) void {
        const press: ?*Animator = if (self.down) |*value| value else null;
        respond(cx, hit, &self.hover, press);
    }

    /// The press animator's value, 0 without a press channel.
    pub fn down_value(self: *const Interaction) f32 {
        const value = if (self.down) |press| press.value else 0;
        assert(value >= 0);
        assert(value <= 1);
        return value;
    }
};

comptime {
    assert(hover_lighten == 0.18);
    assert(down_darken == 0.30);
    assert(hover_duration_ms == 100);
    assert(down_duration_ms == 50);
    assert(hover_rate_per_ms > 0);
    assert(down_rate_per_ms > hover_rate_per_ms);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

// Locks `respond`, row by row of the table in section 3, with and without a press channel:
// the targets after each hit, and that drag, wheel, and secondary change nothing.
test "respond follows the table row by row" {
    const cx = fixture.context();
    const press: ui.Press = .{
        .x = 0,
        .y = 0,
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clicks = 1,
        .mods = .none,
    };
    const inside: ui.Hit = .{ .up = .{ .x = 0, .y = 0, .inside = true } };
    const outside: ui.Hit = .{ .up = .{ .x = 0, .y = 0, .inside = false } };
    var pair = Interaction.init(hover_rate_per_ms, down_rate_per_ms);
    pair.react(cx, .hover_in);
    try testing.expectEqual(@as(f32, 1), pair.hover.target);
    try testing.expectEqual(@as(f32, 0), pair.down.?.target);
    pair.react(cx, .hover_out);
    try testing.expectEqual(@as(f32, 0), pair.hover.target);
    pair.react(cx, .{ .down = press });
    try testing.expectEqual(@as(f32, 1), pair.hover.target);
    try testing.expectEqual(@as(f32, 1), pair.down.?.target);
    for ([_]ui.Hit{ .none, .{ .drag = press }, .{ .secondary = press } }) |hit| {
        pair.react(cx, hit);
        try testing.expectEqual(@as(f32, 1), pair.hover.target);
        try testing.expectEqual(@as(f32, 1), pair.down.?.target);
    }
    const wheel: ui.Hit = .{ .wheel = .{ .x = 0, .y = 0, .dx = 0, .dy = 1 } };
    pair.react(cx, wheel);
    try testing.expectEqual(@as(f32, 1), pair.hover.target);
    pair.react(cx, inside);
    try testing.expectEqual(@as(f32, 1), pair.hover.target);
    try testing.expectEqual(@as(f32, 0), pair.down.?.target);
    pair.react(cx, .{ .down = press });
    pair.react(cx, outside);
    try testing.expectEqual(@as(f32, 0), pair.hover.target);
    try testing.expectEqual(@as(f32, 0), pair.down.?.target);
    var hover_only = Interaction.init(hover_rate_per_ms, null);
    hover_only.react(cx, .{ .down = press });
    try testing.expectEqual(@as(f32, 1), hover_only.hover.target);
    try testing.expectEqual(@as(?Animator, null), hover_only.down);
    hover_only.react(cx, outside);
    try testing.expectEqual(@as(f32, 0), hover_only.hover.target);
    try testing.expectEqual(@as(f32, 0), hover_only.down_value());
    // A 25 ms frame eases both from 0: the press half way (50 ms), the hover a quarter.
    cx.animating = false;
    pair.react(cx, .{ .down = press });
    cx.event_begin(.{ .frame = 25 });
    pair.frame(cx, 25);
    cx.event_end();
    try testing.expectApproxEqAbs(@as(f32, 0.5), pair.down.?.value, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), pair.hover.value, 0.0001);
    try testing.expect(cx.animating);
}

/// `clicked` for one event, dispatched the way an app's `event` sees it.
fn click(cx: *fixture.Context, id: Id, event: input.Event) bool {
    cx.event_begin(event);
    const result = clicked(cx, id, event);
    cx.event_end();
    return result;
}

// Locks `clicked`: an up inside is a click, an up outside is not, and a hover change owes a
// redraw while a press alone does not click.
test "clicked is an up inside and a hover change redraws" {
    const cx = fixture.context();
    const id = ui.id("row", 3);
    cx.begin_frame(1280, 720, 120);
    cx.area(id, .{ .x = 0, .y = 0, .width = 200, .height = 24 }, 0, ui.cx.plain);
    _ = cx.end_frame();
    const over: input.Point = .{ .x = 100, .y = 12 };
    const away: input.Point = .{ .x = 400, .y = 400 };
    cx.dirty = false;
    try testing.expect(!click(cx, id, .{ .pointer_move = over }));
    try testing.expect(cx.dirty);
    try testing.expect(!click(cx, id, .{ .pointer_down = input.left_at(over) }));
    try testing.expect(click(cx, id, .{ .pointer_up = input.left_at(over) }));
    _ = click(cx, id, .{ .pointer_down = input.left_at(over) });
    try testing.expect(!click(cx, id, .{ .pointer_up = input.left_at(away) }));
    // The release outside left the row; coming back is a hover change again.
    cx.dirty = false;
    try testing.expect(!click(cx, id, .{ .pointer_move = over }));
    try testing.expect(cx.dirty);
}

// Locks `append`: a refused instance is counted in `overflow_count` and does not fail, and
// `face` skips a rect with a zero edge without counting it.
test "append counts a refused instance and face skips an empty rect" {
    const cx = fixture.context();
    cx.begin_frame(1280, 720, 120);
    const clip: Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
    const rect: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    var index: u32 = 0;
    while (index < fixture.box_cap + 2) : (index += 1) {
        face(cx, rect, clip, .{ .fill = .{ 1, 1, 1, 1 } });
    }
    try testing.expectEqual(@as(usize, fixture.box_cap), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(u32, 2), cx.draw.overflow_count);
    face(cx, .{ .x = 0, .y = 0, .width = 0, .height = 10 }, clip, .{ .fill = .{ 1, 1, 1, 1 } });
    try testing.expectEqual(@as(u32, 2), cx.draw.overflow_count);
    _ = cx.end_frame();
}

// Locks `Paint.look`: the paint's fill and radius, and the animator values scaled by the
// scheme's weights: dark's 0.18 and 0.30 (the kit constants), light's 0.10 and 0.15.
test "paint look scales hover and down" {
    const paint = paint_of(.{ 0.25, 0.5, 0.75, 1 }, 6);
    const look = paint.look(&theme.dark, 1, 0.5);
    try testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1 }, look.fill);
    try testing.expectEqual(@as(f32, 6), look.radius);
    try testing.expectEqual(hover_lighten, look.hover);
    try testing.expectEqual(@as(f32, 0.5) * down_darken, look.down);
    try testing.expectEqual(draw.transparent, look.border_color);
    const light = paint.look(&theme.light, 1, 0.5);
    try testing.expectEqual(@as(f32, 0.10), light.hover);
    try testing.expectEqual(@as(f32, 0.5) * 0.15, light.down);
}

// Locks `accent`: the app scheme's accents cycled by index with the knob stroke as radius,
// equal to `widgets.accents` under the dark scheme and to light's under the light one.
test "accent reads the scheme's accents" {
    const cx = fixture.context();
    const first = accent(cx, 0);
    try testing.expectEqual(@as(f32, 0.62), first.r);
    try testing.expectEqual(accent_radius, first.radius);
    try testing.expectEqual(accent(cx, 1), accent(cx, 1 + theme.accent_count));
    cx.event_begin(.{ .frame = 0 });
    cx.set_theme(theme.light);
    cx.event_end();
    try testing.expectEqual(theme.light.accents[2][1], accent(cx, 2).g);
    cx.event_begin(.{ .frame = 0 });
    cx.set_theme(theme.dark);
    cx.event_end();
}

// Locks `lit` (section 3) on the dark scheme: at rest the look is returned unchanged; full
// hover moves each channel hover_lighten (0.18) of the way to `lighten`, then a full press
// down_darken (0.30) of the rest of the way to `darken`, on the fill, the end stop, and the
// border, keeping every alpha and the shadow.
test "lit mixes a surface's colours as a box's shader does" {
    const scheme = &theme.dark;
    const look: SurfaceLook = .{
        .fill = .{ 0.2, 0.4, 0.6, 0.9 },
        .fill_to = .{ 1, 0, 0, 0 },
        .border = .{ 0.5, 0.5, 0.5, 0.3 },
        .shadow = .{ .offset = .{ 0, 6 }, .blur = 16, .alpha = 0.35 },
    };
    try testing.expect(std.meta.eql(look, lit(look, scheme, 0, 0)));
    const hovered = lit(look, scheme, 1, 0);
    const light = scheme.colors.lighten;
    try testing.expectApproxEqAbs(0.2 + (light[0] - 0.2) * 0.18, hovered.fill[0], 1e-6);
    try testing.expectEqual(@as(f32, 0.9), hovered.fill[3]);
    try testing.expectEqual(@as(f32, 0), hovered.fill_to.?[3]);
    try testing.expectEqual(@as(f32, 0.3), hovered.border[3]);
    const pressed = lit(look, scheme, 1, 1);
    const dark = scheme.colors.darken;
    const lifted = 0.5 + (light[1] - 0.5) * 0.18;
    try testing.expectApproxEqAbs(lifted + (dark[1] - lifted) * 0.30, pressed.border[1], 1e-6);
    try testing.expect(std.meta.eql(look.shadow, pressed.shadow));
}

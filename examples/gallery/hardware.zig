//! The gallery's hardware skin: a knob, a button, and a toggle drawn with the gallery's own
//! draw types, so the same behaviour as `widgets.Knob` takes a skeuomorphic look.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! A skin is a struct of draw functions (`widgets.skins`, `src/widgets/skin.zig`).
//! `widgets.KnobOf(Skin)`, `ButtonOf(Skin)`, and `ToggleOf(Skin)` keep the library's
//! behaviour, actions, and routing; only their looks and hit shapes come from here. The look
//! uses two draw types written for it, `Dial` and `Bevel`, and a copy of the rack's `Led`; the
//! gallery registers all three in `config.draw`.
//!
//! ## 2. Draw Types
//! - `Dial` (80 bytes: rect, clip, `body`, `accent`, then `value`, `hover`, `shadow`,
//!   `pointer_w`): a soft drop shadow (the body disc moved `shadow_drop` px down, fading over
//!   `shadow` px, alpha 0.35), the body disc with a vertical gradient
//!   `mix(body * 1.15, body * 0.8, local.y / size.y)`, a 1 px bright rim, and a pointer from
//!   30% to 85% of the radius at `arc.x + value * arc.y` (the theme's arc, so it matches the
//!   value arc), lightened by `hover`. Its quad leaves `shadow + shadow_drop` around the body.
//! - `Bevel` (64 bytes: rect, clip, `face`, `radius`, `depth`, `down`, `hover`): a rounded box
//!   whose top edge is lit and bottom edge shaded over `depth` px, inverted as `down` goes to
//!   1, and lightened by `hover`.
//! - `Led`: the rack's glowing disc (`examples/rack/led.zig`), unchanged.
//!
//! ## 3. Draw Order
//! Within a layer a type's batch draws where its first instance appeared, and the default row
//! has already put `Arc` and `Glyph` first in the base layer. So the skin appends its faces
//! (`Dial`, `Bevel`) on `face_layer` and everything on top of them (the value arc, labels, the
//! LED) on `ink_layer`, and restores the caller's layer before returning, so the behaviour
//! records its area where it always does.
//!
//! ## 4. Hit Shapes
//! A knob takes presses on the dial's body disc, not its shadow or the value arc around it; a
//! button on its bevel, rounded by the paint's radius; a toggle on its housing. Tests "the
//! dial's disc holds its center and not its shadow" and "button and toggle hit their faces".

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const draw = patchwork.draw;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;

const Rect = draw.Rect;

/// A knob with a drop shadow, a gradient body, a rim, and a pointer (section 2).
pub const Dial = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    body: [4]f32,
    accent: [4]f32,
    value: f32,
    hover: f32,
    shadow: f32,
    pointer_w: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let center = px.size * 0.5;
        \\    let radius = min(center.x, center.y) - px.shadow - 2.0;
        \\    let drop = sdf_circle(px.local, center + vec2<f32>(0.0, 2.0), radius);
        \\    let shade = 0.35 * clamp(1.0 - max(drop, 0.0) / max(px.shadow, 1.0e-5), 0.0, 1.0);
        \\    let dist = sdf_circle(px.local, center, radius);
        \\    let body = coverage(dist);
        \\    var rgb = mix(px.body.rgb * 1.15, px.body.rgb * 0.8, px.local.y / px.size.y);
        \\    let rim = coverage(abs(dist + 0.5) - 0.5);
        \\    rgb = mix(rgb, min(px.body.rgb * 1.6, vec3<f32>(1.0)), rim * 0.6);
        \\    let angle = frame.theme.arc.x + px.value * frame.theme.arc.y;
        \\    let dir = vec2<f32>(cos(angle), sin(angle));
        \\    let tip = sdf_segment(px.local, center + dir * radius * 0.3, center + dir * radius * 0.85);
        \\    let pointer = coverage(tip - px.pointer_w * 0.5);
        \\    rgb = mix(rgb, mix(px.accent.rgb, vec3<f32>(1.0), px.hover), pointer);
        \\    let alpha = body + shade * (1.0 - body);
        \\    return vec4<f32>(rgb * body / max(alpha, 1.0e-5), alpha);
        \\}
        \\
    ;
};

/// A rounded face lit on its top edge and shaded on its bottom one (section 2).
pub const Bevel = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    face: [4]f32,
    radius: f32,
    depth: f32,
    down: f32,
    hover: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let dist = sdf_box(px.local, px.size, px.radius);
        \\    let depth = max(px.depth, 1.0e-5);
        \\    let top = clamp(1.0 - px.local.y / depth, 0.0, 1.0);
        \\    let bottom = clamp(1.0 - (px.size.y - px.local.y) / depth, 0.0, 1.0);
        \\    let edge = mix(top - bottom, bottom - top, px.down);
        \\    let face = mix(px.face.rgb, vec3<f32>(1.0), px.hover);
        \\    let rgb = clamp(face + vec3<f32>(0.22 * edge), vec3<f32>(0.0), vec3<f32>(1.0));
        \\    return vec4<f32>(rgb, coverage(dist) * px.face.a);
        \\}
        \\
    ;
};

/// The rack's glowing disc (`examples/rack/led.zig`), copied so the gallery stands alone.
pub const Led = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    brightness: f32,

    pub const texture: ?draw.TextureFormat = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    let center = px.size * 0.5;
        \\    let radius = min(center.x, center.y);
        \\    let core = radius * 0.45;
        \\    let dist = sdf_circle(px.local, center, core);
        \\    let reach = clamp(1.0 - max(dist, 0.0) / max(radius - core, 1.0e-5), 0.0, 1.0);
        \\    let glow = reach * reach * px.brightness;
        \\    let rgb = mix(px.color.rgb * 0.3, px.color.rgb, px.brightness);
        \\    let alpha = max(coverage(dist), glow * 0.7) * px.color.a;
        \\    return vec4<f32>(rgb, alpha);
        \\}
        \\
    ;
};

/// The dial's shadow falloff and how far it drops, its pointer width, and the bevel depth.
pub const shadow_px: f32 = 3;
pub const shadow_drop: f32 = 2;
pub const pointer_px: f32 = 2;
pub const bevel_depth: f32 = 3;
/// The toggle housing's corner radius and its LED's side.
pub const housing_radius: f32 = 6;
pub const led_px: f32 = 18;

/// The layers of section 3.
const face_layer: draw.Layer = @fromBackingInt(1);
const ink_layer: draw.Layer = @fromBackingInt(2);

/// The dial's quad in a knob's ring: inside the value arc.
pub fn dial_quad(ring: Rect) Rect {
    return ui.cx.inset(ring, .all(widgets.ring_thickness));
}

/// The dial's body disc: the quad less the shadow's reach.
pub fn dial_body(ring: Rect) Rect {
    return ui.cx.inset(dial_quad(ring), .all(shadow_px + shadow_drop));
}

/// The skin: a dial, a bevel button, and a bevel housing with an LED (module guide).
pub const Skin = struct {
    pub fn knob(cx: anytype, look: widgets.KnobLook) ?widgets.Shape {
        assert(look.value >= 0 and look.value <= 1);
        if (look.row.height < look.ring) return null;
        const ring = widgets.ring_sized(look.row, look.ring);
        const scheme = cx.theme();
        const accent: [4]f32 = .{ look.accent.r, look.accent.g, look.accent.b, look.accent.a };
        const previous = cx.drawing().layer(face_layer);
        defer _ = cx.drawing().layer(previous);
        kit.append(cx, Dial, null, .{
            .rect = dial_quad(ring).array(),
            .clip = look.clip.array(),
            .body = scheme.colors.track,
            .accent = accent,
            .value = look.value,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
            .shadow = shadow_px,
            .pointer_w = pointer_px,
        });
        _ = cx.drawing().layer(ink_layer);
        if (look.value > 0) kit.arc(cx, ring, look.clip, .{
            .color = accent,
            .thickness = widgets.ring_thickness,
            .sweep = look.value,
        });
        const name_box = widgets.name_box(look.row, look.ring);
        kit.label(cx, scheme.name, look.name, name_box, look.clip, kit.centered);
        const value_box = widgets.value_box(look.row, look.ring);
        kit.label(cx, scheme.value, look.value_text, value_box, look.clip, kit.centered);
        const body = dial_body(ring);
        return .{ .rect = body, .radius = body.width * 0.5 };
    }

    pub fn button(cx: anytype, look: widgets.ButtonLook) ?widgets.Shape {
        assert(look.hover >= 0 and look.down >= 0);
        const scheme = cx.theme();
        const paint = look.paint;
        const previous = cx.drawing().layer(face_layer);
        defer _ = cx.drawing().layer(previous);
        kit.append(cx, Bevel, null, .{
            .rect = look.rect.array(),
            .clip = look.clip.array(),
            .face = .{ paint.r, paint.g, paint.b, paint.a },
            .radius = paint.radius,
            .depth = bevel_depth,
            .down = look.down,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
        });
        _ = cx.drawing().layer(ink_layer);
        const inner = ui.cx.inset(look.rect, look.padding);
        kit.label(cx, look.style, look.label, inner, look.clip, kit.centered);
        return .{ .rect = look.rect, .radius = paint.radius };
    }

    pub fn toggle(cx: anytype, look: widgets.ToggleLook) ?widgets.Shape {
        assert(look.thumb >= 0 and look.thumb <= 1);
        const housing = widgets.pill_of(look.row);
        const scheme = cx.theme();
        const previous = cx.drawing().layer(face_layer);
        defer _ = cx.drawing().layer(previous);
        kit.append(cx, Bevel, null, .{
            .rect = housing.array(),
            .clip = look.clip.array(),
            .face = scheme.colors.track,
            .radius = housing_radius,
            .depth = bevel_depth,
            .down = look.thumb,
            .hover = kit.weight(look.hover, scheme.hover_lighten),
        });
        _ = cx.drawing().layer(ink_layer);
        const center_x = housing.x + housing.width * 0.5;
        const center_y = housing.y + housing.height * 0.5;
        kit.append(cx, Led, null, .{
            .rect = .{ center_x - led_px * 0.5, center_y - led_px * 0.5, led_px, led_px },
            .clip = look.clip.array(),
            .color = scheme.colors.value,
            .brightness = look.thumb,
        });
        const side_box = widgets.side_box(look.row);
        kit.label(cx, scheme.name, look.name, side_box, look.clip, kit.centered);
        return .{ .rect = housing, .radius = housing_radius };
    }
};

comptime {
    assert(draw.check_type(Dial) == null);
    assert(draw.check_type(Bevel) == null);
    assert(draw.check_type(Led) == null);
    assert(@sizeOf(Dial) == 80);
    assert(@sizeOf(Bevel) == 64);
    assert(@sizeOf(Led) == 52);
    assert(widgets.skins.check(Skin, .knob) == null);
    assert(widgets.skins.check(Skin, .button) == null);
    assert(widgets.skins.check(Skin, .toggle) == null);
    // The shadow fades out inside the value arc, which the ink layer draws on top anyway.
    assert(shadow_px + shadow_drop <= 2 * widgets.ring_thickness);
    assert(led_px < widgets.pill_h);
}

const testing = std.testing;

// Locks the generated interfaces: the dial's five groups end in a full fifth (`g4`) holding
// value, hover, shadow, and pointer width; the bevel's four end in radius, depth, down, and
// hover; both carry their own `pixel`.
test "dial and bevel assemble against the prelude" {
    const dial = comptime draw.type_source(Dial);
    try testing.expect(std.mem.find(u8, dial, "@location(5) g4: vec4<f32>") != null);
    try testing.expect(std.mem.find(u8, dial, "@location(6)") == null);
    try testing.expect(std.mem.find(u8, dial, "px.pointer_w = v.g4.w;") != null);
    try testing.expect(std.mem.find(u8, dial, "fn pixel(px: Pixel)") != null);
    const bevel = comptime draw.type_source(Bevel);
    try testing.expect(std.mem.find(u8, bevel, "@location(4) g3: vec4<f32>") != null);
    try testing.expect(std.mem.find(u8, bevel, "px.hover = v.g3.w;") != null);
}

// Locks the knob's hit twin (section 4): in a 56 px ring at the origin the dial's quad is the
// ring inset by the arc (48 px at 4), its body that less the shadow's reach (38 px at 9, radius
// 19); the body holds its center (28, 28) and not the shadow just under it (28, 48).
test "the dial's disc holds its center and not its shadow" {
    const ring: Rect = .{ .x = 0, .y = 0, .width = 56, .height = 56 };
    const quad = dial_quad(ring);
    try testing.expectEqual(@as(f32, 4), quad.x);
    try testing.expectEqual(@as(f32, 48), quad.width);
    const body = dial_body(ring);
    try testing.expectEqual(@as(f32, 9), body.x);
    try testing.expectEqual(@as(f32, 38), body.width);
    const radius = body.width * 0.5;
    try testing.expect(draw.contains_box(body.x, body.y, body.width, body.height, radius, 28, 28));
    try testing.expect(!draw.contains_box(body.x, body.y, body.width, body.height, radius, 28, 48));
    // The drop shadow reaches 9 + 38 + 2 + 3 = 52 below the ring's top: inside the quad.
    try testing.expect(body.y + body.height + shadow_drop + shadow_px <= quad.y + quad.height);
}

// Locks the button and toggle hit twins (section 4): a 96 by 40 button rounded by 8 holds its
// center and not its corner pixel; a toggle's 44 by 24 housing sits 8 px into its row,
// centered, and holds its own center but not the label column at x 72.
test "button and toggle hit their faces" {
    try testing.expect(draw.contains_box(0, 0, 96, 40, 8, 48, 20));
    try testing.expect(!draw.contains_box(0, 0, 96, 40, 8, 0.5, 0.5));
    const row: Rect = .{ .x = 0, .y = 0, .width = 140, .height = widgets.toggle_height };
    const housing = widgets.pill_of(row);
    try testing.expectEqual(@as(f32, 8), housing.x);
    try testing.expectEqual(@as(f32, 8), housing.y);
    const contains = draw.contains_box;
    const r = housing_radius;
    try testing.expect(contains(housing.x, housing.y, housing.width, housing.height, r, 30, 20));
    try testing.expect(!contains(housing.x, housing.y, housing.width, housing.height, r, 72, 20));
    try testing.expectEqual(@as(f32, 72), widgets.side_box(row).x);
}

//! The app's theme: the scheme widgets read, its GPU record, and the open-ring arc angles.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Two Values: the Scheme and Its Record
//! A `Scheme` is the whole-app look an app owns: the chrome colors, the window background,
//! the focus ring and selection band, four accents, the two text styles widgets label with,
//! and the hover and press mix weights. Widgets read it on the CPU at draw time through
//! `cx.theme()` (`ui/cx.zig`, section 9b) to fill per-instance colors. `Theme` is the part the
//! GPU needs, `Scheme.record()`: the colors the shaders mix toward (`lighten`, `darken`), the
//! background the passes clear to, the chrome slots, and the arc angles. Sizes are not themed;
//! they stay per instance (`Knob.sized`, `Meter.track_h`). Corners and strokes are, in the
//! scheme's `form` (section 8).
//! ```text
//! App.config.theme : Scheme ---copied at app.start---> ui.Context.scheme --cx.theme()--> widgets
//!                       cx.set_theme(s): scheme = s, draw.theme = s.record(), redraw
//! draw.Context.theme : Theme ---renderer.frame compares it with the uploaded uniform--->
//!                       changed: one whole-uniform write and every tile repainted
//! ```
//! `dark` is the look of steps 1 to 30 and the default; `light` is its light counterpart.
//! `chrome` is `dark.record()`, kept for consumers that read the record directly.
//!
//! ## 2. Why the Record Rides in the Frame Uniform
//! Every draw type's pipeline binds one uniform at `@group(0) @binding(0)` whose WGSL type is
//! `Frame { ortho: mat4x4<f32>, time: vec4<f32>, theme: Theme }` (`draw/prelude.wgsl`). Placing
//! `Theme` in the frame uniform lets all pipelines share one bind group layout and one bind
//! group, keeps color and arc-angle literals out of WGSL, and makes a theme switch one uniform
//! write: the fragment shaders read `lighten`, `darken`, and `arc`, and the renderer's clear
//! pipeline reads `background` (`draw/renderer.zig`, section 4a).
//!
//! The frame record is `draw.matrix_bytes + draw.time_bytes + bytes` long and must equal
//! `draw.uniform_bytes`; see the `comptime` block in `draw.zig` and the alignment rationale on
//! `draw.uniform_bytes`.
//!
//! ## 3. Angle Convention
//! Angles come from `atan2(y, x)` in Y-down pixel space: 0 points along +X, and increasing
//! angles turn clockwise as seen on screen. The open ring starts at `arc_start`, sweeps
//! clockwise by `arc_sweep`, and leaves a gap of `tau - arc_sweep` that closes back at
//! `arc_start`. Test "open ring gap is a quarter turn that closes at the start angle" locks
//! this, and test "sdf arc locks the open ring" in `draw/types.zig` locks the distance field.
//! The arc is not themeable: the CPU twins in `draw/types.zig` use the constants for hit tests,
//! so `record` always writes them.
//!
//! ## 4. Layout Contract
//! `Theme` is an `extern struct` of `vec4<f32>` slots. `draw/registry.zig` generates the WGSL
//! `Theme` struct from this record's fields, in order, so the shader side cannot drift. WGSL
//! packs each `vec4<f32>` at 16 bytes, so slot `i` lives at byte `16 * i` of the record. The
//! `comptime` block below enforces the slot size, the per-field offsets, `bytes`, and
//! `slot_count`; test "source declares locations 1 to N and names every field" in
//! `draw/registry.zig` checks the generated declaration. The `pad` slot stays zero so the
//! record has no uninitialized bytes when copied to the GPU.
//!
//! ## 5. Making a Scheme
//! Start from a preset and change what differs: `var s = theme.dark; s.colors.panel = ...;`.
//! Colors are straight (non-premultiplied) RGBA with every component in `[0, 1]`, and the text
//! sizes are within `text.size_max`; the material's and the form's fields are in their ranges
//! (a corner in `[0, radius_max]`, `capsule` in `[0, 0.5]`, `hairline` in `[0, stroke_max]`,
//! `mark` in `(0, stroke_max]`, and a hairline above 0 when controls are outlined).
//! `app.check` refuses a `config.theme` that breaks any of these and names the field
//! (`conformance`); `cx.set_theme` asserts the material and the form of a scheme built at run
//! time. Keep each `background` component off an 8-bit
//! rounding tie (`c * 255` a half, such as 0.90): the background reaches the screen both as a
//! pass's clear value and as the clear pipeline's output, which some GPUs round apart, so a
//! cached frame would differ from a direct one by one step. Instance colors an app sets (`Button.paint`,
//! `Knob.accent`, a `Label`'s style) win over the scheme; `widgets.kit.accent(cx, i)` reads the
//! scheme's accents for an app that wants them themed.
//!
//! ## 6. Upload Flow
//! `draw/renderer.zig` keeps a `Uniform` record of the projection matrix at offset 0, the time
//! slot at `draw.time_offset`, and `Theme` at `draw.theme_offset`. When the device size, the
//! scale, or `draw.Context.theme` changed it records one `buffer_write` of the whole record,
//! which both hosts replay, and repaints every tile; view and target uniforms are rebuilt from
//! it. Nothing is allocated: a scheme is a value.
//!
//! ## 7. Materials
//! `Scheme.material` says what the default skins make panels and popups of: `solid` (the
//! faces of steps 1 to 39, and the default of `dark` and `light`), or glass, `clear`,
//! `frosted`, or `tinted`, over a backdrop (`draw/backdrop.zig`). A `Panel` or `Menu` (and so a
//! `Dropdown`'s list) may set its own. Glass needs the app to register `draw.Glass` and to mark
//! a backdrop at or below the face's layer (`kit.backdrop`); a menu marks the popup layer
//! itself. Without either the skin draws the solid face, so a glass material never hides a
//! panel. The material is CPU state only: it is not part of the GPU record, and switching it is
//! a redraw. `blur` is the backdrop's sigma; the rest become the `draw.GlassLook` that
//! `kit.glass_look` derives with the scheme's colours.
//!
//! ## 8. Forms
//! `Scheme.form` says what shape the default skins give faces: corners by role, how round the
//! pill-shaped parts are, how wide borders and emphasis lines are, and three choices of style.
//! Like the material it is CPU state only, outside the GPU record, so switching it is a
//! redraw. `Form{}` is exactly the constants of the faces before forms, so `dark` and `light`
//! draw what they always drew.
//! - `radius` has three roles: `control` (faces pressed or typed in, the scroll thumb),
//!   `popup` (menus, the dropdown face that opens one, tooltips), and `band` (highlight bands
//!   in menus, lists, the menu bar, and the dock's drop overlay).
//! - `capsule` is a fraction of the side the default skin halves, not a radius: 0.5 rounds a
//!   toggle's pill and thumb, a meter, the checkbox's mixed bar, the splitter's divider, and
//!   `Segmented` into capsules; 0 squares them. One radius could not give each its own corner.
//! - `hairline` is every border and rule; `mark` every emphasis line (the selected tab's
//!   underline, the tab insertion marker, the divider, the drop outline).
//! - `controls = .outlined` draws buttons, dropdowns, number boxes, fields, checkboxes,
//!   toggles' pills, and tabs as a `hairline` border in their ink (`colors.control`, a
//!   button's paint, `colors.focus` on a focused field) over a tint of that ink that shows only
//!   on hover and press; a button's label takes its paint's colour.
//! - `tab_mark = .filled` fills the selected tab in `accents[0]`, its label in
//!   `colors.panel`, instead of underlining it.
//! - `framed` gives a solid panel a `hairline` border in `colors.control`.
//! Paints an app stores (`Button.paint`, `Panel.paint`, a slider's) keep their own radius:
//! instance values win over the scheme. Insets, icon strokes, and window buttons are not in
//! the form.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("text.zig");

/// Number of `vec4` slots in `Theme`. Asserted equal to the field count.
pub const slot_count: u32 = 11;

/// Byte size of `Theme`. Asserted equal to `@sizeOf(Theme)`.
pub const bytes: u32 = 176;

/// Number of accents a scheme carries; `widgets.accent_count` equals it.
pub const accent_count: u32 = 4;

/// Start angle of the open ring, in the angle convention of the module guide.
pub const arc_start: f32 = 2.0 * std.math.pi / 3.0;

/// Clockwise sweep of the full open ring. The remainder of the turn is the gap.
pub const arc_sweep: f32 = 3.0 * std.math.pi / 2.0;

/// The GPU record of a scheme. Field order is the GPU layout, so it must match the WGSL
/// `Theme`.
///
/// `arc.x` is `arc_start` and `arc.y` is `arc_sweep`; `arc.z`, `arc.w`, and `pad` stay zero.
pub const Theme = extern struct {
    panel: [4]f32,
    text: [4]f32,
    track: [4]f32,
    value: [4]f32,
    control: [4]f32,
    meter: [4]f32,
    lighten: [4]f32,
    darken: [4]f32,
    arc: [4]f32,
    /// The window clear: every pass that clears the screen, and the clear pipeline.
    background: [4]f32,
    pad1: [4]f32,
};

/// A scheme's colors, straight RGBA with every component in `[0, 1]` (module guide, section 5).
pub const Colors = struct {
    /// The window clear.
    background: [4]f32,
    /// Group and panel faces.
    panel: [4]f32,
    /// Text, and the text field's caret.
    text: [4]f32,
    /// Knob rings, slider and meter tracks, toggle pills, the text field's face.
    track: [4]f32,
    /// A slider's filled part.
    value: [4]f32,
    /// Slider knobs, toggle thumbs, the scrollbar thumb, an unfocused field's border.
    control: [4]f32,
    /// A meter's level.
    meter: [4]f32,
    /// A focused text field's border.
    focus: [4]f32,
    /// The selection band behind a field's text.
    selection: [4]f32,
    /// What a hover mixes toward.
    lighten: [4]f32,
    /// What a press mixes toward, after the hover.
    darken: [4]f32,
};

/// The widest backdrop blur a material may ask for, sigma in logical pixels.
pub const blur_max: f32 = 48;

/// The most refraction a material may ask for, logical pixels.
pub const refraction_max: f32 = 64;

/// What panels and popups are made of (module guide, section 7): solid faces, or glass over a
/// backdrop (`draw/backdrop.zig`). Colours stay the scheme's: the tint is `colors.panel`, or
/// `colors.focus` for `tinted`, at `tint` alpha, and the rim mixes toward `colors.lighten`.
pub const Material = struct {
    kind: Kind = .solid,
    /// The backdrop's blur, sigma in logical pixels, `[0, blur_max]`.
    blur: f32 = 0,
    /// `[0, 1]`: 0 shows the lightly filtered backdrop, 1 the blurred one.
    frost: f32 = 0,
    /// `[0, 1]`: how far the backdrop moves toward the tint colour.
    tint: f32 = 0,
    /// `[0, 2]`: 1 keeps the backdrop's colours, more makes them vivid.
    saturation: f32 = 1,
    /// `[0, 1]`: the lit edge.
    rim: f32 = 0,
    /// How far the edge bends what is under it, logical pixels, `[0, refraction_max]`.
    refraction: f32 = 0,

    /// `solid` is the faces of steps 1 to 39 (`opaque` is a Zig keyword).
    pub const Kind = enum(u8) { solid, clear, frosted, tinted };

    pub const solid: Material = .{};
    /// Barely blurred and barely tinted, with a strong lens at the edge.
    pub const clear: Material = .{
        .kind = .clear,
        .blur = 4,
        .frost = 0.35,
        .tint = 0.1,
        .saturation = 1.2,
        .rim = 0.7,
        .refraction = 10,
    };
    /// Blurred and tinted toward the panel colour.
    pub const frosted: Material = .{
        .kind = .frosted,
        .blur = 16,
        .frost = 1,
        .tint = 0.45,
        .saturation = 1.5,
        .rim = 0.5,
        .refraction = 6,
    };
    /// Blurred and tinted toward the focus colour.
    pub const tinted: Material = .{
        .kind = .tinted,
        .blur = 16,
        .frost = 1,
        .tint = 0.4,
        .saturation = 1.3,
        .rim = 0.5,
        .refraction = 6,
    };

    /// True for every kind but `solid`.
    pub fn glass(self: Material) bool {
        return self.kind != .solid;
    }

    /// Null when every field is in its range, otherwise the first that is not.
    pub fn problem(self: Material) ?[]const u8 {
        if (!(self.blur >= 0 and self.blur <= blur_max)) return "blur: must be in [0, 48]";
        if (!(self.frost >= 0 and self.frost <= 1)) return "frost: must be in [0, 1]";
        if (!(self.tint >= 0 and self.tint <= 1)) return "tint: must be in [0, 1]";
        if (!(self.saturation >= 0 and self.saturation <= 2)) {
            return "saturation: must be in [0, 2]";
        }
        if (!(self.rim >= 0 and self.rim <= 1)) return "rim: must be in [0, 1]";
        if (!(self.refraction >= 0 and self.refraction <= refraction_max)) {
            return "refraction: must be in [0, 64]";
        }
        return null;
    }
};

/// The widest corner a form may ask for, logical pixels (a `draw.Box` clamps its corner to half
/// the short side).
pub const radius_max: f32 = 64;

/// The widest border or mark a form may ask for, logical pixels (under `widgets.splitter_px`).
pub const stroke_max: f32 = 4;

/// What shape the default skins give a scheme's faces (module guide, section 8): corners by
/// role, how round the pill-shaped parts are, border and mark widths, whether controls are
/// filled or outlined, how the selected tab is marked, and whether panels are framed. Sizes
/// are not here; they stay per instance or constants.
pub const Form = struct {
    radius: Radii = .{},
    /// A pill-shaped part's corner as a fraction of the side the default skin halves,
    /// `[0, 0.5]`: 0.5 a capsule, 0 square. The toggle's pill and thumb, the meter, the
    /// checkbox's mixed bar, the splitter's divider, the `Segmented` track and segments.
    capsule: f32 = 0.5,
    /// Borders and rules, logical pixels, `[0, stroke_max]`: field, number box, checkbox,
    /// dropdown, menu, tooltip, a focused disclosure or segmented bar, column header lines,
    /// framed panels.
    hairline: f32 = 1,
    /// Emphasis lines, logical pixels, `(0, stroke_max]`: the selected tab's underline, the tab
    /// insertion marker, the splitter's divider, the dock's drop outline.
    mark: f32 = 2,
    /// Whether the default skin fills controls or outlines them (section 8).
    controls: Controls = .filled,
    /// How the default skin marks the selected tab (section 8).
    tab_mark: TabMark = .underline,
    /// A `hairline` border in `colors.control` around solid panels.
    framed: bool = false,

    /// Corner radii by role, logical pixels, `[0, radius_max]`.
    pub const Radii = struct {
        /// Faces pressed or typed in: text field, number box, checkbox box, tab, a tab's
        /// close band, disclosure header, scroll thumb.
        control: f32 = 4,
        /// Popups and what opens them: menu face, dropdown face (it matches its list),
        /// tooltip, and the glass look of all three.
        popup: f32 = 6,
        /// Highlight bands: menu row, list and tree row, menu bar title, dock drop overlay.
        band: f32 = 4,
    };

    /// `filled` is the faces of steps 1 to 62; `outlined` draws a control as its border in
    /// the control's ink over a tint that shows only on hover and press.
    pub const Controls = enum(u8) { filled, outlined };

    /// `underline` is a `mark`-high line in `accents[0]` under the selected tab; `filled`
    /// fills the selected tab in `accents[0]`.
    pub const TabMark = enum(u8) { underline, filled };

    /// Null when every field is in its range, otherwise the first that is not, relative to
    /// the form (`radius.popup`). A NaN is out of every range.
    pub fn problem(self: Form) ?[]const u8 {
        const radius_rule = ": must be in [0, 64]";
        if (!(self.radius.control >= 0 and self.radius.control <= radius_max)) {
            return "radius.control" ++ radius_rule;
        }
        if (!(self.radius.popup >= 0 and self.radius.popup <= radius_max)) {
            return "radius.popup" ++ radius_rule;
        }
        if (!(self.radius.band >= 0 and self.radius.band <= radius_max)) {
            return "radius.band" ++ radius_rule;
        }
        if (!(self.capsule >= 0 and self.capsule <= 0.5)) return "capsule: must be in [0, 0.5]";
        if (!(self.hairline >= 0 and self.hairline <= stroke_max)) {
            return "hairline: must be in [0, 4]";
        }
        if (!(self.mark > 0 and self.mark <= stroke_max)) return "mark: must be in (0, 4]";
        if (self.controls == .outlined) {
            if (!(self.hairline > 0)) return "hairline: outlined controls need a hairline above 0";
        }
        return null;
    }
};

/// The app-level theme (module guide, section 1). `App.config.theme` sets it at start and
/// `cx.set_theme` switches it at run time.
pub const Scheme = struct {
    colors: Colors,
    /// Per-knob accent colors, cycled by index (`widgets.kit.accent`).
    accents: [accent_count][4]f32,
    /// Control names beside a ring, meter, or pill.
    name: text.Style,
    /// Knob value readouts.
    value: text.Style,
    /// Shader mix toward `colors.lighten` at hover animator value 1, `[0, 1]`.
    hover_lighten: f32,
    /// Shader mix toward `colors.darken` at press animator value 1, `[0, 1]`.
    down_darken: f32,
    /// What panels and popups are made of (section 7); a panel or menu may override it.
    material: Material = .solid,
    /// What shape the default skins give faces (section 8). CPU state only, like `material`.
    form: Form = .{},

    /// The GPU record: the colors the shaders and the passes read, and the constant arc.
    pub fn record(self: *const Scheme) Theme {
        assert(self.hover_lighten >= 0);
        assert(self.down_darken >= 0);
        const c = &self.colors;
        const out: Theme = .{
            .panel = c.panel,
            .text = c.text,
            .track = c.track,
            .value = c.value,
            .control = c.control,
            .meter = c.meter,
            .lighten = c.lighten,
            .darken = c.darken,
            .arc = .{ arc_start, arc_sweep, 0, 0 },
            .background = c.background,
            .pad1 = .{ 0, 0, 0, 0 },
        };
        assert(out.arc[0] == arc_start);
        assert(out.pad1[3] == 0);
        return out;
    }
};

/// The look of steps 1 to 30, and the default `App.config.theme`.
pub const dark: Scheme = .{
    .colors = .{
        .background = .{ 0.11, 0.12, 0.16, 1 },
        .panel = .{ 0.16, 0.17, 0.20, 1 },
        .text = .{ 0.86, 0.87, 0.84, 1 },
        .track = .{ 0.27, 0.29, 0.33, 1 },
        .value = .{ 0.55, 0.85, 0.45, 1 },
        .control = .{ 0.78, 0.79, 0.82, 1 },
        .meter = .{ 0.45, 0.80, 0.42, 1 },
        .focus = .{ 0.40, 0.62, 0.95, 1 },
        .selection = .{ 0.26, 0.42, 0.72, 1 },
        .lighten = .{ 1, 1, 1, 1 },
        .darken = .{ 0, 0, 0, 1 },
    },
    .accents = .{
        .{ 0.62, 0.45, 0.86, 1 },
        .{ 0.40, 0.78, 0.48, 1 },
        .{ 0.93, 0.55, 0.24, 1 },
        .{ 0.93, 0.80, 0.32, 1 },
    },
    .name = .{ .face = .sans, .size = 16, .color = .{ 0.86, 0.87, 0.84, 1 } },
    .value = .{ .face = .mono, .size = 16, .color = .{ 0.86, 0.87, 0.84, 1 } },
    .hover_lighten = 0.18,
    .down_darken = 0.30,
};

/// The light counterpart of `dark`: light faces, dark text, accents a little darker, and
/// gentler hover and press weights.
pub const light: Scheme = .{
    .colors = .{
        .background = .{ 0.89, 0.91, 0.93, 1 },
        .panel = .{ 0.97, 0.97, 0.98, 1 },
        .text = .{ 0.12, 0.13, 0.15, 1 },
        .track = .{ 0.80, 0.81, 0.84, 1 },
        .value = .{ 0.20, 0.55, 0.25, 1 },
        .control = .{ 0.36, 0.37, 0.41, 1 },
        .meter = .{ 0.25, 0.62, 0.30, 1 },
        .focus = .{ 0.15, 0.42, 0.85, 1 },
        .selection = .{ 0.72, 0.81, 0.97, 1 },
        .lighten = .{ 1, 1, 1, 1 },
        .darken = .{ 0, 0, 0, 1 },
    },
    .accents = .{
        .{ 0.53, 0.38, 0.73, 1 },
        .{ 0.34, 0.66, 0.41, 1 },
        .{ 0.79, 0.47, 0.20, 1 },
        .{ 0.79, 0.68, 0.27, 1 },
    },
    .name = .{ .face = .sans, .size = 16, .color = .{ 0.12, 0.13, 0.15, 1 } },
    .value = .{ .face = .mono, .size = 16, .color = .{ 0.12, 0.13, 0.15, 1 } },
    .hover_lighten = 0.10,
    .down_darken = 0.15,
};

/// `dark.record()`: the record the library uploaded before schemes, for consumers that read it.
pub const chrome: Theme = dark.record();

/// True when every component of `color` is in `[0, 1]`.
pub fn color_valid(color: [4]f32) bool {
    for (color) |component| {
        if (!(component >= 0 and component <= 1)) return false;
    }
    return true;
}

/// Null when every color of `scheme` is in `[0, 1]`, both weights are, and both text sizes are
/// in `(0, text.size_max]`; otherwise a message naming the first field that is not, relative
/// to the scheme (`colors.panel`, `accents[2]`, `name.size`). `app.conformance` prefixes it.
pub fn problem(comptime scheme: Scheme) ?[]const u8 {
    comptime {
        const color_rule = ": a component is outside [0, 1]";
        const size_rule = std.fmt.comptimePrint(": must be in (0, {d}]", .{text.size_max});
        for (@typeInfo(Colors).@"struct".field_names) |field_name| {
            const color = @field(scheme.colors, field_name);
            if (!color_valid(color)) return "colors." ++ field_name ++ color_rule;
        }
        for (scheme.accents, 0..) |accent, index| {
            if (!color_valid(accent)) {
                return std.fmt.comptimePrint("accents[{d}]", .{index}) ++ color_rule;
            }
        }
        if (!color_valid(scheme.name.color)) return "name.color" ++ color_rule;
        if (!color_valid(scheme.value.color)) return "value.color" ++ color_rule;
        if (!(scheme.name.size > 0 and scheme.name.size <= text.size_max)) {
            return "name.size" ++ size_rule;
        }
        if (!(scheme.value.size > 0 and scheme.value.size <= text.size_max)) {
            return "value.size" ++ size_rule;
        }
        if (!(scheme.hover_lighten >= 0 and scheme.hover_lighten <= 1)) {
            return "hover_lighten: must be in [0, 1]";
        }
        if (!(scheme.down_darken >= 0 and scheme.down_darken <= 1)) {
            return "down_darken: must be in [0, 1]";
        }
        if (scheme.material.problem()) |message| return "material." ++ message;
        if (scheme.form.problem()) |message| return "form." ++ message;
        return null;
    }
}

comptime {
    assert(@sizeOf(Theme) == 176);
    assert(@alignOf(Theme) >= 4);
    assert(bytes == @sizeOf(Theme));
    assert(slot_count == 11);
    // WGSL lays each vec4<f32> out at 16 bytes, so slot i must start at byte 16 * i. Checking
    // every field catches a reordered or retyped field that the total size alone would miss.
    const info = @typeInfo(Theme).@"struct";
    assert(info.field_names.len == slot_count);
    for (info.field_names, info.field_types, 0..) |field_name, field_type, slot| {
        assert(field_type == [4]f32);
        assert(@offsetOf(Theme, field_name) == 16 * slot);
    }
    assert(@offsetOf(Theme, "background") == 16 * 9);
    assert(chrome.arc[0] == arc_start);
    assert(chrome.arc[1] == arc_sweep);
    assert(chrome.arc[2] == 0);
    assert(chrome.arc[3] == 0);
    assert(chrome.pad1[0] == 0);
    assert(chrome.lighten[0] == 1);
    assert(chrome.darken[0] == 0);
    assert(problem(dark) == null);
    assert(problem(light) == null);
    assert(Material.clear.problem() == null);
    assert(Material.frosted.problem() == null);
    assert(Material.tinted.problem() == null);
    assert(!dark.material.glass());
    assert(!light.material.glass());
    assert(@typeInfo(Colors).@"struct".field_names.len == 11);
    // The form is CPU state: small enough to copy with the scheme, and valid in both presets.
    assert(@sizeOf(Form) <= 32);
    assert((Form{}).problem() == null);
    assert(std.meta.eql(dark.form, Form{}));
    assert(std.meta.eql(light.form, Form{}));
    assert(radius_max > 0);
    assert(stroke_max > 0);
}

/// The record steps 1 to 30 uploaded, `pad0` and all, for the comparison test below.
const chrome_before: Theme = .{
    .panel = .{ 0.16, 0.17, 0.20, 1 },
    .text = .{ 0.86, 0.87, 0.84, 1 },
    .track = .{ 0.27, 0.29, 0.33, 1 },
    .value = .{ 0.55, 0.85, 0.45, 1 },
    .control = .{ 0.78, 0.79, 0.82, 1 },
    .meter = .{ 0.45, 0.80, 0.42, 1 },
    .lighten = .{ 1, 1, 1, 1 },
    .darken = .{ 0, 0, 0, 1 },
    .arc = .{ arc_start, arc_sweep, 0, 0 },
    .background = .{ 0, 0, 0, 0 },
    .pad1 = .{ 0, 0, 0, 0 },
};

// Locks the `Theme` size, the arc constants, the zeroed pad and arc tail slots, and
// `background` at slot 9 (byte 144).
test "theme is 176 bytes and the arc is the open ring" {
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(Theme));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(Theme, "background"));
    try std.testing.expectApproxEqAbs(2.0 * std.math.pi / 3.0, chrome.arc[0], 0.0001);
    try std.testing.expectApproxEqAbs(3.0 * std.math.pi / 2.0, chrome.arc[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0), chrome.arc[2]);
    try std.testing.expectEqual(@as(f32, 0), chrome.arc[3]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad1[1]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad1[3]);
}

// Locks `dark.record()` against the record steps 1 to 30 uploaded: every slot equal but slot
// 9, the old `pad0`, which now holds the background (0.11, 0.12, 0.16, 1); `chrome` is that
// record; and the dark text styles and weights are the step 30 widget constants (Noto Sans and
// Mono 16 in the text color, 0.18 and 0.30).
test "dark records today's chrome with the background in slot 9" {
    const record = dark.record();
    const info = @typeInfo(Theme).@"struct";
    inline for (info.field_names, 0..) |field_name, slot| {
        const now = @field(record, field_name);
        if (slot == 9) {
            try std.testing.expectEqual([4]f32{ 0.11, 0.12, 0.16, 1 }, now);
            try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, @field(chrome_before, field_name));
        } else {
            try std.testing.expectEqual(@field(chrome_before, field_name), now);
        }
    }
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&chrome), std.mem.asBytes(&record)));
    try std.testing.expectEqual(text.Face.sans, dark.name.face);
    try std.testing.expectEqual(text.Face.mono, dark.value.face);
    try std.testing.expectEqual(@as(f32, 16), dark.value.size);
    try std.testing.expectEqual(dark.colors.text, dark.name.color);
    try std.testing.expectEqual(@as(f32, 0.18), dark.hover_lighten);
    try std.testing.expectEqual(@as(f32, 0.30), dark.down_darken);
}

// Locks `light`: a light background under darker text, its track in slot 2 of its record, every
// accent darker than dark's on every channel (by about 15%), and weights of 0.10 and 0.15.
test "light is a valid scheme darker in text and accents" {
    const record = light.record();
    try std.testing.expectEqual([4]f32{ 0.89, 0.91, 0.93, 1 }, record.background);
    try std.testing.expectEqual(light.colors.track, record.track);
    try std.testing.expect(light.colors.text[0] < light.colors.background[0]);
    for (light.accents, dark.accents) |lit, base| {
        for (0..3) |channel| {
            try std.testing.expect(lit[channel] < base[channel]);
            try std.testing.expectApproxEqAbs(base[channel] * 0.85, lit[channel], 0.01);
        }
    }
    try std.testing.expectEqual(@as(f32, 0.10), light.hover_lighten);
    try std.testing.expectEqual(@as(f32, 0.15), light.down_darken);
    try std.testing.expectEqual(record.arc, chrome.arc);
}

// Locks the presets' backgrounds off an 8-bit rounding tie (module guide, section 5): no
// component times 255 lies within 0.01 of a half (light's red is 0.89, 226.95; 0.90 would be
// 229.5, which the UHD 770 rounds one way as a clear value and the other as a shader output).
test "preset backgrounds are off an 8-bit rounding tie" {
    for ([_]Scheme{ dark, light }) |scheme| {
        for (scheme.colors.background) |component| {
            const scaled = component * 255;
            const fraction = scaled - @floor(scaled);
            try std.testing.expect(@abs(fraction - 0.5) > 0.01);
        }
    }
}

// Locks `problem`: a component of 1.5 names its color, a negative accent its index, a text
// size past `text.size_max` (512) its style, and a weight above 1 its name.
test "problem names the first field out of range" {
    comptime var bad = dark;
    bad.colors.panel[1] = 1.5;
    const panel = "colors.panel: a component is outside [0, 1]";
    try std.testing.expectEqualStrings(panel, comptime problem(bad).?);
    bad = dark;
    bad.accents[2][0] = -0.1;
    const accent = "accents[2]: a component is outside [0, 1]";
    try std.testing.expectEqualStrings(accent, comptime problem(bad).?);
    bad = dark;
    bad.value.size = text.size_max + 1;
    try std.testing.expectEqualStrings("value.size: must be in (0, 512]", comptime problem(bad).?);
    bad = dark;
    bad.down_darken = 2;
    try std.testing.expectEqualStrings("down_darken: must be in [0, 1]", comptime problem(bad).?);
}

// Locks the open-ring geometry: a three-quarter sweep leaves a quarter-turn gap, and the
// swept end plus the gap returns exactly to `arc_start`, so the ring has no overlap.
test "open ring gap is a quarter turn that closes at the start angle" {
    const gap: f32 = std.math.tau - arc_sweep;
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, gap, 0.00001);
    // The unwrapped end angle is arc_start + arc_sweep. Wrapped into [0, tau) it is pi/6,
    // that is 30 degrees clockwise of the +X axis.
    const end: f32 = arc_start + arc_sweep - std.math.tau;
    try std.testing.expectApproxEqAbs(std.math.pi / 6.0, end, 0.00001);
    try std.testing.expectApproxEqAbs(arc_start, end + gap, 0.00001);
}

// Locks the materials (section 7): the presets are glass and valid, `solid` is the default of
// both schemes, and `problem` names the first field out of range.
test "materials are glass but solid and name their first bad field" {
    try std.testing.expect(Material.frosted.glass());
    try std.testing.expect(!Material.solid.glass());
    try std.testing.expectEqual(Material.Kind.solid, dark.material.kind);
    var bad = Material.frosted;
    bad.blur = 60;
    try std.testing.expectEqualStrings("blur: must be in [0, 48]", bad.problem().?);
    bad = Material.clear;
    bad.saturation = 2.5;
    try std.testing.expectEqualStrings("saturation: must be in [0, 2]", bad.problem().?);
    const scheme = comptime blk: {
        var out = dark;
        out.material.rim = 2;
        break :blk out;
    };
    const message = comptime problem(scheme).?;
    try std.testing.expectEqualStrings("material.rim: must be in [0, 1]", message);
}

// Locks the default form (section 8) as the constants the default skin read before forms:
// corners 4, 6, 4, capsule 0.5, hairline 1, mark 2, filled controls, the underline, no frame;
// `dark` and `light` carry it; and the form is not in the record (`dark.record()` is `chrome`).
test "the default form is today's constants" {
    const form: Form = .{};
    try std.testing.expectEqual(@as(f32, 4), form.radius.control);
    try std.testing.expectEqual(@as(f32, 6), form.radius.popup);
    try std.testing.expectEqual(@as(f32, 4), form.radius.band);
    try std.testing.expectEqual(@as(f32, 0.5), form.capsule);
    try std.testing.expectEqual(@as(f32, 1), form.hairline);
    try std.testing.expectEqual(@as(f32, 2), form.mark);
    try std.testing.expectEqual(Form.Controls.filled, form.controls);
    try std.testing.expectEqual(Form.TabMark.underline, form.tab_mark);
    try std.testing.expect(!form.framed);
    try std.testing.expect(std.meta.eql(form, dark.form));
    try std.testing.expect(std.meta.eql(form, light.form));
    var square = dark;
    square.form.radius = .{ .control = 0, .popup = 0, .band = 0 };
    square.form.capsule = 0;
    const record = square.record();
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&chrome), std.mem.asBytes(&record)));
}

// Locks `Form.problem` (section 5): a popup radius of -1, a capsule of 0.6, a hairline of 5, a
// mark of 0, an outlined form with no hairline, and a NaN capsule each name their field, and
// `problem` prefixes "form.".
test "form problem names the first field out of range" {
    var bad: Form = .{};
    bad.radius.popup = -1;
    try std.testing.expectEqualStrings("radius.popup: must be in [0, 64]", bad.problem().?);
    bad = .{};
    bad.capsule = 0.6;
    try std.testing.expectEqualStrings("capsule: must be in [0, 0.5]", bad.problem().?);
    bad = .{};
    bad.hairline = 5;
    try std.testing.expectEqualStrings("hairline: must be in [0, 4]", bad.problem().?);
    bad = .{};
    bad.mark = 0;
    try std.testing.expectEqualStrings("mark: must be in (0, 4]", bad.problem().?);
    bad = .{};
    bad.controls = .outlined;
    bad.hairline = 0;
    const outlined = "hairline: outlined controls need a hairline above 0";
    try std.testing.expectEqualStrings(outlined, bad.problem().?);
    bad.hairline = 1;
    try std.testing.expect(bad.problem() == null);
    bad = .{};
    bad.capsule = std.math.nan(f32);
    try std.testing.expectEqualStrings("capsule: must be in [0, 0.5]", bad.problem().?);
    const scheme = comptime blk: {
        var out = dark;
        out.form.capsule = 0.6;
        break :blk out;
    };
    const message = comptime problem(scheme).?;
    try std.testing.expectEqualStrings("form.capsule: must be in [0, 0.5]", message);
}

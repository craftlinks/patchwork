//! Chrome colors, uniform packing layout, and open-ring arc angles.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Theme Rides in the Frame Uniform
//! Every draw type's pipeline binds one uniform at `@group(0) @binding(0)` whose WGSL type is
//! `Frame { ortho: mat4x4<f32>, theme: Theme }` (`draw/prelude.wgsl`). Placing `Theme`
//! directly after the projection matrix lets all pipelines share one bind group layout and one
//! bind group, and keeps color and arc-angle literals out of WGSL: widgets read `chrome` on the CPU
//! to fill per-instance colors, while the fragment shader reads `lighten`, `darken`, and `arc`
//! from the uniform.
//!
//! The frame record is `draw.matrix_bytes + bytes` long and must equal `draw.uniform_bytes`;
//! see the `comptime` block in `draw.zig` and the alignment rationale on `draw.uniform_bytes`.
//!
//! ## 2. Angle Convention
//! Angles come from `atan2(y, x)` in Y-down pixel space: 0 points along +X, and increasing
//! angles turn clockwise as seen on screen. The open ring starts at `arc_start`, sweeps
//! clockwise by `arc_sweep`, and leaves a gap of `tau - arc_sweep` that closes back at
//! `arc_start`. Test "open ring gap is a quarter turn that closes at the start angle" locks
//! this, and test "sdf arc locks the open ring" in `draw/types.zig` locks the distance field.
//!
//! ## 3. Layout Contract
//! `Theme` is an `extern struct` of `vec4<f32>` slots. `draw/registry.zig` generates the WGSL
//! `Theme` struct from this record's fields, in order, so the shader side cannot drift. WGSL
//! packs each `vec4<f32>` at 16 bytes, so slot `i` lives at byte `16 * i` of the record. The
//! `comptime` block below enforces the slot size, the per-field offsets, `bytes`, and
//! `slot_count`; test "source declares locations 1 to N and names every field" in
//! `draw/registry.zig` checks the generated declaration. The `pad*` slots stay zero so the record has
//! no uninitialized bytes when copied to the GPU.
//!
//! ## 4. Upload Flow
//! `draw/renderer.zig` keeps a `Uniform` record of the projection matrix at offset 0 followed by
//! `Theme` at offset `draw.matrix_bytes`, initialized from `chrome`. When the logical size
//! changes it records one `buffer_write` of the whole record, which both hosts replay. `chrome`
//! is a `comptime`-known constant, so the theme never changes at runtime and needs no
//! allocation.
//! Knob accents are per-instance colors in `draw.Arc`, not theme slots.

const std = @import("std");
const assert = std.debug.assert;

/// Number of `vec4` slots in `Theme`. Asserted equal to the field count.
pub const slot_count: u32 = 12;

/// Byte size of `Theme`. Asserted equal to `@sizeOf(Theme)`.
pub const bytes: u32 = 192;

/// Start angle of the open ring, in the angle convention of the module guide.
pub const arc_start: f32 = 2.0 * std.math.pi / 3.0;

/// Clockwise sweep of the full open ring. The remainder of the turn is the gap.
pub const arc_sweep: f32 = 3.0 * std.math.pi / 2.0;

/// One uniform theme. Field order is the GPU layout, so it must match the WGSL `Theme`.
///
/// `arc.x` is `arc_start` and `arc.y` is `arc_sweep`; `arc.z` and `arc.w` stay zero, as do
/// all `pad*` slots.
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
    pad0: [4]f32,
    pad1: [4]f32,
    pad2: [4]f32,
};

/// Straight (non-premultiplied) RGBA chrome. Knob accents are per-instance fills, not slots.
pub const chrome: Theme = .{
    .panel = .{ 0.16, 0.17, 0.20, 1 },
    .text = .{ 0.86, 0.87, 0.84, 1 },
    .track = .{ 0.27, 0.29, 0.33, 1 },
    .value = .{ 0.55, 0.85, 0.45, 1 },
    .control = .{ 0.78, 0.79, 0.82, 1 },
    .meter = .{ 0.45, 0.80, 0.42, 1 },
    .lighten = .{ 1, 1, 1, 1 },
    .darken = .{ 0, 0, 0, 1 },
    .arc = .{ arc_start, arc_sweep, 0, 0 },
    .pad0 = .{ 0, 0, 0, 0 },
    .pad1 = .{ 0, 0, 0, 0 },
    .pad2 = .{ 0, 0, 0, 0 },
};

comptime {
    assert(@sizeOf(Theme) == 192);
    assert(@alignOf(Theme) >= 4);
    assert(bytes == @sizeOf(Theme));
    assert(slot_count == 12);
    // WGSL lays each vec4<f32> out at 16 bytes, so slot i must start at byte 16 * i. Checking
    // every field catches a reordered or retyped field that the total size alone would miss.
    const info = @typeInfo(Theme).@"struct";
    assert(info.field_names.len == slot_count);
    for (info.field_names, info.field_types, 0..) |field_name, field_type, slot| {
        assert(field_type == [4]f32);
        assert(@offsetOf(Theme, field_name) == 16 * slot);
    }
    assert(chrome.arc[0] == arc_start);
    assert(chrome.arc[1] == arc_sweep);
    assert(chrome.arc[2] == 0);
    assert(chrome.arc[3] == 0);
    assert(chrome.pad0[0] == 0);
    assert(chrome.pad1[0] == 0);
    assert(chrome.pad2[0] == 0);
    assert(chrome.lighten[0] == 1);
    assert(chrome.darken[0] == 0);
}

// Locks the `Theme` size, the arc constants, and zeroed pad and arc tail slots.
test "theme is 192 bytes and the arc is the open ring" {
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(Theme));
    try std.testing.expectApproxEqAbs(2.0 * std.math.pi / 3.0, chrome.arc[0], 0.0001);
    try std.testing.expectApproxEqAbs(3.0 * std.math.pi / 2.0, chrome.arc[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 0), chrome.arc[2]);
    try std.testing.expectEqual(@as(f32, 0), chrome.arc[3]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad0[0]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad0[3]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad1[1]);
    try std.testing.expectEqual(@as(f32, 0), chrome.pad2[2]);
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

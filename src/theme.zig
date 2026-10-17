//! Chrome colors, uniform packing layout, and open-ring arc angles.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In modern GPU APIs (WebGPU, Vulkan, Metal), uniform buffer allocations and dynamic bind group
//! offsets are subject to strict minimum hardware alignment constraints:
//! - WebGPU Table 23 (`minUniformBufferOffsetAlignment`) mandates at least 256-byte alignment.
//! - A 4x4 float32 orthographic projection matrix requires only 64 bytes (16 floats * 4 bytes).
//! - Allocating an isolated 64-byte buffer either violates hardware alignment requirements or
//!   wastes 192 bytes as unmapped zero padding.
//!
//! Rather than stranding that space or creating an additional uniform buffer with its own
//! bind group allocation and descriptor tracking, Patchwork packs `Theme` (exactly 192 bytes)
//! into the spare tail of the 256-byte uniform buffer at byte offset 64:
//! - Offset  0..63  (64 bytes):  `mat4x4<f32>` orthographic projection matrix (`ortho`).
//! - Offset 64..255 (192 bytes): `Theme` uniform record (12 `vec4<f32>` slots).
//! Total allocation: exactly 256 bytes, satisfying the hardware alignment rule with zero waste.
//!
//! Both pipelines (`quad.wgsl` and `glyph.wgsl`) bind this exact 256-byte uniform buffer at
//! `@group(0) @binding(0)`, allowing both pipelines to share one bind group layout and one bind
//! group instance without pipeline rebinding penalties.
//!
//! Furthermore, storing theme colors and ring angles in the uniform decouples shader logic from
//! hardcoded magic literals:
//! - The CPU widgets read chrome colors to populate per-instance fills.
//! - The fragment shader reads `lighten`, `darken`, and `arc` angles from the uniform buffer.
//! - No color literals or arc angle constants exist in WGSL source code.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Space & Clockwise Angles:
//! - Screen pixel coordinates use top-left origin `(0, 0)` with `+X` right and `+Y` down.
//! - In this Y-down Cartesian system, `atan2(y, x)` is 0 radians at 3 o'clock (positive X axis),
//!   `+pi/2` at 6 o'clock (positive Y axis), `pi` at 9 o'clock (negative X axis), and `-pi/2`
//!   (or `+3pi/2` wrapped) at 12 o'clock (negative Y axis). Positive rotation is clockwise.
//!
//! ### Open-Ring Arc Angles:
//! - **Start Angle (`arc_start`):** `2.0 * pi / 3.0` radians (120 degrees, 7 o'clock).
//! - **Full Sweep Angle (`arc_sweep`):** `3.0 * pi / 2.0` radians (270 degrees clockwise).
//! - **End Angle:** `arc_start + arc_sweep = 2pi/3 + 3pi/2 = 13pi/6 = 2pi + pi/6` (30 degrees,
//!   5 o'clock).
//! - **Open Gap:** The remaining `pi / 2` radians (90 degrees, or bottom quarter of the circle)
//!   forms the open throat between 5 o'clock and 7 o'clock centered around 6 o'clock.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### 192-Byte `Theme` Memory Layout:
//! WebGPU uniform struct alignment packs each `vec4<f32>` at 16 bytes:
//!
//! ```text
//! +---------------+-------------------+-----------------------------------------------+
//! | Uniform Offs  | Theme Offs (Slot) | Field & Value RGBA / Radians                  |
//! +---------------+-------------------+-----------------------------------------------+
//! |  64..79       |   0..15   (Slot 0)| panel:   (0.16, 0.17, 0.20, 1.0)              |
//! |  80..95       |  16..31   (Slot 1)| text:    (0.86, 0.87, 0.84, 1.0)              |
//! |  96..111      |  32..47   (Slot 2)| track:   (0.27, 0.29, 0.33, 1.0)              |
//! | 112..127      |  48..63   (Slot 3)| value:   (0.55, 0.85, 0.45, 1.0)              |
//! | 128..143      |  64..79   (Slot 4)| control: (0.78, 0.79, 0.82, 1.0)              |
//! | 144..159      |  80..95   (Slot 5)| meter:   (0.45, 0.80, 0.42, 1.0)              |
//! | 160..175      |  96..111  (Slot 6)| lighten: (1.00, 1.00, 1.00, 1.0) [White]      |
//! | 176..191      | 112..127  (Slot 7)| darken:  (0.00, 0.00, 0.00, 1.0) [Black]      |
//! | 192..207      | 128..143  (Slot 8)| arc:     (arc_start, arc_sweep, 0.0, 0.0)     |
//! | 208..223      | 144..159  (Slot 9)| pad0:    (0.00, 0.00, 0.00, 0.0)              |
//! | 224..239      | 160..175 (Slot 10)| pad1:    (0.00, 0.00, 0.00, 0.0)              |
//! | 240..255      | 176..191 (Slot 11)| pad2:    (0.00, 0.00, 0.00, 0.0)              |
//! +---------------+-------------------+-----------------------------------------------+
//! ```
//! Total size: exactly 192 bytes (`slot_count * 16 = 12 * 16 = 192`).
//!
//! ### Chrome Colors vs. Per-Instance Knob Accents:
//! - Background clear color remains dark slate `(0.11, 0.12, 0.16, 1.0)`.
//! - Chrome colors are straight RGBA (unmultiplied alpha 1.0).
//! - Knob active arcs do NOT take their fill from theme slots. Instead, knob accents are
//!   per-instance fills passed in `Instance.fill`.
//! - As an intentional demo visual choice, the scene cycles through four distinct accents:
//!   - Purple: (0.62, 0.45, 0.86, 1.0)
//!   - Green:  (0.40, 0.78, 0.48, 1.0)
//!   - Orange: (0.93, 0.55, 0.24, 1.0)
//!   - Yellow: (0.93, 0.80, 0.32, 1.0)
//!
//! ## 4. State Machines & Data Flow
//! - **CPU Initialization:** `chrome` is declared as a compile-time constant.
//! - **GPU Upload:** Whenever `flag_uniform` is set (e.g. on startup or window resize), the host
//!   writes 64 bytes of matrix data at uniform buffer offset 0, followed immediately by 192 bytes
//!   of `Theme` data at offset 64.
//! - **Fragment Sampling:** `quad.wgsl` mixes toward `frame.theme.lighten` and `frame.theme.darken`
//!   and evaluates ring geometry using `frame.theme.arc`.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Wasm Exports:** `theme_ptr()` and `theme_len()` expose the memory address and 192-byte
//!   length to JavaScript in `web/shell.js`.
//! - **Native & Web Parity:** Both `gpu_wgpu.zig` and `web/shell.js` upload the 64-byte matrix
//!   then the 192-byte theme at uniform offset 64, binding minBindingSize 256.
//!
//! ## 6. TigerStyle Invariants
//! - **Comptime Layout Locking:** Compile-time assertions lock `@sizeOf(Theme) == 192`,
//!   `bytes == 192`, `slot_count == 12`, and slot contents.
//! - **Static Allocation:** Zero runtime heap allocations. Zero dynamic theme mutation.

const std = @import("std");
const assert = std.debug.assert;

/// Twelve `vec4` slots. WebGPU uniform layout packs each at 16 bytes.
pub const slot_count: u32 = 12;

/// Byte size of `Theme`. Uploaded at uniform offset 64.
pub const bytes: u32 = 192;

/// Arc start at 7 o'clock. `atan2` is 0 at 3 o'clock and positive clockwise in Y-down pixels.
pub const arc_start: f32 = 2.0 * std.math.pi / 3.0;

/// Full ring sweep, 270 degrees. The gap is the bottom quarter.
pub const arc_sweep: f32 = 3.0 * std.math.pi / 2.0;

/// One uniform theme. Field order is the GPU layout.
///
/// ```text
/// 0 panel   1 text    2 track   3 value
/// 4 control 5 meter   6 lighten 7 darken
/// 8 arc     9 pad     10 pad    11 pad
/// ```
///
/// `arc.x` is `arc_start`. `arc.y` is `arc_sweep`. Pads stay zero.
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

/// Straight RGBA chrome. Knob accents are per-instance fills, not slots here.
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

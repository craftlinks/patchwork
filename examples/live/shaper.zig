//! The inline shaper row's transfer curve: four knob values to 64 samples of a waveshaper.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why This Curve
//! There is no audio engine; the curve only has to respond visibly and boundedly to the four
//! knobs of `shape(gain, slope, twice, asymmetry)`. It uses the soft clip `s(u) = u / (1 +
//! |u|)`, which needs no transcendental function and stays inside (-1, 1) for any input.
//!
//! ## 2. Formula
//! For `x` in `[-1, 1]` at 64 evenly spaced points:
//! ```text
//! g(x) = (1 - k) * s(u) + k * s(u)^3      u = (1 + gain) * x + asymmetry, k = slope / 2
//! f(x) = g(g(x)) when twice >= 0.5, else g(x)       (twice folds the curve back on itself)
//! y(x) = clamp(f(x) - f(0), -1, 1)                  (the bias is removed, so y(0) = 0)
//! ```
//! `gain` drives the clip, `slope` blends toward the cube (bending the knee), `twice` applies
//! the shaper twice, and `asymmetry` biases the input so the two halves differ. The row plots
//! `y` over the fixed range `[-1, 1]` with `draw.path.plot`. Test "the transfer curve follows
//! the four knobs" locks sample values.
//!
//! ## 3. TigerStyle Invariants
//! - Pure and bounded: 64 samples, each a fixed number of operations.

const std = @import("std");
const assert = std.debug.assert;

/// Samples of the transfer curve.
pub const sample_count: u32 = 64;

/// Writes the transfer curve of the four knob values into `out` (section 2).
pub fn transfer(out: *[sample_count]f32, gain: f32, slope: f32, twice: f32, asymmetry: f32) void {
    assert(gain == gain);
    assert(slope == slope);
    const knobs: Knobs = .{
        .drive = 1 + gain,
        .bend = std.math.clamp(slope, -1, 1) * 0.5,
        .twice = twice >= 0.5,
        .bias = asymmetry,
    };
    const center = curve(knobs, 0);
    const last: f32 = @floatFromInt(sample_count - 1);
    for (out, 0..) |*sample, index| {
        const x = -1 + 2 * @as(f32, @floatFromInt(index)) / last;
        sample.* = std.math.clamp(curve(knobs, x) - center, -1, 1);
        assert(sample.* >= -1);
        assert(sample.* <= 1);
    }
}

const Knobs = struct {
    drive: f32,
    bend: f32,
    twice: bool,
    bias: f32,
};

fn curve(knobs: Knobs, x: f32) f32 {
    const once = stage(knobs, x);
    if (!knobs.twice) return once;
    return stage(knobs, once);
}

fn stage(knobs: Knobs, x: f32) f32 {
    const clipped = soft(knobs.drive * x + knobs.bias);
    const result = (1 - knobs.bend) * clipped + knobs.bend * clipped * clipped * clipped;
    assert(result >= -1.5);
    assert(result <= 1.5);
    return result;
}

fn soft(u: f32) f32 {
    const result = u / (1 + @abs(u));
    assert(@abs(result) < 1);
    return result;
}

comptime {
    assert(sample_count == 64);
}

const testing = std.testing;

// Locks the transfer curve: with the patch's knobs (gain 1.5, slope 0.25, twice 0, asymmetry
// 0.1) the ends are -0.7413 and 0.5994; twice folds them to -0.7635 and 0.3924; a zero gain,
// slope, and bias is the plain soft clip, odd and 0.5 at x = 1.
test "the transfer curve follows the four knobs" {
    var out: [sample_count]f32 = undefined;
    transfer(&out, 1.5, 0.25, 0, 0.1);
    try testing.expectApproxEqAbs(@as(f32, -0.7413), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5994), out[63], 1e-4);
    transfer(&out, 1.5, 0.25, 1, 0.1);
    try testing.expectApproxEqAbs(@as(f32, -0.7635), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.3924), out[63], 1e-4);
    transfer(&out, 0, 0, 0, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[63], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[0], 1e-6);
    for (out[0..32], 0..) |sample, index| {
        try testing.expectApproxEqAbs(-sample, out[63 - index], 1e-6);
    }
}

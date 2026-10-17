//! Host-driven level bars. One sample per wake, no second thread.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Host-Driven Metering
//! A meter needs a value that changes over time. Feeding it from a worker thread would bring
//! locks or atomics and memory-ordering hazards into a UI that otherwise has none. Here the
//! host's own timer drives everything: each wake calls `sample(now_ms)` once, so there are no
//! threads, no locks, and no atomics.
//!
//! `sample` is a pure function of time. Metering never reads widget state, so dragging a knob
//! cannot perturb a bar, and the same `now_ms` always yields the same levels, which is what
//! lets `Meter.set_value` suppress redundant redraws (test "the same time returns the same
//! three numbers").
//!
//! ## 2. Waveform Derivation
//! `now_ms` is integer milliseconds from a monotonic clock supplied by the host. Each meter
//! has a `Wave` with an even `period_ms` and a `phase_ms`, evaluated as a triangle wave:
//! ```text
//! along = (now_ms + phase_ms) % period_ms
//! half  = period_ms / 2
//!
//! along <= half:  level = along / half                 (rising)
//! along >  half:  level = (period_ms - along) / half   (falling)
//! ```
//! The reduction is integer arithmetic and the only floating-point step is the final division
//! in `f32`, so there are no trigonometric functions, no `f64`, and no accumulated drift.
//! Periods differ per meter so the bars do not move in lockstep.
//!
//! Each `phase_ms` is `period_ms / 4`, which puts every bar at the midpoint when `now_ms` is 0
//! so it matches the initial meter value in `rack_meter`. The comptime block asserts that
//! relation; test "sample at zero is the midpoint of every bar" locks the result, and test
//! "the locked timestamps hit empty and full" locks the peaks, the troughs, and the falling
//! slope.
//!
//! ## 3. Host Seam
//! `meter_period_ms` is the wake period the app puts in `config.timer_period_ms`, and
//! `period_ns` is the same interval for hosts that arm a nanosecond timer; the comptime block
//! asserts they agree. This file imports no platform code, so native hosts, the browser host,
//! and unit tests all run it unchanged.
//!
//! ## 4. TigerStyle Invariants
//! - `sample` and `level_at` are pure, allocation-free, and loop only over `meter_count`.
//! - Preconditions (positive even period) and the postcondition (`level` in `[0, 1]`) are
//!   asserted separately.

const std = @import("std");
const assert = std.debug.assert;

/// Bars on the rack, one per panel; the rack asserts the two counts match.
pub const meter_count: u32 = 3;

/// Host wake period. Native `period_ns` is this many milliseconds.
pub const meter_period_ms: u32 = 33;

/// `timerfd` interval equal to `meter_period_ms`; the comptime block enforces the relation.
pub const period_ns: u64 = 33_000_000;

const Wave = struct {
    period_ms: u32,
    phase_ms: u32,
};

/// One wave per meter, in panel order. Periods differ so the bars do not stay locked together.
const waves = [meter_count]Wave{
    .{ .period_ms = 2000, .phase_ms = 500 },
    .{ .period_ms = 3000, .phase_ms = 750 },
    .{ .period_ms = 4000, .phase_ms = 1000 },
};

comptime {
    assert(meter_count == 3);
    assert(meter_period_ms == 33);
    assert(period_ns == @as(u64, meter_period_ms) * 1_000_000);
    assert(waves.len == meter_count);
    // A quarter-period phase puts every bar at its midpoint at time zero.
    for (waves) |wave| {
        assert(wave.period_ms % 4 == 0);
        assert(wave.phase_ms * 4 == wave.period_ms);
    }
}

/// Three levels in `[0, 1]` at `now_ms`. The same time returns the same numbers.
pub fn sample(now_ms: u64) [meter_count]f32 {
    var out: [meter_count]f32 = undefined;
    var index: u32 = 0;
    while (index < meter_count) : (index += 1) {
        out[index] = level_at(now_ms, waves[index]);
        assert(out[index] >= 0);
        assert(out[index] <= 1);
    }
    assert(index == meter_count);
    return out;
}

fn level_at(now_ms: u64, wave: Wave) f32 {
    assert(wave.period_ms > 0);
    assert(wave.period_ms % 2 == 0);
    const period: u64 = wave.period_ms;
    const shifted = now_ms + @as(u64, wave.phase_ms);
    const along_u = shifted % period;
    const along: f32 = @floatFromInt(along_u);
    const half: f32 = @floatFromInt(wave.period_ms / 2);
    assert(half > 0);
    if (along <= half) {
        const rising = along / half;
        assert(rising >= 0);
        assert(rising <= 1);
        return rising;
    }
    const span: f32 = @floatFromInt(wave.period_ms);
    const falling = (span - along) / half;
    assert(falling >= 0);
    assert(falling <= 1);
    return falling;
}

// Locks the quarter-period phase: every bar starts at its midpoint, matching `rack_meter`.
test "sample at zero is the midpoint of every bar" {
    const levels = sample(0);
    try std.testing.expectEqual(@as(f32, 0.5), levels[0]);
    try std.testing.expectEqual(@as(f32, 0.5), levels[1]);
    try std.testing.expectEqual(@as(f32, 0.5), levels[2]);
}

// Locks the triangle wave at hand-checked times. With wave = (period_ms, phase_ms):
// t = 500: osc (2000, 500) has along = 1000 = half, so it peaks at 1; amp (4000, 1000) has
// along = 1500 of half = 2000, so it rises to 0.75.
// t = 750: filter (3000, 750) has along = 1500 = half, so it peaks at 1; osc has along = 1250
// past half = 1000, so it falls to (2000 - 1250) / 1000 = 0.75; amp has along = 1750 of
// half = 2000, so it rises to 0.875.
// t = 1500: osc has along = 0, so it is empty.
test "the locked timestamps hit empty and full" {
    const at_500 = sample(500);
    try std.testing.expectEqual(@as(f32, 1), at_500[0]);
    try std.testing.expectEqual(@as(f32, 0.75), at_500[2]);
    const at_1500 = sample(1500);
    try std.testing.expectEqual(@as(f32, 0), at_1500[0]);
    const at_750 = sample(750);
    try std.testing.expectEqual(@as(f32, 1), at_750[1]);
    try std.testing.expectEqual(@as(f32, 0.75), at_750[0]);
    try std.testing.expectEqual(@as(f32, 0.875), at_750[2]);
}

// Locks that `sample` is a pure function of time and stays within `[0, 1]`.
test "the same time returns the same three numbers" {
    const first = sample(500);
    const second = sample(500);
    try std.testing.expectEqual(first[0], second[0]);
    try std.testing.expectEqual(first[1], second[1]);
    try std.testing.expectEqual(first[2], second[2]);
    try std.testing.expect(first[0] >= 0);
    try std.testing.expect(first[0] <= 1);
    try std.testing.expect(first[1] >= 0);
    try std.testing.expect(first[1] <= 1);
}

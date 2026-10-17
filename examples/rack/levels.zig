//! Host-driven level bars. One sample per wake, no second thread.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! Real-time audio and synthesizer interfaces rely on responsive level meter visualization to
//! convey signal presence and output dynamic range.
//!
//! Naive implementations often spawn high-frequency background worker threads or simulate audio
//! DSP pipelines, introducing thread synchronization overhead, mutex contention, atomic memory
//! ordering hazards, or platform-specific audio driver dependencies.
//!
//! Patchwork avoids multi-threaded complexity by making level metering completely host-driven:
//! - **Single-Threaded Host Clock:** Meters are driven strictly by the host environment's main
//!   event loop. One sample is generated per timer wake, requiring zero background threads,
//!   zero locks, and zero atomics.
//! - **Pure Integer Arithmetic:** The wave calculation avoids trigonometric functions (`sin`,
//!   `cos`) and double-precision floating-point (`f64`). It evaluates periodic triangle waves
//!   using integer millisecond remainder arithmetic, performing a single division into `f32`
//!   so locked milestone timestamps hit exact fractional coordinates without floating drift.
//! - **Knob Decoupling:** `sample(now_ms)` is a pure function of time. Metering does not read
//!   widget knob states, and dragging a knob never perturbs the procedural bar animation.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Time Domain:
//! The input domain is integer milliseconds (`now_ms: u64`) sourced from platform monotonic clocks
//! (`CLOCK_MONOTONIC` on Linux, `performance.now()` in the browser).
//!
//! ### Analytical Triangle Wave Derivation:
//! Each meter `i` is defined by a `Wave` struct containing `period_ms` and `phase_ms`.
//! The wave cycles through rising `[0.0, 1.0]` and falling `[1.0, 0.0]` slopes:
//! ```text
//! shifted  = now_ms + phase_ms
//! along    = shifted % period_ms
//! half     = period_ms / 2
//!
//! rising  (along <= half): level = along / half
//! falling (along >  half): level = (period_ms - along) / half
//! ```
//!
//! ### Locked Waveform Parameters:
//! The rack defines 3 waves with distinct periods to prevent visual lockstep:
//! 1. `osc`:   `period_ms = 2000`, `phase_ms = 500`
//! 2. `filter`: `period_ms = 3000`, `phase_ms = 750`
//! 3. `amp`:    `period_ms = 4000`, `phase_ms = 1000`
//!
//! ### Locked Coordinate Milestones:
//! Because each wave's `phase_ms` is set to exactly `period_ms / 4`:
//! - **At `now_ms = 0`:** `along = period_ms / 4 = half / 2`.
//!   All three bars evaluate to exactly `0.5`:
//!   `levels[0] = 0.5`, `levels[1] = 0.5`, `levels[2] = 0.5`.
//!   This matches the initial value configured in `rack_meter`.
//! - **At `now_ms = 500`:**
//!   `osc` reaches `(500 + 500) % 2000 = 1000 = half` -> `level = 1.0` (peak).
//!   `amp` reaches `(500 + 1000) % 4000 = 1500 <= 2000` -> `1500 / 2000 = 0.75`.
//! - **At `now_ms = 750`:**
//!   `filter` reaches `(750 + 750) % 3000 = 1500 = half` -> `level = 1.0` (peak).
//!   `osc` reaches `(750 + 500) % 2000 = 1250 > 1000` -> `(2000 - 1250) / 1000 = 0.75`.
//! - **At `now_ms = 1500`:**
//!   `osc` reaches `(1500 + 500) % 2000 = 0` -> `level = 0.0` (empty).
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Static Constants & Limits:
//! - `meter_count: u32 = 3`: Exactly matches the 3 panels (`osc`, `filter`, `amp`).
//! - `meter_period_ms: u32 = 33`: Host wake period (approx. 30.3 Hz update frequency).
//! - `period_ns: u64 = 33_000_000`: Exact nanosecond equivalent for Linux `timerfd`.
//!
//! ### Stack Memory Layout:
//! `sample()` returns `[meter_count]f32` (12 bytes) by value on the stack. No heap allocation,
//! no pointer indirection, and no dynamic slices.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Host-Driven Execution Pipeline:
//! ```text
//! [Platform Wake (~33 ms)]
//!          |
//!          v
//! now_ms = monotonic_clock()
//!          |
//!          v
//! sampled = levels.sample(now_ms)
//!          |
//!          v
//! app.timer(now_ms)
//!          |---> writes slots 5, 11, 17
//!          |---> Meter.set_value(new_val) (returns true if changed)
//!          +---> if changed: app.scene.dirty = true
//! ```
//!
//! ### Idempotent Evaluation:
//! Passing the same `now_ms` returns identical values. `Meter.set_value` compares incoming
//! values and returns `false` when unchanged, preventing unnecessary frame invalidation.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Linux (Wayland):** The event loop initializes a nonblocking `timerfd` armed at `period_ns`
//!   when `config.timer_period_ms != 0`. On wake, `drain_timer` reads the current timestamp and
//!   calls `app.timer(now_ms)`.
//! - **Browser (WebAssembly):** `web/shell.js` arms a `setInterval` at `timer_period_ms()` (33 ms),
//!   calling the exported `wasm.timer(Math.floor(performance.now()))`. If `timer` returns 1,
//!   `shell.js` schedules a single `requestAnimationFrame`.
//! - **Platform Neutrality:** `levels.zig` contains zero platform-specific imports, running
//!   identically under native Linux, WebAssembly, and unit test harnesses.
//!
//! ## 6. TigerStyle Invariants
//! - **Pure Function Invariance:** `sample` and `level_at` are pure and free of side effects.
//! - **Bounded Loop Bounds:** Iteration bounded by compile-time `meter_count`.
//! - **Split Assertions:** Period positivity, even period division, half positivity, and normalized
//!   output ranges are asserted separately.
//! - **Zero Runtime Allocation:** BSS/stack-only execution with zero dynamic allocation.

const std = @import("std");
const assert = std.debug.assert;

/// Bars on the rack. One per panel.
pub const meter_count: u32 = 3;

/// Host wake period. Native `period_ns` is this many milliseconds.
pub const meter_period_ms: u32 = 33;

/// `timerfd` interval. 33 ms, matching `meter_period_ms`.
pub const period_ns: u64 = 33_000_000;

const Wave = struct {
    period_ms: u32,
    phase_ms: u32,
};

/// Osc, filter, amp. Periods differ so the bars do not stay locked together.
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

test "sample at zero is the midpoint of every bar" {
    const levels = sample(0);
    try std.testing.expectEqual(@as(f32, 0.5), levels[0]);
    try std.testing.expectEqual(@as(f32, 0.5), levels[1]);
    try std.testing.expectEqual(@as(f32, 0.5), levels[2]);
}

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

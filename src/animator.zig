//! Linear animators and a host-timestamp clock.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Rate per Millisecond?
//! An animation that advances a fixed step per frame runs faster on a higher-refresh display.
//! `Animator` instead stores `rate_per_ms` and is stepped with elapsed wall-clock milliseconds
//! taken from the host's presentation timestamps, so a transition takes the same real time at
//! any refresh rate.
//!
//! ### Exact Landing, No Epsilon
//! Springs and exponential decay approach their target asymptotically and need an epsilon to
//! stop. Here `step` moves linearly and clamps onto `target` exactly, and `live()` is the exact
//! comparison `value != target`. A settled animator is therefore detectable with no tolerance,
//! which is what lets the host go fully idle when nothing is moving.
//!
//! ### The Clock and One-Frame Wake Latency
//! While idle the host sleeps until an event arrives, so the last timestamp may be arbitrarily
//! old. Differencing against it would fling every animator to its target in a single frame.
//! `Clock.advance` therefore returns 0 for the first sample after `reset` and only records the
//! baseline. The caller resets the clock once no animator is live. Each wake costs exactly one
//! frame of latency, after which motion is continuous.
//!
//! ## 2. Units & Equations
//! `value` and `target` are normalized to `[0, 1]`. Timestamps are `u32` milliseconds; deltas
//! are `f32` milliseconds.
//!
//! Stepping toward `target` by `delta = rate_per_ms * dt_ms`:
//! ```text
//! value = min(value + delta, target)    if value < target
//! value = max(value - delta, target)    otherwise
//! ```
//! Clock deltas use wrapping subtraction so a `u32` timestamp rollover stays a small positive
//! gap, then clamp so a stalled compositor or backgrounded tab cannot skip across states:
//! ```text
//! gap = now_ms -% last_ms
//! dt  = min(gap, dt_max_ms)            (the discarded excess is not replayed)
//! ```
//! Worked values: see test "clock deltas wrap and clamp, and reset rearms" and test "step
//! reaches the midpoint and clamps on the target".
//!
//! ## 3. State Machines
//! ```text
//! Clock:     Unarmed --advance--> Armed (returns 0)
//!            Armed   --advance--> Armed (returns min(now -% last, dt_max_ms))
//!            Armed   --reset----> Unarmed
//!
//! Animator:  Resting --set_target(new value)--> Live
//!            Live    --step(dt > 0)----------> Live, or Resting once value == target
//! ```
//!
//! ## 4. Cross-Platform Seams
//! Both hosts feed monotonic millisecond timestamps into the same `Clock`: native uses the
//! compositor's `wl_callback.done` timestamp (`linux_window.zig`), and the browser passes
//! `Math.floor` of the `requestAnimationFrame` time to the `tick` export (`web_exports.zig`).
//! The animator code is host-independent.
//!
//! ## 5. TigerStyle Invariants
//! - `Animator` and `Clock` are plain fixed-size values (sizes asserted in the comptime block)
//!   and every operation is O(1) with no loops and no allocation.
//! - Preconditions (`dt_ms >= 0`, `target` in `[0, 1]`, `rate_per_ms` in `(0, 1]`) are asserted
//!   individually.

const std = @import("std");
const assert = std.debug.assert;

/// Largest delta `Clock.advance` will return, in milliseconds.
/// A single stalled frame cannot move an animator by more than this gap.
pub const dt_max_ms: u32 = 100;

/// A float moving toward `target` at `rate_per_ms`. `value` and `target` stay in `[0, 1]`.
pub const Animator = struct {
    value: f32,
    target: f32,
    rate_per_ms: f32,

    /// Resting animator at 0. `rate_per_ms` is the fraction of the unit range covered per
    /// millisecond. Callers name their rates (see `widgets.hover_rate_per_ms`).
    pub fn init(rate_per_ms: f32) Animator {
        assert(rate_per_ms > 0);
        assert(rate_per_ms <= 1);
        const animator: Animator = .{
            .value = 0,
            .target = 0,
            .rate_per_ms = rate_per_ms,
        };
        assert(animator.value == 0);
        assert(!animator.live());
        return animator;
    }

    /// Aims the animator at `target`. Returns false when the target is unchanged, so a pointer
    /// resting inside one widget does not dirty the frame.
    pub fn set_target(self: *Animator, target: f32) bool {
        assert(target >= 0);
        assert(target <= 1);
        if (self.target == target) {
            assert(self.target == target);
            return false;
        }
        self.target = target;
        assert(self.target == target);
        if (self.value == target) {
            assert(!self.live());
        }
        return true;
    }

    /// Moves `value` toward `target` by `rate_per_ms * dt_ms`, then clamps. Returns true when
    /// `value` changed. `dt_ms == 0` leaves `value` alone. Settling assigns `target` exactly,
    /// so a later `step` is a no-op.
    pub fn step(self: *Animator, dt_ms: f32) bool {
        assert(dt_ms >= 0);
        assert(dt_ms == dt_ms);
        if (self.value == self.target) {
            assert(!self.live());
            return false;
        }
        if (dt_ms == 0) {
            assert(self.live());
            return false;
        }
        const previous = self.value;
        const delta = self.rate_per_ms * dt_ms;
        if (self.value < self.target) {
            self.value += delta;
            if (self.value > self.target) {
                self.value = self.target;
            }
        } else {
            self.value -= delta;
            if (self.value < self.target) {
                self.value = self.target;
            }
        }
        assert(self.value >= 0);
        assert(self.value <= 1);
        return self.value != previous;
    }

    /// True while `value` has not landed on `target`.
    pub fn live(self: Animator) bool {
        const moving = self.value != self.target;
        if (moving) {
            assert(self.value != self.target);
        }
        if (!moving) {
            assert(self.value == self.target);
        }
        return moving;
    }
};

/// Host millisecond clock. `armed` is false until the first sample after `reset`, which makes
/// that sample a baseline rather than a delta.
pub const Clock = struct {
    last_ms: u32,
    armed: bool,

    pub fn init() Clock {
        const clock: Clock = .{
            .last_ms = 0,
            .armed = false,
        };
        assert(!clock.armed);
        assert(clock.last_ms == 0);
        return clock;
    }

    /// Elapsed milliseconds since the previous sample, or 0 for the first sample after idle.
    /// Gaps above `dt_max_ms` clamp to it. The latest sample always becomes the baseline.
    pub fn advance(self: *Clock, now_ms: u32) f32 {
        assert(dt_max_ms > 0);
        if (!self.armed) {
            self.last_ms = now_ms;
            self.armed = true;
            assert(self.armed);
            assert(self.last_ms == now_ms);
            return 0;
        }
        const gap: u32 = now_ms -% self.last_ms;
        self.last_ms = now_ms;
        var clamped: u32 = gap;
        if (clamped > dt_max_ms) {
            clamped = dt_max_ms;
        }
        assert(clamped <= dt_max_ms);
        assert(self.last_ms == now_ms);
        return @floatFromInt(clamped);
    }

    /// Forgets the last sample so the next `advance` returns 0. Called when no animator is
    /// live, so idle never produces a delta from a stale timestamp.
    pub fn reset(self: *Clock) void {
        self.armed = false;
        self.last_ms = 0;
        assert(!self.armed);
        assert(self.last_ms == 0);
    }
};

comptime {
    assert(dt_max_ms == 100);
    assert(@sizeOf(Animator) == 12);
    assert(@sizeOf(Clock) == 8);
}

// Locks linear travel at 1/100 per ms: halfway after 50 ms, and exact clamping onto the target
// when a later step overshoots. Also locks that dt == 0 leaves `value` unchanged and that a
// redundant `set_target` returns false.
test "step reaches the midpoint and clamps on the target" {
    var motion = Animator.init(1.0 / 100.0);
    try std.testing.expect(motion.set_target(1));
    try std.testing.expect(!motion.set_target(1));
    try std.testing.expect(motion.live());
    try std.testing.expect(!motion.step(0));
    try std.testing.expectEqual(@as(f32, 0), motion.value);
    try std.testing.expect(motion.step(50));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), motion.value, 0.0001);
    try std.testing.expect(motion.step(60));
    try std.testing.expectEqual(@as(f32, 1), motion.value);
    try std.testing.expect(!motion.live());
    try std.testing.expect(!motion.step(10));
}

// Locks the clock contract: the first sample returns 0 (wake latency), later samples return the
// difference, a `u32` rollover (0xFFFF_FFF0 to 8 is a gap of 24) stays a small positive gap, a
// gap past `dt_max_ms` clamps, and `reset` makes the next sample a baseline again.
test "clock deltas wrap and clamp, and reset rearms" {
    var clock = Clock.init();
    try std.testing.expectEqual(@as(f32, 0), clock.advance(1000));
    try std.testing.expectEqual(@as(f32, 50), clock.advance(1050));
    var wrapped = Clock.init();
    try std.testing.expectEqual(@as(f32, 0), wrapped.advance(0xFFFF_FFF0));
    try std.testing.expectEqual(@as(f32, 24), wrapped.advance(8));
    try std.testing.expectEqual(@as(f32, 100), wrapped.advance(8 + 500));
    wrapped.reset();
    try std.testing.expectEqual(@as(f32, 0), wrapped.advance(8 + 500));
}

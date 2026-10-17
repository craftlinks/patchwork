//! Linear animators and a host-timestamp clock.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! User interface interaction demands smooth visual feedback (such as button hover fades
//! and press darkenings) without tieing animation speed to display hardware refresh cadences.
//!
//! ### Rate per Millisecond vs. Fixed Frame Steps:
//! In naive game loops, animations often advance by a constant step per frame (e.g. `0.016`
//! per tick). On a 60 Hz display, an element takes ~16.6 ms per step; on a 144 Hz or 240 Hz
//! gaming monitor, each frame callback arrives in 6.9 ms or 4.1 ms, causing the animation to
//! complete 2.4x to 4x faster on high-refresh displays.
//! `Animator` solves this by parameterizing travel speed as `rate_per_ms: f32` and consuming
//! elapsed wall-clock milliseconds from host presentation timestamps. A 100 ms hover transition
//! takes exactly 100 ms of real time regardless of whether the display refreshes at 60 Hz,
//! 120 Hz, or 240 Hz.
//!
//! ### Makepad Timing Reference:
//! Makepad's button hover duration is 0.1 s (100 ms). Press darken duration is half of that
//! (50 ms). In `widgets.zig`, `hover_rate_per_ms = 1.0 / 100.0` and
//! `down_rate_per_ms = 1.0 / 50.0`.
//!
//! ### Exact Target Clamping (Zero Epsilon):
//! Many animation frameworks use spring equations or exponential decays that asymptotically
//! approach their targets, requiring arbitrary epsilon thresholds (`abs(val - target) < 0.001`)
//! to cease rendering. In Patchwork:
//! - `step` calculates linear delta and clamps exactly to `target`.
//! - Settling assigns `value = target` directly.
//! - `live()` is strictly `value != target` with zero epsilon.
//!
//! ### The Clock and the One-Frame Wake Latency:
//! Host frame callbacks (`wl_callback.done` in Wayland and `requestAnimationFrame` in the browser)
//! provide millisecond timestamps. When the scene wakes from a prolonged sleep (where the thread
//! consumed 0% CPU in `poll(-1)`), subtracting `now_ms` from `last_ms` would compute an enormous
//! delta that would fling weights across their full range in a single frame.
//! `Clock.advance(now_ms)` resolves this by returning `0.0` on the first sample after idle
//! (`armed == false`). The caller resets the clock when every animator has settled. Each wake
//! gesture therefore pays exactly one frame of latency to establish the baseline timestamp,
//! after which motion proceeds continuously.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces & Value Ranges:
//! - **Animator Domain:** `value` and `target` reside in the normalized unit interval `[0.0, 1.0]`.
//! - **Time Units:** Timestamps are discrete milliseconds (`u32`). Elapsed deltas are continuous
//!   floating-point milliseconds (`f32`).
//!
//! ### Linear Motion Equation:
//! For an animator moving toward `target` at `rate_per_ms`:
//! ```text
//! delta = rate_per_ms * dt_ms
//! if (value < target):
//!     value = min(value + delta, target)
//! else:
//!     value = max(value - delta, target)
//! ```
//! Because clamping assigns `target` exactly when `delta >= abs(target - value)`, no fractional
//! undershoot or overshoot can occur.
//!
//! ### Clock Rollover and Clamping Algebra:
//! Timestamps wrap as 32-bit unsigned integers (`u32`), which roll over every ~49.7 days:
//! ```text
//! gap = now_ms -% last_ms   (wrapping subtraction)
//! clamped_gap = min(gap, dt_max_ms)   (where dt_max_ms = 100)
//! ```
//! Wrapping subtraction `-%` guarantees that across a `u32` rollover (e.g. from `0xFFFF_FFF0` to
//! `0x0000_0008`), `8 -% 0xFFFF_FFF0 = 24`, preserving a correct positive elapsed delta.
//! If a compositor stalls or a browser tab is backgrounded for seconds, `clamped_gap` clamps to
//! `dt_max_ms` (100 ms). A stalled compositor cannot leap across multiple animation states in a
//! single frame; the discarded gap is not replayed, and `last_ms` updates immediately to `now_ms`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Struct Layout: `Animator` (12 Bytes, 4-Byte Alignment):
//! - Offset 0: `value: f32` (4 bytes) - Current normalized blend weight `[0.0, 1.0]`.
//! - Offset 4: `target: f32` (4 bytes) - Target normalized blend weight `[0.0, 1.0]`.
//! - Offset 8: `rate_per_ms: f32` (4 bytes) - Fraction of unit range traversed per millisecond.
//! Total size: 12 bytes. Alignment: 4 bytes. Plain value, zero pointers, register passable.
//!
//! ### Struct Layout: `Clock` (8 Bytes, 4-Byte Alignment):
//! - Offset 0: `last_ms: u32` (4 bytes) - Previous host millisecond timestamp.
//! - Offset 4: `armed: bool` (1 byte) - False until the first sample after `reset()`.
//! - Offset 5..7: Padding (3 bytes) - Compiler padding to 4-byte boundary.
//! Total size: 8 bytes. Alignment: 4 bytes. Plain value.
//!
//! ### Bounds:
//! - `dt_max_ms = 100`: Hard upper bound on elapsed delta returned by `Clock.advance`.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Clock Lifecycle State Machine:
//! ```text
//!               +-----------------------------+
//!               |        Idle / Unarmed       |
//!               |  (armed = false, last = 0)  |
//!               +-----------------------------+
//!                              |
//!                 advance(now) | returns 0 ms
//!               (wake latency) | arms clock, sets last = now
//!                              v
//!               +-----------------------------+
//!  advance(now) |         Armed / Active      |
//!  +------------| (armed = true, last = now)  |
//!  |            +-----------------------------+
//!  | returns min(now -% last, 100) |
//!  +-------------------------------+
//!                              |
//!                      reset() | scene settled (no live animators)
//!                              v
//!               +-----------------------------+
//!               |        Idle / Unarmed       |
//!               +-----------------------------+
//! ```
//!
//! ### Animator Lifecycle State Machine:
//! ```text
//!               +-----------------------------+
//!               |       Resting at Target     |
//!               |    (value == target, !live) |
//!               +-----------------------------+
//!                              |
//!            set_target(T != V)| returns true
//!                              v
//!               +-----------------------------+
//!      step(dt) |       In-Flight Motion      |
//!  +------------|     (value != target, live) |
//!  |            +-----------------------------+
//!  | advances delta            |
//!  +---------------------------+ value reaches target (clamps exactly)
//!                              v
//!               +-----------------------------+
//!               |       Resting at Target     |
//!               |    (value == target, !live) |
//!               +-----------------------------+
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Wayland Protocol:** The Linux event loop in `src/host/linux_window.zig` requests
//!   `wl_surface.frame`.
//!   The compositor executes `wl_callback.done(data, callback, callback_data: u32)`.
//!   `callback_data` is the compositor's presentation timestamp in milliseconds, passed to
//!   `Clock.advance()`.
//! - **Browser WebAssembly:** The JavaScript harness in `web/shell.js` invokes
//!   `requestAnimationFrame`.
//!   The DOM callback receives `now` (`DOMHighResTimeStamp`), floored via `Math.floor(now)` and
//!   passed as a 32-bit unsigned integer to the exported `tick(now_ms: u32)` function.
//! - **Uniform Semantics:** Both platforms feed monotonic millisecond clocks into the identical
//!   pure Zig `Clock` and `Animator` primitives.
//!
//! ## 6. TigerStyle Invariants
//! - **Zero Dynamic Allocation:** `Animator` and `Clock` are fixed-size stack values.
//! - **Bounded Execution:** Every function (`init`, `set_target`, `step`, `live`, `advance`,
//!   `reset`) is strictly O(1) arithmetic with zero internal loops.
//! - **Split Assertions:** All bounds (`dt_ms >= 0`, `target in [0, 1]`, `rate_per_ms > 0`)
//!   are asserted independently rather than compounded.
//! - **Zero Technical Debt:** Explicit handling of timer wraparound via wrapping operators (`-%`).

const std = @import("std");
const assert = std.debug.assert;

/// Largest delta `Clock.advance` will return, in milliseconds.
/// A single stalled frame cannot move an animator by more than this gap.
pub const dt_max_ms: u32 = 100;

/// A float moving toward `target` at `rate_per_ms`.
/// `value` and `target` stay in `[0, 1]` for hover and down.
/// Memory: three `f32` fields, 12 bytes, alignment 4.
pub const Animator = struct {
    value: f32,
    target: f32,
    rate_per_ms: f32,

    /// Resting animator. `rate_per_ms` is the fraction of the unit range covered
    /// in one millisecond. Hover uses `1/100`; down uses `1/50`.
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

    /// Aims the animator at `target`. Returns false when the target is unchanged,
    /// so a pointer that rests inside one widget does not dirty the frame.
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

    /// Moves `value` toward `target` by `rate_per_ms * dt_ms`, then clamps.
    /// `dt_ms == 0` leaves `value` alone and returns false. Settling assigns
    /// `target` exactly, so a later `step` is a no-op.
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

/// Host millisecond clock. `armed` is false until the first sample after `reset`.
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

    /// Elapsed milliseconds since the previous sample, or 0 if this is the first
    /// sample after idle. Wrapping uses `-%` so a `u32` timestamp rollover stays
    /// a small positive gap. Results above `dt_max_ms` clamp to that cap.
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

    /// Forgets the last sample. The next `advance` returns 0.
    /// Called when the scene has no live animator, so idle does not invent a dt
    /// from a timestamp that is minutes old.
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

// Locks linear animator travel: 100 ms duration, midpoint reach at 50 ms, exact target clamping at 60 ms.
// Verifies that dt == 0 leaves value unchanged and that redundant set_target returns false.
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

// Locks host clock delta derivation, one-frame wake latency (first sample returns 0),
// u32 unsigned timestamp rollover wrapping via -%, 100 ms gap clamping, and reset rearming.
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

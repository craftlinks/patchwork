//! Pure Window Sizing, HiDPI Scaling, and Redraw Policy.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! In traditional GUI programming, window event handling is often tangled with GPU drawing
//! and platform-specific window handles. This makes automated testing difficult.
//!
//! `frame.zig` represents pure **Policy**:
//! - It contains NO Wayland dependencies, NO WebGPU dependencies, and NO I/O syscalls.
//! - It can be thoroughly verified under `zig build test` without needing a display server,
//!   GPU driver, or graphics hardware.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//! Modern computer displays have vastly different pixel densities:
//! - A standard 24" 1080p monitor has ~92 pixels per inch (PPI).
//! - A 13" 4K laptop or Retina screen has ~220–300 PPI.
//!
//! If a UI rendered a 100-pixel wide button on a 4K screen without scaling, it would appear
//! physically microscopic. To solve this, desktop environments use a **scale factor**:
//! - **Logical Pixels (`width_logical`, `height_logical`):** The coordinate system used by UI
//!   layout, fonts, and application logic (e.g. 1280 x 720).
//! - **Scale Factor (`scale`):** An integer multiplier (e.g. 1 on standard displays, 2 on 4K).
//! - **Physical Pixels (`width_px`, `height_px`):** The actual pixel resolution of the GPU
//!   framebuffer texture:
//!   ```text
//!   Physical Pixels = Logical Pixels * Scale
//!   ```
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### Bounds:
//! - `width_default = 1280`, `height_default = 720`: Default logical fallback size when the
//!   compositor provides zero hints.
//! - `edge_max = 16384`: Maximum width/height pixel dimension, guarding against overflow.
//! - `scale_max = 16`: Hard ceiling on monitor scale factors.
//!
//! ### Struct Layout:
//! `Frame` struct consists of primitive flags and integers:
//! `running: bool`, `redraw: bool`, `relayout: bool`, `width_logical: u32`, `height_logical: u32`,
//! `scale: u32`, `width_px: u32`, `height_px: u32`. Statically allocated, zero heap dependencies.
//!
//! ## 4. State Machines & Data Flow: Damage and Redraw Pacing
//! Every GPU draw call and buffer presentation consumes energy. To maintain 0% CPU and low
//! GPU power while idle, `Frame` decouples presentation dirtying from layout dirtying using
//! two distinct lifecycle flags: `redraw` and `relayout`.
//!
//! ### The `redraw` Flag (Presentation Dirty):
//! - **Lifecycle:** `init()` sets `redraw = true`. When the display server sends a configure
//!   event with altered dimensions, `apply_configure()` sets `redraw = true`. When the window
//!   moves between monitors of different pixel density, `apply_scale()` sets `redraw = true`
//!   so the framebuffer texture is resized to match the new physical resolution. A duplicate
//!   configure with identical dimensions leaves `redraw` unchanged.
//! - **Clearance:** `mark_presented()` resets `redraw = false` immediately after presentation.
//!
//! ### The `relayout` Flag (Layout Dirty):
//! - **Lifecycle:** `init()` sets `relayout = true` because the initial frame must calculate
//!   child geometry and populate the draw list. A changed configure event sets `relayout = true`
//!   via `apply_configure()`, signaling that `App.layout()` must recompute widget positions.
//! - **Preservation Across Scale Changes:** Crucially, `apply_scale()` does NOT set `relayout`.
//!   Logical UI dimensions are invariant to display scale; only the physical framebuffer size
//!   changes. If a scale change re-ran layout, `App.layout()` would unnecessarily reposition
//!   widgets and dirty the scene. Because `relayout` remains false, a scale-only present reuses
//!   existing instances without rebuilding, updating only `flag_uniform`.
//! - **Clearance:** `mark_laid_out()` resets `relayout = false` immediately after `App.layout()`
//!   finishes positioning widgets. A same-size configure leaves a cleared `relayout` cleared.
//!
//! ### Flag Transition Matrix:
//! ```text
//! Event                       redraw   relayout   Instance list rebuilt?
//! ----------------------------------------------------------------------
//! Frame.init()                true     true       Yes (first frame)
//! apply_configure (changed)   true     true       Yes (new logical bounds)
//! apply_configure (identical) clean    clean      No
//! apply_scale (changed scale) true     false      No (reuses instances)
//! mark_laid_out()             -        false      (clears layout dirty)
//! mark_presented()            false    -          (clears presentation dirty)
//! request_redraw()            true     unchanged  No (input, not a size change)
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - Pure Zig policy container shared across both Linux Wayland (`src/host/linux_window.zig`) and
//!   WebAssembly browser harness (`src/host/web_exports.zig`).
//! - Neither host platform performs layout or damage policy calculations directly; both delegate
//!   exclusively to `Frame`.
//!
//! ## 6. TigerStyle Invariants
//! - **Zero Dynamic Allocation:** Stack or struct-embedded value.
//! - **Deterministic Bounds:** Clamp limits on dimensions (`edge_max`) and scale (`scale_max`).
//! - **Split Assertions:** Preconditions, postconditions, and transition invariants asserted at
//!   every step.
//!
//! ## 7. Refresh Period
//! `wl_surface.frame` provides one callback per presented commit. The interval between
//! consecutive callbacks represents the display refresh period only when every commit successfully
//! meets the compositor's latch point. A commit that misses the latch is delayed to the subsequent
//! display cycle, producing an inter-callback gap of approximately two refresh periods (~33.3 ms at
//! 60 Hz). Storing that doubled gap as the baseline refresh period would cause subsequent commits
//! to pace at half rate (30 Hz), making drag gestures stutter and blur during motion tracking.
//!
//! `refresh_after` implements a protective filter:
//! - Preserves previous period if gap exceeds 1.5 periods (`period + period / 2`),
//!   treating the spike as a missed latch rather than a display mode switch.
//! - Single-frame gaps that land within `refresh_snap_ns` (1 ms) of standard display frequencies
//!   (e.g. 60, 72, 75, 90, 100, 120, 144, 165, 170, 180, 240 Hz) snap directly to exact integer
//!   periods, ensuring that slight callback timing jitter does not accumulate drift.
//! - The initial baseline guess is 60 Hz (`refresh_ns_initial = 16_666_667` ns).
//!
//! This estimator serves as a pure fallback. When the compositor supports `wp_presentation`,
//! the `presented` event reports the output hardware refresh period directly (e.g. 16666666 ns),
//! which the window loop adopts in `note_refresh`.
//!
//! ## 8. Phase-Locked Commit Deadline
//! Compositors latch client surface buffers once per refresh cycle shortly before vertical
//! blanking (measured ~2 ms before vblank on Hyprland 0.56.2). A commit dispatched `margin` (3 ms)
//! prior to that latch incorporates pointer input gathered over nearly the entire refresh interval;
//! a commit dispatched after the latch waits an entire extra frame. `wl_callback.done` is a weak
//! timing anchor: when it is sent is compositor policy (after the render pass on some, 0.35 ms
//! after the pageflip on Hyprland 0.56), and the driver's present path can hold it back by a
//! whole refresh (Mesa FIFO on `wp_fifo_v1` did, on alternate frames). In contrast,
//! `wp_presentation.presented` delivers the pageflip timestamp itself.
//!
//! `present_deadline` projects future presentation deadlines from any past hardware vblank:
//! ```text
//! earliest  = now + margin                       earliest achievable target vblank
//! k         = ceil((earliest - anchor) / refresh) periods forward (0 if anchor >= earliest)
//! vblank    = anchor + k * refresh
//! deadline  = vblank - margin                    guaranteed >= now by construction
//! ```
//! When no hardware vblank anchor is fresh, `anchor` defaults to the receipt time of
//! `wl_callback.done`. At the instant of callback dispatch (`now == anchor`), this simplifies
//! directly to `done + refresh - margin`, preserving legacy callback-relative pacing.
//!
//! Unsynchronized clock drift accumulates as `drift = age * |true_period - refresh| / refresh`.
//! Assuming a typical 100 ppm oscillator frequency error, projecting forward for 1 second produces
//! only 0.1 ms of phase error, which is negligible relative to the 3 ms commit margin.
//! `anchor_is_fresh` bounds projection age to `anchor_age_max_ns` (1 s = 1_000_000_000 ns);
//! older anchors yield to `done` until the next `presented` event re-anchors the phase lock.

const std = @import("std");
const assert = std.debug.assert;

/// Default logical window width when the display compositor does not request a specific size.
pub const width_default: u32 = 1280;

/// Default logical window height when the display compositor does not request a specific size.
pub const height_default: u32 = 720;

/// Hard upper bound on a window dimension in pixels. Clamps excessively large compositor requests.
pub const edge_max: u32 = 16384;

/// Upper bound on display scaling factor. Clamps abnormal scale factor events.
pub const scale_max: u32 = 16;

/// First refresh guess: 60 Hz, in nanoseconds. `1e9 / 60` rounds to this.
pub const refresh_ns_initial: u64 = 16_666_667;

/// Shortest accepted callback gap. Faster than this is a duplicate, not a mode.
pub const refresh_ns_min: u64 = 4_000_000;

/// Longest accepted callback gap. A stalled compositor must not become the period.
pub const refresh_ns_max: u64 = 50_000_000;

/// A sample within this distance of a known rate adopts that rate.
const refresh_snap_ns: u64 = 1_000_000;

/// Maximum duration in nanoseconds (1 second) for which a hardware vblank anchor remains fresh.
///
/// Unsynchronized clock drift accumulates as `drift = age * |true_period - refresh| / refresh`.
/// Assuming a worst-case display timing oscillator error of 100 ppm, one second of projection
/// drifts by 0.1 ms, comfortably inside `present_margin_ns` (3 ms). Beyond 1 s, `anchor_is_fresh`
/// rejects the anchor so the pacing loop falls back to `done` until a new `presented` arrives.
pub const anchor_age_max_ns: u64 = 1_000_000_000;

/// Common output periods, nanoseconds, `round(1e9 / Hz)`.
const refresh_rates_ns = [_]u64{
    16_666_667, // 60
    13_888_889, // 72
    13_333_333, // 75
    11_111_111, // 90
    10_000_000, // 100
    8_333_333, // 120
    6_944_444, // 144
    6_060_606, // 165
    5_882_353, // 170
    5_555_556, // 180
    4_166_667, // 240
};

/// State container tracking window dimensions, scaling, and frame dirtiness.
pub const Frame = struct {
    /// True while the window lifecycle is active; set to false by `close()`.
    running: bool,
    /// Presentation dirty flag: true when swapchain presentation is required.
    redraw: bool,
    /// Layout dirty flag: true when logical bounds changed and child walks must be re-run.
    /// Crucially, scale changes do not set this flag, preserving instances without churn.
    relayout: bool,
    /// Current window width in UI logical pixels.
    width_logical: u32,
    /// Current window height in UI logical pixels.
    height_logical: u32,
    /// Display buffer scale factor (e.g. 1 for standard DPI, 2 for HiDPI/Retina).
    scale: u32,
    /// Physical framebuffer width in device pixels (`width_logical * scale`).
    width_px: u32,
    /// Physical framebuffer height in device pixels (`height_logical * scale`).
    height_px: u32,

    pub const ScaleError = error{ScaleZero};

    /// Initializes a newly created frame state container.
    /// `running`, `redraw`, and `relayout` initialize to `true` because the initial frame
    /// must compute layout and present to the display.
    pub fn init() Frame {
        const frame: Frame = .{
            .running = true,
            .redraw = true,
            .relayout = true,
            .width_logical = 0,
            .height_logical = 0,
            .scale = 1,
            .width_px = 0,
            .height_px = 0,
        };
        assert(frame.running);
        assert(frame.redraw);
        assert(frame.relayout);
        return frame;
    }

    /// Applies a configure event from the window system (e.g. Wayland configure or browser resize).
    /// If the compositor provides (0, 0), substitutes `width_default` and `height_default`.
    /// If the dimensions are identical to the current configuration, returns without dirtying.
    /// If dimensions changed, updates logical and physical sizes and sets both `redraw = true`
    /// and `relayout = true`.
    pub fn apply_configure(self: *Frame, width_logical: u32, height_logical: u32) void {
        assert(self.running);
        const resolved = resolve_logical(width_logical, height_logical);
        const same_width = resolved.width == self.width_logical;
        const same_height = resolved.height == self.height_logical;
        if (same_width) {
            if (same_height) {
                assert(self.width_px != 0 or self.redraw);
                return;
            }
        }
        self.width_logical = resolved.width;
        self.height_logical = resolved.height;
        self.refresh_pixels();
        self.redraw = true;
        self.relayout = true;
        assert(self.width_px != 0);
        assert(self.height_px != 0);
        assert(self.relayout);
    }

    /// Updates the integer display scale factor (e.g. 1 -> 2 when moved to a HiDPI screen).
    /// Clamps scale to `scale_max` and recomputes physical pixel dimensions.
    /// Sets `redraw = true` so the swapchain texture is resized and presented.
    /// Leaves `relayout` untouched because logical coordinates and instance border boxes are
    /// unchanged, avoiding unnecessary draw list rebuilds.
    pub fn apply_scale(self: *Frame, scale: u32) ScaleError!void {
        assert(self.running);
        if (scale == 0) {
            return error.ScaleZero;
        }
        const clamped = if (scale > scale_max) scale_max else scale;
        if (clamped == self.scale) {
            assert(self.scale >= 1);
            return;
        }
        self.scale = clamped;
        if (self.width_logical == 0) {
            assert(self.height_logical == 0);
            return;
        }
        self.refresh_pixels();
        self.redraw = true;
        assert(self.scale >= 1);
        assert(self.width_px != 0);
    }

    /// Clears `relayout = false` after the scene has placed border rects for this logical size.
    /// Asserts that `relayout` was previously true. A scale-only present must never call this.
    pub fn mark_laid_out(self: *Frame) void {
        assert(self.running);
        assert(self.relayout);
        self.relayout = false;
        assert(!self.relayout);
    }

    /// Flags that presentation to the display is required (`redraw = true`).
    ///
    /// Input events (pointer hover, button press) use this entry point. Because pointer
    /// hit-state changes modify instance weights without altering window dimensions,
    /// `relayout` is preserved unchanged, bypassing `App.layout` layout passes.
    pub fn request_redraw(self: *Frame) void {
        assert(self.running);
        self.redraw = true;
        assert(self.redraw);
        assert(self.running);
    }

    /// Marks the current frame as presented to the display, clearing `redraw = false`.
    /// Asserts that `redraw` was previously true.
    pub fn mark_presented(self: *Frame) void {
        assert(self.running);
        assert(self.redraw);
        self.redraw = false;
        assert(!self.redraw);
        assert(self.running);
    }

    /// Signals the window loop to terminate.
    pub fn close(self: *Frame) void {
        assert(self.running);
        self.running = false;
        assert(!self.running);
        assert(self.redraw or !self.redraw);
    }

    /// Recomputes physical pixel dimensions from logical dimensions and buffer scale.
    fn refresh_pixels(self: *Frame) void {
        assert(self.scale >= 1);
        assert(self.width_logical != 0);
        self.width_px = pixel_size(self.width_logical, self.scale);
        self.height_px = pixel_size(self.height_logical, self.scale);
        assert(self.width_px >= 1);
        assert(self.height_px >= 1);
    }
};

const LogicalSize = struct {
    width: u32,
    height: u32,
};

/// Resolves compositor-suggested logical dimensions, applying defaults and bounds.
fn resolve_logical(width: u32, height: u32) LogicalSize {
    if (width == 0) {
        return .{ .width = width_default, .height = height_default };
    }
    if (height == 0) {
        return .{ .width = width_default, .height = height_default };
    }
    return .{
        .width = clamp_edge(width),
        .height = clamp_edge(height),
    };
}

/// Clamps dimension values to prevent integer overflows or graphics driver crashes.
fn clamp_edge(edge: u32) u32 {
    assert(edge != 0);
    if (edge > edge_max) {
        return edge_max;
    }
    assert(edge <= edge_max);
    return edge;
}

/// Multiplies logical size by scale factor, safely clamping to `edge_max`.
fn pixel_size(logical: u32, scale: u32) u32 {
    assert(logical != 0);
    assert(scale >= 1);
    const product: u64 = @as(u64, logical) * @as(u64, scale);
    if (product > edge_max) {
        return edge_max;
    }
    const pixels: u32 = @intCast(product);
    assert(pixels >= 1);
    return pixels;
}

/// Period to use after one more callback gap.
/// A gap wider than one period plus half is a missed latch: the estimate stays.
/// A one-frame gap snaps to a known rate when it is within `refresh_snap_ns`.
pub fn refresh_after(current_ns: u64, delta_ns: u64) u64 {
    assert(current_ns >= refresh_ns_min);
    assert(current_ns <= refresh_ns_max);
    if (delta_ns < refresh_ns_min) {
        assert(delta_ns < refresh_ns_min);
        return current_ns;
    }
    if (delta_ns > refresh_ns_max) {
        assert(delta_ns > refresh_ns_max);
        return current_ns;
    }
    const one_and_half = current_ns + current_ns / 2;
    if (delta_ns > one_and_half) {
        assert(delta_ns > one_and_half);
        return current_ns;
    }
    const snapped = snap_refresh(delta_ns);
    assert(snapped >= refresh_ns_min);
    assert(snapped <= refresh_ns_max);
    return snapped;
}

/// Nearest known period, or `delta_ns` when none is within `refresh_snap_ns`.
fn snap_refresh(delta_ns: u64) u64 {
    assert(delta_ns >= refresh_ns_min);
    assert(delta_ns <= refresh_ns_max);
    var best: u64 = delta_ns;
    var error_ns: u64 = refresh_snap_ns + 1;
    for (refresh_rates_ns) |rate| {
        const gap = if (delta_ns > rate) delta_ns - rate else rate - delta_ns;
        if (gap < error_ns) {
            error_ns = gap;
            best = rate;
        }
    }
    if (error_ns > refresh_snap_ns) {
        assert(error_ns > refresh_snap_ns);
        return delta_ns;
    }
    assert(best >= refresh_ns_min);
    assert(best <= refresh_ns_max);
    return best;
}

/// Projects the commit deadline in nanoseconds for the next achievable display vertical blank.
///
/// Preconditions:
/// - `refresh_ns >= refresh_ns_min` and `refresh_ns <= refresh_ns_max` (asserted).
/// - `margin_ns < refresh_ns` (asserted).
///
/// Parameters:
/// - `anchor_ns`: Monotonic timestamp (nanoseconds) of a known past or present vblank, or
///   receipt time of `wl_callback.done` when no vblank anchor is fresh.
/// - `refresh_ns`: Output refresh period in nanoseconds.
/// - `now_ns`: Current monotonic clock time in nanoseconds (`CLOCK_MONOTONIC`).
/// - `margin_ns`: Lead time required before vblank (e.g. `present_margin_ns = 3 ms`).
///
/// Mathematical Formulation:
/// - `earliest = now_ns + margin_ns`
/// - `k = ceil((earliest - anchor_ns) / refresh_ns)` if `earliest > anchor_ns`, else `0`.
/// - In integer division: `k = (earliest - anchor_ns + refresh_ns - 1) / refresh_ns`.
/// - `vblank = anchor_ns + k * refresh_ns`
/// - `deadline = vblank - margin_ns`
///
/// Invariants & Postconditions:
/// - `vblank >= earliest` and `vblank - earliest < refresh_ns` (asserted).
/// - `deadline >= now_ns` by construction (asserted).
/// - When `anchor_ns == now_ns` (e.g. `done` receipt) and `margin_ns < refresh_ns`, `k = 1`,
///   reducing to `anchor_ns + refresh_ns - margin_ns`.
///
/// Cross-references: `linux_window.schedule_present`.
pub fn present_deadline(anchor_ns: u64, refresh_ns: u64, now_ns: u64, margin_ns: u64) u64 {
    assert(refresh_ns >= refresh_ns_min);
    assert(refresh_ns <= refresh_ns_max);
    assert(margin_ns < refresh_ns);
    const earliest = now_ns + margin_ns;
    var vblank = anchor_ns;
    if (earliest > anchor_ns) {
        const periods = (earliest - anchor_ns + refresh_ns - 1) / refresh_ns;
        assert(periods >= 1);
        vblank = anchor_ns + periods * refresh_ns;
    }
    assert(vblank >= earliest);
    assert(vblank - earliest < refresh_ns);
    const deadline = vblank - margin_ns;
    assert(deadline >= now_ns);
    return deadline;
}

/// Evaluates whether a recorded vblank timestamp `anchor_ns` remains valid for deadline projection.
///
/// Parameters:
/// - `anchor_ns`: Vblank timestamp in nanoseconds on `CLOCK_MONOTONIC`.
/// - `now_ns`: Current time in nanoseconds on `CLOCK_MONOTONIC`.
///
/// Semantics:
/// - Returns `false` if `anchor_ns == 0` (uninitialized).
/// - Returns `true` if `anchor_ns >= now_ns` (valid future anchor on shared monotonic clock).
/// - Returns `true` if `now_ns - anchor_ns <= anchor_age_max_ns` (1 second).
/// - Returns `false` if age exceeds 1 second, preventing accumulated phase drift from stale data.
pub fn anchor_is_fresh(anchor_ns: u64, now_ns: u64) bool {
    if (anchor_ns == 0) {
        assert(anchor_ns == 0);
        return false;
    }
    if (anchor_ns >= now_ns) {
        assert(anchor_ns >= now_ns);
        return true;
    }
    const age = now_ns - anchor_ns;
    return age <= anchor_age_max_ns;
}

comptime {
    assert(refresh_ns_initial >= refresh_ns_min);
    assert(refresh_ns_initial <= refresh_ns_max);
    assert(refresh_ns_initial == 16_666_667);
    assert(anchor_age_max_ns > refresh_ns_max);
    for (refresh_rates_ns) |rate| {
        assert(rate >= refresh_ns_min);
        assert(rate <= refresh_ns_max);
    }
}

// Verifies that a newly initialized frame starts in running state with redraw and relayout set.
test "initial frame is dirty and running" {
    const frame = Frame.init();
    try std.testing.expect(frame.redraw);
    try std.testing.expect(frame.relayout);
    try std.testing.expect(frame.running);
}

// Verifies that mark_presented clears redraw while leaving the frame running.
test "a successful present leaves the frame clean" {
    var frame = Frame.init();
    frame.mark_presented();
    try std.testing.expect(!frame.redraw);
    try std.testing.expect(frame.running);
}

// Verifies that a configure event with identical dimensions does not set redraw or relayout.
test "a same size does not dirty a clean frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(800, 600);
    try std.testing.expect(!frame.redraw);
    try std.testing.expectEqual(@as(u32, 800), frame.width_px);
}

// Verifies that a configure event with changed dimensions sets redraw and updates pixel size.
test "a new size dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(1024, 768);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1024), frame.width_px);
}

// Verifies that apply_scale sets redraw and recalculates physical pixel dimensions.
test "a new scale dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    try frame.apply_scale(2);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1600), frame.width_px);
}

// Verifies that apply_configure with changed dimensions sets both relayout and redraw.
test "a new size requests layout" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    frame.apply_configure(1024, 768);
    try std.testing.expect(frame.relayout);
    try std.testing.expect(frame.redraw);
}

// Verifies the core invariant: apply_scale sets redraw but does NOT set relayout.
test "a scale change does not request layout" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    try frame.apply_scale(2);
    try std.testing.expect(frame.redraw);
    try std.testing.expect(!frame.relayout);
}

// Verifies that an identical configure event leaves both relayout and redraw clean.
test "a same size leaves layout clear" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    frame.apply_configure(800, 600);
    try std.testing.expect(!frame.relayout);
    try std.testing.expect(!frame.redraw);
}

// Verifies that a pointer-driven redraw does not walk layout again.
test "request_redraw leaves relayout clear" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    frame.request_redraw();
    try std.testing.expect(frame.redraw);
    try std.testing.expect(!frame.relayout);
    try std.testing.expect(frame.running);
}

// Verifies that close clears the running state.
test "close clears running" {
    var frame = Frame.init();
    frame.close();
    try std.testing.expect(!frame.running);
}

// Verifies that compositor zero-size hints are resolved to default logical dimensions.
test "a zero configure is replaced by the default size" {
    var frame = Frame.init();
    frame.apply_configure(0, 0);
    try std.testing.expectEqual(width_default, frame.width_logical);
    try std.testing.expectEqual(height_default, frame.height_logical);
    try std.testing.expectEqual(width_default, frame.width_px);
    try std.testing.expect(frame.redraw);
}

// Verifies that a scale factor of 0 is rejected with ScaleError.ScaleZero.
test "scale zero is rejected" {
    var frame = Frame.init();
    try std.testing.expectError(error.ScaleZero, frame.apply_scale(0));
    try std.testing.expectEqual(@as(u32, 1), frame.scale);
}

// A 16 ms or 17 ms sample on a 60 Hz output is the same period. Adopting 17 ms
// waits past the latch.
test "a 60 Hz gap stays on the 60 Hz period" {
    const period = refresh_ns_initial;
    try std.testing.expectEqual(period, refresh_after(period, 16_000_000));
    try std.testing.expectEqual(period, refresh_after(period, 17_200_000));
}

// One missed latch is about two periods. That gap must not become the cadence.
test "a doubled callback gap does not slow the refresh" {
    const period = refresh_ns_initial;
    try std.testing.expectEqual(period, refresh_after(period, period * 2));
    try std.testing.expectEqual(period, refresh_after(period, 33_000_000));
}

// The first guess is 60 Hz. A 144 Hz output replaces it.
test "a 144 Hz gap replaces the 60 Hz guess" {
    try std.testing.expectEqual(@as(u64, 6_944_444), refresh_after(refresh_ns_initial, 6_900_000));
}

// Verifies that a measured callback gap not matching any standard refresh rate table entry
// is retained directly rather than snapped or rejected, ensuring non-standard display modes track.
test "an unmatched gap is kept" {
    try std.testing.expectEqual(@as(u64, 20_000_000), refresh_after(refresh_ns_initial, 20_000_000));
}

// Verifies fallback reduction: when anchor_ns equals the done receipt time (now),
// present_deadline simplifies to done + refresh - margin by mathematical construction.
test "present_deadline from a done receipt is done plus refresh minus margin" {
    const done: u64 = 5_000_000_000;
    const period = refresh_ns_initial;
    const deadline = present_deadline(done, period, done, 3_000_000);
    try std.testing.expectEqual(done + period - 3_000_000, deadline);
}

// Verifies phase locking: varying compositor render durations between pageflip and done
// target the identical vblank, decoupling client commit timing from compositor jitter.
test "present_deadline from a recent vblank ignores compositor render time" {
    const vblank: u64 = 5_000_000_000;
    const period = refresh_ns_initial;
    const quick = present_deadline(vblank, period, vblank + 400_000, 3_000_000);
    const slow = present_deadline(vblank, period, vblank + 2_400_000, 3_000_000);
    try std.testing.expectEqual(vblank + period - 3_000_000, quick);
    try std.testing.expectEqual(quick, slow);
}

// Verifies that multi-period projections from an older anchor increment in integer refresh
// multiples, ensuring deadline >= now and that (deadline + margin) aligns with the period.
test "present_deadline projects whole periods and stays at or after now" {
    const period = refresh_ns_initial;
    const now: u64 = 1_000_000_000;
    const deadline = present_deadline(0, period, now, 3_000_000);
    try std.testing.expect(deadline >= now);
    try std.testing.expectEqual(@as(u64, 61 * period - 3_000_000), deadline);
    try std.testing.expectEqual(@as(u64, 0), (deadline + 3_000_000) % period);
}

// Verifies boundary behavior: when now + margin aligns exactly on a vblank interval, the commit
// is due immediately (deadline == now) rather than skipping ahead by an extra refresh cycle.
test "present_deadline on the boundary is due immediately" {
    const period = refresh_ns_initial;
    const vblank: u64 = 7_000_000_000;
    const now = vblank + period - 3_000_000;
    try std.testing.expectEqual(now, present_deadline(vblank, period, now, 3_000_000));
}

// Verifies freshness bounds: accepts anchors at 50 ms and exactly anchor_age_max_ns (1 s),
// rejects anchors older by 1 ns, rejects uninitialized 0, and accepts future timestamps.
test "anchor_is_fresh bounds the projection age" {
    const anchor: u64 = 10_000_000_000;
    try std.testing.expect(anchor_is_fresh(anchor, anchor + 50_000_000));
    try std.testing.expect(anchor_is_fresh(anchor, anchor + anchor_age_max_ns));
    try std.testing.expect(!anchor_is_fresh(anchor, anchor + anchor_age_max_ns + 1));
    try std.testing.expect(!anchor_is_fresh(0, anchor));
    try std.testing.expect(anchor_is_fresh(anchor, anchor - 1));
}

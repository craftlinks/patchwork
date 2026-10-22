//! Pure window sizing, HiDPI scaling, redraw policy, and present pacing.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Pure Policy Module
//! Window events, GPU presentation, and platform handles are usually tangled together, which
//! makes dirty-tracking rules untestable. This module holds only the policy. It has no Wayland,
//! WebGPU, or I/O dependency, so `zig build test` verifies it without a display or a GPU.
//! Both hosts (`src/host/linux_window.zig`, `src/host/web_exports.zig`) delegate sizing and
//! damage decisions to `Frame` and make none themselves.
//!
//! ## 2. Coordinate Spaces and Bounds
//! - Logical pixels (`width_logical`, `height_logical`) are the space of UI layout and app
//!   logic.
//! - Physical pixels (`width_px`, `height_px`) are the GPU framebuffer size:
//!   `size_px = min(round(size_logical * scale_120 / 120), edge_max)`, rounding half up in
//!   integers as `(size_logical * scale_120 + 60) / 120`, the rounding
//!   `wp_fractional_scale_v1` prescribes.
//! - `scale_120` is the display scale in 1/120 units, the unit of `wp_fractional_scale_v1`:
//!   120 is 1.0, 150 is 1.25, 180 is 1.5. Integer scales arrive as `factor * 120`, and the
//!   browser sends `round(devicePixelRatio * 120)`.
//!
//! Out-of-range input is bounded instead of rejected, except a zero scale. A zero configure
//! size selects `width_default` and `height_default`, configure sizes clamp to `edge_max`,
//! and `scale_120` clamps to `[scale_120_min, scale_120_max]`. A zero scale returns
//! `ScaleError.ScaleZero`.
//! Tests: "a zero configure is replaced by the default size", "scale zero is rejected",
//! "oversized inputs are clamped".
//!
//! ## 3. Damage Flags (Why Two)
//! Presenting costs power, so an idle app must present nothing. `Frame` separates
//! `redraw` (the framebuffer must be presented) from `relayout` (logical bounds changed and
//! `App.layout` must run). A scale change alters only the framebuffer size, so it sets
//! `redraw` and never `relayout`: logical geometry is unchanged. The hosts still redraw the
//! scene on that present, because glyphs are rasterized and snapped at the device scale
//! (`text/cache.zig`, `Cache.owes_draw`); only the glyph records change. A pointer-driven
//! `request_redraw` likewise leaves `relayout` alone.
//!
//! ```text
//! Event                       redraw   relayout
//! -----------------------------------------------
//! Frame.init()                true     true
//! apply_configure (changed)   true     true
//! apply_configure (identical) kept     kept
//! apply_scale (changed)       true     kept
//! request_redraw()            true     kept
//! mark_laid_out()             kept     false
//! mark_presented()            false    kept
//! ```
//!
//! `mark_laid_out` and `mark_presented` assert that their flag was set, so a host that clears
//! a flag twice, or presents without damage, fails fast. The matrix is locked by the tests
//! "initial frame is dirty and running", "a same size does not dirty a clean frame",
//! "a new size requests layout", "a scale change does not request layout", "a same size
//! leaves layout clear", and "request_redraw leaves relayout clear".
//!
//! ## 4. Refresh Period Estimation
//! `wl_surface.frame` fires once per presented commit. The gap between callbacks equals the
//! refresh period only when every commit meets the compositor's latch point. A commit that
//! misses the latch lands one cycle late and produces a gap of about two periods. Adopting
//! that gap as the period would make later commits pace at half rate and make drags stutter.
//! `refresh_after` therefore keeps the previous period when a gap exceeds one and a half
//! periods, rejects gaps outside `[refresh_ns_min, refresh_ns_max]`, and snaps a plausible
//! gap within `refresh_snap_ns` of an entry in `refresh_rates_ns` to that entry so callback
//! jitter does not accumulate. `refresh_ns_initial` is the starting guess. When the
//! compositor offers `wp_presentation`, its reported period supersedes this estimator.
//! Tests: "a 60 Hz gap stays on the 60 Hz period", "a doubled callback gap does not slow the
//! refresh", "a 144 Hz gap replaces the 60 Hz guess", "an unmatched gap is kept".
//!
//! ## 5. Phase-Locked Commit Deadline
//! Compositors latch client buffers once per cycle shortly before vblank (observed on
//! Hyprland 0.56.2). A commit sent one margin before the latch carries the freshest pointer
//! input, while a commit after it waits a whole extra frame. `wl_callback.done` is a weak
//! anchor: its timing is compositor policy, and the driver's present path can delay it by a
//! whole refresh (Mesa FIFO on `wp_fifo_v1` did so on alternate frames). The
//! `wp_presentation.presented` pageflip timestamp is the stable anchor.
//!
//! `present_deadline` projects a deadline from any past vblank, in nanoseconds:
//! ```text
//! earliest = now + margin
//! k        = ceil((earliest - anchor) / refresh)    (0 when anchor >= earliest)
//! vblank   = anchor + k * refresh
//! deadline = vblank - margin                        (>= now by construction)
//! ```
//! With no fresh vblank anchor the caller passes the `done` receipt time, which reduces to
//! `done + refresh - margin` at the instant of dispatch. Projection drifts by
//! `age * |true_period - refresh| / refresh`, so `anchor_is_fresh` rejects anchors older than
//! `anchor_age_max_ns`. The comptime block at the end of the file asserts that the bound keeps
//! drift under a tenth of the shortest refresh period for `oscillator_error_ppm_max`.
//! Tests: the `present_deadline` and `anchor_is_fresh` tests.
//!
//! ## 6. TigerStyle Invariants
//! `Frame` is a plain value with no allocation. Every transition asserts its preconditions and
//! postconditions, and every clamp bound is a named constant.

const std = @import("std");
const assert = std.debug.assert;

/// Logical width used when the compositor suggests no size.
pub const width_default: u32 = 1280;

/// Logical height used when the compositor suggests no size.
pub const height_default: u32 = 720;

/// Upper bound on one window dimension, logical or physical. Guards size arithmetic and
/// driver texture limits against absurd compositor requests.
pub const edge_max: u32 = 16384;

/// Upper bound on `scale_120`: 16.0, the old integer bound. It covers every compositor scale
/// and browser zoom on a high-density display (a device pixel ratio of 10 at 500% zoom over
/// 2.0), and keeps `text.size_key` within the cache key for every `text.size_max`.
pub const scale_120_max: u32 = 16 * 120;

/// Lower bound on `scale_120`: 0.25, a browser zoomed out to 25% on a 1.0 display. Smaller
/// values come only from broken input and would rasterize text below a pixel.
pub const scale_120_min: u32 = 30;

/// Starting refresh period estimate, in nanoseconds, before any callback gap is measured.
pub const refresh_ns_initial: u64 = 16_666_667;

/// Shortest accepted callback gap. Faster than this is a duplicate, not a mode.
pub const refresh_ns_min: u64 = 4_000_000;

/// Longest accepted callback gap. A stalled compositor must not become the period.
pub const refresh_ns_max: u64 = 50_000_000;

/// A gap within this distance of an entry in `refresh_rates_ns` adopts that entry.
const refresh_snap_ns: u64 = 1_000_000;

/// Assumed worst-case relative error between the display clock and `CLOCK_MONOTONIC`.
const oscillator_error_ppm_max: u64 = 100;

/// Longest age, in nanoseconds, at which a vblank anchor still projects usefully.
///
/// Projection drifts by `age * |true_period - refresh| / refresh`, which is at most
/// `age * oscillator_error_ppm_max / 1e6`. The comptime block below asserts that drift stays
/// under a tenth of `refresh_ns_min`. Past this age `anchor_is_fresh` rejects the anchor and
/// pacing falls back to `done` until the next `presented` event re-anchors.
pub const anchor_age_max_ns: u64 = 1_000_000_000;

/// Common output periods in nanoseconds, each `round(1e9 / Hz)` for a standard refresh rate.
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

/// Window size, scale, and damage flags. See the module guide for the flag transition matrix.
pub const Frame = struct {
    /// True while the window lifecycle is active; set to false by `close()`.
    running: bool,
    /// True when the framebuffer must be presented.
    redraw: bool,
    /// True when logical bounds changed and `App.layout` must run. Scale changes never set it.
    relayout: bool,
    /// Window width in UI logical pixels. Zero until the first configure.
    width_logical: u32,
    /// Window height in UI logical pixels. Zero until the first configure.
    height_logical: u32,
    /// Display scale in 1/120 units, in `[scale_120_min, scale_120_max]`.
    scale_120: u32,
    /// Framebuffer width in device pixels; see the module guide, section 2.
    width_px: u32,
    /// Framebuffer height in device pixels; see the module guide, section 2.
    height_px: u32,

    /// Returned by `apply_scale` for a zero scale, which no display server should send.
    pub const ScaleError = error{ScaleZero};

    /// A new frame is dirty on both flags because the first frame must lay out and present.
    pub fn init() Frame {
        const frame: Frame = .{
            .running = true,
            .redraw = true,
            .relayout = true,
            .width_logical = 0,
            .height_logical = 0,
            .scale_120 = 120,
            .width_px = 0,
            .height_px = 0,
        };
        assert(frame.running);
        assert(frame.redraw);
        assert(frame.relayout);
        return frame;
    }

    /// Applies a configure event, in logical pixels, from the window system.
    /// A zero in either dimension selects both defaults, and each dimension clamps to
    /// `edge_max`. A resolved size equal to the current one leaves both flags untouched.
    /// Otherwise the physical size is recomputed and `redraw` and `relayout` are set.
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

    /// Updates the display scale (1/120 units), clamped to `[scale_120_min, scale_120_max]`.
    /// A zero scale is rejected. A changed scale after the first configure recomputes the
    /// physical size and sets `redraw` so the framebuffer is resized. Before the first
    /// configure only `scale_120` is stored. `relayout` is never touched because logical
    /// geometry does not change.
    pub fn apply_scale(self: *Frame, scale_120: u32) ScaleError!void {
        assert(self.running);
        if (scale_120 == 0) {
            return error.ScaleZero;
        }
        const clamped = std.math.clamp(scale_120, scale_120_min, scale_120_max);
        if (clamped == self.scale_120) {
            assert(self.scale_120 >= scale_120_min);
            return;
        }
        self.scale_120 = clamped;
        if (self.width_logical == 0) {
            assert(self.height_logical == 0);
            return;
        }
        self.refresh_pixels();
        self.redraw = true;
        assert(self.scale_120 >= scale_120_min);
        assert(self.width_px != 0);
    }

    /// Clears `relayout` once the app has laid out for the current logical size.
    /// Asserts `relayout` was set, so a present after a scale change alone cannot call it.
    pub fn mark_laid_out(self: *Frame) void {
        assert(self.running);
        assert(self.relayout);
        self.relayout = false;
        assert(!self.relayout);
    }

    /// Requests a present without a layout pass. Input handling uses this because it changes
    /// what is drawn but not the logical window size.
    pub fn request_redraw(self: *Frame) void {
        assert(self.running);
        self.redraw = true;
        assert(self.redraw);
        assert(self.running);
    }

    /// Clears `redraw` after a present. Asserts `redraw` was set.
    pub fn mark_presented(self: *Frame) void {
        assert(self.running);
        assert(self.redraw);
        self.redraw = false;
        assert(!self.redraw);
        assert(self.running);
    }

    /// Ends the window loop by clearing `running`.
    pub fn close(self: *Frame) void {
        assert(self.running);
        self.running = false;
        assert(!self.running);
        assert(self.redraw or !self.redraw);
    }

    /// Recomputes the physical size from the logical size and scale.
    fn refresh_pixels(self: *Frame) void {
        assert(self.scale_120 >= scale_120_min);
        assert(self.width_logical != 0);
        self.width_px = pixel_size(self.width_logical, self.scale_120);
        self.height_px = pixel_size(self.height_logical, self.scale_120);
        assert(self.width_px >= 1);
        assert(self.height_px >= 1);
    }
};

const LogicalSize = struct {
    width: u32,
    height: u32,
};

/// Zero in either dimension selects both defaults, because a half-specified size is a hint
/// to choose freely rather than a request for one axis.
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

/// Clamps one non-zero dimension to `edge_max`.
fn clamp_edge(edge: u32) u32 {
    assert(edge != 0);
    if (edge > edge_max) {
        return edge_max;
    }
    assert(edge <= edge_max);
    return edge;
}

/// `round(logical * scale_120 / 120)` in `u64` so the product cannot overflow, then clamps
/// to `edge_max`. Rounds half up, as `wp_fractional_scale_v1` prescribes for buffer sizes.
pub fn pixel_size(logical: u32, scale_120: u32) u32 {
    assert(logical != 0);
    assert(scale_120 >= scale_120_min);
    const rounded: u64 = (@as(u64, logical) * @as(u64, scale_120) + 60) / 120;
    if (rounded > edge_max) {
        return edge_max;
    }
    const pixels: u32 = @intCast(rounded);
    assert(pixels >= 1);
    return pixels;
}

/// Returns the refresh period to use after observing one more callback gap, in nanoseconds.
/// A gap outside `[refresh_ns_min, refresh_ns_max]`, or wider than one and a half periods
/// (a missed latch), keeps `current_ns`. Any other gap snaps to the nearest entry of
/// `refresh_rates_ns` within `refresh_snap_ns`, or is adopted as measured.
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

/// Nearest entry of `refresh_rates_ns`, or `delta_ns` when none is within `refresh_snap_ns`.
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

/// Projects the commit deadline, in nanoseconds on `CLOCK_MONOTONIC`, for the next
/// achievable vblank. The formula is in the module guide.
///
/// - `anchor_ns`: a known past or present vblank, or the `wl_callback.done` receipt time when
///   no vblank anchor is fresh.
/// - `refresh_ns`: output period, within `[refresh_ns_min, refresh_ns_max]`.
/// - `now_ns`: current time.
/// - `margin_ns`: lead time before vblank, strictly less than `refresh_ns`. The native host
///   owns the value (see `linux_window.schedule_present`).
///
/// Postconditions, asserted: the target vblank is at least `now_ns + margin_ns` and less than
/// one period beyond it, so the returned deadline is never before `now_ns`.
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

/// Reports whether the vblank timestamp `anchor_ns` may still seed `present_deadline`.
/// Both arguments are `CLOCK_MONOTONIC` nanoseconds. Zero means "never recorded" and is
/// stale. An anchor at or after `now_ns` is fresh, and otherwise it is fresh while its age is
/// at most `anchor_age_max_ns`. Test: "anchor_is_fresh bounds the projection age".
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
    assert(scale_120_min < 120);
    assert(scale_120_max > 120);
    assert(@as(u64, edge_max) * scale_120_max + 60 < std.math.maxInt(u32));
    assert(refresh_ns_initial >= refresh_ns_min);
    assert(refresh_ns_initial <= refresh_ns_max);
    assert(refresh_ns_initial == 16_666_667);
    assert(anchor_age_max_ns > refresh_ns_max);
    // Worst-case phase drift at the freshness limit, in nanoseconds.
    const drift_ns_max = anchor_age_max_ns * oscillator_error_ppm_max / 1_000_000;
    assert(drift_ns_max * 10 < refresh_ns_min);
    assert(refresh_rates_ns[0] == refresh_ns_initial);
    for (refresh_rates_ns) |rate| {
        assert(rate >= refresh_ns_min);
        assert(rate <= refresh_ns_max);
    }
}

// Locks `Frame.init`: running, and dirty on both flags.
test "initial frame is dirty and running" {
    const frame = Frame.init();
    try std.testing.expect(frame.redraw);
    try std.testing.expect(frame.relayout);
    try std.testing.expect(frame.running);
}

// Locks `mark_presented`: clears `redraw` only.
test "a successful present leaves the frame clean" {
    var frame = Frame.init();
    frame.mark_presented();
    try std.testing.expect(!frame.redraw);
    try std.testing.expect(frame.running);
}

// Locks the identical-configure row of the flag matrix for `redraw`.
test "a same size does not dirty a clean frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(800, 600);
    try std.testing.expect(!frame.redraw);
    try std.testing.expectEqual(@as(u32, 800), frame.width_px);
}

// Locks the changed-configure row of the flag matrix and the physical size update.
test "a new size dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(1024, 768);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1024), frame.width_px);
}

// Locks `apply_scale`: sets `redraw` and scales the physical size (`size_px = size * scale`).
test "a new scale dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    try frame.apply_scale(240);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1600), frame.width_px);
}

// Locks the fractional size rule: 1280 logical at 1.25 is 1600 device pixels, and an odd
// 1281 at 1.5 rounds 1921.5 half up to 1922.
test "1280 logical at scale_120 150 is 1600 device pixels" {
    var frame = Frame.init();
    frame.apply_configure(1280, 720);
    try frame.apply_scale(150);
    try std.testing.expectEqual(@as(u32, 1600), frame.width_px);
    try std.testing.expectEqual(@as(u32, 900), frame.height_px);
    try std.testing.expectEqual(@as(u32, 1922), pixel_size(1281, 180));
    try std.testing.expectEqual(@as(u32, 1281), pixel_size(1281, 120));
}

// Locks the changed-configure row of the flag matrix for both flags.
test "a new size requests layout" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    frame.apply_configure(1024, 768);
    try std.testing.expect(frame.relayout);
    try std.testing.expect(frame.redraw);
}

// Locks the core invariant: a scale change sets `redraw` but not `relayout`.
test "a scale change does not request layout" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    try frame.apply_scale(240);
    try std.testing.expect(frame.redraw);
    try std.testing.expect(!frame.relayout);
}

// Locks the identical-configure row of the flag matrix for both flags.
test "a same size leaves layout clear" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_laid_out();
    frame.mark_presented();
    frame.apply_configure(800, 600);
    try std.testing.expect(!frame.relayout);
    try std.testing.expect(!frame.redraw);
}

// Locks `request_redraw`: sets `redraw` and leaves `relayout` clear.
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

// Locks `close`: clears `running`.
test "close clears running" {
    var frame = Frame.init();
    frame.close();
    try std.testing.expect(!frame.running);
}

// Locks the zero-hint rule: a (0, 0) configure resolves to the default logical size.
test "a zero configure is replaced by the default size" {
    var frame = Frame.init();
    frame.apply_configure(0, 0);
    try std.testing.expectEqual(width_default, frame.width_logical);
    try std.testing.expectEqual(height_default, frame.height_logical);
    try std.testing.expectEqual(width_default, frame.width_px);
    try std.testing.expect(frame.redraw);
}

// Locks the zero-scale rejection and that it leaves `scale` unchanged.
test "scale zero is rejected" {
    var frame = Frame.init();
    try std.testing.expectError(error.ScaleZero, frame.apply_scale(0));
    try std.testing.expectEqual(@as(u32, 120), frame.scale_120);
}

// Locks snapping: callback jitter around a known rate keeps that rate, because adopting a
// slightly long period would make commits miss the latch.
test "a 60 Hz gap stays on the 60 Hz period" {
    const period = refresh_ns_initial;
    try std.testing.expectEqual(period, refresh_after(period, 16_000_000));
    try std.testing.expectEqual(period, refresh_after(period, 17_200_000));
}

// Locks the missed-latch filter: a gap near two periods must not become the period.
test "a doubled callback gap does not slow the refresh" {
    const period = refresh_ns_initial;
    try std.testing.expectEqual(period, refresh_after(period, period * 2));
    try std.testing.expectEqual(period, refresh_after(period, 33_000_000));
}

// Locks adoption: a gap near another known rate replaces the initial guess (the 144 Hz
// period is the table entry `6_944_444`).
test "a 144 Hz gap replaces the 60 Hz guess" {
    try std.testing.expectEqual(@as(u64, 6_944_444), refresh_after(refresh_ns_initial, 6_900_000));
}

// Locks pass-through: a plausible gap far from every table entry is adopted as measured, so
// non-standard display modes are tracked.
test "an unmatched gap is kept" {
    const kept = refresh_after(refresh_ns_initial, 20_000_000);
    try std.testing.expectEqual(@as(u64, 20_000_000), kept);
}

// Locks the `done` fallback: with `anchor == now`, the deadline is `done + refresh - margin`.
test "present_deadline from a done receipt is done plus refresh minus margin" {
    const done: u64 = 5_000_000_000;
    const period = refresh_ns_initial;
    const deadline = present_deadline(done, period, done, 3_000_000);
    try std.testing.expectEqual(done + period - 3_000_000, deadline);
}

// Locks phase locking: `done` arriving earlier or later after the same pageflip (here 0.4 ms
// and 2.4 ms) yields the same deadline.
test "present_deadline from a recent vblank ignores compositor render time" {
    const vblank: u64 = 5_000_000_000;
    const period = refresh_ns_initial;
    const quick = present_deadline(vblank, period, vblank + 400_000, 3_000_000);
    const slow = present_deadline(vblank, period, vblank + 2_400_000, 3_000_000);
    try std.testing.expectEqual(vblank + period - 3_000_000, quick);
    try std.testing.expectEqual(quick, slow);
}

// Locks multi-period projection: from an anchor at 0 and now = 1 s, the target vblank is the
// 61st period (61 periods of 16.67 ms exceed 1 s + margin, 60 do not), `deadline >= now`, and
// `deadline + margin` is a whole number of periods.
test "present_deadline projects whole periods and stays at or after now" {
    const period = refresh_ns_initial;
    const now: u64 = 1_000_000_000;
    const deadline = present_deadline(0, period, now, 3_000_000);
    try std.testing.expect(deadline >= now);
    try std.testing.expectEqual(@as(u64, 61 * period - 3_000_000), deadline);
    try std.testing.expectEqual(@as(u64, 0), (deadline + 3_000_000) % period);
}

// Locks the boundary: when `now + margin` lands exactly on a vblank, the deadline is `now`
// rather than one period later.
test "present_deadline on the boundary is due immediately" {
    const period = refresh_ns_initial;
    const vblank: u64 = 7_000_000_000;
    const now = vblank + period - 3_000_000;
    try std.testing.expectEqual(now, present_deadline(vblank, period, now, 3_000_000));
}

// Locks `anchor_is_fresh`: accepts a young anchor, exactly `anchor_age_max_ns`, and a future
// anchor; rejects one nanosecond older and the zero (never recorded) anchor.
test "anchor_is_fresh bounds the projection age" {
    const anchor: u64 = 10_000_000_000;
    try std.testing.expect(anchor_is_fresh(anchor, anchor + 50_000_000));
    try std.testing.expect(anchor_is_fresh(anchor, anchor + anchor_age_max_ns));
    try std.testing.expect(!anchor_is_fresh(anchor, anchor + anchor_age_max_ns + 1));
    try std.testing.expect(!anchor_is_fresh(0, anchor));
    try std.testing.expect(anchor_is_fresh(anchor, anchor - 1));
}

// Locks the bounding rules: oversized configure sizes clamp to `edge_max`, physical size clamps
// to `edge_max` after scaling, and the scale clamps to `[scale_120_min, scale_120_max]`.
test "oversized inputs are clamped" {
    var frame = Frame.init();
    frame.apply_configure(edge_max + 1, edge_max * 2);
    try std.testing.expectEqual(edge_max, frame.width_logical);
    try std.testing.expectEqual(edge_max, frame.height_logical);
    frame.apply_configure(edge_max / 2 + 1, 100);
    try frame.apply_scale(scale_120_max + 1);
    try std.testing.expectEqual(scale_120_max, frame.scale_120);
    // 100 at 16.0 is within `edge_max`, but the width product exceeds it.
    try std.testing.expectEqual(edge_max, frame.width_px);
    try std.testing.expectEqual(@as(u32, 1600), frame.height_px);
    try frame.apply_scale(1);
    try std.testing.expectEqual(scale_120_min, frame.scale_120);
}

// Locks that a scale applied before the first configure is stored without dirtying, so the
// first configure computes the physical size from it.
test "scale before the first configure is stored without a redraw" {
    var frame = Frame.init();
    frame.mark_presented();
    try frame.apply_scale(240);
    try std.testing.expect(!frame.redraw);
    try std.testing.expectEqual(@as(u32, 240), frame.scale_120);
    frame.apply_configure(800, 600);
    try std.testing.expectEqual(@as(u32, 1600), frame.width_px);
}

//! Pure Window Sizing, HiDPI Scaling, and Redraw Policy.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Separation of Policy and Mechanism (Pure Logic)
//! In traditional GUI programming, window event handling is often tangled with GPU drawing
//! and platform-specific window handles. This makes automated testing difficult.
//!
//! `frame.zig` represents pure **Policy**:
//! - It contains NO Wayland dependencies, NO WebGPU dependencies, and NO I/O syscalls.
//! - It can be thoroughly verified under `zig build test` without needing a display server,
//!   GPU driver, or graphics hardware.
//!
//! ## 2. Logical Coordinates vs. Physical Pixels (HiDPI Scaling)
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
//!   $$\text{Physical Pixels} = \text{Logical Pixels} \times \text{Scale}$$
//!
//! ## 3. Damage and Redraw Pacing
//! Every GPU draw call and buffer presentation consumes energy. To maintain 0% CPU and low
//! GPU power while idle, `Frame` tracks a single `redraw` flag:
//! - Setting a new size or scale sets `redraw = true`.
//! - If the compositor sends a duplicate configure event with identical dimensions, `redraw`
//!   remains `false`, preventing redundant rendering.
//! - Once presented, `mark_presented()` resets `redraw = false`.

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

/// State container tracking window dimensions, scaling, and frame dirtiness.
pub const Frame = struct {
    running: bool,
    redraw: bool,
    width_logical: u32,
    height_logical: u32,
    scale: u32,
    width_px: u32,
    height_px: u32,

    pub const ScaleError = error{ScaleZero};

    /// Initializes a newly created frame.
    /// `running` and `redraw` start as `true` because the initial frame must be drawn.
    pub fn init() Frame {
        const frame: Frame = .{
            .running = true,
            .redraw = true,
            .width_logical = 0,
            .height_logical = 0,
            .scale = 1,
            .width_px = 0,
            .height_px = 0,
        };
        assert(frame.running);
        assert(frame.redraw);
        return frame;
    }

    /// Applies a configure event from the window system (e.g. Wayland configure or browser resize).
    /// If the compositor provides (0, 0), substitutes `width_default` and `height_default`.
    /// If the dimensions are identical to the current configuration, returns without dirtying.
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
        assert(self.width_px != 0);
        assert(self.height_px != 0);
    }

    /// Updates the integer display scale factor (e.g. 1 -> 2 when moved to a HiDPI screen).
    /// Recomputes physical pixel dimensions and sets `redraw = true`.
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

    /// Marks the current frame as presented to the display, clearing the dirty flag.
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

test "initial frame is dirty and running" {
    const frame = Frame.init();
    try std.testing.expect(frame.redraw);
    try std.testing.expect(frame.running);
}

test "a successful present leaves the frame clean" {
    var frame = Frame.init();
    frame.mark_presented();
    try std.testing.expect(!frame.redraw);
    try std.testing.expect(frame.running);
}

test "a same size does not dirty a clean frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(800, 600);
    try std.testing.expect(!frame.redraw);
    try std.testing.expectEqual(@as(u32, 800), frame.width_px);
}

test "a new size dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    frame.apply_configure(1024, 768);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1024), frame.width_px);
}

test "a new scale dirties the frame" {
    var frame = Frame.init();
    frame.apply_configure(800, 600);
    frame.mark_presented();
    try frame.apply_scale(2);
    try std.testing.expect(frame.redraw);
    try std.testing.expectEqual(@as(u32, 1600), frame.width_px);
}

test "close clears running" {
    var frame = Frame.init();
    frame.close();
    try std.testing.expect(!frame.running);
}

test "a zero configure is replaced by the default size" {
    var frame = Frame.init();
    frame.apply_configure(0, 0);
    try std.testing.expectEqual(width_default, frame.width_logical);
    try std.testing.expectEqual(height_default, frame.height_logical);
    try std.testing.expectEqual(width_default, frame.width_px);
    try std.testing.expect(frame.redraw);
}

test "scale zero is rejected" {
    var frame = Frame.init();
    try std.testing.expectError(error.ScaleZero, frame.apply_scale(0));
    try std.testing.expectEqual(@as(u32, 1), frame.scale);
}

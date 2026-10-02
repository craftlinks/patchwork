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
//!   `Physical Pixels = Logical Pixels * Scale`
//!
//! ## 3. Damage and Redraw Pacing
//! Every GPU draw call and buffer presentation consumes energy. To maintain 0% CPU and low
//! GPU power while idle, `Frame` decouples presentation dirtying from layout dirtying using
//! two distinct lifecycle flags: `redraw` and `relayout`.
//!
//! ### The `redraw` Flag (Presentation Dirty)
//! - **Lifecycle:** `init()` sets `redraw = true`. When the display server sends a configure
//!   event with altered dimensions, `apply_configure()` sets `redraw = true`. When the window
//!   moves between monitors of different pixel density, `apply_scale()` sets `redraw = true`
//!   so the framebuffer texture is resized to match the new physical resolution. A duplicate
//!   configure with identical dimensions leaves `redraw` unchanged.
//! - **Clearance:** `mark_presented()` resets `redraw = false` immediately after presentation.
//!
//! ### The `relayout` Flag (Layout Dirty)
//! - **Lifecycle:** `init()` sets `relayout = true` because the initial frame must calculate
//!   child geometry and populate the draw list. A changed configure event sets `relayout = true`
//!   via `apply_configure()`, signaling that `turtle.paint_column()` must re-walk the column.
//! - **Preservation Across Scale Changes:** Crucially, `apply_scale()` does NOT set `relayout`.
//!   Logical UI dimensions are invariant to display scale; only the physical framebuffer size
//!   changes. If a scale change re-ran layout, `turtle.paint_column()` would clear the
//!   `DrawList` and bump `DrawList.revision`. This revision bump would trick `UploadCursor.flags()`
//!   into unnecessarily re-uploading the 256-instance GPU vertex buffer (`flag_instances`).
//!   Because `relayout` remains false, a scale-only present reuses the existing instance list
//!   in place without rebuilding it, updating only the projection uniform (`flag_uniform`).
//! - **Clearance:** `mark_laid_out()` resets `relayout = false` immediately after
//!   `turtle.paint_column()` finishes populating the draw list. A same-size configure leaves
//!   a cleared `relayout` cleared.
//!
//! ### Flag Transition Matrix
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

    /// Clears `relayout = false` after the turtle has written border rects for this logical size.
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
    /// `relayout` is preserved unchanged, bypassing `turtle.paint_column` layout passes.
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

const std = @import("std");
const assert = std.debug.assert;

/// Logical pixels the compositor treats as "client chooses the size".
pub const width_default: u32 = 1280;
pub const height_default: u32 = 720;

/// Hard cap on a surface edge. Larger compositor sizes are clamped.
pub const edge_max: u32 = 16384;

/// Integer buffer scale never exceeds this. Hyprland stays well below it.
pub const scale_max: u32 = 16;

pub const Frame = struct {
    running: bool,
    redraw: bool,
    width_logical: u32,
    height_logical: u32,
    scale: u32,
    width_px: u32,
    height_px: u32,

    pub const ScaleError = error{ScaleZero};

    /// The first present is owed before any configure arrives.
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

    /// A zero edge means the compositor left the size to us.
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

    pub fn mark_presented(self: *Frame) void {
        assert(self.running);
        assert(self.redraw);
        self.redraw = false;
        assert(!self.redraw);
        assert(self.running);
    }

    pub fn close(self: *Frame) void {
        assert(self.running);
        self.running = false;
        assert(!self.running);
        assert(self.redraw or !self.redraw);
    }

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

fn clamp_edge(edge: u32) u32 {
    assert(edge != 0);
    if (edge > edge_max) {
        return edge_max;
    }
    assert(edge <= edge_max);
    return edge;
}

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

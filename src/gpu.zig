const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const gpu_wgpu = if (builtin.cpu.arch == .wasm32) void else @import("gpu_wgpu.zig");

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Dark slate so a missed clear is obvious against a compositor background.
pub const clear_color: Color = .{
    .r = 0.11,
    .g = 0.12,
    .b = 0.16,
    .a = 1.0,
};

pub const Gpu = if (builtin.cpu.arch == .wasm32) struct {} else gpu_wgpu.Gpu;

pub fn present_clear(
    gpu: *Gpu,
    width_px: u32,
    height_px: u32,
    color: Color,
) !void {
    assert(width_px != 0);
    assert(height_px != 0);
    if (builtin.cpu.arch == .wasm32) {
        const js = struct {
            extern "env" fn present_clear_js(
                w: u32,
                h: u32,
                r: f32,
                g: f32,
                b: f32,
                a: f32,
            ) void;
        };
        js.present_clear_js(width_px, height_px, color.r, color.g, color.b, color.a);
        return;
    }
    try gpu_wgpu.present_clear(gpu, width_px, height_px, color);
}

pub fn create(
    display: *anyopaque,
    surface: *anyopaque,
) !Gpu {
    assert(@intFromPtr(display) != 0);
    assert(@intFromPtr(surface) != 0);
    if (builtin.cpu.arch == .wasm32) {
        return .{};
    }
    return gpu_wgpu.create(display, surface);
}

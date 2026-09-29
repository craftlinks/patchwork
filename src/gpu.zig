const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");

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

pub fn present(
    gpu: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    if (builtin.cpu.arch == .wasm32) {
        const js = struct {
            extern "env" fn present_js(header_ptr: u32, instance_ptr: u32) void;
        };
        js.present_js(@intCast(@intFromPtr(header)), @intCast(@intFromPtr(instances)));
        return;
    }
    try gpu_wgpu.present(gpu, header, instances);
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

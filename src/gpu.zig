//! Cross-platform GPU seam and compile-time backend dispatch.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Compile-Time Dispatch
//! The backend is chosen by `builtin.cpu.arch`, not by a vtable or an abstraction library. On
//! native targets `host/gpu_wgpu.zig` is imported and `Gpu` is its state type. On `wasm32`
//! the import resolves to `void`, so no native binding code is compiled and `Gpu` is a
//! zero-sized struct because JavaScript (`web/shell.js`) owns the WebGPU objects. Callers see
//! one `present` / `create` pair with no dynamic dispatch.
//!
//! ## 2. Wasm Pointer Hand-Off
//! On `wasm32` a pointer is a `u32` byte offset into the module's single linear memory, so
//! `present` passes `header`, `instances`, and `glyphs` to `present_js` as offsets and
//! JavaScript reads them in place. Rules the JavaScript side relies on:
//! - The three pointers are valid only for the duration of the `present_js` call. JavaScript
//!   must not retain them, because linear memory can grow and detach its `ArrayBuffer`.
//! - `header` points at a `draw.PresentHeader`; its layout is locked by `comptime` asserts in
//!   `draw.zig`.
//! - When `flag_instances` is set and `instance_count > 0`, JavaScript uploads
//!   `instance_count * draw.instance_stride` bytes from `instances`. Likewise it uploads
//!   `glyph_count * font.glyph_stride` bytes from `glyphs` under `flag_glyphs`.
//! - The `glyphs` pointer is valid even when `glyph_count` is zero.
//!
//! ## 3. Clear Color Rationale
//! `clear_color` is deliberately neither black nor white, so a skipped clear, a failed pass, or
//! a swapchain glitch is unmistakable in review. It is also what shows through wherever a quad
//! fragment has zero coverage, such as outside a rounded corner.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const font = @import("font.zig");

/// Conditionally import native wgpu bindings only when compiling for non-Wasm targets.
const gpu_wgpu = if (builtin.cpu.arch == .wasm32) void else @import("host/gpu_wgpu.zig");

/// Straight (non-premultiplied) RGBA color with components in `[0, 1]`.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Framebuffer clear color; see the module guide for why it is not black or white.
pub const clear_color: Color = .{
    .r = 0.11,
    .g = 0.12,
    .b = 0.16,
    .a = 1.0,
};

/// Backend state. Native: wgpu-native handles and GPU buffers. Wasm: zero-sized, because
/// JavaScript owns the WebGPU objects.
pub const Gpu = if (builtin.cpu.arch == .wasm32) struct {} else gpu_wgpu.Gpu;

/// Presents one frame: clears to `clear_color`, then draws the instance and glyph lists.
///
/// `header.width_px` and `header.height_px` are physical pixels and must be nonzero. The
/// pointers must stay valid for the duration of the call (see the module guide for the Wasm
/// rule). Upload flags in `header.flags` decide which buffers are rewritten.
pub fn present(
    gpu: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
    glyphs: [*]const font.Glyph,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    assert(header.glyph_count <= font.glyph_cap);
    if (builtin.cpu.arch == .wasm32) {
        const js = struct {
            extern "env" fn present_js(header_ptr: u32, instance_ptr: u32, glyph_ptr: u32) void;
        };
        js.present_js(
            @intCast(@intFromPtr(header)),
            @intCast(@intFromPtr(instances)),
            @intCast(@intFromPtr(glyphs)),
        );
        return;
    }
    try gpu_wgpu.present(gpu, header, instances, glyphs);
}

/// Creates the backend for a native `display` and `surface`, both nonnull. The native backend
/// creates its pipelines and static GPU buffers here. On Wasm this returns the empty `Gpu`
/// because `web/shell.js` performs initialization.
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

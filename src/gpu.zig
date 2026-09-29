//! Cross-Platform GPU Abstraction Seam.
//!
//! # Concepts for Novices:
//!
//! ## 1. Zero-Cost Compile-Time Platform Selection
//! In C or C++, cross-platform graphics code often uses virtual interfaces (`IVideoDriver`),
//! heavy wrapper libraries (SDL, GLFW), or complex preprocessor `#ifdef` chains.
//!
//! In Zig, types and modules are first-class comptime values:
//! - When targeting native Linux (`x86_64`): `gpu_wgpu.zig` is imported, linking directly
//!   against the native `libwgpu_native.so` C library.
//! - When targeting the browser (`wasm32-freestanding`): `gpu_wgpu` is typed as `void`,
//!   completely omitting the native GPU code from compilation. The browser host JavaScript
//!   (`web/shell.js`) owns the WebGPU device, swapchain, and pipeline.
//!
//! ## 2. Passing Pointers Across the WebAssembly Boundary
//! A 32-bit WebAssembly module has a single linear memory space (a contiguous array of bytes).
//! In Zig on `wasm32`, any pointer `*T` is simply a 32-bit unsigned integer offset into that
//! linear memory.
//!
//! By casting the pointer with `@intFromPtr(header)` and passing it to the imported JavaScript
//! function `present_js(header_ptr, instance_ptr)`, JavaScript can read the exact binary struct
//! directly out of `wasm.memory.buffer` using a `DataView` or `Uint8Array`.
//! Zero serialization, zero copying, zero JSON overhead.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");

/// Conditionally import native wgpu bindings only when compiling for non-Wasm targets.
const gpu_wgpu = if (builtin.cpu.arch == .wasm32) void else @import("gpu_wgpu.zig");

/// Standard 32-bit floating-point RGBA color representation (components in range 0.0 to 1.0).
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Background clear color: a distinct dark slate `(0.11, 0.12, 0.16)`.
/// Using a custom slate rather than pure black `(0, 0, 0)` or white `(1, 1, 1)` ensures that
/// missing clears, driver buffer bleeding, or compositor glitches are immediately visible.
pub const clear_color: Color = .{
    .r = 0.11,
    .g = 0.12,
    .b = 0.16,
    .a = 1.0,
};

/// Hardware GPU state context.
/// - Native: Contains active handles to the wgpu-native instance, adapter, device, queue,
///   render pipeline, and VRAM buffers.
/// - Browser: Zero-sized dummy struct because JavaScript manages the WebGPU objects.
pub const Gpu = if (builtin.cpu.arch == .wasm32) struct {} else gpu_wgpu.Gpu;

/// Presents a frame by clearing the render target and drawing the instance list.
/// Dispatches at compile time to either the native wgpu backend or the JavaScript host bridge.
pub fn present(
    gpu: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    if (builtin.cpu.arch == .wasm32) {
        // In WebAssembly, call the imported JavaScript presentation function.
        // Pointers are cast to 32-bit unsigned integer byte offsets into Wasm linear memory.
        const js = struct {
            extern "env" fn present_js(header_ptr: u32, instance_ptr: u32) void;
        };
        js.present_js(@intCast(@intFromPtr(header)), @intCast(@intFromPtr(instances)));
        return;
    }
    try gpu_wgpu.present(gpu, header, instances);
}

/// Initializes the GPU backend.
/// - On Linux: Binds to the Wayland display and surface, requests an adapter/device,
///   creates the render pipeline, and allocates static GPU buffers.
/// - On Wasm: Returns an empty dummy struct (initialization happens in `web/shell.js`).
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

//! Cross-Platform GPU Abstraction Seam and Compile-Time Backend Dispatch.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Zero-Cost Compile-Time Platform Selection
//! In traditional C or C++ game and graphics engines, supporting multiple platforms (like native
//! desktop vs web) typically requires:
//! - Abstract base classes with virtual methods (`IVideoDriver`).
//! - Heavy external abstraction libraries (SDL, GLFW, Sokol).
//! - Tangled preprocessor `#ifdef` chains scattered throughout the rendering codebase.
//!
//! In Zig, types and modules are first-class compile-time (`comptime`) values:
//! - When compiling for native Linux (`x86_64`):
//!   `src/host/gpu_wgpu.zig` is imported, linking directly against `libwgpu_native.so`.
//! - When compiling for the browser (`wasm32-freestanding`):
//!   `gpu_wgpu` is evaluated to the primitive type `void`. The native WebGPU binding code is
//!   completely omitted from compilation. `Gpu` evaluates to a zero-sized dummy struct,
//!   and calls to `gpu.present()` compile into a single WebAssembly host call instruction.
//! - Result: Zero dynamic dispatch (no `vtable`), zero pointer indirection, zero binary bloat.
//!
//! ## 2. Passing Memory Pointers Across the WebAssembly Boundary
//! A 32-bit WebAssembly module has a single linear memory space (a contiguous array of bytes).
//! In Zig on `wasm32`:
//! - Any pointer `*T` or `[*]T` is fundamentally a 32-bit unsigned integer offset into that
//!   linear memory buffer.
//! - By casting pointers with `@intCast(@intFromPtr(header))`,
//!   `@intCast(@intFromPtr(instances))`, and `@intCast(@intFromPtr(glyphs))`, Zig passes the
//!   raw memory addresses across the FFI boundary to `present_js(header, instances, glyphs)`.
//! - In the browser, JavaScript reads the 104-byte `PresentHeader` struct directly out of
//!   Wasm linear memory using a `DataView(wasm.memory.buffer, headerPtr, 104)`.
//! - If `flag_instances` is set and `instance_count > 0`, JavaScript uploads `instance_count * 64`
//!   bytes directly from `instancePtr`.
//! - If `flag_glyphs` is set and `glyph_count > 0`, JavaScript uploads `glyph_count * 64` bytes
//!   directly from `glyphPtr`.
//! - Zero serialization, zero copying, zero JSON overhead, zero GC pressure.
//!
//! ## 3. Clear Color Rationale
//! The background clear color is configured as a distinctive slate gray: `(0.11, 0.12, 0.16)`.
//! Rather than using default black `(0, 0, 0)` or white `(1, 1, 1)`, a custom dark slate ensures
//! that uninitialized textures, failed clear passes, or driver swapchain glitches are immediately
//! and unmistakably visible during testing and code review.
//! Rounded-box corners rely on that clear. A quad fragment that falls outside the rounded
//! shape writes coverage 0 and blends to nothing, so the slate shows through that corner.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const font = @import("font.zig");

/// Conditionally import native wgpu bindings only when compiling for non-Wasm targets.
const gpu_wgpu = if (builtin.cpu.arch == .wasm32) void else @import("host/gpu_wgpu.zig");

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
/// A quad fragment outside the rounded shape writes coverage 0 and blends away, so this
/// slate is what shows in the corner of the bounding quad.
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
    glyphs: [*]const font.Glyph,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    assert(header.glyph_count <= font.glyph_cap);
    if (builtin.cpu.arch == .wasm32) {
        // Pointers are byte offsets into Wasm linear memory. The glyph pointer is
        // valid for the call even when glyph_count is 0.
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

//! Cross-platform GPU seam and compile-time backend dispatch.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Compile-Time Dispatch
//! The backend is chosen by `builtin.cpu.arch`, not by a vtable or an abstraction library. On
//! native targets `host/gpu_wgpu.zig` is imported and `Gpu` is its state type. On `wasm32`
//! the import resolves to `void`, so no native binding code is compiled and `Gpu` is a
//! zero-sized struct because JavaScript (`web/shell.js`) owns the WebGPU objects. Callers see
//! one `create` / `submit` pair with no dynamic dispatch.
//!
//! ## 2. One Entry Point: `submit`
//! Everything the GPU does arrives as a recorded `commands.CommandBuffer` (see
//! `gpu/commands.zig` for the encoding and `draw/renderer.zig` for what is recorded). Native
//! replays it with `gpu_wgpu.execute`. On `wasm32` a pointer is a `u32` byte offset into the
//! module's single linear memory, so `submit` passes the stream's offset and length to the
//! `submit_js` import and JavaScript decodes it in place. Rules the JavaScript side relies on:
//! - The stream and every `Span` in it are valid only for the duration of the `submit_js`
//!   call. JavaScript must not retain them, because linear memory can grow and detach its
//!   `ArrayBuffer`.
//! - The stream starts 8-byte aligned and its length is a multiple of 8.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const commands = @import("gpu/commands.zig");

/// Conditionally import native wgpu bindings only when compiling for non-Wasm targets.
const gpu_wgpu = if (builtin.cpu.arch == .wasm32) void else @import("host/gpu_wgpu.zig");

/// Backend state. Native: wgpu-native handles and resource tables. Wasm: zero-sized, because
/// JavaScript owns the WebGPU objects.
pub const Gpu = if (builtin.cpu.arch == .wasm32) struct {} else gpu_wgpu.Gpu;

/// Replays one recorded stream. The buffer and everything its spans name must stay valid for
/// the duration of the call (see the module guide for the Wasm rule).
pub fn submit(gpu: *Gpu, buffer: *const commands.CommandBuffer) !void {
    assert(buffer.len != 0);
    assert(buffer.len % commands.op_align == 0);
    if (builtin.cpu.arch == .wasm32) {
        const js = struct {
            extern "env" fn submit_js(ptr: u32, len: u32) void;
        };
        js.submit_js(@intCast(@intFromPtr(&buffer.bytes)), buffer.len);
        return;
    }
    try gpu_wgpu.execute(gpu, buffer);
}

/// Creates the backend for a native `display` and `surface`, both nonnull: device, queue, and
/// an unconfigured surface, with empty resource tables for the setup stream to fill. On Wasm
/// this returns the empty `Gpu` because `web/shell.js` creates the device.
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

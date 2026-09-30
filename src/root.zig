//! Pure Platform-Agnostic Core Module and Unit Test Root.
//!
//! # Architecture:
//! Re-exports the pure logic modules (`frame.zig` and `draw.zig`) which contain zero
//! platform-specific dependencies (no Wayland, no wgpu-native, no WebAssembly syscalls).
//! This enables instantaneous unit testing across all host architectures.

pub const frame = @import("frame.zig");
pub const draw = @import("draw.zig");

test {
    _ = frame;
    _ = draw;
}

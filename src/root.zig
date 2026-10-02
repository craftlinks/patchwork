//! Pure Platform-Agnostic Core Module and Unit Test Root.
//!
//! # Architecture:
//! Re-exports the pure logic modules (`frame.zig`, `draw.zig`, and `turtle.zig`) which
//! contain zero platform-specific dependencies (no Wayland, no wgpu-native, no
//! WebAssembly syscalls). This enables instantaneous unit testing across all host
//! architectures.

pub const frame = @import("frame.zig");
pub const draw = @import("draw.zig");
pub const turtle = @import("turtle.zig");

test {
    _ = frame;
    _ = draw;
    _ = turtle;
}

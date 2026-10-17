//! Pure platform-agnostic core and the unit-test root.
//!
//! Re-exports the modules that do not touch Wayland, wgpu-native, or the browser.
//! `zig build test` compiles this file and nothing else.

pub const frame = @import("frame.zig");
pub const font = @import("font.zig");
pub const draw = @import("draw.zig");
pub const turtle = @import("turtle.zig");
pub const input = @import("input.zig");
pub const animator = @import("animator.zig");
pub const widgets = @import("widgets.zig");
pub const scene = @import("scene.zig");
pub const theme = @import("theme.zig");
/// Protocol interface tables, C ABI layout assertions, and pure `presented_ns` timestamp
/// assembly. The extern `libwayland-client` functions are referenced only by runtime helper
/// functions that unit tests never call, allowing `wp_presentation` to be tested without
/// linking `wayland-client`.
pub const wp_presentation = @import("wp_presentation.zig");

test {
    _ = frame;
    _ = font;
    _ = draw;
    _ = turtle;
    _ = input;
    _ = animator;
    _ = widgets;
    _ = scene;
    _ = theme;
    _ = wp_presentation;
}

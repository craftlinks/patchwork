//! The Patchwork library root and the unit-test root.
//!
//! An app imports this module as `patchwork`. Everything reachable from here that does not
//! touch Wayland, wgpu-native, or the browser is pure, so `zig build test` compiles it
//! without a GPU, a display, or a dynamic library.
//!
//! The `host` namespace holds the two platform hosts. They are generic over an app type
//! and are instantiated only from `src/host/native_main.zig` and `src/host/web_main.zig`.
//! Zig analyzes a declaration only when it is referenced, so an app build for one target
//! never compiles the other target's host.

pub const frame = @import("frame.zig");
pub const font = @import("font.zig");
pub const draw = @import("draw.zig");
pub const turtle = @import("turtle.zig");
pub const input = @import("input.zig");
pub const animator = @import("animator.zig");
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const ui = @import("ui.zig");
pub const app = @import("app.zig");
pub const gpu = @import("gpu.zig");

/// The platform hosts. `linux_window.run(App)` and `web_exports.export_app(App)` are the
/// only entry points an app build uses.
pub const host = struct {
    pub const linux_window = @import("host/linux_window.zig");
    pub const web_exports = @import("host/web_exports.zig");
    /// Protocol interface tables, C ABI layout assertions, and pure `presented_ns` timestamp
    /// assembly. The extern `libwayland-client` functions are referenced only by runtime
    /// helper functions that unit tests never call, allowing `wp_presentation` to be tested
    /// without linking `wayland-client`.
    pub const wp_presentation = @import("host/wp_presentation.zig");
};

test {
    _ = frame;
    _ = font;
    _ = draw;
    _ = turtle;
    _ = input;
    _ = animator;
    _ = theme;
    _ = widgets;
    _ = ui;
    _ = app;
    _ = host.wp_presentation;
}

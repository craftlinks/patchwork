//! The Patchwork library root and the unit-test root.
//!
//! An app imports this module as `patchwork`. Everything reachable from here that does not
//! touch Wayland, wgpu-native, or the browser is pure, so `zig build test` compiles it
//! without a GPU, a display, or a dynamic library.
//!
//! The `host` namespace holds the two platform hosts. They are generic over an app type
//! and are instantiated only from the host roots in `src/host`. Zig analyzes a declaration
//! only when it is referenced, so a build for one target never compiles the other target's
//! host.

pub const frame = @import("frame.zig");
pub const text = @import("text.zig");
pub const draw = @import("draw.zig");
pub const input = @import("input.zig");
pub const animator = @import("animator.zig");
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const editor = @import("editor.zig");
pub const ui = @import("ui.zig");
pub const app = @import("app.zig");
pub const gpu = @import("gpu.zig");
pub const commands = @import("gpu/commands.zig");
pub const renderer = @import("draw/renderer.zig");
pub const bench = @import("bench.zig");
pub const realtime = @import("realtime.zig");
pub const drop = @import("drop.zig");

/// The platform hosts. `linux_window.run` and `web_exports.export_app` are the only entry
/// points an app build uses.
pub const host = struct {
    pub const linux_window = @import("host/linux_window.zig");
    /// The windowless regress host (`--regress`); its tests need no GPU.
    pub const headless = @import("host/headless.zig");
    pub const web_exports = @import("host/web_exports.zig");
    /// Protocol tables and pure timestamp assembly for `wp_presentation`. Listed in the test
    /// root even though it declares extern `libwayland-client` functions: tests never call
    /// the helpers that reference them, so the library need not be linked.
    pub const wp_presentation = @import("host/wp_presentation.zig");
    /// Protocol tables for `wp_fractional_scale_v1` and `wp_viewporter`; listed in the test
    /// root for the same reason as `wp_presentation`.
    pub const wp_fractional_scale = @import("host/wp_fractional_scale.zig");
    /// Seat, cursor-shape, and data-device bindings and the clipboard state machine; listed
    /// in the test root for the same reason. `host/xkb.zig` calls libxkbcommon from its test,
    /// so it has its own root (`native_tests.zig`).
    pub const wl_seat = @import("host/wl_seat.zig");
    pub const wp_cursor_shape = @import("host/wp_cursor_shape.zig");
    /// `xdg-shell` and `xdg-decoration` tables and their state decoders; listed in the test
    /// root for the same reason.
    pub const xdg_shell = @import("host/xdg_shell.zig");
    pub const xdg_decoration = @import("host/xdg_decoration.zig");
    pub const wl_data_device = @import("host/wl_data_device.zig");
    pub const clipboard = @import("host/clipboard.zig");
    /// File drops (`wl_data_offer` drag-and-drop); its tests are `host/dnd_test.zig`, run
    /// from `native_tests.zig`.
    pub const dnd = @import("host/dnd.zig");
};

test {
    _ = frame;
    _ = text;
    _ = draw;
    _ = input;
    _ = animator;
    _ = theme;
    _ = widgets;
    _ = editor;
    _ = ui;
    _ = app;
    _ = commands;
    _ = renderer;
    _ = bench;
    _ = realtime;
    _ = drop;
    _ = host.wp_presentation;
    _ = host.wp_fractional_scale;
    _ = host.wl_seat;
    _ = host.wp_cursor_shape;
    _ = host.xdg_shell;
    _ = host.xdg_decoration;
    _ = host.wl_data_device;
    _ = host.clipboard;
    _ = host.headless;
    // These two hosts carry layout asserts and tests shared with the web shell and the wgpu
    // pipelines; referencing them here makes those checks part of `zig build test`.
    _ = host.web_exports;
    _ = @import("host/gpu_wgpu.zig");
}

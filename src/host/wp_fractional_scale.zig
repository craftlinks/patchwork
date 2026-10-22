//! Wayland `wp_fractional_scale_v1` and `wp_viewporter` client bindings.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Both Protocols
//! `wl_surface.preferred_buffer_scale` is an integer, so a 1.5 monitor either gets a 2x
//! buffer the compositor downsamples (blurred text) or a 1x buffer it upsamples. With
//! `wp_fractional_scale_v1` the compositor sends `preferred_scale` in 1/120 units, and the
//! client renders a buffer of `round(logical * scale / 120)` device pixels. A buffer scale
//! cannot express that ratio, so the client keeps `wl_surface.set_buffer_scale` at 1 and sets
//! `wp_viewport.set_destination(logical width, logical height)`: the compositor then maps the
//! larger buffer onto the logical surface size one-to-one with the output's pixels. The
//! fractional scale protocol requires the viewport for exactly this reason, so the host uses
//! fractional mode only when both globals are bound and falls back to the integer
//! `preferred_buffer_scale` otherwise (`linux_window.zig`, section 2).
//!
//! ## 2. Protocol Objects
//! ```text
//! wp_viewporter                  destroy (0), get_viewport (1, new_id, wl_surface)
//! wp_viewport                    destroy (0), set_source (1, 4 x fixed),
//!                                set_destination (2, int width, int height)
//! wp_fractional_scale_manager_v1 destroy (0), get_fractional_scale (1, new_id, wl_surface)
//! wp_fractional_scale_v1         destroy (0); event preferred_scale (0, uint scale_120)
//! ```
//! The tables are hand-written because `libwayland-client` exports only core interfaces.
//! `assert_interface_tables`, called at compile time by `linux_window.zig`, checks their
//! counts and the listener layout.
//!
//! ## 3. Input
//! Pointer coordinates stay in surface-local logical pixels in both modes: the viewport scales
//! the buffer, not the surface coordinate space, so no input conversion is needed.
//!
//! ## 4. TigerStyle Invariants
//! - No runtime allocation; the proxies live for the whole program.
//! - The extern libwayland functions are referenced only by runtime helpers, so the tables and
//!   asserts compile in unit tests without linking `wayland-client`.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

pub const Viewporter = opaque {};
pub const Viewport = opaque {};
pub const FractionalScaleManager = opaque {};
pub const FractionalScale = opaque {};

/// The version of every interface here; the host binds exactly version 1.
pub const version: u32 = 1;

const WlProxy = xdg.WlProxy;
const WlInterface = xdg.WlInterface;
const WlMessage = xdg.WlMessage;

extern fn wl_proxy_marshal_flags(
    proxy: ?*WlProxy,
    opcode: u32,
    interface: ?*const WlInterface,
    version: u32,
    flags: u32,
    ...,
) ?*WlProxy;
extern fn wl_proxy_add_listener(
    proxy: *WlProxy,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) i32;

const get_viewport_types = [_]?*const WlInterface{
    &wp_viewport_interface,
    &xdg.wl_surface_interface,
};
const viewporter_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_viewport", .signature = "no", .types = &get_viewport_types },
};

/// Wire interface descriptor for the global `wp_viewporter`.
pub const wp_viewporter_interface: WlInterface = .{
    .name = "wp_viewporter",
    .version = version,
    .method_count = 2,
    .methods = &viewporter_requests,
    .event_count = 0,
    .events = null,
};

const no_types = [_]?*const WlInterface{ null, null, null, null };
const viewport_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_source", .signature = "ffff", .types = &no_types },
    .{ .name = "set_destination", .signature = "ii", .types = &no_types },
};

/// Wire interface descriptor for a surface's `wp_viewport`.
pub const wp_viewport_interface: WlInterface = .{
    .name = "wp_viewport",
    .version = version,
    .method_count = 3,
    .methods = &viewport_requests,
    .event_count = 0,
    .events = null,
};

const get_fractional_scale_types = [_]?*const WlInterface{
    &wp_fractional_scale_interface,
    &xdg.wl_surface_interface,
};
const manager_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{
        .name = "get_fractional_scale",
        .signature = "no",
        .types = &get_fractional_scale_types,
    },
};

/// Wire interface descriptor for the global `wp_fractional_scale_manager_v1`.
pub const wp_fractional_scale_manager_interface: WlInterface = .{
    .name = "wp_fractional_scale_manager_v1",
    .version = version,
    .method_count = 2,
    .methods = &manager_requests,
    .event_count = 0,
    .events = null,
};

const fractional_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
};
const fractional_events = [_]WlMessage{
    .{ .name = "preferred_scale", .signature = "u", .types = &no_types },
};

/// Wire interface descriptor for a surface's `wp_fractional_scale_v1`.
pub const wp_fractional_scale_interface: WlInterface = .{
    .name = "wp_fractional_scale_v1",
    .version = version,
    .method_count = 1,
    .methods = &fractional_requests,
    .event_count = 1,
    .events = &fractional_events,
};

/// C ABI listener for `wp_fractional_scale_v1`: one slot, `preferred_scale` (opcode 0).
pub const FractionalScaleListener = extern struct {
    preferred_scale: *const fn (
        data: ?*anyopaque,
        fractional: ?*FractionalScale,
        scale_120: u32,
    ) callconv(.c) void,
};

/// Issues `wp_viewporter.get_viewport` (opcode 1) for `surface`.
pub fn get_viewport(viewporter: *Viewporter, surface: *xdg.WlSurface) *Viewport {
    const result = wl_proxy_marshal_flags(
        @ptrCast(viewporter),
        1,
        &wp_viewport_interface,
        version,
        0,
        @as(?*anyopaque, null),
        surface,
    );
    assert(result != null);
    assert(@intFromPtr(surface) != 0);
    return @ptrCast(result.?);
}

/// Issues `wp_viewport.set_destination` (opcode 2): the surface size in logical pixels the
/// buffer is scaled to. Takes effect on the next `wl_surface.commit`.
pub fn set_destination(viewport: *Viewport, width_logical: u32, height_logical: u32) void {
    assert(width_logical >= 1);
    assert(height_logical >= 1);
    const width: i32 = @intCast(width_logical);
    const height: i32 = @intCast(height_logical);
    _ = wl_proxy_marshal_flags(@ptrCast(viewport), 2, null, version, 0, width, height);
}

/// Issues `wp_fractional_scale_manager_v1.get_fractional_scale` (opcode 1) for `surface`.
pub fn get_fractional_scale(
    manager: *FractionalScaleManager,
    surface: *xdg.WlSurface,
) *FractionalScale {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1,
        &wp_fractional_scale_interface,
        version,
        0,
        @as(?*anyopaque, null),
        surface,
    );
    assert(result != null);
    assert(@intFromPtr(surface) != 0);
    return @ptrCast(result.?);
}

/// Installs the `preferred_scale` listener. `listener` must outlive the proxy.
pub fn add_fractional_listener(
    fractional: *FractionalScale,
    listener: *const FractionalScaleListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(fractional), listener, data);
    assert(rc == 0);
    assert(@intFromPtr(fractional) != 0);
}

/// Compile-time consistency checks between the tables, their counts, and the listener. A
/// function for the same reason as `wp_presentation.assert_interface_tables`.
pub fn assert_interface_tables() void {
    comptime {
        assert(wp_viewporter_interface.method_count == viewporter_requests.len);
        assert(wp_viewport_interface.method_count == viewport_requests.len);
        assert(wp_fractional_scale_manager_interface.method_count == manager_requests.len);
        assert(wp_fractional_scale_interface.method_count == fractional_requests.len);
        assert(wp_fractional_scale_interface.event_count == fractional_events.len);
        const listener = @typeInfo(FractionalScaleListener).@"struct";
        assert(listener.field_names.len == fractional_events.len);
    }
}

comptime {
    assert(version == 1);
    assert(@sizeOf(FractionalScaleListener) == @sizeOf(*const anyopaque));
}

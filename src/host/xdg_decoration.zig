//! Hand-written `xdg-decoration-unstable-v1` interface tables and request wrappers: who draws
//! the window's title bar and frame.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Negotiation
//! ```text
//! zxdg_decoration_manager_v1     destroy (0), get_toplevel_decoration (1, new_id, xdg_toplevel)
//! zxdg_toplevel_decoration_v1    destroy (0), set_mode (1, uint), unset_mode (2)
//!                                event configure (0, uint mode)
//! mode                           1 client_side, 2 server_side
//! ```
//! A client that wants the compositor to draw its frame creates a decoration object for its
//! toplevel before the first commit and asks for `server_side`; the compositor answers with
//! `configure(mode)`, before the `xdg_surface.configure` it belongs to, and that answer is the
//! mode. A client that creates no object draws its own frame (the protocol's default), which
//! is what `config.decorations = .client` does (`app.zig`, section 4c). The tables follow
//! `xdg_shell.zig`, sections 1 to 3: libwayland reads them at run time, so
//! `assert_interface_tables` ties counts and opcodes to them, called from `linux_window.zig`.
//!
//! ## 2. Ownership
//! The proxies are owned by libwayland and live as long as the window; the listener table is
//! static.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const xdg = @import("xdg_shell.zig");

const WlInterface = xdg.WlInterface;
const WlMessage = xdg.WlMessage;
const WlProxy = xdg.WlProxy;

pub const Manager = opaque {};
pub const Decoration = opaque {};

/// `zxdg_toplevel_decoration_v1.mode` values.
pub const mode_client_side: u32 = 1;
pub const mode_server_side: u32 = 2;

extern fn wl_proxy_marshal_flags(
    proxy: ?*WlProxy,
    opcode: u32,
    interface: ?*const WlInterface,
    version: u32,
    flags: u32,
    ...,
) ?*WlProxy;
extern fn wl_proxy_get_version(proxy: *WlProxy) u32;
extern fn wl_proxy_add_listener(
    proxy: *WlProxy,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) i32;

const get_decoration_types = [_]*const WlInterface{
    &zxdg_toplevel_decoration_interface,
    &xdg.xdg_toplevel_interface,
};

const manager_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{
        .name = "get_toplevel_decoration",
        .signature = "no",
        .types = @ptrCast(&get_decoration_types),
    },
};

/// Wire interface descriptor for the global `zxdg_decoration_manager_v1`.
pub const zxdg_decoration_manager_interface: WlInterface = .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &manager_requests,
    .event_count = 0,
    .events = null,
};

const decoration_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_mode", .signature = "u", .types = null },
    .{ .name = "unset_mode", .signature = "", .types = null },
};
const decoration_events = [_]WlMessage{
    .{ .name = "configure", .signature = "u", .types = null },
};

/// Wire interface descriptor for a toplevel's `zxdg_toplevel_decoration_v1`.
pub const zxdg_toplevel_decoration_interface: WlInterface = .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .method_count = 3,
    .methods = &decoration_requests,
    .event_count = 1,
    .events = &decoration_events,
};

pub const DecorationListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        decoration: ?*Decoration,
        mode: u32,
    ) callconv(.c) void,
};

/// The decorations a `configure` mode means: `server` only for `server_side`.
pub fn decorations_of(mode: u32) input.Decorations {
    const decorations: input.Decorations = if (mode == mode_server_side) .server else .client;
    assert(decorations == .client or mode == mode_server_side);
    return decorations;
}

/// `zxdg_decoration_manager_v1.get_toplevel_decoration` (opcode 1) for `toplevel`.
pub fn get_decoration(manager: *Manager, toplevel: *xdg.XdgToplevel) *Decoration {
    const proxy: *WlProxy = @ptrCast(manager);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        1,
        &zxdg_toplevel_decoration_interface,
        version,
        0,
        @as(?*anyopaque, null),
        toplevel,
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// `zxdg_toplevel_decoration_v1.set_mode` (opcode 1).
pub fn set_mode(decoration: *Decoration, mode: u32) void {
    assert(mode == mode_client_side or mode == mode_server_side);
    const proxy: *WlProxy = @ptrCast(decoration);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 1, null, version, 0, mode);
}

pub fn add_listener(
    decoration: *Decoration,
    listener: *const DecorationListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(decoration), listener, data);
    assert(rc == 0);
}

/// Compile-time checks between the tables, the listener, and the request opcodes; called from
/// `linux_window.zig` (see `xdg_shell.assert_interface_tables` for why it is a function).
pub fn assert_interface_tables() void {
    comptime {
        assert(zxdg_decoration_manager_interface.method_count == manager_requests.len);
        assert(zxdg_toplevel_decoration_interface.method_count == decoration_requests.len);
        assert(zxdg_toplevel_decoration_interface.event_count == decoration_events.len);
        const slots = @typeInfo(DecorationListener).@"struct".field_names.len;
        assert(slots == decoration_events.len);
        assert(std.mem.eql(u8, std.mem.span(manager_requests[1].name), "get_toplevel_decoration"));
        assert(std.mem.eql(u8, std.mem.span(decoration_requests[1].name), "set_mode"));
    }
}

// Locks section 1: only `server_side` means the compositor draws; `client_side` and a value
// the protocol does not define leave the frame to the app.
test "a decoration mode is server only when the compositor says so" {
    try std.testing.expectEqual(input.Decorations.server, decorations_of(mode_server_side));
    try std.testing.expectEqual(input.Decorations.client, decorations_of(mode_client_side));
    try std.testing.expectEqual(input.Decorations.client, decorations_of(7));
}

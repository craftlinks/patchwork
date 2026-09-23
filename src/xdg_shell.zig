const std = @import("std");
const assert = std.debug.assert;

/// Hand-written xdg-shell v1 tables. wayland-scanner output is generated C we
/// do not want in the tree, and this step only needs bind, ping/pong, configure,
/// ack, and close.
pub const WlInterface = extern struct {
    name: [*:0]const u8,
    version: i32,
    method_count: i32,
    methods: ?[*]const WlMessage,
    event_count: i32,
    events: ?[*]const WlMessage,
};

pub const WlMessage = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const WlInterface,
};

pub const WlProxy = opaque {};
pub const WlSurface = opaque {};
pub const XdgWmBase = opaque {};
pub const XdgSurface = opaque {};
pub const XdgToplevel = opaque {};
pub const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

pub extern const wl_surface_interface: WlInterface;
pub extern const wl_seat_interface: WlInterface;
pub extern const wl_output_interface: WlInterface;

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

const xdg_positioner_interface: WlInterface = .{
    .name = "xdg_positioner",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};

const xdg_popup_interface: WlInterface = .{
    .name = "xdg_popup",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 0,
    .events = null,
};

const get_surface_types = [_]*const WlInterface{
    &xdg_surface_interface,
    &wl_surface_interface,
};
const create_positioner_types = [_]*const WlInterface{&xdg_positioner_interface};
const get_toplevel_types = [_]*const WlInterface{&xdg_toplevel_interface};
const get_popup_types = [_]*const WlInterface{
    &xdg_popup_interface,
    &xdg_surface_interface,
    &xdg_positioner_interface,
};
const set_parent_types = [_]*const WlInterface{&xdg_toplevel_interface};
const seat_types = [_]*const WlInterface{&wl_seat_interface};
const output_types = [_]*const WlInterface{&wl_output_interface};

const wm_base_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = @ptrCast(&create_positioner_types) },
    .{ .name = "get_xdg_surface", .signature = "no", .types = @ptrCast(&get_surface_types) },
    .{ .name = "pong", .signature = "u", .types = null },
};
const wm_base_events = [_]WlMessage{
    .{ .name = "ping", .signature = "u", .types = null },
};

pub const xdg_wm_base_interface: WlInterface = .{
    .name = "xdg_wm_base",
    .version = 1,
    .method_count = 4,
    .methods = &wm_base_requests,
    .event_count = 1,
    .events = &wm_base_events,
};

const surface_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = @ptrCast(&get_toplevel_types) },
    .{ .name = "get_popup", .signature = "n?oo", .types = @ptrCast(&get_popup_types) },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = null },
    .{ .name = "ack_configure", .signature = "u", .types = null },
};
const surface_events = [_]WlMessage{
    .{ .name = "configure", .signature = "u", .types = null },
};

pub const xdg_surface_interface: WlInterface = .{
    .name = "xdg_surface",
    .version = 1,
    .method_count = 5,
    .methods = &surface_requests,
    .event_count = 1,
    .events = &surface_events,
};

const toplevel_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = @ptrCast(&set_parent_types) },
    .{ .name = "set_title", .signature = "s", .types = null },
    .{ .name = "set_app_id", .signature = "s", .types = null },
    .{ .name = "show_window_menu", .signature = "ouii", .types = @ptrCast(&seat_types) },
    .{ .name = "move", .signature = "ou", .types = @ptrCast(&seat_types) },
    .{ .name = "resize", .signature = "ouu", .types = @ptrCast(&seat_types) },
    .{ .name = "set_max_size", .signature = "ii", .types = null },
    .{ .name = "set_min_size", .signature = "ii", .types = null },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "?o", .types = @ptrCast(&output_types) },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};
const toplevel_events = [_]WlMessage{
    .{ .name = "configure", .signature = "iia", .types = null },
    .{ .name = "close", .signature = "", .types = null },
};

pub const xdg_toplevel_interface: WlInterface = .{
    .name = "xdg_toplevel",
    .version = 1,
    .method_count = 14,
    .methods = &toplevel_requests,
    .event_count = 2,
    .events = &toplevel_events,
};

pub const XdgWmBaseListener = extern struct {
    ping: *const fn (
        data: ?*anyopaque,
        base: ?*XdgWmBase,
        serial: u32,
    ) callconv(.c) void,
};

pub const XdgSurfaceListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        surface: ?*XdgSurface,
        serial: u32,
    ) callconv(.c) void,
};

pub const XdgToplevelListener = extern struct {
    configure: *const fn (
        data: ?*anyopaque,
        toplevel: ?*XdgToplevel,
        width: i32,
        height: i32,
        states: ?*WlArray,
    ) callconv(.c) void,
    close: *const fn (data: ?*anyopaque, toplevel: ?*XdgToplevel) callconv(.c) void,
};

pub fn get_xdg_surface(base: *XdgWmBase, surface: *WlSurface) *XdgSurface {
    const proxy: *WlProxy = @ptrCast(base);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        2,
        &xdg_surface_interface,
        version,
        0,
        @as(?*anyopaque, null),
        surface,
    );
    assert(result != null);
    return @ptrCast(result.?);
}

pub fn pong(base: *XdgWmBase, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(base);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 3, null, version, 0, serial);
    assert(serial != 0 or serial == 0);
}

pub fn get_toplevel(surface: *XdgSurface) *XdgToplevel {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        1,
        &xdg_toplevel_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

pub fn ack_configure(surface: *XdgSurface, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 4, null, version, 0, serial);
    assert(version >= 1);
}

pub fn set_title(toplevel: *XdgToplevel, title: [*:0]const u8) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 2, null, version, 0, title);
    assert(version >= 1);
}

pub fn set_app_id(toplevel: *XdgToplevel, app_id: [*:0]const u8) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 3, null, version, 0, app_id);
    assert(version >= 1);
}

pub fn add_wm_base_listener(base: *XdgWmBase, listener: *const XdgWmBaseListener, data: *anyopaque) void {
    const rc = wl_proxy_add_listener(@ptrCast(base), listener, data);
    assert(rc == 0);
}

pub fn add_surface_listener(surface: *XdgSurface, listener: *const XdgSurfaceListener, data: *anyopaque) void {
    const rc = wl_proxy_add_listener(@ptrCast(surface), listener, data);
    assert(rc == 0);
}

pub fn add_toplevel_listener(
    toplevel: *XdgToplevel,
    listener: *const XdgToplevelListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(toplevel), listener, data);
    assert(rc == 0);
}

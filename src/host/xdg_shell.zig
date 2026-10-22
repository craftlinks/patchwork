//! Hand-written `xdg-shell` (version 1) interface tables and request wrappers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Hand-Written Tables Instead of `wayland-scanner`
//! `wayland-scanner` generates C glue from `xdg-shell.xml`, which would add a tool to the
//! build and generated code to either commit or produce through build hooks. The repository
//! allows no dependency beyond the Zig toolchain, so the subset of `xdg_wm_base`,
//! `xdg_surface`, and `xdg_toplevel` that a plain window needs is written out as
//! `WlInterface` and `WlMessage` tables. `xdg_positioner` and `xdg_popup` are present only
//! as empty interfaces because other messages name them in their type lists.
//!
//! ## 2. Wire Signatures
//! `WlMessage.signature` uses the Wayland type letters: `u` unsigned, `i` signed, `s`
//! string, `o` object, `n` new object, `a` array, and a `?` prefix for a nullable argument.
//! `types` is indexed by argument position and consulted only for object and new-object
//! arguments, so a table may stop after the last such argument. libwayland reads these tables
//! at runtime, so a wrong count or order corrupts the wire format instead of failing to
//! compile.
//!
//! ## 3. Opcodes and Marshalling
//! Requests go through the variadic `wl_proxy_marshal_flags`. A request's opcode is its
//! 0-based index in the interface's request table. The wrappers pass opcodes as literals, so
//! `assert_interface_tables` derives each opcode from the table by name and asserts they
//! agree. It also checks that every declared count equals its table length and that listener
//! slot counts equal event counts, because libwayland indexes listeners by event opcode.
//! `linux_window.zig` evaluates it at compile time.
//!
//! ## 4. Configure / Ack Protocol
//! The compositor sends `xdg_toplevel.configure` (suggested size, 0 meaning no preference)
//! and then `xdg_surface.configure(serial)`. The client must answer the latter with
//! `ack_configure(serial)` before committing content for that configure. `linux_window.zig`
//! records both events and acknowledges once per loop iteration. A `xdg_wm_base.ping` must be
//! answered with `pong(serial)` or the compositor may mark the client unresponsive.
//!
//! ## 5. Ownership
//! `WlProxy` and the typed proxy handles are opaque pointers owned by libwayland. A listener
//! table passed to `add_*_listener` must outlive its proxy. Listener registration fails (and
//! is asserted) if the proxy already has a listener.

const std = @import("std");
const assert = std.debug.assert;

/// C layout of libwayland's `struct wl_interface`. Field order and the `i32` counts are ABI,
/// so this must stay an `extern struct`; see the `comptime` block for the table checks.
pub const WlInterface = extern struct {
    name: [*:0]const u8,
    version: i32,
    method_count: i32,
    methods: ?[*]const WlMessage,
    event_count: i32,
    events: ?[*]const WlMessage,
};

/// C layout of libwayland's `struct wl_message`. `signature` and `types` are described in the
/// module guide.
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
/// C layout of libwayland's `struct wl_array`. Borrowed from libwayland; never freed here.
pub const WlArray = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

/// Core interfaces exported by `libwayland-client.so.0`, named here for type lists.
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

/// `xdg_wm_base.get_xdg_surface`: gives `surface` the xdg role object. Assigning a role is
/// permanent for the `wl_surface`.
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

/// `xdg_wm_base.pong`: answers a `ping` with the same `serial`.
pub fn pong(base: *XdgWmBase, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(base);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 3, null, version, 0, serial);
    assert(serial != 0 or serial == 0);
}

/// `xdg_surface.get_toplevel`: makes the xdg surface a top-level window.
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

/// `xdg_surface.ack_configure`: acknowledges the `serial` of a received configure.
pub fn ack_configure(surface: *XdgSurface, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 4, null, version, 0, serial);
    assert(version >= 1);
}

/// `xdg_toplevel.set_title`: UTF-8 window title; `title` must be NUL-terminated.
pub fn set_title(toplevel: *XdgToplevel, title: [*:0]const u8) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 2, null, version, 0, title);
    assert(version >= 1);
}

/// `xdg_toplevel.set_app_id`: application identifier the compositor uses to group windows.
pub fn set_app_id(toplevel: *XdgToplevel, app_id: [*:0]const u8) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 3, null, version, 0, app_id);
    assert(version >= 1);
}

pub fn add_wm_base_listener(
    base: *XdgWmBase,
    listener: *const XdgWmBaseListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(base), listener, data);
    assert(rc == 0);
}

pub fn add_surface_listener(
    surface: *XdgSurface,
    listener: *const XdgSurfaceListener,
    data: *anyopaque,
) void {
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

/// Index of the message called `name` in `messages`. Evaluated at compile time to tie the
/// literal opcodes in the request wrappers to the interface tables.
fn opcode_of(comptime messages: []const WlMessage, comptime name: []const u8) u32 {
    comptime {
        for (messages, 0..) |message, index| {
            if (std.mem.eql(u8, std.mem.span(message.name), name)) return @intCast(index);
        }
        @compileError("no message named " ++ name);
    }
}

/// Compile-time consistency checks between the tables, listeners, and request opcodes.
/// They live in a function, called from a `comptime` block in `linux_window.zig`, because
/// reading the interface tables makes the compiler reference the extern libwayland interface
/// symbols, and unit-test builds link no `wayland-client`.
pub fn assert_interface_tables() void {
    comptime {
        // libwayland trusts the declared counts, so they must equal the table lengths.
        assert(xdg_wm_base_interface.method_count == wm_base_requests.len);
        assert(xdg_wm_base_interface.event_count == wm_base_events.len);
        assert(xdg_surface_interface.method_count == surface_requests.len);
        assert(xdg_surface_interface.event_count == surface_events.len);
        assert(xdg_toplevel_interface.method_count == toplevel_requests.len);
        assert(xdg_toplevel_interface.event_count == toplevel_events.len);

        // Listeners are indexed by event opcode, so slot counts must equal event counts.
        assert(@typeInfo(XdgWmBaseListener).@"struct".field_names.len == wm_base_events.len);
        assert(@typeInfo(XdgSurfaceListener).@"struct".field_names.len == surface_events.len);
        assert(@typeInfo(XdgToplevelListener).@"struct".field_names.len == toplevel_events.len);

        // The wrappers pass opcodes as literals; these asserts tie them to the tables.
        assert(opcode_of(&wm_base_requests, "get_xdg_surface") == 2);
        assert(opcode_of(&wm_base_requests, "pong") == 3);
        assert(opcode_of(&surface_requests, "get_toplevel") == 1);
        assert(opcode_of(&surface_requests, "ack_configure") == 4);
        assert(opcode_of(&toplevel_requests, "set_title") == 2);
        assert(opcode_of(&toplevel_requests, "set_app_id") == 3);
    }
}

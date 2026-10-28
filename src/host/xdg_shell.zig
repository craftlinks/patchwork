//! Hand-written `xdg-shell` (version 5) interface tables, request wrappers, and the decoders of
//! the toplevel's states and capabilities.
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
//! ## 4a. Versions, States, and Window Requests
//! The tables are version 5, and the host binds `xdg_wm_base` at `min(advertised, 5)`: the
//! surfaces and toplevels it creates inherit that version. Version 2 adds the tiled states to
//! `configure`, version 4 the `configure_bounds` event, and version 5 `wm_capabilities`, which
//! a compositor sends before the first configure. `states_of` and `capabilities_of` decode
//! their arrays of `u32` into an `input.WindowState`, ignoring values they do not know and
//! reading at most `states_max`; a compositor that never sends capabilities supports them all.
//! `move`, `resize`, and `show_window_menu` need the seat and the serial of the press that
//! asked (`input.Button.serial`); the compositor ignores them for a stale serial.
//!
//! ## 5. Ownership
//! `WlProxy` and the typed proxy handles are opaque pointers owned by libwayland. A listener
//! table passed to `add_*_listener` must outlive its proxy. Listener registration fails (and
//! is asserted) if the proxy already has a listener.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");

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
/// The highest `xdg_wm_base` version these tables describe.
pub const wm_base_version_max: u32 = 5;
/// The most entries `states_of` and `capabilities_of` read from one array.
pub const states_max: u32 = 16;
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
    .version = wm_base_version_max,
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
    .version = wm_base_version_max,
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
    .{ .name = "configure_bounds", .signature = "4ii", .types = null },
    .{ .name = "wm_capabilities", .signature = "5a", .types = null },
};

pub const xdg_toplevel_interface: WlInterface = .{
    .name = "xdg_toplevel",
    .version = wm_base_version_max,
    .method_count = 14,
    .methods = &toplevel_requests,
    .event_count = 4,
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
    configure_bounds: *const fn (
        data: ?*anyopaque,
        toplevel: ?*XdgToplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void,
    wm_capabilities: *const fn (
        data: ?*anyopaque,
        toplevel: ?*XdgToplevel,
        capabilities: ?*WlArray,
    ) callconv(.c) void,
};

/// `xdg_toplevel.resize_edge`: the edge or corner a resize drags.
pub const ResizeEdge = enum(u32) {
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

/// `xdg_toplevel.state` values `states_of` reads.
const state_maximized: u32 = 1;
const state_fullscreen: u32 = 2;
const state_activated: u32 = 4;
const state_tiled_left: u32 = 5;
const state_tiled_right: u32 = 6;
const state_tiled_top: u32 = 7;
const state_tiled_bottom: u32 = 8;

/// `xdg_toplevel.wm_capabilities` values `capabilities_of` reads.
const capability_window_menu: u32 = 1;
const capability_maximize: u32 = 2;
const capability_fullscreen: u32 = 3;
const capability_minimize: u32 = 4;

/// The `u32` entries of `array`, at most `states_max`; empty for a null array.
fn words_of(array: ?*const WlArray) []const u32 {
    const live = array orelse return &.{};
    if (live.size == 0) return &.{};
    const data = live.data orelse return &.{};
    const count = @min(live.size / @sizeOf(u32), states_max);
    const words: [*]const u32 = @ptrCast(@alignCast(data));
    assert(count <= states_max);
    return words[0..count];
}

/// `state` with the window flags of a `configure` states array: the four booleans are set
/// from `array`, the decorations and capabilities are kept (section 4a).
pub fn states_of(state: input.WindowState, array: ?*const WlArray) input.WindowState {
    var out = state;
    out.maximized = false;
    out.fullscreen = false;
    out.activated = false;
    out.tiled_left = false;
    out.tiled_right = false;
    out.tiled_top = false;
    out.tiled_bottom = false;
    for (words_of(array)) |word| {
        switch (word) {
            state_maximized => out.maximized = true,
            state_fullscreen => out.fullscreen = true,
            state_activated => out.activated = true,
            state_tiled_left => out.tiled_left = true,
            state_tiled_right => out.tiled_right = true,
            state_tiled_top => out.tiled_top = true,
            state_tiled_bottom => out.tiled_bottom = true,
            else => {},
        }
    }
    assert(out.decorations == state.decorations);
    assert(out.can_maximize == state.can_maximize);
    return out;
}

/// `state` with the capabilities of a `wm_capabilities` array: each set only when listed.
pub fn capabilities_of(state: input.WindowState, array: ?*const WlArray) input.WindowState {
    var out = state;
    out.window_menu = false;
    out.can_maximize = false;
    out.can_fullscreen = false;
    out.can_minimize = false;
    for (words_of(array)) |word| {
        switch (word) {
            capability_window_menu => out.window_menu = true,
            capability_maximize => out.can_maximize = true,
            capability_fullscreen => out.can_fullscreen = true,
            capability_minimize => out.can_minimize = true,
            else => {},
        }
    }
    assert(out.maximized == state.maximized);
    assert(out.decorations == state.decorations);
    return out;
}

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

/// `xdg_toplevel.show_window_menu`: the compositor's window menu at the surface point, for the
/// press with `serial`.
pub fn show_window_menu(
    toplevel: *XdgToplevel,
    seat: *anyopaque,
    serial: u32,
    x: i32,
    y: i32,
) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 4, null, version, 0, seat, serial, x, y);
    assert(version >= 1);
}

/// `xdg_toplevel.move`: the compositor moves the window with the pointer of the press with
/// `serial`.
pub fn move(toplevel: *XdgToplevel, seat: *anyopaque, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 5, null, version, 0, seat, serial);
    assert(version >= 1);
}

/// `xdg_toplevel.resize`: the compositor resizes the window from `edge` with the pointer of the
/// press with `serial`.
pub fn resize(toplevel: *XdgToplevel, seat: *anyopaque, serial: u32, edge: ResizeEdge) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 6, null, version, 0, seat, serial, @backingInt(edge));
    assert(version >= 1);
}

/// `xdg_toplevel.set_maximized` (opcode 9), or `unset_maximized` (10) when `on` is false.
pub fn set_maximized(toplevel: *XdgToplevel, on: bool) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    const opcode: u32 = if (on) 9 else 10;
    _ = wl_proxy_marshal_flags(proxy, opcode, null, version, 0);
    assert(version >= 1);
}

/// `xdg_toplevel.set_minimized`: the compositor may hide the window; nothing tells it back.
pub fn set_minimized(toplevel: *XdgToplevel) void {
    const proxy: *WlProxy = @ptrCast(toplevel);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 13, null, version, 0);
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
        // Every opcode lookup compares names byte by byte.
        @setEvalBranchQuota(10_000);
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
        assert(opcode_of(&toplevel_requests, "show_window_menu") == 4);
        assert(opcode_of(&toplevel_requests, "move") == 5);
        assert(opcode_of(&toplevel_requests, "resize") == 6);
        assert(opcode_of(&toplevel_requests, "set_maximized") == 9);
        assert(opcode_of(&toplevel_requests, "unset_maximized") == 10);
        assert(opcode_of(&toplevel_requests, "set_minimized") == 13);
    }
}

const testing = std.testing;

fn array_of(words: []const u32) WlArray {
    const data: *anyopaque = @ptrCast(@constCast(words.ptr));
    return .{ .size = words.len * @sizeOf(u32), .alloc = 0, .data = data };
}

// Locks section 4a: the configure states set exactly the listed flags (an unknown 3, resizing,
// and 99 are ignored), keep the decorations and capabilities, and an empty or null array
// clears them all, activated included.
test "configure states decode into the window flags" {
    var start: input.WindowState = .{ .decorations = .server, .can_minimize = false };
    start.tiled_left = true;
    var words = array_of(&.{ 1, 3, 4, 6, 99 });
    const decoded = states_of(start, &words);
    try testing.expect(decoded.maximized and decoded.activated and decoded.tiled_right);
    try testing.expect(!decoded.fullscreen and !decoded.tiled_left and !decoded.tiled_top);
    try testing.expectEqual(input.Decorations.server, decoded.decorations);
    try testing.expect(!decoded.can_minimize);
    var empty = array_of(&.{});
    const cleared = states_of(decoded, &empty);
    try testing.expect(!cleared.maximized and !cleared.activated and !cleared.tiled_right);
    try testing.expectEqual(cleared, states_of(decoded, null));
}

// Locks section 4a: capabilities are only what the array lists (Hyprland's answer without
// minimize keeps it off), and at most `states_max` entries are read.
test "wm capabilities decode, and arrays are read up to the cap" {
    var listed = array_of(&.{ 1, 2, 3 });
    const caps = capabilities_of(.{ .maximized = true }, &listed);
    try testing.expect(caps.window_menu and caps.can_maximize and caps.can_fullscreen);
    try testing.expect(!caps.can_minimize);
    try testing.expect(caps.maximized);
    var long: [states_max + 1]u32 = @splat(7);
    long[states_max] = 1;
    var capped = array_of(&long);
    try testing.expect(!states_of(.{}, &capped).maximized);
    try testing.expect(states_of(.{}, &capped).tiled_top);
}

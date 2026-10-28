//! Wayland `wp_cursor_shape_v1` client bindings: named pointer shapes without a cursor theme.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Shape Protocol
//! On `wl_pointer.enter` the pointer image is undefined until the client sets one. The core
//! way is `wl_pointer.set_cursor` with a client surface holding cursor pixels, which needs a
//! cursor theme loader and shared-memory buffers. `wp_cursor_shape_v1` lets the client name a
//! shape and the compositor draws it from its own theme, so the host only maps `ui.Cursor`
//! values onto shape numbers (`shape_of`).
//!
//! ## 2. Protocol Objects
//! ```text
//! wp_cursor_shape_manager_v1  destroy (0), get_pointer (1, new_id, wl_pointer),
//!                             get_tablet_tool_v2 (2, new_id, zwp_tablet_tool_v2)
//! wp_cursor_shape_device_v1   destroy (0), set_shape (1, uint serial, uint shape)
//! ```
//! Version 1 is bound. The tablet tool's interface is not bound by this host, so its type
//! slot is null; libwayland reads type slots only to create new objects. `set_shape` must
//! carry the serial of the latest `wl_pointer.enter`; the host re-sends the shape after each
//! enter and otherwise only when it changes (`linux_window.zig`). Without the global the
//! host logs once and leaves the compositor's cursor alone.
//!
//! ## 3. TigerStyle Invariants
//! - No runtime allocation; the proxies live for the whole program.
//! - The extern libwayland functions are referenced only by runtime helpers, so the tables and
//!   asserts compile in unit tests without linking `wayland-client`.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");
const wl_seat = @import("wl_seat.zig");
const areas = @import("../ui/areas.zig");

pub const Manager = opaque {};
pub const Device = opaque {};

/// The version of both interfaces the host binds.
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

const get_pointer_types = [_]?*const WlInterface{
    &wp_cursor_shape_device_interface,
    &wl_seat.wl_pointer_interface,
};
const get_tablet_tool_types = [_]?*const WlInterface{ &wp_cursor_shape_device_interface, null };
const manager_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_pointer", .signature = "no", .types = &get_pointer_types },
    .{ .name = "get_tablet_tool_v2", .signature = "no", .types = &get_tablet_tool_types },
};

/// Wire interface descriptor for the global `wp_cursor_shape_manager_v1`.
pub const wp_cursor_shape_manager_interface: WlInterface = .{
    .name = "wp_cursor_shape_manager_v1",
    .version = version,
    .method_count = 3,
    .methods = &manager_requests,
    .event_count = 0,
    .events = null,
};

const no_types = [_]?*const WlInterface{ null, null };
const device_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_shape", .signature = "uu", .types = &no_types },
};

/// Wire interface descriptor for a pointer's `wp_cursor_shape_device_v1`.
pub const wp_cursor_shape_device_interface: WlInterface = .{
    .name = "wp_cursor_shape_device_v1",
    .version = version,
    .method_count = 2,
    .methods = &device_requests,
    .event_count = 0,
    .events = null,
};

/// The `wp_cursor_shape_device_v1.shape` number of a `ui.Cursor`.
pub fn shape_of(cursor: areas.Cursor) u32 {
    const shape: u32 = switch (cursor) {
        .default => 1,
        .pointer => 4,
        .text => 9,
        .grab => 16,
        .grabbing => 17,
        .ew_resize => 26,
        .ns_resize => 27,
        .nesw_resize => 28,
        .nwse_resize => 29,
    };
    assert(shape >= 1);
    assert(shape <= 34);
    return shape;
}

/// Issues `wp_cursor_shape_manager_v1.get_pointer` (opcode 1) for `pointer`.
pub fn get_device(manager: *Manager, pointer: *wl_seat.WlPointer) *Device {
    const result = wl_proxy_marshal_flags(
        @ptrCast(manager),
        1,
        &wp_cursor_shape_device_interface,
        version,
        0,
        @as(?*anyopaque, null),
        pointer,
    );
    assert(result != null);
    assert(@intFromPtr(pointer) != 0);
    return @ptrCast(result.?);
}

/// Issues `wp_cursor_shape_device_v1.set_shape` (opcode 1) with the latest enter `serial`.
pub fn set_shape(device: *Device, serial: u32, cursor: areas.Cursor) void {
    const shape = shape_of(cursor);
    _ = wl_proxy_marshal_flags(@ptrCast(device), 1, null, version, 0, serial, shape);
    assert(@intFromPtr(device) != 0);
}

/// Issues `wp_cursor_shape_device_v1.destroy` (opcode 0), for a pointer that goes away.
pub fn destroy_device(device: *Device) void {
    _ = wl_proxy_marshal_flags(@ptrCast(device), 0, null, version, 1);
    assert(@intFromPtr(device) != 0);
}

/// Compile-time consistency checks between the tables and their counts. A function for the
/// same reason as `wp_presentation.assert_interface_tables`.
pub fn assert_interface_tables() void {
    comptime {
        assert(wp_cursor_shape_manager_interface.method_count == manager_requests.len);
        assert(wp_cursor_shape_device_interface.method_count == device_requests.len);
        assert(std.mem.eql(u8, std.mem.span(manager_requests[1].name), "get_pointer"));
        assert(std.mem.eql(u8, std.mem.span(device_requests[1].name), "set_shape"));
    }
}

comptime {
    assert(version == 1);
}

// Locks the shape numbers of `cursor-shape-v1.xml` for every `ui.Cursor`.
test "every cursor maps to its protocol shape" {
    try std.testing.expectEqual(@as(u32, 1), shape_of(.default));
    try std.testing.expectEqual(@as(u32, 4), shape_of(.pointer));
    try std.testing.expectEqual(@as(u32, 9), shape_of(.text));
    try std.testing.expectEqual(@as(u32, 16), shape_of(.grab));
    try std.testing.expectEqual(@as(u32, 17), shape_of(.grabbing));
    try std.testing.expectEqual(@as(u32, 26), shape_of(.ew_resize));
    try std.testing.expectEqual(@as(u32, 27), shape_of(.ns_resize));
    try std.testing.expectEqual(@as(u32, 28), shape_of(.nesw_resize));
    try std.testing.expectEqual(@as(u32, 29), shape_of(.nwse_resize));
}

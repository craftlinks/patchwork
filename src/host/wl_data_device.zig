//! Wayland `wl_data_device_manager`, `wl_data_device`, `wl_data_source`, and `wl_data_offer`
//! client bindings: the clipboard's protocol surface. The state machine is `clipboard.zig`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Version and Tables
//! The host binds `min(advertised, manager_version_max)` (3). Every interface here is core,
//! exported by `libwayland-client.so.0`, so no table is written by hand; only the listener
//! tables are, with one slot per event of version 3 in opcode order (asserted below). Version
//! 3 adds only drag-and-drop actions, which this host never starts, so its events are no-ops.
//!
//! ## 2. Requests Used
//! ```text
//! wl_data_device_manager  create_data_source (0, new_id), get_data_device (1, new_id, seat)
//! wl_data_device          set_selection (1, source?, serial), release (2, v2)
//! wl_data_source          offer (0, mime), destroy (1)
//! wl_data_offer           receive (1, mime, fd), destroy (2)
//! ```
//! `receive` passes a file descriptor; libwayland duplicates it while marshalling, so the
//! caller closes its copy right after the request.
//!
//! ## 3. TigerStyle Invariants
//! - No runtime allocation; proxies belong to libwayland.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");
const wl_seat = @import("wl_seat.zig");

/// Highest `wl_data_device_manager` version the host binds.
pub const manager_version_max: u32 = 3;

pub const Manager = opaque {};
pub const Device = opaque {};
pub const Source = opaque {};
pub const Offer = opaque {};

const WlProxy = xdg.WlProxy;
const WlInterface = xdg.WlInterface;

pub extern const wl_data_device_manager_interface: WlInterface;
pub extern const wl_data_device_interface: WlInterface;
pub extern const wl_data_source_interface: WlInterface;
pub extern const wl_data_offer_interface: WlInterface;

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
extern fn wl_proxy_destroy(proxy: *WlProxy) void;

const marshal_flag_destroy: u32 = 1;

/// `wl_data_device` events at version 3.
pub const DeviceListener = extern struct {
    data_offer: *const fn (data: ?*anyopaque, device: ?*Device, offer: ?*Offer) callconv(.c) void,
    enter: *const fn (
        data: ?*anyopaque,
        device: ?*Device,
        serial: u32,
        surface: ?*xdg.WlSurface,
        x: i32,
        y: i32,
        offer: ?*Offer,
    ) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, device: ?*Device) callconv(.c) void,
    motion: *const fn (
        data: ?*anyopaque,
        device: ?*Device,
        time: u32,
        x: i32,
        y: i32,
    ) callconv(.c) void,
    drop: *const fn (data: ?*anyopaque, device: ?*Device) callconv(.c) void,
    selection: *const fn (data: ?*anyopaque, device: ?*Device, offer: ?*Offer) callconv(.c) void,
};

/// `wl_data_source` events at version 3.
pub const SourceListener = extern struct {
    target: *const fn (data: ?*anyopaque, source: ?*Source, mime: ?[*:0]const u8) callconv(.c) void,
    send: *const fn (
        data: ?*anyopaque,
        source: ?*Source,
        mime: [*:0]const u8,
        fd: i32,
    ) callconv(.c) void,
    cancelled: *const fn (data: ?*anyopaque, source: ?*Source) callconv(.c) void,
    dnd_drop_performed: *const fn (data: ?*anyopaque, source: ?*Source) callconv(.c) void,
    dnd_finished: *const fn (data: ?*anyopaque, source: ?*Source) callconv(.c) void,
    action: *const fn (data: ?*anyopaque, source: ?*Source, action: u32) callconv(.c) void,
};

/// `wl_data_offer` events at version 3.
pub const OfferListener = extern struct {
    offer: *const fn (data: ?*anyopaque, offer: ?*Offer, mime: [*:0]const u8) callconv(.c) void,
    source_actions: *const fn (data: ?*anyopaque, offer: ?*Offer, actions: u32) callconv(.c) void,
    action: *const fn (data: ?*anyopaque, offer: ?*Offer, action: u32) callconv(.c) void,
};

/// The version to bind for an advertised manager version.
pub fn bind_version(advertised: u32) u32 {
    assert(advertised >= 1);
    const version = @min(advertised, manager_version_max);
    assert(version <= manager_version_max);
    return version;
}

/// `wl_data_device_manager.get_data_device` (1) for `seat`.
pub fn get_device(manager: *Manager, seat: *wl_seat.WlSeat) *Device {
    const proxy: *WlProxy = @ptrCast(manager);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        1,
        &wl_data_device_interface,
        version,
        0,
        @as(?*anyopaque, null),
        seat,
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// `wl_data_device_manager.create_data_source` (0).
pub fn create_source(manager: *Manager) *Source {
    const proxy: *WlProxy = @ptrCast(manager);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        0,
        &wl_data_source_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// `wl_data_source.offer` (0): the source can provide `mime`.
pub fn source_offer(source: *Source, mime: [*:0]const u8) void {
    const proxy: *WlProxy = @ptrCast(source);
    _ = wl_proxy_marshal_flags(proxy, 0, null, wl_proxy_get_version(proxy), 0, mime);
    assert(@intFromPtr(source) != 0);
}

/// `wl_data_source.destroy` (1).
pub fn destroy_source(source: *Source) void {
    const proxy: *WlProxy = @ptrCast(source);
    _ = wl_proxy_marshal_flags(proxy, 1, null, wl_proxy_get_version(proxy), marshal_flag_destroy);
    assert(@intFromPtr(source) != 0);
}

/// `wl_data_device.set_selection` (1) with the serial of the input event that caused it.
pub fn set_selection(device: *Device, source: ?*Source, serial: u32) void {
    const proxy: *WlProxy = @ptrCast(device);
    _ = wl_proxy_marshal_flags(proxy, 1, null, wl_proxy_get_version(proxy), 0, source, serial);
    assert(@intFromPtr(device) != 0);
}

/// `wl_data_offer.receive` (1): the source writes `mime` data into `fd` and closes it.
pub fn receive(offer: *Offer, mime: [*:0]const u8, fd: i32) void {
    assert(fd >= 0);
    const proxy: *WlProxy = @ptrCast(offer);
    _ = wl_proxy_marshal_flags(proxy, 1, null, wl_proxy_get_version(proxy), 0, mime, fd);
}

/// `wl_data_offer.destroy` (2).
pub fn destroy_offer(offer: *Offer) void {
    const proxy: *WlProxy = @ptrCast(offer);
    _ = wl_proxy_marshal_flags(proxy, 2, null, wl_proxy_get_version(proxy), marshal_flag_destroy);
    assert(@intFromPtr(offer) != 0);
}

pub fn add_device_listener(
    device: *Device,
    listener: *const DeviceListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(device), listener, data);
    assert(rc == 0);
}

pub fn add_source_listener(
    source: *Source,
    listener: *const SourceListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(source), listener, data);
    assert(rc == 0);
}

pub fn add_offer_listener(offer: *Offer, listener: *const OfferListener, data: *anyopaque) void {
    const rc = wl_proxy_add_listener(@ptrCast(offer), listener, data);
    assert(rc == 0);
}

comptime {
    assert(manager_version_max == 3);
    assert(@typeInfo(DeviceListener).@"struct".field_names.len == 6);
    assert(@typeInfo(SourceListener).@"struct".field_names.len == 6);
    assert(@typeInfo(OfferListener).@"struct".field_names.len == 3);
    assert(@sizeOf(DeviceListener) == 6 * @sizeOf(*const anyopaque));
    assert(@sizeOf(OfferListener) == 3 * @sizeOf(*const anyopaque));
}

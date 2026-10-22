//! Wayland `wl_seat` and `wl_pointer` client bindings, bound at `seat_version`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Bound Version Is Pinned
//! `libwayland-client` dispatches an event by indexing the listener table with the event
//! opcode. A compositor may emit any event up to the version the client bound, so a table
//! with fewer slots than the bound version has events would be indexed past its end. The
//! binding therefore pins `seat_version` and sizes `SeatListener` and `PointerListener` to
//! exactly the events of that version. The `comptime` block at the end of this file enforces
//! the slot counts and the pinned version.
//!
//! Newer pointer events (`wl_pointer.frame` and the axis refinements) are deliberately not
//! used. The host already batches: pointer callbacks are leaf writers into `State.queue`,
//! and `sync_input` drains it once per wake with motion coalesced, so grouping events on the
//! protocol level would add no batching.
//!
//! ## 2. Coordinate Spaces
//! - `sx` and `sy` in `enter` and `motion` are surface-local logical pixels: origin at the
//!   top-left of the surface, +X right, +Y down. The Wayland spec defines them independent of
//!   `wl_surface.set_buffer_scale`, so they share the frame used by layout and
//!   `draw.ortho_y_down`.
//! - On the wire they are `wl_fixed_t`: signed 24.8 fixed point, logical = fixed / 256. The
//!   conversion is `input.fixed_to_logical`; worked values are in the test
//!   "fixed_to_logical converts 24.8" in `input.zig`.
//!
//! ## 3. C ABI Layout
//! Listener structs are `extern struct`s of C-callconv function pointers, with fields in
//! event opcode order and no other members. `WlSeat` and `WlPointer` are opaque `wl_proxy`
//! handles owned by libwayland. Slot counts and sizes are enforced by `comptime` asserts.
//!
//! ## 4. State Machine
//! ```text
//!   registry global "wl_seat"  -> bind at seat_version, install SeatListener
//!   capabilities(pointer set)  -> create wl_pointer once, install PointerListener
//!   capabilities(pointer gone) -> destroy wl_pointer, queue .pointer_leave
//!   enter / motion             -> queue .pointer_move
//!   button (primary only)      -> queue .pointer_down / .pointer_up
//!   leave                      -> queue .pointer_leave
//!   axis (vertical only)       -> queue .wheel
//! ```
//! The dispatch itself lives in `linux_window.zig`; this file owns only the protocol surface.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - `wl_seat_interface` and `wl_pointer_interface` are core symbols exported by
//!   `libwayland-client.so.0`, so they are declared `extern` instead of being rebuilt by hand
//!   as `xdg_shell.zig` does for the xdg extension.
//! - `wl_pointer.release` exists only from `wl_pointer` version 3. At `seat_version` the
//!   proxy is released with `wl_proxy_destroy`, which frees only the client side.
//! - Cursor appearance is undefined until the client calls `wl_pointer.set_cursor` or uses
//!   `wp_cursor_shape_v1`. This binding does neither and relies on the compositor keeping its
//!   default cursor, which is compositor policy and not a protocol guarantee. Setting a
//!   cursor would require an extra `wl_surface` and shm buffer (or the shape protocol).
//!
//! ## 6. TigerStyle Invariants
//! - No runtime allocation; proxies belong to libwayland.
//! - Every listener registration return code and proxy pointer is asserted.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

/// Bound version of `wl_seat` and of the `wl_pointer` proxy it creates. The listener tables
/// are sized for this version's events only; see the `comptime` block.
pub const seat_version: u32 = 1;

/// Bit for `wl_seat.capability.pointer` in the `capabilities` mask. Keyboard and touch
/// capabilities are ignored.
pub const pointer_capability: u32 = 1;

/// Linux input event code `BTN_LEFT` from `<linux/input-event-codes.h>`, the primary button.
/// `wl_pointer.button` reports these codes, not Wayland-specific ones.
pub const button_code_left: u32 = 0x110;

/// `wl_pointer.button_state.pressed`; any other state value is a release.
pub const button_state_pressed: u32 = 1;

/// Opaque handle representing a libwayland `wl_seat` proxy.
pub const WlSeat = opaque {};

/// Opaque handle representing a libwayland `wl_pointer` proxy.
pub const WlPointer = opaque {};

const WlProxy = xdg.WlProxy;
const WlInterface = xdg.WlInterface;

/// Core interface descriptor exported by `libwayland-client.so.0`.
pub extern const wl_seat_interface: WlInterface;

/// Core interface descriptor exported by `libwayland-client.so.0`.
pub extern const wl_pointer_interface: WlInterface;

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

/// Listener table for `wl_seat` at `seat_version`: one slot per event, in opcode order.
pub const SeatListener = extern struct {
    capabilities: *const fn (
        data: ?*anyopaque,
        seat: ?*WlSeat,
        capabilities: u32,
    ) callconv(.c) void,
};

/// Listener table for `wl_pointer` at `seat_version`: one slot per event, in opcode order.
pub const PointerListener = extern struct {
    /// Opcode 0: Pointer entered the surface at surface-local logical coordinates `(sx, sy)`.
    enter: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        surface: ?*xdg.WlSurface,
        sx: i32,
        sy: i32,
    ) callconv(.c) void,
    /// Opcode 1: Pointer left the surface.
    leave: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        surface: ?*xdg.WlSurface,
    ) callconv(.c) void,
    /// Opcode 2: Pointer moved inside surface to surface-local logical coordinates `(sx, sy)`.
    motion: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        sx: i32,
        sy: i32,
    ) callconv(.c) void,
    /// Opcode 3: Button state change. `button` is a Linux input event code.
    button: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        time: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void,
    /// Opcode 4: Scroll wheel or trackpad axis movement; `value` is `wl_fixed_t`.
    axis: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        axis: u32,
        value: i32,
    ) callconv(.c) void,
};

/// Issues `wl_seat.get_pointer` (request opcode 0) and returns the new pointer proxy.
/// Precondition: `seat` is a live `wl_seat` proxy bound at `seat_version`.
pub fn get_pointer(seat: *WlSeat) *WlPointer {
    const proxy: *WlProxy = @ptrCast(seat);
    const version = wl_proxy_get_version(proxy);
    assert(version == seat_version);
    const result = wl_proxy_marshal_flags(
        proxy,
        0,
        &wl_pointer_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Destroys a `wl_pointer` proxy with `wl_proxy_destroy`, because `wl_pointer.release` does
/// not exist at `seat_version`.
pub fn destroy_pointer(pointer: *WlPointer) void {
    const proxy: *WlProxy = @ptrCast(pointer);
    wl_proxy_destroy(proxy);
    assert(@intFromPtr(pointer) != 0);
}

/// Installs `listener` on `seat`. `listener` must outlive the proxy. libwayland rejects a
/// second listener on the same proxy, which the return-code assert surfaces.
pub fn add_seat_listener(
    seat: *WlSeat,
    listener: *const SeatListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(seat), listener, data);
    assert(rc == 0);
}

/// Installs `listener` on `pointer`. `listener` must outlive the proxy.
pub fn add_pointer_listener(
    pointer: *WlPointer,
    listener: *const PointerListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(pointer), listener, data);
    assert(rc == 0);
    assert(seat_version == 1);
}

comptime {
    // libwayland indexes listeners by opcode, so slot counts must equal the event counts of
    // the bound version. The remaining asserts pin protocol-defined constants.
    assert(seat_version == 1);
    assert(@typeInfo(SeatListener).@"struct".field_names.len == 1);
    assert(@typeInfo(PointerListener).@"struct".field_names.len == 5);
    assert(pointer_capability == 1);
    assert(button_code_left == 0x110);
    assert(button_state_pressed == 1);
    assert(@sizeOf(SeatListener) == 8);
    assert(@sizeOf(PointerListener) == 40);
}

//! Wayland `wl_seat`, `wl_pointer`, and `wl_keyboard` client bindings, bound at
//! `min(advertised, seat_version_max)`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Tables Are Sized for the Maximum Version
//! `libwayland-client` dispatches an event by indexing the listener table with the event
//! opcode. A compositor may emit any event up to the version the client bound, so a table
//! with fewer slots than the bound version has events would be indexed past its end. The host
//! binds `min(advertised, seat_version_max)` and the tables here have exactly the events of
//! `seat_version_max` (8): a lower bound version simply never delivers the later events, so
//! the same tables serve every version. The `comptime` block enforces the slot counts.
//!
//! Version 8 brings what the host uses: `repeat_info` (4), `wl_pointer.frame` and the axis
//! refinements (5), and the `release` requests (3). The refinements are no-ops: pointer
//! callbacks are leaf writers into the event queue, the queue merges a horizontal and a
//! vertical axis of one frame into one diagonal wheel (`input.zig`, section 1), and the `axis`
//! value is already the pixel delta, so `frame`, `axis_source`, `axis_stop`,
//! `axis_discrete`, and `axis_value120` add nothing. Version 9's relative direction and 10's
//! compositor-side repeat are not bound.
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
//! event opcode order and no other members. `WlSeat`, `WlPointer`, and `WlKeyboard` are opaque
//! `wl_proxy` handles owned by libwayland. Slot counts and sizes are enforced at compile time.
//!
//! ## 4. State Machine
//! ```text
//!   registry global "wl_seat"   -> bind at min(advertised, 8), install SeatListener
//!   capabilities(pointer set)   -> create wl_pointer once, install PointerListener
//!   capabilities(keyboard set)  -> create wl_keyboard once, install KeyboardListener
//!   capabilities(either gone)   -> release that proxy (pointer: queue .pointer_leave;
//!                                  keyboard: queue .window_focus = false)
//!   enter / motion              -> queue .pointer_move (enter also stores its serial)
//!   button (left, right, middle)-> queue .pointer_down / .pointer_up with time and mods
//!   axis (both axes)            -> queue .wheel (dx or dy)
//!   keymap / modifiers          -> xkb state (xkb.zig)
//!   key                         -> queue .key_down / .key_up; arm or disarm repeat
//!   keyboard enter / leave      -> queue .window_focus
//! ```
//! The dispatch itself lives in `linux_window.zig`; this file owns only the protocol surface.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - `wl_seat_interface`, `wl_pointer_interface`, and `wl_keyboard_interface` are core symbols
//!   exported by `libwayland-client.so.0`, so they are declared `extern`.
//! - `release` exists from version 3; below it a proxy is destroyed with `wl_proxy_destroy`,
//!   which frees only the client side.
//! - The cursor is set through `wp_cursor_shape_v1` (`wp_cursor_shape.zig`) with the serial of
//!   the latest `enter`.
//!
//! ## 5a. Touch
//! `wl_touch` (capability bit 4) delivers fingers in order, each with a compositor id, unique
//! only while the finger is down. The listener has the seven events of version 8:
//! ```text
//! down(serial, time, surface, id, x, y)   queue .touch_down, the serial kept for a window move
//! up(serial, time, id)                    queue .touch_up (it carries no position)
//! motion(time, id, x, y)                  queue .touch_move; the queue keeps one per id
//! frame                                   no-op: events stay in order, so groups are kept
//! cancel                                  queue .touch_cancel = null: the compositor took them all
//! shape, orientation                      no-ops: there is no pressure or contact size in the UI
//! ```
//! Positions are `wl_fixed_t` surface-local logical pixels, like the pointer's. Nothing here arms
//! a timer, so touch moves only reach the queue and an idle app sleeps.
//!
//! ## 6. TigerStyle Invariants
//! - No runtime allocation; proxies belong to libwayland.
//! - Every listener registration return code and proxy pointer is asserted.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

/// Highest `wl_seat` version the host binds; the listener tables have its events.
pub const seat_version_max: u32 = 8;

/// Bits of `wl_seat.capability`.
pub const pointer_capability: u32 = 1;
pub const keyboard_capability: u32 = 2;
pub const touch_capability: u32 = 4;

/// Linux input event codes from `<linux/input-event-codes.h>`, which `wl_pointer.button`
/// reports.
pub const button_code_left: u32 = 0x110;
pub const button_code_right: u32 = 0x111;
pub const button_code_middle: u32 = 0x112;

/// `wl_pointer.button_state.pressed` and `wl_keyboard.key_state.pressed`; any other state is
/// a release (version 10's `repeated` is never sent at the versions bound).
pub const button_state_pressed: u32 = 1;
pub const key_state_pressed: u32 = 1;

/// `wl_pointer.axis`: 0 vertical, 1 horizontal.
pub const axis_vertical: u32 = 0;
pub const axis_horizontal: u32 = 1;

/// `wl_keyboard.keymap_format.xkb_v1`.
pub const keymap_format_xkb_v1: u32 = 1;

/// libwayland's `WL_MARSHAL_FLAG_DESTROY`: the request destroys the proxy.
const marshal_flag_destroy: u32 = 1;

pub const WlSeat = opaque {};
pub const WlPointer = opaque {};
pub const WlKeyboard = opaque {};
pub const WlTouch = opaque {};

const WlProxy = xdg.WlProxy;
const WlInterface = xdg.WlInterface;

pub extern const wl_seat_interface: WlInterface;
pub extern const wl_pointer_interface: WlInterface;
pub extern const wl_keyboard_interface: WlInterface;
pub extern const wl_touch_interface: WlInterface;

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

/// Listener table for `wl_seat` at `seat_version_max`: one slot per event, in opcode order.
pub const SeatListener = extern struct {
    capabilities: *const fn (
        data: ?*anyopaque,
        seat: ?*WlSeat,
        capabilities: u32,
    ) callconv(.c) void,
    name: *const fn (data: ?*anyopaque, seat: ?*WlSeat, name: [*:0]const u8) callconv(.c) void,
};

/// Listener table for `wl_pointer` at `seat_version_max`: one slot per event, in opcode order.
pub const PointerListener = extern struct {
    /// 0: entered the surface at surface-local `(sx, sy)`; the serial sets the cursor.
    enter: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        surface: ?*xdg.WlSurface,
        sx: i32,
        sy: i32,
    ) callconv(.c) void,
    /// 1: left the surface.
    leave: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        surface: ?*xdg.WlSurface,
    ) callconv(.c) void,
    /// 2: moved to surface-local `(sx, sy)`.
    motion: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        sx: i32,
        sy: i32,
    ) callconv(.c) void,
    /// 3: a button changed; `button` is a Linux input event code.
    button: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        time: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void,
    /// 4: scroll on `axis`; `value` is `wl_fixed_t`.
    axis: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        axis: u32,
        value: i32,
    ) callconv(.c) void,
    /// 5 (v5): end of a group of events.
    frame: *const fn (data: ?*anyopaque, pointer: ?*WlPointer) callconv(.c) void,
    /// 6 (v5): the source of the axis events in this frame.
    axis_source: *const fn (data: ?*anyopaque, pointer: ?*WlPointer, source: u32) callconv(.c) void,
    /// 7 (v5): an axis stopped.
    axis_stop: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        axis: u32,
    ) callconv(.c) void,
    /// 8 (v5 to 7): discrete steps.
    axis_discrete: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        axis: u32,
        discrete: i32,
    ) callconv(.c) void,
    /// 9 (v8): high-resolution discrete steps.
    axis_value120: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        axis: u32,
        value120: i32,
    ) callconv(.c) void,
};

/// Listener table for `wl_keyboard` at `seat_version_max`: one slot per event, in opcode order.
pub const KeyboardListener = extern struct {
    /// 0: the keymap as a file descriptor the client must close.
    keymap: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        format: u32,
        fd: i32,
        size: u32,
    ) callconv(.c) void,
    /// 1: keyboard focus entered the surface.
    enter: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        serial: u32,
        surface: ?*xdg.WlSurface,
        keys: ?*xdg.WlArray,
    ) callconv(.c) void,
    /// 2: keyboard focus left the surface.
    leave: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        serial: u32,
        surface: ?*xdg.WlSurface,
    ) callconv(.c) void,
    /// 3: a key changed; `key` is an evdev code (xkb keycode minus 8).
    key: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        serial: u32,
        time: u32,
        key: u32,
        state: u32,
    ) callconv(.c) void,
    /// 4: the modifier and group state.
    modifiers: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        serial: u32,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) callconv(.c) void,
    /// 5 (v4): repeats per second (0 disables) and the delay in milliseconds.
    repeat_info: *const fn (
        data: ?*anyopaque,
        keyboard: ?*WlKeyboard,
        rate: i32,
        delay: i32,
    ) callconv(.c) void,
};

/// Listener table for `wl_touch` at `seat_version_max`: one slot per event, in opcode order.
pub const TouchListener = extern struct {
    /// 0: a finger landed at surface-local `(x, y)`; the serial starts a window move.
    down: *const fn (
        data: ?*anyopaque,
        touch: ?*WlTouch,
        serial: u32,
        time: u32,
        surface: ?*xdg.WlSurface,
        id: i32,
        x: i32,
        y: i32,
    ) callconv(.c) void,
    /// 1: a finger lifted.
    up: *const fn (
        data: ?*anyopaque,
        touch: ?*WlTouch,
        serial: u32,
        time: u32,
        id: i32,
    ) callconv(.c) void,
    /// 2: a finger moved to surface-local `(x, y)`.
    motion: *const fn (
        data: ?*anyopaque,
        touch: ?*WlTouch,
        time: u32,
        id: i32,
        x: i32,
        y: i32,
    ) callconv(.c) void,
    /// 3: end of a group of events.
    frame: *const fn (data: ?*anyopaque, touch: ?*WlTouch) callconv(.c) void,
    /// 4: the compositor took every finger.
    cancel: *const fn (data: ?*anyopaque, touch: ?*WlTouch) callconv(.c) void,
    /// 5 (v6): the contact ellipse of a finger.
    shape: *const fn (
        data: ?*anyopaque,
        touch: ?*WlTouch,
        id: i32,
        major: i32,
        minor: i32,
    ) callconv(.c) void,
    /// 6 (v6): the contact ellipse's orientation.
    orientation: *const fn (
        data: ?*anyopaque,
        touch: ?*WlTouch,
        id: i32,
        orientation: i32,
    ) callconv(.c) void,
};

/// The version to bind for an advertised `wl_seat` version.
pub fn bind_version(advertised: u32) u32 {
    assert(advertised >= 1);
    const version = @min(advertised, seat_version_max);
    assert(version <= seat_version_max);
    return version;
}

/// Issues `wl_seat.get_pointer` (request 0) and returns the new pointer proxy.
pub fn get_pointer(seat: *WlSeat) *WlPointer {
    return @ptrCast(get_device(seat, 0, &wl_pointer_interface));
}

/// Issues `wl_seat.get_keyboard` (request 1) and returns the new keyboard proxy.
pub fn get_keyboard(seat: *WlSeat) *WlKeyboard {
    return @ptrCast(get_device(seat, 1, &wl_keyboard_interface));
}

/// Issues `wl_seat.get_touch` (request 2) and returns the new touch proxy.
pub fn get_touch(seat: *WlSeat) *WlTouch {
    return @ptrCast(get_device(seat, 2, &wl_touch_interface));
}

fn get_device(seat: *WlSeat, opcode: u32, interface: *const WlInterface) *WlProxy {
    const proxy: *WlProxy = @ptrCast(seat);
    const version = wl_proxy_get_version(proxy);
    assert(version >= 1);
    assert(version <= seat_version_max);
    const result = wl_proxy_marshal_flags(
        proxy,
        opcode,
        interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return result.?;
}

/// Releases a pointer: `wl_pointer.release` (request 1) from version 3, else the client side.
pub fn release_pointer(pointer: *WlPointer) void {
    release(@ptrCast(pointer), 1);
}

/// Releases a keyboard: `wl_keyboard.release` (request 0) from version 3, else the client side.
pub fn release_keyboard(keyboard: *WlKeyboard) void {
    release(@ptrCast(keyboard), 0);
}

/// Releases a touch: `wl_touch.release` (request 0) from version 3, else the client side.
pub fn release_touch(touch: *WlTouch) void {
    release(@ptrCast(touch), 0);
}

fn release(proxy: *WlProxy, opcode: u32) void {
    const version = wl_proxy_get_version(proxy);
    assert(version >= 1);
    if (version >= 3) {
        _ = wl_proxy_marshal_flags(proxy, opcode, null, version, marshal_flag_destroy);
        return;
    }
    wl_proxy_destroy(proxy);
}

/// Installs `listener` on `seat`. `listener` must outlive the proxy.
pub fn add_seat_listener(seat: *WlSeat, listener: *const SeatListener, data: *anyopaque) void {
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
}

/// Installs `listener` on `keyboard`. `listener` must outlive the proxy.
pub fn add_keyboard_listener(
    keyboard: *WlKeyboard,
    listener: *const KeyboardListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(keyboard), listener, data);
    assert(rc == 0);
}

/// Installs `listener` on `touch`. `listener` must outlive the proxy.
pub fn add_touch_listener(touch: *WlTouch, listener: *const TouchListener, data: *anyopaque) void {
    const rc = wl_proxy_add_listener(@ptrCast(touch), listener, data);
    assert(rc == 0);
}

comptime {
    // libwayland indexes listeners by opcode, so slot counts must equal the event counts of
    // `seat_version_max`. The remaining asserts pin protocol-defined constants.
    assert(seat_version_max == 8);
    assert(@typeInfo(SeatListener).@"struct".field_names.len == 2);
    assert(@typeInfo(PointerListener).@"struct".field_names.len == 10);
    assert(@typeInfo(KeyboardListener).@"struct".field_names.len == 6);
    assert(@typeInfo(TouchListener).@"struct".field_names.len == 7);
    assert(@sizeOf(TouchListener) == 7 * @sizeOf(*const anyopaque));
    assert(touch_capability == 4);
    assert(@sizeOf(SeatListener) == 2 * @sizeOf(*const anyopaque));
    assert(@sizeOf(PointerListener) == 10 * @sizeOf(*const anyopaque));
    assert(@sizeOf(KeyboardListener) == 6 * @sizeOf(*const anyopaque));
    assert(pointer_capability == 1);
    assert(keyboard_capability == 2);
    assert(button_code_left == 0x110);
    assert(button_code_right == button_code_left + 1);
    assert(button_code_middle == button_code_left + 2);
}

// Locks the bound version: the advertised one up to 8, never above.
test "the seat binds the advertised version up to 8" {
    try std.testing.expectEqual(@as(u32, 1), bind_version(1));
    try std.testing.expectEqual(@as(u32, 5), bind_version(5));
    try std.testing.expectEqual(@as(u32, 8), bind_version(8));
    try std.testing.expectEqual(@as(u32, 8), bind_version(11));
}

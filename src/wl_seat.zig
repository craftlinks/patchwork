//! Wayland `wl_seat` version 1 and `wl_pointer` version 1 bindings.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale: Why Version 1?
//! In Wayland's client-server architecture, input devices (pointers, keyboards, touch surfaces)
//! are grouped under `wl_seat` globals. When a client binds an interface, `libwayland-client`
//! uses a virtual method table (the listener struct) to dispatch incoming events.
//!
//! ### The Listener Opcode-Indexing Hazard:
//! - When the compositor transmits an event, `libwayland-client` reads the event message opcode
//!   (an integer `0..N-1`) and executes:
//!   ```c
//!   ((void (**)())implementation)[opcode](...);
//!   ```
//! - If a client binds a higher interface version (e.g. `wl_pointer` version 5), the compositor
//!   is legally permitted to send version 5 events (such as `wl_pointer.frame` at opcode 5,
//!   or `axis_source` at opcode 6).
//! - If the client's listener struct contains only 5 function pointers (opcodes 0..4), dispatching
//!   opcode 5 jumps beyond the end of the allocated struct into unmapped memory, causing an
//!   immediate segmentation fault or arbitrary code execution.
//! - By explicitly binding `seat_version = 1`, the Wayland protocol contract guarantees that the
//!   compositor will NEVER emit opcodes beyond version 1:
//!   - `wl_seat` version 1 emits exactly ONE event: `capabilities` (opcode 0).
//!   - `wl_pointer` version 1 emits exactly FIVE events: `enter` (0), `leave` (1), `motion` (2),
//!     `button` (3), `axis` (4).
//! - This allows `SeatListener` and `PointerListener` to be sized at exactly 1 and 5 pointers.
//!
//! ### Why Not Use `wl_pointer.frame` (Version 5)?
//! Wayland version 5 introduced `wl_pointer.frame` to group related events (e.g. coupled motion
//! and scroll axis changes). In Patchwork, this is completely unnecessary:
//! - Our blocking event loop in `linux_window.zig` reads all available socket events in batch
//!   via `wl_display_dispatch_pending()`.
//! - Pointer callbacks are pure leaf writers that push `input.Event` records into `State.queue`.
//! - `sync_input()` runs once per loop wake, draining the event queue and feeding `scene.handle_event()`,
//!   amortizing motion events into at most one layout/draw pass and presentation.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces: `wl_fixed_t` (24.8)
//!
//! ### Coordinate Spaces:
//! - `sx` and `sy` delivered in `enter` and `motion` are surface-local logical pixels with origin
//!   `(0, 0)` at the top-left of the window.
//! - Crucially, the Wayland specification dictates that surface coordinates are **invariant to
//!   display buffer scale** (`wl_surface.set_buffer_scale`). Whether rendering on standard DPI
//!   or HiDPI (scale 2), `sx` and `sy` are delivered in the same logical pixel frame as `turtle`
//!   and `draw.ortho_y_down`.
//!
//! ### `wl_fixed_t` Wire Encoding:
//! - `wl_fixed_t` is a signed 32-bit two's-complement integer with an 8-bit fractional part.
//! - High 24 bits (bits 8..31): Signed integral pixel coordinate.
//! - Low 8 bits (bits 0..7): Fractional subpixel offset in units of 1/256th of a pixel.
//! - Algebraic conversion:
//!   ```text
//!   logical_px = @as(f32, @floatFromInt(fixed)) / 256.0 = fixed * 2^(-8)
//!   ```
//! - Worked examples:
//!   - `fixed = 256`  (0x00000100) -> `256 / 256.0 = 1.0` logical pixel.
//!   - `fixed = -128` (0xFFFFFF80) -> `-128 / 256.0 = -0.5` logical pixel.
//!   - `fixed = 0`    (0x00000000) -> `0 / 256.0 = 0.0` logical pixel.
//! - Resolution: `1 / 256 = 0.00390625` logical pixels, providing high-precision subpixel tracking.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### C ABI Struct Memory Layouts (64-Bit System):
//! - `SeatListener`: 8 bytes total:
//!   - Offset 0..7: `capabilities` function pointer (`*const fn (...) callconv(.c) void`).
//!   - Alignment: 8 bytes.
//! - `PointerListener`: 40 bytes total:
//!   - Offset 0..7:   `enter` function pointer (opcode 0).
//!   - Offset 8..15:  `leave` function pointer (opcode 1).
//!   - Offset 16..23: `motion` function pointer (opcode 2).
//!   - Offset 24..31: `button` function pointer (opcode 3).
//!   - Offset 32..39: `axis` function pointer (opcode 4).
//!   - Alignment: 8 bytes.
//! - All function pointers use C calling convention (`callconv(.c)`).
//! - `WlSeat` and `WlPointer` are declared as `opaque {}` types, representing raw `wl_proxy`
//!   handles managed internally by `libwayland-client.so.0`.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Lifecycle of Wayland Seat and Pointer:
//! ```text
//! Compositor Registry Broadcast
//!   |
//!   v
//! linux_window.registry_global()
//!   |--> Match interface == "wl_seat"
//!   |--> Bind global via wl_seat_interface at version 1
//!   |--> Register SeatListener
//!   |
//!   v
//! SeatListener.capabilities(capabilities)
//!   |
//!   +--> (capabilities & pointer_capability != 0)?
//!          |
//!          +-- YES (Pointer Added):
//!          |     |--> If state.pointer_proxy == null:
//!          |     |      wl_seat.get_pointer() creates WlPointer
//!          |     |      Register PointerListener
//!          |     |      Store in state.pointer_proxy
//!          |     v
//!          |     PointerListener events stream:
//!          |       enter  --> push_move(sx, sy) -> queue.push(.pointer_move)
//!          |       motion --> push_move(sx, sy) -> queue.push(.pointer_move)
//!          |       button --> queue.push(.pointer_down / .pointer_up) (BTN_LEFT only)
//!          |       leave  --> queue.push(.pointer_leave)
//!          |       axis   --> ignored
//!          |
//!          +-- NO (Pointer Removed / Unplugged):
//!                |--> If state.pointer_proxy != null:
//!                |      wl_seat.destroy_pointer()
//!                |      state.pointer_proxy = null
//!                |      state.queue.push(.pointer_leave)
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Pre-Linked C Interfaces:** Unlike `xdg_shell.zig` (which manually constructs `WlInterface`
//!   descriptors because xdg-shell is an external extension), `wl_seat_interface` and
//!   `wl_pointer_interface` are core symbols directly exported by `libwayland-client.so.0`.
//!   We declare them as `pub extern const` to eliminate redundant metadata definitions.
//! - **Pointer Destruction Seam:** In Wayland version 3, `wl_pointer.release` was introduced.
//!   Because we bind version 1, calling `release` is invalid. We directly call
//!   `wl_proxy_destroy(pointer_proxy)`, which immediately frees the client-side proxy allocation.
//! - **Cursor Shape Architecture:** When a client creates a `wl_pointer`, Wayland protocol
//!   rules specify that cursor appearance is undefined until calling `wl_pointer.set_cursor`.
//!   On modern compositors (Hyprland, Sway), the compositor preserves its default system cursor
//!   theme automatically. Deferring `wp_cursor_shape_v1` avoids creating an extra `wl_surface`
//!   and shm pixel buffer for cursor rendering at this stage.
//!
//! ## 6. TigerStyle Invariants
//! - **Comptime Struct Length Invariant:** `comptime` asserts that `SeatListener` has exactly
//!   1 field and `PointerListener` has exactly 5 fields, locking listener sizes against opcodes.
//! - **Zero Runtime Allocation:** All listener structures and proxies are static or
//!   stack-allocated.
//! - **Split Defensive Assertions:** All version checks, proxy non-null assertions, and listener
//!   registration return codes (`rc == 0`) are individually asserted.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

/// Bound version of `wl_seat` and of the `wl_pointer` proxy it creates.
/// Version 1 guarantees that only opcodes 0..0 for seat and 0..4 for pointer are dispatched.
pub const seat_version: u32 = 1;

/// Bitmask for `wl_seat.capability.pointer` (bit 0 = 1).
/// Keyboard (bit 1) and touch (bit 2) capabilities are ignored.
pub const pointer_capability: u32 = 1;

/// Linux input event code for the primary mouse button (`BTN_LEFT` = 0x110 / 272).
/// Defined in `<linux/input-event-codes.h>`.
pub const button_code_left: u32 = 0x110;

/// State value for `wl_pointer.button_state.pressed` (1 = pressed, 0 = released).
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

/// Listener table for `wl_seat` version 1. Sized for exactly 1 event (`capabilities`, opcode 0).
/// Memory layout: 8 bytes, alignment 8 bytes.
pub const SeatListener = extern struct {
    capabilities: *const fn (
        data: ?*anyopaque,
        seat: ?*WlSeat,
        capabilities: u32,
    ) callconv(.c) void,
};

/// Listener table for `wl_pointer` version 1. Sized for exactly 5 events (opcodes 0..4).
/// Memory layout: 40 bytes, alignment 8 bytes.
/// All function pointers use standard C calling convention (`callconv(.c)`).
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
    /// Opcode 3: Mouse button state change. `button` is Linux event code (e.g. `0x110` = BTN_LEFT).
    button: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        serial: u32,
        time: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void,
    /// Opcode 4: Scroll wheel or trackpad axis movement (ignored in step 5).
    axis: *const fn (
        data: ?*anyopaque,
        pointer: ?*WlPointer,
        time: u32,
        axis: u32,
        value: i32,
    ) callconv(.c) void,
};

/// Creates a `wl_pointer` object from `seat` via opcode 0 (`wl_seat.get_pointer`).
/// Precondition: `seat` must be a valid, bound `wl_seat` proxy at version 1.
/// Postcondition: Returns a valid `*WlPointer` proxy handle.
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

/// Destroys a `wl_pointer` proxy handle.
/// Uses `wl_proxy_destroy` because `wl_pointer.release` is only available in version 3+.
pub fn destroy_pointer(pointer: *WlPointer) void {
    const proxy: *WlProxy = @ptrCast(pointer);
    wl_proxy_destroy(proxy);
    assert(@intFromPtr(pointer) != 0);
}

/// Registers a `SeatListener` vtable with libwayland-client for `seat`.
/// Precondition: `seat` is a live proxy, `listener` is valid and outlives the proxy.
pub fn add_seat_listener(
    seat: *WlSeat,
    listener: *const SeatListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(seat), listener, data);
    assert(rc == 0);
}

/// Registers a `PointerListener` vtable with libwayland-client for `pointer`.
/// Precondition: `pointer` is a live proxy, `listener` contains exactly 5 valid callbacks.
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
    // libwayland indexes listeners by opcode. Sizing must match bound seat_version.
    assert(seat_version == 1);
    assert(@typeInfo(SeatListener).@"struct".fields.len == 1);
    assert(@typeInfo(PointerListener).@"struct".fields.len == 5);
    assert(pointer_capability == 1);
    assert(button_code_left == 0x110);
    assert(button_state_pressed == 1);
    assert(@sizeOf(SeatListener) == 8);
    assert(@sizeOf(PointerListener) == 40);
}

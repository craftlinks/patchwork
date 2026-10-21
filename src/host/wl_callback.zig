//! Wayland `wl_callback` client binding for `wl_surface.frame`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Frame Callbacks Instead of an Interval Timer
//! `wl_surface.frame` is both the animation clock and the present throttle: the compositor
//! sends `wl_callback.done` once the surface contents of the next `wl_surface.commit` have
//! been taken into a presentation cycle. An interval timer (`timerfd`, `nanosleep`) is
//! unrelated to display refresh, so it drifts in phase against vertical blanking and wakes
//! the process while the UI is static. A frame callback is requested only when a commit is
//! owed, so a settled UI arms nothing and the loop sleeps with a null `ppoll` timeout.
//!
//! `done` is NOT the timing anchor for scheduling the next commit. Its arrival time includes
//! compositor render time and driver pacing (for example Mesa's `wp_fifo_v1` barrier commit
//! delays every other `done` by a refresh period). The anchor is the pageflip timestamp from
//! `wp_presentation.presented`; the receipt time of `done` is only the fallback. See the
//! module guide of `wp_presentation.zig` for the root cause, and `frame.present_deadline`
//! and its tests in `frame.zig` for the projection.
//!
//! ## 2. Time Units
//! `callback_data` is a `u32` millisecond timestamp on a compositor-chosen clock. It wraps,
//! so consumers must difference it with wrapping arithmetic. `animator.Clock.advance` does
//! that and clamps the delta; the test "clock deltas wrap and clamp, and reset rearms" in
//! `animator.zig` locks it.
//!
//! ## 3. Protocol Rules and C ABI
//! - `wl_surface.frame` is a `wl_surface` request that creates a `wl_callback` (version 1).
//!   `wl_callback` has one event, `done` (opcode 0), so `CallbackListener` has one slot.
//!   Both facts are enforced by the `comptime` block at the end of this file.
//! - `wl_callback` is one-shot and `done` is its destructor on the server side. The client
//!   MUST call `destroy_callback` from the `done` listener, or the client-side `WlProxy`
//!   leaks.
//! - `wl_callback_interface` is exported by `libwayland-client.so.0`, so no hand-written
//!   interface table is needed (contrast `xdg_shell.zig`).
//!
//! ## 4. State Machine
//! Exactly one frame callback is in flight at a time, tracked by `State.frame_callback` in
//! `linux_window.zig`.
//! ```text
//!   redraw owed, no callback in flight
//!       -> request_frame, then gpu.submit() (the commit the callback attaches to)
//!       -> callback in flight: later wakes leave redraw set and do not present
//!       -> done: destroy proxy, record timestamp, clear in-flight state
//!       -> redraw still owed?  yes: schedule the next commit   no: sleep in ppoll
//! ```
//! A `done` that finds nothing dirty arms nothing, which is what returns the process to idle.
//!
//! ## 5. Cross-Platform Seam
//! The browser host plays the role of `wl_surface.frame` with `requestAnimationFrame`.
//!
//! ## 6. TigerStyle Invariants
//! - The listener is a statically allocated const table; no runtime allocation.
//! - The `done` handler in `linux_window.zig` only records state and destroys the proxy. It
//!   never lays out, draws, or allocates inside Wayland socket dispatch.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

/// Opaque `wl_callback` proxy. One-shot; destroy it from the `done` listener.
pub const WlCallback = opaque {};

const WlProxy = xdg.WlProxy;
const WlInterface = xdg.WlInterface;

/// Core interface descriptor exported by `libwayland-client.so.0`.
pub extern const wl_callback_interface: WlInterface;

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

/// Listener for `wl_callback` version 1. Slot order is event opcode order, because
/// libwayland indexes the table by opcode; see the `comptime` block below.
pub const CallbackListener = extern struct {
    done: *const fn (
        data: ?*anyopaque,
        callback: ?*WlCallback,
        callback_data: u32,
    ) callconv(.c) void,
};

/// Issues `wl_surface.frame` (request opcode 3 of `wl_surface`). The request attaches to the
/// next `wl_surface.commit`, so call it before the commit. The returned proxy is one-shot and
/// must be released with `destroy_callback`.
pub fn request_frame(surface: *xdg.WlSurface) *WlCallback {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    assert(version >= 1);
    const result = wl_proxy_marshal_flags(
        proxy,
        3,
        &wl_callback_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Installs the one-entry `done` listener. `listener` must outlive the proxy.
pub fn add_callback_listener(
    callback: *WlCallback,
    listener: *const CallbackListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(callback), listener, data);
    assert(rc == 0);
    assert(@intFromPtr(callback) != 0);
}

/// Destroys the one-shot proxy. Call this from `done`; the server will not reuse it.
pub fn destroy_callback(callback: *WlCallback) void {
    const proxy: *WlProxy = @ptrCast(callback);
    assert(@intFromPtr(proxy) != 0);
    wl_proxy_destroy(proxy);
    assert(@intFromPtr(callback) != 0);
}

comptime {
    // One slot per `wl_callback` v1 event; a wider table would be indexed past its end.
    assert(@typeInfo(CallbackListener).@"struct".fields.len == 1);
    assert(@sizeOf(CallbackListener) == 8);
}

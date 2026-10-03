//! Wayland `wl_callback` client protocol binding for `wl_surface.frame`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! A Wayland client has to present on the compositor's frame cadence. `wl_surface.frame` is both
//! the animation clock and the present throttle: one commit per callback, with the freshest
//! pointer sample, and no further callback once a `done` finds nothing dirty.
//!
//! ### Frame Callbacks vs. OS Timers (`timerfd`):
//! - A naive approach uses an OS interval timer (such as Linux `timerfd` or POSIX
//!   `nanosleep(16ms)`). Periodic timers fire continuously regardless of display refresh,
//!   leading to frame tearing, phase drift against compositor vertical blanking, and unnecessary
//!   CPU wakeups while the UI is completely static.
//! - Wayland provides `wl_surface.frame` (opcode 3 on `wl_surface`). When invoked, the compositor
//!   schedules a `wl_callback.done` event to be sent back to the client as soon as the surface
//!   contents from the next `wl_surface.commit` have been presented to the screen.
//! - The callback payload `callback_data: u32` delivers the exact compositor presentation
//!   timestamp in milliseconds.
//!
//! ### One-Shot Lifecycle and Proxy Destruction:
//! A `wl_callback` proxy object is strictly one-shot. Once the compositor fires `done`, the server
//! side of the object is automatically destroyed. The client MUST destroy its corresponding
//! client-side `WlProxy` by invoking `wl_proxy_destroy` inside the `done` callback listener.
//! Failure to destroy the proxy results in a memory leak of the `wl_proxy` tracking struct.
//!
//! ### Idle Invariant (0.0% CPU in `poll(-1)`):
//! Every commit in `linux_window.zig` requests `wl_surface.frame` immediately before
//! `gpu.present()`.
//! That present is the commit the callback attaches to. `present_if_dirty` does not draw or present
//! while `state.frame_callback != null`. It leaves `redraw` set, so the next `done` commits the
//! latest coalesced pointer. A settled slider drag still produces one commit per compositor frame.
//!
//! A `done` that finds `redraw == false` arms nothing. The main thread then enters
//! `ppoll` with a null timeout and sleeps at zero CPU until the compositor writes again. A pointer
//! resting on a settled widget does not set `redraw`, so that `done` is what returns the process
//! to idle. While a callback is in flight, `sync_clock` still steps animators from the timestamp.
//!
//! ### What `done` Is and Is Not Used For:
//! `wl_callback.done` serves as the presentation throttle and animation clock, but it is NOT the
//! primary timing anchor for scheduling future commits. The primary anchor is the display hardware
//! pageflip timestamp delivered by `wp_presentation.presented` (see `wp_presentation.zig`), with
//! the arrival instant of `done` used strictly as a fallback.
//!
//! Why `done` is insufficient as an anchor:
//! 1. Compositors dispatch `done` after completing compositor rendering, so its arrival carries
//!    compositor CPU/GPU execution jitter. On Hyprland 0.56.2 / Mesa 26.2.2 (3840x2160@60 Hz),
//!    `done` arrives ~0.35 ms after the pageflip (p95 0.55 ms), with median commit-to-pageflip
//!    latency of 2.6-2.7 ms.
//! 2. Graphics drivers can introduce additional presentation latency. Under Mesa's FIFO
//!    implementation using `wp_fifo_v1`, each present issues two commits (attach, set_barrier,
//!    wait_barrier, commit, wait_barrier, commit). The barrier-held second commit delays every
//!    other `done` event by an entire refresh period, causing presented frame intervals to
//!    alternate between 1-period and 2-period gaps (105 vs 89).
//! 3. Under Mailbox present mode (1 attach + 1 commit per present), `done` arrives consistently
//!    ~0.35 ms after each pageflip, yielding 267 one-period vs 3 two-period gaps in 6 s, and 348
//!    one-period vs 7 two-period gaps over 377 presents in an 8 s sweep.
//!
//! Direct pageflip timestamps from `wp_presentation` are free from compositor rendering jitter
//! and driver pacing artifacts, allowing deadline projection in `frame.present_deadline`:
//! ```text
//! earliest = now + margin
//! k        = ceil((earliest - anchor) / refresh)   (0 if anchor >= earliest)
//! vblank   = anchor + k * refresh
//! deadline = vblank - margin                       (reduces to done + refresh - margin)
//! ```
//! Commits are thus phase-locked reliably 3 ms before display vertical blanking.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Time Units & Timestamp Domain:
//! - `callback_data` is a 32-bit unsigned integer representing monotonic milliseconds.
//! - Passed directly to `animator.Clock.advance(now_ms)`:
//!   - If `armed == false` (first wake from idle), returns `0.0` ms to establish a baseline.
//!   - If `armed == true`, returns `(now_ms -% last_ms)` clamped to `dt_max_ms` (`100` ms).
//! - All animation stepping math in `animator.Animator` is computed in floating-point milliseconds.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### C ABI Function Table: `CallbackListener`:
//! Sized for exactly 1 event (opcode 0):
//! - Offset 0..7: `done` function pointer
//!   (`*const fn (data, callback, callback_data) callconv(.c) void`).
//! - Total size: 8 bytes (on 64-bit platforms). Alignment: 8 bytes.
//! - Comptime assertion: `@typeInfo(CallbackListener).@"struct".fields.len == 1`.
//!
//! ### Protocol Wire Marshalling:
//! - Opcode: `wl_surface.frame` is request opcode 3 on the `wl_surface` interface.
//! - Invocation: `wl_proxy_marshal_flags(surface, 3, &wl_callback_interface, version, 0, null)`.
//!   Passing `null` as the variadic argument instructs `libwayland-client` to allocate a fresh
//!   `WlProxy` ID and return its pointer.
//! - Interface Descriptor: `wl_callback_interface` is an exported `WlInterface` symbol provided
//!   by `libwayland-client.so.0`.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Frame Callback Lifecycle Diagram:
//! ```text
//!   redraw set, frame_callback == null
//!                |
//!                v
//!   +----------------------------------+
//!   | Arm callback, then gpu.present() |
//!   | wl_surface.frame before commit   |
//!   +----------------------------------+
//!                |
//!                | callback in flight: subsequent wakes leave redraw set
//!                v
//!   +----------------------------------+
//!   |        frame_done_callback       |
//!   | - wl_proxy_destroy(proxy)        |
//!   | - frame_callback = null          |
//!   | - frame_time_ms = callback_data  |
//!   | - frame_done = true              |
//!   +----------------------------------+
//!                |
//!                | sync_clock steps animators; input queue already drained
//!                v
//!         [redraw still set?]
//!            /              \
//!         YES                NO
//!          |                  |
//!          v                  v
//!   deadline = next        poll(-1)
//!   projected vblank       sleep at 0.0% CPU
//!   minus 3 ms; ppoll      reset clock when
//!   until then, draw the   settled
//!   latest sample, arm
//!   and present
//! ```
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **Native Linux:** Uses `wl_surface.frame` and `wl_callback` via dynamic linking to
//!   `libwayland-client.so.0`.
//! - **Browser WebAssembly:** The role of `wl_surface.frame` is mirrored by HTML5's
//!   `requestAnimationFrame(callback)`, which similarly coordinates rendering with browser
//!   compositor display vsync and suspends when tabs are backgrounded or idle.
//!
//! ## 6. TigerStyle Invariants
//! - **Comptime Length Locks:** `comptime assert(@sizeOf(CallbackListener) == 8)` guarantees
//!   the C ABI table contains no extra or missing slots.
//! - **Zero Runtime Allocation:** The callback listener is a statically allocated const struct.
//! - **Leaf Handler Discipline:** The C callback `frame_done_callback` in `linux_window.zig`
//!   strictly records state (`frame_time_ms`, `frame_done = true`) and destroys the proxy. It
//!   never triggers GPU commands, layout calculations, or memory allocations from within the
//!   Wayland socket dispatch context.

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

/// Listener for `wl_callback` version 1. Exactly one event: `done` at opcode 0.
/// Memory layout: 8 bytes, alignment 8.
pub const CallbackListener = extern struct {
    done: *const fn (
        data: ?*anyopaque,
        callback: ?*WlCallback,
        callback_data: u32,
    ) callconv(.c) void,
};

/// `wl_surface.frame`. The compositor fires `done` after the next surface commit.
/// `callback_data` is a millisecond timestamp. The returned proxy is one-shot.
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
    assert(@typeInfo(CallbackListener).@"struct".fields.len == 1);
    assert(@sizeOf(CallbackListener) == 8);
}

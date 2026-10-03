//! Wayland `wp_presentation` (presentation-time) client binding.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! `wl_callback.done` indicates only that a committed surface buffer was accepted into a
//! compositor rendering cycle. It does not indicate when that buffer physically reached the
//! display scanout hardware, and when it is sent is a compositor policy, not a protocol
//! guarantee: some compositors send it after their render pass, Hyprland 0.56 sends it about
//! 0.35 ms after the pageflip, and the driver's own present path can hold it back (Mesa's FIFO
//! on `wp_fifo_v1` delayed every other `done` by a refresh). A client that schedules its next
//! commit strictly from `done` inherits whichever of those applies and spends its latch margin
//! on it.
//!
//! The `wp_presentation` extension solves this by providing explicit per-commit hardware timing
//! via `wp_presentation_feedback`. For each commit, the compositor emits exactly one completion
//! event:
//! - `presented`: The buffer was displayed on screen at an exact hardware vertical blanking
//!   timestamp, reporting the output refresh period and hardware synchronization flags.
//! - `discarded`: The buffer was superseded, occluded, or dropped before reaching the display.
//!
//! The `presented` timestamp corresponds to the hardware pageflip. When the compositor uses
//! `CLOCK_MONOTONIC`, this timestamp is directly comparable to `std.os.linux.clock_gettime`,
//! enabling the client to phase-lock its render submission directly to the upcoming display
//! vertical blank rather than reacting to variable compositor render completion.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//! The Wayland wire protocol defines only 32-bit integer primitives (`u`, `i`) and lacks native
//! 64-bit integer types. Consequently, the 64-bit seconds counter (`tv_sec`) and vertical refresh
//! sequence counter (`seq`) are transmitted as split 32-bit unsigned integers:
//! ```text
//! tv_sec      = (tv_sec_hi << 32) | tv_sec_lo            (seconds)
//! presented   = tv_sec * 1_000_000_000 + tv_nsec        (nanoseconds)
//! seq         = (seq_hi << 32) | seq_lo                 (vblank count, 0 if unsupported)
//! refresh     = nanoseconds between refreshes           (0 for variable refresh rate)
//! ```
//! The pure helper `presented_ns` performs this 64-bit assembly. The protocol guarantees that
//! `tv_nsec` is strictly within `0 <= tv_nsec < 1_000_000_000`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//! - `wp_presentation` interface (version 2):
//!   - Request 0: `destroy` (signature `""`) - Destroys the presentation global proxy.
//!   - Request 1: `feedback` (signature `"on"`) - Requests feedback for a `wl_surface`.
//!   - Event 0: `clock_id` (signature `"u"`) - Informs client of `clockid_t` (e.g. 1).
//! - `wp_presentation_feedback` interface (version 2):
//!   - Method count: 0 (no client-to-server requests).
//!   - Event 0: `sync_output` (signature `"o"`) - Output proxy (`wl_output`) of presentation.
//!   - Event 1: `presented` (signature `"uuuuuuu"`) - Timing parameters and flags.
//!   - Event 2: `discarded` (signature `""`) - Buffer dropped without presentation.
//! - Destructor Semantics: Both `presented` and `discarded` are protocol destructors. The server
//!   deletes its state immediately upon emission. The client MUST call `wl_proxy_destroy` from
//!   within the callback listener to release the client-side `WlProxy` tracking structure.
//! - C ABI Struct Layouts:
//!   - `PresentationListener`: 8 bytes, alignment 8 (single function pointer for `clock_id`).
//!   - `FeedbackListener`: 24 bytes, alignment 8 (three function pointers at offsets 0, 8, 16).
//! - Flags Bitmask (`wp_presentation_feedback.kind`):
//!   - `vsync = 0x1`: Synchronized with vertical blanking interval.
//!   - `hw_clock = 0x2`: Timestamp sampled directly by display hardware/kernel clock.
//!   - `hw_completion = 0x4`: Completion confirmed by hardware execution signal.
//!   - `zero_copy = 0x8`: Presentation occurred via direct zero-copy scanout.
//!   - Measured on Hyprland 0.56.2 / Mesa 26.2.2 (3840x2160@60 Hz): Observed `flags = 0x5`
//!     (`vsync | hw_completion`, without `hw_clock`), refresh reported `16666666 ns`, and
//!     `clock_id = CLOCK_MONOTONIC` (1).
//!
//! ## 4. State Machines & Data Flow
//! ```text
//!   commit N  --request feedback-->  wp_presentation_feedback (one-shot proxy)
//!                                         |
//!                       +-----------------+------------------+
//!                       v                                    v
//!             presented(t, refresh, seq, flags)           discarded
//!                       |                                    |
//!             store t, refresh to State                  no timestamps stored
//!                       |                                    |
//!                       +-------- wl_proxy_destroy ----------+
//! ```
//! Exactly two feedback proxies are active in steady state: the feedback for the frame currently
//! scanning out arrives after the subsequent commit has already been dispatched. The client bounds
//! active proxies via `feedback_in_flight_max = 4`. If the bound is reached, further feedback
//! requests are skipped to guarantee bounded memory even if the compositor stalls.
//!
//! ## 5. Cross-Platform Seams & FFI
//! Hand-written protocol interface tables match the `libwayland-client.so.0` C ABI without
//! generating code or linking external tools. Upstream interfaces `wl_surface_interface` and
//! `wl_output_interface` are imported from `xdg_shell.zig`. WebAssembly browsers do not offer
//! equivalent hardware pageflip feedback; the browser harness relies on `requestAnimationFrame`.
//!
//! ## 6. TigerStyle Invariants
//! - Strict comptime assertions locking listener struct sizes and alignment.
//! - Zero runtime allocations: proxies are managed by `libwayland-client` and destroyed
//!   deterministically upon receiving terminal destructor events.
//! - Bounded proxy count (`feedback_in_flight_max = 4`).
//! - Leaf listeners perform minimal data recording into `State`, keeping event handlers pure.

const std = @import("std");
const assert = std.debug.assert;
const xdg = @import("xdg_shell.zig");

/// Opaque proxy handle representing the global `wp_presentation` interface.
pub const WpPresentation = opaque {};

/// Opaque proxy handle representing a one-shot `wp_presentation_feedback` request.
///
/// Created via `request_feedback`. Must be destroyed using `destroy_feedback` from within
/// either the `presented` or `discarded` event callback.
pub const WpPresentationFeedback = opaque {};

/// Highest `wp_presentation` interface version supported by these protocol definitions.
pub const presentation_version: u32 = 2;

/// POSIX `clockid_t` for `CLOCK_MONOTONIC` (value 1 on Linux).
/// Feedback events stamped with any other clock ID cannot be compared to system time and
/// must be ignored by the pacing loop.
pub const clock_monotonic: u32 = 1;

/// Presentation was synchronized with the display vertical blanking interval.
pub const flag_vsync: u32 = 0x1;

/// Timestamp was taken directly by hardware or display engine driver clock.
pub const flag_hw_clock: u32 = 0x2;

/// Frame presentation completed with hardware execution confirmation.
pub const flag_hw_completion: u32 = 0x4;

/// Frame was displayed using zero-copy direct scanout without composite copying.
pub const flag_zero_copy: u32 = 0x8;

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
extern fn wl_proxy_get_version(proxy: *WlProxy) u32;
extern fn wl_proxy_add_listener(
    proxy: *WlProxy,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) i32;
extern fn wl_proxy_destroy(proxy: *WlProxy) void;

const feedback_types = [_]?*const WlInterface{
    &xdg.wl_surface_interface,
    &wp_presentation_feedback_interface,
};
const sync_output_types = [_]?*const WlInterface{&xdg.wl_output_interface};

const presentation_requests = [_]WlMessage{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "feedback", .signature = "on", .types = &feedback_types },
};
const presentation_events = [_]WlMessage{
    .{ .name = "clock_id", .signature = "u", .types = null },
};

/// Wire interface descriptor for the global `wp_presentation` singleton.
pub const wp_presentation_interface: WlInterface = .{
    .name = "wp_presentation",
    .version = presentation_version,
    .method_count = 2,
    .methods = &presentation_requests,
    .event_count = 1,
    .events = &presentation_events,
};

const feedback_events = [_]WlMessage{
    .{ .name = "sync_output", .signature = "o", .types = &sync_output_types },
    .{ .name = "presented", .signature = "uuuuuuu", .types = null },
    .{ .name = "discarded", .signature = "", .types = null },
};

/// Wire interface descriptor for one-shot `wp_presentation_feedback` objects.
pub const wp_presentation_feedback_interface: WlInterface = .{
    .name = "wp_presentation_feedback",
    .version = presentation_version,
    .method_count = 0,
    .methods = null,
    .event_count = 3,
    .events = &feedback_events,
};

/// C ABI function table for `wp_presentation` events.
///
/// Contains one callback (`clock_id` at opcode 0):
/// - Offset 0..7: `clock_id` function pointer (8 bytes).
/// - Size: 8 bytes. Alignment: 8 bytes.
pub const PresentationListener = extern struct {
    clock_id: *const fn (
        data: ?*anyopaque,
        presentation: ?*WpPresentation,
        clock_id: u32,
    ) callconv(.c) void,
};

/// C ABI function table for `wp_presentation_feedback` events.
///
/// Contains three event callbacks:
/// - Offset 0..7: `sync_output` function pointer (opcode 0, 8 bytes).
/// - Offset 8..15: `presented` function pointer (opcode 1, 8 bytes).
/// - Offset 16..23: `discarded` function pointer (opcode 2, 8 bytes).
/// - Size: 24 bytes. Alignment: 8 bytes.
pub const FeedbackListener = extern struct {
    sync_output: *const fn (
        data: ?*anyopaque,
        feedback: ?*WpPresentationFeedback,
        output: ?*anyopaque,
    ) callconv(.c) void,
    presented: *const fn (
        data: ?*anyopaque,
        feedback: ?*WpPresentationFeedback,
        tv_sec_hi: u32,
        tv_sec_lo: u32,
        tv_nsec: u32,
        refresh: u32,
        seq_hi: u32,
        seq_lo: u32,
        flags: u32,
    ) callconv(.c) void,
    discarded: *const fn (
        data: ?*anyopaque,
        feedback: ?*WpPresentationFeedback,
    ) callconv(.c) void,
};

/// Installs the `clock_id` event listener on the bound `wp_presentation` global proxy.
///
/// Preconditions: `presentation` must be non-null. `listener` must remain valid for the
/// lifetime of the proxy.
pub fn add_presentation_listener(
    presentation: *WpPresentation,
    listener: *const PresentationListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(presentation), listener, data);
    assert(rc == 0);
    assert(@intFromPtr(presentation) != 0);
}

/// Issues request opcode 1 (`feedback`) on `wp_presentation` for the target `surface`.
///
/// Allocates and returns a one-shot `WpPresentationFeedback` proxy. The compositor will
/// report the presentation outcome of the surface's next `wl_surface.commit`.
///
/// Preconditions: `presentation` and `surface` must be valid, non-null proxy pointers.
/// Interface version must satisfy `1 <= version <= presentation_version`.
pub fn request_feedback(
    presentation: *WpPresentation,
    surface: *xdg.WlSurface,
) *WpPresentationFeedback {
    const proxy: *WlProxy = @ptrCast(presentation);
    const version = wl_proxy_get_version(proxy);
    assert(version >= 1);
    assert(version <= presentation_version);
    const result = wl_proxy_marshal_flags(
        proxy,
        1,
        &wp_presentation_feedback_interface,
        version,
        0,
        surface,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Registers the three-callback listener on a newly created `WpPresentationFeedback` proxy.
///
/// Preconditions: `feedback` must be non-null. `listener` must remain valid until the
/// proxy is destroyed.
pub fn add_feedback_listener(
    feedback: *WpPresentationFeedback,
    listener: *const FeedbackListener,
    data: *anyopaque,
) void {
    const rc = wl_proxy_add_listener(@ptrCast(feedback), listener, data);
    assert(rc == 0);
    assert(@intFromPtr(feedback) != 0);
}

/// Destroys a one-shot `WpPresentationFeedback` proxy via `wl_proxy_destroy`.
///
/// Must be called from within either `presented` or `discarded` event handlers.
/// Both events are server-side destructors; destroying the client-side proxy releases its
/// local tracking ID without sending further wire messages.
pub fn destroy_feedback(feedback: *WpPresentationFeedback) void {
    const proxy: *WlProxy = @ptrCast(feedback);
    assert(@intFromPtr(proxy) != 0);
    wl_proxy_destroy(proxy);
    assert(@intFromPtr(feedback) != 0);
}

/// Assembles split 64-bit seconds and 32-bit nanoseconds from `presented` into total nanoseconds.
///
/// Preconditions: `tv_nsec` must be strictly less than 1_000_000_000 (asserted).
///
/// Coordinate Frame & Units: Monotonic nanoseconds (`u64`) on the compositor presentation clock
/// (`CLOCK_MONOTONIC`). Directly comparable to `std.os.linux.clock_gettime(.MONOTONIC, ...)`.
/// Verified by test case "presented_ns assembles the split timestamp".
pub fn presented_ns(tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) u64 {
    assert(tv_nsec < 1_000_000_000);
    const seconds: u64 = (@as(u64, tv_sec_hi) << 32) | @as(u64, tv_sec_lo);
    const total: u64 = seconds * 1_000_000_000 + @as(u64, tv_nsec);
    assert(total >= @as(u64, tv_nsec));
    assert(total % 1_000_000_000 == tv_nsec);
    return total;
}

comptime {
    assert(@typeInfo(PresentationListener).@"struct".fields.len == 1);
    assert(@sizeOf(PresentationListener) == 8);
    assert(@typeInfo(FeedbackListener).@"struct".fields.len == 3);
    assert(@sizeOf(FeedbackListener) == 24);
    assert(clock_monotonic == 1);
    assert(flag_vsync | flag_hw_clock | flag_hw_completion | flag_zero_copy == 0xF);
}

// Verifies that presented_ns correctly shifts tv_sec_hi across the 32-bit boundary, combines
// tv_sec_lo, multiplies by 1e9, and adds tv_nsec without integer overflow or precision loss.
test "presented_ns assembles the split timestamp" {
    try std.testing.expectEqual(@as(u64, 1_000_000_005), presented_ns(0, 1, 5));
    const high = presented_ns(1, 0, 0);
    try std.testing.expectEqual(@as(u64, 4_294_967_296) * 1_000_000_000, high);
}

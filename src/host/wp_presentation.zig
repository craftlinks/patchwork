//! Wayland `wp_presentation` (presentation-time protocol) client binding.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Presentation Feedback Instead of `wl_callback.done`
//! `wl_callback.done` says the commit was taken into a compositor presentation cycle, not
//! when it reached scanout, and when it is sent is compositor and driver policy. It can
//! carry the compositor's render time, and a driver's present path can hold it back: with
//! Mesa 26.2.2 in FIFO mode (`wp_fifo_v1`), each present issues a barrier-held second commit
//! that carries the client's `wl_surface.frame`, which delays every other `done` by a
//! refresh period. A client that schedules from `done` inherits that jitter and spends its
//! latch margin on it. The workaround is to anchor on `wp_presentation_feedback.presented`
//! and keep `done` as the fallback; it can be dropped if `done` becomes a reliable scanout
//! signal across the compositors and drivers in use.
//!
//! For each requested feedback the compositor sends exactly one terminal event:
//! `presented` (hardware pageflip time, refresh period, flags) or `discarded` (the content
//! never reached the screen). When `wp_presentation.clock_id` names `CLOCK_MONOTONIC`
//! (`clock_monotonic`), the timestamp is comparable to `clock_gettime(.MONOTONIC)` and the
//! host can project the next vblank from it. Any other clock disables the anchor.
//!
//! ## 2. Timestamp Assembly
//! The wire format has no 64-bit integer, so `presented` splits the seconds and the vblank
//! sequence counter into high and low 32-bit words:
//! ```text
//! tv_sec    = (tv_sec_hi << 32) | tv_sec_lo
//! presented = tv_sec * 1_000_000_000 + tv_nsec       (nanoseconds, tv_nsec < 1_000_000_000)
//! refresh   = nanoseconds per output refresh, 0 when the output has no fixed rate
//! ```
//! `presented_ns` performs the assembly; the test "presented_ns assembles the split
//! timestamp" and the carry test next to it lock it.
//!
//! ## 3. Protocol Rules and C ABI
//! - Both interfaces are hand-written tables (`wp_presentation_interface`,
//!   `wp_presentation_feedback_interface`) because the protocol is an extension that
//!   `libwayland-client` does not export. `assert_interface_tables`, evaluated at compile
//!   time by `linux_window.zig`, checks their counts and versions against the tables.
//! - `presented` and `discarded` are both terminal. The server forgets the object after
//!   either, and the client MUST call `destroy_feedback` from inside that listener to
//!   release the client-side proxy.
//! - `flag_*` constants name the `wp_presentation_feedback.kind` bits; the `comptime` block
//!   pins them to the protocol values.
//! - Listener structs hold one function pointer per event in opcode order. Slot counts and
//!   sizes are enforced by `comptime` asserts.
//!
//! ## 4. State Machine
//! ```text
//!   commit N --request_feedback--> one-shot feedback proxy
//!                                      |
//!                    +-----------------+-----------------+
//!                    v                                   v
//!             presented(t, refresh, ...)             discarded
//!             store t and refresh                    store nothing
//!                    +--------- destroy_feedback ---------+
//! ```
//! Feedback for the frame on screen arrives after the next commit was already dispatched, so
//! more than one proxy is normally live. The host bounds them with
//! `feedback_in_flight_max` in `linux_window.zig` and skips a request at the bound, so a
//! stalled compositor cannot grow memory.
//!
//! ## 5. Cross-Platform Seam
//! Browsers expose no pageflip feedback; the web host paces with `requestAnimationFrame`.
//!
//! ## 6. TigerStyle Invariants
//! - No runtime allocation; proxies are libwayland-owned and destroyed on the terminal event.
//! - The extern libwayland functions are referenced only by runtime helpers, so the interface
//!   tables, asserts, and `presented_ns` are testable without linking `wayland-client`.

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

/// Highest `wp_presentation` version these interface tables describe. The host binds
/// `min(advertised, presentation_version)`.
pub const presentation_version: u32 = 2;

/// Linux `clockid_t` for `CLOCK_MONOTONIC`. Feedback stamped with any other clock cannot be
/// compared to `clock_gettime(.MONOTONIC)` and must be ignored by the pacing loop.
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

/// C ABI listener for `wp_presentation` events: one slot, `clock_id` (opcode 0).
/// Size is enforced by the `comptime` block.
pub const PresentationListener = extern struct {
    clock_id: *const fn (
        data: ?*anyopaque,
        presentation: ?*WpPresentation,
        clock_id: u32,
    ) callconv(.c) void,
};

/// C ABI listener for `wp_presentation_feedback` events, slots in opcode order:
/// `sync_output`, `presented`, `discarded`. Size is enforced by the `comptime` block.
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

/// Issues `wp_presentation.feedback` (request opcode 1) for `surface`.
///
/// Returns a one-shot `WpPresentationFeedback` proxy. The compositor reports the outcome of
/// the surface's next `wl_surface.commit`, so call this before that commit.
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

/// Registers the listener on a newly created `WpPresentationFeedback` proxy.
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
/// Must be called from within the `presented` or `discarded` handler. Both are terminal on
/// the server, so destroying the client proxy sends no further wire message.
pub fn destroy_feedback(feedback: *WpPresentationFeedback) void {
    const proxy: *WlProxy = @ptrCast(feedback);
    assert(@intFromPtr(proxy) != 0);
    wl_proxy_destroy(proxy);
    assert(@intFromPtr(feedback) != 0);
}

/// Assembles the split `presented` timestamp into total nanoseconds.
///
/// Preconditions: `tv_nsec` must be strictly less than 1_000_000_000 (asserted).
///
/// Units: nanoseconds on the compositor presentation clock. Only comparable to
/// `clock_gettime(.MONOTONIC)` when `clock_monotonic` was reported. The seconds word
/// must be small enough that the product fits `u64`, which any real clock satisfies.
/// Locked by the tests "presented_ns assembles the split timestamp" and
/// "presented_ns carries the low seconds word without sign extension".
pub fn presented_ns(tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) u64 {
    assert(tv_nsec < 1_000_000_000);
    const seconds: u64 = (@as(u64, tv_sec_hi) << 32) | @as(u64, tv_sec_lo);
    const total: u64 = seconds * 1_000_000_000 + @as(u64, tv_nsec);
    assert(total >= @as(u64, tv_nsec));
    assert(total % 1_000_000_000 == tv_nsec);
    return total;
}

/// Compile-time consistency checks between the hand-written interface tables and their
/// declared counts and version. They live in a function, called from a `comptime` block in
/// `linux_window.zig`, because reading the interface structs makes the compiler reference the
/// extern libwayland interface symbols, and unit-test builds link no `wayland-client`.
pub fn assert_interface_tables() void {
    comptime {
        // libwayland trusts the declared counts, so a mismatch reads past the message array.
        assert(wp_presentation_interface.method_count == presentation_requests.len);
        assert(wp_presentation_interface.event_count == presentation_events.len);
        assert(wp_presentation_feedback_interface.event_count == feedback_events.len);
        assert(wp_presentation_feedback_interface.method_count == 0);
        assert(wp_presentation_interface.version == presentation_version);
        assert(wp_presentation_feedback_interface.version == presentation_version);
        // Listener slots must equal the event counts of the interface they serve.
        assert(@typeInfo(PresentationListener).@"struct".fields.len == presentation_events.len);
        assert(@typeInfo(FeedbackListener).@"struct".fields.len == feedback_events.len);
    }
}

comptime {
    // `wp_presentation_feedback.kind` bit values as defined by the protocol.
    assert(flag_vsync == 0x1);
    assert(flag_hw_clock == 0x2);
    assert(flag_hw_completion == 0x4);
    assert(flag_zero_copy == 0x8);
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

// Locks that the low seconds word is zero-extended: a sign-extending shift would corrupt the
// high bits of the result. The values are the largest low word and the largest legal tv_nsec.
test "presented_ns carries the low seconds word without sign extension" {
    // 4_294_967_295 s * 1e9 ns/s + 999_999_999 ns.
    const expected: u64 = 4_294_967_295_999_999_999;
    try std.testing.expectEqual(expected, presented_ns(0, 0xFFFF_FFFF, 999_999_999));
}

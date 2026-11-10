//! Linux Wayland window host: event loop, frame pacing, and GPU surface hookup.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Blocking Dual-Source Loop
//! The compositor, not the client, owns the display, sizes the window through asynchronous
//! configure events, and receives complete pixel buffers; Wayland has no server-side drawing.
//! A client that spins or polls on an interval wastes power while the UI is static, so the
//! loop sleeps in `ppoll` until something can change the picture:
//! 1. `wl_display_prepare_read` claims the socket read. A non-zero return means events are
//!    already queued: dispatch them, drain the timer so a busy socket cannot starve app
//!    timers, and skip the sleep.
//! 2. `wl_display_flush` pushes requests out, then `ppoll` waits on a fixed set of seven
//!    descriptors (`Slot`): the Wayland socket, the optional app timer, the key repeat timer,
//!    the clipboard's send and receive pipes, the producer's wake (section 5c), and a file drop's
//!    URI list pipe (section 5d). A negative descriptor is ignored by `poll`, so an app without
//!    a timer passes `no_timer_fd` and never wakes on ticks, the repeat timer is disarmed
//!    unless a repeating key is held, an idle clipboard has no pipes, an app without a
//!    producer has no wake, and no drop has no list.
//! 3. The timeout is null (sleep until the compositor writes) unless a commit is latched in
//!    `State.present_at_ns`, in which case it is the time remaining until that deadline, or a
//!    file transfer runs (section 5d), in which case it is zero.
//! 4. Cancel-read rule: every successful `prepare_read` must end in `wl_display_read_events`
//!    or `wl_display_cancel_read`. A timer-only wake or timeout cancels; only a readable
//!    socket reads. Skipping the cancel leaves libwayland's read lock held.
//! 5. Timer expirations collapse: `drain_timer` reads one expiration count and calls
//!    `app.timer` once at the current monotonic time, however many periods were missed.
//! 6. The app timer is created disarmed when the app declares a period, and `sync_timer`
//!    arms or disarms it before every sleep to match `cx.timer_on` (`ui/cx.zig`, section 9),
//!    so an app that stopped its timer (a paused transport) sleeps like one without a timer.
//!
//! Hover animators do not chain wakes: a present is followed by one frame callback, and a
//! `done` that finds nothing dirty arms nothing, which returns the loop to a null timeout.
//!
//! ## 2. Coordinate Spaces
//! - UI logical pixels: origin at the top-left, +X right, +Y down. Pointer coordinates and
//!   layout use this frame. Wayland surface coordinates are independent of the buffer scale
//!   and of the viewport, so no scale conversion is applied to input.
//! - Physical device pixels: `width_px = round(width_logical * scale_120 / 120)`, and likewise
//!   for height (`frame.pixel_size`). Only the swapchain and the present header use them.
//! - Scale source, chosen once in `create_toplevel` and logged: when the compositor offers
//!   both `wp_fractional_scale_manager_v1` and `wp_viewporter` the host is in fractional
//!   mode: `preferred_scale` (1/120 units) drives `frame.apply_scale`, the buffer scale stays
//!   1, and `wp_viewport.set_destination(logical size)` is sent whenever the logical size
//!   changed (`apply_surface_scale`, before each commit). Otherwise the integer
//!   `wl_surface.preferred_buffer_scale` arrives as `factor * 120` and is set with
//!   `wl_surface.set_buffer_scale`. See `wp_fractional_scale.zig`.
//! - `wl_pointer` coordinates arrive as signed 24.8 fixed point and are converted by
//!   `input.fixed_to_logical` (test "fixed_to_logical converts 24.8" in `input.zig`).
//!
//! ## 3. Protocol Limits and Layout
//! - Bounds are the named constants `global_cap`, `compositor_version_max`,
//!   `wl_seat.seat_version_max`, `wp_presentation.presentation_version` (the host binds
//!   `min(advertised, version)`), and `feedback_in_flight_max`.
//! - `present_margin_ns` is how far before the projected vblank a commit is dispatched. It
//!   must exceed the compositor's latch lead (the point before vblank after which new
//!   content misses that vblank), which is compositor-specific, so the constant is tuned
//!   per target and guarded by the `comptime` block below.
//! - Listener tables are `extern struct`s with one slot per event in opcode order. This file
//!   asserts the layout of `RegistryListener` and `SurfaceListener`; the seat, callback and
//!   presentation listeners are asserted in their own files.
//!
//! ## 4. Loop State Machine
//! Each iteration runs, in order: `ack_if_needed`, `sync_input`, `sync_producer`, `bench_step`,
//! `sync_clock`, `present_if_dirty`, `sync_timer`, `wait_for_events`.
//! Callbacks only write `State`; all app calls happen in this order on the main thread. A bench
//! frame's work runs in the order `host/offscreen.zig` states (section 2); this host adds the
//! pacing and the presentation.
//! - Draw rule (`prepare_app`): `ui.draw_frame` runs `App.draw` when the UI context is dirty
//!   or when the glyph cache owes a draw (`Cache.owes_draw`: the scale moved since the last
//!   draw, or glyphs were skipped for the per-frame budget or a full atlas). After the
//!   commit, a cache that still owes a draw, or a context dirtied again by the hover that
//!   the draw re-resolved, requests another redraw, which the next `done` schedules.
//! - `ack_if_needed`: answers a pending `xdg_surface.configure` with `ack_configure` and
//!   applies the pending size through `frame.apply_configure`. A configure carries no size
//!   guarantee, so a zero dimension is replaced by `Frame`.
//! - `sync_input`: drains `State.queue` once per wake, bounded by `input.queue_cap`, through
//!   `ui.dispatch`. Motion is coalesced by the queue, and a press and release stay separate
//!   events. After each dispatch the clipboard requests are served (section 5a); after the
//!   queue, a finished paste is dispatched and the cursor is sent.
//! - `sync_clock`: runs only after a `wl_callback.done`. It steps animators from the callback
//!   timestamp through `ui.animate`, advances `animator.Time` while the renderer reports an
//!   animated instance on screen (`draw/renderer.zig`, section 4b), requests a redraw while a
//!   widget keeps animating or the renderer is animating, resets the clock when both settled,
//!   and calls `schedule_present`. An animation-only frame draws nothing (the context is
//!   clean) and records the time write and the animated tiles.
//! - `present_if_dirty`: presents only when a redraw is owed, the surface is configured, no
//!   frame callback is in flight, and the latched deadline has passed. Otherwise it leaves
//!   `redraw` set so pointer motion that arrives during the wait is drawn by the commit.
//!   The draw (layout included) runs only on that commit. Each commit requests
//!   `wl_surface.frame` and (bounded) `wp_presentation.feedback` before `gpu.submit`, because
//!   both requests attach to the next `wl_surface.commit`.
//! - `schedule_present`: the deadline is `frame.present_deadline` applied to an anchor, the
//!   last `presented` pageflip while `frame.anchor_is_fresh`, else the receipt time of `done`.
//!   Anchoring on the pageflip keeps compositor and driver delay between pageflip and `done`
//!   out of the deadline (root cause in `wp_presentation.zig`). The refresh period comes
//!   from `presented` when it reports one, else from callback gaps via `frame.refresh_after`.
//!   Tests: the `present_deadline` and `anchor_is_fresh` tests in `frame.zig`.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - `libwayland-client.so.0` and `libxkbcommon.so.0` are linked dynamically. C callbacks
//!   recover `*State` from the listener user-data pointer and never lay out, draw, or step
//!   animators.
//! - `gpu.create` receives the `wl_display` and `wl_surface` pointers to make the WebGPU
//!   surface.
//! - Two clients share one socket: Mesa's Wayland WSI binds its own `wp_presentation`,
//!   `wp_fifo_v1` and `linux-drm-syncobj` objects on a private event queue through a wrapped
//!   display, and its requests interleave with ours. Under FIFO present mode the driver's
//!   barrier-held second commit carries our `wl_surface.frame`, so `done` timing depends on
//!   the driver's present mode (Mesa 26.2.2).
//! - Presentation timestamps are compared to `CLOCK_MONOTONIC` only after
//!   `wp_presentation.clock_id` has named it. Any other clock disables the vblank anchor and
//!   the scheduler falls back to `done`.
//! - Both `wl_pointer.axis` axes become `Event.wheel` (`dy` vertical, `dx` horizontal); a
//!   positive `dy` is added to the scroll offset by the widgets. The browser host drives app
//!   timers with `setInterval` instead of a `timerfd`, set and cleared to follow
//!   `cx.timer_on`, and arms nothing when the period is zero.
//!
//! ## 5a. Keyboard, Repeat, Cursor, and Clipboard
//! - `wl_keyboard` events are translated in their callbacks through libxkbcommon
//!   (`xkb.zig`), because the translation depends on the modifier state at that moment, and
//!   queued as `key_down` (with the typed text) and `key_up`. Keyboard `enter` and `leave`
//!   queue `window_focus`.
//! - Key repeat: `input.Repeat` decides, `apply_arming` sets the second timerfd (created once
//!   in `run`, disarmed at rest). Expirations collapse to one repeat per wake, like the app
//!   timer: `drain_repeat` queues one `key_down` with `repeat` set and fresh text.
//! - Cursor: after input is dispatched and after each present, `apply_cursor` sends the UI
//!   context's `cursor()` through `wp_cursor_shape_v1` when it changed or a pointer `enter`
//!   made it undefined (`wp_cursor_shape.zig`).
//! - Clipboard: after each dispatch the host turns `cx.copy` into a selection (`clipboard.zig`)
//!   with the serial of the latest key or button, and `cx.request_paste` into a receive (or a
//!   paste from `cx.copied()` while we own the selection). A finished receive is dispatched
//!   directly as one `paste` event, never queued. `SIGPIPE` is ignored from `run` on.
//!
//! ## 5b. Bench Mode
//! `run` takes `bench.Options` from the command line (`native_main.zig`). With `--bench
//! <scenario>` the host replays the app's scenario (`bench.zig`, section 2): `bench_step` runs
//! one step whenever the loop is idle (the last frame presented, its callback arrived, nothing
//! owed), before `sync_clock`, so the forced frame is scheduled like real input. Around the
//! existing seams it times `prepare_app`, `finalize` (run once early, since it is idempotent),
//! `Renderer.frame`, and `gpu.submit`, reads the pass time from `gpu.native`, and counts shaded
//! area per draw type. After the last measured frame the loop ends and `bench_finish` writes
//! the frame dump and prints the report. Without `--bench` only two clock reads per present
//! remain.
//!
//! ## 5c. A Producer
//! An app that declares a producer (`app.zig`, section 4e) gets an `eventfd` in `Slot.wake`,
//! created right after `App.init` and attached to the app's own `Wake` before `args`, so a
//! producer that `args` starts can notify at once. An app without one has no descriptor there.
//! - `sync_producer`, every wake: calls `App.drain` once, then owes a redraw if the app is dirty.
//!   While frames are presented it runs once a frame.
//! - Arming (`arm_producer`, before `prepare_read`): only while no frame callback is in flight
//!   and no commit is latched; a callback or a deadline wakes the loop anyway and the next
//!   iteration drains. So while frames flow the producer makes no syscall, and data drives at
//!   most one present per display frame. The app's `Wake` is armed over `App.pending`; a pending
//!   item skips the sleep. Every wait disarms on its way out, and a readable wake is read to
//!   clear it.
//! - Bench mode starts no producer (`args` is not called): each frame it calls `App.produce`
//!   with `bench.producer_frames_at` and then drains, so dumps are deterministic.
//! - The exit line reads `wake: N notified, N drains`.
//!
//! ## 5d. File Drops
//! The data device's drag events reach `clipboard.dnd` (`dnd.zig`), which queues `drop_over`
//! and `drop_leave` and receives the drop's URI list through `Slot.drop_list`. After each
//! dispatch the host tells the compositor whether a drop target is under the drag
//! (`dnd.sync_accept(cx.drop_wanted())`), starts a transfer the app accepted
//! (`cx.take_files_accept`), and dispatches the `cancelled` chunks of a `cx.cancel_files`
//! directly, in a bounded loop. `sync_input` then dispatches a finished list as one `drop`
//! (cancelling a transfer still running first) and reads at most `drop.chunks_per_wake`
//! chunks, each dispatched as a `file` event before the next read. A regular file is always
//! ready, so while the transfer runs `ppoll` does not sleep (a zero timeout) and the loop
//! keeps reading between frames; once it ends the loop sleeps as before. No drag, no wake.
//!
//! ## 5e. Window Chrome
//! - Decorations: with `config.decorations = .server` (or `--decorations server`) and a bound
//!   `zxdg_decoration_manager_v1`, `create_toplevel` asks for `server_side` before the first
//!   commit; the compositor's `configure(mode)` is what the app is told. `.client`, or no
//!   manager, creates no decoration object, and the app draws its own frame. The startup log
//!   names what was asked and what was answered (`xdg_decoration.zig`).
//! - State: `xdg_wm_base` is bound at `min(advertised, 5)`. `toplevel_configure`, the
//!   capabilities, and the decoration's mode write `window_pending`; `ack_if_needed` queues one
//!   `window_state` event when it differs from what the app last saw, so `sync_input` in the
//!   same iteration dispatches it before the draw.
//! - Requests: after each dispatch, `take_window_request` (`ui/cx.zig`, section 5a) becomes
//!   `xdg_toplevel.move`, `resize`, or `show_window_menu` with the press's serial
//!   (`input.Button.serial`, copied in `pointer_button`), `set_minimized`, `set_maximized` or
//!   `unset_maximized` by the last state, or the end of the loop for `close`. A bench run
//!   leaves them to `bench.serve_window`, so it never moves or closes its window.
//! - Close: `xdg_toplevel.close` queues `close_requested` instead of ending the loop; the
//!   context turns it into a `close` request unless the app keeps the window open.
//!
//! ## 6. TigerStyle Invariants
//! - `State` lives on the stack of `run`; the app, the draw context, and the renderer are
//!   static in `Host(App)`, because their sizes follow the app (an editor holds hundreds of
//!   KiB) and `App.config.draw`. The loop allocates nothing.
//! - Every loop is bounded: input drain by `input.queue_cap`, `EINTR` retry by a fixed guard.
//! - Wayland callbacks are leaf writers; all app and GPU work happens in the loop body.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const textures = @import("../draw/textures.zig");
const app_contract = @import("../app.zig");
const commands = @import("../gpu/commands.zig");
const frame = @import("../frame.zig");
const gpu = @import("../gpu.zig");
const input = @import("../input.zig");
const renderer = @import("../draw/renderer.zig");
const font_data = @import("../text.zig").font_data;
const ui = @import("../ui.zig");
const wl_callback = @import("wl_callback.zig");
const wl_seat = @import("wl_seat.zig");
const wp_fractional_scale = @import("wp_fractional_scale.zig");
const wp_presentation = @import("wp_presentation.zig");
const xdg = @import("xdg_shell.zig");
const xdg_decoration = @import("xdg_decoration.zig");
const xkb = @import("xkb.zig");
const wp_cursor_shape = @import("wp_cursor_shape.zig");
const wl_data_device = @import("wl_data_device.zig");
const clipboard_module = @import("clipboard.zig");
const drop = @import("../drop.zig");
const bench = @import("../bench.zig");
const builtin = @import("builtin");

/// First refresh-period guess, re-exported from `frame` for `main`.
pub const refresh_ns_initial: u64 = frame.refresh_ns_initial;
/// Lead time before the projected vblank at which a commit is dispatched. It must exceed the
/// compositor's latch lead so the commit lands in that vblank, while staying early enough in
/// the frame to include late pointer motion. The `ppoll` timeout is nanosecond-resolution
/// because a millisecond timeout is too coarse to hit the latch.
const present_margin_ns: u64 = 3_000_000;

/// Maximum concurrent `wp_presentation_feedback` proxies. The feedback for the frame on screen
/// arrives after the next commit was dispatched, so at least two must be allowed (asserted
/// below). At the bound, further requests are skipped so a stalled compositor cannot grow
/// memory.
const feedback_in_flight_max: u32 = 4;

comptime {
    assert(refresh_ns_initial > present_margin_ns);
    assert(present_margin_ns == 3_000_000);
    assert(feedback_in_flight_max >= 2);
}

/// Maximum number of advertised compositor globals to scan during registry roundtrip.
/// Bounded to satisfy TigerStyle limits.
const global_cap: u32 = 256;

/// Pinned maximum version of `wl_compositor` supported by our bindings.
const compositor_version_max: u32 = 6;

const Display = opaque {};
const Registry = opaque {};
const Compositor = opaque {};
const WlProxy = xdg.WlProxy;
const WlSurface = xdg.WlSurface;
const WlInterface = xdg.WlInterface;

/// Global application and windowing state for Linux Wayland execution.
pub const State = struct {
    frame: frame.Frame,
    display: *Display,
    compositor: ?*Compositor,
    xdg_base: ?*xdg.XdgWmBase,
    surface: ?*WlSurface,
    xdg_surface: ?*xdg.XdgSurface,
    toplevel: ?*xdg.XdgToplevel,
    gpu: gpu.Gpu,
    /// The stream the renderer records into and `gpu.submit` replays, reused every frame.
    commands: commands.CommandBuffer,
    /// Host timestamps from `wl_callback.done`. Reset when no animator is live.
    clock: animator.Clock,
    /// Animation time for animated draw types; advanced while the renderer is animating.
    time: animator.Time,
    /// Pointer events queued by callbacks and drained once per wake.
    queue: input.EventQueue,
    /// Last surface position. Button events carry no coordinates.
    last_x: f32,
    last_y: f32,
    /// In-flight `wl_surface.frame` proxy. Null when no commit is waiting on `done`.
    frame_callback: ?*wl_callback.WlCallback,
    /// Set by the `done` listener. `sync_clock` consumes it.
    frame_done: bool,
    frame_time_ms: u32,
    /// Monotonic nanoseconds when the coalesced commit should run. 0 means not waiting.
    present_at_ns: u64,
    /// Refresh period in use, in nanoseconds. From `wp_presentation` when it reports one,
    /// otherwise estimated from frame-callback gaps starting at `refresh_ns_initial`.
    refresh_ns: u64,
    /// Monotonic nanoseconds of the previous `done`. 0 before the first callback.
    last_callback_ns: u64,
    /// Bound `wp_presentation` global proxy. Null when the compositor does not advertise the
    /// protocol; the scheduler then falls back to anchoring commit deadlines on `done` receipts.
    presentation: ?*wp_presentation.WpPresentation,
    /// Clock identifier reported by `wp_presentation.clock_id` (opcode 0). Value 0 until the
    /// event is received. Timestamps are accepted only when
    /// `presentation_clock == clock_monotonic`.
    presentation_clock: u32,
    /// Hardware vertical blanking / pageflip timestamp in nanoseconds on `CLOCK_MONOTONIC`
    /// from the most recent `presented` event. Value 0 before the first valid presentation.
    /// The commit deadline in `schedule_present` is projected from this anchor.
    vblank_ns: u64,
    /// Fixed output refresh period in nanoseconds reported by `presented`. Value 0 if the
    /// output has no fixed rate (e.g. VRR). When valid, overrides heuristic callback gap tracking.
    vblank_refresh_ns: u64,
    /// Number of `WpPresentationFeedback` proxies awaiting a terminal event. Never exceeds
    /// `feedback_in_flight_max`.
    feedback_in_flight: u32,
    /// Bound Wayland seat proxy (`wl_seat`, version `min(advertised, 8)`).
    seat: ?*wl_seat.WlSeat,
    /// The seat's pointer and keyboard proxies, while the seat has them.
    pointer_proxy: ?*wl_seat.WlPointer,
    keyboard_proxy: ?*wl_seat.WlKeyboard,
    touch_proxy: ?*wl_seat.WlTouch,
    /// The keymap, modifier state, and compose state (`xkb.zig`).
    keyboard: xkb.Keyboard,
    /// The repeating key and the repeat timerfd it arms (section 5a).
    repeat: input.Repeat,
    repeat_fd: i32,
    /// Serial of the latest key, button, or keyboard enter: `set_selection` needs one.
    input_serial: u32,
    /// `wp_cursor_shape_manager_v1` and the pointer's shape device; null without the protocol.
    cursor_manager: ?*wp_cursor_shape.Manager,
    cursor_device: ?*wp_cursor_shape.Device,
    /// Serial of the latest `wl_pointer.enter`, and the shape sent since; null owes one.
    enter_serial: u32,
    cursor_applied: ?ui.Cursor,
    /// The clipboard state machine (static: it holds the paste buffer).
    clipboard: *clipboard_module.Clipboard,
    /// Bound `wp_viewporter` and `wp_fractional_scale_manager_v1` globals; null when absent.
    viewporter: ?*wp_fractional_scale.Viewporter,
    fractional_manager: ?*wp_fractional_scale.FractionalScaleManager,
    /// The surface's viewport; non-null exactly in fractional mode.
    viewport: ?*wp_fractional_scale.Viewport,
    /// Logical size last sent with `wp_viewport.set_destination`; 0 before the first.
    destination_width: u32,
    destination_height: u32,
    configure_serial: u32,
    ack_pending: bool,
    pending_width: u32,
    pending_height: u32,
    global_count: u32,
    /// Bound `zxdg_decoration_manager_v1` and the toplevel's decoration; null without the
    /// protocol, and the decoration also when the app draws its own frame (section 5e).
    decoration_manager: ?*xdg_decoration.Manager,
    decoration: ?*xdg_decoration.Decoration,
    /// The window state the callbacks are assembling, and the one last dispatched to the app.
    window_pending: input.WindowState,
    window_applied: input.WindowState,
    /// True after the first configure was acknowledged: the decoration mode is logged once.
    configured: bool,
};

// libwayland-client symbols. A request is not its own C function:
// `wl_proxy_marshal_flags` encodes every one, and the interface tables name the
// object a creating request returns. The `wl_display_*` functions own the socket,
// from the first connect through the sleep in `wait_for_events`.

/// Vtable for `wl_registry`. `get_registry` passes it so the proxy from
/// `wl_display.get_registry` can receive `global` events.
extern const wl_registry_interface: WlInterface;

/// Vtable for `wl_compositor`. `registry_global` passes it when binding the global
/// that creates surfaces.
extern const wl_compositor_interface: WlInterface;

/// Vtable for `wl_surface`. `create_surface` passes it so the new proxy is the
/// canvas `gpu.create` presents into.
extern const wl_surface_interface: WlInterface;

/// Opens the compositor socket. A null `name` selects `$WAYLAND_DISPLAY`, usually
/// `wayland-0`. Returns the connection used by every later call, or null if the
/// socket cannot be opened. `connect` stores the handle on `State`.
extern fn wl_display_connect(name: ?[*:0]const u8) ?*Display;

/// Socket descriptor for this connection. `wait_for_events` passes it to `poll`
/// and sleeps there until the compositor writes.
extern fn wl_display_get_fd(display: *Display) i32;

/// Claims this thread as the reader of the display socket. Returns 0 when the
/// claim is held. A non-zero return means events are already queued, so
/// `wait_for_events` dispatches them and does not sleep.
extern fn wl_display_prepare_read(display: *Display) i32;

/// Drops a claim from `prepare_read` when `flush` or `poll` fails. Required
/// whenever a successful prepare will not be followed by `read_events`.
extern fn wl_display_cancel_read(display: *Display) void;

/// Reads socket bytes into libwayland's queue after `poll` reports the descriptor
/// readable. Consumes the `prepare_read` claim. Returns 0, or -1 on error.
extern fn wl_display_read_events(display: *Display) i32;

/// Invokes listeners installed with `wl_proxy_add_listener` for events already in
/// the queue. Configure, close, ping, and scale run here. Returns the number of
/// events dispatched, or -1 on error.
extern fn wl_display_dispatch_pending(display: *Display) i32;

/// Pushes queued requests (bind, commit, ack, buffer scale) out the socket before
/// `poll`. Returns the number of bytes written, or -1 on error.
extern fn wl_display_flush(display: *Display) i32;

/// Sends queued requests and blocks until the compositor's replies have been
/// dispatched. `bind_globals` calls this once so `wl_compositor` and `xdg_wm_base`
/// are bound before the window exists. Returns the event count, or -1 on error.
extern fn wl_display_roundtrip(display: *Display) i32;

/// Encodes one Wayland request on `proxy`. `opcode` selects the method. When
/// `interface` is non-null, libwayland allocates the new object and returns it.
/// Null means the request has no new id. The variadic arguments are the payload.
extern fn wl_proxy_marshal_flags(
    proxy: ?*WlProxy,
    opcode: u32,
    interface: ?*const WlInterface,
    version: u32,
    flags: u32,
    ...,
) ?*WlProxy;

/// Version agreed when `proxy` was bound. `set_buffer_scale` skips the request on
/// a `wl_surface` older than version 3, where that request does not exist.
extern fn wl_proxy_get_version(proxy: *WlProxy) u32;

/// Installs the C callback table for events on `proxy`. `data` is the `*State`
/// those callbacks recover. Returns 0, or -1 if a listener is already set.
extern fn wl_proxy_add_listener(
    proxy: *WlProxy,
    implementation: *const anyopaque,
    data: ?*anyopaque,
) i32;

const RegistryListener = extern struct {
    global: *const fn (
        data: ?*anyopaque,
        registry: ?*Registry,
        name: u32,
        interface_name: [*:0]const u8,
        version: u32,
    ) callconv(.c) void,
    global_remove: *const fn (
        data: ?*anyopaque,
        registry: ?*Registry,
        name: u32,
    ) callconv(.c) void,
};

const SurfaceListener = extern struct {
    enter: *const fn (
        data: ?*anyopaque,
        surface: ?*WlSurface,
        output: ?*anyopaque,
    ) callconv(.c) void,
    leave: *const fn (
        data: ?*anyopaque,
        surface: ?*WlSurface,
        output: ?*anyopaque,
    ) callconv(.c) void,
    preferred_buffer_scale: *const fn (
        data: ?*anyopaque,
        surface: ?*WlSurface,
        factor: i32,
    ) callconv(.c) void,
    preferred_buffer_transform: *const fn (
        data: ?*anyopaque,
        surface: ?*WlSurface,
        transform: u32,
    ) callconv(.c) void,
};

const registry_listener: RegistryListener = .{
    .global = registry_global,
    .global_remove = registry_global_remove,
};

const surface_listener: SurfaceListener = .{
    .enter = surface_enter,
    .leave = surface_leave,
    .preferred_buffer_scale = surface_preferred_scale,
    .preferred_buffer_transform = surface_preferred_transform,
};

const wm_base_listener: xdg.XdgWmBaseListener = .{
    .ping = xdg_ping,
};

const xdg_surface_listener: xdg.XdgSurfaceListener = .{
    .configure = xdg_surface_configure,
};

const toplevel_listener: xdg.XdgToplevelListener = .{
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_configure_bounds,
    .wm_capabilities = toplevel_wm_capabilities,
};

const decoration_listener: xdg_decoration.DecorationListener = .{
    .configure = decoration_configure,
};

const seat_listener: wl_seat.SeatListener = .{
    .capabilities = seat_capabilities,
    .name = seat_name,
};

const pointer_listener: wl_seat.PointerListener = .{
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_steps,
    .axis_value120 = pointer_axis_steps,
};

const keyboard_listener: wl_seat.KeyboardListener = .{
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

const touch_listener: wl_seat.TouchListener = .{
    .down = touch_down,
    .up = touch_up,
    .motion = touch_motion,
    .frame = touch_frame,
    .cancel = touch_cancel,
    .shape = touch_shape,
    .orientation = touch_orientation,
};

/// Largest keymap the host maps; real keymaps are under 100 KiB.
const keymap_size_max: u32 = 4 * 1024 * 1024;

/// The paste buffer and protocol state of the clipboard; static because of the buffer.
var clipboard_storage: clipboard_module.Clipboard = undefined;

const callback_listener: wl_callback.CallbackListener = .{
    .done = frame_done_callback,
};

const presentation_listener: wp_presentation.PresentationListener = .{
    .clock_id = presentation_clock_id,
};

const fractional_listener: wp_fractional_scale.FractionalScaleListener = .{
    .preferred_scale = fractional_preferred_scale,
};

const feedback_listener: wp_presentation.FeedbackListener = .{
    .sync_output = feedback_sync_output,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

comptime {
    // libwayland indexes listener tables by event opcode, so a table must have exactly one
    // pointer slot per event: `wl_registry` has 2 events and `wl_surface` has 4 at the
    // versions bound here.
    assert(@typeInfo(RegistryListener).@"struct".field_names.len == 2);
    assert(@sizeOf(RegistryListener) == 2 * @sizeOf(*const anyopaque));
    assert(@typeInfo(SurfaceListener).@"struct".field_names.len == 4);
    assert(@sizeOf(SurfaceListener) == 4 * @sizeOf(*const anyopaque));
    // These checks read the hand-written interface tables, so they run only in builds that
    // link `wayland-client`.
    xdg.assert_interface_tables();
    wp_presentation.assert_interface_tables();
    wp_fractional_scale.assert_interface_tables();
    wp_cursor_shape.assert_interface_tables();
    xdg_decoration.assert_interface_tables();
}

/// Orchestrates the entire Wayland application lifecycle for one app type:
/// 1. Checks the app contract at compile time and initializes `App`. With `--check` it
///    records the setup stream, replays it on a device with no window, and returns
///    (`Host(App).check`). Otherwise, unless a scenario runs, it calls `App.args` once when the
///    app declares it (`app.zig`, section 4d), before any display connection.
/// 2. Connects to the Wayland display socket and binds core globals
///    (`wl_compositor`, `xdg_wm_base`).
/// 3. Creates the surface and desktop window (`xdg_surface`, `xdg_toplevel`), titled with
///    `App.config.title`.
/// 4. Initializes the native WebGPU rendering context (`gpu.Gpu`).
/// 5. Records and submits the renderer's setup stream, and confirms the initial state: no
///    batches and `state.frame.relayout` true.
/// 6. Creates the host timer, disarmed, only when `App.config.timer_period_ms` is not zero;
///    the loop arms it while `cx.timer_on` (`Host.sync_timer`).
/// 7. Enters the blocking event loop (`Host(App).loop`).
///
/// The window state lives on this stack frame. The app, the UI context (with the draw context
/// inside it), and the renderer, whose pools and shadows are sized by `App.config`, are static
/// (`Host(App)`), as on the web host, so a large app or configuration never grows the stack.
pub fn run(comptime App: type, options: bench.Options) !void {
    comptime app_contract.check(App);
    const AppHost = Host(App);
    if (options.bench) {
        if (!AppHost.bench_select(options)) return;
    }
    var state = initial_state();
    AppHost.context.init();
    app_contract.start(App, &AppHost.context);
    AppHost.render.init();
    AppHost.render.cache = options.cache;
    App.init(&AppHost.app_static, &AppHost.context.draw.textures);
    if (options.check) return AppHost.check(&state, options.adapter);
    // Before `args`, so a producer it starts can notify at once (section 5c).
    if (AppHost.has_producer) AppHost.wake_fd = try create_wake();
    defer if (AppHost.has_producer) {
        _ = std.os.linux.close(AppHost.wake_fd);
    };
    if (AppHost.has_producer) App.wake(&AppHost.app_static).attach(AppHost.wake_fd);
    if (comptime app_contract.has_args(App)) {
        if (!options.bench) App.args(&AppHost.app_static, options.app_args);
    } else {
        assert(options.app_args.len == 0);
    }
    try init_input(&state);
    defer _ = std.os.linux.close(state.repeat_fd);
    try connect(&state);
    try bind_globals(&state);
    const decorations = options.decorations orelse App.config.decorations;
    try create_toplevel(&state, App.config.title, decorations);
    try create_device(&state, .{ .adapter = options.adapter, .profile = options.bench });
    var host: AppHost = .{
        .state = &state,
        .app = &AppHost.app_static,
        .timer_fd = no_timer_fd,
        .timer_armed = false,
    };
    try host.setup();
    assert(AppHost.context.draw.batch_count == 0);
    assert(state.frame.relayout);
    if (App.config.timer_period_ms != 0) {
        host.timer_fd = try create_timer();
    }
    defer {
        if (host.timer_fd >= 0) {
            _ = std.os.linux.close(host.timer_fd);
        }
    }
    try host.loop();
    host.log_producer();
    if (options.bench) AppHost.bench_finish(&state);
}

/// The window state before the display is connected: nothing bound, nothing owed but the
/// first draw.
fn initial_state() State {
    const state: State = .{
        .frame = .init(),
        .display = undefined,
        .compositor = null,
        .xdg_base = null,
        .surface = null,
        .xdg_surface = null,
        .toplevel = null,
        .gpu = undefined,
        .commands = .init(),
        .clock = animator.Clock.init(),
        .time = animator.Time.init(),
        .queue = input.EventQueue.init(),
        .last_x = 0,
        .last_y = 0,
        .frame_callback = null,
        .frame_done = false,
        .frame_time_ms = 0,
        .present_at_ns = 0,
        .refresh_ns = refresh_ns_initial,
        .last_callback_ns = 0,
        .presentation = null,
        .presentation_clock = 0,
        .vblank_ns = 0,
        .vblank_refresh_ns = 0,
        .feedback_in_flight = 0,
        .seat = null,
        .pointer_proxy = null,
        .keyboard_proxy = null,
        .touch_proxy = null,
        .keyboard = undefined,
        .repeat = input.Repeat.init(),
        .repeat_fd = no_timer_fd,
        .input_serial = 0,
        .cursor_manager = null,
        .cursor_device = null,
        .enter_serial = 0,
        .cursor_applied = null,
        .clipboard = &clipboard_storage,
        .viewporter = null,
        .fractional_manager = null,
        .viewport = null,
        .destination_width = 0,
        .destination_height = 0,
        .configure_serial = 0,
        .ack_pending = false,
        .pending_width = 0,
        .pending_height = 0,
        .global_count = 0,
        .decoration_manager = null,
        .decoration = null,
        .window_pending = .{},
        .window_applied = .{},
        .configured = false,
    };
    assert(state.repeat_fd == no_timer_fd);
    assert(state.seat == null);
    return state;
}

/// Prepares keyboard and clipboard input before the display connects: `SIGPIPE` ignored, the
/// xkb context and compose table, the clipboard, and the disarmed repeat timerfd.
fn init_input(state: *State) !void {
    ignore_sigpipe();
    state.keyboard.init();
    clipboard_storage.init();
    clipboard_storage.dnd.queue = &state.queue;
    state.repeat_fd = try create_timer();
    assert(state.repeat_fd >= 0);
    assert(state.repeat.code == null);
}

/// `poll` ignores a negative descriptor, so an app without a timer passes this value in the
/// timer slot of the poll set and the timer is never readable.
const no_timer_fd: i32 = -1;

/// The fixed slots of the `ppoll` set (module guide, section 1).
const Slot = enum(u8) {
    wayland,
    timer,
    repeat,
    send,
    receive,
    /// The `eventfd` a producer notifies (section 5c).
    wake,
    drop_list,
};
const slot_count: u32 = @typeInfo(Slot).@"enum".field_names.len;

fn poll_entry(fd: i32, events: i16) std.posix.pollfd {
    assert(events != 0);
    return .{ .fd = fd, .events = events, .revents = 0 };
}

/// Reads the repeat timer's expiration count and queues one repeat of the held key, however
/// many periods passed (section 5a). A key released since queues nothing.
fn drain_repeat(state: *State) void {
    var expirations: u64 = 0;
    const rc = std.os.linux.read(state.repeat_fd, std.mem.asBytes(&expirations), 8);
    if (std.os.linux.errno(rc) != .SUCCESS) return;
    assert(rc == 8);
    const code = state.repeat.code orelse return;
    push_key(state, code, true);
    assert(expirations >= 1);
}

/// Ignores `SIGPIPE`, so writing to a clipboard reader that closed its pipe returns `EPIPE`
/// instead of ending the process (`clipboard.zig`, section 4).
fn ignore_sigpipe() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &action, null);
}

/// A nonblocking `eventfd` at 0: the producer's wake (section 5c).
fn create_wake() !i32 {
    const flags = std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC;
    const created = std.os.linux.eventfd(0, flags);
    const fd: i32 = switch (std.os.linux.errno(created)) {
        .SUCCESS => @intCast(created),
        else => return error.EventCreateFailed,
    };
    assert(fd >= 0);
    return fd;
}

/// Reads the wake's counter to clear it. Nothing to read is fine: a wake can be readable
/// once for several writes.
fn drain_wake(fd: i32) void {
    var count: u64 = 0;
    const rc = std.os.linux.read(fd, std.mem.asBytes(&count), 8);
    if (std.os.linux.errno(rc) != .SUCCESS) return;
    assert(rc == 8);
    assert(count >= 1);
}

/// A disarmed nonblocking `timerfd` on `CLOCK_MONOTONIC`: the key repeat timer, and the app
/// timer when the app declares a period.
fn create_timer() !i32 {
    const flags: std.os.linux.TFD = .{ .NONBLOCK = true, .CLOEXEC = true };
    const created = std.os.linux.timerfd_create(.MONOTONIC, flags);
    const fd: i32 = switch (std.os.linux.errno(created)) {
        .SUCCESS => @intCast(created),
        else => return error.TimerCreateFailed,
    };
    assert(fd >= 0);
    return fd;
}

/// The app-facing half of the native loop. Everything that calls the app contract lives
/// here, so the Wayland and GPU half of this file stays one non-generic compilation.
/// `timer_fd` is `no_timer_fd` when `App.config.timer_period_ms` is 0; otherwise it is armed
/// exactly while `timer_armed`, which `sync_timer` keeps equal to `cx.timer_on`.
fn Host(comptime App: type) type {
    return struct {
        const Self = @This();
        const Context = app_contract.Context(App);
        const Renderer = renderer.Renderer(Context.DrawContext);

        state: *State,
        app: *App,
        timer_fd: i32,
        timer_armed: bool,

        /// The app, its UI context (pools, areas, pointer state), and the renderer. Static so
        /// app storage and the pools and shadows sized by `App.config` stay off the stack;
        /// `run` initializes all three in place.
        var app_static: App = undefined;
        var context: Context = undefined;
        var render: Renderer = undefined;

        /// A producer on another thread (section 5c), and its descriptor.
        const has_producer = app_contract.has_producer(App);
        var wake_fd: i32 = -1;
        /// `App.drain` calls since startup, for the exit line (`log_producer`).
        var producer_drains: u64 = 0;

        // ------------------------------------------------------------ bench mode

        const type_count = Context.DrawContext.Registry.count;
        const scenarios: []const bench.Scenario =
            if (@hasDecl(App, "scenarios")) App.scenarios else &.{};

        /// The run `--bench <scenario>` drives (`bench.zig`, module guide section 2).
        /// Inactive without `--bench`; then only `draw_ns` and `drew` are written.
        const BenchRun = struct {
            active: bool,
            scenario: bench.Scenario,
            replay: bench.Replay,
            options: bench.Options,
            /// No step runs before the first frame recorded its areas.
            presented_any: bool,
            /// Frames presented so far, setup included: the synthetic time (`bench_time`).
            presented: u64,
            draw_ns: u64,
            drew: bool,
            count: u32,
            /// Instances and shaded area per draw type of the last measured frame.
            types: [type_count]bench.TypeArea,
            csv_fd: i32,
            /// Frames the producer was stepped by (section 5c).
            producer_frames: u64,
        };
        var bench_run: BenchRun = .{
            .active = false,
            .scenario = undefined,
            .replay = undefined,
            .options = .off,
            .presented_any = false,
            .presented = 0,
            .draw_ns = 0,
            .drew = false,
            .count = 0,
            .types = undefined,
            .csv_fd = -1,
            .producer_frames = 0,
        };
        var bench_samples: [bench.sample_cap]bench.Sample = undefined;
        var bench_values: [bench.sample_cap]u64 = undefined;
        var bench_row: [bench.width_max * 3]u8 = undefined;

        /// Resolves `--bench [name]` before any window opens. Lists the scenarios and returns
        /// false when none is named or the name is unknown.
        fn bench_select(options: bench.Options) bool {
            assert(options.bench);
            assert(!bench_run.active);
            const name = options.scenario orelse "";
            const found = bench.find(scenarios, name) orelse {
                if (options.scenario != null) {
                    std.debug.print("bench: no scenario \"{s}\"\n", .{name});
                }
                std.debug.print("bench: scenarios of {s}:", .{App.config.title});
                if (scenarios.len == 0) std.debug.print(" none", .{});
                for (scenarios) |scenario| std.debug.print(" {s}", .{scenario.name});
                std.debug.print("\n", .{});
                return false;
            };
            bench_run.active = true;
            bench_run.scenario = found.*;
            if (options.frames) |frames| bench_run.scenario.frames = frames;
            bench_run.replay = .init();
            bench_run.options = options;
            if (options.csv) |path| bench_run.csv_fd = bench_open_csv(path);
            assert(bench_run.scenario.frames >= 1);
            assert(bench_run.scenario.frames <= bench.sample_cap);
            return true;
        }

        /// Runs the next scenario step once the host is idle: the last frame is presented,
        /// its callback arrived, and nothing is owed. Every step forces one frame
        /// (`bench.zig`, section 2). Runs before `sync_clock`, so the frame is scheduled
        /// against vblank like real input.
        fn bench_step(self: *Self) void {
            if (!bench_run.active) return;
            const state = self.state;
            if (!bench_run.presented_any) return;
            if (state.frame.redraw) return;
            if (state.frame_callback != null) return;
            const step = bench_run.replay.next(&bench_run.scenario) orelse return;
            var rect: ?[4]f32 = null;
            if (bench.step_target(step)) |target| {
                const found = context.find(target.id) orelse {
                    std.debug.print("bench: no area {s} {d}\n", .{ target.name, target.index });
                    state.frame.running = false;
                    return;
                };
                rect = found.rect;
            }
            var events: [bench.event_cap]input.Event = undefined;
            const time_ms: u32 = @truncate(monotonic_ns() / std.time.ns_per_ms);
            const count = bench.step_events(step, rect, time_ms, &events);
            for (events[0..count]) |event| self.dispatch(event);
            if (step == .drop) bench.replay_drop(App, self.app, &context, step.drop, rect.?);
            bench.serve_window(App, self.app, &context);
            state.frame.request_redraw();
            assert(state.frame.redraw);
        }

        /// Animation time in bench mode: exactly 1/60 s per presented frame, so frame N reads
        /// the same time in every run and dumps with the cache on and off compare exactly.
        fn bench_time() f32 {
            assert(bench_run.active);
            const time: animator.Time = .{ .ms = bench_run.presented * 1000 / 60 };
            return time.seconds();
        }

        /// Asks the GPU to copy this frame when it is the last measured one and `--dump`
        /// was given.
        fn bench_request_image(state: *State) void {
            assert(bench_run.active);
            if (bench_run.options.dump == null) return;
            const replay = bench_run.replay;
            if (replay.phase != .measure) return;
            if (replay.measured + 1 != bench_run.scenario.frames) return;
            gpu.native.request_frame_image(&state.gpu);
            // A skipped frame would present nothing to copy.
            render.present_next = true;
        }

        /// Records a presented frame: a sample when it was measured, the CSV line, and the
        /// end of the run after the last one.
        fn bench_presented(state: *State, timing: bench.Sample) void {
            assert(bench_run.active);
            bench_run.presented_any = true;
            bench_run.presented += 1;
            if (!bench_run.replay.presented(&bench_run.scenario)) return;
            var sample = timing;
            const scale_120 = state.frame.scale_120;
            sample.instances = bench.shaded_area(
                Context.DrawContext,
                &context.draw,
                scale_120,
                &bench_run.types,
            );
            var area_px: f64 = 0;
            for (bench_run.types) |entry| area_px += entry.area_px;
            const window_px: f64 = @floatFromInt(state.frame.width_px * state.frame.height_px);
            sample.area_windows = @floatCast(area_px / window_px);
            assert(bench_run.count < bench.sample_cap);
            bench_samples[bench_run.count] = sample;
            bench_run.count += 1;
            if (bench_run.csv_fd >= 0) bench_write_csv(bench_run.count - 1, &sample);
            if (bench_run.replay.phase == .done) state.frame.running = false;
            assert(bench_run.count == bench_run.replay.measured);
        }

        fn bench_open_csv(path: [:0]const u8) i32 {
            const fd = open_for_write(path) orelse return -1;
            const header = "frame,drew,draw_us,finalize_us,record_us,submit_us,gpu_us," ++
                "instances,area_windows\n";
            write_all(fd, header);
            return fd;
        }

        fn bench_write_csv(index: u32, sample: *const bench.Sample) void {
            assert(bench_run.csv_fd >= 0);
            var line: [256]u8 = undefined;
            const gpu_us: f64 = if (sample.gpu_ns) |ns| microseconds(ns) else -1;
            const format = "{d},{d},{d:.1},{d:.1},{d:.1},{d:.1},{d:.1},{d},{d:.3}\n";
            const text = std.fmt.bufPrint(&line, format, .{
                index,                          @intFromBool(sample.drew),
                microseconds(sample.draw_ns),   microseconds(sample.finalize_ns),
                microseconds(sample.record_ns), microseconds(sample.submit_ns),
                gpu_us,                         sample.instances,
                sample.area_windows,
            }) catch unreachable;
            write_all(bench_run.csv_fd, text);
        }

        /// After the loop: closes the CSV, writes the dump, and prints the report.
        fn bench_finish(state: *State) void {
            if (!bench_run.active) return;
            if (bench_run.csv_fd >= 0) _ = std.os.linux.close(bench_run.csv_fd);
            if (bench_run.options.dump) |path| bench_write_image(state, path);
            bench_report_header(state);
            if (bench_run.count == 0) return;
            bench_report_kinds();
            bench_report_rows();
            bench_report_targets();
            bench_report_types(state);
        }

        fn bench_write_image(state: *State, path: [:0]const u8) void {
            defer gpu.native.release_frame_image(&state.gpu);
            const image = gpu.native.frame_image(&state.gpu) orelse {
                std.debug.print("bench: no frame image to write\n", .{});
                return;
            };
            assert(image.width <= bench.width_max);
            const fd = open_for_write(path) orelse return;
            defer _ = std.os.linux.close(fd);
            var header: [32]u8 = undefined;
            write_all(fd, bench.ppm_header(&header, image.width, image.height));
            const rgb = bench_row[0 .. image.width * 3];
            for (0..image.height) |y| {
                const row = image.bytes[y * image.row_bytes ..][0 .. image.width * 4];
                bench.ppm_row(rgb, row);
                write_all(fd, rgb);
            }
            std.debug.print("bench: wrote {s} ({d}x{d})\n", .{ path, image.width, image.height });
        }

        fn bench_report_header(state: *State) void {
            const adapter = gpu.native.profile_adapter(&state.gpu);
            const scale: f64 = @as(f64, @floatFromInt(state.frame.scale_120)) / 120.0;
            var drew: u32 = 0;
            for (bench_samples[0..bench_run.count]) |sample| drew += @intFromBool(sample.drew);
            std.debug.print("bench {s}/{s} mode {s} adapter \"{s}\" {d}x{d} px at {d:.2}: " ++
                "{d} frames measured, {d} drew\n", .{
                App.config.title,       bench_run.scenario.name,
                @tagName(builtin.mode), adapter,
                state.frame.width_px,   state.frame.height_px,
                scale,                  bench_run.count,
                drew,
            });
        }

        /// Measured frames per renderer kind (`draw/renderer.zig`, section 4a), and how many
        /// folded their instances into tiles rather than repeating the last frame's (4b).
        fn bench_report_kinds() void {
            var counts = std.EnumArray(renderer.Kind, u32).initFill(0);
            for (bench_samples[0..bench_run.count]) |sample| {
                counts.set(sample.kind, counts.get(sample.kind) + 1);
            }
            std.debug.print("frames:", .{});
            for (std.enums.values(renderer.Kind)) |kind| {
                std.debug.print(" {s} {d}", .{ @tagName(kind), counts.get(kind) });
            }
            var hashed: u32 = 0;
            for (bench_samples[0..bench_run.count]) |sample| hashed += @intFromBool(sample.hashed);
            std.debug.print(" (cache {s}), {d} hashed\n", .{
                if (render.cache) "on" else "off",
                hashed,
            });
        }

        fn bench_report_rows() void {
            std.debug.print("{s:<12} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}   (us)\n", .{
                "", "min", "p10", "p50", "p90", "max",
            });
            const names = [_][]const u8{
                "draw", "finalize", "record", "submit", "cpu", "gpu pass",
            };
            for (names, 0..) |name, metric| {
                var count: u32 = 0;
                for (bench_samples[0..bench_run.count]) |*sample| {
                    const value = bench_metric(sample, @intCast(metric)) orelse continue;
                    bench_values[count] = value;
                    count += 1;
                }
                if (count == 0) {
                    std.debug.print("{s:<12} n/a (no timestamp-query feature)\n", .{name});
                    continue;
                }
                const summary = bench.summarize(bench_values[0..count]);
                std.debug.print("{s:<12} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1}\n", .{
                    name,
                    microseconds(summary.min),
                    microseconds(summary.p10),
                    microseconds(summary.p50),
                    microseconds(summary.p90),
                    microseconds(summary.max),
                });
            }
        }

        /// The GPU time of each offscreen target pass of the frame just submitted: the profiled
        /// passes before the main one (`gpu_wgpu.zig`, section 9).
        fn bench_target_ns(state: *State) [textures.target_cap]u64 {
            var out: [textures.target_cap]u64 = @splat(0);
            const passes = gpu.native.profile_passes_ns(&state.gpu);
            const count = @min(render.rendered, passes.len);
            for (passes[0..count], out[0..count]) |ns, *slot| slot.* = ns;
            return out;
        }

        /// One GPU row per offscreen target index any measured frame rendered, then each
        /// target's device size and memory (`draw/renderer.zig`, section 4c).
        fn bench_report_targets() void {
            for (0..textures.target_cap) |index| {
                var count: u32 = 0;
                for (bench_samples[0..bench_run.count]) |*sample| {
                    if (sample.targets <= index or sample.gpu_ns == null) continue;
                    bench_values[count] = sample.target_ns[index];
                    count += 1;
                }
                if (count == 0) continue;
                const summary = bench.summarize(bench_values[0..count]);
                std.debug.print("gpu target {d} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1}   ({d} frames)\n", .{
                    index,
                    microseconds(summary.min),
                    microseconds(summary.p10),
                    microseconds(summary.p50),
                    microseconds(summary.p90),
                    microseconds(summary.max),
                    count,
                });
            }
            for (render.targets[0..render.target_count], 0..) |target, index| {
                if (!target.ready) continue;
                const buffers: u64 = if (target.kind == .feedback) 2 else 1;
                const bytes = buffers * target.device.width * target.device.height * 4;
                std.debug.print("target {d}: {s} {d}x{d} px, {d} KiB\n", .{
                    index,
                    @tagName(target.kind),
                    target.device.width,
                    target.device.height,
                    bytes / 1024,
                });
            }
        }

        /// One metric of a sample in nanoseconds: draw, finalize, record, submit, the CPU sum
        /// of the first three, and the GPU pass (null without timestamps).
        fn bench_metric(sample: *const bench.Sample, metric: u32) ?u64 {
            assert(metric < 6);
            return switch (metric) {
                0 => sample.draw_ns,
                1 => sample.finalize_ns,
                2 => sample.record_ns,
                3 => sample.submit_ns,
                4 => sample.draw_ns + sample.finalize_ns + sample.record_ns,
                else => sample.gpu_ns,
            };
        }

        fn bench_report_types(state: *State) void {
            const last = bench_samples[bench_run.count - 1];
            std.debug.print("last frame: {d} instances, shaded area {d:.2} windows\n", .{
                last.instances, last.area_windows,
            });
            const window_px: f64 = @floatFromInt(state.frame.width_px * state.frame.height_px);
            inline for (0..type_count) |index| {
                const entry = bench_run.types[index];
                std.debug.print("  {s:<24} {d:>6} instances {d:>7.3} windows\n", .{
                    Context.DrawContext.Registry.labels[index],
                    entry.count,
                    entry.area_px / window_px,
                });
            }
        }

        /// `--check`: records the setup stream exactly as `setup` does and replays it on a
        /// device with no window (`gpu_wgpu.zig`, section 10). Prints the counts and returns,
        /// or exits with status 1 after the backend logged the first failing op.
        fn check(state: *State, adapter: bench.Adapter) !void {
            state.commands.reset();
            render.setup(&state.commands, &context.draw);
            assert(render.ready);
            assert(state.commands.count != 0);
            const checked = gpu.native.check(&state.commands, adapter) catch |err| {
                std.debug.print("check: {s}: {s}\n", .{ App.config.title, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("check: {d} shaders, {d} pipelines ok ({s}, {s})\n", .{
                checked.shaders,
                checked.pipelines,
                App.config.title,
                checked.adapter(),
            });
        }

        /// Records the renderer's setup stream (every long-lived resource and the textures
        /// queued so far) and submits it.
        fn setup(self: *Self) !void {
            const state = self.state;
            state.commands.reset();
            render.setup(&state.commands, &context.draw);
            try gpu.submit(&state.gpu, &state.commands);
            assert(render.ready);
            assert(context.draw.textures.created == context.draw.textures.count);
        }

        /// Records one frame of the draw context and submits it to the GPU, then marks the
        /// frame presented. The renderer updates its shadows while recording.
        fn submit_frame(self: *Self) !void {
            const state = self.state;
            assert(state.frame.redraw);
            assert(state.frame.width_px != 0);
            state.commands.reset();
            const finalize_start_ns = monotonic_ns();
            // `finalize` is idempotent, so bench mode runs it first to time it alone.
            if (bench_run.active) context.draw.finalize();
            if (bench_run.active) bench_request_image(state);
            const time_s = if (bench_run.active) bench_time() else state.time.seconds();
            const record_start_ns = monotonic_ns();
            render.frame(&state.commands, &context.draw, .{
                .width_logical = state.frame.width_logical,
                .height_logical = state.frame.height_logical,
                .width_px = state.frame.width_px,
                .height_px = state.frame.height_px,
                .scale_120 = state.frame.scale_120,
            }, time_s);
            const submit_start_ns = monotonic_ns();
            const presents = render.last != .skipped;
            // Both requests attach to the next commit. A presenting frame's commit is the
            // present inside `gpu.submit`; a skipped frame (`draw/renderer.zig`, section 4a)
            // commits no buffer, only the frame callback that paces the next frame.
            arm_frame(state);
            if (presents) arm_feedback(state);
            if (state.commands.len != 0) try gpu.submit(&state.gpu, &state.commands);
            // No attached buffer: the frame callback and any viewport change take effect, and
            // the compositor keeps showing the last frame.
            if (!presents) commit_surface(state.surface.?);
            if (bench_run.active) bench_presented(state, .{
                .draw_ns = bench_run.draw_ns,
                .finalize_ns = record_start_ns - finalize_start_ns,
                .record_ns = submit_start_ns - record_start_ns,
                .submit_ns = monotonic_ns() - submit_start_ns,
                .gpu_ns = if (presents) gpu.native.profile_pass_ns(&state.gpu) else 0,
                .instances = 0,
                .area_windows = 0,
                .drew = bench_run.drew,
                .kind = render.last,
                .hashed = render.hashed,
                .targets = render.rendered,
                .target_ns = if (presents or render.rendered != 0) bench_target_ns(state) else @splat(0),
            });
            state.frame.mark_presented();
            assert(!state.frame.redraw);
            // Glyphs skipped for the budget or a full atlas finish on the next frame, and a
            // hover that the redraw moved (`ui.draw_frame`) may have owed another draw.
            if (context.draw.text.owes_draw(state.frame.scale_120)) {
                state.frame.request_redraw();
            }
            if (context.dirty) {
                state.frame.request_redraw();
            }
        }

        /// Blocking loop. Callbacks only write the queue and the frame-done flag.
        /// Order is ack, drain input, step the clock, present if due, then sleep in poll.
        /// A commit arms `wl_surface.frame`. The next commit waits until just before the
        /// following refresh. A `done` with nothing dirty arms nothing, so poll blocks.
        fn loop(self: *Self) !void {
            const state = self.state;
            assert(@intFromPtr(state.display) != 0);
            if (App.config.timer_period_ms == 0) assert(self.timer_fd == no_timer_fd);
            while (state.frame.running) {
                ack_if_needed(state);
                self.sync_input();
                // A dispatch that left `close` ended the run (section 5e).
                if (!state.frame.running) break;
                self.sync_producer();
                self.bench_step();
                self.sync_clock();
                try self.present_if_dirty();
                self.sync_timer();
                try self.wait_for_events();
            }
            assert(!state.frame.running);
        }

        /// Drains the input queue once per wake, then dispatches a finished paste, and sends
        /// the cursor. A press and a release in the same Wayland batch stay two events, so a
        /// click is not collapsed.
        fn sync_input(self: *Self) void {
            const state = self.state;
            assert(state.frame.running);
            var guard: u32 = 0;
            while (guard < input.queue_cap) : (guard += 1) {
                const event = state.queue.pop() orelse break;
                self.dispatch(event);
                if (!state.frame.running) return;
            }
            assert(guard <= input.queue_cap);
            if (state.clipboard.take_received()) |pasted| self.dispatch(.{ .paste = pasted });
            self.sync_drops();
            apply_cursor(state, context.cursor());
        }

        /// A finished drop list becomes one `drop` (a transfer still running is cancelled
        /// first), then at most `drop.chunks_per_wake` chunks are read and dispatched
        /// (section 5d).
        fn sync_drops(self: *Self) void {
            const dnd = &self.state.clipboard.dnd;
            if (dnd.take_drop()) |files| {
                if (dnd.busy()) self.dispatch_chunks(dnd.cancel(std.math.maxInt(u16)));
                self.dispatch(.{ .drop = files });
            }
            var reads: u32 = 0;
            while (reads < drop.chunks_per_wake and dnd.busy()) : (reads += 1) {
                const chunk = dnd.next_chunk() orelse break;
                self.dispatch(.{ .file = chunk });
            }
            assert(reads <= drop.chunks_per_wake);
        }

        /// Dispatches cancelled chunks directly; cancels they ask for wait for the next
        /// `serve_files`.
        fn dispatch_chunks(self: *Self, chunks: []const input.Chunk) void {
            assert(chunks.len <= input.drop_files_max);
            for (chunks) |*chunk| {
                ui.dispatch(App, self.app, &context, .{ .file = chunk });
                if (context.dirty) self.state.frame.request_redraw();
            }
        }

        /// After a dispatch: the drag's accept, a transfer the app accepted, and the cancelled
        /// chunks of its cancels, bounded (section 5d).
        fn serve_files(self: *Self) void {
            const dnd = &self.state.clipboard.dnd;
            dnd.sync_accept(context.drop_wanted());
            if (context.take_files_accept()) |mask| dnd.start(mask);
            var guard: u32 = 0;
            while (guard < input.drop_files_max) : (guard += 1) {
                const mask = context.take_files_cancel();
                if (mask == 0) break;
                self.dispatch_chunks(dnd.cancel(mask));
            }
        }

        /// One dispatch, then the clipboard requests it made (section 5a).
        fn dispatch(self: *Self, event: input.Event) void {
            const state = self.state;
            ui.dispatch(App, self.app, &context, event);
            if (context.dirty) {
                state.frame.request_redraw();
            }
            self.serve_files();
            // A bench run's steps are served by `bench.serve_window` (`bench.zig`, section 2c).
            if (!bench_run.active) {
                if (context.take_window_request()) |request| serve_window(state, request);
            }
            if (context.take_copy()) state.clipboard.copy(state.input_serial);
            if (!context.take_paste_request()) return;
            if (state.clipboard.owns_selection()) {
                // Copied into the paste buffer so a widget may `copy` while handling it.
                const own = context.copied();
                @memcpy(state.clipboard.buffer[0..own.len], own);
                ui.dispatch(
                    App,
                    self.app,
                    &context,
                    .{ .paste = state.clipboard.buffer[0..own.len] },
                );
                if (context.dirty) state.frame.request_redraw();
                return;
            }
            _ = state.clipboard.start_receive();
        }

        /// Steps animators from the frame-callback timestamp. The first sample after
        /// idle has dt 0, so a hover pays one frame before it moves. A live app, or a
        /// renderer with an animated instance on screen, requests another present even when
        /// this step did not move a value; the latter also advances the animation time. If
        /// a redraw is owed, the commit is scheduled just before the next refresh so
        /// pointer motion during the wait is included. A settled app resets the clock.
        fn sync_clock(self: *Self) void {
            const state = self.state;
            if (!state.frame_done) {
                assert(!state.frame_done);
                return;
            }
            state.frame_done = false;
            note_refresh(state);
            const dt_ms = state.clock.advance(state.frame_time_ms);
            if (render.animating) state.time.advance(dt_ms);
            const animating = ui.animate(App, self.app, &context, dt_ms) or render.animating;
            if (context.dirty) {
                state.frame.request_redraw();
            }
            if (animating) {
                state.frame.request_redraw();
            } else {
                state.clock.reset();
            }
            schedule_present(state);
            assert(!state.frame_done);
            assert(state.frame.running);
        }

        /// Presents when `redraw` is set, no frame callback is in flight, and the
        /// late-latch deadline has arrived. A callback already in flight, or a deadline
        /// still in the future, leaves `redraw` set so pointer motion during the wait
        /// is in the queue when the commit runs. The draw, layout included, runs only
        /// on that commit; a scale change rebuilds only the glyph records (module
        /// guide, section 4). Every commit arms `wl_surface.frame`.
        fn present_if_dirty(self: *Self) !void {
            const state = self.state;
            if (!state.frame.redraw) {
                assert(!state.frame.redraw);
                return;
            }
            if (state.frame.width_px == 0) {
                assert(state.frame.height_px == 0);
                return;
            }
            if (state.frame_callback != null) {
                assert(state.frame.redraw);
                assert(state.frame_callback != null);
                return;
            }
            if (state.present_at_ns != 0) {
                const now_ns = monotonic_ns();
                if (now_ns < state.present_at_ns) {
                    assert(state.frame.redraw);
                    return;
                }
            }
            state.present_at_ns = 0;
            self.bench_produce();
            const draw_start_ns = monotonic_ns();
            self.prepare_app();
            bench_run.draw_ns = monotonic_ns() - draw_start_ns;
            apply_surface_scale(state);
            try self.submit_frame();
            // A draw that moved things under the pointer re-resolved hover, and its cursor.
            apply_cursor(state, context.cursor());
        }

        /// Draws the app into the context before presentation. A changed logical size only
        /// owes a draw, because layout happens while drawing. `ui.draw_frame` draws when the
        /// context is dirty or the glyph cache owes a draw (module guide, section 4).
        fn prepare_app(self: *Self) void {
            const state = self.state;
            if (state.frame.relayout) {
                state.frame.mark_laid_out();
                context.redraw();
            }
            assert(!state.frame.relayout);
            const scale_120 = state.frame.scale_120;
            bench_run.drew = ui.draw_frame(
                App,
                self.app,
                &context,
                state.frame.width_logical,
                state.frame.height_logical,
                scale_120,
            );
            assert(context.draw.text.drawn_scale_120 == scale_120);
            if (std.debug.runtime_safety) {
                if (context.overflow_report()) |refused| log_overflow(refused);
            }
        }

        /// One line per changed overflow (`ui/cx.zig`, section 10), and one for missing
        /// icons.
        fn log_overflow(refused: ui.cx.Overflow) void {
            if (refused.instances + refused.areas + refused.glyphs > 0) {
                std.debug.print(
                    "overflow: {d} instances, {d} areas, {d} glyphs refused this frame " ++
                        "(raise App.config caps)\n",
                    .{ refused.instances, refused.areas, refused.glyphs },
                );
            }
            if (refused.icons > 0) {
                const face = refused.icon >> 21;
                const name = if (face < font_data.names.len) font_data.names[face] else "?";
                std.debug.print(
                    "icons: {d} drawn this frame are not in their face (last U+{X:0>4} in {s})\n",
                    .{ refused.icons, refused.icon & 0x1FFFFF, name },
                );
            }
        }

        /// Blocks until the compositor writes, the app timer fires, or the latched
        /// commit is due. A timer-only wake cancels the prepared Wayland read.
        /// Idle, with no latched commit, passes a null timeout to `ppoll`.
        fn wait_for_events(self: *Self) !void {
            const state = self.state;
            const display = state.display;
            assert(@intFromPtr(display) != 0);
            assert(wl_display_get_fd(display) >= 0);
            if (!self.arm_producer()) return;
            defer if (has_producer) App.wake(self.app).disarm();
            if (wl_display_prepare_read(display) != 0) {
                const pending = wl_display_dispatch_pending(display);
                if (pending < 0) {
                    return error.DispatchFailed;
                }
                try self.drain_timer();
                return;
            }
            const flush_rc = wl_display_flush(display);
            if (flush_rc < 0) {
                wl_display_cancel_read(display);
                return error.FlushFailed;
            }
            const clipboard = state.clipboard;
            var fds: [slot_count]std.posix.pollfd = undefined;
            fds[@backingInt(Slot.wayland)] = poll_entry(
                wl_display_get_fd(display),
                std.posix.POLL.IN,
            );
            fds[@backingInt(Slot.timer)] = poll_entry(self.timer_fd, std.posix.POLL.IN);
            fds[@backingInt(Slot.repeat)] = poll_entry(state.repeat_fd, std.posix.POLL.IN);
            fds[@backingInt(Slot.send)] = poll_entry(clipboard.send_fd, std.posix.POLL.OUT);
            fds[@backingInt(Slot.receive)] = poll_entry(clipboard.receive_fd, std.posix.POLL.IN);
            fds[@backingInt(Slot.wake)] = poll_entry(wake_fd, std.posix.POLL.IN);
            fds[@backingInt(Slot.drop_list)] = poll_entry(clipboard.dnd.list_fd, std.posix.POLL.IN);
            const ready = poll_wayland(state, fds[0..]) catch {
                wl_display_cancel_read(display);
                return error.PollFailed;
            };
            if (ready == 0) {
                wl_display_cancel_read(display);
                assert(state.present_at_ns != 0 or clipboard.dnd.busy());
                return;
            }
            const wayland_ready = (fds[@backingInt(Slot.wayland)].revents & std.posix.POLL.IN) != 0;
            if (wayland_ready) {
                if (wl_display_read_events(display) != 0) {
                    return error.ReadFailed;
                }
                const pending = wl_display_dispatch_pending(display);
                if (pending < 0) {
                    return error.DispatchFailed;
                }
            } else {
                wl_display_cancel_read(display);
            }
            const timer_ready = (fds[@backingInt(Slot.timer)].revents & std.posix.POLL.IN) != 0;
            if (timer_ready) {
                try self.drain_timer();
            }
            if (fds[@backingInt(Slot.repeat)].revents != 0) drain_repeat(state);
            if (fds[@backingInt(Slot.send)].revents != 0) clipboard.pump_send(context.copied());
            if (fds[@backingInt(Slot.receive)].revents != 0) clipboard.pump_receive();
            if (fds[@backingInt(Slot.wake)].revents != 0) drain_wake(wake_fd);
            if (fds[@backingInt(Slot.drop_list)].revents != 0) clipboard.dnd.pump_list();
            // A bench run that ended in a callback read above stops the loop. That wake is not
            // a failure.
            if (!state.frame.running) {
                assert(!state.frame.running);
                return;
            }
            assert(state.frame.running);
        }

        /// Calls `App.drain` once, and owes a redraw if it left the app dirty (section 5c).
        fn sync_producer(self: *Self) void {
            if (!has_producer) return;
            App.drain(self.app, &context);
            producer_drains += 1;
            if (context.dirty) self.state.frame.request_redraw();
        }

        /// Bench mode only: steps the producer by this frame's sample time, then drains
        /// (section 5c).
        fn bench_produce(self: *Self) void {
            if (!has_producer) return;
            if (!bench_run.active) return;
            if (comptime app_contract.has_produce(App)) {
                App.produce(self.app, bench.producer_frames_at(bench_run.producer_frames, 60));
            }
            bench_run.producer_frames += 1;
            self.sync_producer();
        }

        /// Arms the app's wake before a sleep when nothing else will wake the loop: no frame
        /// callback is in flight and no commit is latched (section 5c).
        /// Returns false when the producer has something pending, so the caller drains.
        fn arm_producer(self: *Self) bool {
            if (!has_producer) return true;
            const state = self.state;
            if (state.frame_callback != null) return true;
            if (state.present_at_ns != 0) return true;
            const count: ProducerCount = .{ .app = self.app };
            return App.wake(self.app).arm(&count);
        }

        /// What `Wake.arm` reads for a producer: the app's own count (`app.zig`, section 4e).
        const ProducerCount = struct {
            app: *const App,

            pub fn pending(count: *const ProducerCount) u32 {
                return App.pending(count.app);
            }
        };

        /// After the loop of an app with a producer: the wakes its `notify` wrote, and drains.
        fn log_producer(self: *const Self) void {
            if (!has_producer) return;
            std.log.info("wake: {d} notified, {d} drains", .{
                App.wake(self.app).notified.load(.monotonic),
                producer_drains,
            });
        }

        /// Arms or disarms the app timer to match `cx.timer_on`, once per wake before the
        /// sleep, so a change made by any call into the app takes effect before `poll`.
        /// Disarming also discards an expiration not yet read (`timerfd_settime`).
        fn sync_timer(self: *Self) void {
            if (self.timer_fd < 0) {
                assert(!context.timer_on);
                assert(!self.timer_armed);
                return;
            }
            if (context.timer_on == self.timer_armed) return;
            const period_ms: u32 = if (context.timer_on) App.config.timer_period_ms else 0;
            set_app_timer(self.timer_fd, period_ms);
            self.timer_armed = context.timer_on;
            assert(self.timer_armed == context.timer_on);
        }

        /// Reads one expiration count and discards it. Several missed periods become
        /// one call at the current monotonic time. A host without a timer returns at once.
        fn drain_timer(self: *Self) !void {
            const state = self.state;
            if (self.timer_fd < 0) {
                assert(self.timer_fd == no_timer_fd);
                return;
            }
            var expirations: u64 = 0;
            const bytes = std.mem.asBytes(&expirations);
            const read_n = std.posix.read(self.timer_fd, bytes) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.TimerReadFailed,
            };
            assert(read_n == 8);
            assert(expirations >= 1);
            // `sync_timer` disarms before every sleep, which discards unread expirations.
            assert(self.timer_armed);
            const now_ms = monotonic_ns() / 1_000_000;
            App.timer(self.app, &context, now_ms);
            if (context.dirty) {
                if (state.frame.running) {
                    assert(state.frame.running);
                    state.frame.request_redraw();
                }
            }
            if (!state.frame.running) {
                assert(!state.frame.running);
                return;
            }
            assert(state.frame.running);
        }
    };
}

/// Connects to the Wayland display socket.
fn connect(state: *State) !void {
    const display = wl_display_connect(null) orelse return error.DisplayConnectFailed;
    state.display = display;
    assert(@intFromPtr(state.display) != 0);
    assert(wl_display_get_fd(display) >= 0);
}

/// Discovers and binds the `wl_compositor` and `xdg_wm_base` globals from the registry.
fn bind_globals(state: *State) !void {
    assert(@intFromPtr(state.display) != 0);
    const registry = get_registry(state.display);
    const add_rc = wl_proxy_add_listener(@ptrCast(registry), &registry_listener, state);
    assert(add_rc == 0);
    const roundtrip_rc = wl_display_roundtrip(state.display);
    if (roundtrip_rc < 0) {
        return error.RegistryRoundtripFailed;
    }
    if (state.compositor == null) {
        return error.MissingCompositor;
    }
    if (state.xdg_base == null) {
        return error.MissingXdgWmBase;
    }
    if (state.cursor_manager == null) {
        std.log.info("cursor: no wp_cursor_shape_v1, the compositor's cursor stays", .{});
    }
}

/// Creates a Wayland surface, wraps it in an `xdg_surface` and `xdg_toplevel` window, and asks
/// for `decorations` (section 5e).
fn create_toplevel(state: *State, title: [:0]const u8, decorations: input.Decorations) !void {
    const compositor = state.compositor orelse return error.MissingCompositor;
    const base = state.xdg_base orelse return error.MissingXdgWmBase;
    const surface = create_surface(compositor);
    state.surface = surface;
    const add_rc = wl_proxy_add_listener(@ptrCast(surface), &surface_listener, state);
    assert(add_rc == 0);
    const xdg_surface = xdg.get_xdg_surface(base, surface);
    state.xdg_surface = xdg_surface;
    xdg.add_wm_base_listener(base, &wm_base_listener, state);
    xdg.add_surface_listener(xdg_surface, &xdg_surface_listener, state);
    const toplevel = xdg.get_toplevel(xdg_surface);
    state.toplevel = toplevel;
    xdg.add_toplevel_listener(toplevel, &toplevel_listener, state);
    xdg.set_title(toplevel, title.ptr);
    xdg.set_app_id(toplevel, "patchwork");
    ask_decorations(state, toplevel, decorations);
    choose_scale_mode(state, surface);
    commit_surface(surface);
    assert(state.surface != null);
    assert(state.toplevel != null);
}

/// Asks the compositor to draw the frame for `.server` when it offers the manager; `.client`
/// creates no decoration object, which leaves the frame to the app (section 5e). Until the
/// compositor answers, the state says `client`.
fn ask_decorations(state: *State, toplevel: *xdg.XdgToplevel, wanted: input.Decorations) void {
    assert(state.decoration == null);
    assert(state.window_pending.decorations == .client);
    const manager = state.decoration_manager orelse {
        std.log.info("decorations: no zxdg_decoration_manager_v1, the app draws its frame", .{});
        return;
    };
    if (wanted == .client) {
        std.log.info("decorations: client asked, none negotiated", .{});
        return;
    }
    const decoration = xdg_decoration.get_decoration(manager, toplevel);
    xdg_decoration.add_listener(decoration, &decoration_listener, state);
    xdg_decoration.set_mode(decoration, xdg_decoration.mode_server_side);
    state.decoration = decoration;
    std.log.info("decorations: server asked", .{});
    assert(state.decoration != null);
}

/// Enters fractional mode when both `wp_fractional_scale_manager_v1` and `wp_viewporter` are
/// bound, else stays on the integer `preferred_buffer_scale`; logs the mode once.
fn choose_scale_mode(state: *State, surface: *WlSurface) void {
    assert(state.viewport == null);
    const manager = state.fractional_manager orelse return log_integer_mode();
    const viewporter = state.viewporter orelse return log_integer_mode();
    state.viewport = wp_fractional_scale.get_viewport(viewporter, surface);
    const fractional = wp_fractional_scale.get_fractional_scale(manager, surface);
    wp_fractional_scale.add_fractional_listener(fractional, &fractional_listener, state);
    std.log.info("scale: fractional (wp_fractional_scale_v1 and wp_viewporter)", .{});
    assert(state.viewport != null);
}

fn log_integer_mode() void {
    std.log.info("scale: integer (wl_surface.preferred_buffer_scale)", .{});
}

/// Initializes the hardware WebGPU device. `Host.setup` then records the renderer's setup
/// stream, which creates every long-lived GPU resource.
fn create_device(state: *State, options: gpu.Options) !void {
    const display = state.display;
    const surface = state.surface orelse return error.MissingSurface;
    state.gpu = try gpu.create(@ptrCast(display), @ptrCast(surface), options);
    assert(state.gpu.configured_width == 0);
    assert(state.gpu.configured_height == 0);
}

/// Acknowledges pending configure serials sent by the compositor.
fn ack_if_needed(state: *State) void {
    if (!state.ack_pending) {
        assert(!state.ack_pending);
        return;
    }
    const xdg_surface = state.xdg_surface orelse return;
    xdg.ack_configure(xdg_surface, state.configure_serial);
    state.frame.apply_configure(state.pending_width, state.pending_height);
    state.ack_pending = false;
    if (!state.configured) log_window(state.window_pending, state.decoration != null);
    state.configured = true;
    // The state the callbacks assembled reaches the app as one event (section 5e).
    if (state.window_pending != state.window_applied) {
        state.window_applied = state.window_pending;
        state.queue.push(.{ .window_state = state.window_applied });
    }
    assert(!state.ack_pending);
}

/// Logs the first configure's window state: the decoration answer when one was asked, the
/// capabilities, and the tiled sides.
fn log_window(window: input.WindowState, asked: bool) void {
    if (asked) std.log.info("decorations: {t} answered", .{window.decorations});
    std.log.info("window: minimize {}, maximize {}, menu {}, tiled {}{}{}{}", .{
        window.can_minimize,
        window.can_maximize,
        window.window_menu,
        @intFromBool(window.tiled_left),
        @intFromBool(window.tiled_right),
        @intFromBool(window.tiled_top),
        @intFromBool(window.tiled_bottom),
    });
}

/// Sends the window request a dispatch left (section 5e). Without a seat the requests that
/// need one are dropped.
fn serve_window(state: *State, request: ui.WindowRequest) void {
    const toplevel = state.toplevel orelse return;
    switch (request) {
        .minimize => xdg.set_minimized(toplevel),
        .toggle_maximize => xdg.set_maximized(toplevel, !state.window_applied.maximized),
        .close => state.frame.close(),
        .move => |serial| {
            const seat = state.seat orelse return;
            xdg.move(toplevel, @ptrCast(seat), serial);
        },
        .resize => |resize| {
            const seat = state.seat orelse return;
            xdg.resize(toplevel, @ptrCast(seat), resize.serial, resize_edge_of(resize.edge));
        },
        .menu => |menu| {
            const seat = state.seat orelse return;
            const x: i32 = @intFromFloat(@round(menu.x));
            const y: i32 = @intFromFloat(@round(menu.y));
            xdg.show_window_menu(toplevel, @ptrCast(seat), menu.serial, x, y);
        },
    }
}

/// The `xdg_toplevel.resize_edge` of an edge part; `none` and `drag` never resize.
fn resize_edge_of(part: ui.WindowPart) xdg.ResizeEdge {
    assert(part != .none and part != .drag);
    return switch (part) {
        .none, .drag => unreachable,
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

/// Requests one frame callback before the commit. `wl_surface.frame` takes effect
/// on the next commit, so this runs before `gpu.submit`. `present_if_dirty`
/// already returned if a callback was in flight; a second one is a bug.
fn arm_frame(state: *State) void {
    assert(state.frame_callback == null);
    assert(state.frame.redraw);
    const surface = state.surface orelse {
        assert(state.surface == null);
        assert(state.frame_callback == null);
        return;
    };
    const callback = wl_callback.request_frame(surface);
    wl_callback.add_callback_listener(callback, &callback_listener, state);
    state.frame_callback = callback;
    assert(state.frame_callback != null);
    assert(state.frame.redraw);
}

/// Requests hardware presentation timing feedback for the upcoming surface commit.
///
/// Preconditions: `state.frame.redraw` must be true.
/// Skipped when `state.presentation == null`, `state.surface == null`, or when
/// `state.feedback_in_flight >= feedback_in_flight_max`. In the skipped case, `schedule_present`
/// continues projecting from the most recent valid anchor.
/// When armed, requests a one-shot `WpPresentationFeedback` proxy, installs `feedback_listener`,
/// and increments `state.feedback_in_flight`.
fn arm_feedback(state: *State) void {
    assert(state.frame.redraw);
    const presentation = state.presentation orelse {
        assert(state.presentation == null);
        return;
    };
    const surface = state.surface orelse {
        assert(state.surface == null);
        return;
    };
    if (state.feedback_in_flight >= feedback_in_flight_max) {
        assert(state.feedback_in_flight == feedback_in_flight_max);
        return;
    }
    const feedback = wp_presentation.request_feedback(presentation, surface);
    wp_presentation.add_feedback_listener(feedback, &feedback_listener, state);
    state.feedback_in_flight += 1;
    assert(state.feedback_in_flight >= 1);
    assert(state.feedback_in_flight <= feedback_in_flight_max);
}

/// Tells the compositor how the next buffer maps onto the surface (module guide, section 2):
/// the viewport destination in fractional mode, the integer buffer scale otherwise.
fn apply_surface_scale(state: *State) void {
    if (state.viewport) |viewport| {
        const width = state.frame.width_logical;
        const height = state.frame.height_logical;
        assert(width != 0);
        if (width != state.destination_width or height != state.destination_height) {
            wp_fractional_scale.set_destination(viewport, width, height);
            state.destination_width = width;
            state.destination_height = height;
        }
        return;
    }
    set_buffer_scale(state);
}

/// Informs the compositor of our integer buffer scale factor (HiDPI fallback mode).
fn set_buffer_scale(state: *State) void {
    const surface = state.surface orelse return;
    assert(state.viewport == null);
    assert(state.frame.scale_120 % 120 == 0);
    const scale = state.frame.scale_120 / 120;
    assert(scale >= 1);
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    if (version < 3) {
        return;
    }
    _ = wl_proxy_marshal_flags(proxy, 8, null, version, 0, @as(i32, @intCast(scale)));
}

/// Blocks in `ppoll` until the socket is readable or the latched commit is due.
/// `EINTR` retries, bounded, without cancelling the prepared read.
fn poll_wayland(state: *State, fds: []std.posix.pollfd) !usize {
    assert(fds.len == slot_count);
    var guard: u32 = 0;
    while (guard < 8) : (guard += 1) {
        var timeout = poll_timeout(state);
        const ready = std.posix.ppoll(
            fds,
            if (timeout) |*spec| spec else null,
            null,
        ) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return error.PollFailed,
        };
        assert(ready <= fds.len);
        return ready;
    }
    return error.PollFailed;
}

/// Remaining time until the latched commit. Null blocks until the compositor writes. Zero
/// while a file transfer runs, so the loop keeps reading (section 5d).
fn poll_timeout(state: *const State) ?std.posix.timespec {
    if (state.clipboard.dnd.busy()) return .{ .sec = 0, .nsec = 0 };
    if (state.present_at_ns == 0) {
        assert(state.present_at_ns == 0);
        return null;
    }
    const now_ns = monotonic_ns();
    if (now_ns >= state.present_at_ns) {
        assert(now_ns >= state.present_at_ns);
        return .{ .sec = 0, .nsec = 0 };
    }
    const remain = state.present_at_ns - now_ns;
    assert(remain <= frame.refresh_ns_max);
    return .{
        .sec = @intCast(remain / 1_000_000_000),
        .nsec = @intCast(remain % 1_000_000_000),
    };
}

/// Arms `fd` to expire every `period_ms` milliseconds, or disarms it when `period_ms` is 0.
fn set_app_timer(fd: i32, period_ms: u32) void {
    assert(fd >= 0);
    assert(period_ms <= app_contract.timer_period_ms_max);
    // Whole seconds go in `tv_sec` so `tv_nsec` stays below one second for any period.
    const period: std.os.linux.timespec = .{
        .sec = @intCast(period_ms / 1000),
        .nsec = @intCast((period_ms % 1000) * 1_000_000),
    };
    assert(period.nsec < 1_000_000_000);
    const spec: std.os.linux.itimerspec = .{
        .it_interval = period,
        .it_value = period,
    };
    const armed = std.os.linux.timerfd_settime(fd, .{}, &spec, null);
    assert(std.os.linux.errno(armed) == .SUCCESS);
}

/// CLOCK_MONOTONIC in nanoseconds. `clock_gettime` of this clock does not fail.
fn monotonic_ns() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    assert(rc == 0);
    assert(ts.sec >= 0);
    assert(ts.nsec >= 0);
    assert(ts.nsec < 1_000_000_000);
    const sec_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000;
    const now_ns = sec_ns + @as(u64, @intCast(ts.nsec));
    assert(now_ns >= sec_ns);
    return now_ns;
}

/// Updates the active refresh period `state.refresh_ns` in nanoseconds.
///
/// Preconditions: `state.refresh_ns` must be within `[frame.refresh_ns_min, frame.refresh_ns_max]`.
/// Prioritizes `state.vblank_refresh_ns` from hardware presentation feedback when valid
/// (`frame.refresh_ns_min <= reported <= frame.refresh_ns_max`). If absent or invalid, calculates
/// the elapsed callback delta `now_ns - state.last_callback_ns` and updates the estimate via
/// `frame.refresh_after`. Doubled gaps from missed latches are ignored.
/// Postconditions: `state.refresh_ns` is asserted within valid bounds, and `last_callback_ns`
/// records `now_ns`.
fn note_refresh(state: *State) void {
    const now_ns = monotonic_ns();
    const reported = state.vblank_refresh_ns;
    const reported_ok = reported >= frame.refresh_ns_min and reported <= frame.refresh_ns_max;
    if (reported_ok) {
        state.refresh_ns = reported;
    } else if (state.last_callback_ns != 0) {
        const delta = now_ns - state.last_callback_ns;
        state.refresh_ns = frame.refresh_after(state.refresh_ns, delta);
    }
    state.last_callback_ns = now_ns;
    assert(state.refresh_ns >= frame.refresh_ns_min);
    assert(state.refresh_ns <= frame.refresh_ns_max);
}

/// Computes the monotonic nanosecond deadline `state.present_at_ns` for the upcoming commit.
///
/// Preconditions: `!state.frame_done`.
/// If no redraw is owed (`!state.frame.redraw`), clears `state.present_at_ns = 0` so the event loop
/// can enter an unbounded sleep.
/// If a redraw is owed, queries `monotonic_ns()` and checks
/// `frame.anchor_is_fresh(state.vblank_ns, now_ns)`.
/// If fresh (age within `frame.anchor_age_max_ns`), projects forward from `state.vblank_ns`.
/// Otherwise anchors on `now_ns`, the receipt time of `wl_callback.done`.
/// Calls `frame.present_deadline(anchor_ns, state.refresh_ns, now_ns, present_margin_ns)`
/// to place the commit `present_margin_ns` before the next achievable vblank.
fn schedule_present(state: *State) void {
    assert(!state.frame_done);
    if (!state.frame.redraw) {
        state.present_at_ns = 0;
        assert(state.present_at_ns == 0);
        return;
    }
    assert(state.refresh_ns > present_margin_ns);
    const now_ns = monotonic_ns();
    var anchor_ns = now_ns;
    if (frame.anchor_is_fresh(state.vblank_ns, now_ns)) {
        anchor_ns = state.vblank_ns;
    }
    state.present_at_ns = frame.present_deadline(
        anchor_ns,
        state.refresh_ns,
        now_ns,
        present_margin_ns,
    );
    assert(state.present_at_ns >= now_ns);
    assert(state.present_at_ns != 0);
}

/// Instantiates a `wl_registry` proxy for discovering server globals.
fn get_registry(display: *Display) *Registry {
    const proxy: *WlProxy = @ptrCast(display);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        1,
        &wl_registry_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Requests a new `wl_surface` from the compositor.
fn create_surface(compositor: *Compositor) *WlSurface {
    const proxy: *WlProxy = @ptrCast(compositor);
    const version = wl_proxy_get_version(proxy);
    const result = wl_proxy_marshal_flags(
        proxy,
        0,
        &wl_surface_interface,
        version,
        0,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Commits pending state changes to the Wayland surface.
fn commit_surface(surface: *WlSurface) void {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 6, null, version, 0);
    assert(version >= 1);
}

/// Binds a named global interface advertised by `wl_registry`.
fn bind_global(
    registry: *Registry,
    name: u32,
    interface: *const WlInterface,
    version: u32,
) *anyopaque {
    const proxy: *WlProxy = @ptrCast(registry);
    const result = wl_proxy_marshal_flags(
        proxy,
        0,
        interface,
        version,
        0,
        name,
        interface.name,
        version,
        @as(?*anyopaque, null),
    );
    assert(result != null);
    return @ptrCast(result.?);
}

/// Callback invoked by libwayland for each global object advertised by the compositor.
fn registry_global(
    data: ?*anyopaque,
    registry: ?*Registry,
    name: u32,
    interface_name: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.global_count += 1;
    assert(state.global_count <= global_cap);
    const iface = std.mem.span(interface_name);
    const live_registry = registry orelse return;
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        const bind_version = if (version < compositor_version_max)
            version
        else
            compositor_version_max;
        const comp = bind_global(live_registry, name, &wl_compositor_interface, bind_version);
        state.compositor = @ptrCast(comp);
        return;
    }
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        const bind_version = @min(version, xdg.wm_base_version_max);
        const interface = &xdg.xdg_wm_base_interface;
        state.xdg_base = @ptrCast(bind_global(live_registry, name, interface, bind_version));
        return;
    }
    if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
        if (state.decoration_manager != null) return;
        const interface = &xdg_decoration.zxdg_decoration_manager_interface;
        state.decoration_manager = @ptrCast(bind_global(live_registry, name, interface, 1));
        return;
    }
    if (std.mem.eql(u8, iface, "wp_presentation")) {
        if (state.presentation != null) {
            return;
        }
        const bind_version = if (version < wp_presentation.presentation_version)
            version
        else
            wp_presentation.presentation_version;
        const bound = bind_global(
            live_registry,
            name,
            &wp_presentation.wp_presentation_interface,
            bind_version,
        );
        const presentation: *wp_presentation.WpPresentation = @ptrCast(bound);
        wp_presentation.add_presentation_listener(presentation, &presentation_listener, state);
        state.presentation = presentation;
        assert(state.presentation != null);
        return;
    }
    if (bind_scale_global(state, live_registry, name, iface)) {
        return;
    }
    if (bind_input_global(state, live_registry, name, iface, version)) {
        return;
    }
}

/// Binds `wl_seat`, `wp_cursor_shape_manager_v1`, or `wl_data_device_manager` when `iface`
/// names one that is not bound yet. True when `iface` was one of them.
fn bind_input_global(
    state: *State,
    registry: *Registry,
    name: u32,
    iface: []const u8,
    version: u32,
) bool {
    if (std.mem.eql(u8, iface, "wl_seat")) {
        if (state.seat != null) return true;
        const bind_version = wl_seat.bind_version(version);
        const bound = bind_global(registry, name, &wl_seat.wl_seat_interface, bind_version);
        const seat: *wl_seat.WlSeat = @ptrCast(bound);
        wl_seat.add_seat_listener(seat, &seat_listener, state);
        state.seat = seat;
        state.clipboard.attach(seat);
        return true;
    }
    if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        if (state.cursor_manager != null) return true;
        const interface = &wp_cursor_shape.wp_cursor_shape_manager_interface;
        state.cursor_manager = @ptrCast(bind_global(registry, name, interface, 1));
        return true;
    }
    if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        if (state.clipboard.manager != null) return true;
        const bind_version = wl_data_device.bind_version(version);
        const interface = &wl_data_device.wl_data_device_manager_interface;
        state.clipboard.manager = @ptrCast(bind_global(registry, name, interface, bind_version));
        if (state.seat) |seat| state.clipboard.attach(seat);
        return true;
    }
    return false;
}

/// Binds `wp_viewporter` or `wp_fractional_scale_manager_v1` (version 1) when `iface` names
/// one that is not bound yet. True when `iface` was one of them.
fn bind_scale_global(state: *State, registry: *Registry, name: u32, iface: []const u8) bool {
    if (std.mem.eql(u8, iface, "wp_viewporter")) {
        if (state.viewporter == null) {
            const bound = bind_global(
                registry,
                name,
                &wp_fractional_scale.wp_viewporter_interface,
                wp_fractional_scale.version,
            );
            state.viewporter = @ptrCast(bound);
        }
        assert(state.viewporter != null);
        return true;
    }
    if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
        if (state.fractional_manager == null) {
            const bound = bind_global(
                registry,
                name,
                &wp_fractional_scale.wp_fractional_scale_manager_interface,
                wp_fractional_scale.version,
            );
            state.fractional_manager = @ptrCast(bound);
        }
        assert(state.fractional_manager != null);
        return true;
    }
    return false;
}

fn registry_global_remove(data: ?*anyopaque, registry: ?*Registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

fn surface_enter(data: ?*anyopaque, surface: ?*WlSurface, output: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

fn surface_leave(data: ?*anyopaque, surface: ?*WlSurface, output: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

/// Callback when the compositor informs the client of the monitor's preferred scale factor.
fn surface_preferred_scale(data: ?*anyopaque, surface: ?*WlSurface, factor: i32) callconv(.c) void {
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    if (state.viewport != null) {
        // Fractional mode: `preferred_scale` is the source of truth (module guide, 2).
        return;
    }
    if (factor <= 0) {
        return;
    }
    if (factor > frame.scale_120_max / 120) {
        state.frame.apply_scale(frame.scale_120_max) catch unreachable;
        return;
    }
    const scale_120: u32 = @as(u32, @intCast(factor)) * 120;
    state.frame.apply_scale(scale_120) catch unreachable;
}

/// `wp_fractional_scale_v1.preferred_scale`: the scale in 1/120 units.
fn fractional_preferred_scale(
    data: ?*anyopaque,
    fractional: ?*wp_fractional_scale.FractionalScale,
    scale_120: u32,
) callconv(.c) void {
    _ = fractional;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    assert(state.viewport != null);
    state.frame.apply_scale(scale_120) catch return;
}

fn surface_preferred_transform(
    data: ?*anyopaque,
    surface: ?*WlSurface,
    transform: u32,
) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = transform;
}

/// Responds to the compositor's heartbeat ping with a pong to verify the UI is responsive.
fn xdg_ping(data: ?*anyopaque, base: ?*xdg.XdgWmBase, serial: u32) callconv(.c) void {
    _ = data;
    const live = base orelse return;
    xdg.pong(live, serial);
}

/// Records the configure serial sent by the compositor.
fn xdg_surface_configure(
    data: ?*anyopaque,
    surface: ?*xdg.XdgSurface,
    serial: u32,
) callconv(.c) void {
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.configure_serial = serial;
    state.ack_pending = true;
}

/// Records the new window dimensions suggested by the window manager, and its states.
fn toplevel_configure(
    data: ?*anyopaque,
    toplevel: ?*xdg.XdgToplevel,
    width: i32,
    height: i32,
    states: ?*xdg.WlArray,
) callconv(.c) void {
    _ = toplevel;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.pending_width = if (width > 0) @intCast(width) else 0;
    state.pending_height = if (height > 0) @intCast(height) else 0;
    state.window_pending = xdg.states_of(state.window_pending, states);
}

/// `xdg_toplevel.configure_bounds` (version 4): unused, the window takes the size it is given.
fn toplevel_configure_bounds(
    data: ?*anyopaque,
    toplevel: ?*xdg.XdgToplevel,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
}

/// `xdg_toplevel.wm_capabilities` (version 5): the requests the compositor honours.
fn toplevel_wm_capabilities(
    data: ?*anyopaque,
    toplevel: ?*xdg.XdgToplevel,
    capabilities: ?*xdg.WlArray,
) callconv(.c) void {
    _ = toplevel;
    const state = state_of(data);
    state.window_pending = xdg.capabilities_of(state.window_pending, capabilities);
}

/// `zxdg_toplevel_decoration_v1.configure`: who draws the frame, as the compositor decided.
fn decoration_configure(
    data: ?*anyopaque,
    decoration: ?*xdg_decoration.Decoration,
    mode: u32,
) callconv(.c) void {
    _ = decoration;
    const state = state_of(data);
    state.window_pending.decorations = xdg_decoration.decorations_of(mode);
}

/// C ABI callback for `wl_seat.capabilities` (opcode 0). Creates or releases the pointer and
/// keyboard proxies as the capabilities come and go.
fn seat_capabilities(
    data: ?*anyopaque,
    seat: ?*wl_seat.WlSeat,
    capabilities: u32,
) callconv(.c) void {
    _ = seat;
    const state = state_of(data);
    const live = state.seat orelse return;
    const has_pointer = (capabilities & wl_seat.pointer_capability) != 0;
    if (has_pointer and state.pointer_proxy == null) {
        const pointer = wl_seat.get_pointer(live);
        wl_seat.add_pointer_listener(pointer, &pointer_listener, state);
        state.pointer_proxy = pointer;
    }
    if (!has_pointer) {
        if (state.pointer_proxy) |pointer| {
            if (state.cursor_device) |device| wp_cursor_shape.destroy_device(device);
            state.cursor_device = null;
            wl_seat.release_pointer(pointer);
            state.pointer_proxy = null;
            state.queue.push(.pointer_leave);
        }
    }
    const has_keyboard = (capabilities & wl_seat.keyboard_capability) != 0;
    if (has_keyboard and state.keyboard_proxy == null) {
        const keyboard = wl_seat.get_keyboard(live);
        wl_seat.add_keyboard_listener(keyboard, &keyboard_listener, state);
        state.keyboard_proxy = keyboard;
    }
    if (!has_keyboard) {
        if (state.keyboard_proxy) |keyboard| {
            wl_seat.release_keyboard(keyboard);
            state.keyboard_proxy = null;
            keyboard_lost(state);
        }
    }
    const has_touch = (capabilities & wl_seat.touch_capability) != 0;
    if (has_touch and state.touch_proxy == null) {
        const touch = wl_seat.get_touch(live);
        wl_seat.add_touch_listener(touch, &touch_listener, state);
        state.touch_proxy = touch;
    }
    if (!has_touch) {
        if (state.touch_proxy) |touch| {
            wl_seat.release_touch(touch);
            state.touch_proxy = null;
            // Every finger is gone with the device.
            state.queue.push(.{ .touch_cancel = null });
        }
    }
    if (has_pointer) assert(state.pointer_proxy != null);
    if (has_keyboard) assert(state.keyboard_proxy != null);
    if (has_touch) assert(state.touch_proxy != null);
}

/// C ABI callback for `wl_touch.down` (opcode 0). Queues the finger with the `down` serial,
/// which `xdg_toplevel.move` accepts, and remembers it as the latest input serial.
fn touch_down(
    data: ?*anyopaque,
    touch: ?*wl_seat.WlTouch,
    serial: u32,
    time: u32,
    surface: ?*xdg.WlSurface,
    id: i32,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = touch;
    _ = surface;
    if (id < 0) return;
    const state = state_of(data);
    state.input_serial = serial;
    state.queue.push(.{ .touch_down = .{
        .id = @intCast(id),
        .x = input.fixed_to_logical(x),
        .y = input.fixed_to_logical(y),
        .time_ms = time,
        .serial = serial,
    } });
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_touch.up` (opcode 1). The lift has no position; the context keeps the
/// finger's last one.
fn touch_up(
    data: ?*anyopaque,
    touch: ?*wl_seat.WlTouch,
    serial: u32,
    time: u32,
    id: i32,
) callconv(.c) void {
    _ = touch;
    _ = serial;
    if (id < 0) return;
    const state = state_of(data);
    state.queue.push(.{ .touch_up = .{ .id = @intCast(id), .time_ms = time } });
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_touch.motion` (opcode 2). The queue keeps the newest sample of each
/// finger (`input.zig`, section 9).
fn touch_motion(
    data: ?*anyopaque,
    touch: ?*wl_seat.WlTouch,
    time: u32,
    id: i32,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = touch;
    if (id < 0) return;
    const state = state_of(data);
    state.queue.push(.{ .touch_move = .{
        .id = @intCast(id),
        .x = input.fixed_to_logical(x),
        .y = input.fixed_to_logical(y),
        .time_ms = time,
    } });
    assert(state.queue.count >= 1);
}

/// `wl_touch.frame` (opcode 3): events stay in order in the queue, so groups are kept.
fn touch_frame(data: ?*anyopaque, touch: ?*wl_seat.WlTouch) callconv(.c) void {
    _ = data;
    _ = touch;
}

/// C ABI callback for `wl_touch.cancel` (opcode 4): the compositor took every finger, for a
/// gesture of its own. It names none, so every contact ends without a click.
fn touch_cancel(data: ?*anyopaque, touch: ?*wl_seat.WlTouch) callconv(.c) void {
    _ = touch;
    const state = state_of(data);
    state.queue.push(.{ .touch_cancel = null });
    assert(state.queue.count >= 1);
}

/// `wl_touch.shape` (opcode 5, version 6): unused.
fn touch_shape(
    data: ?*anyopaque,
    touch: ?*wl_seat.WlTouch,
    id: i32,
    major: i32,
    minor: i32,
) callconv(.c) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = major;
    _ = minor;
}

/// `wl_touch.orientation` (opcode 6, version 6): unused.
fn touch_orientation(
    data: ?*anyopaque,
    touch: ?*wl_seat.WlTouch,
    id: i32,
    orientation: i32,
) callconv(.c) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = orientation;
}

/// `wl_seat.name` (opcode 1, version 2): unused.
fn seat_name(data: ?*anyopaque, seat: ?*wl_seat.WlSeat, name: [*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

fn state_of(data: ?*anyopaque) *State {
    assert(data != null);
    return @ptrCast(@alignCast(data.?));
}

/// C ABI callback for `wl_pointer.enter` (opcode 0). The pointer image is undefined after an
/// enter, so the shape is sent again with this serial.
fn pointer_enter(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    surface: ?*xdg.WlSurface,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = pointer;
    _ = surface;
    const state = state_of(data);
    state.enter_serial = serial;
    state.cursor_applied = null;
    push_move(state, sx, sy);
}

/// C ABI callback for `wl_pointer.leave` (opcode 1). Releases any press so a drag cannot stick.
fn pointer_leave(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    surface: ?*xdg.WlSurface,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    const state = state_of(data);
    state.queue.push(.pointer_leave);
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_pointer.motion` (opcode 2). The commit draws the newest coalesced
/// sample.
fn pointer_motion(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    push_move(state_of(data), sx, sy);
}

/// C ABI callback for `wl_pointer.button` (opcode 3). Queues a press or release of the left,
/// right, or middle button at the last position, with its time and the keyboard modifiers.
fn pointer_button(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    time: u32,
    button: u32,
    button_state: u32,
) callconv(.c) void {
    _ = pointer;
    const state = state_of(data);
    const which: input.MouseButton = switch (button) {
        wl_seat.button_code_left => .left,
        wl_seat.button_code_right => .right,
        wl_seat.button_code_middle => .middle,
        else => return,
    };
    state.input_serial = serial;
    const sample: input.Button = .{
        .x = state.last_x,
        .y = state.last_y,
        .time_ms = time,
        .button = which,
        .mods = state.keyboard.mods(),
        .serial = serial,
    };
    if (button_state == wl_seat.button_state_pressed) {
        state.queue.push(.{ .pointer_down = sample });
    } else {
        state.queue.push(.{ .pointer_up = sample });
    }
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_pointer.axis` (opcode 4). Vertical feeds `dy`, horizontal `dx`; the
/// queue merges both of one frame into one wheel. A zero value is not queued.
fn pointer_axis(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    const delta = input.fixed_to_logical(value);
    if (delta == 0) return;
    const state = state_of(data);
    var wheel: input.Wheel = .{ .x = state.last_x, .y = state.last_y, .dx = 0, .dy = 0 };
    switch (axis) {
        wl_seat.axis_vertical => wheel.dy = delta,
        wl_seat.axis_horizontal => wheel.dx = delta,
        else => return,
    }
    state.queue.push(.{ .wheel = wheel });
    assert(state.queue.count >= 1);
}

/// `wl_pointer.frame` (opcode 5): the queue already groups a frame's axes (wl_seat.zig, 1).
fn pointer_frame(data: ?*anyopaque, pointer: ?*wl_seat.WlPointer) callconv(.c) void {
    _ = data;
    _ = pointer;
}

/// `wl_pointer.axis_source` (opcode 6): unused.
fn pointer_axis_source(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    source: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = source;
}

/// `wl_pointer.axis_stop` (opcode 7): unused, there is no kinetic scrolling.
fn pointer_axis_stop(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    axis: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
}

/// `wl_pointer.axis_discrete` and `axis_value120` (opcodes 8 and 9): the `axis` value already
/// carries the pixel delta.
fn pointer_axis_steps(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    axis: u32,
    steps: i32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = steps;
}

/// Queues a move in UI logical pixels and remembers the point for button events.
fn push_move(state: *State, sx: i32, sy: i32) void {
    const x = input.fixed_to_logical(sx);
    const y = input.fixed_to_logical(sy);
    state.last_x = x;
    state.last_y = y;
    state.queue.push(.{ .pointer_move = .{ .x = x, .y = y } });
    assert(state.last_x == x);
    assert(state.last_y == y);
}

/// `wl_keyboard.keymap` (opcode 0): maps the keymap read-only and private (required from
/// version 7), compiles it, and always closes the fd. A keymap that does not compile keeps the
/// previous one.
fn keyboard_keymap(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    const state = state_of(data);
    defer _ = std.os.linux.close(fd);
    if (format != wl_seat.keymap_format_xkb_v1) return;
    if (size == 0 or size > keymap_size_max) return;
    const mapped = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(mapped);
    // The keymap is NUL-terminated within `size`.
    const length = std.mem.indexOfScalar(u8, mapped, 0) orelse mapped.len;
    if (!state.keyboard.load(mapped[0..length])) {
        std.log.warn("keyboard: the compositor's keymap did not compile", .{});
        return;
    }
    apply_arming(state, state.repeat.stop());
}

/// `wl_keyboard.enter` (opcode 1): the window has keyboard focus. Keys already held are not
/// replayed, as the protocol asks.
fn keyboard_enter(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    serial: u32,
    surface: ?*xdg.WlSurface,
    keys: ?*xdg.WlArray,
) callconv(.c) void {
    _ = keyboard;
    _ = surface;
    _ = keys;
    const state = state_of(data);
    state.input_serial = serial;
    state.queue.push(.{ .window_focus = true });
}

/// `wl_keyboard.leave` (opcode 2): focus left, so repeat stops and held keys are released.
fn keyboard_leave(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    serial: u32,
    surface: ?*xdg.WlSurface,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    keyboard_lost(state_of(data));
}

fn keyboard_lost(state: *State) void {
    apply_arming(state, state.repeat.stop());
    state.queue.push(.{ .window_focus = false });
    assert(state.repeat.code == null);
}

/// `wl_keyboard.key` (opcode 3): translates through xkb, queues the key with its text, and
/// arms or disarms the repeat timer (`input.Repeat`).
fn keyboard_key(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    serial: u32,
    time: u32,
    code: u32,
    key_state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = time;
    const state = state_of(data);
    state.input_serial = serial;
    if (key_state != wl_seat.key_state_pressed) {
        const key = state.keyboard.key_of(code);
        const mods = state.keyboard.mods();
        state.queue.push(.{ .key_up = input.key_press(key, mods, false, "") });
        apply_arming(state, state.repeat.release(code));
        return;
    }
    push_key(state, code, false);
    apply_arming(state, state.repeat.press(code, state.keyboard.repeats(code)));
}

/// Queues one press of `code`: its text rides on the key event, and compose output longer
/// than one event's text follows as `other` presses (`input.next_chunk`).
fn push_key(state: *State, code: u32, repeat: bool) void {
    var typed: xkb.Typed = undefined;
    const key = state.keyboard.press(code, repeat, &typed);
    const mods = state.keyboard.mods();
    const text = typed.text();
    if (text.len == 0) {
        state.queue.push(.{ .key_down = input.key_press(key, mods, repeat, "") });
        return;
    }
    var offset: u32 = 0;
    var first = true;
    var guard: u32 = 0;
    while (offset < text.len and guard < xkb.typed_cap) : (guard += 1) {
        const chunk = input.next_chunk(text, &offset);
        const named: input.Key = if (first) key else .other;
        state.queue.push(.{ .key_down = input.key_press(named, mods, repeat, chunk) });
        first = false;
    }
    assert(offset == text.len);
}

/// `wl_keyboard.modifiers` (opcode 4).
fn keyboard_modifiers(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    state_of(data).keyboard.update_mask(depressed, latched, locked, group);
}

/// `wl_keyboard.repeat_info` (opcode 5, version 4). A rate of 0 disables repeat.
fn keyboard_repeat_info(
    data: ?*anyopaque,
    keyboard: ?*wl_seat.WlKeyboard,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = keyboard;
    const state = state_of(data);
    apply_arming(state, state.repeat.configure(rate, delay));
}

/// Applies an `input.Arming` to the repeat timerfd.
fn apply_arming(state: *State, arming: input.Arming) void {
    assert(state.repeat_fd >= 0);
    const spec: std.os.linux.itimerspec = switch (arming) {
        .keep => return,
        .disarm => .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 0 },
        },
        .arm => |times| .{
            .it_interval = timespec_of(times.interval_ns),
            .it_value = timespec_of(times.delay_ns),
        },
    };
    const rc = std.os.linux.timerfd_settime(state.repeat_fd, .{}, &spec, null);
    assert(std.os.linux.errno(rc) == .SUCCESS);
}

fn timespec_of(ns: u64) std.os.linux.timespec {
    assert(ns >= 1);
    const spec: std.os.linux.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    assert(spec.nsec < 1_000_000_000);
    return spec;
}

/// Sends the cursor shape when it changed or an enter made it undefined. Without the shape
/// protocol nothing is sent (the startup log says so).
fn apply_cursor(state: *State, cursor: ui.Cursor) void {
    if (state.cursor_applied) |applied| {
        if (applied == cursor) return;
    }
    const pointer = state.pointer_proxy orelse return;
    const manager = state.cursor_manager orelse return;
    if (state.enter_serial == 0) return;
    const device = state.cursor_device orelse blk: {
        const created = wp_cursor_shape.get_device(manager, pointer);
        state.cursor_device = created;
        break :blk created;
    };
    wp_cursor_shape.set_shape(device, state.enter_serial, cursor);
    state.cursor_applied = cursor;
    assert(state.cursor_device != null);
}

/// Leaf writer for `wl_callback.done`. Destroys the one-shot proxy and stores the
/// millisecond timestamp. `sync_clock` steps the animators after dispatch returns.
fn frame_done_callback(
    data: ?*anyopaque,
    callback: ?*wl_callback.WlCallback,
    callback_data: u32,
) callconv(.c) void {
    assert(data != null);
    assert(callback != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    const live = callback.?;
    wl_callback.destroy_callback(live);
    state.frame_callback = null;
    state.frame_time_ms = callback_data;
    state.frame_done = true;
    assert(state.frame_callback == null);
    assert(state.frame_done);
}

/// Leaf C ABI callback for `wp_presentation.clock_id` (opcode 0).
///
/// Preconditions: `data != null`.
/// Emitted once by the compositor following the initial global binding.
/// Records `clock_id` into `state.presentation_clock`. Presentation timestamps from
/// `feedback_presented` are accepted only if `clock_id == wp_presentation.clock_monotonic`.
fn presentation_clock_id(
    data: ?*anyopaque,
    presentation: ?*wp_presentation.WpPresentation,
    clock_id: u32,
) callconv(.c) void {
    _ = presentation;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.presentation_clock = clock_id;
    assert(state.presentation_clock == clock_id);
}

/// Leaf C ABI callback for `wp_presentation_feedback.sync_output` (opcode 0).
///
/// Identifies the `wl_output` display proxy to which the committed frame was presented.
/// This application renders into a single window across a primary output; output synchronization
/// is not tracked, making this a deliberate no-op.
fn feedback_sync_output(
    data: ?*anyopaque,
    feedback: ?*wp_presentation.WpPresentationFeedback,
    output: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = feedback;
    _ = output;
}

/// Leaf C ABI callback for `wp_presentation_feedback.presented` (opcode 1).
///
/// Preconditions: `data != null`, `feedback != null`.
/// Protocol destructor: destroys the one-shot proxy via `wp_presentation.destroy_feedback` and
/// decrements `state.feedback_in_flight`.
/// Validates that `state.presentation_clock == wp_presentation.clock_monotonic` and that
/// `tv_nsec < 1_000_000_000`. If valid, assembles the timestamp via `wp_presentation.presented_ns`
/// and stores it in `state.vblank_ns`. Also records `state.vblank_refresh_ns = refresh`.
/// Zero `refresh` indicates a variable refresh rate output and defers cadence tracking to the gap
/// estimator.
/// The `flags` argument is not consulted: the anchor is used whether or not the timestamp
/// came from the hardware clock.
/// Cross-reference: `schedule_present` projects the next commit deadline from `state.vblank_ns`.
fn feedback_presented(
    data: ?*anyopaque,
    feedback: ?*wp_presentation.WpPresentationFeedback,
    tv_sec_hi: u32,
    tv_sec_lo: u32,
    tv_nsec: u32,
    refresh: u32,
    seq_hi: u32,
    seq_lo: u32,
    flags: u32,
) callconv(.c) void {
    _ = seq_hi;
    _ = seq_lo;
    _ = flags;
    assert(data != null);
    assert(feedback != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    wp_presentation.destroy_feedback(feedback.?);
    assert(state.feedback_in_flight >= 1);
    state.feedback_in_flight -= 1;
    if (state.presentation_clock != wp_presentation.clock_monotonic) {
        assert(state.presentation_clock != wp_presentation.clock_monotonic);
        return;
    }
    if (tv_nsec >= 1_000_000_000) {
        assert(tv_nsec >= 1_000_000_000);
        return;
    }
    state.vblank_ns = wp_presentation.presented_ns(tv_sec_hi, tv_sec_lo, tv_nsec);
    state.vblank_refresh_ns = refresh;
    assert(state.vblank_ns != 0);
    assert(state.feedback_in_flight < feedback_in_flight_max);
}

/// Leaf C ABI callback for `wp_presentation_feedback.discarded` (opcode 2).
///
/// Preconditions: `data != null`, `feedback != null`.
/// Protocol destructor: indicates the surface buffer was discarded or superseded before
/// presentation. Destroys the one-shot proxy via `wp_presentation.destroy_feedback` and
/// decrements `state.feedback_in_flight`. Retains existing `vblank_ns` and `vblank_refresh_ns`.
fn feedback_discarded(
    data: ?*anyopaque,
    feedback: ?*wp_presentation.WpPresentationFeedback,
) callconv(.c) void {
    assert(data != null);
    assert(feedback != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    wp_presentation.destroy_feedback(feedback.?);
    assert(state.feedback_in_flight >= 1);
    state.feedback_in_flight -= 1;
    assert(state.feedback_in_flight < feedback_in_flight_max);
}

/// The compositor asks the window to close (its close button, a key binding): the app sees
/// `close_requested` and the loop ends when it does not keep the window open (section 5e).
fn toplevel_close(data: ?*anyopaque, toplevel: ?*xdg.XdgToplevel) callconv(.c) void {
    _ = toplevel;
    const state = state_of(data);
    state.queue.push(.close_requested);
    assert(state.queue.count >= 1);
}

/// Opens `path` for writing, created or truncated, or logs and returns null.
fn open_for_write(path: [:0]const u8) ?i32 {
    const flags: std.os.linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const rc = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        std.debug.print("bench: cannot open {s}\n", .{path});
        return null;
    }
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    return fd;
}

/// Writes all of `bytes`, bounded by `write_retry_max` short writes; an error drops the rest.
fn write_all(fd: i32, bytes: []const u8) void {
    assert(fd >= 0);
    var done: usize = 0;
    var tries: u32 = 0;
    while (done < bytes.len and tries < write_retry_max) : (tries += 1) {
        const rc = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        done += rc;
    }
    assert(done <= bytes.len);
}

const write_retry_max: u32 = 64;

fn microseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

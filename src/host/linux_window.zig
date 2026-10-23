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
//! 2. `wl_display_flush` pushes requests out, then `ppoll` waits on the Wayland fd and the
//!    optional timer fd. A negative descriptor is ignored by `poll`, so an app without a
//!    timer passes `no_timer_fd` and never wakes on ticks.
//! 3. The timeout is null (sleep until the compositor writes) unless a commit is latched in
//!    `State.present_at_ns`, in which case it is the time remaining until that deadline.
//! 4. Cancel-read rule: every successful `prepare_read` must end in `wl_display_read_events`
//!    or `wl_display_cancel_read`. A timer-only wake or timeout cancels; only a readable
//!    socket reads. Skipping the cancel leaves libwayland's read lock held.
//! 5. Timer expirations collapse: `drain_timer` reads one expiration count and calls
//!    `app.timer` once at the current monotonic time, however many periods were missed.
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
//!   `wl_seat.seat_version`, `wp_presentation.presentation_version` (the host binds
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
//! Each iteration runs, in order: `ack_if_needed`, `sync_input`, `sync_clock`,
//! `present_if_dirty`, `wait_for_events`. Callbacks only write `State`; all app calls happen
//! in this order on the main thread.
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
//!   events.
//! - `sync_clock`: runs only after a `wl_callback.done`. It steps animators from the callback
//!   timestamp through `ui.animate`, requests a redraw while a widget keeps animating, resets
//!   the clock when settled, and calls `schedule_present`.
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
//! - `libwayland-client.so.0` is linked dynamically. C callbacks recover `*State` from the
//!   listener user-data pointer and never lay out, draw, or step animators.
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
//! - Only the vertical `wl_pointer.axis` becomes `Event.wheel`; a positive `dy` is added to
//!   the scroll offset by the widgets. The browser host drives app timers with
//!   `setInterval` instead of a `timerfd`, arming nothing when the period is zero.
//!
//! ## 6. TigerStyle Invariants
//! - `State` lives on the stack of `run`; the draw context and renderer are static in
//!   `Host(App)`, because their size follows `App.config.draw`. The loop allocates nothing.
//! - Every loop is bounded: input drain by `input.queue_cap`, `EINTR` retry by a fixed guard.
//! - Wayland callbacks are leaf writers; all app and GPU work happens in the loop body.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const app_contract = @import("../app.zig");
const commands = @import("../gpu/commands.zig");
const frame = @import("../frame.zig");
const gpu = @import("../gpu.zig");
const input = @import("../input.zig");
const renderer = @import("../draw/renderer.zig");
const ui = @import("../ui.zig");
const wl_callback = @import("wl_callback.zig");
const wl_seat = @import("wl_seat.zig");
const wp_fractional_scale = @import("wp_fractional_scale.zig");
const wp_presentation = @import("wp_presentation.zig");
const xdg = @import("xdg_shell.zig");

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
    /// Bound Wayland seat proxy (`wl_seat` version 1) from the compositor registry.
    seat: ?*wl_seat.WlSeat,
    /// Active Wayland pointer proxy (`wl_pointer` version 1) instantiated from `seat`.
    pointer_proxy: ?*wl_seat.WlPointer,
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
};

const seat_listener: wl_seat.SeatListener = .{
    .capabilities = seat_capabilities,
};

const pointer_listener: wl_seat.PointerListener = .{
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
};

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
}

/// Orchestrates the entire Wayland application lifecycle for one app type:
/// 1. Checks the app contract at compile time and initializes `App`.
/// 2. Connects to the Wayland display socket and binds core globals
///    (`wl_compositor`, `xdg_wm_base`).
/// 3. Creates the surface and desktop window (`xdg_surface`, `xdg_toplevel`), titled with
///    `App.config.title`.
/// 4. Initializes the native WebGPU rendering context (`gpu.Gpu`).
/// 5. Records and submits the renderer's setup stream, and confirms the initial state: no
///    batches and `state.frame.relayout` true.
/// 6. Arms the host timer only when `App.config.timer_period_ms` is not zero.
/// 7. Enters the blocking event loop (`Host(App).loop`).
///
/// The window state and the app live on this stack frame. The UI context (with the draw
/// context inside it) and the renderer, whose pools and shadows are sized by `App.config`,
/// are static (`Host(App)`), so a large configuration never grows the stack.
pub fn run(comptime App: type) !void {
    comptime app_contract.check(App);
    const AppHost = Host(App);
    var state: State = .{
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
    };
    AppHost.context.init();
    AppHost.render.init();
    var app: App = undefined;
    App.init(&app, &AppHost.context.draw.textures);
    try connect(&state);
    try bind_globals(&state);
    try create_toplevel(&state, App.config.title);
    try create_device(&state);
    var host: AppHost = .{ .state = &state, .app = &app, .timer_fd = no_timer_fd };
    try host.setup();
    assert(AppHost.context.draw.batch_count == 0);
    assert(state.frame.relayout);
    if (App.config.timer_period_ms != 0) {
        host.timer_fd = try arm_timer(App.config.timer_period_ms);
    }
    defer {
        if (host.timer_fd >= 0) {
            _ = std.os.linux.close(host.timer_fd);
        }
    }
    try host.loop();
}

/// `poll` ignores a negative descriptor, so an app without a timer passes this value in the
/// timer slot of the poll set and the timer is never readable.
const no_timer_fd: i32 = -1;

/// The app-facing half of the native loop. Everything that calls the app contract lives
/// here, so the Wayland and GPU half of this file stays one non-generic compilation.
/// `timer_fd` is `no_timer_fd` when `App.config.timer_period_ms` is 0.
fn Host(comptime App: type) type {
    return struct {
        const Self = @This();
        const Context = app_contract.Context(App);
        const Renderer = renderer.Renderer(Context.DrawContext);

        state: *State,
        app: *App,
        timer_fd: i32,

        /// The app's UI context (pools, areas, pointer state) and renderer. Static so pools
        /// and shadows sized by `App.config` stay off the stack; `run` initializes both in
        /// place.
        var context: Context = undefined;
        var render: Renderer = undefined;

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
            render.frame(&state.commands, &context.draw, .{
                .width_logical = state.frame.width_logical,
                .height_logical = state.frame.height_logical,
                .width_px = state.frame.width_px,
                .height_px = state.frame.height_px,
                .scale_120 = state.frame.scale_120,
            });
            try gpu.submit(&state.gpu, &state.commands);
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
                self.sync_clock();
                try self.present_if_dirty();
                try self.wait_for_events();
            }
            assert(!state.frame.running);
        }

        /// Drains the pointer queue once per wake. A press and a release in the same
        /// Wayland batch stay two events, so a click is not collapsed.
        fn sync_input(self: *Self) void {
            const state = self.state;
            assert(state.frame.running);
            var guard: u32 = 0;
            while (guard < input.queue_cap) : (guard += 1) {
                const event = state.queue.pop() orelse break;
                ui.dispatch(App, self.app, &context, event);
                if (context.dirty) {
                    state.frame.request_redraw();
                }
            }
            assert(guard <= input.queue_cap);
            assert(state.frame.running);
        }

        /// Steps animators from the frame-callback timestamp. The first sample after
        /// idle has dt 0, so a hover pays one frame before it moves. A live app
        /// requests another present even when this step did not move a value. If a
        /// redraw is owed, the commit is scheduled just before the next refresh so
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
            const animating = ui.animate(App, self.app, &context, dt_ms);
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
            self.prepare_app();
            apply_surface_scale(state);
            // Both requests attach to the next commit, and `gpu.submit` is that commit.
            arm_frame(state);
            arm_feedback(state);
            try self.submit_frame();
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
            _ = ui.draw_frame(
                App,
                self.app,
                &context,
                state.frame.width_logical,
                state.frame.height_logical,
                scale_120,
            );
            assert(context.draw.text.drawn_scale_120 == scale_120);
        }

        /// Blocks until the compositor writes, the app timer fires, or the latched
        /// commit is due. A timer-only wake cancels the prepared Wayland read.
        /// Idle, with no latched commit, passes a null timeout to `ppoll`.
        fn wait_for_events(self: *Self) !void {
            const state = self.state;
            const display = state.display;
            assert(@intFromPtr(display) != 0);
            assert(wl_display_get_fd(display) >= 0);
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
            var fds = [_]std.posix.pollfd{
                .{
                    .fd = wl_display_get_fd(display),
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
                .{
                    .fd = self.timer_fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };
            const ready = poll_wayland(state, fds[0..]) catch {
                wl_display_cancel_read(display);
                return error.PollFailed;
            };
            if (ready == 0) {
                wl_display_cancel_read(display);
                assert(state.present_at_ns != 0);
                return;
            }
            const wayland_ready = (fds[0].revents & std.posix.POLL.IN) != 0;
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
            const timer_ready = (fds[1].revents & std.posix.POLL.IN) != 0;
            if (timer_ready) {
                try self.drain_timer();
            }
            // A close event read above stops the loop. That wake is not a failure.
            if (!state.frame.running) {
                assert(!state.frame.running);
                return;
            }
            assert(state.frame.running);
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
}

/// Creates a Wayland surface, wraps it in an `xdg_surface` and `xdg_toplevel` window.
fn create_toplevel(state: *State, title: [:0]const u8) !void {
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
    choose_scale_mode(state, surface);
    commit_surface(surface);
    assert(state.surface != null);
    assert(state.toplevel != null);
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
fn create_device(state: *State) !void {
    const display = state.display;
    const surface = state.surface orelse return error.MissingSurface;
    state.gpu = try gpu.create(@ptrCast(display), @ptrCast(surface));
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
    assert(!state.ack_pending);
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
    assert(fds.len == 2);
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

/// Remaining time until the latched commit. Null blocks until the compositor writes.
fn poll_timeout(state: *const State) ?std.posix.timespec {
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

/// Opens a nonblocking `timerfd` on `CLOCK_MONOTONIC` and arms one period of `period_ms`
/// milliseconds. The caller closes the returned fd.
fn arm_timer(period_ms: u32) !i32 {
    assert(period_ms != 0);
    assert(period_ms <= app_contract.timer_period_ms_max);
    const flags: std.os.linux.TFD = .{ .NONBLOCK = true, .CLOEXEC = true };
    const created = std.os.linux.timerfd_create(.MONOTONIC, flags);
    const fd: i32 = switch (std.os.linux.errno(created)) {
        .SUCCESS => @intCast(created),
        else => return error.TimerCreateFailed,
    };
    assert(fd >= 0);
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
    switch (std.os.linux.errno(armed)) {
        .SUCCESS => {},
        else => {
            _ = std.os.linux.close(fd);
            return error.TimerArmFailed;
        },
    }
    assert(fd >= 0);
    return fd;
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
        state.xdg_base = @ptrCast(bind_global(live_registry, name, &xdg.xdg_wm_base_interface, 1));
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
    if (std.mem.eql(u8, iface, "wl_seat")) {
        if (state.seat != null) {
            return;
        }
        if (version < wl_seat.seat_version) {
            return;
        }
        const bound = bind_global(
            live_registry,
            name,
            &wl_seat.wl_seat_interface,
            wl_seat.seat_version,
        );
        const seat: *wl_seat.WlSeat = @ptrCast(bound);
        wl_seat.add_seat_listener(seat, &seat_listener, state);
        state.seat = seat;
        assert(state.seat != null);
    }
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

/// Records the new window dimensions suggested by the window manager.
fn toplevel_configure(
    data: ?*anyopaque,
    toplevel: ?*xdg.XdgToplevel,
    width: i32,
    height: i32,
    states: ?*xdg.WlArray,
) callconv(.c) void {
    _ = toplevel;
    _ = states;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.pending_width = if (width > 0) @intCast(width) else 0;
    state.pending_height = if (height > 0) @intCast(height) else 0;
}

/// C ABI callback for `wl_seat.capabilities` (opcode 0).
/// Dynamically creates or destroys the `wl_pointer` proxy based on `pointer_capability`.
fn seat_capabilities(
    data: ?*anyopaque,
    seat: ?*wl_seat.WlSeat,
    capabilities: u32,
) callconv(.c) void {
    _ = seat;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    const has_pointer = (capabilities & wl_seat.pointer_capability) != 0;
    if (has_pointer) {
        if (state.pointer_proxy == null) {
            const live = state.seat orelse return;
            const pointer = wl_seat.get_pointer(live);
            wl_seat.add_pointer_listener(pointer, &pointer_listener, state);
            state.pointer_proxy = pointer;
        }
        assert(state.pointer_proxy != null);
        return;
    }
    const pointer = state.pointer_proxy orelse return;
    wl_seat.destroy_pointer(pointer);
    state.pointer_proxy = null;
    state.queue.push(.pointer_leave);
    assert(state.pointer_proxy == null);
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_pointer.enter` (opcode 0).
/// Marks pointer as inside the window surface at logical position `(sx, sy)`.
fn pointer_enter(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    surface: ?*xdg.WlSurface,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    push_move(state, sx, sy);
}

/// C ABI callback for `wl_pointer.leave` (opcode 1).
/// Marks pointer as outside surface and resets button state to prevent stuck drags.
fn pointer_leave(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    surface: ?*xdg.WlSurface,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.queue.push(.pointer_leave);
    assert(state.queue.count >= 1);
}

/// C ABI callback for `wl_pointer.motion` (opcode 2).
/// Queues the raw point. The commit draws the newest coalesced sample.
fn pointer_motion(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    sx: i32,
    sy: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    push_move(state, sx, sy);
}

/// C ABI callback for `wl_pointer.button` (opcode 3).
/// Queues press and release of the primary button (`wl_seat.button_code_left`) at the last
/// pointer position. Other buttons are ignored.
fn pointer_button(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    serial: u32,
    time: u32,
    button: u32,
    button_state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = time;
    assert(data != null);
    if (button != wl_seat.button_code_left) {
        assert(button != wl_seat.button_code_left);
        return;
    }
    const state: *State = @ptrCast(@alignCast(data.?));
    const point: input.Point = .{ .x = state.last_x, .y = state.last_y };
    const pressed = button_state == wl_seat.button_state_pressed;
    if (pressed) {
        state.queue.push(.{ .pointer_down = point });
    } else {
        state.queue.push(.{ .pointer_up = point });
    }
    assert(state.queue.count >= 1);
    assert(point.x == state.last_x);
}

/// Vertical `wl_pointer.axis`. Opcode 4, axis 0. Horizontal axes are ignored.
/// A zero value is not queued. Positive `dy` increases `scroll_y`.
const axis_vertical: u32 = 0;

fn pointer_axis(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = pointer;
    _ = time;
    assert(data != null);
    if (axis != axis_vertical) {
        assert(axis != axis_vertical);
        return;
    }
    const dy = input.fixed_to_logical(value);
    if (dy == 0) {
        assert(dy == 0);
        return;
    }
    const state: *State = @ptrCast(@alignCast(data.?));
    state.queue.push(.{ .wheel = .{
        .x = state.last_x,
        .y = state.last_y,
        .dy = dy,
    } });
    assert(state.queue.count >= 1);
    assert(dy != 0);
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

/// Callback when the user clicks the window close button.
fn toplevel_close(data: ?*anyopaque, toplevel: ?*xdg.XdgToplevel) callconv(.c) void {
    _ = toplevel;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    if (state.frame.running) {
        state.frame.close();
    }
}

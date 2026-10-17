//! Linux Wayland Windowing, Event Loop, and Graphics Integration.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale ("Why")
//! On modern Linux desktop environments, display serving and window management are governed by
//! the **Wayland** protocol (superseding legacy X11).
//!
//! ### Architectural Principles of Wayland:
//! - **The Compositor as Authority:** The compositor (e.g. Hyprland, Sway, GNOME Mutter, KDE KWin)
//!   acts as the display server, directly controlling video outputs, graphics page-flipping,
//!   and kernel input devices (libinput mice, keyboards, touchpads).
//! - **Client Pixel Ownership:** The client connects to the compositor via a Unix domain socket
//!   (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, typically `/run/user/1000/wayland-0`). Unlike X11,
//!   Wayland provides no server-side drawing primitives; clients render complete pixel buffers
//!   (via WebGPU or shared memory) and attach them to a `wl_surface`.
//! - **Compositor-Dictated Sizing:** The compositor—not the client—dictates window sizes through
//!   asynchronous configure transactions.
//!
//! ### The Dual-Source Blocking Event Loop & Timerfd Clock:
//! Many UI toolkits run continuous rendering loops or spin threads, wasting battery and warming
//! devices. Patchwork implements the libwayland multi-thread reader protocol integrated with a
//! Linux `timerfd` for procedural level bars:
//! 1. Before entering the loop, `timerfd_create(CLOCK_MONOTONIC, CLOEXEC|NONBLOCK)` opens a timer
//!    file descriptor armed relatively with `period_ns` (33 ms) for both interval and initial
//!    value, closed on scope exit with `defer`.
//! 2. `wl_display_prepare_read()`: Atomically registers intent to read socket events. If events
//!    are already pending (`rc != 0`), it dispatches pending events and immediately drains the
//!    timer (`drain_meter`) so a busy Wayland socket cannot starve procedural metering.
//! 3. `wl_display_flush()`: Flushes pending client requests across the Unix socket.
//! 4. `ppoll` over two descriptors: `fds[0]` is the Wayland socket, and `fds[1]` is `meter_fd`.
//!    The timeout is null unless a commit is latched (`present_at_ns != 0`), sleeping until an
//!    event arrives or the present deadline is due.
//! 5. **The Cancel-Read Rule:** A timer-only wake must NOT call `wl_display_read_events`.
//!    If `fds[0]` is readable, `wl_display_read_events` reads incoming bytes into libwayland's
//!    ring buffers and dispatches callbacks. If `fds[0]` is NOT readable (a timer-only wake or
//!    timeout), the thread cancels the prepared read via `wl_display_cancel_read`.
//! 6. When `meter_fd` is readable, `drain_meter` reads one `u64` expiration count and discards it.
//!    Multiple missed periods collapse into one sample at `CLOCK_MONOTONIC`, requesting redraw.
//! 7. **CPU Profile & Idle Characterization:** The previous "0.0% CPU while idle" claim is no
//!    longer true while the rack is open. Instead, the thread sleeps in `ppoll` and wakes about
//!    30 times a second for the meter timer, plus Wayland events and the present latch. Hover
//!    animators still do not chain their own loop. Steady state is one present per timer wake,
//!    then sleep in `ppoll`. This is not a spin, and it is not 0% CPU.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! - **UI Logical Pixels:** Screen-space coordinates with origin `(0, 0)` at the top-left, `+X`
//!   right, and `+Y` down.
//! - **Physical Device Pixels:** The actual pixel resolution of the GPU swapchain framebuffer
//!   texture:
//!   ```text
//!   width_px  = width_logical  * scale
//!   height_px = height_logical * scale
//!   ```
//!
//! ### Wayland Signed 24.8 Fixed-Point (`wl_fixed_t`):
//! - Pointer motion delivered by `wl_pointer` uses 24.8 signed fixed-point integers.
//! - Conversion to logical pixels:
//!   ```text
//!   logical = @as(f32, @floatFromInt(fixed)) / 256.0
//!   ```
//! - By Wayland specification, surface coordinates are strictly invariant to `set_buffer_scale`,
//!   matching the logical pixel frame of `turtle` and `scene`.
//!
//! ## 3. Hardware, Spec Limits, and C ABI Layouts
//!
//! ### C ABI Callbacks and Listeners:
//! - `RegistryListener`: 2 function pointers (16 bytes, alignment 8).
//! - `SurfaceListener`: 4 function pointers (32 bytes, alignment 8).
//! - `SeatListener`: 1 function pointer (8 bytes, alignment 8). Bound to `wl_seat` version 1.
//! - `PointerListener`: 5 function pointers (40 bytes, alignment 8). Bound to `wl_pointer` v1.
//! - `CallbackListener`: 1 function pointer (8 bytes, alignment 8). For `wl_callback` opcode 0.
//! - `PresentationListener`: 1 function pointer (8 bytes, alignment 8). `wp_presentation.clock_id`.
//! - `FeedbackListener`: 3 function pointers (24 bytes, alignment 8). Opcodes 0..2 for
//!   `sync_output`, `presented`, and `discarded`.
//!
//! ### Pinned Limits:
//! - `global_cap = 256`: Maximum compositor globals scanned during registry roundtrip.
//! - `compositor_version_max = 6`: Pinned maximum version of `wl_compositor`.
//! - `seat_version = 1`: Guarantees compositor emits opcodes 0..4 only, preventing overrun.
//! - `wp_presentation` is bound at `min(advertised, 2)`.
//! - `feedback_in_flight_max = 4`: Most `wp_presentation_feedback` proxies awaiting an answer.
//!   Steady state is two. A commit that would exceed the bound requests no feedback.
//! - `present_margin_ns = 3 ms` (3_000_000 ns): Dispatch margin prior to projected display vblank.
//!   Guarantees the commit completes before Hyprland's ~2 ms pre-vblank latch point.
//!
//! ## 4. State Machines & Data Flow
//!
//! ### The Strict Main Loop Order:
//! In `loop()`, the execution order is strictly deterministic:
//! ```text
//! 1. ack_if_needed(state)
//! 2. sync_input(state)
//! 3. sync_clock(state)
//! 4. present_if_dirty(state)
//! 5. wait_for_events(state.display)
//! ```
//!
//! ### Loop Stage Details:
//! 1. **`ack_if_needed` (Configure-Acknowledge State Machine):**
//!    If an `xdg_surface.configure(serial)` was received, sends `xdg_surface.ack_configure(serial)`
//!    and updates window dimensions via `frame.apply_configure()`.
//! 2. **`sync_input` (Pointer Event Draining):**
//!    Wayland pointer callbacks (`pointer_motion`, `pointer_button`) are pure leaf writers that
//!    push `input.Event` records into `state.queue: input.EventQueue`. Motion events are coalesced.
//!    `sync_input` drains this queue once per wake, feeding `scene.handle_event(event)`. If widget
//!    state changes, it flags `frame.request_redraw()`.
//! 3. **`sync_clock` (Frame Timing Synchronization):**
//!    When `wl_callback.done` fires, `frame_done_callback` records the timestamp and sets
//!    `frame_done`.
//!    `sync_clock` passes this timestamp to `clock.advance(now_ms)`. If animators move, or any
//!    animator is still live, it requests a redraw. A `done` with `redraw` set schedules the
//!    commit 3 ms before the next vblank (`schedule_present`). That vblank is projected from
//!    the last `wp_presentation.presented` pageflip (`frame.present_deadline`):
//!    ```text
//!    earliest = now + margin
//!    k        = ceil((earliest - anchor) / refresh)   (0 if anchor >= earliest)
//!    vblank   = anchor + k * refresh
//!    deadline = vblank - margin
//!    ```
//!    Because the anchor is the pageflip itself, whatever the compositor or the driver does
//!    between pageflip and `done` cannot move the deadline. When no fresh pageflip is known
//!    (no `wp_presentation`, a non-monotonic compositor clock, or older than `anchor_age_max_ns`
//!    = 1 s), the `done` receipt is the anchor and the rule reduces to `done + refresh - 3 ms`.
//!    The period is the one `presented` reports; without one, callback gaps are snapped to a
//!    known rate and a doubled gap is ignored. The commit draws the pointer sample that has
//!    arrived by the deadline. If all animators have settled, `clock.reset()` is called.
//! 4. **`present_if_dirty` (Conditional Presentation & Frame Callback Request):**
//!    - Early returns if clean (`!frame.redraw`) or unconfigured (`width_px == 0`).
//!    - If a frame callback is in flight, or the late-latch deadline has not arrived, leaves
//!      `redraw` set and returns. Layout and the instance rebuild wait for the commit.
//!    - If `frame.relayout` is true, calls `scene.layout()`, re-dispatching pointer hover.
//!    - If `scene.dirty` is true, calls `scene.draw()` to rebuild the 64-byte instance list.
//!    - **Frame Callback Request:** Every commit requests `wl_surface.frame` immediately before
//!      `gpu.present()`, and only while `state.frame_callback == null`. A `done` with nothing
//!      dirty arms nothing.
//!    - **Presentation Feedback Request:** Every commit also requests
//!      `wp_presentation.feedback` (bounded by `feedback_in_flight_max`). Its `presented`
//!      event is the pageflip timestamp the next schedule anchors on.
//!    - Invokes `gpu.present()` and marks cursor and frame clean.
//! 5. **`wait_for_events` (Sleep & Dual-Source Wake):**
//!    Flushes the socket and blocks in `ppoll` across two file descriptors (`fds[0]` Wayland
//!    socket, `fds[1]` meter `timerfd`). The timeout is null unless a commit is latched.
//!    - If a timeout occurs, cancels the prepared read and returns to present.
//!    - If `fds[0]` is readable, calls `wl_display_read_events` and dispatches pending events.
//!    - **Cancel-Read Rule:** If `fds[0]` is not readable, cancels the prepared read via
//!      `wl_display_cancel_read` to avoid blocking on an unreadable socket.
//!    - If `fds[1]` is readable, `drain_meter` reads the 8-byte expiration counter, samples
//!      `levels.sample(now_ms)`, and flags redraw if levels changed.
//!    - Early return path: if `prepare_read` fails because events are pending, dispatches them
//!      and immediately drains `meter_fd` to prevent meter starvation.
//!    - Steady state is one present per timer wake, then sleep in `ppoll`.
//!
//! ### Measured Cadence on Hyprland 0.56.2 / Mesa 26.2.2 (3840x2160@60 Hz, 6-8 s hover sweep):
//! Hyprland latches client content about 2 ms before the vblank and pageflips at the vblank.
//! Commits dispatched 3 ms before the projected vblank reach the screen in 2.6-2.7 ms (median),
//! and `wl_callback.done` arrives ~0.35 ms after the pageflip (p95 0.55 ms).
//!
//! Pacing mode comparison:
//! - FIFO (`wp_fifo_v1`): Mesa issues two commits per present (attach, set_barrier, wait_barrier,
//!   commit, wait_barrier, commit). The held second commit causes every other `done` to arrive
//!   one refresh late, yielding 105 one-period vs 89 two-period gaps in alternating pairs
//!   and holes.
//! - Mailbox (single attach and commit per present): In a 6 s hover sweep, yielded 267 one-period
//!   vs 3 two-period gaps. In an 8 s hover sweep over 377 presents, yielded 348 one-period vs 7
//!   two-period gaps, with zero scheduled commits shown later than their targeted vblank.
//! - Presentation feedback: Observed flags = 0x5 (`vsync | hw_completion`, no `hw_clock`),
//!   reported refresh = 16666666 ns, and `clock_id` = `CLOCK_MONOTONIC` (1). The 1 s anchor
//!   freshness limit (`anchor_age_max_ns`) never engaged during continuous sweeps.
//!
//! ## 5. Cross-Platform Seams & FFI
//! - **libwayland-client FFI:** Dynamically linked against `libwayland-client.so.0`. Direct
//!   C calling convention callbacks (`callconv(.c)`) recover `*State` from user data pointers.
//! - **wgpu-native Graphics:** Passes `display` and `wl_surface` pointers to `gpu.create()` to
//!   instantiate an XDG-Wayland WebGPU surface, swapchain, and pipeline.
//! - **Two clients on one socket:** Mesa's Wayland WSI binds its own `wp_presentation`,
//!   `wp_fifo_v1`, and `linux-drm-syncobj` globals through a wrapped display on a private
//!   event queue. Its requests interleave with ours on the wire, which is why the present
//!   mode matters to our frame callback: under FIFO the driver's barrier-held second commit
//!   carries our `wl_surface.frame` with it.
//! - **Clock domain:** `presented` timestamps are compared to `clock_gettime(CLOCK_MONOTONIC)`
//!   only after `wp_presentation.clock_id` has named that clock (`CLOCK_MONOTONIC` is 1 on Linux).
//!   Any other clock disables the vblank anchor, causing the scheduler to fall back to `done`.
//! - **Wayland Pointer Axis Seam:** Vertical wheel scrolling arrives via `wl_pointer.axis`
//!   (opcode 4). Only vertical axis 0 is processed; horizontal axes are ignored. Values arrive
//!   as `wl_fixed_t` (signed 24.8) and are converted to UI logical pixels via
//!   `input.fixed_to_logical`. Non-zero deltas are paired with `state.last_x` / `state.last_y`
//!   and pushed onto `EventQueue` as `Event.wheel`. Positive `dy` increases `scroll_y`
//!   (scrolls content downward).
//! - **Timerfd Wake Seam:** Linux drives level bars via `timerfd_create` and `ppoll` on the main
//!   thread, whereas the browser host uses `setInterval` calling `wasm.meter_clock()`.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Allocation:** `State` is stack-allocated in `run()`; zero heap allocations in loop.
//! - **Split Defensive Assertions:** Assertions check versions, return codes, and bounds.
//! - **Leaf Callbacks:** Wayland C callbacks perform zero rendering, layout, or animator math.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("animator.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");
const input = @import("input.zig");
const levels = @import("levels.zig");
const scene = @import("scene.zig");
const wl_callback = @import("wl_callback.zig");
const wl_seat = @import("wl_seat.zig");
const wp_presentation = @import("wp_presentation.zig");
const xdg = @import("xdg_shell.zig");

/// First refresh guess, re-exported for `main`. 60 Hz in nanoseconds.
pub const refresh_ns_initial: u64 = frame.refresh_ns_initial;
/// Commit this many nanoseconds before the next callback is due, so the sample
/// includes pointer motion from the rest of the frame. `ppoll` sleeps until that
/// instant. A millisecond timeout was coarse enough to miss the latch.
const present_margin_ns: u64 = 3_000_000;

/// Maximum concurrent `wp_presentation_feedback` proxies allowed in flight.
/// Two is the steady state: the feedback for the frame currently on screen arrives after the
/// subsequent commit has already been dispatched. If a compositor stops responding, further
/// feedback requests are suppressed once this bound is reached to guarantee bounded memory.
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
    list: draw.DrawList,
    glyphs: font.GlyphList,
    cursor: draw.UploadCursor,
    /// Retained widgets. Hover and slider value live here, not on the draw list.
    scene: scene.Scene,
    /// Host timestamps from `wl_callback.done`. Reset when no animator is live.
    clock: animator.Clock,
    /// Pointer events queued by callbacks and drained once per wake.
    queue: input.EventQueue,
    /// `timerfd` for the rack bars. Negative until `arm_meter_timer`.
    meter_fd: i32,
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
    /// Refresh period in use. From `wp_presentation` when it reports one, otherwise
    /// measured from frame-callback gaps. The first guess is 60 Hz.
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
    /// Number of active `WpPresentationFeedback` proxies currently awaiting an event.
    /// Bounded by `feedback_in_flight_max` (4).
    feedback_in_flight: u32,
    /// Bound Wayland seat proxy (`wl_seat` version 1) from the compositor registry.
    seat: ?*wl_seat.WlSeat,
    /// Active Wayland pointer proxy (`wl_pointer` version 1) instantiated from `seat`.
    pointer_proxy: ?*wl_seat.WlPointer,
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

const feedback_listener: wp_presentation.FeedbackListener = .{
    .sync_output = feedback_sync_output,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

/// Orchestrates the entire Wayland application lifecycle:
/// 1. Connects to the Wayland display socket and binds core globals
///    (`wl_compositor`, `xdg_wm_base`).
/// 2. Creates the surface and desktop window (`xdg_surface`, `xdg_toplevel`).
/// 3. Initializes the native WebGPU rendering context (`gpu.Gpu`).
/// 4. Confirms initial state: draw list is empty (`state.list.count == 0`) and
///    `state.frame.relayout` is true.
/// 5. Enters the blocking event loop (`loop`).
pub fn run(state: *State) !void {
    try connect(state);
    try bind_globals(state);
    try create_toplevel(state);
    try create_device(state);
    assert(state.list.count == 0);
    assert(state.frame.relayout);
    state.meter_fd = try arm_meter_timer();
    defer {
        assert(state.meter_fd >= 0);
        _ = std.os.linux.close(state.meter_fd);
    }
    try loop(state);
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
fn create_toplevel(state: *State) !void {
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
    xdg.set_title(toplevel, "patchwork");
    xdg.set_app_id(toplevel, "patchwork");
    commit_surface(surface);
    assert(state.surface != null);
    assert(state.toplevel != null);
}

/// Initializes the hardware WebGPU device and creates native rendering resources.
fn create_device(state: *State) !void {
    const display = state.display;
    const surface = state.surface orelse return error.MissingSurface;
    state.gpu = try gpu.create(@ptrCast(display), @ptrCast(surface));
    assert(state.gpu.configured_width == 0);
    assert(state.gpu.configured_height == 0);
}

/// Blocking loop. Callbacks only write the queue and the frame-done flag.
/// Order is ack, drain input, step the clock, present if due, then sleep in poll.
/// A commit arms `wl_surface.frame`. The next commit waits until just before the
/// following refresh. A `done` with nothing dirty arms nothing, so poll blocks.
fn loop(state: *State) !void {
    assert(@intFromPtr(state.display) != 0);
    while (state.frame.running) {
        ack_if_needed(state);
        sync_input(state);
        sync_clock(state);
        try present_if_dirty(state);
        try wait_for_events(state);
    }
    assert(!state.frame.running);
}

/// Drains the pointer queue once per wake. A press and a release in the same
/// Wayland batch stay two events, so a click is not collapsed.
fn sync_input(state: *State) void {
    assert(state.frame.running);
    var guard: u32 = 0;
    while (guard < input.queue_cap) : (guard += 1) {
        const event = state.queue.pop() orelse break;
        if (state.scene.handle_event(event)) {
            state.frame.request_redraw();
        }
    }
    assert(guard <= input.queue_cap);
    assert(state.frame.running);
}

/// Steps animators from the frame-callback timestamp. The first sample after
/// idle has dt 0, so a hover pays one frame before it moves. A live scene
/// requests another present even when this step did not move a value. If a
/// redraw is owed, the commit is scheduled just before the next refresh so
/// pointer motion during the wait is included. A settled scene resets the clock.
fn sync_clock(state: *State) void {
    if (!state.frame_done) {
        assert(!state.frame_done);
        return;
    }
    state.frame_done = false;
    note_refresh(state);
    const dt_ms = state.clock.advance(state.frame_time_ms);
    const changed = state.scene.handle_event(.{ .frame = dt_ms });
    if (changed) {
        state.frame.request_redraw();
    }
    if (state.scene.live()) {
        state.frame.request_redraw();
    }
    if (!state.scene.live()) {
        state.clock.reset();
    }
    schedule_present(state);
    assert(!state.frame_done);
    assert(state.frame.running);
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

/// Presents when `redraw` is set, no frame callback is in flight, and the
/// late-latch deadline has arrived. A callback already in flight, or a deadline
/// still in the future, leaves `redraw` set so pointer motion during the wait
/// is in the queue when the commit runs. Layout and the instance rebuild run
/// only on that commit. A scale-only present uploads nothing. Every commit
/// arms `wl_surface.frame`.
fn present_if_dirty(state: *State) !void {
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
    prepare_scene(state);
    set_buffer_scale(state);
    // Both requests attach to the next commit, and `gpu.present` is that commit.
    arm_frame(state);
    arm_feedback(state);
    try submit_frame(state);
}

/// Prepares scene layout and draw lists before presentation.
/// Runs layout if `relayout` is set, and repopulates `DrawList` and `GlyphList` if `dirty` is set.
fn prepare_scene(state: *State) void {
    if (state.frame.relayout) {
        state.scene.layout(state.frame.width_logical, state.frame.height_logical);
        state.frame.mark_laid_out();
    }
    assert(!state.frame.relayout);
    if (state.scene.dirty) {
        state.scene.draw(&state.list, &state.glyphs);
    }
    assert(!state.scene.dirty);
}

/// Populates 104-byte `PresentHeader` and submits quad face and glyph lists to the GPU.
/// Updates the upload cursor with newly presented revisions and marks the frame presented.
fn submit_frame(state: *State) !void {
    assert(state.frame.redraw);
    assert(state.frame.width_px != 0);
    var header: draw.PresentHeader = undefined;
    draw.fill_header(&header, .{
        .list = &state.list,
        .glyphs = &state.glyphs,
        .cursor = state.cursor,
        .width_logical = state.frame.width_logical,
        .height_logical = state.frame.height_logical,
        .width_px = state.frame.width_px,
        .height_px = state.frame.height_px,
        .clear_r = gpu.clear_color.r,
        .clear_g = gpu.clear_color.g,
        .clear_b = gpu.clear_color.b,
        .clear_a = gpu.clear_color.a,
    });
    try gpu.present(&state.gpu, &header, &state.list.items, &state.glyphs.items);
    state.cursor.mark(
        &state.list,
        &state.glyphs,
        state.frame.width_logical,
        state.frame.height_logical,
    );
    state.frame.mark_presented();
    assert(!state.frame.redraw);
    assert(!state.scene.dirty);
}

/// Requests one frame callback before the commit. `wl_surface.frame` takes effect
/// on the next commit, so this runs before `gpu.present`. `present_if_dirty`
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
/// When armed, allocates a one-shot `WpPresentationFeedback` proxy, installs `feedback_listener`,
/// and increments `state.feedback_in_flight` (steady state is 2, ceiling is 4).
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

/// Informs the compositor of our buffer scale factor (HiDPI scaling).
fn set_buffer_scale(state: *State) void {
    const surface = state.surface orelse return;
    const scale = state.frame.scale;
    assert(scale >= 1);
    assert(scale <= frame.scale_max);
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    if (version < 3) {
        return;
    }
    _ = wl_proxy_marshal_flags(proxy, 8, null, version, 0, @as(i32, @intCast(scale)));
}

/// Blocks until the compositor writes, the meter timer fires, or the latched
/// commit is due. A timer-only wake cancels the prepared Wayland read.
/// Idle, with no latched commit, passes a null timeout to `ppoll`.
fn wait_for_events(state: *State) !void {
    const display = state.display;
    assert(@intFromPtr(display) != 0);
    assert(wl_display_get_fd(display) >= 0);
    assert(state.meter_fd >= 0);
    if (wl_display_prepare_read(display) != 0) {
        const pending = wl_display_dispatch_pending(display);
        if (pending < 0) {
            return error.DispatchFailed;
        }
        try drain_meter(state);
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
            .fd = state.meter_fd,
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
    const meter_ready = (fds[1].revents & std.posix.POLL.IN) != 0;
    if (meter_ready) {
        try drain_meter(state);
    }
    // A close event read above stops the loop. That wake is not a failure.
    if (!state.frame.running) {
        assert(!state.frame.running);
        return;
    }
    assert(state.frame.running);
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

/// Opens a nonblocking `timerfd` on `CLOCK_MONOTONIC` and arms one period.
/// The caller closes the returned fd.
fn arm_meter_timer() !i32 {
    const flags: std.os.linux.TFD = .{ .NONBLOCK = true, .CLOEXEC = true };
    const created = std.os.linux.timerfd_create(.MONOTONIC, flags);
    const fd: i32 = switch (std.os.linux.errno(created)) {
        .SUCCESS => @intCast(created),
        else => return error.TimerCreateFailed,
    };
    assert(fd >= 0);
    const period: std.os.linux.timespec = .{
        .sec = 0,
        .nsec = @intCast(levels.period_ns),
    };
    assert(period.nsec == 33_000_000);
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

/// Reads one expiration count and discards it. Several missed periods become
/// one sample at the current monotonic time.
fn drain_meter(state: *State) !void {
    assert(state.meter_fd >= 0);
    var expirations: u64 = 0;
    const bytes = std.mem.asBytes(&expirations);
    const read_n = std.posix.read(state.meter_fd, bytes) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return error.MeterReadFailed,
    };
    assert(read_n == 8);
    assert(expirations >= 1);
    const now_ms = monotonic_ns() / 1_000_000;
    if (state.scene.apply_meters(now_ms)) {
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
/// If fresh (age <= `anchor_age_max_ns` = 1 s), projects forward from `state.vblank_ns`. Otherwise,
/// falls back to anchoring on `now_ns` (the receipt time of `wl_callback.done`).
/// Calls `frame.present_deadline(anchor_ns, state.refresh_ns, now_ns, present_margin_ns)`
/// to place the commit `present_margin_ns` (3 ms) before the next achievable vblank.
/// Cross-references: `frame.present_deadline`.
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
    if (factor <= 0) {
        return;
    }
    state.frame.apply_scale(@intCast(factor)) catch return;
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
/// Tracks primary mouse button (`BTN_LEFT` = 0x110). Ignores secondary and middle clicks.
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
/// `feedback_presented` are accepted only if `clock_id == wp_presentation.clock_monotonic` (1).
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
/// Validates that `state.presentation_clock == wp_presentation.clock_monotonic` (1) and that
/// `tv_nsec < 1_000_000_000`. If valid, assembles the timestamp via `wp_presentation.presented_ns`
/// and stores it in `state.vblank_ns`. Also records `state.vblank_refresh_ns = refresh`.
/// Zero `refresh` indicates a variable refresh rate output and defers cadence tracking to the gap
/// estimator.
/// Observed flags on Hyprland 0.56.2 / Mesa 26.2.2: 0x5 (`vsync | hw_completion`, no `hw_clock`),
/// refresh = 16666666 ns.
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

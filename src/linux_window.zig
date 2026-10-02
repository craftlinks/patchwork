//! Linux Wayland Windowing, Event Loop, and Graphics Integration.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What is Wayland?
//! On modern Linux desktops, the window management system is **Wayland** (replacing legacy X11).
//! In the Wayland architecture:
//! - The **Compositor** (e.g. Hyprland, Sway, GNOME Mutter, KDE KWin) acts as the display server.
//!   It directly controls physical monitors, graphics scanout, and input devices (keyboard, mouse).
//! - The **Client** (our application) connects to the compositor via a Unix domain socket
//!   located at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (typically `/run/user/1000/wayland-0`).
//! - Unlike X11, Wayland provides no server-side 2D drawing primitives. The client is solely
//!   responsible for allocating and rendering complete pixel buffers (via WebGPU or shared memory)
//!   and attaching them to a `wl_surface`.
//!
//! ## 2. Wayland Discovery and the Registry (`wl_registry`)
//! When a client first connects, it receives only a raw handle to `wl_display`. To determine what
//! features and protocols the compositor supports, the client instantiates a `wl_registry`.
//! The compositor broadcasts available "globals" (e.g. `wl_compositor` version 6, `xdg_wm_base`
//! version 1). The client inspects interface names and dynamically binds to the required globals.
//!
//! ## 3. Desktop Windows and the `xdg_shell` Protocol
//! A raw `wl_surface` is an unpositioned rectangular pixel canvas with no window borders or
//! desktop behavior. To turn it into a standard application window, Wayland uses `xdg_shell`:
//! - `xdg_wm_base`: The global factory interface for creating desktop surfaces.
//! - `xdg_surface`: Assigns desktop window roles to a `wl_surface`.
//! - `xdg_toplevel`: Implements desktop application window semantics (window title, app ID,
//!   minimize, maximize, interactive resize, and close operations).
//!
//! ### The Configure-Acknowledge State Machine:
//! In Wayland, the compositor—not the client—dictates window sizing:
//! 1. When the window is mapped or resized, the compositor sends
//!    `toplevel.configure(width, height)`.
//! 2. It then sends `xdg_surface.configure(serial)` with a unique 32-bit transaction ID.
//! 3. The client MUST acknowledge this transaction (`xdg_surface.ack_configure(serial)`) before
//!    presenting a newly sized framebuffer texture.
//!
//! ## 4. The Power-Optimal Blocking Event Loop (0% Idle CPU)
//! Many GUI frameworks use an unconditional polling loop or timer tick (e.g. `sleep(16ms)`),
//! which consumes CPU cycles, wakes CPU cores from low-power C-states, and drains laptop batteries.
//!
//! Patchwork's event loop implements the libwayland multi-thread reader protocol:
//! 1. `wl_display_prepare_read()`: Atomically registers intent to read socket events.
//! 2. `wl_display_flush()`: Flushes any pending client requests over the Unix socket.
//! 3. `std.posix.poll(&fds, -1)`: Puts the calling OS thread into an **uninterruptible sleep**
//!    with timeout `-1` (infinite). The thread consumes 0.0% CPU until compositor writes bytes.
//! 4. `wl_display_read_events()`: Reads incoming bytes from socket into libwayland buffers.
//! 5. `wl_display_dispatch_pending()`: Invokes registered C ABI event callbacks.
//!
//! ### Pointer Event Batching & Amortization:
//! High-frequency gaming mice and trackpads can generate 1,000+ events per second.
//! If every `motion` callback executed a CPU hit test and GPU present, the UI thread would
//! choke and thrash VRAM.
//!
//! Patchwork's event loop decouples input reception from rendering:
//! ```text
//! Socket Event Batch:       [motion] [motion] [motion] [button]
//!                             |        |        |        |
//! dispatch_pending():       Leaf writes update State.pointer (4 memory writes)
//!                             |
//! sync_pointer():           hit.apply() runs ONCE for the entire batch
//!                             |
//! present_if_dirty():       Uploads modified instances and presents ONCE
//! ```
//! Pointer callbacks are leaf writers: they store `x`, `y`, `inside`, and `down` on
//! `State.pointer` and return immediately. The loop applies that sample once per wake:
//! `ack_if_needed`, then `sync_pointer`, then `present_if_dirty`, then `wait_for_events`.
//! Twenty motion events in one dispatch therefore cost one hit test and at most one present.
//! `wl_pointer.frame` is not bound. The seat is `wl_seat` version 1, so the listener tables
//! in `wl_seat.zig` match the event opcodes exactly.
//!
//! ## 5. Graphics Pipeline Integration
//! In `run()`:
//! - State contains `DrawList` and `UploadCursor` on the thread's stack.
//! - Initializes `Gpu` via `gpu.create(display, wl_surface)`.
//! - No hard-coded demo scene is populated on startup: `draw.demo` does not exist.
//!   Instead, `state.list` remains completely empty (`state.list.count == 0`) and
//!   `state.frame.relayout` is initialized to `true`.
//! - In `loop()`, incoming configure events trigger `ack_if_needed()`, which calls
//!   `frame.apply_configure(pending_width, pending_height)`. `sync_pointer` then runs
//!   `hit.apply` and requests a redraw only when a weight changed.
//! - In `present_if_dirty()`:
//!   - Evaluates `frame.redraw`. Returns early if clean or unconfigured (`width_px == 0`).
//!   - Evaluates `frame.relayout`. Only while `relayout` is set does it invoke
//!     `turtle.paint_column(&state.list, ...)` to lay out the column and populate instance
//!     rectangles, followed by `state.frame.mark_laid_out()`. `hit.apply` runs immediately
//!     after that, so a resize keeps the highlight under the last pointer position.
//!   - Preserves instance list across scale changes: When a scale change occurs (via
//!     `surface_preferred_scale`), `frame.apply_scale()` sets `redraw = true` while leaving
//!     `relayout = false`. `present_if_dirty()` skips `turtle.paint_column()`, reusing the
//!     existing draw list and avoiding an unnecessary revision bump.
//!   - Calls `set_buffer_scale()` to inform Wayland of the framebuffer scale factor.
//!   - Fills `PresentHeader` with upload flags computed by `UploadCursor.flags()`.
//!   - Invokes `gpu.present()` to transfer modified buffers and draw instanced quads.
//!   - Calls `cursor.mark()` and `state.frame.mark_presented()`, returning to kernel sleep
//!     in `poll(-1)` where the process consumes 0.0% CPU until the compositor writes bytes.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");
const hit = @import("hit.zig");
const turtle = @import("turtle.zig");
const wl_seat = @import("wl_seat.zig");
const xdg = @import("xdg_shell.zig");

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
    cursor: draw.UploadCursor,
    /// Latest pointer coordinates, surface entry state, and button state.
    pointer: hit.Pointer,
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

/// Main blocking event loop: acknowledges configure, applies the pointer once,
/// renders dirty frames, and sleeps in poll.
fn loop(state: *State) !void {
    assert(@intFromPtr(state.display) != 0);
    while (state.frame.running) {
        // Handle any compositor resize configure.
        ack_if_needed(state);
        // Hit-test once.
        sync_pointer(state);
        // Present once if dirty.
        try present_if_dirty(state);
        // Sleep until the compositor sends new bytes.
        try wait_for_events(state.display);
    }
    assert(!state.frame.running);
}

/// Evaluates hit testing against `state.list` using the latest stored `state.pointer` sample.
/// Runs once per event loop wake after flushing socket events, amortizing multiple motion packets.
/// Requests a frame redraw only if any instance's hover or down weight changed.
fn sync_pointer(state: *State) void {
    if (hit.apply(&state.list, state.pointer)) {
        state.frame.request_redraw();
    }
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

/// Renders and presents a frame if the dirty flag (`redraw`) is set.
///
/// Execution Lifecycle:
/// 1. Early-out if `!frame.redraw` or if window dimensions are unconfigured (`width_px == 0`).
/// 2. Conditional layout: If `frame.relayout` is true (set on startup or after dimension
///    changes), calls `turtle.paint_column` to walk the column and populate `state.list`, then
///    clears the flag via `frame.mark_laid_out()`. If only scale changed, this step is bypassed.
/// 3. Informs the compositor of buffer scaling via `wl_surface.set_buffer_scale`.
/// 4. Constructs a `PresentHeader` on the stack with upload flags from `state.cursor.flags()`.
/// 5. Transfers modified GPU buffers and draws instances via `gpu.present()`.
/// 6. Updates `state.cursor.mark()` and clears presentation dirtying via
///    `state.frame.mark_presented()`.
fn present_if_dirty(state: *State) !void {
    if (!state.frame.redraw) {
        return;
    }
    if (state.frame.width_px == 0) {
        assert(state.frame.height_px == 0);
        return;
    }
    if (state.frame.relayout) {
        turtle.paint_column(&state.list, state.frame.width_logical, state.frame.height_logical);
        state.frame.mark_laid_out();
        // The walk writes every weight as 0. Apply the stored pointer again so a
        // resize does not clear a highlight. Redraw is already owed.
        _ = hit.apply(&state.list, state.pointer);
    }
    assert(!state.frame.relayout);
    set_buffer_scale(state);
    var header: draw.PresentHeader = undefined;
    draw.fill_header(&header, .{
        .list = &state.list,
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
    try gpu.present(&state.gpu, &header, &state.list.items);
    state.cursor.mark(&state.list, state.frame.width_logical, state.frame.height_logical);
    state.frame.mark_presented();
    assert(!state.frame.redraw);
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

/// Blocks execution in `poll(-1)` until the Wayland compositor sends events.
fn wait_for_events(display: *Display) !void {
    assert(@intFromPtr(display) != 0);
    assert(wl_display_get_fd(display) >= 0);
    if (wl_display_prepare_read(display) != 0) {
        const pending = wl_display_dispatch_pending(display);
        if (pending < 0) {
            return error.DispatchFailed;
        }
        return;
    }
    const flush_rc = wl_display_flush(display);
    if (flush_rc < 0) {
        wl_display_cancel_read(display);
        return error.FlushFailed;
    }
    // Sleep until the compositor writes. A 0 timeout was the splash demo spin.
    var fds = [_]std.posix.pollfd{.{
        .fd = wl_display_get_fd(display),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    // puts the thread into an OS kernel sleep with zero CPU usage.
    _ = std.posix.poll(fds[0..], -1) catch {
        wl_display_cancel_read(display);
        return error.PollFailed;
    };
    // Poll wakes up because data is ready.
    // Reads all pending bytes off the socket into libwayland's ring buffer in one syscall.
    if (wl_display_read_events(display) != 0) {
        return error.ReadFailed;
    }
    // Loops through all those messages in memory and invokes our C callbacks one by one.
    const pending = wl_display_dispatch_pending(display);
    if (pending < 0) {
        return error.DispatchFailed;
    }
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
    state.pointer.leave();
    assert(state.pointer_proxy == null);
    assert(!state.pointer.down);
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
    move_pointer(state, sx, sy);
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
    state.pointer.leave();
    assert(!state.pointer.inside);
}

/// C ABI callback for `wl_pointer.motion` (opcode 2).
/// Updates stored pointer coordinates from 24.8 fixed-point surface coordinates.
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
    move_pointer(state, sx, sy);
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
        return;
    }
    const state: *State = @ptrCast(@alignCast(data.?));
    const pressed = button_state == wl_seat.button_state_pressed;
    state.pointer.button(pressed);
    assert(state.pointer.down == pressed);
}

/// C ABI callback for `wl_pointer.axis` (opcode 4).
/// Satisfies version 1 listener vtable layout; scroll input is deferred to step 8.
fn pointer_axis(
    data: ?*anyopaque,
    pointer: ?*wl_seat.WlPointer,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
    _ = value;
}

/// Converts surface-local 24.8 fixed-point coordinates into UI logical pixels and stores them.
fn move_pointer(state: *State, sx: i32, sy: i32) void {
    const x = hit.fixed_to_logical(sx);
    const y = hit.fixed_to_logical(sy);
    state.pointer.move(x, y);
    assert(state.pointer.inside);
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

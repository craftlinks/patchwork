const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");
const xdg = @import("xdg_shell.zig");

/// Hyprland advertises well over 64 protocol globals. This only bounds the
/// registry walk; we bind compositor and xdg_wm_base and ignore the rest.
const global_cap: u32 = 256;
const compositor_version_max: u32 = 6;

const Display = opaque {};
const Registry = opaque {};
const Compositor = opaque {};
const WlProxy = xdg.WlProxy;
const WlSurface = xdg.WlSurface;
const WlInterface = xdg.WlInterface;

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
    configure_serial: u32,
    ack_pending: bool,
    pending_width: u32,
    pending_height: u32,
    global_count: u32,
};

extern const wl_registry_interface: WlInterface;
extern const wl_compositor_interface: WlInterface;
extern const wl_surface_interface: WlInterface;

extern fn wl_display_connect(name: ?[*:0]const u8) ?*Display;
extern fn wl_display_get_fd(display: *Display) i32;
extern fn wl_display_prepare_read(display: *Display) i32;
extern fn wl_display_cancel_read(display: *Display) void;
extern fn wl_display_read_events(display: *Display) i32;
extern fn wl_display_dispatch_pending(display: *Display) i32;
extern fn wl_display_flush(display: *Display) i32;
extern fn wl_display_roundtrip(display: *Display) i32;
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
    enter: *const fn (data: ?*anyopaque, surface: ?*WlSurface, output: ?*anyopaque) callconv(.c) void,
    leave: *const fn (data: ?*anyopaque, surface: ?*WlSurface, output: ?*anyopaque) callconv(.c) void,
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

pub fn run(state: *State) !void {
    try connect(state);
    try bind_globals(state);
    try create_toplevel(state);
    try create_device(state);
    draw.demo(&state.list);
    try loop(state);
}

fn connect(state: *State) !void {
    const display = wl_display_connect(null) orelse return error.DisplayConnectFailed;
    state.display = display;
    assert(@intFromPtr(state.display) != 0);
    assert(wl_display_get_fd(display) >= 0);
}

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

fn create_device(state: *State) !void {
    const display = state.display;
    const surface = state.surface orelse return error.MissingSurface;
    state.gpu = try gpu.create(@ptrCast(display), @ptrCast(surface));
    assert(state.gpu.configured_width == 0);
    assert(state.gpu.configured_height == 0);
}

fn loop(state: *State) !void {
    assert(@intFromPtr(state.display) != 0);
    while (state.frame.running) {
        ack_if_needed(state);
        try present_if_dirty(state);
        try wait_for_events(state.display);
    }
    assert(!state.frame.running);
}

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

fn present_if_dirty(state: *State) !void {
    if (!state.frame.redraw) {
        return;
    }
    if (state.frame.width_px == 0) {
        assert(state.frame.height_px == 0);
        return;
    }
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
    _ = std.posix.poll(fds[0..], -1) catch {
        wl_display_cancel_read(display);
        return error.PollFailed;
    };
    if (wl_display_read_events(display) != 0) {
        return error.ReadFailed;
    }
    const pending = wl_display_dispatch_pending(display);
    if (pending < 0) {
        return error.DispatchFailed;
    }
}

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

fn commit_surface(surface: *WlSurface) void {
    const proxy: *WlProxy = @ptrCast(surface);
    const version = wl_proxy_get_version(proxy);
    _ = wl_proxy_marshal_flags(proxy, 6, null, version, 0);
    assert(version >= 1);
}

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
        const bind_version = if (version < compositor_version_max) version else compositor_version_max;
        state.compositor = @ptrCast(bind_global(live_registry, name, &wl_compositor_interface, bind_version));
        return;
    }
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        state.xdg_base = @ptrCast(bind_global(live_registry, name, &xdg.xdg_wm_base_interface, 1));
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

fn surface_preferred_scale(data: ?*anyopaque, surface: ?*WlSurface, factor: i32) callconv(.c) void {
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    if (factor <= 0) {
        return;
    }
    state.frame.apply_scale(@intCast(factor)) catch return;
}

fn surface_preferred_transform(data: ?*anyopaque, surface: ?*WlSurface, transform: u32) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = transform;
}

fn xdg_ping(data: ?*anyopaque, base: ?*xdg.XdgWmBase, serial: u32) callconv(.c) void {
    _ = data;
    const live = base orelse return;
    xdg.pong(live, serial);
}

fn xdg_surface_configure(data: ?*anyopaque, surface: ?*xdg.XdgSurface, serial: u32) callconv(.c) void {
    _ = surface;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    state.configure_serial = serial;
    state.ack_pending = true;
}

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

fn toplevel_close(data: ?*anyopaque, toplevel: ?*xdg.XdgToplevel) callconv(.c) void {
    _ = toplevel;
    assert(data != null);
    const state: *State = @ptrCast(@alignCast(data.?));
    if (state.frame.running) {
        state.frame.close();
    }
}

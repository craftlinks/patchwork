const std = @import("std");
const assert = std.debug.assert;
const gpu = @import("gpu.zig");

pub const Gpu = struct {
    instance: Instance,
    adapter: Adapter,
    device: Device,
    queue: Queue,
    surface: Surface,
    format: TextureFormat,
    configured_width: u32,
    configured_height: u32,
};

const Instance = *opaque {};
const Adapter = *opaque {};
const Device = *opaque {};
const Queue = *opaque {};
const Surface = *opaque {};
const Texture = *opaque {};
const TextureView = *opaque {};
const CommandEncoder = *opaque {};
const CommandBuffer = *opaque {};
const RenderPassEncoder = *opaque {};

const Bool = u32;
const Flags = u64;
const SType = u32;
const Status = u32;
const CallbackMode = u32;
const TextureFormat = u32;
const TextureUsage = Flags;
const PresentMode = u32;
const CompositeAlphaMode = u32;
const LoadOp = u32;
const StoreOp = u32;
const RequestAdapterStatus = u32;
const RequestDeviceStatus = u32;
const SurfaceGetCurrentTextureStatus = u32;
const s_type_wayland_surface: SType = 0x00000007;
const callback_process_events: CallbackMode = 0x00000002;
const format_bgra8_unorm: TextureFormat = 0x0000001B;
const usage_render_attachment: TextureUsage = 0x0000000000000010;
const present_fifo: PresentMode = 0x00000001;
const alpha_auto: CompositeAlphaMode = 0x00000000;
const load_clear: LoadOp = 0x00000002;
const store_store: StoreOp = 0x00000001;
const status_success: Status = 0x00000001;
const adapter_success: RequestAdapterStatus = 0x00000001;
const device_success: RequestDeviceStatus = 0x00000001;
const texture_success_optimal: SurfaceGetCurrentTextureStatus = 0x00000001;
const texture_success_suboptimal: SurfaceGetCurrentTextureStatus = 0x00000002;
const depth_slice_undefined: u32 = 0xFFFFFFFF;
const wait_max: u32 = 8000;
const format_cap: u32 = 32;

const ChainedStruct = extern struct {
    next: ?*ChainedStruct,
    s_type: SType,
};

const StringView = extern struct {
    data: ?[*]const u8,
    length: usize,
};

const Color = extern struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

const Future = extern struct {
    id: u64,
};

const SurfaceSourceWayland = extern struct {
    chain: ChainedStruct,
    display: *anyopaque,
    surface: *anyopaque,
};

const SurfaceDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
};

const RequestAdapterOptions = extern struct {
    next_in_chain: ?*ChainedStruct,
    feature_level: u32,
    power_preference: u32,
    force_fallback_adapter: Bool,
    backend_type: u32,
    compatible_surface: ?Surface,
};

const RequestAdapterCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    mode: CallbackMode,
    callback: *const fn (
        status: RequestAdapterStatus,
        adapter: ?Adapter,
        message: StringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

const RequestDeviceCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    mode: CallbackMode,
    callback: *const fn (
        status: RequestDeviceStatus,
        device: ?Device,
        message: StringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

const SurfaceCapabilities = extern struct {
    next_in_chain: ?*ChainedStruct,
    usages: TextureUsage,
    format_count: usize,
    formats: ?[*]const TextureFormat,
    present_mode_count: usize,
    present_modes: ?[*]const PresentMode,
    alpha_mode_count: usize,
    alpha_modes: ?[*]const CompositeAlphaMode,
};

const SurfaceConfiguration = extern struct {
    next_in_chain: ?*ChainedStruct,
    device: Device,
    format: TextureFormat,
    usage: TextureUsage,
    width: u32,
    height: u32,
    view_format_count: usize,
    view_formats: ?[*]const TextureFormat,
    alpha_mode: CompositeAlphaMode,
    present_mode: PresentMode,
};

const SurfaceTexture = extern struct {
    next_in_chain: ?*ChainedStruct,
    texture: ?Texture,
    status: SurfaceGetCurrentTextureStatus,
};

const RenderPassColorAttachment = extern struct {
    next_in_chain: ?*ChainedStruct,
    view: ?TextureView,
    depth_slice: u32,
    resolve_target: ?TextureView,
    load_op: LoadOp,
    store_op: StoreOp,
    clear_value: Color,
};

const RenderPassDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    color_attachment_count: usize,
    color_attachments: ?[*]const RenderPassColorAttachment,
    depth_stencil_attachment: ?*anyopaque,
    occlusion_query_set: ?*anyopaque,
    timestamp_writes: ?*anyopaque,
};

const AdapterSlot = struct {
    adapter: ?Adapter,
    ok: bool,
};

const DeviceSlot = struct {
    device: ?Device,
    ok: bool,
};

extern fn wgpuCreateInstance(descriptor: ?*const anyopaque) ?Instance;
extern fn wgpuInstanceCreateSurface(instance: Instance, descriptor: *const SurfaceDescriptor) ?Surface;
extern fn wgpuInstanceRequestAdapter(
    instance: Instance,
    options: ?*const RequestAdapterOptions,
    callback_info: RequestAdapterCallbackInfo,
) Future;
extern fn wgpuInstanceProcessEvents(instance: Instance) void;
extern fn wgpuAdapterRequestDevice(
    adapter: Adapter,
    descriptor: ?*const anyopaque,
    callback_info: RequestDeviceCallbackInfo,
) Future;
extern fn wgpuDeviceGetQueue(device: Device) Queue;
extern fn wgpuDeviceCreateCommandEncoder(device: Device, descriptor: ?*const anyopaque) CommandEncoder;
extern fn wgpuSurfaceGetCapabilities(
    surface: Surface,
    adapter: Adapter,
    capabilities: *SurfaceCapabilities,
) Status;
extern fn wgpuSurfaceCapabilitiesFreeMembers(capabilities: SurfaceCapabilities) void;
extern fn wgpuSurfaceConfigure(surface: Surface, config: *const SurfaceConfiguration) void;
extern fn wgpuSurfaceGetCurrentTexture(surface: Surface, surface_texture: *SurfaceTexture) void;
extern fn wgpuSurfacePresent(surface: Surface) Status;
extern fn wgpuTextureCreateView(texture: Texture, descriptor: ?*const anyopaque) TextureView;
extern fn wgpuCommandEncoderBeginRenderPass(
    encoder: CommandEncoder,
    descriptor: *const RenderPassDescriptor,
) RenderPassEncoder;
extern fn wgpuCommandEncoderFinish(encoder: CommandEncoder, descriptor: ?*const anyopaque) CommandBuffer;
extern fn wgpuRenderPassEncoderEnd(pass: RenderPassEncoder) void;
extern fn wgpuQueueSubmit(queue: Queue, command_count: usize, commands: [*]const CommandBuffer) void;
extern fn wgpuTextureViewRelease(view: TextureView) void;
extern fn wgpuTextureRelease(texture: Texture) void;
extern fn wgpuCommandEncoderRelease(encoder: CommandEncoder) void;
extern fn wgpuCommandBufferRelease(buffer: CommandBuffer) void;
extern fn wgpuRenderPassEncoderRelease(pass: RenderPassEncoder) void;

comptime {
    assert(@sizeOf(Color) == 32);
    assert(@sizeOf(ChainedStruct) == 16);
    assert(@sizeOf(Future) == 8);
    assert(@sizeOf(SurfaceSourceWayland) == 32);
}

const empty_label: StringView = .{ .data = null, .length = 0 };

pub fn create(display: *anyopaque, wl_surface: *anyopaque) !Gpu {
    assert(@intFromPtr(display) != 0);
    assert(@intFromPtr(wl_surface) != 0);
    const instance = try create_instance();
    const surface = try create_surface(instance, display, wl_surface);
    const adapter = try request_adapter(instance, surface);
    const device = try request_device(instance, adapter);
    const queue = wgpuDeviceGetQueue(device);
    const format = try pick_format(surface, adapter);
    return .{
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface = surface,
        .format = format,
        .configured_width = 0,
        .configured_height = 0,
    };
}

pub fn present_clear(self: *Gpu, width_px: u32, height_px: u32, color: gpu.Color) !void {
    assert(width_px != 0);
    assert(height_px != 0);
    configure_surface(self, width_px, height_px);
    const texture = try acquire_texture(self.surface);
    encode_submit_present(self, texture, color);
}

fn create_instance() !Instance {
    // wgpu-native v29.0.1.1 panics if TimedWaitAny is required. Startup waits
    // with WaitAny(0) plus ProcessEvents instead.
    const instance = wgpuCreateInstance(null) orelse return error.InstanceFailed;
    assert(@intFromPtr(instance) != 0);
    assert(wait_max >= 1);
    return instance;
}

fn create_surface(instance: Instance, display: *anyopaque, wl_surface: *anyopaque) !Surface {
    assert(@intFromPtr(instance) != 0);
    var source: SurfaceSourceWayland = .{
        .chain = .{ .next = null, .s_type = s_type_wayland_surface },
        .display = display,
        .surface = wl_surface,
    };
    const descriptor: SurfaceDescriptor = .{
        .next_in_chain = @ptrCast(&source.chain),
        .label = empty_label,
    };
    const surface = wgpuInstanceCreateSurface(instance, &descriptor) orelse {
        return error.SurfaceFailed;
    };
    assert(@intFromPtr(surface) != 0);
    return surface;
}

fn request_adapter(instance: Instance, surface: Surface) !Adapter {
    assert(@intFromPtr(instance) != 0);
    assert(@intFromPtr(surface) != 0);
    var slot: AdapterSlot = .{ .adapter = null, .ok = false };
    const options: RequestAdapterOptions = .{
        .next_in_chain = null,
        .feature_level = 0,
        .power_preference = 0,
        .force_fallback_adapter = 0,
        .backend_type = 0,
        .compatible_surface = surface,
    };
    const info: RequestAdapterCallbackInfo = .{
        .next_in_chain = null,
        .mode = callback_process_events,
        .callback = adapter_ready,
        .userdata1 = @ptrCast(&slot),
        .userdata2 = null,
    };
    const future = wgpuInstanceRequestAdapter(instance, &options, info);
    try wait_future(instance, future, &slot.ok);
    const adapter = slot.adapter orelse return error.AdapterFailed;
    assert(slot.ok);
    return adapter;
}

fn request_device(instance: Instance, adapter: Adapter) !Device {
    assert(@intFromPtr(instance) != 0);
    assert(@intFromPtr(adapter) != 0);
    var slot: DeviceSlot = .{ .device = null, .ok = false };
    const info: RequestDeviceCallbackInfo = .{
        .next_in_chain = null,
        .mode = callback_process_events,
        .callback = device_ready,
        .userdata1 = @ptrCast(&slot),
        .userdata2 = null,
    };
    const future = wgpuAdapterRequestDevice(adapter, null, info);
    try wait_future(instance, future, &slot.ok);
    const device = slot.device orelse return error.DeviceFailed;
    assert(slot.ok);
    return device;
}

fn wait_future(instance: Instance, future: Future, ok: *bool) !void {
    // wgpu-native v29.0.1.1 ships WaitAny in the header and panics if it is called.
    _ = future;
    assert(@intFromPtr(instance) != 0);
    assert(wait_max >= 1);
    var waits: u32 = 0;
    while (waits < wait_max) : (waits += 1) {
        wgpuInstanceProcessEvents(instance);
        if (ok.*) return;
        var req = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&req, null);
    }
    return error.WaitTimeout;
}

fn pick_format(surface: Surface, adapter: Adapter) !TextureFormat {
    assert(@intFromPtr(surface) != 0);
    assert(@intFromPtr(adapter) != 0);
    var capabilities: SurfaceCapabilities = std.mem.zeroes(SurfaceCapabilities);
    const status = wgpuSurfaceGetCapabilities(surface, adapter, &capabilities);
    if (status != status_success) {
        return error.CapabilitiesFailed;
    }
    const format = find_bgra8(capabilities) orelse {
        wgpuSurfaceCapabilitiesFreeMembers(capabilities);
        return error.Bgra8Unsupported;
    };
    wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    assert(format == format_bgra8_unorm);
    return format;
}

fn find_bgra8(capabilities: SurfaceCapabilities) ?TextureFormat {
    const formats = capabilities.formats orelse return null;
    const count_usize = capabilities.format_count;
    if (count_usize == 0) {
        return null;
    }
    if (count_usize > format_cap) {
        return null;
    }
    assert(count_usize >= 1);
    assert(count_usize <= format_cap);
    const count: u32 = @intCast(count_usize);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (formats[index] == format_bgra8_unorm) {
            return format_bgra8_unorm;
        }
    }
    return null;
}

fn configure_surface(self: *Gpu, width_px: u32, height_px: u32) void {
    assert(width_px != 0);
    assert(height_px != 0);
    const same_width = width_px == self.configured_width;
    const same_height = height_px == self.configured_height;
    if (same_width) {
        if (same_height) {
            return;
        }
    }
    const config: SurfaceConfiguration = .{
        .next_in_chain = null,
        .device = self.device,
        .format = self.format,
        .usage = usage_render_attachment,
        .width = width_px,
        .height = height_px,
        .view_format_count = 0,
        .view_formats = null,
        .alpha_mode = alpha_auto,
        .present_mode = present_fifo,
    };
    wgpuSurfaceConfigure(self.surface, &config);
    self.configured_width = width_px;
    self.configured_height = height_px;
}

fn acquire_texture(surface: Surface) !Texture {
    assert(@intFromPtr(surface) != 0);
    var surface_texture: SurfaceTexture = .{
        .next_in_chain = null,
        .texture = null,
        .status = 0,
    };
    wgpuSurfaceGetCurrentTexture(surface, &surface_texture);
    const ok_optimal = surface_texture.status == texture_success_optimal;
    const ok_suboptimal = surface_texture.status == texture_success_suboptimal;
    if (ok_optimal or ok_suboptimal) {
        const texture = surface_texture.texture orelse return error.TextureMissing;
        assert(@intFromPtr(texture) != 0);
        return texture;
    }
    return error.TextureAcquireFailed;
}

fn encode_submit_present(self: *Gpu, texture: Texture, color: gpu.Color) void {
    assert(@intFromPtr(texture) != 0);
    const view = wgpuTextureCreateView(texture, null);
    const encoder = wgpuDeviceCreateCommandEncoder(self.device, null);
    assert(@intFromPtr(view) != 0);
    assert(@intFromPtr(encoder) != 0);
    const attachment: RenderPassColorAttachment = .{
        .next_in_chain = null,
        .view = view,
        .depth_slice = depth_slice_undefined,
        .resolve_target = null,
        .load_op = load_clear,
        .store_op = store_store,
        .clear_value = .{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = color.a,
        },
    };
    const pass_desc: RenderPassDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .color_attachment_count = 1,
        .color_attachments = @ptrCast(&attachment),
        .depth_stencil_attachment = null,
        .occlusion_query_set = null,
        .timestamp_writes = null,
    };
    const pass = wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
    wgpuRenderPassEncoderEnd(pass);
    const commands = wgpuCommandEncoderFinish(encoder, null);
    wgpuQueueSubmit(self.queue, 1, @ptrCast(&commands));
    _ = wgpuSurfacePresent(self.surface);
    wgpuRenderPassEncoderRelease(pass);
    wgpuCommandEncoderRelease(encoder);
    wgpuCommandBufferRelease(commands);
    wgpuTextureViewRelease(view);
    wgpuTextureRelease(texture);
}

fn adapter_ready(
    status: RequestAdapterStatus,
    adapter: ?Adapter,
    message: StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    assert(userdata1 != null);
    const slot: *AdapterSlot = @ptrCast(@alignCast(userdata1.?));
    slot.ok = status == adapter_success;
    slot.adapter = adapter;
    if (slot.ok) {
        assert(adapter != null);
    }
}

fn device_ready(
    status: RequestDeviceStatus,
    device: ?Device,
    message: StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    assert(userdata1 != null);
    const slot: *DeviceSlot = @ptrCast(@alignCast(userdata1.?));
    slot.ok = status == device_success;
    slot.device = device;
    if (slot.ok) {
        assert(device != null);
    }
}

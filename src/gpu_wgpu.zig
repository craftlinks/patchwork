//! Native Linux WebGPU Implementation using wgpu-native (v29.0.1.1 C ABI).
//!
//! # Concepts for Novices:
//!
//! ## 1. What is wgpu-native?
//! `wgpu-native` is a high-performance WebGPU implementation written in Rust (the core of
//! Firefox's WebGPU engine) that exports a standard C ABI defined by the W3C `webgpu.h` spec.
//! Instead of using third-party package managers or complex C++ wrappers, we interface directly
//! with `libwgpu_native.so` using Zig's native C ABI calling conventions (`callconv(.c)`).
//!
//! ## 2. Type-Safe Opaque Handles in Zig
//! In C, graphics handles are often declared as untyped `void*` or incomplete pointer types.
//! In Zig, we declare handles as distinct opaque types: `const Instance = *opaque {};`.
//! In Zig, each `*opaque {}` declaration is a unique type. If you accidentally pass an `Adapter`
//! to a function expecting a `Device`, the Zig compiler catches the bug at compile time.
//!
//! ## 3. The Chained Struct Pattern (`ChainedStruct` and `s_type`)
//! Modern graphics APIs (Vulkan and WebGPU) need a way to pass platform-specific
//! configuration structures without breaking C ABI binary compatibility.
//! They use a tagged, singly-linked list of structs:
//! - Every extensibility struct begins with `ChainedStruct` (16 bytes: `next: ?*ChainedStruct`,
//!   `s_type: SType`, plus 4 bytes padding).
//! - When creating a Wayland surface, `SurfaceSourceWayland` has `chain: ChainedStruct` as its
//!   first field and sets `s_type = s_type_wayland_surface` (0x00000007).
//! - `SurfaceDescriptor` has `next_in_chain: ?*ChainedStruct`. We point `next_in_chain` directly to
//!   `&source.chain`. The underlying C library walks this linked list, checks the `s_type` tag,
//!   casts the pointer to `SurfaceSourceWayland`, and reads the display and surface handles.
//!
//! ## 4. The WebGPU Resource Hierarchy
//! - `Instance`: Entry point to the WebGPU runtime.
//! - `Adapter`: Physical GPU hardware (e.g. Intel UHD, AMD Radeon, NVIDIA).
//! - `Device`: Logical GPU context used to allocate buffers, shaders, and pipelines.
//! - `Queue`: Command queue where recorded command buffers are submitted for execution.
//! - `Surface`: Window attachment connecting WebGPU to the Linux Wayland display server.
//! - `Texture` / `TextureView`: The actual pixel image buffers in GPU VRAM (swapchain images).
//!
//! ## 5. Recording and Submitting GPU Commands
//! Unlike old APIs (like OpenGL) where draw calls happen immediately, modern GPUs are asynchronous:
//! 1. `CommandEncoder`: Records drawing commands into a `CommandBuffer` in CPU memory.
//! 2. `RenderPassEncoder`: Configures render targets, clear colors, pipelines, and draw calls.
//! 3. `wgpuQueueSubmit`: Hands the finished command buffer over to the GPU hardware driver.
//! 4. `wgpuSurfacePresent`: Flips the completed swapchain image onto the display monitor.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");

/// Hardware GPU state context encapsulating all native WebGPU resources.
pub const Gpu = struct {
    instance: Instance,
    adapter: Adapter,
    device: Device,
    queue: Queue,
    surface: Surface,
    format: TextureFormat,
    configured_width: u32,
    configured_height: u32,
    pipeline: RenderPipeline,
    quad_buffer: Buffer,
    instance_buffer: Buffer,
    uniform_buffer: Buffer,
    bind_group: BindGroup,
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
const Buffer = *opaque {};
const ShaderModule = *opaque {};
const BindGroupLayout = *opaque {};
const PipelineLayout = *opaque {};
const BindGroup = *opaque {};
const RenderPipeline = *opaque {};

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
const VertexFormat = u32;
const VertexStepMode = u32;
const PrimitiveTopology = u32;
const IndexFormat = u32;
const FrontFace = u32;
const CullMode = u32;
const BlendOperation = u32;
const BlendFactor = u32;
const BufferBindingType = u32;
const s_type_wayland_surface: SType = 0x00000007;
const s_type_shader_source_wgsl: SType = 0x00000002;
const callback_process_events: CallbackMode = 0x00000002;
const format_bgra8_unorm: TextureFormat = 0x0000001B;
const usage_render_attachment: TextureUsage = 0x0000000000000010;
const usage_copy_dst: Flags = 0x0000000000000008;
const usage_vertex: Flags = 0x0000000000000020;
const usage_uniform: Flags = 0x0000000000000040;
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
const vertex_float32x2: VertexFormat = 0x0000001D;
const vertex_float32x4: VertexFormat = 0x0000001F;
const step_vertex: VertexStepMode = 0x00000001;
const step_instance: VertexStepMode = 0x00000002;
const topology_triangle_list: PrimitiveTopology = 0x00000004;
const index_undefined: IndexFormat = 0x00000000;
const front_ccw: FrontFace = 0x00000001;
const cull_none: CullMode = 0x00000001;
const blend_add: BlendOperation = 0x00000001;
const blend_src_alpha: BlendFactor = 0x00000005;
const blend_one_minus_src_alpha: BlendFactor = 0x00000006;
const buffer_uniform: BufferBindingType = 0x00000002;
const shader_vertex: Flags = 0x0000000000000001;
const color_write_all: Flags = 0x000000000000000F;
const whole_size: u64 = 0xFFFFFFFFFFFFFFFF;

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

const ShaderSourceWgsl = extern struct {
    chain: ChainedStruct,
    code: StringView,
};

const ShaderModuleDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
};

const BufferDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    usage: Flags,
    size: u64,
    mapped_at_creation: Bool,
};

const BufferBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct,
    type: BufferBindingType,
    has_dynamic_offset: Bool,
    min_binding_size: u64,
};

const SamplerBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct,
    type: u32,
};

const TextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct,
    sample_type: u32,
    view_dimension: u32,
    multisampled: Bool,
};

const StorageTextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct,
    access: u32,
    format: TextureFormat,
    view_dimension: u32,
};

const BindGroupLayoutEntry = extern struct {
    next_in_chain: ?*ChainedStruct,
    binding: u32,
    visibility: Flags,
    binding_array_size: u32,
    buffer: BufferBindingLayout,
    sampler: SamplerBindingLayout,
    texture: TextureBindingLayout,
    storage_texture: StorageTextureBindingLayout,
};

const BindGroupLayoutDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    entry_count: usize,
    entries: ?[*]const BindGroupLayoutEntry,
};

const PipelineLayoutDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    bind_group_layout_count: usize,
    bind_group_layouts: ?[*]const BindGroupLayout,
    immediate_size: u32,
};

const BindGroupEntry = extern struct {
    next_in_chain: ?*ChainedStruct,
    binding: u32,
    buffer: ?Buffer,
    offset: u64,
    size: u64,
    sampler: ?*anyopaque,
    texture_view: ?*anyopaque,
};

const BindGroupDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    layout: BindGroupLayout,
    entry_count: usize,
    entries: ?[*]const BindGroupEntry,
};

const VertexAttribute = extern struct {
    next_in_chain: ?*ChainedStruct,
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

const VertexBufferLayout = extern struct {
    next_in_chain: ?*ChainedStruct,
    step_mode: VertexStepMode,
    array_stride: u64,
    attribute_count: usize,
    attributes: ?[*]const VertexAttribute,
};

const BlendComponent = extern struct {
    operation: BlendOperation,
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
};

const BlendState = extern struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

const ColorTargetState = extern struct {
    next_in_chain: ?*ChainedStruct,
    format: TextureFormat,
    blend: ?*const BlendState,
    write_mask: Flags,
};

const VertexState = extern struct {
    next_in_chain: ?*ChainedStruct,
    module: ShaderModule,
    entry_point: StringView,
    constant_count: usize,
    constants: ?*anyopaque,
    buffer_count: usize,
    buffers: ?[*]const VertexBufferLayout,
};

const PrimitiveState = extern struct {
    next_in_chain: ?*ChainedStruct,
    topology: PrimitiveTopology,
    strip_index_format: IndexFormat,
    front_face: FrontFace,
    cull_mode: CullMode,
    unclipped_depth: Bool,
};

const MultisampleState = extern struct {
    next_in_chain: ?*ChainedStruct,
    count: u32,
    mask: u32,
    alpha_to_coverage_enabled: Bool,
};

const FragmentState = extern struct {
    next_in_chain: ?*ChainedStruct,
    module: ShaderModule,
    entry_point: StringView,
    constant_count: usize,
    constants: ?*anyopaque,
    target_count: usize,
    targets: ?[*]const ColorTargetState,
};

const RenderPipelineDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    layout: ?PipelineLayout,
    vertex: VertexState,
    primitive: PrimitiveState,
    depth_stencil: ?*anyopaque,
    multisample: MultisampleState,
    fragment: ?*const FragmentState,
};

const AdapterSlot = struct {
    adapter: ?Adapter,
    ok: bool,
};

const DeviceSlot = struct {
    device: ?Device,
    ok: bool,
};

const Buffers = struct {
    quad: Buffer,
    instances: Buffer,
    uniform: Buffer,
};

extern fn wgpuCreateInstance(descriptor: ?*const anyopaque) ?Instance;
extern fn wgpuInstanceCreateSurface(
    instance: Instance,
    descriptor: *const SurfaceDescriptor,
) ?Surface;
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
extern fn wgpuDeviceCreateCommandEncoder(
    device: Device,
    descriptor: ?*const anyopaque,
) CommandEncoder;
extern fn wgpuDeviceCreateShaderModule(
    device: Device,
    descriptor: *const ShaderModuleDescriptor,
) ShaderModule;
extern fn wgpuDeviceCreateBuffer(device: Device, descriptor: *const BufferDescriptor) ?Buffer;
extern fn wgpuDeviceCreateBindGroupLayout(
    device: Device,
    descriptor: *const BindGroupLayoutDescriptor,
) BindGroupLayout;
extern fn wgpuDeviceCreatePipelineLayout(
    device: Device,
    descriptor: *const PipelineLayoutDescriptor,
) PipelineLayout;
extern fn wgpuDeviceCreateBindGroup(
    device: Device,
    descriptor: *const BindGroupDescriptor,
) BindGroup;
extern fn wgpuDeviceCreateRenderPipeline(
    device: Device,
    descriptor: *const RenderPipelineDescriptor,
) RenderPipeline;
extern fn wgpuQueueWriteBuffer(
    queue: Queue,
    buffer: Buffer,
    offset: u64,
    data: *const anyopaque,
    size: usize,
) void;
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
extern fn wgpuCommandEncoderFinish(
    encoder: CommandEncoder,
    descriptor: ?*const anyopaque,
) CommandBuffer;
extern fn wgpuRenderPassEncoderEnd(pass: RenderPassEncoder) void;
extern fn wgpuRenderPassEncoderSetPipeline(pass: RenderPassEncoder, pipeline: RenderPipeline) void;
extern fn wgpuRenderPassEncoderSetBindGroup(
    pass: RenderPassEncoder,
    group_index: u32,
    group: BindGroup,
    dynamic_offset_count: usize,
    dynamic_offsets: ?[*]const u32,
) void;
extern fn wgpuRenderPassEncoderSetVertexBuffer(
    pass: RenderPassEncoder,
    slot: u32,
    buffer: Buffer,
    offset: u64,
    size: u64,
) void;
extern fn wgpuRenderPassEncoderDraw(
    pass: RenderPassEncoder,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;
extern fn wgpuQueueSubmit(
    queue: Queue,
    command_count: usize,
    commands: [*]const CommandBuffer,
) void;
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
    assert(@sizeOf(ShaderSourceWgsl) == 32);
}

const empty_label: StringView = .{ .data = null, .length = 0 };
const vs_main_name: []const u8 = "vs_main";
const fs_main_name: []const u8 = "fs_main";

const alpha_blend: BlendState = .{
    .color = .{
        .operation = blend_add,
        .src_factor = blend_src_alpha,
        .dst_factor = blend_one_minus_src_alpha,
    },
    .alpha = .{
        .operation = blend_add,
        .src_factor = blend_src_alpha,
        .dst_factor = blend_one_minus_src_alpha,
    },
};

const unit_attr: VertexAttribute = .{
    .next_in_chain = null,
    .format = vertex_float32x2,
    .offset = 0,
    .shader_location = 0,
};

const instance_attrs = [_]VertexAttribute{
    .{
        .next_in_chain = null,
        .format = vertex_float32x4,
        .offset = 0,
        .shader_location = 1,
    },
    .{
        .next_in_chain = null,
        .format = vertex_float32x4,
        .offset = 16,
        .shader_location = 2,
    },
};

/// Initializes the full WebGPU graphics pipeline for Linux Wayland.
/// 1. Connects to WebGPU runtime (Instance).
/// 2. Binds the Wayland window to WebGPU (Surface).
/// 3. Queries the physical graphics card (Adapter).
/// 4. Opens a logical GPU device and execution queue (Device, Queue).
/// 5. Validates surface pixel format (BGRA8Unorm).
/// 6. Compiles the WGSL shader and constructs the render pipeline and buffers.
pub fn create(display: *anyopaque, wl_surface: *anyopaque) !Gpu {
    assert(@intFromPtr(display) != 0);
    assert(@intFromPtr(wl_surface) != 0);
    const instance = try create_instance();
    const surface = try create_surface(instance, display, wl_surface);
    const adapter = try request_adapter(instance, surface);
    const device = try request_device(instance, adapter);
    const queue = wgpuDeviceGetQueue(device);
    const format = try pick_format(surface, adapter);
    const resources = try create_resources(device, queue, format);
    return .{
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface = surface,
        .format = format,
        .configured_width = 0,
        .configured_height = 0,
        .pipeline = resources.pipeline,
        .quad_buffer = resources.quad,
        .instance_buffer = resources.instances,
        .uniform_buffer = resources.uniform,
        .bind_group = resources.bind_group,
    };
}

const PipelineResources = struct {
    pipeline: RenderPipeline,
    quad: Buffer,
    instances: Buffer,
    uniform: Buffer,
    bind_group: BindGroup,
};

/// Compiles the shader, creates VRAM buffers, writes the static unit quad, and builds the pipeline.
fn create_resources(
    device: Device,
    queue: Queue,
    format: TextureFormat,
) !PipelineResources {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(queue) != 0);
    const shader = create_shader(device);
    const buffers = try create_buffers(device);
    write_quad(queue, buffers.quad);
    const layout = create_bind_group_layout(device);
    const pipeline_layout = create_pipeline_layout(device, layout);
    const bind_group = create_bind_group(device, layout, buffers.uniform);
    const pipeline = create_pipeline(device, shader, pipeline_layout, format);
    return .{
        .pipeline = pipeline,
        .quad = buffers.quad,
        .instances = buffers.instances,
        .uniform = buffers.uniform,
        .bind_group = bind_group,
    };
}

/// Presents a frame by updating GPU buffers as needed, acquiring a swapchain texture,
/// and executing the clear and instanced draw render pass.
pub fn present(
    self: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    assert(header.instance_count <= draw.instance_cap);
    configure_surface(self, header.width_px, header.height_px);
    write_uploads(self, header, instances);
    const texture = try acquire_texture(self.surface);
    encode_submit_present(self, texture, header);
}

/// Creates the top-level WebGPU instance handle.
fn create_instance() !Instance {
    // wgpu-native v29.0.1.1 panics if TimedWaitAny is required. Startup waits
    // with WaitAny(0) plus ProcessEvents instead.
    const instance = wgpuCreateInstance(null) orelse return error.InstanceFailed;
    assert(@intFromPtr(instance) != 0);
    assert(wait_max >= 1);
    return instance;
}

/// Creates a WebGPU Surface backed by a Linux Wayland `wl_display` and `wl_surface`.
/// Uses the ChainedStruct mechanism (`s_type_wayland_surface`).
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

/// Asynchronously requests a physical GPU adapter compatible with the window surface.
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

/// Asynchronously requests a logical WebGPU Device and execution queue from the Adapter.
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

/// Pumps the wgpu event loop synchronously until an asynchronous future resolves.
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

/// Queries surface capabilities and confirms support for BGRA8Unorm texture format.
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

/// Helper that searches the list of supported surface formats for BGRA8Unorm.
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

/// Compiles the embedded WGSL shader text into a WebGPU ShaderModule handle.
fn create_shader(device: Device) ShaderModule {
    assert(@intFromPtr(device) != 0);
    assert(draw.shader_file.len >= 1);
    var source: ShaderSourceWgsl = .{
        .chain = .{ .next = null, .s_type = s_type_shader_source_wgsl },
        .code = .{
            .data = draw.shader_file.ptr,
            .length = draw.shader_file.len,
        },
    };
    const descriptor: ShaderModuleDescriptor = .{
        .next_in_chain = @ptrCast(&source.chain),
        .label = empty_label,
    };
    const shader = wgpuDeviceCreateShaderModule(device, &descriptor);
    assert(@intFromPtr(shader) != 0);
    return shader;
}

/// Allocates the static unit quad buffer, instance buffer, and uniform buffer in GPU VRAM.
fn create_buffers(device: Device) !Buffers {
    assert(@intFromPtr(device) != 0);
    const instance_bytes: u32 = draw.instance_cap * draw.instance_stride;
    const vertex_usage: Flags = usage_vertex | usage_copy_dst;
    const uniform_usage: Flags = usage_uniform | usage_copy_dst;
    const quad = try create_buffer(device, draw.quad_bytes, vertex_usage);
    const instances = try create_buffer(device, instance_bytes, vertex_usage);
    const uniform = try create_buffer(device, draw.uniform_bytes, uniform_usage);
    assert(@intFromPtr(instances) != 0);
    assert(@intFromPtr(uniform) != 0);
    return .{ .quad = quad, .instances = instances, .uniform = uniform };
}

/// Helper that creates a single WebGPU Buffer descriptor and allocates GPU memory.
fn create_buffer(device: Device, size: u32, usage: Flags) !Buffer {
    assert(size != 0);
    assert(usage != 0);
    const descriptor: BufferDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .usage = usage,
        .size = size,
        .mapped_at_creation = 0,
    };
    const buffer = wgpuDeviceCreateBuffer(device, &descriptor) orelse return error.BufferFailed;
    assert(@intFromPtr(buffer) != 0);
    return buffer;
}

/// Writes the static unit quad vertex coordinates (48 bytes) into GPU buffer 0 once at startup.
fn write_quad(queue: Queue, buffer: Buffer) void {
    assert(@intFromPtr(queue) != 0);
    assert(@intFromPtr(buffer) != 0);
    wgpuQueueWriteBuffer(queue, buffer, 0, @ptrCast(&draw.unit_quad), @intCast(draw.quad_bytes));
}

/// Defines the bind group layout for binding slot 0 (the orthographic projection matrix uniform).
/// Defines the bind group layout for binding slot 0 (the orthographic projection matrix uniform).
fn create_bind_group_layout(device: Device) BindGroupLayout {
    assert(@intFromPtr(device) != 0);
    const entry: BindGroupLayoutEntry = .{
        .next_in_chain = null,
        .binding = 0,
        .visibility = shader_vertex,
        .binding_array_size = 0,
        .buffer = .{
            .next_in_chain = null,
            .type = buffer_uniform,
            .has_dynamic_offset = 0,
            .min_binding_size = draw.matrix_bytes,
        },
        .sampler = std.mem.zeroes(SamplerBindingLayout),
        .texture = std.mem.zeroes(TextureBindingLayout),
        .storage_texture = std.mem.zeroes(StorageTextureBindingLayout),
    };
    const descriptor: BindGroupLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .entry_count = 1,
        .entries = @ptrCast(&entry),
    };
    const layout = wgpuDeviceCreateBindGroupLayout(device, &descriptor);
    assert(@intFromPtr(layout) != 0);
    return layout;
}

/// Bundles the bind group layouts into a top-level pipeline layout.
fn create_pipeline_layout(device: Device, bind_layout: BindGroupLayout) PipelineLayout {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(bind_layout) != 0);
    const descriptor: PipelineLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .bind_group_layout_count = 1,
        .bind_group_layouts = @ptrCast(&bind_layout),
        .immediate_size = 0,
    };
    const layout = wgpuDeviceCreatePipelineLayout(device, &descriptor);
    assert(@intFromPtr(layout) != 0);
    return layout;
}

/// Instantiates the bind group connecting the uniform buffer (at offset 0) to binding 0.
fn create_bind_group(device: Device, layout: BindGroupLayout, uniform: Buffer) BindGroup {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(uniform) != 0);
    const entry: BindGroupEntry = .{
        .next_in_chain = null,
        .binding = 0,
        .buffer = uniform,
        .offset = 0,
        .size = draw.uniform_bytes,
        .sampler = null,
        .texture_view = null,
    };
    const descriptor: BindGroupDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .layout = layout,
        .entry_count = 1,
        .entries = @ptrCast(&entry),
    };
    const group = wgpuDeviceCreateBindGroup(device, &descriptor);
    assert(@intFromPtr(group) != 0);
    return group;
}

/// Creates the complete render pipeline: vertex layouts, shaders, topology, and alpha blend.
fn create_pipeline(
    device: Device,
    shader: ShaderModule,
    layout: PipelineLayout,
    format: TextureFormat,
) RenderPipeline {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(shader) != 0);
    var buffers: [2]VertexBufferLayout = undefined;
    fill_vertex_layouts(&buffers);
    const vertex = vertex_state(shader, &buffers);
    const target: ColorTargetState = .{
        .next_in_chain = null,
        .format = format,
        .blend = &alpha_blend,
        .write_mask = color_write_all,
    };
    const fragment = fragment_state(shader, &target);
    const descriptor: RenderPipelineDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .layout = layout,
        .vertex = vertex,
        .primitive = .{
            .next_in_chain = null,
            .topology = topology_triangle_list,
            .strip_index_format = index_undefined,
            .front_face = front_ccw,
            .cull_mode = cull_none,
            .unclipped_depth = 0,
        },
        .depth_stencil = null,
        .multisample = .{
            .next_in_chain = null,
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alpha_to_coverage_enabled = 0,
        },
        .fragment = &fragment,
    };
    const pipeline = wgpuDeviceCreateRenderPipeline(device, &descriptor);
    // wgpu-native v29.0.1.1 panics on GetCompilationInfo. A non-null pipeline
    // is the compile barrier for this pin.
    assert(@intFromPtr(pipeline) != 0);
    return pipeline;
}

/// Configures the dual vertex buffer layout:
/// Buffer 0: step_vertex, 8-byte stride (unit quad points).
/// Buffer 1: step_instance, 32-byte stride (instance rect and color).
fn fill_vertex_layouts(buffers: *[2]VertexBufferLayout) void {
    buffers[0] = .{
        .next_in_chain = null,
        .step_mode = step_vertex,
        .array_stride = 8,
        .attribute_count = 1,
        .attributes = @ptrCast(&unit_attr),
    };
    buffers[1] = .{
        .next_in_chain = null,
        .step_mode = step_instance,
        .array_stride = draw.instance_stride,
        .attribute_count = 2,
        .attributes = &instance_attrs,
    };
    assert(buffers[0].attribute_count == 1);
    assert(buffers[1].attribute_count == 2);
}

/// Configures the vertex stage descriptor referencing the `vs_main` entry point.
fn vertex_state(shader: ShaderModule, buffers: [*]const VertexBufferLayout) VertexState {
    assert(@intFromPtr(shader) != 0);
    assert(vs_main_name.len == 7);
    return .{
        .next_in_chain = null,
        .module = shader,
        .entry_point = .{ .data = vs_main_name.ptr, .length = vs_main_name.len },
        .constant_count = 0,
        .constants = null,
        .buffer_count = 2,
        .buffers = buffers,
    };
}

/// Configures the fragment stage descriptor referencing the `fs_main` entry point.
fn fragment_state(shader: ShaderModule, target: *const ColorTargetState) FragmentState {
    assert(@intFromPtr(shader) != 0);
    assert(target.format == format_bgra8_unorm);
    return .{
        .next_in_chain = null,
        .module = shader,
        .entry_point = .{ .data = fs_main_name.ptr, .length = fs_main_name.len },
        .constant_count = 0,
        .constants = null,
        .target_count = 1,
        .targets = @ptrCast(target),
    };
}

/// Conditionally uploads uniform matrix and instance buffer data based on header flags.
fn write_uploads(
    self: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
) void {
    assert(header.instance_count <= draw.instance_cap);
    if ((header.flags & draw.flag_uniform) != 0) {
        wgpuQueueWriteBuffer(
            self.queue,
            self.uniform_buffer,
            0,
            @ptrCast(&header.ortho),
            @intCast(draw.matrix_bytes),
        );
    }
    if ((header.flags & draw.flag_instances) != 0) {
        if (header.instance_count != 0) {
            const byte_count: u32 = header.instance_count * draw.instance_stride;
            wgpuQueueWriteBuffer(
                self.queue,
                self.instance_buffer,
                0,
                @ptrCast(instances),
                @intCast(byte_count),
            );
        }
    }
    assert(@intFromPtr(self.queue) != 0);
}

/// Configures or reconfigures the swapchain when window pixel dimensions change.
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

/// Acquires the current swapchain texture for rendering.
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

/// Encodes the clear and draw render pass, submits commands, and presents to the surface.
fn encode_submit_present(
    self: *Gpu,
    texture: Texture,
    header: *const draw.PresentHeader,
) void {
    assert(@intFromPtr(texture) != 0);
    const view = wgpuTextureCreateView(texture, null);
    const encoder = wgpuDeviceCreateCommandEncoder(self.device, null);
    assert(@intFromPtr(view) != 0);
    assert(@intFromPtr(encoder) != 0);
    const pass = begin_clear_pass(encoder, view, header);
    draw_quads(self, pass, header.instance_count);
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

/// Begins a render pass configured with `load_op = load_clear` and the background slate color.
fn begin_clear_pass(
    encoder: CommandEncoder,
    view: TextureView,
    header: *const draw.PresentHeader,
) RenderPassEncoder {
    assert(@intFromPtr(encoder) != 0);
    assert(@intFromPtr(view) != 0);
    const attachment: RenderPassColorAttachment = .{
        .next_in_chain = null,
        .view = view,
        .depth_slice = depth_slice_undefined,
        .resolve_target = null,
        .load_op = load_clear,
        .store_op = store_store,
        .clear_value = .{
            .r = header.clear_r,
            .g = header.clear_g,
            .b = header.clear_b,
            .a = header.clear_a,
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
    return wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);
}

/// Binds pipeline, bind group 0, vertex buffers 0 and 1, and draws 6 vertices instanced.
fn draw_quads(self: *Gpu, pass: RenderPassEncoder, instance_count: u32) void {
    assert(@intFromPtr(pass) != 0);
    assert(instance_count <= draw.instance_cap);
    wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.quad_buffer, 0, whole_size);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.instance_buffer, 0, whole_size);
    wgpuRenderPassEncoderDraw(pass, draw.vertex_count, instance_count, 0, 0);
}

/// C ABI callback for adapter request completion.
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

/// C ABI callback for device request completion.
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

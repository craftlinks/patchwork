//! Native Linux WebGPU backend over the wgpu-native C ABI (pinned to v29.0.1.1).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Hand-Written C ABI Binding
//! The backend links `libwgpu_native.so` through `webgpu.h` types declared here with
//! `extern struct` and `callconv(.c)`, so the build needs no wrapper library, code generator,
//! or package manager. Every declaration is pinned to the wgpu-native version above; a version
//! bump must re-check each struct against the new header (the `comptime` block after the
//! struct declarations enforces the sizes this file depends on).
//!
//! ## 2. Opaque Handles and Chained Structs
//! Each handle is a distinct `*opaque {}` type, so passing an `Adapter` where a `Device` is
//! expected is a compile error rather than a driver crash.
//!
//! Extensible descriptors start with `next_in_chain: ?*ChainedStruct`, a singly linked list of
//! tagged structs. The native library reads `s_type` and casts the node to the matching
//! struct, so every chained struct must begin with `chain: ChainedStruct` and carry the right
//! tag (`s_type_wayland_surface`, `s_type_shader_source_wgsl`,
//! `s_type_surface_configuration_extras`). The last tag lives in wgpu-native's extension
//! range, not in core WebGPU. Chain nodes must outlive the call that consumes them, which is
//! why each is a local in the function that passes it.
//!
//! ## 3. Vertex Layout Contract
//! Both pipelines use the same two-buffer layout (`fill_vertex_layouts`):
//! - Buffer 0, `step_vertex`: the shared unit quad (`draw.unit_quad`), one `float32x2`
//!   attribute at location 0.
//! - Buffer 1, `step_instance`: four `float32x4` attributes at locations 1 to 4, stride
//!   `draw.instance_stride`. For quads they are rect, fill, shape `(radius, hover, down,
//!   kind)`, and clip. `font.Glyph` is fetched through the same attributes.
//!
//! The attribute offsets are the field offsets of `draw.Instance` and `font.Glyph`;
//! `instance_attrs` is pinned to them by `comptime` asserts so a struct edit cannot desync
//! the vertex fetch. The browser host (`web/shell.js`) mirrors the same locations.
//!
//! ## 4. Frame Lifecycle (`present`)
//! ```text
//! configure_surface  -> only when the physical size differs from the configured size
//! write_uploads      -> only the buffers named by header.flags (see draw.UploadCursor)
//! acquire_texture    -> current swapchain texture, or an error
//! encode_submit_present
//!     clear pass -> draw_quads -> draw_glyphs -> submit -> present -> release handles
//! ```
//! `present` must be called with nonzero dimensions and with counts within the capacities
//! the buffers were created for. Every per-frame handle (texture, view, encoder, pass,
//! command buffer) is released before `encode_submit_present` returns.
//!
//! ## 5. Uniform Buffer and Bind Groups
//! Group 0 is one uniform buffer (matrix at offset 0, theme at offset `draw.matrix_bytes`),
//! sized `draw.uniform_bytes` (see `draw.zig` for the WebGPU uniform alignment rule). It is
//! visible to vertex and fragment stages and shared by both pipelines through one explicit
//! layout, because `layout: auto` layouts are private to a pipeline and cannot be shared.
//! Group 1 (glyph pipeline only) holds the atlas texture and a filtering sampler with
//! clamp-to-edge addressing; the baker's half-texel UV inset (see `font.zig`) keeps linear
//! filtering from sampling outside a glyph cell.
//!
//! ## 6. Texture Upload Rules
//! - Texture and buffer usage flags use different bit assignments: `COPY_DST` is
//!   `texture_usage_copy_dst` for textures but `usage_copy_dst` for buffers, and the buffer
//!   value is `STORAGE_BINDING` on a texture, which `r8unorm` forbids and which makes
//!   `wgpuDeviceCreateTexture` panic. `create_atlas` asserts the two differ.
//! - WebGPU requires `bytesPerRow` to be a multiple of 256 for buffer-to-texture copies
//!   (`GPUCommandEncoder.copyBufferToTexture`). `wgpuQueueWriteTexture` does not enforce it,
//!   but the atlas rows satisfy it anyway so a staging-buffer upload would need no repacking;
//!   the `comptime` block asserts it.
//! - Texture writes use `TexelCopyTextureInfo` and `TexelCopyBufferLayout`, which must match
//!   `wgpuQueueWriteTexture` field for field.
//!
//! ## 7. wgpu-native v29.0.1.1 Workarounds
//! Delete each when the pin moves to a release that fixes it.
//! - `wgpuInstanceWaitAny` is declared in the header but panics inside Rust. `wait_future`
//!   instead pumps `wgpuInstanceProcessEvents` in a loop bounded by `wait_max`.
//! - `wgpuShaderModuleGetCompilationInfo` panics, so shader and pipeline creation is checked
//!   only by a non-null handle.
//! - `desiredMaximumFrameLatency` is requested as `frame_latency` through
//!   `SurfaceConfigurationExtras`, but Mesa's Wayland WSI clamps it to its swapchain image
//!   minimum. It is therefore not a pacing control; pacing comes from the window loop (see
//!   `linux_window.zig`) and the present mode (section 8).
//!
//! ## 8. Present Mode: Mailbox When Offered
//! `pick_present_mode` prefers `present_mailbox` and falls back to `present_fifo`, which
//! WebGPU requires every surface to support. The window loop already commits at most once
//! per `wl_callback.done`, so mailbox cannot outrun the display. The reason to prefer it is
//! a Mesa behavior: with a compositor that offers `wp_fifo_v1` (observed on Mesa 26.2.2 with
//! Hyprland 0.56.2), each FIFO present becomes two commits, one with content and one empty
//! commit held behind a FIFO barrier. The held commit delays every other `wl_surface.frame`
//! callback and the loop then alternates between one-refresh and two-refresh gaps. Mailbox
//! presents with one attach and one commit. Mailbox does not tear on Wayland because the
//! compositor still latches whole buffers; tearing needs `wp_tearing_control_v1`. Remove the
//! preference if a Mesa release makes FIFO a single commit per present.
//!
//! ## 9. TigerStyle Invariants
//! All GPU memory is created once in `create`; the frame path allocates nothing and never
//! creates or destroys long-lived resources. Searches over driver-reported lists are
//! bounded by `present_mode_cap` and `format_cap`, and waiting is bounded by `wait_max`.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const font = @import("../font.zig");
const theme = @import("../theme.zig");

/// Every native WebGPU handle the backend owns. Created once by `create`; never freed, since
/// the process lifetime equals the window lifetime.
pub const Gpu = struct {
    instance: Instance,
    adapter: Adapter,
    device: Device,
    queue: Queue,
    surface: Surface,
    format: TextureFormat,
    /// Chosen once in `create` by `pick_present_mode`; reused on every reconfigure.
    present_mode: PresentMode,
    configured_width: u32,
    configured_height: u32,
    pipeline: RenderPipeline,
    glyph_pipeline: RenderPipeline,
    quad_buffer: Buffer,
    instance_buffer: Buffer,
    glyph_buffer: Buffer,
    uniform_buffer: Buffer,
    bind_group: BindGroup,
    glyph_bind_group: BindGroup,
    atlas: Texture,
    glyph_sampler: Sampler,
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
const Sampler = *opaque {};

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
/// `WGPUPresentMode_Fifo`. Required by WebGPU to be available everywhere.
const present_fifo: PresentMode = 0x00000001;
/// `WGPUPresentMode_Mailbox`. A new frame replaces any queued, unshown one. See module guide
/// section 8 for why it is preferred over FIFO.
const present_mailbox: PresentMode = 0x00000004;
/// Upper bound on driver-reported present modes we are willing to scan. WebGPU defines fewer
/// modes than this, so a larger count means a malformed report and selects FIFO.
const present_mode_cap: u32 = 8;
/// wgpu-native `WGPUSType_SurfaceConfigurationExtras`. Not a core WebGPU sType.
const s_type_surface_configuration_extras: SType = 0x00030008;
/// Requested `desiredMaximumFrameLatency`, in refreshes between acquire and presentation.
/// The driver may clamp it upward (module guide section 7), so it is a request only.
const frame_latency: u32 = 1;
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
const shader_fragment: Flags = 0x0000000000000002;
const format_r8_unorm: TextureFormat = 0x00000001;
/// Texture `COPY_DST` is 0x2. Buffer `usage_copy_dst` is 0x8, which is texture `STORAGE_BINDING`.
const texture_usage_copy_dst: TextureUsage = 0x0000000000000002;
const usage_texture_binding: TextureUsage = 0x0000000000000004;
const dimension_2d: u32 = 0x00000002;
const sample_float: u32 = 0x00000002;
const view_2d: u32 = 0x00000002;
const address_clamp_to_edge: u32 = 0x00000001;
const filter_linear: u32 = 0x00000002;
const mip_nearest: u32 = 0x00000001;
const sampler_filtering: u32 = 0x00000002;
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

/// wgpu-native chain on `SurfaceConfiguration`. `desired_maximum_frame_latency` is
/// the number of monitor refreshes from `GetCurrentTexture` to presentation.
const SurfaceConfigurationExtras = extern struct {
    chain: ChainedStruct,
    desired_maximum_frame_latency: u32,
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

const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
};

const Origin3D = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

const TexelCopyBufferLayout = extern struct {
    offset: u64,
    bytes_per_row: u32,
    rows_per_image: u32,
};

const TexelCopyTextureInfo = extern struct {
    texture: Texture,
    mip_level: u32,
    origin: Origin3D,
    aspect: u32,
};

const TextureDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    usage: TextureUsage,
    dimension: u32,
    size: Extent3D,
    format: TextureFormat,
    mip_level_count: u32,
    sample_count: u32,
    view_format_count: usize,
    view_formats: ?[*]const TextureFormat,
};

const SamplerDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    address_mode_u: u32,
    address_mode_v: u32,
    address_mode_w: u32,
    mag_filter: u32,
    min_filter: u32,
    mipmap_filter: u32,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
    compare: u32,
    max_anisotropy: u16,
};

comptime {
    assert(@sizeOf(Extent3D) == 12);
    assert(@sizeOf(Origin3D) == 12);
    assert(@sizeOf(TexelCopyBufferLayout) == 16);
    assert(@sizeOf(TexelCopyTextureInfo) == 32);
    assert(@sizeOf(TextureDescriptor) == 80);
    assert(@sizeOf(SamplerDescriptor) == 64);
}

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
extern fn wgpuDeviceCreateTexture(
    device: Device,
    descriptor: *const TextureDescriptor,
) ?Texture;
extern fn wgpuDeviceCreateSampler(
    device: Device,
    descriptor: *const SamplerDescriptor,
) Sampler;
extern fn wgpuQueueWriteTexture(
    queue: Queue,
    destination: *const TexelCopyTextureInfo,
    data: [*]const u8,
    data_size: usize,
    data_layout: *const TexelCopyBufferLayout,
    write_size: *const Extent3D,
) void;
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
    // chain (16) plus the latency u32, rounded up to the pointer alignment.
    assert(@sizeOf(SurfaceConfigurationExtras) == 24);

    // The glyph pipeline reuses the instance vertex layout, so both structs must expose the
    // same four vec4 groups at the offsets in `instance_attrs`, and the unit-quad buffer
    // stride in `fill_vertex_layouts` must match `draw.unit_quad`.
    assert(instance_attrs[0].offset == @offsetOf(draw.Instance, "x"));
    assert(instance_attrs[1].offset == @offsetOf(draw.Instance, "r"));
    assert(instance_attrs[2].offset == @offsetOf(draw.Instance, "radius"));
    assert(instance_attrs[3].offset == @offsetOf(draw.Instance, "clip_x0"));
    assert(instance_attrs[0].offset == @offsetOf(font.Glyph, "x"));
    assert(instance_attrs[1].offset == @offsetOf(font.Glyph, "u0"));
    assert(instance_attrs[2].offset == @offsetOf(font.Glyph, "r"));
    assert(instance_attrs[3].offset == @offsetOf(font.Glyph, "clip_x0"));
    assert(@sizeOf(draw.Instance) == @sizeOf(font.Glyph));
    assert(draw.quad_bytes == draw.vertex_count * 2 * @sizeOf(f32));
    // Buffer-to-texture copy rows must be 256-byte aligned (module guide section 6).
    assert(font.atlas_width % 256 == 0);
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

/// Per-instance vertex fetch shared by the quad and glyph pipelines. `shader_location` values
/// match `@location` in `quad.wgsl` and `glyph.wgsl`. Offsets are pinned to the field offsets
/// of `draw.Instance` and `font.Glyph` by the `comptime` block below.
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
    .{
        .next_in_chain = null,
        .format = vertex_float32x4,
        .offset = 32,
        .shader_location = 3,
    },
    .{
        .next_in_chain = null,
        .format = vertex_float32x4,
        .offset = 48,
        .shader_location = 4,
    },
};

/// Creates the instance, Wayland-backed surface, adapter, device, queue, and every long-lived
/// GPU resource. `display` and `wl_surface` must be live Wayland handles that outlive the
/// returned `Gpu`. The swapchain is left unconfigured until the first `present`.
/// Errors: any failed handle request, `error.WaitTimeout`, or `error.Bgra8Unsupported`.
pub fn create(display: *anyopaque, wl_surface: *anyopaque) !Gpu {
    assert(@intFromPtr(display) != 0);
    assert(@intFromPtr(wl_surface) != 0);
    const instance = try create_instance();
    const surface = try create_surface(instance, display, wl_surface);
    const adapter = try request_adapter(instance, surface);
    const device = try request_device(instance, adapter);
    const queue = wgpuDeviceGetQueue(device);
    const chosen = try pick_format(surface, adapter);
    const resources = try create_resources(device, queue, chosen.format);
    return .{
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface = surface,
        .format = chosen.format,
        .present_mode = chosen.present_mode,
        .configured_width = 0,
        .configured_height = 0,
        .pipeline = resources.pipeline,
        .glyph_pipeline = resources.glyph_pipeline,
        .quad_buffer = resources.quad,
        .instance_buffer = resources.instances,
        .glyph_buffer = resources.glyph_buffer,
        .uniform_buffer = resources.uniform,
        .bind_group = resources.bind_group,
        .glyph_bind_group = resources.glyph_bind_group,
        .atlas = resources.atlas,
        .glyph_sampler = resources.glyph_sampler,
    };
}

const PipelineResources = struct {
    pipeline: RenderPipeline,
    glyph_pipeline: RenderPipeline,
    quad: Buffer,
    instances: Buffer,
    glyph_buffer: Buffer,
    uniform: Buffer,
    bind_group: BindGroup,
    glyph_bind_group: BindGroup,
    atlas: Texture,
    glyph_sampler: Sampler,
};

/// Builds every GPU resource for both pipelines and uploads the static unit quad and atlas.
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
    const glyphs = try create_glyph_resources(device, queue, format, layout);
    return .{
        .pipeline = pipeline,
        .glyph_pipeline = glyphs.pipeline,
        .quad = buffers.quad,
        .instances = buffers.instances,
        .glyph_buffer = glyphs.buffer,
        .uniform = buffers.uniform,
        .bind_group = bind_group,
        .glyph_bind_group = glyphs.bind_group,
        .atlas = glyphs.atlas,
        .glyph_sampler = glyphs.sampler,
    };
}

/// GPU resources owned by the glyph pipeline alone.
const GlyphResources = struct {
    pipeline: RenderPipeline,
    buffer: Buffer,
    bind_group: BindGroup,
    atlas: Texture,
    sampler: Sampler,
};

/// Creates the glyph instance buffer (`font.glyph_cap` records of `font.glyph_stride` bytes),
/// the uploaded atlas texture, sampler, group 1 layout and bind group, and the glyph pipeline.
/// `uniform_layout` is the shared group 0 layout so both pipelines can bind one bind group.
fn create_glyph_resources(
    device: Device,
    queue: Queue,
    format: TextureFormat,
    uniform_layout: BindGroupLayout,
) !GlyphResources {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(uniform_layout) != 0);
    const shader = create_glyph_shader(device);
    const byte_count: u32 = font.glyph_cap * font.glyph_stride;
    const buffer = try create_buffer(device, byte_count, usage_vertex | usage_copy_dst);
    const atlas = try create_atlas(device);
    write_atlas(queue, atlas);
    const sampler = create_glyph_sampler(device);
    const glyph_layout = create_glyph_bind_group_layout(device);
    const bind_group = create_glyph_bind_group(device, glyph_layout, atlas, sampler);
    const pipeline_layout = create_glyph_pipeline_layout(device, uniform_layout, glyph_layout);
    const pipeline = create_glyph_pipeline(device, shader, pipeline_layout, format);
    assert(@intFromPtr(pipeline) != 0);
    assert(font.atlas_bytes.len == 131072);
    return .{
        .pipeline = pipeline,
        .buffer = buffer,
        .bind_group = bind_group,
        .atlas = atlas,
        .sampler = sampler,
    };
}

/// Presents one frame; the sequence is module guide section 4. `header` dimensions must be
/// nonzero and its counts within capacity. `instances` and `glyphs` must hold at least the
/// header's counts when the matching upload flag is set. Returns the error from
/// `acquire_texture` when no swapchain texture is available.
pub fn present(
    self: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
    glyphs: [*]const font.Glyph,
) !void {
    assert(header.width_px != 0);
    assert(header.height_px != 0);
    assert(header.instance_count <= draw.instance_cap);
    assert(header.glyph_count <= font.glyph_cap);
    configure_surface(self, header.width_px, header.height_px);
    write_uploads(self, header, instances, glyphs);
    const texture = try acquire_texture(self.surface);
    encode_submit_present(self, texture, header);
}

/// Creates the top-level WebGPU instance handle. Startup waits use `wait_future`, not
/// `WaitAny` (module guide section 7).
fn create_instance() !Instance {
    const instance = wgpuCreateInstance(null) orelse return error.InstanceFailed;
    assert(@intFromPtr(instance) != 0);
    assert(wait_max >= 1);
    return instance;
}

/// Creates a surface for a Wayland `wl_display` and `wl_surface` via a chained
/// `SurfaceSourceWayland` node.
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

/// Requests an adapter compatible with `surface` and blocks (bounded) until it resolves.
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

/// Requests a device from `adapter` and blocks (bounded) until it resolves.
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

/// Pumps `wgpuInstanceProcessEvents` until a callback sets `ok`, at most `wait_max`
/// iterations of a short sleep each. `future` is unused because `WaitAny` is unavailable
/// (module guide section 7). Returns `error.WaitTimeout` if the callback never fires.
fn wait_future(instance: Instance, future: Future, ok: *bool) !void {
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

/// Swapchain format and present mode chosen from the surface capabilities. The format is
/// always `format_bgra8_unorm`, which the pipelines are built for.
const SurfaceChoice = struct {
    format: TextureFormat,
    present_mode: PresentMode,
};

/// Queries surface capabilities, requires BGRA8Unorm, and picks the present mode
/// (module guide section 8). The capability lists are freed on every path.
/// Errors: `error.CapabilitiesFailed`, `error.Bgra8Unsupported`.
fn pick_format(surface: Surface, adapter: Adapter) !SurfaceChoice {
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
    const present_mode = pick_present_mode(capabilities);
    wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    assert(format == format_bgra8_unorm);
    assert(present_mode == present_mailbox or present_mode == present_fifo);
    return .{ .format = format, .present_mode = present_mode };
}

/// Returns `present_mailbox` if listed, otherwise `present_fifo`. A null list, an empty list,
/// or a count above `present_mode_cap` also yields FIFO, which WebGPU requires every surface
/// to support. Locked by the test "present mode prefers mailbox and falls back to fifo".
fn pick_present_mode(capabilities: SurfaceCapabilities) PresentMode {
    const modes = capabilities.present_modes orelse return present_fifo;
    const count_usize = capabilities.present_mode_count;
    if (count_usize == 0) {
        return present_fifo;
    }
    if (count_usize > present_mode_cap) {
        return present_fifo;
    }
    assert(count_usize >= 1);
    assert(count_usize <= present_mode_cap);
    const count: u32 = @intCast(count_usize);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (modes[index] == present_mailbox) {
            return present_mailbox;
        }
    }
    assert(index == count);
    return present_fifo;
}

/// Returns `format_bgra8_unorm` if listed, else null. A null list, an empty list, or a count
/// above `format_cap` yields null. Locked by the test "bgra8 lookup rejects malformed lists".
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

/// Creates the quad shader module from `draw.shader_file`.
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

/// Allocates the unit quad, instance, and uniform buffers. Sizes are fixed for the life of
/// the device; a frame uploads only the records it has.
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

/// Creates one GPU buffer; `size` and `usage` must be nonzero.
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

/// Uploads `draw.unit_quad` (`draw.quad_bytes` bytes) once at startup.
fn write_quad(queue: Queue, buffer: Buffer) void {
    assert(@intFromPtr(queue) != 0);
    assert(@intFromPtr(buffer) != 0);
    wgpuQueueWriteBuffer(queue, buffer, 0, @ptrCast(&draw.unit_quad), @intCast(draw.quad_bytes));
}

/// Group 0 layout: one uniform buffer of `draw.uniform_bytes`, visible to vertex and fragment.
fn create_bind_group_layout(device: Device) BindGroupLayout {
    assert(@intFromPtr(device) != 0);
    const entry: BindGroupLayoutEntry = .{
        .next_in_chain = null,
        .binding = 0,
        .visibility = shader_vertex | shader_fragment,
        .binding_array_size = 0,
        .buffer = .{
            .next_in_chain = null,
            .type = buffer_uniform,
            .has_dynamic_offset = 0,
            .min_binding_size = draw.uniform_bytes,
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

/// Quad pipeline layout: group 0 only.
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

/// Binds the whole uniform buffer to group 0 binding 0.
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

/// Quad render pipeline: shared vertex layout, triangle list, straight-alpha source-over blend.
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
    // `GetCompilationInfo` is unusable on this pin (module guide section 7), so a non-null
    // pipeline is the only compile check.
    assert(@intFromPtr(pipeline) != 0);
    return pipeline;
}

/// Fills the two-buffer vertex layout described in module guide section 3.
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
        .attribute_count = 4,
        .attributes = &instance_attrs,
    };
    assert(buffers[0].attribute_count == 1);
    assert(buffers[1].attribute_count == 4);
}

/// Vertex stage descriptor using entry point `vs_main`.
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

/// Fragment stage descriptor using entry point `fs_main`; `target` must be BGRA8Unorm.
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

/// Uploads the buffers selected by `header.flags`. The uniform upload writes the matrix at
/// offset 0 and the theme at offset `draw.matrix_bytes`. Instance and glyph uploads write
/// only the first `count` records and are skipped when the count is zero.
fn write_uploads(
    self: *Gpu,
    header: *const draw.PresentHeader,
    instances: [*]const draw.Instance,
    glyphs: [*]const font.Glyph,
) void {
    assert(header.instance_count <= draw.instance_cap);
    assert(header.glyph_count <= font.glyph_cap);
    if ((header.flags & draw.flag_uniform) != 0) {
        wgpuQueueWriteBuffer(
            self.queue,
            self.uniform_buffer,
            0,
            @ptrCast(&header.ortho),
            @intCast(draw.matrix_bytes),
        );
        wgpuQueueWriteBuffer(
            self.queue,
            self.uniform_buffer,
            draw.matrix_bytes,
            @ptrCast(&theme.chrome),
            @intCast(theme.bytes),
        );
    }
    if ((header.flags & draw.flag_instances) != 0) {
        if (header.instance_count != 0) {
            // Paired with the Wasm export and `web/shell.js`, which check the same stride.
            assert(draw.instance_stride == 64);
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
    if ((header.flags & draw.flag_glyphs) != 0) {
        if (header.glyph_count != 0) {
            assert(font.glyph_stride == 64);
            const byte_count: u32 = header.glyph_count * font.glyph_stride;
            wgpuQueueWriteBuffer(
                self.queue,
                self.glyph_buffer,
                0,
                @ptrCast(glyphs),
                @intCast(byte_count),
            );
        }
    }
    assert(@intFromPtr(self.queue) != 0);
}

/// Configures the swapchain, or reconfigures it when the physical size differs from the last
/// configuration; otherwise a no-op. Both dimensions must be nonzero. Requests `frame_latency`
/// through a chained `SurfaceConfigurationExtras` and uses `self.present_mode`.
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
    var extras: SurfaceConfigurationExtras = .{
        .chain = .{ .next = null, .s_type = s_type_surface_configuration_extras },
        .desired_maximum_frame_latency = frame_latency,
    };
    const config: SurfaceConfiguration = .{
        .next_in_chain = @ptrCast(&extras.chain),
        .device = self.device,
        .format = self.format,
        .usage = usage_render_attachment,
        .width = width_px,
        .height = height_px,
        .view_format_count = 0,
        .view_formats = null,
        .alpha_mode = alpha_auto,
        .present_mode = self.present_mode,
    };
    wgpuSurfaceConfigure(self.surface, &config);
    self.configured_width = width_px;
    self.configured_height = height_px;
    assert(extras.chain.s_type == s_type_surface_configuration_extras);
    assert(extras.desired_maximum_frame_latency == frame_latency);
}

/// Acquires the current swapchain texture. Optimal and suboptimal statuses both succeed;
/// the caller owns the texture and releases it after present.
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

/// Records the clear pass with both draws, submits, presents, and releases every handle it
/// created plus `texture`.
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
    draw_glyphs(self, pass, header.glyph_count);
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

/// Begins a single-attachment pass that clears to the header's clear color and stores.
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

/// Draws `instance_count` quads; zero is valid and draws nothing.
fn draw_quads(self: *Gpu, pass: RenderPassEncoder, instance_count: u32) void {
    assert(@intFromPtr(pass) != 0);
    assert(instance_count <= draw.instance_cap);
    wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.quad_buffer, 0, whole_size);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.instance_buffer, 0, whole_size);
    wgpuRenderPassEncoderDraw(pass, draw.vertex_count, instance_count, 0, 0);
}

/// Creates the single-mip `r8unorm` atlas texture sized `font.atlas_width` by
/// `font.atlas_height`. Must use `texture_usage_copy_dst`, never the buffer flag
/// (module guide section 6).
fn create_atlas(device: Device) !Texture {
    assert(@intFromPtr(device) != 0);
    assert(texture_usage_copy_dst != usage_copy_dst);
    assert(font.atlas_height == 256);
    const descriptor: TextureDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .usage = texture_usage_copy_dst | usage_texture_binding,
        .dimension = dimension_2d,
        .size = .{
            .width = font.atlas_width,
            .height = font.atlas_height,
            .depth_or_array_layers = 1,
        },
        .format = format_r8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
        .view_format_count = 0,
        .view_formats = null,
    };
    const texture = wgpuDeviceCreateTexture(device, &descriptor) orelse return error.AtlasFailed;
    assert(@intFromPtr(texture) != 0);
    assert(descriptor.format == format_r8_unorm);
    return texture;
}

/// Uploads `font.atlas_bytes` once at startup. Rows are tightly packed, so
/// `bytes_per_row` equals `font.atlas_width` (alignment rule in module guide section 6).
fn write_atlas(queue: Queue, texture: Texture) void {
    assert(@intFromPtr(queue) != 0);
    assert(@intFromPtr(texture) != 0);
    assert(font.atlas_width % 256 == 0);
    assert(font.atlas_bytes.len == 131072);
    const destination: TexelCopyTextureInfo = .{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = 0,
    };
    const layout: TexelCopyBufferLayout = .{
        .offset = 0,
        .bytes_per_row = font.atlas_width,
        .rows_per_image = font.atlas_height,
    };
    const size: Extent3D = .{
        .width = font.atlas_width,
        .height = font.atlas_height,
        .depth_or_array_layers = 1,
    };
    wgpuQueueWriteTexture(
        queue,
        &destination,
        font.atlas_bytes.ptr,
        font.atlas_bytes.len,
        &layout,
        &size,
    );
    assert(layout.bytes_per_row == 512);
    assert(size.depth_or_array_layers == 1);
}

/// Bilinear sampler with clamp-to-edge addressing on all axes; edge bleed is prevented by
/// the baker's UV inset (module guide section 5).
fn create_glyph_sampler(device: Device) Sampler {
    assert(@intFromPtr(device) != 0);
    const descriptor: SamplerDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .address_mode_u = address_clamp_to_edge,
        .address_mode_v = address_clamp_to_edge,
        .address_mode_w = address_clamp_to_edge,
        .mag_filter = filter_linear,
        .min_filter = filter_linear,
        .mipmap_filter = mip_nearest,
        .lod_min_clamp = 0,
        .lod_max_clamp = 32,
        .compare = 0,
        .max_anisotropy = 1,
    };
    const sampler = wgpuDeviceCreateSampler(device, &descriptor);
    assert(@intFromPtr(sampler) != 0);
    assert(descriptor.mag_filter == filter_linear);
    return sampler;
}

/// Group 1 layout: binding 0 is the float 2D atlas texture, binding 1 a filtering sampler,
/// both fragment-only.
fn create_glyph_bind_group_layout(device: Device) BindGroupLayout {
    assert(@intFromPtr(device) != 0);
    const entries = [2]BindGroupLayoutEntry{
        .{
            .next_in_chain = null,
            .binding = 0,
            .visibility = shader_fragment,
            .binding_array_size = 0,
            .buffer = std.mem.zeroes(BufferBindingLayout),
            .sampler = std.mem.zeroes(SamplerBindingLayout),
            .texture = .{
                .next_in_chain = null,
                .sample_type = sample_float,
                .view_dimension = view_2d,
                .multisampled = 0,
            },
            .storage_texture = std.mem.zeroes(StorageTextureBindingLayout),
        },
        .{
            .next_in_chain = null,
            .binding = 1,
            .visibility = shader_fragment,
            .binding_array_size = 0,
            .buffer = std.mem.zeroes(BufferBindingLayout),
            .sampler = .{
                .next_in_chain = null,
                .type = sampler_filtering,
            },
            .texture = std.mem.zeroes(TextureBindingLayout),
            .storage_texture = std.mem.zeroes(StorageTextureBindingLayout),
        },
    };
    const descriptor: BindGroupLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .entry_count = entries.len,
        .entries = &entries,
    };
    const layout = wgpuDeviceCreateBindGroupLayout(device, &descriptor);
    assert(@intFromPtr(layout) != 0);
    assert(entries[0].binding == 0);
    return layout;
}

/// Group 1 bind group: a default view of `texture` at binding 0 and `sampler` at binding 1.
fn create_glyph_bind_group(
    device: Device,
    layout: BindGroupLayout,
    texture: Texture,
    sampler: Sampler,
) BindGroup {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(texture) != 0);
    const view = wgpuTextureCreateView(texture, null);
    assert(@intFromPtr(view) != 0);
    const entries = [2]BindGroupEntry{
        .{
            .next_in_chain = null,
            .binding = 0,
            .buffer = null,
            .offset = 0,
            .size = 0,
            .sampler = null,
            .texture_view = view,
        },
        .{
            .next_in_chain = null,
            .binding = 1,
            .buffer = null,
            .offset = 0,
            .size = 0,
            .sampler = sampler,
            .texture_view = null,
        },
    };
    const descriptor: BindGroupDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .layout = layout,
        .entry_count = entries.len,
        .entries = &entries,
    };
    const group = wgpuDeviceCreateBindGroup(device, &descriptor);
    assert(@intFromPtr(group) != 0);
    assert(entries[1].sampler != null);
    return group;
}

/// Glyph pipeline layout: shared group 0 followed by the atlas group 1.
fn create_glyph_pipeline_layout(
    device: Device,
    uniform_layout: BindGroupLayout,
    glyph_layout: BindGroupLayout,
) PipelineLayout {
    assert(@intFromPtr(device) != 0);
    assert(@intFromPtr(uniform_layout) != 0);
    const groups = [2]BindGroupLayout{ uniform_layout, glyph_layout };
    const descriptor: PipelineLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .bind_group_layout_count = groups.len,
        .bind_group_layouts = &groups,
        .immediate_size = 0,
    };
    const layout = wgpuDeviceCreatePipelineLayout(device, &descriptor);
    assert(@intFromPtr(layout) != 0);
    assert(descriptor.bind_group_layout_count == 2);
    return layout;
}

/// Creates the glyph shader module from `font.shader_file`.
fn create_glyph_shader(device: Device) ShaderModule {
    assert(@intFromPtr(device) != 0);
    assert(font.shader_file.len >= 1);
    var source: ShaderSourceWgsl = .{
        .chain = .{ .next = null, .s_type = s_type_shader_source_wgsl },
        .code = .{
            .data = font.shader_file.ptr,
            .length = font.shader_file.len,
        },
    };
    const descriptor: ShaderModuleDescriptor = .{
        .next_in_chain = @ptrCast(&source.chain),
        .label = empty_label,
    };
    const shader = wgpuDeviceCreateShaderModule(device, &descriptor);
    assert(@intFromPtr(shader) != 0);
    assert(font.glyph_stride == 64);
    return shader;
}

/// Glyph render pipeline. Reuses `fill_vertex_layouts` and `alpha_blend`, which is valid
/// because `font.Glyph` has the same attribute layout as `draw.Instance`.
fn create_glyph_pipeline(
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
    assert(@intFromPtr(pipeline) != 0);
    assert(format == format_bgra8_unorm);
    return pipeline;
}

/// Draws `glyph_count` glyph quads in the already-open pass; issues no commands when zero.
fn draw_glyphs(self: *Gpu, pass: RenderPassEncoder, glyph_count: u32) void {
    assert(@intFromPtr(pass) != 0);
    assert(glyph_count <= font.glyph_cap);
    if (glyph_count == 0) {
        assert(glyph_count == 0);
        return;
    }
    wgpuRenderPassEncoderSetPipeline(pass, self.glyph_pipeline);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
    wgpuRenderPassEncoderSetBindGroup(pass, 1, self.glyph_bind_group, 0, null);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.quad_buffer, 0, whole_size);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.glyph_buffer, 0, whole_size);
    wgpuRenderPassEncoderDraw(pass, draw.vertex_count, glyph_count, 0, 0);
}

/// C ABI callback: `userdata1` is the `AdapterSlot` that `wait_future` polls.
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

/// C ABI callback: `userdata1` is the `DeviceSlot` that `wait_future` polls.
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

// Locks the present-mode policy: mailbox only when listed within the scan bound, FIFO for
// every other input including malformed reports.
test "present mode prefers mailbox and falls back to fifo" {
    const with_mailbox = [_]PresentMode{ present_fifo, present_mailbox };
    const fifo_only = [_]PresentMode{present_fifo};
    var capabilities = std.mem.zeroes(SurfaceCapabilities);

    try std.testing.expectEqual(present_fifo, pick_present_mode(capabilities));

    capabilities.present_modes = &with_mailbox;
    capabilities.present_mode_count = with_mailbox.len;
    try std.testing.expectEqual(present_mailbox, pick_present_mode(capabilities));

    capabilities.present_modes = &fifo_only;
    capabilities.present_mode_count = fifo_only.len;
    try std.testing.expectEqual(present_fifo, pick_present_mode(capabilities));

    capabilities.present_mode_count = 0;
    try std.testing.expectEqual(present_fifo, pick_present_mode(capabilities));

    // A count past the scan bound is rejected before the list is read.
    capabilities.present_modes = &with_mailbox;
    capabilities.present_mode_count = present_mode_cap + 1;
    try std.testing.expectEqual(present_fifo, pick_present_mode(capabilities));
}

// Locks the format lookup: BGRA8Unorm is found when listed, and null, empty, or oversized
// lists are rejected.
test "bgra8 lookup rejects malformed lists" {
    const listed = [_]TextureFormat{ format_r8_unorm, format_bgra8_unorm };
    const unlisted = [_]TextureFormat{format_r8_unorm};
    var capabilities = std.mem.zeroes(SurfaceCapabilities);

    try std.testing.expectEqual(@as(?TextureFormat, null), find_bgra8(capabilities));

    capabilities.formats = &listed;
    capabilities.format_count = listed.len;
    try std.testing.expectEqual(@as(?TextureFormat, format_bgra8_unorm), find_bgra8(capabilities));

    capabilities.formats = &unlisted;
    capabilities.format_count = unlisted.len;
    try std.testing.expectEqual(@as(?TextureFormat, null), find_bgra8(capabilities));

    capabilities.formats = &listed;
    capabilities.format_count = 0;
    try std.testing.expectEqual(@as(?TextureFormat, null), find_bgra8(capabilities));

    capabilities.format_count = format_cap + 1;
    try std.testing.expectEqual(@as(?TextureFormat, null), find_bgra8(capabilities));
}

//! Native Linux WebGPU backend over the wgpu-native C ABI (pinned to v29.0.1.1).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Hand-Written C ABI Binding
//! The backend links `libwgpu_native.so` through `webgpu.h` types declared here with
//! `extern struct` and `callconv(.c)`, so the build needs no wrapper library, code generator,
//! or package manager. Every declaration is pinned to the wgpu-native version above; a version
//! bump must re-check each struct against the new header (the `comptime` blocks after the
//! struct declarations enforce the sizes this file depends on).
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
//! ## 3. A Replayer, Not a Renderer
//! `create` makes the instance, surface, adapter, device, and queue, and nothing else. Every
//! resource and every frame arrives as a `commands.CommandBuffer` that `execute` replays op by
//! op (`gpu/commands.zig` defines the encoding, `draw/renderer.zig` what is recorded). Ids map
//! to handles through fixed tables in `Gpu`, one per `commands.Kind`, sized by
//! `commands.caps`. Creating an id twice or using an id that was never created panics with
//! the op name. A layout's entries are kept beside its handle, because a bind group entry's
//! resource id names a buffer, a texture, or a sampler according to the layout entry at the
//! same binding. A texture's default view is created with it and is what bind groups bind.
//! Pipelines target `Gpu.format` and use the conventions listed in `gpu/commands.zig`.
//!
//! ## 4. Frame Lifecycle
//! ```text
//! pass_begin        -> open the frame's encoder if needed; for the surface, reconfigure it
//!                      if the size changed and acquire its texture; begin a render pass on
//!                      the surface or a render target, clearing or loading it
//! pipeline_set .. draw, scissor_set -> recorded into that pass; they panic with no pass open
//! pass_end_present  -> end, finish, submit, present, release every per-frame handle
//! pass_end          -> end the pass, keep the encoder
//! present_copy      -> acquire the surface texture, copy a render target onto it, finish,
//!                      submit, present, release (`draw/renderer.zig`, section 6)
//! ```
//! `target_create` makes a render target in the surface format and is the one create that may
//! repeat an id: a new size replaces the texture.
//! Buffer and texture writes go straight to the queue, so a write recorded before
//! `pass_begin` is visible to the pass. If `execute` returns early, a deferred release frees
//! whatever per-frame handles exist.
//!
//! ## 5. Errors
//! `request_device` installs `uncaptured_error`, which wgpu-native calls synchronously from
//! inside the failing call. It keeps the first message in `error_slot`; `execute` checks the
//! slot after every op and fails the frame with `error.GpuValidation`, logging the op index,
//! the op name, the shader label for a `shader_create` (the draw type's name), and the
//! message. The label is also the shader module's own label, so wgpu names the draw type in
//! pipeline errors too. Without the callback wgpu-native would abort the process.
//!
//! ## 6. Texture Upload Rules
//! - Texture and buffer usage flags use different bit assignments: `COPY_DST` is
//!   `texture_usage_copy_dst` for textures but `usage_copy_dst` for buffers, and the buffer
//!   value is `STORAGE_BINDING` on a texture, which `r8unorm` forbids and which makes
//!   `wgpuDeviceCreateTexture` panic. `texture_create` asserts the two differ.
//! - WebGPU requires `bytesPerRow` to be a multiple of 256 for buffer-to-texture copies
//!   (`GPUCommandEncoder.copyBufferToTexture`). `wgpuQueueWriteTexture` does not enforce it;
//!   the renderer keeps the atlas rows aligned anyway.
//! - Texture writes use `TexelCopyTextureInfo` and `TexelCopyBufferLayout`, which must match
//!   `wgpuQueueWriteTexture` field for field.
//!
//! ## 7. wgpu-native v29.0.1.1 Workarounds
//! Delete each when the pin moves to a release that fixes it.
//! - `wgpuInstanceWaitAny` is declared in the header but panics inside Rust. `wait_future`
//!   instead pumps `wgpuInstanceProcessEvents` in a loop bounded by `wait_max`.
//! - `wgpuShaderModuleGetCompilationInfo` panics, so shader and pipeline creation is checked
//!   by a non-null handle and by the uncaptured-error callback (section 5).
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
//! ## 9. Profiling (Bench Mode)
//! With `Options.profile` (the native host's `--bench`, see `bench.zig`) the backend:
//! - requests `TimestampQuery` when the adapter has it, attaches `timestampWrites` to each of
//!   the frame's first `pass_cap` passes (pass `i` writes `2i` and `2i + 1`; the offscreen
//!   targets' passes come before the main one), resolves them after the frame, copies them to
//!   a map-read buffer, and blocks on `wgpuDevicePoll` after present to read `pass_ns` (every
//!   pass and the copy) and `passes_ns` (each pass). Blocking removes CPU and
//!   GPU overlap, so profiled frames time the pass, not the pipeline;
//! - adds `copy_src` to the surface usage, so `request_frame_image` can copy the next frame's
//!   swapchain texture into a 256-byte-aligned buffer, mapped until `release_frame_image`;
//! - keeps the adapter's device name for the report.
//! Without it no feature is requested, the surface usage is unchanged, and none of this runs.
//! `Options.adapter` maps to `power_preference` in either mode.
//!
//! ## 10. TigerStyle Invariants
//! Long-lived resources are created only by setup ops, into fixed tables; frame ops create
//! and release only per-frame handles. Searches over driver-reported lists are bounded by
//! `present_mode_cap` and `format_cap`, waiting is bounded by `wait_max`, and an error
//! message is truncated to `error_message_cap` bytes.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");
const bench = @import("../bench.zig");

/// Every native WebGPU handle the backend owns. The device objects are created by `create`
/// and the resource tables are filled by setup ops; nothing is freed, since the process
/// lifetime equals the window lifetime.
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
    shaders: [cap(.shader)]?ShaderModule,
    layouts: [cap(.layout)]?BindGroupLayout,
    /// The entries each layout was created with, read by `bind_group_create`.
    layout_entries: [cap(.layout)]commands.LayoutCreate,
    pipelines: [cap(.pipeline)]?RenderPipeline,
    buffers: [cap(.buffer)]?Buffer,
    textures: [cap(.texture)]?Texture,
    /// Default view of the texture with the same id.
    views: [cap(.texture)]?TextureView,
    samplers: [cap(.sampler)]?Sampler,
    bind_groups: [cap(.bind_group)]?BindGroup,
    /// Width and height of each render target (`target_create`); zero for other textures.
    target_sizes: [cap(.texture)][2]u32,
    /// Bench-mode state (module guide section 9); `enabled` is false otherwise.
    profile: Profile,
};

/// How `create` picks the adapter and whether it profiles (module guide section 9).
pub const Options = struct {
    adapter: bench.Adapter,
    profile: bool,
};

fn cap(comptime kind: commands.Kind) usize {
    return commands.caps.get(kind);
}

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
const load_load: LoadOp = 0x00000001;
const store_store: StoreOp = 0x00000001;
const status_success: Status = 0x00000001;
const adapter_success: RequestAdapterStatus = 0x00000001;
const device_success: RequestDeviceStatus = 0x00000001;
const texture_success_optimal: SurfaceGetCurrentTextureStatus = 0x00000001;
const texture_success_suboptimal: SurfaceGetCurrentTextureStatus = 0x00000002;
const depth_slice_undefined: u32 = 0xFFFFFFFF;
const wait_max: u32 = 8000;
const format_cap: u32 = 32;
const vertex_float32: VertexFormat = 0x0000001C;
const vertex_float32x2: VertexFormat = 0x0000001D;
const vertex_float32x3: VertexFormat = 0x0000001E;
const vertex_float32x4: VertexFormat = 0x0000001F;
const step_vertex: VertexStepMode = 0x00000001;
const step_instance: VertexStepMode = 0x00000002;
const topology_triangle_list: PrimitiveTopology = 0x00000004;
const index_undefined: IndexFormat = 0x00000000;
const front_ccw: FrontFace = 0x00000001;
const cull_none: CullMode = 0x00000001;
const blend_add: BlendOperation = 0x00000001;
const blend_zero: BlendFactor = 0x00000001;
const blend_one: BlendFactor = 0x00000002;
const blend_src_alpha: BlendFactor = 0x00000005;
const blend_one_minus_src_alpha: BlendFactor = 0x00000006;
const blend_dst: BlendFactor = 0x00000007;
const buffer_uniform: BufferBindingType = 0x00000002;
const buffer_read_only_storage: BufferBindingType = 0x00000004;
const error_type_no_error: u32 = 0x00000001;
const shader_vertex: Flags = 0x0000000000000001;
const shader_fragment: Flags = 0x0000000000000002;
const format_r8_unorm: TextureFormat = 0x00000001;
const format_rgba8_unorm: TextureFormat = 0x00000016;
const format_r16_float: TextureFormat = 0x00000009;
const format_rg16_float: TextureFormat = 0x00000015;
const format_r32_float: TextureFormat = 0x0000000E;
const format_rg32_float: TextureFormat = 0x00000021;
/// Texture `COPY_DST` is 0x2. Buffer `usage_copy_dst` is 0x8, which is texture `STORAGE_BINDING`.
const texture_usage_copy_dst: TextureUsage = 0x0000000000000002;
const texture_usage_copy_src: TextureUsage = 0x0000000000000001;
const usage_texture_binding: TextureUsage = 0x0000000000000004;
const dimension_2d: u32 = 0x00000002;
const sample_float: u32 = 0x00000002;
const sample_unfilterable_float: u32 = 0x00000003;
const view_2d: u32 = 0x00000002;
const address_clamp_to_edge: u32 = 0x00000001;
const address_repeat: u32 = 0x00000002;
const filter_nearest: u32 = 0x00000001;
const filter_linear: u32 = 0x00000002;
const mip_nearest: u32 = 0x00000001;
const sampler_filtering: u32 = 0x00000002;
const sampler_non_filtering: u32 = 0x00000003;
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

const QueueDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
};

const DeviceLostCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    mode: CallbackMode,
    callback: ?*const anyopaque,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

const UncapturedErrorCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    callback: ?*const fn (
        device: ?*const anyopaque,
        type: u32,
        message: StringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

const DeviceDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    required_feature_count: usize,
    required_features: ?*const anyopaque,
    required_limits: ?*const anyopaque,
    default_queue: QueueDescriptor,
    device_lost_callback_info: DeviceLostCallbackInfo,
    uncaptured_error_callback_info: UncapturedErrorCallbackInfo,
};

comptime {
    assert(@sizeOf(QueueDescriptor) == 24);
    assert(@sizeOf(DeviceLostCallbackInfo) == 40);
    assert(@sizeOf(UncapturedErrorCallbackInfo) == 32);
    assert(@sizeOf(DeviceDescriptor) == 144);
}

const AdapterSlot = struct {
    adapter: ?Adapter,
    ok: bool,
};

const DeviceSlot = struct {
    device: ?Device,
    ok: bool,
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
extern fn wgpuBindGroupRelease(group: BindGroup) void;
extern fn wgpuTextureRelease(texture: Texture) void;
extern fn wgpuCommandEncoderRelease(encoder: CommandEncoder) void;
extern fn wgpuCommandBufferRelease(buffer: CommandBuffer) void;
extern fn wgpuRenderPassEncoderRelease(pass: RenderPassEncoder) void;
extern fn wgpuPipelineLayoutRelease(layout: PipelineLayout) void;

comptime {
    assert(@sizeOf(Color) == 32);
    assert(@sizeOf(ChainedStruct) == 16);
    assert(@sizeOf(Future) == 8);
    assert(@sizeOf(SurfaceSourceWayland) == 32);
    assert(@sizeOf(ShaderSourceWgsl) == 32);
    // chain (16) plus the latency u32, rounded up to the pointer alignment.
    assert(@sizeOf(SurfaceConfigurationExtras) == 24);
    // Usage and stage bits pass through from the stream unchanged (module guide section 3).
    assert(usage_copy_dst == commands.usage_copy_dst);
    assert(usage_vertex == commands.usage_vertex);
    assert(usage_uniform == commands.usage_uniform);
    assert(shader_vertex == commands.stage_vertex);
    assert(shader_fragment == commands.stage_fragment);
}

const empty_label: StringView = .{ .data = null, .length = 0 };

/// The blend states of `commands.Blend`, whose doc comment gives the factors.
const alpha_blend: BlendState = .{
    .color = .{
        .operation = blend_add,
        .src_factor = blend_src_alpha,
        .dst_factor = blend_one_minus_src_alpha,
    },
    .alpha = .{
        .operation = blend_add,
        .src_factor = blend_one,
        .dst_factor = blend_one_minus_src_alpha,
    },
};

const premultiplied_blend: BlendState = .{
    .color = .{ .operation = blend_add, .src_factor = blend_one, .dst_factor = blend_one_minus_src_alpha },
    .alpha = .{ .operation = blend_add, .src_factor = blend_one, .dst_factor = blend_one_minus_src_alpha },
};

/// Keeps the target's alpha: the additive and multiply modes change color only.
const keep_alpha: BlendComponent = .{
    .operation = blend_add,
    .src_factor = blend_zero,
    .dst_factor = blend_one,
};

const additive_blend: BlendState = .{
    .color = .{ .operation = blend_add, .src_factor = blend_src_alpha, .dst_factor = blend_one },
    .alpha = keep_alpha,
};

const multiply_blend: BlendState = .{
    .color = .{ .operation = blend_add, .src_factor = blend_dst, .dst_factor = blend_zero },
    .alpha = keep_alpha,
};

/// Longest error message kept by `uncaptured_error`; longer messages are truncated.
const error_message_cap: u32 = 1024;

/// The first uncaptured device error since `execute` last reported one (module guide
/// section 5). Static because wgpu-native needs a stable userdata address before `Gpu` exists.
const ErrorSlot = struct {
    failed: bool,
    len: u32,
    message: [error_message_cap]u8,
};

var error_slot: ErrorSlot = .{ .failed = false, .len = 0, .message = undefined };

/// Creates the instance, Wayland-backed surface, adapter, device, and queue, with empty
/// resource tables. `display` and `wl_surface` must be live Wayland handles that outlive the
/// returned `Gpu`. The swapchain is left unconfigured until the first `pass_begin`.
/// Errors: any failed handle request, `error.WaitTimeout`, or `error.Bgra8Unsupported`.
pub fn create(display: *anyopaque, wl_surface: *anyopaque, options: Options) !Gpu {
    assert(@intFromPtr(display) != 0);
    assert(@intFromPtr(wl_surface) != 0);
    const instance = try create_instance();
    const surface = try create_surface(instance, display, wl_surface);
    const adapter = try request_adapter(instance, surface, options.adapter);
    const timestamps = options.profile and
        wgpuAdapterHasFeature(adapter, feature_timestamp_query) != 0;
    const inside_encoders = timestamps and
        wgpuAdapterHasFeature(adapter, feature_timestamps_inside_encoders) != 0;
    const device = try request_device(instance, adapter, timestamps, inside_encoders);
    const queue = wgpuDeviceGetQueue(device);
    const chosen = try pick_format(surface, adapter);
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
        .shaders = @splat(null),
        .layouts = @splat(null),
        .layout_entries = undefined,
        .pipelines = @splat(null),
        .buffers = @splat(null),
        .textures = @splat(null),
        .views = @splat(null),
        .samplers = @splat(null),
        .bind_groups = @splat(null),
        .target_sizes = @splat(.{ 0, 0 }),
        .profile = profile_create(adapter, device, queue, .{
            .enabled = options.profile,
            .timestamps = timestamps,
            .inside_encoders = inside_encoders,
        }),
    };
}

/// Per-frame handles between the first op that opens the encoder and the present. All null
/// outside a frame. `texture` and `view` are the surface's; a pass on a render target uses
/// the target's own view. `timed_passes` and `timed_copy` say which timestamps bench mode wrote.
const Frame = struct {
    texture: ?Texture,
    view: ?TextureView,
    encoder: ?CommandEncoder,
    pass: ?RenderPassEncoder,
    timed_passes: u32,
    timed_copy: bool,

    const empty: Frame = .{
        .texture = null,
        .view = null,
        .encoder = null,
        .pass = null,
        .timed_passes = 0,
        .timed_copy = false,
    };

    /// Releases whatever exists, innermost first. Only reached with handles on an error path.
    fn release(self: *Frame) void {
        if (self.pass) |pass| wgpuRenderPassEncoderRelease(pass);
        if (self.encoder) |encoder| wgpuCommandEncoderRelease(encoder);
        if (self.view) |view| wgpuTextureViewRelease(view);
        if (self.texture) |texture| wgpuTextureRelease(texture);
        self.* = empty;
    }
};

/// Replays `buffer` op by op (module guide sections 3 and 4). Returns the error from
/// `acquire_texture` when no swapchain texture is available, or `error.GpuValidation` after
/// logging the failing op when the device reported an error.
pub fn execute(self: *Gpu, buffer: *const commands.CommandBuffer) !void {
    assert(buffer.len != 0);
    assert(!error_slot.failed);
    var frame: Frame = .empty;
    defer frame.release();
    var reader = buffer.reader();
    while (reader.next()) |op| {
        try run(self, op, &frame);
        if (error_slot.failed) {
            const label = op_label(op);
            std.log.err("gpu op {d} ({s}{s}{s}) failed: {s}", .{
                reader.index - 1,
                @tagName(op),
                if (label.len == 0) "" else " ",
                label,
                error_slot.message[0..error_slot.len],
            });
            error_slot.failed = false;
            return error.GpuValidation;
        }
    }
    assert(frame.pass == null);
    assert(reader.index == buffer.count);
}

/// The shader label for a `shader_create` op; empty for any other op.
/// A WGSL error then names the draw type whose module failed.
fn op_label(op: commands.Op) []const u8 {
    switch (op) {
        .shader_create => |p| {
            const label = p.label.slice();
            assert(label.len != 0);
            // The label is static text, so returning a slice of it outlives this call.
            return label;
        },
        else => return "",
    }
}

fn run(self: *Gpu, op: commands.Op, frame: *Frame) !void {
    switch (op) {
        .shader_create => |p| shader_create(self, p),
        .layout_create => |p| layout_create(self, p),
        .pipeline_create => |p| pipeline_create(self, p),
        .buffer_create => |p| try buffer_create(self, p),
        .texture_create => |p| try texture_create(self, p),
        .sampler_create => |p| sampler_create(self, p),
        .bind_group_create => |p| bind_group_create(self, p),
        .buffer_write => |p| {
            const data = p.data.slice();
            const target = get(Buffer, "buffer_write", &self.buffers, p.id);
            wgpuQueueWriteBuffer(self.queue, target, p.offset, data.ptr, data.len);
        },
        .texture_write => |p| texture_write(self, p),
        .pass_begin => |p| try pass_begin(self, p, frame),
        .pipeline_set => |p| {
            const pipeline = get(RenderPipeline, "pipeline_set", &self.pipelines, p.id);
            wgpuRenderPassEncoderSetPipeline(open_pass("pipeline_set", frame), pipeline);
        },
        .bind_group_set => |p| {
            const group = get(BindGroup, "bind_group_set", &self.bind_groups, p.id);
            const pass = open_pass("bind_group_set", frame);
            wgpuRenderPassEncoderSetBindGroup(pass, p.slot, group, 0, null);
        },
        .vertex_buffer_set => |p| {
            const vertices = get(Buffer, "vertex_buffer_set", &self.buffers, p.buffer);
            const pass = open_pass("vertex_buffer_set", frame);
            wgpuRenderPassEncoderSetVertexBuffer(pass, p.slot, vertices, p.offset, whole_size);
        },
        .draw => |p| wgpuRenderPassEncoderDraw(
            open_pass("draw", frame),
            p.vertex_count,
            p.instance_count,
            p.first_vertex,
            p.first_instance,
        ),
        .pass_end_present => pass_end_present(self, frame),
        .target_create => |p| try target_create(self, p),
        .scissor_set => |p| wgpuRenderPassEncoderSetScissorRect(
            open_pass("scissor_set", frame),
            p.x,
            p.y,
            p.width,
            p.height,
        ),
        .pass_end => {
            const pass = open_pass("pass_end", frame);
            wgpuRenderPassEncoderEnd(pass);
            wgpuRenderPassEncoderRelease(pass);
            frame.pass = null;
        },
        .present_copy => |p| try present_copy(self, p, frame),
    }
}

/// The handle for `id` in `table`. Panics, naming `op`, when the id is out of range or was
/// never created.
fn get(comptime T: type, comptime op: []const u8, table: []const ?T, id: u16) T {
    if (id >= table.len) {
        std.debug.panic("{s}: id {d} is out of range {d}", .{ op, id, table.len });
    }
    return table[id] orelse std.debug.panic("{s}: id {d} was never created", .{ op, id });
}

/// Asserts `id` names an empty slot of `table`. Panics, naming `op`, otherwise.
fn claim(comptime T: type, comptime op: []const u8, table: []const ?T, id: u16) void {
    if (id >= table.len) {
        std.debug.panic("{s}: id {d} is out of range {d}", .{ op, id, table.len });
    }
    if (table[id] != null) {
        std.debug.panic("{s}: id {d} was already created", .{ op, id });
    }
}

fn string_view(text: []const u8) StringView {
    assert(text.len != 0);
    return .{ .data = text.ptr, .length = text.len };
}

fn open_pass(comptime op: []const u8, frame: *const Frame) RenderPassEncoder {
    return frame.pass orelse std.debug.panic("{s}: no render pass is open", .{op});
}

fn shader_create(self: *Gpu, p: commands.ShaderCreate) void {
    claim(ShaderModule, "shader_create", &self.shaders, p.id);
    const source_text = p.source.slice();
    var source: ShaderSourceWgsl = .{
        .chain = .{ .next = null, .s_type = s_type_shader_source_wgsl },
        .code = .{ .data = source_text.ptr, .length = source_text.len },
    };
    const descriptor: ShaderModuleDescriptor = .{
        .next_in_chain = @ptrCast(&source.chain),
        .label = string_view(p.label.slice()),
    };
    const shader = wgpuDeviceCreateShaderModule(self.device, &descriptor);
    assert(@intFromPtr(shader) != 0);
    self.shaders[p.id] = shader;
}

fn layout_create(self: *Gpu, p: commands.LayoutCreate) void {
    claim(BindGroupLayout, "layout_create", &self.layouts, p.id);
    assert(p.entry_count <= commands.layout_entry_cap);
    var entries: [commands.layout_entry_cap]BindGroupLayoutEntry = undefined;
    for (p.entries[0..p.entry_count], entries[0..p.entry_count]) |entry, *out| {
        out.* = .{
            .next_in_chain = null,
            .binding = entry.binding,
            .visibility = entry.visibility,
            .binding_array_size = 0,
            .buffer = std.mem.zeroes(BufferBindingLayout),
            .sampler = std.mem.zeroes(SamplerBindingLayout),
            .texture = std.mem.zeroes(TextureBindingLayout),
            .storage_texture = std.mem.zeroes(StorageTextureBindingLayout),
        };
        switch (entry.kind) {
            .uniform => out.buffer.type = buffer_uniform,
            .storage_read => out.buffer.type = buffer_read_only_storage,
            .texture => {
                out.texture.sample_type = sample_float;
                out.texture.view_dimension = view_2d;
            },
            .texture_unfilterable => {
                out.texture.sample_type = sample_unfilterable_float;
                out.texture.view_dimension = view_2d;
            },
            .sampler => out.sampler.type = sampler_filtering,
            .sampler_non_filtering => out.sampler.type = sampler_non_filtering,
        }
    }
    const descriptor: BindGroupLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .entry_count = p.entry_count,
        .entries = &entries,
    };
    const layout = wgpuDeviceCreateBindGroupLayout(self.device, &descriptor);
    assert(@intFromPtr(layout) != 0);
    self.layouts[p.id] = layout;
    self.layout_entries[p.id] = p;
}

fn pipeline_create(self: *Gpu, p: commands.PipelineCreate) void {
    claim(RenderPipeline, "pipeline_create", &self.pipelines, p.id);
    assert(p.layout_count <= commands.pipeline_layout_cap);
    assert(p.buffer_count <= commands.vertex_buffer_cap);
    const shader = get(ShaderModule, "pipeline_create", &self.shaders, p.shader);
    var groups: [commands.pipeline_layout_cap]BindGroupLayout = undefined;
    for (p.layouts[0..p.layout_count], groups[0..p.layout_count]) |id, *out| {
        out.* = get(BindGroupLayout, "pipeline_create", &self.layouts, id);
    }
    const layout_descriptor: PipelineLayoutDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .bind_group_layout_count = p.layout_count,
        .bind_group_layouts = &groups,
        .immediate_size = 0,
    };
    const layout = wgpuDeviceCreatePipelineLayout(self.device, &layout_descriptor);
    assert(@intFromPtr(layout) != 0);
    var attributes: [commands.vertex_buffer_cap][commands.attribute_cap]VertexAttribute = undefined;
    var buffers: [commands.vertex_buffer_cap]VertexBufferLayout = undefined;
    for (p.vertex[0..p.buffer_count], buffers[0..p.buffer_count], 0..) |source, *out, i| {
        assert(source.attribute_count <= commands.attribute_cap);
        const used = source.attributes[0..source.attribute_count];
        for (used, attributes[i][0..used.len]) |attribute, *slot| {
            slot.* = .{
                .next_in_chain = null,
                .format = switch (attribute.format) {
                    .float32 => vertex_float32,
                    .float32x2 => vertex_float32x2,
                    .float32x3 => vertex_float32x3,
                    .float32x4 => vertex_float32x4,
                },
                .offset = attribute.offset,
                .shader_location = attribute.location,
            };
        }
        out.* = .{
            .next_in_chain = null,
            .step_mode = switch (source.step) {
                .vertex => step_vertex,
                .instance => step_instance,
            },
            .array_stride = source.stride,
            .attribute_count = source.attribute_count,
            .attributes = &attributes[i],
        };
    }
    const target: ColorTargetState = .{
        .next_in_chain = null,
        .format = self.format,
        .blend = switch (p.blend) {
            .none => null,
            .alpha => &alpha_blend,
            .additive => &additive_blend,
            .multiply => &multiply_blend,
            .premultiplied => &premultiplied_blend,
        },
        .write_mask = color_write_all,
    };
    const fragment: FragmentState = .{
        .next_in_chain = null,
        .module = shader,
        .entry_point = string_view(commands.fragment_entry),
        .constant_count = 0,
        .constants = null,
        .target_count = 1,
        .targets = @ptrCast(&target),
    };
    const descriptor: RenderPipelineDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .layout = layout,
        .vertex = .{
            .next_in_chain = null,
            .module = shader,
            .entry_point = string_view(commands.vertex_entry),
            .constant_count = 0,
            .constants = null,
            .buffer_count = p.buffer_count,
            .buffers = &buffers,
        },
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
    const pipeline = wgpuDeviceCreateRenderPipeline(self.device, &descriptor);
    // `GetCompilationInfo` is unusable on this pin (module guide section 7), so a non-null
    // pipeline and the error callback are the only compile checks.
    assert(@intFromPtr(pipeline) != 0);
    wgpuPipelineLayoutRelease(layout);
    self.pipelines[p.id] = pipeline;
}

fn buffer_create(self: *Gpu, p: commands.BufferCreate) !void {
    claim(Buffer, "buffer_create", &self.buffers, p.id);
    assert(p.size != 0);
    assert(p.usage != 0);
    const descriptor: BufferDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .usage = p.usage,
        .size = p.size,
        .mapped_at_creation = 0,
    };
    const buffer = wgpuDeviceCreateBuffer(self.device, &descriptor) orelse {
        return error.BufferFailed;
    };
    self.buffers[p.id] = buffer;
}

fn texture_create(self: *Gpu, p: commands.TextureCreate) !void {
    claim(Texture, "texture_create", &self.textures, p.id);
    assert(p.width != 0);
    assert(p.height != 0);
    // Module guide section 6: the buffer COPY_DST bit is STORAGE_BINDING on a texture.
    assert(texture_usage_copy_dst != usage_copy_dst);
    const descriptor: TextureDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .usage = texture_usage_copy_dst | usage_texture_binding,
        .dimension = dimension_2d,
        .size = .{ .width = p.width, .height = p.height, .depth_or_array_layers = 1 },
        .format = switch (p.format) {
            .r8unorm => format_r8_unorm,
            .rgba8unorm => format_rgba8_unorm,
            .r16float => format_r16_float,
            .rg16float => format_rg16_float,
            .r32float => format_r32_float,
            .rg32float => format_rg32_float,
        },
        .mip_level_count = 1,
        .sample_count = 1,
        .view_format_count = 0,
        .view_formats = null,
    };
    const texture = wgpuDeviceCreateTexture(self.device, &descriptor) orelse {
        return error.TextureFailed;
    };
    const view = wgpuTextureCreateView(texture, null);
    assert(@intFromPtr(view) != 0);
    self.textures[p.id] = texture;
    self.views[p.id] = view;
}

fn sampler_create(self: *Gpu, p: commands.SamplerCreate) void {
    claim(Sampler, "sampler_create", &self.samplers, p.id);
    const filter: u32 = switch (p.filter) {
        .nearest => filter_nearest,
        .linear => filter_linear,
    };
    const descriptor: SamplerDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .address_mode_u = address_of(p.address_u),
        .address_mode_v = address_of(p.address_v),
        .address_mode_w = address_clamp_to_edge,
        .mag_filter = filter,
        .min_filter = filter,
        .mipmap_filter = mip_nearest,
        .lod_min_clamp = 0,
        .lod_max_clamp = 32,
        .compare = 0,
        .max_anisotropy = 1,
    };
    const sampler = wgpuDeviceCreateSampler(self.device, &descriptor);
    assert(@intFromPtr(sampler) != 0);
    self.samplers[p.id] = sampler;
}

fn address_of(address: commands.Address) u32 {
    return switch (address) {
        .clamp => address_clamp_to_edge,
        .repeat => address_repeat,
    };
}

fn bind_group_create(self: *Gpu, p: commands.BindGroupCreate) void {
    assert(p.replace <= 1);
    if (p.replace == 1) {
        const old = get(BindGroup, "bind_group_create", &self.bind_groups, p.id);
        wgpuBindGroupRelease(old);
        self.bind_groups[p.id] = null;
    }
    claim(BindGroup, "bind_group_create", &self.bind_groups, p.id);
    assert(p.entry_count <= commands.bind_group_entry_cap);
    const layout = get(BindGroupLayout, "bind_group_create", &self.layouts, p.layout);
    const layout_entries = &self.layout_entries[p.layout];
    var entries: [commands.bind_group_entry_cap]BindGroupEntry = undefined;
    for (p.entries[0..p.entry_count], entries[0..p.entry_count]) |entry, *out| {
        out.* = .{
            .next_in_chain = null,
            .binding = entry.binding,
            .buffer = null,
            .offset = 0,
            .size = whole_size,
            .sampler = null,
            .texture_view = null,
        };
        switch (binding_kind(layout_entries, entry.binding)) {
            .uniform, .storage_read => {
                out.buffer = get(Buffer, "bind_group_create", &self.buffers, entry.resource);
            },
            .texture, .texture_unfilterable => {
                const views = &self.views;
                out.texture_view = get(TextureView, "bind_group_create", views, entry.resource);
            },
            .sampler, .sampler_non_filtering => {
                out.sampler = get(Sampler, "bind_group_create", &self.samplers, entry.resource);
            },
        }
    }
    const descriptor: BindGroupDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .layout = layout,
        .entry_count = p.entry_count,
        .entries = &entries,
    };
    const group = wgpuDeviceCreateBindGroup(self.device, &descriptor);
    assert(@intFromPtr(group) != 0);
    self.bind_groups[p.id] = group;
}

/// The kind of the layout entry at `binding`. Panics when the layout has no such binding.
fn binding_kind(layout: *const commands.LayoutCreate, binding: u16) commands.BindingKind {
    for (layout.entries[0..layout.entry_count]) |entry| {
        if (entry.binding == binding) return entry.kind;
    }
    std.debug.panic("bind_group_create: layout {d} has no binding {d}", .{ layout.id, binding });
}

fn texture_write(self: *Gpu, p: commands.TextureWrite) void {
    const texture = get(Texture, "texture_write", &self.textures, p.id);
    const data = p.data.slice();
    assert(data.len >= p.bytes_per_row * (p.height - 1) + p.width);
    const destination: TexelCopyTextureInfo = .{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = p.x, .y = p.y, .z = 0 },
        .aspect = 0,
    };
    const layout: TexelCopyBufferLayout = .{
        .offset = 0,
        .bytes_per_row = p.bytes_per_row,
        .rows_per_image = p.height,
    };
    const size: Extent3D = .{ .width = p.width, .height = p.height, .depth_or_array_layers = 1 };
    wgpuQueueWriteTexture(self.queue, &destination, data.ptr, data.len, &layout, &size);
}

/// Reconfigures the surface if needed, acquires its texture, and opens a clearing pass.
fn pass_begin(self: *Gpu, p: commands.PassBegin, frame: *Frame) !void {
    if (frame.pass != null) {
        std.debug.panic("pass_begin: a render pass is already open", .{});
    }
    assert(p.width_px != 0);
    assert(p.height_px != 0);
    const view = if (p.target == commands.surface_target) blk: {
        assert(p.load == .clear);
        try acquire_surface(self, p.width_px, p.height_px, frame);
        break :blk frame.view.?;
    } else blk: {
        const size = self.target_sizes[p.target];
        if (size[0] != p.width_px or size[1] != p.height_px) {
            std.debug.panic("pass_begin: target {d} is {d}x{d}, the pass {d}x{d}", .{
                p.target, size[0], size[1], p.width_px, p.height_px,
            });
        }
        break :blk get(TextureView, "pass_begin", &self.views, p.target);
    };
    const encoder = open_encoder(self, frame);
    const attachment: RenderPassColorAttachment = .{
        .next_in_chain = null,
        .view = view,
        .depth_slice = depth_slice_undefined,
        .resolve_target = null,
        .load_op = if (p.load == .clear) load_clear else load_load,
        .store_op = store_store,
        .clear_value = .{ .r = p.clear[0], .g = p.clear[1], .b = p.clear[2], .a = p.clear[3] },
    };
    var writes: PassTimestampWrites = undefined;
    const timed = self.profile.query != null and frame.timed_passes < pass_cap;
    if (timed) {
        writes = .{
            .next_in_chain = null,
            .query_set = self.profile.query.?,
            .begin_index = 2 * frame.timed_passes,
            .end_index = 2 * frame.timed_passes + 1,
        };
        frame.timed_passes += 1;
    }
    const descriptor: RenderPassDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .color_attachment_count = 1,
        .color_attachments = @ptrCast(&attachment),
        .depth_stencil_attachment = null,
        .occlusion_query_set = null,
        .timestamp_writes = if (timed) @ptrCast(&writes) else null,
    };
    frame.pass = wgpuCommandEncoderBeginRenderPass(encoder, &descriptor);
}

/// The frame's encoder, created by the first op that needs it.
fn open_encoder(self: *Gpu, frame: *Frame) CommandEncoder {
    if (frame.encoder) |encoder| return encoder;
    const encoder = wgpuDeviceCreateCommandEncoder(self.device, null);
    assert(@intFromPtr(encoder) != 0);
    frame.encoder = encoder;
    return encoder;
}

/// Reconfigures the surface if its size changed and acquires its texture and view.
fn acquire_surface(self: *Gpu, width_px: u32, height_px: u32, frame: *Frame) !void {
    assert(frame.texture == null);
    configure_surface(self, width_px, height_px);
    const texture = try acquire_texture(self.surface);
    frame.texture = texture;
    const view = wgpuTextureCreateView(texture, null);
    assert(@intFromPtr(view) != 0);
    frame.view = view;
}

/// Ends the pass, submits, presents, and releases every per-frame handle.
fn pass_end_present(self: *Gpu, frame: *Frame) void {
    const pass = open_pass("pass_end_present", frame);
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
    frame.pass = null;
    submit_present(self, frame);
}

/// Copies render target `p.target` onto the surface texture, then submits and presents.
fn present_copy(self: *Gpu, p: commands.PresentCopy, frame: *Frame) !void {
    if (frame.pass != null) std.debug.panic("present_copy: a render pass is still open", .{});
    const source = get(Texture, "present_copy", &self.textures, p.target);
    const size = self.target_sizes[p.target];
    assert(size[0] != 0);
    assert(size[1] != 0);
    try acquire_surface(self, size[0], size[1], frame);
    const encoder = open_encoder(self, frame);
    const timed = self.profile.inside_encoders;
    if (timed) wgpuCommandEncoderWriteTimestamp(encoder, self.profile.query.?, 2 * pass_cap);
    const from: TexelCopyTextureInfo = .{
        .texture = source,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = 0,
    };
    const to: TexelCopyTextureInfo = .{
        .texture = frame.texture.?,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = 0,
    };
    const extent: Extent3D = .{ .width = size[0], .height = size[1], .depth_or_array_layers = 1 };
    wgpuCommandEncoderCopyTextureToTexture(encoder, &from, &to, &extent);
    if (timed) wgpuCommandEncoderWriteTimestamp(encoder, self.profile.query.?, 2 * pass_cap + 1);
    frame.timed_copy = timed;
    submit_present(self, frame);
}

/// Finishes the frame's encoder, submits it, presents the surface, and releases every
/// per-frame handle.
fn submit_present(self: *Gpu, frame: *Frame) void {
    assert(frame.pass == null);
    const encoder = frame.encoder.?;
    profile_record(self, encoder, frame);
    const commands_buffer = wgpuCommandEncoderFinish(encoder, null);
    wgpuQueueSubmit(self.queue, 1, @ptrCast(&commands_buffer));
    _ = wgpuSurfacePresent(self.surface);
    wgpuCommandBufferRelease(commands_buffer);
    profile_read(self, frame);
    frame.release();
    assert(frame.pass == null);
    assert(frame.texture == null);
}

/// Creates render target `p.id`, or replaces it at a new size (module guide section 4).
fn target_create(self: *Gpu, p: commands.TargetCreate) !void {
    assert(p.width != 0);
    assert(p.height != 0);
    if (p.id >= self.textures.len) std.debug.panic("target_create: id {d} out of range", .{p.id});
    if (self.textures[p.id]) |old| {
        if (self.target_sizes[p.id][0] == 0) {
            std.debug.panic("target_create: id {d} is a sampled texture", .{p.id});
        }
        wgpuTextureViewRelease(self.views[p.id].?);
        wgpuTextureRelease(old);
    }
    const descriptor: TextureDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .usage = usage_render_attachment | texture_usage_copy_src | usage_texture_binding,
        .dimension = dimension_2d,
        .size = .{ .width = p.width, .height = p.height, .depth_or_array_layers = 1 },
        .format = self.format,
        .mip_level_count = 1,
        .sample_count = 1,
        .view_format_count = 0,
        .view_formats = null,
    };
    const texture = wgpuDeviceCreateTexture(self.device, &descriptor) orelse {
        return error.TextureFailed;
    };
    const view = wgpuTextureCreateView(texture, null);
    assert(@intFromPtr(view) != 0);
    self.textures[p.id] = texture;
    self.views[p.id] = view;
    self.target_sizes[p.id] = .{ p.width, p.height };
}

/// C ABI callback installed by `request_device` (module guide section 5). Keeps the first
/// message until `execute` reports it.
fn uncaptured_error(
    device: ?*const anyopaque,
    error_type: u32,
    message: StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    if (error_type == error_type_no_error) return;
    if (error_slot.failed) return;
    var len: u32 = 0;
    if (message.data) |data| {
        // `WGPU_STRLEN` (all ones) marks a null-terminated message.
        const full = if (message.length == std.math.maxInt(usize))
            std.mem.len(@as([*:0]const u8, @ptrCast(data)))
        else
            message.length;
        len = @intCast(@min(full, error_message_cap));
        @memcpy(error_slot.message[0..len], data[0..len]);
    }
    error_slot.len = len;
    error_slot.failed = true;
    assert(error_slot.len <= error_message_cap);
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
fn request_adapter(instance: Instance, surface: Surface, preference: bench.Adapter) !Adapter {
    assert(@intFromPtr(instance) != 0);
    assert(@intFromPtr(surface) != 0);
    var slot: AdapterSlot = .{ .adapter = null, .ok = false };
    const options: RequestAdapterOptions = .{
        .next_in_chain = null,
        .feature_level = 0,
        .power_preference = switch (preference) {
            .default => power_undefined,
            .low => power_low,
            .high => power_high,
        },
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

/// Requests a device from `adapter` with `uncaptured_error` installed (module guide section
/// 5) and blocks (bounded) until it resolves.
fn request_device(
    instance: Instance,
    adapter: Adapter,
    timestamps: bool,
    inside_encoders: bool,
) !Device {
    assert(@intFromPtr(instance) != 0);
    assert(@intFromPtr(adapter) != 0);
    if (inside_encoders) assert(timestamps);
    var slot: DeviceSlot = .{ .device = null, .ok = false };
    const features = [2]u32{ feature_timestamp_query, feature_timestamps_inside_encoders };
    const feature_count: usize = if (inside_encoders) 2 else if (timestamps) 1 else 0;
    const info: RequestDeviceCallbackInfo = .{
        .next_in_chain = null,
        .mode = callback_process_events,
        .callback = device_ready,
        .userdata1 = @ptrCast(&slot),
        .userdata2 = null,
    };
    const descriptor: DeviceDescriptor = .{
        .next_in_chain = null,
        .label = empty_label,
        .required_feature_count = feature_count,
        .required_features = if (feature_count != 0) @ptrCast(&features) else null,
        .required_limits = null,
        .default_queue = .{ .next_in_chain = null, .label = empty_label },
        .device_lost_callback_info = .{
            .next_in_chain = null,
            .mode = callback_process_events,
            .callback = null,
            .userdata1 = null,
            .userdata2 = null,
        },
        .uncaptured_error_callback_info = .{
            .next_in_chain = null,
            .callback = uncaptured_error,
            .userdata1 = null,
            .userdata2 = null,
        },
    };
    const future = wgpuAdapterRequestDevice(adapter, &descriptor, info);
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
/// always `format_bgra8_unorm`, which every pipeline targets.
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
        // `present_copy` copies a render target onto the surface texture; bench mode also
        // copies the surface texture out (module guide section 9).
        .usage = if (self.profile.enabled)
            usage_render_attachment | texture_usage_copy_dst | texture_usage_copy_src
        else
            usage_render_attachment | texture_usage_copy_dst,
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

// ------------------------------------------------------------------ profiling (section 9)

const QuerySet = *opaque {};

const QuerySetDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct,
    label: StringView,
    type: u32,
    count: u32,
};

const PassTimestampWrites = extern struct {
    next_in_chain: ?*ChainedStruct,
    query_set: QuerySet,
    begin_index: u32,
    end_index: u32,
};

const BufferMapCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    mode: CallbackMode,
    callback: ?*const fn (
        status: u32,
        message: StringView,
        userdata1: ?*anyopaque,
        userdata2: ?*anyopaque,
    ) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

const TexelCopyBufferInfo = extern struct {
    layout: TexelCopyBufferLayout,
    buffer: Buffer,
};

const AdapterInfo = extern struct {
    next_in_chain: ?*ChainedStruct,
    vendor: StringView,
    architecture: StringView,
    device: StringView,
    description: StringView,
    backend_type: u32,
    adapter_type: u32,
    vendor_id: u32,
    device_id: u32,
    subgroup_min_size: u32,
    subgroup_max_size: u32,
};

comptime {
    assert(@sizeOf(QuerySetDescriptor) == 32);
    assert(@sizeOf(PassTimestampWrites) == 24);
    assert(@sizeOf(BufferMapCallbackInfo) == 40);
    assert(@sizeOf(TexelCopyBufferInfo) == 24);
    assert(@sizeOf(AdapterInfo) == 96);
}

extern fn wgpuAdapterHasFeature(adapter: Adapter, feature: u32) Bool;
extern fn wgpuAdapterGetInfo(adapter: Adapter, info: *AdapterInfo) Status;
extern fn wgpuAdapterInfoFreeMembers(info: AdapterInfo) void;
extern fn wgpuDeviceCreateQuerySet(device: Device, descriptor: *const QuerySetDescriptor) ?QuerySet;
extern fn wgpuQueueGetTimestampPeriod(queue: Queue) f32;
extern fn wgpuCommandEncoderResolveQuerySet(
    encoder: CommandEncoder,
    query_set: QuerySet,
    first: u32,
    count: u32,
    destination: Buffer,
    offset: u64,
) void;
extern fn wgpuCommandEncoderCopyBufferToBuffer(
    encoder: CommandEncoder,
    source: Buffer,
    source_offset: u64,
    destination: Buffer,
    destination_offset: u64,
    size: u64,
) void;
extern fn wgpuCommandEncoderCopyTextureToBuffer(
    encoder: CommandEncoder,
    source: *const TexelCopyTextureInfo,
    destination: *const TexelCopyBufferInfo,
    size: *const Extent3D,
) void;
extern fn wgpuBufferMapAsync(
    buffer: Buffer,
    mode: Flags,
    offset: usize,
    size: usize,
    info: BufferMapCallbackInfo,
) Future;
extern fn wgpuBufferGetConstMappedRange(
    buffer: Buffer,
    offset: usize,
    size: usize,
) ?*const anyopaque;
extern fn wgpuBufferUnmap(buffer: Buffer) void;
extern fn wgpuBufferRelease(buffer: Buffer) void;
extern fn wgpuDevicePoll(device: Device, wait: Bool, index: ?*const u64) Bool;
extern fn wgpuCommandEncoderWriteTimestamp(
    encoder: CommandEncoder,
    query_set: QuerySet,
    index: u32,
) void;
extern fn wgpuCommandEncoderCopyTextureToTexture(
    encoder: CommandEncoder,
    source: *const TexelCopyTextureInfo,
    destination: *const TexelCopyTextureInfo,
    size: *const Extent3D,
) void;
extern fn wgpuRenderPassEncoderSetScissorRect(
    pass: RenderPassEncoder,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) void;

const feature_timestamp_query: u32 = 0x00000009;
/// wgpu-native's `TimestampQueryInsideEncoders`: timestamps around `present_copy`'s copy.
const feature_timestamps_inside_encoders: u32 = 0x00030024;
const query_type_timestamp: u32 = 0x00000002;
const power_undefined: u32 = 0x00000000;
const power_low: u32 = 0x00000001;
const power_high: u32 = 0x00000002;
const buffer_usage_map_read: Flags = 0x0000000000000001;
const buffer_usage_copy_src: Flags = 0x0000000000000004;
const buffer_usage_query_resolve: Flags = 0x0000000000000200;
const map_mode_read: Flags = 0x0000000000000001;
const map_status_success: u32 = 0x00000001;
/// Passes timed per frame: every offscreen target's and the main one.
pub const pass_cap: u32 = 1 + @import("../draw/textures.zig").target_cap;
/// Two timestamps per pass, then two around the copy.
const timestamp_count: u32 = 2 * pass_cap + 2;
/// The copy's pair is resolved at this offset (a resolve offset is a multiple of 256).
const copy_resolve_offset: u64 = 256;
const timestamp_bytes: u64 = copy_resolve_offset + 2 * 8;
/// `wgpuCommandEncoderCopyTextureToBuffer` needs rows aligned to 256 bytes.
const copy_row_align: u32 = 256;
const adapter_name_cap: u32 = 96;

/// Bench-mode state (module guide section 9). Every handle is null when disabled.
const Profile = struct {
    enabled: bool,
    /// Null without the timestamp feature.
    query: ?QuerySet,
    /// Timestamps around `present_copy`'s copy are available.
    inside_encoders: bool,
    resolve: ?Buffer,
    read: ?Buffer,
    period_ns: f32,
    pass_ns: ?u64,
    /// Each timed pass of the last frame, in recording order.
    passes_ns: [pass_cap]u64,
    pass_count: u32,
    image_requested: bool,
    image: ?Buffer,
    image_width: u32,
    image_height: u32,
    image_row_bytes: u32,
    image_mapped: bool,
    adapter_name: [adapter_name_cap]u8,
    adapter_name_len: u32,
};

/// A mapped copy of one presented frame: BGRA rows `row_bytes` apart.
pub const FrameImage = struct {
    bytes: []const u8,
    width: u32,
    height: u32,
    row_bytes: u32,
};

const ProfileFeatures = struct {
    enabled: bool,
    timestamps: bool,
    inside_encoders: bool,
};

fn profile_create(
    adapter: Adapter,
    device: Device,
    queue: Queue,
    features: ProfileFeatures,
) Profile {
    if (features.timestamps) assert(features.enabled);
    if (features.inside_encoders) assert(features.timestamps);
    var profile: Profile = std.mem.zeroes(Profile);
    profile.enabled = features.enabled;
    profile.inside_encoders = features.inside_encoders;
    if (!features.enabled) return profile;
    var info: AdapterInfo = std.mem.zeroes(AdapterInfo);
    if (wgpuAdapterGetInfo(adapter, &info) == status_success) {
        const name = if (info.device.data) |data| data[0..info.device.length] else "";
        const len: u32 = @intCast(@min(name.len, adapter_name_cap));
        @memcpy(profile.adapter_name[0..len], name[0..len]);
        profile.adapter_name_len = len;
        wgpuAdapterInfoFreeMembers(info);
    }
    if (!features.timestamps) return profile;
    profile.period_ns = wgpuQueueGetTimestampPeriod(queue);
    profile.query = wgpuDeviceCreateQuerySet(device, &.{
        .next_in_chain = null,
        .label = empty_label,
        .type = query_type_timestamp,
        .count = timestamp_count,
    });
    profile.resolve = create_profile_buffer(device, buffer_usage_query_resolve |
        buffer_usage_copy_src, timestamp_bytes);
    profile.read = create_profile_buffer(
        device,
        buffer_usage_map_read | usage_copy_dst,
        timestamp_bytes,
    );
    assert(profile.period_ns > 0);
    assert(profile.query != null);
    return profile;
}

fn create_profile_buffer(device: Device, usage: Flags, size: u64) ?Buffer {
    assert(size % 4 == 0);
    assert(usage != 0);
    return wgpuDeviceCreateBuffer(device, &.{
        .next_in_chain = null,
        .label = empty_label,
        .usage = usage,
        .size = size,
        .mapped_at_creation = 0,
    });
}

/// Records the timestamp resolve and, when requested, the copy of the surface texture into
/// `encoder`, before `finish`. Does nothing outside bench mode.
fn profile_record(self: *Gpu, encoder: CommandEncoder, frame: *const Frame) void {
    const profile = &self.profile;
    if (!profile.enabled) return;
    const target = frame.texture.?;
    if (profile.query) |query| {
        // Only queries this frame wrote: resolving one never written waits on it forever on
        // Vulkan, which loses the device. The passes' pairs land at offset 0, the copy's at
        // `copy_resolve_offset` (a resolve offset must be a multiple of 256).
        const passes = 2 * frame.timed_passes;
        if (passes != 0) wgpuCommandEncoderResolveQuerySet(encoder, query, 0, passes, profile.resolve.?, 0);
        if (frame.timed_copy) {
            wgpuCommandEncoderResolveQuerySet(encoder, query, 2 * pass_cap, 2, profile.resolve.?, copy_resolve_offset);
        }
        if (passes != 0 or frame.timed_copy) {
            wgpuCommandEncoderCopyBufferToBuffer(
                encoder,
                profile.resolve.?,
                0,
                profile.read.?,
                0,
                timestamp_bytes,
            );
        }
    }
    if (!profile.image_requested) return;
    assert(profile.image == null);
    const width = self.configured_width;
    const height = self.configured_height;
    const row_bytes = std.mem.alignForward(u32, width * 4, copy_row_align);
    const buffer = create_profile_buffer(
        self.device,
        buffer_usage_map_read | usage_copy_dst,
        @as(u64, row_bytes) * height,
    ) orelse return;
    const source: TexelCopyTextureInfo = .{
        .texture = target,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = 0,
    };
    const destination: TexelCopyBufferInfo = .{
        .layout = .{ .offset = 0, .bytes_per_row = row_bytes, .rows_per_image = height },
        .buffer = buffer,
    };
    const size: Extent3D = .{ .width = width, .height = height, .depth_or_array_layers = 1 };
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &destination, &size);
    profile.image = buffer;
    profile.image_width = width;
    profile.image_height = height;
    profile.image_row_bytes = row_bytes;
    profile.image_requested = false;
}

/// After present: blocks until the frame's GPU work is done, then reads its GPU time (the
/// pass plus `present_copy`'s copy, whichever ran) and maps the frame copy if one was
/// recorded.
fn profile_read(self: *Gpu, frame: *const Frame) void {
    const profile = &self.profile;
    if (!profile.enabled) return;
    profile.pass_ns = null;
    if (profile.read) |read| {
        if (map_blocking(self, read, timestamp_bytes)) {
            const range = wgpuBufferGetConstMappedRange(read, 0, timestamp_bytes).?;
            const stamps: *const [timestamp_bytes / 8]u64 = @ptrCast(@alignCast(range));
            // The passes' pairs from offset 0, the copy's at `copy_resolve_offset`.
            var ticks: u64 = 0;
            profile.pass_count = frame.timed_passes;
            for (0..frame.timed_passes) |pass| {
                const pass_ticks = stamps[2 * pass + 1] -% stamps[2 * pass];
                profile.passes_ns[pass] = @intFromFloat(@as(f64, @floatFromInt(pass_ticks)) * profile.period_ns);
                ticks += pass_ticks;
            }
            if (frame.timed_copy) {
                const at = copy_resolve_offset / 8;
                ticks += stamps[at + 1] -% stamps[at];
            }
            const ns = @as(f64, @floatFromInt(ticks)) * profile.period_ns;
            profile.pass_ns = @intFromFloat(ns);
            wgpuBufferUnmap(read);
        }
    }
    if (profile.image) |image| {
        if (profile.image_mapped) return;
        const size = @as(u64, profile.image_row_bytes) * profile.image_height;
        profile.image_mapped = map_blocking(self, image, size);
    }
}

/// Maps `buffer` for reading and waits, bounded by `wait_max` device polls.
fn map_blocking(self: *Gpu, buffer: Buffer, size: u64) bool {
    assert(size > 0);
    assert(wait_max >= 1);
    var done: bool = false;
    const info: BufferMapCallbackInfo = .{
        .next_in_chain = null,
        .mode = callback_process_events,
        .callback = map_ready,
        .userdata1 = @ptrCast(&done),
        .userdata2 = null,
    };
    _ = wgpuBufferMapAsync(buffer, map_mode_read, 0, @intCast(size), info);
    var waits: u32 = 0;
    while (waits < wait_max) : (waits += 1) {
        _ = wgpuDevicePoll(self.device, 1, null);
        wgpuInstanceProcessEvents(self.instance);
        if (done) return true;
    }
    return false;
}

fn map_ready(
    status: u32,
    message: StringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const done: *bool = @ptrCast(@alignCast(userdata1.?));
    done.* = status == map_status_success;
}

/// The render pass time of the last presented frame, null outside bench mode or without
/// the timestamp feature.
/// Each timed pass of the last profiled frame, in recording order: the offscreen targets'
/// passes first, then the main one.
pub fn profile_passes_ns(self: *const Gpu) []const u64 {
    assert(self.profile.pass_count <= pass_cap);
    return self.profile.passes_ns[0..self.profile.pass_count];
}

pub fn profile_pass_ns(self: *const Gpu) ?u64 {
    if (!self.profile.enabled) assert(self.profile.pass_ns == null);
    return self.profile.pass_ns;
}

/// The adapter's device name, empty outside bench mode.
pub fn profile_adapter(self: *const Gpu) []const u8 {
    assert(self.profile.adapter_name_len <= adapter_name_cap);
    return self.profile.adapter_name[0..self.profile.adapter_name_len];
}

/// Copies the next presented frame for `frame_image`. Bench mode only.
pub fn request_frame_image(self: *Gpu) void {
    assert(self.profile.enabled);
    assert(self.profile.image == null);
    self.profile.image_requested = true;
}

/// The copied frame, mapped, or null if none is ready.
pub fn frame_image(self: *const Gpu) ?FrameImage {
    const profile = &self.profile;
    const image = profile.image orelse return null;
    if (!profile.image_mapped) return null;
    const size = @as(u64, profile.image_row_bytes) * profile.image_height;
    const range = wgpuBufferGetConstMappedRange(image, 0, @intCast(size)) orelse return null;
    const bytes: [*]const u8 = @ptrCast(range);
    assert(profile.image_row_bytes >= profile.image_width * 4);
    return .{
        .bytes = bytes[0..@intCast(size)],
        .width = profile.image_width,
        .height = profile.image_height,
        .row_bytes = profile.image_row_bytes,
    };
}

/// Unmaps and releases the copied frame.
pub fn release_frame_image(self: *Gpu) void {
    const profile = &self.profile;
    const image = profile.image orelse return;
    if (profile.image_mapped) wgpuBufferUnmap(image);
    wgpuBufferRelease(image);
    profile.image = null;
    profile.image_mapped = false;
    assert(profile.image == null);
}

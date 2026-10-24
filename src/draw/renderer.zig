//! Records the draw context's pools and batches as a GPU command stream.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Role
//! `Renderer(Context)` is the only code that knows what the GPU is asked to do, and it is
//! generic over the app's draw context, so its tables are sized by `App.config.draw`. `setup`
//! records every long-lived resource once, right after the host creates its device: one
//! shader module (labelled with the type name), pipeline, and instance buffer per draw type,
//! the frame and texture bind group layouts, the unit quad and uniform buffers, the sampler,
//! the frame bind group, the unit quad upload, and the textures queued so far (the atlas
//! first). `frame` records one frame: queued textures, the uploads the shadows ask for, then
//! one pass with one draw per batch, then present. The hosts only replay the stream
//! (`gpu/commands.zig`), so this file is pure and every recording is unit tested without a GPU.
//!
//! ## 2. Descriptors
//! Buffer 0 is the unit quad stepped per vertex (location 0, `float32x2`); buffer 1 is the
//! type's pool stepped per instance (`registry.instance_layout`). Group 0 is the frame
//! uniform, shared by every pipeline; group 1 is a texture and its sampler, for textured types
//! only, with one bind group per texture. There are two texture layouts, one per
//! `textures.Class`: filterable (a float texture and a filtering sampler) and unfilterable
//! (the 32-bit float formats, with a non-filtering sampler). A pipeline takes its type's
//! class and a bind group its texture's, which agree because a type's format is its
//! textures' format. Samplers are one per `textures.Sampling` mode: the default (linear,
//! clamped) at setup, any other in the stream that first creates a texture using it, and
//! shared from then on. Each pipeline blends by its type's `blend` (`registry.zig`, 2c). When a registered type
//! reads points (`registry.reads_points`), group 0 also holds the point buffer at binding 1
//! (read-only storage, vertex and fragment stages, since a type's `vertex` may read it too),
//! so it is bound once per pass with the uniform and a
//! pipeline that does not declare it ignores it.
//!
//! ## 3. Frame Shape
//! ```text
//! buffer_write uniform            only when the device size or scale changed (or first frame)
//! texture_create, bind_group_create, texture_write   whatever `Textures` queued, after the
//!                                 glyph cache queued its dirty atlas rectangle (one write)
//! buffer_write pool[i] [range]    per pool whose revision moved and whose records changed
//! buffer_write points [range]     when the point revision moved and points changed
//! buffer_write uniform time       16 bytes at `draw.time_offset`, while animating and the
//!                                 time moved (section 4b)
//! then, by the frame's kind (section 4a), nothing (skipped), present_copy (copied), or:
//! [target_create]                 the kept target, at its first use or a new size
//! pass_begin                      the surface (direct), or the kept target, cleared (full)
//!                                 or loaded (cached)
//!   per rect (cached only): scissor_set, pipeline_set clear, vertex_buffer_set 0, draw
//!   bind_group_set 0, vertex_buffer_set 0                   once, when any batch exists
//!   per batch, in order:
//!     pipeline_set, vertex_buffer_set 1    only when the type differs from the last batch
//!     bind_group_set 1                     only when a textured batch changes texture
//!     draw (6 vertices, count instances, first_instance = batch.first)
//! pass_end_present (direct), or pass_end and present_copy (full, cached)
//! ```
//! `frame_op_cap` and `frame_bytes_max` bound this at compile time from the type count and
//! `batch_cap`, with `rects_max` rects for a cached frame; `app.check` rejects a configuration
//! whose worst frame would not fit one `commands.CommandBuffer`.
//!
//! ## 4. Uploads (Dirty Ranges per Pool)
//! Each pool has a shadow of what the GPU last received and the revision it was taken at.
//! - Revision equal to the shadow's: nothing, without looking at the records. This is the
//!   idle path: a frame the host did not draw takes it for every pool.
//! - Revision moved: the finalized (sorted) records are compared with the shadow, and
//!   `draw.dirty_range` returns the smallest record range covering every change plus every
//!   record past the shadow's count. An identical rebuild writes nothing, and a hover that
//!   changes one arc writes one record of the arc pool only.
//! Only the written range is copied into the shadow, because records outside it are equal by
//! construction. The point pool follows the same rule with its own shadow and revision, so a
//! rebuilt path writes no points when its shape is unchanged, and a recolored path writes its
//! `Path` records only. The counting sort is stable by key and overlays sort last, so content that
//! appears on a higher layer lands at the tail of its pool and keeps ranges small.
//!
//! A scale change redraws the scene (glyphs are rasterized and snapped per device scale; see
//! `text/cache.zig`), but only glyph records move: the box and arc pools compare equal and
//! write nothing, and the frame writes the uniform, the new atlas rectangle, and the glyph
//! range. Test "a scale change writes the uniform, the atlas, and glyphs only" locks it.
//!
//! ## 4a. Pixel Cache
//! The renderer keeps the last frame's pixels in a render target (the kept target) and
//! repaints only the tiles whose commands changed (`draw/tiles.zig`). After the uploads,
//! `frame` hashes the finalized batches into tiles and picks one of five frames (`Kind`):
//! ```text
//! skipped  no tile changed           nothing more: no pass, no present (uploads still go)
//! copied   none changed, but a present was asked for (`present_next`, a frame dump):
//!          present_copy of the kept target
//! cached   some changed, kept target valid: one pass on the kept target that loads it, and
//!          per dirty rect: scissor_set, the clear pipeline, every batch; then pass_end and
//!          present_copy
//! full     some changed, kept target stale: one pass on it that clears it, every batch,
//!          pass_end, present_copy; the kept target is valid again
//! direct   more than half changed (scrolling, a resize, the first frame), or the cache is
//!          off or the target too large: today's pass on the surface, no copy; the kept
//!          target goes stale
//! ```
//! Inside a scissor the kept pixels must be cleared before the batches blend over them, and
//! WebGPU clears whole attachments only, so a small clear pipeline (no blending, one
//! full-target quad of `clear_color`) runs first in each rect. A scissor does not change any
//! pixel value, so a cached frame equals a direct one bit for bit; the bench's image compare
//! checks it (`--no-cache`). A uniform change (size or scale) dirties every tile. The rect
//! count is bounded per app by `rects_max`, so the worst frame still fits one command buffer.
//!
//! ## 4b. Animated Types and Time
//! An animated type (`draw/registry.zig`, section 2b) changes its pixels with the time slot,
//! not its records, so hashing alone would never repaint it. `hash_batch` forces the tiles of
//! every animated instance dirty (`Tiles.force`), and `animating` reports that one touched a
//! tile: the hosts then keep frame callbacks coming and advance `animator.Time`, and a frame
//! with no animated instance on screen ends the chain. With the cache off, `animating` is true
//! whenever the finalized frame holds an animated batch.
//!
//! A frame whose instances are exactly the last frame's (no pool or point revision moved, no
//! texture write or create, no uniform change, and the last frame hashed on this grid) would
//! fold the same hashes, so `choose` skips the fold: `Tiles.repeat` makes the last frame's
//! forced tiles dirty, and `animating` keeps its value (`hashed` is false). That is the idle
//! frame (skipped) and the animation-only frame (the animated tiles, cached).
//! ```text
//! animation-only frame:  buffer_write uniform time (16 B)
//!                        pass_begin kept target, load
//!                          per rect: scissor_set, clear, every batch
//!                        pass_end, present_copy
//! ```
//! The time write is recorded when the registry has an animated type, this frame is animating,
//! and `time_s` differs from the uploaded value; a registry without animated types never writes
//! it. A resize frame writes the whole uniform first and the time after it.
//!
//! ## 5. Lifetime
//! Spans point into the context's pools, `Textures`' queued writes (the glyph cache's mirror
//! among them), `Renderer.uniform`, and static data, so all of them must stay put until the
//! host's submit returns. Both hosts
//! submit synchronously from the call that recorded the stream.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");
const draw = @import("../draw.zig");
const pools = @import("pools.zig");
const registry = @import("registry.zig");
const textures = @import("textures.zig");
const theme = @import("../theme.zig");
const tiles_module = @import("tiles.zig");
const types = @import("types.zig");

/// Straight (non-premultiplied) RGBA color with components in `[0, 1]`.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Framebuffer clear color. Deliberately neither black nor white, so a skipped clear, a failed
/// pass, or a swapchain glitch is unmistakable in review. It also shows through wherever a
/// fragment has zero coverage, such as outside a rounded corner.
pub const clear_color: Color = .{
    .r = 0.11,
    .g = 0.12,
    .b = 0.16,
    .a = 1.0,
};

/// The frame uniform: projection, time, and the theme, `draw.uniform_bytes` in all.
/// `time[0]` is the animation time in seconds; the other lanes stay zero.
pub const Uniform = extern struct {
    ortho: [16]f32,
    time: [4]f32,
    theme: theme.Theme,
};

/// Logical size, physical size for the pass, and the display scale in 1/120 units. The
/// projection is built from the physical size and the scale (`draw.ortho_y_down`). All
/// nonzero.
pub const Size = struct {
    width_logical: u32,
    height_logical: u32,
    width_px: u32,
    height_px: u32,
    scale_120: u32,
};

const BindGroupEntries = [commands.bind_group_entry_cap]commands.BindGroupEntry;
const LayoutEntries = [commands.layout_entry_cap]commands.LayoutEntry;

/// Ops a frame records at most per batch: pipeline, instance buffer, texture group, draw.
const batch_op_cap: u32 = 4;

/// Ops one cached rect records besides its batches: scissor, the clear pipeline, its vertex
/// buffer and draw, and the frame group and unit quad that `draw_batches` binds.
const rect_op_cap: u32 = 6;

/// Upper bound on the ops `frame` records: a cached frame of `rects_max` rects (module guide,
/// sections 3 and 4a), which is longer than a direct one.
pub fn frame_op_cap(type_count: u32, batch_cap: u32) u32 {
    const texture_ops = textures.sampling_count + 2 * textures.texture_cap + textures.write_cap;
    const rects = rects_max(type_count, batch_cap);
    // Uniform, textures, one write per pool and one for the points, the time, the target,
    // the pass, the rects with their batches, the pass end, and the present.
    return 1 + texture_ops + type_count + 1 + 1 + 1 + 1 +
        rects * (rect_op_cap + batch_cap * batch_op_cap) + 1 + 1;
}

/// Upper bound on the bytes `frame` records, for the same shape as `frame_op_cap`.
pub fn frame_bytes_max(type_count: u32, batch_cap: u32) u32 {
    return frame_bytes_for(type_count, batch_cap, rects_max(type_count, batch_cap));
}

/// Most rects a cached frame repaints for an app: up to `tiles.rect_cap`, as many as fit one
/// command buffer with every batch replayed per rect, and at least 1.
pub fn rects_max(type_count: u32, batch_cap: u32) u32 {
    var rects: u32 = tiles_module.rect_cap;
    while (rects > 1) : (rects -= 1) {
        if (frame_bytes_for(type_count, batch_cap, rects) <= commands.capacity) break;
    }
    assert(rects >= 1);
    return rects;
}

fn frame_bytes_for(type_count: u32, batch_cap: u32, rects: u32) u32 {
    const texture_bytes = textures.sampling_count * op_bytes(commands.SamplerCreate) +
        textures.texture_cap *
            (op_bytes(commands.TextureCreate) + op_bytes(commands.BindGroupCreate)) +
        textures.write_cap * op_bytes(commands.TextureWrite);
    const pass_bytes = op_bytes(commands.TargetCreate) + op_bytes(commands.PassBegin) +
        op_bytes(commands.PassEnd) + op_bytes(commands.PresentCopy);
    const per_batch = op_bytes(commands.PipelineSet) + op_bytes(commands.VertexBufferSet) +
        op_bytes(commands.BindGroupSet) + op_bytes(commands.Draw);
    const per_rect = op_bytes(commands.ScissorSet) + op_bytes(commands.PipelineSet) +
        2 * op_bytes(commands.VertexBufferSet) + op_bytes(commands.Draw) +
        op_bytes(commands.BindGroupSet) + batch_cap * per_batch;
    return (3 + type_count) * op_bytes(commands.BufferWrite) + texture_bytes + pass_bytes +
        rects * per_rect;
}

/// What a recorded frame does (module guide, section 4a).
pub const Kind = enum(u8) {
    skipped,
    copied,
    cached,
    full,
    direct,
};

/// The clear pipeline's WGSL: one full-target quad of `clear_color`, no bindings.
const clear_wgsl: []const u8 = std.fmt.comptimePrint(
    \\@vertex
    \\fn vs_main(@location(0) unit: vec2<f32>) -> @builtin(position) vec4<f32> {{
    \\    return vec4<f32>(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    \\}}
    \\
    \\@fragment
    \\fn fs_main() -> @location(0) vec4<f32> {{
    \\    return vec4<f32>({d:.6}, {d:.6}, {d:.6}, {d:.6});
    \\}}
    \\
, .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a });

fn op_bytes(comptime Payload: type) u32 {
    const size: u32 = @sizeOf(Payload);
    return commands.header_bytes + (size + commands.op_align - 1) / commands.op_align *
        commands.op_align;
}

/// The renderer for one draw context type (`draw.Context(...)`). See the module guide.
pub fn Renderer(comptime Cx: type) type {
    const R = Cx.Registry;
    const shadow_types: [R.count]type = blk: {
        var out: [R.count]type = undefined;
        for (0..R.count) |index| out[index] = Shadow(R.Type(index), R.caps[index]);
        break :blk out;
    };
    comptime {
        assert(frame_bytes_max(R.count, Cx.batch_capacity) <= commands.capacity);
    }
    return struct {
        const Self = @This();

        ids: commands.Ids,
        resources: Resources,
        shadows: @Tuple(&shadow_types),
        /// What the GPU last received of the point pool (module guide, section 4).
        point_shadow: Shadow(pools.Point, Cx.point_capacity),
        uniform: Uniform,
        /// Device size and scale the uploaded uniform was built for; 0 before the first frame.
        width_px: u32,
        height_px: u32,
        scale_120: u32,
        ready: bool,
        /// The pixel cache is on (module guide, section 4a); the host may turn it off.
        cache: bool,
        /// The next frame presents even when no tile changed (a frame dump).
        present_next: bool,
        /// What the last `frame` recorded.
        last: Kind,
        tiles: tiles_module.Tiles,
        /// The kept target's texture id, allocated at the first frame that needs it.
        kept: ?u16,
        kept_width: u32,
        kept_height: u32,
        /// The kept target holds the last presented frame.
        kept_valid: bool,
        /// The shadows' tile keys belong to the last frame (module guide, section 4a).
        keys_valid: bool,
        /// An animated instance is on screen: the host keeps presenting (section 4b).
        animating: bool,
        /// The last `frame` folded its instances into tiles, rather than repeating the last
        /// frame's (section 4b).
        hashed: bool,

        /// Most ops one `frame` records.
        pub const op_cap: u32 = frame_op_cap(R.count, Cx.batch_capacity);
        /// Most rects one cached frame repaints (module guide, section 4a).
        pub const rect_count_max: u32 = rects_max(R.count, Cx.batch_capacity);

        /// True when the frame group carries the point buffer (module guide, section 2).
        const uses_points: bool = Cx.point_capacity != 0;
        const frame_entry_count: u16 = if (uses_points) 2 else 1;

        /// The ids `setup` allocated.
        pub const Resources = struct {
            shaders: [R.count]u16,
            pipelines: [R.count]u16,
            instance_buffers: [R.count]u16,
            frame_layout: u16,
            /// One texture layout per `textures.Class`, by its value.
            texture_layouts: [2]u16,
            unit_buffer: u16,
            uniform_buffer: u16,
            /// The point buffer; meaningful only when `Cx.point_capacity != 0`.
            points_buffer: u16,
            /// One sampler per `textures.Sampling` mode, by `Sampling.index`, once created.
            samplers: [textures.sampling_count]?u16,
            frame_group: u16,
            clear_shader: u16,
            clear_pipeline: u16,
            textures: [textures.texture_cap]u16,
            texture_groups: [textures.texture_cap]u16,
        };

        /// Out-pointer init so a static renderer needs no stack copy.
        pub fn init(self: *Self) void {
            self.ids = .init();
            self.uniform = .{ .ortho = undefined, .time = @splat(0), .theme = theme.chrome };
            self.width_px = 0;
            self.height_px = 0;
            self.scale_120 = 0;
            self.ready = false;
            self.cache = true;
            self.present_next = false;
            self.last = .direct;
            self.tiles.init();
            self.kept = null;
            self.kept_width = 0;
            self.kept_height = 0;
            self.kept_valid = false;
            inline for (0..R.count) |index| {
                self.shadows[index].count = 0;
                self.shadows[index].revision = 0;
                self.shadows[index].changed = .{ .first = 0, .end = 0 };
            }
            self.point_shadow.changed = .{ .first = 0, .end = 0 };
            self.point_shadow.count = 0;
            self.point_shadow.revision = 0;
            self.keys_valid = false;
            self.animating = false;
            self.hashed = false;
            assert(!self.ready);
            assert(self.width_px == 0);
        }

        /// Records every long-lived resource, the unit quad upload, and the textures queued
        /// so far. Called once, on an empty buffer, before the first `frame`.
        pub fn setup(self: *Self, buffer: *commands.CommandBuffer, cx: *Cx) void {
            assert(!self.ready);
            assert(buffer.len == 0);
            self.setup_layouts(buffer);
            const r = &self.resources;
            const vertex_usage = commands.usage_vertex | commands.usage_copy_dst;
            r.unit_buffer = self.create_buffer(buffer, vertex_usage, draw.quad_bytes);
            r.uniform_buffer = self.create_buffer(
                buffer,
                commands.usage_uniform | commands.usage_copy_dst,
                draw.uniform_bytes,
            );
            r.points_buffer = 0;
            if (uses_points) {
                r.points_buffer = self.create_buffer(
                    buffer,
                    commands.usage_storage | commands.usage_copy_dst,
                    Cx.point_capacity * @sizeOf(pools.Point),
                );
            }
            r.samplers = @splat(null);
            _ = self.sampler_for(buffer, .{});
            r.frame_group = self.ids.take(.bind_group);
            var frame_bindings = std.mem.zeroes(BindGroupEntries);
            frame_bindings[0] = .{ .binding = 0, .resource = r.uniform_buffer };
            if (uses_points) {
                frame_bindings[1] = .{ .binding = 1, .resource = r.points_buffer };
            }
            buffer.push(.{ .bind_group_create = .{
                .id = r.frame_group,
                .layout = r.frame_layout,
                .entry_count = frame_entry_count,
                .entries = frame_bindings,
            } });
            inline for (0..R.count) |index| {
                self.setup_type(buffer, index);
            }
            self.setup_clear(buffer);
            buffer.push(.{ .buffer_write = .{
                .id = r.unit_buffer,
                .offset = 0,
                .data = .of(std.mem.asBytes(&draw.unit_quad)),
            } });
            self.flush_textures(buffer, &cx.textures);
            self.ready = true;
            assert(self.ready);
            assert(cx.textures.created == cx.textures.count);
        }

        fn setup_layouts(self: *Self, buffer: *commands.CommandBuffer) void {
            const r = &self.resources;
            r.frame_layout = self.ids.take(.layout);
            var frame_entries = std.mem.zeroes(LayoutEntries);
            frame_entries[0] = .{
                .binding = 0,
                .visibility = commands.stage_vertex | commands.stage_fragment,
                .kind = .uniform,
            };
            if (uses_points) {
                frame_entries[1] = .{
                    .binding = 1,
                    .visibility = commands.stage_vertex | commands.stage_fragment,
                    .kind = .storage_read,
                };
            }
            buffer.push(.{ .layout_create = .{
                .id = r.frame_layout,
                .entry_count = frame_entry_count,
                .entries = frame_entries,
            } });
            const kinds = [2][2]commands.BindingKind{
                .{ .texture, .sampler },
                .{ .texture_unfilterable, .sampler_non_filtering },
            };
            for (&r.texture_layouts, kinds) |*layout, pair| {
                layout.* = self.ids.take(.layout);
                var texture_entries = std.mem.zeroes(LayoutEntries);
                const fragment = commands.stage_fragment;
                texture_entries[0] = .{ .binding = 0, .visibility = fragment, .kind = pair[0] };
                texture_entries[1] = .{ .binding = 1, .visibility = fragment, .kind = pair[1] };
                buffer.push(.{ .layout_create = .{
                    .id = layout.*,
                    .entry_count = 2,
                    .entries = texture_entries,
                } });
            }
            assert(r.frame_layout != r.texture_layouts[0]);
            assert(r.texture_layouts[0] != r.texture_layouts[1]);
        }

        fn setup_type(self: *Self, buffer: *commands.CommandBuffer, comptime index: u32) void {
            const T = R.Type(index);
            const r = &self.resources;
            r.shaders[index] = self.ids.take(.shader);
            buffer.push(.{ .shader_create = .{
                .id = r.shaders[index],
                .source = .of(R.sources[index]),
                .label = .of(R.labels[index]),
            } });
            r.instance_buffers[index] = self.create_buffer(
                buffer,
                commands.usage_vertex | commands.usage_copy_dst,
                R.caps[index] * @sizeOf(T),
            );
            r.pipelines[index] = self.ids.take(.pipeline);
            const layout_count: u8 = if (R.textured[index]) 2 else 1;
            buffer.push(.{ .pipeline_create = .{
                .id = r.pipelines[index],
                .shader = r.shaders[index],
                .layout_count = layout_count,
                .buffer_count = 2,
                .blend = R.blends[index],
                .layouts = .{
                    r.frame_layout,
                    r.texture_layouts[@backingInt(R.classes[index])],
                    0,
                    0,
                },
                .vertex = .{ unit_layout(), R.vertex_layout(index) },
            } });
        }

        /// The clear pipeline the cached frame runs in each rect (module guide, section 4a).
        fn setup_clear(self: *Self, buffer: *commands.CommandBuffer) void {
            const r = &self.resources;
            r.clear_shader = self.ids.take(.shader);
            buffer.push(.{ .shader_create = .{
                .id = r.clear_shader,
                .source = .of(clear_wgsl),
                .label = .of("clear"),
            } });
            r.clear_pipeline = self.ids.take(.pipeline);
            buffer.push(.{ .pipeline_create = .{
                .id = r.clear_pipeline,
                .shader = r.clear_shader,
                .layout_count = 0,
                .buffer_count = 1,
                .blend = .none,
                .layouts = .{ 0, 0, 0, 0 },
                .vertex = .{ unit_layout(), std.mem.zeroes(commands.VertexBuffer) },
            } });
            assert(r.clear_pipeline >= R.count);
            assert(r.clear_shader >= R.count);
        }

        /// The sampler for `sampling`, created in `buffer` the first time a texture needs it.
        fn sampler_for(
            self: *Self,
            buffer: *commands.CommandBuffer,
            sampling: textures.Sampling,
        ) u16 {
            const slot = &self.resources.samplers[sampling.index()];
            if (slot.*) |id| return id;
            const id = self.ids.take(.sampler);
            buffer.push(.{ .sampler_create = .{
                .id = id,
                .filter = sampling.filter,
                .address_u = sampling.address_u,
                .address_v = sampling.address_v,
            } });
            slot.* = id;
            return id;
        }

        fn create_buffer(
            self: *Self,
            buffer: *commands.CommandBuffer,
            usage: u32,
            size: u32,
        ) u16 {
            assert(usage != 0);
            assert(size != 0);
            const id = self.ids.take(.buffer);
            buffer.push(.{ .buffer_create = .{ .id = id, .usage = usage, .size = size } });
            return id;
        }

        /// Records every texture `Textures` created since the last stream, with its bind
        /// group, then every queued write, and empties the write queue.
        fn flush_textures(
            self: *Self,
            buffer: *commands.CommandBuffer,
            table: *textures.Textures,
        ) void {
            assert(table.created <= table.count);
            assert(table.write_count <= textures.write_cap);
            const r = &self.resources;
            while (table.created < table.count) : (table.created += 1) {
                const index = table.created;
                r.textures[index] = self.ids.take(.texture);
                buffer.push(.{ .texture_create = .{
                    .id = r.textures[index],
                    .format = textures.gpu_format(table.formats[index]),
                    .width = table.widths[index],
                    .height = table.heights[index],
                } });
                r.texture_groups[index] = self.ids.take(.bind_group);
                var bindings = std.mem.zeroes(BindGroupEntries);
                bindings[0] = .{ .binding = 0, .resource = r.textures[index] };
                bindings[1] = .{
                    .binding = 1,
                    .resource = self.sampler_for(buffer, table.samplings[index]),
                };
                buffer.push(.{ .bind_group_create = .{
                    .id = r.texture_groups[index],
                    .layout = r.texture_layouts[
                        @backingInt(textures.class_of(table.formats[index]))
                    ],
                    .entry_count = 2,
                    .entries = bindings,
                } });
            }
            for (table.writes[0..table.write_count]) |write| {
                buffer.push(.{ .texture_write = .{
                    .id = r.textures[@backingInt(write.id)],
                    .x = write.region.x,
                    .y = write.region.y,
                    .width = write.region.width,
                    .height = write.region.height,
                    .bytes_per_row = write.bytes_per_row,
                    .data = .of(write.data),
                } });
            }
            table.write_count = 0;
            assert(table.created == table.count);
        }

        /// Records one frame of `cx` into an empty `buffer`. Finalizes the context (sorting
        /// and batching it if it changed) and updates the shadows. `time_s` is the animation
        /// time (`animator.Time.seconds`) animated types read. See the module guide.
        pub fn frame(
            self: *Self,
            buffer: *commands.CommandBuffer,
            cx: *Cx,
            size: Size,
            time_s: f32,
        ) void {
            assert(self.ready);
            assert(buffer.len == 0);
            assert(size.width_px != 0);
            assert(size.height_px != 0);
            assert(size.width_logical != 0);
            assert(size.scale_120 != 0);
            const resized = self.uniform_dirty(size);
            if (resized) {
                draw.ortho_y_down(
                    &self.uniform.ortho,
                    size.width_px,
                    size.height_px,
                    size.scale_120,
                );
                buffer.push(.{ .buffer_write = .{
                    .id = self.resources.uniform_buffer,
                    .offset = 0,
                    .data = .of(std.mem.asBytes(&self.uniform)),
                } });
                self.width_px = size.width_px;
                self.height_px = size.height_px;
                self.scale_120 = size.scale_120;
            }
            assert(time_s >= 0);
            cx.text.queue_upload(&cx.textures);
            const unchanged = !resized and self.same_instances(cx);
            self.flush_textures(buffer, &cx.textures);
            cx.finalize();
            inline for (0..R.count) |index| {
                self.upload_pool(buffer, index, &cx.pools[index]);
            }
            if (uses_points) self.upload_points(buffer, cx);
            const kind = self.choose(cx, size, resized, unchanged);
            if (R.any_animated and self.animating and self.uniform.time[0] != time_s) {
                self.uniform.time[0] = time_s;
                buffer.push(.{ .buffer_write = .{
                    .id = self.resources.uniform_buffer,
                    .offset = draw.time_offset,
                    .data = .of(std.mem.asBytes(&self.uniform.time)),
                } });
            }
            switch (kind) {
                .skipped => {},
                .copied => buffer.push(.{ .present_copy = .{ .target = self.kept.? } }),
                .cached => self.record_kept(buffer, cx, size, .load),
                .full => self.record_kept(buffer, cx, size, .clear),
                .direct => self.record_direct(buffer, cx, size),
            }
            self.last = kind;
            assert(buffer.count <= op_cap);
            assert(buffer.len <= frame_bytes_max(R.count, Cx.batch_capacity));
        }

        /// True when no pool or point revision moved and no texture is created or written
        /// this frame, so the finalized instances are the last frame's. Called before the
        /// uploads, which take the revisions into the shadows.
        fn same_instances(self: *const Self, cx: *const Cx) bool {
            if (cx.textures.write_count != 0) return false;
            if (cx.textures.created != cx.textures.count) return false;
            inline for (0..R.count) |index| {
                if (self.shadows[index].revision != cx.pools[index].revision) return false;
            }
            if (uses_points and self.point_shadow.revision != cx.point_revision) return false;
            return true;
        }

        /// Hashes the frame into tiles, or repeats the last frame's when its instances are
        /// unchanged, and picks its kind (module guide, sections 4a and 4b).
        fn choose(self: *Self, cx: *Cx, size: Size, resized: bool, unchanged: bool) Kind {
            const forced = self.present_next;
            self.present_next = false;
            self.hashed = false;
            if (!self.cache) {
                self.kept_valid = false;
                self.keys_valid = false;
                self.animating = shows_animated(cx);
                return .direct;
            }
            var dirty: u32 = 0;
            if (unchanged and self.keys_valid and self.tiles.valid) {
                assert(self.tiles.width_px == size.width_px);
                assert(self.tiles.height_px == size.height_px);
                dirty = self.tiles.repeat();
            } else {
                if (!self.tiles.begin(size.width_px, size.height_px)) {
                    self.kept_valid = false;
                    self.keys_valid = false;
                    self.animating = shows_animated(cx);
                    return .direct;
                }
                if (resized) self.tiles.invalidate();
                self.animating = false;
                self.hash_frame(cx, size.scale_120);
                self.keys_valid = true;
                self.hashed = true;
                dirty = self.tiles.finish();
            }
            if (dirty == 0) {
                if (!forced) return .skipped;
                return if (self.kept_valid) .copied else .direct;
            }
            if (dirty * 2 > self.tiles.tile_count()) {
                self.kept_valid = false;
                return .direct;
            }
            return if (self.kept_valid) .cached else .full;
        }

        /// Folds every instance into the tiles its bounds touch, in draw order
        /// (`draw/tiles.zig`). A record's key covers its bytes and, for a type that names its
        /// points, those points; it is kept in the shadow and recomputed only for records
        /// (or points) the upload found changed, because hashing every record of a stress
        /// frame (about 600 KB) cost more than the rest of the frame. At fold time the key is
        /// mixed with its batch and with the texture's revision for a sampled texture other
        /// than the glyph atlas, whose regions never change once written.
        fn hash_frame(self: *Self, cx: *const Cx, scale_120: u32) void {
            const scale: f32 = @as(f32, @floatFromInt(scale_120)) / 120.0;
            const points_key: u64 = if (whole_points_key)
                tiles_module.key_of(0, std.mem.sliceAsBytes(cx.point_items()))
            else
                0;
            for (cx.batch_list(), 0..) |batch, batch_index| {
                inline for (0..R.count) |index| {
                    if (batch.type_id == index) {
                        self.hash_batch(index, cx, batch, @intCast(batch_index), .{
                            .scale = scale,
                            .points_key = points_key,
                        });
                    }
                }
            }
        }

        /// True when the finalized frame holds an instance of an animated type.
        fn shows_animated(cx: *const Cx) bool {
            if (comptime !R.any_animated) return false;
            for (cx.batch_list()) |batch| {
                if (R.animates[batch.type_id]) return true;
            }
            return false;
        }

        /// True when some type reads points without naming its range (`first_point`), so
        /// its key folds in the whole point pool; `draw.Path` names its range.
        const whole_points_key: bool = blk: {
            for (0..R.count) |index| {
                const T = R.Type(index);
                if (registry.reads_points(T) and !@hasField(T, "first_point")) break :blk true;
            }
            break :blk false;
        };

        const HashContext = struct {
            scale: f32,
            /// A hash of the whole point pool, for a points type without `first_point`.
            points_key: u64,
        };

        fn hash_batch(
            self: *Self,
            comptime index: u32,
            cx: *const Cx,
            batch: pools.Batch,
            batch_index: u32,
            context: HashContext,
        ) void {
            const T = R.Type(index);
            assert(batch.count >= 1);
            var seed: u64 = (@as(u64, batch_index) << 32) | (@as(u64, index) << 16) |
                @backingInt(batch.texture);
            if (R.textured[index] and batch.texture != .atlas) {
                seed ^= @as(u64, cx.textures.revision_of(batch.texture)) << 40;
            }
            var batch_key = tiles_module.key_of(seed, std.mem.asBytes(&seed));
            if (comptime registry.reads_points(T) and !@hasField(T, "first_point")) {
                batch_key ^= context.points_key;
            }
            const shadow = &self.shadows[index];
            const items = cx.items(T)[batch.first..][0..batch.count];
            for (items, batch.first..) |*item, pool_index| {
                if (!self.keys_valid or self.key_stale(T, shadow, item, @intCast(pool_index))) {
                    shadow.keys[pool_index] = record_key(T, cx, item);
                }
                const key = shadow.keys[pool_index] ^ batch_key;
                const x0 = @max(item.rect[0], item.clip[0]) * context.scale;
                const y0 = @max(item.rect[1], item.clip[1]) * context.scale;
                const x1 = @min(item.rect[0] + item.rect[2], item.clip[2]) * context.scale;
                const y1 = @min(item.rect[1] + item.rect[3], item.clip[3]) * context.scale;
                self.tiles.add(.{ x0, y0, x1, y1 }, key);
                if (comptime R.animates[index]) {
                    if (self.tiles.force(.{ x0, y0, x1, y1 })) self.animating = true;
                }
            }
        }

        /// True when the record at `pool_index` (or a point it names) changed since the
        /// last frame's key was taken.
        fn key_stale(
            self: *const Self,
            comptime T: type,
            shadow: anytype,
            item: *const T,
            pool_index: u32,
        ) bool {
            if (in_range(shadow.changed, pool_index, pool_index + 1)) return true;
            if (comptime !(registry.reads_points(T) and @hasField(T, "first_point"))) {
                return false;
            }
            const first: u32 = @intFromFloat(item.first_point);
            const count: u32 = @intFromFloat(item.point_count);
            return in_range(self.point_shadow.changed, first, first + count);
        }

        /// The key of one record: its bytes, then the points it names, if any.
        fn record_key(comptime T: type, cx: *const Cx, item: *const T) u64 {
            const key = tiles_module.key_of(0, std.mem.asBytes(item));
            if (comptime !(registry.reads_points(T) and @hasField(T, "first_point"))) {
                return key;
            }
            const first: u32 = @intFromFloat(item.first_point);
            const count: u32 = @intFromFloat(item.point_count);
            const points = cx.point_items()[first..][0..count];
            return tiles_module.key_of(key, std.mem.sliceAsBytes(points));
        }

        /// Today's frame: one pass on the surface that clears it, every batch, present.
        fn record_direct(self: *Self, buffer: *commands.CommandBuffer, cx: *Cx, size: Size) void {
            buffer.push(.{ .pass_begin = .{
                .width_px = size.width_px,
                .height_px = size.height_px,
                .clear = .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a },
                .target = commands.surface_target,
                .load = .clear,
            } });
            self.draw_batches(buffer, cx.batch_list());
            buffer.push(.{ .pass_end_present = .{} });
        }

        /// A pass on the kept target: cleared with every batch (`full`), or loaded with each
        /// dirty rect cleared and repainted (`cached`). Then the copy to the surface.
        fn record_kept(
            self: *Self,
            buffer: *commands.CommandBuffer,
            cx: *Cx,
            size: Size,
            load: commands.LoadOp,
        ) void {
            const kept = self.kept_target(buffer, size);
            if (load == .load) assert(self.kept_valid);
            buffer.push(.{ .pass_begin = .{
                .width_px = size.width_px,
                .height_px = size.height_px,
                .clear = .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a },
                .target = kept,
                .load = load,
            } });
            if (load == .clear) {
                self.draw_batches(buffer, cx.batch_list());
            } else {
                var rects: [rect_count_max]tiles_module.Rect = undefined;
                const count = self.tiles.rects(&rects);
                assert(count >= 1);
                for (rects[0..count]) |rect| {
                    buffer.push(.{ .scissor_set = .{
                        .x = rect.x,
                        .y = rect.y,
                        .width = rect.width,
                        .height = rect.height,
                    } });
                    self.draw_clear(buffer);
                    self.draw_batches(buffer, cx.batch_list());
                }
            }
            buffer.push(.{ .pass_end = .{} });
            buffer.push(.{ .present_copy = .{ .target = kept } });
            self.kept_valid = true;
        }

        /// The kept target's id, created (or recreated at a new size) in `buffer` first.
        fn kept_target(self: *Self, buffer: *commands.CommandBuffer, size: Size) u16 {
            const id = self.kept orelse self.ids.take(.texture);
            self.kept = id;
            if (self.kept_width != size.width_px or self.kept_height != size.height_px) {
                buffer.push(.{ .target_create = .{
                    .id = id,
                    .width = size.width_px,
                    .height = size.height_px,
                } });
                self.kept_width = size.width_px;
                self.kept_height = size.height_px;
                self.kept_valid = false;
            }
            assert(self.kept != null);
            return id;
        }

        fn draw_clear(self: *const Self, buffer: *commands.CommandBuffer) void {
            const r = &self.resources;
            buffer.push(.{ .pipeline_set = .{ .id = r.clear_pipeline } });
            buffer.push(.{ .vertex_buffer_set = .{
                .slot = 0,
                .buffer = r.unit_buffer,
                .offset = 0,
            } });
            buffer.push(.{ .draw = .{
                .vertex_count = draw.vertex_count,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = 0,
            } });
        }

        fn uniform_dirty(self: *const Self, size: Size) bool {
            assert(size.width_px != 0);
            assert(size.height_px != 0);
            if (self.width_px != size.width_px) {
                return true;
            }
            if (self.height_px != size.height_px) {
                return true;
            }
            return self.scale_120 != size.scale_120;
        }

        fn upload_pool(
            self: *Self,
            buffer: *commands.CommandBuffer,
            comptime index: u32,
            pool: anytype,
        ) void {
            const T = R.Type(index);
            const shadow = &self.shadows[index];
            assert(pool.count <= R.caps[index]);
            assert(shadow.count <= R.caps[index]);
            shadow.changed = .{ .first = 0, .end = 0 };
            if (shadow.revision == pool.revision) {
                return;
            }
            const records = pool.items[0..pool.count];
            if (draw.dirty_range(T, shadow.items[0..shadow.count], records)) |range| {
                shadow.changed = range;
                buffer.push(.{ .buffer_write = .{
                    .id = self.resources.instance_buffers[index],
                    .offset = range.first * @sizeOf(T),
                    .data = .of(std.mem.sliceAsBytes(records[range.first..range.end])),
                } });
                // Records outside the range already equal the shadow (module guide, 4).
                @memcpy(shadow.items[range.first..range.end], records[range.first..range.end]);
            }
            shadow.count = pool.count;
            shadow.revision = pool.revision;
            assert(shadow.count == pool.count);
        }

        /// The point pool's upload: the same revision and shadow rule as `upload_pool`.
        fn upload_points(self: *Self, buffer: *commands.CommandBuffer, cx: *const Cx) void {
            const shadow = &self.point_shadow;
            assert(cx.point_count <= Cx.point_capacity);
            assert(shadow.count <= Cx.point_capacity);
            shadow.changed = .{ .first = 0, .end = 0 };
            if (shadow.revision == cx.point_revision) {
                return;
            }
            const points = cx.points[0..cx.point_count];
            const old = shadow.items[0..shadow.count];
            if (draw.dirty_range(pools.Point, old, points)) |range| {
                shadow.changed = range;
                buffer.push(.{ .buffer_write = .{
                    .id = self.resources.points_buffer,
                    .offset = range.first * @sizeOf(pools.Point),
                    .data = .of(std.mem.sliceAsBytes(points[range.first..range.end])),
                } });
                @memcpy(shadow.items[range.first..range.end], points[range.first..range.end]);
            }
            shadow.count = cx.point_count;
            shadow.revision = cx.point_revision;
            assert(shadow.count == cx.point_count);
        }

        fn draw_batches(
            self: *const Self,
            buffer: *commands.CommandBuffer,
            batches: []const pools.Batch,
        ) void {
            assert(batches.len <= Cx.batch_capacity);
            if (batches.len == 0) {
                return;
            }
            const r = &self.resources;
            buffer.push(.{ .bind_group_set = .{ .slot = 0, .id = r.frame_group } });
            buffer.push(.{ .vertex_buffer_set = .{
                .slot = 0,
                .buffer = r.unit_buffer,
                .offset = 0,
            } });
            var type_bound: ?u8 = null;
            var group_bound: ?u16 = null;
            for (batches) |batch| {
                assert(batch.type_id < R.count);
                assert(batch.count != 0);
                if (type_bound != batch.type_id) {
                    buffer.push(.{ .pipeline_set = .{ .id = r.pipelines[batch.type_id] } });
                    buffer.push(.{ .vertex_buffer_set = .{
                        .slot = 1,
                        .buffer = r.instance_buffers[batch.type_id],
                        .offset = 0,
                    } });
                    type_bound = batch.type_id;
                }
                if (R.textured[batch.type_id]) {
                    const group = r.texture_groups[@backingInt(batch.texture)];
                    if (group_bound != group) {
                        buffer.push(.{ .bind_group_set = .{ .slot = 1, .id = group } });
                        group_bound = group;
                    }
                }
                buffer.push(.{ .draw = .{
                    .vertex_count = draw.vertex_count,
                    .instance_count = batch.count,
                    .first_vertex = 0,
                    .first_instance = batch.first,
                } });
            }
        }
    };
}

fn Shadow(comptime T: type, comptime cap: u32) type {
    return struct {
        items: [cap]T,
        count: u32,
        revision: u64,
        /// The records the last upload found changed; every other record equals the last
        /// frame's at the same index, so its tile key is reused (module guide, section 4a).
        changed: draw.Range,
        /// Each record's tile key from the last frame that hashed it; meaningful while
        /// `Renderer.keys_valid`.
        keys: [cap]u64,
    };
}

/// True when `[first, end)` overlaps `range`.
fn in_range(range: draw.Range, first: u32, end: u32) bool {
    assert(first <= end);
    assert(range.first <= range.end);
    return first < range.end and range.first < end;
}

fn unit_layout() commands.VertexBuffer {
    var attributes = std.mem.zeroes([commands.attribute_cap]commands.VertexAttribute);
    attributes[0] = .{ .location = 0, .format = .float32x2, .offset = 0 };
    return .{
        .stride = 2 * @sizeOf(f32),
        .step = .vertex,
        .attribute_count = 1,
        .attributes = attributes,
    };
}

comptime {
    assert(@sizeOf(Uniform) == draw.uniform_bytes);
    assert(@offsetOf(Uniform, "time") == draw.time_offset);
    assert(@offsetOf(Uniform, "theme") == draw.theme_offset);
    assert(draw.quad_bytes == draw.vertex_count * 2 * @sizeOf(f32));
    assert(batch_op_cap == 4);
}

const testing = std.testing;
const text = @import("../text.zig");

/// The op codes recorded in `buffer`, in order.
pub fn codes(buffer: *const commands.CommandBuffer, out: []commands.Code) []commands.Code {
    var reader = buffer.reader();
    var count: usize = 0;
    while (reader.next()) |op| {
        assert(count < out.len);
        out[count] = std.meta.activeTag(op);
        count += 1;
    }
    return out[0..count];
}

/// Every `buffer_write` in `buffer`, in order.
pub fn writes(
    buffer: *const commands.CommandBuffer,
    out: []commands.BufferWrite,
) []commands.BufferWrite {
    var reader = buffer.reader();
    var count: usize = 0;
    while (reader.next()) |op| {
        switch (op) {
            .buffer_write => |write| {
                assert(count < out.len);
                out[count] = write;
                count += 1;
            },
            else => {},
        }
    }
    return out[0..count];
}

const test_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 8 },
    .{ .type = types.Arc, .cap = 8 },
    .{ .type = types.Glyph, .cap = 16 },
};

const TestContext = draw.Context(&test_draw, 8, 0);
const TestRenderer = Renderer(TestContext);

const Fixture = struct {
    var context: TestContext = undefined;
    var renderer: TestRenderer = undefined;
    var buffer: commands.CommandBuffer = undefined;

    fn setup_only() void {
        context.init();
        renderer.init();
        buffer = .init();
        renderer.setup(&buffer, &context);
    }

    fn start() void {
        setup_only();
        buffer.reset();
    }

    /// Records one 1280 by 720 logical frame at `scale_120`.
    fn record(scale_120: u32) void {
        buffer.reset();
        renderer.frame(&buffer, &context, .{
            .width_logical = 1280,
            .height_logical = 720,
            .width_px = 1280 * scale_120 / 120,
            .height_px = 720 * scale_120 / 120,
            .scale_120 = scale_120,
        }, 0);
    }
};

fn face(x: f32) types.Box {
    return .{
        .rect = .{ x, 0, 10, 10 },
        .clip = .{ 0, 0, 100, 100 },
        .fill = .{ 1, 1, 1, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    };
}

fn ring(x: f32, hover: f32) types.Arc {
    return .{
        .rect = .{ x, 0, 56, 56 },
        .clip = .{ 0, 0, 100, 100 },
        .color = .{ 1, 1, 1, 1 },
        .thickness = 4,
        .sweep = 1,
        .hover = hover,
        .pad = 0,
    };
}

fn glyph(x: f32) types.Glyph {
    return .{
        .rect = .{ x, 0, 4, 8 },
        .clip = .{ 0, 0, 100, 100 },
        .uv = .{ 0, 0, 1, 1 },
        .color = .{ 1, 1, 1, 1 },
    };
}

/// Box, glyph, box, glyph, then an arc: the scene most tests below record.
fn scene(hover: f32) !void {
    const cx = &Fixture.context;
    cx.text.scale_120 = 120;
    cx.reset();
    try cx.append(types.Box, null, face(0));
    try cx.append(types.Glyph, .atlas, glyph(0));
    try cx.append(types.Box, null, face(20));
    try cx.append(types.Glyph, .atlas, glyph(20));
    try cx.append(types.Arc, null, ring(0, hover));
    try cx.append(types.Arc, null, ring(60, 0));
}

// Locks the setup recording: the frame layout and the two texture layouts, then per type a
// shader (labelled), a buffer, and a pipeline; the atlas texture and its bind group last,
// after the unit quad upload, with no texels: the glyph cache uploads what it rasterizes in
// later frames.
test "setup records one shader, buffer, and pipeline per type and the atlas" {
    Fixture.setup_only();
    var storage: [64]commands.Code = undefined;
    const expected = [_]commands.Code{
        .layout_create,     .layout_create,  .layout_create,
        .buffer_create,     .buffer_create,  .sampler_create,
        .bind_group_create, .shader_create,  .buffer_create,
        .pipeline_create,   .shader_create,  .buffer_create,
        .pipeline_create,   .shader_create,  .buffer_create,
        .pipeline_create,   .shader_create,  .pipeline_create,
        .buffer_write,      .texture_create, .bind_group_create,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&Fixture.buffer, &storage));
    var reader = Fixture.buffer.reader();
    var pipelines: u32 = 0;
    while (reader.next()) |op| {
        switch (op) {
            .shader_create => |shader| {
                try testing.expect(std.mem.endsWith(u8, shader.label.slice(), "Box") or
                    std.mem.endsWith(u8, shader.label.slice(), "Arc") or
                    std.mem.endsWith(u8, shader.label.slice(), "Glyph") or
                    std.mem.eql(u8, shader.label.slice(), "clear"));
            },
            .pipeline_create => |pipeline| {
                // Box: 80 bytes in five groups; the glyph pipeline also binds the texture.
                if (pipelines == 0) {
                    try testing.expectEqual(@as(u16, 80), pipeline.vertex[1].stride);
                    try testing.expectEqual(@as(u8, 5), pipeline.vertex[1].attribute_count);
                    try testing.expectEqual(@as(u8, 1), pipeline.layout_count);
                }
                if (pipelines == 2) {
                    try testing.expectEqual(@as(u8, 2), pipeline.layout_count);
                }
                // The clear pipeline (module guide, section 4a): no bindings, no blending.
                if (pipelines == 3) {
                    try testing.expectEqual(@as(u8, 0), pipeline.layout_count);
                    try testing.expectEqual(@as(u8, 1), pipeline.buffer_count);
                    try testing.expectEqual(commands.Blend.none, pipeline.blend);
                }
                pipelines += 1;
            },
            .texture_create => |texture| {
                try testing.expectEqual(commands.TextureFormat.r8unorm, texture.format);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 4), pipelines);
    try testing.expect(Fixture.renderer.ready);
}

// Locks the first frame: the uniform and three pool writes, then three batches with the
// frame group and unit quad bound once and each pipeline set once.
test "the first frame writes every pool and draws one call per batch" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    var storage: [64]commands.Code = undefined;
    const expected = [_]commands.Code{
        .buffer_write,      .buffer_write, .buffer_write,
        .buffer_write,      .pass_begin,   .bind_group_set,
        .vertex_buffer_set, .pipeline_set, .vertex_buffer_set,
        .draw,              .pipeline_set, .vertex_buffer_set,
        .bind_group_set,    .draw,         .pipeline_set,
        .vertex_buffer_set, .draw,         .pass_end_present,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&Fixture.buffer, &storage));
    var write_storage: [8]commands.BufferWrite = undefined;
    const recorded = writes(&Fixture.buffer, &write_storage);
    const r = &Fixture.renderer.resources;
    try testing.expectEqual(r.uniform_buffer, recorded[0].id);
    try testing.expectEqual(draw.uniform_bytes, recorded[0].data.len);
    try testing.expectEqual(r.instance_buffers[0], recorded[1].id);
    try testing.expectEqual(@as(u32, 2 * 80), recorded[1].data.len);
    try testing.expectEqual(r.instance_buffers[2], recorded[3].id);
}

// Locks the idle paths: a frame recorded again without a draw and an identical rebuild write
// nothing and, with no tile changed, present nothing (module guide, section 4a); with the
// cache off the same frame is a direct pass again.
test "an undrawn frame and an identical rebuild write nothing" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    try testing.expectEqual(Kind.direct, Fixture.renderer.last);
    Fixture.record(120);
    try testing.expectEqual(@as(u32, 0), Fixture.buffer.count);
    try testing.expectEqual(Kind.skipped, Fixture.renderer.last);
    try scene(0);
    Fixture.record(120);
    try testing.expectEqual(@as(u32, 0), Fixture.buffer.count);
    Fixture.renderer.cache = false;
    Fixture.record(120);
    var write_storage: [8]commands.BufferWrite = undefined;
    try testing.expectEqual(@as(usize, 0), writes(&Fixture.buffer, &write_storage).len);
    var reader = Fixture.buffer.reader();
    try testing.expectEqual(@as(u32, 1280), reader.next().?.pass_begin.width_px);
    try testing.expectEqual(Kind.direct, Fixture.renderer.last);
}

/// The first op of `kind` in the fixture's last recording.
fn first_op(comptime kind: commands.Code) ?@FieldType(commands.Op, @tagName(kind)) {
    var reader = Fixture.buffer.reader();
    while (reader.next()) |op| {
        if (op == kind) return @field(op, @tagName(kind));
    }
    return null;
}

// Locks the pixel cache's frames (module guide, section 4a) on a 1280 by 720 window of 240
// tiles: a hover that changes one ring repaints the kept target in full the first time
// (creating it) and then only the ring's tile under a scissor, after the clear pipeline; a
// present with nothing changed copies the kept target; a scale change goes direct.
test "a small change repaints one tile of the kept target" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    try testing.expectEqual(Kind.direct, Fixture.renderer.last);
    try scene(0.18);
    Fixture.record(120);
    try testing.expectEqual(Kind.full, Fixture.renderer.last);
    const kept = Fixture.renderer.kept.?;
    try testing.expectEqual(@as(u32, 1280), first_op(.target_create).?.width);
    try testing.expectEqual(kept, first_op(.pass_begin).?.target);
    try testing.expectEqual(commands.LoadOp.clear, first_op(.pass_begin).?.load);
    try testing.expectEqual(kept, first_op(.present_copy).?.target);
    try testing.expectEqual(@as(?commands.ScissorSet, null), first_op(.scissor_set));
    try scene(0);
    Fixture.record(120);
    try testing.expectEqual(Kind.cached, Fixture.renderer.last);
    try testing.expectEqual(@as(?commands.TargetCreate, null), first_op(.target_create));
    try testing.expectEqual(commands.LoadOp.load, first_op(.pass_begin).?.load);
    const scissor: commands.ScissorSet = .{ .x = 0, .y = 0, .width = 64, .height = 64 };
    try testing.expectEqual(scissor, first_op(.scissor_set).?);
    const clear = Fixture.renderer.resources.clear_pipeline;
    try testing.expectEqual(clear, first_op(.pipeline_set).?.id);
    try testing.expectEqual(@as(u32, 1), first_op(.draw).?.instance_count);
    var storage: [64]commands.Code = undefined;
    const recorded = codes(&Fixture.buffer, &storage);
    try testing.expectEqual(commands.Code.pass_end, recorded[recorded.len - 2]);
    try testing.expectEqual(commands.Code.present_copy, recorded[recorded.len - 1]);
    Fixture.renderer.present_next = true;
    Fixture.record(120);
    try testing.expectEqual(Kind.copied, Fixture.renderer.last);
    try testing.expectEqual(@as(u32, 1), Fixture.buffer.count);
    try scene(0);
    Fixture.record(180);
    try testing.expectEqual(Kind.direct, Fixture.renderer.last);
    try testing.expect(!Fixture.renderer.kept_valid);
}

// Locks the unchanged fast path (module guide, section 4b): an undrawn frame repeats the last
// frame's tiles without hashing, while a texture create or write on an otherwise undrawn frame
// hashes again; a registry without animated types never animates or writes time.
test "an undrawn frame repeats its tiles unless a texture changed" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    try testing.expect(Fixture.renderer.hashed);
    Fixture.record(120);
    try testing.expect(!Fixture.renderer.hashed);
    try testing.expectEqual(Kind.skipped, Fixture.renderer.last);
    const cx = &Fixture.context;
    const id = cx.textures.create(.rgba8, 2, 2);
    Fixture.record(120);
    try testing.expect(Fixture.renderer.hashed);
    const texels: [16]u8 = @splat(0xFF);
    cx.textures.write(id, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, &texels);
    Fixture.record(120);
    try testing.expect(Fixture.renderer.hashed);
    try testing.expectEqual(Kind.skipped, Fixture.renderer.last);
    Fixture.record(120);
    try testing.expect(!Fixture.renderer.hashed);
    try testing.expect(!Fixture.renderer.animating);
    try testing.expectEqual(@as(f32, 0), Fixture.renderer.uniform.time[0]);
}

/// An animated test type: its alpha follows `time_pulse`.
const Pulse = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const animated = true;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(1.0, 1.0, 1.0, time_pulse(1.0));
        \\}
        \\
    ;
};

const animated_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 8 },
    .{ .type = Pulse, .cap = 4 },
};

const AnimatedContext = draw.Context(&animated_draw, 8, 0);

const Animated = struct {
    var context: AnimatedContext = undefined;
    var renderer: Renderer(AnimatedContext) = undefined;
    var buffer: commands.CommandBuffer = undefined;

    fn start() void {
        context.init();
        renderer.init();
        buffer = .init();
        renderer.setup(&buffer, &context);
    }

    /// A box in tile 0 and, when `pulsing`, a pulse in tile 4 (x 256 to 320).
    fn scene(pulsing: bool) !void {
        context.text.scale_120 = 120;
        context.reset();
        try context.append(types.Box, null, face(0));
        if (pulsing) {
            try context.append(Pulse, null, .{
                .rect = .{ 290, 10, 10, 10 },
                .clip = .{ 0, 0, 1280, 720 },
            });
        }
    }

    /// Records one 1280 by 720 frame at scale 1 and animation time `time_s`.
    fn record(time_s: f32) void {
        buffer.reset();
        renderer.frame(&buffer, &context, .{
            .width_logical = 1280,
            .height_logical = 720,
            .width_px = 1280,
            .height_px = 720,
            .scale_120 = 120,
        }, time_s);
    }

    /// The first op of `kind` in the last recording.
    fn first(comptime kind: commands.Code) ?@FieldType(commands.Op, @tagName(kind)) {
        var reader = buffer.reader();
        while (reader.next()) |op| {
            if (op == kind) return @field(op, @tagName(kind));
        }
        return null;
    }
};

// Locks the animation-only frame (module guide, section 4b): with a pulse on screen and no
// draw, a frame writes 16 bytes of time at offset 64, hashes nothing, and repaints the pulse's
// tile under a scissor; a frame at the same time writes no time but still repaints; dropping
// the pulse repaints its tile once and stops animating, and the next frame is skipped.
test "an animation-only frame writes the time and repaints the animated tiles" {
    Animated.start();
    try Animated.scene(true);
    Animated.record(0);
    try testing.expectEqual(Kind.direct, Animated.renderer.last);
    try testing.expect(Animated.renderer.animating);
    try testing.expect(Animated.renderer.hashed);
    Animated.record(0.5);
    try testing.expectEqual(Kind.full, Animated.renderer.last);
    try testing.expect(!Animated.renderer.hashed);
    Animated.record(1.0);
    try testing.expectEqual(Kind.cached, Animated.renderer.last);
    try testing.expect(!Animated.renderer.hashed);
    var write_storage: [8]commands.BufferWrite = undefined;
    const recorded = writes(&Animated.buffer, &write_storage);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqual(Animated.renderer.resources.uniform_buffer, recorded[0].id);
    try testing.expectEqual(draw.time_offset, recorded[0].offset);
    try testing.expectEqual(@as(usize, draw.time_bytes), recorded[0].data.len);
    try testing.expectEqual(@as(f32, 1.0), Animated.renderer.uniform.time[0]);
    var storage: [64]commands.Code = undefined;
    const ops = codes(&Animated.buffer, &storage);
    try testing.expectEqual(commands.Code.buffer_write, ops[0]);
    try testing.expectEqual(commands.Code.pass_begin, ops[1]);
    const scissor: commands.ScissorSet = .{ .x = 256, .y = 0, .width = 64, .height = 64 };
    try testing.expectEqual(scissor, Animated.first(.scissor_set).?);
    Animated.record(1.0);
    try testing.expectEqual(Kind.cached, Animated.renderer.last);
    try testing.expectEqual(@as(usize, 0), writes(&Animated.buffer, &write_storage).len);
    try Animated.scene(false);
    Animated.record(1.0);
    try testing.expect(Animated.renderer.hashed);
    try testing.expect(!Animated.renderer.animating);
    try testing.expectEqual(Kind.cached, Animated.renderer.last);
    try testing.expectEqual(scissor, Animated.first(.scissor_set).?);
    Animated.record(2.0);
    try testing.expectEqual(Kind.skipped, Animated.renderer.last);
    try testing.expectEqual(@as(u32, 0), Animated.buffer.count);
    try testing.expect(!Animated.renderer.hashed);
}

// Locks animation with the cache off: every frame is direct, and `animating` follows whether
// the finalized frame holds a pulse.
test "with the cache off, animating follows the animated batches" {
    Animated.start();
    Animated.renderer.cache = false;
    try Animated.scene(true);
    Animated.record(0);
    try testing.expect(Animated.renderer.animating);
    Animated.record(0.25);
    try testing.expectEqual(Kind.direct, Animated.renderer.last);
    try testing.expectEqual(draw.time_offset, Animated.first(.buffer_write).?.offset);
    try Animated.scene(false);
    Animated.record(0.25);
    try testing.expect(!Animated.renderer.animating);
}

/// An unfilterable, multiplying test type.
const Heat = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = .r32float;
    pub const blend: draw.Blend = .multiply;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(sample_texture(px.local / px.size).rrr, 1.0);
        \\}
        \\
    ;
};

const data_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 4 },
    .{ .type = Heat, .cap = 4 },
    .{ .type = types.Image, .cap = 4 },
};

const DataContext = draw.Context(&data_draw, 8, 0);

// Locks samplers, layouts, and blends (module guide, section 2): each pipeline takes its
// type's blend and class layout; a nearest, repeating mode gets one sampler, created in the
// stream that first needs it and shared by the second texture of that mode; each bind group
// takes its texture's class layout and mode's sampler; the default mode is the setup sampler.
test "textures get their class layout and their mode's sampler, created once" {
    const static = struct {
        var context: DataContext = undefined;
        var renderer: Renderer(DataContext) = undefined;
        var buffer: commands.CommandBuffer = undefined;
    };
    const cx = &static.context;
    const renderer = &static.renderer;
    cx.init();
    renderer.init();
    static.buffer = .init();
    renderer.setup(&static.buffer, cx);
    const r = &renderer.resources;
    var reader = static.buffer.reader();
    while (reader.next()) |op| {
        switch (op) {
            .pipeline_create => |pipeline| if (pipeline.id == r.pipelines[1]) {
                try testing.expectEqual(commands.Blend.multiply, pipeline.blend);
                try testing.expectEqual(r.texture_layouts[1], pipeline.layouts[1]);
            } else if (pipeline.id == r.pipelines[2]) {
                try testing.expectEqual(commands.Blend.alpha, pipeline.blend);
                try testing.expectEqual(r.texture_layouts[0], pipeline.layouts[1]);
            },
            .layout_create => |layout| if (layout.id == r.texture_layouts[1]) {
                try testing.expectEqual(commands.BindingKind.texture_unfilterable, layout.entries[0].kind);
                try testing.expectEqual(commands.BindingKind.sampler_non_filtering, layout.entries[1].kind);
            },
            else => {},
        }
    }
    const nearest: textures.Sampling = .{ .filter = .nearest, .address_u = .repeat };
    _ = cx.textures.create_sampled(.r32float, 8, 4, nearest);
    _ = cx.textures.create_sampled(.r32float, 4, 4, nearest);
    _ = cx.textures.create(.rgba8, 2, 2);
    static.buffer.reset();
    renderer.frame(&static.buffer, cx, .{
        .width_logical = 64,
        .height_logical = 64,
        .width_px = 64,
        .height_px = 64,
        .scale_120 = 120,
    }, 0);
    var storage: [64]commands.Code = undefined;
    const expected = [_]commands.Code{
        .buffer_write,   .texture_create,    .sampler_create, .bind_group_create,
        .texture_create, .bind_group_create, .texture_create, .bind_group_create,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&static.buffer, &storage)[0..8]);
    const shared = r.samplers[nearest.index()].?;
    try testing.expect(shared != r.samplers[(textures.Sampling{}).index()].?);
    reader = static.buffer.reader();
    var groups: u32 = 0;
    while (reader.next()) |op| {
        switch (op) {
            .sampler_create => |sampler| {
                try testing.expectEqual(shared, sampler.id);
                try testing.expectEqual(commands.Filter.nearest, sampler.filter);
                try testing.expectEqual(commands.Address.repeat, sampler.address_u);
                try testing.expectEqual(commands.Address.clamp, sampler.address_v);
            },
            .bind_group_create => |group| {
                const heat = groups < 2;
                const class: u32 = if (heat) 1 else 0;
                const sampler = if (heat) shared else r.samplers[(textures.Sampling{}).index()].?;
                try testing.expectEqual(r.texture_layouts[class], group.layout);
                try testing.expectEqual(sampler, group.entries[1].resource);
                groups += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 3), groups);
}

// Locks the bound that keeps the worst cached frame in one command buffer: an app of few
// batches gets every rect, the default `batch_cap` of 256 fewer, and never zero.
test "the rect count fits the command buffer" {
    try testing.expectEqual(tiles_module.rect_cap, rects_max(5, 16));
    try testing.expect(rects_max(16, 256) >= 1);
    try testing.expect(rects_max(16, 256) < tiles_module.rect_cap);
    try testing.expect(frame_bytes_max(16, 256) <= commands.capacity);
}

/// Two boxes, an arc, and a text label drawn through the glyph cache at `scale_120`, the way
/// a host draws when the cache owes a draw.
fn text_scene(scale_120: u32) void {
    const cx = &Fixture.context;
    cx.text.scale_120 = scale_120;
    cx.reset();
    cx.append(types.Box, null, face(0)) catch unreachable;
    cx.append(types.Box, null, face(20)) catch unreachable;
    cx.append(types.Arc, null, ring(0, 0)) catch unreachable;
    const style: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
    const rect: draw.Rect = .{ .x = 3, .y = 50, .width = 90, .height = 24 };
    const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    text.place(cx, style, "Hi", rect, clip, .{
        .align_x = .start,
        .align_y = .center,
        .ellipsis = false,
    });
    assert(cx.overflow_count == 0);
}

// Locks the scale-change frame: the scene is redrawn at 1.5, the frame writes the uniform,
// one atlas rectangle, and the glyph range, and the box and arc pools write nothing.
test "a scale change writes the uniform, the atlas, and glyphs only" {
    Fixture.start();
    text_scene(120);
    Fixture.record(120);
    try testing.expect(!Fixture.context.text.owes_draw(120));
    try testing.expect(Fixture.context.text.owes_draw(180));
    text_scene(180);
    Fixture.record(180);
    var write_storage: [8]commands.BufferWrite = undefined;
    const recorded = writes(&Fixture.buffer, &write_storage);
    const r = &Fixture.renderer.resources;
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqual(r.uniform_buffer, recorded[0].id);
    try testing.expectEqual(r.instance_buffers[2], recorded[1].id);
    var atlas_writes: u32 = 0;
    var reader = Fixture.buffer.reader();
    while (reader.next()) |op| {
        switch (op) {
            .texture_write => |write| {
                try testing.expectEqual(r.textures[0], write.id);
                try testing.expectEqual(@as(u32, 1024), write.bytes_per_row);
                atlas_writes += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 1), atlas_writes);
}

// Locks per-pool uploads: a hover that changes one arc writes that one record of the arc pool
// and nothing in the box or glyph pools.
test "changing one pool writes only that pool" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    try scene(0.18);
    Fixture.record(120);
    var write_storage: [8]commands.BufferWrite = undefined;
    const recorded = writes(&Fixture.buffer, &write_storage);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqual(Fixture.renderer.resources.instance_buffers[1], recorded[0].id);
    try testing.expectEqual(@as(u32, 0), recorded[0].offset);
    try testing.expectEqual(@as(u32, @sizeOf(types.Arc)), recorded[0].data.len);
}

// Locks the worst-case bound the comptime check relies on.
test "the frame op bound covers every batch" {
    try testing.expect(TestRenderer.op_cap >= 1 + 3 + 1 + 3 + 8 * 4 + 1);
    try testing.expect(frame_bytes_max(16, 256) <= commands.capacity);
}

const path_draw = [_]registry.DrawType{
    .{ .type = types.Box, .cap = 8 },
    .{ .type = types.Path, .cap = 32 },
};

const PathContext = draw.Context(&path_draw, 8, 256);

const PathFixture = struct {
    var context: PathContext = undefined;
    var renderer: Renderer(PathContext) = undefined;
    var buffer: commands.CommandBuffer = undefined;

    fn record() void {
        buffer.reset();
        renderer.frame(&buffer, &context, .{
            .width_logical = 1280,
            .height_logical = 720,
            .width_px = 1280,
            .height_px = 720,
            .scale_120 = 120,
        }, 0);
    }

    /// One sagging cable at `hover`, ending at `end_x`.
    fn cable(hover: f32, end_x: f32) void {
        const cx = &context;
        cx.text.scale_120 = 120;
        cx.reset();
        const color: [4]f32 = .{ 1, 0.5, 0, 0.85 };
        const stroke: draw.path.Stroke = .{ .color = color, .width = 4, .hover = hover };
        const clip: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 1280, .y1 = 720 };
        const control = [4]draw.Point{ .{ 100, 100 }, .{ 300, 260 }, .{ 500, 260 }, .{
            end_x,
            100,
        } };
        _ = draw.path.cubic(cx, control, stroke, clip).?;
    }
};

// Locks the point buffer's setup: a registry with a `reads_points` type creates a storage
// buffer after the uniform, gives the frame layout a read-only storage entry at binding 1 for
// the vertex and fragment stages, and binds the buffer there, so it is set once per pass with
// group 0.
test "a points type adds the point buffer to the frame group" {
    PathFixture.context.init();
    PathFixture.renderer.init();
    PathFixture.buffer = .init();
    PathFixture.renderer.setup(&PathFixture.buffer, &PathFixture.context);
    var storage: [64]commands.Code = undefined;
    const expected = [_]commands.Code{
        .layout_create,     .layout_create,     .layout_create,
        .buffer_create,     .buffer_create,     .buffer_create,
        .sampler_create,    .bind_group_create, .shader_create,
        .buffer_create,     .pipeline_create,   .shader_create,
        .buffer_create,     .pipeline_create,   .shader_create,
        .pipeline_create,   .buffer_write,      .texture_create,
        .bind_group_create,
    };
    const recorded = codes(&PathFixture.buffer, &storage);
    try testing.expectEqualSlices(commands.Code, &expected, recorded);
    const r = &PathFixture.renderer.resources;
    var reader = PathFixture.buffer.reader();
    var shaders: u32 = 0;
    while (reader.next()) |op| {
        switch (op) {
            .layout_create => |layout| if (layout.id == r.frame_layout) {
                try testing.expectEqual(@as(u16, 2), layout.entry_count);
                try testing.expectEqual(commands.BindingKind.storage_read, layout.entries[1].kind);
                const both = commands.stage_vertex | commands.stage_fragment;
                try testing.expectEqual(both, layout.entries[1].visibility);
            },
            .buffer_create => |created| if (created.id == r.points_buffer) {
                const usage = commands.usage_storage | commands.usage_copy_dst;
                try testing.expectEqual(usage, created.usage);
                try testing.expectEqual(@as(u32, 256 * 8), created.size);
            },
            .bind_group_create => |group| if (group.id == r.frame_group) {
                try testing.expectEqual(@as(u16, 2), group.entry_count);
                try testing.expectEqual(r.points_buffer, group.entries[1].resource);
            },
            .shader_create => |shader| {
                const declares = std.mem.find(u8, shader.source.slice(), "var<storage") != null;
                try testing.expectEqual(shaders == 1, declares);
                shaders += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 3), shaders);
}

// Locks the point uploads: the first frame writes the Path records and the points, an
// identical rebuild writes nothing, a hover recolor writes Path records only, and a moved end
// point writes the changed points.
test "points upload by range and a recolor writes no points" {
    PathFixture.context.init();
    PathFixture.renderer.init();
    PathFixture.buffer = .init();
    PathFixture.renderer.setup(&PathFixture.buffer, &PathFixture.context);
    const r = &PathFixture.renderer.resources;
    var write_storage: [8]commands.BufferWrite = undefined;
    PathFixture.cable(0, 700);
    PathFixture.record();
    const first = writes(&PathFixture.buffer, &write_storage);
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expectEqual(r.instance_buffers[1], first[1].id);
    try testing.expectEqual(r.points_buffer, first[2].id);
    const point_bytes = PathFixture.context.point_count * @sizeOf(draw.Point);
    try testing.expectEqual(point_bytes, first[2].data.len);
    PathFixture.cable(0, 700);
    PathFixture.record();
    try testing.expectEqual(@as(usize, 0), writes(&PathFixture.buffer, &write_storage).len);
    PathFixture.cable(0.18, 700);
    PathFixture.record();
    const hover = writes(&PathFixture.buffer, &write_storage);
    try testing.expectEqual(@as(usize, 1), hover.len);
    try testing.expectEqual(r.instance_buffers[1], hover[0].id);
    PathFixture.cable(0.18, 720);
    PathFixture.record();
    const moved = writes(&PathFixture.buffer, &write_storage);
    try testing.expectEqual(r.points_buffer, moved[moved.len - 1].id);
}

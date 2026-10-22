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
//! uniform, shared by every pipeline; group 1 is a texture and the shared clamping linear
//! sampler, for textured types only, with one bind group per texture.
//!
//! ## 3. Frame Shape
//! ```text
//! buffer_write uniform            only when the device size or scale changed (or first frame)
//! texture_create, bind_group_create, texture_write   whatever `Textures` queued, after the
//!                                 glyph cache queued its dirty atlas rectangle (one write)
//! buffer_write pool[i] [range]    per pool whose revision moved and whose records changed
//! pass_begin
//!   bind_group_set 0, vertex_buffer_set 0                   once, when any batch exists
//!   per batch, in order:
//!     pipeline_set, vertex_buffer_set 1    only when the type differs from the last batch
//!     bind_group_set 1                     only when a textured batch changes texture
//!     draw (6 vertices, count instances, first_instance = batch.first)
//! pass_end_present
//! ```
//! `frame_op_cap` and `frame_bytes_max` bound this at compile time from the type count and
//! `batch_cap`; `app.check` rejects a configuration whose worst frame would not fit one
//! `commands.CommandBuffer`.
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
//! construction. The counting sort is stable by key and overlays sort last, so content that
//! appears on a higher layer lands at the tail of its pool and keeps ranges small.
//!
//! A scale change redraws the scene (glyphs are rasterized and snapped per device scale; see
//! `text/cache.zig`), but only glyph records move: the box and arc pools compare equal and
//! write nothing, and the frame writes the uniform, the new atlas rectangle, and the glyph
//! range. Test "a scale change writes the uniform, the atlas, and glyphs only" locks it.
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

/// The frame uniform: projection followed by the theme, `draw.uniform_bytes` in all.
pub const Uniform = extern struct {
    ortho: [16]f32,
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

/// Upper bound on the ops `frame` records; see the module guide's frame shape.
pub fn frame_op_cap(type_count: u32, batch_cap: u32) u32 {
    const texture_ops = 2 * textures.texture_cap + textures.write_cap;
    return 1 + texture_ops + type_count + 3 + batch_cap * batch_op_cap + 1;
}

/// Upper bound on the bytes `frame` records, for the same shape as `frame_op_cap`.
pub fn frame_bytes_max(type_count: u32, batch_cap: u32) u32 {
    const texture_bytes = textures.texture_cap *
        (op_bytes(commands.TextureCreate) + op_bytes(commands.BindGroupCreate)) +
        textures.write_cap * op_bytes(commands.TextureWrite);
    const pass_bytes = op_bytes(commands.PassBegin) + op_bytes(commands.BindGroupSet) +
        op_bytes(commands.VertexBufferSet) + op_bytes(commands.PassEndPresent);
    const per_batch = op_bytes(commands.PipelineSet) + op_bytes(commands.VertexBufferSet) +
        op_bytes(commands.BindGroupSet) + op_bytes(commands.Draw);
    return (1 + type_count) * op_bytes(commands.BufferWrite) + texture_bytes + pass_bytes +
        batch_cap * per_batch;
}

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
        uniform: Uniform,
        /// Device size and scale the uploaded uniform was built for; 0 before the first frame.
        width_px: u32,
        height_px: u32,
        scale_120: u32,
        ready: bool,

        /// Most ops one `frame` records.
        pub const op_cap: u32 = frame_op_cap(R.count, Cx.batch_capacity);

        /// The ids `setup` allocated.
        pub const Resources = struct {
            shaders: [R.count]u16,
            pipelines: [R.count]u16,
            instance_buffers: [R.count]u16,
            frame_layout: u16,
            texture_layout: u16,
            unit_buffer: u16,
            uniform_buffer: u16,
            sampler: u16,
            frame_group: u16,
            textures: [textures.texture_cap]u16,
            texture_groups: [textures.texture_cap]u16,
        };

        /// Out-pointer init so a static renderer needs no stack copy.
        pub fn init(self: *Self) void {
            self.ids = .init();
            self.uniform = .{ .ortho = undefined, .theme = theme.chrome };
            self.width_px = 0;
            self.height_px = 0;
            self.scale_120 = 0;
            self.ready = false;
            inline for (0..R.count) |index| {
                self.shadows[index].count = 0;
                self.shadows[index].revision = 0;
            }
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
            r.sampler = self.ids.take(.sampler);
            buffer.push(.{ .sampler_create = .{ .id = r.sampler, .filter = .linear } });
            r.frame_group = self.ids.take(.bind_group);
            var frame_bindings = std.mem.zeroes(BindGroupEntries);
            frame_bindings[0] = .{ .binding = 0, .resource = r.uniform_buffer };
            buffer.push(.{ .bind_group_create = .{
                .id = r.frame_group,
                .layout = r.frame_layout,
                .entry_count = 1,
                .entries = frame_bindings,
            } });
            inline for (0..R.count) |index| {
                self.setup_type(buffer, index);
            }
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
            buffer.push(.{ .layout_create = .{
                .id = r.frame_layout,
                .entry_count = 1,
                .entries = frame_entries,
            } });
            r.texture_layout = self.ids.take(.layout);
            var texture_entries = std.mem.zeroes(LayoutEntries);
            const fragment = commands.stage_fragment;
            texture_entries[0] = .{ .binding = 0, .visibility = fragment, .kind = .texture };
            texture_entries[1] = .{ .binding = 1, .visibility = fragment, .kind = .sampler };
            buffer.push(.{ .layout_create = .{
                .id = r.texture_layout,
                .entry_count = 2,
                .entries = texture_entries,
            } });
            assert(r.frame_layout != r.texture_layout);
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
                .blend = .alpha,
                .layouts = .{ r.frame_layout, r.texture_layout, 0, 0 },
                .vertex = .{ unit_layout(), R.vertex_layout(index) },
            } });
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
                bindings[1] = .{ .binding = 1, .resource = r.sampler };
                buffer.push(.{ .bind_group_create = .{
                    .id = r.texture_groups[index],
                    .layout = r.texture_layout,
                    .entry_count = 2,
                    .entries = bindings,
                } });
            }
            for (table.writes[0..table.write_count]) |write| {
                buffer.push(.{ .texture_write = .{
                    .id = r.textures[@intFromEnum(write.id)],
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
        /// and batching it if it changed) and updates the shadows. See the module guide.
        pub fn frame(
            self: *Self,
            buffer: *commands.CommandBuffer,
            cx: *Cx,
            size: Size,
        ) void {
            assert(self.ready);
            assert(buffer.len == 0);
            assert(size.width_px != 0);
            assert(size.height_px != 0);
            assert(size.width_logical != 0);
            assert(size.scale_120 != 0);
            if (self.uniform_dirty(size)) {
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
            cx.text.queue_upload(&cx.textures);
            self.flush_textures(buffer, &cx.textures);
            cx.finalize();
            inline for (0..R.count) |index| {
                self.upload_pool(buffer, index, &cx.pools[index]);
            }
            buffer.push(.{ .pass_begin = .{
                .width_px = size.width_px,
                .height_px = size.height_px,
                .clear = .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a },
            } });
            self.draw_batches(buffer, cx.batch_list());
            buffer.push(.{ .pass_end_present = .{} });
            assert(buffer.count <= op_cap);
            assert(buffer.len <= frame_bytes_max(R.count, Cx.batch_capacity));
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
            if (shadow.revision == pool.revision) {
                return;
            }
            const records = pool.items[0..pool.count];
            if (draw.dirty_range(T, shadow.items[0..shadow.count], records)) |range| {
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
                    const group = r.texture_groups[@intFromEnum(batch.texture)];
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
    };
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
    assert(@offsetOf(Uniform, "theme") == draw.matrix_bytes);
    assert(draw.quad_bytes == draw.vertex_count * 2 * @sizeOf(f32));
    assert(batch_op_cap == 4);
}

const testing = std.testing;
const text = @import("../text.zig");
const turtle = @import("../turtle.zig");

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

const TestContext = draw.Context(&test_draw, 8);
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
        });
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

// Locks the setup recording: per type a shader (labelled), a buffer, and a pipeline; the
// atlas texture and its bind group last, after the unit quad upload, with no texels: the
// glyph cache uploads what it rasterizes in later frames.
test "setup records one shader, buffer, and pipeline per type and the atlas" {
    Fixture.setup_only();
    var storage: [64]commands.Code = undefined;
    const expected = [_]commands.Code{
        .layout_create, .layout_create,  .buffer_create,
        .buffer_create, .sampler_create, .bind_group_create,
        .shader_create, .buffer_create,  .pipeline_create,
        .shader_create, .buffer_create,  .pipeline_create,
        .shader_create, .buffer_create,  .pipeline_create,
        .buffer_write,  .texture_create, .bind_group_create,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&Fixture.buffer, &storage));
    var reader = Fixture.buffer.reader();
    var pipelines: u32 = 0;
    while (reader.next()) |op| {
        switch (op) {
            .shader_create => |shader| {
                try testing.expect(std.mem.endsWith(u8, shader.label.slice(), "Box") or
                    std.mem.endsWith(u8, shader.label.slice(), "Arc") or
                    std.mem.endsWith(u8, shader.label.slice(), "Glyph"));
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
                pipelines += 1;
            },
            .texture_create => |texture| {
                try testing.expectEqual(commands.TextureFormat.r8unorm, texture.format);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 3), pipelines);
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
// nothing.
test "an undrawn frame and an identical rebuild write nothing" {
    Fixture.start();
    try scene(0);
    Fixture.record(120);
    Fixture.record(120);
    var write_storage: [8]commands.BufferWrite = undefined;
    try testing.expectEqual(@as(usize, 0), writes(&Fixture.buffer, &write_storage).len);
    var reader = Fixture.buffer.reader();
    try testing.expectEqual(@as(u32, 1280), reader.next().?.pass_begin.width_px);
    try scene(0);
    Fixture.record(120);
    try testing.expectEqual(@as(usize, 0), writes(&Fixture.buffer, &write_storage).len);
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
    const rect: turtle.Rect = .{ .x = 3, .y = 50, .width = 90, .height = 24 };
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
    try testing.expect(TestRenderer.op_cap >= 1 + 3 + 3 + 8 * 4 + 1);
    try testing.expect(frame_bytes_max(16, 256) <= commands.capacity);
}

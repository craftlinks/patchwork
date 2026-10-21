//! Records the quad and glyph passes as a GPU command stream.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Role
//! `Renderer` is the only code that knows what the GPU is asked to do. `setup` records every
//! long-lived resource once, right after the host creates its device: two shader modules, two
//! bind group layouts, four buffers, the atlas texture and sampler, two bind groups, two
//! pipelines, and the uploads of the unit quad and the atlas. `frame` records one frame:
//! the buffer writes `draw.UploadCursor` asks for, then one pass that draws faces and glyphs
//! back to front and presents. The hosts only replay the stream (`gpu/commands.zig`), so
//! this file is pure and every recording is unit tested without a GPU.
//!
//! ## 2. Descriptors From Zig Layouts
//! Vertex layouts are built from `@offsetOf` on `draw.Instance` and `font.Glyph`, so the
//! attribute offsets cannot drift from the records. Buffer 0 is the unit quad stepped per
//! vertex (location 0, `float32x2`); buffer 1 is the record list stepped per instance
//! (locations 1 to 4, one `float32x4` each). Group 0 is the frame uniform, shared by both
//! pipelines; group 1 is the atlas texture and its linear sampler, glyph pipeline only.
//!
//! ## 3. Frame Shape
//! ```text
//! buffer_write uniform           only when the logical size changed (or first frame)
//! buffer_write instances [range] only the records that changed (draw.dirty_range)
//! buffer_write glyphs    [range] same
//! pass_begin
//!   pipeline_set quad  bind_group_set 0  vertex_buffer_set 0, 1  draw    when faces exist
//!   pipeline_set glyph bind_group_set 0, 1  vertex_buffer_set 0, 1  draw when glyphs exist
//! pass_end_present
//! ```
//! That is at most `frame_op_cap` ops. The cursor is marked as the writes are recorded,
//! because hosts execute ops in order and every write precedes the pass that could fail.
//!
//! ## 4. Lifetime
//! Spans point into the caller's lists, into `Renderer.uniform`, and into static data, so the
//! renderer and both lists must stay put until the host's submit returns. Both hosts submit
//! synchronously from the same call that recorded the stream.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");
const draw = @import("../draw.zig");
const font = @import("../font.zig");
const theme = @import("../theme.zig");

/// Straight (non-premultiplied) RGBA color with components in `[0, 1]`.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Framebuffer clear color. Deliberately neither black nor white, so a skipped clear, a failed
/// pass, or a swapchain glitch is unmistakable in review. It also shows through wherever a
/// quad fragment has zero coverage, such as outside a rounded corner.
pub const clear_color: Color = .{
    .r = 0.11,
    .g = 0.12,
    .b = 0.16,
    .a = 1.0,
};

/// Upper bound on the ops `frame` records; see the module guide's frame shape.
pub const frame_op_cap: u32 = 16;

/// The frame uniform: projection followed by the theme, `draw.uniform_bytes` in all.
pub const Uniform = extern struct {
    ortho: [16]f32,
    theme: theme.Theme,
};

/// Logical size for the projection and physical size for the pass. All nonzero.
pub const Size = struct {
    width_logical: u32,
    height_logical: u32,
    width_px: u32,
    height_px: u32,
};

/// The ids `setup` allocated, one per resource.
pub const Resources = struct {
    quad_shader: u16,
    glyph_shader: u16,
    frame_layout: u16,
    atlas_layout: u16,
    unit_buffer: u16,
    instance_buffer: u16,
    glyph_buffer: u16,
    uniform_buffer: u16,
    atlas: u16,
    atlas_sampler: u16,
    frame_group: u16,
    atlas_group: u16,
    quad_pipeline: u16,
    glyph_pipeline: u16,
};

pub const Renderer = struct {
    ids: commands.Ids,
    resources: Resources,
    cursor: draw.UploadCursor,
    uniform: Uniform,
    ready: bool,

    pub fn init() Renderer {
        const renderer: Renderer = .{
            .ids = .init(),
            .resources = undefined,
            .cursor = .init(),
            .uniform = .{ .ortho = undefined, .theme = theme.chrome },
            .ready = false,
        };
        assert(!renderer.ready);
        return renderer;
    }

    /// Records every long-lived resource and its static upload. Called once, on an empty
    /// buffer, before the first `frame`.
    pub fn setup(self: *Renderer, buffer: *commands.CommandBuffer) void {
        assert(!self.ready);
        assert(buffer.len == 0);
        const r = &self.resources;
        r.quad_shader = self.ids.take(.shader);
        r.glyph_shader = self.ids.take(.shader);
        buffer.push(.{ .shader_create = .{
            .id = r.quad_shader,
            .source = .of(draw.shader_file),
        } });
        buffer.push(.{ .shader_create = .{
            .id = r.glyph_shader,
            .source = .of(font.shader_file),
        } });

        r.frame_layout = self.ids.take(.layout);
        r.atlas_layout = self.ids.take(.layout);
        var frame_entries = std.mem.zeroes([commands.layout_entry_cap]commands.LayoutEntry);
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
        var atlas_entries = std.mem.zeroes([commands.layout_entry_cap]commands.LayoutEntry);
        const fragment = commands.stage_fragment;
        atlas_entries[0] = .{ .binding = 0, .visibility = fragment, .kind = .texture };
        atlas_entries[1] = .{ .binding = 1, .visibility = fragment, .kind = .sampler };
        buffer.push(.{ .layout_create = .{
            .id = r.atlas_layout,
            .entry_count = 2,
            .entries = atlas_entries,
        } });

        const vertex_usage = commands.usage_vertex | commands.usage_copy_dst;
        r.unit_buffer = self.create_buffer(buffer, vertex_usage, draw.quad_bytes);
        r.instance_buffer = self.create_buffer(
            buffer,
            vertex_usage,
            draw.instance_cap * draw.instance_stride,
        );
        r.glyph_buffer = self.create_buffer(
            buffer,
            vertex_usage,
            font.glyph_cap * font.glyph_stride,
        );
        r.uniform_buffer = self.create_buffer(
            buffer,
            commands.usage_uniform | commands.usage_copy_dst,
            draw.uniform_bytes,
        );

        r.atlas = self.ids.take(.texture);
        buffer.push(.{ .texture_create = .{
            .id = r.atlas,
            .format = .r8unorm,
            .width = font.atlas_width,
            .height = font.atlas_height,
        } });
        r.atlas_sampler = self.ids.take(.sampler);
        buffer.push(.{ .sampler_create = .{ .id = r.atlas_sampler, .filter = .linear } });

        r.frame_group = self.ids.take(.bind_group);
        r.atlas_group = self.ids.take(.bind_group);
        var frame_bindings = std.mem.zeroes([commands.bind_group_entry_cap]commands.BindGroupEntry);
        frame_bindings[0] = .{ .binding = 0, .resource = r.uniform_buffer };
        buffer.push(.{ .bind_group_create = .{
            .id = r.frame_group,
            .layout = r.frame_layout,
            .entry_count = 1,
            .entries = frame_bindings,
        } });
        var atlas_bindings = std.mem.zeroes([commands.bind_group_entry_cap]commands.BindGroupEntry);
        atlas_bindings[0] = .{ .binding = 0, .resource = r.atlas };
        atlas_bindings[1] = .{ .binding = 1, .resource = r.atlas_sampler };
        buffer.push(.{ .bind_group_create = .{
            .id = r.atlas_group,
            .layout = r.atlas_layout,
            .entry_count = 2,
            .entries = atlas_bindings,
        } });

        r.quad_pipeline = self.ids.take(.pipeline);
        r.glyph_pipeline = self.ids.take(.pipeline);
        buffer.push(.{ .pipeline_create = .{
            .id = r.quad_pipeline,
            .shader = r.quad_shader,
            .layout_count = 1,
            .buffer_count = 2,
            .blend = .alpha,
            .layouts = .{ r.frame_layout, 0, 0, 0 },
            .vertex = .{ unit_layout(), records_layout(draw.Instance, quad_fields) },
        } });
        buffer.push(.{ .pipeline_create = .{
            .id = r.glyph_pipeline,
            .shader = r.glyph_shader,
            .layout_count = 2,
            .buffer_count = 2,
            .blend = .alpha,
            .layouts = .{ r.frame_layout, r.atlas_layout, 0, 0 },
            .vertex = .{ unit_layout(), records_layout(font.Glyph, glyph_fields) },
        } });

        buffer.push(.{ .buffer_write = .{
            .id = r.unit_buffer,
            .offset = 0,
            .data = .of(std.mem.asBytes(&draw.unit_quad)),
        } });
        // Rows are tightly packed; `font.atlas_width` is also a multiple of 256, so a
        // staging-buffer copy would need no repacking (`comptime` block below).
        buffer.push(.{ .texture_write = .{
            .id = r.atlas,
            .x = 0,
            .y = 0,
            .width = font.atlas_width,
            .height = font.atlas_height,
            .bytes_per_row = font.atlas_width,
            .data = .of(font.atlas_bytes),
        } });
        self.ready = true;
        assert(self.ready);
    }

    fn create_buffer(self: *Renderer, buffer: *commands.CommandBuffer, usage: u32, size: u32) u16 {
        assert(usage != 0);
        assert(size != 0);
        const id = self.ids.take(.buffer);
        buffer.push(.{ .buffer_create = .{ .id = id, .usage = usage, .size = size } });
        return id;
    }

    /// Records one frame of `list` and `glyphs` into an empty `buffer`, then marks the
    /// cursor. The module guide lists the ops.
    pub fn frame(
        self: *Renderer,
        buffer: *commands.CommandBuffer,
        list: *const draw.DrawList,
        glyphs: *const font.GlyphList,
        size: Size,
    ) void {
        assert(self.ready);
        assert(buffer.len == 0);
        assert(size.width_px != 0);
        assert(size.height_px != 0);
        const r = &self.resources;
        if (self.cursor.uniform_dirty(size.width_logical, size.height_logical)) {
            draw.ortho_y_down(&self.uniform.ortho, size.width_logical, size.height_logical);
            buffer.push(.{ .buffer_write = .{
                .id = r.uniform_buffer,
                .offset = 0,
                .data = .of(std.mem.asBytes(&self.uniform)),
            } });
        }
        if (self.cursor.instance_range(list)) |range| {
            const records = list.items[0..list.count];
            write_records(buffer, r.instance_buffer, draw.Instance, records, range);
        }
        if (self.cursor.glyph_range(glyphs)) |range| {
            const records = glyphs.items[0..glyphs.count];
            write_records(buffer, r.glyph_buffer, font.Glyph, records, range);
        }
        self.cursor.mark(list, glyphs, size.width_logical, size.height_logical);

        buffer.push(.{ .pass_begin = .{
            .width_px = size.width_px,
            .height_px = size.height_px,
            .clear = .{ clear_color.r, clear_color.g, clear_color.b, clear_color.a },
        } });
        if (list.count != 0) {
            buffer.push(.{ .pipeline_set = .{ .id = r.quad_pipeline } });
            buffer.push(.{ .bind_group_set = .{ .slot = 0, .id = r.frame_group } });
            self.draw_records(buffer, r.instance_buffer, list.count);
        }
        if (glyphs.count != 0) {
            buffer.push(.{ .pipeline_set = .{ .id = r.glyph_pipeline } });
            buffer.push(.{ .bind_group_set = .{ .slot = 0, .id = r.frame_group } });
            buffer.push(.{ .bind_group_set = .{ .slot = 1, .id = r.atlas_group } });
            self.draw_records(buffer, r.glyph_buffer, glyphs.count);
        }
        buffer.push(.{ .pass_end_present = .{} });
        assert(buffer.count <= frame_op_cap);
    }

    fn draw_records(
        self: *Renderer,
        buffer: *commands.CommandBuffer,
        records: u16,
        count: u32,
    ) void {
        assert(count != 0);
        buffer.push(.{ .vertex_buffer_set = .{
            .slot = 0,
            .buffer = self.resources.unit_buffer,
            .offset = 0,
        } });
        buffer.push(.{ .vertex_buffer_set = .{ .slot = 1, .buffer = records, .offset = 0 } });
        buffer.push(.{ .draw = .{
            .vertex_count = draw.vertex_count,
            .instance_count = count,
            .first_vertex = 0,
            .first_instance = 0,
        } });
    }
};

fn write_records(
    buffer: *commands.CommandBuffer,
    id: u16,
    comptime T: type,
    records: []const T,
    range: draw.Range,
) void {
    assert(range.first < range.end);
    assert(range.end <= records.len);
    buffer.push(.{ .buffer_write = .{
        .id = id,
        .offset = range.first * @sizeOf(T),
        .data = .of(std.mem.sliceAsBytes(records[range.first..range.end])),
    } });
}

/// The four vec4 groups of each record type, in shader location order 1 to 4.
const quad_fields = [4][]const u8{ "x", "r", "radius", "clip_x0" };
const glyph_fields = [4][]const u8{ "x", "u0", "r", "clip_x0" };

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

fn records_layout(comptime T: type, comptime fields: [4][]const u8) commands.VertexBuffer {
    var attributes = std.mem.zeroes([commands.attribute_cap]commands.VertexAttribute);
    inline for (fields, 0..) |name, i| {
        attributes[i] = .{
            .location = i + 1,
            .format = .float32x4,
            .offset = @offsetOf(T, name),
        };
    }
    return .{
        .stride = @sizeOf(T),
        .step = .instance,
        .attribute_count = fields.len,
        .attributes = attributes,
    };
}

comptime {
    assert(@sizeOf(Uniform) == draw.uniform_bytes);
    assert(@offsetOf(Uniform, "theme") == draw.matrix_bytes);
    assert(draw.quad_bytes == draw.vertex_count * 2 * @sizeOf(f32));
    // Each group is one float32x4, so consecutive fields start 16 bytes apart.
    for (quad_fields, 0..) |name, i| assert(@offsetOf(draw.Instance, name) == 16 * i);
    for (glyph_fields, 0..) |name, i| assert(@offsetOf(font.Glyph, name) == 16 * i);
    assert(font.atlas_width % 256 == 0);
    assert(font.atlas_bytes.len == font.atlas_width * font.atlas_height);
}

const testing = std.testing;

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

fn face(x: f32) draw.Instance {
    return .{
        .x = x,
        .y = 0,
        .width = 10,
        .height = 10,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .radius = 0,
        .hover = 0,
        .down = 0,
        .kind = draw.kind_box,
        .clip_x0 = 0,
        .clip_y0 = 0,
        .clip_x1 = 100,
        .clip_y1 = 100,
    };
}

fn label(glyphs: *font.GlyphList) void {
    font.place(glyphs, "Hi", .{ .x = 0, .y = 0, .width = 64, .height = 32 }, .{
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
    }, .{ .x0 = 0, .y0 = 0, .x1 = 64, .y1 = 32 });
}

const size_720: Size = .{
    .width_logical = 1280,
    .height_logical = 720,
    .width_px = 1280,
    .height_px = 720,
};

// Locks the setup recording: each resource is created once, pipelines after the layouts and
// shaders they name, and the two static uploads last.
test "setup records every resource once" {
    var renderer = Renderer.init();
    var buffer = commands.CommandBuffer.init();
    renderer.setup(&buffer);
    var storage: [32]commands.Code = undefined;
    const expected = [_]commands.Code{
        .shader_create,     .shader_create,
        .layout_create,     .layout_create,
        .buffer_create,     .buffer_create,
        .buffer_create,     .buffer_create,
        .texture_create,    .sampler_create,
        .bind_group_create, .bind_group_create,
        .pipeline_create,   .pipeline_create,
        .buffer_write,      .texture_write,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&buffer, &storage));
    try testing.expect(renderer.ready);
    // The decoded quad pipeline carries the Instance offsets.
    var reader = buffer.reader();
    while (reader.next()) |op| {
        switch (op) {
            .pipeline_create => |pipeline| {
                try testing.expectEqual(@as(u16, draw.instance_stride), pipeline.vertex[1].stride);
                try testing.expectEqual(@as(u16, 48), pipeline.vertex[1].attributes[3].offset);
                try testing.expectEqual(@as(u8, 4), pipeline.vertex[1].attributes[3].location);
                break;
            },
            else => {},
        }
    }
}

// Locks the first frame: three whole-list writes, one pass, two draws, present.
test "the first frame writes three buffers and draws twice" {
    var renderer = Renderer.init();
    var buffer = commands.CommandBuffer.init();
    renderer.setup(&buffer);
    var list = draw.DrawList.init();
    try list.append(face(0));
    try list.append(face(20));
    var glyphs = font.GlyphList.init();
    label(&glyphs);
    buffer.reset();
    renderer.frame(&buffer, &list, &glyphs, size_720);
    var storage: [32]commands.Code = undefined;
    const expected = [_]commands.Code{
        .buffer_write,      .buffer_write,      .buffer_write,
        .pass_begin,        .pipeline_set,      .bind_group_set,
        .vertex_buffer_set, .vertex_buffer_set, .draw,
        .pipeline_set,      .bind_group_set,    .bind_group_set,
        .vertex_buffer_set, .vertex_buffer_set, .draw,
        .pass_end_present,
    };
    try testing.expectEqualSlices(commands.Code, &expected, codes(&buffer, &storage));
    try testing.expectEqual(frame_op_cap, buffer.count);
    var write_storage: [4]commands.BufferWrite = undefined;
    const recorded = writes(&buffer, &write_storage);
    try testing.expectEqual(renderer.resources.uniform_buffer, recorded[0].id);
    try testing.expectEqual(draw.uniform_bytes, recorded[0].data.len);
    try testing.expectEqual(renderer.resources.instance_buffer, recorded[1].id);
    try testing.expectEqual(2 * draw.instance_stride, recorded[1].data.len);
    try testing.expectEqual(renderer.resources.glyph_buffer, recorded[2].id);
    try testing.expectEqual(glyphs.count * font.glyph_stride, recorded[2].data.len);
}

// Locks the scale-only frame: same lists and logical size at a new physical size write
// nothing and still carry the new size in the pass.
test "a scale-only frame writes nothing" {
    var renderer = Renderer.init();
    var buffer = commands.CommandBuffer.init();
    renderer.setup(&buffer);
    var list = draw.DrawList.init();
    try list.append(face(0));
    var glyphs = font.GlyphList.init();
    label(&glyphs);
    buffer.reset();
    renderer.frame(&buffer, &list, &glyphs, size_720);
    buffer.reset();
    var scaled = size_720;
    scaled.width_px = 2560;
    scaled.height_px = 1440;
    renderer.frame(&buffer, &list, &glyphs, scaled);
    var write_storage: [4]commands.BufferWrite = undefined;
    try testing.expectEqual(@as(usize, 0), writes(&buffer, &write_storage).len);
    var reader = buffer.reader();
    try testing.expectEqual(@as(u32, 2560), reader.next().?.pass_begin.width_px);
}

// Locks a hover frame: a rebuilt list where one face changed writes that one record at its
// offset and nothing else; an empty glyph list records no glyph draw.
test "a changed face writes one record" {
    var renderer = Renderer.init();
    var buffer = commands.CommandBuffer.init();
    renderer.setup(&buffer);
    var list = draw.DrawList.init();
    try list.append(face(0));
    try list.append(face(20));
    try list.append(face(40));
    const glyphs = font.GlyphList.init();
    buffer.reset();
    renderer.frame(&buffer, &list, &glyphs, size_720);
    try testing.expect(list.set_state(1, 0.5, 0));
    buffer.reset();
    renderer.frame(&buffer, &list, &glyphs, size_720);
    var write_storage: [4]commands.BufferWrite = undefined;
    const recorded = writes(&buffer, &write_storage);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqual(renderer.resources.instance_buffer, recorded[0].id);
    try testing.expectEqual(draw.instance_stride, recorded[0].offset);
    try testing.expectEqual(draw.instance_stride, recorded[0].data.len);
    var storage: [32]commands.Code = undefined;
    const recorded_codes = codes(&buffer, &storage);
    try testing.expectEqual(@as(usize, 1 + 1 + 5 + 1), recorded_codes.len);
}

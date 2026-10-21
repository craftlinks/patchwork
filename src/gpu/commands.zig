//! The GPU command stream: one encoding that both hosts replay.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Command Stream
//! Zig records every GPU operation, from shader creation to present, into a `CommandBuffer` in
//! its own memory. The native host decodes it with `Reader` and calls wgpu-native
//! (`host/gpu_wgpu.zig`, `execute`); the browser host receives `(ptr, len)` through
//! `submit_js` and replays it against WebGPU (`web/shell.js`). Neither host knows about quads,
//! glyphs, WGSL, or vertex layouts: those live in `draw/renderer.zig`, which records the
//! stream. A new pipeline, buffer, or texture is a new recording, not a third copy of
//! pipeline code.
//!
//! ## 2. Encoding
//! ```text
//! op      = Header { code: u16, size: u16, pad: u32 }  payload[size]  zero[pad to 8]
//! stream  = op*                      (at most `capacity` bytes, starts 8-byte aligned)
//! Span    = { address: u64, len: u32, pad: u32 }      (a reference into host memory)
//! ```
//! `size` is the payload's `@sizeOf`, so the reader can assert it before decoding. Every
//! payload is an `extern struct` with explicit `pad` fields and no implicit padding (the
//! `comptime` block at the end of this file checks each one), so no uninitialized byte
//! crosses the boundary. On `wasm32` a `Span.address` is a linear-memory offset zero-extended
//! to 64 bits; JavaScript reads its low 32 bits and asserts the high word is zero.
//!
//! ## 3. Ids, Not Handles
//! Resources are named by `u16` ids that Zig allocates (`Ids`) and the hosts map to their own
//! handle tables, bounded by `caps`. The stream is therefore byte-identical on both targets,
//! and a unit test can record a frame and assert its op sequence without a GPU. Creating an
//! id twice or using an id that was never created is a host assertion naming the op.
//! A `shader_create` also carries a label (the draw type's name); both hosts give it to the
//! shader module and print it with a failure, because WGSL errors appear only when a host
//! compiles the module at startup.
//!
//! ## 4. Fixed Conventions
//! Things every pipeline shares are conventions instead of payload fields: entry points are
//! `vertex_entry` and `fragment_entry`, topology is a triangle list with no culling, the color
//! target is the host's surface format, a texture is created with binding and copy-destination
//! usage and bound through its default view, a bind-group buffer entry binds the whole buffer,
//! and a sampler clamps to the edge. Buffer usage bits and shader stage bits are the WebGPU
//! values, which `webgpu.h` shares, so both hosts pass them through unchanged.
//!
//! ## 5. One Op Table for Both Interpreters
//! `table_json` is generated at compile time from `Op` and its payload types: op codes, names,
//! payload sizes, every field's offset and type, the payload enums, the caps, and the entry
//! point names. The wasm module exports it, and `web/shell.js` decodes payloads by field name
//! from that table, so a payload edit cannot desynchronize the browser decoder. The test
//! "table json matches the payload layouts" parses it back and checks it against `@offsetOf`.
//!
//! ## 6. TigerStyle Invariants
//! - `CommandBuffer` is a fixed array of `capacity` bytes. Overflow is a panic that names the
//!   op and the capacity, never growth or truncation.
//! - Each id kind is bounded by `caps`; `Ids.take` asserts the bound.
//! - Spans must outlive the submit that carries them. Both hosts consume a stream
//!   synchronously, so memory owned by the recorder or by static data is sufficient.

const std = @import("std");
const assert = std.debug.assert;

/// Byte capacity of one `CommandBuffer`, so of one submit.
pub const capacity: u32 = 65536;

/// Byte size of `Header`.
pub const header_bytes: u32 = 8;

/// Alignment of every op header in the stream.
pub const op_align: u32 = 8;

/// Vertex entry point every shader module defines.
pub const vertex_entry: []const u8 = "vs_main";

/// Fragment entry point every shader module defines.
pub const fragment_entry: []const u8 = "fs_main";

/// Fixed array bounds inside payloads.
pub const layout_entry_cap: u32 = 4;
pub const pipeline_layout_cap: u32 = 4;
pub const vertex_buffer_cap: u32 = 2;
pub const attribute_cap: u32 = 8;
pub const bind_group_entry_cap: u32 = 4;

/// WebGPU `GPUBufferUsage` bits (identical in `webgpu.h`).
pub const usage_copy_dst: u32 = 0x08;
pub const usage_vertex: u32 = 0x20;
pub const usage_uniform: u32 = 0x40;
pub const usage_storage: u32 = 0x80;

/// WebGPU `GPUShaderStage` bits (identical in `webgpu.h`).
pub const stage_vertex: u8 = 0x1;
pub const stage_fragment: u8 = 0x2;

/// Resource kinds, one host table each.
pub const Kind = enum {
    shader,
    layout,
    pipeline,
    buffer,
    texture,
    sampler,
    bind_group,
};

/// Host table size per kind. Ids are `0 .. caps.get(kind)`.
pub const caps = std.EnumArray(Kind, u16).init(.{
    .shader = 16,
    .layout = 16,
    .pipeline = 32,
    .buffer = 64,
    .texture = 32,
    .sampler = 8,
    .bind_group = 64,
});

/// Op codes. Zero is reserved so a zeroed header is never a valid op.
pub const Code = enum(u16) {
    shader_create = 1,
    layout_create,
    pipeline_create,
    buffer_create,
    texture_create,
    sampler_create,
    bind_group_create,
    buffer_write,
    texture_write,
    pass_begin,
    pipeline_set,
    bind_group_set,
    vertex_buffer_set,
    draw,
    pass_end_present,
};

/// What one bind group layout entry holds, and so what its bind group resource id names.
pub const BindingKind = enum(u8) {
    uniform,
    texture,
    sampler,
    storage_read,
};

pub const VertexFormat = enum(u8) {
    float32x2,
    float32x4,
};

pub const StepMode = enum(u8) {
    vertex,
    instance,
};

/// `alpha` is source-over on straight alpha for color and alpha.
pub const Blend = enum(u8) {
    none,
    alpha,
};

/// `r8unorm` is single-channel coverage (the font atlas); `rgba8unorm` is straight-alpha
/// color (images). Both sample as filterable float, so one bind group layout serves both.
pub const TextureFormat = enum(u8) {
    r8unorm,
    rgba8unorm,
};

/// Min and mag filter of a sampler.
pub const Filter = enum(u8) {
    nearest,
    linear,
};

/// The payload enums, listed in `table_json`. Each must be contiguous from zero so the table
/// can list names by value.
const payload_enums = .{ BindingKind, VertexFormat, StepMode, Blend, TextureFormat, Filter };

pub const Header = extern struct {
    code: u16,
    size: u16,
    pad: u32 = 0,
};

/// A byte range in host memory, valid until the submit that carries it returns.
pub const Span = extern struct {
    address: u64,
    len: u32,
    pad: u32 = 0,

    /// Spans `bytes`, which must be nonempty.
    pub fn of(bytes: []const u8) Span {
        assert(bytes.len != 0);
        assert(bytes.len <= std.math.maxInt(u32));
        const span: Span = .{ .address = @intFromPtr(bytes.ptr), .len = @intCast(bytes.len) };
        assert(span.address != 0);
        return span;
    }

    /// The bytes this span names. Only meaningful in the process that recorded it.
    pub fn slice(self: Span) []const u8 {
        assert(self.address != 0);
        assert(self.len != 0);
        const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(self.address)));
        return ptr[0..self.len];
    }
};

pub const ShaderCreate = extern struct {
    id: u16,
    pad0: u16 = 0,
    pad1: u32 = 0,
    /// WGSL source text.
    source: Span,
    /// Debug label (the draw type's name). Hosts pass it to the shader module and name it in
    /// error messages, because WGSL errors surface only when a host compiles the module.
    label: Span,
};

pub const LayoutEntry = extern struct {
    binding: u8,
    /// `stage_*` bits.
    visibility: u8,
    kind: BindingKind,
    pad: u8 = 0,
};

pub const LayoutCreate = extern struct {
    id: u16,
    entry_count: u16,
    entries: [layout_entry_cap]LayoutEntry,
};

pub const VertexAttribute = extern struct {
    location: u8,
    format: VertexFormat,
    offset: u16,
};

pub const VertexBuffer = extern struct {
    stride: u16,
    step: StepMode,
    attribute_count: u8,
    attributes: [attribute_cap]VertexAttribute,
};

pub const PipelineCreate = extern struct {
    id: u16,
    shader: u16,
    layout_count: u8,
    buffer_count: u8,
    blend: Blend,
    pad: u8 = 0,
    /// Layout ids for bind groups `0 .. layout_count`.
    layouts: [pipeline_layout_cap]u16,
    vertex: [vertex_buffer_cap]VertexBuffer,
};

pub const BufferCreate = extern struct {
    id: u16,
    pad: u16 = 0,
    /// `usage_*` bits.
    usage: u32,
    size: u32,
};

pub const TextureCreate = extern struct {
    id: u16,
    format: TextureFormat,
    pad: u8 = 0,
    width: u32,
    height: u32,
};

pub const SamplerCreate = extern struct {
    id: u16,
    filter: Filter,
    pad: u8 = 0,
};

pub const BindGroupEntry = extern struct {
    binding: u16,
    /// A buffer, texture, or sampler id, by the kind of the layout entry at `binding`.
    resource: u16,
};

pub const BindGroupCreate = extern struct {
    id: u16,
    layout: u16,
    entry_count: u16,
    pad: u16 = 0,
    entries: [bind_group_entry_cap]BindGroupEntry,
};

pub const BufferWrite = extern struct {
    id: u16,
    pad: u16 = 0,
    offset: u32,
    data: Span,
};

/// Writes `data` into the `width` by `height` texel region at `(x, y)`. Rows are
/// `bytes_per_row` apart in `data`.
pub const TextureWrite = extern struct {
    id: u16,
    pad: u16 = 0,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    data: Span,
};

/// Acquires the surface texture and begins a pass that clears it. `width_px` and `height_px`
/// are the physical size the frame was recorded for; native reconfigures the surface when it
/// changes and the browser asserts it equals the canvas backing size.
pub const PassBegin = extern struct {
    width_px: u32,
    height_px: u32,
    /// Straight RGBA clear color.
    clear: [4]f32,
};

pub const PipelineSet = extern struct {
    id: u16,
    pad: u16 = 0,
};

pub const BindGroupSet = extern struct {
    slot: u16,
    id: u16,
};

pub const VertexBufferSet = extern struct {
    slot: u16,
    buffer: u16,
    offset: u32,
};

pub const Draw = extern struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

/// Ends the pass, submits the frame, and presents the surface texture.
pub const PassEndPresent = extern struct {};

/// One decoded op. The tag is the op code and the payload type is the field type.
pub const Op = union(Code) {
    shader_create: ShaderCreate,
    layout_create: LayoutCreate,
    pipeline_create: PipelineCreate,
    buffer_create: BufferCreate,
    texture_create: TextureCreate,
    sampler_create: SamplerCreate,
    bind_group_create: BindGroupCreate,
    buffer_write: BufferWrite,
    texture_write: TextureWrite,
    pass_begin: PassBegin,
    pipeline_set: PipelineSet,
    bind_group_set: BindGroupSet,
    vertex_buffer_set: VertexBufferSet,
    draw: Draw,
    pass_end_present: PassEndPresent,
};

/// Allocates resource ids per kind, in order, bounded by `caps`. Ids are never freed: every
/// resource is created once, at setup.
pub const Ids = struct {
    next: std.EnumArray(Kind, u16),

    pub fn init() Ids {
        const ids: Ids = .{ .next = .initFill(0) };
        assert(ids.next.get(.shader) == 0);
        return ids;
    }

    /// Returns the next unused id of `kind`.
    pub fn take(self: *Ids, kind: Kind) u16 {
        const id = self.next.get(kind);
        assert(id < caps.get(kind));
        self.next.set(kind, id + 1);
        assert(self.next.get(kind) == id + 1);
        return id;
    }
};

/// A fixed-capacity recording of ops. `count` is the number of ops, `len` their byte length.
pub const CommandBuffer = struct {
    bytes: [capacity]u8 align(op_align),
    len: u32,
    count: u32,

    pub fn init() CommandBuffer {
        const buffer: CommandBuffer = .{ .bytes = undefined, .len = 0, .count = 0 };
        assert(buffer.len == 0);
        return buffer;
    }

    /// Empties the buffer for the next recording.
    pub fn reset(self: *CommandBuffer) void {
        assert(self.len <= capacity);
        self.len = 0;
        self.count = 0;
        assert(self.len == 0);
    }

    /// Appends one op. Panics, naming the op and `capacity`, if it does not fit.
    pub fn push(self: *CommandBuffer, op: Op) void {
        switch (op) {
            inline else => |payload, code| self.push_payload(code, payload),
        }
    }

    fn push_payload(self: *CommandBuffer, comptime code: Code, payload: anytype) void {
        const size: u32 = @sizeOf(@TypeOf(payload));
        const total: u32 = header_bytes + align_up(size);
        assert(self.len % op_align == 0);
        if (self.len + total > capacity) {
            std.debug.panic("command buffer overflow: {s} needs {d} bytes, {d} of {d} used", .{
                @tagName(code), total, self.len, capacity,
            });
        }
        const header: Header = .{ .code = @intFromEnum(code), .size = @intCast(size) };
        const start = self.len;
        @memcpy(self.bytes[start..][0..header_bytes], std.mem.asBytes(&header));
        if (size != 0) {
            @memcpy(self.bytes[start + header_bytes ..][0..size], std.mem.asBytes(&payload));
        }
        @memset(self.bytes[start + header_bytes + size .. start + total], 0);
        self.len += total;
        self.count += 1;
        assert(self.len % op_align == 0);
        assert(self.len <= capacity);
    }

    /// A reader over the recorded ops, in order.
    pub fn reader(self: *const CommandBuffer) Reader {
        assert(self.len <= capacity);
        return Reader.init(self.bytes[0..self.len]);
    }
};

/// Decodes a stream op by op. `index` is the number of ops already returned, which is the
/// index hosts name in error messages.
pub const Reader = struct {
    bytes: []const u8,
    offset: u32,
    index: u32,

    pub fn init(bytes: []const u8) Reader {
        assert(bytes.len <= capacity);
        assert(bytes.len % op_align == 0);
        return .{ .bytes = bytes, .offset = 0, .index = 0 };
    }

    /// Returns the next op, or null at the end. Panics on an unknown code or a payload size
    /// that disagrees with the code's payload type.
    pub fn next(self: *Reader) ?Op {
        if (self.offset == self.bytes.len) {
            return null;
        }
        assert(self.offset + header_bytes <= self.bytes.len);
        const header = std.mem.bytesToValue(Header, self.bytes[self.offset..][0..header_bytes]);
        const code = std.enums.fromInt(Code, header.code) orelse {
            std.debug.panic("command {d}: unknown op code {d}", .{ self.index, header.code });
        };
        const total = header_bytes + align_up(header.size);
        assert(self.offset + total <= self.bytes.len);
        const payload = self.bytes[self.offset + header_bytes ..][0..header.size];
        const op = decode(code, payload, self.index);
        self.offset += total;
        self.index += 1;
        return op;
    }
};

fn decode(code: Code, payload: []const u8, index: u32) Op {
    switch (code) {
        inline else => |tag| {
            const T = @FieldType(Op, @tagName(tag));
            if (payload.len != @sizeOf(T)) {
                std.debug.panic("command {d}: {s} payload is {d} bytes, expected {d}", .{
                    index, @tagName(tag), payload.len, @sizeOf(T),
                });
            }
            if (@sizeOf(T) == 0) {
                return @unionInit(Op, @tagName(tag), .{});
            }
            const value = std.mem.bytesToValue(T, payload[0..@sizeOf(T)]);
            return @unionInit(Op, @tagName(tag), value);
        },
    }
}

fn align_up(size: u32) u32 {
    return (size + op_align - 1) / op_align * op_align;
}

/// The op table both interpreters read; see the module guide, section 5.
pub const table_json: []const u8 = blk: {
    @setEvalBranchQuota(200_000);
    const text = json_table();
    const copy = text[0..text.len].*;
    break :blk &copy;
};

fn json_table() []const u8 {
    comptime {
        var out: []const u8 = "{";
        out = out ++ std.fmt.comptimePrint(
            "\"capacity\":{d},\"header_bytes\":{d},\"align\":{d},",
            .{ capacity, header_bytes, op_align },
        );
        out = out ++ "\"entry\":{\"vertex\":\"" ++ vertex_entry ++ "\",\"fragment\":\"" ++
            fragment_entry ++ "\"},";
        out = out ++ "\"caps\":{";
        for (std.enums.values(Kind), 0..) |kind, i| {
            if (i != 0) out = out ++ ",";
            out = out ++ std.fmt.comptimePrint("\"{s}\":{d}", .{ @tagName(kind), caps.get(kind) });
        }
        out = out ++ "},\"enums\":{";
        for (payload_enums, 0..) |E, i| {
            if (i != 0) out = out ++ ",";
            out = out ++ "\"" ++ short_name(E) ++ "\":[";
            for (@typeInfo(E).@"enum".fields, 0..) |field, j| {
                if (j != 0) out = out ++ ",";
                out = out ++ "\"" ++ field.name ++ "\"";
            }
            out = out ++ "]";
        }
        out = out ++ "},\"ops\":[";
        for (@typeInfo(Op).@"union".fields, 0..) |field, i| {
            if (i != 0) out = out ++ ",";
            const code = @field(Code, field.name);
            out = out ++ std.fmt.comptimePrint(
                "{{\"code\":{d},\"name\":\"{s}\",\"size\":{d},\"type\":",
                .{ @intFromEnum(code), field.name, @sizeOf(field.type) },
            );
            out = out ++ type_json(field.type) ++ "}";
        }
        out = out ++ "]}";
        return out;
    }
}

fn type_json(comptime T: type) []const u8 {
    comptime {
        switch (@typeInfo(T)) {
            .int, .float => return "\"" ++ @typeName(T) ++ "\"",
            .@"enum" => |info| {
                return "{\"enum\":\"" ++ short_name(T) ++ "\",\"int\":\"" ++
                    @typeName(info.tag_type) ++ "\"}";
            },
            .array => |info| {
                return std.fmt.comptimePrint("{{\"array\":{s},\"len\":{d},\"stride\":{d}}}", .{
                    type_json(info.child), info.len, @sizeOf(info.child),
                });
            },
            .@"struct" => |info| {
                var out: []const u8 = "{\"fields\":[";
                var first = true;
                for (info.fields) |field| {
                    if (std.mem.startsWith(u8, field.name, "pad")) continue;
                    if (!first) out = out ++ ",";
                    first = false;
                    out = out ++ std.fmt.comptimePrint(
                        "{{\"name\":\"{s}\",\"offset\":{d},\"type\":",
                        .{ field.name, @offsetOf(T, field.name) },
                    );
                    out = out ++ type_json(field.type) ++ "}";
                }
                return out ++ "]}";
            },
            else => @compileError("type not allowed in a command payload: " ++ @typeName(T)),
        }
    }
}

fn short_name(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// True when `T` has no implicit padding anywhere: its size is the sum of its fields' sizes,
/// recursively, so every byte of a payload is a declared field.
fn dense(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .int, .float, .@"enum" => return true,
        .array => |info| return dense(info.child),
        .@"struct" => |info| {
            var sum: usize = 0;
            for (info.fields) |field| {
                if (!dense(field.type)) return false;
                sum += @sizeOf(field.type);
            }
            return sum == @sizeOf(T);
        },
        else => return false,
    }
}

comptime {
    assert(@sizeOf(Header) == header_bytes);
    assert(@sizeOf(Span) == 16);
    assert(@alignOf(Span) == op_align);
    assert(capacity % op_align == 0);
    // Every payload fits a u16 size, is dense, and is at most 8-byte aligned so a payload at
    // `header_bytes` past an aligned header is aligned.
    for (@typeInfo(Op).@"union".fields) |field| {
        assert(@sizeOf(field.type) <= std.math.maxInt(u16));
        assert(@alignOf(field.type) <= op_align);
        assert(dense(field.type));
        assert(@typeInfo(field.type).@"struct".layout == .@"extern");
    }
    for (payload_enums) |E| {
        for (@typeInfo(E).@"enum".fields, 0..) |field, i| {
            assert(field.value == i);
        }
    }
    assert(@sizeOf(ShaderCreate) == 40);
    assert(@sizeOf(PipelineCreate) == 88);
    assert(@sizeOf(TextureWrite) == 40);
    assert(@sizeOf(PassEndPresent) == 0);
}

const testing = std.testing;

const sample_source = "fn main() {}";
const sample_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

fn attribute(location: u8, format: VertexFormat, offset: u16) VertexAttribute {
    return .{ .location = location, .format = format, .offset = offset };
}

/// One op per code with distinct, nonzero field values, in code order.
fn samples() [@typeInfo(Op).@"union".fields.len]Op {
    var attributes = std.mem.zeroes([attribute_cap]VertexAttribute);
    attributes[0] = attribute(1, .float32x4, 0);
    attributes[1] = attribute(2, .float32x4, 16);
    var second = std.mem.zeroes([attribute_cap]VertexAttribute);
    second[0] = attribute(0, .float32x2, 0);
    return .{
        .{ .shader_create = .{ .id = 3, .source = .of(sample_source), .label = .of("box") } },
        .{ .layout_create = .{ .id = 2, .entry_count = 2, .entries = .{
            .{ .binding = 0, .visibility = stage_fragment, .kind = .texture },
            .{ .binding = 1, .visibility = stage_fragment, .kind = .sampler },
            .{ .binding = 2, .visibility = stage_vertex, .kind = .storage_read },
            .{ .binding = 3, .visibility = stage_vertex | stage_fragment, .kind = .uniform },
        } } },
        .{ .pipeline_create = .{
            .id = 5,
            .shader = 3,
            .layout_count = 2,
            .buffer_count = 2,
            .blend = .alpha,
            .layouts = .{ 0, 2, 0, 0 },
            .vertex = .{
                .{ .stride = 8, .step = .vertex, .attribute_count = 1, .attributes = second },
                .{
                    .stride = 64,
                    .step = .instance,
                    .attribute_count = 2,
                    .attributes = attributes,
                },
            },
        } },
        .{ .buffer_create = .{ .id = 7, .usage = usage_vertex | usage_copy_dst, .size = 4096 } },
        .{ .texture_create = .{ .id = 1, .format = .rgba8unorm, .width = 32, .height = 32 } },
        .{ .sampler_create = .{ .id = 1, .filter = .linear } },
        .{ .bind_group_create = .{ .id = 9, .layout = 2, .entry_count = 2, .entries = .{
            .{ .binding = 0, .resource = 1 },
            .{ .binding = 1, .resource = 1 },
            .{ .binding = 0, .resource = 0 },
            .{ .binding = 0, .resource = 0 },
        } } },
        .{ .buffer_write = .{ .id = 7, .offset = 128, .data = .of(&sample_data) } },
        .{ .texture_write = .{
            .id = 1,
            .x = 4,
            .y = 8,
            .width = 2,
            .height = 4,
            .bytes_per_row = 2,
            .data = .of(&sample_data),
        } },
        .{ .pass_begin = .{ .width_px = 1280, .height_px = 720, .clear = .{ 0.1, 0.2, 0.3, 1 } } },
        .{ .pipeline_set = .{ .id = 5 } },
        .{ .bind_group_set = .{ .slot = 1, .id = 9 } },
        .{ .vertex_buffer_set = .{ .slot = 1, .buffer = 7, .offset = 64 } },
        .{ .draw = .{
            .vertex_count = 6,
            .instance_count = 40,
            .first_vertex = 0,
            .first_instance = 2,
        } },
        .{ .pass_end_present = .{} },
    };
}

fn payload_bytes(op: *const Op) []const u8 {
    switch (op.*) {
        inline else => |*payload| return std.mem.asBytes(payload),
    }
}

// Locks the round trip: every op encodes and decodes to the same code and payload bytes, in
// order, and each header starts 8-byte aligned.
test "every op round trips through the stream" {
    const ops = samples();
    var buffer = CommandBuffer.init();
    for (ops) |op| {
        buffer.push(op);
    }
    try testing.expectEqual(@as(u32, ops.len), buffer.count);
    var reader = buffer.reader();
    for (ops, 0..) |expected, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), reader.index);
        try testing.expect(reader.offset % op_align == 0);
        const actual = reader.next().?;
        try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
        try testing.expectEqualSlices(u8, payload_bytes(&expected), payload_bytes(&actual));
    }
    try testing.expectEqual(@as(?Op, null), reader.next());
    try testing.expectEqual(buffer.len, reader.offset);
}

// Locks the encoding of one op: header code and size, payload at offset 8, zero tail padding.
test "a header carries the code and the payload size" {
    var buffer = CommandBuffer.init();
    buffer.push(.{ .pipeline_set = .{ .id = 5 } });
    try testing.expectEqual(@as(u32, 16), buffer.len);
    const header = std.mem.bytesToValue(Header, buffer.bytes[0..8]);
    try testing.expectEqual(@intFromEnum(Code.pipeline_set), header.code);
    try testing.expectEqual(@as(u16, 4), header.size);
    try testing.expectEqual(@as(u16, 5), std.mem.bytesToValue(u16, buffer.bytes[8..10]));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, buffer.bytes[10..16]);
    buffer.push(.{ .pass_end_present = .{} });
    try testing.expectEqual(@as(u32, 24), buffer.len);
    buffer.reset();
    try testing.expectEqual(@as(u32, 0), buffer.len);
    try testing.expectEqual(@as(u32, 0), buffer.count);
}

// Locks that a span names the exact bytes it was made from.
test "a span resolves to its bytes" {
    const span: Span = .of(&sample_data);
    try testing.expectEqual(@as(u32, 8), span.len);
    try testing.expectEqualSlices(u8, &sample_data, span.slice());
}

// Locks that ids are dense per kind and kinds are independent.
test "ids count up per kind" {
    var ids = Ids.init();
    try testing.expectEqual(@as(u16, 0), ids.take(.buffer));
    try testing.expectEqual(@as(u16, 1), ids.take(.buffer));
    try testing.expectEqual(@as(u16, 0), ids.take(.shader));
    try testing.expectEqual(@as(u16, 2), ids.take(.buffer));
}

fn expect_field(fields: std.json.Array, name: []const u8, offset: usize) !std.json.Value {
    for (fields.items) |item| {
        const object = item.object;
        if (std.mem.eql(u8, object.get("name").?.string, name)) {
            try testing.expectEqual(@as(i64, @intCast(offset)), object.get("offset").?.integer);
            return object.get("type").?;
        }
    }
    return error.FieldMissing;
}

// Locks that the generated table parses, lists every op with its code and size, omits pad
// fields, and reports offsets equal to `@offsetOf`, including nested arrays and structs.
test "table json matches the payload layouts" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, table_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, capacity), root.get("capacity").?.integer);
    try testing.expectEqualStrings(vertex_entry, root.get("entry").?.object.get("vertex").?.string);
    try testing.expectEqual(@as(i64, 64), root.get("caps").?.object.get("buffer").?.integer);
    const formats = root.get("enums").?.object.get("VertexFormat").?.array;
    const float32x4 = formats.items[@intFromEnum(VertexFormat.float32x4)];
    try testing.expectEqualStrings("float32x4", float32x4.string);
    const ops = root.get("ops").?.array;
    try testing.expectEqual(@typeInfo(Op).@"union".fields.len, ops.items.len);
    inline for (@typeInfo(Op).@"union".fields, 0..) |field, i| {
        const op = ops.items[i].object;
        try testing.expectEqualStrings(field.name, op.get("name").?.string);
        const code: i64 = @intFromEnum(@field(Code, field.name));
        try testing.expectEqual(code, op.get("code").?.integer);
        try testing.expectEqual(@as(i64, @sizeOf(field.type)), op.get("size").?.integer);
        const fields = op.get("type").?.object.get("fields").?.array;
        inline for (@typeInfo(field.type).@"struct".fields) |member| {
            if (comptime std.mem.startsWith(u8, member.name, "pad")) {
                try testing.expectError(error.FieldMissing, expect_field(fields, member.name, 0));
            } else {
                _ = try expect_field(fields, member.name, @offsetOf(field.type, member.name));
            }
        }
    }
    // Nested: pipeline_create.vertex is an array of VertexBuffer whose attributes nest again.
    const pipeline = ops.items[@intFromEnum(Code.pipeline_create) - 1].object;
    const vertex = try expect_field(
        pipeline.get("type").?.object.get("fields").?.array,
        "vertex",
        @offsetOf(PipelineCreate, "vertex"),
    );
    try testing.expectEqual(@as(i64, @sizeOf(VertexBuffer)), vertex.object.get("stride").?.integer);
    const buffer_fields = vertex.object.get("array").?.object.get("fields").?.array;
    const attributes = try expect_field(
        buffer_fields,
        "attributes",
        @offsetOf(VertexBuffer, "attributes"),
    );
    const attribute_fields = attributes.object.get("array").?.object.get("fields").?.array;
    const format_offset = @offsetOf(VertexAttribute, "format");
    const format = try expect_field(attribute_fields, "format", format_offset);
    try testing.expectEqualStrings("VertexFormat", format.object.get("enum").?.string);
}

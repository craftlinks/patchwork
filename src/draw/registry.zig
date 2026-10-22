//! The draw type registry: comptime checks, WGSL assembly, and vertex layouts per type.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Draw Types
//! A draw type is a Zig `extern struct` plus a WGSL `pixel` function. The app lists its types
//! and their capacities in `App.config.draw`; a type's id is its index in that list. Library
//! types live in `draw/types.zig` and an app adds its own without editing the library (the
//! rack's `Led`). Each type gets one shader module, one pipeline, and one vertex buffer.
//!
//! ## 2. The Instance Convention (`check`)
//! ```text
//! offset 0   rect: [4]f32   x, y, width, height in logical pixels   location 1
//! offset 16  clip: [4]f32   exclusive-max x0, y0, x1, y1             location 2
//! offset 32  up to 6 more 16-byte parameter groups                   locations 3 to 8
//! ```
//! Every field is `f32` or `[4]f32`, and a `[4]f32` starts on a 16-byte boundary, so each
//! 16-byte group is exactly one `float32x4` attribute. `@sizeOf(T)` must be a multiple of 16
//! and at most `group_cap * 16`. The type declares `pub const pixel: []const u8` (its WGSL
//! function) and `pub const texture: ?textures.Format` (null for an untextured type). Field
//! names must not shadow the prelude's `local`, `size`, or `pos`. `check` returns the first
//! violation as a message that starts with the type's name, so `app.check` can fail the build
//! naming it (`zig build test-contract` locks one case).
//!
//! ## 3. WGSL Assembly (`source`)
//! ```text
//! prelude.wgsl                         Frame, vs_main, fs_main, coverage, sdf_*, clip_mask
//! struct Theme { ... }                 one vec4 per `theme.Theme` field, in order
//! bound_texture, bound_sampler         @group(1), textured types only, with sample_texture
//! struct Instance { g0 .. gN-1 }       @location(1 .. N) vec4<f32>
//! struct Varyings                      position, local, and every group @interpolate(flat)
//! struct Pixel                         local, size, pos, and every Zig field by name
//! fn carry, fn unpack                  copy the groups through and name the fields
//! T.pixel                              the type's own fn pixel(px: Pixel) -> vec4<f32>
//! ```
//! Generating `Theme` from the Zig record removes the hand-mirrored copy that a test used to
//! police. The concatenation runs at compile time; the result is static data spanned by the
//! renderer's `shader_create`, labelled with `@typeName(T)`.
//!
//! ## 4. TigerStyle Invariants
//! - At most `type_cap` types, each with `1 <= cap <= instance_cap_max` and at most
//!   `group_cap` groups; all checked at compile time.
//! - Nothing here runs at run time except reading the generated tables.

const std = @import("std");
const assert = std.debug.assert;
const commands = @import("../gpu/commands.zig");
const theme = @import("../theme.zig");
const textures = @import("textures.zig");

const prelude: []const u8 = @embedFile("prelude.wgsl");

/// One registered draw type and the instances its pool holds per frame.
pub const DrawType = struct {
    type: type,
    cap: u32,
};

/// Draw types one app may register: one shader module and one pipeline each.
pub const type_cap: u32 = 16;

/// Attribute groups per instance: `rect`, `clip`, and up to six parameter groups.
pub const group_cap: u32 = 8;

/// Upper bound on one type's pool, so `cap * @sizeOf(T)` stays far below buffer limits.
pub const instance_cap_max: u32 = 65536;

/// Names the prelude adds to `Pixel`.
const reserved = [_][]const u8{ "local", "size", "pos" };

/// Null when `T` satisfies the instance convention, otherwise a message naming `T` and the
/// first violation. See the module guide, section 2.
pub fn check(comptime T: type) ?[]const u8 {
    comptime {
        const name = @typeName(T);
        const info = @typeInfo(T);
        if (info != .@"struct") return name ++ ": a draw type must be an extern struct";
        if (info.@"struct".layout != .@"extern") {
            return name ++ ": a draw type must be an extern struct";
        }
        if (@sizeOf(T) % 16 != 0) {
            return name ++ ": @sizeOf must be a multiple of 16 (one vec4 per 16 bytes)";
        }
        if (@sizeOf(T) / 16 > group_cap) return name ++ ": at most 8 vec4 groups";
        const field_names = info.@"struct".field_names;
        const field_types = info.@"struct".field_types;
        if (field_names.len < 2) return name ++ ": the first fields must be `rect` and `clip`";
        if (!std.mem.eql(u8, field_names[0], "rect")) {
            return name ++ ": the first field must be `rect: [4]f32`";
        }
        if (!std.mem.eql(u8, field_names[1], "clip")) {
            return name ++ ": the second field must be `clip: [4]f32`";
        }
        if (field_types[0] != [4]f32) return name ++ ": `rect` must be [4]f32";
        if (field_types[1] != [4]f32) return name ++ ": `clip` must be [4]f32";
        for (field_names, field_types) |field_name, field_type| {
            if (field_problem(T, field_name, field_type)) |problem| {
                return name ++ ": field `" ++ field_name ++ "` " ++ problem;
            }
        }
        if (!@hasDecl(T, "pixel")) return name ++ ": missing `pub const pixel: []const u8`";
        if (@TypeOf(T.pixel) != []const u8) return name ++ ": `pixel` must be []const u8";
        if (!@hasDecl(T, "texture")) {
            return name ++ ": missing `pub const texture: ?draw.TextureFormat`";
        }
        if (@TypeOf(T.texture) != ?textures.Format) {
            return name ++ ": `texture` must be ?draw.TextureFormat";
        }
        return null;
    }
}

fn field_problem(comptime T: type, comptime name: []const u8, comptime F: type) ?[]const u8 {
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return "shadows a prelude name";
    }
    if (F == f32) return null;
    if (F == [4]f32) {
        if (@offsetOf(T, name) % 16 != 0) return "must start on a 16-byte boundary";
        return null;
    }
    return "must be f32 or [4]f32";
}

/// Null when `entries` is a valid registry, otherwise the first problem. Pure, so `app.zig`
/// reports it as a build error and tests can check it.
pub fn validate(comptime entries: []const DrawType) ?[]const u8 {
    comptime {
        if (entries.len == 0) return "App.config.draw must list at least one draw type";
        if (entries.len > type_cap) return "App.config.draw lists more than 16 draw types";
        for (entries, 0..) |entry, index| {
            if (check(entry.type)) |message| return message;
            const name = @typeName(entry.type);
            if (entry.cap == 0) return name ++ ": cap must be at least 1";
            if (entry.cap > instance_cap_max) return name ++ ": cap must be at most 65536";
            for (entries[0..index]) |earlier| {
                if (earlier.type == entry.type) return name ++ ": registered twice";
            }
        }
        return null;
    }
}

/// The comptime tables for one app's draw types. See the module guide.
pub fn Registry(comptime entries: []const DrawType) type {
    comptime {
        if (validate(entries)) |message| @compileError(message);
    }
    return struct {
        pub const count: u32 = entries.len;

        /// The draw type with id `index`.
        pub fn Type(comptime index: u32) type {
            return entries[index].type;
        }

        /// Pool capacity of each type, by id.
        pub const caps: [count]u32 = blk: {
            var out: [count]u32 = undefined;
            for (entries, 0..) |entry, index| out[index] = entry.cap;
            break :blk out;
        };

        /// True for a type that samples a texture, by id.
        pub const textured: [count]bool = blk: {
            var out: [count]bool = undefined;
            for (entries, 0..) |entry, index| out[index] = entry.type.texture != null;
            break :blk out;
        };

        /// Assembled WGSL module of each type, by id. Static data.
        pub const sources: [count][]const u8 = blk: {
            var out: [count][]const u8 = undefined;
            for (entries, 0..) |entry, index| out[index] = source(entry.type);
            break :blk out;
        };

        /// Shader module label of each type, by id: its Zig type name.
        pub const labels: [count][]const u8 = blk: {
            var out: [count][]const u8 = undefined;
            for (entries, 0..) |entry, index| out[index] = @typeName(entry.type);
            break :blk out;
        };

        /// The id of `T`. A type missing from `App.config.draw` fails the build.
        pub fn id(comptime T: type) u8 {
            comptime {
                for (entries, 0..) |entry, index| {
                    if (entry.type == T) return index;
                }
                @compileError(@typeName(T) ++ " is not registered in App.config.draw");
            }
        }

        /// Vertex buffer 1 of type `index`: one float32x4 per group at locations 1 to N.
        pub fn vertex_layout(comptime index: u32) commands.VertexBuffer {
            return instance_layout(entries[index].type);
        }
    };
}

/// Vertex buffer 1 for `T`: one `float32x4` per 16-byte group, at locations 1 to N.
pub fn instance_layout(comptime T: type) commands.VertexBuffer {
    comptime assert(check(T) == null);
    const groups: u32 = @sizeOf(T) / 16;
    var attributes = std.mem.zeroes([commands.attribute_cap]commands.VertexAttribute);
    inline for (0..groups) |group| {
        attributes[group] = .{ .location = group + 1, .format = .float32x4, .offset = 16 * group };
    }
    const layout: commands.VertexBuffer = .{
        .stride = @sizeOf(T),
        .step = .instance,
        .attribute_count = groups,
        .attributes = attributes,
    };
    assert(layout.attribute_count >= 2);
    assert(layout.attribute_count <= group_cap);
    return layout;
}

/// The complete WGSL module for `T`, as static data. See the module guide, section 3.
pub fn source(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        assert(check(T) == null);
        var text: []const u8 = prelude ++ "\n" ++ theme_wgsl();
        if (T.texture != null) text = text ++ texture_wgsl;
        text = text ++ io_wgsl(T) ++ "\n" ++ T.pixel;
        const copy = text[0..text.len].*;
        return &copy;
    }
}

fn theme_wgsl() []const u8 {
    comptime {
        var out: []const u8 = "struct Theme {\n";
        const info = @typeInfo(theme.Theme).@"struct";
        for (info.field_names, info.field_types) |field_name, field_type| {
            assert(field_type == [4]f32);
            out = out ++ "    " ++ field_name ++ ": vec4<f32>,\n";
        }
        return out ++ "}\n";
    }
}

const texture_wgsl: []const u8 =
    \\
    \\@group(1) @binding(0) var bound_texture: texture_2d<f32>;
    \\@group(1) @binding(1) var bound_sampler: sampler;
    \\
    \\// Samples the type's texture. Call it in uniform control flow (prelude, section 3).
    \\fn sample_texture(uv: vec2<f32>) -> vec4<f32> {
    \\    return textureSample(bound_texture, bound_sampler, uv);
    \\}
    \\
;

fn io_wgsl(comptime T: type) []const u8 {
    comptime {
        const groups: u32 = @sizeOf(T) / 16;
        var instance: []const u8 = "\nstruct Instance {\n";
        var varyings: []const u8 = "struct Varyings {\n" ++
            "    @builtin(position) position: vec4<f32>,\n" ++
            "    @location(0) local: vec2<f32>,\n";
        var carry: []const u8 = "fn carry(i: Instance) -> Varyings {\n" ++
            "    var out: Varyings;\n";
        for (0..groups) |group| {
            const g = std.fmt.comptimePrint("g{d}", .{group});
            const at = std.fmt.comptimePrint("{d}", .{group + 1});
            instance = instance ++ "    @location(" ++ at ++ ") " ++ g ++ ": vec4<f32>,\n";
            varyings = varyings ++ "    @location(" ++ at ++ ") @interpolate(flat) " ++ g ++
                ": vec4<f32>,\n";
            carry = carry ++ "    out." ++ g ++ " = i." ++ g ++ ";\n";
        }
        var pixel: []const u8 = "struct Pixel {\n" ++
            "    local: vec2<f32>,\n    size: vec2<f32>,\n    pos: vec2<f32>,\n";
        var unpack: []const u8 = "fn unpack(v: Varyings) -> Pixel {\n" ++
            "    var px: Pixel;\n    px.local = v.local;\n    px.size = v.g0.zw;\n" ++
            "    px.pos = v.g0.xy + v.local;\n";
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |field_name, field_type| {
            const offset = @offsetOf(T, field_name);
            const g = std.fmt.comptimePrint("v.g{d}", .{offset / 16});
            if (field_type == [4]f32) {
                pixel = pixel ++ "    " ++ field_name ++ ": vec4<f32>,\n";
                unpack = unpack ++ "    px." ++ field_name ++ " = " ++ g ++ ";\n";
            } else {
                const lane = "xyzw"[(offset % 16) / 4 ..][0..1];
                pixel = pixel ++ "    " ++ field_name ++ ": f32,\n";
                unpack = unpack ++ "    px." ++ field_name ++ " = " ++ g ++ "." ++ lane ++ ";\n";
            }
        }
        return instance ++ "}\n\n" ++ varyings ++ "}\n\n" ++ pixel ++ "}\n\n" ++ carry ++
            "    return out;\n}\n\n" ++ unpack ++ "    return px;\n}\n";
    }
}

const testing = std.testing;

const Probe = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    tint: [4]f32,
    weight: f32,
    spread: f32,
    pad0: f32,
    pad1: f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return px.tint * px.weight;
        \\}
    ;
};

const Unaligned = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    weight: f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
};

const Straddle = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    weight: f32,
    tint: [4]f32,
    pad0: f32,
    pad1: f32,
    pad2: f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
};

const NoClip = extern struct {
    rect: [4]f32,
    tint: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
};

// Locks the generated interface: locations 1 to N in `Instance`, flat groups in `Varyings`,
// every field named in `Pixel` with its lane, the theme fields in order, and no texture
// bindings on an untextured type.
test "source declares locations 1 to N and names every field" {
    const text = comptime source(Probe);
    try testing.expect(std.mem.find(u8, text, "@location(1) g0: vec4<f32>") != null);
    try testing.expect(std.mem.find(u8, text, "@location(4) g3: vec4<f32>") != null);
    try testing.expect(std.mem.find(u8, text, "@location(5) g4") == null);
    try testing.expect(std.mem.find(u8, text, "@location(3) @interpolate(flat) g2") != null);
    try testing.expect(std.mem.find(u8, text, "px.tint = v.g2;") != null);
    try testing.expect(std.mem.find(u8, text, "px.weight = v.g3.x;") != null);
    try testing.expect(std.mem.find(u8, text, "px.spread = v.g3.y;") != null);
    try testing.expect(std.mem.find(u8, text, "px.clip = v.g1;") != null);
    try testing.expect(std.mem.find(u8, text, "bound_texture") == null);
    try testing.expect(std.mem.find(u8, text, "fn vs_main") != null);
    var cursor: usize = std.mem.find(u8, text, "struct Theme {").?;
    inline for (@typeInfo(theme.Theme).@"struct".field_names) |field_name| {
        const needle = field_name ++ ": vec4<f32>";
        cursor = std.mem.findPos(u8, text, cursor, needle).? + needle.len;
    }
    const layout = comptime instance_layout(Probe);
    try testing.expectEqual(@as(u8, 4), layout.attribute_count);
    try testing.expectEqual(@as(u16, 48), layout.attributes[3].offset);
    try testing.expectEqual(@as(u8, 4), layout.attributes[3].location);
}

// Locks the negative space of the convention: each violation is named with the type.
test "check names the type and the violation" {
    try testing.expect(comptime check(Probe) == null);
    const unaligned = comptime check(Unaligned).?;
    try testing.expect(std.mem.find(u8, unaligned, "Unaligned") != null);
    try testing.expect(std.mem.find(u8, unaligned, "multiple of 16") != null);
    const straddle = comptime check(Straddle).?;
    try testing.expect(std.mem.find(u8, straddle, "`tint`") != null);
    const no_clip = comptime check(NoClip).?;
    try testing.expect(std.mem.find(u8, no_clip, "clip") != null);
    const empty = comptime validate(&.{});
    try testing.expect(empty != null);
    const twice = comptime validate(&.{
        .{ .type = Probe, .cap = 4 },
        .{ .type = Probe, .cap = 4 },
    });
    try testing.expect(std.mem.find(u8, twice.?, "twice") != null);
    const zero = comptime validate(&.{.{ .type = Probe, .cap = 0 }});
    try testing.expect(std.mem.find(u8, zero.?, "cap") != null);
}

comptime {
    assert(group_cap * 16 <= std.math.maxInt(u16));
    assert(group_cap <= commands.attribute_cap);
    assert(type_cap <= commands.caps.get(.shader));
    assert(type_cap <= commands.caps.get(.pipeline));
    // Unit quad, uniform, and one instance buffer per type.
    assert(type_cap + 2 <= commands.caps.get(.buffer));
}

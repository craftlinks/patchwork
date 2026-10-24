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
//! A type may also declare `pub const reads_points: bool`. When it is true the type's module
//! declares the context's point buffer (`@group(0) @binding(1)`, read-only storage, vertex and
//! fragment stages) as `points: array<vec2<f32>>`, and the renderer creates that buffer and
//! binds it in the frame group, once per pass for every pipeline. A registry without such a
//! type has no point buffer at all (`uses_points`), so its apps pay nothing for paths
//! (`draw.Path`).
//!
//! All geometry is relative to `rect`: a type's parameters (radii, sweeps, UVs, the LED's
//! glow) are expressed in the quad's local space, never as absolute positions. The UI layer
//! aligns a container after its children drew by adding a delta to `rect.xy` alone
//! (`Context.shift` in `draw/pools.zig`); a type that stored an absolute coordinate elsewhere
//! would be left behind.
//!
//! ## 2b. Animated Types
//! A type may declare `pub const animated: bool`. An animated type may read the frame
//! uniform's time slot (`frame.time`, `time_seconds()`, `time_pulse(hz)`; prelude guide,
//! section 6), so its pixels change with no record change. The renderer repaints its tiles every
//! frame and keeps the host presenting while one is on screen (`draw/renderer.zig`, section
//! 4b). A type that does not declare it but names any of those in its `pixel` or `vertex` fails
//! `check`: the pixel cache would otherwise keep its first frame forever. The search is
//! textual, so a comment that names them counts too.
//!
//! ## 2c. Blending
//! A type may declare `pub const blend: draw.Blend` (default `.alpha`); `.none` is rejected,
//! because the clip mask works through alpha. Every mode blends the straight-alpha output of
//! `fs_main`, `a = color.a * clip`, and the registry generates `blend_out`, which `fs_main`
//! applies last:
//! ```text
//! alpha     out = (rgb, a)                 rgb * a + dst * (1 - a)
//! additive  out = (rgb, a)                 dst + rgb * a
//! multiply  out = (mix(1, rgb, a), a)      dst * mix(1, rgb, a)
//! ```
//! so a clipped-out pixel leaves the target unchanged in every mode. The factors are in
//! `commands.Blend`.
//!
//! ## 2a. The Vertex Contract
//! By default a type's quad is its `rect`: the shared `vs_main` places the unit quad's corner
//! `unit` (in [0, 1]^2) at `rect.xy + unit * rect.zw`. A type may instead declare
//! `pub const vertex: []const u8` holding `fn vertex(px: Pixel, unit: vec2<f32>) -> vec2<f32>`,
//! which returns the corner's local position (relative to `rect.xy`, logical pixels). `px`
//! carries every field, with `local` zero. The fragment stage is unchanged: `local` still
//! means `pos - rect.xy`, so `pixel` needs no change. The quad must cover every fragment
//! with coverage; anything it covers outside `rect` is still cut by the clip mask, and `rect`
//! stays the type's bounds for clipping, alignment shifts, and hit areas. `draw.Path` uses it
//! to rasterize a quad along each chunk's chord instead of the chunk's axis-aligned box. The
//! vertex stage has no derivatives.
//!
//! ## 3. WGSL Assembly (`source`)
//! ```text
//! prelude.wgsl                         Frame, vs_main, fs_main, coverage, sdf_*, clip_mask
//! struct Theme { ... }                 one vec4 per `theme.Theme` field, in order
//! bound_texture, bound_sampler         @group(1), textured types only, with sample_texture,
//!                                      sample_texture_level, load_texture, texture_size
//! points                               @group(0) @binding(1), `reads_points` types only
//! struct Instance { g0 .. gN-1 }       @location(1 .. N) vec4<f32>
//! struct Varyings                      position, local, and every group @interpolate(flat)
//! struct Pixel                         local, size, pos, and every Zig field by name
//! fn carry, fn unpack                  copy the groups through and name the fields
//! T.pixel                              the type's own fn pixel(px: Pixel) -> vec4<f32>
//! [T.vertex]                           the type's own fn vertex, when it declares one
//! fn vertex_local                      unit * rect.zw, or vertex(unpack(carry(i)), unit)
//! fn blend_out                         identity, or the multiply mix (section 2c)
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
        if (@hasDecl(T, "reads_points")) {
            if (@TypeOf(T.reads_points) != bool) return name ++ ": `reads_points` must be bool";
        }
        if (@hasDecl(T, "vertex")) {
            if (@TypeOf(T.vertex) != []const u8) return name ++ ": `vertex` must be []const u8";
        }
        if (@hasDecl(T, "animated")) {
            if (@TypeOf(T.animated) != bool) return name ++ ": `animated` must be bool";
        }
        if (@hasDecl(T, "blend")) {
            if (@TypeOf(T.blend) != commands.Blend) {
                return name ++ ": `blend` must be draw.Blend";
            }
            if (T.blend == .none) return name ++ ": `blend` must not be .none";
        }
        if (!animated(T) and reads_time(T)) {
            return name ++ ": reads time but does not declare `animated = true`";
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

/// True when `T` declares `reads_points = true` (module guide, section 2).
pub fn reads_points(comptime T: type) bool {
    if (comptime !@hasDecl(T, "reads_points")) return false;
    return comptime T.reads_points;
}

/// True when `T` declares `animated = true` (module guide, section 2b).
pub fn animated(comptime T: type) bool {
    if (comptime !@hasDecl(T, "animated")) return false;
    return comptime T.animated;
}

/// The blend `T` declares, `.alpha` by default (module guide, section 2c).
pub fn blend_of(comptime T: type) commands.Blend {
    if (comptime !@hasDecl(T, "blend")) return .alpha;
    return comptime T.blend;
}

/// Names in WGSL that read the time slot (prelude guide, section 6).
const time_names = [_][]const u8{ "frame.time", "time_seconds(", "time_pulse(" };

/// True when `T`'s own WGSL names the time slot or a helper that reads it.
fn reads_time(comptime T: type) bool {
    comptime {
        const vertex_len = if (@hasDecl(T, "vertex")) T.vertex.len else 0;
        @setEvalBranchQuota(1000 + 64 * time_names.len * (T.pixel.len + vertex_len));
        for (time_names) |needle| {
            if (std.mem.find(u8, T.pixel, needle) != null) return true;
            if (@hasDecl(T, "vertex") and std.mem.find(u8, T.vertex, needle) != null) return true;
        }
        return false;
    }
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

        /// True when some registered type reads the point buffer (module guide, section 2).
        pub const uses_points: bool = blk: {
            var out = false;
            for (entries) |entry| out = out or reads_points(entry.type);
            break :blk out;
        };

        /// True for an animated type, by id (module guide, section 2b).
        pub const animates: [count]bool = blk: {
            var out: [count]bool = undefined;
            for (entries, 0..) |entry, index| out[index] = animated(entry.type);
            break :blk out;
        };

        /// The blend of each type, by id (module guide, section 2c).
        pub const blends: [count]commands.Blend = blk: {
            var out: [count]commands.Blend = undefined;
            for (entries, 0..) |entry, index| out[index] = blend_of(entry.type);
            break :blk out;
        };

        /// The texture layout class of each textured type, by id; `filterable` for an
        /// untextured one, which binds no texture.
        pub const classes: [count]textures.Class = blk: {
            var out: [count]textures.Class = undefined;
            for (entries, 0..) |entry, index| {
                out[index] = if (entry.type.texture) |format|
                    textures.class_of(format)
                else
                    .filterable;
            }
            break :blk out;
        };

        /// True when some registered type is animated.
        pub const any_animated: bool = blk: {
            var out = false;
            for (entries) |entry| out = out or animated(entry.type);
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
        if (reads_points(T)) text = text ++ points_wgsl;
        text = text ++ io_wgsl(T) ++ "\n" ++ T.pixel ++ vertex_wgsl(T) ++ blend_wgsl(T);
        const copy = text[0..text.len].*;
        return &copy;
    }
}

/// The `blend_out` that `fs_main` applies (module guide, section 2c).
fn blend_wgsl(comptime T: type) []const u8 {
    return switch (comptime blend_of(T)) {
        .none => unreachable,
        .alpha, .additive, .premultiplied => "\nfn blend_out(c: vec4<f32>) -> vec4<f32> {\n" ++
            "    return c;\n}\n",
        .multiply => "\nfn blend_out(c: vec4<f32>) -> vec4<f32> {\n" ++
            "    return vec4<f32>(mix(vec3<f32>(1.0, 1.0, 1.0), c.rgb, c.a), c.a);\n}\n",
    };
}

/// The type's `vertex` and the `vertex_local` that `vs_main` calls (module guide, section 2a).
fn vertex_wgsl(comptime T: type) []const u8 {
    comptime {
        if (!@hasDecl(T, "vertex")) {
            return "\nfn vertex_local(i: Instance, unit: vec2<f32>) -> vec2<f32> {\n" ++
                "    return unit * i.g0.zw;\n}\n";
        }
        return "\n" ++ T.vertex ++
            "\nfn vertex_local(i: Instance, unit: vec2<f32>) -> vec2<f32> {\n" ++
            "    var v = carry(i);\n" ++
            "    v.local = vec2<f32>(0.0, 0.0);\n" ++
            "    return vertex(unpack(v), unit);\n}\n";
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
    \\// Samples at mip level 0, with no derivatives, so it may run under branches and in
    \\// loops of instance-dependent length.
    \\fn sample_texture_level(uv: vec2<f32>) -> vec4<f32> {
    \\    return textureSampleLevel(bound_texture, bound_sampler, uv, 0.0);
    \\}
    \\
    \\// Reads one texel, no filter and no derivatives, so it may run under branches.
    \\fn load_texture(texel: vec2<i32>) -> vec4<f32> {
    \\    return textureLoad(bound_texture, texel, 0);
    \\}
    \\
    \\fn texture_size() -> vec2<i32> {
    \\    return vec2<i32>(textureDimensions(bound_texture));
    \\}
    \\
;

const points_wgsl: []const u8 =
    \\
    \\// The draw context's points, read by `reads_points` types (module guide, section 2).
    \\@group(0) @binding(1) var<storage, read> points: array<vec2<f32>>;
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

const Turned = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
    pub const vertex: []const u8 =
        \\fn vertex(px: Pixel, unit: vec2<f32>) -> vec2<f32> {
        \\    return unit.yx * px.size;
        \\}
    ;
};

const BadVertex = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
    pub const vertex = 1;
};

const Pulsing = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const animated = true;
    pub const pixel: []const u8 =
        \\fn pixel(px: Pixel) -> vec4<f32> {
        \\    return vec4<f32>(time_pulse(1.0));
        \\}
    ;
};

const Frozen = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
    pub const vertex: []const u8 =
        \\fn vertex(px: Pixel, unit: vec2<f32>) -> vec2<f32> {
        \\    return unit * px.size * frame.time.x;
        \\}
    ;
};

const BadAnimated = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const pixel: []const u8 = "";
    pub const animated = 1;
};

const Multiplied = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = .r32float;
    pub const blend: commands.Blend = .multiply;
    pub const pixel: []const u8 = "";
};

const Unblended = extern struct {
    rect: [4]f32,
    clip: [4]f32,

    pub const texture: ?textures.Format = null;
    pub const blend: commands.Blend = .none;
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
    try testing.expect(std.mem.find(u8, text, "var<storage, read> points") == null);
    try testing.expect(comptime !reads_points(Probe));
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

// Locks the vertex contract (section 2a): a type without `vertex` gets the axis-aligned quad,
// a type with one gets it called through `carry` and `unpack`, and a mistyped one is named.
test "vertex_local is the rect quad or the type's own vertex" {
    const plain = comptime source(Probe);
    try testing.expect(std.mem.find(u8, plain, "return unit * i.g0.zw;") != null);
    try testing.expect(std.mem.find(u8, plain, "fn vertex(px: Pixel") == null);
    const turned = comptime source(Turned);
    try testing.expect(std.mem.find(u8, turned, "return unit.yx * px.size;") != null);
    try testing.expect(std.mem.find(u8, turned, "return vertex(unpack(v), unit);") != null);
    try testing.expect(std.mem.find(u8, turned, "return unit * i.g0.zw;") == null);
    try testing.expect(std.mem.find(u8, plain, "vertex_local(instance, unit)") != null);
    const bad = comptime check(BadVertex).?;
    try testing.expect(std.mem.find(u8, bad, "`vertex` must be []const u8") != null);
}

// Locks the animated declaration (section 2b): an animated type may read time, a type that
// reads time in its vertex without declaring it is rejected, and a mistyped one is named.
test "only an animated type may read time" {
    try testing.expect(comptime check(Pulsing) == null);
    try testing.expect(comptime animated(Pulsing));
    try testing.expect(comptime !animated(Probe));
    const frozen = comptime check(Frozen).?;
    try testing.expect(std.mem.find(u8, frozen, "Frozen: reads time") != null);
    const bad = comptime check(BadAnimated).?;
    try testing.expect(std.mem.find(u8, bad, "`animated` must be bool") != null);
    const Both = Registry(&.{ .{ .type = Probe, .cap = 4 }, .{ .type = Pulsing, .cap = 4 } });
    try testing.expectEqual([2]bool{ false, true }, Both.animates);
    try testing.expect(Both.any_animated);
    try testing.expect(!Registry(&.{.{ .type = Probe, .cap = 4 }}).any_animated);
}

// Locks blending and textures (sections 2c and 3): a multiply type gets the mix toward white
// as `blend_out` and the texel helpers, an alpha type the identity, `.none` is named, and the
// registry tables carry each type's blend and layout class.
test "blend_out follows the declared blend, and none is rejected" {
    const multiplied = comptime source(Multiplied);
    try testing.expect(std.mem.find(u8, multiplied, "mix(vec3<f32>(1.0, 1.0, 1.0), c.rgb") != null);
    try testing.expect(std.mem.find(u8, multiplied, "fn load_texture(texel: vec2<i32>)") != null);
    try testing.expect(std.mem.find(u8, multiplied, "fn texture_size()") != null);
    const plain = comptime source(Probe);
    try testing.expect(std.mem.find(u8, plain, "fn blend_out(c: vec4<f32>) -> vec4<f32> {\n    return c;") != null);
    try testing.expect(std.mem.find(u8, plain, "return blend_out(vec4<f32>(") != null);
    const unblended = comptime check(Unblended).?;
    try testing.expect(std.mem.find(u8, unblended, "Unblended: `blend` must not be .none") != null);
    const Both = Registry(&.{ .{ .type = Probe, .cap = 4 }, .{ .type = Multiplied, .cap = 4 } });
    try testing.expectEqual([2]commands.Blend{ .alpha, .multiply }, Both.blends);
    try testing.expectEqual([2]textures.Class{ .filterable, .unfilterable }, Both.classes);
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
    // Unit quad, uniform, the point buffer, and one instance buffer per type.
    assert(type_cap + 3 <= commands.caps.get(.buffer));
}

//! 2D instanced quads, Y-down orthographic projection, draw lists, and SDF boxes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Instanced Unit Quads Instead of Immediate Geometry
//! Nearly every UI element is an axis-aligned rectangle. Rebuilding four to six vertices per
//! rectangle on the CPU each frame costs CPU time, allocator churn, and upload bandwidth that
//! grows with the rectangle count. Instead, one static unit quad (`unit_quad`, uploaded once)
//! is expanded in the vertex shader by per-instance data held in `Instance`. The vertex fetch
//! unit advances the quad attributes per vertex and the instance attributes per instance, so a
//! whole frame of rectangles is one draw call of `vertex_count` vertices times `count`
//! instances, and only `DrawList.count` instances are ever uploaded.
//!
//! ## 2. Y-Down Orthographic Projection
//! Coordinate spaces:
//! - **UI logical pixels:** origin at the top-left of the window, `+X` right in `[0, w]`,
//!   `+Y` down in `[0, h]`.
//! - **WebGPU NDC:** `X` in `[-1, +1]` left to right, `Y` in `[-1, +1]` bottom to top (Y-up),
//!   `Z` in `[0, 1]` near to far.
//!
//! The linear maps are fixed by the corner constraints `f(0) = -1, f(w) = +1` for X and
//! `g(0) = +1, g(h) = -1` for Y (the flip), with depth pinned at `z = 0`:
//! ```text
//! X_ndc = (2 / w) * x - 1
//! Y_ndc = -(2 / h) * y + 1
//! ```
//! As a column-major 4x4 `M` applied to the column vector `[x, y, 0, 1]`, matching WGSL
//! `mat4x4<f32>` memory order, the 16 floats are written column by column:
//! ```text
//! col 0: [ 2/w,   0, 0, 0 ]      col 2: [  0, 0, 1, 0 ]
//! col 1: [   0, -2/h, 0, 0 ]     col 3: [ -1, 1, 0, 1 ]
//! ```
//! Worked values: see test "ortho maps the four corners and the center".
//!
//! ## 3. Uniform Size and the Present Header
//! The frame uniform holds the projection matrix followed by `theme.Theme`; `uniform_bytes`
//! is their sum, enforced by the `comptime` block below. WebGPU requires dynamic uniform
//! offsets to be multiples of the `minUniformBufferOffsetAlignment` limit (WebGPU "Limits"
//! table, default 256). The buffer size is kept a multiple of that limit
//! (`min_uniform_offset_alignment`) so the record stays valid if it is ever bound at an offset.
//!
//! `PresentHeader` is an `extern struct` that the host reads in place across the platform
//! boundary: native code as a Zig struct and `web/shell.js` through a `DataView` over Wasm
//! linear memory. Its size and every field offset are the ABI, enforced by `comptime` asserts
//! on `@sizeOf` and `@offsetOf`; there is no padding except the explicit `pad` field, which
//! `fill_header` writes as zero so no uninitialized bytes cross the boundary.
//!
//! ## 4. Dirty Tracking (`UploadCursor`)
//! Each GPU `writeBuffer` has driver synchronization cost, so `UploadCursor` remembers what
//! the GPU last received and `flags` reports only what changed:
//! - Unprimed cursor: upload everything (`flag_instances | flag_uniform | flag_glyphs`).
//! - `DrawList.revision` differs: `flag_instances`. `GlyphList.revision` differs: `flag_glyphs`.
//! - Logical width or height differs: `flag_uniform`, because the projection depends only on
//!   the logical size.
//! - Nothing differs, including a present that changes only the physical pixel scale: zero,
//!   so neither instance buffer is rewritten.
//! Revision counters only increase and are compared for inequality, never reset. Each
//! scenario above is locked by one of the `UploadCursor` tests at the end of this file.
//!
//! ## 5. Rounded-Box and Open-Ring Distance Fields
//! The same unit quad, draw call, and straight-alpha blend serve boxes and rings: the fragment
//! shader evaluates a signed distance (negative inside, zero on the outline, positive outside)
//! and turns it into coverage. A distance field replaces a fan of corner triangles, which
//! would need a mesh rebuild when the radius changes and would alias unless finer than a
//! pixel. The unit quad is the shape's bounding box.
//!
//! ### Instance Layout
//! `Instance` is four `float32x4` vertex attributes, in struct order, one per shader
//! location. Offsets are enforced by the `comptime` block below.
//! - Location 1, `(x, y, width, height)`: rectangle in logical pixels, top-left origin.
//! - Location 2, `(r, g, b, a)`: straight-alpha fill.
//! - Location 3, `(radius, hover, down, kind)`: `kind` is `kind_box` or `kind_arc`.
//!   For a box, `radius` is the geometric corner radius and `down` is the darken weight.
//!   For an arc, `radius` is the stroke thickness and `down` is the sweep fraction.
//!   `hover` is the lighten weight for both.
//! - Location 4, `(clip_x0, clip_y0, clip_x1, clip_y1)`: exclusive-max clip rectangle in
//!   logical pixels.
//!
//! ### Radius, Hover, and Down
//! A box radius is clamped to half the shorter edge by both `sdf_box` and the shader, so a
//! wide box becomes a capsule and a square becomes a disc. `append` rejects a negative radius
//! and stores an oversized one unchanged. `hover` and `down` are mix weights in `[0, 1]`
//! toward the theme's `lighten` and `darken` colors; for an arc, `down` instead scales
//! `theme.arc_sweep` and the shader never darkens an arc. Widgets scale their animator values
//! by `widgets.hover_lighten` and `widgets.down_darken` before writing them; this module only
//! validates the range.
//!
//! ### CPU Twins
//! `sdf_box` and `sdf_arc` are the CPU twins of the functions of the same names in
//! `quad.wgsl`, so layout and hit testing can be verified without a GPU. Tests "sdf center is
//! inside", "sdf sharp edge midpoint is on the boundary", "sdf point outside a sharp corner
//! is positive", "sdf grown radius puts a former inner corner outside", "sdf oversized radius
//! saturates into a disc", and "sdf arc locks the open ring" hold the worked values.
//!
//! ### Hard Clip Masking
//! Clipping is evaluated per fragment instead of through scissor state, so one pass and one
//! draw call survive any number of clip regions:
//! ```text
//! pos    = rect.xy + local
//! inside = step(clip.x, pos.x) * step(clip.y, pos.y) * step(pos.x, clip.z) * step(pos.y, clip.w)
//! alpha  = fill.a * coverage * inside
//! ```
//! `append` requires an exclusive-max clip (`clip_x1 > clip_x0`, `clip_y1 > clip_y0`, all
//! finite), although WGSL `step` makes the max edge inclusive. There is no unclipped sentinel:
//! unclipped content passes the window rectangle.
//!
//! ### Ownership
//! This module owns primitives, buffer layouts, and distance fields, not scene geometry.
//! Widgets append to `DrawList` and `font.GlyphList`; the application owns draw order and
//! rebuilds both lists back to front. `contains_box` is the single rounded-box point test and
//! `contains` delegates to it, so instance hit testing and widget bounds checks cannot drift.
//!
//! ## 6. TigerStyle Invariants
//! - `DrawList` is a fixed array bounded by `instance_cap`: no heap allocation, no
//!   `OutOfMemory` after startup, and `error.ListFull` instead of growth.
//! - Public functions assert their preconditions and postconditions, and layout facts are
//!   `comptime` asserts so an ABI mismatch with WGSL or the web shell fails the build.

const std = @import("std");
const assert = std.debug.assert;
const font = @import("font.zig");
const theme = @import("theme.zig");

/// WGSL source for the quad pipeline, embedded so the native and web hosts compile the same text.
pub const shader_file: []const u8 = @embedFile("quad.wgsl");

/// Hard upper bound on instances queued per frame. It bounds `DrawList.items` and the GPU
/// instance buffer, so nothing grows after startup.
pub const instance_cap: u32 = 256;

/// Byte size of one `Instance`: four `float32x4` vertex attributes. Asserted equal to
/// `@sizeOf(Instance)` and a multiple of 16 in the `comptime` block below.
pub const instance_stride: u32 = 64;

/// Box face. The fragment shader evaluates `sdf_box` and may darken by `down`.
pub const kind_box: f32 = 0;

/// Open ring. `radius` is the stroke thickness and `down` is the sweep fraction.
/// The shader does not darken an arc.
pub const kind_arc: f32 = 1;

/// Vertices in the unit quad drawn as a triangle list. Asserted equal to `unit_quad.len / 2`.
pub const vertex_count: u32 = 6;

/// Byte size of the unit quad vertex buffer. Asserted equal to `@sizeOf` of `unit_quad`.
pub const quad_bytes: u32 = 48;

/// Byte size of one `mat4x4<f32>`. Asserted equal to `@sizeOf([16]f32)`.
pub const matrix_bytes: u32 = 64;

/// WebGPU `minUniformBufferOffsetAlignment` default (WebGPU "Limits" table).
const min_uniform_offset_alignment: u32 = 256;

/// Byte size of the frame uniform: the projection matrix followed by `theme.Theme`. Asserted to
/// equal `matrix_bytes + theme.bytes` and to be a multiple of `min_uniform_offset_alignment`.
pub const uniform_bytes: u32 = 256;

/// Upload flag: the face instance buffer must be rewritten.
pub const flag_instances: u32 = 1;

/// Upload flag: the frame uniform (projection matrix and theme) must be rewritten.
pub const flag_uniform: u32 = 2;

/// Upload flag: the glyph instance buffer must be rewritten.
pub const flag_glyphs: u32 = 4;

/// Two triangles covering the unit square, as flat `[x, y]` pairs drawn as a triangle list
/// without an index buffer. The winding is clockwise on screen after the projection's Y flip,
/// which is harmless because both pipelines disable face culling.
pub const unit_quad: [12]f32 = .{
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    0.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
};

/// Per-instance parameters sent to the GPU in vertex buffer 1.
///
/// An `extern struct` so field order is the byte order, with no compiler reordering. Fields are
/// grouped as four `float32x4` attributes; see the module guide for their meaning, and the
/// `comptime` block below for the enforced offsets. Rectangle and clip are in logical pixels
/// and the fill is straight alpha. `hover` and `down` are in `[0, 1]`, and `kind` is stored
/// as a float and is `kind_box` or `kind_arc`.
pub const Instance = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    hover: f32,
    down: f32,
    kind: f32,
    clip_x0: f32,
    clip_y0: f32,
    clip_x1: f32,
    clip_y1: f32,
};

/// The frame description handed to the graphics backend, read in place by the host. See the
/// module guide for the ABI rules; field offsets are enforced by the `comptime` block below.
///
/// `width_px` and `height_px` are physical swapchain pixels. `instance_count` and
/// `glyph_count` are the number of live records, bounded by `instance_cap` and
/// `font.glyph_cap`. `flags` is a bitmask of `flag_instances`, `flag_uniform`, and
/// `flag_glyphs`. `clear_*` is the straight RGBA clear color and `ortho` is the column-major
/// projection from `ortho_y_down`. `pad` is always written as zero.
pub const PresentHeader = extern struct {
    width_px: u32,
    height_px: u32,
    instance_count: u32,
    flags: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    ortho: [16]f32,
    glyph_count: u32,
    pad: u32,
};

/// A fixed-capacity list of face instances for one frame. `revision` increases on every
/// mutation, which is what `UploadCursor` compares to decide whether to upload.
pub const DrawList = struct {
    items: [instance_cap]Instance,
    count: u32,
    revision: u32,

    /// Returns an empty list with zeroed storage.
    pub fn init() DrawList {
        const list: DrawList = .{
            .items = std.mem.zeroes([instance_cap]Instance),
            .count = 0,
            .revision = 0,
        };
        assert(list.count == 0);
        assert(list.revision == 0);
        return list;
    }

    pub const AppendError = error{
        EdgeNotPositive,
        ListFull,
        NegativeRadius,
        HoverOutOfRange,
        DownOutOfRange,
        KindUnknown,
        ClipUnordered,
    };

    /// Appends one instance, or returns the first violated precondition. Nothing is stored and
    /// `revision` is unchanged on error.
    ///
    /// - `error.EdgeNotPositive`: `width <= 0` or `height <= 0`. Layout can produce collapsed or
    ///   negative edges, and degenerate geometry must never reach the GPU.
    /// - `error.NegativeRadius`: `radius < 0`. An oversized radius is stored unchanged because
    ///   `sdf_box` and `quad.wgsl` clamp it, but a negative one would survive the clamp and
    ///   invert the field.
    /// - `error.HoverOutOfRange`, `error.DownOutOfRange`: weight outside `[0, 1]`, which would
    ///   extrapolate the shader `mix` past the lighten or darken color.
    /// - `error.KindUnknown`: `kind` is neither `kind_box` nor `kind_arc`.
    /// - `error.ClipUnordered`: the clip is non-finite or not exclusive-max.
    /// - `error.ListFull`: `count == instance_cap`.
    pub fn append(self: *DrawList, instance: Instance) AppendError!void {
        assert(self.count <= instance_cap);
        if (instance.width <= 0) {
            return error.EdgeNotPositive;
        }
        if (instance.height <= 0) {
            return error.EdgeNotPositive;
        }
        if (instance.radius < 0) {
            return error.NegativeRadius;
        }
        if (instance.hover < 0) {
            return error.HoverOutOfRange;
        }
        if (instance.hover > 1) {
            return error.HoverOutOfRange;
        }
        if (instance.down < 0) {
            return error.DownOutOfRange;
        }
        if (instance.down > 1) {
            return error.DownOutOfRange;
        }
        if (!kind_known(instance.kind)) {
            return error.KindUnknown;
        }
        if (!clip_ordered(instance)) {
            return error.ClipUnordered;
        }
        if (self.count == instance_cap) {
            return error.ListFull;
        }
        assert(instance.radius >= 0);
        assert(kind_known(instance.kind));
        self.items[self.count] = instance;
        self.count += 1;
        self.revision += 1;
        assert(self.items[self.count - 1].kind == instance.kind);
        assert(self.items[self.count - 1].clip_x1 > self.items[self.count - 1].clip_x0);
    }

    /// Writes `hover` and `down` on the live slot `index` (`index < count`). Both weights
    /// must already be in `[0, 1]`; they are asserted, not clamped.
    ///
    /// Returns false and leaves `revision` unchanged when both weights already match, so a
    /// resting pointer that hit-tests on every wake causes no upload. Returns true after
    /// storing a change and bumping `revision`.
    pub fn set_state(self: *DrawList, index: u32, hover: f32, down: f32) bool {
        assert(index < self.count);
        assert(hover >= 0);
        assert(hover <= 1);
        assert(down >= 0);
        assert(down <= 1);
        const item = &self.items[index];
        if (item.hover == hover) {
            if (item.down == down) {
                assert(self.items[index].hover == hover);
                return false;
            }
        }
        item.hover = hover;
        item.down = down;
        self.revision += 1;
        assert(self.items[index].hover == hover);
        assert(self.items[index].down == down);
        return true;
    }

    /// Empties the list. `revision` is bumped even if the list was already empty.
    pub fn clear(self: *DrawList) void {
        assert(self.count <= instance_cap);
        self.count = 0;
        self.revision += 1;
        assert(self.count == 0);
        assert(self.revision >= 1);
    }
};

/// Remembers the revisions and logical size last uploaded, so an unchanged present skips every
/// GPU buffer write. See the module guide for the flag rules.
pub const UploadCursor = struct {
    primed: bool,
    revision: u32,
    glyph_revision: u32,
    width_logical: u32,
    height_logical: u32,

    pub fn init() UploadCursor {
        const cursor: UploadCursor = .{
            .primed = false,
            .revision = 0,
            .glyph_revision = 0,
            .width_logical = 0,
            .height_logical = 0,
        };
        assert(!cursor.primed);
        assert(cursor.glyph_revision == 0);
        return cursor;
    }

    /// Returns the `flag_*` bitmask of buffers to upload for this frame. Pure: the cursor is
    /// only updated by `mark`, after the upload actually happened.
    pub fn flags(
        self: UploadCursor,
        list: *const DrawList,
        glyphs: *const font.GlyphList,
        width_logical: u32,
        height_logical: u32,
    ) u32 {
        assert(list.count <= instance_cap);
        assert(glyphs.count <= font.glyph_cap);
        if (!self.primed) {
            return flag_instances | flag_uniform | flag_glyphs;
        }
        var result: u32 = 0;
        if (self.revision != list.revision) {
            result |= flag_instances;
        }
        if (self.glyph_revision != glyphs.revision) {
            result |= flag_glyphs;
        }
        if (self.width_logical != width_logical) {
            result |= flag_uniform;
        } else if (self.height_logical != height_logical) {
            result |= flag_uniform;
        }
        return result;
    }

    /// Records that the current revisions and dimensions were uploaded.
    pub fn mark(
        self: *UploadCursor,
        list: *const DrawList,
        glyphs: *const font.GlyphList,
        width_logical: u32,
        height_logical: u32,
    ) void {
        assert(list.count <= instance_cap);
        assert(glyphs.count <= font.glyph_cap);
        assert(width_logical != 0);
        self.primed = true;
        self.revision = list.revision;
        self.glyph_revision = glyphs.revision;
        self.width_logical = width_logical;
        self.height_logical = height_logical;
        assert(self.primed);
        assert(self.height_logical != 0);
    }
};

/// Inputs to `fill_header`. `width_logical` and `height_logical` size the projection, while
/// `width_px` and `height_px` are the physical framebuffer size; both must be nonzero.
pub const HeaderOptions = struct {
    list: *const DrawList,
    glyphs: *const font.GlyphList,
    cursor: UploadCursor,
    width_logical: u32,
    height_logical: u32,
    width_px: u32,
    height_px: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
};

/// Fills every field of `header` from `options`, including the upload flags and a projection
/// built from the logical size. Does not call `UploadCursor.mark`.
pub fn fill_header(header: *PresentHeader, options: HeaderOptions) void {
    assert(options.width_px != 0);
    assert(options.height_px != 0);
    header.width_px = options.width_px;
    header.height_px = options.height_px;
    header.instance_count = options.list.count;
    header.glyph_count = options.glyphs.count;
    header.pad = 0;
    header.flags = options.cursor.flags(
        options.list,
        options.glyphs,
        options.width_logical,
        options.height_logical,
    );
    header.clear_r = options.clear_r;
    header.clear_g = options.clear_g;
    header.clear_b = options.clear_b;
    header.clear_a = options.clear_a;
    ortho_y_down(&header.ortho, options.width_logical, options.height_logical);
    assert(header.instance_count <= instance_cap);
    assert(header.glyph_count <= font.glyph_cap);
    assert(header.pad == 0);
    assert(header.ortho[0] > 0);
}

/// Writes the column-major projection from top-left, Y-down logical pixels to WebGPU NDC.
/// The derivation is in the module guide; `width` and `height` are nonzero logical pixels.
pub fn ortho_y_down(out: *[16]f32, width: u32, height: u32) void {
    assert(width != 0);
    assert(height != 0);
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    out.* = .{
        2.0 / w, 0.0,      0.0, 0.0,
        0.0,     -2.0 / h, 0.0, 0.0,
        0.0,     0.0,      1.0, 0.0,
        -1.0,    1.0,      0.0, 1.0,
    };
    assert(out[0] > 0);
    assert(out[5] < 0);
}

/// Signed distance of a rounded rectangle, negative inside and positive outside. CPU twin of
/// `sdf_box` in `quad.wgsl`; the tests named in the module guide lock the field without a GPU.
///
/// `(px, py)` is in local logical pixels with the origin at the rectangle's top-left, the space
/// the vertex shader interpolates as `unit * size`. `radius` is the geometric corner radius,
/// clamped to half the shorter edge, so oversized values give a capsule or a disc. The shader
/// derives coverage and hover from this field; this function does neither.
///
/// With `half = (width / 2, height / 2)` and `k = min(radius, min(half.x, half.y))`:
/// ```text
/// q        = abs(point - half) - (half - k)
/// distance = min(max(q.x, q.y), 0) + length(max(q, 0)) - k
/// ```
/// `q` is the offset from an inner sharp box shrunk by `k`, folded into one quadrant. The
/// first term is the inside distance to the nearest inner face, the second is the outside
/// Euclidean distance, and subtracting `k` grows the inner box back into the rounded outline.
pub fn sdf_box(px: f32, py: f32, width: f32, height: f32, radius: f32) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(radius >= 0);
    const half_w: f32 = 0.5 * width;
    const half_h: f32 = 0.5 * height;
    // Past half the shorter edge the inner box would invert and the corner circles overlap.
    const shorter: f32 = @min(half_w, half_h);
    const k: f32 = @min(radius, shorter);
    assert(k >= 0);
    assert(k <= shorter);
    const qx: f32 = @abs(px - half_w) - (half_w - k);
    const qy: f32 = @abs(py - half_h) - (half_h - k);
    const outside_x: f32 = @max(qx, 0.0);
    const outside_y: f32 = @max(qy, 0.0);
    const outside: f32 = @sqrt(outside_x * outside_x + outside_y * outside_y);
    const inside: f32 = @min(@max(qx, qy), 0.0);
    return inside + outside - k;
}

/// Signed distance of an open ring. CPU twin of `sdf_arc` in `quad.wgsl`.
///
/// `(px, py)` is in local logical pixels, origin at the face top-left, Y down. `thickness` is
/// the stroke width and `sweep_fraction` in `[0, 1]` scales `theme.arc_sweep`. Angles follow
/// the convention in `theme.zig`. Round caps fall out of measuring the distance to the swept
/// centerline, clamped at the sweep end, and subtracting half the thickness.
///
/// ```text
/// center = size * 0.5
/// p      = local - center
/// mid    = min(center.x, center.y) - thickness * 0.5
/// sweep  = sweep_fraction * arc_sweep
/// rel    = wrap(atan2(p.y, p.x) - arc_start, 0, tau)
/// ang    = min(rel, sweep)
/// dir    = (cos(arc_start + ang), sin(arc_start + ang))
/// dist   = length(p - dir * mid) - thickness * 0.5
/// ```
pub fn sdf_arc(
    px: f32,
    py: f32,
    width: f32,
    height: f32,
    thickness: f32,
    sweep_fraction: f32,
) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(thickness >= 0);
    assert(sweep_fraction >= 0);
    assert(sweep_fraction <= 1);
    const center_x: f32 = width * 0.5;
    const center_y: f32 = height * 0.5;
    const local_x = px - center_x;
    const local_y = py - center_y;
    const mid = @min(center_x, center_y) - thickness * 0.5;
    const sweep = sweep_fraction * theme.arc_sweep;
    const turned = std.math.atan2(local_y, local_x) - theme.arc_start;
    const rel = wrap_tau(turned);
    const ang = @min(rel, sweep);
    const dir_x = @cos(theme.arc_start + ang);
    const dir_y = @sin(theme.arc_start + ang);
    const dx = local_x - dir_x * mid;
    const dy = local_y - dir_y * mid;
    const dist = @sqrt(dx * dx + dy * dy) - thickness * 0.5;
    assert(dist == dist);
    assert(rel >= 0);
    return dist;
}

/// Wraps an angle into `[0, tau)`. Valid because `atan2` minus the start angle is less than
/// one turn away from that range.
fn wrap_tau(angle: f32) f32 {
    assert(angle == angle);
    const span = std.math.tau;
    var value = angle;
    if (value < 0) {
        value += span;
    }
    if (value >= span) {
        value -= span;
    }
    assert(value >= 0);
    assert(value < span);
    return value;
}

/// True when `(px, py)` lies inside the rounded rectangle, boundary included.
///
/// All values are logical pixels, top-left origin, Y down, and `(x, y)` is the rectangle's
/// top-left. `sdf_box <= 0` matches the shader's coverage of at least one half on the outline.
pub fn contains_box(
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    px: f32,
    py: f32,
) bool {
    assert(width > 0);
    assert(height > 0);
    assert(radius >= 0);
    if (px < x) {
        return false;
    }
    if (px > x + width) {
        return false;
    }
    if (py < y) {
        return false;
    }
    if (py > y + height) {
        return false;
    }
    const dist = sdf_box(px - x, py - y, width, height, radius);
    assert(dist == dist);
    return dist <= 0;
}

/// True when `(x, y)` lies inside `instance`'s rounded face, inclusive of the boundary.
/// Delegates to `contains_box` so a widget rect and an instance of that rect agree.
pub fn contains(instance: Instance, x: f32, y: f32) bool {
    assert(instance.width > 0);
    assert(instance.height > 0);
    assert(instance.radius >= 0);
    const hit = contains_box(
        instance.x,
        instance.y,
        instance.width,
        instance.height,
        instance.radius,
        x,
        y,
    );
    assert(instance.kind == instance.kind);
    return hit;
}

fn kind_known(kind: f32) bool {
    if (kind == kind_box) {
        assert(kind == kind_box);
        return true;
    }
    if (kind == kind_arc) {
        assert(kind == kind_arc);
        return true;
    }
    return false;
}

fn finite_f32(value: f32) bool {
    if (value != value) {
        return false;
    }
    if (std.math.isInf(value)) {
        return false;
    }
    assert(value == value);
    return true;
}

fn clip_ordered(instance: Instance) bool {
    if (!finite_f32(instance.clip_x0)) {
        return false;
    }
    if (!finite_f32(instance.clip_y0)) {
        return false;
    }
    if (!finite_f32(instance.clip_x1)) {
        return false;
    }
    if (!finite_f32(instance.clip_y1)) {
        return false;
    }
    if (!(instance.clip_x1 > instance.clip_x0)) {
        return false;
    }
    if (!(instance.clip_y1 > instance.clip_y0)) {
        return false;
    }
    assert(instance.clip_x1 > instance.clip_x0);
    assert(instance.clip_y1 > instance.clip_y0);
    return true;
}

/// Test construction record. Omitted `kind` is a box. Omitted clip is `(0, 0, 1, 1)`.
const Face = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    radius: f32,
    hover: f32,
    down: f32,
    kind: f32 = kind_box,
    clip_x0: f32 = 0,
    clip_y0: f32 = 0,
    clip_x1: f32 = 1,
    clip_y1: f32 = 1,
};

fn face(spec: Face) Instance {
    const instance: Instance = .{
        .x = spec.x,
        .y = spec.y,
        .width = spec.width,
        .height = spec.height,
        .r = spec.r,
        .g = spec.g,
        .b = spec.b,
        .a = spec.a,
        .radius = spec.radius,
        .hover = spec.hover,
        .down = spec.down,
        .kind = spec.kind,
        .clip_x0 = spec.clip_x0,
        .clip_y0 = spec.clip_y0,
        .clip_x1 = spec.clip_x1,
        .clip_y1 = spec.clip_y1,
    };
    assert(instance.down >= 0);
    assert(instance.kind == spec.kind);
    return instance;
}

comptime {
    // The `extern struct` layouts below are an ABI shared with WGSL vertex attributes and with
    // the web shell's `DataView`, so a field reorder must fail the build, not the GPU.
    assert(@sizeOf(Instance) == 64);
    assert(@alignOf(Instance) >= 4);
    assert(instance_stride == @sizeOf(Instance));
    // One float32x4 attribute per 16 bytes: rect, fill, shape, clip.
    assert(instance_stride % 16 == 0);
    assert(@offsetOf(Instance, "x") == 0);
    assert(@offsetOf(Instance, "r") == 16);
    assert(@offsetOf(Instance, "radius") == 32);
    assert(@offsetOf(Instance, "kind") == 44);
    assert(@offsetOf(Instance, "clip_x0") == 48);
    assert(kind_box == 0);
    assert(kind_arc == 1);

    assert(@sizeOf(PresentHeader) == 104);
    assert(@offsetOf(PresentHeader, "width_px") == 0);
    assert(@offsetOf(PresentHeader, "height_px") == 4);
    assert(@offsetOf(PresentHeader, "instance_count") == 8);
    assert(@offsetOf(PresentHeader, "flags") == 12);
    assert(@offsetOf(PresentHeader, "clear_r") == 16);
    assert(@offsetOf(PresentHeader, "ortho") == 32);
    assert(@offsetOf(PresentHeader, "glyph_count") == 96);
    assert(@offsetOf(PresentHeader, "pad") == 100);

    // Flags are disjoint bits so they can be OR-ed and tested independently.
    assert(flag_instances == 1);
    assert(flag_uniform == 2);
    assert(flag_glyphs == 4);

    assert(quad_bytes == @sizeOf(@TypeOf(unit_quad)));
    assert(unit_quad.len == 2 * vertex_count);
    assert(matrix_bytes == @sizeOf([16]f32));
    assert(theme.bytes + matrix_bytes == uniform_bytes);
    assert(uniform_bytes % min_uniform_offset_alignment == 0);
    assert(shader_file.len >= 1);

    // The relations above hold for any consistent change; these pin the values the web shell
    // and the hosts hard-code, so changing one without the others fails the build.
    assert(quad_bytes == 48);
    assert(vertex_count == 6);
    assert(matrix_bytes == 64);
    assert(uniform_bytes == 256);
}

comptime {
    // `glyph.wgsl` reads `font.Glyph` through the same attribute locations and 64-byte stride
    // as `quad.wgsl` reads `Instance`: rect at 0, uv rect at 16, color at 32, clip at 48. The
    // clip offset is also shared with `Instance` so both shaders mask identically.
    assert(font.glyph_stride == instance_stride);
    assert(@offsetOf(font.Glyph, "x") == 0);
    assert(@offsetOf(font.Glyph, "u0") == 16);
    assert(@offsetOf(font.Glyph, "r") == 32);
    assert(@offsetOf(font.Glyph, "clip_x0") == @offsetOf(Instance, "clip_x0"));
}

fn project(matrix: [16]f32, x: f32, y: f32) [2]f32 {
    const nx = matrix[0] * x + matrix[4] * y + matrix[12];
    const ny = matrix[1] * x + matrix[5] * y + matrix[13];
    return .{ nx, ny };
}

fn rect(width: f32, height: f32) Instance {
    const instance = face(.{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .radius = 0,
        .hover = 0,
        .down = 0,
    });
    assert(instance.down == 0);
    assert(instance.kind == kind_box);
    return instance;
}

// Locks the projection: the four logical corners map to the NDC corners with Y flipped, and the
// center maps to the origin.
test "ortho maps the four corners and the center" {
    var matrix: [16]f32 = undefined;
    ortho_y_down(&matrix, 200, 100);
    const top_left = project(matrix, 0, 0);
    const top_right = project(matrix, 200, 0);
    const bottom_left = project(matrix, 0, 100);
    const bottom_right = project(matrix, 200, 100);
    const center = project(matrix, 100, 50);
    try std.testing.expectApproxEqAbs(@as(f32, -1), top_left[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_left[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_right[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), top_right[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_left[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_left[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), bottom_right[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), bottom_right[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), center[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), center[1], 0.0001);
}

// Locks that `append` preserves insertion order and counts each instance.
test "append keeps order" {
    var list = DrawList.init();
    try list.append(face(.{
        .x = 1,
        .y = 2,
        .width = 3,
        .height = 4,
        .r = 1,
        .g = 0,
        .b = 0,
        .a = 1,
        .radius = 0,
        .hover = 0,
        .down = 0,
    }));
    try list.append(face(.{
        .x = 5,
        .y = 6,
        .width = 7,
        .height = 8,
        .r = 0,
        .g = 1,
        .b = 0,
        .a = 1,
        .radius = 0,
        .hover = 0,
        .down = 0,
    }));
    try std.testing.expectEqual(@as(u32, 2), list.count);
    try std.testing.expectEqual(@as(f32, 1), list.items[0].x);
    try std.testing.expectEqual(@as(f32, 5), list.items[1].x);
}

// Locks that a zero width or height is rejected without storing anything.
test "a zero edge is rejected" {
    var list = DrawList.init();
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(0, 10)));
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(10, 0)));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that a negative width or height is rejected without storing anything.
test "a negative edge is rejected" {
    var list = DrawList.init();
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(-1, 10)));
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(10, -1)));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that a negative radius is rejected without storing anything.
test "negative radius is rejected" {
    var list = DrawList.init();
    var instance = rect(10, 10);
    instance.radius = -1;
    try std.testing.expectError(error.NegativeRadius, list.append(instance));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that a `hover` weight outside [0, 1] returns `HoverOutOfRange` and stores nothing.
test "hover outside 0 to 1 is rejected" {
    var list = DrawList.init();
    var low = rect(10, 10);
    low.hover = -0.1;
    try std.testing.expectError(error.HoverOutOfRange, list.append(low));
    var high = rect(10, 10);
    high.hover = 1.1;
    try std.testing.expectError(error.HoverOutOfRange, list.append(high));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that `append` stores both known kinds and their `down` meaning unchanged.
test "append stores box and arc kinds" {
    var list = DrawList.init();
    var box = rect(10, 10);
    box.down = 0.25;
    box.kind = kind_box;
    try list.append(box);
    var arc = rect(10, 10);
    arc.kind = kind_arc;
    arc.down = 1;
    try list.append(arc);
    try std.testing.expectEqual(kind_box, list.items[0].kind);
    try std.testing.expectEqual(@as(f32, 0.25), list.items[0].down);
    try std.testing.expectEqual(kind_arc, list.items[1].kind);
    try std.testing.expectEqual(@as(f32, 1), list.items[1].down);
}

// Locks that a kind other than `kind_box` or `kind_arc` returns `KindUnknown`.
test "an unknown kind is rejected" {
    var list = DrawList.init();
    var instance = rect(10, 10);
    instance.kind = 2;
    try std.testing.expectError(error.KindUnknown, list.append(instance));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that an empty or reversed clip on either axis returns `ClipUnordered`.
test "a reversed clip is rejected" {
    var list = DrawList.init();
    var instance = rect(10, 10);
    instance.clip_x0 = 4;
    instance.clip_x1 = 4;
    try std.testing.expectError(error.ClipUnordered, list.append(instance));
    instance = rect(10, 10);
    instance.clip_y1 = -1;
    try std.testing.expectError(error.ClipUnordered, list.append(instance));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that a `down` weight outside [0, 1] returns `DownOutOfRange` and stores nothing.
test "down outside 0 to 1 is rejected" {
    var list = DrawList.init();
    var low = rect(10, 10);
    low.down = -0.1;
    try std.testing.expectError(error.DownOutOfRange, list.append(low));
    var high = rect(10, 10);
    high.down = 1.1;
    try std.testing.expectError(error.DownOutOfRange, list.append(high));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

// Locks that matching weights return false and leave `revision` alone, so no upload follows.
test "set_state leaves the revision when the weights match" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const revision = list.revision;
    try std.testing.expect(!list.set_state(0, 0, 0));
    try std.testing.expectEqual(revision, list.revision);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].down);
}

// Locks that a changed weight returns true and bumps `revision` by exactly one.
test "set_state bumps the revision when a weight changes" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const revision = list.revision;
    try std.testing.expect(list.set_state(0, 0.18, 0.30));
    try std.testing.expectEqual(revision + 1, list.revision);
    try std.testing.expectEqual(@as(f32, 0.18), list.items[0].hover);
    try std.testing.expectEqual(@as(f32, 0.30), list.items[0].down);
}

// Locks that a sharp box includes its edges and a rounded box rejects the pixel just inside
// its corner, where the box covers the point but the quarter circle does not.
test "contains accepts the sharp edge and rejects a rounded corner" {
    const sharp = rect(20, 10);
    try std.testing.expect(contains(sharp, 10, 0));
    try std.testing.expect(contains(sharp, 0, 5));
    try std.testing.expect(!contains(sharp, -1, 5));
    // A pill: the radius is half the height, so the (x + 1, y + 1) pixel is outside the cap and
    // (1144, 680) is the rectangle center.
    const footer = face(.{
        .x = 1024,
        .y = 656,
        .width = 240,
        .height = 48,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .radius = 24,
        .hover = 0,
        .down = 0,
    });
    try std.testing.expect(contains(footer, 1144, 680));
    try std.testing.expect(!contains(footer, 1025, 657));
    try std.testing.expect(contains_box(1024, 656, 240, 48, 24, 1144, 680));
    try std.testing.expect(!contains_box(1024, 656, 240, 48, 24, 1025, 657));
}

// Locks the capacity bound: the append after `instance_cap` returns `ListFull`.
test "a full list rejects the next append" {
    var list = DrawList.init();
    var index: u32 = 0;
    while (index < instance_cap) : (index += 1) {
        try list.append(rect(1, 1));
    }
    try std.testing.expectError(error.ListFull, list.append(rect(1, 1)));
    try std.testing.expectEqual(instance_cap, list.count);
}

// Locks that `clear` zeroes the count and bumps `revision` by exactly one.
test "clear zeros the count and bumps the revision" {
    var list = DrawList.init();
    try list.append(rect(1, 1));
    const revision = list.revision;
    list.clear();
    try std.testing.expectEqual(@as(u32, 0), list.count);
    try std.testing.expectEqual(revision + 1, list.revision);
}

// Locks the interior: the center of a sharp 20 by 10 box is half the shorter side inside.
test "sdf center is inside" {
    const dist = sdf_box(10, 5, 20, 10, 0);
    try std.testing.expect(dist < 0);
    try std.testing.expectApproxEqAbs(@as(f32, -5), dist, 0.0001);
}

// Locks that the midpoint of a box edge is on the outline.
test "sdf sharp edge midpoint is on the boundary" {
    const dist = sdf_box(10, 0, 20, 10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dist, 0.0001);
}

// Locks the exterior corner: one pixel out on both axes is sqrt(2) away from the corner.
test "sdf point outside a sharp corner is positive" {
    const dist = sdf_box(-1, -1, 20, 10, 0);
    try std.testing.expect(dist > 0);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 2)), dist, 0.0001);
}

// Locks that growing the radius moves a pixel next to the corner from inside to outside.
test "sdf grown radius puts a former inner corner outside" {
    const sharp = sdf_box(0.5, 0.5, 20, 20, 0);
    const rounded = sdf_box(0.5, 0.5, 20, 20, 8);
    try std.testing.expect(sharp < 0);
    try std.testing.expect(rounded > 0);
}

// Locks the ring: on a 56 by 56 face with thickness 4, the start-cap center is half the stroke
// inside, the face center is `mid - thickness / 2` outside, a point on the mid radius at 6
// o'clock lies in the gap, and a zero sweep leaves only the cap at the start.
test "sdf arc locks the open ring" {
    const size: f32 = 56;
    const thickness: f32 = 4;
    const mid: f32 = size * 0.5 - thickness * 0.5;
    const start_x = size * 0.5 + @cos(theme.arc_start) * mid;
    const start_y = size * 0.5 + @sin(theme.arc_start) * mid;
    try std.testing.expectApproxEqAbs(@as(f32, 15), start_x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.51666), start_y, 0.001);
    const at_start = sdf_arc(start_x, start_y, size, size, thickness, 1);
    const at_center = sdf_arc(28, 28, size, size, thickness, 1);
    try std.testing.expectApproxEqAbs(@as(f32, -2), at_start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), at_center, 0.0001);
    const six = sdf_arc(28, 28 + mid, size, size, thickness, 1);
    try std.testing.expect(six > 0);
    const cap = sdf_arc(start_x, start_y, size, size, thickness, 0);
    try std.testing.expectApproxEqAbs(@as(f32, -2), cap, 0.0001);
    const away = sdf_arc(28, 28, size, size, thickness, 0);
    try std.testing.expect(away > 0);
}

// Locks the radius clamp: a 20 by 20 box with an oversized radius is a disc of diameter 20.
test "sdf oversized radius saturates into a disc" {
    const center = sdf_box(10, 10, 20, 20, 100);
    const edge = sdf_box(10, 0, 20, 20, 100);
    const corner = sdf_box(0, 0, 20, 20, 100);
    try std.testing.expectApproxEqAbs(@as(f32, -10), center, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), edge, 0.0001);
    try std.testing.expect(corner > 0);
}

// Locks that an unprimed cursor requests every upload, so the first frame is complete.
test "the first present uploads instances and the uniform" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const glyphs = font.GlyphList.init();
    const cursor = UploadCursor.init();
    const flags = cursor.flags(&list, &glyphs, 1280, 720);
    try std.testing.expectEqual(flag_instances | flag_uniform | flag_glyphs, flags);
}

// Locks that a primed cursor with a changed face revision requests only `flag_instances`.
test "a revision change uploads instances" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const glyphs = font.GlyphList.init();
    var cursor = UploadCursor.init();
    cursor.mark(&list, &glyphs, 1280, 720);
    list.clear();
    try list.append(face(.{
        .x = 8,
        .y = 8,
        .width = 16,
        .height = 16,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .radius = 0,
        .hover = 0,
        .down = 0,
    }));
    const flags = cursor.flags(&list, &glyphs, 1280, 720);
    try std.testing.expectEqual(flag_instances, flags);
}

// Locks that a primed cursor with a changed logical width requests only `flag_uniform`.
test "a logical size change uploads the uniform" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const glyphs = font.GlyphList.init();
    var cursor = UploadCursor.init();
    cursor.mark(&list, &glyphs, 1280, 720);
    const flags = cursor.flags(&list, &glyphs, 800, 720);
    try std.testing.expectEqual(flag_uniform, flags);
}

// Locks that identical revisions and logical size request no upload, even if the physical
// pixel scale changed.
test "a scale-style present with the same logical size uploads nothing" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const glyphs = font.GlyphList.init();
    var cursor = UploadCursor.init();
    cursor.mark(&list, &glyphs, 800, 600);
    const flags = cursor.flags(&list, &glyphs, 800, 600);
    try std.testing.expectEqual(@as(u32, 0), flags);
}

// Locks that a primed cursor with a changed glyph revision requests only `flag_glyphs`.
test "a glyph revision change uploads glyphs" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    var glyphs = font.GlyphList.init();
    var cursor = UploadCursor.init();
    cursor.mark(&list, &glyphs, 1280, 720);
    glyphs.clear();
    const flags = cursor.flags(&list, &glyphs, 1280, 720);
    try std.testing.expectEqual(flag_glyphs, flags);
}

// Locks the Zig-to-WGSL contract that `comptime` cannot see: both shaders declare `Theme` with
// the fields of `theme.Theme` in order, and the vertex inputs use the locations the layouts
// in this module and `font.Glyph` assume.
test "wgsl declarations match the Zig layouts" {
    const sources = [_][]const u8{ shader_file, font.shader_file };
    for (sources) |source| {
        const start = std.mem.indexOf(u8, source, "struct Theme {").?;
        const end = std.mem.indexOfPos(u8, source, start, "}").?;
        const block = source[start..end];
        var cursor: usize = 0;
        inline for (@typeInfo(theme.Theme).@"struct".fields) |field| {
            const needle = field.name ++ ": vec4<f32>";
            const at = std.mem.indexOfPos(u8, block, cursor, needle).?;
            cursor = at + needle.len;
        }
        try std.testing.expectEqual(
            @as(usize, theme.slot_count),
            std.mem.count(u8, block, ": vec4<f32>"),
        );
        const ortho_at = std.mem.indexOfPos(u8, source, end, "ortho: mat4x4<f32>").?;
        const theme_at = std.mem.indexOfPos(u8, source, end, "theme: Theme,").?;
        try std.testing.expect(ortho_at < theme_at);
    }
    const quad_inputs = [_][]const u8{
        "@location(1) rect: vec4<f32>",
        "@location(2) fill: vec4<f32>",
        "@location(3) shape: vec4<f32>",
        "@location(4) bounds: vec4<f32>",
    };
    for (quad_inputs) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, shader_file, needle) != null);
    }
    const glyph_inputs = [_][]const u8{
        "@location(1) rect: vec4<f32>",
        "@location(2) uv_rect: vec4<f32>",
        "@location(3) color: vec4<f32>",
        "@location(4) bounds: vec4<f32>",
    };
    for (glyph_inputs) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, font.shader_file, needle) != null);
    }
}

//! 2D Instanced Quad Rendering and Draw List Management.
//!
//! # Concepts for Novices:
//!
//! ## 1. Why Instanced Unit Quads?
//! In a typical graphical user interface (buttons, panels, borders, badges, scrollbars),
//! almost every primitive is a rectangle. Traditional 3D graphics draws geometry by defining
//! vertex meshes (e.g. 4 vertices and 6 indices per rectangle). If a UI has 1,000 rectangles,
//! computing and uploading 4,000 vertices every frame consumes CPU time and PCIe bus bandwidth.
//!
//! Instead, modern UI engines like Makepad use **GPU Hardware Instancing**:
//! - We upload **one** static "unit quad" of 6 vertices representing a 1x1 square
//!   `(0,0)` to `(1,1)` into GPU memory once at startup (48 bytes total).
//! - We pass a compact array of per-rectangle parameters called **instances**
//!   (`[x, y, w, h, r, g, b, a]`).
//! - With a single draw call `draw(6, instance_count)`, the GPU duplicates the unit quad
//!   for every instance, running the vertex shader to scale and translate each rectangle.
//!
//! ## 2. Coordinate Spaces and the Orthographic Matrix
//! - **UI Coordinate Space:** Programmers reason about 2D layouts using pixels:
//!   - Origin `(0, 0)` is at the top-left of the window.
//!   - `+X` goes rightwards.
//!   - `+Y` goes downwards (Y-down).
//! - **Normalized Device Coordinates (NDC):** Modern graphics APIs (WebGPU, Vulkan, DirectX)
//!   expect vertex positions in a normalized clip cube:
//!   - Center of the screen is `(0, 0)`.
//!   - Left edge is `-1.0`, right edge is `+1.0`.
//!   - Bottom edge is `-1.0`, top edge is `+1.0` (Y-up!).
//!
//! An **orthographic projection matrix** performs the linear transformation that maps
//! pixel coordinates `[0, width]` and `[0, height]` directly into NDC `[-1, 1]`, flipping
//! the vertical axis so Y points downwards naturally.
//!
//! ## 3. TigerStyle Design Rules
//! - **No Heap Allocation:** The draw list has a fixed capacity (`instance_cap = 256`).
//! - **Bounded & Asserted:** Preconditions and postconditions are asserted on all operations.
//! - **Dirty Tracking:** `UploadCursor` tracks whether the draw list or window dimensions
//!   have changed, avoiding redundant GPU buffer uploads when re-rendering.

const std = @import("std");
const assert = std.debug.assert;

/// The WebGPU Shading Language source embedded directly into the binary at compile time.
/// Both native Linux (via wgpu-native) and the browser (via WebAssembly) compile this same source.
pub const shader_file: []const u8 = @embedFile("quad.wgsl");

/// Hard upper bound on how many rectangle instances can be queued in one draw call.
/// In TigerStyle, all buffer sizes are statically bounded at compile time.
pub const instance_cap: u32 = 256;

/// Byte size of a single instance record in memory (8 floats * 4 bytes = 32 bytes).
pub const instance_stride: u32 = 32;

/// Number of vertices in a quad drawn as a triangle list (2 triangles * 3 vertices = 6).
pub const vertex_count: u32 = 6;

/// Byte size of the unit quad vertex buffer (12 floats * 4 bytes = 48 bytes).
pub const quad_bytes: u32 = 48;

/// Byte size of a 4x4 float32 matrix (16 floats * 4 bytes = 64 bytes).
pub const matrix_bytes: u32 = 64;

/// WebGPU specification rule: Uniform buffer bindings must be aligned to at least 256 bytes.
/// Even though our 4x4 matrix is only 64 bytes, its GPU buffer must be at least 256 bytes.
pub const uniform_bytes: u32 = 256;

/// Upload flag indicating that the instance vertex buffer needs to be written to GPU memory.
pub const flag_instances: u32 = 1;

/// Upload flag indicating that the orthographic matrix uniform buffer needs to be written to GPU.
pub const flag_uniform: u32 = 2;

/// Two triangles that make up the unit square `(0,0)` to `(1,1)` in counter-clockwise order.
/// Laid out as flat 2D points: `[x0, y0, x1, y1, ...]`.
/// No index buffer is required because the 6 vertices are drawn as a triangle list.
pub const unit_quad: [12]f32 = .{
    0.0, 0.0, // Triangle 1: top-left
    1.0, 0.0, // Triangle 1: top-right
    1.0, 1.0, // Triangle 1: bottom-right
    0.0, 0.0, // Triangle 2: top-left
    1.0, 1.0, // Triangle 2: bottom-right
    0.0, 1.0, // Triangle 2: bottom-left
};

/// Per-instance parameters sent to the GPU in Vertex Buffer 1.
/// Marked as `extern struct` to guarantee exact C ABI memory layout with no compiler reordering.
pub const Instance = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// The binary header passed to the graphics backend before rendering a frame.
/// In WebAssembly, this exact struct is constructed on the Zig call stack and read by
/// JavaScript via a typed `DataView` over Wasm linear memory.
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
};

/// A fixed-capacity list of rectangle instances to be drawn in a frame.
/// Follows TigerStyle: zero dynamic heap allocation, bounded by `instance_cap`.
pub const DrawList = struct {
    items: [instance_cap]Instance,
    count: u32,
    revision: u32,

    /// Initializes an empty draw list with zeroed memory.
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

    pub const AppendError = error{ ZeroEdge, ListFull };

    /// Appends a new rectangle instance to the draw list.
    /// Rejects zero-width or zero-height rectangles, and enforces the compile-time capacity.
    /// Increments the revision counter so the GPU upload cursor detects the change.
    pub fn append(self: *DrawList, instance: Instance) AppendError!void {
        assert(self.count <= instance_cap);
        if (instance.width == 0) {
            return error.ZeroEdge;
        }
        if (instance.height == 0) {
            return error.ZeroEdge;
        }
        if (self.count == instance_cap) {
            return error.ListFull;
        }
        self.items[self.count] = instance;
        self.count += 1;
        self.revision += 1;
        assert(self.count >= 1);
        assert(self.revision >= 1);
    }

    /// Clears the draw list for the next frame, bumping the revision counter.
    pub fn clear(self: *DrawList) void {
        assert(self.count <= instance_cap);
        self.count = 0;
        self.revision += 1;
        assert(self.count == 0);
        assert(self.revision >= 1);
    }
};

/// Remembers the last uploaded revision and logical window dimensions.
/// This prevents redundant GPU queue writes: if neither the draw list contents nor
/// the window dimensions changed, the present call skips writing to the GPU buffers.
pub const UploadCursor = struct {
    primed: bool,
    revision: u32,
    width_logical: u32,
    height_logical: u32,

    pub fn init() UploadCursor {
        const cursor: UploadCursor = .{
            .primed = false,
            .revision = 0,
            .width_logical = 0,
            .height_logical = 0,
        };
        assert(!cursor.primed);
        assert(cursor.revision == 0);
        return cursor;
    }

    /// Computes the bitmask of buffers that need to be uploaded to the GPU.
    /// If unprimed (first frame), both instances and uniform matrix must be uploaded.
    pub fn flags(
        self: UploadCursor,
        list: *const DrawList,
        width_logical: u32,
        height_logical: u32,
    ) u32 {
        assert(list.count <= instance_cap);
        if (!self.primed) {
            return flag_instances | flag_uniform;
        }
        var result: u32 = 0;
        if (self.revision != list.revision) {
            result |= flag_instances;
        }
        if (self.width_logical != width_logical) {
            result |= flag_uniform;
        } else if (self.height_logical != height_logical) {
            result |= flag_uniform;
        }
        return result;
    }

    /// Records that the current revision and dimensions were successfully uploaded to the GPU.
    pub fn mark(
        self: *UploadCursor,
        list: *const DrawList,
        width_logical: u32,
        height_logical: u32,
    ) void {
        assert(list.count <= instance_cap);
        assert(width_logical != 0);
        self.primed = true;
        self.revision = list.revision;
        self.width_logical = width_logical;
        self.height_logical = height_logical;
        assert(self.primed);
        assert(self.height_logical != 0);
    }
};

pub const HeaderOptions = struct {
    list: *const DrawList,
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

/// Populates a `PresentHeader` for presentation.
/// Computes upload flags, stores pixel/instance counts, and generates the projection matrix.
pub fn fill_header(header: *PresentHeader, options: HeaderOptions) void {
    assert(options.width_px != 0);
    assert(options.height_px != 0);
    header.width_px = options.width_px;
    header.height_px = options.height_px;
    header.instance_count = options.list.count;
    header.flags = options.cursor.flags(
        options.list,
        options.width_logical,
        options.height_logical,
    );
    header.clear_r = options.clear_r;
    header.clear_g = options.clear_g;
    header.clear_b = options.clear_b;
    header.clear_a = options.clear_a;
    ortho_y_down(&header.ortho, options.width_logical, options.height_logical);
    assert(header.instance_count <= instance_cap);
    assert(header.ortho[0] > 0);
}

/// Generates a 4x4 column-major orthographic projection matrix for a top-left origin, Y-down UI.
///
/// Matrix Layout (column-major):
/// ```
/// | 2/w   0     0  -1 |   [x]   [ (2*x)/w - 1 ] -> NDC X in [-1, +1]
/// |  0  -2/h    0   1 | * [y] = [ 1 - (2*y)/h ] -> NDC Y in [+1, -1] (flipped!)
/// |  0    0     1   0 |   [0]   [      0      ] -> NDC Z in [0, 1]
/// |  0    0     0   1 |   [1]   [      1      ] -> W
/// ```
/// - When x = 0:       (2*0)/w - 1 = -1 (left edge)
/// - When x = w:       (2*w)/w - 1 = +1 (right edge)
/// - When y = 0:       1 - (2*0)/h = +1 (top edge in NDC)
/// - When y = h:       1 - (2*h)/h = -1 (bottom edge in NDC)
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

/// Populates the draw list with a 16x16 grid demo (256 instances, 100% buffer capacity).
/// Illustrates coordinate placement, color gradients, and alpha transparency blending.
pub fn demo(list: *DrawList) void {
    assert(list.count == 0);
    const cols: u32 = 16;
    const rows: u32 = 16;
    assert(cols * rows == instance_cap);
    assert(instance_cap <= 256);

    const x_start: f32 = 132.0;
    const y_start: f32 = 44.0;
    const tile_w: f32 = 56.0;
    const tile_h: f32 = 32.0;
    const gap_x: f32 = 8.0;
    const gap_y: f32 = 8.0;

    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const col_f: f32 = @floatFromInt(col);
            const row_f: f32 = @floatFromInt(row);
            const x: f32 = x_start + col_f * (tile_w + gap_x);
            const y: f32 = y_start + row_f * (tile_h + gap_y);
            const r: f32 = 0.15 + 0.80 * (col_f / 15.0);
            const g: f32 = 0.20 + 0.75 * (row_f / 15.0);
            const b: f32 = 0.20 + 0.75 * ((15.0 - col_f) / 15.0);
            const a: f32 = 0.35 + 0.65 * ((col_f + row_f) / 30.0);

            list.append(.{
                .x = x,
                .y = y,
                .width = tile_w,
                .height = tile_h,
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            }) catch unreachable;
        }
    }
    assert(list.count == instance_cap);
    assert(list.revision == instance_cap);
}

comptime {
    // Assert struct sizes and alignments to prevent C ABI mismatches across compilers.
    assert(@sizeOf(Instance) == 32);
    assert(@alignOf(Instance) >= 4);
    assert(instance_stride == 32);
    assert(instance_stride % 16 == 0);
    assert(@sizeOf(PresentHeader) == 96);
    assert(quad_bytes == 48);
    assert(unit_quad.len == 12);
    assert(vertex_count == 6);
    assert(shader_file.len >= 1);
    assert(uniform_bytes == 256);
    assert(matrix_bytes == 64);
}

fn project(matrix: [16]f32, x: f32, y: f32) [2]f32 {
    const nx = matrix[0] * x + matrix[4] * y + matrix[12];
    const ny = matrix[1] * x + matrix[5] * y + matrix[13];
    return .{ nx, ny };
}

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

test "append keeps order" {
    var list = DrawList.init();
    try list.append(.{ .x = 1, .y = 2, .width = 3, .height = 4, .r = 1, .g = 0, .b = 0, .a = 1 });
    try list.append(.{ .x = 5, .y = 6, .width = 7, .height = 8, .r = 0, .g = 1, .b = 0, .a = 1 });
    try std.testing.expectEqual(@as(u32, 2), list.count);
    try std.testing.expectEqual(@as(f32, 1), list.items[0].x);
    try std.testing.expectEqual(@as(f32, 5), list.items[1].x);
}

test "zero edge is rejected" {
    var list = DrawList.init();
    try std.testing.expectError(error.ZeroEdge, list.append(.{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 10,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
    }));
    try std.testing.expectError(error.ZeroEdge, list.append(.{
        .x = 0,
        .y = 0,
        .width = 10,
        .height = 0,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
    }));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

test "a full list rejects the next append" {
    var list = DrawList.init();
    var index: u32 = 0;
    while (index < instance_cap) : (index += 1) {
        try list.append(.{
            .x = 0,
            .y = 0,
            .width = 1,
            .height = 1,
            .r = 1,
            .g = 1,
            .b = 1,
            .a = 1,
        });
    }
    try std.testing.expectError(error.ListFull, list.append(.{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
    }));
    try std.testing.expectEqual(instance_cap, list.count);
}

test "clear zeros the count and bumps the revision" {
    var list = DrawList.init();
    try list.append(.{ .x = 0, .y = 0, .width = 1, .height = 1, .r = 1, .g = 1, .b = 1, .a = 1 });
    const revision = list.revision;
    list.clear();
    try std.testing.expectEqual(@as(u32, 0), list.count);
    try std.testing.expectEqual(revision + 1, list.revision);
}

test "demo writes 16x16 grid of instances" {
    var list = DrawList.init();
    demo(&list);
    try std.testing.expectEqual(instance_cap, list.count);
    try std.testing.expect(list.items[0].a < 1);
    try std.testing.expectEqual(@as(f32, 1.0), list.items[instance_cap - 1].a);
}

test "the first present uploads instances and the uniform" {
    var list = DrawList.init();
    demo(&list);
    const cursor = UploadCursor.init();
    const flags = cursor.flags(&list, 1280, 720);
    try std.testing.expectEqual(flag_instances | flag_uniform, flags);
}

test "a revision change uploads instances" {
    var list = DrawList.init();
    demo(&list);
    var cursor = UploadCursor.init();
    cursor.mark(&list, 1280, 720);
    list.clear();
    try list.append(.{ .x = 8, .y = 8, .width = 16, .height = 16, .r = 1, .g = 1, .b = 1, .a = 1 });
    const flags = cursor.flags(&list, 1280, 720);
    try std.testing.expectEqual(flag_instances, flags);
}

test "a logical size change uploads the uniform" {
    var list = DrawList.init();
    demo(&list);
    var cursor = UploadCursor.init();
    cursor.mark(&list, 1280, 720);
    const flags = cursor.flags(&list, 800, 720);
    try std.testing.expectEqual(flag_uniform, flags);
}

test "a scale-style present with the same logical size uploads nothing" {
    var list = DrawList.init();
    demo(&list);
    var cursor = UploadCursor.init();
    cursor.mark(&list, 800, 600);
    const flags = cursor.flags(&list, 800, 600);
    try std.testing.expectEqual(@as(u32, 0), flags);
}

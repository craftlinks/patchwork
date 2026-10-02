//! 2D Instanced Quad Rendering, Orthographic Projections, Draw Lists, and SDF Boxes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Instanced Unit Quads Instead of Immediate Geometry?
//! In a graphical user interface (buttons, panels, borders, badges, scrollbars, text backgrounds),
//! virtually every rendered visual element is a 2D axis-aligned rectangle (quad).
//!
//! In traditional or legacy graphics approaches (such as OpenGL 1.x immediate mode or naive 2D
//! canvas drawing):
//! - The CPU recalculates four 2D vertex positions `(x, y)` and UV coordinates for each quad.
//! - The CPU builds a temporary vertex buffer with 4 to 6 vertices per quad.
//! - For 256 quads, this requires copying 256 * 6 = 1,536 vertices (~49 KB)
//!   across the PCIe bus to GPU VRAM every single frame.
//! - This burns CPU cycles, causes memory allocator churn, and congests PCIe bandwidth.
//!
//! Modern GPU engines (such as Makepad, Flutter Impeller, and modern game UI engines) leverage
//! **Hardware Instancing**:
//! - A single canonical "unit quad" of 6 vertices representing a 1 x 1 square spanning
//!   from `(0, 0)` to `(1, 1)` is uploaded to GPU memory **once** at startup (48 bytes total).
//! - Per-quad parameters (position `x, y`, dimension `width, height`, color `r, g, b, a`,
//!   corner `radius`, and a baked `hover` lighten) are packed into a compact array called
//!   **instances** (48 bytes per instance, three `vec4` groups). Section 6 derives the
//!   rounded-box field those extra floats drive.
//! - Drawing all 256 quads requires just **one single draw call**: `draw(6, instance_count)`.
//! - The GPU hardware vertex fetch unit advances unit quad attributes once per vertex,
//!   and advances instance attributes once per instance. The vertex shader expands each
//!   unit quad into its world-space pixel rectangle directly inside GPU registers.
//!
//! ## 2. Mathematical Derivation of the Y-Down Orthographic Projection Matrix
//!
//! ### Coordinate Spaces:
//! - **UI Pixel Coordinates:**
//!   User interfaces are defined in 2D screen coordinates with origin `(0, 0)` at the top-left
//!   corner of the window. `+X` increases rightwards (`[0, width]`), and `+Y` increases downwards
//!   (`[0, height]`).
//! - **Normalized Device Coordinates (NDC) in WebGPU:**
//!   WebGPU (and Vulkan / Metal) defines the visible clip space as a 3D volume:
//!   - `X in [-1.0, +1.0]`: -1.0 is the left edge, +1.0 is the right edge.
//!   - `Y in [-1.0, +1.0]`: -1.0 is the bottom edge, +1.0 is the top edge (Y-up!).
//!   - `Z in [0.0, 1.0]`: 0.0 is the near plane, 1.0 is the far plane (not OpenGL `[-1, 1]`).
//!
//! ### Algebraic Derivation:
//! We seek linear transformations `f(x)` and `g(y)` mapping pixel ranges to NDC ranges:
//!
//! 1. **Horizontal Mapping (X):**
//!    ```text
//!    f(0) = -1.0,  f(w) = +1.0
//!    f(x) = m_x * x + c_x
//!    m_x * 0 + c_x = -1.0  =>  c_x = -1.0
//!    m_x * w - 1.0 = +1.0  =>  m_x = 2 / w
//!    X_ndc = (2 / w) * x - 1
//!    ```
//!
//! 2. **Vertical Mapping (Y, Inverting Top-Down to Bottom-Up):**
//!    ```text
//!    g(0) = +1.0 (top),  g(h) = -1.0 (bottom)
//!    g(y) = m_y * y + c_y
//!    m_y * 0 + c_y = +1.0  =>  c_y = +1.0
//!    m_y * h + 1.0 = -1.0  =>  m_y = -2 / h
//!    Y_ndc = -(2 / h) * y + 1
//!    ```
//!
//! 3. **Depth Mapping (Z):**
//!    For 2D orthographic UI rendering, depth is unused.
//!    We set `z = 0`, mapping directly to `Z_ndc = 0.0`.
//!
//! 4. **Matrix Formulation (Column-Major 4x4):**
//!    Multiplying matrix `M` by column vector `[x, y, 0, 1]`:
//!    ```text
//!    | 2/w   0    0  -1 |   | x |   | (2*x)/w - 1 | -> NDC X in [-1, +1]
//!    |  0  -2/h   0   1 | * | y | = | 1 - (2*y)/h | -> NDC Y in [+1, -1]
//!    |  0    0    1   0 |   | 0 |   |      0      | -> NDC Z in [0, 1]
//!    |  0    0    0   1 |   | 1 |   |      1      | -> W
//!    ```
//!    Because WebGPU and WGSL represent matrices in **column-major memory order**,
//!    the 16 consecutive floats in memory are stored column by column:
//!    - Column 0 (indices 0..3):   `[ 2.0 / w,      0.0, 0.0, 0.0 ]`
//!    - Column 1 (indices 4..7):   `[     0.0, -2.0 / h, 0.0, 0.0 ]`
//!    - Column 2 (indices 8..11):  `[     0.0,      0.0, 1.0, 0.0 ]`
//!    - Column 3 (indices 12..15): `[    -1.0,      1.0, 0.0, 1.0 ]`
//!
//! ## 3. WebGPU Specification Limit: The 256-Byte Uniform Buffer Alignment Rule
//! The WebGPU standard specification (Section 24.1, Table 23 "Limits") specifies:
//! - `minUniformBufferOffsetAlignment`: Minimum byte alignment for dynamic uniform buffer
//!   offsets and bind group ranges. Compliant hardware requires at least **256 bytes**.
//! - Even though our 4x4 matrix is exactly 64 bytes (16 * 4 bytes), allocating 64 bytes
//!   violates the minimum binding size on certain Vulkan and Metal backends.
//! - Therefore, we set `uniform_bytes = 256` for the GPU allocation, leaving bytes 64..255
//!   zeroed as safe padding.
//!
//! ## 4. The Dirty Tracking Architecture (`UploadCursor`)
//! Transferring data from CPU to GPU via `writeBuffer` incurs driver synchronization overhead.
//! `UploadCursor` implements a state machine that tracks:
//! - `primed`: Has the GPU received the initial data yet? (First frame uploads all buffers).
//! - `revision`: An incrementing counter bumped on `DrawList.append()` or `DrawList.clear()`.
//! - `width_logical`, `height_logical`: Window dimensions from which matrix was built.
//!
//! This enables four distinct upload scenarios:
//! 1. **Initial Frame:** `flag_instances | flag_uniform` (uploads both buffers).
//! 2. **Content Change Only:** `flag_instances` (re-uploads instance buffer; leaves matrix alone).
//! 3. **Window Resize Only:** `flag_uniform` (re-uploads 64-byte matrix; leaves instances intact).
//! 4. **Identical Re-present:** `0` (skips all buffer uploads; immediately begins render pass).
//!
//! ## 5. TigerStyle Safety and Determinism
//! - **Static Allocation:** Fixed capacity of 256 instances (`items: [instance_cap]Instance`).
//!   Zero heap allocation, zero pointer chasing, zero risk of `OutOfMemory` after startup.
//! - **Defensive Pre/Postconditions:** Every public function asserts valid bounds, positive edges,
//!   and correct state transitions.
//! - **Binary Layout Verification:** Comptime assertions enforce exact struct sizes, alignments,
//!   and layout compatibility with WGSL shader declarations.
//!
//! ## 6. Rounded-Box Distance Field
//! Step 2 filled each instance with a flat color. Step 3 keeps the same unit quad, the same
//! draw call, and the same straight-alpha blend, and evaluates a signed distance in the
//! fragment shader. A panel, a pill, and a button face are one instance type.
//!
//! ### Why a distance instead of more triangles
//! A rounded corner can be a fan of extra vertices. That would rebuild the mesh whenever the
//! radius changed, and it would alias on a scaled surface unless the fan was finer than a
//! pixel. A signed distance is a scalar at every local point: negative inside the shape, zero
//! on the boundary, positive outside. The unit quad stays the rectangle's bounding box. The
//! fragment shader asks the field whether that pixel is inside the rounded outline, then turns
//! the distance into coverage. Radius 0 reproduces the sharp rectangle from step 2.
//!
//! ### The 48-byte instance
//! `Instance` is twelve `f32`s in three groups the GPU fetches as `float32x4`:
//! - Offset  0: rectangle `(x, y, width, height)` in logical pixels, origin top-left.
//! - Offset 16: straight-alpha fill `(r, g, b, a)`.
//! - Offset 32: `(radius, hover, down, 0)`.
//!
//! WebGPU requires a vertex `arrayStride` that is a multiple of 4. It does not require a
//! multiple of 16. The third attribute is still a `float32x4`, the same format as the
//! rectangle and the fill, so the record occupies bytes 32..48 and the stride is 48.
//! `radius`, `hover`, and `down` are the live values. The last float is a pad so that one
//! attribute format is shared by `quad.wgsl`, the native pipeline, and `web/shell.js`.
//! `append` writes the pad as 0 and stores `down`. A later reader of `.w` then sees a
//! defined value, and two uploads of the same face compare equal.
//!
//! The instance buffer stays fixed at `instance_cap * instance_stride` bytes (256 * 48).
//! Only `count` instances are uploaded.
//!
//! ### Radius
//! `radius` is the geometric corner radius in logical pixels. `append` rejects a negative
//! radius, because `min(radius, half_edge)` would keep the negative value and the field
//! would invert. A radius larger than the box is stored as given. `sdf_box` and the shader
//! both clamp it to half the shorter edge, so the two implementations cannot drift. A wide
//! box becomes a capsule. A square becomes a disc whose diameter is the side. Makepad's
//! older button shader multiplied the radius by 2 as a compatibility clamp. This field uses
//! the geometric radius, so a value of 16 is a 16-pixel corner.
//!
//! ### Hover and down
//! `hover` is a weight in `[0, 1]` toward white. `down` is a weight in `[0, 1]` toward
//! black, applied after the lighten. The shader computes
//! `mix(mix(fill.rgb, white, hover), black, down)` and leaves the fill alpha unchanged.
//! Weight 0 leaves that stage at the incoming color. Weight 1 replaces it with white or
//! black. A weight outside `[0, 1]` would extrapolate, so `append` rejects it. The stored
//! fill stays the resting color. `hit.zig` writes both weights. `set_state` bumps
//! `revision` only when a stored weight changes, so a resting pointer uploads nothing.
//!
//! ### CPU twin and shader paint
//! `sdf_box` is the CPU twin of the WGSL function. The point is in the same local logical
//! pixels the vertex shader interpolates (`unit * size`, origin at the top-left). Tests lock
//! the field without a GPU: center, sharp edge, outside corner, a corner that falls outside
//! once the radius grows, and disc saturation. The shader owns the paint: analytic coverage
//! from `fwidth`, then the hover mix. See the guide at the top of `src/quad.wgsl`.
//!
//! ### Who writes the rectangles
//! This file does not place the scene. Scene construction and layout are handled by
//! `turtle.paint_column` in `src/turtle.zig`, which replaces the hardcoded seven-face demo
//! from Step 3. Whenever logical window dimensions change (indicated by `Frame.relayout`),
//! `turtle.paint_column` clears the draw list and appends the full-window column followed
//! by each placed child panel whose dimensions are strictly positive.
//!
//! The draw list capacity remains statically bounded at `instance_cap` (256). Radius,
//! hover, and down remain packed fields of `Instance`. The demo column paints every panel
//! at hover 0 and down 0. `hit.apply` writes the weights after each layout walk, so a
//! resize does not leave a resting pointer on an unlit panel. Child capacity is
//! `child_cap = instance_cap - 1` (255), guaranteeing that the
//! root column rectangle (1 slot) plus all children never exceed the 256-instance limit.

const std = @import("std");
const assert = std.debug.assert;

/// The WebGPU Shading Language source embedded directly into the binary at compile time.
/// Both native Linux (via wgpu-native) and the browser (via WebAssembly) compile this same source.
pub const shader_file: []const u8 = @embedFile("quad.wgsl");

/// Hard upper bound on how many rectangle instances can be queued in one draw call.
/// In TigerStyle, all buffer sizes are statically bounded at compile time.
pub const instance_cap: u32 = 256;

/// Byte size of one instance (12 floats * 4 bytes = 48 bytes).
/// Three `float32x4` attributes at offsets 0, 16, and 32. WebGPU only requires the
/// buffer stride to be a multiple of 4. The third attribute is a full `vec4`, so the
/// record is 48 bytes. `down` occupies the former first pad. `pad1` stays 0.
pub const instance_stride: u32 = 48;

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
/// Memory Layout:
/// - Offset  0: `x` (f32) - Left edge in logical UI pixels.
/// - Offset  4: `y` (f32) - Top edge in logical UI pixels.
/// - Offset  8: `width` (f32) - Width in logical UI pixels.
/// - Offset 12: `height` (f32) - Height in logical UI pixels.
/// - Offset 16: `r`, `g`, `b`, `a` (4 f32) - Fill color.
/// - Offset 32: `radius` (f32) - Geometric corner radius in logical pixels.
///   Oversized values are stored here and clamped inside `sdf_box`.
/// - Offset 36: `hover` (f32) - Mix weight toward white, range [0, 1].
///   `hit.apply` writes it. The shader applies it before `down`.
/// - Offset 40: `down` (f32) - Mix weight toward black, range [0, 1].
///   Applied after the hover lighten. `append` stores the caller's value.
/// - Offset 44: `pad1` (f32) - Written as 0. It completes the third `vec4`.
/// Total size: 48 bytes.
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
    pad1: f32,
};

/// The binary header passed to the graphics backend before rendering a frame.
/// In WebAssembly, this exact struct is constructed on the Zig call stack and read by
/// JavaScript via a typed `DataView` over Wasm linear memory.
/// Memory Layout:
/// - Offset  0: `width_px` (u32, 4 bytes) - Physical swapchain width in device pixels.
/// - Offset  4: `height_px` (u32, 4 bytes) - Physical swapchain height in device pixels.
/// - Offset  8: `instance_count` (u32, 4 bytes) - Number of instances to draw [0..256].
/// - Offset 12: `flags` (u32, 4 bytes) - Bitmask of buffers to upload (flags_instances / uniform).
/// - Offset 16: `clear_r` (f32, 4 bytes) - Framebuffer background clear color red.
/// - Offset 20: `clear_g` (f32, 4 bytes) - Framebuffer background clear color green.
/// - Offset 24: `clear_b` (f32, 4 bytes) - Framebuffer background clear color blue.
/// - Offset 28: `clear_a` (f32, 4 bytes) - Framebuffer background clear color alpha.
/// - Offset 32: `ortho` ([16]f32, 64 bytes) - 4x4 column-major orthographic projection matrix.
/// Total size: 96 bytes.
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

    pub const AppendError = error{
        EdgeNotPositive,
        ListFull,
        NegativeRadius,
        HoverOutOfRange,
        DownOutOfRange,
    };

    /// Appends one rectangle instance to the draw list.
    ///
    /// Preconditions and Error Handling:
    /// - `error.EdgeNotPositive`: Returned if either `instance.width <= 0` or
    ///   `instance.height <= 0`. Layout calculations can produce zero edges (e.g. collapsed
    ///   flex bounds or zero-dimension viewports) or negative edges (e.g. when container
    ///   padding or child margins exceed available bounds). Both zero and negative dimensions
    ///   are explicitly rejected so degenerate geometry is never submitted to the GPU.
    /// - `error.NegativeRadius`: Returned if `instance.radius < 0`. An oversized radius is
    ///   stored unchanged because both `sdf_box` and `quad.wgsl` clamp it to half the shorter
    ///   edge. A negative radius would survive `min(radius, half)` and invert the field.
    /// - `error.HoverOutOfRange`: Returned if `instance.hover < 0` or `instance.hover > 1`.
    ///   Weights outside `[0.0, 1.0]` would extrapolate the shader `mix` beyond the fill or white.
    /// - `error.DownOutOfRange`: Returned if `instance.down < 0` or `instance.down > 1`.
    ///   The darken mix would extrapolate past black the same way an out-of-range hover
    ///   extrapolates past white.
    /// - `error.ListFull`: Returned if `self.count == instance_cap` (256).
    ///
    /// Attribute Padding & Revision:
    /// - `down` is stored. `pad1` is zeroed so the unused `.w` of the third `vec4` is defined.
    /// - Increments both `count` and `revision` on success.
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
        if (self.count == instance_cap) {
            return error.ListFull;
        }
        assert(instance.radius >= 0);
        assert(instance.hover >= 0);
        assert(instance.down >= 0);
        var stored: Instance = instance;
        stored.pad1 = 0;
        self.items[self.count] = stored;
        self.count += 1;
        self.revision += 1;
        assert(self.items[self.count - 1].hover <= 1);
        assert(self.items[self.count - 1].down <= 1);
        assert(self.items[self.count - 1].pad1 == 0);
    }

    /// Writes `hover` and `down` on one live slot.
    ///
    /// Parameters & Invariants:
    /// - `index`: Must be a valid live slot (`index < self.count`). Slot 0 is reserved for column
    ///   background and should not be modified by caller.
    /// - `hover`: Mix weight toward white, clamped to `[0.0, 1.0]`.
    /// - `down`: Mix weight toward black, clamped to `[0.0, 1.0]`.
    ///
    /// Revision & Dirty Tracking Interplay:
    /// - Returns false when both stored weights already match existing values, leaving `revision`
    ///   unchanged. This allows resting pointers to hit-test every poll wake with 0% CPU and zero
    ///   GPU buffer uploads (`UploadCursor.flags() == 0`).
    /// - Returns true when either weight differs, updating `items[index]` and incrementing
    ///   `self.revision` so `UploadCursor.flags()` emits `flag_instances`.
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

/// Signed distance of a rounded rectangle. This is the CPU twin of `sdf_box` in `quad.wgsl`.
///
/// `(px, py)` is in local logical pixels. The origin is the rectangle's top-left, the same
/// space the vertex shader interpolates as `unit * size`. The return is negative inside, zero
/// on the boundary, and positive outside. Tests lock this field without a GPU. The shader
/// turns the same field into coverage and applies hover. This function does not.
///
/// `radius` is the geometric corner radius in logical pixels. It is clamped to half the
/// shorter edge. A larger value becomes a capsule, and a square becomes a disc whose diameter
/// is the side. Radius 0 is the sharp rectangle from step 2. `append` stores an oversized
/// radius unchanged and rejects a negative one. This function and the shader both clamp, so
/// the pictures cannot drift. Makepad's older button shader multiplied the radius by 2 as a
/// compatibility clamp. The value here is the geometric radius.
///
/// The outline is an inner sharp box shrunk by the clamped radius `k`, then expanded by `k`.
/// The expansion turns the inner corners into quarter-circles. With `half = (width/2, height/2)`
/// and `k = min(radius, min(half.x, half.y))`:
///
/// ```
/// q = abs(point - half) - (half - k)
/// distance = min(max(q.x, q.y), 0) + length(max(q, 0)) - k
/// ```
///
/// `q` is the first-quadrant offset from the inner box. `abs` folds the other three quadrants.
/// `min(max(q.x, q.y), 0)` is the inside distance to the nearest inner face. `length(max(q, 0))`
/// is the outside Euclidean distance. At a corner, that length is the distance to the inner
/// corner point. Subtracting `k` moves the boundary out to the rounded outline.
///
/// Values locked by the tests:
/// - Center of a 20 by 10 sharp box: -5, which is half the shorter side.
/// - Midpoint of that box's top edge: 0.
/// - The point (-1, -1), one pixel left and one pixel above the top-left corner: sqrt(2).
/// - The point (0.5, 0.5) on a 20 by 20 box is inside at radius 0 and outside at radius 8.
/// - A 20 by 20 box with radius 100 clamps to `k = 10`. The center is -10, an edge midpoint
///   is 0, and a geometric corner is outside. That is a disc.
pub fn sdf_box(px: f32, py: f32, width: f32, height: f32, radius: f32) f32 {
    assert(width > 0);
    assert(height > 0);
    assert(radius >= 0);
    // Origin is the top-left, so the center sits at (half_w, half_h). Those same
    // numbers are the half-extents of the box. The field is measured from there.
    const half_w: f32 = 0.5 * width;
    const half_h: f32 = 0.5 * height;
    // A radius past half the shorter edge would make the inner box negative and the
    // corner circles overlap. The clamp saturates a wide box into a capsule and a
    // square into a disc.
    const shorter: f32 = @min(half_w, half_h);
    const k: f32 = @min(radius, shorter);
    assert(k >= 0);
    assert(k <= shorter);
    // First-quadrant offset from the inner box, whose half-extent is (half - k).
    const qx: f32 = @abs(px - half_w) - (half_w - k);
    const qy: f32 = @abs(py - half_h) - (half_h - k);
    // The outside term ignores inward components. At a corner it is the distance
    // to the inner corner point.
    const outside_x: f32 = @max(qx, 0.0);
    const outside_y: f32 = @max(qy, 0.0);
    const outside: f32 = @sqrt(outside_x * outside_x + outside_y * outside_y);
    // The inside term is the nearest face, and only while the point is inside both axes.
    const inside: f32 = @min(@max(qx, qy), 0.0);
    // Expand the inner box by k. The boundary lands on the quarter-circle.
    return inside + outside - k;
}

/// True when `(x, y)` lies inside the rounded face, inclusive of the boundary.
///
/// Coordinate Space & Units:
/// - `(x, y)`: UI logical pixels, top-left origin, `+X` right, `+Y` down.
/// - Matched against `(instance.x, instance.y, instance.width, instance.height)` in logical pixels.
///
/// Preconditions:
/// - `instance.width > 0`, `instance.height > 0`, `instance.radius >= 0`.
///
/// Two-Phase Hit Detection:
/// 1. Axis-Aligned Bounding Box (AABB) early rejection: points strictly outside `[x, x + width]`
///    or `[y, y + height]` return false immediately without distance computation.
/// 2. Analytic Distance Twin: evaluates `sdf_box` on local coordinates `(x - inst.x, y - inst.y)`.
///    Boundary test is `dist <= 0.0`, matching WGSL fragment coverage `>= 0.5`.
///    A corner pixel inside the AABB but outside the rounded boundary returns false.
pub fn contains(instance: Instance, x: f32, y: f32) bool {
    assert(instance.width > 0);
    assert(instance.height > 0);
    assert(instance.radius >= 0);
    if (x < instance.x) {
        return false;
    }
    if (x > instance.x + instance.width) {
        return false;
    }
    if (y < instance.y) {
        return false;
    }
    if (y > instance.y + instance.height) {
        return false;
    }
    const local_x = x - instance.x;
    const local_y = y - instance.y;
    const dist = sdf_box(local_x, local_y, instance.width, instance.height, instance.radius);
    return dist <= 0;
}

/// Test construction record. `face` writes `pad1` as 0 so every call site stores
/// a defined shape `vec4`.
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
        .pad1 = 0,
    };
    assert(instance.down >= 0);
    assert(instance.pad1 == 0);
    return instance;
}

comptime {
    // Assert struct sizes and alignments to prevent C ABI mismatches across compilers.
    assert(@sizeOf(Instance) == 48);
    assert(@alignOf(Instance) >= 4);
    assert(instance_stride == 48);
    // 48 is three vec4 groups, not a WebGPU minimum. The spec only requires a multiple of 4.
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
    assert(instance.pad1 == 0);
    return instance;
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

test "a zero edge is rejected" {
    var list = DrawList.init();
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(0, 10)));
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(10, 0)));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

test "a negative edge is rejected" {
    var list = DrawList.init();
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(-1, 10)));
    try std.testing.expectError(error.EdgeNotPositive, list.append(rect(10, -1)));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

test "negative radius is rejected" {
    var list = DrawList.init();
    var instance = rect(10, 10);
    instance.radius = -1;
    try std.testing.expectError(error.NegativeRadius, list.append(instance));
    try std.testing.expectEqual(@as(u32, 0), list.count);
}

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

// Locks storage of down weight at offset 40 and deterministically zeroed pad1 at offset 44.
test "append stores down and zeros the pad" {
    var list = DrawList.init();
    var instance = rect(10, 10);
    instance.down = 0.25;
    instance.pad1 = 8;
    try list.append(instance);
    try std.testing.expectEqual(@as(f32, 0.25), list.items[0].down);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].pad1);
}

// Locks defensive bounds validation: down weights outside [0, 1] return DownOutOfRange.
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

// Locks dirty tracking optimization: matching weights return false without bumping revision.
test "set_state leaves the revision when the weights match" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const revision = list.revision;
    try std.testing.expect(!list.set_state(0, 0, 0));
    try std.testing.expectEqual(revision, list.revision);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].down);
}

// Locks revision bumping: changed hover or down weights return true and increment revision.
test "set_state bumps the revision when a weight changes" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const revision = list.revision;
    try std.testing.expect(list.set_state(0, 0.18, 0.30));
    try std.testing.expectEqual(revision + 1, list.revision);
    try std.testing.expectEqual(@as(f32, 0.18), list.items[0].hover);
    try std.testing.expectEqual(@as(f32, 0.30), list.items[0].down);
}

// Locks analytic boundary testing: sharp corners hit edges, rounded corners reject outside curve.
test "contains accepts the sharp edge and rejects a rounded corner" {
    const sharp = rect(20, 10);
    try std.testing.expect(contains(sharp, 10, 0));
    try std.testing.expect(contains(sharp, 0, 5));
    try std.testing.expect(!contains(sharp, -1, 5));
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
}

test "a full list rejects the next append" {
    var list = DrawList.init();
    var index: u32 = 0;
    while (index < instance_cap) : (index += 1) {
        try list.append(rect(1, 1));
    }
    try std.testing.expectError(error.ListFull, list.append(rect(1, 1)));
    try std.testing.expectEqual(instance_cap, list.count);
}

test "clear zeros the count and bumps the revision" {
    var list = DrawList.init();
    try list.append(rect(1, 1));
    const revision = list.revision;
    list.clear();
    try std.testing.expectEqual(@as(u32, 0), list.count);
    try std.testing.expectEqual(revision + 1, list.revision);
}

// The five distance tests mirror the worked values on `sdf_box`: interior, boundary,
// exterior corner, a corner sample pushed outside by a grown radius, and disc saturation.
test "sdf center is inside" {
    const dist = sdf_box(10, 5, 20, 10, 0);
    try std.testing.expect(dist < 0);
    try std.testing.expectApproxEqAbs(@as(f32, -5), dist, 0.0001);
}

test "sdf sharp edge midpoint is on the boundary" {
    const dist = sdf_box(10, 0, 20, 10, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dist, 0.0001);
}

test "sdf point outside a sharp corner is positive" {
    const dist = sdf_box(-1, -1, 20, 10, 0);
    try std.testing.expect(dist > 0);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 2)), dist, 0.0001);
}

test "sdf grown radius puts a former inner corner outside" {
    const sharp = sdf_box(0.5, 0.5, 20, 20, 0);
    const rounded = sdf_box(0.5, 0.5, 20, 20, 8);
    try std.testing.expect(sharp < 0);
    try std.testing.expect(rounded > 0);
}

test "sdf oversized radius saturates into a disc" {
    const center = sdf_box(10, 10, 20, 20, 100);
    const edge = sdf_box(10, 0, 20, 20, 100);
    const corner = sdf_box(0, 0, 20, 20, 100);
    try std.testing.expectApproxEqAbs(@as(f32, -10), center, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), edge, 0.0001);
    try std.testing.expect(corner > 0);
}

test "the first present uploads instances and the uniform" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    const cursor = UploadCursor.init();
    const flags = cursor.flags(&list, 1280, 720);
    try std.testing.expectEqual(flag_instances | flag_uniform, flags);
}

test "a revision change uploads instances" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    var cursor = UploadCursor.init();
    cursor.mark(&list, 1280, 720);
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
    const flags = cursor.flags(&list, 1280, 720);
    try std.testing.expectEqual(flag_instances, flags);
}

test "a logical size change uploads the uniform" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    var cursor = UploadCursor.init();
    cursor.mark(&list, 1280, 720);
    const flags = cursor.flags(&list, 800, 720);
    try std.testing.expectEqual(flag_uniform, flags);
}

test "a scale-style present with the same logical size uploads nothing" {
    var list = DrawList.init();
    try list.append(rect(10, 10));
    var cursor = UploadCursor.init();
    cursor.mark(&list, 800, 600);
    const flags = cursor.flags(&list, 800, 600);
    try std.testing.expectEqual(@as(u32, 0), flags);
}

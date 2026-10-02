//! Pointer state and the CPU hit test over a laid-out draw list.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Core Problem & Rationale: Flat GPU Instance Buffer as Hit Target
//! In traditional GUI toolkits (DOM, Flutter RenderBox, Qt QWidget), hit testing traverses
//! a deep hierarchical retained widget tree. This requires duplicating geometric bounds,
//! maintaining spatial index trees (R-trees, quadtrees), and managing parent-child object
//! lifecycles with garbage collection or heap allocations.
//!
//! In Patchwork:
//! - There is no widget tree yet. `turtle.paint_column` lays out panels and appends them
//!   directly into `DrawList.items` (a flat array of 48-byte instances).
//! - The GPU paints instances in append order (Painter's algorithm; later instances draw over
//!   earlier ones). Therefore, a simple reverse scan (`count - 1` down to 0) over the laid-out
//!   instances strictly matches the visual z-order rendered on screen.
//! - Slot 0 contains the root column background rectangle spanning the entire window. It is
//!   excluded from hit testing by slicing `items[1..count]`, ensuring the background never
//!   steals child hits or activates hover/down visual states.
//! - The hit test uses `sdf_box <= 0.0` (the exact analytical CPU twin of the WGSL shader)
//!   rather than an Axis-Aligned Bounding Box (AABB) alone. On rounded corners, an AABB would
//!   falsely hit exterior transparent/slate pixels where the corner curved away.
//!
//! ## 2. Mathematical Derivations & Coordinate Spaces
//!
//! ### Coordinate Spaces:
//! - **UI Logical Pixel Coordinates:** Origin `(0, 0)` at window top-left, `+X` rightwards,
//!   `+Y` downwards. This coordinate space is identical across `turtle` layout,
//!   `draw.ortho_y_down`, and `Pointer.x, Pointer.y`.
//! - **Wayland Wire Coordinates (`wl_fixed_t`):**
//!   Wayland `wl_pointer.enter` and `motion` deliver coordinates in `wl_fixed_t`, a signed
//!   24.8 fixed-point integer (32-bit signed int):
//!   - High 24 bits (bits 8..31): Signed integral pixel coordinate.
//!   - Low 8 bits (bits 0..7): Fractional subpixel position in increments of 1/256.
//!   - Conversion equation:
//!     ```text
//!     logical = @as(f32, @floatFromInt(fixed)) / 256.0
//!     ```
//!   - Worked numerical points:
//!     - `fixed = 256`  (0x00000100) -> `256 / 256.0 = 1.0` logical pixel.
//!     - `fixed = -128` (0xFFFFFF80) -> `-128 / 256.0 = -0.5` logical pixel.
//!     - `fixed = 0`    (0x00000000) -> `0 / 256.0 = 0.0` logical pixel.
//!     - Precision: `1 / 256 = 0.00390625` logical pixels.
//!   - Wayland surface-local coordinates are invariant to `wl_surface.set_buffer_scale`.
//! - **Browser Host Coordinates:**
//!   `shell.js` receives mouse events in CSS pixels (`offsetX`, `offsetY`). Because `resize`
//!   currently configures the logical coordinate space to the canvas backing buffer (device
//!   pixels), `shell.js` multiplies by `window.devicePixelRatio` before invoking Wasm exports.
//! - **Local Instance Coordinates:**
//!   ```text
//!   local_x = pointer_x - instance.x
//!   local_y = pointer_y - instance.y
//!   ```
//!
//! ### Signed Distance Field for Rounded Boxes (`sdf_box`):
//! For an instance of dimensions `(width, height)` and corner radius `radius`:
//! ```text
//! half_w = 0.5 * width
//! half_h = 0.5 * height
//! k = min(radius, min(half_w, half_h))
//! qx = abs(local_x - half_w) - (half_w - k)
//! qy = abs(local_y - half_h) - (half_h - k)
//! inside = min(max(qx, qy), 0.0)
//! outside = sqrt(max(qx, 0.0)^2 + max(qy, 0.0)^2)
//! distance = inside + outside - k
//! ```
//! - Interior point: `distance < 0.0`.
//! - Boundary contour: `distance == 0.0`. In `quad.wgsl`:
//!   `coverage = clamp(0.5 - dist/pixel, 0, 1)`, so `distance == 0.0` yields coverage of 0.5.
//! - Hit condition: `draw.contains()` checks AABB early rejection, then requires `dist <= 0.0`.
//!
//! ## 3. Hardware, Spec Limits, and Memory Layouts
//! - `Pointer`: 16 bytes total:
//!   - Bytes 0..3: `x: f32` (logical X coordinate).
//!   - Bytes 4..7: `y: f32` (logical Y coordinate).
//!   - Byte 8: `inside: bool` (true if pointer is currently over surface).
//!   - Byte 9: `down: bool` (true if primary mouse button is held down).
//!   - Bytes 10..15: 6 bytes compiler padding to 16-byte alignment.
//! - `Weights`: 8 bytes total:
//!   - Bytes 0..3: `hover: f32` (mix weight toward white).
//!   - Bytes 4..7: `down: f32` (mix weight toward black).
//! - `Instance` (in `DrawList`): 48 bytes total:
//!   - Offset 32: `radius: f32` (`shape.x`).
//!   - Offset 36: `hover: f32` (`shape.y`, written by `apply`).
//!   - Offset 40: `down: f32` (`shape.z`, written by `apply`).
//!   - Offset 44: `pad1: f32` (`shape.w`, fixed zero).
//!
//! ## 4. State Machines & Data Flow
//!
//! ### Pointer State Transitions:
//! ```text
//!   +-----------------------------------------------------------+
//!   |                                                           |
//!   v                                                           |
//! [Init: inside=false, down=false]                              |
//!   |                                                           |
//!   | enter(x, y) / motion(x, y)                                |
//!   v                                                           |
//! [Inside: inside=true, down=false]                             |
//!   |                   ^                                       |
//!   | button(true)      | button(false)                         |
//!   v                   |                                       |
//! [Pressed: inside=true, down=true]                             |
//!   |                                                           |
//!   | leave()                                                   |
//!   +-----------------------------------------------------------+
//! ```
//! Note: `leave()` clears both `inside` and `down`. If a user presses a mouse button, drags
//! off the surface, and releases, the display server may never deliver the release event.
//! Clearing `down` on `leave` prevents stuck click states.
//!
//! ### Data Flow & Redraw Pacing:
//! ```text
//! Platform Event (Wayland callback / JS pointer listener)
//!   |
//!   v
//! Pointer.move / Pointer.button / Pointer.leave
//!   |
//!   v
//! hit.apply(DrawList, Pointer)
//!   |--> topmost() reverse scan over DrawList.items[1..count]
//!   |--> compute target weights:
//!   |      hover_lighten = 0.18 (on hit)
//!   |      down_darken   = 0.30 (on hit if pointer.down)
//!   |--> DrawList.set_state(slot, hover, down)
//!          |--> If weights match existing values: returns false (revision unchanged)
//!          |--> If weights differ: updates values, bumps revision, returns true
//!   |
//!   v
//! If changed == true:
//!   Frame.request_redraw()
//!   |--> Linux: loop wakes, present_if_dirty uploads instances and presents
//!   |--> Browser: note_pointer returns 1, shell.js schedules requestAnimationFrame
//! If changed == false:
//!   0% CPU / 0% GPU idle; no buffer upload, no redraw.
//! ```
//!
//! ## 5. Cross-Platform Seams & Synchronization
//! - **Wayland Loop Amortization:**
//!   Compositors can deliver dozens of `wl_pointer.motion` events per frame. `linux_window.zig`
//!   callbacks only update `State.pointer`. The main loop calls `sync_pointer` once per wake
//!   after `ack_if_needed`, executing exactly one hit test and at most one frame draw.
//! - **Browser Pointer Capture:**
//!   In `shell.js`, `canvas.setPointerCapture(event.pointerId)` is called on `pointerdown`.
//!   This guarantees that dragging off canvas continues tracking until `pointerup`, releasing
//!   cleanly even outside canvas boundaries.
//! - **Relayout Preservation:**
//!   When the window resizes, `turtle.paint_column` clears the draw list and emits instances
//!   with initial `hover = 0, down = 0`. Both `linux_window.zig:present_if_dirty` and
//!   `web_exports.zig:tick` immediately re-invoke `hit.apply(&list, state.pointer)` right after
//!   `frame.mark_laid_out()`. This prevents a resize from flickering or wiping the highlight
//!   under a resting pointer.
//!
//! ## 6. TigerStyle Invariants
//! - **Static Memory Bounds:** Zero heap allocation; operates in place on `DrawList`.
//! - **Bounded Execution:** `topmost` and `apply` loop at most `draw.instance_cap` (256) times.
//!   No recursion. Maximum call stack depth is strictly bounded.
//! - **Split Assertions:** Every pre/postcondition and state transition is asserted individually.
//! - **Positive & Negative Space Testing:** Verified against interior centers, sharp edges,
//!   gutter spaces, rounded corner cutouts, overlapping z-orders, and relayout bounds.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const turtle = @import("turtle.zig");

/// Mix weight toward white applied to the instance currently under the pointer.
/// In `quad.wgsl`: `let lit = mix(fill.rgb, vec3(1.0), hover);`
pub const hover_lighten: f32 = 0.18;

/// Mix weight toward black applied to the instance under the pointer while pressed.
/// In `quad.wgsl`: `let rgb = mix(lit, vec3(0.0), down);`
pub const down_darken: f32 = 0.30;

/// Snapshot of pointer state. Platform callbacks write it; `hit.apply` reads it.
/// Memory layout: 16 bytes total (two 4-byte f32s, two 1-byte bools, 6 bytes padding).
pub const Pointer = struct {
    x: f32,
    y: f32,
    inside: bool,
    down: bool,

    /// Initializes pointer in resting state outside surface boundaries.
    pub fn init() Pointer {
        const pointer: Pointer = .{
            .x = 0,
            .y = 0,
            .inside = false,
            .down = false,
        };
        assert(!pointer.inside);
        assert(!pointer.down);
        return pointer;
    }

    /// Records pointer position inside the surface in UI logical pixels.
    /// Wayland `wl_pointer.enter`/`motion` and browser `pointermove` call this.
    pub fn move(self: *Pointer, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
        self.inside = true;
        assert(self.inside);
        assert(self.x == x);
    }

    /// Records pointer leaving surface bounds. Clears `down` so uncaptured presses cannot stick.
    pub fn leave(self: *Pointer) void {
        self.inside = false;
        self.down = false;
        assert(!self.inside);
        assert(!self.down);
    }

    /// Records primary button state (true = pressed, false = released).
    pub fn button(self: *Pointer, pressed: bool) void {
        self.down = pressed;
        assert(self.down == pressed);
    }
};

/// Internal tuple of hover and down weights computed for an instance slot.
const Weights = struct {
    hover: f32,
    down: f32,
};

/// Converts a Wayland `wl_fixed_t` (signed 24.8 fixed point) value to UI logical pixels.
/// Precondition: `fixed` is a valid 32-bit signed fixed-point value.
/// Postcondition: Result is `fixed / 256.0`.
pub fn fixed_to_logical(fixed: i32) f32 {
    const logical: f32 = @as(f32, @floatFromInt(fixed)) / 256.0;
    if (fixed == 0) {
        assert(logical == 0);
    }
    if (fixed == 256) {
        assert(logical == 1);
    }
    return logical;
}

/// Identifies the index of the topmost instance whose rounded face contains `(x, y)`.
///
/// Coordinate space: `(x, y)` in UI logical pixels, top-left origin.
/// Search order: Reverse scan (`count - 1` down to 0) matching GPU draw z-order.
/// Returns null if `instances` is empty or if `(x, y)` is outside all instances.
/// Bounded by `draw.instance_cap`.
pub fn topmost(instances: []const draw.Instance, x: f32, y: f32) ?u32 {
    const count: u32 = @intCast(instances.len);
    assert(count <= draw.instance_cap);
    var index: u32 = count;
    while (index > 0) {
        index -= 1;
        if (draw.contains(instances[index], x, y)) {
            assert(index < count);
            return index;
        }
    }
    assert(index == 0);
    return null;
}

/// Evaluates hit testing against `list` and updates `hover` and `down` weights.
///
/// Slot 0 (root column background) is strictly excluded and never modified.
/// Returns true if any instance's stored weights changed (which bumps `list.revision`).
/// Returns false if weights are identical to prior state (allowing 0% CPU idle skip).
pub fn apply(list: *draw.DrawList, pointer: Pointer) bool {
    assert(list.count <= draw.instance_cap);
    const hit = hit_slot(list, pointer);
    var changed = false;
    var slot: u32 = 1;
    while (slot < list.count) : (slot += 1) {
        const weights = weights_for(slot, hit, pointer.down);
        if (list.set_state(slot, weights.hover, weights.down)) {
            changed = true;
        }
    }
    if (list.count == 0) {
        assert(!changed);
    }
    return changed;
}

/// Determines which slot in `list.items[1..count]` is hit by `pointer`.
/// Returns absolute slot index in `[1, count - 1]`, or null if outside or unhit.
fn hit_slot(list: *const draw.DrawList, pointer: Pointer) ?u32 {
    assert(list.count <= draw.instance_cap);
    if (!pointer.inside) {
        return null;
    }
    if (list.count <= 1) {
        return null;
    }
    const children = list.items[1..list.count];
    if (topmost(children, pointer.x, pointer.y)) |index| {
        const slot: u32 = index + 1;
        assert(slot < list.count);
        assert(slot >= 1);
        return slot;
    }
    return null;
}

/// Computes hover and down weights for a given slot.
/// Hit slot receives `hover_lighten` (and `down_darken` if pressed); non-hit slots receive zero.
fn weights_for(slot: u32, hit: ?u32, pressed: bool) Weights {
    if (hit) |chosen| {
        if (slot == chosen) {
            var down: f32 = 0;
            if (pressed) {
                down = down_darken;
            }
            assert(hover_lighten > 0);
            assert(down <= down_darken);
            return .{ .hover = hover_lighten, .down = down };
        }
    }
    return .{ .hover = 0, .down = 0 };
}

comptime {
    assert(hover_lighten > 0);
    assert(hover_lighten <= 1);
    assert(down_darken > 0);
    assert(down_darken <= 1);
    assert(@sizeOf(Pointer) <= 16);
}

/// Helper to construct an instance for testing hit detection.
fn sample(x: f32, y: f32, width: f32, height: f32, radius: f32) draw.Instance {
    const instance: draw.Instance = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .r = 1,
        .g = 1,
        .b = 1,
        .a = 1,
        .radius = radius,
        .hover = 0,
        .down = 0,
        .pad1 = 0,
    };
    assert(instance.width > 0);
    assert(instance.pad1 == 0);
    return instance;
}

// Locks Wayland 24.8 signed fixed-point conversion against regressions.
test "fixed_to_logical converts 24.8" {
    try std.testing.expectEqual(@as(f32, 1), fixed_to_logical(256));
    try std.testing.expectEqual(@as(f32, -0.5), fixed_to_logical(-128));
    try std.testing.expectEqual(@as(f32, 0), fixed_to_logical(0));
}

// Locks reverse scan z-order: overlapping quads pick the later index.
test "topmost returns the later overlapping index" {
    const faces = [_]draw.Instance{
        sample(0, 0, 40, 40, 0),
        sample(10, 10, 40, 40, 0),
    };
    const hit = topmost(&faces, 20, 20);
    try std.testing.expectEqual(@as(u32, 1), hit.?);
}

// Locks null return when testing against an empty instance slice.
test "topmost of an empty slice is null" {
    const faces = [_]draw.Instance{};
    try std.testing.expect(topmost(&faces, 0, 0) == null);
}

// Locks worked positive and negative hit-test points for 1280x720 column layout:
// - (8, 8): Gutter margin outside children -> null.
// - (640, 48): Inside header panel -> slot 0 in children slice.
// - (640, 368): Inside body panel -> slot 1 in children slice.
// - (1144, 680): Inside rounded footer button -> slot 2 in children slice (dist = -24).
// - (1025, 657): Inside bounding box but outside radius-24 rounded corner -> null (dist ~ 8.53).
test "column hits at 1280 by 720" {
    var list = draw.DrawList.init();
    turtle.paint_column(&list, 1280, 720);
    const children = list.items[1..list.count];
    try std.testing.expect(topmost(children, 8, 8) == null);
    try std.testing.expectEqual(@as(u32, 0), topmost(children, 640, 48).?);
    try std.testing.expectEqual(@as(u32, 1), topmost(children, 640, 368).?);
    try std.testing.expectEqual(@as(u32, 2), topmost(children, 1144, 680).?);
    try std.testing.expect(topmost(children, 1025, 657) == null);
    const center = draw.sdf_box(120, 24, 240, 48, 24);
    const corner = draw.sdf_box(1, 1, 240, 48, 24);
    try std.testing.expectApproxEqAbs(@as(f32, -24), center, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.53), corner, 0.01);
    try std.testing.expect(corner > 0);
}

// Locks apply idempotency: first hover bumps revision; repeated hover returns false without bump.
test "apply hovers the body once" {
    var list = draw.DrawList.init();
    turtle.paint_column(&list, 1280, 720);
    var pointer = Pointer.init();
    pointer.move(640, 368);
    const before = list.revision;
    try std.testing.expect(apply(&list, pointer));
    try std.testing.expectEqual(hover_lighten, list.items[2].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[2].down);
    try std.testing.expectEqual(@as(f32, 0), list.items[1].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[3].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[0].hover);
    try std.testing.expect(list.revision > before);
    const after = list.revision;
    try std.testing.expect(!apply(&list, pointer));
    try std.testing.expectEqual(after, list.revision);
}

// Locks down weight application: button press darkens only the active hit slot.
test "a press darkens only the hit" {
    var list = draw.DrawList.init();
    turtle.paint_column(&list, 1280, 720);
    var pointer = Pointer.init();
    pointer.move(640, 368);
    try std.testing.expect(apply(&list, pointer));
    pointer.button(true);
    try std.testing.expect(apply(&list, pointer));
    try std.testing.expectEqual(down_darken, list.items[2].down);
    try std.testing.expectEqual(hover_lighten, list.items[2].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[1].down);
    try std.testing.expectEqual(@as(f32, 0), list.items[3].down);
}

// Locks pointer leave semantics: leaving clears hover and down weights on previously hit slot.
test "leave clears hover and down" {
    var list = draw.DrawList.init();
    turtle.paint_column(&list, 1280, 720);
    var pointer = Pointer.init();
    pointer.move(640, 368);
    pointer.button(true);
    try std.testing.expect(apply(&list, pointer));
    pointer.leave();
    try std.testing.expect(apply(&list, pointer));
    try std.testing.expectEqual(@as(f32, 0), list.items[2].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[2].down);
    try std.testing.expect(!apply(&list, pointer));
}

// Locks hit-test persistence across relayout: resting pointer over (600, 560) hits body
// under 1280x720, but hits relocated footer panel after resizing to 800x600.
test "a resting pointer hits the footer after relayout" {
    var list = draw.DrawList.init();
    turtle.paint_column(&list, 1280, 720);
    var pointer = Pointer.init();
    pointer.move(600, 560);
    try std.testing.expect(apply(&list, pointer));
    try std.testing.expectEqual(hover_lighten, list.items[2].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[3].hover);
    turtle.paint_column(&list, 800, 600);
    try std.testing.expect(apply(&list, pointer));
    try std.testing.expectEqual(@as(f32, 544), list.items[3].x);
    try std.testing.expectEqual(@as(f32, 536), list.items[3].y);
    try std.testing.expectEqual(@as(f32, 240), list.items[3].width);
    try std.testing.expectEqual(@as(f32, 48), list.items[3].height);
    try std.testing.expectEqual(hover_lighten, list.items[3].hover);
    try std.testing.expectEqual(@as(f32, 0), list.items[2].hover);
    const local = draw.sdf_box(56, 24, 240, 48, 24);
    try std.testing.expectApproxEqAbs(@as(f32, -24), local, 0.0001);
}

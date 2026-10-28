//! Hit areas: stable ids, the area record a widget leaves while drawing, and the one scan
//! that resolves a pointer against them.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Areas
//! A widget records where it was actually drawn (`cx.area`), and pointer events resolve
//! against the areas of the last drawn frame, which is what the user sees and points at.
//! There is no widget list and no layout pass to keep in sync with drawing.
//!
//! ## 2. Ids
//! `id(name, index)` hashes `name` with FNV-1a-64 at compile time and mixes in `index` with
//! the splitmix64 finalizer, so `id("knob", 3)` is a constant-cost `u64` that is stable
//! across frames and builds. `Id.none` (0) is never produced. `derive(salt)` mixes a second
//! number in, for a widget's sub-part such as a view's thumb. One area per id per frame:
//! safe builds check it with `Stamps` (section 5).
//!
//! ## 3. The Record
//! `Area` is 64 bytes: `id`, `rect` and `clip` as `[4]f32` (`clip` exclusive-max like an
//! instance's), the corner `radius` of the rounded hit shape, the draw `layer` it was
//! recorded on, `flags`, and the point range `first_point`, `point_count` of a path area.
//! `flags` are `wheel` (the area takes wheel input), `focusable` (a left press focuses it and
//! Tab visits it; the area list in draw order is the Tab order), `tab` (while focused, Tab
//! and Shift+Tab go to its widget instead of moving focus), `cursor` (the pointer shape
//! over it, resolved with the hot area), `drop` (the area takes dropped files), and `window`
//! (a press on it moves or resizes the window, `WindowPart`). A point hits a box area
//! (`point_count == 0`) when the clip contains it and `draw.contains_box` accepts it.
//!
//! A path area (`ui.Context.path_area`) is the set of points within `radius` of a stroked
//! polyline whose points are in the draw context's point pool, relative to the path origin
//! `rect.xy + radius` (`draw/path.zig`, section 6). Its rect is the path's bounds padded by
//! `radius`, so a shift of the rect moves the shape with it. A point hits it when the clip
//! and the rect contain it and `draw.path.distance_to_polyline` is at most `radius`; only
//! path areas whose rect contains the point measure the polyline. The points are those of
//! the frame that recorded the area, which is the frame events resolve against.
//!
//! ## 3a. Areas in a Canvas
//! An area recorded inside a canvas (`ui/cx.zig`, section 3a) is mapped to the screen when it
//! is recorded: `rect`, `clip`, and `radius` through the canvas's view, so resolution, capture,
//! and `Press.rect` stay in screen pixels. `zoom` is the view's zoom (1 outside a canvas): a
//! path area's points stay in world pixels, so `contains` measures the polyline at
//! `(point - origin) / zoom` against `radius / zoom`, where the origin `rect.xy + radius` is
//! the path origin mapped.
//!
//! ## 4. Resolution
//! `resolve` scans the areas once from last to first. The hot area is the topmost: the
//! highest layer, then the last appended, so a path area drawn on a higher layer (a cable)
//! takes the press and the wheel from the box areas under its stroke. The wheel target is the
//! topmost wheel-flagged area under the point whose layer is at least the hot area's, so an
//! overlay blocks wheel input to views beneath it. The drop target is found the same way among
//! drop-flagged areas, so a popup blocks drops on what is beneath it too. All three come from
//! the same pass: a candidate replaces the best only on a strictly higher layer, so the first
//! one met on the winning layer stays.
//!
//! ## 5. Duplicate Check (`Stamps`)
//! In safe builds a table of `2 * area_cap` slots (rounded up to a power of two) records each
//! id with the frame's stamp under linear probing. A slot whose stamp is not the current one
//! is empty, so a new frame needs no clearing: `next_frame` only increments the stamp. When
//! the `u32` stamp wraps the table is zeroed once. In release builds the table has no slots
//! and the check compiles away.
//!
//! ## 6. TigerStyle Invariants
//! - `resolve` is O(areas), once per event; probing is bounded by the table size, which is at
//!   least twice the number of ids a frame can insert.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");

/// Largest `Config.area_cap`; area indices fit a `u16` count.
pub const area_cap_max: u32 = 65536;

/// A stable widget identity. See the module guide, section 2.
pub const Id = enum(u64) {
    none = 0,
    _,

    /// A second id derived from this one, for a sub-part of the same widget.
    pub fn derive(self: Id, salt: u64) Id {
        assert(self != .none);
        const mixed = finish(@backingInt(self) +% (salt +% 1) *% golden);
        assert(mixed != .none);
        return mixed;
    }
};

/// The pointer shape over an area. The tag names are the CSS cursor names with `_` for `-`;
/// the native host maps them onto `wp_cursor_shape_device_v1` shapes.
pub const Cursor = enum(u4) {
    default,
    pointer,
    text,
    grab,
    grabbing,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,
};

/// The part of the window an area stands for: a press on it goes to the compositor as a move
/// (`drag`) or a resize from that edge (`ui/cx.zig`, section 5a). `none` for every other area.
pub const WindowPart = enum(u4) {
    none,
    drag,
    top,
    bottom,
    left,
    right,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

/// What an area takes besides presses and hover. See the module guide, section 3.
pub const Flags = packed struct(u16) {
    wheel: bool,
    /// A left press focuses the area, and Tab visits it in draw order.
    focusable: bool,
    /// While the area is focused, Tab and Shift+Tab go to its widget (an editor indents)
    /// instead of moving focus. Escape still clears focus, so the keyboard can leave it.
    tab: bool,
    cursor: Cursor,
    /// The area takes dropped files: the topmost one under a file drag is its target.
    drop: bool = false,
    /// The window part a press on the area moves or resizes; `none` for a widget's area.
    window: WindowPart = .none,
    unused: u4 = 0,
};

/// One hit area. See the module guide, section 3.
pub const Area = extern struct {
    id: Id,
    rect: [4]f32,
    clip: [4]f32,
    radius: f32,
    layer: u8,
    pad: u8,
    flags: Flags,
    /// A path area's points in the point pool; `point_count == 0` for a box area.
    first_point: u32,
    point_count: u32,
    /// Screen pixels per world pixel of the canvas it was recorded in, 1 outside one: a path
    /// area's points are in world pixels (section 3a).
    zoom: f32 = 1,
    pad1: u32 = 0,
};

/// What `resolve` found under a point: indices into the area slice, or null.
pub const Resolved = struct {
    hot: ?u32,
    wheel: ?u32,
    drop: ?u32,
};

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;
const golden: u64 = 0x9e3779b97f4a7c15;

comptime {
    assert(@sizeOf(Area) == 64);
    assert(@offsetOf(Area, "zoom") == 56);
    assert(@offsetOf(Area, "first_point") == 48);
    assert(@offsetOf(Area, "rect") == 8);
    assert(@offsetOf(Area, "clip") == 24);
    assert(@offsetOf(Area, "flags") == 46);
    assert(@sizeOf(Flags) == 2);
    assert(@typeInfo(Cursor).@"enum".field_names.len == 9);
    assert(@typeInfo(WindowPart).@"enum".field_names.len == 10);
    assert(area_cap_max <= std.math.maxInt(u16) + 1);
}

/// The id of item `index` of the kind `name`. See the module guide, section 2.
pub fn id(comptime name: []const u8, index: u32) Id {
    const base = comptime fnv(name);
    const mixed = finish(base +% (@as(u64, index) +% 1) *% golden);
    assert(mixed != .none);
    return mixed;
}

fn fnv(comptime name: []const u8) u64 {
    comptime {
        assert(name.len >= 1);
        var hash: u64 = fnv_offset;
        for (name) |byte| {
            hash ^= byte;
            hash *%= fnv_prime;
        }
        return hash;
    }
}

/// The splitmix64 finalizer, mapping 0 to 1 so `Id.none` is never produced.
fn finish(seed: u64) Id {
    var z = seed;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z ^= z >> 31;
    if (z == 0) z = 1;
    assert(z != 0);
    return @fromBackingInt(@intCast(z));
}

/// True when the clip and the shape of `area` both contain `(x, y)`: its rounded rect, or
/// for a path area the points within `radius` of its polyline in `points` (section 3).
pub fn contains(area: *const Area, points: []const draw.Point, x: f32, y: f32) bool {
    assert(x == x);
    assert(y == y);
    if (x < area.clip[0]) return false;
    if (y < area.clip[1]) return false;
    if (!(x < area.clip[2])) return false;
    if (!(y < area.clip[3])) return false;
    const rect = area.rect;
    assert(rect[2] > 0);
    assert(rect[3] > 0);
    if (area.point_count == 0) {
        return draw.contains_box(rect[0], rect[1], rect[2], rect[3], area.radius, x, y);
    }
    if (x < rect[0] or x > rect[0] + rect[2]) return false;
    if (y < rect[1] or y > rect[1] + rect[3]) return false;
    assert(area.first_point + area.point_count <= points.len);
    const shape = points[area.first_point..][0..area.point_count];
    const origin_x = rect[0] + area.radius;
    const origin_y = rect[1] + area.radius;
    // In world pixels inside a canvas (section 3a); dividing by 1 elsewhere is exact.
    assert(area.zoom > 0);
    const dx = (x - origin_x) / area.zoom;
    const dy = (y - origin_y) / area.zoom;
    return draw.path.distance_to_polyline(shape, dx, dy) <= area.radius / area.zoom;
}

/// The hot area, the wheel target, and the drop target under `(x, y)`; `points` are the point
/// pool path areas index. See the module guide, section 4.
pub fn resolve(areas: []const Area, points: []const draw.Point, x: f32, y: f32) Resolved {
    assert(areas.len <= area_cap_max);
    var hot: ?u32 = null;
    var wheel: ?u32 = null;
    var drop: ?u32 = null;
    var index: u32 = @intCast(areas.len);
    while (index > 0) {
        index -= 1;
        const area = &areas[index];
        if (!contains(area, points, x, y)) continue;
        if (hot == null or area.layer > areas[hot.?].layer) hot = index;
        if (area.flags.wheel) {
            if (wheel == null or area.layer > areas[wheel.?].layer) wheel = index;
        }
        if (area.flags.drop) {
            if (drop == null or area.layer > areas[drop.?].layer) drop = index;
        }
    }
    if (wheel) |target| {
        if (areas[target].layer < areas[hot.?].layer) wheel = null;
    }
    if (drop) |target| {
        if (areas[target].layer < areas[hot.?].layer) drop = null;
    }
    if (wheel != null or drop != null) assert(hot != null);
    return .{ .hot = hot, .wheel = wheel, .drop = drop };
}

/// The duplicate-id check for frames of at most `area_cap` areas; see the module guide,
/// section 5. Zero slots outside safe builds.
pub fn Stamps(comptime area_cap: u32) type {
    const slot_count: u32 = if (std.debug.runtime_safety)
        std.math.ceilPowerOfTwoAssert(u32, 2 * area_cap)
    else
        0;
    return struct {
        const Self = @This();

        ids: [slot_count]u64,
        stamps: [slot_count]u32,
        stamp: u32,

        pub const slots: u32 = slot_count;

        pub fn init(self: *Self) void {
            @memset(&self.stamps, 0);
            self.stamp = 1;
            assert(self.stamp != 0);
        }

        /// Starts a frame: every slot becomes empty without being touched.
        pub fn next_frame(self: *Self) void {
            self.stamp +%= 1;
            if (self.stamp == 0) {
                @memset(&self.stamps, 0);
                self.stamp = 1;
            }
            assert(self.stamp != 0);
        }

        /// Records `key` for this frame. Returns false when it was already recorded.
        pub fn insert(self: *Self, key: Id) bool {
            assert(key != .none);
            if (slot_count == 0) return true;
            const bits: u64 = @backingInt(key);
            var slot: u32 = @intCast(bits & (slot_count - 1));
            var probes: u32 = 0;
            while (probes < slot_count) : (probes += 1) {
                if (self.stamps[slot] != self.stamp) {
                    self.stamps[slot] = self.stamp;
                    self.ids[slot] = bits;
                    return true;
                }
                if (self.ids[slot] == bits) return false;
                slot = (slot + 1) & (slot_count - 1);
            }
            unreachable;
        }
    };
}

const testing = std.testing;

fn test_area(key: Id, x: f32, layer: u8, wheel: bool) Area {
    return .{
        .id = key,
        .rect = .{ x, 0, 100, 100 },
        .clip = .{ 0, 0, 1000, 1000 },
        .radius = 0,
        .layer = layer,
        .flags = .{ .wheel = wheel, .focusable = false, .tab = false, .cursor = .default },
        .pad = 0,
        .first_point = 0,
        .point_count = 0,
    };
}

// Locks the id rules: stable, distinct per name and index, never `none`, and `derive` is
// distinct from its base.
test "ids are stable, distinct, and never none" {
    try testing.expectEqual(id("knob", 3), id("knob", 3));
    try testing.expect(id("knob", 3) != id("knob", 4));
    try testing.expect(id("knob", 0) != id("meter", 0));
    try testing.expect(id("knob", 0) != .none);
    try testing.expect(id("view", 0).derive(1) != id("view", 0));
    try testing.expect(id("view", 0).derive(1) != id("view", 0).derive(2));
}

// Locks the topmost rule: the highest layer wins, then the last appended on that layer.
test "topmost is the highest layer, then the last appended" {
    const areas = [_]Area{
        test_area(id("a", 0), 0, 4, false),
        test_area(id("b", 0), 0, 0, false),
        test_area(id("c", 0), 0, 4, false),
        test_area(id("d", 0), 0, 0, false),
    };
    try testing.expectEqual(@as(?u32, 2), resolve(&areas, &.{}, 50, 50).hot);
    const base_only = [_]Area{ areas[1], areas[3] };
    try testing.expectEqual(@as(?u32, 1), resolve(&base_only, &.{}, 50, 50).hot);
    try testing.expectEqual(@as(?u32, null), resolve(&areas, &.{}, 500, 50).hot);
}

// Locks that a clipped part of an area does not hit, and the rounded corner does not either.
test "clipped areas do not hit" {
    var area = test_area(id("a", 0), 0, 0, false);
    area.clip = .{ 0, 0, 50, 1000 };
    try testing.expect(contains(&area, &.{}, 49, 50));
    try testing.expect(!contains(&area, &.{}, 50, 50));
    area.clip = .{ 0, 0, 1000, 1000 };
    area.radius = 50;
    try testing.expect(contains(&area, &.{}, 50, 50));
    try testing.expect(!contains(&area, &.{}, 2, 2));
}

// Locks the wheel rule: the topmost wheel-flagged area under the point wins over a later
// plain area on the same layer, and loses to an overlay above it.
test "the wheel goes to the topmost wheel area not below the hot layer" {
    var areas = [_]Area{
        test_area(id("view", 0), 0, 0, true),
        test_area(id("label", 0), 0, 0, false),
    };
    const base = resolve(&areas, &.{}, 50, 50);
    try testing.expectEqual(@as(?u32, 1), base.hot);
    try testing.expectEqual(@as(?u32, 0), base.wheel);
    areas[1].layer = 4;
    const covered = resolve(&areas, &.{}, 50, 50);
    try testing.expectEqual(@as(?u32, 1), covered.hot);
    try testing.expectEqual(@as(?u32, null), covered.wheel);
}

// Locks the drop rule: the topmost drop-flagged area wins over a later plain area on its layer
// (a label inside a zone), the later of two zones wins, and a popup above blocks it.
test "a popup blocks the drop target beneath it" {
    var areas = [_]Area{
        test_area(id("zone", 0), 0, 0, false),
        test_area(id("zone", 1), 0, 0, false),
        test_area(id("label", 0), 0, 0, false),
    };
    areas[0].flags.drop = true;
    areas[1].flags.drop = true;
    const base = resolve(&areas, &.{}, 50, 50);
    try testing.expectEqual(@as(?u32, 2), base.hot);
    try testing.expectEqual(@as(?u32, 1), base.drop);
    try testing.expectEqual(@as(?u32, null), base.wheel);
    areas[2].layer = 5;
    const covered = resolve(&areas, &.{}, 50, 50);
    try testing.expectEqual(@as(?u32, 2), covered.hot);
    try testing.expectEqual(@as(?u32, null), covered.drop);
    try testing.expectEqual(@as(?u32, null), resolve(&areas, &.{}, 500, 50).drop);
}

// Locks the duplicate check: a repeat in one frame is refused, the next frame starts empty.
test "stamps refuse a duplicate id within a frame only" {
    const T = Stamps(4);
    var stamps: T = undefined;
    stamps.init();
    if (T.slots == 0) return;
    try testing.expectEqual(@as(u32, 8), T.slots);
    try testing.expect(stamps.insert(id("knob", 1)));
    try testing.expect(stamps.insert(id("knob", 2)));
    try testing.expect(!stamps.insert(id("knob", 1)));
    stamps.next_frame();
    try testing.expect(stamps.insert(id("knob", 1)));
}

// Locks the path shape: an L-shaped path area of radius 5 (a 4 px stroke plus the 3 px slop
// would be 5) hits within 5 px of its polyline and misses the empty corner of its rect, a
// higher-layer path area takes the hot spot from a box under its stroke only, and the
// distance is measured from the origin `rect.xy + radius`.
test "a path area hits near its polyline only" {
    const points = [_]draw.Point{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 60 } };
    const path: Area = .{
        .id = id("cable", 0),
        .rect = .{ 15, 15, 110, 70 },
        .clip = .{ 0, 0, 1000, 1000 },
        .radius = 5,
        .layer = 2,
        .flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .default },
        .pad = 0,
        .first_point = 0,
        .point_count = 3,
    };
    try testing.expect(contains(&path, &points, 70, 20));
    try testing.expect(contains(&path, &points, 70, 24.5));
    try testing.expect(!contains(&path, &points, 70, 25.5));
    // The same path recorded in a canvas at zoom 2 from (50, 40) (section 3a): every point
    // maps to `(50 + 2x, 40 + 2y)` and hits exactly where its world point did.
    var mapped = path;
    mapped.rect = .{ 50 + 2 * 15, 40 + 2 * 15, 2 * 110, 2 * 70 };
    mapped.radius = 2 * 5;
    mapped.zoom = 2;
    try testing.expect(contains(&mapped, &points, 50 + 2 * 70, 40 + 2 * 24.5));
    try testing.expect(!contains(&mapped, &points, 50 + 2 * 70, 40 + 2 * 25.5));
    try testing.expect(contains(&path, &points, 124, 60));
    try testing.expect(!contains(&path, &points, 40, 70));
    const areas = [_]Area{ test_area(id("knob", 0), 0, 0, true), path };
    try testing.expectEqual(@as(?u32, 1), resolve(&areas, &points, 70, 21).hot);
    try testing.expectEqual(@as(?u32, null), resolve(&areas, &points, 70, 21).wheel);
    try testing.expectEqual(@as(?u32, 0), resolve(&areas, &points, 40, 70).hot);
}

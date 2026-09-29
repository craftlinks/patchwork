const std = @import("std");
const assert = std.debug.assert;

/// One WGSL source for the native pipeline and the browser compile.
pub const shader_file: []const u8 = @embedFile("quad.wgsl");

pub const instance_cap: u32 = 256;
pub const instance_stride: u32 = 32;
pub const vertex_count: u32 = 6;
pub const quad_bytes: u32 = 48;
pub const matrix_bytes: u32 = 64;
/// WebGPU's minimum uniform offset alignment. The matrix sits at offset 0.
pub const uniform_bytes: u32 = 256;

pub const flag_instances: u32 = 1;
pub const flag_uniform: u32 = 2;

/// Six vertices of the unit square (0,0)–(1,1), two triangles, no index buffer.
pub const unit_quad: [12]f32 = .{
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    0.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
};

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

pub const DrawList = struct {
    items: [instance_cap]Instance,
    count: u32,
    revision: u32,

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

    pub fn clear(self: *DrawList) void {
        assert(self.count <= instance_cap);
        self.count = 0;
        self.revision += 1;
        assert(self.count == 0);
        assert(self.revision >= 1);
    }
};

/// Remembers the last uploaded revision and logical size so a present can skip
/// a buffer write. Pixel size is the swapchain's problem, not this cursor's.
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

/// Logical pixels, origin top-left, Y down. Column-major so WGSL `ortho * p` matches.
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

pub fn demo(list: *DrawList) void {
    assert(list.count == 0);
    assert(list.count + 3 <= instance_cap);
    list.append(.{
        .x = 48,
        .y = 48,
        .width = 360,
        .height = 240,
        .r = 0.85,
        .g = 0.45,
        .b = 0.28,
        .a = 1.0,
    }) catch unreachable;
    list.append(.{
        .x = 120,
        .y = 96,
        .width = 240,
        .height = 160,
        .r = 0.25,
        .g = 0.65,
        .b = 0.90,
        .a = 0.45,
    }) catch unreachable;
    list.append(.{
        .x = 48,
        .y = 320,
        .width = 480,
        .height = 40,
        .r = 0.95,
        .g = 0.90,
        .b = 0.55,
        .a = 1.0,
    }) catch unreachable;
    assert(list.count == 3);
    assert(list.revision == 3);
}

comptime {
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

test "demo writes three rectangles" {
    var list = DrawList.init();
    demo(&list);
    try std.testing.expectEqual(@as(u32, 3), list.count);
    try std.testing.expect(list.items[1].a < 1);
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

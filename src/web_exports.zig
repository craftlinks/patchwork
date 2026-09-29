const std = @import("std");
const assert = std.debug.assert;
const draw = @import("draw.zig");
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");

const State = struct {
    frame: frame.Frame,
    list: draw.DrawList,
    cursor: draw.UploadCursor,
};

var state: State = .{
    .frame = frame.Frame.init(),
    .list = draw.DrawList.init(),
    .cursor = draw.UploadCursor.init(),
};

export fn shader_ptr() [*]const u8 {
    assert(draw.shader_file.len >= 1);
    assert(draw.instance_stride == 32);
    return draw.shader_file.ptr;
}

export fn shader_len() u32 {
    assert(draw.shader_file.len >= 1);
    return @intCast(draw.shader_file.len);
}

export fn quad_ptr() [*]const f32 {
    assert(draw.quad_bytes == 48);
    return &draw.unit_quad;
}

export fn quad_bytes() u32 {
    assert(draw.unit_quad.len == 12);
    return draw.quad_bytes;
}

export fn instance_stride() u32 {
    assert(draw.instance_stride == 32);
    return draw.instance_stride;
}

export fn start() u32 {
    state.frame = frame.Frame.init();
    state.list = draw.DrawList.init();
    state.cursor = draw.UploadCursor.init();
    draw.demo(&state.list);
    assert(state.frame.running);
    assert(state.list.count == 3);
    return dirty_flag();
}

export fn resize(width_px: u32, height_px: u32) u32 {
    assert(state.frame.running);
    state.frame.apply_configure(width_px, height_px);
    assert(state.frame.width_px != 0);
    return dirty_flag();
}

export fn tick() u32 {
    assert(state.frame.running);
    if (!state.frame.redraw) {
        return 0;
    }
    if (state.frame.width_px == 0) {
        return 0;
    }
    // The header lives on this stack until present_js returns, so JS can read it.
    var header: draw.PresentHeader = undefined;
    draw.fill_header(&header, .{
        .list = &state.list,
        .cursor = state.cursor,
        .width_logical = state.frame.width_logical,
        .height_logical = state.frame.height_logical,
        .width_px = state.frame.width_px,
        .height_px = state.frame.height_px,
        .clear_r = gpu.clear_color.r,
        .clear_g = gpu.clear_color.g,
        .clear_b = gpu.clear_color.b,
        .clear_a = gpu.clear_color.a,
    });
    var unused: gpu.Gpu = .{};
    gpu.present(&unused, &header, &state.list.items) catch unreachable;
    state.cursor.mark(&state.list, state.frame.width_logical, state.frame.height_logical);
    state.frame.mark_presented();
    assert(!state.frame.redraw);
    return 0;
}

fn dirty_flag() u32 {
    if (state.frame.redraw) {
        if (state.frame.width_px != 0) {
            return 1;
        }
    }
    return 0;
}

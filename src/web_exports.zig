const std = @import("std");
const assert = std.debug.assert;
const frame = @import("frame.zig");
const gpu = @import("gpu.zig");

const State = struct {
    frame: frame.Frame,
};

var state: State = .{
    .frame = frame.Frame.init(),
};

export fn start() u32 {
    state.frame = frame.Frame.init();
    assert(state.frame.running);
    assert(state.frame.redraw);
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
    var unused: gpu.Gpu = .{};
    gpu.present_clear(
        &unused,
        state.frame.width_px,
        state.frame.height_px,
        gpu.clear_color,
    ) catch unreachable;
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

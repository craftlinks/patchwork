const linux_window = @import("linux_window.zig");

pub fn main() !void {
    var state: linux_window.State = .{
        .frame = .init(),
        .display = undefined,
        .compositor = null,
        .xdg_base = null,
        .surface = null,
        .xdg_surface = null,
        .toplevel = null,
        .gpu = undefined,
        .configure_serial = 0,
        .ack_pending = false,
        .pending_width = 0,
        .pending_height = 0,
        .global_count = 0,
    };
    try linux_window.run(&state);
}

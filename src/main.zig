//! Native Linux Application Entry Point.
//!
//! # Architecture:
//! Allocates the entire native window, graphics, and pointer input state (`linux_window.State`)
//! directly on the operating system thread's call stack.
//! In accordance with TigerStyle:
//! - Zero dynamic heap allocation.
//! - Statically allocates `DrawList` (256 instances), `UploadCursor`, and `Pointer`.
//! - Runs the power-optimal blocking Wayland event loop to completion until the window is closed.

const animator = @import("animator.zig");
const font = @import("font.zig");
const input = @import("input.zig");
const linux_window = @import("linux_window.zig");
const scene = @import("scene.zig");

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
        .list = .init(),
        .glyphs = font.GlyphList.init(),
        .cursor = .init(),
        .scene = scene.Scene.init_demo(),
        .clock = animator.Clock.init(),
        .queue = input.EventQueue.init(),
        .meter_fd = -1,
        .last_x = 0,
        .last_y = 0,
        .frame_callback = null,
        .frame_done = false,
        .frame_time_ms = 0,
        .present_at_ns = 0,
        .refresh_ns = linux_window.refresh_ns_initial,
        .last_callback_ns = 0,
        .presentation = null,
        .presentation_clock = 0,
        .vblank_ns = 0,
        .vblank_refresh_ns = 0,
        .feedback_in_flight = 0,
        .seat = null,
        .pointer_proxy = null,
        .configure_serial = 0,
        .ack_pending = false,
        .pending_width = 0,
        .pending_height = 0,
        .global_count = 0,
    };
    try linux_window.run(&state);
}

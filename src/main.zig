//! Native Linux Application Entry Point.
//!
//! # Architecture:
//! Allocates the entire native window and graphics state (`linux_window.State`) directly on
//! the operating system thread's call stack.
//! In accordance with TigerStyle:
//! - Zero dynamic heap allocation.
//! - Runs the blocking Wayland event loop to completion until the window is closed.

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
        .list = .init(),
        .cursor = .init(),
        .configure_serial = 0,
        .ack_pending = false,
        .pending_width = 0,
        .pending_height = 0,
        .global_count = 0,
    };
    try linux_window.run(&state);
}

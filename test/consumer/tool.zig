//! The consumer's tool: its own `main` over `Offscreen(App)`, which draws the app at a time it is
//! given and measures the frame. `addTool` links only libwgpu_native, so `linked.keysym` can
//! resolve only through the peer's module, and the run proves the link. The app's 500 ms timer
//! runs, and the one frame is drawn with `.ticks = .collapse`, so a time far into the app owes
//! no ticks and the timer is called once.
//!
//! ```text
//! consumer-tool <time_ms> [high|low]
//! consumer-tool: t=1500 ms, 640x360, bar 150 px, keysym 0x71, timer calls 1
//! consumer-tool: t=600000 ms, 640x360, bar 624 px, keysym 0x71, timer calls 1
//! ```

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const consumer = @import("app");
const linked = @import("linked");
const Off = patchwork.host.offscreen.Offscreen(consumer.App);

const width: u32 = 640;
const height: u32 = 360;
/// A channel this far from the background is the bar's.
const channel_apart: u32 = 32;

var pixels: [width * height * 4]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const time_ms = try std.fmt.parseInt(u64, args.next() orelse return error.MissingTime, 10);
    const adapter_name = args.next() orelse "high";
    const adapter = std.meta.stringToEnum(patchwork.bench.Adapter, adapter_name) orelse
        return error.BadAdapter;
    try Off.open(.{ .adapter = adapter, .width = width, .height = height });
    defer Off.close();
    try Off.start(.{});
    // The tool sets the app's time itself. A scrub owes a draw, as an event would.
    Off.app().time_ms = time_ms;
    Off.context().set_timer(true);
    Off.context().redraw();
    // One frame at a time the tool picks: the ticks owed since 0 collapse into one call.
    try Off.frame(.{ .time_ms = time_ms, .dt_ms = 0, .ticks = .collapse });
    const frame = try Off.read(.rgba, &pixels);
    const format = "consumer-tool: t={d} ms, {d}x{d}, bar {d} px, keysym 0x{x}, timer calls {d}\n";
    std.debug.print(format, .{
        time_ms,
        frame.width,
        frame.height,
        bar_length(frame.bytes),
        linked.keysym("q"),
        Off.app().timer_calls,
    });
}

/// The bar's length in device pixels: pixels of its row that differ from the background, the
/// last pixel of the row just above the bar (a bar may run to the edge).
fn bar_length(bytes: []const u8) u32 {
    assert(bytes.len == pixels.len);
    const row: u32 = @intFromFloat(consumer.bar_y + consumer.bar_height / 2);
    const start = row * width * 4;
    const line = bytes[start..][0 .. width * 4];
    const above: u32 = @intFromFloat(consumer.bar_y - 1);
    assert(above < row);
    const background = bytes[(above + 1) * width * 4 - 4 ..][0..4];
    var length: u32 = 0;
    for (0..width) |x| {
        const pixel = line[x * 4 ..][0..4];
        var apart: u32 = 0;
        for (pixel[0..3], background[0..3]) |a, b| {
            apart = @max(apart, if (a > b) a - b else b - a);
        }
        if (apart >= channel_apart) length += 1;
    }
    assert(length <= width);
    return length;
}

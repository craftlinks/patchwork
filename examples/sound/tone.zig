//! The glue between Thrum's test tone and a Patchwork app: what the audio and rack examples share
//! to play the tone and see its blocks (Patchwork's step 55).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Roles
//! ```text
//! natively   thrum.pipewire.Device(testtone) --monitor--> drain on the UI thread
//!                        audio thread --monitor_hook--> the app's patchwork.Wake
//! elsewhere  produce(frames) renders the offline engine --monitor--> drain
//! a page     Thrum's worklet --posts--> tone_inbox, tone_push --> page_monitor --> drain
//! ```
//! The app owns one `Tone` as a field and declares Patchwork's producer contract over it
//! (`app.zig`, section 4e): `wake`, `pending`, `drain`, and `produce` each forward here. Space
//! calls `set_playing`. The tone's blocks reach the app through `pop`, on the UI thread.
//!
//! ## 2. Natively
//! `args` calls `allow_device`; only the native window host calls `args`, so `--bench`, regress,
//! and the tests never touch the audio server and play through the offline engine instead. A start
//! opens the device, the tone from its first frame, where both sines are 0, so it does not click;
//! a stop calls `Device.stop`, which fades the volume to 0 and closes the stream. Stopped, nothing
//! runs: no stream, no blocks, no wake. The device's monitor hook notifies the app's `Wake` after
//! each block, which writes the poll loop's `eventfd` only while the UI sleeps armed.
//!
//! ## 3. Where No Device Plays
//! `produce(frames)` renders the blocks `frames` of sample time owe into the offline engine while
//! the tone plays, keeping the frames short of a block for the next call. Stopped, it renders and
//! keeps nothing, so the tone's clock waits, as Patchwork's audio pacing did: at regress's 60 fps
//! that is 6, 6, 6, 7 blocks a frame from the start.
//!
//! ## 4. In a Page
//! A start calls the import `tone_run(1)` from Space's key handler, so the page has the user
//! activation an `AudioContext` needs. `tone.js` (the app's web module) creates the context and
//! Thrum's worklet the first time, from this same wasm, which carries the tone's `thrum_*` exports
//! (`exports`), with `monitor: true`; later starts resume it and stops suspend it. Each post comes
//! back through `tone_inbox` and `tone_push` into `page_monitor`, and `shell.wake()` schedules the
//! frame that drains it. `tone_run` returns 0 in a replay (`?bench=`), which stays offline.
//!
//! ## 5. Stopped Blocks
//! `pop` returns blocks only while the tone plays. Stopped, it discards what waits: a block that
//! was rendered before the stop and drained after it is not shown, so a stopped scope keeps its
//! window. `dropped` is the blocks the monitors refused, summed over every stream opened.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: the device, the engine, and the monitors are fields of the app.
//! - `pop` is bounded by the monitor's capacity in its callers' loops; `produce` by
//!   `monitor_blocks` blocks a call.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const thrum = @import("thrum");
const testtone = @import("testtone");

/// Blocks a monitor holds: 256 blocks of 2.67 ms, 683 ms, as long a stall as the UI may have
/// before it loses a block to look at.
pub const monitor_blocks: u32 = 256;
pub const config: thrum.Config = .{ .monitor_blocks = monitor_blocks };

pub const Engine = thrum.Engine(testtone, config);
pub const Monitor = Engine.Monitor;
/// One block of the tone: L and R, planar.
pub const Block = Engine.B;
pub const channels: u8 = testtone.channels;

/// The quantum the device asks for: 21.3 ms at 48 kHz, PipeWire's default. At 256 (5.3 ms) the
/// audio example popped every second or two on a Scarlett 4i4 with no xrun reported and clean
/// samples in the graph (2026-11-10); a test signal for meters needs no low latency.
const latency_frames: u32 = 1024;
/// Blocks one worklet post carries (Thrum's `web/worklet.js`, section 5b).
const inbox_blocks: u32 = 8;

const is_wasm = builtin.target.cpu.arch.isWasm();
const Device = if (is_wasm) void else thrum.pipewire.Device(testtone, config);
/// The tone in the page's worklet, which only the worklet's instance of the wasm renders.
const PageWeb = thrum.web.Web(testtone, &.{});

comptime {
    assert(channels == 2);
    assert(@sizeOf(Block) == 1024);
    assert(@as(u64, monitor_blocks) * thrum.block_frames * 1000 / thrum.sample_rate_hz == 682);
    assert(inbox_blocks <= monitor_blocks);
}

/// The page's producer, in `tone.js` (section 4): starts or resumes the page's sound and returns
/// 1, stops it and returns 1, or returns 0 in a replay, which stays offline.
extern "env" fn tone_run(on: u32) u32;

/// What a start reports: played, or the reason the device did not open (section 2).
pub const Start = union(enum) {
    playing,
    failed: []const u8,
};

/// The tone, its hosts, and the blocks it rendered. See the module guide.
pub const Tone = struct {
    /// The app's wake, which the device's monitor hook notifies (section 2).
    wake_value: patchwork.Wake,
    device: Device,
    /// Whether the window host called `args`, so a start may open the device.
    device_allowed: bool,
    device_open: bool,
    node_name: [*:0]const u8,
    /// The tone where no device plays, and its frames short of a block (section 3).
    offline: Engine,
    frames_short: u32,
    /// The page's monitor, filled from the worklet's posts, and whether the page plays (section 4).
    page_monitor: Monitor,
    page_started: bool,
    playing: bool,
    /// Blocks refused by device monitors already closed (section 5).
    dropped_closed: u32,

    /// A stopped tone on no device, its stream to be named `node_name` in `pw-top`.
    pub fn init(tone: *Tone, node_name: [*:0]const u8) void {
        tone.wake_value = .init(-1);
        tone.device = undefined;
        tone.device_allowed = false;
        tone.device_open = false;
        tone.node_name = node_name;
        tone.offline.init(.init());
        tone.frames_short = 0;
        tone.page_monitor = .empty;
        tone.page_started = false;
        tone.playing = false;
        tone.dropped_closed = 0;
        page.instance = tone;
        assert(tone.pending() == 0);
        assert(!tone.playing);
    }

    /// Lets a start open the audio device: the native window host's `args` only (section 2).
    pub fn allow_device(tone: *Tone) void {
        assert(!tone.playing);
        if (is_wasm) return;
        tone.device_allowed = true;
    }

    /// Starts or stops the tone on whichever host plays it (sections 2 to 4).
    pub fn set_playing(tone: *Tone, on: bool) Start {
        assert(tone.playing != on);
        if (is_wasm) {
            if (tone_run(@intFromBool(on)) == 1) tone.page_started = true;
        } else if (tone.device_allowed) {
            if (on) {
                if (tone.device_start()) |reason| return .{ .failed = reason };
            } else {
                tone.device_stop();
            }
        }
        tone.playing = on;
        assert(tone.playing == on);
        return .playing;
    }

    /// Opens the device; returns the reason it did not open, or null.
    fn device_start(tone: *Tone) ?[]const u8 {
        assert(!is_wasm);
        assert(!tone.device_open);
        tone.device.open(.{
            .frames_max = null,
            .latency_frames = latency_frames,
            .node_name = tone.node_name,
            .control = .init(),
            .monitor_hook = .{ .context = &tone.wake_value, .function = hook_notify },
        }) catch |err| return @errorName(err);
        tone.device_open = true;
        return null;
    }

    /// Fades and closes the device, keeping its monitor's refusals (section 5).
    fn device_stop(tone: *Tone) void {
        assert(!is_wasm);
        assert(tone.device_open);
        _ = tone.device.stop();
        tone.dropped_closed +%= tone.device.engine.monitor.dropped.load(.monotonic);
        tone.device_open = false;
    }

    pub fn wake(tone: *Tone) *patchwork.Wake {
        return &tone.wake_value;
    }

    /// The monitor blocks arrive in: the device's, the page's, or the offline engine's.
    fn monitor(tone: *Tone) *Monitor {
        if (!is_wasm and tone.device_open) return &tone.device.engine.monitor;
        if (is_wasm and tone.page_started) return &tone.page_monitor;
        return &tone.offline.monitor;
    }

    /// Blocks waiting; the host reads it before a sleep (`wake.zig`, section 2).
    pub fn pending(tone: *const Tone) u32 {
        const count = @constCast(tone).monitor().pending();
        assert(count <= monitor_blocks);
        return count;
    }

    /// The oldest block waiting while the tone plays; stopped, discards every block (section 5).
    pub fn pop(tone: *Tone) ?Block {
        const from = tone.monitor();
        if (tone.playing) return from.pop();
        var discarded: u32 = 0;
        while (discarded < monitor_blocks) : (discarded += 1) {
            _ = from.pop() orelse break;
        }
        assert(from.pending() == 0 or discarded == monitor_blocks);
        return null;
    }

    /// Renders the blocks `frames` of sample time owe into the offline engine (section 3).
    pub fn produce(tone: *Tone, frames: u32) void {
        assert(frames <= patchwork.bench.producer_frames_max);
        if (!tone.playing) return;
        if (!is_wasm and tone.device_open) return;
        if (is_wasm and tone.page_started) return;
        const total = tone.frames_short + frames;
        const blocks = total / thrum.block_frames;
        tone.frames_short = total % thrum.block_frames;
        assert(blocks <= monitor_blocks);
        for (0..blocks) |_| _ = tone.offline.render();
    }

    /// Blocks the monitors refused, over every stream opened (section 5).
    pub fn dropped(tone: *const Tone) u32 {
        const open: u32 = if (!is_wasm and tone.device_open)
            tone.device.engine.monitor.dropped.load(.monotonic)
        else
            0;
        if (open > 0) assert(tone.device_open);
        // Counts wrap by design, as the monitors' own do.
        return tone.dropped_closed +% open +%
            tone.offline.monitor.dropped.load(.monotonic) +%
            tone.page_monitor.dropped.load(.monotonic);
    }
};

/// The device's `monitor_hook` (section 2): runs on the audio thread after each block.
fn hook_notify(context: *anyopaque) void {
    const wake_value: *patchwork.Wake = @ptrCast(@alignCast(context));
    wake_value.notify();
}

/// The page's side (section 4): the inbox the web module copies a post into.
const page = struct {
    var instance: *Tone = undefined;
    var inbox: [inbox_blocks]Block = undefined;

    fn tone_inbox() callconv(.c) [*]f32 {
        return @ptrCast(&inbox);
    }

    /// Pushes the first `blocks` inbox blocks into the page's monitor; returns those it took.
    fn tone_push(blocks: u32) callconv(.c) u32 {
        if (blocks > inbox_blocks) return 0;
        var taken: u32 = 0;
        for (inbox[0..blocks]) |block| {
            if (instance.page_monitor.push(block)) taken += 1;
        }
        assert(taken <= blocks);
        return taken;
    }
};

/// The wasm's exports for the page (section 4): the tone's own for Thrum's worklet, which renders
/// from a second instance of the app's wasm, and the inbox. Call from the app's root `comptime`.
pub fn exports() void {
    if (!is_wasm) return;
    PageWeb.exports();
    @export(&page.tone_inbox, .{ .name = "tone_inbox" });
    @export(&page.tone_push, .{ .name = "tone_push" });
}

const testing = std.testing;

/// A tone with nothing allowed, as regress and the tests have it.
var fixture: Tone = undefined;

// Locks section 3: started, 60 frames of `produce` at 60 fps render 375 blocks, a second, as 6, 6,
// 6, 7 a frame, and `pop` hands them out in order as the test tone's samples; stopped, `produce`
// renders nothing and `pop` discards what waits.
test "produce renders the tone's blocks where no device plays" {
    const tone = &fixture;
    tone.init("test");
    try testing.expect(tone.set_playing(true) == .playing);
    var popped: u32 = 0;
    for (0..60) |frame| {
        tone.produce(patchwork.bench.producer_frames_at(frame, 60));
        const expected: u32 = if (frame % 4 == 3) 7 else 6;
        try testing.expectEqual(expected, tone.pending());
        while (tone.pop()) |block| : (popped += 1) {
            const first: u64 = @as(u64, popped) * thrum.block_frames;
            try testing.expectEqual(testtone.sample(first + 5, testtone.voices[0]), block[0][5]);
            try testing.expectEqual(testtone.sample(first + 5, testtone.voices[1]), block[1][5]);
        }
    }
    try testing.expectEqual(@as(u32, 375), popped);
    tone.produce(800);
    try testing.expect(tone.set_playing(false) == .playing);
    try testing.expect(tone.pop() == null);
    try testing.expectEqual(@as(u32, 0), tone.pending());
    tone.produce(800);
    try testing.expectEqual(@as(u32, 0), tone.pending());
    try testing.expectEqual(@as(u32, 0), tone.dropped());
}

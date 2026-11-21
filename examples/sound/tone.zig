//! The glue between Thrum's test tone and a Patchwork app: what the audio and rack examples share
//! to play the tone and see its blocks (Patchwork's step 55).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Roles
//! ```text
//! natively   thrum.Player: pipewire.Device(testtone) --monitor--> drain on the UI thread
//!                        audio thread --monitor_hook--> the app's patchwork.Wake
//! elsewhere  produce(frames) renders the offline engine --monitor--> drain
//! a page     Thrum's worklet --posts--> thrum_page_inbox, thrum_page_push --> the player's
//!            page monitor --> drain
//! ```
//! The app owns one `Tone` as a field and declares Patchwork's producer contract over it
//! (`app.zig`, section 4e): `wake`, `pending`, `drain`, and `produce` each forward here. Space
//! calls `set_playing`. The tone's blocks reach the app through `pop`, on the UI thread. The
//! device, the page's start, and the page's monitor and inbox are `thrum.Player`'s (Thrum's
//! `player.zig`); what is left here is what serves Patchwork: the offline engine `produce` steps,
//! the wake and its hook, and the stopped-block rule.
//!
//! ## 2. Natively
//! `args` calls `allow_device`; only the native window host calls `args`, so `--bench`, regress,
//! and the tests never touch the audio server and play through the offline engine instead. A start
//! opens the device, the tone from its first frame, where both sines are 0, so it does not click;
//! a stop fades the volume to 0 and closes the stream. Stopped, nothing runs: no stream, no
//! blocks, no wake. The device's monitor hook notifies the app's `Wake` after each block, which
//! writes the poll loop's `eventfd` only while the UI sleeps armed.
//!
//! ## 3. Where No Device Plays
//! `produce(frames)` renders the blocks `frames` of sample time owe into the offline engine while
//! the tone plays and the player has no host (`player.host == .none`: no device, and no page or a
//! page that refused), keeping the frames short of a block for the next call. Stopped, it renders
//! and keeps nothing, so the tone's clock waits, as Patchwork's audio pacing did: at regress's 60
//! fps that is 6, 6, 6, 7 blocks a frame from the start.
//!
//! ## 4. In a Page
//! A start calls the player's `play` from Space's key handler, which calls the import
//! `thrum_page_play(1)`, so the page has the user activation an `AudioContext` needs. `tone.js`
//! (the app's web module) is a call of Thrum's `player` (`web/node.js`): it creates the context and
//! Thrum's worklet the first time, from this same wasm, which carries the tone's `thrum_*` exports
//! (`exports`), with `monitor: true`; later starts resume it and stops suspend it. Each post comes
//! back through `thrum_page_inbox` and `thrum_page_push` into the player's page monitor, and
//! `shell.wake()` schedules the frame that drains it. The import returns 0 in a replay
//! (`?bench=`), which stays offline.
//!
//! ## 5. Stopped Blocks
//! `pop` returns blocks only while the tone plays. Stopped, it discards what waits: a block that
//! was rendered before the stop and drained after it is not shown, so a stopped scope keeps its
//! window. `dropped` is the blocks the monitors refused, summed over every stream opened.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: the player, the engine, and the monitors are fields of the app.
//! - `playing` is kept equal to `player.playing`.
//! - `pop` is bounded by the monitor's capacity in its callers' loops; `produce` by
//!   `monitor_blocks` blocks a call.

const std = @import("std");
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

const Player = thrum.Player(testtone, config);

comptime {
    assert(channels == 2);
    assert(@sizeOf(Block) == 1024);
    assert(@as(u64, monitor_blocks) * thrum.block_frames * 1000 / thrum.sample_rate_hz == 682);
    assert(thrum.player.inbox_blocks <= monitor_blocks);
}

/// What a start reports: played, or the reason the device did not open (section 2).
pub const Start = union(enum) {
    playing,
    failed: []const u8,
};

/// The tone, its hosts, and the blocks it rendered. See the module guide.
pub const Tone = struct {
    /// The app's wake, which the device's monitor hook notifies (section 2).
    wake_value: patchwork.Wake,
    /// The device natively and the page's node elsewhere (section 1).
    player: Player,
    /// The tone where no device plays, and its frames short of a block (section 3).
    offline: Engine,
    frames_short: u32,
    /// Equal to `player.playing`.
    playing: bool,

    /// A stopped tone on no device, its stream to be named `node_name` in `pw-top`.
    pub fn init(tone: *Tone, node_name: [*:0]const u8) void {
        tone.wake_value = .init(-1);
        tone.player.init(.{
            .node_name = node_name,
            .latency_frames = latency_frames,
            .monitor_hook = .{ .context = &tone.wake_value, .function = hook_notify },
        });
        tone.offline.init(.init());
        tone.frames_short = 0;
        tone.playing = false;
        assert(tone.pending() == 0);
        assert(!tone.playing);
    }

    /// Lets a start open the audio device: the native window host's `args` only (section 2).
    pub fn allow_device(tone: *Tone) void {
        assert(!tone.playing);
        tone.player.allow_device();
    }

    /// Starts or stops the tone on whichever host plays it (sections 2 to 4).
    pub fn set_playing(tone: *Tone, on: bool) Start {
        assert(tone.playing != on);
        assert(tone.playing == tone.player.playing);
        if (on) {
            switch (tone.player.play()) {
                .failed => |reason| return .{ .failed = reason },
                .device, .page, .none => {},
            }
        } else {
            tone.player.stop();
        }
        tone.playing = on;
        assert(tone.playing == tone.player.playing);
        return .playing;
    }

    pub fn wake(tone: *Tone) *patchwork.Wake {
        return &tone.wake_value;
    }

    /// The monitor blocks arrive in: the player's, or the offline engine's.
    fn monitor(tone: *Tone) *Monitor {
        return tone.player.monitor() orelse &tone.offline.monitor;
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
        if (tone.player.host != .none) return;
        const total = tone.frames_short + frames;
        const blocks = total / thrum.block_frames;
        tone.frames_short = total % thrum.block_frames;
        assert(blocks <= monitor_blocks);
        for (0..blocks) |_| _ = tone.offline.render();
    }

    /// Blocks the monitors refused, over every stream opened (section 5).
    pub fn dropped(tone: *const Tone) u32 {
        // Counts wrap by design, as the monitors' own do.
        return tone.player.dropped() +% tone.offline.monitor.dropped.load(.monotonic);
    }
};

/// The device's `monitor_hook` (section 2): runs on the audio thread after each block.
fn hook_notify(context: *anyopaque) void {
    const wake_value: *patchwork.Wake = @ptrCast(@alignCast(context));
    wake_value.notify();
}

/// The wasm's exports for the page (section 4): the tone's own for Thrum's worklet, which renders
/// from a second instance of the app's wasm, and the inbox. Call from the app's root `comptime`.
pub fn exports() void {
    Player.exports();
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

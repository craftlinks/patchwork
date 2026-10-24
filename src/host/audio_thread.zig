//! Native audio engine: the app's `Audio` source on its own thread, paced by the clock.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Role
//! `Engine(Audio)` owns the app's audio source (`app.zig`, section 4a) and renders it into the
//! audio queue (`realtime.zig`) off the UI thread, then wakes the UI if it is asleep. Natively
//! there is no audio device yet, so the thread is paced by `CLOCK_MONOTONIC` at the rate a
//! device would pull: `post_blocks` blocks every `post_ns(1)` (10.67 ms at 48 kHz). A PipeWire
//! sink would replace the clock with the device's callback and keep the queue and the wake.
//!
//! ## 2. States and the Park
//! `state` is a futex word: `stopped`, `running`, or `quit`. The UI thread writes it
//! (`set_running`, `finish`) and wakes the futex; the thread reads it before every post. A
//! stopped thread sleeps in `FUTEX_WAIT` until the word changes, so a stopped source costs
//! nothing. The thread is spawned at the first start, never before, and joined by `finish`.
//!
//! ## 3. Pacing
//! A start anchors the clock: post `k` is due at `anchor + post_ns(k)`, computed in integers
//! (`k * 512 * 10^9 / rate` in `u128`), so the posts do not drift. The thread renders a post,
//! notifies, and sleeps with `clock_nanosleep(ABSTIME)` until the next deadline. When it wakes
//! more than `late_posts_max` posts late (a stall, or a suspend), it re-anchors at the current
//! time and counts it in `late`, rather than rendering the backlog in a burst.
//!
//! ## 4. A Full Queue
//! A post renders every block even when the queue has no slot: the block goes into `scratch`
//! and is counted as dropped (`Queue.refuse`), so the source's own clock keeps running and the
//! tone stays continuous when the UI catches up.
//!
//! ## 5. TigerStyle Invariants
//! - The engine is static in the host; the thread's stack is `stack_bytes`; nothing allocates.
//! - The thread loop is unbounded by design (it lives until `finish`); each iteration is one
//!   post of `post_blocks` blocks, and the `EINTR` retry of the sleep is bounded.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const realtime = @import("../realtime.zig");

/// The futex word's values.
const stopped: u32 = 0;
const running: u32 = 1;
const quit: u32 = 2;

/// The audio thread's stack. The source renders into the queue in place, so little is needed,
/// but glibc's `pthread_create` refuses (EINVAL) a stack below its minimum plus the binary's
/// static TLS, which 256 KiB was not for the test binary.
const stack_bytes: usize = 1024 * 1024;

/// Posts behind schedule before the clock re-anchors (section 3).
const late_posts_max: u64 = 2;

/// Retries of an interrupted sleep before the post goes ahead anyway.
const eintr_max: u32 = 8;

/// Frames per post.
const post_frames: u64 = realtime.block_frames * realtime.post_blocks;

/// Nanoseconds from the anchor to post `posts` at `rate` (section 3).
pub fn post_ns(posts: u64, rate: u32) u64 {
    assert(rate != 0);
    const ns = @as(u128, posts) * post_frames * std.time.ns_per_s / rate;
    assert(ns <= std.math.maxInt(u64));
    return @intCast(ns);
}

/// The engine for one app's source (module guide, section 1).
pub fn Engine(comptime Audio: type) type {
    return struct {
        const Self = @This();

        source: Audio,
        rate: u32,
        queue: *realtime.AudioQueue,
        wake: *realtime.Wake,
        /// The futex word (section 2).
        state: std.atomic.Value(u32),
        thread: ?std.Thread,
        /// Re-anchors after a stall (section 3), written only by the thread.
        late: std.atomic.Value(u32),
        /// Where a post renders a block the full queue refused (section 4).
        scratch: realtime.Block,

        /// Initializes the source at `rate`. No thread runs until the first `set_running`.
        pub fn init(
            self: *Self,
            queue: *realtime.AudioQueue,
            wake: *realtime.Wake,
            rate: u32,
        ) void {
            Audio.init(&self.source, rate);
            self.rate = rate;
            self.queue = queue;
            self.wake = wake;
            self.state = .init(stopped);
            self.thread = null;
            self.late = .init(0);
            assert(self.thread == null);
        }

        /// UI thread: starts or parks the thread to match `on`; spawns it at the first start.
        pub fn set_running(self: *Self, on: bool) !void {
            assert(self.state.load(.monotonic) != quit);
            self.state.store(if (on) running else stopped, .release);
            if (on and self.thread == null) {
                self.thread = try std.Thread.spawn(.{ .stack_size = stack_bytes }, main, .{self});
            }
            futex_wake(&self.state);
        }

        /// UI thread: ends and joins the thread, if one was spawned.
        pub fn finish(self: *Self) void {
            self.state.store(quit, .release);
            futex_wake(&self.state);
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }

        /// Renders `count` blocks into the queue, counting a refused one (section 4). The
        /// thread calls it per post; the bench calls it on the UI thread with no thread running.
        pub fn render(self: *Self, count: u32) void {
            assert(count <= realtime.post_blocks * 2);
            var index: u32 = 0;
            while (index < count) : (index += 1) {
                if (self.queue.slot()) |block| {
                    Audio.render(&self.source, block);
                    self.queue.publish();
                } else {
                    Audio.render(&self.source, &self.scratch);
                    self.queue.refuse();
                }
            }
        }

        fn main(self: *Self) void {
            var anchor_ns: u64 = monotonic_ns();
            var posts: u64 = 0;
            while (true) {
                const now_state = self.state.load(.acquire);
                if (now_state == quit) break;
                if (now_state == stopped) {
                    futex_wait(&self.state, stopped);
                    anchor_ns = monotonic_ns();
                    posts = 0;
                    continue;
                }
                assert(now_state == running);
                self.render(realtime.post_blocks);
                self.wake.notify();
                posts += 1;
                const deadline_ns = anchor_ns + post_ns(posts, self.rate);
                const now_ns = monotonic_ns();
                if (now_ns > deadline_ns + post_ns(late_posts_max, self.rate)) {
                    _ = self.late.fetchAdd(1, .monotonic);
                    anchor_ns = now_ns;
                    posts = 0;
                    continue;
                }
                sleep_until(deadline_ns);
            }
        }
    };
}

fn futex_wake(word: *std.atomic.Value(u32)) void {
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, 1);
}

/// Sleeps while `word` is `expected`. A spurious return is fine: the caller re-reads it.
fn futex_wait(word: *std.atomic.Value(u32), expected: u32) void {
    _ = linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}

fn sleep_until(deadline_ns: u64) void {
    const spec: linux.timespec = .{
        .sec = @intCast(deadline_ns / std.time.ns_per_s),
        .nsec = @intCast(deadline_ns % std.time.ns_per_s),
    };
    var tries: u32 = 0;
    while (tries < eintr_max) : (tries += 1) {
        const rc = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &spec, null);
        if (linux.errno(rc) != .INTR) return;
    }
}

fn monotonic_ns() u64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    assert(rc == 0);
    assert(ts.sec >= 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

comptime {
    assert(post_frames == 512);
    assert(late_posts_max >= 1);
}

// Locks the pacing arithmetic (section 3): post 1 is 10,666,666 ns after the anchor at 48 kHz,
// and 3 posts are exactly 32 ms, so the integer schedule does not drift.
test "posts are due at exact integer times" {
    try std.testing.expectEqual(@as(u64, 10_666_666), post_ns(1, 48_000));
    try std.testing.expectEqual(@as(u64, 32_000_000), post_ns(3, 48_000));
    try std.testing.expectEqual(@as(u64, 3_600 * std.time.ns_per_s), post_ns(337_500, 48_000));
}

// Locks the full-queue rule (section 4): a post into a queue with one free slot publishes one
// block and counts the rest as dropped, and the source's clock advances by every block.
test "a post into a full queue renders and drops" {
    const Engine_ = Engine(realtime.TestTone);
    const static = struct {
        var queue: realtime.AudioQueue = undefined;
        var engine: Engine_ = undefined;
    };
    static.queue.init();
    var wake = realtime.Wake.init(-1);
    static.engine.init(&static.queue, &wake, realtime.sample_rate);
    var filled: u32 = 0;
    while (filled < realtime.queue_blocks - 1) : (filled += 1) {
        try std.testing.expect(static.queue.push(&realtime.Block.silent));
    }
    static.engine.render(realtime.post_blocks);
    try std.testing.expectEqual(realtime.queue_blocks, static.queue.pending());
    try std.testing.expectEqual(@as(u32, 3), static.queue.dropped_count());
    try std.testing.expectEqual(@as(u64, 4 * 128), static.engine.source.frame);
}

// Locks the thread's lifecycle against a real clock: started, it posts and notifies an armed
// wake within a few posts; stopped, it parks; `finish` joins it.
test "the thread posts while running and joins on finish" {
    const Engine_ = Engine(realtime.TestTone);
    const static = struct {
        var queue: realtime.AudioQueue = undefined;
        var engine: Engine_ = undefined;
    };
    static.queue.init();
    var wake = realtime.Wake.init(-1);
    static.engine.init(&static.queue, &wake, realtime.sample_rate);
    _ = wake.arm(&static.queue);
    try static.engine.set_running(true);
    var waited: u32 = 0;
    while (static.queue.pending() < 8 and waited < 200) : (waited += 1) {
        sleep_until(monotonic_ns() + 5 * std.time.ns_per_ms);
    }
    try std.testing.expect(static.queue.pending() >= 8);
    try std.testing.expectEqual(@as(u32, 1), wake.notified.raw);
    try static.engine.set_running(false);
    static.engine.finish();
    try std.testing.expect(static.engine.thread == null);
}

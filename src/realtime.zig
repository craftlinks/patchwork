//! Data from another thread into the UI: audio blocks, a single-producer queue, and a wake.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Queue and a Wake
//! Meters and scopes show what an audio engine is producing, and the engine runs on its own
//! clock: an audio thread natively, an AudioWorklet in the browser. A timer that samples
//! levels wakes the UI whether or not anything changed and is not synced to the display. Here
//! the producer pushes fixed blocks into a lock-free ring and wakes the UI only when the UI is
//! asleep; a UI that is presenting frames drains the ring once per frame, so the producer makes
//! no syscall while frames flow, and nothing at all runs while audio is stopped.
//! ```text
//! producer (audio thread / worklet)          consumer (UI thread)
//!   slot() -> render into it -> publish()      peek() -> App.audio(block) -> release()
//!   ... post_blocks times, then wake.notify()  before sleeping: wake.arm(queue)
//! ```
//!
//! ## 2. Blocks and Rates
//! A `Block` is `block_frames` (128, the Web Audio render quantum) stereo frames interleaved
//! as `[L, R]` `f32`: 1 KiB. `sample_rate` is 48 kHz. The producer posts `post_blocks` (4)
//! blocks at a time, 512 frames or 10.67 ms. `AudioQueue` holds `queue_blocks` (256), 683 ms.
//!
//! ## 3. The Queue
//! `Queue(T, capacity)` is a ring of `capacity` slots, a power of two. `head` is written only by
//! the producer, `tail` only by the consumer, each on its own cache line; indices wrap as
//! `u32` and the slot is `index & (capacity - 1)`, so `head -% tail` is the count even across
//! the wrap. The producer renders into `slot()` in place and makes it visible with `publish()`
//! (a release store of `head`); the consumer reads `peek()` and gives the slot back with
//! `release()` (a release store of `tail`, which the producer's acquire load of `tail` pairs
//! with before it reuses the slot). A full queue returns no slot: the producer counts the block
//! in `dropped` and carries on. It never overwrites, never blocks, and never corrupts, so
//! overflow is a counted drop by construction and not an assert that ReleaseFast removes.
//!
//! ## 4. The Wake and the Lost-Wakeup Argument
//! `Wake` lives in `wake.zig` since step 54, where any producer can use it; this file names it.
//! It is an `armed` flag and a descriptor (an `eventfd` natively, -1 in the browser and in
//! tests). The producer calls `notify` after each post: if `armed` was set, it clears it and
//! writes the descriptor once. The consumer calls `arm(queue)` just before it sleeps: it sets
//! `armed`, then loads the queue's `head`; if a block is pending it disarms and skips the sleep.
//! The producer's `head` store precedes its swap of `armed`, and the consumer's store of
//! `armed` precedes its load of `head`; all four are `seq_cst`, so they sit in one total order
//! and at least one side sees the other: either the producer sees `armed` and writes, or the
//! consumer sees the block and does not sleep. A UI that never arms (it is presenting, so its
//! frame callback will wake it) costs the producer one atomic swap per post.
//!
//! ## 5. The Test Tone
//! `TestTone` is a valid app `Audio` source (`app.zig`): L is a 220 Hz sine and R a 330 Hz sine,
//! 3:2, so an XY plot is a closed Lissajous figure. Each sine has a triangle gain `0.05 + 0.45 *
//! tri` with periods of 2 s and 3 s, so meters sweep; the peak is 0.5 (-6 dBFS). Phase is the
//! integer `(n * hz) mod rate` of the sample counter `n`, so there is no accumulated drift.
//!
//! ## 6. Analysis
//! - `levels(block)`: peak `max |x|` and RMS `sqrt(sum x^2 / 128)` of L, R, and mid `(L+R)/2`.
//! - `meter_of(level)`: dBFS mapped onto `[0, 1]` over `meter_range_db` (60 dB):
//!   `clamp((20 log10(level) + 60) / 60, 0, 1)`, and 0 for silence.
//! - `Ballistics`: per block, `value = max(new, value - fall_per_block)` with a fall of
//!   `fall_db_per_s` (24 dB/s, 0.064 dB per block), and a `hold` that keeps its maximum for
//!   `hold_blocks` (1 s) before falling the same way. Counted in blocks, not seconds, so a bench
//!   run that feeds the same blocks draws the same frames.
//! - `Scope(window)`: the last `2 * window` frames per channel and a window of `window` frames
//!   that starts at the latest rising zero crossing of L (`x[i-1] < 0 <= x[i]`) leaving a full
//!   window after it, or at the newest window when there is none (free run); `newest` is the
//!   newest window always, for an XY plot.
//!
//! ## 7. Bench Schedule
//! Bench dumps must not depend on a thread, so the native bench feeds blocks on the UI thread:
//! `blocks_for_frame(n)` is how many blocks frame `n` of a 60 Hz run receives, 6, 6, 6, 7, which
//! is 800 frames per display frame at 48 kHz (test "the bench schedule").
//!
//! ## 8. TigerStyle Invariants
//! - No allocation: the queue, the scope history, and the blocks are fixed arrays.
//! - Every loop is bounded by `block_frames`, `capacity`, or `window`.
//! - Counters wrap by design (`u32` indices) and the wrap is tested.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// Interleaved channels per frame: L and R.
pub const channels: u32 = 2;
/// Frames per block: the Web Audio render quantum.
pub const block_frames: u32 = 128;
/// The rate the hosts ask for. The browser passes the rate it got to `Audio.init`.
pub const sample_rate: u32 = 48_000;
/// Blocks per producer post: 512 frames, 10.67 ms at 48 kHz.
pub const post_blocks: u32 = 4;
/// Blocks the audio queue holds: 32,768 frames, 683 ms at 48 kHz.
pub const queue_blocks: u32 = 256;
/// The span producer and consumer indices are kept apart by.
const cache_line: u32 = 64;

/// One block of interleaved stereo frames (section 2).
pub const Block = extern struct {
    samples: [block_frames * channels]f32,

    pub const silent: Block = .{ .samples = @splat(0) };

    /// Frame `index` as `{ L, R }`.
    pub fn frame(self: *const Block, index: u32) [2]f32 {
        assert(index < block_frames);
        return .{ self.samples[index * 2], self.samples[index * 2 + 1] };
    }
};

/// The queue the hosts carry audio blocks through.
pub const AudioQueue = Queue(Block, queue_blocks);

/// A single-producer, single-consumer ring of `capacity` items (section 3).
pub fn Queue(comptime T: type, comptime capacity: u32) type {
    comptime {
        assert(capacity >= 2);
        assert(std.math.isPowerOfTwo(capacity));
        assert(capacity <= 1 << 30);
    }
    return struct {
        const Self = @This();
        pub const cap: u32 = capacity;
        const mask: u32 = capacity - 1;

        /// The next index the producer publishes. Written only by the producer.
        head: std.atomic.Value(u32) align(cache_line),
        /// The next index the consumer reads. Written only by the consumer.
        tail: std.atomic.Value(u32) align(cache_line),
        /// Blocks the producer found no room for. Written only by the producer.
        dropped: std.atomic.Value(u32) align(cache_line),
        slots: [capacity]T align(cache_line),

        /// Empties the queue in place; it is too large to return by value.
        pub fn init(self: *Self) void {
            self.init_at(0);
        }

        /// Empties the queue with both indices at `start`, so tests can cross the `u32` wrap.
        pub fn init_at(self: *Self, start: u32) void {
            self.head = .init(start);
            self.tail = .init(start);
            self.dropped = .init(0);
            assert(self.pending() == 0);
        }

        /// Producer: the slot the next `publish` makes visible, or null when the queue is full.
        pub fn slot(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            // Acquire pairs with `release`: the consumer is done with the slot before reuse.
            const tail = self.tail.load(.acquire);
            const used = head -% tail;
            assert(used <= capacity);
            if (used == capacity) return null;
            return &self.slots[head & mask];
        }

        /// Producer: makes the slot `slot` returned visible to the consumer.
        pub fn publish(self: *Self) void {
            const head = self.head.load(.monotonic);
            assert(head -% self.tail.load(.monotonic) < capacity);
            // Release for the slot's bytes; seq_cst for the wake (section 4).
            self.head.store(head +% 1, .seq_cst);
        }

        /// Producer: counts an item there was no room for.
        pub fn refuse(self: *Self) void {
            _ = self.dropped.fetchAdd(1, .monotonic);
        }

        /// Producer: copies `item` in. False, and counted, when the queue is full.
        pub fn push(self: *Self, item: *const T) bool {
            const target = self.slot() orelse {
                self.refuse();
                return false;
            };
            target.* = item.*;
            self.publish();
            return true;
        }

        /// Consumer: the oldest item, or null when the queue is empty. Valid until `release`.
        pub fn peek(self: *Self) ?*const T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.seq_cst);
            if (head == tail) return null;
            assert(head -% tail <= capacity);
            return &self.slots[tail & mask];
        }

        /// Consumer: gives the slot `peek` returned back to the producer.
        pub fn release(self: *Self) void {
            const tail = self.tail.load(.monotonic);
            assert(self.head.load(.acquire) != tail);
            self.tail.store(tail +% 1, .release);
        }

        /// Items published and not yet released, at most `capacity`.
        pub fn pending(self: *const Self) u32 {
            const used = self.head.load(.seq_cst) -% self.tail.load(.monotonic);
            assert(used <= capacity);
            return used;
        }

        /// Items refused so far.
        pub fn dropped_count(self: *const Self) u32 {
            return self.dropped.load(.monotonic);
        }
    };
}

/// The producer's way to wake a sleeping consumer (section 4): moved to `wake.zig` at step 54,
/// named here until the audio code goes.
pub const Wake = @import("wake.zig").Wake;

/// One sine of the test tone: frequency and the period of its gain triangle.
const Voice = struct {
    hz: u32,
    gain_period_s: u32,
};

/// The test tone's two voices (section 5).
pub const voices = [channels]Voice{
    .{ .hz = 220, .gain_period_s = 2 },
    .{ .hz = 330, .gain_period_s = 3 },
};
/// Gain at the bottom of the triangle, and its swing to the top.
pub const gain_floor: f32 = 0.05;
pub const gain_swing: f32 = 0.45;

/// A stereo test signal and a valid app `Audio` source (section 5).
pub const TestTone = struct {
    rate: u32,
    /// Frames rendered so far: the tone's clock.
    frame: u64,

    pub fn init(tone: *TestTone, rate: u32) void {
        assert(rate >= 8000);
        assert(rate <= 384_000);
        tone.* = .{ .rate = rate, .frame = 0 };
    }

    pub fn render(tone: *TestTone, block: *Block) void {
        assert(tone.rate != 0);
        var index: u32 = 0;
        while (index < block_frames) : (index += 1) {
            const n = tone.frame + index;
            block.samples[index * 2] = sample(n, tone.rate, voices[0]);
            block.samples[index * 2 + 1] = sample(n, tone.rate, voices[1]);
        }
        tone.frame += block_frames;
    }

    /// Voice `voice` at frame `n`: the gain times the sine of the integer phase.
    pub fn sample(n: u64, rate: u32, voice: Voice) f32 {
        assert(voice.hz < rate / 2);
        const cycle = (n * voice.hz) % rate;
        const phase = @as(f32, @floatFromInt(cycle)) / @as(f32, @floatFromInt(rate));
        const value = gain(n, rate, voice.gain_period_s) * @sin(std.math.tau * phase);
        assert(@abs(value) <= gain_floor + gain_swing);
        return value;
    }

    /// The triangle gain at frame `n`: `gain_floor` at the start of each period, the top at half.
    pub fn gain(n: u64, rate: u32, period_s: u32) f32 {
        const period = @as(u64, period_s) * rate;
        assert(period % 2 == 0);
        const along = n % period;
        const half = period / 2;
        const rising = if (along <= half) along else period - along;
        const tri = @as(f32, @floatFromInt(rising)) / @as(f32, @floatFromInt(half));
        assert(tri >= 0);
        assert(tri <= 1);
        return gain_floor + gain_swing * tri;
    }
};

/// Indices into `Levels`.
pub const left: u32 = 0;
pub const right: u32 = 1;
pub const mid: u32 = 2;

/// Peak and RMS of L, R, and mid over one block.
pub const Levels = struct {
    peak: [3]f32,
    rms: [3]f32,
};

/// The levels of one block (section 6).
pub fn levels(block: *const Block) Levels {
    var peak: [3]f32 = @splat(0);
    var sum: [3]f32 = @splat(0);
    var index: u32 = 0;
    while (index < block_frames) : (index += 1) {
        const pair = block.frame(index);
        const values = [3]f32{ pair[0], pair[1], (pair[0] + pair[1]) * 0.5 };
        for (values, 0..) |value, channel| {
            peak[channel] = @max(peak[channel], @abs(value));
            sum[channel] += value * value;
        }
    }
    var out: Levels = .{ .peak = peak, .rms = undefined };
    for (&out.rms, sum) |*rms, total| {
        rms.* = @sqrt(total / @as(f32, @floatFromInt(block_frames)));
        assert(rms.* >= 0);
    }
    return out;
}

/// The decibel span a meter shows, from full scale down.
pub const meter_range_db: f32 = 60;

/// A linear level in `[0, 1]` and above on the meter scale `[0, 1]` (section 6).
pub fn meter_of(level: f32) f32 {
    assert(level >= 0);
    if (level <= 0) return 0;
    const db = 20 * std.math.log10(level);
    const value = std.math.clamp((db + meter_range_db) / meter_range_db, 0, 1);
    assert(value >= 0);
    assert(value <= 1);
    return value;
}

/// Meter fall rate, and how long a peak hold stays, in blocks at `sample_rate`.
pub const fall_db_per_s: f32 = 24;
pub const hold_blocks: u32 = sample_rate / block_frames;
/// The fall per block on the meter scale.
pub const fall_per_block: f32 = fall_db_per_s * block_frames / sample_rate / meter_range_db;

/// A meter value that falls slowly, and a peak hold (section 6).
pub const Ballistics = struct {
    value: f32,
    hold: f32,
    /// Blocks since `hold` was last raised, at most `hold_blocks`.
    held: u32,

    pub const zero: Ballistics = .{ .value = 0, .hold = 0, .held = 0 };

    /// One block with meter value `meter`.
    pub fn step(self: *Ballistics, meter: f32) void {
        assert(meter >= 0);
        assert(meter <= 1);
        self.value = @max(meter, @max(0, self.value - fall_per_block));
        if (meter >= self.hold) {
            self.hold = meter;
            self.held = 0;
        } else if (self.held < hold_blocks) {
            self.held += 1;
        } else {
            self.hold = @max(self.value, self.hold - fall_per_block);
        }
        assert(self.hold >= self.value);
        assert(self.held <= hold_blocks);
    }
};

/// The last `2 * window` frames of both channels and a triggered window (section 6).
pub fn Scope(comptime window: u32) type {
    comptime {
        assert(window >= block_frames);
        assert(window % block_frames == 0);
    }
    return struct {
        const Self = @This();
        pub const frames: u32 = window;
        const span: u32 = 2 * window;

        history: [channels][span]f32,
        /// The frame the next block writes, `0 .. span`.
        head: u32,

        pub fn init(self: *Self) void {
            self.history = @splat(@splat(0));
            self.head = 0;
        }

        pub fn push(self: *Self, block: *const Block) void {
            assert(self.head < span);
            assert(self.head % block_frames == 0);
            var index: u32 = 0;
            while (index < block_frames) : (index += 1) {
                const pair = block.frame(index);
                self.history[0][self.head + index] = pair[0];
                self.history[1][self.head + index] = pair[1];
            }
            self.head = (self.head + block_frames) % span;
        }

        /// Fills `out` with the triggered window and returns true, or with the newest window
        /// and returns false when no crossing leaves a full window after it.
        pub fn window_of(self: *const Self, out: *[channels][window]f32) bool {
            // Ages count back from the newest frame: the newest window starts `window` back.
            var start: u32 = self.at(window);
            var triggered = false;
            var age: u32 = window;
            while (age < span - 1) : (age += 1) {
                const here = self.history[0][self.at(age)];
                const before = self.history[0][self.at(age + 1)];
                if (before < 0 and here >= 0) {
                    start = self.at(age);
                    triggered = true;
                    break;
                }
            }
            assert(age <= span - 1);
            self.copy_from(start, out);
            return triggered;
        }

        /// Fills `out` with the newest `window` frames, untriggered.
        pub fn newest(self: *const Self, out: *[channels][window]f32) void {
            self.copy_from(self.at(window), out);
        }

        fn copy_from(self: *const Self, start: u32, out: *[channels][window]f32) void {
            assert(start < span);
            for (0..channels) |channel| {
                var index: u32 = 0;
                while (index < window) : (index += 1) {
                    out[channel][index] = self.history[channel][(start + index) % span];
                }
            }
        }

        /// The history index of the frame `age` frames before the head, `1 ..= span`.
        fn at(self: *const Self, age: u32) u32 {
            assert(age >= 1);
            assert(age <= span);
            return (self.head + span - age) % span;
        }
    };
}

/// Frames a 60 Hz display frame spans at `sample_rate`.
pub const frames_per_display_frame: u32 = sample_rate / 60;

/// Blocks the bench feeds frame `n` of a run (section 7).
pub fn blocks_for_frame(n: u64) u32 {
    const per: u64 = frames_per_display_frame;
    const count = ((n + 1) * per) / block_frames - (n * per) / block_frames;
    assert(count <= post_blocks * 2);
    return @intCast(count);
}

comptime {
    assert(@sizeOf(Block) == 1024);
    assert(block_frames * post_blocks == 512);
    assert(sample_rate % 60 == 0);
    assert(sample_rate % block_frames == 0);
    assert(hold_blocks == 375);
    assert(queue_blocks % post_blocks == 0);
    assert(@alignOf(AudioQueue) == cache_line);
}

// Locks the queue's FIFO order and its full refusal: capacity items fit, the next is refused
// and counted, and a release frees exactly one slot.
test "the queue holds capacity items in order and refuses the next" {
    const Small = Queue(u32, 4);
    var queue: Small = undefined;
    queue.init();
    for (0..4) |value| try std.testing.expect(queue.push(&@as(u32, @intCast(value))));
    try std.testing.expectEqual(@as(u32, 4), queue.pending());
    try std.testing.expect(!queue.push(&@as(u32, 9)));
    try std.testing.expectEqual(@as(u32, 1), queue.dropped_count());
    try std.testing.expectEqual(@as(u32, 0), queue.peek().?.*);
    queue.release();
    try std.testing.expect(queue.push(&@as(u32, 4)));
    for (1..5) |expected| {
        try std.testing.expectEqual(@as(u32, @intCast(expected)), queue.peek().?.*);
        queue.release();
    }
    try std.testing.expect(queue.peek() == null);
    try std.testing.expectEqual(@as(u32, 0), queue.pending());
}

// Locks the index wrap: started 2 below `maxInt(u32)`, six items cross it and come out in
// order, with the count right at every step (`head -% tail`).
test "the queue crosses the u32 wrap" {
    const Small = Queue(u32, 4);
    var queue: Small = undefined;
    queue.init_at(std.math.maxInt(u32) - 1);
    var next: u32 = 0;
    var expected: u32 = 0;
    while (next < 6) : (next += 1) {
        try std.testing.expect(queue.push(&next));
        if (queue.pending() == 3) {
            try std.testing.expectEqual(expected, queue.peek().?.*);
            queue.release();
            expected += 1;
        }
    }
    try std.testing.expect(queue.head.raw < 8);
    while (queue.peek()) |value| : (expected += 1) {
        try std.testing.expectEqual(expected, value.*);
        queue.release();
    }
    try std.testing.expectEqual(@as(u32, 6), expected);
}

// Locks the tone (section 5): both sines start at 0; a quarter period of 220 Hz at 48 kHz is
// frame 54.5, so frame 0 of R and the gain triangle are the worked values: the gain is 0.05 at
// 0, 0.5 at half its period (1 s for L, 1.5 s for R), and 0.275 at a quarter.
test "the test tone's phase and gain triangle" {
    try std.testing.expectEqual(@as(f32, 0), TestTone.sample(0, sample_rate, voices[0]));
    try std.testing.expectEqual(@as(f32, 0.05), TestTone.gain(0, sample_rate, 2));
    try std.testing.expectEqual(@as(f32, 0.5), TestTone.gain(48_000, sample_rate, 2));
    try std.testing.expectEqual(@as(f32, 0.5), TestTone.gain(72_000, sample_rate, 3));
    try std.testing.expectApproxEqAbs(@as(f32, 0.275), TestTone.gain(24_000, sample_rate, 2), 1e-6);
    // 330 Hz: (n * 330) mod 48000 = 12000 is a quarter cycle at n = 400 / 11; at n = 1600 the
    // phase is 528000 mod 48000 = 0, a whole number of cycles.
    const whole = TestTone.sample(1600, sample_rate, voices[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0), whole, 1e-6);
    var tone: TestTone = undefined;
    tone.init(sample_rate);
    var block: Block = undefined;
    var peak: f32 = 0;
    for (0..1000) |_| {
        tone.render(&block);
        for (block.samples) |value| peak = @max(peak, @abs(value));
    }
    try std.testing.expectEqual(@as(u64, 128_000), tone.frame);
    try std.testing.expect(peak <= 0.5);
    try std.testing.expect(peak > 0.3);
}

// Locks the levels: a full-scale square gives peak 1 and RMS 1 on L, silence on R, so mid is
// 0.5 for both; a sine of amplitude A over whole cycles gives RMS A / sqrt(2).
test "levels of a square and a sine" {
    var block: Block = undefined;
    for (0..block_frames) |index| {
        block.samples[index * 2] = if (index % 2 == 0) 1 else -1;
        block.samples[index * 2 + 1] = 0;
    }
    const square = levels(&block);
    try std.testing.expectEqual(@as(f32, 1), square.peak[left]);
    try std.testing.expectEqual(@as(f32, 1), square.rms[left]);
    try std.testing.expectEqual(@as(f32, 0), square.peak[right]);
    try std.testing.expectEqual(@as(f32, 0.5), square.peak[mid]);
    try std.testing.expectEqual(@as(f32, 0.5), square.rms[mid]);
    // 4 cycles in 128 frames: a period of 32 frames.
    for (0..block_frames) |index| {
        const t = std.math.tau * @as(f32, @floatFromInt(index)) / 32.0;
        block.samples[index * 2] = 0.8 * @sin(t);
        block.samples[index * 2 + 1] = 0.8 * @sin(t);
    }
    const sine = levels(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8 / std.math.sqrt2), sine.rms[left], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), sine.peak[left], 1e-6);
}

// Locks the meter scale: full scale is 1, -6.02 dB (0.5) is 0.8997, -60 dB and below is 0.
test "the meter scale" {
    try std.testing.expectEqual(@as(f32, 1), meter_of(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.89966), meter_of(0.5), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), meter_of(0.001));
    try std.testing.expectEqual(@as(f32, 0), meter_of(0));
    try std.testing.expectEqual(@as(f32, 1), meter_of(2));
}

// Locks the ballistics in blocks: from 0.9, silence falls `fall_per_block` (1/937.5) a block;
// the hold stays at 0.9 for `hold_blocks` blocks, then falls the same way.
test "ballistics fall and hold by the block" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 937.5), fall_per_block, 1e-9);
    var meter = Ballistics.zero;
    meter.step(0.9);
    try std.testing.expectEqual(@as(f32, 0.9), meter.value);
    for (0..hold_blocks) |_| meter.step(0);
    try std.testing.expectEqual(@as(f32, 0.9), meter.hold);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9 - 375.0 / 937.5), meter.value, 1e-4);
    meter.step(0);
    try std.testing.expect(meter.hold < 0.9);
    for (0..2000) |_| meter.step(0);
    try std.testing.expectEqual(@as(f32, 0), meter.value);
    try std.testing.expectEqual(@as(f32, 0), meter.hold);
}

// Locks the trigger: a 32-frame sine whose rising crossings are at multiples of 32 starts the
// window on one; DC never crosses, so the window is the newest one, untriggered.
test "the scope triggers on a rising crossing and free-runs on DC" {
    const Small = Scope(256);
    var scope: Small = undefined;
    scope.init();
    var block: Block = undefined;
    var frame_index: u32 = 0;
    for (0..4) |_| {
        for (0..block_frames) |index| {
            // Offset by 5 frames so the crossing is not at a block edge.
            const t = std.math.tau * @as(f32, @floatFromInt(frame_index + 5)) / 32.0;
            block.samples[index * 2] = @sin(t);
            block.samples[index * 2 + 1] = 0.25;
            frame_index += 1;
        }
        scope.push(&block);
    }
    var out: [channels][256]f32 = undefined;
    try std.testing.expect(scope.window_of(&out));
    try std.testing.expect(out[0][0] >= 0);
    try std.testing.expect(out[0][0] < 0.2);
    try std.testing.expect(out[0][1] > out[0][0]);
    try std.testing.expectEqual(@as(f32, 0.25), out[1][100]);
    for (&block.samples) |*value| value.* = 0.5;
    for (0..4) |_| scope.push(&block);
    try std.testing.expect(!scope.window_of(&out));
    try std.testing.expectEqual(@as(f32, 0.5), out[0][255]);
}

// Locks the bench schedule (section 7): 6, 6, 6, 7 blocks, 25 blocks of 128 per 4 frames.
test "the bench schedule" {
    try std.testing.expectEqual(@as(u32, 6), blocks_for_frame(0));
    try std.testing.expectEqual(@as(u32, 6), blocks_for_frame(1));
    try std.testing.expectEqual(@as(u32, 6), blocks_for_frame(2));
    try std.testing.expectEqual(@as(u32, 7), blocks_for_frame(3));
    var total: u64 = 0;
    for (0..600) |n| total += blocks_for_frame(n);
    try std.testing.expectEqual(@as(u64, 600 * 800 / 128), total);
}

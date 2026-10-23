//! The transport and the automation lanes: one ring of samples per binding and a playhead.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Semantics
//! There is no audio engine, so the transport moves a playhead over the lanes and records
//! knob values into them; lanes never write into the text.
//! ```text
//! paused             the host timer is stopped (`cx.set_timer(false)`): nothing wakes
//! playing            each timer tick (`timer_period_ms`, about 30 Hz) advances `head` by one
//! playing+recording  each tick first writes every binding's current value at `head`
//! back               `head` returns to 0
//! ```
//!
//! ## 2. Why an In-Place Ring
//! A scrolling lane would rewrite all of its points on every tick. The ring keeps sample `i`
//! at x position `i` and the playhead sweeps over it, so a tick that records one changed value
//! changes one sample, and the app anchors each lane's path at its rect (`path.polyline_at`),
//! so one sample is one point in the upload. A tick that records nothing changes no sample;
//! only the playhead moves.
//!
//! ## 3. Lane Identity
//! Lane `i` belongs to binding slot `i`. It remembers the key of the binding it was filled for
//! (a hash of the binding's label); when a slot's key changes (a new binding, or one renamed
//! or moved into the slot) the lane is refilled flat with the binding's value.
//!
//! ## 4. TigerStyle Invariants
//! - Fixed storage: `lane_cap` rings of `sample_count` samples. Every loop is bounded by them.
//! - `head < sample_count` always.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");

/// Samples per lane: the most `draw.path.plot` maps, so one lane is one path.
pub const sample_count: u32 = patchwork.draw.path.plot_samples_max;

pub const Transport = struct {
    playing: bool,
    recording: bool,
    head: u32,

    pub const stopped: Transport = .{ .playing = false, .recording = false, .head = 0 };

    /// Advances the playhead one sample, wrapping at the end of the ring.
    pub fn step(self: *Transport) void {
        assert(self.playing);
        assert(self.head < sample_count);
        self.head = (self.head + 1) % sample_count;
        assert(self.head < sample_count);
    }
};

/// `lane_cap` rings of `sample_count` values. See the module guide.
pub fn Lanes(comptime lane_cap: u32) type {
    return struct {
        const Self = @This();

        values: [lane_cap][sample_count]f32,
        /// The key each lane was filled for; 0 for a lane never filled.
        keys: [lane_cap]u64,

        pub fn init(self: *Self) void {
            @memset(&self.keys, 0);
            assert(self.keys[0] == 0);
        }

        /// Fills lane `index` flat with `value` when its key is not `key` (section 3).
        pub fn bind(self: *Self, index: u32, key: u64, value: f32) void {
            assert(index < lane_cap);
            assert(key != 0);
            if (self.keys[index] == key) return;
            self.keys[index] = key;
            @memset(&self.values[index], value);
            assert(self.values[index][sample_count - 1] == value);
        }

        /// Writes `value` at `head` of lane `index`; returns true when the sample changed.
        pub fn write(self: *Self, index: u32, head: u32, value: f32) bool {
            assert(index < lane_cap);
            assert(head < sample_count);
            assert(self.keys[index] != 0);
            if (self.values[index][head] == value) return false;
            self.values[index][head] = value;
            return true;
        }

        pub fn samples(self: *const Self, index: u32) *const [sample_count]f32 {
            assert(index < lane_cap);
            return &self.values[index];
        }
    };
}

/// The key of a lane's binding: the FNV-1a hash of its label, never 0.
pub fn key_of(label: []const u8) u64 {
    assert(label.len > 0);
    const hash = std.hash.Fnv1a_64.hash(label);
    return hash | 1;
}

comptime {
    assert(sample_count == 256);
}

const testing = std.testing;

// Locks the ring: the head wraps from 255 to 0, a bound lane is flat, a second bind with the
// same key keeps the samples, a new key refills them, and a write reports a change once.
test "the ring wraps and a lane refills only for a new key" {
    var transport: Transport = .stopped;
    transport.playing = true;
    transport.head = sample_count - 1;
    transport.step();
    try testing.expectEqual(@as(u32, 0), transport.head);
    const static = struct {
        var lanes: Lanes(2) = undefined;
    };
    const lanes = &static.lanes;
    lanes.init();
    lanes.bind(1, key_of("gain"), 1.5);
    try testing.expectEqual(@as(f32, 1.5), lanes.samples(1)[200]);
    try testing.expect(lanes.write(1, 7, 2.0));
    try testing.expect(!lanes.write(1, 7, 2.0));
    lanes.bind(1, key_of("gain"), 0.25);
    try testing.expectEqual(@as(f32, 2.0), lanes.samples(1)[7]);
    lanes.bind(1, key_of("slope"), 0.25);
    try testing.expectEqual(@as(f32, 0.25), lanes.samples(1)[7]);
    try testing.expect(key_of("gain") != key_of("slope"));
}

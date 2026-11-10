//! A wake from any thread: a producer notifies, and the UI's poll loop, asleep, wakes once.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Role
//! A UI that sleeps while nothing is live must still wake when another thread has something for
//! it: an audio thread's blocks, a peer library's monitor, a worker's results. `Wake` is the one
//! piece of that a library must own, since only the host's poll loop can sleep on a descriptor;
//! the data itself travels in whatever queue the producer and the app share (an app can write a
//! queue, so the library holds none for it). It moved here from `realtime.zig` at step 54, so any
//! producer can use it (`app.zig`, section 4e); the rest of that file went at step 56.
//!
//! ## 2. The Lost-Wakeup Argument
//! `Wake` is an `armed` flag and a descriptor: an `eventfd` the native window host attaches, or
//! -1 where there is nothing to write (the browser, headless runs, tests). The producer calls
//! `notify` after each item it makes visible: if `armed` was set, it clears it and writes the
//! descriptor once. The consumer calls `arm(queue)` just before it sleeps: it sets `armed`, then
//! asks `queue.pending()`; if an item is waiting it disarms and skips the sleep. The producer's
//! publish precedes its swap of `armed`, and the consumer's store of `armed` precedes its read of
//! the count; with all four `seq_cst`, they sit in one total order and at least one side sees the
//! other: either the producer sees `armed` and writes, or the consumer sees the item and does not
//! sleep. So `queue` may be any type with `pending() u32` whose loads are `seq_cst` and whose
//! producer publishes `seq_cst` (Thrum's monitor does, from its step 23). A UI that never arms,
//! because it is presenting and its frame callback will wake it, costs the producer one atomic
//! swap per notify.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: two atomics and a descriptor.
//! - `notify` writes the descriptor at most once per `arm`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The producer's way to wake a sleeping consumer (section 2).
pub const Wake = struct {
    /// Set by the consumer just before it sleeps; cleared by the notify that wakes it.
    armed: std.atomic.Value(bool),
    /// An `eventfd` natively; -1 where there is nothing to write (the browser, tests).
    fd: i32,
    /// Writes made so far, for tests and the exit line.
    notified: std.atomic.Value(u32),

    pub fn init(fd: i32) Wake {
        const wake: Wake = .{ .armed = .init(false), .fd = fd, .notified = .init(0) };
        assert(!wake.armed.raw);
        return wake;
    }

    /// Host: gives the wake the poll loop's descriptor, before any producer starts.
    pub fn attach(self: *Wake, fd: i32) void {
        assert(fd >= 0);
        assert(!self.armed.load(.monotonic));
        self.fd = fd;
    }

    /// Producer: wakes the consumer once if it is armed.
    pub fn notify(self: *Wake) void {
        if (!self.armed.swap(false, .seq_cst)) return;
        _ = self.notified.fetchAdd(1, .monotonic);
        if (self.fd < 0) return;
        if (builtin.os.tag != .linux) return;
        const one: u64 = 1;
        // A full counter (2^64 - 2 unread writes) cannot happen: every wake reads it.
        _ = std.os.linux.write(self.fd, std.mem.asBytes(&one), 8);
    }

    /// Consumer: arms before a sleep. Returns false, disarmed, when `queue` already holds an
    /// item, so the caller must drain instead of sleeping.
    pub fn arm(self: *Wake, queue: anytype) bool {
        self.armed.store(true, .seq_cst);
        if (queue.pending() == 0) return true;
        self.armed.store(false, .seq_cst);
        return false;
    }

    /// Consumer: clears the flag after a wake, or when it will not sleep on the wake.
    pub fn disarm(self: *Wake) void {
        self.armed.store(false, .seq_cst);
    }
};

/// A count of items for tests: what `arm` reads.
const Count = struct {
    items: std.atomic.Value(u32),

    fn pending(count: *const Count) u32 {
        return count.items.load(.seq_cst);
    }
};

// Locks section 2 on one thread: unarmed, notify writes nothing; armed, the first notify counts
// and the second does not; arming over a pending item refuses the sleep and stays disarmed.
test "the wake notifies once per arm and refuses a sleep over pending data" {
    var count: Count = .{ .items = .init(0) };
    var wake = Wake.init(-1);
    wake.notify();
    try std.testing.expectEqual(@as(u32, 0), wake.notified.raw);
    try std.testing.expect(wake.arm(&count));
    wake.notify();
    wake.notify();
    try std.testing.expectEqual(@as(u32, 1), wake.notified.raw);
    count.items.store(1, .seq_cst);
    try std.testing.expect(!wake.arm(&count));
    try std.testing.expect(!wake.armed.raw);
    wake.notify();
    try std.testing.expectEqual(@as(u32, 1), wake.notified.raw);
}

// Locks `attach` and the write: an attached `eventfd` armed and notified reads back 1.
test "an attached wake writes its descriptor once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const created = std.os.linux.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(created));
    const fd: i32 = @intCast(created);
    defer _ = std.os.linux.close(fd);
    var count: Count = .{ .items = .init(0) };
    var wake = Wake.init(-1);
    wake.attach(fd);
    try std.testing.expect(wake.arm(&count));
    wake.notify();
    wake.notify();
    var value: u64 = 0;
    const read = std.os.linux.read(fd, std.mem.asBytes(&value), 8);
    try std.testing.expectEqual(@as(usize, 8), read);
    try std.testing.expectEqual(@as(u64, 1), value);
}

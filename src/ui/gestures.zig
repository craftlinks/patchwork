//! Gestures: a per-target recognizer for tap, drag, long-press, pinch, two-finger tap, and
//! two-finger pan, which a widget or an app opts into.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Is
//! A `Recognizer` is a small value (no allocation) that watches the contacts on one target and
//! says what they mean. It knows nothing of widgets or hosts: `feed` takes a `Sample` and `tick`
//! a time step, both pure, and `handle` reads them from the context (`cx.touch()` for a finger,
//! `cx.hit` for the mouse's left button). A widget that wants gestures holds a `Recognizer` beside
//! its `hit` call; a widget of several ids holds one per id. No library widget uses it yet.
//!
//! ## 2. The Conflict Table
//! ```text
//! One contact, moved past slop_px from its origin               Drag wins; Tap, Long_Press fail
//! One contact, within slop for long_press_ms                    Long_Press wins, Tap fails; later
//!                                                               movement also starts a Drag
//! One contact, up within slop and tap_max_ms, no Long_Press     Tap
//! Two contacts on one target, the second within chord_ms of the first
//!                                                               the two-finger set; the
//!                                                               one-finger set fails
//! Two contacts within slop, both up within tap_max_ms of the first down
//!                                                               Two_Finger_Tap; Pinch, Pan fail
//! Two contacts, centroid moves past slop, distance ratio inside [1 / pinch_ratio, pinch_ratio]
//!                                                               Pan; Two_Finger_Tap fails
//! Distance ratio leaves that range                              Pinch (Pan may run with it)
//! Cancel of any participating contact                           that target's gesture is
//!                                                               `cancelled`; nothing else fires
//! ```
//! A late second finger (after `chord_ms`), a third, and a recognizer whose mask has no two-finger
//! kind leave the one-finger set alone: the extra contact is counted and ignored.
//!
//! ## 3. States
//! ```text
//! idle -> one -> drag                  a lift ends the drag
//!          |  \-> (tap, long_press)    a lift fires the tap
//!          \-> two -> two_active       the first lift ends the pinch or pan
//! any gesture that ended or failed -> blocked, until every contact on the target is up
//! ```
//! `live` counts every contact down on the target, tracked or not, so `blocked` returns to `idle`
//! exactly when the last finger lifts.
//!
//! ## 4. Time
//! Tap and chord times use the samples' `time_ms` with wrapping subtraction, as `count_click` does.
//! A long-press has no event to arrive on, so `handle` counts `.frame` deltas through `tick`,
//! calls `cx.redraw()` on a press when the mask wants it (so frames start), and calls
//! `cx.keep_animating()` only while a long-press is pending. The idle invariant holds: at most
//! `long_press_ms` of frames, then the app sleeps.
//!
//! ## 5. The Mouse
//! With no `cx.touch()`, `handle` feeds the left button from `cx.hit`: the one-finger set. A right
//! click stays `Hit.secondary`, and the two-finger kinds never run.
//!
//! ## 6. TigerStyle Invariants
//! - Two tracks, no allocation, no recursion; every function is straight-line or a bounded scan
//!   of the two tracks.
//! - A gesture is one return value: a pinch and a pan on one move are one `two_finger` with both
//!   flags.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const areas = @import("areas.zig");

pub const Id = areas.Id;

/// Which kinds a recognizer reports.
pub const Mask = packed struct(u8) {
    tap: bool = false,
    drag: bool = false,
    long_press: bool = false,
    pinch: bool = false,
    two_finger_tap: bool = false,
    two_finger_pan: bool = false,
    unused: u2 = 0,

    /// Every kind.
    pub const all: Mask = .{
        .tap = true,
        .drag = true,
        .long_press = true,
        .pinch = true,
        .two_finger_tap = true,
        .two_finger_pan = true,
    };

    /// True when a second contact could mean anything.
    fn two_fingers(self: Mask) bool {
        return self.pinch or self.two_finger_tap or self.two_finger_pan;
    }
};

/// The limits that tell the gestures apart. A screen may widen them.
pub const Thresholds = struct {
    /// Travel from the origin that is still a stay, in logical px: a finger lands loosely.
    slop_px: f32 = 12,
    long_press_ms: u32 = 400,
    /// The second finger of a two-finger gesture lands within this of the first.
    chord_ms: u32 = 80,
    /// A tap lifts within this of its down.
    tap_max_ms: u32 = 300,
    /// The distance ratio outside `[1 / pinch_ratio, pinch_ratio]` is a pinch.
    pinch_ratio: f32 = 1.08,
};

pub const Phase = enum { began, changed, ended, cancelled };

/// Where a tap or long-press happened.
pub const Spot = struct {
    x: f32,
    y: f32,
};

/// A one-finger drag: the point and its travel from where the contact landed.
pub const Drag = struct {
    phase: Phase,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
};

/// A pinch, a pan, or both: the centroid, its travel, and the distance ratio to the start.
pub const TwoFinger = struct {
    phase: Phase,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    scale: f32,
    pinching: bool,
    panning: bool,
};

/// What a sample or a tick meant.
pub const Gesture = union(enum) {
    none,
    tap: Spot,
    long_press: Spot,
    drag: Drag,
    two_finger_tap: Spot,
    two_finger: TwoFinger,
};

pub const SamplePhase = enum { down, move, up, cancel };

/// One contact's fact on the target. `up` and `cancel` carry the last position.
pub const Sample = struct {
    id: u32,
    phase: SamplePhase,
    x: f32,
    y: f32,
    time_ms: u32,
};

const State = enum { idle, one, drag, two, two_active, blocked };

const Track = struct {
    id: u32,
    origin: [2]f32,
    at: [2]f32,
    down_ms: u32,
    up: bool,
};

const empty_track: Track = .{ .id = 0, .origin = .{ 0, 0 }, .at = .{ 0, 0 }, .down_ms = 0, .up = false };

fn distance(a: [2]f32, b: [2]f32) f32 {
    return @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
}

pub const Recognizer = struct {
    mask: Mask,
    limits: Thresholds,
    state: State,
    tracks: [2]Track,
    count: u32,
    /// Contacts down on the target, tracked or not.
    live: u32,
    /// Frame time since the first contact went down, for the long-press.
    held_ms: f32,
    long_fired: bool,
    /// The one contact moved past the slop, so a tap and a long-press are off.
    slop_exceeded: bool,
    /// The two-finger start: the distance and the centroid when the second finger landed.
    start_distance: f32,
    start_centre: [2]f32,
    pinching: bool,
    panning: bool,
    /// Either finger of a two-finger gesture strayed: no two-finger tap.
    strayed: bool,

    pub fn init(mask: Mask, limits: Thresholds) Recognizer {
        assert(limits.slop_px >= 0);
        assert(limits.pinch_ratio > 1);
        assert(mask.unused == 0);
        return .{
            .mask = mask,
            .limits = limits,
            .state = .idle,
            .tracks = .{ empty_track, empty_track },
            .count = 0,
            .live = 0,
            .held_ms = 0,
            .long_fired = false,
            .slop_exceeded = false,
            .start_distance = 0,
            .start_centre = .{ 0, 0 },
            .pinching = false,
            .panning = false,
            .strayed = false,
        };
    }

    /// True while a long-press is still possible: frames must keep coming.
    pub fn pending(self: *const Recognizer) bool {
        return self.state == .one and self.mask.long_press and !self.long_fired and
            !self.slop_exceeded;
    }

    /// True while a drag, pinch, or pan is in flight.
    pub fn active(self: *const Recognizer) bool {
        return self.state == .drag or self.state == .two_active;
    }

    /// Advances the long-press by `dt_ms` of frame time. Pure.
    pub fn tick(self: *Recognizer, dt_ms: f32) Gesture {
        assert(dt_ms >= 0);
        if (!self.pending()) return .none;
        self.held_ms += dt_ms;
        if (self.held_ms < @as(f32, @floatFromInt(self.limits.long_press_ms))) return .none;
        self.long_fired = true;
        const at = self.tracks[0].at;
        return .{ .long_press = .{ .x = at[0], .y = at[1] } };
    }

    /// One contact's fact. Pure: the recognizer's state is the only thing it changes.
    pub fn feed(self: *Recognizer, sample: Sample) Gesture {
        assert(self.count <= 2);
        return switch (sample.phase) {
            .down => self.land(sample),
            .move => self.travel(sample),
            .up => self.lift(sample, false),
            .cancel => self.lift(sample, true),
        };
    }

    fn track_of(self: *const Recognizer, id: u32) ?u32 {
        for (self.tracks[0..self.count], 0..) |track, index| {
            if (track.id == id and !track.up) return @intCast(index);
        }
        return null;
    }

    fn land(self: *Recognizer, sample: Sample) Gesture {
        self.live += 1;
        const track: Track = .{
            .id = sample.id,
            .origin = .{ sample.x, sample.y },
            .at = .{ sample.x, sample.y },
            .down_ms = sample.time_ms,
            .up = false,
        };
        switch (self.state) {
            .idle => {
                self.reset_gesture();
                self.tracks[0] = track;
                self.count = 1;
                self.state = .one;
            },
            .one => {
                const early = (sample.time_ms -% self.tracks[0].down_ms) <= self.limits.chord_ms;
                if (self.count == 1 and self.mask.two_fingers() and early) {
                    self.tracks[1] = track;
                    self.count = 2;
                    self.state = .two;
                    self.start_distance = distance(self.tracks[0].at, track.at);
                    self.start_centre = centre_of(self.tracks[0].at, track.at);
                }
            },
            .drag, .two, .two_active, .blocked => {},
        }
        return .none;
    }

    fn travel(self: *Recognizer, sample: Sample) Gesture {
        const index = self.track_of(sample.id) orelse return .none;
        const track = &self.tracks[index];
        track.at = .{ sample.x, sample.y };
        switch (self.state) {
            .one => {
                if (distance(track.at, track.origin) <= self.limits.slop_px) return .none;
                self.slop_exceeded = true;
                if (!self.mask.drag) return .none;
                self.state = .drag;
                return .{ .drag = self.drag_of(.began) };
            },
            .drag => return .{ .drag = self.drag_of(.changed) },
            .two, .two_active => return self.two_travel(),
            .idle, .blocked => return .none,
        }
    }

    fn drag_of(self: *const Recognizer, phase: Phase) Drag {
        const track = self.tracks[0];
        return .{
            .phase = phase,
            .x = track.at[0],
            .y = track.at[1],
            .dx = track.at[0] - track.origin[0],
            .dy = track.at[1] - track.origin[1],
        };
    }

    /// The two-finger gesture at the contacts' current points.
    fn two_of(self: *const Recognizer, phase: Phase) TwoFinger {
        const centre = centre_of(self.tracks[0].at, self.tracks[1].at);
        return .{
            .phase = phase,
            .x = centre[0],
            .y = centre[1],
            .dx = centre[0] - self.start_centre[0],
            .dy = centre[1] - self.start_centre[1],
            .scale = self.ratio(),
            .pinching = self.pinching,
            .panning = self.panning,
        };
    }

    fn ratio(self: *const Recognizer) f32 {
        if (!(self.start_distance > 1.0e-3)) return 1;
        return distance(self.tracks[0].at, self.tracks[1].at) / self.start_distance;
    }

    fn two_travel(self: *Recognizer) Gesture {
        assert(self.count == 2);
        const scale = self.ratio();
        const centre = centre_of(self.tracks[0].at, self.tracks[1].at);
        const slop = self.limits.slop_px;
        const moved = distance(centre, self.start_centre) > slop;
        const range = self.limits.pinch_ratio;
        const stretched = scale > range or scale < 1 / range;
        if (moved or stretched) self.strayed = true;
        for (self.tracks[0..2]) |track| {
            if (distance(track.at, track.origin) > slop) self.strayed = true;
        }
        if (stretched and self.mask.pinch) self.pinching = true;
        if (moved and self.mask.two_finger_pan) self.panning = true;
        if (self.state == .two_active) return .{ .two_finger = self.two_of(.changed) };
        if (!self.pinching and !self.panning) return .none;
        self.state = .two_active;
        return .{ .two_finger = self.two_of(.began) };
    }

    fn lift(self: *Recognizer, sample: Sample, cancelled: bool) Gesture {
        const index = self.track_of(sample.id) orelse {
            // A contact the recognizer ignored (a late second, a third), or one already lifted.
            if (self.live > 0 and self.state != .idle) self.live -= 1;
            if (self.live == 0) self.state = .idle;
            return .none;
        };
        assert(self.live >= 1);
        self.live -= 1;
        self.tracks[index].at = .{ sample.x, sample.y };
        const result: Gesture = switch (self.state) {
            .one => self.lift_one(sample, cancelled),
            .drag => blk: {
                const phase: Phase = if (cancelled) .cancelled else .ended;
                const dragged = self.drag_of(phase);
                self.block();
                break :blk .{ .drag = dragged };
            },
            .two => self.lift_two(index, sample, cancelled),
            .two_active => blk: {
                const phase: Phase = if (cancelled) .cancelled else .ended;
                const done = self.two_of(phase);
                self.block();
                break :blk .{ .two_finger = done };
            },
            .idle, .blocked => .none,
        };
        if (self.live == 0) {
            self.state = .idle;
            self.count = 0;
        }
        return result;
    }

    fn lift_one(self: *Recognizer, sample: Sample, cancelled: bool) Gesture {
        const tapped = !cancelled and self.mask.tap and !self.long_fired and !self.slop_exceeded and
            (sample.time_ms -% self.tracks[0].down_ms) <= self.limits.tap_max_ms;
        self.block();
        if (!tapped) return .none;
        return .{ .tap = .{ .x = sample.x, .y = sample.y } };
    }

    fn lift_two(self: *Recognizer, index: u32, sample: Sample, cancelled: bool) Gesture {
        if (cancelled) {
            self.block();
            return .none;
        }
        self.tracks[index].up = true;
        if (!self.tracks[0].up or !self.tracks[1].up) return .none;
        const first = self.tracks[0].down_ms;
        const soon = (sample.time_ms -% first) <= self.limits.tap_max_ms;
        const tapped = self.mask.two_finger_tap and !self.strayed and soon;
        const centre = centre_of(self.tracks[0].at, self.tracks[1].at);
        self.block();
        if (!tapped) return .none;
        return .{ .two_finger_tap = .{ .x = centre[0], .y = centre[1] } };
    }

    /// The gesture is over or failed: nothing more until every contact is up.
    fn block(self: *Recognizer) void {
        self.state = .blocked;
    }

    fn reset_gesture(self: *Recognizer) void {
        self.held_ms = 0;
        self.long_fired = false;
        self.slop_exceeded = false;
        self.pinching = false;
        self.panning = false;
        self.strayed = false;
        self.count = 0;
    }

    /// Feeds the recognizer what the context says about `id` for `event`, and the frame deltas to
    /// its clock (module guide, sections 4 and 5). Event phase.
    pub fn handle(self: *Recognizer, cx: anytype, id: Id, event: input.Event) Gesture {
        assert(id != .none);
        if (event == .frame) {
            const result = self.tick(event.frame);
            if (self.pending()) cx.keep_animating();
            return result;
        }
        if (cx.touch()) |finger| {
            if (finger.target != id) return .none;
            const phase: SamplePhase = switch (event) {
                .pointer_down => .down,
                .pointer_move => .move,
                .pointer_up => .up,
                // The leave after a lift is not a second lift: only a cancel is a leave.
                .pointer_leave => if (finger.phase == .cancel) .cancel else return .none,
                else => return .none,
            };
            const result = self.feed(.{
                .id = finger.id,
                .phase = phase,
                .x = finger.x,
                .y = finger.y,
                .time_ms = finger.time_ms,
            });
            if (phase == .down and self.mask.long_press) cx.redraw();
            return result;
        }
        return self.handle_mouse(cx, id, event);
    }

    fn handle_mouse(self: *Recognizer, cx: anytype, id: Id, event: input.Event) Gesture {
        const mouse_id: u32 = std.math.maxInt(u32);
        switch (cx.hit(id, event)) {
            .down => |press| {
                const result = self.feed(.{
                    .id = mouse_id,
                    .phase = .down,
                    .x = press.x,
                    .y = press.y,
                    .time_ms = event.pointer_down.time_ms,
                });
                if (self.mask.long_press) cx.redraw();
                return result;
            },
            .drag => |press| return self.feed(.{
                .id = mouse_id,
                .phase = .move,
                .x = press.x,
                .y = press.y,
                .time_ms = 0,
            }),
            .up => |up| {
                const time_ms: u32 = if (event == .pointer_up) event.pointer_up.time_ms else 0;
                return self.feed(.{
                    .id = mouse_id,
                    .phase = if (event == .pointer_leave) .cancel else .up,
                    .x = up.x,
                    .y = up.y,
                    .time_ms = time_ms,
                });
            },
            .none, .hover_in, .hover_out, .wheel, .secondary => return .none,
        }
    }
};

fn centre_of(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

comptime {
    assert(@sizeOf(Mask) == 1);
    assert(@sizeOf(Thresholds) == 20);
}

const testing = std.testing;

fn smp(id: u32, phase: SamplePhase, x: f32, y: f32, time_ms: u32) Sample {
    return .{ .id = id, .phase = phase, .x = x, .y = y, .time_ms = time_ms };
}

fn recognizer() Recognizer {
    return .init(.all, .{});
}

// Locks tap against drag (section 2): a contact that lifts within 12 px and 300 ms is a tap at
// the lift; at exactly 12 px and 300 ms it still is; 13 px is a drag that began on the move, kept
// its travel, and ended at the lift, with no tap; 301 ms is neither.
test "a tap is a short stay and a drag is a move past the slop" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 100, 100, 1000));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .move, 106, 109, 1050)));
    const tap = rec.feed(smp(1, .up, 106, 109, 1100));
    try testing.expectEqual(Spot{ .x = 106, .y = 109 }, tap.tap);
    try testing.expectEqual(State.idle, rec.state);
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    _ = rec.feed(smp(1, .move, 12, 0, 10));
    try testing.expectEqual(Spot{ .x = 12, .y = 0 }, rec.feed(smp(1, .up, 12, 0, 300)).tap);
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .up, 0, 0, 301)));
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    const began = rec.feed(smp(1, .move, 13, 0, 10)).drag;
    try testing.expectEqual(Phase.began, began.phase);
    try testing.expectEqual(@as(f32, 13), began.dx);
    const moved = rec.feed(smp(1, .move, 40, 5, 20)).drag;
    try testing.expectEqual(Phase.changed, moved.phase);
    try testing.expectEqual(@as(f32, 40), moved.dx);
    try testing.expectEqual(@as(f32, 5), moved.dy);
    const ended = rec.feed(smp(1, .up, 41, 5, 30)).drag;
    try testing.expectEqual(Phase.ended, ended.phase);
    try testing.expectEqual(State.idle, rec.state);
}

// Locks the long-press (section 2): frames add up to 400 ms and fire it once at the contact's
// point, 399 ms do not; the lift after it is no tap; moving past the slop afterwards starts a
// drag; and moving past the slop before it stops the long-press for good.
test "a long press fires once, then a move still drags" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 50, 60, 0));
    try testing.expect(rec.pending());
    try testing.expectEqual(Gesture.none, rec.tick(399));
    const pressed = rec.tick(1).long_press;
    try testing.expectEqual(Spot{ .x = 50, .y = 60 }, pressed);
    try testing.expect(!rec.pending());
    try testing.expectEqual(Gesture.none, rec.tick(100));
    try testing.expectEqual(Phase.began, rec.feed(smp(1, .move, 80, 60, 450)).drag.phase);
    _ = rec.feed(smp(1, .up, 80, 60, 500));
    _ = rec.feed(smp(1, .down, 50, 60, 1000));
    _ = rec.feed(smp(1, .move, 70, 60, 1100));
    try testing.expect(!rec.pending());
    try testing.expectEqual(Gesture.none, rec.tick(1000));
    _ = rec.feed(smp(1, .up, 70, 60, 2200));
    _ = rec.feed(smp(1, .down, 50, 60, 3000));
    try testing.expectEqual(Spot{ .x = 50, .y = 60 }, rec.feed(smp(1, .up, 50, 60, 3200)).tap);
}

// Locks the two-finger set (section 2): fingers landing 80 ms apart are a chord, 81 ms apart are
// not (the second is ignored and the first can still tap); a pinch begins when the distance
// ratio passes 1.08, reports the scale at each move and ends at the first lift; a ratio of
// exactly 1.08 is not yet a pinch.
test "a chord pinches when the distance ratio leaves its range" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 100, 80));
    try testing.expectEqual(State.two, rec.state);
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .move, 208, 100, 90)));
    const began = rec.feed(smp(2, .move, 220, 100, 100)).two_finger;
    try testing.expectEqual(Phase.began, began.phase);
    try testing.expect(began.pinching);
    try testing.expectApproxEqAbs(@as(f32, 1.2), began.scale, 1.0e-5);
    const moved = rec.feed(smp(2, .move, 300, 100, 110)).two_finger;
    try testing.expectEqual(Phase.changed, moved.phase);
    try testing.expectApproxEqAbs(@as(f32, 2), moved.scale, 1.0e-5);
    try testing.expectApproxEqAbs(@as(f32, 200), moved.x, 1.0e-4);
    const ended = rec.feed(smp(1, .up, 100, 100, 200)).two_finger;
    try testing.expectEqual(Phase.ended, ended.phase);
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .up, 300, 100, 210)));
    try testing.expectEqual(State.idle, rec.state);
    _ = rec.feed(smp(1, .down, 100, 100, 1000));
    _ = rec.feed(smp(2, .down, 200, 100, 1081));
    try testing.expectEqual(State.one, rec.state);
    try testing.expectEqual(Spot{ .x = 100, .y = 100 }, rec.feed(smp(1, .up, 100, 100, 1100)).tap);
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .up, 200, 100, 1110)));
    try testing.expectEqual(State.idle, rec.state);
}

// Locks the pan and its overlap with a pinch (section 2): the centroid moving past 12 px with the
// distance steady is a pan (not a pinch); the ratio then leaving its range adds pinching to the
// same gesture, so one move is one `two_finger` with both flags.
test "a pan runs alone and a pinch joins it as one gesture" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 100, 10));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .move, 100, 120, 20)));
    const began = rec.feed(smp(2, .move, 200, 120, 30)).two_finger;
    try testing.expect(began.panning);
    try testing.expect(!began.pinching);
    try testing.expectApproxEqAbs(@as(f32, 20), began.dy, 1.0e-4);
    const both = rec.feed(smp(2, .move, 300, 120, 50)).two_finger;
    try testing.expect(both.panning and both.pinching);
    try testing.expectEqual(Phase.changed, both.phase);
}

// Locks the two-finger tap (section 2): both contacts up within 300 ms of the first down, both
// within 12 px, is one tap at the centroid; one that strays past the slop is not, and neither is a
// chord held longer than 300 ms.
test "two fingers that stay and lift are a two-finger tap" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 120, 20));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .up, 101, 100, 120)));
    const tapped = rec.feed(smp(2, .up, 200, 120, 130)).two_finger_tap;
    try testing.expectEqual(Spot{ .x = 150.5, .y = 110 }, tapped);
    try testing.expectEqual(State.idle, rec.state);
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 100, 10));
    _ = rec.feed(smp(2, .move, 205, 113, 20));
    _ = rec.feed(smp(2, .move, 200, 100, 30));
    _ = rec.feed(smp(1, .up, 100, 100, 60));
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .up, 200, 100, 70)));
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 100, 10));
    _ = rec.feed(smp(1, .up, 100, 100, 200));
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .up, 200, 100, 301)));
}

// Locks cancel (section 2): a drag and a pinch end `cancelled` on a cancel of any participating
// contact, a cancel of one-finger press fires nothing, a cancel before the second finger's lift
// of an untouched chord fires nothing, and the recognizer is idle after the last contact is up.
test "a cancel cancels the gesture and fires nothing else" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    _ = rec.feed(smp(1, .move, 30, 0, 10));
    try testing.expectEqual(Phase.cancelled, rec.feed(smp(1, .cancel, 30, 0, 20)).drag.phase);
    try testing.expectEqual(State.idle, rec.state);
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    _ = rec.feed(smp(2, .down, 100, 0, 10));
    _ = rec.feed(smp(2, .move, 150, 0, 20));
    try testing.expectEqual(Phase.cancelled, rec.feed(smp(2, .cancel, 150, 0, 30)).two_finger.phase);
    try testing.expectEqual(State.blocked, rec.state);
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .up, 0, 0, 40)));
    try testing.expectEqual(State.idle, rec.state);
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .cancel, 0, 0, 10)));
    _ = rec.feed(smp(1, .down, 0, 0, 0));
    _ = rec.feed(smp(2, .down, 100, 0, 10));
    try testing.expectEqual(Gesture.none, rec.feed(smp(1, .cancel, 0, 0, 20)));
    try testing.expectEqual(Gesture.none, rec.feed(smp(2, .up, 100, 0, 30)));
    try testing.expectEqual(State.idle, rec.state);
}

// Locks the third contact and the masks: a third finger is counted and ignored, a recognizer with
// only `tap` ignores a chord's second finger and still taps, and a mask without `drag` reports
// no drag but still fails the tap.
test "extra contacts and missing kinds change nothing else" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 100, 100, 0));
    _ = rec.feed(smp(2, .down, 200, 100, 10));
    _ = rec.feed(smp(3, .down, 300, 100, 20));
    try testing.expectEqual(@as(u32, 3), rec.live);
    try testing.expectEqual(Gesture.none, rec.feed(smp(3, .move, 400, 100, 30)));
    try testing.expectEqual(Gesture.none, rec.feed(smp(3, .up, 400, 100, 40)));
    try testing.expectEqual(@as(u32, 2), rec.live);
    var plain = Recognizer.init(.{ .tap = true }, .{});
    _ = plain.feed(smp(1, .down, 10, 10, 0));
    _ = plain.feed(smp(2, .down, 60, 10, 5));
    try testing.expectEqual(State.one, plain.state);
    try testing.expectEqual(Gesture.none, plain.feed(smp(2, .up, 60, 10, 20)));
    try testing.expectEqual(Spot{ .x = 10, .y = 10 }, plain.feed(smp(1, .up, 10, 10, 40)).tap);
    var still = Recognizer.init(.{ .tap = true }, .{});
    _ = still.feed(smp(1, .down, 0, 0, 0));
    try testing.expectEqual(Gesture.none, still.feed(smp(1, .move, 50, 0, 10)));
    try testing.expectEqual(Gesture.none, still.feed(smp(1, .up, 50, 0, 20)));
}

// Locks time wrap: a tap whose down time is 100 ms before the `u32` wraps and whose lift is 100 ms
// after is 200 ms, a tap.
test "tap times wrap like click times" {
    var rec = recognizer();
    _ = rec.feed(smp(1, .down, 5, 5, std.math.maxInt(u32) - 99));
    try testing.expectEqual(Spot{ .x = 5, .y = 5 }, rec.feed(smp(1, .up, 5, 5, 100)).tap);
}

const widget_fixture = @import("../widgets/fixture.zig");
const cx_module = @import("cx.zig");

fn two_areas(cx: *widget_fixture.Context) void {
    cx.begin_frame(600, 300, 120);
    cx.area(areas.id("left", 0), .{ .x = 0, .y = 0, .width = 200, .height = 200 }, 0, cx_module.plain);
    cx.area(areas.id("right", 0), .{ .x = 300, .y = 0, .width = 200, .height = 200 }, 0, cx_module.plain);
    _ = cx.end_frame();
}

/// Dispatches a touch event as `ui.dispatch` does and feeds every pointer event to `rec` for `id`,
/// returning the last gesture that was not `none`.
fn feed_touch(cx: *widget_fixture.Context, rec: *Recognizer, id: Id, event: input.Event) Gesture {
    const plan = cx.touch_begin(event) orelse return .none;
    var last: Gesture = .none;
    for (plan.events[0..plan.count]) |pointer_event| {
        cx.event_begin(pointer_event);
        const got = rec.handle(cx, id, pointer_event);
        if (got != .none) last = got;
        cx.event_end();
    }
    cx.touch_end();
    return last;
}

fn touch_at(id: u32, x: f32, y: f32, time_ms: u32) input.Event {
    return .{ .touch_down = .{ .id = id, .x = x, .y = y, .time_ms = time_ms } };
}

// Locks `handle` with fingers (section 4): a pinch on one target works with both fingers on it, two
// fingers on different targets give each target a lone contact and no pinch, a tap through the
// context is a tap once (the leave after a lift is not a second lift), and a cancel through it
// cancels a drag.
test "handle takes a target's fingers from the context" {
    const cx = widget_fixture.context();
    two_areas(cx);
    const left = areas.id("left", 0);
    const right = areas.id("right", 0);
    var rec: Recognizer = .init(.all, .{});
    _ = feed_touch(cx, &rec, left, touch_at(0, 50, 100, 0));
    _ = feed_touch(cx, &rec, left, touch_at(1, 150, 100, 10));
    const moved = feed_touch(cx, &rec, left, .{ .touch_move = .{ .id = 1, .x = 190, .y = 100, .time_ms = 20 } });
    try testing.expect(moved.two_finger.pinching);
    _ = feed_touch(cx, &rec, left, .{ .touch_up = .{ .id = 1, .time_ms = 30 } });
    _ = feed_touch(cx, &rec, left, .{ .touch_up = .{ .id = 0, .time_ms = 40 } });
    try testing.expectEqual(State.idle, rec.state);

    var split: Recognizer = .init(.all, .{});
    _ = feed_touch(cx, &split, left, touch_at(0, 50, 100, 0));
    _ = feed_touch(cx, &split, left, touch_at(1, 350, 100, 5));
    const apart = feed_touch(cx, &split, left, .{ .touch_move = .{ .id = 1, .x = 480, .y = 100, .time_ms = 10 } });
    try testing.expectEqual(Gesture.none, apart);
    try testing.expectEqual(@as(u32, 1), split.live);
    const tapped = feed_touch(cx, &split, left, .{ .touch_up = .{ .id = 0, .time_ms = 60 } });
    try testing.expectEqual(Spot{ .x = 50, .y = 100 }, tapped.tap);
    _ = feed_touch(cx, &split, right, .{ .touch_up = .{ .id = 1, .time_ms = 70 } });

    var dragger: Recognizer = .init(.all, .{});
    _ = feed_touch(cx, &dragger, left, touch_at(0, 50, 100, 0));
    _ = feed_touch(cx, &dragger, left, .{ .touch_move = .{ .id = 0, .x = 100, .y = 100, .time_ms = 10 } });
    const cancelled = feed_touch(cx, &dragger, left, .{ .touch_cancel = 0 });
    try testing.expectEqual(Phase.cancelled, cancelled.drag.phase);
}

// Locks the clock through the context: frames add up to the long-press and keep the app animating
// only while it is pending; the press owes a draw; and after the press fires, frames ask for none.
test "frames drive the long press and ask for no more once it fired" {
    const cx = widget_fixture.context();
    two_areas(cx);
    const left = areas.id("left", 0);
    var rec: Recognizer = .init(.{ .long_press = true, .tap = true }, .{});
    cx.dirty = false;
    _ = feed_touch(cx, &rec, left, touch_at(0, 50, 100, 0));
    try testing.expect(cx.dirty);
    var fired: ?Gesture = null;
    var frames: u32 = 0;
    while (frames < 60) : (frames += 1) {
        cx.animating = false;
        cx.event_begin(.{ .frame = 16 });
        const got = rec.handle(cx, left, .{ .frame = 16 });
        const wanted = cx.animating;
        cx.event_end();
        if (got == .long_press) {
            fired = got;
            try testing.expect(!wanted);
            break;
        }
        try testing.expect(wanted);
    }
    // The 25th frame brings the total to 400 ms.
    try testing.expectEqual(@as(u32, 24), frames);
    try testing.expectEqual(Spot{ .x = 50, .y = 100 }, fired.?.long_press);
}

// Locks the mouse (section 5): a left click is a tap, a left drag a drag, a left press held 400 ms
// a long-press; a right click gives nothing; and a mouse never runs a two-finger kind.
test "the mouse's left button is the one-finger set" {
    const cx = widget_fixture.context();
    two_areas(cx);
    const left = areas.id("left", 0);
    var rec: Recognizer = .init(.all, .{});
    const press: input.Button = .{ .x = 50, .y = 60, .time_ms = 100, .button = .left, .mods = .none };
    var event: input.Event = .{ .pointer_down = press };
    cx.event_begin(event);
    _ = rec.handle(cx, left, event);
    cx.event_end();
    var release = press;
    release.time_ms = 200;
    event = .{ .pointer_up = release };
    cx.event_begin(event);
    const tapped = rec.handle(cx, left, event);
    cx.event_end();
    try testing.expectEqual(Spot{ .x = 50, .y = 60 }, tapped.tap);
    var right = press;
    right.button = .right;
    event = .{ .pointer_down = right };
    cx.event_begin(event);
    try testing.expectEqual(Gesture.none, rec.handle(cx, left, event));
    cx.event_end();
    event = .{ .pointer_down = press };
    cx.event_begin(event);
    _ = rec.handle(cx, left, event);
    cx.event_end();
    event = .{ .pointer_move = .{ .x = 90, .y = 60 } };
    cx.event_begin(event);
    const dragged = rec.handle(cx, left, event);
    cx.event_end();
    try testing.expectEqual(Phase.began, dragged.drag.phase);
    try testing.expectEqual(@as(f32, 40), dragged.drag.dx);
}

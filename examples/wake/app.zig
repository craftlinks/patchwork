//! Wake example: a producer on another thread feeds the screen through the app's own ring and a
//! `patchwork.Wake`, and the screen sleeps when it stops (step 54).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The producer contract (`src/app.zig`, section 4e) with no audio and no peer library. A
//! producer makes a tick every `tick_frames` frames of a 48 kHz clock (5 ms, 200 a second), a
//! value on a slow sine, pushes it into `Ring`, the app's own queue for one producer and one
//! consumer, and calls `Wake.notify`. The UI's `drain` pops every waiting value into a history of
//! `history_len` and owes a draw; the screen draws the history as a sparkline with the counts.
//! ```text
//! title   16, 16, 1056 by 32
//! spark   16, 56, 1056 by 384    the last 256 values, -1 to 1
//! stats   16, 456, 1056 by 24    ticks, drained, wakes written, dropped, running or stopped
//! ```
//!
//! ## 2. Three Producers, One Generator
//! `Producer.step(frames)` makes the ticks `frames` more of the clock owe, keeping the frames
//! short of a tick for the next call, so every host makes the same values in the same order:
//! - natively, `args` starts a thread that waits on a futex while stopped, and while running
//!   steps by `tick_frames` and sleeps 5 ms; the UI sleeps in `poll` until its notify;
//! - in regress and the native bench no thread runs: `produce(frames)` steps it by the frame's
//!   sample time (`bench.producer_frames_at`), 800 frames at 60 fps, 3 or 4 ticks;
//! - in the browser, `app.js` runs an interval of 5 ms while running, which calls the wasm's
//!   `wake_push` and then `shell.wake()`; the wasm starts and stops it through `wake_run`, an
//!   import of the app's own (`web/shell.js`, section 9a).
//! Space starts and stops it.
//!
//! ## 3. The Ring
//! `head` is published `seq_cst` and `pending` loads both indices `seq_cst`, so `Wake.arm` over it
//! has its total order (`src/wake.zig`, section 2). A full ring counts the value in `dropped`.
//!
//! ## 4. TigerStyle Invariants
//! - Static storage: the ring, the history, and the thread's stack size are fixed.
//! - `drain` takes at most `ring_capacity` values; a step makes at most `step_ticks_max`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const theme = patchwork.theme;
const ui = patchwork.ui;
const kit = patchwork.widgets.kit;

const Rect = quads.Rect;
const is_wasm = builtin.target.cpu.arch.isWasm();

pub const title_rect: Rect = .{ .x = 16, .y = 16, .width = 1056, .height = 32 };
pub const spark_rect: Rect = .{ .x = 16, .y = 56, .width = 1056, .height = 384 };
pub const stats_rect: Rect = .{ .x = 16, .y = 456, .width = 1056, .height = 24 };

/// Frames of the 48 kHz clock between two ticks: 5 ms, 200 ticks a second.
pub const tick_frames: u32 = 240;
/// Ticks in one period of the value's sine: one second.
pub const ticks_per_cycle: u32 = 200;
pub const ring_capacity: u32 = 256;
pub const history_len: u32 = 256;
/// The most ticks one step makes: a second's worth, more than any frame at `fps_min`.
pub const step_ticks_max: u32 = ticks_per_cycle;

const face_color: [4]f32 = .{ 0.05, 0.07, 0.06, 1 };
const trace_color: [4]f32 = .{ 0.35, 1.0, 0.55, 1 };
const axis_color: [4]f32 = .{ 1, 1, 1, 0.18 };
const ink = theme.dark.colors.text;
const title_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const label_style: text.Style = .{ .face = .sans, .size = 13, .color = ink };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

const stats_cap: u32 = 128;
const path_cap: u32 = quads.path.chunks_max(history_len);

comptime {
    assert(patchwork.bench.producer_frames_max <= step_ticks_max * tick_frames);
    assert(std.math.isPowerOfTwo(ring_capacity));
    assert(spark_rect.width >= history_len);
}

/// The app's queue for one producer and one consumer (section 3).
pub const Ring = struct {
    values: [ring_capacity]f32,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    dropped: std.atomic.Value(u32),

    pub fn init(ring: *Ring) void {
        ring.values = @splat(0);
        ring.head = .init(0);
        ring.tail = .init(0);
        ring.dropped = .init(0);
        assert(ring.pending() == 0);
    }

    /// Producer: copies `value` in; false, and counted, when the ring is full.
    pub fn push(ring: *Ring, value: f32) bool {
        const head = ring.head.load(.monotonic);
        const tail = ring.tail.load(.acquire);
        assert(head -% tail <= ring_capacity);
        if (head -% tail == ring_capacity) {
            _ = ring.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        ring.values[head % ring_capacity] = value;
        ring.head.store(head +% 1, .seq_cst);
        return true;
    }

    /// Consumer: the oldest value, or null.
    pub fn pop(ring: *Ring) ?f32 {
        const tail = ring.tail.load(.monotonic);
        const head = ring.head.load(.acquire);
        if (head == tail) return null;
        const value = ring.values[tail % ring_capacity];
        ring.tail.store(tail +% 1, .release);
        return value;
    }

    /// Values waiting, `seq_cst` for the wake's argument (section 3).
    pub fn pending(ring: *const Ring) u32 {
        const used = ring.head.load(.seq_cst) -% ring.tail.load(.seq_cst);
        assert(used <= ring_capacity);
        return used;
    }
};

/// The one generator every host steps (section 2).
pub const Producer = struct {
    ticks: u64,
    /// Frames of the clock short of the next tick.
    frames_short: u32,

    pub const zero: Producer = .{ .ticks = 0, .frames_short = 0 };

    /// Makes the ticks `frames` more frames owe, pushes them, and notifies once if it made any.
    pub fn step(producer: *Producer, frames: u32, ring: *Ring, wake: *patchwork.Wake) void {
        var total = producer.frames_short + frames;
        var made: u32 = 0;
        while (total >= tick_frames and made < step_ticks_max) : (made += 1) {
            _ = ring.push(value_of(producer.ticks));
            producer.ticks += 1;
            total -= tick_frames;
        }
        assert(total < tick_frames);
        producer.frames_short = total;
        if (made > 0) wake.notify();
    }
};

/// Tick `n`'s value: a sine of one second.
pub fn value_of(n: u64) f32 {
    const phase: f32 = @floatFromInt(n % ticks_per_cycle);
    return 0.8 * @sin(std.math.tau * phase / ticks_per_cycle);
}

/// The native thread (section 2): a futex word, `stopped`, `running`, or `quit`.
const Thread = if (is_wasm) struct {} else struct {
    const linux = std.os.linux;
    const stopped: u32 = 0;
    const running: u32 = 1;
    // As `audio_thread.zig`: glibc puts static TLS on the stack, and 64 KiB was refused.
    const stack_bytes: usize = 1024 * 1024;
    /// One tick of the 48 kHz clock: 5 ms.
    const tick_ns: u64 = @as(u64, tick_frames) * std.time.ns_per_s / 48_000;

    comptime {
        assert(tick_ns == 5 * std.time.ns_per_ms);
    }

    fn main(app: *App) void {
        var deadline_ns = monotonic_ns();
        while (true) {
            const state = app.state.load(.acquire);
            if (state == stopped) {
                const wait: linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
                _ = linux.futex_4arg(&app.state.raw, wait, stopped, null);
                deadline_ns = monotonic_ns();
                continue;
            }
            if (state != running) return;
            app.producer.step(tick_frames, &app.ring, &app.wake_value);
            deadline_ns += tick_ns;
            sleep_until(deadline_ns);
        }
    }

    fn wake_futex(app: *App) void {
        _ = linux.futex_3arg(&app.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
    }

    fn sleep_until(deadline_ns: u64) void {
        const spec: linux.timespec = .{
            .sec = @intCast(deadline_ns / std.time.ns_per_s),
            .nsec = @intCast(deadline_ns % std.time.ns_per_s),
        };
        _ = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &spec, null);
    }

    fn monotonic_ns() u64 {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        assert(linux.clock_gettime(.MONOTONIC, &ts) == 0);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

/// The browser's producer, in `app.js`: started and stopped through this import (section 2).
extern "env" fn wake_run(on: u32) void;

/// The browser's tick: one step of the clock's 5 ms, then `app.js` calls `shell.wake()`.
fn wake_push() callconv(.c) void {
    App.instance.producer.step(tick_frames, &App.instance.ring, &App.instance.wake_value);
}

comptime {
    if (is_wasm) @export(&wake_push, .{ .name = "wake_push" });
}

/// The wake screen. See the module guide.
pub const App = struct {
    wake_value: patchwork.Wake,
    ring: Ring,
    producer: Producer,
    /// The thread's futex word (section 2); `running` also says whether `produce` steps.
    state: std.atomic.Value(u32),
    /// Whether `args` started the native thread, so `produce` never runs beside it.
    threaded: bool,
    history: [history_len]f32,
    /// Values drained since startup, and `drain` calls.
    drained: u64,
    drains: u64,

    /// The one instance, for the browser's export (`wake_push`).
    var instance: *App = undefined;

    pub const config: patchwork.app.Config = .{
        .title = "wake",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = quads.Box, .cap = 4 },
            .{ .type = quads.Glyph, .cap = 256 },
            .{ .type = quads.Path, .cap = path_cap },
        },
        .batch_cap = 16,
        .area_cap = 1,
        .point_cap = history_len,
    };

    const space: patchwork.bench.Step = .{ .key = .{ .key = .other, .text = " " } };
    pub const scenarios: []const patchwork.bench.Scenario = &.{
        .{ .name = "idle", .setup = &.{.{ .wait = 5 }}, .cycle = &.{.{ .wait = 1 }}, .frames = 30 },
        .{
            .name = "run",
            .setup = &.{ .{ .wait = 5 }, space, .{ .wait = 5 } },
            .cycle = &.{},
            .frames = 90,
        },
        .{
            .name = "stop",
            .setup = &.{ .{ .wait = 5 }, space, .{ .wait = 40 }, space, .{ .wait = 5 } },
            .cycle = &.{},
            .frames = 30,
        },
    };

    pub fn init(app: *App, textures: *quads.Textures) void {
        _ = textures;
        app.wake_value = .init(-1);
        app.ring.init();
        app.producer = .zero;
        app.state = .init(0);
        app.threaded = false;
        app.history = @splat(0);
        app.drained = 0;
        app.drains = 0;
        instance = app;
    }

    /// Native window only: starts the producer's thread, stopped (section 2).
    pub fn args(app: *App, arguments: []const [:0]const u8) void {
        if (arguments.len > 0) {
            std.debug.print("usage: wake (no arguments)\n", .{});
            std.process.exit(2);
        }
        if (is_wasm) return;
        const thread = std.Thread.spawn(.{ .stack_size = Thread.stack_bytes }, Thread.main, .{app});
        if (thread) |handle| {
            handle.detach();
            app.threaded = true;
        } else |err| {
            std.debug.print("wake: no producer thread: {s}\n", .{@errorName(err)});
        }
    }

    pub fn wake(app: *App) *patchwork.Wake {
        return &app.wake_value;
    }

    pub fn pending(app: *const App) u32 {
        return app.ring.pending();
    }

    /// Takes every value waiting into the history and owes a draw (section 1).
    pub fn drain(app: *App, cx: *Context) void {
        app.drains += 1;
        var count: u32 = 0;
        while (count < ring_capacity) : (count += 1) {
            const value = app.ring.pop() orelse break;
            std.mem.copyForwards(f32, app.history[0 .. history_len - 1], app.history[1..]);
            app.history[history_len - 1] = value;
        }
        assert(count <= ring_capacity);
        app.drained += count;
        if (count > 0) cx.redraw();
    }

    /// Steps the producer where no thread runs it (section 2).
    pub fn produce(app: *App, frames: u32) void {
        assert(!app.threaded);
        if (app.state.load(.monotonic) != 1) return;
        app.producer.step(frames, &app.ring, &app.wake_value);
    }

    pub fn event(app: *App, cx: *Context, event_value: input.Event) void {
        switch (event_value) {
            .key_down => |press| {
                if (press.key == .other and std.mem.eql(u8, press.typed(), " ")) app.toggle(cx);
            },
            else => {},
        }
    }

    /// Starts or stops the producer, on whichever host runs it (section 2).
    fn toggle(app: *App, cx: *Context) void {
        const on: u32 = if (app.state.load(.monotonic) == 1) 0 else 1;
        app.state.store(on, .release);
        if (is_wasm) {
            wake_run(on);
        } else if (app.threaded) {
            Thread.wake_futex(app);
        }
        cx.redraw();
    }

    pub fn timer(app: *App, cx: *Context, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }

    pub fn draw(app: *App, cx: *Context) void {
        const draw_cx = cx.drawing();
        const window = clip_of(cx.window);
        const running = app.state.load(.monotonic) == 1;
        const title = if (running)
            "wake: producing (space stops)"
        else
            "wake: stopped (space starts)";
        append_box(cx, spark_rect, face_color, spark_rect, 8);
        text.place(draw_cx, title_style, title, title_rect, window, left);
        const center_y = spark_rect.y + spark_rect.height / 2;
        const axis: Rect = .{
            .x = spark_rect.x,
            .y = center_y,
            .width = spark_rect.width,
            .height = 1,
        };
        append_box(cx, axis, axis_color, spark_rect, 0);
        var points: [history_len]quads.path.Point = undefined;
        const step_x = spark_rect.width / @as(f32, history_len);
        const scale = spark_rect.height / 2 - 16;
        for (&points, app.history, 0..) |*point, value, index| {
            const x = spark_rect.x + step_x * (@as(f32, @floatFromInt(index)) + 0.5);
            point.* = .{ x, center_y - value * scale };
        }
        const clip = clip_of(spark_rect);
        const style: quads.path.Stroke = .{ .color = trace_color, .width = 2, .hover = 0 };
        _ = quads.path.polyline(draw_cx, &points, style, clip);
        app.draw_stats(cx, running);
        assert(cx.draw.overflow_count == 0);
    }

    fn draw_stats(app: *const App, cx: *Context, running: bool) void {
        var buffer: [stats_cap]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "ticks {d}    drained {d}    dropped {d}    {s}", .{
            app.producer.ticks,
            app.drained,
            app.ring.dropped.load(.monotonic),
            if (running) "running" else "stopped",
        }) catch unreachable;
        text.place(cx.drawing(), label_style, line, stats_rect, clip_of(cx.window), left);
    }
};

pub const Context = patchwork.app.Context(App);

fn append_box(cx: *Context, rect: Rect, color: [4]f32, clip: Rect, radius: f32) void {
    kit.append(cx, quads.Box, null, .of(rect, clip_of(clip), .{ .fill = color, .radius = radius }));
}

fn clip_of(rect: Rect) quads.Clip {
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

const fixture = struct {
    var app: App = undefined;
    var context: Context = undefined;
};

fn new_app() *App {
    fixture.context.init();
    patchwork.app.start(App, &fixture.context);
    App.init(&fixture.app, &fixture.context.draw.textures);
    return &fixture.app;
}

// Locks the generator (section 2): 800 frames make 3 ticks and keep 80 short, the next 800 make 3
// more and the third 4, so three steps of 800 make 10, as one step of 2400 does; a step notifies
// an armed wake once.
test "the producer makes the same ticks however it is stepped" {
    var ring: Ring = undefined;
    ring.init();
    var wake = patchwork.Wake.init(-1);
    var producer: Producer = .zero;
    producer.step(800, &ring, &wake);
    try std.testing.expectEqual(@as(u64, 3), producer.ticks);
    try std.testing.expectEqual(@as(u32, 80), producer.frames_short);
    producer.step(800, &ring, &wake);
    try std.testing.expectEqual(@as(u64, 6), producer.ticks);
    producer.step(800, &ring, &wake);
    try std.testing.expectEqual(@as(u64, 10), producer.ticks);
    var once: Producer = .zero;
    var other: Ring = undefined;
    other.init();
    once.step(2400, &other, &wake);
    try std.testing.expectEqual(producer.ticks, once.ticks);
    try std.testing.expectEqual(@as(u32, 10), ring.pending());
    try std.testing.expect(wake.arm(&ring) == false);
    var empty: Ring = undefined;
    empty.init();
    try std.testing.expect(wake.arm(&empty));
    producer.step(240, &empty, &wake);
    try std.testing.expectEqual(@as(u32, 1), wake.notified.raw);
}

// Locks the ring (section 3): 256 values fit, the next is dropped and counted, and they come out
// in order.
test "the ring keeps order and counts a full push" {
    var ring: Ring = undefined;
    ring.init();
    for (0..ring_capacity) |index| try std.testing.expect(ring.push(@floatFromInt(index)));
    try std.testing.expect(!ring.push(9));
    try std.testing.expectEqual(@as(u32, 1), ring.dropped.raw);
    for (0..ring_capacity) |index| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(index)), ring.pop().?);
    }
    try std.testing.expect(ring.pop() == null);
}

// Locks the drain on the UI thread (section 1): Space starts the producer, 60 frames of produce at
// 60 fps make 200 ticks, one second, and drain takes them all into the history, whose last value is
// the sine just before its zero; stopped, produce makes nothing.
test "space, produce, and drain move the history" {
    const app = new_app();
    const cx = &fixture.context;
    ui.dispatch(App, app, cx, .{ .key_down = input.key_press(.other, .none, false, " ") });
    for (0..60) |frame| {
        app.produce(patchwork.bench.producer_frames_at(frame, 60));
        app.drain(cx);
    }
    try std.testing.expectEqual(@as(u64, 200), app.producer.ticks);
    try std.testing.expectEqual(@as(u64, 200), app.drained);
    try std.testing.expectEqual(value_of(199), app.history[history_len - 1]);
    ui.dispatch(App, app, cx, .{ .key_down = input.key_press(.other, .none, false, " ") });
    app.produce(800);
    try std.testing.expectEqual(@as(u64, 200), app.producer.ticks);
}

comptime {
    patchwork.app.check(App);
}

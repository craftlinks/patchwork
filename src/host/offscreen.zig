//! Offscreen frames: an app rendered with no window, at a size, a scale, and a time the caller
//! picks, and read back as rows of pixels.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Library Type
//! A video, a thumbnail, or a contact sheet needs a frame at a time and a size it picks, and an
//! app cannot reach a device, a target, or readback by itself. `Offscreen(App)` owns them and the
//! frame loop. It knows nothing of scenarios or goldens: `host/headless.zig` is its first client
//! (`--regress`, `--render`), and any native caller may be another.
//! ```text
//! open({adapter, width, height, scale_120, fps})   device, target, staging buffer
//!   start({cache})                                 fresh app, context, and renderer (section 3)
//!     dispatch(event), step(step, time_ms)         input at the caller's pace
//!     frame(at)                                    one frame's work (section 2)
//!     read(layout, out)                            the target as rows, top to bottom
//! close()
//! ```
//! Drawing and reading are separate calls because a regress run draws a whole scenario and reads
//! only its last frame. Nothing in the renderer or the app knows which client drives it. The
//! storage is static, so there is one live instance per `App` type. Sizes follow the windowed
//! host's rule (`frame.pixel_size`), and either side may be at most `bench.width_max`, the limit
//! of a device with default limits. Frames are opaque: `read` gives alpha 255.
//!
//! ## 2. The Frame
//! `frame(at)` is the windowed bench's order of work (`linux_window.zig`, sections 4 and 5c')
//! with the time given instead of measured:
//! 1. the app timer's ticks owed by `at.time_ms` (`bench.Clock`, shared with the browser
//!    replay): with period `p`, a tick at every multiple of `p` up to the time, while
//!    `cx.timer_on`, fired as `at.ticks` says (section 5); ticks that fall while the timer is
//!    off are skipped;
//! 2. `ui.animate` with `at.dt_ms`;
//! 3. with a producer (`app.zig`, section 4e), `App.produce` with
//!    `bench.producer_frames_at(k, fps)` frames when the app declares it, then `App.drain`, `k`
//!    counting the frames stepped so far; no thread runs a producer here;
//! 4. `ui.draw_frame` and `Renderer.frame` with `time_s` of `at`, then `gpu_wgpu.execute`.
//! Input comes before `frame`: `step` stamps a scenario step's presses with the time it is given
//! and dispatches them, then serves the drop and the window request as every replay does.
//! Every frame runs the renderer's own skip and cache logic as in a window, so a frame that
//! changed nothing leaves the target as it was.
//!
//! ## 3. Fresh State per Start
//! The app, the UI context, the renderer, and the command buffer are static
//! (their sizes follow `App.config`), and every `start` initializes them in place as the windowed
//! host's `run` does. The device is kept between starts and its tables are emptied with
//! `gpu_wgpu.reset` before the setup stream is replayed again, which costs far less than a new
//! device. App state that `App.init` does not reset leaks from one start into the next; the fix
//! belongs in the app. `start` owes a redraw, so the first frame draws everything.
//!
//! ## 4. Time
//! `at_frame(n, fps)` is frame `n` of a clock at `fps`: `n * 1000 / fps` ms in integer division
//! and `dt_ms = 1000 / fps` (0 for frame 0, as the first sample after idle). At 60 it equals
//! `bench.Clock`. A caller that keeps its state outside the app timer may draw any time in any
//! order: ticks fire only as time passes the next multiple of the period, `dt_ms` is the
//! caller's, and `Offscreen` never rewinds the app. The shader clock is the only thing that
//! follows the time exactly. `fps` paces a producer only.
//!
//! ## 5. What a Timer Means Offscreen
//! A window's timer is a wake, not a count: when the loop was late, `drain_timer` makes one
//! `App.timer` call at the current time for all the periods missed (`linux_window.zig`, section
//! 1), and a browser's `setInterval` does not catch up either. So an app that steps a playhead
//! per call already runs slow under load, and an app that polls (a watched file) polls once. A
//! frame fires the ticks owed since the last one in either of two ways, `At.ticks`:
//! - `.each` (the default, and every replay's): one call per tick at the tick's own time, so a
//!   run of frames at a steady rate is the same run every time. At most
//!   `bench.ticks_per_frame_max` are owed to one frame, which bounds the frame's work; more is
//!   `error.TooManyTicks`, refused before any tick fires or anything draws, with a log line
//!   naming the ticks owed, the limit, and `.collapse`. The app is left as it was.
//! - `.collapse`: the window's rule. At most one call, at `at.time_ms`, however many ticks are
//!   owed, and none owed after. A tool that draws one frame at a time it picks (a still, a sheet,
//!   a first frame at 600 s) owes the ticks between its frames nothing.
//! The limit is not raised: it bounds a frame's loop, and no limit covers a time a caller picks.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: every buffer is static and sized by `App.config`; pixels go to the caller's
//!   `out`.
//! - Bounded loops: timer ticks by `bench.ticks_per_frame_max` (`.collapse` makes one call); a
//!   producer's frames by `bench.producer_frames_max`.
//! - `open` and every call after it check the instance's state with asserts, and a size or scale
//!   out of range is refused with an error before a device exists.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const app_contract = @import("../app.zig");
const bench = @import("../bench.zig");
const commands = @import("../gpu/commands.zig");
const frame_module = @import("../frame.zig");
const gpu_wgpu = @import("gpu_wgpu.zig");
const input = @import("../input.zig");
const renderer = @import("../draw/renderer.zig");
const ui = @import("../ui.zig");

/// A frame read back: `height` rows of `width` pixels in `layout`, top to bottom, over the
/// caller's `out`.
pub const Pixels = struct {
    width: u32,
    height: u32,
    layout: bench.Layout,
    bytes: []const u8,
};

/// When a frame happens: the shader clock's time, `ui.animate`'s delta (0 allowed), and how the
/// app timer's ticks owed by then fire (module guide, section 5).
pub const At = struct {
    time_ms: u64,
    dt_ms: f32,
    ticks: Ticks = .each,
};

/// How a frame fires the app timer's ticks owed since the last frame (module guide, section 5).
pub const Ticks = enum(u8) {
    /// One `App.timer` call per tick, at the tick's own time, as the replay clock fires them;
    /// `error.TooManyTicks` before any fires when more than `bench.ticks_per_frame_max` are owed.
    each,
    /// At most one `App.timer` call, at the frame's time, for all the ticks owed, as a window
    /// calls it after missed periods (`linux_window.zig`, section 1); none is owed after.
    collapse,
};

/// Frame `n` of a clock at `fps` (module guide, section 4).
pub fn at_frame(n: u64, fps: u32) At {
    assert(fps >= bench.fps_min and fps <= bench.fps_max);
    const period_ms = 1000.0 / @as(f32, @floatFromInt(fps));
    const at: At = .{ .time_ms = n * 1000 / fps, .dt_ms = if (n == 0) 0 else period_ms };
    assert(at.dt_ms >= 0);
    return at;
}

/// An app's frames with no window (module guide, section 1).
pub fn Offscreen(comptime App: type) type {
    comptime app_contract.check(App);
    return struct {
        pub const Context = app_contract.Context(App);

        pub const Options = struct {
            adapter: bench.Adapter = .high,
            /// Logical pixels.
            width: u32,
            height: u32,
            scale_120: u32 = 120,
            /// Paces a producer only (module guide, section 4).
            fps: u32 = 60,
        };

        pub const Start = struct {
            cache: bool = true,
        };

        const Renderer = renderer.Renderer(Context.DrawContext);
        const has_producer = app_contract.has_producer(App);

        // Module guide, section 3: static, initialized in place per start.
        var app_state: App = undefined;
        var ui_context: Context = undefined;
        var render: Renderer = undefined;
        var buffer: commands.CommandBuffer = undefined;
        var device: gpu_wgpu.Gpu = undefined;
        var paste_buffer: [ui.cx.clipboard_cap]u8 = undefined;

        var opened: bool = false;
        var started: bool = false;
        var drawn: bool = false;
        var size: renderer.Size = undefined;
        var fps: u32 = 0;

        /// One start's state: the timer clock, the producer's frames, and the clipboard.
        var clock: bench.Clock = undefined;
        /// Frames the producer was stepped by (module guide, section 2, step 3).
        var producer_frames: u64 = 0;
        var owns_copy: bool = false;

        /// Opens the device at a size, a scale, and a rate. `error.BadScale` outside
        /// `[frame.scale_120_min, frame.scale_120_max]`, `error.TooLarge` when either side is
        /// over `bench.width_max` device pixels, and the device's errors.
        pub fn open(options: Options) !void {
            assert(!opened);
            assert(options.width >= 1 and options.height >= 1);
            assert(options.fps >= bench.fps_min and options.fps <= bench.fps_max);
            const scale = options.scale_120;
            if (scale < frame_module.scale_120_min or scale > frame_module.scale_120_max) {
                return error.BadScale;
            }
            const width_px = frame_module.pixel_size(options.width, scale);
            const height_px = frame_module.pixel_size(options.height, scale);
            if (width_px > bench.width_max or height_px > bench.width_max) return error.TooLarge;
            device = try gpu_wgpu.create_headless(options.adapter);
            errdefer gpu_wgpu.destroy(&device);
            try gpu_wgpu.headless_target_create(&device, width_px, height_px);
            size = .{
                .width_logical = options.width,
                .height_logical = options.height,
                .width_px = width_px,
                .height_px = height_px,
                .scale_120 = scale,
            };
            fps = options.fps;
            buffer.len = 0;
            buffer.count = 0;
            opened = true;
            started = false;
            drawn = false;
        }

        pub fn close() void {
            assert(opened);
            gpu_wgpu.destroy(&device);
            opened = false;
            started = false;
            drawn = false;
        }

        /// Fresh state on the open device (module guide, section 3).
        pub fn start(options: Start) !void {
            assert(opened);
            started = false;
            drawn = false;
            gpu_wgpu.reset(&device);
            ui_context.init();
            app_contract.start(App, &ui_context);
            render.init();
            render.cache = options.cache;
            App.init(&app_state, &ui_context.draw.textures);
            buffer.reset();
            render.setup(&buffer, &ui_context.draw);
            try gpu_wgpu.execute(&device, &buffer);
            assert(render.ready);
            clock = .init(App.config.timer_period_ms);
            producer_frames = 0;
            owns_copy = false;
            // The first frame draws everything, as a window's first configure does.
            ui_context.redraw();
            started = true;
        }

        /// The app, which the caller may change between frames.
        pub fn app() *App {
            assert(started);
            return &app_state;
        }

        /// The UI context, which the caller may change between frames.
        pub fn context() *Context {
            assert(started);
            return &ui_context;
        }

        /// One dispatch with the windowed host's clipboard rule when the app owns the selection:
        /// a paste request pastes the app's own copy (`linux_window.zig`, 5a).
        pub fn dispatch(event: input.Event) void {
            assert(started);
            ui.dispatch(App, &app_state, &ui_context, event);
            if (ui_context.take_copy()) owns_copy = true;
            if (!ui_context.take_paste_request()) return;
            if (!owns_copy) return;
            const own = ui_context.copied();
            @memcpy(paste_buffer[0..own.len], own);
            ui.dispatch(App, &app_state, &ui_context, .{ .paste = paste_buffer[0..own.len] });
        }

        /// A scenario step's events, stamped `time_ms`. `error.NoArea` when its target was not
        /// in the last frame.
        pub fn step(taken: bench.Step, time_ms: u32) !void {
            assert(started);
            var rect: ?[4]f32 = null;
            if (bench.step_target(taken)) |target| {
                const found = ui_context.find(target.id) orelse return error.NoArea;
                rect = found.rect;
            }
            var events: [bench.event_cap]input.Event = undefined;
            const count = bench.step_events(taken, rect, time_ms, &events);
            for (events[0..count]) |event| dispatch(event);
            if (taken == .drop) {
                bench.replay_drop(App, &app_state, &ui_context, taken.drop, rect.?);
            }
            bench.serve_window(App, &app_state, &ui_context);
        }

        /// One frame at the given time (module guide, section 2). With `.ticks = .each`,
        /// `error.TooManyTicks` when more than `bench.ticks_per_frame_max` timer ticks are owed,
        /// before any fires or anything draws (section 5); and the GPU's errors.
        pub fn frame(at: At) !void {
            assert(started);
            assert(at.dt_ms >= 0);
            _ = fire_ticks(App, &app_state, &ui_context, &clock, at) catch |err| {
                std.log.err(
                    "offscreen frame at {d} ms owes {d} timer ticks of {d} ms, more than " ++
                        "bench.ticks_per_frame_max ({d}): draw it with .ticks = .collapse",
                    .{
                        at.time_ms,
                        clock.owed(at.time_ms, ui_context.timer_on),
                        App.config.timer_period_ms,
                        bench.ticks_per_frame_max,
                    },
                );
                return err;
            };
            _ = ui.animate(App, &app_state, &ui_context, at.dt_ms);
            if (has_producer) produce();
            const logical_w = size.width_logical;
            const logical_h = size.height_logical;
            _ = ui.draw_frame(App, &app_state, &ui_context, logical_w, logical_h, size.scale_120);
            buffer.reset();
            const time: animator.Time = .{ .ms = at.time_ms };
            render.frame(&buffer, &ui_context.draw, size, time.seconds());
            if (buffer.len != 0) try gpu_wgpu.execute(&device, &buffer);
            drawn = true;
        }

        /// Steps the producer by this frame's sample time and drains it (section 2, step 3).
        fn produce() void {
            assert(has_producer);
            if (comptime app_contract.has_produce(App)) {
                App.produce(&app_state, bench.producer_frames_at(producer_frames, fps));
            }
            producer_frames += 1;
            App.drain(&app_state, &ui_context);
        }

        /// Copies the target into `out`, whose length is the frame's in `layout`. Blocks until
        /// the GPU has finished the frames drawn so far.
        pub fn read(layout: bench.Layout, out: []u8) !Pixels {
            assert(drawn);
            const width = size.width_px;
            const height = size.height_px;
            assert(out.len == @as(usize, width) * height * layout.pixel_bytes());
            try gpu_wgpu.read_target(&device, out, layout);
            return .{ .width = width, .height = height, .layout = layout, .bytes = out };
        }

        /// The frame's size in device pixels.
        pub fn size_px() [2]u32 {
            assert(opened);
            return .{ size.width_px, size.height_px };
        }

        pub fn adapter_text() gpu_wgpu.AdapterText {
            assert(opened);
            return gpu_wgpu.adapter_text(&device);
        }
    };
}

/// Fires the app timer's ticks owed by `at.time_ms` as `at.ticks` says (module guide, sections 2
/// and 5) and returns the `App.timer` calls made. A refusal changes nothing: no tick fires and
/// the clock keeps them owed.
fn fire_ticks(
    comptime App: type,
    app_state: *App,
    ui_context: *app_contract.Context(App),
    clock: *bench.Clock,
    at: At,
) error{TooManyTicks}!u32 {
    assert(clock.period_ms == App.config.timer_period_ms);
    if (App.config.timer_period_ms == 0) assert(!ui_context.timer_on);
    switch (at.ticks) {
        .collapse => {
            if (!clock.collapse(at.time_ms, ui_context.timer_on)) return 0;
            App.timer(app_state, ui_context, at.time_ms);
            assert(clock.owed(at.time_ms, true) == 0);
            return 1;
        },
        .each => {
            const owed = clock.owed(at.time_ms, ui_context.timer_on);
            if (owed > bench.ticks_per_frame_max) return error.TooManyTicks;
            var calls: u32 = 0;
            while (clock.due(at.time_ms, ui_context.timer_on)) |tick| : (calls += 1) {
                assert(calls < owed);
                App.timer(app_state, ui_context, tick);
            }
            assert(calls <= bench.ticks_per_frame_max);
            return calls;
        },
    }
}

const testing = std.testing;

// Locks the frame clock: at 60 it is `bench.Clock` for 100,000 frames, so regress keeps its
// clock; at 30 it reads 0, 33, 66, 100 ms and at 24 it reads 0, 41, 83, 125 ms, with delta 0 for
// frame 0 and `1000 / fps` after.
test "frame times follow the frame rate" {
    for (0..100_000) |n| {
        const at = at_frame(n, 60);
        try testing.expectEqual(bench.Clock.frame_time_ms(n), at.time_ms);
        try testing.expectEqual(bench.Clock.frame_dt(n), at.dt_ms);
    }
    for ([4]u64{ 0, 33, 66, 100 }, 0..) |time_ms, n| {
        try testing.expectEqual(time_ms, at_frame(n, 30).time_ms);
    }
    for ([4]u64{ 0, 41, 83, 125 }, 0..) |time_ms, n| {
        try testing.expectEqual(time_ms, at_frame(n, 24).time_ms);
    }
    try testing.expectEqual(@as(f32, 0), at_frame(0, 24).dt_ms);
    try testing.expectEqual(@as(f32, 1000.0 / 24.0), at_frame(1, 24).dt_ms);
}

// Locks the size rule of worked sizes: 1920 x 1080 at 240 is 3840 x 2160; 1280 x 720 at 180 is
// 1920 x 1080 and at 150 is 1600 x 900; 1366 at 150 rounds half up to 1708.
test "device sizes follow the window's rounding" {
    try testing.expectEqual(@as(u32, 3840), frame_module.pixel_size(1920, 240));
    try testing.expectEqual(@as(u32, 2160), frame_module.pixel_size(1080, 240));
    try testing.expectEqual(@as(u32, 1920), frame_module.pixel_size(1280, 180));
    try testing.expectEqual(@as(u32, 1080), frame_module.pixel_size(720, 180));
    try testing.expectEqual(@as(u32, 1600), frame_module.pixel_size(1280, 150));
    try testing.expectEqual(@as(u32, 900), frame_module.pixel_size(720, 150));
    try testing.expectEqual(@as(u32, 1708), frame_module.pixel_size(1366, 150));
}

// Locks going back in time: the app timer fires as time passes each multiple of its period, a
// frame at an earlier time fires nothing, and a tick already fired never fires again.
test "time going backwards fires no tick" {
    var clock: bench.Clock = .init(100);
    try testing.expectEqual(@as(?u64, 100), clock.due(250, true));
    try testing.expectEqual(@as(?u64, 200), clock.due(250, true));
    try testing.expectEqual(@as(?u64, null), clock.due(250, true));
    try testing.expectEqual(@as(?u64, null), clock.due(40, true));
    try testing.expectEqual(@as(?u64, null), clock.due(250, true));
    try testing.expectEqual(@as(?u64, 300), clock.due(300, true));
}

/// The smallest app: `Offscreen` needs a GPU to run, so its GPU-free calls are compiled here.
const TinyApp = struct {
    const Cx = app_contract.Context(TinyApp);

    pub const config: app_contract.Config = .{
        .title = "tiny",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = @import("../draw.zig").Box, .cap = 4 }},
    };

    pub fn init(app: *TinyApp, pool: *@import("../draw/textures.zig").Textures) void {
        _ = app;
        _ = pool;
    }
    pub fn event(app: *TinyApp, cx: *Cx, event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }
    pub fn timer(app: *TinyApp, cx: *Cx, now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }
    pub fn draw(app: *TinyApp, cx: *Cx) void {
        _ = app;
        _ = cx;
    }
};

/// A 500 ms timer that counts its calls and keeps the last one's time.
const TimerApp = struct {
    calls: u32,
    last_ms: u64,

    const Cx = app_contract.Context(TimerApp);

    pub const config: app_contract.Config = .{
        .title = "timer",
        .timer_period_ms = 500,
        .draw = &.{.{ .type = @import("../draw.zig").Box, .cap = 4 }},
    };

    pub fn init(app: *TimerApp, pool: *@import("../draw/textures.zig").Textures) void {
        _ = pool;
        app.calls = 0;
        app.last_ms = 0;
    }
    pub fn event(app: *TimerApp, cx: *Cx, event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }
    pub fn timer(app: *TimerApp, cx: *Cx, now_ms: u64) void {
        _ = cx;
        app.calls += 1;
        app.last_ms = now_ms;
    }
    pub fn draw(app: *TimerApp, cx: *Cx) void {
        _ = app;
        _ = cx;
    }
};

// Locks a first frame far into a film: with a 500 ms timer, a frame at 600 s owes 1,200 ticks.
// `.each` refuses it with no call made and the ticks still owed; `.collapse` makes one call, at
// 600,000 ms, and owes nothing after, so the next `.each` frame at 600.5 s makes one call at
// 600,500 ms. A frame at an earlier time makes none; a stopped timer is called by neither.
test "a first frame at 600 s fires one tick when collapsed" {
    const static = struct {
        var app: TimerApp = undefined;
        var cx: TimerApp.Cx = undefined;
        var clock: bench.Clock = undefined;

        fn fire(at: At) !u32 {
            return fire_ticks(TimerApp, &app, &cx, &clock, at);
        }
    };
    static.cx.init();
    app_contract.start(TimerApp, &static.cx);
    TimerApp.init(&static.app, &static.cx.draw.textures);
    static.clock = .init(TimerApp.config.timer_period_ms);
    const clock = &static.clock;
    const late: At = .{ .time_ms = 600_000, .dt_ms = 0 };
    try testing.expectError(error.TooManyTicks, static.fire(late));
    try testing.expectEqual(@as(u32, 0), static.app.calls);
    try testing.expectEqual(@as(u64, 1_200), clock.owed(late.time_ms, true));
    var collapsed = late;
    collapsed.ticks = .collapse;
    try testing.expectEqual(@as(u32, 1), try static.fire(collapsed));
    try testing.expectEqual(@as(u32, 1), static.app.calls);
    try testing.expectEqual(@as(u64, 600_000), static.app.last_ms);
    try testing.expectEqual(@as(u32, 0), try static.fire(late));
    const next: At = .{ .time_ms = 600_500, .dt_ms = 0 };
    try testing.expectEqual(@as(u32, 1), try static.fire(next));
    try testing.expectEqual(@as(u64, 600_500), static.app.last_ms);
    var early = collapsed;
    early.time_ms = 1_000;
    try testing.expectEqual(@as(u32, 0), try static.fire(early));
    static.cx.set_timer(false);
    var stopped = collapsed;
    stopped.time_ms = 700_000;
    try testing.expectEqual(@as(u32, 0), try static.fire(stopped));
    stopped.ticks = .each;
    stopped.time_ms = 800_000;
    try testing.expectEqual(@as(u32, 0), try static.fire(stopped));
    try testing.expectEqual(@as(u32, 2), static.app.calls);
}

// Locks that the calls no bundled client makes compile: `app`, `context`, and `dispatch` are
// generic, so an unused one is otherwise never analysed.
test "the caller's calls compile for any app" {
    const Off = Offscreen(TinyApp);
    try testing.expect(@TypeOf(Off.app) == fn () *TinyApp);
    try testing.expect(@TypeOf(Off.context) == fn () *Off.Context);
    _ = &Off.dispatch;
    _ = &Off.step;
}

comptime {
    assert(bench.producer_frames_max > 0);
    assert(bench.width_max <= frame_module.edge_max);
}

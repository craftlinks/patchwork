//! Bench mode: scripted scenarios, per-frame samples, summaries, and frame images.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Bench Mode in the Library
//! Every performance step needs the same numbers before and after it lands: CPU time per frame
//! phase, GPU time of the pass, and where the GPU's fragments go. A pixel cache also needs
//! exact image comparison between two runs. This module holds the parts that need no window
//! and no GPU, so they are unit tested: scenario replay, command-line options, percentile
//! summaries, the shaded-area counter, and PPM images. The native host (`linux_window.zig`)
//! wires them to its frame seams, and `gpu_wgpu.zig` adds timestamps and frame readback, both
//! only when a scenario runs. `--regress` (`host/headless.zig`) and the browser's `?bench=`
//! replay share the scenarios, the clock (section 5b), and the images. Without `--bench` or
//! `--regress` nothing here executes.
//!
//! ## 2. Scenarios
//! An app may declare `pub const scenarios: []const bench.Scenario`. A scenario has a `setup`
//! list, run once, and a `cycle` list, repeated while `frames` frames are measured:
//! ```text
//! host idle (frame presented, no callback in flight, nothing owed)
//!   -> Replay.next() -> a step -> step_events() -> ui.dispatch, then one forced frame
//!   -> presented frame -> Replay.presented() -> measured once the setup is done
//! ```
//! Every step presents exactly one frame, even when it changes nothing, so a scenario's frame
//! count is its step count. A scenario with an empty `cycle` measures the frames the app
//! presents by itself (a transport driven by the app timer). Steps address areas of the last
//! frame by `Target`, so they survive layout changes; an unknown target ends the run with its
//! name. Pointer steps: `click` and `click_at` press and release, then leave the window, and
//! `right_click` does the same with the right button (a context menu);
//! `wheel` turns at the centre, then leaves; `hover` moves to a point and stays, so hover
//! animations and tooltips settle; `drag` presses, moves by a delta, and releases, and the
//! pointer stays at the end point.
//!
//! ## 2a. Headless Replay
//! `replay_headless` runs a scenario against an app and a static UI context with no host and
//! no GPU: the app draws a frame, the next step's events are dispatched, and so on. App tests
//! use it to keep scenarios valid as the app changes. Timer frames are not simulated, so an
//! empty cycle ends the replay.
//!
//! ## 3. Samples and Summaries
//! A `Sample` holds one presented frame's phase times in nanoseconds and its shaded area. The
//! host keeps at most `sample_cap` of them in static storage. `summarize` sorts one metric's
//! values in place and reads percentiles by index: `sorted[(count - 1) * q / 100]`.
//!
//! ## 4. Shaded Area
//! `shaded_area` sums `rect` intersected with `clip`, in device pixels, per draw type. It is
//! the counter that found the path overdraw after step 18: a type's area times its per-fragment
//! cost is its share of the pass. A type with a custom vertex quad rasterizes less than its
//! `rect`, so its area is an upper bound.
//!
//! ## 5. Images
//! Frames are written as binary PPM (`P6`, maxval 255) because the format is a short header
//! and raw RGB rows. `compare` returns the per-pixel maximum channel difference as a
//! histogram, so an exact match, rounding noise, and real differences read apart.
//!
//! ## 5a. PNG and Hashes
//! `png_write` writes 8-bit RGB PNG with no compression: one `IDAT` holding a zlib stream of
//! stored deflate blocks (at most 65535 bytes each) over the rows, each row led by filter
//! byte 0, with CRC-32 and Adler-32 from `std.hash`. Any viewer opens it and it needs no
//! deflate encoder; a 1280 x 720 frame is 2.7 MB. `png_read_stored` reads exactly that
//! form back (the regress host's baselines) and refuses anything else. `diff_rgb` paints a
//! diff picture: pixels equal in both images as the new pixel's grey at a quarter of its
//! level, differing pixels red, brighter the larger their maximum channel difference.
//! `rgb_hash` is XxHash64, seed 0, over the RGB rows top to bottom: the regress golden value.
//!
//! ## 5b. The Simulated Clock
//! `--regress` (`host/headless.zig`) and the browser's `?bench=` replay
//! (`host/web_exports.zig`) run scenarios on one clock, `Clock`: frame `n` at
//! `n * 1000 / 60` ms, `ui.animate` stepped by `frame_ms` (0 for frame 0), and an app timer of
//! period `p` ticking at every multiple of `p` up to the frame's time while it is on.
//! `regress_size` is the size both render at: `App.regress_size`, or 1280 x 720.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: replay state is three counters, summaries sort the caller's slice, and
//!   images are parsed in place.
//! - Bounds: `steps_max` steps per list, `scenario_cap` scenarios, `sample_cap` measured
//!   frames, `arg_cap` arguments; `validate` checks an app's scenarios at compile time.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("input.zig");
const areas = @import("ui/areas.zig");
const ui = @import("ui.zig");
const renderer = @import("draw/renderer.zig");
const textures = @import("draw/textures.zig");
const realtime = @import("realtime.zig");

/// Most steps in one `setup` or `cycle` list.
pub const steps_max: u32 = 256;

/// Most scenarios one app declares.
pub const scenario_cap: u32 = 32;

/// Most frames one run measures; the host's sample storage.
pub const sample_cap: u32 = 4096;

/// Most command-line arguments the native host reads.
pub const arg_cap: u32 = 16;

/// Most events one step dispatches: move, press, release, leave (a click), or move, press,
/// move, release (a drag).
pub const event_cap: u32 = 4;

/// Widest image `ppm_row` converts, in pixels.
pub const width_max: u32 = 8192;

/// An area of the last frame, by id, with the name and index it came from for messages.
pub const Target = struct {
    id: areas.Id,
    name: []const u8,
    index: u32,
};

/// The target of `areas.id(name, index)`.
pub fn area(comptime name: []const u8, index: u32) Target {
    const target: Target = .{ .id = areas.id(name, index), .name = name, .index = index };
    assert(target.id != .none);
    assert(target.name.len > 0);
    return target;
}

/// A key pressed and released; `text` is what it types, at most `input.key_text_cap` bytes.
pub const Press = struct {
    key: input.Key,
    text: []const u8,
};

/// A point at `(x, y)` logical pixels from the target's top-left.
pub const At = struct {
    target: Target,
    x: f32,
    y: f32,
};

/// A wheel turn at the target's centre.
pub const Turn = struct {
    target: Target,
    dx: f32,
    dy: f32,
};

/// A left drag: press at `(from_x, from_y)` from the target's top-left, move by `(dx, dy)`,
/// release. Not both of `dx` and `dy` are 0.
pub const Drag = struct {
    target: Target,
    from_x: f32,
    from_y: f32,
    dx: f32,
    dy: f32,
};

/// One scripted action. Each step presents one frame (module guide, section 2).
pub const Step = union(enum) {
    key: Press,
    /// A left click at the target's centre, then the pointer leaves the window.
    click: Target,
    click_at: At,
    /// A right click at the point, then the pointer leaves the window.
    right_click: At,
    wheel: Turn,
    /// The pointer moves to the point and stays there: no leave, so the target stays hovered.
    hover: At,
    /// Move to the start, press, move by the delta, release; the pointer rests at the end.
    drag: Drag,
    /// Frames presented without input.
    wait: u32,
};

pub const Scenario = struct {
    name: []const u8,
    /// Run once before measuring.
    setup: []const Step,
    /// Repeated while measuring; empty when the app presents frames by itself.
    cycle: []const Step,
    /// Frames to measure, `1 ..= sample_cap`.
    frames: u32,
    /// `--regress` renders it and compares its last frame with the golden file
    /// (`host/headless.zig`). A scenario that opts out says why in a comment.
    regress: bool = true,
};

/// Returns null when `scenarios` are well formed, otherwise a message naming the problem.
/// Called by `app.conformance` at compile time.
pub fn validate(comptime scenarios: []const Scenario) ?[]const u8 {
    if (scenarios.len > scenario_cap) return "App.scenarios: at most 32 scenarios";
    for (scenarios, 0..) |scenario, index| {
        const name = scenario.name;
        if (name.len == 0) return "App.scenarios: a scenario has an empty name";
        if (scenario.frames == 0) return "App.scenarios." ++ name ++ ": frames must be >= 1";
        if (scenario.frames > sample_cap) {
            return "App.scenarios." ++ name ++ ": frames must be at most 4096";
        }
        if (scenario.setup.len > steps_max) return "App.scenarios." ++ name ++ ": setup too long";
        if (scenario.cycle.len > steps_max) return "App.scenarios." ++ name ++ ": cycle too long";
        if (steps_invalid(scenario.setup) or steps_invalid(scenario.cycle)) {
            return "App.scenarios." ++ name ++ ": a key types more than 4 bytes or a wait is 0";
        }
        if (drag_still(scenario.setup) or drag_still(scenario.cycle)) {
            return "App.scenarios." ++ name ++ ": a drag moves by 0";
        }
        for (scenarios[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, name)) {
                return "App.scenarios: duplicate name " ++ name;
            }
        }
    }
    return null;
}

fn steps_invalid(steps: []const Step) bool {
    for (steps) |step| {
        switch (step) {
            .key => |press| if (press.text.len > input.key_text_cap) return true,
            .wait => |frames| if (frames == 0) return true,
            .click, .click_at, .right_click, .wheel, .hover, .drag => {},
        }
    }
    return false;
}

/// True when a drag of `steps` has `dx == 0` and `dy == 0`.
fn drag_still(steps: []const Step) bool {
    for (steps) |step| {
        if (step != .drag) continue;
        if (step.drag.dx == 0 and step.drag.dy == 0) return true;
    }
    return false;
}

/// The scenario with `name`, or null.
pub fn find(scenarios: []const Scenario, name: []const u8) ?*const Scenario {
    assert(scenarios.len <= scenario_cap);
    for (scenarios) |*scenario| {
        if (std.mem.eql(u8, scenario.name, name)) return scenario;
    }
    return null;
}

/// Replay state for one scenario (module guide, section 2).
pub const Replay = struct {
    phase: Phase,
    /// Index of the next step in `setup` or `cycle`.
    index: u32,
    /// Frames still to present for the current `wait` step, counting this one.
    wait_left: u32,
    measured: u32,

    pub const Phase = enum { setup, measure, done };

    pub fn init() Replay {
        const replay: Replay = .{ .phase = .setup, .index = 0, .wait_left = 0, .measured = 0 };
        assert(replay.phase == .setup);
        assert(replay.measured == 0);
        return replay;
    }

    /// The step to run now that the host is idle, or null when there is none: an empty
    /// cycle, or a finished run. Leaving the setup switches to measuring.
    pub fn next(self: *Replay, scenario: *const Scenario) ?Step {
        assert(self.index <= steps_max);
        if (self.phase == .done) return null;
        if (self.phase == .setup) {
            if (self.take(scenario.setup)) |step| return step;
            self.phase = .measure;
            self.index = 0;
            self.wait_left = 0;
        }
        assert(self.phase == .measure);
        if (scenario.cycle.len == 0) return null;
        if (self.index == scenario.cycle.len) self.index = 0;
        const step = self.take(scenario.cycle);
        assert(step != null);
        return step;
    }

    /// The next step of `steps`, holding a `wait` for its frame count, or null at the end.
    fn take(self: *Replay, steps: []const Step) ?Step {
        assert(self.index <= steps.len);
        if (self.index == steps.len) return null;
        const step = steps[self.index];
        switch (step) {
            .wait => |frames| {
                if (self.wait_left == 0) self.wait_left = frames;
                assert(self.wait_left >= 1);
                self.wait_left -= 1;
                if (self.wait_left == 0) self.index += 1;
            },
            else => self.index += 1,
        }
        return step;
    }

    /// Records a presented frame. Returns true when it was measured; the run is done after
    /// `scenario.frames` measured frames.
    pub fn presented(self: *Replay, scenario: *const Scenario) bool {
        assert(scenario.frames >= 1);
        if (self.phase != .measure) return false;
        assert(self.measured < scenario.frames);
        self.measured += 1;
        if (self.measured == scenario.frames) self.phase = .done;
        assert(self.measured <= scenario.frames);
        return true;
    }
};

/// The events of `step` for a target whose rect is `rect` (null for `key` and `wait`),
/// written to `out`. Returns how many. `time_ms` stamps presses, so steps a frame apart do
/// not count as a double click unless the frames are 400 ms apart or less.
pub fn step_events(step: Step, rect: ?[4]f32, time_ms: u32, out: *[event_cap]input.Event) u32 {
    switch (step) {
        .wait => return 0,
        .key => |press| {
            assert(press.text.len <= input.key_text_cap);
            var key: input.KeyPress = .{
                .key = press.key,
                .mods = .none,
                .repeat = false,
                .len = @intCast(press.text.len),
                .text = @splat(0),
            };
            @memcpy(key.text[0..press.text.len], press.text);
            out[0] = .{ .key_down = key };
            out[1] = .{ .key_up = key };
            return 2;
        },
        .click, .click_at, .right_click => {
            const r = rect.?;
            const offset: [2]f32 = switch (step) {
                .click => .{ r[2] / 2, r[3] / 2 },
                .click_at, .right_click => |at| .{ at.x, at.y },
                else => unreachable,
            };
            const x = r[0] + offset[0];
            const y = r[1] + offset[1];
            const button: input.Button = .{
                .x = x,
                .y = y,
                .time_ms = time_ms,
                .button = if (step == .right_click) .right else .left,
                .mods = .none,
            };
            out[0] = .{ .pointer_move = .{ .x = x, .y = y } };
            out[1] = .{ .pointer_down = button };
            out[2] = .{ .pointer_up = button };
            out[3] = .pointer_leave;
            return 4;
        },
        .wheel => |turn| {
            const r = rect.?;
            const x = r[0] + r[2] / 2;
            const y = r[1] + r[3] / 2;
            out[0] = .{ .pointer_move = .{ .x = x, .y = y } };
            out[1] = .{ .wheel = .{ .x = x, .y = y, .dx = turn.dx, .dy = turn.dy } };
            out[2] = .pointer_leave;
            return 3;
        },
        .hover => |at| {
            const r = rect.?;
            out[0] = .{ .pointer_move = .{ .x = r[0] + at.x, .y = r[1] + at.y } };
            return 1;
        },
        .drag => |drag| {
            assert(drag.dx != 0 or drag.dy != 0);
            const r = rect.?;
            const x = r[0] + drag.from_x;
            const y = r[1] + drag.from_y;
            const press: input.Button = .{
                .x = x,
                .y = y,
                .time_ms = time_ms,
                .button = .left,
                .mods = .none,
            };
            var release = press;
            release.x = x + drag.dx;
            release.y = y + drag.dy;
            out[0] = .{ .pointer_move = .{ .x = x, .y = y } };
            out[1] = .{ .pointer_down = press };
            out[2] = .{ .pointer_move = .{ .x = release.x, .y = release.y } };
            out[3] = .{ .pointer_up = release };
            return 4;
        },
    }
}

/// The target a step addresses, or null for `key` and `wait`.
pub fn step_target(step: Step) ?Target {
    return switch (step) {
        .click => |target| target,
        .click_at, .right_click => |at| at.target,
        .wheel => |turn| turn.target,
        .hover => |at| at.target,
        .drag => |drag| drag.target,
        .key, .wait => null,
    };
}

pub const ReplayError = error{NoArea};

/// Runs at most `steps_limit` steps of `scenario` against `app` and its UI context `cx`, one
/// `width` by `height` frame at scale 1 drawn before each (section 2a). Returns the steps run.
pub fn replay_headless(
    comptime App: type,
    app: *App,
    cx: anytype,
    scenario: *const Scenario,
    size: [2]u32,
    steps_limit: u32,
) ReplayError!u32 {
    assert(steps_limit >= 1);
    assert(size[0] >= 1);
    assert(size[1] >= 1);
    var replay: Replay = .init();
    var count: u32 = 0;
    while (count < steps_limit) : (count += 1) {
        cx.redraw();
        assert(ui.draw_frame(App, app, cx, size[0], size[1], 120));
        const step = replay.next(scenario) orelse break;
        var rect: ?[4]f32 = null;
        if (step_target(step)) |target| {
            const found = cx.find(target.id) orelse return error.NoArea;
            rect = found.rect;
        }
        var events: [event_cap]input.Event = undefined;
        // A second apart, so no two steps count as one double click.
        const time_ms = count * 1000;
        for (events[0..step_events(step, rect, time_ms, &events)]) |event| {
            ui.dispatch(App, app, cx, event);
        }
        _ = replay.presented(scenario);
    }
    assert(count <= steps_limit);
    return count;
}

/// The regress frame in logical pixels at scale 1 when the app declares no
/// `regress_size`: the browser check's viewport (section 5b).
pub const regress_size_default: [2]u32 = .{ 1280, 720 };

/// The size `--regress` and the browser replay render `App` at.
pub fn regress_size(comptime App: type) [2]u32 {
    return if (@hasDecl(App, "regress_size")) App.regress_size else regress_size_default;
}

/// The simulated frame period, as `ui.animate` receives it.
pub const frame_ms: f32 = 1000.0 / 60.0;

/// Most app timer ticks one simulated frame runs: a 1 ms timer over a 17 ms step, with margin.
pub const ticks_per_frame_max: u32 = 32;

/// The simulated clock (section 5b; `host/headless.zig`, section 2): frame times, `ui.animate`'s
/// delta, and the app timer's ticks.
pub const Clock = struct {
    period_ms: u32,
    /// The next tick's time; ticks are multiples of `period_ms`.
    next_ms: u64,

    pub fn init(period_ms: u32) Clock {
        assert(period_ms <= 1000);
        const clock: Clock = .{ .period_ms = period_ms, .next_ms = period_ms };
        assert(clock.next_ms == clock.period_ms);
        return clock;
    }

    /// Frame `n`'s time in milliseconds.
    pub fn frame_time_ms(n: u64) u64 {
        const t = n * 1000 / 60;
        assert(t <= n * 17);
        return t;
    }

    /// `ui.animate`'s delta for frame `n`.
    pub fn frame_dt(n: u64) f32 {
        return if (n == 0) 0 else frame_ms;
    }

    /// The time of the next tick due by `t_ms`, or null. While the timer is off, the ticks
    /// up to `t_ms` are skipped, so turning it on does not replay them.
    pub fn due(self: *Clock, t_ms: u64, on: bool) ?u64 {
        if (self.period_ms == 0) return null;
        assert(self.next_ms % self.period_ms == 0);
        if (!on) {
            if (self.next_ms <= t_ms) self.next_ms = (t_ms / self.period_ms + 1) * self.period_ms;
            assert(self.next_ms > t_ms);
            return null;
        }
        if (self.next_ms > t_ms) return null;
        const at = self.next_ms;
        self.next_ms += self.period_ms;
        return at;
    }
};

/// Which adapter the native host asks wgpu for.
pub const Adapter = enum(u8) {
    default,
    /// `power_preference = low_power`: an integrated GPU where there is one.
    low,
    /// `power_preference = high_performance`: a discrete GPU where there is one.
    high,
};

/// Native host options from the command line.
pub const Options = struct {
    /// `--bench` was given.
    bench: bool,
    /// The scenario to run; null with `bench` lists the scenarios.
    scenario: ?[]const u8,
    /// Overrides the scenario's `frames`.
    frames: ?u32,
    adapter: Adapter,
    /// Writes the last measured frame as a PPM.
    dump: ?[:0]const u8,
    /// Writes one CSV line per measured frame.
    csv: ?[:0]const u8,
    /// The renderer's pixel cache (`draw/renderer.zig`, section 4a); `--no-cache` turns it
    /// off to compare against.
    cache: bool,
    /// `--check`: compile the app's shaders and pipelines on a device with no window, report,
    /// and exit (`host/gpu_wgpu.zig`, section 10).
    check: bool,
    /// `--regress`: render every regressed scenario with no window, cache on and off, and
    /// compare with the golden files (`host/headless.zig`).
    regress: bool,
    /// `--adapter both`: regress on the high and the low adapter (the default for `--regress`).
    both: bool,
    /// `--bless`: rewrite the golden file from this run.
    bless: bool,
    /// `--only <scenario>`: regress that scenario alone.
    only: ?[]const u8,
    /// `--keep`: write every regressed frame as a PNG, passing or not.
    keep: bool,
    /// The program's file name without its directory, set by the native entry point: the
    /// golden file's name (`host/headless.zig`).
    program: []const u8,

    pub const off: Options = .{
        .bench = false,
        .scenario = null,
        .frames = null,
        .adapter = .default,
        .dump = null,
        .csv = null,
        .cache = true,
        .check = false,
        .regress = false,
        .both = false,
        .bless = false,
        .only = null,
        .keep = false,
        .program = "",
    };
};

pub const usage =
    \\usage: <app> [--adapter low|high] [--no-cache] [--check] [--bench [scenario]
    \\       [--frames N] [--dump out.ppm] [--csv out.csv]]
    \\       <app> --regress [--adapter high|low|both] [--bless] [--only scenario] [--keep]
    \\
;

pub const ParseError = error{ UnknownArgument, MissingValue, BadNumber, BadAdapter };

/// Parses the arguments after the program name. `--bench` takes an optional scenario name,
/// `--no-cache`, `--check`, `--regress`, `--bless`, and `--keep` take none, and every other
/// option takes one value. `--adapter both` is accepted only with `--regress`.
pub fn parse_args(args: []const [:0]const u8) ParseError!Options {
    assert(args.len <= arg_cap);
    var options: Options = .off;
    var index: u32 = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--bench")) {
            options.bench = true;
            if (index + 1 < args.len) {
                if (!std.mem.startsWith(u8, args[index + 1], "--")) {
                    index += 1;
                    options.scenario = args[index];
                }
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-cache")) {
            options.cache = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
            continue;
        }
        if (flag(arg)) |which| {
            switch (which) {
                .regress => options.regress = true,
                .bless => options.bless = true,
                .keep => options.keep = true,
            }
            continue;
        }
        if (index + 1 == args.len) {
            if (is_option(arg)) return error.MissingValue;
            return error.UnknownArgument;
        }
        const value = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, arg, "--frames")) {
            options.frames = std.fmt.parseInt(u32, value, 10) catch return error.BadNumber;
            if (options.frames.? == 0 or options.frames.? > sample_cap) return error.BadNumber;
        } else if (std.mem.eql(u8, arg, "--adapter")) {
            if (std.mem.eql(u8, value, "both")) {
                options.both = true;
                options.adapter = .default;
            } else {
                options.both = false;
                options.adapter = std.meta.stringToEnum(Adapter, value) orelse
                    return error.BadAdapter;
            }
        } else if (std.mem.eql(u8, arg, "--only")) {
            options.only = value;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            options.dump = value;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            options.csv = value;
        } else {
            return error.UnknownArgument;
        }
    }
    assert(index == args.len);
    if (options.both and !options.regress) return error.BadAdapter;
    return options;
}

const Flag = enum { regress, bless, keep };

fn flag(arg: []const u8) ?Flag {
    if (std.mem.eql(u8, arg, "--regress")) return .regress;
    if (std.mem.eql(u8, arg, "--bless")) return .bless;
    if (std.mem.eql(u8, arg, "--keep")) return .keep;
    return null;
}

fn is_option(arg: []const u8) bool {
    const names = [_][]const u8{ "--frames", "--adapter", "--dump", "--csv", "--only" };
    for (names) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// One presented frame of a run, times in nanoseconds.
pub const Sample = struct {
    /// `App.draw` with layout, through `ui.draw_frame`; 0 when nothing was owed.
    draw_ns: u64,
    /// Sorting the pools into batches.
    finalize_ns: u64,
    /// The record compare and the command stream.
    record_ns: u64,
    /// Replaying the stream, submit, and present (CPU).
    submit_ns: u64,
    /// The render pass on the GPU, from timestamps; null without the feature.
    gpu_ns: ?u64,
    instances: u32,
    /// Shaded area in windows: the sum of `rect` and `clip` intersections over the window.
    area_windows: f32,
    drew: bool,
    /// What the renderer recorded (`draw/renderer.zig`, section 4a).
    kind: renderer.Kind,
    /// The renderer folded the instances into tiles; false when it repeated the last frame's
    /// (`draw/renderer.zig`, section 4b).
    hashed: bool,
    /// Offscreen target passes the frame rendered (`draw/renderer.zig`, section 4c), and each
    /// one's GPU time in recording order (meaningful below `targets`, with timestamps).
    targets: u32 = 0,
    target_ns: [textures.target_cap]u64 = @splat(0),
};

pub const Summary = struct {
    min: u64,
    p10: u64,
    p50: u64,
    p90: u64,
    max: u64,
};

/// Sorts `values` in place and reads its percentiles (module guide, section 3).
pub fn summarize(values: []u64) Summary {
    assert(values.len >= 1);
    assert(values.len <= sample_cap);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const last: u32 = @intCast(values.len - 1);
    const summary: Summary = .{
        .min = values[0],
        .p10 = values[last * 10 / 100],
        .p50 = values[last * 50 / 100],
        .p90 = values[last * 90 / 100],
        .max = values[last],
    };
    assert(summary.min <= summary.p50);
    assert(summary.p50 <= summary.max);
    return summary;
}

/// Instances and shaded area of one draw type in one frame.
pub const TypeArea = struct {
    count: u32,
    /// Device pixels covered by `rect` intersected with `clip`.
    area_px: f64,
};

/// Fills `out[type id]` for every pool of the draw context `cx` (module guide, section 4).
/// Returns the instance total.
pub fn shaded_area(comptime Cx: type, cx: *const Cx, scale_120: u32, out: []TypeArea) u32 {
    const R = Cx.Registry;
    assert(out.len == R.count);
    assert(scale_120 >= 1);
    const scale: f64 = @as(f64, @floatFromInt(scale_120)) / 120.0;
    var total: u32 = 0;
    inline for (0..R.count) |index| {
        const items = cx.items(R.Type(index));
        var sum: f64 = 0;
        for (items) |*item| sum += clipped_area(item.rect, item.clip);
        out[index] = .{ .count = @intCast(items.len), .area_px = sum * scale * scale };
        total += @intCast(items.len);
    }
    assert(total <= std.math.maxInt(u32));
    return total;
}

/// The area of `rect` (x, y, width, height) inside `clip` (x0, y0, x1, y1), in logical px.
pub fn clipped_area(rect: [4]f32, clip: [4]f32) f64 {
    assert(rect[2] >= 0);
    assert(rect[3] >= 0);
    const x0 = @max(rect[0], clip[0]);
    const y0 = @max(rect[1], clip[1]);
    const x1 = @min(rect[0] + rect[2], clip[2]);
    const y1 = @min(rect[1] + rect[3], clip[3]);
    if (!(x1 > x0)) return 0;
    if (!(y1 > y0)) return 0;
    return @as(f64, x1 - x0) * @as(f64, y1 - y0);
}

/// Writes the PPM header for a `width` by `height` image into `buffer`.
pub fn ppm_header(buffer: []u8, width: u32, height: u32) []const u8 {
    assert(width >= 1);
    assert(height >= 1);
    const header = std.fmt.bufPrint(buffer, "P6\n{d} {d}\n255\n", .{ width, height }) catch
        unreachable;
    assert(header.len <= buffer.len);
    return header;
}

/// Converts one row of BGRA texels (the swapchain format) to RGB.
pub fn ppm_row(rgb: []u8, bgra: []const u8) void {
    assert(bgra.len % 4 == 0);
    assert(rgb.len == bgra.len / 4 * 3);
    const width = bgra.len / 4;
    assert(width <= width_max);
    for (0..width) |x| {
        rgb[x * 3 + 0] = bgra[x * 4 + 2];
        rgb[x * 3 + 1] = bgra[x * 4 + 1];
        rgb[x * 3 + 2] = bgra[x * 4 + 0];
    }
}

/// An RGB image whose pixels point into the parsed bytes.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const ImageError = error{ NotPpm, BadHeader, Truncated };

/// Parses a binary PPM with maxval 255 and no comments, as `ppm_header` writes it.
pub fn ppm_parse(bytes: []const u8) ImageError!Image {
    if (bytes.len < 2) return error.NotPpm;
    if (!std.mem.eql(u8, bytes[0..2], "P6")) return error.NotPpm;
    var cursor: u32 = 2;
    var fields: [3]u32 = undefined;
    for (&fields) |*field| {
        while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
        const start = cursor;
        while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
        if (cursor == start) return error.BadHeader;
        field.* = std.fmt.parseInt(u32, bytes[start..cursor], 10) catch return error.BadHeader;
    }
    if (fields[2] != 255) return error.BadHeader;
    if (fields[0] == 0 or fields[1] == 0) return error.BadHeader;
    if (cursor == bytes.len or !std.ascii.isWhitespace(bytes[cursor])) return error.BadHeader;
    cursor += 1;
    const size: u64 = @as(u64, fields[0]) * fields[1] * 3;
    if (bytes.len - cursor < size) return error.Truncated;
    const image: Image = .{
        .width = fields[0],
        .height = fields[1],
        .pixels = bytes[cursor..][0..@intCast(size)],
    };
    assert(image.pixels.len == size);
    return image;
}

/// How two images differ: per pixel, the maximum difference over its three channels.
pub const Diff = struct {
    pixels: u64,
    differing: u64,
    /// Pixels per maximum channel difference, 0 to 255.
    histogram: [256]u64,
    max: u8,
    /// Bounding box of the differing pixels, inclusive (x0, y0, x1, y1); unset when none.
    box: [4]u32,
};

/// Compares two images of the same size.
pub fn compare(a: Image, b: Image) error{SizeMismatch}!Diff {
    if (a.width != b.width or a.height != b.height) return error.SizeMismatch;
    assert(a.pixels.len == b.pixels.len);
    var diff: Diff = .{
        .pixels = @as(u64, a.width) * a.height,
        .differing = 0,
        .histogram = @splat(0),
        .max = 0,
        .box = .{ a.width, a.height, 0, 0 },
    };
    for (0..a.height) |y| {
        for (0..a.width) |x| {
            const at = (y * a.width + x) * 3;
            var most: u8 = 0;
            for (0..3) |channel| {
                const p = a.pixels[at + channel];
                const q = b.pixels[at + channel];
                most = @max(most, if (p > q) p - q else q - p);
            }
            diff.histogram[most] += 1;
            if (most == 0) continue;
            diff.differing += 1;
            diff.max = @max(diff.max, most);
            diff.box = .{
                @min(diff.box[0], @as(u32, @intCast(x))),
                @min(diff.box[1], @as(u32, @intCast(y))),
                @max(diff.box[2], @as(u32, @intCast(x))),
                @max(diff.box[3], @as(u32, @intCast(y))),
            };
        }
    }
    assert(diff.histogram[0] + diff.differing == diff.pixels);
    return diff;
}

/// Bytes `png_write` writes for a `width` by `height` image.
pub fn png_size(width: u32, height: u32) u64 {
    assert(width >= 1 and width <= width_max);
    assert(height >= 1);
    const raw = png_raw_len(width, height);
    const blocks = (raw + png_block_max - 1) / png_block_max;
    const zlib = 2 + blocks * 5 + raw + 4;
    return png_signature.len + (12 + 13) + (12 + zlib) + 12;
}

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
/// Most bytes one stored deflate block holds.
const png_block_max: u64 = 65535;

/// The filtered rows' length: a filter byte and `width` RGB pixels per row.
fn png_raw_len(width: u32, height: u32) u64 {
    return @as(u64, height) * (1 + @as(u64, width) * 3);
}

/// Writes `rgb` (`height` rows of `width` RGB pixels, top to bottom) as a PNG (section 5a).
pub fn png_write(
    writer: *std.Io.Writer,
    width: u32,
    height: u32,
    rgb: []const u8,
) std.Io.Writer.Error!void {
    assert(rgb.len == @as(u64, width) * height * 3);
    const raw_len = png_raw_len(width, height);
    const blocks = (raw_len + png_block_max - 1) / png_block_max;
    try writer.writeAll(&png_signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    // Bit depth 8, color type 2 (RGB), deflate, no filter method extension, no interlace.
    header[8..13].* = .{ 8, 2, 0, 0, 0 };
    try png_chunk(writer, "IHDR", &header);
    const zlib_len = 2 + blocks * 5 + raw_len + 4;
    var chunk: PngChunk = try .begin(writer, "IDAT", @intCast(zlib_len));
    // CMF 0x78 (deflate, 32 KiB window) and FLG 0x01 (no dictionary, check bits).
    try chunk.write(&.{ 0x78, 0x01 });
    var adler: std.hash.Adler32 = .{};
    var left: u64 = raw_len;
    var block_left: u64 = 0;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const pixels = rgb[@as(usize, row) * width * 3 ..][0 .. width * 3];
        const filter = [1]u8{0};
        for ([2][]const u8{ &filter, pixels }) |piece| {
            var at: usize = 0;
            while (at < piece.len) {
                if (block_left == 0) {
                    block_left = @min(left, png_block_max);
                    const len: u16 = @intCast(block_left);
                    var stored: [5]u8 = undefined;
                    stored[0] = @intFromBool(left == block_left);
                    std.mem.writeInt(u16, stored[1..3], len, .little);
                    std.mem.writeInt(u16, stored[3..5], ~len, .little);
                    try chunk.write(&stored);
                }
                const take: usize = @intCast(@min(block_left, piece.len - at));
                try chunk.write(piece[at..][0..take]);
                adler.update(piece[at..][0..take]);
                at += take;
                block_left -= take;
                left -= take;
            }
        }
    }
    assert(left == 0);
    var check: [4]u8 = undefined;
    std.mem.writeInt(u32, &check, adler.adler, .big);
    try chunk.write(&check);
    try chunk.end();
    try png_chunk(writer, "IEND", "");
}

/// One chunk being written: its CRC-32 covers the type and the data.
const PngChunk = struct {
    writer: *std.Io.Writer,
    crc: std.hash.Crc32,
    left: u32,

    fn begin(writer: *std.Io.Writer, kind: *const [4]u8, len: u32) !PngChunk {
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, len, .big);
        try writer.writeAll(&length);
        var chunk: PngChunk = .{ .writer = writer, .crc = .init(), .left = len + 4 };
        try chunk.write(kind);
        return chunk;
    }

    fn write(self: *PngChunk, bytes: []const u8) !void {
        assert(bytes.len <= self.left);
        self.crc.update(bytes);
        self.left -= @intCast(bytes.len);
        try self.writer.writeAll(bytes);
    }

    fn end(self: *PngChunk) !void {
        assert(self.left == 0);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, self.crc.final(), .big);
        try self.writer.writeAll(&crc);
    }
};

fn png_chunk(writer: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var chunk: PngChunk = try .begin(writer, kind, @intCast(data.len));
    try chunk.write(data);
    try chunk.end();
}

pub const PngError = error{ NotPng, Unsupported, Truncated, BadChecksum, TooLarge };

/// Reads a PNG in `png_write`'s form (section 5a) into `out`, which must hold its pixels.
/// Any other PNG (compressed blocks, another color type, filters) is `error.Unsupported`.
pub fn png_read_stored(bytes: []const u8, out: []u8) PngError!Image {
    const fixed = png_signature.len + 8 + 13 + 4 + 8;
    if (bytes.len < fixed) return error.NotPng;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return error.NotPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.NotPng;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (!std.mem.eql(u8, bytes[24..29], &.{ 8, 2, 0, 0, 0 })) return error.Unsupported;
    if (width == 0 or height == 0 or width > width_max) return error.Unsupported;
    const pixels: u64 = @as(u64, width) * height * 3;
    if (pixels > out.len) return error.TooLarge;
    const idat = 33;
    const zlib_len = std.mem.readInt(u32, bytes[idat..][0..4], .big);
    if (!std.mem.eql(u8, bytes[idat + 4 ..][0..4], "IDAT")) return error.Unsupported;
    if (bytes.len < idat + 8 + @as(u64, zlib_len) + 4) return error.Truncated;
    const zlib = bytes[idat + 8 ..][0..zlib_len];
    const crc = std.mem.readInt(u32, bytes[idat + 8 + zlib_len ..][0..4], .big);
    if (std.hash.Crc32.hash(bytes[idat + 4 ..][0 .. 4 + zlib_len]) != crc) {
        return error.BadChecksum;
    }
    if (zlib.len < 6 or zlib[0] != 0x78) return error.Unsupported;
    const raw_len = png_raw_len(width, height);
    var cursor: usize = 2;
    var raw_at: u64 = 0;
    var adler: std.hash.Adler32 = .{};
    var final = false;
    const blocks_max = raw_len / png_block_max + 1;
    var blocks: u64 = 0;
    while (!final) : (blocks += 1) {
        if (blocks == blocks_max) return error.Unsupported;
        if (zlib.len - cursor < 5) return error.Truncated;
        if (zlib[cursor] & 0xFE != 0) return error.Unsupported;
        final = zlib[cursor] == 1;
        const len = std.mem.readInt(u16, zlib[cursor + 1 ..][0..2], .little);
        const nlen = std.mem.readInt(u16, zlib[cursor + 3 ..][0..2], .little);
        if (nlen != ~len) return error.BadChecksum;
        cursor += 5;
        if (zlib.len - cursor < len or raw_at + len > raw_len) return error.Truncated;
        const data = zlib[cursor..][0..len];
        adler.update(data);
        for (data, 0..) |byte, offset| {
            const at = raw_at + offset;
            const row = at / (1 + @as(u64, width) * 3);
            const column = at % (1 + @as(u64, width) * 3);
            if (column == 0) {
                if (byte != 0) return error.Unsupported;
                continue;
            }
            out[@intCast(row * width * 3 + column - 1)] = byte;
        }
        raw_at += len;
        cursor += len;
    }
    if (raw_at != raw_len) return error.Truncated;
    if (zlib.len - cursor < 4) return error.Truncated;
    if (std.mem.readInt(u32, zlib[cursor..][0..4], .big) != adler.adler) return error.BadChecksum;
    const image: Image = .{ .width = width, .height = height, .pixels = out[0..@intCast(pixels)] };
    assert(image.pixels.len == pixels);
    return image;
}

/// Paints the diff of `old` and `new` (same size) into `out` (section 5a): equal pixels are
/// the new pixel's grey at a quarter level (at most 63), differing ones red from 64 (a
/// difference of 1) to 255 (a difference of 255), by the maximum channel difference.
pub fn diff_rgb(old: []const u8, new: []const u8, out: []u8) void {
    assert(old.len == new.len);
    assert(out.len == new.len);
    assert(new.len % 3 == 0);
    var at: usize = 0;
    while (at < new.len) : (at += 3) {
        var most: u32 = 0;
        for (0..3) |channel| {
            const p = old[at + channel];
            const q = new[at + channel];
            most = @max(most, if (p > q) p - q else q - p);
        }
        if (most == 0) {
            const luma = (@as(u32, new[at]) * 77 + @as(u32, new[at + 1]) * 150 +
                @as(u32, new[at + 2]) * 29) >> 8;
            const grey: u8 = @intCast(luma / 4);
            out[at..][0..3].* = .{ grey, grey, grey };
        } else {
            const red: u8 = @intCast(64 + most * 191 / 255);
            out[at..][0..3].* = .{ red, 0, 0 };
        }
    }
}

/// The regress golden value of an RGB frame (section 5a).
pub fn rgb_hash(rgb: []const u8) u64 {
    assert(rgb.len % 3 == 0);
    return std.hash.XxHash64.hash(0, rgb);
}

const testing = std.testing;
const draw = @import("draw.zig");

const test_scenario: Scenario = .{
    .name = "type",
    .setup = &.{ .{ .wait = 2 }, .{ .click = area("editor", 0) } },
    .cycle = &.{
        .{ .key = .{ .key = .x, .text = "x" } },
        .{ .key = .{ .key = .backspace, .text = "" } },
    },
    .frames = 3,
};

// Locks replay order: a wait holds for its frames, setup frames are not measured, the cycle
// repeats, and the run ends after `frames` measured frames.
test "replay runs setup once, cycles while measuring, and stops after frames" {
    var replay: Replay = .init();
    const s = &test_scenario;
    try testing.expectEqual(Step{ .wait = 2 }, replay.next(s).?);
    try testing.expect(!replay.presented(s));
    try testing.expectEqual(Step{ .wait = 2 }, replay.next(s).?);
    try testing.expect(!replay.presented(s));
    try testing.expectEqual(areas.id("editor", 0), step_target(replay.next(s).?).?.id);
    try testing.expect(!replay.presented(s));
    try testing.expectEqual(input.Key.x, replay.next(s).?.key.key);
    try testing.expect(replay.presented(s));
    try testing.expectEqual(input.Key.backspace, replay.next(s).?.key.key);
    try testing.expect(replay.presented(s));
    try testing.expectEqual(input.Key.x, replay.next(s).?.key.key);
    try testing.expect(replay.presented(s));
    try testing.expectEqual(Replay.Phase.done, replay.phase);
    try testing.expectEqual(@as(?Step, null), replay.next(s));
    try testing.expect(!replay.presented(s));
}

// Locks the empty-cycle case: after the setup, frames the app presents are measured and no
// step is returned.
test "an empty cycle measures the app's own frames" {
    const s: Scenario = .{
        .name = "timer",
        .setup = &.{.{ .wait = 1 }},
        .cycle = &.{},
        .frames = 2,
    };
    var replay: Replay = .init();
    try testing.expectEqual(Step{ .wait = 1 }, replay.next(&s).?);
    try testing.expect(!replay.presented(&s));
    try testing.expectEqual(@as(?Step, null), replay.next(&s));
    try testing.expectEqual(Replay.Phase.measure, replay.phase);
    try testing.expect(replay.presented(&s));
    try testing.expect(replay.presented(&s));
    try testing.expectEqual(Replay.Phase.done, replay.phase);
}

// Locks the events a step dispatches: a click at the centre leaves the window afterwards, a
// key carries its text, and a wait dispatches nothing.
test "steps become events" {
    var out: [event_cap]input.Event = undefined;
    const rect: [4]f32 = .{ 10, 20, 40, 30 };
    try testing.expectEqual(@as(u32, 4), step_events(.{ .click = area("a", 0) }, rect, 7, &out));
    try testing.expectEqual(@as(f32, 30), out[1].pointer_down.x);
    try testing.expectEqual(@as(f32, 35), out[1].pointer_down.y);
    try testing.expectEqual(@as(u32, 7), out[1].pointer_down.time_ms);
    try testing.expect(out[3] == .pointer_leave);
    const at: Step = .{ .click_at = .{ .target = area("a", 0), .x = 2, .y = 3 } };
    _ = step_events(at, rect, 0, &out);
    try testing.expectEqual(@as(f32, 12), out[2].pointer_up.x);
    try testing.expectEqual(@as(u32, 2), step_events(test_scenario.cycle[0], null, 0, &out));
    try testing.expectEqualStrings("x", out[0].key_down.typed());
    try testing.expectEqual(@as(u32, 0), step_events(.{ .wait = 3 }, null, 0, &out));
}

// Locks the pointer steps: a hover is one move to the point from the target's top-left with no
// leave; a drag is move, press, move by (dx, dy), and release there, with no leave.
test "hover and drag steps dispatch exactly their events" {
    var out: [event_cap]input.Event = undefined;
    const rect: [4]f32 = .{ 10, 20, 40, 30 };
    const hover: Step = .{ .hover = .{ .target = area("a", 0), .x = 5, .y = 6 } };
    try testing.expectEqual(@as(u32, 1), step_events(hover, rect, 0, &out));
    try testing.expectEqual(input.Point{ .x = 15, .y = 26 }, out[0].pointer_move);
    try testing.expectEqual(areas.id("a", 0), step_target(hover).?.id);
    const drag: Step = .{ .drag = .{
        .target = area("a", 1),
        .from_x = 4,
        .from_y = 15,
        .dx = 80,
        .dy = -30,
    } };
    try testing.expectEqual(@as(u32, 4), step_events(drag, rect, 9, &out));
    try testing.expectEqual(input.Point{ .x = 14, .y = 35 }, out[0].pointer_move);
    try testing.expectEqual(@as(f32, 14), out[1].pointer_down.x);
    try testing.expectEqual(@as(f32, 35), out[1].pointer_down.y);
    try testing.expectEqual(@as(u32, 9), out[1].pointer_down.time_ms);
    try testing.expectEqual(input.Point{ .x = 94, .y = 5 }, out[2].pointer_move);
    try testing.expectEqual(@as(f32, 94), out[3].pointer_up.x);
    try testing.expectEqual(@as(f32, 5), out[3].pointer_up.y);
    try testing.expectEqual(input.MouseButton.left, out[3].pointer_up.button);
    try testing.expectEqual(areas.id("a", 1), step_target(drag).?.id);
}

// Locks the right click: move to the point from the target's top-left (10 + 5, 20 + 6), press
// and release the right button there, then leave, like a click.
test "a right click presses the right button at its point" {
    var out: [event_cap]input.Event = undefined;
    const rect: [4]f32 = .{ 10, 20, 40, 30 };
    const right: Step = .{ .right_click = .{ .target = area("a", 2), .x = 5, .y = 6 } };
    try testing.expectEqual(@as(u32, 4), step_events(right, rect, 3, &out));
    try testing.expectEqual(input.Point{ .x = 15, .y = 26 }, out[0].pointer_move);
    try testing.expectEqual(input.MouseButton.right, out[1].pointer_down.button);
    try testing.expectEqual(@as(f32, 15), out[1].pointer_down.x);
    try testing.expectEqual(input.MouseButton.right, out[2].pointer_up.button);
    try testing.expect(out[3] == .pointer_leave);
    try testing.expectEqual(areas.id("a", 2), step_target(right).?.id);
}

// Locks validation in both spaces: a good list passes, and each rule names the scenario.
test "scenario validation rejects bad lists by name" {
    try testing.expectEqual(@as(?[]const u8, null), comptime validate(&.{test_scenario}));
    const no_frames: Scenario = .{ .name = "z", .setup = &.{}, .cycle = &.{}, .frames = 0 };
    try testing.expect(std.mem.find(u8, comptime validate(&.{no_frames}).?, "z") != null);
    const long_key: Scenario = .{
        .name = "k",
        .setup = &.{.{ .key = .{ .key = .a, .text = "abcde" } }},
        .cycle = &.{},
        .frames = 1,
    };
    try testing.expect(std.mem.find(u8, comptime validate(&.{long_key}).?, "4 bytes") != null);
    const target = comptime area("a", 0);
    const nowhere: Drag = .{ .target = target, .from_x = 1, .from_y = 1, .dx = 0, .dy = 0 };
    const still: Scenario = .{
        .name = "still-drag",
        .setup = &.{.{ .drag = nowhere }},
        .cycle = &.{},
        .frames = 1,
    };
    const refused = comptime validate(&.{still}).?;
    try testing.expectEqualStrings("App.scenarios.still-drag: a drag moves by 0", refused);
    const twice = comptime validate(&.{ test_scenario, test_scenario }).?;
    try testing.expect(std.mem.find(u8, twice, "duplicate") != null);
    try testing.expect(find(&.{test_scenario}, "type") != null);
    try testing.expect(find(&.{test_scenario}, "none") == null);
}

// Locks the command line: values, the optional scenario after `--bench`, the `--check` flag
// beside `--adapter`, and each error.
test "arguments parse into options and reject mistakes" {
    const full = try parse_args(&.{ "--adapter", "low", "--bench", "typing", "--frames", "50" });
    try testing.expect(full.bench);
    try testing.expectEqualStrings("typing", full.scenario.?);
    try testing.expectEqual(@as(?u32, 50), full.frames);
    try testing.expectEqual(Adapter.low, full.adapter);
    const list = try parse_args(&.{ "--bench", "--dump", "a.ppm" });
    try testing.expect(list.bench);
    try testing.expectEqual(@as(?[]const u8, null), list.scenario);
    try testing.expectEqualStrings("a.ppm", list.dump.?);
    try testing.expect(!(try parse_args(&.{})).bench);
    try testing.expect((try parse_args(&.{})).cache);
    try testing.expect(!(try parse_args(&.{"--no-cache"})).cache);
    try testing.expect(!(try parse_args(&.{})).check);
    const check = try parse_args(&.{ "--check", "--adapter", "high" });
    try testing.expect(check.check);
    try testing.expect(!check.bench);
    try testing.expectEqual(Adapter.high, check.adapter);
    try testing.expectError(error.MissingValue, parse_args(&.{"--frames"}));
    try testing.expectError(error.BadNumber, parse_args(&.{ "--frames", "0" }));
    try testing.expectError(error.BadAdapter, parse_args(&.{ "--adapter", "fast" }));
    try testing.expectError(error.UnknownArgument, parse_args(&.{"stray"}));
}

// Locks the percentile rule `sorted[(count - 1) * q / 100]` on eleven values.
test "summaries read percentiles by index" {
    var values = [_]u64{ 100, 0, 90, 10, 80, 20, 70, 30, 60, 40, 50 };
    const summary = summarize(&values);
    try testing.expectEqual(@as(u64, 0), summary.min);
    try testing.expectEqual(@as(u64, 10), summary.p10);
    try testing.expectEqual(@as(u64, 50), summary.p50);
    try testing.expectEqual(@as(u64, 90), summary.p90);
    try testing.expectEqual(@as(u64, 100), summary.max);
}

const area_draw = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 4 },
    .{ .type = draw.Glyph, .cap = 4 },
};
const AreaContext = draw.Context(&area_draw, 4, 0);

// Locks the shaded-area counter: clipped boxes count their visible part, scaled by the square
// of the display scale, and a fully clipped box counts as an instance with no area.
test "shaded area sums clipped rects in device pixels" {
    const static = struct {
        var context: AreaContext = undefined;
    };
    const cx = &static.context;
    cx.init();
    const window: draw.Clip = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const square: draw.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    var box: draw.Box = .of(square, window, .{ .fill = .{ 1, 1, 1, 1 } });
    try cx.append(draw.Box, null, box);
    box.rect = .{ 95, 0, 10, 10 };
    try cx.append(draw.Box, null, box);
    box.rect = .{ 200, 0, 10, 10 };
    try cx.append(draw.Box, null, box);
    var out: [2]TypeArea = undefined;
    try testing.expectEqual(@as(u32, 3), shaded_area(AreaContext, cx, 240, &out));
    try testing.expectEqual(@as(u32, 3), out[0].count);
    try testing.expectEqual(@as(f64, 600), out[0].area_px);
    try testing.expectEqual(@as(u32, 0), out[1].count);
}

// Locks the image round trip and the comparison: a written image parses back, an identical
// image differs nowhere, and one changed channel is counted with its box.
test "ppm images round trip and compare" {
    var bytes: [64]u8 = undefined;
    const header = ppm_header(&bytes, 2, 2);
    const bgra = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    ppm_row(bytes[header.len..][0..6], &bgra);
    ppm_row(bytes[header.len + 6 ..][0..6], &bgra);
    const total = header.len + 12;
    const a = try ppm_parse(bytes[0..total]);
    try testing.expectEqual(@as(u32, 2), a.width);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 6, 5, 4 }, a.pixels[0..6]);
    try testing.expectEqual(@as(u64, 0), (try compare(a, a)).differing);
    var changed = bytes;
    changed[header.len + 9] +%= 9;
    const diff = try compare(a, try ppm_parse(changed[0..total]));
    try testing.expectEqual(@as(u64, 1), diff.differing);
    try testing.expectEqual(@as(u8, 9), diff.max);
    try testing.expectEqual([4]u32{ 1, 1, 1, 1 }, diff.box);
    try testing.expectError(error.Truncated, ppm_parse(bytes[0 .. total - 1]));
    try testing.expectError(error.NotPpm, ppm_parse("P3"));
}

const test_rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30, 40, 50, 60, 70, 80, 90 };

// Locks the PNG layout of a 3 x 2 image: signature, IHDR (CRC 0x1216F14D), one IDAT of 31
// bytes (zlib header 78 01, one final stored block of 20 bytes, Adler-32 0x335904C0, CRC
// 0xC5321E86), and IEND (CRC 0xAE426082); 88 bytes in all, which `png_size` predicts, and the
// file reads back to the same pixels. Values from Python's zlib.
test "png writes stored blocks with the known checksums and reads back" {
    var bytes: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try png_write(&writer, 3, 2, &test_rgb);
    const png = writer.buffered();
    try testing.expectEqual(png_size(3, 2), png.len);
    try testing.expectEqual(@as(usize, 88), png.len);
    try testing.expectEqualSlices(u8, &png_signature, png[0..8]);
    try testing.expectEqual(@as(u32, 0x1216F14D), std.mem.readInt(u32, png[29..33], .big));
    try testing.expectEqual(@as(u32, 31), std.mem.readInt(u32, png[33..37], .big));
    try testing.expectEqualStrings("IDAT", png[37..41]);
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x01, 0x01, 20, 0, 0xEB, 0xFF }, png[41..48]);
    try testing.expectEqual(@as(u32, 0x335904C0), std.mem.readInt(u32, png[68..72], .big));
    try testing.expectEqual(@as(u32, 0xC5321E86), std.mem.readInt(u32, png[72..76], .big));
    try testing.expectEqual(@as(u32, 0xAE426082), std.mem.readInt(u32, png[84..88], .big));
    var pixels: [18]u8 = undefined;
    const image = try png_read_stored(png, &pixels);
    try testing.expectEqual(@as(u32, 3), image.width);
    try testing.expectEqualSlices(u8, &test_rgb, image.pixels);
    var broken = bytes;
    broken[50] +%= 1;
    try testing.expectError(error.BadChecksum, png_read_stored(broken[0..png.len], &pixels));
}

// Locks block splitting: 200 x 120 RGB is 72,120 filtered bytes, two stored blocks (65,535
// and 6,585), and the image reads back.
test "png splits rows across stored blocks" {
    const static = struct {
        var rgb: [200 * 120 * 3]u8 = undefined;
        var file: [80_000]u8 = undefined;
        var back: [200 * 120 * 3]u8 = undefined;
    };
    for (&static.rgb, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var writer: std.Io.Writer = .fixed(&static.file);
    try png_write(&writer, 200, 120, &static.rgb);
    try testing.expectEqual(png_size(200, 120), writer.buffered().len);
    try testing.expectEqual(@as(u64, 72_120), png_raw_len(200, 120));
    const image = try png_read_stored(writer.buffered(), &static.back);
    try testing.expectEqualSlices(u8, &static.rgb, image.pixels);
}

// Locks the diff colors: an equal white pixel is grey 63, an equal black one 0, a difference
// of 1 is red 64, and one of 255 is red 255.
test "diff pixels are dimmed grey where equal and red by difference" {
    const old = [_]u8{ 255, 255, 255, 0, 0, 0, 10, 10, 10, 0, 0, 0 };
    const new = [_]u8{ 255, 255, 255, 0, 0, 0, 10, 11, 10, 0, 255, 0 };
    var out: [12]u8 = undefined;
    diff_rgb(&old, &new, &out);
    try testing.expectEqualSlices(u8, &.{ 63, 63, 63, 0, 0, 0, 64, 0, 0, 255, 0, 0 }, &out);
}

// Locks the golden hash: XxHash64 seed 0 of the 3 x 2 test image is 0xdedd90bdfe13ccbd, and
// of nothing 0xef46db3751d8e999 (the reference value); both from an independent
// implementation of the algorithm.
test "frames hash with xxhash64 seed 0" {
    try testing.expectEqual(@as(u64, 0xdedd90bdfe13ccbd), rgb_hash(&test_rgb));
    try testing.expectEqual(@as(u64, 0xef46db3751d8e999), rgb_hash(""));
}

// Locks the regress flags: `--regress` alone, then with `--bless`, `--only`, `--keep`, and
// `--adapter both`, which is refused without `--regress`; and `Scenario.regress` defaults on.
test "regress arguments parse" {
    const plain = try parse_args(&.{"--regress"});
    try testing.expect(plain.regress);
    try testing.expect(!plain.bless and !plain.keep and !plain.both);
    try testing.expectEqual(@as(?[]const u8, null), plain.only);
    const all = [_][:0]const u8{
        "--regress", "--bless", "--only", "still", "--keep", "--adapter", "both",
    };
    const full = try parse_args(&all);
    try testing.expect(full.bless and full.keep and full.both);
    try testing.expectEqualStrings("still", full.only.?);
    try testing.expectEqual(Adapter.default, full.adapter);
    const low = try parse_args(&.{ "--regress", "--adapter", "low" });
    try testing.expectEqual(Adapter.low, low.adapter);
    try testing.expect(!low.both);
    try testing.expectError(error.BadAdapter, parse_args(&.{ "--adapter", "both" }));
    try testing.expectError(error.MissingValue, parse_args(&.{ "--regress", "--only" }));
    try testing.expect(test_scenario.regress);
}

// Locks the simulated clock over 20 frames: frame times 0, 16, 33, ... 316 ms; a 33 ms timer
// ticks at 33, 66, ... 297 on frames 2, 4, ... 18 (one each); a 125 ms timer at 125 (frame 8)
// and 250 (frame 15); ticks while off are skipped; and the audio blocks fed per frame are
// `realtime.blocks_for_frame`, 375 over the first 60 frames (one second at 48 kHz).
test "the simulated clock fires timers at multiples of their period" {
    try testing.expectEqual(@as(u64, 16), Clock.frame_time_ms(1));
    try testing.expectEqual(@as(u64, 316), Clock.frame_time_ms(19));
    try testing.expectEqual(@as(f32, 0), Clock.frame_dt(0));
    try testing.expectEqual(frame_ms, Clock.frame_dt(5));
    var fast: Clock = .init(33);
    var slow: Clock = .init(125);
    var fast_ticks: [20]u64 = @splat(0);
    var fast_frames: [20]u64 = @splat(0);
    var fast_count: u32 = 0;
    var slow_frames: [2]u64 = @splat(0);
    var slow_count: u32 = 0;
    for (0..20) |n| {
        const t = Clock.frame_time_ms(n);
        while (fast.due(t, true)) |at| {
            fast_ticks[fast_count] = at;
            fast_frames[fast_count] = n;
            fast_count += 1;
        }
        while (slow.due(t, true)) |_| {
            slow_frames[slow_count] = n;
            slow_count += 1;
        }
    }
    try testing.expectEqual(@as(u32, 9), fast_count);
    const times = [_]u64{ 33, 66, 99, 132, 165, 198, 231, 264, 297 };
    try testing.expectEqualSlices(u64, &times, fast_ticks[0..9]);
    try testing.expectEqualSlices(u64, &.{ 2, 4, 6, 8, 10, 12, 14, 16, 18 }, fast_frames[0..9]);
    try testing.expectEqual(@as(u32, 2), slow_count);
    try testing.expectEqualSlices(u64, &.{ 8, 15 }, &slow_frames);
    var paused: Clock = .init(33);
    try testing.expectEqual(@as(?u64, null), paused.due(100, false));
    try testing.expectEqual(@as(?u64, null), paused.due(130, true));
    try testing.expectEqual(@as(?u64, 132), paused.due(133, true));
    var none: Clock = .init(0);
    try testing.expectEqual(@as(?u64, null), none.due(1000, true));
    var blocks: u32 = 0;
    for (0..60) |n| blocks += realtime.blocks_for_frame(n);
    try testing.expectEqual(realtime.sample_rate / realtime.block_frames, blocks);
}

comptime {
    assert(event_cap == 4);
    assert(ticks_per_frame_max >= 17);
    assert(sample_cap <= 1 << 16);
    assert(steps_max <= 1 << 16);
}

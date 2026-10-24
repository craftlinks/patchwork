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
//! only when a scenario runs. Without `--bench` nothing here executes.
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
//! name.
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

/// Most steps in one `setup` or `cycle` list.
pub const steps_max: u32 = 256;

/// Most scenarios one app declares.
pub const scenario_cap: u32 = 32;

/// Most frames one run measures; the host's sample storage.
pub const sample_cap: u32 = 4096;

/// Most command-line arguments the native host reads.
pub const arg_cap: u32 = 16;

/// Most events one step dispatches: move, press, release, leave.
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

/// One scripted action. Each step presents one frame (module guide, section 2).
pub const Step = union(enum) {
    key: Press,
    /// A left click at the target's centre, then the pointer leaves the window.
    click: Target,
    click_at: At,
    wheel: Turn,
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
            .click, .click_at, .wheel => {},
        }
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
        .click, .click_at => {
            const r = rect.?;
            const offset: [2]f32 = switch (step) {
                .click => .{ r[2] / 2, r[3] / 2 },
                .click_at => |at| .{ at.x, at.y },
                else => unreachable,
            };
            const x = r[0] + offset[0];
            const y = r[1] + offset[1];
            const button: input.Button = .{
                .x = x,
                .y = y,
                .time_ms = time_ms,
                .button = .left,
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
    }
}

/// The target a step addresses, or null for `key` and `wait`.
pub fn step_target(step: Step) ?Target {
    return switch (step) {
        .click => |target| target,
        .click_at => |at| at.target,
        .wheel => |turn| turn.target,
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

    pub const off: Options = .{
        .bench = false,
        .scenario = null,
        .frames = null,
        .adapter = .default,
        .dump = null,
        .csv = null,
        .cache = true,
    };
};

pub const usage =
    \\usage: <app> [--adapter low|high] [--no-cache] [--bench [scenario] [--frames N]
    \\       [--dump out.ppm] [--csv out.csv]]
    \\
;

pub const ParseError = error{ UnknownArgument, MissingValue, BadNumber, BadAdapter };

/// Parses the arguments after the program name. `--bench` takes an optional scenario name;
/// every other option takes one value.
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
            options.adapter = std.meta.stringToEnum(Adapter, value) orelse return error.BadAdapter;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            options.dump = value;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            options.csv = value;
        } else {
            return error.UnknownArgument;
        }
    }
    assert(index == args.len);
    return options;
}

fn is_option(arg: []const u8) bool {
    const names = [_][]const u8{ "--frames", "--adapter", "--dump", "--csv" };
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
    const twice = comptime validate(&.{ test_scenario, test_scenario }).?;
    try testing.expect(std.mem.find(u8, twice, "duplicate") != null);
    try testing.expect(find(&.{test_scenario}, "type") != null);
    try testing.expect(find(&.{test_scenario}, "none") == null);
}

// Locks the command line: values, the optional scenario after `--bench`, and each error.
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
    var box: draw.Box = .{
        .rect = .{ 0, 0, 10, 10 },
        .clip = .{ 0, 0, 100, 100 },
        .fill = .{ 1, 1, 1, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    };
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

comptime {
    assert(event_cap == 4);
    assert(sample_cap <= 1 << 16);
    assert(steps_max <= 1 << 16);
}

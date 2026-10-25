//! Headless regression host: every scenario of an app rendered with no window, hashed, and
//! compared with committed golden files.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Second Native Host
//! The windowed bench (`linux_window.zig`, section 5b) answers performance and presentation
//! questions, but a regression question ("did any picture change?") needs none of that: no
//! Wayland connection, no vsync, no wall clock. `run` is entered from `native_main.zig` with
//! `--regress`, before any display is touched, and renders each regressed scenario
//! (`bench.Scenario.regress`) of the app in this one process:
//! ```text
//! for adapter in (high, low):            gpu_wgpu.create_headless + headless_target_create
//!   read test/golden/<adapter slug>/<app>.txt; refuse a golden blessed on another driver
//!   for scenario, for cache in (on, off):
//!     fresh app, UI context, renderer, GPU tables      (section 3)
//!     frames on the simulated clock                    (section 2)
//!     read the target back, hash the RGB rows          (bench.rgb_hash)
//!   compare: cache on == cache off; hash == golden line (or bless it)
//! one report, one write; exit 0 only when every line is the same and ok
//! ```
//! Nothing in the renderer knows it is headless: the device's target texture stands in for
//! the swapchain (`gpu_wgpu.zig`, section 10a).
//!
//! ## 2. The Simulated Clock
//! Frame `n` is at `t_n = n * 1000 / 60` ms (integer division, the windowed bench's
//! `bench_time`). Before frame `n` draws, in this order:
//! 1. the scenario step of this frame (`bench.Replay`, `bench.step_events`), its presses
//!    stamped `t_n`, through `ui.dispatch`;
//! 2. every app timer tick due by `t_n` (`bench.Clock.due`, shared with the browser
//!    replay): with period `p`, a tick at every multiple of `p` up to `t_n`, oldest first,
//!    while `cx.timer_on`, each one `App.timer` call with the tick's own time; ticks that
//!    fall while the timer is off are skipped;
//! 3. `ui.animate` with `dt = 1000 / 60` ms (0 for frame 0, as the first sample after idle);
//! 4. while `cx.audio_on`, `realtime.blocks_for_frame(k)` blocks rendered on this thread and
//!    drained through `App.audio`, `k` counting the frames fed so far, exactly as the
//!    windowed bench does (`linux_window.zig`, section 5c);
//! 5. `ui.draw_frame` and `Renderer.frame` with `time_s` of `t_n`, then `gpu_wgpu.execute`.
//! Every frame is drawn: there is no vsync to wait for, and the renderer's own skip and
//! cache logic runs as in a window. A scenario runs frame 0 (the first draw), then one frame
//! per step until `frames` are measured; an empty cycle draws clock frames.
//!
//! ## 3. Fresh State per Run
//! The app, the UI context, the renderer, the audio engine, and the command buffer are
//! static (their sizes follow `App.config`), and every (scenario, cache) run initializes
//! them in place as the windowed host's `run` does. The device is kept per adapter and its
//! tables are emptied with `gpu_wgpu.reset` before the setup stream is replayed again, which
//! costs far less than a new device (measured on the step page). App state that `App.init`
//! does not reset would leak from one scenario into the next and show as a difference
//! between a full run and `--only`; the fix belongs in the app.
//!
//! ## 4. Golden Files
//! `test/golden/<adapter slug>/<app>.txt`, one per app so parallel apps never write the same
//! file (`Golden`). The header names the adapter, its driver, and the size; then one line per
//! scenario, sorted by name, with the hash as 16 lowercase hex digits; no timestamps, so
//! blessing an unchanged tree rewrites the same bytes. A golden whose adapter or driver
//! differs from the device's is refused before anything renders, unless `--bless`.
//! A scenario with no line is `new`, which fails unless `--bless`. `--bless` rewrites the
//! file from this run, keeping the lines of scenarios it did not run (`--only`), and only
//! when cache on and off agreed for every scenario it ran.
//!
//! ## 5. Pictures and the Report
//! A passing run writes nothing. A failing one writes the frame as
//! `zig-out/regress/<app>/<scenario>-<adapter>-<cache>.new.png`, and a diff PNG
//! (`bench.diff_rgb`) against the cache-on frame for an on/off mismatch, or against the
//! baseline `<scenario>-<adapter>-<cache>.png` when that file exists and its pixels hash to
//! the golden line (a `--keep` run on a passing tree writes baselines). `--keep` writes
//! every frame as a baseline. The report is formatted into one buffer and written once, so
//! parallel app runs do not interleave; the exit code is 0 only when every row passed.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation: frames, PNG bytes, the golden file, and the report live in static buffers
//!   sized by the app's regress size (`bench.regress_size`).
//! - Bounded loops: frames by the scenario's setup and `frames`, timer ticks per frame by
//!   `bench.ticks_per_frame_max`, golden lines by `bench.scenario_cap`, paths by `path_cap`.

const std = @import("std");
const assert = std.debug.assert;
const animator = @import("../animator.zig");
const app_contract = @import("../app.zig");
const bench = @import("../bench.zig");
const commands = @import("../gpu/commands.zig");
const gpu_wgpu = @import("gpu_wgpu.zig");
const input = @import("../input.zig");
const realtime = @import("../realtime.zig");
const renderer = @import("../draw/renderer.zig");
const ui = @import("../ui.zig");
const audio_thread = @import("audio_thread.zig");

/// The display scale regress renders at, in 1/120 units.
pub const scale_120: u32 = 120;

const Clock = bench.Clock;

/// Longest path this host builds.
const path_cap: u32 = 512;

/// Bytes of the golden file read or written for one app.
pub const golden_bytes_max: u32 = 8192;

/// Bytes of the report one app prints.
const report_cap: u32 = 16384;

/// The adapters `--regress` visits, in report order.
const Visit = enum { high, low };

/// One app's golden file (section 4). Text slices point into the parsed bytes or into
/// static scenario names.
pub const Golden = struct {
    adapter: []const u8,
    driver: []const u8,
    size: [2]u32,
    names: [bench.scenario_cap][]const u8,
    hashes: [bench.scenario_cap]u64,
    count: u32,

    pub const version_line = "# patchwork regress golden v1";

    pub const ParseError = error{BadGolden};

    pub fn empty(adapter: []const u8, driver: []const u8, size: [2]u32) Golden {
        const golden: Golden = .{
            .adapter = adapter,
            .driver = driver,
            .size = size,
            .names = undefined,
            .hashes = undefined,
            .count = 0,
        };
        assert(golden.count == 0);
        return golden;
    }

    /// Parses a file `format` wrote. Lines need not be sorted; a duplicate name is refused.
    pub fn parse(bytes: []const u8) ParseError!Golden {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", version_line)) return error.BadGolden;
        const adapter = header_value(lines.next(), "# adapter: ") orelse return error.BadGolden;
        const driver = header_value(lines.next(), "# driver: ") orelse return error.BadGolden;
        const size_text = header_value(lines.next(), "# size: ") orelse return error.BadGolden;
        var golden: Golden = .empty(adapter, driver, parse_size(size_text) orelse
            return error.BadGolden);
        const columns = lines.next() orelse return error.BadGolden;
        if (!std.mem.startsWith(u8, columns, "scenario ")) return error.BadGolden;
        var guard: u32 = 0;
        while (lines.next()) |line| : (guard += 1) {
            if (guard > bench.scenario_cap) return error.BadGolden;
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const name = fields.next() orelse return error.BadGolden;
            const hex = fields.next() orelse return error.BadGolden;
            if (fields.next() != null or hex.len != 16) return error.BadGolden;
            const hash = std.fmt.parseInt(u64, hex, 16) catch return error.BadGolden;
            if (golden.find(name) != null) return error.BadGolden;
            if (golden.count == bench.scenario_cap) return error.BadGolden;
            golden.set(name, hash);
        }
        assert(golden.count <= bench.scenario_cap);
        return golden;
    }

    /// The hash blessed for `name`, or null when it has no line (`new`).
    pub fn find(self: *const Golden, name: []const u8) ?u64 {
        assert(self.count <= bench.scenario_cap);
        for (self.names[0..self.count], self.hashes[0..self.count]) |known, hash| {
            if (std.mem.eql(u8, known, name)) return hash;
        }
        return null;
    }

    /// Sets `name`'s line, adding it when new.
    pub fn set(self: *Golden, name: []const u8, hash: u64) void {
        assert(name.len != 0);
        for (self.names[0..self.count], 0..) |known, index| {
            if (std.mem.eql(u8, known, name)) {
                self.hashes[index] = hash;
                return;
            }
        }
        assert(self.count < bench.scenario_cap);
        self.names[self.count] = name;
        self.hashes[self.count] = hash;
        self.count += 1;
    }

    /// Writes the file into `out`: the header, then one line per scenario sorted by name.
    pub fn format(self: *const Golden, out: []u8) error{NoSpaceLeft}![]const u8 {
        var order: [bench.scenario_cap]u8 = undefined;
        for (0..self.count) |index| order[index] = @intCast(index);
        // Insertion sort over at most `scenario_cap` lines.
        for (1..self.count) |index| {
            var at = index;
            while (at > 0 and name_before(self.names[order[at]], self.names[order[at - 1]])) {
                std.mem.swap(u8, &order[at], &order[at - 1]);
                at -= 1;
            }
        }
        var width: usize = "scenario".len;
        for (self.names[0..self.count]) |name| width = @max(width, name.len);
        var writer: std.Io.Writer = .fixed(out);
        writer.print("{s}\n# adapter: {s}\n# driver: {s}\n# size: {d}x{d} @{d}\n", .{
            version_line, self.adapter, self.driver, self.size[0], self.size[1], scale_120,
        }) catch return error.NoSpaceLeft;
        pad_print(&writer, "scenario", width + 2) catch return error.NoSpaceLeft;
        writer.writeAll("hash\n") catch return error.NoSpaceLeft;
        for (order[0..self.count]) |index| {
            pad_print(&writer, self.names[index], width + 2) catch return error.NoSpaceLeft;
            writer.print("{x:0>16}\n", .{self.hashes[index]}) catch return error.NoSpaceLeft;
        }
        return writer.buffered();
    }

    /// True when this golden was blessed on another adapter or driver than the device's.
    pub fn other_device(self: *const Golden, adapter: []const u8, driver: []const u8) bool {
        if (!std.mem.eql(u8, self.adapter, adapter)) return true;
        return !std.mem.eql(u8, self.driver, driver);
    }
};

fn header_value(line: ?[]const u8, prefix: []const u8) ?[]const u8 {
    const text = line orelse return null;
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

/// `1280x720 @120` -> the size; the scale must be `scale_120`.
fn parse_size(text: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    if (space < x) return null;
    if (!std.mem.eql(u8, text[space..], " @120")) return null;
    const width = std.fmt.parseInt(u32, text[0..x], 10) catch return null;
    const height = std.fmt.parseInt(u32, text[x + 1 .. space], 10) catch return null;
    return .{ width, height };
}

fn name_before(a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn pad_print(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    try writer.splatByteAll(' ', width -| text.len);
}

/// The refusal for a golden blessed on another device (section 4), into `out`.
pub fn refusal(
    out: []u8,
    app: []const u8,
    golden: *const Golden,
    adapter: []const u8,
    driver: []const u8,
) []const u8 {
    return std.fmt.bufPrint(out, "golden for {s} was blessed on driver \"{s} / {s}\"; this " ++
        "device reports \"{s} / {s}\". Re-bless from master (see the Agent brief)", .{
        app, golden.adapter, golden.driver, adapter, driver,
    }) catch out[0..0];
}

/// The golden directory's name for an adapter: lowercased, every run of other characters
/// than letters and digits one `-`, none at either end.
pub fn slug(name: []const u8, out: []u8) []const u8 {
    assert(out.len >= name.len);
    var len: usize = 0;
    var dash = false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (dash and len != 0) {
                out[len] = '-';
                len += 1;
            }
            dash = false;
            out[len] = std.ascii.toLower(byte);
            len += 1;
        } else {
            dash = true;
        }
    }
    assert(len <= name.len);
    return out[0..len];
}

/// How one (scenario, adapter) row ended.
pub const Status = enum { ok, changed, new, blessed, failed };

/// One report row.
const Row = struct {
    visit: Visit,
    name: []const u8,
    same: bool,
    status: Status,
    /// What the run wrote or why it failed.
    note: [path_cap]u8,
    note_len: u32,
};

/// Runs `--regress` for `App` (module guide, section 1) and returns the exit code.
pub fn run(comptime App: type, options: bench.Options) !u8 {
    comptime app_contract.check(App);
    assert(options.regress);
    return Runner(App).run(options);
}

fn Runner(comptime App: type) type {
    return struct {
        const Context = app_contract.Context(App);
        const Renderer = renderer.Renderer(Context.DrawContext);
        const size: [2]u32 = bench.regress_size(App);
        const rgb_bytes: usize = @as(usize, size[0]) * size[1] * 3;
        const png_bytes: usize = @intCast(bench.png_size(size[0], size[1]));
        const scenarios: []const bench.Scenario =
            if (@hasDecl(App, "scenarios")) App.scenarios else &.{};
        const has_audio = app_contract.has_audio(App);
        const Engine = if (has_audio) audio_thread.Engine(App.Audio) else void;

        // Module guide, section 3: static, initialized in place per run.
        var app: App = undefined;
        var context: Context = undefined;
        var render: Renderer = undefined;
        var buffer: commands.CommandBuffer = undefined;
        var device: gpu_wgpu.Gpu = undefined;
        var engine: Engine = undefined;
        var audio_queue: realtime.AudioQueue = undefined;
        var wake: realtime.Wake = .init(-1);
        var paste_buffer: [ui.cx.clipboard_cap]u8 = undefined;

        var rgb_on: [rgb_bytes]u8 = undefined;
        var rgb_off: [rgb_bytes]u8 = undefined;
        /// A baseline read back, then the diff painted over it.
        var rgb_other: [rgb_bytes]u8 = undefined;
        var png: [png_bytes]u8 = undefined;
        var golden_text: [golden_bytes_max]u8 = undefined;
        var golden_out: [golden_bytes_max]u8 = undefined;
        var report: [report_cap]u8 = undefined;

        var rows: [2 * bench.scenario_cap]Row = undefined;
        var row_count: u32 = 0;
        var adapter_names: [2]gpu_wgpu.AdapterText = undefined;
        var adapter_seen: [2]bool = .{ false, false };
        var problems: [2][path_cap]u8 = undefined;
        var problem_lens: [2]u32 = .{ 0, 0 };
        var runs: u32 = 0;

        /// One run's replay state: the clock, the frames fed audio, and the clipboard.
        var clock: Clock = undefined;
        var audio_frames: u64 = 0;
        var owns_copy: bool = false;

        comptime {
            assert(size[0] >= 1 and size[0] <= 4096);
            assert(size[1] >= 1 and size[1] <= 4096);
        }

        fn run(options: bench.Options) !u8 {
            const start_ns = monotonic_ns();
            buffer.len = 0;
            buffer.count = 0;
            const app_name = options.program;
            if (!valid_name(app_name)) {
                std.debug.print("regress: bad program name \"{s}\"\n", .{app_name});
                return 1;
            }
            if (options.only) |only| {
                const found = bench.find(scenarios, only) orelse {
                    std.debug.print("regress {s}: no scenario \"{s}\"\n", .{ app_name, only });
                    return 1;
                };
                if (!found.regress) {
                    std.debug.print("regress {s}: {s} opts out of regress\n", .{ app_name, only });
                    return 1;
                }
            }
            const visits: []const Visit = switch (options.adapter) {
                .default => &.{ .high, .low },
                .high => &.{.high},
                .low => &.{.low},
            };
            for (visits) |visit| try run_adapter(app_name, visit, options);
            const elapsed_s = @as(f64, @floatFromInt(monotonic_ns() - start_ns)) / 1e9;
            const passed = write_report(app_name, elapsed_s);
            return if (passed) 0 else 1;
        }

        fn run_adapter(app_name: []const u8, visit: Visit, options: bench.Options) !void {
            const slot = @backingInt(visit);
            device = gpu_wgpu.create_headless(switch (visit) {
                .high => .high,
                .low => .low,
            }) catch |err| {
                problem(slot, "{s}: no device ({s})", .{ @tagName(visit), @errorName(err) });
                return;
            };
            defer gpu_wgpu.destroy(&device);
            try gpu_wgpu.headless_target_create(&device, size[0], size[1]);
            adapter_names[slot] = gpu_wgpu.adapter_text(&device);
            adapter_seen[slot] = true;
            const names = &adapter_names[slot];
            var slug_buffer: [128]u8 = undefined;
            const adapter_slug = slug(names.name_slice(), &slug_buffer);
            var path_buffer: [path_cap]u8 = undefined;
            const golden_path = std.mem.printSentinel(&path_buffer, "test/golden/{s}/{s}.txt", .{
                adapter_slug, app_name,
            }, 0) catch unreachable;
            const old_text = read_file(golden_path, &golden_text);
            var golden: Golden = .empty(names.name_slice(), names.driver_slice(), size);
            if (old_text) |text| {
                const parsed = Golden.parse(text) catch {
                    problem(slot, "{s}: cannot parse", .{golden_path});
                    return;
                };
                if (parsed.other_device(names.name_slice(), names.driver_slice())) {
                    if (!options.bless) {
                        var message: [path_cap]u8 = undefined;
                        const name = names.name_slice();
                        const driver = names.driver_slice();
                        problem(slot, "{s}", .{refusal(&message, app_name, &parsed, name, driver)});
                        return;
                    }
                } else {
                    golden = parsed;
                }
            }
            var blessable = true;
            for (scenarios) |*scenario| {
                if (!scenario.regress) continue;
                if (options.only) |only| {
                    if (!std.mem.eql(u8, only, scenario.name)) continue;
                }
                const row = run_scenario(app_name, visit, scenario, &golden, options);
                if (!row.same or row.status == .failed) blessable = false;
            }
            if (!options.bless) return;
            if (!blessable) {
                problem(slot, "not blessed: a scenario failed or cache on and off differ", .{});
                return;
            }
            golden.adapter = names.name_slice();
            golden.driver = names.driver_slice();
            golden.size = size;
            const text = golden.format(&golden_out) catch {
                problem(slot, "golden file too large", .{});
                return;
            };
            var dir_buffer: [path_cap]u8 = undefined;
            const dir_format = "test/golden/{s}";
            const dir = std.mem.printSentinel(&dir_buffer, dir_format, .{adapter_slug}, 0) catch
                unreachable;
            make_dirs(dir);
            if (!write_file(golden_path, text)) problem(slot, "cannot write {s}", .{golden_path});
        }

        /// Runs one scenario cache on and off, compares, and records its row.
        fn run_scenario(
            app_name: []const u8,
            visit: Visit,
            scenario: *const bench.Scenario,
            golden: *Golden,
            options: bench.Options,
        ) *const Row {
            assert(row_count < rows.len);
            const row = &rows[row_count];
            row_count += 1;
            row.* = .{
                .visit = visit,
                .name = scenario.name,
                .same = false,
                .status = .failed,
                .note = undefined,
                .note_len = 0,
            };
            const hash_on = render_scenario(scenario, true, &rgb_on) catch |err| {
                note(row, "cache on: {s}", .{@errorName(err)});
                return row;
            };
            const hash_off = render_scenario(scenario, false, &rgb_off) catch |err| {
                note(row, "cache off: {s}", .{@errorName(err)});
                return row;
            };
            row.same = hash_on == hash_off;
            const blessed = golden.find(scenario.name);
            if (options.bless) {
                row.status = if (row.same) .blessed else .failed;
                if (row.same) golden.set(scenario.name, hash_on);
            } else if (blessed == null) {
                row.status = .new;
            } else {
                row.status = if (blessed.? == hash_on) .ok else .changed;
            }
            const passed = row.same and (row.status == .ok or row.status == .blessed);
            var dir_buffer: [path_cap]u8 = undefined;
            const dir_format = "zig-out/regress/{s}";
            const dir = std.mem.printSentinel(&dir_buffer, dir_format, .{app_name}, 0) catch
                unreachable;
            if (options.keep or !passed) make_dirs(dir);
            const tag = @tagName(visit);
            if (options.keep) {
                _ = write_png(dir, scenario.name, tag, "on", "", &rgb_on);
                _ = write_png(dir, scenario.name, tag, "off", "", &rgb_off);
            }
            if (passed) return row;
            const on_path = write_png(dir, scenario.name, tag, "on", ".new", &rgb_on);
            if (!row.same) {
                _ = write_png(dir, scenario.name, tag, "off", ".new", &rgb_off);
                bench.diff_rgb(&rgb_on, &rgb_off, &rgb_other);
                _ = write_png(dir, scenario.name, tag, "onoff", ".diff", &rgb_other);
                const name = scenario.name;
                note(row, "cache off differs -> {s}/{s}-{s}-onoff.diff.png", .{ dir, name, tag });
                return row;
            }
            // The path lives in `write_png`'s buffer, so the note copies it before the next.
            note(row, "-> {s}", .{on_path});
            if (row.status == .changed and baseline_matches(dir, scenario.name, tag, blessed.?)) {
                bench.diff_rgb(&rgb_other, &rgb_on, &rgb_other);
                if (write_png(dir, scenario.name, tag, "on", ".diff", &rgb_other).len != 0) {
                    note(row, "-> {s} (+ .diff.png)", .{on_path_copy(row)});
                }
            }
            return row;
        }

        /// True when `<scenario>-<tag>-on.png` exists and its pixels hash to `hash`; its
        /// pixels are then in `rgb_other`.
        fn baseline_matches(dir: []const u8, name: []const u8, tag: []const u8, hash: u64) bool {
            var path_buffer: [path_cap]u8 = undefined;
            const format = "{s}/{s}-{s}-on.png";
            const path = std.mem.printSentinel(&path_buffer, format, .{ dir, name, tag }, 0) catch
                return false;
            const bytes = read_file(path, &png) orelse return false;
            const image = bench.png_read_stored(bytes, &rgb_other) catch return false;
            if (image.width != size[0] or image.height != size[1]) return false;
            return bench.rgb_hash(image.pixels) == hash;
        }

        /// Renders `scenario` from fresh state (module guide, sections 2 and 3) and returns the
        /// hash of its last frame, whose RGB rows are left in `out`.
        fn render_scenario(scenario: *const bench.Scenario, cache: bool, out: *[rgb_bytes]u8) !u64 {
            runs += 1;
            gpu_wgpu.reset(&device);
            context.init();
            app_contract.start(App, &context);
            render.init();
            render.cache = cache;
            App.init(&app, &context.draw.textures);
            if (has_audio) {
                audio_queue.init();
                engine.init(&audio_queue, &wake, realtime.sample_rate);
            }
            buffer.reset();
            render.setup(&buffer, &context.draw);
            try gpu_wgpu.execute(&device, &buffer);
            assert(render.ready);
            clock = .init(App.config.timer_period_ms);
            audio_frames = 0;
            owns_copy = false;
            var replay: bench.Replay = .init();
            // The first frame draws everything, as a window's first configure does.
            context.redraw();
            try draw(0);
            _ = replay.presented(scenario);
            const frames_max: u64 = setup_frames(scenario) + scenario.frames + 1;
            var n: u64 = 1;
            while (replay.phase != .done) : (n += 1) {
                if (n > frames_max) return error.ReplayStuck;
                const step = replay.next(scenario);
                if (step) |taken| try apply_step(taken, n);
                try draw(n);
                _ = replay.presented(scenario);
            }
            try gpu_wgpu.read_target(&device, out);
            return bench.rgb_hash(out);
        }

        /// The frames a scenario's setup takes: one per step, `n` per wait of `n`.
        fn setup_frames(scenario: *const bench.Scenario) u64 {
            var total: u64 = 0;
            for (scenario.setup) |step| total += if (step == .wait) step.wait else 1;
            assert(total >= scenario.setup.len);
            return total;
        }

        fn apply_step(step: bench.Step, n: u64) !void {
            var rect: ?[4]f32 = null;
            if (bench.step_target(step)) |target| {
                const found = context.find(target.id) orelse return error.NoArea;
                rect = found.rect;
            }
            var events: [bench.event_cap]input.Event = undefined;
            const time_ms: u32 = @intCast(Clock.frame_time_ms(n));
            const count = bench.step_events(step, rect, time_ms, &events);
            for (events[0..count]) |event| dispatch(event);
        }

        /// One dispatch with the windowed host's clipboard rule when the app owns the
        /// selection: a paste request pastes the app's own copy (`linux_window.zig`, 5a).
        fn dispatch(event: input.Event) void {
            ui.dispatch(App, &app, &context, event);
            if (context.take_copy()) owns_copy = true;
            if (!context.take_paste_request()) return;
            if (!owns_copy) return;
            const own = context.copied();
            @memcpy(paste_buffer[0..own.len], own);
            ui.dispatch(App, &app, &context, .{ .paste = paste_buffer[0..own.len] });
        }

        /// Frame `n` on the simulated clock (module guide, section 2), steps 2 to 5.
        fn draw(n: u64) !void {
            const t_ms = Clock.frame_time_ms(n);
            var ticks: u32 = 0;
            while (clock.due(t_ms, context.timer_on)) |at| : (ticks += 1) {
                if (ticks == bench.ticks_per_frame_max) return error.TooManyTicks;
                App.timer(&app, &context, at);
            }
            _ = ui.animate(App, &app, &context, Clock.frame_dt(n));
            if (has_audio and context.audio_on) {
                engine.render(realtime.blocks_for_frame(audio_frames));
                audio_frames += 1;
                drain_audio();
            }
            _ = ui.draw_frame(App, &app, &context, size[0], size[1], scale_120);
            buffer.reset();
            const time: animator.Time = .{ .ms = t_ms };
            render.frame(&buffer, &context.draw, .{
                .width_logical = size[0],
                .height_logical = size[1],
                .width_px = size[0],
                .height_px = size[1],
                .scale_120 = scale_120,
            }, time.seconds());
            if (buffer.len != 0) try gpu_wgpu.execute(&device, &buffer);
        }

        fn drain_audio() void {
            var drained: u32 = 0;
            while (drained < realtime.queue_blocks) : (drained += 1) {
                const block = audio_queue.peek() orelse break;
                if (context.audio_on) App.audio(&app, &context, block);
                audio_queue.release();
            }
            assert(drained <= realtime.queue_blocks);
            context.audio_dropped = audio_queue.dropped_count();
        }

        /// Writes `<dir>/<name>-<tag>-<cache><suffix>.png` and returns its path (empty when
        /// it could not be written).
        fn write_png(
            dir: []const u8,
            name: []const u8,
            tag: []const u8,
            cache: []const u8,
            suffix: []const u8,
            rgb: *const [rgb_bytes]u8,
        ) []const u8 {
            const static = struct {
                var path_buffer: [path_cap]u8 = undefined;
            };
            const path = std.mem.printSentinel(&static.path_buffer, "{s}/{s}-{s}-{s}{s}.png", .{
                dir, name, tag, cache, suffix,
            }, 0) catch return "";
            var writer: std.Io.Writer = .fixed(&png);
            bench.png_write(&writer, size[0], size[1], rgb) catch unreachable;
            if (!write_file(path, writer.buffered())) return "";
            return path;
        }

        /// The `.new.png` path the row's note already names (after its `-> `).
        fn on_path_copy(row: *const Row) []const u8 {
            const static = struct {
                var copy: [path_cap]u8 = undefined;
            };
            const text = row.note[3..row.note_len];
            @memcpy(static.copy[0..text.len], text);
            return static.copy[0..text.len];
        }

        fn note(row: *Row, comptime format: []const u8, args: anytype) void {
            const text = std.fmt.bufPrint(&row.note, format, args) catch row.note[0..0];
            row.note_len = @intCast(text.len);
        }

        fn problem(slot: usize, comptime format: []const u8, args: anytype) void {
            const text = std.fmt.bufPrint(&problems[slot], format, args) catch problems[slot][0..0];
            problem_lens[slot] = @intCast(text.len);
        }

        /// Formats the whole report and writes it in one call (module guide, section 5).
        /// Returns true when every row passed and no adapter had a problem.
        fn write_report(app_name: []const u8, elapsed_s: f64) bool {
            var writer: std.Io.Writer = .fixed(&report);
            var adapter_width: usize = "adapter".len;
            for (adapter_names, adapter_seen) |names, seen| {
                if (seen) adapter_width = @max(adapter_width, names.name_len);
            }
            var name_width: usize = "scenario".len;
            for (rows[0..row_count]) |row| name_width = @max(name_width, row.name.len);
            var counts: [@typeInfo(Status).@"enum".field_names.len]u32 = @splat(0);
            var mismatches: u32 = 0;
            var passed = true;
            writer.print("regress {s}  {d}x{d}@1.00\n  ", .{ app_name, size[0], size[1] }) catch {};
            pad_print(&writer, "adapter", adapter_width + 2) catch {};
            pad_print(&writer, "scenario", name_width + 2) catch {};
            writer.writeAll("on/off  golden\n") catch {};
            for (rows[0..row_count]) |*row| {
                counts[@backingInt(row.status)] += 1;
                if (!row.same) mismatches += 1;
                if (!row.same or (row.status != .ok and row.status != .blessed)) passed = false;
                writer.writeAll("  ") catch {};
                const names = &adapter_names[@backingInt(row.visit)];
                pad_print(&writer, names.name_slice(), adapter_width + 2) catch {};
                pad_print(&writer, row.name, name_width + 2) catch {};
                pad_print(&writer, if (row.same) "same" else "DIFFER", 8) catch {};
                const status: []const u8 = switch (row.status) {
                    .ok => "ok",
                    .changed => "CHANGED",
                    .new => "new",
                    .blessed => "blessed",
                    .failed => "FAILED",
                };
                if (row.note_len == 0) {
                    writer.print("{s}\n", .{status}) catch {};
                } else {
                    pad_print(&writer, status, 9) catch {};
                    writer.print("{s}\n", .{row.note[0..row.note_len]}) catch {};
                }
            }
            for (problem_lens, 0..) |len, slot| {
                if (len == 0) continue;
                passed = false;
                writer.print("  {s}\n", .{problems[slot][0..len]}) catch {};
            }
            writer.print("{s}: {d} runs, {d} ok, {d} changed, {d} new, {d} blessed, {d} failed, " ++
                "{d} on/off mismatches  ({d:.1} s)\n", .{
                app_name,
                runs,
                counts[@backingInt(Status.ok)],
                counts[@backingInt(Status.changed)],
                counts[@backingInt(Status.new)],
                counts[@backingInt(Status.blessed)],
                counts[@backingInt(Status.failed)],
                mismatches,
                elapsed_s,
            }) catch {};
            _ = write_all(1, writer.buffered());
            return passed;
        }
    };
}

/// A program name usable in paths: letters, digits, `-`, and `_`.
fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

fn monotonic_ns() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Creates every directory of `path` that does not exist (`mkdir -p`), bounded by its length.
fn make_dirs(path: [:0]const u8) void {
    var buffer: [path_cap]u8 = undefined;
    assert(path.len < buffer.len);
    for (path, 0..) |byte, index| {
        if (byte != '/' and index + 1 != path.len) continue;
        const end = if (byte == '/') index else index + 1;
        @memcpy(buffer[0..end], path[0..end]);
        buffer[end] = 0;
        _ = std.os.linux.mkdir(buffer[0..end :0], 0o755);
    }
}

/// Reads all of `path` into `out`, or null when it is missing or does not fit.
fn read_file(path: [:0]const u8, out: []u8) ?[]const u8 {
    const rc = std.os.linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    var len: usize = 0;
    var tries: u32 = 0;
    while (tries < io_retry_max) : (tries += 1) {
        if (len == out.len) {
            // Full: the file fits only if nothing follows.
            var extra: [1]u8 = undefined;
            const more = std.os.linux.read(fd, &extra, 1);
            if (std.os.linux.errno(more) != .SUCCESS or more != 0) return null;
            return out[0..len];
        }
        const got = std.os.linux.read(fd, out[len..].ptr, out.len - len);
        if (std.os.linux.errno(got) != .SUCCESS) return null;
        if (got == 0) return out[0..len];
        len += got;
    }
    return null;
}

fn write_file(path: [:0]const u8, bytes: []const u8) bool {
    const flags: std.os.linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const rc = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = std.os.linux.close(fd);
    return write_all(fd, bytes);
}

fn write_all(fd: i32, bytes: []const u8) bool {
    assert(fd >= 0);
    var done: usize = 0;
    var tries: u32 = 0;
    while (done < bytes.len and tries < io_retry_max) : (tries += 1) {
        const rc = std.os.linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (std.os.linux.errno(rc) != .SUCCESS) return false;
        done += rc;
    }
    return done == bytes.len;
}

const io_retry_max: u32 = 4096;

const testing = std.testing;

const test_golden =
    \\# patchwork regress golden v1
    \\# adapter: NVIDIA GeForce RTX 3060
    \\# driver: NVIDIA 580.95.05
    \\# size: 1280x720 @120
    \\scenario  hash
    \\interact  0b17e2c4d9a85f60
    \\still     9f3c0d5e2a7b4411
    \\
;

// Locks the golden format: the spec's sample parses, formats back to the same bytes, sorts
// lines added out of order, and reports a scenario with no line as new (null).
test "golden files round trip sorted" {
    var golden = try Golden.parse(test_golden);
    try testing.expectEqualStrings("NVIDIA GeForce RTX 3060", golden.adapter);
    try testing.expectEqualStrings("NVIDIA 580.95.05", golden.driver);
    try testing.expectEqual([2]u32{ 1280, 720 }, golden.size);
    try testing.expectEqual(@as(?u64, 0x9f3c0d5e2a7b4411), golden.find("still"));
    try testing.expectEqual(@as(?u64, null), golden.find("hover"));
    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(test_golden, try golden.format(&out));
    golden.set("hardware", 1);
    golden.set("hover", 0xffff_ffff_ffff_ffff);
    golden.set("still", 2);
    const expected =
        \\# patchwork regress golden v1
        \\# adapter: NVIDIA GeForce RTX 3060
        \\# driver: NVIDIA 580.95.05
        \\# size: 1280x720 @120
        \\scenario  hash
        \\hardware  0000000000000001
        \\hover     ffffffffffffffff
        \\interact  0b17e2c4d9a85f60
        \\still     0000000000000002
        \\
    ;
    try testing.expectEqualStrings(expected, try golden.format(&out));
    try testing.expectError(error.BadGolden, Golden.parse("# patchwork regress golden v0\n"));
    const twice = test_golden ++ "still 0000000000000003\n";
    try testing.expectError(error.BadGolden, Golden.parse(twice));
}

// Locks the driver check: the same adapter and driver pass, another driver is refused with
// the message naming both and the way out.
test "a golden blessed on another driver is refused with its message" {
    const golden = try Golden.parse(test_golden);
    try testing.expect(!golden.other_device("NVIDIA GeForce RTX 3060", "NVIDIA 580.95.05"));
    try testing.expect(golden.other_device("NVIDIA GeForce RTX 3060", "NVIDIA 590.10"));
    try testing.expect(golden.other_device("Intel(R) UHD Graphics 770", "NVIDIA 580.95.05"));
    var out: [512]u8 = undefined;
    const message = refusal(&out, "rack", &golden, "NVIDIA GeForce RTX 3060", "NVIDIA 590.10");
    try testing.expectEqualStrings("golden for rack was blessed on driver \"NVIDIA GeForce RTX " ++
        "3060 / NVIDIA 580.95.05\"; this device reports \"NVIDIA GeForce RTX 3060 / NVIDIA " ++
        "590.10\". Re-bless from master (see the Agent brief)", message);
}

// Locks the adapter slug of three names: runs of other characters become one dash, none at
// either end.
test "adapter names slug to directory names" {
    var out: [64]u8 = undefined;
    const nvidia = slug("NVIDIA GeForce RTX 3060", &out);
    try testing.expectEqualStrings("nvidia-geforce-rtx-3060", nvidia);
    const intel = slug("Intel(R) Graphics (RPL-S)", &out);
    try testing.expectEqualStrings("intel-r-graphics-rpl-s", intel);
    const software = slug("  llvmpipe (LLVM 20.1.8, 256 bits)", &out);
    try testing.expectEqualStrings("llvmpipe-llvm-20-1-8-256-bits", software);
}

comptime {
    assert(scale_120 == 120);
    assert(golden_bytes_max >= 512);
}

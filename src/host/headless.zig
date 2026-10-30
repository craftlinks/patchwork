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
//! for adapter in (high, low):            Offscreen.open
//!   read test/golden/<adapter slug>/<app>.txt; refuse a golden blessed on another driver
//!   for scenario, for cache in (on, off):
//!     Offscreen.start, then Playback to the end        (section 2)
//!     Offscreen.read(.rgb), hash the RGB rows          (bench.rgb_hash)
//!   compare: cache on == cache off; hash == golden line (or bless it)
//! one report, one write; exit 0 only when every line is the same and ok
//! ```
//! The frame loop, the fresh state per start, and the device live in `Offscreen`
//! (`host/offscreen.zig`, sections 2 and 3). Everything here is scenarios: playback, goldens,
//! pictures, and the report.
//!
//! ## 2. Playback
//! `Playback` is a scenario on a frame clock at `fps` (`offscreen.at_frame`): frame 0 draws with
//! no step, and each later frame `n` applies the scenario's next step (`bench.Replay`), its
//! presses stamped `t_n`, then draws, until `frames` are measured. Every frame is drawn: there
//! is no vsync to wait for. An empty cycle draws clock frames. `--regress` runs it at 60 fps.
//!
//! ## 3. Rendering Frames
//! `render` is `--render`: one scenario's every `Playback` frame, from frame 0, at any size,
//! scale, and rate, as a PNG sequence or as raw RGBA on stdout for a video encoder. The frame
//! lives in one static buffer of `bench.render_size(App)`; a size over it is refused by name
//! before a device exists. PNGs are read as RGB and go through a `FileSink`, so no PNG-sized
//! buffer is needed. Raw frames go to stdout in pieces of at most `raw_piece_bytes`, so
//! `write_all`'s retry bound holds on a pipe; the encoder sets the pace. A closed pipe is an
//! `EPIPE`, not a signal, and ends the run. The report is one line on stderr, and stdout carries
//! only frames. Its hash is the last frame's `rgb_hash` whichever layout was read, so a render
//! at the regress size, scale 1, and 60 fps prints the scenario's golden.
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
//!   sized by the app's regress size (`bench.regress_size`) and render size
//!   (`bench.render_size`).
//! - Bounded loops: frames by the scenario's setup and `frames`, golden lines by
//!   `bench.scenario_cap`, paths by `path_cap`, writes by `io_retry_max`.

const std = @import("std");
const assert = std.debug.assert;
const app_contract = @import("../app.zig");
const bench = @import("../bench.zig");
const frame_module = @import("../frame.zig");
const gpu_wgpu = @import("gpu_wgpu.zig");
const offscreen = @import("offscreen.zig");

/// The display scale regress renders at, in 1/120 units.
pub const scale_120: u32 = 120;

/// The frame rate regress runs at.
const regress_fps: u32 = 60;

/// Most bytes of a raw frame one `write_all` takes (module guide, section 3).
const raw_piece_bytes: usize = 1024 * 1024;

/// Bytes of a PNG buffered before they reach the file.
const png_chunk_bytes: usize = 64 * 1024;

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

/// Runs `--render` for `App` (module guide, section 3) and returns the exit code.
pub fn render(comptime App: type, options: bench.Options) u8 {
    comptime app_contract.check(App);
    assert(options.render != null);
    assert(options.out != null);
    return Runner(App).render(options);
}

/// A scenario on a frame clock through `Off` (module guide, section 2).
fn Playback(comptime Off: type) type {
    return struct {
        const Self = @This();

        /// The app's scenario with `frames` replaced, which `bench.Replay` reads.
        scenario: bench.Scenario,
        fps: u32,
        replay: bench.Replay,
        n: u64,
        frames_max: u64,

        fn init(scenario: *const bench.Scenario, fps: u32, frames: u32) Self {
            assert(frames >= 1);
            assert(fps >= bench.fps_min and fps <= bench.fps_max);
            var measured = scenario.*;
            measured.frames = frames;
            return .{
                .scenario = measured,
                .fps = fps,
                .replay = .init(),
                .n = 0,
                .frames_max = setup_frames(scenario) + frames + 1,
            };
        }

        /// Draws the next frame and returns its number, or null when the replay is done.
        fn next(self: *Self) !?u64 {
            const n = self.n;
            if (self.replay.phase == .done) return null;
            if (n > self.frames_max) return error.ReplayStuck;
            const at = offscreen.at_frame(n, self.fps);
            if (n != 0) {
                if (self.replay.next(&self.scenario)) |step| {
                    try Off.step(step, @intCast(at.time_ms));
                }
            }
            try Off.frame(at);
            _ = self.replay.presented(&self.scenario);
            self.n += 1;
            return n;
        }

        /// The frames a scenario's setup takes: one per step, `n` per wait of `n`.
        fn setup_frames(scenario: *const bench.Scenario) u64 {
            var total: u64 = 0;
            for (scenario.setup) |step| total += if (step == .wait) step.wait else 1;
            assert(total >= scenario.setup.len);
            return total;
        }
    };
}

/// A `std.Io.Writer` over a file descriptor: a PNG reaches the file through `buffer` with no
/// PNG-sized storage (module guide, section 3).
const FileSink = struct {
    fd: i32,
    writer: std.Io.Writer,

    fn init(fd: i32, buffer: []u8) FileSink {
        assert(fd >= 0);
        assert(buffer.len != 0);
        return .{ .fd = fd, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const sink: *FileSink = @alignCast(@fieldParentPtr("writer", writer));
        assert(data.len >= 1);
        if (!write_all(sink.fd, writer.buffered())) return error.WriteFailed;
        writer.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            if (!write_all(sink.fd, bytes)) return error.WriteFailed;
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0) return written;
        for (0..splat) |_| {
            if (!write_all(sink.fd, pattern)) return error.WriteFailed;
            written += pattern.len;
        }
        return written;
    }
};

fn Runner(comptime App: type) type {
    return struct {
        const Off = offscreen.Offscreen(App);
        const size: [2]u32 = bench.regress_size(App);
        const rgb_bytes: usize = @as(usize, size[0]) * size[1] * 3;
        const png_bytes: usize = @intCast(bench.png_size(size[0], size[1]));
        const scenarios: []const bench.Scenario =
            if (@hasDecl(App, "scenarios")) App.scenarios else &.{};
        const render_max: [2]u32 = bench.render_size(App);
        const render_bytes: usize = @as(usize, render_max[0]) * render_max[1] * 4;

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

        /// One `--render` frame (module guide, section 3). Zero, not `undefined`, which a Debug
        /// build writes into every binary instead of leaving to BSS.
        var render_frame: [render_bytes]u8 = @splat(0);
        var png_chunk: [png_chunk_bytes]u8 = undefined;

        comptime {
            assert(size[0] >= 1 and size[0] <= 4096);
            assert(size[1] >= 1 and size[1] <= 4096);
        }

        fn run(options: bench.Options) !u8 {
            const start_ns = monotonic_ns();
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
            Off.open(.{
                .adapter = switch (visit) {
                    .high => .high,
                    .low => .low,
                },
                .width = size[0],
                .height = size[1],
                .scale_120 = scale_120,
                .fps = regress_fps,
            }) catch |err| {
                problem(slot, "{s}: no device ({s})", .{ @tagName(visit), @errorName(err) });
                return;
            };
            defer Off.close();
            adapter_names[slot] = Off.adapter_text();
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

        /// Renders `scenario` from fresh state (module guide, section 2) and returns the hash
        /// of its last frame, whose RGB rows are left in `out`.
        fn render_scenario(scenario: *const bench.Scenario, cache: bool, out: *[rgb_bytes]u8) !u64 {
            runs += 1;
            try Off.start(.{ .cache = cache });
            var playback: Playback(Off) = .init(scenario, regress_fps, scenario.frames);
            while (try playback.next()) |_| {}
            const pixels = try Off.read(.rgb, out);
            return bench.rgb_hash(pixels.bytes);
        }

        /// `--render` (module guide, section 3): refuses what cannot run, then renders.
        fn render(options: bench.Options) u8 {
            const app_name = options.program;
            const name = options.render.?;
            const scenario = bench.find(scenarios, name) orelse {
                std.debug.print("render {s}: no scenario \"{s}\"\n", .{ app_name, name });
                return 1;
            };
            const logical = options.size orelse size;
            const scale = options.scale_120 orelse scale_120;
            const width_px = frame_module.pixel_size(logical[0], scale);
            const height_px = frame_module.pixel_size(logical[1], scale);
            if (width_px > render_max[0] or height_px > render_max[1]) {
                std.debug.print("render {s}: {d}x{d} px is over App.render_size_max ({d}x{d})\n", .{
                    app_name, width_px, height_px, render_max[0], render_max[1],
                });
                return 1;
            }
            const raw = std.mem.eql(u8, options.out.?, "-");
            if (raw) {
                ignore_sigpipe();
            } else {
                make_dirs(options.out.?);
            }
            const adapter: bench.Adapter = if (options.adapter == .low) .low else .high;
            Off.open(.{
                .adapter = adapter,
                .width = logical[0],
                .height = logical[1],
                .scale_120 = scale,
                .fps = options.fps orelse regress_fps,
            }) catch |err| {
                std.debug.print("render {s}: no device ({s})\n", .{ app_name, @errorName(err) });
                return 1;
            };
            defer Off.close();
            return render_frames(scenario, options, raw) catch |err| {
                const failed = @errorName(err);
                std.debug.print("render {s} {s}: {s}\n", .{ app_name, scenario.name, failed });
                return 1;
            };
        }

        /// Every `Playback` frame of `scenario`, written as it is read, then the report.
        fn render_frames(scenario: *const bench.Scenario, options: bench.Options, raw: bool) !u8 {
            const start_ns = monotonic_ns();
            const app_name = options.program;
            const fps = options.fps orelse regress_fps;
            const frames = options.frames orelse scenario.frames;
            const px = Off.size_px();
            const layout: bench.Layout = if (raw) .rgba else .rgb;
            const frame_len = @as(usize, px[0]) * px[1] * layout.pixel_bytes();
            const out = render_frame[0..frame_len];
            try Off.start(.{ .cache = options.cache });
            var playback: Playback(Off) = .init(scenario, fps, frames);
            var written: u64 = 0;
            var draw_ns: u64 = 0;
            var read_ns: u64 = 0;
            while (true) {
                const before_ns = monotonic_ns();
                const n = try playback.next() orelse break;
                const drawn_ns = monotonic_ns();
                const pixels = try Off.read(layout, out);
                draw_ns += drawn_ns - before_ns;
                read_ns += monotonic_ns() - drawn_ns;
                if (raw) {
                    if (!write_raw(pixels.bytes)) {
                        std.debug.print("render {s} {s}: output closed after {d} frames\n", .{
                            app_name, scenario.name, written,
                        });
                        return 1;
                    }
                } else if (!write_frame(options.out.?, scenario.name, n, pixels)) {
                    return 1;
                }
                written += 1;
            }
            assert(written >= 1);
            const last = if (raw) bench.rgb_hash_rgba(out) else bench.rgb_hash(out);
            const count: f64 = @floatFromInt(written);
            const scale: f64 = @floatFromInt(options.scale_120 orelse scale_120);
            std.debug.print("render {s} {s}  {d}x{d} px @{d:.2}  {d} frames at {d} fps  " ++
                "last {x:0>16}  ({d:.1} s; {d:.2} ms draw, {d:.2} ms read a frame)\n", .{
                app_name,
                scenario.name,
                px[0],
                px[1],
                scale / 120,
                written,
                fps,
                last,
                @as(f64, @floatFromInt(monotonic_ns() - start_ns)) / 1e9,
                @as(f64, @floatFromInt(draw_ns)) / 1e6 / count,
                @as(f64, @floatFromInt(read_ns)) / 1e6 / count,
            });
            return 0;
        }

        /// Writes `<dir>/<name>-<n>.png`. On failure it says so and returns false.
        fn write_frame(
            dir: [:0]const u8,
            name: []const u8,
            n: u64,
            pixels: offscreen.Pixels,
        ) bool {
            assert(pixels.layout == .rgb);
            var path_buffer: [path_cap]u8 = undefined;
            const path = std.mem.printSentinel(&path_buffer, "{s}/{s}-{d:0>6}.png", .{
                dir, name, n,
            }, 0) catch {
                std.debug.print("render: path too long under {s}\n", .{dir});
                return false;
            };
            const fd = create_file(path) orelse {
                std.debug.print("render: cannot write {s}\n", .{path});
                return false;
            };
            defer _ = std.os.linux.close(fd);
            var sink: FileSink = .init(fd, &png_chunk);
            const written = blk: {
                bench.png_write(&sink.writer, pixels.width, pixels.height, pixels.bytes) catch
                    break :blk false;
                sink.writer.flush() catch break :blk false;
                break :blk true;
            };
            if (!written) std.debug.print("render: cannot write {s}\n", .{path});
            return written;
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

/// Writes a raw frame to stdout in pieces (module guide, section 3). False on a closed pipe.
fn write_raw(bytes: []const u8) bool {
    assert(bytes.len != 0);
    var done: usize = 0;
    var pieces: usize = 0;
    while (done < bytes.len) : (pieces += 1) {
        assert(pieces <= bytes.len / raw_piece_bytes);
        const take = @min(bytes.len - done, raw_piece_bytes);
        if (!write_all(1, bytes[done..][0..take])) return false;
        done += take;
    }
    assert(done == bytes.len);
    return true;
}

/// A closed pipe becomes `EPIPE` on the next write, so the run can say so.
fn ignore_sigpipe() void {
    const action: std.os.linux.Sigaction = .{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(.PIPE, &action, null);
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
    const fd = create_file(path) orelse return false;
    defer _ = std.os.linux.close(fd);
    return write_all(fd, bytes);
}

/// Opens `path` for writing, empty; null when it cannot.
fn create_file(path: [:0]const u8) ?i32 {
    const flags: std.os.linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const rc = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
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

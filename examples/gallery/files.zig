//! The gallery's "files" page (step 37): a drop zone, the dropped files in a list box, and
//! the waveform of a dropped WAV.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Zone
//! One area flagged `drop` over a panel. `cx.drop_hovering` gives its highlight in `draw`, so
//! the page keeps no hover state: `drop_in` and `drop_out` only owe a redraw. On `dropped` the
//! page copies each file's name (cut to `name_cap` bytes on a codepoint) and size, and accepts
//! every readable file; a folder is listed but not accepted.
//!
//! ## 2. Chunks
//! Each file's row shows its size and status: "reading 42%" as bytes arrive, then "done",
//! "failed", "cancelled", or "cut at 21.8 s"; "folder" for an unreadable entry. The first file
//! whose name ends in ".wav" is fed to `wav.Decoder` chunk by chunk into `samples`; the others
//! are counted, not stored. When `samples` is full the page cancels that file alone
//! (`cx.cancel_files`), which is the big-file path in practice: the app stops reading what it
//! cannot hold. On the WAV's last chunk (or its cut) the page builds `wave.Pyramid` over the
//! samples, and `draw` shows them as a `draw.Waveform` of one column per logical pixel.
//!
//! ## 3. TigerStyle Invariants
//! - Fixed storage: `input.drop_files_max` rows, `samples_max` samples, one pyramid.
//! - Each event does work bounded by one chunk; `draw` by the panel's width in columns.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const input = patchwork.input;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;
const kit = widgets.kit;
const wave = quads.wave;
const icons = @import("icons.zig");
const wav = @import("wav.zig");

const Rect = quads.Rect;

/// Samples one WAV keeps: 21.8 s at 48 kHz, mono or the left channel.
pub const samples_max: u32 = 1 << 20;
/// Bytes of a file's name the page keeps.
pub const name_cap: u32 = 48;
/// Columns the waveform draws at most: the page is narrower.
pub const columns_max: u32 = 1024;

pub const zone_w: f32 = 400;
pub const zone_h: f32 = 200;
pub const row_px: f32 = 28;
pub const zone_id = ui.id("drop_zone", 0);
pub const list_id = ui.id("drop_files", 0);

const files_max = input.drop_files_max;

pub const Status = enum(u8) {
    waiting,
    reading,
    done,
    failed,
    cancelled,
    cut,
    folder,
};

/// What the page reports for the status line: up to three parts.
pub const Note = struct {
    parts: [3][]const u8,
    len: u32,

    fn of(parts: []const []const u8) Note {
        assert(parts.len <= 3);
        var note: Note = .{ .parts = undefined, .len = @intCast(parts.len) };
        for (parts, 0..) |part, index| note.parts[index] = part;
        return note;
    }

    pub fn slice(self: *const Note) []const []const u8 {
        return self.parts[0..self.len];
    }
};

pub const Page = struct {
    list: widgets.ListBox,
    count: u8,
    names: [files_max][name_cap]u8,
    name_lens: [files_max]u8,
    sizes: [files_max]u64,
    received: [files_max]u64,
    status: [files_max]Status,
    /// The WAV being decoded or shown, by row.
    wav_row: ?u8,
    decoder: wav.Decoder,
    /// The decoded samples are complete and the pyramid built.
    shown: bool,
    samples: [samples_max]f32,
    pyramid: wave.Pyramid(samples_max),
    columns: [columns_max]wave.Column,
    /// The info line over the waveform and the cut row's status text.
    info: [64]u8,
    info_len: u32,
    cut_text: [24]u8,
    cut_len: u32,

    pub fn init(self: *Page) void {
        self.list = widgets.ListBox.init(list_id, 0, row_px);
        self.count = 0;
        self.wav_row = null;
        self.shown = false;
        self.info_len = 0;
        self.cut_len = 0;
        self.decoder.init();
        assert(self.list.count == 0);
    }

    /// The zone and the list box (section 1); a report for the status line, or null.
    pub fn handle(self: *Page, cx: anytype, event: input.Event) ?Note {
        switch (self.list.handle(cx, event)) {
            .selected, .activated => |row| return Note.of(&.{ "file ", self.name(row), " selected" }),
            .none => {},
        }
        switch (cx.drop_hit(zone_id, event)) {
            .drop_in, .drop_out => cx.redraw(),
            .dropped => |dropped| return self.take(cx, dropped.files),
            .file => |piece| return self.receive(cx, piece),
            .none => if (event == .drop) return Note.of(&.{"drop on nothing"}),
        }
        return null;
    }

    /// Lists the dropped files and accepts the readable ones (section 1).
    fn take(self: *Page, cx: anytype, files: *const input.Drop) Note {
        var mask: u16 = 0;
        self.count = files.count;
        self.wav_row = null;
        self.shown = false;
        self.info_len = 0;
        for (files.listed(), 0..) |file, index| {
            const length = input.utf8_prefix(file.name, name_cap);
            @memcpy(self.names[index][0..length], file.name[0..length]);
            self.name_lens[index] = @intCast(length);
            self.sizes[index] = file.size;
            self.received[index] = 0;
            self.status[index] = if (file.readable) .waiting else .folder;
            if (!file.readable) continue;
            mask |= @as(u16, 1) << @intCast(index);
            if (self.wav_row == null and is_wav(file.name)) self.wav_row = @intCast(index);
        }
        self.list = widgets.ListBox.init(list_id, files.count, row_px);
        if (self.wav_row != null) self.decoder.init();
        if (mask != 0) cx.accept_files(zone_id, mask);
        cx.redraw();
        return Note.of(&.{ "drop ", count_text(files.count), if (files.count == 1) " file" else " files" });
    }

    /// One chunk of an accepted file (section 2).
    fn receive(self: *Page, cx: anytype, piece: *const input.Chunk) ?Note {
        const row = piece.file;
        assert(row < self.count);
        cx.redraw();
        self.received[row] += piece.bytes.len;
        if (self.wav_row == row and self.status[row] != .cut) {
            self.decoder.feed(piece.bytes, &self.samples);
            if (self.decoder.cut) {
                self.status[row] = .cut;
                self.show(row);
                cx.cancel_files(@as(u16, 1) << @intCast(row));
                return Note.of(&.{ "file ", self.name(row), " cut" });
            }
        }
        switch (piece.end) {
            .more => {
                self.status[row] = .reading;
                return null;
            },
            .done => {
                self.status[row] = .done;
                if (self.wav_row == row) self.show(row);
                return Note.of(&.{ "file ", self.name(row), " done" });
            },
            .failed => self.status[row] = .failed,
            .cancelled => if (self.status[row] != .cut) {
                self.status[row] = .cancelled;
            },
        }
        if (self.status[row] == .cut) return null;
        return Note.of(&.{ "file ", self.name(row), if (piece.end == .failed) " failed" else " cancelled" });
    }

    /// Builds the pyramid over the decoded samples and the info line.
    fn show(self: *Page, row: u8) void {
        const decoder = &self.decoder;
        if (decoder.problem != .none or decoder.count == 0) {
            const why = switch (decoder.problem) {
                .not_pcm16 => "not 16-bit PCM",
                .not_riff => "not a RIFF/WAVE file",
                .no_format, .none => "no samples",
            };
            self.info_len = write(&self.info, "{s}: {s}", .{ self.name(row), why });
            return;
        }
        self.pyramid.build(self.samples[0..decoder.count]);
        self.shown = true;
        const layout = if (decoder.channels == 1) "mono" else "left of stereo";
        self.info_len = write(&self.info, "{s} · {d} Hz · {s} · 16-bit · {d:.2} s", .{
            self.name(row), decoder.rate, layout, decoder.seconds(),
        });
        if (decoder.cut) self.cut_len = write(&self.cut_text, "cut at {d:.1} s", .{decoder.seconds()});
    }

    fn name(self: *const Page, row: u32) []const u8 {
        assert(row < self.count);
        return self.names[row][0..self.name_lens[row]];
    }

    /// The zone over the file list beside the waveform panel.
    pub fn draw(self: *Page, cx: anytype, gap: f32, padding: f32, panel: widgets.Paint) void {
        _ = cx.begin(ui.sized(.fill, .fill), .{ .flow = .right, .spacing = gap });
        _ = cx.begin(ui.sized(.{ .fixed = zone_w }, .fill), .{ .flow = .down, .spacing = gap });
        self.draw_zone(cx, panel);
        const face: widgets.Panel = .{ .paint = panel };
        _ = face.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .padding = .all(padding), .clip = true });
        _ = self.list.begin(cx, ui.sized(.fill, .fill));
        while (self.list.next(cx)) |row| self.draw_row(cx, row);
        self.list.end(cx);
        _ = cx.end();
        _ = cx.end();
        _ = face.begin(cx, ui.sized(.fill, .fill), .{ .flow = .down, .spacing = gap, .padding = .all(padding), .clip = true });
        self.draw_wave(cx);
        _ = cx.end();
        _ = cx.end();
    }

    fn draw_zone(self: *const Page, cx: anytype, panel: widgets.Paint) void {
        _ = self;
        const zone = cx.walk(ui.sized(.fill, .{ .fixed = zone_h }));
        const clip = cx.visible(zone) orelse return;
        const colors = &cx.theme().colors;
        const over = cx.drop_hovering(zone_id);
        kit.face(cx, zone, clip, .{
            .fill = panel.look(cx.theme(), 0, 0).fill,
            .border_color = if (over) cx.theme().accents[0] else colors.track,
            .border_width = if (over) 2 else 1,
            .radius = panel.radius,
        });
        cx.area(zone_id, zone, panel.radius, ui.cx.drop_flag);
        const icon_rect: Rect = .{ .x = zone.x, .y = zone.y + 36, .width = zone.width, .height = 48 };
        kit.icon(cx, .icons, icons.folder_open, 32, icon_rect, clip, colors.text);
        const title: Rect = .{ .x = zone.x, .y = zone.y + 96, .width = zone.width, .height = 28 };
        kit.label(cx, style(cx, .sans_bold, 18), "Drop files here", title, clip, widgets.centered);
        const line: Rect = .{ .x = zone.x, .y = zone.y + 128, .width = zone.width, .height = 20 };
        kit.label(cx, style(cx, .sans, 14), "A WAV (16-bit PCM) is drawn", line, clip, widgets.centered);
    }

    fn draw_row(self: *const Page, cx: anytype, row: widgets.ListRow) void {
        const index = row.index;
        assert(index < self.count);
        const inner = ui.cx.inset(row.rect, .xy(12, 0));
        const name_rect: Rect = .{ .x = inner.x, .y = inner.y, .width = inner.width - 176, .height = inner.height };
        kit.label(cx, style(cx, .sans, 14), self.name(index), name_rect, row.clip, start);
        var size_bytes: [16]u8 = undefined;
        const size_rect: Rect = .{ .x = inner.x + inner.width - 176, .y = inner.y, .width = 72, .height = inner.height };
        if (self.status[index] != .folder) {
            kit.label(cx, style(cx, .mono, 13), size_text(&size_bytes, self.sizes[index]), size_rect, row.clip, end);
        }
        var status_bytes: [24]u8 = undefined;
        const status_rect: Rect = .{ .x = inner.x + inner.width - 96, .y = inner.y, .width = 96, .height = inner.height };
        kit.label(cx, style(cx, .sans, 14), self.status_text(&status_bytes, index), status_rect, row.clip, end);
    }

    fn draw_wave(self: *Page, cx: anytype) void {
        const line = cx.walk(ui.sized(.fill, .{ .fixed = 20 }));
        if (cx.visible(line)) |clip| {
            const words = if (self.info_len > 0) self.info[0..self.info_len] else "no WAV dropped yet";
            kit.label(cx, style(cx, .sans, 14), words, line, clip, start);
        }
        const rect = cx.walk(ui.sized(.fill, .fill));
        const clip = cx.visible(rect) orelse return;
        kit.face(cx, rect, clip, .{ .fill = cx.theme().colors.track, .radius = 4 });
        if (!self.shown) return;
        const count: u32 = @intFromFloat(@min(@floor(rect.width), columns_max));
        const out = self.columns[0..count];
        self.pyramid.columns(self.samples[0..self.decoder.count], 0, self.decoder.count, out);
        const accent = cx.theme().accents[0];
        const rms: [4]f32 = .{ accent[0], accent[1], accent[2], 0.5 };
        const wave_rect: [4]f32 = .{ rect.x, rect.y, @floatFromInt(count), rect.height };
        _ = wave.append(cx.drawing(), wave_rect, clip.array(), out, .{ .color = accent, .rms_color = rms });
    }

    fn status_text(self: *const Page, out: *[24]u8, row: u32) []const u8 {
        return switch (self.status[row]) {
            .waiting => "waiting",
            .reading => blk: {
                const percent = self.received[row] * 100 / @max(self.sizes[row], 1);
                break :blk std.fmt.bufPrint(out, "reading {d}%", .{percent}) catch unreachable;
            },
            .done => "done",
            .failed => "failed",
            .cancelled => "cancelled",
            .cut => self.cut_text[0..self.cut_len],
            .folder => "folder",
        };
    }
};

const start: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };
const end: text.Options = .{ .align_x = .end, .align_y = .center, .ellipsis = false };

fn style(cx: anytype, face: text.Face, size: f32) text.Style {
    return .{ .face = face, .size = size, .color = cx.theme().colors.text };
}

/// True for a name ending in ".wav", any case.
pub fn is_wav(name: []const u8) bool {
    return name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".wav");
}

/// `bytes` as "120 B", "93.8 KB", or "4.0 MB" (1024-based).
pub fn size_text(out: *[16]u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(out, "{d} B", .{bytes}) catch unreachable;
    const value: f64 = @floatFromInt(bytes);
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(out, "{d:.1} KB", .{value / 1024}) catch unreachable;
    return std.fmt.bufPrint(out, "{d:.1} MB", .{value / (1024 * 1024)}) catch unreachable;
}

fn count_text(count: u8) []const u8 {
    const numbers = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16" };
    assert(count <= files_max);
    return numbers[count];
}

fn write(out: anytype, comptime format: []const u8, args: anytype) u32 {
    const written = std.fmt.bufPrint(out, format, args) catch out[0..];
    return @intCast(written.len);
}

// ---------------------------------------------------------------------- the scenario file

/// The `drop` scenario's WAV: 48 kHz mono 16-bit, 1.00 s of a 120 Hz tone with partials at 2
/// and 3 times its frequency, as the header and one 400-sample period repeated 120 times.
pub const tone_rate: u32 = 48000;
pub const tone_period: u32 = 400;
pub const tone_periods: u32 = 120;
pub const tone_header = wav.header(tone_rate, 1, tone_period * tone_periods * 2);
pub const tone_cycle: [tone_period * 2]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var out: [tone_period * 2]u8 = undefined;
    for (0..tone_period) |index| {
        const phase = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / tone_period;
        const value = 0.5 * @sin(phase) + 0.25 * @sin(2 * phase + 0.5) + 0.12 * @sin(3 * phase + 1.0);
        const sample: i16 = @intFromFloat(@round(value * 32767));
        std.mem.writeInt(i16, out[2 * index ..][0..2], sample, .little);
    }
    break :blk out;
};
pub const readme = "Dropped files reach the app as bytes in 64 KiB chunks, on Linux and in the browser alike.\n" ++
    "No path is ever shown.";

comptime {
    assert(tone_header.len + tone_cycle.len * tone_periods == 96044);
    assert(readme.len == 112);
    assert(name_cap <= input.drop_name_max);
}

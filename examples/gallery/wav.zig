//! A streaming RIFF/WAVE decoder for the gallery's files page (step 37): the dropped file's
//! chunks are fed as they arrive, and 16-bit PCM samples come out as `f32`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Streaming
//! A dropped file arrives in 64 KiB chunks and the gallery keeps none of them, only the
//! decoded samples. So the decoder holds no file: a carry buffer of at most `carry_cap` bytes
//! collects a header item (the RIFF header, a chunk header, a `fmt ` body) or a sample frame
//! that straddles two chunks, and everything else is consumed in place.
//! ```text
//! riff (12) -> header (8) -> "fmt " body -> header -> skip other chunks -> "data": frames
//! ```
//! Chunks other than `fmt ` and `data` (LIST, bext, iXML) are skipped by their length, with
//! the pad byte of an odd length.
//!
//! ## 2. What It Accepts
//! PCM (format 1, or WAVE_FORMAT_EXTENSIBLE, 0xFFFE), 16 bits, 1 or 2 channels; the left
//! channel of stereo. A sample `s` becomes `s / 32768`. Anything else stops the decoder with
//! a `Problem` the page shows; the file still reads to its end. Samples past the output's
//! length set `cut` (the gallery then cancels the file).
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the carry buffer is fixed; the output is the caller's slice.
//! - `feed` is bounded by its input: every iteration consumes at least one byte or ends.

const std = @import("std");
const assert = std.debug.assert;

/// Bytes the carry buffer holds: the longest `fmt ` body read (an extensible one, 40 bytes).
pub const carry_cap: u32 = 40;

pub const Problem = enum(u8) {
    none,
    not_riff,
    not_pcm16,
    no_format,
};

const State = enum(u8) {
    riff,
    header,
    format,
    skip,
    data,
    stopped,
};

pub const Decoder = struct {
    state: State,
    carry: [carry_cap]u8,
    carry_len: u32,
    /// Bytes the current header item needs in `carry`.
    need: u32,
    /// Bytes left to skip, or of the `data` chunk.
    left: u64,
    /// The pad byte after the current chunk's body.
    pad: bool,
    rate: u32,
    channels: u16,
    have_format: bool,
    problem: Problem,
    /// Samples written to the output, and whether some did not fit.
    count: u32,
    cut: bool,

    pub fn init(self: *Decoder) void {
        self.state = .riff;
        self.carry_len = 0;
        self.need = 12;
        self.left = 0;
        self.pad = false;
        self.rate = 0;
        self.channels = 0;
        self.have_format = false;
        self.problem = .none;
        self.count = 0;
        self.cut = false;
        assert(self.need <= carry_cap);
    }

    /// Bytes of one sample frame of the data.
    fn frame_bytes(self: *const Decoder) u32 {
        assert(self.channels == 1 or self.channels == 2);
        return 2 * @as(u32, self.channels);
    }

    /// Decodes `bytes`, the next piece of the file, writing samples to `out[count..]`.
    pub fn feed(self: *Decoder, bytes: []const u8, out: []f32) void {
        assert(self.count <= out.len);
        var rest = bytes;
        var guard: usize = 0;
        while (rest.len > 0 and self.state != .stopped) : (guard += 1) {
            assert(guard <= bytes.len + 8);
            switch (self.state) {
                .riff, .header, .format => {
                    const take = @min(self.need - self.carry_len, rest.len);
                    @memcpy(self.carry[self.carry_len..][0..take], rest[0..take]);
                    self.carry_len += @intCast(take);
                    rest = rest[take..];
                    if (self.carry_len == self.need) self.item();
                },
                .skip => {
                    const take: usize = @intCast(@min(self.left, rest.len));
                    self.left -= take;
                    rest = rest[take..];
                    if (self.left == 0) self.expect_header();
                },
                .data => rest = self.samples(rest, out),
                .stopped => unreachable,
            }
        }
        assert(self.count <= out.len);
    }

    /// A complete header item is in `carry`.
    fn item(self: *Decoder) void {
        const at = self.carry[0..self.need];
        self.carry_len = 0;
        switch (self.state) {
            .riff => {
                if (!std.mem.eql(u8, at[0..4], "RIFF") or !std.mem.eql(u8, at[8..12], "WAVE")) {
                    return self.stop(.not_riff);
                }
                self.expect_header();
            },
            .header => {
                const size = std.mem.readInt(u32, at[4..8], .little);
                self.pad = size % 2 == 1;
                if (std.mem.eql(u8, at[0..4], "fmt ")) {
                    if (size < 16 or size > carry_cap) return self.stop(.not_pcm16);
                    self.state = .format;
                    self.need = size;
                } else if (std.mem.eql(u8, at[0..4], "data")) {
                    if (!self.have_format) return self.stop(.no_format);
                    self.state = .data;
                    self.left = size;
                } else {
                    self.skip_body(size);
                }
            },
            .format => {
                const tag = std.mem.readInt(u16, at[0..2], .little);
                const channels = std.mem.readInt(u16, at[2..4], .little);
                const bits = std.mem.readInt(u16, at[14..16], .little);
                const pcm = tag == 1 or tag == 0xFFFE;
                if (!pcm or bits != 16 or channels == 0 or channels > 2) return self.stop(.not_pcm16);
                self.channels = channels;
                self.rate = std.mem.readInt(u32, at[4..8], .little);
                self.have_format = true;
                self.skip_body(0);
            },
            .skip, .data, .stopped => unreachable,
        }
    }

    /// Skips `size` bytes and the pad byte, then reads the next chunk header.
    fn skip_body(self: *Decoder, size: u64) void {
        self.left = size + @intFromBool(self.pad);
        self.pad = false;
        if (self.left == 0) return self.expect_header();
        self.state = .skip;
    }

    fn expect_header(self: *Decoder) void {
        self.state = .header;
        self.need = 8;
        self.carry_len = 0;
    }

    fn stop(self: *Decoder, problem: Problem) void {
        assert(problem != .none);
        self.problem = problem;
        self.state = .stopped;
    }

    /// Converts whole frames of `rest` (completing a carried one first) and returns what is
    /// left after the data chunk, or nothing.
    fn samples(self: *Decoder, rest: []const u8, out: []f32) []const u8 {
        const frame = self.frame_bytes();
        var data = rest[0..@intCast(@min(self.left, rest.len))];
        const after = rest[data.len..];
        self.left -= data.len;
        if (self.carry_len > 0) {
            const take = @min(frame - self.carry_len, data.len);
            @memcpy(self.carry[self.carry_len..][0..take], data[0..take]);
            self.carry_len += @intCast(take);
            data = data[take..];
            if (self.carry_len == frame) {
                self.put(self.carry[0..2], out);
                self.carry_len = 0;
            }
        }
        const whole = data.len / frame * frame;
        var offset: usize = 0;
        while (offset < whole) : (offset += frame) self.put(data[offset..][0..2], out);
        const tail = data[whole..];
        @memcpy(self.carry[0..tail.len], tail);
        self.carry_len = @intCast(tail.len);
        if (self.left == 0) {
            self.state = .stopped;
            return &.{};
        }
        assert(after.len == 0);
        return after;
    }

    fn put(self: *Decoder, sample: *const [2]u8, out: []f32) void {
        if (self.count == out.len) {
            self.cut = true;
            return;
        }
        const value = std.mem.readInt(i16, sample, .little);
        out[self.count] = @as(f32, @floatFromInt(value)) / 32768;
        self.count += 1;
    }

    /// Seconds of the samples decoded so far.
    pub fn seconds(self: *const Decoder) f32 {
        assert(self.rate > 0);
        return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.rate));
    }
};

/// A canonical 44-byte header of 16-bit PCM WAV with `channels` at `rate` and `data_bytes` of
/// samples: the gallery's scenario file and the tests use it.
pub fn header(rate: u32, channels: u16, data_bytes: u32) [44]u8 {
    var out: [44]u8 = undefined;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_bytes, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * 2 * channels, .little);
    std.mem.writeInt(u16, out[32..34], 2 * channels, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_bytes, .little);
    return out;
}

const testing = std.testing;

/// A stereo file with a LIST chunk of odd length before its data: 6 frames, L = i * 1000,
/// R = -1.
fn stereo_file() [44 + 12 + 24]u8 {
    var out: [44 + 12 + 24]u8 = undefined;
    const head = header(44100, 2, 24);
    @memcpy(out[0..36], head[0..36]);
    @memcpy(out[36..40], "LIST");
    std.mem.writeInt(u32, out[40..44], 3, .little);
    @memcpy(out[44..48], "abc\x00");
    @memcpy(out[48..56], head[36..44]);
    for (0..6) |frame| {
        std.mem.writeInt(i16, out[56 + 4 * frame ..][0..2], @intCast(frame * 1000), .little);
        std.mem.writeInt(i16, out[56 + 4 * frame + 2 ..][0..2], -1, .little);
    }
    std.mem.writeInt(u32, out[4..8], out.len - 8, .little);
    return out;
}

// Locks streaming across every split: a stereo file with an odd-length LIST chunk decodes to
// the same six left samples whether it arrives whole or in two pieces split at any byte.
test "every split decodes the same samples" {
    const file = stereo_file();
    var split: usize = 0;
    while (split <= file.len) : (split += 1) {
        var decoder: Decoder = undefined;
        decoder.init();
        var out: [8]f32 = undefined;
        decoder.feed(file[0..split], &out);
        decoder.feed(file[split..], &out);
        try testing.expectEqual(Problem.none, decoder.problem);
        try testing.expectEqual(@as(u32, 6), decoder.count);
        try testing.expectEqual(@as(u32, 44100), decoder.rate);
        try testing.expectEqual(@as(u16, 2), decoder.channels);
        for (out[0..6], 0..) |sample, frame| {
            try testing.expectEqual(@as(f32, @floatFromInt(frame * 1000)) / 32768, sample);
        }
    }
}

// Locks the refusals and the cut: 24-bit PCM is not 16-bit, a non-RIFF file is refused, and
// samples past the output set `cut`.
test "other formats are refused and a full output cuts" {
    var decoder: Decoder = undefined;
    decoder.init();
    var head = header(48000, 1, 6);
    std.mem.writeInt(u16, head[34..36], 24, .little);
    var out: [2]f32 = undefined;
    decoder.feed(&head, &out);
    try testing.expectEqual(Problem.not_pcm16, decoder.problem);
    decoder.init();
    decoder.feed("RIFX\x00\x00\x00\x00WAVE", &out);
    try testing.expectEqual(Problem.not_riff, decoder.problem);
    decoder.init();
    const mono = header(48000, 1, 6);
    decoder.feed(&mono, &out);
    decoder.feed(&.{ 0, 64, 0, 192, 1, 0 }, &out);
    try testing.expectEqual(@as(u32, 2), decoder.count);
    try testing.expect(decoder.cut);
    try testing.expectEqual(@as(f32, 0.5), out[0]);
    try testing.expectEqual(@as(f32, -0.5), out[1]);
}

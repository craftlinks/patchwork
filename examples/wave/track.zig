//! The wave example's synthetic track and the analysis its views show: band envelopes for the
//! DJ waveform and DFT columns for the spectrogram.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Track
//! `seconds` at `sample_rate`, generated in `fill`, deterministic and with no asset. At 120 BPM
//! a beat is `beat_samples`:
//! ```text
//! kick   every beat:      sin(phase), f = 40 + 15 exp(-30 t) Hz, amplitude 0.9 exp(-8 t)
//! bass   every eighth:    0.35 exp(-6 t) (sin(w t) + 0.3 sin(3 w t)), w from bass_hz
//! hats   on the off-beat: 0.25 exp(-40 t) times high-passed xorshift noise
//! swell  the whole track: 0.12 (0.5 - 0.5 cos(2 pi s / seconds)) sin(2 pi 220 s)
//! ```
//! with `t` the seconds since the event's start and `s` the seconds since the track's start;
//! the sum is clamped to [-1, 1].
//!
//! ## 2. Bands
//! One-pole low-passes (`y += a (x - y)`, `a = 1 - exp(-2 pi fc / sample_rate)`) at 150 and
//! 3,000 Hz split the track into low, mid (3 kHz minus 150 Hz), and high (the rest). Per tick
//! block of `tick_samples`, each band's peak magnitude times its gain goes through `sqrt` (a
//! louder look for quiet bands) and is stored as one `rgba8` texel: r low, g mid, b high.
//!
//! ## 3. Spectrum
//! A `window` sample Hann-windowed DFT ending at the tick's last sample (zeros before the
//! track), evaluated at `bins` log-spaced frequencies `f_b = 40 (10000 / 40)^(b / (bins - 1))`
//! Hz, so the kick and the bass get rows instead of the bottom two of a linear axis. Each bin
//! rotates a phasor by `2 pi f_b / sample_rate` per sample (`Analyzer.steps`): `window * bins`
//! multiply-adds per column. Magnitudes `|X_b| / (window / 4)` (a full-scale sine is 0 dB)
//! are mapped from [`db_floor`, 0] dB to [0, 1], one `f16` per bin with the highest frequency
//! in row 0 (the top).
//!
//! ## 4. TigerStyle Invariants
//! Every function is bounded by `sample_count`, `tick_count`, or `window * bins`.

const std = @import("std");
const assert = std.debug.assert;

pub const sample_rate: u32 = 22_050;
pub const seconds: u32 = 16;
pub const sample_count: u32 = sample_rate * seconds;
/// Samples per tick: 20 ms, the app timer's period.
pub const tick_samples: u32 = 441;
pub const tick_count: u32 = sample_count / tick_samples;
pub const beat_samples: u32 = sample_rate / 2;
pub const window: u32 = 512;
pub const bins: u32 = 128;

const bass_hz = [4]f32{ 55, 55, 65.41, 49 };
const low_hz: f32 = 150;
const high_hz: f32 = 3000;
const gains = [3]f32{ 1.0, 1.0, 3.0 };
const db_floor: f32 = -70;
const f_lo: f32 = 40;
const f_hi: f32 = 10_000;

comptime {
    assert(sample_count % tick_samples == 0);
    assert(tick_count == 800);
    assert(window == 4 * bins);
}

/// Writes the track (section 1).
pub fn fill(out: *[sample_count]f32) void {
    const rate: f32 = @floatFromInt(sample_rate);
    var noise_state: u32 = 0x9E37_79B9;
    var noise_last: f32 = 0;
    var kick_phase: f32 = 0;
    for (out, 0..) |*sample, index_usize| {
        const index: u32 = @intCast(index_usize);
        const s = @as(f32, @floatFromInt(index)) / rate;
        const beat_t = @as(f32, @floatFromInt(index % beat_samples)) / rate;
        const kick_hz = 40 + 15 * @exp(-30 * beat_t);
        if (index % beat_samples == 0) kick_phase = 0;
        kick_phase += std.math.tau * kick_hz / rate;
        const kick = 0.9 * @exp(-8 * beat_t) * @sin(kick_phase);
        const eighth = beat_samples / 2;
        const eighth_t = @as(f32, @floatFromInt(index % eighth)) / rate;
        const note = bass_hz[(index / eighth) % bass_hz.len];
        const w = std.math.tau * note * eighth_t;
        const bass = 0.35 * @exp(-6 * eighth_t) * (@sin(w) + 0.3 * @sin(3 * w));
        noise_state ^= noise_state << 13;
        noise_state ^= noise_state >> 17;
        noise_state ^= noise_state << 5;
        const noise = @as(f32, @floatFromInt(noise_state >> 8)) / 8_388_608.0 - 1;
        const high_passed = noise - noise_last;
        noise_last = noise;
        const off = (index + eighth) % beat_samples;
        const hat_t = @as(f32, @floatFromInt(off)) / rate;
        const hats = 0.25 * @exp(-40 * hat_t) * high_passed * 0.5;
        const total: f32 = @floatFromInt(seconds);
        const swell = 0.12 * (0.5 - 0.5 * @cos(std.math.tau * s / total)) *
            @sin(std.math.tau * 220 * s);
        sample.* = std.math.clamp(kick + bass + hats + swell, -1, 1);
    }
}

/// Writes one `rgba8` texel per tick block (section 2).
pub fn fill_bands(track: *const [sample_count]f32, out: *[tick_count][4]u8) void {
    const rate: f32 = @floatFromInt(sample_rate);
    const a_low = 1 - @exp(-std.math.tau * low_hz / rate);
    const a_high = 1 - @exp(-std.math.tau * high_hz / rate);
    var below_low: f32 = 0;
    var below_high: f32 = 0;
    for (out, 0..) |*texel, tick| {
        var peaks = [3]f32{ 0, 0, 0 };
        for (track[tick * tick_samples ..][0..tick_samples]) |x| {
            below_low += a_low * (x - below_low);
            below_high += a_high * (x - below_high);
            const bands = [3]f32{ below_low, below_high - below_low, x - below_high };
            for (&peaks, bands) |*peak, band| peak.* = @max(peak.*, @abs(band));
        }
        for (0..3) |band| {
            const level = @sqrt(@min(1, peaks[band] * gains[band]));
            texel[band] = @intFromFloat(@round(level * 255));
        }
        texel[3] = 255;
    }
}

/// The window and the per-bin phasor steps `spectrum` reads (section 3).
pub const Analyzer = struct {
    hann: [window]f32,
    /// `(cos w, sin w)` with `w = 2 pi f_b / sample_rate`.
    steps: [bins][2]f32,

    pub fn init(self: *Analyzer) void {
        const n: f32 = @floatFromInt(window);
        for (&self.hann, 0..) |*value, index| {
            value.* = 0.5 - 0.5 * @cos(std.math.tau * @as(f32, @floatFromInt(index)) / n);
        }
        for (&self.steps, 0..) |*step, bin| {
            const w = std.math.tau * frequency(@intCast(bin)) / @as(f32, @floatFromInt(sample_rate));
            step.* = .{ @cos(w), @sin(w) };
        }
    }
};

/// The frequency of `bin`, in hertz (section 3).
pub fn frequency(bin: u32) f32 {
    assert(bin < bins);
    const fraction = @as(f32, @floatFromInt(bin)) / @as(f32, @floatFromInt(bins - 1));
    return f_lo * std.math.pow(f32, f_hi / f_lo, fraction);
}

/// One spectrogram column for the window ending at sample `end` (section 3).
pub fn spectrum(
    track: *const [sample_count]f32,
    analyzer: *const Analyzer,
    end: u32,
    out: *[bins]f16,
) void {
    assert(end <= sample_count);
    var windowed: [window]f32 = undefined;
    for (&windowed, 0..) |*value, index| {
        const at = @as(i64, end) - window + @as(i64, @intCast(index));
        const raw: f32 = if (at >= 0) track[@intCast(at)] else 0;
        value.* = raw * analyzer.hann[index];
    }
    for (0..bins) |bin| {
        const step = analyzer.steps[bin];
        var c: f32 = 1;
        var s: f32 = 0;
        var re: f32 = 0;
        var im: f32 = 0;
        for (windowed) |value| {
            re += value * c;
            im -= value * s;
            const next = c * step[0] - s * step[1];
            s = s * step[0] + c * step[1];
            c = next;
        }
        const magnitude = @sqrt(re * re + im * im) / (window / 4);
        const db = 20 * std.math.log10(magnitude + 1e-6);
        const level = std.math.clamp((db - db_floor) / -db_floor, 0, 1);
        out[bins - 1 - bin] = @floatCast(level);
    }
}

// Locks the analysis on worked inputs: the bins span 40 Hz to 10 kHz; a full-scale sine at
// bin 64's frequency peaks in bin 64 (row 63) near 0 dB and leaves a far bin near the floor;
// and on the track, the kick at tick 0 is louder in the low band than the decayed kick at
// tick 20, while the off-beat hat at tick 13 is brighter in the high band than tick 5.
test "the spectrum finds a sine and the bands follow the beat" {
    const static = struct {
        var track: [sample_count]f32 = undefined;
        var bands: [tick_count][4]u8 = undefined;
    };
    var analyzer: Analyzer = undefined;
    analyzer.init();
    try std.testing.expectApproxEqAbs(@as(f32, 40), frequency(0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 10_000), frequency(bins - 1), 0.1);
    const w = std.math.tau * frequency(64) / @as(f32, @floatFromInt(sample_rate));
    for (static.track[0..window], 0..) |*sample, index| {
        sample.* = @sin(w * @as(f32, @floatFromInt(index)));
    }
    var column: [bins]f16 = undefined;
    spectrum(&static.track, &analyzer, window, &column);
    try std.testing.expect(column[bins - 1 - 64] > 0.95);
    try std.testing.expect(column[bins - 1 - 10] < 0.2);
    fill(&static.track);
    fill_bands(&static.track, &static.bands);
    try std.testing.expect(static.bands[0][0] > static.bands[20][0]);
    try std.testing.expect(static.bands[13][2] > static.bands[5][2]);
    try std.testing.expectEqual(@as(u8, 255), static.bands[7][3]);
}

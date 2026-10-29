//! The session's sound, made up: four channels as pure functions of time, so meters, scopes,
//! and spectra move while the transport plays and every frame is the same in every host.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Synthesized
//! The screen is about drawing, not audio. Each channel is `sample(channel, t)` with `t` in
//! seconds, so a scope is `scope_points` calls, a level is the RMS of `level_samples` calls,
//! and a spectrum is a sum of Gaussian bumps at the channel's partials. Nothing is stored and
//! nothing allocates; the regress clock gives the same picture natively and in the browser.
//!
//! ## 2. Channels
//! ```text
//! bass  55 Hz sine through a decaying envelope every half second
//! pads  three detuned saws (A minor) under a slow swell
//! line  a square arpeggio stepping every quarter second
//! wet   hashed noise under the pads' swell
//! ```
//!
//! ## 3. TigerStyle Invariants
//! - Pure functions; every loop is bounded by a named constant.

const std = @import("std");
const assert = std.debug.assert;

pub const channel_count: u32 = 4;
pub const bass: u32 = 0;
pub const pads: u32 = 1;
pub const line: u32 = 2;
pub const wet: u32 = 3;

/// Points of one scope trace.
pub const scope_points: u32 = 72;
/// Seconds one scope trace spans.
pub const scope_span_s: f32 = 0.018;
/// Bins of one spectrum, low to high on a log axis from `bin_lo_hz` to `bin_hi_hz`.
pub const bins: u32 = 48;
pub const bin_lo_hz: f32 = 30;
pub const bin_hi_hz: f32 = 16000;
/// Samples a level averages, over `level_span_s`.
pub const level_samples: u32 = 48;
pub const level_span_s: f32 = 0.05;
/// Partials a channel's spectrum sums at most.
const partials_max: u32 = 8;

const tau: f32 = 2 * std.math.pi;

/// The value of `channel` at `t` seconds, in `[-1, 1]`.
pub fn sample(channel: u32, t: f32) f32 {
    assert(channel < channel_count);
    assert(t >= 0);
    const value = switch (channel) {
        bass => @sin(tau * 55 * t) * envelope(t, 0.5, 5) * 0.9,
        pads => (saw(220 * t) + saw(261.6 * t * 1.003) + saw(329.6 * t * 0.997)) * swell(t) * 0.28,
        line => square(arp_hz(t) * t) * envelope(t, 0.25, 7) * 0.55,
        wet => (noise(t * 9000) * 0.6 + @sin(tau * 110 * t) * 0.2) * swell(t) * 0.6,
        else => unreachable,
    };
    assert(value >= -1 and value <= 1);
    return value;
}

/// The RMS of `channel` over the `level_span_s` before `t`, in `[0, 1]`.
pub fn level(channel: u32, t: f32) f32 {
    assert(channel < channel_count);
    var sum: f32 = 0;
    var index: u32 = 0;
    while (index < level_samples) : (index += 1) {
        const at = @max(0, t - level_span_s * @as(f32, @floatFromInt(index)) / level_samples);
        const value = sample(channel, at);
        sum += value * value;
    }
    const rms = @sqrt(sum / @as(f32, level_samples));
    assert(rms >= 0 and rms <= 1);
    return rms;
}

/// The scope trace of `channel` ending at `t`: `scope_points` values in `[-1, 1]`.
pub fn scope(out: *[scope_points]f32, channel: u32, t: f32) void {
    assert(channel < channel_count);
    for (out, 0..) |*value, index| {
        const at = @max(0, t - scope_span_s * @as(f32, @floatFromInt(scope_points - 1 - index)) / scope_points);
        value.* = sample(channel, at);
    }
}

/// The spectrum of `channel` at `t`: `bins` magnitudes in `[0, 1]`, low frequencies first.
pub fn spectrum(out: *[bins]f32, channel: u32, t: f32) void {
    assert(channel < channel_count);
    var hz: [partials_max]f32 = @splat(0);
    var gain: [partials_max]f32 = @splat(0);
    const count = partials(channel, t, &hz, &gain);
    assert(count <= partials_max);
    for (out, 0..) |*value, bin| {
        const position = @as(f32, @floatFromInt(bin)) / @as(f32, bins - 1);
        const at_hz = bin_lo_hz * std.math.pow(f32, bin_hi_hz / bin_lo_hz, position);
        var sum: f32 = 0.04 + 0.05 * noise(t * 31 + @as(f32, @floatFromInt(bin)) * 7.3);
        for (hz[0..count], gain[0..count]) |partial, amount| {
            const distance = @log2(at_hz / partial) * 3;
            sum += amount * @exp(-distance * distance);
        }
        value.* = std.math.clamp(sum, 0, 1);
    }
}

/// Fills the partials of `channel` at `t`; returns how many.
fn partials(channel: u32, t: f32, hz: *[partials_max]f32, gain: *[partials_max]f32) u32 {
    switch (channel) {
        bass => {
            const env = envelope(t, 0.5, 5);
            hz[0..3].* = .{ 55, 110, 165 };
            gain[0..3].* = .{ 0.9 * env + 0.1, 0.45 * env, 0.2 * env };
            return 3;
        },
        pads => {
            const s = swell(t);
            hz[0..6].* = .{ 220, 261.6, 329.6, 440, 659, 1320 };
            gain[0..6].* = .{ 0.6 * s, 0.55 * s, 0.5 * s, 0.35 * s, 0.25 * s, 0.15 * s };
            return 6;
        },
        line => {
            const f = arp_hz(t);
            const env = envelope(t, 0.25, 7);
            hz[0..4].* = .{ f, 3 * f, 5 * f, 7 * f };
            gain[0..4].* = .{ 0.8 * env, 0.3 * env, 0.18 * env, 0.12 * env };
            return 4;
        },
        wet => {
            const s = swell(t);
            hz[0..5].* = .{ 110, 900, 2400, 5200, 9000 };
            gain[0..5].* = .{ 0.3 * s, 0.35 * s, 0.4 * s, 0.35 * s, 0.25 * s };
            return 5;
        },
        else => unreachable,
    }
}

/// A decay restarting every `period` seconds at `rate` per second.
fn envelope(t: f32, period: f32, rate: f32) f32 {
    const phase = t - period * @floor(t / period);
    return @exp(-rate * phase);
}

/// A slow swell in `[0.4, 1]` with a 6.4 s period.
fn swell(t: f32) f32 {
    return 0.7 + 0.3 * @sin(tau * t / 6.4);
}

/// The arpeggio's pitch at `t`: four notes, a quarter second each.
fn arp_hz(t: f32) f32 {
    const notes = [_]f32{ 440, 523.3, 659.3, 784 };
    const step: u32 = @intFromFloat(@mod(@floor(t * 4), 4));
    return notes[step];
}

fn saw(cycles: f32) f32 {
    return 2 * (cycles - @floor(cycles)) - 1;
}

fn square(cycles: f32) f32 {
    return if (cycles - @floor(cycles) < 0.5) 1 else -1;
}

/// A hash of `x` mapped to `[-1, 1]`: deterministic noise.
pub fn noise(x: f32) f32 {
    const bits: u32 = @bitCast(@floor(x));
    var h = bits *% 0x9E3779B1;
    h ^= h >> 15;
    h *%= 0x85EBCA77;
    h ^= h >> 13;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 32767.5 - 1;
}

/// `amplitude` (RMS in `[0, 1]`) in decibels, at least `floor_db`.
pub fn decibels(amplitude: f32, floor_db: f32) f32 {
    assert(amplitude >= 0);
    if (amplitude <= 0) return floor_db;
    return @max(floor_db, 20 * @log10(amplitude));
}

// Locks the channels' ranges and the level of a known signal: every sample of every channel
// stays in [-1, 1] over the first ten seconds, and the bass level right after a beat is near
// the RMS of a 0.9 sine under a fast decay (0.45 to 0.65).
test "signals stay in range and levels are RMS" {
    var channel: u32 = 0;
    while (channel < channel_count) : (channel += 1) {
        var index: u32 = 0;
        while (index < 2000) : (index += 1) {
            const value = sample(channel, @as(f32, @floatFromInt(index)) * 0.005);
            try std.testing.expect(value >= -1 and value <= 1);
        }
    }
    const bass_level = level(bass, 0.06);
    try std.testing.expect(bass_level > 0.45 and bass_level < 0.65);
    var bars: [bins]f32 = undefined;
    spectrum(&bars, pads, 1.5);
    for (bars) |value| try std.testing.expect(value >= 0 and value <= 1);
    try std.testing.expectEqual(@as(f32, -60), decibels(0, -60));
}

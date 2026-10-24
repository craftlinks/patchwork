//! The live screen's bench scenarios (`patchwork.bench`), run with
//! `zig build bench-live -Doptimize=ReleaseFast -- <name> [--adapter low|high]`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What They Measure
//! The four runs the step-18 measurements used, so later steps compare against the same
//! frames:
//! - `transport` presses play and measures the 30 Hz ticks the app timer presents: the
//!   playhead and lane rings move, the editor does not.
//! - `typing` clicks into the editor and alternates `x` and Backspace, one key per frame.
//! - `transport-stress` and `typing-stress` do the same after F2 loads the 2,000-line text,
//!   whose 64 bound literals draw a curve each across the screen.
//! - `idle` presents frames in which nothing changed: with the pixel cache on, every one is
//!   skipped (no pass, no present, only the frame callback's commit natively).
//! - `pulse` arms record while paused and measures the animation-only frames its glow keeps
//!   presenting: no `App.draw`, a 16-byte time write, and the glow's tiles repainted.
//!
//! ## 2. Setup
//! Each setup waits a few frames first, so the glyph cache has rasterized what the first
//! frames drew and the measured frames start from a settled screen. The typing click lands on
//! the editor's thirteenth visible line, 300 logical pixels in, which holds text in both texts.

const patchwork = @import("patchwork");
const bench = patchwork.bench;

const settle_frames: u32 = 5;
const measured_frames: u32 = 300;

const play = bench.area("transport", 1);
const record = bench.area("transport", 2);
const editor = bench.area("editor", 0);

/// A point on the editor's thirteenth line (21 px lines), past the line numbers.
const into_editor: bench.Step = .{ .click_at = .{ .target = editor, .x = 300, .y = 21 * 12 + 10 } };
const load_stress: bench.Step = .{ .key = .{ .key = .f2, .text = "" } };
const settle: bench.Step = .{ .wait = settle_frames };

const typing_cycle = [_]bench.Step{
    .{ .key = .{ .key = .x, .text = "x" } },
    .{ .key = .{ .key = .backspace, .text = "" } },
};

pub const scenarios = [_]bench.Scenario{
    .{
        .name = "idle",
        .setup = &.{settle},
        .cycle = &.{.{ .wait = 1 }},
        .frames = measured_frames,
    },
    .{
        .name = "pulse",
        .setup = &.{ settle, .{ .click = record }, settle },
        .cycle = &.{.{ .wait = 1 }},
        .frames = measured_frames,
    },
    .{
        .name = "transport",
        .setup = &.{ settle, .{ .click = play }, settle },
        .cycle = &.{},
        .frames = measured_frames,
    },
    .{
        .name = "typing",
        .setup = &.{ settle, into_editor, settle },
        .cycle = &typing_cycle,
        .frames = measured_frames,
    },
    .{
        .name = "transport-stress",
        .setup = &.{ load_stress, settle, .{ .click = play }, settle },
        .cycle = &.{},
        .frames = measured_frames,
    },
    .{
        .name = "typing-stress",
        .setup = &.{ load_stress, settle, into_editor, settle },
        .cycle = &typing_cycle,
        .frames = measured_frames,
    },
};

comptime {
    if (bench.validate(&scenarios)) |message| @compileError(message);
}

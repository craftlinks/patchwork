//! The app contract: the calls both hosts make on an application.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Comptime Contract, Not a Vtable
//! Each host is compiled once per app and per target, so the app type is known at compile
//! time and the hosts call `App.init`, `App.event`, and the rest as ordinary functions: no
//! function pointer, no dynamic dispatch, no allocation. `check` turns a missing or mistyped
//! declaration into a build error that names it.
//!
//! ## 2. The Contract
//! ```text
//! pub const App = struct {
//!     pub const config: patchwork.app.Config = .{
//!         .title = "...",
//!         .timer_period_ms = 0,
//!         .draw = &.{
//!             .{ .type = patchwork.draw.Box, .cap = 64 },
//!             .{ .type = patchwork.draw.Glyph, .cap = 256 },
//!         },
//!     };
//!     pub fn init(app: *App, textures: *patchwork.draw.Textures) void
//!     pub fn event(app: *App, cx: *patchwork.app.Context(App), event: patchwork.input.Event) void
//!     pub fn timer(app: *App, cx: *patchwork.app.Context(App), now_ms: u64) void
//!     pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void
//! };
//! ```
//! - `init` runs once before any other call. It may create textures and queue their pixels;
//!   the renderer records them into the next stream, so `init` may run before the GPU device
//!   exists. Queued bytes must stay valid until then.
//! - `event` applies one pointer, wheel, key, paste, window focus, or `frame` event
//!   (`input.Event`); the `frame` event carries the animator step in milliseconds. The
//!   app routes it to each widget's `handle`, which resolves it with `cx.hit` against the
//!   areas of the last draw (`ui/cx.zig`), or reads keys when `cx.focused(id)`. A visible
//!   change calls `cx.redraw()`; an animator still moving calls `cx.keep_animating()`, which
//!   gates frame callbacks, so a settled app costs nothing.
//! - `timer` runs when the host timer expires and calls `cx.redraw()` when a visible value
//!   changed. When `config.timer_period_ms` is 0 the hosts never call it.
//! - `draw` lays out and appends every instance into the reset context, recording hit areas
//!   as it goes. There is no separate layout call: the window size is `cx.window`, and a
//!   resize only marks a draw as owed. The hosts call `draw` when `cx.dirty` is set or when
//!   the context's glyph cache owes a draw (`text/cache.zig`: the display scale changed, or
//!   glyphs were skipped for the per-frame budget or a full atlas), so `draw` must be
//!   repeatable: unchanged state draws the same instances again. It must not call `redraw`.
//! - `cx.set_timer(on)` during `event` or `timer` starts or stops the host timer of an app
//!   that declared a period (section 4).
//!
//! ## 2a. Draw Configuration
//! `config.draw` lists the app's draw types and the instances each pool holds per frame; a
//! type's id is its index. `config.batch_cap` (default 256) bounds the batches per frame and
//! `config.area_cap` (default 1024) the hit areas. `config.point_cap` (default 65536) sizes the
//! point pool that `draw.Path` strokes read; it is allocated only when a registered type
//! declares `reads_points` (`draw/pools.zig`, section 5b). `Context(App)` is the UI context
//! built from them (`ui.Context`, which embeds the draw context as `cx.draw`). `check` rejects
//! an empty or oversized list, a type that breaks the instance convention (the message names
//! the type; see `draw/registry.zig`), a zero cap, a `batch_cap` whose worst frame would not
//! fit one command buffer, an `area_cap` outside `1 .. areas.area_cap_max`, and a
//! `point_cap` outside `1 .. pools.point_cap_max`.
//!
//! ## 3. Host Order Per Wake
//! Drain queued events through `ui.dispatch`. When a frame callback completes, call
//! `ui.animate`, which dispatches `.frame` and reports whether to keep animating. When the
//! timer expires, call `timer`. A changed window size calls `cx.redraw()`. At present time
//! `ui.draw_frame` draws if `cx.dirty` or the glyph cache owes a draw, then re-resolves hover
//! under the pointer. After presenting, a context that is dirty again or a cache that still
//! owes a draw requests another frame.
//!
//! ## 4. The Optional Timer
//! `timer_period_ms == 0` means no timer. The native host then creates no `timerfd` and
//! sleeps in `poll` while nothing is live. The browser host arms no `setInterval`.
//! `timer_period_ms_max` bounds the period so a value in the wrong unit fails the build.
//! With a period, the timer runs from startup when `timer_armed` is true (the default), and
//! the app starts and stops it at run time with `cx.set_timer(on)` (`ui/cx.zig`, section 9):
//! after each call into the app the hosts arm or disarm it to match `cx.timer_on`, so a
//! stopped timer wakes nothing and calls no `timer`. `start_timer(App, cx)` is the one setup
//! both hosts (and app tests) run after `cx.init`.
//!
//! ## 5. TigerStyle Invariants
//! The contract is checked at compile time and costs nothing at run time. The app owns all
//! of its storage, sized by its own comptime constants.

const std = @import("std");
const assert = std.debug.assert;
const quads = @import("draw.zig");
const commands = @import("gpu/commands.zig");
const input = @import("input.zig");
const registry = @import("draw/registry.zig");
const renderer = @import("draw/renderer.zig");
const ui = @import("ui.zig");
const areas = @import("ui/areas.zig");
const pools = @import("draw/pools.zig");

/// Per-app settings the hosts read at compile time. Comptime-only, because `draw` names types.
pub const Config = struct {
    /// Window title on native. The browser page sets its own title.
    title: [:0]const u8,
    /// Host timer period in milliseconds. 0 means no timer.
    timer_period_ms: u32,
    /// Whether the timer runs from startup; `cx.set_timer` starts and stops it later.
    /// Ignored when `timer_period_ms` is 0.
    timer_armed: bool = true,
    /// The app's draw types and their pool capacities; a type's id is its index.
    draw: []const quads.DrawType,
    /// Upper bound on batches per frame: distinct (layer, type, texture) runs.
    batch_cap: u32 = 256,
    /// Upper bound on hit areas per frame; the rest are counted and not hittable.
    area_cap: u32 = 1024,
    /// Upper bound on path points per frame, when a registered type reads points.
    point_cap: u32 = 65536,
};

/// The UI context type `App.event`, `App.timer`, and `App.draw` receive, built from
/// `App.config`.
pub fn Context(comptime App: type) type {
    const Draw = quads.Context(App.config.draw, App.config.batch_cap, App.config.point_cap);
    return ui.Context(Draw, App.config.area_cap);
}

/// Records `App.config`'s timer in a freshly initialized context (section 4). Both hosts call
/// it after `cx.init`; app tests call it to start where a host starts.
pub fn start_timer(comptime App: type, cx: *Context(App)) void {
    cx.timer_setup(App.config.timer_period_ms, App.config.timer_armed);
    if (App.config.timer_period_ms == 0) assert(!cx.timer_on);
}

/// Upper bound for `Config.timer_period_ms`, chosen so a period given in the wrong unit is
/// rejected at build time. The failure message in `conformance` repeats the number, which the
/// comptime assert at the end of this file and the "slow timer" test keep in sync.
pub const timer_period_ms_max: u32 = 1000;

/// Returns null when `App` satisfies the contract, otherwise a message naming the first
/// problem. Pure, so tests can check failure cases without a compile error. Signature types
/// are compared exactly.
pub fn conformance(comptime App: type) ?[]const u8 {
    // Comparing the signatures instantiates `Context(App)`: the draw pools, the registry's
    // generated tables, and the UI context. That comptime work exceeds the default quota of
    // 1000 backward branches for an app with several draw types.
    @setEvalBranchQuota(20_000);
    if (!@hasDecl(App, "config")) {
        return "App must declare `pub const config: patchwork.app.Config`";
    }
    if (@TypeOf(App.config) != Config) {
        return "App.config must have type patchwork.app.Config";
    }
    if (App.config.timer_period_ms > timer_period_ms_max) {
        return "App.config.timer_period_ms must be at most 1000";
    }
    if (registry.validate(App.config.draw)) |message| {
        return message;
    }
    if (App.config.batch_cap == 0) {
        return "App.config.batch_cap must be at least 1";
    }
    const frame_bytes = renderer.frame_bytes_max(App.config.draw.len, App.config.batch_cap);
    if (frame_bytes > commands.capacity) {
        return "App.config.batch_cap is too large: its worst frame exceeds the command buffer";
    }
    if (App.config.area_cap == 0) {
        return "App.config.area_cap must be at least 1";
    }
    if (App.config.area_cap > areas.area_cap_max) {
        return "App.config.area_cap must be at most 65536";
    }
    if (App.config.point_cap == 0) {
        return "App.config.point_cap must be at least 1";
    }
    if (App.config.point_cap > pools.point_cap_max) {
        return "App.config.point_cap must be at most 65536";
    }
    const names = [_][]const u8{ "init", "event", "timer", "draw" };
    const expected = [_]type{
        fn (*App, *quads.Textures) void,
        fn (*App, *Context(App), input.Event) void,
        fn (*App, *Context(App), u64) void,
        fn (*App, *Context(App)) void,
    };
    inline for (names, expected) |name, signature| {
        if (!@hasDecl(App, name)) {
            return "App is missing `pub fn " ++ name ++ "`";
        }
        const found = @TypeOf(@field(App, name));
        if (found != signature) {
            return "App." ++ name ++ " must have type `" ++ @typeName(signature) ++
                "`, found `" ++ @typeName(found) ++ "`";
        }
    }
    return null;
}

/// Fails the build with a message naming the missing or mistyped declaration.
/// Both host roots call this before they instantiate anything.
pub fn check(comptime App: type) void {
    if (comptime conformance(App)) |message| {
        @compileError(message);
    }
}

const test_draw = [_]quads.DrawType{
    .{ .type = quads.Box, .cap = 4 },
    .{ .type = quads.Glyph, .cap = 4 },
};

/// A draw type whose size is not a multiple of 16 bytes.
const Ragged = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    weight: f32,

    pub const texture: ?quads.TextureFormat = null;
    pub const pixel: []const u8 = "";
};

const RaggedApp = struct {
    pub const config: Config = .{
        .title = "ragged",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = Ragged, .cap = 4 }},
    };
};

const HugeBatches = struct {
    pub const config: Config = .{
        .title = "huge",
        .timer_period_ms = 0,
        .draw = &test_draw,
        .batch_cap = 100_000,
    };
};

const GoodApp = struct {
    pub const config: Config = .{ .title = "good", .timer_period_ms = 0, .draw = &test_draw };
    pub fn init(app: *GoodApp, textures: *quads.Textures) void {
        _ = app;
        _ = textures;
    }
    pub fn event(app: *GoodApp, cx: *Context(GoodApp), event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }
    pub fn timer(app: *GoodApp, cx: *Context(GoodApp), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }
    pub fn draw(app: *GoodApp, cx: *Context(GoodApp)) void {
        _ = app;
        _ = cx;
    }
};

const NoDraw = struct {
    pub const config: Config = .{ .title = "no draw", .timer_period_ms = 0, .draw = &test_draw };
    pub fn init(app: *NoDraw, textures: *quads.Textures) void {
        _ = app;
        _ = textures;
    }
    pub fn event(app: *NoDraw, cx: *Context(NoDraw), event_value: input.Event) void {
        _ = app;
        _ = cx;
        _ = event_value;
    }
    pub fn timer(app: *NoDraw, cx: *Context(NoDraw), now_ms: u64) void {
        _ = app;
        _ = cx;
        _ = now_ms;
    }
};

const NoConfig = struct {
    pub fn init(app: *NoConfig) void {
        _ = app;
    }
};

const SlowTimer = struct {
    pub const config: Config = .{ .title = "slow", .timer_period_ms = 5000, .draw = &test_draw };
};

const NoAreas = struct {
    pub const config: Config = .{
        .title = "no areas",
        .timer_period_ms = 0,
        .draw = &test_draw,
        .area_cap = 0,
    };
};

const HugeAreas = struct {
    pub const config: Config = .{
        .title = "huge areas",
        .timer_period_ms = 0,
        .draw = &test_draw,
        .area_cap = 65537,
    };
};

const HugePoints = struct {
    pub const config: Config = .{
        .title = "huge points",
        .timer_period_ms = 0,
        .draw = &test_draw,
        .point_cap = 65537,
    };
};

const NoPoints = struct {
    pub const config: Config = .{
        .title = "no points",
        .timer_period_ms = 0,
        .draw = &test_draw,
        .point_cap = 0,
    };
};

const OldEvent = struct {
    pub const config: Config = .{ .title = "old", .timer_period_ms = 0, .draw = &test_draw };
    pub fn init(app: *OldEvent, textures: *quads.Textures) void {
        _ = app;
        _ = textures;
    }
    // The step-13 shape: no context, and a dirty flag returned instead of `cx.redraw()`.
    pub fn event(app: *OldEvent, event_value: input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }
};

// Locks the positive space: a complete app passes and pins the exact shape hosts rely on.
test "a complete app satisfies the contract" {
    try std.testing.expect(comptime conformance(GoodApp) == null);
    check(GoodApp);
}

// Locks the negative space: a missing declaration is named in the message. The compile-error
// path of `check` itself is locked by `zig build test-contract`.
test "a missing declaration is reported by name" {
    const missing = comptime conformance(NoDraw).?;
    try std.testing.expect(std.mem.find(u8, missing, "draw") != null);
    try std.testing.expect(!@hasDecl(NoDraw, "draw"));
    try std.testing.expect(@hasDecl(NoDraw, "timer"));
}

// Locks the remaining rejections: missing config, over-limit timer period, and a signature
// mismatch (an `event` of the step-13 shape names the member and the context type).
test "a missing config, a slow timer, and an old event signature are rejected" {
    const no_config = comptime conformance(NoConfig).?;
    try std.testing.expect(std.mem.find(u8, no_config, "config") != null);
    const slow = comptime conformance(SlowTimer).?;
    try std.testing.expect(std.mem.find(u8, slow, "1000") != null);
    const wrong = comptime conformance(OldEvent).?;
    try std.testing.expect(std.mem.find(u8, wrong, "event") != null);
    try std.testing.expect(std.mem.find(u8, wrong, "Context") != null);
}

// Locks the area capacity bounds: zero and one past `area_cap_max` are rejected by name.
test "an area cap of zero or above the maximum is rejected" {
    const none = comptime conformance(NoAreas).?;
    try std.testing.expect(std.mem.find(u8, none, "area_cap") != null);
    const huge = comptime conformance(HugeAreas).?;
    try std.testing.expect(std.mem.find(u8, huge, "65536") != null);
    try std.testing.expectEqual(@as(u32, 65536), areas.area_cap_max);
}

// Locks the point capacity bounds: zero and one past `point_cap_max` are rejected by name.
test "a point cap of zero or above the maximum is rejected" {
    const none = comptime conformance(NoPoints).?;
    try std.testing.expect(std.mem.find(u8, none, "point_cap") != null);
    const huge = comptime conformance(HugePoints).?;
    try std.testing.expect(std.mem.find(u8, huge, "65536") != null);
    try std.testing.expectEqual(@as(u32, 65536), pools.point_cap_max);
}

// Locks the draw configuration rejections: a type that breaks the convention is named, and
// a batch cap whose worst frame overflows the command buffer is refused.
test "a ragged draw type and an oversized batch cap are rejected" {
    const ragged = comptime conformance(RaggedApp).?;
    try std.testing.expect(std.mem.find(u8, ragged, "Ragged") != null);
    try std.testing.expect(std.mem.find(u8, ragged, "multiple of 16") != null);
    const huge = comptime conformance(HugeBatches).?;
    try std.testing.expect(std.mem.find(u8, huge, "batch_cap") != null);
}

comptime {
    assert(timer_period_ms_max == 1000);
}

//! The app contract: the calls both hosts make on an application.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Comptime Contract, Not a Vtable
//! Each host is compiled once per app and per target, so the app type is known at compile
//! time and the hosts call `App.init`, `App.layout`, and the rest as ordinary functions: no
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
//!     pub fn layout(app: *App, width_logical: u32, height_logical: u32) void
//!     pub fn event(app: *App, event: patchwork.input.Event) bool      // true: dirty
//!     pub fn timer(app: *App, now_ms: u64) bool                      // true: dirty
//!     pub fn live(app: *const App) bool
//!     pub fn dirty(app: *const App) bool
//!     pub fn draw(app: *App, cx: *patchwork.app.Context(App)) void
//! };
//! ```
//! - `init` runs once before any other call and leaves the app ready for `layout`. It may
//!   create textures and queue their pixels; the renderer records them into the next stream,
//!   so `init` may run before the GPU device exists. Queued bytes must stay valid until then.
//! - `layout` places the widgets for a window of `width_logical` by `height_logical` UI
//!   logical pixels. Hosts call it only when the logical window size changed (see
//!   `Frame.relayout`). It must leave `dirty()` true so the next `draw` rebuilds the lists.
//! - `event` applies one pointer, wheel, or `frame` event. The `frame` event carries the
//!   animator step in milliseconds. It returns true when a visible value changed.
//! - `timer` runs when the host timer expires. When `config.timer_period_ms` is 0 the hosts
//!   never call it, and it exists only to satisfy the contract.
//! - `live` is true while an animator has not settled. It gates frame callbacks, so a
//!   settled app costs nothing.
//! - `dirty` is true when `draw` has work to do. The host resets the context, then `draw`
//!   appends every instance and must leave `dirty()` false. The hosts assert the latter.
//!   The hosts also call `draw` on a clean app when the context's glyph cache owes a draw
//!   (`text/cache.zig`: the display scale changed since the last draw, or glyphs were
//!   skipped for the per-frame budget or a full atlas), so `draw` must be repeatable: a
//!   clean app draws the same instances again.
//!
//! ## 2a. Draw Configuration
//! `config.draw` lists the app's draw types and the instances each pool holds per frame; a
//! type's id is its index. `config.batch_cap` (default 256) bounds the batches per frame.
//! `Context(App)` is the draw context type built from them, which `draw` receives. `check`
//! rejects an empty or oversized list, a type that breaks the instance convention (the
//! message names the type; see `draw/registry.zig`), a zero cap, and a `batch_cap` whose worst
//! frame would not fit one command buffer.
//!
//! ## 3. Host Order Per Wake
//! Drain queued events into `event`. When a frame callback completes, call `event(.frame)`.
//! When the timer expires, call `timer`. At present time call `layout` if the window
//! changed, then, if `dirty()` or `context.text.owes_draw(scale_120)`, set
//! `context.text.scale_120`, reset the context, and call `draw`. After presenting, a cache
//! that still owes a draw requests another frame.
//!
//! ## 4. The Optional Timer
//! `timer_period_ms == 0` means no timer. The native host then creates no `timerfd` and
//! sleeps in `poll` while nothing is live. The browser host arms no `setInterval`.
//! `timer_period_ms_max` bounds the period so a value in the wrong unit fails the build.
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

/// Per-app settings the hosts read at compile time. Comptime-only, because `draw` names types.
pub const Config = struct {
    /// Window title on native. The browser page sets its own title.
    title: [:0]const u8,
    /// Host timer period in milliseconds. 0 means no timer.
    timer_period_ms: u32,
    /// The app's draw types and their pool capacities; a type's id is its index.
    draw: []const quads.DrawType,
    /// Upper bound on batches per frame: distinct (layer, type, texture) runs.
    batch_cap: u32 = 256,
};

/// The draw context type `App.draw` receives, built from `App.config`.
pub fn Context(comptime App: type) type {
    return quads.Context(App.config.draw, App.config.batch_cap);
}

/// Upper bound for `Config.timer_period_ms`, chosen so a period given in the wrong unit is
/// rejected at build time. The failure message in `conformance` repeats the number, which the
/// comptime assert at the end of this file and the "slow timer" test keep in sync.
pub const timer_period_ms_max: u32 = 1000;

/// Returns null when `App` satisfies the contract, otherwise a message naming the first
/// problem. Pure, so tests can check failure cases without a compile error. Signature types
/// are compared exactly, which is why `live` and `dirty` must take `*const App`.
pub fn conformance(comptime App: type) ?[]const u8 {
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
    const names = [_][]const u8{ "init", "layout", "event", "timer", "live", "dirty", "draw" };
    const expected = [_]type{
        fn (*App, *quads.Textures) void,
        fn (*App, u32, u32) void,
        fn (*App, input.Event) bool,
        fn (*App, u64) bool,
        fn (*const App) bool,
        fn (*const App) bool,
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
    pub fn layout(app: *GoodApp, width_logical: u32, height_logical: u32) void {
        _ = app;
        _ = width_logical;
        _ = height_logical;
    }
    pub fn event(app: *GoodApp, event_value: input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }
    pub fn timer(app: *GoodApp, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }
    pub fn live(app: *const GoodApp) bool {
        _ = app;
        return false;
    }
    pub fn dirty(app: *const GoodApp) bool {
        _ = app;
        return false;
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
    pub fn layout(app: *NoDraw, width_logical: u32, height_logical: u32) void {
        _ = app;
        _ = width_logical;
        _ = height_logical;
    }
    pub fn event(app: *NoDraw, event_value: input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }
    pub fn timer(app: *NoDraw, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }
    pub fn live(app: *const NoDraw) bool {
        _ = app;
        return false;
    }
    pub fn dirty(app: *const NoDraw) bool {
        _ = app;
        return false;
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

const WrongLive = struct {
    pub const config: Config = .{ .title = "wrong", .timer_period_ms = 0, .draw = &test_draw };
    pub fn init(app: *WrongLive, textures: *quads.Textures) void {
        _ = app;
        _ = textures;
    }
    pub fn layout(app: *WrongLive, width_logical: u32, height_logical: u32) void {
        _ = app;
        _ = width_logical;
        _ = height_logical;
    }
    pub fn event(app: *WrongLive, event_value: input.Event) bool {
        _ = app;
        _ = event_value;
        return false;
    }
    pub fn timer(app: *WrongLive, now_ms: u64) bool {
        _ = app;
        _ = now_ms;
        return false;
    }
    // Takes a mutable pointer where the contract demands `*const`.
    pub fn live(app: *WrongLive) bool {
        _ = app;
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
    try std.testing.expect(std.mem.indexOf(u8, missing, "draw") != null);
    try std.testing.expect(!@hasDecl(NoDraw, "draw"));
    try std.testing.expect(@hasDecl(NoDraw, "dirty"));
}

// Locks the remaining rejections: missing config, over-limit timer period, and a signature
// mismatch (the message names both the member and the expected `*const` type).
test "a missing config, a slow timer, and a mistyped live are rejected" {
    const no_config = comptime conformance(NoConfig).?;
    try std.testing.expect(std.mem.indexOf(u8, no_config, "config") != null);
    const slow = comptime conformance(SlowTimer).?;
    try std.testing.expect(std.mem.indexOf(u8, slow, "1000") != null);
    const wrong = comptime conformance(WrongLive).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong, "live") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrong, "*const") != null);
}

// Locks the draw configuration rejections: a type that breaks the convention is named, and
// a batch cap whose worst frame overflows the command buffer is refused.
test "a ragged draw type and an oversized batch cap are rejected" {
    const ragged = comptime conformance(RaggedApp).?;
    try std.testing.expect(std.mem.indexOf(u8, ragged, "Ragged") != null);
    try std.testing.expect(std.mem.indexOf(u8, ragged, "multiple of 16") != null);
    const huge = comptime conformance(HugeBatches).?;
    try std.testing.expect(std.mem.indexOf(u8, huge, "batch_cap") != null);
}

comptime {
    assert(timer_period_ms_max == 1000);
}

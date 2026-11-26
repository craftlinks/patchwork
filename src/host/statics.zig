//! The one App of a native process: the app, its UI context, and its renderer, which the window
//! host (`linux_window.zig`) and the offscreen host (`offscreen.zig`) both use.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why One
//! The native executable holds both hosts (`host/native_main.zig`): `--regress` and `--render`
//! run `Offscreen(App)`, everything else runs `Host(App)`. Each once declared its own app,
//! context, and renderer, so an app's largest storage was in the binary twice though a process
//! only ever runs one host. An App of 655.7 MB made 1.38 GB of static data, near the 2 GiB a
//! native link allows (step 82).
//!
//! ## 2. How the Hosts Share It
//! `Statics(App)` is a comptime type function, so every call with the same `App` returns the same
//! type and its `var`s are one storage in the program. Each host points at them:
//!
//! ```text
//!   Statics(App).app / .context / .render     one static each
//!          ^                    ^
//!   linux_window Host(App)   offscreen Offscreen(App)   (const pointers, comptime-known)
//! ```
//!
//! No function pointer and no allocation: each host is still compiled for its `App` and calls it
//! directly. The app's contract does not change; an app never sees this file.
//!
//! ## 3. One Holder at a Time
//! `claim` marks which host holds the storage and `release` gives it back. The window host
//! claims for its whole `run`; the offscreen host from `open` to `close`, so a tool may open,
//! close, and open again. Claiming while the other holds it is a bug, caught by an assert: both
//! would initialize the same app in place under each other.
//!
//! ## 4. How Large
//! Zig 0.17's own Debug backend and linker write these `undefined` statics into the file with a
//! third more room, and an executable whose static data ends past 2 GiB links without an error and
//! crashes (an absolute 32-bit address that cannot hold it). An App of 1500 MiB started, 1536 MiB
//! crashed at start (step 85). So under any backend but LLVM the three together may be at most
//! `own_linker_bytes_max`, 1 GiB, and a larger App fails to compile naming the fix. Through LLD
//! (`AppOptions.lld`) they are BSS and LLD refuses a link that cannot reach, so there is no bound
//! here. The app's own file-scope statics are not counted.
//!
//! ## 5. TigerStyle Invariants
//! - Static allocation: the sizes follow `App` and `App.config`, as in each host before.
//! - `claim` and `release` assert the holder, so a second host cannot start silently.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const app_contract = @import("../app.zig");
const renderer = @import("../draw/renderer.zig");

/// The most bytes the app, its context, and its renderer may be together when Zig's own backend and
/// linker build the executable (module guide, section 4).
pub const own_linker_bytes_max: u64 = 1 << 30;

comptime {
    assert(own_linker_bytes_max < 1 << 31);
}

/// The host that holds an App's statics (module guide, section 3).
pub const Holder = enum(u8) { none, window, offscreen };

/// The app, UI context, and renderer of `App`, one each per program (module guide, section 2).
pub fn Statics(comptime App: type) type {
    return struct {
        pub const Context = app_contract.Context(App);
        pub const Renderer = renderer.Renderer(Context.DrawContext);

        /// Initialized in place by the host that holds them (`App.init`, `Context.init`,
        /// `Renderer.init`).
        pub var app: App = undefined;
        pub var context: Context = undefined;
        pub var render: Renderer = undefined;

        var holder: Holder = .none;

        comptime {
            const bytes = @sizeOf(App) + @sizeOf(Context) + @sizeOf(Renderer);
            if (builtin.zig_backend != .stage2_llvm and bytes > own_linker_bytes_max) {
                @compileError(std.fmt.comptimePrint("the app, its context, and its renderer " ++
                    "are {d} bytes of static data, past the {d} bytes Zig's own linker " ++
                    "holds: link through LLD (`AppOptions.lld`)", .{
                    bytes,
                    own_linker_bytes_max,
                }));
            }
        }

        /// Takes the statics for `by`. Asserts no host holds them.
        pub fn claim(by: Holder) void {
            assert(by != .none);
            assert(holder == .none);
            holder = by;
        }

        /// Gives the statics back. Asserts `by` holds them.
        pub fn release(by: Holder) void {
            assert(by != .none);
            assert(holder == by);
            holder = .none;
        }

        /// The host holding the statics, `.none` between holders.
        pub fn held() Holder {
            return holder;
        }
    };
}

/// The smallest app: the statics need its config for the context and the renderer.
const TinyApp = struct {
    value: u32,

    const Cx = app_contract.Context(TinyApp);

    pub const config: app_contract.Config = .{
        .title = "tiny",
        .timer_period_ms = 0,
        .draw = &.{.{ .type = @import("../draw.zig").Box, .cap = 4 }},
    };
};

test "one App per type, whichever file asks" {
    const a = Statics(TinyApp);
    const b = Statics(TinyApp);
    try std.testing.expect(a == b);
    try std.testing.expect(&a.app == &b.app);
    try std.testing.expect(&a.context == &b.context);
    try std.testing.expect(&a.render == &b.render);
}

test "a holder claims and releases, one at a time" {
    const S = Statics(TinyApp);
    try std.testing.expectEqual(Holder.none, S.held());
    S.claim(.offscreen);
    try std.testing.expectEqual(Holder.offscreen, S.held());
    S.release(.offscreen);
    S.claim(.window);
    try std.testing.expectEqual(Holder.window, S.held());
    S.release(.window);
    try std.testing.expectEqual(Holder.none, S.held());
}

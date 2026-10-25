//! Native Linux application entry point.
//!
//! The build compiles this file with two imports: `patchwork`, the library, and `app`, the
//! application's root file. It contains no app code, so the same app source builds for
//! native and browser. `linux_window.run` checks the app contract at compile time, then
//! owns all storage on its own stack frame: window state, draw lists, queue, and the app.
//! The command line selects the adapter, bench mode, and the windowless shader check
//! (`--check`, which returns before any Wayland connection; `bench.zig`, `bench.usage`).

const std = @import("std");
const patchwork = @import("patchwork");
const app = @import("app");
const bench = patchwork.bench;

/// Reads the options after the program name (`bench.parse_args`) and runs the app.
pub fn main(init: std.process.Init.Minimal) !void {
    var storage: [bench.arg_cap][:0]const u8 = undefined;
    var count: u32 = 0;
    var args = init.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (count == bench.arg_cap) return error.TooManyArguments;
        storage[count] = arg;
        count += 1;
    }
    const options = bench.parse_args(storage[0..count]) catch |err| {
        std.debug.print("{s}: {s}\n{s}", .{ app.App.config.title, @errorName(err), bench.usage });
        return err;
    };
    try patchwork.host.linux_window.run(app.App, options);
}

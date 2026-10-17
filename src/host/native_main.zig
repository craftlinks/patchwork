//! Native Linux application entry point.
//!
//! The build compiles this file with two imports: `patchwork`, the library, and `app`, the
//! application's root file. It contains no app code, so the same app source builds for
//! native and browser. `linux_window.run` checks the app contract at compile time, then
//! owns all storage on its own stack frame: window state, draw lists, queue, and the app.

const patchwork = @import("patchwork");
const app = @import("app");

pub fn main() !void {
    try patchwork.host.linux_window.run(app.App);
}

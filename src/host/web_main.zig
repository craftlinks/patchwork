//! Browser entry point.
//!
//! The build compiles this file for `wasm32-freestanding` with two imports: `patchwork`, the
//! library, and `app`, the application's root file. `export_app` checks the app contract
//! at compile time and exports every symbol `web/shell.js` looks up. `panic` must be declared
//! here, in the root file, for std to use it: every panic goes to the page's console.

const patchwork = @import("patchwork");
const app = @import("app");

/// Every panic of the module goes to the page's console (`host/web_exports.zig`, section 4e).
pub const panic = patchwork.host.web_exports.panic;

comptime {
    patchwork.host.web_exports.export_app(app.App);
}

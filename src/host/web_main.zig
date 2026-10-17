//! Browser entry point.
//!
//! The build compiles this file for `wasm32-freestanding` with two imports: `patchwork`, the
//! library, and `app`, the application's root file. `export_app` checks the app contract
//! at compile time and exports every symbol `web/shell.js` looks up.

const patchwork = @import("patchwork");
const app = @import("app");

comptime {
    patchwork.host.web_exports.export_app(app.App);
}

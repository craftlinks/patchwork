//! The test root of the native-only tests: code that calls a system library and so cannot run
//! in the library's pure test root (`root.zig`). `build.zig` links this root against
//! libxkbcommon and adds it to `zig build test` for the native target only; the wasm build
//! never sees it.

test {
    _ = @import("host/xkb.zig");
}

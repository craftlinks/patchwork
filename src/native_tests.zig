//! The test root of the native-only tests: code that calls a system library or spawns a thread
//! and so cannot run in the library's pure test root (`root.zig`). `build.zig` links this root
//! against libxkbcommon and libwayland-client and adds it to `zig build test` for the native
//! target only; the wasm build never sees it.

test {
    _ = @import("host/xkb.zig");
    _ = @import("host/audio_thread.zig");
    _ = @import("host/dnd_test.zig");
    _ = @import("serve.zig");
}

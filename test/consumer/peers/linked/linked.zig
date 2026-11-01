//! A peer that calls into a system library, for `test/consumer`: libxkbcommon natively, which every
//! Patchwork build machine has, and the same answer by hand on wasm. The native-only branch lives
//! here, in the peer, so the consumer's `@import("linked")` reads the same on both targets.

const std = @import("std");
const builtin = @import("builtin");

const native = builtin.cpu.arch != .wasm32;

extern fn xkb_keysym_from_name(name: [*:0]const u8, flags: c_int) u32;

/// The keysym of the key `name`, one lowercase ASCII letter: from libxkbcommon natively.
pub fn keysym(name: [:0]const u8) u32 {
    std.debug.assert(name.len == 1);
    std.debug.assert(name[0] >= 'a' and name[0] <= 'z');
    if (native) return xkb_keysym_from_name(name.ptr, 0);
    return name[0];
}

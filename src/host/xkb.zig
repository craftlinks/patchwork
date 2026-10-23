//! libxkbcommon bindings and the native key translation: keymap, modifier state, keysym to
//! `input.Key`, UTF-8 text, dead keys through the compose table, and key repeat lookup.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why libxkbcommon
//! A Wayland compositor sends the keymap as an XKB text file and every key as an evdev code;
//! turning them into characters needs the XKB compiler, which every Wayland desktop ships as
//! `libxkbcommon.so.0`. It is linked dynamically, like `libwayland-client`, and only by the
//! native build (`build.zig`, `add_native`); the wasm build never references this file. A
//! system without it fails to start with the loader's "error while loading shared libraries",
//! as one without libwayland does; there is no fallback layout table.
//!
//! ## 2. Translation
//! ```text
//! wl_keyboard.keymap (fd, size)   mmap read-only private -> xkb_keymap -> xkb_state
//! wl_keyboard.modifiers           xkb_state_update_mask -> Mods (Shift, Control, Mod1, Mod4)
//! wl_keyboard.key (evdev code)    keycode = code + 8
//!                                   keysym = xkb_state_key_get_one_sym -> input.key_of_keysym
//!                                   text   = compose result, else xkb_state_key_get_utf8
//! ```
//! Dead keys go through the compose table of the user's locale (the first non-empty of
//! `LC_ALL`, `LC_CTYPE`, `LANG`, else "C"): a press is fed to the compose state; while a
//! sequence is composing the press types nothing, a finished sequence types its result, and a
//! cancelled one types nothing. Repeats are not fed to compose. A locale without a compose
//! table types dead keys as nothing and everything else normally.
//!
//! ## 3. Allocation
//! libxkbcommon allocates internally when a keymap or compose table is compiled: once at
//! startup and again only when the compositor sends a new keymap (a layout switch). This is
//! accepted like libwayland's own allocation; the host itself allocates nothing.
//!
//! ## 4. TigerStyle Invariants
//! - Text is bounded by `typed_cap`; a longer xkb result is cut on a codepoint boundary.
//! - The test at the end compiles a German keymap from names without a display and checks
//!   the translation path; `zig build test` runs it natively (`src/native_tests.zig`).

const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");

/// Bytes of text one key press may produce before `input.next_chunk` splits it.
pub const typed_cap: u32 = 64;

/// Wayland's evdev codes are xkb keycodes minus 8.
pub const keycode_offset: u32 = 8;

const mod_invalid: u32 = 0xFFFF_FFFF;
const state_mods_effective: u32 = 1 << 3;
const keymap_format_text_v1: u32 = 1;
const compose_feed_accepted: u32 = 1;
const compose_composing: u32 = 1;
const compose_composed: u32 = 2;
const compose_cancelled: u32 = 3;

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8,
    model: ?[*:0]const u8,
    layout: ?[*:0]const u8,
    variant: ?[*:0]const u8,
    options: ?[*:0]const u8,
};

extern fn xkb_context_new(flags: u32) ?*Context;
extern fn xkb_keymap_new_from_names(
    context: *Context,
    names: *const RuleNames,
    flags: u32,
) ?*Keymap;
extern fn xkb_keymap_new_from_buffer(
    context: *Context,
    buffer: [*]const u8,
    length: usize,
    format: u32,
    flags: u32,
) ?*Keymap;
extern fn xkb_keymap_unref(keymap: *Keymap) void;
extern fn xkb_keymap_mod_get_index(keymap: *Keymap, name: [*:0]const u8) u32;
extern fn xkb_keymap_key_repeats(keymap: *Keymap, key: u32) i32;
extern fn xkb_state_new(keymap: *Keymap) ?*State;
extern fn xkb_state_unref(state: *State) void;
extern fn xkb_state_update_mask(
    state: *State,
    depressed: u32,
    latched: u32,
    locked: u32,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) u32;
extern fn xkb_state_update_key(state: *State, key: u32, direction: u32) u32;
extern fn xkb_state_key_get_one_sym(state: *State, key: u32) u32;
extern fn xkb_state_key_get_utf8(state: *State, key: u32, buffer: [*]u8, size: usize) i32;
extern fn xkb_state_mod_index_is_active(state: *State, index: u32, kind: u32) i32;
extern fn xkb_compose_table_new_from_locale(
    context: *Context,
    locale: [*:0]const u8,
    flags: u32,
) ?*ComposeTable;
extern fn xkb_compose_state_new(table: *ComposeTable, flags: u32) ?*ComposeState;
extern fn xkb_compose_state_feed(state: *ComposeState, keysym: u32) u32;
extern fn xkb_compose_state_reset(state: *ComposeState) void;
extern fn xkb_compose_state_get_status(state: *ComposeState) u32;
extern fn xkb_compose_state_get_utf8(state: *ComposeState, buffer: [*]u8, size: usize) i32;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// The text one key press typed: `bytes[0..len]`, whole codepoints.
pub const Typed = struct {
    bytes: [typed_cap]u8,
    len: u32,

    pub fn text(self: *const Typed) []const u8 {
        assert(self.len < typed_cap);
        return self.bytes[0..self.len];
    }
};

/// The xkb objects of one seat's keyboard. Static in the host; see the module guide.
pub const Keyboard = struct {
    context: ?*Context,
    keymap: ?*Keymap,
    state: ?*State,
    compose: ?*ComposeState,
    shift: u32,
    ctrl: u32,
    alt: u32,
    meta: u32,

    /// Creates the context and the locale's compose state. No keymap yet: keys translate to
    /// nothing until `load` or `use_keymap`.
    pub fn init(self: *Keyboard) void {
        self.* = .{
            .context = xkb_context_new(0),
            .keymap = null,
            .state = null,
            .compose = null,
            .shift = mod_invalid,
            .ctrl = mod_invalid,
            .alt = mod_invalid,
            .meta = mod_invalid,
        };
        const context = self.context orelse return;
        const table = xkb_compose_table_new_from_locale(context, locale(), 0) orelse return;
        self.compose = xkb_compose_state_new(table, 0);
        assert(self.keymap == null);
    }

    /// Compiles the keymap text `bytes` (the compositor's keymap, without its trailing NUL).
    /// Returns false when it does not compile; the previous keymap then stays.
    pub fn load(self: *Keyboard, bytes: []const u8) bool {
        const context = self.context orelse return false;
        const keymap = xkb_keymap_new_from_buffer(
            context,
            bytes.ptr,
            bytes.len,
            keymap_format_text_v1,
            0,
        ) orelse return false;
        return self.use_keymap(keymap);
    }

    /// Takes `keymap` and makes a fresh state for it. Returns false when no state could be made.
    pub fn use_keymap(self: *Keyboard, keymap: *Keymap) bool {
        const state = xkb_state_new(keymap) orelse {
            xkb_keymap_unref(keymap);
            return false;
        };
        if (self.state) |old| xkb_state_unref(old);
        if (self.keymap) |old| xkb_keymap_unref(old);
        self.keymap = keymap;
        self.state = state;
        self.shift = xkb_keymap_mod_get_index(keymap, "Shift");
        self.ctrl = xkb_keymap_mod_get_index(keymap, "Control");
        self.alt = xkb_keymap_mod_get_index(keymap, "Mod1");
        self.meta = xkb_keymap_mod_get_index(keymap, "Mod4");
        if (self.compose) |compose| xkb_compose_state_reset(compose);
        assert(self.keymap != null);
        assert(self.state != null);
        return true;
    }

    /// Applies `wl_keyboard.modifiers`.
    pub fn update_mask(
        self: *Keyboard,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const state = self.state orelse return;
        _ = xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        assert(self.keymap != null);
    }

    /// The modifiers in effect.
    pub fn mods(self: *const Keyboard) input.Mods {
        const state = self.state orelse return .none;
        const result: input.Mods = .{
            .shift = active(state, self.shift),
            .ctrl = active(state, self.ctrl),
            .alt = active(state, self.alt),
            .meta = active(state, self.meta),
        };
        assert(result.unused == 0);
        return result;
    }

    /// True when the keymap repeats the evdev `code`.
    pub fn repeats(self: *const Keyboard, code: u32) bool {
        const keymap = self.keymap orelse return false;
        return xkb_keymap_key_repeats(keymap, code + keycode_offset) != 0;
    }

    /// The key the evdev `code` names now.
    pub fn key_of(self: *const Keyboard, code: u32) input.Key {
        const state = self.state orelse return .other;
        return input.key_of_keysym(xkb_state_key_get_one_sym(state, code + keycode_offset));
    }

    /// Translates a press of the evdev `code`: returns its key and writes its text into
    /// `typed` (section 2). A `repeat` bypasses compose.
    pub fn press(self: *Keyboard, code: u32, repeat: bool, typed: *Typed) input.Key {
        typed.len = 0;
        const state = self.state orelse return .other;
        const keycode = code + keycode_offset;
        const keysym = xkb_state_key_get_one_sym(state, keycode);
        const key = input.key_of_keysym(keysym);
        if (!repeat) {
            if (self.compose) |compose| {
                if (xkb_compose_state_feed(compose, keysym) == compose_feed_accepted) {
                    switch (xkb_compose_state_get_status(compose)) {
                        compose_composing => return key,
                        compose_composed => {
                            const length = xkb_compose_state_get_utf8(
                                compose,
                                &typed.bytes,
                                typed_cap,
                            );
                            xkb_compose_state_reset(compose);
                            typed.len = clamp_text(&typed.bytes, length);
                            return key;
                        },
                        compose_cancelled => {
                            xkb_compose_state_reset(compose);
                            return key;
                        },
                        else => {},
                    }
                }
            }
        }
        const length = xkb_state_key_get_utf8(state, keycode, &typed.bytes, typed_cap);
        typed.len = clamp_text(&typed.bytes, length);
        assert(typed.len < typed_cap);
        return key;
    }
};

fn active(state: *State, index: u32) bool {
    if (index == mod_invalid) return false;
    return xkb_state_mod_index_is_active(state, index, state_mods_effective) > 0;
}

/// The bytes of an xkb UTF-8 result of `length` (the untruncated size xkb reports) that fit
/// the buffer whole: xkb writes a NUL-terminated, possibly cut string.
fn clamp_text(bytes: *const [typed_cap]u8, length: i32) u32 {
    if (length <= 0) return 0;
    const reported: u32 = @intCast(length);
    if (reported < typed_cap) return reported;
    const written = std.mem.indexOfScalar(u8, bytes, 0) orelse typed_cap - 1;
    const cut = input.utf8_prefix(bytes[0..written], typed_cap - 1);
    assert(cut < typed_cap);
    return cut;
}

/// The locale for the compose table (section 2).
fn locale() [*:0]const u8 {
    const names = [_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (names) |name| {
        const value = getenv(name) orelse continue;
        if (value[0] != 0) return value;
    }
    return "C";
}

const testing = std.testing;

/// evdev codes from `<linux/input-event-codes.h>`.
const key_grave: u32 = 41;
const key_apostrophe: u32 = 40;
const key_e: u32 = 18;
const key_left_shift: u32 = 42;
const key_backspace: u32 = 14;

// Locks the native translation without a display: a German keymap compiled from names types
// "ä" on the AC11 key and "A"-row keys through `press`, names Backspace, and repeats letters
// but not Shift; dead circumflex then "e" composes "ê" when the locale has a compose table.
test "a German keymap types umlauts and composes dead keys" {
    var keyboard: Keyboard = undefined;
    keyboard.init();
    const context = keyboard.context orelse return error.SkipZigTest;
    const names: RuleNames = .{
        .rules = null,
        .model = null,
        .layout = "de",
        .variant = null,
        .options = null,
    };
    const keymap = xkb_keymap_new_from_names(context, &names, 0) orelse return error.SkipZigTest;
    try testing.expect(keyboard.use_keymap(keymap));
    var typed: Typed = undefined;
    try testing.expectEqual(input.Key.other, keyboard.press(key_apostrophe, false, &typed));
    try testing.expectEqualStrings("\u{e4}", typed.text());
    try testing.expectEqual(input.Key.backspace, keyboard.press(key_backspace, false, &typed));
    try testing.expectEqual(input.Key.e, keyboard.press(key_e, true, &typed));
    try testing.expectEqualStrings("e", typed.text());
    try testing.expect(keyboard.repeats(key_e));
    try testing.expect(!keyboard.repeats(key_left_shift));
    _ = xkb_state_update_key(keyboard.state.?, key_left_shift + keycode_offset, 1);
    try testing.expect(keyboard.mods().shift);
    try testing.expectEqualStrings("E", blk: {
        _ = keyboard.press(key_e, true, &typed);
        break :blk typed.text();
    });
    _ = xkb_state_update_key(keyboard.state.?, key_left_shift + keycode_offset, 0);
    try testing.expect(!keyboard.mods().shift);
    // The compose table comes from the locale; a fixed UTF-8 locale keeps the test stable.
    const table = xkb_compose_table_new_from_locale(context, "en_US.UTF-8", 0) orelse {
        std.debug.print("xkb test: no en_US.UTF-8 compose table, dead keys not checked\n", .{});
        return;
    };
    keyboard.compose = xkb_compose_state_new(table, 0);
    try testing.expect(keyboard.compose != null);
    _ = keyboard.press(key_grave, false, &typed);
    try testing.expectEqual(@as(u32, 0), typed.len);
    _ = keyboard.press(key_e, false, &typed);
    try testing.expectEqualStrings("\u{ea}", typed.text());
}

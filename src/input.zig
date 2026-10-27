//! Input events, the bounded event queue the native loop drains once per wake, and the pure
//! input policy both hosts share: click counting, key naming, text filtering, and key repeat.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Queue Instead of a Latest-State Snapshot?
//! Wayland delivers socket messages in batches. If the loop only kept the latest pointer state,
//! a press followed by a release inside one batch would overwrite itself to `down == false`
//! before the app ran, and the click edge would be lost. `EventQueue` keeps events in the order
//! the platform observed them, and the loop drains it once per wake.
//!
//! ### Ordering and Coalescing Rules
//! - Presses, releases, leaves, frames, keys, and window focus changes are never merged or
//!   reordered, so click and key transitions survive.
//! - A `pointer_move` pushed directly after a `pointer_move` replaces it. Only the newest
//!   position matters, and this keeps high-rate mice from filling the queue.
//! - A `wheel` pushed directly after a `wheel` is merged: `dx` and `dy` are summed and the
//!   anchor point `(x, y)` becomes the newest one. A diagonal scroll arrives from Wayland as a
//!   horizontal and a vertical axis event in one `wl_pointer.frame`, so this merge also does
//!   the frame grouping.
//! - Merging is only ever with the last queued event, so an intervening event of another kind
//!   splits the run (tests "a wheel between moves does not merge" and "move down move up keeps
//!   four events").
//! - A push into a full queue is counted in `dropped` and discarded; queued history is never
//!   modified and nothing is allocated (test "overflow drops the newest event").
//! - `paste` never enters the queue: its slice points at a host buffer that is only valid
//!   while the host dispatches it, so the hosts call `ui.dispatch` directly (asserted). The
//!   same holds for `drop` and `file` (section 6).
//! - A `drop_over` pushed directly after a `drop_over` replaces it, like a move.
//!
//! ### Native vs. Web
//! Native Wayland callbacks only push to the queue; the window loop pops events in order
//! (`sync_input` in `linux_window.zig`). Browser events arrive one at a time, so the web
//! exports call into the app directly and bypass the queue. Both paths hand the app the same
//! `Event` values.
//!
//! ## 2. Coordinate Spaces
//! Points are in the surface's layout space: top-left origin, `+X` right, `+Y` down. This
//! module applies no scaling; each host converts into that space before pushing.
//! - **Wayland:** `wl_pointer.enter` and `motion` carry `wl_fixed_t`, a signed 24.8 fixed-point
//!   number. `logical = fixed / 256` (`fixed_to_logical`, test "fixed_to_logical converts
//!   24.8"). Surface-local coordinates are independent of the buffer scale, so they are already
//!   layout pixels.
//! - **Browser:** `web/shell.js` passes DOM CSS pixels, which are the layout pixels.
//!
//! ## 3. Keys and Text
//! `Key` names the keys widgets act on: arrows, Home, End, Page Up and Down, Backspace,
//! Delete, Enter, Tab, Escape, `a` to `z`, `0` to `9`, and F1 to F12; every other key is
//! `other`. The name follows the layout (the xkb keysym natively, `KeyboardEvent.key` in the
//! browser), so Ctrl+Z follows the user's layout. `key_of_keysym` and `key_of_dom` map both
//! sources, so all key naming lives here and is tested.
//!
//! A `key_down` carries the text the key typed (`KeyPress.text`, at most 4 bytes): one event,
//! one dispatch per keystroke and per repeat. Text is dropped when Ctrl or Meta is held
//! (`text_allowed`) and for C0 controls and DEL (`printable`), so Enter, Tab, and Backspace
//! carry none. A compose result longer than 4 bytes is split by `next_chunk` into follow-up
//! `key_down` events of key `other`, each holding whole codepoints.
//!
//! ## 4. Clicks
//! Click counting lives in the library so a double click behaves the same on both targets;
//! the hosts only stamp `Button.time_ms` (Wayland's millisecond `wl_pointer.button` time, or
//! the browser's `event.timeStamp`). A press continues the count when it is the same button,
//! at most `click_interval_ms` after the previous press (wrapping `u32` subtraction, so the
//! undefined Wayland time base and its wrap do not matter), and within `click_slop_px` on
//! each axis; otherwise the count restarts at 1 (`count_click`, test "clicks count within the
//! interval and the slop").
//!
//! ## 5. Key Repeat
//! The browser repeats keys itself (`event.repeat`). The native host repeats with a timerfd
//! that `Repeat` arms: a press of a key that repeats arms it with the delay and the interval
//! of `wl_keyboard.repeat_info`; a release of that key, a leave, or a rate of 0 disarms it, so
//! an idle app has no timer armed. Without `repeat_info` (a seat bound below version 4) the
//! defaults `repeat_rate_default` and `repeat_delay_ms_default` apply. Test "repeat arms on a
//! repeating press and disarms on its release".
//!
//! ## 6. File Drops
//! A drag that carries files reports `drop_over` while it is over the window and
//! `drop_leave` when it leaves or is cancelled; the pointer, hover, and capture are not
//! involved (the drag holds the pointer). `drop` lists up to `drop_files_max` files by base
//! name, size, and whether they can be read; the app accepts some of them during that event,
//! and the host then delivers their bytes as `file` events (`Chunk`, `src/drop.zig`):
//! - Accepted files arrive in index order, never interleaved; each file's chunks have
//!   increasing offsets, back to back, and end with exactly one terminal chunk (`done`,
//!   `failed`, or `cancelled`).
//! - A file delivers exactly `size` bytes in chunks of `drop.chunk_cap`, except the last. The
//!   chunk that reaches `size` is `done` and carries bytes; an empty file is one empty `done`.
//!   `failed` and `cancelled` carry no bytes and sit at the offset reached.
//! So chunk boundaries are the same on every host. `drop` and `file` point into host storage
//! that is valid only while they are dispatched; neither enters the queue.
//!
//! ## 7. TigerStyle Invariants
//! - Capacity is fixed by `queue_cap`; there is no allocation.
//! - `push`, `pop`, and `index_at` are O(1); the key maps are O(1) switches or O(name) compares.
//! - Dropped events are counted, never silent.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum events retained between loop wakes. Moves and wheels coalesce, so the cap fills with
/// presses, releases, and keys rather than with motion samples.
pub const queue_cap: u32 = 64;

/// Longest gap between two presses of one click sequence, in milliseconds.
pub const click_interval_ms: u32 = 400;
/// Largest travel on either axis between two presses of one click sequence, in logical px.
pub const click_slop_px: f32 = 4;

/// Key repeat when the seat never sent `repeat_info`: repeats per second, and the hold time
/// before the first repeat.
pub const repeat_rate_default: u32 = 25;
pub const repeat_delay_ms_default: u32 = 600;

/// Bytes of text one `KeyPress` carries: one codepoint of up to 4 bytes, or several short ones.
pub const key_text_cap: u32 = 4;

/// Files one drop lists; the rest are counted in `Drop.skipped`. The accept and cancel masks
/// are a `u16`, one bit per file.
pub const drop_files_max: u32 = 16;
/// Bytes of one dropped file's name, cut on a codepoint boundary.
pub const drop_name_max: u32 = 255;

/// A point in UI logical pixels. Origin is the top-left. Y grows downward.
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
};

/// Modifier keys held during an event. The bit order is also the browser ABI
/// (`web_exports.zig`): shift 1, ctrl 2, alt 4, meta 8.
pub const Mods = packed struct(u8) {
    shift: bool,
    ctrl: bool,
    alt: bool,
    /// Super on Linux, Command on a Mac.
    meta: bool,
    unused: u4 = 0,

    pub const none: Mods = .{ .shift = false, .ctrl = false, .alt = false, .meta = false };

    /// The shortcut modifier: Ctrl, or Command on a Mac.
    pub fn shortcut(self: Mods) bool {
        assert(self.unused == 0);
        return self.ctrl or self.meta;
    }
};

/// A press or release of `button` at `(x, y)` in UI logical pixels. `time_ms` has an
/// undefined base and wraps; only differences are meaningful (section 4).
pub const Button = struct {
    x: f32,
    y: f32,
    time_ms: u32,
    button: MouseButton,
    mods: Mods,
};

/// A left-button sample at `point` with no modifiers at time 0: the press tests and synthetic
/// callers make.
pub fn left_at(point: Point) Button {
    assert(point.x == point.x);
    assert(point.y == point.y);
    return .{ .x = point.x, .y = point.y, .time_ms = 0, .button = .left, .mods = .none };
}

/// One wheel sample: the pointer anchor `(x, y)` in UI logical pixels and the scroll deltas.
/// Positive `dy` scrolls content downward, positive `dx` scrolls it right.
pub const Wheel = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
};

/// The keys widgets name. See the module guide, section 3.
pub const Key = enum(u8) {
    other,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    backspace,
    delete,
    enter,
    tab,
    escape,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    /// The bit of this key in a held-key set; `other` has none.
    pub fn bit(self: Key) u64 {
        if (self == .other) return 0;
        const index: u6 = @intCast(@backingInt(self));
        assert(index < key_count);
        return @as(u64, 1) << index;
    }
};

/// Values of `Key`, `other` included; a held-key set fits a `u64`.
pub const key_count: u32 = @typeInfo(Key).@"enum".field_names.len;

/// A key press or release. `text` holds `len` bytes of whole UTF-8 codepoints the press
/// typed; a release and a non-printing key carry none.
pub const KeyPress = struct {
    key: Key,
    mods: Mods,
    repeat: bool,
    len: u8,
    text: [key_text_cap]u8,

    /// The typed text.
    pub fn typed(self: *const KeyPress) []const u8 {
        assert(self.len <= key_text_cap);
        return self.text[0..self.len];
    }
};

/// One file of a drop (section 6).
pub const DropFile = struct {
    /// The base name, valid UTF-8; path bytes that are not are shown as '?'.
    name: []const u8,
    /// The bytes the transfer delivers: the size when the files were dropped.
    size: u64,
    /// False for a directory, a special file, or a path that could not be examined.
    readable: bool,
};

/// The files of one drop at `(x, y)` (section 6).
pub const Drop = struct {
    x: f32,
    y: f32,
    /// Files listed in `files`.
    count: u8,
    /// Files not listed: over `drop_files_max`, over the host's name room, or not local files.
    skipped: u16,
    files: [drop_files_max]DropFile,

    pub fn listed(self: *const Drop) []const DropFile {
        assert(self.count <= drop_files_max);
        return self.files[0..self.count];
    }
};

/// Whether a chunk is the last of its file, and how the file ended.
pub const ChunkEnd = enum(u8) {
    more,
    done,
    failed,
    cancelled,
};

/// A piece of an accepted file (section 6).
pub const Chunk = struct {
    /// The file's index in the `Drop` that was accepted.
    file: u8,
    /// The offset of `bytes[0]` in the file.
    offset: u64,
    /// At most `drop.chunk_cap` bytes, valid only while the chunk is dispatched.
    bytes: []const u8,
    end: ChunkEnd,
};

/// One input fact, in the order the platform observed it. `frame` carries the clock delta in
/// milliseconds; the native loop injects it from `sync_clock`. `paste` is the pasted UTF-8,
/// valid only during its dispatch (section 1). `window_focus` reports keyboard focus of the
/// window: false releases held keys. `drop_over`, `drop_leave`, `drop`, and `file` are a file
/// drag and the bytes of the files it delivered (section 6).
pub const Event = union(enum) {
    pointer_move: Point,
    pointer_down: Button,
    pointer_up: Button,
    pointer_leave,
    frame: f32,
    wheel: Wheel,
    key_down: KeyPress,
    key_up: KeyPress,
    paste: []const u8,
    window_focus: bool,
    /// A drag carrying files is over the window at the point.
    drop_over: Point,
    /// That drag left the window, or ended, without dropping here.
    drop_leave,
    /// It dropped here; valid only during the dispatch.
    drop: *const Drop,
    /// Bytes of an accepted file; valid only during the dispatch.
    file: *const Chunk,

    /// True for the events whose payload points into host storage: they never enter the queue.
    pub fn borrowed(self: Event) bool {
        return switch (self) {
            .paste, .drop, .file => true,
            else => false,
        };
    }
};

/// Latest pointer sample. The UI context stores this so a redraw can re-hit the same point.
/// Wayland button callbacks carry no coordinates, so the window keeps the last position
/// separately and copies it into the press and release events.
pub const Pointer = struct {
    x: f32,
    y: f32,
    inside: bool,
    down: bool,

    /// Resting pointer, outside the surface.
    pub fn init() Pointer {
        const pointer: Pointer = .{
            .x = 0,
            .y = 0,
            .inside = false,
            .down = false,
        };
        assert(!pointer.inside);
        assert(!pointer.down);
        return pointer;
    }

    /// Records a position inside the surface, in UI logical pixels.
    pub fn move(self: *Pointer, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
        self.inside = true;
        assert(self.inside);
        assert(self.x == x);
    }

    /// The pointer left the surface. Clears `down` so a press cannot stick when
    /// the display server never delivers the release.
    pub fn leave(self: *Pointer) void {
        self.inside = false;
        self.down = false;
        assert(!self.inside);
        assert(!self.down);
    }

    /// Records the primary button. `pressed` true means held.
    pub fn button(self: *Pointer, pressed: bool) void {
        self.down = pressed;
        assert(self.down == pressed);
        assert(self.x == self.x);
    }
};

/// The last press of a click sequence and how many presses it has. See section 4.
pub const Clicks = struct {
    x: f32,
    y: f32,
    time_ms: u32,
    button: MouseButton,
    count: u8,

    /// No sequence yet: the next press counts 1.
    pub const none: Clicks = .{ .x = 0, .y = 0, .time_ms = 0, .button = .left, .count = 0 };
};

/// The sequence after `down`: one more press when it continues `previous`, else 1.
pub fn count_click(previous: Clicks, down: Button) Clicks {
    assert(down.x == down.x);
    assert(down.y == down.y);
    var count: u8 = 1;
    if (previous.count >= 1 and previous.button == down.button) {
        const elapsed = down.time_ms -% previous.time_ms;
        const near_x = @abs(down.x - previous.x) <= click_slop_px;
        const near_y = @abs(down.y - previous.y) <= click_slop_px;
        if (elapsed <= click_interval_ms and near_x and near_y) count = previous.count +| 1;
    }
    const next: Clicks = .{
        .x = down.x,
        .y = down.y,
        .time_ms = down.time_ms,
        .button = down.button,
        .count = count,
    };
    assert(next.count >= 1);
    return next;
}

/// Ring of events. `head` is the next pop, `count` the live population, and `dropped` the
/// pushes rejected because the ring was full.
pub const EventQueue = struct {
    items: [queue_cap]Event,
    head: u32,
    count: u32,
    dropped: u32,

    pub fn init() EventQueue {
        const queue: EventQueue = .{
            .items = undefined,
            .head = 0,
            .count = 0,
            .dropped = 0,
        };
        assert(queue.count == 0);
        assert(queue.dropped == 0);
        return queue;
    }

    /// Appends `event`, applying the coalescing rules in the module guide. A push that cannot
    /// coalesce while `count == queue_cap` increments `dropped` and leaves the queue unchanged.
    pub fn push(self: *EventQueue, event: Event) void {
        assert(self.count <= queue_cap);
        assert(self.head < queue_cap);
        assert(!event.borrowed());
        if (coalesce(self, event)) {
            assert(self.count >= 1);
            return;
        }
        if (self.count == queue_cap) {
            self.dropped += 1;
            assert(self.dropped >= 1);
            assert(self.count == queue_cap);
            return;
        }
        const index = self.index_at(self.count);
        self.items[index] = event;
        self.count += 1;
        assert(self.count <= queue_cap);
        assert(self.count >= 1);
    }

    /// Removes the oldest event. Empty returns null.
    pub fn pop(self: *EventQueue) ?Event {
        assert(self.count <= queue_cap);
        assert(self.head < queue_cap);
        if (self.count == 0) {
            assert(self.count == 0);
            return null;
        }
        const event = self.items[self.head];
        self.head += 1;
        if (self.head == queue_cap) {
            self.head = 0;
        }
        self.count -= 1;
        assert(self.head < queue_cap);
        assert(self.count < queue_cap);
        assert(!event.borrowed());
        return event;
    }

    fn index_at(self: *const EventQueue, offset: u32) u32 {
        assert(offset < queue_cap);
        assert(self.head < queue_cap);
        const sum = self.head + offset;
        if (sum >= queue_cap) {
            assert(sum < queue_cap * 2);
            return sum - queue_cap;
        }
        assert(sum < queue_cap);
        return sum;
    }
};

/// Converts a Wayland `wl_fixed_t` (signed 24.8, so 1/256 units) sample to UI logical pixels.
pub fn fixed_to_logical(fixed: i32) f32 {
    const logical: f32 = @as(f32, @floatFromInt(fixed)) / 256.0;
    if (fixed == 0) {
        assert(logical == 0);
    }
    if (fixed == 256) {
        assert(logical == 1);
    }
    return logical;
}

/// Replaces a trailing move or sums a trailing wheel. Returns true when `event` did not need
/// its own slot.
fn coalesce(self: *EventQueue, event: Event) bool {
    assert(self.count <= queue_cap);
    if (self.count == 0) {
        assert(self.count == 0);
        return false;
    }
    const last = self.index_at(self.count - 1);
    if (event == .drop_over and self.items[last] == .drop_over) {
        self.items[last] = event;
        return true;
    }
    if (event == .pointer_move) {
        if (self.items[last] == .pointer_move) {
            self.items[last] = event;
            assert(self.count >= 1);
            return true;
        }
    }
    if (event == .wheel) {
        if (self.items[last] == .wheel) {
            const previous = self.items[last].wheel;
            self.items[last] = .{ .wheel = .{
                .x = event.wheel.x,
                .y = event.wheel.y,
                .dx = previous.dx + event.wheel.dx,
                .dy = previous.dy + event.wheel.dy,
            } };
            assert(self.items[last] == .wheel);
            return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------------------- keys and text

/// True unless Ctrl or Meta is held: a shortcut types nothing (section 3).
pub fn text_allowed(mods: Mods) bool {
    assert(mods.unused == 0);
    return !mods.shortcut();
}

/// True for a codepoint a key may type: not a C0 control and not DEL.
pub fn printable(codepoint: u21) bool {
    if (codepoint < 0x20) return false;
    if (codepoint == 0x7F) return false;
    assert(codepoint >= 0x20);
    return true;
}

/// Byte length of the UTF-8 sequence led by `lead`, or 0 for a byte that cannot lead one.
pub fn sequence_length(lead: u8) u32 {
    if (lead < 0x80) return 1;
    if (lead >= 0xC2 and lead <= 0xDF) return 2;
    if (lead >= 0xE0 and lead <= 0xEF) return 3;
    if (lead >= 0xF0 and lead <= 0xF4) return 4;
    return 0;
}

/// The longest prefix of `bytes` of at most `limit` bytes that ends on a codepoint boundary:
/// a truncation never splits a sequence. `bytes` is valid UTF-8.
pub fn utf8_prefix(bytes: []const u8, limit: u32) u32 {
    if (bytes.len <= limit) return @intCast(bytes.len);
    var end: u32 = limit;
    // At most three continuation bytes precede a boundary in valid UTF-8.
    var guard: u32 = 0;
    while (end > 0 and guard < 3) : (guard += 1) {
        if (bytes[end] & 0xC0 != 0x80) break;
        end -= 1;
    }
    assert(end <= limit);
    assert(end == 0 or bytes[end] & 0xC0 != 0x80);
    return end;
}

/// The length of `bytes` without a trailing codepoint cut short: a read that stopped at a
/// buffer cap may end inside a sequence, which this drops. Earlier bytes are not checked.
pub fn utf8_whole(bytes: []const u8) u32 {
    const length: u32 = @intCast(bytes.len);
    var lead = length;
    var guard: u32 = 0;
    while (lead > 0 and guard < 4) : (guard += 1) {
        lead -= 1;
        if (bytes[lead] & 0xC0 != 0x80) break;
    }
    if (lead == length) return length;
    const needed = @max(1, sequence_length(bytes[lead]));
    if (lead + needed > length) return lead;
    assert(lead + needed <= length);
    return length;
}

/// The next chunk of whole codepoints of `utf8` from `offset.*`, at most `key_text_cap` bytes,
/// and advances `offset`. Splits compose output across `key_down` events (section 3).
pub fn next_chunk(utf8: []const u8, offset: *u32) []const u8 {
    const start = offset.*;
    assert(start < utf8.len);
    var end = start;
    while (end < utf8.len) {
        const length = @max(1, sequence_length(utf8[end]));
        if (end + length - start > key_text_cap) break;
        end += length;
    }
    if (end == start) end = start + 1;
    offset.* = @min(end, @as(u32, @intCast(utf8.len)));
    assert(offset.* > start);
    return utf8[start..offset.*];
}

/// A press of `key` with `mods`, carrying `utf8` when it is printable text that fits and the
/// modifiers allow text (section 3). `utf8` is at most `key_text_cap` bytes of whole
/// codepoints.
pub fn key_press(key: Key, mods: Mods, repeat: bool, utf8: []const u8) KeyPress {
    assert(utf8.len <= key_text_cap);
    var press: KeyPress = .{
        .key = key,
        .mods = mods,
        .repeat = repeat,
        .len = 0,
        .text = @splat(0),
    };
    if (!text_allowed(mods)) return press;
    if (utf8.len == 0) return press;
    if (!printable_text(utf8)) return press;
    @memcpy(press.text[0..utf8.len], utf8);
    press.len = @intCast(utf8.len);
    assert(press.len <= key_text_cap);
    return press;
}

/// True when every byte of `utf8` belongs to a printable codepoint. ASCII bytes are checked
/// one by one; a multi-byte sequence is at least U+0080, which `printable` accepts.
fn printable_text(utf8: []const u8) bool {
    assert(utf8.len <= key_text_cap);
    for (utf8) |byte| {
        if (byte < 0x80 and !printable(byte)) return false;
    }
    return true;
}

/// The key an xkb keysym names (`xkbcommon-keysyms.h`); letters of either case and the keypad
/// navigation keys included. Anything else is `other`.
pub fn key_of_keysym(keysym: u32) Key {
    if (keysym >= 'a' and keysym <= 'z') return letter(@intCast(keysym - 'a'));
    if (keysym >= 'A' and keysym <= 'Z') return letter(@intCast(keysym - 'A'));
    if (keysym >= '0' and keysym <= '9') return digit(@intCast(keysym - '0'));
    if (keysym >= 0xFFBE and keysym <= 0xFFC9) return function(@intCast(keysym - 0xFFBE));
    return switch (keysym) {
        0xFF51, 0xFF96 => .left,
        0xFF52, 0xFF97 => .up,
        0xFF53, 0xFF98 => .right,
        0xFF54, 0xFF99 => .down,
        0xFF50, 0xFF95 => .home,
        0xFF57, 0xFF9C => .end,
        0xFF55, 0xFF9A => .page_up,
        0xFF56, 0xFF9B => .page_down,
        0xFF08 => .backspace,
        0xFFFF, 0xFF9F => .delete,
        0xFF0D, 0xFF8D => .enter,
        0xFF09, 0xFE20 => .tab,
        0xFF1B => .escape,
        else => .other,
    };
}

/// The key a `KeyboardEvent.key` value names. A single ASCII letter of either case or digit
/// names that key; named keys use the DOM spellings. Anything else is `other`.
pub fn key_of_dom(name: []const u8) Key {
    if (name.len == 1) {
        const byte = name[0];
        if (byte >= 'a' and byte <= 'z') return letter(byte - 'a');
        if (byte >= 'A' and byte <= 'Z') return letter(byte - 'A');
        if (byte >= '0' and byte <= '9') return digit(byte - '0');
        return .other;
    }
    if (name.len >= 2 and name.len <= 3 and name[0] == 'F') {
        const number = std.fmt.parseInt(u8, name[1..], 10) catch return .other;
        if (number >= 1 and number <= 12) return function(number - 1);
        return .other;
    }
    const names = [_]struct { name: []const u8, key: Key }{
        .{ .name = "ArrowLeft", .key = .left },
        .{ .name = "ArrowRight", .key = .right },
        .{ .name = "ArrowUp", .key = .up },
        .{ .name = "ArrowDown", .key = .down },
        .{ .name = "Home", .key = .home },
        .{ .name = "End", .key = .end },
        .{ .name = "PageUp", .key = .page_up },
        .{ .name = "PageDown", .key = .page_down },
        .{ .name = "Backspace", .key = .backspace },
        .{ .name = "Delete", .key = .delete },
        .{ .name = "Enter", .key = .enter },
        .{ .name = "Tab", .key = .tab },
        .{ .name = "Escape", .key = .escape },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.key;
    }
    return .other;
}

fn letter(index: u8) Key {
    assert(index < 26);
    return @fromBackingInt(@intCast(@backingInt(Key.a) + index));
}

fn digit(index: u8) Key {
    assert(index < 10);
    return @fromBackingInt(@intCast(@backingInt(Key.d0) + index));
}

fn function(index: u8) Key {
    assert(index < 12);
    return @fromBackingInt(@intCast(@backingInt(Key.f1) + index));
}

// ---------------------------------------------------------------------------------- repeat

/// The seat's repeat settings. A rate of 0 disables repeat.
pub const RepeatInfo = struct {
    rate_hz: u32,
    delay_ms: u32,

    pub const default: RepeatInfo = .{
        .rate_hz = repeat_rate_default,
        .delay_ms = repeat_delay_ms_default,
    };
};

/// What the native host does with its repeat timerfd after a key fact (section 5).
pub const Arming = union(enum) {
    /// Leave the timer as it is.
    keep,
    disarm,
    /// Arm: the first expiration after `delay_ns`, then every `interval_ns`.
    arm: struct { delay_ns: u64, interval_ns: u64 },
};

/// The key the native host repeats, as an evdev code. Pure: the host applies the `Arming`
/// each method returns. See the module guide, section 5.
pub const Repeat = struct {
    info: RepeatInfo,
    /// The held key that repeats, or null.
    code: ?u32,

    pub fn init() Repeat {
        const repeat: Repeat = .{ .info = .default, .code = null };
        assert(repeat.code == null);
        assert(repeat.info.rate_hz != 0);
        return repeat;
    }

    /// A press of `code`; `repeats` says whether the keymap repeats it. A repeating press
    /// takes over the timer; a non-repeating press (a modifier) leaves it running.
    pub fn press(self: *Repeat, code: u32, repeats: bool) Arming {
        if (!repeats) return .keep;
        if (self.info.rate_hz == 0) {
            self.code = null;
            return .disarm;
        }
        self.code = code;
        const interval_ns = @divFloor(@as(u64, 1_000_000_000), self.info.rate_hz);
        // A zero delay would disarm a timerfd, so the first repeat waits at least 1 ms.
        const delay_ns = @as(u64, @max(1, self.info.delay_ms)) * 1_000_000;
        assert(interval_ns >= 1);
        assert(self.code == code);
        return .{ .arm = .{ .delay_ns = delay_ns, .interval_ns = interval_ns } };
    }

    /// A release of `code`: disarms when it is the repeating key.
    pub fn release(self: *Repeat, code: u32) Arming {
        const held = self.code orelse return .keep;
        if (held != code) return .keep;
        self.code = null;
        assert(self.code == null);
        return .disarm;
    }

    /// Keyboard focus left, or the keymap changed: nothing repeats.
    pub fn stop(self: *Repeat) Arming {
        const was_held = self.code != null;
        self.code = null;
        assert(self.code == null);
        return if (was_held) .disarm else .keep;
    }

    /// New settings from `repeat_info`. A rate of 0 stops a running repeat.
    pub fn configure(self: *Repeat, rate_hz: i32, delay_ms: i32) Arming {
        self.info = .{
            .rate_hz = @intCast(@max(0, rate_hz)),
            .delay_ms = @intCast(@max(0, delay_ms)),
        };
        if (self.info.rate_hz == 0) return self.stop();
        return .keep;
    }
};

comptime {
    assert(queue_cap == 64);
    assert(key_count == 62);
    assert(key_count <= 64);
    assert(@sizeOf(Pointer) <= 16);
    assert(@sizeOf(Point) == 8);
    assert(@sizeOf(Button) == 16);
    assert(@sizeOf(Wheel) == 16);
    assert(@sizeOf(KeyPress) == 8);
    assert(@sizeOf(Mods) == 1);
    assert(@sizeOf(Event) <= 24);
    assert(drop_files_max <= 16);
    assert(drop_name_max <= 255);
}

const testing = std.testing;

fn button_at(x: f32, y: f32, time_ms: u32, which: MouseButton) Button {
    return .{ .x = x, .y = y, .time_ms = time_ms, .button = which, .mods = .none };
}

// Locks the 24.8 conversion used by `wl_pointer.enter` and `motion`.
test "fixed_to_logical converts 24.8" {
    try testing.expectEqual(@as(f32, 1), fixed_to_logical(256));
    try testing.expectEqual(@as(f32, -0.5), fixed_to_logical(-128));
    try testing.expectEqual(@as(f32, 0), fixed_to_logical(0));
    try testing.expectEqual(@as(f32, 10), fixed_to_logical(2560));
}

// Locks the wheel merge: three wheels occupy one slot, both deltas are summed, and the latest
// point wins.
test "consecutive wheels sum dx and dy" {
    var queue = EventQueue.init();
    queue.push(.{ .wheel = .{ .x = 1, .y = 2, .dx = 0, .dy = 3 } });
    queue.push(.{ .wheel = .{ .x = 4, .y = 5, .dx = 2, .dy = 0 } });
    queue.push(.{ .wheel = .{ .x = 7, .y = 8, .dx = 1, .dy = 9 } });
    try testing.expectEqual(@as(u32, 1), queue.count);
    const wheel = queue.pop().?.wheel;
    try testing.expectEqual(@as(f32, 7), wheel.x);
    try testing.expectEqual(@as(f32, 8), wheel.y);
    try testing.expectEqual(@as(f32, 3), wheel.dx);
    try testing.expectEqual(@as(f32, 12), wheel.dy);
}

// Locks that a wheel splits the motion stream, so it cannot collapse into either move.
test "a wheel between moves does not merge" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 1 } });
    queue.push(.{ .wheel = .{ .x = 1, .y = 1, .dx = 0, .dy = 4 } });
    queue.push(.{ .pointer_move = .{ .x = 2, .y = 2 } });
    try testing.expectEqual(@as(u32, 3), queue.count);
    try testing.expect(queue.pop().? == .pointer_move);
    try testing.expect(queue.pop().? == .wheel);
    try testing.expect(queue.pop().? == .pointer_move);
}

// Locks the move merge: three motions occupy one slot and the latest point wins.
test "consecutive moves coalesce" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 2 } });
    queue.push(.{ .pointer_move = .{ .x = 3, .y = 4 } });
    queue.push(.{ .pointer_move = .{ .x = 5, .y = 6 } });
    try testing.expectEqual(@as(u32, 1), queue.count);
    const point = queue.pop().?.pointer_move;
    try testing.expectEqual(@as(f32, 5), point.x);
    try testing.expectEqual(@as(f32, 6), point.y);
    try testing.expect(queue.pop() == null);
}

// Locks that a press splits the motion stream, so the click cannot collapse into the last
// move, and that key events never merge.
test "move down move up keeps four events" {
    var queue = EventQueue.init();
    queue.push(.{ .pointer_move = .{ .x = 1, .y = 1 } });
    queue.push(.{ .pointer_down = button_at(1, 1, 0, .left) });
    queue.push(.{ .pointer_move = .{ .x = 2, .y = 2 } });
    queue.push(.{ .pointer_up = button_at(2, 2, 5, .left) });
    const press = key_press(.a, .none, false, "a");
    queue.push(.{ .key_down = press });
    queue.push(.{ .key_down = press });
    try testing.expectEqual(@as(u32, 6), queue.count);
    try testing.expect(queue.pop().? == .pointer_move);
    try testing.expect(queue.pop().? == .pointer_down);
    try testing.expect(queue.pop().? == .pointer_move);
    try testing.expect(queue.pop().? == .pointer_up);
    try testing.expect(queue.pop().? == .key_down);
    try testing.expect(queue.pop().? == .key_down);
    try testing.expect(queue.pop() == null);
}

// Locks the drop rules: consecutive `drop_over`s keep the newest point in one slot, a
// `drop_leave` splits them, and the borrowed events are the three host-storage ones.
test "drop overs coalesce and a leave splits them" {
    var queue = EventQueue.init();
    queue.push(.{ .drop_over = .{ .x = 1, .y = 2 } });
    queue.push(.{ .drop_over = .{ .x = 3, .y = 4 } });
    queue.push(.drop_leave);
    queue.push(.{ .drop_over = .{ .x = 5, .y = 6 } });
    try testing.expectEqual(@as(u32, 3), queue.count);
    try testing.expectEqual(@as(f32, 3), queue.pop().?.drop_over.x);
    try testing.expect(queue.pop().? == .drop_leave);
    try testing.expectEqual(@as(f32, 6), queue.pop().?.drop_over.y);
    const drop: Drop = .{ .x = 0, .y = 0, .count = 0, .skipped = 0, .files = undefined };
    const chunk: Chunk = .{ .file = 0, .offset = 0, .bytes = "", .end = .done };
    try testing.expect((Event{ .drop = &drop }).borrowed());
    try testing.expect((Event{ .file = &chunk }).borrowed());
    try testing.expect((Event{ .paste = "a" }).borrowed());
    try testing.expect(!(Event{ .drop_over = .{ .x = 0, .y = 0 } }).borrowed());
    try testing.expectEqual(@as(usize, 0), drop.listed().len);
}

// Locks overflow: the press after `queue_cap` queued presses is counted and discarded;
// earlier ones stay.
test "overflow drops the newest event" {
    var queue = EventQueue.init();
    var index: u32 = 0;
    while (index < queue_cap) : (index += 1) {
        queue.push(.{ .pointer_down = button_at(0, 0, index, .left) });
    }
    try testing.expectEqual(queue_cap, queue.count);
    queue.push(.{ .pointer_down = button_at(9, 9, 99, .left) });
    try testing.expectEqual(@as(u32, 1), queue.dropped);
    try testing.expectEqual(queue_cap, queue.count);
    try testing.expectEqual(@as(f32, 0), queue.pop().?.pointer_down.x);
}

// Locks click counting: presses of one button within 400 ms and 4 px on each axis count up
// (across the u32 time wrap); a late, far, or other-button press restarts at 1.
test "clicks count within the interval and the slop" {
    var clicks = count_click(.none, button_at(10, 10, 1000, .left));
    try testing.expectEqual(@as(u8, 1), clicks.count);
    clicks = count_click(clicks, button_at(14, 6, 1400, .left));
    try testing.expectEqual(@as(u8, 2), clicks.count);
    clicks = count_click(clicks, button_at(14, 6, 1500, .left));
    try testing.expectEqual(@as(u8, 3), clicks.count);
    try testing.expectEqual(@as(u8, 1), count_click(clicks, button_at(14, 6, 1901, .left)).count);
    try testing.expectEqual(@as(u8, 1), count_click(clicks, button_at(18.5, 6, 1600, .left)).count);
    try testing.expectEqual(@as(u8, 1), count_click(clicks, button_at(14, 6, 1600, .right)).count);
    const before_wrap = count_click(.none, button_at(0, 0, 0xFFFF_FF00, .left));
    try testing.expectEqual(@as(u8, 2), count_click(before_wrap, button_at(0, 0, 50, .left)).count);
}

// Locks key naming from both sources: keysyms of either case, keypad navigation, and the DOM
// spellings map to the same keys; unknown names are `other`.
test "keysyms and DOM names map to the same keys" {
    try testing.expectEqual(Key.a, key_of_keysym('a'));
    try testing.expectEqual(Key.z, key_of_keysym('Z'));
    try testing.expectEqual(Key.d7, key_of_keysym('7'));
    try testing.expectEqual(Key.f12, key_of_keysym(0xFFC9));
    try testing.expectEqual(Key.left, key_of_keysym(0xFF96));
    try testing.expectEqual(Key.tab, key_of_keysym(0xFE20));
    try testing.expectEqual(Key.other, key_of_keysym(0xE4));
    try testing.expectEqual(Key.a, key_of_dom("A"));
    try testing.expectEqual(Key.d0, key_of_dom("0"));
    try testing.expectEqual(Key.f1, key_of_dom("F1"));
    try testing.expectEqual(Key.f12, key_of_dom("F12"));
    try testing.expectEqual(Key.other, key_of_dom("F13"));
    try testing.expectEqual(Key.page_down, key_of_dom("PageDown"));
    try testing.expectEqual(Key.escape, key_of_dom("Escape"));
    try testing.expectEqual(Key.other, key_of_dom("\u{e4}"));
    try testing.expectEqual(Key.other, key_of_dom("Dead"));
    try testing.expectEqual(@as(u64, 0), Key.other.bit());
    try testing.expectEqual(@as(u64, 1) << 61, Key.f12.bit());
}

// Locks the text filter: printable text rides on the press, while Ctrl or Meta, a C0 control,
// or DEL types nothing; Alt alone still types.
test "key presses carry printable text only without a shortcut modifier" {
    try testing.expectEqualStrings("a", key_press(.a, .none, false, "a").typed());
    try testing.expectEqualStrings("\u{e4}", key_press(.other, .none, false, "\u{e4}").typed());
    var ctrl = Mods.none;
    ctrl.ctrl = true;
    try testing.expectEqual(@as(u8, 0), key_press(.c, ctrl, false, "c").len);
    var meta = Mods.none;
    meta.meta = true;
    try testing.expectEqual(@as(u8, 0), key_press(.v, meta, false, "v").len);
    var alt = Mods.none;
    alt.alt = true;
    try testing.expectEqualStrings("@", key_press(.q, alt, false, "@").typed());
    try testing.expectEqual(@as(u8, 0), key_press(.enter, .none, false, "\r").len);
    try testing.expectEqual(@as(u8, 0), key_press(.backspace, .none, false, "\x08").len);
    try testing.expectEqual(@as(u8, 0), key_press(.delete, .none, false, "\x7f").len);
    try testing.expect(key_press(.a, .none, true, "a").repeat);
}

// Locks the compose split and the clipboard truncation: chunks hold whole codepoints of at most
// 4 bytes, and a truncation backs off to the last boundary at or under the limit.
test "text splits and truncates on codepoint boundaries" {
    const composed = "a\u{e9}\u{20ac}\u{1f3b9}";
    var offset: u32 = 0;
    try testing.expectEqualStrings("a\u{e9}", next_chunk(composed, &offset));
    try testing.expectEqualStrings("\u{20ac}", next_chunk(composed, &offset));
    try testing.expectEqualStrings("\u{1f3b9}", next_chunk(composed, &offset));
    try testing.expectEqual(@as(u32, composed.len), offset);
    const umlauts = "\u{e4}\u{f6}\u{fc}";
    try testing.expectEqual(@as(u32, 6), utf8_prefix(umlauts, 6));
    try testing.expectEqual(@as(u32, 4), utf8_prefix(umlauts, 5));
    try testing.expectEqual(@as(u32, 0), utf8_prefix(umlauts, 1));
    try testing.expectEqual(@as(u32, 0), utf8_prefix("\u{1f3b9}", 3));
    try testing.expectEqual(@as(u32, 2), utf8_prefix("ab", 9));
    try testing.expectEqual(@as(u32, 4), utf8_whole("ab\u{e4}"));
    try testing.expectEqual(@as(u32, 2), utf8_whole("ab\xc3"));
    try testing.expectEqual(@as(u32, 1), utf8_whole("a\xf0\x9f\x8e"));
    try testing.expectEqual(@as(u32, 0), utf8_whole(""));
}

// Locks repeat arming: a repeating press arms delay then 1 / rate, a modifier press keeps the
// timer, only the repeating key's release disarms, a rate of 0 disarms, and a leave disarms
// once.
test "repeat arms on a repeating press and disarms on its release" {
    var repeat = Repeat.init();
    const armed = repeat.press(30, true);
    try testing.expectEqual(@as(u64, 600_000_000), armed.arm.delay_ns);
    try testing.expectEqual(@as(u64, 40_000_000), armed.arm.interval_ns);
    try testing.expect(repeat.press(42, false) == .keep);
    try testing.expect(repeat.release(42) == .keep);
    try testing.expect(repeat.release(30) == .disarm);
    try testing.expect(repeat.release(30) == .keep);
    try testing.expect(repeat.configure(33, 250) == .keep);
    try testing.expectEqual(@as(u64, 250_000_000), repeat.press(31, true).arm.delay_ns);
    try testing.expect(repeat.stop() == .disarm);
    try testing.expect(repeat.stop() == .keep);
    _ = repeat.press(31, true);
    try testing.expect(repeat.configure(0, 250) == .disarm);
    try testing.expect(repeat.press(31, true) == .disarm);
}

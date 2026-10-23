//! The native clipboard: offering our copy as the selection and reading another client's
//! selection, through pipes the event loop polls. Non-generic; `linux_window.zig` owns one
//! static `Clipboard` and pumps it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Pipes in the Poll Set
//! A Wayland clipboard transfer is a pipe between two clients: the reader creates it and sends
//! the write end with `wl_data_offer.receive`; the owner gets that fd in
//! `wl_data_source.send` and writes. Either side may be slow or never finish, so both ends are
//! non-blocking and sit in the loop's `ppoll` set (`send_fd` for `POLLOUT`, `receive_fd` for
//! `POLLIN`); each wake moves what is ready and nothing blocks. A peer that stops reading or
//! writing costs no wakes: there is no timeout. It is closed when it is replaced: a new copy
//! or a `cancelled` source closes a send in progress, and a new paste closes a receive.
//!
//! ## 2. Copy
//! `copy(serial)` creates a `wl_data_source` offering `mimes` (UTF-8 plain text under its
//! three common names) and sets it as the selection with the serial of the key press that
//! asked. The bytes stay in the UI context (`cx.copied()`); `pump_send` writes them from
//! `send_offset`. One send slot: a `send` while one is running is closed at once.
//!
//! ## 3. Paste
//! Offers arrive as `data_offer` followed by their `offer` (mime) events, then `selection`
//! names the selection offer, or a drag-and-drop `enter` names one this host destroys.
//! `start_receive` picks the best text mime of the selection offer (`preferred_mime`), opens a
//! `pipe2(NONBLOCK)`, sends the write end, and closes it locally. `pump_receive` reads into the
//! static `receive_cap` buffer until end of file or until the buffer is full; then the receive
//! is complete, cut to whole codepoints (`input.utf8_whole`), and the host dispatches it as one
//! `paste` event. While this client owns the selection the host pastes from `cx.copied()`
//! directly.
//!
//! ## 4. Signals
//! Writing into a pipe whose reader closed raises `SIGPIPE`, which would end the process, so
//! the host ignores `SIGPIPE` at startup and `pump_send` treats `EPIPE` as a finished send.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage: two fds, two offers, one source, and one `receive_cap` buffer.
//! - Every read and write is non-blocking and bounded by the buffer.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const input = @import("../input.zig");
const data = @import("wl_data_device.zig");
const xdg = @import("xdg_shell.zig");

/// Bytes one paste may read; the rest of a larger selection is dropped.
pub const receive_cap: u32 = 65536;

/// A closed descriptor slot; `poll` ignores a negative fd.
pub const no_fd: i32 = -1;

/// The text mimes we offer and accept, best first.
pub const mimes = [_][*:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

/// The bit of `mime` in an offer's mime set, or 0 for a mime that is not text.
pub fn mime_bit(mime: []const u8) u8 {
    for (mimes, 0..) |known, index| {
        if (std.mem.eql(u8, std.mem.span(known), mime)) return @as(u8, 1) << @intCast(index);
    }
    return 0;
}

/// The best text mime in the set `bits`, or null.
pub fn preferred_mime(bits: u8) ?[*:0]const u8 {
    for (mimes, 0..) |known, index| {
        if (bits & (@as(u8, 1) << @intCast(index)) != 0) return known;
    }
    return null;
}

pub const Clipboard = struct {
    manager: ?*data.Manager,
    device: ?*data.Device,
    /// Our selection source while we own the selection.
    source: ?*data.Source,
    /// The newest offer, until `selection` or `enter` says what it is, and its mime set.
    pending: ?*data.Offer,
    pending_mimes: u8,
    /// The current selection offer and its mime set.
    selection: ?*data.Offer,
    selection_mimes: u8,
    send_fd: i32,
    send_offset: u32,
    receive_fd: i32,
    receive_len: u32,
    /// A finished receive waiting for the host to dispatch it.
    received: bool,
    buffer: [receive_cap]u8,

    pub fn init(self: *Clipboard) void {
        self.manager = null;
        self.device = null;
        self.source = null;
        self.pending = null;
        self.pending_mimes = 0;
        self.selection = null;
        self.selection_mimes = 0;
        self.send_fd = no_fd;
        self.send_offset = 0;
        self.receive_fd = no_fd;
        self.receive_len = 0;
        self.received = false;
        assert(self.source == null);
        assert(self.send_fd == no_fd);
    }

    /// Creates the data device for `seat` once both it and the manager exist.
    pub fn attach(self: *Clipboard, seat: *anyopaque) void {
        if (self.device != null) return;
        const manager = self.manager orelse return;
        const device = data.get_device(manager, @ptrCast(seat));
        data.add_device_listener(device, &device_listener, self);
        self.device = device;
        assert(self.device != null);
    }

    /// True while our source is the selection.
    pub fn owns_selection(self: *const Clipboard) bool {
        assert(self.send_offset <= receive_cap);
        return self.source != null;
    }

    /// Offers the context's copied text as the selection (section 2). `serial` is the serial
    /// of the input event that asked.
    pub fn copy(self: *Clipboard, serial: u32) void {
        const manager = self.manager orelse return;
        const device = self.device orelse return;
        self.close_send();
        if (self.source) |old| data.destroy_source(old);
        const source = data.create_source(manager);
        data.add_source_listener(source, &source_listener, self);
        for (mimes) |mime| data.source_offer(source, mime);
        data.set_selection(device, source, serial);
        self.source = source;
        assert(self.send_fd == no_fd);
    }

    /// Starts reading the selection offer (section 3). Returns false when there is no text
    /// to read.
    pub fn start_receive(self: *Clipboard) bool {
        const offer = self.selection orelse return false;
        const mime = preferred_mime(self.selection_mimes) orelse return false;
        self.close_receive();
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(rc) != .SUCCESS) return false;
        data.receive(offer, mime, fds[1]);
        // libwayland duplicated the write end while marshalling (wl_data_device.zig).
        _ = linux.close(fds[1]);
        self.receive_fd = fds[0];
        self.receive_len = 0;
        self.received = false;
        assert(self.receive_fd >= 0);
        return true;
    }

    /// Writes what the reader accepts of `bytes` from `send_offset`. Closes the fd when all of
    /// it is written or the reader is gone.
    pub fn pump_send(self: *Clipboard, bytes: []const u8) void {
        if (self.send_fd < 0) return;
        assert(self.send_offset <= bytes.len);
        var guard: u32 = 0;
        while (self.send_offset < bytes.len and guard < 64) : (guard += 1) {
            const rest = bytes[self.send_offset..];
            const rc = linux.write(self.send_fd, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => self.send_offset += @intCast(rc),
                .AGAIN => return,
                .INTR => continue,
                else => break,
            }
        }
        if (self.send_offset < bytes.len and guard < 64) {
            // An error other than AGAIN: the reader is gone.
            self.close_send();
            return;
        }
        if (self.send_offset == bytes.len) self.close_send();
    }

    /// Reads what is ready into the buffer. Marks the receive complete at end of file, on an
    /// error, or when the buffer is full (section 3).
    pub fn pump_receive(self: *Clipboard) void {
        if (self.receive_fd < 0) return;
        var guard: u32 = 0;
        while (self.receive_len < receive_cap and guard < 64) : (guard += 1) {
            const room = self.buffer[self.receive_len..];
            const rc = linux.read(self.receive_fd, room.ptr, room.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    self.receive_len += @intCast(rc);
                },
                .AGAIN => return,
                .INTR => continue,
                else => break,
            }
        }
        if (guard == 64) return;
        self.close_receive();
        self.receive_len = input.utf8_whole(self.buffer[0..self.receive_len]);
        self.received = true;
        assert(self.receive_len <= receive_cap);
    }

    /// The finished paste, once.
    pub fn take_received(self: *Clipboard) ?[]const u8 {
        if (!self.received) return null;
        self.received = false;
        assert(self.receive_len <= receive_cap);
        return self.buffer[0..self.receive_len];
    }

    fn close_send(self: *Clipboard) void {
        if (self.send_fd >= 0) _ = linux.close(self.send_fd);
        self.send_fd = no_fd;
        self.send_offset = 0;
        assert(self.send_fd == no_fd);
    }

    fn close_receive(self: *Clipboard) void {
        if (self.receive_fd >= 0) _ = linux.close(self.receive_fd);
        self.receive_fd = no_fd;
        assert(self.receive_fd == no_fd);
    }

    fn drop_pending(self: *Clipboard) void {
        if (self.pending) |offer| data.destroy_offer(offer);
        self.pending = null;
        self.pending_mimes = 0;
    }
};

// ---------------------------------------------------------------------- protocol listeners

const device_listener: data.DeviceListener = .{
    .data_offer = device_data_offer,
    .enter = device_enter,
    .leave = device_leave,
    .motion = device_motion,
    .drop = device_drop,
    .selection = device_selection,
};

const offer_listener: data.OfferListener = .{
    .offer = offer_mime,
    .source_actions = offer_actions,
    .action = offer_actions,
};

const source_listener: data.SourceListener = .{
    .target = source_target,
    .send = source_send,
    .cancelled = source_cancelled,
    .dnd_drop_performed = source_dnd,
    .dnd_finished = source_dnd,
    .action = source_action,
};

fn clipboard_of(pointer: ?*anyopaque) *Clipboard {
    assert(pointer != null);
    return @ptrCast(@alignCast(pointer.?));
}

/// A new offer: its mimes follow, then `selection` or `enter` says what it is.
fn device_data_offer(
    pointer: ?*anyopaque,
    device: ?*data.Device,
    offer: ?*data.Offer,
) callconv(.c) void {
    _ = device;
    const self = clipboard_of(pointer);
    const live = offer orelse return;
    self.drop_pending();
    data.add_offer_listener(live, &offer_listener, self);
    self.pending = live;
    assert(self.pending_mimes == 0);
}

/// Drag and drop is out of scope: its offer is destroyed.
fn device_enter(
    pointer: ?*anyopaque,
    device: ?*data.Device,
    serial: u32,
    surface: ?*xdg.WlSurface,
    x: i32,
    y: i32,
    offer: ?*data.Offer,
) callconv(.c) void {
    _ = device;
    _ = serial;
    _ = surface;
    _ = x;
    _ = y;
    const self = clipboard_of(pointer);
    const live = offer orelse return;
    if (self.pending == live) {
        self.drop_pending();
        return;
    }
    data.destroy_offer(live);
}

fn device_leave(pointer: ?*anyopaque, device: ?*data.Device) callconv(.c) void {
    _ = pointer;
    _ = device;
}

fn device_motion(
    pointer: ?*anyopaque,
    device: ?*data.Device,
    time: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    _ = pointer;
    _ = device;
    _ = time;
    _ = x;
    _ = y;
}

fn device_drop(pointer: ?*anyopaque, device: ?*data.Device) callconv(.c) void {
    _ = pointer;
    _ = device;
}

/// The selection changed: the named offer (or none) replaces the previous one.
fn device_selection(
    pointer: ?*anyopaque,
    device: ?*data.Device,
    offer: ?*data.Offer,
) callconv(.c) void {
    _ = device;
    const self = clipboard_of(pointer);
    if (self.selection) |old| {
        if (old != offer) data.destroy_offer(old);
    }
    self.selection = null;
    self.selection_mimes = 0;
    const live = offer orelse return;
    if (self.pending == live) {
        self.selection_mimes = self.pending_mimes;
        self.pending = null;
        self.pending_mimes = 0;
    }
    self.selection = live;
    assert(self.selection != null);
}

fn offer_mime(pointer: ?*anyopaque, offer: ?*data.Offer, mime: [*:0]const u8) callconv(.c) void {
    const self = clipboard_of(pointer);
    const bit = mime_bit(std.mem.span(mime));
    if (offer == self.pending) self.pending_mimes |= bit;
    if (offer == self.selection) self.selection_mimes |= bit;
}

fn offer_actions(pointer: ?*anyopaque, offer: ?*data.Offer, actions: u32) callconv(.c) void {
    _ = pointer;
    _ = offer;
    _ = actions;
}

fn source_target(
    pointer: ?*anyopaque,
    source: ?*data.Source,
    mime: ?[*:0]const u8,
) callconv(.c) void {
    _ = pointer;
    _ = source;
    _ = mime;
}

/// A reader wants our text in `fd`: take the one send slot, or close `fd` when it is busy.
fn source_send(
    pointer: ?*anyopaque,
    source: ?*data.Source,
    mime: [*:0]const u8,
    fd: i32,
) callconv(.c) void {
    _ = mime;
    const self = clipboard_of(pointer);
    assert(fd >= 0);
    if (self.send_fd >= 0 or source != self.source) {
        _ = linux.close(fd);
        return;
    }
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
    self.send_fd = fd;
    self.send_offset = 0;
}

/// Another client took the selection: our source and any send in progress end.
fn source_cancelled(pointer: ?*anyopaque, source: ?*data.Source) callconv(.c) void {
    const self = clipboard_of(pointer);
    const live = source orelse return;
    if (live == self.source) {
        self.close_send();
        self.source = null;
    }
    data.destroy_source(live);
}

fn source_dnd(pointer: ?*anyopaque, source: ?*data.Source) callconv(.c) void {
    _ = pointer;
    _ = source;
}

fn source_action(pointer: ?*anyopaque, source: ?*data.Source, action: u32) callconv(.c) void {
    _ = pointer;
    _ = source;
    _ = action;
}

comptime {
    assert(receive_cap == 65536);
    assert(mimes.len <= 8);
}

const testing = std.testing;

// Locks the mime choice: the three text names map to bits in preference order, other mimes
// are ignored, and the best offered one wins.
test "the best text mime of an offer is chosen" {
    try testing.expectEqual(@as(u8, 1), mime_bit("text/plain;charset=utf-8"));
    try testing.expectEqual(@as(u8, 2), mime_bit("UTF8_STRING"));
    try testing.expectEqual(@as(u8, 4), mime_bit("text/plain"));
    try testing.expectEqual(@as(u8, 0), mime_bit("image/png"));
    try testing.expectEqualStrings("UTF8_STRING", std.mem.span(preferred_mime(6).?));
    try testing.expectEqualStrings("text/plain;charset=utf-8", std.mem.span(preferred_mime(7).?));
    try testing.expectEqual(@as(?[*:0]const u8, null), preferred_mime(0));
}

// Locks the receive path without a display: a pipe holding more than `receive_cap` bytes that
// end inside a codepoint at the cap is read across pumps, cut to whole codepoints, and handed
// over once.
test "a receive stops at the cap on a codepoint boundary" {
    const static = struct {
        var clipboard: Clipboard = undefined;
    };
    const clipboard = &static.clipboard;
    clipboard.init();
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true })));
    clipboard.receive_fd = fds[0];
    var chunk: [4096]u8 = @splat('a');
    // The last chunk ends with the lead byte of "ä" exactly at the cap.
    var written: u32 = 0;
    while (written < receive_cap) {
        if (written + chunk.len == receive_cap) chunk[chunk.len - 1] = 0xC3;
        clipboard.pump_receive();
        const rc = linux.write(fds[1], &chunk, chunk.len);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        written += @intCast(rc);
    }
    _ = linux.write(fds[1], "\xa4tail", 5);
    clipboard.pump_receive();
    _ = linux.close(fds[1]);
    const pasted = clipboard.take_received().?;
    try testing.expectEqual(@as(usize, receive_cap - 1), pasted.len);
    try testing.expectEqual(no_fd, clipboard.receive_fd);
    try testing.expectEqual(@as(?[]const u8, null), clipboard.take_received());
}

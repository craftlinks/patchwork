//! Native file drops: the Wayland drag-and-drop offer, the `text/uri-list` it carries, and the
//! reads that deliver the accepted files. A field of `clipboard.Clipboard`, which owns the data
//! device and hands its drag events here; `linux_window.zig` pumps it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Offer
//! ```text
//! idle --enter(offer has text/uri-list, v3)--> hovering: set_actions(copy, copy), accept(null)
//!                                              queue drop_over
//! idle --enter(no uri-list, or below v3)-----> the offer is destroyed (the compositor shows
//!                                              no-drop)
//! hovering --motion--> queue drop_over (the queue coalesces them)
//! hovering --leave---> queue drop_leave; destroy the offer
//! hovering --drop----> accepted: receive the list through a pipe; else as leave
//! receiving --leave--> ignored: the offer lives until finish
//! receiving --EOF----> finish, destroy the offer; the loop builds and dispatches the drop
//! ```
//! Callbacks only store and queue. After each dispatch the loop calls `sync_accept` with
//! whether a drop target is under the drag (`cx.drop_wanted`), and a change sends `accept`
//! with `text/uri-list` or null and the enter serial, so the compositor shows a copy cursor
//! over drop zones only and refuses a drop elsewhere.
//!
//! ## 2. The List
//! The list arrives through a non-blocking pipe in the loop's poll set, into `list_cap`
//! bytes; a longer list keeps its whole lines and the rest is lost (the files are counted in
//! `skipped` only when they were seen). `take_drop` parses it (`drop.next_uri`) and examines
//! each path with `statx`, following symlinks: a regular file is readable with its size; a
//! directory, a FIFO, a device, or a path `statx` refuses is listed unreadable with size 0.
//! A non-regular file is never opened: opening a FIFO blocks.
//!
//! ## 3. Reading
//! `next_chunk` is the host's side of `drop.Transfer`: it opens the current file when its turn
//! comes (`O_RDONLY | O_CLOEXEC | O_NONBLOCK`; a file that is no longer regular fails), reads
//! `Read.len` bytes with `pread` at the read's offset into `chunk_cap` bytes, and returns the
//! chunk to dispatch, closing the file at its end. Regular files never report `EAGAIN`, so a
//! read can stall on slow storage; the loop bounds it to `drop.chunks_per_wake` reads per
//! wake and does not sleep while the transfer runs (`linux_window.zig`, section 5d).
//!
//! ## 4. Tests
//! Its tests read files and reference libwayland-client's proxy calls, so they live in
//! `dnd_test.zig`, which only the native test root (`native_tests.zig`) imports: a test in this
//! file would run in the library's pure root too, because `clipboard.zig` imports it.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage: one offer, two descriptors, the list bytes, one `drop.List`, one chunk.
//! - Every read and loop is bounded by its buffer or by `input.drop_files_max`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const input = @import("../input.zig");
const drop = @import("../drop.zig");
const data = @import("wl_data_device.zig");

/// Bytes of `text/uri-list` one drop reads.
pub const list_cap: u32 = 16384;
/// The mime a file drag must offer.
pub const uri_list_mime: [*:0]const u8 = "text/uri-list";
/// A closed descriptor slot; `poll` ignores a negative fd.
pub const no_fd: i32 = -1;
/// Longest path one URI decodes to.
const path_max: u32 = 4096;

pub const Phase = enum(u8) {
    idle,
    hovering,
    receiving,
};

pub const Dnd = struct {
    /// The loop's event queue, set once the loop's state exists.
    queue: ?*input.EventQueue,
    phase: Phase,
    offer: ?*data.Offer,
    serial: u32,
    /// The drag's last point, in surface coordinates.
    x: f32,
    y: f32,
    /// The last `accept` sent: true for `text/uri-list`.
    accepted: bool,
    list_fd: i32,
    list_len: u32,
    /// The list is complete; `take_drop` builds the drop.
    list_ready: bool,
    list_bytes: [list_cap]u8,
    list: drop.List,
    transfer: drop.Transfer,
    /// The open file of the transfer, and its index.
    file_fd: i32,
    file_index: u8,
    chunk_bytes: [drop.chunk_cap]u8,
    /// The chunk `next_chunk` returned, which the dispatch points at.
    chunk: input.Chunk,
    cancelled: [input.drop_files_max]input.Chunk,
    path: [path_max]u8,

    pub fn init(self: *Dnd) void {
        self.queue = null;
        self.phase = .idle;
        self.offer = null;
        self.serial = 0;
        self.x = 0;
        self.y = 0;
        self.accepted = false;
        self.list_fd = no_fd;
        self.list_len = 0;
        self.list_ready = false;
        self.transfer.init();
        self.file_fd = no_fd;
        self.file_index = 0;
        assert(self.phase == .idle);
    }

    /// True while the transfer has files to deliver: the loop does not sleep.
    pub fn busy(self: *const Dnd) bool {
        return self.transfer.running();
    }

    // ------------------------------------------------------------------- the offer

    /// A drag entered the surface with `offer`, whose mimes are `has_uri_list` or not.
    /// Returns false when the drag is not a file drag the host takes: the caller destroys it.
    pub fn enter(
        self: *Dnd,
        offer: *data.Offer,
        serial: u32,
        x: f32,
        y: f32,
        has_uri_list: bool,
    ) bool {
        if (!has_uri_list or data.offer_version(offer) < data.dnd_version) return false;
        if (self.phase == .receiving) return false;
        if (self.offer) |old| data.destroy_offer(old);
        self.offer = offer;
        self.serial = serial;
        self.phase = .hovering;
        self.accepted = false;
        data.set_actions(offer, data.action_copy, data.action_copy);
        data.accept(offer, serial, null);
        self.over(x, y);
        assert(self.offer != null);
        return true;
    }

    pub fn motion(self: *Dnd, x: f32, y: f32) void {
        if (self.phase != .hovering) return;
        self.over(x, y);
    }

    pub fn leave(self: *Dnd) void {
        if (self.phase != .hovering) return;
        self.push(.drop_leave);
        self.end_offer();
    }

    /// The drag dropped here: read the list when a target took it, else end as a leave.
    pub fn dropped(self: *Dnd) void {
        if (self.phase != .hovering) return;
        if (!self.accepted) return self.leave();
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(rc) != .SUCCESS) return self.leave();
        data.receive(self.offer.?, uri_list_mime, fds[1]);
        // libwayland duplicated the write end while marshalling (wl_data_device.zig).
        _ = linux.close(fds[1]);
        self.list_fd = fds[0];
        self.list_len = 0;
        self.phase = .receiving;
        assert(self.list_fd >= 0);
    }

    /// After a dispatch: tells the compositor whether a drop here would be taken (section 1).
    pub fn sync_accept(self: *Dnd, wanted: bool) void {
        if (self.phase != .hovering) return;
        if (wanted == self.accepted) return;
        data.accept(self.offer.?, self.serial, if (wanted) uri_list_mime else null);
        self.accepted = wanted;
    }

    fn over(self: *Dnd, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
        self.push(.{ .drop_over = .{ .x = x, .y = y } });
    }

    fn push(self: *Dnd, event: input.Event) void {
        const queue = self.queue orelse return;
        queue.push(event);
    }

    fn end_offer(self: *Dnd) void {
        if (self.offer) |offer| data.destroy_offer(offer);
        self.offer = null;
        self.phase = .idle;
        self.accepted = false;
        assert(self.offer == null);
    }

    // -------------------------------------------------------------------- the list

    /// Reads what is ready of the list; at the end (or a full buffer, or an error) finishes
    /// the offer and marks the list ready (section 2).
    pub fn pump_list(self: *Dnd) void {
        if (self.list_fd < 0) return;
        var guard: u32 = 0;
        while (self.list_len < list_cap and guard < 64) : (guard += 1) {
            const room = self.list_bytes[self.list_len..];
            const rc = linux.read(self.list_fd, room.ptr, room.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    self.list_len += @intCast(rc);
                },
                .AGAIN => return,
                .INTR => continue,
                else => break,
            }
        }
        if (guard == 64) return;
        _ = linux.close(self.list_fd);
        self.list_fd = no_fd;
        if (self.offer) |offer| data.finish(offer);
        self.end_offer();
        self.list_ready = true;
        assert(self.list_len <= list_cap);
    }

    /// The finished drop, once: the list parsed and each path examined (section 2).
    pub fn take_drop(self: *Dnd) ?*const input.Drop {
        if (!self.list_ready) return null;
        self.list_ready = false;
        self.list.reset(self.x, self.y);
        const bytes = self.list_bytes[0..self.list_len];
        var cursor: u32 = 0;
        var guard: u32 = 0;
        while (drop.next_uri(bytes, &cursor, self.path[0 .. path_max - 1])) |uri| : (guard += 1) {
            assert(guard <= list_cap);
            switch (uri) {
                .skipped => self.list.skip(),
                .path => |path| self.add_path(path),
            }
        }
        return self.list.files();
    }

    fn add_path(self: *Dnd, path: []const u8) void {
        assert(path.len < path_max);
        self.path[path.len] = 0;
        const terminated = self.path[0..path.len :0];
        var info: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .SIZE = true };
        const rc = linux.statx(linux.AT.FDCWD, terminated, 0, mask, &info);
        const examined = linux.errno(rc) == .SUCCESS and info.mask.TYPE;
        const regular = examined and linux.S.ISREG(info.mode) and info.mask.SIZE;
        const size: u64 = if (regular) info.size else 0;
        _ = self.list.add(path, drop.basename(path), size, regular);
    }

    // --------------------------------------------------------------------- reading

    /// Starts delivering the files in `mask` of the last drop. Nothing may be running.
    pub fn start(self: *Dnd, mask: u16) void {
        assert(!self.transfer.running());
        assert(self.file_fd == no_fd);
        self.transfer.begin(self.list.files(), mask);
    }

    /// Ends the files in `mask`; returns their cancelled chunks to dispatch (section 3).
    pub fn cancel(self: *Dnd, mask: u16) []const input.Chunk {
        const count = self.transfer.cancel(mask, &self.cancelled);
        if (self.file_fd >= 0 and mask & (@as(u16, 1) << @intCast(self.file_index)) != 0) {
            self.close_file();
        }
        if (!self.transfer.running()) self.close_file();
        return self.cancelled[0..count];
    }

    /// The next chunk to dispatch, reading it from its file, or null when the transfer ended.
    pub fn next_chunk(self: *Dnd) ?*const input.Chunk {
        const next = self.transfer.next() orelse {
            self.close_file();
            return null;
        };
        switch (next) {
            .end => |end| self.chunk = end,
            .read => |read| self.chunk = self.read_chunk(read),
        }
        if (self.chunk.end != .more) self.close_file();
        return &self.chunk;
    }

    fn read_chunk(self: *Dnd, read: drop.Read) input.Chunk {
        assert(read.len >= 1);
        assert(read.len <= drop.chunk_cap);
        if (self.file_fd < 0 or self.file_index != read.file) {
            self.close_file();
            if (!self.open_file(read.file)) {
                return self.transfer.complete(read.ticket, &.{}, true).?;
            }
        }
        const out = self.chunk_bytes[0..read.len];
        var got: u32 = 0;
        var failed = false;
        var guard: u32 = 0;
        while (got < read.len and guard < 16) : (guard += 1) {
            const rest = out[got..];
            const rc = linux.pread(self.file_fd, rest.ptr, rest.len, @intCast(read.offset + got));
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    got += @intCast(rc);
                },
                .INTR, .AGAIN => continue,
                else => {
                    failed = true;
                    break;
                },
            }
        }
        return self.transfer.complete(read.ticket, out[0..got], failed).?;
    }

    /// Opens listed file `index` for reading; false when it cannot be or is not regular.
    fn open_file(self: *Dnd, index: u8) bool {
        assert(self.file_fd == no_fd);
        const path = self.list.path(index);
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true };
        const rc = linux.open(path.ptr, flags, 0);
        if (linux.errno(rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(rc);
        var info: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true };
        const stat_rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &info);
        if (linux.errno(stat_rc) != .SUCCESS or !linux.S.ISREG(info.mode)) {
            _ = linux.close(fd);
            return false;
        }
        self.file_fd = fd;
        self.file_index = index;
        return true;
    }

    fn close_file(self: *Dnd) void {
        if (self.file_fd >= 0) _ = linux.close(self.file_fd);
        self.file_fd = no_fd;
    }
};

comptime {
    assert(list_cap == drop.paths_cap);
    assert(path_max <= drop.paths_cap);
}

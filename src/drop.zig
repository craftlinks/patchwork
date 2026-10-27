//! File drops: the list of dropped files, the `text/uri-list` parser, and the transfer state
//! machine every host drives to deliver the files' bytes as `input.Chunk`s.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why One Transfer for Every Host
//! The native host reads files with `read`, the browser with `File.slice`, and bench replays
//! from bytes in the scenario. If each host cut its own chunks, an app's decoder would see
//! different splits natively, in the browser, and in regress, and the exactly-once contract
//! (`input.zig`, section 6) would be written three times. So the hosts only fill a buffer:
//! ```text
//! host                                  Transfer
//!   begin(drop, mask)          ------>  pending = mask, the first file current
//!   next()                     <------  .read {ticket, file, offset, len} or .end (a chunk)
//!   read len bytes at offset
//!   complete(ticket, bytes)    <------  the chunk to dispatch, or null for a stale ticket
//!   cancel(mask, out)          <------  the cancelled chunks, in file order
//! ```
//! `len` is `min(chunk_cap, size - offset)`, so a file of `size` bytes arrives in chunks of
//! `chunk_cap` but the last, and the chunk that reaches `size` is `done`. An empty file and an
//! unreadable one end at once (`.end`: `done` or `failed`, no bytes). A read that returns fewer
//! bytes than asked, or fails, ends its file as `failed`. Files go in index order, the current
//! one being the lowest bit still pending.
//!
//! ## 2. Tickets
//! Every `next` that hands out a read and every cancel bump `ticket`. `complete` with an older
//! ticket changes nothing and returns null, so a browser read that resolves after its file was
//! cancelled is ignored. One read is outstanding at a time (asserted).
//!
//! ## 3. The List
//! `List` builds the `input.Drop` a host dispatches: base names cut to `input.drop_name_max`
//! bytes on a codepoint boundary, with bytes that are not UTF-8 shown as '?', and (natively)
//! the full paths, NUL-terminated for `open`. A file past `input.drop_files_max` or past the
//! path room is counted in `skipped`.
//!
//! ## 4. URI Lists
//! A native drag offers `text/uri-list` (RFC 2483): one URI per line, CRLF (or LF), `#` lines
//! and blank lines skipped. `next_uri` returns the percent-decoded path of a `file:` URI whose
//! host is empty or `localhost` (`file:///a/b`, `file://localhost/a/b`, `file:/a/b`), and
//! `.skipped` for every other line, a path that does not fit, or one holding a NUL. A `%`
//! not followed by two hex digits is kept as it is.
//!
//! ## 5. TigerStyle Invariants
//! - Fixed storage: `input.drop_files_max` sizes, names, and paths; no allocation.
//! - Every loop is bounded by the files, the input bytes, or the output room.

const std = @import("std");
const assert = std.debug.assert;
const input = @import("input.zig");

/// Bytes of one chunk: every file but its last chunk arrives in pieces of exactly this size.
pub const chunk_cap: u32 = 65536;
/// Chunks the native host reads per wake of its loop (256 KiB).
pub const chunks_per_wake: u32 = 4;
/// Bytes of the full paths one native drop keeps, NUL terminators included.
pub const paths_cap: u32 = 16384;
/// Bytes of the names one drop keeps.
pub const names_cap: u32 = input.drop_files_max * input.drop_name_max;

const files_max = input.drop_files_max;
const all_files: u16 = std.math.maxInt(u16);

comptime {
    assert(files_max <= 16);
    assert(std.math.isPowerOfTwo(chunk_cap));
    assert(chunks_per_wake >= 1);
    assert(paths_cap >= files_max * 2);
}

// ----------------------------------------------------------------------------------- list

/// The files of one drop, in fixed storage (section 3).
pub const List = struct {
    drop: input.Drop,
    names: [names_cap]u8,
    names_len: u32,
    paths: [paths_cap]u8,
    paths_len: u32,
    /// Each listed file's path in `paths`, as start and length without the NUL.
    spans: [files_max][2]u32,

    /// Empties the list for a drop at `(x, y)`.
    pub fn reset(self: *List, x: f32, y: f32) void {
        assert(x == x);
        assert(y == y);
        self.drop = .{ .x = x, .y = y, .count = 0, .skipped = 0, .files = undefined };
        self.names_len = 0;
        self.paths_len = 0;
        assert(self.drop.count == 0);
    }

    /// Lists one file: its full path `full` (empty in the browser), its `name`, its size, and
    /// whether it can be read. False, with the file counted as skipped, when the list or the
    /// path room is full.
    pub fn add(self: *List, full: []const u8, name: []const u8, size: u64, readable: bool) bool {
        assert(self.drop.count <= files_max);
        assert(self.names_len <= names_cap);
        if (self.drop.count == files_max or full.len + 1 > paths_cap - self.paths_len) {
            self.skip();
            return false;
        }
        const index = self.drop.count;
        @memcpy(self.paths[self.paths_len..][0..full.len], full);
        self.paths[self.paths_len + full.len] = 0;
        self.spans[index] = .{ self.paths_len, @intCast(full.len) };
        self.paths_len += @intCast(full.len + 1);
        const room = self.names[self.names_len..][0..input.drop_name_max];
        const name_len = clean_name(name, room);
        self.drop.files[index] = .{
            .name = room[0..name_len],
            .size = size,
            .readable = readable,
        };
        self.names_len += name_len;
        self.drop.count += 1;
        assert(self.names_len <= names_cap);
        assert(self.paths_len <= paths_cap);
        return true;
    }

    /// Counts a file that is not listed (not a local file, or no room).
    pub fn skip(self: *List) void {
        self.drop.skipped +|= 1;
        assert(self.drop.skipped >= 1);
    }

    /// The drop to dispatch.
    pub fn files(self: *const List) *const input.Drop {
        assert(self.drop.count <= files_max);
        return &self.drop;
    }

    /// The full path of listed file `index`, NUL-terminated.
    pub fn path(self: *const List, index: u32) [:0]const u8 {
        assert(index < self.drop.count);
        const span = self.spans[index];
        assert(self.paths[span[0] + span[1]] == 0);
        return self.paths[span[0]..][0..span[1] :0];
    }
};

/// Copies `name` into `out` as UTF-8: whole codepoints while they fit, every byte that does
/// not start a valid sequence as '?'. Returns the bytes written.
pub fn clean_name(name: []const u8, out: []u8) u32 {
    assert(out.len >= 1);
    var read: usize = 0;
    var written: u32 = 0;
    while (read < name.len) {
        const length = std.unicode.utf8ByteSequenceLength(name[read]) catch 0;
        const valid = length != 0 and read + length <= name.len and
            decodes(name[read..][0..length]);
        const take: u32 = if (valid) length else 1;
        if (written + take > out.len) break;
        if (valid) {
            @memcpy(out[written..][0..take], name[read..][0..take]);
        } else {
            out[written] = '?';
        }
        written += take;
        read += take;
    }
    assert(written <= out.len);
    return written;
}

fn decodes(sequence: []const u8) bool {
    assert(sequence.len >= 1);
    assert(sequence.len <= 4);
    _ = std.unicode.utf8Decode(sequence) catch return false;
    return true;
}

/// The last component of `path`, ignoring trailing slashes ("/a/b/" is "b").
pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const head = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, head, '/') orelse return head;
    if (slash + 1 == end) return head;
    const name = head[slash + 1 ..];
    assert(name.len >= 1);
    return name;
}

// ------------------------------------------------------------------------------ uri lists

/// One line of a `text/uri-list` (section 4): a local path, or a line that is not one.
pub const Uri = union(enum) {
    path: []const u8,
    skipped,
};

/// The next URI of `bytes` from `cursor`, decoding a local path into `out`; null at the end.
pub fn next_uri(bytes: []const u8, cursor: *u32, out: []u8) ?Uri {
    assert(cursor.* <= bytes.len);
    while (cursor.* < bytes.len) {
        const start = cursor.*;
        const rest = bytes[start..];
        const newline = std.mem.indexOfScalar(u8, rest, '\n');
        var line = rest[0 .. newline orelse rest.len];
        cursor.* = start + @as(u32, @intCast(line.len)) + @intFromBool(newline != null);
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        return uri_path(line, out);
    }
    assert(cursor.* == bytes.len);
    return null;
}

fn uri_path(line: []const u8, out: []u8) Uri {
    assert(line.len >= 1);
    if (!std.ascii.startsWithIgnoreCase(line, "file:")) return .skipped;
    var rest = line["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return .skipped;
        const host = after[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return .skipped;
        rest = after[slash..];
    }
    if (rest.len == 0 or rest[0] != '/') return .skipped;
    const length = percent_decode(rest, out) orelse return .skipped;
    if (std.mem.indexOfScalar(u8, out[0..length], 0) != null) return .skipped;
    return .{ .path = out[0..length] };
}

/// Decodes `%XX` escapes of `text` into `out`; null when it does not fit.
pub fn percent_decode(text: []const u8, out: []u8) ?u32 {
    var read: usize = 0;
    var written: u32 = 0;
    while (read < text.len) {
        if (written == out.len) return null;
        var byte = text[read];
        var step: usize = 1;
        if (byte == '%' and read + 2 < text.len) {
            const high = std.fmt.charToDigit(text[read + 1], 16) catch null;
            const low = std.fmt.charToDigit(text[read + 2], 16) catch null;
            if (high != null and low != null) {
                byte = high.? * 16 + low.?;
                step = 3;
            }
        }
        out[written] = byte;
        written += 1;
        read += step;
    }
    assert(written <= out.len);
    return written;
}

// ------------------------------------------------------------------------------- transfer

/// A read the host performs: `len` bytes of `file` at `offset` (section 1).
pub const Read = struct {
    ticket: u32,
    file: u8,
    offset: u64,
    len: u32,
};

/// What the host does next: a read, or a chunk to dispatch at once (an empty or unreadable
/// file's end, which carries no bytes).
pub const Next = union(enum) {
    read: Read,
    end: input.Chunk,
};

/// The transfer state machine (section 1).
pub const Transfer = struct {
    sizes: [files_max]u64,
    readable: u16,
    /// Accepted files that have not ended; the lowest bit is the current file.
    pending: u16,
    /// Bytes of the current file delivered so far.
    offset: u64,
    ticket: u32,
    /// A read is out: `next` returned it and `complete` has not.
    reading: bool,
    current_len: u32,

    pub fn init(self: *Transfer) void {
        self.readable = 0;
        self.pending = 0;
        self.offset = 0;
        self.ticket = 0;
        self.reading = false;
        self.current_len = 0;
        assert(!self.running());
    }

    /// True while an accepted file has not ended.
    pub fn running(self: *const Transfer) bool {
        assert(!self.reading or self.pending != 0);
        return self.pending != 0;
    }

    /// Starts delivering the files of `drop` in `mask`. A transfer still running must be
    /// cancelled first.
    pub fn begin(self: *Transfer, drop: *const input.Drop, mask: u16) void {
        assert(!self.running());
        assert(mask != 0);
        assert(drop.count <= files_max);
        const listed: u16 = if (drop.count == files_max)
            all_files
        else
            (@as(u16, 1) << @intCast(drop.count)) - 1;
        assert(mask & ~listed == 0);
        self.readable = 0;
        for (drop.listed(), 0..) |file, index| {
            self.sizes[index] = file.size;
            if (file.readable) self.readable |= @as(u16, 1) << @intCast(index);
        }
        self.pending = mask;
        self.offset = 0;
        self.reading = false;
        self.ticket +%= 1;
        assert(self.running());
    }

    /// The next read, or an end to dispatch, or null when every accepted file ended.
    pub fn next(self: *Transfer) ?Next {
        assert(!self.reading);
        if (self.pending == 0) return null;
        const file = self.current();
        const bit = @as(u16, 1) << @intCast(file);
        if (self.readable & bit == 0) return .{ .end = self.finish(file, .failed) };
        const size = self.sizes[file];
        assert(self.offset < size or (size == 0 and self.offset == 0));
        if (size == 0) return .{ .end = self.finish(file, .done) };
        const left = size - self.offset;
        const len: u32 = @intCast(@min(left, chunk_cap));
        self.ticket +%= 1;
        self.reading = true;
        self.current_len = len;
        assert(len >= 1);
        const read: Read = .{
            .ticket = self.ticket,
            .file = file,
            .offset = self.offset,
            .len = len,
        };
        return .{ .read = read };
    }

    /// The chunk of a finished read whose bytes the host put in `bytes`, or null when the
    /// ticket is stale (the file was cancelled meanwhile). Fewer bytes than asked, or
    /// `failed`, end the file as failed.
    pub fn complete(self: *Transfer, ticket: u32, bytes: []const u8, failed: bool) ?input.Chunk {
        if (!self.reading or ticket != self.ticket) return null;
        assert(self.pending != 0);
        self.reading = false;
        const file = self.current();
        if (failed or bytes.len != self.current_len) return self.finish(file, .failed);
        const offset = self.offset;
        self.offset += bytes.len;
        assert(self.offset <= self.sizes[file]);
        if (self.offset == self.sizes[file]) {
            self.pending &= ~(@as(u16, 1) << @intCast(file));
            self.offset = 0;
            return .{ .file = file, .offset = offset, .bytes = bytes, .end = .done };
        }
        return .{ .file = file, .offset = offset, .bytes = bytes, .end = .more };
    }

    /// Ends the pending files in `mask`: writes their `cancelled` chunks into `out` in file
    /// order and returns how many. An outstanding read of a cancelled file goes stale.
    pub fn cancel(self: *Transfer, mask: u16, out: *[files_max]input.Chunk) u32 {
        var count: u32 = 0;
        const ending = self.pending & mask;
        if (ending == 0) return 0;
        const head = self.current();
        var bits = ending;
        var guard: u32 = 0;
        while (bits != 0 and guard < files_max) : (guard += 1) {
            const file: u8 = @ctz(bits);
            bits &= bits - 1;
            const offset = if (file == head) self.offset else 0;
            out[count] = .{ .file = file, .offset = offset, .bytes = &.{}, .end = .cancelled };
            count += 1;
        }
        if (ending & (@as(u16, 1) << @intCast(head)) != 0) {
            self.offset = 0;
            self.reading = false;
            self.ticket +%= 1;
        }
        self.pending &= ~ending;
        assert(count >= 1);
        assert(self.pending & mask == 0);
        return count;
    }

    fn current(self: *const Transfer) u8 {
        assert(self.pending != 0);
        return @ctz(self.pending);
    }

    fn finish(self: *Transfer, file: u8, end: input.ChunkEnd) input.Chunk {
        assert(end != .more);
        assert(file == self.current());
        const chunk: input.Chunk = .{
            .file = file,
            .offset = self.offset,
            .bytes = &.{},
            .end = end,
        };
        self.pending &= ~(@as(u16, 1) << @intCast(file));
        self.offset = 0;
        return chunk;
    }
};

// ---------------------------------------------------------------------------------- tests

const testing = std.testing;

fn test_drop(sizes: []const u64, readable: []const bool) input.Drop {
    var drop: input.Drop = .{
        .x = 0,
        .y = 0,
        .count = @intCast(sizes.len),
        .skipped = 0,
        .files = undefined,
    };
    for (sizes, readable, 0..) |size, can_read, index| {
        drop.files[index] = .{ .name = "f", .size = size, .readable = can_read };
    }
    return drop;
}

/// Runs a transfer to its end with reads that always succeed and records each chunk as
/// (file, offset, length, end) into `out`; returns the count.
fn run_all(transfer: *Transfer, buffer: []u8, out: [][4]u64) u32 {
    var count: u32 = 0;
    var guard: u32 = 0;
    while (transfer.next()) |step| : (guard += 1) {
        assert(guard < 1000);
        const chunk = switch (step) {
            .end => |end| end,
            .read => |read| transfer.complete(read.ticket, buffer[0..read.len], false).?,
        };
        out[count] = .{ chunk.file, chunk.offset, chunk.bytes.len, @backingInt(chunk.end) };
        count += 1;
    }
    return count;
}

const more: u64 = @backingInt(input.ChunkEnd.more);
const done: u64 = @backingInt(input.ChunkEnd.done);

// Locks the chunking contract (`input.zig`, section 6): sizes 0, 1, 65,536, 65,537, and
// 200,000 arrive as one empty done; one done of 1; one done of 65,536; 65,536 more then 1
// done; three of 65,536 more then 3,392 done, in file order.
test "files arrive in exact chunks with one done each" {
    const static = struct {
        var buffer: [chunk_cap]u8 = undefined;
    };
    const drop = test_drop(&.{ 0, 1, 65536, 65537, 200000 }, &.{ true, true, true, true, true });
    var transfer: Transfer = undefined;
    transfer.init();
    transfer.begin(&drop, 0b11111);
    var out: [16][4]u64 = undefined;
    const count = run_all(&transfer, &static.buffer, &out);
    const expected = [_][4]u64{
        .{ 0, 0, 0, done },
        .{ 1, 0, 1, done },
        .{ 2, 0, 65536, done },
        .{ 3, 0, 65536, more },
        .{ 3, 65536, 1, done },
        .{ 4, 0, 65536, more },
        .{ 4, 65536, 65536, more },
        .{ 4, 131072, 65536, more },
        .{ 4, 196608, 3392, done },
    };
    try testing.expectEqual(@as(u32, expected.len), count);
    try testing.expectEqualSlices([4]u64, &expected, out[0..count]);
    try testing.expect(!transfer.running());
}

// Locks the ends that carry no bytes: an accepted unreadable file is one failed chunk, an
// unaccepted file sends nothing, and a short read fails its file at the offset reached.
test "an unreadable file fails at once and a short read fails its file" {
    const static = struct {
        var buffer: [chunk_cap]u8 = undefined;
    };
    const drop = test_drop(&.{ 10, 100000, 5 }, &.{ false, true, true });
    var transfer: Transfer = undefined;
    transfer.init();
    transfer.begin(&drop, 0b011);
    const first = transfer.next().?.end;
    try testing.expectEqual(input.ChunkEnd.failed, first.end);
    try testing.expectEqual(@as(u8, 0), first.file);
    const read = transfer.next().?.read;
    try testing.expectEqual(@as(u32, 65536), read.len);
    const first_chunk = transfer.complete(read.ticket, static.buffer[0..65536], false).?;
    try testing.expectEqual(input.ChunkEnd.more, first_chunk.end);
    const second = transfer.next().?.read;
    try testing.expectEqual(@as(u32, 100000 - 65536), second.len);
    const short = transfer.complete(second.ticket, static.buffer[0..10], false).?;
    try testing.expectEqual(input.ChunkEnd.failed, short.end);
    try testing.expectEqual(@as(u64, 65536), short.offset);
    try testing.expectEqual(@as(usize, 0), short.bytes.len);
    try testing.expectEqual(@as(?Next, null), transfer.next());
}

// Locks cancel: cancelling the current file mid-way and a later one gives one cancelled chunk
// each in file order (the current at its offset), the outstanding read goes stale, and the
// file between them still arrives in full.
test "cancel ends the masked files and a stale read is ignored" {
    const static = struct {
        var buffer: [chunk_cap]u8 = undefined;
    };
    const drop = test_drop(&.{ 200000, 3, 7 }, &.{ true, true, true });
    var transfer: Transfer = undefined;
    transfer.init();
    transfer.begin(&drop, 0b111);
    const read = transfer.next().?.read;
    _ = transfer.complete(read.ticket, static.buffer[0..read.len], false).?;
    const outstanding = transfer.next().?.read;
    var out: [files_max]input.Chunk = undefined;
    const count = transfer.cancel(0b101, &out);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expectEqual(@as(u8, 0), out[0].file);
    try testing.expectEqual(@as(u64, 65536), out[0].offset);
    try testing.expectEqual(input.ChunkEnd.cancelled, out[0].end);
    try testing.expectEqual(@as(u8, 2), out[1].file);
    try testing.expectEqual(@as(u64, 0), out[1].offset);
    const stale = transfer.complete(outstanding.ticket, static.buffer[0..outstanding.len], false);
    try testing.expectEqual(@as(?input.Chunk, null), stale);
    var rest: [4][4]u64 = undefined;
    try testing.expectEqual(@as(u32, 1), run_all(&transfer, &static.buffer, &rest));
    try testing.expectEqual([4]u64{ 1, 0, 3, done }, rest[0]);
    try testing.expectEqual(@as(u32, 0), transfer.cancel(all_files, &out));
}

// Locks the URI list forms: GNOME's and KDE's file URIs with escapes, a localhost host, the
// one-slash form, a comment, a blank line, a bare LF, another host, another scheme, a NUL
// escape, and a path that does not fit.
test "a uri list yields local paths and skips the rest" {
    const list = "# comment\r\nfile:///home/a/My%20Song.wav\r\n" ++
        "file://localhost/tmp/b%C3%A4.txt\r\n\r\nfile:/c\nhttps://example.com/x\r\n" ++
        "file://server/share/y\r\nfile:///z%00\r\nfile:///100%\r\n" ++
        "file:///a-much-longer-name";
    var out: [12]u8 = undefined;
    var cursor: u32 = 0;
    var wide: [64]u8 = undefined;
    try testing.expectEqualStrings("/home/a/My Song.wav", next_uri(list, &cursor, &wide).?.path);
    try testing.expectEqualStrings("/tmp/b\u{e4}.txt", next_uri(list, &cursor, &wide).?.path);
    try testing.expectEqualStrings("/c", next_uri(list, &cursor, &wide).?.path);
    try testing.expectEqual(Uri.skipped, next_uri(list, &cursor, &wide).?);
    try testing.expectEqual(Uri.skipped, next_uri(list, &cursor, &wide).?);
    try testing.expectEqual(Uri.skipped, next_uri(list, &cursor, &wide).?);
    try testing.expectEqualStrings("/100%", next_uri(list, &cursor, &wide).?.path);
    try testing.expectEqual(Uri.skipped, next_uri(list, &cursor, &out).?);
    try testing.expectEqual(@as(?Uri, null), next_uri(list, &cursor, &wide));
    try testing.expectEqual(@as(u32, list.len), cursor);
}

// Locks the list: names are base names, cut to 255 bytes on a codepoint, invalid bytes shown
// as '?', paths kept NUL-terminated, and a 17th file is skipped.
test "the list keeps names, paths, and counts what does not fit" {
    const static = struct {
        var list: List = undefined;
    };
    const list = &static.list;
    list.reset(5, 6);
    try testing.expect(list.add("/a/b/kick.wav", basename("/a/b/kick.wav"), 10, true));
    try testing.expect(list.add("/a/bad\xff.wav", basename("/a/bad\xff.wav"), 1, true));
    var long: [400]u8 = undefined;
    for (0..200) |pair| long[2 * pair ..][0..2].* = "\u{e4}".*;
    try testing.expect(list.add("", &long, 0, false));
    try testing.expectEqualStrings("kick.wav", list.files().files[0].name);
    try testing.expectEqualStrings("/a/b/kick.wav", list.path(0));
    try testing.expectEqualStrings("bad?.wav", list.files().files[1].name);
    try testing.expectEqual(@as(usize, 254), list.files().files[2].name.len);
    try testing.expect(std.unicode.utf8ValidateSlice(list.files().files[2].name));
    var index: u32 = 3;
    while (index < files_max) : (index += 1) try testing.expect(list.add("/x", "x", 0, true));
    try testing.expect(!list.add("/y", "y", 0, true));
    try testing.expectEqual(@as(u8, 16), list.files().count);
    try testing.expectEqual(@as(u16, 1), list.files().skipped);
    try testing.expectEqualStrings("samples", basename("/home/a/samples/"));
    try testing.expectEqualStrings("/", basename("/"));
}

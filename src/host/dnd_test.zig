//! The tests of `dnd.zig`: a received uri list becomes a drop, and its files are read and
//! cancelled through real descriptors. Imported only by `native_tests.zig` (`dnd.zig`,
//! section 4).

const std = @import("std");
const linux = std.os.linux;
const input = @import("../input.zig");
const drop = @import("../drop.zig");
const dnd_module = @import("dnd.zig");
const Dnd = dnd_module.Dnd;
const no_fd = dnd_module.no_fd;
const write_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };

const testing = std.testing;

/// A static `Dnd` for tests, initialized.
fn test_dnd() *Dnd {
    const static = struct {
        var dnd: Dnd = undefined;
    };
    static.dnd.init();
    return &static.dnd;
}

// Locks the list path without a display: a uri-list written into the receive pipe in two
// writes is read to its end, and `take_drop` lists a regular file with its size, a directory
// and a FIFO as unreadable (never opened), skips an https line, and hands the drop over once.
test "a received uri list becomes a drop of examined files" {
    const dnd = test_dnd();
    var dir_buffer: [64]u8 = undefined;
    const pid = linux.getpid();
    const dir = try std.fmt.bufPrintSentinel(&dir_buffer, "/tmp/patchwork-dnd-{d}", .{pid}, 0);
    _ = linux.mkdir(dir, 0o700);
    defer _ = linux.rmdir(dir);
    var file_buffer: [96]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buffer, "{s}/a b.raw", .{dir}, 0);
    const fd: i32 = @intCast(linux.open(file, write_flags, 0o600));
    defer _ = linux.unlink(file);
    var payload: [70000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    try testing.expectEqual(@as(usize, payload.len), linux.write(fd, &payload, payload.len));
    _ = linux.close(fd);
    var fifo_buffer: [96]u8 = undefined;
    const fifo = try std.fmt.bufPrintSentinel(&fifo_buffer, "{s}/pipe", .{dir}, 0);
    const made = linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(@as(usize, 0), made);
    defer _ = linux.unlink(fifo);
    var list_buffer: [512]u8 = undefined;
    const form = "file://{s}/a%20b.raw\r\nfile://{s}\r\nhttps://x/y\r\nfile://{s}\r\n";
    const list = try std.fmt.bufPrint(&list_buffer, form, .{ dir, dir, fifo });
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true })));
    dnd.list_fd = fds[0];
    _ = linux.write(fds[1], list.ptr, 10);
    dnd.pump_list();
    try testing.expect(!dnd.list_ready);
    _ = linux.write(fds[1], list[10..].ptr, list.len - 10);
    _ = linux.close(fds[1]);
    dnd.pump_list();
    try testing.expect(dnd.list_ready);
    try testing.expectEqual(no_fd, dnd.list_fd);
    const files = dnd.take_drop().?;
    try testing.expectEqual(@as(?*const input.Drop, null), dnd.take_drop());
    try testing.expectEqual(@as(u8, 3), files.count);
    try testing.expectEqual(@as(u16, 1), files.skipped);
    try testing.expectEqualStrings("a b.raw", files.files[0].name);
    try testing.expectEqual(@as(u64, 70000), files.files[0].size);
    try testing.expect(files.files[0].readable);
    try testing.expect(!files.files[1].readable);
    try testing.expectEqualStrings("pipe", files.files[2].name);
    try testing.expect(!files.files[2].readable);

    // Locks the reads over the same drop: the file in two chunks with its bytes, then the
    // two unreadable ones failed, then nothing; no descriptor stays open.
    dnd.start(0b111);
    const first = dnd.next_chunk().?;
    try testing.expectEqual(input.ChunkEnd.more, first.end);
    try testing.expectEqual(@as(usize, 65536), first.bytes.len);
    try testing.expectEqual(@as(u8, 255), first.bytes[255]);
    try testing.expect(dnd.file_fd >= 0);
    const second = dnd.next_chunk().?;
    try testing.expectEqual(input.ChunkEnd.done, second.end);
    try testing.expectEqual(@as(u64, 65536), second.offset);
    try testing.expectEqual(@as(usize, 70000 - 65536), second.bytes.len);
    try testing.expectEqual(@as(u8, @truncate(65536)), second.bytes[0]);
    try testing.expectEqual(no_fd, dnd.file_fd);
    try testing.expectEqual(input.ChunkEnd.failed, dnd.next_chunk().?.end);
    try testing.expectEqual(input.ChunkEnd.failed, dnd.next_chunk().?.end);
    try testing.expectEqual(@as(?*const input.Chunk, null), dnd.next_chunk());
    try testing.expect(!dnd.busy());
}

// Locks a cancel mid-file: the open file is closed, its cancelled chunk sits at the offset
// reached, and the transfer ends.
test "a cancel closes the file being read" {
    const dnd = test_dnd();
    var file_buffer: [64]u8 = undefined;
    const pid = linux.getpid();
    const name = "/tmp/patchwork-dnd-cancel-{d}";
    const file = try std.fmt.bufPrintSentinel(&file_buffer, name, .{pid}, 0);
    const fd: i32 = @intCast(linux.open(file, write_flags, 0o600));
    defer _ = linux.unlink(file);
    var payload: [100000]u8 = @splat(7);
    _ = linux.write(fd, &payload, payload.len);
    _ = linux.close(fd);
    dnd.list.reset(0, 0);
    try testing.expect(dnd.list.add(file, drop.basename(file), payload.len, true));
    dnd.start(1);
    try testing.expectEqual(input.ChunkEnd.more, dnd.next_chunk().?.end);
    try testing.expect(dnd.busy());
    const ended = dnd.cancel(1);
    try testing.expectEqual(@as(usize, 1), ended.len);
    try testing.expectEqual(@as(u64, 65536), ended[0].offset);
    try testing.expectEqual(input.ChunkEnd.cancelled, ended[0].end);
    try testing.expectEqual(no_fd, dnd.file_fd);
    try testing.expect(!dnd.busy());
    try testing.expectEqual(@as(?*const input.Chunk, null), dnd.next_chunk());
}

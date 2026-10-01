//! Zero-Dependency Development HTTP Server for Browser WebGPU/Wasm Host Testing.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why an Internal HTTP Server Instead of `file://` or External Tools?
//! WebGPU is strictly disabled by all modern browsers on local `file://` URIs due to the
//! W3C cross-origin security specification and origin-isolation rules.
//! - Running browser builds typically requires external dependencies like Python (`python -m
//!   http.server`), Node.js (`npx serve`), or Go.
//! - In Patchwork, `zig build serve` provides a completely self-contained, zero-dependency
//!   static HTTP server compiled using only Zig's standard library.
//!
//! ## 2. TigerStyle Memory and Concurrency Guarantees
//! - **Bounded Buffers:** Fixed 4 KB request/response header buffers (`header_cap = 4096`)
//!   and a 4 MB maximum file size limit (`file_cap = 4 * 1024 * 1024`).
//! - **Zero Runtime Allocation:** Serves directly from preallocated stack/file buffers without
//!   dynamic heap allocation.
//! - **Deterministic MIME Handling:** Explicitly sets correct `Content-Type` headers for
//!   `text/html`, `application/javascript`, and `application/wasm` (which is required by browsers
//!   for streaming instantiation via `WebAssembly.instantiateStreaming`).

const std = @import("std");
const assert = std.debug.assert;

const header_cap: u32 = 4096;
const file_cap: u32 = 4 * 1024 * 1024;
const listen_port: u16 = 8080;

const Paths = struct {
    index: []const u8,
    shell: []const u8,
    wasm: []const u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const paths = try parse_paths(init.args);
    var threaded: std.Io.Threaded = .init(std.mem.Allocator.failing, .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
        .argv0 = .init(init.args),
        .environ = init.environ,
        .disable_memory_mapping = false,
    });
    defer threaded.deinit();
    const io = threaded.io();
    try serve_forever(io, paths);
}

fn parse_paths(args: std.process.Args) !Paths {
    var it = std.process.Args.Iterator.init(args);
    const argv0 = it.next();
    assert(argv0 != null);
    const index = it.next() orelse return error.MissingIndexHtml;
    const shell = it.next() orelse return error.MissingShellJs;
    const wasm = it.next() orelse return error.MissingWasm;
    assert(index.len != 0);
    return .{ .index = index, .shell = shell, .wasm = wasm };
}

fn serve_forever(io: std.Io, paths: Paths) !void {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", listen_port);
    var server = try address.listen(io, .{
        .kernel_backlog = 1,
        .reuse_address = true,
        .mode = .stream,
        .protocol = .tcp,
    });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    assert(port != 0);
    std.debug.print("serving http://127.0.0.1:{d}/\n", .{port});
    while (true) {
        try serve_one(io, &server, paths);
    }
}

fn serve_one(io: std.Io, server: *std.Io.net.Server, paths: Paths) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var recv_buffer: [header_cap]u8 = undefined;
    var send_buffer: [header_cap]u8 = undefined;
    var connection_reader = stream.reader(io, recv_buffer[0..]);
    var connection_writer = stream.writer(io, send_buffer[0..]);
    var http_server = std.http.Server.init(
        &connection_reader.interface,
        &connection_writer.interface,
    );
    const request = http_server.receiveHead() catch {
        return;
    };
    var live_request = request;
    try respond_target(io, &live_request, live_request.head.target, paths);
}

fn respond_target(
    io: std.Io,
    request: *std.http.Server.Request,
    target: []const u8,
    paths: Paths,
) !void {
    assert(target.len != 0);
    const path = strip_query(target);
    if (std.mem.eql(u8, path, "/")) {
        try respond_file(io, request, paths.index, "text/html; charset=utf-8");
        return;
    }
    if (std.mem.eql(u8, path, "/index.html")) {
        try respond_file(io, request, paths.index, "text/html; charset=utf-8");
        return;
    }
    if (std.mem.eql(u8, path, "/shell.js")) {
        try respond_file(io, request, paths.shell, "text/javascript; charset=utf-8");
        return;
    }
    if (std.mem.eql(u8, path, "/patchwork.wasm")) {
        try respond_file(io, request, paths.wasm, "application/wasm");
        return;
    }
    try request.respond("not found\n", .{
        .status = .not_found,
        .reason = null,
        .version = .@"HTTP/1.1",
        .keep_alive = false,
        .extra_headers = &.{},
        .transfer_encoding = null,
    });
}

fn respond_file(
    io: std.Io,
    request: *std.http.Server.Request,
    path: []const u8,
    content_type: []const u8,
) !void {
    assert(path.len != 0);
    assert(content_type.len != 0);
    var body: [file_cap]u8 = undefined;
    const length = try read_file(io, path, body[0..]);
    try request.respond(body[0..length], .{
        .status = .ok,
        .reason = null,
        .version = .@"HTTP/1.1",
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
        },
        .transfer_encoding = null,
    });
}

fn read_file(io: std.Io, path: []const u8, dest: []u8) !u32 {
    assert(path.len != 0);
    assert(dest.len == file_cap);
    var file = try open_path(io, path);
    defer file.close(io);
    const info = try file.stat(io);
    if (info.size > file_cap) {
        return error.FileTooLarge;
    }
    const length: u32 = @intCast(info.size);
    const read_n = try file.readPositionalAll(io, dest[0..length], 0);
    if (read_n != length) {
        return error.FileShortRead;
    }
    return length;
}

fn open_path(io: std.Io, path: []const u8) !std.Io.File {
    assert(path.len != 0);
    const options: std.Io.Dir.OpenFileOptions = .{
        .mode = .read_only,
        .allow_directory = false,
        .path_only = false,
        .lock = .none,
        .lock_nonblocking = false,
        .allow_ctty = false,
        .follow_symlinks = true,
        .resolve_beneath = false,
    };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options);
    }
    assert(!std.fs.path.isAbsolute(path));
    return std.Io.Dir.cwd().openFile(io, path, options);
}

fn strip_query(target: []const u8) []const u8 {
    assert(target.len != 0);
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    assert(q <= target.len);
    return target[0..q];
}

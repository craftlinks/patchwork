//! Zero-dependency development HTTP server for the browser host.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why an Internal Server
//! The browser host needs an HTTP origin: `web/shell.js` is an ES module and fetches the
//! wasm with `WebAssembly.instantiateStreaming`, and neither works from a `file://` page.
//! `instantiateStreaming` also requires the response `Content-Type` to be `application/wasm`
//! (WebAssembly Web API specification, "compile a potential WebAssembly response"), and
//! WebGPU is exposed only in secure contexts, which `http://127.0.0.1` is. Serving from this
//! file keeps the toolchain at Zig alone, with no Python, Node, or Go server needed.
//!
//! ## 2. Contract
//! - Command line: four file paths, in order, for the page, `shell.js`, the wasm, and
//!   `worklet.js` (the AudioWorklet processor, `web/worklet.js`).
//!   `build.zig` (`add_serve`) passes them. Relative paths resolve against the working
//!   directory.
//! - Routes are exact path matches after the query string is dropped. Anything else gets 404.
//! - The server binds loopback only, on `listen_port` (8080) or on the port the environment
//!   variable `PATCHWORK_SERVE_PORT` names (decimal, 1 to 65535; anything else fails at
//!   startup), handles one connection at a time, and closes each connection after one
//!   response. The variable lets a tool (`tools/browser_check.py`) run its own server beside
//!   one already on 8080. That is sufficient for a single developer
//!   browser and keeps the control flow bounded.
//!
//! ## 3. TigerStyle Invariants
//! - Header buffers are `header_cap` bytes and a served file may be at most `file_cap` bytes.
//!   A larger file returns `error.FileTooLarge` instead of truncating.
//! - No heap allocation: the Io runtime is built with a failing allocator, and the request
//!   and file buffers live on the stack.

const std = @import("std");
const assert = std.debug.assert;

/// Size of each of the receive and send buffers, which bounds the request head.
const header_cap: u32 = 4096;
/// Largest file the server will read into its stack buffer.
const file_cap: u32 = 4 * 1024 * 1024;
/// Loopback TCP port. A fixed port keeps the URL stable between runs.
const listen_port: u16 = 8080;
/// The environment variable that overrides `listen_port`.
pub const port_env: []const u8 = "PATCHWORK_SERVE_PORT";

const Paths = struct {
    index: []const u8,
    shell: []const u8,
    wasm: []const u8,
    worklet: []const u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const paths = try parse_paths(init.args);
    const port = try port_of(std.process.Environ.getPosix(init.environ, port_env));
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
    try serve_forever(io, paths, port);
}

/// The port to listen on: `listen_port` without the variable, else its decimal value.
pub fn port_of(value: ?[]const u8) error{BadPort}!u16 {
    const text = value orelse return listen_port;
    if (text.len == 0 or text.len > 5) return error.BadPort;
    var port: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return error.BadPort;
        port = port * 10 + (byte - '0');
    }
    if (port == 0 or port > std.math.maxInt(u16)) return error.BadPort;
    assert(port <= 65535);
    return @intCast(port);
}

/// Reads the four required file paths from the command line, in the order the module guide
/// states.
fn parse_paths(args: std.process.Args) !Paths {
    var it = std.process.Args.Iterator.init(args);
    const argv0 = it.next();
    assert(argv0 != null);
    const index = it.next() orelse return error.MissingIndexHtml;
    const shell = it.next() orelse return error.MissingShellJs;
    const wasm = it.next() orelse return error.MissingWasm;
    const worklet = it.next() orelse return error.MissingWorkletJs;
    assert(index.len != 0);
    return .{ .index = index, .shell = shell, .wasm = wasm, .worklet = worklet };
}

fn serve_forever(io: std.Io, paths: Paths, listen: u16) !void {
    assert(listen != 0);
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", listen);
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

/// Accepts one connection and answers its first request. A malformed request head drops the
/// connection silently, since the only client is a local browser that will retry.
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
    if (std.mem.eql(u8, path, "/worklet.js")) {
        try respond_file(io, request, paths.worklet, "text/javascript; charset=utf-8");
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

/// Reads the whole file into `dest[0..length]` and returns `length`. Fails with
/// `error.FileTooLarge` above `file_cap` and `error.FileShortRead` if the file shrinks
/// between `stat` and read.
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
    const q = std.mem.findScalar(u8, target, '?') orelse return target;
    assert(q <= target.len);
    return target[0..q];
}

// Locks the port override (section 2): no variable is 8080; a decimal port in 1 to 65535 is
// taken; empty, zero, too large, signed, or non-decimal values are refused.
test "the serve port comes from the environment or defaults to 8080" {
    try std.testing.expectEqual(@as(u16, 8080), try port_of(null));
    try std.testing.expectEqual(@as(u16, 8123), try port_of("8123"));
    try std.testing.expectEqual(@as(u16, 65535), try port_of("65535"));
    for ([_][]const u8{ "", "0", "65536", "123456", "-1", "80a", " 80" }) |bad| {
        try std.testing.expectError(error.BadPort, port_of(bad));
    }
}

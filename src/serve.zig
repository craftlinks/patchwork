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
//! - Command line: `ROUTE=PATH` pairs, at most `routes_max`, each a route that starts with `/`
//!   and the file it serves. `build.zig` (`add_serve`) passes Patchwork's four, `/index.html`,
//!   `/shell.js`, `/patchwork.wasm`, and `/app.js` (the app's web module, or `web/app.js`),
//!   then the app's own `web_files` (step 54); an audio worklet is one of those (step 56).
//!   Relative paths resolve against the working directory. Every file is opened once at
//!   startup, so a missing one fails there, naming its route, and not on a request; a route
//!   given twice or without `/index.html` is refused too.
//! - A route that ends in `/` (and is longer than `/`) is a folder, `/scenes/=scenes` on the
//!   command line, `web_dirs` in `build.zig` (step 70). It is opened as a folder at startup, and
//!   a file inside it is read when the request comes, so a file added while the server runs is
//!   served. Files and folders share the `routes_max` routes. An exact route wins over a
//!   folder; among folders the longest route that matches wins. The rest of the target after
//!   the folder's route is a name; `name_ok` accepts it as text (1 to `name_max` bytes, no NUL,
//!   no empty, `.`, or `..` segment). Names are not percent-decoded, as routes are not.
//! - Routes are matched after the query string is dropped; `/` is `/index.html`. The content
//!   type is the route's (or the name's) extension's: `.html`, `.js`, `.wasm`, `.json`, `.wav`,
//!   `.css`, else `application/octet-stream`.
//! - Every request that arrives gets an answer, and the server never ends on one. The stream
//!   ends before a head: nothing, there is no one to answer. A head over `header_cap` bytes
//!   with no line end in them: 414. A head over it whose first line fits: 431. A head that
//!   does not parse: 400. A method other than GET or HEAD: 405 with `allow: GET, HEAD`. No
//!   route, a name `name_ok` refuses, a folder's own path (there is no listing), a file that is
//!   missing, is not a regular file, or whose real path leaves its folder: 404. A file over
//!   `file_cap` (16 MiB), or cut short or failing while read: 500 with the reason in the body.
//!   Otherwise 200, and HEAD sends the head only. Each body names the limit it hit.
//! - Closing a socket with bytes still unread makes Linux reset the connection, and the
//!   client may never see the answer. So after a 414, a 431, a 400, or a 405 the server ends its
//!   sending side, reads and discards up to `drain_cap` bytes or the end of the stream, and
//!   only then closes (a 405 drains too, since its request may carry a body); a failure while
//!   draining is ignored.
//! - The server binds loopback only, on `listen_port` (8080) or on the port the environment
//!   variable `PATCHWORK_SERVE_PORT` names (decimal, 1 to 65535; anything else fails at
//!   startup), handles one connection at a time, and closes each connection after one
//!   response. The variable lets a tool (`tools/browser_check.py`) run its own server beside
//!   one already on 8080. That is sufficient for a single developer
//!   browser and keeps the control flow bounded.
//!
//! ## 3. TigerStyle Invariants
//! - Header buffers are `header_cap` bytes and a served file may be at most `file_cap` bytes
//!   (16 MiB, room for an app's Debug wasm); a larger file is a 500, never truncated.
//! - A file in a folder is held to it twice. The name is checked as text, and after the file is
//!   opened its real path (`File.realPath`) must be the folder's real path (`Dir.realPath`)
//!   followed by `/`, so a link that leaves the folder is refused. Both paths are read into
//!   two stack buffers of `std.fs.max_path_bytes`. The name is examined, links followed,
//!   before it is opened, because opening a FIFO blocks (step 37). Zig's `resolve_beneath`
//!   open option is not used: on Linux the standard library ignores it.
//! - No heap allocation: the Io runtime is built with a failing allocator. The request buffers
//!   live on the stack. A file is read whole into `body_buffer`, one static buffer of `file_cap`
//!   bytes that the server owns, since `file_cap` on the stack risks an overflow. The server
//!   answers one request at a time, so one buffer serves all; `body_busy` asserts that.

const std = @import("std");
const assert = std.debug.assert;

/// Size of each of the receive and send buffers, which bounds the request head.
const header_cap: u32 = 4096;
/// Largest file the server will read into `body_buffer`.
const file_cap: u32 = 16 * 1024 * 1024;
/// Loopback TCP port. A fixed port keeps the URL stable between runs.
const listen_port: u16 = 8080;
/// The environment variable that overrides `listen_port`.
pub const port_env: []const u8 = "PATCHWORK_SERVE_PORT";

/// The most routes one server takes (section 2).
pub const routes_max: u32 = 32;
/// Bytes of a name inside a served folder.
pub const name_max: u32 = 1024;
/// Bytes read and discarded after an answer to a head that did not fit or parse.
const drain_cap: u32 = 4 * 1024 * 1024;

/// The one buffer a served file is read into (section 3): static, not on the stack.
var body_buffer: [file_cap]u8 = undefined;
/// True while a request holds `body_buffer`; the server answers one request at a time.
var body_busy: bool = false;

comptime {
    assert(file_cap == 16 * 1024 * 1024);
    assert(@sizeOf(@TypeOf(body_buffer)) == file_cap);
    assert(header_cap < file_cap);
}

/// One `ROUTE=PATH` pair from the command line.
pub const Route = struct {
    route: []const u8,
    path: []const u8,
};

/// True for a folder route: it ends with `/`.
pub fn is_dir(route: Route) bool {
    assert(route.route.len != 0);
    return route.route[route.route.len - 1] == '/';
}

/// What a target reaches: an exact route (`name` empty), or a folder route and the name in it.
pub const Match = struct { route: Route, name: []const u8 };

/// The routes a server answers (section 2).
pub const Routes = struct {
    items: [routes_max]Route,
    count: u32,

    pub const empty: Routes = .{ .items = undefined, .count = 0 };

    /// The route for `target`, `/` being `/index.html`, or null.
    pub fn find(routes: *const Routes, target: []const u8) ?Route {
        assert(routes.count <= routes_max);
        const wanted = if (std.mem.eql(u8, target, "/")) "/index.html" else target;
        for (routes.items[0..routes.count]) |item| {
            if (std.mem.eql(u8, item.route, wanted)) return item;
        }
        return null;
    }
};

pub const RouteError = error{ BadRoute, DuplicateRoute, TooManyRoutes, MissingIndexHtml };

/// Splits `ROUTE=PATH` at its first `=`: the route must start with `/`, and neither side be
/// empty. A route that ends in `/` is a folder and must be longer than `/`.
pub fn route_parse(text: []const u8) RouteError!Route {
    const at = std.mem.findScalar(u8, text, '=') orelse return error.BadRoute;
    const route = text[0..at];
    const path = text[at + 1 ..];
    if (route.len < 2 or route[0] != '/') return error.BadRoute;
    if (path.len == 0) return error.BadRoute;
    assert(route.len + path.len + 1 == text.len);
    return .{ .route = route, .path = path };
}

/// Every pair of `texts` into `routes`, in order (section 2).
pub fn routes_parse(texts: []const []const u8, routes: *Routes) RouteError!void {
    routes.* = .empty;
    for (texts) |text| {
        if (routes.count == routes_max) return error.TooManyRoutes;
        const item = try route_parse(text);
        if (routes.find(item.route) != null) return error.DuplicateRoute;
        routes.items[routes.count] = item;
        routes.count += 1;
    }
    if (routes.find("/index.html") == null) return error.MissingIndexHtml;
    assert(routes.count <= routes_max);
}

/// True for a name that stays in its folder as text: 1 to `name_max` bytes, no NUL, and no
/// segment between `/` that is empty, `.`, or `..`.
pub fn name_ok(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    if (std.mem.findScalar(u8, name, 0) != null) return false;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// The route for `target`: an exact route first, then the folder route with the longest prefix
/// whose rest is a name `name_ok` accepts. `/` is `/index.html`.
pub fn match(routes: *const Routes, target: []const u8) ?Match {
    assert(routes.count <= routes_max);
    if (routes.find(target)) |exact| {
        // A folder's own path is not a file: it falls through, and nothing else matches it.
        if (!is_dir(exact)) return .{ .route = exact, .name = target[target.len..] };
    }
    var best: ?Match = null;
    for (routes.items[0..routes.count]) |item| {
        if (!is_dir(item)) continue;
        if (!std.mem.startsWith(u8, target, item.route)) continue;
        const name = target[item.route.len..];
        if (!name_ok(name)) continue;
        if (best) |held| {
            if (held.route.route.len >= item.route.len) continue;
        }
        best = .{ .route = item, .name = name };
    }
    if (best) |found| assert(found.name.len != 0);
    return best;
}

/// The content type a route is served with, by its extension (section 2).
pub fn content_type_of(route: []const u8) []const u8 {
    const types = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".json", "application/json" },
        .{ ".wav", "audio/wav" },
        .{ ".css", "text/css; charset=utf-8" },
    };
    for (types) |entry| {
        if (std.mem.endsWith(u8, route, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

pub fn main(init: std.process.Init.Minimal) !void {
    var texts: [routes_max + 1][]const u8 = undefined;
    var count: u32 = 0;
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next();
    while (it.next()) |arg| : (count += 1) {
        if (count == texts.len) return error.TooManyRoutes;
        texts[count] = arg;
    }
    var routes: Routes = .empty;
    try routes_parse(texts[0..count], &routes);
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
    try routes_check(io, &routes);
    try serve_forever(io, &routes, port);
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

/// Opens every route's file (or folder) once, so a missing one fails at startup, naming its
/// route.
fn routes_check(io: std.Io, routes: *const Routes) !void {
    assert(routes.count <= routes_max);
    for (routes.items[0..routes.count]) |item| {
        if (is_dir(item)) {
            var dir = open_dir(io, item.path) catch |err| {
                std.debug.print("serve: {s}: cannot open folder {s}: {s}\n", .{
                    item.route,
                    item.path,
                    @errorName(err),
                });
                return err;
            };
            dir.close(io);
            continue;
        }
        var file = open_path(io, item.path) catch |err| {
            std.debug.print("serve: {s}: cannot open {s}: {s}\n", .{
                item.route,
                item.path,
                @errorName(err),
            });
            return err;
        };
        file.close(io);
    }
}

fn serve_forever(io: std.Io, routes: *const Routes, listen: u16) !void {
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
        try serve_one(io, &server, routes);
    }
}

/// Accepts one connection and answers its first request (`answer`). An error from the client's
/// side of the stream ends this connection and not the server. After an answer to a head that
/// did not fit or parse, the sending side ends and what the client still sends is discarded
/// before the close, so the client sees the answer and not a reset (section 2).
fn serve_one(io: std.Io, server: *std.Io.net.Server, routes: *const Routes) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var recv_buffer: [header_cap]u8 = undefined;
    var send_buffer: [header_cap]u8 = undefined;
    var connection_reader = stream.reader(io, recv_buffer[0..]);
    var connection_writer = stream.writer(io, send_buffer[0..]);
    const drain = answer(
        io,
        &connection_reader.interface,
        &connection_writer.interface,
        routes,
    ) catch return;
    if (!drain) return;
    stream.shutdown(io, .send) catch return;
    _ = connection_reader.interface.discardShort(drain_cap) catch return;
}

/// Reads one request head from `in` and writes its answer to `out` (section 2). Returns true
/// when the head did not fit or parse, or the method is not GET or HEAD (405, whose request may
/// carry a body), so the caller drains before it closes.
fn answer(io: std.Io, in: *std.Io.Reader, out: *std.Io.Writer, routes: *const Routes) !bool {
    assert(in != @as(*std.Io.Reader, @ptrCast(out)));
    var http_server = std.http.Server.init(in, out);
    // A reader over a larger buffer than `header_cap` (a test's fixed one) is held to it too.
    http_server.reader.max_head_len = header_cap;
    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing, error.HttpRequestTruncated => return false,
        error.ReadFailed => return error.ReadFailed,
        error.HttpHeadersOversize => {
            const held = in.buffered();
            const window = held[0..@min(held.len, header_cap)];
            if (std.mem.findScalar(u8, window, '\n') == null) {
                try head_answer(out, .uri_too_long, line_long_text);
            } else {
                try head_answer(out, .request_header_fields_too_large, head_long_text);
            }
            return true;
        },
        error.HttpHeadersInvalid => {
            try head_answer(out, .bad_request, "bad request");
            return true;
        },
    };
    switch (request.head.method) {
        .GET, .HEAD => {},
        else => {
            try respond_text(&request, .method_not_allowed, "method not allowed\n", &.{
                .{ .name = "allow", .value = "GET, HEAD" },
            });
            return true;
        },
    }
    const target = strip_query(request.head.target);
    const found = match(routes, target) orelse {
        try respond_text(&request, .not_found, "not found\n", &.{});
        return false;
    };
    try respond_file(io, &request, found);
    return false;
}

const line_long_text = std.fmt.comptimePrint("request line over {d} bytes", .{header_cap});
const head_long_text = std.fmt.comptimePrint("request head over {d} bytes", .{header_cap});

/// Writes an answer to a request that did not parse: status line, a text body and a newline.
/// No `Request` exists to `respond` through.
fn head_answer(out: *std.Io.Writer, status: std.http.Status, body: []const u8) !void {
    assert(@backingInt(status) >= 400);
    assert(body.len != 0);
    try out.print("HTTP/1.1 {d} {s}\r\n", .{ @backingInt(status), status.phrase().? });
    try out.writeAll("content-type: text/plain; charset=utf-8\r\n");
    try out.print("content-length: {d}\r\n", .{body.len + 1});
    try out.writeAll("connection: close\r\n\r\n");
    try out.writeAll(body);
    try out.writeAll("\n");
    try out.flush();
}

fn respond_text(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    extra_headers: []const std.http.Header,
) !void {
    assert(@backingInt(status) >= 400);
    assert(body.len != 0);
    try request.respond(body, .{
        .status = status,
        .reason = null,
        .version = .@"HTTP/1.1",
        .keep_alive = false,
        .extra_headers = extra_headers,
        .transfer_encoding = null,
    });
}

/// Sends what `found` reaches: 200 with the file, 404 when it cannot be opened as a regular
/// file in its place, 500 with the reason when it cannot be read whole.
fn respond_file(io: std.Io, request: *std.http.Server.Request, found: Match) !void {
    assert(found.route.path.len != 0);
    assert(found.route.route.len != 0);
    // One request at a time holds the static buffer (section 3).
    assert(!body_busy);
    body_busy = true;
    defer body_busy = false;
    const body = body_buffer[0..];
    const length = load(io, found.route.path, found.name, body) catch |err| {
        const status: std.http.Status = switch (err) {
            error.NotFound => .not_found,
            else => .internal_server_error,
        };
        const text = switch (err) {
            error.NotFound => "not found\n",
            error.TooLarge => too_large_text,
            error.ShortRead => short_text,
            error.ReadFailed => failed_text,
        };
        return respond_text(request, status, text, &.{});
    };
    const typed = if (found.name.len == 0) found.route.route else found.name;
    try request.respond(body[0..length], .{
        .status = .ok,
        .reason = null,
        .version = .@"HTTP/1.1",
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type_of(typed) },
        },
        .transfer_encoding = null,
    });
}

const too_large_text = std.fmt.comptimePrint("file over {d} bytes\n", .{file_cap});
const short_text = "file cut short while read\n";
const failed_text = "file read failed\n";

const LoadError = error{ NotFound, TooLarge, ShortRead, ReadFailed };

/// Reads the file `path` (an exact route, `name` empty) or `name` inside the folder `path` whole
/// into `dest`, and returns its length. A file that cannot be opened, is not a regular file, or
/// whose real path leaves the folder is `NotFound`.
fn load(io: std.Io, path: []const u8, name: []const u8, dest: []u8) LoadError!u32 {
    assert(path.len != 0);
    assert(dest.len == file_cap);
    if (name.len == 0) {
        var file = open_regular(io, std.Io.Dir.cwd(), path) catch return error.NotFound;
        defer file.close(io);
        return read_file(io, file, dest);
    }
    assert(name_ok(name));
    var dir = open_dir(io, path) catch return error.NotFound;
    defer dir.close(io);
    var file = open_regular(io, dir, name) catch return error.NotFound;
    defer file.close(io);
    if (!inside(io, dir, file)) return error.NotFound;
    return read_file(io, file, dest);
}

/// Examines `sub_path` in `dir` without opening it, links followed, and opens it only when it is
/// a regular file: opening a FIFO blocks (step 37).
fn open_regular(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !std.Io.File {
    assert(sub_path.len != 0);
    const info = try dir.statFile(io, sub_path, .{ .follow_symlinks = true });
    if (info.kind != .file) return error.NotRegularFile;
    if (std.fs.path.isAbsolute(sub_path)) return open_path(io, sub_path);
    return dir.openFile(io, sub_path, open_options);
}

/// True when the opened `file`'s real path lies under the real path of `dir`, so a link that
/// leaves the folder is refused (section 3).
fn inside(io: std.Io, dir: std.Io.Dir, file: std.Io.File) bool {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_length = dir.realPath(io, &dir_buffer) catch return false;
    const file_length = file.realPath(io, &file_buffer) catch return false;
    assert(dir_length <= dir_buffer.len);
    assert(file_length <= file_buffer.len);
    // The root folder's path is `/`: dropping its slash leaves the prefix every path begins with.
    var base = dir_buffer[0..dir_length];
    if (base.len != 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    const real = file_buffer[0..file_length];
    if (!std.mem.startsWith(u8, real, base)) return false;
    return real.len > base.len and real[base.len] == '/';
}

/// Reads the whole file into `dest[0..length]` and returns `length`. Fails with `TooLarge`
/// above `file_cap` and `ShortRead` if the file shrinks between `stat` and read.
fn read_file(io: std.Io, file: std.Io.File, dest: []u8) LoadError!u32 {
    assert(dest.len == file_cap);
    const info = file.stat(io) catch return error.ReadFailed;
    if (info.size > file_cap) return error.TooLarge;
    const length: u32 = @intCast(info.size);
    const read_n = file.readPositionalAll(io, dest[0..length], 0) catch return error.ReadFailed;
    if (read_n != length) return error.ShortRead;
    return length;
}

const open_options: std.Io.Dir.OpenFileOptions = .{
    .mode = .read_only,
    .allow_directory = false,
    .path_only = false,
    .lock = .none,
    .lock_nonblocking = false,
    .allow_ctty = false,
    .follow_symlinks = true,
    .resolve_beneath = false,
};

fn open_path(io: std.Io, path: []const u8) !std.Io.File {
    assert(path.len != 0);
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, open_options);
    }
    assert(!std.fs.path.isAbsolute(path));
    return std.Io.Dir.cwd().openFile(io, path, open_options);
}

fn open_dir(io: std.Io, path: []const u8) !std.Io.Dir {
    assert(path.len != 0);
    const options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .iterate = false,
        .follow_symlinks = true,
    };
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    assert(!std.fs.path.isAbsolute(path));
    return std.Io.Dir.cwd().openDir(io, path, options);
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

// Locks the routes (section 2): pairs parse at their first `=`; a route without `/`, an empty
// side, a second `/index.html`, a list without one, and a 33rd route are refused; `/` finds the
// page; and the content types follow the extension, a file of none being bytes. A route that
// ends in `/` is a folder (`/kit/=samples`), and `/=b` stays refused.
test "routes parse, refuse, and type their files" {
    const item = try route_parse("/kit/a.wav=/tmp/x=y.wav");
    try std.testing.expectEqualStrings("/kit/a.wav", item.route);
    try std.testing.expectEqualStrings("/tmp/x=y.wav", item.path);
    try std.testing.expect(!is_dir(item));
    const folder = try route_parse("/kit/=samples");
    try std.testing.expect(is_dir(folder));
    try std.testing.expectEqualStrings("samples", folder.path);
    for ([_][]const u8{ "a=b", "/=b", "/a=", "nope", "=b" }) |bad| {
        try std.testing.expectError(error.BadRoute, route_parse(bad));
    }
    var routes: Routes = .empty;
    try routes_parse(&.{ "/index.html=i", "/shell.js=s", "/app.js=m" }, &routes);
    try std.testing.expectEqualStrings("i", routes.find("/").?.path);
    try std.testing.expectEqualStrings("m", routes.find("/app.js").?.path);
    try std.testing.expect(routes.find("/other.js") == null);
    const twice = [_][]const u8{ "/index.html=i", "/index.html=j" };
    try std.testing.expectError(error.DuplicateRoute, routes_parse(&twice, &routes));
    try std.testing.expectError(error.MissingIndexHtml, routes_parse(&.{"/a.js=a"}, &routes));
    var many: [routes_max + 1][]const u8 = undefined;
    var names: [routes_max + 1][16]u8 = undefined;
    for (&many, &names, 0..) |*text, *name, index| {
        text.* = std.fmt.bufPrint(name, "/r{d}.js=p", .{index}) catch unreachable;
    }
    many[0] = "/index.html=i";
    try std.testing.expectError(error.TooManyRoutes, routes_parse(&many, &routes));
    try std.testing.expectEqualStrings("application/wasm", content_type_of("/patchwork.wasm"));
    try std.testing.expectEqualStrings("audio/wav", content_type_of("/kit/a.wav"));
    try std.testing.expectEqualStrings("application/octet-stream", content_type_of("/data"));
}

// Locks the text rule of a name inside a folder (section 2): plain names, a nested one, and a
// leading `..` inside a segment pass; the empty name, `..`, any `.` or `..` or empty segment,
// a NUL, and a name of `name_max` + 1 bytes do not.
test "a name stays in its folder as text" {
    for ([_][]const u8{ "a.scene", "sub/a.scene", "..a" }) |good| {
        try std.testing.expect(name_ok(good));
    }
    for ([_][]const u8{
        "",       "..", "../build.zig", "a/../b", "./a", "a//b", "/a", "a/",
        "a\x00b",
    }) |bad| {
        try std.testing.expect(!name_ok(bad));
    }
    var long: [name_max + 1]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expect(name_ok(long[0..name_max]));
    try std.testing.expect(!name_ok(long[0 .. name_max + 1]));
}

// Locks the match order (section 2): an exact route wins over its folder, the longest folder
// wins, and a folder's own path, a name with `..`, an unrouted path match nothing; `/` is the page.
test "an exact route wins, then the longest folder" {
    var routes: Routes = .empty;
    try routes_parse(&.{
        "/index.html=i",
        "/scenes/=a",
        "/scenes/deep/=b",
        "/scenes/a.scene=c",
    }, &routes);
    const exact = match(&routes, "/scenes/a.scene").?;
    try std.testing.expectEqualStrings("c", exact.route.path);
    try std.testing.expectEqualStrings("", exact.name);
    const near = match(&routes, "/scenes/b.scene").?;
    try std.testing.expectEqualStrings("a", near.route.path);
    try std.testing.expectEqualStrings("b.scene", near.name);
    const deep = match(&routes, "/scenes/deep/c.scene").?;
    try std.testing.expectEqualStrings("b", deep.route.path);
    try std.testing.expectEqualStrings("c.scene", deep.name);
    for ([_][]const u8{ "/scenes/", "/scenes/../build.zig", "/other/x", "/scenes/deep/" }) |none| {
        try std.testing.expect(match(&routes, none) == null);
    }
    try std.testing.expectEqualStrings("i", match(&routes, "/").?.route.path);
}

/// The first line of what `out` holds, for a test of `answer`.
fn first_line(out: *const std.Io.Writer) []const u8 {
    const written = out.buffered();
    const end = std.mem.findScalar(u8, written, '\r') orelse written.len;
    return written[0..end];
}

/// Feeds `request` to `answer` through fixed buffers and returns whether it asked to drain.
fn answer_test(
    request: []const u8,
    routes: *const Routes,
    out: *std.Io.Writer,
) !bool {
    var in: std.Io.Reader = .fixed(request);
    return answer(std.testing.io, &in, out, routes);
}

// Locks the answers to a head that does not fit (section 2): a request line of 5,000 bytes is
// 414 and its body names 4096; a short line then 5,000 bytes of headers is 431; both ask to drain.
test "a head that does not fit is answered" {
    var routes: Routes = .empty;
    try routes_parse(&.{"/index.html=i"}, &routes);
    var big: [5200]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    @memcpy(big[0..11], "GET /index?");
    @memset(big[11..5000], 'a');
    try std.testing.expect(try answer_test(big[0..5000], &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 414 URI Too Long", first_line(&out));
    try std.testing.expect(std.mem.find(u8, out.buffered(), "4096") != null);
    var head: [5200]u8 = undefined;
    const line = "GET /index.html HTTP/1.1\r\nx: ";
    @memcpy(head[0..line.len], line);
    @memset(head[line.len..5000], 'b');
    out = .fixed(&out_buffer);
    try std.testing.expect(try answer_test(head[0..5000], &routes, &out));
    const expected = "HTTP/1.1 431 Request Header Fields Too Large";
    try std.testing.expectEqualStrings(expected, first_line(&out));
    try std.testing.expect(std.mem.find(u8, out.buffered(), "4096") != null);
}

// Locks the answers with no request to read (section 2): a head that does not parse is 400 and
// asks to drain; a stream that ends before any byte, or inside a head, gets nothing.
test "a head that does not parse is 400, and an empty stream is nothing" {
    var routes: Routes = .empty;
    try routes_parse(&.{"/index.html=i"}, &routes);
    var out_buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expect(try answer_test("NOT HTTP\r\n\r\n", &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 400 Bad Request", first_line(&out));
    out = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test("", &routes, &out));
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
    try std.testing.expect(!try answer_test("GET /index.html HT", &routes, &out));
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
}

/// A temporary folder's absolute path, written into `buffer`.
fn tmp_path(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

// Locks the methods (section 2): POST is 405 with `allow: GET, HEAD` and asks to drain; HEAD of
// a served file is 200 with the head only; GET is 200 and does not drain.
test "a method other than GET or HEAD is 405" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "page.html", .data = "<p>hi</p>" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp_path(&tmp, &path_buffer);
    var text_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buffer, "/index.html={s}/page.html", .{base});
    var routes: Routes = .empty;
    try routes_parse(&.{text}, &routes);
    var out_buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expect(try answer_test("POST /index.html HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 405 Method Not Allowed", first_line(&out));
    try std.testing.expect(std.mem.find(u8, out.buffered(), "allow: GET, HEAD\r\n") != null);
    out = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test("HEAD /index.html HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", first_line(&out));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "\r\n\r\n"));
    out = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test("GET /index.html HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "<p>hi</p>"));
}

/// The status line of `GET target` against `routes`, written into `line`.
fn status_of(target: []const u8, routes: *const Routes, line: []u8) ![]const u8 {
    var request_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buffer, "GET {s} HTTP/1.1\r\n\r\n", .{target});
    var out_buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test(request, routes, &out));
    const first = first_line(&out);
    @memcpy(line[0..first.len], first);
    return line[0..first.len];
}

/// Fails unless `GET target` against `routes` is answered with the status line `expected`.
fn expect_status(target: []const u8, routes: *const Routes, expected: []const u8) !void {
    var line: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try status_of(target, routes, &line));
}

// Locks a folder (section 2, 3): over a temporary folder with `inside/a.scene`,
// `inside/sub/b.scene`, a `secret.txt` beside `inside`, a link `inside/out` to it, and a folder
// `inside/dir`, `/scenes/a.scene` is 200 with the file's bytes and `/scenes/sub/b.scene` is 200;
// the link, the folder, a missing name, the folder's own path, and `..` are each 404; and a file
// written after the routes were parsed is 200.
test "a folder serves what is in it and nothing outside" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "inside/sub");
    try tmp.dir.createDirPath(io, "inside/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "inside/a.scene", .data = "alpha" });
    try tmp.dir.writeFile(io, .{ .sub_path = "inside/sub/b.scene", .data = "beta" });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "i" });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "secret" });
    try tmp.dir.symLink(io, "../secret.txt", "inside/out", .{});
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp_path(&tmp, &path_buffer);
    var page: [std.fs.max_path_bytes + 32]u8 = undefined;
    var folder: [std.fs.max_path_bytes + 32]u8 = undefined;
    const page_text = try std.fmt.bufPrint(&page, "/index.html={s}/index.html", .{base});
    const folder_text = try std.fmt.bufPrint(&folder, "/scenes/={s}/inside", .{base});
    var routes: Routes = .empty;
    try routes_parse(&.{ page_text, folder_text }, &routes);
    var out_buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test("GET /scenes/a.scene HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", first_line(&out));
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), "alpha"));
    try expect_status("/scenes/sub/b.scene", &routes, "HTTP/1.1 200 OK");
    for ([_][]const u8{
        "/scenes/out",           "/scenes/dir", "/scenes/missing", "/scenes/",
        "/scenes/../secret.txt",
    }) |target| {
        try expect_status(target, &routes, "HTTP/1.1 404 Not Found");
    }
    try expect_status("/scenes/c.scene", &routes, "HTTP/1.1 404 Not Found");
    try tmp.dir.writeFile(io, .{ .sub_path = "inside/c.scene", .data = "gamma" });
    try expect_status("/scenes/c.scene?x=1", &routes, "HTTP/1.1 200 OK");
}

// Locks the server never ending on a request (section 2): an exact route whose file is removed
// after the routes were parsed is 404, and a file over `file_cap` is a 500 naming the cap.
test "a file that cannot be sent has an answer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "i" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.js", .data = "g" });
    var big = try tmp.dir.createFile(io, "big.bin", .{});
    try big.setLength(io, file_cap + 1);
    big.close(io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp_path(&tmp, &path_buffer);
    var texts: [3][std.fs.max_path_bytes + 32]u8 = undefined;
    const page = try std.fmt.bufPrint(&texts[0], "/index.html={s}/index.html", .{base});
    const gone = try std.fmt.bufPrint(&texts[1], "/gone.js={s}/gone.js", .{base});
    const huge = try std.fmt.bufPrint(&texts[2], "/big.bin={s}/big.bin", .{base});
    var routes: Routes = .empty;
    try routes_parse(&.{ page, gone, huge }, &routes);
    try routes_check(io, &routes);
    try tmp.dir.deleteFile(io, "gone.js");
    try expect_status("/gone.js", &routes, "HTTP/1.1 404 Not Found");
    var out_buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    try std.testing.expect(!try answer_test("GET /big.bin HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error", first_line(&out));
    try std.testing.expect(std.mem.find(u8, out.buffered(), "16777216") != null);
}

/// What the test of a whole `file_cap` answer writes into: the head, then the file. Static, as
/// `body_buffer` is, since 16 MiB on a test's stack risks an overflow.
var cap_out_buffer: [file_cap + header_cap]u8 = undefined;

/// A file `name` in `dir` of `length` bytes: 'A' first, 'Z' last, and zero between.
fn cap_file(dir: std.Io.Dir, name: []const u8, length: u32) !void {
    assert(length >= 2);
    assert(name.len != 0);
    const io = std.testing.io;
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.setLength(io, length);
    try file.writePositionalAll(io, "A", 0);
    try file.writePositionalAll(io, "Z", length - 1);
}

// Locks the cap (section 2, 3): a file of exactly `file_cap` = 16,777,216 bytes ('A', zeros, 'Z')
// is 200 with `content-length: 16777216` and every byte of it after the head; a file of 16,777,217
// bytes is 500 with the body "file over 16777216 bytes\n", the text the cap has always had.
test "a file of file_cap bytes is served whole, and one byte more is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "i" });
    try cap_file(tmp.dir, "cap.wasm", file_cap);
    try cap_file(tmp.dir, "over.wasm", file_cap + 1);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp_path(&tmp, &path_buffer);
    var texts: [3][std.fs.max_path_bytes + 32]u8 = undefined;
    const page = try std.fmt.bufPrint(&texts[0], "/index.html={s}/index.html", .{base});
    const cap = try std.fmt.bufPrint(&texts[1], "/cap.wasm={s}/cap.wasm", .{base});
    const over = try std.fmt.bufPrint(&texts[2], "/over.wasm={s}/over.wasm", .{base});
    var routes: Routes = .empty;
    try routes_parse(&.{ page, cap, over }, &routes);
    var out: std.Io.Writer = .fixed(&cap_out_buffer);
    try std.testing.expect(!try answer_test("GET /cap.wasm HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expect(!body_busy);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK", first_line(&out));
    const written = out.buffered();
    const head_end = std.mem.find(u8, written, "\r\n\r\n").? + 4;
    const head = written[0..head_end];
    try std.testing.expect(std.mem.find(u8, head, "content-length: 16777216\r\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "content-type: application/wasm\r\n") != null);
    const body = written[head_end..];
    try std.testing.expectEqual(@as(usize, 16777216), body.len);
    try std.testing.expectEqual(@as(u8, 'A'), body[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), body[body.len - 1]);
    try std.testing.expect(std.mem.allEqual(u8, body[1 .. body.len - 1], 0));
    var small_buffer: [2048]u8 = undefined;
    out = .fixed(&small_buffer);
    try std.testing.expect(!try answer_test("GET /over.wasm HTTP/1.1\r\n\r\n", &routes, &out));
    try std.testing.expect(!body_busy);
    try std.testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error", first_line(&out));
    const refused = "\r\n\r\nfile over 16777216 bytes\n";
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), refused));
}

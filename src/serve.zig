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
//!   Relative paths resolve against the working directory. Every file is opened once at startup, so a missing one fails there,
//!   naming its route, and not on a request; a route given twice or without `/index.html` is
//!   refused too.
//! - Routes are exact path matches after the query string is dropped; `/` is `/index.html`.
//!   Anything else gets 404. The content type is the route's extension's: `.html`, `.js`,
//!   `.wasm`, `.json`, `.wav`, `.css`, else `application/octet-stream`.
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

/// The most routes one server takes (section 2).
pub const routes_max: u32 = 32;

/// One `ROUTE=PATH` pair from the command line.
pub const Route = struct {
    route: []const u8,
    path: []const u8,
};

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

/// Splits `ROUTE=PATH` at its first `=`: the route must start with `/`, and neither side be empty.
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

/// Opens every route's file once, so a missing one fails at startup, naming its route.
fn routes_check(io: std.Io, routes: *const Routes) !void {
    assert(routes.count <= routes_max);
    for (routes.items[0..routes.count]) |item| {
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

/// Accepts one connection and answers its first request. A malformed request head drops the
/// connection silently, since the only client is a local browser that will retry.
fn serve_one(io: std.Io, server: *std.Io.net.Server, routes: *const Routes) !void {
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
    try respond_target(io, &live_request, live_request.head.target, routes);
}

fn respond_target(
    io: std.Io,
    request: *std.http.Server.Request,
    target: []const u8,
    routes: *const Routes,
) !void {
    assert(target.len != 0);
    const path = strip_query(target);
    if (routes.find(path)) |item| {
        try respond_file(io, request, item.path, content_type_of(item.route));
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

// Locks the routes (section 2): pairs parse at their first `=`; a route without `/`, an empty
// side, a second `/index.html`, a list without one, and a 33rd route are refused; `/` finds the
// page; and the content types follow the extension, a file of none being bytes.
test "routes parse, refuse, and type their files" {
    const item = try route_parse("/kit/a.wav=/tmp/x=y.wav");
    try std.testing.expectEqualStrings("/kit/a.wav", item.route);
    try std.testing.expectEqualStrings("/tmp/x=y.wav", item.path);
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

//! `describe <src-dir> [--check <describe.json>]`: prints the library as JSON for an agent that
//! has never seen it, generated from the code (`zig build describe`). With `--check`, compares
//! the output with the committed golden instead and fails naming the first line that differs.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Two Sources, One Output
//! Reflection knows types, fields, sizes, defaults, and a function's parameter and return types;
//! it does not know a parameter's name or what a declaration is for. The source text knows both.
//! So the tool reflects at compile time and parses at run time:
//! ```text
//!   comptime   the hand-kept `namespaces` list, public names by walking the namespaces,
//!              draw types, the types they and the functions name, constants, widgets
//!   run time   each declaration's file, `///` sentence, and parameter names, from
//!              `std.zig.Ast` over `<src-dir>`, by resolving its public path (section 3)
//! ```
//! Every printed type comes from reflection. Every printed parameter name comes from the source
//! and is checked against reflection: the count, `comptime`, `anytype`, and each type, with
//! aliases followed to the declaration both sides name (section 4). A mismatch fails the run.
//!
//! ## 2. Public Names
//! A type is printed as an app writes it: `draw.BoxLook`, not `draw.types.BoxLook`. The names
//! come from a breadth-first walk of the public declarations from the library's root, in the
//! order of `roots`, so the shortest path wins and, at one depth, the earlier root. The generic
//! contexts have no single type: the tool instantiates them for a stand-in `App` and prints them
//! as `app.Context(App)` (the UI context `App.draw` receives) and `draw.Context(...)` (the draw
//! context `cx.drawing()` returns). A container a field names that has no public path of its
//! own (a union's payload struct) is named after its parent and field: `draw.Gradient.linear`.
//! A public name for a type that is not a container (`draw.Point`, `[2]f32`) is lost to
//! reflection, so each one the source of a printed signature or field writes is printed as an
//! alias: a first pass over the parts records the aliases the cross-check passes through.
//!
//! ## 3. Resolving a Public Path
//! `text.place` is resolved from `src/root.zig` one name at a time over a stack of pending
//! lookups: an identifier is looked up in its container and then its file's root, `a.b` looks up
//! `b` in what `a` resolved to, `@import("f.zig")` opens a file, `@This()` is the container it
//! is written in, and `F(...)` is the container `F` returns. Each declaration the path's own
//! name passes through (`text.place`, an alias, then `layout.place`, the function) is a
//! candidate: the first with a `///` comment gives the sentence, and the last gives the file.
//!
//! ## 4. The Cross-Check
//! A parameter's type expression is peeled (`?`, pointers, arrays, error unions) into the prefix
//! reflection prints, and its base is resolved to a declaration, which must be the one the
//! reflected type's public path resolves to; a primitive must have the same name. A base the
//! resolver cannot follow (a function's own parameter, as in `Draw`, or a call on one) is
//! unchecked, and more than `unchecked_max` of them fail the run.
//!
//! ## 5. Layout
//! Keys in a fixed order, one declaration a line, no other whitespace, so a diff of the golden
//! shows the declaration that changed, and two runs give the same bytes. A declaration's file is
//! printed and its line is not, so an edit that moves lines changes nothing in the golden. A
//! value is written as Zig writes it (`std.zon`): a default `.{0,0,0,0}`, an enum `.non_zero`.
//!
//! ## 6. TigerStyle Invariants
//! - Static memory: the sources and every syntax tree live in fixed arrays (`std.zig.Ast`
//!   allocates through a fixed buffer over one of them); the output is one fixed buffer.
//! - No recursion: resolution and peeling are loops over explicit stacks, each bounded.
//! - Linux only, like `tools/subset.zig`: files are read with plain system calls.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const Ast = std.zig.Ast;
const Writer = std.Io.Writer;
const patchwork = @import("patchwork");
const draw = patchwork.draw;
const text = patchwork.text;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

// ------------------------------------------------------------------ 1. The hand-kept list

/// What a function's `cx: anytype` parameter expects.
const Cx = enum { none, draw, ui };

/// One namespace whose public functions and constants are printed.
const Namespace = struct {
    /// The public path; a segment ending in `()` is the container that function returns.
    path: []const u8,
    /// The namespace itself, for reflection: an instantiation for a generic one.
    T: type,
    /// What its `cx: anytype` parameters expect.
    cx: Cx,
};

/// The stand-in app the generic contexts are instantiated for (section 2).
const App = struct {
    pub const config: patchwork.app.Config = .{
        .title = "describe",
        .timer_period_ms = 0,
        .draw = &.{
            .{ .type = draw.Box, .cap = 1 },
            .{ .type = draw.Path, .cap = 1 },
        },
    };
};
const UiContext = patchwork.app.Context(App);
const DrawContext = @FieldType(UiContext, "draw");

/// What a part's `cx: anytype` functions take, printed once at the top of the part (section 5).
const contexts = std.enums.EnumArray(Cx, []const u8).init(.{
    .none = "",
    .draw = "*draw.Context(...), which an app gets from cx.drawing()",
    .ui = "*app.Context(App), the cx App.draw receives",
});

comptime {
    // The phrases name `cx.drawing()` and `App.draw`'s parameter: a rename fails here.
    const drawing = @typeInfo(@TypeOf(UiContext.drawing)).@"fn";
    assert(drawing.return_type.? == *DrawContext);
    assert(drawing.param_types[0].? == *UiContext);
    const draw_call = patchwork.app.declarations(App)[4];
    assert(std.mem.eql(u8, draw_call.name, "draw"));
    assert(draw_call.type == fn (*App, *UiContext) void);
}

/// The namespaces whose functions are printed. Everything printed about them comes from the
/// code; this list only chooses, so it can leave a function out but cannot misdescribe one.
const namespaces = [_]Namespace{
    .{ .path = "draw", .T = draw, .cx = .draw },
    .{ .path = "draw.Context()", .T = DrawContext, .cx = .draw },
    .{ .path = "draw.Box", .T = draw.Box, .cx = .none },
    .{ .path = "draw.Arc", .T = draw.Arc, .cx = .none },
    .{ .path = "draw.Surface", .T = draw.Surface, .cx = .none },
    .{ .path = "draw.Glass", .T = draw.Glass, .cx = .none },
    .{ .path = "draw.Textures", .T = draw.Textures, .cx = .none },
    .{ .path = "draw.path", .T = draw.path, .cx = .draw },
    .{ .path = "draw.fill", .T = draw.fill, .cx = .draw },
    .{ .path = "draw.fill.Builder", .T = draw.fill.Builder, .cx = .none },
    .{ .path = "draw.Transform", .T = draw.Transform, .cx = .none },
    .{ .path = "draw.wave", .T = draw.wave, .cx = .draw },
    .{ .path = "draw.fx", .T = draw.fx, .cx = .draw },
    .{ .path = "text", .T = text, .cx = .draw },
    .{ .path = "text.Cache", .T = text.Cache, .cx = .none },
    .{ .path = "text.Glyphs", .T = text.Glyphs, .cx = .none },
    .{ .path = "text.ttf", .T = text.ttf, .cx = .none },
    .{ .path = "theme", .T = patchwork.theme, .cx = .none },
    .{ .path = "ui", .T = ui, .cx = .ui },
    .{ .path = "ui.Context()", .T = UiContext, .cx = .ui },
    .{ .path = "widgets.kit", .T = widgets.kit, .cx = .ui },
    .{ .path = "app", .T = patchwork.app, .cx = .none },
};

/// The library's namespaces the public-name walk starts from, in order of preference.
const roots = [_][]const u8{
    "draw",  "text",     "theme", "ui",   "widgets", "app",    "bench",
    "input", "animator", "frame", "wake", "drop",    "editor", "commands",
};

/// Depth of the public-name walk: `widgets.Knob.Action` is depth 2.
const depth_max: u32 = 3;
/// Most public types the walk records.
const public_cap: u32 = 1024;
/// Most types the types section prints.
const type_cap: u32 = 256;
/// Most parameters the cross-check may leave unresolved (section 4).
const unchecked_max: u32 = 16;

comptime {
    @setEvalBranchQuota(100_000);
    for (namespaces) |entry| check_namespace(entry);
}

/// Fails the build when `entry.path` does not reach `entry.T` from the library's root.
fn check_namespace(comptime entry: Namespace) void {
    var current: type = patchwork;
    var called = false;
    var parts = std.mem.splitScalar(u8, entry.path, '.');
    while (parts.next()) |part| {
        const call = std.mem.endsWith(u8, part, "()");
        const name = if (call) part[0 .. part.len - 2] else part;
        if (!@hasDecl(current, name)) {
            @compileError("describe: namespace " ++ entry.path ++ ": no `" ++ name ++ "`");
        }
        if (call) {
            const F = @TypeOf(@field(current, name));
            if (@typeInfo(F) != .@"fn") @compileError("describe: " ++ entry.path ++ ": not a fn");
            called = true;
        } else {
            current = @field(current, name);
        }
    }
    if (!called and current != entry.T) {
        @compileError("describe: namespace " ++ entry.path ++ " is not the type listed");
    }
}

// ------------------------------------------------------------------ 2. Public names

const Public = struct {
    T: type,
    /// As an app writes it: `draw.BoxLook`.
    name: []const u8,
    /// What the resolver follows to its declaration (section 3); null when it has none.
    path: ?[]const u8,
};

fn is_container(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque", .error_set => true,
        else => false,
    };
}

fn decls_of(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.decl_names,
        .@"union" => |u| u.decl_names,
        .@"enum" => |e| e.decl_names,
        .@"opaque" => |o| o.decl_names,
        else => &.{},
    };
}

fn depth_of(comptime name: []const u8) u32 {
    return @intCast(std.mem.count(u8, name, "."));
}

/// The walk of section 2, after the stand-ins for the generic contexts.
const public: []const Public = walk: {
    @setEvalBranchQuota(10_000_000);
    var list: [public_cap]Public = undefined;
    list[0] = .{ .T = DrawContext, .name = "draw.Context(...)", .path = "draw.Context()" };
    list[1] = .{ .T = UiContext, .name = "app.Context(App)", .path = "ui.Context()" };
    list[2] = .{ .T = App, .name = "App", .path = null };
    const stand_ins: u32 = 3;
    var count: u32 = stand_ins;
    for (roots) |root| {
        list[count] = .{ .T = @field(patchwork, root), .name = root, .path = root };
        count += 1;
    }
    var head: u32 = stand_ins;
    while (head < count) : (head += 1) {
        const entry = list[head];
        if (depth_of(entry.name) >= depth_max) continue;
        for (decls_of(entry.T)) |decl| {
            if (@TypeOf(@field(entry.T, decl)) != type) continue;
            const value = @field(entry.T, decl);
            if (!is_container(value)) continue;
            if (index_of(list[0..count], value) != null) continue;
            assert(count < public_cap);
            const name = entry.name ++ "." ++ decl;
            list[count] = .{ .T = value, .name = name, .path = name };
            count += 1;
        }
    }
    const final = list[0..count].*;
    break :walk &final;
};

fn index_of(comptime list: []const Public, comptime T: type) ?u32 {
    for (list, 0..) |entry, index| {
        if (entry.T == T) return index;
    }
    return null;
}

fn public_of(comptime T: type) ?Public {
    @setEvalBranchQuota(10_000_000);
    const index = index_of(public, T) orelse return null;
    return public[index];
}

/// A type's wrappers, outermost first, and what they wrap.
const Peeled = struct {
    /// As printed: `?[]const `, `[4]`, `draw.AppendError!`.
    prefix: []const u8,
    base: type,
    /// The error set of an error union in the wrappers, if any.
    error_set: ?type,
};

fn peel(comptime T: type) Peeled {
    var prefix: []const u8 = "";
    var current: type = T;
    var error_set: ?type = null;
    for (0..16) |_| {
        switch (@typeInfo(current)) {
            .optional => |o| {
                prefix = prefix ++ "?";
                current = o.child;
            },
            .pointer => |p| {
                const sentinel = if (p.sentinel_ptr == null) "" else std.fmt.comptimePrint(
                    ":{any}",
                    .{@as(*const p.child, @ptrCast(@alignCast(p.sentinel_ptr.?))).*},
                );
                prefix = prefix ++ switch (p.size) {
                    .one => "*",
                    .slice => "[" ++ sentinel ++ "]",
                    .many => "[*" ++ sentinel ++ "]",
                    .c => "[*c]",
                } ++ (if (p.attrs.@"const") "const " else "");
                current = p.child;
            },
            .array => |a| {
                prefix = prefix ++ std.fmt.comptimePrint("[{d}]", .{a.len});
                current = a.child;
            },
            .error_union => |e| {
                const set = if (public_of(e.error_set)) |found| found.name else "";
                if (set.len > 0) error_set = e.error_set;
                prefix = prefix ++ set ++ "!";
                current = e.payload;
            },
            else => return .{ .prefix = prefix, .base = current, .error_set = error_set },
        }
    }
    unreachable;
}

/// `T` as an app writes it: wrappers peeled in a loop, then the base's public name.
fn type_text(comptime T: type) []const u8 {
    @setEvalBranchQuota(10_000_000);
    const peeled = peel(T);
    return peeled.prefix ++ base_text(peeled.base);
}

fn base_text(comptime T: type) []const u8 {
    if (public_of(T)) |found| return found.name;
    if (anonymous_of(T)) |name| return name;
    if (@typeInfo(T) == .@"fn") return fn_text(T);
    return @typeName(T);
}

fn fn_text(comptime F: type) []const u8 {
    const info = @typeInfo(F).@"fn";
    var out: []const u8 = "fn (";
    for (info.param_types, 0..) |P, index| {
        if (index > 0) out = out ++ ", ";
        out = out ++ if (P) |known| type_text(known) else "anytype";
    }
    return out ++ ") " ++ if (info.return_type) |R| type_text(R) else "anytype";
}

// ------------------------------------------------------------------ 3. What is printed

const Function = struct {
    /// As printed: `draw.path.polyline`, or `draw.Context(...).layer`.
    name: []const u8,
    /// What the resolver follows: `draw.Context().layer`.
    path: []const u8,
    F: type,
    cx: Cx,
};

fn printed_name(comptime path: []const u8) []const u8 {
    var out: []const u8 = "";
    var parts = std.mem.splitScalar(u8, path, '.');
    var first = true;
    while (parts.next()) |part| {
        if (!first) out = out ++ ".";
        first = false;
        if (std.mem.endsWith(u8, part, "()")) {
            out = out ++ part[0 .. part.len - 2] ++ "(...)";
        } else {
            out = out ++ part;
        }
    }
    return out;
}

const functions: []const Function = list: {
    @setEvalBranchQuota(10_000_000);
    var out: []const Function = &.{};
    for (namespaces) |entry| {
        for (decls_of(entry.T)) |decl| {
            const F = @TypeOf(@field(entry.T, decl));
            if (@typeInfo(F) != .@"fn") continue;
            const path = entry.path ++ "." ++ decl;
            out = out ++ [_]Function{.{
                .name = printed_name(path),
                .path = path,
                .F = F,
                .cx = entry.cx,
            }};
        }
    }
    break :list out;
};

/// Whether every type `T` holds is plain data a constant can print: no pointer, no type, no
/// non-exhaustive enum. A worklist, not recursion.
fn plain(comptime T: type) bool {
    var pending: []const type = &.{T};
    var steps: u32 = 0;
    while (pending.len > 0) : (steps += 1) {
        if (steps > 256) return false;
        const U = pending[0];
        pending = pending[1..];
        switch (@typeInfo(U)) {
            .int, .float, .bool => {},
            .@"enum" => |e| if (e.mode == .nonexhaustive) return false,
            .array => |a| {
                if (a.len > 16) return false;
                pending = pending ++ [_]type{a.child};
            },
            .optional => |o| pending = pending ++ [_]type{o.child},
            .@"struct" => |s| {
                if (s.is_tuple) return false;
                pending = pending ++ s.field_types;
            },
            else => return false,
        }
    }
    return true;
}

/// Whether `T` holds a field only the compiler can hold (`type`), so it has no size.
fn comptime_only(comptime T: type) bool {
    var pending: []const type = &.{T};
    var seen: []const type = &.{};
    var steps: u32 = 0;
    outer: while (pending.len > 0) : (steps += 1) {
        assert(steps < 1024);
        const U = pending[0];
        pending = pending[1..];
        for (seen) |known| {
            if (known == U) continue :outer;
        }
        seen = seen ++ [_]type{U};
        switch (@typeInfo(U)) {
            .type, .comptime_int, .comptime_float, .enum_literal, .@"fn" => return true,
            .array => |a| pending = pending ++ [_]type{a.child},
            .optional => |o| pending = pending ++ [_]type{o.child},
            .pointer => |p| if (@typeInfo(p.child) != .@"fn") {
                pending = pending ++ [_]type{p.child};
            },
            .@"struct" => |s| pending = pending ++ s.field_types,
            .@"union" => |u| pending = pending ++ u.field_types,
            else => {},
        }
    }
    return false;
}

const Constant = struct { name: []const u8, T: type, value: *const anyopaque };

const constants: []const Constant = list: {
    @setEvalBranchQuota(10_000_000);
    var out: []const Constant = &.{};
    for (namespaces) |entry| {
        if (std.mem.indexOf(u8, entry.path, "()") != null) continue;
        // A draw type's own declarations (`texture`, `blend`) are its draw_types entry.
        if (is_draw_type(entry.T)) continue;
        for (decls_of(entry.T)) |decl| {
            const V = @TypeOf(@field(entry.T, decl));
            if (V == type) continue;
            if (@typeInfo(V) == .@"fn") continue;
            if (!plain(V)) continue;
            out = out ++ [_]Constant{.{
                .name = entry.path ++ "." ++ decl,
                .T = V,
                .value = &@field(entry.T, decl),
            }};
        }
    }
    break :list out;
};

/// A library draw type: an extern struct with `pixel` and `texture` (`draw/registry.zig`).
fn is_draw_type(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@typeInfo(T).@"struct".layout != .@"extern") return false;
    return @hasDecl(T, "pixel") and @hasDecl(T, "texture");
}

const draw_types: []const Public = list: {
    @setEvalBranchQuota(10_000_000);
    var out: []const Public = &.{};
    for (public) |entry| {
        if (is_draw_type(entry.T)) out = out ++ [_]Public{entry};
    }
    break :list out;
};

/// A widget: a public `widgets.X` struct with `handle` or `draw`.
fn is_widget(comptime entry: Public) bool {
    if (!std.mem.startsWith(u8, entry.name, "widgets.")) return false;
    if (depth_of(entry.name) != 1) return false;
    if (@typeInfo(entry.T) != .@"struct") return false;
    return @hasDecl(entry.T, "handle") or @hasDecl(entry.T, "draw");
}

const widget_list: []const Public = list: {
    @setEvalBranchQuota(10_000_000);
    var out: []const Public = &.{};
    for (public) |entry| {
        if (is_widget(entry)) out = out ++ [_]Public{entry};
    }
    break :list out;
};

/// A widget without `init` is made with a struct literal, so its fields are printed instead.
fn has_init(comptime W: type) bool {
    return @hasDecl(W, "init") and @typeInfo(@TypeOf(W.init)) == .@"fn";
}

const Step = patchwork.bench.Step;

/// A type printed as its own section or as functions, never in the types section.
fn printed_elsewhere(comptime T: type) bool {
    if (is_draw_type(T)) return true;
    if (T == DrawContext or T == UiContext or T == App or T == Step) return true;
    for (widget_list) |entry| {
        if (entry.T == T) return true;
    }
    for (widget_list) |entry| {
        if (@hasDecl(entry.T, "Action") and entry.T.Action == T) return true;
    }
    return false;
}

/// A type whose functions are printed: its fields are printed, but not followed.
fn is_namespace(comptime T: type) bool {
    for (namespaces) |entry| {
        if (entry.T == T) return true;
    }
    return T == DrawContext or T == UiContext;
}

/// A container a field names with no public path of its own: `draw.Gradient.linear`.
const Anonymous = struct { T: type, name: []const u8 };

const Collected = struct { types: []const Public, anonymous: []const Anonymous };

fn add_base(comptime list: []const type, comptime T: type) []const type {
    const base = peel(T).base;
    if (!is_container(base)) return list;
    for (list) |known| {
        if (known == base) return list;
    }
    return list ++ [_]type{base};
}

fn add_fields(comptime list: []const type, comptime T: type) []const type {
    var out = list;
    switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.field_types) |F| {
            out = add_base(out, F);
        },
        .@"union" => |u| for (u.field_types) |F| {
            out = add_base(out, F);
        },
        else => {},
    }
    return out;
}

fn anonymous_by_name(comptime T: type) bool {
    return std.mem.indexOf(u8, @typeName(T), "__") != null;
}

/// The types section: every container the draw types, the functions, the widgets, the contract,
/// the scenario steps, and the constants name, and those their fields name, by a worklist.
const collected: Collected = collect: {
    @setEvalBranchQuota(100_000_000);
    var list: []const type = &.{};
    for (functions) |function| {
        const info = @typeInfo(function.F).@"fn";
        for (info.param_types) |P| {
            if (P) |known| list = add_base(list, known);
        }
        if (info.return_type) |R| list = add_base(list, R);
    }
    for (draw_types) |entry| {
        if (@hasDecl(entry.T, "of")) {
            for (@typeInfo(@TypeOf(entry.T.of)).@"fn".param_types) |P| list = add_base(list, P.?);
        }
    }
    for (widget_list) |entry| {
        if (has_init(entry.T)) {
            for (@typeInfo(@TypeOf(entry.T.init)).@"fn".param_types) |P| {
                if (P) |known| list = add_base(list, known);
            }
        } else {
            list = add_fields(list, entry.T);
        }
        if (@hasDecl(entry.T, "Action")) list = add_fields(list, entry.T.Action);
    }
    for (patchwork.app.declarations(App)) |declaration| list = add_base(list, declaration.type);
    list = add_fields(list, Step);
    for (constants) |constant| list = add_base(list, constant.T);
    var anonymous: []const Anonymous = &.{};
    var head: u32 = 0;
    while (head < list.len) : (head += 1) {
        const T = list[head];
        if (is_namespace(T) or printed_elsewhere(T)) continue;
        const names: []const [:0]const u8, const fields: []const type = switch (@typeInfo(T)) {
            .@"struct" => |s| .{ s.field_names, s.field_types },
            .@"union" => |u| .{ u.field_names, u.field_types },
            else => .{ &.{}, &.{} },
        };
        for (names, fields) |field, F| {
            const base = peel(F).base;
            if (!is_container(base)) continue;
            const named = public_of(base) != null or anonymous_index(anonymous, base) != null;
            if (!named and anonymous_by_name(base)) {
                const parent = if (public_of(T)) |p|
                    p.name
                else
                    anonymous[anonymous_index(anonymous, T).?].name;
                const name = parent ++ "." ++ field;
                anonymous = anonymous ++ [_]Anonymous{.{ .T = base, .name = name }};
            }
            list = add_base(list, F);
        }
    }
    var out: []const Public = &.{};
    for (list) |T| {
        if (printed_elsewhere(T)) continue;
        if (public_of(T)) |found| {
            out = out ++ [_]Public{found};
        } else if (anonymous_index(anonymous, T)) |index| {
            out = out ++ [_]Public{.{ .T = T, .name = anonymous[index].name, .path = null }};
        } else {
            out = out ++ [_]Public{.{ .T = T, .name = @typeName(T), .path = null }};
        }
    }
    assert(out.len <= type_cap);
    break :collect .{ .types = sorted(out), .anonymous = anonymous };
};

/// `list` by name, so the golden's order does not follow the walk's.
fn sorted(comptime list: []const Public) []const Public {
    var out: [list.len]Public = list[0..list.len].*;
    for (1..out.len) |i| {
        var j = i;
        while (j > 0 and std.mem.order(u8, out[j - 1].name, out[j].name) == .gt) : (j -= 1) {
            const swap = out[j];
            out[j] = out[j - 1];
            out[j - 1] = swap;
        }
    }
    const final = out;
    return &final;
}

/// Every public name for a type that is not a container (`draw.Point` is `[2]f32`), at its
/// shortest path. Reflection prints the type it names, so the run prints beside it each such
/// name the source of a printed signature or field writes (`alias_used`).
const alias_candidates: []const Public = list: {
    @setEvalBranchQuota(100_000_000);
    var out: []const Public = &.{};
    for (public) |entry| {
        if (entry.path == null) continue;
        if (depth_of(entry.name) >= depth_max) continue;
        if (entry.T == DrawContext or entry.T == UiContext) continue;
        for (decls_of(entry.T)) |decl| {
            if (@TypeOf(@field(entry.T, decl)) != type) continue;
            const value = @field(entry.T, decl);
            if (is_container(value)) continue;
            if (@typeInfo(value) == .@"fn") continue;
            const name = entry.name ++ "." ++ decl;
            out = out ++ [_]Public{.{ .T = value, .name = name, .path = name }};
        }
    }
    break :list out;
};

fn anonymous_index(comptime list: []const Anonymous, comptime T: type) ?u32 {
    for (list, 0..) |entry, index| {
        if (entry.T == T) return index;
    }
    return null;
}

fn anonymous_of(comptime T: type) ?[]const u8 {
    const index = anonymous_index(collected.anonymous, T) orelse return null;
    return collected.anonymous[index].name;
}

// ------------------------------------------------------------------ 4. Sources and trees

/// Largest source the tool reads, all files together.
const source_cap: u32 = 8 * 1024 * 1024;
/// The syntax trees' fixed buffer.
const tree_cap: u32 = 96 * 1024 * 1024;
/// Most files the tool opens.
const file_cap: u32 = 160;
/// Longest relative path of a file under `<src-dir>`.
const path_max: u32 = 128;
/// Largest output.
const output_cap: u32 = 1024 * 1024;

var source_bytes: [source_cap]u8 = undefined;
var source_used: u32 = 0;
var tree_bytes: [tree_cap]u8 = undefined;
var tree_allocator: std.heap.FixedBufferAllocator = undefined;
var output_bytes: [output_cap]u8 = undefined;

const File = struct {
    path: [path_max]u8,
    path_len: u32,
    tree: Ast,

    fn name(file: *const File) []const u8 {
        return file.path[0..file.path_len];
    }
};

var files: [file_cap]File = undefined;
var file_count: u32 = 0;
var src_dir: []const u8 = "";

const Failure = error{ Missing, Unresolved, Mismatch, Capacity, Io };

/// The tree of `path` (relative to `<src-dir>`), parsing it on first use.
fn open(path: []const u8) Failure!u16 {
    assert(path.len > 0);
    for (files[0..file_count], 0..) |*file, index| {
        if (std.mem.eql(u8, file.name(), path)) return @intCast(index);
    }
    if (file_count == file_cap or path.len > path_max) return error.Capacity;
    var full: [512]u8 = undefined;
    const joined = std.fmt.bufPrintSentinel(&full, "{s}/{s}", .{ src_dir, path }, 0) catch {
        return error.Capacity;
    };
    const source = try read(joined);
    const allocator = tree_allocator.allocator();
    const tree = Ast.parse(allocator, source, .{ .mode = .zig }) catch return error.Capacity;
    if (tree.errors.len > 0) return error.Io;
    const file = &files[file_count];
    @memcpy(file.path[0..path.len], path);
    file.path_len = @intCast(path.len);
    file.tree = tree;
    file_count += 1;
    assert(file_count <= file_cap);
    return @intCast(file_count - 1);
}

/// Reads `path` into the source buffer with a 0 after it, as `Ast.parse` takes it.
fn read(path: [:0]const u8) Failure![:0]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        if (!quiet) std.debug.print("describe: cannot open {s}\n", .{path});
        return error.Io;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const start = source_used;
    var reads: u32 = 0;
    while (true) : (reads += 1) {
        if (reads > 4096) return error.Io;
        if (source_used + 1 >= source_cap) return error.Capacity;
        const room = source_cap - 1 - source_used;
        const result = linux.read(fd, source_bytes[source_used..].ptr, room);
        if (linux.errno(result) != .SUCCESS) return error.Io;
        if (result == 0) break;
        source_used += @intCast(result);
    }
    source_bytes[source_used] = 0;
    const out = source_bytes[start..source_used :0];
    source_used += 1;
    assert(source_used <= source_cap);
    return out;
}

/// `relative`, an `@import` written in `from`, as a path under `<src-dir>`; null when it
/// leaves it.
fn joined_path(buffer: *[path_max]u8, from: []const u8, relative: []const u8) ?[]const u8 {
    var parts: [16][]const u8 = undefined;
    var count: u32 = 0;
    var base = std.mem.splitScalar(u8, from, '/');
    while (base.next()) |part| {
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    count -= 1; // The file's own name.
    var rest = std.mem.splitScalar(u8, relative, '/');
    while (rest.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return null;
            count -= 1;
        } else if (!std.mem.eql(u8, part, ".")) {
            if (count == parts.len) return null;
            parts[count] = part;
            count += 1;
        }
    }
    var writer: Writer = .fixed(buffer);
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) writer.writeByte('/') catch return null;
        writer.writeAll(part) catch return null;
    }
    return writer.buffered();
}

// ------------------------------------------------------------------ 5. Resolution

const Node = Ast.Node.Index;

/// A container in a file: the file's root, a `struct {}`, or a returned one.
const Container = struct { file: u16, node: Node };

/// A declaration: the node of its `const`, `fn`, or field, in a file.
const Decl = struct { file: u16, node: Node };

const Result = union(enum) {
    container: Container,
    function: Decl,
    /// An expression the resolver does not follow further: an array type, a literal.
    value: struct { file: u16, node: Node, scope: Container },
    unresolved,
};

const Found = struct {
    result: Result,
    /// The first candidate declaration with a `///` comment (section 3).
    doc: ?Decl,
    /// The last candidate: its file and line are printed.
    last: ?Decl,
};

const Pending = union(enum) {
    /// An identifier, looked up in `scope` and then its file's root.
    ident: struct { name: []const u8, scope: Container },
    /// A name looked up in the result so far.
    field: []const u8,
    call,
    result: Result,
};

const pending_cap: u32 = 64;
const resolve_steps_max: u32 = 512;

fn tree_of(file: u16) *const Ast {
    assert(file < file_count);
    return &files[file].tree;
}

fn root_of(file: u16) Container {
    return .{ .file = file, .node = .root };
}

/// Pushes what `node`, an expression written in `scope`, asks for (section 3).
fn push_expression(
    stack: *[pending_cap]Pending,
    count: *u32,
    file: u16,
    start: Node,
    scope: Container,
) Failure!void {
    const tree = tree_of(file);
    var node = start;
    for (0..32) |_| {
        if (count.* + 1 >= pending_cap) return error.Capacity;
        switch (tree.nodeTag(node)) {
            .identifier => {
                const name = tree.tokenSlice(tree.nodeMainToken(node));
                stack[count.*] = .{ .ident = .{ .name = name, .scope = scope } };
                count.* += 1;
                return;
            },
            .field_access => {
                const lhs, const name_token = tree.nodeData(node).node_and_token;
                stack[count.*] = .{ .field = tree.tokenSlice(name_token) };
                count.* += 1;
                node = lhs;
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                var buffer: [1]Node = undefined;
                const call = tree.fullCall(&buffer, node).?;
                stack[count.*] = .call;
                count.* += 1;
                node = call.ast.fn_expr;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                const builtin = tree.tokenSlice(tree.nodeMainToken(node));
                var buffer: [2]Node = undefined;
                const params = tree.builtinCallParams(&buffer, node).?;
                var result: Result = .unresolved;
                if (std.mem.eql(u8, builtin, "@This")) {
                    result = .{ .container = scope };
                } else if (std.mem.eql(u8, builtin, "@import") and params.len == 1) {
                    const literal = tree.tokenSlice(tree.nodeMainToken(params[0]));
                    const relative = literal[1 .. literal.len - 1];
                    var path_buffer: [path_max]u8 = undefined;
                    if (std.mem.endsWith(u8, relative, ".zig")) {
                        if (joined_path(&path_buffer, files[file].name(), relative)) |path| {
                            result = .{ .container = root_of(try open(path)) };
                        }
                    }
                }
                stack[count.*] = .{ .result = result };
                count.* += 1;
                return;
            },
            else => {
                var buffer: [2]Node = undefined;
                const result: Result = if (tree.fullContainerDecl(&buffer, node) != null)
                    .{ .container = .{ .file = file, .node = node } }
                else
                    .{ .value = .{ .file = file, .node = node, .scope = scope } };
                stack[count.*] = .{ .result = result };
                count.* += 1;
                return;
            },
        }
    }
    return error.Capacity;
}

/// The member of `container` named `name`: a declaration or a field.
fn member(container: Container, name: []const u8) ?Decl {
    return member_of(container, name, true);
}

/// The declaration of `container` named `name`, for an identifier: an expression never names
/// a field, and a field may share a declaration's name (`textures: textures.Textures`).
fn declared(container: Container, name: []const u8) ?Decl {
    return member_of(container, name, false);
}

fn member_of(container: Container, name: []const u8, fields: bool) ?Decl {
    const tree = tree_of(container.file);
    var buffer: [2]Node = undefined;
    const decl = tree.fullContainerDecl(&buffer, container.node) orelse return null;
    for (decl.ast.members) |node| {
        const is_field = switch (tree.nodeTag(node)) {
            .container_field_init, .container_field_align, .container_field => true,
            else => false,
        };
        if (is_field and !fields) continue;
        if (member_name(tree, node)) |found| {
            if (std.mem.eql(u8, found, name)) return .{ .file = container.file, .node = node };
        }
    }
    return null;
}

fn member_name(tree: *const Ast, node: Node) ?[]const u8 {
    var buffer: [1]Node = undefined;
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            const proto_node = tree.nodeData(node).node_and_node[0];
            const proto = tree.fullFnProto(&buffer, proto_node).?;
            return tree.tokenSlice(proto.name_token orelse return null);
        },
        .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
            const proto = tree.fullFnProto(&buffer, node).?;
            return tree.tokenSlice(proto.name_token orelse return null);
        },
        .container_field_init, .container_field_align, .container_field => {
            return tree.tokenSlice(tree.nodeMainToken(node));
        },
        else => {
            const var_decl = tree.fullVarDecl(node) orelse return null;
            return tree.tokenSlice(var_decl.ast.mut_token + 1);
        },
    }
}

/// The container `function` returns: the first `return struct { ... }` in its body.
fn returned_container(function: Decl) ?Container {
    const tree = tree_of(function.file);
    if (tree.nodeTag(function.node) != .fn_decl) return null;
    const body = tree.nodeData(function.node).node_and_node[1];
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    var buffer: [2]Node = undefined;
    for (0..tree.nodes.len) |index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));
        if (tree.fullContainerDecl(&buffer, node) == null) continue;
        if (tree.nodeTag(node) == .root) continue;
        const token = tree.firstToken(node);
        if (token <= first or token > last) continue;
        if (tree.tokenTag(token - 1) != .keyword_return) continue;
        return .{ .file = function.file, .node = node };
    }
    return null;
}

/// Resolves `path` from `src/root.zig`, a segment ending in `()` being a call (section 3).
fn resolve_path(path: []const u8) Failure!Found {
    var stack: [pending_cap]Pending = undefined;
    var count: u32 = 0;
    // Push the segments last first, so the first is on top.
    var segments: [16][]const u8 = undefined;
    var segment_count: u32 = 0;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (segment_count == segments.len) return error.Capacity;
        segments[segment_count] = part;
        segment_count += 1;
    }
    var index = segment_count;
    while (index > 0) {
        index -= 1;
        const part = segments[index];
        const call = std.mem.endsWith(u8, part, "()");
        if (call) {
            stack[count] = .call;
            count += 1;
        }
        stack[count] = .{ .field = if (call) part[0 .. part.len - 2] else part };
        count += 1;
    }
    const root = try open("root.zig");
    stack[count] = .{ .result = .{ .container = root_of(root) } };
    count += 1;
    return run(&stack, &count);
}

/// Resolves the expression `node` written in `scope`.
fn resolve_expression(file: u16, node: Node, scope: Container) Failure!Found {
    var stack: [pending_cap]Pending = undefined;
    var count: u32 = 0;
    try push_expression(&stack, &count, file, node, scope);
    return run(&stack, &count);
}

/// The machine of section 3: pops lookups until the stack is empty.
fn run(stack: *[pending_cap]Pending, count: *u32) Failure!Found {
    var found: Found = .{ .result = .unresolved, .doc = null, .last = null };
    var steps: u32 = 0;
    while (count.* > 0) : (steps += 1) {
        if (steps == resolve_steps_max) return error.Capacity;
        count.* -= 1;
        const item = stack[count.*];
        const decl: Decl = switch (item) {
            .result => |result| {
                found.result = result;
                continue;
            },
            .call => {
                const function = switch (found.result) {
                    .function => |function| function,
                    else => {
                        found.result = .unresolved;
                        continue;
                    },
                };
                found.result = if (returned_container(function)) |container|
                    .{ .container = container }
                else
                    .unresolved;
                continue;
            },
            .ident => |ident| declared(ident.scope, ident.name) orelse
                declared(root_of(ident.scope.file), ident.name) orelse {
                found.result = .unresolved;
                continue;
            },
            .field => |name| switch (found.result) {
                .container => |container| member(container, name) orelse {
                    found.result = .unresolved;
                    continue;
                },
                else => {
                    found.result = .unresolved;
                    continue;
                },
            },
        };
        // A candidate when only calls remain below it: the path's own name, or its alias.
        var item_level = true;
        for (stack[0..count.*]) |below| {
            if (below != .call) item_level = false;
        }
        if (item_level) {
            if (found.doc == null and doc_token(decl) != null) found.doc = decl;
            found.last = decl;
        }
        const tree = tree_of(decl.file);
        const container = container_of(decl);
        switch (tree.nodeTag(decl.node)) {
            .fn_decl => found.result = .{ .function = decl },
            .container_field_init, .container_field_align, .container_field => {
                found.result = .{ .value = .{
                    .file = decl.file,
                    .node = decl.node,
                    .scope = container,
                } };
            },
            else => {
                const var_decl = tree.fullVarDecl(decl.node) orelse {
                    found.result = .unresolved;
                    continue;
                };
                const init = var_decl.ast.init_node.unwrap() orelse {
                    found.result = .unresolved;
                    continue;
                };
                try push_expression(stack, count, decl.file, init, container);
            },
        }
    }
    return found;
}

/// The container a member declaration is written in.
fn container_of(decl: Decl) Container {
    const tree = tree_of(decl.file);
    var buffer: [2]Node = undefined;
    const token = tree.firstToken(decl.node);
    // The innermost container whose members hold `decl`.
    var best: Container = root_of(decl.file);
    var best_span: u32 = std.math.maxInt(u32);
    for (0..tree.nodes.len) |index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));
        const container = tree.fullContainerDecl(&buffer, node) orelse continue;
        if (tree.nodeTag(node) == .root) continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (token <= first or token >= last) continue;
        if (last - first >= best_span) continue;
        for (container.ast.members) |candidate| {
            if (candidate == decl.node) {
                best = .{ .file = decl.file, .node = node };
                best_span = last - first;
            }
        }
    }
    return best;
}

/// The first `///` token before `decl`, or null.
fn doc_token(decl: Decl) ?Ast.TokenIndex {
    const tree = tree_of(decl.file);
    const first = tree.firstToken(decl.node);
    var token = first;
    var steps: u32 = 0;
    while (token > 0 and tree.tokenTag(token - 1) == .doc_comment) : (steps += 1) {
        assert(steps < 4096);
        token -= 1;
    }
    return if (token == first) null else token;
}

/// Writes the first sentence of the `///` (or `//!`) comment from `token`, joined onto one line.
fn write_sentence(writer: *Writer, file: u16, token: Ast.TokenIndex) Writer.Error!void {
    const tree = tree_of(file);
    var current = token;
    var started = false;
    var in_code = false;
    var steps: u32 = 0;
    const tag = tree.tokenTag(token);
    assert(tag == .doc_comment or tag == .container_doc_comment);
    while (tree.tokenTag(current) == tag) : (current += 1) {
        assert(steps < 4096);
        steps += 1;
        const raw = tree.tokenSlice(current);
        assert(std.mem.startsWith(u8, raw, "///") or std.mem.startsWith(u8, raw, "//!"));
        const line = std.mem.trim(u8, raw[3..], " \t\r");
        if (line.len == 0) {
            if (started) return; // A blank comment line ends the paragraph.
            continue;
        }
        if (started) try writer.writeByte(' ');
        started = true;
        for (line, 0..) |byte, index| {
            if (byte == '`') in_code = !in_code;
            try write_json_char(writer, byte);
            if (byte == '.' and !in_code) {
                const end = index + 1 == line.len or line[index + 1] == ' ';
                if (end) return;
            }
        }
    }
}

fn write_json_char(writer: *Writer, byte: u8) Writer.Error!void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    }
}

// ------------------------------------------------------------------ 6. The cross-check

/// One parameter or return type as reflection sees it, for the check of section 4.
const Expected = struct {
    /// Null for `anytype` or a type that depends on an earlier parameter.
    text: ?[]const u8,
    prefix: []const u8,
    /// The base's public path to resolve, or null for a primitive or an unnamed type.
    path: ?[]const u8,
    /// The base's name when it is a primitive: `f32`.
    primitive: ?[]const u8,
    /// The public path of the error set in the wrappers, if any.
    error_path: ?[]const u8,
};

fn expected_of(comptime T: ?type) Expected {
    @setEvalBranchQuota(10_000_000);
    const known = T orelse return .{
        .text = null,
        .prefix = "",
        .path = null,
        .primitive = null,
        .error_path = null,
    };
    const peeled = peel(known);
    const named = public_of(peeled.base);
    const primitive = !is_container(peeled.base) and @typeInfo(peeled.base) != .@"fn";
    const error_path = if (peeled.error_set) |set| public_of(set).?.path else null;
    return .{
        .text = comptime type_text(known),
        .prefix = peeled.prefix,
        .path = if (named) |entry| entry.path else null,
        .primitive = if (primitive) @typeName(peeled.base) else null,
        .error_path = error_path,
    };
}

/// `expected` with the `!` of an inferred error set taken off its prefix.
fn without_bang(comptime expected: Expected) Expected {
    var out = expected;
    if (std.mem.startsWith(u8, out.prefix, "!")) out.prefix = out.prefix[1..];
    return out;
}

/// Most aliases the sources of printed declarations name.
const alias_cap: u32 = 64;
var alias_used: [alias_cap]Decl = undefined;
var alias_used_count: u32 = 0;

/// Records that a printed signature or field names the alias `decl` (`alias_candidates`).
fn note_alias(decl: ?Decl) void {
    const found = decl orelse return;
    for (alias_used[0..alias_used_count]) |seen| {
        if (seen.file == found.file and seen.node == found.node) return;
    }
    if (alias_used_count == alias_cap) return;
    alias_used[alias_used_count] = found;
    alias_used_count += 1;
}

fn alias_was_used(decl: Decl) bool {
    for (alias_used[0..alias_used_count]) |seen| {
        if (seen.file == decl.file and seen.node == decl.node) return true;
    }
    return false;
}

/// Peels a field's type expression and records each alias of a type expression it names.
fn note_field_aliases(file: u16, start: Node, scope: Container) Failure!void {
    var current_file = file;
    var node = start;
    var current_scope = scope;
    for (0..32) |_| {
        const tree = tree_of(current_file);
        switch (tree.nodeTag(node)) {
            .optional_type => node = tree.nodeData(node).node,
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                node = tree.fullPtrType(node).?.ast.child_type;
            },
            .array_type, .array_type_sentinel => node = tree.fullArrayType(node).?.ast.elem_type,
            .identifier, .field_access => {
                if (tree.nodeTag(node) == .identifier) {
                    const name = tree.tokenSlice(tree.nodeMainToken(node));
                    if (std.zig.primitives.isPrimitive(name)) return;
                }
                const found = try resolve_expression(current_file, node, current_scope);
                switch (found.result) {
                    .value => |value| {
                        note_alias(found.last);
                        current_file = value.file;
                        node = value.node;
                        current_scope = value.scope;
                    },
                    else => return,
                }
            },
            else => return,
        }
    }
}

var unchecked: u32 = 0;
var unchecked_names: [unchecked_max][]const u8 = undefined;

/// Checks the type expression `start` in `file`, written in `scope`, against `expected`.
fn check_type(
    file: u16,
    start: Node,
    scope: Container,
    expected: Expected,
    what: []const u8,
) Failure!void {
    var prefix_buffer: [64]u8 = undefined;
    var prefix: Writer = .fixed(&prefix_buffer);
    var current_file = file;
    var node = start;
    var current_scope = scope;
    for (0..32) |_| {
        const tree = tree_of(current_file);
        switch (tree.nodeTag(node)) {
            .optional_type => {
                prefix.writeByte('?') catch return error.Capacity;
                node = tree.nodeData(node).node;
            },
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                const pointer = tree.fullPtrType(node).?;
                const sentinel_node = pointer.ast.sentinel.unwrap();
                const sentinel = if (sentinel_node) |s| tree.getNodeSource(s) else "";
                const opener = switch (pointer.size) {
                    .one => "*",
                    .slice => "[",
                    .many => "[*",
                    .c => "[*c",
                };
                prefix.writeAll(opener) catch return error.Capacity;
                if (pointer.size != .one and pointer.size != .c) {
                    if (sentinel.len > 0) {
                        prefix.print(":{s}", .{sentinel}) catch return error.Capacity;
                    }
                }
                if (pointer.size != .one) prefix.writeByte(']') catch return error.Capacity;
                if (pointer.const_token != null) {
                    prefix.writeAll("const ") catch return error.Capacity;
                }
                node = pointer.ast.child_type;
            },
            .array_type, .array_type_sentinel => {
                const array = tree.fullArrayType(node).?;
                const count = tree.getNodeSource(array.ast.elem_count);
                const literal = tree.nodeTag(array.ast.elem_count) == .number_literal;
                prefix.print("[{s}]", .{if (literal) count else "_"}) catch return error.Capacity;
                node = array.ast.elem_type;
            },
            .error_union => {
                const set, const payload = tree.nodeData(node).node_and_node;
                const path = expected.error_path orelse return mismatch(what, "an error set");
                try check_same(current_file, set, current_scope, path, what);
                prefix.print("{s}!", .{error_name(expected.prefix)}) catch return error.Capacity;
                node = payload;
            },
            .identifier, .field_access, .call, .call_one, .call_comma, .call_one_comma => {
                if (tree.nodeTag(node) == .identifier) {
                    const name = tree.tokenSlice(tree.nodeMainToken(node));
                    if (std.zig.primitives.isPrimitive(name)) {
                        try check_prefix(prefix.buffered(), expected.prefix, what);
                        const primitive = expected.primitive orelse return mismatch(what, name);
                        if (!std.mem.eql(u8, primitive, name)) return mismatch(what, name);
                        return;
                    }
                }
                const found = try resolve_expression(current_file, node, current_scope);
                switch (found.result) {
                    .value => |value| {
                        // An alias of a type expression: `Point = [2]f32`. Peel it too.
                        note_alias(found.last);
                        current_file = value.file;
                        node = value.node;
                        current_scope = value.scope;
                        continue;
                    },
                    .container => |container| {
                        try check_prefix(prefix.buffered(), expected.prefix, what);
                        const path = expected.path orelse return note_unchecked(what);
                        const wanted = try resolve_path(path);
                        const same = switch (wanted.result) {
                            .container => |other| other.file == container.file and
                                other.node == container.node,
                            else => false,
                        };
                        if (!same) return mismatch(what, path);
                        return;
                    },
                    else => return note_unchecked(what),
                }
            },
            else => {
                const tag = tree.nodeTag(node);
                if (tag == .error_set_decl) return; // Checked by `check_same`'s caller.
                return note_unchecked(what);
            },
        }
    }
    return error.Capacity;
}

/// The error set's name in `prefix`, the part before `!`.
fn error_name(prefix: []const u8) []const u8 {
    const bang = std.mem.indexOfScalar(u8, prefix, '!') orelse return "";
    var start = bang;
    while (start > 0 and prefix[start - 1] != ' ' and prefix[start - 1] != ']' and
        prefix[start - 1] != '*' and prefix[start - 1] != '?') start -= 1;
    return prefix[start..bang];
}

/// The source's prefix must equal reflection's, an array length written as a name (`[_]`)
/// matching any number.
fn check_prefix(source: []const u8, reflected: []const u8, what: []const u8) Failure!void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < source.len and j < reflected.len) {
        if (std.mem.startsWith(u8, source[i..], "[_]") and reflected[j] == '[') {
            const close = std.mem.indexOfScalarPos(u8, reflected, j, ']') orelse break;
            i += 3;
            j = close + 1;
            continue;
        }
        if (source[i] != reflected[j]) break;
        i += 1;
        j += 1;
    }
    if (i != source.len or j != reflected.len) return mismatch(what, source);
}

/// The expression `node` must resolve to the same declaration as the public `path`.
fn check_same(
    file: u16,
    node: Node,
    scope: Container,
    path: []const u8,
    what: []const u8,
) Failure!void {
    const here = try resolve_expression(file, node, scope);
    const there = try resolve_path(path);
    const a = here.last orelse return note_unchecked(what);
    const b = there.last orelse return mismatch(what, path);
    if (a.file != b.file or a.node != b.node) return mismatch(what, path);
}

fn note_unchecked(what: []const u8) Failure!void {
    if (unchecked == unchecked_max) {
        std.debug.print("describe: more than {d} types the cross-check cannot follow\n", .{
            unchecked_max,
        });
        return error.Unresolved;
    }
    unchecked_names[unchecked] = what;
    unchecked += 1;
}

/// Set by the test that makes a mismatch on purpose, so it prints nothing.
var quiet = false;

fn mismatch(what: []const u8, source: []const u8) Failure {
    if (quiet) return error.Mismatch;
    const message = "describe: {s}: the source says `{s}`, reflection does not\n";
    std.debug.print(message, .{ what, source });
    return error.Mismatch;
}

// ------------------------------------------------------------------ 7. Writing

fn write_string(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| try write_json_char(writer, byte);
    try writer.writeByte('"');
}

/// `"doc":"...",` when `decl` has a `///` comment, else nothing.
fn write_doc(writer: *Writer, decl: ?Decl) Writer.Error!void {
    const found = decl orelse return;
    const token = doc_token(found) orelse return;
    try writer.writeAll("\"doc\":\"");
    try write_sentence(writer, found.file, token);
    try writer.writeAll("\",");
}

/// `"file":"src/...",` for the declaration a path resolved to. No line: a golden holding lines
/// would change with every edit above a declaration (section 5).
fn write_place(writer: *Writer, found: Found) Writer.Error!void {
    const last = found.last orelse return;
    try writer.print("\"file\":\"src/{s}\",", .{files[last.file].name()});
}

/// A value as Zig writes it: `std.zon`, or a tag of a non-exhaustive enum.
fn write_value(writer: *Writer, comptime T: type, value: T) Writer.Error!void {
    if (comptime plain(T) or zon_writes(T)) {
        var buffer: [1024]u8 = undefined;
        var zon: Writer = .fixed(&buffer);
        std.zon.stringify.serialize(value, .{ .whitespace = false }, &zon) catch {
            return write_string(writer, "(too long)");
        };
        return write_string(writer, zon.buffered());
    }
    if (@typeInfo(T) == .@"enum") {
        inline for (@typeInfo(T).@"enum".field_names) |tag| {
            if (value == @field(T, tag)) return write_string(writer, "." ++ tag);
        }
        var buffer: [32]u8 = undefined;
        const number = @backingInt(value);
        const literal = std.fmt.bufPrint(&buffer, "@fromBackingInt({d})", .{number}) catch {
            unreachable;
        };
        return write_string(writer, literal);
    }
    return write_string(writer, "(not printable)");
}

/// Whether `std.zon` serializes `T`: no type, function, error, opaque, or non-exhaustive enum.
fn zon_writes(comptime T: type) bool {
    var pending: []const type = &.{T};
    var seen: []const type = &.{};
    var steps: u32 = 0;
    outer: while (pending.len > 0) : (steps += 1) {
        if (steps > 512) return false;
        const U = pending[0];
        pending = pending[1..];
        for (seen) |known| {
            if (known == U) continue :outer;
        }
        seen = seen ++ [_]type{U};
        switch (@typeInfo(U)) {
            .int, .float, .bool, .void => {},
            .@"enum" => |e| if (e.mode == .nonexhaustive) return false,
            .array => |a| pending = pending ++ [_]type{a.child},
            .optional => |o| pending = pending ++ [_]type{o.child},
            .pointer => |p| {
                if (p.size == .many or p.size == .c) return false;
                pending = pending ++ [_]type{p.child};
            },
            .@"struct" => |s| pending = pending ++ s.field_types,
            .@"union" => |u| {
                if (u.tag_type == null) return false;
                pending = pending ++ u.field_types;
            },
            else => return false,
        }
    }
    return true;
}

/// `[{"name":..,"type":..,"default":..,"doc":..},...]` for the fields of `T`, whose
/// declaration is `container` when known.
fn write_fields(writer: *Writer, comptime T: type, container: ?Container) Writer.Error!void {
    @setEvalBranchQuota(10_000_000);
    try writer.writeByte('[');
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (
            s.field_names,
            s.field_types,
            s.field_attrs,
            0..,
        ) |name, F, attrs, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"type\":", .{name});
            try write_string(writer, comptime type_text(F));
            if (comptime attrs.defaultValue(F)) |value| {
                try writer.writeAll(",\"default\":");
                try write_value(writer, F, value);
            }
            note_field_type(container, name);
            try write_field_doc(writer, container, name);
            try writer.writeByte('}');
        },
        .@"union" => |u| inline for (u.field_names, u.field_types, 0..) |name, F, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"type\":", .{name});
            try write_string(writer, comptime type_text(F));
            try write_field_doc(writer, container, name);
            try writer.writeByte('}');
        },
        .@"enum" => |e| inline for (e.field_names, e.field_values, 0..) |name, value, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"value\":{d}", .{ name, value });
            try write_field_doc(writer, container, name);
            try writer.writeByte('}');
        },
        .error_set => |set| if (set) |names| inline for (names, 0..) |name, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\"}}", .{name});
        },
        else => {},
    }
    try writer.writeByte(']');
}

/// Records the aliases the type of the field `name` of `container` names.
fn note_field_type(container: ?Container, name: []const u8) void {
    const where = container orelse return;
    const decl = member(where, name) orelse return;
    const field = tree_of(decl.file).fullContainerField(decl.node) orelse return;
    const type_expr = field.ast.type_expr.unwrap() orelse return;
    note_field_aliases(decl.file, type_expr, where) catch return;
}

/// `,"doc":"..."` for the field `name` of `container`, when it has a `///` comment.
fn write_field_doc(writer: *Writer, container: ?Container, name: []const u8) Writer.Error!void {
    const where = container orelse return;
    const decl = member(where, name) orelse return;
    const token = doc_token(decl) orelse return;
    try writer.writeAll(",\"doc\":\"");
    try write_sentence(writer, decl.file, token);
    try writer.writeByte('"');
}

fn kind_of(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| switch (s.layout) {
            .@"extern" => "extern struct",
            .@"packed" => "packed struct",
            .auto => "struct",
        },
        .@"union" => |u| if (u.tag_type != null) "union(enum)" else "union",
        .@"enum" => |e| if (e.mode == .nonexhaustive)
            "enum(" ++ @typeName(e.tag_type) ++ "), non-exhaustive"
        else
            "enum(" ++ @typeName(e.tag_type) ++ ")",
        .error_set => "error set",
        .@"opaque" => "opaque",
        else => @typeName(T),
    };
}

fn container_result(found: Found) ?Container {
    return switch (found.result) {
        .container => |container| container,
        else => null,
    };
}

fn write_params(
    writer: *Writer,
    comptime F: type,
    comptime name: []const u8,
    cx: Cx,
    found: Found,
) Failure!void {
    @setEvalBranchQuota(10_000_000);
    const info = @typeInfo(F).@"fn";
    const function = switch (found.result) {
        .function => |function| function,
        else => {
            std.debug.print("describe: {s} does not resolve to a function\n", .{name});
            return error.Unresolved;
        },
    };
    const tree = tree_of(function.file);
    const scope = container_of(function);
    var buffer: [1]Node = undefined;
    const proto_node = tree.nodeData(function.node).node_and_node[0];
    const proto = tree.fullFnProto(&buffer, proto_node).?;
    var iterator = proto.iterate(tree);
    writer.writeAll("\"params\":[") catch return error.Capacity;
    inline for (info.param_types, 0..) |P, index| {
        const param = iterator.next() orelse return mismatch(name, "fewer parameters");
        const param_name = tree.tokenSlice(param.name_token orelse return mismatch(name, "_"));
        const is_comptime = if (param.comptime_noalias) |token|
            tree.tokenTag(token) == .keyword_comptime
        else
            false;
        const is_anytype = param.anytype_ellipsis3 != null;
        const expected = comptime expected_of(P);
        if (is_anytype and P != null) return mismatch(name, "anytype");
        if (index > 0) writer.writeByte(',') catch return error.Capacity;
        writer.print("{{\"name\":\"{s}\",\"type\":", .{param_name}) catch return error.Capacity;
        if (expected.text) |shown| {
            write_string(writer, shown) catch return error.Capacity;
            const type_expr = param.type_expr orelse return mismatch(name, param_name);
            try check_type(function.file, type_expr, scope, expected, name);
        } else if (is_anytype) {
            write_string(writer, "anytype") catch return error.Capacity;
        } else {
            // A type that depends on an earlier comptime parameter: as written.
            const type_expr = param.type_expr orelse return mismatch(name, param_name);
            write_string(writer, tree.getNodeSource(type_expr)) catch return error.Capacity;
        }
        if (is_comptime) writer.writeAll(",\"comptime\":true") catch return error.Capacity;
        const is_context = std.mem.eql(u8, param_name, "cx") or
            std.mem.eql(u8, param_name, "context");
        if (is_anytype and is_context and cx != .none) {
            // The part's header says what each context is and where an app gets it.
            const key = if (cx == .draw) "draw_context" else "ui_context";
            writer.print(",\"expects\":\"{s}\"", .{key}) catch return error.Capacity;
        }
        writer.writeByte('}') catch return error.Capacity;
    }
    if (iterator.next() != null) return mismatch(name, "more parameters");
    writer.writeAll("],\"returns\":") catch return error.Capacity;
    const R = comptime info.return_type;
    if (R) |known| {
        write_string(writer, comptime type_text(known)) catch return error.Capacity;
        const return_node = proto.ast.return_type.unwrap() orelse return mismatch(name, "void");
        const expected = comptime expected_of(known);
        if (tree.tokenTag(tree.firstToken(return_node) - 1) == .bang) {
            // An inferred error set: reflection's prefix starts with `!`.
            if (!comptime std.mem.startsWith(u8, expected.prefix, "!")) return mismatch(name, "!");
            const trimmed = comptime without_bang(expected);
            try check_type(function.file, return_node, scope, trimmed, name);
        } else {
            try check_type(function.file, return_node, scope, expected, name);
        }
    } else {
        const return_node = proto.ast.return_type.unwrap() orelse return mismatch(name, "void");
        write_string(writer, tree.getNodeSource(return_node)) catch return error.Capacity;
    }
}

// ------------------------------------------------------------------ 7a. Parts

/// One file of `docs/describe/`: an area an app author thinks in (section 5a).
const Part = enum { draw, textures, text, ui, widgets, theme, app };

/// The part each public name belongs to, by its first segments. A name no prefix takes is a
/// compile error, so a new root cannot fall out of every file.
const part_prefixes = [_]struct { prefix: []const u8, part: Part }{
    .{ .prefix = "draw.Texture", .part = .textures },
    .{ .prefix = "draw.TargetKind", .part = .textures },
    .{ .prefix = "draw.fx.", .part = .textures },
    .{ .prefix = "draw.wave.", .part = .textures },
    .{ .prefix = "commands.", .part = .textures },
    .{ .prefix = "draw.", .part = .draw },
    .{ .prefix = "text.", .part = .text },
    .{ .prefix = "ui.", .part = .ui },
    .{ .prefix = "input.", .part = .ui },
    .{ .prefix = "widgets.", .part = .widgets },
    .{ .prefix = "animator.", .part = .widgets },
    .{ .prefix = "theme.", .part = .theme },
    .{ .prefix = "app.", .part = .app },
    .{ .prefix = "bench.", .part = .app },
};

/// The module whose first `//!` sentence says what a part holds, in the index.
const part_modules = std.enums.EnumArray(Part, []const u8).init(.{
    .draw = "draw.zig",
    .textures = "draw/textures.zig",
    .text = "text.zig",
    .ui = "ui.zig",
    .widgets = "widgets.zig",
    .theme = "theme.zig",
    .app = "app.zig",
});

/// Whether a function of `part` has a `cx: anytype` that expects the context `cx`.
fn part_uses(comptime part: Part, comptime cx: Cx) bool {
    @setEvalBranchQuota(10_000_000);
    for (functions) |function| {
        if (function.cx != cx or part_of(function.name) != part) continue;
        for (@typeInfo(function.F).@"fn".param_types) |P| {
            if (P == null) return true;
        }
    }
    if (cx == .ui and part == .widgets) return widget_list.len > 0;
    return false;
}

fn part_of(comptime name: []const u8) Part {
    for (part_prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) return entry.part;
    }
    @compileError("describe: no part takes " ++ name);
}

/// What one part holds, for the index.
const Counts = struct {
    draw_types: u32 = 0,
    types: u32 = 0,
    aliases: u32 = 0,
    constants: u32 = 0,
    functions: u32 = 0,
    contract: u32 = 0,
    scenario_steps: u32 = 0,
    widgets: u32 = 0,
};

/// One array of a part: opened on its first entry, so an empty one is left out.
const Section = struct {
    writer: *Writer,
    key: []const u8,
    count: u32 = 0,

    fn item(section: *Section) Failure!void {
        const w = section.writer;
        if (section.count == 0) {
            w.print(",\n\"{s}\":[\n", .{section.key}) catch return error.Capacity;
        } else {
            w.writeAll(",\n") catch return error.Capacity;
        }
        section.count += 1;
    }

    fn end(section: *Section) Failure!u32 {
        if (section.count > 0) section.writer.writeByte(']') catch return error.Capacity;
        return section.count;
    }
};

// ------------------------------------------------------------------ 7b. One part

/// Whether the alias candidate `index`, resolved to `found`, is printed: a printed declaration's
/// source names it, and no earlier (shorter) candidate names the same declaration.
fn alias_printed(found: Found, comptime index: usize) Failure!bool {
    const decl = found.last orelse return false;
    if (!alias_was_used(decl)) return false;
    inline for (alias_candidates[0..index]) |earlier| {
        const before = try resolve_path(earlier.path.?);
        if (before.last) |other| {
            if (other.file == decl.file and other.node == decl.node) return false;
        }
    }
    return true;
}

fn write_part(writer: *Writer, comptime part: Part) Failure!Counts {
    @setEvalBranchQuota(100_000_000);
    const w = writer;
    var counts: Counts = .{};
    const header = "{{\"library\":\"patchwork\",\"part\":\"{s}\",\"zig\":\"0.17.0\"";
    w.print(header, .{@tagName(part)}) catch return error.Capacity;
    // The contexts this part's functions take, once, on the first line.
    inline for (.{ Cx.draw, Cx.ui }) |cx| {
        if (comptime part_uses(part, cx)) {
            const key = if (cx == .draw) "draw_context" else "ui_context";
            w.print(",\"{s}\":\"{s}\"", .{ key, contexts.get(cx) }) catch return error.Capacity;
        }
    }

    var section: Section = .{ .writer = w, .key = "draw_types" };
    inline for (draw_types) |entry| {
        if (comptime part_of(entry.name) != part) continue;
        try section.item();
        const T = entry.T;
        const found = try resolve_path(entry.path.?);
        w.print("{{\"name\":\"{s}\",", .{entry.name}) catch return error.Capacity;
        write_doc(w, found.doc) catch return error.Capacity;
        write_place(w, found) catch return error.Capacity;
        w.print("\"size\":{d},\"fields\":", .{@sizeOf(T)}) catch return error.Capacity;
        write_fields(w, T, container_result(found)) catch return error.Capacity;
        const texture: ?draw.TextureFormat = T.texture;
        const texture_text = if (texture) |format| "\"" ++ @tagName(format) ++ "\"" else "null";
        const points = @hasDecl(T, "reads_points") and T.reads_points;
        const animated = @hasDecl(T, "animated") and T.animated;
        const blend = if (@hasDecl(T, "blend")) @tagName(T.blend) else "alpha";
        const look = if (@hasDecl(T, "of"))
            "\"" ++ comptime type_text(@typeInfo(@TypeOf(T.of)).@"fn".param_types[2].?) ++ "\""
        else
            "null";
        const vertex = @hasDecl(T, "vertex");
        const backdrop = @hasDecl(T, "backdrop");
        w.print(
            ",\"texture\":{s},\"reads_points\":{},\"animated\":{},\"blend\":\"{s}\"," ++
                "\"vertex\":{},\"backdrop\":{},\"look\":{s}}}",
            .{ texture_text, points, animated, blend, vertex, backdrop, look },
        ) catch return error.Capacity;
    }
    counts.draw_types = try section.end();

    section = .{ .writer = w, .key = "types" };
    inline for (collected.types) |entry| {
        if (comptime part_of(entry.name) != part) continue;
        try section.item();
        const T = entry.T;
        const found: ?Found = if (entry.path) |path| try resolve_path(path) else null;
        w.print("{{\"name\":\"{s}\",", .{entry.name}) catch return error.Capacity;
        if (found) |f| {
            write_doc(w, f.doc) catch return error.Capacity;
            write_place(w, f) catch return error.Capacity;
        }
        w.print("\"kind\":\"{s}\",\"size\":", .{kind_of(T)}) catch return error.Capacity;
        if (comptime comptime_only(T) or @typeInfo(T) == .@"opaque") {
            w.writeAll("null") catch return error.Capacity;
        } else {
            w.print("{d}", .{@sizeOf(T)}) catch return error.Capacity;
        }
        const key = switch (@typeInfo(T)) {
            .@"enum" => "tags",
            .error_set => "errors",
            else => "fields",
        };
        w.print(",\"{s}\":", .{key}) catch return error.Capacity;
        const container = if (found) |f| container_result(f) else null;
        write_fields(w, T, container) catch return error.Capacity;
        w.writeByte('}') catch return error.Capacity;
    }
    counts.types = try section.end();

    section = .{ .writer = w, .key = "aliases" };
    inline for (alias_candidates, 0..) |entry, index| {
        if (comptime part_of(entry.name) != part) continue;
        const found = try resolve_path(entry.path.?);
        if (try alias_printed(found, index)) {
            try section.item();
            w.print("{{\"name\":\"{s}\",", .{entry.name}) catch return error.Capacity;
            write_doc(w, found.doc) catch return error.Capacity;
            write_place(w, found) catch return error.Capacity;
            w.writeAll("\"type\":") catch return error.Capacity;
            write_string(w, comptime type_text(entry.T)) catch return error.Capacity;
            w.writeByte('}') catch return error.Capacity;
        }
    }
    counts.aliases = try section.end();

    section = .{ .writer = w, .key = "constants" };
    inline for (constants) |constant| {
        if (comptime part_of(constant.name) != part) continue;
        try section.item();
        const found = try resolve_path(constant.name);
        w.print("{{\"name\":\"{s}\",", .{constant.name}) catch return error.Capacity;
        write_doc(w, found.doc) catch return error.Capacity;
        write_place(w, found) catch return error.Capacity;
        w.writeAll("\"type\":") catch return error.Capacity;
        write_string(w, comptime type_text(constant.T)) catch return error.Capacity;
        w.writeAll(",\"value\":") catch return error.Capacity;
        const value: *const constant.T = @ptrCast(@alignCast(constant.value));
        write_value(w, constant.T, value.*) catch return error.Capacity;
        w.writeByte('}') catch return error.Capacity;
    }
    counts.constants = try section.end();

    section = .{ .writer = w, .key = "functions" };
    inline for (functions) |function| {
        if (comptime part_of(function.name) != part) continue;
        try section.item();
        const found = try resolve_path(function.path);
        w.print("{{\"name\":\"{s}\",", .{function.name}) catch return error.Capacity;
        write_doc(w, found.doc) catch return error.Capacity;
        write_place(w, found) catch return error.Capacity;
        try write_params(w, function.F, function.name, function.cx, found);
        w.writeByte('}') catch return error.Capacity;
    }
    counts.functions = try section.end();

    if (part == .app) {
        section = .{ .writer = w, .key = "contract" };
        const table = comptime patchwork.app.declarations(App);
        inline for (table) |declaration| {
            try section.item();
            const name = declaration.name;
            w.print("{{\"name\":\"{s}\",\"type\":", .{name}) catch return error.Capacity;
            write_string(w, comptime type_text(declaration.type)) catch return error.Capacity;
            const need = @tagName(declaration.need);
            w.print(",\"need\":\"{s}\"}}", .{need}) catch return error.Capacity;
        }
        counts.contract = try section.end();

        section = .{ .writer = w, .key = "scenario_steps" };
        const steps = try resolve_path("bench.Step");
        const step_info = @typeInfo(Step).@"union";
        inline for (step_info.field_names, step_info.field_types) |name, F| {
            try section.item();
            w.print("{{\"name\":\"{s}\",\"type\":", .{name}) catch return error.Capacity;
            write_string(w, comptime type_text(F)) catch return error.Capacity;
            write_field_doc(w, container_result(steps), name) catch return error.Capacity;
            w.writeByte('}') catch return error.Capacity;
        }
        counts.scenario_steps = try section.end();
    }

    section = .{ .writer = w, .key = "widgets" };
    inline for (widget_list) |entry| {
        if (comptime part_of(entry.name) != part) continue;
        try section.item();
        const W = entry.T;
        const found = try resolve_path(entry.path.?);
        w.print("{{\"name\":\"{s}\",", .{entry.name}) catch return error.Capacity;
        write_doc(w, found.doc) catch return error.Capacity;
        write_place(w, found) catch return error.Capacity;
        if (comptime has_init(W)) {
            const init_found = try resolve_path(entry.path.? ++ ".init");
            w.writeAll("\"init\":{") catch return error.Capacity;
            try write_params(w, @TypeOf(W.init), entry.name ++ ".init", .ui, init_found);
            w.writeAll("},\"fields\":null") catch return error.Capacity;
        } else {
            w.writeAll("\"init\":null,\"fields\":") catch return error.Capacity;
            write_fields(w, W, container_result(found)) catch return error.Capacity;
        }
        w.writeAll(",\"actions\":") catch return error.Capacity;
        if (@hasDecl(W, "Action")) {
            const actions = try resolve_path(entry.path.? ++ ".Action");
            write_fields(w, W.Action, container_result(actions)) catch return error.Capacity;
        } else {
            w.writeAll("null") catch return error.Capacity;
        }
        w.writeByte('}') catch return error.Capacity;
    }
    counts.widgets = try section.end();

    w.writeAll("}\n") catch return error.Capacity;
    return counts;
}

// ------------------------------------------------------------------ 7c. All parts and the index

const part_count = @typeInfo(Part).@"enum".field_names.len;

/// Every part, then the index, each a slice of `output_bytes`.
const Output = struct {
    parts: [part_count][]const u8,
    index: []const u8,
};

var index_bytes: [64 * 1024]u8 = undefined;

fn write_all() Failure!Output {
    // A first pass over every part learns which aliases the printed declarations name, since a
    // part's aliases come before the functions of later parts.
    alias_used_count = 0;
    inline for (@typeInfo(Part).@"enum".field_names) |name| {
        unchecked = 0;
        var scratch: Writer = .fixed(&output_bytes);
        _ = try write_part(&scratch, @field(Part, name));
    }
    unchecked = 0;
    var out: Output = undefined;
    var counts: [part_count]Counts = undefined;
    var used: usize = 0;
    inline for (@typeInfo(Part).@"enum".field_names, 0..) |name, index| {
        var writer: Writer = .fixed(output_bytes[used..]);
        counts[index] = try write_part(&writer, @field(Part, name));
        out.parts[index] = writer.buffered();
        used += out.parts[index].len;
    }
    var index_writer: Writer = .fixed(&index_bytes);
    write_index(&index_writer, out.parts, counts) catch return error.Capacity;
    out.index = index_writer.buffered();
    assert(out.index.len > 0);
    return out;
}

/// `index.json`: each part's file, the first sentence of its module's guide, its bytes, and
/// its counts. What an agent reads first.
fn write_index(
    w: *Writer,
    parts: [part_count][]const u8,
    counts: [part_count]Counts,
) (Writer.Error || Failure)!void {
    try w.writeAll("{\"library\":\"patchwork\",\"zig\":\"0.17.0\"," ++
        "\"generated\":\"zig build describe\",\"files\":[\n");
    inline for (@typeInfo(Part).@"enum".field_names, 0..) |name, index| {
        if (index > 0) try w.writeAll(",\n");
        try w.print("{{\"file\":\"{s}.json\",\"doc\":\"", .{name});
        const module = try open(part_modules.get(@field(Part, name)));
        try write_module_sentence(w, module);
        try w.print("\",\"bytes\":{d}", .{parts[index].len});
        inline for (@typeInfo(Counts).@"struct".field_names) |field| {
            try w.print(",\"{s}\":{d}", .{ field, @field(counts[index], field) });
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

/// The first sentence of `file`'s `//!` module guide.
fn write_module_sentence(writer: *Writer, file: u16) Writer.Error!void {
    const tree = tree_of(file);
    assert(tree.tokenTag(0) == .container_doc_comment);
    try write_sentence(writer, file, 0);
}

// ------------------------------------------------------------------ 8. Main

/// `describe <src-dir>` prints the index and every part; `describe <src-dir> draw text` prints
/// those parts; `--write <dir>` writes them all as files; `--check <dir>` compares them.
pub fn main(init: std.process.Init.Minimal) !u8 {
    var args = init.args.iterate();
    _ = args.next();
    src_dir = args.next() orelse return usage();
    var mode: enum { print, write, check } = .print;
    var dir: [:0]const u8 = "";
    var chosen: [part_count]bool = @splat(false);
    var any_chosen = false;
    var argument_count: u32 = 0;
    while (args.next()) |argument| : (argument_count += 1) {
        if (argument_count > part_count + 2) return usage();
        if (std.mem.eql(u8, argument, "--write") or std.mem.eql(u8, argument, "--check")) {
            mode = if (argument[2] == 'w') .write else .check;
            dir = args.next() orelse return usage();
            continue;
        }
        const part = std.meta.stringToEnum(Part, argument) orelse return usage();
        chosen[@backingInt(part)] = true;
        any_chosen = true;
    }
    tree_allocator = .init(&tree_bytes);
    const output = write_all() catch |err| {
        std.debug.print("describe: {s}\n", .{@errorName(err)});
        return 1;
    };
    switch (mode) {
        .check => return check_dir(dir, output),
        .write => {
            try write_dir(dir, output);
            return 0;
        },
        .print => {
            if (!any_chosen) try write_fd(1, output.index);
            for (output.parts, chosen) |part, wanted| {
                if (wanted or !any_chosen) try write_fd(1, part);
            }
            return 0;
        },
    }
}

fn usage() u8 {
    std.debug.print(
        "usage: describe <src-dir> [draw|textures|text|ui|widgets|theme|app ...] " ++
            "[--write <dir> | --check <dir>]\n",
        .{},
    );
    return 2;
}

const regenerate = "zig build describe -- --write docs/describe";

/// Whether `name` is a file `write_dir` writes.
fn is_known(name: []const u8) bool {
    if (std.mem.eql(u8, name, "index.json")) return true;
    inline for (@typeInfo(Part).@"enum".field_names) |part| {
        if (std.mem.eql(u8, name, part ++ ".json")) return true;
    }
    return false;
}

/// Most entries `json_files` reads from a golden directory.
const entry_cap: u32 = 64;

/// The `.json` names in `dir`, into `names` (backed by `storage`); null when it cannot be read.
fn json_files(dir: []const u8, storage: *[4096]u8, names: *[entry_cap][]const u8) ?u32 {
    var path: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&path, "{s}", .{dir}, 0) catch return null;
    const opened = linux.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var buffer: [8192]u8 align(8) = undefined;
    var count: u32 = 0;
    var used: usize = 0;
    var reads: u32 = 0;
    while (reads < 64) : (reads += 1) {
        const result = linux.getdents64(fd, &buffer, buffer.len);
        if (linux.errno(result) != .SUCCESS) return null;
        if (result == 0) break;
        var offset: usize = 0;
        while (offset < result) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            const name_at = offset + @offsetOf(linux.dirent64, "name");
            const name_ptr: [*:0]const u8 = @ptrCast(&buffer[name_at]);
            const name = std.mem.span(name_ptr);
            offset += entry.reclen;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (count == entry_cap or used + name.len > storage.len) return null;
            @memcpy(storage[used..][0..name.len], name);
            names[count] = storage[used..][0..name.len];
            used += name.len;
            count += 1;
        }
    }
    return count;
}

/// Writes `index.json` and each part's file into `dir`, and removes any other `.json` file
/// there, a part that no longer exists.
fn write_dir(dir: []const u8, output: Output) !void {
    var storage: [4096]u8 = undefined;
    var names: [entry_cap][]const u8 = undefined;
    const count = json_files(dir, &storage, &names) orelse return error.OpenFailed;
    var path: [512]u8 = undefined;
    for (names[0..count]) |name| {
        if (is_known(name)) continue;
        const stale = try std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ dir, name }, 0);
        if (linux.errno(linux.unlink(stale)) != .SUCCESS) return error.UnlinkFailed;
    }
    try write_file(try std.fmt.bufPrintSentinel(&path, "{s}/index.json", .{dir}, 0), output.index);
    inline for (@typeInfo(Part).@"enum".field_names, 0..) |name, index| {
        const file = try std.fmt.bufPrintSentinel(&path, "{s}/{s}.json", .{ dir, name }, 0);
        try write_file(file, output.parts[index]);
    }
}

/// Exits 1 naming the first file and line in `dir` that differs from the code, a file the
/// index does not list, or one it lists that is missing.
fn check_dir(dir: []const u8, output: Output) !u8 {
    var storage: [4096]u8 = undefined;
    var names: [entry_cap][]const u8 = undefined;
    const count = json_files(dir, &storage, &names) orelse {
        const message = "describe: cannot list {s}; regenerate: {s}\n";
        if (!quiet) std.debug.print(message, .{ dir, regenerate });
        return 1;
    };
    for (names[0..count]) |name| {
        if (is_known(name)) continue;
        if (!quiet) {
            std.debug.print("describe: {s}/{s} is not in the index; regenerate: {s}\n", .{
                dir, name, regenerate,
            });
        }
        return 1;
    }
    var path: [512]u8 = undefined;
    // The parts first: their lines name the declaration that changed; the index only sizes.
    inline for (@typeInfo(Part).@"enum".field_names, 0..) |name, index| {
        const file = try std.fmt.bufPrintSentinel(&path, "{s}/{s}.json", .{ dir, name }, 0);
        if (!try compare(file, output.parts[index])) return 1;
    }
    const index_path = try std.fmt.bufPrintSentinel(&path, "{s}/index.json", .{dir}, 0);
    if (!try compare(index_path, output.index)) return 1;
    return 0;
}

/// Whether `path` holds `output`; prints the first line that differs when not.
fn compare(path: [:0]const u8, output: []const u8) !bool {
    const before = source_used;
    defer source_used = before;
    const golden = read(path) catch {
        const message = "describe: {s} is missing; regenerate: {s}\n";
        if (!quiet) std.debug.print(message, .{ path, regenerate });
        return false;
    };
    if (std.mem.eql(u8, golden, output)) return true;
    var line: u32 = 1;
    var golden_lines = std.mem.splitScalar(u8, golden, '\n');
    var output_lines = std.mem.splitScalar(u8, output, '\n');
    while (line < 1 << 20) : (line += 1) {
        const a = golden_lines.next();
        const b = output_lines.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        if (quiet) break;
        std.debug.print(
            "describe: {s} differs from the code at line {d}:\n  golden: {s}\n  code:   {s}\n" ++
                "Regenerate: {s}\n",
            .{ path, line, a orelse "(end)", b orelse "(end)", regenerate },
        );
        break;
    }
    return false;
}

/// Creates or truncates `path` and writes `bytes` to it.
fn write_file(path: [:0]const u8, bytes: []const u8) !void {
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("describe: cannot create {s}\n", .{path});
        return error.CreateFailed;
    }
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    try write_fd(fd, bytes);
}

fn write_fd(fd: i32, bytes: []const u8) !void {
    var written: usize = 0;
    var steps: u32 = 0;
    while (written < bytes.len) : (steps += 1) {
        assert(steps < 1 << 20);
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        written += result;
    }
    assert(written == bytes.len);
}

// ------------------------------------------------------------------ 9. Tests

const testing = std.testing;

/// Points the tool at this repository's `src`, once; the tests run from the build root.
fn test_setup() void {
    if (src_dir.len > 0) return;
    src_dir = "src";
    tree_allocator = .init(&tree_bytes);
}

// Locks that the list of namespaces is checked at comptime (a missing one is a compile error,
// `check_namespace`) and holds the 22 namespaces, with `draw.path` expecting the draw context.
test "every namespace in the list exists" {
    comptime assert(namespaces.len == 22);
    comptime check_namespace(namespaces[0]);
    try testing.expectEqual(Cx.draw, namespaces[7].cx);
    try testing.expectEqualStrings("draw.path", namespaces[7].path);
}

// Locks the cross-check: writing everything finds every printed function's declaration, and
// its parameter count and types agree with reflection's, with at most `unchecked_max` types
// unfollowed (a parameter's own type such as `Draw`, the generated `text.Face`).
test "the parser's parameters agree with reflection for every printed function" {
    test_setup();
    const output = try write_all();
    try testing.expect(unchecked <= unchecked_max);
    for (output.parts) |part| try testing.expect(part.len > 1000);
}

// Locks that the check fails a wrong type: `polyline`'s `clip: Clip` checked as a `draw.Rect`
// is a mismatch, and as a `draw.Clip` passes.
test "a parameter of the wrong type fails the cross-check" {
    test_setup();
    const found = try resolve_path("draw.path.polyline");
    const function = found.result.function;
    const tree = tree_of(function.file);
    var buffer: [1]Node = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function.node).node_and_node[0]).?;
    var iterator = proto.iterate(tree);
    var clip: ?Ast.full.FnProto.Param = null;
    while (iterator.next()) |param| clip = param;
    const node = clip.?.type_expr.?;
    const scope = container_of(function);
    try check_type(function.file, node, scope, comptime expected_of(draw.Clip), "test");
    quiet = true;
    defer quiet = false;
    const wrong = check_type(function.file, node, scope, comptime expected_of(draw.Rect), "test");
    try testing.expectError(error.Mismatch, wrong);
}

// Locks the resolver on an alias chain: `text.place` is declared in `text.zig` as an alias and
// defined in `text/layout.zig`, whose line is printed, with the alias's sentence.
test "an alias resolves to its definition and keeps its own sentence" {
    test_setup();
    const found = try resolve_path("text.place");
    try testing.expect(found.result == .function);
    try testing.expectEqualStrings("text/layout.zig", files[found.last.?.file].name());
    try testing.expectEqualStrings("text.zig", files[found.doc.?.file].name());
}

var second_bytes: [output_cap]u8 = undefined;

// Locks the fixed layout: two runs give the same bytes, part by part and in the index, and a
// part is one declaration a line.
test "two runs give the same bytes" {
    test_setup();
    const first = try write_all();
    var used: usize = 0;
    var copies: [part_count][]const u8 = undefined;
    for (first.parts, &copies) |part, *copy| {
        @memcpy(second_bytes[used..][0..part.len], part);
        copy.* = second_bytes[used..][0..part.len];
        used += part.len;
    }
    const second = try write_all();
    for (copies, second.parts) |a, b| try testing.expectEqualSlices(u8, a, b);
    try testing.expect(std.mem.count(u8, second.parts[0], "\n") > 50);
    try testing.expect(std.mem.startsWith(u8, second.index, "{\"library\":\"patchwork\""));
}

// Locks the split: every printed name falls in one part, by prefix: `draw.path.polyline` in
// draw, `text.ttf.glyph_id` in text, `input.Event` in ui, `bench.Step` in app.
test "each public name belongs to one part" {
    comptime assert(part_of("draw.path.polyline") == .draw);
    comptime assert(part_of("draw.Context(...).layer") == .draw);
    comptime assert(part_of("text.ttf.glyph_id") == .text);
    comptime assert(part_of("input.Event") == .ui);
    comptime assert(part_of("bench.Step") == .app);
    comptime assert(part_of("draw.Textures.create") == .textures);
    try testing.expectEqual(7, part_count);
}

// Locks the golden directory's rules: a `.json` file the index does not list fails the check, a
// listed file that is missing fails it, `--write` removes the stray file and restores the missing
// one, and the check then passes.
test "a stray or a missing golden file fails the check" {
    test_setup();
    const dir = ".zig-cache/describe-test";
    _ = linux.mkdir(".zig-cache", 0o755);
    _ = linux.mkdir(dir, 0o755);
    const output = try write_all();
    try write_dir(dir, output);
    try testing.expectEqual(@as(u8, 0), try check_dir(dir, output));
    quiet = true;
    defer quiet = false;
    try write_file(dir ++ "/old.json", "{}\n");
    try testing.expectEqual(@as(u8, 1), try check_dir(dir, output));
    try write_dir(dir, output);
    try testing.expectEqual(@as(u8, 0), try check_dir(dir, output));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlink(dir ++ "/text.json")));
    try testing.expectEqual(@as(u8, 1), try check_dir(dir, output));
    try write_dir(dir, output);
    try testing.expectEqual(@as(u8, 0), try check_dir(dir, output));
}

// Locks the aliases: `draw.Point` is printed in the draw part as `[2]f32`, since `polyline` and
// the fill builder write it, and the part's first line says what its `cx` is.
test "an alias a signature writes is printed" {
    test_setup();
    const output = try write_all();
    const draw_part = output.parts[@backingInt(Part.draw)];
    const line = "{\"name\":\"draw.Point\",";
    try testing.expect(std.mem.indexOf(u8, draw_part, line) != null);
    try testing.expect(std.mem.indexOf(u8, draw_part, "\"type\":\"[2]f32\"}") != null);
    const first = draw_part[0..std.mem.indexOfScalar(u8, draw_part, '\n').?];
    try testing.expect(std.mem.indexOf(u8, first, "cx.drawing()") != null);
}

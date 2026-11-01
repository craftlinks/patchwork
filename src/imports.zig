//! The rules for the packages an app or a tool imports beside Patchwork.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Here
//! `build.zig` checks a consumer's lists at configure time, and a build script has no tests of its
//! own. So the rules are one pure function in the library's tree, generic over the list's element
//! so it never names `std.Build`: `build.zig` imports this file as it imports
//! `src/text/subset.zig`, and `zig build test` locks it through `src/root.zig`.
//!
//! ## 2. The Rules
//! An app has three lists: `imports` for both targets, and `native_imports` and `wasm_imports` for
//! one each. A module that links a system library needs a known target, so such a peer is built
//! once per target and appears in the two per-target lists under one name.
//! - A reserved name is refused: the name a host gives a module of its own.
//! - A name twice for one target is refused. `imports` counts for both targets, so a name in
//!   `imports` and in a per-target list is a duplicate.
//! - A name in only one per-target list is refused. `@import("thrum")` is in an app file that
//!   compiles for both targets, so it must resolve on both; a native-only branch belongs in the
//!   peer.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: the check reads the caller's lists.
//! - Bounded loops: every loop walks a list, so the worst case is the square of their total.

const std = @import("std");
const assert = std.debug.assert;

/// Which list an entry is in.
pub const List = enum { imports, native_imports, wasm_imports };

pub const Problem = enum { reserved, duplicate, one_target };

/// The first entry that breaks a rule.
pub const Found = struct {
    list: List,
    index: u32,
    name: []const u8,
    problem: Problem,
};

/// The first entry of the lists that breaks a rule, or null. `Import` is any type with a
/// `name: []const u8` field.
pub fn check(
    comptime Import: type,
    reserved: []const []const u8,
    shared: []const Import,
    native: []const Import,
    wasm: []const Import,
) ?Found {
    const lists = [_][]const Import{ shared, native, wasm };
    for (lists, [_]List{ .imports, .native_imports, .wasm_imports }) |entries, list| {
        for (entries, 0..) |entry, index| {
            const found: Found = .{
                .list = list,
                .index = @intCast(index),
                .name = entry.name,
                .problem = problem_of(Import, reserved, entry.name, list, lists) orelse continue,
            };
            assert(found.index < entries.len);
            return found;
        }
    }
    return null;
}

/// What is wrong with one entry of `list`, or null.
fn problem_of(
    comptime Import: type,
    reserved: []const []const u8,
    name: []const u8,
    list: List,
    lists: [3][]const Import,
) ?Problem {
    for (reserved) |taken| {
        if (std.mem.eql(u8, name, taken)) return .reserved;
    }
    const shared = count(Import, lists[0], name);
    const native = count(Import, lists[1], name);
    const wasm = count(Import, lists[2], name);
    assert(shared + native + wasm >= 1);
    if (shared + native > 1 or shared + wasm > 1) return .duplicate;
    if (list != .imports and (native == 0 or wasm == 0)) return .one_target;
    return null;
}

fn count(comptime Import: type, entries: []const Import, name: []const u8) usize {
    var found: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) found += 1;
    }
    assert(found <= entries.len);
    return found;
}

/// The message `build.zig` panics with for a problem.
pub fn problem_text(problem: Problem) []const u8 {
    return switch (problem) {
        .reserved => "this name is the host's own",
        .duplicate => "this name appears twice for one target",
        .one_target => "this name must be in both native_imports and wasm_imports",
    };
}

const testing = std.testing;
const Entry = struct { name: []const u8 };

fn found_in(
    shared: []const Entry,
    native: []const Entry,
    wasm: []const Entry,
) ?Found {
    return check(Entry, &.{"patchwork"}, shared, native, wasm);
}

// Locks the shapes a consumer writes: no imports, a pure peer in `imports`, and a linked peer
// under one name in both per-target lists.
test "a shared peer and a peer per target pass" {
    try testing.expect(found_in(&.{}, &.{}, &.{}) == null);
    try testing.expect(found_in(&.{.{ .name = "weft" }}, &.{}, &.{}) == null);
    const thrum: []const Entry = &.{.{ .name = "thrum" }};
    try testing.expect(found_in(&.{.{ .name = "weft" }}, thrum, thrum) == null);
}

// Locks the reserved name in every list, with the entry's position: `patchwork` at index 1 of
// `imports`, and at index 0 of each per-target list before the rule that it is in only one.
test "a reserved name is refused in every list" {
    const shared = found_in(&.{ .{ .name = "weft" }, .{ .name = "patchwork" } }, &.{}, &.{}).?;
    try testing.expectEqual(Problem.reserved, shared.problem);
    try testing.expectEqual(List.imports, shared.list);
    try testing.expectEqual(@as(u32, 1), shared.index);
    const native = found_in(&.{}, &.{.{ .name = "patchwork" }}, &.{}).?;
    try testing.expectEqual(Problem.reserved, native.problem);
    try testing.expectEqual(List.native_imports, native.list);
    const wasm = found_in(&.{}, &.{}, &.{.{ .name = "patchwork" }}).?;
    try testing.expectEqual(Problem.reserved, wasm.problem);
    try testing.expectEqual(List.wasm_imports, wasm.list);
}

// Locks a name twice for one target: twice in one list, and once in `imports` and once in a
// per-target list, which holds for either target and with the name in both.
test "a name twice for one target is refused" {
    const twice: []const Entry = &.{ .{ .name = "weft" }, .{ .name = "weft" } };
    try testing.expectEqual(Problem.duplicate, found_in(twice, &.{}, &.{}).?.problem);
    const once: []const Entry = &.{.{ .name = "weft" }};
    try testing.expectEqual(Problem.duplicate, found_in(once, once, &.{}).?.problem);
    try testing.expectEqual(Problem.duplicate, found_in(once, &.{}, once).?.problem);
    try testing.expectEqual(Problem.duplicate, found_in(once, once, once).?.problem);
    try testing.expectEqual(Problem.duplicate, found_in(&.{}, twice, once).?.problem);
    try testing.expectEqualStrings("weft", found_in(&.{}, twice, once).?.name);
}

// Locks the rule that keeps `@import` resolving on both targets: a name in one per-target list
// is refused from either side, and the second peer's entry is the one named.
test "a name in only one per-target list is refused" {
    const both: Entry = .{ .name = "thrum" };
    const native = found_in(&.{}, &.{ both, .{ .name = "alsa" } }, &.{both}).?;
    try testing.expectEqual(Problem.one_target, native.problem);
    try testing.expectEqual(List.native_imports, native.list);
    try testing.expectEqual(@as(u32, 1), native.index);
    try testing.expectEqualStrings("alsa", native.name);
    const wasm = found_in(&.{}, &.{}, &.{.{ .name = "web" }}).?;
    try testing.expectEqual(Problem.one_target, wasm.problem);
    try testing.expectEqual(List.wasm_imports, wasm.list);
}

// Locks the tool's use: its one list with two reserved names, and that `app` is free for an app,
// whose module has no import of that name.
test "a tool reserves app as well" {
    const reserved: []const []const u8 = &.{ "patchwork", "app" };
    const list: []const Entry = &.{.{ .name = "app" }};
    const found = check(Entry, reserved, list, &.{}, &.{}).?;
    try testing.expectEqual(Problem.reserved, found.problem);
    try testing.expect(found_in(list, &.{}, &.{}) == null);
}

// Locks that every problem has a message.
test "every problem has a message" {
    for (std.enums.values(Problem)) |problem| {
        try testing.expect(problem_text(problem).len > 0);
    }
}

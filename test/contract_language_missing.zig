//! Negative build test for the language contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_language_missing.Bare: missing `pub fn next(line: []const u8, at: *u32, state:
//! *State) ?editor.Token(Class)`" (the `expect_errors` string in `build.zig`): a language
//! without `next` fails at build time, naming the language and the function
//! (`src/editor/language.zig`, section 3).

const patchwork = @import("patchwork");

/// A language with states, classes, and colours, but no tokenizer.
const Bare = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { word };
    pub const palette: [1][4]f32 = .{.{ 1, 1, 1, 1 }};
};

/// An editor of a language that cannot tokenize.
const BareEditor = patchwork.editor.EditorOf(Bare);

comptime {
    _ = BareEditor;
}

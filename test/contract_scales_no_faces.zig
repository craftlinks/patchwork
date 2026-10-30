//! Negative build test for the language contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_scales_no_faces.Mono: `scales` needs `faces`" (the `expect_errors` string in
//! `build.zig`): line sizes are built on a language's faces, so the mono grid never meets them
//! (`src/editor/language.zig`, section 3).

const patchwork = @import("patchwork");
const editor = patchwork.editor;

/// A mono language that asks for a second size.
const Mono = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a };
    pub const palette: [1][4]f32 = .{.{ 1, 1, 1, 1 }};
    pub const scales: [2]f32 = .{ 1, 2 };

    pub fn level_of(line: []const u8) u8 {
        _ = line;
        return 0;
    }

    pub fn next(line: []const u8, at: *u32, state: *State) ?editor.Token(Class) {
        _ = line;
        _ = at;
        _ = state;
        return null;
    }
};

comptime {
    _ = editor.EditorOf(Mono);
}

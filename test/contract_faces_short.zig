//! Negative build test for the language contract. This file must NOT compile.
//!
//! `zig build test-contract` compiles it and passes only when the compiler reports
//! "contract_faces_short.Short: `faces` must be [2]text.Face, one face per Class" (the
//! `expect_errors` string in `build.zig`): a proportional language names one face per class, so
//! a class never lacks one (`src/editor/language.zig`, section 3).

const patchwork = @import("patchwork");
const editor = patchwork.editor;

/// Two classes and one face.
const Short = struct {
    pub const State = enum(u8) { normal };
    pub const Class = enum(u8) { a, b };
    pub const palette: [2][4]f32 = .{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } };
    pub const faces: [1]patchwork.text.Face = .{.sans};

    pub fn next(line: []const u8, at: *u32, state: *State) ?editor.Token(Class) {
        _ = line;
        _ = at;
        _ = state;
        return null;
    }
};

comptime {
    _ = editor.EditorOf(Short);
}

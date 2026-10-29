//! The session's serif faces: the codepoints they keep.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Ranges
//! `build.zig` imports this file and passes `ranges` for the three Noto Serif faces
//! (`AppOptions.fonts`): Basic Latin and Latin-1, Greek (the patch's `α` and `φ`), the
//! dashes and the ellipsis, the minus sign, and `ꝏ` (U+A74F), the patch's stereo type. The
//! files in `fonts/` are already cut to these ranges, so the build's subset is a copy. This
//! file depends on nothing but `std`, because the build runner compiles it too.

pub const ranges = [_][2]u21{
    .{ 0x0020, 0x007E }, .{ 0x00A0, 0x00FF }, .{ 0x0391, 0x03C9 },
    .{ 0x2010, 0x2027 }, .{ 0x2212, 0x2212 }, .{ 0xA74F, 0xA74F },
};

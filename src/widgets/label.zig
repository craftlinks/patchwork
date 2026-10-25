//! `Label`: text centered in its box.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Contract
//! A label carries its own style and points at app-owned bytes (usually a literal) of at most
//! `text.byte_cap`. It is passive: it records no area. Empty text appends nothing.

const std = @import("std");
const assert = std.debug.assert;
const text = @import("../text.zig");
const kit = @import("kit.zig");

const Walk = kit.Walk;

/// Text centered in its box, in `style`. See the module guide.
pub const Label = struct {
    text: []const u8,
    style: text.Style,

    pub fn draw(self: *const Label, cx: anytype, walk: Walk) void {
        assert(self.text.len <= text.byte_cap);
        assert(self.style.color[3] >= 0);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        kit.label(cx, self.style, self.text, rect, clip, kit.centered);
    }
};

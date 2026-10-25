//! `Panel`: a rounded face behind other content.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Contract
//! A panel is passive: it records no area. `begin` draws the face and opens a container over
//! it, so the face is appended before the children and draws under them; `draw` is the face
//! alone, as a leaf.

const std = @import("std");
const assert = std.debug.assert;
const ui = @import("../ui.zig");
const kit = @import("kit.zig");

const Rect = kit.Rect;
const Walk = kit.Walk;

/// A rounded face behind other content. Passive: it records no area.
pub const Panel = struct {
    paint: kit.Paint,

    /// Draws the face over the box `walk` gets, under the enclosing clip, then opens a
    /// container laid out by `layout` over it. The caller closes it with `cx.end()`. The
    /// face is appended before the container opens, so aligning the children leaves it in
    /// place; a fit panel has no box yet and draws no face.
    pub fn begin(self: *const Panel, cx: anytype, walk: Walk, layout: ui.Layout) Rect {
        assert(self.paint.radius >= 0);
        const rect = cx.peek(walk);
        if (cx.visible(rect)) |clip| kit.face(cx, rect, clip, self.paint.look(0, 0));
        const opened = cx.begin(walk, layout);
        assert(opened.x == rect.x);
        assert(opened.y == rect.y);
        return opened;
    }

    /// Draws the face alone, as a leaf.
    pub fn draw(self: *const Panel, cx: anytype, walk: Walk) void {
        assert(self.paint.radius >= 0);
        const rect = cx.walk(walk);
        const clip = cx.visible(rect) orelse return;
        kit.face(cx, rect, clip, self.paint.look(0, 0));
    }
};

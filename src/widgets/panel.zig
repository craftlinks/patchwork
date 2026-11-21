//! `Panel`: a rounded face behind other content.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Contract
//! A panel is passive: it records no area. `begin` draws the face and opens a container over
//! it, so the face is appended before the children and draws under them; `draw` is the face
//! alone, as a leaf. The skin draws the face (`widgets/skin.zig`); `Panel` is
//! `PanelOf(skins.Default)`. Its `material` (or the scheme's) decides between a solid face and
//! glass over the backdrop under its layer (`theme.zig`, section 7).
//!
//! ## 2. Counts
//! `PanelOf(S).appends` is what one panel appends to a frame at most, for `begin` and for
//! `draw` alike (`widgets/appends.zig`): the skin's `panel_appends`, with no text and no area.
//! The children are the app's.

const std = @import("std");
const assert = std.debug.assert;
const ui = @import("../ui.zig");
const kit = @import("kit.zig");
const skin = @import("skin.zig");
const Appends = @import("appends.zig").Appends;

const Rect = kit.Rect;
const Walk = kit.Walk;

/// The default panel: `PanelOf(skins.Default)`, a rounded face.
pub const Panel = PanelOf(skin.Default);

/// A face behind other content, drawn by `Skin` (`widgets/skin.zig`). Passive: it records no
/// area.
pub fn PanelOf(comptime Skin: type) type {
    if (comptime skin.check(Skin, .panel)) |problem| @compileError(problem);
    return struct {
        const Self = @This();

        paint: kit.Paint,
        /// The panel's material; null takes the scheme's (`theme.zig`, section 7).
        material: ?kit.Material = null,

        /// What one panel appends to a frame at most (section 2).
        pub const appends: Appends = Skin.panel_appends.with(0);

        /// Draws the face over the box `walk` gets, under the enclosing clip, then opens a
        /// container laid out by `layout` over it. The caller closes it with `cx.end()`. The
        /// face is appended before the container opens, so aligning the children leaves it in
        /// place; a fit panel has no box yet and draws no face.
        pub fn begin(self: *const Self, cx: anytype, walk: Walk, layout: ui.Layout) Rect {
            assert(self.paint.radius >= 0);
            const rect = cx.peek(walk);
            if (cx.visible(rect)) |clip| {
                Skin.panel(cx, self.look(cx, rect, clip));
            }
            const opened = cx.begin(walk, layout);
            assert(opened.x == rect.x);
            assert(opened.y == rect.y);
            return opened;
        }

        /// The look the skin gets: the paint, and the panel's material or the scheme's.
        fn look(self: *const Self, cx: anytype, rect: Rect, clip: kit.Clip) skin.PanelLook {
            const material = self.material orelse cx.theme().material;
            return .{ .rect = rect, .clip = clip, .paint = self.paint, .material = material };
        }

        /// Draws the face alone, as a leaf.
        pub fn draw(self: *const Self, cx: anytype, walk: Walk) void {
            assert(self.paint.radius >= 0);
            const rect = cx.walk(walk);
            const clip = cx.visible(rect) orelse return;
            Skin.panel(cx, self.look(cx, rect, clip));
        }
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");
const draw = @import("../draw.zig");

/// One frame of `panel` on layer 2 at (100, 100), with a backdrop marked there when `marked`.
fn panel_frame(cx: *fixture.Context, panel: *const Panel, marked: bool) void {
    cx.begin_frame(1280, 720, 120);
    if (marked) _ = kit.backdrop(cx, @fromBackingInt(2), kit.Material.frosted);
    _ = cx.drawing().layer(@fromBackingInt(2));
    panel.draw(cx, fixture.at(100, 100, 200, 120));
    _ = cx.drawing().layer(.base);
    _ = cx.end_frame();
}

// Locks the material (theme.zig, section 7): the scheme's solid material draws a box; a frosted
// panel with no backdrop under it draws the same box, not nothing; with one marked on its layer
// it draws one `draw.Glass` sampling that backdrop, tinted with the panel colour at the
// material's 0.45, and no box.
test "a panel is glass over a backdrop and solid without one" {
    const cx = fixture.context();
    var panel: Panel = .{ .paint = kit.paint_of(.{ 0.2, 0.2, 0.2, 1 }, 12) };
    panel_frame(cx, &panel, false);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
    panel.material = .frosted;
    panel_frame(cx, &panel, false);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(draw.Glass).len);
    panel_frame(cx, &panel, true);
    try testing.expectEqual(@as(usize, 0), cx.draw.items(draw.Box).len);
    const glass = cx.draw.items(draw.Glass);
    try testing.expectEqual(@as(usize, 1), glass.len);
    try testing.expectEqual(@as(f32, 0.45), glass[0].tint[3]);
    try testing.expectEqual(cx.theme().colors.panel[0], glass[0].tint[0]);
    try testing.expectEqual(@as(f32, 12), glass[0].look[0]);
    try testing.expect(cx.draw.textures.is_backdrop(cx.draw.backdrop_list()[0].id));
}

comptime {
    // The default skin's panel (section 2): a Box when solid, a Glass over a backdrop.
    assert(Panel.appends.of(draw.Box) == 1);
    assert(Panel.appends.of(draw.Glass) == 1);
    assert(Panel.appends.of(draw.Glyph) == 0);
    assert(Panel.appends.areas == 0);
}

// Locks `Panel.appends` (section 2) with the default skin: solid it draws Box 1, frosted over
// a marked backdrop Glass 1, no text, no area, and no overflow; `begin` draws the same face.
test "Panel appends at most appends and reaches it" {
    const cx = fixture.context();
    var tally: fixture.Tally(Panel.appends) = .{};
    var panel: Panel = .{ .paint = kit.paint_of(.{ 0.2, 0.2, 0.2, 1 }, 12), .material = .solid };
    panel_frame(cx, &panel, false);
    try tally.observe(cx);
    panel.material = .frosted;
    panel_frame(cx, &panel, true);
    try tally.observe(cx);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Glass).len);
    try tally.expect_reached();
    var opened: fixture.Tally(Panel.appends) = .{};
    cx.begin_frame(1280, 720, 120);
    _ = panel.begin(cx, fixture.at(100, 100, 200, 120), .{ .flow = .down });
    _ = cx.end();
    _ = cx.end_frame();
    try opened.observe(cx);
    try testing.expectEqual(@as(usize, 1), cx.draw.items(draw.Box).len);
}

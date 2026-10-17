//! Scroll column example: one `Scroll` of knobs, a meter, and toggles docked on the right.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Demonstrates
//! The scene holds a single widget, a fixed-width `Scroll` parked on the right edge of a
//! padded full-window column, and requests no host timer. It exists to lock the scroll, wheel,
//! toggle, and hover behavior that the rack example does not exercise. Every worked number
//! lives in this file's tests, for example "demo layout at 1280 by 720".
//!
//! ## 2. Coordinate Space and Layout
//! All measurements are UI logical pixels, top-left origin, `+Y` down. The scroll's walk is
//! `width = fixed`, `height = fill`, `align_x = 1`, so `turtle.place_column` parks it against
//! the right padding and stretches it to the padded height. `Scroll.layout_children` then
//! places the controls and clamps the scroll offset.
//!
//! ## 3. Contract With the Library
//! `App` implements the contract in `patchwork.app`. Because `config.timer_period_ms` is 0 the
//! host never calls `timer`, so a resting pointer causes no wakeups; `timer` exists only to
//! satisfy the contract and always returns false.
//!
//! ## 4. TigerStyle Invariants
//! - One fixed widget slot and no allocation.
//! - Every loop is bounded by `Scroll.child_count`, which is at most `widgets.scroll_child_cap`.
//!   The comptime block asserts that a full scroll fits the instance and glyph caps.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const animator = patchwork.animator;
const font = patchwork.font;
const quads = patchwork.draw;
const input = patchwork.input;
const turtle = patchwork.turtle;
const ui = patchwork.ui;
const widgets = patchwork.widgets;

/// Widgets in the column scene. The scroll owns its children.
pub const widget_cap: u32 = 1;

pub const slot_scroll: u32 = 0;

const id_scroll: u32 = 1;

const column_padding: turtle.Inset = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 };
const scroll_padding: turtle.Inset = .{ .left = 8, .top = 8, .right = 8, .bottom = 8 };
const row_margin: turtle.Inset = .{ .left = 0, .top = 8, .right = 0, .bottom = 0 };
const zero_margin: turtle.Inset = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
const empty_rect: turtle.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

const knob_specs = [_]struct { name: []const u8, value: f32 }{
    .{ .name = "gain", .value = 0.25 },
    .{ .name = "slope", .value = 0.50 },
    .{ .name = "twice", .value = 0.75 },
    .{ .name = "skew", .value = 0 },
    .{ .name = "echo", .value = 1 },
    .{ .name = "room", .value = 0.50 },
    .{ .name = "out", .value = 0.50 },
    .{ .name = "drive", .value = 0.50 },
};

/// The one widget kind in this app.
pub const Widget = union(enum) {
    scroll: widgets.Scroll,
};

const Scene = ui.Scene(Widget, widget_cap);

/// The column app. `timer_period_ms` is 0: nothing wakes the host while the pointer rests.
pub const App = struct {
    scene: Scene,

    pub const config: patchwork.app.Config = .{
        .title = "patchwork column",
        .timer_period_ms = 0,
    };

    pub fn init(app: *App) void {
        app.scene = Scene.init(widget_cap);
        app.scene.widgets[slot_scroll] = .{ .scroll = demo_scroll() };
        assert(app.scene.count == widget_cap);
        assert(!app.scene.pointer.inside);
    }

    /// Places the scroll against the right edge of a padded full-window column.
    pub fn layout(app: *App, width_logical: u32, height_logical: u32) void {
        assert(width_logical != 0);
        assert(height_logical != 0);
        const scroll = &app.scene.widgets[slot_scroll].scroll;
        assert(scroll.walk.align_x == 1);
        var walks = [_]turtle.Walk{scroll.walk};
        var rects: [1]turtle.Rect = undefined;
        const column: turtle.Column = .{
            .rect = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width_logical),
                .height = @floatFromInt(height_logical),
            },
            .padding = column_padding,
        };
        turtle.place_column(column, &walks, &rects);
        scroll.rect = rects[0];
        scroll.layout_children();
        app.scene.finish_layout(width_logical, height_logical);
        assert(app.scene.dirty);
    }

    pub fn event(app: *App, event_value: input.Event) bool {
        assert(app.scene.count == widget_cap);
        return app.scene.handle_event(event_value);
    }

    /// No timer is armed, so this is never called by a host. It satisfies the contract.
    pub fn timer(app: *App, now_ms: u64) bool {
        assert(app.scene.count == widget_cap);
        assert(now_ms == now_ms);
        return false;
    }

    pub fn live(app: *const App) bool {
        assert(app.scene.count == widget_cap);
        return app.scene.live();
    }

    pub fn dirty(app: *const App) bool {
        assert(app.scene.count == widget_cap);
        return app.scene.dirty;
    }

    /// Clears both lists and draws the scroll. The window clip is the full frame.
    pub fn draw(app: *App, list: *quads.DrawList, glyphs: *font.GlyphList) void {
        assert(app.scene.width_logical != 0);
        assert(app.scene.height_logical != 0);
        list.clear();
        glyphs.clear();
        const clip: font.Clip = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = @floatFromInt(app.scene.width_logical),
            .y1 = @floatFromInt(app.scene.height_logical),
        };
        app.scene.widgets[slot_scroll].scroll.draw(list, glyphs, clip);
        app.scene.finish_draw();
        assert(list.count <= quads.instance_cap);
        assert(glyphs.count <= font.glyph_cap);
    }
};

fn demo_scroll() widgets.Scroll {
    var scroll: widgets.Scroll = .{
        .id = id_scroll,
        .rect = empty_rect,
        .walk = .{
            .margin = zero_margin,
            .width = .{ .fixed = 320 },
            .height = .fill,
            .align_x = 1,
        },
        .padding = scroll_padding,
        .children = undefined,
        .child_count = 11,
        .scroll_y = 0,
        .content_h = 0,
        .press = .none,
        .hot = null,
    };
    var index: u32 = 0;
    while (index < knob_specs.len) : (index += 1) {
        scroll.children[index] = .{ .knob = demo_knob(index) };
    }
    scroll.children[8] = .{ .meter = demo_meter() };
    scroll.children[9] = .{ .toggle = demo_toggle(11, "take", true) };
    scroll.children[10] = .{ .toggle = demo_toggle(12, "drums", false) };
    assert(scroll.child_count == 11);
    assert(scroll.children[0].knob.value == 0.25);
    return scroll;
}

fn demo_knob(index: u32) widgets.Knob {
    assert(index < knob_specs.len);
    const spec = knob_specs[index];
    var knob: widgets.Knob = .{
        .id = index + 2,
        .rect = empty_rect,
        .walk = row_walk(widgets.knob_height),
        .name = spec.name,
        .value_text = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .value = spec.value,
        .accent = widgets.accents[index % widgets.accent_count],
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .drag_y = 0,
    };
    knob.set_value(spec.value);
    assert(knob.name.len <= 8);
    assert(knob.value == spec.value);
    return knob;
}

fn demo_meter() widgets.Meter {
    const meter: widgets.Meter = .{
        .id = 10,
        .rect = empty_rect,
        .walk = row_walk(widgets.meter_height),
        .name = "meter",
        .value = 0.50,
    };
    assert(meter.value == 0.50);
    assert(meter.walk.height.fixed == widgets.meter_height);
    return meter;
}

fn demo_toggle(id: u32, name: []const u8, on: bool) widgets.Toggle {
    assert(name.len <= 8);
    const toggle: widgets.Toggle = .{
        .id = id,
        .rect = empty_rect,
        .walk = row_walk(widgets.toggle_height),
        .name = name,
        .on = on,
        .hover = animator.Animator.init(widgets.hover_rate_per_ms),
        .thumb = widgets.settled(widgets.hover_rate_per_ms, on),
    };
    assert(toggle.on == on);
    assert(!toggle.thumb.live());
    return toggle;
}

fn row_walk(height: f32) turtle.Walk {
    assert(height > 0);
    const walk: turtle.Walk = .{
        .margin = row_margin,
        .width = .fill,
        .height = .{ .fixed = height },
        .align_x = 0,
    };
    assert(walk.margin.top == 8);
    assert(walk.height.fixed == height);
    return walk;
}

comptime {
    assert(widget_cap == 1);
    assert(1 + 1 + widgets.scroll_child_cap * 2 <= quads.instance_cap);
    assert(widgets.scroll_child_cap * 12 <= font.glyph_cap);
    assert(widget_cap <= turtle.child_cap);
    assert(column_padding.left == 16);
    assert(scroll_padding.left == 8);
    assert(knob_specs.len == 8);
}

fn new_app() App {
    var app: App = undefined;
    App.init(&app);
    return app;
}

fn scroll_of(app: *App) *widgets.Scroll {
    assert(app.scene.count == widget_cap);
    return &app.scene.widgets[slot_scroll].scroll;
}

fn expect_rect(rect: turtle.Rect, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, rect.x);
    try std.testing.expectEqual(y, rect.y);
    try std.testing.expectEqual(width, rect.width);
    try std.testing.expectEqual(height, rect.height);
}

fn expect_box(instance: quads.Instance, x: f32, y: f32, width: f32, height: f32) !void {
    try std.testing.expectEqual(x, instance.x);
    try std.testing.expectEqual(y, instance.y);
    try std.testing.expectEqual(width, instance.width);
    try std.testing.expectEqual(height, instance.height);
}

const view_clip: font.Clip = .{ .x0 = 952, .y0 = 24, .x1 = 1256, .y1 = 696 };

fn glyph_has_clip(glyph: font.Glyph, clip: font.Clip) bool {
    if (glyph.clip_x0 != clip.x0) {
        return false;
    }
    if (glyph.clip_y0 != clip.y0) {
        return false;
    }
    if (glyph.clip_x1 != clip.x1) {
        return false;
    }
    if (glyph.clip_y1 != clip.y1) {
        return false;
    }
    return true;
}

// Locks the scroll, viewport, and content column rects, the first knob's faces, and that
// a draw clears the dirty flag.
test "demo layout at 1280 by 720" {
    var app = new_app();
    app.layout(1280, 720);
    const scroll = scroll_of(&app);
    try expect_rect(scroll.rect, 944, 16, 320, 688);
    try expect_rect(scroll.viewport(), 952, 24, 304, 672);
    try expect_rect(scroll.content_column(), 952, 24, 288, 672);
    try std.testing.expectEqual(@as(f32, 904), scroll.content_h);
    try std.testing.expectEqual(@as(f32, 232), scroll.max_scroll());
    try expect_rect(scroll.children[0].knob.rect, 952, 32, 288, 72);
    try expect_rect(widgets.ring_of(scroll.children[0].knob.rect), 960, 40, 56, 56);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try expect_box(list.items[1], 960, 40, 56, 56);
    try std.testing.expectEqual(quads.kind_arc, list.items[1].kind);
    try std.testing.expectEqual(@as(f32, 1), list.items[1].down);
    try expect_box(list.items[2], 960, 40, 56, 56);
    try std.testing.expectEqual(@as(f32, 0.25), list.items[2].down);
    try std.testing.expect(!app.dirty());
}

// Locks that the scroll rect and `max_scroll` follow the window while content height does not.
test "demo layout at 800 by 600" {
    var app = new_app();
    app.layout(800, 600);
    const scroll = scroll_of(&app);
    try expect_rect(scroll.rect, 464, 16, 320, 568);
    try std.testing.expectEqual(@as(f32, 904), scroll.content_h);
    try std.testing.expectEqual(@as(f32, 352), scroll.max_scroll());
}

// Locks that rows below the viewport are culled and visible meter faces carry the viewport
// clip.
test "scroll 0 clips the meter and omits the toggles" {
    var app = new_app();
    app.layout(1280, 720);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    var meter_faces: u32 = 0;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const face = list.items[index];
        if (face.y >= 840) {
            try std.testing.expect(false);
        }
        if (face.width == widgets.meter_track_w) {
            meter_faces += 1;
            try std.testing.expectEqual(view_clip.x0, face.clip_x0);
            try std.testing.expectEqual(view_clip.y0, face.clip_y0);
            try std.testing.expectEqual(view_clip.x1, face.clip_x1);
            try std.testing.expectEqual(view_clip.y1, face.clip_y1);
        }
    }
    try std.testing.expect(meter_faces >= 1);
    var gain_glyph = false;
    var meter_glyph = false;
    index = 0;
    while (index < glyphs.count) : (index += 1) {
        const glyph = glyphs.items[index];
        try std.testing.expect(glyph_has_clip(glyph, view_clip));
        if (glyph.y < 80) {
            gain_glyph = true;
        }
        if (glyph.y > 700) {
            meter_glyph = true;
        }
    }
    try std.testing.expect(gain_glyph);
    try std.testing.expect(meter_glyph);
}

// Locks that a zero-valued knob emits only its track arc.
test "value 0 omits the value arc" {
    var app = new_app();
    app.layout(1280, 720);
    const skew = scroll_of(&app).children[3].knob.rect;
    const ring = widgets.ring_of(skew);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    var arcs: u32 = 0;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const face = list.items[index];
        if (face.kind != quads.kind_arc) {
            continue;
        }
        if (face.y != ring.y) {
            continue;
        }
        arcs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), arcs);
}

// Locks that toggle rows, shorter than knob rows, still draw when nothing needs scrolling.
test "a tall window draws the short toggle rows" {
    var app = new_app();
    app.layout(1280, 1000);
    const scroll = scroll_of(&app);
    try std.testing.expectEqual(@as(f32, 0), scroll.max_scroll());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    const drums = scroll.children[10].toggle.rect;
    const pill_y = drums.y + (drums.height - widgets.pill_h) * 0.5;
    var found = false;
    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        if (list.items[index].y == pill_y) {
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(glyphs.count > 0);
}

// Locks wheel scrolling to the last row and its clamp at `max_scroll`.
test "scroll 232 shows drums and clamps a further wheel" {
    var app = new_app();
    app.layout(1280, 720);
    const scroll = scroll_of(&app);
    const view = scroll.viewport();
    const wheel_x = view.x + view.width - 8;
    const wheel_y = view.y + 40;
    try std.testing.expect(app.event(.{ .wheel = .{
        .x = wheel_x,
        .y = wheel_y,
        .dy = 232,
    } }));
    try std.testing.expectEqual(@as(f32, 232), scroll.scroll_y);
    const drums = scroll.children[10].toggle.rect;
    const bottom = drums.y - scroll.scroll_y + drums.height;
    try std.testing.expectEqual(view.y + view.height, bottom);
    try std.testing.expect(!app.event(.{ .wheel = .{
        .x = wheel_x,
        .y = wheel_y,
        .dy = 40,
    } }));
    try std.testing.expectEqual(@as(f32, 232), scroll.scroll_y);
}

// Locks the relative knob drag through the scene, including clamping at both ends.
test "knob drag from the ring center clamps at both ends" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&app).children[0].knob.rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = cx, .y = cy } }));
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&app).children[0].knob.value);
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy + 4000 } }));
    try std.testing.expectEqual(@as(f32, 0), scroll_of(&app).children[0].knob.value);
    try std.testing.expect(app.event(.{ .pointer_move = .{ .x = cx, .y = cy - 4000 } }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&app).children[0].knob.value);
}

// Locks wheel routing: a ring wheel nudges the knob, any other viewport wheel scrolls.
test "wheel on the ring nudges and wheel on the label scrolls" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&app).children[0].knob.rect);
    const cx = ring.x + ring.width * 0.5;
    const cy = ring.y + ring.height * 0.5;
    try std.testing.expect(app.event(.{ .wheel = .{ .x = cx, .y = cy, .dy = -60 } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&app).children[0].knob.value);
    try std.testing.expectEqual(@as(f32, 0), scroll_of(&app).scroll_y);
    try std.testing.expect(app.event(.{ .wheel = .{
        .x = ring.x + 80,
        .y = cy,
        .dy = 40,
    } }));
    try std.testing.expectEqual(@as(f32, 0.75), scroll_of(&app).children[0].knob.value);
    try std.testing.expectEqual(@as(f32, 40), scroll_of(&app).scroll_y);
}

// Locks that an inside release flips a scrolled toggle and the thumb eases to its target.
test "toggle up inside drums slides the thumb" {
    var app = new_app();
    app.layout(1280, 720);
    const scroll = scroll_of(&app);
    const view = scroll.viewport();
    try std.testing.expect(app.event(.{ .wheel = .{
        .x = view.x + view.width - 8,
        .y = view.y + 40,
        .dy = 232,
    } }));
    const row = scroll.children[10].toggle.rect;
    const visual_y = row.y - scroll.scroll_y;
    const pill_x = row.x + widgets.ring_inset + widgets.pill_w * 0.5;
    const pill_y = visual_y + row.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(app.event(.{ .pointer_up = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(scroll.children[10].toggle.on);
    try std.testing.expectEqual(@as(f32, 1), scroll.children[10].toggle.thumb.target);
    try std.testing.expect(app.event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        scroll.children[10].toggle.thumb.value,
        0.0001,
    );
    try std.testing.expect(app.event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), scroll.children[10].toggle.thumb.value);
}

// Locks that a release outside the pill leaves the toggle unchanged.
test "toggle up outside does not flip" {
    var app = new_app();
    app.layout(1280, 720);
    const scroll = scroll_of(&app);
    const view = scroll.viewport();
    try std.testing.expect(app.event(.{ .wheel = .{
        .x = view.x + view.width - 8,
        .y = view.y + 40,
        .dy = 232,
    } }));
    const row = scroll.children[10].toggle.rect;
    const pill_x = row.x + widgets.ring_inset + widgets.pill_w * 0.5;
    const pill_y = row.y - scroll.scroll_y + row.height * 0.5;
    try std.testing.expect(app.event(.{ .pointer_down = .{ .x = pill_x, .y = pill_y } }));
    try std.testing.expect(app.event(.{ .pointer_up = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(!scroll.children[10].toggle.on);
    try std.testing.expectEqual(@as(f32, 0), scroll.children[10].toggle.thumb.target);
}

// Locks hover easing and that a settled scene stays clean across frames.
test "hover on gain eases and a later frame stays clean" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&app).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(app.event(.{ .pointer_move = point }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&app).children[0].knob.hover.target);
    try std.testing.expect(app.live());
    try std.testing.expect(app.event(.{ .frame = 50 }));
    try std.testing.expectApproxEqAbs(
        @as(f32, 0.5),
        scroll_of(&app).children[0].knob.hover.value,
        0.0001,
    );
    try std.testing.expect(app.event(.{ .frame = 1000 }));
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&app).children[0].knob.hover.value);
    try std.testing.expect(!app.live());
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    try std.testing.expect(!app.dirty());
    try std.testing.expect(!app.event(.{ .frame = 16 }));
    try std.testing.expect(!app.dirty());
}

// Locks that a relayout re-hits the stored pointer and preserves hover state.
test "relayout by 8 px keeps gain hover" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&app).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(app.event(.{ .pointer_move = point }));
    app.layout(1288, 720);
    try std.testing.expectEqual(@as(f32, 1), scroll_of(&app).children[0].knob.hover.target);
    try std.testing.expectEqual(slot_scroll, app.scene.hovered.?);
    try std.testing.expectEqual(@as(u32, 0), scroll_of(&app).hot.?);
}

// Locks that pointer leave drops capture without changing the value.
test "pointer leave during a knob press releases capture" {
    var app = new_app();
    app.layout(1280, 720);
    const ring = widgets.ring_of(scroll_of(&app).children[0].knob.rect);
    const point: input.Point = .{
        .x = ring.x + ring.width * 0.5,
        .y = ring.y + ring.height * 0.5,
    };
    try std.testing.expect(app.event(.{ .pointer_down = point }));
    try std.testing.expect(app.event(.pointer_leave));
    try std.testing.expect(app.scene.capture == null);
    try std.testing.expect(!app.scene.pointer.inside);
    try std.testing.expectEqual(@as(f32, 0.25), scroll_of(&app).children[0].knob.value);
}

// Locks that an unchanged scene produces no upload flags.
test "a settled scene does not rebuild on a scale-style present" {
    var app = new_app();
    app.layout(1280, 720);
    var list = quads.DrawList.init();
    var glyphs = font.GlyphList.init();
    app.draw(&list, &glyphs);
    const revision = list.revision;
    var cursor = quads.UploadCursor.init();
    cursor.mark(&list, &glyphs, 1280, 720);
    try std.testing.expect(!app.dirty());
    try std.testing.expectEqual(@as(u32, 0), cursor.flags(&list, &glyphs, 1280, 720));
    try std.testing.expectEqual(revision, list.revision);
}

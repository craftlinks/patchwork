//! The UI context: the draw context plus the turtle stack, the hit areas, and pointer state.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why One Context
//! Layout happens while drawing (Makepad's turtle): `begin` opens a container, the children
//! walk and append instances, and `end` resolves fit sizes and alignment. Widgets record hit
//! areas while they draw, and the next events resolve against those areas. All of that state
//! is per frame and per window, so it lives beside the draw pools in one value,
//! `Context(Draw, area_cap)`, which embeds the draw context by value as `cx.draw`. The host
//! keeps one static instance; the renderer reads `&cx.draw`.
//!
//! ## 2. Phases
//! ```text
//! idle  --event_begin-->  event  --event_end-->  idle      ui.dispatch, once per event
//! idle  --begin_frame-->  draw   --end_frame-->  idle      ui.draw_frame, when owed
//! ```
//! `append`, `drawing`, `walk`, `begin`, and `area` assert the draw phase; `hit` asserts the
//! event phase; `redraw` asserts that no draw is running, because a draw reads the state it
//! would mark dirty.
//!
//! ## 3. Turtles and Clips
//! `begin_frame` pushes the root turtle: the window, flowing down, clipped to the window.
//! Each entry records the pool counts (`draw.counts`) and the area count when it opened. A
//! `Layout.clip` container intersects the clip with its border box; an empty intersection
//! is `null`, and widgets draw nothing under it (`visible`). Every instance and area copies
//! the clip in effect when it was made.
//!
//! ## 4. Alignment After the Fact
//! At `end`, `turtle.main_shift` (main-axis alignment of the children) and then
//! `turtle.self_shift` (a fit container's own cross alignment) each give one delta. The delta
//! is snapped to the device grid, `d = round(d * s) / s` with `s = scale_120 / 120`, so the
//! glyphs `text.place` snapped stay on device pixels, and is then added to `rect.xy` of every
//! instance appended since the entry opened (`draw.shift`) and of every area recorded since.
//! A zero delta does nothing. Clips never move, so a container that shifts by a non-zero
//! delta must not contain a clipping container (asserted with the running `clip_total`), and
//! a clipping container must have a non-fit size on both axes.
//!
//! ## 5. Hit Resolution
//! `event_begin` stores the pointer and resolves the hot area and the wheel target once
//! (`areas.resolve`, O(areas)); `hit(id, event)` is then O(1) per widget:
//! ```text
//! move   captured: the capture gets drag; else hover_in / hover_out from the old to the new
//!        hover (the hot id)
//! down   the hot area gets down and becomes the capture; the old hover gets hover_out
//! up     the capture gets up { inside = hot is the capture }; a new hot id gets hover_in
//! leave  the capture gets up { inside = false }; else the hover gets hover_out
//! wheel  the wheel target gets wheel; otherwise as move
//! ```
//! While a capture is held, hover is frozen on it. `down` and `drag` carry the area's rect
//! (`Press.rect`) from the last draw, so widgets keep no rects of their own.
//!
//! ## 6. Hover After a Redraw
//! Areas are single-buffered: drawing never interleaves with events. After a draw moved
//! things, `end_frame` re-resolves the stored pointer; if the hot id changed and nothing is
//! captured it returns true and `ui.draw_frame` dispatches a synthetic `pointer_move` at the
//! pointer, so hover lands one frame late.
//!
//! ## 7. TigerStyle Invariants
//! - All storage is fixed: `turtle.depth_max` entries, `area_cap` areas, and the duplicate
//!   stamps of safe builds. Per-frame work is proportional to instances, areas, and depth;
//!   nothing capacity-sized is cleared per frame.
//! - Overflowing areas are counted in `area_overflow` and are not hittable.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const theme = @import("../theme.zig");
const turtle = @import("turtle.zig");
const areas = @import("areas.zig");
const view = @import("view.zig");

pub const Rect = draw.Rect;
pub const Clip = draw.Clip;
pub const Id = areas.Id;
pub const Area = areas.Area;
pub const Flags = areas.Flags;
pub const ViewState = view.ViewState;

/// What the context is doing; see the module guide, section 2.
pub const Phase = enum(u8) {
    idle,
    event,
    draw,
};

/// A press or drag sample, with the rect of the area that was hit at the last draw.
pub const Press = struct {
    x: f32,
    y: f32,
    rect: Rect,
};

/// A release sample. `inside` is true when the pointer is still over the captured area.
pub const Up = struct {
    x: f32,
    y: f32,
    inside: bool,
};

/// What one event means for one id. See the module guide, section 5.
pub const Hit = union(enum) {
    none,
    hover_in,
    hover_out,
    down: Press,
    drag: Press,
    up: Up,
    wheel: input.Wheel,
};

/// No hover, press, or wheel interest beyond the default.
pub const plain: Flags = .{ .wheel = false, .focusable = false };
/// Takes wheel input.
pub const wheel_flag: Flags = .{ .wheel = true, .focusable = false };

/// The layout of the root turtle: the window, flowing down, clipped to the window.
pub const root_layout: turtle.Layout = .{
    .flow = .down,
    .spacing = 0,
    .padding = turtle.zero_inset,
    .alignment = .{ .x = 0, .y = 0 },
    .clip = true,
};

/// The UI context over the draw context type `Draw`. See the module guide.
pub fn Context(comptime Draw: type, comptime area_cap: u32) type {
    comptime {
        assert(area_cap >= 1);
        assert(area_cap <= areas.area_cap_max);
    }
    const pool_count = Draw.Registry.count;
    const Entry = struct {
        turtle: turtle.Turtle,
        starts: [pool_count]u32,
        area_start: u32,
        clip: ?Clip,
        /// `clip_total` once this entry opened, its own clip included.
        clip_total: u32,
        /// Set for a view: its state, id, viewport, and the walk and rect in its parent.
        view: ?*ViewState,
        view_id: Id,
        viewport: Rect,
        outer_walk: turtle.Walk,
        outer_rect: Rect,
    };
    return struct {
        const Self = @This();

        draw: Draw,
        stack: [turtle.depth_max]Entry,
        depth: u32,
        /// Clipping containers opened this frame.
        clip_total: u32,
        areas: [area_cap]Area,
        area_count: u32,
        area_overflow: u32,
        stamps: areas.Stamps(area_cap),
        /// The window in logical pixels at the last `begin_frame`.
        window: Rect,
        phase: Phase,
        event_tag: std.meta.Tag(input.Event),
        pointer: input.Pointer,
        hot: Id,
        hot_rect: Rect,
        wheel: Id,
        hover: Id,
        hover_prev: Id,
        capture: Id,
        capture_rect: Rect,
        /// True during the event whose `down` set the capture.
        pressed: bool,
        /// A draw is owed. Set by `redraw`, cleared by `begin_frame`.
        dirty: bool,
        /// An animator is still moving; see `keep_animating`.
        animating: bool,

        pub const DrawContext = Draw;
        pub const capacity: u32 = area_cap;

        /// Initializes the draw context and an idle UI state that owes its first draw.
        /// Out-pointer init so a static context needs no stack copy.
        pub fn init(self: *Self) void {
            self.draw.init();
            self.stamps.init();
            self.depth = 0;
            self.clip_total = 0;
            self.area_count = 0;
            self.area_overflow = 0;
            self.window = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            self.phase = .idle;
            self.event_tag = .frame;
            self.pointer = input.Pointer.init();
            self.hot = .none;
            self.hot_rect = self.window;
            self.wheel = .none;
            self.hover = .none;
            self.hover_prev = .none;
            self.capture = .none;
            self.capture_rect = self.window;
            self.pressed = false;
            self.dirty = true;
            self.animating = false;
            assert(self.phase == .idle);
            assert(self.dirty);
        }

        /// Marks a draw as owed. Not during a draw.
        pub fn redraw(self: *Self) void {
            assert(self.phase != .draw);
            self.dirty = true;
            assert(self.dirty);
        }

        /// Asks the host for another frame because an animator is still moving.
        pub fn keep_animating(self: *Self) void {
            assert(self.phase == .event);
            self.animating = true;
            assert(self.animating);
        }

        /// The hovered id: the one the last event left hot, frozen while a capture is held.
        pub fn hovered(self: *const Self) Id {
            assert(self.depth <= turtle.depth_max);
            return self.hover;
        }

        // ---------------------------------------------------------------- frame

        /// Resets the draw context and the areas for a window of `width` by `height` logical
        /// pixels at `scale_120`, and pushes the root turtle.
        pub fn begin_frame(self: *Self, width: u32, height: u32, scale_120: u32) void {
            assert(self.phase == .idle);
            assert(width != 0);
            assert(height != 0);
            self.draw.text.scale_120 = scale_120;
            self.draw.reset();
            self.window = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            };
            self.area_count = 0;
            self.area_overflow = 0;
            self.stamps.next_frame();
            self.clip_total = 0;
            self.dirty = false;
            self.phase = .draw;
            self.stack[0] = self.entry_of(
                turtle.root(self.window, root_layout),
                clip_of(self.window),
            );
            self.depth = 1;
            assert(self.stack[0].clip != null);
        }

        /// Ends the frame. Returns true when the hot id under the stored pointer changed and
        /// nothing is captured, so the host owes a synthetic `pointer_move` (section 6).
        pub fn end_frame(self: *Self) bool {
            assert(self.phase == .draw);
            assert(self.depth == 1);
            self.depth = 0;
            self.phase = .idle;
            if (self.capture != .none) {
                if (self.find(self.capture)) |held| self.capture_rect = rect_of(held.rect);
                return false;
            }
            if (!self.pointer.inside) return false;
            const live = self.areas[0..self.area_count];
            const found = areas.resolve(live, self.pointer.x, self.pointer.y);
            const next: Id = if (found.hot) |index| self.areas[index].id else .none;
            return next != self.hover;
        }

        /// The draw context, for `text.place` and app-defined appends. Draw phase only.
        pub fn drawing(self: *Self) *Draw {
            assert(self.phase == .draw);
            assert(self.depth >= 1);
            return &self.draw;
        }

        /// Appends one instance through the draw context. Draw phase only.
        pub fn append(
            self: *Self,
            comptime T: type,
            texture: ?draw.TextureId,
            instance: T,
        ) draw.AppendError!void {
            return self.drawing().append(T, texture, instance);
        }

        // --------------------------------------------------------------- layout

        /// Places a leaf for `walk` in the current container and returns its border box.
        pub fn walk(self: *Self, child: turtle.Walk) Rect {
            assert(child.width != .fit);
            assert(child.height != .fit);
            const current = self.top();
            const rect = turtle.place(&current.turtle, child);
            turtle.advance(&current.turtle, child, rect);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            return rect;
        }

        /// Opens a container for `child` laid out by `layout` and returns its border box (a
        /// fit axis is 0 until `end`).
        pub fn begin(self: *Self, child: turtle.Walk, layout: turtle.Layout) Rect {
            assert(self.depth < turtle.depth_max);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            var clipped = parent.clip;
            if (layout.clip) {
                assert(child.width != .fit);
                assert(child.height != .fit);
                self.clip_total += 1;
                clipped = intersect(parent.clip, rect);
            }
            self.stack[self.depth] = self.entry_of(turtle.open(rect, child, layout), clipped);
            self.depth += 1;
            assert(self.depth >= 2);
            return rect;
        }

        /// Closes the current container: aligns its children, resolves fit sizes, aligns
        /// itself, and advances its parent. Returns its final border box.
        pub fn end(self: *Self) Rect {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            assert(entry.view == null);
            _ = self.shift_since(entry, turtle.main_shift(&entry.turtle));
            var rect = turtle.close(&entry.turtle);
            self.depth -= 1;
            const parent = self.top();
            const moved = self.shift_since(entry, turtle.self_shift(
                &parent.turtle,
                entry.turtle.walk,
                rect,
            ));
            rect.x += moved[0];
            rect.y += moved[1];
            turtle.advance(&parent.turtle, entry.turtle.walk, rect);
            return rect;
        }

        /// Advances the current container's cursor by `span` without a child.
        pub fn skip(self: *Self, span: f32) void {
            assert(span >= 0);
            const current = self.top();
            const before = current.turtle.count;
            turtle.skip(&current.turtle, span);
            assert(current.turtle.count == before);
        }

        /// The border box the next child for `child` would get, without placing it. A
        /// container face drawn before `begin` uses it, so a shift of the children leaves
        /// the face in place.
        pub fn peek(self: *Self, child: turtle.Walk) Rect {
            const current = self.top();
            const before = current.turtle.count;
            const rect = turtle.peek(&current.turtle, child);
            assert(current.turtle.count == before);
            assert(rect.width >= 0);
            return rect;
        }

        /// True when the next child for `child` would fit the current container.
        pub fn fits(self: *Self, child: turtle.Walk) bool {
            const current = self.top();
            const before = current.turtle.count;
            const result = turtle.fits(&current.turtle, child);
            assert(current.turtle.count == before);
            return result;
        }

        /// The space the next child of the current container could use.
        pub fn remaining(self: *Self) Rect {
            const rect = turtle.remaining(&self.top().turtle);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            return rect;
        }

        /// The clip in effect, or null when it is empty.
        pub fn clip(self: *Self) ?Clip {
            const current = self.top().clip orelse return null;
            assert(current.x1 > current.x0);
            assert(current.y1 > current.y0);
            return current;
        }

        /// The clip in effect when `rect` has positive edges and overlaps it, else null: the
        /// cull test widgets apply before drawing.
        pub fn visible(self: *Self, rect: Rect) ?Clip {
            const current = self.top().clip orelse return null;
            if (!(rect.width > 0)) return null;
            if (!(rect.height > 0)) return null;
            if (rect.x >= current.x1) return null;
            if (rect.y >= current.y1) return null;
            if (rect.x + rect.width <= current.x0) return null;
            if (rect.y + rect.height <= current.y0) return null;
            assert(current.x1 > current.x0);
            assert(rect.width > 0);
            return current;
        }

        // ---------------------------------------------------------------- views

        /// Opens a scrolling view for `child`. `layout.padding` insets the viewport and the
        /// children flow by `layout` in the viewport minus the gutter, `scroll_y` above its
        /// top. Registers the view's wheel area first. Returns the viewport.
        pub fn begin_view(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *ViewState,
        ) Rect {
            assert(self.depth < turtle.depth_max);
            assert(child.width != .fit);
            assert(child.height != .fit);
            assert(layout.alignment.y == 0);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            const viewport = inset(rect, layout.padding);
            state.viewport = viewport;
            state.scroll_y = std.math.clamp(state.scroll_y, 0, state.max_scroll());
            if (viewport.width > 0 and viewport.height > 0) {
                self.area(id, viewport, 0, wheel_flag);
            }
            const content: Rect = .{
                .x = viewport.x,
                .y = viewport.y - state.scroll_y,
                .width = @max(0, viewport.width - view.gutter_px),
                .height = @max(0, viewport.height),
            };
            var inner = layout;
            inner.padding = turtle.zero_inset;
            inner.clip = false;
            self.clip_total += 1;
            const clipped = intersect(parent.clip, viewport);
            var entry = self.entry_of(turtle.root(content, inner), clipped);
            entry.view = state;
            entry.view_id = id;
            entry.viewport = viewport;
            entry.outer_walk = child;
            entry.outer_rect = rect;
            self.stack[self.depth] = entry;
            self.depth += 1;
            return viewport;
        }

        /// Closes the current view: stores the measured content height, advances the
        /// parent, and draws the thumb with its area when the content can scroll.
        pub fn end_view(self: *Self) void {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            const state = entry.view.?;
            state.content_h = @max(0, entry.turtle.extent[1] - entry.turtle.rect.y);
            self.depth -= 1;
            const parent = self.top();
            turtle.advance(&parent.turtle, entry.outer_walk, entry.outer_rect);
            if (!(state.max_scroll() > 0)) return;
            if (!(state.viewport.height > 0)) return;
            const thumb = state.thumb_rect();
            const outer = parent.clip orelse return;
            self.append(draw.Box, null, .{
                .rect = .{ thumb.x, thumb.y, thumb.width, thumb.height },
                .clip = .{ outer.x0, outer.y0, outer.x1, outer.y1 },
                .fill = theme.chrome.control,
                .border_color = .{ 0, 0, 0, 0 },
                .radius = view.thumb_radius,
                .border_width = 0,
                .hover = 0,
                .down = 0,
            }) catch |err| switch (err) {
                error.PoolFull, error.BatchFull => {},
                error.EdgeNotPositive, error.ClipUnordered => unreachable,
            };
            self.area(entry.view_id.derive(view.thumb_salt), thumb, 0, plain);
        }

        // ---------------------------------------------------------------- areas

        /// Records a hit area for `id` over `rect` with corner `radius`, under the clip in
        /// effect, on the current layer. One area per id per frame.
        pub fn area(self: *Self, id: Id, rect: Rect, radius: f32, flags: Flags) void {
            assert(self.phase == .draw);
            assert(id != .none);
            assert(rect.width > 0);
            assert(rect.height > 0);
            assert(radius >= 0);
            const current = self.top().clip orelse return;
            if (self.area_count == area_cap) {
                self.area_overflow += 1;
                return;
            }
            // Only stored areas are stamped, so at most `area_cap` inserts fill the
            // 2 * area_cap slots and the probe always finds a free one.
            const fresh = self.stamps.insert(id);
            assert(fresh);
            self.areas[self.area_count] = .{
                .id = id,
                .rect = .{ rect.x, rect.y, rect.width, rect.height },
                .clip = .{ current.x0, current.y0, current.x1, current.y1 },
                .radius = radius,
                .layer = @backingInt(self.draw.layer_now),
                .flags = flags,
                .pad = 0,
            };
            self.area_count += 1;
            assert(self.area_count <= area_cap);
        }

        /// The area recorded for `id` at the last draw, or null. O(areas): for tests and for
        /// anchoring something to a widget drawn earlier in the frame.
        pub fn find(self: *const Self, id: Id) ?Area {
            assert(id != .none);
            assert(self.area_count <= area_cap);
            for (self.areas[0..self.area_count]) |candidate| {
                if (candidate.id == id) return candidate;
            }
            return null;
        }

        /// The areas of the last draw, in append order.
        pub fn area_list(self: *const Self) []const Area {
            assert(self.area_count <= area_cap);
            return self.areas[0..self.area_count];
        }

        // --------------------------------------------------------------- events

        /// Starts dispatching `event`: stores the pointer and resolves the hot area and the
        /// wheel target once (section 5).
        pub fn event_begin(self: *Self, event: input.Event) void {
            assert(self.phase == .idle);
            self.phase = .event;
            self.event_tag = event;
            self.hover_prev = self.hover;
            self.pressed = false;
            switch (event) {
                .frame => {},
                .pointer_leave => {
                    self.pointer.leave();
                    self.hot = .none;
                    self.wheel = .none;
                    self.hover = .none;
                },
                .pointer_move => |point| self.point_at(point.x, point.y, false),
                .pointer_up => |point| {
                    self.pointer.button(false);
                    self.point_at(point.x, point.y, true);
                },
                .wheel => |wheel| self.point_at(wheel.x, wheel.y, false),
                .pointer_down => |point| {
                    self.pointer.button(true);
                    self.point_at(point.x, point.y, false);
                    if (self.capture == .none and self.hot != .none) {
                        self.capture = self.hot;
                        self.capture_rect = self.hot_rect;
                        self.pressed = true;
                    }
                },
            }
            assert(self.phase == .event);
        }

        /// Finishes dispatching: a release or a leave drops the capture.
        pub fn event_end(self: *Self) void {
            assert(self.phase == .event);
            switch (self.event_tag) {
                .pointer_up, .pointer_leave => self.capture = .none,
                else => {},
            }
            self.phase = .idle;
            assert(self.phase == .idle);
        }

        /// What `event` means for `id`. O(1); see the module guide, section 5.
        pub fn hit(self: *const Self, id: Id, event: input.Event) Hit {
            assert(self.phase == .event);
            assert(id != .none);
            assert(@as(std.meta.Tag(input.Event), event) == self.event_tag);
            switch (event) {
                .frame => return .none,
                .pointer_move => |point| {
                    if (self.capture != .none) return self.drag_of(id, point);
                    return self.hover_change(id);
                },
                .pointer_down => |point| {
                    if (self.pressed and id == self.capture) {
                        return .{ .down = .{ .x = point.x, .y = point.y, .rect = self.hot_rect } };
                    }
                    if (!self.pressed and self.capture != .none) return self.drag_of(id, point);
                    return self.hover_change(id);
                },
                .pointer_up => |point| {
                    if (self.capture == .none) return self.hover_change(id);
                    if (id == self.capture) {
                        const inside = self.hot == self.capture;
                        return .{ .up = .{ .x = point.x, .y = point.y, .inside = inside } };
                    }
                    if (id == self.hover and id != self.hover_prev) return .hover_in;
                    return .none;
                },
                .pointer_leave => {
                    if (id == self.capture) {
                        const at = self.pointer;
                        return .{ .up = .{ .x = at.x, .y = at.y, .inside = false } };
                    }
                    if (id == self.hover_prev) return .hover_out;
                    return .none;
                },
                .wheel => |wheel| {
                    if (id == self.wheel) return .{ .wheel = wheel };
                    if (self.capture != .none) return .none;
                    return self.hover_change(id);
                },
            }
        }

        fn drag_of(self: *const Self, id: Id, point: input.Point) Hit {
            assert(self.capture != .none);
            assert(id != .none);
            if (id != self.capture) return .none;
            return .{ .drag = .{ .x = point.x, .y = point.y, .rect = self.capture_rect } };
        }

        fn hover_change(self: *const Self, id: Id) Hit {
            assert(id != .none);
            assert(self.phase == .event);
            if (self.hover == self.hover_prev) return .none;
            if (id == self.hover) return .hover_in;
            if (id == self.hover_prev) return .hover_out;
            return .none;
        }

        /// Stores the pointer and resolves the hot area and wheel target under it. Hover
        /// follows the hot id unless a capture is held, except on the release that ends it.
        fn point_at(self: *Self, x: f32, y: f32, releasing: bool) void {
            assert(x == x);
            assert(y == y);
            self.pointer.move(x, y);
            const found = areas.resolve(self.areas[0..self.area_count], x, y);
            self.hot = .none;
            self.wheel = .none;
            if (found.hot) |index| {
                self.hot = self.areas[index].id;
                self.hot_rect = rect_of(self.areas[index].rect);
            }
            if (found.wheel) |index| self.wheel = self.areas[index].id;
            if (self.capture == .none or releasing) self.hover = self.hot;
            assert(self.pointer.inside);
        }

        // ------------------------------------------------------------- internals

        fn top(self: *Self) *Entry {
            assert(self.phase == .draw);
            assert(self.depth >= 1);
            assert(self.depth <= turtle.depth_max);
            return &self.stack[self.depth - 1];
        }

        fn entry_of(self: *const Self, value: turtle.Turtle, clipped: ?Clip) Entry {
            assert(value.count == 0);
            assert(self.area_count <= area_cap);
            return .{
                .turtle = value,
                .starts = self.draw.counts(),
                .area_start = self.area_count,
                .clip = clipped,
                .clip_total = self.clip_total,
                .view = null,
                .view_id = .none,
                .viewport = value.rect,
                .outer_walk = value.walk,
                .outer_rect = value.rect,
            };
        }

        /// Snaps `delta` to device pixels and moves what `entry` drew by it (section 4).
        /// Returns the delta applied.
        fn shift_since(self: *Self, entry: *const Entry, delta: [2]f32) [2]f32 {
            assert(delta[0] >= 0);
            assert(delta[1] >= 0);
            assert(entry.area_start <= self.area_count);
            const scale = @as(f32, @floatFromInt(self.draw.text.scale_120)) / 120;
            const dx = @round(delta[0] * scale) / scale;
            const dy = @round(delta[1] * scale) / scale;
            if (dx == 0 and dy == 0) return .{ 0, 0 };
            // Clips do not move, so nothing inside may have set one (section 4).
            assert(self.clip_total == entry.clip_total);
            self.draw.shift(entry.starts, dx, dy);
            for (self.areas[entry.area_start..self.area_count]) |*moved| {
                moved.rect[0] += dx;
                moved.rect[1] += dy;
            }
            return .{ dx, dy };
        }
    };
}

/// The clip of a rect with positive edges.
pub fn clip_of(rect: Rect) Clip {
    assert(rect.width > 0);
    assert(rect.height > 0);
    assert(rect.x == rect.x);
    return .{ .x0 = rect.x, .y0 = rect.y, .x1 = rect.x + rect.width, .y1 = rect.y + rect.height };
}

/// `clip` intersected with `rect`, or null when the result is empty.
pub fn intersect(clip: ?Clip, rect: Rect) ?Clip {
    assert(rect.width == rect.width);
    assert(rect.height == rect.height);
    const outer = clip orelse return null;
    const out: Clip = .{
        .x0 = @max(outer.x0, rect.x),
        .y0 = @max(outer.y0, rect.y),
        .x1 = @min(outer.x1, rect.x + rect.width),
        .y1 = @min(outer.y1, rect.y + rect.height),
    };
    if (!(out.x1 > out.x0)) return null;
    if (!(out.y1 > out.y0)) return null;
    return out;
}

/// `rect` inset by `padding`; edges may go negative.
pub fn inset(rect: Rect, padding: draw.Inset) Rect {
    assert(padding.left >= 0);
    assert(padding.right >= 0);
    return .{
        .x = rect.x + padding.left,
        .y = rect.y + padding.top,
        .width = rect.width - padding.left - padding.right,
        .height = rect.height - padding.top - padding.bottom,
    };
}

fn rect_of(values: [4]f32) Rect {
    assert(values[2] == values[2]);
    assert(values[3] == values[3]);
    return .{ .x = values[0], .y = values[1], .width = values[2], .height = values[3] };
}

const testing = std.testing;
const text = @import("../text.zig");

const test_draw = [_]draw.DrawType{
    .{ .type = draw.Box, .cap = 64 },
    .{ .type = draw.Glyph, .cap = 64 },
};

const TestContext = Context(draw.Context(&test_draw, 8), 64);

/// A freshly initialized static context, so tests keep the pools off the stack.
fn new_context() *TestContext {
    const static = struct {
        var context: TestContext = undefined;
    };
    static.context.init();
    return &static.context;
}

fn sized(width: turtle.Size, height: turtle.Size) turtle.Walk {
    return .{ .width = width, .height = height, .margin = turtle.zero_inset };
}

fn flow_of(flow: turtle.Flow) turtle.Layout {
    var layout = root_layout;
    layout.flow = flow;
    layout.clip = false;
    return layout;
}

fn box(context: *TestContext, rect: Rect) void {
    const current = context.clip().?;
    context.append(draw.Box, null, .{
        .rect = .{ rect.x, rect.y, rect.width, rect.height },
        .clip = .{ current.x0, current.y0, current.x1, current.y1 },
        .fill = .{ 1, 1, 1, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .radius = 0,
        .border_width = 0,
        .hover = 0,
        .down = 0,
    }) catch unreachable;
}

fn rect_at(x: f32, y: f32, width: f32, height: f32) Rect {
    return .{ .x = x, .y = y, .width = width, .height = height };
}

/// Dispatches `event` and writes what it means for each of `ids` into `out`.
fn send(context: *TestContext, event: input.Event, ids: []const Id, out: []Hit) void {
    assert(ids.len == out.len);
    context.event_begin(event);
    for (ids, out) |key, *result| result.* = context.hit(key, event);
    context.event_end();
}

// Locks the post-hoc alignment: a fit row in a centered column measures its children, and
// `end` moves its instances and areas by the snapped delta, so at scale 1.5 the glyphs stay
// on device pixels.
test "a fit container measures its children and alignment shifts their instances" {
    const context = new_context();
    context.begin_frame(300, 200, 180);
    var column = flow_of(.down);
    column.alignment.x = 0.5;
    _ = context.begin(sized(.fill, .fill), column);
    _ = context.begin(sized(.fit, .fit), flow_of(.right));
    const face = context.walk(sized(.{ .fixed = 40 }, .{ .fixed = 20 }));
    box(context, face);
    context.area(areas.id("face", 0), face, 0, plain);
    const label = context.walk(sized(.{ .fixed = 41 }, .{ .fixed = 20 }));
    const style: text.Style = .{ .face = .sans, .size = 16, .color = .{ 1, 1, 1, 1 } };
    const options: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = false };
    text.place(context.drawing(), style, "Hi", label, context.clip().?, options);
    const row = context.end();
    // Width 81, slack 219, half of it 109.5 logical = 164.25 device px, snapped to 164.
    try testing.expectEqual(@as(f32, 164.0 / 1.5), row.x);
    try testing.expectEqual(@as(f32, 81), row.width);
    try testing.expectEqual(row.x, context.draw.items(draw.Box)[0].rect[0]);
    try testing.expectEqual(row.x, context.find(areas.id("face", 0)).?.rect[0]);
    const glyphs = context.draw.items(draw.Glyph);
    try testing.expect(glyphs.len >= 1);
    for (glyphs) |glyph| {
        const device = glyph.rect[0] * 1.5;
        try testing.expectApproxEqAbs(@round(device), device, 0.001);
    }
    _ = context.end();
    try testing.expect(!context.end_frame());
    try testing.expectEqual(@as(u32, 0), context.draw.overflow_count);
}

// Locks hit resolution: hover moves to the topmost area (the overlay layer wins over a later
// base area), a press captures, the capture persists across a redraw that moved the area and
// its drags carry the new rect, and a release outside reports `inside = false`.
test "topmost wins and capture persists across frames" {
    const context = new_context();
    const panel = areas.id("panel", 0);
    const knob = areas.id("knob", 0);
    const tip = areas.id("tip", 0);
    context.begin_frame(400, 300, 120);
    context.area(panel, rect_at(0, 0, 200, 200), 0, plain);
    const previous = context.draw.layer(.overlay);
    context.area(tip, rect_at(80, 80, 50, 50), 0, plain);
    _ = context.draw.layer(previous);
    context.area(knob, rect_at(50, 50, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    const ids = [_]Id{ panel, knob, tip };
    var out: [3]Hit = undefined;
    send(context, .{ .pointer_move = .{ .x = 60, .y = 60 } }, &ids, &out);
    try testing.expectEqual(Hit.none, out[0]);
    try testing.expectEqual(Hit.hover_in, out[1]);
    send(context, .{ .pointer_move = .{ .x = 90, .y = 90 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_out, out[1]);
    try testing.expectEqual(Hit.hover_in, out[2]);
    send(context, .{ .pointer_down = .{ .x = 60, .y = 60 } }, &ids, &out);
    try testing.expectEqual(@as(f32, 50), out[1].down.rect.x);
    try testing.expectEqual(Hit.hover_out, out[2]);
    try testing.expectEqual(knob, context.hovered());
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(150, 50, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    send(context, .{ .pointer_move = .{ .x = 170, .y = 60 } }, &ids, &out);
    try testing.expectEqual(@as(f32, 150), out[1].drag.rect.x);
    try testing.expectEqual(Hit.none, out[0]);
    send(context, .{ .pointer_up = .{ .x = 390, .y = 290 } }, &ids, &out);
    try testing.expect(!out[1].up.inside);
    try testing.expectEqual(Id.none, context.capture);
    try testing.expectEqual(Id.none, context.hovered());
}

// Locks clipping: an area under a clipping container hits only inside the clip, and a fully
// clipped container records nothing.
test "clipped areas do not hit" {
    const context = new_context();
    context.begin_frame(400, 300, 120);
    var clipped = flow_of(.down);
    clipped.clip = true;
    _ = context.begin(sized(.{ .fixed = 100 }, .{ .fixed = 100 }), clipped);
    context.area(areas.id("wide", 0), rect_at(0, 0, 300, 50), 0, plain);
    try testing.expectEqual(@as(?Clip, clip_of(rect_at(0, 0, 100, 100))), context.clip());
    _ = context.begin(sized(.{ .fixed = 0 }, .{ .fixed = 10 }), clipped);
    try testing.expectEqual(@as(?Clip, null), context.clip());
    context.area(areas.id("hidden", 0), rect_at(0, 0, 10, 10), 0, plain);
    _ = context.end();
    _ = context.end();
    _ = context.end_frame();
    try testing.expectEqual(@as(usize, 1), context.area_list().len);
    var out: [1]Hit = undefined;
    const ids = [_]Id{areas.id("wide", 0)};
    send(context, .{ .pointer_move = .{ .x = 150, .y = 10 } }, &ids, &out);
    try testing.expectEqual(Hit.none, out[0]);
    send(context, .{ .pointer_move = .{ .x = 50, .y = 10 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
}

// Locks the redraw rule: when a redraw moves an area out from under a resting pointer,
// `end_frame` reports that hover must be re-resolved, and an unchanged redraw does not.
test "end_frame reports hover that a redraw moved" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{knob}, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(100, 0, 50, 50), 0, plain);
    try testing.expect(context.end_frame());
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{knob}, &out);
    try testing.expectEqual(Hit.hover_out, out[0]);
}

// Locks the virtualized list: in a 240 px view of 1,000 rows of 24 px scrolled to 100, only
// rows 4 to 14 emit boxes and areas, the measured content is the whole list, the thumb draws
// with its area, a wheel over a row scrolls the view, and the next frame clamps the offset.
test "a 1,000-row list emits only visible rows" {
    const context = new_context();
    const list: view.List = .{ .row_height = 24, .count = 1000 };
    const view_id = areas.id("view", 0);
    var state = ViewState.init();
    state.scroll_y = 100;
    state.content_h = list.height();
    var drawn: [2]view.List.Range = undefined;
    var frame: u32 = 0;
    while (frame < 2) : (frame += 1) {
        context.begin_frame(400, 300, 120);
        const walk = sized(.{ .fixed = 200 }, .{ .fixed = 240 });
        const port = context.begin_view(view_id, walk, flow_of(.down), &state);
        const range = list.visible(state.scroll_y, port.height);
        drawn[frame] = range;
        context.skip(@as(f32, @floatFromInt(range.first)) * list.row_height);
        var row = range.first;
        while (row < range.end) : (row += 1) {
            const rect = context.walk(sized(.fill, .{ .fixed = list.row_height }));
            box(context, rect);
            context.area(areas.id("row", row), rect, 0, plain);
        }
        context.skip(@as(f32, @floatFromInt(list.count - range.end)) * list.row_height);
        context.end_view();
        _ = context.end_frame();
        if (frame == 0) {
            try testing.expectEqual(@as(f32, 24000), state.content_h);
            // Eleven rows, one thumb.
            try testing.expectEqual(@as(usize, 12), context.draw.items(draw.Box).len);
            // The view, eleven rows, and the thumb.
            try testing.expectEqual(@as(usize, 13), context.area_list().len);
            const first = context.find(areas.id("row", 4)).?;
            try testing.expectEqualSlices(f32, &.{ 0, -4, 184, 24 }, &first.rect);
            var out: [1]Hit = undefined;
            const wheel: input.Event = .{ .wheel = .{ .x = 20, .y = 10, .dy = 30000 } };
            context.event_begin(wheel);
            const action = state.handle(context, view_id, wheel);
            try testing.expectEqual(ViewState.Action.scrolled, action);
            out[0] = context.hit(areas.id("row", 4), wheel);
            context.event_end();
            try testing.expectEqual(Hit.hover_in, out[0]);
        }
    }
    try testing.expectEqual(view.List.Range{ .first = 4, .end = 15 }, drawn[0]);
    try testing.expectEqual(@as(f32, 24000 - 240), state.scroll_y);
    try testing.expectEqual(view.List.Range{ .first = 990, .end = 1000 }, drawn[1]);
    try testing.expectEqual(@as(u32, 0), context.area_overflow);
}

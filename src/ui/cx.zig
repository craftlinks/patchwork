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
//! `append`, `drawing`, `walk`, `begin`, and `area` assert the draw phase; `hit`, the focus
//! changes, `copy`, and `request_paste` assert the event phase; `redraw` asserts that no draw
//! is running, because a draw reads the state it would mark dirty.
//!
//! ## 3. Turtles and Clips
//! `begin_frame` pushes the root turtle: the window, flowing down, clipped to the window.
//! Each entry records the pool counts (`draw.counts`) and the area count when it opened. A
//! `Layout.clip` container intersects the clip with its border box; an empty intersection
//! is `null`, and widgets draw nothing under it (`visible`). Every instance and area copies
//! the clip in effect when it was made.
//!
//! ## 3a. Canvases
//! `begin_canvas(id, walk, layout, *CanvasState, layers)` opens a pan/zoom canvas
//! (`ui/canvas.zig`). It records the canvas's own wheel area over the viewport in screen pixels,
//! gives each of `layers` the state's view this frame (`draw.Context.view`), and switches to
//! the first. Inside, until `end_canvas`, everything is in world pixels:
//! ```text
//! clip     T^-1(parent clip ∩ viewport):  x0' = (x0 - view.x) / zoom, likewise each edge
//! turtle   a root over T^-1(viewport), the visible world rect (`remaining`)
//! visible  the usual cull test, against the world clip
//! area     mapped forward: rect' = (view.x + zoom * x, view.y + zoom * y, zoom * w,
//!          zoom * h), radius' = zoom * radius, clip' = T(world clip), Area.zoom = zoom
//! shift    snapped to 1 / text.device_scale(); areas move by delta * zoom
//! ```
//! Instances keep world rects and clips, which the renderer draws through the layer's view;
//! areas are on the screen, so resolution, capture, and `Press.rect` need no inverse. The glyph
//! zoom (`text.zoom`) is the rung nearest the zoom while the canvas is open and 1 after.
//! Canvases do not nest.
//!
//! ## 3b. Free Placement
//! `begin_at(rect, layout)` opens a container at a fixed `rect` in the current coordinates
//! without placing it in its parent's flow, so a canvas places modules at their world rects.
//! Its `end` aligns its children as usual but neither shifts it nor advances the parent.
//!
//! ## 3c. Popups
//! A popup (a menu, a dropdown's list, a dialog) is drawn by its owner at the end of
//! `App.draw` (`ui.overlays`), when only the root is open. `begin_popup(id, rect, layout, dim)`
//! switches to `Layer.popup`, appends a black face over the window at alpha `dim` (0 for none,
//! a dialog's dimming otherwise), records the backdrop area `popup_backdrop(id)` over the whole
//! window, and opens a free container (section 3b) at `rect` under the window clip, so nothing
//! the app opened clips it; `end_popup` closes it and restores the layer. Resolution prefers
//! the highest layer and then the last appended (`ui/areas.zig`, section 4), so the popup's own
//! areas, recorded after the backdrop, take the pointer over them, and the backdrop takes it
//! everywhere else: a press outside reaches no base widget, so it only dismisses. One popup per
//! frame (`popup.popup_depth_max`), never inside a canvas, and never while the popup layer is
//! bound offscreen (asserted).
//!
//! A widget that opens a popup calls `request_popup(id)`, which owes a draw. The owner's draw
//! then meets the request with `begin_popup` (or `skip_popup` when its anchor was not drawn),
//! and in safe builds `end_frame` panics naming the id when nothing met it: an app that forgot
//! `ui.overlays` learns it on the first open, not by a menu that never shows.
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
//! move        captured: the capture gets drag; else hover_in / hover_out from the old to
//!             the new hover (the hot id)
//! left down   the hot area gets down and becomes the capture; the old hover gets hover_out
//! left up     the capture gets up { inside = hot is the capture }; a new hot id gets hover_in
//! right down  uncaptured: the hot area gets secondary (no capture); otherwise as move
//! other       a middle press and every non-left release act as a move
//! leave       the capture gets up { inside = false }; else the hover gets hover_out
//! wheel       the wheel target gets wheel; otherwise as move
//! keys, paste, window focus, frame: none (section 7)
//! ```
//! A path area (`path_area`, for a stroke drawn with `draw.path`) is hit within a distance of
//! its polyline instead of a rounded rect (`ui/areas.zig`, section 3); the scan is the same.
//! While a capture is held, hover is frozen on it. `down`, `drag`, and `secondary` carry the
//! area's rect (`Press.rect`) from the last draw, so widgets keep no rects of their own, and
//! the press count of the click sequence (`Press.clicks`, `input.count_click`). Only the left
//! button captures, so a right release never ends a left drag.
//!
//! ## 6. Hover After a Redraw
//! Areas are single-buffered: drawing never interleaves with events. After a draw moved
//! things, `end_frame` re-resolves the stored pointer; if the hot id changed and nothing is
//! captured it returns true and `ui.draw_frame` dispatches a synthetic `pointer_move` at the
//! pointer, so hover lands one frame late.
//!
//! ## 7. Keyboard Focus
//! `focus` is the id that receives keys and pastes. Widgets ask `focused(id)` (O(1)) and read
//! the event themselves; `hit` answers `none` for keyboard events, so pointer-only widgets
//! ignore them. Areas flagged `focusable` define the Tab order: their order in the area list,
//! which is draw order.
//! - A left press focuses the hot area when it is focusable and clears focus otherwise.
//! - Tab and Shift+Tab move to the next or previous focusable area, wrapping, with one scan of
//!   the areas: the only O(areas) keyboard path. A focus that was not drawn starts the cycle.
//!   When the focused area is flagged `tab` (an editor that indents), Tab and Shift+Tab stay
//!   with its widget and focus does not move; Escape still clears focus, which is how the
//!   keyboard leaves such a widget.
//! - Escape clears focus in `event_end`, after the widgets saw the key, so a field reads it as
//!   cancel; a move away by a press or Tab is visible during that event as `focus_lost(id)`,
//!   which a field reads as commit.
//! - A focused id that the last draw did not record stays focused; `focus_rect` is its area's
//!   rect from the last draw that recorded it (refreshed in `end_frame`, only while focused).
//! - `window_focus(false)` clears the held keys and the modifiers.
//! A browser key is `consumed` when a widget had focus or Tab moved it, unless it is a
//! clipboard shortcut, so the page's own copy, cut, and paste events still fire.
//!
//! ## 8. Cursor and Clipboard
//! The hot area's `Flags.cursor` is resolved with the hot area; `cursor()` reports it, the
//! captured area's cursor while a press is held (a held `grab` reads `grabbing`), and
//! `default` outside the window. `copy(bytes)` stores up to `clipboard_cap` bytes (cut on a
//! codepoint boundary) in `clipboard` and flags the host; `request_paste` asks the host for
//! the clipboard text, which arrives as a `paste` event routed to the focused widget.
//!
//! ## 9. The Timer Flag
//! `timer_setup(period_ms, armed)` (from the hosts, once) stores `App.config.timer_period_ms`
//! and sets `timer_on` to `period_ms != 0 and armed`. `set_timer(on)` changes the flag during
//! an event or a timer call; after each call into the app the hosts compare it with what
//! they armed and arm or disarm the timer (`timerfd_settime` natively, `setInterval` and
//! `clearInterval` in the browser), so a paused app sleeps. Setting it on an app without a
//! period is a programming error (asserted).
//!
//! ## 9a. The Audio Flag
//! `audio_setup(has_audio)` (from the hosts, once) records whether the app declares an
//! `Audio` source (`app.zig`); `audio_on` starts false. `set_audio(on)` during an event starts or
//! stops the source: the native host starts or parks its audio thread to match, and the
//! browser resumes or suspends its `AudioContext`, so a stopped app produces nothing and sleeps
//! (`realtime.zig`). Setting it on an app without a source is a programming error (asserted).
//! After each drain the hosts copy the queue's drop count into `audio_dropped`.
//!
//! ## 9b. The Theme
//! `scheme` is the app's `theme.Scheme` and `draw.theme` its GPU record (`theme.zig`, section
//! 1). `theme_setup(scheme)` (from `app.start`, once) copies `App.config.theme`; until then
//! both are `theme.dark`. `theme()` returns it in any phase, and widgets read their colors,
//! text styles, and hover and press weights from it at draw time; the scrollbar thumb is
//! `colors.control`. `set_theme(scheme)` during an event or a timer call stores a different
//! scheme, writes its record into `draw.theme`, and calls `redraw`; the same scheme again is
//! no change and owes nothing. The renderer sees the new record as a uniform change.
//!
//! ## 10. TigerStyle Invariants
//! - All storage is fixed: `turtle.depth_max` entries, `area_cap` areas, the clipboard, and the
//!   duplicate stamps of safe builds. Per-frame work is proportional to instances, areas, and
//!   depth; nothing capacity-sized is cleared per frame or per event.
//! - Overflowing areas are counted in `area_overflow` and are not hittable. `overflow()` gathers
//!   them with the refused instances and glyphs, and `overflow_report()` returns that only when
//!   it changed and is not zero, which both hosts log after a draw in safe builds.

const std = @import("std");
const assert = std.debug.assert;
const draw = @import("../draw.zig");
const input = @import("../input.zig");
const theme_module = @import("../theme.zig");
const turtle = @import("turtle.zig");
const areas = @import("areas.zig");
const view = @import("view.zig");
const canvas = @import("canvas.zig");
const popup = @import("popup.zig");

pub const Rect = draw.Rect;
pub const Clip = draw.Clip;
pub const Id = areas.Id;
pub const Area = areas.Area;
pub const Flags = areas.Flags;
pub const Cursor = areas.Cursor;
pub const ViewState = view.ViewState;
pub const CanvasState = canvas.CanvasState;

/// Bytes `copy` keeps for the host to offer: one paste-sized buffer per context.
pub const clipboard_cap: u32 = 65536;

/// What the context is doing; see the module guide, section 2.
pub const Phase = enum(u8) {
    idle,
    event,
    draw,
};

/// A press or drag sample, with the rect of the area that was hit at the last draw, the press
/// count of the click sequence, and the modifiers.
pub const Press = struct {
    x: f32,
    y: f32,
    rect: Rect,
    clicks: u8,
    mods: input.Mods,
};

/// A release sample. `inside` is true when the pointer is still over the captured area.
pub const Up = struct {
    x: f32,
    y: f32,
    inside: bool,
};

/// What the last draw refused for lack of room (module guide, section 10): instances
/// (`draw.overflow_count`), areas (`area_overflow`), and glyphs the atlas could not fit.
pub const Overflow = struct {
    instances: u32,
    areas: u32,
    glyphs: u32,

    pub const zero: Overflow = .{ .instances = 0, .areas = 0, .glyphs = 0 };
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
    /// A right press on the hot area. It does not capture.
    secondary: Press,
};

/// No hover, press, or wheel interest beyond the default.
pub const plain: Flags = .{ .wheel = false, .focusable = false, .tab = false, .cursor = .default };
/// Takes wheel input.
pub const wheel_flag: Flags = .{
    .wheel = true,
    .focusable = false,
    .tab = false,
    .cursor = .default,
};

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
        /// Set for a canvas (section 3a): `end_canvas` closes it.
        is_canvas: bool,
        /// Set for a container `begin_at` placed (section 3b): it does not take part in its
        /// parent's flow.
        free: bool,
    };
    // The open canvas (section 3a).
    const Canvas = struct {
        view: draw.View,
        layer_before: draw.Layer,
    };
    // The open popup (section 3c).
    const Popup = struct {
        id: Id,
        layer_before: draw.Layer,
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
        hot_focusable: bool,
        hot_cursor: Cursor,
        wheel: Id,
        hover: Id,
        hover_prev: Id,
        capture: Id,
        capture_rect: Rect,
        capture_cursor: Cursor,
        /// True during the event whose `down` set the capture.
        pressed: bool,
        /// True during the left release that ends the capture.
        ending_capture: bool,
        /// The click sequence of the last press (`input.count_click`).
        clicks: input.Clicks,
        /// Keyboard focus and the focus when the current event began (section 7).
        focus: Id,
        focus_prev: Id,
        focus_rect: Rect,
        /// True during an Escape press; `event_end` then clears focus.
        escaping: bool,
        /// True after a key press a widget or Tab took (section 7).
        key_consumed: bool,
        /// Held keys as `Key.bit` flags, and the latest modifiers.
        keys_held: u64,
        mods: input.Mods,
        window_focused: bool,
        /// `copy` output: `clipboard[0..copy_len]`. The flags are for the host (section 8).
        clipboard: [clipboard_cap]u8,
        copy_len: u32,
        copy_pending: bool,
        paste_pending: bool,
        /// A draw is owed. Set by `redraw`, cleared by `begin_frame`.
        dirty: bool,
        /// An animator is still moving; see `keep_animating`.
        animating: bool,
        /// The host timer's period (`App.config.timer_period_ms`), 0 for an app without a
        /// timer, and whether the app wants it running (section 9). Hosts read `timer_on`.
        timer_period_ms: u32,
        timer_on: bool,
        /// Whether the app declares an audio source, and whether it wants it running
        /// (section 9a). Hosts read `audio_on`.
        has_audio: bool,
        audio_on: bool,
        /// Blocks the audio queue refused so far; the hosts copy it after each drain.
        audio_dropped: u32,
        /// The canvas being drawn, if any (section 3a).
        canvas_open: ?Canvas,
        /// The popup being drawn, if any, and the popups drawn this frame (section 3c).
        popup_open: ?Popup,
        popup_count: u32,
        /// The popup a widget opened (`request_popup`) and the one this frame drew or skipped;
        /// safe builds check at `end_frame` that a request was met (section 3c).
        popup_requested: Id,
        popup_met: Id,
        /// The app's scheme (section 9b); `draw.theme` is its record.
        scheme: theme_module.Scheme,
        /// What `overflow_report` last returned or saw (section 10).
        overflow_seen: Overflow,

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
            self.hot_focusable = false;
            self.hot_cursor = .default;
            self.wheel = .none;
            self.hover = .none;
            self.hover_prev = .none;
            self.capture = .none;
            self.capture_rect = self.window;
            self.capture_cursor = .default;
            self.pressed = false;
            self.ending_capture = false;
            self.clicks = .none;
            self.focus = .none;
            self.focus_prev = .none;
            self.focus_rect = self.window;
            self.escaping = false;
            self.key_consumed = false;
            self.keys_held = 0;
            self.mods = .none;
            self.window_focused = true;
            self.copy_len = 0;
            self.copy_pending = false;
            self.paste_pending = false;
            self.dirty = true;
            self.animating = false;
            self.timer_period_ms = 0;
            self.timer_on = false;
            self.has_audio = false;
            self.audio_on = false;
            self.audio_dropped = 0;
            self.canvas_open = null;
            self.popup_open = null;
            self.popup_count = 0;
            self.popup_requested = .none;
            self.popup_met = .none;
            self.overflow_seen = .zero;
            self.scheme = theme_module.dark;
            self.draw.theme = self.scheme.record();
            assert(self.phase == .idle);
            assert(self.dirty);
        }

        /// Records the app's timer period and whether the timer runs from startup; the hosts
        /// call it once after `init` (section 9). A period of 0 never runs.
        pub fn timer_setup(self: *Self, period_ms: u32, armed: bool) void {
            assert(self.phase == .idle);
            self.timer_period_ms = period_ms;
            self.timer_on = period_ms != 0 and armed;
            if (period_ms == 0) assert(!self.timer_on);
        }

        /// Starts or stops the host timer. The host applies the change after the current call
        /// returns; a stopped timer calls no `App.timer` (section 9). Not during a draw, and
        /// only for an app that declared a timer period.
        pub fn set_timer(self: *Self, on: bool) void {
            assert(self.phase != .draw);
            assert(self.timer_period_ms != 0);
            self.timer_on = on;
            assert(self.timer_on == on);
        }

        /// Records whether the app declares an audio source; the hosts call it once after
        /// `init` (section 9a). The source starts stopped.
        pub fn audio_setup(self: *Self, has_audio: bool) void {
            assert(self.phase == .idle);
            self.has_audio = has_audio;
            self.audio_on = false;
        }

        /// Starts or stops the app's audio source. The host applies the change after the
        /// current call returns (section 9a). Not during a draw, and only for an app with a
        /// source.
        pub fn set_audio(self: *Self, on: bool) void {
            assert(self.phase != .draw);
            assert(self.has_audio);
            self.audio_on = on;
            assert(self.audio_on == on);
        }

        /// Records the app's starting scheme; the hosts call it once after `init` (section 9b).
        /// The first draw is already owed, so it marks nothing.
        pub fn theme_setup(self: *Self, scheme: theme_module.Scheme) void {
            assert(self.phase == .idle);
            assert(self.dirty);
            self.scheme = scheme;
            self.draw.theme = scheme.record();
        }

        /// The app's scheme, which widgets read their colors, text styles, and weights from
        /// (section 9b). Any phase.
        pub fn theme(self: *const Self) *const theme_module.Scheme {
            assert(self.depth <= turtle.depth_max);
            return &self.scheme;
        }

        /// Switches the app's scheme: stores it, gives the draw context its record, and owes a
        /// draw, which the renderer turns into one uniform write and a full repaint (section
        /// 9b). The current scheme again does nothing. Not during a draw.
        pub fn set_theme(self: *Self, scheme: theme_module.Scheme) void {
            assert(self.phase != .draw);
            if (std.meta.eql(scheme, self.scheme)) return;
            self.scheme = scheme;
            self.draw.theme = scheme.record();
            self.redraw();
            assert(self.dirty);
            assert(std.meta.eql(self.scheme, scheme));
        }

        /// What the last draw refused (section 10). Not during a draw.
        pub fn overflow(self: *const Self) Overflow {
            assert(self.phase != .draw);
            return .{
                .instances = self.draw.overflow_count,
                .areas = self.area_overflow,
                .glyphs = self.draw.text.overflow_count,
            };
        }

        /// The last draw's overflow when it differs from what this last saw and is not all
        /// zero, else null, so a persistent overflow is reported once and again whenever it
        /// changes. The hosts log it after each draw in builds with runtime safety.
        pub fn overflow_report(self: *Self) ?Overflow {
            const now = self.overflow();
            if (std.meta.eql(now, self.overflow_seen)) return null;
            self.overflow_seen = now;
            if (std.meta.eql(now, Overflow.zero)) return null;
            return now;
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
            self.popup_count = 0;
            self.popup_met = .none;
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
            assert(self.popup_open == null);
            self.depth = 0;
            self.phase = .idle;
            if (self.popup_requested != .none) {
                // A widget opened a popup that no draw_overlay reached (section 3c).
                if (std.debug.runtime_safety and self.popup_met != self.popup_requested) {
                    std.debug.panic(
                        "popup {x} was requested but not drawn: call ui.overlays(cx, app) " ++
                            "at the end of App.draw",
                        .{@backingInt(self.popup_requested)},
                    );
                }
                self.popup_requested = .none;
            }
            if (self.focus != .none) {
                if (self.find(self.focus)) |focused_area| {
                    self.focus_rect = rect_of(focused_area.rect);
                }
            }
            if (self.capture != .none) {
                if (self.find(self.capture)) |captured| self.capture_rect = rect_of(captured.rect);
                return false;
            }
            if (!self.pointer.inside) return false;
            const live = self.areas[0..self.area_count];
            const points = self.draw.point_items();
            const found = areas.resolve(live, points, self.pointer.x, self.pointer.y);
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
            assert(!entry.is_canvas);
            _ = self.shift_since(entry, turtle.main_shift(&entry.turtle));
            var rect = turtle.close(&entry.turtle);
            self.depth -= 1;
            // A free container keeps its rect and leaves its parent's flow alone (section 3b).
            if (entry.free) return rect;
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
            return self.begin_view_with(id, child, layout, state, wheel_flag);
        }

        /// `begin_view` whose own area carries `flags` (which take the wheel): a list box makes
        /// its view focusable, so Tab reaches it and its keys follow focus.
        pub fn begin_view_with(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *ViewState,
            flags: Flags,
        ) Rect {
            assert(flags.wheel);
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
                self.area(id, viewport, 0, flags);
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
            assert(!entry.is_canvas);
            const state = entry.view.?;
            state.content_h = @max(0, entry.turtle.extent[1] - entry.turtle.rect.y);
            self.depth -= 1;
            const parent = self.top();
            turtle.advance(&parent.turtle, entry.outer_walk, entry.outer_rect);
            if (!(state.max_scroll() > 0)) return;
            if (!(state.viewport.height > 0)) return;
            const thumb = state.thumb_rect();
            const outer = parent.clip orelse return;
            const look: draw.BoxLook = .{
                .fill = self.scheme.colors.control,
                .radius = view.thumb_radius,
            };
            self.append(draw.Box, null, .of(thumb, outer, look)) catch |err| switch (err) {
                error.PoolFull, error.BatchFull => {},
                error.EdgeNotPositive, error.ClipUnordered => unreachable,
            };
            self.area(entry.view_id.derive(view.thumb_salt), thumb, 0, plain);
        }

        // ------------------------------------------------------------- canvases

        /// Opens a canvas for `child` (section 3a): `layout.padding` insets the viewport, the
        /// canvas's own wheel and pan area `id` covers it, and `layers` (1 to 4, none the base
        /// layer) get `state`'s view this frame. Until `end_canvas`, appends go to those layers
        /// (starting on the first), the turtle, clips, and `visible` work in world pixels, and
        /// areas are mapped to the screen. Canvases do not nest. Returns the viewport.
        pub fn begin_canvas(
            self: *Self,
            id: Id,
            child: turtle.Walk,
            layout: turtle.Layout,
            state: *CanvasState,
            layers: []const draw.Layer,
        ) Rect {
            assert(self.canvas_open == null);
            assert(self.depth < turtle.depth_max);
            assert(child.width != .fit);
            assert(child.height != .fit);
            assert(layers.len >= 1 and layers.len <= 4);
            const parent = self.top();
            const rect = turtle.place(&parent.turtle, child);
            const viewport = inset(rect, layout.padding);
            state.viewport = viewport;
            if (viewport.width > 0 and viewport.height > 0) {
                self.area(id, viewport, 0, wheel_flag);
            }
            const viewed = state.view_of(self.draw.text.scale_120);
            state.drawn = viewed;
            var mask: u8 = 0;
            for (layers) |layer_value| {
                self.draw.view(layer_value, viewed);
                mask |= @as(u8, 1) << @intCast(@backingInt(layer_value));
            }
            self.draw.open_views(mask, viewed.zoom);
            self.draw.text.zoom = canvas.glyph_zoom(viewed.zoom);
            const screen = intersect(parent.clip, viewport);
            const world_clip: ?Clip = if (screen) |outer| world_clip_of(viewed, outer) else null;
            const world = world_rect_of(viewed, viewport);
            var inner = layout;
            inner.padding = turtle.zero_inset;
            inner.clip = false;
            self.clip_total += 1;
            var entry = self.entry_of(turtle.root(world, inner), world_clip);
            entry.is_canvas = true;
            entry.viewport = viewport;
            entry.outer_walk = child;
            entry.outer_rect = rect;
            self.stack[self.depth] = entry;
            self.depth += 1;
            self.canvas_open = .{ .view = viewed, .layer_before = self.draw.layer(layers[0]) };
            assert(self.canvas_open.?.view.zoom > 0);
            return viewport;
        }

        /// Closes the open canvas: restores the layer and the glyph zoom and advances the
        /// parent by the canvas's walk.
        pub fn end_canvas(self: *Self) void {
            assert(self.depth >= 2);
            const entry = &self.stack[self.depth - 1];
            assert(entry.is_canvas);
            const open = self.canvas_open.?;
            self.depth -= 1;
            const parent = self.top();
            turtle.advance(&parent.turtle, entry.outer_walk, entry.outer_rect);
            _ = self.draw.layer(open.layer_before);
            self.draw.close_views();
            self.draw.text.zoom = 1;
            self.canvas_open = null;
        }

        /// The view of the open canvas, or null outside one.
        pub fn canvas_view(self: *const Self) ?draw.View {
            const open = self.canvas_open orelse return null;
            return open.view;
        }

        /// Opens a container at `rect` (fixed on both axes) in the current coordinates, laid
        /// out by `layout`, outside its parent's flow (section 3b). Close it with `end`, which
        /// returns `rect` and leaves the parent's cursor alone.
        pub fn begin_at(self: *Self, rect: Rect, layout: turtle.Layout) Rect {
            assert(self.depth < turtle.depth_max);
            assert(rect.width >= 0);
            assert(rect.height >= 0);
            const parent = self.top();
            var clipped = parent.clip;
            if (layout.clip) {
                self.clip_total += 1;
                clipped = intersect(parent.clip, rect);
            }
            var entry = self.entry_of(turtle.root(rect, layout), clipped);
            entry.free = true;
            self.stack[self.depth] = entry;
            self.depth += 1;
            assert(self.depth >= 2);
            return rect;
        }

        // --------------------------------------------------------------- popups

        /// Opens popup `id` at `rect` (section 3c): switches to `Layer.popup`, appends a dimmed
        /// face over the window when `dim > 0` (its alpha), records the backdrop area
        /// `popup_backdrop(id)` over the whole window, and opens a free container at `rect`
        /// laid out by `layout` under the window clip. Only at the root, outside a canvas, one
        /// popup per frame, and never while the popup layer draws offscreen. Returns `rect`.
        pub fn begin_popup(self: *Self, id: Id, rect: Rect, layout: turtle.Layout, dim: f32) Rect {
            assert(self.phase == .draw);
            assert(self.depth == 1);
            assert(self.canvas_open == null);
            assert(self.popup_open == null);
            assert(self.popup_count < popup.popup_depth_max);
            assert(dim >= 0 and dim <= 1);
            assert(rect.width > 0 and rect.height > 0);
            const popup_index: u8 = @backingInt(draw.Layer.popup);
            assert(self.draw.binding_of(popup_index) == null);
            assert(self.draw.view_of(popup_index) == null);
            const before = self.draw.layer(.popup);
            const window_clip = self.stack[0].clip.?;
            if (dim > 0) {
                const look: draw.BoxLook = .{ .fill = .{ 0, 0, 0, dim } };
                self.append(draw.Box, null, .of(self.window, window_clip, look)) catch |err| {
                    switch (err) {
                        error.PoolFull, error.BatchFull => {},
                        error.EdgeNotPositive, error.ClipUnordered => unreachable,
                    }
                };
            }
            self.area(self.popup_backdrop(id), self.window, 0, plain);
            self.popup_open = .{ .id = id, .layer_before = before };
            self.popup_count += 1;
            self.popup_met = id;
            const opened = self.begin_at(rect, layout);
            assert(self.depth == 2);
            return opened;
        }

        /// Closes the open popup and restores the layer it opened over.
        pub fn end_popup(self: *Self) void {
            assert(self.depth == 2);
            const open = self.popup_open.?;
            assert(self.stack[1].free);
            _ = self.end();
            _ = self.draw.layer(open.layer_before);
            self.popup_open = null;
            assert(self.depth == 1);
            assert(self.draw.layer_now != .popup or open.layer_before == .popup);
        }

        /// The id of popup `id`'s backdrop area, which takes every press outside the popup.
        pub fn popup_backdrop(self: *const Self, id: Id) Id {
            assert(id != .none);
            assert(self.depth <= turtle.depth_max);
            return id.derive(popup.backdrop_salt);
        }

        /// Notes that popup `id` opened and owes its first draw: safe builds check at the end
        /// of that draw that its owner drew it or skipped it (section 3c). Not during a draw.
        pub fn request_popup(self: *Self, id: Id) void {
            assert(self.phase != .draw);
            assert(id != .none);
            self.popup_requested = id;
            self.redraw();
        }

        /// Notes that the owner of popup `id` reached it this frame but drew nothing, because
        /// its anchor was not drawn (section 3c). Draw phase.
        pub fn skip_popup(self: *Self, id: Id) void {
            assert(self.phase == .draw);
            assert(id != .none);
            self.popup_met = id;
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
            var stored: Area = .{
                .id = id,
                .rect = .{ rect.x, rect.y, rect.width, rect.height },
                .clip = .{ current.x0, current.y0, current.x1, current.y1 },
                .radius = radius,
                .layer = @backingInt(self.draw.layer_now),
                .flags = flags,
                .pad = 0,
                .first_point = 0,
                .point_count = 0,
                .zoom = 1,
                .pad1 = 0,
            };
            // Inside a canvas, mapped to the screen (section 3a).
            if (self.canvas_open) |open| {
                const v = open.view;
                stored.rect = .{
                    v.x + v.zoom * rect.x,
                    v.y + v.zoom * rect.y,
                    v.zoom * rect.width,
                    v.zoom * rect.height,
                };
                stored.clip = .{
                    v.x + v.zoom * current.x0,
                    v.y + v.zoom * current.y0,
                    v.x + v.zoom * current.x1,
                    v.y + v.zoom * current.y1,
                };
                stored.radius = v.zoom * radius;
                stored.zoom = v.zoom;
            }
            self.areas[self.area_count] = stored;
            self.area_count += 1;
            assert(self.area_count <= area_cap);
        }

        /// Records a path area for `id`: the points within `width / 2 + path.hit_slop` of the
        /// path `placed` (from `draw.path`, this frame) under the clip in effect, on the
        /// current layer (`ui/areas.zig`, section 3). One area per id per frame.
        pub fn path_area(
            self: *Self,
            id: Id,
            placed: draw.path.Placed,
            width: f32,
            flags: Flags,
        ) void {
            assert(width > 0);
            assert(placed.count >= 1);
            assert(placed.first + placed.count <= self.draw.point_count);
            const radius = width * 0.5 + draw.path.hit_slop;
            const bounds = placed.bounds;
            const rect: Rect = .{
                .x = bounds.x - radius,
                .y = bounds.y - radius,
                .width = bounds.width + 2 * radius,
                .height = bounds.height + 2 * radius,
            };
            const before = self.area_count;
            self.area(id, rect, radius, flags);
            if (self.area_count == before) return;
            const recorded = &self.areas[before];
            recorded.first_point = placed.first;
            recorded.point_count = placed.count;
            assert(recorded.id == id);
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
        /// wheel target once (section 5), and applies focus, keys, and window focus (section 7).
        pub fn event_begin(self: *Self, event: input.Event) void {
            assert(self.phase == .idle);
            self.phase = .event;
            self.event_tag = event;
            self.hover_prev = self.hover;
            self.focus_prev = self.focus;
            self.pressed = false;
            self.ending_capture = false;
            self.escaping = false;
            switch (event) {
                .frame, .paste => {},
                .pointer_leave => {
                    self.pointer.leave();
                    self.hot = .none;
                    self.hot_focusable = false;
                    self.hot_cursor = .default;
                    self.wheel = .none;
                    self.hover = .none;
                },
                .pointer_move => |point| self.point_at(point.x, point.y, false),
                .wheel => |wheel| self.point_at(wheel.x, wheel.y, false),
                .pointer_down => |down| self.press_at(down),
                .pointer_up => |up| {
                    self.mods = up.mods;
                    const left = up.button == .left;
                    if (left) self.pointer.button(false);
                    self.ending_capture = left and self.capture != .none;
                    self.point_at(up.x, up.y, left);
                },
                .key_down => |press| self.key_at(press),
                .key_up => |press| {
                    self.mods = press.mods;
                    self.keys_held &= ~press.key.bit();
                },
                .window_focus => |focused_now| {
                    self.window_focused = focused_now;
                    if (!focused_now) {
                        self.keys_held = 0;
                        self.mods = .none;
                    }
                },
            }
            assert(self.phase == .event);
        }

        /// Finishes dispatching: a left release or a leave drops the capture, and an Escape
        /// press clears focus after the widgets saw it (section 7).
        pub fn event_end(self: *Self) void {
            assert(self.phase == .event);
            switch (self.event_tag) {
                .pointer_up => if (self.ending_capture) {
                    self.capture = .none;
                },
                .pointer_leave => self.capture = .none,
                else => {},
            }
            if (self.escaping) self.focus = .none;
            self.phase = .idle;
            assert(self.phase == .idle);
        }

        /// What `event` means for `id`. O(1); see the module guide, section 5.
        pub fn hit(self: *const Self, id: Id, event: input.Event) Hit {
            assert(self.phase == .event);
            assert(id != .none);
            assert(@as(std.meta.Tag(input.Event), event) == self.event_tag);
            switch (event) {
                .frame, .key_down, .key_up, .paste, .window_focus => return .none,
                .pointer_move => |point| {
                    if (self.capture != .none) return self.drag_of(id, point.x, point.y);
                    return self.hover_change(id);
                },
                .pointer_down => |down| {
                    if (down.button == .left) {
                        if (self.pressed and id == self.capture) {
                            return .{ .down = self.press_of(down.x, down.y, self.hot_rect) };
                        }
                        if (!self.pressed and self.capture != .none) {
                            return self.drag_of(id, down.x, down.y);
                        }
                        return self.hover_change(id);
                    }
                    if (self.capture != .none) return self.drag_of(id, down.x, down.y);
                    if (down.button == .right and id == self.hot) {
                        return .{ .secondary = self.press_of(down.x, down.y, self.hot_rect) };
                    }
                    return self.hover_change(id);
                },
                .pointer_up => |up| {
                    if (up.button != .left) {
                        if (self.capture != .none) return self.drag_of(id, up.x, up.y);
                        return self.hover_change(id);
                    }
                    if (self.capture == .none) return self.hover_change(id);
                    if (id == self.capture) {
                        const inside = self.hot == self.capture;
                        return .{ .up = .{ .x = up.x, .y = up.y, .inside = inside } };
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

        fn press_of(self: *const Self, x: f32, y: f32, rect: Rect) Press {
            assert(x == x);
            assert(self.clicks.count >= 1);
            return .{
                .x = x,
                .y = y,
                .rect = rect,
                .clicks = self.clicks.count,
                .mods = self.mods,
            };
        }

        fn drag_of(self: *const Self, id: Id, x: f32, y: f32) Hit {
            assert(self.capture != .none);
            assert(id != .none);
            if (id != self.capture) return .none;
            return .{ .drag = self.press_of(x, y, self.capture_rect) };
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
            const live = self.areas[0..self.area_count];
            const found = areas.resolve(live, self.draw.point_items(), x, y);
            self.hot = .none;
            self.hot_focusable = false;
            self.hot_cursor = .default;
            self.wheel = .none;
            if (found.hot) |index| {
                const hot_area = &self.areas[index];
                self.hot = hot_area.id;
                self.hot_rect = rect_of(hot_area.rect);
                self.hot_focusable = hot_area.flags.focusable;
                self.hot_cursor = hot_area.flags.cursor;
            }
            if (found.wheel) |index| self.wheel = self.areas[index].id;
            if (self.capture == .none or releasing) self.hover = self.hot;
            assert(self.pointer.inside);
        }

        /// A press: counts the click, and a left press captures the hot area and moves focus
        /// to it when it is focusable, or clears focus (section 7).
        fn press_at(self: *Self, down: input.Button) void {
            self.mods = down.mods;
            self.clicks = input.count_click(self.clicks, down);
            if (down.button != .left) {
                self.point_at(down.x, down.y, false);
                return;
            }
            self.pointer.button(true);
            self.point_at(down.x, down.y, false);
            if (self.capture != .none) return;
            if (self.hot != .none) {
                self.capture = self.hot;
                self.capture_rect = self.hot_rect;
                self.capture_cursor = self.hot_cursor;
                self.pressed = true;
            }
            self.focus = if (self.hot_focusable) self.hot else .none;
            if (self.focus != .none) self.focus_rect = self.hot_rect;
            assert(self.clicks.count >= 1);
        }

        /// A key press: holds the key, cycles focus on Tab, notes Escape, and decides whether
        /// the browser should keep the key from the page (section 7).
        fn key_at(self: *Self, press: input.KeyPress) void {
            self.mods = press.mods;
            self.keys_held |= press.key.bit();
            self.escaping = press.key == .escape;
            if (press.key == .tab and !press.mods.shortcut() and !press.mods.alt) {
                if (!self.focus_keeps_tab()) self.cycle_focus(press.mods.shift);
            }
            const clipboard_key = press.key == .c or press.key == .x or press.key == .v;
            const shortcut = press.mods.shortcut() and clipboard_key;
            const routed = self.focus_prev != .none or self.focus != .none;
            self.key_consumed = routed and !shortcut;
            if (shortcut) assert(!self.key_consumed);
        }

        /// True when the focused area of the last draw is flagged `tab`, so Tab goes to its
        /// widget. One scan of the areas, on the Tab path only (section 7).
        fn focus_keeps_tab(self: *const Self) bool {
            assert(self.phase == .event);
            if (self.focus == .none) return false;
            const focused_area = self.find(self.focus) orelse return false;
            assert(focused_area.flags.focusable);
            return focused_area.flags.tab;
        }

        /// Moves focus to the next focusable area in draw order, or the previous one when
        /// `backward`, wrapping. One scan of the areas; nothing focusable leaves focus as is.
        fn cycle_focus(self: *Self, backward: bool) void {
            var first: ?u32 = null;
            var last: ?u32 = null;
            var before: ?u32 = null;
            var after: ?u32 = null;
            var seen = false;
            for (self.areas[0..self.area_count], 0..) |candidate, index| {
                if (!candidate.flags.focusable) continue;
                const at: u32 = @intCast(index);
                if (first == null) first = at;
                last = at;
                if (candidate.id == self.focus) {
                    seen = true;
                } else if (!seen) {
                    before = at;
                } else if (after == null) {
                    after = at;
                }
            }
            const chosen: ?u32 = if (!seen)
                (if (backward) last else first)
            else if (backward)
                (before orelse last)
            else
                (after orelse first);
            const index = chosen orelse return;
            assert(index < self.area_count);
            self.focus = self.areas[index].id;
            self.focus_rect = rect_of(self.areas[index].rect);
        }

        // ---------------------------------------------------------------- focus

        /// True when `id` has keyboard focus.
        pub fn focused(self: *const Self, id: Id) bool {
            assert(id != .none);
            assert(self.area_count <= area_cap);
            return self.focus == id;
        }

        /// True during the event that gave `id` focus.
        pub fn focus_gained(self: *const Self, id: Id) bool {
            assert(self.phase == .event);
            assert(id != .none);
            return self.focus == id and self.focus_prev != id;
        }

        /// True during the event that took focus from `id` (a press elsewhere or Tab).
        pub fn focus_lost(self: *const Self, id: Id) bool {
            assert(self.phase == .event);
            assert(id != .none);
            return self.focus_prev == id and self.focus != id;
        }

        /// Gives `id` focus, as a widget that opens an editor does. Event phase only.
        pub fn set_focus(self: *Self, id: Id) void {
            assert(self.phase == .event);
            assert(id != .none);
            self.focus = id;
            if (self.find(id)) |found| self.focus_rect = rect_of(found.rect);
            assert(self.focus == id);
        }

        /// Clears focus, as a field does when Enter commits. Event phase only.
        pub fn clear_focus(self: *Self) void {
            assert(self.phase == .event);
            self.focus = .none;
            assert(self.focus == .none);
        }

        /// The focused area's rect at the last draw that recorded it (section 7).
        pub fn focused_rect(self: *const Self) Rect {
            assert(self.focus != .none);
            assert(self.focus_rect.width >= 0);
            return self.focus_rect;
        }

        /// True while `key` is held.
        pub fn held(self: *const Self, key: input.Key) bool {
            assert(key != .other);
            assert(self.phase != .draw);
            return self.keys_held & key.bit() != 0;
        }

        /// True when the last key press went to a widget or moved focus (section 7).
        pub fn consumed(self: *const Self) bool {
            assert(self.phase == .idle);
            assert(self.event_tag == .key_down);
            return self.key_consumed;
        }

        // ------------------------------------------------------ cursor, clipboard

        /// The pointer shape to show (section 8).
        pub fn cursor(self: *const Self) Cursor {
            assert(self.phase != .draw);
            if (self.capture != .none) {
                if (self.capture_cursor == .grab) return .grabbing;
                return self.capture_cursor;
            }
            if (!self.pointer.inside) return .default;
            return self.hot_cursor;
        }

        /// Stores `utf8` (cut to `clipboard_cap` on a codepoint boundary) for the host to offer
        /// as the clipboard selection. Event phase only.
        pub fn copy(self: *Self, utf8: []const u8) void {
            assert(self.phase == .event);
            const length = input.utf8_prefix(utf8, clipboard_cap);
            @memcpy(self.clipboard[0..length], utf8[0..length]);
            self.copy_len = length;
            self.copy_pending = true;
            assert(self.copy_len <= clipboard_cap);
        }

        /// The bytes of the last `copy`.
        pub fn copied(self: *const Self) []const u8 {
            assert(self.copy_len <= clipboard_cap);
            return self.clipboard[0..self.copy_len];
        }

        /// Host side: true once after a `copy`.
        pub fn take_copy(self: *Self) bool {
            assert(self.phase == .idle);
            const pending = self.copy_pending;
            self.copy_pending = false;
            assert(!self.copy_pending);
            return pending;
        }

        /// Asks the host for the clipboard text; it arrives as a `paste` event. Event phase.
        pub fn request_paste(self: *Self) void {
            assert(self.phase == .event);
            self.paste_pending = true;
            assert(self.paste_pending);
        }

        /// Host side: true once after a `request_paste`.
        pub fn take_paste_request(self: *Self) bool {
            assert(self.phase == .idle);
            const pending = self.paste_pending;
            self.paste_pending = false;
            assert(!self.paste_pending);
            return pending;
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
                .is_canvas = false,
                .free = false,
            };
        }

        /// Snaps `delta` to device pixels and moves what `entry` drew by it (section 4).
        /// Returns the delta applied.
        fn shift_since(self: *Self, entry: *const Entry, delta: [2]f32) [2]f32 {
            assert(delta[0] >= 0);
            assert(delta[1] >= 0);
            assert(entry.area_start <= self.area_count);
            const scale = self.draw.text.device_scale();
            const dx = @round(delta[0] * scale) / scale;
            const dy = @round(delta[1] * scale) / scale;
            if (dx == 0 and dy == 0) return .{ 0, 0 };
            // Clips do not move, so nothing inside may have set one (section 4).
            assert(self.clip_total == entry.clip_total);
            self.draw.shift(entry.starts, dx, dy);
            // Areas inside a canvas are in screen pixels (section 3a).
            const area_scale: f32 = if (self.canvas_open) |open| open.view.zoom else 1;
            for (self.areas[entry.area_start..self.area_count]) |*moved| {
                moved.rect[0] += dx * area_scale;
                moved.rect[1] += dy * area_scale;
            }
            return .{ dx, dy };
        }
    };
}

/// The world clip under the screen clip `outer` through `v` (section 3a).
fn world_clip_of(v: draw.View, outer: Clip) Clip {
    assert(v.zoom > 0);
    const low = v.invert(outer.x0, outer.y0);
    const high = v.invert(outer.x1, outer.y1);
    const out: Clip = .{ .x0 = low[0], .y0 = low[1], .x1 = high[0], .y1 = high[1] };
    assert(out.x1 > out.x0);
    assert(out.y1 > out.y0);
    return out;
}

/// The world rect under the screen rect `rect` through `v`.
fn world_rect_of(v: draw.View, rect: Rect) Rect {
    assert(v.zoom > 0);
    const origin = v.invert(rect.x, rect.y);
    const width = rect.width / v.zoom;
    return .{ .x = origin[0], .y = origin[1], .width = width, .height = rect.height / v.zoom };
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

const TestContext = Context(draw.Context(&test_draw, 8, 0), 64);

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
    context.append(draw.Box, null, .of(rect, current, .{ .fill = .{ 1, 1, 1, 1 } })) catch
        unreachable;
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
    send(context, .{ .pointer_down = input.left_at(.{ .x = 60, .y = 60 }) }, &ids, &out);
    try testing.expectEqual(@as(f32, 50), out[1].down.rect.x);
    try testing.expectEqual(Hit.hover_out, out[2]);
    try testing.expectEqual(knob, context.hovered());
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(150, 50, 50, 50), 0, plain);
    try testing.expect(!context.end_frame());
    send(context, .{ .pointer_move = .{ .x = 170, .y = 60 } }, &ids, &out);
    try testing.expectEqual(@as(f32, 150), out[1].drag.rect.x);
    try testing.expectEqual(Hit.none, out[0]);
    send(context, .{ .pointer_up = input.left_at(.{ .x = 390, .y = 290 }) }, &ids, &out);
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
            const wheel: input.Event = .{ .wheel = .{ .x = 20, .y = 10, .dx = 0, .dy = 30000 } };
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

fn press_key(key: input.Key, mods: input.Mods) input.Event {
    return .{ .key_down = input.key_press(key, mods, false, "") };
}

fn button_event(x: f32, y: f32, which: input.MouseButton, down: bool) input.Event {
    const sample: input.Button = .{ .x = x, .y = y, .time_ms = 0, .button = which, .mods = .none };
    if (down) return .{ .pointer_down = sample };
    return .{ .pointer_up = sample };
}

const focusable_text: Flags = .{ .wheel = false, .focusable = true, .tab = false, .cursor = .text };

/// Draws three focusable fields at x = 0, 100, 200 and one plain area at x = 300.
fn draw_fields(context: *TestContext) void {
    context.begin_frame(400, 300, 120);
    var index: u32 = 0;
    while (index < 3) : (index += 1) {
        const x: f32 = @floatFromInt(index * 100);
        context.area(areas.id("field", index), rect_at(x, 0, 80, 20), 0, focusable_text);
    }
    context.area(areas.id("plain", 0), rect_at(300, 0, 80, 20), 0, plain);
    _ = context.end_frame();
}

// Locks focus: a left press focuses a focusable area and clears focus elsewhere, Tab and
// Shift+Tab walk the areas in draw order and wrap, the event that moves focus reports
// `focus_lost` and `focus_gained`, Escape clears focus only after the widgets saw it, and an
// undrawn focus survives a draw while Tab restarts from the first area.
test "focus follows presses, Tab cycles in draw order, and Escape clears after routing" {
    const context = new_context();
    draw_fields(context);
    const first = areas.id("field", 0);
    const second = areas.id("field", 1);
    const third = areas.id("field", 2);
    var out: [1]Hit = undefined;
    send(context, button_event(110, 10, .left, true), &.{second}, &out);
    try testing.expect(context.focused(second));
    try testing.expectEqual(@as(f32, 100), context.focused_rect().x);
    send(context, button_event(110, 10, .left, false), &.{second}, &out);
    context.event_begin(press_key(.tab, .none));
    try testing.expect(context.focus_lost(second));
    try testing.expect(context.focus_gained(third));
    context.event_end();
    try testing.expect(context.consumed());
    send(context, press_key(.tab, .none), &.{third}, &out);
    try testing.expect(context.focused(first));
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.tab, shift), &.{first}, &out);
    try testing.expect(context.focused(third));
    context.event_begin(press_key(.escape, .none));
    try testing.expect(context.focused(third));
    try testing.expect(!context.focus_lost(third));
    context.event_end();
    try testing.expectEqual(Id.none, context.focus);
    send(context, button_event(10, 10, .left, true), &.{first}, &out);
    send(context, button_event(10, 10, .left, false), &.{first}, &out);
    context.event_begin(button_event(310, 10, .left, true));
    try testing.expect(context.focus_lost(first));
    context.event_end();
    try testing.expectEqual(Id.none, context.focus);
    send(context, button_event(310, 10, .left, false), &.{first}, &out);
    context.event_begin(press_key(.tab, .none));
    context.set_focus(areas.id("gone", 0));
    context.event_end();
    draw_fields(context);
    try testing.expectEqual(areas.id("gone", 0), context.focus);
    send(context, press_key(.tab, .none), &.{first}, &out);
    try testing.expect(context.focused(first));
}

// Locks the `tab` flag: a focused area flagged `tab` keeps focus on Tab and Shift+Tab (its
// widget reads the key, which is consumed), Escape still clears it, and from there Tab cycles
// into the focusable areas again.
test "a tab-flagged focus keeps Tab and Escape still clears it" {
    const context = new_context();
    var editor_flags = focusable_text;
    editor_flags.tab = true;
    const editor = areas.id("editor", 0);
    const field = areas.id("field", 0);
    context.begin_frame(400, 300, 120);
    context.area(field, rect_at(0, 0, 80, 20), 0, focusable_text);
    context.area(editor, rect_at(100, 0, 200, 200), 0, editor_flags);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    send(context, button_event(150, 50, .left, true), &.{editor}, &out);
    send(context, button_event(150, 50, .left, false), &.{editor}, &out);
    try testing.expect(context.focused(editor));
    context.event_begin(press_key(.tab, .none));
    try testing.expect(!context.focus_lost(editor));
    context.event_end();
    try testing.expect(context.focused(editor));
    try testing.expect(context.consumed());
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.tab, shift), &.{editor}, &out);
    try testing.expect(context.focused(editor));
    send(context, press_key(.escape, .none), &.{editor}, &out);
    try testing.expectEqual(Id.none, context.focus);
    send(context, press_key(.tab, .none), &.{editor}, &out);
    try testing.expect(context.focused(field));
    send(context, press_key(.tab, .none), &.{editor}, &out);
    try testing.expect(context.focused(editor));
}

// Locks the browser key verdict: with nothing focusable a Tab is not consumed (the page may
// move focus), a focused widget consumes keys, and Ctrl+C, Ctrl+X, and Ctrl+V are never
// consumed so the page's clipboard events fire.
test "keys are consumed by focus but clipboard shortcuts never are" {
    const context = new_context();
    var out: [1]Hit = undefined;
    const field = areas.id("field", 0);
    send(context, press_key(.tab, .none), &.{field}, &out);
    try testing.expect(!context.consumed());
    draw_fields(context);
    send(context, press_key(.tab, .none), &.{field}, &out);
    try testing.expect(context.consumed());
    send(context, press_key(.a, .none), &.{field}, &out);
    try testing.expect(context.consumed());
    var ctrl = input.Mods.none;
    ctrl.ctrl = true;
    for ([_]input.Key{ .c, .x, .v }) |key| {
        send(context, press_key(key, ctrl), &.{field}, &out);
        try testing.expect(!context.consumed());
    }
    send(context, press_key(.a, ctrl), &.{field}, &out);
    try testing.expect(context.consumed());
    try testing.expectEqual(Hit.none, out[0]);
}

// Locks held keys: presses set and releases clear their bits, and a window blur releases every
// held key and the modifiers.
test "a window blur releases held keys and modifiers" {
    const context = new_context();
    var out: [1]Hit = undefined;
    const ids = [_]Id{areas.id("any", 0)};
    var shift = input.Mods.none;
    shift.shift = true;
    send(context, press_key(.a, shift), &ids, &out);
    send(context, press_key(.left, shift), &ids, &out);
    try testing.expect(context.held(.a));
    try testing.expect(context.held(.left));
    try testing.expect(context.mods.shift);
    send(context, .{ .key_up = input.key_press(.a, shift, false, "") }, &ids, &out);
    try testing.expect(!context.held(.a));
    send(context, .{ .window_focus = false }, &ids, &out);
    try testing.expect(!context.held(.left));
    try testing.expect(!context.mods.shift);
    try testing.expect(!context.window_focused);
    try testing.expectEqual(@as(u64, 0), context.keys_held);
}

// Locks the other buttons: a right press on the hot area is `secondary` without a capture, a
// right release during a left drag does not end it, and the left release does; the drag
// carries the click count.
test "right presses are secondary and never end a left capture" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    const other = areas.id("other", 0);
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, plain);
    context.area(other, rect_at(100, 0, 50, 50), 0, plain);
    _ = context.end_frame();
    const ids = [_]Id{ knob, other };
    var out: [2]Hit = undefined;
    send(context, button_event(10, 10, .right, true), &ids, &out);
    try testing.expectEqual(@as(f32, 0), out[0].secondary.rect.x);
    try testing.expectEqual(@as(u8, 1), out[0].secondary.clicks);
    try testing.expectEqual(Id.none, context.capture);
    send(context, button_event(10, 10, .right, false), &ids, &out);
    send(context, button_event(10, 10, .left, true), &ids, &out);
    try testing.expectEqual(knob, context.capture);
    send(context, button_event(120, 10, .right, true), &ids, &out);
    try testing.expectEqual(@as(f32, 120), out[0].drag.x);
    try testing.expectEqual(Hit.none, out[1]);
    send(context, button_event(120, 10, .right, false), &ids, &out);
    try testing.expectEqual(knob, context.capture);
    send(context, button_event(120, 10, .left, false), &ids, &out);
    try testing.expect(!out[0].up.inside);
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the cursor: the hot area's shape, `default` off every area and outside the window,
// and a held `grab` reads `grabbing` until the release.
test "the cursor follows the hot area and a held grab reads grabbing" {
    const context = new_context();
    const knob = areas.id("knob", 0);
    const field = areas.id("field", 0);
    const grab: Flags = .{ .wheel = true, .focusable = false, .tab = false, .cursor = .grab };
    context.begin_frame(400, 300, 120);
    context.area(knob, rect_at(0, 0, 50, 50), 0, grab);
    context.area(field, rect_at(100, 0, 50, 50), 0, focusable_text);
    _ = context.end_frame();
    var out: [1]Hit = undefined;
    try testing.expectEqual(Cursor.default, context.cursor());
    send(context, .{ .pointer_move = .{ .x = 120, .y = 10 } }, &.{field}, &out);
    try testing.expectEqual(Cursor.text, context.cursor());
    send(context, .{ .pointer_move = .{ .x = 10, .y = 10 } }, &.{field}, &out);
    try testing.expectEqual(Cursor.grab, context.cursor());
    send(context, button_event(10, 10, .left, true), &.{knob}, &out);
    send(context, .{ .pointer_move = .{ .x = 300, .y = 200 } }, &.{knob}, &out);
    try testing.expectEqual(Cursor.grabbing, context.cursor());
    send(context, button_event(300, 200, .left, false), &.{knob}, &out);
    try testing.expectEqual(Cursor.default, context.cursor());
    send(context, .pointer_leave, &.{knob}, &out);
    try testing.expectEqual(Cursor.default, context.cursor());
}

// Locks the clipboard handshake: `copy` keeps the bytes and flags the host once, a copy over
// `clipboard_cap` is cut on a codepoint boundary, and a paste request flags the host once.
test "copy keeps the bytes for the host and cuts on a codepoint boundary" {
    const context = new_context();
    context.event_begin(.{ .frame = 0 });
    context.copy("vco \u{e4}");
    context.request_paste();
    context.event_end();
    try testing.expectEqualStrings("vco \u{e4}", context.copied());
    try testing.expect(context.take_copy());
    try testing.expect(!context.take_copy());
    try testing.expect(context.take_paste_request());
    try testing.expect(!context.take_paste_request());
    const static = struct {
        var long: [clipboard_cap + 1]u8 = undefined;
    };
    @memset(static.long[0 .. clipboard_cap - 1], 'a');
    static.long[clipboard_cap - 1] = 0xC3;
    static.long[clipboard_cap] = 0xA4;
    context.event_begin(.{ .frame = 0 });
    context.copy(&static.long);
    context.event_end();
    try testing.expectEqual(@as(usize, clipboard_cap - 1), context.copied().len);
}

const path_test_draw = [_]draw.DrawType{.{ .type = draw.Path, .cap = 16 }};

const PathTestContext = Context(draw.Context(&path_test_draw, 4, 128), 8);

// Locks that a path area follows its container's alignment shift with its stroke: a 100 px
// row centered in a 400 px window moves by 150, and the pointer resolves to the path near the
// shifted polyline and to nothing in the empty corner of its rect.
test "a path area moves with its container's shift" {
    const static = struct {
        var context: PathTestContext = undefined;
    };
    const context = &static.context;
    context.init();
    context.begin_frame(400, 300, 120);
    var row = flow_of(.right);
    row.alignment = .{ .x = 0.5, .y = 0 };
    _ = context.begin(sized(.fill, .{ .fixed = 100 }), row);
    const cell = context.walk(sized(.{ .fixed = 100 }, .fill));
    const window = context.clip().?;
    const stroke: draw.path.Stroke = .{ .color = .{ 1, 1, 1, 1 }, .width = 4, .hover = 0 };
    const points = [_]draw.Point{
        .{ cell.x, cell.y + 10 },
        .{ cell.x + 90, cell.y + 10 },
        .{ cell.x + 90, cell.y + 90 },
    };
    const placed = draw.path.polyline(context.drawing(), &points, stroke, window).?;
    const cable = areas.id("cable", 0);
    context.path_area(cable, placed, stroke.width, plain);
    _ = context.end();
    _ = context.end_frame();
    const recorded = context.find(cable).?;
    try testing.expectEqual(@as(f32, 150 - 5), recorded.rect[0]);
    try testing.expectEqual(@as(u32, 3), recorded.point_count);
    try testing.expectEqual(@as(f32, 150), context.draw.items(draw.Path)[0].rect[0] + 3);
    context.event_begin(.{ .pointer_move = .{ .x = 150 + 45, .y = 13 } });
    try testing.expectEqual(cable, context.hot);
    context.event_end();
    context.event_begin(.{ .pointer_move = .{ .x = 150 + 20, .y = 80 } });
    try testing.expectEqual(areas.Id.none, context.hot);
    context.event_end();
}

// Locks the timer flag: a fresh context has no timer, setup with a period and `armed` false
// starts stopped, `set_timer` flips it during an event, and a zero period never runs even when
// asked to start armed.
test "the timer flag starts from setup and follows set_timer" {
    const cx = new_context();
    try testing.expectEqual(@as(u32, 0), cx.timer_period_ms);
    try testing.expect(!cx.timer_on);
    cx.timer_setup(33, false);
    try testing.expect(!cx.timer_on);
    cx.event_begin(.{ .frame = 0 });
    cx.set_timer(true);
    try testing.expect(cx.timer_on);
    cx.set_timer(false);
    cx.event_end();
    try testing.expect(!cx.timer_on);
    cx.timer_setup(33, true);
    try testing.expect(cx.timer_on);
    cx.timer_setup(0, true);
    try testing.expect(!cx.timer_on);
    try testing.expectEqual(@as(u32, 0), cx.timer_period_ms);
}

// Locks the audio flag: a fresh context has no source, setup records one stopped, and
// `set_audio` starts and stops it during an event.
test "the audio flag starts stopped and follows set_audio" {
    const cx = new_context();
    try testing.expect(!cx.has_audio);
    try testing.expect(!cx.audio_on);
    cx.audio_setup(true);
    try testing.expect(!cx.audio_on);
    cx.event_begin(.{ .frame = 0 });
    cx.set_audio(true);
    try testing.expect(cx.audio_on);
    cx.event_end();
    cx.event_begin(.{ .frame = 0 });
    cx.set_audio(false);
    cx.event_end();
    try testing.expect(!cx.audio_on);
}

// Locks the theme (section 9b): a fresh context holds `theme.dark` and its record; setting it
// again is a no-op that owes no draw; `theme.light` stores it, writes its record into
// `draw.theme` (its track in slot 2, its background in slot 9), and owes a draw; and the
// scrollbar thumb is drawn in the scheme's `control`.
test "set_theme stores a new scheme and owes a draw, the same one nothing" {
    const cx = new_context();
    const dark_record = theme_module.dark.record();
    try testing.expect(std.meta.eql(theme_module.dark, cx.theme().*));
    const held = std.mem.asBytes(&cx.draw.theme);
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&dark_record), held));
    cx.begin_frame(200, 100, 120);
    _ = cx.end_frame();
    try testing.expect(!cx.dirty);
    cx.event_begin(.{ .frame = 0 });
    cx.set_theme(theme_module.dark);
    try testing.expect(!cx.dirty);
    cx.set_theme(theme_module.light);
    cx.event_end();
    try testing.expect(cx.dirty);
    try testing.expectEqual(theme_module.light.colors.track, cx.draw.theme.track);
    try testing.expectEqual(theme_module.light.colors.background, cx.draw.theme.background);
    try testing.expectEqual(theme_module.light.colors.text, cx.theme().colors.text);
    var state = ViewState.init();
    cx.begin_frame(200, 100, 120);
    const view_id = areas.id("view", 0);
    const port: turtle.Walk = .{ .width = .fill, .height = .{ .fixed = 50 } };
    _ = cx.begin_view(view_id, port, .{ .flow = .down }, &state);
    _ = cx.walk(.{ .width = .fill, .height = .{ .fixed = 400 } });
    cx.end_view();
    _ = cx.end_frame();
    const thumb = cx.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 1), thumb.len);
    try testing.expectEqual(theme_module.light.colors.control, thumb[0].fill);
}

/// One frame of a 200 by 100 canvas at the top-left with one free module at world
/// (10, 5, 20, 10) and its area, viewed by `state`. Returns the module's world clip.
fn canvas_frame(context: *TestContext, state: *CanvasState) ?Clip {
    context.begin_frame(400, 300, 120);
    const layers = [_]draw.Layer{ @fromBackingInt(1), @fromBackingInt(2) };
    const walk = sized(.{ .fixed = 200 }, .{ .fixed = 100 });
    _ = context.begin_canvas(areas.id("canvas", 0), walk, flow_of(.down), state, &layers);
    const module = rect_at(10, 5, 20, 10);
    const clipped = context.visible(module);
    if (clipped != null) {
        _ = context.begin_at(module, flow_of(.right));
        box(context, module);
        context.area(areas.id("module", 0), module, 0, plain);
        _ = context.end();
    }
    context.end_canvas();
    _ = context.end_frame();
    return clipped;
}

// Locks canvases (section 3a): at zoom 2 from (50, 40) the canvas's clip is the world clip
// (-25, -20)..(75, 30), the cull test runs in world pixels, the module draws at its world rect
// while its area is mapped to (70, 50, 40, 20) on the screen, glyphs zoom inside only, the
// layer comes back, and `begin_at` leaves the canvas cursor where it was.
test "a canvas clips and culls in world pixels and maps its areas to the screen" {
    const context = new_context();
    var state = CanvasState.init(50, 40, 2);
    context.begin_frame(400, 300, 120);
    const layers = [_]draw.Layer{ @fromBackingInt(1), @fromBackingInt(2) };
    const walk = sized(.{ .fixed = 200 }, .{ .fixed = 100 });
    const canvas_id = areas.id("canvas", 0);
    const viewport = context.begin_canvas(canvas_id, walk, flow_of(.down), &state, &layers);
    try testing.expectEqual(rect_at(0, 0, 200, 100), viewport);
    const world: Clip = .{ .x0 = -25, .y0 = -20, .x1 = 75, .y1 = 30 };
    try testing.expectEqual(@as(?Clip, world), context.clip());
    try testing.expectEqual(@as(?Clip, null), context.visible(rect_at(80, 0, 10, 10)));
    try testing.expectEqual(@as(f32, 2), context.draw.text.zoom);
    try testing.expectEqual(@as(f32, 2), context.draw.text.device_scale());
    try testing.expectEqual(@as(u8, 1), @backingInt(context.draw.layer_now));
    const before = context.remaining();
    const module = rect_at(10, 5, 20, 10);
    try testing.expectEqual(module, context.begin_at(module, flow_of(.right)));
    box(context, module);
    context.area(areas.id("module", 0), module, 0, plain);
    try testing.expectEqual(module, context.end());
    try testing.expectEqual(before, context.remaining());
    context.end_canvas();
    try testing.expectEqual(draw.Layer.base, context.draw.layer_now);
    try testing.expectEqual(@as(f32, 1), context.draw.text.zoom);
    _ = context.end_frame();
    try testing.expectEqualSlices(f32, &.{ 10, 5, 20, 10 }, &context.draw.items(draw.Box)[0].rect);
    const drawn = context.draw.items(draw.Box)[0];
    try testing.expectEqualSlices(f32, &.{ -25, -20, 75, 30 }, &drawn.clip);
    const mapped = context.find(areas.id("module", 0)).?;
    try testing.expectEqualSlices(f32, &.{ 70, 50, 40, 20 }, &mapped.rect);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 200, 100 }, &mapped.clip);
    try testing.expectEqual(@as(f32, 2), mapped.zoom);
    try testing.expectEqual(draw.View{ .x = 50, .y = 40, .zoom = 2 }, state.drawn);
}

// Locks exact hit testing at every rung (section 3a): the press at the module's mapped center
// hits it and a point half a logical pixel right of its mapped edge reaches the canvas instead.
test "a canvas area hits its mapped rect at every zoom" {
    const context = new_context();
    const ids = [_]Id{ areas.id("module", 0), areas.id("canvas", 0) };
    var out: [2]Hit = undefined;
    for (canvas.rungs) |rung| {
        var state = CanvasState.init(60, 30, rung);
        if (canvas_frame(context, &state) == null) continue;
        const v = state.drawn;
        const center = v.apply(20, 10);
        const middle: input.Point = .{ .x = center[0], .y = center[1] };
        send(context, .{ .pointer_down = input.left_at(middle) }, &ids, &out);
        try testing.expect(out[0] == .down);
        send(context, .{ .pointer_up = input.left_at(middle) }, &ids, &out);
        const edge = v.apply(30, 10);
        if (edge[0] + 0.5 >= 200) continue;
        const outside: input.Point = .{ .x = edge[0] + 0.5, .y = edge[1] };
        send(context, .{ .pointer_down = input.left_at(outside) }, &ids, &out);
        try testing.expect(out[0] != .down);
        try testing.expect(out[1] == .down);
        send(context, .{ .pointer_up = input.left_at(outside) }, &ids, &out);
    }
}

// Locks the overflow report (section 10): a frame that refuses two instances is reported, the
// same overflow on the next frame is not, a frame without overflow is not but resets the
// memory, and the same overflow after it is reported again.
test "an overflow is reported once per change" {
    const context = new_context();
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 2;
    const two: Overflow = .{ .instances = 2, .areas = 0, .glyphs = 0 };
    try testing.expectEqual(@as(?Overflow, two), context.overflow_report());
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 0;
    try testing.expectEqual(@as(?Overflow, null), context.overflow_report());
    context.draw.overflow_count = 2;
    context.area_overflow = 1;
    const three: Overflow = .{ .instances = 2, .areas = 1, .glyphs = 0 };
    try testing.expectEqual(@as(?Overflow, three), context.overflow_report());
}

/// One frame with a base button at (20, 20, 100, 40) and, when `open`, popup `menu` at
/// (200, 100, 120, 60) holding one row area over its top half; `dim` as in `begin_popup`.
fn popup_frame(context: *TestContext, open: bool, dim: f32) void {
    const menu = areas.id("menu", 0);
    context.begin_frame(400, 300, 120);
    box(context, rect_at(20, 20, 100, 40));
    context.area(areas.id("button", 0), rect_at(20, 20, 100, 40), 0, plain);
    if (open) {
        const rect = rect_at(200, 100, 120, 60);
        const inside = context.begin_popup(menu, rect, .{ .flow = .down }, dim);
        try_expect(context.draw.layer_now == .popup);
        box(context, inside);
        context.area(menu.derive(0), context.walk(sized(.fill, .{ .fixed = 30 })), 0, plain);
        context.end_popup();
    }
    try_expect(context.draw.layer_now == .base);
    _ = context.end_frame();
}

fn try_expect(ok: bool) void {
    assert(ok);
}

// Locks `begin_popup` (section 3c): the backdrop is the first area on the popup layer and
// covers the window, the popup's row follows it on the same layer, the container is the
// popup's rect under the window clip, the layer is restored, and a `dim` of 0.4 appends one
// black face at alpha 0.4 over the window under the popup's face.
test "begin_popup records the backdrop first on the popup layer and restores the layer" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    popup_frame(context, true, 0);
    const list = context.area_list();
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(context.popup_backdrop(menu), list[1].id);
    try testing.expectEqual(@as(u8, 6), list[1].layer);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &list[1].rect);
    try testing.expectEqual(menu.derive(0), list[2].id);
    try testing.expectEqual(@as(u8, 6), list[2].layer);
    try testing.expectEqualSlices(f32, &.{ 200, 100, 120, 30 }, &list[2].rect);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &list[2].clip);
    try testing.expectEqual(@as(usize, 2), context.draw.items(draw.Box).len);
    popup_frame(context, true, 0.4);
    const boxes = context.draw.items(draw.Box);
    try testing.expectEqual(@as(usize, 3), boxes.len);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 400, 300 }, &boxes[1].rect);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0.4 }, boxes[1].fill);
    try testing.expectEqual(draw.Layer.popup, context.draw.layer_at(draw.Box, 1));
    try testing.expectEqual(draw.Layer.popup, context.draw.layer_at(draw.Box, 2));
}

// Locks resolution under a popup (section 3c): a point over the base button resolves to the
// backdrop, a point over the row to the row, and a press outside reaches the backdrop as `down`
// while the button under it sees nothing, then the release gives the button no `up`.
test "a popup's backdrop takes every press outside it" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    const button = areas.id("button", 0);
    const backdrop = context.popup_backdrop(menu);
    popup_frame(context, false, 0);
    var out: [3]Hit = undefined;
    const ids = [_]Id{ button, backdrop, menu.derive(0) };
    send(context, .{ .pointer_move = .{ .x = 50, .y = 30 } }, &ids, &out);
    try testing.expectEqual(Hit.hover_in, out[0]);
    popup_frame(context, true, 0);
    send(context, .{ .pointer_move = .{ .x = 50, .y = 30 } }, &ids, &out);
    try testing.expectEqual(backdrop, context.hot);
    try testing.expectEqual(Hit.hover_out, out[0]);
    try testing.expectEqual(Hit.hover_in, out[1]);
    send(context, .{ .pointer_move = .{ .x = 250, .y = 110 } }, &ids, &out);
    try testing.expectEqual(menu.derive(0), context.hot);
    try testing.expectEqual(Hit.hover_in, out[2]);
    send(context, .{ .pointer_move = .{ .x = 250, .y = 150 } }, &ids, &out);
    try testing.expectEqual(backdrop, context.hot);
    const at: input.Point = .{ .x = 50, .y = 30 };
    send(context, .{ .pointer_down = input.left_at(at) }, &ids, &out);
    try testing.expect(out[1] == .down);
    try testing.expectEqual(Hit.none, out[0]);
    // The owner dismisses and the next frame has no popup; the release still ends the
    // backdrop's capture, so the button gets no click.
    popup_frame(context, false, 0);
    send(context, .{ .pointer_up = input.left_at(at) }, &ids, &out);
    try testing.expect(out[1] == .up);
    try testing.expect(out[0] != .up);
    try testing.expectEqual(Id.none, context.capture);
}

// Locks the request check's bookkeeping (section 3c): a request is met by `begin_popup` or
// `skip_popup` in the next draw and cleared there, so the frame after owes nothing.
test "a popup request is met by the next draw" {
    const context = new_context();
    const menu = areas.id("menu", 0);
    popup_frame(context, false, 0);
    context.event_begin(.{ .frame = 0 });
    context.request_popup(menu);
    context.event_end();
    try testing.expect(context.dirty);
    try testing.expectEqual(menu, context.popup_requested);
    popup_frame(context, true, 0);
    try testing.expectEqual(Id.none, context.popup_requested);
    context.event_begin(.{ .frame = 0 });
    context.request_popup(menu);
    context.event_end();
    context.begin_frame(400, 300, 120);
    context.skip_popup(menu);
    _ = context.end_frame();
    try testing.expectEqual(Id.none, context.popup_requested);
}
